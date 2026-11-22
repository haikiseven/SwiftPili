import SwiftData
import SwiftUI

struct OfflinePlayerView: View {
    @AppMotion private var motion
    let pagingContext: OfflinePortraitPagingContext
    @Query private var downloadedItems: [DownloadedVideo]
    @State private var ownerLease: PlayerOwnerLease?
    @State private var routeActivation = RouteActivationState()
    @State private var presentationScreenID = UUID()
    @State private var routePosition: PlayerRoutePosition?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var pagingReducer: PortraitPagingReducer
    @State private var dragOffsetBox = PortraitDragOffsetBox()
    @State private var pagingEnabled = false
    @State private var pagingCoordinator = PlayerVerticalPagingCoordinator()
    @State private var assetValid = true
    @State private var inlineContainerSize: CGSize = .zero
    @State private var owner: String
    @State private var containerWidth: CGFloat = AppWindowMetrics.current?.bounds.width ?? UIScreen.main.bounds.width
    private var player: PlayerViewModel { .shared }
    private var isActiveOfflineRoute: Bool {
        coordinator.isActivePlayerRoute(.offline(pagingContext), position: routePosition)
    }
    private var isRouteActivated: Bool {
        routeActivation.admits(routeIsActive: isActiveOfflineRoute)
    }
    private var presentationContext: PlayerScreenPresentationContext? {
        guard isRouteActivated, assetValid, let asset = currentAsset else { return nil }
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
        return isRouteActivated && item != nil && assetValid && player.error == nil
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
        UIDevice.current.userInterfaceIdiom != .pad && playerShapeIsCurrent && player.isPortraitContent
    }
    private var pageWidth: CGFloat {
        containerWidth > 0 ? containerWidth : (AppWindowMetrics.current?.bounds.width ?? UIScreen.main.bounds.width)
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
        guard isRouteActivated, let ownerLease, player.isCurrentOwner(ownerLease) else { return false }
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
        guard isRouteActivated else { return }
        guard let asset = currentAsset,
              validatedItem(for: currentRouteItem.downloadID) != nil else {
            invalidateCurrentAsset()
            return
        }
        if player.isAlreadyLivePresentation(lease: ownerLease, source: .offline(asset)) { return }
        if routeActivation.defersActivation {
            player.endForeignOwnerForRouteActivation(incomingOwner: owner)
        }
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
            && isRouteActivated && pagingEnabled && !player.isFullscreen
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
                guard isRouteActivated, let settlement = pagingReducer.settlement(for: token),
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
        .animation(nil, value: player.isFullscreen)
        .clipped()
        .allowsHitTesting(false)
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
                    let layout = OfflinePlayerLayout(containerSize: geometry.size,
                        layoutContainerSize: inlineContainerSize, isPad: UIDevice.current.userInterfaceIdiom == .pad,
                        isPortraitContent: pageIsPortraitContent,
                        isCondensed: shapeIsCurrent && player.inlineCondensed
                    )
                    let playerCornerRadius: CGFloat = layout.isSplit ? DetailStageLayout.playerCornerRadius : 0
                    OfflinePlayerPage(layout: layout, viewportHeight: max(0, geometry.size.height)) {
                        ZStack(alignment: .topLeading) {
                            if isRouteActivated, !player.isFullscreen {
                                PlayerView(owner: owner, verticalPagingGestureSink: pagingSink,
                                    pageNavigationActions: playerPageNavigation,
                                    inlineViewportSize: layout.playerSize,
                                    inlineCornerRadius: playerCornerRadius,
                                    screenLease: ownerLease
                                )
                                .frame(width: layout.playerSize.width, height: layout.playerSize.height)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                                    guard !player.isFullscreen, hasInlineExitChrome else { return }
                                    player.refreshInlineVideoRect()
                                }
                            } else if !player.isFullscreen {
                                RouteActivationPlaceholderView(
                                    still: player.outgoingRouteStill(for: owner),
                                    coverURL: item.coverURL, height: layout.playerSize.height,
                                    cornerRadius: playerCornerRadius
                                )
                            }
                            if !player.isFullscreen, isActiveOfflineRoute {
                                let showsNavigation = !hasInlineExitChrome || player.showControls
                                if showsNavigation && (!isRouteActivated || !player.showControls) {
                                    PlayerControlsScrim()
                                        .frame(width: layout.playerSize.width, height: layout.playerSize.height)
                                        .clipShape(RoundedRectangle(
                                            cornerRadius: playerCornerRadius, style: .continuous
                                        ))
                                }
                                PlayerPageNavigationButtons(actions: playerPageNavigation)
                                    .padding(.horizontal, PlayerPageNavigationButtons.inlineHorizontalPadding)
                                    .padding(.top, PlayerPageNavigationButtons.topPadding)
                                    .opacity(showsNavigation ? 1 : 0)
                                    .allowsHitTesting(showsNavigation)
                                    .accessibilityHidden(!showsNavigation)
                            }
                        }
                    } metadata: {
                        if !player.isFullscreen {
                            OfflinePlayerMetadataView(title: item.title, ownerName: item.ownerName,
                                qualityLabel: item.qualityLabel, fileSizeBytes: item.fileSizeBytes,
                                isSplit: layout.isSplit
                            )
                            .animation(nil, value: player.isFullscreen)
                        }
                    }
                }
                .guardIPadTopSafeArea(when: !player.isFullscreen)
                .background {
                    if player.isFullscreen {
                        Color.black.ignoresSafeArea()
                    } else {
                        CinematicBackdrop(
                            coverURL: item.coverURL,
                            player: player,
                            ownerLease: ownerLease,
                            isRouteActive: isRouteActivated
                        )
                    }
                }
                .animation(nil, value: player.isFullscreen)
            } else {
                ContentUnavailableView(item == nil ? "Not Available" : "Download unavailable",
                    systemImage: "questionmark.folder",
                    description: Text("Downloaded files are missing or corrupt.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    PlayerPageNavigationButtons(actions: playerPageNavigation)
                        .padding(.horizontal, PlayerPageNavigationButtons.inlineHorizontalPadding)
                        .padding(.top, PlayerPageNavigationButtons.topPadding)
                }
                .guardIPadTopSafeArea(when: !player.isFullscreen)
            }
        }
        .appSurface(.cinematic)
        .background {
            GeometryReader { _ in
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        if inlineContainerSize != size { inlineContainerSize = size }
                    }
            }
            .ignoresSafeArea(.all, edges: .vertical)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            pagingReducer.updateContainerHeight($0.height)
            if dragOffsetBox.y != pagingReducer.offset {
                dragOffsetBox.y = pagingReducer.offset
            }
            if containerWidth != $0.width { containerWidth = $0.width }
            pagingReducer.noteCoverResolution(width: $0.width, height: $0.height)
        }
        .modifier(PortraitDragOffset(box: dragOffsetBox))
        .background { pagingNeighbourPreviews }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .keepsInteractivePopGesture()
        .routeAppearanceProbe { event in
            _ = routeActivation.handle(event, owner: owner)
        }
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(player.isFullscreen)
        .background(alignment: .topLeading) {
            if let presentationContext {
                PlayerFullscreenHost(context: presentationContext, navigation: coordinator)
            }
        }
        .onChange(of: isActiveOfflineRoute, initial: true) { _, active in
            let outcome = routeActivation.handle(.routeActivity(active), owner: owner)
            if outcome == .deactivated, routeActivation.defersActivation {
                player.pauseForRouteDeparture(lease: ownerLease)
            }
        }
        .task(id: isRouteActivated) {
            guard !Task.isCancelled else { return }
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
