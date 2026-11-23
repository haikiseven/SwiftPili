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

private struct VideoFrameWarmJob: Sendable {
    let frame: PostProcessFrameBox
    let configuration: VideoEnhancementConfiguration
    let upscale: Bool
    let superResolutionCap: Float
    let superResolutionTargetDimensions: VideoSuperResolutionDimensions?
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
    private var cadenceEstimator = VideoFrameCadenceEstimator()
    private var interpolationGridNextPTS: TimeInterval?

    /// User-requested configuration. The governor may degrade it at runtime; see `effectiveConfiguration`.
    var configuration = VideoEnhancementConfiguration.disabled {
        didSet {
            guard configuration != oldValue else { return }
            pendingOutcomeMissed = nil
            governor.reset(requested: configuration)
            telemetryWindow.reset()
            cadenceEstimator.reset()
            interpolationGridNextPTS = nil
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
    private var pendingExpectation: (frame: EnhancementFrameIdentity, expectedMidpointCount: Int, upscale: Bool)?

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

    private enum SuperResolutionResolutionPlan: Equatable {
        case scaleCap(Float)
        case explicitOutput(VideoSuperResolutionDimensions)
        case bypassed(String)

        var scaleCapValue: Float {
            if case let .scaleCap(cap) = self { return cap }
            return 0
        }

        var targetDimensions: VideoSuperResolutionDimensions? {
            if case let .explicitOutput(dimensions) = self { return dimensions }
            return nil
        }

        var bypassReason: String? {
            if case let .bypassed(reason) = self { return reason }
            return nil
        }
    }

    private func superResolutionPlan(for frame: MediaVideoFrame) -> SuperResolutionResolutionPlan {
        let effective = effectiveConfiguration
        guard effective.superResolutionMode != .off else { return .bypassed("Off") }
        if let reason = VideoEnhancementGuardrails.superResolutionBypassReason(
            frame.pixelBuffer, maxInputResolution: effective.maxInputResolution
        ) {
            return .bypassed(reason)
        }
        let inputWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
        let inputHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
        switch effective.superResolutionMode {
        case .off:
            return .bypassed("Off")
        case .videoToolboxML:
            let requested = effective.superResolutionScale.factor
            guard configuration.limitToScreenResolution, let displaySurface else { return .scaleCap(requested) }
            guard let cap = displaySurface.superResolutionCap(
                inputWidth: inputWidth, inputHeight: inputHeight, requested: requested, mode: .videoToolboxML
            ) else { return .bypassed("Display resolution reached") }
            return .scaleCap(cap)
        case .metalFXSpatial:
            if let targetShortEdge = effective.superResolutionTargetResolution.shortEdge {
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
                let maxAutoScale: Float = governor.level >= .reducedScale ? 2 : 4
                guard let cap = displaySurface.superResolutionCap(
                    inputWidth: inputWidth, inputHeight: inputHeight, requested: maxAutoScale, mode: .metalFXSpatial
                ) else { return .bypassed("Display resolution reached") }
                return .scaleCap(cap)
            }
            return .scaleCap(effective.superResolutionScale.factor)
        }
    }

    /// Effective SR scale cap for this frame, or nil when SR would not be visible on screen.
    func superResolutionCap(for frame: MediaVideoFrame) -> Float? {
        switch superResolutionPlan(for: frame) {
        case let .scaleCap(cap): return cap
        case .explicitOutput, .bypassed: return nil
        }
    }

    private func superResolutionBypassReason(_ frame: MediaVideoFrame) -> String? {
        superResolutionPlan(for: frame).bypassReason
    }

    /// How far ahead of the display clock the engine should hand frames to the renderer.
    var preferredPresentLeadSeconds: TimeInterval { bufferPlan.lead }

    var interpolationLabel: String {
        if #available(iOS 26.0, *) { return "VT FI" }
        return "Vision FI"
    }

    func canProcess(_ frame: MediaVideoFrame, playbackRate: Double = 1.0) -> Bool {
        guard configuration.isRequested, ExperimentalSettingsPolicy.videoEnhancementEnabled else {
            frameTelemetry = VideoEnhancementTelemetry()
            return false
        }
        cadenceEstimator.observe(pts: frame.pts)
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
            if let reason = interpolationInputBypassReason(frame) {
                noteBypass(reason)
                return false
            }
            guard let estimatedInterval = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration) else {
                noteBypass("Frame timing invalid")
                return false
            }
            if let reason = VideoFrameInterpolationPlan.streamEligibilityBypassReason(
                sourceInterval: estimatedInterval,
                rate: effective.interpolationRate,
                playbackRate: playbackRate
            ) {
                noteBypass(reason)
                return false
            }
            return true
        } else if let reason = superResolutionBypassReason(frame) {
            noteBypass(reason)
        }
        return false
    }

