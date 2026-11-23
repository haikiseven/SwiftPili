import Foundation

enum BiliURLParser {
    static func parse(_ url: URL) -> Route? {
        if url.scheme?.lowercased() == "bilibili" {
            return parseBiliScheme(url)
        }
        if case .resolved(let target, _) = BiliLinkResolver.resolve(url: url) {
            return target.route
        }
        return nil
    }

    static func unwrappedBrowserURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "bilibili",
              url.host()?.lowercased() == "browser" else { return nil }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = queryItems.first(where: { $0.name.lowercased() == "url" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let inner = URL(string: normalized) ?? URL(string: normalized, encodingInvalidCharacters: true),
              BiliLinkHostPolicy.isSupportedScheme(inner.scheme) else { return nil }
        return inner
    }

    private static func parseBiliScheme(_ url: URL) -> Route? {
        let host = url.host()?.lowercased()
        let parts = url.path.split(separator: "/").map(String.init)
        let pathID = parts.first
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func queryValue(_ names: String...) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        switch host {
        case "video":
            let rawID = pathID ?? queryValue("bvid", "aid", "avid")
            guard let id = rawID.flatMap(parseVideoID) else { return nil }
            return .videoDetail(id)
        case "live":
            let rawID = pathID ?? queryValue("room_id", "roomid", "id")
            guard let id = rawID, let roomID = Int(id), roomID > 0 else { return nil }
            return .liveRoom(roomID)
        case "space", "author", "user":
            let rawID = pathID ?? queryValue("mid", "uid", "vmid")
            guard let id = rawID, let mid = Int(id), mid > 0 else { return nil }
            return .userSpace(mid)
        case "opus", "dt":
            let candidate = (parts.first?.lowercased() == "detail" ? parts.dropFirst().first : parts.first)
                ?? queryValue("id", "dyn_id")
            guard let id = candidate, BiliLinkResolver.isPositiveNumericID(id) else { return nil }
            return .momentDetail(id)
        case "following":
            let candidate: String? = if parts.count >= 2, parts[0].lowercased() == "detail" {
                parts[1]
            } else if parts.count == 1 {
                parts[0]
            } else {
                queryValue("id", "dyn_id")
            }
            guard let id = candidate, BiliLinkResolver.isPositiveNumericID(id) else { return nil }
            return .momentDetail(id)
        case "article", "read":
            let rawID = pathID ?? queryValue("id", "cvid")
            guard let raw = rawID else { return nil }
            if let cvid = BiliLinkResolver.parsedPrefixedID(raw, prefix: "cv") {
                return .articleReader(cvid)
            }
            if let cvid = Int(raw), cvid > 0 {
                return .articleReader(cvid)
            }
            return nil
        case "bangumi", "pgc":
            if let rawSeason = queryValue("season_id", "seasonid"),
               let sid = BiliLinkResolver.parsedPrefixedID(rawSeason, prefix: "ss")
                   ?? (Int(rawSeason).flatMap { $0 > 0 ? $0 : nil }) {
                return .bangumiDetail(sid)
            }
            if parts.count >= 2, parts[0].lowercased() == "season",
               let sid = Int(parts[1]), sid > 0 {
                return .bangumiDetail(sid)
            }
            if parts.count >= 2, parts[0].lowercased() == "play",
               let sid = BiliLinkResolver.parsedPrefixedID(parts[1], prefix: "ss") {
                return .bangumiDetail(sid)
            }
            if parts.count == 1,
               let sid = BiliLinkResolver.parsedPrefixedID(parts[0], prefix: "ss")
                   ?? (Int(parts[0]).flatMap { $0 > 0 ? $0 : nil }) {
                return .bangumiDetail(sid)
            }
            return nil
        case "search":
            guard let keyword = queryValue("keyword", "word", "q")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !keyword.isEmpty else { return nil }
            return .search(.all, keyword: keyword)
        case "browser":
            guard let inner = unwrappedBrowserURL(from: url) else { return nil }
            switch BiliLinkResolver.resolve(url: inner) {
            case .resolved(let target, _):
                return target.route
            case .needsRedirect:
                return nil
            case .none:
                return .inAppWeb(BiliLinkSanitizer.sanitize(inner))
            }
        default:
            return nil
        }
    }

    private static func parseVideoID(_ raw: String) -> VideoID? {
        if let bvid = BiliLinkResolver.normalizedBVID(raw) {
            return .bvid(bvid)
        }
        if let aid = BiliLinkResolver.parsedAID(raw, allowBareNumeric: true) {
            return .aid(aid)
        }
        return nil
    }
}
