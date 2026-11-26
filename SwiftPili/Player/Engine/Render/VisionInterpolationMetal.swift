import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Vision

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

/// Quality/speed profile for the Apple Vision pyramidal optical flow (`Revision 1`) + Metal synthesis pipeline.
///
/// - `.ultra`: 540p analysis + `VNGenerateOpticalFlowRequest.ComputationAccuracy.medium` (Force Frame Interpolation mode)
/// - `.high`: 480p analysis + `VNGenerateOpticalFlowRequest.ComputationAccuracy.medium`
/// - `.balanced`: 480p analysis + `VNGenerateOpticalFlowRequest.ComputationAccuracy.low`
/// - `.fast`: 360p analysis + `VNGenerateOpticalFlowRequest.ComputationAccuracy.low`
enum OpticalFlowQualityProfile: Int, Comparable, CaseIterable, Sendable {
    case fast = 0
    case balanced = 1
    case high = 2
    case ultra = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var analysisLongEdge: Int {
        switch self {
        case .ultra: 540
        case .high, .balanced: 480
        case .fast: 360
        }
    }

    var visionAccuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy {
        switch self {
        case .ultra, .high: .medium
        case .balanced, .fast: .low
        }
    }
}

struct VisionInterpolationFormat: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let chromaOffset: SIMD2<Float>
    let isBT2020: Bool

    var isBGRA: Bool { pixelFormat == kCVPixelFormatType_32BGRA }

    var is10Bit: Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    var isVideoRange: Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    var analysisMode: Float {
        if isBGRA { return 0 }
        return isVideoRange ? 2 : 1
    }

    var lumaMetalFormat: MTLPixelFormat {
        if isBGRA { return .bgra8Unorm }
        return is10Bit ? .r16Unorm : .r8Unorm
    }

    var chromaMetalFormat: MTLPixelFormat {
        is10Bit ? .rg16Unorm : .rg8Unorm
    }

    var biPlanarSynthesisFlags: Float {
        var flags = 0
        if isVideoRange { flags |= 1 }
        if is10Bit { flags |= 2 }
        return Float(flags)
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
        guard width > 0, height > 0,
              VideoEnhancementGuardrails.isSupportedInterpolationBuffer(buffer),
              VideoFramePairFormat.interpolationBypassReason(buffer) == nil else { return nil }
        if let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil),
           CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            isBT2020 = true
        } else {
            isBT2020 = false
        }
        if pixelFormat == kCVPixelFormatType_32BGRA {
            guard !CVPixelBufferIsPlanar(buffer) else { return nil }
            chromaOffset = .zero
        } else {
            guard width.isMultiple(of: 2), height.isMultiple(of: 2),
                  CVPixelBufferGetPlaneCount(buffer) == 2,
                  CVPixelBufferGetWidthOfPlane(buffer, 0) == width,
                  CVPixelBufferGetHeightOfPlane(buffer, 0) == height,
                  CVPixelBufferGetWidthOfPlane(buffer, 1) == width / 2,
                  CVPixelBufferGetHeightOfPlane(buffer, 1) == height / 2 else { return nil }
            let offset = Self.chromaSiting(buffer)
            chromaOffset = offset / SIMD2<Float>(Float(width), Float(height))
        }
    }

    private static func chromaSiting(_ buffer: CVPixelBuffer) -> SIMD2<Float> {
        guard let location = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) else {
            return SIMD2(-0.5, 0)
        }
        for (key, offset) in chromaSitingTable where CFEqual(location, key) {
            return offset
        }
        // Default unrecognized siting (e.g. DV420) safely to standard MPEG-2/H.264/HEVC/AV1 left siting.
        return SIMD2(-0.5, 0)
    }
}

/// GPU infrastructure pairing Apple's `VNGenerateOpticalFlowRequest` with a single-`MTLCommandBuffer`
/// zero-readback validation, outlier/Jacobian regularization, atomic Z-buffered forward splat, and
/// full-resolution 8/10-bit SDR & HDR synthesis pipeline.
final class VisionInterpolationMetal {
    fileprivate struct Texture {
        let metal: any MTLTexture
        let bridge: CVMetalTexture
    }

