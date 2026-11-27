import CoreGraphics
import Foundation
import Observation

enum PortraitVideoPresentationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case inlineExpandable = "inline_expandable"
    case immersiveFullscreen = "immersive_fullscreen"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inlineExpandable: String(localized: "Inline Adaptive")
        case .immersiveFullscreen: String(localized: "Immersive Fullscreen")
        }
    }
}

enum BiliAspectRatioURIParser {
    static func parseAspectRatio(from uri: String?) -> CGFloat? {
        guard let trimmed = uri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        if let components = URLComponents(string: trimmed),
           let items = components.queryItems,
           !items.isEmpty {
            let width = items.first(where: { $0.name == "player_width" })?.value.flatMap(Double.init)
            let height = items.first(where: { $0.name == "player_height" })?.value.flatMap(Double.init)
            if let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 {
                let rotate = items.first(where: { $0.name == "player_rotate" })?.value == "1"
                let effectiveWidth = rotate ? height : width
                let effectiveHeight = rotate ? width : height
                let ratio = effectiveWidth / effectiveHeight
                if ratio.isFinite, ratio >= 0.2, ratio <= 4.0 {
                    return CGFloat(ratio)
                }
            }
        }

        if trimmed.lowercased().hasPrefix("bilibili://story") {
            return 9.0 / 16.0
        }
        return nil
    }
}

enum PortraitPagingRoute: Equatable, Sendable {
    case onlineDetail
    case offlinePlayback
    case shorts
}

enum PortraitPagingPolicy {
    static let shortsFeedEnabled = false

    static func allowsVerticalPaging(on route: PortraitPagingRoute) -> Bool {
        switch route {
        case .onlineDetail, .offlinePlayback:
            return false
        case .shorts:
            return shortsFeedEnabled
        }
    }

    static func allowsVerticalPaging(
        on route: PortraitPagingRoute,
        isImmersiveStage: Bool,
        itemCount: Int
    ) -> Bool {
        guard isImmersiveStage, itemCount > 1 else { return false }
        switch route {
        case .onlineDetail, .offlinePlayback, .shorts:
            return true
        }
    }
}

enum PortraitVODCondensationPolicy {
    static let collapseThreshold: CGFloat = -60

    static func shouldAutoCollapse(
        offset: CGFloat,
        isCondensed: Bool,
        hasManualChoice: Bool
    ) -> Bool {
        guard offset.isFinite, !isCondensed, !hasManualChoice else { return false }
        return offset < collapseThreshold
    }

    static func condensationProgress(
        scrollOffset: CGFloat,
        expandedHeight: CGFloat,
        compactHeight: CGFloat
    ) -> CGFloat {
        let delta = expandedHeight - compactHeight
        guard delta > 1, scrollOffset.isFinite, expandedHeight.isFinite, compactHeight.isFinite else {
            return 0
        }
        return min(max(max(0, -scrollOffset) / delta, 0), 1)
    }
}

enum PortraitImmersiveStagePolicy {
    static func shouldEnterOnInitialOpen(
        mode: PortraitVideoPresentationMode,
        isWideLayout: Bool,
        usesCompactFraming: Bool,
        aspectRatio: CGFloat?,
        isPortraitFallback: Bool
    ) -> Bool {
        guard mode == .immersiveFullscreen,
              !isWideLayout,
              usesCompactFraming else { return false }
        return DetailPlayerGeometry.isPortraitAspect(aspectRatio, fallback: isPortraitFallback)
    }

    static func shouldPromoteAfterMetadataLoad(
        mode: PortraitVideoPresentationMode,
        isWideLayout: Bool,
        usesCompactFraming: Bool,
        isAlreadyImmersive: Bool,
        userCollapsedCurrentVideo: Bool,
        userHasScrolledInline: Bool,
        aspectRatio: CGFloat?,
        isPortraitFallback: Bool
    ) -> Bool {
        guard mode == .immersiveFullscreen,
              !isWideLayout,
              usesCompactFraming,
              !isAlreadyImmersive,
              !userCollapsedCurrentVideo,
              !userHasScrolledInline else { return false }
        return DetailPlayerGeometry.isPortraitAspect(aspectRatio, fallback: isPortraitFallback)
    }
}

