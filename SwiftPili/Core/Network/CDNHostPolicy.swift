import Foundation

/// Structural validity of the hosts and URLs a CDN path may use, plus the
/// one VOD-scoped trust decision.
///
/// The shared section answers exactly ONE question: is this a parseable
/// absolute http/https URL with a usable host, and what is its canonical
/// comparison key. No trust, provider or P2P notion lives there — the
/// mirror sweep, DNS/geo resolution, blacklist, seed host, delivery-health
/// probes, live streaming and offline playback all go through it and must
/// not inherit VOD CDN policy. Merely checking never rewrites a URL:
/// canonicalization is limited to comparison keys, and callers keep the
/// original signed bytes.
enum CDNHostPolicy {
    // MARK: - Structural validity (shared by every CDN path)

    enum RejectionReason: String, Equatable, Sendable {
        case malformedURL = "malformed_url"
        case unsupportedScheme = "unsupported_scheme"
        case missingHost = "missing_host"
        case malformedHost = "malformed_host"
    }

    struct Decision: Equatable, Sendable {
        let canonicalHost: String?
        let rejection: RejectionReason?

        var isAllowed: Bool { canonicalHost != nil && rejection == nil }
        var reason: String { rejection?.rawValue ?? "allowed" }
    }

    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    /// Checks an absolute HTTP(S) URL without changing its representation.
    static func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme else {
            return Decision(canonicalHost: nil, rejection: .unsupportedScheme)
        }
        let normalizedScheme = scheme.lowercased(with: comparisonLocale)
        guard normalizedScheme == "http" || normalizedScheme == "https" else {
            return Decision(canonicalHost: nil, rejection: .unsupportedScheme)
        }
        guard let host = url.host(), !host.isEmpty else {
            return Decision(canonicalHost: nil, rejection: .missingHost)
        }
        return decision(forHost: host)
    }

    /// Parses and checks a URL string. The input is not returned or rebuilt.
    static func decision(for urlString: String) -> Decision {
        guard let url = URL(string: urlString) else {
            return Decision(canonicalHost: nil, rejection: .malformedURL)
        }
        return decision(for: url)
    }

    /// Checks a host-only value used by provider, cache, and seed paths.
    static func decision(forHost host: String?) -> Decision {
        guard let canonical = canonicalHost(host) else {
            return Decision(canonicalHost: nil, rejection: host == nil ? .missingHost : .malformedHost)
        }
        return Decision(canonicalHost: canonical, rejection: nil)
    }

    static func allows(_ url: URL) -> Bool {
        decision(for: url).isAllowed
    }

    static func allows(_ urlString: String) -> Bool {
        decision(for: urlString).isAllowed
    }

    static func allowsHost(_ host: String?) -> Bool {
        decision(forHost: host).isAllowed
    }

    /// Comparison key for host dictionaries: lowercased, trailing dots
    /// stripped, and nil for anything that is not a bare host.
    static func canonicalHost(_ host: String?) -> String? {
        guard var value = host?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let forbiddenScalars: Set<Unicode.Scalar> = ["/", "?", "#", "@", "\n", "\r", "\t"]
        guard !value.unicodeScalars.contains(where: { scalar in
            scalar.properties.isWhitespace || scalar.value < 0x20 || forbiddenScalars.contains(scalar)
        }) else {
            return nil
        }

        value = value.lowercased(with: comparisonLocale)
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    /// Host-only text for diagnostics. It cannot contain a path, query, or
    /// cookie because non-host input is reduced to `invalid`.
    static func diagnosticHost(_ host: String?) -> String {
        guard let canonical = canonicalHost(host) else { return "invalid" }
        return String(canonical.prefix(96))
    }

    /// Bounded reason vocabulary for logs. Callers must not interpolate raw
    /// URL/error text into a CDN admission diagnostic.
    static func diagnosticReason(_ raw: String) -> String {
        let value = raw.lowercased(with: comparisonLocale)
        if value.contains("probe") { return "probe" }
        if value.contains("dns") { return "dns" }
        if value.contains("seed") { return "seed" }
        if value.contains("cache") { return "cache" }
        if value.contains("ramp") { return "ramp" }
        if value.contains("black") { return "blacklist" }
        if value.contains("fail") || value.contains("fallback") { return "failover" }
        return "admission"
    }

    /// Replaces only the URL authority and optional scheme. The path, query,
    /// fragment, and their percent-encoded bytes are copied from the original
    /// absolute string rather than reconstructed through URLComponents.
    static func replacingAuthority(
        of originalURL: URL,
        withHost host: String,
        scheme: String? = nil
    ) -> URL? {
        guard decision(for: originalURL).isAllowed,
              let replacementHost = canonicalHost(host),
              let delimiter = originalURL.absoluteString.range(of: "://")
        else { return nil }

        let raw = originalURL.absoluteString
        let authorityStart = delimiter.upperBound
        let authorityEnd = raw[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? raw.endIndex
        let authority = String(raw[authorityStart..<authorityEnd])
        let userInfo: String
        if let at = authority.lastIndex(of: "@") {
            userInfo = String(authority[...at])
        } else {
            userInfo = ""
        }

        let originalScheme = String(raw[..<delimiter.lowerBound])
        let replacementScheme = scheme ?? originalScheme
        let suffix = String(raw[authorityEnd...])
        return URL(string: "\(replacementScheme)://\(userInfo)\(replacementHost)\(suffix)")
    }

    // MARK: - VOD CDN trust (VOD playback only — never a general host check)

    /// Block PCDN hosts entirely (Settings → Network). Default on.
    static var blockPCDN: Bool {
        get { UserDefaults.standard.object(forKey: "block_pcdn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "block_pcdn") }
    }

    /// Domains BiliBili's REAL VOD CDN uses. Everything else in a playurl
    /// response is PCDN: either bilibili's own P2P edge (*.mcdn.bilivideo.cn)
    /// or rented third-party nodes under arbitrary vanity domains
    /// (szbdyd.com, mountaintoys.cn, …) — an allowlist is the only durable
    /// way to catch those. PCDN is excluded from carrier zero-rating
    /// (定向免流) packages and markedly less reliable than the upos CDN.
    private static let trustedVODCDNDomains = [
        "bilivideo.com", "bilivideo.cn", "bilibili.com", "hdslb.com",
    ]

    /// VOD-ONLY: may this host deliver VOD video/audio bytes?
    ///
    /// LIVE STREAMING DELIBERATELY DOES NOT CONSULT THIS — its CDN is a
    /// different network from the VOD upos CDN and legitimately serves from
    /// hosts outside the allowlist above, so VOD trust would reject working
    /// live streams. Offline playback, the mirror sweep and the
    /// delivery-health probes stay structural for the same reason.
    /// With "Block PCDN" off every structurally valid host is admitted: the
    /// trust step is the user's setting, not a hard rule.
    static func admitsVODHost(_ url: URL) -> Bool {
        guard decision(for: url).isAllowed else { return false }
        return !blockPCDN || admitsTrustedVODHost(url)
    }

    /// Helpers are always trusted VOD CDNs, independent of Block PCDN.
    /// This stricter scope never changes structural admission for live/probes.
    static func admitsTrustedVODHost(_ url: URL) -> Bool {
        guard let host = decision(for: url).canonicalHost else { return false }
        // mcdn is bilibili-owned but IS the P2P edge network.
        guard !host.contains("mcdn.bilivideo") else { return false }
        return trustedVODCDNDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
