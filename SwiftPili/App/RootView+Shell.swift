import SwiftUI
import UIKit

/// The shell: which tabs exist, how they are arranged, and what each one
/// carries. Split out of `RootView.swift` when the two arrangements pushed that
/// file over SwiftLint's 500-line warning — the same reason
/// `PlayerViewModel+CDN.swift` exists, and with the same consequence: `private`
/// is FILE-scoped in Swift, so the shell-facing stored properties this seam
/// reads are declared `internal` on the type rather than private. Nothing outside these
/// two files may touch them.
///
/// What lives here is everything the declaration needs and nothing about how
/// the shell is decorated: the modifier chain — the style, the customization,
/// the fold/unfold reconciliation — stays with `body`, because those are
/// answers ABOUT the shell rather than parts of it.
extension RootView {
    /// Whether a sidebar is on screen — asked once, here, and answered by the
    /// policy every other reader uses. It is NOT "the width is regular": a Max
    /// iPhone in landscape is regular and keeps its tab bar.
    private var showsSidebar: Bool {
        ShellNavigationPolicy.showsSidebar(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isRegularWidth: horizontalSizeClass == .regular
        )
    }

    /// One tab, one stack — the single place that says which screen and which
    /// path a tab carries.
    ///
    /// The shell declares its tabs TWICE (grouped into sections where there is
    /// a sidebar, flat where there is a tab bar), so a body written inline at
    /// each `Tab` would be written twice as well, and the two copies are what
    /// would drift. The binding comes from the coordinator because `@Bindable`
    /// reaches the stacks only inside `body`.
    @ViewBuilder
    private func stack(for tab: AppTab) -> some View {
        let path = coordinator.stackBinding(for: tab, hidingDetail: { hidesDetailInRootShell })
        switch tab {
        case .home: tabStack(path, tab: tab, screen: "Home") { HomeView() }
        case .dynamics: tabStack(path, tab: tab, screen: "Dynamics") { DynamicsView() }
        case .live: tabStack(path, tab: tab, screen: "Live.List") { LiveListView() }
        case .mine: tabStack(path, tab: tab, screen: "Mine") { MineView() }
        case .search: tabStack(path, tab: tab, screen: "Search") { SearchView() }
        }
    }

