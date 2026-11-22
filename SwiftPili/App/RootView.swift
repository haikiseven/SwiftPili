import Combine
import SwiftUI
import UIKit
struct RootView: View {
    // The shell-facing stored properties are `internal`, not `private`, for one reason:
    // `RootView+Shell.swift` declares the tabs and `private` is FILE-scoped in
    // Swift, so a private property here is invisible there. Same seam, same
    // rule and same header note as `PlayerViewModel+CDN.swift`. Nothing outside
    // these two files may read them.
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @AppMotion private var motion
    /// Persisted by the system: which sidebar tabs/rows the user moved or hid.
    @AppStorage("sidebar-customization") var tabCustomization: TabViewCustomization
    @AppStorage(AppearanceMode.storageKey) var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(SetupWizardPolicy.completedStorageKey) private var hasCompletedSetup = false
    @State private var showSetupWizard = false
    @Namespace private var navigationZoomNamespace
    @State private var detailPresentation = RootDetailPresentationState()
    /// The presented flow's root, kept until UIKit finishes the dismissal.
    @State private var retainedCoverRoot: DetailRouteOccurrence?
    @State private var contentLinkLifetime = ContentLinkLifetime()
    /// The bottom navigation's tint, or **nil to leave iOS's own selected-state
    /// appearance alone**. Always honours an explicit choice, whatever the
    /// scope — that surface is the one the setting exists for.
    /// `AccentStore` is `@Observable`, so this recolours live.
    private var navigationTint: Color? { AccentStore.shared.navigationTint }
    /// The accent for genuinely semantic accent surfaces inside a tab. Resolves
    /// to the PLATFORM accent unless the user chose a colour and scoped it to
    /// content — never to a brand pink.
    private var semanticAccent: Color { AccentStore.shared.semanticAccent }
    /// Single bottom-accessory slot: clipboard link suggestion takes priority over the in-flight download indicator.
    @ViewBuilder
    private func bottomChrome(showsSurface: Bool) -> some View {
        ZStack {
            if let suggestion = coordinator.clipboardSuggestion {
                ClipboardLinkBanner(
                    suggestion: suggestion,
                    accent: semanticAccent,
                    showsSurface: showsSurface,
                    open: { coordinator.acceptClipboardSuggestion() },
                    dismiss: { coordinator.dismissClipboardSuggestion() }
                )
                .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
            } else {
                DownloadProgressCapsuleHost(
                    accent: semanticAccent,
                    open: { coordinator.navigate(to: .downloads) },
                    showsSurface: showsSurface
                )
            }
        }
        .animation(motion.animation(normal: .snappy(duration: 0.22)), value: coordinator.clipboardSuggestion)
    }
    /// Whether there is anything to put in the slot at all.
    ///
    /// `DownloadProgressCapsuleHost` renders nothing when no transfer is in
    /// flight, and an accessory with nothing in it is not nothing: on iOS 26.1
    /// the container stays and leaves a blank strip above the tab bar. That is
    /// what `tabViewBottomAccessory(isEnabled:)` exists for, and what this
    /// predicate feeds.
    private var hasBottomChrome: Bool {
        coordinator.clipboardSuggestion != nil || DownloadManager.shared.hasInFlightDownloads
    }
    /// The detail host survives every iPad width. Sidebar eligibility belongs
    /// to the shell; using it here would destroy the playing page on resize.
    private var detailPresentationInput: RootDetailPresentationState.Input {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return .init(
            navigation: isPad ? coordinator.detailNavigation : nil,
            navigationRevision: isPad ? coordinator.contentLinkNavigationRevision : 0,
            accountRevision: AccountManager.shared.identityRevision,
            isEligible: isPad
        )
    }
    /// Keep the root navigation projection filtered for the entire detail
    /// transition, including the exit animation after the route has popped.
    var hidesDetailInRootShell: Bool {
        detailPresentation.hidesDetailInRootShell(for: detailPresentationInput)
    }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// iPad presents the detail flow full-screen over the shell, never inside
    /// a stack that contains it. The shell's tabs and sidebar rows already own
    /// a NavigationStack each; an outer stack whose root contains them is a
    /// nested NavigationStack, which accepted the first detail and then
    /// silently ignored later path changes (related video never pushed, Back
    /// popped two routes at once). A presentation is a separate hierarchy, and
    /// it is also one native Zoom pairs with: the tapped shell card is the
    /// source, the presented flow the destination. Window resizing never moves
    /// a detail into a different host.
    @ViewBuilder
    private var navigationContent: some View {
        if isPad {
            rootShell
                .fullScreenCover(
                    isPresented: detailCoverPresented,
                    onDismiss: { retainedCoverRoot = nil },
                    content: { detailCover }
                )
        } else {
            rootShell
        }
    }

