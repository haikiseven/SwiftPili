import SwiftUI
import UIKit

struct LiveRoomView: View {
    let roomID: Int
    @State private var routePosition: PlayerRoutePosition?

    init(roomID: Int, routePosition: PlayerRoutePosition? = nil) {
        self.roomID = roomID
        _routePosition = State(initialValue: routePosition)
    }

    @State private var viewModel = LiveRoomViewModel()
    @State private var danmakuDraft = LiveDanmakuDraftModel()
    @FocusState private var isDanmakuFocused: Bool
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.authManager) private var authManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var scaleModeBeforeImmersivePortrait: VideoScaleMode?
    @State private var inlineContainerSize: CGSize = .zero
    @State private var portraitKeyboardFrame: CGRect?
    @State private var portraitInputBarHeight = LivePortraitOverlayMetrics.minimumInputHeight
    @State private var immersiveTransportHeight = LivePortraitOverlayMetrics.minimumInputHeight
    @State private var immersiveHeaderHeight = LivePortraitOverlayMetrics.minimumHeaderHeight
    @State private var standardHeaderHeight = LivePortraitOverlayMetrics.minimumHeaderHeight
    @State private var presentationScreenID = UUID()

    private var player: PlayerViewModel { PlayerViewModel.shared }

    private var isActiveLiveRoute: Bool {
        coordinator.isActivePlayerRoute(.live(roomID), position: routePosition)
    }

    private var presentationContext: PlayerScreenPresentationContext? {
        guard isActiveLiveRoute else { return nil }
        return player.presentationContext(
            screenID: presentationScreenID, lease: viewModel.playerOwnerLease,
            route: .live(roomID), position: routePosition, source: .live(roomID: roomID)
        )
    }

    private var roomAvailability: LiveRoomAvailability {
        LiveRoomAvailability.resolve(liveStatus: viewModel.roomInfo?.liveStatus)
    }

    private var isRoomOffline: Bool { roomAvailability.isOffline }

    private var usesWideCompanionLayout: Bool {
        DetailSplitPolicy.usesSplit(
            isRegularWidth: horizontalSizeClass == .regular,
            containerSize: inlineContainerSize
        )
    }

    private var playerShapeIsCurrent: Bool {
        player.isCurrentPresentationSource(lease: viewModel.playerOwnerLease, source: .live(roomID: roomID))
    }

    private var pageIsPortraitContent: Bool {
        guard DeviceCapability.usesCompactPortraitVideoFraming else { return false }
        return streamIsPortraitContent
    }

    private var streamIsPortraitContent: Bool {
        if playerShapeIsCurrent, player.portraitPropagation.hasValidVideoGeometry {
            return player.isPortraitContent
        }
        return viewModel.isPortraitHint
            ?? viewModel.roomInfo?.isPortrait
            ?? (playerShapeIsCurrent && player.isPortraitContent)
    }

    private var usesImmersivePortraitLayout: Bool {
        !usesWideCompanionLayout && !isRoomOffline && pageIsPortraitContent
    }

    private var shouldUseImmersiveFillScale: Bool {
        usesImmersivePortraitLayout && !player.isFullscreenPresentationActive
    }

    private var playerPageNavigation: PlayerPageNavigationActions {
        PlayerPageNavigationActions(
            onBack: { coordinator.goBack() }, onHome: { coordinator.goHome() },
            onDownload: nil, onReport: nil, pageOwnsInlineNavigation: true
        )
    }

    private var isCurrentRoomPlaybackUnavailable: Bool {
        guard let lease = viewModel.playerOwnerLease,
              player.isCurrentOwner(lease),
              player.mode == .live else { return false }
        return (player.error ?? player.videoPresentationFailureMessage) != nil
    }

    private var keyWindowSafeAreaInsets: UIEdgeInsets? {
        AppWindowMetrics.current?.safeAreaInsets
    }

    private var keyWindowFrameInScreen: CGRect? { AppWindowMetrics.frameInScreen }

    private func playerInlineHeight(containerWidth: CGFloat, boxHeight: CGFloat) -> CGFloat {
        if usesImmersivePortraitLayout { return max(0, boxHeight).rounded() }
        if usesWideCompanionLayout {
            return LiveRoomWideStageLayout.metrics(
                in: CGSize(width: containerWidth, height: boxHeight),
                hasRoomInfo: viewModel.roomInfo != nil,
                standardHeaderHeight: standardHeaderHeight,
                streamIsPortraitContent: streamIsPortraitContent,
                isRoomOffline: isRoomOffline
            ).playerSize.height
        }
        return DetailPlayerGeometry.videoHeight(
            containerWidth: containerWidth, primaryColumnWidth: nil,
            isPortraitContent: pageIsPortraitContent, isCondensed: playerShapeIsCurrent && player.inlineCondensed
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            bodyStageReader
                .ignoresSafeArea(
                    usesImmersivePortraitLayout ? .all : .keyboard,
                    edges: usesImmersivePortraitLayout ? .all : (usesWideCompanionLayout ? .bottom : [])
                )

            if usesWideCompanionLayout, !isRoomOffline,
               viewModel.roomInfo != nil, AuthManager.shared.isLoggedIn {
                LiveRoomWideDanmakuInputView(
                    roomID: roomID,
                    viewModel: viewModel,
                    danmakuDraft: danmakuDraft,
                    isFocused: $isDanmakuFocused,
                    containerWidth: inlineContainerSize.width
                )
            }
        }
        .onPreferenceChange(LivePortraitInputBarHeightKey.self) { measuredHeight in
            guard measuredHeight > 0,
                  abs(measuredHeight - portraitInputBarHeight) > 0.5
            else {
                return
            }
            portraitInputBarHeight = measuredHeight
        }
        .playerDetailChrome(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isStatusBarHidden: player.isFullscreen || usesImmersivePortraitLayout,
            guardsIPadTopSafeArea: !usesImmersivePortraitLayout,
            presentationContext: presentationContext,
            coordinator: coordinator,
            liveRoom: viewModel
        ) {
            if usesImmersivePortraitLayout {
                Color.black.ignoresSafeArea()
            } else {
                CinematicBackdrop(
                    coverURL: viewModel.roomInfo?.coverURL(for: .roomPoster),
                    player: player,
                    ownerLease: viewModel.playerOwnerLease,
                    isRouteActive: isActiveLiveRoute
                )
            }
        }
        .playerDetailInlineContainerSize(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive
        ) { size in
            if inlineContainerSize != size { inlineContainerSize = size }
        }
        .onChange(of: isActiveLiveRoute, initial: true) { oldActive, active in
            if !active, oldActive {
                viewModel.revokeLoadForRouteDeparture()
                player.pauseForRouteDeparture(lease: viewModel.playerOwnerLease)
            }
        }
        .task(id: isActiveLiveRoute) {
            guard isActiveLiveRoute else { return }
            player.endForeignOwnerForRouteActivation(incomingOwner: PlayerViewModel.liveOwner(roomID))
            await viewModel.load(roomID: roomID, requestAdmission: { isActiveLiveRoute })
        }
        .task(id: viewModel.roomInfo?.uid) {
            await viewModel.loadBroadcaster(uid: viewModel.roomInfo?.uid, authManager: authManager)
        }
        .onDisappear {
            portraitKeyboardFrame = nil
            isDanmakuFocused = false
            guard scenePhase == .active else { return }
            let departingLease = viewModel.playerOwnerLease
            guard viewModel.endPlayback() == .ownershipEnded else { return }
            danmakuDraft.cancelSend()
            viewModel.disconnect()
            if player.currentOwnerLease == nil || player.currentOwnerLease == departingLease {
                restoreScaleModeAfterImmersivePortrait()
            } else {
                scaleModeBeforeImmersivePortrait = nil
            }
        }
        .onChange(of: isDanmakuFocused) { _, focused in
            guard usesImmersivePortraitLayout,
                  let lease = viewModel.playerOwnerLease, player.isCurrentOwner(lease) else { return }
            if focused {
                if !player.showControls { player.showControls = true }
            } else {
                player.scheduleHideControls()
            }
        }
        .onChange(of: shouldUseImmersiveFillScale) { _, isImmersive in
            guard let lease = viewModel.playerOwnerLease, player.isCurrentOwner(lease) else {
                scaleModeBeforeImmersivePortrait = nil
                return
            }
            if isImmersive {
                if scaleModeBeforeImmersivePortrait == nil {
                    scaleModeBeforeImmersivePortrait = player.scaleMode
                }
                player.scaleMode = .fill
            } else {
                restoreScaleModeAfterImmersivePortrait()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            portraitKeyboardFrame = nil
            isDanmakuFocused = false
            danmakuDraft.cancelSend()
        }
    }

    private var bodyStageReader: some View {
        GeometryReader { geometry in
            let windowSafeArea = keyWindowSafeAreaInsets
            let physicalTopInset = max(windowSafeArea?.top ?? 0, geometry.safeAreaInsets.top)
            let physicalBottomInset = usesImmersivePortraitLayout
                ? AppWindowMetrics.bottomInset(orAtLeast: geometry.safeAreaInsets.bottom)
                : (windowSafeArea?.bottom ?? geometry.safeAreaInsets.bottom)
            let keyboardEffectiveBottomInset = LivePortraitKeyboardLayout.effectiveBottomInset(
                physicalBottomInset: physicalBottomInset,
                keyboardFrame: portraitKeyboardFrame,
                containerFrame: keyWindowFrameInScreen ?? unsafeAreaContainerFrame(geometry)
            )
            let overlayBoxHeight = keyWindowFrameInScreen?.height
                ?? (geometry.size.height
                    + geometry.safeAreaInsets.top
                    + geometry.safeAreaInsets.bottom)
            let safeAreaLayout = LivePortraitSafeAreaLayout.resolve(
                isImmersivePortrait: usesImmersivePortraitLayout,
                topSafeAreaInset: physicalTopInset,
                physicalBottomSafeAreaInset: physicalBottomInset,
                keyboardEffectiveBottomInset: keyboardEffectiveBottomInset
            )
            let hasInput = AuthManager.shared.isLoggedIn
            let hasImmersiveTransport = viewModel.streamUnavailable == nil
                && viewModel.error == nil
                && !isCurrentRoomPlaybackUnavailable
            let minimumTransportHeight: CGFloat = if hasImmersiveTransport {
                LivePortraitOverlayMetrics.minimumInputHeight
                    + (hasInput ? LivePortraitOverlayMetrics.transportRowSpacing : 0)
            } else {
                0
            }
            let overlayMetrics = LivePortraitOverlayMetrics.resolve(
                containerHeight: overlayBoxHeight,
                topOverlayPadding: safeAreaLayout.topOverlayPadding,
                bottomOverlayPadding: safeAreaLayout.bottomOverlayPadding,
                headerHeight: immersiveHeaderHeight,
                inputHeight: hasInput ? portraitInputBarHeight : 0,
                minimumInputHeight: hasInput
                    ? LivePortraitOverlayMetrics.minimumInputHeight
                    : 0,
                transportHeight: hasImmersiveTransport ? immersiveTransportHeight : 0,
                minimumTransportHeight: minimumTransportHeight,
                minimumHeaderHeight: LivePortraitOverlayMetrics.immersiveMinimumHeaderHeight
            )

            let hasStandardInput = hasInput && !isRoomOffline
            let chromeReservation = LivePortraitOverlayMetrics.reservedHeader(
                headerHeight: standardHeaderHeight
            ) + LivePortraitOverlayMetrics.reservedInput(
                inputHeight: hasStandardInput ? portraitInputBarHeight : 0,
                minimumInputHeight: hasStandardInput
                    ? LivePortraitOverlayMetrics.minimumInputHeight
                    : 0
            )

            let hostChrome = safeAreaLayout.hostChromeExtent(
                metrics: overlayMetrics,
                hasInput: hasInput,
                hasTransport: hasImmersiveTransport
            )

            let compactStack = videoStack(
                containerWidth: geometry.size.width,
                boxHeight: overlayBoxHeight,
                chromeBoxHeight: geometry.size.height,
                chromeReservation: chromeReservation,
                hostChrome: hostChrome
            )
            ZStack {
                inlineContent(compact: compactStack)
                    .ignoresSafeArea(
                        usesImmersivePortraitLayout ? .all : .container,
                        edges: usesImmersivePortraitLayout ? .all : []
                    )

                if usesImmersivePortraitLayout {
                    LiveRoomPortraitImmersionView(
                        roomID: roomID,
                        viewModel: viewModel,
                        player: player,
                        danmakuDraft: danmakuDraft,
                        isDanmakuFocused: $isDanmakuFocused,
                        roomAvailability: roomAvailability,
                        isRoomOffline: isRoomOffline,
                        isCurrentRoomPlaybackUnavailable: isCurrentRoomPlaybackUnavailable,
                        layout: safeAreaLayout,
                        containerSize: geometry.size,
                        metrics: overlayMetrics,
                        boxHeight: overlayBoxHeight,
                        keyWindowSafeAreaInsets: windowSafeArea
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(LivePortraitHeaderHeightKey.self) { measuredHeight in
                guard measuredHeight > 0 else { return }
                if usesImmersivePortraitLayout {
                    guard abs(measuredHeight - immersiveHeaderHeight) > 0.5 else { return }
                    immersiveHeaderHeight = measuredHeight
                } else {
                    guard abs(measuredHeight - standardHeaderHeight) > 0.5 else { return }
                    standardHeaderHeight = measuredHeight
                }
            }
            .onPreferenceChange(LivePortraitTransportHeightKey.self) { measuredHeight in
                guard measuredHeight > 0,
                      abs(measuredHeight - immersiveTransportHeight) > 0.5
                else {
                    return
                }
                immersiveTransportHeight = measuredHeight
            }
            .modifier(LiveKeyboardFrameTracker(frame: $portraitKeyboardFrame))
        }
    }

    @ViewBuilder
    private func inlineContent<Compact: View>(compact: Compact) -> some View {
        if usesWideCompanionLayout {
            LiveRoomWideStageView(
                roomID: roomID,
                routePosition: routePosition,
                viewModel: viewModel,
                player: player,
                isActiveLiveRoute: isActiveLiveRoute,
                roomAvailability: roomAvailability,
                isRoomOffline: isRoomOffline,
                streamIsPortraitContent: streamIsPortraitContent,
                standardHeaderHeight: standardHeaderHeight,
                portraitInputBarHeight: portraitInputBarHeight,
                playerPageNavigation: playerPageNavigation
            )
        } else {
            compact
        }
    }

    private func videoStack(
        containerWidth: CGFloat,
        boxHeight: CGFloat,
        chromeBoxHeight: CGFloat,
        chromeReservation: CGFloat,
        hostChrome: LiveHostChromeExtent
    ) -> some View {
        let isImmersive = usesImmersivePortraitLayout
        let primaryWidth = containerWidth
        let companionWidth = containerWidth
        let playerHeight = playerInlineHeight(containerWidth: containerWidth, boxHeight: boxHeight)
        let viewportHeight = max(0, chromeBoxHeight)
        let companionViewport = max(0, viewportHeight - playerHeight)
        let minimumChatHeight = viewModel.roomInfo != nil && !isRoomOffline
            ? LivePortraitOverlayMetrics.minimumInputHeight * 2 : 0
        let companionReservation = viewModel.roomInfo == nil ? 0 : chromeReservation
        let chatHeight = max(minimumChatHeight, companionViewport - companionReservation)
        let minimumCompanionHeight = companionReservation + minimumChatHeight
        let needsOuterScroll = !isImmersive && playerHeight + minimumCompanionHeight > viewportHeight
        return ScrollView(needsOuterScroll ? .vertical : []) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView([]) {
                    LiveRoomInlinePlayerHost(
                        roomID: roomID,
                        routePosition: routePosition,
                        viewModel: viewModel,
                        player: player,
                        isActiveLiveRoute: isActiveLiveRoute,
                        isRoomOffline: isRoomOffline,
                        usesImmersivePortraitLayout: isImmersive,
                        width: primaryWidth,
                        height: playerHeight,
                        isImmersive: isImmersive,
                        hostChrome: hostChrome,
                        playerPageNavigation: playerPageNavigation
                    )
                }
                .scrollClipDisabled()
                .frame(width: primaryWidth, height: playerHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if !player.isFullscreenPresentationActive, !isImmersive {
                        LiveRoomInlineNavigationOverlay(
                            player: player,
                            viewModel: viewModel,
                            isActiveLiveRoute: isActiveLiveRoute,
                            isRoomOffline: isRoomOffline,
                            width: primaryWidth,
                            height: playerHeight,
                            actions: playerPageNavigation
                        )
                    }
                }

                ScrollView([]) {
                    if !isImmersive {
                        LiveRoomStandardCompanionView(
                            roomID: roomID,
                            viewModel: viewModel,
                            danmakuDraft: danmakuDraft,
                            isDanmakuFocused: $isDanmakuFocused,
                            roomAvailability: roomAvailability,
                            isRoomOffline: isRoomOffline,
                            chatHeight: chatHeight
                        )
                        .frame(width: companionWidth)
                    }
                }
                .frame(
                    width: companionWidth,
                    height: isImmersive ? 0 : max(companionViewport, minimumCompanionHeight),
                    alignment: .topLeading
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func unsafeAreaContainerFrame(_ geometry: GeometryProxy) -> CGRect {
        let inset = geometry.frame(in: .global)
        let insets = geometry.safeAreaInsets
        return CGRect(
            x: inset.minX - insets.leading,
            y: inset.minY - insets.top,
            width: inset.width + insets.leading + insets.trailing,
            height: inset.height + insets.top + insets.bottom
        )
    }

    private func restoreScaleModeAfterImmersivePortrait() {
        guard let previous = scaleModeBeforeImmersivePortrait else { return }
        scaleModeBeforeImmersivePortrait = nil
        player.scaleMode = previous
    }
}
