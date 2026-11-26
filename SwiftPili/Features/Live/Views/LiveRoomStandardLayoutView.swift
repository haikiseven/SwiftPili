import SwiftUI

struct LiveRoomWideStageMetrics {
    let panelWidth: CGFloat
    let columnWidth: CGFloat
    let playerSize: CGSize
}

enum LiveRoomWideStageLayout {
    @MainActor
    static func metrics(
        in size: CGSize,
        hasRoomInfo: Bool,
        standardHeaderHeight: CGFloat,
        streamIsPortraitContent: Bool,
        isRoomOffline: Bool
    ) -> LiveRoomWideStageMetrics {
        let margin = DetailStageLayout.outerMargin
        let gap = DetailStageLayout.columnGap
        let headerGap = AppSpacing.l
        let panelWidth = DetailSplitPolicy.companionColumnWidth(containerWidth: size.width)
        let columnWidth = max(0, size.width - panelWidth - margin * 2 - gap)
        let infoReserve = hasRoomInfo ? standardHeaderHeight + headerGap : 0
        let maxHeight = max(0, size.height - margin * 2 - infoReserve)
        let playerSize: CGSize
        if streamIsPortraitContent, !isRoomOffline {
            let width = min(columnWidth, maxHeight * 9.0 / 16.0)
            playerSize = CGSize(width: width, height: width * 16.0 / 9.0)
        } else {
            let width = min(columnWidth, maxHeight * 16.0 / 9.0)
            playerSize = CGSize(width: width, height: width * 9.0 / 16.0)
        }
        return LiveRoomWideStageMetrics(panelWidth: panelWidth, columnWidth: columnWidth, playerSize: playerSize)
    }
}

struct LiveRoomWideStageView: View {
    let roomID: Int
    let routePosition: PlayerRoutePosition?
    let viewModel: LiveRoomViewModel
    let player: PlayerViewModel
    let isActiveLiveRoute: Bool
    let roomAvailability: LiveRoomAvailability
    let isRoomOffline: Bool
    let streamIsPortraitContent: Bool
    let standardHeaderHeight: CGFloat
    let portraitInputBarHeight: CGFloat
    let playerPageNavigation: PlayerPageNavigationActions

