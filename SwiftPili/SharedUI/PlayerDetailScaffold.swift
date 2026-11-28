import SwiftUI
import UIKit

enum PlayerDetailSurfacePolicy {
    @MainActor
    static func hostOwnsInlineSurface(
        player: PlayerViewModel,
        lease: PlayerOwnerLease?
    ) -> Bool {
        guard player.isFullscreenPresentationActive,
              let lease,
              player.isCurrentOwner(lease) else { return false }
        return player.activeSurfaceLease?.ownerLease == lease
            && player.activeSurfaceLease?.role == .fullscreen
    }

    @MainActor
    static func hasUsableInlineExitChrome(
        player: PlayerViewModel,
        lease: PlayerOwnerLease?,
        expectedMode: PlayerMode
    ) -> Bool {
        guard let lease, player.isCurrentOwner(lease) else { return false }
        return player.mode == expectedMode
            && player.activeSurfaceLease?.ownerLease == lease
            && player.activeSurfaceLease?.role == .inline
            && player.error == nil
            && player.videoPresentationFailureMessage == nil
            && player.currentURL != nil
    }
}

struct PlayerDetailContainerMetrics: Equatable, Sendable {
    @MainActor
    private static var lastMeasuredSizeForWindow: (windowSize: CGSize, detailSize: CGSize)?

    var containerSize: CGSize
    var wideContainerHeight: CGFloat
    var isKeyboardDocked = false

    @MainActor
    init(initialBounds: CGRect? = nil) {
        if let explicitBounds = initialBounds {
            containerSize = explicitBounds.size
            wideContainerHeight = explicitBounds.height
            return
        }
        let windowBounds = WindowMetricsFallback.currentBounds
        if let cached = Self.lastMeasuredSizeForWindow,
           abs(cached.windowSize.width - windowBounds.width) < 1,
           abs(cached.windowSize.height - windowBounds.height) < 1,
           cached.detailSize.width > 0,
           cached.detailSize.height > 0 {
            containerSize = cached.detailSize
            wideContainerHeight = cached.detailSize.height
        } else {
            containerSize = windowBounds.size
            wideContainerHeight = windowBounds.height
        }
    }

    var containerWidth: CGFloat { containerSize.width }
    var restingHeight: CGFloat { containerSize.height }

    @MainActor
    var pageWidth: CGFloat {
        containerWidth > 0 ? containerWidth : WindowMetricsFallback.currentWidth
    }

    @MainActor
    func isWideLayout(isRegularWidth: Bool) -> Bool {
        DetailSplitPolicy.usesSplit(
            isRegularWidth: isRegularWidth,
            containerSize: containerSize
        )
    }

    @MainActor
    var usesCompactPhoneActions: Bool {
        guard containerSize.width.isFinite, containerSize.height.isFinite,
              containerSize.width > 0, containerSize.height > 0 else {
            let fallback = WindowMetricsFallback.currentSize
            return DeviceCapability.usesCompactPortraitVideoFraming && fallback.height >= fallback.width
        }
        return DeviceCapability.usesCompactPortraitVideoFraming && containerSize.height >= containerSize.width
    }

    @MainActor
    mutating func update(
        size: CGSize,
        isRegularWidth: Bool
    ) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if containerSize != size {
            containerSize = size
        }
        if UIApplication.shared.applicationState == .active {
            let windowSize = WindowMetricsFallback.currentSize
            if windowSize.width > 0, windowSize.height > 0 {
                Self.lastMeasuredSizeForWindow = (windowSize: windowSize, detailSize: size)
            }
        }
        let wide = DetailSplitPolicy.usesSplit(
            isRegularWidth: isRegularWidth,
            containerSize: size
        )
        if !wide, isKeyboardDocked {
            isKeyboardDocked = false
        }
        if wide, wideContainerHeight != size.height {
            wideContainerHeight = size.height
        }
    }

    mutating func updateKeyboardDocked(_ docked: Bool) {
        if isKeyboardDocked != docked {
            isKeyboardDocked = docked
        }
    }
}

struct PlayerDetailGeometryObserver: ViewModifier {
    let isFullscreenPresentationActive: Bool
    var isActiveRoute: Bool = true
    let onSizeChange: @MainActor (CGSize) -> Void

