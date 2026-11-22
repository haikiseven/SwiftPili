import Foundation

enum DanmakuClockSync {
    struct LayerTiming: Equatable, Sendable {
        let speed: Double
        let timeOffset: TimeInterval
        let beginTime: TimeInterval
    }

    static let resyncThreshold: TimeInterval = 0.15

    static func timing(
        mediaTime: TimeInterval,
        rate: Double,
        isPlaying: Bool,
        hostTime: TimeInterval
    ) -> LayerTiming {
        let position = mediaTime.isFinite ? max(0, mediaTime) : 0
        guard isPlaying, rate.isFinite, rate > 0 else {
            return LayerTiming(speed: 0, timeOffset: position, beginTime: 0)
        }
        return LayerTiming(
            speed: rate,
            timeOffset: 0,
            beginTime: hostTime - position / rate
        )
    }

    static func transitionTiming(
        previous: LayerTiming?,
        mediaTime: TimeInterval,
        rate: Double,
        isPlaying: Bool,
        hostTime: TimeInterval
    ) -> LayerTiming {
        let target = mediaTime.isFinite ? max(0, mediaTime) : 0
        let anchor: TimeInterval
        if let previous {
            let currentLocal = localTime(under: previous, atHostTime: hostTime)
            if currentLocal.isFinite, currentLocal >= 0,
               abs(currentLocal - target) <= resyncThreshold {
                anchor = currentLocal
            } else {
                anchor = target
            }
        } else {
            anchor = target
        }
        return timing(
            mediaTime: anchor,
            rate: rate,
            isPlaying: isPlaying,
            hostTime: hostTime
        )
    }

    static func localTime(
        under timing: LayerTiming,
        atHostTime hostTime: TimeInterval
    ) -> TimeInterval {
        (hostTime - timing.beginTime) * timing.speed + timing.timeOffset
    }

    static let liveClockAgreement: TimeInterval = 1.0

    static func transportEdgeTime(
        openPosition: TimeInterval?,
        liveClock: TimeInterval?,
        sampled: TimeInterval
    ) -> TimeInterval {
        if let openPosition { return openPosition }
        guard let live = liveClock, live.isFinite, live >= 0 else { return sampled }
        guard sampled.isFinite else { return live }
        return abs(live - sampled) <= liveClockAgreement ? live : sampled
    }

    static func needsResync(
        under timing: LayerTiming,
        mediaTime: TimeInterval,
        atHostTime hostTime: TimeInterval
    ) -> Bool {
        guard mediaTime.isFinite else { return true }
        let local = localTime(under: timing, atHostTime: hostTime)
        guard local.isFinite else { return true }
        return abs(local - mediaTime) > resyncThreshold
    }
}
