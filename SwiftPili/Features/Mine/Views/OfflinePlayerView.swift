import SwiftData
import SwiftUI

struct OfflinePlayerView: View {
    @AppMotion private var motion
    let pagingContext: OfflinePortraitPagingContext
    @Query private var downloadedItems: [DownloadedVideo]
    @State private var ownerLease: PlayerOwnerLease?
    @State private var presentationScreenID = UUID()
    @State private var routePosition: PlayerRoutePosition?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var pagingReducer: PortraitPagingReducer
    @State private var dragOffsetBox = PortraitDragOffsetBox()
    @State private var pagingEnabled = false
    @State private var pagingCoordinator = PlayerVerticalPagingCoordinator()
    @State private var assetValid = true
    @State private var inlineContainerSize: CGSize = .zero
    @State private var owner: String
    @State private var containerWidth: CGFloat = WindowMetricsFallback.currentWidth
    private var player: PlayerViewModel { .shared }
    private var isActiveOfflineRoute: Bool {
        coordinator.isActivePlayerRoute(.offline(pagingContext), position: routePosition)
    }
    private var presentationContext: PlayerScreenPresentationContext? {
        guard isActiveOfflineRoute, assetValid, let asset = currentAsset else { return nil }
        return player.presentationContext(
            screenID: presentationScreenID, lease: ownerLease,
            route: .offline(pagingContext), position: routePosition, source: .offline(asset)
        )
    }
    private var playerPageNavigation: PlayerPageNavigationActions {
        .init(
            onBack: { coordinator.goBack() },
            onHome: { coordinator.goHome() },
            onDownload: nil,
            onReport: nil,
            pageOwnsInlineNavigation: true
        )
    }
    private var hasInlineExitChrome: Bool {
        guard let ownerLease, player.isCurrentOwner(ownerLease), player.mode == .offline else { return false }
        return isActiveOfflineRoute && item != nil && assetValid && player.error == nil
            && player.surfaceLease(matching: ownerLease, role: .inline) != nil
    }
    private var currentAsset: OfflinePlaybackAsset? {
        guard let item else { return nil }
        return OfflinePlaybackAsset(
            videoURL: item.videoFileURL, audioURL: item.audioFileURL,
            aid: item.aid, cid: item.cid, quality: item.qualityCode, codecs: item.codecs,
            durationSeconds: item.durationSeconds, title: item.title,
            artist: item.ownerName, cover: item.coverURL
        )
    }
    private var playerShapeIsCurrent: Bool {
        guard let asset = currentAsset else { return false }
        return player.isCurrentPresentationSource(lease: ownerLease, source: .offline(asset))
    }
    private var pageIsPortraitContent: Bool {
        DeviceCapability.usesCompactPortraitVideoFraming && playerShapeIsCurrent && player.isPortraitContent
    }
    private var pageWidth: CGFloat {
        containerWidth > 0 ? containerWidth : WindowMetricsFallback.currentWidth
    }
    init(pagingContext: OfflinePortraitPagingContext, routePosition: PlayerRoutePosition? = nil) {
        self.pagingContext = pagingContext
        _routePosition = State(initialValue: routePosition)
        _owner = State(initialValue: "offline-pager-\(UUID().uuidString)")
        _pagingReducer = State(initialValue: PortraitPagingReducer(
            itemCount: pagingContext.items.count,
            initialIndex: pagingContext.initialIndex
        ))
    }
    private var currentRouteItem: OfflinePortraitPagingItem {
        pagingContext.items[pagingReducer.currentIndex]
    }
    private var item: DownloadedVideo? {
        downloadedItems.first { $0.id == currentRouteItem.downloadID }
    }
    private func validatedItem(for downloadID: String) -> DownloadedVideo? {
        guard let candidate = downloadedItems.first(where: { $0.id == downloadID }),
              candidate.filesExist
        else { return nil }
        return candidate
    }
    private var pagingSink: PlayerVerticalPagingCoordinator? {
        guard PortraitPagingPolicy.allowsVerticalPaging(on: .offlinePlayback),
              pagingEnabled else { return nil }
        pagingCoordinator.install(.init(
            begin: beginPagingDrag,
            change: updatePagingDrag,
            end: endPagingDrag,
            cancel: cancelPagingDrag
        ))
        return pagingCoordinator
    }
    @discardableResult
    private func activateCurrent() -> Bool {
        guard isActiveOfflineRoute, let ownerLease, player.isCurrentOwner(ownerLease) else { return false }
        guard let item = validatedItem(for: currentRouteItem.downloadID)
        else {
            assetValid = false
            return false
        }
        assetValid = true
        let opened = player.playOffline(
            videoURL: item.videoFileURL,
            audioURL: item.audioFileURL,
            aid: item.aid,
            cid: item.cid,
            quality: item.qualityCode,
            codecs: item.codecs,
            durationSeconds: item.durationSeconds,
            title: item.title,
            artist: item.ownerName,
            cover: item.coverURL,
            resumeAt: TimeInterval(item.resumePositionSeconds),
            lease: ownerLease
        )
        if !opened { assetValid = false }
        return opened
    }
    private func releaseOwnerLease() {
        guard let ownerLease else { return }
        guard player.endOwnerPlayback(lease: ownerLease) == .ownershipEnded else { return }
        self.ownerLease = nil
    }