struct PortraitPagingCoverSource: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case mobileVariant
        case desktop
    }

    let desktopURL: String
    let mobileVariantURL: String?

    init(desktopURL: String, mobileVariantURL: String? = nil) {
        self.desktopURL = desktopURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mobileVariantURL = mobileVariantURL
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func portraitPreview(desktopURL: String, mobileVariantURL: String?) -> Self {
        Self(desktopURL: desktopURL, mobileVariantURL: mobileVariantURL)
    }

    static func desktop(url: String) -> Self {
        Self(desktopURL: url)
    }

    func url(preferring preferred: Kind) -> String {
        switch preferred {
        case .mobileVariant:
            return mobileVariantURL ?? desktopURL
        case .desktop:
            return desktopURL.isEmpty ? (mobileVariantURL ?? desktopURL) : desktopURL
        }
    }

    func kind(preferring preferred: Kind) -> Kind {
        switch preferred {
        case .mobileVariant:
            return mobileVariantURL == nil ? .desktop : .mobileVariant
        case .desktop:
            return desktopURL.isEmpty && mobileVariantURL != nil ? .mobileVariant : .desktop
        }
    }

    var isEmpty: Bool { desktopURL.isEmpty && mobileVariantURL == nil }
}

struct PortraitPagingPreview: Hashable, Sendable {
    let title: String
    let coverSource: PortraitPagingCoverSource
    let ownerName: String
    let durationSeconds: Int
    let isPortraitHint: Bool?
    let aspectRatioHint: CGFloat?

    private static func normalizedAspectRatioHint(_ aspect: CGFloat?) -> CGFloat? {
        guard let aspect, aspect.isFinite, aspect > 0.1, aspect <= 5.0 else {
            return nil
        }
        return aspect
    }

    init(
        title: String,
        coverURL: String = "",
        ownerName: String = "",
        durationSeconds: Int = 0,
        isPortraitHint: Bool? = nil,
        aspectRatioHint: CGFloat? = nil
    ) {
        let normalizedAspect = Self.normalizedAspectRatioHint(aspectRatioHint)
        self.title = title
        coverSource = .desktop(url: coverURL)
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
        self.aspectRatioHint = normalizedAspect
        self.isPortraitHint = isPortraitHint ?? normalizedAspect.map { $0 < 0.95 }
    }

    init(
        title: String,
        coverSource: PortraitPagingCoverSource,
        ownerName: String = "",
        durationSeconds: Int = 0,
        isPortraitHint: Bool? = nil,
        aspectRatioHint: CGFloat? = nil
    ) {
        let normalizedAspect = Self.normalizedAspectRatioHint(aspectRatioHint)
        self.title = title
        self.coverSource = coverSource
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
        self.aspectRatioHint = normalizedAspect
        self.isPortraitHint = isPortraitHint ?? normalizedAspect.map { $0 < 0.95 }
    }
}

struct VideoRouteTarget: Hashable, Sendable, Identifiable {
    let videoID: VideoID
    let preview: PortraitPagingPreview
    let zoomSourceID: UUID?

    var id: VideoID { videoID }

    init(
        videoID: VideoID,
        preview: PortraitPagingPreview = .init(title: ""),
        zoomSourceID: UUID? = nil
    ) {
        self.videoID = videoID
        self.preview = preview
        self.zoomSourceID = zoomSourceID
    }

    func opening(from sourceID: UUID) -> Self {
        Self(videoID: videoID, preview: preview, zoomSourceID: sourceID)
    }

    var withoutZoom: Self {
        zoomSourceID == nil ? self : Self(videoID: videoID, preview: preview, zoomSourceID: nil)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.videoID == rhs.videoID }

    func hash(into hasher: inout Hasher) { hasher.combine(videoID) }

    static func make(
        bvid: String?,
        aid: Int?,
        title: String,
        coverURL: String = "",
        mobileCoverURL: String? = nil,
        ownerName: String = "",
        durationSeconds: Int = 0,
        isPortraitHint: Bool? = nil,
        aspectRatioHint: CGFloat? = nil
    ) -> Self? {
        let videoID: VideoID
        if let bvid = bvid?.trimmingCharacters(in: .whitespacesAndNewlines), !bvid.isEmpty {
            videoID = .bvid(bvid)
        } else if let aid, aid > 0 {
            videoID = .aid(aid)
        } else {
            return nil
        }
        return Self(
            videoID: videoID,
            preview: .init(
                title: title,
                coverSource: .portraitPreview(
                    desktopURL: coverURL,
                    mobileVariantURL: mobileCoverURL
                ),
                ownerName: ownerName,
                durationSeconds: max(0, durationSeconds),
                isPortraitHint: isPortraitHint,
                aspectRatioHint: aspectRatioHint
            )
        )
    }
}

