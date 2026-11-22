import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum VideoInterpolationBackendOutcome {
    case interpolated(frames: [MediaVideoFrame])
    case passthrough
    case bypassed(reason: String)
}

/// Single-owner VideoToolbox interpolation backend. The postprocessor's serial
/// worker owns the pair and waits for the actual VT callback before recycling it.
final class VideoToolboxFrameInterpolationBackend {
    #if !targetEnvironment(simulator)
    private struct StoredFrame {
        let pixelBuffer: CVPixelBuffer
        let pts: TimeInterval
        let duration: TimeInterval
        let staged: CVPixelBuffer?

        init(_ frame: MediaVideoFrame, staged: CVPixelBuffer? = nil) {
            pixelBuffer = frame.pixelBuffer
            pts = frame.pts
            duration = frame.duration
            self.staged = staged
        }
    }

    private var previousFrame: StoredFrame?
    private var hasSubmittedPair = false
    private var sessionStorage: AnyObject?
    private var rejectedConfigurations: [RejectedConfiguration] = []
    private var loggedEvents: [DiagnosticKey] = []
    #endif

    /// Drops the worker's references. Native session reuse is decided when the
    /// next valid pair arrives, so deadline bypasses can leave the model warm.
    func flush() {
        #if !targetEnvironment(simulator)
        previousFrame = nil
        hasSubmittedPair = false
        #endif
    }

    func tearDown() {
        flush()
        #if !targetEnvironment(simulator)
        sessionStorage = nil
        #endif
    }

    func process(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        #if targetEnvironment(simulator)
        return .bypassed(reason: "Simulator unsupported")
        #else
        guard #available(iOS 26.0, *) else {
            return .bypassed(reason: "Requires iOS 26")
        }
        return await processIOS26(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
        #endif
    }
}

#if !targetEnvironment(simulator)
private extension VideoToolboxFrameInterpolationBackend {
    struct RejectedConfiguration {
        let key: VTInterpolationSessionKey
        let kind: VTInterpolationKind
        let detail: String
    }

    struct DiagnosticKey: Equatable {
        let raster: VTInterpolationRaster
        let event: String
    }

    @available(iOS 26.0, *)
    func processIOS26(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        guard hasTimeRemaining() else { return bypass("VT FI deadline") }
        guard VideoFrameInterpolationTiming.sourceFPS(frame) != nil else {
            return bypass("VT FI invalid source timing")
        }
        if let reason = VideoFramePairFormat.interpolationBypassReason(frame.pixelBuffer) {
            return bypass(reason)
        }
        guard let plan, let previous = previousFrame,
              VideoFrameInterpolationTiming(
                previousPTS: previous.pts, previousDuration: previous.duration, current: frame
              ) != nil, VideoFramePairFormat.matches(previous.pixelBuffer, frame.pixelBuffer) else {
            flush()
            previousFrame = StoredFrame(frame)
            return .passthrough
        }

        let raster = VTInterpolationRaster(frame.pixelBuffer)
        let key = VTInterpolationSessionKey(raster: raster, phaseCount: plan.phases.count)
        do {
            let session = try ensureSession(
                key, input: frame.pixelBuffer, previousPTS: previous.pts, hasTimeRemaining: hasTimeRemaining
            )
            return try await synthesize(
                previous: previous, current: frame, plan: plan, session: session, hasTimeRemaining: hasTimeRemaining
            )
        } catch let failure as VTInterpolationFailure {
            if let detail = failure.detail { logOnce(raster, event: failure.reason, detail) }
            return bypass(failure.reason)
        } catch {
            // Only the processing callback can throw an unwrapped framework error.
            let error = error as NSError
            logOnce(raster, event: "process \(error.domain)/\(error.code)", "callback failed")
            recoverFromCallbackError(error)
            return bypass("VT FI process error")
        }
    }

    @available(iOS 26.0, *)
    func recoverFromCallbackError(_ error: NSError) {
        let code = VTFrameProcessorError.Code.from(error)
        if code?.rejectsConfiguration == true, let session = sessionStorage as? VTInterpolationSession {
            let detail = "\(session.kind.rawValue) process=\(error.domain)/\(error.code)"
            reject(session.key, kind: session.kind, detail: detail)
            sessionStorage = nil
            return
        }
        switch code {
        case .fatalError, .sessionNotStarted, .sessionLevelError:
            sessionStorage = nil
        case .invalidFrameTiming:
            // FRC can clear its cache with the next random submission.
            if (sessionStorage as? VTInterpolationSession)?.kind == .lowLatency { sessionStorage = nil }
        default:
            if error.domain == NSOSStatusErrorDomain,
               error.code == Int(kVTInvalidSessionErr) || error.code == Int(kVTSessionMalfunctionErr) {
                sessionStorage = nil
            }
        }
    }

