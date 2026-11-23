import CoreVideo
import Foundation
import os
import UIKit

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
    static let minimumAutomaticBudget = 128 << 20
    static let maximumAutomaticBudget = 1 << 30

    /// Automatic budget: 25% of what the process could still allocate (plus what enhancement
    /// already holds, so the budget doesn't shrink as its own buffers fill), 128 MB–1 GB.
    static func automaticBudget(currentUsageBytes: Int) -> Int {
        let available = Int(clamping: os_proc_available_memory())
        guard available > 0 else { return 256 << 20 }
        return min(maximumAutomaticBudget, max(minimumAutomaticBudget, (available + currentUsageBytes) / 4))
    }
    static let defaultSuperResolutionFrames = 8
    static let defaultInterpolationFramesPerPhase = 4
    /// Buffers in flight inside the worker / not yet handed to the display layer.
    private static let workerHeadroom = 4
    private static let displaySlack: TimeInterval = 0.1

    var lead: TimeInterval = defaultLead
    var superResolutionFrames = defaultSuperResolutionFrames
    var interpolationFramesPerPhase = defaultInterpolationFramesPerPhase
    /// The output rate needs more buffers than the budget allows even at the minimum lookahead,
    /// so enhancement will keep hitting "pool busy" until the configuration is reduced.
    var isMemoryBound = false
    /// Approximate bytes held by enhancement output at this lookahead.
    var estimatedBytes = 0
    var budgetBytes = 0

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
        interpolatedBytes: Int,
        budgetBytes: Int,
        maximumLead: TimeInterval = 1.0
    ) -> Self {
        guard sourceFPS.isFinite, sourceFPS > 1, sourceFPS < 240, budgetBytes > 0 else { return .default }
        let midpoints = max(0, midpointsPerSource)
        let outputFPS = sourceFPS * Double(1 + midpoints)
        let maximumLead = max(minimumLead, maximumLead)
        // High-multiplier interpolation (e.g. 5× = 4 midpoints + 1 original) keeps up to
        // `midpoints + 1` buffers in flight inside the worker before enqueueing to the display layer.
        let headroom = max(workerHeadroom, midpoints + 2)
        var plan = Self.default
        plan.budgetBytes = budgetBytes

        if let upscaledBytes, upscaledBytes > 0 {
            // SR output covers originals and (upscaled) midpoints; FI buffers are transient.
            let affordable = budgetBytes / upscaledBytes
            plan.superResolutionFrames = max(defaultSuperResolutionFrames, affordable)
            plan.lead = leadFitting(
                frames: plan.superResolutionFrames, fps: outputFPS, maximumLead: maximumLead, headroom: headroom
            )
            plan.isMemoryBound = framesNeeded(fps: outputFPS, headroom: headroom) > plan.superResolutionFrames
            plan.estimatedBytes = framesNeeded(fps: outputFPS, lead: plan.lead, headroom: headroom) * upscaledBytes
        } else if midpoints > 0, interpolatedBytes > 0 {
            // FI only: midpoints sit in the display queue straight from the FI pool.
            let affordable = budgetBytes / interpolatedBytes
            let midpointFPS = sourceFPS * Double(midpoints)
            plan.lead = leadFitting(
                frames: affordable, fps: midpointFPS, maximumLead: maximumLead, headroom: headroom
            )
            plan.isMemoryBound = framesNeeded(fps: midpointFPS, headroom: headroom) > affordable
            plan.estimatedBytes = framesNeeded(
                fps: midpointFPS, lead: plan.lead, headroom: headroom
            ) * interpolatedBytes
        } else {
            return .default
        }

        if midpoints > 0 {
            let pairsAlive = Int(((plan.lead + displaySlack) * sourceFPS).rounded(.up)) + 2
            plan.interpolationFramesPerPhase = max(defaultInterpolationFramesPerPhase, pairsAlive)
        }
        return plan
    }

    /// Buffers alive at the minimum lookahead.
    private static func framesNeeded(
        fps: Double, lead: TimeInterval = minimumLead, headroom: Int = workerHeadroom
    ) -> Int {
        Int(((lead + displaySlack) * fps).rounded(.up)) + headroom
    }

    private static func leadFitting(
        frames: Int, fps: Double, maximumLead: TimeInterval, headroom: Int = workerHeadroom
    ) -> TimeInterval {
        let lead = Double(frames - headroom) / fps - displaySlack
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

/// Records system memory warnings; enhancement halves its buffer budget for a minute afterwards.
enum VideoEnhancementMemoryPressure {
    private static let lastWarning = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    nonisolated(unsafe) private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
    ) { _ in
        lastWarning.withLock { $0 = .now }
    }

    static func install() { _ = observer }

    static var isUnderPressure: Bool {
        install()
        guard let last = lastWarning.withLock({ $0 }) else { return false }
        return last.duration(to: .now) < .seconds(60)
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
