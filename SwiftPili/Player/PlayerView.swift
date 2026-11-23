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
        let begin: @MainActor () -> Bool
        let change: @MainActor (CGFloat) -> Void
        let end: @MainActor (CGFloat, CGFloat) -> Void
        let cancel: @MainActor () -> Void
    }

    private var handlers: Handlers?

    @MainActor
    func install(_ handlers: Handlers) {
        self.handlers = handlers
        UIHitchMonitor.count("sink")
    }

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
    let fullscreenSafeAreaInsets: EdgeInsets?
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?

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
        fullscreenSafeAreaInsets: EdgeInsets? = nil,
        screenLease: PlayerOwnerLease? = nil,
        presentationReceipt: PlayerPresentationReceipt? = nil,
        fullscreenHostIdentity: UUID? = nil,
        gestureDisplay: PlayerGestureDisplay = PlayerGestureDisplay()
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
        self.fullscreenSafeAreaInsets = fullscreenSafeAreaInsets
        self.screenLease = screenLease
        self.presentationReceipt = presentationReceipt
        self.fullscreenHostIdentity = fullscreenHostIdentity
        _gestureDisplay = State(initialValue: gestureDisplay)
    }

    private var vm: PlayerViewModel { PlayerViewModel.shared }
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @State private var danmakuPanelPresented = false
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
    @State private var surfaceSize: CGSize = .zero
    @GestureState private var isSurfacePressing = false
    @State private var surfaceTouchInFlight = false
    @State private var surfaceHoldEngaged = false
    private var surfaceOwnsTouch: Bool {
        surfaceHoldEngaged || swipeSeekActive || verticalAdjustActive || verticalPagingActive
    }
    @State private var surfaceHoldTask: Task<Void, Never>?
    @State private var pendingTapTask: Task<Void, Never>?
    @State private var surfaceDrag = PlayerSurfaceDragStore()
    @State private var surfaceStartLocation: CGPoint = .zero
    @State private var showSponsorBlock = false

    private var allocatedInlineViewport: CGSize? {
        guard !vm.isFullscreen, let size = inlineViewportSize,
              size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { return nil }
        return size
    }

    private var isInlineViewportCollapsed: Bool {
        guard let size = allocatedInlineViewport else { return false }
        return size.width == 0 || size.height == 0
    }

    private var containerAspect: CGFloat {
        if vm.isFullscreen {
            return fullscreenViewportAspect ?? PlayerFullscreenViewportPolicy.fallbackAspect
        }
        if let size = allocatedInlineViewport, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        if vm.isPortraitContent, vm.mode != .live {
            return vm.inlineCondensed ? 16.0 / 9.0 : 3.0 / 4.0
        }
        return 16.0 / 9.0
    }

    private var chromeInsets: PlayerChromeInsets {
        let insets = fullscreenSafeAreaInsets ?? {
            let window = AppWindowMetrics.safeAreaInsets
            return EdgeInsets(top: window.top, leading: window.left, bottom: window.bottom, trailing: window.right)
        }()
        return PlayerChromeInsets.resolve(
            presentation: resolvedPresentation,
            windowTop: insets.top,
            windowBottom: insets.bottom,
            windowLeft: insets.leading,
            windowRight: insets.trailing
        )
    }

    private var resolvedPresentation: PlayerContainerPresentation {
        vm.isFullscreen ? .fullscreen : container
    }

    private var transportPlacement: PlayerTransportPlacement {
        PlayerTransportPlacement.resolve(presentation: resolvedPresentation)
    }

    private var isOwner: Bool {
        guard let screenLease, vm.isCurrentOwner(screenLease) else { return false }
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

    private var isPlaybackUnavailable: Bool {
        (vm.error ?? vm.videoPresentationFailureMessage) != nil
    }

    var body: some View {
        let _ = UIHitchMonitor.countBody("player")
        let effectiveCornerRadius = max(
            vm.isFullscreen ? 0 : inlineCornerRadius,
            PlayerPresentationCornerPolicy.cornerRadius(
                isPiPRestoringInline: vm.isPiPRestoringInline
            )
        )
        ZStack {
            (surfaceRole == .inline || vm.isFullscreen) ? Color.black : Color.clear

            if isOwner {
                PlayerFullscreenAmbientBackdrop(player: vm)
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
                enabled: danmakuEnabled
            ) {
                PlayerDanmakuOverlay(player: vm)
            }

            if !isOwner,
               let still = vm.outgoingRouteStill(for: owner)
                   ?? (vm.outgoingRouteStill?.owner == owner ? vm.outgoingRouteStill?.image : nil),
               still.size.width > 0 {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFit()
                    .allowsHitTesting(false)
            }

            if isOwner, let frame = vm.freezeFrame, frame.size.width > 0 {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .allowsHitTesting(false)
            }

            if vm.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            HStack(spacing: 0) {
                if !vm.isFullscreen {
                    Color.clear
                        .frame(width: Self.systemBackEdgeReserve)
                        .allowsHitTesting(false)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(surfaceGesture)
                    .interactiveDismissDisabled(surfaceOwnsTouch)
                    .background(PresentationDismissGestureGate(isHeld: surfaceOwnsTouch))
            }
            .zIndex(0)

            if surfaceRole == .inline || vm.isFullscreen {
                PlayerControlsOverlay(
                    player: vm, owner: owner, screenLease: screenLease,
                    presentationReceipt: presentationReceipt, fullscreenHostIdentity: fullscreenHostIdentity,
                    gestureDisplay: gestureDisplay, liveQualityControl: liveQualityControl,
                    pageNavigationActions: pageNavigationActions,
                    showsAnimeOptions: showsAnimeOptions,
                    chromeInsets: chromeInsets, transportPlacement: transportPlacement,
                    suppressTransportRow: isPlaybackUnavailable,
                    danmakuPanelPresented: $danmakuPanelPresented, showSponsorBlock: $showSponsorBlock
                )
                    .opacity(vm.showControls ? 1 : 0)
                    .allowsHitTesting(vm.showControls)
                    .zIndex(1)
            }

            if vm.isFullscreen, danmakuPanelPresented, danmakuEnabled {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            danmakuPanelPresented = false
                            vm.setDanmakuSettingsHold(false)
                        }
                    ScrollView {
                        DanmakuPlayerSettingsPanel(presentation: .fullscreen) {
                            danmakuPanelPresented = false
                            vm.setDanmakuSettingsHold(false)
                        }
                    }
                    .frame(width: 280)
                    .padding(.top, 8 + chromeInsets.top + 44)
                    .padding(.trailing, 12 + chromeInsets.horizontal)
                    .padding(.bottom, 20 + chromeInsets.bottom + 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .zIndex(2)
            }

            if let error = vm.error ?? vm.videoPresentationFailureMessage {
                VStack(spacing: 12) {
                    Image(systemName: vm.unavailability?.symbolName
                        ?? "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(vm.unavailability == nil ? .yellow : .white.opacity(0.8))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if vm.unavailability?.isRetryable ?? true {
                        Button("Retry") {
                            vm.retryPlayback()
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    }
                }
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
                    .overlay {
                        GeometryReader { proxy in
                            Color.clear
                                .onChange(of: chromeInsets, initial: true) { _, i in
                                    guard PlayerLog.isCapturing else { return }
                                    let rect = proxy.frame(in: .global)
                                    PlayerLog.log(
                                        "[PlayerChrome] statsCard "
                                            + "box=\(Int(rect.minY.rounded()))..\(Int(rect.maxY.rounded())) "
                                            + "presentation=\(vm.isFullscreen ? "fullscreen" : "\(container)") "
                                            + "insetTop=\(Int(i.top.rounded())) "
                                            + "insetBottom=\(Int(i.bottom.rounded())) "
                                            + "insetH=\(Int(i.horizontal.rounded())) "
                                            + "cardTop=\(Int((rect.minY + 8 + i.top).rounded())) "
                                            + "transport=\(transportPlacement)"
                                    )
                                }
                        }
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .clipShape(
            RoundedRectangle(
                cornerRadius: effectiveCornerRadius,
                style: .continuous
            )
        )
        .overlay(alignment: .bottom) {
            PlayerSubtitleOverlay(player: vm)
                .ignoresSafeArea(.keyboard, edges: .all)
        }
        .overlay(alignment: .bottom) {
            if !isPlaybackUnavailable {
                PlayerSeekStrip(
                    player: vm, owner: owner, isCurrentOwner: isOwner, gestureDisplay: gestureDisplay,
                    chromeInsets: chromeInsets,
                    inlineCornerRadius: vm.isFullscreen ? 0 : inlineCornerRadius,
                    controlAnimation: controlAnimation
                )
                .ignoresSafeArea(.keyboard, edges: .all)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
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
                        .playerChromeCapsule(horizontal: 14, vertical: 9)
                    }
                    .padding(.trailing, (vm.isFullscreen ? 4 : 12) + chromeInsets.horizontal)
                    .padding(.bottom, (vm.isFullscreen ? 32 : 20) + chromeInsets.bottom)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(microControlAnimation, value: vm.pendingSponsorManualSegment?.uuid)
            .ignoresSafeArea(.keyboard, edges: .all)
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .sheet(isPresented: $showSponsorBlock) {
            SponsorBlockPanel(vm: vm)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(containerAspect, contentMode: .fit)
        .frame(width: allocatedInlineViewport?.width, height: allocatedInlineViewport?.height)
        .frame(maxHeight: vm.isFullscreen ? .infinity : nil)
        .background { if vm.isFullscreen { Color.black } }
        .ignoresSafeArea(.keyboard, edges: .all)
        .ignoresSafeArea(.all, edges: vm.isFullscreen ? .all : [])
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        recordGeometrySettlement(size: proxy.size)
                        publishSurfaceSizeIfAllowed(proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newValue in
                        recordGeometrySettlement(size: newValue)
                        publishSurfaceSizeIfAllowed(newValue)
                    }
                    .onChange(of: vm.isPiPRestoringInline, initial: true) { _, restoring in
                        guard PlayerLog.isCapturing else { return }
                        let rect = proxy.frame(in: .global)
                        PlayerLog.log(
                            "[Surface][PiPTrace] swiftUI restore=\(restoring ? 1 : 0) "
                                + "rect=\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))-"
                                + "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded())) "
                                + "fullscreen=\(vm.isFullscreen ? 1 : 0)"
                        )
                    }
            }
        )
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if swipeSeekActive {
                    PlayerSwipeSeekHUD(
                        player: vm, gestureDisplay: gestureDisplay, swipeSeekBase: swipeSeekBase
                    )
                }
                if vm.isHoldFastForwarding {
                    HStack(spacing: 5) {
                        Image(systemName: "forward.fill")
                        Text("2x")
                    }
                    .playerChromeCapsule()
                    .transition(.opacity)
                }
                if let notice = vm.skipNotice {
                    Text(notice)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .transition(.opacity)
                }
            }
            .padding(.top, 12)
            .animation(microControlAnimation, value: vm.isHoldFastForwarding)
            .animation(microControlAnimation, value: vm.skipNotice)
            .animation(microControlAnimation, value: swipeSeekActive)
            .ignoresSafeArea(.keyboard, edges: .all)
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
        .onAppear {
            claimScreenSurfaceIfCurrent()
            scheduleHideControls()
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        .onDisappear {
            if let claimedSurfaceLease { vm.releaseSurfaceSlot(lease: claimedSurfaceLease) }
            claimedSurfaceLease = nil
            resetSurfaceTouch(reason: "view disappeared")
            danmakuPanelPresented = false
            if vm.ownerKey == owner {
                vm.setDanmakuSettingsHold(false)
            }
            surfaceHoldTask?.cancel()
            surfaceHoldTask = nil
            pendingTapTask?.cancel()
            pendingTapTask = nil
        }
        .onChange(of: isSurfacePressing) { _, pressing in
            if !pressing, surfaceTouchInFlight {
                resetSurfaceTouch(reason: "system-cancelled")
            }
        }
        .onChange(of: gestureDisplay.isSeeking) { _, seeking in
            guard isOwner else { return }
            if seeking {
                vm.hideControlsTask?.cancel()
                vm.hideControlsTask = nil
            } else {
                vm.scheduleHideControls()
            }
        }
        .onChange(of: vm.ownerKey) { _, _ in
            claimScreenSurfaceIfCurrent()
        }
        .onChange(of: vm.activeSurfaceLease) { _, _ in
            claimScreenSurfaceIfCurrent()
        }
        .onChange(of: screenLease) { _, _ in
            claimScreenSurfaceIfCurrent()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard isOwner, UIDevice.current.userInterfaceIdiom == .phone else { return }
            let orientation = UIDevice.current.orientation
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
            recordGeometrySettlement(size: surfaceSize)
            guard isOwner, UIDevice.current.userInterfaceIdiom == .phone else { return }
            if newValue == .regular, vm.isFullscreen {
                PlayerLog.log("[Player] window rotated to portrait behind isFullscreen — reconciling")
                vm.requestFullscreenTransition(target: false, source: .verticalSizeClass)
            } else if newValue == .compact, !vm.isFullscreen, vm.currentURL != nil {
                PlayerLog.log("[Player] window rotated to landscape behind inline state — reconciling")
                vm.requestFullscreenTransition(target: true, source: .verticalSizeClass)
            }
        }
        .onChange(of: vm.isFullscreen) { _, _ in
            resetSurfaceTouch(reason: "fullscreen changed")
            gestureDisplay.cancelSeek()
        }
        .opacity(isInlineViewportCollapsed ? 0 : 1)
        .allowsHitTesting(!isInlineViewportCollapsed)
        .accessibilityHidden(isInlineViewportCollapsed)
    }

    // MARK: - Unified Surface Gesture (tap / hold-2x / swipe-seek)

    private static let swipeEngageDistance: CGFloat = 24
    private static let scrollRejectDistance: CGFloat = 36
    private static let holdMaxDrift: CGFloat = 30
    private static let tapMaxDistance: CGFloat = 24
    private static let surfaceHoldDelay: Duration = .milliseconds(200)
    private static let systemBackEdgeReserve: CGFloat = 20
    private static let verticalAdjustHardwareStep: Double = 1.0 / 256

    private func resetSurfaceTouch(reason: String) {
        guard surfaceTouchInFlight || surfaceHoldEngaged || swipeSeekActive || swipeSeekRejected
                || verticalAdjustActive || verticalPagingActive else { return }
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
        verticalAdjustActive = false
        swipeSeekRejected = false
        surfaceTouchInFlight = false
        surfaceDrag.reset()
    }

    private var surfaceGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isSurfacePressing) { _, pressing, _ in
                pressing = true
            }
            .onChanged { gesture in
                guard isOwner, surfaceLease != nil else { return }
                UIHitchMonitor.count("gesture")
                if surfaceTouchInFlight, gesture.startLocation != surfaceStartLocation {
                    resetSurfaceTouch(reason: "stale touch — previous one was system-cancelled")
                }

                let dx = gesture.translation.width
                let dy = gesture.translation.height

                if !surfaceTouchInFlight {
                    surfaceTouchInFlight = true
                    surfaceStartLocation = gesture.startLocation
                    surfaceDrag.reset()
                    surfaceHoldEngaged = false
                    swipeSeekRejected = false
                    surfaceHoldTask?.cancel()
                    surfaceHoldTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.surfaceHoldDelay)
                        guard !Task.isCancelled, isOwner, surfaceLease != nil, surfaceTouchInFlight,
                              !swipeSeekActive, !swipeSeekRejected, !verticalAdjustActive, !verticalPagingActive,
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

                if !swipeSeekActive, !verticalAdjustActive, !verticalPagingActive {
                    if abs(dx) > Self.swipeEngageDistance, abs(dx) > abs(dy) * 1.2 {
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
                    } else if abs(dy) > Self.scrollRejectDistance, abs(dy) >= abs(dx) {
                        if let verticalPagingGestureSink, !vm.isFullscreen {
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
                        let width = surfaceSize.width > 0 ? surfaceSize.width : UIScreen.main.bounds.width
                        verticalAdjustIsVolume = surfaceStartLocation.x > width / 2
                        verticalAdjustBase = verticalAdjustIsVolume
                            ? Double(SystemVolumeController.shared.volume)
                            : Double(UIScreen.main.brightness)
                        gestureDisplay.verticalAdjustValue = verticalAdjustBase
                        verticalAdjustActive = true
                        PlayerLog.log("[PlayerGesture] vertical \(verticalAdjustIsVolume ? "volume" : "brightness") engaged at \(Int(verticalAdjustBase * 100))%")
                    } else {
                        return
                    }
                }

                if verticalPagingActive {
                    verticalPagingGestureSink?.change(dy)
                    return
                }

                if verticalAdjustActive {
                    let height = Double(surfaceSize.height > 0 ? surfaceSize.height : UIScreen.main.bounds.height)
                    let value = min(max(verticalAdjustBase - Double(dy) / height, 0), 1)
                    gestureDisplay.verticalAdjustValue = value
                    let applied = surfaceDrag.appliedAdjust
                    guard applied == nil
                        || abs(value - (applied ?? 0)) >= Self.verticalAdjustHardwareStep
                        || value == 0 || value == 1
                    else { return }
                    surfaceDrag.appliedAdjust = value
                    UIHitchMonitor.count("hw")
                    if verticalAdjustIsVolume {
                        SystemVolumeController.shared.setVolume(Float(value))
                    } else {
                        UIScreen.main.brightness = CGFloat(value)
                    }
                    return
                }

                let width = max(surfaceSize.width > 0 ? surfaceSize.width : UIScreen.main.bounds.width, 1)
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

    // MARK: - Helpers

    private var verticalSizeClassLabel: String {
        if verticalSizeClass == .compact { return "compact" }
        if verticalSizeClass == .regular { return "regular" }
        return "nil"
    }

    private var surfaceGeometryPublicationContext: PlayerSurfaceGeometryPublicationPolicy.Context {
        let deviceClass: PlayerSurfaceGeometryPublicationPolicy.DeviceClass
        if UIDevice.current.userInterfaceIdiom == .phone {
            deviceClass = .iPhone
        } else if UIDevice.current.userInterfaceIdiom == .pad {
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

    private func recordGeometrySettlement(size: CGSize) {
        guard isOwner, surfaceLease != nil else { return }
        FullscreenTransitionDiagnostics.recordGeometrySettlement(
            size: size,
            isFullscreen: vm.isFullscreen,
            verticalSizeClass: verticalSizeClassLabel
        )
        vm.noteSurfaceGeometry(size: size, verticalSizeClass: verticalSizeClassLabel)
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
        if isOwner { vm.scheduleHideControls(isSeeking: gestureDisplay.isSeeking) }
    }
}