    func canUpscale(_ frame: MediaVideoFrame) -> Bool {
        effectiveConfiguration.superResolutionMode != .off && superResolutionBypassReason(frame) == nil
    }

    /// Returns the non-overlapping media-time presentation duration for an original frame when
    /// frame interpolation is active and eligible on this stream, or `nil` when the original
    /// frame should retain its full source duration.
    func activeOutputFrameDuration(for frame: MediaVideoFrame, playbackRate: Double = 1.0) -> TimeInterval? {
        guard configuration.isRequested,
              ExperimentalSettingsPolicy.videoEnhancementEnabled,
              VideoEnhancementGuardrails.commonBypassReason(
                  configuration: configuration, pixelBuffer: frame.pixelBuffer
              ) == nil else {
            return nil
        }
        let effective = effectiveConfiguration
        guard effective.frameInterpolationEnabled,
              interpolationInputBypassReason(frame) == nil,
              frame.duration.isFinite, frame.duration > 0 else {
            return nil
        }
        let estimatedInterval = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration) ?? frame.duration
        guard VideoFrameInterpolationPlan.streamEligibilityBypassReason(
            sourceInterval: estimatedInterval,
            rate: effective.interpolationRate,
            playbackRate: playbackRate
        ) == nil else {
            return nil
        }
        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        let outputDuration: TimeInterval
        if let targetFPS = effective.interpolationRate.targetFPS {
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
                rate: effective.interpolationRate,
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

    /// Pure, idempotent planner for a `(previous, current)` source pair. Never mutates
    /// `interpolationGridNextPTS`; grid advancement is committed only in `noteOriginalPresented`.
    func interpolationPlanOutcome(
        previous: MediaVideoFrame,
        current: MediaVideoFrame,
        playbackRate: Double = 1.0
    ) -> VideoInterpolationPlanOutcome {
        let effective = effectiveConfiguration
        guard effective.frameInterpolationEnabled else { return .bypass("Off") }
        if let reason = VideoEnhancementGuardrails.commonBypassReason(
            configuration: configuration, pixelBuffer: previous.pixelBuffer
        ) {
            return .bypass(reason)
        }
        if let reason = interpolationInputBypassReason(previous) { return .bypass(reason) }
        if let reason = interpolationInputBypassReason(current) { return .bypass(reason) }
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
            rate: effective.interpolationRate,
            playbackRate: playbackRate
        )
    }

    func interpolationPlan(
        previous: MediaVideoFrame,
        current: MediaVideoFrame,
        playbackRate: Double = 1.0
    ) -> VideoFrameInterpolationPlan? {
        if case let .plan(resolved) = interpolationPlanOutcome(
            previous: previous, current: current, playbackRate: playbackRate
        ) {
            return resolved
        }
        return nil
    }

