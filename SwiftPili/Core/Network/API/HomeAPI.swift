import Foundation

enum HomeAPI {
    static func getRecommended(
        freshIdx: Int = 1,
        ps: Int = 30
    ) async throws(BiliError) -> RecommendResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/wbi/index/top/feed/rcmd",
                params: [
                    "version": "1",
                    "feed_version": "V8",
                    "homepage_ver": "1",
                    "fresh_idx": String(freshIdx),
                    "brush": String(freshIdx),
                    "ps": String(ps),
                    "fresh_type": "4",
                ]
            ),
            type: RecommendResult.self
        )
    }

    static func getPopular(
        page: Int = 1,
        pageSize: Int = 20
    ) async throws(BiliError) -> PopularResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/popular",
                params: [
                    "pn": String(page),
                    "ps": String(pageSize),
                ],

            ),
            type: PopularResult.self
        )
    }

    static func getRanking(
        rid: Int = 0,
        type: String = "all"
    ) async throws(BiliError) -> RankingResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/ranking/v2",
                params: [
                    "rid": String(rid),
                    "type": type,
                ],

            ),
            type: RankingResult.self
        )
    }

    static func getPGCIndex(
        indexType: Int = 1,
        page: Int = 1,
        pageSize: Int = 20
    ) async throws(BiliError) -> PGCIndexResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/pgc/season/index/result",
                params: [
                    "season_type": String(indexType),
                    "page": String(page),
                    "pagesize": String(pageSize),
                    "type": "1",
                ],
                baseURL: "https://api.bilibili.com"
            ),
            type: PGCIndexResult.self
        )
    }
}
