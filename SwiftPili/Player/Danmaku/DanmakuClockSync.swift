import Foundation

/// How the media clock drives the danmaku layer tree — as arithmetic, with no
/// layer in sight.
///
/// The renderer does not animate bullets frame by frame. It hands CoreAnimation
/// one timing configuration and lets the render server advance them, which is
/// what keeps danmaku moving while the main thread hitches and what makes a
/// `CADisplayLink` unnecessary. Everything that can go wrong with that lives in
/// three numbers, so the three numbers are computed here and tested by
/// execution.
///
/// **The identity.** A `CALayer`'s local time is
///
///     t_local = (t_host − beginTime) × speed + timeOffset
///
/// Define the container's local time to BE media time. Then every bullet's
/// animation can use its own `progress` as its `beginTime` with no conversion at
/// all, and the only thing that ever has to be written is this configuration —
/// on play, pause, rate change and seek. Those are edges, not frames.
///
/// Solving `t_local = mediaTime` at the moment of the write gives
/// `beginTime = t_host − mediaTime / rate`, which is the whole mechanism. A
/// consequence worth stating: press-and-hold 2× needs no code here, because
/// `speed = rate` is already the answer.
enum DanmakuClockSync {
    /// What gets written onto the container layer. Nothing else is.
    struct LayerTiming: Equatable, Sendable {
        /// `CALayer.speed`. Zero while paused — which freezes the whole tree
        /// without touching a single bullet's animation.
        let speed: Double
        /// `CALayer.timeOffset`.
        let timeOffset: TimeInterval
        /// `CALayer.beginTime`.
        let beginTime: TimeInterval
    }

    /// How far the layer tree may drift from the media clock before it is worth
    /// rewriting the configuration.
    ///
    /// The media tick arrives roughly every 250 ms and carries small jitter;
    /// re-anchoring on every one of them would be churn, and a visible jump each
    /// time the correction was larger than the error. 150 ms is under the
    /// threshold at which a bullet's position reads as wrong and comfortably
    /// above the clock's own noise.
    static let resyncThreshold: TimeInterval = 0.15

    /// The configuration that makes the container's local time equal
    /// `mediaTime` at `hostTime`, and advance at `rate` from there.
    ///
    /// - Parameters:
    ///   - hostTime: `CACurrentMediaTime()` at the moment of the write.
    ///   - rate: playback rate. A non-positive or non-finite rate is treated as
    ///     paused rather than inverted or NaN-propagated — a clock this app
    ///     cannot describe must stop the bullets, not scatter them.
    static func timing(
        mediaTime: TimeInterval,
        rate: Double,
        isPlaying: Bool,
        hostTime: TimeInterval
    ) -> LayerTiming {
        let position = mediaTime.isFinite ? max(0, mediaTime) : 0
        guard isPlaying, rate.isFinite, rate > 0 else {
            // Paused: local time is pinned by `timeOffset` with `speed = 0` and
            // `beginTime = 0` (Apple QA1673 / CAMediaTiming). Setting `beginTime`
            // to `CACurrentMediaTime()` puts `beginTime` slightly ahead of the
            // current CATransaction's VSync timestamp, dropping child animations
            // for one frame (`t_parent < beginTime` under `.removed` fillMode).
            return LayerTiming(speed: 0, timeOffset: position, beginTime: 0)
        }
        return LayerTiming(
            speed: rate,
            timeOffset: 0,
            beginTime: hostTime - position / rate
        )
    }

    /// Preserves the layer tree's continuous local time across pause, resume,
    /// and rate edges whenever it already agrees with `mediaTime` within
    /// `resyncThreshold`, preventing visible bullet snaps inside the deadband.
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

    /// The layer tree's local time under a configuration — i.e. what CoreAnimation
    /// believes the media clock is.
    ///
    /// This is the same identity the layer applies, written out so a test can
    /// check the configuration against it instead of against a restatement of
    /// how it was built.
    static func localTime(
        under timing: LayerTiming,
        atHostTime hostTime: TimeInterval
    ) -> TimeInterval {
        (hostTime - timing.beginTime) * timing.speed + timing.timeOffset
    }

    /// How far the backend's own clock may sit from the 4Hz sample and still
    /// be believed at a transport edge.
    ///
    /// At the nominal cadence the sample trails the picture by one throttle
    /// interval (0.25s) times the rate. Larger disagreement is uncertain: a
    /// delayed callback, seek or reopen can all cause it, so the edge keeps the
    /// sample until explicit opening or successful settlement pins a proved
    /// position. Current media ticks retire that pin and retain the existing
    /// unsolicited-backward refill fallback.
    static let liveClockAgreement: TimeInterval = 1.0

    /// The media time a transport edge — play, pause, rate change — writes
    /// into the container (B7).
    ///
    /// - `openPosition` wins while it is set: the admitted opening or successful
    ///   Seek settlement has not supplied a current tick yet. The backend may
    ///   still be opening, or the throttled sample may predate the settled clock.
    /// - Otherwise the backend's live clock, when it is a real time and agrees
    ///   with `sampled` to within `liveClockAgreement`. That is the whole
    ///   point: a pause pinned to the throttled sample snapped every bullet
    ///   back by up to a quarter second.
    /// - Otherwise `sampled`.
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

    /// Whether the tree has drifted far enough from the media clock to be worth
    /// re-anchoring. Called from the media tick; almost always false.
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
