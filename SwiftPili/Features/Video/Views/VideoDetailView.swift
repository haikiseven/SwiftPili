import Observation
import SwiftUI
import UIKit
import WebKit

/// Presentation reads stay in this child rather than invalidating the player root.
private struct VideoDetailCommentPresentationReader<Content: View>: View {
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

/// `.onChange(of: model.currentCommentSource)` with the read inside the
/// modifier's own body, so a source change does not register on the root.
private struct CommentSourceChange: ViewModifier {
    let model: VideoDetailViewModel
    let action: (VideoDetailViewModel.CommentSource?) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: model.currentCommentSource) { _, source in action(source) }
    }
}

/// Control visibility updates this navigation leaf, not the detail page values.
private struct VideoDetailInlineNavigation: View {
    let player: PlayerViewModel
    let screenLease: PlayerOwnerLease?
    let isActiveVideoRoute: Bool
    let isRouteActivated: Bool
    let isPageAvailable: Bool
    let cornerRadius: CGFloat
    let actions: PlayerPageNavigationActions

    var body: some View {
        if !player.isFullscreen, isActiveVideoRoute {
            let showsNavigation = !hasUsableInlinePlayerChrome || player.showControls
            ZStack(alignment: .topLeading) {
                // A mounted player's scrim is visible whenever showControls is
                // true, including error states. Supply contrast only otherwise.
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
    /// This screen instance's owner key, state-backed so SwiftUI value
    /// recreation never creates another owner or render attachment.
    @State private var screenOwner: String
    /// Whether this page's UIKit transition has finished, latched per route
    /// activation. See `RouteActivationGate` for why the path alone no longer
    /// starts the player handoff.
    @State private var activationCoordinator = VideoDetailActivationCoordinator()
    @State private var viewModel = VideoDetailViewModel()
    @State private var commentPresentation = CommentZoomPresentation()
    @State private var replyPresentation = CommentZoomPresentation()
    @State private var replyCommentSource: VideoDetailViewModel.CommentSource?
    @State private var commentText = ""
    @State private var commentPictures: [ComposedPicture] = []
    @State private var commentSubmission = CommentComposerSubmission()
    @State private var sendCommentTask: Task<Void, Never>?

    private struct CommentComposerCapture {
        let model: VideoDetailViewModel
        let requestedID: VideoID
        let source: VideoDetailViewModel.CommentSource?
        let context: CommentComposerUploadOwner.Context
        let sessionGeneration: UUID
    }

    @State private var showShareSheet = false
    /// The composed share card (cover + title + UP + description + a QR of
    /// the link) rendered when System Share is tapped; shared on its own.
    @State private var shareImage: UIImage?
    @State private var shareRequestID: UUID?
    @State private var sharePreparation: Task<Void, Never>?
    @State private var replyTarget: CommentResult.CommentItem?
    @State private var showThread: CommentThreadTarget?
    @State private var musicSheetDestination: MusicDestination?
    /// One-shot target for the top-level comment list. The id is kept until
    /// the reader performs the scroll so later pagination/body updates cannot
    /// re-target the list.
    @State private var commentTargetRpid: Int?
    @State private var highlightedCommentRpid: Int?
    @State private var previewImages: ImagePreviewItem?
    @State private var isDescExpanded = false
    @State private var showDescActions = false
    @State private var showFavoriteSheet = false
    @State private var downloadPresentation: DownloadQualityPresentation?
    @State private var downloadRequestSerial: UInt64 = 0
    @State private var showCoinDialog = false
    /// Requests started from the coin dialog / favorite sheet, so the action bar
    /// plays its turn-on feedback for them and only them.
    @State private var coinRequestInFlight = false
    @State private var favoriteRequestInFlight = false
    @State private var followRequestInFlight = false
    /// User part picks only (selection haptic); the selected fill slides.
    @State private var partPicks = 0
    /// The part the user just picked, shown before `switchPage` runs.
    @State private var pickedPartCid: Int?
    @Namespace private var partIndicator
    /// Scroll offsets live OUTSIDE SwiftUI @State: they arrive every frame
    /// while a page scrolls, and writing them to @State re-rendered the whole
    /// detail hierarchy per frame (expensive under the tall player subtree).
    /// Mutating this box changes nothing SwiftUI observes; only the
    /// condensation VERDICT (player.inlineCondensed) invalidates the view.
    private final class PageOffsetStore {
        var offsets: [Int: CGFloat] = [:]
    }

    @State private var pageOffsetStore = PageOffsetStore()
    /// Wall-clock of the last condensation flip — the inset transition
    /// perturbs the scroll offset (observed: offset jumps to 0 or +13
    /// right after a condense), and the preference reader re-evaluates
    /// immediately. The automatic path is intentionally one-way now: the
    /// cooldown only prevents duplicate collapse decisions while the spring
    /// settles; restoring the larger window belongs to the button.
    @State private var lastCondenseFlipAt: CFTimeInterval = 0

    /// Height of the video surface only. Ambient uses this boundary; page
    /// content spacing is owned separately by `playerAreaHeight`.
    private var playerVideoHeight: CGFloat {
        // iPad landscape: the cinematic page's own 16:9 box for the current
        // hero/stage state (`DetailStageLayout`). The content column's top
        // inset reads this, so it tracks the box exactly.
        if isWideLayout { return wideVideoSize.height }
        let fallbackBounds = AppWindowMetrics.current?.bounds ?? UIScreen.main.bounds
        let base = containerWidth > 0 ? containerWidth : min(fallbackBounds.width, fallbackBounds.height)
        let shapeIsCurrent = playerShapeIsCurrent
        return DetailPlayerGeometry.videoHeight(
            containerWidth: base,
            primaryColumnWidth: nil,
            isPortraitContent: UIDevice.current.userInterfaceIdiom != .pad
                && (shapeIsCurrent ? player.isPortraitContent : metadataPortraitHint),
            isCondensed: shapeIsCurrent && player.inlineCondensed
        )
    }

    /// The shared player's portrait/condensed flags describe whatever it last
    /// loaded, and only reset inside the next `loadVOD` — after the push and the
    /// metadata request. They shape this page only once the player is showing
    /// this page's video; otherwise a previous portrait video opened this page
    /// at 3:4 and snapped to 16:9 when the new content loaded.
    ///
    /// Not gated on `isRouteActivated`: an outgoing page loses activation at the
    /// path write but stays on screen through the push, and `screenOwner` is
    /// per instance, so the owner match already means "this page's claim".
    private var playerShapeIsCurrent: Bool {
        guard let aid = viewModel.videoInfo?.aid else { return false }
        return player.ownerKey == screenOwner && player.mode == .vod && player.currentAid == aid
    }

    /// Before the player owns this content, the metadata already says whether
    /// the current part is portrait — the same hint `loadVOD` receives (the
    /// video's dimension for the first load, the part's for a part switch),
    /// under the player's own iPad rule. No metadata means the 16:9 box.
    private var metadataPortraitHint: Bool {
        guard UIDevice.current.userInterfaceIdiom != .pad, let info = viewModel.videoInfo else { return false }
        guard let cid = viewModel.currentCid, cid != info.cid,
              let page = info.pages?.first(where: { $0.cid == cid }) else {
            return info.dimension?.isPortrait ?? false
        }
        return (page.dimension?.isPortrait ?? info.dimension?.isPortrait) ?? false
    }

    /// Pinned player header height used by page scroll spacers.
    private var playerAreaHeight: CGFloat {
        DetailPlayerGeometry.pinnedHeaderHeight(
            videoHeight: playerVideoHeight, isFullscreen: player.isFullscreen
        )
    }
    @State private var showReportSheet = false
    @State private var containerWidth: CGFloat
    /// The outer detail container, not the player column, decides orientation.
    /// iPad can keep a regular vertical size class in landscape, so a
    /// size-class check cannot select the wide detail branch reliably.
    ///
    /// Only the VERDICT is state. The raw container size changes on every
    /// layout pass of a push or an iPad resize, and each write re-evaluated the
    /// whole detail root for a value no phone layout reads.
    @State private var isWideLayout: Bool
    /// Phone action adaptation also retains only the measured layout verdict.
    @State private var usesCompactPhoneActions: Bool
    /// The whole detail container's height, measured with the verdict.
    /// Written only while wide: it caps the cinematic page's video box and no
    /// phone layout reads it.
    @State private var wideContainerHeight: CGFloat
    @State private var restingContainerHeight: CGFloat
    @State private var isKeyboardDocked = false
    /// Hero (the page's opening) or stage (player top-left, comment panel on
    /// the right). Per page visit; scrolling switches it both ways.
    @State private var stage = DetailStageState()
    private var stagePresentation: DetailStagePresentation { stage.presentation }
    /// Comment composer starts collapsed into a floating glass button;
    /// tapping it (or any Reply) raises the input panel from the bottom edge.
    @State private var composerPresentation = CommentComposerPresentation()
    @State private var commentFocus = CommentComposerFocus()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    // Tag / BGM jump links route through RootView's OpenURLAction (bilibili
    // links open in-app; a topic/music page opens externally).
    @Environment(\.openURL) private var openURL
    @Environment(\.contentLinkContext) private var linkContext
    @State private var commentLinkLifetime = ContentLinkLifetime()
    @State private var pendingCommentLinkContext: ContentLinkContext?

    @State private var routePosition: PlayerRoutePosition?

    init(target: VideoRouteTarget, routePosition: PlayerRoutePosition? = nil) {
        let initialBounds = AppWindowMetrics.current?.bounds ?? UIScreen.main.bounds
        self.target = target
        _routePosition = State(initialValue: routePosition)
        _screenOwner = State(initialValue: "vod-detail-\(UUID().uuidString)")
        _containerWidth = State(initialValue: initialBounds.width)
        _isWideLayout = State(initialValue: DetailSplitPolicy.usesSplit(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            containerSize: initialBounds.size
        ))
        _usesCompactPhoneActions = State(initialValue: UIDevice.current.userInterfaceIdiom == .phone
            && initialBounds.height >= initialBounds.width)
        _wideContainerHeight = State(initialValue: initialBounds.height)
        _restingContainerHeight = State(initialValue: initialBounds.height)
    }

    private var accent: Color { .biliAccent }
    /// iPad landscape (`DetailSplitPolicy.usesSplit`) is the cinematic page:
    /// hero or stage geometry from the width this page is offered.
    private var stageGeometry: DetailStageLayout.Geometry {
        DetailStageLayout.geometry(
            for: stagePresentation,
            containerSize: CGSize(width: pageWidth, height: wideContainerHeight),
            heroReserve: heroBarHeight > 0 ? heroBarHeight + DetailStageLayout.heroContentGap : 0
        )
    }
    /// The hero bar's measured height. Its width is the full hero column,
    /// which follows the container width only, so measuring it can never feed
    /// back through the player size it reserves room under.
    @State private var heroBarHeight: CGFloat = 0
    private var showsHeroBar: Bool { isWideLayout && stagePresentation == .hero }

    private var wideVideoSize: CGSize { stageGeometry.playerSize }

    private var showsWideChrome: Bool { isWideLayout && !player.isFullscreen }
    /// App-policy width gap between the phone action-bar family (below) and
    /// the iPad-portrait capsule-row family (at/above) in
    /// `cinematicCreatorAndActions`. Not an Apple breakpoint.
    private static var compactCapsuleMinimumWidth: CGFloat { 600 }
    /// `UpNextShelf` card width below `compactCapsuleMinimumWidth`, so two
    /// cards plus a peek are visible on a phone instead of one 280pt card
    /// dominating a ~350pt usable width.
    private static var phoneShelfCardWidth: CGFloat { 220 }

    private func setStagePresentation(_ next: DetailStagePresentation) {
        guard isWideLayout, stagePresentation != next else { return }
        withAnimation(motion.animation(normal: .spring(duration: 0.45, bounce: 0.12))) {
            _ = stage.set(next)
        }
    }

    /// The content column's scroll position relative to its resting top.
    /// Only a switch writes state, so scrolling never re-renders the page.
    private func handleStageScroll(_ offset: CGFloat) {
        guard showsWideChrome, let next = stage.target(forScrollOffset: offset) else { return }
        PlayerLog.log("[Stage] \(stagePresentation) → \(next) offset=\(Int(offset))")
        setStagePresentation(next)
    }

    @State private var presentationScreenID = UUID()
    private var player: PlayerViewModel { PlayerViewModel.shared }
    private var presentationContext: PlayerScreenPresentationContext? {
        guard isRouteActivated, let aid = viewModel.videoInfo?.aid,
              let cid = viewModel.currentCid else { return nil }
        return player.presentationContext(
            screenID: presentationScreenID, lease: viewModel.playerLease,
            route: .video(videoID), position: routePosition,
            source: .vod(aid: aid, cid: cid, source: .ugc)
        )
    }
    private var videoID: VideoID { target.videoID }

    /// Navigation state, not SwiftUI appearance, decides whether this detail
    /// may compose the shared player. Historical destinations remain in the
    /// path for Back but are not allowed to mount either inline or fullscreen
    /// player hosts while a successor is on top.
    private var isActiveVideoRoute: Bool {
        coordinator.isActivePlayerRoute(.video(videoID), position: routePosition)
    }

    /// The route gate AND "this page's transition has completed" (design §8).
    /// Everything that takes the shared player — the activation task, the
    /// inline `PlayerView`, the fullscreen host — keys on this, so the handoff
    /// runs on a settled page rather than inside the push/pop animation. The
    /// path is still the authority: this can only ever be narrower than
    /// `isActiveVideoRoute`, never admit a historical route.
    private var isRouteActivated: Bool {
        activationCoordinator.admits(routeIsActive: isActiveVideoRoute)
    }

    /// This page's own artwork for the video surface while it is not activated:
    /// the loaded metadata's cover once there is one, else the list item's
    /// snapshot the route carried in.
    private var placeholderCoverURL: String? {
        if let pic = viewModel.videoInfo?.pic, !pic.isEmpty { return pic }
        let preview = target.preview.coverSource.desktopURL
        return preview.isEmpty ? nil : preview
    }

    /// The pinned header stays fixed; every page starts the shared content
    /// gap below it.
    private var detailContentTopInset: CGFloat {
        playerAreaHeight + DetailPlayerGeometry.contentTopGap
    }

    /// Navigation exists from the first active-route frame, before the player
    /// is admitted. Every action rechecks the live route rather than media state.
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
            onReport: viewModel.videoInfo != nil ? { showReportSheet = true } : nil,
            pageOwnsInlineNavigation: true
        )
    }

    /// The detail container's measured width, not `UIScreen.main.bounds.width`.
    ///
    /// The screen bounds are a global that flips the instant the scene starts
    /// rotating, while this subtree is still mounted — so entering fullscreen
    /// re-measured both pages, the horizontal scroll content and every
    /// materialized comment row at LANDSCAPE width, immediately before
    /// discarding the whole thing. Exiting never paid that: the pager is
    /// inserted fresh at its final width and measured once, which is exactly the
    /// enter/exit asymmetry in the hitch report. The measured value is also the
    /// correct one under iPad Split View, where the screen bounds are not the
    /// container's width at all.
    private var pageWidth: CGFloat {
        // Before the first geometry callback there is no measurement; the active
        // window bounds are the honest estimate under iPad Split View / Stage Manager.
        containerWidth > 0 ? containerWidth : (AppWindowMetrics.current?.bounds.width ?? UIScreen.main.bounds.width)
    }

    /// Home-indicator inset, read from the key window (stable) instead of a
    /// GeometryReader — the pager no longer lives in one.
    private var pagerBottomInset: CGFloat {
        // Filtered — see `AppWindowMetrics`. The unfiltered `isKeyWindow` scan
        // this replaced could pick UIKit's keyboard windows, which report zero
        // insets, and silently drop the home-indicator inset.
        AppWindowMetrics.safeAreaInsets.bottom
    }

    var body: some View {
        let _ = UIHitchMonitor.countBody("detail")
        // Gate the inline `PlayerView` on `!player.isFullscreen` so only one `PlayerRenderView`
        // (inline or `PlayerFullscreenHost`) claims the shared backend surface at a time.
        ZStack(alignment: .bottom) {
            containerGeometryProbes

            // Keep the player over a full-height detail scroll. Collapsing
            // changes its content inset rather than the scroll viewport, so
            // the retained detail position does not jump with the player size.
            // PlayerView keeps ONE position in the tree so its identity is
            // stable across the fullscreen toggle (a second identity rebuilds
            // the player view and restarts the stream).
            ZStack(alignment: .topLeading) {
                if !player.isFullscreen {
                    // Keep the scroll shell mounted while metadata arrives;
                    // loading changes its content, not its viewport identity.
                    if isWideLayout {
                        wideContent(bottomInset: pagerBottomInset)
                            .animation(nil, value: player.isFullscreen)
                    } else {
                        compactContent()
                    }
                }

                // Pinned top: the inline player remains outside the local
                // comments presentation context and its native Zoom.
                //
                // In fullscreen the surface is the presented host's, so this
                // inline player is absent rather than hidden — see the note on
                // `body` for why exactly one `PlayerView` may be mounted.
                VStack(spacing: 0) {
                    if !player.isFullscreen, isRouteActivated {
                        PlayerView(
                            owner: screenOwner,
                            surfaceRole: .inline,
                            pageNavigationActions: playerPageNavigation,
                            inlineViewportSize: CGSize(
                                width: isWideLayout ? wideVideoSize.width : containerWidth,
                                height: playerVideoHeight
                            ),
                            inlineCornerRadius: showsWideChrome ? DetailStageLayout.playerCornerRadius : 0,
                            screenLease: viewModel.playerLease
                        )
                    } else if !player.isFullscreen {
                        // Historical routes must not mount the shared player,
                        // and neither may an active one whose transition is
                        // still running. This page keeps its own last frame
                        // until the route actually leaves the stack (a covered
                        // page still needs it), falling back to its own cover —
                        // never the outgoing owner's picture.
                        RouteActivationPlaceholderView(
                            still: player.outgoingRouteStill(for: screenOwner),
                            coverURL: placeholderCoverURL,
                            height: playerVideoHeight,
                            cornerRadius: showsWideChrome ? DetailStageLayout.playerCornerRadius : 0
                        )
                    }
                }
                // iPad landscape: the cinematic page's rounded 16:9 box for
                // the current hero/stage state, placed at its own origin. Page
                // navigation overlays the BOX, so Back/Home line up with the
                // player chrome's reserved slot. The window's leading edge
                // never carries the player (it starts `outerMargin` in), so
                // left-edge back is untouched; `systemBackEdgeReserve` stays
                // inside `PlayerView` regardless.
                .frame(width: showsWideChrome ? wideVideoSize.width : nil)
                .overlay(alignment: .topLeading) {
                    VideoDetailInlineNavigation(
                        player: player,
                        screenLease: viewModel.playerLease,
                        isActiveVideoRoute: isActiveVideoRoute,
                        isRouteActivated: isRouteActivated,
                        isPageAvailable: viewModel.error == nil && viewModel.unavailability == nil,
                        cornerRadius: showsWideChrome ? DetailStageLayout.playerCornerRadius : 0,
                        actions: playerPageNavigation
                    )
                }
                .detailStagePlayerPlacement(
                    isActive: showsWideChrome, geometry: stageGeometry, presentation: stagePresentation
                )
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DetailPlayerGeometry.headerBottomInset(isFullscreen: player.isFullscreen))
            }
            // The player must NEVER resize when the keyboard appears —
            // keyboard avoidance applies only to the wide stage comment panel,
            // compact comments overlay, and toast below outside this subtree.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // `minWidth: 0` stops a child sized from a previous `containerWidth`
            // (the player, whose own frame is derived FROM `containerWidth` via
            // `wideVideoSize`/`stageGeometry`) from demanding more than this
            // area is offered and inflating it right back.
            .frame(minWidth: 0, maxWidth: .infinity)

            // The comments destination keeps keyboard avoidance outside the
            // fixed player's keyboard-ignoring subtree. Its local presentation
            // frame starts below that same player and never hosts its surface.
            if !player.isFullscreen, !isWideLayout {
                compactCommentsOverlay
            }

            // Tap anywhere outside the composer to dismiss it while keeping draft
            // text, attachments, and reply target intact.
            if showsWideChrome, composerPresentation.isExpanded, stagePresentation == .stage, showThread == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        commentFocus.dismiss()
                        collapseComposer()
                    }
            }

