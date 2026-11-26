import CoreMedia
import CoreVideo
import Foundation
import os

private struct VideoFrameEnhancementJob: Sendable {
    let current: PostProcessFrameBox
    let previous: PostProcessFrameBox
    let configuration: VideoEnhancementConfiguration
    let resolvedInterpolationBackend: VideoFrameInterpolationBackend
    let interpolationLabel: String
    let interpolationPlan: VideoFrameInterpolationPlan?
    let playbackRate: Double
    let deadlines: VideoEnhancementDeadlines
    let upscalingBypassReason: String?
    let superResolutionCap: Float
    let superResolutionTargetDimensions: VideoSuperResolutionDimensions?

    var isUpscaling: Bool { configuration.superResolutionMode != .off && upscalingBypassReason == nil }
}

private struct VideoFrameWarmJob: Sendable {
    let frame: PostProcessFrameBox
    let configuration: VideoEnhancementConfiguration
    let resolvedInterpolationBackend: VideoFrameInterpolationBackend
    let superResolutionCap: Float
    let superResolutionTargetDimensions: VideoSuperResolutionDimensions?
    let interpolationPreviousPTS: TimeInterval?
    let interpolationCurrentPTS: TimeInterval?
    let interpolationPlan: VideoFrameInterpolationPlan?

    var isUpscaling: Bool {
        configuration.superResolutionMode != .off
            && (superResolutionTargetDimensions != nil || superResolutionCap > 0)
    }
}

private enum WorkerCommand: Sendable {
    case prewarm(
        job: VideoFrameWarmJob,
        isAlive: @Sendable () -> Bool,
        complete: @Sendable (Bool) async -> Void
    )
    case process(
        job: VideoFrameEnhancementJob,
        isAlive: @Sendable () -> Bool,
        publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void,
        complete: @Sendable (VideoFrameEnhancementResult) async -> Void
    )
    case retireInterpolationBackend(VideoFrameInterpolationBackend)
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
            case let .prewarm(job, isAlive, complete):
                let completed = await pipeline.prewarm(job, isAlive: isAlive)
                await complete(completed)
            case let .process(job, isAlive, publishMidpoints, complete):
                let result = await pipeline.process(
                    job,
                    isAlive: isAlive,
                    publishMidpoints: publishMidpoints
                )
                await complete(result)
            case let .retireInterpolationBackend(backend):
                pipeline.retireInterpolationBackend(backend)
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
    private struct WarmKey: Equatable, Sendable {
        let superResolutionMode: VideoSuperResolutionMode
        let superResolutionScale: VideoSuperResolutionScale
        let superResolutionTargetResolution: VideoSuperResolutionTargetResolution
        let limitToScreenResolution: Bool
        let frameInterpolationEnabled: Bool
        let resolvedFrameInterpolationBackend: VideoFrameInterpolationBackend
        let interpolationRate: VideoInterpolationRate
        let maxInputResolution: VideoEnhancementMaxInputResolution
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let roundedPlaybackRate: Int
    }

    private let workerChannel = OSAllocatedUnfairLock(initialState: WorkerChannelState())
    private var nextJobID: UInt64 = 0
    private var inFlightJobID: UInt64?
    private(set) var isWarming = false
    private var warmedKey: WarmKey?
    private var idleCallback: (@MainActor () -> Void)?
    private var cadenceEstimator = VideoFrameCadenceEstimator()
    private var interpolationGridNextPTS: TimeInterval?
    /// Stream-scoped runtime fallback to `.visionOpticalFlow` when `.auto` picks `.videoToolbox`
    /// on iOS 26+ and `VTFrameProcessor` rejects the current stream's format/resolution/ratio.
    private var autoRuntimeFallbackBackend: VideoFrameInterpolationBackend?
    private var suppressConfigurationDidSet = false

    var configuration = VideoEnhancementConfiguration.disabled {
        didSet {
            guard !suppressConfigurationDidSet else { return }
            let change = configuration.changeKind(from: oldValue)
            guard change != .unchanged else { return }
            applyConfigurationChange(change)
        }
    }

    @discardableResult
    func updateConfiguration(
        _ newConfiguration: VideoEnhancementConfiguration
    ) -> VideoEnhancementConfigurationChange {
        let oldValue = configuration
        let change = newConfiguration.changeKind(from: oldValue)
        guard change != .unchanged else { return .unchanged }
        suppressConfigurationDidSet = true
        configuration = newConfiguration
        suppressConfigurationDidSet = false
        if newConfiguration.isForceInterpolationActive != oldValue.isForceInterpolationActive {
            warmedKey = nil
            telemetryWindow.reset()
            if newConfiguration.isForceInterpolationActive, frameTelemetry.bypassReason != nil {
                frameTelemetry.bypassReason = nil
            }
        }
        applyConfigurationChange(change)
        return change
    }

