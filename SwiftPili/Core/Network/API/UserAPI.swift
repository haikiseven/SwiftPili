import Foundation

enum UserAPI {
    /// Profile identity for any mid.
    ///
    /// `x/space/wbi/acc/info` is the rich source, but it sits behind the
    /// main-site risk control: an anonymous session is answered with
    /// `-352 风控校验失败` (+ `v_voucher`) — measured 2026-11-11 with no
    /// cookies, with a server-issued buvid3/buvid4, and with a made-up one,
    /// so the buvid state is not the lever. `x/web-interface/card` carries
    /// the same identity fields and is served to anonymous clients, so a
    /// risk-control rejection (and only that) falls back to it. Any other
    /// failure — transport, decoding, a missing user — surfaces unchanged:
    /// the card endpoint would not answer those differently.
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

    /// `x/web-interface/card` mapped into the shared `UserInfo` shape. It has
    /// no `ip_location` / `top_photo` the way acc/info does; `photo=true`
    /// adds the space banner.
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

    /// ⚠️ `type: "archive"` is LOAD-BEARING beyond the list's contents, and the
    /// two history surfaces depend on it.
    ///
    /// `type` is this endpoint's category filter — `all` (its default) / `archive`
    /// / `live` / `article`. A history entry's `cover` is whatever its own business
    /// composed: an archive `pic`, a live room's artwork (bimodal 4:3 / 16:9, see
    /// `LiveCoverPolicy`), or nothing at all for a column, whose images arrive in a
    /// `covers` ARRAY this model does not decode. So an unfiltered list is
    /// heterogeneous, and `badge` — the only per-row hint in the decoded model — is
    /// display text (稿件视频 / 剧集 / 笔记) that nothing may be keyed off.
    ///
    /// Asking for `archive` is what makes the rows homogeneous, and it is why
    /// `FullHistoryView` and `MineView` can enter the cover policy as
    /// `VideoCoverSources(widescreen:)` — case B, one official widescreen asset —
    /// instead of `singleUnclassified`. Widening this filter to show live or column
    /// history would make that classification a false claim of an authored 16:9
    /// match at both call sites; the fix then is to decode `history.business` and
    /// classify per row, NOT to leave the label and hope.
    static func getHistory(max: Int = 0, viewAt: Int = 0, ps: Int = 20) async throws(BiliError) -> HistoryResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/history/cursor",
                params: ["max": String(max), "view_at": String(viewAt), "ps": String(ps), "type": "archive"]
            ),
            type: HistoryResult.self
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

    /// Fans list (/x/relation/fans — PiliPlus-verified: vmid/pn/ps/order,
    /// same item shape as followings plus `attribute` for follow-back
    /// state). Only the OWN fans list is fully pageable; other users'
    /// lists are truncated by the server.
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

    /// Rename the account (改昵称). BiliBili charges 6 coins per rename;
    /// the server enforces the balance and answers a coded error when
    /// it falls short — surface that message verbatim.
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

    /// Update the profile signature/bio (个性签名). Free, but reviewed
    /// server-side (banned words answer a coded error).
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

    /// The logged-in user's follow groups, including the two built-ins:
    /// tagid -10 = 特别关注 (Special Follow), 0 = 默认分组 (Default).
    static func getRelationTags() async throws(BiliError) -> [RelationTag] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/relation/tags"),
            type: [RelationTag].self
        )
    }

    /// Members of one group. Same item shape as the following list.
    static func getRelationTagMembers(tagid: Int, pn: Int = 1, ps: Int = 20) async throws(BiliError) -> [FollowingResult.FollowingItem] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/tag",
                params: ["tagid": String(tagid), "pn": String(pn), "ps": String(ps)]
            ),
            type: [FollowingResult.FollowingItem].self
        )
    }

    /// tagid → name for the groups ONE followed user currently sits in
    /// (keys are stringified ids, e.g. "-10": "特别关注").
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

    /// Create a follow group; answers the new tagid.
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

    /// REPLACES the group set of the given users: tagids [0] = back to
    /// the default group, include -10 to mark Special Follow.
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

    /// Videos the user recently coined (最近投币). Privacy-gated: the
    /// server answers code 53013 when the profile hides this list.
    static func getUserCoinVideos(mid: Int) async throws(BiliError) -> [SpaceArchive] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/coin/video",
                params: ["vmid": String(mid)]
            ),
            type: [SpaceArchive].self
        )
    }

    /// Videos the user recently liked (最近点赞). Privacy-gated (53013).
    static func getUserLikeVideos(mid: Int) async throws(BiliError) -> SpaceLikeResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/like/video",
                params: ["vmid": String(mid)]
            ),
            type: SpaceLikeResult.self
        )
    }

    /// The user's published articles (专栏投稿), newest first.
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

    /// Add a video to Watch Later (稍后再看). Write op — csrf required.
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

    /// Remove a video from Watch Later.
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

    /// Remove every ALREADY-WATCHED video from Watch Later (`viewed=true`).
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

    /// Empty the entire Watch Later list.
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
                params: ["up_mid": String(mid), "type": "2"],

            ),
            type: FavoriteFolderResult.self
        )
    }

    static func getFavoriteContent(
        mediaId: Int,
        pn: Int = 1,
        ps: Int = 20,
        keyword: String? = nil
    ) async throws(BiliError) -> FavoriteContentResult {
        var params = [
            "media_id": String(mediaId),
            "pn": String(pn),
            "ps": String(ps),
            "platform": "web",
        ]
        if let keyword, !keyword.isEmpty {
            // Server-side search within the folder; type=0 matches the
            // web client's keyword queries.
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

    /// The server rejects deleting the default folder — surface its error
    /// rather than guessing client-side which folder that is.
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

    /// Removes one video from one folder (resource type 2 = video).
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

    /// x/relation/modify acts: 1 follow, 2 unfollow, 5 block, 6 unblock.
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

    /// The user's blocked list (x/relation/blacks), 50 per page.
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
