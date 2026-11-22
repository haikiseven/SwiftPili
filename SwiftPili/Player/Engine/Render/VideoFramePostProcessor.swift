import CoreMedia
import CoreVideo
import Foundation

private struct VideoFrameEnhancementJob: Sendable {
    let current: PostProcessFrameBox
    let previous: PostProcessFrameBox
    let configuration: VideoEnhancementConfiguration
    let interpolationLabel: String
    let interpolationPlan: VideoFrameInterpolationPlan?
    let deadlines: VideoEnhancementDeadlines
    let upscalingBypassReason: String?

    var isUpscaling: Bool { configuration.superResolutionMode != .off && upscalingBypassReason == nil }
}

@MainActor
final class VideoFramePostProcessor {
    private let worker = VideoFramePostProcessorWorker()
    private var activeTask: Task<Void, Never>?
    private var needsFlush = false
    private var needsTearDown = false
    private var governor = VideoEnhancementGovernor()
    /// Outcome of the in-flight / most recent submission: `nil` = none, `true` = missed its deadline.
    private var pendingOutcomeMissed: Bool?
    private var systemState = VideoEnhancementSystemState.current
    private var systemStateSampledAt = ContinuousClock.now

    /// User-requested configuration. The governor may degrade it at runtime; see `effectiveConfiguration`.
    var configuration = VideoEnhancementConfiguration.disabled {
        didSet {
            guard configuration != oldValue else { return }
            pendingOutcomeMissed = nil
            governor.reset(requested: configuration)
            telemetry = configuration.isRequested && configuration.isLiveStream
                ? .bypassed(reason: "VOD only") : VideoEnhancementTelemetry()
        }
    }
    private(set) var telemetry = VideoEnhancementTelemetry() {
        didSet {
            let note = governor.level > .none ? governor.reason : nil
            if telemetry.degradationNote != note { telemetry.degradationNote = note }
        }
    }

    /// Configuration actually executed, after performance / thermal / Low Power degradation.
    var effectiveConfiguration: VideoEnhancementConfiguration { governor.effectiveConfiguration }
    var degradationLevel: VideoEnhancementDegradationLevel { governor.level }

    var isBusy: Bool { activeTask != nil }

    var interpolationLabel: String {
        if #available(iOS 26.0, *) { return "VT FI" }
        return "Vision FI"
    }

    func canProcess(_ frame: MediaVideoFrame) -> Bool {
        guard configuration.isRequested, ExperimentalSettingsPolicy.videoEnhancementEnabled else {
            telemetry = VideoEnhancementTelemetry()
            return false
        }
        if let reason = VideoEnhancementGuardrails.commonBypassReason(
            configuration: configuration, pixelBuffer: frame.pixelBuffer
        ) {
            noteBypass(reason)
            return false
        }
        let now = ContinuousClock.now
        if systemStateSampledAt.duration(to: now) >= .seconds(1) {
            systemState = .current
            systemStateSampledAt = now
        }
        governor.evaluate(system: systemState, now: now)
        let effective = effectiveConfiguration
        guard effective.isRequested else {
            noteBypass(governor.reason ?? "Performance limited")
            return false
        }
        if canUpscale(frame) { return true }
        if effective.frameInterpolationEnabled {
            guard let reason = interpolationInputBypassReason(frame) else { return true }
            noteBypass(reason)
        } else if let reason = VideoEnhancementGuardrails.superResolutionBypassReason(frame.pixelBuffer) {
            noteBypass(reason)
        }
        return false
    }

    func canUpscale(_ frame: MediaVideoFrame) -> Bool {
        effectiveConfiguration.superResolutionMode != .off
            && VideoEnhancementGuardrails.superResolutionBypassReason(frame.pixelBuffer) == nil
    }

