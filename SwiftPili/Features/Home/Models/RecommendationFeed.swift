import Foundation

struct VideoFeedSection<Item: Identifiable>: Identifiable {
    let id: UInt64
    var items: [Item]
}

extension VideoFeedSection: Sendable where Item: Sendable {}
extension VideoFeedSection: Equatable where Item: Equatable {}

extension VideoFeedSection {
    static func balanced(
        _ sections: [VideoFeedSection<Item>],
        columnCount: Int,
        reserveLeadingHero: Bool = true
    ) -> [VideoFeedSection<Item>] {
        guard sections.count > 1, columnCount > 1 else { return sections }
        var result = sections
        var index = 0
        while index < result.count - 1 {
            let sliceCount = (reserveLeadingHero && index == 0)
                ? max(0, result[index].items.count - 1)
                : result[index].items.count
            let remainder = sliceCount % columnCount
            if remainder > 0 {
                if sliceCount < columnCount {
                    let merged = VideoFeedSection(
                        id: result[index].id,
                        items: result[index].items + result[index + 1].items
                    )
                    result.replaceSubrange(index...(index + 1), with: [merged])
                    continue
                }
                let splitIndex = result[index].items.count - remainder
                let trailing = Array(result[index].items[splitIndex...])
                result[index].items.removeSubrange(splitIndex...)
                result[index + 1].items.insert(contentsOf: trailing, at: 0)
            }
            index += 1
        }
        return result
    }
}

struct RecommendationFeed: Sendable {
    typealias Generation = VideoFeedSection<RecommendResult.RecommendItem>

    private(set) var generations: [Generation] = []
    private(set) var items: [RecommendResult.RecommendItem] = []
    private var nextGenerationID: UInt64 = 0
    private var admittedIDs: Set<Int> = []
    private var admittedBVIDs: Set<String> = []

    @concurrent
    func newItems(
        from incoming: [RecommendResult.RecommendItem],
        excluding candidates: [RecommendResult.RecommendItem] = [],
        limit: Int = .max
    ) async throws -> [RecommendResult.RecommendItem] {
        try filteredItems(from: incoming, excluding: candidates, limit: limit)
    }

    @concurrent
    func appendingPage(_ incoming: [RecommendResult.RecommendItem]) async throws -> RecommendationFeed {
        let accepted = try filteredItems(from: incoming)
        guard !accepted.isEmpty else { return self }
        var prepared = self
        if prepared.generations.isEmpty {
            let generation = prepared.makeGeneration(accepted)
            prepared.generations.append(generation)
        } else {
            prepared.generations[prepared.generations.count - 1].items.append(contentsOf: accepted)
        }
        try Task.checkCancellation()
        prepared.items.append(contentsOf: accepted)
        try prepared.recordMembership(accepted)
        return prepared
    }

    @concurrent
    func prepending(
        _ accepted: [RecommendResult.RecommendItem]
    ) async throws -> (feed: RecommendationFeed, generationID: UInt64) {
        try Task.checkCancellation()
        var prepared = self
        let generation = prepared.makeGeneration(accepted)
        prepared.generations.insert(generation, at: 0)
        try Task.checkCancellation()
        prepared.items.insert(contentsOf: accepted, at: 0)
        try prepared.recordMembership(accepted)
        return (prepared, generation.id)
    }

    func balancedGenerations(
        columnCount: Int
    ) -> [VideoFeedSection<RecommendResult.RecommendItem>] {
        VideoFeedSection.balanced(generations, columnCount: columnCount)
    }

    private func filteredItems(
        from incoming: [RecommendResult.RecommendItem],
        excluding candidates: [RecommendResult.RecommendItem] = [],
        limit: Int = .max
    ) throws -> [RecommendResult.RecommendItem] {
        try Task.checkCancellation()
        var candidateIDs = Set(candidates.map(\.id))
        var candidateBVIDs = Set(candidates.compactMap(Self.playableBVID))
        var accepted: [RecommendResult.RecommendItem] = []
        for item in incoming {
            try Task.checkCancellation()
            guard accepted.count < limit else { break }
            guard let bvid = Self.playableBVID(item),
                  !admittedIDs.contains(item.id), !admittedBVIDs.contains(bvid),
                  !candidateIDs.contains(item.id), !candidateBVIDs.contains(bvid) else { continue }
            candidateIDs.insert(item.id)
            candidateBVIDs.insert(bvid)
            accepted.append(item)
        }
        return accepted
    }

    private mutating func recordMembership(_ accepted: [RecommendResult.RecommendItem]) throws {
        for item in accepted {
            try Task.checkCancellation()
            admittedIDs.insert(item.id)
            if let bvid = Self.playableBVID(item) { admittedBVIDs.insert(bvid) }
        }
        try Task.checkCancellation()
    }

    private mutating func makeGeneration(_ items: [RecommendResult.RecommendItem]) -> Generation {
        nextGenerationID &+= 1
        return Generation(id: nextGenerationID, items: items)
    }

    private static func playableBVID(_ item: RecommendResult.RecommendItem) -> String? {
        guard item.goto == nil || item.goto == "av", item.owner != nil else { return nil }
        let bvid = item.bvid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return bvid.isEmpty ? nil : bvid
    }
}
