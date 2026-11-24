import SwiftUI
import UIKit

struct LivePortraitSafeAreaLayout: Equatable, Sendable {
    static let topDesignSpacing: CGFloat = 12
    static let bottomDesignSpacing: CGFloat = 10

    let topSafeAreaInset: CGFloat
    let physicalBottomSafeAreaInset: CGFloat
    let effectiveBottomSafeAreaInset: CGFloat
    let keyboardDisplacement: CGFloat
    let topOverlayPadding: CGFloat
    let bottomOverlayPadding: CGFloat

    static func resolve(
        isImmersivePortrait: Bool,
        topSafeAreaInset: CGFloat,
        physicalBottomSafeAreaInset: CGFloat,
        keyboardEffectiveBottomInset: CGFloat? = nil,
        topDesignSpacing: CGFloat = Self.topDesignSpacing,
        bottomDesignSpacing: CGFloat = Self.bottomDesignSpacing
    ) -> Self {
        guard isImmersivePortrait else {
            return Self(
                topSafeAreaInset: 0,
                physicalBottomSafeAreaInset: 0,
                effectiveBottomSafeAreaInset: 0,
                keyboardDisplacement: 0,
                topOverlayPadding: 0,
                bottomOverlayPadding: 0
            )
        }

        let topSpacing = max(0, topDesignSpacing)
        let bottomSpacing = max(0, bottomDesignSpacing)
        let topInset = max(0, topSafeAreaInset)
        let physicalBottomInset = max(0, physicalBottomSafeAreaInset)
        let keyboardInset = max(0, keyboardEffectiveBottomInset ?? physicalBottomInset)
        let effectiveBottomInset = max(physicalBottomInset, keyboardInset)

        return Self(
            topSafeAreaInset: topInset,
            physicalBottomSafeAreaInset: physicalBottomInset,
            effectiveBottomSafeAreaInset: effectiveBottomInset,
            keyboardDisplacement: max(0, effectiveBottomInset - physicalBottomInset),
            topOverlayPadding: topInset + topSpacing,
            bottomOverlayPadding: effectiveBottomInset + bottomSpacing
        )
    }
}

extension LivePortraitSafeAreaLayout {
    func hostChromeExtent(
        metrics: LivePortraitOverlayMetrics,
        hasInput: Bool,
        hasTransport: Bool = false
    ) -> LiveHostChromeExtent {
        LiveHostChromeExtent(
            top: max(0, topOverlayPadding) + max(0, metrics.reservedHeaderHeight),
            bottom: max(0, bottomOverlayPadding)
                + (hasInput ? max(0, metrics.reservedInputHeight) : 0)
                + (hasTransport ? max(0, metrics.reservedTransportHeight) : 0),
            bottomInterceptsTouches: metrics.showsChatList
        )
    }
}

private struct LiveKeyboardFrameTracker: ViewModifier {
    @Binding var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { notification in
                guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
                      value.cgRectValue.width > 0, value.cgRectValue.height > 0 else {
                    frame = nil
                    return
                }
                frame = value.cgRectValue
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                frame = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                frame = nil
            }
    }
}

struct LiveHostChromeExtent: Equatable, Sendable {
    let top: CGFloat
    let bottom: CGFloat
    let bottomInterceptsTouches: Bool
}

struct LivePortraitKeyboardLayout: Equatable, Sendable {
    private static let bottomIntersectionTolerance: CGFloat = 1

    static func effectiveBottomInset(
        physicalBottomInset: CGFloat,
        keyboardFrame: CGRect?,
        containerFrame: CGRect
    ) -> CGFloat {
        let physical = max(0, physicalBottomInset)
        guard let keyboardFrame,
              keyboardFrame.width > 0,
              keyboardFrame.height > 0,
              keyboardFrame.minX.isFinite,
              keyboardFrame.maxX.isFinite,
              keyboardFrame.minY.isFinite,
              keyboardFrame.maxY.isFinite,
              containerFrame.width > 0,
              containerFrame.height > 0
        else {
            return physical
        }

        let horizontalOverlap = min(containerFrame.maxX, keyboardFrame.maxX)
            - max(containerFrame.minX, keyboardFrame.minX)
        guard horizontalOverlap > 0,
              keyboardFrame.maxY >= containerFrame.maxY - bottomIntersectionTolerance
        else {
            return physical
        }

        let overlapTop = max(containerFrame.minY, keyboardFrame.minY)
        let overlapBottom = min(containerFrame.maxY, keyboardFrame.maxY)
        let keyboardOverlap = max(0, overlapBottom - overlapTop)
        return max(physical, keyboardOverlap)
    }
}

private struct ImmersiveChromeFade: ViewModifier {
    let isActive: Bool
    let animation: Animation?

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .animation(animation, value: isActive)
    }
}

struct LivePortraitOverlayMetrics: Equatable, Sendable {
    static let minimumInputHeight: CGFloat = 44
    static let preferredChatHeight: CGFloat = 300
    static let minimumHeaderHeight: CGFloat = 56
    static let transportRowSpacing: CGFloat = 6
    static let immersiveMinimumHeaderHeight: CGFloat = 64

    let availableHeight: CGFloat
    let reservedHeaderHeight: CGFloat
    let reservedInputHeight: CGFloat
    let reservedTransportHeight: CGFloat
    let chatHeight: CGFloat

    var showsChatList: Bool { chatHeight > 0 }
    var reservedBottomHeight: CGFloat { reservedInputHeight + reservedTransportHeight }

    static func reservedHeader(
        headerHeight: CGFloat,
        minimumHeaderHeight: CGFloat = Self.minimumHeaderHeight
    ) -> CGFloat {
        max(max(0, minimumHeaderHeight), max(0, headerHeight))
    }

