import Observation
import SwiftUI
import UIKit

struct VideoDetailCommentPresentationReader<Content: View>: View {
    let presentation: CommentZoomPresentation
    let content: (Bool) -> Content

    init(
        presentation: CommentZoomPresentation,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.presentation = presentation
        self.content = content
    }

    var body: some View { content(presentation.isPresented) }
}

private struct CommentSourceChange: ViewModifier {
    let model: VideoDetailViewModel
    let action: (VideoDetailViewModel.CommentSource?) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: model.currentCommentSource) { _, source in action(source) }
    }
}

private struct VideoDetailErrorAlertObserver: ViewModifier {
    let model: VideoDetailViewModel
    @State private var errorAlert: ToastMessage?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.toast) { _, toast in
                guard let toast, toast.style == .error else { return }
                errorAlert = toast
                model.toast = nil
            }
            .alert(
                "Operation Failed",
                isPresented: Binding(
                    get: { errorAlert != nil },
                    set: { if !$0 { errorAlert = nil } }
                ),
                presenting: errorAlert
            ) { _ in
                Button("OK", role: .cancel) { errorAlert = nil }
            } message: { alert in
                Text(alert.text)
            }
    }
}

enum DetailDepartureHeightFreezePolicy {
    static func resolvedHeight(
        isWideLayout: Bool,
        wideHeight: CGFloat,
        isActiveRoute: Bool,
        frozenStateHeight: CGFloat?,
        cachedActiveHeight: CGFloat?,
        computedHeight: CGFloat
    ) -> CGFloat {
        if isWideLayout { return wideHeight }
        if !isActiveRoute, let frozen = frozenStateHeight ?? cachedActiveHeight {
            return frozen
        }
        return computedHeight
    }

    static func allowsInlineHeightAnimation(
        isActiveRoute: Bool,
        isWideLayout: Bool,
        isFullscreenPresentationActive: Bool,
        isFullscreen: Bool
    ) -> Bool {
        isActiveRoute
            && !isWideLayout
            && !isFullscreenPresentationActive
            && !isFullscreen
    }

    static func shouldDeferRelatedGrid(
        isCompact: Bool,
        hasVideos: Bool,
        isTransitionSettled: Bool
    ) -> Bool {
        hasVideos && isCompact && !isTransitionSettled
    }
}

struct VideoDetailView: View {
    enum DetailSheet: Identifiable {
        enum ID: Hashable {
            case report(Int)
            case favorite
            case music(MusicDestination.ID)
            case download(UUID)
            case batchDownload(UUID)
            case playlist
            case share(UUID)
        }

        case report(aid: Int)
        case favorite
        case music(MusicDestination)
        case download(DownloadQualityPresentation)
        case batchDownload(BatchDownloadPresentation)
        case playlist
        case share(VideoSharePayload)

        var id: ID {
            switch self {
            case .report(let aid): .report(aid)
            case .favorite: .favorite
            case .music(let destination): .music(destination.id)
            case .download(let presentation): .download(presentation.id)
            case .batchDownload(let presentation): .batchDownload(presentation.id)
            case .playlist: .playlist
            case .share(let payload): .share(payload.id)
            }
        }
    }

    final class PageOffsetStore {
        var offsets: [Int: CGFloat] = [:]
        var lastActivePlayerVideoHeight: CGFloat?
        var lastActiveExpandedVideoHeight: CGFloat?
    }

    @AppMotion var motion
    let target: VideoRouteTarget
    @State var screenOwner: String
    @State var viewModel = VideoDetailViewModel()

