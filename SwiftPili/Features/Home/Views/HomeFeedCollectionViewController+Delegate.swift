import UIKit

extension HomeFeedCollectionViewController {
    override func didSelectItem(at indexPath: IndexPath) {
        guard let itemID = itemIdentifier(at: indexPath),
              let target = itemByID[itemID]?.routeTarget else {
            return
        }
        onSelectVideo(target)
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        itemIdentifier(at: indexPath) != nil
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard let itemID = itemIdentifier(at: indexPath),
              let index = itemIndexByID[itemID] else {
            return
        }
        let key = PaginationTriggerKey(count: orderedItemIDs.count, lastID: orderedItemIDs.last)
        triggerNearEndPaginationIfNeeded(
            index: index,
            totalCount: orderedItemIDs.count,
            key: key,
            action: onLastAppear
        )
    }

    private func itemIdentifier(at indexPath: IndexPath) -> HomeFeedItemIdentifier? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        switch cellKey {
        case .hero(let id), .gridCard(let id), .rowCard(let id):
            return id
        case .skeletonHero, .skeletonGrid, .skeletonRow:
            return nil
        }
    }
}

// MARK: - UICollectionViewDataSourcePrefetching

extension HomeFeedCollectionViewController: UICollectionViewDataSourcePrefetching {
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

    private func coverRequest(for indexPath: IndexPath) -> UIKitCoverPipeline.CoverRequest? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        switch cellKey {
        case .hero(let id):
            guard let item = itemByID[id] else { return nil }
            let heroPresentation = CoverPresentation(
                aspect: .sixteenByNine,
                display: coverPresentation.display
            )
            let width = heroUsesWideRow
                ? max(1, (currentContentWidth * HomeHeroLayoutMetrics.heroWideCoverFraction).rounded(.down))
                : max(1, currentContentWidth.rounded())
            return UIKitCoverPipeline.request(
                sources: item.sources,
                drawnBox: heroPresentation.size(width: width),
                presentation: heroPresentation,
                scale: traitCollection.displayScale
            )
        case .gridCard(let id):
            guard let item = itemByID[id] else { return nil }
            return UIKitCoverPipeline.request(
                sources: item.sources,
                drawnBox: coverPresentation.size(width: max(1, activeColumnWidth)),
                presentation: coverPresentation,
                scale: traitCollection.displayScale
            )
        case .rowCard(let id):
            guard let item = itemByID[id] else { return nil }
            let isRegular = traitCollection.horizontalSizeClass == .regular
            let coverWidth = RowCardMetrics.coverWidth(
                columnWidth: activeColumnWidth,
                isRegularWidth: isRegular
            )
            return UIKitCoverPipeline.request(
                sources: item.sources,
                drawnBox: coverPresentation.size(width: max(1, coverWidth)),
                presentation: coverPresentation,
                scale: traitCollection.displayScale
            )
        case .skeletonHero, .skeletonGrid, .skeletonRow:
            return nil
        }
    }
}
