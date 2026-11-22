import Foundation

/// Whose danmaku these are: the part (`cid`, the `seg.so` oid) and the logical
/// player owner that admitted it.
///
/// The owner is the logical key (`PlayerViewModel.vodOwner` /
/// `pgcOwner`), deliberately NOT the lease generation. Leaving a video and
/// re-entering the same one claims a fresh lease under the same owner key,
/// and that re-entry is one of the reloads that must keep its segments (D3).
/// A different owner playing the same cid (a PGC episode opened as a plain
/// video) is a different screen's content and starts clean.
struct DanmakuSessionIdentity: Equatable, Sendable {
    let oid: Int
    let owner: String
}

/// The single authority on whether danmaku may fetch, and whether a store that
/// survived a `stop()` still belongs to what is playing now.
///
/// **Why this exists (D2).** The clock edge used to gate on the feature switch,
/// the mode and `currentCid` only — and `stop()` keeps `currentCid`. So any
/// `UserDefaults` write, or an overlay resize, arriving after a stop rebuilt the
/// store and fetched segment 1 for content that was no longer playing (device
/// run4, +5096.042). The fix is an identity with one writer:
///
/// - `admit` — called only from `PlayerViewModel.playURL`, the last boundary
///   before a stream opens, for `.vod` with a cid. Every VOD/PGC stream,
///   including a loop restart or seek reopen, passes through it.
/// - `suspend` — called only from `stop()`. The session is no longer live:
///   nothing may create a store, fetch, or admit bullets until the next
///   `admit`. What was already fetched is retained, inert.
/// - `release` — content is gone for good (mode left VOD, cid cleared).
///
/// Everything else — the defaults observer, the resize path, a sink attach —
/// may only ask `liveSession(for:)`, and gets nil after a stop.
///
/// **Why the store survives a suspend (D3).** A quality/codec switch, a
/// lifecycle or media-services reload, an expired-URL loop restart and a
/// same-video re-entry all run `stop()` and then open the SAME content again;
/// releasing on stop refetched segment 1 five times in 62s for one video
/// (baseline capture). The next `admit` adjudicates instead: same identity →
/// `.resumed`, keep the segments and realign seek-style; anything else →
/// `.fresh`, release first. A different content therefore never sees the old
/// content's bullets, and the retained data is bounded by the ±1 window (three
/// segments) whatever happens in between.
///
/// **A retention is a cache, and caches are evictable (A4a).** A suspended
/// retention is dropped by memory pressure and after `retentionTTL` without a
/// re-admission — the same 90s a parked Demand playback session lives
/// (`DemandPacedPlayerBackend.parkTTL`, private to that file). Past that, the
/// reload the retention exists for is not happening, and a re-entry is a new
/// visit that may as well fetch fresh. A LIVE session is never evicted by
/// either: its segments are the ones on screen.
struct DanmakuSessionLedger: Equatable, Sendable {
    enum Admission: Equatable, Sendable {
        /// Same identity, already live: a loop restart on a fresh URL or a
        /// seek reopen. A changed explicit opening position arms realignment.
        case continuing
        /// Same identity, suspended by `stop()` within the TTL: keep the
        /// retained store and realign at the open position — a seek, not a
        /// new session.
        case resumed
        /// Nothing retained, a different content or owner, or a retention
        /// past its TTL: release whatever is retained and start clean.
        case fresh
    }

    /// Why a suspended retention was dropped.
    enum Eviction: Equatable, Sendable, CustomStringConvertible {
        case memoryPressure
        case expired

        var description: String {
            switch self {
            case .memoryPressure: "memory pressure"
            case .expired: "ttl expired"
            }
        }
    }

    /// Mirrors `DemandPacedPlayerBackend.parkTTL`; see the type comment.
    static let retentionTTL: TimeInterval = 90

    /// The identity the retained store (if any) belongs to. Survives a
    /// suspend; cleared by `release`, by an eviction, or replaced by a
    /// `.fresh` admit.
    private(set) var retained: DanmakuSessionIdentity?
    private(set) var isLive = false
    /// Monotonic seconds at which the live session was suspended; nil while
    /// live or when nothing is retained.
    private(set) var suspendedAt: TimeInterval?

    /// The identity allowed to create a store, fetch and admit right now.
    var live: DanmakuSessionIdentity? { isLive ? retained : nil }

    /// The live session, if it is `currentOID`'s. The single question every
    /// clock edge — tick, defaults write, resize, sink attach — asks before it
    /// may create a store or fetch; nil after `stop()` although the player
    /// still remembers the cid (D2).
    func liveSession(for currentOID: Int?) -> DanmakuSessionIdentity? {
        guard let live, live.oid == currentOID else { return nil }
        return live
    }

    mutating func admit(_ incoming: DanmakuSessionIdentity, at now: TimeInterval) -> Admission {
        let expired = !isLive && isPastTTL(at: now)
        defer {
            retained = incoming
            isLive = true
            suspendedAt = nil
        }
        guard retained == incoming, !expired else { return .fresh }
        return isLive ? .continuing : .resumed
    }

    /// Idempotent: a route handoff stops twice, and the second stop must not
    /// restart the TTL of the first.
    mutating func suspend(at now: TimeInterval) {
        if isLive, retained != nil { suspendedAt = now }
        isLive = false
    }

    mutating func release() {
        retained = nil
        isLive = false
        suspendedAt = nil
    }

    /// Drops a suspended retention for `reason`. Returns the dropped identity,
    /// or nil when there is nothing to drop: a live session (never evicted),
    /// nothing retained, or — for `.expired` — a retention still inside its
    /// TTL (a late timer from an earlier suspend lands here harmlessly).
    mutating func evictRetained(_ reason: Eviction, at now: TimeInterval) -> DanmakuSessionIdentity? {
        guard !isLive, let dropped = retained else { return nil }
        if reason == .expired, !isPastTTL(at: now) { return nil }
        release()
        return dropped
    }

    private func isPastTTL(at now: TimeInterval) -> Bool {
        suspendedAt.map { now - $0 >= Self.retentionTTL } ?? false
    }
}
