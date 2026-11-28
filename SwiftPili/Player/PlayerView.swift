import Combine
import SwiftUI

private final class PlayerSurfaceDragStore {
    var translation: CGSize = .zero
    var appliedAdjust: Double?

    func reset() {
        translation = .zero
        appliedAdjust = nil
    }
}

final class PlayerVerticalPagingCoordinator {
    struct Handlers {
        var canPagePrevious: @MainActor () -> Bool = { false }
        let begin: @MainActor () -> Bool
        let change: @MainActor (CGFloat) -> Void
        let end: @MainActor (CGFloat, CGFloat) -> Void
        let cancel: @MainActor () -> Void
    }

    private var handlers: Handlers?

    @MainActor
    func install(_ handlers: Handlers) {
        self.handlers = handlers
    }

    @MainActor
    func canPagePrevious() -> Bool { handlers?.canPagePrevious() ?? false }
    @MainActor
    func begin() -> Bool { handlers?.begin() ?? false }
    @MainActor
    func change(_ translation: CGFloat) { handlers?.change(translation) }
    @MainActor
    func end(_ translation: CGFloat, _ predictedEnd: CGFloat) {
        handlers?.end(translation, predictedEnd)
    }

    @MainActor
    func cancel() { handlers?.cancel() }
}

struct PlayerPageNavigationActions {
    let onBack: () -> Void
    let onHome: () -> Void
    let onDownload: (() -> Void)?
    let onReport: (() -> Void)?
    var pageOwnsInlineNavigation = false
    var onHideVideo: (() -> Void)?
    var onBlockOwner: (() -> Void)?
}

struct PlayerView: View {
    let owner: String
    let surfaceRole: PlayerSurfaceRole
    let verticalPagingGestureSink: PlayerVerticalPagingCoordinator?
    let liveQualityControl: LiveQualityControl?
    let container: PlayerContainerPresentation
    let pageNavigationActions: PlayerPageNavigationActions?
    let showsAnimeOptions: Bool
    let fullscreenViewportAspect: CGFloat?
    let inlineViewportSize: CGSize?
    let inlineCornerRadius: CGFloat
    let isInlinePortraitImmersive: Bool
    let fullscreenSafeAreaInsets: EdgeInsets?
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    let placeholderCoverURL: String?
    let showsLoadingIndicator: Bool
    let endedRecommendations: [PlayerEndedRecommendation]
    let onSelectEndedRecommendation: ((PlayerEndedRecommendation) -> Void)?

    init(
        owner: String,
        surfaceRole: PlayerSurfaceRole = .inline,
        verticalPagingGestureSink: PlayerVerticalPagingCoordinator? = nil,
        liveQualityControl: LiveQualityControl? = nil,
        container: PlayerContainerPresentation = .inlineSafeArea,
        pageNavigationActions: PlayerPageNavigationActions? = nil,
        showsAnimeOptions: Bool = false,
        fullscreenViewportAspect: CGFloat? = nil,
        inlineViewportSize: CGSize? = nil,
        inlineCornerRadius: CGFloat = 0,
        isInlinePortraitImmersive: Bool = false,
        fullscreenSafeAreaInsets: EdgeInsets? = nil,
        screenLease: PlayerOwnerLease? = nil,
        presentationReceipt: PlayerPresentationReceipt? = nil,
        fullscreenHostIdentity: UUID? = nil,
        placeholderCoverURL: String? = nil,
        showsLoadingIndicator: Bool = true,
        gestureDisplay: PlayerGestureDisplay = PlayerGestureDisplay(),
        endedRecommendations: [PlayerEndedRecommendation] = [],
        onSelectEndedRecommendation: ((PlayerEndedRecommendation) -> Void)? = nil
    ) {
        self.owner = owner
        self.surfaceRole = surfaceRole
        self.verticalPagingGestureSink = verticalPagingGestureSink
        self.liveQualityControl = liveQualityControl
        self.container = container
        self.pageNavigationActions = pageNavigationActions
        self.showsAnimeOptions = showsAnimeOptions
        self.fullscreenViewportAspect = fullscreenViewportAspect
        self.inlineViewportSize = inlineViewportSize
        self.inlineCornerRadius = inlineCornerRadius
        self.isInlinePortraitImmersive = isInlinePortraitImmersive
        self.fullscreenSafeAreaInsets = fullscreenSafeAreaInsets
        self.screenLease = screenLease
        self.presentationReceipt = presentationReceipt
        self.fullscreenHostIdentity = fullscreenHostIdentity
        self.placeholderCoverURL = placeholderCoverURL
        self.showsLoadingIndicator = showsLoadingIndicator
        _gestureDisplay = State(initialValue: gestureDisplay)
        self.endedRecommendations = endedRecommendations
        self.onSelectEndedRecommendation = onSelectEndedRecommendation
    }

    private var vm: PlayerViewModel { PlayerViewModel.shared }
    @Environment(\.appSceneID) private var appSceneID
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppMotion private var motion
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @State private var danmakuPanelPresented = false
    @State private var landscapeDanmakuDragOffset: CGSize = .zero
    @State private var subtitlePanelPresented = false
    @State private var landscapeSubtitleDragOffset: CGSize = .zero
    @State private var gestureDisplay: PlayerGestureDisplay
    private var isSeeking: Bool {
        get { gestureDisplay.isSeeking }
        nonmutating set { gestureDisplay.isSeeking = newValue }
    }
    @State private var swipeSeekActive = false
    @State private var swipeSeekBase: TimeInterval = 0
    @State private var swipeSeekRejected = false
    @State private var verticalAdjustActive = false
    @State private var verticalPagingActive = false
    @State private var verticalAdjustIsVolume = false
    @State private var verticalAdjustBase: Double = 0
    @State private var portraitDismissDragActive = false
    @State private var portraitVerticalDragOffset: CGFloat = 0
    @State private var isDraggingHairlineBar = false
    @State private var doubleTapLikePulse: PortraitDoubleTapPulse?
    @State private var doubleTapPulseClearTask: Task<Void, Never>?
    @State private var pinchTransitionLatched = false
    @State private var surfaceSize: CGSize = .zero
    @GestureState private var isSurfacePressing = false
    @State private var surfaceTouchInFlight = false
    @State private var surfaceHoldEngaged = false
    private var surfaceOwnsTouch: Bool {
        surfaceHoldEngaged
            || swipeSeekActive
            || verticalAdjustActive
            || verticalPagingActive
            || portraitDismissDragActive
    }
    @State private var surfaceHoldTask: Task<Void, Never>?
    @State private var pendingTapTask: Task<Void, Never>?
    @State private var surfaceDrag = PlayerSurfaceDragStore()
    @State private var surfaceStartLocation: CGPoint = .zero
    @State private var surfaceGlobalStartLocation: CGPoint = .zero
    @State private var surfaceGlobalOrigin: CGPoint = .zero
    @State private var showSponsorBlock = false

    private var allocatedInlineViewport: CGSize? {
        guard surfaceRole == .inline, !vm.isFullscreen, let size = inlineViewportSize,
              size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { return nil }
        return size
    }

    private var isInlineViewportCollapsed: Bool {
        guard let size = allocatedInlineViewport else { return false }
        return size.width == 0 || size.height == 0
    }

    private var isFullscreenPresentation: Bool {
        surfaceRole == .fullscreen || vm.isFullscreen
    }

    private var isImmersiveStagePresentation: Bool {
        isFullscreenPresentation || isInlinePortraitImmersive
    }

    private var isFullscreenLandscapePresentation: Bool {
        guard isFullscreenPresentation else { return false }
        if DeviceCapability.supportsOrientationLock, AppOrientation.shared.mask.contains(.landscape) {
            return true
        }
        if let aspect = fullscreenViewportAspect, aspect > 1.02 {
            return true
        }
        return false
    }

    private var isPortraitImmersiveFullscreen: Bool {
        (isInlinePortraitImmersive || (isFullscreenPresentation && vm.isPortraitContent && !isFullscreenLandscapePresentation))
            && vm.mode != .live
    }

    private var usesLandscapeDanmakuDrawer: Bool {
        surfaceRole == .fullscreen && vm.isFullscreen && !isPortraitImmersiveFullscreen
    }

    private var danmakuSheetBinding: Binding<Bool> {
        Binding(
            get: { !usesLandscapeDanmakuDrawer && danmakuPanelPresented && danmakuEnabled },
            set: { presented in
                danmakuPanelPresented = presented
                if !presented, isOwner {
                    vm.setDanmakuSettingsHold(subtitlePanelPresented)
                }
            }
        )
    }

    private var subtitleSheetBinding: Binding<Bool> {
        Binding(
            get: { !usesLandscapeDanmakuDrawer && subtitlePanelPresented },
            set: { presented in
                subtitlePanelPresented = presented
                if !presented, isOwner {
                    vm.setDanmakuSettingsHold(danmakuPanelPresented && danmakuEnabled)
                }
            }
        )
    }

    private func dismissDanmakuPanel() {
        danmakuPanelPresented = false
        landscapeDanmakuDragOffset = .zero
        if isOwner {
            vm.setDanmakuSettingsHold(subtitlePanelPresented)
        }
    }

    private func dismissSubtitlePanel() {
        subtitlePanelPresented = false
        landscapeSubtitleDragOffset = .zero
        if isOwner {
            vm.setDanmakuSettingsHold(danmakuPanelPresented && danmakuEnabled)
        }
    }

    private var activePortraitFullscreenContext: PlayerPortraitFullscreenContext? {
        guard let screenLease,
              vm.portraitFullscreenContext?.ownerLease == screenLease else {
            return nil
        }
        return vm.portraitFullscreenContext
    }

    private var portraitStageOffsetY: CGFloat {
        guard isPortraitImmersiveFullscreen, portraitVerticalDragOffset != 0 else { return 0 }
        return portraitVerticalDragOffset * 0.18
    }

    private var portraitStageScale: CGFloat {
        1.0
    }

