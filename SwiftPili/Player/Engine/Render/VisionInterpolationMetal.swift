import CoreVideo
import Foundation
import Metal

struct VisionInterpolationSetupFailure: Error {
    let stage: String
    let status: Int?

    init(stage: String, status: Int? = nil) {
        self.stage = stage
        self.status = status
    }

    var reason: String {
        let detail = status.map { " status=\($0)" } ?? ""
        return "Vision FI setup \(stage)\(detail)"
    }
}

struct VisionInterpolationFormat: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let chromaOffset: SIMD2<Float>

    var isBGRA: Bool { pixelFormat == kCVPixelFormatType_32BGRA }
    var analysisMode: Float {
        if isBGRA { return 0 }
        return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 2 : 1
    }

    init?(_ buffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard width > 0, height > 0, VideoEnhancementGuardrails.isSDR8Bit(buffer),
              VideoFramePairFormat.interpolationBypassReason(buffer) == nil else { return nil }
        if pixelFormat == kCVPixelFormatType_32BGRA {
            guard !CVPixelBufferIsPlanar(buffer) else { return nil }
            chromaOffset = .zero
        } else {
            guard width.isMultiple(of: 2), height.isMultiple(of: 2),
                  CVPixelBufferGetPlaneCount(buffer) == 2,
                  CVPixelBufferGetWidthOfPlane(buffer, 0) == width,
                  CVPixelBufferGetHeightOfPlane(buffer, 0) == height,
                  CVPixelBufferGetWidthOfPlane(buffer, 1) == width / 2,
                  CVPixelBufferGetHeightOfPlane(buffer, 1) == height / 2,
                  let offset = Self.chromaSiting(buffer) else { return nil }
            chromaOffset = offset / SIMD2<Float>(Float(width), Float(height))
        }
    }

    private static func chromaSiting(_ buffer: CVPixelBuffer) -> SIMD2<Float>? {
        guard let location = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) else {
            return .zero
        }
        return [
            kCVImageBufferChromaLocation_Center: SIMD2<Float>.zero,
            kCVImageBufferChromaLocation_Left: SIMD2(-0.5, 0),
            kCVImageBufferChromaLocation_TopLeft: SIMD2(-0.5, -0.5),
            kCVImageBufferChromaLocation_Top: SIMD2(0, -0.5),
            kCVImageBufferChromaLocation_BottomLeft: SIMD2(-0.5, 0.5),
            kCVImageBufferChromaLocation_Bottom: SIMD2(0, 0.5)
        ].first { CFEqual(location, $0.key) }?.value
    }
}

final class VisionInterpolationMetal {
    fileprivate struct Texture {
        let metal: any MTLTexture
        let bridge: CVMetalTexture
    }

    struct Pair {
        fileprivate let previous: [Texture]
        fileprivate let current: [Texture]
        let previousAnalysis: CVPixelBuffer
        let currentAnalysis: CVPixelBuffer
        fileprivate let analysisTextures: [Texture]
    }

    let format: VisionInterpolationFormat
    private let queue: any MTLCommandQueue
    private let preparePipeline: any MTLComputePipelineState
    private let validatePipeline: any MTLComputePipelineState
    private let synthesisPipeline: any MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let outputPool: CVPixelBufferPool
    private let analysisPool: CVPixelBufferPool
    private let forwardTexture: any MTLTexture
    private let backwardTexture: any MTLTexture
    private let validationBuffer: any MTLBuffer
    private let analysisWidth: Int
    private let analysisHeight: Int

    private static let validationWidth = 32
    private static let validationHeight = 24

    init(format: VisionInterpolationFormat) throws {
        self.format = format
        let analysisScale = min(1, 480 / Double(max(format.width, format.height)))
        analysisWidth = Int(Double(format.width) * analysisScale)
        analysisHeight = Int(Double(format.height) * analysisScale)
        guard min(analysisWidth, analysisHeight) >= 16 else {
            throw VisionInterpolationSetupFailure(stage: "analysis dimensions too small")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VisionInterpolationSetupFailure(stage: "Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw VisionInterpolationSetupFailure(stage: "Metal command queue unavailable")
        }
        guard let library = device.makeDefaultLibrary() else {
            throw VisionInterpolationSetupFailure(stage: "default Metal library unavailable")
        }
        self.queue = queue
        preparePipeline = try Self.makePipeline(named: "visionInterpolationPrepare", library: library, device: device)
        validatePipeline = try Self.makePipeline(named: "visionInterpolationValidate", library: library, device: device)
        synthesisPipeline = try Self.makePipeline(
            named: "visionInterpolationSynthesize", library: library, device: device
        )
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess else {
            throw VisionInterpolationSetupFailure(stage: "texture cache creation failed", status: Int(cacheStatus))
        }
        guard let cache else {
            throw VisionInterpolationSetupFailure(stage: "texture cache missing result", status: Int(cacheStatus))
        }
        self.cache = cache
        outputPool = try Self.makePool(width: format.width, height: format.height, pixelFormat: format.pixelFormat)
        analysisPool = try Self.makePool(
            width: analysisWidth, height: analysisHeight, pixelFormat: kCVPixelFormatType_32BGRA
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: analysisWidth, height: analysisHeight, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let validationLength = Self.validationWidth * Self.validationHeight * MemoryLayout<SIMD4<Float>>.stride
        guard let forward = device.makeTexture(descriptor: descriptor),
              let backward = device.makeTexture(descriptor: descriptor) else {
            throw VisionInterpolationSetupFailure(stage: "flow texture allocation failed")
        }
        guard let validation = device.makeBuffer(length: validationLength, options: .storageModeShared) else {
            throw VisionInterpolationSetupFailure(stage: "validation buffer allocation failed")
        }
        forwardTexture = forward
        backwardTexture = backward
        validationBuffer = validation
    }

    private static func makePipeline(
        named name: String, library: any MTLLibrary, device: any MTLDevice
    ) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw VisionInterpolationSetupFailure(stage: "missing shader \(name)")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw VisionInterpolationSetupFailure(stage: "compute pipeline \(name)", status: (error as NSError).code)
        }
    }

