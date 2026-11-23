import CoreMedia
import CoreVideo
import Foundation
#if !targetEnvironment(simulator)
import VideoToolbox
#endif

struct PostProcessFrameBox: @unchecked Sendable {
    let frame: MediaVideoFrame
}

struct EnhancementFrameIdentity: Equatable, Sendable {
    private let buffer: ObjectIdentifier
    private let pts: TimeInterval
    private let duration: TimeInterval

    init(_ frame: MediaVideoFrame) {
        buffer = ObjectIdentifier(frame.pixelBuffer)
        pts = frame.pts
        duration = frame.duration
    }
}

struct VideoEnhancementDeadlines: Sendable {
    let original: ContinuousClock.Instant
    let midpoint: ContinuousClock.Instant?

    func workDeadline(upscaling: Bool) -> ContinuousClock.Instant {
        upscaling ? original : midpoint ?? original
    }
}

struct VideoFrameEnhancementResult: Sendable {
    let midpoints: [PostProcessFrameBox]
    let enhancedOriginal: PostProcessFrameBox?
    let telemetry: VideoEnhancementTelemetry
    let interpolationBypassReason: String?
    let originalSuperResolutionBypassReason: String?
}

enum VideoFrameEnhancementUpdate: Sendable {
    case midpointReady([PostProcessFrameBox])
    case finished(VideoFrameEnhancementResult)
}

struct VideoFrameInterpolationTiming {
    static let tolerance: TimeInterval = 1e-9
    let delta: TimeInterval

    init?(previousPTS: TimeInterval, previousDuration: TimeInterval, current: MediaVideoFrame) {
        guard Self.sourceFPS(current) != nil, previousPTS.isFinite,
              previousDuration.isFinite, previousDuration > 0 else { return nil }
        let delta = current.pts - previousPTS
        let midpointPTS = previousPTS + delta * 0.5
        guard delta.isFinite, delta > 0, delta <= previousDuration * 1.5 + Self.tolerance,
              midpointPTS > previousPTS, midpointPTS < current.pts else { return nil }
        self.delta = delta
    }

    static func sourceFPS(_ frame: MediaVideoFrame) -> Double? {
        guard frame.pts.isFinite, frame.duration.isFinite, frame.duration > 0 else { return nil }
        let fps = 1 / frame.duration
        return fps.isFinite ? fps : nil
    }
}

struct VideoFrameInterpolationPlan: Sendable {
    static let maximumMultiplier = 5
    /// Multipliers supported by arbitrary-phase backends (`VTFrameRateConversionConfiguration` on
    /// iOS 26+ and `VisionFrameInterpolationBackend`'s optical-flow Metal shader on iOS 18–25).
    static let fullMultipliers = [5, 4, 3, 2]
    /// Dyadic-only multipliers supported by `VTLowLatencyFrameInterpolationConfiguration`
    /// (`numberOfInterpolatedFrames = 1` → 2× `[0.5]`, `2` → 4× `[0.25, 0.5, 0.75]`).
    static let dyadicMultipliers = [4, 2]
    /// Small relative interval tolerance covering 1 ms container PTS quantization (e.g. 33/34 ms for
    /// 30 fps or 41/42 ms for 24 fps) so `phaseCount` stays constant and avoids VT session churn.
    static let jitterFactor: Double = 1.0165

    let phases: [Float]
    let pts: [TimeInterval]
    let sourceInterval: TimeInterval

    /// Whether the active interpolation backend supports arbitrary uniform phases (such as 3×
    /// `[1/3, 2/3]` for 30→90 / 24→72 fps and 5× `[0.2, 0.4, 0.6, 0.8]` for 24→120 fps).
    static var supportsArbitraryPhases: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        if #available(iOS 26.0, *) {
            // VTFrameRateConversionConfiguration accepts arbitrary phases in (0, 1);
            // VTLowLatencyFrameInterpolationConfiguration only produces 2^x - 1 dyadic phases.
            // Restrict to dyadic multipliers only when a device supports LLFI without FRC.
            return VTFrameRateConversionConfiguration.isSupported
                || !VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return true
        #endif
    }

    static var defaultMultipliers: [Int] {
        supportsArbitraryPhases ? fullMultipliers : dyadicMultipliers
    }

    static func bestMultiplier(
        forInterval interval: TimeInterval,
        rate: VideoInterpolationRate,
        allowedMultipliers: [Int] = Self.defaultMultipliers
    ) -> Int? {
        guard interval.isFinite, interval > 0 else { return nil }
        guard let targetFPS = rate.targetFPS else { return 2 }
        let cap = Double(targetFPS)
        let effectiveInterval = interval * jitterFactor + VideoFrameInterpolationTiming.tolerance
        return allowedMultipliers
            .filter { $0 >= 2 && $0 <= maximumMultiplier }
            .sorted(by: >)
            .first { effectiveInterval >= Double($0) / cap }
    }

    init?(
        previousPTS: TimeInterval,
        currentPTS: TimeInterval,
        interval: TimeInterval,
        rate: VideoInterpolationRate,
        allowedMultipliers: [Int] = Self.defaultMultipliers
    ) {
        guard let multiplier = Self.bestMultiplier(
            forInterval: interval, rate: rate, allowedMultipliers: allowedMultipliers
        ) else { return nil }
        let phases = (1..<multiplier).map { Float($0) / Float(multiplier) }
        let pts = phases.map { previousPTS + interval * Double($0) }
        var lastPTS = previousPTS
        for point in pts {
            guard point > lastPTS, point < currentPTS else { return nil }
            lastPTS = point
        }
        self.phases = phases
        self.pts = pts
        sourceInterval = interval
    }

    var sourceFPS: Double { 1 / sourceInterval }

    func makeFrames(buffers: [CVPixelBuffer]) -> [MediaVideoFrame] {
        precondition(buffers.count == pts.count)
        let duration = sourceInterval / Double(pts.count + 1)
        return zip(pts, buffers).map { MediaVideoFrame(pts: $0, duration: duration, pixelBuffer: $1) }
    }

    static func outputPoolLimit(phaseCount: Int) -> Int {
        VideoEnhancementPoolLimits.interpolationFrames(phaseCount: phaseCount)
    }
}
