import AVFoundation
import Foundation
import UIKit

/// Records the window identity and placement that produced a screen-space frame.
struct PlayerWindowGeometry: Equatable {
    let windowID: ObjectIdentifier
    let screenID: ObjectIdentifier
    let frameInScreen: CGRect

    @MainActor
    init?(window: UIWindow) {
        let frame = window.convert(window.bounds, to: window.screen.coordinateSpace)
        guard !window.isHidden, frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 1, frame.height > 1 else { return nil }
        windowID = ObjectIdentifier(window)
        screenID = ObjectIdentifier(window.screen)
        frameInScreen = frame
    }
}

struct PlayerInlineReturnTarget: Equatable {
    let frameInScreen: CGRect
    let window: PlayerWindowGeometry
    let receipt: PlayerPresentationReceipt
}

extension PlayerViewModel {

    /// The ONE place render identity advances, and the reason it advanced.
    func advanceGeneration(_ reason: String) {
        playerGeneration &+= 1
        PlayerLog.log("[Generation] \(playerGeneration - 1)→\(playerGeneration) why=\(reason)")
    }

    /// Native layout callbacks cannot publish a retired or fullscreen container
    /// as the inline return slot, even during the exit's isFullscreen=false span.
    func noteInlineVideoRect(from attachment: any PlayerRenderAttachment) {
        guard !isFullscreen, renderAttachment === attachment,
              let lease = renderAttachmentSurfaceLease,
              lease == activeSurfaceLease, lease.role == .inline,
              let presentation = fullscreenPresentation,
              let receipt = fullscreenPresentationReceipt,
              receipt.context.ownerLease == lease.ownerLease,
              isCurrentPresentation(presentation, receipt: receipt)
        else { return }
        guard let measured = attachment.frameInScreen,
              let window = PlayerWindowGeometry(window: measured.window),
              measured.rect.minX.isFinite, measured.rect.minY.isFinite,
              measured.rect.width.isFinite, measured.rect.height.isFinite,
              measured.rect.width > 1, measured.rect.height > 1 else {
            if inlineReturnTarget != nil { inlineReturnTarget = nil }
            return
        }
        let target = PlayerInlineReturnTarget(frameInScreen: measured.rect, window: window, receipt: receipt)
        if inlineReturnTarget != target { inlineReturnTarget = target }
    }

    /// Ancestor scrolling/window movement need not resize the native container.
    /// SwiftUI geometry is only a trigger; UIKit owns the measured coordinates.
    func refreshInlineVideoRect() {
        guard let attachment = renderAttachment else { return }
        noteInlineVideoRect(from: attachment)
    }

    func inlineVideoRect(
        for receipt: PlayerPresentationReceipt,
        hostIdentity: UUID,
        window: PlayerWindowGeometry?
    ) -> CGRect? {
        guard !isFullscreen, isCurrentPresentationReceipt(receipt, hostIdentity: hostIdentity),
              let target = inlineReturnTarget, let window,
              target.receipt == receipt,
              target.window.windowID == window.windowID,
              target.window.screenID == window.screenID else { return nil }
        // The phone deliberately parks toward its pre-entry portrait target
        // while the same window rotates back. iPad never forces that rotation:
        // a moved/resized window needs a fresh returning inline measurement.
        if UIDevice.current.userInterfaceIdiom == .pad, target.window != window { return nil }
        return target.frameInScreen
    }

    /// This is intentionally separate from Route/view appearance callbacks are only hints about composition and
    /// can fire for historical destinations in a TabView or NavigationStack.
    @discardableResult
    func claimSurfaceSlot(
        ownerLease: PlayerOwnerLease,
        role: PlayerSurfaceRole
    ) -> PlayerSurfaceLease? {
        guard isCurrentOwner(ownerLease) else {
            PlayerLog.log(
                "[Surface] claim rejected — stale owner="
                    + "\(ownerLease.owner) lease=\(ownerLease.generation)"
            )
            return nil
        }
        guard let lease = surfaceAuthority.claim(ownerLease: ownerLease, role: role) else {
            PlayerLog.log(
                "[Surface] claim rejected — slot owned by "
                    + "\(activeSurfaceLease?.role.rawValue ?? "none")"
            )
            return nil
        }
        activeSurfaceLease = lease
        return lease
    }