    private var containerAspect: CGFloat {
        if isFullscreenPresentation {
            return fullscreenViewportAspect ?? PlayerFullscreenViewportPolicy.fallbackAspect
        }
        if let size = allocatedInlineViewport, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        if let aspect = vm.videoAspectRatio, aspect.isFinite, aspect > 0.1 {
            return aspect
        }
        if vm.isPortraitContent, vm.mode != .live {
            return vm.inlineCondensed ? 16.0 / 9.0 : 3.0 / 4.0
        }
        return 16.0 / 9.0
    }

    private var chromeInsets: PlayerChromeInsets {
        let insets: EdgeInsets
        if let fullscreenSafeAreaInsets {
            insets = fullscreenSafeAreaInsets
        } else {
            let window = AppWindowMetrics.safeAreaInsets
            insets = EdgeInsets(
                top: window.top,
                leading: window.left,
                bottom: window.bottom,
                trailing: window.right
            )
        }
        return PlayerChromeInsets.resolve(
            presentation: resolvedPresentation,
            windowTop: insets.top,
            windowBottom: insets.bottom,
            windowLeft: insets.leading,
            windowRight: insets.trailing,
            isPortraitViewport: isPortraitImmersiveFullscreen || containerAspect <= 1.0
        )
    }

    private var resolvedPresentation: PlayerContainerPresentation {
        (isFullscreenPresentation || isInlinePortraitImmersive) ? .fullscreen : container
    }

    private var transportPlacement: PlayerTransportPlacement {
        PlayerTransportPlacement.resolve(presentation: resolvedPresentation)
    }

    private var isOwner: Bool {
        guard let screenLease, vm.isCurrentOwner(screenLease, in: appSceneID) else { return false }
        guard let presentationReceipt else { return surfaceRole == .inline }
        guard let fullscreenHostIdentity else { return false }
        return vm.isCurrentPresentationReceipt(presentationReceipt, hostIdentity: fullscreenHostIdentity)
    }

    private var surfaceLease: PlayerSurfaceLease? {
        guard isOwner, let screenLease else { return nil }
        return vm.surfaceLease(matching: screenLease, role: surfaceRole)
    }

    @State private var claimedSurfaceLease: PlayerSurfaceLease?

    private func claimScreenSurfaceIfCurrent() {
        guard isOwner, let screenLease else { return }
        vm.routeOwnership.bindActiveSceneIfUnbound(appSceneID)
        if let lease = vm.claimSurfaceSlot(ownerLease: screenLease, role: surfaceRole) {
            claimedSurfaceLease = lease
        }
    }

