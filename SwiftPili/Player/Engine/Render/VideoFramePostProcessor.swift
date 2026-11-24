import CoreMedia
import CoreVideo
import Foundation
import os

private struct VideoFrameEnhancementJob: Sendable {
    let current: PostProcessFrameBox
    let previous: PostProcessFrameBox
    let configuration: VideoEnhancementConfiguration
    let interpolationLabel: String
    let interpolationPlan: VideoFrameInterpolationPlan?
    let deadlines: VideoEnhancementDeadlines
    let upscalingBypassReason: String?
    let superResolutionCap: Float
    let superResolutionTargetDimensions: VideoSuperResolutionDimensions?

    var isUpscaling: Bool { configuration.superResolutionMode != .off && upscalingBypassReason == nil }
}

private enum WorkerCommand: Sendable {
    case process(
        job: VideoFrameEnhancementJob,
        isAlive: @Sendable () -> Bool,
        publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void,
        complete: @Sendable (VideoFrameEnhancementResult) async -> Void
    )
    case flush
    case tearDown
}

private struct WorkerChannelState: Sendable {
    var generation: UInt64 = 0
    var continuation: AsyncStream<WorkerCommand>.Continuation?
}

/// Persistent single-consumer background worker actor that owns the stream lifecycle.
///
/// The non-`Sendable` Metal/VideoToolbox/Vision backends live inside a single persistent
/// `for await` loop task (created lazily on first submission, closed in `deinit`), avoiding
/// per-frame `Task.detached` allocation storms and keeping all hardware sessions strictly serial.
private actor VideoFramePostProcessorActor {
    static func launchLoop(stream: AsyncStream<WorkerCommand>) {
        Task.detached(priority: .userInitiated) {
            await runLoop(stream: stream)
        }
    }

    private nonisolated static func runLoop(stream: AsyncStream<WorkerCommand>) async {
        let pipeline = VideoFramePostProcessorPipeline()
        for await command in stream {
            switch command {
            case let .process(job, isAlive, publishMidpoints, complete):
                let result = await pipeline.process(
                    job,
                    isAlive: isAlive,
                    publishMidpoints: publishMidpoints
                )
                await complete(result)
            case .flush:
                pipeline.flush()
            case .tearDown:
                pipeline.tearDown()
            }
        }
        pipeline.tearDown()
    }
}

@MainActor
final class VideoFramePostProcessor {
    private let workerChannel = OSAllocatedUnfairLock(initialState: WorkerChannelState())
    private var nextJobID: UInt64 = 0
    private var inFlightJobID: UInt64?
    private var cadenceEstimator = VideoFrameCadenceEstimator()
    private var interpolationGridNextPTS: TimeInterval?

    var configuration = VideoEnhancementConfiguration.disabled {
        didSet {
            guard configuration != oldValue else { return }
            pendingExpectation = nil
            telemetryWindow.reset()
            cadenceEstimator.reset()
            interpolationGridNextPTS = nil
            frameTelemetry = configuration.isRequested && configuration.isLiveStream
                ? .bypassed(reason: "VOD only") : VideoEnhancementTelemetry()
        }
    }

    /// State of the most recent frame only; noisy under partial load. UI reads `telemetry`.
    private(set) var frameTelemetry = VideoEnhancementTelemetry()
    private var telemetryWindow = VideoEnhancementTelemetryWindow()
    private var lastProcessingMs: Double = 0
    /// What the in-flight submission was expected to deliver, to detect partial failures in telemetry.
    private var pendingExpectation: (frame: EnhancementFrameIdentity, expectedMidpointCount: Int, upscale: Bool)?

    deinit {
        workerChannel.withLock { state in
            state.generation &+= 1
            state.continuation?.finish()
            state.continuation = nil
        }
    }

    /// Window-aggregated telemetry for the stats overlay / player menu.
    var telemetry: VideoEnhancementTelemetry {
        var value = telemetryWindow.summarize(
            latest: frameTelemetry, configuration: configuration, interpolationLabel: interpolationLabel
        ) ?? frameTelemetry
        if value.smoothedProcessingMs <= 0.01 { value.smoothedProcessingMs = lastProcessingMs }
        value.degradationNote = nil
        return value
    }

    var isBusy: Bool { inFlightJobID != nil }

    /// Set by the renderer on layout / scale-mode changes.
    var displaySurface: VideoEnhancementDisplaySurface?

    /// Steady presentation lookahead requested when video enhancement is active.
    var preferredPresentLeadSeconds: TimeInterval { VideoEnhancementPoolLimits.defaultLead }

    var interpolationLabel: String {
        if #available(iOS 26.0, *) { return "VT FI" }
        return "Vision FI"
    }

    // MARK: - Single-Pass Admission Snapshot

    private enum SuperResolutionResolutionPlan: Equatable {
        case scaleCap(Float)
        case explicitOutput(VideoSuperResolutionDimensions)
        case bypassed(String)

        var resolved: VideoEnhancementSuperResolutionPlan? {
            switch self {
            case let .scaleCap(cap):
                VideoEnhancementSuperResolutionPlan(scaleCap: cap, targetDimensions: nil)
            case let .explicitOutput(dimensions):
                VideoEnhancementSuperResolutionPlan(scaleCap: 0, targetDimensions: dimensions)
            case .bypassed:
                nil
            }
        }

