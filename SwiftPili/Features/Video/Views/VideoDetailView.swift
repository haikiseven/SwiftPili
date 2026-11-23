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

private struct VideoDetailInlineNavigation: View {
    let player: PlayerViewModel
    let screenLease: PlayerOwnerLease?
    let isActiveVideoRoute: Bool
    let isRouteActivated: Bool
    let isPageAvailable: Bool
    let cornerRadius: CGFloat
    let actions: PlayerPageNavigationActions

    var body: some View {
        if !player.isFullscreenPresentationActive, isActiveVideoRoute {
            let showsNavigation = !hasUsableInlinePlayerChrome || player.showControls
            ZStack(alignment: .topLeading) {
                if showsNavigation && (!isRouteActivated || !player.showControls) {
                    PlayerControlsScrim()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                PlayerPageNavigationButtons(actions: actions)
                    .padding(.horizontal, PlayerPageNavigationButtons.inlineHorizontalPadding)
                    .padding(.top, PlayerPageNavigationButtons.topPadding)
                    .opacity(showsNavigation ? 1 : 0)
                    .allowsHitTesting(showsNavigation)
                    .accessibilityHidden(!showsNavigation)
            }
        }
    }

    private var hasUsableInlinePlayerChrome: Bool {
        guard isRouteActivated, isPageAvailable,
              player.error == nil, player.unavailability == nil,
              player.videoPresentationFailureMessage == nil, player.currentURL != nil,
              let lease = screenLease else { return false }
        return player.isCurrentOwner(lease) && player.mode == .vod
            && player.surfaceLease(matching: lease, role: .inline) != nil
    }
}

struct VideoDetailView: View {
    @AppMotion private var motion
    let target: VideoRouteTarget
    @State private var screenOwner: String
    @State private var activationCoordinator = VideoDetailActivationCoordinator()
    @State private var viewModel = VideoDetailViewModel()
    private enum DetailSheet: Identifiable {
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

    private enum DetailDialog: Equatable {
        case coin
        case descriptionActions
    }

    private struct VideoShareState {
        var isPresenting = false
        var image: UIImage?
        var requestID: UUID?
        var preparation: Task<Void, Never>?
    }

    @State private var commentPresentation = CommentZoomPresentation()
    @State private var replyPresentation = CommentZoomPresentation()
    @State private var composer = VideoCommentComposerState()
    @State private var activeSheet: DetailSheet?
    @State private var activeDialog: DetailDialog?
    @State private var shareState = VideoShareState()
    @State private var showThread: CommentThreadTarget?
    @State private var commentTargetRpid: Int?
    @State private var highlightedCommentRpid: Int?
    @State private var previewImages: ImagePreviewItem?
    @State private var isDescExpanded = false
    @State private var downloadRequestSerial: UInt64 = 0
    @State private var coinRequestInFlight = false
    @State private var favoriteRequestInFlight = false
    @State private var followRequestInFlight = false
    @State private var partPicks = 0
    @State private var pickedPartCid: Int?
    @Namespace private var partIndicator
    private final class PageOffsetStore {
        var offsets: [Int: CGFloat] = [:]
    }

    @State private var pageOffsetStore = PageOffsetStore()
    @State private var lastCondenseFlipAt: CFTimeInterval = 0

    private static var fallbackContainerBounds: CGRect {
        if let bounds = AppWindowMetrics.current?.bounds {
            return bounds
        }
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            if let windowBounds = scene.windows.first(where: { !$0.isHidden })?.bounds {
                return windowBounds
            }
            return scene.coordinateSpace.bounds
        }
        return CGRect(x: 0, y: 0, width: 393, height: 852)
    }

    private var playerVideoHeight: CGFloat {
        if isWideLayout { return wideVideoSize.height }
        let fallbackBounds = Self.fallbackContainerBounds
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
        DetailPlayerGeometry.pinnedHeaderHeight(
            videoHeight: playerVideoHeight, isFullscreen: false
        )
    }
    @State private var containerWidth: CGFloat
    @State private var isWideLayout: Bool
    @State private var usesCompactPhoneActions: Bool
    @State private var wideContainerHeight: CGFloat
    @State private var restingContainerHeight: CGFloat
    @State private var pendingContainerSize: CGSize?
    @State private var isKeyboardDocked = false
    @State private var stage = DetailStageState()
    private var stagePresentation: DetailStagePresentation { stage.presentation }
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.contentLinkContext) private var linkContext
    @State private var commentLinkLifetime = ContentLinkLifetime()
    @State private var pendingCommentLinkContext: ContentLinkContext?

    @State private var routePosition: PlayerRoutePosition?

    init(target: VideoRouteTarget, routePosition: PlayerRoutePosition? = nil) {
        let initialBounds = Self.fallbackContainerBounds
        self.target = target
        _routePosition = State(initialValue: routePosition)
        _screenOwner = State(initialValue: "vod-detail-\(UUID().uuidString)")
        _containerWidth = State(initialValue: initialBounds.width)
        _isWideLayout = State(initialValue: DetailSplitPolicy.usesSplit(
            isPad: DeviceCapability.supportsPadDetailSplit,
            containerSize: initialBounds.size
        ))
        _usesCompactPhoneActions = State(initialValue: DeviceCapability.usesCompactPortraitVideoFraming
            && initialBounds.height >= initialBounds.width)
        _wideContainerHeight = State(initialValue: initialBounds.height)
        _restingContainerHeight = State(initialValue: initialBounds.height)
    }

    private var accent: Color { .biliAccent }
    private var stageGeometry: DetailStageLayout.Geometry {
        DetailStageLayout.geometry(
            for: stagePresentation,
            containerSize: CGSize(width: pageWidth, height: wideContainerHeight),
            heroReserve: heroBarHeight > 0 ? heroBarHeight + DetailStageLayout.heroContentGap : 0
        )
    }
    @State private var heroBarHeight: CGFloat = 0
    private var showsHeroBar: Bool { isWideLayout && stagePresentation == .hero }

    private var wideVideoSize: CGSize { stageGeometry.playerSize }

    private var showsWideChrome: Bool { isWideLayout }
    private var hostOwnsInlineSurface: Bool {
        guard player.isFullscreenPresentationActive,
              let lease = viewModel.playerLease,
              player.isCurrentOwner(lease) else { return false }
        return player.activeSurfaceLease?.ownerLease == lease
            && player.activeSurfaceLease?.role == .fullscreen
    }
    private static var compactCapsuleMinimumWidth: CGFloat { 600 }
    private static var phoneShelfCardWidth: CGFloat { 220 }

    private func setStagePresentation(_ next: DetailStagePresentation) {
        guard isWideLayout, stagePresentation != next else { return }
        withAnimation(motion.animation(normal: .spring(duration: 0.45, bounce: 0.12))) {
            _ = stage.set(next)
        }
    }

    private func handleStageScroll(_ offset: CGFloat) {
        guard showsWideChrome, let next = stage.target(forScrollOffset: offset) else { return }
        PlayerLog.log("[Stage] \(stagePresentation) → \(next) offset=\(Int(offset))")
        setStagePresentation(next)
    }

