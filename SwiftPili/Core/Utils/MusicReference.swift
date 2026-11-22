import Foundation

struct MusicReference: Hashable, Sendable {
    let musicID: String
    let originAid: Int?
    let originCid: Int?
    let officialURL: URL

    init?(musicID: String, originAid: Int? = nil, originCid: Int? = nil) {
        let identifier = musicID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        let aid = originAid.flatMap { $0 > 0 ? $0 : nil }
        let cid = originCid.flatMap { $0 > 0 ? $0 : nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.bilibili.com"
        components.path = "/h5/music-detail"
        components.queryItems = [URLQueryItem(name: "music_id", value: identifier)]
        if let aid { components.queryItems?.append(URLQueryItem(name: "aid", value: String(aid))) }
        if let cid { components.queryItems?.append(URLQueryItem(name: "cid", value: String(cid))) }
        guard let url = components.url else { return nil }
        self.musicID = identifier
        self.originAid = aid
        self.originCid = cid
        officialURL = url
    }
}

struct MusicDestination: Hashable, Sendable, Identifiable {
    let reference: MusicReference
    let titleSeed: String?
    let originalURL: URL?

    var id: MusicReference { reference }

    init(reference: MusicReference, titleSeed: String? = nil, originalURL: URL? = nil) {
        self.reference = reference
        let title = titleSeed?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.titleSeed = title?.isEmpty == false ? title : nil
        self.originalURL = originalURL
    }

    var officialURL: URL {
        guard let originalURL,
              BiliLinkHostPolicy.isSupportedScheme(originalURL.scheme),
              originalURL.host()?.lowercased() == "music.bilibili.com",
              originalURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "h5/music-detail",
              var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        else { return reference.officialURL }
        var items = (components.queryItems ?? []).filter {
            !["music_id", "aid", "cid"].contains($0.name)
        }
        items.append(URLQueryItem(name: "music_id", value: reference.musicID))
        if let aid = reference.originAid { items.append(URLQueryItem(name: "aid", value: String(aid))) }
        if let cid = reference.originCid { items.append(URLQueryItem(name: "cid", value: String(cid))) }
        components.queryItems = items
        return components.url ?? reference.officialURL
    }
}
