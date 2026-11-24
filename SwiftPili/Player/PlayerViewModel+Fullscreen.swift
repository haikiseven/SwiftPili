import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class PlayerFullscreenTransitionState {
    static let shared = PlayerFullscreenTransitionState()

    enum Phase: Equatable, Sendable {
        case idle
        case entering
        case fullscreen
        case leaving
    }

    private(set) var activeHostID: UUID?
    private(set) var phase: Phase = .idle

    var isHostActive: Bool {
        activeHostID != nil && phase != .idle
    }

    var isGeometryTransitioning: Bool {
        phase == .entering || phase == .leaving
    }

    func update(hostID: UUID?, phase: Phase) {
        if self.activeHostID != hostID { self.activeHostID = hostID }
        if self.phase != phase { self.phase = phase }
    }

    func clear(matching hostID: UUID? = nil) {
        if let hostID, activeHostID != nil, activeHostID != hostID { return }
        activeHostID = nil
        phase = .idle
    }
}

@MainActor
final class FullscreenOrientationLatch {
    static let shared = FullscreenOrientationLatch()
    private static let minimumSettleWindow: TimeInterval = 0.8
    private var latchedFullscreen: Bool?
    private var latchedAt: TimeInterval = 0

    func recordButtonTransition(targetFullscreen: Bool, now: TimeInterval = CACurrentMediaTime()) {
        latchedFullscreen = targetFullscreen
        latchedAt = now
    }

    func clear() {
        latchedFullscreen = nil
    }

    func shouldIgnoreDeviceOrientation(
        _ orientation: UIDeviceOrientation,
        currentFullscreen: Bool,
        now: TimeInterval = CACurrentMediaTime()
    ) -> Bool {
        let wantsFullscreen: Bool
        if orientation.isLandscape {
            wantsFullscreen = true
        } else if orientation == .portrait {
            wantsFullscreen = false
        } else {
            return true
        }
        if wantsFullscreen == currentFullscreen {
            if let latched = latchedFullscreen, latched == wantsFullscreen,
               now - latchedAt >= Self.minimumSettleWindow {
                latchedFullscreen = nil
            }
            return true
        }
        if latchedFullscreen != nil, now - latchedAt < Self.minimumSettleWindow {
            return true
        }
        if let latched = latchedFullscreen, wantsFullscreen != latched {
            return true
        }
        return false
    }
}

extension PlayerViewModel {