    @State private var presentationScreenID = UUID()
    private var player: PlayerViewModel { PlayerViewModel.shared }
    private var presentationContext: PlayerScreenPresentationContext? {
        guard isRouteActivated else { return nil }
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
    private var videoID: VideoID { target.videoID }

    private var isActiveVideoRoute: Bool {
        coordinator.isActivePlayerRoute(.video(videoID), position: routePosition)
    }

    private var isRouteActivated: Bool {
        activationCoordinator.admits(routeIsActive: isActiveVideoRoute)
    }

    private var placeholderCoverURL: String? {
        if let pic = viewModel.videoInfo?.pic, !pic.isEmpty { return pic }
        let preview = target.preview.coverSource.desktopURL
        return preview.isEmpty ? nil : preview
    }

    private var detailContentTopInset: CGFloat {
        playerAreaHeight + DetailPlayerGeometry.contentTopGap
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

    private var pageWidth: CGFloat {
        containerWidth > 0 ? containerWidth : Self.fallbackContainerBounds.width
    }

    private var pagerBottomInset: CGFloat {
        AppWindowMetrics.safeAreaInsets.bottom
    }

    var body: some View {
        let _ = UIHitchMonitor.countBody("detail")
        let inlineCornerRadius = showsWideChrome ? DetailStageLayout.playerCornerRadius : 0
        ZStack(alignment: .bottom) {
            containerGeometryProbes

            ZStack(alignment: .topLeading) {
                if isWideLayout {
                    wideContent(bottomInset: pagerBottomInset)
                } else {
                    compactContent()
                }

                VStack(spacing: 0) {
                    if isRouteActivated {
                        if hostOwnsInlineSurface {
                            RoundedRectangle(cornerRadius: inlineCornerRadius, style: .continuous)
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
                                inlineCornerRadius: inlineCornerRadius,
                                screenLease: viewModel.playerLease
                            )
                        }
                    } else {
                        RouteActivationPlaceholderView(
                            still: player.outgoingRouteStill(for: screenOwner),
                            coverURL: placeholderCoverURL,
                            height: playerVideoHeight,
                            cornerRadius: inlineCornerRadius
                        )
                    }
                }
                .background {
                    PlayerInlineSlotProbe(cornerRadius: inlineCornerRadius)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(width: showsWideChrome ? wideVideoSize.width : nil)
                .overlay(alignment: .topLeading) {
                    VideoDetailInlineNavigation(
                        player: player,
                        screenLease: viewModel.playerLease,
                        isActiveVideoRoute: isActiveVideoRoute,
                        isRouteActivated: isRouteActivated,
                        isPageAvailable: viewModel.error == nil && viewModel.unavailability == nil,
                        cornerRadius: inlineCornerRadius,
                        actions: playerPageNavigation
                    )
                }
                .detailStagePlayerPlacement(
                    isActive: showsWideChrome, geometry: stageGeometry, presentation: stagePresentation
                )
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DetailPlayerGeometry.headerBottomInset(isFullscreen: false))
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

            rootCommentToast
        }
        .allowsHitTesting(!player.isFullscreenPresentationActive)
        .accessibilityHidden(player.isFullscreenPresentationActive)
        .onChange(of: player.isFullscreenPresentationActive) { _, active in
            guard !active, let pending = pendingContainerSize else { return }
            pendingContainerSize = nil
            updateContainerGeometry(pending)
        }
        .guardIPadTopSafeArea(when: true)
        .background {
            CinematicBackdrop(
                coverURL: placeholderCoverURL,
                player: player,
                ownerLease: viewModel.playerLease,
                isRouteActive: isRouteActivated && isActiveVideoRoute
            )
        }
        .appSurface(.cinematic)
        .background(alignment: .topLeading) {
            if let presentationContext {
                PlayerFullscreenHost(context: presentationContext, navigation: coordinator)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .keepsInteractivePopGesture()
        .preventsVideoDetailContentDismissal(isActive: isActiveVideoRoute)
        .routeAppearanceProbe { event in
            activationCoordinator.handleAppearance(event, owner: screenOwner)
        }
        .onChange(of: isActiveVideoRoute, initial: true) { _, active in
            if !active {
                cancelSharePreparation()
                downloadRequestSerial &+= 1
            }
            activationCoordinator.handleRouteActivity(
                active, owner: screenOwner, route: activationRouteRead, ports: activationPorts
            )
        }
        .tint(Color.primary)
        .task(id: isRouteActivated) { await activateIfNeeded() }
        .onChange(of: coordinator.pendingCommentNavigation?.sequence) { _, _ in
            Task { await handlePendingCommentNavigationIfNeeded() }
        }
        .freezeWatchdogScreen("VideoDetail")
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
        .statusBarHidden(player.isFullscreen)
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
            if let showThread, showThread.type != 1 || showThread.oid != source?.aid || composer.replyCommentSource != source {
                commentPresentation.cancelPendingAction()
                replyPresentation.cancelPendingAction()
                replyPresentation.isPresented = false
                self.showThread = nil
                composer.replyCommentSource = nil
                replyPresentation.anchors.sourceProvider = nil
            }
        })
    }

    @ViewBuilder
    private var containerGeometryProbes: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                updateContainerGeometry(size)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

        if isWideLayout {
            let restingHeight = restingContainerHeight
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onGeometryChange(for: Bool.self) { proxy in
                    let safeHeight = proxy.size.height
                    guard restingHeight.isFinite, restingHeight > 0,
                          safeHeight.isFinite, safeHeight > 0 else { return false }
                    return (restingHeight - safeHeight) > 40
                } action: { docked in
                    if isKeyboardDocked != docked { isKeyboardDocked = docked }
                }
        }
    }

    private func updateContainerGeometry(_ size: CGSize) {
        UIHitchMonitor.count("geom")
        if DeviceCapability.supportsOrientationLock, player.isFullscreenPresentationActive {
            pendingContainerSize = size
            return
        }
        if size.width.isFinite, size.width > 0, containerWidth != size.width {
            containerWidth = size.width
        }
        let wide = DetailSplitPolicy.usesSplit(
            isPad: DeviceCapability.supportsPadDetailSplit,
            containerSize: size
        )
        if isWideLayout != wide { isWideLayout = wide }
        if !wide, isKeyboardDocked { isKeyboardDocked = false }
        if size.height.isFinite, size.height > 0, restingContainerHeight != size.height {
            restingContainerHeight = size.height
        }
        if wide, wideContainerHeight != size.height { wideContainerHeight = size.height }
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            let compactPhone = DeviceCapability.usesCompactPortraitVideoFraming && size.height >= size.width
            if usesCompactPhoneActions != compactPhone { usesCompactPhoneActions = compactPhone }
        }
    }

