import Foundation
import Testing
@testable import SwiftPili

@Suite("Route & Navigation Projection")
struct RouteTests {
    @Test("NavigationProjection.project handles empty, content-only, and mixed stacks")
    func navigationProjectionProject() {
        #expect(NavigationProjection.project([]) == .empty)

        let contentOnly: [Route] = [.favorites, .userSpace(42)]
        #expect(NavigationProjection.project(contentOnly) == NavigationProjection(
            contentStack: [.favorites, .userSpace(42)],
            detail: nil
        ))

        let video1 = Route.videoDetail(.bvid("BV1xx411c7mD"))
        let video2 = Route.videoDetail(.aid(100))
        let mixed: [Route] = [.favorites, video1, .userSpace(7), video2]
        #expect(NavigationProjection.project(mixed) == NavigationProjection(
            contentStack: [.favorites, .userSpace(7)],
            detail: video2
        ))
    }

    @Test("NavigationProjection.contentStack stops at the first detail route")
    func navigationProjectionContentStackPrefix() {
        let video = Route.videoDetail(.aid(1))
        let stack: [Route] = [.history, .userSpace(10), video, .userSpace(20), .liveRoom(99)]
        #expect(NavigationProjection.contentStack(from: stack) == [.history, .userSpace(10)])
        #expect(NavigationProjection.contentStack(from: [video, .userSpace(10)]).isEmpty)
    }

    @Test("NavigationProjection.activeDetailRoute returns tail detail route only")
    func navigationProjectionActiveDetailRoute() {
        let video = Route.videoDetail(.aid(5))
        #expect(NavigationProjection.activeDetailRoute(from: []) == nil)
        #expect(NavigationProjection.activeDetailRoute(from: [.favorites]) == nil)
        #expect(NavigationProjection.activeDetailRoute(from: [.favorites, video]) == video)
        #expect(NavigationProjection.activeDetailRoute(from: [video, .userSpace(12)]) == nil)
    }

    @Test("DetailNavigation extracts root and nested detail path with accurate positions")
    func detailNavigationExtraction() {
        #expect(DetailNavigation(stack: [], tab: .home, sidebarID: nil) == nil)
        #expect(DetailNavigation(stack: [.favorites, .userSpace(1)], tab: .mine, sidebarID: nil) == nil)

        let video = Route.videoDetail(.bvid("BV1test"))
        let user = Route.userSpace(99)
        let live = Route.liveRoom(777)
        let stack: [Route] = [.favorites, video, user, live]

        let detailNav = DetailNavigation(stack: stack, tab: .mine, sidebarID: "sidebar.favorites")
        #expect(detailNav != nil)
        #expect(detailNav?.root == DetailRouteOccurrence(
            route: video,
            position: PlayerRoutePosition(tab: .mine, sidebarID: "sidebar.favorites", depth: 1)
        ))
        #expect(detailNav?.path == [
            DetailRouteOccurrence(
                route: video,
                position: PlayerRoutePosition(tab: .mine, sidebarID: "sidebar.favorites", depth: 1)
            ),
            DetailRouteOccurrence(
                route: user,
                position: PlayerRoutePosition(tab: .mine, sidebarID: "sidebar.favorites", depth: 2)
            ),
            DetailRouteOccurrence(
                route: live,
                position: PlayerRoutePosition(tab: .mine, sidebarID: "sidebar.favorites", depth: 3)
            ),
        ])
    }

    @Test("SidebarDestination.folded and unfolded round-trip for all myContent rows")
    func sidebarDestinationFoldAndUnfold() {
        let nested: [Route] = [.userSpace(123), .videoDetail(.aid(456))]

        for row in SidebarDestination.myContent {
            let folded = SidebarDestination.folded(row, rowStack: nested)
            #expect(folded.first == row.root)
            #expect(Array(folded.dropFirst()) == nested)

            let unfolded = SidebarDestination.unfolded(tab: row.parentTab, stack: folded)
            #expect(unfolded?.row == row)
            #expect(unfolded?.rowStack == nested)
            #expect(SidebarDestination.selected(tab: row.parentTab, stack: folded) == row)
        }

        // Wrong parent tab or non-sidebar root must not unfold.
        let favoritesRow = SidebarDestination.myContent[0]
        let foldedFavorites = SidebarDestination.folded(favoritesRow, rowStack: nested)
        #expect(SidebarDestination.unfolded(tab: .home, stack: foldedFavorites) == nil)
        #expect(SidebarDestination.unfolded(tab: .mine, stack: []) == nil)
        #expect(SidebarDestination.unfolded(tab: .mine, stack: [.messages]) == nil)
    }

    @Test("ShellNavigationPolicy only shows sidebar on regular-width iPad")
    func shellNavigationPolicy() {
        #expect(ShellNavigationPolicy.showsSidebar(isPad: true, isRegularWidth: true) == true)
        #expect(ShellNavigationPolicy.showsSidebar(isPad: true, isRegularWidth: false) == false)
        #expect(ShellNavigationPolicy.showsSidebar(isPad: false, isRegularWidth: true) == false)
        #expect(ShellNavigationPolicy.showsSidebar(isPad: false, isRegularWidth: false) == false)
    }
}
