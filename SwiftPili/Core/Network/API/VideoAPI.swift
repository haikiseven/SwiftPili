import Foundation

enum VideoAPI {
    static func getVideoInfo(id: VideoID) async throws(BiliError) -> VideoInfo {
        var params: [String: String] = [:]
        switch id {
        case .aid(let aid): params["aid"] = String(aid)
        case .bvid(let bvid): params["bvid"] = bvid
        }

        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/web-interface/view", params: params),
            type: VideoInfo.self
        )
    }

    static func getPlayURL(
        aid: Int,
        cid: Int,
        quality: Int = 80,
        fnval: Int = 16
    ) async throws(BiliError) -> PlayURLResult {
        try await getPlayURL(id: ["avid": String(aid)], cid: cid, quality: quality, fnval: fnval)
    }

    static func getPlayURL(
        bvid: String,
        cid: Int,
        quality: Int = 80,
        fnval: Int = 16
    ) async throws(BiliError) -> PlayURLResult {
        try await getPlayURL(id: ["bvid": bvid], cid: cid, quality: quality, fnval: fnval)
    }

    private static func getPlayURL(
        id: [String: String],
        cid: Int,
        quality: Int,
        fnval: Int
    ) async throws(BiliError) -> PlayURLResult {
        var params = id
        params["cid"] = String(cid)
        params["qn"] = String(quality)
        params["fnval"] = String(fnval)
        params["fourk"] = "1"
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/player/wbi/playurl", params: params, signType: .wbi),
            type: PlayURLResult.self
        )
    }

    static func getOnlineTotal(aid: Int, cid: Int) async throws(BiliError) -> OnlineTotalResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/player/online/total",
                params: ["aid": String(aid), "cid": String(cid)]
            ),
            type: OnlineTotalResult.self
        )
    }

    static func getPlayerInfo(aid: Int, cid: Int) async throws(BiliError) -> PlayerV2Info {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/player/wbi/v2",
                params: ["aid": String(aid), "cid": String(cid)]
            ),
            type: PlayerV2Info.self
        )
    }

    static func getTags(aid: Int, cid: Int? = nil) async throws(BiliError) -> [VideoTag] {
        var params: [String: String] = ["aid": String(aid)]
        if let cid { params["cid"] = String(cid) }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/web-interface/view/detail/tag", params: params),
            type: [VideoTag].self
        )
    }

    static func getRelated(aid: Int) async throws(BiliError) -> [VideoCard] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/archive/related",
                params: ["aid": String(aid)],

            ),
            type: [VideoCard].self
        )
    }

    // MARK: - Interactions

    static func like(aid: Int, like: Bool) async throws(BiliError) -> LikeResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/archive/like",
                method: .post,
                params: ["aid": String(aid), "like": like ? "1" : "2", "csrf": csrf],

            ),
            type: LikeResult.self
        )
    }

    static func addCoin(aid: Int, multiply: Int = 1) async throws(BiliError) -> CoinResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/coin/add",
                method: .post,
                params: [
                    "aid": String(aid), "multiply": String(multiply),
                    "select_like": "0", "csrf": csrf,
                ],
                headers: ["Referer": "https://www.bilibili.com/video/av\(aid)/"]
            ),
            type: CoinResult.self
        )
    }

    static func share(aid: Int) async throws(BiliError) -> ShareResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/share/add",
                method: .post,
                params: ["aid": String(aid), "csrf": csrf]
            ),
            type: ShareResult.self
        )
    }

    static func hasLiked(aid: Int) async throws(BiliError) -> Int {
        let result: HasLikedResult = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/archive/has/like",
                params: ["aid": String(aid)],

            ),
            type: HasLikedResult.self
        )
        return result.liked ?? 0
    }

    static func hasCoined(aid: Int) async throws(BiliError) -> Int {
        let result: HasCoinedResult = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/archive/coins",
                params: ["aid": String(aid)],

            ),
            type: HasCoinedResult.self
        )
        return result.multiply ?? 0
    }

    static func hasFavoured(aid: Int) async throws(BiliError) -> Bool {
        let result: HasFavouredResult = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/fav/video/favoured",
                params: ["aid": String(aid)],

            ),
            type: HasFavouredResult.self
        )
        return result.favoured ?? false
    }

    static func getFavFolders(aid: Int) async throws(BiliError) -> [FavFolderListResult.FavFolder] {
        guard let mid = AuthManager.shared.dedeUserID else { throw .authRequired }
        let result: FavFolderListResult = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/created/list-all",
                params: ["up_mid": mid, "type": "2", "rid": String(aid)]
            ),
            type: FavFolderListResult.self
        )
        return result.list ?? []
    }

    static func dealFavorite(aid: Int, addIds: [Int], delIds: [Int]) async throws(BiliError) -> FavoriteResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        var params: [String: String] = ["rid": String(aid), "type": "2", "csrf": csrf]
        if !addIds.isEmpty {
            params["add_media_ids"] = addIds.map(String.init).joined(separator: ",")
        }
        if !delIds.isEmpty {
            params["del_media_ids"] = delIds.map(String.init).joined(separator: ",")
        }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/resource/deal",
                method: .post,
                params: params,
                headers: ["Referer": "https://www.bilibili.com/video/av\(aid)/"]
            ),
            type: FavoriteResult.self
        )
    }

    static func getDefaultFolder() async throws(BiliError) -> Int? {
        guard let mid = AuthManager.shared.dedeUserID else { throw .authRequired }
        let result: DefaultFolderResult = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/created/list-all",
                params: ["up_mid": mid, "type": "2"],

            ),
            type: DefaultFolderResult.self
        )
        return result.firstId
    }

    // MARK: - History Report

    static func reportHeartbeat(
        aid: Int, cid: Int, progress: Int, realtime: Int, startTs: Int,
        epid: Int? = nil, sid: Int? = nil, seasonType: Int? = nil
    ) async {
        guard let csrf = AuthManager.shared.biliJct else {
            PlayerLog.log("[VideoAPI] ⚠️ heartbeat skipped: no csrf (bili_jct) — progress will NOT sync to cloud")
            return
        }
        var params = [
            "aid": String(aid), "cid": String(cid),
            "played_time": String(progress),
            "realtime": String(realtime),
            "start_ts": String(startTs),
            "dt": "2",
            "play_type": "0",
            "type": epid != nil ? "4" : "3",
            "csrf": csrf,
        ]
        if let mid = AuthManager.shared.dedeUserID { params["mid"] = mid }
        if let epid { params["epid"] = String(epid) }
        if let sid { params["sid"] = String(sid) }
        if epid != nil { params["sub_type"] = String(seasonType ?? 1) }
        do {
            _ = try await BiliAPIClient.shared.request(
                BiliEndpoint(
                    path: "/x/click-interface/web/heartbeat",
                    method: .post,
                    params: params
                ),
                type: EmptyResult.self
            )
            PlayerLog.log("[VideoAPI] heartbeat accepted: aid=\(aid) cid=\(cid)\(epid.map { " epid=\($0)" } ?? "")\(sid.map { " sid=\($0)" } ?? "") played_time=\(progress)s")
        } catch {
            PlayerLog.log("[VideoAPI] ⚠️ heartbeat FAILED (aid=\(aid) cid=\(cid)\(epid.map { " epid=\($0)" } ?? "") played_time=\(progress)s): \(error)")
        }
    }

    static func reportHistory(aid: Int, cid: Int, progress: Int, epid: Int? = nil) async {
        guard let csrf = AuthManager.shared.biliJct else {
            PlayerLog.log("[VideoAPI] ⚠️ history report skipped: no csrf (bili_jct) — resume positions will NOT be saved")
            return
        }
        var params = [
            "aid": String(aid), "cid": String(cid),
            "progress": String(progress), "csrf": csrf,
        ]
        if let epid {
            params["epid"] = String(epid)
            params["type"] = "4"
        }
        do {
            _ = try await BiliAPIClient.shared.request(
                BiliEndpoint(
                    path: "/x/v2/history/report",
                    method: .post,
                    params: params
                ),
                type: EmptyResult.self
            )
        } catch {
            PlayerLog.log("[VideoAPI] ⚠️ history report failed (aid=\(aid) cid=\(cid)\(epid.map { " epid=\($0)" } ?? "") progress=\(progress)s): \(error)")
        }
    }
}
