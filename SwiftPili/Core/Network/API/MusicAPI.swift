import Foundation

enum MusicAPI {
    static func detail(musicID: String) async throws(BiliError) -> MusicDetail {
        guard !musicID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .apiError(code: -1, message: String(localized: "Data decode failed"))
        }
        let detail: MusicDetail = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/copyright-music-publicity/bgm/detail",
                params: ["music_id": musicID]
            )
        )
        guard !detail.musicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .apiError(code: -1, message: String(localized: "Data decode failed"))
        }
        return detail
    }
}

struct MusicDetail: Decodable, Sendable {
    let musicTitle: String
    let mvCover: String?
    let album: String?
    let musicSource: String?
    let originArtist: String?
    let originArtistList: String?
    let artists: [Artist]?
    let artistsList: [Artist]?
    let mvAid: Int?
    let mvBvid: String?
    let mvCid: Int?

    struct Artist: Decodable, Sendable {
        let mid: Int?
        let name: String?
        let face: String?
    }

    var displayArtists: [Artist] {
        let preferred = artistsList?.filter {
            $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        if let preferred, !preferred.isEmpty { return preferred }
        return artists?.filter { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false } ?? []
    }

    var artistText: String? {
        [originArtistList, originArtist].compactMap { value in
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }.first
    }

    var mvVideoID: VideoID? {
        if let bvid = mvBvid?.trimmingCharacters(in: .whitespacesAndNewlines),
           case .bvid(let identified)? = BiliLinkScanner.firstMatch(in: bvid), identified == bvid {
            return .bvid(bvid)
        }
        if let mvAid, mvAid > 0 { return .aid(mvAid) }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case musicTitle = "music_title"
        case mvCover = "mv_cover"
        case album
        case musicSource = "music_source"
        case originArtist = "origin_artist"
        case originArtistList = "origin_artist_list"
        case artists
        case artistsList = "artists_list"
        case mvAid = "mv_aid"
        case mvBvid = "mv_bvid"
        case mvCid = "mv_cid"
    }
}
