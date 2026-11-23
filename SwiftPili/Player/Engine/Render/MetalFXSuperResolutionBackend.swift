import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

private let nv12ToBGRAMetalSource = """
#include <metal_stdlib>
using namespace metal;

struct NV12ConvertParams {
    uint fullRange;
    uint colorMatrix; // 0 = BT.709, 1 = BT.601, 2 = BT.2020
};

kernel void nv12ToBGRA(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::sample> cbcrTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    constant NV12ConvertParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    constexpr sampler chromaSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = yTexture.read(gid).r;
    float2 uv = (float2(gid) + 0.5f) / float2(width, height);
    float2 cbcr = cbcrTexture.sample(chromaSampler, uv).rg - float2(0.5f, 0.5f);
    float yAdj = params.fullRange != 0 ? y : clamp((y - 16.0f / 255.0f) * (255.0f / 219.0f), 0.0f, 1.0f);
    float cb = params.fullRange != 0 ? cbcr.x : cbcr.x * (255.0f / 224.0f);
    float cr = params.fullRange != 0 ? cbcr.y : cbcr.y * (255.0f / 224.0f);

    float crv, cgu, cgv, cbu;
    if (params.colorMatrix == 1) {
        // BT.601
        crv = 1.402f;
        cgu = 0.344136f;
        cgv = 0.714136f;
        cbu = 1.772f;
    } else if (params.colorMatrix == 2) {
        // BT.2020
        crv = 1.4746f;
        cgu = 0.164553f;
        cgv = 0.571353f;
        cbu = 1.8814f;
    } else {
        // BT.709
        crv = 1.5748f;
        cgu = 0.187324f;
        cgv = 0.468124f;
        cbu = 1.8556f;
    }

    float r = clamp(yAdj + crv * cr, 0.0f, 1.0f);
    float g = clamp(yAdj - cgu * cb - cgv * cr, 0.0f, 1.0f);
    float b = clamp(yAdj + cbu * cb, 0.0f, 1.0f);
    outTexture.write(float4(r, g, b, 1.0f), gid);
}
"""

private struct NV12ConvertParams {
    var fullRange: UInt32
    var colorMatrix: UInt32
}

final class MetalFXSuperResolutionBackend {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var convertPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var inputRGBATexture: MTLTexture?
    private var privateOutputTexture: MTLTexture?
    private var outputPool: VideoSuperResolutionPool?
    private var configuredOutput: (width: Int, height: Int)?

    #if canImport(MetalFX)
    private var scaler: MTLFXSpatialScaler?
    #endif

    deinit {
        tearDown()
    }

    func flush() {
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    func tearDown() {
        flush()
        #if canImport(MetalFX)
        scaler = nil
        #endif
        inputRGBATexture = nil
        privateOutputTexture = nil
        outputPool = nil
        textureCache = nil
        convertPipeline = nil
        commandQueue = nil
        device = nil
        configuredOutput = nil
    }

    /// - Parameter maxScale: may be fractional; the caller caps it to the on-screen magnification so
    ///   output never exceeds the display's pixel size (upscaling past it is wasted GPU and memory).
    func upscale(pixelBuffer: CVPixelBuffer, maxScale: Float = 2) async -> VideoEnhancementBackendOutcome {
        #if !canImport(MetalFX)
        return .bypassed(reason: "MetalFX unavailable")
        #else
        guard maxScale.isFinite, maxScale >= VideoEnhancementDisplaySurface.minimumUsefulMagnification else {
            return .bypassed(reason: "Display resolution reached")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let scale = min(maxScale, 4)
        let candidates = [Self.evenSize(width, height, scale)]
            + [4, 3, 2].filter { Float($0) < scale }.map { (width * $0, height * $0) }
        guard VideoSuperResolutionRasterBudget.contains(width: width, height: height),
              let output = candidates.first(where: {
                  VideoSuperResolutionRasterBudget.contains(width: $0.0, height: $0.1)
              }) else {
            return .bypassed(reason: "MetalFX output exceeds raster budget")
        }
        if let setupReason = ensureMetalInfrastructure() {
            return .bypassed(reason: setupReason)
        }
        if scaler?.inputWidth != width || scaler?.inputHeight != height
            || configuredOutput?.width != output.0 || configuredOutput?.height != output.1,
           let configReason = configureScaler(width: width, height: height, output: output) {
            return .bypassed(reason: configReason)
        }
        return await runUpscalePass(pixelBuffer: pixelBuffer, width: width, height: height)
        #endif
    }

    private static func evenSize(_ width: Int, _ height: Int, _ scale: Float) -> (Int, Int) {
        func even(_ value: Float) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Float(width) * scale), even(Float(height) * scale))
    }

