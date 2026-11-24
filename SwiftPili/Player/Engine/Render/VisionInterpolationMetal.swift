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

    nonisolated(unsafe) private static let chromaSitingTable: [(CFString, SIMD2<Float>)] = [
        (kCVImageBufferChromaLocation_Left, SIMD2(-0.5, 0)),
        (kCVImageBufferChromaLocation_Center, .zero),
        (kCVImageBufferChromaLocation_TopLeft, SIMD2(-0.5, -0.5)),
        (kCVImageBufferChromaLocation_Top, SIMD2(0, -0.5)),
        (kCVImageBufferChromaLocation_BottomLeft, SIMD2(-0.5, 0.5)),
        (kCVImageBufferChromaLocation_Bottom, SIMD2(0, 0.5)),
    ]

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
        for (key, offset) in chromaSitingTable where CFEqual(location, key) {
            return offset
        }
        return nil
    }
}

final class VisionInterpolationMetal {
    fileprivate struct Texture {
        let metal: any MTLTexture
        let bridge: CVMetalTexture
    }

    struct FlowTexture {
        fileprivate let metal: any MTLTexture
        fileprivate let bridge: CVMetalTexture?
    }

    struct Pair {
        fileprivate let previous: [Texture]
        fileprivate let current: [Texture]
        fileprivate let currentSource: CVPixelBuffer
        let previousAnalysis: CVPixelBuffer
        let currentAnalysis: CVPixelBuffer
        fileprivate let analysisTextures: [Texture]
        fileprivate let needsPreviousAnalysis: Bool
    }

    let format: VisionInterpolationFormat
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let preparePipeline: any MTLComputePipelineState
    private let validatePipeline: any MTLComputePipelineState
    private let synthesisPipeline: any MTLComputePipelineState
    private let outputPool: CVPixelBufferPool
    private let analysisPool: CVPixelBufferPool
    private var fallbackForwardTexture: (any MTLTexture)?
    private var fallbackBackwardTexture: (any MTLTexture)?
    private var cachedAnalysis: (source: CVPixelBuffer, analysis: CVPixelBuffer)?
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

        let metal = VideoEnhancementMetalContext.shared
        let resources: VideoEnhancementMetalContext.Resources
        do {
            resources = try metal.resources()
            preparePipeline = try metal.pipeline(for: .visionInterpolationPrepare)
            validatePipeline = try metal.pipeline(for: .visionInterpolationValidate)
            synthesisPipeline = try metal.pipeline(for: .visionInterpolationSynthesize)
        } catch {
            throw VisionInterpolationSetupFailure(stage: error.stage, status: error.status)
        }
        device = resources.device
        queue = resources.commandQueue

