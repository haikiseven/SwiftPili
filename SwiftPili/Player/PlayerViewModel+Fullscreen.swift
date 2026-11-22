import AVFoundation
import Foundation
import SwiftUI
import UIKit

extension PlayerViewModel {

    /// Transient overlay chip (reuses the skip-notice slot) — auto-hides.
    func showNotice(_ text: String) {
        skipNotice = text
        skipNoticeTask?.cancel()
        skipNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.skipNotice = nil
        }
    }

    /// Coalesce button, orientation and layout requests into one pending transition.
    private func coalesceFullscreenTransitionRequest(
        target: Bool,
        transitionID: UInt64
    ) -> FullscreenTransitionRequestDecision {
        fullscreenTransition.request(
            target: target,
            currentState: isFullscreen,
            transitionID: transitionID
        )
    }

    /// Judge an interrupted transition against its observed state, not a newer value.
    private func settleFullscreenTransition(
        actualState: Bool
    ) -> FullscreenTransitionSettlement {
        fullscreenTransition.settle(actualState: actualState)
    }

    /// Settle once in the model, independent of view mounts, then restore usable controls.
    private func settleFullscreenPresentation(actualState: Bool) {
        FullscreenTransitionDiagnostics.recordSettlement(
            settleFullscreenTransition(actualState: actualState),
            actualState: actualState,
            playerGeneration: playerGeneration,
            hasURL: currentURL != nil,
            surfaceSize: lastReportedSurfaceSize,
            verticalSizeClass: lastReportedVerticalSizeClass
        )
        // Avoid invalidating observers when the controls are already visible.
        if !showControls { showControls = true }
        scheduleHideControls()
    }

    func noteSurfaceGeometry(size: CGSize, verticalSizeClass: String) {
        lastReportedSurfaceSize = size
        lastReportedVerticalSizeClass = verticalSizeClass
    }

    func scheduleHideControls() {
        hideControlsTask?.cancel()
        guard showControls, !danmakuSettingsHold else { return }
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showControls = false
            }
        }
    }

    func setDanmakuSettingsHold(_ hold: Bool) {
        let wasHeld = danmakuSettingsHold
        danmakuSettingsHold = hold
        if hold {
            hideControlsTask?.cancel()
            showControls = true
        } else {
            if wasHeld {
                NotificationCenter.default.post(name: .danmakuPreferencesCommit, object: nil)
            }
            scheduleHideControls()
        }
    }

    func enterFullscreen() {
        guard !isFullscreen else { return }
        guard let presentation = fullscreenPresentation,
              let receipt = fullscreenPresentationReceipt,
              isCurrentPresentation(presentation, receipt: receipt),
              currentURL != nil, error == nil, !terminalOpenFailure,
              presentation.reserveHost(receipt: receipt) else {
            settleFullscreenPresentation(actualState: false)
            return
        }
        // Read the actual current window before the inline attachment retires.
        // Moving a floating window may not have resized its player container.
        refreshInlineVideoRect()
        // A real controller consumer is reserved BEFORE inline authority ends.
        guard prepareSurfaceHandoff(ownerLease: receipt.context.ownerLease, to: .fullscreen) else {
            presentation.cancelReservedHost(receipt: receipt)
            settleFullscreenPresentation(actualState: false)
            return
        }
        FullscreenLoginHandoff.shared.cancel()
        if fullscreenPresentation != nil {
            isFullscreen = true
        } else {
            withAnimation(AppMotionPreferences.current.animation(normal: .easeInOut(duration: 0.25))) {
                isFullscreen = true
            }
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            applyOrientation(.landscape)
        }
        presentation.reconcile()
        settleFullscreenPresentation(actualState: isFullscreen)
    }

    /// Rollback/external dismissal may affect only the captured transaction.
    func exitFullscreen(
        presentation: any PlayerFullscreenPresentation,
        receipt: PlayerPresentationReceipt
    ) {
        guard isCurrentPresentation(presentation, receipt: receipt) else { return }
        exitFullscreen()
    }

    func exitFullscreen() {
        guard isFullscreen else { return }
        setDanmakuSettingsHold(false)
        fullscreenDanmakuComposerPresented = false
        PlayerLog.log("[Fullscreen] exit: portrait=\(isPortraitContent) condensed=\(inlineCondensed) showControls=\(showControls)")
        if let ownerLease = currentOwnerLease {
            _ = handoffSurfaceSlot(ownerLease: ownerLease, to: .inline)
        }
        if fullscreenPresentation != nil {
            isFullscreen = false
        } else {
            withAnimation(AppMotionPreferences.current.animation(normal: .easeInOut(duration: 0.25))) {
                isFullscreen = false
            }
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            applyOrientation(.portrait)
        }
        settleFullscreenPresentation(actualState: false)
    }

    /// Whether to wait is asked of the host itself — a registered presentation that took the no-host fallback
    /// (the in-place rotation) has no dismissal to wait for, and waiting on one would never open login.
    func requestLoginFromFullscreen() {
        guard isFullscreen else { return }
        let handoff = FullscreenLoginHandoff.shared
        handoff.arm()
        let waitsForHost = fullscreenPresentation?.hasPresentedHost == true
        exitFullscreen()
        if !waitsForHost { handoff.release() }
    }

    /// Order matters: a geometry request is honoured only for an orientation the app currently PERMITS, so the
    /// mask (and the delegate re-query it triggers) must land first.
    private func applyOrientation(_ mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        if let presentation = fullscreenPresentation {
            // `PlayerFullscreenPresentation` states the contract; this branch is only reachable for a screen
            // that mounted one, so live and offline keep this method bit-for-bit.
            presentation.applyOrientation(
                mask: mask,
                label: Self.orientationMaskLabel(mask)
            )
            return
        }
        AppOrientation.shared.set(mask)
        // Both the window and the scene come from the FILTERED probe.
        let window = AppWindowMetrics.current
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        // A closed label, not the UIKit type: the sink takes no platform types.
        FullscreenTransitionDiagnostics.recordSceneGeometryRequest(
            mask: Self.orientationMaskLabel(mask),
            windowResolved: window != nil
        )
    }

    /// Closed labels for the three masks this app ever requests. `other` covers
    /// nothing today and exists so the sink can never be handed a raw value.
    private static func orientationMaskLabel(
        _ mask: UIInterfaceOrientationMask
    ) -> String {
        switch mask {
        case .landscape: "landscape"
        case .portrait: "portrait"
        case .all: "all"
        default: "other"
        }
    }

    // No `toggleFullscreen()` any more.

    /// It was a private helper on `PlayerView`, which was correct while the player was the only thing that
    /// could ask.
    func requestFullscreenTransition(target: Bool, source: FullscreenTransitionSource) {
        let transitionID = FullscreenTransitionDiagnostics.nextTransitionID()
        // Read once: the decision is made against the view model's own value,
        // and the record must report the same state the decision saw.
        let currentState = isFullscreen
        let decision = coalesceFullscreenTransitionRequest(
            target: target,
            transitionID: transitionID
        )
        FullscreenTransitionDiagnostics.recordRequest(
            decision: decision,
            source: source,
            target: target,
            currentState: currentState,
            playerGeneration: playerGeneration,
            hasURL: currentURL != nil,
            surfaceSize: lastReportedSurfaceSize,
            verticalSizeClass: lastReportedVerticalSizeClass
        )

        guard case .start = decision else { return }
        // Dispatching here is what makes a second caller unable to pair a granted request with the wrong side
        // of the toggle.
        if target {
            enterFullscreen()
        } else {
            exitFullscreen()
        }
    }

    func togglePortraitExpand() {
        guard isPortraitContent, !isFullscreen else { return }
        let was = inlineCondensed
        inlineCondensed.toggle()
        // The ONLY legitimate writer of this lock: it means "the user chose
        // this size". Both manual expansion and manual condensation are
        // authoritative; scrolling must not immediately undo either choice.
        portraitCondenseLocked = true
        PlayerLog.log(
            "[condense] manual condensed=\(was)→\(inlineCondensed) "
            + "locked=\(portraitCondenseLocked)"
        )
    }

    /// Pause/silence the outgoing transport before the next target load, but do not release ownership or
    /// advance player/backend generations here: the target loader remains the sole activation authority for the
    /// successor.
    @discardableResult
    func beginPortraitPagingHandoff(lease: PlayerOwnerLease) -> Bool {
        guard isCurrentOwner(lease), (mode == .vod || mode == .offline) else { return false }
        error = nil
        // A new load is a new verdict: a refusal belongs to the source that
        // produced it, and carrying it forward would make the successor
        // unplayable and un-retryable before it ever asked the server.
        unavailability = nil
        terminalOpenFailure = false
        suspendPlayback()
        return true
    }
}