    @State var commentPresentation = CommentZoomPresentation()
    @State var replyPresentation = CommentZoomPresentation()
    @State var composer = VideoCommentComposerState()
    @State var activeSheet: DetailSheet?
    @State var showThread: CommentThreadTarget?
    @State var commentTargetRpid: Int?
    @State var highlightedCommentRpid: Int?
    @State var previewImages: ImagePreviewItem?
    @State var downloadRequestSerial: UInt64 = 0
    @State var favoriteRequestInFlight = false
    @State var pageOffsetStore = PageOffsetStore()
    @State var lastCondenseFlipAt: CFTimeInterval = 0
    @State var inlineScrollOffset: CGFloat = 0
    @State var isPortraitImmersiveStageActive: Bool
    @State var userCollapsedImmersiveVideoID: VideoID?
    @State var immersiveFeedSession = PortraitImmersiveFeedSession()
    @State var immersiveDragOffsetBox = PortraitDragOffsetBox()
    @State var immersivePagingCoordinator = PlayerVerticalPagingCoordinator()
    @State var immersiveViewportSize: CGSize = WindowMetricsFallback.currentBounds.size
    @State var hasInitializedImmersiveSession = false
    @State var frozenDepartureImmersiveActive: Bool?
    @State var containerMetrics = PlayerDetailContainerMetrics()
    @State var stageController = DetailStageController()
    @State var commentLinkLifetime = ContentLinkLifetime()
    @State var routePosition: PlayerRoutePosition?
    @State var presentationScreenID = UUID()
    @State var activePlaylistTarget: VideoRouteTarget?
    @State var detailScrollToTopTick = 0
    @State var lastActivePlayerVideoHeight: CGFloat?
    @State var lastActiveExpandedVideoHeight: CGFloat?
    @State var isRouteTransitionSettled = false

    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.scenePhase) var scenePhase

    init(target: VideoRouteTarget, routePosition: PlayerRoutePosition? = nil) {
        self.target = target
        _routePosition = State(initialValue: routePosition)
        _screenOwner = State(initialValue: "vod-detail-\(UUID().uuidString)")
        let cachedSnapshot = VideoDetailReactivationPolicy.retainsScreenData
            ? VideoDetailScreenDataCache.snapshot(for: target.videoID)
            : nil
        let cachedPage: VideoInfo.VideoPage? = cachedSnapshot.flatMap { snap in
            let cid = snap.cid ?? snap.info.cid
            return snap.info.pages?.first(where: { $0.cid == cid })
        }
        let resolvedInitialAspect = cachedPage?.dimension?.effectiveAspectRatio
            ?? cachedSnapshot?.info.dimension?.effectiveAspectRatio
            ?? target.preview.aspectRatioHint
        let resolvedInitialPortrait = cachedPage?.dimension?.isPortrait
            ?? cachedSnapshot?.info.dimension?.isPortrait
            ?? target.preview.isPortraitHint
            ?? false
        _viewModel = State(
            initialValue: VideoDetailViewModel(
                prehydratedSnapshot: cachedSnapshot,
                initialAspectRatioHint: resolvedInitialAspect
            )
        )
        _isRouteTransitionSettled = State(initialValue: cachedSnapshot != nil)
        let initialImmersive = PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: PlayerPlaybackPreferences.portraitVideoMode,
            isWideLayout: false,
            usesCompactFraming: DeviceCapability.usesCompactPortraitVideoFraming,
            aspectRatio: resolvedInitialAspect,
            isPortraitFallback: resolvedInitialPortrait
        )
        _isPortraitImmersiveStageActive = State(initialValue: initialImmersive)
    }

    var player: PlayerViewModel { PlayerViewModel.shared }
    var routeVideoID: VideoID { target.videoID }
    var activeTarget: VideoRouteTarget { activePlaylistTarget ?? target }
    var videoID: VideoID { activeTarget.videoID }

    var isActiveVideoRoute: Bool {
        coordinator.isActivePlayerRoute(.video(routeVideoID), position: routePosition)
    }

    var showsInRoutePortraitImmersive: Bool {
        !isWideLayout && isActiveVideoRoute && isPortraitImmersiveStageActive
    }

    var rendersFullBleedImmersiveStage: Bool {
        guard !isWideLayout else { return false }
        if isActiveVideoRoute {
            return isPortraitImmersiveStageActive
        }
        return frozenDepartureImmersiveActive ?? isPortraitImmersiveStageActive
    }

    var immersiveStageSize: CGSize {
        if immersiveViewportSize.width > 1, immersiveViewportSize.height > 1 {
            return immersiveViewportSize
        }
        return WindowMetricsFallback.currentBounds.size
    }

    var immersivePagingNeighboursReachable: Bool {
        PortraitPagingPolicy.allowsVerticalPaging(
            on: .onlineDetail,
            isImmersiveStage: showsInRoutePortraitImmersive,
            itemCount: immersiveFeedSession.entries.count
        ) && !player.isFullscreenPresentationActive && !player.fullscreenDanmakuComposerPresented
    }

    var immersivePagingSink: PlayerVerticalPagingCoordinator? {
        guard immersivePagingNeighboursReachable else { return nil }
        immersivePagingCoordinator.install(.init(
            canPagePrevious: { immersiveFeedSession.reducer.previousIndex != nil },
            begin: beginImmersivePagingDrag,
            change: updateImmersivePagingDrag,
            end: endImmersivePagingDrag,
            cancel: cancelImmersivePagingDrag
        ))
        return immersivePagingCoordinator
    }

    var activeFloatingPlaylistQueue: PlaybackQueueContext? {
        guard isActiveVideoRoute,
              !player.isFullscreen,
              let lease = viewModel.playerLease,
              player.isCurrentOwner(lease),
              let queue = player.activePlaylistQueue else {
            return nil
        }
        return queue
    }

    var containerWidth: CGFloat { containerMetrics.containerWidth }
    var isWideLayout: Bool { containerMetrics.isWideLayout(isRegularWidth: sizeClass == .regular) }
    var usesCompactPhoneActions: Bool { containerMetrics.usesCompactPhoneActions }
    var wideContainerHeight: CGFloat { containerMetrics.wideContainerHeight }
    var isKeyboardDocked: Bool { containerMetrics.isKeyboardDocked }
    var stagePresentation: DetailStagePresentation { stageController.presentation }
    var showsWideChrome: Bool { isWideLayout }
    var pageWidth: CGFloat { containerMetrics.pageWidth }
    var pagerBottomInset: CGFloat { AppWindowMetrics.safeAreaInsets.bottom }

    var stageGeometry: DetailStageLayout.Geometry {
        stageController.geometry(containerWidth: pageWidth, containerHeight: wideContainerHeight)
    }

    private var showsHeroBar: Bool { stageController.showsHeroBar(isWideLayout: isWideLayout) }
    private var wideVideoSize: CGSize { stageGeometry.playerSize }

    var compactBaseWidth: CGFloat {
        let fallbackBounds = WindowMetricsFallback.currentBounds
        return containerWidth > 0 ? containerWidth : min(fallbackBounds.width, fallbackBounds.height)
    }

    var metadataAspectRatioHint: CGFloat? {
        if viewModel.matchesLoadedVideo(videoID), let info = viewModel.videoInfo {
            let activePage: VideoInfo.VideoPage? = if let cid = viewModel.currentCid {
                info.pages?.first(where: { $0.cid == cid })
            } else {
                nil
            }
            return activePage?.dimension?.effectiveAspectRatio
                ?? info.dimension?.effectiveAspectRatio
                ?? activeTarget.preview.aspectRatioHint
        }
        return activeTarget.preview.aspectRatioHint
    }

    var effectiveInlineAspectRatio: CGFloat? {
        let fallback = metadataAspectRatioHint
        if playerShapeIsCurrent {
            return DetailPlayerGeometry.normalizedAspect(player.videoAspectRatio) ?? fallback
        }
        return fallback
    }

    var effectiveInlineAspectRatioKey: Int? {
        effectiveInlineAspectRatio.map { Int(($0 * 100).rounded()) }
    }

    var resolvedPortraitHint: Bool {
        DeviceCapability.usesCompactPortraitVideoFraming
            && (playerShapeIsCurrent ? player.isPortraitContent : metadataPortraitHint)
    }

    var currentDetailScrollOffset: CGFloat {
        inlineScrollOffset
    }

    private struct CompactHeightSnapshot: Equatable {
        let playerHeight: CGFloat
        let expandedHeight: CGFloat
    }

    private var computedExpandedInlineVideoHeight: CGFloat {
        if isWideLayout { return wideVideoSize.height }
        let base = compactBaseWidth
        return DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: base,
            primaryColumnWidth: nil,
            containerHeight: containerMetrics.restingHeight,
            topSafeArea: AppWindowMetrics.safeAreaInsets.top,
            videoAspectRatio: effectiveInlineAspectRatio,
            isPortraitFallback: resolvedPortraitHint
        )
    }

    private var computedPlayerVideoHeight: CGFloat {
        if isWideLayout { return wideVideoSize.height }
        let base = compactBaseWidth
        let shapeIsCurrent = playerShapeIsCurrent
        let isCommentsCondensed = commentPresentation.isPresented && shapeIsCurrent && player.inlineCondensed
        return DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: base,
            primaryColumnWidth: nil,
            containerHeight: containerMetrics.restingHeight,
            topSafeArea: AppWindowMetrics.safeAreaInsets.top,
            videoAspectRatio: effectiveInlineAspectRatio,
            isPortraitFallback: resolvedPortraitHint,
            scrollOffset: currentDetailScrollOffset,
            isManuallyCondensed: shapeIsCurrent && player.inlineCondensed,
            isManualLockActive: isCommentsCondensed
        )
    }

    private var activeCompactHeightSnapshot: CompactHeightSnapshot? {
        guard isActiveVideoRoute, !isWideLayout else { return nil }
        return CompactHeightSnapshot(
            playerHeight: computedPlayerVideoHeight,
            expandedHeight: computedExpandedInlineVideoHeight
        )
    }

    var expandedInlineVideoHeight: CGFloat {
        DetailDepartureHeightFreezePolicy.resolvedHeight(
            isWideLayout: isWideLayout,
            wideHeight: wideVideoSize.height,
            isActiveRoute: isActiveVideoRoute,
            frozenStateHeight: lastActiveExpandedVideoHeight,
            cachedActiveHeight: pageOffsetStore.lastActiveExpandedVideoHeight,
            computedHeight: computedExpandedInlineVideoHeight
        )
    }

    var playerVideoHeight: CGFloat {
        DetailDepartureHeightFreezePolicy.resolvedHeight(
            isWideLayout: isWideLayout,
            wideHeight: wideVideoSize.height,
            isActiveRoute: isActiveVideoRoute,
            frozenStateHeight: lastActivePlayerVideoHeight,
            cachedActiveHeight: pageOffsetStore.lastActivePlayerVideoHeight,
            computedHeight: computedPlayerVideoHeight
        )
    }

    var playerShapeIsCurrent: Bool {
        guard viewModel.matchesLoadedVideo(videoID), let aid = viewModel.videoInfo?.aid else { return false }
        return player.ownerKey == screenOwner && player.mode == .vod && player.currentAid == aid
    }

    var metadataPortraitHint: Bool {
        guard DeviceCapability.usesCompactPortraitVideoFraming else { return false }
        if viewModel.matchesLoadedVideo(videoID), let info = viewModel.videoInfo {
            guard let cid = viewModel.currentCid, cid != info.cid,
                  let page = info.pages?.first(where: { $0.cid == cid }) else {
                return info.dimension?.isPortrait ?? activeTarget.preview.isPortraitHint ?? false
            }
            return (page.dimension?.isPortrait ?? info.dimension?.isPortrait ?? activeTarget.preview.isPortraitHint)
                ?? false
        }
        return activeTarget.preview.isPortraitHint ?? false
    }

    private var inlineManualCondenseKey: Int {
        guard !isWideLayout, playerShapeIsCurrent else { return 0 }
        return player.inlineCondensed ? 1 : 0
    }

    private var inlineAspectAnimation: Animation? {
        guard !rendersFullBleedImmersiveStage,
              DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                  isActiveRoute: isActiveVideoRoute,
                  isWideLayout: isWideLayout,
                  isFullscreenPresentationActive: player.isFullscreenPresentationActive,
                  isFullscreen: player.isFullscreen
              ) else { return nil }
        return motion.animation(normal: .snappy(duration: 0.22))
    }

    private var inlinePlayerHeightAnimation: Animation? {
        guard !rendersFullBleedImmersiveStage,
              DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                  isActiveRoute: isActiveVideoRoute,
                  isWideLayout: isWideLayout,
                  isFullscreenPresentationActive: player.isFullscreenPresentationActive,
                  isFullscreen: player.isFullscreen
              ) else { return nil }
        return motion.animation(normal: .spring(duration: 0.32, bounce: 0.06))
    }

    private var playerAreaHeight: CGFloat {
        DetailPlayerGeometry.pinnedHeaderHeight(videoHeight: playerVideoHeight, isFullscreen: false)
    }

    private var detailContentTopInset: CGFloat {
        playerAreaHeight + DetailPlayerGeometry.contentTopGap
    }

    private var expandedDetailContentTopInset: CGFloat {
        DetailPlayerGeometry.pinnedHeaderHeight(
            videoHeight: expandedInlineVideoHeight,
            isFullscreen: false
        ) + DetailPlayerGeometry.contentTopGap
    }

    private var hostOwnsInlineSurface: Bool {
        PlayerDetailSurfacePolicy.hostOwnsInlineSurface(player: player, lease: viewModel.playerLease)
    }

    var hasUsableInlinePlayerChrome: Bool {
        guard isActiveVideoRoute, viewModel.error == nil, viewModel.unavailability == nil,
              player.error == nil, player.unavailability == nil,
              player.videoPresentationFailureMessage == nil, player.currentURL != nil,
              let lease = viewModel.playerLease else { return false }
        return player.isCurrentOwner(lease) && player.mode == .vod
            && player.surfaceLease(matching: lease, role: .inline) != nil
    }

    var presentationContext: PlayerScreenPresentationContext? {
        guard isActiveVideoRoute else { return nil }
        let source: PlayerPresentationSource? = if let aid = viewModel.videoInfo?.aid,
            let cid = viewModel.currentCid {
            .vod(aid: aid, cid: cid, source: .ugc)
        } else {
            nil
        }
        return player.presentationContext(
            screenID: presentationScreenID, lease: viewModel.playerLease,
            route: .video(routeVideoID), position: routePosition,
            source: source
        )
    }

    private struct PortraitContextSyncFingerprint: Equatable {
        let lease: PlayerOwnerLease?
        let isActiveRoute: Bool
        let isInRouteImmersiveStage: Bool
        let aid: Int?
        let bvid: String?
        let currentCid: Int?
        let pagesCount: Int
        let seasonEpisodeCount: Int
        let title: String
        let upMid: Int?
        let upName: String
        let upAvatarURL: String?
        let isFollowing: Bool?
        let isLiked: Bool
        let likeCount: Int?
        let isCoined: Bool
        let userCoinCount: Int
        let statCoinCount: Int?
        let maxCoins: Int
        let isFavorited: Bool
        let favoriteCount: Int?
        let replyCount: Int?
        let shareCount: Int?
        let commentsClosed: Bool
    }

    private var portraitContextSyncFingerprint: PortraitContextSyncFingerprint? {
        guard isActiveVideoRoute else { return nil }
        let info = viewModel.matchesLoadedVideo(videoID) ? viewModel.videoInfo : nil
        return PortraitContextSyncFingerprint(
            lease: viewModel.playerLease,
            isActiveRoute: isActiveVideoRoute,
            isInRouteImmersiveStage: showsInRoutePortraitImmersive,
            aid: info?.aid,
            bvid: info?.bvid,
            currentCid: viewModel.currentCid,
            pagesCount: info?.pages?.count ?? 0,
            seasonEpisodeCount: info?.ugcSeason?.allEpisodes.count ?? 0,
            title: info?.title ?? activeTarget.preview.title,
            upMid: info?.owner.mid,
            upName: info?.owner.name ?? activeTarget.preview.ownerName,
            upAvatarURL: info?.owner.face,
            isFollowing: viewModel.isFollowingUp,
            isLiked: viewModel.isLiked,
            likeCount: info?.stat.like,
            isCoined: viewModel.isCoined,
            userCoinCount: viewModel.coinCount,
            statCoinCount: info?.stat.coin,
            maxCoins: viewModel.maxCoins,
            isFavorited: viewModel.isFavorited,
            favoriteCount: info?.stat.favorite,
            replyCount: info?.stat.reply,
            shareCount: info?.stat.share,
            commentsClosed: viewModel.commentsClosed
        )
    }

    private var placeholderCoverURL: String? {
        let prefersPortraitVariant = showsInRoutePortraitImmersive || resolvedPortraitHint
        if prefersPortraitVariant,
           let mobile = activeTarget.preview.coverSource.mobileVariantURL,
           !mobile.isEmpty {
            return mobile
        }
        if viewModel.matchesLoadedVideo(videoID), let pic = viewModel.videoInfo?.pic, !pic.isEmpty {
            return pic
        }
        let preferredKind: PortraitPagingCoverSource.Kind = prefersPortraitVariant ? .mobileVariant : .desktop
        let preview = activeTarget.preview.coverSource.url(preferring: preferredKind)
        if !preview.isEmpty { return preview }
        let desktopFallback = activeTarget.preview.coverSource.desktopURL
        if !desktopFallback.isEmpty { return desktopFallback }
        if let pic = viewModel.videoInfo?.pic, !pic.isEmpty { return pic }
        return nil
    }

    private var playerPageNavigation: PlayerPageNavigationActions {
        PlayerPageNavigationActions(
            onBack: {
                guard isActiveVideoRoute else { return }
                coordinator.goBack()
            },
            onHome: {
                guard isActiveVideoRoute else { return }
                coordinator.goHome()
            },
            onDownload: viewModel.videoInfo.map { info in { offerDownload(info) } },
            onReport: viewModel.videoInfo.map { info in { activeSheet = .report(aid: info.aid) } },
            pageOwnsInlineNavigation: true,
            onHideVideo: viewModel.videoInfo.map { info in { hideCurrentVideoAndExit(info) } },
            onBlockOwner: viewModel.videoInfo.flatMap { info in
                info.owner.mid > 0 ? { blockCurrentOwnerAndExit(info) } : nil
            }
        )
    }

    private func hideCurrentVideoAndExit(_ info: VideoInfo) {
        guard isActiveVideoRoute else { return }
        let store = LocalContentFilterStore.shared
        let added = store.blockVideo(
            aid: info.aid,
            bvid: info.bvid,
            title: info.title,
            ownerName: info.owner.name
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let aid = info.aid
        let bvid = info.bvid
        ContentFilterUndoToastCenter.shared.show(
            message: String(localized: "Hidden video locally"),
            systemImage: "eye.slash"
        ) {
            if let added {
                store.unblockVideo(id: added.id)
            } else {
                store.unblockVideo(aid: aid, bvid: bvid)
            }
        }
        viewModel.stopPlaybackForLocalFilterExit()
        coordinator.goBack()
    }

    private func blockCurrentOwnerAndExit(_ info: VideoInfo) {
        guard isActiveVideoRoute else { return }
        let mid = info.owner.mid
        guard mid > 0 else { return }
        let trimmed = info.owner.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "UID \(mid)" : trimmed
        let store = LocalContentFilterStore.shared
        _ = store.blockUP(mid: mid, name: displayName, face: info.owner.face)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ContentFilterUndoToastCenter.shared.show(
            message: String(format: String(localized: "Locally blocked UP \"%@\""), displayName),
            systemImage: "person.slash"
        ) {
            store.unblockUP(mid: mid)
        }
        viewModel.stopPlaybackForLocalFilterExit()
        coordinator.goBack()
    }

    func setStagePresentation(_ next: DetailStagePresentation) {
        stageController.transition(to: next, isWideLayout: isWideLayout, motion: motion)
    }

    private func handleStageScroll(_ offset: CGFloat) {
        stageController.handleScroll(
            offset: offset,
            isWideLayout: showsWideChrome,
            motion: motion,
            logTag: "Stage"
        )
    }

    var body: some View {
        let base = applyRouteAndImmersiveObservers(to: rootStageStack)
        let observed = applyPlaybackAndQueueObservers(to: base)
        return applySheetsAndAlerts(to: observed)
    }

    private var rootStageStack: some View {
        let inlineCornerRadius = showsWideChrome ? DetailStageLayout.playerCornerRadius : 0
        let isImmersiveStage = rendersFullBleedImmersiveStage
        return ZStack(alignment: .bottom) {
            PlayerDetailGeometryProbes(
                isWideLayout: isWideLayout,
                restingHeight: containerMetrics.restingHeight,
                isFullscreenPresentationActive: player.isFullscreenPresentationActive,
                onSizeChange: { size in
                    containerMetrics.update(size: size, isRegularWidth: sizeClass == .regular)
                },
                onKeyboardDockedChange: { docked in
                    containerMetrics.updateKeyboardDocked(docked)
                }
            )

            if !isWideLayout {
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

            mainStageContentStack(
                isImmersiveStage: isImmersiveStage,
                inlineCornerRadius: inlineCornerRadius
            )

            if !isWideLayout {
                floatingPlaylistCapsuleOverlay
                    .opacity(isImmersiveStage ? 0 : 1)
                    .allowsHitTesting(!isImmersiveStage)
                compactCommentsOverlay
                    .opacity(isImmersiveStage ? 0 : 1)
                    .allowsHitTesting(!isImmersiveStage)
                    .accessibilityHidden(isImmersiveStage)
                    .animation(inlineAspectAnimation, value: effectiveInlineAspectRatioKey)
                    .animation(inlinePlayerHeightAnimation, value: inlineManualCondenseKey)
            }

            VideoDetailComposerDismissScrim(
                composer: composer,
                isActive: showsWideChrome && stagePresentation == .stage && showThread == nil,
                ignoresSafeArea: true
            )

            if showsWideChrome {
                floatingPlaylistCapsuleOverlay
                ObservedModel(viewModel) { model in
                    wideCommentPanel(model: model, geometry: stageGeometry)
                }
            }

            VideoDetailRootToastView(
                model: viewModel,
                commentPresentation: commentPresentation,
                isWideLayout: isWideLayout,
                showsWideChrome: showsWideChrome,
                showsInRoutePortraitImmersive: showsInRoutePortraitImmersive,
                pagerBottomInset: pagerBottomInset,
                stagePresentation: stagePresentation,
                stagePanelWidth: stageGeometry.panelWidth,
                hasActiveThread: showThread != nil
            )
            .zIndex(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.keyboard, edges: isImmersiveStage ? .all : (!isWideLayout ? .bottom : []))
        .playerDetailChrome(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isStatusBarHidden: player.isFullscreen || showsInRoutePortraitImmersive,
            guardsIPadTopSafeArea: !isImmersiveStage,
            preventsContentDismissal: isActiveVideoRoute,
            presentationContext: presentationContext,
            coordinator: coordinator
        ) {
            if isImmersiveStage {
                Color.black.ignoresSafeArea()
            } else {
                CinematicBackdrop(
                    coverURL: placeholderCoverURL,
                    player: player,
                    ownerLease: viewModel.playerLease,
                    isRouteActive: isActiveVideoRoute,
                    inlinePlayerHeight: playerVideoHeight
                )
            }
        }
    }

    private func mainStageContentStack(
        isImmersiveStage: Bool,
        inlineCornerRadius: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if isWideLayout {
                wideContent(bottomInset: pagerBottomInset)
            } else {
                compactContent()
                    .padding(.top, AppWindowMetrics.safeAreaInsets.top)
                    .opacity(isImmersiveStage ? 0 : 1)
                    .allowsHitTesting(!isImmersiveStage)
                    .accessibilityHidden(isImmersiveStage)
            }

            if isImmersiveStage {
                immersivePagingNeighbourPreviews
            }

            inlinePlayerSlot(cornerRadius: isImmersiveStage ? 0 : inlineCornerRadius)
                .padding(
                    .top,
                    (!isWideLayout && !isImmersiveStage) ? AppWindowMetrics.safeAreaInsets.top : 0
                )
                .modifier(PortraitDragOffset(box: immersiveDragOffsetBox))
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            maxHeight: isWideLayout ? nil : .infinity,
            alignment: .topLeading
        )
        .animation(inlineAspectAnimation, value: effectiveInlineAspectRatioKey)
        .animation(inlinePlayerHeightAnimation, value: inlineManualCondenseKey)
        .ignoresSafeArea(.container, edges: isWideLayout ? [] : .all)
        .ignoresSafeArea(.keyboard, edges: isImmersiveStage ? .all : .bottom)
    }

    private func applyRouteAndImmersiveObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: activeCompactHeightSnapshot, initial: true) { _, snapshot in
                guard let snapshot else { return }
                pageOffsetStore.lastActivePlayerVideoHeight = snapshot.playerHeight
                pageOffsetStore.lastActiveExpandedVideoHeight = snapshot.expandedHeight
            }
            .onChange(of: isActiveVideoRoute, initial: true) { oldActive, active in
                handleRouteActivationChange(oldActive: oldActive, active: active)
            }
            .onChange(of: showsInRoutePortraitImmersive) { _, active in
                guard isActiveVideoRoute else { return }
                syncInlinePortraitImmersiveBinding()
                syncPortraitFullscreenContext()
                if active {
                    syncImmersiveFeedSessionForEntry()
                    triggerImmersiveRefillIfNeeded(forceSmallPool: true)
                } else {
                    immersiveDragOffsetBox.y = 0
                }
            }
            .onChange(of: portraitContextSyncFingerprint, initial: true) { _, fingerprint in
                guard isActiveVideoRoute, fingerprint != nil else { return }
                syncPortraitFullscreenContext()
            }
            .onChange(of: effectiveInlineAspectRatioKey) { _, _ in
                guard isActiveVideoRoute else { return }
                syncInlineScrollOffsetAfterAspectChange()
                applyModeDPortraitFullscreenIfNeeded()
            }
            .onChange(of: viewModel.playerLease) { _, _ in
                guard isActiveVideoRoute else { return }
                syncInlinePortraitImmersiveBinding()
                syncPortraitFullscreenContext()
                applyModeDPortraitFullscreenIfNeeded()
            }
    }

    private func applyPlaybackAndQueueObservers<Content: View>(to content: Content) -> some View {
        let firstGroup = content
            .onChange(of: player.currentURL) { _, _ in
                guard isActiveVideoRoute else { return }
                applyModeDPortraitFullscreenIfNeeded()
            }
            .onChange(of: player.hasRenderedFirstFrame) { _, _ in
                guard isActiveVideoRoute else { return }
                applyModeDPortraitFullscreenIfNeeded()
            }
            .onChange(of: videoID) { _, _ in
                inlineScrollOffset = 0
                userCollapsedImmersiveVideoID = nil
            }
            .onChange(of: viewModel.relatedVideos.map(\.bvid)) { _, _ in
                guard isActiveVideoRoute else { return }
                ensureImmersiveFeedSessionInitialized()
                immersiveFeedSession.ingestRelatedVideos(viewModel.relatedVideos)
                prewarmAdjacentImmersiveCovers()
            }
            .tint(Color.primary)
            .task(id: isActiveVideoRoute) { await activateIfNeeded(settlesNavigationAdmission: true) }
            .task(id: isActiveVideoRoute) {
                await settleRouteTransitionIfNeeded()
            }

        return firstGroup
            .onChange(of: coordinator.pendingCommentNavigation?.sequence) { _, _ in
                Task { await handlePendingCommentNavigationIfNeeded() }
            }
            .onChange(of: player.isFullscreen) { wasFullscreen, isFullscreen in
                guard wasFullscreen, !isFullscreen, isActiveVideoRoute else { return }
                syncVideoDetailAfterExternalPlaylistSwitch()
            }
            .onChange(of: player.playbackQueue) { _, _ in
                handlePlaybackQueueChange()
            }
            .onChange(of: viewModel.currentCid) { oldCid, newCid in
                guard let oldCid, let newCid, oldCid != newCid else { return }
                inlineScrollOffset = 0
                detailScrollToTopTick &+= 1
                syncPortraitFullscreenContext()
                applyModeDPortraitFullscreenIfNeeded()
            }
            .onDisappear(perform: handleRootDisappear)
            .onChange(of: player.fullscreenVODDanmakuSendFailure) { _, _ in
                guard !player.isFullscreen,
                      let message = player.takeFullscreenDanmakuFailure(ownerLease: viewModel.playerLease)
                else { return }
                viewModel.showToast(message, style: .error)
            }
    }

    private func applySheetsAndAlerts<Content: View>(to content: Content) -> some View {
        content
            .modifier(VideoDetailErrorAlertObserver(model: viewModel))
            .imagePreview(item: $previewImages)
            .sheet(item: $activeSheet, content: detailSheetView)
            .modifier(CommentSourceChange(model: viewModel) { source in
                composer.collapseImmediatelyIfSourceCleared(source)
                if let showThread,
                   showThread.type != 1
                    || showThread.oid != source?.aid
                    || composer.replyCommentSource != source {
                    commentPresentation.cancelPendingAction()
                    replyPresentation.cancelPendingAction()
                    replyPresentation.isPresented = false
                    self.showThread = nil
                    composer.replyCommentSource = nil
                    replyPresentation.anchors.sourceProvider = nil
                }
            })
    }

    private func handleRouteActivationChange(oldActive: Bool, active: Bool) {
        if active {
            frozenDepartureImmersiveActive = nil
            if lastActivePlayerVideoHeight != nil { lastActivePlayerVideoHeight = nil }
            if lastActiveExpandedVideoHeight != nil { lastActiveExpandedVideoHeight = nil }
            _ = claimPlayerLeaseIfNeeded()
            ensureImmersiveFeedSessionInitialized()
            installPlaylistSelectionHandlerIfNeeded()
            syncInlinePortraitImmersiveBinding()
            syncPortraitFullscreenContext()
            applyModeDPortraitFullscreenIfNeeded()
            if showsInRoutePortraitImmersive {
                triggerImmersiveRefillIfNeeded(forceSmallPool: true)
            }
        } else {
            if oldActive {
                viewModel.cacheCompletedScreenData()
            }
            if oldActive, !isWideLayout {
                frozenDepartureImmersiveActive = isPortraitImmersiveStageActive
                lastActivePlayerVideoHeight = pageOffsetStore.lastActivePlayerVideoHeight
                    ?? computedPlayerVideoHeight
                lastActiveExpandedVideoHeight = pageOffsetStore.lastActiveExpandedVideoHeight
                    ?? computedExpandedInlineVideoHeight
            }
            downloadRequestSerial &+= 1
            clearPlaylistSelectionHandlerIfOwned()
            clearInlinePortraitImmersiveBindingIfOwned()
            clearPortraitFullscreenContextIfOwned()
            if oldActive {
                viewModel.revokeLoadForRouteDeparture()
                player.pauseForRouteDeparture(lease: viewModel.playerLease)
            }
            coordinator.cancelVideoNavigation(routeVideoID)
        }
    }

    private func settleRouteTransitionIfNeeded() async {
        guard isActiveVideoRoute, !isRouteTransitionSettled else { return }
        if motion.reducesGeometry {
            isRouteTransitionSettled = true
            return
        }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled, isActiveVideoRoute else { return }
        isRouteTransitionSettled = true
    }

    private func handlePlaybackQueueChange() {
        if player.activePlaylistQueue != nil {
            installPlaylistSelectionHandlerIfNeeded()
        } else if case .playlist = activeSheet {
            activeSheet = nil
        }
        guard isActiveVideoRoute else { return }
        immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
        syncImmersiveViewportReducerMetrics()
        prewarmAdjacentImmersiveCovers()
    }

    private func handleRootDisappear() {
        downloadRequestSerial &+= 1
        clearPlaylistSelectionHandlerIfOwned()
        if case .download = activeSheet { activeSheet = nil }
        if case .batchDownload = activeSheet { activeSheet = nil }
        if case .playlist = activeSheet { activeSheet = nil }
        if case .share = activeSheet { activeSheet = nil }
        if scenePhase == .active, !isActiveVideoRoute {
            coordinator.cancelVideoNavigation(routeVideoID)
        }
        guard scenePhase == .active else {
            PlayerLog.log("[Detail] playback release deferred scenePhase=\(scenePhase)")
            return
        }
        clearInlinePortraitImmersiveBindingIfOwned()
        clearPortraitFullscreenContextIfOwned()
        viewModel.releasePlayback()
    }

    @ViewBuilder
    private func detailSheetView(_ sheet: DetailSheet) -> some View {
        switch sheet {
        case .report(let aid):
            VideoReportSheet(aid: aid)
        case .favorite:
            FavoriteFolderSheet(
                folders: viewModel.favFolders,
                selection: Set(viewModel.favFolders.filter(\.containsVideo).map(\.id))
            ) { selected in
                Task {
                    favoriteRequestInFlight = true
                    await viewModel.applyFavorite(selectedIds: selected)
                    favoriteRequestInFlight = false
                }
            }
        case .music(let destination):
            MusicDetailSheet(destination: destination) { activeSheet = nil }
        case .download(let presentation):
            DownloadQualitySheet(qualities: presentation.qualities) { quality in
                activeSheet = nil
                startDownload(presentation.info, cid: presentation.cid, quality: quality)
            }
            .appAdaptiveSheet(compactDetents: [.medium], padSizing: .form)
        case .batchDownload(let presentation):
            BatchEpisodeDownloadSheet(
                title: presentation.title,
                items: presentation.items,
                qualities: presentation.qualities,
                initialSelectedID: presentation.initialSelectedID
            ) { count in
                viewModel.showToast(
                    String(format: String(localized: "Added %lld downloads"), count),
                    style: .progress
                )
            }
        case .playlist:
            PlayerPlaylistDrawerSheet(player: player)
        case .share(let payload):
            VideoShareStudioSheet(payload: payload) {
                await viewModel.shareVideo()
                syncPortraitFullscreenContext()
            }
        }
    }

    private var endedPlayerRecommendations: [PlayerEndedRecommendation] {
        viewModel.relatedVideos.prefix(3).compactMap { video in
            guard !video.bvid.isEmpty else { return nil }
            return PlayerEndedRecommendation(
                id: video.bvid,
                bvid: video.bvid,
                title: video.title,
                authorName: video.owner.name,
                coverURL: video.pic.isEmpty ? nil : video.pic,
                durationSeconds: video.duration > 0 ? video.duration : nil
            )
        }
    }

    private func handleSelectEndedRecommendation(_ recommendation: PlayerEndedRecommendation) {
        let nextTarget: VideoRouteTarget? = if let matched = viewModel.relatedVideos.first(where: { $0.bvid == recommendation.bvid }) {
            VideoDetailRouteTargetFactory.relatedTarget(for: matched).withoutZoom
        } else {
            VideoRouteTarget.make(
                bvid: recommendation.bvid,
                aid: nil,
                title: recommendation.title,
                coverURL: recommendation.coverURL ?? "",
                ownerName: recommendation.authorName,
                durationSeconds: recommendation.durationSeconds ?? 0
            )?.withoutZoom
        }
        guard let nextTarget else { return }

        if isActiveVideoRoute, player.isFullscreen || isPortraitImmersiveStageActive {
            switchToRecommendedVideoInline(nextTarget)
            return
        }
        coordinator.navigateToVideo(nextTarget)
    }

    @ViewBuilder
    private var immersivePagingNeighbourPreviews: some View {
        let stageSize = immersiveStageSize
        let containerHeight = immersiveFeedSession.reducer.containerHeight > 0
            ? immersiveFeedSession.reducer.containerHeight
            : stageSize.height
        ZStack {
            if immersivePagingNeighboursReachable {
                if let previous = immersiveFeedSession.reducer.previousIndex {
                    immersiveNeighbourPreview(index: previous, pageSize: stageSize)
                        .modifier(PortraitDragOffset(
                            box: immersiveDragOffsetBox,
                            base: -containerHeight
                        ))
                }
                if let next = immersiveFeedSession.reducer.nextIndex {
                    immersiveNeighbourPreview(index: next, pageSize: stageSize)
                        .modifier(PortraitDragOffset(
                            box: immersiveDragOffsetBox,
                            base: containerHeight
                        ))
                }
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func immersiveNeighbourPreview(index: Int, pageSize: CGSize) -> some View {
        if let entry = immersiveFeedSession.entry(at: index) {
            PortraitPagerCoverBackdrop(
                coverSource: entry.target.preview.coverSource,
                title: entry.target.preview.title,
                ownerName: entry.target.preview.ownerName,
                pageSize: pageSize,
                resolutionBudget: immersiveFeedSession.reducer.coverResolutionBudget
            )
        } else {
            Color.clear
        }
    }

    private func inlinePlayerSlot(cornerRadius: CGFloat) -> some View {
        let isImmersiveStage = rendersFullBleedImmersiveStage
        let stageSize = immersiveStageSize
        let slotWidth: CGFloat? = if isImmersiveStage {
            stageSize.width
        } else if isWideLayout {
            wideVideoSize.width
        } else {
            nil
        }
        let slotHeight = isImmersiveStage ? stageSize.height : playerVideoHeight
        let viewportSize = isImmersiveStage
            ? stageSize
            : CGSize(
                width: isWideLayout ? wideVideoSize.width : containerWidth,
                height: playerVideoHeight
            )
        let effectiveCornerRadius: CGFloat = isImmersiveStage ? 0 : cornerRadius
        let outgoingStill = !isActiveVideoRoute ? player.outgoingRouteStill(for: screenOwner) : nil
        return ZStack {
            if isActiveVideoRoute {
                if hostOwnsInlineSurface {
                    RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(
                            width: slotWidth,
                            height: slotHeight
                        )
                        .frame(maxWidth: (isWideLayout || isImmersiveStage) ? nil : .infinity)
                } else {
                    PlayerView(
                        owner: screenOwner,
                        surfaceRole: .inline,
                        verticalPagingGestureSink: immersivePagingSink,
                        pageNavigationActions: playerPageNavigation,
                        inlineViewportSize: viewportSize,
                        inlineCornerRadius: effectiveCornerRadius,
                        isInlinePortraitImmersive: showsInRoutePortraitImmersive,
                        screenLease: viewModel.playerLease,
                        placeholderCoverURL: placeholderCoverURL,
                        showsLoadingIndicator: viewModel.error == nil && viewModel.unavailability == nil,
                        endedRecommendations: endedPlayerRecommendations,
                        onSelectEndedRecommendation: handleSelectEndedRecommendation
                    )
                    .transition(.opacity)
                }
            } else {
                RouteActivationPlaceholderView(
                    still: outgoingStill,
                    coverURL: placeholderCoverURL,
                    height: slotHeight,
                    cornerRadius: effectiveCornerRadius
                )
                .frame(width: isImmersiveStage ? stageSize.width : nil, height: slotHeight)
                .transition(.opacity)
            }
        }
        .animation(
            motion.feedbackAnimation(normal: .easeOut(duration: 0.2)),
            value: isActiveVideoRoute
        )
        .animation(
            motion.feedbackAnimation(normal: .easeOut(duration: 0.2)),
            value: outgoingStill != nil
        )
        .background {
            PlayerInlineSlotProbe(cornerRadius: effectiveCornerRadius)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: isImmersiveStage ? stageSize.width : (showsWideChrome ? wideVideoSize.width : nil))
        .overlay(alignment: .topLeading) {
            if !isImmersiveStage {
                PlayerDetailInlineNavigationOverlay(
                    player: player,
                    isActiveRoute: isActiveVideoRoute,
                    hasInlineExitChrome: { hasUsableInlinePlayerChrome },
                    cornerRadius: effectiveCornerRadius,
                    actions: playerPageNavigation
                )
            }
        }
        .detailStagePlayerPlacement(
            isActive: showsWideChrome, geometry: stageGeometry, presentation: stagePresentation
        )
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DetailPlayerGeometry.headerBottomInset(isFullscreen: isImmersiveStage))
    }

    private func wideContent(bottomInset: CGFloat) -> some View {
        let geometry = stageGeometry
        let topInset = DetailStageLayout.contentTopInset(
            playerHeight: geometry.playerSize.height, presentation: stagePresentation
        )
        let isStage = stagePresentation == .stage
        let playlistClearance: CGFloat = activeFloatingPlaylistQueue != nil ? 76 : 0
        return CinematicStageColumn(
            topInset: topInset,
            fadeGap: DetailStageLayout.contentGap(for: stagePresentation),
            bottomSpacer: bottomInset + VideoDetailLayoutMetrics.contentBottomPadding + playlistClearance
                + (isStage ? 0 : wideContainerHeight * 0.35),
            scrollToTopTrigger: detailScrollToTopTick,
            onOffset: handleStageScroll
        ) {
            detailColumn(
                columnWidth: geometry.columnWidth,
                horizontalInset: stagePresentation == .hero
                    ? geometry.playerOriginX : VideoDetailLayoutMetrics.cinematicTextInset,
                showsCommentsCapsule: true,
                isCompact: false
            )
            .frame(width: geometry.columnWidth, alignment: .leading)
            .padding(.leading, geometry.columnOriginX)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
    }

    private func compactContent() -> some View {
        let details = detailsPage(
            topInset: expandedDetailContentTopInset,
            fadeTopInset: detailContentTopInset,
            bottomInset: pagerBottomInset
        )
        return VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            details
                .allowsHitTesting(!commentsPresented)
                .accessibilityHidden(commentsPresented)
                .animation(nil, value: player.isFullscreen)
        }
    }

    private func detailsPage(
        topInset: CGFloat,
        fadeTopInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: topInset)
                    .id("video-detail-compact-top")
                detailColumn(
                    columnWidth: pageWidth,
                    horizontalInset: 16,
                    showsCommentsCapsule: false,
                    isCompact: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(
                    height: bottomInset
                        + VideoDetailLayoutMetrics.contentBottomPadding
                        + (activeFloatingPlaylistQueue != nil ? 76 : 0)
                )
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                handleCompactDetailScroll(offset)
            }
            .onChange(of: detailScrollToTopTick) { _, _ in
                withAnimation(motion.animation(normal: .easeInOut(duration: 0.28))) {
                    proxy.scrollTo("video-detail-compact-top", anchor: .top)
                }
            }
            .mask { DetailPinnedFadeMask(topInset: fadeTopInset) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func detailColumn(
        columnWidth: CGFloat,
        horizontalInset: CGFloat,
        showsCommentsCapsule: Bool,
        isCompact: Bool
    ) -> some View {
        VideoDetailColumnView(
            model: viewModel,
            requestedVideoID: videoID,
            previewTitle: activeTarget.preview.title,
            previewOwnerName: activeTarget.preview.ownerName,
            columnWidth: columnWidth,
            horizontalInset: horizontalInset,
            showsHeroBar: showsHeroBar,
            showsCommentsCapsule: showsCommentsCapsule,
            stagePresentation: stagePresentation,
            isCompact: isCompact,
            usesCompactPhoneActions: usesCompactPhoneActions,
            isActiveVideoRoute: isActiveVideoRoute,
            isTransitionSettled: isRouteTransitionSettled,
            favoriteRequestInFlight: favoriteRequestInFlight,
            commentPresentation: commentPresentation,
            onHeroBarHeightChange: { height in stageController.updateHeroBarHeight(height, motion: motion) },
            onOpenComments: openComments,
            onPresentFavorite: { activeSheet = .favorite },
            onShareCard: prepareShareCard,
            onSelectMusic: { activeSheet = .music($0) },
            onSelectSeasonEpisode: { episode in
                guard let info = viewModel.videoInfo, let season = info.ugcSeason else { return }
                switchToSeasonEpisodeInline(
                    episode,
                    season: season,
                    fallbackOwnerName: info.owner.name
                )
            },
            onRetry: { Task { await activateIfNeeded(settlesNavigationAdmission: false) } }
        )
    }

    @ViewBuilder
    private var floatingPlaylistCapsuleOverlay: some View {
        if let queue = activeFloatingPlaylistQueue, !isKeyboardDocked {
            VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
                if isWideLayout {
                    let geometry = stageGeometry
                    VideoDetailFloatingPlaylistCapsule(
                        queue: queue,
                        isPlaying: player.isPlaying
                    ) {
                        activeSheet = .playlist
                    }
                    .frame(maxWidth: min(440, max(260, geometry.columnWidth)))
                    .padding(.leading, geometry.columnOriginX)
                    .padding(.trailing, 16)
                    .padding(.bottom, DetailStageLayout.outerMargin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
                } else if !commentsPresented {
                    VideoDetailFloatingPlaylistCapsule(
                        queue: queue,
                        isPlaying: player.isPlaying
                    ) {
                        activeSheet = .playlist
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
                }
            }
            .animation(
                motion.feedbackAnimation(normal: .spring(duration: 0.3)),
                value: queue.currentItem?.id
            )
        }
    }
}