    /// Move the same physical slot between inline and fullscreen.
    @discardableResult
    func handoffSurfaceSlot(
        ownerLease: PlayerOwnerLease,
        to role: PlayerSurfaceRole
    ) -> PlayerSurfaceLease? {
        guard isCurrentOwner(ownerLease),
              let next = surfaceAuthority.handoff(ownerLease: ownerLease, to: role)
        else { return nil }
        if activeSurfaceLease == next {
            return next
        }
        retireRenderAttachment(reason: "handoff-\(role.rawValue)")
        activeSurfaceLease = next
        PlayerLog.log(
            "[Surface] handoff owner=\(ownerLease.owner) "
                + "role=\(role.rawValue) token=\(next.token)"
        )
        return next
    }

    /// Prepare a host-driven fullscreen presentation even if the inline
    /// representable has not delivered its first update pass yet.
    @discardableResult
    func prepareSurfaceHandoff(ownerLease: PlayerOwnerLease, to role: PlayerSurfaceRole) -> Bool {
        guard isCurrentOwner(ownerLease) else {
            return false
        }
        if activeSurfaceLease == nil {
            _ = claimSurfaceSlot(ownerLease: ownerLease, role: .inline)
        }
        return handoffSurfaceSlot(ownerLease: ownerLease, to: role) != nil
    }

    func releaseSurfaceSlot(lease: PlayerSurfaceLease) {
        guard activeSurfaceLease == lease, surfaceAuthority.release(lease) else { return }
        retireRenderAttachment(reason: "view-disappear-\(lease.role.rawValue)")
        activeSurfaceLease = nil
    }

    /// The slot a specific screen lease is allowed to draw. A newer lease for
    /// the same owner does not inherit it: the outgoing screen keeps the live
    /// renderer until it releases the slot.
    func surfaceLease(
        matching screenLease: PlayerOwnerLease,
        role: PlayerSurfaceRole
    ) -> PlayerSurfaceLease? {
        guard let lease = activeSurfaceLease,
              lease.ownerLease == screenLease,
              lease.role == role else {
            return nil
        }
        return lease
    }

    func invalidateSurfaceSlot(reason: String) {
        let hadLease = activeSurfaceLease != nil
        if let ownerLease = activeSurfaceLease?.ownerLease {
            _ = surfaceAuthority.invalidate(ownerLease: ownerLease)
        } else {
            _ = surfaceAuthority.invalidate()
        }
        retireRenderAttachment(reason: reason)
        activeSurfaceLease = nil
        if hadLease {
            PlayerLog.log("[Surface] slot invalidated reason=\(reason)")
        }
    }

    private func retireRenderAttachment(reason: String) {
        guard let attachment = renderAttachment else { return }
        let lease = renderAttachmentSurfaceLease
        unregisterRenderAttachment(attachment)
        attachment.attach(hostedVC: nil, generation: -1)
        PlayerLog.log(
            "[Surface] attachment retired reason=\(reason) "
                + "token=\(lease.map { String($0.token) } ?? "-")"
        )
    }

    func registerRenderAttachment(
        _ attachment: any PlayerRenderAttachment,
        surfaceLease: PlayerSurfaceLease
    ) -> Bool {
        guard activeSurfaceLease == surfaceLease,
              surfaceAuthority.active == surfaceLease,
              isCurrentOwner(surfaceLease.ownerLease)
        else {
            PlayerLog.log(
                "[Surface] stale attachment rejected token=\(surfaceLease.token)"
            )
            return false
        }
        if renderAttachment === attachment,
           renderAttachmentSurfaceLease == surfaceLease {
            return true
        }
        if renderAttachment != nil, renderAttachment !== attachment {
            guard renderAttachmentSurfaceLease == surfaceLease,
                  let previous = renderAttachment
            else {
                PlayerLog.log(
                    "[Surface] second attachment refused token=\(surfaceLease.token)"
                )
                return false
            }
            // A representable replacement under the same admitted surface lease is a container replacement,
            // not a second owner.
            recoveryCover?.detach(from: previous)
            previous.attach(hostedVC: nil, generation: -1)
            renderAttachment = nil
            renderAttachmentSurfaceLease = nil
            PlayerLog.log(
                "[Surface] attachment replaced token=\(surfaceLease.token)"
            )
        }
        renderAttachment = attachment
        renderAttachmentSurfaceLease = surfaceLease
        if usesDemandPresentationContinuity, !ownerKey.isEmpty {
            let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
            switch decision.registration(currentRenderGeneration: playerGeneration) {
            case .adoptReservedFence:
                // An attach effect reserved this generation while the SwiftUI
                // representable was temporarily absent. Adopt it exactly once;
                // do not create a second generation or replace the transaction.
                advanceGeneration("adoptReservedFence")
            case .adoptTransactionDestination(let generation):
                // A transient container replacement does not reserve another generation underneath an
                // already-running warm/restore transaction.
                PlayerLog.log(
                    "[Generation] \(playerGeneration)→\(generation) "
                        + "why=adoptTransactionDestination"
                )
                playerGeneration = generation
            case .newContainer:
                // A newly registered UIKit container is a new presentation
                // destination even when it hosts the same controller. Rotate
                // render identity so an old container's proof cannot settle it.
                advanceGeneration("newContainerRegistered")
            }
        }
        attachment.attach(hostedVC: backend.renderViewController, generation: playerGeneration)
        let snapshot = attachment.presentationSnapshot
        backend.noteDemandInlineAttachment(
            renderGeneration: snapshot.renderGeneration ?? playerGeneration,
            isVisible: snapshot.isVisible,
            boundsUsable: snapshot.boundsUsable
        )
        if usesDemandPresentationContinuity {
            let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
            if let fence = makeDemandPresentationFence(epoch: epoch) {
                let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
                if decision.shouldInstallInline(fence: fence) {
                    beginDemandPresentationDebt(fence)
                    dispatchDemandPresentation(.installInline(fence: fence))
                }
            }
            renderAttachmentDidChange(attachment)
        }
        return true
    }