        var bypassReason: String? {
            if case let .bypassed(reason) = self { return reason }
            return nil
        }
    }

    private func resolveSuperResolutionPlan(for frame: MediaVideoFrame) -> SuperResolutionResolutionPlan {
        guard configuration.superResolutionMode != .off else { return .bypassed("Off") }
        if let reason = VideoEnhancementGuardrails.superResolutionBypassReason(
            frame.pixelBuffer, maxInputResolution: configuration.maxInputResolution
        ) {
            return .bypassed(reason)
        }
        let inputWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
        let inputHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
        switch configuration.superResolutionMode {
        case .off:
            return .bypassed("Off")
        case .videoToolboxML:
            let requested = configuration.superResolutionScale.factor
            guard configuration.limitToScreenResolution, let displaySurface else { return .scaleCap(requested) }
            guard let cap = displaySurface.superResolutionCap(
                inputWidth: inputWidth, inputHeight: inputHeight, requested: requested, mode: .videoToolboxML
            ) else { return .bypassed("Display resolution reached") }
            return .scaleCap(cap)
        case .metalFXSpatial:
            if let targetShortEdge = configuration.superResolutionTargetResolution.shortEdge {
                // Explicit manual target resolution overrides Limit to Screen Resolution.
                switch VideoSuperResolutionTargetResolution.resolveMetalFXOutput(
                    inputWidth: inputWidth, inputHeight: inputHeight, targetShortEdge: targetShortEdge
                ) {
                case let .output(dimensions): return .explicitOutput(dimensions)
                case .alreadyAtOrAboveTarget: return .bypassed("Target resolution reached")
                case .exceedsRasterBudget: return .bypassed("MetalFX output exceeds raster budget")
                }
            }
            if configuration.limitToScreenResolution, let displaySurface {
                guard let cap = displaySurface.superResolutionCap(
                    inputWidth: inputWidth, inputHeight: inputHeight, requested: 4, mode: .metalFXSpatial
                ) else { return .bypassed("Display resolution reached") }
                return .scaleCap(cap)
            }
            return .scaleCap(configuration.superResolutionScale.factor)
        }
    }

    /// Evaluates hard guardrails, super-resolution sizing, and frame-interpolation planning ONCE
    /// for a `(previous, frame)` pair, returning a complete snapshot ready for submission.
    func evaluateAdmission(
        for frame: MediaVideoFrame,
        previous: MediaVideoFrame?,
        playbackRate: Double = 1.0
    ) -> VideoEnhancementAdmissionOutcome {
        guard configuration.isRequested, ExperimentalSettingsPolicy.videoEnhancementEnabled else {
            let empty = VideoEnhancementTelemetry()
            if frameTelemetry != empty {
                frameTelemetry = empty
            }
            return .ineligible(bypassReason: nil, activeOriginalDuration: nil)
        }

        cadenceEstimator.observe(pts: frame.pts)

        if let reason = VideoEnhancementGuardrails.commonBypassReason(
            configuration: configuration, pixelBuffer: frame.pixelBuffer
        ) {
            noteBypass(reason)
            return .ineligible(bypassReason: reason, activeOriginalDuration: nil)
        }

        let srPlan = resolveSuperResolutionPlan(for: frame)

        var fiStreamEligible = false
        var fiStreamBypass: String?
        var activeOriginalDuration: TimeInterval?

        if configuration.frameInterpolationEnabled {
            if let reason = interpolationInputBypassReason(frame) {
                fiStreamBypass = reason
            } else if let estimatedInterval = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration) {
                if let reason = VideoFrameInterpolationPlan.streamEligibilityBypassReason(
                    sourceInterval: estimatedInterval,
                    rate: configuration.interpolationRate,
                    playbackRate: playbackRate
                ) {
                    fiStreamBypass = reason
                } else {
                    fiStreamEligible = true
                    activeOriginalDuration = computeActiveOutputFrameDuration(
                        for: frame, estimatedInterval: estimatedInterval, playbackRate: playbackRate
                    )
                }
            } else {
                fiStreamBypass = "Frame timing invalid"
            }
        } else {
            fiStreamBypass = "Off"
        }

        guard srPlan.resolved != nil || fiStreamEligible else {
            let reason = configuration.frameInterpolationEnabled
                ? (fiStreamBypass ?? srPlan.bypassReason ?? "Off")
                : (srPlan.bypassReason ?? "Off")
            noteBypass(reason)
            return .ineligible(bypassReason: reason, activeOriginalDuration: nil)
        }

        guard let previous else {
            return .ineligible(
                bypassReason: "No accepted reference",
                activeOriginalDuration: activeOriginalDuration
            )
        }

        let pairPlan: VideoFrameInterpolationPlan?
        let pairBypass: String?
        if fiStreamEligible {
            switch resolvePairInterpolationPlan(previous: previous, current: frame, playbackRate: playbackRate) {
            case let .plan(resolved):
                pairPlan = resolved
                pairBypass = nil
            case let .bypass(reason):
                pairPlan = nil
                pairBypass = reason
            }
        } else {
            pairPlan = nil
            pairBypass = fiStreamBypass
        }

