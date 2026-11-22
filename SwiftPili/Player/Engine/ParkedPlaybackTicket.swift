import Foundation

struct ParkedPlaybackTicket: Equatable, Sendable {
    let identity: String
    let position: TimeInterval
    let parkedAt: ContinuousClock.Instant

    enum ClaimDecision: Equatable, Sendable {
        case claim
        case expiredTTL
        case identityMismatch
    }

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
        guard parkedAt.duration(to: now) <= ttl else { return .expiredTTL }
        return .claim
    }

    func ageMilliseconds(now: ContinuousClock.Instant) -> Int {
        Int(parkedAt.duration(to: now) / .milliseconds(1))
    }
}
