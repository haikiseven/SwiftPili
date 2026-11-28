import SwiftData
import SwiftUI
import UIKit

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
    @State private var pagingCoordinator = PlayerVerticalPagingCoordinator()
    @State private var assetValid = true
    @State private var inlineContainerSize: CGSize = .zero
    @State private var immersiveViewportSize: CGSize = WindowMetricsFallback.currentBounds.size
    @State private var owner: String
    @State private var containerWidth: CGFloat = WindowMetricsFallback.currentWidth
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @State private var offlineHasDanmaku = false
    @State private var isPortraitImmersiveStageActive: Bool
    @State private var userCollapsedImmersiveDownloadID: String?
    @State private var frozenDepartureImmersiveActive: Bool?
    private var player: PlayerViewModel { .shared }
    private var isActiveOfflineRoute: Bool {
        coordinator.isActivePlayerRoute(.offline(pagingContext), position: routePosition)
    }
    private var showsInRouteOfflineImmersive: Bool {
        !isSplitLayout && isActiveOfflineRoute && assetValid && item != nil && isPortraitImmersiveStageActive
    }
    private var rendersFullBleedOfflineImmersive: Bool {
        guard !isSplitLayout, assetValid, item != nil else { return false }
        if isActiveOfflineRoute {
            return isPortraitImmersiveStageActive
        }
        return frozenDepartureImmersiveActive ?? isPortraitImmersiveStageActive
    }
    private var offlineImmersiveStageSize: CGSize {
        if immersiveViewportSize.width > 1, immersiveViewportSize.height > 1 {
            return immersiveViewportSize
        }
        return WindowMetricsFallback.currentBounds.size
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
        guard isActiveOfflineRoute, item != nil, assetValid else { return false }
        return PlayerDetailSurfacePolicy.hasUsableInlineExitChrome(
            player: player,
            lease: ownerLease,
            expectedMode: .offline
        )
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
    private var resolvedOfflineAspectRatio: CGFloat? {
        let fallback = item?.aspectRatioHint ?? currentRouteItem.preview.aspectRatioHint
        if playerShapeIsCurrent {
            return DetailPlayerGeometry.normalizedAspect(player.videoAspectRatio) ?? fallback
        }
        return fallback
    }
    private var resolvedOfflineAspectRatioKey: Int? {
        resolvedOfflineAspectRatio.map { Int(($0 * 100).rounded()) }
    }
    private var isSplitLayout: Bool {
        let referenceSize = (inlineContainerSize.width > 0 && inlineContainerSize.height > 0)
            ? inlineContainerSize
            : WindowMetricsFallback.currentSize
        return DetailSplitPolicy.usesSplit(
            isRegularWidth: horizontalSizeClass == .regular,
            supportsPadSplit: DeviceCapability.supportsPadDetailSplit,
            containerSize: referenceSize
        )
    }
    private var pageIsPortraitContent: Bool {
        guard DeviceCapability.usesCompactPortraitVideoFraming else { return false }
        return DetailPlayerGeometry.isPortraitAspect(
            resolvedOfflineAspectRatio,
            fallback: (playerShapeIsCurrent && player.isPortraitContent)
                || (currentRouteItem.preview.isPortraitHint ?? false)
        )
    }
    private struct OfflinePortraitContextFingerprint: Equatable {
        let lease: PlayerOwnerLease?
        let isActiveRoute: Bool
        let isInRouteImmersive: Bool
        let downloadID: String
        let title: String?
        let ownerName: String?
    }
    private var offlinePortraitContextFingerprint: OfflinePortraitContextFingerprint {
        OfflinePortraitContextFingerprint(
            lease: ownerLease,
            isActiveRoute: isActiveOfflineRoute,
            isInRouteImmersive: showsInRouteOfflineImmersive,
            downloadID: currentRouteItem.downloadID,
            title: item?.title,
            ownerName: item?.ownerName
        )
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
        let initialItem = pagingContext.items[
            pagingContext.items.indices.contains(pagingContext.initialIndex) ? pagingContext.initialIndex : 0
        ]
        let initialImmersive = PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: PlayerPlaybackPreferences.portraitVideoMode,
            isWideLayout: false,
            usesCompactFraming: DeviceCapability.usesCompactPortraitVideoFraming,
            aspectRatio: initialItem.preview.aspectRatioHint,
            isPortraitFallback: initialItem.preview.isPortraitHint ?? false
        )
        _isPortraitImmersiveStageActive = State(initialValue: initialImmersive)
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
        guard pagingNeighboursReachable else { return nil }
        pagingCoordinator.install(.init(
            canPagePrevious: { pagingReducer.previousIndex != nil },
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
            aspectRatioHint: item.aspectRatioHint ?? currentRouteItem.preview.aspectRatioHint,
            lease: ownerLease
        )
        if !opened {
            assetValid = false
        } else {
            syncOfflineInlinePortraitImmersiveBinding()
            syncOfflinePortraitFullscreenContext()
            applyModeDPortraitFullscreenIfNeeded()
        }
        return opened
    }
    private func releaseOwnerLease() {
        clearOfflineInlinePortraitImmersiveBindingIfOwned()
        clearOfflinePortraitFullscreenContextIfOwned()
        guard let ownerLease else { return }
        guard player.endOwnerPlayback(lease: ownerLease) == .ownershipEnded else { return }
        player.unregisterOfflineDanmakuDirectory(for: currentAsset)
        self.ownerLease = nil
    }

    private func syncOfflineInlinePortraitImmersiveBinding() {
        guard isActiveOfflineRoute,
              let lease = ownerLease,
              player.isCurrentOwner(lease) else { return }
        let active = showsInRouteOfflineImmersive
        if player.isInlinePortraitImmersiveActive != active {
            player.isInlinePortraitImmersiveActive = active
        }
        player.onRequestInlinePortraitImmersive = { target in
            handleOfflineInlinePortraitImmersiveRequest(target)
        }
    }

    private func clearOfflineInlinePortraitImmersiveBindingIfOwned() {
        guard let lease = ownerLease,
              player.isCurrentOwner(lease) else { return }
        player.isInlinePortraitImmersiveActive = false
        player.onRequestInlinePortraitImmersive = nil
    }

    @discardableResult
    private func handleOfflineInlinePortraitImmersiveRequest(_ target: Bool) -> Bool {
        guard isActiveOfflineRoute,
              !isSplitLayout,
              DeviceCapability.usesCompactPortraitVideoFraming,
              assetValid,
              item != nil else { return false }
        if target {
            guard !isPortraitImmersiveStageActive else { return true }
            userCollapsedImmersiveDownloadID = nil
            dragOffsetBox.y = 0
            player.portraitPureViewEnabled = false
            withAnimation(motion.animation(normal: .spring(duration: 0.32, bounce: 0.04))) {
                isPortraitImmersiveStageActive = true
                player.isInlinePortraitImmersiveActive = true
            }
            syncOfflinePortraitFullscreenContext()
            return true
        } else {
            guard isPortraitImmersiveStageActive else { return false }
            collapseFromOfflinePortraitImmersiveStage()
            return true
        }
    }

    private func collapseFromOfflinePortraitImmersiveStage() {
        userCollapsedImmersiveDownloadID = currentRouteItem.downloadID
        player.portraitPureViewEnabled = false
        dragOffsetBox.y = 0
        let ownsPlayer: Bool = if let lease = ownerLease {
            player.isCurrentOwner(lease)
        } else {
            false
        }
        withAnimation(motion.animation(normal: .spring(duration: 0.32, bounce: 0.04))) {
            isPortraitImmersiveStageActive = false
            if ownsPlayer {
                player.isInlinePortraitImmersiveActive = false
            }
        }
        syncOfflinePortraitFullscreenContext()
    }

    private func syncOfflinePortraitFullscreenContext() {
        guard isActiveOfflineRoute,
              let lease = ownerLease,
              player.isCurrentOwner(lease),
              let item else { return }
        let context: PlayerPortraitFullscreenContext
        if let existing = player.portraitFullscreenContext, existing.ownerLease == lease {
            context = existing
        } else {
            context = PlayerPortraitFullscreenContext(ownerLease: lease)
            player.portraitFullscreenContext = context
        }
        context.title = item.title
        context.upName = item.ownerName
        context.isInRouteImmersiveStage = showsInRouteOfflineImmersive
        context.summaryBadgeText = nil
        context.descriptionPreview = nil
        let sizeText = item.fileSizeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file)
            : ""
        let summaryParts = [item.qualityLabel, sizeText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        context.statsSummary = summaryParts.isEmpty ? nil : summaryParts.joined(separator: "  ")
        context.hasExpandableDetails = false
        context.makeDetailsSheetView = nil
        context.onBackToFeed = {
            if player.isFullscreen { player.exitFullscreen() }
            coordinator.goBack()
        }
        context.onCollapseToDetail = {
            if isPortraitImmersiveStageActive {
                collapseFromOfflinePortraitImmersiveStage()
            } else {
                player.requestFullscreenTransition(target: false, source: .button)
            }
        }
    }

    private func clearOfflinePortraitFullscreenContextIfOwned() {
        guard let lease = ownerLease,
              player.portraitFullscreenContext?.ownerLease == lease else { return }
        player.portraitFullscreenContext = nil
    }

    private func applyModeDPortraitFullscreenIfNeeded() {
        guard isActiveOfflineRoute,
              assetValid,
              item != nil,
              !player.isFullscreen,
              !player.isFullscreenPresentationActive else { return }

        let shouldPromote = PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: PlayerPlaybackPreferences.portraitVideoMode,
            isWideLayout: isSplitLayout,
            usesCompactFraming: DeviceCapability.usesCompactPortraitVideoFraming,
            isAlreadyImmersive: isPortraitImmersiveStageActive,
            userCollapsedCurrentVideo: userCollapsedImmersiveDownloadID == currentRouteItem.downloadID,
            userHasScrolledInline: false,
            aspectRatio: resolvedOfflineAspectRatio,
            isPortraitFallback: pageIsPortraitContent
        )
        guard shouldPromote else { return }

        if let aspect = resolvedOfflineAspectRatio {
            player.applyAspectRatioHint(aspect)
        } else if !player.portraitPropagation.hasValidVideoGeometry {
            player.isPortraitContent = true
        }
        dragOffsetBox.y = 0
        withAnimation(motion.animation(normal: .spring(duration: 0.3))) {
            isPortraitImmersiveStageActive = true
            if let lease = ownerLease, player.isCurrentOwner(lease) {
                player.isInlinePortraitImmersiveActive = true
            }
        }
        syncOfflineInlinePortraitImmersiveBinding()
        syncOfflinePortraitFullscreenContext()
    }

    private var playerMountsNativeDanmaku: Bool {
        guard let ownerLease else { return false }
        return PlayerDanmakuMountPolicy.shouldMount(
            mode: player.mode,
            source: player.currentURL,
            isOwner: player.isCurrentOwner(ownerLease),
            hasSurfaceLease: player.surfaceLease(matching: ownerLease, role: .inline) != nil,
            enabled: danmakuEnabled,
            hasOfflineDanmaku: player.hasRegisteredOfflineDanmaku
        )
    }

    private func startSessionIfNeeded() {
        guard isActiveOfflineRoute else { return }
        guard let asset = currentAsset,
              validatedItem(for: currentRouteItem.downloadID) != nil else {
            invalidateCurrentAsset()
            return
        }
        if player.isAlreadyLivePresentation(lease: ownerLease, source: .offline(asset)) {
            syncOfflineInlinePortraitImmersiveBinding()
            syncOfflinePortraitFullscreenContext()
            applyModeDPortraitFullscreenIfNeeded()
            return
        }
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
        PortraitPagingPolicy.allowsVerticalPaging(
            on: .offlinePlayback,
            isImmersiveStage: showsInRouteOfflineImmersive,
            itemCount: pagingContext.items.count
        ) && isActiveOfflineRoute && !player.isFullscreenPresentationActive
    }

    private var hostOwnsInlineSurface: Bool {
        PlayerDetailSurfacePolicy.hostOwnsInlineSurface(player: player, lease: ownerLease)
    }

    private func updateImmersiveViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
        if DeviceCapability.supportsOrientationLock, player.isFullscreenPresentationActive { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if immersiveViewportSize != rounded {
            immersiveViewportSize = rounded
        }
        pagingReducer.updateContainerHeight(rounded.height)
        pagingReducer.noteCoverResolution(width: rounded.width, height: rounded.height)
        if dragOffsetBox.y != pagingReducer.offset {
            dragOffsetBox.y = pagingReducer.offset
        }
    }

    private func beginPagingDrag() -> Bool {
        guard pagingNeighboursReachable else { return false }
        let stageSize = offlineImmersiveStageSize
        pagingReducer.updateContainerHeight(stageSize.height)
        pagingReducer.noteCoverResolution(width: stageSize.width, height: stageSize.height)
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
        let switched = PortraitPagingSettlementDispatcher.complete(
            token: token,
            getReducer: { pagingReducer },
            setReducer: { pagingReducer = $0 },
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
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.portraitPureViewEnabled = false
                userCollapsedImmersiveDownloadID = nil
                dragOffsetBox.y = 0
                _ = activateCurrent()
            }
        )
        if !switched {
            dragOffsetBox.y = pagingReducer.offset
        }
    }

    private var pagingNeighbourPreviews: some View {
        let stageSize = offlineImmersiveStageSize
        let containerHeight = pagingReducer.containerHeight > 0
            ? pagingReducer.containerHeight
            : stageSize.height
        return ZStack {
            if pagingNeighboursReachable {
                if let previous = pagingReducer.previousIndex {
                    neighbourPreview(index: previous, pageSize: stageSize)
                        .modifier(PortraitDragOffset(
                            box: dragOffsetBox, base: -containerHeight
                        ))
                }
                if let next = pagingReducer.nextIndex {
                    neighbourPreview(index: next, pageSize: stageSize)
                        .modifier(PortraitDragOffset(
                            box: dragOffsetBox, base: containerHeight
                        ))
                }
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
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
    private func neighbourPreview(index: Int, pageSize: CGSize) -> some View {
        if pagingContext.items.indices.contains(index) {
            let routeItem = pagingContext.items[index]
            PortraitPagerCoverBackdrop(
                coverSource: routeItem.preview.coverSource,
                title: routeItem.preview.title,
                ownerName: routeItem.preview.ownerName,
                pageSize: pageSize,
                resolutionBudget: pagingReducer.coverResolutionBudget
            )
        } else {
            Color.clear
        }
    }
}
extension OfflinePlayerView {
    @ViewBuilder
    private func offlinePlayerSlot(
        item: DownloadedVideo,
        size: CGSize,
        cornerRadius: CGFloat,
        isImmersiveStage: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if isActiveOfflineRoute {
                if hostOwnsInlineSurface {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(width: size.width, height: size.height)
                } else {
                    PlayerView(
                        owner: owner,
                        surfaceRole: .inline,
                        verticalPagingGestureSink: pagingSink,
                        pageNavigationActions: playerPageNavigation,
                        inlineViewportSize: size,
                        inlineCornerRadius: cornerRadius,
                        isInlinePortraitImmersive: isImmersiveStage,
                        screenLease: ownerLease,
                        placeholderCoverURL: item.coverURL
                    )
                    .frame(width: size.width, height: size.height)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                        guard !player.isFullscreenPresentationActive, hasInlineExitChrome else {
                            return
                        }
                        player.refreshInlineVideoRect()
                    }

                    if !player.isFullscreenPresentationActive,
                       danmakuEnabled,
                       offlineHasDanmaku,
                       playerShapeIsCurrent,
                       !playerMountsNativeDanmaku {
                        OfflineDanmakuOverlay(
                            player: player,
                            folderURL: item.folderURL,
                            cid: item.cid
                        )
                        .frame(width: size.width, height: size.height)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: cornerRadius,
                                style: .continuous
                            )
                        )
                        .allowsHitTesting(false)
                    }
                }
            } else {
                RouteActivationPlaceholderView(
                    still: player.outgoingRouteStill(for: owner),
                    coverURL: item.coverURL,
                    height: size.height,
                    cornerRadius: cornerRadius
                )
                .frame(width: size.width, height: size.height)
            }

            if !isImmersiveStage {
                PlayerDetailInlineNavigationOverlay(
                    player: player,
                    isActiveRoute: isActiveOfflineRoute,
                    hasInlineExitChrome: { hasInlineExitChrome },
                    scrimWidth: size.width,
                    scrimHeight: size.height,
                    cornerRadius: cornerRadius,
                    actions: playerPageNavigation
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            PlayerInlineSlotProbe(cornerRadius: cornerRadius)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        let isImmersiveStage = rendersFullBleedOfflineImmersive
        return ZStack {
            if !isSplitLayout {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { updateImmersiveViewportSize(proxy.size) }
                        .onChange(of: proxy.size) { _, newSize in
                            updateImmersiveViewportSize(newSize)
                        }
                }
                .ignoresSafeArea(.all, edges: .all)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

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
                            isCondensed: shapeIsCurrent && player.inlineCondensed,
                            videoAspectRatio: resolvedOfflineAspectRatio,
                            topSafeArea: AppWindowMetrics.safeAreaInsets.top
                        )
                        let playerCornerRadius: CGFloat = layout.isSplit ? DetailStageLayout.playerCornerRadius : 0
                        if layout.isSplit {
                            OfflinePlayerPage(layout: layout, viewportHeight: max(0, geometry.size.height)) {
                                offlinePlayerSlot(
                                    item: item,
                                    size: layout.playerSize,
                                    cornerRadius: playerCornerRadius,
                                    isImmersiveStage: false
                                )
                            } metadata: {
                                OfflinePlayerMetadataView(
                                    title: item.title,
                                    ownerName: item.ownerName,
                                    qualityLabel: item.qualityLabel,
                                    fileSizeBytes: item.fileSizeBytes,
                                    isSplit: true,
                                    onOpenOriginal: originalVideoTarget(for: item).map { target in
                                        {
                                            player.unregisterOfflineDanmakuDirectory(for: currentAsset)
                                            coordinator.navigate(to: .videoDetail(target))
                                        }
                                    }
                                )
                            }
                        } else {
                            let stageSize = offlineImmersiveStageSize
                            let slotSize = isImmersiveStage ? stageSize : layout.playerSize
                            let topInset = AppWindowMetrics.safeAreaInsets.top
                            ZStack(alignment: .topLeading) {
                                ScrollView(.vertical) {
                                    OfflinePlayerMetadataView(
                                        title: item.title,
                                        ownerName: item.ownerName,
                                        qualityLabel: item.qualityLabel,
                                        fileSizeBytes: item.fileSizeBytes,
                                        isSplit: false,
                                        onOpenOriginal: originalVideoTarget(for: item).map { target in
                                            {
                                                player.unregisterOfflineDanmakuDirectory(for: currentAsset)
                                                coordinator.navigate(to: .videoDetail(target))
                                            }
                                        }
                                    )
                                    .frame(width: layout.metadataWidth, alignment: .topLeading)
                                }
                                .scrollIndicators(.hidden)
                                .scrollBounceBehavior(.basedOnSize)
                                .padding(.top, layout.playerSize.height + topInset)
                                .frame(width: layout.metadataWidth, alignment: .topLeading)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .opacity(isImmersiveStage ? 0 : 1)
                                .allowsHitTesting(!isImmersiveStage)
                                .accessibilityHidden(isImmersiveStage)

                                if isImmersiveStage {
                                    pagingNeighbourPreviews
                                }

                                offlinePlayerSlot(
                                    item: item,
                                    size: slotSize,
                                    cornerRadius: 0,
                                    isImmersiveStage: isImmersiveStage
                                )
                                .padding(.top, isImmersiveStage ? 0 : topInset)
                                .modifier(PortraitDragOffset(box: dragOffsetBox))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .ignoresSafeArea(.container, edges: .all)
                            .animation(
                                (!isImmersiveStage
                                    && DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                                        isActiveRoute: isActiveOfflineRoute,
                                        isWideLayout: isSplitLayout,
                                        isFullscreenPresentationActive: player.isFullscreenPresentationActive,
                                        isFullscreen: player.isFullscreen
                                    ))
                                    ? motion.animation(normal: .snappy(duration: 0.22))
                                    : nil,
                                value: resolvedOfflineAspectRatioKey
                            )
                        }
                    }
                    .ignoresSafeArea(.keyboard, edges: isImmersiveStage ? .all : [])
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .playerDetailInlineContainerSize(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isActiveRoute: isActiveOfflineRoute
        ) { size in
            if inlineContainerSize != size { inlineContainerSize = size }
        }
        .playerDetailDeferredSize(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isActiveRoute: isActiveOfflineRoute
        ) { size in
            if containerWidth != size.width { containerWidth = size.width }
        }
        .playerDetailChrome(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isStatusBarHidden: player.isFullscreen || isImmersiveStage,
            guardsIPadTopSafeArea: !isImmersiveStage,
            presentationContext: presentationContext,
            coordinator: coordinator
        ) {
            offlineBackdrop(isImmersiveStage: isImmersiveStage)
        }
        .onChange(of: isActiveOfflineRoute, initial: true) { oldActive, active in
            if active {
                frozenDepartureImmersiveActive = nil
                syncOfflineInlinePortraitImmersiveBinding()
                syncOfflinePortraitFullscreenContext()
                applyModeDPortraitFullscreenIfNeeded()
            } else {
                if oldActive, !isSplitLayout {
                    frozenDepartureImmersiveActive = isPortraitImmersiveStageActive
                }
                clearOfflineInlinePortraitImmersiveBindingIfOwned()
                clearOfflinePortraitFullscreenContextIfOwned()
                if oldActive {
                    player.pauseForRouteDeparture(lease: ownerLease)
                }
            }
        }
        .onChange(of: showsInRouteOfflineImmersive) { _, active in
            guard isActiveOfflineRoute else { return }
            syncOfflineInlinePortraitImmersiveBinding()
            syncOfflinePortraitFullscreenContext()
            if !active {
                dragOffsetBox.y = 0
            }
        }
        .onChange(of: offlinePortraitContextFingerprint, initial: true) { _, _ in
            syncOfflinePortraitFullscreenContext()
        }
        .onChange(of: resolvedOfflineAspectRatioKey) { _, _ in
            applyModeDPortraitFullscreenIfNeeded()
        }
        .onChange(of: ownerLease) { _, _ in
            syncOfflineInlinePortraitImmersiveBinding()
            syncOfflinePortraitFullscreenContext()
            applyModeDPortraitFullscreenIfNeeded()
        }
        .onChange(of: player.currentURL) { _, _ in
            applyModeDPortraitFullscreenIfNeeded()
        }
        .onChange(of: player.hasRenderedFirstFrame) { _, _ in
            applyModeDPortraitFullscreenIfNeeded()
        }
        .onChange(of: currentRouteItem.downloadID) { _, _ in
            userCollapsedImmersiveDownloadID = nil
            syncOfflinePortraitFullscreenContext()
            applyModeDPortraitFullscreenIfNeeded()
        }
        .task(id: isActiveOfflineRoute) {
            guard !Task.isCancelled, isActiveOfflineRoute else { return }
            startSessionIfNeeded()
        }
        .task(id: currentAsset) {
            guard let asset = currentAsset else {
                offlineHasDanmaku = false
                return
            }
            let folderURL = asset.videoURL.deletingLastPathComponent()
            let hasDanmaku = await Task.detached(priority: .utility) {
                OfflineDanmakuSidecar.hasDanmaku(in: folderURL)
            }.value
            guard !Task.isCancelled, currentAsset == asset else { return }
            offlineHasDanmaku = hasDanmaku
        }
        .onChange(of: currentAsset) { old, new in
            guard old != new else { return }
            if let old {
                player.unregisterOfflineDanmakuDirectory(for: old)
            }
            if new == nil || validatedItem(for: currentRouteItem.downloadID) == nil { invalidateCurrentAsset() }
        }
        .onDisappear {
            guard scenePhase == .active else { return }
            releaseOwnerLease()
        }
    }

    @ViewBuilder
    private func offlineBackdrop(isImmersiveStage: Bool) -> some View {
        if let item, assetValid {
            if isImmersiveStage {
                Color.black.ignoresSafeArea()
            } else {
                CinematicBackdrop(
                    coverURL: item.coverURL,
                    player: player,
                    ownerLease: ownerLease,
                    isRouteActive: isActiveOfflineRoute
                )
            }
        } else {
            PlayerAmbientPolicy.groundColor.ignoresSafeArea()
        }
    }
}