    func flushTextures() { CVMetalTextureCacheFlush(cache, 0) }

    func allocateOutput(phaseCount: Int) throws -> CVPixelBuffer {
        try Self.allocate(from: outputPool, limit: VideoFrameInterpolationPlan.outputPoolLimit(phaseCount: phaseCount))
    }

    func makePair(previous: CVPixelBuffer, current: CVPixelBuffer) throws -> Pair {
        let previousAnalysis = try Self.allocate(from: analysisPool, limit: 2)
        let currentAnalysis = try Self.allocate(from: analysisPool, limit: 2)
        return try Pair(
            previous: mapPlanes(previous, usage: .shaderRead),
            current: mapPlanes(current, usage: .shaderRead),
            previousAnalysis: previousAnalysis, currentAnalysis: currentAnalysis,
            analysisTextures: [previousAnalysis, currentAnalysis].map {
                try map($0, pixelFormat: .bgra8Unorm, size: (analysisWidth, analysisHeight),
                        plane: 0, usage: [.shaderRead, .shaderWrite])
            }
        )
    }

    func prepareAnalysis(_ pair: Pair) async throws {
        let (command, encoder) = try beginCommand(label: "Vision FI analysis")
        encoder.setComputePipelineState(preparePipeline)
        var parameters = SIMD4<Float>(format.chromaOffset.x, format.chromaOffset.y, format.analysisMode, 0)
        encoder.setBytes(&parameters, length: MemoryLayout.size(ofValue: parameters), index: 0)
        for (planes, analysis) in zip([pair.previous, pair.current], pair.analysisTextures) {
            encoder.setTexture(planes[0].metal, index: 0)
            encoder.setTexture(planes.last?.metal, index: 1)
            encoder.setTexture(analysis.metal, index: 2)
            Self.dispatch(encoder, pipeline: preparePipeline, width: analysisWidth, height: analysisHeight)
        }
        encoder.endEncoding()
        try await Self.run(command, retaining: pair.previous + pair.current + pair.analysisTextures)
    }

    func validateMotion(input: Pair) async throws -> Float {
        let (command, encoder) = try beginCommand(label: "Vision FI flow validation")
        encoder.setComputePipelineState(validatePipeline)
        encoder.setTexture(input.analysisTextures[0].metal, index: 0)
        encoder.setTexture(input.analysisTextures[1].metal, index: 1)
        encoder.setTexture(forwardTexture, index: 2)
        encoder.setTexture(backwardTexture, index: 3)
        encoder.setBuffer(validationBuffer, offset: 0, index: 0)
        var grid = SIMD2<UInt32>(UInt32(Self.validationWidth), UInt32(Self.validationHeight))
        encoder.setBytes(&grid, length: MemoryLayout.size(ofValue: grid), index: 1)
        Self.dispatch(encoder, pipeline: validatePipeline, width: Self.validationWidth, height: Self.validationHeight)
        encoder.endEncoding()
        try await Self.run(command, retaining: input.analysisTextures)
        return try motionVerticalSign()
    }

