import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

private let videoEnhancementMetalSource = """
#include <metal_stdlib>
using namespace metal;

struct NV12ConvertParams {
    uint fullRange;
    uint colorMatrix; // 0 = BT.709, 1 = BT.601, 2 = BT.2020
    float chromaOffsetX;
    float chromaOffsetY;
};

struct NV12RangeConvertParams {
    uint fullToVideo; // 1 = 420f -> 420v, 0 = 420v -> 420f
};

struct RCASParams {
    float strength;
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
    // MPEG-2 / H.264 / HEVC / AV1 default left-sited 4:2:0 uses chromaOffset = (1.0, 0.5)
    // so even columns co-site exactly with chroma texel centers (i + 0.5) / (W / 2) = (2*i + 1) / W.
    float2 uv = (float2(gid) + float2(params.chromaOffsetX, params.chromaOffsetY)) / float2(width, height);
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

kernel void nv12RangeConvertY(
    texture2d<float, access::read> inY [[texture(0)]],
    texture2d<float, access::write> outY [[texture(1)]],
    constant NV12RangeConvertParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) {
        return;
    }
    float y = inY.read(gid).r;
    float converted = params.fullToVideo != 0
        ? clamp(y * (219.0f / 255.0f) + (16.0f / 255.0f), 0.0f, 1.0f)
        : clamp((y - (16.0f / 255.0f)) * (255.0f / 219.0f), 0.0f, 1.0f);
    outY.write(float4(converted, 0.0f, 0.0f, 1.0f), gid);
}

kernel void nv12RangeConvertCbCr(
    texture2d<float, access::read> inCbCr [[texture(0)]],
    texture2d<float, access::write> outCbCr [[texture(1)]],
    constant NV12RangeConvertParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outCbCr.get_width() || gid.y >= outCbCr.get_height()) {
        return;
    }
    float2 cbcr = inCbCr.read(gid).rg;
    const float2 center = float2(128.0f / 255.0f);
    float2 converted = params.fullToVideo != 0
        ? clamp((cbcr - center) * (224.0f / 255.0f) + center, 0.0f, 1.0f)
        : clamp((cbcr - center) * (255.0f / 224.0f) + center, 0.0f, 1.0f);
    outCbCr.write(float4(converted.x, converted.y, 0.0f, 1.0f), gid);
}

// AMD FidelityFX RCAS-style 5-tap contrast-adaptive sharpening with anti-ringing clamping
// and isolated compression-speckle attenuation.
kernel void rcasSharpen(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant RCASParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    uint maxX = inTexture.get_width() - 1;
    uint maxY = inTexture.get_height() - 1;
    uint cx = min(gid.x, maxX);
    uint cy = min(gid.y, maxY);

    float4 centerSample = inTexture.read(uint2(cx, cy));
    float3 c = centerSample.rgb;
    float3 n = inTexture.read(uint2(cx, cy > 0 ? cy - 1 : 0)).rgb;
    float3 s = inTexture.read(uint2(cx, min(cy + 1, maxY))).rgb;
    float3 w = inTexture.read(uint2(cx > 0 ? cx - 1 : 0, cy)).rgb;
    float3 e = inTexture.read(uint2(min(cx + 1, maxX), cy)).rgb;

    float3 mn4 = min(min(n, s), min(w, e));
    float3 mx4 = max(max(n, s), max(w, e));
    float3 mn5 = min(mn4, c);
    float3 mx5 = max(mx4, c);

    // Per-channel anti-ringing limits merged to a single RGB lobe to avoid chroma fringes.
    float3 hitMin = mn5 / max(4.0f * mx4, float3(1e-5f));
    float3 hitMax = (1.0f - mx5) / min(4.0f * mn4 - 4.0f, float3(-1e-5f));
    float3 lobeRGB = max(-hitMin, hitMax);
    float lobe = max(-0.1875f, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0f));

    // Gently attenuate sharpening on isolated 1px compression speckles while preserving edges.
    float cL = 0.25f * c.r + 0.5f * c.g + 0.25f * c.b;
    float nL = 0.25f * n.r + 0.5f * n.g + 0.25f * n.b;
    float sL = 0.25f * s.r + 0.5f * s.g + 0.25f * s.b;
    float wL = 0.25f * w.r + 0.5f * w.g + 0.25f * w.b;
    float eL = 0.25f * e.r + 0.5f * e.g + 0.25f * e.b;
    float nz = 0.25f * (nL + sL + wL + eL) - cL;
    float rangeL = max(max(max(nL, sL), max(wL, eL)), cL) - min(min(min(nL, sL), min(wL, eL)), cL);
    float denoise = -0.5f * clamp(abs(nz) / max(rangeL, 1e-4f), 0.0f, 1.0f) + 1.0f;

    float weight = lobe * denoise * params.strength;
    float3 sharpened = (c + weight * (n + s + w + e)) / (1.0f + 4.0f * weight);
    float3 result = clamp(sharpened, mn5, mx5);
    outTexture.write(float4(result, centerSample.a), gid);
}
"""

