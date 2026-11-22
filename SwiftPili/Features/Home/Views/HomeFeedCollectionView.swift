import SwiftUI
import UIKit

/// Pure UIKit `UICollectionView` Home & Ranking feed surface backed by
/// `UIKitCollectionHost`, compositional layout, diffable data source,
/// and `UIKitPrefetchCoordinator`.
struct HomeFeedCollectionView<Item: Identifiable>: View {
    let items: [Item]
    var sections: [VideoFeedSection<Item>]?
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
            sections: convertedSections,
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

@MainActor
final class HomeFeedCollectionViewController: UIKitBaseCollectionViewController {
    struct PaginationTriggerKey: Hashable {
        let count: Int
        let lastID: HomeFeedItemIdentifier?
    }

    var dataSource: UICollectionViewDiffableDataSource<HomeFeedSectionKey, HomeFeedCellKey>?

    var rawSections: [HomeFeedSectionData] = []
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

        let sectionsChanged = config.sections != rawSections
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

        rawSections = config.sections
        layoutMode = config.layoutMode
        coverPresentation = config.coverPresentation
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        heroBadge = config.heroBadge

        if layoutChanged || presentationChanged {
            prefetchCoordinator.cancelAll()
            collectionView.collectionViewLayout.invalidateLayout()
        }

        rebuildIndexCaches()
        if orderedItemIDs.count != previousOrderedCount {
            resetPaginationGate()
        }

        let toReconfigure = changedReconfigureIDs(
            previousItems: previousItems,
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
        layoutChanged: Bool,
        presentationChanged: Bool,
        badgeChanged: Bool
    ) -> Set<HomeFeedItemIdentifier> {
        guard !layoutChanged else { return [] }
        var toReconfigure = Set<HomeFeedItemIdentifier>()
        for id in orderedItemIDs {
            let changed = previousItems[id] != itemByID[id]
            let isHero = id == orderedItemIDs.first
            if changed || presentationChanged || (badgeChanged && isHero) {
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
