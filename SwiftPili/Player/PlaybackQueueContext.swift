import CoreGraphics
import Foundation

enum PlaylistOrderMode: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case sequential
    case loopList
    case shuffle

    static let defaultsKey = "player_playlist_order_mode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sequential: String(localized: "Sequential")
        case .loopList: String(localized: "Loop List")
        case .shuffle: String(localized: "Shuffle")
        }
    }

    var systemImage: String {
        switch self {
        case .sequential: "arrow.right"
        case .loopList: "repeat"
        case .shuffle: "shuffle"
        }
    }

    static func loadPreferred(from defaults: UserDefaults = .standard) -> PlaylistOrderMode {
        guard let raw = defaults.string(forKey: defaultsKey),
              let mode = PlaylistOrderMode(rawValue: raw) else {
            return .sequential
        }
        return mode
    }

    static func savePreferred(
        _ mode: PlaylistOrderMode,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}

struct PlaybackSkipSegment: Equatable, Hashable, Sendable {
    let label: String
    let start: Double
    let end: Double

    init(label: String, start: Double, end: Double) {
        self.label = label
        self.start = start
        self.end = end
    }

    var asTuple: (label: String, start: Double, end: Double) {
        (label: label, start: start, end: end)
    }
}

struct PlaybackQueueItem: Equatable, Sendable, Identifiable {
    let id: String
    let aid: Int
    let cid: Int
    let bvid: String?
    let title: String
    let artist: String
    let coverURL: String?
    let duration: TimeInterval?
    let isPortraitHint: Bool?
    let aspectRatioHint: CGFloat?
    let source: PlayerViewModel.StreamSource
    let originRoute: Route
    let originScreenRoute: PlayerScreenRoute
    let opEdSegments: [PlaybackSkipSegment]
    let pgcSeasonType: Int?
    let partIndex: Int?
    let partCount: Int?
    let partTitle: String?

    init(
        id: String,
        aid: Int,
        cid: Int,
        bvid: String? = nil,
        title: String,
        artist: String,
        coverURL: String? = nil,
        duration: TimeInterval? = nil,
        isPortraitHint: Bool? = nil,
        aspectRatioHint: CGFloat? = nil,
        source: PlayerViewModel.StreamSource = .ugc,
        originRoute: Route,
        originScreenRoute: PlayerScreenRoute,
        opEdSegments: [PlaybackSkipSegment] = [],
        pgcSeasonType: Int? = nil,
        partIndex: Int? = nil,
        partCount: Int? = nil,
        partTitle: String? = nil
    ) {
        self.id = id
        self.aid = aid
        self.cid = cid
        self.bvid = bvid
        self.title = title
        self.artist = artist
        self.coverURL = coverURL
        self.duration = duration
        self.isPortraitHint = isPortraitHint
        self.aspectRatioHint = aspectRatioHint
        self.source = source
        self.originRoute = originRoute
        self.originScreenRoute = originScreenRoute
        self.opEdSegments = opEdSegments
        self.pgcSeasonType = pgcSeasonType
        self.partIndex = partIndex
        self.partCount = partCount
        self.partTitle = partTitle
    }

    var skipSegmentTuples: [(label: String, start: Double, end: Double)] {
        opEdSegments.map(\.asTuple)
    }

    var isMultiPart: Bool {
        (partCount ?? 0) > 1
    }

    var partBadge: String? {
        guard let partIndex, let partCount, partCount > 1 else { return nil }
        return "P\(partIndex)/\(partCount)"
    }

    var displayTitleWithPart: String {
        guard let partIndex, let partCount, partCount > 1 else { return title }
        if let partTitle, !partTitle.isEmpty {
            return "\(title) (P\(partIndex) \(partTitle))"
        }
        return "\(title) (P\(partIndex)/\(partCount))"
    }