    func unregisterRenderAttachment(_ attachment: any PlayerRenderAttachment) {
        guard renderAttachment === attachment else { return }
        recoveryCover?.detach(from: attachment)
        let detachedGeneration = attachment.presentationSnapshot.renderGeneration
            ?? playerGeneration
        backend.noteDemandInlineAttachment(
            renderGeneration: detachedGeneration,
            isVisible: false,
            boundsUsable: false
        )
        if usesDemandPresentationContinuity,
           let pendingFence = lifecycleRecovery.presentationPhase.fence,
           pendingFence.renderGeneration == detachedGeneration {
            dispatchDemandPresentation(.inlineDetached(fence: pendingFence))
        }
        renderAttachment = nil
        renderAttachmentSurfaceLease = nil
        if let lease = activeSurfaceLease,
           surfaceAuthority.active == lease {
            _ = surfaceAuthority.release(lease)
            activeSurfaceLease = nil
        }
    }

    func renderAttachmentDidChange(_ attachment: any PlayerRenderAttachment) {
        guard renderAttachment === attachment else { return }
        if let recoveryCover, let image = freezeFrame, ownsRecoveryCoverAuthority(recoveryCover) {
            _ = recoveryCover.mount(image, on: attachment)
        }
        let snapshot = attachment.presentationSnapshot
        let snapshotGeneration = snapshot.renderGeneration ?? playerGeneration
        backend.noteDemandInlineAttachment(
            renderGeneration: snapshotGeneration,
            isVisible: snapshot.isVisible,
            boundsUsable: snapshot.boundsUsable
        )
        guard usesDemandPresentationContinuity,
              snapshotGeneration == playerGeneration,
              let pendingFence = lifecycleRecovery.presentationPhase.fence,
              pendingFence.renderGeneration == playerGeneration else { return }
        guard snapshot.isAttached, snapshot.isVisible, snapshot.boundsUsable else {
            dispatchDemandPresentation(.inlineDetached(fence: pendingFence))
            return
        }
        dispatchDemandPresentation(.inlineAttached(fence: pendingFence))
    }

    @discardableResult
    func reattachInlineSurface() -> PlayerRenderAttachmentSnapshot? {
        guard let renderAttachment else { return nil }
        // Reattaching that destination must adopt its reserved generation; advancing again creates a fence the
        // transaction never issued and turns a valid restore callback into staleAuthority.
        let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
        switch decision.reattachment(currentRenderGeneration: playerGeneration) {
        case .advance:
            advanceGeneration("reattachInlineSurface")
        case .adoptCurrent:
            PlayerLog.log(
                "[Generation] \(playerGeneration)→\(playerGeneration) "
                    + "why=reattachInlineSurfaceAdopted"
            )
        }
        renderAttachment.attach(
            hostedVC: backend.renderViewController,
            generation: playerGeneration
        )
        let snapshot = renderAttachment.presentationSnapshot
        backend.noteDemandInlineAttachment(
            renderGeneration: snapshot.renderGeneration ?? playerGeneration,
            isVisible: snapshot.isVisible,
            boundsUsable: snapshot.boundsUsable
        )
        return snapshot
    }
}
