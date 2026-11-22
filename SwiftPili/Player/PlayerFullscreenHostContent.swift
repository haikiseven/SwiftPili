import SwiftUI
import UIKit

/// Measurements belong to this exact presented controller, not a scene-wide
/// key-window lookup or a SwiftUI child that has already ignored its safe area.
@MainActor
@Observable
final class PlayerFullscreenHostGeometry {
    var safeAreaInsets = EdgeInsets()
    var containerSize: CGSize = .zero
    var frameInScreen: CGRect?
    var windowGeometry: PlayerWindowGeometry?

    func update(from view: UIView) {
        let size = view.bounds.size
        if size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1, containerSize != size {
            containerSize = size
        }
        let insets = view.safeAreaInsets
        let nextInsets = EdgeInsets(
            top: insets.top, leading: insets.left,
            bottom: insets.bottom, trailing: insets.right
        )
        if safeAreaInsets != nextInsets { safeAreaInsets = nextInsets }
        let nextWindow = view.window.flatMap { PlayerWindowGeometry(window: $0) }
        if windowGeometry != nextWindow { windowGeometry = nextWindow }
        let nextFrame = view.window.map { view.convert(view.bounds, to: $0.screen.coordinateSpace) }
        if frameInScreen != nextFrame { frameInScreen = nextFrame }
    }

    func prepareForTransition(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
        if containerSize != size {
            containerSize = size
        }
    }
}

/// The host's SwiftUI content: one `PlayerView`, and the observer that ends the
/// presentation.
///
/// `PlayerView` is passed no paging sink on purpose. Portrait vertical paging is
/// an inline-only contract (`player-portrait-vod-paging.md` §3: "Fullscreen,
/// live, and views without a sink keep existing brightness/volume, seek, tap,
/// double-tap, and hold-to-2x behavior"), and a nil sink is how that is spelled.
struct PlayerFullscreenHostContent: View {
    let receipt: PlayerPresentationReceipt
    let hostIdentity: UUID
    let geometry: PlayerFullscreenHostGeometry
    let liveControls: PlayerFullscreenLiveControls
    /// `@MainActor` on the function type, the same shape
    /// `PlayerVerticalPagingCoordinator.Handlers` uses: the closure calls a
    /// main-actor method, and a bare `() -> Void` stored property would strip
    /// that isolation on the way in.
    let reconcile: @MainActor () -> Void

    init(
        receipt: PlayerPresentationReceipt,
        hostIdentity: UUID,
        geometry: PlayerFullscreenHostGeometry,
        liveControls: PlayerFullscreenLiveControls,
        reconcile: @escaping @MainActor () -> Void
    ) {
        self.receipt = receipt
        self.hostIdentity = hostIdentity
        self.geometry = geometry
        self.liveControls = liveControls
        self.reconcile = reconcile
    }

    private var player: PlayerViewModel { PlayerViewModel.shared }
    private var isCurrentContext: Bool {
        player.isCurrentPresentationReceipt(receipt, hostIdentity: hostIdentity)
    }

    /// Draft for this presentation. `PlayerView` is detached and reattached
    /// across the handoff, and transport chrome hides on its own timer, so
    /// neither of those views can own the text or the failure toast.
    @State private var fullscreenDanmakuDraft = ""
    @State private var fullscreenDanmakuDraftReceipt: PlayerViewModel.FullscreenDanmakuDraftReceipt?
    /// Every on-demand source — UGC and PGC alike — keeps its fullscreen
    /// draft in the player's source-bound slot. Neither detail page has an
    /// inline danmaku composer to hand a draft back to any more.
    private var keepsVODFullscreenDraft: Bool {
        if case .vod = receipt.context.source { return true }
        return false
    }
    private var isCurrentVODFullscreenDraft: Bool {
        fullscreenDanmakuDraftReceipt.map(player.isCurrentFullscreenDanmakuDraft) ?? false
    }
    /// Send result — the failure, or the "sent" confirmation — drawn on this
    /// host after the composer closes. Not the bar.
    @State private var fullscreenDanmakuNotice: DanmakuNotice?
    @State private var fullscreenKeyboardFrame: CGRect?
    /// Opened before `sendDanmaku` and settled when its result is applied —
    /// one send at a time. Sending disables and so resigns the field; that
    /// resignation is not an empty-draft dismiss, or the failure toast would be
    /// cleared with the bar.
    @State private var fullscreenDanmakuSend = DanmakuComposerSendGate()
    private var fullscreenDanmakuSendInFlight: Bool { fullscreenDanmakuSend.isSending }

