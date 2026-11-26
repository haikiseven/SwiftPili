import Foundation

enum DanmakuAPI {
    static func metadata(oid: Int) async throws(BiliError) -> DanmakuSegmentResponse {
        let (body, response) = try await BiliAPIClient.shared.requestRawResponse(
            BiliEndpoint(path: "/x/v2/dm/web/view", params: ["type": "1", "oid": String(oid)])
        )
        return DanmakuSegmentResponse(
            status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"), body: body
        )
    }

    static func segment(oid: Int, segmentIndex: Int) async throws(BiliError) -> DanmakuSegmentResponse {
        let (body, response) = try await BiliAPIClient.shared.requestRawResponse(
            BiliEndpoint(
                path: "/x/v2/dm/web/seg.so",
                params: [
                    "type": "1",
                    "oid": String(oid),
                    "segment_index": String(segmentIndex)
                ]
            )
        )
        return DanmakuSegmentResponse(
            status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            body: body
        )
    }

    static func postDanmaku(
        oid: Int,
        bvid: String,
        message: String,
        progress: Int,
        mode: Int = 1,
        color: Int = 16_777_215,
        fontSize: Int = 25
    ) async throws(BiliError) -> PostDanmakuResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/v2/dm/post",
                method: .post,
                params: [
                    "type": "1",
                    "oid": String(oid),
                    "bvid": bvid,
                    "msg": message,
                    "progress": String(progress),
                    "mode": String(mode),
                    "color": String(color),
                    "fontsize": String(fontSize),
                    "pool": "0",
                    "rnd": String(Int(Date().timeIntervalSince1970 * 1_000_000)),
                    "csrf": csrf,
                ]
            ),
            type: PostDanmakuResult.self
        )
    }

    static func getUserFilters() async throws(BiliError) -> [CloudDanmakuFilterRule] {
        guard AuthManager.shared.isLoggedIn else { throw .authRequired }
        let result = try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/dm/filter/user"),
            type: CloudDanmakuFilterResult.self
        )
        return result.rule ?? []
    }
}

struct PostDanmakuResult: Decodable, Sendable {
    let dmid: Int?
    let dmidStr: String?

    var resolvedID: Int64? {
        if let dmid, dmid > 0 { return Int64(dmid) }
        guard let dmidStr, let parsed = Int64(dmidStr), parsed > 0 else { return nil }
        return parsed
    }

    enum CodingKeys: String, CodingKey {
        case dmid
        case dmidStr = "dmid_str"
    }
}
