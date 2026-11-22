import Foundation

/// Identity + validity for ONE parked Demand playback session.
///
/// Exiting the player no longer has to destroy a reusable session: the backend
/// parks it under this ticket, and the next `load` claims it — skipping
/// `open()`, the demux rebuild, and the decoder bring-up — when, and only
/// when, the ticket says the parked state still answers for the requested
/// playback. Everything here is a pure decision over values, deliberately
/// compilable into the off-device harness exactly as shipped.
///
/// Identity is PATH-canonical: a re-entered video refetches playurl, so the
/// host and the signed query routinely change (CDN re-pick, fresh signature)
/// while the upos PATH still names the exact resource — cid, quality, codec.
/// The load-shaping parameters that outlive the URL (decoder mode, buffer
/// depth) are folded in, so a Settings change between exit and re-entry
/// invalidates the park instead of resuming into a mismatched pipeline.
struct ParkedPlaybackTicket: Equatable, Sendable {
    let identity: String
    /// The session's media position at park time — becomes the claimed
    /// load's `openedAtPosition`, which is what lets the ViewModel's
    /// loaded-at-target logic skip the restore seek.
    let position: TimeInterval
    let parkedAt: ContinuousClock.Instant

    enum ClaimDecision: Equatable, Sendable {
        case claim
        case expiredTTL
        case identityMismatch
    }

    /// The existing same-stream key. Only callers already qualified by the
    /// parked-content and account boundaries may ignore delivery credentials.
    static func streamIdentity(of url: URL) -> String { url.path }

    static func identity(
        videoURL: URL,
        audioURL: URL?,
        hardwareDecode: Bool,
        preferNativeVideoToolbox: Bool,
        maxBuffer: TimeInterval
    ) -> String {
        let audio = audioURL.map { streamIdentity(of: $0) } ?? "-"
        return "\(streamIdentity(of: videoURL))|\(audio)" +
            "|hw=\(hardwareDecode ? 1 : 0)" +
            "|vt=\(preferNativeVideoToolbox ? 1 : 0)" +
            "|buf=\(Int(maxBuffer.rounded()))"
    }

    func decision(
        for identity: String,
        now: ContinuousClock.Instant,
        ttl: Duration
    ) -> ClaimDecision {
        guard identity == self.identity else { return .identityMismatch }
        // TTL keeps the claim inside the window where the parked session's
        // signed URLs, decoder state, and banked content are still trustworthy
        // — beyond it, a cold reopen is the honest path.
        guard parkedAt.duration(to: now) <= ttl else { return .expiredTTL }
        return .claim
    }

    func ageMilliseconds(now: ContinuousClock.Instant) -> Int {
        Int(parkedAt.duration(to: now) / .milliseconds(1))
    }
}