    func showNotice(_ text: String) {
        skipNotice = text
        skipNoticeTask?.cancel()
        skipNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.skipNotice = nil
        }
    }

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

    private func settleFullscreenTransition(
        actualState: Bool
    ) -> FullscreenTransitionSettlement {
        fullscreenTransition.settle(actualState: actualState)
    }

    private func settleFullscreenPresentation(actualState: Bool) {
        FullscreenTransitionDiagnostics.recordSettlement(
            settleFullscreenTransition(actualState: actualState),
            actualState: actualState,
            playerGeneration: playerGeneration,
            hasURL: currentURL != nil,
            surfaceSize: lastReportedSurfaceSize,
            verticalSizeClass: lastReportedVerticalSizeClass
        )
        if !showControls { showControls = true }
        scheduleHideControls()
    }

    func noteSurfaceGeometry(size: CGSize, verticalSizeClass: String) {
        lastReportedSurfaceSize = size
        lastReportedVerticalSizeClass = verticalSizeClass
    }

    func scheduleHideControls(isSeeking: Bool = false) {
        hideControlsTask?.cancel()
        guard showControls, !danmakuSettingsHold, !isSeeking, !isSeekInFlight else { return }
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.isSeekInFlight else { return }
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

    var isFullscreenPresentationActive: Bool {
        isFullscreen || PlayerFullscreenTransitionState.shared.isHostActive
    }

    func captureFullscreenTransitionCover() -> PlayerFullscreenTransitionCover? {
        if let frame = backend.currentDisplayedFrameForTransition(),
           frame.size.width > 1, frame.size.height > 1 {
            return .image(frame, contentMode: scaleMode.contentMode)
        }
        if let frame = freezeFrame, frame.size.width > 1, frame.size.height > 1 {
            return .image(frame, contentMode: scaleMode.contentMode)
        }
        if let sourceView = backend.renderViewController?.viewIfLoaded ?? (renderAttachment as? UIView),
           sourceView.window != nil,
           sourceView.bounds.width > 1, sourceView.bounds.height > 1,
           let snapshot = sourceView.snapshotView(afterScreenUpdates: false) {
            return .snapshotView(snapshot)
        }
        return nil
    }

    func enterFullscreen() {
        guard !isFullscreen else { return }
        guard let presentation = fullscreenPresentation,
              let receipt = fullscreenPresentationReceipt,
              isCurrentPresentation(presentation, receipt: receipt),
              currentURL != nil, error == nil, !terminalOpenFailure else {
            settleFullscreenPresentation(actualState: false)
            return
        }
        refreshInlineVideoRect()
        let transitionCover = captureFullscreenTransitionCover()
        guard presentation.reserveHost(receipt: receipt, transitionCover: transitionCover) else {
            settleFullscreenPresentation(actualState: false)
            return
        }
        guard prepareSurfaceHandoff(ownerLease: receipt.context.ownerLease, to: .fullscreen) else {
            presentation.cancelReservedHost(receipt: receipt)
            settleFullscreenPresentation(actualState: false)
            return
        }
        FullscreenLoginHandoff.shared.cancel()
        if DeviceCapability.supportsOrientationLock {
            AppWindowMetrics.current?.endEditing(true)
        }
        if fullscreenPresentation != nil {
            isFullscreen = true
        } else {
            withAnimation(AppMotionPreferences.current.animation(normal: .easeInOut(duration: 0.25))) {
                isFullscreen = true
            }
        }
        if DeviceCapability.supportsOrientationLock {
            let targetMask: UIInterfaceOrientationMask = isPortraitContent ? .portrait : .landscape
            applyOrientation(targetMask)
        }
        presentation.reconcile()
        settleFullscreenPresentation(actualState: isFullscreen)
    }

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
        let hasActiveHost = fullscreenPresentation?.hasPresentedHost == true
        if !hasActiveHost, let ownerLease = currentOwnerLease {
            _ = handoffSurfaceSlot(ownerLease: ownerLease, to: .inline)
        }
        if fullscreenPresentation != nil {
            isFullscreen = false
        } else {
            withAnimation(AppMotionPreferences.current.animation(normal: .easeInOut(duration: 0.25))) {
                isFullscreen = false
            }
        }
        if DeviceCapability.supportsOrientationLock {
            applyOrientation(.portrait)
        }
        fullscreenPresentation?.reconcile()
        settleFullscreenPresentation(actualState: false)
    }

    func requestLoginFromFullscreen(sceneID: UUID? = nil) {
        guard isFullscreen else { return }
        let handoff = FullscreenLoginHandoff.shared
        handoff.arm(sceneID: sceneID ?? routeOwnership.activeSceneID)
        let waitsForHost = fullscreenPresentation?.hasPresentedHost == true
        exitFullscreen()
        if !waitsForHost { handoff.release() }
    }

    private func applyOrientation(_ mask: UIInterfaceOrientationMask) {
        guard DeviceCapability.supportsOrientationLock else { return }
        if let presentation = fullscreenPresentation {
            presentation.applyOrientation(
                mask: mask,
                label: Self.orientationMaskLabel(mask)
            )
            return
        }
        AppOrientation.shared.set(mask)
        let window = AppWindowMetrics.current
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        FullscreenTransitionDiagnostics.recordSceneGeometryRequest(
            mask: Self.orientationMaskLabel(mask),
            windowResolved: window != nil
        )
    }

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

    func requestFullscreenTransition(target: Bool, source: FullscreenTransitionSource) {
        let transitionID = FullscreenTransitionDiagnostics.nextTransitionID()
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
        if source == .button {
            FullscreenOrientationLatch.shared.recordButtonTransition(targetFullscreen: target)
        }
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
        portraitCondenseLocked = true
        PlayerLog.log(
            "[condense] manual condensed=\(was)→\(inlineCondensed) "
            + "locked=\(portraitCondenseLocked)"
        )
    }

    @discardableResult
    func beginPortraitPagingHandoff(lease: PlayerOwnerLease) -> Bool {
        guard isCurrentOwner(lease), (mode == .vod || mode == .offline) else { return false }
        hasRenderedFirstFrame = false
        error = nil
        unavailability = nil
        terminalOpenFailure = false
        suspendPlayback()
        return true
    }
}

extension PlayerViewModel {

    func presentationContext(
        screenID: UUID,
        lease: PlayerOwnerLease?,
        route: PlayerScreenRoute,
        position: PlayerRoutePosition?,
        source: PlayerPresentationSource?
    ) -> PlayerScreenPresentationContext? {
        guard let lease, let position, isCurrentOwner(lease) else { return nil }
        switch (route, source) {
        case (.video, .vod(_, _, .ugc)), (.video, nil),
             (.bangumi, .vod(_, _, .pgc)), (.bangumi, nil),
             (.offline, .offline):
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
        guard isCurrentOwner(context.ownerLease) else { return false }
        switch (context.route, context.source) {
        case (.video, .vod(_, _, .ugc)), (.video, nil),
             (.bangumi, .vod(_, _, .pgc)), (.bangumi, nil):
            return true
        case (.live(let roomID), .live(let sourceRoomID)):
            return roomID == sourceRoomID && mode == .live && currentRoomID == roomID
        case (.offline, .offline(let asset)):
            return mode == .offline && offlineAsset == asset
        default:
            return false
        }
    }

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
           let existing = fullscreenPresentationReceipt,
           existing.context.hostKey == context.hostKey {
            let updated = PlayerPresentationReceipt(id: existing.id, context: context)
            fullscreenPresentationReceipt = updated
            return updated
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
        fullscreenPresentation = nil
        fullscreenPresentationReceipt = nil
        if isFullscreen { exitFullscreen() }
        FullscreenOrientationLatch.shared.clear()
        previous?.relinquishForOwnerReplacement()
    }
}