    private var inlineRectInScreen: CGRect? {
        player.inlineVideoRect(for: receipt, hostIdentity: hostIdentity, window: geometry.windowGeometry)
    }

    /// The complete inline target in the presented host's coordinate space.
    /// Wide iPad detail routes use a primary column, so parking by y alone is
    /// not enough; x, width, and height are part of the handoff.
    private var inlineTargetFrame: CGRect? {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              !player.isFullscreen,
              let inlineRect = inlineRectInScreen,
              let windowFrame = geometry.frameInScreen,
              windowFrame.minX.isFinite, windowFrame.minY.isFinite
        else { return nil }
        return CGRect(
            x: inlineRect.minX - windowFrame.minX,
            y: inlineRect.minY - windowFrame.minY,
            width: inlineRect.width,
            height: inlineRect.height
        )
    }

    /// Park the phone at its measured y, converted from screen to this host; zero/negative is valid.
    /// Keep its existing width/backend surface; iPad uses the complete primary-column target.
    /// No transition snapshot or extra animation.
    private var inlineTopInset: CGFloat? {
        guard UIDevice.current.userInterfaceIdiom != .pad,
              !player.isFullscreen,
              let rect = inlineRectInScreen,
              let windowFrame = geometry.frameInScreen,
              rect.minY.isFinite, windowFrame.minY.isFinite
        else { return nil }
        let hostY = rect.minY - windowFrame.minY
        return hostY.isFinite ? hostY : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let resolvedSize = geometry.containerSize.width > 1 && geometry.containerSize.height > 1
                ? geometry.containerSize
                : proxy.size
            let viewportAspect = PlayerFullscreenViewportPolicy.aspect(for: resolvedSize)
            // Centred while fullscreen, parked at the complete inline slot on
            // iPad while leaving, or at the measured inline y on iPhone. These
            // are conditional values around one PlayerView identity rather
            // than separate branches that could remount the surface.
            ZStack(alignment: inlineTargetFrame == nil && inlineTopInset == nil ? .center : .topLeading) {
                player.isFullscreen ? Color.black : Color.clear
                let playerSafeArea = EdgeInsets(
                    top: geometry.safeAreaInsets.top,
                    leading: geometry.safeAreaInsets.leading,
                    bottom: min(geometry.safeAreaInsets.bottom, AppWindowMetrics.safeAreaInsets.bottom),
                    trailing: geometry.safeAreaInsets.trailing
                )
                PlayerView(
                    owner: receipt.context.ownerLease.owner, surfaceRole: .fullscreen,
                    liveQualityControl: liveControls.qualityControl,
                    fullscreenViewportAspect: viewportAspect,
                    inlineViewportSize: inlineRectInScreen?.size,
                    fullscreenSafeAreaInsets: playerSafeArea,
                    screenLease: receipt.context.ownerLease,
                    presentationReceipt: receipt, fullscreenHostIdentity: hostIdentity
                )
                    .frame(width: inlineTargetFrame?.width, height: inlineTargetFrame?.height)
                    .frame(maxWidth: inlineTargetFrame == nil ? .infinity : nil,
                           maxHeight: inlineTargetFrame == nil ? .infinity : nil)
                    .offset(x: inlineTargetFrame?.minX ?? 0,
                            y: inlineTargetFrame?.minY ?? inlineTopInset ?? 0)
            }
        }
        .ignoresSafeArea()
        // Sibling of the geometry that frames PlayerView. An overlay here does
        // not change the size proposed to the video; only the bar is padded.
        .overlay(alignment: .bottom) {
            if isCurrentContext, player.mode.usesOnlineVODServices, player.fullscreenDanmakuComposerPresented,
               !keepsVODFullscreenDraft || isCurrentVODFullscreenDraft {
                FullscreenDanmakuComposer(
                    draft: $fullscreenDanmakuDraft,
                    notice: nil,
                    isSending: fullscreenDanmakuSendInFlight,
                    keyboardFrame: fullscreenKeyboardFrame,
                    onSubmit: submitFullscreenDanmaku,
                    onClose: clearFullscreenDanmakuComposer,
                    onFocusLost: fullscreenDanmakuComposerFocusLost
                )
            }
        }
        // The composer owns the only keyboard offset (from the keyboard frame).
        // Without this opt-out SwiftUI would lift the overlay by the keyboard
        // height as well, doubling it.
        .ignoresSafeArea()
        .danmakuNoticeToast($fullscreenDanmakuNotice)
        .onChange(of: player.fullscreenDanmakuComposerPresented) { _, presented in
            guard presented else { return }
            openFullscreenDanmakuComposer()
        }
        .onChange(of: isCurrentVODFullscreenDraft) { _, current in
            guard keepsVODFullscreenDraft, !current else { return }
            clearFullscreenDanmakuComposer()
        }
        .onChange(of: player.fullscreenVODDanmakuSendFailure, initial: true) { _, _ in
            guard isCurrentContext, player.isFullscreen,
                  let message = player.takeFullscreenDanmakuFailure(ownerLease: receipt.context.ownerLease)
            else { return }
            presentFullscreenDanmakuNotice(message)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )
        ) { notification in
            fullscreenKeyboardFrame = keyboardFrame(from: notification)
        }
        // Dismissal is driven by OBSERVING `isFullscreen`, never by the shrink
        // button: `PlayerViewModel.stop(reason:)` also exits fullscreen when the
        // teardown does not preserve the presentation, and a button-wired
        // dismissal would leave this host stranded over a dead player.
        .onChange(of: player.isFullscreen) { _, isFullscreen in
            guard isCurrentContext else { return }
            if !isFullscreen {
                // Only this exit keeps an unsent draft. Close and an empty
                // resignation still discard. An in-flight send stays on the
                // failure path and is not handed off here.
                handOffUnsentFullscreenDanmakuDraft()
                dismissFullscreenDanmakuComposer()
            }
            reconcile()
        }
        // `onChange` does not fire on mount, so a state flip that lands between
        // the presentation being requested and this content appearing would be
        // observed by nobody. `reconcile()` reads the live state and makes the
        // presentation match it, so calling it twice costs nothing.
        .onAppear {
            reconcile()
            if player.fullscreenDanmakuComposerPresented, fullscreenDanmakuDraftReceipt == nil {
                openFullscreenDanmakuComposer()
            }
        }
        .onDisappear {
            // Ordinary dismissal can retire the native host before SwiftUI
            // delivers the isFullscreen edge. Only its source-bound VOD slot
            // may receive this fallback; a replacement has already retired it.
            if keepsVODFullscreenDraft, !player.isFullscreen {
                handOffUnsentFullscreenDanmakuDraft()
            }
        }
    }

    private func openFullscreenDanmakuComposer() {
        guard keepsVODFullscreenDraft, isCurrentContext, player.isFullscreen,
              let opened = player.openFullscreenDanmakuDraft(presentation: receipt, hostIdentity: hostIdentity)
        else { return }
        fullscreenDanmakuDraftReceipt = opened.receipt
        fullscreenDanmakuDraft = opened.text
    }

    private func submitFullscreenDanmaku() {
        // One send at a time: a second submit while the first is pending is
        // refused outright (the composer is also disabled while sending).
        guard isCurrentContext, player.mode.usesOnlineVODServices,
              !fullscreenDanmakuSendInFlight else { return }
        let draftReceipt = fullscreenDanmakuDraftReceipt
        let submittedLoadGeneration = player.loadGeneration
        guard !keepsVODFullscreenDraft || isCurrentVODFullscreenDraft else { return }
        // An empty send just closes. It does not arm the in-flight guard:
        // there is no resignation-from-clear to ignore, and no toast to keep.
        guard let text = fullscreenDanmakuSend.begin(draft: fullscreenDanmakuDraft) else {
            clearFullscreenDanmakuComposer()
            return
        }
        // Keep the submitted text until the POST settles. Clearing it first is
        // what a rotation during the await throws away.
        Task {
            if let draftReceipt {
                // UI Close/reopen cannot cancel an admitted send. Only source
                // or account replacement before this queued Task starts can.
                guard player.loadGeneration == submittedLoadGeneration,
                      player.isCurrentPresentationContext(draftReceipt.presentation.context),
                      AuthManager.shared.sessionGeneration == draftReceipt.accountSession else {
                    fullscreenDanmakuSend.settle()
                    return
                }
            }
            let message = await player.sendDanmaku(text: text)
            fullscreenDanmakuSend.settle()
            if let draftReceipt {
                settleVODFullscreenDanmaku(text: text, message: message, receipt: draftReceipt)
                return
            }
            guard isCurrentContext else { return }
            if let message {
                if player.isFullscreen {
                    fullscreenDanmakuDraft = text
                    player.fullscreenDanmakuComposerPresented = false
                    presentFullscreenDanmakuNotice(message)
                } else {
                    // The portrait field is a different view's state. Hand the
                    // text and the toast across; do not drop them on the way out.
                    fullscreenDanmakuDraft = ""
                    player.fullscreenDanmakuSendFailureDraft = text
                    player.fullscreenDanmakuSendFailure = message
                }
            } else if player.isFullscreen {
                player.fullscreenDanmakuComposerPresented = false
                fullscreenDanmakuDraft = ""
                presentFullscreenDanmakuNotice(String(localized: "Danmaku sent"))
            } else {
                fullscreenDanmakuDraft = ""
            }
        }
    }

    private func settleVODFullscreenDanmaku(
        text: String, message: String?, receipt: PlayerViewModel.FullscreenDanmakuDraftReceipt
    ) {
        guard player.isCurrentFullscreenDanmakuDraft(receipt) else { return }
        if let message {
            let retained = player.retainFullscreenDanmakuDraft(text, receipt: receipt)
            if isCurrentContext, player.isFullscreen {
                if retained { fullscreenDanmakuDraft = text }
                player.fullscreenDanmakuComposerPresented = false
                presentFullscreenDanmakuNotice(message)
            } else {
                fullscreenDanmakuDraft = ""
                player.handOffFullscreenDanmakuFailure(message, receipt: receipt)
            }
        } else {
            player.discardFullscreenDanmakuDraft(receipt: receipt)
            fullscreenDanmakuDraft = ""
            if isCurrentContext, player.isFullscreen {
                player.fullscreenDanmakuComposerPresented = false
                presentFullscreenDanmakuNotice(String(localized: "Danmaku sent"))
            }
        }
    }

    /// Keyboard resignation. Empty (including whitespace-only) closes. A draft
    /// the user may still send stays up — this is not a post, and chrome
    /// auto-hide does not come through here. Closing after a send also resigns
    /// an empty field; that one must not call `clear`, which drops the toast.
    private func fullscreenDanmakuComposerFocusLost() {
        guard isCurrentContext else { return }
        guard !fullscreenDanmakuSendInFlight else { return }
        guard player.fullscreenDanmakuComposerPresented else { return }
        let text = fullscreenDanmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return }
        clearFullscreenDanmakuComposer()
    }

    /// A fresh notice each time, so a repeat of the same text restarts its
    /// dismissal instead of inheriting the previous one's remaining time.
    private func presentFullscreenDanmakuNotice(_ message: String) {
        fullscreenDanmakuNotice = DanmakuNotice(text: message)
    }

    /// Trimmed, non-empty, and not already awaiting a POST. The close button
    /// and an empty focus resignation do not call this.
    private func handOffUnsentFullscreenDanmakuDraft() {
        guard !fullscreenDanmakuSendInFlight else { return }
        let text = fullscreenDanmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if keepsVODFullscreenDraft {
            guard let fullscreenDanmakuDraftReceipt else { return }
            player.retainFullscreenDanmakuDraft(text, receipt: fullscreenDanmakuDraftReceipt)
        } else if isCurrentContext {
            player.fullscreenDanmakuUnsentDraft = text
        }
    }

    /// Explicit Close/empty resignation discards the VOD slot too. A pending
    /// POST is unchanged; its captured text may report failure but cannot revive
    /// a discarded draft. Ordinary fullscreen exit only dismisses below.
    private func clearFullscreenDanmakuComposer() {
        if let fullscreenDanmakuDraftReceipt {
            player.discardFullscreenDanmakuDraft(receipt: fullscreenDanmakuDraftReceipt)
            fullscreenDanmakuDraft = ""
        }
        dismissFullscreenDanmakuComposer()
    }

    private func dismissFullscreenDanmakuComposer() {
        fullscreenDanmakuNotice = nil
        if !fullscreenDanmakuSendInFlight {
            fullscreenDanmakuDraft = ""
        }
        if isCurrentContext { player.fullscreenDanmakuComposerPresented = false }
    }

    private func keyboardFrame(from notification: Notification) -> CGRect? {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return nil
        }
        let frame = value.cgRectValue
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }
}