    struct FlowTexture {
        let metal: any MTLTexture
        let bridge: CVMetalTexture?
    }

    struct PreparedPair {
        fileprivate let previousPlanes: [Texture]
        fileprivate let currentPlanes: [Texture]
        fileprivate let currentSource: CVPixelBuffer
        let previousAnalysis: CVPixelBuffer
        let currentAnalysis: CVPixelBuffer
        fileprivate let analysisTextures: [Texture]
        fileprivate let needsPreviousAnalysis: Bool
        let analysisSize: (width: Int, height: Int)
        fileprivate let slotIndex: Int
    }

    private struct AnalysisResources {
        let width: Int
        let height: Int
        let analysisPool: CVPixelBufferPool
        let cleanFlowTexture: any MTLTexture
        let phaseFieldTexture: any MTLTexture
        let fallbackFlowTexture: any MTLTexture
        let splatBuffer: any MTLBuffer
    }

    let format: VisionInterpolationFormat
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue

    private let preparePipeline: any MTLComputePipelineState
    private let coarseFlowPipeline: any MTLComputePipelineState
    private let validatePipeline: any MTLComputePipelineState
    private let regularizePipeline: any MTLComputePipelineState
    private let clearSplatPipeline: any MTLComputePipelineState
    private let splatPhasePipeline: any MTLComputePipelineState
    private let resolvePhasePipeline: any MTLComputePipelineState
    private let synthesizeBGRAPipeline: any MTLComputePipelineState
    private let synthesizeNV12Pipeline: any MTLComputePipelineState

    private let outputPool: CVPixelBufferPool
    /// Standard analysis-tier resources: `[0]` = 480p (`.high` / `.balanced`), `[1]` = 360p (`.fast`).
    private let tiers: [AnalysisResources]
    /// Lazily allocated 540p `.ultra` tier used only when Force Frame Interpolation is enabled.
    private var ultraTier: AnalysisResources?
    /// 16-byte GPU-private scene summary (`float4(snapNearest, bestSignY, validFraction, avgWarped)`).
    private let sceneStatsBuffer: any MTLBuffer

    private var cachedAnalysis: (source: CVPixelBuffer, analysis: CVPixelBuffer, tierIndex: Int)?

