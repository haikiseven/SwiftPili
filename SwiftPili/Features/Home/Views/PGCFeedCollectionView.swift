import SwiftUI
import UIKit

/// Snapshot-ready value model for a followed anime/show tile in the PGC horizontal rail.
struct PGCFollowedPosterData: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let cover: String
    let meta: String
}

/// Snapshot-ready value model for a 3:4 PGC index poster card.
struct PGCPosterItemData: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let cover: String
    let badge: String?
    let meta: String?
}

@MainActor
private struct PGCFeedConfiguration {
    let followedTitle: String
    let followedItems: [PGCFollowedPosterData]
    let items: [PGCPosterItemData]
    let placeholderCount: Int
    let placeholderLabel: String
    let onLastAppear: () -> Void
    let onSelectBangumi: (Int) -> Void
}

private enum PGCSectionKey: Hashable, Sendable {
    case followedRail
    case posters
    case skeletonPosters
}

private enum PGCCellKey: Hashable, Sendable {
    case followed(Int)
    case poster(Int)
    case skeleton(Int)
}

/// Pure UIKit `UICollectionView` PGC feed combining an optional horizontal
/// orthogonal `FollowedBangumiRail` section and a `3:4` `UIKitPosterCardCell` grid.
struct PGCFeedCollectionView: View {
    let followedTitle: String
    let followedItems: [PGCFollowedPosterData]
    let items: [PGCPosterItemData]
    var placeholderCount = 0
    var placeholderLabel = ""
    var isActive = true
    var isHomeTabSelected = true
    var scrollToTopTick = 0
    var onRefresh: @MainActor () async -> Bool = { false }
    let onLastAppear: () -> Void
    let onSelectBangumi: (Int) -> Void

