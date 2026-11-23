import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoToolboxSuperResolutionBackend {
    #if !targetEnvironment(simulator)
    private var contextStorage: AnyObject?
    #endif

    func flush() {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *) { (contextStorage as? VTSRContext)?.flush() }
        #endif
    }

    func tearDown() {
        #if !targetEnvironment(simulator)
        contextStorage = nil
        #endif
    }

    func upscale(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        maxScale: Float = 2,
        hasTimeRemaining: @Sendable () -> Bool = { true }
    ) async -> VideoEnhancementBackendOutcome {
        #if targetEnvironment(simulator)
        return .bypassed(reason: "Simulator unsupported")
        #else
        guard #available(iOS 26.0, *) else { return .bypassed(reason: "Requires iOS 26") }
        do {
            try VTSRFailure.checkDeadline(hasTimeRemaining)
            guard pts.isNumeric else { throw VTSRFailure("VT SR timestamp invalid") }
            guard maxScale.isFinite, maxScale > 1 else { throw VTSRFailure("VT SR scale cap \(maxScale)x") }
            let output = try await upscaleIOS26(
                pixelBuffer, pts: pts, maxScale: maxScale, hasTimeRemaining: hasTimeRemaining
            )
            return .processed(output)
        } catch {
            flush()
            if Task.isCancelled || !hasTimeRemaining() {
                return .bypassed(reason: VTSRFailure.deadline.reason)
            }
            let reason = (error as? VTSRFailure)?.reason ?? (error as? VideoSuperResolutionPool.Failure)?.reason
                ?? "VT SR buffer preparation failed"
            return .bypassed(reason: reason)
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private func upscaleIOS26(
        _ input: CVPixelBuffer, pts: CMTime, maxScale: Float, hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        let inputRaster = VTInterpolationRaster(input)
        let context = if let current = contextStorage as? VTSRContext, current.raster == inputRaster {
            current
        } else {
            VTSRContext(raster: inputRaster, maxScale: maxScale)
        }
        contextStorage = context
        context.updateScaleCap(maxScale)
        return try await context.upscale(input, pts: pts, hasTimeRemaining: hasTimeRemaining)
    }
    #endif
}

#if !targetEnvironment(simulator)
@available(iOS 26.0, *)
private final class VTSRContext {
    let raster: VTInterpolationRaster
    private var maxScale: Float
    private var candidates: [VTSRConfiguration]
    private var configurationFailure: String
    private var session: VTSRSession?
    private var nativeRejections: [VTSRConfiguration.Identifier: String] = [:]
    private var nextModelDownloadRequests: [VTSRConfiguration.Identifier: ContinuousClock.Instant] = [:]

    init(raster: VTInterpolationRaster, maxScale: Float) {
        self.raster = raster
        self.maxScale = maxScale
        (candidates, configurationFailure) = VTSRConfiguration.candidates(for: raster, maxScale: maxScale)
    }

    func updateScaleCap(_ maxScale: Float) {
        guard self.maxScale != maxScale else { return }
        self.maxScale = maxScale
        (candidates, configurationFailure) = VTSRConfiguration.candidates(for: raster, maxScale: maxScale)
        if let session, !candidates.contains(where: { $0.id == session.configuration.id }) {
            self.session = nil
        }
    }

    func flush() { session?.flush() }

    func upscale(
        _ input: CVPixelBuffer, pts: CMTime, hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        var bypassReason = configurationFailure
        var modelBypassReason: String?
        for candidate in candidates {
            try VTSRFailure.checkDeadline(hasTimeRemaining)
            if let rejection = nativeRejections[candidate.id] {
                bypassReason = rejection
                continue
            }
            let canStage = raster.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let isDirect = candidate.source.accepts(input)
            guard isDirect || canStage else {
                bypassReason = "VT SR decoded buffer layout unsupported (\(raster.description))"
                continue
            }
            if session?.canReuse(candidate.id, at: pts) != true,
               let reason = legacyModelBypassReason(for: candidate) {
                modelBypassReason = modelBypassReason ?? reason
                continue
            }
            if session?.configuration.id != candidate.id { session = nil }
            let active = session ?? VTSRSession(configuration: candidate)
            session = active
            do {
                return try await active.upscale(input, pts: pts, isDirect: isDirect, hasTimeRemaining: hasTimeRemaining)
            } catch let failure as VTSRFailure where failure.rejectsConfiguration {
                session = nil
                nativeRejections[candidate.id] = failure.reason
                bypassReason = failure.reason
            }
        }
        throw VTSRFailure(modelBypassReason ?? bypassReason)
    }

    private func legacyModelBypassReason(for candidate: VTSRConfiguration) -> String? {
        guard let legacy = candidate.native as? VTSuperResolutionScalerConfiguration else { return nil }
        switch legacy.configurationModelStatus {
        case .ready:
            return nil
        case .downloading:
            return "VT SR legacy model downloading"
        case .downloadRequired:
            let now = ContinuousClock.now
            if nextModelDownloadRequests[candidate.id].map({ now >= $0 }) ?? true {
                nextModelDownloadRequests[candidate.id] = now.advanced(by: .seconds(30))
                legacy.downloadConfigurationModel { _ in }
            }
            return "VT SR legacy model download required"
        @unknown default:
            return "VT SR legacy model unavailable"
        }
    }
}

private struct VTSRFailure: Error {
    static let deadline = Self("VT SR deadline")
    let reason: String
    let rejectsConfiguration: Bool

    init(_ reason: String, rejectsConfiguration: Bool = false) {
        self.reason = reason
        self.rejectsConfiguration = rejectsConfiguration
    }

    static func checkDeadline(_ hasTimeRemaining: @Sendable () -> Bool) throws {
        guard !Task.isCancelled, hasTimeRemaining() else { throw deadline }
    }
}

private extension VTInterpolationRaster {
    init(width: Int, height: Int, format: OSType) {
        self.width = width
        self.height = height
        self.format = format
    }
}

@available(iOS 26.0, *)
private struct VTSRConfiguration {
    enum Identifier: Hashable {
        case lowLatency(Float)
        case legacyVideo(Int)
        case legacyImage(Int)

        var scale: Float {
            switch self {
            case let .lowLatency(scale): scale
            case let .legacyVideo(scale), let .legacyImage(scale): Float(scale)
            }
        }
    }

    let id: Identifier
    let native: any VTFrameProcessorConfiguration
    let source: VTInterpolationBufferRequirements
    let destination: VTInterpolationBufferRequirements

    private enum CandidateRejection: String, Error {
        case scaleCap = "VT SR output exceeds scale cap"
        case rasterBudget = "VT SR output exceeds raster budget"
        case raster = "VT SR native raster unsupported"
        case format = "VT SR native format/layout unsupported"
    }

    static func candidates(for raster: VTInterpolationRaster, maxScale: Float) -> ([Self], String) {
        let lowLatency = VTLowLatencySuperResolutionScalerConfiguration.isSupported
        let legacy = VTSuperResolutionScalerConfiguration.isSupported
        guard lowLatency || legacy else { return ([], "VT SR unsupported on this device") }

        let rawLowLatency = lowLatency ? VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: raster.width, frameHeight: raster.height
        ) : []
        let rawLegacy = legacy ? VTSuperResolutionScalerConfiguration.supportedScaleFactors : []
        PlayerLog.log(
            "[VT SR] input=\(raster.description) maxScale=\(maxScale)x " +
            "rawLowLatency=\(rawLowLatency) rawLegacy=\(rawLegacy)"
        )
        let lowLatencyIDs = Set(rawLowLatency.filter { $0.isFinite && $0 > 1 }).sorted(by: >).map(Identifier.lowLatency)
        let legacyIDs = Set(rawLegacy.filter { $0 > 1 }).sorted(by: >).flatMap {
            [Identifier.legacyVideo($0), .legacyImage($0)]
        }
        let ids = lowLatencyIDs + legacyIDs
        guard !ids.isEmpty else { return ([], "No native VT SR scale (\(raster.description))") }
        let admitted = ids.filter { $0.scale <= maxScale }
        guard !admitted.isEmpty else {
            return ([], "VT SR native scales exceed \(maxScale)x cap (\(raster.description))")
        }
        var rejections: Set<CandidateRejection> = []
        let configurations = admitted.compactMap { id -> Self? in
            do throws(CandidateRejection) {
                return try makeConfiguration(id, raster: raster, maxScale: maxScale)
            } catch {
                rejections.insert(error)
                return nil
            }
        }
        let rejection = [CandidateRejection.format, .rasterBudget, .raster, .scaleCap].first(where: rejections.contains)
        let failure = "\((rejection ?? .raster).rawValue) (\(raster.description))"
        return (configurations, failure)
    }

    private static func makeConfiguration(
        _ id: Identifier, raster: VTInterpolationRaster, maxScale: Float
    ) throws(CandidateRejection) -> Self {
        let native: any VTFrameProcessorConfiguration
        switch id {
        case let .lowLatency(scale):
            native = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, scaleFactor: scale
            )
        case let .legacyVideo(scale), let .legacyImage(scale):
            let inputType: VTSuperResolutionScalerConfiguration.InputType = switch id {
            case .legacyVideo: .video
            default: .image
            }
            guard let config = VTSuperResolutionScalerConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, scaleFactor: scale, inputType: inputType,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision
            ) else { throw .raster }
            native = config
        }

        let source = native.sourcePixelBufferAttributes
        let destination = native.destinationPixelBufferAttributes
        let widthKey = kCVPixelBufferWidthKey as String
        let heightKey = kCVPixelBufferHeightKey as String
        guard (source[widthKey] as? Int ?? raster.width) == raster.width,
              (source[heightKey] as? Int ?? raster.height) == raster.height,
              let width = destination[widthKey] as? Int, let height = destination[heightKey] as? Int,
              width > raster.width, height > raster.height else { throw .raster }
        guard VideoSuperResolutionRasterBudget.contains(width: width, height: height) else { throw .rasterBudget }
        guard Double(width) <= Double(raster.width) * Double(maxScale),
              Double(height) <= Double(raster.height) * Double(maxScale) else { throw .scaleCap }
        let outputRaster = VTInterpolationRaster(width: width, height: height, format: raster.format)
        guard let input = VTInterpolationBufferRequirements.resolve(source, for: raster).requirements,
              let output = VTInterpolationBufferRequirements.resolve(destination, for: outputRaster).requirements else {
            throw .format
        }
        return Self(id: id, native: native, source: input, destination: output)
    }
}

