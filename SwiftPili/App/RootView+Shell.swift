import SwiftUI
import UIKit

extension RootView {
    var showsSidebar: Bool {
        ShellNavigationPolicy.showsSidebar(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isRegularWidth: horizontalSizeClass == .regular
        )
    }

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

    @ViewBuilder
    private func accountHeader(selection: Binding<SidebarSelection>) -> some View {
        Button {
            selection.wrappedValue = .tab(.mine)
        } label: {
            HStack(spacing: 12) {
                if let account = AccountManager.shared.activeAccount {
                    AvatarImage(urlString: account.avatarURL, size: 56)
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
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

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

    @ViewBuilder
    var shell: some View {
        let selection = Binding<SidebarSelection>(
            get: {
                coordinator.selectedSidebarRow.map(SidebarSelection.row)
                    ?? .tab(coordinator.selectedTab)
            },
            set: { newValue in
                switch newValue {
                case .tab(let tab):
                    if coordinator.selectedSidebarRow != nil {
                        coordinator.selectedSidebarRow = nil
                    } else if tab == coordinator.selectedTab {
                        coordinator.handleTabReselect(tab)
                    }
                    coordinator.selectedTab = tab
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

        TabView(selection: selection) {
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
                TabSection("My Content") {
                    ForEach(SidebarDestination.myContent) { row in
                        Tab(
                            LocalizedStringKey(row.titleKey),
                            systemImage: row.systemImage,
                            value: SidebarSelection.row(row)
                        ) {
                            sidebarRowScreen(row)
                        }
                        .customizationID(row.id)
                        .defaultVisibility(.automatic, for: .sidebar)
                        .defaultVisibility(.hidden, for: .tabBar)
                    }
                }

            }

            Tab(
                LocalizedStringKey(AppTab.mine.titleKey),
                systemImage: AppTab.mine.systemImage,
                value: SidebarSelection.tab(.mine)
            ) {
                stack(for: .mine)
            }
            .customizationID(AppTab.mine.sidebarCustomizationID)
            .defaultVisibility(.hidden, for: .sidebar)

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
        .tabViewSidebarHeader {
            accountHeader(selection: selection)
        }
    }
}