    private func interpolationInputBypassReason(_ frame: MediaVideoFrame) -> String? {
        if let reason = VideoFramePairFormat.interpolationBypassReason(frame.pixelBuffer) { return reason }
        if #available(iOS 26.0, *) { return nil }
        return VisionFrameInterpolationBackend.inputBypassReason(
            frame,
            maxInputResolution: effectiveConfiguration.maxInputResolution,
            cadenceInterval: cadenceEstimator.medianInterval
        )
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
        cadenceEstimator.reset()
        interpolationGridNextPTS = nil
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
        var labels: [String] = []
        if srActive { labels.append(effectiveConfiguration.superResolutionMode.telemetryLabel) }
        if midpointCount > 0 { labels.append(interpolationLabel) }
        displayed.activeModeLabel = labels.isEmpty ? "Bypass" : labels.joined(separator: " + ")
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
            if result.telemetry.smoothedProcessingMs > 0.01 { lastProcessingMs = result.telemetry.smoothedProcessingMs }
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
                  let targetFPS = effectiveConfiguration.interpolationRate.targetFPS {
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
            let missed = (pendingOutcomeMissed ?? false) || interpolationMissed || upscaleMissed
            pendingOutcomeMissed = nil
            pendingExpectation = nil
            governor.record(missed: missed)
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
        updateBufferPlan(
            original: original,
            upscaled: upscaled ?? (midpointsWereUpscaled ? result?.midpoints.first?.frame : nil),
            midpointCount: midpointCount,
            committedPlan: committedPlan,
            playbackRate: speed
        )
    }

    private func updateBufferPlan(
        original: MediaVideoFrame,
        upscaled: MediaVideoFrame?,
        midpointCount: Int,
        committedPlan: VideoFrameInterpolationPlan?,
        playbackRate: Double = 1.0
    ) {
        let effective = effectiveConfiguration
        if effective.superResolutionMode == .off {
            lastUpscaledBytes = nil
        } else if let upscaled {
            lastUpscaledBytes = upscaled.pixelBuffer.enhancementByteSize
        }
        if !effective.frameInterpolationEnabled {
            lastMidpointsPerSource = 0
        } else if let plan = committedPlan, plan.isCFRResampling {
            let cadence = cadenceEstimator.estimatedInterval(fallbackDuration: original.duration) ?? plan.sourceInterval
            let worstCasePhases = max(1, Int((cadence / plan.outputFrameDuration).rounded(.up)))
            lastMidpointsPerSource = min(
                VideoFrameInterpolationPlan.maximumPhasesPerPair, max(midpointCount, worstCasePhases)
            )
        } else if midpointCount > 0 {
            lastMidpointsPerSource = midpointCount
        }
        let inputSize = (CVPixelBufferGetWidth(original.pixelBuffer), CVPixelBufferGetHeight(original.pixelBuffer))
        if lastInputSize.map({ $0 != inputSize }) ?? false { governor.resetStructuralFloor() }
        lastInputSize = inputSize
        let estimatedInterval = cadenceEstimator.estimatedInterval(fallbackDuration: original.duration)
        let mediaFPS = estimatedInterval.map { 1.0 / $0 } ?? VideoFrameInterpolationTiming.sourceFPS(original)
        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        let fps = mediaFPS.map { $0 * speed }
        guard let fps, fps.isFinite, fps > 0,
              lastUpscaledBytes != nil || lastMidpointsPerSource > 0 else {
            if !effective.isRequested { resetBufferPlan() }
            return
        }
        let now = ContinuousClock.now
        let plan = VideoEnhancementBufferPlan.make(
            sourceFPS: fps,
            midpointsPerSource: lastMidpointsPerSource,
            upscaledBytes: lastUpscaledBytes,
            interpolatedBytes: original.pixelBuffer.enhancementByteSize,
            budgetBytes: bufferBudgetBytes(now: now),
            maximumLead: configuration.maxLookahead.seconds,
            outputFPSOverride: committedPlan?.targetOutputFPS
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

        let srPlan = superResolutionPlan(for: frame)
        let upscale = srPlan.bypassReason == nil
        var plan: VideoFrameInterpolationPlan?
        if effective.frameInterpolationEnabled, interpolationInputBypassReason(frame) == nil,
           let interval = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration) {
            plan = VideoFrameInterpolationPlan.prewarmPlan(
                before: frame.pts,
                interval: interval,
                cadenceInterval: cadenceEstimator.medianInterval,
                isCadenceStable: cadenceEstimator.isConstantRate,
                rate: effective.interpolationRate
            )
            if #unavailable(iOS 26.0), !VisionFrameInterpolationBackend.acceptsPairDelta(interval) { plan = nil }
        }
        guard upscale || plan != nil else { return }
        warmedKey = key

        isWarming = true
        warmTaskCancelled = false
        governor.noteDiscontinuity()
        let job = VideoFrameWarmJob(
            frame: PostProcessFrameBox(frame: frame), configuration: effective, upscale: upscale,
            superResolutionCap: srPlan.scaleCapValue,
            superResolutionTargetDimensions: srPlan.targetDimensions,
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
        interpolationPlan: VideoFrameInterpolationPlan? = nil,
        playbackRate: Double = 1.0,
        onUpdate: @escaping @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        precondition(activeTask == nil)
        finalizePendingOutcome()
        pendingOutcomeMissed = false
        let srPlan = superResolutionPlan(for: frame)
        let resolvedPlan = deadlines.midpoint.flatMap { _ in
            interpolationPlan ?? self.interpolationPlan(previous: previous, current: frame, playbackRate: playbackRate)
        }.flatMap { $0.phases.isEmpty ? nil : $0 }
        let job = VideoFrameEnhancementJob(
            current: PostProcessFrameBox(frame: frame), previous: PostProcessFrameBox(frame: previous),
            configuration: effectiveConfiguration, interpolationLabel: interpolationLabel,
            interpolationPlan: resolvedPlan,
            deadlines: deadlines,
            upscalingBypassReason: srPlan.bypassReason,
            superResolutionCap: srPlan.scaleCapValue,
            superResolutionTargetDimensions: srPlan.targetDimensions
        )
        pendingExpectation = (
            EnhancementFrameIdentity(frame),
            job.interpolationPlan?.phases.count ?? 0,
            job.isUpscaling
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
        interpolationGridNextPTS = nil
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
        cadenceEstimator.reset()
        interpolationGridNextPTS = nil
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
                        pixelBuffer: frame.pixelBuffer, pts: CMTime(seconds: warmPTS, preferredTimescale: 60_000),
                        maxScale: cap, hasTimeRemaining: untilCancelled
                    )
                    vtSuperRes.flush()
                    superResolutionClock = SessionClock(width: width, height: height, detail: capKey, pts: warmPTS)
                    report.superResolution = true
                }
            case .metalFXSpatial:
                let warmDetail = job.superResolutionTargetDimensions
                    .map { ($0.width << 16) | ($0.height & 0xFFFF) } ?? capKey
                if metalFXWarmRaster?.width != width || metalFXWarmRaster?.height != height
                    || metalFXWarmRaster?.detail != warmDetail {
                    _ = await metalFXSuperRes.upscale(
                        pixelBuffer: frame.pixelBuffer, maxScale: cap,
                        targetDimensions: job.superResolutionTargetDimensions,
                        sharpness: job.configuration.superResolutionSharpness
                    )
                    metalFXWarmRaster = SessionClock(width: width, height: height, detail: warmDetail, pts: 0)
                    report.superResolution = true
                }
            }
        }

