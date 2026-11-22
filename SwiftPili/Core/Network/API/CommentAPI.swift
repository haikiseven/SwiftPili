import Foundation

enum CommentAPI {
    static func getComments(
        oid: Int,
        type: Int = 1,
        sort: Int = 0,
        pn: Int = 1,
        ps: Int = 20
    ) async throws(BiliError) -> CommentResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/reply",
                params: [
                    "oid": String(oid),
                    "type": String(type),
                    "sort": String(sort),
                    "pn": String(pn),
                    "ps": String(ps),
                ],

            ),
            type: CommentResult.self
        )
    }

    static func getReplies(
        oid: Int,
        rootID: Int,
        type: Int = 1,
        pn: Int = 1,
        ps: Int = 20
    ) async throws(BiliError) -> CommentResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/reply/reply",
                params: [
                    "oid": String(oid),
                    "type": String(type),
                    "root": String(rootID),
                    "pn": String(pn),
                    "ps": String(ps),
                ],

            ),
            type: CommentResult.self
        )
    }

    static func postComment(
        oid: Int,
        message: String,
        type: Int = 1,
        root: Int? = nil,
        parent: Int? = nil,
        pictures: [ComposedPicture] = []
    ) async throws(BiliError) -> PostCommentResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        var params: [String: String] = [
            "oid": String(oid),
            "type": String(type),
            "message": message,
            "csrf": csrf,
        ]
        if let root { params["root"] = String(root) }
        if let parent { params["parent"] = String(parent) }
        if !pictures.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: pictures.map(\.asJSONObject)),
           let json = String(data: data, encoding: .utf8)
        {
            params["pictures"] = json
        }

        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/v2/reply/add", method: .post, params: params),
            type: PostCommentResult.self
        )
    }

    /// Like / unlike a comment (/x/v2/reply/action).
    static func likeComment(
        oid: Int,
        type: Int,
        rpid: Int,
        like: Bool
    ) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/reply/action",
                method: .post,
                params: [
                    "oid": String(oid), "type": String(type),
                    "rpid": String(rpid), "action": like ? "1" : "0",
                    "csrf": csrf,
                ]
            ),
            type: EmptyResult.self
        )
    }

    /// Report reason codes from the web client's report dialog.
    static let reportReasons: [(code: Int, label: String)] = [
        (1, String(localized: "Spam")),
        (2, String(localized: "Pornography")),
        (3, String(localized: "Flooding")),
        (4, String(localized: "Provocation")),
        (5, String(localized: "Spoiler")),
        (7, String(localized: "Personal attack")),
        (8, String(localized: "Irrelevant")),
        (0, String(localized: "Other")),
    ]

    /// Delete the user's OWN comment (/x/v2/reply/del — verified against
    /// PiliPlus: form POST with oid/type/rpid/csrf). The server rejects
    /// deleting someone else's comment; the UI only offers it on own rows.
    static func deleteComment(
        oid: Int,
        type: Int,
        rpid: Int
    ) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/v2/reply/del", method: .post, params: [
                "oid": String(oid), "type": String(type),
                "rpid": String(rpid), "csrf": csrf,
            ]),
            type: EmptyResult.self
        )
    }

    /// Report a comment (/x/v2/reply/report).
    static func reportComment(
        oid: Int,
        type: Int,
        rpid: Int,
        reason: Int,
        content: String = ""
    ) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        var params: [String: String] = [
            "oid": String(oid), "type": String(type),
            "rpid": String(rpid), "reason": String(reason),
            "csrf": csrf,
            // Mirrors PiliPlus's proven field set — the bare params can be
            // rejected by risk control. content is REQUIRED for reason 0
            // ("Other"); the UI collects it before calling.
            "gaia_source": "main_h5",
            "scene": "main",
            "platform": "android",
            "add_blacklist": "0",
        ]
        if !content.isEmpty { params["content"] = content }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/v2/reply/report", method: .post, params: params),
            type: EmptyResult.self
        )
    }

    /// The user's sticker/emote packages for the comment composer.
    static func getEmotePanel() async throws(BiliError) -> EmotePanelResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/emote/user/panel/web", params: ["business": "reply"]),
            type: EmotePanelResult.self
        )
    }

    enum CommentVisibility {
        case visible
        case hidden
        case unknown
    }

    /// Checks whether a comment is visible to OTHER users. A shadow-banned
    /// comment is always visible to its own author, so the requests go out
    /// anonymously — an ephemeral session with no cookies attached,
    /// bypassing BiliAPIClient's shared cookie jar.
    static func checkCommentVisibleAnonymously(
        oid: Int,
        rpid: Int,
        root: Int? = nil,
        access: ExperimentalAccessReceipt,
        operation: ExperimentalAccessPermit? = nil
    ) async -> CommentVisibility {
        let permission = VerificationPermission(access: access, operation: operation)
        guard permission.isValid else { return .unknown }
        let ps = 49
        if let root {
            // Sub-replies sort time-ASCENDING: a fresh reply in a thread
            // longer than one page sits on the LAST page — checking only
            // page 1 misread every such reply as shadow-banned.
            guard let first = await fetchListAnonymously(
                oid: oid, root: root, pn: 1, ps: ps, permission: permission
            ) else {
                return .unknown
            }
            if contains(first, rpid: rpid) { return .visible }
            let total = first.page?.count ?? 0
            if total > ps {
                let lastPage = (total + ps - 1) / ps
                guard let last = await fetchListAnonymously(
                    oid: oid, root: root, pn: lastPage, ps: ps, permission: permission
                ) else {
                    return .unknown
                }
                if contains(last, rpid: rpid) { return .visible }
            }
            return .hidden
        }
        // Main list via wbi/main mode=2 (time, newest first): the first
        // cursor window holds a fresh top-level comment.
        guard let main = await fetchListAnonymously(
            oid: oid, root: nil, pn: 1, ps: ps, permission: permission
        ) else {
            return .unknown
        }
        return contains(main, rpid: rpid) ? .visible : .hidden
    }

    private struct VerificationPermission: Sendable {
        let access: ExperimentalAccessReceipt
        let operation: ExperimentalAccessPermit?
        var isValid: Bool {
            !Task.isCancelled && access.feature == .commentTools && access.isValid
                && operation?.isValid != false && ExperimentalSettingsPolicy.isAllowed(.commentTools)
        }
    }

    private static func contains(_ result: CommentResult, rpid: Int) -> Bool {
        let items = result.replies ?? []
        return items.contains { $0.rpid == rpid }
            || items.contains { ($0.replies ?? []).contains { $0.rpid == rpid } }
    }

    private static func fetchListAnonymously(
        oid: Int,
        root: Int?,
        pn: Int,
        ps: Int,
        permission: VerificationPermission
    ) async -> CommentResult? {
        guard permission.isValid else { return nil }
        var comps: URLComponents
        if let root {
            // Sub-thread endpoint; takes no sort param (always time-asc).
            comps = URLComponents(string: "https://api.bilibili.com/x/v2/reply/reply")!
            comps.queryItems = [
                URLQueryItem(name: "oid", value: String(oid)),
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "pn", value: String(pn)),
                URLQueryItem(name: "ps", value: String(ps)),
                URLQueryItem(name: "root", value: String(root)),
            ]
        } else {
            // Anonymous time-sorted main lists are DEAD on the classic
            // endpoint — /x/v2/reply?sort=0 returns an EMPTY array on
            // every video without login (verified live), which read as a
            // shadow ban for every fresh top-level comment. The wbi/main
            // endpoint serves anonymous time-sorted pages (mode=2) when
            // WBI-signed; only the request itself must stay cookie-less.
            guard let signed = try? await WBISigner.shared.sign(params: [
                "oid": String(oid), "type": "1", "mode": "2",
            ]) else { return nil }
            guard permission.isValid else { return nil }
            comps = URLComponents(string: "https://api.bilibili.com/x/v2/reply/wbi/main")!
            comps.queryItems = signed
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard permission.isValid, let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(BiliAPIClient.defaultReferer, forHTTPHeaderField: "Referer")
        request.setValue(BiliAPIClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            guard permission.isValid else { return nil }
            let (data, response) = try await session.data(for: request)
            guard permission.isValid, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            struct Wrapper: Decodable {
                let code: Int
                let data: CommentResult?
            }
            let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
            return wrapper.code == 0 ? wrapper.data : nil
        } catch {
            guard permission.isValid else { return nil }
            PlayerLog.log("[CommentAPI] anonymous visibility fetch failed: \(error)")
            return nil
        }
    }
}
