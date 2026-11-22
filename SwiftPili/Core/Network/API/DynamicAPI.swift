import Foundation

enum DynamicAPI {
    typealias AttachmentPicture =
        DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicDesc.RichTextNode.Picture

    /// type: "all" (全部), "pgc" (追番), "article" (专栏), "video" (投稿).
    static func getFeed(
        type: String? = "all",
        hostMID: Int? = nil,
        offset: String = "",
        page: Int = 1
    ) async throws(BiliError) -> DynamicFeedResult {
        var params: [String: String] = [
            "page": String(page),
            // Without itemOpusStyle the server sends titled text/article
            // posts in the legacy MAJOR_TYPE_ARTICLE shape; with it they
            // arrive as major.opus (title + summary + pics).
            "features": "itemOpusStyle",
        ]
        if let hostMID {
            // Author mode is the same followed feed, server-filtered. The
            // observed request omits type when host_mid is present.
            params["host_mid"] = String(hostMID)
        } else {
            params["type"] = type ?? "all"
        }
        if !offset.isEmpty {
            params["offset"] = offset
        }

        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/feed/all",
                params: params,
                signType: .wbi
            ),
            type: DynamicFeedResult.self
        )
    }

    /// Recent/updating people rail. The returned `up_list` has its own opaque
    /// cursor; further pages come from `getFollowingPeopleUpdates(offset:)`.
    static func getFollowingPeoplePortal() async throws(BiliError) -> DynamicPortalResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/portal",
                params: ["up_list_more": "1", "web_location": "333.1365"]
            ),
            type: DynamicPortalResult.self
        )
    }

    /// Continues the modern portal update-person catalog. This cursor is not
    /// interchangeable with the relationship-list page number.
    static func getFollowingPeopleUpdates(
        offset: String
    ) async throws(BiliError) -> DynamicFollowingUpdatePage {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/uplist",
                params: [
                    "offset": offset,
                    "platform": "web",
                    "web_location": "333.1365",
                ]
            ),
            type: DynamicFollowingUpdatePage.self
        )
    }

    /// Full detail for a single dynamic (same item shape as the feed).
    static func getDetail(dynamicId: String) async throws(BiliError) -> DynamicDetailResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/detail",
                params: ["id": dynamicId, "features": "itemOpusStyle"],
                signType: .wbi
            ),
            type: DynamicDetailResult.self
        )
    }

    /// Resolves a VIEW_PICTURE attachment whose feed node supplied only a rid.
    /// The endpoint's data is the picture array, not a dynamic detail item.
    static func getPictures(
        attachmentID: String
    ) async throws(BiliError) -> [AttachmentPicture] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/detail/pic",
                params: ["id": attachmentID, "web_location": "333.1368"]
            ),
            type: [AttachmentPicture].self
        )
    }

    static func getForwardList(dynamicId: String, offset: String = "") async throws(BiliError) -> DynamicForwardResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/detail/forward",
                params: ["id": dynamicId, "offset": offset],
                signType: .wbi
            ),
            type: DynamicForwardResult.self
        )
    }

    /// Users who liked or otherwise reacted to one dynamic. The endpoint
    /// returns mixed participant actions, not a likes-only list.
    static func getReactionList(dynamicId: String, offset: String = "") async throws(BiliError) -> DynamicReactionResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/detail/reaction",
                params: ["id": dynamicId, "offset": offset, "web_location": "333.1369"],
                signType: .wbi
            ),
            type: DynamicReactionResult.self
        )
    }

    /// Like / unlike a dynamic. up: 1 = like, 2 = cancel.
    static func likeDynamic(dynamicId: String, up: Int) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/dynamic_like/v1/dynamic_like/thumb",
                method: .post,
                params: [
                    "dynamic_id": dynamicId,
                    "up": String(up),
                    "csrf_token": csrf,
                    "csrf": csrf,
                ],
                baseURL: "https://api.vc.bilibili.com"
            ),
            type: EmptyResult.self
        )
    }

    /// Repost a dynamic to the user's own feed with an optional comment.
    static func repostDynamic(dynamicId: String, content: String) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/dynamic_repost/v1/dynamic_repost/repost",
                method: .post,
                params: [
                    "dynamic_id": dynamicId,
                    "content": content.isEmpty ? "转发动态" : content,
                    "csrf_token": csrf,
                    "csrf": csrf,
                ],
                baseURL: "https://api.vc.bilibili.com"
            ),
            type: EmptyResult.self
        )
    }

    static func createMoment(text: String) async throws(BiliError) -> CreateDynamicResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/dynamic/feed/create/dyn",
                method: .post,
                params: [
                    "dyn_req": "{\"content\":{\"contents\":[{\"raw_text\":\"\(text.jsonEscaped)\",\"type\":1,\"biz_id\":\"\"}]},\"scene\":1}",
                    "csrf": csrf,
                ],
            ),
            type: CreateDynamicResult.self
        )
    }
}