    private var controlAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(
            duration: AppMotionPolicy.duration(for: .control, reduceMotion: false)
        )
    }

    private var microControlAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(
            duration: AppMotionPolicy.duration(for: .microControl, reduceMotion: false)
        )
    }

    private var ownerPlaybackError: String? {
        isOwner ? (vm.error ?? vm.videoPresentationFailureMessage) : nil
    }

    private var isPlaybackUnavailable: Bool {
        ownerPlaybackError != nil
    }

    private var isPlaybackEnded: Bool {
        isOwner && vm.playbackEnded && !isPlaybackUnavailable
    }

    private var resolvedEndedRecommendations: [PlayerEndedRecommendation] {
        if !endedRecommendations.isEmpty {
            return endedRecommendations
        }
        guard isOwner,
              let screenLease,
              vm.session.endedRecommendationsOwnerLease == screenLease else {
            return []
        }
        return vm.endedRecommendations
    }

    private var resolvedOnSelectEndedRecommendation: ((PlayerEndedRecommendation) -> Void)? {
        if let onSelectEndedRecommendation {
            return { recommendation in
                vm.cancelEndedAutoAdvance()
                onSelectEndedRecommendation(recommendation)
            }
        }
        guard isOwner,
              let screenLease,
              vm.session.endedRecommendationsOwnerLease == screenLease,
              let handler = vm.onSelectEndedRecommendation else {
            return nil
        }
        return { recommendation in
            vm.cancelEndedAutoAdvance()
            handler(recommendation)
        }
    }

    private func syncInlineEndedRecommendationsIfNeeded() {
        guard surfaceRole == .inline,
              isOwner,
              let screenLease,
              !endedRecommendations.isEmpty || onSelectEndedRecommendation != nil else {
            return
        }
        vm.syncEndedRecommendations(
            endedRecommendations,
            ownerLease: screenLease,
            onSelect: onSelectEndedRecommendation
        )
    }

    private var hasRenderedFirstFrameForOwner: Bool {
        isOwner && vm.hasRenderedFirstFrame && vm.currentURL != nil
    }

    private var resolvedPlaceholderCoverURL: String? {
        if let placeholderCoverURL, !placeholderCoverURL.isEmpty {
            return placeholderCoverURL
        }
        if isOwner, let ambientCover = vm.ambientCoverURL, !ambientCover.isEmpty {
            return ambientCover
        }
        return nil
    }

    private var usableCoverViewportSize: CGSize? {
        guard let size = allocatedInlineViewport, size.width > 1, size.height > 1 else {
            return nil
        }
        return size
    }

    private var showsUnifiedInlineAmbient: Bool {
        guard surfaceRole == .inline, !isImmersiveStagePresentation,
              isOwner, let screenLease,
              !reduceTransparency,
              vm.ambientModeEnabled,
              ExperimentalSettingsPolicy.isAllowed(.ambient),
              vm.isAmbientVideoLoaded(for: screenLease),
              !isPlaybackUnavailable,
              vm.unavailability == nil else { return false }
        return true
    }

    var body: some View {
        let staged = applyPanelSheetsAndListeners(to: applyStageOverlays(to: playerStageCore))
        let hudStage = applyHUDOverlays(to: applyViewportMetrics(to: staged))
        let seekObserved = applyLifecycleAndSeekObservers(to: hudStage)
        return applyOrientationAndCollapseObservers(to: applyOwnershipObservers(to: seekObserved))
    }

    private var playerStageCore: some View {
        let isFullscreenTransitioning = surfaceRole == .fullscreen
            && PlayerFullscreenTransitionState.shared.isGeometryTransitioning
        let effectiveCornerRadius: CGFloat = if isImmersiveStagePresentation {
            0
        } else {
            max(
                inlineCornerRadius,
                PlayerPresentationCornerPolicy.cornerRadius(
                    isPiPRestoringInline: vm.isPiPRestoringInline
                )
            )
        }
        let outgoingStill = !isOwner ? vm.outgoingRouteStill(for: owner) : nil
        let activeFreezeFrame = isOwner ? vm.freezeFrame.flatMap { $0.size.width > 0 ? $0 : nil } : nil
        let showsFirstFrameCover = !hasRenderedFirstFrameForOwner
            && outgoingStill == nil
            && activeFreezeFrame == nil
            && !isPlaybackUnavailable
        let showsCoverProgress = showsLoadingIndicator && (!isOwner || vm.playbackIntent != .pausedByUser)
        return ZStack {
            if isImmersiveStagePresentation {
                Color.black
            } else if surfaceRole == .inline {
                Color.black
                    .opacity(showsUnifiedInlineAmbient ? 0 : 1)
                    .animation(
                        motion.animation(normal: .easeInOut(duration: 0.45)),
                        value: showsUnifiedInlineAmbient
                    )
            } else {
                Color.clear
            }

            if isOwner, isImmersiveStagePresentation {
                PlayerFullscreenAmbientBackdrop(
                    player: vm,
                    isPortraitImmersive: isPortraitImmersiveFullscreen,
                    fallbackCoverURL: resolvedPlaceholderCoverURL
                )
            }

            if vm.currentURL != nil || vm.retainsRecoveryRenderContainer(owner: owner), isOwner, let surfaceLease {
                PlayerRenderView(
                    generation: vm.playerGeneration,
                    viewController: vm.backend.renderViewController,
                    surfaceLease: surfaceLease,
                    presentationCornerRadius: effectiveCornerRadius
                )
            }

            if PlayerDanmakuMountPolicy.shouldMount(
                mode: vm.mode,
                source: vm.currentURL,
                isOwner: isOwner,
                hasSurfaceLease: surfaceLease != nil,
                enabled: danmakuEnabled,
                hasOfflineDanmaku: vm.hasRegisteredOfflineDanmaku
            ) {
                PlayerDanmakuOverlay(
                    player: vm,
                    topSafeInset: isPortraitImmersiveFullscreen ? chromeInsets.top : 0
                )
            }

            if let still = outgoingStill {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFit()
                    .allowsHitTesting(false)
            }

            if let frame = activeFreezeFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .allowsHitTesting(false)
            }

            ZStack {
                if showsFirstFrameCover {
                    PlayerFirstFrameCoverOverlay(
                        coverURL: resolvedPlaceholderCoverURL,
                        viewportSize: usableCoverViewportSize ?? (surfaceSize.width > 1 && surfaceSize.height > 1 ? surfaceSize : nil),
                        showsProgress: showsCoverProgress,
                        isPortraitImmersive: isPortraitImmersiveFullscreen
                    )
                    .transition(.opacity)
                }
            }
            .animation(
                (reduceMotion || showsFirstFrameCover) ? nil : .easeOut(duration: 0.18),
                value: showsFirstFrameCover
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if isOwner, vm.isBuffering, !showsFirstFrameCover, !isPlaybackUnavailable, !isPlaybackEnded, !verticalAdjustActive {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            HStack(spacing: 0) {
                if !isFullscreenPresentation || isPortraitImmersiveFullscreen {
                    Color.clear
                        .frame(width: Self.systemBackEdgeReserve)
                        .allowsHitTesting(false)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(surfaceGesture)
                    .simultaneousGesture(pinchGesture)
                    .interactiveDismissDisabled(surfaceOwnsTouch)
                    .background(PresentationDismissGestureGate(isHeld: surfaceOwnsTouch))
            }
            .allowsHitTesting(!isPlaybackUnavailable && !isPlaybackEnded)
            .zIndex(0)

            playbackStatusOverlays
            .zIndex(1)

            ZStack {
                if isPortraitImmersiveFullscreen {
                    let showsPortraitChrome = !isFullscreenTransitioning
                        && (isInlinePortraitImmersive || vm.isFullscreen)
                    if isInlinePortraitImmersive || surfaceRole == .inline || vm.isFullscreen {
                        PlayerPortraitFullscreenChrome(
                            player: vm,
                            owner: owner,
                            isCurrentOwner: isOwner,
                            screenLease: screenLease,
                            presentationReceipt: presentationReceipt,
                            fullscreenHostIdentity: fullscreenHostIdentity,
                            gestureDisplay: gestureDisplay,
                            chromeInsets: chromeInsets,
                            isScrubbingOrFastForwarding: swipeSeekActive
                                || isSeeking
                                || surfaceHoldEngaged
                                || isDraggingHairlineBar,
                            isPlaybackUnavailable: isPlaybackUnavailable,
                            isPlaybackEnded: isPlaybackEnded,
                            doubleTapLikePulse: doubleTapLikePulse,
                            danmakuPanelPresented: $danmakuPanelPresented,
                            subtitlePanelPresented: $subtitlePanelPresented,
                            showSponsorBlock: $showSponsorBlock,
                            isDraggingHairlineBar: $isDraggingHairlineBar
                        )
                        .opacity(showsPortraitChrome ? 1 : 0)
                        .allowsHitTesting(showsPortraitChrome)
                        .animation(controlAnimation, value: isFullscreenTransitioning)
                        .transition(.opacity)
                    }
                } else {
                    let showsControlsOverlay = (vm.showControls || isPlaybackUnavailable || isPlaybackEnded)
                        && !isFullscreenTransitioning
                        && (surfaceRole == .inline || vm.isFullscreen)
                    if surfaceRole == .inline || vm.isFullscreen {
                        PlayerControlsOverlay(
                            player: vm, owner: owner, screenLease: screenLease,
                            presentationReceipt: presentationReceipt, fullscreenHostIdentity: fullscreenHostIdentity,
                            gestureDisplay: gestureDisplay, liveQualityControl: liveQualityControl,
                            pageNavigationActions: pageNavigationActions,
                            showsAnimeOptions: showsAnimeOptions,
                            chromeInsets: chromeInsets, transportPlacement: transportPlacement,
                            suppressTransportRow: isPlaybackUnavailable,
                            danmakuPanelPresented: $danmakuPanelPresented,
                            subtitlePanelPresented: $subtitlePanelPresented,
                            showSponsorBlock: $showSponsorBlock
                        )
                        .opacity(showsControlsOverlay ? 1 : 0)
                        .allowsHitTesting(showsControlsOverlay)
                        .animation(controlAnimation, value: isFullscreenTransitioning)
                        .animation(controlAnimation, value: showsControlsOverlay)
                        .transition(.opacity)
                    }
                }
            }
            .animation(controlAnimation, value: isPortraitImmersiveFullscreen)
            .zIndex(2)

            if usesLandscapeDanmakuDrawer, subtitlePanelPresented {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(controlAnimation) {
                                dismissSubtitlePanel()
                            }
                        }

                    SubtitlePlayerSettingsPanel(player: vm, surface: .overlay) {
                        withAnimation(controlAnimation) {
                            dismissSubtitlePanel()
                        }
                    }
                    .offset(
                        x: max(0, landscapeSubtitleDragOffset.width),
                        y: max(0, landscapeSubtitleDragOffset.height)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 16)
                            .onChanged { value in
                                landscapeSubtitleDragOffset = value.translation
                            }
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                let predictedDx = value.predictedEndTranslation.width
                                let predictedDy = value.predictedEndTranslation.height
                                if dy > 44 || dx > 44 || predictedDy > 110 || predictedDx > 110 {
                                    withAnimation(controlAnimation) {
                                        dismissSubtitlePanel()
                                    }
                                } else {
                                    withAnimation(reduceMotion ? nil : .spring(duration: 0.24)) {
                                        landscapeSubtitleDragOffset = .zero
                                    }
                                }
                            }
                    )
                    .padding(.top, max(10, chromeInsets.top + 8))
                    .padding(.trailing, 12 + chromeInsets.horizontal)
                    .padding(.bottom, max(10, chromeInsets.bottom + 10))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(3)
            }

            if usesLandscapeDanmakuDrawer,
               danmakuPanelPresented, danmakuEnabled {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(controlAnimation) {
                                dismissDanmakuPanel()
                            }
                        }

                    DanmakuPlayerSettingsPanel(presentation: .fullscreen, surface: .overlay) {
                        withAnimation(controlAnimation) {
                            dismissDanmakuPanel()
                        }
                    }
                    .offset(
                        x: max(0, landscapeDanmakuDragOffset.width),
                        y: max(0, landscapeDanmakuDragOffset.height)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 16)
                            .onChanged { value in
                                landscapeDanmakuDragOffset = value.translation
                            }
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                let predictedDx = value.predictedEndTranslation.width
                                let predictedDy = value.predictedEndTranslation.height
                                if dy > 44 || dx > 44 || predictedDy > 110 || predictedDx > 110 {
                                    withAnimation(controlAnimation) {
                                        dismissDanmakuPanel()
                                    }
                                } else {
                                    withAnimation(reduceMotion ? nil : .spring(duration: 0.24)) {
                                        landscapeDanmakuDragOffset = .zero
                                    }
                                }
                            }
                    )
                    .padding(.top, max(10, chromeInsets.top + 8))
                    .padding(.trailing, 12 + chromeInsets.horizontal)
                    .padding(.bottom, max(10, chromeInsets.bottom + 10))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(3)
            }

            if vm.showStats {
                Color.clear
                    .overlay(alignment: .topLeading) {
                        PlayerStatsOverlay(
                            player: vm,
                            isCurrentOwner: isOwner && !isPlaybackUnavailable,
                            gestureDisplay: gestureDisplay,
                            chromeInsets: chromeInsets
                        )
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .zIndex(4)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .clipShape(
            RoundedRectangle(
                cornerRadius: effectiveCornerRadius,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var playbackStatusOverlays: some View {
        let allowsOverlayPaging = isPortraitImmersiveFullscreen && verticalPagingGestureSink != nil
        if let error = ownerPlaybackError {
            PlayerPlaybackErrorOverlay(
                message: error,
                unavailability: vm.unavailability,
                isFullscreen: isImmersiveStagePresentation,
                chromeInsets: chromeInsets,
                onRetry: { vm.retryPlayback() }
            )
            .simultaneousGesture(portraitOverlayPagingGesture, isEnabled: allowsOverlayPaging)
            .zIndex(1)
        }

        ZStack {
            if isPlaybackEnded {
                PlayerPlaybackEndedOverlay(
                    isFullscreen: isImmersiveStagePresentation,
                    isPortraitFullscreen: isPortraitImmersiveFullscreen,
                    chromeInsets: chromeInsets,
                    transportPlacement: transportPlacement,
                    autoAdvance: vm.endedAutoAdvance,
                    recommendations: resolvedEndedRecommendations,
                    onReplay: { vm.play() },
                    onNextEpisode: vm.endedNextEpisodeAction,
                    onPlayAutoAdvanceNow: { vm.playEndedAutoAdvanceNow() },
                    onCancelAutoAdvance: { vm.cancelEndedAutoAdvance() },
                    onSelectRecommendation: resolvedOnSelectEndedRecommendation
                )
                .transition(.opacity)
            }
        }
        .animation(controlAnimation, value: isPlaybackEnded)
        .simultaneousGesture(portraitOverlayPagingGesture, isEnabled: allowsOverlayPaging && isPlaybackEnded)
        .allowsHitTesting(isPlaybackEnded)
    }

    private func applyStageOverlays<Content: View>(to content: Content) -> some View {
        let isFullscreenTransitioning = surfaceRole == .fullscreen
            && PlayerFullscreenTransitionState.shared.isGeometryTransitioning
        let resolvedContainerHeight = surfaceSize.height > 0
            ? surfaceSize.height
            : (allocatedInlineViewport?.height ?? 0)
        return content
            .overlay(alignment: .bottom) {
                PlayerSubtitleOverlay(
                    player: vm,
                    isFullscreenSurface: surfaceRole == .fullscreen || isInlinePortraitImmersive,
                    portraitChromeBottomInset: isPortraitImmersiveFullscreen ? chromeInsets.bottom : 0,
                    isPortraitImmersive: isPortraitImmersiveFullscreen,
                    controlsVisible: isPortraitImmersiveFullscreen
                        ? false
                        : (vm.showControls || isPlaybackUnavailable || isPlaybackEnded),
                    bottomSafeArea: chromeInsets.bottom
                )
                .ignoresSafeArea(.keyboard, edges: .all)
            }
            .overlay(alignment: .bottom) {
                if !isPlaybackUnavailable,
                   !isPortraitImmersiveFullscreen,
                   surfaceRole == .inline || (vm.isFullscreen && !isFullscreenTransitioning) {
                    PlayerSeekStrip(
                        player: vm, owner: owner, isCurrentOwner: isOwner, gestureDisplay: gestureDisplay,
                        chromeInsets: chromeInsets,
                        inlineCornerRadius: isFullscreenPresentation ? 0 : inlineCornerRadius,
                        containerHeight: resolvedContainerHeight,
                        suppressScrubPreview: swipeSeekActive,
                        controlAnimation: controlAnimation
                    )
                    .ignoresSafeArea(.keyboard, edges: .all)
                }
            }
            .overlay(
                alignment: (isPortraitImmersiveFullscreen && !vm.portraitPureViewEnabled)
                    ? .topTrailing
                    : .bottomTrailing
            ) {
                sponsorManualSkipOverlay
            }
            .scaleEffect(portraitStageScale)
            .offset(y: portraitStageOffsetY)
            .ignoresSafeArea(.keyboard, edges: .all)
    }

    private var sponsorManualSkipOverlay: some View {
        let placesAtPortraitTop = isPortraitImmersiveFullscreen && !vm.portraitPureViewEnabled
        let hasPortraitTopNotice = isOwner && vm.activeNoticeBanner != nil
        let topPadding: CGFloat = placesAtPortraitTop
            ? (chromeInsets.top + (hasPortraitTopNotice ? 102 : 54))
            : 0
        let trailingPadding: CGFloat = placesAtPortraitTop
            ? 16
            : (isPortraitImmersiveFullscreen
                ? 20
                : ((isFullscreenPresentation ? 4 : 12) + chromeInsets.horizontal))
        let bottomPadding: CGFloat = if placesAtPortraitTop {
            0
        } else if isPortraitImmersiveFullscreen {
            24 + chromeInsets.bottom
        } else if vm.showControls || isPlaybackEnded {
            (isFullscreenPresentation ? 96 : 74) + chromeInsets.bottom
        } else {
            (isFullscreenPresentation ? (gestureDisplay.isSeeking ? 42 : 32) : 30) + chromeInsets.bottom
        }
        return ZStack(alignment: placesAtPortraitTop ? .topTrailing : .bottomTrailing) {
            if vm.mode.usesOnlineVODServices, let seg = vm.pendingSponsorManualSegment {
                Button {
                    vm.skipSponsorSegment(seg)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(seg.category.color)
                            .frame(width: 9, height: 9)
                        Text(String(format: String(localized: "Skip %@"), seg.category.displayName))
                        Image(systemName: "forward.fill")
                    }
                    .playerChromeCapsule(horizontal: 14, vertical: 9, minHeight: 44)
                }
                .padding(.top, topPadding)
                .padding(.trailing, trailingPadding)
                .padding(.bottom, bottomPadding)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(microControlAnimation, value: vm.pendingSponsorManualSegment?.uuid)
        .animation(controlAnimation, value: vm.showControls)
        .animation(microControlAnimation, value: hasPortraitTopNotice)
        .ignoresSafeArea(.keyboard, edges: .all)
    }

    private func applyPanelSheetsAndListeners<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $showSponsorBlock) {
                SponsorBlockPanel(vm: vm)
                    .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme)
            }
            .background {
                Color.clear
                    .sheet(isPresented: danmakuSheetBinding) {
                        PlayerDanmakuSettingsSheet(
                            presentation: isImmersiveStagePresentation ? .fullscreen : .inline,
                            onClose: { dismissDanmakuPanel() }
                        )
                        .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme)
                    }
            }
            .background {
                Color.clear
                    .sheet(isPresented: subtitleSheetBinding) {
                        PlayerSubtitleSettingsSheet(
                            player: vm,
                            onClose: { dismissSubtitlePanel() }
                        )
                        .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme)
                    }
            }
            .onChange(of: danmakuPanelPresented) { _, presented in
                if presented {
                    subtitlePanelPresented = false
                    landscapeSubtitleDragOffset = .zero
                } else {
                    landscapeDanmakuDragOffset = .zero
                }
                if isOwner {
                    vm.setDanmakuSettingsHold((presented && danmakuEnabled) || subtitlePanelPresented)
                }
            }
            .onChange(of: subtitlePanelPresented) { _, presented in
                if presented {
                    danmakuPanelPresented = false
                    landscapeDanmakuDragOffset = .zero
                } else {
                    landscapeSubtitleDragOffset = .zero
                }
                if isOwner {
                    vm.setDanmakuSettingsHold(presented || (danmakuPanelPresented && danmakuEnabled))
                }
            }
    }

    private func applyViewportMetrics<Content: View>(to content: Content) -> some View {
        content
            .modifier(
                PlayerViewportFrameModifier(
                    surfaceRole: surfaceRole,
                    containerAspect: containerAspect,
                    allocatedInlineViewport: allocatedInlineViewport,
                    fillsAllocatedViewport: isImmersiveStagePresentation
                )
            )
            .coordinateSpace(name: Self.surfaceCoordinateSpace)
            .background { if isImmersiveStagePresentation { Color.black } }
            .ignoresSafeArea(.keyboard, edges: .all)
            .ignoresSafeArea(.all, edges: isImmersiveStagePresentation ? .all : [])
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newValue in
                publishSurfaceSizeIfAllowed(newValue)
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                if origin.x.isFinite, origin.y.isFinite, !verticalPagingActive, !portraitDismissDragActive {
                    surfaceGlobalOrigin = origin
                }
            }
    }

    private func applyHUDOverlays<Content: View>(to content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                topHUDOverlay
            }
            .overlay(alignment: .center) {
                ZStack {
                    if verticalAdjustActive {
                        PlayerVerticalAdjustHUD(
                            gestureDisplay: gestureDisplay, verticalAdjustIsVolume: verticalAdjustIsVolume
                        )
                        .transition(.opacity)
                    }
                }
                .animation(microControlAnimation, value: verticalAdjustActive)
                .ignoresSafeArea(.keyboard, edges: .all)
            }
            .ignoresSafeArea(.keyboard, edges: .all)
            .allowsHitTesting(isOwner && surfaceLease != nil)
    }

    private var noticeTopPadding: CGFloat {
        if isPortraitImmersiveFullscreen {
            return chromeInsets.top + 56
        }
        if vm.showControls || isPlaybackUnavailable || isPlaybackEnded {
            return chromeInsets.top + (isFullscreenPresentation ? 58 : 56)
        }
        return chromeInsets.top + (isFullscreenPresentation ? 14 : 12)
    }

    private var topHUDOverlay: some View {
        VStack(spacing: 6) {
            if swipeSeekActive, (!isPortraitImmersiveFullscreen || vm.portraitPureViewEnabled) {
                PlayerSwipeSeekHUD(
                    player: vm, gestureDisplay: gestureDisplay, swipeSeekBase: swipeSeekBase
                )
                .allowsHitTesting(false)
            }
            if vm.isHoldFastForwarding {
                HStack(spacing: 5) {
                    Image(systemName: "forward.fill")
                    Text("2x")
                }
                .playerChromeCapsule()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if isOwner, let banner = vm.activeNoticeBanner {
                PlayerNoticeBannerView(banner: banner) {
                    vm.triggerNoticeBannerAction()
                }
                .allowsHitTesting(banner.isInteractive)
                .transition(.opacity)
            }
        }
        .padding(.top, noticeTopPadding)
        .animation(microControlAnimation, value: vm.isHoldFastForwarding)
        .animation(microControlAnimation, value: vm.activeNoticeBanner)
        .animation(microControlAnimation, value: vm.showControls)
        .animation(microControlAnimation, value: swipeSeekActive)
        .ignoresSafeArea(.keyboard, edges: .all)
    }

    private func applyLifecycleAndSeekObservers<Content: View>(to content: Content) -> some View {
        content
            .onAppear {
                claimScreenSurfaceIfCurrent()
            syncInlineEndedRecommendationsIfNeeded()
            scheduleHideControls()
        }
        .onDisappear {
            if let claimedSurfaceLease { vm.releaseSurfaceSlot(lease: claimedSurfaceLease) }
            claimedSurfaceLease = nil
            resetSurfaceTouch(reason: "view disappeared")
            danmakuPanelPresented = false
            portraitVerticalDragOffset = 0
            pinchTransitionLatched = false
            isDraggingHairlineBar = false
            if vm.ownerKey == owner {
                vm.setDanmakuSettingsHold(false)
                PlayerStoryboardPreviewLoader.shared.clearActivePreview()
            }
            surfaceHoldTask?.cancel()
            surfaceHoldTask = nil
            pendingTapTask?.cancel()
            pendingTapTask = nil
            doubleTapPulseClearTask?.cancel()
            doubleTapPulseClearTask = nil
            doubleTapLikePulse = nil
        }
        .onChange(of: isSurfacePressing) { _, pressing in
            if !pressing, surfaceTouchInFlight {
                resetSurfaceTouch(reason: "system-cancelled")
            }
        }
        .onChange(of: gestureDisplay.isSeeking) { _, seeking in
            guard isOwner else { return }
            if seeking {
                vm.dismissNoticeBanner(onlyIfResume: true)
                vm.cancelEndedAutoAdvance()
                vm.hideControlsTask?.cancel()
                vm.hideControlsTask = nil
                PlayerStoryboardPreviewLoader.shared.updatePreview(
                    aid: vm.currentAid,
                    cid: vm.currentCid,
                    time: gestureDisplay.seekValue,
                    isSeekableOnlineVOD: vm.mode.usesOnlineVODServices && vm.currentURL != nil
                )
            } else {
                PlayerStoryboardPreviewLoader.shared.clearActivePreview()
                scheduleHideControls()
            }
        }
        .onChange(of: gestureDisplay.seekValue) { _, targetTime in
            guard isOwner, gestureDisplay.isSeeking else { return }
            PlayerStoryboardPreviewLoader.shared.updatePreview(
                aid: vm.currentAid,
                cid: vm.currentCid,
                time: targetTime,
                isSeekableOnlineVOD: vm.mode.usesOnlineVODServices && vm.currentURL != nil
            )
        }
        .onChange(of: vm.playbackEnded) { _, ended in
            guard isOwner else { return }
            if ended {
                vm.hideControlsTask?.cancel()
                vm.hideControlsTask = nil
            } else {
                scheduleHideControls()
            }
        }
        .onChange(of: isPortraitImmersiveFullscreen, initial: true) { _, immersive in
            if immersive {
                if isOwner {
                    vm.hideControlsTask?.cancel()
                    vm.hideControlsTask = nil
                    if !vm.showControls { vm.showControls = true }
                }
            } else {
                portraitVerticalDragOffset = 0
                portraitDismissDragActive = false
                isDraggingHairlineBar = false
            }
        }
        .onChange(of: vm.showControls) { _, shown in
            guard isOwner, isPortraitImmersiveFullscreen, !shown else { return }
            vm.hideControlsTask?.cancel()
            vm.hideControlsTask = nil
            vm.showControls = true
        }
    }

    private func applyOwnershipObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: vm.ownerKey) { _, _ in
                claimScreenSurfaceIfCurrent()
                syncInlineEndedRecommendationsIfNeeded()
            }
            .onChange(of: vm.activeSurfaceLease) { _, _ in
                claimScreenSurfaceIfCurrent()
                syncInlineEndedRecommendationsIfNeeded()
            }
            .onChange(of: screenLease) { _, _ in
                claimScreenSurfaceIfCurrent()
                syncInlineEndedRecommendationsIfNeeded()
            }
            .onChange(of: endedRecommendations) { _, _ in
                syncInlineEndedRecommendationsIfNeeded()
            }
    }

    private func applyOrientationAndCollapseObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: vm.currentURL) { _, newURL in
                guard newURL != nil,
                      isOwner,
                      surfaceRole == .inline,
                      DeviceCapability.supportsOrientationLock,
                      !vm.isFullscreen,
                      !vm.isPortraitContent else { return }
                let orientation = UIDevice.current.orientation
                guard orientation.isLandscape,
                      !FullscreenOrientationLatch.shared.shouldIgnoreDeviceOrientation(
                          orientation,
                          currentFullscreen: false
                      ) else { return }
                vm.requestFullscreenTransition(target: true, source: .deviceOrientation)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                guard isOwner, DeviceCapability.supportsOrientationLock else { return }
                let orientation = UIDevice.current.orientation
                if vm.isPortraitContent, !AppOrientation.shared.mask.contains(.landscape) {
                    return
                }
                guard !FullscreenOrientationLatch.shared.shouldIgnoreDeviceOrientation(
                    orientation,
                    currentFullscreen: vm.isFullscreen
                ) else { return }
                if orientation.isLandscape, vm.currentURL != nil, !vm.isFullscreen {
                    vm.requestFullscreenTransition(target: true, source: .deviceOrientation)
                } else if orientation == .portrait, vm.isFullscreen {
                    vm.requestFullscreenTransition(target: false, source: .deviceOrientation)
                }
            }
            .onChange(of: verticalSizeClass) { _, newValue in
                guard isOwner, DeviceCapability.supportsOrientationLock else { return }
                if newValue == .regular, vm.isFullscreen, AppOrientation.shared.mask.contains(.landscape) {
                    PlayerLog.log("[Player] window rotated to portrait behind isFullscreen — reconciling")
                    vm.requestFullscreenTransition(target: false, source: .verticalSizeClass)
                } else if newValue == .compact, !vm.isFullscreen, vm.currentURL != nil,
                          !PlayerFullscreenTransitionState.shared.isHostActive {
                    PlayerLog.log("[Player] window rotated to landscape behind inline state — reconciling")
                    vm.requestFullscreenTransition(target: true, source: .verticalSizeClass)
                }
            }
            .onChange(of: vm.isFullscreen) { _, _ in
                resetSurfaceTouch(reason: "fullscreen changed")
                dismissDanmakuPanel()
                portraitVerticalDragOffset = 0
                portraitDismissDragActive = false
                pinchTransitionLatched = false
                isDraggingHairlineBar = false
                gestureDisplay.cancelSeek()
            }
            .onChange(of: isInlinePortraitImmersive) { _, _ in
                resetSurfaceTouch(reason: "inline portrait immersive changed")
                dismissDanmakuPanel()
                portraitVerticalDragOffset = 0
                portraitDismissDragActive = false
                isDraggingHairlineBar = false
                gestureDisplay.cancelSeek()
            }
            .opacity(isInlineViewportCollapsed ? 0 : 1)
            .allowsHitTesting(!isInlineViewportCollapsed)
            .accessibilityHidden(isInlineViewportCollapsed)
    }

    // MARK: - Unified Surface Gesture (tap / hold-2x / swipe-seek)

    private static let surfaceCoordinateSpace = "playerSurface"
    private static let swipeEngageDistance: CGFloat = 24
    private static let scrollRejectDistance: CGFloat = 36
    private static let portraitDismissEngageDistance: CGFloat = 28
    private static let holdMaxDrift: CGFloat = 30
    private static let tapMaxDistance: CGFloat = 24
    private static let surfaceHoldDelay: Duration = .milliseconds(200)
    private static let systemBackEdgeReserve: CGFloat = 24
    private static let portraitBackEdgeRejectLimit: CGFloat = 28
    private static let verticalAdjustHardwareStep: Double = 1.0 / 256

    private func resetSurfaceTouch(reason: String) {
        guard surfaceTouchInFlight || surfaceHoldEngaged || swipeSeekActive || swipeSeekRejected
                || verticalAdjustActive || verticalPagingActive || portraitDismissDragActive else { return }
        PlayerLog.log("[PlayerGesture] reset (\(reason))")
        surfaceHoldTask?.cancel()
        surfaceHoldTask = nil
        pendingTapTask?.cancel()
        pendingTapTask = nil
        if surfaceHoldEngaged {
            surfaceHoldEngaged = false
            if isOwner { vm.endHoldFastForward() }
        }
        if swipeSeekActive {
            swipeSeekActive = false
            gestureDisplay.cancelSeek()
        }
        if verticalPagingActive {
            verticalPagingActive = false
            verticalPagingGestureSink?.cancel()
        }
        if portraitDismissDragActive {
            portraitDismissDragActive = false
            if portraitVerticalDragOffset != 0 {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
                    portraitVerticalDragOffset = 0
                }
            }
        }
        verticalAdjustActive = false
        swipeSeekRejected = false
        surfaceTouchInFlight = false
        surfaceDrag.reset()
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isOwner, surfaceLease != nil, vm.mode != .live,
                      (isPortraitImmersiveFullscreen || vm.isPortraitContent) else { return }
                let scale = value.magnification
                if abs(scale - 1.0) > 0.04 {
                    surfaceHoldTask?.cancel()
                    swipeSeekRejected = true
                }
                guard !pinchTransitionLatched else { return }
                if !isPortraitImmersiveFullscreen {
                    if scale > 1.18 {
                        pinchTransitionLatched = true
                        resetSurfaceTouch(reason: "pinch-out to immersive")
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        PlayerLog.log("[PlayerGesture] portrait pinch-out → immersive")
                        vm.requestFullscreenTransition(target: true, source: .button)
                    }
                } else if scale > 1.18 {
                    if !vm.portraitPureViewEnabled {
                        pinchTransitionLatched = true
                        resetSurfaceTouch(reason: "pinch-out to pure view")
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        PlayerLog.log("[PlayerGesture] portrait pinch-out → pure view")
                        vm.portraitPureViewEnabled = true
                    }
                } else if scale < 0.84 {
                    pinchTransitionLatched = true
                    resetSurfaceTouch(reason: "pinch-in from immersive")
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if vm.portraitPureViewEnabled {
                        PlayerLog.log("[PlayerGesture] portrait pinch-in → exit pure view")
                        vm.portraitPureViewEnabled = false
                    } else {
                        PlayerLog.log("[PlayerGesture] portrait pinch-in → collapse to detail")
                        if let collapse = activePortraitFullscreenContext?.onCollapseToDetail {
                            collapse()
                        } else {
                            vm.requestFullscreenTransition(target: false, source: .button)
                        }
                    }
                }
            }
            .onEnded { _ in
                pinchTransitionLatched = false
            }
    }

    private var portraitOverlayPagingGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($isSurfacePressing) { _, pressing, _ in
                pressing = true
            }
            .onChanged { gesture in
                guard isOwner,
                      surfaceLease != nil,
                      isPortraitImmersiveFullscreen,
                      let verticalPagingGestureSink,
                      !pinchTransitionLatched else { return }
                if surfaceTouchInFlight, gesture.startLocation != surfaceGlobalStartLocation {
                    resetSurfaceTouch(reason: "stale overlay touch")
                }
                let dx = gesture.translation.width
                let dy = gesture.translation.height
                if !surfaceTouchInFlight {
                    surfaceTouchInFlight = true
                    surfaceGlobalStartLocation = gesture.startLocation
                    surfaceStartLocation = CGPoint(
                        x: gesture.startLocation.x - surfaceGlobalOrigin.x,
                        y: gesture.startLocation.y - surfaceGlobalOrigin.y
                    )
                    surfaceDrag.reset()
                    swipeSeekRejected = false
                }
                if swipeSeekRejected { return }
                if verticalPagingActive {
                    verticalPagingGestureSink.change(dy)
                    return
                }
                if surfaceStartLocation.x <= Self.portraitBackEdgeRejectLimit,
                   dx > 0, dx >= abs(dy) {
                    swipeSeekRejected = true
                    return
                }
                if abs(dy) > Self.portraitDismissEngageDistance,
                   abs(dy) > abs(dx) * 1.15 {
                    guard verticalPagingGestureSink.begin() else {
                        swipeSeekRejected = true
                        return
                    }
                    verticalPagingActive = true
                    verticalPagingGestureSink.change(dy)
                    PlayerLog.log("[PlayerGesture] portrait overlay vertical paging engaged")
                } else if abs(dx) > Self.swipeEngageDistance,
                          abs(dx) > abs(dy) * 1.2 {
                    swipeSeekRejected = true
                }
            }
            .onEnded { gesture in
                defer {
                    surfaceTouchInFlight = false
                    swipeSeekRejected = false
                    surfaceDrag.reset()
                }
                if verticalPagingActive {
                    verticalPagingActive = false
                    verticalPagingGestureSink?.end(
                        gesture.translation.height,
                        gesture.predictedEndTranslation.height
                    )
                }
            }
    }

    private var surfaceGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isSurfacePressing) { _, pressing, _ in
                pressing = true
            }
            .onChanged { gesture in
                guard isOwner, surfaceLease != nil, !pinchTransitionLatched else { return }
                if surfaceTouchInFlight, gesture.startLocation != surfaceGlobalStartLocation {
                    resetSurfaceTouch(reason: "stale touch — previous one was system-cancelled")
                }

                let dx = gesture.translation.width
                let dy = gesture.translation.height

                if !surfaceTouchInFlight {
                    surfaceTouchInFlight = true
                    surfaceGlobalStartLocation = gesture.startLocation
                    surfaceStartLocation = CGPoint(
                        x: gesture.startLocation.x - surfaceGlobalOrigin.x,
                        y: gesture.startLocation.y - surfaceGlobalOrigin.y
                    )
                    surfaceDrag.reset()
                    surfaceHoldEngaged = false
                    swipeSeekRejected = false
                    surfaceHoldTask?.cancel()
                    surfaceHoldTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.surfaceHoldDelay)
                        guard !Task.isCancelled, isOwner, surfaceLease != nil, surfaceTouchInFlight,
                              !swipeSeekActive, !swipeSeekRejected, !verticalAdjustActive,
                              !verticalPagingActive, !portraitDismissDragActive, !pinchTransitionLatched,
                              hypot(surfaceDrag.translation.width, surfaceDrag.translation.height) < Self.holdMaxDrift,
                              vm.supportsHoldFastForward, vm.isPlaying else { return }
                        surfaceHoldEngaged = true
                        let wall = CFAbsoluteTimeGetCurrent()
                        PlayerLog.log(String(format: "[PlayerGesture] hold → 2x ON wall=%.3f", wall))
                        vm.beginHoldFastForward()
                    }
                }

                if surfaceHoldEngaged || swipeSeekRejected { return }
                surfaceDrag.translation = gesture.translation

                if !swipeSeekActive, !verticalAdjustActive, !verticalPagingActive, !portraitDismissDragActive {
                    if isPortraitImmersiveFullscreen,
                       surfaceStartLocation.x <= Self.portraitBackEdgeRejectLimit,
                       dx > 0, dx >= abs(dy) {
                        surfaceHoldTask?.cancel()
                        swipeSeekRejected = true
                        return
                    }
                    if !isPortraitImmersiveFullscreen,
                       abs(dx) > Self.swipeEngageDistance,
                       abs(dx) > abs(dy) * 1.2 {
                        surfaceHoldTask?.cancel()
                        guard vm.mode.isSeekable, vm.currentURL != nil, vm.duration > 0 else {
                            swipeSeekRejected = true
                            return
                        }
                        swipeSeekActive = true
                        swipeSeekBase = vm.displayTime
                        gestureDisplay.seekValue = swipeSeekBase
                        isSeeking = true
                        PlayerLog.log("[PlayerGesture] swipe-seek engaged at \(Int(swipeSeekBase))s")
                    } else if isPortraitImmersiveFullscreen,
                              abs(dy) > Self.portraitDismissEngageDistance,
                              abs(dy) > abs(dx) * 1.15 {
                        surfaceHoldTask?.cancel()
                        if let verticalPagingGestureSink {
                            guard verticalPagingGestureSink.begin() else {
                                swipeSeekRejected = true
                                return
                            }
                            verticalPagingActive = true
                            verticalPagingGestureSink.change(dy)
                            PlayerLog.log("[PlayerGesture] portrait immersive vertical paging engaged")
                            return
                        }
                        portraitDismissDragActive = true
                        portraitVerticalDragOffset = dy
                        return
                    } else if isPortraitImmersiveFullscreen,
                              abs(dx) > Self.swipeEngageDistance,
                              abs(dx) > abs(dy) * 1.2 {
                        surfaceHoldTask?.cancel()
                        swipeSeekRejected = true
                        return
                    } else if !isPortraitImmersiveFullscreen,
                              abs(dy) > Self.scrollRejectDistance,
                              abs(dy) >= abs(dx) {
                        if let verticalPagingGestureSink {
                            surfaceHoldTask?.cancel()
                            guard verticalPagingGestureSink.begin() else {
                                swipeSeekRejected = true
                                return
                            }
                            verticalPagingActive = true
                            verticalPagingGestureSink.change(dy)
                            return
                        }
                        surfaceHoldTask?.cancel()
                        let fallbackSize = WindowMetricsFallback.currentSize
                        let width = surfaceSize.width > 0 ? surfaceSize.width : fallbackSize.width
                        verticalAdjustIsVolume = surfaceStartLocation.x > width / 2
                        verticalAdjustBase = verticalAdjustIsVolume
                            ? Double(SystemVolumeController.shared.volume)
                            : Double(AppWindowMetrics.current?.windowScene?.screen.brightness ?? 0.5)
                        gestureDisplay.verticalAdjustValue = verticalAdjustBase
                        verticalAdjustActive = true
                        PlayerLog.log("[PlayerGesture] vertical \(verticalAdjustIsVolume ? "volume" : "brightness") engaged at \(Int(verticalAdjustBase * 100))%")
                    } else {
                        return
                    }
                }

                if portraitDismissDragActive {
                    portraitVerticalDragOffset = dy
                    return
                }

                if verticalPagingActive {
                    verticalPagingGestureSink?.change(dy)
                    return
                }

                if verticalAdjustActive {
                    let fallbackHeight = WindowMetricsFallback.currentSize.height
                    let height = Double(surfaceSize.height > 0 ? surfaceSize.height : fallbackHeight)
                    let value = min(max(verticalAdjustBase - Double(dy) / height, 0), 1)
                    gestureDisplay.verticalAdjustValue = value
                    let applied = surfaceDrag.appliedAdjust
                    guard applied == nil
                        || abs(value - (applied ?? 0)) >= Self.verticalAdjustHardwareStep
                        || value == 0 || value == 1
                    else { return }
                    surfaceDrag.appliedAdjust = value
                    if verticalAdjustIsVolume {
                        SystemVolumeController.shared.setVolume(Float(value))
                    } else {
                        AppWindowMetrics.current?.windowScene?.screen.brightness = CGFloat(value)
                    }
                    return
                }

                let width = max(surfaceSize.width > 0 ? surfaceSize.width : WindowMetricsFallback.currentWidth, 1)
                let span = min(max(vm.duration * 0.25, 60), 300)
                let target = swipeSeekBase + Double(dx / width) * span
                gestureDisplay.seekValue = min(max(target, 0), vm.duration)
            }
            .onEnded { gesture in
                guard isOwner, surfaceLease != nil else {
                    resetSurfaceTouch(reason: "surface retired")
                    return
                }
                surfaceHoldTask?.cancel()
                surfaceHoldTask = nil
                surfaceTouchInFlight = false
                defer { swipeSeekRejected = false }

                if pinchTransitionLatched {
                    return
                }

                if surfaceHoldEngaged {
                    surfaceHoldEngaged = false
                    let wall = CFAbsoluteTimeGetCurrent()
                    PlayerLog.log(String(format: "[PlayerGesture] hold → 2x OFF wall=%.3f", wall))
                    vm.endHoldFastForward()
                    return
                }
                if swipeSeekActive {
                    swipeSeekActive = false
                    isSeeking = false
                    PlayerLog.log("[PlayerGesture] swipe-seek commit → \(Int(gestureDisplay.seekValue))s")
                    vm.seek(to: gestureDisplay.seekValue)
                    return
                }
                if portraitDismissDragActive {
                    portraitDismissDragActive = false
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
                        portraitVerticalDragOffset = 0
                    }
                    return
                }
                if verticalPagingActive {
                    verticalPagingActive = false
                    verticalPagingGestureSink?.end(
                        gesture.translation.height,
                        gesture.predictedEndTranslation.height
                    )
                    return
                }
                if verticalAdjustActive {
                    verticalAdjustActive = false
                    PlayerLog.log(
                        "[PlayerGesture] vertical adjust commit → \(Int(gestureDisplay.verticalAdjustValue * 100))%"
                    )
                    return
                }
                let moved = hypot(gesture.translation.width, gesture.translation.height)
                if !swipeSeekRejected, moved <= Self.tapMaxDistance {
                    if isPortraitImmersiveFullscreen {
                        if pendingTapTask != nil {
                            pendingTapTask?.cancel()
                            pendingTapTask = nil
                            if let onDoubleTapLike = activePortraitFullscreenContext?.onDoubleTapLike {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                let localTapLocation = CGPoint(
                                    x: gesture.location.x - surfaceGlobalOrigin.x,
                                    y: gesture.location.y - surfaceGlobalOrigin.y
                                )
                                triggerDoubleTapLikePulse(at: localTapLocation)
                                PlayerLog.log("[PlayerGesture] portrait double-tap → like")
                                Task { await onDoubleTapLike() }
                            } else {
                                PlayerLog.log("[PlayerGesture] portrait double-tap → fallback togglePlayPause")
                                vm.togglePlayPause()
                            }
                        } else {
                            pendingTapTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(220))
                                guard !Task.isCancelled, isOwner, surfaceLease != nil else { return }
                                pendingTapTask = nil
                                PlayerLog.log("[PlayerGesture] portrait single-tap → \(vm.isPlaying ? "pause" : "play")")
                                vm.togglePlayPause()
                            }
                        }
                    } else {
                        if pendingTapTask != nil {
                            pendingTapTask?.cancel()
                            pendingTapTask = nil
                            PlayerLog.log("[PlayerGesture] double-tap → \(vm.isPlaying ? "pause" : "play")")
                            vm.togglePlayPause()
                        } else {
                            pendingTapTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(280))
                                guard !Task.isCancelled, isOwner, surfaceLease != nil else { return }
                                pendingTapTask = nil
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    vm.showControls.toggle()
                                }
                                scheduleHideControls()
                            }
                        }
                    }
                }
            }
    }

    private func triggerDoubleTapLikePulse(at location: CGPoint) {
        let pulse = PortraitDoubleTapPulse(location: location)
        doubleTapLikePulse = pulse
        doubleTapPulseClearTask?.cancel()
        doubleTapPulseClearTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, doubleTapLikePulse?.id == pulse.id else { return }
            doubleTapLikePulse = nil
        }
    }

    // MARK: - Helpers

    private var surfaceGeometryPublicationContext: PlayerSurfaceGeometryPublicationPolicy.Context {
        let deviceClass: PlayerSurfaceGeometryPublicationPolicy.DeviceClass
        if DeviceCapability.supportsOrientationLock {
            deviceClass = .iPhone
        } else if DeviceCapability.supportsPadDetailSplit {
            deviceClass = .iPad
        } else {
            deviceClass = .other
        }

        let sceneSizeClass: PlayerSurfaceGeometryPublicationPolicy.SceneSizeClass
        if verticalSizeClass == .compact {
            sceneSizeClass = .compact
        } else if verticalSizeClass == .regular {
            sceneSizeClass = .regular
        } else {
            sceneSizeClass = .unknown
        }

        return .init(
            isFullscreen: vm.isFullscreen,
            sceneSizeClass: sceneSizeClass,
            deviceClass: deviceClass
        )
    }

    private func publishSurfaceSizeIfAllowed(_ candidateSize: CGSize) {
        let decision = PlayerSurfaceGeometryPublicationPolicy.decision(
            for: candidateSize,
            context: surfaceGeometryPublicationContext,
            currentPublishedSize: surfaceSize
        )
        if case let .publish(publishedSize) = decision {
            surfaceSize = publishedSize
        }
    }

    private func scheduleHideControls() {
        guard isOwner else { return }
        if isPortraitImmersiveFullscreen {
            vm.hideControlsTask?.cancel()
            vm.hideControlsTask = nil
            if !vm.showControls { vm.showControls = true }
            return
        }
        vm.scheduleHideControls(isSeeking: gestureDisplay.isSeeking)
    }
}