    var body: some View {
        GeometryReader { proxy in
            let metrics = LiveRoomWideStageLayout.metrics(
                in: proxy.size,
                hasRoomInfo: viewModel.roomInfo != nil,
                standardHeaderHeight: standardHeaderHeight,
                streamIsPortraitContent: streamIsPortraitContent,
                isRoomOffline: isRoomOffline
            )
            HStack(alignment: .top, spacing: DetailStageLayout.columnGap) {
                wideStageLeftColumn(metrics: metrics)
                wideStageChatPanel(metrics: metrics)
            }
            .padding(.horizontal, DetailStageLayout.outerMargin)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wideStageLeftColumn(metrics: LiveRoomWideStageMetrics) -> some View {
        let playerShape = RoundedRectangle(cornerRadius: DetailStageLayout.playerCornerRadius, style: .continuous)
        let barShape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        return VStack(spacing: AppSpacing.l) {
            LiveRoomInlinePlayerHost(
                roomID: roomID,
                routePosition: routePosition,
                viewModel: viewModel,
                player: player,
                isActiveLiveRoute: isActiveLiveRoute,
                isRoomOffline: isRoomOffline,
                usesImmersivePortraitLayout: false,
                width: metrics.playerSize.width,
                height: metrics.playerSize.height,
                isImmersive: false,
                hostChrome: LiveHostChromeExtent(top: 0, bottom: 0, bottomInterceptsTouches: false),
                cornerRadius: DetailStageLayout.playerCornerRadius,
                playerPageNavigation: playerPageNavigation
            )
            .frame(width: metrics.playerSize.width, height: metrics.playerSize.height)
            .clipShape(playerShape)
            .overlay(alignment: .topLeading) {
                if !player.isFullscreenPresentationActive {
                    LiveRoomInlineNavigationOverlay(
                        player: player,
                        viewModel: viewModel,
                        isActiveLiveRoute: isActiveLiveRoute,
                        isRoomOffline: isRoomOffline,
                        width: metrics.playerSize.width,
                        height: metrics.playerSize.height,
                        actions: playerPageNavigation
                    )
                    .clipShape(playerShape)
                }
            }
            .frame(maxWidth: .infinity)

            if let info = viewModel.roomInfo {
                LiveRoomInfoBarView(
                    info: info,
                    viewModel: viewModel,
                    roomAvailability: roomAvailability,
                    isRoomOffline: isRoomOffline,
                    showsDivider: false,
                    isWideStage: true
                )
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

    private func wideStageChatPanel(metrics: LiveRoomWideStageMetrics) -> some View {
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
}

struct LiveRoomWideDanmakuInputView: View {
    let roomID: Int
    let viewModel: LiveRoomViewModel
    let danmakuDraft: LiveDanmakuDraftModel
    var isFocused: FocusState<Bool>.Binding
    let containerWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isFloating = isFocused.wrappedValue
        let panelWidth = DetailSplitPolicy.companionColumnWidth(containerWidth: containerWidth)
        LiveDanmakuInputBar(
            style: isFloating ? .floating : .standard,
            draft: danmakuDraft,
            isFocused: isFocused,
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
}

struct LiveRoomStandardCompanionView: View {
    let roomID: Int
    let viewModel: LiveRoomViewModel
    let danmakuDraft: LiveDanmakuDraftModel
    var isDanmakuFocused: FocusState<Bool>.Binding
    let roomAvailability: LiveRoomAvailability
    let isRoomOffline: Bool
    let chatHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if let info = viewModel.roomInfo {
                LiveRoomInfoBarView(
                    info: info,
                    viewModel: viewModel,
                    roomAvailability: roomAvailability,
                    isRoomOffline: isRoomOffline
                )
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
                        isFocused: isDanmakuFocused,
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
}

struct LiveRoomInfoBarView: View {
    let info: LiveRoomInfo
    let viewModel: LiveRoomViewModel
    let roomAvailability: LiveRoomAvailability
    let isRoomOffline: Bool
    var showsDivider: Bool = true
    var isWideStage: Bool = false

    @Environment(AppCoordinator.self) private var coordinator

    private var canChooseQuality: Bool {
        viewModel.streamUnavailable == nil && !viewModel.availableQualities.isEmpty
    }

    var body: some View {
        let name = viewModel.broadcasterName
        let opensHostProfile = info.uid > 0

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: isWideStage ? AppSpacing.m : 10) {
                Text(info.title)
                    .appFont(isWideStage ? .screenTitle : .sectionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(alignment: .center, spacing: AppSpacing.m) {
                    roomInfoHostLead(name: name, opensHostProfile: opensHostProfile)
                    Spacer(minLength: AppSpacing.s)
                    if !canChooseQuality {
                        Text(roomAvailability.statusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let following = viewModel.isFollowingBroadcaster {
                        LiveRoomFollowButton(
                            style: .standard,
                            mid: info.uid,
                            following: following,
                            viewModel: viewModel
                        )
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
        name: String,
        opensHostProfile: Bool
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
                        Divider()
                            .frame(height: 10)
                            .accessibilityHidden(true)
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
}

struct LiveRoomFollowButton: View {
    enum Style {
        case standard
        case immersive
    }

    let style: Style
    let mid: Int
    let following: Bool
    let viewModel: LiveRoomViewModel

    @Environment(\.accentStore) private var accentStore

    var body: some View {
        Button {
            Task {
                await viewModel.toggleFollowBroadcaster(mid: mid)
            }
        } label: {
            switch style {
            case .immersive:
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
            case .standard:
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
        }
        .buttonStyle(.appControl)
        .disabled(viewModel.followRequestInFlight)
    }
}
