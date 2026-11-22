import Foundation

/// VOD danmaku transport: protobuf metadata (`view`), 6-minute bullet segments
/// (`seg.so`), and non-retried bullet posting (`post`).
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

    /// One six-minute segment of a video's bullets, as the raw reply.
    ///
    /// Returns bytes rather than decoded elements on purpose: the decode is
    /// ~1.4 ms for the densest segment measured, which is a quarter of a frame
    /// and does not belong on whatever actor the caller happens to be. The store
    /// moves it off-main; handing back `[DanmakuElem]` from here would take that
    /// choice away.
    ///
    /// Returns status and content type with the body, and does NOT throw on a
    /// non-2xx: risk-control rejections arrive as **HTTP 200 with a JSON
    /// envelope**, so the status line cannot be the verdict, and every outcome
    /// — 200 protobuf, 200 envelope, 412, 5xx — has to reach
    /// `DanmakuSegmentClassifier` and the log with the same evidence attached
    /// (`bytes=… status=…`). Only a request that never completed throws.
    ///
    /// - Parameters:
    ///   - oid: the part's `cid`, not the video's `aid`.
    ///   - segmentIndex: 1-based; segment *n* covers `[(n-1)*360, n*360)`.
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

    /// Post one scroll bullet. Never retry: `BiliAPIClient` already refuses to
    /// retry POSTs, and a second attempt could double-send.
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
}

struct PostDanmakuResult: Decodable, Sendable {
    let dmid: Int?
    let dmidStr: String?

    /// Both reply forms identify the same server bullet. Preserve that actual
    /// numeric id for the renderer even when only dmid_str was returned.
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
