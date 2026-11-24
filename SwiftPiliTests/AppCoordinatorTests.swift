import Foundation
import Testing
@testable import SwiftPili

@MainActor
private final class MockNavigationPlaybackHook: NavigationPlaybackHook {
    struct RouteChange: Equatable {
        let from: PlayerRouteDestination?
        let to: PlayerRouteDestination?
    }

    var routeChanges: [RouteChange] = []
    var parkCount = 0
    var nextParkedOwner: String? = "mock-owner"
    var retiredOwners: [String] = []
    var endPlaybackCount = 0
    var clearStillsCount = 0

    func playerRouteWillChange(from old: PlayerRouteDestination?, to new: PlayerRouteDestination?) {
        routeChanges.append(RouteChange(from: old, to: new))
    }

    @discardableResult
    func parkOutgoingRouteStill() -> String? {
        parkCount += 1
        return nextParkedOwner
    }

    func retireDepartedRouteStill(owner: String) {
        retiredOwners.append(owner)
    }

    func endCurrentOwnerPlayback() {
        endPlaybackCount += 1
    }

    func clearAllOutgoingRouteStills() {
        clearStillsCount += 1
    }
}

@Suite("AppCoordinator")
@MainActor
struct AppCoordinatorTests {
    private func makeCoordinator() -> (AppCoordinator, MockNavigationPlaybackHook) {
        let hook = MockNavigationPlaybackHook()
        let coordinator = AppCoordinator(playbackHookProvider: { hook })
        return (coordinator, hook)
    }

    @Test("Tab stack push, pop, and reselect maintain per-tab isolation")
    func tabStackPushPopReselect() {
        let (coordinator, hook) = makeCoordinator()

        coordinator.navigate(to: .userSpace(1))
        coordinator.navigate(to: .favorites)
        #expect(coordinator.stack(for: .home) == [.userSpace(1), .favorites])
        #expect(coordinator.stack(for: .dynamics).isEmpty)

        coordinator.selectedTab = .dynamics
        coordinator.navigate(to: .momentDetail("dyn-1"))
        #expect(coordinator.stack(for: .dynamics) == [.momentDetail("dyn-1")])
        #expect(coordinator.stack(for: .home) == [.userSpace(1), .favorites])

        // goBack pops only the active tab and parks/retires outgoing route still.
        coordinator.goBack()
        #expect(coordinator.stack(for: .dynamics).isEmpty)
        #expect(hook.parkCount == 1)
        #expect(hook.retiredOwners == ["mock-owner"])

        // Reselecting a tab with routes clears its stack without bumping scrollToTopTick.
        coordinator.selectedTab = .home
        let initialTick = coordinator.scrollToTopTick
        coordinator.handleTabReselect(.home)
        #expect(coordinator.stack(for: .home).isEmpty)
        #expect(coordinator.scrollToTopTick == initialTick)

        // Reselecting an already-empty tab increments scrollToTopTick.
        coordinator.handleTabReselect(.home)
        #expect(coordinator.scrollToTopTick == initialTick + 1)
    }

    @Test("Sidebar unfold and fold preserve routes without firing spurious player route changes")
    func sidebarFoldAndUnfold() {
        let (coordinator, hook) = makeCoordinator()
        let favoritesRow = SidebarDestination.myContent[0]
        let video = VideoRouteTarget(videoID: .aid(101))

        coordinator.selectedTab = .mine
        coordinator.navigate(to: favoritesRow.root)
        #expect(coordinator.navigateToVideo(video))
        coordinator.settleVideoNavigation(video.videoID)
        hook.routeChanges.removeAll()

        // Unfolding extracts the sidebar row and keeps activePlayerDestination identical.
        coordinator.unfoldSidebarSelection()
        #expect(coordinator.selectedSidebarRow == favoritesRow)
        #expect(coordinator.sidebarRowStack(for: favoritesRow) == [.videoDetail(video)])
        #expect(coordinator.stack(for: .mine).isEmpty)
        #expect(hook.routeChanges.isEmpty)

        // Folding moves the row stack back into .mine without notifying a route change.
        coordinator.foldSidebarSelection()
        #expect(coordinator.selectedSidebarRow == nil)
        #expect(coordinator.selectedTab == .mine)
        #expect(coordinator.stack(for: .mine) == [favoritesRow.root, .videoDetail(video)])
        #expect(coordinator.sidebarRowStack(for: favoritesRow).isEmpty)
        #expect(hook.routeChanges.isEmpty)
    }

