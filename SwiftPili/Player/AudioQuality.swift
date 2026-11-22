import Foundation

/// BiliBili's VOD audio tiers, named by the playurl stream `id` they carry.
///
/// `dash.audio` holds the AAC tiers and `dash.flac.audio` the Hi-Res lossless
/// one (VIP only). Dolby (`dash.dolby`, 30250/30255) is deliberately not a case
/// yet: neither engine decodes E-AC-3, and a tier that exists here is a tier
/// the selection below may choose.
enum AudioQualityTier: Int, CaseIterable, Sendable {
    case hiRes = 30251
    case k192 = 30280
    case k132 = 30232
    case k64 = 30216

    /// Ordering for selection. NOT the raw id: 30280 (192K) is numerically
    /// above 30251 (Hi-Res), which is why PiliPlus needs a special case to
    /// step from Hi-Res down to 192K. Ranking by quality needs none.
    var rank: Int {
        switch self {
        case .hiRes: return 3
        case .k192: return 2
        case .k132: return 1
        case .k64: return 0
        }
    }

    /// Menu and Settings label.
    var label: String {
        switch self {
        case .hiRes: return String(localized: "Hi-Res Lossless")
        case .k192: return "192K"
        case .k132: return "132K"
        case .k64: return "64K"
        }
    }

    /// The short tier name the stats overlay puts after the codec.
    var statsLabel: String {
        switch self {
        case .hiRes: return "Hi-Res"
        case .k192: return "192K"
        case .k132: return "132K"
        case .k64: return "64K"
        }
    }

    /// Highest first — the order every picker lists them in.
    static let byRankDescending: [AudioQualityTier] = allCases.sorted { $0.rank > $1.rank }
}

/// Pure audio-stream selection over a playurl DASH manifest.
enum AudioStreamSelection {
    typealias DashStream = PlayURLResult.DashInfo.DashStream

    /// Every audio stream the manifest offers: the lossless track first, then
    /// the AAC tiers. Order carries no meaning for selection, which ranks.
    static func candidates(_ dash: PlayURLResult.DashInfo) -> [DashStream] {
        var streams: [DashStream] = []
        if let flac = dash.flac?.audio { streams.append(flac) }
        streams.append(contentsOf: dash.audio ?? [])
        return streams
    }

    /// Among streams whose id is a known tier the running engine can decode:
    /// the highest rank at or below `preference`, else the lowest rank above
    /// it. `nil` when no stream qualifies — the caller decides the fallback.
    ///
    /// Decodability comes first (Media3's `DefaultTrackSelector`: a track the
    /// renderer cannot decode is never selected), then the preference.
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

    /// The load-time choice for a manifest.
    ///
    /// When no stream carries a known, decodable tier id, today's behaviour
    /// stands: the highest-bandwidth `dash.audio` entry whose id is not a KNOWN
    /// tier the engine refused (an unknown id carries no codec claim to refuse).
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

    /// Tiers the manifest offers that the engine can decode, highest first —
    /// what the in-player menu lists.
    static func availableTiers(
        in dash: PlayURLResult.DashInfo,
        decodable: (AudioQualityTier) -> Bool
    ) -> [AudioQualityTier] {
        let offered = Set(candidates(dash).compactMap { AudioQualityTier(rawValue: $0.id) })
        return AudioQualityTier.byRankDescending.filter { offered.contains($0) && decodable($0) }
    }

    /// Stats-overlay name for the playing audio track: `FLAC Hi-Res`,
    /// `mp4a.40.2 192K`, or the raw codec string for an unknown id.
    static func trackName(codecs: String, tier: AudioQualityTier?) -> String {
        let codecName = codecs.lowercased().hasPrefix("flac") ? "FLAC" : codecs
        return [codecName, tier?.statsLabel ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Two streams claiming one tier resolve deterministically to the fatter.
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