        return .eligible(VideoEnhancementAdmission(
            configuration: configuration,
            superResolution: srPlan.resolved,
            superResolutionBypassReason: srPlan.bypassReason,
            interpolationPlan: pairPlan,
            interpolationBypassReason: pairBypass,
            activeOriginalDuration: activeOriginalDuration
        ))
    }

    private func resolvePairInterpolationPlan(
        previous: MediaVideoFrame,
        current: MediaVideoFrame,
        playbackRate: Double
    ) -> VideoInterpolationPlanOutcome {
        if !VideoEnhancementGuardrails.isSDR8Bit(previous.pixelBuffer) {
            return .bypass("HDR / 10-bit")
        }
        if let reason = interpolationInputBypassReason(previous) {
            return .bypass(reason)
        }
        let cadence = cadenceEstimator.medianInterval
        guard let timing = VideoFrameInterpolationTiming(
            previousPTS: previous.pts,
            previousDuration: previous.duration,
            current: current,
            expectedInterval: cadence
        ) else {
            return .bypass("Frame timing gap")
        }
        guard VideoFramePairFormat.matches(previous.pixelBuffer, current.pixelBuffer) else {
            return .bypass("Frame format changed")
        }
        if #unavailable(iOS 26.0), !VisionFrameInterpolationBackend.acceptsPairDelta(timing.delta) {
            return .bypass("Vision FI > 30fps pair")
        }
        return VideoFrameInterpolationPlan.plan(
            previousPTS: previous.pts,
            currentPTS: current.pts,
            interval: timing.delta,
            cadenceInterval: cadence,
            isCadenceStable: cadenceEstimator.isConstantRate,
            gridNextPTS: interpolationGridNextPTS,
            rate: configuration.interpolationRate,
            playbackRate: playbackRate
        )
    }

    private func computeActiveOutputFrameDuration(
        for frame: MediaVideoFrame,
        estimatedInterval: TimeInterval,
        playbackRate: Double
    ) -> TimeInterval? {
        guard frame.duration.isFinite, frame.duration > 0 else { return nil }
        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        let outputDuration: TimeInterval
        if let targetFPS = configuration.interpolationRate.targetFPS {
            let cap = Double(targetFPS)
            let targetPeriod = 1.0 / cap
            let wallCadence = estimatedInterval / speed
            let allowedMultipliers = VideoFrameInterpolationPlan.defaultMultipliers
            let ratio = cap * wallCadence
            if interpolationGridNextPTS == nil, cadenceEstimator.isConstantRate,
               let exactMultiplier = allowedMultipliers.first(where: { multiplier in
                   let target = Double(multiplier)
                   return abs(ratio - target) / target <= VideoFrameInterpolationPlan.exactIntegerTolerance
               }) {
                outputDuration = estimatedInterval / Double(exactMultiplier)
            } else if VideoFrameInterpolationPlan.supportsArbitraryPhases {
                outputDuration = targetPeriod * speed
            } else if let multiplier = VideoFrameInterpolationPlan.bestMultiplier(
                forInterval: wallCadence,
                rate: configuration.interpolationRate,
                allowedMultipliers: VideoFrameInterpolationPlan.dyadicMultipliers
            ) {
                outputDuration = estimatedInterval / Double(multiplier)
            } else {
                return nil
            }
        } else {
            outputDuration = estimatedInterval * 0.5
        }
        guard outputDuration.isFinite, outputDuration > 0, outputDuration < frame.duration else {
            return nil
        }
        return outputDuration
    }

    private func interpolationInputBypassReason(_ frame: MediaVideoFrame) -> String? {
        if let reason = VideoFramePairFormat.interpolationBypassReason(frame.pixelBuffer) { return reason }
        if #available(iOS 26.0, *) { return nil }
        return VisionFrameInterpolationBackend.inputBypassReason(
            frame,
            maxInputResolution: configuration.maxInputResolution,
            cadenceInterval: cadenceEstimator.medianInterval
        )
    }

    // MARK: - Telemetry & Continuity

    func noteBypass(_ reason: String) {
        frameTelemetry = .bypassed(reason: reason)
    }

    /// Seek / stream switch / renderer reset.
    func noteDiscontinuity() {
        pendingExpectation = nil
        telemetryWindow.reset()
        cadenceEstimator.reset()
        interpolationGridNextPTS = nil
    }

    func noteMidpointAccepted(
        _ midpoint: MediaVideoFrame,
        previous: MediaVideoFrame,
        original: MediaVideoFrame,
        acceptedCount: Int = 1,
        plan: VideoFrameInterpolationPlan? = nil
    ) {
        let delta = original.pts - previous.pts
        let sourceFPS = delta > 0 ? 1 / delta : (plan?.sourceFPS ?? 0)
        let outputFPS = plan?.targetOutputFPS ?? (sourceFPS * Double(acceptedCount + 1))
        frameTelemetry = VideoEnhancementTelemetry(
            activeModeLabel: interpolationLabel,
            inputWidth: CVPixelBufferGetWidth(original.pixelBuffer),
            inputHeight: CVPixelBufferGetHeight(original.pixelBuffer),
            outputWidth: CVPixelBufferGetWidth(midpoint.pixelBuffer),
            outputHeight: CVPixelBufferGetHeight(midpoint.pixelBuffer),
            inputFPS: sourceFPS, outputFPS: outputFPS, isActive: true
        )
    }

    private func noteAccepted(
        _ result: VideoFrameEnhancementResult,
        midpointCount: Int,
        enhancedOriginal: Bool,
        emittedOriginal: Bool,
        committedPlan: VideoFrameInterpolationPlan?
    ) {
        var displayed = result.telemetry
        let srActive = enhancedOriginal || (!emittedOriginal && midpointCount > 0 && result.midpointsUpscaled)
        if let plan = committedPlan {
            displayed.outputFPS = midpointCount > 0 ? plan.targetOutputFPS : displayed.inputFPS
        } else {
            displayed.outputFPS = displayed.inputFPS * Double(midpointCount + (emittedOriginal ? 1 : 0))
        }
        let hasMidpoints = midpointCount > 0
        switch (srActive, hasMidpoints) {
        case (true, true):
            displayed.activeModeLabel = "\(configuration.superResolutionMode.telemetryLabel) + \(interpolationLabel)"
        case (true, false):
            displayed.activeModeLabel = configuration.superResolutionMode.telemetryLabel
        case (false, true):
            displayed.activeModeLabel = interpolationLabel
        case (false, false):
            displayed.activeModeLabel = "Bypass"
        }
        if !enhancedOriginal {
            if midpointCount > 0, let buffer = result.midpoints.first?.frame.pixelBuffer {
                displayed.outputWidth = CVPixelBufferGetWidth(buffer)
                displayed.outputHeight = CVPixelBufferGetHeight(buffer)
            } else {
                displayed.outputWidth = displayed.inputWidth
                displayed.outputHeight = displayed.inputHeight
            }
        }
        displayed.isActive = midpointCount > 0 || enhancedOriginal
        displayed.bypassReason = displayed.isActive ? nil : (
            displayed.bypassReason ?? result.interpolationBypassReason ?? "Enhancement not admitted"
        )
        frameTelemetry = displayed
    }

    /// Called once for every source frame the renderer settles while enhancement is requested
    /// (including CFR steps where synthesized midpoints replace the original frame on screen).
    func noteOriginalPresented(
        _ original: MediaVideoFrame,
        result: VideoFrameEnhancementResult?,
        midpointCount: Int,
        upscaled: MediaVideoFrame?,
        emittedOriginal: Bool = true,
        committedPlan: VideoFrameInterpolationPlan? = nil,
        playbackRate: Double = 1.0
    ) {
        cadenceEstimator.observe(pts: original.pts)
        if let result {
            noteAccepted(
                result,
                midpointCount: midpointCount,
                enhancedOriginal: upscaled != nil,
                emittedOriginal: emittedOriginal,
                committedPlan: committedPlan
            )
            if result.telemetry.smoothedProcessingMs > 0.01 {
                lastProcessingMs = result.telemetry.smoothedProcessingMs
            }
        }
        guard configuration.isRequested, !configuration.isLiveStream else { return }

        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        if let plan = committedPlan, let nextGrid = plan.nextGridPTS {
            if emittedOriginal == plan.emitsOriginal, midpointCount > 0 || plan.phases.isEmpty {
                interpolationGridNextPTS = nextGrid
            } else if emittedOriginal {
                interpolationGridNextPTS = original.pts + plan.outputFrameDuration
            }
        } else if let plan = committedPlan, plan.nextGridPTS == nil {
            interpolationGridNextPTS = nil
        } else if emittedOriginal, interpolationGridNextPTS != nil,
                  let targetFPS = configuration.interpolationRate.targetFPS {
            interpolationGridNextPTS = original.pts + (1.0 / Double(targetFPS)) * speed
        }

        let validZeroMidpointCFRStep = committedPlan?.isCFRResampling == true
            && committedPlan?.phases.isEmpty == true
            && emittedOriginal == committedPlan?.emitsOriginal
        let midpointsWereUpscaled = !emittedOriginal && midpointCount > 0 && (result?.midpointsUpscaled == true)
        let stepUpscaled = (upscaled != nil) || midpointsWereUpscaled

        var expectedMidpoints = committedPlan?.phases.count ?? 0
        var missReason: String?
        if let expectation = pendingExpectation, expectation.frame == EnhancementFrameIdentity(original) {
            expectedMidpoints = max(expectedMidpoints, expectation.expectedMidpointCount)
            let interpolationMissed = expectation.expectedMidpointCount > 0
                && midpointCount < expectation.expectedMidpointCount
                && !validZeroMidpointCFRStep
            let upscaleMissed = expectation.upscale && !stepUpscaled
            if interpolationMissed {
                missReason = result?.interpolationBypassReason ?? "Interpolation deadline"
            } else if upscaleMissed {
                missReason = result?.originalSuperResolutionBypassReason ?? "Super resolution deadline"
            }
            pendingExpectation = nil
        } else if !stepUpscaled, midpointCount == 0, !validZeroMidpointCFRStep {
            missReason = frameTelemetry.bypassReason
        }
        let input = original.pixelBuffer
        let output = upscaled?.pixelBuffer
            ?? (midpointsWereUpscaled ? result?.midpoints.first?.frame.pixelBuffer : nil)
            ?? input
        telemetryWindow.record(.init(
            at: .now,
            upscaled: stepUpscaled,
            midpoints: midpointCount,
            expectedMidpoints: expectedMidpoints,
            missReason: missReason,
            inputWidth: CVPixelBufferGetWidth(input),
            inputHeight: CVPixelBufferGetHeight(input),
            outputWidth: CVPixelBufferGetWidth(output),
            outputHeight: CVPixelBufferGetHeight(output),
            emittedOriginal: emittedOriginal,
            interpolationStepActive: midpointCount > 0 || validZeroMidpointCFRStep
        ))
    }

    // MARK: - Persistent Worker Submission & Lifecycle

    func submit(
        _ frame: MediaVideoFrame,
        previous: MediaVideoFrame,
        admission: VideoEnhancementAdmission,
        deadlines: VideoEnhancementDeadlines,
        onUpdate: @escaping @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        precondition(inFlightJobID == nil)
        nextJobID &+= 1
        let jobID = nextJobID
        inFlightJobID = jobID

        let resolvedPlan = deadlines.midpoint.flatMap { _ in
            admission.interpolationPlan
        }.flatMap { $0.phases.isEmpty ? nil : $0 }

        let job = VideoFrameEnhancementJob(
            current: PostProcessFrameBox(frame: frame),
            previous: PostProcessFrameBox(frame: previous),
            configuration: admission.configuration,
            interpolationLabel: interpolationLabel,
            interpolationPlan: resolvedPlan,
            deadlines: deadlines,
            upscalingBypassReason: admission.superResolutionBypassReason,
            superResolutionCap: admission.superResolution?.scaleCap ?? 0,
            superResolutionTargetDimensions: admission.superResolution?.targetDimensions
        )
        pendingExpectation = (
            EnhancementFrameIdentity(frame),
            job.interpolationPlan?.phases.count ?? 0,
            job.isUpscaling
        )

        let channel = workerChannel
        let (generation, continuation, newStream): (
            UInt64,
            AsyncStream<WorkerCommand>.Continuation,
            AsyncStream<WorkerCommand>?
        ) = channel.withLock { state in
            if let existing = state.continuation {
                return (state.generation, existing, nil)
            }
            let (stream, cont) = AsyncStream<WorkerCommand>.makeStream()
            state.continuation = cont
            return (state.generation, cont, stream)
        }
        if let newStream {
            VideoFramePostProcessorActor.launchLoop(stream: newStream)
        }

        let isAlive: @Sendable () -> Bool = {
            channel.withLock { $0.generation == generation }
        }
        let publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void = { [weak self] midpoints in
            await self?.deliverMidpoints(midpoints, jobID: jobID, generation: generation, onUpdate: onUpdate)
        }
        let complete: @Sendable (VideoFrameEnhancementResult) async -> Void = { [weak self] result in
            await self?.finish(result, jobID: jobID, generation: generation, onUpdate: onUpdate)
        }

        continuation.yield(.process(
            job: job,
            isAlive: isAlive,
            publishMidpoints: publishMidpoints,
            complete: complete
        ))
    }

    func flush() {
        pendingExpectation = nil
        interpolationGridNextPTS = nil
        let continuation: AsyncStream<WorkerCommand>.Continuation? = workerChannel.withLock { state in
            state.generation &+= 1
            return state.continuation
        }
        continuation?.yield(.flush)
    }

    func tearDown() {
        pendingExpectation = nil
        telemetryWindow.reset()
        cadenceEstimator.reset()
        interpolationGridNextPTS = nil
        lastProcessingMs = 0
        frameTelemetry = VideoEnhancementTelemetry()
        let continuation: AsyncStream<WorkerCommand>.Continuation? = workerChannel.withLock { state in
            state.generation &+= 1
            return state.continuation
        }
        continuation?.yield(.tearDown)
    }

    private func deliverMidpoints(
        _ midpoints: [PostProcessFrameBox],
        jobID: UInt64,
        generation: UInt64,
        onUpdate: @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        guard inFlightJobID == jobID,
              workerChannel.withLock({ $0.generation == generation }) else { return }
        onUpdate(.midpointReady(midpoints))
    }

    private func finish(
        _ result: VideoFrameEnhancementResult,
        jobID: UInt64,
        generation: UInt64,
        onUpdate: @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        if inFlightJobID == jobID {
            inFlightJobID = nil
        }
        guard workerChannel.withLock({ $0.generation == generation }) else { return }
        onUpdate(.finished(result))
    }
}

