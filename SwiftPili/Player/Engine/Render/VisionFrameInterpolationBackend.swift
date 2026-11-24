import CoreVideo
import Foundation
import os
import Vision

final class VisionFrameInterpolationBackend {
    private var previousFrame: MediaVideoFrame?
    private var resources: VisionInterpolationMetal?

    private static let minimumSourceInterval: TimeInterval = 1 / 32.5

    /// Vision optical flow + Metal synthesis supports arbitrary phases in `(0, 1)` (2×–5× and
    /// CFR resampling), constrained to progressive SDR sources ≤ ~32 fps within the configured
    /// input resolution cap.
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
        guard VideoFrameInterpolationTiming.sourceFPS(frame) != nil else {
            return "Vision FI invalid duration"
        }
        let effectiveInterval = cadenceInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? frame.duration
        guard effectiveInterval + VideoFrameInterpolationTiming.tolerance >= minimumSourceInterval else {
            return "Vision FI source > 30fps or invalid duration"
        }
        return nil
    }

    static func acceptsPairDelta(_ delta: TimeInterval) -> Bool {
        delta + VideoFrameInterpolationTiming.tolerance >= minimumSourceInterval && delta <= 0.25
    }

    func flush() {
        previousFrame = nil
        resources?.flushTextures()
    }

    func tearDown() {
        previousFrame = nil
        resources?.flushTextures()
        resources = nil
    }

    func process(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        maxInputResolution: VideoEnhancementMaxInputResolution = .p1080,
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
        guard VideoFrameInterpolationTiming.sourceFPS(frame) != nil,
              let format = VisionInterpolationFormat(buffer) else {
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
        guard hasTimeRemaining() else {
            return .bypassed(reason: VisionInterpolationFailure.deadline.rawValue)
        }
        guard let timing = VideoFrameInterpolationTiming(
            previousPTS: previous.pts,
            previousDuration: previous.duration,
            current: frame,
            expectedInterval: plan.sourceInterval
        ), Self.acceptsPairDelta(timing.delta) else {
            return .bypassed(reason: "Vision FI discontinuous or > 30fps pair")
        }
        guard VisionInterpolationFormat(previous.pixelBuffer) == format,
              VideoFramePairFormat.matches(previous.pixelBuffer, buffer) else {
            return .bypassed(reason: "Vision FI frame format changed")
        }
        do {
            let resources = try metalResources(for: format)
            let candidates = try await interpolate(
                previous: previous.pixelBuffer, current: buffer, plan: plan,
                resources: resources, hasTimeRemaining: hasTimeRemaining
            )
            return .interpolated(frames: plan.makeFrames(buffers: candidates))
        } catch {
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
        resources: VisionInterpolationMetal,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> [CVPixelBuffer] {
        try Self.checkBudget(hasTimeRemaining)
        let input = try resources.makePair(previous: previous, current: current)
        try await resources.prepareAnalysis(input)

        let forwardBuffer = try await Self.flow(
            from: input.previousAnalysis, to: input.currentAnalysis, hasTimeRemaining: hasTimeRemaining
        )
        let forwardFlow = try resources.bindFlow(forwardBuffer, forward: true)

        let backwardBuffer = try await Self.flow(
            from: input.currentAnalysis, to: input.previousAnalysis, hasTimeRemaining: hasTimeRemaining
        )
        let backwardFlow = try resources.bindFlow(backwardBuffer, forward: false)

        let outputs = try await resources.validateAndSynthesize(
            input,
            forwardFlow: forwardFlow,
            backwardFlow: backwardFlow,
            phases: plan.phases,
            currentBuffer: current
        ) {
            try Self.checkBudget(hasTimeRemaining)
        }

        // Never discard already-computed GPU output once synthesis finishes.
        for output in outputs {
            VideoFramePairFormat.copyInterpretation(from: current, to: output)
        }
        return outputs
    }

    private static let signposter = OSSignposter(subsystem: "com.swiftpili.app", category: "VisionFrameInterpolation")

    private static func flow(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        try checkBudget(hasTimeRemaining)
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: source, orientation: .up, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        request.keepNetworkOutput = false
        let cancellation = VisionRequestCancellation(request: request)
        return try await withTaskCancellationHandler {
            let handler = VNImageRequestHandler(cvPixelBuffer: destination, orientation: .up, options: [:])
            do {
                try signposter.withIntervalSignpost("Optical flow") { try handler.perform([request]) }
            } catch {
                try checkBudget(hasTimeRemaining)
                throw VisionInterpolationFailure.vision
            }
            guard let buffer = request.results?.first?.pixelBuffer else { throw VisionInterpolationFailure.flowLayout }
            return buffer
        } onCancel: {
            cancellation.request.cancel()
        }
    }
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
    case sceneCut = "Vision FI scene cut or high residual"
    case inconsistent = "Vision FI inconsistent optical flow"
    case gpu = "Vision FI Metal execution failed"
}
