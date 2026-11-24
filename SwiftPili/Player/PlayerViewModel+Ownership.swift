import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    // MARK: - Ownership

    static func vodOwner(_ id: VideoID) -> String { "vod-\(id.queryParam)" }
    static func liveOwner(_ roomID: Int) -> String { "live-\(roomID)" }
    static func pgcOwner(_ seasonId: Int) -> String { "pgc-\(seasonId)" }

    func claim(owner: String) {
        if ownerKey != owner { mediaResetRecovery.invalidate() }
        resetRecoveryBudget()
        cdnFallbackActive = false
        if ownerKey != owner {
            hasRenderedFirstFrame = false
            suspendDanmakuVisibleWork()
            clearFreezeFrame()
            if let outgoingOwner = currentOwnerLease {
                _ = NowPlayingCenter.shared.deactivate(owner: outgoingOwner)
            }
            presentationResetPendingForOwnerChange = true
            lifecycleRecoveryTask?.cancel()
            lifecycleRecovery.invalidate()
            invalidateLifecycleReadiness()
            decoderRecoveryAdmission.invalidate()
            nonLifecycleRecoveryTicket = nil
            deferredPiPOwnerExit.cancel()
            PlayerLog.log("[Player] render view claimed by \(owner) (was \(ownerKey.isEmpty ? "-" : ownerKey))")
            ownerKey = owner
            ambientCoverURL = nil
            ambientStoryboardRequest = nil
            ambientStoryboardLoader.retire(keepingArtwork: false)
            retireAmbientSelection()
            ambientOwnerLease = nil
            ambientStoryboard = []
            ambientStoryboardOwnerLease = nil
            ambientStoryboardLoadGeneration = nil
            ambientStoryboardContent = nil
            ambientSelectionMediaTime = nil
        }
    }

    func claimOwnerLease(owner: String) -> PlayerOwnerLease {
        claimOwnerLease(owner: owner, sceneID: nil)
    }

    func claimOwnerLease(owner: String, sceneID: UUID?) -> PlayerOwnerLease {
        retireFullscreenPresentation()
        let outgoingOwner = currentOwnerLease
        let retainsRunningSession = !ownerKey.isEmpty
            && ownerKey == owner
            && outgoingOwner != nil
            && (sceneID == nil || routeOwnership.activeSceneID == nil || routeOwnership.activeSceneID == sceneID)
        if !retainsRunningSession {
            hasRenderedFirstFrame = false
            invalidateSurfaceSlot(reason: "owner-lease-replacement")
        }
        mediaResetRecovery.invalidate()
        let keepsRunningSession = ownerKey == owner
        playerInfoHandoffPolicy.invalidate()
        pendingPlayerInfo = nil
        claim(owner: owner)
        if let recoveryCover { clearRecoveryCover(matching: recoveryCover.identity) }
        retireCDNFrameCover()
        ownerLeaseGeneration &+= 1
        routeOwnership.activeSceneID = sceneID
        let incomingOwner = PlayerOwnerLease(owner: owner, generation: ownerLeaseGeneration)
        if retainsRunningSession {
            upgradeOrInvalidateSurfaceSlot(from: outgoingOwner, to: incomingOwner)
        }
        if keepsRunningSession, let outgoingOwner {
            _ = NowPlayingCenter.shared.deactivate(owner: outgoingOwner)
        }
        updateDemandVideoLivenessContext()
        lifecycleRecoveryTask?.cancel()
        lifecycleRecovery.invalidate()
        invalidateLifecycleReadiness()
        if keepsRunningSession {
            decoderRecoveryAdmission.install(decoderRecoveryContext())
        }
        nonLifecycleRecoveryTicket = nil
        deferredPiPOwnerExit.cancel()
        installEqualizerMaintenanceAdmission()
        return incomingOwner
    }

    @discardableResult
    func endOwnerPlayback(lease: PlayerOwnerLease) -> PlayerOwnerExitOutcome {
        guard lease.matches(
            currentOwner: ownerKey,
            currentGeneration: ownerLeaseGeneration
        ) else {
            PlayerLog.log(
                "[Player] stale owner exit ignored owner=\(lease.owner) " +
                "leaseGen=\(lease.generation) currentGen=\(ownerLeaseGeneration)"
            )
            return .ownershipEnded
        }
        return endOwnerPlayback(owner: lease.owner)
    }

    func isCurrentOwner(_ lease: PlayerOwnerLease) -> Bool {
        routeOwnership.isCurrentOwner(lease, in: nil)
    }

    func isCurrentOwner(_ lease: PlayerOwnerLease, in sceneID: UUID?) -> Bool {
        routeOwnership.isCurrentOwner(lease, in: sceneID)
    }

    @discardableResult
    func endOwnerPlayback(owner: String) -> PlayerOwnerExitOutcome {
        guard ownerKey == owner else { return .ownershipEnded }
        let coverage = fullscreenPresentation?.coverage ?? .none
        if coverage.retainsLease,
           fullscreenPresentationReceipt?.context.ownerLease == currentOwnerLease {
            PlayerLog.log("[Player] owner retained by exact fullscreen presentation owner=\(owner)")
            return .leaseRetained
        }
        invalidateSurfaceSlot(reason: "owner-exit")
        clearPlayerInfoHandoff(matching: currentOwnerLease)
        if PlayerOwnerExitPolicy.shouldKeepPlayback(
            ownerMatches: true,
            hasObservedPiPLease: backend.hasObservedPiPLease,
            playerPresentationIsOnScreen: false,
            configuration: PlayerPlaybackPreferences.playbackContinuationConfiguration
        ) {
            deferredPiPOwnerExit.preserve(owner: owner)
            PlayerLog.log("[Player] owner exit preserved by observed PiP lease owner=\(owner)")
            return .ownershipEnded
        }
        deferredPiPOwnerExit.cancel()
        lifecycleRecoveryTask?.cancel()
        if backend.isPiPActive || backend.hasObservedPiPLease {
            if usesDemandPresentationContinuity {
                let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
                if let fence = makeDemandPresentationFence(epoch: epoch) {
                    dispatchDemandPresentation(.forceRetirePiP(
                        fence: fence,
                        authority: .ownerTeardown
                    ))
                } else {
                    backend.forceRetireDemandPiP()
                }
            } else {
                PlayerLog.log(
                    "[Player] owner exit dismissing unleased raw PiP owner=\(owner)"
                )
                backend.stopPiP()
            }
        }
        lifecycleRecovery.invalidate()
        if mode == .vod, backend.parkForReuse() {
            PlayerLog.log("[Player] owner exit parking session owner=\(owner)")
            stop(reason: .ownerExit, preservingParkedBackend: true)
            ownerKey = ""
            routeOwnership.activeSceneID = nil
            ambientCoverURL = nil
            ambientOwnerLease = nil
            ambientStoryboard = []
            ambientStoryboardOwnerLease = nil
            ambientStoryboardLoadGeneration = nil
            ambientStoryboardContent = nil
            ambientSelectionMediaTime = nil
            return .ownershipEnded
        }
        PlayerLog.log("[Player] owner exit stopping owner=\(owner)")
        stop(reason: .ownerExit)
        ownerKey = ""
        routeOwnership.activeSceneID = nil
        ambientCoverURL = nil
        ambientOwnerLease = nil
        ambientStoryboard = []
        ambientStoryboardOwnerLease = nil
        ambientStoryboardLoadGeneration = nil
        ambientStoryboardContent = nil
        ambientSelectionMediaTime = nil
        return .ownershipEnded
    }

    func handleObservedPiPLeaseChange(_ active: Bool) {
        reconcileAmbientStoryboard(allowWork: !active)
        updateDemandVideoLivenessContext()
        guard !active else { return }
        guard let owner = deferredPiPOwnerExit.consumeLeaseEnd(currentOwner: ownerKey) else {
            return
        }
        PlayerLog.log("[Player] observed PiP lease ended — completing deferred owner exit owner=\(owner)")
        endOwnerPlayback(owner: owner)
    }

    func endCurrentOwnerPlayback() {
        guard !ownerKey.isEmpty else { return }
        endOwnerPlayback(owner: ownerKey)
    }

    @discardableResult
    func pauseForRouteDeparture(lease: PlayerOwnerLease?) -> Bool {
        guard let lease, isCurrentOwner(lease) else { return false }
        guard playbackIntent == .playing else { return false }
        if PlayerOwnerExitPolicy.shouldKeepPlayback(
            ownerMatches: true,
            hasObservedPiPLease: backend.hasObservedPiPLease,
            playerPresentationIsOnScreen: fullscreenPresentation?.coverage.retainsLease == true,
            configuration: PlayerPlaybackPreferences.playbackContinuationConfiguration
        ) {
            PlayerLog.log("[Route] departing owner kept playing owner=\(lease.owner) (PiP/presentation)")
            return false
        }
        PlayerLog.log("[Route] departing owner paused owner=\(lease.owner)")
        pause()
        return true
    }

    func endForeignOwnerForRouteActivation(incomingOwner: String) {
        guard !ownerKey.isEmpty, ownerKey != incomingOwner else { return }
        PlayerLog.log("[Route] ending departing owner=\(ownerKey) before incoming=\(incomingOwner) claims")
        endOwnerPlayback(owner: ownerKey)
    }
}