extension PlayerViewModel {

    /// Read-only source fact. A presentation never opens/restarts transport.
    func presentationContext(
        screenID: UUID,
        lease: PlayerOwnerLease?,
        route: PlayerScreenRoute,
        position: PlayerRoutePosition?,
        source: PlayerPresentationSource
    ) -> PlayerScreenPresentationContext? {
        guard let lease, let position, isCurrentOwner(lease) else { return nil }
        switch (route, source) {
        case (.video, .vod(_, _, .ugc)), (.bangumi, .vod(_, _, .pgc)), (.offline, .offline):
            break
        case (.live(let routeRoomID), .live(let sourceRoomID)) where routeRoomID == sourceRoomID:
            break
        default:
            return nil
        }
        let context = PlayerScreenPresentationContext(
            screenID: screenID, ownerLease: lease, route: route, position: position, source: source
        )
        return isCurrentPresentationContext(context) ? context : nil
    }

    func isCurrentPresentationContext(_ context: PlayerScreenPresentationContext) -> Bool {
        isCurrentPresentationSource(lease: context.ownerLease, source: context.source)
    }

    /// Source-owned geometry remains readable while a route transitions out.
    /// Matching never activates media or requires a mounted presentation.
    func isCurrentPresentationSource(lease: PlayerOwnerLease?, source: PlayerPresentationSource) -> Bool {
        guard let lease, isCurrentOwner(lease) else { return false }
        switch source {
        case .vod(let aid, let cid, let source):
            return mode == .vod && currentAid == aid && currentCid == cid && currentSource == source
        case .live(let roomID):
            return mode == .live && currentRoomID == roomID
        case .offline(let asset):
            return mode == .offline && offlineAsset == asset
        }
    }

