import SwiftUI
import UIKit

struct HomeFeedCollectionView<Item: Identifiable>: View {
    let items: [Item]
    var sections: [VideoFeedSection<Item>]?
    var preconvertedSections: [HomeFeedSectionData]? = nil
    var contentRevision: UInt64? = nil
    let title: (Item) -> String
    let sources: (Item) -> VideoCoverSources
    let duration: (Item) -> Int
    let ownerName: (Item) -> String
    let viewCount: (Item) -> Int
    var rank: (Item) -> Int? = { _ in nil }
    let routeTarget: (Item) -> VideoRouteTarget?
    var fixedLayoutMode: HomeLayoutMode?
    var placeholderCount = 0
    var placeholderLabel = ""
    var heroBadge: String = String(localized: "Recommend")
    var isActive = true
    var isHomeTabSelected = true
    var scrollToTopTick = 0
    var onRefresh: @MainActor () async -> Bool = { false }
    let onLastAppear: () -> Void
    let onSelectVideo: (VideoRouteTarget) -> Void

    @AppStorage(HomeLayoutMode.storageKey) private var layoutRaw = HomeLayoutMode.grid.rawValue

    private var effectiveLayoutMode: HomeLayoutMode {
        fixedLayoutMode ?? (HomeLayoutMode(rawValue: layoutRaw) ?? .grid)
    }

    var body: some View {
        let coverPresentation = CoverPresentationStore.shared.presentation
        let config = HomeFeedConfiguration(
            sections: preconvertedSections ?? convertedSections,
            contentRevision: contentRevision,
            layoutMode: effectiveLayoutMode,
            coverPresentation: coverPresentation,
            placeholderCount: placeholderCount,
            placeholderLabel: placeholderLabel,
            heroBadge: heroBadge,
            isActive: isActive,
            isHomeTabSelected: isHomeTabSelected,
            scrollToTopTick: scrollToTopTick,
            onRefresh: onRefresh,
            onLastAppear: onLastAppear,
            onSelectVideo: onSelectVideo
        )
        UIKitCollectionHost(
            isActive: isActive,
            isTabSelected: isHomeTabSelected,
            scrollToTopTick: scrollToTopTick,
            onRefresh: onRefresh,
            makeController: { HomeFeedCollectionViewController() },
            updateController: { controller in controller.update(config) }
        )
    }

    private var convertedSections: [HomeFeedSectionData] {
        if let sections {
            return sections.compactMap { section in
                let mapped = section.items.map(convertItem)
                guard !mapped.isEmpty else { return nil }
                return HomeFeedSectionData(id: section.id, items: mapped)
            }
        }
        guard !items.isEmpty else { return [] }
        return [HomeFeedSectionData(id: 0, items: items.map(convertItem))]
    }

    private func convertItem(_ item: Item) -> HomeFeedItemData {
        HomeFeedItemData(
            id: HomeFeedItemIdentifier(item.id),
            title: title(item),
            sources: sources(item),
            duration: duration(item),
            ownerName: ownerName(item),
            viewCount: viewCount(item),
            rank: rank(item),
            routeTarget: routeTarget(item)
        )
    }
}

extension HomeFeedCollectionView where Item == HomeFeedItemData {
    init(
        preconvertedSections: [HomeFeedSectionData],
        contentRevision: UInt64,
        fixedLayoutMode: HomeLayoutMode? = nil,
        placeholderCount: Int = 0,
        placeholderLabel: String = "",
        heroBadge: String = String(localized: "Recommend"),
        isActive: Bool = true,
        isHomeTabSelected: Bool = true,
        scrollToTopTick: Int = 0,
        onRefresh: @escaping @MainActor () async -> Bool = { false },
        onLastAppear: @escaping () -> Void,
        onSelectVideo: @escaping (VideoRouteTarget) -> Void
    ) {
        items = []
        sections = nil
        self.preconvertedSections = preconvertedSections
        self.contentRevision = contentRevision
        title = \.title
        sources = \.sources
        duration = \.duration
        ownerName = \.ownerName
        viewCount = \.viewCount
        rank = \.rank
        routeTarget = \.routeTarget
        self.fixedLayoutMode = fixedLayoutMode
        self.placeholderCount = placeholderCount
        self.placeholderLabel = placeholderLabel
        self.heroBadge = heroBadge
        self.isActive = isActive
        self.isHomeTabSelected = isHomeTabSelected
        self.scrollToTopTick = scrollToTopTick
        self.onRefresh = onRefresh
        self.onLastAppear = onLastAppear
        self.onSelectVideo = onSelectVideo
    }
}

@MainActor
final class HomeFeedCollectionViewController: UIKitBaseCollectionViewController {
    struct PaginationTriggerKey: Hashable {
        let count: Int
        let lastID: HomeFeedItemIdentifier?
    }

    var dataSource: UICollectionViewDiffableDataSource<HomeFeedSectionKey, HomeFeedCellKey>?
    var currentSections: [HomeFeedSectionKey] = []