        outputPool = try Self.makePool(width: format.width, height: format.height, pixelFormat: format.pixelFormat)
        analysisPool = try Self.makePool(
            width: analysisWidth, height: analysisHeight, pixelFormat: kCVPixelFormatType_32BGRA
        )
        let validationLength = Self.validationWidth * Self.validationHeight * MemoryLayout<SIMD4<Float>>.stride
        guard let validation = device.makeBuffer(length: validationLength, options: .storageModeShared) else {
            throw VisionInterpolationSetupFailure(stage: "validation buffer allocation failed")
        }
        validationBuffer = validation
    }

    func flushTextures() {
        cachedAnalysis = nil
        VideoEnhancementMetalContext.shared.flushTextureCache()
    }

    func allocateOutput(phaseCount: Int) throws -> CVPixelBuffer {
        try Self.allocate(from: outputPool, limit: VideoFrameInterpolationPlan.outputPoolLimit(phaseCount: phaseCount))
    }

    func makePair(previous: CVPixelBuffer, current: CVPixelBuffer) throws -> Pair {
        let reusedPrevious = cachedAnalysis.flatMap { $0.source === previous ? $0.analysis : nil }
        let previousAnalysis = try reusedPrevious ?? Self.allocate(from: analysisPool, limit: 3)
        let currentAnalysis = try Self.allocate(from: analysisPool, limit: 3)
        let previousAnalysisUsage: MTLTextureUsage = reusedPrevious == nil ? [.shaderRead, .shaderWrite] : .shaderRead
        return try Pair(
            previous: mapPlanes(previous, usage: .shaderRead),
            current: mapPlanes(current, usage: .shaderRead),
            currentSource: current,
            previousAnalysis: previousAnalysis,
            currentAnalysis: currentAnalysis,
            analysisTextures: [
                try map(
                    previousAnalysis, pixelFormat: .bgra8Unorm, size: (analysisWidth, analysisHeight),
                    plane: 0, usage: previousAnalysisUsage
                ),
                try map(
                    currentAnalysis, pixelFormat: .bgra8Unorm, size: (analysisWidth, analysisHeight),
                    plane: 0, usage: [.shaderRead, .shaderWrite]
                ),
            ],
            needsPreviousAnalysis: reusedPrevious == nil
        )
    }

    func prepareAnalysis(_ pair: Pair) async throws {
        let (command, encoder) = try beginCommand(label: "Vision FI analysis")
        encoder.setComputePipelineState(preparePipeline)
        var parameters = SIMD4<Float>(format.chromaOffset.x, format.chromaOffset.y, format.analysisMode, 0)
        encoder.setBytes(&parameters, length: MemoryLayout.size(ofValue: parameters), index: 0)

        var retained: [CVMetalTexture] = []
        if pair.needsPreviousAnalysis {
            encoder.setTexture(pair.previous[0].metal, index: 0)
            encoder.setTexture(pair.previous.last?.metal, index: 1)
            encoder.setTexture(pair.analysisTextures[0].metal, index: 2)
            Self.dispatch(encoder, pipeline: preparePipeline, width: analysisWidth, height: analysisHeight)
            retained.append(contentsOf: pair.previous.map(\.bridge))
            retained.append(pair.analysisTextures[0].bridge)
        }
        encoder.setTexture(pair.current[0].metal, index: 0)
        encoder.setTexture(pair.current.last?.metal, index: 1)
        encoder.setTexture(pair.analysisTextures[1].metal, index: 2)
        Self.dispatch(encoder, pipeline: preparePipeline, width: analysisWidth, height: analysisHeight)
        retained.append(contentsOf: pair.current.map(\.bridge))
        retained.append(pair.analysisTextures[1].bridge)

        encoder.endEncoding()
        try await Self.run(command, retaining: retained)
        cachedAnalysis = (source: pair.currentSource, analysis: pair.currentAnalysis)
    }

    /// Maps Vision's `kCVPixelFormatType_TwoComponent16Half` flow output directly to `.rg16Float`
    /// via zero-copy IOSurface `CVMetalTextureCache`, falling back to CPU `texture.replace` ONLY
    /// when `buffer` has no IOSurface backing.
    func bindFlow(_ buffer: CVPixelBuffer, forward: Bool) throws -> FlowTexture {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_TwoComponent16Half,
              CVPixelBufferGetWidth(buffer) == analysisWidth,
              CVPixelBufferGetHeight(buffer) == analysisHeight,
              !CVPixelBufferIsPlanar(buffer) else {
            throw VisionInterpolationFailure.flowLayout
        }
        if CVPixelBufferGetIOSurface(buffer) != nil,
           let mapped = VideoEnhancementMetalContext.shared.makeTexture(
            buffer: buffer,
            format: .rg16Float,
            width: analysisWidth,
            height: analysisHeight,
            plane: 0,
            usage: .shaderRead
           ) {
            return FlowTexture(metal: mapped.texture, bridge: mapped.bridge)
        }

        // Software fallback only when Vision produced a non-IOSurface pixel buffer.
        guard CVPixelBufferGetBytesPerRow(buffer) >= analysisWidth * 4,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw VisionInterpolationFailure.flowLayout
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VisionInterpolationFailure.flowLayout
        }
        let texture = try fallbackFlowTexture(forward: forward)
        texture.replace(
            region: MTLRegionMake2D(0, 0, analysisWidth, analysisHeight), mipmapLevel: 0,
            withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        )
        return FlowTexture(metal: texture, bridge: nil)
    }

    /// Runs lightweight 32×24 motion validation, allocates full-resolution output buffers only when
    /// flow passes scene-cut/consistency checks, and synthesizes all phases in one command buffer.
    func validateAndSynthesize(
        _ input: Pair,
        forwardFlow: FlowTexture,
        backwardFlow: FlowTexture,
        phases: [Float],
        currentBuffer: CVPixelBuffer,
        checkBudgetBeforeSynthesis: @Sendable () throws -> Void
    ) async throws -> [CVPixelBuffer] {
        let verticalSign = try await validateMotion(
            input: input, forwardFlow: forwardFlow, backwardFlow: backwardFlow
        )
        try checkBudgetBeforeSynthesis()

        let outputs = try phases.map { phase -> (phase: Float, buffer: CVPixelBuffer, planes: [Texture]) in
            let buffer = try allocateOutput(phaseCount: phases.count)
            guard VideoFramePairFormat.hasSameStorageFormat(currentBuffer, buffer) else {
                throw VisionInterpolationFailure.outputFormat
            }
            return (phase: phase, buffer: buffer, planes: try mapPlanes(buffer, usage: .shaderWrite))
        }

        let (command, encoder) = try beginCommand(label: "Vision FI phase synthesis")
        encoder.setComputePipelineState(synthesisPipeline)
        encoder.setTexture(forwardFlow.metal, index: 3)
        encoder.setTexture(backwardFlow.metal, index: 4)
        encoder.setTexture(input.analysisTextures[0].metal, index: 5)
        encoder.setTexture(input.analysisTextures[1].metal, index: 6)
        for output in outputs {
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

        var retained: [CVMetalTexture] = []
        retained.reserveCapacity(
            input.previous.count + input.current.count + input.analysisTextures.count
                + outputs.count * 2 + 2
        )
        retained.append(contentsOf: input.previous.map(\.bridge))
        retained.append(contentsOf: input.current.map(\.bridge))
        retained.append(contentsOf: input.analysisTextures.map(\.bridge))
        if let bridge = forwardFlow.bridge { retained.append(bridge) }
        if let bridge = backwardFlow.bridge { retained.append(bridge) }
        for output in outputs {
            retained.append(contentsOf: output.planes.map(\.bridge))
        }

        try await Self.run(command, retaining: retained)
        return outputs.map(\.buffer)
    }

    private func validateMotion(
        input: Pair,
        forwardFlow: FlowTexture,
        backwardFlow: FlowTexture
    ) async throws -> Float {
        let (command, encoder) = try beginCommand(label: "Vision FI flow validation")
        encoder.setComputePipelineState(validatePipeline)
        encoder.setTexture(input.analysisTextures[0].metal, index: 0)
        encoder.setTexture(input.analysisTextures[1].metal, index: 1)
        encoder.setTexture(forwardFlow.metal, index: 2)
        encoder.setTexture(backwardFlow.metal, index: 3)
        encoder.setBuffer(validationBuffer, offset: 0, index: 0)
        var grid = SIMD2<UInt32>(UInt32(Self.validationWidth), UInt32(Self.validationHeight))
        encoder.setBytes(&grid, length: MemoryLayout.size(ofValue: grid), index: 1)
        Self.dispatch(encoder, pipeline: validatePipeline, width: Self.validationWidth, height: Self.validationHeight)
        encoder.endEncoding()

        var retained = input.analysisTextures.map(\.bridge)
        if let bridge = forwardFlow.bridge { retained.append(bridge) }
        if let bridge = backwardFlow.bridge { retained.append(bridge) }
        try await Self.run(command, retaining: retained)
        return try motionVerticalSign()
    }

    private func fallbackFlowTexture(forward: Bool) throws -> any MTLTexture {
        if forward, let existing = fallbackForwardTexture { return existing }
        if !forward, let existing = fallbackBackwardTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: analysisWidth, height: analysisHeight, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let created = device.makeTexture(descriptor: descriptor) else {
            throw VisionInterpolationSetupFailure(stage: "flow texture allocation failed")
        }
        if forward {
            fallbackForwardTexture = created
        } else {
            fallbackBackwardTexture = created
        }
        return created
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
        guard let mapped = VideoEnhancementMetalContext.shared.makeTexture(
            buffer: buffer, format: pixelFormat, width: size.width, height: size.height, plane: plane, usage: usage
        ) else {
            throw VisionInterpolationFailure.texture
        }
        return Texture(metal: mapped.texture, bridge: mapped.bridge)
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
        let rows = min(8, max(1, pipeline.maxTotalThreadsPerThreadgroup / threads))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threads, height: rows, depth: 1))
    }

    private static func run(_ command: any MTLCommandBuffer, retaining bridges: [CVMetalTexture]) async throws {
        defer { withExtendedLifetime(bridges) {} }
        let completed = await VideoEnhancementMetalContext.commitAndWait(command)
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