struct OfflinePortraitPagingItem: Hashable, Sendable, Identifiable {
    let downloadID: String
    let preview: PortraitPagingPreview

    var id: String { downloadID }
}

struct OfflinePortraitPagingContext: Hashable, Sendable {
    let items: [OfflinePortraitPagingItem]
    let initialIndex: Int

    init?(items: [OfflinePortraitPagingItem], selectedID: String) {
        var seen: Set<String> = []
        let stable = items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard let initialIndex = stable.firstIndex(where: { $0.id == selectedID }) else { return nil }
        self.items = stable
        self.initialIndex = initialIndex
    }

    static func single(_ id: String) -> Self {
        Self(
            items: [.init(downloadID: id, preview: .init(title: ""))],
            selectedID: id
        )!
    }
}

struct PortraitPagingToken: Hashable, Sendable {
    let rawValue: UInt64
}

struct PortraitPagingReducer: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        var distanceFraction: CGFloat = 0.22
        var predictedFraction: CGFloat = 0.42
        var boundaryDamping: CGFloat = 0.28
    }

    enum SettlementKind: Equatable, Sendable {
        case rebound
        case switchPage(targetIndex: Int)
    }

    struct Settlement: Equatable, Sendable {
        let token: PortraitPagingToken
        let kind: SettlementKind
    }

    enum Phase: Equatable, Sendable {
        case idle
        case dragging
        case settling(Settlement)
    }

    struct Commit: Equatable, Sendable {
        let token: PortraitPagingToken
        let index: Int
    }

    private(set) var currentIndex: Int
    private(set) var offset: CGFloat = 0
    private(set) var phase: Phase = .idle
    private(set) var containerHeight: CGFloat = 0
    private(set) var coverResolutionBudget: CGSize = .zero

    static let coverBoxQuantum: CGFloat = 32

    private(set) var itemCount: Int
    private var tokenCounter: UInt64 = 0
    let configuration: Configuration

    init(itemCount: Int, initialIndex: Int, configuration: Configuration = .init()) {
        self.itemCount = max(0, itemCount)
        currentIndex = itemCount > 0 ? min(max(0, initialIndex), itemCount - 1) : 0
        self.configuration = configuration
    }

    var acceptsTouch: Bool { phase == .idle && itemCount > 0 }
    var previousIndex: Int? { currentIndex > 0 ? currentIndex - 1 : nil }
    var nextIndex: Int? { currentIndex + 1 < itemCount ? currentIndex + 1 : nil }

    mutating func updateItemCount(_ count: Int) {
        let normalized = max(0, count)
        itemCount = normalized
        if normalized == 0 {
            currentIndex = 0
            if phase != .idle {
                phase = .idle
                offset = 0
                tokenCounter &+= 1
            }
            return
        }
        if currentIndex >= normalized {
            currentIndex = normalized - 1
        }
        if case .settling(let settlement) = phase,
           case .switchPage(let target) = settlement.kind,
           target >= normalized {
            phase = .idle
            offset = 0
            tokenCounter &+= 1
        }
    }

    mutating func syncItems(count: Int, currentIndex newIndex: Int) {
        updateItemCount(count)
        guard phase == .idle else { return }
        if itemCount > 0 {
            currentIndex = min(max(0, newIndex), itemCount - 1)
        } else {
            currentIndex = 0
        }
    }

    mutating func updateContainerHeight(_ height: CGFloat) {
        let normalized = height.isFinite && height > 0 ? height : 0
        guard normalized != containerHeight else { return }
        containerHeight = normalized
        guard phase != .idle else { return }
        phase = .idle
        offset = 0
        tokenCounter &+= 1
    }

    mutating func noteCoverResolution(width: CGFloat, height: CGFloat) {
        guard width.isFinite, width > 0, height.isFinite, height > 0 else { return }
        let quantizedWidth = Self.quantizedCoverSide(width)
        let quantizedHeight = Self.quantizedCoverSide(height)
        guard quantizedWidth == coverResolutionBudget.width else {
            coverResolutionBudget = CGSize(width: quantizedWidth, height: quantizedHeight)
            return
        }
        guard quantizedHeight > coverResolutionBudget.height else { return }
        coverResolutionBudget.height = quantizedHeight
    }

    private static func quantizedCoverSide(_ side: CGFloat) -> CGFloat {
        (side / coverBoxQuantum).rounded(.up) * coverBoxQuantum
    }

    @discardableResult
    mutating func beginDrag() -> Bool {
        guard acceptsTouch else { return false }
        phase = .dragging
        offset = 0
        return true
    }

    func dragOffset(for translation: CGFloat) -> CGFloat {
        guard phase == .dragging, translation.isFinite else { return offset }
        return targetIndex(for: translation) == nil
            ? translation * configuration.boundaryDamping
            : translation
    }

    @discardableResult
    mutating func drag(translation: CGFloat) -> CGFloat {
        guard phase == .dragging, translation.isFinite else { return offset }
        offset = dragOffset(for: translation)
        return offset
    }

    @discardableResult
    mutating func endDrag(translation: CGFloat, predictedEndTranslation: CGFloat) -> Settlement? {
        guard phase == .dragging else { return nil }
        let actual = translation.isFinite ? translation : 0
        let predicted = predictedEndTranslation.isFinite ? predictedEndTranslation : actual
        let directionSample = abs(actual) > 0.5 ? actual : predicted
        let sameDirection = actual == 0 || predicted == 0 || actual * predicted >= 0
        let crossesThreshold = containerHeight > 0 && (
            abs(actual) >= containerHeight * configuration.distanceFraction ||
                (sameDirection && abs(predicted) >= containerHeight * configuration.predictedFraction)
        )

        let kind: SettlementKind
        if let target = targetIndex(for: directionSample), crossesThreshold {
            kind = .switchPage(targetIndex: target)
            offset = directionSample < 0 ? -containerHeight : containerHeight
        } else {
            kind = .rebound
            offset = 0
        }
        let settlement = nextSettlement(kind)
        phase = .settling(settlement)
        return settlement
    }

    @discardableResult
    mutating func cancelDrag() -> Settlement? {
        guard phase == .dragging else { return nil }
        offset = 0
        let settlement = nextSettlement(.rebound)
        phase = .settling(settlement)
        return settlement
    }

    func settlement(for token: PortraitPagingToken) -> Settlement? {
        guard case .settling(let settlement) = phase, settlement.token == token else { return nil }
        return settlement
    }

    @discardableResult
    mutating func abandonSettlement(token: PortraitPagingToken) -> Bool {
        guard settlement(for: token) != nil else { return false }
        phase = .idle
        offset = 0
        return true
    }

    @discardableResult
    mutating func completeSettlement(token: PortraitPagingToken) -> Commit? {
        guard let settlement = settlement(for: token) else { return nil }
        phase = .idle
        offset = 0
        guard case .switchPage(let target) = settlement.kind else { return nil }
        currentIndex = target
        return Commit(token: token, index: target)
    }

    private func targetIndex(for translation: CGFloat) -> Int? {
        guard translation != 0 else { return nil }
        let target = currentIndex + (translation < 0 ? 1 : -1)
        return (0..<itemCount).contains(target) ? target : nil
    }

    private mutating func nextSettlement(_ kind: SettlementKind) -> Settlement {
        tokenCounter &+= 1
        return .init(token: .init(rawValue: tokenCounter), kind: kind)
    }
}