private struct PlayerFirstFrameCoverOverlay: View {
    let coverURL: String?
    let viewportSize: CGSize?
    let showsProgress: Bool
    var isPortraitImmersive: Bool = false

    @State private var delayedSpinnerVisible = false

    private static func quantizedBudget(for size: CGSize) -> CGSize {
        let quantum = PortraitPagingReducer.coverBoxQuantum
        return CGSize(
            width: (size.width / quantum).rounded(.up) * quantum,
            height: (size.height / quantum).rounded(.up) * quantum
        )
    }

    private var usesAmbientPortraitLayers: Bool {
        if isPortraitImmersive { return true }
        guard let size = viewportSize, size.width > 1, size.height > 1 else { return false }
        return size.height > size.width * 1.05
    }

    var body: some View {
        ZStack {
            Color.black
            if let coverURL, !coverURL.isEmpty {
                if usesAmbientPortraitLayers,
                   let pageSize = viewportSize,
                   pageSize.width > 1,
                   pageSize.height > 1 {
                    PortraitPagerCoverLayers(
                        coverURL: coverURL,
                        pageSize: pageSize,
                        resolutionBudget: Self.quantizedBudget(for: pageSize)
                    )
                    if !isPortraitImmersive {
                        Color.black.opacity(0.12)
                    }
                } else {
                    CoverImage(
                        urlString: coverURL,
                        displaySize: viewportSize,
                        contentMode: .fit,
                        groundColor: .black,
                        isDecorative: true,
                        fillsOfferedBox: viewportSize != nil
                    )
                    Color.black.opacity(0.18)
                }
            }
            if showsProgress && (!isPortraitImmersive || delayedSpinnerVisible) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: isPortraitImmersive && showsProgress) {
            guard isPortraitImmersive, showsProgress else {
                delayedSpinnerVisible = false
                return
            }
            delayedSpinnerVisible = false
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            delayedSpinnerVisible = true
        }
    }
}

