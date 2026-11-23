import Combine
import SwiftUI
import UIKit
struct RootView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(AppNoticeCenter.self) private var noticeCenter: AppNoticeCenter?
    @Environment(\.appSceneID) private var appSceneID
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @AppMotion private var motion
    @AppStorage("sidebar-customization") var tabCustomization: TabViewCustomization
    @AppStorage(AppearanceMode.storageKey) var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(SetupWizardPolicy.completedStorageKey) private var hasCompletedSetup = false
    @State private var showSetupWizard = false
    @Namespace private var navigationZoomNamespace
    @State private var detailPresentation = RootDetailPresentationState()
    @State private var retainedCoverRoot: DetailRouteOccurrence?
    @State private var contentLinkLifetime = ContentLinkLifetime()
    private var navigationTint: Color? { AccentStore.shared.navigationTint }
    private var semanticAccent: Color { AccentStore.shared.semanticAccent }
    @ViewBuilder
    private func bottomChrome(showsSurface: Bool) -> some View {
        let chromeTransition = showsSurface
            ? motion.transition(normal: .move(edge: .bottom).combined(with: .opacity))
            : motion.transition(normal: .opacity)
        ZStack {
            if let suggestion = coordinator.clipboardSuggestion {
                ClipboardLinkBanner(
                    suggestion: suggestion,
                    accent: semanticAccent,
                    showsSurface: showsSurface,
                    open: { coordinator.acceptClipboardSuggestion() },
                    dismiss: { coordinator.dismissClipboardSuggestion() }
                )
                .transition(chromeTransition)
            } else if DownloadManager.shared.hasInFlightDownloads {
                DownloadProgressCapsuleHost(
                    accent: semanticAccent,
                    open: { coordinator.navigate(to: .downloads) },
                    showsSurface: showsSurface
                )
                .transition(chromeTransition)
            }
        }
        .animation(motion.animation(normal: .snappy(duration: 0.22)), value: coordinator.clipboardSuggestion)
    }
    private var hasBottomChrome: Bool {
        coordinator.clipboardSuggestion != nil || DownloadManager.shared.hasInFlightDownloads
    }
    private var usesRegularDetailHost: Bool {
        showsSidebar
    }
    private var detailPresentationInput: RootDetailPresentationState.Input {
        let eligible = usesRegularDetailHost
        return .init(
            navigation: eligible ? coordinator.detailNavigation : nil,
            navigationRevision: eligible ? coordinator.contentLinkNavigationRevision : 0,
            accountRevision: AccountManager.shared.identityRevision,
            isEligible: eligible
        )
    }
    var hidesDetailInRootShell: Bool {
        detailPresentation.hidesDetailInRootShell(for: detailPresentationInput)
    }

    private var navigationContent: some View {
        rootShell
            .fullScreenCover(
                isPresented: detailCoverPresented,
                onDismiss: { retainedCoverRoot = nil },
                content: {
                    detailCover.modifier(
                        DetailCoverLinkModifier(coordinator: coordinator) { url, context in
                            handleOpenURL(url, context: context)
                        }
                    )
                }
            )
    }

    @ViewBuilder
    private var detailCover: some View {
        if let root = detailPresentation.navigation?.root ?? retainedCoverRoot {
            let isAtRoot = detailPresentation.isVisible
                && detailPresentation.navigation != nil
                && detailCoverPath(root: root).wrappedValue.isEmpty
            NavigationStack(path: detailCoverPath(root: root)) {
                detailPage(root)
                    .keepsInteractivePopGesture()
                    .toolbar {
                        if root.route.requiresCoverCloseButton {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    coordinator.goBack()
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .tint(Color.primary)
                                .accessibilityLabel(Text("Close"))
                            }
                        }
                    }
                    .environment(\.zoomDestinationSuppressed, true)
                    .navigationDestination(for: DetailRouteOccurrence.self) { occurrence in
                        detailPage(occurrence)
                            .keepsInteractivePopGesture()
                    }
            }
            .background {
                DetailCoverEdgePopHost(
                    isAtRoot: isAtRoot,
                    isBlocked: { PlayerViewModel.existingShared?.chrome.isFullscreen ?? false }
                ) {
                    coordinator.goBack()
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .environment(\.appSceneID, appSceneID)
            .environment(coordinator)
            .environment(noticeCenter)
            .environment(\.appNoticeCenter, noticeCenter)
            .environment(\.navigationZoomNamespace, navigationZoomNamespace)
            .modifier(CoverZoom(
                sourceID: motion.reducesGeometry ? nil : root.route.zoomSourceID,
                namespace: navigationZoomNamespace
            ))
            .id(root)
            .onAppear { retainedCoverRoot = root }
            .appNoticeOverlay()
        }
    }

    private func detailPage(_ occurrence: DetailRouteOccurrence) -> some View {
        coordinator.destination(for: occurrence.route, position: occurrence.position)
            .imageDiagnosticsScreen("Root.detail")
            .imageDiagnosticsScrollTracking()
            .accentContentBoundary()
    }

    private var rootShell: some View {
        shell
            .tabViewStyle(.sidebarAdaptable)
            .tabViewCustomization($tabCustomization)
            .glassTabBarBehaviour()
            .appBottomChrome(
                isPresented: hasBottomChrome,
                bottomOverlayPadding: showsSidebar ? 16 : 58
            ) { showsSurface in
                bottomChrome(showsSurface: showsSurface)
            }
            .allowsHitTesting(!detailPresentation.projectionHeld)
            .accessibilityHidden(detailPresentation.projectionHeld)
            .appNoticeOverlay(bottomPadding: showsSidebar ? 8 : 54)
    }

    private var detailCoverPresented: Binding<Bool> {
        Binding(
            get: { detailPresentation.isVisible && detailPresentation.navigation != nil },
            set: { presented in
                guard !presented, detailPresentation.isVisible,
                      let navigation = detailPresentation.navigation else { return }
                let generation = detailPresentation.generation
                let input = detailPresentationInput
                guard input.requiresOuterHost, input.navigation == navigation,
                      detailPresentation.accountRevision == input.accountRevision,
                      coordinator.popDetailNavigation(to: [], from: navigation)
                else { return }
                detailPresentation.noteCommittedNativePop(
                    root: navigation.root, generation: generation, input: detailPresentationInput
                )
            }
        )
    }

    private func detailCoverPath(root: DetailRouteOccurrence) -> Binding<[DetailRouteOccurrence]> {
        let navigation = detailPresentation.navigation
        let generation = detailPresentation.generation
        let revision = coordinator.contentLinkNavigationRevision
        return Binding(
            get: {
                guard let currentNavigation = detailPresentation.navigation,
                      currentNavigation.root == root else { return [] }
                return Array(detailPresentation.nativePath(
                    for: currentNavigation,
                    generation: detailPresentation.generation,
                    input: detailPresentationInput
                ).dropFirst())
            },
            set: { pushed in
                let input = detailPresentationInput
                let path = [root] + pushed
                guard let navigation, navigation.root == root,
                      detailPresentation.isVisible,
                      detailPresentation.generation == generation,
                      input.navigationRevision == revision,
                      detailPresentation.navigation == navigation,
                      detailPresentation.accountRevision == input.accountRevision,
                      input.requiresOuterHost, input.navigation == navigation,
                      path.count < navigation.path.count,
                      navigation.path.prefix(path.count).elementsEqual(path)
                else { return }
                coordinator.popDetailNavigation(to: path, from: navigation)
            }
        )
    }

    private func inspectClipboard() {
        let pasteboard = UIPasteboard.general
        coordinator.inspectClipboardForLink(changeCount: pasteboard.changeCount) {
            pasteboard.hasStrings ? pasteboard.string : nil
        }
    }

    private func handleOpenURL(_ url: URL, context: ContentLinkContext) -> OpenURLAction.Result {
        coordinator.contentLinks.cancel()
        if url.scheme == "swiftpili", url.host() == "seek" {
            let player = PlayerViewModel.shared
            if let seconds = Double(url.lastPathComponent),
               player.mode == .vod, player.currentURL != nil,
               player.duration > 0, seconds < player.duration {
                PlayerLog.log("[Player] comment timestamp tapped → seek \(Int(seconds))s")
                player.seek(to: seconds)
            } else {
                PlayerLog.log("[Player] comment timestamp ignored (no VOD playing or out of range)")
            }
            return .handled
        }
        return coordinator.openContentURL(url, context: context)
    }

    var body: some View {
        navigationContent
        .environment(\.navigationZoomNamespace, navigationZoomNamespace)
        .onChange(of: detailPresentationInput, initial: true) { _, input in
            detailPresentation.reconcile(
                input,
                entryAnimation: motion.feedbackAnimation(normal: AppTransitionMotion.detailEntryAnimation),
                exitAnimation: motion.feedbackAnimation(normal: AppTransitionMotion.detailExitAnimation),
                currentInput: { detailPresentationInput }
            )
        }
        .onChange(of: horizontalSizeClass, initial: true) { old, new in
            if old != new {
                coordinator.noteContentLinkNavigationChange()
            }
            if ShellNavigationPolicy.showsSidebar(
                isPad: DeviceCapability.supportsPadDetailSplit,
                isRegularWidth: new == .regular
            ) {
                coordinator.unfoldSidebarSelection()
            } else {
                coordinator.foldSidebarSelection()
            }
        }
        .overlay(alignment: .topTrailing) {
            ImageDiagnosticsOverlay()
                .padding(.top, 4)
                .padding(.trailing, 6)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            inspectClipboard()
        }
        .task {
            inspectClipboard()
            #if DEBUG
            SeekHarness.startIfRequested(coordinator: coordinator)
            #endif
        }
        .tint(navigationTint)
        .onOpenURL { url in
            coordinator.handle(
                url: url,
                context: coordinator.activeCoverLinkContext ?? contentLinkLifetime.capture()
            )
        }
        .environment(\.contentLinkContext, contentLinkLifetime.capture())
        .environment(\.openURL, OpenURLAction { url in
            handleOpenURL(url, context: contentLinkLifetime.capture())
        })
        .contentLinkFeedback(
            controller: coordinator.contentLinks,
            scopeID: contentLinkLifetime.id,
            bottomPadding: showsSidebar ? 8 : 54
        )
        .onAppear {
            contentLinkLifetime.activate()
            coordinator.rootLinkContext = contentLinkLifetime.capture()
            if !hasCompletedSetup {
                showSetupWizard = true
            }
        }
        .sheet(
            isPresented: $showSetupWizard,
            onDismiss: { hasCompletedSetup = true },
            content: { SetupWizardView() }
        )
        .onDisappear {
            contentLinkLifetime.deactivate()
            coordinator.contentLinks.cancel(lifetimeID: contentLinkLifetime.id)
        }
        .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme)
        .onChange(of: FullscreenLoginHandoff.shared.isReady) { _, ready in
            if ready, FullscreenLoginHandoff.shared.consume(for: appSceneID) {
                coordinator.presentLogin()
            }
        }
        .sheet(item: Binding(
            get: { coordinator.loginPresentation },
            set: { coordinator.loginPresentation = $0 }
        )) { _ in
            NavigationStack {
                LoginView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { coordinator.loginPresentation = nil }
                        }
                    }
            }
            .accentContentBoundary()
        }
    }
}