    private var rootCommentToast: some View {
        VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            let handledByWidePanel = showsWideChrome && stagePresentation == .stage && showThread == nil
            let handledByCompactOverlay = !isWideLayout && commentsPresented
            Group {
                if !handledByWidePanel, !handledByCompactOverlay,
                   isWideLayout || !commentsPresented, let toast = viewModel.toast {
                    ToastView(message: toast)
                }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: viewModel.toast)
            .frame(maxWidth: showsWideChrome ? stageGeometry.panelWidth : .infinity)
            .padding(.trailing, showsWideChrome ? DetailStageLayout.outerMargin : 0)
            .padding(.bottom, showsWideChrome ? DetailStageLayout.outerMargin : 0)
            .frame(maxWidth: .infinity, alignment: showsWideChrome ? .trailing : .center)
        }
    }

    private func dialogBinding(_ dialog: DetailDialog) -> Binding<Bool> {
        Binding(
            get: { activeDialog == dialog },
            set: { isPresented in
                if !isPresented, activeDialog == dialog {
                    activeDialog = nil
                }
            }
        )
    }

    private func commentFeedbackAndComposer(isCompactOverlay: Bool) -> some View {
        let model = viewModel
        let requestedID = videoID
        return VideoDetailCommentComposerOverlay(
            composer: composer,
            model: model,
            commentPresentation: commentPresentation,
            requestedVideoID: requestedID,
            isCompactOverlay: isCompactOverlay,
            showsWideChrome: showsWideChrome,
            isWideLayout: isWideLayout,
            stagePresentation: stagePresentation,
            hasActiveThread: showThread != nil,
            isInlineCommentInputEligible: isInlineCommentInputEligible,
            isModelCurrent: { viewModel === model && videoID == requestedID },
            onRevealPostedComment: { postedRpid, target, model, sourceIsCurrent in
                revealAcceptedComment(
                    postedRpid,
                    replyingTo: target,
                    model: model,
                    sourceIsCurrent: sourceIsCurrent
                )
            }
        )
    }

    private var isInlineCommentInputEligible: Bool {
        AuthManager.shared.isLoggedIn && !viewModel.commentsClosed
    }

    private func statsLine(_ info: VideoInfo) -> some View {
        HStack(spacing: 10) {
            Text("\(FormatUtils.viewCount(info.stat.view)) plays")
            Text("\(FormatUtils.viewCount(info.stat.danmaku)) danmaku")
            if let online = viewModel.onlineCount, !online.isEmpty {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                    Text("\(online) watching")
                }
            }
            Spacer()
            Text(FormatUtils.timeAgo(from: info.pubdate))
        }
        .appFont(.screenStat)
        .foregroundStyle(.secondary)
    }

    private func descriptionBlock(_ info: VideoInfo) -> some View {
        let hasDesc = !info.desc.isEmpty && info.desc != "-"
        return VStack(alignment: .leading, spacing: 10) {
            if hasDesc {
                EmoteText.linkified(
                    info.desc, links: info.descLinks, accent: .biliAccent
                )
                    .appFont(.screenSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                            isDescExpanded.toggle()
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        activeDialog = .descriptionActions
                    }
                    .confirmationDialog(
                        "", isPresented: dialogBinding(.descriptionActions), titleVisibility: .hidden
                    ) {
                        Button {
                            UIPasteboard.general.string = info.desc
                        } label: {
                            Text("Copy Description")
                        }
                    }
            }

            if !viewModel.tags.isEmpty {
                descriptionTags
            }
        }
    }

    private func ownerRow(_ info: VideoInfo, fillsWidth: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarImage(urlString: info.owner.face, size: 36)

            Text(info.owner.name)
                .appFont(.screenOwner)
                .fontWeight(.medium)
                .lineLimit(fillsWidth ? nil : 1)

            if fillsWidth { Spacer() }

            if let following = viewModel.isFollowingUp {
                Button {
                    Task {
                        followRequestInFlight = true
                        await viewModel.toggleFollowUp()
                        followRequestInFlight = false
                    }
                } label: {
                    (following ? Text("Following") : Text("+ Follow"))
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(following ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            following
                                ? AnyShapeStyle(Color(.tertiarySystemFill))
                                : AnyShapeStyle(Color.biliAccent),
                            in: Capsule()
                        )
                        .appStateLabelFeedback(isOn: following, userActionInFlight: followRequestInFlight)
                }
                .buttonStyle(.appControl)
                .disabled(followRequestInFlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.navigate(to: .userSpace(info.owner.mid))
        }
    }

    private func partsSelector(
        _ pages: [VideoInfo.VideoPage], horizontalInset: CGFloat = 16
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Parts", count: pages.count)
                .padding(.horizontal, horizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pages, id: \.cid) { page in
                        let selected = page.cid == (pickedPartCid ?? viewModel.currentCid)
                        PlaybackEntryChip(
                            label: "P\(page.page)",
                            detail: FormatUtils.duration(page.duration),
                            title: page.part,
                            isSelected: selected,
                            indicator: partIndicator
                        ) {
                            guard !selected else { return }
                            partPicks &+= 1
                            pickPart(page)
                        }
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
        }
        .padding(.bottom, 6)
        .appSelectionHaptic(userPicks: partPicks)
    }

    private func pickPart(_ page: VideoInfo.VideoPage) {
        let start = {
            guard pickedPartCid == page.cid else { return }
            Task {
                await viewModel.switchPage(page)
                if pickedPartCid == page.cid { pickedPartCid = nil }
            }
        }
        guard let animation = motion.animation(normal: .snappy(duration: 0.24)) else {
            pickedPartCid = page.cid
            start()
            return
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            pickedPartCid = page.cid
        } completion: {
            start()
        }
    }

    @ViewBuilder
    private func actionButtons(_ info: VideoInfo, compact: Bool = false) -> some View {
        DetailActionButton(
            icon: viewModel.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
            label: FormatUtils.viewCount(info.stat.like),
            isActive: viewModel.isLiked,
            count: info.stat.like,
            compact: compact,
            accessibilityTitle: "Like"
        ) {
            await viewModel.toggleLike()
        }
        DetailActionButton(
            icon: viewModel.isCoined ? "b.circle.fill" : "b.circle",
            label: FormatUtils.viewCount(info.stat.coin),
            isActive: viewModel.isCoined,
            count: info.stat.coin,
            externalActionInFlight: coinRequestInFlight,
            compact: compact,
            accessibilityTitle: "Coin"
        ) {
            if viewModel.maxCoins - viewModel.coinCount >= 2 {
                activeDialog = .coin
            } else {
                await viewModel.addCoin(multiply: 1)
            }
        }
        .confirmationDialog("Coin this video", isPresented: dialogBinding(.coin), titleVisibility: .visible) {
            Button("Give 1 Coin") { addCoinFromDialog(1) }
            Button("Give 2 Coins") { addCoinFromDialog(2) }
        }
        DetailActionButton(
            icon: viewModel.isFavorited ? "star.fill" : "star",
            label: FormatUtils.viewCount(info.stat.favorite),
            isActive: viewModel.isFavorited,
            count: info.stat.favorite,
            externalActionInFlight: favoriteRequestInFlight,
            compact: compact,
            accessibilityTitle: "Favorite"
        ) {
            await viewModel.loadFavFolders()
            activeSheet = .favorite
        }
        DetailActionButton(
            icon: viewModel.isInWatchLater ? "clock.fill" : "clock",
            label: String(localized: "Watch"),
            isActive: viewModel.isInWatchLater,
            compact: compact,
            showsCaption: !compact,
            accessibilityTitle: "Watch Later"
        ) {
            await viewModel.toggleWatchLater()
        }
        shareMenu(info, compact: compact)
    }

    private func addCoinFromDialog(_ coins: Int) {
        Task {
            coinRequestInFlight = true
            await viewModel.addCoin(multiply: coins)
            coinRequestInFlight = false
        }
    }

    private func shareMenu(_ info: VideoInfo, compact: Bool = false) -> some View {
        Menu {
            Button {
                prepareShareCard(info)
            } label: {
                Label("System Share", systemImage: "square.and.arrow.up")
            }

            Button {
                UIPasteboard.general.string = "https://www.bilibili.com/video/\(info.bvid)"
                Task { await viewModel.shareVideo() }
            } label: {
                Label("Copy Link", systemImage: "link")
            }

            Button {
                UIPasteboard.general.string = info.bvid
            } label: {
                Label("Copy BV ID", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = String(info.aid)
            } label: {
                Label("Copy AV ID", systemImage: "number")
            }
        } label: {
            DetailActionButtonLabel(
                compact: compact,
                compactIconOnly: false,
                isActive: viewModel.hasShared
            ) {
                Image(systemName: viewModel.hasShared ? "arrowshape.turn.up.right.fill" : "arrowshape.turn.up.right")
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(Color.primary)
            } caption: {
                Text(FormatUtils.viewCount(info.stat.share))
                    .appFont(.controlLabel)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityLabel(Text("Share"))
        .accessibilityValue(Text(info.stat.share, format: .number))
    }

    private func offerDownload(_ info: VideoInfo) {
        let cid = viewModel.currentCid ?? info.cid
        if let existing = DownloadManager.shared.existing(bvid: info.bvid, cid: cid) {
            if existing.filesExist {
                viewModel.showToast(String(localized: "Already downloaded"), style: .success)
                return
            }
            guard DownloadManager.shared.delete(existing) else {
                viewModel.showToast(String(localized: "Download is being exported"), style: .progress)
                return
            }
        }
        if DownloadManager.shared.isActive(bvid: info.bvid, cid: cid) {
            viewModel.showToast(String(localized: "Download in progress"), style: .progress)
            return
        }
        let isImmediate = DownloadManager.shared.hasImmediateQualityList(
            aid: info.aid, cid: cid
        )
        if !isImmediate {
            viewModel.showToast(String(localized: "Preparing…"), style: .progress)
        }
        downloadRequestSerial &+= 1
        let serial = downloadRequestSerial
        Task {
            do {
                let qualities = try await DownloadManager.shared.availableQualities(
                    aid: info.aid, cid: cid
                )
                guard !Task.isCancelled,
                      downloadRequestSerial == serial,
                      viewModel.videoInfo?.aid == info.aid,
                      (viewModel.currentCid ?? viewModel.videoInfo?.cid) == cid
                else { return }
                activeSheet = .download(DownloadQualityPresentation(
                    info: info, cid: cid, qualities: qualities
                ))
            } catch {
                guard !Task.isCancelled, downloadRequestSerial == serial else { return }
                viewModel.showToast(error.localizedDescription, style: .error)
            }
        }
    }

    private func shareItems(for info: VideoInfo) -> [Any] {
        if let shareImage = shareState.image { return [shareImage] }
        if let url = URL(string: "https://www.bilibili.com/video/\(info.bvid)") { return [url] }
        return [info.title]
    }

    private func prepareShareCard(_ info: VideoInfo) {
        guard shareState.requestID == nil, !shareState.isPresenting, isRouteActivated else { return }
        let id = UUID()
        let model = viewModel
        let request = ShareCardRenderer.Request(
            coverURL: info.pic, title: info.title, uploader: info.owner.name, description: info.desc,
            linkURL: "https://www.bilibili.com/video/\(info.bvid)",
            linkDisplay: "bilibili.com/video/\(info.bvid)",
            accent: UIColor(Color.biliAccent).resolvedColor(with: UITraitCollection.current)
        )
        shareState.requestID = id
        shareState.preparation = Task {
            defer {
                if shareState.requestID == id {
                    shareState.requestID = nil
                    shareState.preparation = nil
                }
            }
            guard let image = try? await ShareCardRenderer.prepare(request),
                  !Task.isCancelled, shareState.requestID == id,
                  isRouteActivated, viewModel === model, model.videoInfo?.bvid == info.bvid else { return }
            shareState.image = image
            shareState.isPresenting = true
            ActivitySharePresenter.present(items: shareItems(for: info)) { completed in
                shareState.isPresenting = false
                guard completed else { return }
                Task { await viewModel.shareVideo() }
            }
        }
    }

    private func cancelSharePreparation() {
        shareState.preparation?.cancel()
        shareState.preparation = nil
        shareState.requestID = nil
    }

    private func startDownload(_ info: VideoInfo, cid: Int, quality: Int) {
        let duration = info.pages?.first(where: { $0.cid == cid })?.duration ?? info.duration
        viewModel.showToast(String(localized: "Download started"), style: .progress)
        Task {
            await DownloadManager.shared.startDownload(
                aid: info.aid, cid: cid, bvid: info.bvid, title: info.title,
                coverURL: info.pic, ownerName: info.owner.name,
                durationSeconds: duration, quality: quality
            )
        }
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

    private var compactCommentsOverlay: some View {
        CommentZoomContainer(
            presentation: commentPresentation,
            destination: commentsSurface(bottomInset: pagerBottomInset),
            onPresentationChanged: { isPresented in
                if isPresented { updatePlayerCondensation() }
                if !isPresented {
                    composer.collapse(motion: motion)
                }
            },
            allowsInteractiveDismissal: showThread == nil,
            onDismissed: resetCommentThreadAfterModalDismissal
        )
        .padding(.top, playerAreaHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func openComments() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        if isWideLayout { setStagePresentation(.stage) }
        commentPresentation.isPresented = true
        if showThread != nil { replyPresentation.isPresented = true }
    }

    private func closeComments() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        composer.collapse(motion: motion)
        if commentPresentation.isPresented {
            commentPresentation.isPresented = false
        } else {
            let threadID = showThread?.id
            replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
        }
    }

    private func resetCommentThreadAfterModalDismissal() {
        guard !commentPresentation.isPresented else { return }
        updatePlayerCondensation()
        replyPresentation.cancelPendingAction()
        replyPresentation.isPresented = false
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    private func openCommentThread(_ target: CommentThreadTarget) {
        guard let source = viewModel.currentCommentSource,
              source.aid == target.oid, target.type == 1 else { return }
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        commentLinkLifetime.invalidate()
        coordinator.contentLinks.cancel()
        composer.collapse(motion: motion)
        replyPresentation.anchors.sourceProvider = { nil }
        composer.replyCommentSource = source
        showThread = target
        replyPresentation.isPresented = true
    }

    private func closeCommentThread() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        let threadID = showThread?.id
        replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
    }

    private func finishCommentThreadDismissal(_ threadID: CommentThreadTarget.Identity?) {
        guard !replyPresentation.isPresented, showThread?.id == threadID else { return }
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    private func openCommentThreadURL(
        _ url: URL, context: ContentLinkContext, target: CommentThreadTarget
    ) -> OpenURLAction.Result {
        guard let origin = coordinator.contentLinkOrigin(context) else { return .discarded }
        coordinator.contentLinks.open(url, context: origin) { route in
            origin.beforeNavigate()
            navigateFromCommentThread(to: route, target: target)
        }
        return .handled
    }

    private func navigateFromCommentThread(to route: Route, target: CommentThreadTarget) {
        let model = viewModel
        let requestedID = videoID
        guard isActiveVideoRoute, replyPresentation.isPresented, showThread?.id == target.id,
              let source = model.currentCommentSource, source == composer.replyCommentSource,
              source.aid == target.oid, target.type == 1,
              model.hasCommentSource(for: requestedID) else { return }
        let navigationRevision = coordinator.contentLinkNavigationRevision
        let accountRevision = AccountManager.shared.identityRevision
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        composer.collapse(motion: motion)
        replyPresentation.dismissThenPerform {
            finishCommentThreadDismissal(target.id)
            commentPresentation.dismissThenPerform {
                guard isActiveVideoRoute, viewModel === model, videoID == requestedID,
                      model.currentCommentSource == source, model.hasCommentSource(for: requestedID),
                      coordinator.contentLinkNavigationRevision == navigationRevision,
                      AccountManager.shared.identityRevision == accountRevision else { return }
                coordinator.navigate(to: route)
            }
        }
    }

    private var activationRouteRead: VideoDetailActivationCoordinator.RouteRead {
        .init(isActive: { isActiveVideoRoute }, currentVideoID: { videoID })
    }

    private var activationPorts: VideoDetailActivationCoordinator.Ports {
        .init(model: viewModel, player: player, navigation: coordinator)
    }

    private func activateIfNeeded() async {
        guard activationCoordinator.beginRoute(
            owner: screenOwner, route: activationRouteRead, ports: activationPorts
        ) else { return }
        await activationCoordinator.activate(
            owner: screenOwner, route: activationRouteRead, ports: activationPorts,
            settlesNavigationAdmission: true
        )
        await handlePendingCommentNavigationIfNeeded()
    }

    private func handlePendingCommentNavigationIfNeeded() async {
        let model = viewModel
        let requestedID = videoID
        let sourceGeneration = model.commentSourceGeneration
        guard isActiveVideoRoute,
              let request = coordinator.pendingCommentNavigation,
              request.anchor.videoID == requestedID,
              model.videoInfo != nil else { return }

        while model.commentsAwaitingInitialResponse,
              viewModel === model, videoID == requestedID,
              model.commentSourceGeneration == sourceGeneration,
              isActiveVideoRoute, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, isActiveVideoRoute, viewModel === model,
              videoID == requestedID, model.commentSourceGeneration == sourceGeneration,
              model.hasCommentSource(for: requestedID),
              coordinator.consumeCommentNavigation(request, for: requestedID) else { return }

        openComments()
        let anchor = request.anchor
        let rootRpid = anchor.rootRpid ?? anchor.rpid
        let location = await model.locateComment(rpid: rootRpid)
        guard !Task.isCancelled, isActiveVideoRoute, viewModel === model,
              videoID == requestedID, model.commentSourceGeneration == sourceGeneration,
              model.hasCommentSource(for: requestedID),
              model.isCurrentCommentLocation(location) else { return }
        guard case .found(let intent) = location,
              let root = model.comments.first(where: { $0.rpid == rootRpid }) else {
            model.showToast(String(localized: "Comment is unavailable"), style: .error)
            return
        }
        if anchor.isNestedReply {
            openCommentThread(CommentThreadTarget(
                oid: intent.receipt.source.aid, type: 1, root: root, highlightRpid: anchor.rpid
            ))
        } else {
            commentTargetRpid = anchor.rpid
        }
    }

    private func relatedRouteTarget(_ video: VideoCard) -> VideoRouteTarget {
        VideoRouteTarget.make(
            bvid: video.bvid,
            aid: nil,
            title: video.title,
            coverURL: video.pic,
            mobileCoverURL: video.mobileCoverURL,
            ownerName: video.owner.name,
            durationSeconds: video.duration
        ) ?? VideoRouteTarget(videoID: .bvid(video.bvid))
    }

    private func recordPageOffsets(_ offsets: [Int: CGFloat]) {
        pageOffsetStore.offsets.merge(offsets) { _, new in new }
        updatePlayerCondensation()
    }

    private func updatePlayerCondensation() {
        guard !isWideLayout, player.isPortraitContent, !player.isFullscreenPresentationActive,
              player.ownerKey == screenOwner else { return }
        if player.portraitCondenseLocked { return }
        let now = CACurrentMediaTime()
        guard now - lastCondenseFlipAt > 0.4 else { return }
        let offset = pageOffsetStore.offsets[commentPresentation.isPresented ? 1 : 0] ?? 0
        let shouldCondense = PortraitVODCondensationPolicy.shouldAutoCollapse(
            offset: offset,
            isCondensed: player.inlineCondensed,
            hasManualChoice: player.portraitCondenseLocked
        )
        guard shouldCondense else { return }
        lastCondenseFlipAt = now
        PlayerLog.log(
            "[condense] auto-collapse "
            + "offset=\(Int(offset)) threshold=\(Int(PortraitVODCondensationPolicy.collapseThreshold)) "
            + "condensed=\(player.inlineCondensed)→\(shouldCondense) "
            + "locked=\(player.portraitCondenseLocked)"
        )
        withAnimation(motion.animation(normal: .spring(duration: 0.3))) {
            player.inlineCondensed = shouldCondense
        }
    }

    @ViewBuilder
    private func unavailableState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: viewModel.unavailability?.symbolName
                ?? "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if viewModel.unavailability?.isRetryable ?? true {
                Button {
                    Task {
                        await activationCoordinator.activate(
                            owner: screenOwner, route: activationRouteRead, ports: activationPorts
                        )
                    }
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(accent.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.appControl)
                .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static var wideHeaderSingleRowWidth: CGFloat { 900 }
    private static var cinematicTextInset: CGFloat { 4 }
    private static var shelfCardWidth: CGFloat { 280 }
    private static var panelComposerClearance: CGFloat { 84 }
    private static var contentBottomPadding: CGFloat { 24 }

    private func wideContent(bottomInset: CGFloat) -> some View {
        ObservedModel(viewModel) { model in
            wideContentBody(bottomInset: bottomInset, model: model)
        }
    }

    private func wideContentBody(
        bottomInset: CGFloat, model: VideoDetailViewModel
    ) -> some View {
        let geometry = stageGeometry
        let topInset = DetailStageLayout.contentTopInset(
            playerHeight: geometry.playerSize.height, presentation: stagePresentation
        )
        let isStage = stagePresentation == .stage
        return CinematicStageColumn(
            topInset: topInset,
            fadeGap: DetailStageLayout.contentGap(for: stagePresentation),
            bottomSpacer: bottomInset + Self.contentBottomPadding
                + (isStage ? 0 : wideContainerHeight * 0.35),
            onOffset: handleStageScroll
        ) {
            cinematicColumn(
                model: model, columnWidth: geometry.columnWidth,
                horizontalInset: stagePresentation == .hero
                    ? geometry.playerOriginX : Self.cinematicTextInset
            )
            .frame(width: geometry.columnWidth, alignment: .leading)
            .padding(.leading, geometry.columnOriginX)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func cinematicColumn(
        model: VideoDetailViewModel,
        columnWidth: CGFloat,
        horizontalInset: CGFloat = Self.cinematicTextInset,
        showsCommentsCapsule: Bool = true,
        isCompact: Bool = false
    ) -> some View {
        let info = model.videoInfo
        let inset = horizontalInset
        if info != nil || viewModel.isLoading || viewModel.error == nil {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeroBar, let info {
                    heroBar(info, columnWidth: columnWidth, horizontalInset: inset)
                    statsLine(info)
                        .padding(.horizontal, inset)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        titleHeader(info: info, horizontalInset: inset)
                        if let info {
                            statsLine(info)
                                .padding(.horizontal, inset)
                        }
                    }
                    if let info {
                        cinematicCreatorAndActions(
                            info, columnWidth: columnWidth,
                            showsCommentsCapsule: showsCommentsCapsule, horizontalInset: inset
                        )
                    }
                }

                if let info {
                    let hasDesc = !info.desc.isEmpty && info.desc != "-"
                    if isDescExpanded, hasDesc || !viewModel.tags.isEmpty {
                        descriptionBlock(info)
                            .padding(.horizontal, inset)
                            .transition(motion.transition(normal: .opacity))
                    }
                    if let pages = info.pages, pages.count > 1 {
                        partsSelector(pages, horizontalInset: inset)
                    }
                    if isCompact {
                        hotCommentsPreviewCard(info, model: model)
                            .padding(.horizontal, inset)
                    }
                    if !model.relatedVideos.isEmpty {
                        if isCompact {
                            relatedVideosGrid(model: model, columnWidth: columnWidth, horizontalInset: inset)
                        } else {
                            UpNextShelf(
                                title: "Related",
                                videos: model.relatedVideos,
                                cardWidth: columnWidth >= Self.compactCapsuleMinimumWidth
                                    ? Self.shelfCardWidth : Self.phoneShelfCardWidth,
                                leadingInset: 0,
                                target: relatedRouteTarget,
                                clipsContent: true
                            )
                            .padding(.horizontal, inset)
                            .padding(.top, 4)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
        } else if let message = viewModel.error {
            unavailableState(message)
        }
    }

    private func titleHeader(
        info: VideoInfo?, horizontalInset: CGFloat, fixedLineLimit: Int? = nil
    ) -> some View {
        let titleText = info?.title ?? target.preview.title
        let hasDesc = info.map { !$0.desc.isEmpty && $0.desc != "-" } ?? false
        let canExpand = info != nil && (hasDesc || !viewModel.tags.isEmpty || !titleText.isEmpty)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titleText)
                .appFont(.editorialTitle)
                .fontWeight(.bold)
                .lineLimit(fixedLineLimit ?? (isDescExpanded ? nil : 2))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canExpand {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .appDisclosureRotation(isExpanded: isDescExpanded)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canExpand else { return }
            withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                isDescExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canExpand ? .isButton : [])
        .accessibilityHint(
            canExpand
                ? (isDescExpanded ? Text("Show Less") : Text("Show More"))
                : Text("")
        )
        .padding(.horizontal, horizontalInset)
    }

    @ViewBuilder
    private func hotCommentsPreviewCard(_ info: VideoInfo, model: VideoDetailViewModel) -> some View {
        if !model.commentsClosed {
            CommentZoomSource(anchors: commentPresentation.anchors) {
                HotCommentsPreviewCard(
                    comments: Array(model.comments.prefix(2)),
                    total: info.stat.reply,
                    isLoading: model.isLoadingComments || model.commentsAwaitingInitialResponse,
                    isRegularWidth: sizeClass == .regular,
                    action: openComments
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relatedVideosGrid(
        model: VideoDetailViewModel, columnWidth: CGFloat, horizontalInset: CGFloat
    ) -> some View {
        let columnCount = columnWidth >= Self.compactCapsuleMinimumWidth ? 3 : 2
        let cardColumnWidth = FeedColumnPolicy.columnWidth(
            availableWidth: max(0, columnWidth - horizontalInset * 2),
            count: columnCount,
            spacing: 12
        )
        return VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Related")
                .padding(.horizontal, horizontalInset)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount),
                spacing: 12
            ) {
                ForEach(model.relatedVideos) { video in
                    VideoNavigationButton(target: relatedRouteTarget(video)) {
                        GridVideoCardView(
                            title: video.title,
                            sources: VideoCoverSources(widescreen: video.pic, fourByThree: video.mobileCoverURL),
                            duration: video.duration,
                            ownerName: video.owner.name,
                            viewCount: video.stat.view,
                            explicitColumnWidth: cardColumnWidth
                        )
                        .equatable()
                    }
                }
            }
            .rowCardColumnWidth(cardColumnWidth)
            .padding(.horizontal, horizontalInset)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func cinematicCreatorAndActions(
        _ info: VideoInfo,
        columnWidth: CGFloat,
        showsCommentsCapsule: Bool = true,
        horizontalInset: CGFloat
    ) -> some View {
        if usesCompactPhoneActions {
            VStack(alignment: .leading, spacing: 12) {
                ownerRow(info, fillsWidth: true)
                HStack(spacing: 6) { actionButtons(info, compact: true) }
            }
            .padding(.horizontal, horizontalInset)
        } else if columnWidth >= Self.wideHeaderSingleRowWidth {
            HStack(spacing: 12) {
                ownerRow(info, fillsWidth: false)
                Spacer(minLength: 0)
                if showsCommentsCapsule { heroCommentsCapsule(info) }
                HStack(spacing: 8) { actionButtons(info) }
            }
            .padding(.horizontal, horizontalInset)
        } else if columnWidth >= Self.compactCapsuleMinimumWidth {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ownerRow(info, fillsWidth: false)
                    Spacer(minLength: 0)
                    if showsCommentsCapsule { heroCommentsCapsule(info) }
                }
                HStack(spacing: 8) { actionButtons(info) }
            }
            .padding(.horizontal, horizontalInset)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ownerRow(info, fillsWidth: true)
                    .padding(.horizontal, horizontalInset)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { actionButtons(info) }
                        .padding(.horizontal, horizontalInset)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func heroBar(_ info: VideoInfo, columnWidth: CGFloat, horizontalInset: CGFloat) -> some View {
        CinematicHeroBar {
            titleHeader(info: info, horizontalInset: 0, fixedLineLimit: 1)
        } leading: {
            ownerRow(info, fillsWidth: false)
        } trailing: {
            let actions = HStack(spacing: 8) {
                heroCommentsCapsule(info)
                actionButtons(info)
            }
            if columnWidth >= Self.wideHeaderSingleRowWidth {
                actions
            } else {
                ScrollView(.horizontal, showsIndicators: false) { actions }
                    .scrollClipDisabled()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if height.isFinite, height > 0, abs(height - heroBarHeight) >= 1 { heroBarHeight = height }
        }
        .padding(.horizontal, horizontalInset)
    }

    @ViewBuilder
    private func heroCommentsCapsule(_ info: VideoInfo) -> some View {
        if stagePresentation == .hero, !viewModel.commentsClosed {
            Button(action: openComments) {
                DetailActionButtonLabel {
                    Image(systemName: "text.bubble")
                        .font(.body)
                } caption: {
                    Text(FormatUtils.viewCount(info.stat.reply))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Comments"))
            .transition(.opacity)
        }
    }

    private func commentReplyRegion<Main: View>(@ViewBuilder root: () -> Main) -> some View {
        let target = showThread
        return CommentReplyZoomContainer(
            presentation: replyPresentation,
            root: root(),
            destination: Group {
                if let target { commentThreadInline(target) }
            },
            ownsKeyboardSafeArea: !isWideLayout,
            onDismissed: { finishCommentThreadDismissal(target?.id) }
        )
        .ignoresSafeArea(.container, edges: isWideLayout ? [] : .bottom)
    }

    private func commentThreadInline(_ target: CommentThreadTarget) -> some View {
        VStack(spacing: 0) {
            CommentThreadHeader(
                isWideLayout: isWideLayout,
                anchors: replyPresentation.anchors,
                onBack: closeCommentThread,
                onClose: closeComments
            )
            CommentThreadView(
                oid: target.oid,
                rootComment: target.root,
                highlightRpid: target.highlightRpid,
                type: target.type,
                upMid: viewModel.videoInfo?.owner.mid,
                isStandalonePage: false,
                onAvatarTap: { mid in
                    navigateFromCommentThread(to: .userSpace(mid), target: target)
                }
            )
            .id(target.id)
            .modifier(CommentThreadLinkHandoff { url, context in
                openCommentThreadURL(url, context: context, target: target)
            })
            .contentLinks(isCurrent: {
                isActiveVideoRoute && replyPresentation.isPresented && showThread?.id == target.id
                    && composer.replyCommentSource == viewModel.currentCommentSource
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func wideCommentPanel(
        model: VideoDetailViewModel,
        geometry: DetailStageLayout.Geometry
    ) -> some View {
        CinematicStagePanel(
            geometry: geometry,
            isStage: stagePresentation == .stage,
            isKeyboardDocked: isKeyboardDocked
        ) {
            commentReplyRegion {
                ZStack(alignment: .top) {
                    wideCommentList(model: model)
                        .transaction(value: stagePresentation) { $0.animation = nil }
                        .allowsHitTesting(showThread == nil)
                        .accessibilityHidden(showThread != nil)
                    VideoDetailComposerDismissScrim(
                        composer: composer,
                        isActive: stagePresentation == .stage && showThread == nil
                    )
                }
                .overlay(alignment: .bottom) {
                    commentFeedbackAndComposer(isCompactOverlay: false)
                }
            }
        }
    }

    private func wideCommentList(model: VideoDetailViewModel) -> some View {
        let source = model.currentCommentSource
        let requestedID = videoID
        let headerView: AnyView? = model.videoInfo != nil ? AnyView(commentSectionHeader) : nil
        let headerFingerprint = model.videoInfo.map { info in
            VideoCommentHeaderFingerprint(
                replyCount: info.stat.reply,
                commentsClosed: model.commentsClosed,
                commentSort: model.commentSort,
                sourceAid: source?.aid,
                sourceGeneration: source?.generation
            )
        }
        return VideoDetailCommentList(
            model: model,
            requestedID: requestedID,
            highlightedRpid: highlightedCommentRpid,
            scrollToRpid: commentTargetRpid,
            headerView: headerView,
            headerFingerprint: headerFingerprint,
            showsInitialVideoSkeletons: false,
            closedTopPadding: 40,
            bottomClearance: isInlineCommentInputEligible
                ? max(120, Self.panelComposerClearance) : Self.panelComposerClearance,
            showsScrollIndicators: false,
            actions: commentRowActions,
            unavailableView: nil,
            unavailableFingerprint: nil,
            onRefresh: {
                guard viewModel === model, videoID == requestedID,
                      model.hasCommentSource(for: requestedID),
                      let request = model.prepareCommentRefresh(from: source) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onScrollOffsetChange: nil
        )
        .task(id: commentTargetRpid) {
            guard let target = commentTargetRpid else { return }
            setStagePresentation(.stage)
            highlightedCommentRpid = target
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, highlightedCommentRpid == target else { return }
            highlightedCommentRpid = nil
            commentTargetRpid = nil
        }
    }

    private func detailsPage(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        ObservedModel(viewModel) { model in
            detailsPageBody(topInset: topInset, bottomInset: bottomInset, model: model)
        }
    }

    private func detailsPageBody(
        topInset: CGFloat, bottomInset: CGFloat, model: VideoDetailViewModel
    ) -> some View {
        ScrollView {
            Color.clear.frame(height: topInset)
            cinematicColumn(
                model: model, columnWidth: pageWidth, horizontalInset: 16,
                showsCommentsCapsule: false, isCompact: true
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: bottomInset + Self.contentBottomPadding)
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

    private var commentSectionHeader: some View {
        let model = viewModel
        let source = model.currentCommentSource
        return HStack(spacing: 6) {
            Text("Comments").font(.headline)
            if let count = model.videoInfo?.stat.reply, count > 0 {
                Text(FormatUtils.viewCount(count))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if !model.commentsClosed {
                commentSortControl(capturedSource: source)
            }
        }
        .padding(.vertical, 4)
    }

    private func commentPageHeader(model: VideoDetailViewModel) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Comments")
                        .appFont(.sectionTitle)
                        .fontWeight(.semibold)
                    if let count = model.videoInfo?.stat.reply, count > 0 {
                        Text(FormatUtils.viewCount(count))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.commentsClosed {
                    commentSortControl(capturedSource: model.currentCommentSource)
                        .background(
                            CommentZoomRegion(anchors: commentPresentation.anchors, role: .sortControl)
                                .padding(-4)
                        )
                }
                CommentHeaderCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Close comments",
                    anchors: commentPresentation.anchors,
                    role: .closeControl,
                    action: closeComments
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            Divider()
                .opacity(0.35)
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .background(CommentZoomRegion(anchors: commentPresentation.anchors, role: .header))
    }

    private func commentSortControl(
        capturedSource: VideoDetailViewModel.CommentSource? = nil
    ) -> some View {
        let model = viewModel
        let source = capturedSource ?? model.currentCommentSource
        let requestedID = videoID
        return CommentSortBar(selection: model.commentSort) { sort in
            guard viewModel === model, videoID == requestedID,
                  model.hasCommentSource(for: requestedID),
                  model.currentCommentSource == source,
                  let request = model.prepareCommentSort(sort, from: source) else { return }
            Task { await model.performCommentRequest(request) }
        }
    }

    private func commentsSurface(bottomInset: CGFloat) -> some View {
        ObservedModel(viewModel) { model in
            commentReplyRegion {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        commentPageHeader(model: model)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                        commentsPageList(bottomInset: bottomInset, model: model)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                    .allowsHitTesting(showThread == nil)
                    .accessibilityHidden(showThread != nil)
                    VideoDetailComposerDismissScrim(
                        composer: composer,
                        isActive: showThread == nil
                    )
                }
                .overlay(alignment: .bottom) {
                    commentFeedbackAndComposer(isCompactOverlay: true)
                }
            }
            .background {
                CommentZoomContentSurface()
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
    }

    private func commentsPageList(
        bottomInset: CGFloat, model: VideoDetailViewModel
    ) -> some View {
        let source = model.currentCommentSource
        let requestedID = videoID
        let unavailableMessage = (model.videoInfo == nil && !model.isLoading) ? model.error : nil
        let unavailableFingerprint = unavailableMessage.map { message in
            VideoUnavailableFingerprint(
                message: message,
                symbolName: model.unavailability?.symbolName ?? "exclamationmark.triangle",
                isRetryable: model.unavailability?.isRetryable ?? true
            )
        }
        return VideoDetailCommentList(
            model: model,
            requestedID: requestedID,
            highlightedRpid: highlightedCommentRpid,
            scrollToRpid: commentTargetRpid,
            headerView: nil,
            headerFingerprint: nil,
            showsInitialVideoSkeletons: true,
            closedTopPadding: 60,
            bottomClearance: (isInlineCommentInputEligible ? 120 : 0)
                + bottomInset + Self.contentBottomPadding,
            showsScrollIndicators: true,
            actions: commentRowActions,
            unavailableView: unavailableMessage.map { AnyView(unavailableState($0)) },
            unavailableFingerprint: unavailableFingerprint,
            onRefresh: {
                guard viewModel === model, videoID == requestedID,
                      model.hasCommentSource(for: requestedID),
                      let request = model.prepareCommentRefresh(from: source) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onScrollOffsetChange: { offset in
                recordPageOffsets([1: offset])
            }
        )
        .task(id: commentTargetRpid) {
            guard let target = commentTargetRpid else { return }
            highlightedCommentRpid = target
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, highlightedCommentRpid == target else { return }
            highlightedCommentRpid = nil
            commentTargetRpid = nil
        }
    }

    private var commentRowActions: VideoDetailCommentRowActions {
        VideoDetailCommentRowActions(
            isRouteActive: { isActiveVideoRoute },
            currentVideoID: { videoID },
            reply: { target in
                composer.beginReply(
                    to: target,
                    aid: viewModel.videoInfo?.aid ?? 0,
                    motion: motion
                )
            },
            openThread: { target in
                openCommentThread(target)
            },
            previewImages: { item in previewImages = item }
        )
    }

    @ViewBuilder
    private var descriptionTags: some View {
        let tagSource = viewModel.currentTagSource
        let musicTags = viewModel.tags.filter(\.isMusic)
        let normalTags = viewModel.tags.filter { !$0.isMusic }

        if !musicTags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(musicTags) { music in
                    let destination = viewModel.musicDestination(for: music, source: tagSource)
                    Button {
                        guard isActiveVideoRoute,
                              let current = viewModel.musicDestination(for: music, source: tagSource) else { return }
                        coordinator.contentLinks.cancel()
                        activeSheet = .music(current)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                            Text(music.tagName)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if destination != nil {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.biliAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.biliAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.thumbnail))
                    }
                    .buttonStyle(.plain)
                    .disabled(destination == nil)
                }
            }
        }

        if !normalTags.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(normalTags) { tag in
                    Button {
                        if let jump = tag.jumpUrl, jump.hasPrefix("http"),
                           let url = URL(string: jump.httpsURL) {
                            openURL(url)
                        } else {
                            coordinator.navigate(to: .search(.all, keyword: tag.tagName))
                        }
                    } label: {
                        Text(tag.tagName)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(.secondary)
                            .background(AppFill.nested, in: Capsule())
                            .frame(minHeight: 36)
                            .contentShape(.interaction, Capsule().inset(by: -4))
                    }
                    .buttonStyle(.appControl)
                }
            }
        }
    }

    private func revealAcceptedComment(
        _ postedRpid: Int,
        replyingTo target: CommentResult.CommentItem?,
        model: VideoDetailViewModel,
        sourceIsCurrent: () -> Bool
    ) {
        guard sourceIsCurrent(), isActiveVideoRoute,
              let source = model.currentCommentSource else { return }
        openComments()
        if let target {
            let root = model.comments.first(where: { $0.rpid == target.rpid }) ?? target
            openCommentThread(CommentThreadTarget(
                oid: source.aid, type: 1, root: root, highlightRpid: postedRpid
            ))
        } else if model.comments.contains(where: { $0.rpid == postedRpid }) {
            commentTargetRpid = postedRpid
        }
    }
}

private struct CommentThreadLinkHandoff: ViewModifier {
    @Environment(\.contentLinkContext) private var context
    @Environment(\.openURL) private var upstream
    let open: @MainActor (URL, ContentLinkContext) -> OpenURLAction.Result

    func body(content: Content) -> some View {
        content
            .environment(\.contentLinkDefersToParent, true)
            .environment(\.openURL, OpenURLAction { url in
                if BiliURLParser.handlesContent(url) {
                    guard let context else { return .discarded }
                    return open(url, context)
                }
                upstream(url)
                return .handled
            })
    }
}

private struct FavoriteFolderSheet: View {
    let folders: [FavFolderListResult.FavFolder]
    @State var selection: Set<Int>
    let onConfirm: (Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List(folders) { folder in
                Button {
                    if selection.contains(folder.id) {
                        selection.remove(folder.id)
                    } else {
                        selection.insert(folder.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        FolderIconView(size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.title)
                                .foregroundStyle(.primary)
                            if let count = folder.mediaCount {
                                Text("\(count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selection.contains(folder.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selection.contains(folder.id)
                                ? AnyShapeStyle(.biliAccent)
                                : AnyShapeStyle(.quaternary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add to Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onConfirm(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView(
                        "No Folders",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Could not load your favorite folders. Check the log for details.")
                    )
                }
            }
        }
        .appAdaptiveSheet(padSizing: .form)
    }
}

private struct DownloadQualityPresentation: Identifiable {
    let id = UUID()
    let info: VideoInfo
    let cid: Int
    let qualities: [DownloadQualityOption]
}

private struct DownloadQualitySheet: View {
    let qualities: [DownloadQualityOption]
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List {
                ForEach(qualities, id: \.code) { quality in
                    Button {
                        onSelect(quality.code)
                    } label: {
                        HStack {
                            Text(quality.label)
                            Spacer()
                            if let bytes = quality.estimatedBytes {
                                Text(DownloadStoragePolicy.byteLabel(bytes))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Download Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct VideoReportSheet: View {
    let aid: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            AuthedBiliWebView(url: URL(string: "https://www.bilibili.com/appeal/?avid=\(aid)")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Report Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .appAdaptiveSheet(compactDetents: [.large], padSizing: .page)
    }
}

// MARK: - Comment list

private struct VideoDetailCommentRowActions {
    let isRouteActive: () -> Bool
    let currentVideoID: () -> VideoID
    let reply: (CommentResult.CommentItem) -> Void
    let openThread: (CommentThreadTarget) -> Void
    let previewImages: (ImagePreviewItem) -> Void
}

private struct VideoCommentHeaderFingerprint: Hashable, Sendable {
    let replyCount: Int?
    let commentsClosed: Bool
    let commentSort: CommentSort
    let sourceAid: Int?
    let sourceGeneration: UInt64?
}

private struct VideoUnavailableFingerprint: Hashable, Sendable {
    let message: String
    let symbolName: String
    let isRetryable: Bool
}

private struct VideoCommentRowFingerprint: Hashable, Sendable {
    let upMid: Int?
    let receiptSourceAid: Int?
    let receiptSourceGeneration: UInt64?
    let receiptSort: CommentSort?
    let receiptLineage: UUID?
    let requestedID: VideoID
}

private enum VideoCommentFooterFingerprint: Hashable, Sendable {
    case unavailable(VideoUnavailableFingerprint)
    case closed(topPadding: CGFloat)
    case feedback(
        hasLoaded: Bool,
        failureCode: Int?,
        isLoading: Bool,
        isEmpty: Bool,
        hasMore: Bool,
        sourceAid: Int?,
        sourceGeneration: UInt64?,
        receiptLineage: UUID?
    )

    static func failureCode(_ failure: CommentLoadFeedback.Failure?) -> Int? {
        switch failure {
        case nil: nil
        case .initial: 0
        case .refresh: 1
        case .pagination: 2
        }
    }
}

private struct VideoDetailCommentList: View {
    let model: VideoDetailViewModel
    let requestedID: VideoID
    let highlightedRpid: Int?
    let scrollToRpid: Int?
    let headerView: AnyView?
    let headerFingerprint: VideoCommentHeaderFingerprint?
    let showsInitialVideoSkeletons: Bool
    let closedTopPadding: CGFloat
    let bottomClearance: CGFloat
    let showsScrollIndicators: Bool
    let actions: VideoDetailCommentRowActions
    let unavailableView: AnyView?
    let unavailableFingerprint: VideoUnavailableFingerprint?
    let onRefresh: @MainActor () async -> Bool
    let onScrollOffsetChange: ((CGFloat) -> Void)?

    var body: some View {
        let receipt = model.commentListReceipt
        let receiptSource = receipt?.source
        let commentLinkIsCurrent: @MainActor @Sendable () -> Bool = {
            actions.isRouteActive()
                && actions.currentVideoID() == requestedID
                && receiptSource != nil
                && model.hasCommentSource(for: requestedID)
                && model.currentCommentSource == receiptSource
        }
        let footer = resolvedFooter(receipt: receipt)
        let currentComments = model.comments
        let visibleComments = CommentAIFilterEngine.shared.visibleComments(
            from: currentComments,
            upMid: model.videoInfo?.owner.mid
        )
        UIKitCommentFeedCollectionView(
            headerItems: headerItems,
            items: commentItems(visibleComments, receipt: receipt),
            footerContent: footer.content,
            footerFingerprint: footer.fingerprint,
            skeletonCount: resolvedSkeletonCount,
            highlightedItemID: highlightedRpid.map { AnyHashableSendable($0) },
            scrollToItemID: scrollToRpid.map { AnyHashableSendable($0) },
            showsItemDividers: true,
            dividerLeadingInset: 48,
            itemSpacing: AppSpacing.l,
            headerSpacing: AppSpacing.l,
            horizontalInset: AppSpacing.l,
            topInset: headerView != nil ? AppSpacing.s : AppSpacing.l,
            maxContentWidth: nil,
            bottomClearance: bottomClearance,
            ignoresBottomSafeArea: false,
            showsScrollIndicators: showsScrollIndicators,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: onRefresh,
            onScrollOffsetChange: onScrollOffsetChange,
            onWillDisplayItemAt: { index in
                triggerPagination(
                    at: index,
                    in: visibleComments,
                    unfilteredCount: currentComments.count,
                    receipt: receipt
                )
            }
        )
        .contentLinks(presentsFeedback: false, handlesURLs: true, isCurrent: commentLinkIsCurrent)
    }

    private var headerItems: [UIKitCommentFeedItem] {
        guard let headerView, let headerFingerprint else { return [] }
        return [
            UIKitCommentFeedItem(
                id: "video-comment-header",
                fingerprint: headerFingerprint,
                content: { headerView }
            )
        ]
    }

    private var isCommentAreaOpen: Bool {
        model.videoInfo != nil && !model.commentsClosed
    }

    private var isEmptyInitialCommentLoad: Bool {
        if model.videoInfo == nil {
            return showsInitialVideoSkeletons && unavailableView == nil
        }
        return !model.commentsClosed
            && model.comments.isEmpty
            && (model.isLoadingComments || model.commentsAwaitingInitialResponse)
    }

    private var resolvedSkeletonCount: Int {
        isEmptyInitialCommentLoad ? 6 : 0
    }

    private func commentItems(
        _ comments: [CommentResult.CommentItem],
        receipt: VideoDetailViewModel.CommentListReceipt?
    ) -> [UIKitCommentFeedItem] {
        guard isCommentAreaOpen else { return [] }
        let upMid = model.videoInfo?.owner.mid
        let extra = AnyHashableSendable(VideoCommentRowFingerprint(
            upMid: upMid,
            receiptSourceAid: receipt?.source.aid,
            receiptSourceGeneration: receipt?.source.generation,
            receiptSort: receipt?.sort,
            receiptLineage: receipt?.lineage,
            requestedID: requestedID
        ))
        return comments.map { comment in
            UIKitCommentFeedItem(comment: comment, extraFingerprint: extra) {
                VideoDetailCommentRow(
                    comment: comment,
                    upMid: upMid,
                    receipt: receipt,
                    requestedID: requestedID,
                    model: model,
                    actions: actions
                )
                .equatable()
            }
        }
    }

    private func resolvedFooter(
        receipt: VideoDetailViewModel.CommentListReceipt?
    ) -> (content: AnyView?, fingerprint: AnyHashableSendable?) {
        if let unavailableView, let unavailableFingerprint, model.videoInfo == nil {
            return (
                unavailableView,
                AnyHashableSendable(VideoCommentFooterFingerprint.unavailable(unavailableFingerprint))
            )
        }
        guard model.videoInfo != nil else { return (nil, nil) }
        if model.commentsClosed {
            let view = ContentUnavailableView(
                "Comments are turned off",
                systemImage: "exclamationmark.bubble"
            )
            .padding(.top, closedTopPadding)
            return (
                AnyView(view),
                AnyHashableSendable(VideoCommentFooterFingerprint.closed(topPadding: closedTopPadding))
            )
        }
        if isEmptyInitialCommentLoad { return (nil, nil) }
        let source = model.currentCommentSource
        let isLoading = model.isLoadingComments || model.commentsAwaitingInitialResponse
        let hasMore = model.commentsHaveMore
        if !isLoading, model.commentFeedback.failure == nil, !model.comments.isEmpty, !hasMore {
            return (nil, nil)
        }
        let feedbackView = CommentLoadFeedbackView(
            feedback: model.commentFeedback,
            isLoading: isLoading,
            isEmpty: model.comments.isEmpty,
            hasMore: hasMore
        ) {
            guard actions.currentVideoID() == requestedID,
                  model.hasCommentSource(for: requestedID),
                  model.currentCommentSource == source else { return }
            let request = model.commentFeedback.failure == .pagination
                ? model.prepareMoreComments(from: receipt) : model.prepareCommentRefresh(from: source)
            if let request { Task { await model.performCommentRequest(request) } }
        }
        let fingerprint = VideoCommentFooterFingerprint.feedback(
            hasLoaded: model.commentFeedback.hasLoaded,
            failureCode: VideoCommentFooterFingerprint.failureCode(model.commentFeedback.failure),
            isLoading: isLoading,
            isEmpty: model.comments.isEmpty,
            hasMore: hasMore,
            sourceAid: source?.aid,
            sourceGeneration: source?.generation,
            receiptLineage: receipt?.lineage
        )
        return (AnyView(feedbackView), AnyHashableSendable(fingerprint))
    }

    private func triggerPagination(
        at index: Int,
        in comments: [CommentResult.CommentItem],
        unfilteredCount: Int,
        receipt: VideoDetailViewModel.CommentListReceipt?
    ) {
        let receiptSource = receipt?.source
        guard actions.isRouteActive(),
              actions.currentVideoID() == requestedID,
              receiptSource != nil,
              model.hasCommentSource(for: requestedID),
              model.currentCommentSource == receiptSource,
              comments.indices.contains(index) else { return }
        let appearingRpid = comments.count < unfilteredCount ? nil : comments[index].rpid
        guard let request = model.prepareMoreComments(
            from: receipt, appearingRpid: appearingRpid
        ) else { return }
        Task { await model.performCommentRequest(request) }
    }
}

private struct VideoDetailCommentRow: View, Equatable {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    let receipt: VideoDetailViewModel.CommentListReceipt?
    let requestedID: VideoID
    let model: VideoDetailViewModel
    let actions: VideoDetailCommentRowActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.comment.rpid == rhs.comment.rpid
            && lhs.upMid == rhs.upMid
            && lhs.receipt == rhs.receipt
            && lhs.requestedID == rhs.requestedID
    }

    var body: some View {
        let model = model
        let source = receipt?.source
        let requestedID = requestedID
        let actions = actions
        let comment = comment
        let sourceIsCurrent: @MainActor @Sendable () -> Bool = {
            actions.isRouteActive()
                && actions.currentVideoID() == requestedID && source != nil
                && model.hasCommentSource(for: requestedID)
                && model.currentCommentSource == source
        }
        let actionIsCurrent: @MainActor @Sendable () -> Bool = { sourceIsCurrent() }
        CommentRowView(
            comment: comment,
            upMid: upMid,
            onReply: { target in
                guard actionIsCurrent() else { return }
                actions.reply(target)
            },
            onViewThread: { root in
                guard actionIsCurrent() else { return }
                let target = CommentThreadTarget(oid: source?.aid ?? 0, type: 1, root: root)
                actions.openThread(target)
            },
            onOpenReply: { root, rpid in
                guard actionIsCurrent() else { return }
                let target = CommentThreadTarget(oid: source?.aid ?? 0, type: 1, root: root, highlightRpid: rpid)
                actions.openThread(target)
            },
            onImageTap: { item in
                guard actionIsCurrent() else { return }
                actions.previewImages(item)
            },
            onDelete: {
                guard sourceIsCurrent() else { return }
                model.removeComment(rpid: comment.rpid)
                model.showToast(String(localized: "Comment deleted"), style: .success)
            }
        )
    }
}
