import Foundation

/// The highest position a seek may ASK for.
///
/// Every engine needs some content to remain between a seek target and the end
/// of the media before it can start playing there — the Demand engine has to
/// bank its audio ring's seek-transition reserve past the target, libVLC's
/// in-place seek has always clamped to half a second short of the end. Both
/// knew it; neither said it, and the player clamped its targets INCLUSIVELY to
/// `duration` instead, which manufactures a target that cannot be satisfied.
///
/// What that cost (backlog CB-23): a swipe-seek to the end of a 15.3 s video
/// produced `SEEK PRIMING FAILED (endOfStreamBeforeTarget)`, a decoder-recovery
/// ticket spent where no reopen could help, the user-facing string "Video
/// decoder failed. Tap Retry." against a decoder that had just decoded two
/// 1920×1080 frames, and a durable resume target that re-aimed at the same
/// impossible position for the ticket's whole 90-second lifetime. The last
/// `reserve` seconds of every video were a structural dead zone — 0.25 s at 1×
/// and 0.5 s at 2×, because the reserve is denominated in content.
///
/// This is not a threshold tuned to make a symptom go away. The reserve is a
/// property the engines already enforce on themselves; the only defect was that
/// nobody asked them before naming a target.
enum SeekTargetAdmission {
    /// Clamps a requested position into the range the active engine can serve.
    ///
    /// - Parameters:
    ///   - requested: the position asked for, in absolute media seconds.
    ///   - duration: the media's duration, or 0 when it is not known yet.
    ///   - reserve: what must remain between the target and the end of the
    ///     media for this engine to launch there (`PlayerBackend.seekLaunchReserve`).
    /// - Returns: the position to actually seek to.
    ///
    /// An unknown duration passes the request through: a ceiling derived from a
    /// duration nobody measured would be a fabricated bound, and the engines
    /// still clamp in their own coordinates. A duration shorter than the
    /// reserve yields 0 — the whole file is inside the reserve, and the head is
    /// the only position that can be served.
    static func admissibleTarget(
        requested: TimeInterval,
        duration: TimeInterval,
        reserve: TimeInterval
    ) -> TimeInterval {
        let floor = requested.isFinite ? max(0, requested) : 0
        guard duration.isFinite, duration > 0 else { return floor }
        let safeReserve = reserve.isFinite ? max(0, reserve) : 0
        let ceiling = max(0, duration - safeReserve)
        return min(floor, ceiling)
    }

    /// Whether a request was actually lowered — for the one log line that makes
    /// a clamped seek visible. Comparing the two values at the call site would
    /// read as float equality; this states what the comparison means.
    static func wasClamped(
        requested: TimeInterval,
        admitted: TimeInterval
    ) -> Bool {
        guard requested.isFinite else { return true }
        return admitted < requested - 1e-6
    }
}
