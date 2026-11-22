import Foundation

/// Optional web-player artwork. An unsupported response is decoration failure,
/// never a reason to fail playback or the independent subtitle request.
struct VideoStoryboardManifest: Decodable, Sendable {
    let columns: Int
    let rows: Int
    let cellWidth: Int
    let cellHeight: Int
    let images: [String]
    let index: [Double]

    enum CodingKeys: String, CodingKey {
        case columns = "img_x_len"
        case rows = "img_y_len"
        case cellWidth = "img_x_size"
        case cellHeight = "img_y_size"
        case images = "image"
        case index
    }
}

extension VideoAPI {
    static func getStoryboard(aid: Int, cid: Int) async throws(BiliError) -> VideoStoryboardManifest {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/player/videoshot",
                params: ["aid": String(aid), "cid": String(cid), "index": "1"]
            ),
            type: VideoStoryboardManifest.self
        )
    }
}
