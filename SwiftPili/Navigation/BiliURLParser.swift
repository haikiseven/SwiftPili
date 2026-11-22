import Foundation

/// Routes custom `bilibili://` deep links and resolved web links via `BiliLinkResolver`.
enum BiliURLParser {
    static func parse(_ url: URL) -> Route? {
        if url.scheme == "bilibili" {
            return parseBiliScheme(url)
        }
        if case .resolved(let target, _) = BiliLinkResolver.resolve(url: url) {
            return target.route
        }
        return nil
    }

    private static func parseBiliScheme(_ url: URL) -> Route? {
        let host = url.host()
        let pathID = url.pathComponents.dropFirst().first

        switch host {
        case "video":
            guard let id = pathID else { return nil }
            return .videoDetail(parseVideoID(id))
        case "live":
            guard let id = pathID, let roomID = Int(id) else { return nil }
            return .liveRoom(roomID)
        case "space":
            guard let id = pathID, let mid = Int(id) else { return nil }
            return .userSpace(mid)
        default:
            return nil
        }
    }

    private static func parseVideoID(_ raw: String) -> VideoID {
        if raw.hasPrefix("BV") {
            return .bvid(raw)
        }
        if let aid = Int(raw) {
            return .aid(aid)
        }
        return .bvid(raw)
    }
}