            // Wide stage comment panel stays mounted (slid off-edge in Hero)
            // outside the keyboard-ignoring subtree so it rises above a
            // docked keyboard without moving or resizing the fixed player.
            if showsWideChrome {
                ObservedModel(viewModel) { model in
                    wideCommentPanel(model: model, geometry: stageGeometry)
                }
            }

            rootCommentToast
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
                    isRouteActive: isRouteActivated && isActiveVideoRoute
                )
            }
        }
        .animation(nil, value: player.isFullscreen)
        // The whole VOD detail page is a cinematic surface (user decision
        // H1/R1): always dark whatever the system appearance, on iPad
        // landscape and on compact alike, and shared components below read
        // `.cinematic` to pick glass cards and bare video cards. Applied to
        // the page's own content and backdrop only: the sheets attached
        // further down are separate presentations and keep the system
        // appearance and the `.standard` surface.
        .appSurface(.cinematic)
        // Stage 0 measurement mount. Zero-sized and hit-test-transparent so it
        // cannot perturb the very layout whose transition cost is being
        // measured (it is one extra layer in a 313–344 layer census, and it is
        // constant across every row). It presents nothing until the control in
        // the toolbar below flips the binding, and it rides the same condition
        // as that control: with no capture running the trigger is not on
        // screen, so an always-mounted probe would be dead weight in every
        // production detail screen. Flipping the switch while this screen is
        // open inserts probe and control together, which costs one extra
        // baseline row and nothing else.
        // All sources use the same exact-context fullscreen host. Historical
        // routes and a not-yet-activated page cannot register a presenter.
        .background(alignment: .topLeading) {
            if let presentationContext {
                PlayerFullscreenHost(context: presentationContext, navigation: coordinator)
            }
        }
        // Page-owned inline navigation keeps the same layout through activation
        // and failure; media readiness never inserts a native navigation bar.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // Preserve native swipe-back while the player chrome owns navigation.
        .keepsInteractivePopGesture()
        .preventsVideoDetailContentDismissal(isActive: isActiveVideoRoute)
        // The appearance half of `isRouteActivated`. UIKit's own cycle, fed to
        // the latch; the route half arrives through the `onChange` below.
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
        // Keep route/content controls monochrome; the player chrome uses
        // explicit white symbols over video.
        .tint(Color.primary)
        .task(id: isRouteActivated) { await activateIfNeeded() }
        .onChange(of: coordinator.pendingCommentNavigation?.sequence) { _, _ in
            Task { await handlePendingCommentNavigationIfNeeded() }
        }
        .freezeWatchdogScreen("VideoDetail")
        .onDisappear {
            cancelSharePreparation()
            downloadRequestSerial &+= 1
            downloadPresentation = nil
            if scenePhase == .active, !isActiveVideoRoute {
                coordinator.cancelVideoNavigation(videoID)
            }
            // Backgrounding makes the scene temporarily non-visible but does
            // not end this detail route's player ownership. Releasing here
            // would clear the owner-admitted Ambient cover and force a new
            // metadata boundary on return. Real navigation/fullscreen exits
            // still arrive while the scene is active and use the existing
            // owner-exit policy. The route still is not cleared here: this
            // callback also runs while the route is only covered by a push.
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
        .sheet(isPresented: $showReportSheet) {
            if let aid = viewModel.videoInfo?.aid {
                VideoReportSheet(aid: aid)
            }
        }
        .sheet(isPresented: $showFavoriteSheet) {
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
        }
        .sheet(item: $musicSheetDestination) { destination in
            MusicDetailSheet(destination: destination) { musicSheetDestination = nil }
        }
        // Root-owned sheet instead of a confirmationDialog attached to the
        // unrelated Share menu. On iPad that dialog used Share as its popover
        // anchor even though Download lives in the navigation-bar More menu,
        // so the quality choices appeared in a misleading position.
        .sheet(item: $downloadPresentation) { presentation in
            DownloadQualitySheet(qualities: presentation.qualities) { quality in
                downloadPresentation = nil
                startDownload(presentation.info, cid: presentation.cid, quality: quality)
            }
            .appAdaptiveSheet(compactDetents: [.medium], padSizing: .form)
        }
        // Thread selection follows the comment source independently of the
        // input bar's login and presentation state.
        .modifier(CommentSourceChange(model: viewModel) { source in
            if source == nil, composerPresentation.isExpanded {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    composerPresentation.isExpanded = false
                }
            }
            if let showThread, showThread.type != 1 || showThread.oid != source?.aid || replyCommentSource != source {
                // Real source retirement cancels both completion chains. Window
                // adaptation alone does not execute this path or clear selection.
                commentPresentation.cancelPendingAction()
                replyPresentation.cancelPendingAction()
                replyPresentation.isPresented = false
                self.showThread = nil
                replyCommentSource = nil
                replyPresentation.anchors.sourceProvider = nil
            }
        })
        // NOTE: replyTarget is intentionally NOT cleared on focus loss —
        // opening the sticker/mention pickers dismisses the keyboard, and
        // the reply context must survive that. The banner's ✕ cancels it.
    }

    @ViewBuilder
    private var containerGeometryProbes: some View {
        // Measure the full resting container size inside a keyboard-ignoring
        // probe so a docked keyboard never shrinks `wideContainerHeight` or the
        // fixed inline player.
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                updateContainerGeometry(size)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

        // Track keyboard-safe threshold only while wide iPad stage mode is active
        // so compact keyboard animations never emit per-frame root invalidations.
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
        if size.width.isFinite, size.width > 0, containerWidth != size.width {
            containerWidth = size.width
        }
        let wide = DetailSplitPolicy.usesSplit(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            containerSize: size
        )
        if isWideLayout != wide { isWideLayout = wide }
        if !wide, isKeyboardDocked { isKeyboardDocked = false }
        if size.height.isFinite, size.height > 0, restingContainerHeight != size.height {
            restingContainerHeight = size.height
        }
        if wide, wideContainerHeight != size.height { wideContainerHeight = size.height }
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            let compactPhone = UIDevice.current.userInterfaceIdiom == .phone && size.height >= size.width
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

    /// Panel-scoped and compact-overlay comment feedback + shared composer slot.
    private func commentFeedbackAndComposer(isCompactOverlay: Bool) -> some View {
        VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            let showsToast = isCompactOverlay
                || (showsWideChrome && stagePresentation == .stage && showThread == nil)
            let showsInput = (isCompactOverlay || showsWideChrome)
                && showsCommentInput(for: commentsPresented)
            let usesFeedWidth = !showsWideChrome && UIDevice.current.userInterfaceIdiom == .pad
            VStack(spacing: 10) {
                Group {
                    if showsToast, let toast = viewModel.toast {
                        ToastView(message: toast)
                    }
                }
                .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: viewModel.toast)

                if showsInput {
                    CommentComposerMorphContainer(
                        isExpanded: composerPresentation.isExpanded,
                        hasDraft: composerHasDraft,
                        sourceIdentity: AnyHashable(commentComposerCapture.context.sourceIdentity),
                        onExpand: openComposer,
                        expandedComposer: { expandedCommentComposer() }
                    )
                    .frame(maxWidth: usesFeedWidth ? ReadableWidth.feed : .infinity)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func expandedCommentComposer() -> some View {
        let composer = commentComposerCapture
        return CommentComposerBar(
            text: commentTextBinding(for: composer),
            pictures: commentPicturesBinding(for: composer),
            placeholder: replyTarget.map { CommentComposerBar.replyPlaceholder(to: $0.member.uname) }
            ?? String(localized: "Write a comment..."),
            replyBanner: replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: commentSubmission.isSending,
            focus: commentFocus,
            autoFocusOnAppear: composerPresentation.isExpanded && !commentSubmission.isSending,
            usesExternalMorphSurface: true,
            onCancelReply: {
                guard composerIsCurrent(composer) else { return }
                PlayerLog.log(
                    "[Composer] reply target cleared (explicit ✕) "
                    + "was rpid=\(replyTarget?.rpid ?? 0)"
                )
                setCommentReplyTarget(nil)
                commentFocus.dismiss()
                // Not an unconditional close: cancelling
                // reply mode may be a drafted reply being
                // turned into a top-level comment.
                if !composerHasDraft { collapseComposer() }
            },
            onCollapse: collapseComposer,
            onSend: {
                guard composerPresentation.isExpanded, composerIsCurrent(composer) else { return }
                sendComment()
            },
            onCancelSend: { sendCommentTask?.cancel() },
            uploadScope: commentUploadScope(for: composer),
            isInteractionCurrent: {
                showsCommentInput(for: commentPresentation.isPresented)
                    && composerIsCurrent(composer)
            }
        )
        .id(composer.context.sourceIdentity)
        .id(composer.sessionGeneration)
    }

    /// Availability reserves clearance independently of presentation state.
    private var isInlineCommentInputEligible: Bool {
        !player.isFullscreen
            && AuthManager.shared.isLoggedIn && !viewModel.commentsClosed
    }

    private func showsCommentInput(for commentsPresented: Bool) -> Bool {
        // An open in-place reply thread has its own bottom
        // composer inside `CommentThreadView`; the page-level composer must
        // not show a second one over it.
        showThread == nil && isInlineCommentInputEligible
            && (isWideLayout ? stagePresentation == .stage : commentsPresented)
    }

    /// Raises the input panel and requests immediate window-attached focus so
    /// the keyboard carries it smoothly into position.
    private func openComposer() {
        guard !composerPresentation.isExpanded else {
            commentFocus.request()
            return
        }
        PlayerLog.log("[Composer] expanding from launcher")
        withAnimation(motion.animation(normal: CollapsibleComposer.composerExpandAnimation)) {
            composerPresentation.isExpanded = true
        }
        commentFocus.request()
    }

    /// Collapses the composer to the floating launcher while preserving draft text, attachments, and reply target.
    private func collapseComposer() {
        commentFocus.dismiss()
        guard composerPresentation.isExpanded else { return }
        PlayerLog.log(
            "[Composer] collapsing to launcher draft=\(composerHasDraft ? 1 : 0)"
        )
        withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
            composerPresentation.isExpanded = false
        }
    }

    /// What the collapsed launcher has to answer for.
    private var composerHasDraft: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !commentPictures.isEmpty
            || replyTarget != nil
    }

    /// Plays, danmaku, watching, and published date.
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

    /// Description (links, long-press copy) and the tag/BGM strip, revealed
    /// beneath the title/stats block when the title is expanded.
    private func descriptionBlock(_ info: VideoInfo) -> some View {
        let hasDesc = !info.desc.isEmpty && info.desc != "-"
        return VStack(alignment: .leading, spacing: 10) {
            if hasDesc {
                // Shares the comment section's link renderer: bare BV
                // ids, @mention UPs (resolved via desc_v2) and plain
                // URLs become accent-tinted, tappable runs. RootView
                // routes bilibili destinations in-app.
                // `linkified` returns a plain `Text` — link runs, no
                // inline stickers — so this takes the role directly
                // rather than an `EmoteTextFont`. Nothing here is cut
                // from font metrics.
                EmoteText.linkified(
                    info.desc, links: info.descLinks, accent: .biliAccent
                )
                    .appFont(.screenSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Tap plain text to collapse; inline links win over
                    // this gesture and navigate instead.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                            isDescExpanded.toggle()
                        }
                    }
                    // Long-press → action sheet, deliberately NOT
                    // .contextMenu: its lift snapshots and magnifies
                    // the text ("pop"). Same reason the comment rows
                    // avoid it — the description stays perfectly still.
                    .onLongPressGesture(minimumDuration: 0.4) {
                        showDescActions = true
                    }
                    .confirmationDialog(
                        "", isPresented: $showDescActions, titleVisibility: .hidden
                    ) {
                        Button {
                            UIPasteboard.general.string = info.desc
                        } label: {
                            Text("Copy Description")
                        }
                    }
            }

            // Tags + identified BGM: revealed with the expanded title.
            if !viewModel.tags.isEmpty {
                descriptionTags
            }
        }
    }

    /// Avatar, name and follow. `fillsWidth` pushes Follow to the trailing
    /// edge (the compact page); the iPad header keeps it beside the name and
    /// gives the trailing side to the action buttons.
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
                    // Two Texts, not a ternary inside Text() — the latter
                    // infers String and skips localization.
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
                // One request at a time, as the Following list already does.
                .disabled(followRequestInFlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.navigate(to: .userSpace(info.owner.mid))
        }
    }

    /// Part picker for multi-P videos, in the app's chip language.
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
                        // The selected fill is one matched shape, so it slides
                        // between chips (a pick or an automatic next part).
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

    /// Moves the indicator first and switches the part only once the slide is
    /// logically complete. `switchPage` does synchronous main-actor work (the
    /// player claim, the tag reset, the load's stop/open), and started in the
    /// same turn it ate the frames of the 0.24s slide. The local pick is a
    /// presentation of the user's intent only: it falls back to the view
    /// model's `currentCid` once the switch settles, so a refused switch
    /// slides back. A newer pick supersedes an older one that has not started.
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

    /// All five actions retain their existing request owners. The portrait
    /// phone presentation hides only Watch/Share captions to fit one row.
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
                showCoinDialog = true
            } else {
                await viewModel.addCoin(multiply: 1)
            }
        }
        .confirmationDialog("Coin this video", isPresented: $showCoinDialog, titleVisibility: .visible) {
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
            showFavoriteSheet = true
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
            // NOT accent-tinted, and that is the whole point.
            //
            // Its four siblings — Like, Coin, Favorite, Watch Later — are
            // `isActive ? .biliAccent : .primary`, so in this row the accent
            // means "this state is on". Share has no on-state, and painting it
            // unconditionally made the accent mean "this state is on" for four
            // buttons and "this is the share button" for the fifth, in one row,
            // at one instant. HIG § Color: "Avoid using the same color to mean
            // different things... if you use your brand color to indicate that
            // a borderless button is interactive, using the same or similar
            // color to stylize noninteractive text is confusing."
            //
            // The fill/outline glyph swap still marks "shared this session" —
            // shape, not colour, which is also what HIG asks for.
            //
            // Concrete `Color.primary`, not hierarchical `.primary`, for the
            // same reason as the count below it.
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

    /// Open the quality picker for a download (or report that it's already
    /// downloaded / in flight). The current part's cid is what gets saved.
    private func offerDownload(_ info: VideoInfo) {
        let cid = viewModel.currentCid ?? info.cid
        if let existing = DownloadManager.shared.existing(bvid: info.bvid, cid: cid) {
            if existing.filesExist {
                viewModel.showToast(String(localized: "Already downloaded"), style: .success)
                return
            }
            // A stale row must not permanently block a fresh download.
            guard DownloadManager.shared.delete(existing) else {
                viewModel.showToast(String(localized: "Download is being exported"), style: .progress)
                return
            }
        }
        if DownloadManager.shared.isActive(bvid: info.bvid, cid: cid) {
            viewModel.showToast(String(localized: "Download in progress"), style: .progress)
            return
        }
        // Immediate when the list is already known (the player's own
        // accept_quality for this part, or a cached one) — the sheet opens with
        // no intermediate state at all. Only a real playurl round trip gets a
        // progress indicator, instead of the tap looking frozen while it ran.
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
                downloadPresentation = DownloadQualityPresentation(
                    info: info, cid: cid, qualities: qualities
                )
            } catch {
                guard !Task.isCancelled, downloadRequestSerial == serial else { return }
                viewModel.showToast(error.localizedDescription, style: .error)
            }
        }
    }

    /// The composed share card ONLY — the link rides inside it as a scannable
    /// QR, so no separate URL is attached. Falls back to the plain link only
    /// if the card somehow never rendered.
    private func shareItems(for info: VideoInfo) -> [Any] {
        if let shareImage { return [shareImage] }
        if let url = URL(string: "https://www.bilibili.com/video/\(info.bvid)") { return [url] }
        return [info.title]
    }

    private func prepareShareCard(_ info: VideoInfo) {
        guard shareRequestID == nil, !showShareSheet, isRouteActivated else { return }
        let id = UUID()
        let model = viewModel
        // Resolve the theme on its UI owner before leaving MainActor.
        let request = ShareCardRenderer.Request(
            coverURL: info.pic, title: info.title, uploader: info.owner.name, description: info.desc,
            linkURL: "https://www.bilibili.com/video/\(info.bvid)",
            linkDisplay: "bilibili.com/video/\(info.bvid)",
            accent: UIColor(Color.biliAccent).resolvedColor(with: UITraitCollection.current)
        )
        shareRequestID = id
        sharePreparation = Task {
            defer {
                if shareRequestID == id {
                    shareRequestID = nil
                    sharePreparation = nil
                }
            }
            guard let image = try? await ShareCardRenderer.prepare(request),
                  !Task.isCancelled, shareRequestID == id,
                  isRouteActivated, viewModel === model, model.videoInfo?.bvid == info.bvid else { return }
            shareImage = image
            showShareSheet = true
            ActivitySharePresenter.present(items: shareItems(for: info)) { completed in
                showShareSheet = false
                // Only a COMPLETED system share counts (not a dismissed
                // sheet) — then report it to BiliBili like Copy Link does.
                guard completed else { return }
                Task { await viewModel.shareVideo() }
            }
        }
    }

    private func cancelSharePreparation() {
        sharePreparation?.cancel()
        sharePreparation = nil
        shareRequestID = nil
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

    /// The detail scroll stays in its original tree while comments cover it.
    private func compactContent() -> some View {
        let details = detailsPage(topInset: detailContentTopInset, bottomInset: pagerBottomInset)
        return VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            details
                .allowsHitTesting(!commentsPresented)
                .accessibilityHidden(commentsPresented)
                .animation(nil, value: player.isFullscreen)
        }
    }

    /// This sibling respects keyboard safe areas while the player/detail
    /// subtree keeps its fixed geometry. Only container insets are extended.
    private var compactCommentsOverlay: some View {
        CommentZoomContainer(
            presentation: commentPresentation,
            destination: commentsSurface(bottomInset: pagerBottomInset),
            onPresentationChanged: { isPresented in
                if isPresented { updatePlayerCondensation() }
                if !isPresented {
                    commentFocus.dismiss()
                    collapseComposer()
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
        commentFocus.dismiss()
        collapseComposer()
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
        replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    /// Opens an inline reply thread inside the comments container using the shared push transition.
    private func openCommentThread(_ target: CommentThreadTarget) {
        guard let source = viewModel.currentCommentSource,
              source.aid == target.oid, target.type == 1 else { return }
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        commentLinkLifetime.invalidate()
        coordinator.contentLinks.cancel()
        commentFocus.dismiss()
        collapseComposer()
        replyPresentation.anchors.sourceProvider = { nil }
        replyCommentSource = source
        showThread = target
        replyPresentation.isPresented = true
    }

    private func closeCommentThread() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        let threadID = showThread?.id
        replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
    }

    /// Native retirement on adaptation does not call this. A confirmed Back
    /// clears only reply selection; the mounted main viewport never changes.
    private func finishCommentThreadDismissal(_ threadID: CommentThreadTarget.Identity?) {
        guard !replyPresentation.isPresented, showThread?.id == threadID else { return }
        showThread = nil
        replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    /// Resolve through the existing link owner while the thread is visible;
    /// only the final route waits for the local native dismissal.
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
              let source = model.currentCommentSource, source == replyCommentSource,
              source.aid == target.oid, target.type == 1,
              model.hasCommentSource(for: requestedID) else { return }
        let navigationRevision = coordinator.contentLinkNavigationRevision
        let accountRevision = AccountManager.shared.identityRevision
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        commentFocus.dismiss()
        collapseComposer()
        replyPresentation.dismissThenPerform {
            finishCommentThreadDismissal(target.id)
            commentPresentation.dismissThenPerform {
                // Both local controllers have actually detached. The retired
                // thread lifetime cannot reject its own captured handoff.
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

    /// This task is keyed by `isRouteActivated`. When A becomes historical
    /// under B and active again after Back, that id goes false → true — at the
    /// END of the pop transition now, not at its finger-lift — so SwiftUI
    /// cancels the historical task and starts a fresh activation for A.
    /// Cancellation/restart is expected. The "IfNeeded" here covers the LEASE
    /// only; whether the activation below is a real load is decided at the
    /// load's own admission point (`VideoDetailReactivationPolicy`), which is
    /// the only place that can see what the player is actually running. Do not
    /// add a second guard here.
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

    /// Consumes only a request addressed to this active video destination.
    /// Comment lookup is deliberately downstream of player activation: it may
    /// reuse the already loaded page-one response, but it never creates a
    /// player owner or changes the playback source.
    private func handlePendingCommentNavigationIfNeeded() async {
        let model = viewModel
        let requestedID = videoID
        let sourceGeneration = model.commentSourceGeneration
        guard isActiveVideoRoute,
              let request = coordinator.pendingCommentNavigation,
              request.anchor.videoID == requestedID,
              model.videoInfo != nil else { return }

        // Keep the existing readiness wait, including the queued comment-only
        // recovery interval after a proved-live activation returns immediately.
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

    /// Vertical videos: full 3:4 near the top of the page; collapse to 16:9
    /// once scrolled. The old failure mode — the resize reset the pager
    /// scroll, which fed straight back into the offset this reads, so any
    /// live evaluation flip-flapped — is gone with the overlay layout: the
    /// player now insets the pages instead of resizing their frame, so
    /// collapsing shifts content smoothly without a reset. Automatic scrolling
    /// is deliberately one-way: the first downward crossing of -60 collapses
    /// the window, and no offset can expand it again. The button is the only
    /// restore path and its manual choice then locks the selected size.
    /// Owner-gated: the shared player may already belong to the NEXT
    /// video's screen when a late offset from this one dribbles in.
    private func recordPageOffsets(_ offsets: [Int: CGFloat]) {
        // Each page reports its native scroll geometry independently. Merge
        // partial reports so one page cannot discard the other's retained offset.
        pageOffsetStore.offsets.merge(offsets) { _, new in new }
        updatePlayerCondensation()
    }

    private func updatePlayerCondensation() {
        // `screenOwner`, NOT `vodOwner(videoID)`. This screen claims the player
        // under its own state-backed pager identity ("vod-pager-<UUID>"), so
        // `ownerKey` can never equal `vodOwner(videoID)` ("vod-bvid=…") — the
        // guard rejected every call and the pull-down stopped collapsing the
        // portrait player to the landscape-aspect window. The check still has
        // to exist: a background page's scroll offsets must not condense the
        // player a different screen now owns.
        guard !isWideLayout, player.isPortraitContent, !player.isFullscreen,
              player.ownerKey == screenOwner else { return }
        // The lock means "the user chose this size explicitly", and only
        // `togglePortraitExpand()` sets it. An automatic collapse is already
        // one-way through `inlineCondensed`; it must not be undone by a later
        // scroll sample.
        // Deliberately silent: this runs per scroll sample, so a line here is a
        // firehose. `togglePortraitExpand` logs the lock when it engages, and
        // every flip line below carries `locked=`, so "a manual choice is
        // holding it" is already answerable from the log.
        if player.portraitCondenseLocked { return }
        let now = CACurrentMediaTime()
        guard now - lastCondenseFlipAt > 0.4 else { return }
        let offset = pageOffsetStore.offsets[commentPresentation.isPresented ? 1 : 0] ?? 0
        // The previous -8pt expansion edge and hysteresis band are intentionally
        // gone. Once the player is condensed, only the visible window button
        // may change it; this path only admits the first -60pt collapse.
        let shouldCondense = PortraitVODCondensationPolicy.shouldAutoCollapse(
            offset: offset,
            isCondensed: player.inlineCondensed,
            hasManualChoice: player.portraitCondenseLocked
        )
        guard shouldCondense else { return }
        lastCondenseFlipAt = now
        // Every field needed to adjudicate a flip without Instruments: which
        // side of which threshold, what it moved from and to, whose decision it
        // was, and whether a manual choice is holding.
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

    /// Unavailability placeholder; shows Retry only for transient failures (`isRetryable`).
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
            // A transient failure keeps a retry; a settled refusal does not.
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

    /// App policy: five action capsules (~510pt) and the comment capsule
    /// beside an owner row with a typical name and the follow button.
    private static var wideHeaderSingleRowWidth: CGFloat { 900 }
    /// The cinematic column's text sits this far inside the player's edge.
    private static var cinematicTextInset: CGFloat { 4 }
    /// Large "related" shelf cards on the cinematic page.
    private static var shelfCardWidth: CGFloat { 280 }
    /// Room under the panel's last comment for the panel-scoped composer.
    private static var panelComposerClearance: CGFloat { 84 }
    /// Extra breathing room after the scrollable details/comments content,
    /// beyond the device's home-indicator inset.
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
        // The content column scrolls UNDER the pinned player and fades out at
        // the player's bottom edge (`mask`), so nothing ever shows in the
        // margin around the rounded player. Only its top inset follows the
        // hero/stage switch; the scroll view's frame never changes.
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

    /// The editorial column: title, creator and actions, stats, parts, the
    /// related shelf and the description card. The same column in hero and
    /// stage, and on the compact (iPhone/iPad-portrait) details page; only
    /// its width, origin and inset change.
    ///
    /// `horizontalInset` defaults to the wide page's 4pt text inset (its
    /// caller already applies a 24pt outer margin); compact has no such
    /// outer margin, so its call site passes 16 to match every other 16pt
    /// inset already used on this page. `showsCommentsCapsule` defaults to
    /// true for the wide hero/stage page; compact passes false, because the
    /// capsule's only action (`setStagePresentation(.stage)`) is a no-op
    /// when `isWideLayout` is false. `isCompact` defaults to false (the wide
    /// hero/stage page, unchanged); the compact details page passes true for
    /// a hot-comments preview card and a vertical related-videos grid in
    /// place of the wide page's horizontal `UpNextShelf`.
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
                    // iPad landscape hero: title, creator and actions in one
                    // glass bar directly under the player, so all of it is
                    // visible at scroll top; the stats follow the bar.
                    heroBar(info, columnWidth: columnWidth, horizontalInset: inset)
                    statsLine(info)
                        .padding(.horizontal, inset)
                } else {
                    // The stats belong to the title they describe, so they sit
                    // directly under it, before the creator and actions.
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

    /// Tapping the title toggles the description and tag strip beneath the
    /// stats row, using the shared snappy disclosure animation.
    /// `fixedLineLimit` pins the title's line count regardless of the
    /// description toggle — the hero bar uses 1 so expanding the description
    /// can never grow the bar and shrink the player it reserves room under.
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

    /// A stable, rendered source for UIKit's native Zoom, including the empty
    /// and loading states so an open comment area always has an entry point.
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

    /// The compact page's vertical related-videos grid: 2 columns on iPhone,
    /// 3 at/above `compactCapsuleMinimumWidth` (iPad portrait) — the same
    /// threshold `cinematicCreatorAndActions` already uses to tell the two
    /// compact families apart. Replaces the wide page's horizontal
    /// `UpNextShelf` only on the compact details page; cards are bare (no
    /// platter) to sit directly on the cinematic backdrop, matching F4.
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

    /// Owner and follow on the leading side, the glass action capsules on the
    /// trailing side while the column is wide enough; otherwise the actions
    /// take their own row. A width rule rather than `ViewThatFits`, which would
    /// build the buttons — and the coin dialog bound to them — twice. In the
    /// hero the comment count rides along as the way into the stage.
    ///
    /// A third, narrower branch (phone widths, below
    /// `compactCapsuleMinimumWidth`) packs the owner row full-width with
    /// Follow trailing, and the same capsule row below it inside a
    /// horizontal `ScrollView` — five capsules side by side run wider than
    /// any phone offers, so the row scrolls instead of wrapping or shrinking.
    /// `showsCommentsCapsule` is false on the compact page (see
    /// `cinematicColumn`), so this branch does not reference the capsule at
    /// all; the other two branches gate it per call.
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

    /// iPad landscape hero: title, creator and the action row in one glass bar
    /// directly under the player — the same controls the wide single-row
    /// header draws, so the buttons are unchanged. Its height is measured for
    /// the hero geometry's reserve.
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

    /// The native stack owns the main list and reply, keeping Zoom inside
    /// this exact comments viewport rather than asking a sibling to present.
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
                    && replyCommentSource == viewModel.currentCommentSource
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The floating glass comment panel of the stage. Hidden in the hero
    /// (slid out past the trailing edge, not hit-testable), but mounted, so a
    /// comment-target navigation can scroll it the moment it appears.
    private func wideCommentPanel(
        model: VideoDetailViewModel,
        geometry: DetailStageLayout.Geometry
    ) -> some View {
        // The list stays mounted (hidden, not removed) while a reply thread
        // is open, so its scroll offset, ScrollViewReader proxy and
        // pageOffsetStore entry are all untouched by opening/closing a
        // thread (F6) — the same precedent this panel already uses for its
        // own hero↔stage slide.
        CinematicStagePanel(
            geometry: geometry,
            isStage: stagePresentation == .stage,
            isKeyboardDocked: isKeyboardDocked
        ) {
            commentReplyRegion {
                ZStack(alignment: .top) {
                    wideCommentList(model: model)
                        // The panel slides as a unit; never spring the UIKit list's
                        // content or header layout inside the hero/stage transaction.
                        .transaction(value: stagePresentation) { $0.animation = nil }
                        .allowsHitTesting(showThread == nil)
                        .accessibilityHidden(showThread != nil)
                    if composerPresentation.isExpanded, stagePresentation == .stage, showThread == nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                commentFocus.dismiss()
                                collapseComposer()
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    commentFeedbackAndComposer(isCompactOverlay: false)
                }
            }
        }
    }

    /// The stage panel's comment list only — extracted so the ZStack wrapper
    /// added for the F6 in-place reply thread does not push
    /// `wideCommentPanel` over the function-body-length threshold.
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

    /// Video info, parts, actions and related videos share one retained scroll.
    /// The top inset follows the pinned player without resizing this viewport.
    /// Bottom clearance keeps the last card above the home indicator.
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
            // The compact details page shares the cinematic page's editorial
            // column — title, creator+actions, stats, parts, the related
            // shelf and the description card — at a 16pt inset (this page has
            // no outer margin of its own) and with no comments capsule (its
            // only action is a no-op outside the wide hero/stage page).
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
            // Measure the scroll position, not the changing player spacer.
            // Match Comments: zero at rest and negative while scrolling down.
            recordPageOffsets([0: offset])
        }
        // Fades scrolled content under the pinned player to reveal the shared cinematic backdrop.
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

    /// The header is the sole dismissal gesture region. Sort and close controls
    /// are explicitly excluded from drag admission.
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
                    // This complete root keeps its viewport while UIKit covers
                    // it with the reply at the same header boundary.
                    VStack(spacing: 0) {
                        commentPageHeader(model: model)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                        commentsPageList(bottomInset: bottomInset, model: model)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                    .allowsHitTesting(showThread == nil)
                    .accessibilityHidden(showThread != nil)
                    if composerPresentation.isExpanded, showThread == nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                commentFocus.dismiss()
                                collapseComposer()
                            }
                    }
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

    /// The native UIKit comment feed owns scrolling, prefetch, and pull-to-refresh.
    /// Its header stays outside this collection view and cannot initiate a list refresh.
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

    /// Host effects for inline rows. Every closure reads live host state, so a
    /// row skipped by equality still acts on the current page.
    private var commentRowActions: VideoDetailCommentRowActions {
        VideoDetailCommentRowActions(
            isRouteActive: { isActiveVideoRoute },
            currentVideoID: { videoID },
            reply: { target in
                setCommentReplyTarget(target)
                let aid = viewModel.videoInfo?.aid ?? 0
                PlayerLog.log(
                    "[Composer] reply target set rpid=\(target.rpid) "
                    + "aid=\(aid)"
                )
                openComposer()
            },
            openThread: { target in
                openCommentThread(target)
            },
            previewImages: { item in previewImages = item }
        )
    }

    /// Tag chips + BiliBili's identified background music, shown under the
    /// expanded description. The BGM rows are the song-identification feature:
    /// tag_type "bgm" entries carry the recognised track and a link to it.
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
                        // A bottom sheet, not a push: identified music is
                        // secondary info about the video, not a screen worth
                        // leaving it for. The `.musicInfo` route itself is
                        // unchanged and still serves deep links.
                        musicSheetDestination = current
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
                        // Topic tags carry their own destination; a plain tag
                        // opens a video search for its name.
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

    private var commentComposerCapture: CommentComposerCapture {
        let model = viewModel
        return CommentComposerCapture(
            model: model, requestedID: videoID, source: model.currentCommentSource,
            context: model.commentComposerContext, sessionGeneration: AuthManager.shared.sessionGeneration
        )
    }

    private func composerIsCurrent(_ captured: CommentComposerCapture) -> Bool {
        guard let source = captured.source else { return false }
        return viewModel === captured.model && videoID == captured.requestedID
            && captured.model.hasCommentSource(for: captured.requestedID)
            && captured.model.currentCommentSource == source
            && captured.model.commentComposerContext == captured.context
            && AuthManager.shared.isLoggedIn
            && AuthManager.shared.sessionGeneration == captured.sessionGeneration
    }

    private func commentUploadScope(for captured: CommentComposerCapture) -> CommentComposerUploadScope {
        // Presentation gates new interaction; an admitted batch survives hiding this draft.
        CommentComposerUploadScope(
            owner: captured.model.commentUpload, context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: { commentSubmission.draftDidChange() }
        )
    }

    private func commentTextBinding(for captured: CommentComposerCapture) -> Binding<String> {
        Binding(get: { commentText }, set: { text in
            guard composerIsCurrent(captured) else { return }
            commentTextBinding.wrappedValue = text
        })
    }

    private func commentPicturesBinding(for captured: CommentComposerCapture) -> Binding<[ComposedPicture]> {
        Binding(get: { commentPictures }, set: { pictures in
            guard composerIsCurrent(captured) else { return }
            commentPicturesBinding.wrappedValue = pictures
        })
    }

    private var commentTextBinding: Binding<String> {
        Binding(get: { commentText }, set: { text in
            // Count literal writes, including canonically equivalent Strings.
            commentSubmission.draftDidChange()
            commentText = text
        })
    }

    private var commentPicturesBinding: Binding<[ComposedPicture]> {
        Binding(get: { commentPictures }, set: { pictures in
            guard pictures != commentPictures else { return }
            commentSubmission.draftDidChange()
            commentPictures = pictures
        })
    }

    private func setCommentReplyTarget(_ target: CommentResult.CommentItem?) {
        if replyTarget?.rpid != target?.rpid { commentSubmission.draftDidChange() }
        replyTarget = target
    }

    private func clearCommentDraft() {
        commentTextBinding.wrappedValue = ""
        commentPicturesBinding.wrappedValue = []
        setCommentReplyTarget(nil)
        viewModel.commentDraftWasReplaced()
    }

    private func finishCommentSubmission(_ attempt: CommentComposerSubmission.Attempt) {
        if commentSubmission.finish(attempt) { sendCommentTask = nil }
    }

    private func sendComment() {
        let msg = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedVideoID = videoID
        guard !msg.isEmpty || !commentPictures.isEmpty,
              !viewModel.commentUpload.isUploading,
              viewModel.hasCommentSource(for: requestedVideoID),
              let aid = viewModel.videoInfo?.aid,
              let attempt = commentSubmission.begin() else { return }
        let target = replyTarget
        let pictures = commentPictures
        let model = viewModel
        let generation = model.commentSourceGeneration
        let sourceIsCurrent = {
            viewModel === model && videoID == requestedVideoID
                && model.hasCommentSource(for: requestedVideoID)
                && model.videoInfo?.aid == aid && model.commentSourceGeneration == generation
        }
        let canApply = {
            !Task.isCancelled && sourceIsCurrent() && commentSubmission.canApply(attempt)
        }
        sendCommentTask = Task {
            guard !Task.isCancelled, sourceIsCurrent() else {
                finishCommentSubmission(attempt)
                return
            }
            let postedRpid = await model.postComment(
                message: msg,
                root: target?.rpid,
                parent: target?.rpid,
                pictures: pictures
            )
            finishCommentSubmission(attempt)
            // Failed, cancelled, edited or superseded sends keep the live draft.
            guard let postedRpid, canApply() else { return }
            clearCommentDraft()
            collapseComposer()
            revealAcceptedComment(
                postedRpid, replyingTo: target, model: model, sourceIsCurrent: sourceIsCurrent
            )
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

/// Shared thread scopes retain URL admission/feedback; the VOD host supplies
/// their final route callback so it can await its own native dismissal.
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

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here, so without this the screen renders the PLATFORM
    // accent while everything behind it renders the chosen one. Declared on
    // the view rather than at the call site so every presentation of it —
    // including future ones — is covered.
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

/// A stable quality picker on both iPhone and iPad. A sheet is intentional:
/// download is launched from a toolbar menu whose item disappears as soon as
/// it is tapped, so a menu/popover cannot provide a durable presentation
/// anchor for the asynchronously fetched quality list.
private struct DownloadQualitySheet: View {
    let qualities: [DownloadQualityOption]
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here, so without this the screen renders the PLATFORM
    // accent while everything behind it renders the chosen one. Declared on
    // the view rather than at the call site so every presentation of it —
    // including future ones — is covered.
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

/// BiliBili exposes NO public JSON endpoint for reporting a VIDEO — the
/// official clients (and PiliPlus) hand off to the web appeal form at
/// bilibili.com/appeal. This wraps that form in a sheet with the login
/// cookies injected, so the flow stays in-app and authenticated.
/// (Comment reporting IS a JSON API and stays fully native.)
private struct VideoReportSheet: View {
    let aid: Int
    @Environment(\.dismiss) private var dismiss

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here, so without this the screen renders the PLATFORM
    // accent while everything behind it renders the chosen one. Declared on
    // the view rather than at the call site so every presentation of it —
    // including future ones — is covered.
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

/// WKWebView with the app's BiliBili auth cookies injected into an
/// ephemeral store — WKWebView does not read the app's cookie jar.
private struct AuthedBiliWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context _: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)

        let cookies: [(name: String, value: String?)] = [
            ("SESSDATA", AuthManager.shared.sessData),
            ("bili_jct", AuthManager.shared.biliJct),
            ("DedeUserID", AuthManager.shared.dedeUserID),
        ]
        let store = config.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for (name, value) in cookies {
            guard let value,
                  let cookie = HTTPCookie(properties: [
                      .domain: ".bilibili.com",
                      .path: "/",
                      .name: name,
                      .value: value,
                      .secure: true,
                  ])
            else { continue }
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        // Load only after every cookie landed — racing the first request
        // against setCookie renders the form logged-out.
        group.notify(queue: .main) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}

// MARK: - Comment list

/// Inline row effects owned by the detail host. They are deliberately not part
/// of `VideoDetailCommentRow` equality: each one runs only after the row's own
/// currentness check, which reads live route/video/source state plus the
/// compared `requestedID` and `receipt`.
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

/// The only reader of the published comment list, its receipt, feedback and
/// loading state, so pagination invalidates this subtree and nothing above it.
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

/// One comment row that SwiftUI can skip when its rendered inputs are equal.
///
/// Closures are excluded from `==` on purpose (they are rebuilt every host
/// pass). That is sound because every effect first passes `sourceIsCurrent`,
/// whose inputs are either live reads or compared here. Row content for one
/// rpid cannot change within one receipt: appends never touch retained rows,
/// and every replacement publishes a new list lineage.
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
        // The detail host's model is State-owned and never replaced, so the
        // former `viewModel === model` identity check is implied here.
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
            // Tapping a specific preview reply lands on THAT reply
            // rather than the top of the thread.
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
