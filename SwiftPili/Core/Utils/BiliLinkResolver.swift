import Foundation

/// A Bilibili destination recovered from arbitrary text or a URL.
///
/// Deliberately separate from `Route`: this is *what was identified*, and
/// routing is a decision the navigation layer makes about it. Keeping them
/// apart is what lets the clipboard detector hold a target without navigating.
enum BiliLinkTarget: Equatable, Sendable {
    case video(VideoID)
    case liveRoom(Int)
    case userSpace(Int)
    case moment(String)
    case article(Int)
    case music(MusicDestination)
}

/// The outcome of the resolution pipeline.
enum BiliLinkResolution: Equatable, Sendable {
    /// Identified without touching the network. `sanitized` is the cleaned URL
    /// when the input was one, for callers that want to hand a link onward.
    case resolved(BiliLinkTarget, sanitized: URL?)
    /// An opaque `b23.tv` short code. One redirect is required, and only from
    /// this host — see `BiliLinkHostPolicy`.
    case needsRedirect(URL)
    case none
}

/// Which hosts may be trusted as a final Bilibili destination.
///
/// This is the open-redirect defence. A short link is followed only when the
/// INPUT is a known shortener, and whatever it lands on must be a Bilibili host
/// before any identity is extracted from it — otherwise `b23.tv/x` pointing at
/// `evil.example/video/BV1` would route as a video.
enum BiliLinkHostPolicy {
    /// Registrable domains this app will build a route from.
    ///
    /// Exactly one entry, and deliberately so: every destination this app
    /// actually routes to lives under `bilibili.com` (www, m, live, space, t).
    /// `bilibili.tv` is the international site with a different API, so a route
    /// built from it would query the wrong backend; `biligame.com` serves none
    /// of these paths. A redirect target is trusted only against observed
    /// destinations — widening this set on a guess is exactly how a shortener
    /// walks a client somewhere it should not go.
    static let bilibiliDomains: Set<String> = ["bilibili.com"]
    /// Shorteners whose redirect this app is willing to follow. Nothing else is
    /// followed at all.
    static let shortenerDomains: Set<String> = ["b23.tv"]

    /// Case-insensitive registrable-suffix match. A plain `hasSuffix` would
    /// accept `notbilibili.com`, so the boundary before the suffix is required.
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

    /// Only http(s). A `javascript:` or `data:` "link" pasted into a comment
    /// must never reach the redirect follower or a route.
    static func isSupportedScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// Removes share/tracking parameters, keeping functional ones.
///
/// The rule is a DENY list, not an allow list, and that is the point: the
/// functional parameters differ per destination (`p` for a part, `t` for a
/// timestamp, `start_progress`, episode and season ids), and an allow list would
/// silently drop the next one anybody adds. Only names known to be tracking are
/// removed.
enum BiliLinkSanitizer {
    /// Injected by Bilibili's own share sheets and by the web player.
    static let trackingParameters: Set<String> = [
        "spm_id_from", "vd_source", "buvid", "mid", "share_source",
        "share_medium", "share_plat", "share_session_id", "share_tag",
        "share_from", "plat_id", "timestamp", "unique_k", "up_id",
        // Observed alongside the above in shared links.
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
            // Also drop a bare "?" so two spellings of the same clean link
            // compare equal.
            components.query = nil
            return components.url ?? url
        }
        let kept = items.filter { !trackingParameters.contains($0.name) }
        components.queryItems = kept.isEmpty ? nil : kept
        // A fragment is never functional on these destinations and carries
        // share anchors.
        components.fragment = nil
        return components.url ?? url
    }
}

/// Finds the first Bilibili reference inside arbitrary text.
///
/// Share text is the normal input: "【title】 https://b23.tv/xxx 转发自…". The
/// scanner therefore looks for references *embedded* in prose rather than
/// requiring the whole string to be an identifier.
enum BiliLinkScanner {
    /// What was found, before any host validation or sanitizing.
    enum Match: Equatable, Sendable {
        case bvid(String)
        case aid(Int)
        case url(URL)
    }

    /// Order matters: a URL containing `BV…` must be matched as a URL so its
    /// functional query survives, so URLs are scanned first.
    ///
    /// Bare identifiers are then scanned over the text with **every** http(s)
    /// URL removed — not over the raw text. Otherwise a BV-shaped token inside
    /// a URL this policy already REJECTED would still be harvested:
    /// `https://youtube.com/watch?v=BV1xx411c7mD` resolved as a Bilibili video,
    /// which is both wrong and a way to make a link look like it goes somewhere
    /// it does not.
    static func firstMatch(in text: String) -> Match? {
        if let url = firstURL(in: text) { return .url(url) }
        let outsideURLs = textWithURLsRemoved(text)
        if let bvid = firstBVID(in: outsideURLs) { return .bvid(bvid) }
        if let aid = firstAID(in: outsideURLs) { return .aid(aid) }
        return nil
    }