enum PortraitPagingSettlementDispatcher {
    enum Resolution<ItemID> {
        case noop
        case settledNonSwitch(PortraitPagingReducer)
        case abandoned(PortraitPagingReducer)
        case switched(PortraitPagingReducer, PortraitPagingReducer.Commit, ItemID)
    }

    static func resolve<ItemID>(
        token: PortraitPagingToken,
        reducer: PortraitPagingReducer,
        itemIDAtIndex: (Int) -> ItemID?,
        handoff: () -> Bool
    ) -> Resolution<ItemID> {
        var next = reducer
        guard let settlement = next.settlement(for: token) else { return .noop }
        guard case .switchPage(let targetIndex) = settlement.kind else {
            _ = next.completeSettlement(token: token)
            return .settledNonSwitch(next)
        }
        guard let itemID = itemIDAtIndex(targetIndex), handoff() else {
            _ = next.abandonSettlement(token: token)
            return .abandoned(next)
        }
        guard let commit = next.completeSettlement(token: token) else { return .noop }
        return .switched(next, commit, itemID)
    }

    @discardableResult
    static func complete<ItemID>(
        token: PortraitPagingToken,
        getReducer: () -> PortraitPagingReducer,
        setReducer: (PortraitPagingReducer) -> Void,
        itemIDAtIndex: (Int) -> ItemID?,
        handoff: () -> Bool,
        activate: (PortraitPagingReducer.Commit, ItemID) -> Void
    ) -> Bool {
        switch resolve(
            token: token,
            reducer: getReducer(),
            itemIDAtIndex: itemIDAtIndex,
            handoff: handoff
        ) {
        case .noop:
            return false
        case .settledNonSwitch(let updated), .abandoned(let updated):
            setReducer(updated)
            return false
        case .switched(let updated, let commit, let itemID):
            setReducer(updated)
            activate(commit, itemID)
            return true
        }
    }
}

