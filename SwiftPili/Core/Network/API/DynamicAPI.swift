import Foundation

enum DynamicAPI {
    typealias AttachmentPicture =
        DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicDesc.RichTextNode.Picture

    static func getFeed(
        type: String? = "all",
        hostMID: Int? = nil,
        offset: String = "",
        page: Int = 1
    ) async throws(BiliError) -> DynamicFeedResult {
        var params: [String: String] = [
            "page": String(page),
            "features": "itemOpusStyle",
        ]
        if let hostMID {
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

    static func getFollowingPeoplePortal() async throws(BiliError) -> DynamicPortalResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/portal",
                params: ["up_list_more": "1", "web_location": "333.1365"]
            ),
            type: DynamicPortalResult.self
        )
    }

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
