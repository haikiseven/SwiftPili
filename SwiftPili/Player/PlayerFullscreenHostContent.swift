import SwiftUI
import UIKit

@MainActor
@Observable
final class PlayerFullscreenHostGeometry {
    var safeAreaInsets = EdgeInsets()
    var containerSize: CGSize = .zero
    var frameInScreen: CGRect?
    var windowGeometry: PlayerWindowGeometry?

    func update(from view: UIView, stageSize: CGSize? = nil) {
        let size = stageSize ?? view.bounds.size
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
        switch receipt.context.route {
        case .video, .bangumi: return true
        case .live, .offline: return false
        }
    }
    private var isCurrentVODFullscreenDraft: Bool {
        fullscreenDanmakuDraftReceipt.map(player.isCurrentFullscreenDanmakuDraft) ?? false
    }
    @State private var fullscreenDanmakuNotice: DanmakuNotice?
    @State private var fullscreenKeyboardFrame: CGRect?
    @State private var fullscreenDanmakuSend = DanmakuComposerSendGate()
    private var fullscreenDanmakuSendInFlight: Bool { fullscreenDanmakuSend.isSending }

    var body: some View {
        GeometryReader { proxy in
            let resolvedSize = proxy.size.width > 1 && proxy.size.height > 1
                ? proxy.size
                : geometry.containerSize
            let viewportAspect = PlayerFullscreenViewportPolicy.aspect(for: resolvedSize)
            let isPortraitImmersive = player.isPortraitContent && player.mode != .live
            let resolvedTopInset = isPortraitImmersive
                ? max(geometry.safeAreaInsets.top, AppWindowMetrics.safeAreaInsets.top)
                : max(0, geometry.safeAreaInsets.top)
            let resolvedBottomInset = isPortraitImmersive
                ? max(geometry.safeAreaInsets.bottom, AppWindowMetrics.safeAreaInsets.bottom)
                : (geometry.safeAreaInsets.bottom > 0
                    ? min(geometry.safeAreaInsets.bottom, AppWindowMetrics.safeAreaInsets.bottom)
                    : 0)
            let playerSafeArea = EdgeInsets(
                top: resolvedTopInset,
                leading: geometry.safeAreaInsets.leading,
                bottom: resolvedBottomInset,
                trailing: geometry.safeAreaInsets.trailing
            )
            PlayerView(
                owner: receipt.context.ownerLease.owner, surfaceRole: .fullscreen,
                liveQualityControl: liveControls.qualityControl,
                fullscreenViewportAspect: viewportAspect,
                fullscreenSafeAreaInsets: playerSafeArea,
                screenLease: receipt.context.ownerLease,
                presentationReceipt: receipt, fullscreenHostIdentity: hostIdentity
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .modifier(LiveKeyboardFrameTracker(frame: $fullscreenKeyboardFrame))
        .onChange(of: player.isFullscreen) { _, isFullscreen in
            guard isCurrentContext else { return }
            if !isFullscreen {
                player.portraitPureViewEnabled = false
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
}
