import Foundation

enum MessageAPI {
    private static let messageHeaders: [String: String] = [
        "Referer": "https://message.bilibili.com/",
        "Origin": "https://message.bilibili.com",
    ]

    static func getUnreadCount() async throws(BiliError) -> MessageUnreadCount {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/msgfeed/unread", headers: messageHeaders),
            type: MessageUnreadCount.self
        )
    }

    static func getReplyMessages(
        id: Int = 0,
        replyTime: Int = 0
    ) async throws(BiliError) -> ReplyMessageResult {
        var params: [String: String] = ["platform": "web"]
        if id > 0 { params["id"] = String(id) }
        if replyTime > 0 { params["reply_time"] = String(replyTime) }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/msgfeed/reply", params: params, headers: messageHeaders),
            type: ReplyMessageResult.self
        )
    }

    static func getAtMessages(
        id: Int = 0,
        atTime: Int = 0
    ) async throws(BiliError) -> AtMessageResult {
        var params: [String: String] = ["build": "0", "mobi_app": "web"]
        if id > 0 { params["id"] = String(id) }
        if atTime > 0 { params["at_time"] = String(atTime) }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/msgfeed/at", params: params, headers: messageHeaders),
            type: AtMessageResult.self
        )
    }

    static func getLikeMessages(
        id: Int = 0,
        likeTime: Int = 0
    ) async throws(BiliError) -> LikeMessageResult {
        var params: [String: String] = ["platform": "web"]
        if id > 0 { params["id"] = String(id) }
        if likeTime > 0 { params["like_time"] = String(likeTime) }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/msgfeed/like", params: params, headers: messageHeaders),
            type: LikeMessageResult.self
        )
    }

    static func getSystemNotifications(
        cursor: Int = 0,
        pageSize: Int = 20
    ) async throws(BiliError) -> SystemNotifyResult {
        let clampedPageSize = min(max(pageSize, 1), 20)
        var params: [String: String] = [
            "page_size": String(clampedPageSize),
            "build": "0",
            "mobi_app": "web",
        ]
        if let csrf = AuthManager.shared.biliJct, !csrf.isEmpty {
            params["csrf"] = csrf
        }
        if cursor > 0 {
            params["cursor"] = String(cursor)
        }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/sys-msg/query_user_notify",
                params: params,
                signType: .none,
                baseURL: "https://message.bilibili.com",
                headers: messageHeaders
            ),
            type: SystemNotifyResult.self
        )
    }

    static func getSessionList(
        endTs: Int = 0
    ) async throws(BiliError) -> SessionListResult {
        var params: [String: String] = [
            "session_type": "1",
            "group_fold": "1",
            "unfollow_fold": "0",
            "sort_rule": "2",
            "build": "0",
            "mobi_app": "web",
        ]
        if endTs > 0 { params["end_ts"] = String(endTs) }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/session_svr/v1/session_svr/get_sessions",
                params: params,
                baseURL: "https://api.vc.bilibili.com",
                headers: messageHeaders
            ),
            type: SessionListResult.self
        )
    }

    static func getSessionUserInfos(uids: [Int]) async throws(BiliError) -> [IMUserInfo] {
        guard !uids.isEmpty else { return [] }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/account/v1/user/infos",
                params: [
                    "uids": uids.map(String.init).joined(separator: ","),
                    "build": "0",
                    "mobi_app": "web",
                ],
                baseURL: "https://api.vc.bilibili.com",
                headers: messageHeaders
            ),
            type: [IMUserInfo].self
        )
    }

    // MARK: - Private Chat

    static func getSessionMessages(
        talkerId: Int,
        size: Int = 30,
        endSeqno: Int? = nil
    ) async throws(BiliError) -> SessionMsgsResult {
        var params: [String: String] = [
            "talker_id": String(talkerId),
            "session_type": "1",
            "size": String(size),
            "sender_device_id": "1",
            "build": "0",
            "mobi_app": "web",
        ]
        if let endSeqno { params["end_seqno"] = String(endSeqno) }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/svr_sync/v1/svr_sync/fetch_session_msgs",
                params: params,
                baseURL: "https://api.vc.bilibili.com",
                headers: messageHeaders
            ),
            type: SessionMsgsResult.self
        )
    }

    static func markSessionRead(talkerId: Int, ackSeqno: Int) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/session_svr/v1/session_svr/update_ack",
                params: [
                    "talker_id": String(talkerId),
                    "session_type": "1",
                    "ack_seqno": String(ackSeqno),
                    "build": "0",
                    "mobi_app": "web",
                    "csrf_token": csrf,
                    "csrf": csrf,
                ],
                baseURL: "https://api.vc.bilibili.com",
                headers: messageHeaders
            ),
            type: EmptyResult.self
        )
    }

    private static let deviceId = UUID().uuidString

    static func sendMessage(
        receiverId: Int,
        content: String
    ) async throws(BiliError) -> SendMsgResult {
        guard let csrf = AuthManager.shared.biliJct,
              let uid = AuthManager.shared.dedeUserID else { throw .authRequired }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["content": content]),
              let payloadString = String(data: payload, encoding: .utf8) else {
            throw .apiError(code: -1, message: "content encoding failed")
        }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/web_im/v1/web_im/send_msg",
                method: .post,
                params: [
                    "msg[sender_uid]": uid,
                    "msg[receiver_id]": String(receiverId),
                    "msg[receiver_type]": "1",
                    "msg[msg_type]": "1",
                    "msg[msg_status]": "0",
                    "msg[dev_id]": deviceId,
                    "msg[timestamp]": String(Int(Date().timeIntervalSince1970)),
                    "msg[new_face_version]": "1",
                    "msg[content]": payloadString,
                    "build": "0",
                    "mobi_app": "web",
                    "csrf_token": csrf,
                    "csrf": csrf,
                ],
                baseURL: "https://api.vc.bilibili.com",
                headers: messageHeaders
            ),
            type: SendMsgResult.self
        )
    }

    // MARK: - User Space

    static func getRelationStat(mid: Int) async throws(BiliError) -> RelationStatResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/stat",
                params: ["vmid": String(mid)]
            ),
            type: RelationStatResult.self
        )
    }

    static func getUpStat(mid: Int) async throws(BiliError) -> UpStatResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/upstat",
                params: ["mid": String(mid)]
            ),
            type: UpStatResult.self
        )
    }

    static func getUserVideos(
        mid: Int,
        pn: Int = 1,
        ps: Int = 30,
        order: String = "pubdate"
    ) async throws(BiliError) -> UserVideoResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/wbi/arc/search",
                params: [
                    "mid": String(mid),
                    "pn": String(pn),
                    "ps": String(ps),
                    "order": order,
                ]
            ),
            type: UserVideoResult.self
        )
    }

    static func getUserDynamics(
        mid: Int,
        offset: String = ""
    ) async throws(BiliError) -> DynamicFeedResult {
        var params: [String: String] = [
            "host_mid": String(mid),
            "features": "itemOpusStyle",
        ]
        if !offset.isEmpty { params["offset"] = offset }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/polymer/web-dynamic/v1/feed/space",
                params: params,
                signType: .wbi
            ),
            type: DynamicFeedResult.self
        )
    }
}
