import Foundation

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

    static func decision(for urlString: String) -> Decision {
        guard let url = URL(string: urlString) else {
            return Decision(canonicalHost: nil, rejection: .malformedURL)
        }
        return decision(for: url)
    }

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

    static func diagnosticHost(_ host: String?) -> String {
        guard let canonical = canonicalHost(host) else { return "invalid" }
        return String(canonical.prefix(96))
    }

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

    static var blockPCDN: Bool {
        get { UserDefaults.standard.object(forKey: "block_pcdn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "block_pcdn") }
    }

    private static let trustedVODCDNDomains = [
        "bilivideo.com", "bilivideo.cn", "bilibili.com", "hdslb.com",
    ]

    static func admitsVODHost(_ url: URL) -> Bool {
        guard decision(for: url).isAllowed else { return false }
        return !blockPCDN || admitsTrustedVODHost(url)
    }

    static func admitsTrustedVODHost(_ url: URL) -> Bool {
        guard let host = decision(for: url).canonicalHost else { return false }
        guard !host.contains("mcdn.bilivideo") else { return false }
        return trustedVODCDNDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