struct PlayerOwnerLease: Equatable, Sendable {
    let owner: String
    let generation: UInt64

    func matches(currentOwner: String, currentGeneration: UInt64) -> Bool {
        owner == currentOwner && generation == currentGeneration
    }
}

enum PlayerSurfaceRole: String, Equatable, Sendable {
    case inline
    case fullscreen
}

struct PlayerSurfaceLease: Equatable, Sendable {
    let ownerLease: PlayerOwnerLease
    let token: UInt64
    let role: PlayerSurfaceRole

    func matches(_ other: PlayerSurfaceLease) -> Bool {
        self == other
    }
}

struct PlayerSurfaceAuthority: Equatable, Sendable {
    private(set) var active: PlayerSurfaceLease?
    private var nextToken: UInt64 = 0

    mutating func claim(
        ownerLease: PlayerOwnerLease,
        role: PlayerSurfaceRole
    ) -> PlayerSurfaceLease? {
        if let active {
            guard active.ownerLease == ownerLease, active.role == role else {
                return nil
            }
            return active
        }
        nextToken &+= 1
        let lease = PlayerSurfaceLease(
            ownerLease: ownerLease,
            token: nextToken,
            role: role
        )
        active = lease
        return lease
    }

    mutating func handoff(
        ownerLease: PlayerOwnerLease,
        to role: PlayerSurfaceRole
    ) -> PlayerSurfaceLease? {
        guard let active,
              active.ownerLease == ownerLease
        else { return nil }
        guard active.role != role else { return active }
        nextToken &+= 1
        let lease = PlayerSurfaceLease(
            ownerLease: ownerLease,
            token: nextToken,
            role: role
        )
        self.active = lease
        return lease
    }

