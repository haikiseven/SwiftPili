import Foundation

enum CDNProvider: String, CaseIterable, Sendable, Identifiable {
    case alibaba
    case tencent
    case huawei
    case other
    case overseas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alibaba: String(localized: "Alibaba Cloud")
        case .tencent: String(localized: "Tencent Cloud")
        case .huawei: String(localized: "Huawei Cloud")
        case .other: String(localized: "Other")
        case .overseas: String(localized: "Overseas")
        }
    }

    var services: [CDNService] {
        CDNService.publishableServices.filter { $0.provider == self }
    }

    // MARK: - User-configured ranking

    static let defaultPriority: [CDNProvider] = [.alibaba, .tencent, .huawei, .other, .overseas]

    static var priority: [CDNProvider] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: "smart_cdn_provider_priority") ?? []
            var order = raw.compactMap(CDNProvider.init(rawValue:))
            for provider in defaultPriority where !order.contains(provider) {
                order.append(provider)
            }
            return order
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "smart_cdn_provider_priority") }
    }

    static var rankTable: [CDNProvider: Int] {
        Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
    }
}

enum CDNService: String, CaseIterable, Sendable, Identifiable {
    case baseUrl
    case backupUrl
    case ali
    case alib
    case alio1
    case cos
    case cosb
    case coso1
    case hw
    case hwb
    case hwo1
    case hw08c
    case hw08h
    case hw08ct
    case tfHw = "tf_hw"
    case tfTx = "tf_tx"
    case estgoss
    case estgcos
    case estghw
    case upcdnbda2
    case aliov
    case cosov
    case hwov
    case eqHk = "eq_hk"
    case mirrorbd
    case mirrorbdb
    case mirror14b
    case mirrorzos
    case mirrorbos
    case cnTjCu0102 = "cn_tj_cu_01_02"
    case cnTjCu0103 = "cn_tj_cu_01_03"

    var id: String { rawValue }

    var label: String {
        String(localized: CDNNodeCatalog[self].labelKey)
    }

    var host: String? {
        CDNNodeCatalog[self].host
    }

    var isOverseas: Bool {
        CDNNodeCatalog[self].sweepMembership == .overseas
    }

    var provider: CDNProvider? {
        CDNNodeCatalog[self].provider
    }

    static var publishableServices: [CDNService] { CDNNodeCatalog.services }

    func safeRewriteURL(_ originalURL: URL) -> URL? {
        guard CDNHostPolicy.allows(originalURL) else { return nil }
        guard let cdnHost = host else { return originalURL }
        return CDNHostPolicy.replacingAuthority(of: originalURL, withHost: cdnHost, scheme: "https")
    }

    static var current: CDNService {
        get {
            let defaults = UserDefaults.standard
            let raw = defaults.string(forKey: "cdn_service") ?? CDNService.backupUrl.rawValue
            guard let service = CDNService(rawValue: raw) else {
                defaults.set(CDNService.backupUrl.rawValue, forKey: "cdn_service")
                return .backupUrl
            }
            return service
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cdn_service") }
    }

    static func fetchSampleVideoURL() async throws -> String {
        let result = try await VideoAPI.getPlayURL(bvid: "BV1fK4y1t7hj", cid: 196018899, quality: 80, fnval: 4048)
        guard let url = result.dash?.video.first?.baseUrl,
              CDNHostPolicy.allows(url) else {
            throw CDNTestError.noStream
        }
        return url
    }

    static func testDownloadSpeed(_ cdn: CDNService, sampleURL: String) async -> CDNTestResult {
        guard let originalURL = URL(string: sampleURL),
              let testURL = cdn.safeRewriteURL(originalURL) else {
            return CDNTestResult(speed: 0, error: String(localized: "Invalid URL"))
        }

        var request = URLRequest(url: testURL, timeoutInterval: 15)
        request.setValue(BiliAPIClient.defaultReferer, forHTTPHeaderField: "Referer")
        request.setValue(BiliAPIClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let maxBytes = 8 * 1024 * 1024
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        let start = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(start)

            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                return CDNTestResult(speed: 0, error: "\(http.statusCode)")
            }

            if !data.isEmpty && elapsed > 0 {
                let megabytesPerSec = Double(data.count) / elapsed / 1_000_000
                return CDNTestResult(speed: megabytesPerSec, error: nil)
            }
            return CDNTestResult(speed: 0, error: String(localized: "No data"))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == -1001 {
                return CDNTestResult(speed: 0, error: String(localized: "Timeout"))
            }
            if nsError.domain == NSURLErrorDomain && nsError.code == -1004 {
                return CDNTestResult(speed: 0, error: String(localized: "Unreachable"))
            }
            return CDNTestResult(speed: 0, error: String(localized: "Failed"))
        }
    }
}

enum CDNTestError: LocalizedError {
    case noStream