private struct PlayerViewportFrameModifier: ViewModifier {
    let surfaceRole: PlayerSurfaceRole
    let containerAspect: CGFloat
    let allocatedInlineViewport: CGSize?
    let fillsAllocatedViewport: Bool

    func body(content: Content) -> some View {
        if surfaceRole == .fullscreen {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if fillsAllocatedViewport {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: allocatedInlineViewport?.width, height: allocatedInlineViewport?.height)
        } else {
            content
                .frame(maxWidth: .infinity)
                .aspectRatio(containerAspect, contentMode: .fit)
                .frame(width: allocatedInlineViewport?.width, height: allocatedInlineViewport?.height)
        }
    }
}

private struct PlayerPlaybackErrorOverlay: View {
    let message: String
    let unavailability: PlaybackUnavailability?
    let isFullscreen: Bool
    let chromeInsets: PlayerChromeInsets
    let onRetry: () -> Void

    private var title: LocalizedStringKey {
        unavailability == nil ? "Playback Failed" : "Playback Unavailable"
    }

    private var symbolName: String {
        unavailability?.symbolName ?? "exclamationmark.triangle.fill"
    }

    private var canRetry: Bool {
        unavailability?.isRetryable ?? true
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)

            VStack(spacing: isFullscreen ? 10 : 6) {
                if isFullscreen {
                    Image(systemName: symbolName)
                        .font(.title2)
                        .foregroundStyle(unavailability == nil ? .yellow : .white.opacity(0.85))
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: symbolName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(unavailability == nil ? .yellow : .white.opacity(0.85))
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }

                Text(message)
                    .font(isFullscreen ? .footnote : .caption)
                    .foregroundStyle(.white.opacity(0.84))
                    .multilineTextAlignment(.center)
                    .lineLimit(isFullscreen ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: isFullscreen ? 380 : 300)

                if canRetry {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(isFullscreen ? .regular : .small)
                    .tint(Color.biliAccent)
                    .padding(.top, 4)
                    .accessibilityIdentifier("player.retryButton")
                }
            }
            .padding(.top, isFullscreen ? (chromeInsets.top + 56) : (chromeInsets.top + 38))
            .padding(.bottom, isFullscreen ? (chromeInsets.bottom + 16) : 12)
            .padding(.horizontal, isFullscreen ? (chromeInsets.horizontal + 24) : 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard, edges: .all)
        .environment(\.colorScheme, .dark)
    }
}

