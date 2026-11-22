import UIKit

extension HomeFeedCollectionViewController {
    private struct CellRegistrations {
        let hero: UICollectionView.CellRegistration<HomeHeroFeedCell, HomeFeedItemData>
        let grid: UICollectionView.CellRegistration<UIKitGridVideoCell, HomeFeedItemData>
        let row: UICollectionView.CellRegistration<UIKitRowVideoCell, HomeFeedItemData>
        let skeletonHero: UICollectionView.CellRegistration<UIKitHeroSkeletonCell, Int>
        let skeletonGrid: UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>
        let skeletonRow: UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int>
    }

    func configureDataSource() {
        let registrations = makeCellRegistrations()
        let headerReg = UICollectionView.SupplementaryRegistration<UIKitFeedSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, _ in
            view.configure(title: String(localized: "Previously loaded recommendations"))
        }

        let source = UICollectionViewDiffableDataSource<HomeFeedSectionKey, HomeFeedCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            self?.dequeueCell(
                in: collectionView,
                at: indexPath,
                for: cellKey,
                registrations: registrations
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

    private func makeCellRegistrations() -> CellRegistrations {
        let heroReg = UICollectionView.CellRegistration<HomeHeroFeedCell, HomeFeedItemData>(
            handler: { [weak self] cell, _, item in
                guard let self else { return }
                cell.configure(
                    item: item,
                    badgeText: heroBadge,
                    isWide: heroUsesWideRow,
                    containerWidth: currentContentWidth,
                    coverPresentation: coverPresentation
                )
            }
        )
        let gridReg = UICollectionView.CellRegistration<UIKitGridVideoCell, HomeFeedItemData>(
            handler: { [weak self] cell, _, item in
                guard let self else { return }
                cell.configure(UIKitGridVideoCell.Model(
                    title: item.title,
                    sources: item.sources,
                    duration: item.duration,
                    ownerName: item.ownerName,
                    viewCount: item.viewCount,
                    columnWidth: activeColumnWidth,
                    coverPresentation: coverPresentation
                ))
            }
        )
        let rowReg = UICollectionView.CellRegistration<UIKitRowVideoCell, HomeFeedItemData>(
            handler: { [weak self] cell, _, item in
                guard let self else { return }
                cell.configure(UIKitRowVideoCell.Model(
                    style: .feed,
                    title: item.title,
                    sources: item.sources,
                    duration: item.duration,
                    subtitle: .metaLine(ownerName: item.ownerName, viewCount: item.viewCount),
                    rank: item.rank,
                    columnWidth: activeColumnWidth,
                    coverPresentation: coverPresentation
                ))
            }
        )
        let skeletons = makeSkeletonRegistrations()
        return CellRegistrations(
            hero: heroReg,
            grid: gridReg,
            row: rowReg,
            skeletonHero: skeletons.hero,
            skeletonGrid: skeletons.grid,
            skeletonRow: skeletons.row
        )
    }

    private struct SkeletonRegistrations {
        let hero: UICollectionView.CellRegistration<UIKitHeroSkeletonCell, Int>
        let grid: UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>
        let row: UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int>
    }

    private func makeSkeletonRegistrations() -> SkeletonRegistrations {
        let skHeroReg = UICollectionView.CellRegistration<UIKitHeroSkeletonCell, Int>(
            handler: { [weak self] cell, _, _ in
                guard let self else { return }
                cell.configure(
                    containerWidth: currentContentWidth,
                    wideCoverFraction: HomeHeroLayoutMetrics.heroWideCoverFraction,
                    isWide: heroUsesWideRow
                )
            }
        )
        let skGridReg = UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>(
            handler: { [weak self] cell, _, index in
                guard let self else { return }
                cell.configure(
                    columnWidth: activeColumnWidth,
                    coverPresentation: coverPresentation,
                    accessibilityLabel: index == 0 && !placeholderLabel.isEmpty ? placeholderLabel : nil
                )
            }
        )
        let skRowReg = UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int>(
            handler: { [weak self] cell, _, index in
                guard let self else { return }
                cell.configure(
                    style: .feed,
                    columnWidth: activeColumnWidth,
                    coverPresentation: coverPresentation,
                    accessibilityLabel: index == 0 && !placeholderLabel.isEmpty ? placeholderLabel : nil
                )
            }
        )
        return SkeletonRegistrations(hero: skHeroReg, grid: skGridReg, row: skRowReg)
    }

    private func dequeueCell(
        in collectionView: UICollectionView,
        at indexPath: IndexPath,
        for cellKey: HomeFeedCellKey,
        registrations: CellRegistrations
    ) -> UICollectionViewCell? {
        switch cellKey {
        case .hero(let id):
            guard let item = itemByID[id] else { return nil }
            return collectionView.dequeueConfiguredReusableCell(
                using: registrations.hero,
                for: indexPath,
                item: item
            )
        case .gridCard(let id):
            guard let item = itemByID[id] else { return nil }
            return collectionView.dequeueConfiguredReusableCell(
                using: registrations.grid,
                for: indexPath,
                item: item
            )
        case .rowCard(let id):
            guard let item = itemByID[id] else { return nil }
            return collectionView.dequeueConfiguredReusableCell(
                using: registrations.row,
                for: indexPath,
                item: item
            )
        case .skeletonHero:
            return collectionView.dequeueConfiguredReusableCell(
                using: registrations.skeletonHero,
                for: indexPath,
                item: 0
            )
        case .skeletonGrid(let index):
            return collectionView.dequeueConfiguredReusableCell(
                using: registrations.skeletonGrid,
                for: indexPath,
                item: index
            )
        case .skeletonRow(let index):
            return collectionView.dequeueConfiguredReusableCell(
                using: registrations.skeletonRow,
                for: indexPath,
                item: index
            )
        }
    }

    func makeHomeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            let sectionKey = sections[sectionIndex]
            let isLast = sectionIndex == sections.count - 1
            let effectiveWidth = environment.container.effectiveContentSize.width
            let contentWidth = max(1, effectiveWidth - UIKitFeedLayoutMetrics.horizontalInset * 2)

            switch sectionKey {
            case .hero, .skeletonHero:
                return makeHeroLayoutSection(contentWidth: contentWidth)
            case .feed(let generationID):
                let showsHeader = generationID != balancedSections.first?.id
                return makeCardsLayoutSection(
                    contentWidth: contentWidth,
                    traitCollection: environment.traitCollection,
                    showsHeader: showsHeader,
                    isLast: isLast
                )
            case .skeletonCards:
                return makeCardsLayoutSection(
                    contentWidth: contentWidth,
                    traitCollection: environment.traitCollection,
                    showsHeader: false,
                    isLast: true
                )
            }
        }
    }

    private func makeHeroLayoutSection(contentWidth: CGFloat) -> NSCollectionLayoutSection {
        let isWide = FeedColumnPolicy.columnCount(.videoGrid, availableWidth: contentWidth) >= 3
        let coverFraction = isWide ? HomeHeroLayoutMetrics.heroWideCoverFraction : 1.0
        let estimatedHeight = max(160, (contentWidth * coverFraction * 9 / 16).rounded())
        let size = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(estimatedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: UIKitFeedLayoutMetrics.topInset,
            leading: UIKitFeedLayoutMetrics.horizontalInset,
            bottom: HomeHeroLayoutMetrics.heroToFeedSpacing,
            trailing: UIKitFeedLayoutMetrics.horizontalInset
        )
        return section
    }

    private func makeCardsLayoutSection(
        contentWidth: CGFloat,
        traitCollection: UITraitCollection,
        showsHeader: Bool,
        isLast: Bool
    ) -> NSCollectionLayoutSection {
        let surface: FeedColumnPolicy.Surface = layoutMode == .grid ? .videoGrid : .videoRow
        let count = max(1, FeedColumnPolicy.columnCount(surface, availableWidth: contentWidth))
        let colWidth = FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: count,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
        let isRegular = traitCollection.horizontalSizeClass == .regular
        let estimatedHeight: CGFloat = if layoutMode == .grid {
            coverPresentation.height(forWidth: max(1, colWidth)) + 68
        } else {
            coverPresentation.height(
                forWidth: RowCardMetrics.coverWidth(columnWidth: colWidth, isRegularWidth: isRegular)
            )
        }

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
        section.interGroupSpacing = layoutMode == .grid
            ? UIKitFeedLayoutMetrics.gridRowSpacing
            : UIKitFeedLayoutMetrics.listRowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: UIKitFeedLayoutMetrics.horizontalInset,
            bottom: isLast ? UIKitFeedLayoutMetrics.bottomInset : UIKitFeedLayoutMetrics.gridRowSpacing,
            trailing: UIKitFeedLayoutMetrics.horizontalInset
        )

        if showsHeader {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(40)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]
        }
        return section
    }

    func rebuildIndexCaches() {
        balancedSections = VideoFeedSection.balanced(
            rawSections,
            columnCount: activeColumnCount
        )
        var map: [HomeFeedItemIdentifier: HomeFeedItemData] = [:]
        var ordered: [HomeFeedItemIdentifier] = []
        var indices: [HomeFeedItemIdentifier: Int] = [:]
        for section in balancedSections {
            for item in section.items {
                map[item.id] = item
                indices[item.id] = ordered.count
                ordered.append(item.id)
            }
        }
        itemByID = map
        orderedItemIDs = ordered
        itemIndexByID = indices
    }

    func applySnapshot(
        reconfigureItemIDs: Set<HomeFeedItemIdentifier>,
        reconfigureSkeletons: Bool = false
    ) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<HomeFeedSectionKey, HomeFeedCellKey>()

        if orderedItemIDs.isEmpty {
            if placeholderCount > 0 {
                snapshot.appendSections([.skeletonHero, .skeletonCards])
                snapshot.appendItems([.skeletonHero], toSection: .skeletonHero)
                let count = min(placeholderCount, 6)
                let cardKeys: [HomeFeedCellKey] = (0..<count).map { index in
                    layoutMode == .grid ? .skeletonGrid(index) : .skeletonRow(index)
                }
                snapshot.appendItems(cardKeys, toSection: .skeletonCards)
                if reconfigureSkeletons {
                    snapshot.reconfigureItems(snapshot.itemIdentifiers)
                }
            }
            lastReconfiguredWidth = currentContentWidth
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        if let leadID = orderedItemIDs.first {
            snapshot.appendSections([.hero])
            snapshot.appendItems([.hero(leadID)], toSection: .hero)
        }

        let firstSectionID = balancedSections.first?.id
        for section in balancedSections {
            let slice = section.id == firstSectionID
                ? Array(section.items.dropFirst())
                : section.items
            guard !slice.isEmpty else { continue }
            let sectionKey = HomeFeedSectionKey.feed(section.id)
            snapshot.appendSections([sectionKey])
            let cellKeys: [HomeFeedCellKey] = slice.map { item in
                layoutMode == .grid ? .gridCard(item.id) : .rowCard(item.id)
            }
            snapshot.appendItems(cellKeys, toSection: sectionKey)
        }

        reconfigureItems(reconfigureItemIDs, in: &snapshot)
        lastReconfiguredWidth = currentContentWidth
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureItems(
        _ ids: Set<HomeFeedItemIdentifier>,
        in snapshot: inout NSDiffableDataSourceSnapshot<HomeFeedSectionKey, HomeFeedCellKey>
    ) {
        guard !ids.isEmpty else { return }
        let validKeys = Set(snapshot.itemIdentifiers)
        let targets = ids.compactMap { id -> HomeFeedCellKey? in
            if id == orderedItemIDs.first {
                let heroKey = HomeFeedCellKey.hero(id)
                return validKeys.contains(heroKey) ? heroKey : nil
            }
            let cardKey: HomeFeedCellKey = layoutMode == .grid ? .gridCard(id) : .rowCard(id)
            return validKeys.contains(cardKey) ? cardKey : nil
        }
        if !targets.isEmpty {
            snapshot.reconfigureItems(targets)
        }
    }
}