    #if canImport(MetalFX)
    private func ensureMetalInfrastructure() -> String? {
        if device != nil, commandQueue != nil, convertPipeline != nil, textureCache != nil {
            return nil
        }
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            return "Metal device unavailable"
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(metalDevice) else {
            return "MetalFX unsupported"
        }
        guard let queue = metalDevice.makeCommandQueue() else {
            return "Metal queue unavailable"
        }
        guard let library = try? metalDevice.makeLibrary(source: nv12ToBGRAMetalSource, options: nil),
              let function = library.makeFunction(name: "nv12ToBGRA"),
              let pipeline = try? metalDevice.makeComputePipelineState(function: function) else {
            return "Metal pipeline failed"
        }
        var cacheOut: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cacheOut)
        guard status == kCVReturnSuccess, let cache = cacheOut else {
            return "Metal texture cache failed"
        }
        device = metalDevice
        commandQueue = queue
        convertPipeline = pipeline
        textureCache = cache
        return nil
    }

    private func configureScaler(width: Int, height: Int, output: (Int, Int)) -> String? {
        guard let device else { return "Metal device unavailable" }
        guard let createdScaler = Self.makeScaler(
            device: device, width: width, height: height, output: output
        ) else {
            return "MetalFX scaler init failed"
        }
        let outWidth = createdScaler.outputWidth
        let outHeight = createdScaler.outputHeight

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        inputDesc.storageMode = .private
        inputDesc.usage = createdScaler.colorTextureUsage.union([.shaderWrite, .shaderRead])

        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outWidth, height: outHeight, mipmapped: false
        )
        outputDesc.storageMode = .private
        outputDesc.usage = createdScaler.outputTextureUsage.union([.shaderRead])

        guard let inTex = device.makeTexture(descriptor: inputDesc),
              let outTex = device.makeTexture(descriptor: outputDesc),
              let pool = Self.makeBGRAOutputPool(width: outWidth, height: outHeight) else {
            return "MetalFX textures alloc failed"
        }

        scaler = createdScaler
        inputRGBATexture = inTex
        privateOutputTexture = outTex
        outputPool = pool
        configuredOutput = output
        return nil
    }

    private static func makeScaler(
        device: MTLDevice, width: Int, height: Int, output: (Int, Int)
    ) -> MTLFXSpatialScaler? {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.colorProcessingMode = .perceptual
        descriptor.outputWidth = output.0
        descriptor.outputHeight = output.1
        if let scaler = descriptor.makeSpatialScaler(device: device) { return scaler }
        // Fallback if a fractional ratio is rejected: largest integer scale that fits.
        let ratio = Float(output.0) / Float(max(1, width))
        for scale in [4, 3, 2] where Float(scale) <= max(2, ratio.rounded(.down)) {
            descriptor.outputWidth = width * scale
            descriptor.outputHeight = height * scale
            if let scaler = descriptor.makeSpatialScaler(device: device) { return scaler }
        }
        return nil
    }

    private func runUpscalePass(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) async -> VideoEnhancementBackendOutcome {
        guard let commandQueue, let textureCache, let outputPool, let scaler,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return .bypassed(reason: "MetalFX not configured")
        }
        let destBuffer: CVPixelBuffer
        do throws(VideoSuperResolutionPool.Failure) {
            destBuffer = try outputPool.allocate()
        } catch {
            return .bypassed(reason: error.isBusy ? error.reason : "BGRA output alloc failed")
        }
        let outSize = (scaler.outputWidth, scaler.outputHeight)
        guard let outputCVTexture = Self.makeCVTexture(
            cache: textureCache, buffer: destBuffer, format: .bgra8Unorm, size: outSize, plane: 0
        ), let outputMetalTexture = CVMetalTextureGetTexture(outputCVTexture) else {
            return .bypassed(reason: "Output Metal texture failed")
        }
        guard let retainedInputs = encodeInputToBGRA(
            commandBuffer: commandBuffer, pixelBuffer: pixelBuffer, size: (width, height)
        ) else {
            return .bypassed(reason: "Input texture bind failed")
        }
        guard encodeScaleAndBlit(
            commandBuffer: commandBuffer,
            inputSize: (width, height),
            outputSize: outSize,
            destination: outputMetalTexture
        ) else {
            return .bypassed(reason: "MetalFX encode failed")
        }

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: buffer.status == .completed)
            }
            commandBuffer.commit()
        }
        withExtendedLifetime((retainedInputs, outputCVTexture)) {}
        guard succeeded else { return .bypassed(reason: "MetalFX GPU error") }
        ScaledVideoOutputMetadata.copy(from: pixelBuffer, to: destBuffer, colorSpace: .rgbConverted)
        return .processed(destBuffer)
    }

    private func encodeInputToBGRA(
        commandBuffer: MTLCommandBuffer,
        pixelBuffer: CVPixelBuffer,
        size: (Int, Int)
    ) -> [CVMetalTexture]? {
        guard let textureCache, let inputRGBATexture, let convertPipeline else { return nil }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat == kCVPixelFormatType_32BGRA {
            guard let bgraCV = Self.makeCVTexture(
                cache: textureCache, buffer: pixelBuffer, format: .bgra8Unorm, size: size, plane: 0
            ), let bgraTex = CVMetalTextureGetTexture(bgraCV),
            let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(
                from: bgraTex, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: size.0, height: size.1, depth: 1),
                to: inputRGBATexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            return [bgraCV]
        }

        let chromaSize = (max(1, size.0 / 2), max(1, size.1 / 2))
        guard let yCV = Self.makeCVTexture(
            cache: textureCache, buffer: pixelBuffer, format: .r8Unorm, size: size, plane: 0
        ), let cbcrCV = Self.makeCVTexture(
            cache: textureCache, buffer: pixelBuffer, format: .rg8Unorm, size: chromaSize, plane: 1
        ), let yTex = CVMetalTextureGetTexture(yCV),
        let cbcrTex = CVMetalTextureGetTexture(cbcrCV),
        let compute = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var params = NV12ConvertParams(
            fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0,
            colorMatrix: Self.colorMatrixIndex(for: pixelBuffer, width: size.0, height: size.1)
        )
        compute.setComputePipelineState(convertPipeline)
        compute.setTexture(yTex, index: 0)
        compute.setTexture(cbcrTex, index: 1)
        compute.setTexture(inputRGBATexture, index: 2)
        compute.setBytes(&params, length: MemoryLayout<NV12ConvertParams>.size, index: 0)
        let tgW = min(16, convertPipeline.threadExecutionWidth)
        let tgH = min(16, max(1, convertPipeline.maxTotalThreadsPerThreadgroup / tgW))
        let tgSize = MTLSize(width: tgW, height: tgH, depth: 1)
        let gridSize = MTLSize(
            width: (size.0 + tgW - 1) / tgW, height: (size.1 + tgH - 1) / tgH, depth: 1
        )
        compute.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
        compute.endEncoding()
        return [yCV, cbcrCV]
    }

    private static func colorMatrixIndex(for pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> UInt32 {
        if let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) {
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
                || CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
                return 1
            }
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
                return 2
            }
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
                return 0
            }
        }
        return (width <= 720 && height <= 576) ? 1 : 0
    }

    private func encodeScaleAndBlit(
        commandBuffer: MTLCommandBuffer,
        inputSize: (Int, Int),
        outputSize: (Int, Int),
        destination: MTLTexture
    ) -> Bool {
        guard let scaler, let inputRGBATexture, let privateOutputTexture else { return false }
        scaler.colorTexture = inputRGBATexture
        scaler.inputContentWidth = inputSize.0
        scaler.inputContentHeight = inputSize.1
        scaler.outputTexture = privateOutputTexture
        scaler.encode(commandBuffer: commandBuffer)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.copy(
            from: privateOutputTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: outputSize.0, height: outputSize.1, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        return true
    }

    private static func makeCVTexture(
        cache: CVMetalTextureCache,
        buffer: CVPixelBuffer,
        format: MTLPixelFormat,
        size: (Int, Int),
        plane: Int
    ) -> CVMetalTexture? {
        var textureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format, size.0, size.1, plane, &textureOut
        )
        return status == kCVReturnSuccess ? textureOut : nil
    }

    private static func makeBGRAOutputPool(width: Int, height: Int) -> VideoSuperResolutionPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        return try? VideoSuperResolutionPool(
            attributes: attrs as CFDictionary, label: "MetalFX destination", followsDisplayLookahead: true
        )
    }
    #endif
}

