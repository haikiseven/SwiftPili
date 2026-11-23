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

@Suite("Bilibili Link Parsing & Resolution")
struct BiliLinkParsingTests {
    @Test("Video URLs with query parameters resolve natively instead of failing")
    func videoURLsWithQueryParamsResolveNatively() {
        let withQueries = URL(
            string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2&t=30&spmid=333.1007&share_copy=hi&from=search"
        )!
        #expect(BiliURLParser.localResult(withQueries) == .native(.videoDetail(.bvid("BV1xx411c7mD"))))

        let schemeWithQuery = URL(string: "bilibili://video/BV1xx411c7mD?from=share&t=12")!
        #expect(BiliURLParser.localResult(schemeWithQuery) == .native(.videoDetail(.bvid("BV1xx411c7mD"))))

        let shortVideoPath = URL(string: "https://www.bilibili.com/s/video/av170001?p=3")!
        #expect(BiliURLParser.localResult(shortVideoPath) == .native(.videoDetail(.aid(170001))))

        let festivalURL = URL(string: "https://www.bilibili.com/festival/2025?bvid=bv1xx411c7mD")!
        #expect(BiliURLParser.localResult(festivalURL) == .native(.videoDetail(.bvid("BV1xx411c7mD"))))

        let listURL = URL(string: "https://www.bilibili.com/list/watchlater?bvid=BV1xx411c7mD")!
        #expect(BiliURLParser.localResult(listURL) == .native(.videoDetail(.bvid("BV1xx411c7mD"))))

        let mediaListPath = URL(string: "https://www.bilibili.com/medialist/play/ml12345/BV1xx411c7mD")!
        #expect(BiliURLParser.localResult(mediaListPath) == .native(.videoDetail(.bvid("BV1xx411c7mD"))))

        let mediaListQuery = URL(string: "https://www.bilibili.com/medialist/play/ml12345?aid=456789")!
        #expect(BiliURLParser.localResult(mediaListQuery) == .native(.videoDetail(.aid(456789))))
    }

    @Test("Shortener paths reject false-positive BV/AID codes and resolve valid direct IDs")
    func shortenerPathValidation() {
        let falsePositiveBV = URL(string: "https://b23.tv/bv3K9xQ")!
        #expect(BiliLinkResolver.resolve(url: falsePositiveBV) == .needsRedirect(falsePositiveBV))
        #expect(BiliURLParser.localResult(falsePositiveBV) == nil)

        let numericShortCode = URL(string: "https://b23.tv/123456")!
        #expect(BiliLinkResolver.resolve(url: numericShortCode) == .needsRedirect(numericShortCode))

        let epShortLink = URL(string: "https://b23.tv/ep123456")!
        #expect(BiliLinkResolver.resolve(url: epShortLink) == .needsRedirect(epShortLink))

        let validBVShort = URL(string: "https://b23.tv/BV1xx411c7mD")!
        #expect(BiliURLParser.localResult(validBVShort) == .native(.videoDetail(.bvid("BV1xx411c7mD"))))

        let validAVShort = URL(string: "https://acg.tv/av170001")!
        #expect(BiliURLParser.localResult(validAVShort) == .native(.videoDetail(.aid(170001))))

        let validSeasonShort = URL(string: "https://b23.tv/ss34430")!
        #expect(BiliURLParser.localResult(validSeasonShort) == .native(.bangumiDetail(34430)))

        for domain in ["b23.tv", "bili2233.cn", "acg.tv", "bili22.cn", "bili23.cn", "bili33.cn"] {
            let shortURL = URL(string: "https://\(domain)/AbCdEfG")!
            #expect(BiliLinkHostPolicy.isShortener(shortURL.host) == true)
            #expect(BiliURLParser.handlesContent(shortURL) == true)
            #expect(BiliLinkResolver.resolve(url: shortURL) == .needsRedirect(shortURL))
        }
    }

    @Test("Major Bilibili web paths resolve to native destinations")
    func bilibiliWebPaths() {
        let bangumiSS = URL(string: "https://www.bilibili.com/bangumi/play/ss34430")!
        #expect(BiliURLParser.parse(bangumiSS) == .bangumiDetail(34430))

        let searchAll = URL(string: "https://search.bilibili.com/all?from_source=webcommentline_search&keyword=SwiftUI")!
        #expect(BiliURLParser.parse(searchAll) == .search(.all, keyword: "SwiftUI"))

        let searchVideo = URL(string: "https://search.bilibili.com/video?keyword=Metal")!
        #expect(BiliURLParser.parse(searchVideo) == .search(.video, keyword: "Metal"))

        let searchUser = URL(string: "https://search.bilibili.com/upuser?keyword=Bilibili")!
        #expect(BiliURLParser.parse(searchUser) == .search(.user, keyword: "Bilibili"))

        let mobileSearch = URL(string: "https://m.bilibili.com/search?keyword=iPad")!
        #expect(BiliURLParser.parse(mobileSearch) == .search(.all, keyword: "iPad"))

        let mobileDynamic = URL(string: "https://m.bilibili.com/dynamic/987654321")!
        #expect(BiliURLParser.parse(mobileDynamic) == .momentDetail("987654321"))

        let webDynamic = URL(string: "https://www.bilibili.com/dynamic/987654321")!
        #expect(BiliURLParser.parse(webDynamic) == .momentDetail("987654321"))

        let tDynamic = URL(string: "https://t.bilibili.com/987654321")!
        #expect(BiliURLParser.parse(tDynamic) == .momentDetail("987654321"))

        let opus = URL(string: "https://www.bilibili.com/opus/987654321")!
        #expect(BiliURLParser.parse(opus) == .momentDetail("987654321"))

        let articleUpper = URL(string: "https://www.bilibili.com/read/CV123456")!
        #expect(BiliURLParser.parse(articleUpper) == .articleReader(123456))

        let articleMobilePath = URL(string: "https://www.bilibili.com/read/mobile/123456")!
        #expect(BiliURLParser.parse(articleMobilePath) == .articleReader(123456))

        let articleMobileQuery = URL(string: "https://www.bilibili.com/read/mobile?id=123456")!
        #expect(BiliURLParser.parse(articleMobileQuery) == .articleReader(123456))

        let liveH5 = URL(string: "https://live.bilibili.com/h5/21452505")!
        #expect(BiliURLParser.parse(liveH5) == .liveRoom(21452505))
    }

