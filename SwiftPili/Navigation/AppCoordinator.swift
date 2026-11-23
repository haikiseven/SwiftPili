import SwiftUI
import UIKit

struct VideoNavigationAdmission: Equatable, Sendable {
    private(set) var pendingTarget: VideoID?

    mutating func begin(_ target: VideoID) -> Bool {
        guard pendingTarget == nil else { return false }
        pendingTarget = target
        return true
    }

    mutating func settle(_ target: VideoID) {
        guard pendingTarget == target else { return }
        pendingTarget = nil
    }

    mutating func cancel(_ target: VideoID) {
        guard pendingTarget == target else { return }
        pendingTarget = nil
    }

    mutating func cancel() {
        pendingTarget = nil
    }
}

struct CommentNavigationRequest: Hashable, Sendable {
    let sequence: UInt64
    let anchor: CommentAnchor
}

enum BangumiRouteSurfacePolicy {
    static func isActive(seasonID: Int, topRoute: Route?) -> Bool {
        guard case .bangumiDetail(let topSeasonID, _) = topRoute else { return false }
        return topSeasonID == seasonID
    }
}

@MainActor
@Observable
final class AppCoordinator {
    let contentLinks = ContentLinkController()
    @ObservationIgnored var rootLinkContext: ContentLinkContext?
    @ObservationIgnored var activeCoverLinkContext: ContentLinkContext?
    var contentLinkNavigationRevision: UInt64 = 0

    @ObservationIgnored
    private let playbackHookProvider: @MainActor () -> (any NavigationPlaybackHook)?

    init(
        playbackHookProvider: @escaping @MainActor () -> (any NavigationPlaybackHook)? = {
            PlayerViewModel.existingShared
        }
    ) {
        self.playbackHookProvider = playbackHookProvider
    }

    private var routePlayer: (any NavigationPlaybackHook)? {
        playbackHookProvider()
    }