enum VideoEnhancementBackendOutcome {
    case processed(CVPixelBuffer)
    case bypassed(reason: String)
}

enum VideoSuperResolutionRasterBudget {
    private static let longestEdge = 3840
    private static let pixelCount = 3840 * 2160

    static func contains(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && max(width, height) <= longestEdge && width * height <= pixelCount
    }
}

struct VideoSuperResolutionPool {
    struct Failure: Error {
        let reason: String
        var isBusy = false
    }

    private let pool: CVPixelBufferPool
    private let label: String
    private let limit: Int
    private let followsDisplayLookahead: Bool
    private let isCompatible: (CVPixelBuffer) -> Bool

    /// - Parameter followsDisplayLookahead: destination pools whose buffers wait in the display
    ///   queue; their limit tracks `VideoEnhancementPoolLimits` so deeper lookahead doesn't starve them.
    init(
        attributes: CFDictionary, label: String, limit: Int = 8, followsDisplayLookahead: Bool = false,
        isCompatible: @escaping (CVPixelBuffer) -> Bool = { _ in true }
    ) throws(Failure) {
        var result: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &result)
        guard status == kCVReturnSuccess, let result else {
            throw Failure(reason: "\(label) pool unavailable (\(status))")
        }
        pool = result
        self.label = label
        self.limit = limit
        self.followsDisplayLookahead = followsDisplayLookahead
        self.isCompatible = isCompatible
    }

    func allocate() throws(Failure) -> CVPixelBuffer {
        let threshold = followsDisplayLookahead ? max(limit, VideoEnhancementPoolLimits.superResolutionFrames) : limit
        let allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: threshold] as CFDictionary
        var result: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, allocationAttributes, &result
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw Failure(reason: "\(label) pool busy", isBusy: true)
        }
        guard status == kCVReturnSuccess, let result else {
            throw Failure(reason: "\(label) buffer unavailable (\(status))")
        }
        guard isCompatible(result) else { throw Failure(reason: "\(label) buffer layout unsupported") }
        return result
    }
}