    private func startSessionIfNeeded() {
        guard isActiveOfflineRoute else { return }
        guard let asset = currentAsset,
              validatedItem(for: currentRouteItem.downloadID) != nil else {
            invalidateCurrentAsset()
            return
        }
        if player.isAlreadyLivePresentation(lease: ownerLease, source: .offline(asset)) { return }
        player.endForeignOwnerForRouteActivation(incomingOwner: owner)
        if let ownerLease, !player.isCurrentOwner(ownerLease) { self.ownerLease = nil }
        if ownerLease == nil { ownerLease = player.claimOwnerLease(owner: owner) }
        if !activateCurrent() { releaseOwnerLease() }
    }

    private func invalidateCurrentAsset() {
        if let ownerLease { player.retirePresentation(screenID: presentationScreenID, lease: ownerLease) }
        releaseOwnerLease()
        assetValid = false
    }

    private var pagingNeighboursReachable: Bool {
        PortraitPagingPolicy.allowsVerticalPaging(on: .offlinePlayback)
            && isActiveOfflineRoute && pagingEnabled && !player.isFullscreenPresentationActive
    }

    private var hostOwnsInlineSurface: Bool {
        PlayerDetailSurfacePolicy.hostOwnsInlineSurface(player: player, lease: ownerLease)
    }

    private func beginPagingDrag() -> Bool {
        guard pagingNeighboursReachable else { return false }
        let began = pagingReducer.beginDrag()
        if began { dragOffsetBox.y = pagingReducer.offset }
        return began
    }

    private func updatePagingDrag(_ translation: CGFloat) {
        dragOffsetBox.y = pagingReducer.dragOffset(for: translation)
    }

    private func endPagingDrag(_ translation: CGFloat, _ predicted: CGFloat) {
        var next = pagingReducer
        guard let settlement = next.endDrag(
            translation: translation,
            predictedEndTranslation: predicted
        ) else { return }
        motion.settle(normal: .snappy(duration: 0.24)) {
            pagingReducer = next
            dragOffsetBox.y = next.offset
        } completion: {
            completePagingSettlement(settlement.token)
        }
    }

    private func cancelPagingDrag() {
        var next = pagingReducer
        guard let settlement = next.cancelDrag() else { return }
        motion.settle(normal: .snappy(duration: 0.2)) {
            pagingReducer = next
            dragOffsetBox.y = next.offset
        } completion: {
            completePagingSettlement(settlement.token)
        }
    }

