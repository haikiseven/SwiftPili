import SwiftUI
import UIKit

struct LiveFeedItemData: Identifiable, Equatable, Sendable {
    let id: Int
    let roomID: Int
    let title: String
    let uname: String
    let areaName: String?
    let coverURL: String
    let displayOnline: String
    let liveStatus: Int?
}

@MainActor
private struct LiveFeedConfiguration {
    let items: [LiveFeedItemData]
    let coverPresentation: CoverPresentation
    let showsSkeletons: Bool
    let skeletonLabel: String
    let canLoadMore: Bool
    let paginationCursor: String
    let onLastAppear: () -> Void
    let onSelectRoom: (Int) -> Void
}

private enum LiveFeedSectionKey: Hashable, Sendable {
    case cards
    case skeletonCards
}

private enum LiveFeedCellKey: Hashable, Sendable {
    case card(Int)
    case skeleton(Int)
}

struct LiveFeedCollectionView: View {
    let items: [LiveFeedItemData]
    var showsSkeletons = false
    var skeletonLabel = ""
    var canLoadMore = false
    var paginationCursor = ""
    var isActive = true
    var isLiveTabSelected = true
    var scrollToTopTick = 0
    var onRefresh: @MainActor () async -> Bool = { false }
    let onLastAppear: () -> Void
    let onSelectRoom: (Int) -> Void

