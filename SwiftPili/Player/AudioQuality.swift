import Foundation

enum AudioQualityTier: Int, CaseIterable, Sendable {
    case hiRes = 30251
    case k192 = 30280
    case k132 = 30232
    case k64 = 30216

    var rank: Int {
        switch self {
        case .hiRes: return 3
        case .k192: return 2
        case .k132: return 1
        case .k64: return 0
        }
    }

    var label: String {
        switch self {
        case .hiRes: return String(localized: "Hi-Res Lossless")
        case .k192: return "192K"
        case .k132: return "132K"
        case .k64: return "64K"
        }
    }

    var statsLabel: String {
        switch self {
        case .hiRes: return "Hi-Res"
        case .k192: return "192K"
        case .k132: return "132K"
        case .k64: return "64K"
        }
    }

    static let byRankDescending: [AudioQualityTier] = allCases.sorted { $0.rank > $1.rank }
}

enum AudioStreamSelection {
    typealias DashStream = PlayURLResult.DashInfo.DashStream

    static func candidates(_ dash: PlayURLResult.DashInfo) -> [DashStream] {
        var streams: [DashStream] = []
        if let flac = dash.flac?.audio { streams.append(flac) }
        streams.append(contentsOf: dash.audio ?? [])
        return streams
    }

    static func select(
        from streams: [DashStream],
        preference: AudioQualityTier,
        decodable: (AudioQualityTier) -> Bool
    ) -> DashStream? {
        let ranked: [(tier: AudioQualityTier, stream: DashStream)] = streams.compactMap { stream in
            guard let tier = AudioQualityTier(rawValue: stream.id), decodable(tier) else { return nil }
            return (tier, stream)
        }
        let atOrBelow = ranked.filter { $0.tier.rank <= preference.rank }
        if let bestRank = atOrBelow.map(\.tier.rank).max() {
            return fattest(atOrBelow, rank: bestRank)
        }
        let above = ranked.filter { $0.tier.rank > preference.rank }
        guard let nearestRank = above.map(\.tier.rank).min() else { return nil }
        return fattest(above, rank: nearestRank)
    }

    static func select(
        in dash: PlayURLResult.DashInfo,
        preference: AudioQualityTier,
        decodable: (AudioQualityTier) -> Bool
    ) -> DashStream? {
        if let chosen = select(from: candidates(dash), preference: preference, decodable: decodable) {
            return chosen
        }
        return (dash.audio ?? [])
            .filter { stream in
                AudioQualityTier(rawValue: stream.id).map(decodable) ?? true
            }
            .max(by: { $0.bandwidth < $1.bandwidth })
    }

    static func availableTiers(
        in dash: PlayURLResult.DashInfo,
        decodable: (AudioQualityTier) -> Bool
    ) -> [AudioQualityTier] {
        let offered = Set(candidates(dash).compactMap { AudioQualityTier(rawValue: $0.id) })
        return AudioQualityTier.byRankDescending.filter { offered.contains($0) && decodable($0) }
    }

    static func trackName(codecs: String, tier: AudioQualityTier?) -> String {
        let codecName = codecs.lowercased().hasPrefix("flac") ? "FLAC" : codecs
        return [codecName, tier?.statsLabel ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func fattest(
        _ ranked: [(tier: AudioQualityTier, stream: DashStream)],
        rank: Int
    ) -> DashStream? {
        ranked
            .filter { $0.tier.rank == rank }
            .max(by: { $0.stream.bandwidth < $1.stream.bandwidth })?
            .stream
    }
}