private struct PlayerPlaybackEndedOverlay: View {
    let isFullscreen: Bool
    var isPortraitFullscreen = false
    let chromeInsets: PlayerChromeInsets
    let transportPlacement: PlayerTransportPlacement
    let autoAdvance: PlayerEndedAutoAdvanceState?
    let recommendations: [PlayerEndedRecommendation]
    let onReplay: () -> Void
    let onNextEpisode: (() -> Void)?
    let onPlayAutoAdvanceNow: () -> Void
    let onCancelAutoAdvance: () -> Void
    let onSelectRecommendation: ((PlayerEndedRecommendation) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var topClearance: CGFloat {
        isFullscreen ? (chromeInsets.top + 60) : (chromeInsets.top + 52)
    }

    private var bottomClearance: CGFloat {
        guard transportPlacement == .playerBottomEdge else {
            return chromeInsets.bottom + 16
        }
        return isFullscreen ? (chromeInsets.bottom + 102) : (chromeInsets.bottom + 84)
    }

    private var horizontalInset: CGFloat {
        if isPortraitFullscreen {
            return max(16, chromeInsets.horizontal)
        }
        return isFullscreen ? (chromeInsets.horizontal + 24) : (chromeInsets.horizontal + 14)
    }

    private var progressAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
    }

    private var selectableRecommendations: [PlayerEndedRecommendation] {
        guard onSelectRecommendation != nil else { return [] }
        return Array(recommendations.prefix(3))
    }

