import CoreVideo
import Foundation
import os

/// How far ahead of display enhanced frames are produced, and how many enhancement output buffers
/// may be alive at once.
///
/// Every enhanced frame enqueued to the display layer keeps its output pixel buffer alive until it
/// is shown, so lookahead and pool size must grow together: a deeper lookahead with the old fixed
/// pools (8 SR / 4×phases FI) just turns into "pool busy" fallbacks. Both are bounded by a memory
/// budget derived from the measured output buffer size (MetalFX outputs BGRA, so 4K is ~33 MB/frame).
struct VideoEnhancementBufferPlan: Equatable, Sendable {
    static let defaultLead: TimeInterval = 0.3
    static let minimumLead: TimeInterval = 0.2
    static let maximumLead: TimeInterval = 1.0
    static let memoryBudgetBytes = 192 << 20
    static let defaultSuperResolutionFrames = 8
    static let defaultInterpolationFramesPerPhase = 4
    /// Buffers in flight inside the worker / not yet handed to the display layer.
    private static let workerHeadroom = 4
    private static let displaySlack: TimeInterval = 0.1

    var lead: TimeInterval = defaultLead
    var superResolutionFrames = defaultSuperResolutionFrames
    var interpolationFramesPerPhase = defaultInterpolationFramesPerPhase

    static let `default` = Self()

    /// - Parameters:
    ///   - sourceFPS: source frame rate.
    ///   - midpointsPerSource: interpolated frames per source frame (0 when FI is not running).
    ///   - upscaledBytes: size of one SR output buffer, or nil when SR is not running.
    ///   - interpolatedBytes: size of one FI output buffer (≈ source frame size).
    static func make(
        sourceFPS: Double,
        midpointsPerSource: Int,
        upscaledBytes: Int?,
        interpolatedBytes: Int
    ) -> Self {
        guard sourceFPS.isFinite, sourceFPS > 1, sourceFPS < 240 else { return .default }
        let midpoints = max(0, midpointsPerSource)
        let outputFPS = sourceFPS * Double(1 + midpoints)
        var plan = Self.default

        if let upscaledBytes, upscaledBytes > 0 {
            // SR output covers originals and (upscaled) midpoints; FI buffers are transient.
            let affordable = memoryBudgetBytes / upscaledBytes
            plan.superResolutionFrames = max(defaultSuperResolutionFrames, affordable)
            plan.lead = leadFitting(frames: plan.superResolutionFrames, fps: outputFPS)
        } else if midpoints > 0, interpolatedBytes > 0 {
            // FI only: midpoints sit in the display queue straight from the FI pool.
            let affordable = memoryBudgetBytes / interpolatedBytes
            let midpointFPS = sourceFPS * Double(midpoints)
            plan.lead = leadFitting(frames: affordable, fps: midpointFPS)
        } else {
            return .default
        }

        if midpoints > 0 {
            let pairsAlive = Int(((plan.lead + displaySlack) * sourceFPS).rounded(.up)) + 2
            plan.interpolationFramesPerPhase = max(defaultInterpolationFramesPerPhase, pairsAlive)
        }
        return plan
    }

    private static func leadFitting(frames: Int, fps: Double) -> TimeInterval {
        let lead = Double(frames - workerHeadroom) / fps - displaySlack
        return min(maximumLead, max(minimumLead, lead))
    }
}

/// Process-wide pool limits read at allocation time by the enhancement backends (which run on
/// detached worker tasks), written by the main-actor post processor.
enum VideoEnhancementPoolLimits {
    private static let state = OSAllocatedUnfairLock(initialState: VideoEnhancementBufferPlan.default)

    static func apply(_ plan: VideoEnhancementBufferPlan) {
        state.withLock { $0 = plan }
    }

    static var superResolutionFrames: Int {
        state.withLock { $0.superResolutionFrames }
    }

    static func interpolationFrames(phaseCount: Int) -> Int {
        max(1, phaseCount) * state.withLock { $0.interpolationFramesPerPhase }
    }
}

extension CVPixelBuffer {
    /// Approximate resident size, summing planes for planar formats.
    var enhancementByteSize: Int {
        let planes = CVPixelBufferGetPlaneCount(self)
        guard planes > 0 else { return CVPixelBufferGetDataSize(self) }
        return (0..<planes).reduce(0) {
            $0 + CVPixelBufferGetBytesPerRowOfPlane(self, $1) * CVPixelBufferGetHeightOfPlane(self, $1)
        }
    }
}
