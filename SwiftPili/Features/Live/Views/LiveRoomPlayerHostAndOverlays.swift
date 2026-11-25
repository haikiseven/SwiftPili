import SwiftUI

struct LiveRoomInlinePlayerHost: View {
    let roomID: Int
    let routePosition: PlayerRoutePosition?
    let viewModel: LiveRoomViewModel
    let player: PlayerViewModel
    let isActiveLiveRoute: Bool
    let isRoomOffline: Bool
    let usesImmersivePortraitLayout: Bool
    let width: CGFloat
    let height: CGFloat
    let isImmersive: Bool
    let hostChrome: LiveHostChromeExtent
    var cornerRadius: CGFloat = 0
    let playerPageNavigation: PlayerPageNavigationActions

    @Environment(AppCoordinator.self) private var coordinator

    private var hostOwnsInlineSurface: Bool {
        PlayerDetailSurfacePolicy.hostOwnsInlineSurface(player: player, lease: viewModel.playerOwnerLease)
    }

    private var canChooseQuality: Bool {
        viewModel.streamUnavailable == nil && !viewModel.availableQualities.isEmpty
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

    var body: some View {
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
                            LiveRoomUnavailableOverlay(refusal: refusal)
                        } else if isRoomOffline {
                            LiveRoomOfflineOverlay()
                        } else if let loadError = viewModel.error, player.error == nil {
                            LiveRoomErrorOverlay(
                                message: loadError,
                                roomID: roomID,
                                viewModel: viewModel,
                                isActiveLiveRoute: isActiveLiveRoute
                            )
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
}

struct LiveRoomInlineNavigationOverlay: View {
    let player: PlayerViewModel
    let viewModel: LiveRoomViewModel
    let isActiveLiveRoute: Bool
    let isRoomOffline: Bool
    let width: CGFloat
    let height: CGFloat
    let actions: PlayerPageNavigationActions

    private var hasInlineExitChrome: Bool {
        guard isActiveLiveRoute, !isRoomOffline, viewModel.streamUnavailable == nil,
              viewModel.error == nil, player.error == nil,
              let lease = viewModel.playerOwnerLease else { return false }
        return player.isCurrentOwner(lease) && player.mode == .live
            && player.surfaceLease(matching: lease, role: .inline) != nil
    }

    var body: some View {
        PlayerDetailInlineNavigationOverlay(
            player: player,
            isActiveRoute: isActiveLiveRoute,
            hasInlineExitChrome: { hasInlineExitChrome },
            scrimWidth: width,
            scrimHeight: height,
            actions: actions
        )
    }
}

struct LiveRoomUnavailableOverlay: View {
    let refusal: LiveRoomStatusPolicy.Refusal

    var body: some View {
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
}

struct LiveRoomOfflineOverlay: View {
    var body: some View {
        ContentUnavailableView(
            "OFFLINE",
            systemImage: "antenna.radiowaves.left.and.right.slash"
        )
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.86))
        .contentShape(Rectangle())
    }
}

struct LiveRoomErrorOverlay: View {
    let message: String
    let roomID: Int
    let viewModel: LiveRoomViewModel
    let isActiveLiveRoute: Bool

    var body: some View {
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
}