    var selectedTab: AppTab = .home {
        willSet {
            if selectedTab != newValue {
                noteContentLinkNavigationChange()
                if layoutMigrationDepth == 0 {
                    videoNavigationAdmission.cancel()
                }
            }
            guard selectedSidebarRow == nil else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: stack(for: newValue), tab: newValue))
        }
    }

    struct LoginPresentation: Identifiable {
        let id = UUID()
    }

    var loginPresentation: LoginPresentation?

    func presentLogin() {
        loginPresentation = LoginPresentation()
    }

    private var tabStacks: [AppTab: [Route]] = [:] {
        willSet {
            let changed = AppTab.allCases.contains { (tabStacks[$0] ?? []) != (newValue[$0] ?? []) }
            if changed { noteContentLinkNavigationChange() }
            guard selectedSidebarRow == nil else { return }
            let oldActive = tabStacks[selectedTab] ?? []
            let newActive = newValue[selectedTab] ?? []
            guard oldActive != newActive else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: newActive, tab: selectedTab))
        }
    }

    // MARK: - Sidebar rows

    var selectedSidebarRow: SidebarDestination? {
        willSet {
            if selectedSidebarRow != newValue {
                noteContentLinkNavigationChange()
                if layoutMigrationDepth == 0 {
                    videoNavigationAdmission.cancel()
                }
            }
            let destination = if let row = newValue {
                playerDestination(stack: SidebarDestination.folded(row, rowStack: sidebarRowStack(for: row)),
                                  tab: row.parentTab, sidebarID: row.id)
            } else {
                playerDestination(stack: stack(for: selectedTab), tab: selectedTab)
            }
            notifyPlayerRouteChange(to: destination)
        }
    }

    var sidebarRowStacks: [String: [Route]] = [:] {
        willSet {
            if sidebarRowStacks != newValue { noteContentLinkNavigationChange() }
            guard let row = selectedSidebarRow else { return }
            notifyPlayerRouteChange(to: playerDestination(
                stack: SidebarDestination.folded(row, rowStack: newValue[row.id] ?? []),
                tab: row.parentTab, sidebarID: row.id
            ))
        }
    }
    @ObservationIgnored
    private var layoutMigrationDepth = 0

    private func notifyPlayerRouteChange(to destination: PlayerRouteDestination?) {
        guard layoutMigrationDepth == 0 else { return }
        let previous = activePlayerDestination
        guard previous != destination else { return }
        routePlayer?.playerRouteWillChange(from: previous, to: destination)
    }

    private func playerDestination(
        stack: [Route], tab: AppTab, sidebarID: String? = nil
    ) -> PlayerRouteDestination? {
        guard let route = PlayerScreenRoute(route: stack.last) else { return nil }
        let rowID = sidebarID ?? SidebarDestination.unfolded(tab: tab, stack: stack)?.row.id
        return .init(route: route, position: .init(tab: tab, sidebarID: rowID, depth: stack.count - 1))
    }

    var activePlayerDestination: PlayerRouteDestination? {
        if let row = selectedSidebarRow {
            return playerDestination(
                stack: SidebarDestination.folded(row, rowStack: sidebarRowStack(for: row)),
                tab: row.parentTab, sidebarID: row.id
            )
        }
        return playerDestination(stack: stack(for: selectedTab), tab: selectedTab)
    }

    func playerRoutePosition(
        for route: Route, tab: AppTab? = nil, sidebarRow: SidebarDestination? = nil
    ) -> PlayerRoutePosition? {
        let row = sidebarRow ?? (tab == nil ? selectedSidebarRow : nil)
        let originTab = row?.parentTab ?? tab ?? selectedTab
        let routes = row.map { SidebarDestination.folded($0, rowStack: sidebarRowStack(for: $0)) }
            ?? stack(for: originTab)
        guard let depth = routes.lastIndex(of: route) else { return nil }
        let rowID = row?.id ?? SidebarDestination.unfolded(tab: originTab, stack: routes)?.row.id
        return .init(tab: originTab, sidebarID: rowID, depth: depth)
    }
    @ObservationIgnored
    private var videoNavigationAdmission = VideoNavigationAdmission()
    @ObservationIgnored
    private var nextCommentNavigationSequence: UInt64 = 0
    private(set) var pendingCommentNavigation: CommentNavigationRequest?

    func sidebarRowStack(for row: SidebarDestination) -> [Route] {
        sidebarRowStacks[row.id] ?? []
    }

    func sidebarRowStackBinding(
        for row: SidebarDestination,
        hidingDetail: @escaping () -> Bool = { false }
    ) -> Binding<[Route]> {
        projectedStackBinding(
            get: { self.sidebarRowStacks[row.id] ?? [] },
            set: { self.setSidebarRowStack($0, for: row) },
            hidingDetail: hidingDetail
        )
    }

    func foldSidebarSelection() {
        guard let row = selectedSidebarRow else { return }
        layoutMigrationDepth += 1
        defer { layoutMigrationDepth -= 1 }
        setStack(SidebarDestination.folded(row, rowStack: sidebarRowStack(for: row)), for: row.parentTab)
        sidebarRowStacks[row.id] = []
        selectedSidebarRow = nil
        selectedTab = row.parentTab
    }

    func unfoldSidebarSelection() {
        guard selectedSidebarRow == nil,
              let unfolded = SidebarDestination.unfolded(tab: selectedTab, stack: stack(for: selectedTab))
        else { return }
        layoutMigrationDepth += 1
        defer { layoutMigrationDepth -= 1 }
        sidebarRowStacks[unfolded.row.id] = unfolded.rowStack
        setStack([], for: unfolded.row.parentTab)
        selectedSidebarRow = unfolded.row
    }

    private func setStack(_ stack: [Route], for tab: AppTab) {
        setStack(stack, for: tab, parkBeforeWrite: true)
    }

    private func setStack(
        _ stack: [Route],
        for tab: AppTab,
        parkBeforeWrite: Bool
    ) {
        let old = self.stack(for: tab)
        if layoutMigrationDepth == 0,
           selectedSidebarRow == nil,
           tab == selectedTab,
           stack.count < old.count {
            videoNavigationAdmission.cancel()
        }
        let shouldPark = parkBeforeWrite
            && selectedSidebarRow == nil
            && tab == selectedTab
            && stack.count < old.count
        if shouldPark {
            let departedOwner = routePlayer?.parkOutgoingRouteStill()
            tabStacks[tab] = stack
            if let departedOwner {
                routePlayer?.retireDepartedRouteStill(owner: departedOwner)
            }
            return
        }
        tabStacks[tab] = stack
    }

    private func setSidebarRowStack(_ stack: [Route], for row: SidebarDestination) {
        let old = sidebarRowStacks[row.id] ?? []
        if layoutMigrationDepth == 0, selectedSidebarRow?.id == row.id, stack.count < old.count {
            videoNavigationAdmission.cancel()
        }
        let departedOwner = selectedSidebarRow?.id == row.id && stack.count < old.count
            ? routePlayer?.parkOutgoingRouteStill()
            : nil
        sidebarRowStacks[row.id] = stack
        if let departedOwner {
            routePlayer?.retireDepartedRouteStill(owner: departedOwner)
        }
    }

    func projection(for tab: AppTab) -> NavigationProjection {
        NavigationProjection.project(stack(for: tab))
    }

    func stackBinding(
        for tab: AppTab,
        hidingDetail: @escaping () -> Bool = { false }
    ) -> Binding<[Route]> {
        projectedStackBinding(
            get: { self.stack(for: tab) },
            set: { self.setStack($0, for: tab) },
            hidingDetail: hidingDetail
        )
    }

    private func projectedStackBinding(
        get fullStack: @escaping () -> [Route],
        set setFullStack: @escaping ([Route]) -> Void,
        hidingDetail: @escaping () -> Bool
    ) -> Binding<[Route]> {
        Binding(
            get: {
                hidingDetail()
                    ? NavigationProjection.contentStack(from: fullStack())
                    : fullStack()
            },
            set: { projectedStack in
                guard !hidingDetail() else { return }
                setFullStack(projectedStack)
            }
        )
    }

    func stack(for tab: AppTab) -> [Route] {
        tabStacks[tab] ?? []
    }

    private var activeTopRoute: Route? {
        if let row = selectedSidebarRow {
            return sidebarRowStacks[row.id]?.last ?? row.root
        }
        return stack(for: selectedTab).last
    }

    var activeDetailRoute: Route? {
        if let row = selectedSidebarRow {
            return NavigationProjection.activeDetailRoute(
                from: SidebarDestination.folded(
                    row,
                    rowStack: sidebarRowStack(for: row)
                )
            )
        }
        return NavigationProjection.activeDetailRoute(from: stack(for: selectedTab))
    }

    var activeRouteIsDetail: Bool {
        activeDetailRoute != nil
    }

    func isActiveBangumiRoute(_ seasonID: Int) -> Bool {
        BangumiRouteSurfacePolicy.isActive(seasonID: seasonID, topRoute: activeTopRoute)
    }

    func isActivePlayerRoute(_ route: PlayerScreenRoute) -> Bool {
        PlayerScreenRoute(route: activeTopRoute) == route
    }

    func isActivePlayerRoute(_ route: PlayerScreenRoute, position: PlayerRoutePosition?) -> Bool {
        guard let position else { return false }
        return activePlayerDestination == .init(route: route, position: position)
    }

    private(set) var scrollToTopTick = 0

    func handleSidebarRowReselect(_ row: SidebarDestination) {
        if !sidebarRowStack(for: row).isEmpty {
            if let departedOwner = routePlayer?.parkOutgoingRouteStill() {
                routePlayer?.retireDepartedRouteStill(owner: departedOwner)
            }
            sidebarRowStacks[row.id] = []
            videoNavigationAdmission.cancel()
            pendingCommentNavigation = nil
            return
        }
        scrollToTopTick += 1
    }

    func handleTabReselect(_ tab: AppTab) {
        if !stack(for: tab).isEmpty {
            setStack([], for: tab)
            videoNavigationAdmission.cancel()
            pendingCommentNavigation = nil
            return
        }
        scrollToTopTick += 1
    }

    func goBack() {
        let costSpan = UIHitchMonitor.beginSpan("nav.back")
        defer { UIHitchMonitor.endSpan(costSpan) }
        videoNavigationAdmission.cancel()
        pendingCommentNavigation = nil
        if let row = selectedSidebarRow {
            guard var rowStack = sidebarRowStacks[row.id], !rowStack.isEmpty else { return }
            let departedOwner = routePlayer?.parkOutgoingRouteStill()
            rowStack.removeLast()
            sidebarRowStacks[row.id] = rowStack
            if let departedOwner {
                routePlayer?.retireDepartedRouteStill(owner: departedOwner)
            }
            return
        }

        var current = stack(for: selectedTab)
        guard !current.isEmpty else { return }
        let departedOwner = routePlayer?.parkOutgoingRouteStill()
        current.removeLast()
        setStack(current, for: selectedTab, parkBeforeWrite: false)
        if let departedOwner {
            routePlayer?.retireDepartedRouteStill(owner: departedOwner)
        }
    }

    func goHome() {
        videoNavigationAdmission.cancel()
        pendingCommentNavigation = nil
        routePlayer?.endCurrentOwnerPlayback()
        routePlayer?.clearAllOutgoingRouteStills()
        if selectedTab != .home {
            tabStacks[selectedTab] = []
        }
        tabStacks[.home] = []
        selectedSidebarRow = nil
        sidebarRowStacks.removeAll()
        selectedTab = .home
    }

    func resetForAccountChange() {
        contentLinks.cancel()
        videoNavigationAdmission.cancel()
        pendingCommentNavigation = nil
        routePlayer?.endCurrentOwnerPlayback()
        routePlayer?.clearAllOutgoingRouteStills()
        tabStacks.removeAll()
        selectedSidebarRow = nil
        sidebarRowStacks.removeAll()
        selectedTab = .home
        loginPresentation = nil
    }

    func navigate(to route: Route) {
        if case .videoDetail(let target) = route {
            navigateToVideo(target)
            return
        }
        contentLinks.cancel()
        pendingCommentNavigation = nil
        append(route)
    }

    private func append(_ route: Route) {
        let costSpan = UIHitchMonitor.beginSpan("nav.push")
        defer { UIHitchMonitor.endSpan(costSpan) }
        if activePlayerDestination != nil {
            routePlayer?.parkOutgoingRouteStill()
        }
        if let row = selectedSidebarRow {
            sidebarRowStacks[row.id, default: []].append(route)
            return
        }
        tabStacks[selectedTab, default: []].append(route)
    }

    @discardableResult
    func navigateToVideo(_ target: VideoRouteTarget) -> Bool {
        guard videoNavigationAdmission.begin(target.videoID) else {
            PlayerLog.log("[Navigation] video route admission rejected — transition pending")
            return false
        }
        contentLinks.cancel()
        pendingCommentNavigation = nil
        append(.videoDetail(target))
        return true
    }

    func settleVideoNavigation(_ target: VideoID) {
        videoNavigationAdmission.settle(target)
    }

    func cancelVideoNavigation(_ target: VideoID) {
        videoNavigationAdmission.cancel(target)
    }

    func navigate(to anchor: CommentAnchor) {
        if isActiveVideoDestination(anchor.videoID) {
            contentLinks.cancel()
            nextCommentNavigationSequence &+= 1
            pendingCommentNavigation = CommentNavigationRequest(
                sequence: nextCommentNavigationSequence,
                anchor: anchor
            )
            return
        }
        guard videoNavigationAdmission.begin(anchor.videoID) else {
            PlayerLog.log("[Navigation] video route admission rejected — transition pending")
            return
        }
        contentLinks.cancel()
        nextCommentNavigationSequence &+= 1
        pendingCommentNavigation = CommentNavigationRequest(
            sequence: nextCommentNavigationSequence,
            anchor: anchor
        )
        append(.videoDetail(anchor.videoID))
    }

    private func isActiveVideoDestination(_ videoID: VideoID) -> Bool {
        switch activeTopRoute {
        case .videoDetail(let target):
            return target.videoID == videoID
        default:
            return false
        }
    }

    @discardableResult
    func consumeCommentNavigation(
        _ request: CommentNavigationRequest,
        for videoID: VideoID
    ) -> Bool {
        guard pendingCommentNavigation == request,
              request.anchor.videoID == videoID,
              isActiveVideoDestination(videoID)
        else { return false }
        pendingCommentNavigation = nil
        return true
    }

    func handle(url: URL, context: ContentLinkContext? = nil) {
        if BiliURLParser.handlesContent(url) {
            _ = openContentURL(url, context: context)
            return
        }
        contentLinks.cancel()
        guard (context ?? activeCoverLinkContext ?? rootLinkContext)?.isCurrent() != false else { return }
        if BiliLinkHostPolicy.isSupportedScheme(url.scheme) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Clipboard suggestion

    var clipboardSuggestion: ClipboardLinkSuggestion?
    private var clipboardGate = ClipboardSuggestionGate()

    func inspectClipboardForLink(
        changeCount: Int,
        readContent: () -> String?
    ) {
        guard UserDefaults.standard.bool(forKey: ClipboardLinkDetector.settingsKey) else { return }
        guard clipboardGate.shouldInspect(changeCount: changeCount) else { return }
        clipboardGate.noteInspected(changeCount: changeCount)
        guard let content = readContent(), !content.isEmpty else { return }
        guard clipboardGate.shouldSuggest(content: content) else { return }
        guard let suggestion = ClipboardLinkDetector.suggestion(for: content) else {
            clipboardGate.noteHandled(content: content)
            return
        }
        clipboardSuggestion = suggestion
        PlayerLog.log("[BiliLink] clipboard suggestion: \(suggestion.action)")
    }

    func acceptClipboardSuggestion() {
        guard let suggestion = clipboardSuggestion else { return }
        clipboardGate.noteHandled(content: suggestion.sourceContent)
        clipboardSuggestion = nil
        switch suggestion.action {
        case .target(let target):
            navigate(to: target.route)
        case .shortLink(let url):
            _ = openContentURL(url)
        }
    }

    func dismissClipboardSuggestion() {
        guard let suggestion = clipboardSuggestion else { return }
        clipboardGate.noteHandled(content: suggestion.sourceContent)
        clipboardSuggestion = nil
    }
}

