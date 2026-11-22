import SwiftUI

/// Anime (bangumi) playback screen: player on top, season details with a
/// portrait cover, and an episode selection panel. (The followed-anime
/// rail lives at the top of the Anime/Movies sections.)
struct BangumiDetailView: View {
    @AppMotion private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let seasonId: Int
    @State private var routePosition: PlayerRoutePosition?

    init(seasonId: Int, routePosition: PlayerRoutePosition? = nil) {
        let initialBounds = AppWindowMetrics.current?.bounds ?? UIScreen.main.bounds
        self.seasonId = seasonId
        _routePosition = State(initialValue: routePosition)
        _containerWidth = State(initialValue: initialBounds.width)
        _containerSize = State(initialValue: initialBounds.size)
    }
    @State private var viewModel = BangumiViewModel()
    /// Whether this page's UIKit transition has finished, latched per route
    /// activation — the same gate as VOD detail (`RouteActivationGate`).
    @State private var routeActivation = RouteActivationState()
    @State private var isDescExpanded = false
    /// The in-place reply thread on the comment surface (B3).
    @State private var showThread: CommentThreadTarget?
    /// The compact comment overlay and the in-place reply, both native Zoom.
    @State private var commentPresentation = CommentZoomPresentation()
    @State private var replyPresentation = CommentZoomPresentation()
    /// iPad landscape hero or stage, per page visit.
    @State private var stage = DetailStageState()
    /// The hero bar's measured height, reserved under the hero player.
    @State private var heroBarHeight: CGFloat = 0
    @State private var previewImages: ImagePreviewItem?
    @State private var containerWidth: CGFloat
    /// Use the actual detail container orientation. iPad landscape does not
    /// consistently report a compact vertical size class.
    @State private var containerSize: CGSize
    @State private var isKeyboardDocked = false
    @State private var wideComposerExpanded = false
    @State private var compactComposerPresentation = CommentComposerPresentation()
    @State private var commentFocus = CommentComposerFocus()
    @State private var commentLinkLifetime = ContentLinkLifetime()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var presentationScreenID = UUID()
    private var player: PlayerViewModel { PlayerViewModel.shared }
    private var presentationContext: PlayerScreenPresentationContext? {
        guard isRouteActivated, let aid = viewModel.currentEpisodeAid,
              let episode = viewModel.season?.episodes?.first(where: { $0.id == viewModel.selectedEpisodeId }),
              let cid = episode.cid else { return nil }
        return player.presentationContext(
            screenID: presentationScreenID, lease: viewModel.playerLease,
            route: .bangumi(seasonId), position: routePosition,
            source: .vod(aid: aid, cid: cid, source: .pgc(epId: episode.id))
        )
    }
    /// iPad landscape (`DetailSplitPolicy.usesSplit`, shared with VOD) is the
    /// cinematic stage; everything else is the compact page.
    private var isWideLayout: Bool {
        DetailSplitPolicy.usesSplit(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            containerSize: containerSize
        )
    }
    private var stageGeometry: DetailStageLayout.Geometry {
        DetailStageLayout.geometry(
            for: stage.presentation,
            containerSize: CGSize(width: pageWidth, height: containerSize.height),
            heroReserve: heroBarHeight > 0 ? heroBarHeight + DetailStageLayout.heroContentGap : 0
        )
    }
    private var wideVideoSize: CGSize { stageGeometry.playerSize }
    private var showsWideChrome: Bool { isWideLayout && !player.isFullscreen }
    private var showsHeroBar: Bool { isWideLayout && stage.presentation == .hero }

    private var pgcOwner: String { PlayerViewModel.pgcOwner(seasonId) }

    private var isActiveBangumiRoute: Bool {
        coordinator.isActivePlayerRoute(.bangumi(seasonId), position: routePosition)
    }

    /// The route gate AND "this page's transition has completed" — the
    /// shared-player handoff runs on a settled page (design §8). Never wider
    /// than `isActiveBangumiRoute`.
    private var isRouteActivated: Bool {
        routeActivation.admits(routeIsActive: isActiveBangumiRoute)
    }

    private var hasInlineExitChrome: Bool {
        guard isRouteActivated, viewModel.error == nil,
              player.error == nil, player.unavailability == nil,
              let lease = viewModel.playerLease else { return false }
        return player.isCurrentOwner(lease) && player.mode == .vod
            && player.surfaceLease(matching: lease, role: .inline) != nil
    }

    /// This page's own artwork for the player band while it is not activated:
    /// the selected episode's cover, else the season's.
    private var placeholderCoverURL: String? {
        let episode = viewModel.season?.episodes?.first { $0.id == viewModel.selectedEpisodeId }
        let url = episode?.cover ?? viewModel.season?.cover
        return url?.isEmpty == false ? url : nil
    }

    // The singleton's shape belongs to a precise episode and owner lease,
    // including while this page is leaving. Episodes carry no dimension hint.
    private var playerShapeIsCurrent: Bool {
        guard let aid = viewModel.currentEpisodeAid,
              let episode = viewModel.season?.episodes?.first(where: { $0.id == viewModel.selectedEpisodeId }),
              let cid = episode.cid else { return false }
        return player.isCurrentPresentationSource(
            lease: viewModel.playerLease, source: .vod(aid: aid, cid: cid, source: .pgc(epId: episode.id))
        )
    }

