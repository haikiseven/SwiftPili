import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Pure, simulator-testable source/destination pixel-format negotiation helpers for VideoToolbox
/// frame interpolation (`VTLowLatencyFrameInterpolationConfiguration` and
/// `VTFrameRateConversionConfiguration`).
enum VTInterpolationFormatNegotiation {
    struct FormatPair: Equatable, Sendable {
        let source: OSType
        let destination: OSType
    }

    static func canStage(inputFormat: OSType, targetFormat: OSType) -> Bool {
        if inputFormat == targetFormat {
            return MetalNV12PixelConverter.isNV12(inputFormat)
                || inputFormat == kCVPixelFormatType_32BGRA
        }
        if MetalNV12PixelConverter.isNV12(inputFormat) {
            return MetalNV12PixelConverter.isNV12(targetFormat)
                || targetFormat == kCVPixelFormatType_32BGRA
        }
        return false
    }

    /// Returns prioritized `(source, destination)` format pairs compatible with `nativeSupported`,
    /// `sourceAttributeFormats`, `destinationAttributeFormats`, and GPU staging from `inputFormat`.
    /// Prefers zero-copy matching `inputFormat` first, and prefers symmetric `destination == source`.
    static func candidateFormatPairs(
        inputFormat: OSType,
        nativeSupported: [OSType],
        sourceAttributeFormats: [OSType],
        destinationAttributeFormats: [OSType]
    ) -> [FormatPair] {
        let sourceCandidates = VTSRNegotiation.candidateFormats(
            preferred: VTSRNegotiation.sourceFormatPriority(for: inputFormat),
            nativeSupported: nativeSupported,
            attributeFormats: sourceAttributeFormats
        ).filter { candidate in
            candidate == inputFormat || canStage(inputFormat: inputFormat, targetFormat: candidate)
        }

        var pairs: [FormatPair] = []
        for sourceFormat in sourceCandidates {
            let destPreferred = VTSRNegotiation.destinationFormatPriority(for: sourceFormat)
            var destCandidates = VTSRNegotiation.candidateFormats(
                preferred: destPreferred,
                nativeSupported: nativeSupported,
                attributeFormats: destinationAttributeFormats
            )
            if destCandidates.isEmpty, !destinationAttributeFormats.isEmpty {
                destCandidates = VTSRNegotiation.candidateFormats(
                    preferred: destPreferred,
                    nativeSupported: [],
                    attributeFormats: destinationAttributeFormats
                )
            }
            for destFormat in destCandidates {
                let pair = FormatPair(source: sourceFormat, destination: destFormat)
                if !pairs.contains(pair) {
                    pairs.append(pair)
                }
            }
        }
        return pairs
    }

    static func selectFormatPair(
        inputFormat: OSType,
        nativeSupported: [OSType],
        sourceAttributeFormats: [OSType],
        destinationAttributeFormats: [OSType]
    ) -> FormatPair? {
        candidateFormatPairs(
            inputFormat: inputFormat,
            nativeSupported: nativeSupported,
            sourceAttributeFormats: sourceAttributeFormats,
            destinationAttributeFormats: destinationAttributeFormats
        ).first
    }
}

