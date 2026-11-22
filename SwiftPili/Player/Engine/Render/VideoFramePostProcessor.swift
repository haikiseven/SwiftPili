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

    var isUpscaling: Bool { configuration.superResolutionMode != .off && upscalingBypassReason == nil }
}

private struct VideoFrameWarmJob: Sendable {
    let frame: PostProcessFrameBox
    let configuration: VideoEnhancementConfiguration
    let upscale: Bool
    let superResolutionCap: Float
    /// Synthetic plan ending one frame before `frame`, so warm timestamps precede real ones.
    let interpolationPlan: VideoFrameInterpolationPlan?
}

struct VideoFrameWarmReport: Sendable {
    var superResolution = false
    var interpolation = false
    var elapsedMs: Double = 0
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
    private(set) var bufferPlan = VideoEnhancementBufferPlan.default
    private var lastUpscaledBytes: Int?
    private var lastMidpointsPerSource = 0
    private struct WarmKey: Equatable {
        let configuration: VideoEnhancementConfiguration
        let width: Int
        let height: Int
        let format: OSType
    }
    private var warmedKey: WarmKey?
    private var warmTaskCancelled = false
    private(set) var isWarming = false
    private var structuralHoldUntil = ContinuousClock.now
    private var automaticBudget: (bytes: Int, sampledAt: ContinuousClock.Instant)?
    private var lastInputSize: (width: Int, height: Int)?

    /// User-requested configuration. The governor may degrade it at runtime; see `effectiveConfiguration`.
    var configuration = VideoEnhancementConfiguration.disabled {
        didSet {
            guard configuration != oldValue else { return }
            pendingOutcomeMissed = nil
            governor.reset(requested: configuration)
            telemetryWindow.reset()
            warmedKey = nil
            resetBufferPlan()
            frameTelemetry = configuration.isRequested && configuration.isLiveStream
                ? .bypassed(reason: "VOD only") : VideoEnhancementTelemetry()
        }
    }
    /// State of the most recent frame only; noisy under partial load. UI reads `telemetry`.
    private(set) var frameTelemetry = VideoEnhancementTelemetry()
    private var telemetryWindow = VideoEnhancementTelemetryWindow()
    private var lastProcessingMs: Double = 0
    /// What the in-flight submission was expected to deliver, to detect partial failures.
    private var pendingExpectation: (frame: EnhancementFrameIdentity, interpolation: Bool, upscale: Bool)?

    /// Window-aggregated telemetry for the stats overlay / player menu.
    var telemetry: VideoEnhancementTelemetry {
        var value = telemetryWindow.summarize(
            latest: frameTelemetry, configuration: effectiveConfiguration, interpolationLabel: interpolationLabel
        ) ?? frameTelemetry
        if value.smoothedProcessingMs <= 0.01 { value.smoothedProcessingMs = lastProcessingMs }
        value.degradationNote = governor.level > .none ? governor.reason : nil
        return value
    }

    /// Configuration actually executed, after performance / thermal / Low Power degradation.
    var effectiveConfiguration: VideoEnhancementConfiguration { governor.effectiveConfiguration }
    var degradationLevel: VideoEnhancementDegradationLevel { governor.level }

    var isBusy: Bool { activeTask != nil }

    /// Set by the renderer on layout / scale-mode changes.
    var displaySurface: VideoEnhancementDisplaySurface? {
        didSet {
            guard displaySurface != oldValue else { return }
            governor.resetStructuralFloor()
            warmedKey = nil
        }
    }

    /// Effective SR scale cap for this frame, or nil when SR would not be visible on screen.
    func superResolutionCap(for frame: MediaVideoFrame) -> Float? {
        let effective = effectiveConfiguration
        let requested = effective.superResolutionScale.factor
        guard effective.superResolutionMode != .off else { return nil }
        guard configuration.limitToScreenResolution, let displaySurface else { return requested }
        return displaySurface.superResolutionCap(
            inputWidth: CVPixelBufferGetWidth(frame.pixelBuffer), inputHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
            requested: requested, mode: effective.superResolutionMode
        )
    }

    private func superResolutionBypassReason(_ frame: MediaVideoFrame) -> String? {
        VideoEnhancementGuardrails.superResolutionBypassReason(frame.pixelBuffer)
            ?? (superResolutionCap(for: frame) == nil ? "Display resolution reached" : nil)
    }

    /// How far ahead of the display clock the engine should hand frames to the renderer.
    var preferredPresentLeadSeconds: TimeInterval { bufferPlan.lead }