    @discardableResult
    mutating func release(_ lease: PlayerSurfaceLease) -> Bool {
        guard active == lease else { return false }
        active = nil
        return true
    }

    @discardableResult
    mutating func invalidate(ownerLease: PlayerOwnerLease? = nil) -> Bool {
        guard let active,
              ownerLease == nil || active.ownerLease == ownerLease
        else { return false }
        self.active = nil
        return true
    }

    mutating func rekeyOrInvalidate(
        from outgoing: PlayerOwnerLease,
        to incoming: PlayerOwnerLease,
        hasAttachment: Bool
    ) -> PlayerSurfaceLease? {
        guard let active, active.ownerLease == outgoing, hasAttachment else {
            self.active = nil
            return nil
        }
        nextToken &+= 1
        let upgraded = PlayerSurfaceLease(
            ownerLease: incoming,
            token: nextToken,
            role: active.role
        )
        self.active = upgraded
        return upgraded
    }
}

@MainActor
protocol PlayerRenderAttachment: AnyObject {
    func attach(hostedVC: UIViewController?, generation: Int)
    func setPresentationCornerRadius(_ radius: CGFloat)
    func installRecoveryCover(_ image: UIImage, identity: UInt64) -> PlayerRecoveryCoverMount
    func removeRecoveryCover(identity: UInt64)
    var presentationSnapshot: PlayerRenderAttachmentSnapshot { get }
    var frameInScreen: (rect: CGRect, window: UIWindow)? { get }
}

extension PlayerRenderAttachment where Self: UIView {
    var frameInScreen: (rect: CGRect, window: UIWindow)? {
        guard let window, presentationSnapshot.isVisible else { return nil }
        return (convert(bounds, to: window.screen.coordinateSpace), window)
    }
}

struct PlayerRenderAttachmentSnapshot: Equatable {
    let renderGeneration: Int?
    let isAttached: Bool
    let isVisible: Bool
    let boundsUsable: Bool
}