extension AppCoordinator {
    @ViewBuilder
    func destination(for route: Route, position: PlayerRoutePosition? = nil) -> some View {
        let routePosition = position ?? playerRoutePosition(for: route)
        switch route {
        case .videoDetail(let target):
            VideoDetailView(target: target, routePosition: routePosition)
                .videoZoomDestination(sourceID: target.zoomSourceID)
        case .liveRoom(let roomID, let zoom):
            LiveRoomView(roomID: roomID, routePosition: routePosition)
                .zoomDestination(zoom)
        case .userSpace(let mid):
            UserSpaceView(mid: mid)
                .toolbar(.visible, for: .navigationBar)
        case .search(let type, let keyword):
            SearchView(initialType: type, initialKeyword: keyword)
                .toolbar(.visible, for: .navigationBar)
        case .favorites:
            FavoritesView()
                .toolbar(.visible, for: .navigationBar)
        case .history:
            FullHistoryView()
                .toolbar(.visible, for: .navigationBar)
        case .following(let mid):
            FollowingListView(mode: .following, mid: mid)
                .toolbar(.visible, for: .navigationBar)
        case .followers(let mid):
            FollowingListView(mode: .followers, mid: mid)
                .toolbar(.visible, for: .navigationBar)
        case .watchLater:
            WatchLaterListView()
                .toolbar(.visible, for: .navigationBar)
        case .downloads:
            DownloadsView()
                .toolbar(.visible, for: .navigationBar)
        case .messages:
            MessageCenterView()
                .toolbar(.visible, for: .navigationBar)
        case .offlinePlayer(let id, let zoom):
            OfflinePlayerView(pagingContext: .single(id), routePosition: routePosition)
                .zoomDestination(zoom)
        case .offlinePager(let context, let zoom):
            OfflinePlayerView(pagingContext: context, routePosition: routePosition)
                .zoomDestination(zoom)
        case .chat(let talkerId, let name, let face):
            ChatView(talkerId: talkerId, name: name, face: face)
                .toolbar(.visible, for: .navigationBar)
        case .favoriteDetail(let mediaId, let title):
            FavoriteDetailView(mediaId: mediaId, title: title)
                .toolbar(.visible, for: .navigationBar)
        case .bangumiDetail(let seasonId, let zoom):
            BangumiDetailView(seasonId: seasonId, routePosition: routePosition)
                .zoomDestination(zoom)
        case .momentDetail(let dynamicId):
            MomentDetailView(dynamicId: dynamicId)
                .toolbar(.visible, for: .navigationBar)
        case .articleReader(let cvid):
            ArticleReaderView(cvid: cvid)
                .toolbar(.visible, for: .navigationBar)
        case .musicInfo, .inAppWeb:
            contentLinkDestination(for: route)
        }
    }
    var detailNavigation: DetailNavigation? {
        if let row = selectedSidebarRow {
            return DetailNavigation(
                stack: SidebarDestination.folded(row, rowStack: sidebarRowStack(for: row)),
                tab: row.parentTab, sidebarID: row.id
            )
        }
        let routes = stack(for: selectedTab)
        return DetailNavigation(
            stack: routes, tab: selectedTab,
            sidebarID: SidebarDestination.unfolded(tab: selectedTab, stack: routes)?.row.id
        )
    }

    @discardableResult
    func popDetailNavigation(
        to path: [DetailRouteOccurrence], from navigation: DetailNavigation
    ) -> Bool {
        guard detailNavigation == navigation,
              path.count < navigation.path.count,
              navigation.path.prefix(path.count).elementsEqual(path)
        else { return false }
        videoNavigationAdmission.cancel()
        pendingCommentNavigation = nil
        let removedCount = navigation.path.count - path.count
        if let row = selectedSidebarRow {
            setSidebarRowStack(Array(sidebarRowStack(for: row).dropLast(removedCount)), for: row)
        } else {
            setStack(Array(stack(for: selectedTab).dropLast(removedCount)), for: selectedTab)
        }
        return true
    }
}