    var playlistRouteTarget: VideoRouteTarget {
        if case .videoDetail(let target) = originRoute {
            return VideoRouteTarget(
                videoID: target.videoID,
                preview: target.preview,
                zoomSourceID: nil
            )
        }
        let videoID: VideoID = if let bvid, !bvid.isEmpty {
            .bvid(bvid)
        } else {
            .aid(aid)
        }
        return VideoRouteTarget(
            videoID: videoID,
            preview: PortraitPagingPreview(
                title: title,
                coverURL: coverURL ?? "",
                ownerName: artist,
                durationSeconds: duration.map { max(0, Int($0.rounded())) } ?? 0
            ),
            zoomSourceID: nil
        )
    }
}

struct PlaybackQueueContext: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case videoParts(aid: Int)
        case bangumiSeason(seasonId: Int)
        case ugcSeason(seasonId: Int)
        case playlist(name: String)
    }

    var kind: Kind
    var items: [PlaybackQueueItem]
    var currentIndex: Int
    var playlistOrderMode: PlaylistOrderMode
    var shuffledOrder: [String]

    init(
        kind: Kind,
        items: [PlaybackQueueItem],
        currentIndex: Int = 0,
        playlistOrderMode: PlaylistOrderMode = .sequential,
        shuffledOrder: [String] = []
    ) {
        self.kind = kind
        self.items = items
        if items.isEmpty {
            self.currentIndex = 0
        } else {
            self.currentIndex = min(max(currentIndex, 0), items.count - 1)
        }
        self.playlistOrderMode = playlistOrderMode
        if playlistOrderMode == .shuffle, !items.isEmpty {
            let itemIDs = Set(items.map(\.id))
            if shuffledOrder.count == items.count && Set(shuffledOrder) == itemIDs {
                self.shuffledOrder = shuffledOrder
            } else {
                var rng = SystemRandomNumberGenerator()
                let currentID = items[self.currentIndex].id
                self.shuffledOrder = Self.buildShuffledOrder(
                    items: items,
                    leadingCurrentID: currentID,
                    avoidingLeadingID: nil,
                    avoidingLeadingAid: nil,
                    using: &rng
                )
            }
        } else {
            self.shuffledOrder = []
        }
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var playlistName: String? {
        guard case .playlist(let name) = kind else { return nil }
        return name
    }

    var isPlaylist: Bool {
        playlistName != nil
    }

    var displayIndex: Int {
        items.isEmpty ? 0 : currentIndex + 1
    }

    var totalCount: Int {
        items.count
    }

    var currentItem: PlaybackQueueItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var hasPrevious: Bool {
        guard items.indices.contains(currentIndex) else { return false }
        switch playlistOrderMode {
        case .sequential:
            return currentIndex > 0
        case .loopList, .shuffle:
            return !items.isEmpty
        }
    }

    var hasNext: Bool {
        guard items.indices.contains(currentIndex) else { return false }
        switch playlistOrderMode {
        case .sequential:
            return currentIndex + 1 < items.count
        case .loopList, .shuffle:
            return !items.isEmpty
        }
    }

    var upNextItem: PlaybackQueueItem? {
        item(atOffset: 1)
    }

    func item(atOffset offset: Int) -> PlaybackQueueItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        if offset == 0 { return items[currentIndex] }
        switch playlistOrderMode {
        case .sequential:
            let targetIndex = currentIndex + offset
            guard items.indices.contains(targetIndex) else { return nil }
            return items[targetIndex]
        case .loopList:
            let count = items.count
            let targetIndex = ((currentIndex + offset) % count + count) % count
            return items[targetIndex]
        case .shuffle:
            let order = normalizedShuffleOrder()
            guard !order.isEmpty, let currentID = currentItem?.id,
                  let pos = order.firstIndex(of: currentID) else { return nil }
            let rawPos = pos + offset
            if order.indices.contains(rawPos) {
                let targetID = order[rawPos]
                return items.first(where: { $0.id == targetID })
            }
            let count = order.count
            if count == 1 {
                return items[0]
            }
            let wrappedPos = ((rawPos % count) + count) % count
            let wrappedID = order[wrappedPos]
            if wrappedID == currentID,
               let fallback = order.first(where: { $0 != currentID }),
               let match = items.first(where: { $0.id == fallback }) {
                return match
            }
            return items.first(where: { $0.id == wrappedID })
        }
    }

    func advancing(by offset: Int) -> (PlaybackQueueContext, PlaybackQueueItem)? {
        var rng = SystemRandomNumberGenerator()
        return advancing(by: offset, using: &rng)
    }

    func advancing(
        by offset: Int,
        using generator: inout some RandomNumberGenerator
    ) -> (PlaybackQueueContext, PlaybackQueueItem)? {
        guard offset != 0, items.indices.contains(currentIndex) else { return nil }
        switch playlistOrderMode {
        case .sequential:
            let targetIndex = currentIndex + offset
            guard items.indices.contains(targetIndex) else { return nil }
            var updated = self
            updated.currentIndex = targetIndex
            return (updated, items[targetIndex])

        case .loopList:
            let count = items.count
            let targetIndex = ((currentIndex + offset) % count + count) % count
            var updated = self
            updated.currentIndex = targetIndex
            return (updated, items[targetIndex])

        case .shuffle:
            var updated = self
            let current = items[currentIndex]
            let order = updated.normalizedShuffleOrder()
            guard !order.isEmpty else { return nil }
            let count = order.count
            if count == 1 {
                updated.shuffledOrder = order
                updated.currentIndex = 0
                return (updated, items[0])
            }
            let pos = order.firstIndex(of: current.id) ?? 0
            let nextPos = pos + offset
            if order.indices.contains(nextPos) {
                updated.shuffledOrder = order
                let targetID = order[nextPos]
                guard let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
                    return nil
                }
                updated.currentIndex = targetIndex
                return (updated, items[targetIndex])
            }
            if offset > 0 {
                let nextCycle = Self.buildShuffledOrder(
                    items: items,
                    leadingCurrentID: nil,
                    avoidingLeadingID: current.id,
                    avoidingLeadingAid: current.aid,
                    using: &generator
                )
                updated.shuffledOrder = nextCycle
                let targetPos = ((nextPos % count) + count) % count
                let targetID = nextCycle[targetPos]
                guard let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
                    return nil
                }
                updated.currentIndex = targetIndex
                return (updated, items[targetIndex])
            } else {
                updated.shuffledOrder = order
                let wrappedPos = ((nextPos % count) + count) % count
                let targetID = order[wrappedPos]
                guard let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
                    return nil
                }
                updated.currentIndex = targetIndex
                return (updated, items[targetIndex])
            }
        }
    }

    func settingOrderMode(_ mode: PlaylistOrderMode) -> PlaybackQueueContext {
        var rng = SystemRandomNumberGenerator()
        return settingOrderMode(mode, using: &rng)
    }

    func settingOrderMode(
        _ mode: PlaylistOrderMode,
        using generator: inout some RandomNumberGenerator
    ) -> PlaybackQueueContext {
        var updated = self
        updated.playlistOrderMode = mode
        if mode == .shuffle, !items.isEmpty {
            let currentID = currentItem?.id ?? items[0].id
            updated.shuffledOrder = Self.buildShuffledOrder(
                items: items,
                leadingCurrentID: currentID,
                avoidingLeadingID: nil,
                avoidingLeadingAid: nil,
                using: &generator
            )
        } else {
            updated.shuffledOrder = []
        }
        return updated
    }

    func selecting(id: String) -> (PlaybackQueueContext, PlaybackQueueItem)? {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var updated = self
        updated.currentIndex = index
        if updated.playlistOrderMode == .shuffle {
            updated.shuffledOrder = updated.normalizedShuffleOrder()
        }
        return (updated, items[index])
    }

    func selecting(aid: Int, cid: Int) -> PlaybackQueueContext {
        guard let index = items.firstIndex(where: { $0.aid == aid && $0.cid == cid }) else {
            return self
        }
        var updated = self
        updated.currentIndex = index
        return updated
    }

    func selecting(source: PlayerViewModel.StreamSource) -> PlaybackQueueContext {
        guard let index = items.firstIndex(where: { $0.source == source }) else {
            return self
        }
        var updated = self
        updated.currentIndex = index
        return updated
    }

    func movingItems(fromOffsets source: IndexSet, toOffset destination: Int) -> PlaybackQueueContext {
        guard !items.isEmpty, !source.isEmpty else { return self }
        let moving = source.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
        guard !moving.isEmpty else { return self }

        let activeID = currentItem?.id
        let removedBeforeDestination = source.filter { $0 < destination }.count
        var reordered: [PlaybackQueueItem] = []
        reordered.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where !source.contains(index) {
            reordered.append(item)
        }
        let insertionIndex = min(max(0, destination - removedBeforeDestination), reordered.count)
        reordered.insert(contentsOf: moving, at: insertionIndex)

        var updated = self
        updated.items = reordered
        if let activeID, let newIndex = reordered.firstIndex(where: { $0.id == activeID }) {
            updated.currentIndex = newIndex
        } else {
            updated.currentIndex = min(max(0, updated.currentIndex), max(0, reordered.count - 1))
        }
        if updated.playlistOrderMode == .shuffle {
            updated.shuffledOrder = updated.normalizedShuffleOrder()
        }
        return updated
    }

    func removingItem(id: String) -> (context: PlaybackQueueContext?, removedActiveItem: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return (self, false)
        }

        var updatedItems = items
        updatedItems.remove(at: index)
        if updatedItems.isEmpty {
            return (nil, true)
        }

        let oldShuffleOrder = playlistOrderMode == .shuffle ? normalizedShuffleOrder() : []
        let updatedShuffleOrder = oldShuffleOrder.filter { $0 != id }

        var updated = self
        updated.items = updatedItems
        if updated.playlistOrderMode == .shuffle {
            updated.shuffledOrder = updatedShuffleOrder
        }

        if index < currentIndex {
            updated.currentIndex = currentIndex - 1
            return (updated, false)
        }
        if index > currentIndex {
            return (updated, false)
        }

        // Removing the currently playing item while other items remain.
        if updated.playlistOrderMode == .shuffle, !updatedShuffleOrder.isEmpty {
            let oldPos = oldShuffleOrder.firstIndex(of: id) ?? 0
            let nextShufflePos = oldPos < updatedShuffleOrder.count ? oldPos : 0
            let nextID = updatedShuffleOrder[nextShufflePos]
            if let nextIndex = updatedItems.firstIndex(where: { $0.id == nextID }) {
                updated.currentIndex = nextIndex
                return (updated, true)
            }
        }

        if index < updatedItems.count {
            updated.currentIndex = index
        } else if updated.playlistOrderMode == .loopList {
            updated.currentIndex = 0
        } else {
            updated.currentIndex = updatedItems.count - 1
        }
        return (updated, true)
    }

    func appendingItems(_ newItems: [PlaybackQueueItem]) -> PlaybackQueueContext {
        var rng = SystemRandomNumberGenerator()
        return appendingItems(newItems, using: &rng)
    }

    func appendingItems(
        _ newItems: [PlaybackQueueItem],
        using generator: inout some RandomNumberGenerator
    ) -> PlaybackQueueContext {
        guard !newItems.isEmpty else { return self }
        var seenIDs = Set(items.map(\.id))
        let uniqueNew = newItems.filter { seenIDs.insert($0.id).inserted }
        guard !uniqueNew.isEmpty else { return self }

        var updated = self
        updated.items.append(contentsOf: uniqueNew)
        if updated.playlistOrderMode == .shuffle {
            var order = normalizedShuffleOrder()
            let currentID = currentItem?.id
            let currentPos = currentID.flatMap { order.firstIndex(of: $0) } ?? 0
            let newBlocks = Self.videoBlocks(from: uniqueNew)
            for block in newBlocks {
                let blockIDs = block.map(\.id)
                let minInsert = min(currentPos + 1, order.count)
                let insertPos = minInsert < order.count
                    ? Int.random(in: minInsert...order.count, using: &generator)
                    : order.count
                order.insert(contentsOf: blockIDs, at: insertPos)
            }
            updated.shuffledOrder = order
        }
        return updated
    }

    func expandingMultiPartVideo(
        info: VideoInfo,
        videoID: VideoID,
        currentCid: Int
    ) -> PlaybackQueueContext {
        guard let pages = info.pages, pages.count > 1 else { return self }
        let existingCids = Set(items.filter { $0.aid == info.aid && $0.source == .ugc }.map(\.cid))
        let pageCids = Set(pages.map(\.cid))
        if existingCids == pageCids {
            return currentItem?.aid == info.aid ? selecting(aid: info.aid, cid: currentCid) : self
        }
        guard let anchorIndex = items.firstIndex(where: { $0.aid == info.aid && $0.source == .ugc }) else {
            return self
        }

        let anchor = items[anchorIndex]
        let bvid = info.bvid.isEmpty ? anchor.bvid : info.bvid
        let cover = info.pic.isEmpty ? anchor.coverURL : info.pic
        let title = info.title.isEmpty ? anchor.title : info.title
        let artist = info.owner.name.isEmpty ? anchor.artist : info.owner.name
        let totalParts = pages.count

        let expandedItems: [PlaybackQueueItem] = pages.map { page in
            let aspectRatioHint = page.dimension?.effectiveAspectRatio
                ?? info.dimension?.effectiveAspectRatio
                ?? anchor.aspectRatioHint
            let portraitHint = page.dimension?.isPortrait ?? info.dimension?.isPortrait ?? anchor.isPortraitHint
            let routeTarget = VideoRouteTarget(
                videoID: videoID,
                preview: PortraitPagingPreview(
                    title: title,
                    coverURL: cover ?? "",
                    ownerName: artist,
                    durationSeconds: page.duration,
                    isPortraitHint: portraitHint,
                    aspectRatioHint: aspectRatioHint
                ),
                zoomSourceID: nil
            )
            return PlaybackQueueItem(
                id: "playlist-part-\(info.aid)-\(page.cid)",
                aid: info.aid,
                cid: page.cid,
                bvid: bvid,
                title: title,
                artist: artist,
                coverURL: cover,
                duration: TimeInterval(page.duration),
                isPortraitHint: portraitHint,
                aspectRatioHint: aspectRatioHint,
                source: .ugc,
                originRoute: .videoDetail(routeTarget),
                originScreenRoute: .video(videoID),
                opEdSegments: [],
                pgcSeasonType: nil,
                partIndex: page.page,
                partCount: totalParts,
                partTitle: page.part.isEmpty ? nil : page.part
            )
        }

        let previousActive = currentItem
        let removedIDs = Set(items.filter { $0.aid == info.aid && $0.source == .ugc }.map(\.id))

        var updatedItems: [PlaybackQueueItem] = []
        updatedItems.reserveCapacity(items.count - removedIDs.count + expandedItems.count)
        var inserted = false
        for item in items {
            if item.aid == info.aid && item.source == .ugc {
                if !inserted {
                    updatedItems.append(contentsOf: expandedItems)
                    inserted = true
                }
            } else {
                updatedItems.append(item)
            }
        }

        var updated = self
        updated.items = updatedItems

        if let previousActive, previousActive.aid == info.aid && previousActive.source == .ugc {
            updated.currentIndex = updatedItems.firstIndex(where: { $0.aid == info.aid && $0.cid == currentCid })
                ?? updatedItems.firstIndex(where: { $0.aid == info.aid })
                ?? 0
        } else if let previousActive,
                  let preservedIndex = updatedItems.firstIndex(where: { $0.id == previousActive.id }) {
            updated.currentIndex = preservedIndex
        } else {
            updated.currentIndex = min(max(0, updated.currentIndex), max(0, updatedItems.count - 1))
        }

        if updated.playlistOrderMode == .shuffle {
            let oldOrder = normalizedShuffleOrder()
            let expandedIDs = expandedItems.map(\.id)
            var nextOrder: [String] = []
            nextOrder.reserveCapacity(updatedItems.count)
            var replacedInShuffle = false
            for entryID in oldOrder {
                if removedIDs.contains(entryID) {
                    if !replacedInShuffle {
                        nextOrder.append(contentsOf: expandedIDs)
                        replacedInShuffle = true
                    }
                } else {
                    nextOrder.append(entryID)
                }
            }
            if !replacedInShuffle {
                nextOrder.append(contentsOf: expandedIDs)
            }
            updated.shuffledOrder = nextOrder
        }

        return updated
    }

    func matchingItem(
        aid: Int?,
        cid: Int?,
        source: PlayerViewModel.StreamSource? = nil
    ) -> PlaybackQueueItem? {
        if let source, case .pgc = source,
           let match = items.first(where: { $0.source == source }) {
            return match
        }
        if let aid, let cid,
           let match = items.first(where: { $0.aid == aid && $0.cid == cid }) {
            return match
        }
        return nil
    }

    // MARK: - Shuffle Order Helpers

    private func normalizedShuffleOrder() -> [String] {
        guard !items.isEmpty else { return [] }
        let validIDs = Set(items.map(\.id))
        var filtered: [String] = []
        filtered.reserveCapacity(items.count)
        var seen = Set<String>()
        for id in shuffledOrder where validIDs.contains(id) && seen.insert(id).inserted {
            filtered.append(id)
        }
        if filtered.count == items.count {
            return filtered
        }
        for item in items where seen.insert(item.id).inserted {
            filtered.append(item.id)
        }
        return filtered
    }

    private static func videoBlocks(from items: [PlaybackQueueItem]) -> [[PlaybackQueueItem]] {
        var blocks: [[PlaybackQueueItem]] = []
        for item in items {
            if var last = blocks.last,
               let firstInBlock = last.first,
               firstInBlock.aid == item.aid && firstInBlock.source == item.source {
                last.append(item)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([item])
            }
        }
        return blocks
    }

    private static func fisherYatesShuffle<T>(
        _ elements: inout [T],
        using generator: inout some RandomNumberGenerator
    ) {
        guard elements.count > 1 else { return }
        for idx in stride(from: elements.count - 1, through: 1, by: -1) {
            let swapIndex = Int.random(in: 0...idx, using: &generator)
            if idx != swapIndex {
                elements.swapAt(idx, swapIndex)
            }
        }
    }

    private static func buildShuffledOrder(
        items: [PlaybackQueueItem],
        leadingCurrentID: String?,
        avoidingLeadingID: String?,
        avoidingLeadingAid: Int?,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        guard !items.isEmpty else { return [] }
        var blocks = videoBlocks(from: items)

        if let leadingCurrentID,
           let blockIndex = blocks.firstIndex(where: { block in
               block.contains(where: { $0.id == leadingCurrentID })
           }) {
            let currentBlock = blocks.remove(at: blockIndex)
            let splitIndex = currentBlock.firstIndex(where: { $0.id == leadingCurrentID }) ?? 0
            let leadingSlice = Array(currentBlock[splitIndex...])
            let earlierParts = Array(currentBlock[..<splitIndex])
            if !earlierParts.isEmpty {
                blocks.append(earlierParts)
            }
            fisherYatesShuffle(&blocks, using: &generator)
            return leadingSlice.map(\.id) + blocks.flatMap { $0.map(\.id) }
        }

        fisherYatesShuffle(&blocks, using: &generator)
        if blocks.count > 1,
           let firstItem = blocks.first?.first,
           firstItem.id == avoidingLeadingID
            || (avoidingLeadingAid != nil && firstItem.aid == avoidingLeadingAid) {
            if let nonMatchingIndex = blocks.indices.dropFirst().first(where: { idx in
                guard let candidate = blocks[idx].first else { return false }
                return candidate.id != avoidingLeadingID
                    && (avoidingLeadingAid == nil || candidate.aid != avoidingLeadingAid)
            }) {
                blocks.swapAt(0, nonMatchingIndex)
            } else if let nonMatchingIDIndex = blocks.indices.dropFirst().first(where: { idx in
                blocks[idx].first?.id != avoidingLeadingID
            }) {
                blocks.swapAt(0, nonMatchingIDIndex)
            }
        }
        return blocks.flatMap { $0.map(\.id) }
    }
}

