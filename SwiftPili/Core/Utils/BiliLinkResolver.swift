import Foundation

enum BiliLinkTarget: Equatable, Sendable {
    case video(VideoID)
    case liveRoom(Int)
    case userSpace(Int)
    case moment(String)
    case article(Int)
    case music(MusicDestination)
    case bangumi(Int)
    case search(SearchType, keyword: String)
}

enum BiliLinkResolution: Equatable, Sendable {
    case resolved(BiliLinkTarget, sanitized: URL?)
    case needsRedirect(URL)
    case none
}

enum BiliLinkHostPolicy {
    static let bilibiliDomains: Set<String> = ["bilibili.com"]
    static let shortenerDomains: Set<String> = [
        "b23.tv",
        "bili2233.cn",
        "acg.tv",
        "bili22.cn",
        "bili23.cn",
        "bili33.cn",
    ]

    static func matches(host: String?, anyOf domains: Set<String>) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return domains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    static func isBilibiliHost(_ host: String?) -> Bool {
        matches(host: host, anyOf: bilibiliDomains)
    }

    static func isShortener(_ host: String?) -> Bool {
        matches(host: host, anyOf: shortenerDomains)
    }

    static func isSupportedScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum BiliLinkSanitizer {
    static let trackingParameters: Set<String> = [
        "spm_id_from", "vd_source", "buvid", "mid", "share_source",
        "share_medium", "share_plat", "share_session_id", "share_tag",
        "share_from", "plat_id", "timestamp", "unique_k", "up_id",
        "from_spmid", "from_source", "seid", "bbid", "ts", "msource",
        "refer_from", "visit_id", "share_times", "is_story_h5", "hotRank",
        "session_id", "launch_id", "trackid", "broadcast_type", "jumpfrom",
        "sourceFrom", "live_from", "up_dynamic",
    ]

    static func sanitize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        guard let items = components.queryItems, !items.isEmpty else {
            components.query = nil
            return components.url ?? url
        }
        let kept = items.filter { !trackingParameters.contains($0.name) }
        components.queryItems = kept.isEmpty ? nil : kept
        components.fragment = nil
        return components.url ?? url
    }
}

enum BiliLinkScanner {
    enum Match: Equatable, Sendable {
        case bvid(String)
        case aid(Int)
        case url(URL)
    }

    static func firstMatch(in text: String) -> Match? {
        if let url = firstURL(in: text) { return .url(url) }
        let outsideURLs = textWithURLsRemoved(text)
        if let bvid = firstBVID(in: outsideURLs) { return .bvid(bvid) }
        if let aid = firstAID(in: outsideURLs) { return .aid(aid) }
        return nil
    }