    static func reservedInput(
        inputHeight: CGFloat,
        minimumInputHeight: CGFloat = Self.minimumInputHeight
    ) -> CGFloat {
        max(max(0, minimumInputHeight), max(0, inputHeight))
    }

    static func resolve(
        containerHeight: CGFloat,
        topOverlayPadding: CGFloat,
        bottomOverlayPadding: CGFloat,
        headerHeight: CGFloat,
        inputHeight: CGFloat,
        preferredChatHeight: CGFloat = Self.preferredChatHeight,
        minimumInputHeight: CGFloat = Self.minimumInputHeight,
        transportHeight: CGFloat = 0,
        minimumTransportHeight: CGFloat = 0,
        minimumHeaderHeight: CGFloat = Self.minimumHeaderHeight
    ) -> Self {
        let availableHeight = max(
            0,
            containerHeight - max(0, topOverlayPadding) - max(0, bottomOverlayPadding)
        )
        let reservedInputHeight = reservedInput(
            inputHeight: inputHeight,
            minimumInputHeight: minimumInputHeight
        )
        let reservedTransportHeight = reservedInput(
            inputHeight: transportHeight,
            minimumInputHeight: minimumTransportHeight
        )
        let reservedHeaderHeight = reservedHeader(
            headerHeight: headerHeight,
            minimumHeaderHeight: minimumHeaderHeight
        )
        let chatSpace = max(
            0,
            availableHeight - reservedHeaderHeight - reservedInputHeight - reservedTransportHeight
        )
        let chatHeight = min(max(0, preferredChatHeight), chatSpace)

        return Self(
            availableHeight: availableHeight,
            reservedHeaderHeight: reservedHeaderHeight,
            reservedInputHeight: reservedInputHeight,
            reservedTransportHeight: reservedTransportHeight,
            chatHeight: chatHeight
        )
    }
}

struct LivePortraitHostLayout: Equatable, Sendable {
    let showsArea: Bool
    let showsPopularity: Bool
    let showsQualityLabel: Bool

    static func resolve(
        width: CGFloat,
        isAccessibilitySize: Bool = false
    ) -> Self {
        let normalizedWidth = max(0, width)
        if isAccessibilitySize || normalizedWidth <= 320 {
            return Self(showsArea: false, showsPopularity: false, showsQualityLabel: false)
        }
        if normalizedWidth < 390 {
            return Self(showsArea: false, showsPopularity: true, showsQualityLabel: false)
        }
        return Self(showsArea: true, showsPopularity: true, showsQualityLabel: true)
    }
}

private struct LiveAreaBreadcrumb: View {
    let parentAreaName: String
    let areaName: String
    let textStyle: AnyShapeStyle
    let separatorStyle: AnyShapeStyle

    private var levels: [String] {
        [parentAreaName, areaName].filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .imageScale(.small)
                        .foregroundStyle(separatorStyle)
                        .accessibilityHidden(true)
                }
                Text(level)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(textStyle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(levels.joined(separator: ", ")))
    }
}

private struct LiveStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LivePortraitInputBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LivePortraitTransportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LivePortraitHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum LiveRoomAvailability: Equatable {
    case loading
    case live
    case roundPlay
    case offline

    static func resolve(liveStatus: Int?) -> Self {
        guard let liveStatus else { return .loading }
        switch LiveRoomStatusPolicy.state(liveStatus: liveStatus) {
        case .live: return .live
        case .roundPlay: return .roundPlay
        case .offline: return .offline
        case .unknown: return .live
        }
    }

    var isOffline: Bool { self == .offline }

    var statusText: String {
        switch self {
        case .loading: String(localized: "LIVE")
        case .live: String(localized: "LIVE")
        case .roundPlay: String(localized: "ROUND")
        case .offline: String(localized: "OFFLINE")
        }
    }

    var announcedStatusText: String? {
        switch self {
        case .loading, .live: nil
        case .roundPlay: String(localized: "ROUND")
        case .offline: String(localized: "OFFLINE")
        }
    }

    var statusColor: Color {
        switch self {
        case .loading: .secondary
        case .live: .red
        case .roundPlay: .orange
        case .offline: .secondary
        }
    }
}

enum LiveChatRenderPolicy {
    static let standardVisibleMessageLimit = 200
    static let immersiveVisibleMessageLimit = 80

    static func standardVisibleMessages(
        from messages: [ChatMessage]
    ) -> ArraySlice<ChatMessage> {
        messages.suffix(standardVisibleMessageLimit)
    }

    static func immersiveVisibleMessages(
        from messages: [ChatMessage]
    ) -> ArraySlice<ChatMessage> {
        messages.suffix(immersiveVisibleMessageLimit)
    }
}

final class LiveChatAutoScrollPolicy<ID: Hashable> {
    private(set) var lastRequestedID: ID?

    func nextTarget(for latestID: ID?) -> ID? {
        guard let latestID else {
            lastRequestedID = nil
            return nil
        }
        guard latestID != lastRequestedID else { return nil }
        lastRequestedID = latestID
        return latestID
    }