    var interpolationLabel: String {
        if #available(iOS 26.0, *) { return "VT FI" }
        return "Vision FI"
    }

    func canProcess(_ frame: MediaVideoFrame) -> Bool {
        guard configuration.isRequested, ExperimentalSettingsPolicy.videoEnhancementEnabled else {
            frameTelemetry = VideoEnhancementTelemetry()
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
        } else if let reason = superResolutionBypassReason(frame) {
            noteBypass(reason)
        }
        return false
    }

    func canUpscale(_ frame: MediaVideoFrame) -> Bool {
        effectiveConfiguration.superResolutionMode != .off && superResolutionBypassReason(frame) == nil
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
        frameTelemetry = .bypassed(reason: reason)
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
        pendingExpectation = nil
        telemetryWindow.reset()
        warmedKey = nil
        governor.noteDiscontinuity()
    }

    private func finalizePendingOutcome() {
        pendingExpectation = nil
        guard let missed = pendingOutcomeMissed else { return }
        pendingOutcomeMissed = nil
        governor.record(missed: missed)
    }

    func noteMidpointAccepted(
        _ midpoint: MediaVideoFrame, previous: MediaVideoFrame, original: MediaVideoFrame, acceptedCount: Int = 1
    ) {
        let sourceFPS = 1 / (original.pts - previous.pts)
        frameTelemetry = VideoEnhancementTelemetry(
            activeModeLabel: interpolationLabel,
            inputWidth: CVPixelBufferGetWidth(original.pixelBuffer),
            inputHeight: CVPixelBufferGetHeight(original.pixelBuffer),
            outputWidth: CVPixelBufferGetWidth(midpoint.pixelBuffer),
            outputHeight: CVPixelBufferGetHeight(midpoint.pixelBuffer),
            inputFPS: sourceFPS, outputFPS: sourceFPS * Double(acceptedCount + 1), isActive: true
        )
    }

    private func noteAccepted(_ result: VideoFrameEnhancementResult, midpointCount: Int, enhancedOriginal: Bool) {
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
        frameTelemetry = displayed
    }

    /// Called once for every original frame the renderer presents while enhancement is requested.
    func noteOriginalPresented(
        _ original: MediaVideoFrame,
        result: VideoFrameEnhancementResult?,
        midpointCount: Int,
        upscaled: MediaVideoFrame?
    ) {
        if let result {
            noteAccepted(result, midpointCount: midpointCount, enhancedOriginal: upscaled != nil)
            if result.telemetry.smoothedProcessingMs > 0.01 { lastProcessingMs = result.telemetry.smoothedProcessingMs }
        }
        guard configuration.isRequested, !configuration.isLiveStream else { return }

        var missReason: String?
        if let expectation = pendingExpectation, expectation.frame == EnhancementFrameIdentity(original) {
            let interpolationMissed = expectation.interpolation && midpointCount == 0
            let upscaleMissed = expectation.upscale && upscaled == nil
            if interpolationMissed {
                missReason = result?.interpolationBypassReason ?? "Interpolation deadline"
            } else if upscaleMissed {
                missReason = result?.originalSuperResolutionBypassReason ?? "Super resolution deadline"
            }
            let missed = (pendingOutcomeMissed ?? false) || interpolationMissed || upscaleMissed
            pendingOutcomeMissed = nil
            pendingExpectation = nil
            governor.record(missed: missed)
        } else if upscaled == nil, midpointCount == 0 {
            missReason = frameTelemetry.bypassReason
        }
        let input = original.pixelBuffer
        let output = upscaled?.pixelBuffer ?? input
        telemetryWindow.record(.init(
            at: .now, upscaled: upscaled != nil, midpoints: midpointCount, missReason: missReason,
            inputWidth: CVPixelBufferGetWidth(input), inputHeight: CVPixelBufferGetHeight(input),
            outputWidth: CVPixelBufferGetWidth(output), outputHeight: CVPixelBufferGetHeight(output)
        ))
        updateBufferPlan(original: original, upscaled: upscaled, midpointCount: midpointCount)
    }