    private static func textWithURLsRemoved(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return text }
        let ns = text as NSString
        let mutable = NSMutableString(string: text)
        for match in regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ).reversed() {
            mutable.replaceCharacters(
                in: match.range,
                with: String(repeating: " ", count: match.range.length)
            )
        }
        return mutable as String
    }

    private static let urlPattern = #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#

    private static func firstURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,;:!?)]}。，！？；：】」》）".contains(last) {
                raw.removeLast()
            }
            guard let url = URL(string: raw),
                  BiliLinkHostPolicy.isSupportedScheme(url.scheme)
            else { continue }
            let host = url.host
            if BiliLinkHostPolicy.isBilibiliHost(host) || BiliLinkHostPolicy.isShortener(host) {
                return url
            }
        }
        return nil
    }

    private static func firstBVID(in text: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9])([Bb][Vv][A-HJ-NP-Za-km-z1-9]{10})(?![A-Za-z0-9])"#
        guard let raw = firstCapture(pattern, in: text) else { return nil }
        return BiliLinkResolver.normalizedBVID(raw)
    }

    private static func firstAID(in text: String) -> Int? {
        let pattern = #"(?<![A-Za-z0-9])[Aa][Vv](\d{1,12})(?![A-Za-z0-9])"#
        guard let digits = firstCapture(pattern, in: text),
              let aid = Int(digits), aid > 0 else { return nil }
        return aid
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

enum BiliLinkResolver {
    static func resolve(text: String) -> BiliLinkResolution {
        guard let match = BiliLinkScanner.firstMatch(in: text) else { return .none }
        switch match {
        case .bvid(let value):
            return .resolved(.video(.bvid(value)), sanitized: nil)
        case .aid(let value):
            return .resolved(.video(.aid(value)), sanitized: nil)
        case .url(let url):
            return resolve(url: url)
        }
    }

    static func resolve(url: URL) -> BiliLinkResolution {
        guard BiliLinkHostPolicy.isSupportedScheme(url.scheme) else { return .none }
        let host = url.host

        if BiliLinkHostPolicy.isShortener(host) {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count == 1, let first = parts.first {
                if let target = videoTarget(fromPathComponent: first, allowBareNumeric: false) {
                    return .resolved(target, sanitized: BiliLinkSanitizer.sanitize(url))
                }
                if let seasonID = parsedPrefixedID(first, prefix: "ss") {
                    return .resolved(.bangumi(seasonID), sanitized: BiliLinkSanitizer.sanitize(url))
                }
            }
            return .needsRedirect(url)
        }

        guard BiliLinkHostPolicy.isBilibiliHost(host) else { return .none }
        guard let target = musicTarget(for: url) ?? target(forBilibiliURL: url) else { return .none }
        return .resolved(target, sanitized: BiliLinkSanitizer.sanitize(url))
    }

    static func resolveRedirect(finalURL: URL) -> BiliLinkResolution {
        guard BiliLinkHostPolicy.isSupportedScheme(finalURL.scheme),
              BiliLinkHostPolicy.isBilibiliHost(finalURL.host),
              let target = musicTarget(for: finalURL) ?? target(forBilibiliURL: finalURL)
        else { return .none }
        return .resolved(target, sanitized: BiliLinkSanitizer.sanitize(finalURL))
    }

    // MARK: - Strict ID validation

    private static let base58Charset = Set("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz123456789")

    static func normalizedBVID(_ raw: String) -> String? {
        guard raw.count == 12,
              raw.prefix(2).lowercased() == "bv" else { return nil }
        let body = raw.dropFirst(2)
        guard body.allSatisfy({ $0.isASCII && base58Charset.contains($0) }) else { return nil }
        return "BV" + body
    }

    static func parsedAID(_ raw: String, allowBareNumeric: Bool) -> Int? {
        guard !raw.isEmpty else { return nil }
        if raw.prefix(2).lowercased() == "av" {
            let digits = raw.dropFirst(2)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let aid = Int(digits), aid > 0 else { return nil }
            return aid
        }
        if allowBareNumeric,
           raw.allSatisfy({ $0.isASCII && $0.isNumber }),
           let aid = Int(raw), aid > 0 {
            return aid
        }
        return nil
    }

    static func parsedPrefixedID(_ raw: String, prefix: String) -> Int? {
        let count = prefix.count
        guard raw.count > count,
              raw.prefix(count).lowercased() == prefix.lowercased() else { return nil }
        let digits = raw.dropFirst(count)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), value > 0 else { return nil }
        return value
    }

    static func isPositiveNumericID(_ raw: String) -> Bool {
        !raw.isEmpty && raw.allSatisfy({ $0.isASCII && $0.isNumber }) && raw.contains(where: { $0 != "0" })
    }

    // MARK: - Identity extraction

    private static func musicTarget(for url: URL) -> BiliLinkTarget? {
        guard url.host?.lowercased() == "music.bilibili.com",
              url.path.split(separator: "/").map(String.init) == ["h5", "music-detail"] else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let identifier = query.first(where: { $0.name == "music_id" })?.value,
              let reference = MusicReference(
                musicID: identifier,
                originAid: query.first(where: { $0.name == "aid" })?.value.flatMap(Int.init),
                originCid: query.first(where: { $0.name == "cid" })?.value.flatMap(Int.init)
              ) else { return nil }
        return .music(MusicDestination(reference: reference, originalURL: BiliLinkSanitizer.sanitize(url)))
    }

    private static func target(forBilibiliURL url: URL) -> BiliLinkTarget? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        if host.hasPrefix("search.") {
            return searchTarget(pathHead: parts.first, queryValue: queryValue)
        }
        if host.hasPrefix("space.") {
            if let first = parts.first, let mid = Int(first), mid > 0 { return .userSpace(mid) }
            return nil
        }
        if host.hasPrefix("live.") {
            if let first = parts.first {
                if let room = Int(first), room > 0 { return .liveRoom(room) }
                let lower = first.lowercased()
                if (lower == "h5" || lower == "blanc"), parts.count >= 2,
                   let room = Int(parts[1]), room > 0 {
                    return .liveRoom(room)
                }
            }
            return nil
        }
        if host.hasPrefix("t.") {
            if parts.count == 1, isPositiveNumericID(parts[0]) {
                return .moment(parts[0])
            }
            if parts.count >= 4,
               parts[0].lowercased() == "h5",
               parts[1].lowercased() == "dynamic",
               parts[2].lowercased() == "detail",
               isPositiveNumericID(parts[3]) {
                return .moment(parts[3])
            }
            if parts.count >= 2,
               ["dynamic", "opus", "detail"].contains(parts[0].lowercased()),
               isPositiveNumericID(parts[1]) {
                return .moment(parts[1])
            }
            return nil
        }

        guard let first = parts.first?.lowercased() else { return nil }
        switch first {
        case "video":
            guard parts.count >= 2 else { return nil }
            return videoTarget(fromPathComponent: parts[1], allowBareNumeric: true)
        case "s":
            guard parts.count >= 3, parts[1].lowercased() == "video" else { return nil }
            return videoTarget(fromPathComponent: parts[2], allowBareNumeric: true)
        case "bangumi":
            guard parts.count >= 3, parts[1].lowercased() == "play" else { return nil }
            if let seasonID = parsedPrefixedID(parts[2], prefix: "ss") {
                return .bangumi(seasonID)
            }
            return nil
        case "search":
            return searchTarget(pathHead: parts.dropFirst().first, queryValue: queryValue)
        case "dynamic":
            guard parts.count >= 2, isPositiveNumericID(parts[1]) else { return nil }
            return .moment(parts[1])
        case "opus":
            guard parts.count >= 2, isPositiveNumericID(parts[1]) else { return nil }
            return .moment(parts[1])
        case "h5":
            if parts.count >= 4,
               parts[1].lowercased() == "dynamic",
               parts[2].lowercased() == "detail",
               isPositiveNumericID(parts[3]) {
                return .moment(parts[3])
            }
            return nil
        case "read":
            guard parts.count >= 2 else { return nil }
            let second = parts[1]
            if let cv = parsedPrefixedID(second, prefix: "cv") { return .article(cv) }
            if second.lowercased() == "mobile" {
                if parts.count >= 3, let cv = parsedPrefixedID(parts[2], prefix: "cv") ?? positiveInt(parts[2]) {
                    return .article(cv)
                }
                if let rawID = queryValue(["id"]),
                   let cv = parsedPrefixedID(rawID, prefix: "cv") ?? positiveInt(rawID) {
                    return .article(cv)
                }
            }
            return nil
        case "space":
            guard parts.count >= 2, let mid = Int(parts[1]), mid > 0 else { return nil }
            return .userSpace(mid)
        case "live":
            guard parts.count >= 2, let room = Int(parts[1]), room > 0 else { return nil }
            return .liveRoom(room)
        case "festival", "list", "medialist":
            if let bvid = queryValue(["bvid"]).flatMap(normalizedBVID) {
                return .video(.bvid(bvid))
            }
            if let aid = queryValue(["aid", "avid"]).flatMap({ parsedAID($0, allowBareNumeric: true) }) {
                return .video(.aid(aid))
            }
            if first != "festival" {
                for segment in parts.dropFirst().reversed() {
                    if let target = videoTarget(fromPathComponent: segment, allowBareNumeric: false) {
                        return target
                    }
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func searchTarget(
        pathHead: String?,
        queryValue: ([String]) -> String?
    ) -> BiliLinkTarget? {
        guard let keyword = queryValue(["keyword", "word", "q"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty else { return nil }
        let rawType = (pathHead ?? queryValue(["type"]) ?? "all").lowercased()
        let searchType: SearchType = switch rawType {
        case "video": .video
        case "bangumi", "pgc", "media_bangumi": .bangumi
        case "live", "live_room": .liveRoom
        case "upuser", "user", "bili_user": .user
        case "article", "read": .article
        default: .all
        }
        return .search(searchType, keyword: keyword)
    }

    private static func positiveInt(_ raw: String) -> Int? {
        guard raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw), value > 0 else { return nil }
        return value
    }

    static func videoTarget(fromPathComponent raw: String, allowBareNumeric: Bool = true) -> BiliLinkTarget? {
        guard !raw.isEmpty else { return nil }
        if let bvid = normalizedBVID(raw) {
            return .video(.bvid(bvid))
        }
        if let aid = parsedAID(raw, allowBareNumeric: allowBareNumeric) {
            return .video(.aid(aid))
        }
        return nil
    }
}

// MARK: - Routing

extension BiliLinkTarget {
    var route: Route {
        switch self {
        case .video(let id): .videoDetail(id)
        case .liveRoom(let room): .liveRoom(room)
        case .userSpace(let mid): .userSpace(mid)
        case .moment(let id): .momentDetail(id)
        case .article(let cv): .articleReader(cv)
        case .music(let destination): .musicInfo(destination)
        case .bangumi(let seasonID): .bangumiDetail(seasonID)
        case .search(let type, let keyword): .search(type, keyword: keyword)
        }
    }
}