    /// The flow's first page is the stack's root, so the presentation itself is
    /// its arrival and departure; later pages push natively inside it (and zoom
    /// from their related-video cards, which are in this same stack).
    @ViewBuilder
    private var detailCover: some View {
        // The live root while presented; the retained one while UIKit is still
        // animating the dismissal after the route has already left, so the
        // zoom shrinks the real page instead of an empty container.
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
                    // Its source is in the shell; the presentation carries the
                    // zoom (below), so the page itself must not ask for one.
                    .environment(\.zoomDestinationSuppressed, true)
                    .navigationDestination(for: DetailRouteOccurrence.self) { occurrence in
                        detailPage(occurrence)
                            .keepsInteractivePopGesture()
                    }
            }
            .background {
                DetailCoverEdgePopHost(isAtRoot: isAtRoot) {
                    coordinator.goBack()
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .environment(coordinator)
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
            .appBottomChrome(isPresented: hasBottomChrome) { showsSurface in
                bottomChrome(showsSurface: showsSurface)
            }
            // Retain the source and its content-only path for native return.
            .allowsHitTesting(!detailPresentation.projectionHeld)
            .accessibilityHidden(detailPresentation.projectionHeld)
            .appNoticeOverlay(bottomPadding: UIDevice.current.userInterfaceIdiom == .phone ? 54 : 8)
    }

    /// Presented while the retained presentation is visible. A user dismissal
    /// (the zoom's swipe-down or pinch) pops the flow's first page, which is
    /// exactly what Back does; a programmatic exit arrives here with the route
    /// already gone and is ignored.
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

    /// The pages above the root. The getter follows live retained state;
    /// native pops are admitted only as a prefix of the exact navigation that
    /// was current when SwiftUI received this binding, and never pop the root
    /// — leaving the flow is the presentation's job.
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
            // `hasStrings` avoids reading at all when there is nothing to read.
            pasteboard.hasStrings ? pasteboard.string : nil
        }
    }

    var body: some View {
        navigationContent
        // One namespace for the shell and, on iPad, the presented detail flow.
        .environment(\.navigationZoomNamespace, navigationZoomNamespace)
        // Native navigation animates pushes and pops inside the flow; the
        // layer's own transition animates the flow's entry and exit.
        .onChange(of: detailPresentationInput, initial: true) { _, input in
            detailPresentation.reconcile(
                input,
                entryAnimation: motion.feedbackAnimation(normal: AppTransitionMotion.detailEntryAnimation),
                exitAnimation: motion.feedbackAnimation(normal: AppTransitionMotion.detailExitAnimation),
                currentInput: { detailPresentationInput }
            )
        }
        // Sidebar folding changes the root arrangement, while the canonical
        // suffix keeps the same outer host. Use the same eligibility as the
        // actual TabSection declaration; regular-width iPhones have no sidebar.
        .onChange(of: horizontalSizeClass, initial: true) { old, new in
            if old != new {
                coordinator.noteContentLinkNavigationChange()
            }
            // The value SwiftUI hands over, not the captured property — the
            // parameter is the one that is certainly current.
            //
            // nil folds, exactly as `TabSection` and `MineView` treat it: they
            // compute `sizeClass == .regular`, which is false for nil, and they
            // cannot abstain because they have to render something. A version
            // of this that returned early on nil made the three disagree — the
            // section was constructed away while a `.row` selection survived,
            // which is a TabView holding a selection no `Tab` declares.
            //
            // Folding on a transient nil is recoverable, and that is why this
            // is the safe side to err on: `foldSidebarSelection` writes
            // `[row.root] + rowStack` onto the parent tab, and
            // `unfoldSidebarSelection` recognises exactly that shape, so the
            // round trip restores the position on the next resolved pass.
            if ShellNavigationPolicy.showsSidebar(
                isPad: UIDevice.current.userInterfaceIdiom == .pad,
                isRegularWidth: new == .regular
            ) {
                coordinator.unfoldSidebarSelection()
            } else {
                coordinator.foldSidebarSelection()
            }
        }
        // Image-scroll counters, over the tab content and above the tab bar.
        // Renders nothing at all unless Settings -> Image Diagnostics is armed
        // WITH its overlay switch on, and never takes a touch — the scroll it
        // measures has to reach the content underneath.
        .overlay(alignment: .topTrailing) {
            ImageDiagnosticsOverlay()
                .padding(.top, 4)
                .padding(.trailing, 6)
        }
        // `didBecomeActive`, not `.onAppear`: the clipboard is inspected at a
        // foreground/user-visible point, once per pasteboard generation.
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
            // Device seek-acceptance harness: a no-op unless launched with
            // `-seek-harness <spec>` / `SEEK_HARNESS` (compiled out of Release).
            SeekHarness.startIfRequested(coordinator: coordinator)
            #endif
        }
        // Tint the navigation bar/tab bar here (`nil` preserves iOS default); content re-establishes its own tint at `accentContentBoundary()`.
        .tint(navigationTint)
        // Re-key the whole tab tree on account switch (and logout): every
        // feature view's .task refires, so feeds, badges, and history all
        // reload under the new credential set. Tab selection and the
        // navigation paths live in the coordinator and survive.
        .id(AccountManager.shared.activeMid ?? "logged-out")
        .onOpenURL { url in
            coordinator.handle(url: url, context: contentLinkLifetime.capture())
        }
        .environment(\.contentLinkContext, contentLinkLifetime.capture())
        // Links tapped INSIDE content (comment hyperlinks, dynamic rich
        // text): bilibili destinations open in-app, the rest in Safari.
        .environment(\.openURL, OpenURLAction { url in
            coordinator.contentLinks.cancel()
            // Timestamp links injected into comment text (swiftpili://
            // seek/<seconds>): jump the playing video there. Ignored when
            // nothing VOD is playing (e.g. a timestamp inside a moment).
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
            return coordinator.openContentURL(url, context: contentLinkLifetime.capture())
        })
        .overlay(alignment: .top) {
            ContentLinkFeedback(controller: coordinator.contentLinks, scopeID: contentLinkLifetime.id)
        }
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
        .onChange(of: AccountManager.shared.identityRevision) { coordinator.contentLinks.cancel() }
        // Follows the system appearance unless the user picks one in Settings.
        .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme)
        // Outside the account `.id` above on purpose: a login re-keys that tree,
        // and a sheet inside it would be torn down mid-"Login successful".
        // LoginView dismisses itself on success; the page behind it then
        // reloads under the new account, as a login from Mine does.
        // The fullscreen chrome's login request lands here once its host has
        // dismissed (`FullscreenLoginHandoff`).
        .onChange(of: FullscreenLoginHandoff.shared.isReady) { _, ready in
            if ready, FullscreenLoginHandoff.shared.consume() {
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
    /// The iPhone tab bar's Liquid Glass behaviour: it shrinks to its selected
    /// item while the user scrolls down and comes back on the way up, so a feed
    /// gets the height the bar was holding. iPad uses the adaptable sidebar /
    /// detail placement above and must not receive this iPhone-only modifier.
    ///
    /// Same shape as `launcherGlassSurface` and `composerSurface` — the effect
    /// where the system has it, and the pre-26 arrangement untouched where it
    /// does not, rather than a reimplementation that would age badly.
    @ViewBuilder
    func glassTabBarBehaviour() -> some View {
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

private extension View {
    /// The app-global slot below the content: the tab bar's bottom accessory
    /// where the system has one, and the hand-positioned overlay where it does
    /// not.
    ///
    /// Three branches, and each one is the API that version actually has.
    /// `tabViewBottomAccessory` draws its capsule whatever is inside it, so an
    /// empty accessory is a blank strip rather than nothing — on iOS 26.0 that
    /// is avoided by putting nothing in it, and from 26.1 by
    /// `isEnabled:`, which is the only API that removes the container. Below
    /// 26 the old overlay stands, and its 58pt is still correct there because
    /// that tab bar neither floats nor minimises.
    @ViewBuilder
    func appBottomChrome(
        isPresented: Bool,
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
                        // Clear of the tab bar.
                        .padding(.bottom, 58)
                }
            }
        }
    }
}

/// Native Zoom for the iPad detail presentation, from the shell card it was
/// opened from. No source (deep link, reduced motion) keeps the default
/// full-screen presentation.
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