// MARK: - Single-Consumer Background Pipeline

private final class VideoFramePostProcessorPipeline {
    private let vtSuperRes = VideoToolboxSuperResolutionBackend()
    private let metalFXSuperRes = MetalFXSuperResolutionBackend()
    private let vtFrameInterp = VideoToolboxFrameInterpolationBackend()
    private let visionFrameInterp = VisionFrameInterpolationBackend()
    private var interpolationReference: EnhancementFrameIdentity?
    private var smoothedMs: Double = 0
    private var lastSuperResolutionMode = VideoSuperResolutionMode.off
    private var lastInterpolationEnabled = false

    private struct InterpolationStage {
        var midpoints: [MediaVideoFrame] = []
        var inputFPS: Double
        var bypassReason: String?
        var srBypassReason: String?
        var midpointsUpscaled = false
    }

    private func releaseIdleBackends(for configuration: VideoEnhancementConfiguration) {
        let mode = configuration.superResolutionMode
        if mode != lastSuperResolutionMode {
            if lastSuperResolutionMode == .videoToolboxML {
                vtSuperRes.tearDown()
            }
            if lastSuperResolutionMode == .metalFXSpatial {
                metalFXSuperRes.tearDown()
            }
            lastSuperResolutionMode = mode
        }
        if lastInterpolationEnabled, !configuration.frameInterpolationEnabled {
            vtFrameInterp.tearDown()
            visionFrameInterp.tearDown()
            interpolationReference = nil
        }
        lastInterpolationEnabled = configuration.frameInterpolationEnabled
    }