    func reset() {
        lastRequestedID = nil
    }
}

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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.authManager) private var authManager
    @Environment(\.accentStore) private var accentStore
    @State private var scaleModeBeforeImmersivePortrait: VideoScaleMode?
    @State private var inlineContainerSize: CGSize = .zero
    @State private var portraitKeyboardFrame: CGRect?
    @State private var portraitInputBarHeight = LivePortraitOverlayMetrics.minimumInputHeight
    @State private var immersiveTransportHeight = LivePortraitOverlayMetrics.minimumInputHeight
    @State private var immersiveHeaderHeight = LivePortraitOverlayMetrics.minimumHeaderHeight
    @State private var standardHeaderHeight = LivePortraitOverlayMetrics.minimumHeaderHeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private var isPlayerOwner: Bool {
        player.ownerKey == PlayerViewModel.liveOwner(roomID)
    }

    @AppStorage("show_network_speed") private var showNetworkSpeed = false
    private var roomAvailability: LiveRoomAvailability {
        LiveRoomAvailability.resolve(liveStatus: viewModel.roomInfo?.liveStatus)
    }
    private var isRoomOffline: Bool { roomAvailability.isOffline }

    private var isImmersiveChromeActive: Bool {
        player.showControls || isDanmakuFocused || !player.isPlaying
            || viewModel.streamUnavailable != nil || viewModel.error != nil || isRoomOffline
    }

    private var immersiveChromeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

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

    private var hostOwnsInlineSurface: Bool {
        PlayerDetailSurfacePolicy.hostOwnsInlineSurface(player: player, lease: viewModel.playerOwnerLease)
    }

    private var playerPageNavigation: PlayerPageNavigationActions {
        PlayerPageNavigationActions(
            onBack: { coordinator.goBack() }, onHome: { coordinator.goHome() },
            onDownload: nil, onReport: nil, pageOwnsInlineNavigation: true
        )
    }

    private var hasInlineExitChrome: Bool {
        guard isActiveLiveRoute, !isRoomOffline, viewModel.streamUnavailable == nil,
              viewModel.error == nil, player.error == nil,
              let lease = viewModel.playerOwnerLease else { return false }
        return player.isCurrentOwner(lease) && player.mode == .live
            && player.surfaceLease(matching: lease, role: .inline) != nil
    }

    private var inlineQualityControl: LiveQualityControl? {
        guard !usesImmersivePortraitLayout, isActiveLiveRoute, !player.isFullscreenPresentationActive,
              canChooseQuality, let lease = viewModel.playerOwnerLease,
              player.isCurrentOwner(lease), player.mode == .live else { return nil }
        let room = viewModel
        let expectedRoomID = roomID
        let expectedRoutePosition = routePosition
        let navigation = coordinator
        return LiveQualityControl(
            options: room.availableQualities.map { .init(qn: $0.qn, label: $0.label) },
            current: room.currentQuality,
            select: { [weak room] quality in
                guard let room, room.playerOwnerLease == lease,
                      PlayerViewModel.shared.isCurrentOwner(lease),
                      !PlayerViewModel.shared.isFullscreen,
                      navigation.isActivePlayerRoute(.live(expectedRoomID), position: expectedRoutePosition),
                      room.streamUnavailable == nil,
                      room.availableQualities.contains(where: { $0.qn == quality }) else { return }
                Task { @MainActor [weak room] in
                    guard let room, room.playerOwnerLease == lease,
                          PlayerViewModel.shared.isCurrentOwner(lease),
                          !PlayerViewModel.shared.isFullscreen,
                          navigation.isActivePlayerRoute(.live(expectedRoomID), position: expectedRoutePosition),
                          room.streamUnavailable == nil,
                          room.availableQualities.contains(where: { $0.qn == quality }) else { return }
                    await room.switchQuality(roomID: expectedRoomID, quality: quality)
                }
            }
        )
    }

    private func playerInlineHeight(containerWidth: CGFloat, boxHeight: CGFloat) -> CGFloat {
        if usesImmersivePortraitLayout { return max(0, boxHeight).rounded() }
        if usesWideCompanionLayout {
            return wideStageMetrics(in: CGSize(width: containerWidth, height: boxHeight)).playerSize.height
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
                wideDanmakuInput
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
            liveRoom: viewModel,
            watchdogScreen: "LiveRoom"
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
                    immersivePortraitOverlay(
                        layout: safeAreaLayout,
                        containerSize: geometry.size,
                        metrics: overlayMetrics,
                        boxHeight: overlayBoxHeight
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
            wideStage()
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
                    inlinePlayerContent(
                        width: primaryWidth, height: playerHeight, isImmersive: isImmersive,
                        hostChrome: hostChrome
                    )
                }
                .scrollClipDisabled()
                .frame(width: primaryWidth, height: playerHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if !player.isFullscreenPresentationActive, !isImmersive {
                        inlineNavigationOverlay(width: primaryWidth, height: playerHeight)
                    }
                }

                ScrollView([]) {
                    if !isImmersive {
                        standardRoomCompanion(chatHeight: chatHeight)
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

    @ViewBuilder
    private func inlinePlayerContent(
        width: CGFloat, height: CGFloat, isImmersive: Bool,
        hostChrome: LiveHostChromeExtent, cornerRadius: CGFloat = 0
    ) -> some View {
        let showsLoadingIndicator = !isRoomOffline
            && viewModel.streamUnavailable == nil
            && viewModel.error == nil
        Group {
            if isActiveLiveRoute {
                if hostOwnsInlineSurface {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(width: width, height: height)
                } else {
                    PlayerView(
                        owner: PlayerViewModel.liveOwner(roomID),
                        liveQualityControl: inlineQualityControl,
                        container: isImmersive
                            ? .inlineFullBleed(
                                hostChromeTop: hostChrome.top, hostChromeBottom: hostChrome.bottom,
                                hostOwnsTransportRow: true
                            )
                            : .inlineSafeArea,
                        pageNavigationActions: isImmersive ? nil : playerPageNavigation,
                        inlineViewportSize: CGSize(width: width, height: height),
                        inlineCornerRadius: cornerRadius,
                        screenLease: viewModel.playerOwnerLease,
                        placeholderCoverURL: viewModel.roomInfo?.coverURL(for: .roomPoster),
                        showsLoadingIndicator: showsLoadingIndicator
                    )
                    .frame(width: width, height: height)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                        if isActiveLiveRoute, !player.isFullscreenPresentationActive,
                           let lease = viewModel.playerOwnerLease, player.isCurrentOwner(lease),
                           player.surfaceLease(matching: lease, role: .inline) != nil {
                            player.refreshInlineVideoRect()
                        }
                    }
                    .overlay {
                        if let refusal = viewModel.streamUnavailable {
                            unavailablePlayerOverlay(refusal)
                        } else if isRoomOffline {
                            offlinePlayerOverlay
                        } else if let loadError = viewModel.error, player.error == nil {
                            errorPlayerOverlay(loadError)
                        }
                    }
                    .background {
                        (isImmersive ? Color.black : Color.clear)
                            .ignoresSafeArea(edges: .top)
                    }
                }
            } else {
                RouteActivationPlaceholderView(
                    still: player.outgoingRouteStill(for: PlayerViewModel.liveOwner(roomID)),
                    coverURL: viewModel.roomInfo?.coverURL(for: .roomPoster),
                    height: height,
                    cornerRadius: cornerRadius
                )
                .frame(width: width, height: height)
            }
        }
        .background {
            PlayerInlineSlotProbe(cornerRadius: cornerRadius)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func inlineNavigationOverlay(width: CGFloat, height: CGFloat) -> some View {
        PlayerDetailInlineNavigationOverlay(
            player: player,
            isActiveRoute: isActiveLiveRoute,
            hasInlineExitChrome: { hasInlineExitChrome },
            scrimWidth: width,
            scrimHeight: height,
            actions: playerPageNavigation
        )
    }

    // MARK: - iPad landscape stage

    private struct WideStageMetrics {
        let panelWidth: CGFloat
        let columnWidth: CGFloat
        let playerSize: CGSize
    }

    private func wideStageMetrics(in size: CGSize) -> WideStageMetrics {
        let margin = DetailStageLayout.outerMargin
        let gap = DetailStageLayout.columnGap
        let headerGap = AppSpacing.l
        let panelWidth = DetailSplitPolicy.companionColumnWidth(containerWidth: size.width)
        let columnWidth = max(0, size.width - panelWidth - margin * 2 - gap)
        let infoReserve = viewModel.roomInfo == nil ? 0 : standardHeaderHeight + headerGap
        let maxHeight = max(0, size.height - margin * 2 - infoReserve)
        let playerSize: CGSize
        if streamIsPortraitContent, !isRoomOffline {
            let width = min(columnWidth, maxHeight * 9.0 / 16.0)
            playerSize = CGSize(width: width, height: width * 16.0 / 9.0)
        } else {
            let width = min(columnWidth, maxHeight * 16.0 / 9.0)
            playerSize = CGSize(width: width, height: width * 9.0 / 16.0)
        }
        return WideStageMetrics(panelWidth: panelWidth, columnWidth: columnWidth, playerSize: playerSize)
    }

    private func wideStage() -> some View {
        GeometryReader { proxy in
            let metrics = wideStageMetrics(in: proxy.size)
            HStack(alignment: .top, spacing: DetailStageLayout.columnGap) {
                wideStageLeftColumn(metrics: metrics)
                wideStageChatPanel(metrics: metrics)
            }
            .padding(.horizontal, DetailStageLayout.outerMargin)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wideStageLeftColumn(metrics: WideStageMetrics) -> some View {
        let playerShape = RoundedRectangle(cornerRadius: DetailStageLayout.playerCornerRadius, style: .continuous)
        let barShape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        return VStack(spacing: AppSpacing.l) {
            inlinePlayerContent(
                width: metrics.playerSize.width, height: metrics.playerSize.height,
                isImmersive: false,
                hostChrome: LiveHostChromeExtent(top: 0, bottom: 0, bottomInterceptsTouches: false),
                cornerRadius: DetailStageLayout.playerCornerRadius
            )
            .frame(width: metrics.playerSize.width, height: metrics.playerSize.height)
            .clipShape(playerShape)
            .overlay(alignment: .topLeading) {
                if !player.isFullscreenPresentationActive {
                    inlineNavigationOverlay(
                        width: metrics.playerSize.width, height: metrics.playerSize.height
                    )
                    .clipShape(playerShape)
                }
            }
            .frame(maxWidth: .infinity)
            if let info = viewModel.roomInfo {
                roomInfoBar(info, showsDivider: false, isWideStage: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LivePortraitHeaderHeightKey.self, value: proxy.size.height
                            )
                        }
                    }
                    .background {
                        Color.clear
                            .appCardSurface(in: barShape)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        }
        .frame(width: metrics.columnWidth, alignment: .top)
        .padding(.top, DetailStageLayout.outerMargin)
    }

    private func wideStageChatPanel(metrics: WideStageMetrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: DetailStageLayout.panelCornerRadius, style: .continuous)
        let hasInput = viewModel.roomInfo != nil && !isRoomOffline && AuthManager.shared.isLoggedIn
        return VStack(spacing: 0) {
            if viewModel.roomInfo != nil {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if !isRoomOffline {
                            LiveStandardChatView(viewModel: viewModel, isWide: true)
                        }
                    }
                Color.clear
                    .frame(height: hasInput ? portraitInputBarHeight + AppSpacing.m : 0)
            } else if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(maxHeight: .infinity)
            }
        }
        .frame(width: metrics.panelWidth)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .background {
            Color.clear
                .appCardSurface(in: shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.top, DetailStageLayout.outerMargin)
        .padding(.bottom, DetailStageLayout.outerMargin)
    }

    private var wideDanmakuInput: some View {
        let isFloating = isDanmakuFocused
        let panelWidth = DetailSplitPolicy.companionColumnWidth(containerWidth: inlineContainerSize.width)
        return LiveDanmakuInputBar(
            style: isFloating ? .floating : .standard,
            draft: danmakuDraft,
            isFocused: $isDanmakuFocused,
            roomID: roomID,
            viewModel: viewModel
        )
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LivePortraitInputBarHeightKey.self, value: proxy.size.height
                )
            }
        }
        .frame(maxWidth: isFloating ? IPadKeyboardComposerLayout.maxWidth : panelWidth)
        .padding(.horizontal, isFloating ? AppSpacing.l : 0)
        .padding(.trailing, isFloating ? 0 : DetailStageLayout.outerMargin)
        .padding(.bottom, isFloating ? 6 : DetailStageLayout.outerMargin + AppSpacing.s)
        .frame(maxWidth: .infinity, alignment: isFloating ? .center : .trailing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isFloating)
    }

    private func standardRoomCompanion(chatHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let info = viewModel.roomInfo {
                roomInfoBar(info)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LivePortraitHeaderHeightKey.self, value: proxy.size.height
                            )
                        }
                    }

                Color.clear
                    .frame(height: chatHeight)
                    .overlay(alignment: .topLeading) {
                        if !isRoomOffline {
                            LiveStandardChatView(viewModel: viewModel, isWide: false)
                        }
                    }

                if !isRoomOffline && AuthManager.shared.isLoggedIn {
                    LiveDanmakuInputBar(
                        style: .standard,
                        draft: danmakuDraft,
                        isFocused: $isDanmakuFocused,
                        roomID: roomID,
                        viewModel: viewModel
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: LivePortraitInputBarHeightKey.self, value: proxy.size.height
                                )
                            }
                        }
                }
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: chatHeight)
            } else {
                Color.clear
                    .frame(height: chatHeight)
            }
        }
    }

    // MARK: - Immersive portrait live

    private func immersivePortraitOverlay(
        layout: LivePortraitSafeAreaLayout,
        containerSize: CGSize,
        metrics: LivePortraitOverlayMetrics,
        boxHeight: CGFloat
    ) -> some View {
        let hasInput = AuthManager.shared.isLoggedIn
        return ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.20), .black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(280, boxHeight * 0.46))
            .opacity(isImmersiveChromeActive ? 1.0 : 0.65)
            .animation(immersiveChromeAnimation, value: isImmersiveChromeActive)
            .allowsHitTesting(false)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if let info = viewModel.roomInfo {
                    immersiveRoomInfoBar(info, containerWidth: containerSize.width)
                        .padding(.horizontal, 12)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: LivePortraitHeaderHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        }
                        .padding(.top, layout.topOverlayPadding)
                        .modifier(ImmersiveChromeFade(
                            isActive: isImmersiveChromeActive,
                            animation: immersiveChromeAnimation
                        ))
                }

                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    if metrics.showsChatList {
                        LiveImmersiveChatView(viewModel: viewModel)
                            .frame(height: metrics.chatHeight)
                            .opacity(isImmersiveChromeActive ? 1.0 : 0.60)
                            .animation(immersiveChromeAnimation, value: isImmersiveChromeActive)
                    }

                    if viewModel.streamUnavailable == nil,
                       viewModel.error == nil,
                       !isCurrentRoomPlaybackUnavailable {
                        immersiveTransportRow
                            .padding(.horizontal, 12)
                            .padding(.bottom, hasInput ? LivePortraitOverlayMetrics.transportRowSpacing : 0)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: LivePortraitTransportHeightKey.self,
                                        value: proxy.size.height
                                    )
                                }
                            }
                            .modifier(ImmersiveChromeFade(
                                isActive: isImmersiveChromeActive,
                                animation: immersiveChromeAnimation
                            ))
                    }

                    if hasInput {
                        immersiveDanmakuInputBar()
                            .modifier(ImmersiveChromeFade(
                                isActive: isImmersiveChromeActive,
                                animation: immersiveChromeAnimation
                            ))
                    }
                }
                .padding(.bottom, layout.bottomOverlayPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func immersiveDanmakuInputBar() -> some View {
        LiveDanmakuInputBar(
            style: .immersive,
            draft: danmakuDraft,
            isFocused: $isDanmakuFocused,
            roomID: roomID,
            viewModel: viewModel
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LivePortraitInputBarHeightKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private func unavailablePlayerOverlay(
        _ refusal: LiveRoomStatusPolicy.Refusal
    ) -> some View {
        ContentUnavailableView {
            Label(
                refusal == .roundPlayWithoutStream
                    ? String(localized: "Round play — no stream available")
                    : String(localized: "OFFLINE"),
                systemImage: refusal == .roundPlayWithoutStream
                    ? "arrow.trianglehead.2.clockwise.rotate.90"
                    : "antenna.radiowaves.left.and.right.slash"
            )
        } description: {
            if refusal == .roundPlayWithoutStream {
                Text("The streamer is away and this room's carousel is not available to play.")
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.86))
        .contentShape(Rectangle())
    }

    private var offlinePlayerOverlay: some View {
        ContentUnavailableView(
            "OFFLINE",
            systemImage: "antenna.radiowaves.left.and.right.slash"
        )
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.86))
        .contentShape(Rectangle())
    }

    private func errorPlayerOverlay(_ message: String) -> some View {
        ContentUnavailableView {
            Label {
                Text("Playback Failed")
                    .font(.headline)
                    .foregroundStyle(.white)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
            }
        } description: {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        } actions: {
            Button("Retry") {
                Task {
                    await viewModel.load(roomID: roomID, requestAdmission: { isActiveLiveRoute })
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.isLoading)
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.86))
        .contentShape(Rectangle())
    }

    private var immersiveTransportRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(
                            width: LivePortraitOverlayMetrics.minimumInputHeight,
                            height: LivePortraitOverlayMetrics.minimumInputHeight
                        )
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("live.playPause")
                .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))

                LiveStatusSpeedBadge(
                    roomAvailability: roomAvailability,
                    showNetworkSpeed: showNetworkSpeed,
                    isPlayerOwner: isPlayerOwner,
                    player: player,
                    showsBackground: false
                )
            }
            .liveImmersiveGlass(in: Capsule(), interactive: true)

            Spacer(minLength: 0)

            Button {
                player.requestFullscreenTransition(
                    target: !player.isFullscreen,
                    source: .button
                )
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .liveImmersiveGlass(in: Circle(), interactive: true)
                    .frame(
                        width: LivePortraitOverlayMetrics.minimumInputHeight,
                        height: LivePortraitOverlayMetrics.minimumInputHeight
                    )
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("live.fullscreen")
            .accessibilityLabel(Text("Enter fullscreen"))
        }
    }

    private func immersiveRoomInfoBar(
        _ info: LiveRoomInfo,
        containerWidth: CGFloat
    ) -> some View {
        let hostLayout = LivePortraitHostLayout.resolve(
            width: containerWidth,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        let currentQualityLabel = viewModel.availableQualities.first {
            $0.qn == viewModel.currentQuality
        }?.label ?? String(localized: "Auto")
        let followWidth: CGFloat = viewModel.isFollowingBroadcaster.map { following in
            let text = following ? String(localized: "Following") : String(localized: "+ Follow")
            return LiveChromeLabelWidth.estimate(text, textScale: headerTextScaleProbe / 100) + 20
        } ?? 0
        let budget = LivePortraitHeaderBudget.resolve(
            containerWidth: containerWidth,
            leadingSafeAreaInset: keyWindowSafeAreaInsets?.left ?? 0,
            trailingSafeAreaInset: keyWindowSafeAreaInsets?.right ?? 0,
            preferredQualityLabelWidth: LiveChromeLabelWidth.estimate(
                currentQualityLabel,
                textScale: headerTextScaleProbe / 100
            ),
            showsQualityLabel: hostLayout.showsQualityLabel,
            followControlWidth: followWidth,
            showsQualityControl: canChooseQuality
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: LivePortraitHeaderBudget.interitemSpacing) {
                immersiveBackButton
                immersiveBroadcasterPill(info, hostLayout: hostLayout, budget: budget)
                    .layoutPriority(0)
                Spacer(minLength: 0)
                if canChooseQuality {
                    immersiveQualityPicker(
                        showsLabel: budget.showsQualityLabel,
                        labelMaxWidth: budget.qualityLabelMaxWidth
                    )
                    .layoutPriority(1)
                }
            }

            if !info.title.isEmpty {
                Text(info.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                    .padding(
                        .leading,
                        LivePortraitHeaderBudget.controlSide + LivePortraitHeaderBudget.interitemSpacing
                    )
            }
        }
    }

    private var immersiveBackButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .liveImmersiveGlass(in: Circle(), interactive: true)
                .frame(
                    width: LivePortraitOverlayMetrics.minimumInputHeight,
                    height: LivePortraitOverlayMetrics.minimumInputHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Back"))
        .accessibilitySortPriority(4)
    }

    private func immersiveBroadcasterPill(
        _ info: LiveRoomInfo,
        hostLayout: LivePortraitHostLayout,
        budget: LivePortraitHeaderBudget
    ) -> some View {
        HStack(spacing: 0) {
            immersiveHostIdentityBlock(info, hostLayout: hostLayout, budget: budget)
            if let following = viewModel.isFollowingBroadcaster {
                immersiveFollowButton(mid: info.uid, following: following)
                    .padding(.leading, LivePortraitHeaderBudget.pillFollowSpacing)
            }
        }
        .padding(.leading, LivePortraitHeaderBudget.pillLeadingPadding)
        .padding(
            .trailing,
            viewModel.isFollowingBroadcaster == nil
                ? LivePortraitHeaderBudget.pillTrailingPaddingWithoutFollow
                : LivePortraitHeaderBudget.pillTrailingPaddingWithFollow
        )
        .padding(.vertical, 5)
        .frame(minHeight: 40)
        .liveImmersiveGlass(in: Capsule(), interactive: true)
    }

    private func immersiveHostIdentityBlock(
        _ info: LiveRoomInfo,
        hostLayout: LivePortraitHostLayout,
        budget: LivePortraitHeaderBudget
    ) -> some View {
        let name = viewModel.broadcasterName
        let opensHostProfile = info.uid > 0
        let hostAccessibilityLabel = [
            name,
            roomAvailability.announcedStatusText,
            info.title,
            hostLayout.showsPopularity
                ? String(localized: "\(FormatUtils.viewCount(info.online)) viewers")
                : nil,
            opensHostProfile ? String(localized: "Open \(name)'s profile") : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")

        return HStack(spacing: LivePortraitHeaderBudget.interitemSpacing) {
            AvatarImage(urlString: viewModel.broadcasterFace, size: LivePortraitHeaderBudget.avatarSide)
                .frame(width: LivePortraitHeaderBudget.avatarSide, height: LivePortraitHeaderBudget.avatarSide)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let status = roomAvailability.announcedStatusText {
                        LiveStatusBadge(text: status, color: roomAvailability.statusColor)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.86))
                    }
                }
                if hostLayout.showsPopularity {
                    HStack(spacing: 3) {
                        Image(systemName: "eye").accessibilityHidden(true)
                        Text(FormatUtils.viewCount(info.online)).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.76))
                }
            }
            .frame(maxWidth: budget.containerFitsFixedControls ? budget.hostBlockWidth : nil, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard opensHostProfile else { return }
            coordinator.navigate(to: .userSpace(info.uid))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(hostAccessibilityLabel))
        .accessibilityAddTraits(opensHostProfile ? .isButton : [])
        .accessibilitySortPriority(3)
    }

    private func immersiveFollowButton(mid: Int, following: Bool) -> some View {
        Button {
            Task {
                await viewModel.toggleFollowBroadcaster(mid: mid)
            }
        } label: {
            (following ? Text("Following") : Text("+ Follow"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(following ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.white))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    following
                        ? AnyShapeStyle(Color.white.opacity(0.16))
                        : AnyShapeStyle(accentStore.semanticAccent),
                    in: Capsule()
                )
                .contentShape(Capsule())
                .appStateLabelFeedback(isOn: following, userActionInFlight: viewModel.followRequestInFlight)
        }
        .buttonStyle(.appControl)
        .disabled(viewModel.followRequestInFlight)
    }

    private var keyWindowSafeAreaInsets: UIEdgeInsets? {
        AppWindowMetrics.current?.safeAreaInsets
    }

    private var keyWindowFrameInScreen: CGRect? { AppWindowMetrics.frameInScreen }

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

    // MARK: - Room Info

    private func roomInfoBar(
        _ info: LiveRoomInfo,
        showsDivider: Bool = true,
        isWideStage: Bool = false
    ) -> some View {
        let name = viewModel.broadcasterName
        let opensHostProfile = info.uid > 0

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: isWideStage ? AppSpacing.m : 10) {
                Text(info.title)
                    .appFont(isWideStage ? .screenTitle : .sectionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(alignment: .center, spacing: AppSpacing.m) {
                    roomInfoHostLead(
                        info,
                        name: name,
                        opensHostProfile: opensHostProfile,
                        isWideStage: isWideStage
                    )
                    Spacer(minLength: AppSpacing.s)
                    if !canChooseQuality {
                        Text(roomAvailability.statusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let following = viewModel.isFollowingBroadcaster {
                        standardFollowButton(mid: info.uid, following: following)
                    }
                }
            }
            .padding(.horizontal, isWideStage ? 20 : AppSpacing.l)
            .padding(.vertical, isWideStage ? AppSpacing.l : AppSpacing.m)

            if showsDivider {
                Divider()
                    .opacity(0.22)
            }
        }
    }

    private func roomInfoHostLead(
        _ info: LiveRoomInfo,
        name: String,
        opensHostProfile: Bool,
        isWideStage: Bool
    ) -> some View {
        let hasArea = !info.parentAreaName.isEmpty || !info.areaName.isEmpty
        return HStack(spacing: isWideStage ? AppSpacing.m : 10) {
            AvatarImage(urlString: viewModel.broadcasterFace, size: isWideStage ? 40 : 36)
            VStack(alignment: .leading, spacing: isWideStage ? 4 : 2) {
                HStack(spacing: AppSpacing.s) {
                    Text(name)
                        .font((isWideStage ? Font.callout : Font.subheadline).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                    if !isRoomOffline {
                        LiveStatusBadge(
                            text: roomAvailability.announcedStatusText ?? String(localized: "LIVE"),
                            color: roomAvailability.statusColor
                        )
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(roomAvailability.statusColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(roomAvailability.statusColor)
                    }
                }
                HStack(spacing: 6) {
                    if hasArea {
                        LiveAreaBreadcrumb(
                            parentAreaName: info.parentAreaName,
                            areaName: info.areaName,
                            textStyle: AnyShapeStyle(HierarchicalShapeStyle.secondary),
                            separatorStyle: AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                        )
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .imageScale(.small)
                        Text(FormatUtils.viewCount(info.online))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard opensHostProfile else { return }
            coordinator.navigate(to: .userSpace(info.uid))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            opensHostProfile
                ? String(localized: "Open \(name)'s profile")
                : name
        ))
        .accessibilityAddTraits(opensHostProfile ? .isButton : [])
    }

    private func standardFollowButton(mid: Int, following: Bool) -> some View {
        Button {
            Task {
                await viewModel.toggleFollowBroadcaster(mid: mid)
            }
        } label: {
            Group {
                if following {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                        Text("Following")
                    }
                } else {
                    Text("+ Follow")
                }
            }
            .appFont(.controlLabel)
            .fontWeight(.semibold)
            .foregroundStyle(following ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.white))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                following
                    ? AnyShapeStyle(AppFill.inset)
                    : AnyShapeStyle(accentStore.semanticAccent),
                in: Capsule()
            )
            .frame(minHeight: LivePortraitOverlayMetrics.minimumInputHeight)
            .contentShape(Rectangle())
            .appStateLabelFeedback(isOn: following, userActionInFlight: viewModel.followRequestInFlight)
        }
        .buttonStyle(.appControl)
        .disabled(viewModel.followRequestInFlight)
    }

    // MARK: - Quality

    @ScaledMetric(relativeTo: .footnote) private var headerTextScaleProbe: CGFloat = 100

    private var canChooseQuality: Bool {
        viewModel.streamUnavailable == nil && !viewModel.availableQualities.isEmpty
    }

    private var isCurrentRoomPlaybackUnavailable: Bool {
        guard let lease = viewModel.playerOwnerLease,
              player.isCurrentOwner(lease),
              player.mode == .live else { return false }
        return (player.error ?? player.videoPresentationFailureMessage) != nil
    }

    private func immersiveQualityPicker(
        showsLabel: Bool,
        labelMaxWidth: CGFloat
    ) -> some View {
        let label = viewModel.availableQualities.first {
            $0.qn == viewModel.currentQuality
        }?.label ?? String(localized: "Auto")
        return Menu {
            ForEach(viewModel.availableQualities, id: \.qn) { quality in
                Button {
                    Task { await viewModel.switchQuality(roomID: roomID, quality: quality.qn) }
                } label: {
                    HStack {
                        Text(quality.label)
                        if quality.qn == viewModel.currentQuality {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            if showsLabel {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: labelMaxWidth > 0 ? labelMaxWidth : nil)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .liveImmersiveGlass(in: Capsule(), interactive: true)
                .frame(minHeight: LivePortraitOverlayMetrics.minimumInputHeight)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .liveImmersiveGlass(in: Circle(), interactive: true)
                    .frame(
                        width: LivePortraitOverlayMetrics.minimumInputHeight,
                        height: LivePortraitOverlayMetrics.minimumInputHeight
                    )
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel(Text("Video quality \(label)"))
        .accessibilitySortPriority(2)
    }
}

// MARK: - Isolated Live Chat Subviews

private struct LiveStandardChatView: View {
    let viewModel: LiveRoomViewModel
    let isWide: Bool

    @Environment(AppCoordinator.self) private var coordinator
    @ScaledMetric(relativeTo: .callout) private var chatSenderNameMaxWidth: CGFloat = 130
    @State private var autoScroll = LiveChatAutoScrollPolicy<UUID>()

    var body: some View {
        ScrollViewReader { proxy in
            let renderedMessages = LiveChatRenderPolicy.standardVisibleMessages(
                from: viewModel.chatMessages
            )
            let horizontalInset: CGFloat = isWide ? 18 : 14
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AppSpacing.s) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.biliAccent)
                    Text("Live Chat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                    Spacer()
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, isWide ? AppSpacing.l : AppSpacing.m)
                .padding(.bottom, isWide ? AppSpacing.m : AppSpacing.s)

                Divider()
                    .opacity(0.24)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: isWide ? 10 : 8) {
                        ForEach(renderedMessages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }

                        if renderedMessages.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: AppSpacing.s) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.title2)
                                        .foregroundStyle(.tertiary)
                                    Text("Chat messages will appear here")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 48)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, isWide ? AppSpacing.m : AppSpacing.s)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: renderedMessages.last?.id) { _, latestID in
                guard let targetID = autoScroll.nextTarget(for: latestID) else {
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            }
            .onDisappear {
                autoScroll.reset()
            }
        }
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if msg.isSystem {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(msg.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                if let name = msg.medalName, let level = msg.medalLevel {
                    LiveChatMedalChip(name: name, level: level, color: msg.medalColor)
                        .alignmentGuide(.firstTextBaseline) {
                            LiveChatMedalChip.firstTextBaseline($0)
                        }
                }
                Button {
                    guard msg.uid > 0 else { return }
                    coordinator.navigate(to: .userSpace(msg.uid))
                } label: {
                    Text(msg.uname)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.biliAccent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: chatSenderNameMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .disabled(msg.uid <= 0)
                .accessibilityLabel(Text(
                    msg.uid > 0
                        ? "Open \(msg.uname)'s profile"
                        : msg.uname
                ))
                Text(msg.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
        }
    }
}

private struct LiveImmersiveChatView: View {
    let viewModel: LiveRoomViewModel

    @Environment(AppCoordinator.self) private var coordinator
    @ScaledMetric(relativeTo: .callout) private var chatSenderNameMaxWidth: CGFloat = 130
    @State private var autoScroll = LiveChatAutoScrollPolicy<UUID>()

    var body: some View {
        ScrollViewReader { proxy in
            let renderedMessages = LiveChatRenderPolicy.immersiveVisibleMessages(
                from: viewModel.chatMessages
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(renderedMessages) { message in
                        immersiveChatBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 24)
                    Color.black
                }
            }
            .onChange(of: renderedMessages.last?.id) { _, latestID in
                guard let targetID = autoScroll.nextTarget(for: latestID) else {
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            }
            .onDisappear {
                autoScroll.reset()
            }
        }
    }

    private func immersiveChatBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if message.isSystem {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.80))
                Text(message.text)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.88))
                    .italic()
            } else {
                if let name = message.medalName, let level = message.medalLevel {
                    LiveChatMedalChip(name: name, level: level, color: message.medalColor)
                        .alignmentGuide(.firstTextBaseline) {
                            LiveChatMedalChip.firstTextBaseline($0)
                        }
                }
                Button {
                    guard message.uid > 0 else { return }
                    coordinator.navigate(to: .userSpace(message.uid))
                } label: {
                    Text(message.uname)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.biliAccent.mix(with: .white, by: 0.25))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: chatSenderNameMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .disabled(message.uid <= 0)
                .accessibilityLabel(Text(
                    message.uid > 0
                        ? "Open \(message.uname)'s profile"
                        : message.uname
                ))
                Text(message.text)
                    .font(.callout)
                    .lineLimit(2)
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.82), radius: 1, x: 0, y: 0.5)
        .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1.5)
    }
}

private struct LiveChatMedalChip: View {
    let name: String
    let level: Int
    let color: Int?

    var body: some View {
        HStack(spacing: 2) {
            Text(name)
                .appFont(.overlayBadge)
                .fontWeight(.medium)
                .lineLimit(1)
            Text("\(level)")
                .appFont(.overlayBadge)
                .fontWeight(.bold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(medalColor)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
        .fixedSize()
    }

    private var medalColor: Color {
        guard let color else { return .secondary }
        return Color(
            red: Double((color >> 16) & 0xFF) / 255.0,
            green: Double((color >> 8) & 0xFF) / 255.0,
            blue: Double(color & 0xFF) / 255.0
        )
    }

    nonisolated static func firstTextBaseline(_ dimensions: ViewDimensions) -> CGFloat {
        let capHeight = UIFont.preferredFont(forTextStyle: .callout).capHeight
        return dimensions.height / 2 + capHeight / 2
    }
}
