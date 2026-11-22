import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    // MARK: - Ownership

    static func vodOwner(_ id: VideoID) -> String { "vod-\(id.queryParam)" }
    static func liveOwner(_ roomID: Int) -> String { "live-\(roomID)" }
    static func pgcOwner(_ seasonId: Int) -> String { "pgc-\(seasonId)" }

    /// Called BEFORE loadVOD/loadLive; internal reloads (CDN fallback, decoder recovery, quality switch) keep
    /// the existing claim. stop() deliberately does NOT clear it — it runs inside loadVOD after the new screen
    /// has already claimed.
    func claim(owner: String) {
        if ownerKey != owner { mediaResetRecovery.invalidate() }
        // A screen (re)taking ownership restores the recovery budget — UNCONDITIONALLY, because re-entering
        // the same video keeps the same ownerKey.
        resetRecoveryBudget()
        cdnFallbackActive = false
        if ownerKey != owner {
            suspendDanmakuVisibleWork()
            // A same-owner claim lands inside the 32ms window after a seek or CDN cover is installed.
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
            // A different screen/content owner must not inherit the previous video's decoration while its own
            // cover metadata is still loading.
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

    /// Claim from a newly-created screen instance. Unlike internal reloads
    /// that reuse `claim(owner:)`, this advances an exit lease even when the
    /// replacement screen displays the same logical content.
    func claimOwnerLease(owner: String) -> PlayerOwnerLease {
        retireFullscreenPresentation()
        let retainsRunningSession = !ownerKey.isEmpty
            && ownerKey == owner
            && currentOwnerLease != nil
        // Detaching here would take the only picture off the page that is still showing it.
        if !retainsRunningSession {
            invalidateSurfaceSlot(reason: "owner-lease-replacement")
        }
        mediaResetRecovery.invalidate()
        // A replacement screen for the SAME owner may keep the running session (`playOffline`'s same-asset
        // branch does exactly that, so no loader — and therefore no `playURL`, the sole installer — runs).
        let keepsRunningSession = ownerKey == owner
        let outgoingOwner = currentOwnerLease
        // A new screen lease is a new handoff authority, even for the same aid/cid.
        playerInfoHandoffPolicy.invalidate()
        pendingPlayerInfo = nil
        claim(owner: owner)
        if let recoveryCover { clearRecoveryCover(matching: recoveryCover.identity) }
        retireCDNFrameCover()
        ownerLeaseGeneration &+= 1
        if keepsRunningSession, let outgoingOwner {
            // A replacement screen with the same logical owner still receives
            // a new lease. Do not let the previous screen's commands survive
            // until its asynchronous load tail installs the successor card.
            _ = NowPlayingCenter.shared.deactivate(owner: outgoingOwner)
        }
        // A same-source screen replacement may keep the shared backend/session
        // alive. Fence the detector immediately instead of waiting for a load
        // generation to change.
        updateDemandVideoLivenessContext()
        lifecycleRecoveryTask?.cancel()
        lifecycleRecovery.invalidate()
        invalidateLifecycleReadiness()
        if keepsRunningSession {
            decoderRecoveryAdmission.install(decoderRecoveryContext())
        }
        // Either way no in-flight ticket survives a new screen lease: `install`
        // drops one whose lease no longer matches, and `claim` invalidated the
        // whole admission when the owner changed.
        nonLifecycleRecoveryTicket = nil
        deferredPiPOwnerExit.cancel()
        installEqualizerMaintenanceAdmission()
        return PlayerOwnerLease(owner: owner, generation: ownerLeaseGeneration)
    }

    /// Only the current owner may exit. An observed PiP lease or active presentation can retain playback.
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
        lease.matches(
            currentOwner: ownerKey,
            currentGeneration: ownerLeaseGeneration
        )
    }

    /// Only the current owner may exit. An observed PiP lease or active presentation can retain playback.
    @discardableResult
    func endOwnerPlayback(owner: String) -> PlayerOwnerExitOutcome {
        guard ownerKey == owner else { return .ownershipEnded }
        // Coverage is decided BEFORE any surface/token mutation. Only the
        // exact registered screen/controller may retain this owner lease.
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
        // A refusal is the normal stop.
        if mode == .vod, backend.parkForReuse() {
            PlayerLog.log("[Player] owner exit parking session owner=\(owner)")
            stop(reason: .ownerExit, preservingParkedBackend: true)
            ownerKey = ""
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

    /// Navigation-level exits do not always know the current screen's owner.
    func endCurrentOwnerPlayback() {
        guard !ownerKey.isEmpty else { return }
        endOwnerPlayback(owner: ownerKey)
    }

    /// The incoming page no longer takes the player at the path write — it waits for its transition to finish —
    /// so without this the departing video's audio would keep running under its frozen route still for the
    /// whole push/pop animation.
    @discardableResult
    func pauseForRouteDeparture(lease: PlayerOwnerLease?) -> Bool {
        guard let lease, isCurrentOwner(lease) else { return false }
        // Already silent: a user or system pause owns the transport, and
        // rewriting a `.pausedBySystem` would break the interruption's resume.
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

    /// The incoming detail page is about to claim the player after its transition completed.
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

/// The only physical render destination allowed to bind the shared backend.
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

/// One exact lease owns the render surface; stale releases cannot revoke a successor.
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
}

@MainActor
protocol PlayerRenderAttachment: AnyObject {
    func attach(hostedVC: UIViewController?, generation: Int)
    /// Apply a presentation-only shape synchronously to the current inline
    /// host. This is separate from `attach`: SwiftUI may deliver the visual
    /// update after a native PiP stop request has already started.
    func setPresentationCornerRadius(_ radius: CGFloat)
    func installRecoveryCover(_ image: UIImage, identity: UInt64) -> PlayerRecoveryCoverMount
    func removeRecoveryCover(identity: UInt64)
    var presentationSnapshot: PlayerRenderAttachmentSnapshot { get }
    /// Geometry of this native container, explicitly in its own screen space.
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
