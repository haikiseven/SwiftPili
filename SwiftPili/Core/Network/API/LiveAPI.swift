import Foundation

enum LiveAPI {
    static let defaultLiveQuality = 400

    static func getRoomInfo(roomID: Int) async throws(BiliError) -> LiveRoomInfo {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/room/v1/Room/get_info",
                params: ["room_id": String(roomID)],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: LiveRoomInfo.self
        )
    }

    static func getPlayInfo(
        roomID: Int,
        quality: Int = LiveAPI.defaultLiveQuality
    ) async throws(BiliError) -> LivePlayInfo {
        try await BiliAPIClient.shared.request(
            playInfoEndpoint(roomID: roomID, quality: quality),
            type: LivePlayInfo.self
        )
    }

    private static func playInfoEndpoint(
        roomID: Int,
        quality: Int = LiveAPI.defaultLiveQuality
    ) -> BiliEndpoint {
        BiliEndpoint(
            path: "/xlive/web-room/v2/index/getRoomPlayInfo",
            params: [
                "room_id": String(roomID),
                "protocol": "0,1",
                "format": "0,1,2",
                "codec": "0,1,2",
                "qn": String(quality),
                "platform": "web",
                "ptype": "8",
                "dolby": "5",
                "panorama": "1",
            ],
            baseURL: "https://api.live.bilibili.com"
        )
    }

    static func sendDanmaku(
        roomID: Int,
        message: String,
        color: Int = 16777215,
        mode: Int = 1,
        fontSize: Int = 25
    ) async throws(BiliError) -> SendLiveDanmakuResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/msg/send",
                method: .post,
                params: [
                    "roomid": String(roomID),
                    "msg": message,
                    "color": String(color),
                    "mode": String(mode),
                    "fontsize": String(fontSize),
                    "bubble": "0",
                    "room_type": "0",
                    "rnd": String(Int(Date().timeIntervalSince1970)),
                    "csrf": csrf,
                    "csrf_token": csrf,
                ],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: SendLiveDanmakuResult.self
        )
    }

    static func getAnchorInfo(uid: Int) async throws(BiliError) -> LiveAnchorInfo {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/live_user/v1/Master/info",
                params: ["uid": String(uid)],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: LiveAnchorInfo.self
        )
    }

    static func getDanmuInfo(roomID: Int) async throws(BiliError) -> DanmuInfo {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/xlive/web-room/v1/index/getDanmuInfo",
                params: ["id": String(roomID), "type": "0"],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: DanmuInfo.self
        )
    }

    private static let appHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com)",
        "Referer": "https://live.bilibili.com/",
        "app-key": "android",
        "env": "prod",
        "x-bili-aurora-eid": "",
        "x-bili-aurora-zone": "",
    ]

    static func getLiveList(
        page: Int = 1
    ) async throws(BiliError) -> LiveListResult {
        var params: [String: String] = [
            "page": String(page),
            "device": "android",
            "device_name": "android",
            "device_type": "0",
            "platform": "android",
            "scale": "2",
            "build": "8430300",
            "mobi_app": "android",
            "network": "wifi",
            "c_locale": "zh_CN",
            "s_locale": "zh_CN",
            "disable_rcmd": "0",
            "fnval": "912",
            "https_url_req": "1",
            "channel": "master",
            "actionKey": "appkey",
        ]
        if let buvid = BuvidManager.getBuvid() {
            params["buvid"] = buvid
        }

        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/xlive/app-interface/v2/index/feed",
                params: params,
                signType: .app,
                baseURL: "https://api.live.bilibili.com",
                headers: appHeaders
            ),
            type: LiveListResult.self
        )
    }

    static func getAreaList() async throws(BiliError) -> [LiveParentArea] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/room/v1/Area/getList",
                params: ["need_entrance": "1", "parent_id": "0"],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: [LiveParentArea].self
        )
    }

    static let areaRoomsPageSize = 30

    static func getAreaRooms(
        parentAreaID: Int,
        areaID: Int = 0,
        page: Int = 1
    ) async throws(BiliError) -> [LiveListResult.LiveCard] {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/room/v1/area/getRoomList",
                params: [
                    "platform": "web",
                    "parent_area_id": String(parentAreaID),
                    "cate_id": "0",
                    "area_id": String(areaID),
                    "sort_type": "online",
                    "page": String(page),
                    "page_size": String(areaRoomsPageSize),
                ],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: [LiveListResult.LiveCard].self
        )
    }

    static func getFollowingLive(
        page: Int = 1,
        pageSize: Int = 29
    ) async throws(BiliError) -> LiveFollowingResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/xlive/web-ucenter/user/following",
                params: [
                    "page": String(page),
                    "page_size": String(pageSize),
                    "ignoreRecord": "1",
                    "hit_ab": "true",
                ],
                baseURL: "https://api.live.bilibili.com"
            ),
            type: LiveFollowingResult.self
        )
    }
}