    var body: some View {
        ZStack {
            endedBackdrop

            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - horizontalInset * 2)
                let availableHeight = max(0, proxy.size.height - topClearance - bottomClearance)
                if availableWidth > 1, availableHeight > 1 {
                    Group {
                        if availableHeight < 136 {
                            compactContent(
                                totalHeight: proxy.size.height,
                                availableWidth: availableWidth,
                                availableHeight: availableHeight
                            )
                        } else if availableHeight < 252 {
                            mediumContent(
                                availableWidth: availableWidth,
                                availableHeight: availableHeight
                            )
                        } else {
                            spaciousContent(
                                availableWidth: availableWidth,
                                availableHeight: availableHeight
                            )
                        }
                    }
                    .frame(width: availableWidth, height: availableHeight, alignment: .center)
                    .padding(.top, topClearance)
                    .padding(.bottom, bottomClearance)
                    .padding(.horizontal, horizontalInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard, edges: .all)
        .environment(\.colorScheme, .dark)
    }

    private var endedBackdrop: some View {
        ZStack {
            if reduceTransparency {
                Color.black.opacity(0.86)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.55)
                Color.black.opacity(0.62)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.32), location: 0),
                        .init(color: .clear, location: 0.28),
                        .init(color: .clear, location: 0.72),
                        .init(color: .black.opacity(0.38), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    // MARK: - Adaptive Tiers

    @ViewBuilder
    private func compactContent(
        totalHeight: CGFloat,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        if let countdown = autoAdvance {
            compactCountdownBanner(countdown, maxWidth: min(availableWidth, 390))
        } else {
            let showMiniRecommendation = !selectableRecommendations.isEmpty
                && totalHeight >= 205
                && availableHeight >= 74
            VStack(spacing: showMiniRecommendation ? 7 : 6) {
                if !showMiniRecommendation, availableHeight >= 56 {
                    Text("Playback Ended")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                }
                actionButtonsRow(compact: true)
                if showMiniRecommendation, let first = selectableRecommendations.first {
                    compactRecommendationMiniCard(first, maxWidth: min(availableWidth, 352))
                }
            }
        }
    }

    @ViewBuilder
    private func mediumContent(
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let recs = visibleRecommendations(for: availableWidth)
        let showsRecommendations = !recs.isEmpty && availableHeight >= 156
        VStack(spacing: showsRecommendations ? 12 : 14) {
            if let countdown = autoAdvance {
                countdownBanner(
                    countdown,
                    maxWidth: min(availableWidth, 560),
                    showsReplayAction: !showsRecommendations
                )
            } else if showsRecommendations {
                HStack(spacing: 12) {
                    Text("Playback Ended")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    actionButtonsRow(compact: true)
                }
            } else {
                VStack(spacing: 10) {
                    Text("Playback Ended")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    actionButtonsRow(compact: false)
                }
            }

            if showsRecommendations {
                let headerReserve: CGFloat = autoAdvance != nil ? 86 : 44
                let cardAreaHeight = max(84, availableHeight - headerReserve)
                recommendationCardsRow(
                    recs,
                    availableWidth: min(availableWidth, 660),
                    maxCardHeight: cardAreaHeight,
                    showsSectionLabel: false
                )
            }
        }
    }

    @ViewBuilder
    private func spaciousContent(
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let recs = visibleRecommendations(for: availableWidth)
        VStack(spacing: 18) {
            if let countdown = autoAdvance {
                VStack(spacing: 12) {
                    countdownBanner(
                        countdown,
                        maxWidth: min(availableWidth, 540),
                        showsReplayAction: false
                    )
                    Button(action: onReplay) {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.white)
                    .accessibilityIdentifier("player.replayButton")
                }
            } else {
                VStack(spacing: 12) {
                    Text("Playback Ended")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    actionButtonsRow(compact: false)
                }
            }

            if !recs.isEmpty {
                let headerReserve: CGFloat = autoAdvance != nil ? 136 : 92
                let cardAreaHeight = max(120, min(availableHeight - headerReserve, 220))
                recommendationCardsRow(
                    recs,
                    availableWidth: min(availableWidth, 700),
                    maxCardHeight: cardAreaHeight,
                    showsSectionLabel: true
                )
            }
        }
    }

    // MARK: - Actions & Countdown

    private func actionButtonsRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Button(action: onReplay) {
                Label("Replay", systemImage: "arrow.counterclockwise")
                    .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(compact ? .small : .regular)
            .tint(Color.biliAccent)
            .accessibilityIdentifier("player.replayButton")

            if let onNextEpisode {
                Button(action: onNextEpisode) {
                    Label("Next Episode", systemImage: "forward.end.fill")
                        .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(compact ? .small : .regular)
                .tint(.white)
                .accessibilityIdentifier("player.endedNextEpisodeButton")
            }
        }
    }

    private func compactCountdownBanner(
        _ countdown: PlayerEndedAutoAdvanceState,
        maxWidth: CGFloat
    ) -> some View {
        HStack(spacing: 10) {
            countdownRing(countdown, size: 30, lineWidth: 2.5)

            VStack(alignment: .leading, spacing: 3) {
                Text("Up next in \(countdown.remainingSeconds)s")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .monospacedDigit()
                    .lineLimit(1)

                countdownTitleText(countdown)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                countdownProgressBar(countdown, height: 2.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button(action: onPlayAutoAdvanceNow) {
                    Label("Play Now", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .tint(Color.biliAccent)
                .accessibilityIdentifier("player.endedAutoAdvancePlayNow")

                Button(action: onCancelAutoAdvance) {
                    Text("Cancel")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .tint(.white)
                .accessibilityIdentifier("player.endedAutoAdvanceCancel")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: maxWidth)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                )
        )
    }

    private func countdownBanner(
        _ countdown: PlayerEndedAutoAdvanceState,
        maxWidth: CGFloat,
        showsReplayAction: Bool
    ) -> some View {
        HStack(spacing: 12) {
            if let coverURL = countdown.coverURL, !coverURL.isEmpty {
                ZStack {
                    CoverImage(
                        urlString: coverURL,
                        displaySize: CGSize(width: 80, height: 45),
                        contentMode: .fill,
                        requestsServerCrop: true,
                        groundColor: Color.white.opacity(0.08),
                        fillsOfferedBox: true
                    )
                    .frame(width: 80, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Color.black.opacity(0.32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    countdownRing(countdown, size: 28, lineWidth: 2.5)
                }
                .frame(width: 80, height: 45)
            } else {
                countdownRing(countdown, size: 38, lineWidth: 3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Up next in \(countdown.remainingSeconds)s")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .monospacedDigit()
                    .lineLimit(1)

                countdownTitleText(countdown)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let author = countdown.authorName, !author.isEmpty {
                    Text(verbatim: author)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                countdownProgressBar(countdown, height: 3)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if showsReplayAction {
                    Button(action: onReplay) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .tint(.white)
                    .accessibilityIdentifier("player.replayButton")
                    .accessibilityLabel(Text("Replay"))
                }

                Button(action: onPlayAutoAdvanceNow) {
                    Label("Play Now", systemImage: "play.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Color.biliAccent)
                .accessibilityIdentifier("player.endedAutoAdvancePlayNow")

                Button(action: onCancelAutoAdvance) {
                    Text("Cancel")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.white)
                .accessibilityIdentifier("player.endedAutoAdvanceCancel")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: maxWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                )
        )
    }

    private func countdownTitleText(_ countdown: PlayerEndedAutoAdvanceState) -> Text {
        if let title = countdown.title, !title.isEmpty {
            return Text(verbatim: title)
        }
        return Text("Next Episode")
    }

    private func countdownRing(
        _ countdown: PlayerEndedAutoAdvanceState,
        size: CGFloat,
        lineWidth: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.24), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.08, countdown.progress)))
                .stroke(
                    Color.biliAccent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(progressAnimation, value: countdown.remainingSeconds)
            Text(verbatim: "\(max(0, countdown.remainingSeconds))")
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func countdownProgressBar(
        _ countdown: PlayerEndedAutoAdvanceState,
        height: CGFloat
    ) -> some View {
        GeometryReader { barProxy in
            let filledWidth = max(0, barProxy.size.width * CGFloat(min(max(countdown.progress, 0.08), 1)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(Color.biliAccent)
                    .frame(width: filledWidth)
                    .animation(progressAnimation, value: countdown.remainingSeconds)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    // MARK: - Recommendations

    private func visibleRecommendations(for availableWidth: CGFloat) -> [PlayerEndedRecommendation] {
        let maxCount: Int
        if availableWidth >= 460 {
            maxCount = 3
        } else if availableWidth >= 300 {
            maxCount = 2
        } else {
            maxCount = 1
        }
        return Array(selectableRecommendations.prefix(maxCount))
    }

    private func compactRecommendationMiniCard(
        _ recommendation: PlayerEndedRecommendation,
        maxWidth: CGFloat
    ) -> some View {
        Button {
            onSelectRecommendation?(recommendation)
        } label: {
            HStack(spacing: 8) {
                recommendationThumbnail(
                    coverURL: recommendation.coverURL,
                    durationSeconds: recommendation.durationSeconds,
                    size: CGSize(width: 64, height: 36),
                    cornerRadius: 6,
                    compactBadge: true
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: recommendation.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !recommendation.authorName.isEmpty {
                        Text(verbatim: recommendation.authorName)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: maxWidth)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.endedRecommendation.\(recommendation.id)")
    }

    private func recommendationCardsRow(
        _ items: [PlayerEndedRecommendation],
        availableWidth: CGFloat,
        maxCardHeight: CGFloat,
        showsSectionLabel: Bool
    ) -> some View {
        let spacing: CGFloat = 12
        let count = CGFloat(max(items.count, 1))
        let labelReserve: CGFloat = showsSectionLabel ? 20 : 0
        let textReserve: CGFloat = maxCardHeight >= 155 ? 52 : 42
        let maxThumbHeight = max(56, maxCardHeight - labelReserve - textReserve)
        let widthLimitedCard = (availableWidth - spacing * (count - 1)) / count
        let heightLimitedCard = maxThumbHeight * 16.0 / 9.0
        let cardWidth = max(min(availableWidth, 120), min(widthLimitedCard, heightLimitedCard, 216))
        let thumbHeight = max(1, (cardWidth * 9.0 / 16.0).rounded())
        let titleLines = maxCardHeight >= 155 ? 2 : 1
        let totalRowWidth = cardWidth * count + spacing * (count - 1)

        return VStack(alignment: .leading, spacing: 8) {
            if showsSectionLabel {
                Text("Recommended")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }

            HStack(alignment: .top, spacing: spacing) {
                ForEach(items) { recommendation in
                    Button {
                        onSelectRecommendation?(recommendation)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            recommendationThumbnail(
                                coverURL: recommendation.coverURL,
                                durationSeconds: recommendation.durationSeconds,
                                size: CGSize(width: cardWidth, height: thumbHeight),
                                cornerRadius: 8,
                                compactBadge: false
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: recommendation.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(titleLines)
                                    .truncationMode(.tail)
                                    .multilineTextAlignment(.leading)

                                if !recommendation.authorName.isEmpty {
                                    Text(verbatim: recommendation.authorName)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.68))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                        }
                        .frame(width: cardWidth, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.endedRecommendation.\(recommendation.id)")
                }
            }
        }
        .frame(maxWidth: totalRowWidth)
    }

    private func recommendationThumbnail(
        coverURL: String?,
        durationSeconds: Int?,
        size: CGSize,
        cornerRadius: CGFloat,
        compactBadge: Bool
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let coverURL, !coverURL.isEmpty {
                CoverImage(
                    urlString: coverURL,
                    displaySize: size,
                    contentMode: .fill,
                    requestsServerCrop: true,
                    groundColor: Color.white.opacity(0.08),
                    fillsOfferedBox: true
                )
                .frame(width: size.width, height: size.height)
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .frame(width: size.width, height: size.height)
            }

            if let durationSeconds, let formatted = Self.formattedDuration(durationSeconds) {
                Text(verbatim: formatted)
                    .font(.system(size: compactBadge ? 9 : 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, compactBadge ? 4 : 5)
                    .padding(.vertical, compactBadge ? 1 : 2)
                    .background(
                        Color.black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                    .padding(compactBadge ? 3 : 5)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private static func formattedDuration(_ totalSeconds: Int) -> String? {
        guard totalSeconds > 0 else { return nil }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
