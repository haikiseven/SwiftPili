import Foundation

struct MuteAuthority: Equatable {
    enum Reason: String, CaseIterable, Sendable {
        case sponsorSegment
        case seekTravel
    }

    private(set) var reasons: Set<Reason> = []

    var isMuted: Bool { !reasons.isEmpty }

    func holds(_ reason: Reason) -> Bool { reasons.contains(reason) }

    mutating func set(_ reason: Reason, active: Bool) -> Bool? {
        let before = isMuted
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        return isMuted == before ? nil : isMuted
    }

    mutating func releaseAll() -> Bool? {
        let before = isMuted
        reasons.removeAll()
        return isMuted == before ? nil : isMuted
    }

    var reasonsDescription: String {
        reasons.isEmpty
            ? "none"
            : Reason.allCases.filter(reasons.contains).map(\.rawValue).joined(separator: "+")
    }
}