    private func applyConfigurationChange(_ change: VideoEnhancementConfigurationChange) {
        switch change {
        case .unchanged, .shaderUniformOnly, .interpolationBackendAliasOnly:
            return
        case let .interpolationBackendHotSwap(outgoing, _):
            // Live hot-swap: keep cadence history, MetalFX SR state, and active playback intact;
            // reset only the interpolation grid/warm/window state and retire the outgoing backend.
            autoRuntimeFallbackBackend = nil
            warmedKey = nil
            interpolationGridNextPTS = nil
            telemetryWindow.reset()
            if !frameTelemetry.isActive {
                frameTelemetry = VideoEnhancementTelemetry(
                    activeFrameInterpolationBackendLabel: activeFrameInterpolationBackendLabel
                )
            } else {
                frameTelemetry.activeFrameInterpolationBackendLabel = activeFrameInterpolationBackendLabel
            }
            let continuation = workerChannel.withLock { $0.continuation }
            continuation?.yield(.retireInterpolationBackend(outgoing))
        case .fullPipelineReset:
            autoRuntimeFallbackBackend = nil
            warmedKey = nil
            if !configuration.isRequested || configuration.isLiveStream {
                VideoEnhancementPoolLimits.reset()
            }
            pendingExpectation = nil
            telemetryWindow.reset()
            cadenceEstimator.reset()
            interpolationGridNextPTS = nil
            var resetTelemetry: VideoEnhancementTelemetry = configuration.isRequested && configuration.isLiveStream
                ? .bypassed(reason: "VOD only") : VideoEnhancementTelemetry()
            resetTelemetry.activeFrameInterpolationBackendLabel = configuration.frameInterpolationEnabled
                ? activeFrameInterpolationBackendLabel
                : nil
            frameTelemetry = resetTelemetry
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
        value.activeFrameInterpolationBackendLabel = configuration.frameInterpolationEnabled
            ? activeFrameInterpolationBackendLabel
            : nil
        return value
    }

    var isBusy: Bool { inFlightJobID != nil }

    /// Set by the renderer on layout / scale-mode changes.
    var displaySurface: VideoEnhancementDisplaySurface?

    /// Steady presentation lookahead requested when video enhancement is active.
    var preferredPresentLeadSeconds: TimeInterval { VideoEnhancementPoolLimits.currentLead }

    /// Concrete runtime interpolation backend resolved for the current configuration and device
    /// (honoring stream-scoped `.auto` fallback from `VT System` to `Vision Flow` when VT rejects a stream).
    var resolvedFrameInterpolationBackend: VideoFrameInterpolationBackend {
        if configuration.frameInterpolationBackend == .auto,
           let autoRuntimeFallbackBackend {
            return autoRuntimeFallbackBackend
        }
        return configuration.resolvedFrameInterpolationBackend
    }

    /// Runtime display label for the active/resolved interpolation backend (`"VT System"` vs `"Vision Flow"`).
    var activeFrameInterpolationBackendLabel: String {
        resolvedFrameInterpolationBackend.telemetryLabel
    }

    var interpolationLabel: String {
        activeFrameInterpolationBackendLabel
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
            VideoEnhancementPoolLimits.reset()
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

        var resolvedBackend = resolvedFrameInterpolationBackend
        var supportsArbitraryPhases = VideoFrameInterpolationPlan.supportsArbitraryPhases(for: resolvedBackend)
        if configuration.frameInterpolationEnabled {
            if let reason = interpolationInputBypassReason(frame, backend: resolvedBackend) {
                fiStreamBypass = reason
            } else if let estimatedInterval = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration) {
                if let reason = VideoFrameInterpolationPlan.streamEligibilityBypassReason(
                    sourceInterval: estimatedInterval,
                    rate: configuration.interpolationRate,
                    playbackRate: playbackRate,
                    supportsArbitraryPhases: supportsArbitraryPhases
                ) {
                    // Under `.auto` on iOS 26+, if dyadic VT LLFI rejects a non-dyadic cadence ratio
                    // (e.g. 50fps -> 60fps), fall back automatically to arbitrary-phase Vision Flow.
                    if configuration.frameInterpolationBackend == .auto,
                       resolvedBackend == .videoToolbox,
                       reason == "Interpolation ratio unsupported",
                       interpolationInputBypassReason(frame, backend: .visionOpticalFlow) == nil,
                       VideoFrameInterpolationPlan.streamEligibilityBypassReason(
                           sourceInterval: estimatedInterval,
                           rate: configuration.interpolationRate,
                           playbackRate: playbackRate,
                           supportsArbitraryPhases: true
                       ) == nil {
                        autoRuntimeFallbackBackend = .visionOpticalFlow
                        resolvedBackend = .visionOpticalFlow
                        supportsArbitraryPhases = true
                        fiStreamEligible = true
                        activeOriginalDuration = computeActiveOutputFrameDuration(
                            for: frame,
                            estimatedInterval: estimatedInterval,
                            playbackRate: playbackRate,
                            supportsArbitraryPhases: true
                        )
                    } else {
                        fiStreamBypass = reason
                    }
                } else {
                    fiStreamEligible = true
                    activeOriginalDuration = computeActiveOutputFrameDuration(
                        for: frame,
                        estimatedInterval: estimatedInterval,
                        playbackRate: playbackRate,
                        supportsArbitraryPhases: supportsArbitraryPhases
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

        let estimatedCadence = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration)

        guard let previous else {
            updatePoolLimits(
                cadenceInterval: estimatedCadence,
                playbackRate: playbackRate,
                committedPlan: nil
            )
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

        updatePoolLimits(
            cadenceInterval: estimatedCadence,
            playbackRate: playbackRate,
            committedPlan: pairPlan
        )

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
        let resolvedBackend = resolvedFrameInterpolationBackend
        if let reason = VideoFramePairFormat.interpolationBypassReason(previous.pixelBuffer) {
            return .bypass(reason)
        }
        if let reason = interpolationInputBypassReason(previous, backend: resolvedBackend) {
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
        if resolvedBackend == .visionOpticalFlow,
           !VisionFrameInterpolationBackend.acceptsPairDelta(timing.delta) {
            return .bypass("Vision FI > 60fps pair")
        }
        return VideoFrameInterpolationPlan.plan(
            previousPTS: previous.pts,
            currentPTS: current.pts,
            interval: timing.delta,
            cadenceInterval: cadence,
            isCadenceStable: cadenceEstimator.isConstantRate,
            gridNextPTS: interpolationGridNextPTS,
            rate: configuration.interpolationRate,
            playbackRate: playbackRate,
            supportsArbitraryPhases: VideoFrameInterpolationPlan.supportsArbitraryPhases(for: resolvedBackend)
        )
    }

    private func computeActiveOutputFrameDuration(
        for frame: MediaVideoFrame,
        estimatedInterval: TimeInterval,
        playbackRate: Double,
        supportsArbitraryPhases: Bool
    ) -> TimeInterval? {
        let referenceDuration = (frame.duration.isFinite && frame.duration > 0)
            ? frame.duration
            : estimatedInterval
        guard referenceDuration.isFinite, referenceDuration > 0 else { return nil }
        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        let outputDuration: TimeInterval
        if let targetFPS = configuration.interpolationRate.targetFPS {
            let cap = Double(targetFPS)
            let targetPeriod = 1.0 / cap
            let wallCadence = estimatedInterval / speed
            let allowedMultipliers = supportsArbitraryPhases
                ? VideoFrameInterpolationPlan.fullMultipliers
                : VideoFrameInterpolationPlan.dyadicMultipliers
            let ratio = cap * wallCadence
            if interpolationGridNextPTS == nil, cadenceEstimator.isConstantRate,
               let exactMultiplier = allowedMultipliers.first(where: { multiplier in
                   let target = Double(multiplier)
                   return abs(ratio - target) / target <= VideoFrameInterpolationPlan.exactIntegerTolerance
               }) {
                outputDuration = estimatedInterval / Double(exactMultiplier)
            } else if supportsArbitraryPhases {
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
        guard outputDuration.isFinite, outputDuration > 0, outputDuration < referenceDuration else {
            return nil
        }
        return outputDuration
    }

    private func interpolationInputBypassReason(
        _ frame: MediaVideoFrame,
        backend: VideoFrameInterpolationBackend
    ) -> String? {
        if let reason = VideoFramePairFormat.interpolationBypassReason(frame.pixelBuffer) { return reason }
        switch backend.resolved() {
        case .videoToolbox:
            return nil
        case .visionOpticalFlow, .auto:
            return VisionFrameInterpolationBackend.inputBypassReason(
                frame,
                maxInputResolution: configuration.maxInputResolution,
                cadenceInterval: cadenceEstimator.medianInterval
            )
        }
    }

    // MARK: - Telemetry & Continuity

    func noteBypass(_ reason: String) {
        var telemetry = VideoEnhancementTelemetry.bypassed(reason: reason)
        telemetry.activeFrameInterpolationBackendLabel = configuration.frameInterpolationEnabled
            ? activeFrameInterpolationBackendLabel
            : nil
        frameTelemetry = telemetry
    }

    /// Seek / stream switch / renderer reset.
    func noteDiscontinuity() {
        autoRuntimeFallbackBackend = nil
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
            inputFPS: sourceFPS,
            outputFPS: outputFPS,
            isActive: true,
            activeFrameInterpolationBackendLabel: configuration.frameInterpolationEnabled
                ? activeFrameInterpolationBackendLabel
                : nil
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
        let jobInterpolationLabel = result.resolvedInterpolationBackend?.telemetryLabel ?? interpolationLabel
        let hasMidpoints = midpointCount > 0
        switch (srActive, hasMidpoints) {
        case (true, true):
            displayed.activeModeLabel =
                "\(configuration.superResolutionMode.telemetryLabel) + \(jobInterpolationLabel)"
        case (true, false):
            displayed.activeModeLabel = configuration.superResolutionMode.telemetryLabel
        case (false, true):
            displayed.activeModeLabel = jobInterpolationLabel
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
        displayed.activeFrameInterpolationBackendLabel = configuration.frameInterpolationEnabled
            ? activeFrameInterpolationBackendLabel
            : nil
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

        updatePoolLimits(
            cadenceInterval: cadenceEstimator.estimatedInterval(fallbackDuration: original.duration),
            playbackRate: playbackRate,
            committedPlan: committedPlan
        )

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
        // Adopt runtime `.auto` VT -> Vision fallback before checking transition-framebackend mismatch.
        if let result,
           configuration.frameInterpolationEnabled,
           configuration.frameInterpolationBackend == .auto,
           result.resolvedInterpolationBackend == .visionOpticalFlow,
           autoRuntimeFallbackBackend != .visionOpticalFlow {
            autoRuntimeFallbackBackend = .visionOpticalFlow
            warmedKey = nil
            frameTelemetry.activeFrameInterpolationBackendLabel = activeFrameInterpolationBackendLabel
        }
        // Skip recording a single in-flight transition frame from an outgoing backend after a live
        // backend hot-swap so the rolling telemetry window reflects only the incoming backend.
        if let result,
           configuration.frameInterpolationEnabled,
           let jobBackend = result.resolvedInterpolationBackend,
           jobBackend != resolvedFrameInterpolationBackend {
            return
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

    // MARK: - Pool Limits & Worker Idle Notifications

    private func updatePoolLimits(
        cadenceInterval: TimeInterval?,
        playbackRate: Double,
        committedPlan: VideoFrameInterpolationPlan?
    ) {
        guard configuration.isRequested, !configuration.isLiveStream else {
            VideoEnhancementPoolLimits.reset()
            return
        }
        guard let cadenceInterval, cadenceInterval.isFinite, cadenceInterval > 0 else { return }
        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        let sourceFPS = (1.0 / cadenceInterval) * speed
        guard sourceFPS.isFinite, sourceFPS > 0 else { return }

        let outputFPS: Double
        let maxPhasesPerPair: Int
        if let plan = committedPlan {
            outputFPS = max(sourceFPS, plan.targetOutputFPS)
            let ratio = outputFPS / sourceFPS
            let estimatedPhases = max(plan.phases.count, Int(ceil(ratio)) - 1)
            maxPhasesPerPair = max(0, min(estimatedPhases, VideoFrameInterpolationPlan.maximumPhasesPerPair))
        } else if configuration.frameInterpolationEnabled {
            if let targetFPS = configuration.interpolationRate.targetFPS {
                outputFPS = max(sourceFPS, Double(targetFPS))
            } else {
                outputFPS = sourceFPS * 2.0
            }
            let ratio = outputFPS / sourceFPS
            maxPhasesPerPair = ratio > 1.05
                ? max(1, min(Int(ceil(ratio)) - 1, VideoFrameInterpolationPlan.maximumPhasesPerPair))
                : 0
        } else {
            outputFPS = sourceFPS
            maxPhasesPerPair = 0
        }

        VideoEnhancementPoolLimits.configure(
            sourceFPS: sourceFPS,
            outputFPS: outputFPS,
            maxPhasesPerPair: maxPhasesPerPair,
            underMemoryPressure: VideoEnhancementGuardrails.isUnderMemoryPressure,
            forceFrameInterpolation: configuration.isForceInterpolationActive
        )
    }

    func notifyWhenIdle(_ callback: @escaping @MainActor () -> Void) {
        guard isBusy else {
            callback()
            return
        }
        idleCallback = callback
    }

    func clearIdleCallback() {
        idleCallback = nil
    }

    private func notifyIdleIfNeeded() {
        guard !isBusy, let callback = idleCallback else { return }
        idleCallback = nil
        callback()
    }

    // MARK: - Persistent Worker Submission & Lifecycle

    private func ensureWorkerChannel() -> (
        generation: UInt64,
        continuation: AsyncStream<WorkerCommand>.Continuation
    ) {
        let (generation, continuation, newStream): (
            UInt64,
            AsyncStream<WorkerCommand>.Continuation,
            AsyncStream<WorkerCommand>?
        ) = workerChannel.withLock { state in
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
        return (generation, continuation)
    }

    /// Lightweight non-blocking session prewarm triggered when the initial reference frame is
    /// accepted, so VideoToolbox / MetalFX / Vision cold-start model load finishes before Frame 1
    /// exhausts its presentation runway.
    func prewarmIfNeeded(with frame: MediaVideoFrame, playbackRate: Double = 1.0) {
        guard inFlightJobID == nil,
              configuration.isRequested,
              !configuration.isLiveStream,
              ExperimentalSettingsPolicy.videoEnhancementEnabled else {
            return
        }
        guard VideoEnhancementGuardrails.commonBypassReason(
            configuration: configuration,
            pixelBuffer: frame.pixelBuffer
        ) == nil else {
            return
        }

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let speed = VideoFrameInterpolationPlan.normalizedPlaybackRate(playbackRate)
        let resolvedBackend = resolvedFrameInterpolationBackend
        let key = WarmKey(
            superResolutionMode: configuration.superResolutionMode,
            superResolutionScale: configuration.superResolutionScale,
            superResolutionTargetResolution: configuration.superResolutionTargetResolution,
            limitToScreenResolution: configuration.limitToScreenResolution,
            frameInterpolationEnabled: configuration.frameInterpolationEnabled,
            resolvedFrameInterpolationBackend: resolvedBackend,
            interpolationRate: configuration.interpolationRate,
            maxInputResolution: configuration.maxInputResolution,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            roundedPlaybackRate: Int((speed * 100).rounded())
        )
        guard key != warmedKey else { return }

        let srPlan = resolveSuperResolutionPlan(for: frame).resolved
        let estimatedCadence = cadenceEstimator.estimatedInterval(fallbackDuration: frame.duration)
        let fiWarmPlan: (previousPTS: TimeInterval, currentPTS: TimeInterval, plan: VideoFrameInterpolationPlan)?
        if configuration.frameInterpolationEnabled,
           interpolationInputBypassReason(frame, backend: resolvedBackend) == nil {
            fiWarmPlan = VideoFrameInterpolationPlan.prewarmPlan(
                for: frame,
                cadenceInterval: estimatedCadence,
                rate: configuration.interpolationRate,
                playbackRate: speed,
                supportsArbitraryPhases: VideoFrameInterpolationPlan.supportsArbitraryPhases(for: resolvedBackend)
            )
        } else {
            fiWarmPlan = nil
        }

        warmedKey = key
        guard srPlan != nil || fiWarmPlan != nil else { return }

        updatePoolLimits(
            cadenceInterval: estimatedCadence,
            playbackRate: speed,
            committedPlan: fiWarmPlan?.plan
        )

        nextJobID &+= 1
        let jobID = nextJobID
        inFlightJobID = jobID
        isWarming = true

        let warmJob = VideoFrameWarmJob(
            frame: PostProcessFrameBox(frame: frame),
            configuration: configuration,
            resolvedInterpolationBackend: resolvedBackend,
            superResolutionCap: srPlan?.scaleCap ?? 0,
            superResolutionTargetDimensions: srPlan?.targetDimensions,
            interpolationPreviousPTS: fiWarmPlan?.previousPTS,
            interpolationCurrentPTS: fiWarmPlan?.currentPTS,
            interpolationPlan: fiWarmPlan?.plan
        )

        let channel = workerChannel
        let (generation, continuation) = ensureWorkerChannel()
        let isAlive: @Sendable () -> Bool = {
            channel.withLock { $0.generation == generation }
        }
        let complete: @Sendable (Bool) async -> Void = { [weak self] completed in
            await self?.finishPrewarm(jobID: jobID, generation: generation, key: key, completed: completed)
        }
        continuation.yield(.prewarm(job: warmJob, isAlive: isAlive, complete: complete))
    }

    func submit(
        _ frame: MediaVideoFrame,
        previous: MediaVideoFrame,
        admission: VideoEnhancementAdmission,
        playbackRate: Double = 1.0,
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

        let resolvedBackend: VideoFrameInterpolationBackend = if admission.configuration.frameInterpolationBackend == .auto,
                                                                 let autoRuntimeFallbackBackend {
            autoRuntimeFallbackBackend
        } else {
            admission.configuration.resolvedFrameInterpolationBackend
        }
        let job = VideoFrameEnhancementJob(
            current: PostProcessFrameBox(frame: frame),
            previous: PostProcessFrameBox(frame: previous),
            configuration: admission.configuration,
            resolvedInterpolationBackend: resolvedBackend,
            interpolationLabel: resolvedBackend.telemetryLabel,
            interpolationPlan: resolvedPlan,
            playbackRate: playbackRate,
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
        let (generation, continuation) = ensureWorkerChannel()
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
        inFlightJobID = nil
        isWarming = false
        warmedKey = nil
        autoRuntimeFallbackBackend = nil
        pendingExpectation = nil
        telemetryWindow.reset()
        cadenceEstimator.reset()
        interpolationGridNextPTS = nil
        lastProcessingMs = 0
        frameTelemetry = VideoEnhancementTelemetry()
        VideoEnhancementPoolLimits.reset()
        let continuation: AsyncStream<WorkerCommand>.Continuation? = workerChannel.withLock { state in
            state.generation &+= 1
            return state.continuation
        }
        continuation?.yield(.tearDown)
        notifyIdleIfNeeded()
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

    private func finishPrewarm(
        jobID: UInt64,
        generation: UInt64,
        key: WarmKey,
        completed: Bool
    ) {
        _ = generation
        guard inFlightJobID == jobID else { return }
        inFlightJobID = nil
        isWarming = false
        if !completed, warmedKey == key {
            warmedKey = nil
        }
        notifyIdleIfNeeded()
    }

    private func finish(
        _ result: VideoFrameEnhancementResult,
        jobID: UInt64,
        generation: UInt64,
        onUpdate: @MainActor (VideoFrameEnhancementUpdate) -> Void
    ) {
        let becameIdle: Bool
        if inFlightJobID == jobID {
            inFlightJobID = nil
            becameIdle = true
        } else {
            becameIdle = false
        }
        if workerChannel.withLock({ $0.generation == generation }) {
            onUpdate(.finished(result))
        }
        if becameIdle {
            notifyIdleIfNeeded()
        }
    }
}

// MARK: - Single-Consumer Background Pipeline

private final class VideoFramePostProcessorPipeline {
    private let metalFXSuperRes = MetalFXSuperResolutionBackend()
    private let vtFrameInterp = VideoToolboxFrameInterpolationBackend()
    private let visionFrameInterp = VisionFrameInterpolationBackend()
    private var interpolationReference: EnhancementFrameIdentity?
    private var smoothedMs: Double = 0
    private var lastSuperResolutionMode = VideoSuperResolutionMode.off
    private var lastInterpolationEnabled = false
    private var lastResolvedInterpolationBackend: VideoFrameInterpolationBackend?

    private struct InterpolationStage {
        var midpoints: [MediaVideoFrame] = []
        var inputFPS: Double
        var bypassReason: String?
        var srBypassReason: String?
        var midpointsUpscaled = false
        var actualBackend: VideoFrameInterpolationBackend?
    }

    private func releaseIdleBackends(
        for configuration: VideoEnhancementConfiguration,
        resolvedInterpolationBackend: VideoFrameInterpolationBackend
    ) {
        let mode = configuration.superResolutionMode
        if mode != lastSuperResolutionMode {
            if lastSuperResolutionMode == .metalFXSpatial {
                metalFXSuperRes.tearDown()
            }
            lastSuperResolutionMode = mode
        }
        if !configuration.frameInterpolationEnabled {
            if lastInterpolationEnabled {
                vtFrameInterp.tearDown()
                visionFrameInterp.tearDown()
                interpolationReference = nil
            }
            lastResolvedInterpolationBackend = nil
        } else if let previousBackend = lastResolvedInterpolationBackend,
                  previousBackend != resolvedInterpolationBackend {
            retireInterpolationBackend(previousBackend)
            lastResolvedInterpolationBackend = resolvedInterpolationBackend
        } else {
            lastResolvedInterpolationBackend = resolvedInterpolationBackend
        }
        lastInterpolationEnabled = configuration.frameInterpolationEnabled
    }

    func retireInterpolationBackend(_ backend: VideoFrameInterpolationBackend) {
        switch backend.resolved() {
        case .videoToolbox:
            vtFrameInterp.tearDown()
        case .visionOpticalFlow, .auto:
            visionFrameInterp.tearDown()
        }
        if lastResolvedInterpolationBackend == backend.resolved() {
            lastResolvedInterpolationBackend = nil
        }
        interpolationReference = nil
    }

    func flush() {
        metalFXSuperRes.flush()
        resetInterpolation()
        smoothedMs = 0
    }

    func tearDown() {
        metalFXSuperRes.tearDown()
        vtFrameInterp.tearDown()
        visionFrameInterp.tearDown()
        interpolationReference = nil
        smoothedMs = 0
        lastSuperResolutionMode = .off
        lastInterpolationEnabled = false
        lastResolvedInterpolationBackend = nil
    }

    func prewarm(
        _ job: VideoFrameWarmJob,
        isAlive: @escaping @Sendable () -> Bool
    ) async -> Bool {
        guard isAlive() else { return false }
        releaseIdleBackends(
            for: job.configuration,
            resolvedInterpolationBackend: job.resolvedInterpolationBackend
        )
        let frame = job.frame.frame

        if job.isUpscaling {
            switch job.configuration.superResolutionMode {
            case .off:
                break
            case .metalFXSpatial:
                metalFXSuperRes.prewarm(
                    pixelBuffer: frame.pixelBuffer,
                    maxScale: job.superResolutionCap,
                    targetDimensions: job.superResolutionTargetDimensions
                )
            }
        }

        guard isAlive() else { return false }

        if let plan = job.interpolationPlan,
           let prevPTS = job.interpolationPreviousPTS,
           let currPTS = job.interpolationCurrentPTS {
            if job.resolvedInterpolationBackend == .visionOpticalFlow {
                // Lightweight <1 ms GPU analysis buffer prewarm that seeds Frame 0 directly as reference
                // without locking the worker on a throwaway Vision request.
                if await visionFrameInterp.prewarm(
                    frame,
                    maxInputResolution: job.configuration.maxInputResolution,
                    superResolutionActive: job.isUpscaling,
                    forceInterpolation: job.configuration.isForceInterpolationActive
                ) {
                    interpolationReference = EnhancementFrameIdentity(frame)
                }
            } else {
                resetInterpolation(for: job.resolvedInterpolationBackend)
                let warmPrev = MediaVideoFrame(
                    pts: prevPTS,
                    duration: plan.sourceInterval,
                    pixelBuffer: frame.pixelBuffer
                )
                let warmCurr = MediaVideoFrame(
                    pts: currPTS,
                    duration: plan.sourceInterval,
                    pixelBuffer: frame.pixelBuffer
                )
                _ = await interpolate(
                    warmPrev,
                    plan: nil,
                    backend: job.resolvedInterpolationBackend,
                    maxInputResolution: job.configuration.maxInputResolution,
                    superResolutionActive: job.isUpscaling,
                    forceInterpolation: job.configuration.isForceInterpolationActive,
                    playbackRate: 1.0,
                    hasTimeRemaining: isAlive
                )
                if isAlive() {
                    _ = await interpolate(
                        warmCurr,
                        plan: plan,
                        backend: job.resolvedInterpolationBackend,
                        maxInputResolution: job.configuration.maxInputResolution,
                        superResolutionActive: job.isUpscaling,
                        forceInterpolation: job.configuration.isForceInterpolationActive,
                        playbackRate: 1.0,
                        hasTimeRemaining: isAlive
                    )
                }
                resetInterpolation(for: job.resolvedInterpolationBackend)
            }
        }

        return isAlive()
    }

    func process(
        _ job: VideoFrameEnhancementJob,
        isAlive: @escaping @Sendable () -> Bool,
        publishMidpoints: @Sendable ([PostProcessFrameBox]) async -> Void
    ) async -> VideoFrameEnhancementResult {
        _ = publishMidpoints
        let start = ContinuousClock.now
        releaseIdleBackends(
            for: job.configuration,
            resolvedInterpolationBackend: job.resolvedInterpolationBackend
        )
        let frame = job.current.frame
        let previous = job.previous.frame
        let nominalFPS = VideoFrameInterpolationTiming.sourceFPS(frame) ?? 0

        guard isAlive() else {
            return makeResult(job, interpolation: InterpolationStage(inputFPS: nominalFPS), original: nil)
        }

        let previousIdentity = EnhancementFrameIdentity(previous)
        let formatMatches = VideoFramePairFormat.matches(previous.pixelBuffer, frame.pixelBuffer)
        if !formatMatches, interpolationReference != nil {
            resetInterpolation(for: job.resolvedInterpolationBackend)
        }

        // Stage 1: Frame interpolation (raw synthesized midpoints in strictly ascending PTS order).
        var interpolation = await interpolateRaw(job, previousIdentity: previousIdentity, isAlive: isAlive)
        let shouldUpscaleOriginal = job.isUpscaling
            && ((job.interpolationPlan?.emitsOriginal ?? true) || interpolation.midpoints.isEmpty)

        // Stage 2: Super resolution (MetalFX Spatial + RCAS batches midpoints + original into one GPU submission).
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
        let nominalFPS = VideoFrameInterpolationTiming.sourceFPS(frame) ?? (job.interpolationPlan?.sourceFPS ?? 0)
        var stage = InterpolationStage(inputFPS: nominalFPS, actualBackend: job.resolvedInterpolationBackend)
        guard let deadline = job.deadlines.midpoint, let plan = job.interpolationPlan else {
            if interpolationReference != nil {
                resetInterpolation(for: job.resolvedInterpolationBackend)
            }
            return stage
        }
        let hasTimeRemaining: @Sendable () -> Bool = { isAlive() && .now < deadline }
        var activeBackend = job.resolvedInterpolationBackend
        let canAutoFallbackToVision = job.configuration.frameInterpolationBackend == .auto
            && activeBackend == .videoToolbox
        let forceFI = job.configuration.isForceInterpolationActive

        if interpolationReference != previousIdentity, hasTimeRemaining() {
            resetInterpolation(for: activeBackend)
            switch await interpolate(
                job.previous.frame,
                plan: nil,
                backend: activeBackend,
                maxInputResolution: job.configuration.maxInputResolution,
                superResolutionActive: job.isUpscaling,
                forceInterpolation: forceFI,
                playbackRate: job.playbackRate,
                hasTimeRemaining: hasTimeRemaining
            ) {
            case .passthrough, .interpolated:
                interpolationReference = previousIdentity
            case let .bypassed(reason):
                if canAutoFallbackToVision,
                   !Self.preservesInterpolationReference(forBypassReason: reason),
                   hasTimeRemaining() {
                    vtFrameInterp.tearDown()
                    activeBackend = .visionOpticalFlow
                    stage.actualBackend = .visionOpticalFlow
                    lastResolvedInterpolationBackend = .visionOpticalFlow
                    resetInterpolation(for: .visionOpticalFlow)
                    switch await interpolate(
                        job.previous.frame,
                        plan: nil,
                        backend: .visionOpticalFlow,
                        maxInputResolution: job.configuration.maxInputResolution,
                        superResolutionActive: job.isUpscaling,
                        forceInterpolation: forceFI,
                        playbackRate: job.playbackRate,
                        hasTimeRemaining: hasTimeRemaining
                    ) {
                    case .passthrough, .interpolated:
                        interpolationReference = previousIdentity
                    case let .bypassed(visionReason):
                        stage.bypassReason = visionReason
                        resetInterpolation(for: .visionOpticalFlow)
                        return stage
                    }
                } else {
                    stage.bypassReason = reason
                    resetInterpolation(for: activeBackend)
                    return stage
                }
            }
        }
        guard hasTimeRemaining() else {
            stage.bypassReason = "Interpolation deadline"
            return stage
        }
        switch await interpolate(
            frame,
            plan: plan,
            backend: activeBackend,
            maxInputResolution: job.configuration.maxInputResolution,
            superResolutionActive: job.isUpscaling,
            forceInterpolation: forceFI,
            playbackRate: job.playbackRate,
            hasTimeRemaining: hasTimeRemaining
        ) {
        case let .interpolated(frames):
            stage.inputFPS = plan.sourceFPS
            stage.midpoints = frames
            stage.actualBackend = activeBackend
            interpolationReference = EnhancementFrameIdentity(frame)
        case .passthrough:
            stage.actualBackend = activeBackend
            interpolationReference = EnhancementFrameIdentity(frame)
        case let .bypassed(reason):
            if canAutoFallbackToVision,
               activeBackend == .videoToolbox,
               !Self.preservesInterpolationReference(forBypassReason: reason),
               hasTimeRemaining() {
                vtFrameInterp.tearDown()
                activeBackend = .visionOpticalFlow
                stage.actualBackend = .visionOpticalFlow
                lastResolvedInterpolationBackend = .visionOpticalFlow
                resetInterpolation(for: .visionOpticalFlow)
                _ = await interpolate(
                    job.previous.frame,
                    plan: nil,
                    backend: .visionOpticalFlow,
                    maxInputResolution: job.configuration.maxInputResolution,
                    superResolutionActive: job.isUpscaling,
                    forceInterpolation: forceFI,
                    playbackRate: job.playbackRate,
                    hasTimeRemaining: hasTimeRemaining
                )
                if hasTimeRemaining(),
                   case let .interpolated(visionFrames) = await interpolate(
                       frame,
                       plan: plan,
                       backend: .visionOpticalFlow,
                       maxInputResolution: job.configuration.maxInputResolution,
                       superResolutionActive: job.isUpscaling,
                       forceInterpolation: forceFI,
                       playbackRate: job.playbackRate,
                       hasTimeRemaining: hasTimeRemaining
                   ) {
                    stage.inputFPS = plan.sourceFPS
                    stage.midpoints = visionFrames
                    stage.bypassReason = nil
                    interpolationReference = EnhancementFrameIdentity(frame)
                    return stage
                }
            }
            stage.bypassReason = reason
            if Self.preservesInterpolationReference(forBypassReason: reason) {
                interpolationReference = EnhancementFrameIdentity(frame)
            } else {
                resetInterpolation(for: activeBackend)
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
        let splitCompare = job.configuration.superResolutionSplitCompare

        if !interpolation.midpoints.isEmpty, hasMidpointTime {
            if shouldUpscaleOriginal {
                var buffers = interpolation.midpoints.map(\.pixelBuffer)
                buffers.append(frame.pixelBuffer)
                let outcomes = await metalFXSuperRes.upscaleBatch(
                    pixelBuffers: buffers,
                    maxScale: job.superResolutionCap,
                    targetDimensions: job.superResolutionTargetDimensions,
                    sharpness: job.configuration.superResolutionSharpness,
                    splitCompare: splitCompare
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
                    sharpness: job.configuration.superResolutionSharpness,
                    splitCompare: splitCompare
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
            sharpness: job.configuration.superResolutionSharpness,
            splitCompare: splitCompare
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

        let effectiveBackend = interpolation.actualBackend ?? job.resolvedInterpolationBackend
        let effectiveInterpolationLabel = effectiveBackend.telemetryLabel
        let srActive = enhancedOriginal != nil || interpolation.midpointsUpscaled
        let hasMidpoints = !interpolation.midpoints.isEmpty
        let isActive = srActive || hasMidpoints
        let activeModeLabel: String
        switch (srActive, hasMidpoints) {
        case (true, true):
            activeModeLabel = "\(job.configuration.superResolutionMode.telemetryLabel) + \(effectiveInterpolationLabel)"
        case (true, false):
            activeModeLabel = job.configuration.superResolutionMode.telemetryLabel
        case (false, true):
            activeModeLabel = effectiveInterpolationLabel
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
            isActive: isActive,
            activeFrameInterpolationBackendLabel: job.configuration.frameInterpolationEnabled
                ? effectiveInterpolationLabel
                : nil
        )
        return VideoFrameEnhancementResult(
            midpoints: interpolation.midpoints.map(PostProcessFrameBox.init),
            enhancedOriginal: enhancedOriginal.map(PostProcessFrameBox.init),
            telemetry: telemetry,
            interpolationBypassReason: interpolation.bypassReason,
            originalSuperResolutionBypassReason: srBypass,
            midpointsUpscaled: interpolation.midpointsUpscaled,
            resolvedInterpolationBackend: job.configuration.frameInterpolationEnabled
                ? effectiveBackend
                : nil
        )
    }

    private func resetInterpolation() {
        vtFrameInterp.flush()
        visionFrameInterp.flush()
        interpolationReference = nil
    }

    private func resetInterpolation(for backend: VideoFrameInterpolationBackend) {
        switch backend.resolved() {
        case .videoToolbox:
            vtFrameInterp.flush()
        case .visionOpticalFlow, .auto:
            visionFrameInterp.flush()
        }
        interpolationReference = nil
    }

    private func interpolate(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        backend: VideoFrameInterpolationBackend,
        maxInputResolution: VideoEnhancementMaxInputResolution,
        superResolutionActive: Bool,
        forceInterpolation: Bool,
        playbackRate: Double,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        switch backend.resolved() {
        case .videoToolbox:
            if #available(iOS 26.0, *) {
                return await vtFrameInterp.process(frame, plan: plan, hasTimeRemaining: hasTimeRemaining)
            }
            return await visionFrameInterp.process(
                frame,
                plan: plan,
                maxInputResolution: maxInputResolution,
                superResolutionActive: superResolutionActive,
                forceInterpolation: forceInterpolation,
                playbackRate: playbackRate,
                hasTimeRemaining: hasTimeRemaining
            )
        case .visionOpticalFlow, .auto:
            return await visionFrameInterp.process(
                frame,
                plan: plan,
                maxInputResolution: maxInputResolution,
                superResolutionActive: superResolutionActive,
                forceInterpolation: forceInterpolation,
                playbackRate: playbackRate,
                hasTimeRemaining: hasTimeRemaining
            )
        }
    }
}