    func interpolationPlan(previous: MediaVideoFrame, current: MediaVideoFrame) -> VideoFrameInterpolationPlan? {
        let effective = effectiveConfiguration
        guard effective.frameInterpolationEnabled,
              VideoEnhancementGuardrails.commonBypassReason(
                  configuration: configuration, pixelBuffer: previous.pixelBuffer
              ) == nil,
              interpolationInputBypassReason(previous) == nil,
              interpolationInputBypassReason(current) == nil,
              let timing = VideoFrameInterpolationTiming(
                  previousPTS: previous.pts, previousDuration: previous.duration, current: current
              ), VideoFramePairFormat.matches(previous.pixelBuffer, current.pixelBuffer) else { return nil }
        if #unavailable(iOS 26.0), !VisionFrameInterpolationBackend.acceptsPairDelta(timing.delta) {
            return nil
        }
        return VideoFrameInterpolationPlan(
            previousPTS: previous.pts, currentPTS: current.pts, interval: timing.delta,
            rate: effective.interpolationRate
        )
    }

    private func interpolationInputBypassReason(_ frame: MediaVideoFrame) -> String? {
        if let reason = VideoFramePairFormat.interpolationBypassReason(frame.pixelBuffer) { return reason }
        if #available(iOS 26.0, *) { return nil }
        return VisionFrameInterpolationBackend.inputBypassReason(frame)
    }

    func noteBypass(_ reason: String) {
        telemetry = .bypassed(reason: reason)
    }

    /// An enhancement-eligible frame could not be enhanced in time (late arrival, worker busy,
    /// deadline expiry, late SR output). Feeds the adaptive governor; does not touch telemetry.
    func notePerformanceMiss() {
        if pendingOutcomeMissed != nil {
            pendingOutcomeMissed = true
        } else {
            governor.record(missed: true)
        }
    }

    /// Seek / stream switch / renderer reset: keep the learned level but ignore transient lateness.
    func noteDiscontinuity() {
        pendingOutcomeMissed = nil
        governor.noteDiscontinuity()
    }

    private func finalizePendingOutcome() {
        guard let missed = pendingOutcomeMissed else { return }
        pendingOutcomeMissed = nil
        governor.record(missed: missed)
    }

    func noteMidpointAccepted(
        _ midpoint: MediaVideoFrame, previous: MediaVideoFrame, original: MediaVideoFrame, acceptedCount: Int = 1
    ) {
        let sourceFPS = 1 / (original.pts - previous.pts)
        telemetry = VideoEnhancementTelemetry(
            activeModeLabel: interpolationLabel,
            inputWidth: CVPixelBufferGetWidth(original.pixelBuffer),
            inputHeight: CVPixelBufferGetHeight(original.pixelBuffer),
            outputWidth: CVPixelBufferGetWidth(midpoint.pixelBuffer),
            outputHeight: CVPixelBufferGetHeight(midpoint.pixelBuffer),
            inputFPS: sourceFPS, outputFPS: sourceFPS * Double(acceptedCount + 1), isActive: true
        )
    }

    func noteAccepted(_ result: VideoFrameEnhancementResult, midpointCount: Int, enhancedOriginal: Bool) {
        var displayed = result.telemetry
        displayed.outputFPS = displayed.inputFPS * Double(midpointCount + 1)
        if midpointCount == 0 {
            if !result.midpoints.isEmpty {
                displayed.activeModeLabel = enhancedOriginal
                    ? effectiveConfiguration.superResolutionMode.telemetryLabel : "Bypass"
            }
        }
        if !enhancedOriginal {
            displayed.outputWidth = displayed.inputWidth
            displayed.outputHeight = displayed.inputHeight
            if midpointCount > 0, let buffer = result.midpoints.first?.frame.pixelBuffer {
                displayed.activeModeLabel = interpolationLabel
                displayed.outputWidth = CVPixelBufferGetWidth(buffer)
                displayed.outputHeight = CVPixelBufferGetHeight(buffer)
            }
        }
        displayed.isActive = midpointCount > 0 || enhancedOriginal
        displayed.bypassReason = displayed.isActive ? nil : (
            displayed.bypassReason ?? result.interpolationBypassReason ?? "Enhancement not admitted"
        )
        telemetry = displayed
    }

    func submit(
        _ frame: MediaVideoFrame,
        previous: MediaVideoFrame,
        deadlines: VideoEnhancementDeadlines,
        onUpdate: @escaping @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        precondition(activeTask == nil)
        finalizePendingOutcome()
        pendingOutcomeMissed = false
        let job = VideoFrameEnhancementJob(
            current: PostProcessFrameBox(frame: frame), previous: PostProcessFrameBox(frame: previous),
            configuration: effectiveConfiguration, interpolationLabel: interpolationLabel,
            interpolationPlan: deadlines.midpoint.flatMap { _ in
                interpolationPlan(previous: previous, current: frame)
            },
            deadlines: deadlines,
            upscalingBypassReason: VideoEnhancementGuardrails.superResolutionBypassReason(frame.pixelBuffer)
        )
        let worker = self.worker
        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await worker.process(job) { midpoints in
                await onUpdate(.midpointReady(midpoints))
            }
            await self?.finish(result, onUpdate: onUpdate)
        }
    }

    func flush() {
        finalizePendingOutcome()
        if activeTask != nil {
            needsFlush = true
            activeTask?.cancel()
        } else {
            worker.flush()
        }
    }

    func tearDown() {
        pendingOutcomeMissed = nil
        governor.reset(requested: configuration)
        telemetry = VideoEnhancementTelemetry()
        if let activeTask {
            needsTearDown = true
            activeTask.cancel()
        } else {
            startTearDown()
        }
    }

    private func finish(
        _ result: VideoFrameEnhancementResult,
        onUpdate: @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        activeTask = nil
        recordWorkerOutcome(result)
        if needsTearDown {
            needsTearDown = false
            needsFlush = false
            startTearDown()
        } else if needsFlush {
            needsFlush = false
            worker.flush()
        }
        onUpdate(.finished(result))
    }

    private func recordWorkerOutcome(_ result: VideoFrameEnhancementResult) {
        let workerMissed = [result.interpolationBypassReason, result.originalSuperResolutionBypassReason]
            .contains { $0?.localizedCaseInsensitiveContains("deadline") == true }
        if workerMissed, pendingOutcomeMissed != nil { pendingOutcomeMissed = true }
        let fps = result.telemetry.inputFPS
        if fps.isFinite, fps > 0 {
            governor.recordLoad(processingMs: result.telemetry.smoothedProcessingMs, frameInterval: 1 / fps)
        }
    }

    private func startTearDown() {
        let worker = self.worker
        activeTask = Task.detached(priority: .utility) { [weak self] in
            worker.tearDown()
            await self?.finishTearDown()
        }
    }

    private func finishTearDown() {
        needsTearDown = false
        needsFlush = false
        activeTask = nil
    }
}

