import SwiftUI
import UIKit

struct LiveRoomPortraitImmersionView: View {
    let roomID: Int
    let viewModel: LiveRoomViewModel
    let player: PlayerViewModel
    let danmakuDraft: LiveDanmakuDraftModel
    var isDanmakuFocused: FocusState<Bool>.Binding
    let roomAvailability: LiveRoomAvailability
    let isRoomOffline: Bool
    let isCurrentRoomPlaybackUnavailable: Bool
    let layout: LivePortraitSafeAreaLayout
    let containerSize: CGSize
    let metrics: LivePortraitOverlayMetrics
    let boxHeight: CGFloat
    let keyWindowSafeAreaInsets: UIEdgeInsets?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isImmersiveChromeActive: Bool {
        player.showControls || isDanmakuFocused.wrappedValue || !player.isPlaying
            || viewModel.streamUnavailable != nil || viewModel.error != nil || isRoomOffline
    }

    private var immersiveChromeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    var body: some View {
        let hasInput = AuthManager.shared.isLoggedIn
        ZStack(alignment: .bottom) {
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
                    LiveRoomImmersiveHeaderBarView(
                        roomID: roomID,
                        info: info,
                        viewModel: viewModel,
                        roomAvailability: roomAvailability,
                        containerWidth: containerSize.width,
                        keyWindowSafeAreaInsets: keyWindowSafeAreaInsets
                    )
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
                        LiveRoomImmersiveTransportRow(
                            roomID: roomID,
                            player: player,
                            roomAvailability: roomAvailability
                        )
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
                        LiveDanmakuInputBar(
                            style: .immersive,
                            draft: danmakuDraft,
                            isFocused: isDanmakuFocused,
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
}

private struct LiveRoomImmersiveTransportRow: View {
    let roomID: Int
    let player: PlayerViewModel
    let roomAvailability: LiveRoomAvailability

    @AppStorage("show_network_speed") private var showNetworkSpeed = false

    private var isPlayerOwner: Bool {
        player.ownerKey == PlayerViewModel.liveOwner(roomID)
    }

    var body: some View {
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
}

private struct LiveRoomImmersiveHeaderBarView: View {
    let roomID: Int
    let info: LiveRoomInfo
    let viewModel: LiveRoomViewModel
    let roomAvailability: LiveRoomAvailability
    let containerWidth: CGFloat
    let keyWindowSafeAreaInsets: UIEdgeInsets?

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var headerTextScaleProbe: CGFloat = 100

    private var canChooseQuality: Bool {
        viewModel.streamUnavailable == nil && !viewModel.availableQualities.isEmpty
    }

    var body: some View {
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

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: LivePortraitHeaderBudget.interitemSpacing) {
                immersiveBackButton
                immersiveBroadcasterPill(hostLayout: hostLayout, budget: budget)
                    .layoutPriority(0)
                Spacer(minLength: 0)
                if canChooseQuality {
                    LiveRoomImmersiveQualityMenu(
                        roomID: roomID,
                        viewModel: viewModel,
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
        hostLayout: LivePortraitHostLayout,
        budget: LivePortraitHeaderBudget
    ) -> some View {
        HStack(spacing: 0) {
            immersiveHostIdentityBlock(hostLayout: hostLayout, budget: budget)
            if let following = viewModel.isFollowingBroadcaster {
                LiveRoomFollowButton(
                    style: .immersive,
                    mid: info.uid,
                    following: following,
                    viewModel: viewModel
                )
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
}

private struct LiveRoomImmersiveQualityMenu: View {
    let roomID: Int
    let viewModel: LiveRoomViewModel
    let showsLabel: Bool
    let labelMaxWidth: CGFloat

    var body: some View {
        let label = viewModel.availableQualities.first {
            $0.qn == viewModel.currentQuality
        }?.label ?? String(localized: "Auto")
        Menu {
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