struct PortraitImmersiveEntry: Hashable, Sendable, Identifiable {
    let id: String
    let target: VideoRouteTarget
    let preferredCid: Int?
    let queueItemID: String?

    init(
        id: String,
        target: VideoRouteTarget,
        preferredCid: Int? = nil,
        queueItemID: String? = nil
    ) {
        self.id = id
        self.target = target.withoutZoom
        self.preferredCid = preferredCid
        self.queueItemID = queueItemID
    }
}

@MainActor
protocol PortraitImmersiveBlocklistChecking {
    func isBlocked(_ mid: Int) -> Bool
}

extension BlocklistManager: PortraitImmersiveBlocklistChecking {}

@MainActor
@Observable
final class PortraitImmersiveFeedSession {
    typealias RecommendationFetcher = @Sendable (Int) async throws -> RecommendResult

    private(set) var entries: [PortraitImmersiveEntry] = []
    @ObservationIgnored private var storedReducer = PortraitPagingReducer(itemCount: 0, initialIndex: 0)
    var reducer: PortraitPagingReducer {
        get {
            access(keyPath: \.reducer)
            return storedReducer
        }
        set {
            guard newValue != storedReducer else { return }
            withMutation(keyPath: \.reducer) {
                storedReducer = newValue
            }
        }
    }
    private(set) var isBackedByPlaybackQueue = false
    private(set) var isRefilling = false

    @ObservationIgnored private let recommendationFetcher: RecommendationFetcher
    @ObservationIgnored private var seenKeys: Set<String> = []
    @ObservationIgnored private var freshIdx = 0
    @ObservationIgnored private var sessionGeneration: UInt64 = 0

    init(
        recommendationFetcher: @escaping RecommendationFetcher = { idx in
            try await HomeAPI.getRecommended(freshIdx: idx, ps: 20)
        }
    ) {
        self.recommendationFetcher = recommendationFetcher
    }

    var currentEntry: PortraitImmersiveEntry? {
        entry(at: reducer.currentIndex)
    }

    func entry(at index: Int) -> PortraitImmersiveEntry? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    func reset(
        initialTarget: VideoRouteTarget,
        preferredCid: Int? = nil,
        activeQueue: PlaybackQueueContext? = nil
    ) {
        sessionGeneration &+= 1
        isRefilling = false
        freshIdx = 0
        let previousHeight = reducer.containerHeight

        if let queue = activeQueue, !queue.items.isEmpty {
            let mapped = queue.items.map(Self.entry(for:))
            isBackedByPlaybackQueue = true
            entries = mapped
            seenKeys = Set(mapped.map { Self.dedupKey(for: $0.target.videoID) })
            var nextReducer = PortraitPagingReducer(
                itemCount: mapped.count,
                initialIndex: queue.currentIndex
            )
            if previousHeight > 0 {
                nextReducer.updateContainerHeight(previousHeight)
            }
            reducer = nextReducer
        } else {
            let normalizedTarget = initialTarget.withoutZoom
            isBackedByPlaybackQueue = false
            entries = [
                PortraitImmersiveEntry(
                    id: normalizedTarget.videoID.queryParam,
                    target: normalizedTarget,
                    preferredCid: preferredCid,
                    queueItemID: nil
                ),
            ]
            seenKeys = [Self.dedupKey(for: normalizedTarget.videoID)]
            var nextReducer = PortraitPagingReducer(itemCount: 1, initialIndex: 0)
            if previousHeight > 0 {
                nextReducer.updateContainerHeight(previousHeight)
            }
            reducer = nextReducer
        }
    }