    var errorDescription: String? {
        switch self {
        case .noStream: String(localized: "Unable to get test video stream")
        }
    }
}

struct CDNTestResult: Sendable {
    let speed: Double
    let error: String?

    var succeeded: Bool { error == nil && speed > 0 }

    var displayText: String {
        if let error { return error }
        if speed >= 1 {
            return String(format: "%.1f MB/s", speed)
        }
        return String(format: "%.0f KB/s", speed * 1000)
    }
}

enum CDNCloudVendor: String, CaseIterable, Sendable, Equatable {
    case alibaba
    case tencent
    case huawei
    case baidu
    case ctyun
    case kingsoft
    case qiniu
    case wangsu
    case akamai
    case equinix

    var localizedName: String {
        switch self {
        case .alibaba: String(localized: "Alibaba Cloud")
        case .tencent: String(localized: "Tencent Cloud")
        case .huawei: String(localized: "Huawei Cloud")
        case .baidu: String(localized: "Baidu Cloud")
        case .ctyun: String(localized: "CTYun")
        case .kingsoft: String(localized: "Kingsoft Cloud")
        case .qiniu: String(localized: "Qiniu Cloud")
        case .wangsu: String(localized: "Wangsu")
        case .akamai: "Akamai"
        case .equinix: "Equinix"
        }
    }
}

enum CDNHostDisplay {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    static func normalizedDomain(_ rawAuthority: String) -> String {
        var trimmed = rawAuthority.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed.lowercased(with: comparisonLocale)
    }

    static func vendor(for rawAuthority: String) -> CDNCloudVendor? {
        let domain = normalizedDomain(rawAuthority)
        guard !domain.isEmpty else { return nil }

        let hostOnly: String
        if !domain.hasPrefix("["), let colon = domain.firstIndex(of: ":") {
            hostOnly = String(domain[..<colon])
        } else {
            hostOnly = domain
        }
        guard !hostOnly.isEmpty else { return nil }

        if hostOnly.contains("mirrorali")
            || hostOnly.contains("estgoss")
            || hostOnly.contains("upcdnali")
            || hostOnly.contains("tf-all-ali")
            || hostOnly == "alicdn.com"
            || hostOnly.hasSuffix(".alicdn.com") {
            return .alibaba
        }

        if hostOnly.contains("mirrorcos")
            || hostOnly.contains("estgcos")
            || hostOnly.contains("tf-all-tx")
            || hostOnly.contains("upcdntx")
            || hostOnly == "myqcloud.com"
            || hostOnly.hasSuffix(".myqcloud.com") {
            return .tencent
        }

        if hostOnly.contains("mirrorhw")
            || hostOnly.contains("mirror08c")
            || hostOnly.contains("mirror08h")
            || hostOnly.contains("estghw")
            || hostOnly.contains("tf-all-hw")
            || hostOnly.contains("upcdnhw")
            || hostOnly == "huaweicloud.com"
            || hostOnly.hasSuffix(".huaweicloud.com") {
            return .huawei
        }

        if hostOnly.contains("upcdnbd")
            || hostOnly.contains("mirrorbd")
            || hostOnly.contains("mirrorbos")
            || hostOnly == "baidubce.com"
            || hostOnly.hasSuffix(".baidubce.com")
            || hostOnly == "bdydns.com"
            || hostOnly.hasSuffix(".bdydns.com") {
            return .baidu
        }

        if hostOnly.contains("mirrorzos")
            || hostOnly.contains("ctyun")
            || hostOnly.hasSuffix(".ctyunapi.cn") {
            return .ctyun
        }

        if hostOnly.contains("mirrorks")
            || hostOnly.contains("upcdnks")
            || hostOnly.hasSuffix(".ksyun.com")
            || hostOnly.hasSuffix(".ks-cdn.com") {
            return .kingsoft
        }

        if hostOnly.contains("mirrorkodo")
            || hostOnly.contains("upcdnqn")
            || hostOnly.hasSuffix(".qiniucdn.com") {
            return .qiniu
        }

        if hostOnly.contains("upcdnws")
            || hostOnly.contains("mirrorws")
            || hostOnly.hasSuffix(".wscdns.com") {
            return .wangsu
        }

        if hostOnly.contains("mirrorakam")
            || hostOnly.hasSuffix(".akamaized.net")
            || hostOnly.hasSuffix(".akamaihd.net")
            || hostOnly.hasSuffix(".akamai.net") {
            return .akamai
        }

        if hostOnly.hasPrefix("cn-hk-eq-")
            || hostOnly.contains(".equinix.") {
            return .equinix
        }

        return nil
    }

    static func formatted(_ rawAuthority: String) -> String {
        let domain = normalizedDomain(rawAuthority)
        guard !domain.isEmpty else { return "" }
        if let vendor = vendor(for: domain) {
            return "\(domain) (\(vendor.localizedName))"
        }
        return domain
    }
}