    @Test("resetForAccountChange clears all stacks, sidebar state, pending admission, comments, and login")
    func resetForAccountChange() {
        let (coordinator, hook) = makeCoordinator()
        let favoritesRow = SidebarDestination.myContent[0]
        let anchor = CommentAnchor(videoID: .bvid("BV1reset"), oid: 555, rpid: 999)

        // Populate multiple tabs, a sidebar row with active video, pending admission, comment anchor, and login.
        coordinator.navigate(to: .videoDetail(.aid(1)))
        coordinator.settleVideoNavigation(.aid(1))

        coordinator.selectedTab = .dynamics
        coordinator.navigate(to: .userSpace(42))

        coordinator.selectedTab = .mine
        coordinator.selectedSidebarRow = favoritesRow
        coordinator.navigate(to: anchor)
        coordinator.presentLogin()

        // While video admission is still pending, another video push is rejected.
        #expect(!coordinator.navigateToVideo(VideoRouteTarget(videoID: .aid(2))))
        #expect(coordinator.pendingCommentNavigation?.anchor == anchor)
        #expect(coordinator.loginPresentation != nil)

        hook.routeChanges.removeAll()
        coordinator.resetForAccountChange()

        #expect(coordinator.selectedTab == .home)
        #expect(coordinator.selectedSidebarRow == nil)
        #expect(coordinator.sidebarRowStacks.isEmpty)
        for tab in AppTab.allCases {
            #expect(coordinator.stack(for: tab).isEmpty)
        }
        #expect(coordinator.pendingCommentNavigation == nil)
        #expect(coordinator.loginPresentation == nil)
        #expect(hook.endPlaybackCount == 1)
        #expect(hook.clearStillsCount == 1)

        // Exactly one route change notification from the active sidebar video to nil (no bounce through .home video).
        #expect(hook.routeChanges.count == 1)
        #expect(hook.routeChanges.first?.from?.route == .video(.bvid("BV1reset")))
        #expect(hook.routeChanges.first?.to == nil)

        // Video admission was cancelled, so a fresh video navigation succeeds immediately.
        #expect(coordinator.navigateToVideo(VideoRouteTarget(videoID: .aid(3))))
    }

    @Test("Independent coordinator instances isolate multi-window state completely")
    func multiWindowCoordinatorIsolation() {
        let (windowOne, hookOne) = makeCoordinator()
        let (windowTwo, hookTwo) = makeCoordinator()

        windowOne.selectedTab = .dynamics
        windowOne.navigate(to: .videoDetail(.aid(11)))
        windowOne.presentLogin()

        windowTwo.selectedTab = .live
        windowTwo.navigate(to: .liveRoom(222))

        #expect(windowOne.selectedTab == .dynamics)
        #expect(windowOne.stack(for: .dynamics) == [.videoDetail(.aid(11))])
        #expect(windowOne.stack(for: .live).isEmpty)
        #expect(windowOne.loginPresentation != nil)

        #expect(windowTwo.selectedTab == .live)
        #expect(windowTwo.stack(for: .live) == [.liveRoom(222)])
        #expect(windowTwo.stack(for: .dynamics).isEmpty)
        #expect(windowTwo.loginPresentation == nil)

        #expect(hookOne.routeChanges.count == 1)
        #expect(hookOne.routeChanges.first?.to?.route == .video(.aid(11)))
        #expect(hookTwo.routeChanges.count == 1)
        #expect(hookTwo.routeChanges.first?.to?.route == .live(222))

        // Resetting windowOne does not disturb windowTwo.
        windowOne.resetForAccountChange()
        #expect(windowOne.stack(for: .dynamics).isEmpty)
        #expect(windowTwo.selectedTab == .live)
        #expect(windowTwo.stack(for: .live) == [.liveRoom(222)])
        #expect(hookTwo.endPlaybackCount == 0)
    }

    @Test("Independent AppNoticeCenter instances isolate scene-scoped notices")
    func multiWindowNoticeCenterIsolation() {
        let sceneOne = AppNoticeCenter()
        let sceneTwo = AppNoticeCenter()

        sceneOne.show("Window 1 notice", style: .success)
        #expect(sceneOne.message?.text == "Window 1 notice")
        #expect(sceneOne.message?.style == .success)
        #expect(sceneTwo.message == nil)
    }

