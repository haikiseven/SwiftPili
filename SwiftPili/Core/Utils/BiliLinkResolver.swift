import Foundation

enum BiliLinkTarget: Equatable, Sendable {
    case video(VideoID)
    case liveRoom(Int)
    case userSpace(Int)
    case moment(String)
    case article(Int)
    case music(MusicDestination)
}

enum BiliLinkResolution: Equatable, Sendable {
    case resolved(BiliLinkTarget, sanitized: URL?)
    case needsRedirect(URL)
    case none
}

enum BiliLinkHostPolicy {
    static let bilibiliDomains: Set<String> = ["bilibili.com"]
    static let shortenerDomains: Set<String> = ["b23.tv"]

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
            while let last = raw.last, ".,;:!?)】」".contains(last) {
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
        let pattern = #"(?<![A-Za-z0-9])(BV[A-HJ-NP-Za-km-z1-9]{10})(?![A-Za-z0-9])"#
        return firstCapture(pattern, in: text)
    }

    private static func firstAID(in text: String) -> Int? {
        let pattern = #"(?<![A-Za-z0-9])[Aa][Vv](\d{1,12})(?![A-Za-z0-9])"#
        guard let digits = firstCapture(pattern, in: text) else { return nil }
        return Int(digits)
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
            let first = url.pathComponents.dropFirst().first ?? ""
            if let target = videoTarget(fromPathComponent: first) {
                return .resolved(target, sanitized: BiliLinkSanitizer.sanitize(url))
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

        if host.hasPrefix("space.") {
            if let mid = parts.first.flatMap(Int.init) { return .userSpace(mid) }
            return nil
        }
        if host.hasPrefix("live.") {
            if let room = parts.first.flatMap(Int.init) { return .liveRoom(room) }
            return nil
        }
        if host.hasPrefix("t.") {
            if let last = parts.last, Int(last) != nil { return .moment(last) }
            return nil
        }

        guard let first = parts.first else { return nil }
        switch first {
        case "video":
            guard parts.count >= 2 else { return nil }
            return videoTarget(fromPathComponent: parts[1])
        case "read":
            guard parts.count >= 2 else { return nil }
            let raw = parts[1]
            if raw.hasPrefix("cv"), let cv = Int(raw.dropFirst(2)) { return .article(cv) }
            if raw == "mobile", parts.count >= 3, let cv = Int(parts[2]) { return .article(cv) }
            return nil
        case "opus":
            guard parts.count >= 2, Int(parts[1]) != nil else { return nil }
            return .moment(parts[1])
        case "space":
            guard parts.count >= 2, let mid = Int(parts[1]) else { return nil }
            return .userSpace(mid)
        case "live":
            guard parts.count >= 2, let room = Int(parts[1]) else { return nil }
            return .liveRoom(room)
        default:
            return nil
        }
    }

    private static func videoTarget(fromPathComponent raw: String) -> BiliLinkTarget? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("BV") || raw.hasPrefix("bv") {
            return .video(.bvid("BV" + raw.dropFirst(2)))
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("av"), let aid = Int(lower.dropFirst(2)) {
            return .video(.aid(aid))
        }
        if let aid = Int(raw) { return .video(.aid(aid)) }
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
        }
    }
}
