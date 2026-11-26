import Foundation

enum UserAPI {
    static func getUserInfo(mid: Int) async throws(BiliError) -> UserInfo {
        do {
            return try await BiliAPIClient.shared.request(
                BiliEndpoint(path: "/x/space/wbi/acc/info", params: ["mid": String(mid)]),
                type: UserInfo.self
            )
        } catch where error.isRiskControlRejection {
            PlayerLog.log(
                "[UserAPI] acc/info risk-controlled (\(error)) — falling back to card for mid \(mid)"
            )
            return try await getUserCard(mid: mid)
        }
    }

    private static func getUserCard(mid: Int) async throws(BiliError) -> UserInfo {
        let result = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/card",
                params: ["mid": String(mid), "photo": "true"],
                signType: .none
            ),
            type: UserCardResult.self
        )
        return UserInfo(card: result)
    }

    static func getHistory(max: Int = 0, viewAt: Int = 0, ps: Int = 20) async throws(BiliError) -> HistoryResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/history/cursor",
                params: ["max": String(max), "view_at": String(viewAt), "ps": String(ps), "type": "archive"]
            ),
            type: HistoryResult.self
        )
    }

    static func deleteHistoryItem(kid: Int, business: String = "archive") async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/history/delete",
                method: .post,
                params: ["kid": "\(business)_\(kid)", "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func clearHistory() async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/history/clear",
                method: .post,
                params: ["csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func getMyInfo() async throws(BiliError) -> UserInfo {
        try await BiliAPIClient.shared.request(BiliEndpoint(path: "/x/space/myinfo"), type: UserInfo.self)
    }

    static func getFollowing(mid: Int, pn: Int = 1, ps: Int = 20) async throws(BiliError) -> FollowingResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/followings",
                params: ["vmid": String(mid), "pn": String(pn), "ps": String(ps)]
            ),
            type: FollowingResult.self
        )
    }

    static func getFollowers(mid: Int, pn: Int = 1, ps: Int = 20) async throws(BiliError) -> FollowingResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/fans",
                params: ["vmid": String(mid), "pn": String(pn), "ps": String(ps), "order": "desc"]
            ),
            type: FollowingResult.self
        )
    }

    static func getWatchLater(ps: Int = 20) async throws(BiliError) -> WatchLaterResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/v2/history/toview/web", params: ["ps": String(ps)]),
            type: WatchLaterResult.self
        )
    }

    // MARK: - Profile editing

    static func updateUsername(_ name: String) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/member/web/update",
                method: .post,
                params: ["uname": name, "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func updateSignature(_ sign: String) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/member/web/sign/update",
                method: .post,
                params: ["user_sign": sign, "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    // MARK: - Following groups (relation tags, 关注分组)

    static func getRelationTags() async throws(BiliError) -> [RelationTag] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/relation/tags"),
            type: [RelationTag].self
        )
    }

    static func getRelationTagMembers(tagid: Int, pn: Int = 1, ps: Int = 20) async throws(BiliError) -> [FollowingResult.FollowingItem] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/tag",
                params: ["tagid": String(tagid), "pn": String(pn), "ps": String(ps)]
            ),
            type: [FollowingResult.FollowingItem].self
        )
    }

    static func getUserRelationTags(fid: Int) async throws(BiliError) -> [String: String] {
        struct Status: Decodable { let code: Int }
        let endpoint = BiliEndpoint(path: "/x/relation/tag/user", params: ["fid": String(fid)])
        let raw = try await BiliAPIClient.shared.requestRaw(endpoint)
        do {
            let code = try JSONDecoder().decode(Status.self, from: raw).code
            let response = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
            guard code == 0 else {
                let message = (response?["message"] as? String) ?? (response?["msg"] as? String) ?? ""
                throw BiliError.apiError(code: code, message: message)
            }
            guard let members = response?["data"] as? [String: String],
                  members.keys.allSatisfy({ Int($0) != nil }) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "Missing or invalid following group membership"
                ))
            }
            return members
        } catch let error as BiliError {
            throw error
        } catch { throw .decodingFailed(error) }
    }

    static func createRelationTag(name: String) async throws(BiliError) -> RelationTagCreated {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/tag/create",
                method: .post,
                params: ["tag": name, "csrf": csrf]
            ),
            type: RelationTagCreated.self
        )
    }

    static func setRelationTags(mids: [Int], tagids: [Int]) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/tags/addUsers",
                method: .post,
                params: [
                    "fids": mids.map(String.init).joined(separator: ","),
                    "tagids": (tagids.isEmpty ? [0] : tagids).map(String.init).joined(separator: ","),
                    "csrf": csrf,
                ]
            ),
            type: EmptyResult.self
        )
    }

    static func getUserCoinVideos(mid: Int) async throws(BiliError) -> [SpaceArchive] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/coin/video",
                params: ["vmid": String(mid)]
            ),
            type: [SpaceArchive].self
        )
    }

    static func getUserLikeVideos(mid: Int) async throws(BiliError) -> SpaceLikeResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/like/video",
                params: ["vmid": String(mid)]
            ),
            type: SpaceLikeResult.self
        )
    }

    static func getUserArticles(mid: Int, pn: Int = 1, ps: Int = 20) async throws(BiliError) -> UserArticlesResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/wbi/article",
                params: [
                    "mid": String(mid),
                    "pn": String(pn),
                    "ps": String(ps),
                    "sort": "publish_time",
                ]
            ),
            type: UserArticlesResult.self
        )
    }

    static func addToWatchLater(aid: Int) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/history/toview/add",
                method: .post,
                params: ["aid": String(aid), "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func removeFromWatchLater(aid: Int) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/history/toview/del",
                method: .post,
                params: ["aid": String(aid), "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func removeWatchedFromWatchLater() async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/history/toview/del",
                method: .post,
                params: ["viewed": "true", "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func clearWatchLater() async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/history/toview/clear",
                method: .post,
                params: ["csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func getFavorites(
        mid: Int
    ) async throws(BiliError) -> FavoriteFolderResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/created/list-all",
                params: ["up_mid": String(mid), "type": "2"]
            ),
            type: FavoriteFolderResult.self
        )
    }

    static func getCollectedFavoriteFolders(
        upMid: Int,
        pn: Int = 1,
        ps: Int = 20
    ) async throws(BiliError) -> FavoriteFolderResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/collected/list",
                params: [
                    "up_mid": String(upMid),
                    "pn": String(pn),
                    "ps": String(ps),
                    "platform": "web",
                ]
            ),
            type: FavoriteFolderResult.self
        )
    }

    static func getFavoriteContent(
        mediaId: Int,
        pn: Int = 1,
        ps: Int = 20,
        keyword: String? = nil,
        order: String = "mtime"
    ) async throws(BiliError) -> FavoriteContentResult {
        var params = [
            "media_id": String(mediaId),
            "pn": String(pn),
            "ps": String(ps),
            "order": order,
            "platform": "web",
        ]
        if let keyword, !keyword.isEmpty {
            params["keyword"] = keyword
            params["type"] = "0"
        }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/v3/fav/resource/list", params: params),
            type: FavoriteContentResult.self
        )
    }

    static func createFavoriteFolder(title: String, isPrivate: Bool) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/add",
                method: .post,
                params: [
                    "title": title,
                    "privacy": isPrivate ? "1" : "0",
                    "csrf": csrf,
                ]
            ),
            type: EmptyResult.self
        )
    }

    static func deleteFavoriteFolder(mediaId: Int) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/del",
                method: .post,
                params: ["media_ids": String(mediaId), "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    static func sortFavoriteFolders(orderedIds: [Int]) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/folder/sort",
                method: .post,
                params: [
                    "sort": orderedIds.map(String.init).joined(separator: ","),
                    "csrf": csrf,
                ]
            ),
            type: EmptyResult.self
        )
    }

    static func removeFavoriteResource(aid: Int, mediaId: Int) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v3/fav/resource/batch-del",
                method: .post,
                params: [
                    "resources": "\(aid):2",
                    "media_id": String(mediaId),
                    "csrf": csrf,
                ]
            ),
            type: EmptyResult.self
        )
    }

    enum FavoriteTransfer: String, Sendable {
        case copy, move
    }

    static func transferFavoriteResource(
        aid: Int,
        sourceMediaId: Int,
        targetMediaId: Int,
        sourceOwnerMid: Int,
        operation: FavoriteTransfer
    ) async throws(BiliError) {
        guard let account = AuthManager.shared.dedeUserID.flatMap(Int.init), account > 0,
              let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        guard aid > 0, sourceMediaId > 0, targetMediaId > 0, sourceOwnerMid > 0,
              sourceMediaId != targetMediaId else {
            throw .apiError(code: -1, message: String(localized: "Operation Failed"))
        }
        var params = [
            "resources": "\(aid):2",
            "src_media_id": String(sourceMediaId),
            "tar_media_id": String(targetMediaId),
            "platform": "web",
            "csrf": csrf,
        ]
        if operation == .copy { params["mid"] = String(sourceOwnerMid) }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/v3/fav/resource/\(operation.rawValue)", method: .post, params: params),
            type: EmptyResult.self
        )
    }

    static func getStat() async throws(BiliError) -> UserStatResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/web-interface/nav/stat"),
            type: UserStatResult.self
        )
    }

    private static func modifyRelation(mid: Int, act: Int) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/modify",
                method: .post,
                params: [
                    "fid": String(mid),
                    "act": String(act),
                    "csrf": csrf,
                ],

            ),
            type: EmptyResult.self
        )
    }

    static func follow(mid: Int) async throws(BiliError) {
        try await modifyRelation(mid: mid, act: 1)
    }

    static func unfollow(mid: Int) async throws(BiliError) {
        try await modifyRelation(mid: mid, act: 2)
    }

    static let blockedUsersPageSize = 50

    static func getBlacklist(
        pn: Int = 1, ps: Int = UserAPI.blockedUsersPageSize
    ) async throws(BiliError) -> BlacklistResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/blacks",
                params: ["pn": String(pn), "ps": String(ps)]
            ),
            type: BlacklistResult.self
        )
    }

    static func getRelation(mid: Int) async throws(BiliError) -> RelationResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation",
                params: ["fid": String(mid)],

            ),
            type: RelationResult.self
        )
    }
}