    private var playerVideoHeight: CGFloat {
        if isWideLayout { return wideVideoSize.height }
        let fallbackBounds = AppWindowMetrics.current?.bounds ?? UIScreen.main.bounds
        let base = containerWidth > 0
            ? containerWidth
            : min(fallbackBounds.width, fallbackBounds.height)
        let shapeIsCurrent = playerShapeIsCurrent
        return DetailPlayerGeometry.videoHeight(
            containerWidth: base,
            primaryColumnWidth: nil,
            isPortraitContent: UIDevice.current.userInterfaceIdiom != .pad
                && shapeIsCurrent && player.isPortraitContent,
            isCondensed: shapeIsCurrent && player.inlineCondensed
        )
    }

    /// Pinned player header height including the bottom inset.
    private var playerAreaHeight: CGFloat {
        DetailPlayerGeometry.pinnedHeaderHeight(
            videoHeight: playerVideoHeight, isFullscreen: player.isFullscreen
        )
    }

    /// Runs only once the route is active AND its transition completed. The
    /// reactivation no-op (fullscreen return) is decided inside `load`, which
    /// is the only place that can see what the player is running.
    private func activateIfNeeded() async {
        guard isRouteActivated else { return }
        if routeActivation.defersActivation {
            // The departing owner's paused picture must not be re-hosted inside
            // this page by the claim `load` is about to make. A same-owner
            // screen (`pgc-<season>`) is left alone.
            player.endForeignOwnerForRouteActivation(incomingOwner: pgcOwner)
        }
        await viewModel.load(seasonId: seasonId)
    }

    private var playerPageNavigation: PlayerPageNavigationActions {
        PlayerPageNavigationActions(
            onBack: { coordinator.goBack() },
            onHome: { coordinator.goHome() },
            onDownload: nil,
            onReport: nil,
            pageOwnsInlineNavigation: true
        )
    }

    /// The pager's own measured width, not `UIScreen.main.bounds.width`.
    ///
    /// Same defect, same fix, same reason as `VideoDetailView.pageWidth`: the
    /// screen bounds are a global that flips the instant the scene starts
    /// rotating, while this subtree is still mounted — so entering fullscreen
    /// re-measured both pages, the horizontal scroll content and every
    /// materialized comment row at LANDSCAPE width, immediately before
    /// discarding the whole thing. Exiting never paid that: the pager is
    /// inserted fresh at its final width and measured once, which is exactly the
    /// enter/exit asymmetry in the hitch report. This screen was simply missed
    /// when the video and live screens were fixed. The measured value is also
    /// the correct one under iPad Split View, where the screen bounds are not
    /// the container's width at all.
    private var pageWidth: CGFloat {
        // Before the first geometry callback there is no measurement; the active
        // window bounds are the honest estimate under iPad Split View / Stage Manager.
        containerWidth > 0 ? containerWidth : (AppWindowMetrics.current?.bounds.width ?? UIScreen.main.bounds.width)
    }
    private var safeAreaBottom: CGFloat {
        // Filtered — see `AppWindowMetrics`.
        AppWindowMetrics.safeAreaInsets.bottom
    }

    private var isInlineCommentInputEligible: Bool {
        !player.isFullscreen
            && AuthManager.shared.isLoggedIn && !viewModel.commentsClosed
    }

