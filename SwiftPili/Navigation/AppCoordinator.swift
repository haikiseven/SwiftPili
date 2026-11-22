import SwiftUI

/// Admission for a single animated video-route transition. The navigation path
/// remains append-only so Back history is preserved, but a short burst of taps
/// cannot materialize several VOD detail screens before the first one has
/// reached its activation boundary and claimed its lease.
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

/// A pending request is separate from the route. The route only identifies the
/// video; this request carries the exact comment target until the destination
/// has admitted its metadata and comment list.
struct CommentNavigationRequest: Hashable, Sendable {
    let sequence: UInt64
    let anchor: CommentAnchor
}

/// The route-derived authority for the shared PGC surface. A Bangumi detail
/// does not have an online portrait pager, but it still needs the same rule as
/// VOD: a historical destination may remain in the navigation stack for Back
/// without registering a render attachment or claiming the shared player.
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
    var contentLinkNavigationRevision: UInt64 = 0

    /// Navigation cleans up an existing owner without creating native playback.
    private var routePlayer: PlayerViewModel? {
        PlayerViewModel.existingShared
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

    /// The login screen as a sheet over whatever is on screen, for an entry
    /// that needs an account (the danmaku band's "log in to send"). A sheet and
    /// not a `Route`: pushing login would take the player off the detail page
    /// the user is trying to write on. `RootView` mounts it.
    ///
    /// A fresh item per request, not a Bool: a presentation UIKit refused
    /// (something else was presenting) leaves the binding set, and writing
    /// `true` over `true` would never try again. A new identity does.
    struct LoginPresentation: Identifiable {
        let id = UUID()
    }

    var loginPresentation: LoginPresentation?

    func presentLogin() {
        loginPresentation = LoginPresentation()
    }

    /// One ordered stack per tab, and the whole navigation truth.
    ///
    /// `[Route]` rather than `NavigationPath` because the elements have to be
    /// READABLE: a wide window arranges the same stack into two columns
    /// (`NavigationProjection`), and `NavigationPath` is opaque — it can be
    /// appended to and cleared, never inspected. Nothing else changes; these are
    /// append-only and every push is a `Route`, which is what a typed path
    /// requires and what `navigate(to:)` has always done.
    ///
    /// Four stored properties rather than a `[AppTab: [Route]]` dictionary, so
    /// a push in one tab does not invalidate observers of the other three.
    var homeStack: [Route] = [] {
        willSet {
            if homeStack != newValue { noteContentLinkNavigationChange() }
            guard selectedSidebarRow == nil, selectedTab == .home else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: newValue, tab: .home))
        }
    }
    var dynamicsStack: [Route] = [] {
        willSet {
            if dynamicsStack != newValue { noteContentLinkNavigationChange() }
            guard selectedSidebarRow == nil, selectedTab == .dynamics else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: newValue, tab: .dynamics))
        }
    }
    var liveStack: [Route] = [] {
        willSet {
            if liveStack != newValue { noteContentLinkNavigationChange() }
            guard selectedSidebarRow == nil, selectedTab == .live else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: newValue, tab: .live))
        }
    }
    var mineStack: [Route] = [] {
        willSet {
            if mineStack != newValue { noteContentLinkNavigationChange() }
            guard selectedSidebarRow == nil, selectedTab == .mine else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: newValue, tab: .mine))
        }
    }
    /// The search tab's own stack. `SearchView` is that tab's ROOT now, so a
    /// tapped result has to push somewhere — this is that somewhere. The
    /// `.search(type:keyword:)` ROUTE is unaffected and still pushes into
    /// whichever tab invoked it, which is what keeps "search this tag" from a
    /// video beside the player instead of throwing the user into another tab.
    var searchStack: [Route] = [] {
        willSet {
            if searchStack != newValue { noteContentLinkNavigationChange() }
            guard selectedSidebarRow == nil, selectedTab == .search else { return }
            notifyPlayerRouteChange(to: playerDestination(stack: newValue, tab: .search))
        }
    }

    // MARK: - Sidebar rows

    /// The sidebar row the user is in, or nil when they are at a tab's own
    /// root. Only ever non-nil at regular width: the rows do not exist in a tab
    /// bar, which is what `foldSidebarSelection` exists to reconcile.
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

    /// What is pushed ABOVE each row's own root, keyed by the row's stable id.
    ///
    /// A dictionary here and four stored properties for the tabs, deliberately:
    /// a dictionary mutation invalidates every reader, which matters for tabs
    /// that are all alive at once and not for six rows of which one is visible.
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

    /// Destination construction samples its own stack, including inactive tabs.
    /// The screen retains this position in State across later value rebuilds.
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
    /// The active detail destination consumes this only after its video and
    /// comment metadata are ready. Keeping it observable lets an already-open
    /// video receive a notification without pushing a duplicate route.
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

    /// Regular → compact. The row is about to stop existing, so its position
    /// becomes the push it corresponds to on its parent tab.
    func foldSidebarSelection() {
        guard let row = selectedSidebarRow else { return }
        layoutMigrationDepth += 1
        defer { layoutMigrationDepth -= 1 }
        setStack(SidebarDestination.folded(row, rowStack: sidebarRowStack(for: row)), for: row.parentTab)
        sidebarRowStacks[row.id] = []
        selectedSidebarRow = nil
        selectedTab = row.parentTab
    }

    /// Compact → regular. The inverse, and only when the parent tab is actually
    /// sitting on a row's root — otherwise the position is one no row
    /// describes and it stays where it is.
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

    /// Applies a tab path mutation and retires a popped owner's still only
    /// after the path has been written. `goBack()` parks before it removes the
    /// local last element, so it opts out of the second capture here.
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
            // System pops write this binding and never call goBack(). Park
            // while the outgoing renderer is still attached, then remember the
            // owner so the next park — not this turn — drops the pixels.
            let departedOwner = routePlayer?.parkOutgoingRouteStill()
            switch tab {
            case .home: homeStack = stack
            case .dynamics: dynamicsStack = stack
            case .live: liveStack = stack
            case .mine: mineStack = stack
            case .search: searchStack = stack
            }
            if let departedOwner {
                routePlayer?.retireDepartedRouteStill(owner: departedOwner)
            }
            return
        }
        switch tab {
        case .home: homeStack = stack
        case .dynamics: dynamicsStack = stack
        case .live: liveStack = stack
        case .mine: mineStack = stack
        case .search: searchStack = stack
        }
    }

    /// The sidebar row has its own NavigationStack binding, so its system pop
    /// does not pass through a tab's `setStack`. Keep the same pre-detach
    /// capture and post-write retirement ordering for that path.
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

    /// The stack a wide window would arrange into columns. The full stack is
    /// still the source of truth; this is only a read-only arrangement view.
    func projection(for tab: AppTab) -> NavigationProjection {
        NavigationProjection.project(stack(for: tab))
    }

    /// A tab's stack as a binding, so the shell can declare a tab from a table
    /// instead of writing each `NavigationStack` out by hand. It exists for the
    /// same reason `sidebarRowStackBinding` does: the stacks are stored here, and
    /// `@Bindable` reaches them only inside a `body`, while the shell now builds
    /// its tabs in helpers that are not one.
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

    /// A root NavigationStack keeps the prefix below the outer detail flow
    /// while that host is active. SwiftUI may
    /// write a path while it reconciles that projection; ignoring those writes
    /// prevents the hidden root shell from deleting or reordering compact
    /// back-history. At root and compact widths the binding is direct, so
    /// ordinary NavigationStack pops still update the full stack.
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
        switch tab {
        case .home: homeStack
        case .dynamics: dynamicsStack
        case .live: liveStack
        case .mine: mineStack
        case .search: searchStack
        }
    }

    /// The route currently presented by the active tab/sidebar destination.
    /// This is intentionally derived from navigation state instead of a view
    /// lifecycle callback, because historical destinations can outlive their
    /// window membership during a push/pop animation.
    private var activeTopRoute: Route? {
        if let row = selectedSidebarRow {
            return sidebarRowStacks[row.id]?.last ?? row.root
        }
        return stack(for: selectedTab).last
    }

    /// The one detail route the outer iPad host may render. The route remains
    /// in the same typed stack, so Back/Home and player ownership keep their
    /// existing authority; this is only a presentation projection.
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

    /// Detail routes are rendered without the root iPad tab/sidebar list.
    var activeRouteIsDetail: Bool {
        activeDetailRoute != nil
    }

    /// Whether this Bangumi destination is the sole route allowed to mount or
    /// claim the shared player surface.
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

    /// Bumped when the current tab is tapped again at its root — screens
    /// observe it and scroll their content back to the top.
    private(set) var scrollToTopTick = 0

    /// Tapping the already-selected tab: pop to the tab's root first;
    /// once at the root, scroll to top.
    /// Re-selecting the sidebar row the user is already in: pop what is above
    /// its root first, then scroll to top — the same two-step the tab bar has.
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
        var popping = false
        switch tab {
        case .home:
            guard !homeStack.isEmpty else { break }
            popping = true
            setStack([], for: .home)
        case .dynamics:
            guard !dynamicsStack.isEmpty else { break }
            popping = true
            setStack([], for: .dynamics)
        case .live:
            guard !liveStack.isEmpty else { break }
            popping = true
            setStack([], for: .live)
        case .mine:
            guard !mineStack.isEmpty else { break }
            popping = true
            setStack([], for: .mine)
        case .search:
            guard !searchStack.isEmpty else { break }
            popping = true
            setStack([], for: .search)
        }
        if popping {
            videoNavigationAdmission.cancel()
            pendingCommentNavigation = nil
            return
        }
        scrollToTopTick += 1
    }

    /// Pops exactly one route from the navigation stack that currently owns
    /// the visible screen. This is the action used by the in-player Back
    /// button, so compact NavigationStack paths and iPad sidebar-row paths
    /// keep the same semantics as the system back button.
    func goBack() {
        let costSpan = UIHitchMonitor.beginSpan("nav.back")
        defer { UIHitchMonitor.endSpan(costSpan) }
        videoNavigationAdmission.cancel()
        pendingCommentNavigation = nil
        if let row = selectedSidebarRow {
            guard var rowStack = sidebarRowStacks[row.id], !rowStack.isEmpty else { return }
            // Park before the path changes. The outgoing renderer detaches
            // once this route is no longer top; a later claim sees no pixels.
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

    /// "Home" shortcut on detail screens: pops the current tab's stack
    /// (so playback screens tear down) and lands on the Home tab root.
    func goHome() {
        videoNavigationAdmission.cancel()
        pendingCommentNavigation = nil
        // Explicit stop: onDisappear is unreliable when programmatic path
        // clearing and a tab switch happen in the same transaction. The shared
        // owner-exit gate preserves only an observed PiP lease, never a sticky
        // raw native PiP flag. Every route is leaving, so every still goes
        // with it — a historical page's onDisappear must not be the clearer.
        routePlayer?.endCurrentOwnerPlayback()
        routePlayer?.clearAllOutgoingRouteStills()
        selectedSidebarRow = nil
        sidebarRowStacks.removeAll()
        switch selectedTab {
        case .home: break
        case .dynamics: dynamicsStack = []
        case .live: liveStack = []
        case .mine: mineStack = []
        case .search: searchStack = []
        }
        homeStack = []
        selectedTab = .home
    }

    func navigate(to route: Route) {
        if case .videoDetail(let target) = route {
            navigateToVideo(target)
            return
        }
        contentLinks.cancel()
        pendingCommentNavigation = nil
        // `append` parks the outgoing still before the path write.
        append(route)
    }

    private func append(_ route: Route) {
        let costSpan = UIHitchMonitor.beginSpan("nav.push")
        defer { UIHitchMonitor.endSpan(costSpan) }
        // One push mutation. Park first, while the current owner's renderer
        // is still attached. `navigate` and `navigateToVideo` both land here;
        // a rejected video admission returns before this and must not park.
        if activePlayerDestination != nil {
            routePlayer?.parkOutgoingRouteStill()
        }
        // A sidebar row owns its own stack, so a push from inside one belongs
        // there and not on the parent tab — which is still sitting at whatever
        // the user left it at.
        if let row = selectedSidebarRow {
            sidebarRowStacks[row.id, default: []].append(route)
            return
        }
        switch selectedTab {
        case .home: homeStack.append(route)
        case .dynamics: dynamicsStack.append(route)
        case .live: liveStack.append(route)
        case .mine: mineStack.append(route)
        case .search: searchStack.append(route)
        }
    }

    /// The route names the one tapped video; its preview only feeds the
    /// destination's placeholder.
    @discardableResult
    func navigateToVideo(_ target: VideoRouteTarget) -> Bool {
        guard videoNavigationAdmission.begin(target.videoID) else {
            PlayerLog.log("[Navigation] video route admission rejected — transition pending")
            return false
        }
        contentLinks.cancel()
        pendingCommentNavigation = nil
        // Admitted pushes park in `append`, before the path changes.
        append(.videoDetail(target))
        return true
    }

    /// Called by the destination's `.task` once the pushed route is actually
    /// active. This is an observed lifecycle boundary, not a guessed delay.
    func settleVideoNavigation(_ target: VideoID) {
        videoNavigationAdmission.settle(target)
    }

    /// Cancels only the matching route admission. A historical destination's
    /// disappearance must not release a successor target that is still
    /// starting.
    func cancelVideoNavigation(_ target: VideoID) {
        videoNavigationAdmission.cancel(target)
    }

    /// Requests a typed comment location. An already-active matching video
    /// receives the request in place; every other destination gets the ordinary
    /// video-detail route. No player or surface owner is involved here.
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

    /// The route-derived check intentionally knows only the route's admitted
    /// identity. A historical detail route cannot consume a successor's
    /// request because it is not the top route in the active stack.
    private func isActiveVideoDestination(_ videoID: VideoID) -> Bool {
        switch activeTopRoute {
        case .videoDetail(let target):
            return target.videoID == videoID
        default:
            return false
        }
    }

    /// Finishes a request only when the matching active destination is the
    /// caller. The request stays pending while paging/loading so cancellation
    /// can retry it when the same destination remains visible.
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
        _ = openContentURL(url, context: context)
    }

    // MARK: - Clipboard suggestion

    /// A Bilibili link found on the clipboard, waiting for the user to accept
    /// or dismiss it. Held rather than acted on: the requirement is a
    /// non-disruptive affordance, never navigation the user did not ask for.
    var clipboardSuggestion: ClipboardLinkSuggestion?
    private var clipboardGate = ClipboardSuggestionGate()

    /// Inspects the clipboard, if the setting is on and the content is new.
    ///
    /// Called from a foreground/user-visible point only. Reading a pasteboard's
    /// strings is privacy-visible on iOS, so the generation gate runs FIRST: an
    /// unchanged clipboard is never read at all, no matter how many times the
    /// app foregrounds.
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
            // Not a Bilibili link. Mark it handled so the same non-link text is
            // not re-scanned on every foreground.
            clipboardGate.noteHandled(content: content)
            return
        }
        clipboardSuggestion = suggestion
        PlayerLog.log("[BiliLink] clipboard suggestion: \(suggestion.target)")
    }

    /// Accept: route to the detected target. The content is marked handled so
    /// it is never offered twice.
    func acceptClipboardSuggestion() {
        guard let suggestion = clipboardSuggestion else { return }
        clipboardGate.noteHandled(content: suggestion.sourceContent)
        clipboardSuggestion = nil
        navigate(to: suggestion.target.route)
    }

    /// Dismiss counts as answered — the same content must not prompt again.
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
    /// Canonical folding keeps this suffix and every occurrence unchanged
    /// when a sidebar row moves into or out of its compact parent tab.
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

    /// Only a native prefix pop of the exact current projection is admitted.
    /// The existing setters retain pre-detach still capture and player-route
    /// notification order; the host never owns a copied mutable route array.
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