    @Test("Case-insensitive bilibili:// deep links parse all supported hosts")
    func bilibiliCustomSchemeParsing() {
        #expect(BiliURLParser.parse(URL(string: "bilibili://video/av123")!) == .videoDetail(.aid(123)))
        #expect(BiliURLParser.parse(URL(string: "BILIBILI://video/bv1xx411c7mD")!) == .videoDetail(.bvid("BV1xx411c7mD")))
        #expect(BiliURLParser.parse(URL(string: "bilibili://video/170001")!) == .videoDetail(.aid(170001)))
        #expect(BiliURLParser.parse(URL(string: "bilibili://live/21452505")!) == .liveRoom(21452505))
        #expect(BiliURLParser.parse(URL(string: "bilibili://space/42")!) == .userSpace(42))
        #expect(BiliURLParser.parse(URL(string: "bilibili://author/42")!) == .userSpace(42))
        #expect(BiliURLParser.parse(URL(string: "bilibili://user/42")!) == .userSpace(42))
        #expect(BiliURLParser.parse(URL(string: "bilibili://opus/detail/888999")!) == .momentDetail("888999"))
        #expect(BiliURLParser.parse(URL(string: "bilibili://following/detail/888999")!) == .momentDetail("888999"))
        #expect(BiliURLParser.parse(URL(string: "bilibili://dt/888999")!) == .momentDetail("888999"))
        #expect(BiliURLParser.parse(URL(string: "bilibili://article/cv654")!) == .articleReader(654))
        #expect(BiliURLParser.parse(URL(string: "bilibili://read/654")!) == .articleReader(654))
        #expect(BiliURLParser.parse(URL(string: "bilibili://bangumi/season/34430")!) == .bangumiDetail(34430))
        #expect(BiliURLParser.parse(URL(string: "bilibili://pgc/season/34430")!) == .bangumiDetail(34430))
        #expect(BiliURLParser.parse(URL(string: "bilibili://search?keyword=Swift")!) == .search(.all, keyword: "Swift"))

        let browserVideo = URL(
            string: "bilibili://browser?url=https%3A%2F%2Fwww.bilibili.com%2Fvideo%2FBV1xx411c7mD"
        )!
        #expect(BiliURLParser.parse(browserVideo) == .videoDetail(.bvid("BV1xx411c7mD")))

        let browserActivity = URL(
            string: "bilibili://browser?url=https%3A%2F%2Fwww.bilibili.com%2Fblackboard%2Factivity.html"
        )!
        #expect(
            BiliURLParser.localResult(browserActivity)
                == .native(.inAppWeb(URL(string: "https://www.bilibili.com/blackboard/activity.html")!))
        )
    }

    @Test("Unknown Bilibili HTTP(S) URLs open directly in InAppWebView; unmapped custom schemes remain unsupported")
    func unknownBilibiliWebRoutesToInAppWeb() {
        let activity = URL(string: "https://www.bilibili.com/blackboard/activity-xyz.html?spm_id_from=333.1")!
        #expect(
            BiliURLParser.localResult(activity)
                == .native(.inAppWeb(URL(string: "https://www.bilibili.com/blackboard/activity-xyz.html")!))
        )

        let bangumiEP = URL(string: "https://www.bilibili.com/bangumi/play/ep123456")!
        #expect(BiliURLParser.localResult(bangumiEP) == .native(.inAppWeb(bangumiEP)))

        let unmappedScheme = URL(string: "bilibili://unknown-feature/123")!
        #expect(BiliURLParser.localResult(unmappedScheme) == .unsupported(unmappedScheme))
    }

    @Test("ArticleContentParser preserves anchor links and UIKitDynamicRichTextBuilder strips CJK punctuation")
    func richTextAndArticleLinkExtraction() {
        let html = #"<div id="read-article-holder"><p>See <a href="https://www.bilibili.com/video/BV1xx411c7mD">this video</a> now.</p></div>"#
        let blocks = ArticleContentParser.parse(pageHTML: html)
        #expect(blocks.count == 1)
        if case .paragraph(let attributed) = blocks.first {
            #expect(String(attributed.characters) == "See this video now.")
            let links = attributed.runs.compactMap { $0.link }
            #expect(links == [URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!])
        } else {
            Issue.record("Expected paragraph block")
        }

        let inline = UIKitDynamicRichTextBuilder.inlineLinks(
            in: "点击链接https://b23.tv/abc123。或者看（https://www.bilibili.com/video/BV1xx411c7mD）！"
        )
        #expect(inline["https://b23.tv/abc123"] == URL(string: "https://b23.tv/abc123"))
        #expect(
            inline["https://www.bilibili.com/video/BV1xx411c7mD"]
                == URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")
        )
    }

    @Test("ClipboardLinkDetector supports shortener share links")
    func clipboardShortenerDetection() {
        let shareText = "【测试视频】 https://b23.tv/AbCdEfG"
        let suggestion = ClipboardLinkDetector.suggestion(for: shareText)
        #expect(suggestion?.action == .shortLink(URL(string: "https://b23.tv/AbCdEfG")!))
    }
}