    @Test("Playback hook receives accurate transitions on push, tab switch, and detail pop")
    func playbackHookNotifications() throws {
        let (coordinator, hook) = makeCoordinator()
        let v1 = VideoRouteTarget(videoID: .aid(10))
        let v2 = VideoRouteTarget(videoID: .aid(20))

        #expect(coordinator.navigateToVideo(v1))
        coordinator.settleVideoNavigation(v1.videoID)
        let dest1 = PlayerRouteDestination(
            route: .video(.aid(10)),
            position: PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 0)
        )
        #expect(hook.routeChanges == [.init(from: nil, to: dest1)])

        // Pushing v2 on top of v1 parks the outgoing still and notifies v1 -> v2.
        #expect(coordinator.navigateToVideo(v2))
        coordinator.settleVideoNavigation(v2.videoID)
        let dest2 = PlayerRouteDestination(
            route: .video(.aid(20)),
            position: PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 1)
        )
        #expect(hook.parkCount == 1)
        #expect(hook.routeChanges.last == .init(from: dest1, to: dest2))

        // Switching to an empty tab notifies v2 -> nil, switching back notifies nil -> v2.
        coordinator.selectedTab = .search
        #expect(hook.routeChanges.last == .init(from: dest2, to: nil))
        coordinator.selectedTab = .home
        #expect(hook.routeChanges.last == .init(from: nil, to: dest2))

        // popDetailNavigation pops back to v1 and notifies v2 -> v1.
        let currentDetailNav = try #require(coordinator.detailNavigation)
        #expect(coordinator.popDetailNavigation(to: [currentDetailNav.root], from: currentDetailNav))
        #expect(coordinator.stack(for: .home) == [.videoDetail(v1)])
        #expect(hook.routeChanges.last == .init(from: dest2, to: dest1))
    }

    @Test("Direct route activation queries reflect active player routes immediately without appearance gating")
    func directRouteActivationAndAdmissionCancel() {
        let (coordinator, _) = makeCoordinator()
        let v1 = VideoRouteTarget(videoID: .bvid("BV1direct001"))
        let v2 = VideoRouteTarget(videoID: .bvid("BV1direct002"))

        // Pushing a video activates its player route immediately; pending admission blocks duplicates until settled/cancelled.
        #expect(coordinator.navigateToVideo(v1))
        let pos1 = coordinator.playerRoutePosition(for: .videoDetail(v1))
        #expect(pos1 == PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 0))
        #expect(coordinator.isActivePlayerRoute(.video(v1.videoID)))
        #expect(coordinator.isActivePlayerRoute(.video(v1.videoID), position: pos1))
        #expect(!coordinator.isActivePlayerRoute(.video(v1.videoID), position: nil))
        #expect(!coordinator.navigateToVideo(v2))

        // Cancelling the pending video admission allows a subsequent video push immediately.
        coordinator.cancelVideoNavigation(v1.videoID)
        #expect(coordinator.navigateToVideo(v2))
        let pos2 = coordinator.playerRoutePosition(for: .videoDetail(v2))
        #expect(pos2 == PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 1))
        #expect(coordinator.isActivePlayerRoute(.video(v2.videoID), position: pos2))
        #expect(!coordinator.isActivePlayerRoute(.video(v1.videoID), position: pos1))
        coordinator.settleVideoNavigation(v2.videoID)

        // Bangumi, Live, and Offline routes become active immediately upon push.
        coordinator.navigate(to: .bangumiDetail(34430))
        #expect(coordinator.isActiveBangumiRoute(34430))
        #expect(!coordinator.isActiveBangumiRoute(99999))
        #expect(coordinator.isActivePlayerRoute(.bangumi(34430)))

        coordinator.navigate(to: .liveRoom(21452505))
        #expect(!coordinator.isActiveBangumiRoute(34430))
        #expect(coordinator.isActivePlayerRoute(.live(21452505)))

        coordinator.navigate(to: .offlinePlayer("dl-offline-1"))
        #expect(coordinator.isActivePlayerRoute(.offline(.single("dl-offline-1"))))
        #expect(!coordinator.isActivePlayerRoute(.live(21452505)))
    }
}