    func bypass(_ reason: String) -> VideoInterpolationBackendOutcome {
        flush()
        return .bypassed(reason: reason)
    }

    @available(iOS 26.0, *)
    func ensureSession(
        _ key: VTInterpolationSessionKey,
        input: CVPixelBuffer,
        previousPTS: TimeInterval,
        hasTimeRemaining: @Sendable () -> Bool
    ) throws -> VTInterpolationSession {
        if let session = sessionStorage as? VTInterpolationSession,
           session.canReuse(key, previousPTS: previousPTS) { return session }
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        // Replacing the hardware session only breaks VT's sequential mode. The
        // validated original pair is still usable for the first submission.
        sessionStorage = nil
        hasSubmittedPair = false
        let raster = key.raster
        var rejected: [String] = []
        for kind in VTInterpolationKind.candidates(for: raster) {
            guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
            if let cached = rejectedConfigurations.first(where: { $0.key == key && $0.kind == kind }) {
                rejected.append(cached.detail)
                continue
            }
            do {
                let configuration = try kind.negotiate(key).get()
                let session = try VTInterpolationSession(
                    key: key, kind: kind, configuration: configuration, hasTimeRemaining: hasTimeRemaining
                )
                sessionStorage = session
                logOnce(raster, event: "\(kind.rawValue) negotiation phases=\(key.phaseCount)",
                        "\(configuration.detail) startup=0 " +
                    "sourcePadding=\(configuration.source.padding) " +
                    "destinationPadding=\(configuration.destination.padding) " +
                    "inputPadding=\(VTInterpolationPadding(input)) \(rejected.joined(separator: " | "))")
                return session
            } catch let failure as VTInterpolationFailure {
                guard failure.isIncompatible else { throw failure }
                let detail = failure.detail ?? failure.reason
                reject(key, kind: kind, detail: detail)
                rejected.append(detail)
            }
        }
        logOnce(raster, event: "negotiation phases=\(key.phaseCount)", rejected.joined(separator: " | "))
        throw VTInterpolationFailure.unsupported
    }

    func reject(_ key: VTInterpolationSessionKey, kind: VTInterpolationKind, detail: String) {
        // Only device/configuration verdicts enter this cache. Individual
        // source buffers, resource pressure, and deadlines vary per attempt.
        if rejectedConfigurations.count == 32 { rejectedConfigurations.removeFirst() }
        rejectedConfigurations.append(RejectedConfiguration(key: key, kind: kind, detail: detail))
    }

    @available(iOS 26.0, *)
    private func synthesize(
        previous: StoredFrame,
        current: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan,
        session: VTInterpolationSession,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> VideoInterpolationBackendOutcome {
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let previousInput = previous.staged.flatMap(session.directInput) ?? session.directInput(previous.pixelBuffer)
        let currentInput = session.directInput(current.pixelBuffer)
        if previousInput == nil || currentInput == nil {
            logOnce(session.key.raster, event: "input layout", session.layoutDetail(
                previous: previous.pixelBuffer, current: current.pixelBuffer
            ))
        }
        let destinations = try plan.phases.map { _ in
            guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
            let output = try session.destination.allocate()
            VideoFramePairFormat.copyInterpretation(from: current.pixelBuffer, to: output)
            return output
        }
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let prev = try previousInput ?? session.stage(previous.pixelBuffer)
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let next = try currentInput ?? session.stage(current.pixelBuffer)
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let request = VTInterpolationSession.Request(
            previous: (prev, previous.pts), current: (next, current.pts),
            plan: plan, destinations: destinations, sequential: hasSubmittedPair
        )
        try await session.process(request, hasTimeRemaining: hasTimeRemaining)
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        // VT may modify destination attachments. Restore the original's
        // interpretation only after the actual completion callback.
        for output in destinations {
            VideoFramePairFormat.copyInterpretation(from: current.pixelBuffer, to: output)
        }
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        previousFrame = StoredFrame(current, staged: currentInput == nil ? next : nil)
        hasSubmittedPair = true
        return .interpolated(frames: plan.makeFrames(buffers: destinations))
    }

    func logOnce(_ raster: VTInterpolationRaster, event: String, _ detail: @autoclosure () -> String) {
        guard PlayerLog.isCapturing else { return }
        let key = DiagnosticKey(raster: raster, event: event)
        guard !loggedEvents.contains(key) else { return }
        if loggedEvents.count == 32 { loggedEvents.removeFirst() }
        loggedEvents.append(key)
        PlayerLog.log("[VT FI] input=\(raster.description) event=\(event) \(detail())")
    }
}

private struct VTInterpolationSessionKey: Equatable {
    let raster: VTInterpolationRaster
    let phaseCount: Int