    func flush() {
        vtSuperRes.flush()
        metalFXSuperRes.flush()
        resetInterpolation()
        smoothedMs = 0
    }

    func tearDown() {
        vtSuperRes.tearDown()
        metalFXSuperRes.tearDown()
        vtFrameInterp.tearDown()
        visionFrameInterp.tearDown()
        interpolationReference = nil
        smoothedMs = 0
        lastSuperResolutionMode = .off
        lastInterpolationEnabled = false
    }

    func process(
        _ job: VideoFrameEnhancementJob,
        isAlive: @escaping @Sendable () -> Bool,
        publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void
    ) async -> VideoFrameEnhancementResult {
        let start = ContinuousClock.now
        releaseIdleBackends(for: job.configuration)
        let frame = job.current.frame
        let previous = job.previous.frame
        let nominalFPS = VideoFrameInterpolationTiming.sourceFPS(frame) ?? 0

        guard isAlive() else {
            return makeResult(job, interpolation: InterpolationStage(inputFPS: nominalFPS), original: nil)
        }

        let previousIdentity = EnhancementFrameIdentity(previous)
        let formatMatches = VideoFramePairFormat.matches(previous.pixelBuffer, frame.pixelBuffer)
        if !formatMatches {
            if job.configuration.superResolutionMode == .videoToolboxML {
                vtSuperRes.flush()
            }
            if interpolationReference != nil {
                resetInterpolation()
            }
        }

        // Stage 1: Frame interpolation (raw synthesized midpoints in strictly ascending PTS order).
        var interpolation = await interpolateRaw(job, previousIdentity: previousIdentity, isAlive: isAlive)
        let shouldUpscaleOriginal = job.isUpscaling
            && ((job.interpolationPlan?.emitsOriginal ?? true) || interpolation.midpoints.isEmpty)

        // Stage 2: Super resolution.
        // - MetalFX Spatial batches midpoints + original into a single GPU command buffer submission.
        // - VideoToolbox ML processes midpoints then original in strictly ascending PTS order so
        //   VTSRSession temporal `lastSubmittedPTS` stays strictly monotonic with zero session teardown.
        var originalOutcome: VideoEnhancementBackendOutcome?
        if job.isUpscaling {
            switch job.configuration.superResolutionMode {
            case .off:
                break
            case .metalFXSpatial:
                originalOutcome = await runMetalFXStage(
                    job,
                    interpolation: &interpolation,
                    shouldUpscaleOriginal: shouldUpscaleOriginal,
                    isAlive: isAlive
                )
            case .videoToolboxML:
                originalOutcome = await runVideoToolboxSRStage(
                    job,
                    interpolation: &interpolation,
                    shouldUpscaleOriginal: shouldUpscaleOriginal,
                    isAlive: isAlive,
                    publishMidpoints: publishMidpoints
                )
            }
        } else if job.configuration.superResolutionMode != .off,
                  let reason = job.upscalingBypassReason {
            originalOutcome = .bypassed(reason: reason)
        }

        let elapsedMs = Double(start.duration(to: .now) / .microseconds(1)) / 1_000
        smoothedMs = smoothedMs > 0 ? smoothedMs * 0.8 + elapsedMs * 0.2 : elapsedMs
        return makeResult(job, interpolation: interpolation, original: originalOutcome)
    }