    var body: some View {
        let coverPresentation = CoverPresentationStore.shared.presentation
        let config = LiveFeedConfiguration(
            items: items,
            coverPresentation: coverPresentation,
            showsSkeletons: showsSkeletons,
            skeletonLabel: skeletonLabel,
            canLoadMore: canLoadMore,
            paginationCursor: paginationCursor,
            onLastAppear: onLastAppear,
            onSelectRoom: onSelectRoom
        )
        UIKitCollectionHost(
            isActive: isActive,
            isTabSelected: isLiveTabSelected,
            scrollToTopTick: scrollToTopTick,
            onRefresh: onRefresh,
            makeController: { LiveFeedCollectionViewController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
private final class LiveFeedCollectionViewController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let count: Int
        let lastID: Int?
        let cursor: String
    }

    private var dataSource: UICollectionViewDiffableDataSource<LiveFeedSectionKey, LiveFeedCellKey>?
    private var items: [LiveFeedItemData] = []
    private var itemByID: [Int: LiveFeedItemData] = [:]
    private var itemIndexByID: [Int: Int] = [:]
    private var coverPresentation = CoverPresentation(aspect: .current, display: .current)
    private var showsSkeletons = false
    private var skeletonLabel = ""
    private var canLoadMore = false
    private var paginationCursor = ""
    private var onLastAppear: () -> Void = {}
    private var onSelectRoom: (Int) -> Void = { _ in }
    private var geometryTask: Task<Void, Never>?

    private var liveColumnCount: Int {
        max(1, FeedColumnPolicy.columnCount(.liveGrid, availableWidth: currentContentWidth))
    }

    private var liveColumnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth,
            count: liveColumnCount,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            guard let self else { return nil }
            let effectiveWidth = environment.container.effectiveContentSize.width
            let contentWidth = max(1, effectiveWidth - UIKitFeedLayoutMetrics.horizontalInset * 2)
            return makeGridSection(contentWidth: contentWidth)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot()
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldColumns = max(1, FeedColumnPolicy.columnCount(.liveGrid, availableWidth: oldWidth))
        let widthChanged = abs(newWidth - lastReconfiguredWidth) > 1.5
        guard oldColumns != liveColumnCount || widthChanged else { return }

        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    func update(_ config: LiveFeedConfiguration) {
        onLastAppear = config.onLastAppear
        onSelectRoom = config.onSelectRoom
        canLoadMore = config.canLoadMore

        if config.paginationCursor != paginationCursor {
            paginationCursor = config.paginationCursor
            resetPaginationGate()
        }

        let itemsChanged = config.items != items
        let presentationChanged = config.coverPresentation != coverPresentation
        let skeletonChanged = config.showsSkeletons != showsSkeletons
            || config.skeletonLabel != skeletonLabel

        guard itemsChanged || presentationChanged || skeletonChanged else { return }

        let previousCount = items.count
        let previousByID = itemByID

        items = config.items
        itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        coverPresentation = config.coverPresentation
        showsSkeletons = config.showsSkeletons
        skeletonLabel = config.skeletonLabel

        if items.count != previousCount {
            resetPaginationGate()
        }
        if presentationChanged {
            prefetchCoordinator.cancelAll()
            collectionView.collectionViewLayout.invalidateLayout()
        }

        if isViewLoaded {
            let reconfigureKeys: [LiveFeedCellKey] = if presentationChanged {
                items.map { .card($0.id) }
            } else {
                items.compactMap { item in
                    previousByID[item.id] != item ? .card(item.id) : nil
                }
            }
            applySnapshot(
                reconfigureKeys: reconfigureKeys,
                reconfigureSkeletons: items.isEmpty && (presentationChanged || skeletonChanged)
            )
        }
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        super.tearDown()
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        roomID(at: indexPath) != nil
    }

    override func didSelectItem(at indexPath: IndexPath) {
        guard let roomID = roomID(at: indexPath) else { return }
        onSelectRoom(roomID)
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard isHostActive,
              canLoadMore,
              let roomID = roomID(at: indexPath),
              let index = itemIndexByID[roomID] else {
            return
        }
        let key = PaginationKey(
            count: items.count,
            lastID: items.last?.id,
            cursor: paginationCursor
        )
        triggerNearEndPaginationIfNeeded(
            index: index,
            totalCount: items.count,
            key: key,
            action: onLastAppear
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] indexPath in
            self?.coverRequest(for: indexPath)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }
}

private extension LiveFeedCollectionViewController {
    func configureDataSource() {
        let cardReg = UICollectionView.CellRegistration<UIKitLiveGridCell, UIKitLiveGridCell.Model>(
            handler: { cell, _, model in
                cell.configure(model)
            }
        )
        let skeletonReg = UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>(
            handler: { [weak self] cell, _, index in
                guard let self else { return }
                cell.configure(
                    columnWidth: liveColumnWidth,
                    coverPresentation: coverPresentation,
                    accessibilityLabel: index == 0 && !skeletonLabel.isEmpty ? skeletonLabel : nil
                )
            }
        )

        dataSource = UICollectionViewDiffableDataSource<LiveFeedSectionKey, LiveFeedCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            guard let self else { return nil }
            switch cellKey {
            case .card(let id):
                guard let item = itemByID[id] else { return nil }
                let model = UIKitLiveGridCell.Model(
                    title: item.title,
                    uname: item.uname,
                    areaName: item.areaName,
                    coverURL: item.coverURL,
                    displayOnline: item.displayOnline,
                    liveStatus: item.liveStatus,
                    columnWidth: liveColumnWidth,
                    coverPresentation: coverPresentation
                )
                return collectionView.dequeueConfiguredReusableCell(
                    using: cardReg,
                    for: indexPath,
                    item: model
                )
            case .skeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(
                    using: skeletonReg,
                    for: indexPath,
                    item: index
                )
            }
        }
    }

    func makeGridSection(contentWidth: CGFloat) -> NSCollectionLayoutSection {
        let count = max(1, FeedColumnPolicy.columnCount(.liveGrid, availableWidth: contentWidth))
        let colWidth = FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: count,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
        let estimatedHeight = coverPresentation.height(forWidth: max(1, colWidth)) + 48
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(count)),
            heightDimension: .estimated(max(60, estimatedHeight))
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(max(60, estimatedHeight))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: count
        )
        group.interItemSpacing = .fixed(UIKitFeedLayoutMetrics.gridColumnSpacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = UIKitFeedLayoutMetrics.gridRowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: UIKitFeedLayoutMetrics.topInset,
            leading: UIKitFeedLayoutMetrics.horizontalInset,
            bottom: UIKitFeedLayoutMetrics.bottomInset,
            trailing: UIKitFeedLayoutMetrics.horizontalInset
        )
        return section
    }

    func applySnapshot(
        reconfigureKeys: [LiveFeedCellKey] = [],
        reconfigureAll: Bool = false,
        reconfigureSkeletons: Bool = false
    ) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<LiveFeedSectionKey, LiveFeedCellKey>()

        if items.isEmpty {
            if showsSkeletons {
                let count = max(liveColumnCount * 2, 6)
                snapshot.appendSections([.skeletonCards])
                snapshot.appendItems((0..<count).map { .skeleton($0) }, toSection: .skeletonCards)
                if reconfigureSkeletons || reconfigureAll {
                    snapshot.reconfigureItems(snapshot.itemIdentifiers)
                }
            }
        } else {
            snapshot.appendSections([.cards])
            snapshot.appendItems(items.map { .card($0.id) }, toSection: .cards)
            if reconfigureAll {
                snapshot.reconfigureItems(snapshot.itemIdentifiers)
            } else if !reconfigureKeys.isEmpty {
                let valid = Set(snapshot.itemIdentifiers)
                let targets = reconfigureKeys.filter { valid.contains($0) }
                if !targets.isEmpty {
                    snapshot.reconfigureItems(targets)
                }
            }
        }

        lastReconfiguredWidth = currentContentWidth
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(
                reconfigureAll: !items.isEmpty,
                reconfigureSkeletons: items.isEmpty && showsSkeletons
            )
        }
    }

    func roomID(at indexPath: IndexPath) -> Int? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath),
              case .card(let id) = cellKey else {
            return nil
        }
        return itemByID[id]?.roomID
    }

    func coverRequest(for indexPath: IndexPath) -> UIKitCoverPipeline.CoverRequest? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath),
              case .card(let id) = cellKey,
              let item = itemByID[id] else {
            return nil
        }
        return UIKitCoverPipeline.request(
            sources: .singleUnclassified(item.coverURL),
            drawnBox: coverPresentation.size(width: max(1, liveColumnWidth)),
            presentation: coverPresentation,
            scale: traitCollection.displayScale
        )
    }
}