private final class VideoFramePostProcessorWorker: @unchecked Sendable {
    private let vtSuperRes = VideoToolboxSuperResolutionBackend()
    private let metalFXSuperRes = MetalFXSuperResolutionBackend()
    private let vtFrameInterp = VideoToolboxFrameInterpolationBackend()
    private let visionFrameInterp = VisionFrameInterpolationBackend()
    private var previousInput: EnhancementFrameIdentity?
    private var interpolationReference: EnhancementFrameIdentity?
    private var smoothedMs: Double = 0
    private var lastSuperResolutionMode = VideoSuperResolutionMode.off
    private var lastInterpolationEnabled = false

    /// The governor can switch backends at runtime; release sessions that are no longer used so a
    /// device already short on resources does not keep idle VT / Metal state resident.
    private func releaseIdleBackends(for configuration: VideoEnhancementConfiguration) {
        let mode = configuration.superResolutionMode
        if mode != lastSuperResolutionMode {
            if lastSuperResolutionMode == .videoToolboxML { vtSuperRes.tearDown() }
            if lastSuperResolutionMode == .metalFXSpatial { metalFXSuperRes.tearDown() }
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
        previousInput = nil
        smoothedMs = 0
    }

    func tearDown() {
        vtSuperRes.tearDown()
        metalFXSuperRes.tearDown()
        vtFrameInterp.tearDown()
        visionFrameInterp.tearDown()
        previousInput = nil
        interpolationReference = nil
        smoothedMs = 0
        lastSuperResolutionMode = .off
        lastInterpolationEnabled = false
    }

    private struct InterpolationStage {
        var midpoints: [MediaVideoFrame] = []
        var inputFPS: Double
        var bypassReason: String?
    }

    func process(
        _ job: VideoFrameEnhancementJob,
        publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void
    ) async -> VideoFrameEnhancementResult {
        let start = ContinuousClock.now
        releaseIdleBackends(for: job.configuration)
        let frame = job.current.frame
        let previous = job.previous.frame
        let previousIdentity = EnhancementFrameIdentity(previous)
        if previousInput != previousIdentity || !VideoFramePairFormat.matches(previous.pixelBuffer, frame.pixelBuffer) {
            vtSuperRes.flush()
            resetInterpolation()
        }
        let interpolation = await processInterpolation(job, previousIdentity: previousIdentity)
        if job.isUpscaling, !interpolation.midpoints.isEmpty, !Task.isCancelled {
            await publishMidpoints(interpolation.midpoints.map(PostProcessFrameBox.init))
        }
        let original = await processOriginal(job)
        previousInput = EnhancementFrameIdentity(frame)
        let elapsedMs = Double(start.duration(to: .now) / .microseconds(1)) / 1_000
        smoothedMs = smoothedMs > 0 ? smoothedMs * 0.8 + elapsedMs * 0.2 : elapsedMs
        return makeResult(job, interpolation: interpolation, original: original)
    }

    private func processInterpolation(
        _ job: VideoFrameEnhancementJob, previousIdentity: EnhancementFrameIdentity
    ) async -> InterpolationStage {
        let frame = job.current.frame
        let nominalFPS = VideoFrameInterpolationTiming.sourceFPS(frame) ?? 0
        var stage = InterpolationStage(inputFPS: nominalFPS)
        guard let deadline = job.deadlines.midpoint, let plan = job.interpolationPlan else {
            if interpolationReference != nil { resetInterpolation() }
            return stage
        }
        let hasTimeRemaining: @Sendable () -> Bool = { !Task.isCancelled && .now < deadline }
        if interpolationReference != previousIdentity, hasTimeRemaining() {
            resetInterpolation()
            _ = await interpolate(job.previous.frame, plan: nil, hasTimeRemaining: hasTimeRemaining)
        }
        guard hasTimeRemaining() else {
            stage.bypassReason = "Interpolation deadline"
            resetInterpolation()
            return stage
        }
        switch await interpolate(frame, plan: plan, hasTimeRemaining: hasTimeRemaining) {
        case let .interpolated(frames):
            stage.inputFPS = plan.sourceFPS
            interpolationReference = EnhancementFrameIdentity(frame)
            stage.midpoints = job.isUpscaling
                ? await upscaleMidpoints(frames, configuration: job.configuration, hasTimeRemaining: hasTimeRemaining)
                : frames
        case .passthrough:
            interpolationReference = EnhancementFrameIdentity(frame)
        case let .bypassed(reason):
            stage.bypassReason = reason
            resetInterpolation()
        }
        return stage
    }

    private func processOriginal(_ job: VideoFrameEnhancementJob) async -> VideoEnhancementBackendOutcome? {
        let mode = job.configuration.superResolutionMode
        guard mode != .off else { return nil }
        if let reason = job.upscalingBypassReason { return .bypassed(reason: reason) }
        let deadline = job.deadlines.original
        let hasTimeRemaining: @Sendable () -> Bool = { !Task.isCancelled && .now < deadline }
        guard hasTimeRemaining() else {
            if mode == .videoToolboxML { vtSuperRes.flush() }
            return .bypassed(reason: "Super resolution deadline")
        }
        let result = await upscale(
            job.current.frame, configuration: job.configuration, hasTimeRemaining: hasTimeRemaining
        )
        if mode == .videoToolboxML, case .bypassed = result { vtSuperRes.flush() }
        return result
    }

    private func makeResult(
        _ job: VideoFrameEnhancementJob, interpolation: InterpolationStage, original: VideoEnhancementBackendOutcome?
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
        }
        var labels: [String] = []
        if enhancedOriginal != nil { labels.append(job.configuration.superResolutionMode.telemetryLabel) }
        if !interpolation.midpoints.isEmpty { labels.append(job.interpolationLabel) }
        let output = enhancedOriginal?.pixelBuffer ?? frame.pixelBuffer
        let telemetry = VideoEnhancementTelemetry(
            activeModeLabel: labels.isEmpty ? "Bypass" : labels.joined(separator: " + "),
            inputWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
            inputHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
            outputWidth: CVPixelBufferGetWidth(output),
            outputHeight: CVPixelBufferGetHeight(output),
            inputFPS: interpolation.inputFPS,
            outputFPS: interpolation.inputFPS * Double(interpolation.midpoints.count + 1),
            smoothedProcessingMs: smoothedMs,
            bypassReason: labels.isEmpty ? (srBypass ?? interpolation.bypassReason) : nil,
            isActive: !labels.isEmpty
        )
        return VideoFrameEnhancementResult(
            midpoints: interpolation.midpoints.map(PostProcessFrameBox.init),
            enhancedOriginal: enhancedOriginal.map(PostProcessFrameBox.init),
            telemetry: telemetry, interpolationBypassReason: interpolation.bypassReason,
            originalSuperResolutionBypassReason: srBypass
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
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        if #available(iOS 26.0, *) {
            return await vtFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
        }
        return await visionFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
    }