    var rawSections: [HomeFeedSectionData] = []
    private var lastContentRevision: UInt64?
    var balancedSections: [HomeFeedSectionData] = []
    var itemByID: [HomeFeedItemIdentifier: HomeFeedItemData] = [:]
    var itemIndexByID: [HomeFeedItemIdentifier: Int] = [:]
    var orderedItemIDs: [HomeFeedItemIdentifier] = []

    var layoutMode: HomeLayoutMode = .grid
    var coverPresentation = CoverPresentation(aspect: .current, display: .current)
    var placeholderCount = 0
    var placeholderLabel = ""
    var heroBadge = String(localized: "Recommend")

    var onLastAppear: () -> Void = {}
    var onSelectVideo: (VideoRouteTarget) -> Void = { _ in }

    private var geometryTask: Task<Void, Never>?

    var activeColumnCount: Int {
        FeedColumnPolicy.columnCount(
            layoutMode == .grid ? .videoGrid : .videoRow,
            availableWidth: currentContentWidth
        )
    }

    var activeColumnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth,
            count: activeColumnCount,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    var heroUsesWideRow: Bool {
        FeedColumnPolicy.columnCount(.videoGrid, availableWidth: currentContentWidth) >= 3
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        makeHomeLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot(reconfigureItemIDs: [])
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldColumns = FeedColumnPolicy.columnCount(
            layoutMode == .grid ? .videoGrid : .videoRow,
            availableWidth: oldWidth
        )
        let oldHeroWide = FeedColumnPolicy.columnCount(.videoGrid, availableWidth: oldWidth) >= 3
        let columnsChanged = oldColumns != activeColumnCount
        let heroChanged = oldHeroWide != heroUsesWideRow
        let widthChanged = abs(newWidth - lastReconfiguredWidth) > 1.5
        guard columnsChanged || heroChanged || widthChanged else { return }

        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    func update(_ config: HomeFeedConfiguration) {
        onLastAppear = config.onLastAppear
        onSelectVideo = config.onSelectVideo

        let sectionsChanged: Bool
        if let incomingRev = config.contentRevision, let currentRev = lastContentRevision,
           incomingRev == currentRev {
            sectionsChanged = false
        } else {
            sectionsChanged = config.sections != rawSections
        }
        let layoutChanged = config.layoutMode != layoutMode
        let presentationChanged = config.coverPresentation != coverPresentation
        let placeholderChanged = config.placeholderCount != placeholderCount
            || config.placeholderLabel != placeholderLabel
        let badgeChanged = config.heroBadge != heroBadge

        guard sectionsChanged || layoutChanged || presentationChanged
            || placeholderChanged || badgeChanged else {
            return
        }

        let previousItems = itemByID
        let previousOrderedCount = orderedItemIDs.count

        if sectionsChanged {
            rawSections = config.sections
        }
        lastContentRevision = config.contentRevision
        layoutMode = config.layoutMode
        coverPresentation = config.coverPresentation
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        heroBadge = config.heroBadge

        if layoutChanged || presentationChanged {
            prefetchCoordinator.cancelAll()
            collectionView.collectionViewLayout.invalidateLayout()
        }

        if sectionsChanged || layoutChanged {
            rebuildIndexCaches()
        }
        if orderedItemIDs.count != previousOrderedCount {
            resetPaginationGate()
        }

        let toReconfigure = changedReconfigureIDs(
            previousItems: previousItems,
            sectionsChanged: sectionsChanged,
            layoutChanged: layoutChanged,
            presentationChanged: presentationChanged,
            badgeChanged: badgeChanged
        )

        if isViewLoaded {
            applySnapshot(
                reconfigureItemIDs: toReconfigure,
                reconfigureSkeletons: orderedItemIDs.isEmpty && (presentationChanged || placeholderChanged)
            )
        }
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        super.tearDown()
    }

    private func changedReconfigureIDs(
        previousItems: [HomeFeedItemIdentifier: HomeFeedItemData],
        sectionsChanged: Bool,
        layoutChanged: Bool,
        presentationChanged: Bool,
        badgeChanged: Bool
    ) -> Set<HomeFeedItemIdentifier> {
        guard !layoutChanged else { return [] }
        if presentationChanged {
            return Set(orderedItemIDs)
        }
        if !sectionsChanged {
            if badgeChanged, let first = orderedItemIDs.first {
                return [first]
            }
            return []
        }
        var toReconfigure = Set<HomeFeedItemIdentifier>()
        for id in orderedItemIDs {
            let changed = previousItems[id] != itemByID[id]
            let isHero = id == orderedItemIDs.first
            if changed || (badgeChanged && isHero) {
                toReconfigure.insert(id)
            }
        }
        return toReconfigure
    }

    private func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            rebuildIndexCaches()
            applySnapshot(
                reconfigureItemIDs: Set(orderedItemIDs),
                reconfigureSkeletons: orderedItemIDs.isEmpty && placeholderCount > 0
            )
        }
    }
}
