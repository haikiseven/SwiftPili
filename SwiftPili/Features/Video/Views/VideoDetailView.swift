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

struct VideoDetailView: View {
    enum DetailSheet: Identifiable {
        enum ID: Hashable {
            case report(Int)
            case favorite
            case music(MusicDestination.ID)
            case download(UUID)
        }

        case report(aid: Int)
        case favorite
        case music(MusicDestination)
        case download(DownloadQualityPresentation)

        var id: ID {
            switch self {
            case .report(let aid): .report(aid)
            case .favorite: .favorite
            case .music(let destination): .music(destination.id)
            case .download(let presentation): .download(presentation.id)
            }
        }
    }

    struct VideoShareState {
        var isPresenting = false
        var image: UIImage?
        var requestID: UUID?
        var preparation: Task<Void, Never>?
    }

    final class PageOffsetStore {
        var offsets: [Int: CGFloat] = [:]
    }

    @AppMotion var motion
    let target: VideoRouteTarget
    @State var screenOwner: String
    @State var viewModel = VideoDetailViewModel()

    @State var commentPresentation = CommentZoomPresentation()
    @State var replyPresentation = CommentZoomPresentation()
    @State var composer = VideoCommentComposerState()
    @State var activeSheet: DetailSheet?
    @State var shareState = VideoShareState()
    @State var showThread: CommentThreadTarget?
    @State var commentTargetRpid: Int?
    @State var highlightedCommentRpid: Int?
    @State var previewImages: ImagePreviewItem?
    @State var downloadRequestSerial: UInt64 = 0
    @State var favoriteRequestInFlight = false
    @State var pageOffsetStore = PageOffsetStore()
    @State var lastCondenseFlipAt: CFTimeInterval = 0
    @State var containerMetrics = PlayerDetailContainerMetrics()
    @State var stageController = DetailStageController()
    @State var commentLinkLifetime = ContentLinkLifetime()
    @State var routePosition: PlayerRoutePosition?
    @State var presentationScreenID = UUID()

    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.scenePhase) var scenePhase

    init(target: VideoRouteTarget, routePosition: PlayerRoutePosition? = nil) {
        self.target = target
        _routePosition = State(initialValue: routePosition)
        _screenOwner = State(initialValue: "vod-detail-\(UUID().uuidString)")
    }

    var player: PlayerViewModel { PlayerViewModel.shared }
    var videoID: VideoID { target.videoID }

    var isActiveVideoRoute: Bool {
        coordinator.isActivePlayerRoute(.video(videoID), position: routePosition)
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

    var playerVideoHeight: CGFloat {
        if isWideLayout { return wideVideoSize.height }
        let fallbackBounds = WindowMetricsFallback.currentBounds
        let base = containerWidth > 0 ? containerWidth : min(fallbackBounds.width, fallbackBounds.height)
        let shapeIsCurrent = playerShapeIsCurrent
        return DetailPlayerGeometry.videoHeight(
            containerWidth: base,
            primaryColumnWidth: nil,
            isPortraitContent: DeviceCapability.usesCompactPortraitVideoFraming
                && (shapeIsCurrent ? player.isPortraitContent : metadataPortraitHint),
            isCondensed: shapeIsCurrent && player.inlineCondensed
        )
    }

    private var playerShapeIsCurrent: Bool {
        guard let aid = viewModel.videoInfo?.aid else { return false }
        return player.ownerKey == screenOwner && player.mode == .vod && player.currentAid == aid
    }

    private var metadataPortraitHint: Bool {
        guard DeviceCapability.usesCompactPortraitVideoFraming, let info = viewModel.videoInfo else { return false }
        guard let cid = viewModel.currentCid, cid != info.cid,
              let page = info.pages?.first(where: { $0.cid == cid }) else {
            return info.dimension?.isPortrait ?? false
        }
        return (page.dimension?.isPortrait ?? info.dimension?.isPortrait) ?? false
    }

    private var playerAreaHeight: CGFloat {
        DetailPlayerGeometry.pinnedHeaderHeight(videoHeight: playerVideoHeight, isFullscreen: false)
    }

    private var detailContentTopInset: CGFloat {
        playerAreaHeight + DetailPlayerGeometry.contentTopGap
    }

    private var hostOwnsInlineSurface: Bool {
        PlayerDetailSurfacePolicy.hostOwnsInlineSurface(player: player, lease: viewModel.playerLease)
    }

    private var hasUsableInlinePlayerChrome: Bool {
        guard isActiveVideoRoute, viewModel.error == nil, viewModel.unavailability == nil,
              player.error == nil, player.unavailability == nil,
              player.videoPresentationFailureMessage == nil, player.currentURL != nil,
              let lease = viewModel.playerLease else { return false }
        return player.isCurrentOwner(lease) && player.mode == .vod
            && player.surfaceLease(matching: lease, role: .inline) != nil
    }

    private var presentationContext: PlayerScreenPresentationContext? {
        guard isActiveVideoRoute else { return nil }
        let source: PlayerPresentationSource? = if let aid = viewModel.videoInfo?.aid,
            let cid = viewModel.currentCid {
            .vod(aid: aid, cid: cid, source: .ugc)
        } else {
            nil
        }
        return player.presentationContext(
            screenID: presentationScreenID, lease: viewModel.playerLease,
            route: .video(videoID), position: routePosition,
            source: source
        )
    }

    private var placeholderCoverURL: String? {
        if let pic = viewModel.videoInfo?.pic, !pic.isEmpty { return pic }
        let preview = target.preview.coverSource.desktopURL
        return preview.isEmpty ? nil : preview
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
            pageOwnsInlineNavigation: true
        )
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
        let inlineCornerRadius = showsWideChrome ? DetailStageLayout.playerCornerRadius : 0
        ZStack(alignment: .bottom) {
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

            ZStack(alignment: .topLeading) {
                if isWideLayout {
                    wideContent(bottomInset: pagerBottomInset)
                } else {
                    compactContent()
                }

                inlinePlayerSlot(cornerRadius: inlineCornerRadius)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .frame(minWidth: 0, maxWidth: .infinity)

            if !isWideLayout {
                compactCommentsOverlay
            }

            VideoDetailComposerDismissScrim(
                composer: composer,
                isActive: showsWideChrome && stagePresentation == .stage && showThread == nil,
                ignoresSafeArea: true
            )

            if showsWideChrome {
                ObservedModel(viewModel) { model in
                    wideCommentPanel(model: model, geometry: stageGeometry)
                }
            }

            VideoDetailRootToastView(
                model: viewModel,
                commentPresentation: commentPresentation,
                isWideLayout: isWideLayout,
                showsWideChrome: showsWideChrome,
                stagePresentation: stagePresentation,
                stagePanelWidth: stageGeometry.panelWidth,
                hasActiveThread: showThread != nil
            )
        }
        .playerDetailChrome(
            isFullscreenPresentationActive: player.isFullscreenPresentationActive,
            isStatusBarHidden: player.isFullscreen,
            guardsIPadTopSafeArea: true,
            preventsContentDismissal: isActiveVideoRoute,
            presentationContext: presentationContext,
            coordinator: coordinator
        ) {
            CinematicBackdrop(
                coverURL: placeholderCoverURL,
                player: player,
                ownerLease: viewModel.playerLease,
                isRouteActive: isActiveVideoRoute
            )
        }
        .onChange(of: isActiveVideoRoute, initial: true) { oldActive, active in
            if active {
                _ = claimPlayerLeaseIfNeeded()
            } else {
                cancelSharePreparation()
                downloadRequestSerial &+= 1
                if oldActive {
                    viewModel.revokeLoadForRouteDeparture()
                    player.pauseForRouteDeparture(lease: viewModel.playerLease)
                }
                coordinator.cancelVideoNavigation(videoID)
            }
        }
        .tint(Color.primary)
        .task(id: isActiveVideoRoute) { await activateIfNeeded(settlesNavigationAdmission: true) }
        .onChange(of: coordinator.pendingCommentNavigation?.sequence) { _, _ in
            Task { await handlePendingCommentNavigationIfNeeded() }
        }
        .onDisappear {
            cancelSharePreparation()
            downloadRequestSerial &+= 1
            if case .download = activeSheet { activeSheet = nil }
            if scenePhase == .active, !isActiveVideoRoute {
                coordinator.cancelVideoNavigation(videoID)
            }
            guard scenePhase == .active else {
                PlayerLog.log("[Detail] playback release deferred scenePhase=\(scenePhase)")
                return
            }
            viewModel.releasePlayback()
        }
        .onChange(of: player.fullscreenVODDanmakuSendFailure) { _, _ in
            guard !player.isFullscreen,
                  let message = player.takeFullscreenDanmakuFailure(ownerLease: viewModel.playerLease)
            else { return }
            viewModel.showToast(message, style: .error)
        }
        .modifier(VideoDetailErrorAlertObserver(model: viewModel))
        .imagePreview(item: $previewImages)
        .sheet(item: $activeSheet) { sheet in
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
            }
        }
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

    private func inlinePlayerSlot(cornerRadius: CGFloat) -> some View {
        VStack(spacing: 0) {
            if isActiveVideoRoute {
                if hostOwnsInlineSurface {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(
                            width: isWideLayout ? wideVideoSize.width : nil,
                            height: playerVideoHeight
                        )
                        .frame(maxWidth: isWideLayout ? nil : .infinity)
                } else {
                    PlayerView(
                        owner: screenOwner,
                        surfaceRole: .inline,
                        pageNavigationActions: playerPageNavigation,
                        inlineViewportSize: CGSize(
                            width: isWideLayout ? wideVideoSize.width : containerWidth,
                            height: playerVideoHeight
                        ),
                        inlineCornerRadius: cornerRadius,
                        screenLease: viewModel.playerLease,
                        placeholderCoverURL: placeholderCoverURL,
                        showsLoadingIndicator: viewModel.error == nil && viewModel.unavailability == nil
                    )
                }
            } else {
                RouteActivationPlaceholderView(
                    still: player.outgoingRouteStill(for: screenOwner),
                    coverURL: placeholderCoverURL,
                    height: playerVideoHeight,
                    cornerRadius: cornerRadius
                )
            }
        }
        .background {
            PlayerInlineSlotProbe(cornerRadius: cornerRadius)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: showsWideChrome ? wideVideoSize.width : nil)
        .overlay(alignment: .topLeading) {
            PlayerDetailInlineNavigationOverlay(
                player: player,
                isActiveRoute: isActiveVideoRoute,
                hasInlineExitChrome: { hasUsableInlinePlayerChrome },
                cornerRadius: cornerRadius,
                actions: playerPageNavigation
            )
        }
        .detailStagePlayerPlacement(
            isActive: showsWideChrome, geometry: stageGeometry, presentation: stagePresentation
        )
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DetailPlayerGeometry.headerBottomInset(isFullscreen: false))
    }

    private func wideContent(bottomInset: CGFloat) -> some View {
        let geometry = stageGeometry
        let topInset = DetailStageLayout.contentTopInset(
            playerHeight: geometry.playerSize.height, presentation: stagePresentation
        )
        let isStage = stagePresentation == .stage
        return CinematicStageColumn(
            topInset: topInset,
            fadeGap: DetailStageLayout.contentGap(for: stagePresentation),
            bottomSpacer: bottomInset + VideoDetailLayoutMetrics.contentBottomPadding
                + (isStage ? 0 : wideContainerHeight * 0.35),
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
        let details = detailsPage(topInset: detailContentTopInset, bottomInset: pagerBottomInset)
        return VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            details
                .allowsHitTesting(!commentsPresented)
                .accessibilityHidden(commentsPresented)
                .animation(nil, value: player.isFullscreen)
        }
    }

    private func detailsPage(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        ScrollView {
            Color.clear.frame(height: topInset)
            detailColumn(
                columnWidth: pageWidth,
                horizontalInset: 16,
                showsCommentsCapsule: false,
                isCompact: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: bottomInset + VideoDetailLayoutMetrics.contentBottomPadding)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            -(geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, offset in
            recordPageOffsets([0: offset])
        }
        .mask { DetailPinnedFadeMask(topInset: topInset) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func detailColumn(
        columnWidth: CGFloat,
        horizontalInset: CGFloat,
        showsCommentsCapsule: Bool,
        isCompact: Bool
    ) -> some View {
        VideoDetailColumnView(
            model: viewModel,
            previewTitle: target.preview.title,
            columnWidth: columnWidth,
            horizontalInset: horizontalInset,
            showsHeroBar: showsHeroBar,
            showsCommentsCapsule: showsCommentsCapsule,
            stagePresentation: stagePresentation,
            isCompact: isCompact,
            usesCompactPhoneActions: usesCompactPhoneActions,
            isActiveVideoRoute: isActiveVideoRoute,
            favoriteRequestInFlight: favoriteRequestInFlight,
            commentPresentation: commentPresentation,
            onHeroBarHeightChange: { height in stageController.updateHeroBarHeight(height) },
            onOpenComments: openComments,
            onPresentFavorite: { activeSheet = .favorite },
            onShareCard: prepareShareCard,
            onSelectMusic: { activeSheet = .music($0) },
            onRetry: { Task { await activateIfNeeded(settlesNavigationAdmission: false) } }
        )
    }
}