enum VideoInterpolationBackendOutcome {
    case interpolated(frames: [MediaVideoFrame])
    case passthrough
    case bypassed(reason: String)
}

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
    private let pixelConverter = MetalNV12PixelConverter()
    private var rejectedConfigurations: [RejectedConfiguration] = []
    private var loggedEvents: [DiagnosticKey] = []
    #endif

    func flush() {
        #if !targetEnvironment(simulator)
        previousFrame = nil
        hasSubmittedPair = false
        pixelConverter.flush()
        #endif
    }

    func tearDown() {
        flush()
        #if !targetEnvironment(simulator)
        sessionStorage = nil
        pixelConverter.tearDown()
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
        guard VideoFrameInterpolationTiming.sourceFPS(frame) != nil else {
            return bypass("VT FI invalid source timing")
        }
        if let reason = VideoFramePairFormat.interpolationBypassReason(frame.pixelBuffer) {
            return bypass(reason)
        }
        guard hasTimeRemaining() else {
            // Preserve the current frame as reference so the very next pair interpolates immediately
            // via `.random` mode instead of dropping two consecutive pairs.
            previousFrame = StoredFrame(frame)
            hasSubmittedPair = false
            return .bypassed(reason: VTInterpolationFailure.deadline.reason)
        }
        guard let plan, let previous = previousFrame,
              VideoFrameInterpolationTiming(
                previousPTS: previous.pts,
                previousDuration: previous.duration,
                current: frame,
                expectedInterval: plan.sourceInterval
              ) != nil, VideoFramePairFormat.matches(previous.pixelBuffer, frame.pixelBuffer) else {
            flush()
            previousFrame = StoredFrame(frame)
            return .passthrough
        }
        guard !plan.phases.isEmpty else {
            previousFrame = StoredFrame(frame)
            hasSubmittedPair = false
            return .passthrough
        }

        let raster = VTInterpolationRaster(frame.pixelBuffer)
        let key = VTInterpolationSessionKey(raster: raster, plan: plan)
        do {
            let session = try ensureSession(
                key,
                input: frame.pixelBuffer,
                initialPhaseCount: plan.phases.count,
                previousPTS: previous.pts,
                hasTimeRemaining: hasTimeRemaining
            )
            return try await synthesize(
                previous: previous, current: frame, plan: plan, session: session, hasTimeRemaining: hasTimeRemaining
            )
        } catch let failure as VTInterpolationFailure {
            if let detail = failure.detail { logOnce(raster, event: failure.reason, detail) }
            if failure.preservesReference {
                previousFrame = StoredFrame(frame)
                hasSubmittedPair = false
                return .bypassed(reason: failure.reason)
            }
            return bypass(failure.reason)
        } catch {
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
        initialPhaseCount: Int,
        previousPTS: TimeInterval,
        hasTimeRemaining: @Sendable () -> Bool
    ) throws -> VTInterpolationSession {
        if let session = sessionStorage as? VTInterpolationSession,
           session.canReuse(key, previousPTS: previousPTS) { return session }
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        sessionStorage = nil
        hasSubmittedPair = false
        let raster = key.raster
        var rejected: [String] = []
        for kind in VTInterpolationKind.candidates(for: key) {
            guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
            if let cached = rejectedConfigurations.first(where: { $0.key == key && $0.kind == kind }) {
                rejected.append(cached.detail)
                continue
            }
            do {
                let configuration = try kind.negotiate(key).get()
                let session = try VTInterpolationSession(
                    key: key,
                    kind: kind,
                    configuration: configuration,
                    initialPhaseCount: initialPhaseCount,
                    hasTimeRemaining: hasTimeRemaining
                )
                sessionStorage = session
                logOnce(raster, event: "\(kind.rawValue) negotiation mode=\(key.mode.diagnosticLabel)",
                        "\(configuration.detail) startup=0 " +
                    "sourcePadding=\(configuration.source.padding) " +
                    "destinationPadding=\(configuration.destination.padding) " +
                    "inputPadding=\(VTInterpolationPadding(input)) " +
                    "rejected=[\(rejected.joined(separator: " | "))]")
                return session
            } catch let failure as VTInterpolationFailure {
                guard failure.isIncompatible else { throw failure }
                let detail = failure.detail ?? failure.reason
                reject(key, kind: kind, detail: detail)
                rejected.append(detail)
            }
        }
        logOnce(
            raster,
            event: "negotiation mode=\(key.mode.diagnosticLabel)",
            "rejected=[\(rejected.joined(separator: " | "))]"
        )
        throw VTInterpolationFailure.unsupported
    }

    func reject(_ key: VTInterpolationSessionKey, kind: VTInterpolationKind, detail: String) {
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
        let previousInput = previous.staged.flatMap(session.directInput) ?? session.directInput(previous.pixelBuffer)
        let currentInput = session.directInput(current.pixelBuffer)
        if previousInput == nil || currentInput == nil {
            logOnce(session.key.raster, event: "input layout", session.layoutDetail(
                previous: previous.pixelBuffer, current: current.pixelBuffer
            ))
        }
        session.recordPhaseCount(plan.phases.count)
        let destinations = try plan.phases.map { _ in
            try session.destination.allocate()
        }
        let prev: CVPixelBuffer
        if let previousInput {
            prev = previousInput
        } else {
            prev = try await session.stage(previous.pixelBuffer, pixelConverter: pixelConverter)
        }
        let next: CVPixelBuffer
        if let currentInput {
            next = currentInput
        } else {
            next = try await session.stage(current.pixelBuffer, pixelConverter: pixelConverter)
        }
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let request = VTInterpolationSession.Request(
            previous: (prev, previous.pts), current: (next, current.pts),
            plan: plan, destinations: destinations, sequential: hasSubmittedPair
        )
        try await session.process(request)
        // Never discard already-computed hardware output once `process` succeeds.
        let outputColorSpace: ScaledVideoOutputMetadata.OutputColorSpace =
            session.destination.requirements.raster.format == kCVPixelFormatType_32BGRA
                ? .rgbConverted : .yuvSameAsSource
        for output in destinations {
            ScaledVideoOutputMetadata.copy(from: current.pixelBuffer, to: output, colorSpace: outputColorSpace)
        }
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

private enum VTInterpolationSessionMode: Equatable {
    /// Exact uniform dyadic plans (`[0.5]` → level 1, `[0.25, 0.5, 0.75]` → level 2),
    /// eligible for `VTLowLatencyFrameInterpolationConfiguration`.
    case dyadic(lowLatencyLevel: Int)
    /// Arbitrary phases in `(0, 1)` (non-dyadic integer multiples 3×/5× and CFR resampling),
    /// routed exclusively to a single persistent `VTFrameRateConversionConfiguration` session
    /// even when `plan.phases.count` varies across consecutive pairs.
    case arbitraryPhases

    var diagnosticLabel: String {
        switch self {
        case let .dyadic(level): "dyadic(\(level))"
        case .arbitraryPhases: "arbitrary"
        }
    }
}

private struct VTInterpolationSessionKey: Equatable {
    let raster: VTInterpolationRaster
    let mode: VTInterpolationSessionMode

    init(raster: VTInterpolationRaster, plan: VideoFrameInterpolationPlan) {
        self.raster = raster
        if plan.allowsLowLatency, let level = Self.lowLatencyLevel(forPhaseCount: plan.phases.count) {
            mode = .dyadic(lowLatencyLevel: level)
        } else {
            mode = .arbitraryPhases
        }
    }

    /// `VTLowLatencyFrameInterpolationConfiguration` exposes `2^x - 1` dyadic points
    /// (`1` → `[0.5]`, `2` → `[0.25, 0.5, 0.75]`). Plans with `allowsLowLatency == false`
    /// (including single-phase CFR pairs like `[0.42]`) always return `nil` and use
    /// `VTFrameRateConversionConfiguration`.
    var lowLatencyLevel: Int? {
        if case let .dyadic(level) = mode { return level }
        return nil
    }

    var expectedLowLatencyPhaseCount: Int? {
        switch lowLatencyLevel {
        case 1: 1
        case 2: 3
        default: nil
        }
    }

    private static func lowLatencyLevel(forPhaseCount count: Int) -> Int? {
        switch count {
        case 1: 1
        case 3: 2
        default: nil
        }
    }
}

private enum VTInterpolationKind: String {
    case lowLatency = "LLFI"

    static func candidates(for key: VTInterpolationSessionKey) -> [Self] {
        key.lowLatencyLevel != nil ? [.lowLatency] : []
    }

    @available(iOS 26.0, *)
    func negotiate(
        _ key: VTInterpolationSessionKey
    ) -> Result<VTInterpolationSession.Configuration, VTInterpolationFailure> {
        let raster = key.raster
        switch self {
        case .lowLatency:
            guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { return unavailable("device") }
            guard let level = key.lowLatencyLevel else { return unavailable("phases") }
            guard let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, numberOfInterpolatedFrames: level
            ) else { return unavailable("dimensions") }
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
            let sourceAttrFormats = VTSRNegotiation.attributeFormats(from: source)
            let destAttrFormats = VTSRNegotiation.attributeFormats(from: destination)
            let pairs = VTInterpolationFormatNegotiation.candidateFormatPairs(
                inputFormat: raster.format,
                nativeSupported: formats,
                sourceAttributeFormats: sourceAttrFormats,
                destinationAttributeFormats: destAttrFormats
            )
            let configurationStatuses = [
                kCVReturnSuccess, kCVReturnInvalidArgument, kCVReturnInvalidPixelFormat,
                kCVReturnInvalidSize, kCVReturnInvalidPixelBufferAttributes
            ]
            var lastSourceStatus: CVReturn = kCVReturnInvalidPixelFormat
            var lastDestStatus: CVReturn = kCVReturnInvalidPixelFormat
            var sawNonConfigurationStatus = false
            var attempted: [String] = []

            for pair in pairs {
                let sourceRaster = VTInterpolationRaster(width: raster.width, height: raster.height, format: pair.source)
                let destRaster = VTInterpolationRaster(width: raster.width, height: raster.height, format: pair.destination)
                let input = VTInterpolationBufferRequirements.resolve(source, for: sourceRaster)
                let output = VTInterpolationBufferRequirements.resolve(destination, for: destRaster)
                lastSourceStatus = input.status
                lastDestStatus = output.status
                if !configurationStatuses.contains(input.status) || !configurationStatuses.contains(output.status) {
                    sawNonConfigurationStatus = true
                }
                if let sourceRequirement = input.requirements, let destinationRequirement = output.requirements {
                    let detail = "\(kind.rawValue) supported=\(VTSRNegotiation.formatsDescription(formats)) " +
                        "sourceFormats=\(VTSRNegotiation.formatsDescription(sourceAttrFormats)) " +
                        "destinationFormats=\(VTSRNegotiation.formatsDescription(destAttrFormats)) " +
                        "selectedSource=\(VTInterpolationRaster.fourCC(pair.source)) " +
                        "selectedDest=\(VTInterpolationRaster.fourCC(pair.destination)) " +
                        "sourceResolve=\(input.status) destinationResolve=\(output.status)"
                    return .success(Self(
                        native: native, source: sourceRequirement, destination: destinationRequirement, detail: detail
                    ))
                }
                attempted.append(
                    "\(VTInterpolationRaster.fourCC(pair.source))->\(VTInterpolationRaster.fourCC(pair.destination))" +
                    "(src=\(input.status),dst=\(output.status))"
                )
            }

            let detail = "\(kind.rawValue) supported=\(VTSRNegotiation.formatsDescription(formats)) " +
                "sourceFormats=\(VTSRNegotiation.formatsDescription(sourceAttrFormats)) " +
                "destinationFormats=\(VTSRNegotiation.formatsDescription(destAttrFormats)) " +
                "selectedSource=none selectedDest=none " +
                "sourceResolve=\(lastSourceStatus) destinationResolve=\(lastDestStatus) " +
                "attempted=[\(attempted.joined(separator: ","))]"
            if sawNonConfigurationStatus {
                return .failure(VTInterpolationFailure(reason: "VT FI attribute resolution failed", detail: detail))
            }
            return .failure(.incompatible(detail))
        }
    }

    private final class PhaseCountBox {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    let key: VTInterpolationSessionKey
    let source: VTInterpolationBufferRequirements
    let destination: VTInterpolationPool
    let kind: VTInterpolationKind
    private let processor: VTFrameProcessor
    private let maxPhaseCount: PhaseCountBox
    private var stagingPool: VTInterpolationPool?
    private var lastLLFISourcePTS: TimeInterval?

    init(
        key: VTInterpolationSessionKey,
        kind: VTInterpolationKind,
        configuration: Configuration,
        initialPhaseCount: Int,
        hasTimeRemaining: @Sendable () -> Bool
    ) throws {
        guard hasTimeRemaining() else { throw VTInterpolationFailure.deadline }
        let initialLimitPhaseCount = key.mode == .arbitraryPhases
            ? max(2, initialPhaseCount)
            : max(1, initialPhaseCount)
        let maxPhaseCount = PhaseCountBox(initialLimitPhaseCount)
        let destination = try VTInterpolationPool(
            requirements: configuration.destination, role: "destination",
            dynamicLimit: {
                VideoFrameInterpolationPlan.outputPoolLimit(phaseCount: maxPhaseCount.value)
            }
        )
        let processor = VTFrameProcessor()
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
        self.maxPhaseCount = maxPhaseCount
    }

    deinit {
        processor.endSession()
    }

    func recordPhaseCount(_ count: Int) {
        if count > maxPhaseCount.value {
            maxPhaseCount.value = count
        }
    }

    func canReuse(_ key: VTInterpolationSessionKey, previousPTS: TimeInterval) -> Bool {
        self.key == key && (lastLLFISourcePTS.map { previousPTS >= $0 } ?? true)
    }

    private var canStageInput: Bool {
        VTInterpolationFormatNegotiation.canStage(
            inputFormat: key.raster.format,
            targetFormat: source.raster.format
        )
    }

    func layoutDetail(previous: CVPixelBuffer, current: CVPixelBuffer) -> String {
        "\(kind.rawValue) sourceRaster=\(source.raster.description) " +
            "destRaster=\(destination.requirements.raster.description) " +
            "sourcePadding=\(source.padding) destinationPadding=\(destination.requirements.padding) " +
            "previousPadding=\(VTInterpolationPadding(previous)) currentPadding=\(VTInterpolationPadding(current)) " +
            "previousIOSurface=\(CVPixelBufferGetIOSurface(previous) != nil) " +
            "currentIOSurface=\(CVPixelBufferGetIOSurface(current) != nil) " +
            "stagingAllowed=\(canStageInput)"
    }

    func directInput(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        source.accepts(input) ? input : nil
    }

    func stage(_ input: CVPixelBuffer, pixelConverter: MetalNV12PixelConverter) async throws -> CVPixelBuffer {
        let inputFormat = CVPixelBufferGetPixelFormatType(input)
        let targetFormat = source.raster.format
        guard VTInterpolationFormatNegotiation.canStage(inputFormat: inputFormat, targetFormat: targetFormat) else {
            throw VTInterpolationFailure(reason: "VT FI decoded buffers do not meet source requirements")
        }
        let pool = try stagingPool ?? VTInterpolationPool(
            requirements: source, role: "source staging", limit: 6, metalCompatible: true
        )
        stagingPool = pool
        let staged = try pool.allocate()
        let sameNV12 = inputFormat == targetFormat && MetalNV12PixelConverter.isNV12(inputFormat)
        if sameNV12 {
            try await VTNV12StagingCopy.copyAsync(from: input, to: staged)
            return staged
        }
        let converted = await pixelConverter.convert(from: input, to: staged)
        guard converted else {
            let srcCC = VTInterpolationRaster.fourCC(inputFormat)
            let dstCC = VTInterpolationRaster.fourCC(targetFormat)
            throw VTInterpolationFailure(reason: "VT FI GPU staging failed (\(srcCC)->\(dstCC))")
        }
        let stagedColorSpace: ScaledVideoOutputMetadata.OutputColorSpace =
            targetFormat == kCVPixelFormatType_32BGRA ? .rgbConverted : .yuvSameAsSource
        ScaledVideoOutputMetadata.copy(from: input, to: staged, colorSpace: stagedColorSpace)
        return staged
    }

    struct Request {
        let previous: (buffer: CVPixelBuffer, pts: TimeInterval)
        let current: (buffer: CVPixelBuffer, pts: TimeInterval)
        let plan: VideoFrameInterpolationPlan
        let destinations: [CVPixelBuffer]
        let sequential: Bool
    }

    func process(_ request: Request) async throws {
        guard let parameters = parameters(for: request) else {
            throw VTInterpolationFailure(reason: "VT FI params invalid")
        }
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
              !plan.phases.isEmpty,
              plan.phases.count == plan.pts.count,
              request.destinations.count == plan.phases.count,
              let prev = VTFrameProcessorFrame(buffer: request.previous.buffer, presentationTimeStamp: prevTime),
              let curr = VTFrameProcessorFrame(buffer: request.current.buffer, presentationTimeStamp: currTime) else {
            return nil
        }
        if kind == .lowLatency {
            guard let expectedCount = key.expectedLowLatencyPhaseCount,
                  plan.phases.count == expectedCount else { return nil }
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
    var preservesReference = false

    static let deadline = Self(reason: "VT FI deadline", preservesReference: true)
    static let unsupported = Self(reason: "VT FI native configuration unsupported")

    static func incompatible(_ detail: String) -> Self {
        Self(reason: unsupported.reason, detail: detail, isIncompatible: true)
    }
}
#endif