extension PlaybackQueueContext {
    static func videoParts(
        info: VideoInfo,
        videoID: VideoID,
        currentCid: Int
    ) -> PlaybackQueueContext? {
        guard let pages = info.pages, pages.count > 1 else { return nil }
        let cover = info.pic.isEmpty ? nil : info.pic
        let bvid = info.bvid.isEmpty ? nil : info.bvid
        let totalParts = pages.count
        let items: [PlaybackQueueItem] = pages.map { page in
            let artist = page.part.isEmpty ? info.owner.name : "P\(page.page) \(page.part)"
            let aspectRatioHint = page.dimension?.effectiveAspectRatio
                ?? info.dimension?.effectiveAspectRatio
            let portraitHint = page.dimension?.isPortrait ?? info.dimension?.isPortrait
            let routeTarget = VideoRouteTarget(
                videoID: videoID,
                preview: PortraitPagingPreview(
                    title: info.title,
                    coverURL: info.pic,
                    ownerName: info.owner.name,
                    durationSeconds: page.duration,
                    isPortraitHint: portraitHint,
                    aspectRatioHint: aspectRatioHint
                ),
                zoomSourceID: nil
            )
            return PlaybackQueueItem(
                id: "ugc-part-\(info.aid)-\(page.cid)",
                aid: info.aid,
                cid: page.cid,
                bvid: bvid,
                title: info.title,
                artist: artist,
                coverURL: cover,
                duration: TimeInterval(page.duration),
                isPortraitHint: portraitHint,
                aspectRatioHint: aspectRatioHint,
                source: .ugc,
                originRoute: .videoDetail(routeTarget),
                originScreenRoute: .video(videoID),
                opEdSegments: [],
                pgcSeasonType: nil,
                partIndex: page.page,
                partCount: totalParts,
                partTitle: page.part.isEmpty ? nil : page.part
            )
        }
        let selectedIndex = items.firstIndex(where: { $0.cid == currentCid }) ?? 0
        return PlaybackQueueContext(
            kind: .videoParts(aid: info.aid),
            items: items,
            currentIndex: selectedIndex
        )
    }