    var body: some View {
        let config = PGCFeedConfiguration(
            followedTitle: followedTitle,
            followedItems: followedItems,
            items: items,
            placeholderCount: placeholderCount,
            placeholderLabel: placeholderLabel,
            onLastAppear: onLastAppear,
            onSelectBangumi: onSelectBangumi
        )
        UIKitCollectionHost(
            isActive: isActive,
            isTabSelected: isHomeTabSelected,
            scrollToTopTick: scrollToTopTick,
            onRefresh: onRefresh,
            makeController: { PGCFeedCollectionViewController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
private final class PGCFeedCollectionViewController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let count: Int
        let lastID: Int?
    }

    private var dataSource: UICollectionViewDiffableDataSource<PGCSectionKey, PGCCellKey>?
    private var followedTitle = ""
    private var followedItems: [PGCFollowedPosterData] = []
    private var followedByID: [Int: PGCFollowedPosterData] = [:]
    private var items: [PGCPosterItemData] = []
    private var itemByID: [Int: PGCPosterItemData] = [:]
    private var itemIndexByID: [Int: Int] = [:]
    private var placeholderCount = 0
    private var placeholderLabel = ""
    private var onLastAppear: () -> Void = {}
    private var onSelectBangumi: (Int) -> Void = { _ in }
    private var geometryTask: Task<Void, Never>?

    private var railCardWidth: CGFloat {
        PGCFollowedRailPolicy.cardWidth(availableWidth: currentContentWidth)
    }

    private var posterColumnCount: Int {
        FeedColumnPolicy.pgcPosterColumnCount(availableWidth: currentContentWidth)
    }

    private var posterColumnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth,
            count: posterColumnCount,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            let effectiveWidth = environment.container.effectiveContentSize.width
            let contentWidth = max(1, effectiveWidth - UIKitFeedLayoutMetrics.horizontalInset * 2)

            switch sections[sectionIndex] {
            case .followedRail:
                return makeFollowedRailSection(contentWidth: contentWidth)
            case .posters, .skeletonPosters:
                return makePosterGridSection(contentWidth: contentWidth)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot(reconfigureAll: false)
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldRailWidth = PGCFollowedRailPolicy.cardWidth(availableWidth: oldWidth)
        let oldCols = FeedColumnPolicy.pgcPosterColumnCount(availableWidth: oldWidth)
        let widthChanged = abs(newWidth - lastReconfiguredWidth) > 1.5
        guard oldRailWidth != railCardWidth || oldCols != posterColumnCount || widthChanged else { return }

        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    func update(_ config: PGCFeedConfiguration) {
        onLastAppear = config.onLastAppear
        onSelectBangumi = config.onSelectBangumi

        let followedChanged = config.followedItems != followedItems || config.followedTitle != followedTitle
        let itemsChanged = config.items != items
        let placeholderChanged = config.placeholderCount != placeholderCount
            || config.placeholderLabel != placeholderLabel

        guard followedChanged || itemsChanged || placeholderChanged else { return }

        let previousCount = items.count
        let previousFollowed = followedByID
        let previousItems = itemByID

        followedTitle = config.followedTitle
        followedItems = config.followedItems
        followedByID = Dictionary(uniqueKeysWithValues: followedItems.map { ($0.id, $0) })

        items = config.items
        itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })

        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel

        if items.count != previousCount {
            resetPaginationGate()
        }

        if isViewLoaded {
            var reconfigure: [PGCCellKey] = []
            for item in followedItems where previousFollowed[item.id] != item {
                reconfigure.append(.followed(item.id))
            }
            for item in items where previousItems[item.id] != item {
                reconfigure.append(.poster(item.id))
            }
            applySnapshot(reconfigureKeys: reconfigure)
        }
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        super.tearDown()
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        bangumiID(at: indexPath) != nil
    }

    override func didSelectItem(at indexPath: IndexPath) {
        guard let seasonID = bangumiID(at: indexPath) else { return }
        onSelectBangumi(seasonID)
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath),
              case .poster(let seasonID) = cellKey,
              let index = itemIndexByID[seasonID] else { return }
        let key = PaginationKey(count: items.count, lastID: items.last?.id)
        triggerNearEndPaginationIfNeeded(
            index: index,
            totalCount: items.count,
            key: key,
            action: onLastAppear
        )
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
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

private extension PGCFeedCollectionViewController {
    func configureDataSource() {
        let posterReg = UICollectionView.CellRegistration<UIKitPosterCardCell, UIKitPosterCardCell.Model>(
            handler: { cell, _, model in
                cell.configure(model)
            }
        )
        let skeletonReg = UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>(
            handler: { [weak self] cell, _, index in
                guard let self else { return }
                cell.configurePoster(
                    columnWidth: posterColumnWidth,
                    accessibilityLabel: index == 0 && !placeholderLabel.isEmpty ? placeholderLabel : nil
                )
            }
        )
        let headerReg = UICollectionView.SupplementaryRegistration<UIKitFeedSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            guard let self else { return }
            view.configure(
                title: followedTitle,
                showsDivider: false,
                textStyle: .headline,
                weight: .semibold,
                color: .label
            )
        }

        let source = UICollectionViewDiffableDataSource<PGCSectionKey, PGCCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            self?.dequeueCell(
                in: collectionView,
                at: indexPath,
                for: cellKey,
                posterReg: posterReg,
                skeletonReg: skeletonReg
            )
        }
        source.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerReg,
                for: indexPath
            )
        }
        dataSource = source
    }

    func dequeueCell(
        in collectionView: UICollectionView,
        at indexPath: IndexPath,
        for cellKey: PGCCellKey,
        posterReg: UICollectionView.CellRegistration<UIKitPosterCardCell, UIKitPosterCardCell.Model>,
        skeletonReg: UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>
    ) -> UICollectionViewCell? {
        switch cellKey {
        case .followed(let id):
            guard let item = followedByID[id] else { return nil }
            let model = UIKitPosterCardCell.Model(
                title: item.title,
                meta: item.meta,
                coverURL: item.cover,
                badge: nil,
                cardWidth: railCardWidth,
                displayMode: .entire,
                requestsServerCrop: false,
                titleRole: .shelfCardTitle
            )
            return collectionView.dequeueConfiguredReusableCell(using: posterReg, for: indexPath, item: model)
        case .poster(let id):
            guard let item = itemByID[id] else { return nil }
            let model = UIKitPosterCardCell.Model(
                title: item.title,
                meta: item.meta,
                coverURL: item.cover,
                badge: item.badge,
                cardWidth: posterColumnWidth,
                displayMode: .fill,
                requestsServerCrop: true,
                titleRole: .cardTitle
            )
            return collectionView.dequeueConfiguredReusableCell(using: posterReg, for: indexPath, item: model)
        case .skeleton(let index):
            return collectionView.dequeueConfiguredReusableCell(using: skeletonReg, for: indexPath, item: index)
        }
    }

    func makeFollowedRailSection(contentWidth: CGFloat) -> NSCollectionLayoutSection {
        let cardWidth = PGCFollowedRailPolicy.cardWidth(availableWidth: contentWidth)
        let estimatedHeight = (cardWidth * 4 / 3).rounded() + 56
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(cardWidth),
            heightDimension: .estimated(estimatedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(cardWidth),
            heightDimension: .estimated(estimatedHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = UIKitFeedLayoutMetrics.gridColumnSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 2,
            leading: UIKitFeedLayoutMetrics.horizontalInset,
            bottom: 4,
            trailing: UIKitFeedLayoutMetrics.horizontalInset
        )

        let headerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(38)
        )
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
        section.boundarySupplementaryItems = [header]
        return section
    }

    func makePosterGridSection(contentWidth: CGFloat) -> NSCollectionLayoutSection {
        let count = max(1, FeedColumnPolicy.pgcPosterColumnCount(availableWidth: contentWidth))
        let colWidth = FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: count,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
        let estimatedHeight = (colWidth * 4 / 3).rounded() + 58
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(count)),
            heightDimension: .estimated(max(80, estimatedHeight))
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(max(80, estimatedHeight))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: count
        )
        group.interItemSpacing = .fixed(UIKitFeedLayoutMetrics.gridColumnSpacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 16
        section.contentInsets = NSDirectionalEdgeInsets(
            top: UIKitFeedLayoutMetrics.horizontalInset,
            leading: UIKitFeedLayoutMetrics.horizontalInset,
            bottom: UIKitFeedLayoutMetrics.horizontalInset,
            trailing: UIKitFeedLayoutMetrics.horizontalInset
        )
        return section
    }

    func applySnapshot(reconfigureKeys: [PGCCellKey] = [], reconfigureAll: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<PGCSectionKey, PGCCellKey>()

        if !followedItems.isEmpty {
            snapshot.appendSections([.followedRail])
            snapshot.appendItems(followedItems.map { .followed($0.id) }, toSection: .followedRail)
        }

        if items.isEmpty {
            if placeholderCount > 0 {
                let count = max(posterColumnCount * 2, placeholderCount)
                snapshot.appendSections([.skeletonPosters])
                snapshot.appendItems((0..<count).map { .skeleton($0) }, toSection: .skeletonPosters)
            }
        } else {
            snapshot.appendSections([.posters])
            snapshot.appendItems(items.map { .poster($0.id) }, toSection: .posters)
        }

        if reconfigureAll {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        } else if !reconfigureKeys.isEmpty {
            let valid = Set(snapshot.itemIdentifiers)
            let targets = reconfigureKeys.filter { valid.contains($0) }
            if !targets.isEmpty { snapshot.reconfigureItems(targets) }
        }

        lastReconfiguredWidth = currentContentWidth
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(reconfigureAll: true)
        }
    }

    func bangumiID(at indexPath: IndexPath) -> Int? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        switch cellKey {
        case .followed(let id), .poster(let id): return id
        case .skeleton: return nil
        }
    }

    func coverRequest(for indexPath: IndexPath) -> UIKitCoverPipeline.CoverRequest? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        switch cellKey {
        case .followed(let id):
            guard let item = followedByID[id] else { return nil }
            let width = max(1, railCardWidth)
            return UIKitCoverPipeline.request(
                urlString: item.cover,
                drawnBox: CGSize(width: width, height: (width * 4 / 3).rounded()),
                displayMode: .entire,
                requestsServerCrop: false,
                scale: traitCollection.displayScale
            )
        case .poster(let id):
            guard let item = itemByID[id] else { return nil }
            let width = max(1, posterColumnWidth)
            return UIKitCoverPipeline.request(
                urlString: item.cover,
                drawnBox: CGSize(width: width, height: (width * 4 / 3).rounded()),
                displayMode: .fill,
                requestsServerCrop: true,
                scale: traitCollection.displayScale
            )
        case .skeleton:
            return nil
        }
    }
}