        if let plan = job.interpolationPlan, !plan.phases.isEmpty, !Task.isCancelled {
            let clock = interpolationClock
            let planDetail = Self.interpolationSessionDetail(for: plan)
            if clock == nil || clock?.width != width || clock?.height != height
                || clock?.detail != planDetail || frame.pts < (clock?.pts ?? 0) {
                var first = frame
                first.pts = plan.pts.first.map { $0 - plan.sourceInterval * Double(plan.phases[0]) } ?? frame.pts
                first.duration = plan.sourceInterval
                var second = first
                second.pts = first.pts + plan.sourceInterval
                resetInterpolation()
                _ = await interpolate(
                    first, plan: nil, maxInputResolution: job.configuration.maxInputResolution,
                    hasTimeRemaining: untilCancelled
                )
                _ = await interpolate(
                    second, plan: plan, maxInputResolution: job.configuration.maxInputResolution,
                    hasTimeRemaining: untilCancelled
                )
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
        var midpointsUpscaled = false
    }

    private static func interpolationSessionDetail(for plan: VideoFrameInterpolationPlan) -> Int {
        plan.allowsLowLatency ? plan.phases.count : -1
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
        let shouldUpscaleOriginal = job.isUpscaling
            && ((job.interpolationPlan?.emitsOriginal ?? true) || interpolation.midpoints.isEmpty)
        if shouldUpscaleOriginal, !interpolation.midpoints.isEmpty, !Task.isCancelled {
            await publishMidpoints(interpolation.midpoints.map(PostProcessFrameBox.init))
        }
        let original = shouldUpscaleOriginal ? await processOriginal(job) : nil
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
            _ = await interpolate(
                job.previous.frame, plan: nil, maxInputResolution: job.configuration.maxInputResolution,
                hasTimeRemaining: hasTimeRemaining
            )
        }
        guard hasTimeRemaining() else {
            stage.bypassReason = "Interpolation deadline"
            resetInterpolation()
            return stage
        }
        switch await interpolate(
            frame, plan: plan, maxInputResolution: job.configuration.maxInputResolution,
            hasTimeRemaining: hasTimeRemaining
        ) {
        case let .interpolated(frames):
            stage.inputFPS = plan.sourceFPS
            interpolationReference = EnhancementFrameIdentity(frame)
            if job.isUpscaling {
                let upscaled = await upscaleMidpoints(
                    frames, configuration: job.configuration, maxScale: job.superResolutionCap,
                    targetDimensions: job.superResolutionTargetDimensions,
                    hasTimeRemaining: hasTimeRemaining
                )
                stage.midpoints = upscaled.frames
                stage.midpointsUpscaled = upscaled.allUpscaled
            } else {
                stage.midpoints = frames
                stage.midpointsUpscaled = false
            }
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
            targetDimensions: job.superResolutionTargetDimensions,
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
        let srActive = enhancedOriginal != nil || interpolation.midpointsUpscaled
        var labels: [String] = []
        if srActive { labels.append(job.configuration.superResolutionMode.telemetryLabel) }
        if !interpolation.midpoints.isEmpty { labels.append(job.interpolationLabel) }
        let output = enhancedOriginal?.pixelBuffer
            ?? (interpolation.midpointsUpscaled ? interpolation.midpoints.first?.pixelBuffer : nil)
            ?? frame.pixelBuffer
        let outputFPS = job.interpolationPlan?.targetOutputFPS
            ?? (interpolation.inputFPS * Double(interpolation.midpoints.count + 1))
        let telemetry = VideoEnhancementTelemetry(
            activeModeLabel: labels.isEmpty ? "Bypass" : labels.joined(separator: " + "),
            inputWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
            inputHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
            outputWidth: CVPixelBufferGetWidth(output),
            outputHeight: CVPixelBufferGetHeight(output),
            inputFPS: interpolation.inputFPS,
            outputFPS: outputFPS,
            smoothedProcessingMs: smoothedMs,
            bypassReason: labels.isEmpty ? (srBypass ?? interpolation.bypassReason) : nil,
            isActive: !labels.isEmpty
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
        interpolationClock = SessionClock(
            width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
            detail: plan.map(Self.interpolationSessionDetail(for:)) ?? interpolationClock?.detail ?? 0,
            pts: frame.pts
        )
        if #available(iOS 26.0, *) {
            return await vtFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
        }
        return await visionFrameInterp.process(
            frame, plan: plan, maxInputResolution: maxInputResolution, hasTimeRemaining: hasTimeRemaining
        )
    }

    private func upscaleMidpoints(
        _ frames: [MediaVideoFrame],
        configuration: VideoEnhancementConfiguration,
        maxScale: Float,
        targetDimensions: VideoSuperResolutionDimensions?,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> (frames: [MediaVideoFrame], allUpscaled: Bool) {
        guard !frames.isEmpty else { return (frames, false) }
        var enhanced = frames
        for index in frames.indices {
            guard hasTimeRemaining() else { return (frames, false) }
            let outcome = await upscale(
                frames[index], configuration: configuration, maxScale: maxScale,
                targetDimensions: targetDimensions, hasTimeRemaining: hasTimeRemaining
            )
            if case let .processed(buffer) = outcome {
                enhanced[index].pixelBuffer = buffer
            } else {
                if configuration.superResolutionMode == .videoToolboxML {
                    vtSuperRes.flush()
                }
                return (frames, false)
            }
        }
        return (enhanced, true)
    }

    private func upscale(
        _ frame: MediaVideoFrame,
        configuration: VideoEnhancementConfiguration,
        maxScale: Float,
        targetDimensions: VideoSuperResolutionDimensions?,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoEnhancementBackendOutcome {
        switch configuration.superResolutionMode {
        case .off:
            return .bypassed(reason: "Off")
        case .videoToolboxML:
            let pts = CMTime(seconds: max(0, frame.pts), preferredTimescale: 60_000)
            superResolutionClock = SessionClock(
                width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
                detail: Int((maxScale * 100).rounded()), pts: max(0, frame.pts)
            )
            return await vtSuperRes.upscale(
                pixelBuffer: frame.pixelBuffer, pts: pts, maxScale: maxScale, hasTimeRemaining: hasTimeRemaining
            )
        case .metalFXSpatial:
            let detail = targetDimensions.map { ($0.width << 16) | ($0.height & 0xFFFF) }
                ?? Int((maxScale * 100).rounded())
            metalFXWarmRaster = SessionClock(
                width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
                detail: detail, pts: 0
            )
            return await metalFXSuperRes.upscale(
                pixelBuffer: frame.pixelBuffer, maxScale: maxScale,
                targetDimensions: targetDimensions,
                sharpness: configuration.superResolutionSharpness
            )
        }
    }
}
