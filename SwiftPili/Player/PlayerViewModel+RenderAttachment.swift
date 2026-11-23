import AVFoundation
import Foundation
import UIKit

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
    let frameInWindow: CGRect
    let windowSize: CGSize
    let cornerRadius: CGFloat
    let window: PlayerWindowGeometry
    let receipt: PlayerPresentationReceipt
}

extension PlayerViewModel {

    func advanceGeneration(_ reason: String) {
        playerGeneration &+= 1
        PlayerLog.log("[Generation] \(playerGeneration - 1)→\(playerGeneration) why=\(reason)")
    }

    func noteInlineVideoRect(from attachment: any PlayerRenderAttachment) {
        if DeviceCapability.supportsOrientationLock, isFullscreenPresentationActive {
            return
        }
        guard !isFullscreen, renderAttachment === attachment,
              let lease = renderAttachmentSurfaceLease,
              lease == activeSurfaceLease, lease.role == .inline,
              let presentation = fullscreenPresentation,
              let receipt = fullscreenPresentationReceipt,
              receipt.context.ownerLease == lease.ownerLease,
              isCurrentPresentation(presentation, receipt: receipt)
        else { return }
        guard let measured = attachment.frameInScreen,
              let windowGeometry = PlayerWindowGeometry(window: measured.window),
              let attachmentView = attachment as? UIView,
              measured.rect.minX.isFinite, measured.rect.minY.isFinite,
              measured.rect.width.isFinite, measured.rect.height.isFinite,
              measured.rect.width > 1, measured.rect.height > 1 else {
            if inlineReturnTarget != nil { inlineReturnTarget = nil }
            return
        }
        let frameInWindow = attachmentView.convert(attachmentView.bounds, to: measured.window)
        let cornerRadius = (attachment as? PlayerContainerView)?.currentPresentationCornerRadius ?? 0
        let target = PlayerInlineReturnTarget(
            frameInScreen: measured.rect,
            frameInWindow: frameInWindow,
            windowSize: measured.window.bounds.size,
            cornerRadius: cornerRadius,
            window: windowGeometry,
            receipt: receipt
        )
        if inlineReturnTarget != target { inlineReturnTarget = target }
    }

    func noteInlineSlotGeometry(from view: UIView, cornerRadius: CGFloat) {
        if DeviceCapability.supportsOrientationLock, isFullscreenPresentationActive {
            return
        }
        guard let window = view.window,
              let windowGeometry = PlayerWindowGeometry(window: window),
              let presentation = fullscreenPresentation,
              let receipt = fullscreenPresentationReceipt,
              isCurrentPresentation(presentation, receipt: receipt),
              view.bounds.width > 1, view.bounds.height > 1 else { return }
        let frameInScreen = view.convert(view.bounds, to: window.screen.coordinateSpace)
        let frameInWindow = view.convert(view.bounds, to: window)
        guard frameInScreen.minX.isFinite, frameInScreen.minY.isFinite,
              frameInScreen.width > 1, frameInScreen.height > 1,
              frameInWindow.minX.isFinite, frameInWindow.minY.isFinite,
              frameInWindow.width > 1, frameInWindow.height > 1 else { return }
        let target = PlayerInlineReturnTarget(
            frameInScreen: frameInScreen,
            frameInWindow: frameInWindow,
            windowSize: window.bounds.size,
            cornerRadius: max(0, cornerRadius),
            window: windowGeometry,
            receipt: receipt
        )
        if inlineReturnTarget != target { inlineReturnTarget = target }
    }