    func synthesize(
        _ input: Pair,
        verticalSign: Float,
        outputs: [(phase: Float, buffer: CVPixelBuffer)],
        checkBudget: @Sendable () throws -> Void
    ) async throws {
        let mappedOutputs = try outputs.map { output in
            try checkBudget()
            return (phase: output.phase, planes: try mapPlanes(output.buffer, usage: .shaderWrite))
        }
        let (command, encoder) = try beginCommand(label: "Vision FI phase synthesis")
        encoder.setComputePipelineState(synthesisPipeline)
        encoder.setTexture(forwardTexture, index: 3)
        encoder.setTexture(backwardTexture, index: 4)
        encoder.setTexture(input.analysisTextures[0].metal, index: 5)
        encoder.setTexture(input.analysisTextures[1].metal, index: 6)
        for output in mappedOutputs {
            for (index, plane) in output.planes.enumerated() {
                let offset = index == 0 ? .zero : format.chromaOffset
                var parameters = SIMD4<Float>(offset.x, offset.y, verticalSign, output.phase)
                encoder.setBytes(&parameters, length: MemoryLayout.size(ofValue: parameters), index: 0)
                encoder.setTexture(input.previous[index].metal, index: 0)
                encoder.setTexture(input.current[index].metal, index: 1)
                encoder.setTexture(plane.metal, index: 2)
                Self.dispatch(
                    encoder, pipeline: synthesisPipeline, width: plane.metal.width, height: plane.metal.height
                )
            }
        }
        encoder.endEncoding()
        let textures = input.previous + input.current + input.analysisTextures + mappedOutputs.flatMap { $0.planes }
        try checkBudget()
        try await Self.run(command, retaining: textures)
    }

    private func motionVerticalSign() throws -> Float {
        let count = Self.validationWidth * Self.validationHeight
        let samples = validationBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var totals = SIMD4<Float>.zero
        for index in 0..<count { totals += samples[index] }
        let average = totals / Float(count)
        let topDownScore = average.x + (1 - average.y) * 0.25
        let bottomUpScore = average.z + (1 - average.w) * 0.25
        let topDown = topDownScore <= bottomUpScore
        let residual = topDown ? average.x : average.z
        let validFraction = topDown ? average.y : average.w
        guard residual.isFinite, residual < 0.13 else { throw VisionInterpolationFailure.sceneCut }
        guard validFraction >= 0.65 else { throw VisionInterpolationFailure.inconsistent }
        return topDown ? 1 : -1
    }

    func uploadFlow(_ buffer: CVPixelBuffer, forward: Bool) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_TwoComponent16Half,
              CVPixelBufferGetWidth(buffer) == analysisWidth, CVPixelBufferGetHeight(buffer) == analysisHeight,
              !CVPixelBufferIsPlanar(buffer), CVPixelBufferGetBytesPerRow(buffer) >= analysisWidth * 4,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw VisionInterpolationFailure.flowLayout
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw VisionInterpolationFailure.flowLayout }
        let texture = forward ? forwardTexture : backwardTexture
        texture.replace(
            region: MTLRegionMake2D(0, 0, analysisWidth, analysisHeight), mipmapLevel: 0,
            withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        )
    }

    private func mapPlanes(_ buffer: CVPixelBuffer, usage: MTLTextureUsage) throws -> [Texture] {
        let luma = try map(buffer, pixelFormat: format.isBGRA ? .bgra8Unorm : .r8Unorm,
                           size: (format.width, format.height), plane: 0, usage: usage)
        if format.isBGRA { return [luma] }
        let chroma = try map(buffer, pixelFormat: .rg8Unorm, size: (format.width / 2, format.height / 2),
                             plane: 1, usage: usage)
        return [luma, chroma]
    }

    private func map(
        _ buffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, size: (width: Int, height: Int),
        plane: Int, usage: MTLTextureUsage
    ) throws -> Texture {
        var bridge: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, attributes, pixelFormat, size.width, size.height, plane, &bridge
        )
        guard status == kCVReturnSuccess, let bridge, let texture = CVMetalTextureGetTexture(bridge),
              texture.usage.contains(usage) else { throw VisionInterpolationFailure.texture }
        return Texture(metal: texture, bridge: bridge)
    }

    private func beginCommand(label: String) throws -> (any MTLCommandBuffer, any MTLComputeCommandEncoder) {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw VisionInterpolationFailure.gpu
        }
        command.label = label
        return (command, encoder)
    }

    private static func dispatch(
        _ encoder: any MTLComputeCommandEncoder, pipeline: any MTLComputePipelineState, width: Int, height: Int
    ) {
        let threads = pipeline.threadExecutionWidth
        let rows = min(8, pipeline.maxTotalThreadsPerThreadgroup / threads)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threads, height: rows, depth: 1))
    }

    private static func run(_ command: any MTLCommandBuffer, retaining textures: [Texture]) async throws {
        defer { withExtendedLifetime(textures) {} }
        let completed = await withCheckedContinuation { continuation in
            command.addCompletedHandler { continuation.resume(returning: $0.status == .completed) }
            command.commit()
        }
        guard completed else { throw VisionInterpolationFailure.gpu }
    }

    private static func makePool(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height, kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw VisionInterpolationFailure.pool }
        return pool
    }

    private static func allocate(from pool: CVPixelBufferPool, limit: Int) throws -> CVPixelBuffer {
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey: limit] as CFDictionary
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, attributes, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { throw VisionInterpolationFailure.poolBusy }
        guard status == kCVReturnSuccess, let buffer else { throw VisionInterpolationFailure.pool }
        return buffer
    }
}