    private func interpolateRaw(
        _ job: VideoFrameEnhancementJob,
        previousIdentity: EnhancementFrameIdentity,
        isAlive: @escaping @Sendable () -> Bool
    ) async -> InterpolationStage {
        let frame = job.current.frame
        let nominalFPS = VideoFrameInterpolationTiming.sourceFPS(frame) ?? 0
        var stage = InterpolationStage(inputFPS: nominalFPS)
        guard let deadline = job.deadlines.midpoint, let plan = job.interpolationPlan else {
            if interpolationReference != nil { resetInterpolation() }
            return stage
        }
        let hasTimeRemaining: @Sendable () -> Bool = { isAlive() && .now < deadline }
        if interpolationReference != previousIdentity, hasTimeRemaining() {
            resetInterpolation()
            switch await interpolate(
                job.previous.frame,
                plan: nil,
                maxInputResolution: job.configuration.maxInputResolution,
                hasTimeRemaining: hasTimeRemaining
            ) {
            case .passthrough, .interpolated:
                interpolationReference = previousIdentity
            case let .bypassed(reason):
                stage.bypassReason = reason
                resetInterpolation()
                return stage
            }
        }
        guard hasTimeRemaining() else {
            stage.bypassReason = "Interpolation deadline"
            return stage
        }
        switch await interpolate(
            frame,
            plan: plan,
            maxInputResolution: job.configuration.maxInputResolution,
            hasTimeRemaining: hasTimeRemaining
        ) {
        case let .interpolated(frames):
            stage.inputFPS = plan.sourceFPS
            stage.midpoints = frames
            interpolationReference = EnhancementFrameIdentity(frame)
        case .passthrough:
            interpolationReference = EnhancementFrameIdentity(frame)
        case let .bypassed(reason):
            stage.bypassReason = reason
            if Self.preservesInterpolationReference(forBypassReason: reason) {
                interpolationReference = EnhancementFrameIdentity(frame)
            } else {
                resetInterpolation()
            }
        }
        return stage
    }

