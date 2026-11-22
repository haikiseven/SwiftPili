import Foundation

struct DanmakuSessionIdentity: Equatable, Sendable {
    let oid: Int
    let owner: String
}

struct DanmakuSessionLedger: Equatable, Sendable {
    enum Admission: Equatable, Sendable {
        case continuing
        case resumed
        case fresh
    }

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

    static let retentionTTL: TimeInterval = 90

    private(set) var retained: DanmakuSessionIdentity?
    private(set) var isLive = false
    private(set) var suspendedAt: TimeInterval?

    var live: DanmakuSessionIdentity? { isLive ? retained : nil }

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

    mutating func suspend(at now: TimeInterval) {
        if isLive, retained != nil { suspendedAt = now }
        isLive = false
    }

    mutating func release() {
        retained = nil
        isLive = false
        suspendedAt = nil
    }

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
