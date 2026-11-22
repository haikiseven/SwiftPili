import Foundation

struct DownloadQualityCacheKey: Hashable, Sendable {
    let aid: Int
    let cid: Int
    let sessionGeneration: UUID
}

struct DownloadQualityOption: Hashable, Sendable {
    let code: Int
    let label: String
    let estimatedBytes: Int64?
}

extension DownloadQualityOption {
    static func options(
        videoStreams: [(id: Int, bandwidth: Int)],
        audioBandwidth: Int?,
        durationSeconds: Int?,
        labels: [Int: String]
    ) -> [DownloadQualityOption] {
        var seen = Set<Int>()
        return videoStreams
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id > $1.id }
            .map { stream in
                DownloadQualityOption(
                    code: stream.id,
                    label: labels[stream.id] ?? String(stream.id),
                    estimatedBytes: durationSeconds.flatMap {
                        DownloadStoragePolicy.estimatedBytes(
                            videoBandwidth: stream.bandwidth,
                            audioBandwidth: audioBandwidth,
                            durationSeconds: $0
                        )
                    }
                )
            }
    }
}

struct DownloadQualityCache: Sendable {
    static let defaultTTL: TimeInterval = 300
    private static let maximumEntries = 128

    private struct Entry {
        let qualities: [DownloadQualityOption]
        let storedAt: Date
    }

    let ttl: TimeInterval
    private var entries: [DownloadQualityCacheKey: Entry] = [:]

    init(ttl: TimeInterval = DownloadQualityCache.defaultTTL) {
        self.ttl = max(0, ttl)
    }

    mutating func value(
        for key: DownloadQualityCacheKey,
        now: Date
    ) -> [DownloadQualityOption]? {
        prune(now: now, sessionGeneration: key.sessionGeneration)
        guard let entry = entries[key] else { return nil }
        return entry.qualities
    }

    mutating func store(
        _ qualities: [DownloadQualityOption],
        for key: DownloadQualityCacheKey,
        now: Date
    ) {
        prune(now: now, sessionGeneration: key.sessionGeneration)
        guard !qualities.isEmpty else { return }
        entries[key] = Entry(qualities: qualities, storedAt: now)
        if entries.count > Self.maximumEntries,
           let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func invalidate(_ key: DownloadQualityCacheKey) {
        entries.removeValue(forKey: key)
    }

    private mutating func prune(now: Date, sessionGeneration: UUID) {
        entries = entries.filter {
            let age = now.timeIntervalSince($0.value.storedAt)
            return $0.key.sessionGeneration == sessionGeneration && age >= 0 && age < ttl
        }
    }
}
