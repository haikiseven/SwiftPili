import SwiftUI
import UIKit

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

struct PlayerFullscreenHostContent: View {
    let receipt: PlayerPresentationReceipt
    let hostIdentity: UUID
    let geometry: PlayerFullscreenHostGeometry
    let liveControls: PlayerFullscreenLiveControls
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

    @State private var fullscreenDanmakuDraft = ""
    @State private var fullscreenDanmakuDraftReceipt: PlayerViewModel.FullscreenDanmakuDraftReceipt?
    private var keepsVODFullscreenDraft: Bool {
        if case .vod = receipt.context.source { return true }
        return false
    }
    private var isCurrentVODFullscreenDraft: Bool {
        fullscreenDanmakuDraftReceipt.map(player.isCurrentFullscreenDanmakuDraft) ?? false
    }
    @State private var fullscreenDanmakuNotice: DanmakuNotice?
    @State private var fullscreenKeyboardFrame: CGRect?
    @State private var fullscreenDanmakuSend = DanmakuComposerSendGate()
    private var fullscreenDanmakuSendInFlight: Bool { fullscreenDanmakuSend.isSending }

    private var inlineRectInScreen: CGRect? {
        player.inlineVideoRect(for: receipt, hostIdentity: hostIdentity, window: geometry.windowGeometry)
    }

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
        .onChange(of: player.isFullscreen) { _, isFullscreen in
            guard isCurrentContext else { return }
            if !isFullscreen {
                handOffUnsentFullscreenDanmakuDraft()
                dismissFullscreenDanmakuComposer()
            }
            reconcile()
        }
        .onAppear {
            reconcile()
            if player.fullscreenDanmakuComposerPresented, fullscreenDanmakuDraftReceipt == nil {
                openFullscreenDanmakuComposer()
            }
        }
        .onDisappear {
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
        guard isCurrentContext, player.mode.usesOnlineVODServices,
              !fullscreenDanmakuSendInFlight else { return }
        let draftReceipt = fullscreenDanmakuDraftReceipt
        let submittedLoadGeneration = player.loadGeneration
        guard !keepsVODFullscreenDraft || isCurrentVODFullscreenDraft else { return }
        guard let text = fullscreenDanmakuSend.begin(draft: fullscreenDanmakuDraft) else {
            clearFullscreenDanmakuComposer()
            return
        }
        Task {
            if let draftReceipt {
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

    private func fullscreenDanmakuComposerFocusLost() {
        guard isCurrentContext else { return }
        guard !fullscreenDanmakuSendInFlight else { return }
        guard player.fullscreenDanmakuComposerPresented else { return }
        let text = fullscreenDanmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return }
        clearFullscreenDanmakuComposer()
    }

    private func presentFullscreenDanmakuNotice(_ message: String) {
        fullscreenDanmakuNotice = DanmakuNotice(text: message)
    }

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
