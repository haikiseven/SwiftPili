import CoreGraphics
import Foundation

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

    init(
        title: String,
        coverURL: String = "",
        ownerName: String = "",
        durationSeconds: Int = 0
    ) {
        self.title = title
        coverSource = .desktop(url: coverURL)
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
    }

    init(
        title: String,
        coverSource: PortraitPagingCoverSource,
        ownerName: String = "",
        durationSeconds: Int = 0
    ) {
        self.title = title
        self.coverSource = coverSource
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
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

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.videoID == rhs.videoID }

    func hash(into hasher: inout Hasher) { hasher.combine(videoID) }

    static func make(
        bvid: String?,
        aid: Int?,
        title: String,
        coverURL: String = "",
        mobileCoverURL: String? = nil,
        ownerName: String = "",
        durationSeconds: Int = 0
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
                durationSeconds: max(0, durationSeconds)
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
    @discardableResult
    static func complete<ItemID>(
        token: PortraitPagingToken,
        reducer: inout PortraitPagingReducer,
        itemIDAtIndex: (Int) -> ItemID?,
        handoff: () -> Bool,
        activate: (PortraitPagingReducer.Commit, ItemID) -> Void
    ) -> Bool {
        guard let settlement = reducer.settlement(for: token) else { return false }
        guard case .switchPage(let targetIndex) = settlement.kind else {
            _ = reducer.completeSettlement(token: token)
            return false
        }
        guard let itemID = itemIDAtIndex(targetIndex), handoff() else {
            _ = reducer.abandonSettlement(token: token)
            return false
        }
        guard let commit = reducer.completeSettlement(token: token) else { return false }
        activate(commit, itemID)
        return true
    }
}