    @State private var pendingSize: CGSize?
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    private var shouldDeferGeometryUpdates: Bool {
        (DeviceCapability.supportsOrientationLock && isFullscreenPresentationActive)
            || !isActiveRoute
            || UIApplication.shared.applicationState != .active
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if shouldDeferGeometryUpdates {
                    pendingSize = size
                    return
                }
                pendingSize = nil
                onSizeChange(size)
            }
            .onChange(of: isFullscreenPresentationActive) { _, _ in
                flushPendingSizeIfReady()
            }
            .onChange(of: isActiveRoute) { _, _ in
                flushPendingSizeIfReady()
            }
            .onChange(of: scenePhase) { _, _ in
                flushPendingSizeIfReady()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            ) { _ in
                flushPendingSizeIfReady()
            }
    }

    @MainActor
    private func flushPendingSizeIfReady() {
        guard !shouldDeferGeometryUpdates, let pending = pendingSize else { return }
        pendingSize = nil
        onSizeChange(pending)
    }
}

struct PlayerDetailGeometryProbes: View {
    let isWideLayout: Bool
    let restingHeight: CGFloat
    let isFullscreenPresentationActive: Bool
    var isActiveRoute: Bool = true
    let onSizeChange: @MainActor (CGSize) -> Void
    let onKeyboardDockedChange: @MainActor (Bool) -> Void

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .playerDetailDeferredSize(
                    isFullscreenPresentationActive: isFullscreenPresentationActive,
                    isActiveRoute: isActiveRoute,
                    onSizeChange: onSizeChange
                )
                .ignoresSafeArea(.container, edges: .all)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if isWideLayout {
                let restingHeight = self.restingHeight
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onGeometryChange(for: Bool.self) { proxy in
                        let safeHeight = proxy.size.height
                        guard restingHeight.isFinite, restingHeight > 0,
                              safeHeight.isFinite, safeHeight > 0 else { return false }
                        return (restingHeight - safeHeight) > 40
                    } action: { docked in
                        onKeyboardDockedChange(docked)
                    }
                    .ignoresSafeArea(.container, edges: .all)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlayerDetailInlineNavigationOverlay: View {
    let player: PlayerViewModel
    let isActiveRoute: Bool
    let hasInlineExitChrome: @MainActor () -> Bool
    var scrimWidth: CGFloat?
    var scrimHeight: CGFloat?
    var cornerRadius: CGFloat = 0
    let actions: PlayerPageNavigationActions

    var body: some View {
        if !player.isFullscreenPresentationActive, isActiveRoute {
            let showsNavigation = !hasInlineExitChrome() || player.showControls || player.playbackEnded
            let showsTopFeather = showsNavigation && !player.showControls && !player.playbackEnded
            let featherHeight = scrimHeight.map { min(max($0, 0), 76) } ?? 76
            ZStack(alignment: .topLeading) {
                if !player.showControls && !player.playbackEnded {
                    LinearGradient(
                        colors: [.black.opacity(0.42), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: scrimWidth, height: featherHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .opacity(showsTopFeather ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(.easeOut(duration: 0.18), value: showsNavigation)
                }
                PlayerPageNavigationButtons(actions: actions)
                    .padding(.horizontal, PlayerPageNavigationButtons.inlineHorizontalPadding)
                    .padding(.top, PlayerPageNavigationButtons.topPadding)
                    .opacity(showsNavigation ? 1 : 0)
                    .allowsHitTesting(showsNavigation)
                    .accessibilityHidden(!showsNavigation)
                    .animation(.easeOut(duration: 0.18), value: showsNavigation)
            }
        }
    }
}

struct PlayerDetailChromeModifier<Backdrop: View>: ViewModifier {
    let isFullscreenPresentationActive: Bool
    let isStatusBarHidden: Bool
    let guardsIPadTopSafeArea: Bool?
    let preventsContentDismissal: Bool?
    let presentationContext: PlayerScreenPresentationContext?
    let coordinator: AppCoordinator
    let liveRoom: LiveRoomViewModel?
    let backdrop: Backdrop

    func body(content: Content) -> some View {
        dismissGated(
            backdropApplied(
                safeAreaGuarded(
                    content
                        .allowsHitTesting(!isFullscreenPresentationActive)
                        .accessibilityHidden(isFullscreenPresentationActive)
                )
            )
            .appSurface(.cinematic)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .keepsInteractivePopGesture()
        )
        .background(alignment: .topLeading) {
            if let presentationContext {
                PlayerFullscreenHost(
                    context: presentationContext,
                    navigation: coordinator,
                    liveRoom: liveRoom
                )
            }
        }
        .statusBarHidden(isStatusBarHidden)
    }

    @ViewBuilder
    private func safeAreaGuarded<Target: View>(_ view: Target) -> some View {
        if let guardsIPadTopSafeArea {
            view.guardIPadTopSafeArea(when: guardsIPadTopSafeArea)
        } else {
            view
        }
    }

    @ViewBuilder
    private func backdropApplied<Target: View>(_ view: Target) -> some View {
        if Backdrop.self != EmptyView.self {
            view.background { backdrop }
        } else {
            view
        }
    }

    @ViewBuilder
    private func dismissGated<Target: View>(_ view: Target) -> some View {
        if let preventsContentDismissal {
            view.preventsVideoDetailContentDismissal(isActive: preventsContentDismissal)
        } else {
            view
        }
    }
}

extension View {
    func playerDetailDeferredSize(
        isFullscreenPresentationActive: Bool,
        isActiveRoute: Bool = true,
        onSizeChange: @escaping @MainActor (CGSize) -> Void
    ) -> some View {
        modifier(
            PlayerDetailGeometryObserver(
                isFullscreenPresentationActive: isFullscreenPresentationActive,
                isActiveRoute: isActiveRoute,
                onSizeChange: onSizeChange
            )
        )
    }

    func playerDetailInlineContainerSize(
        isFullscreenPresentationActive: Bool,
        isActiveRoute: Bool = true,
        onSizeChange: @escaping @MainActor (CGSize) -> Void
    ) -> some View {
        background {
            GeometryReader { _ in
                Color.clear
                    .playerDetailDeferredSize(
                        isFullscreenPresentationActive: isFullscreenPresentationActive,
                        isActiveRoute: isActiveRoute,
                        onSizeChange: onSizeChange
                    )
            }
            .ignoresSafeArea(.all, edges: .vertical)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    func playerDetailChrome<Backdrop: View>(
        isFullscreenPresentationActive: Bool,
        isStatusBarHidden: Bool,
        guardsIPadTopSafeArea: Bool? = true,
        preventsContentDismissal: Bool? = nil,
        presentationContext: PlayerScreenPresentationContext?,
        coordinator: AppCoordinator,
        liveRoom: LiveRoomViewModel? = nil,
        @ViewBuilder backdrop: () -> Backdrop
    ) -> some View {
        modifier(
            PlayerDetailChromeModifier(
                isFullscreenPresentationActive: isFullscreenPresentationActive,
                isStatusBarHidden: isStatusBarHidden,
                guardsIPadTopSafeArea: guardsIPadTopSafeArea,
                preventsContentDismissal: preventsContentDismissal,
                presentationContext: presentationContext,
                coordinator: coordinator,
                liveRoom: liveRoom,
                backdrop: backdrop()
            )
        )
    }

    func playerDetailChrome(
        isFullscreenPresentationActive: Bool,
        isStatusBarHidden: Bool,
        guardsIPadTopSafeArea: Bool? = nil,
        preventsContentDismissal: Bool? = nil,
        presentationContext: PlayerScreenPresentationContext?,
        coordinator: AppCoordinator,
        liveRoom: LiveRoomViewModel? = nil
    ) -> some View {
        modifier(
            PlayerDetailChromeModifier(
                isFullscreenPresentationActive: isFullscreenPresentationActive,
                isStatusBarHidden: isStatusBarHidden,
                guardsIPadTopSafeArea: guardsIPadTopSafeArea,
                preventsContentDismissal: preventsContentDismissal,
                presentationContext: presentationContext,
                coordinator: coordinator,
                liveRoom: liveRoom,
                backdrop: EmptyView()
            )
        )
    }
}
