import Foundation

enum PGCAPI {
    static func getSeason(seasonId: Int) async throws(BiliError) -> PGCSeasonInfo {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/pgc/view/web/season",
                params: ["season_id": String(seasonId)]
            ),
            type: PGCSeasonInfo.self
        )
    }

    static func getClipInfo(epId: Int, cid: Int) async -> [(label: String, start: Double, end: Double)] {
        do {
            let data = try await BiliAPIClient.shared.requestRaw(
                BiliEndpoint(
                    path: "/pgc/player/web/v2/playurl",
                    params: [
                        "ep_id": String(epId), "cid": String(cid),
                        "qn": "64", "fnval": "16", "fnver": "0",
                    ]
                )
            )
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let business = (result["play_view_business_info"] ?? result["playViewBusinessInfo"]) as? [String: Any],
                  let clips = (business["clip_info"] ?? business["clipInfo"]) as? [[String: Any]],
                  !clips.isEmpty
            else {
                PlayerLog.log("[PGCAPI] v2 playurl: no clip_info for ep\(epId)")
                return []
            }
            let segments = clips.compactMap { clip -> (label: String, start: Double, end: Double)? in
                let type = ((clip["clip_type"] ?? clip["clipType"]) as? String) ?? ""
                guard let start = (clip["start"] as? NSNumber)?.doubleValue,
                      let end = (clip["end"] as? NSNumber)?.doubleValue,
                      end > start else { return nil }
                return (label: type.contains("ED") ? "ED" : "OP", start: start, end: end)
            }
            PlayerLog.log("[PGCAPI] v2 playurl clip_info for ep\(epId): \(segments.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" }.joined(separator: ", "))")
            return segments
        } catch {
            PlayerLog.log("[PGCAPI] ⚠️ v2 playurl clip_info probe failed for ep\(epId): \(error)")
            return []
        }
    }

    static func getPlayURL(
        epId: Int,
        cid: Int,
        quality: Int,
        fnval: Int
    ) async throws(BiliError) -> PlayURLResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/pgc/player/web/playurl",
                params: [
                    "ep_id": String(epId),
                    "cid": String(cid),
                    "qn": String(quality),
                    "fnval": String(fnval),
                    "fourk": "1",
                ]
            ),
            type: PlayURLResult.self
        )
    }

    static func getFollowedBangumi(mid: Int, type: Int = 1, pn: Int = 1, ps: Int = 30) async throws(BiliError) -> BangumiFollowResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/space/bangumi/follow/list",
                params: [
                    "type": String(type),
                    "vmid": String(mid),
                    "pn": String(pn),
                    "ps": String(ps),
                ]
            ),
            type: BangumiFollowResult.self
        )
    }
}
