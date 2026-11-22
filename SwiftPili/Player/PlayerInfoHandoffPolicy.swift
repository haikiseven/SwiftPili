import Foundation

/// Identity for the one screen-start load that is allowed to consume a
/// player-info response fetched by the resume lookup.
///
/// The request id distinguishes two loads of the same aid/cid. The owner and
/// lease generation bind it to the screen instance that asked for the lookup;
/// an ownerless internal reload can therefore never consume the response.
struct PlayerInfoHandoffToken: Hashable, Sendable {
    let requestID: UInt64
    let aid: Int
    let cid: Int
    let owner: String
    let ownerLeaseGeneration: UInt64
}

/// Pure admission policy for the `x/player/wbi/v2` handoff.
///
/// The response itself is retained by `PlayerViewModel`; this type owns only
/// the identity/fence. Keeping the decision pure makes same-content reloads,
/// stale screen leases, and one-shot consumption executable without a
/// network request or a ViewModel fixture.
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

    /// Consume only from the exact screen-start load and exact owner lease.
    /// `isScreenLoad == false` is the explicit guard for quality/CDN/recovery
    /// reloads, even when they target the same content and owner.
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
