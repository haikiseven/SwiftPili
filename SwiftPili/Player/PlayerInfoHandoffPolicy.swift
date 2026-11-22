import Foundation

struct PlayerInfoHandoffToken: Hashable, Sendable {
    let requestID: UInt64
    let aid: Int
    let cid: Int
    let owner: String
    let ownerLeaseGeneration: UInt64
}

struct PlayerInfoHandoffPolicy: Sendable {
    private(set) var nextRequestID: UInt64 = 0
    private(set) var activeToken: PlayerInfoHandoffToken?

    mutating func issue(
        aid: Int,
        cid: Int,
        owner: String,
        ownerLeaseGeneration: UInt64
    ) -> PlayerInfoHandoffToken? {
        guard !owner.isEmpty, ownerLeaseGeneration > 0 else { return nil }
        nextRequestID &+= 1
        let token = PlayerInfoHandoffToken(
            requestID: nextRequestID,
            aid: aid,
            cid: cid,
            owner: owner,
            ownerLeaseGeneration: ownerLeaseGeneration
        )
        activeToken = token
        return token
    }

    mutating func consume(
        _ token: PlayerInfoHandoffToken,
        aid: Int,
        cid: Int,
        currentOwner: String,
        currentOwnerLeaseGeneration: UInt64,
        isScreenLoad: Bool
    ) -> Bool {
        guard isScreenLoad,
              token == activeToken,
              token.aid == aid,
              token.cid == cid,
              token.owner == currentOwner,
              token.ownerLeaseGeneration == currentOwnerLeaseGeneration
        else { return false }
        activeToken = nil
        return true
    }

    mutating func invalidate() {
        activeToken = nil
    }
}