    func isAlreadyLivePresentation(
        lease: PlayerOwnerLease?,
        source: PlayerPresentationSource
    ) -> Bool {
        guard let lease, isCurrentOwner(lease), currentURL != nil,
              error == nil, unavailability == nil, !terminalOpenFailure else { return false }
        switch source {
        case .live(let roomID):
            return mode == .live && currentRoomID == roomID && currentURL?.isFileURL == false
        case .offline(let asset):
            return mode == .offline && offlineAsset == asset && currentURL == asset.videoURL
                && OfflinePlaybackAssetValidator.allows(videoURL: asset.videoURL, audioURL: asset.audioURL)
        case .vod(let aid, let cid, let source):
            return mode == .vod && currentAid == aid && currentCid == cid && currentSource == source
        }
    }

    func registerFullscreenPresentation(
        _ presentation: any PlayerFullscreenPresentation,
        context: PlayerScreenPresentationContext
    ) -> PlayerPresentationReceipt? {
        guard presentation.routeIsActive, isCurrentPresentationContext(context) else { return nil }
        if fullscreenPresentation === presentation,
           let receipt = fullscreenPresentationReceipt, receipt.context == context {
            return receipt
        }
        retireFullscreenPresentation()
        let receipt = PlayerPresentationReceipt(id: UUID(), context: context)
        fullscreenPresentation = presentation
        fullscreenPresentationReceipt = receipt
        return receipt
    }

    func isCurrentPresentationReceipt(
        _ receipt: PlayerPresentationReceipt,
        hostIdentity: UUID
    ) -> Bool {
        guard let presentation = fullscreenPresentation else { return false }
        return isCurrentPresentation(presentation, receipt: receipt)
            && presentation.isCurrentHost(hostIdentity)
    }

    func isCurrentPresentation(
        _ presentation: any PlayerFullscreenPresentation,
        receipt: PlayerPresentationReceipt
    ) -> Bool {
        fullscreenPresentation === presentation && fullscreenPresentationReceipt == receipt
            && presentation.routeIsActive && isCurrentPresentationContext(receipt.context)
    }

    func unregisterFullscreenPresentation(
        _ presentation: any PlayerFullscreenPresentation,
        receipt: PlayerPresentationReceipt
    ) {
        guard fullscreenPresentation === presentation, fullscreenPresentationReceipt == receipt else { return }
        retireFullscreenPresentation()
    }

    /// Actual stack/selection writes are the sole producer of route departure.
    func playerRouteWillChange(from old: PlayerRouteDestination?, to new: PlayerRouteDestination?) {
        guard old != new, let old,
              let receipt = fullscreenPresentationReceipt,
              receipt.context.route == old.route, receipt.context.position == old.position else { return }
        let lease = receipt.context.ownerLease
        retireFullscreenPresentation()
        endOwnerPlayback(lease: lease)
    }

    func retirePresentation(screenID: UUID, lease: PlayerOwnerLease) {
        guard let context = fullscreenPresentationReceipt?.context,
              context.screenID == screenID, context.ownerLease == lease else { return }
        retireFullscreenPresentation()
        endOwnerPlayback(lease: lease)
    }

    func retireFullscreenPresentation() {
        let previous = fullscreenPresentation
        // Retire registration before the exit.
        fullscreenPresentation = nil
        fullscreenPresentationReceipt = nil
        if isFullscreen { exitFullscreen() }
        previous?.relinquishForOwnerReplacement()
    }
}