    // LLFI exposes 2^level - 1 evenly spaced phases for temporal interpolation.
    var lowLatencyLevel: Int { phaseCount == 3 ? 2 : 1 }
}

private enum VTInterpolationKind: String {
    case lowLatency = "LLFI"
    case frameRateConversion = "FRC"

    static func candidates(for raster: VTInterpolationRaster) -> [Self] {
        raster.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ? [.lowLatency, .frameRateConversion] : [.frameRateConversion]
    }

    @available(iOS 26.0, *)
    func negotiate(
        _ key: VTInterpolationSessionKey
    ) -> Result<VTInterpolationSession.Configuration, VTInterpolationFailure> {
        let raster = key.raster
        switch self {
        case .lowLatency:
            guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { return unavailable("device") }
            guard let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, numberOfInterpolatedFrames: key.lowLatencyLevel
            ) else { return unavailable("dimensions") }
            return VTInterpolationSession.Configuration.resolve(
                config, kind: self, formats: config.supportedPixelFormats, raster: raster
            )
        case .frameRateConversion:
            guard VTFrameRateConversionConfiguration.isSupported else { return unavailable("device") }
            guard let config = VTFrameRateConversionConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, usePrecomputedFlow: false,
                qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision
            ) else { return unavailable("dimensions/revision") }
            return VTInterpolationSession.Configuration.resolve(
                config, kind: self, formats: config.supportedPixelFormats, raster: raster
            )
        }
    }

    @available(iOS 26.0, *)
    private func unavailable(_ reason: String) -> Result<VTInterpolationSession.Configuration, VTInterpolationFailure> {
        .failure(.incompatible("\(rawValue) config=unsupported(\(reason))"))
    }
}

@available(iOS 26.0, *)
private final class VTInterpolationSession {
    struct Configuration {
        let native: any VTFrameProcessorConfiguration
        let source: VTInterpolationBufferRequirements
        let destination: VTInterpolationBufferRequirements
        let detail: String

        static func resolve(
            _ native: any VTFrameProcessorConfiguration,
            kind: VTInterpolationKind,
            formats: [OSType],
            raster: VTInterpolationRaster
        ) -> Result<Self, VTInterpolationFailure> {
            let source = native.sourcePixelBufferAttributes
            let destination = native.destinationPixelBufferAttributes
            let input = VTInterpolationBufferRequirements.resolve(source, for: raster)
            let output = VTInterpolationBufferRequirements.resolve(destination, for: raster)
            let detail = "\(kind.rawValue) supported=\(formats.map(VTInterpolationRaster.fourCC)) " +
                "sourceFormats=\(VTInterpolationBufferRequirements.formatsDescription(source)) " +
                "destinationFormats=\(VTInterpolationBufferRequirements.formatsDescription(destination)) " +
                "sourceResolve=\(input.status) destinationResolve=\(output.status)"
            guard formats.contains(raster.format) else { return .failure(.incompatible(detail)) }
            let configurationStatuses = [
                kCVReturnSuccess, kCVReturnInvalidArgument, kCVReturnInvalidPixelFormat,
                kCVReturnInvalidSize, kCVReturnInvalidPixelBufferAttributes
            ]
            guard configurationStatuses.contains(input.status), configurationStatuses.contains(output.status) else {
                return .failure(VTInterpolationFailure(reason: "VT FI attribute resolution failed", detail: detail))
            }
            guard let sourceRequirement = input.requirements, let destinationRequirement = output.requirements else {
                return .failure(.incompatible(detail))
            }
            return .success(Self(
                native: native, source: sourceRequirement, destination: destinationRequirement, detail: detail
            ))
        }
    }

    let key: VTInterpolationSessionKey
    let source: VTInterpolationBufferRequirements
    let destination: VTInterpolationPool
    let kind: VTInterpolationKind
    private let processor: VTFrameProcessor
    private var stagingPool: VTInterpolationPool?
    private var lastLLFISourcePTS: TimeInterval?

    init(
        key: VTInterpolationSessionKey,
        kind: VTInterpolationKind,
        configuration: Configuration,
        hasTimeRemaining: @Sendable () -> Bool
    ) throws {
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let destination = try VTInterpolationPool(
            requirements: configuration.destination, role: "destination",
            limit: VideoFrameInterpolationPlan.outputPoolLimit(phaseCount: key.phaseCount)
        )
        let processor = VTFrameProcessor()
        // Model loading can overrun a frame budget. Avoid starting it after
        // expiration and keep a successful session warm for subsequent pairs.
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        do {
            try processor.startSession(configuration: configuration.native)
        } catch {
            let error = error as NSError
            let detail = "\(configuration.detail) startup=\(error.domain)/\(error.code)"
            if VTFrameProcessorError.Code.from(error)?.rejectsConfiguration == true {
                throw VTInterpolationFailure.incompatible(detail)
            }
            throw VTInterpolationFailure(reason: "VT FI session failed", detail: detail)
        }
        self.key = key
        self.kind = kind
        self.source = configuration.source
        self.destination = destination
        self.processor = processor
    }