    static func bangumiSeason(
        _ season: PGCSeasonInfo,
        seasonId: Int,
        currentEpisodeId: Int?
    ) -> PlaybackQueueContext? {
        guard let episodes = season.episodes else { return nil }
        let seasonTitle = season.title ?? "Anime"
        let items: [PlaybackQueueItem] = episodes.compactMap { episode in
            guard let aid = episode.aid, let cid = episode.cid else { return nil }
            var segments: [PlaybackSkipSegment] = []
            if let op = episode.skip?.op, let start = op.start, let end = op.end, end > start {
                segments.append(PlaybackSkipSegment(label: "OP", start: Double(start), end: Double(end)))
            }
            if let ed = episode.skip?.ed, let start = ed.start, let end = ed.end, end > start {
                segments.append(PlaybackSkipSegment(label: "ED", start: Double(start), end: Double(end)))
            }
            let rawCover = episode.cover ?? season.cover
            let cover = rawCover?.isEmpty == false ? rawCover : nil
            return PlaybackQueueItem(
                id: "pgc-\(seasonId)-\(episode.id)",
                aid: aid,
                cid: cid,
                bvid: episode.bvid,
                title: seasonTitle,
                artist: episode.displayTitle,
                coverURL: cover,
                duration: nil,
                isPortraitHint: nil,
                source: .pgc(epId: episode.id),
                originRoute: .bangumiDetail(seasonId, zoom: .none),
                originScreenRoute: .bangumi(seasonId),
                opEdSegments: segments,
                pgcSeasonType: season.type
            )
        }
        guard !items.isEmpty else { return nil }
        let selectedIndex: Int = if let currentEpisodeId {
            items.firstIndex(where: { $0.source == .pgc(epId: currentEpisodeId) }) ?? 0
        } else {
            0
        }
        return PlaybackQueueContext(
            kind: .bangumiSeason(seasonId: seasonId),
            items: items,
            currentIndex: selectedIndex
        )
    }
}