    /// WHO this is, at the TOP of the sidebar and above every row in it.
    ///
    /// `.tabViewSidebarHeader` is the platform's own slot for this, and it is
    /// why the avatar can be 56pt: a header is not a list row, so nothing
    /// clamps it to the sidebar's SF-Symbol icon metric — which is exactly what
    /// made the first attempt (a `Tab` with a custom `Label`) render a face as a
    /// dot beside a regular-weight name. The slot brings its own separation
    /// from the rows below; the padding here only keeps the circle off the
    /// window's top edge.
    ///
    /// `AvatarImage` already clips to a circle and asks the CDN for the
    /// circle's own pixel box, so `size:` is a decode budget and not
    /// decoration. The signed-out shape is `MineView`'s own — glyph and string
    /// key included — so the sidebar and the screen it opens do not extend two
    /// differently worded invitations to one login.
    ///
    /// The roster is the source rather than `MineViewModel` because this
    /// renders before that screen is ever opened, and `AccountManager` is
    /// already observable and already re-keys the tree on an account switch. A
    /// nil active account means "no name to show" — signed out, and signed in
    /// with a roster that has not caught up, both land there.
    ///
    /// It writes through the shell's own selection binding rather than poking
    /// `coordinator.selectedTab`: that binding is what clears a live sidebar row
    /// before moving, notes the screen for a freeze report, and turns a tap on
    /// the already-selected Mine into pop-to-root. A second path into the same
    /// state would be a second set of those rules.
    @ViewBuilder
    private func accountHeader(selection: Binding<SidebarSelection>) -> some View {
        Button {
            selection.wrappedValue = .tab(.mine)
        } label: {
            HStack(spacing: 12) {
                if let account = AccountManager.shared.activeAccount {
                    AvatarImage(urlString: account.avatarURL, size: 56)
                        // Every other image site in the app is attributed;
                        // without this one the sidebar's decodes land in the
                        // default bucket and a stall here would be invisible.
                        .imageDiagnosticsScreen("Sidebar.account")
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                    Text(account.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(.secondary)
                    Text("Log In")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        // `.plain`, or the row reads as a tinted control instead of an identity.
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    /// A sidebar row's own stack: its root is the row's screen, and what the
    /// user pushes from there lives above it.
    @ViewBuilder
    private func sidebarRowScreen(_ row: SidebarDestination) -> some View {
        NavigationStack(
            path: coordinator.sidebarRowStackBinding(
                for: row,
                hidingDetail: { hidesDetailInRootShell }
            )
        ) {
            coordinator.destination(for: row.root)
                .keepsInteractivePopGesture()
                .imageDiagnosticsScreen("Sidebar.\(row.id)")
                .imageDiagnosticsScrollTracking()
                .navigationDestination(for: Route.self) { route in
                    coordinator.destination(
                        for: route, position: coordinator.playerRoutePosition(for: route, sidebarRow: row)
                    )
                        .keepsInteractivePopGesture()
                        .accentContentBoundary()
                }
                .accentContentBoundary()
        }
    }

    /// One tab's stack, with the diagnostics attachment every tab carried
    /// separately before there were six of them.
    @ViewBuilder
    private func tabStack(
        _ path: Binding<[Route]>,
        tab: AppTab,
        screen: String,
        @ViewBuilder root: () -> some View
    ) -> some View {
        NavigationStack(path: path) {
            root()
                .keepsInteractivePopGesture()
                .toolbar(path.wrappedValue.isEmpty ? .visible : .automatic, for: .tabBar)
                .background {
                    RootTabBarDiagnostics(tab: tab, coordinator: coordinator)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .imageDiagnosticsScreen(screen)
                .imageDiagnosticsScrollTracking()
                .navigationDestination(for: Route.self) { route in
                    coordinator.destination(
                        for: route, position: coordinator.playerRoutePosition(for: route, tab: tab)
                    )
                        .keepsInteractivePopGesture()
                        .accentContentBoundary()
                }
                .accentContentBoundary()
        }
    }

    /// The declaration itself. `body` attaches the modifiers.
    @ViewBuilder
    var shell: some View {
        // Custom binding so tapping the ALREADY-selected row is observable:
        // pop-to-root, then scroll-to-top. It now spans both kinds of row,
        // because a sidebar row is a real destination with its own
        // stack — see `SidebarSelection`.
        let selection = Binding<SidebarSelection>(
            get: {
                coordinator.selectedSidebarRow.map(SidebarSelection.row)
                    ?? .tab(coordinator.selectedTab)
            },
            set: { newValue in
                switch newValue {
                case .tab(let tab):
                    if coordinator.selectedSidebarRow != nil {
                        // Leaving a row for its own parent tab is a move, not a
                        // re-selection, even when the tab value is unchanged.
                        coordinator.selectedSidebarRow = nil
                    } else if tab == coordinator.selectedTab {
                        coordinator.handleTabReselect(tab)
                    }
                    coordinator.selectedTab = tab
                    // Screen provenance for a freeze report. Here rather than on
                    // each tab root's onAppear: a TabView keeps its children
                    // alive, so switching fires no appearance callback and the
                    // noted screen would stay whichever was mounted first.
                    FreezeWatchdog.noteScreen("tab:\(tab)")
                case .row(let row):
                    if coordinator.selectedSidebarRow == row {
                        coordinator.handleSidebarRowReselect(row)
                    }
                    coordinator.selectedSidebarRow = row
                    coordinator.selectedTab = row.parentTab
                    FreezeWatchdog.noteScreen("sidebar:\(row.id)")
                }
            }
        )

        // iOS 18's `Tab` values, not `.tabItem` tags. The value-based form is
        // what `.sidebarAdaptable` needs to morph a declaration into a sidebar
        // on iPad, and it is the only form `Tab(role: .search)` exists in. The
        // re-selection binding above is unchanged — selection still travels
        // through `AppTab`, and the account row is `.tab(.mine)` like the bar's
        // Mine tab, so the two shells select the same values.
        //
        // ONE truth, two arrangements — and the arrangements are two
        // declarations on purpose: `TabSection` exists only in the sidebar, so
        // the bar's version cannot be the same statement with a header. What
        // may not differ is the DATA, which is why both branches read
        // `AppTab.browse`, `tab.titleKey` and `tab.systemImage` rather than
        // repeating literals. Only `.mine` differs between them at all.
        // Native tab/sidebar switching owns root presentation; no authored
        // whole-NavigationStack entrance may replay or reset on selection.
        TabView(selection: selection) {
            // Browsing is the sidebar's FIRST block and carries no heading: a
            // `TabSection` would give it one and a disclosure triangle with it,
            // and these three are the app — not a group the user should be able
            // to fold away. Declared here rather than inside the branch, so the
            // same statement serves both shells.
            //
            // That is also what keeps a size-class crossing cheap. Only `.mine`
            // is declared twice now (an account row in the sidebar, an ordinary
            // tab in the bar); the other four keep one declaration, so a
            // rotation cannot rebuild them.
            ForEach(AppTab.browse, id: \.self) { tab in
                Tab(
                    LocalizedStringKey(tab.titleKey),
                    systemImage: tab.systemImage,
                    value: SidebarSelection.tab(tab)
                ) {
                    stack(for: tab)
                }
                .customizationID(tab.sidebarCustomizationID)
                .defaultVisibility(.automatic, for: .sidebar)
            }

            if showsSidebar {
                // What this account has. The heading this replaced was
                // "Library", borrowed from Music and TV, and it sat BESIDE a
                // Mine tab that owned the same five screens — so the sidebar
                // named the user's own content twice and never named the user.
                // The user is named in the HEADER now, above every row.
                //
                // This one IS a section, and deliberately: the heading says
                // whose five screens these are, and the system's
                // drag-to-reorder edits by section.
                TabSection("My Content") {
                    ForEach(SidebarDestination.myContent) { row in
                        Tab(
                            LocalizedStringKey(row.titleKey),
                            systemImage: row.systemImage,
                            value: SidebarSelection.row(row)
                        ) {
                            sidebarRowScreen(row)
                        }
                        // Only these rows carry an identifier, so only these
                        // rows can be reordered or hidden. The sections' own
                        // members, search and the account row stay where the
                        // user expects them — an account row a user could hide
                        // would take the settings and the log-out with it.
                        .customizationID(row.id)
                        .defaultVisibility(.automatic, for: .sidebar)
                        .defaultVisibility(.hidden, for: .tabBar)
                    }
                }

            }

            // Mine, declared ONCE for both shells: the bar's fourth slot, and
            // hidden in the sidebar because the header above already IS it.
            // Hidden rather than undeclared — a `Tab` has to exist for the
            // value, or `.tab(.mine)` (which the header sets, which a fold
            // produces, and which a deep link can reach) would be a selection
            // no `Tab` declares: the TabView holds it, and the screen the user
            // was on vanishes.
            //
            // It carries a stable ID so the ephemeral detail customization can
            // hide it with the other root tabs. Its root default remains hidden
            // because the sidebar header already represents Mine.
            Tab(
                LocalizedStringKey(AppTab.mine.titleKey),
                systemImage: AppTab.mine.systemImage,
                value: SidebarSelection.tab(.mine)
            ) {
                stack(for: .mine)
            }
            .customizationID(AppTab.mine.sidebarCustomizationID)
            .defaultVisibility(.hidden, for: .sidebar)

            // Declared once, outside the branch, and last in both shells: the
            // system owns a search role's position — pinned to the trailing
            // edge of the bar, its own slot in the sidebar — so declaration
            // order is not what places it, and the app stops inventing one.
            //
            // It is the FIFTH bar item, and the bar holds five. A device run
            // with six (this plus five ordinary tabs) put 我的 into "More",
            // chosen by declaration order rather than importance. Four ordinary
            // tabs is the ceiling; everything else belongs in the sidebar.
            Tab(
                LocalizedStringKey(AppTab.search.titleKey),
                systemImage: AppTab.search.systemImage,
                value: SidebarSelection.tab(.search),
                role: .search
            ) {
                stack(for: .search)
            }
            .customizationID(AppTab.search.sidebarCustomizationID)
            .defaultVisibility(.automatic, for: .sidebar)
        }
        // The header is CONTENT, not decoration, which is why it is attached
        // here and not with `body`'s modifier chain: it is the sidebar's top
        // block, and it is the reason `.tab(.mine)` has no row of its own. The
        // slot exists only in the sidebar, so this costs the tab bar nothing
        // and needs no branch.
        .tabViewSidebarHeader {
            accountHeader(selection: selection)
        }
    }
}