    private func updateBufferPlan(original: MediaVideoFrame, upscaled: MediaVideoFrame?, midpointCount: Int) {
        let effective = effectiveConfiguration
        if effective.superResolutionMode == .off {
            lastUpscaledBytes = nil
        } else if let upscaled {
            lastUpscaledBytes = upscaled.pixelBuffer.enhancementByteSize
        }
        if !effective.frameInterpolationEnabled {
            lastMidpointsPerSource = 0
        } else if midpointCount > 0 {
            lastMidpointsPerSource = midpointCount
        }
        let inputSize = (CVPixelBufferGetWidth(original.pixelBuffer), CVPixelBufferGetHeight(original.pixelBuffer))
        if lastInputSize.map({ $0 != inputSize }) ?? false { governor.resetStructuralFloor() }
        lastInputSize = inputSize
        guard let fps = VideoFrameInterpolationTiming.sourceFPS(original),
              lastUpscaledBytes != nil || lastMidpointsPerSource > 0 else {
            if !effective.isRequested { resetBufferPlan() }
            return
        }
        let now = ContinuousClock.now
        let plan = VideoEnhancementBufferPlan.make(
            sourceFPS: fps, midpointsPerSource: lastMidpointsPerSource,
            upscaledBytes: lastUpscaledBytes, interpolatedBytes: original.pixelBuffer.enhancementByteSize,
            budgetBytes: bufferBudgetBytes(now: now), maximumLead: configuration.maxLookahead.seconds
        )
        if plan.isMemoryBound, now >= structuralHoldUntil, governor.raiseStructuralFloor(now: now) {
            // Re-measure at the new level before judging again.
            structuralHoldUntil = now.advanced(by: .milliseconds(1500))
            lastUpscaledBytes = nil
            lastMidpointsPerSource = 0
            if PlayerLog.isCapturing {
                PlayerLog.log(
                    "[PathA][enhancement] memory-bound fps=\(String(format: "%.0f", fps)) " +
                        "midpoints=\(midpointCount) srBytes=\(upscaled?.pixelBuffer.enhancementByteSize ?? 0) " +
                        "budget=\(plan.budgetBytes >> 20)MB → level=\(governor.level)"
                )
            }
            return
        }
        applyBufferPlan(plan)
    }

    /// User-selected or automatic budget; halved for a minute after a system memory warning.
    private func bufferBudgetBytes(now: ContinuousClock.Instant) -> Int {
        var bytes: Int
        if let fixed = configuration.bufferBudget.fixedBytes {
            bytes = fixed
        } else if let cached = automaticBudget, cached.sampledAt.duration(to: now) < .seconds(5) {
            bytes = cached.bytes
        } else {
            bytes = VideoEnhancementBufferPlan.automaticBudget(currentUsageBytes: bufferPlan.estimatedBytes)
            automaticBudget = (bytes, now)
        }
        if VideoEnhancementMemoryPressure.isUnderPressure { bytes /= 2 }
        return bytes
    }

    private func resetBufferPlan() {
        lastUpscaledBytes = nil
        lastMidpointsPerSource = 0
        automaticBudget = nil
        structuralHoldUntil = .now
        applyBufferPlan(.default)
    }

    private func applyBufferPlan(_ plan: VideoEnhancementBufferPlan) {
        // Ignore sub-50ms lead jitter so the engine's present lead does not wobble every frame.
        if plan.superResolutionFrames == bufferPlan.superResolutionFrames,
           plan.interpolationFramesPerPhase == bufferPlan.interpolationFramesPerPhase,
           abs(plan.lead - bufferPlan.lead) < 0.05 { return }
        bufferPlan = plan
        VideoEnhancementPoolLimits.apply(plan)
        if PlayerLog.isCapturing {
            PlayerLog.log(
                "[PathA][enhancement] buffer plan lead=\(String(format: "%.2f", plan.lead))s " +
                    "srFrames=\(plan.superResolutionFrames) fiFramesPerPhase=\(plan.interpolationFramesPerPhase) " +
                    "estimated=\(plan.estimatedBytes >> 20)MB budget=\(plan.budgetBytes >> 20)MB " +
                    "memAvail=\(Int(os_proc_available_memory()) >> 20)MB"
            )
        }
    }

    // MARK: Prewarm

