import CoreVideo
import Foundation
import os
import Vision

/// Owned by the serial enhancement worker. The worker cancels and awaits its active
/// process before flushing or tearing down. The original frames stay with presentation.
final class VisionFrameInterpolationBackend {
    private var previousFrame: MediaVideoFrame?
    private var resources: VisionInterpolationMetal?

    // This backend runs two flow requests and a full-resolution GPU synthesis.
    // Preserve its current admission envelope until device measurements support expanding it.
    private static let minimumSourceInterval: TimeInterval = 1 / 30.5

    static func inputBypassReason(_ frame: MediaVideoFrame) -> String? {
        if !VideoEnhancementGuardrails.isWithin1080p(
            width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer)
        ) {
            return "Vision FI resolution > 1080p"
        }
        guard VideoFrameInterpolationTiming.sourceFPS(frame) != nil,
              frame.duration + VideoFrameInterpolationTiming.tolerance >= minimumSourceInterval else {
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
        resources = nil
    }

    func process(
        _ frame: MediaVideoFrame,
        plan: VideoFrameInterpolationPlan?,
        hasTimeRemaining: @Sendable () -> Bool
    ) async -> VideoInterpolationBackendOutcome {
        #if targetEnvironment(simulator)
        return .bypassed(reason: "Vision FI device required")
        #else
        if let reason = Self.inputBypassReason(frame) {
            flush()
            return .bypassed(reason: reason)
        }
        let buffer = frame.pixelBuffer
        guard VideoFrameInterpolationTiming.sourceFPS(frame) != nil,
              let format = VisionInterpolationFormat(buffer) else {
            flush()
            return .bypassed(reason: "Vision FI input format or timing")
        }
        guard !Task.isCancelled else {
            flush()
            return .bypassed(reason: VisionInterpolationFailure.cancelled.rawValue)
        }
        let previous = previousFrame
        var reference = frame
        reference.displayCoverage = nil
        previousFrame = reference
        guard let plan, let previous else { return .passthrough }
        guard let timing = VideoFrameInterpolationTiming(
            previousPTS: previous.pts, previousDuration: previous.duration, current: frame
        ), Self.acceptsPairDelta(timing.delta) else {
            return .bypassed(reason: "Vision FI discontinuous or > 30fps pair")
        }
        guard VisionInterpolationFormat(previous.pixelBuffer) == format,
              VideoFramePairFormat.matches(previous.pixelBuffer, buffer) else {
            return .bypassed(reason: "Vision FI frame format changed")
        }
        do {
            try Self.checkBudget(hasTimeRemaining)
            let resources = try metalResources(for: format)
            let candidates = try await interpolate(
                previous: previous.pixelBuffer, current: buffer, plan: plan,
                resources: resources, hasTimeRemaining: hasTimeRemaining
            )
            return .interpolated(frames: plan.makeFrames(buffers: candidates))
        } catch {
            if Task.isCancelled { flush() }
            let reason = (error as? VisionInterpolationSetupFailure)?.reason
                ?? (error as? VisionInterpolationFailure)?.rawValue
                ?? "Vision FI unexpected failure"
            return .bypassed(reason: reason)
        }
        #endif
    }

    private func metalResources(for format: VisionInterpolationFormat) throws -> VisionInterpolationMetal {
        if let resources, resources.format == format { return resources }
        // Retire the previous format pool before configuring a replacement.
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
        let outputs = try plan.phases.map { phase in
            try Self.checkBudget(hasTimeRemaining)
            let buffer = try resources.allocateOutput(phaseCount: plan.phases.count)
            guard VideoFramePairFormat.hasSameStorageFormat(current, buffer) else {
                throw VisionInterpolationFailure.outputFormat
            }
            return (phase: phase, buffer: buffer)
        }
        try Self.checkBudget(hasTimeRemaining)
        let input = try resources.makePair(previous: previous, current: current)
        try Self.checkBudget(hasTimeRemaining)
        try await resources.prepareAnalysis(input)
        try Self.checkBudget(hasTimeRemaining)
        try resources.uploadFlow(try await Self.flow(
            from: input.previousAnalysis, to: input.currentAnalysis, hasTimeRemaining: hasTimeRemaining
        ), forward: true)
        try Self.checkBudget(hasTimeRemaining)
        try resources.uploadFlow(try await Self.flow(
            from: input.currentAnalysis, to: input.previousAnalysis, hasTimeRemaining: hasTimeRemaining
        ), forward: false)
        try Self.checkBudget(hasTimeRemaining)
        let verticalSign = try await resources.validateMotion(input: input)
        try Self.checkBudget(hasTimeRemaining)
        try await resources.synthesize(input, verticalSign: verticalSign, outputs: outputs) {
            try Self.checkBudget(hasTimeRemaining)
        }
        try Self.checkBudget(hasTimeRemaining)
        for output in outputs {
            VideoFramePairFormat.copyInterpretation(from: current, to: output.buffer)
        }
        try Self.checkBudget(hasTimeRemaining)
        return outputs.map { $0.buffer }
    }

    private static let signposter = OSSignposter(subsystem: "com.swiftpili.app", category: "VisionFrameInterpolation")

    private static func flow(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        // Apple defines the displacement domain as the *targeted* image. Use .up
        // on both inputs so Vision sees the same raster orientation as the shader.
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: source, orientation: .up, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        request.keepNetworkOutput = false
        let cancellation = VisionRequestCancellation(request: request)
        return try await withTaskCancellationHandler {
            try checkBudget(hasTimeRemaining)
            let handler = VNImageRequestHandler(cvPixelBuffer: destination, orientation: .up, options: [:])
            do {
                try signposter.withIntervalSignpost("Optical flow") { try handler.perform([request]) }
            } catch {
                try checkBudget(hasTimeRemaining)
                throw VisionInterpolationFailure.vision
            }
            try checkBudget(hasTimeRemaining)
            guard let buffer = request.results?.first?.pixelBuffer else { throw VisionInterpolationFailure.flowLayout }
            return buffer
        } onCancel: {
            cancellation.request.cancel()
        }
    }
}

/// Carries one fully configured request to its cancellation handler. `cancel()` is
/// the only operation allowed there. Vision execution and result reads stay on the worker.
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