    func syncPlaybackQueue(_ queue: PlaybackQueueContext?) {
        if let queue, !queue.items.isEmpty {
            if !isBackedByPlaybackQueue {
                sessionGeneration &+= 1
                isRefilling = false
            }
            let mapped = queue.items.map(Self.entry(for:))
            isBackedByPlaybackQueue = true
            entries = mapped
            seenKeys = Set(mapped.map { Self.dedupKey(for: $0.target.videoID) })
            reducer.syncItems(count: mapped.count, currentIndex: queue.currentIndex)
        } else if isBackedByPlaybackQueue {
            sessionGeneration &+= 1
            isRefilling = false
            isBackedByPlaybackQueue = false
            if let current = currentEntry {
                let detachedTarget = current.target.withoutZoom
                entries = [
                    PortraitImmersiveEntry(
                        id: detachedTarget.videoID.queryParam,
                        target: detachedTarget,
                        preferredCid: current.preferredCid,
                        queueItemID: nil
                    ),
                ]
                seenKeys = [Self.dedupKey(for: detachedTarget.videoID)]
                reducer.syncItems(count: 1, currentIndex: 0)
            } else {
                entries = []
                seenKeys = []
                reducer.syncItems(count: 0, currentIndex: 0)
            }
        }
    }

    func ingestRelatedVideos(
        _ videos: [VideoCard],
        filterStore: LocalContentFilterStore = .shared,
        blocklist: any PortraitImmersiveBlocklistChecking = BlocklistManager.shared
    ) {
        guard !isBackedByPlaybackQueue, !videos.isEmpty else { return }

        var portraitAdditions: [PortraitImmersiveEntry] = []
        var otherAdditions: [PortraitImmersiveEntry] = []

        for video in videos {
            guard let normalizedBVID = LocalContentFilterStore.normalizedBVID(video.bvid) else {
                continue
            }
            if video.owner.mid > 0, blocklist.isBlocked(video.owner.mid) {
                continue
            }
            if filterStore.shouldHideVideo(
                aid: video.aid > 0 ? video.aid : nil,
                bvid: normalizedBVID,
                mid: video.owner.mid > 0 ? video.owner.mid : nil,
                title: video.title,
                includeCloudBlocklist: false
            ) {
                continue
            }
            let keys = Self.dedupKeys(bvid: normalizedBVID, aid: video.aid)
            guard !keys.isEmpty, keys.allSatisfy({ !seenKeys.contains($0) }) else {
                continue
            }
            seenKeys.formUnion(keys)

            let target = VideoDetailRouteTargetFactory.relatedTarget(for: video).withoutZoom
            let entry = PortraitImmersiveEntry(
                id: target.videoID.queryParam,
                target: target,
                preferredCid: nil,
                queueItemID: nil
            )
            let isPortrait = video.dimension?.isPortrait == true
                || (video.dimension?.effectiveAspectRatio ?? 1.0) < 0.95
            if isPortrait {
                portraitAdditions.append(entry)
            } else {
                otherAdditions.append(entry)
            }
        }

        let additions = portraitAdditions + otherAdditions
        guard !additions.isEmpty else { return }
        entries.append(contentsOf: additions)
        reducer.updateItemCount(entries.count)
    }

    func shouldRefillRecommendations(threshold: Int = 3) -> Bool {
        !isBackedByPlaybackQueue
            && !isRefilling
            && !entries.isEmpty
            && (entries.count - 1 - reducer.currentIndex) <= threshold
    }