    private static func preservesInterpolationReference(forBypassReason reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("deadline") || lower.contains("pool") || lower.contains("busy")
            || lower.contains("exhausted")
    }

    private func runMetalFXStage(
        _ job: VideoFrameEnhancementJob,
        interpolation: inout InterpolationStage,
        shouldUpscaleOriginal: Bool,
        isAlive: @escaping @Sendable () -> Bool
    ) async -> VideoEnhancementBackendOutcome? {
        let frame = job.current.frame
        let midpointDeadline = job.deadlines.midpoint
        let hasMidpointTime = midpointDeadline.map { isAlive() && .now < $0 } ?? false

        if !interpolation.midpoints.isEmpty, hasMidpointTime {
            if shouldUpscaleOriginal {
                var buffers = interpolation.midpoints.map(\.pixelBuffer)
                buffers.append(frame.pixelBuffer)
                let outcomes = await metalFXSuperRes.upscaleBatch(
                    pixelBuffers: buffers,
                    maxScale: job.superResolutionCap,
                    targetDimensions: job.superResolutionTargetDimensions,
                    sharpness: job.configuration.superResolutionSharpness
                )
                guard outcomes.count == buffers.count else {
                    return .bypassed(reason: "MetalFX batch mismatch")
                }
                let midpointCount = interpolation.midpoints.count
                var upscaledMidpoints = interpolation.midpoints
                var allMidpointsUpscaled = true
                for index in 0..<midpointCount {
                    if case let .processed(buffer) = outcomes[index] {
                        upscaledMidpoints[index].pixelBuffer = buffer
                    } else {
                        allMidpointsUpscaled = false
                        if case let .bypassed(reason) = outcomes[index], interpolation.srBypassReason == nil {
                            interpolation.srBypassReason = reason
                        }
                        break
                    }
                }
                if allMidpointsUpscaled {
                    interpolation.midpoints = upscaledMidpoints
                    interpolation.midpointsUpscaled = true
                }
                return outcomes[midpointCount]
            } else {
                let buffers = interpolation.midpoints.map(\.pixelBuffer)
                let outcomes = await metalFXSuperRes.upscaleBatch(
                    pixelBuffers: buffers,
                    maxScale: job.superResolutionCap,
                    targetDimensions: job.superResolutionTargetDimensions,
                    sharpness: job.configuration.superResolutionSharpness
                )
                guard outcomes.count == buffers.count else {
                    interpolation.srBypassReason = "MetalFX batch mismatch"
                    return nil
                }
                var upscaledMidpoints = interpolation.midpoints
                var allMidpointsUpscaled = true
                for index in 0..<buffers.count {
                    if case let .processed(buffer) = outcomes[index] {
                        upscaledMidpoints[index].pixelBuffer = buffer
                    } else {
                        allMidpointsUpscaled = false
                        if case let .bypassed(reason) = outcomes[index], interpolation.srBypassReason == nil {
                            interpolation.srBypassReason = reason
                        }
                        break
                    }
                }
                if allMidpointsUpscaled {
                    interpolation.midpoints = upscaledMidpoints
                    interpolation.midpointsUpscaled = true
                }
                return nil
            }
        }

        if !interpolation.midpoints.isEmpty {
            interpolation.srBypassReason = "Super resolution deadline"
        }
        guard shouldUpscaleOriginal else { return nil }
        guard isAlive(), .now < job.deadlines.original else {
            return .bypassed(reason: "Super resolution deadline")
        }
        return await metalFXSuperRes.upscale(
            pixelBuffer: frame.pixelBuffer,
            maxScale: job.superResolutionCap,
            targetDimensions: job.superResolutionTargetDimensions,
            sharpness: job.configuration.superResolutionSharpness
        )
    }

