import Foundation

enum Route: Hashable {
    case videoDetail(VideoRouteTarget)
    case liveRoom(Int, zoom: RouteZoomSource = .none)
    case userSpace(Int)
    case search(SearchType, keyword: String?)
    case favorites
    case history
    case following(mid: Int?)
    case followers(mid: Int?)
    case watchLater
    case downloads
    case offlinePlayer(String, zoom: RouteZoomSource = .none)
    case offlinePager(OfflinePortraitPagingContext, zoom: RouteZoomSource = .none)
    case messages
    case chat(talkerId: Int, name: String, face: String?)
    case favoriteDetail(Int, String)
    case bangumiDetail(Int, zoom: RouteZoomSource = .none)
    case momentDetail(String)
    case articleReader(Int)
    case musicInfo(MusicDestination)
    case inAppWeb(URL)
}

extension Route {
    static func videoDetail(_ id: VideoID) -> Route {
        .videoDetail(VideoRouteTarget(videoID: id))
    }

    var requiresCoverCloseButton: Bool {
        switch self {
        case .momentDetail, .articleReader, .chat, .musicInfo:
            true
        case .videoDetail, .liveRoom, .bangumiDetail, .offlinePlayer, .offlinePager, .inAppWeb,
             .userSpace, .search, .favorites, .favoriteDetail, .history, .following,
             .followers, .watchLater, .downloads, .messages:
            false
        }
    }
}

enum AppTab: Hashable, CaseIterable {
    case home
    case dynamics
    case live
    case mine
    case search
}

extension AppTab {
    static let browse: [AppTab] = [.home, .dynamics, .live]

    var titleKey: String {
        switch self {
        case .home: "Home"
        case .dynamics: "Moments"
        case .live: "Live"
        case .mine: "Mine"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .dynamics: "bolt.horizontal.fill"
        case .live: "play.tv.fill"
        case .mine: "person.fill"
        case .search: "magnifyingglass"
        }
    }

    var sidebarCustomizationID: String {
        switch self {
        case .home: "root-tab.home"
        case .dynamics: "root-tab.dynamics"
        case .live: "root-tab.live"
        case .mine: "root-tab.mine"
        case .search: "root-tab.search"
        }
    }
}

enum VideoID: Hashable, Sendable {
    case aid(Int)
    case bvid(String)

    var queryParam: String {
        switch self {
        case .aid(let id): "aid=\(id)"
        case .bvid(let id): "bvid=\(id)"
        }
    }
}

enum RouteColumn: Hashable, Sendable {
    case content
    case detail

    static func of(_ route: Route) -> RouteColumn {
        switch route {
        case .videoDetail, .liveRoom, .bangumiDetail, .momentDetail,
             .articleReader, .offlinePlayer, .offlinePager, .chat, .musicInfo, .inAppWeb:
            .detail
        case .search, .favorites, .favoriteDetail, .history, .following,
             .followers, .watchLater, .downloads, .messages, .userSpace:
            .content
        }
    }
}

struct NavigationProjection: Equatable, Sendable {
    var contentStack: [Route]
    var detail: Route?

    static let empty = NavigationProjection(contentStack: [], detail: nil)

    static func project(_ stack: [Route]) -> NavigationProjection {
        var projection = NavigationProjection.empty
        for route in stack {
            switch RouteColumn.of(route) {
            case .content: projection.contentStack.append(route)
            case .detail: projection.detail = route
            }
        }
        return projection
    }

    static func contentStack(from stack: [Route]) -> [Route] {
        Array(stack.prefix { RouteColumn.of($0) == .content })
    }

    static func activeDetailRoute(from stack: [Route]) -> Route? {
        guard let route = stack.last, RouteColumn.of(route) == .detail else {
            return nil
        }
        return route
    }
}

struct DetailRouteOccurrence: Hashable {
    let route: Route
    let position: PlayerRoutePosition
}

struct DetailNavigation: Equatable {
    let root: DetailRouteOccurrence
    let path: [DetailRouteOccurrence]

    init?(stack: [Route], tab: AppTab, sidebarID: String?) {
        guard let first = stack.firstIndex(where: { RouteColumn.of($0) == .detail }) else { return nil }
        root = .init(route: stack[first], position: .init(tab: tab, sidebarID: sidebarID, depth: first))
        path = stack.enumerated().dropFirst(first).map { depth, route in
            .init(route: route, position: .init(tab: tab, sidebarID: sidebarID, depth: depth))
        }
    }
}

struct SidebarDestination: Hashable, Sendable, Identifiable {
    let id: String
    let titleKey: String
    let systemImage: String
    let parentTab: AppTab
    let root: Route

    static let myContent: [SidebarDestination] = [
        .init(
            id: "sidebar.favorites", titleKey: "Favorites", systemImage: "star.fill",
            parentTab: .mine, root: .favorites
        ),
        .init(
            id: "sidebar.history", titleKey: "History", systemImage: "clock.arrow.circlepath",
            parentTab: .mine, root: .history
        ),
        .init(
            id: "sidebar.watchLater", titleKey: "Watch Later", systemImage: "clock.fill",
            parentTab: .mine, root: .watchLater
        ),
        .init(
            id: "sidebar.downloads", titleKey: "Downloads", systemImage: "arrow.down.circle.fill",
            parentTab: .mine, root: .downloads
        ),
        .init(
            id: "sidebar.following", titleKey: "Following", systemImage: "person.2.fill",
            parentTab: .mine, root: .following(mid: nil)
        ),
    ]

    // MARK: - Folding

    static func folded(_ row: SidebarDestination, rowStack: [Route]) -> [Route] {
        [row.root] + rowStack
    }

    static func unfolded(tab: AppTab, stack: [Route]) -> (row: SidebarDestination, rowStack: [Route])? {
        guard let first = stack.first,
              let row = myContent.first(where: { $0.parentTab == tab && $0.root == first })
        else { return nil }
        return (row, Array(stack.dropFirst()))
    }

    static func selected(tab: AppTab, stack: [Route]) -> SidebarDestination? {
        unfolded(tab: tab, stack: stack)?.row
    }
}

enum ShellNavigationPolicy {
    static func showsSidebar(isPad: Bool, isRegularWidth: Bool) -> Bool {
        isPad && isRegularWidth
    }
}

enum SidebarSelection: Hashable, Sendable {
    case tab(AppTab)
    case row(SidebarDestination)
}