private extension View {
    @ViewBuilder
    func glassTabBarBehaviour() -> some View {
        if #available(iOS 26.0, *), DeviceCapability.usesPhoneTabBarMinimization {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

private extension View {
    @ViewBuilder
    func appBottomChrome(
        isPresented: Bool,
        bottomOverlayPadding: CGFloat = 58,
        @ViewBuilder content: @escaping (_ showsSurface: Bool) -> some View
    ) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isPresented) { content(false) }
        } else if #available(iOS 26.0, *) {
            tabViewBottomAccessory {
                if isPresented { content(false) }
            }
        } else {
            overlay(alignment: .bottom) {
                if isPresented {
                    content(true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomOverlayPadding)
                }
            }
        }
    }
}

private struct DetailCoverLinkModifier: ViewModifier {
    let coordinator: AppCoordinator
    let handleOpenURL: @MainActor (URL, ContentLinkContext) -> OpenURLAction.Result
    @State private var lifetime = ContentLinkLifetime()

    func body(content: Content) -> some View {
        let context = lifetime.capture()
        content
            .environment(\.contentLinkContext, context)
            .environment(\.openURL, OpenURLAction { url in
                handleOpenURL(url, lifetime.capture())
            })
            .contentLinkFeedback(
                controller: coordinator.contentLinks,
                scopeID: lifetime.id
            )
            .onAppear {
                lifetime.activate()
                coordinator.activeCoverLinkContext = lifetime.capture()
            }
            .onDisappear {
                lifetime.deactivate()
                if coordinator.activeCoverLinkContext?.presentationID == lifetime.id {
                    coordinator.activeCoverLinkContext = nil
                }
                coordinator.contentLinks.cancel(lifetimeID: lifetime.id)
            }
    }
}

private struct CoverZoom: ViewModifier {
    let sourceID: UUID?
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if let sourceID {
            content.navigationTransition(.zoom(sourceID: AnyHashable(sourceID), in: namespace))
        } else {
            content
        }
    }
}
