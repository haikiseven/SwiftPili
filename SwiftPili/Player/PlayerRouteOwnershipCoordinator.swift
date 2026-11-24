import Foundation
import Observation
import UIKit

/// Coordinates playback route ownership, multi-window single-audio-focus scene handoff,
/// surface lease tracking, and outgoing route transition stills.
@MainActor
@Observable
final class PlayerRouteOwnershipCoordinator {
    struct SceneOwnershipClaimResult: Equatable, Sendable {
        let lease: PlayerOwnerLease
        let previousOwner: String?
        let previousSceneID: UUID?
        let didTransferScene: Bool
    }

    var ownerKey = ""
    var ownerLeaseGeneration: UInt64 = 0

    /// The scene that currently holds the active playback lease across iPad multi-window setups.
    /// When a second window claims playback, `activeSceneID` transfers to the new window so the
    /// prior window cleanly yields to its static cover placeholder without audio/canvas collision.
    var activeSceneID: UUID?

    @ObservationIgnored
    var presentationResetPendingForOwnerChange = false

    var surfaceAuthority = PlayerSurfaceAuthority()
    var activeSurfaceLease: PlayerSurfaceLease?
    var deferredPiPOwnerExit = DeferredPiPOwnerExit()
    var playerGeneration = 0
    var inlineReturnTarget: PlayerInlineReturnTarget?

    var outgoingRouteStills: [String: UIImage] = [:]
    @ObservationIgnored
    var outgoingRouteStillTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    var departedRouteStillOwners: [String] = []

    var currentOwnerLease: PlayerOwnerLease? {
        guard !ownerKey.isEmpty else { return nil }
        return PlayerOwnerLease(owner: ownerKey, generation: ownerLeaseGeneration)
    }

    func ownsScene(_ sceneID: UUID?) -> Bool {
        guard let sceneID, let activeSceneID else { return true }
        return activeSceneID == sceneID
    }

    func isCurrentOwner(_ lease: PlayerOwnerLease, in sceneID: UUID? = nil) -> Bool {
        guard lease.matches(currentOwner: ownerKey, currentGeneration: ownerLeaseGeneration) else {
            return false
        }
        return ownsScene(sceneID)
    }

    @discardableResult
    func claimOwnership(owner: String, sceneID: UUID? = nil) -> SceneOwnershipClaimResult {
        let previousOwner = ownerKey.isEmpty ? nil : ownerKey
        let previousSceneID = activeSceneID
        let didTransferScene = previousSceneID != nil && sceneID != nil && previousSceneID != sceneID
        ownerKey = owner
        ownerLeaseGeneration &+= 1
        activeSceneID = sceneID
        let lease = PlayerOwnerLease(owner: owner, generation: ownerLeaseGeneration)
        return SceneOwnershipClaimResult(
            lease: lease,
            previousOwner: previousOwner,
            previousSceneID: previousSceneID,
            didTransferScene: didTransferScene
        )
    }

    func bindActiveSceneIfUnbound(_ sceneID: UUID?) {
        guard let sceneID, activeSceneID == nil, !ownerKey.isEmpty else { return }
        activeSceneID = sceneID
    }

    func releaseOwnership(matchingSceneID sceneID: UUID? = nil) {
        if let sceneID, let activeSceneID, activeSceneID != sceneID {
            return
        }
        ownerKey = ""
        activeSceneID = nil
    }
}