    private func completePagingSettlement(_ token: PortraitPagingToken) {
        PortraitPagingSettlementDispatcher.complete(
            token: token,
            reducer: &pagingReducer,
            itemIDAtIndex: { index in
                pagingContext.items.indices.contains(index)
                    ? pagingContext.items[index].downloadID
                    : nil
            },
            handoff: {
                guard isActiveOfflineRoute, let settlement = pagingReducer.settlement(for: token),
                      case .switchPage(let targetIndex) = settlement.kind,
                      pagingContext.items.indices.contains(targetIndex),
                      let ownerLease,
                      validatedItem(for: pagingContext.items[targetIndex].downloadID) != nil
                else { return false }
                return player.beginPortraitPagingHandoff(lease: ownerLease)
            },
            activate: { _, _ in
                _ = activateCurrent()
            }
        )
    }

    private var pagingNeighbourPreviews: some View {
        ZStack {
            if pagingNeighboursReachable {
                if let previous = pagingReducer.previousIndex {
                    neighbourPreview(index: previous)
                        .modifier(PortraitDragOffset(
                            box: dragOffsetBox, base: -pagingReducer.containerHeight
                        ))
                }
                if let next = pagingReducer.nextIndex {
                    neighbourPreview(index: next)
                        .modifier(PortraitDragOffset(
                            box: dragOffsetBox, base: pagingReducer.containerHeight
                        ))
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func originalVideoTarget(for item: DownloadedVideo) -> VideoRouteTarget? {
        VideoRouteTarget.make(
            bvid: item.bvid,
            aid: item.aid,
            title: item.title,
            coverURL: item.coverURL,
            ownerName: item.ownerName,
            durationSeconds: item.durationSeconds
        )
    }

    @ViewBuilder
    private func neighbourPreview(index: Int) -> some View {
        if pagingContext.items.indices.contains(index) {
            let routeItem = pagingContext.items[index]
            PortraitPagerCoverBackdrop(
                coverSource: routeItem.preview.coverSource,
                title: routeItem.preview.title,
                ownerName: routeItem.preview.ownerName,
                pageSize: CGSize(
                    width: pageWidth,
                    height: pagingReducer.containerHeight
                ),
                resolutionBudget: pagingReducer.coverResolutionBudget
            )
        } else {
            Color.clear
        }
    }
}
extension OfflinePlayerView {
    var body: some View {
        Group {
            if let item, assetValid {
                GeometryReader { geometry in
                    let shapeIsCurrent = playerShapeIsCurrent
                    let layout = OfflinePlayerLayout(
                        containerSize: geometry.size,
                        layoutContainerSize: inlineContainerSize,
                        isRegularWidth: horizontalSizeClass == .regular,
                        supportsPadSplit: DeviceCapability.supportsPadDetailSplit,
                        isPortraitContent: pageIsPortraitContent,
                        isCondensed: shapeIsCurrent && player.inlineCondensed
                    )
                    let playerCornerRadius: CGFloat = layout.isSplit ? DetailStageLayout.playerCornerRadius : 0
                    OfflinePlayerPage(layout: layout, viewportHeight: max(0, geometry.size.height)) {
                        ZStack(alignment: .topLeading) {
                            if isActiveOfflineRoute {
                                if hostOwnsInlineSurface {
                                    RoundedRectangle(cornerRadius: playerCornerRadius, style: .continuous)
                                        .fill(Color.black)
                                        .frame(width: layout.playerSize.width, height: layout.playerSize.height)
                                } else {
                                    PlayerView(
                                        owner: owner,
                                        surfaceRole: .inline,
                                        verticalPagingGestureSink: pagingSink,
                                        pageNavigationActions: playerPageNavigation,
                                        inlineViewportSize: layout.playerSize,
                                        inlineCornerRadius: playerCornerRadius,
                                        screenLease: ownerLease,
                                        placeholderCoverURL: item.coverURL
                                    )
                                    .frame(width: layout.playerSize.width, height: layout.playerSize.height)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                                        guard !player.isFullscreenPresentationActive, hasInlineExitChrome else { return }
                                        player.refreshInlineVideoRect()
                                    }
                                }
                            } else {
                                RouteActivationPlaceholderView(
                                    still: player.outgoingRouteStill(for: owner),
                                    coverURL: item.coverURL,
                                    height: layout.playerSize.height,
                                    cornerRadius: playerCornerRadius
                                )
                                .frame(width: layout.playerSize.width, height: layout.playerSize.height)
                            }
                            PlayerDetailInlineNavigationOverlay(
                                player: player,
                                isActiveRoute: isActiveOfflineRoute,
                                hasInlineExitChrome: { hasInlineExitChrome },
                                scrimWidth: layout.playerSize.width,
                                scrimHeight: layout.playerSize.height,
                                cornerRadius: playerCornerRadius,
                                actions: playerPageNavigation
                            )
                        }
                        .frame(width: layout.playerSize.width, height: layout.playerSize.height, alignment: .topLeading)
                        .background {
                            PlayerInlineSlotProbe(cornerRadius: playerCornerRadius)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    } metadata: {
                        OfflinePlayerMetadataView(
                            title: item.title,
                            ownerName: item.ownerName,
                            qualityLabel: item.qualityLabel,
                            fileSizeBytes: item.fileSizeBytes,
                            isSplit: layout.isSplit,
                            onOpenOriginal: originalVideoTarget(for: item).map { target in
                                { coordinator.navigate(to: .videoDetail(target)) }
                            }
                        )
                    }
                }
                .guardIPadTopSafeArea(when: true)
                .background {
                    CinematicBackdrop(
                        coverURL: item.coverURL,
                        player: player,
                        ownerLease: ownerLease,
                        isRouteActive: isActiveOfflineRoute
                    )
                }
            } else {
                ZStack(alignment: .topLeading) {
                    ContentUnavailableView {
                        Label(
                            item == nil
                                ? LocalizedStringKey("Not Available")
                                : LocalizedStringKey("Download unavailable"),
                            systemImage: "questionmark.folder"
                        )
                    } description: {
                        Text("Downloaded files are missing or corrupt.")
                    } actions: {
                        Button("Back") {
                            coordinator.goBack()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.biliAccent)
                    }
                    .padding(.top, PlayerPageNavigationButtons.topPadding + PlayerPageNavigationButtons.buttonSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    PlayerPageNavigationButtons(actions: playerPageNavigation)
                        .padding(.horizontal, PlayerPageNavigationButtons.inlineHorizontalPadding)
                        .padding(.top, PlayerPageNavigationButtons.topPadding)
                }
                .guardIPadTopSafeArea(when: true)
                .background {
                    PlayerAmbientPolicy.groundColor
                        .ignoresSafeArea()
                }
            }
        }
        .playerDetailInlineContainerSize(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive
        ) { size in
            if inlineContainerSize != size { inlineContainerSize = size }
        }
        .playerDetailDeferredSize(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive
        ) { size in
            pagingReducer.updateContainerHeight(size.height)
            if dragOffsetBox.y != pagingReducer.offset {
                dragOffsetBox.y = pagingReducer.offset
            }
            if containerWidth != size.width { containerWidth = size.width }
            pagingReducer.noteCoverResolution(width: size.width, height: size.height)
        }
        .modifier(PortraitDragOffset(box: dragOffsetBox))
        .background { pagingNeighbourPreviews }
        .playerDetailChrome(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isStatusBarHidden: player.isFullscreen,
            guardsIPadTopSafeArea: nil,
            presentationContext: presentationContext,
            coordinator: coordinator
        ) {
            PlayerAmbientPolicy.groundColor
                .ignoresSafeArea()
        }
        .onChange(of: isActiveOfflineRoute, initial: true) { oldActive, active in
            if !active, oldActive {
                player.pauseForRouteDeparture(lease: ownerLease)
            }
        }
        .task(id: isActiveOfflineRoute) {
            guard !Task.isCancelled, isActiveOfflineRoute else { return }
            startSessionIfNeeded()
        }
        .onChange(of: currentAsset) { old, new in
            guard old != new else { return }
            if new == nil || validatedItem(for: currentRouteItem.downloadID) == nil { invalidateCurrentAsset() }
        }
        .onChange(of: pageIsPortraitContent, initial: true) { _, portrait in
            guard portrait else { return }
            pagingEnabled = PortraitPagingPolicy.allowsVerticalPaging(on: .offlinePlayback)
        }
        .onDisappear {
            guard scenePhase == .active else { return }
            releaseOwnerLease()
        }
    }
}