    var inlineStageSnapshot: PlayerFullscreenStageGeometry.InlineSnapshot? {
        guard let target = inlineReturnTarget,
              let receipt = fullscreenPresentationReceipt,
              target.receipt == receipt else { return nil }
        return PlayerFullscreenStageGeometry.InlineSnapshot(
            frameInWindow: target.frameInWindow,
            frameInScreen: target.frameInScreen,
            windowSize: target.windowSize,
            windowFrameInScreen: target.window.frameInScreen,
            cornerRadius: target.cornerRadius
        )
    }

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
        if DeviceCapability.supportsPadDetailSplit, target.window != window { return nil }
        return target.frameInScreen
    }

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

    func upgradeOrInvalidateSurfaceSlot(
        from outgoing: PlayerOwnerLease?,
        to incoming: PlayerOwnerLease
    ) {
        guard let outgoing else {
            invalidateSurfaceSlot(reason: "owner-lease-replacement")
            return
        }
        let hasAttachment = renderAttachment != nil
            && renderAttachmentSurfaceLease == activeSurfaceLease
        if let upgraded = surfaceAuthority.rekeyOrInvalidate(
            from: outgoing,
            to: incoming,
            hasAttachment: hasAttachment
        ) {
            activeSurfaceLease = upgraded
            renderAttachmentSurfaceLease = upgraded
            PlayerLog.log(
                "[Surface] lease upgraded owner=\(incoming.owner) " +
                "gen=\(outgoing.generation)→\(incoming.generation) " +
                "role=\(upgraded.role.rawValue) token=\(upgraded.token)"
            )
        } else {
            retireRenderAttachment(reason: "owner-lease-replacement")
            activeSurfaceLease = nil
        }
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
        var targetGeneration = playerGeneration
        var generationReason: String?
        if usesDemandPresentationContinuity, !ownerKey.isEmpty {
            let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
            switch decision.registration(currentRenderGeneration: playerGeneration) {
            case .adoptReservedFence:
                targetGeneration &+= 1
                generationReason = "adoptReservedFence"
            case .adoptTransactionDestination(let generation):
                targetGeneration = generation
                if targetGeneration != playerGeneration {
                    generationReason = "adoptTransactionDestination"
                }
            case .newContainer:
                targetGeneration &+= 1
                generationReason = "newContainerRegistered"
            }
        }
        attachment.attach(hostedVC: backend.renderViewController, generation: targetGeneration)
        let snapshot = attachment.presentationSnapshot
        backend.noteDemandInlineAttachment(
            renderGeneration: snapshot.renderGeneration ?? targetGeneration,
            isVisible: snapshot.isVisible,
            boundsUsable: snapshot.boundsUsable
        )
        if targetGeneration != playerGeneration || usesDemandPresentationContinuity {
            Task { @MainActor [weak self, weak attachment] in
                guard let self, let attachment,
                      self.renderAttachment === attachment,
                      self.renderAttachmentSurfaceLease == surfaceLease,
                      self.isCurrentOwner(surfaceLease.ownerLease) else { return }
                if targetGeneration != self.playerGeneration {
                    if let generationReason {
                        PlayerLog.log("[Generation] \(self.playerGeneration)→\(targetGeneration) why=\(generationReason)")
                    }
                    self.playerGeneration = targetGeneration
                }
                if self.usesDemandPresentationContinuity {
                    let epoch = self.lifecycleRecovery.ensureDemandPresentationEpoch()
                    if let fence = self.makeDemandPresentationFence(epoch: epoch) {
                        let decision = RenderDestinationDecision(phase: self.lifecycleRecovery.presentationPhase)
                        if decision.shouldInstallInline(fence: fence) {
                            self.beginDemandPresentationDebt(fence)
                            self.dispatchDemandPresentation(.installInline(fence: fence))
                        }
                    }
                    self.renderAttachmentDidChange(attachment)
                }
            }
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

    func hasUsableRenderAttachment(
        forRole role: PlayerSurfaceRole,
        ownerLease: PlayerOwnerLease
    ) -> Bool {
        guard let attachment = renderAttachment,
              let lease = renderAttachmentSurfaceLease,
              lease == activeSurfaceLease,
              lease.ownerLease == ownerLease,
              lease.role == role else { return false }
        let snapshot = attachment.presentationSnapshot
        return snapshot.isAttached && snapshot.isVisible && snapshot.boundsUsable
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
        fullscreenPresentation?.surfaceAttachmentDidChange()
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
