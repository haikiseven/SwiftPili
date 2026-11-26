import CoreImage
import CoreVideo
import Foundation
import os
import Vision

/// Hysteresis-based quality scaler that smoothly trades `VNGenerateOpticalFlowRequest` (`Revision 1`)
/// accuracy (`.medium` ↔ `.low`) and analysis resolution (`480p` ↔ `360p`) against pair deadlines,
/// SR load, and `.fair` thermal headroom — or locks unconditionally to `.ultra` (`540p .medium`)
/// when `forceInterpolation` is enabled.
struct OpticalFlowAdaptiveController: Sendable {
    private(set) var currentProfile: OpticalFlowQualityProfile = .high
    private var slowStreak: Int = 0
    private var fastStreak: Int = 0

    static let slowBudgetFraction: Double = 0.55
    static let fastBudgetFraction: Double = 0.28
    static let slowPairsToStepDown: Int = 2
    static let fastPairsToStepUp: Int = 24

    static func maxAllowedProfile(
        sourceFPS: Double,
        phaseCount: Int,
        superResolutionActive: Bool = false,
        forceInterpolation: Bool = false,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> OpticalFlowQualityProfile {
        if forceInterpolation {
            return .ultra
        }
        if thermalState == .fair || sourceFPS > 40 || phaseCount >= 3 || superResolutionActive {
            return .balanced
        }
        return .high
    }

    func activeProfile(
        sourceFPS: Double,
        phaseCount: Int,
        superResolutionActive: Bool = false,
        forceInterpolation: Bool = false,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> OpticalFlowQualityProfile {
        if forceInterpolation {
            return .ultra
        }
        return min(
            currentProfile,
            Self.maxAllowedProfile(
                sourceFPS: sourceFPS,
                phaseCount: phaseCount,
                superResolutionActive: superResolutionActive,
                forceInterpolation: false,
                thermalState: thermalState
            )
        )
    }

    mutating func recordCompletion(
        elapsedMs: Double,
        pairIntervalSeconds: TimeInterval,
        sourceFPS: Double,
        phaseCount: Int,
        superResolutionActive: Bool = false,
        forceInterpolation: Bool = false,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) {
        if forceInterpolation {
            slowStreak = 0
            fastStreak = 0
            return
        }
        guard elapsedMs.isFinite, elapsedMs >= 0 else { return }
        let maxAllowed = Self.maxAllowedProfile(
            sourceFPS: sourceFPS,
            phaseCount: phaseCount,
            superResolutionActive: superResolutionActive,
            forceInterpolation: false,
            thermalState: thermalState
        )
        let effective = min(currentProfile, maxAllowed)
        let budgetMs = min(50.0, max(8.0, pairIntervalSeconds * 1_000.0))

        if elapsedMs > budgetMs * Self.slowBudgetFraction {
            slowStreak += 1
            fastStreak = 0
            if slowStreak >= Self.slowPairsToStepDown {
                currentProfile = OpticalFlowQualityProfile(rawValue: max(0, effective.rawValue - 1)) ?? .fast
                slowStreak = 0
            }
        } else if elapsedMs < budgetMs * Self.fastBudgetFraction {
            slowStreak = 0
            if effective < maxAllowed {
                fastStreak += 1
                if fastStreak >= Self.fastPairsToStepUp {
                    currentProfile = OpticalFlowQualityProfile(
                        rawValue: min(maxAllowed.rawValue, effective.rawValue + 1)
                    ) ?? maxAllowed
                    fastStreak = 0
                }
            } else {
                fastStreak = 0
            }
        } else {
            slowStreak = 0
            fastStreak = 0
        }
    }

    mutating func recordDeadlineMiss(
        sourceFPS: Double,
        phaseCount: Int,
        superResolutionActive: Bool = false,
        forceInterpolation: Bool = false,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) {
        if forceInterpolation {
            slowStreak = 0
            fastStreak = 0
            return
        }
        let maxAllowed = Self.maxAllowedProfile(
            sourceFPS: sourceFPS,
            phaseCount: phaseCount,
            superResolutionActive: superResolutionActive,
            forceInterpolation: false,
            thermalState: thermalState
        )
        let effective = min(currentProfile, maxAllowed)
        currentProfile = OpticalFlowQualityProfile(rawValue: max(0, effective.rawValue - 1)) ?? .fast
        slowStreak = 0
        fastStreak = 0
    }

    mutating func resetStreaks() {
        slowStreak = 0
        fastStreak = 0
    }

    mutating func reset() {
        currentProfile = .high
        slowStreak = 0
        fastStreak = 0
    }
}

final class VisionFrameInterpolationBackend {
    private var previousFrame: MediaVideoFrame?
    private var resources: VisionInterpolationMetal?
    private var adaptiveController = OpticalFlowAdaptiveController()

    /// Supports progressive 8-bit & 10-bit SDR/HDR sources up to ~60fps (including 24/30→60/120fps and 60→120fps).
    private static let minimumSourceInterval: TimeInterval = 1 / 65.0

    static func inputBypassReason(
        _ frame: MediaVideoFrame,
        maxInputResolution: VideoEnhancementMaxInputResolution = .p1080,
        cadenceInterval: TimeInterval? = nil
    ) -> String? {
        if !VideoEnhancementGuardrails.isWithin(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer),
            limit: maxInputResolution
        ) {
            return "Vision FI \(maxInputResolution.bypassReason.lowercased())"
        }
        guard frame.pts.isFinite else {
            return "Vision FI invalid duration"
        }
        let validCadence = cadenceInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let validDuration = (frame.duration.isFinite && frame.duration > 0) ? frame.duration : nil
        guard let effectiveInterval = validCadence ?? validDuration else {
            return "Vision FI invalid duration"
        }
        guard effectiveInterval + VideoFrameInterpolationTiming.tolerance >= minimumSourceInterval else {
            return "Vision FI source > 60fps or invalid duration"
        }
        return nil
    }

    static func acceptsPairDelta(_ delta: TimeInterval) -> Bool {
        delta + VideoFrameInterpolationTiming.tolerance >= minimumSourceInterval && delta <= 0.25
    }

    func flush() {
        previousFrame = nil
        adaptiveController.resetStreaks()
        resources?.flushTextures()
    }

    func tearDown() {
        previousFrame = nil
        adaptiveController.reset()
        resources?.flushTextures()
        resources = nil
    }

    /// Uses `VNGenerateOpticalFlowRequestRevision1` (Apple's native Metal pyramidal optical flow,
    /// ~4× faster than the fixed-tensor neural `Revision 2` default and scaling linearly with
    /// `360p` / `480p` / `540p` analysis resolution).
    static let visionOpticalFlowRevision: Int = VNGenerateOpticalFlowRequestRevision1

    /// Lightweight initial-frame prewarm: compiles Metal pipelines, allocates pools, and prepares
    /// `frame`'s analysis buffer into cache while seeding `previousFrame = frame` so Frame 1 can
    /// interpolate immediately without a blocking dummy Vision request.
    func prewarm(
        _ frame: MediaVideoFrame,
        maxInputResolution: VideoEnhancementMaxInputResolution = .p1080,
        superResolutionActive: Bool = false,
        forceInterpolation: Bool = false
    ) async -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard VideoEnhancementGuardrails.isWithin(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer),
            limit: maxInputResolution
        ), let format = VisionInterpolationFormat(frame.pixelBuffer) else {
            return false
        }
        do {
            let metal = try metalResources(for: format)
            let profile = adaptiveController.activeProfile(
                sourceFPS: (frame.duration > 0 && frame.duration.isFinite) ? (1.0 / frame.duration) : 30.0,
                phaseCount: 1,
                superResolutionActive: superResolutionActive,
                forceInterpolation: forceInterpolation
            )
            try await metal.prewarmAnalysis(source: frame.pixelBuffer, profile: profile)
            previousFrame = frame
            return true
        } catch {
            return false
        }
        #endif
    }

    func process(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        maxInputResolution: VideoEnhancementMaxInputResolution = .p1080,
        superResolutionActive: Bool = false,
        forceInterpolation: Bool = false,
        playbackRate: Double = 1.0,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        #if targetEnvironment(simulator)
        return .bypassed(reason: "Vision FI device required")
        #else
        if !VideoEnhancementGuardrails.isWithin(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer),
            limit: maxInputResolution
        ) {
            flush()
            return .bypassed(reason: "Vision FI \(maxInputResolution.bypassReason.lowercased())")
        }
        let buffer = frame.pixelBuffer
        guard frame.pts.isFinite, let format = VisionInterpolationFormat(buffer) else {
            flush()
            return .bypassed(reason: "Vision FI input format or timing")
        }
        if let plan,
           let reason = Self.inputBypassReason(
               frame, maxInputResolution: maxInputResolution, cadenceInterval: plan.sourceInterval
           ) {
            flush()
            return .bypassed(reason: reason)
        }
        // Advance `previousFrame` even if this frame misses its deadline so the very next pair
        // can interpolate immediately without waiting an extra frame to rebuild reference state.
        let previous = previousFrame
        previousFrame = frame
        guard !Task.isCancelled else {
            return .bypassed(reason: VisionInterpolationFailure.cancelled.rawValue)
        }
        guard let plan, let previous else { return .passthrough }
        guard !plan.phases.isEmpty else { return .passthrough }
        let speed = (playbackRate.isFinite && playbackRate > 0) ? playbackRate : 1.0
        let wallFPS = plan.sourceFPS * speed
        guard hasTimeRemaining() else {
            adaptiveController.recordDeadlineMiss(
                sourceFPS: wallFPS,
                phaseCount: plan.phases.count,
                superResolutionActive: superResolutionActive,
                forceInterpolation: forceInterpolation
            )
            return .bypassed(reason: VisionInterpolationFailure.deadline.rawValue)
        }
        guard let timing = VideoFrameInterpolationTiming(
            previousPTS: previous.pts,
            previousDuration: previous.duration,
            current: frame,
            expectedInterval: plan.sourceInterval
        ), Self.acceptsPairDelta(timing.delta) else {
            return .bypassed(reason: "Vision FI discontinuous or > 60fps pair")
        }
        guard VisionInterpolationFormat(previous.pixelBuffer) == format,
              VideoFramePairFormat.matches(previous.pixelBuffer, buffer) else {
            return .bypassed(reason: "Vision FI frame format changed")
        }
        do {
            let resources = try metalResources(for: format)
            let profile = adaptiveController.activeProfile(
                sourceFPS: wallFPS,
                phaseCount: plan.phases.count,
                superResolutionActive: superResolutionActive,
                forceInterpolation: forceInterpolation
            )
            let start = ContinuousClock.now
            let signpostState = Self.signposter.beginInterval("Optical flow")
            let candidates: [CVPixelBuffer]
            do {
                candidates = try await interpolate(
                    previous: previous.pixelBuffer,
                    current: buffer,
                    plan: plan,
                    profile: profile,
                    resources: resources,
                    hasTimeRemaining: hasTimeRemaining
                )
            } catch {
                Self.signposter.endInterval("Optical flow", signpostState)
                throw error
            }
            Self.signposter.endInterval("Optical flow", signpostState)
            let elapsedMs = Double(start.duration(to: .now) / .microseconds(1)) / 1_000.0
            let wallInterval = plan.sourceInterval / speed
            adaptiveController.recordCompletion(
                elapsedMs: elapsedMs,
                pairIntervalSeconds: wallInterval,
                sourceFPS: wallFPS,
                phaseCount: plan.phases.count,
                superResolutionActive: superResolutionActive,
                forceInterpolation: forceInterpolation
            )
            return .interpolated(frames: plan.makeFrames(buffers: candidates))
        } catch {
            if let failure = error as? VisionInterpolationFailure, failure == .deadline {
                adaptiveController.recordDeadlineMiss(
                    sourceFPS: wallFPS,
                    phaseCount: plan.phases.count,
                    superResolutionActive: superResolutionActive,
                    forceInterpolation: forceInterpolation
                )
            }
            let reason = (error as? VisionInterpolationSetupFailure)?.reason
                ?? (error as? VisionInterpolationFailure)?.rawValue
                ?? "Vision FI unexpected failure"
            return .bypassed(reason: reason)
        }
        #endif
    }

    private func metalResources(for format: VisionInterpolationFormat) throws -> VisionInterpolationMetal {
        if let resources, resources.format == format { return resources }
        resources = nil
        let replacement = try VisionInterpolationMetal(format: format)
        resources = replacement
        return replacement
    }

    private static func checkBudget(_ hasTimeRemaining: @Sendable () -> Bool) throws {
        if Task.isCancelled { throw VisionInterpolationFailure.cancelled }
        guard hasTimeRemaining() else { throw VisionInterpolationFailure.deadline }
    }

    private func interpolate(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        plan: VideoFrameInterpolationPlan,
        profile: OpticalFlowQualityProfile,
        resources: VisionInterpolationMetal,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> [CVPixelBuffer] {
        try Self.checkBudget(hasTimeRemaining)
        let pair = try await resources.preparePair(previous: previous, current: current, profile: profile)
        let flowBuffer = try await Self.computeVisionFlow(
            previousAnalysis: pair.previousAnalysis,
            currentAnalysis: pair.currentAnalysis,
            accuracy: profile.visionAccuracy,
            hasTimeRemaining: hasTimeRemaining
        )
        let forwardFlow = try resources.bindFlow(flowBuffer, for: pair)
        try Self.checkBudget(hasTimeRemaining)
        let outputs = try await resources.synthesize(pair, forwardFlow: forwardFlow, phases: plan.phases)

        // Preserve full SDR / 10-bit PQ / HLG / Dolby Vision color & mastering metadata on synthesized frames.
        let outputColorSpace: ScaledVideoOutputMetadata.OutputColorSpace =
            resources.format.isBGRA ? .rgbConverted : .yuvSameAsSource
        for output in outputs {
            ScaledVideoOutputMetadata.copy(from: current, to: output, colorSpace: outputColorSpace)
        }
        return outputs
    }

    /// Orders the analysis pair for `VNGenerateOpticalFlowRequest` so Vision computes **forward**
    /// dense optical flow anchored on `previousAnalysis` (`t = 0`) pointing toward `currentAnalysis`
    /// (`t = 1`): `current(p + flow(p)) ≈ previous(p)`.
    ///
    /// Note: `VNGenerateOpticalFlowRequest` produces directional vectors on the `VNImageRequestHandler`
    /// image grid pointing toward `targetedCVPixelBuffer`, so `handler` MUST receive `previousAnalysis`
    /// and `request` MUST target `currentAnalysis`.
    static func forwardFlowInputs(
        previousAnalysis: CVPixelBuffer,
        currentAnalysis: CVPixelBuffer
    ) -> (handlerSource: CVPixelBuffer, requestTarget: CVPixelBuffer) {
        (handlerSource: previousAnalysis, requestTarget: currentAnalysis)
    }

    /// Computes forward dense optical flow (`previousAnalysis` → `currentAnalysis`) via a single
    /// `VNGenerateOpticalFlowRequestRevision1` pass backed by the shared Metal `CIContext` and
    /// wrapped in an `autoreleasepool` so Vision's internal IOSurfaces are reclaimed immediately.
    private static func computeVisionFlow(
        previousAnalysis: CVPixelBuffer,
        currentAnalysis: CVPixelBuffer,
        accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        try checkBudget(hasTimeRemaining)
        let inputs = forwardFlowInputs(
            previousAnalysis: previousAnalysis,
            currentAnalysis: currentAnalysis
        )
        let options: [VNImageOption: Any]
        if let ciContext = try? VideoEnhancementMetalContext.shared.resources().visionCIContext {
            options = [.ciContext: ciContext]
        } else {
            options = [:]
        }
        let request = VNGenerateOpticalFlowRequest(
            targetedCVPixelBuffer: inputs.requestTarget,
            orientation: .up,
            options: options
        )
        request.revision = visionOpticalFlowRevision
        request.computationAccuracy = accuracy
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        request.keepNetworkOutput = false
        let cancellation = VisionRequestCancellation(request: request)
        return try await withTaskCancellationHandler {
            try autoreleasepool {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: inputs.handlerSource,
                    orientation: .up,
                    options: options
                )
                do {
                    try handler.perform([request])
                } catch {
                    try checkBudget(hasTimeRemaining)
                    throw VisionInterpolationFailure.vision
                }
                guard let buffer = request.results?.first?.pixelBuffer else {
                    throw VisionInterpolationFailure.flowLayout
                }
                return buffer
            }
        } onCancel: {
            cancellation.request.cancel()
        }
    }

    private static let signposter = OSSignposter(subsystem: "com.swiftpili.app", category: "VisionFrameInterpolation")
}

private struct VisionRequestCancellation: @unchecked Sendable {
    let request: VNRequest
}

enum VisionInterpolationFailure: String, Error {
    case cancelled = "Vision FI cancelled"
    case deadline = "Vision FI deadline"
    case pool = "Vision FI pixel buffer pool"
    case poolBusy = "Vision FI output pool exhausted"
    case texture = "Vision FI pixel buffer texture mapping"
    case outputFormat = "Vision FI output layout differs from source"
    case vision = "Vision FI optical flow request failed"
    case flowLayout = "Vision FI unexpected flow layout"
    case gpu = "Vision FI Metal execution failed"
}