    /// The composer shows where the comments are on screen: the stage panel,
    /// or the presented compact overlay. An open reply thread owns its own
    /// composer inside `CommentThreadView`.
    private var showsCommentInput: Bool {
        showThread == nil && isInlineCommentInputEligible
            && (isWideLayout ? stage.presentation == .stage : commentPresentation.isPresented)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            containerGeometryProbes

            ZStack(alignment: .topLeading) {
                if !player.isFullscreen {
                    // The scroll shells stay mounted while metadata arrives;
                    // loading changes their content, not their viewport. Their
                    // MOUNT is not animated by the fullscreen toggle (fcde28c):
                    // a structural transition would keep every materialized row
                    // rendered while the scene rotates.
                    Group {
                        if isWideLayout {
                            wideStage
                        } else {
                            compactDetailsPage
                        }
                    }
                    .animation(nil, value: player.isFullscreen)
                }

                // Pinned top: the inline player stays outside the comment
                // presentation context and its native Zoom.
                VStack(spacing: 0) {
                    if !player.isFullscreen, isRouteActivated {
                        PlayerView(
                            owner: pgcOwner,
                            surfaceRole: .inline,
                            pageNavigationActions: playerPageNavigation,
                            showsAnimeOptions: true,
                            inlineViewportSize: CGSize(
                                width: isWideLayout ? wideVideoSize.width : containerWidth,
                                height: playerVideoHeight
                            ),
                            inlineCornerRadius: showsWideChrome ? DetailStageLayout.playerCornerRadius : 0,
                            screenLease: viewModel.playerLease
                        )
                    } else if !player.isFullscreen {
                        // Historical, or active with its transition still
                        // running: this page's own still, else its own cover —
                        // never the shared player and never another owner's
                        // picture.
                        RouteActivationPlaceholderView(
                            still: player.outgoingRouteStill(for: pgcOwner),
                            coverURL: placeholderCoverURL,
                            height: playerVideoHeight,
                            cornerRadius: showsWideChrome ? DetailStageLayout.playerCornerRadius : 0
                        )
                    }
                }
                .frame(width: showsWideChrome ? wideVideoSize.width : nil)
                .overlay(alignment: .topLeading) {
                    if !player.isFullscreen, isActiveBangumiRoute {
                        let showsNavigation = !hasInlineExitChrome || player.showControls
                        ZStack(alignment: .topLeading) {
                            if showsNavigation && (!isRouteActivated || !player.showControls) {
                                PlayerControlsScrim()
                                    .frame(height: playerVideoHeight)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: showsWideChrome ? DetailStageLayout.playerCornerRadius : 0,
                                            style: .continuous
                                        )
                                    )
                            }
                            PlayerPageNavigationButtons(actions: playerPageNavigation)
                                .padding(.horizontal, PlayerPageNavigationButtons.inlineHorizontalPadding)
                                .padding(.top, PlayerPageNavigationButtons.topPadding)
                                .opacity(showsNavigation ? 1 : 0)
                                .allowsHitTesting(showsNavigation)
                                .accessibilityHidden(!showsNavigation)
                        }
                    }
                }
                .detailStagePlayerPlacement(
                    isActive: showsWideChrome, geometry: stageGeometry, presentation: stage.presentation
                )
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DetailPlayerGeometry.headerBottomInset(isFullscreen: player.isFullscreen))
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            // Keep continueBanner out of keyboard lift and below compact comments.
            Group {
                if !player.isFullscreen, viewModel.showContinueBanner,
                   let ep = viewModel.resumeEpisode {
                    continueBanner(ep)
                }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)),
                       value: viewModel.showContinueBanner)
            .frame(maxWidth: showsWideChrome ? stageGeometry.columnWidth : .infinity)
            .padding(.leading, showsWideChrome ? stageGeometry.columnOriginX : 0)
            .frame(maxWidth: .infinity, alignment: showsWideChrome ? .leading : .center)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            // The comment overlay keeps keyboard avoidance outside the fixed
            // player's keyboard-ignoring subtree; it starts below the player.
            if !player.isFullscreen, !isWideLayout {
                compactCommentsOverlay
            }

            if showsWideChrome, wideComposerExpanded, stage.presentation == .stage, showThread == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        commentFocus.dismiss()
                        withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                            wideComposerExpanded = false
                        }
                    }
            }

            // iPad stage: keep the comment panel and its composer outside the
            // player's keyboard-ignoring subtree so docked keyboards lift the
            // stage panel while leaving the player and editorial column fixed.
            if showsWideChrome {
                wideStagePanel
            }

            Group {
                if let toast = viewModel.toast {
                    ToastView(message: toast)
                }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: viewModel.toast)
        }
        .guardIPadTopSafeArea(when: !player.isFullscreen)
        .background {
            if player.isFullscreen {
                Color.black.ignoresSafeArea()
            } else {
                CinematicBackdrop(
                    coverURL: placeholderCoverURL,
                    player: player,
                    ownerLease: viewModel.playerLease,
                    isRouteActive: isRouteActivated && isActiveBangumiRoute
                )
            }
        }
        .animation(nil, value: player.isFullscreen)
        // A cinematic surface like the VOD page: always dark, glass cards.
        // Applied to the page's own content and backdrop; presentations
        // attached further down keep the system appearance.
        .appSurface(.cinematic)
        .navigationBarTitleDisplayMode(.inline)
        .statusBarHidden(player.isFullscreen)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .keepsInteractivePopGesture()
        .preventsVideoDetailContentDismissal(isActive: isActiveBangumiRoute)
        .routeAppearanceProbe { event in
            _ = routeActivation.handle(event, owner: pgcOwner)
        }
        .onChange(of: isActiveBangumiRoute, initial: true) { _, active in
            // Departure: silence this page's transport at the path write — the
            // successor waits for its transition before it takes the player.
            // SwiftUI does not write the path for a cancelled swipe.
            let outcome = routeActivation.handle(.routeActivity(active), owner: pgcOwner)
            if outcome == .deactivated, routeActivation.defersActivation {
                viewModel.revokeLoadForRouteDeparture()
                player.pauseForRouteDeparture(lease: viewModel.playerLease)
            }
        }
        .background(alignment: .topLeading) {
            if let presentationContext {
                PlayerFullscreenHost(context: presentationContext, navigation: coordinator)
            }
        }
        // Keyed on the activation, not unkeyed. An unkeyed `.task` ran when
        // this page RE-APPEARED under an interactive pop — at swipe BEGIN,
        // before the path changed and even for a swipe the user then
        // cancelled — and `load` claims the player with no route check of its
        // own. The same rule `player-portrait-vod-paging.md` states for VOD.
        .task(id: isRouteActivated) { await activateIfNeeded() }
        .onDisappear {
            // Backgrounding temporarily removes this SwiftUI tree but does
            // not end the Bangumi route's ownership. Match VOD and defer the
            // release until the scene is active; fullscreen host removal is
            // handled separately by the live PlayerPresentationHost presence.
            guard scenePhase == .active else {
                PlayerLog.log("[BangumiDetail] playback release deferred scenePhase=\(scenePhase)")
                return
            }
            viewModel.releasePlayback()
        }
        // The fullscreen send bar keeps its draft in the player's
        // source-bound slot (as VOD does); a failure that settles after
        // fullscreen closed is surfaced here.
        .onChange(of: player.fullscreenVODDanmakuSendFailure) { _, _ in
            guard !player.isFullscreen,
                  let message = player.takeFullscreenDanmakuFailure(ownerLease: viewModel.playerLease)
            else { return }
            viewModel.showToast(message, style: .error)
        }
        .onChange(of: viewModel.commentSourceRevision) { _, _ in
            commentFocus.dismiss()
            wideComposerExpanded = false
            compactComposerPresentation.isExpanded = false
            if showThread != nil || replyPresentation.isPresented {
                commentPresentation.cancelPendingAction()
                replyPresentation.cancelPendingAction()
                commentLinkLifetime.invalidate()
                replyPresentation.isPresented = false
                showThread = nil
                replyPresentation.anchors.sourceProvider = nil
            }
        }
        .imagePreview(item: $previewImages)
    }

    /// Non-intrusive "Continue Watching" pill: tap to jump to the last-watched
    /// episode (at its saved position), X to dismiss. Playback already started
    /// at episode 1, so this never blocks watching.
    private func continueBanner(_ episode: PGCSeasonInfo.Episode) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.resumeFromLastEpisode() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.biliAccent)
                        VStack(alignment: .leading, spacing: 1) {
                        Text("Continue Watching")
                            .appFont(.messageMeta)
                            .foregroundStyle(.secondary)
                        Text(episode.displayTitle)
                            .appFont(.controlLabel)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                viewModel.dismissContinueBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .continueBannerSurface(reduceTransparency: reduceTransparency)
        .padding(.horizontal, 16)
        .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
    }

    @ViewBuilder
    private var seasonLoadFeedback: some View {
        if let error = viewModel.error, !viewModel.isLoading {
            ContentUnavailableView(
                "Couldn't Load",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .padding(.top, 40)
        } else {
            ProgressView()
                .padding(.top, 60)
        }
    }

    // MARK: - Layout (the VOD detail page's structure)

    private static var stageTextInset: CGFloat { 4 }
    private static var contentBottomPadding: CGFloat { 24 }

    @ViewBuilder
    private var containerGeometryProbes: some View {
        // Measure the full resting container size inside a keyboard-ignoring
        // probe so a docked keyboard never shrinks `containerSize` or the
        // fixed inline player.
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                updateContainerGeometry(size)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

        if isWideLayout {
            let restingHeight = containerSize.height
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
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if containerWidth != size.width { containerWidth = size.width }
        if containerSize != size { containerSize = size }
        if !isWideLayout, isKeyboardDocked { isKeyboardDocked = false }
    }

    /// iPad landscape: hero (full-width player + hero bar) or stage (pinned
    /// player, column, floating comment panel), through the shared scaffold.
    private var wideStage: some View {
        let geometry = stageGeometry
        let presentation = stage.presentation
        let isStage = presentation == .stage
        let topInset = DetailStageLayout.contentTopInset(
            playerHeight: geometry.playerSize.height, presentation: presentation
        )
        // The hero needs room to scroll up into the stage even when its
        // content fits; the stage only clears the home indicator.
        return CinematicStageColumn(
            topInset: topInset,
            fadeGap: DetailStageLayout.contentGap(for: presentation),
            bottomSpacer: safeAreaBottom + Self.contentBottomPadding
                + (isStage ? 0 : containerSize.height * 0.35),
            onOffset: handleStageScroll
        ) {
            bangumiColumn(
                horizontalInset: presentation == .hero ? geometry.playerOriginX : Self.stageTextInset,
                isCompact: false
            )
            .frame(width: geometry.columnWidth, alignment: .leading)
            .padding(.leading, geometry.columnOriginX)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Stage comment panel kept mounted in Hero so scroll position and in-place
    /// reply threads preserve identity, and lifted above docked keyboards.
    private var wideStagePanel: some View {
        CinematicStagePanel(
            geometry: stageGeometry,
            isStage: stage.presentation == .stage,
            isKeyboardDocked: isKeyboardDocked
        ) {
            ObservedModel(viewModel) { _ in
                commentReplyRegion {
                    commentList(isWide: true)
                        // The panel slides as a unit; never spring the UIKit list's
                        // content or header layout inside the hero/stage transaction.
                        .transaction(value: stage.presentation) { $0.animation = nil }
                        .allowsHitTesting(showThread == nil)
                        .accessibilityHidden(showThread != nil)
                        .overlay(alignment: .bottom) {
                            if showsCommentInput { commentComposer(observedExpansion: $wideComposerExpanded) }
                        }
                }
            }
        }
    }

    /// iPhone and iPad portrait: one details scroll under the pinned player,
    /// fading out at its bottom edge onto the cinematic backdrop.
    private var compactDetailsPage: some View {
        let topInset = playerAreaHeight + DetailPlayerGeometry.contentTopGap
        let commentsPresented = commentPresentation.isPresented
        return ScrollView {
            Color.clear.frame(height: topInset)
            bangumiColumn(horizontalInset: 16, isCompact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: safeAreaBottom + Self.contentBottomPadding)
        }
        .mask { DetailPinnedFadeMask(topInset: topInset) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(!commentsPresented)
        .accessibilityHidden(commentsPresented)
    }

    /// The comment overlay below the player, presented from the top-comments
    /// card with the native Zoom — the VOD page's `compactCommentsOverlay`.
    private var compactCommentsOverlay: some View {
        CommentZoomContainer(
            presentation: commentPresentation,
            destination: commentsSurface,
            onPresentationChanged: { isPresented in
                if !isPresented {
                    commentFocus.dismiss()
                    compactComposerPresentation.isExpanded = false
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

    /// Hosted by UIKit (the comment Zoom destination), so the model is read
    /// inside an `ObservedModel` boundary: observation registered in the page
    /// body would leave this content showing the values it was built with.
    private var commentsSurface: some View {
        ObservedModel(viewModel) { _ in
            commentReplyRegion {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        commentSurfaceHeader(isOverlay: true)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                        commentList(isWide: false)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                    .allowsHitTesting(showThread == nil)
                    .accessibilityHidden(showThread != nil)
                    if compactComposerPresentation.isExpanded, showThread == nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                commentFocus.dismiss()
                                withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                                    compactComposerPresentation.isExpanded = false
                                }
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsCommentInput {
                        commentComposer(observedExpansion: Binding(
                            get: { compactComposerPresentation.isExpanded },
                            set: { compactComposerPresentation.isExpanded = $0 }
                        ))
                    }
                }
            }
        }
        .background {
            CommentZoomContentSurface()
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    /// Title, count, refresh and sort; the overlay adds its grabber and close.
    private func commentSurfaceHeader(
        isOverlay: Bool,
        horizontalPadding: CGFloat = 16
    ) -> some View {
        let model = viewModel
        let source = model.currentCommentSource
        let anchors = commentPresentation.anchors
        return VStack(spacing: 0) {
            if isOverlay {
                Capsule()
                    .fill(.secondary.opacity(0.6))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Comments")
                        .appFont(.sectionTitle)
                        .fontWeight(.semibold)
                    if model.commentTotal > 0 {
                        Text(FormatUtils.viewCount(model.commentTotal))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.commentsClosed {
                    CommentSortBar(selection: model.commentSort) { sort in
                        guard viewModel === model, model.currentCommentSource == source,
                              let request = model.prepareCommentSort(sort, from: source) else { return }
                        Task { await model.performCommentRequest(request) }
                    }
                    .background(
                        CommentZoomRegion(anchors: anchors, role: .sortControl)
                            .padding(-4)
                    )
                }
                if isOverlay {
                    CommentHeaderCircleButton(
                        systemName: "xmark",
                        accessibilityLabel: "Close comments",
                        anchors: anchors,
                        role: .closeControl,
                        action: closeComments
                    )
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, isOverlay ? 0 : 12)
            .padding(.bottom, isOverlay ? 6 : 8)
            if isOverlay {
                Divider()
                    .opacity(0.35)
            }
        }
        .frame(minHeight: isOverlay ? 54 : 52)
        .contentShape(Rectangle())
        .background {
            if isOverlay { CommentZoomRegion(anchors: anchors, role: .header) }
        }
    }

    /// The comment list for the playing episode. The stage panel carries its
    /// header inside the collection; the overlay pins it above.
    private func commentList(isWide: Bool) -> some View {
        commentsSection(isWide: isWide)
    }

    /// The episode's comment composer: launcher, then the input bar.
    private func commentComposer(observedExpansion: Binding<Bool>? = nil) -> some View {
        let context = viewModel.composerContext
        let composer = viewModel.commentComposer
        return CollapsibleComposer(
            text: commentTextBinding(context: context),
            pictures: commentPicturesBinding(context: context),
            placeholder: composer.replyTarget.map {
                CommentComposerBar.replyPlaceholder(to: $0.member.uname)
            }
            ?? String(localized: "Write a comment..."),
            replyBanner: composer.replyTarget.map {
                CommentComposerBar.replyBannerText(for: $0.member.uname)
            },
            isSending: composer.submission.isSending,
            focus: commentFocus,
            onCancelReply: {
                guard composerIsCurrent(context) else { return }
                setCommentReplyTarget(nil, context: context)
                commentFocus.dismiss()
            },
            onSend: { sendComment(context: context) },
            allowsCollapseAfterSend: { canCollapseAfterCommentSend },
            uploadScope: commentUploadScope(context: context),
            observedExpansion: observedExpansion
        )
    }

    // MARK: - Stage and comment presentation

    private func setStagePresentation(_ next: DetailStagePresentation) {
        guard isWideLayout, stage.presentation != next else { return }
        withAnimation(motion.animation(normal: .spring(duration: 0.45, bounce: 0.12))) {
            _ = stage.set(next)
        }
    }

    /// The column's scroll position relative to its resting top. Only a
    /// switch writes state, so scrolling never re-renders the page.
    private func handleStageScroll(_ offset: CGFloat) {
        guard showsWideChrome, let next = stage.target(forScrollOffset: offset) else { return }
        PlayerLog.log("[BangumiStage] \(stage.presentation) → \(next) offset=\(Int(offset))")
        setStagePresentation(next)
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
        commentFocus.dismiss()
        if commentPresentation.isPresented {
            commentPresentation.isPresented = false
        } else {
            let threadID = showThread?.id
            replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
        }
    }

    private func resetCommentThreadAfterModalDismissal() {
        guard !commentPresentation.isPresented else { return }
        replyPresentation.cancelPendingAction()
        replyPresentation.isPresented = false
        showThread = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    private func closeCommentThread() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        let threadID = showThread?.id
        replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
    }

    /// A confirmed Back clears only the reply selection; the mounted list's
    /// viewport never changes.
    private func finishCommentThreadDismissal(_ threadID: CommentThreadTarget.Identity?) {
        guard !replyPresentation.isPresented, showThread?.id == threadID else { return }
        showThread = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    /// The comment list (root) and an in-place reply thread (destination).
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
                upMid: nil,
                isStandalonePage: false,
                onAvatarTap: { mid in
                    coordinator.navigate(to: .userSpace(mid))
                }
            )
            .id(target.id)
            .contentLinks(isCurrent: {
                isActiveBangumiRoute && replyPresentation.isPresented && showThread?.id == target.id
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Column

    /// Title area, episodes, synopsis and — compact only — the top-comments
    /// card: the bangumi counterpart of the VOD page's editorial column.
    @ViewBuilder
    private func bangumiColumn(horizontalInset inset: CGFloat, isCompact: Bool) -> some View {
        if let season = viewModel.season {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeroBar {
                    heroBar(season, horizontalInset: inset)
                } else {
                    seasonHeader(season)
                        .padding(.horizontal, inset)
                }

                if let error = viewModel.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, inset)
                }

                if let episodes = season.episodes, !episodes.isEmpty {
                    episodePanel(episodes, horizontalInset: inset)
                }

                if let evaluate = season.evaluate, !evaluate.isEmpty {
                    synopsis(evaluate)
                        .padding(.horizontal, inset)
                }

                if isCompact, !viewModel.commentsClosed {
                    CommentZoomSource(anchors: commentPresentation.anchors) {
                        HotCommentsPreviewCard(
                            comments: Array(viewModel.comments.prefix(2)),
                            total: viewModel.commentTotal,
                            isLoading: viewModel.isLoadingComments,
                            isRegularWidth: sizeClass == .regular,
                            action: openComments
                        )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, inset)
                }
            }
        } else {
            seasonLoadFeedback
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// iPad landscape hero: the title, then rating and episode progress beside
    /// the comments capsule, in one glass bar under the player. Its height is
    /// measured for the hero geometry's reserve.
    private func heroBar(_ season: PGCSeasonInfo, horizontalInset: CGFloat) -> some View {
        CinematicHeroBar {
            Text(season.title ?? "")
                .appFont(.editorialTitle)
                .fontWeight(.bold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } leading: {
            seasonProgressLine(season)
        } trailing: {
            heroCommentsCapsule
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if height.isFinite, height > 0, abs(height - heroBarHeight) >= 1 { heroBarHeight = height }
        }
        .padding(.horizontal, horizontalInset)
    }

    /// Rating and the new-episode progress, as one line.
    private func seasonProgressLine(_ season: PGCSeasonInfo) -> some View {
        HStack(spacing: 10) {
            if let score = season.rating?.score {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(String(format: "%.1f", score))
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
            }
            if let newEp = season.newEp?.desc, !newEp.isEmpty {
                Text(newEp)
                    .appFont(.screenStat)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Opens the stage's comment panel. Absent when comments are closed.
    @ViewBuilder
    private var heroCommentsCapsule: some View {
        if !viewModel.commentsClosed {
            Button(action: openComments) {
                DetailActionButtonLabel {
                    Image(systemName: "text.bubble")
                        .font(.body)
                } caption: {
                    Text(FormatUtils.viewCount(viewModel.commentTotal))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Comments"))
        }
    }

    // MARK: - Comments (keyed to the playing episode)

    private func commentsSection(isWide: Bool) -> some View {
        let model = viewModel
        let source = model.commentListSource
        let requestSource = model.currentCommentSource
        let receipt = model.commentListReceipt
        let context = model.composerContext
        let footer = commentFooter(model: model, requestSource: requestSource, receipt: receipt)
        return UIKitCommentFeedCollectionView(
            headerItems: commentHeaderItems(isWide: isWide, model: model, source: requestSource),
            items: commentFeedItems(model: model, source: source, context: context),
            footerContent: footer.content,
            footerFingerprint: footer.fingerprint,
            skeletonCount: isEmptyInitialCommentLoad(model: model) ? 6 : 0,
            showsItemDividers: true,
            dividerLeadingInset: 48,
            itemSpacing: AppSpacing.l,
            headerSpacing: isWide ? AppSpacing.s : 0,
            horizontalInset: AppSpacing.l,
            topInset: AppSpacing.s,
            bottomClearance: (isInlineCommentInputEligible ? 120 : 0) + (isWide ? 0 : safeAreaBottom),
            ignoresBottomSafeArea: false,
            showsScrollIndicators: false,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: {
                guard viewModel === model,
                      let request = model.prepareCommentRefresh(from: requestSource) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onWillDisplayItemAt: { _ in
                guard viewModel === model,
                      model.currentCommentSource == requestSource,
                      let request = model.prepareMoreComments(from: receipt) else { return }
                Task { await model.performCommentRequest(request) }
            }
        )
        .contentLinks(presentsFeedback: false, handlesURLs: true, isCurrent: {
            source != nil && model.currentCommentSource == source
        })
    }

    private func commentHeaderItems(
        isWide: Bool,
        model: BangumiViewModel,
        source: BangumiViewModel.CommentListSource?
    ) -> [UIKitCommentFeedItem] {
        guard isWide else { return [] }
        let fingerprint = BangumiCommentHeaderFingerprint(
            commentTotal: model.commentTotal,
            commentsClosed: model.commentsClosed,
            commentSort: model.commentSort,
            sourceAid: source?.aid,
            sourceRevision: source?.revision
        )
        return [
            UIKitCommentFeedItem(
                id: "bangumi-comment-header",
                fingerprint: fingerprint,
                content: { commentSurfaceHeader(isOverlay: false, horizontalPadding: 0) }
            )
        ]
    }

    private func isEmptyInitialCommentLoad(model: BangumiViewModel) -> Bool {
        if model.season == nil {
            return model.isLoading || model.error == nil
        }
        return !model.commentsClosed && model.comments.isEmpty && model.isLoadingComments
    }

    private func commentFeedItems(
        model: BangumiViewModel,
        source: BangumiViewModel.CommentListSource?,
        context: CommentComposerUploadOwner.Context
    ) -> [UIKitCommentFeedItem] {
        guard model.season != nil, !model.commentsClosed else { return [] }
        let extra = AnyHashableSendable(BangumiCommentRowFingerprint(
            sourceAid: source?.aid,
            sourceRevision: source?.revision,
            sort: model.commentSort,
            composerSourceRevision: context.sourceRevision,
            composerReplacementEpoch: context.replacementEpoch
        ))
        let visibleComments = CommentAIFilterEngine.shared.visibleComments(from: model.comments, upMid: nil)
        return visibleComments.map { comment in
            UIKitCommentFeedItem(comment: comment, extraFingerprint: extra) {
                commentRow(comment, source: source, context: context)
            }
        }
    }

    private func commentFooter(
        model: BangumiViewModel,
        requestSource: BangumiViewModel.CommentListSource?,
        receipt: BangumiViewModel.CommentListReceipt?
    ) -> (content: AnyView?, fingerprint: AnyHashableSendable?) {
        if model.season == nil {
            guard let error = model.error, !model.isLoading else { return (nil, nil) }
            return (
                AnyView(seasonLoadFeedback.frame(maxWidth: .infinity, alignment: .top)),
                AnyHashableSendable(BangumiCommentFooterFingerprint.seasonError(error))
            )
        }
        if model.commentsClosed {
            let closedView = ContentUnavailableView(
                "Comments are turned off",
                systemImage: "exclamationmark.bubble"
            )
            .padding(.top, 40)
            return (AnyView(closedView), AnyHashableSendable(BangumiCommentFooterFingerprint.closed))
        }
        if isEmptyInitialCommentLoad(model: model) { return (nil, nil) }
        if !model.isLoadingComments, model.commentFeedback.failure == nil, !model.comments.isEmpty {
            return (nil, nil)
        }
        let feedbackView = CommentLoadFeedbackView(
            feedback: model.commentFeedback,
            isLoading: model.isLoadingComments,
            isEmpty: model.comments.isEmpty
        ) {
            guard viewModel === model,
                  let requestSource, model.currentCommentSource == requestSource else { return }
            let request = model.commentFeedback.failure == .pagination
                ? model.prepareMoreComments(from: receipt) : model.prepareCommentRefresh(from: requestSource)
            if let request { Task { await model.performCommentRequest(request) } }
        }
        let fingerprint = BangumiCommentFooterFingerprint.feedback(
            hasLoaded: model.commentFeedback.hasLoaded,
            failureCode: BangumiCommentFooterFingerprint.failureCode(model.commentFeedback.failure),
            isLoading: model.isLoadingComments,
            isEmpty: model.comments.isEmpty,
            sourceAid: requestSource?.aid,
            sourceRevision: requestSource?.revision
        )
        return (AnyView(feedbackView), AnyHashableSendable(fingerprint))
    }

    private func commentRow(
        _ comment: CommentResult.CommentItem,
        source: BangumiViewModel.CommentListSource?,
        context: CommentComposerUploadOwner.Context
    ) -> some View {
        let model = viewModel
        return CommentRowView(
            comment: comment,
            upMid: nil,
            onReply: { target in
                guard composerIsCurrent(context), model.admitsComment(target, from: source) else { return }
                setCommentReplyTarget(target, context: context)
                commentFocus.request()
            },
            onViewThread: { root in
                guard model.admitsComment(root, from: source) else { return }
                let target = CommentThreadTarget(oid: source?.aid ?? 0, type: 1, root: root)
                presentCommentThread(target)
            },
            // A tapped preview reply opens at that reply rather than the thread top.
            onOpenReply: { root, rpid in
                guard model.admitsComment(root, from: source) else { return }
                let target = CommentThreadTarget(
                    oid: source?.aid ?? 0, type: 1, root: root, highlightRpid: rpid
                )
                presentCommentThread(target)
            },
            onImageTap: { item in
                guard model.admitsComment(comment, from: source) else { return }
                previewImages = item
            },
            onDelete: {
                guard model.admitsComment(comment, from: source) else { return }
                model.removeComment(rpid: comment.rpid)
                model.showToast(String(localized: "Comment deleted"), style: .success)
            }
        )
    }

    /// Opens a reply thread in place on the comment surface (B3). Entry from a
    /// row has no geometric source, so the Zoom cross-fades.
    private func presentCommentThread(_ target: CommentThreadTarget) {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        commentLinkLifetime.invalidate()
        coordinator.contentLinks.cancel()
        commentFocus.dismiss()
        replyPresentation.anchors.sourceProvider = { nil }
        showThread = target
        replyPresentation.isPresented = true
    }

    private func composerIsCurrent(_ context: CommentComposerUploadOwner.Context) -> Bool {
        viewModel.composerContext == context
    }

    private func commentUploadScope(context: CommentComposerUploadOwner.Context) -> CommentComposerUploadScope {
        let model = viewModel
        return CommentComposerUploadScope(
            owner: model.commentComposer.upload,
            context: context,
            isCurrent: { viewModel === model && model.composerContext == context },
            onAdmission: { model.commentComposer.draftDidChange() }
        )
    }

    private func commentTextBinding(context: CommentComposerUploadOwner.Context) -> Binding<String> {
        let model = viewModel
        return Binding(get: { model.commentComposer.text }, set: { text in
            guard viewModel === model, model.composerContext == context else { return }
            // Count literal writes, including canonically equivalent Strings.
            model.commentComposer.draftDidChange()
            model.commentComposer.text = text
        })
    }

    private func commentPicturesBinding(context: CommentComposerUploadOwner.Context) -> Binding<[ComposedPicture]> {
        let model = viewModel
        return Binding(get: { model.commentComposer.pictures }, set: { pictures in
            guard viewModel === model, model.composerContext == context,
                  pictures != model.commentComposer.pictures else { return }
            model.commentComposer.draftDidChange()
            model.commentComposer.pictures = pictures
        })
    }

    private func setCommentReplyTarget(
        _ target: CommentResult.CommentItem?, context: CommentComposerUploadOwner.Context
    ) {
        guard composerIsCurrent(context) else { return }
        let composer = viewModel.commentComposer
        composer.acceptedClear = nil
        if composer.replyTarget?.rpid != target?.rpid { composer.draftDidChange() }
        composer.replyTarget = target
    }

    private var canCollapseAfterCommentSend: Bool {
        viewModel.commentComposer.acceptedClear == viewModel.composerContext
    }

    private func sendComment(context: CommentComposerUploadOwner.Context) {
        let model = viewModel
        let composer = model.commentComposer
        let msg = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard composerIsCurrent(context), !composer.upload.isUploading,
              !msg.isEmpty || !composer.pictures.isEmpty,
              let aid = model.currentEpisodeAid,
              let attempt = composer.submission.begin() else { return }
        composer.acceptedClear = nil
        let target = composer.replyTarget
        let pictures = composer.pictures
        let requestedSeasonId = seasonId
        let episodeId = model.selectedEpisodeId
        let revision = model.commentSourceRevision
        let sourceIsCurrent = {
            viewModel === model && seasonId == requestedSeasonId && model.selectedEpisodeId == episodeId
                && model.currentEpisodeAid == aid && model.commentSourceRevision == revision
                && model.composerContext == context
        }
        Task {
            guard !Task.isCancelled, sourceIsCurrent() else {
                composer.submission.finish(attempt)
                return
            }
            let acceptedRpid = await model.postComment(
                message: msg,
                root: target?.rpid,
                parent: target?.rpid,
                pictures: pictures
            )
            guard composer.submission.finish(attempt), acceptedRpid != nil,
                  !Task.isCancelled, sourceIsCurrent(), composer.submission.canApply(attempt) else { return }
            composer.replaceWithEmptyDraft()
            composer.acceptedClear = model.composerContext
            commentFocus.dismiss()
        }
    }

    // MARK: - Header (portrait cover + metadata)

    private func seasonHeader(_ season: PGCSeasonInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(urlString: season.cover ?? "", displaySize: CGSize(width: 104, height: 140))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(season.title ?? "")
                    .appFont(.editorialTitle)
                    .fontWeight(.bold)
                    .lineLimit(2)

                if let score = season.rating?.score {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(String(format: "%.1f", score))
                            .appFont(.controlLabel)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                        if let count = season.rating?.count {
                            Text("(\(FormatUtils.viewCount(count)))")
                                .appFont(.screenStat)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let newEp = season.newEp?.desc, !newEp.isEmpty {
                    Text(newEp)
                        .appFont(.screenStat)
                        .foregroundStyle(.secondary)
                }

                let tags = (season.areas ?? []).compactMap(\.name) + (season.styles ?? [])
                if !tags.isEmpty {
                    Text(tags.prefix(4).joined(separator: " / "))
                        .appFont(.screenStat)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let views = season.stat?.views {
                    HStack(spacing: 10) {
                        Label(FormatUtils.viewCount(views), systemImage: "play.rectangle")
                        if let favorites = season.stat?.favorites {
                            Label(FormatUtils.viewCount(favorites), systemImage: "heart")
                        }
                    }
                    .appFont(.screenStat)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(height: 140)
        }
    }

    // MARK: - Episodes

    private func episodePanel(
        _ episodes: [PGCSeasonInfo.Episode], horizontalInset: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Episodes", count: episodes.count)
                .padding(.horizontal, horizontalInset)

            // Edge to edge, like the VOD part row: chips scroll under the
            // column inset instead of being clipped by it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(episodes) { episode in
                        episodeChip(episode)
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
        }
    }

    private func episodeChip(_ episode: PGCSeasonInfo.Episode) -> some View {
        let selected = viewModel.selectedEpisodeId == episode.id
        return PlaybackEntryChip(
            label: episode.indexLabel,
            title: episode.longTitle ?? "",
            isSelected: selected,
            action: { Task { await viewModel.play(episode: episode) } },
            badge: {
                if let badge = episode.badge, !badge.isEmpty {
                    Text(badge)
                        .appFont(.overlayBadge)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(AccentStore.shared.badgeFill, in: RoundedRectangle(cornerRadius: AppRadius.badge))
                }
            }
        )
    }

    // MARK: - Synopsis

    private func synopsis(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader("Synopsis")
            Text(text)
                .appFont(.screenSummary)
                .foregroundStyle(.secondary)
                .lineLimit(isDescExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                    isDescExpanded.toggle()
                }
            } label: {
                // Same disclosure control as the VOD description.
                HStack(spacing: 3) {
                    (isDescExpanded ? Text("Show Less") : Text("Show More"))
                        .appFont(.controlLabel)
                        .contentTransition(.interpolate)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
                        .appDisclosureRotation(isExpanded: isDescExpanded)
                }
                .foregroundStyle(.biliAccent)
            }
            .buttonStyle(.appControl)
        }
    }

}

private struct BangumiCommentHeaderFingerprint: Hashable, Sendable {
    let commentTotal: Int
    let commentsClosed: Bool
    let commentSort: CommentSort
    let sourceAid: Int?
    let sourceRevision: UInt64?
}

private struct BangumiCommentRowFingerprint: Hashable, Sendable {
    let sourceAid: Int?
    let sourceRevision: UInt64?
    let sort: CommentSort
    let composerSourceRevision: UInt64
    let composerReplacementEpoch: UInt64
}

private enum BangumiCommentFooterFingerprint: Hashable, Sendable {
    case seasonError(String)
    case closed
    case feedback(
        hasLoaded: Bool,
        failureCode: Int?,
        isLoading: Bool,
        isEmpty: Bool,
        sourceAid: Int?,
        sourceRevision: UInt64?
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

private extension View {
    /// Floating banner over content: Liquid Glass on iOS 26, card surface otherwise.
    @ViewBuilder
    func continueBannerSurface(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        if !reduceTransparency, #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            appCardSurface(in: shape)
        }
    }
}