    init(format: VisionInterpolationFormat) throws {
        self.format = format

        let metal = VideoEnhancementMetalContext.shared
        let resources: VideoEnhancementMetalContext.Resources
        do {
            resources = try metal.resources()
            preparePipeline = try metal.pipeline(for: .visionInterpolationPrepare)
            coarseFlowPipeline = try metal.pipeline(for: .visionInterpolationCoarseFlow)
            validatePipeline = try metal.pipeline(for: .visionInterpolationValidate)
            regularizePipeline = try metal.pipeline(for: .visionInterpolationRegularizeFlow)
            clearSplatPipeline = try metal.pipeline(for: .visionInterpolationClearSplat)
            splatPhasePipeline = try metal.pipeline(for: .visionInterpolationSplatPhase)
            resolvePhasePipeline = try metal.pipeline(for: .visionInterpolationResolvePhase)
            synthesizeBGRAPipeline = try metal.pipeline(for: .visionInterpolationSynthesize)
            synthesizeNV12Pipeline = try metal.pipeline(for: .visionInterpolationSynthesizeNV12)
        } catch {
            throw VisionInterpolationSetupFailure(stage: error.stage, status: error.status)
        }
        device = resources.device
        queue = resources.commandQueue

        outputPool = try Self.makePool(width: format.width, height: format.height, pixelFormat: format.pixelFormat)

        let tier480 = try Self.makeAnalysisResources(device: device, format: format, targetLongEdge: 480, label: "480p")
        let tier360 = try Self.makeAnalysisResources(device: device, format: format, targetLongEdge: 360, label: "360p")
        tiers = [tier480, tier360]

        guard let stats = device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModePrivate
        ) else {
            throw VisionInterpolationSetupFailure(stage: "scene stats buffer allocation failed")
        }
        sceneStatsBuffer = stats
    }

    func flushTextures() {
        cachedAnalysis = nil
        VideoEnhancementMetalContext.shared.flushTextureCache()
    }

    private func tierIndex(for profile: OpticalFlowQualityProfile) -> Int {
        switch profile {
        case .ultra: 2
        case .high, .balanced: 0
        case .fast: 1
        }
    }

    private func analysisResources(forSlot idx: Int) throws -> AnalysisResources {
        if idx == 2 {
            if let ultraTier { return ultraTier }
            let created = try Self.makeAnalysisResources(
                device: device, format: format, targetLongEdge: 540, label: "540p"
            )
            ultraTier = created
            return created
        }
        return tiers[idx]
    }

    /// Lightweight initial-frame prewarm: prepares and caches `source`'s analysis buffer on GPU
    /// (<1 ms) without running a throwaway `VNGenerateOpticalFlowRequest`, so Frame 1 interpolates immediately.
    func prewarmAnalysis(source: CVPixelBuffer, profile: OpticalFlowQualityProfile = .high) async throws {
        let idx = tierIndex(for: profile)
        if let cached = cachedAnalysis, cached.source === source, cached.tierIndex == idx {
            return
        }
        let tier = try analysisResources(forSlot: idx)
        let planes = try mapPlanes(source, usage: .shaderRead)
        let analysisBuffer = try Self.allocate(from: tier.analysisPool, limit: 4)
        let analysisTex = try map(
            analysisBuffer,
            pixelFormat: .bgra8Unorm,
            size: (tier.width, tier.height),
            plane: 0,
            usage: [.shaderRead, .shaderWrite]
        )

        let (command, encoder) = try beginCommand(label: "Vision FI prewarm analysis")
        encodePrepareSingle(
            encoder: encoder,
            planes: planes,
            analysisOut: analysisTex.metal,
            size: (tier.width, tier.height)
        )
        encoder.endEncoding()

        var retained = planes.map(\.bridge)
        retained.append(analysisTex.bridge)
        try await Self.run(command, retaining: retained)
        cachedAnalysis = (source: source, analysis: analysisBuffer, tierIndex: idx)
    }

    func preparePair(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        profile: OpticalFlowQualityProfile
    ) async throws -> PreparedPair {
        let idx = tierIndex(for: profile)
        let tier = try analysisResources(forSlot: idx)
        let reusedPrevious: CVPixelBuffer? = if let cached = cachedAnalysis,
                                                cached.source === previous,
                                                cached.tierIndex == idx {
            cached.analysis
        } else {
            nil
        }

        let previousAnalysis = try reusedPrevious ?? Self.allocate(from: tier.analysisPool, limit: 4)
        let currentAnalysis = try Self.allocate(from: tier.analysisPool, limit: 4)
        let prevUsage: MTLTextureUsage = reusedPrevious == nil ? [.shaderRead, .shaderWrite] : .shaderRead

        let prevPlanes = try mapPlanes(previous, usage: .shaderRead)
        let currPlanes = try mapPlanes(current, usage: .shaderRead)
        let prevAnalysisTex = try map(
            previousAnalysis,
            pixelFormat: .bgra8Unorm,
            size: (tier.width, tier.height),
            plane: 0,
            usage: prevUsage
        )
        let currAnalysisTex = try map(
            currentAnalysis,
            pixelFormat: .bgra8Unorm,
            size: (tier.width, tier.height),
            plane: 0,
            usage: [.shaderRead, .shaderWrite]
        )

        let (command, encoder) = try beginCommand(label: "Vision FI analysis (\(tier.width)x\(tier.height))")
        var retained: [CVMetalTexture] = []
        retained.reserveCapacity(prevPlanes.count + currPlanes.count + 2)

        if reusedPrevious == nil {
            encodePrepareSingle(
                encoder: encoder,
                planes: prevPlanes,
                analysisOut: prevAnalysisTex.metal,
                size: (tier.width, tier.height)
            )
            retained.append(contentsOf: prevPlanes.map(\.bridge))
            retained.append(prevAnalysisTex.bridge)
        }
        encodePrepareSingle(
            encoder: encoder,
            planes: currPlanes,
            analysisOut: currAnalysisTex.metal,
            size: (tier.width, tier.height)
        )
        retained.append(contentsOf: currPlanes.map(\.bridge))
        retained.append(currAnalysisTex.bridge)

        encoder.endEncoding()
        try await Self.run(command, retaining: retained)
        cachedAnalysis = (source: current, analysis: currentAnalysis, tierIndex: idx)

        return PreparedPair(
            previousPlanes: prevPlanes,
            currentPlanes: currPlanes,
            currentSource: current,
            previousAnalysis: previousAnalysis,
            currentAnalysis: currentAnalysis,
            analysisTextures: [prevAnalysisTex, currAnalysisTex],
            needsPreviousAnalysis: reusedPrevious == nil,
            analysisSize: (tier.width, tier.height),
            slotIndex: idx
        )
    }

    /// Zero-copy IOSurface bind for `VNGenerateOpticalFlowRequest` output (`TwoComponent16Half` / `TwoComponent32Float`),
    /// with CPU `texture.replace` fallback when Vision or unit tests supply a non-IOSurface pixel buffer.
    func bindFlow(_ buffer: CVPixelBuffer, for pair: PreparedPair) throws -> FlowTexture {
        let tier = try analysisResources(forSlot: pair.slotIndex)
        let pf = CVPixelBufferGetPixelFormatType(buffer)
        let isHalf = pf == kCVPixelFormatType_TwoComponent16Half
        let isFloat = pf == kCVPixelFormatType_TwoComponent32Float
        guard (isHalf || isFloat),
              CVPixelBufferGetWidth(buffer) == tier.width,
              CVPixelBufferGetHeight(buffer) == tier.height,
              !CVPixelBufferIsPlanar(buffer) else {
            throw VisionInterpolationFailure.flowLayout
        }

        let mtlFormat: MTLPixelFormat = isHalf ? .rg16Float : .rg32Float
        if CVPixelBufferGetIOSurface(buffer) != nil,
           let mapped = VideoEnhancementMetalContext.shared.makeTexture(
            buffer: buffer,
            format: mtlFormat,
            width: tier.width,
            height: tier.height,
            plane: 0,
            usage: .shaderRead
           ) {
            return FlowTexture(metal: mapped.texture, bridge: mapped.bridge)
        }

        let minRowBytes = tier.width * (isHalf ? 4 : 8)
        guard CVPixelBufferGetBytesPerRow(buffer) >= minRowBytes,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw VisionInterpolationFailure.flowLayout
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VisionInterpolationFailure.flowLayout
        }

        if isHalf {
            tier.fallbackFlowTexture.replace(
                region: MTLRegionMake2D(0, 0, tier.width, tier.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
            )
            return FlowTexture(metal: tier.fallbackFlowTexture, bridge: nil)
        }

        let floatDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: tier.width, height: tier.height, mipmapped: false
        )
        floatDesc.storageMode = .shared
        floatDesc.usage = .shaderRead
        guard let tempTex = device.makeTexture(descriptor: floatDesc) else {
            throw VisionInterpolationFailure.flowLayout
        }
        tempTex.replace(
            region: MTLRegionMake2D(0, 0, tier.width, tier.height),
            mipmapLevel: 0,
            withBytes: base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        )
        return FlowTexture(metal: tempTex, bridge: nil)
    }

    /// Executes sign/scene-cut validation, outlier/Jacobian flow regularization, atomic forward splatting,
    /// and full-resolution anti-explosion synthesis in a single zero-readback `MTLCommandBuffer`.
    func synthesize(
        _ pair: PreparedPair,
        forwardFlow: FlowTexture?,
        phases: [Float]
    ) async throws -> [CVPixelBuffer] {
        guard !phases.isEmpty else { return [] }
        let tier = try analysisResources(forSlot: pair.slotIndex)

        let outputs = try phases.map { phase -> (phase: Float, buffer: CVPixelBuffer, planes: [Texture]) in
            let buffer = try Self.allocate(
                from: outputPool,
                limit: VideoFrameInterpolationPlan.outputPoolLimit(phaseCount: phases.count)
            )
            guard VideoFramePairFormat.hasSameStorageFormat(pair.currentSource, buffer) else {
                throw VisionInterpolationFailure.outputFormat
            }
            return (phase: phase, buffer: buffer, planes: try mapPlanes(buffer, usage: .shaderWrite))
        }

        let (command, encoder) = try beginCommand(label: "Vision FI synthesize")
        let flowTexture: any MTLTexture
        if let forwardFlow {
            flowTexture = forwardFlow.metal
        } else {
            // Simulator / fallback GPU block-matching flow when Vision ANE runtime is unavailable.
            encoder.setComputePipelineState(coarseFlowPipeline)
            encoder.setTexture(pair.analysisTextures[0].metal, index: 0)
            encoder.setTexture(pair.analysisTextures[1].metal, index: 1)
            encoder.setTexture(tier.fallbackFlowTexture, index: 2)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: encoder,
                pipeline: coarseFlowPipeline,
                width: tier.width,
                height: tier.height
            )
            flowTexture = tier.fallbackFlowTexture
        }

        // 1. Validate signY (+1 vs -1) and scene-cut / chaos guard into private `sceneStatsBuffer`.
        let side = validatePipeline.maxTotalThreadsPerThreadgroup >= 256 ? 16 : 8
        encoder.setComputePipelineState(validatePipeline)
        encoder.setTexture(pair.analysisTextures[0].metal, index: 0)
        encoder.setTexture(pair.analysisTextures[1].metal, index: 1)
        encoder.setTexture(flowTexture, index: 2)
        encoder.setBuffer(sceneStatsBuffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1)
        )

        // 2. 3x3 outlier median + Jacobian fold/stretch rejection -> `cleanFlowTexture`.
        encoder.setComputePipelineState(regularizePipeline)
        encoder.setTexture(flowTexture, index: 0)
        encoder.setTexture(pair.analysisTextures[0].metal, index: 1)
        encoder.setTexture(pair.analysisTextures[1].metal, index: 2)
        encoder.setTexture(tier.cleanFlowTexture, index: 3)
        encoder.setBuffer(sceneStatsBuffer, offset: 0, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: encoder,
            pipeline: regularizePipeline,
            width: tier.width,
            height: tier.height
        )

        // 3. Per-phase atomic Z-buffered forward splat + full-resolution synthesis.
        var elementCount = UInt32(tier.width * tier.height)
        let clearTG = max(1, min(256, clearSplatPipeline.maxTotalThreadsPerThreadgroup))
        let clearGroups = (Int(elementCount) + clearTG - 1) / clearTG

        for output in outputs {
            encoder.setComputePipelineState(clearSplatPipeline)
            encoder.setBuffer(tier.splatBuffer, offset: 0, index: 0)
            encoder.setBytes(&elementCount, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreadgroups(
                MTLSize(width: clearGroups, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: clearTG, height: 1, depth: 1)
            )

            var splatParams = SIMD4<Float>(output.phase, 0, 0, 0)
            encoder.setComputePipelineState(splatPhasePipeline)
            encoder.setTexture(tier.cleanFlowTexture, index: 0)
            encoder.setBuffer(tier.splatBuffer, offset: 0, index: 0)
            encoder.setBuffer(sceneStatsBuffer, offset: 0, index: 1)
            encoder.setBytes(&splatParams, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: encoder,
                pipeline: splatPhasePipeline,
                width: tier.width,
                height: tier.height
            )

            encoder.setComputePipelineState(resolvePhasePipeline)
            encoder.setTexture(tier.cleanFlowTexture, index: 0)
            encoder.setTexture(tier.phaseFieldTexture, index: 1)
            encoder.setBuffer(tier.splatBuffer, offset: 0, index: 0)
            encoder.setBuffer(sceneStatsBuffer, offset: 0, index: 1)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: encoder,
                pipeline: resolvePhasePipeline,
                width: tier.width,
                height: tier.height
            )

            encodeSynthesize(
                encoder: encoder,
                previousPlanes: pair.previousPlanes,
                currentPlanes: pair.currentPlanes,
                outputPlanes: output.planes,
                phaseField: tier.phaseFieldTexture,
                phase: output.phase
            )
        }

        encoder.endEncoding()

        var retained: [CVMetalTexture] = []
        retained.reserveCapacity(
            pair.previousPlanes.count + pair.currentPlanes.count + pair.analysisTextures.count
                + outputs.count * 2 + 1
        )
        retained.append(contentsOf: pair.previousPlanes.map(\.bridge))
        retained.append(contentsOf: pair.currentPlanes.map(\.bridge))
        retained.append(contentsOf: pair.analysisTextures.map(\.bridge))
        if let bridge = forwardFlow?.bridge {
            retained.append(bridge)
        }
        for output in outputs {
            retained.append(contentsOf: output.planes.map(\.bridge))
        }

        try await Self.run(command, retaining: retained)
        return outputs.map(\.buffer)
    }

    /// Convenience end-to-end Metal synthesis helper (used by deterministic Simulator GPU tests or
    /// when a precomputed `forwardFlow` pixel buffer is supplied).
    func interpolate(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        phases: [Float],
        profile: OpticalFlowQualityProfile = .high,
        forwardFlowBuffer: CVPixelBuffer? = nil
    ) async throws -> [CVPixelBuffer] {
        let pair = try await preparePair(previous: previous, current: current, profile: profile)
        let flow = try forwardFlowBuffer.map { try bindFlow($0, for: pair) }
        let buffers = try await synthesize(pair, forwardFlow: flow, phases: phases)
        let outputColorSpace: ScaledVideoOutputMetadata.OutputColorSpace =
            format.isBGRA ? .rgbConverted : .yuvSameAsSource
        for output in buffers {
            ScaledVideoOutputMetadata.copy(from: current, to: output, colorSpace: outputColorSpace)
        }
        return buffers
    }

    // MARK: - Encoders

    private func encodePrepareSingle(
        encoder: any MTLComputeCommandEncoder,
        planes: [Texture],
        analysisOut: any MTLTexture,
        size: (width: Int, height: Int)
    ) {
        var params = SIMD4<Float>(
            format.chromaOffset.x,
            format.chromaOffset.y,
            format.analysisMode,
            format.isBT2020 ? 1.0 : 0.0
        )
        encoder.setComputePipelineState(preparePipeline)
        encoder.setTexture(planes[0].metal, index: 0)
        encoder.setTexture(planes.last?.metal, index: 1)
        encoder.setTexture(analysisOut, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: encoder,
            pipeline: preparePipeline,
            width: size.width,
            height: size.height
        )
    }

    private func encodeSynthesize(
        encoder: any MTLComputeCommandEncoder,
        previousPlanes: [Texture],
        currentPlanes: [Texture],
        outputPlanes: [Texture],
        phaseField: any MTLTexture,
        phase: Float
    ) {
        if format.isBGRA {
            var params = SIMD4<Float>(phase, 0, 0, 0)
            encoder.setComputePipelineState(synthesizeBGRAPipeline)
            encoder.setTexture(previousPlanes[0].metal, index: 0)
            encoder.setTexture(currentPlanes[0].metal, index: 1)
            encoder.setTexture(outputPlanes[0].metal, index: 2)
            encoder.setTexture(phaseField, index: 3)
            encoder.setBuffer(sceneStatsBuffer, offset: 0, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: encoder,
                pipeline: synthesizeBGRAPipeline,
                width: format.width,
                height: format.height
            )
        } else {
            var params = SIMD4<Float>(
                format.chromaOffset.x,
                format.chromaOffset.y,
                phase,
                format.biPlanarSynthesisFlags
            )
            encoder.setComputePipelineState(synthesizeNV12Pipeline)
            encoder.setTexture(previousPlanes[0].metal, index: 0)
            encoder.setTexture(currentPlanes[0].metal, index: 1)
            encoder.setTexture(previousPlanes[1].metal, index: 2)
            encoder.setTexture(currentPlanes[1].metal, index: 3)
            encoder.setTexture(outputPlanes[0].metal, index: 4)
            encoder.setTexture(outputPlanes[1].metal, index: 5)
            encoder.setTexture(phaseField, index: 6)
            encoder.setBuffer(sceneStatsBuffer, offset: 0, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: encoder,
                pipeline: synthesizeNV12Pipeline,
                width: format.width / 2,
                height: format.height / 2
            )
        }
    }

    // MARK: - Resource Allocation

    private static func makeAnalysisResources(
        device: any MTLDevice,
        format: VisionInterpolationFormat,
        targetLongEdge: Int,
        label: String
    ) throws -> AnalysisResources {
        let scale = min(1.0, Double(targetLongEdge) / Double(max(format.width, format.height)))
        let width = max(16, (Int((Double(format.width) * scale).rounded()) / 2) * 2)
        let height = max(16, (Int((Double(format.height) * scale).rounded()) / 2) * 2)
        guard width * height < (1 << 20) else {
            throw VisionInterpolationSetupFailure(stage: "\(label) analysis grid exceeds 20-bit index budget")
        }

        let pool = try makePool(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA,
            stampSRGBColorSpace: true
        )

        let rgbaDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        rgbaDesc.storageMode = .private
        rgbaDesc.usage = [.shaderRead, .shaderWrite]
        guard let cleanFlow = device.makeTexture(descriptor: rgbaDesc),
              let phaseField = device.makeTexture(descriptor: rgbaDesc) else {
            throw VisionInterpolationSetupFailure(stage: "\(label) private flow textures allocation failed")
        }
        cleanFlow.label = "VisionFI.cleanFlow.\(label)"
        phaseField.label = "VisionFI.phaseField.\(label)"

        let fallbackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: width, height: height, mipmapped: false
        )
        fallbackDesc.storageMode = .shared
        fallbackDesc.usage = [.shaderRead, .shaderWrite]
        guard let fallbackFlow = device.makeTexture(descriptor: fallbackDesc) else {
            throw VisionInterpolationSetupFailure(stage: "\(label) fallback flow texture allocation failed")
        }
        fallbackFlow.label = "VisionFI.fallbackFlow.\(label)"

        let splatBytes = width * height * MemoryLayout<UInt32>.stride
        guard let splat = device.makeBuffer(length: splatBytes, options: .storageModePrivate) else {
            throw VisionInterpolationSetupFailure(stage: "\(label) splat buffer allocation failed")
        }
        splat.label = "VisionFI.splat.\(label)"

        return AnalysisResources(
            width: width,
            height: height,
            analysisPool: pool,
            cleanFlowTexture: cleanFlow,
            phaseFieldTexture: phaseField,
            fallbackFlowTexture: fallbackFlow,
            splatBuffer: splat
        )
    }

    private func mapPlanes(_ buffer: CVPixelBuffer, usage: MTLTextureUsage) throws -> [Texture] {
        let luma = try map(
            buffer,
            pixelFormat: format.lumaMetalFormat,
            size: (format.width, format.height),
            plane: 0,
            usage: usage
        )
        if format.isBGRA { return [luma] }
        let chroma = try map(
            buffer,
            pixelFormat: format.chromaMetalFormat,
            size: (format.width / 2, format.height / 2),
            plane: 1,
            usage: usage
        )
        return [luma, chroma]
    }

    private func map(
        _ buffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        size: (width: Int, height: Int),
        plane: Int,
        usage: MTLTextureUsage
    ) throws -> Texture {
        guard let mapped = VideoEnhancementMetalContext.shared.makeTexture(
            buffer: buffer,
            format: pixelFormat,
            width: size.width,
            height: size.height,
            plane: plane,
            usage: usage
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

    private static func run(_ command: any MTLCommandBuffer, retaining bridges: [CVMetalTexture]) async throws {
        defer { withExtendedLifetime(bridges) {} }
        let completed = await VideoEnhancementMetalContext.commitAndWait(command)
        guard completed else { throw VisionInterpolationFailure.gpu }
    }

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private static func makePool(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        stampSRGBColorSpace: Bool = false
    ) throws -> CVPixelBufferPool {
        var attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        if stampSRGBColorSpace, let sRGBColorSpace {
            attributes[kCVBufferPropagatedAttachmentsKey] = [
                kCVImageBufferCGColorSpaceKey: sRGBColorSpace,
            ] as CFDictionary
        }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            throw VisionInterpolationFailure.pool
        }
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