private struct NV12ConvertParams {
    var fullRange: UInt32
    var colorMatrix: UInt32
    var chromaOffsetX: Float
    var chromaOffsetY: Float
}

private struct NV12RangeConvertParams {
    var fullToVideo: UInt32
}

private struct RCASParams {
    var strength: Float
}

/// Shared GPU pixel-format converter used by both MetalFX Spatial (NV12→BGRA input preparation)
/// and VideoToolbox ML SR (cross-format staging such as 420v/420f→32BGRA and 420f↔420v).
final class MetalNV12PixelConverter {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var nv12ToBGRAPipeline: MTLComputePipelineState?
    private var rangeYPipeline: MTLComputePipelineState?
    private var rangeCbCrPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

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
        textureCache = nil
        nv12ToBGRAPipeline = nil
        rangeYPipeline = nil
        rangeCbCrPipeline = nil
        commandQueue = nil
        device = nil
    }

    /// Converts `source` into `destination` on the GPU (supports NV12→BGRA, 420f↔420v, and BGRA→BGRA).
    func convert(from source: CVPixelBuffer, to destination: CVPixelBuffer) async -> Bool {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0,
              width == CVPixelBufferGetWidth(destination),
              height == CVPixelBufferGetHeight(destination),
              ensureInfrastructure(),
              let commandQueue, let textureCache,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        let srcFormat = CVPixelBufferGetPixelFormatType(source)
        let dstFormat = CVPixelBufferGetPixelFormatType(destination)
        let size = (width, height)
        let retained: [CVMetalTexture]

        if Self.isNV12(srcFormat), dstFormat == kCVPixelFormatType_32BGRA {
            guard let textures = encodeNV12ToBGRA(
                commandBuffer: commandBuffer, cache: textureCache,
                source: source, destination: destination, size: size
            ) else { return false }
            retained = textures
        } else if Self.isNV12(srcFormat), Self.isNV12(dstFormat), srcFormat != dstFormat {
            guard let textures = encodeNV12RangeConvert(
                commandBuffer: commandBuffer, cache: textureCache,
                source: source, destination: destination, size: size,
                fullToVideo: srcFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ) else { return false }
            retained = textures
        } else if srcFormat == kCVPixelFormatType_32BGRA, dstFormat == kCVPixelFormatType_32BGRA {
            guard let srcCV = Self.makeCVTexture(
                cache: textureCache, buffer: source, format: .bgra8Unorm, size: size, plane: 0
            ), let dstCV = Self.makeCVTexture(
                cache: textureCache, buffer: destination, format: .bgra8Unorm, size: size, plane: 0
            ), let srcTex = CVMetalTextureGetTexture(srcCV),
            let dstTex = CVMetalTextureGetTexture(dstCV),
            let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
            blit.copy(
                from: srcTex, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: dstTex, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            retained = [srcCV, dstCV]
        } else {
            return false
        }

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: buffer.status == .completed)
            }
            commandBuffer.commit()
        }
        withExtendedLifetime(retained) {}
        return succeeded
    }

    private func ensureInfrastructure() -> Bool {
        if device != nil, commandQueue != nil, nv12ToBGRAPipeline != nil,
           rangeYPipeline != nil, rangeCbCrPipeline != nil, textureCache != nil {
            return true
        }
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let queue = metalDevice.makeCommandQueue(),
              let library = try? metalDevice.makeLibrary(source: videoEnhancementMetalSource, options: nil),
              let bgraFn = library.makeFunction(name: "nv12ToBGRA"),
              let yFn = library.makeFunction(name: "nv12RangeConvertY"),
              let cbcrFn = library.makeFunction(name: "nv12RangeConvertCbCr"),
              let bgraPipe = try? metalDevice.makeComputePipelineState(function: bgraFn),
              let yPipe = try? metalDevice.makeComputePipelineState(function: yFn),
              let cbcrPipe = try? metalDevice.makeComputePipelineState(function: cbcrFn) else {
            return false
        }
        var cacheOut: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cacheOut) == kCVReturnSuccess,
              let cache = cacheOut else {
            return false
        }
        device = metalDevice
        commandQueue = queue
        nv12ToBGRAPipeline = bgraPipe
        rangeYPipeline = yPipe
        rangeCbCrPipeline = cbcrPipe
        textureCache = cache
        return true
    }

    private func encodeNV12ToBGRA(
        commandBuffer: MTLCommandBuffer,
        cache: CVMetalTextureCache,
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        size: (Int, Int)
    ) -> [CVMetalTexture]? {
        guard let nv12ToBGRAPipeline else { return nil }
        let chromaSize = (max(1, size.0 / 2), max(1, size.1 / 2))
        guard let yCV = Self.makeCVTexture(cache: cache, buffer: source, format: .r8Unorm, size: size, plane: 0),
              let cbcrCV = Self.makeCVTexture(
                cache: cache, buffer: source, format: .rg8Unorm, size: chromaSize, plane: 1
              ),
              let outCV = Self.makeCVTexture(
                cache: cache, buffer: destination, format: .bgra8Unorm, size: size, plane: 0
              ),
              let yTex = CVMetalTextureGetTexture(yCV),
              let cbcrTex = CVMetalTextureGetTexture(cbcrCV),
              let outTex = CVMetalTextureGetTexture(outCV),
              outTex.usage.contains(.shaderWrite),
              let compute = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        let chromaOffset = Self.chromaOffset(for: source)
        var params = NV12ConvertParams(
            fullRange: CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ? 1 : 0,
            colorMatrix: Self.colorMatrixIndex(for: source, width: size.0, height: size.1),
            chromaOffsetX: chromaOffset.0,
            chromaOffsetY: chromaOffset.1
        )
        compute.setComputePipelineState(nv12ToBGRAPipeline)
        compute.setTexture(yTex, index: 0)
        compute.setTexture(cbcrTex, index: 1)
        compute.setTexture(outTex, index: 2)
        compute.setBytes(&params, length: MemoryLayout<NV12ConvertParams>.size, index: 0)
        Self.dispatchThreads(encoder: compute, pipeline: nv12ToBGRAPipeline, width: size.0, height: size.1)
        compute.endEncoding()
        return [yCV, cbcrCV, outCV]
    }

    private func encodeNV12RangeConvert(
        commandBuffer: MTLCommandBuffer,
        cache: CVMetalTextureCache,
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        size: (Int, Int),
        fullToVideo: Bool
    ) -> [CVMetalTexture]? {
        guard let rangeYPipeline, let rangeCbCrPipeline else { return nil }
        let chromaSize = (max(1, size.0 / 2), max(1, size.1 / 2))
        guard let srcYCV = Self.makeCVTexture(cache: cache, buffer: source, format: .r8Unorm, size: size, plane: 0),
              let srcCbCrCV = Self.makeCVTexture(
                cache: cache, buffer: source, format: .rg8Unorm, size: chromaSize, plane: 1
              ),
              let dstYCV = Self.makeCVTexture(
                cache: cache, buffer: destination, format: .r8Unorm, size: size, plane: 0
              ),
              let dstCbCrCV = Self.makeCVTexture(
                cache: cache, buffer: destination, format: .rg8Unorm, size: chromaSize, plane: 1
              ),
              let srcYTex = CVMetalTextureGetTexture(srcYCV),
              let srcCbCrTex = CVMetalTextureGetTexture(srcCbCrCV),
              let dstYTex = CVMetalTextureGetTexture(dstYCV),
              let dstCbCrTex = CVMetalTextureGetTexture(dstCbCrCV),
              dstYTex.usage.contains(.shaderWrite), dstCbCrTex.usage.contains(.shaderWrite),
              let compute = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        var params = NV12RangeConvertParams(fullToVideo: fullToVideo ? 1 : 0)
        compute.setComputePipelineState(rangeYPipeline)
        compute.setTexture(srcYTex, index: 0)
        compute.setTexture(dstYTex, index: 1)
        compute.setBytes(&params, length: MemoryLayout<NV12RangeConvertParams>.size, index: 0)
        Self.dispatchThreads(encoder: compute, pipeline: rangeYPipeline, width: size.0, height: size.1)

        compute.setComputePipelineState(rangeCbCrPipeline)
        compute.setTexture(srcCbCrTex, index: 0)
        compute.setTexture(dstCbCrTex, index: 1)
        compute.setBytes(&params, length: MemoryLayout<NV12RangeConvertParams>.size, index: 0)
        Self.dispatchThreads(encoder: compute, pipeline: rangeCbCrPipeline, width: chromaSize.0, height: chromaSize.1)
        compute.endEncoding()
        return [srcYCV, srcCbCrCV, dstYCV, dstCbCrCV]
    }

    static func isNV12(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func colorMatrixIndex(for pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> UInt32 {
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

    /// Returns luma-grid chroma sampling offset `(offsetX, offsetY)` for normalized sampling
    /// `uv = (float2(gid) + offset) / float2(width, height)`. Defaults to MPEG-2 / H.264 / HEVC / AV1
    /// left-sited 4:2:0 `(1.0, 0.5)` so even luma columns align exactly with chroma texel centers.
    static func chromaOffset(for pixelBuffer: CVPixelBuffer) -> (Float, Float) {
        if let loc = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil) {
            if CFEqual(loc, kCVImageBufferChromaLocation_Center) {
                return (0.5, 0.5)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_TopLeft) {
                return (1.0, 1.0)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_Top) {
                return (0.5, 1.0)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_BottomLeft) {
                return (1.0, 0.0)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_Bottom) {
                return (0.5, 0.0)
            }
        }
        return (1.0, 0.5)
    }

    static func makeCVTexture(
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

    static func dispatchThreads(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let tgW = min(16, pipeline.threadExecutionWidth)
        let tgH = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / tgW))
        let tgSize = MTLSize(width: tgW, height: tgH, depth: 1)
        let gridSize = MTLSize(
            width: (width + tgW - 1) / tgW, height: (height + tgH - 1) / tgH, depth: 1
        )
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
    }
}