    /// Blanks out every http(s) URL so identifier scanning cannot reach inside
    /// one. Replaced with spaces rather than deleted, so the boundary rules that
    /// guard against substring matches still see a separator.
    private static func textWithURLsRemoved(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return text }
        let ns = text as NSString
        let mutable = NSMutableString(string: text)
        // Reverse order so earlier replacements do not shift later ranges.
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

    /// Bounded, explicit scheme. A detector that accepted bare "www." forms
    /// would also have to guess a scheme, and a guessed scheme is not something
    /// to hand a redirect follower.
    private static let urlPattern = #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#

    private static func firstURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            var raw = ns.substring(with: match.range)
            // Trailing punctuation from prose ("… b23.tv/abc." / "…)" ) is not
            // part of the URL.
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

    /// `BV` + 10 base58 characters. Anchored on a non-alphanumeric boundary so
    /// an identifier inside a longer word is not harvested.
    private static func firstBVID(in text: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9])(BV[A-HJ-NP-Za-km-z1-9]{10})(?![A-Za-z0-9])"#
        return firstCapture(pattern, in: text)
    }

    /// `av` + digits, case-insensitive, same boundary rule.
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

/// The one Bilibili link resolver.
///
/// Pipeline, in order:
/// raw text → direct AV/BV → Bilibili URL → known URL sanitized immediately →
/// opaque b23 short link deferred to a redirect → final host validated →
/// tracking stripped → identity extracted.
enum BiliLinkResolver {
    /// Pure. Never performs I/O — a caller that gets `.needsRedirect` decides
    /// whether following it is worth a network request.
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

    /// Pure resolution of a single URL.
    static func resolve(url: URL) -> BiliLinkResolution {
        guard BiliLinkHostPolicy.isSupportedScheme(url.scheme) else { return .none }
        let host = url.host

        if BiliLinkHostPolicy.isShortener(host) {
            // A shortener path that already spells the identity needs no
            // network: b23.tv/BV… and b23.tv/av… are mechanical redirects to
            // www.bilibili.com/video/<same>, verified against the live service.
            let first = url.pathComponents.dropFirst().first ?? ""
            if let target = videoTarget(fromPathComponent: first) {
                return .resolved(target, sanitized: BiliLinkSanitizer.sanitize(url))
            }
            // Genuinely opaque. The caller must follow it, and only then may a
            // destination be trusted.
            return .needsRedirect(url)
        }

        guard BiliLinkHostPolicy.isBilibiliHost(host) else { return .none }
        guard let target = musicTarget(for: url) ?? target(forBilibiliURL: url) else { return .none }
        return .resolved(target, sanitized: BiliLinkSanitizer.sanitize(url))
    }

    /// Completes a `.needsRedirect` once its destination is known.
    ///
    /// `finalURL` must be whatever the transport actually landed on. This is the
    /// gate that makes following a shortener safe: an open redirect to a
    /// non-Bilibili host resolves to `.none` rather than to a route.
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

        // Subdomain-routed destinations first: the path alone is ambiguous.
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
            // /read/cv12345 and /read/mobile/12345
            guard parts.count >= 2 else { return nil }
            let raw = parts[1]
            if raw.hasPrefix("cv"), let cv = Int(raw.dropFirst(2)) { return .article(cv) }
            if raw == "mobile", parts.count >= 3, let cv = Int(parts[2]) { return .article(cv) }
            return nil
        case "opus":
            guard parts.count >= 2, Int(parts[1]) != nil else { return nil }
            return .moment(parts[1])
        case "space":
            // m.bilibili.com/space/<mid>
            guard parts.count >= 2, let mid = Int(parts[1]) else { return nil }
            return .userSpace(mid)
        case "live":
            // m.bilibili.com/live/<room>
            guard parts.count >= 2, let room = Int(parts[1]) else { return nil }
            return .liveRoom(room)
        default:
            return nil
        }
    }

    /// A `BV…` or `av…`/numeric path component.
    private static func videoTarget(fromPathComponent raw: String) -> BiliLinkTarget? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("BV") || raw.hasPrefix("bv") {
            // Preserve the server's capitalization contract: identifiers are
            // "BV" + base58 and the API is case-sensitive about the prefix.
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
    /// The screen this target opens. Kept as a mapping rather than folded into
    /// the resolver so identification stays independent of navigation — the
    /// clipboard detector holds a target without routing it anywhere.
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