    private func upscaleMidpoints(
        _ frames: [MediaVideoFrame],
        configuration: VideoEnhancementConfiguration,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> [MediaVideoFrame] {
        var enhanced = frames
        for index in frames.indices {
            guard hasTimeRemaining() else { break }
            let outcome = await upscale(frames[index], configuration: configuration, hasTimeRemaining: hasTimeRemaining)
            if case let .processed(buffer) = outcome {
                enhanced[index].pixelBuffer = buffer
            } else if configuration.superResolutionMode == .videoToolboxML {
                vtSuperRes.flush()
            }
        }
        return enhanced
    }

    private func upscale(
        _ frame: MediaVideoFrame,
        configuration: VideoEnhancementConfiguration,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoEnhancementBackendOutcome {
        let maxScale = configuration.superResolutionScale.factor
        switch configuration.superResolutionMode {
        case .off:
            return .bypassed(reason: "Off")
        case .videoToolboxML:
            let pts = CMTime(seconds: max(0, frame.pts), preferredTimescale: 600)
            return await vtSuperRes.upscale(
                pixelBuffer: frame.pixelBuffer, pts: pts, maxScale: maxScale, hasTimeRemaining: hasTimeRemaining
            )
        case .metalFXSpatial:
            return await metalFXSuperRes.upscale(pixelBuffer: frame.pixelBuffer, maxScale: maxScale)
        }
    }
}