final class MetalFXSuperResolutionBackend {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var convertPipeline: MTLComputePipelineState?
    private var rcasPipeline: MTLComputePipelineState?
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
        rcasPipeline = nil
        commandQueue = nil
        device = nil
        configuredOutput = nil
    }

    /// - Parameters:
    ///   - maxScale: may be fractional in Auto mode; the caller caps it to the on-screen
    ///     magnification so output never exceeds the display's pixel size.
    ///   - targetDimensions: explicit output dimensions (even, within raster budget) when the user
    ///     configured a manual MetalFX target resolution; bypasses the Auto magnification floor.
    ///   - sharpness: AMD RCAS contrast-adaptive sharpening strength applied during the output pass.
    func upscale(
        pixelBuffer: CVPixelBuffer,
        maxScale: Float = 2,
        targetDimensions: VideoSuperResolutionDimensions? = nil,
        sharpness: VideoSuperResolutionSharpness = .standard
    ) async -> VideoEnhancementBackendOutcome {
        #if !canImport(MetalFX)
        return .bypassed(reason: "MetalFX unavailable")
        #else
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let output: (Int, Int)
        if let targetDimensions {
            guard targetDimensions.width > width, targetDimensions.height > height else {
                return .bypassed(reason: "Target resolution reached")
            }
            guard VideoSuperResolutionRasterBudget.contains(width: width, height: height),
                  VideoSuperResolutionRasterBudget.contains(
                    width: targetDimensions.width, height: targetDimensions.height
                  ) else {
                return .bypassed(reason: "MetalFX output exceeds raster budget")
            }
            output = (targetDimensions.width, targetDimensions.height)
        } else {
            guard maxScale.isFinite, maxScale >= VideoEnhancementDisplaySurface.minimumUsefulMagnification else {
                return .bypassed(reason: "Display resolution reached")
            }
            let scale = min(maxScale, 4)
            let candidates = [Self.evenSize(width, height, scale)]
                + [4, 3, 2].filter { Float($0) < scale }.map { (width * $0, height * $0) }
            guard VideoSuperResolutionRasterBudget.contains(width: width, height: height),
                  let resolved = candidates.first(where: {
                      VideoSuperResolutionRasterBudget.contains(width: $0.0, height: $0.1)
                  }) else {
                return .bypassed(reason: "MetalFX output exceeds raster budget")
            }
            output = resolved
        }
        if let setupReason = ensureMetalInfrastructure() {
            return .bypassed(reason: setupReason)
        }
        if scaler?.inputWidth != width || scaler?.inputHeight != height
            || configuredOutput?.width != output.0 || configuredOutput?.height != output.1,
           let configReason = configureScaler(width: width, height: height, output: output) {
            return .bypassed(reason: configReason)
        }
        return await runUpscalePass(
            pixelBuffer: pixelBuffer, width: width, height: height, sharpness: sharpness
        )
        #endif
    }

    private static func evenSize(_ width: Int, _ height: Int, _ scale: Float) -> (Int, Int) {
        func even(_ value: Float) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Float(width) * scale), even(Float(height) * scale))
    }

    #if canImport(MetalFX)
    private func ensureMetalInfrastructure() -> String? {
        if device != nil, commandQueue != nil, convertPipeline != nil, rcasPipeline != nil, textureCache != nil {
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
        guard let library = try? metalDevice.makeLibrary(source: videoEnhancementMetalSource, options: nil),
              let convertFunction = library.makeFunction(name: "nv12ToBGRA"),
              let rcasFunction = library.makeFunction(name: "rcasSharpen"),
              let convertPipe = try? metalDevice.makeComputePipelineState(function: convertFunction),
              let rcasPipe = try? metalDevice.makeComputePipelineState(function: rcasFunction) else {
            return "Metal pipeline failed"
        }
        var cacheOut: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cacheOut)
        guard status == kCVReturnSuccess, let cache = cacheOut else {
            return "Metal texture cache failed"
        }
        device = metalDevice
        commandQueue = queue
        convertPipeline = convertPipe
        rcasPipeline = rcasPipe
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
            let candidateWidth = width * scale
            let candidateHeight = height * scale
            guard VideoSuperResolutionRasterBudget.contains(
                width: candidateWidth, height: candidateHeight
            ) else { continue }
            descriptor.outputWidth = candidateWidth
            descriptor.outputHeight = candidateHeight
            if let scaler = descriptor.makeSpatialScaler(device: device) { return scaler }
        }
        return nil
    }

    private func runUpscalePass(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        sharpness: VideoSuperResolutionSharpness
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
        guard let outputCVTexture = MetalNV12PixelConverter.makeCVTexture(
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
            destination: outputMetalTexture,
            sharpness: sharpness
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
            guard let bgraCV = MetalNV12PixelConverter.makeCVTexture(
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
        guard let yCV = MetalNV12PixelConverter.makeCVTexture(
            cache: textureCache, buffer: pixelBuffer, format: .r8Unorm, size: size, plane: 0
        ), let cbcrCV = MetalNV12PixelConverter.makeCVTexture(
            cache: textureCache, buffer: pixelBuffer, format: .rg8Unorm, size: chromaSize, plane: 1
        ), let yTex = CVMetalTextureGetTexture(yCV),
        let cbcrTex = CVMetalTextureGetTexture(cbcrCV),
        let compute = commandBuffer.makeComputeCommandEncoder() else { return nil }

        let chromaOffset = MetalNV12PixelConverter.chromaOffset(for: pixelBuffer)
        var params = NV12ConvertParams(
            fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0,
            colorMatrix: MetalNV12PixelConverter.colorMatrixIndex(
                for: pixelBuffer, width: size.0, height: size.1
            ),
            chromaOffsetX: chromaOffset.0,
            chromaOffsetY: chromaOffset.1
        )
        compute.setComputePipelineState(convertPipeline)
        compute.setTexture(yTex, index: 0)
        compute.setTexture(cbcrTex, index: 1)
        compute.setTexture(inputRGBATexture, index: 2)
        compute.setBytes(&params, length: MemoryLayout<NV12ConvertParams>.size, index: 0)
        MetalNV12PixelConverter.dispatchThreads(
            encoder: compute, pipeline: convertPipeline, width: size.0, height: size.1
        )
        compute.endEncoding()
        return [yCV, cbcrCV]
    }

    private func encodeScaleAndBlit(
        commandBuffer: MTLCommandBuffer,
        inputSize: (Int, Int),
        outputSize: (Int, Int),
        destination: MTLTexture,
        sharpness: VideoSuperResolutionSharpness
    ) -> Bool {
        guard let scaler, let inputRGBATexture, let privateOutputTexture else { return false }
        scaler.colorTexture = inputRGBATexture
        scaler.inputContentWidth = inputSize.0
        scaler.inputContentHeight = inputSize.1
        scaler.outputTexture = privateOutputTexture
        scaler.encode(commandBuffer: commandBuffer)

        if sharpness.rcasStrength > 0.001, let rcasPipeline, destination.usage.contains(.shaderWrite) {
            guard let compute = commandBuffer.makeComputeCommandEncoder() else { return false }
            var params = RCASParams(strength: sharpness.rcasStrength)
            compute.setComputePipelineState(rcasPipeline)
            compute.setTexture(privateOutputTexture, index: 0)
            compute.setTexture(destination, index: 1)
            compute.setBytes(&params, length: MemoryLayout<RCASParams>.size, index: 0)
            MetalNV12PixelConverter.dispatchThreads(
                encoder: compute, pipeline: rcasPipeline, width: outputSize.0, height: outputSize.1
            )
            compute.endEncoding()
            return true
        }

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
    static let longestEdge = 3840
    static let pixelCount = 3840 * 2160

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
