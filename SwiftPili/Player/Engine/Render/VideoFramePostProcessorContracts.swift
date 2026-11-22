import CoreMedia
import CoreVideo
import Foundation

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
    let phases: [Float]
    let pts: [TimeInterval]
    let sourceInterval: TimeInterval

    init?(previousPTS: TimeInterval, currentPTS: TimeInterval, interval: TimeInterval,
          rate: VideoInterpolationRate) {
        let multiplier: Int
        if rate == .doubleRate {
            multiplier = 2
        } else {
            let cap = Double(rate.rawValue)
            guard let fitting = [4, 2].first(where: {
                interval + VideoFrameInterpolationTiming.tolerance >= Double($0) / cap
            }) else { return nil }
            multiplier = fitting
        }
        let phases = multiplier == 4 ? [Float(0.25), 0.5, 0.75] : [Float(0.5)]
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