@available(iOS 26.0, *)
private final class VTSRSession {
    private struct FramePair {
        let source: VTFrameProcessorFrame
        let output: VTFrameProcessorFrame
    }

    let configuration: VTSRConfiguration
    private var processor: VTFrameProcessor?
    private var lastSubmittedPTS: CMTime?
    private var history: FramePair?
    private var destinationPool: VideoSuperResolutionPool?
    private var stagingPool: VideoSuperResolutionPool?

    init(configuration: VTSRConfiguration) {
        self.configuration = configuration
    }

    deinit { endSession() }

    func flush() {
        history = nil
        lastSubmittedPTS = nil
    }

    func canReuse(_ id: VTSRConfiguration.Identifier, at pts: CMTime) -> Bool {
        configuration.id == id && processor != nil && (lastSubmittedPTS.map { pts > $0 } ?? true)
    }

    func upscale(
        _ input: CVPixelBuffer, pts: CMTime, isDirect: Bool, hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        if let lastSubmittedPTS, pts <= lastSubmittedPTS { endSession() }
        let pair = try prepareFrames(input, pts: pts, isDirect: isDirect, hasTimeRemaining: hasTimeRemaining)
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        guard let parameters = makeParameters(pair) else { throw VTSRFailure("VT SR parameters invalid") }
        let processor = try startIfNeeded(hasTimeRemaining: hasTimeRemaining)
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        lastSubmittedPTS = pts
        do {
            try await Self.process(processor, parameters: parameters)
        } catch {
            throw handleNativeError(error, operation: "process")
        }
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let output = pair.output.buffer
        ScaledVideoOutputMetadata.copy(from: input, to: output, colorSpace: .yuvSameAsSource)
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        if case .legacyVideo = configuration.id { history = pair }
        return output
    }