    private func runVideoToolboxSRStage(
        _ job: VideoFrameEnhancementJob,
        interpolation: inout InterpolationStage,
        shouldUpscaleOriginal: Bool,
        isAlive: @escaping @Sendable () -> Bool,
        publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void
    ) async -> VideoEnhancementBackendOutcome? {
        let frame = job.current.frame
        if !interpolation.midpoints.isEmpty, let midpointDeadline = job.deadlines.midpoint {
            let hasMidpointTime: @Sendable () -> Bool = { isAlive() && .now < midpointDeadline }
            var upscaledMidpoints = interpolation.midpoints
            var allMidpointsUpscaled = true
            for index in interpolation.midpoints.indices {
                guard hasMidpointTime() else {
                    allMidpointsUpscaled = false
                    interpolation.srBypassReason = "Super resolution deadline"
                    break
                }
                let midpoint = interpolation.midpoints[index]
                let pts = CMTime(seconds: max(0, midpoint.pts), preferredTimescale: 1_000_000_000)
                let outcome = await vtSuperRes.upscale(
                    pixelBuffer: midpoint.pixelBuffer,
                    pts: pts,
                    maxScale: job.superResolutionCap,
                    hasTimeRemaining: hasMidpointTime
                )
                if case let .processed(buffer) = outcome {
                    upscaledMidpoints[index].pixelBuffer = buffer
                } else {
                    allMidpointsUpscaled = false
                    if case let .bypassed(reason) = outcome {
                        interpolation.srBypassReason = reason
                    }
                    break
                }
            }
            if allMidpointsUpscaled {
                interpolation.midpoints = upscaledMidpoints
                interpolation.midpointsUpscaled = true
            }
            if shouldUpscaleOriginal, !interpolation.midpoints.isEmpty, hasMidpointTime() {
                await publishMidpoints(interpolation.midpoints.map(PostProcessFrameBox.init))
            }
        }

        guard shouldUpscaleOriginal else { return nil }
        let originalDeadline = job.deadlines.original
        let hasOriginalTime: @Sendable () -> Bool = { isAlive() && .now < originalDeadline }
        guard hasOriginalTime() else {
            return .bypassed(reason: "Super resolution deadline")
        }
        let pts = CMTime(seconds: max(0, frame.pts), preferredTimescale: 1_000_000_000)
        return await vtSuperRes.upscale(
            pixelBuffer: frame.pixelBuffer,
            pts: pts,
            maxScale: job.superResolutionCap,
            hasTimeRemaining: hasOriginalTime
        )
    }

    private func makeResult(
        _ job: VideoFrameEnhancementJob,
        interpolation: InterpolationStage,
        original: VideoEnhancementBackendOutcome?
    ) -> VideoFrameEnhancementResult {
        let frame = job.current.frame
        var enhancedOriginal: MediaVideoFrame?
        var srBypass: String?
        if case let .processed(buffer) = original {
            var enhanced = frame
            enhanced.pixelBuffer = buffer
            enhancedOriginal = enhanced
        } else if case let .bypassed(reason) = original {
            srBypass = reason
        } else if job.isUpscaling, !interpolation.midpointsUpscaled {
            srBypass = interpolation.srBypassReason
        }

        let srActive = enhancedOriginal != nil || interpolation.midpointsUpscaled
        let hasMidpoints = !interpolation.midpoints.isEmpty
        let isActive = srActive || hasMidpoints
        let activeModeLabel: String
        switch (srActive, hasMidpoints) {
        case (true, true):
            activeModeLabel = "\(job.configuration.superResolutionMode.telemetryLabel) + \(job.interpolationLabel)"
        case (true, false):
            activeModeLabel = job.configuration.superResolutionMode.telemetryLabel
        case (false, true):
            activeModeLabel = job.interpolationLabel
        case (false, false):
            activeModeLabel = "Bypass"
        }
        let output = enhancedOriginal?.pixelBuffer
            ?? (interpolation.midpointsUpscaled ? interpolation.midpoints.first?.pixelBuffer : nil)
            ?? frame.pixelBuffer
        let outputFPS = job.interpolationPlan?.targetOutputFPS
            ?? (interpolation.inputFPS * Double(interpolation.midpoints.count + 1))
        let telemetry = VideoEnhancementTelemetry(
            activeModeLabel: activeModeLabel,
            inputWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
            inputHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
            outputWidth: CVPixelBufferGetWidth(output),
            outputHeight: CVPixelBufferGetHeight(output),
            inputFPS: interpolation.inputFPS,
            outputFPS: outputFPS,
            smoothedProcessingMs: smoothedMs,
            bypassReason: isActive ? nil : (srBypass ?? interpolation.bypassReason),
            isActive: isActive
        )
        return VideoFrameEnhancementResult(
            midpoints: interpolation.midpoints.map(PostProcessFrameBox.init),
            enhancedOriginal: enhancedOriginal.map(PostProcessFrameBox.init),
            telemetry: telemetry,
            interpolationBypassReason: interpolation.bypassReason,
            originalSuperResolutionBypassReason: srBypass,
            midpointsUpscaled: interpolation.midpointsUpscaled
        )
    }

    private func resetInterpolation() {
        vtFrameInterp.flush()
        visionFrameInterp.flush()
        interpolationReference = nil
    }

    private func interpolate(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        maxInputResolution: VideoEnhancementMaxInputResolution,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        if #available(iOS 26.0, *) {
            return await vtFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
        }
        return await visionFrameInterp.process(
            frame, plan: plan, maxInputResolution: maxInputResolution, hasTimeRemaining: hasTimeRemaining
        )
    }
}