    func refillRecommendationsIfNeeded(
        threshold: Int = 3,
        filterStore: LocalContentFilterStore = .shared,
        blocklist: any PortraitImmersiveBlocklistChecking = BlocklistManager.shared
    ) async {
        guard shouldRefillRecommendations(threshold: threshold) else { return }

        let generation = sessionGeneration
        isRefilling = true
        defer {
            if sessionGeneration == generation {
                isRefilling = false
            }
        }

        freshIdx += 1
        let requestIndex = freshIdx
        let result: RecommendResult
        do {
            result = try await recommendationFetcher(requestIndex)
        } catch {
            return
        }

        guard !Task.isCancelled,
              sessionGeneration == generation,
              !isBackedByPlaybackQueue else {
            return
        }

        let items = result.item ?? []
        var portraitAdditions: [PortraitImmersiveEntry] = []
        var otherAdditions: [PortraitImmersiveEntry] = []

        for item in items {
            guard item.goto == nil || item.goto == "av" else { continue }
            guard let normalizedBVID = LocalContentFilterStore.normalizedBVID(item.bvid) else {
                continue
            }
            if let mid = item.owner?.mid, mid > 0, blocklist.isBlocked(mid) {
                continue
            }
            if filterStore.shouldHideVideo(
                aid: item.id > 0 ? item.id : nil,
                bvid: normalizedBVID,
                mid: item.owner?.mid,
                title: item.title,
                includeCloudBlocklist: false
            ) {
                continue
            }
            let keys = Self.dedupKeys(bvid: normalizedBVID, aid: item.id)
            guard !keys.isEmpty, keys.allSatisfy({ !seenKeys.contains($0) }) else {
                continue
            }
            let aspectRatioHint = item.aspectRatioHint
            guard let target = VideoRouteTarget.make(
                bvid: normalizedBVID,
                aid: item.id > 0 ? item.id : nil,
                title: item.title,
                coverURL: item.pic,
                mobileCoverURL: item.mobileCoverURL,
                ownerName: item.owner?.name ?? "",
                durationSeconds: item.duration ?? 0,
                isPortraitHint: aspectRatioHint.map { $0 < 0.95 },
                aspectRatioHint: aspectRatioHint
            )?.withoutZoom else {
                continue
            }

            seenKeys.formUnion(keys)
            let entry = PortraitImmersiveEntry(
                id: target.videoID.queryParam,
                target: target,
                preferredCid: nil,
                queueItemID: nil
            )
            if (aspectRatioHint ?? 1.0) < 0.95 {
                portraitAdditions.append(entry)
            } else {
                otherAdditions.append(entry)
            }
        }

        let additions = portraitAdditions + otherAdditions
        guard !additions.isEmpty else { return }
        entries.append(contentsOf: additions)
        reducer.updateItemCount(entries.count)
    }

    static func dedupKey(for videoID: VideoID) -> String {
        switch videoID {
        case .aid(let aid):
            return "aid:\(aid)"
        case .bvid(let bvid):
            let normalized = LocalContentFilterStore.normalizedBVID(bvid)
                ?? bvid.trimmingCharacters(in: .whitespacesAndNewlines)
            return "bv:\(normalized)"
        }
    }

    private static func dedupKeys(bvid: String?, aid: Int?) -> [String] {
        var keys: [String] = []
        if let normalized = LocalContentFilterStore.normalizedBVID(bvid) {
            keys.append("bv:\(normalized)")
        }
        if let aid, aid > 0 {
            keys.append("aid:\(aid)")
        }
        return keys
    }

    private static func entry(for item: PlaybackQueueItem) -> PortraitImmersiveEntry {
        let base = item.playlistRouteTarget.withoutZoom
        let resolvedPortrait = base.preview.isPortraitHint ?? item.isPortraitHint
        let resolvedAspect = base.preview.aspectRatioHint ?? item.aspectRatioHint
        let target: VideoRouteTarget
        if resolvedPortrait != base.preview.isPortraitHint
            || resolvedAspect != base.preview.aspectRatioHint {
            target = VideoRouteTarget(
                videoID: base.videoID,
                preview: PortraitPagingPreview(
                    title: base.preview.title,
                    coverSource: base.preview.coverSource,
                    ownerName: base.preview.ownerName,
                    durationSeconds: base.preview.durationSeconds,
                    isPortraitHint: resolvedPortrait,
                    aspectRatioHint: resolvedAspect
                ),
                zoomSourceID: nil
            )
        } else {
            target = base
        }
        return PortraitImmersiveEntry(
            id: item.id,
            target: target,
            preferredCid: item.cid > 0 ? item.cid : nil,
            queueItemID: item.id
        )
    }
}