    private func prepareFrames(
        _ input: CVPixelBuffer, pts: CMTime, isDirect: Bool, hasTimeRemaining: @Sendable () -> Bool
    ) throws -> FramePair {
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let source = isDirect ? input : try stage(input, hasTimeRemaining: hasTimeRemaining)
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let requirements = configuration.destination
        let pool = try destinationPool ?? VideoSuperResolutionPool(
            attributes: requirements.poolAttributes, label: "VT SR destination", followsDisplayLookahead: true,
            isCompatible: requirements.accepts
        )
        destinationPool = pool
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let output = try pool.allocate()
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let outputFrame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts) else {
            throw VTSRFailure("VT SR frame parameters invalid")
        }
        return FramePair(source: sourceFrame, output: outputFrame)
    }

    private func stage(_ input: CVPixelBuffer, hasTimeRemaining: @Sendable () -> Bool) throws -> CVPixelBuffer {
        let requirements = configuration.source
        let pool = try stagingPool ?? VideoSuperResolutionPool(
            attributes: requirements.poolAttributes, label: "VT SR staging", limit: 2,
            isCompatible: requirements.accepts
        )
        stagingPool = pool
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let staged = try pool.allocate()
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        do {
            try VTNV12StagingCopy.copy(from: input, to: staged)
        } catch {
            throw VTSRFailure("VT SR NV12 staging failed")
        }
        return staged
    }

    private func makeParameters(_ pair: FramePair) -> (any VTFrameProcessorParameters)? {
        if case .lowLatency = configuration.id {
            return VTLowLatencySuperResolutionScalerParameters(sourceFrame: pair.source, destinationFrame: pair.output)
        }
        let previous = history.flatMap { reference in
            reference.source.presentationTimeStamp < pair.source.presentationTimeStamp
                && VideoFramePairFormat.matches(reference.source.buffer, pair.source.buffer) ? reference : nil
        }
        return VTSuperResolutionScalerParameters(
            sourceFrame: pair.source, previousFrame: previous?.source, previousOutputFrame: previous?.output,
            opticalFlow: nil, submissionMode: previous == nil ? .random : .sequential, destinationFrame: pair.output
        )
    }

    private func startIfNeeded(hasTimeRemaining: @Sendable () -> Bool) throws -> VTFrameProcessor {
        if let processor { return processor }
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let newProcessor = VTFrameProcessor()
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        do {
            try newProcessor.startSession(configuration: configuration.native)
        } catch {
            throw handleNativeError(error, operation: "start")
        }
        processor = newProcessor
        return newProcessor
    }

    private func endSession() {
        processor?.endSession()
        processor = nil
        lastSubmittedPTS = nil
        flush()
    }

    private func handleNativeError(_ error: Error, operation: String) -> VTSRFailure {
        let nsError = error as NSError
        let code = nsError.domain == VTFrameProcessorError.errorDomain
            ? VTFrameProcessorError.Code(rawValue: nsError.code) : nil
        switch code {
        case .unsupportedResolution, .revisionNotSupported:
            endSession()
            return VTSRFailure("VT SR native configuration rejected (\(nsError.code))", rejectsConfiguration: true)
        case .fatalError, .sessionLevelError, .sessionNotStarted, .invalidFrameTiming, .assetDownloadFailed:
            endSession()
        default:
            flush()
        }
        return VTSRFailure("VT SR \(operation) failed (\(nsError.code))")
    }

    private static func process(
        _ processor: VTFrameProcessor, parameters: any VTFrameProcessorParameters
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
#endif