    deinit {
        processor.endSession()
    }

    func canReuse(_ key: VTInterpolationSessionKey, previousPTS: TimeInterval) -> Bool {
        // LLFI takes an explicit pair but has no random mode. Start a fresh
        // session if a seek or replacement makes the pair overlap its old timeline.
        self.key == key && (lastLLFISourcePTS.map { previousPTS >= $0 } ?? true)
    }

    func layoutDetail(previous: CVPixelBuffer, current: CVPixelBuffer) -> String {
        "\(kind.rawValue) sourcePadding=\(source.padding) destinationPadding=\(destination.requirements.padding) " +
            "previousPadding=\(VTInterpolationPadding(previous)) currentPadding=\(VTInterpolationPadding(current)) " +
            "previousIOSurface=\(CVPixelBufferGetIOSurface(previous) != nil) " +
            "currentIOSurface=\(CVPixelBufferGetIOSurface(current) != nil) " +
            "stagingAllowed=\(kind == .lowLatency)"
    }

    func directInput(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        source.accepts(input) ? input : nil
    }

    func stage(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        guard kind == .lowLatency else {
            throw VTInterpolationFailure(reason: "VT FI decoded buffers do not meet source requirements")
        }
        let pool = try stagingPool ?? VTInterpolationPool(requirements: source, role: "source staging", limit: 2)
        stagingPool = pool
        let staged = try pool.allocate()
        try VTNV12StagingCopy.copy(from: input, to: staged)
        return staged
    }

    struct Request {
        let previous: (buffer: CVPixelBuffer, pts: TimeInterval)
        let current: (buffer: CVPixelBuffer, pts: TimeInterval)
        let plan: VideoFrameInterpolationPlan
        let destinations: [CVPixelBuffer]
        let sequential: Bool
    }

    func process(_ request: Request, hasTimeRemaining: @Sendable () -> Bool) async throws {
        guard let parameters = parameters(for: request) else {
            throw VTInterpolationFailure(reason: "VT FI params invalid")
        }
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        if kind == .lowLatency { lastLLFISourcePTS = request.current.pts }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func parameters(for request: Request) -> (any VTFrameProcessorParameters)? {
        let scale: CMTimeScale = 1_000_000_000
        let prevTime = CMTime(seconds: request.previous.pts, preferredTimescale: scale)
        let currTime = CMTime(seconds: request.current.pts, preferredTimescale: scale)
        let plan = request.plan
        guard prevTime.isNumeric, currTime.isNumeric,
              plan.phases.count == key.phaseCount, plan.pts.count == key.phaseCount,
              request.destinations.count == key.phaseCount,
              let prev = VTFrameProcessorFrame(buffer: request.previous.buffer, presentationTimeStamp: prevTime),
              let curr = VTFrameProcessorFrame(buffer: request.current.buffer, presentationTimeStamp: currTime) else {
            return nil
        }
        var lastTime = prevTime
        var output: [VTFrameProcessorFrame] = []
        for (pts, buffer) in zip(plan.pts, request.destinations) {
            let time = CMTime(seconds: pts, preferredTimescale: scale)
            guard time.isNumeric, lastTime < time, time < currTime,
                  let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else { return nil }
            output.append(frame)
            lastTime = time
        }
        switch kind {
        case .lowLatency:
            return VTLowLatencyFrameInterpolationParameters(
                sourceFrame: curr, previousFrame: prev, interpolationPhase: plan.phases, destinationFrames: output
            )
        case .frameRateConversion:
            return VTFrameRateConversionParameters(
                sourceFrame: prev, nextFrame: curr, opticalFlow: nil, interpolationPhase: plan.phases,
                submissionMode: request.sequential ? .sequential : .random, destinationFrames: output
            )
        }
    }
}

@available(iOS 26.0, *)
private extension VTFrameProcessorError.Code {
    static func from(_ error: NSError) -> Self? {
        guard error.domain == VTFrameProcessorError.errorDomain else { return nil }
        return Self(rawValue: error.code)
    }

    var rejectsConfiguration: Bool {
        self == .unsupportedResolution || self == .revisionNotSupported
    }
}

struct VTInterpolationFailure: Error {
    let reason: String
    var detail: String?
    var isIncompatible = false

    static let deadline = Self(reason: "VT FI deadline")
    static let unsupported = Self(reason: "VT FI native configuration unsupported")

    static func incompatible(_ detail: String) -> Self {
        Self(reason: unsupported.reason, detail: detail, isIncompatible: true)
    }
}
#endif