    /// Creates VT / MetalFX / FI sessions on a real decoded frame before playback reaches it, so
    /// the first enhanced frames after start / seek / backend switch don't time out on session setup
    /// or model load. Cheap no-op when already warm.
    func prewarm(with frame: MediaVideoFrame) {
        guard activeTask == nil, configuration.isRequested, !configuration.isLiveStream,
              ExperimentalSettingsPolicy.videoEnhancementEnabled,
              VideoEnhancementGuardrails.commonBypassReason(
                  configuration: configuration, pixelBuffer: frame.pixelBuffer
              ) == nil else { return }
        let effective = effectiveConfiguration
        guard effective.isRequested else { return }
        let buffer = frame.pixelBuffer
        let key = WarmKey(
            configuration: effective, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            format: CVPixelBufferGetPixelFormatType(buffer)
        )
        guard key != warmedKey else { return }
        warmedKey = key

        let upscale = canUpscale(frame)
        var plan: VideoFrameInterpolationPlan?
        let interval = frame.duration
        if effective.frameInterpolationEnabled, interpolationInputBypassReason(frame) == nil,
           interval.isFinite, interval > 0 {
            plan = VideoFrameInterpolationPlan(
                previousPTS: frame.pts - 2 * interval, currentPTS: frame.pts - interval, interval: interval,
                rate: effective.interpolationRate
            )
            if #unavailable(iOS 26.0), !VisionFrameInterpolationBackend.acceptsPairDelta(interval) { plan = nil }
        }
        guard upscale || plan != nil else { return }

        isWarming = true
        warmTaskCancelled = false
        governor.noteDiscontinuity()
        let job = VideoFrameWarmJob(
            frame: PostProcessFrameBox(frame: frame), configuration: effective, upscale: upscale,
            superResolutionCap: superResolutionCap(for: frame) ?? effective.superResolutionScale.factor,
            interpolationPlan: plan
        )
        let worker = self.worker
        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let report = await worker.prewarm(job)
            await self?.finishPrewarm(report)
        }
    }

    private func finishPrewarm(_ report: VideoFrameWarmReport) {
        activeTask = nil
        isWarming = false
        if warmTaskCancelled { warmedKey = nil }
        // Grace from the end of warm-up so the first real frames are not judged.
        governor.noteDiscontinuity()
        if PlayerLog.isCapturing {
            PlayerLog.log(
                "[PathA][enhancement] prewarm sr=\(report.superResolution) fi=\(report.interpolation) " +
                    "elapsed=\(String(format: "%.1f", report.elapsedMs))ms cancelled=\(warmTaskCancelled)"
            )
        }
        if needsTearDown {
            needsTearDown = false
            needsFlush = false
            startTearDown()
        } else if needsFlush {
            needsFlush = false
            worker.flush()
        }
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
            upscalingBypassReason: superResolutionBypassReason(frame),
            superResolutionCap: superResolutionCap(for: frame) ?? effectiveConfiguration.superResolutionScale.factor
        )
        pendingExpectation = (EnhancementFrameIdentity(frame), job.interpolationPlan != nil, job.isUpscaling)
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
        if isWarming {
            // Warm-up is independent of stream position; let it finish and flush afterwards.
            needsFlush = true
        } else if activeTask != nil {
            needsFlush = true
            activeTask?.cancel()
        } else {
            worker.flush()
        }
    }

    func tearDown() {
        pendingOutcomeMissed = nil
        pendingExpectation = nil
        governor.reset(requested: configuration)
        telemetryWindow.reset()
        lastProcessingMs = 0
        warmedKey = nil
        resetBufferPlan()
        frameTelemetry = VideoEnhancementTelemetry()
        if isWarming { warmTaskCancelled = true }
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
    private struct SessionClock {
        let width: Int
        let height: Int
        let detail: Int
        var pts: TimeInterval
    }
    /// Last VT SR submission (raster + scale cap + pts); VT restarts the session on a new raster or
    /// a PTS that goes backwards, so warm-up only runs when the next real frame would pay that.
    private var superResolutionClock: SessionClock?
    private var metalFXWarmRaster: SessionClock?
    /// Last FI reference (raster + phase count + pts).
    private var interpolationClock: SessionClock?

    func prewarm(_ job: VideoFrameWarmJob) async -> VideoFrameWarmReport {
        let start = ContinuousClock.now
        var report = VideoFrameWarmReport()
        releaseIdleBackends(for: job.configuration)
        let frame = job.frame.frame
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let untilCancelled: @Sendable () -> Bool = { !Task.isCancelled }

        if job.upscale {
            let cap = job.superResolutionCap
            let capKey = Int((cap * 100).rounded())
            switch job.configuration.superResolutionMode {
            case .off:
                break
            case .videoToolboxML:
                let clock = superResolutionClock
                if clock == nil || clock?.width != width || clock?.height != height
                    || clock?.detail != capKey || frame.pts < (clock?.pts ?? 0) {
                    let warmPTS = max(0, frame.pts - 1)
                    _ = await vtSuperRes.upscale(
                        pixelBuffer: frame.pixelBuffer, pts: CMTime(seconds: warmPTS, preferredTimescale: 600),
                        maxScale: cap, hasTimeRemaining: untilCancelled
                    )
                    vtSuperRes.flush()
                    superResolutionClock = SessionClock(width: width, height: height, detail: capKey, pts: warmPTS)
                    report.superResolution = true
                }
            case .metalFXSpatial:
                if metalFXWarmRaster?.width != width || metalFXWarmRaster?.height != height
                    || metalFXWarmRaster?.detail != capKey {
                    _ = await metalFXSuperRes.upscale(pixelBuffer: frame.pixelBuffer, maxScale: cap)
                    metalFXWarmRaster = SessionClock(width: width, height: height, detail: capKey, pts: 0)
                    report.superResolution = true
                }
            }
        }

        if let plan = job.interpolationPlan, !Task.isCancelled {
            let clock = interpolationClock
            if clock == nil || clock?.width != width || clock?.height != height
                || clock?.detail != plan.phases.count || frame.pts < (clock?.pts ?? 0) {
                var first = frame
                first.displayCoverage = nil
                first.pts = plan.pts.first.map { $0 - plan.sourceInterval * Double(plan.phases[0]) } ?? frame.pts
                first.duration = plan.sourceInterval
                var second = first
                second.pts = first.pts + plan.sourceInterval
                resetInterpolation()
                _ = await interpolate(first, plan: nil, hasTimeRemaining: untilCancelled)
                _ = await interpolate(second, plan: plan, hasTimeRemaining: untilCancelled)
                resetInterpolation()
                report.interpolation = true
            }
        }
        report.elapsedMs = Double(start.duration(to: .now) / .microseconds(1)) / 1_000
        return report
    }

    /// The governor can switch backends at runtime; release sessions that are no longer used so a
    /// device already short on resources does not keep idle VT / Metal state resident.
    private func releaseIdleBackends(for configuration: VideoEnhancementConfiguration) {
        let mode = configuration.superResolutionMode
        if mode != lastSuperResolutionMode {
            if lastSuperResolutionMode == .videoToolboxML {
                vtSuperRes.tearDown()
                superResolutionClock = nil
            }
            if lastSuperResolutionMode == .metalFXSpatial {
                metalFXSuperRes.tearDown()
                metalFXWarmRaster = nil
            }
            lastSuperResolutionMode = mode
        }
        if lastInterpolationEnabled, !configuration.frameInterpolationEnabled {
            vtFrameInterp.tearDown()
            visionFrameInterp.tearDown()
            interpolationReference = nil
            interpolationClock = nil
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
        superResolutionClock = nil
        metalFXWarmRaster = nil
        interpolationClock = nil
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
                ? await upscaleMidpoints(
                    frames, configuration: job.configuration, maxScale: job.superResolutionCap,
                    hasTimeRemaining: hasTimeRemaining
                )
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
            job.current.frame, configuration: job.configuration, maxScale: job.superResolutionCap,
            hasTimeRemaining: hasTimeRemaining
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
        interpolationClock = SessionClock(
            width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
            detail: plan?.phases.count ?? interpolationClock?.detail ?? 0, pts: frame.pts
        )
        if #available(iOS 26.0, *) {
            return await vtFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
        }
        return await visionFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
    }

    private func upscaleMidpoints(
        _ frames: [MediaVideoFrame],
        configuration: VideoEnhancementConfiguration,
        maxScale: Float,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> [MediaVideoFrame] {
        var enhanced = frames
        for index in frames.indices {
            guard hasTimeRemaining() else { break }
            let outcome = await upscale(
                frames[index], configuration: configuration, maxScale: maxScale, hasTimeRemaining: hasTimeRemaining
            )
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
        maxScale: Float,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoEnhancementBackendOutcome {
        switch configuration.superResolutionMode {
        case .off:
            return .bypassed(reason: "Off")
        case .videoToolboxML:
            let pts = CMTime(seconds: max(0, frame.pts), preferredTimescale: 600)
            superResolutionClock = SessionClock(
                width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
                detail: Int((maxScale * 100).rounded()), pts: max(0, frame.pts)
            )
            return await vtSuperRes.upscale(
                pixelBuffer: frame.pixelBuffer, pts: pts, maxScale: maxScale, hasTimeRemaining: hasTimeRemaining
            )
        case .metalFXSpatial:
            return await metalFXSuperRes.upscale(pixelBuffer: frame.pixelBuffer, maxScale: maxScale)
        }
    }
}
