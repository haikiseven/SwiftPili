import Foundation

/// Resident, fetch, evict, and cancel sets for VOD danmaku segments at one playhead position.
struct DanmakuWindowPlan: Equatable, Sendable {
    let resident: Set<Int>
    let fetch: Set<Int>
    let evict: Set<Int>
    let cancel: Set<Int>

    var isQuiet: Bool { fetch.isEmpty && evict.isEmpty && cancel.isEmpty }
}

/// Sliding 3-segment window policy (current, previous, and prefetched next within
/// `prefetchLeadSeconds`), bounding resident danmaku memory independent of video duration.
enum DanmakuSegmentWindow {
    /// Fallback page size when metadata is unavailable.
    static let segmentSeconds: TimeInterval = 360

    /// How far before a segment's end the next one is fetched.
    ///
    /// A segment decodes in ~1.4 ms but has to arrive over the network first, so
    /// the lead is sized for the request, not the decode. It also keeps the
    /// first load to ONE request: at t=0 the next segment is 360s away and is
    /// not resident yet.
    static let prefetchLeadSeconds: TimeInterval = 60

    /// A ceiling on the index arithmetic, not on any real video —
    /// `Int32.max` segments is a quarter of a million years. It exists because
    /// `Int(someDouble)` TRAPS above `Int.max`, and a media clock is not a
    /// trusted number: it comes from libVLC through a recovery path that has
    /// reported strange values before. Measured — `index(for: 1e300)` crashed
    /// the process before this guard.
    private static let indexCeiling = Int(Int32.max)

    /// 1-based, matching the `segment_index` query parameter. Segment *n*
    /// covers `[(n-1)*360, n*360)`.
    static func index(for mediaTime: TimeInterval, pageSeconds: TimeInterval = segmentSeconds) -> Int {
        guard mediaTime > 0, mediaTime.isFinite else { return 1 }
        let ordinal = mediaTime / validPageSeconds(pageSeconds)
        guard ordinal < TimeInterval(indexCeiling) else { return indexCeiling }
        return Int(ordinal) + 1
    }

    /// The last segment a video of this duration has.
    ///
    /// A non-positive or non-finite duration means "not known yet" — a live
    /// clock that has not reported, or a load still in flight — and answers nil
    /// rather than 1. Clamping to a duration nobody measured would cap the
    /// window at the first six minutes of every video whose metadata is late.
    static func lastIndex(duration: TimeInterval, pageSeconds: TimeInterval = segmentSeconds) -> Int? {
        guard duration > 0, duration.isFinite else { return nil }
        let ordinal = (duration / validPageSeconds(pageSeconds)).rounded(.up)
        // Same trap as `index(for:)`, same reason — a duration this app never
        // measured is still a `Double` somebody can hand it.
        guard ordinal < TimeInterval(indexCeiling) else { return indexCeiling }
        return max(1, Int(ordinal))
    }

    /// The segments that belong in memory at `mediaTime`.
    ///
    /// Always the current one. The previous one too, because a small seek back
    /// across a boundary is common and refetching it would show a gap where
    /// bullets had just been. The next one once playback is within
    /// `prefetchLeadSeconds` of needing it.
    static func resident(
        mediaTime: TimeInterval, duration: TimeInterval, pageSeconds: TimeInterval = segmentSeconds
    ) -> Set<Int> {
        let current = index(for: mediaTime, pageSeconds: pageSeconds)
        let last = lastIndex(duration: duration, pageSeconds: pageSeconds)
        var window: Set<Int> = [current]
        if current > 1 { window.insert(current - 1) }

        let segmentEnd = TimeInterval(current) * validPageSeconds(pageSeconds)
        if mediaTime >= segmentEnd - prefetchLeadSeconds {
            let next = current + 1
            if last.map({ next <= $0 }) ?? true { window.insert(next) }
        }
        // A `current` past the end can only come from a clock that outran the
        // duration; keep the window inside the video rather than asking the
        // server for a segment that does not exist.
        if let last { return window.filter { $0 >= 1 && $0 <= last } }
        return window.filter { $0 >= 1 }
    }

    /// Smallest server page size this app segments by. Every observed official
    /// `page_size` is 360000 ms. A tiny one (1 ms) would make `index(for:)` jump
    /// hundreds of segments per tick and request `seg.so` pages that do not
    /// exist, so anything under a minute is treated as no page size at all.
    static let minimumPageSeconds: TimeInterval = 60

    /// A server page size, or nil when it is not one this app segments by —
    /// non-finite, non-positive, or under `minimumPageSeconds`. The only place
    /// that floor is applied: metadata decoding and window arithmetic both ask.
    static func admissiblePageSeconds(_ seconds: TimeInterval) -> TimeInterval? {
        seconds >= minimumPageSeconds && seconds.isFinite ? seconds : nil
    }

    static func validPageSeconds(_ seconds: TimeInterval) -> TimeInterval {
        admissiblePageSeconds(seconds) ?? segmentSeconds
    }

    /// The whole decision, in one value.
    ///
    /// - Parameters:
    ///   - loaded: segment indices currently decoded and in memory.
    ///   - inFlight: segment indices with a request outstanding.
    ///   - blocked: segment indices whose last attempt failed and which may
    ///     not be asked for yet — backing off, cooling down after a round,
    ///     or malformed for this content (`DanmakuSegmentRetryPolicy`).
    ///     Resident but never fetched.
    static func plan(
        mediaTime: TimeInterval,
        duration: TimeInterval,
        loaded: Set<Int>,
        inFlight: Set<Int>,
        blocked: Set<Int> = [],
        pageSeconds: TimeInterval = segmentSeconds
    ) -> DanmakuWindowPlan {
        let resident = resident(mediaTime: mediaTime, duration: duration, pageSeconds: pageSeconds)
        return DanmakuWindowPlan(
            resident: resident,
            // Subtracting `inFlight` is what stops a per-tick plan from firing
            // the same request every tick for the whole of a slow fetch.
            // Subtracting `blocked` is the same rule for a request that already
            // came back failed: without it the next 4Hz tick asked again, with
            // no backoff, for as long as the segment stayed resident (D1).
            fetch: resident.subtracting(loaded).subtracting(inFlight).subtracting(blocked),
            evict: loaded.subtracting(resident),
            cancel: inFlight.subtracting(resident)
        )
    }
}
