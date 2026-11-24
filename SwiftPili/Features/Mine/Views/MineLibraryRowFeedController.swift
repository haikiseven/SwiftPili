import UIKit

private enum MineRowSectionKey: Hashable, Sendable {
    case items
    case skeletons
}

private enum MineRowCellKey: Hashable, Sendable {
    case item(MineRowID)
    case skeleton(Int)
}

private struct MineRowRegistrations {
    let row: UICollectionView.CellRegistration<UIKitRowVideoCell, MineLibraryRowItem>
    let skeleton: UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int>
    let header: UICollectionView.SupplementaryRegistration<UIKitFeedSectionHeaderView>
    let footer: UICollectionView.SupplementaryRegistration<MineFeedFooterView>
}

@MainActor
final class MineLibraryRowFeedController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let count: Int
        let lastID: MineRowID?
    }

    private var dataSource: UICollectionViewDiffableDataSource<MineRowSectionKey, MineRowCellKey>?
    private var currentSections: [MineRowSectionKey] = []
    private var items: [MineLibraryRowItem] = []
    private var itemByID: [MineRowID: MineLibraryRowItem] = [:]
    private var itemIndexByID: [MineRowID: Int] = [:]
    private var headerTitle: String?
    private var placeholderCount = 0
    private var placeholderLabel = ""
    private var footerState: MineFeedFooterState = .none
    private var coverPresentation = CoverPresentationStore.shared.presentation

    private var onNearEndAppear: (() -> Void)?
    private var onFooterAction: (() -> Void)?
    private var onSelectItem: (MineRowID) -> Void = { _ in }
    private var makeTrailingMenu: ((MineRowID, UIView?) -> UIMenu?)?
    private var makeContextMenu: ((MineRowID) -> UIMenu?)?
    private var geometryTask: Task<Void, Never>?

    override var layoutHorizontalInset: CGFloat {
        let width = isViewLoaded && collectionView.bounds.width > 1
            ? collectionView.bounds.width
            : FeedWidth.fullContainerSeed
        return FeedColumnPolicy.horizontalMargin(for: width)
    }

    private var activeColumnCount: Int {
        max(1, FeedColumnPolicy.columnCount(.videoRow, availableWidth: currentContentWidth))
    }

    private var activeColumnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth,
            count: activeColumnCount,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self, sectionIndex < currentSections.count else { return nil }
            let effectiveWidth = environment.container.effectiveContentSize.width
            let margin = FeedColumnPolicy.horizontalMargin(for: effectiveWidth)
            let contentWidth = max(1, effectiveWidth - margin * 2)
            return makeRowSection(
                contentWidth: contentWidth,
                horizontalInset: margin,
                traitCollection: environment.traitCollection,
                isSkeleton: currentSections[sectionIndex] == .skeletons
            )
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot(reconfigureAll: false)
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldCols = FeedColumnPolicy.columnCount(.videoRow, availableWidth: oldWidth)
        let widthChanged = abs(newWidth - lastReconfiguredWidth) > 1.5
        guard oldCols != activeColumnCount || widthChanged else { return }

        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        super.tearDown()
    }

    func update(_ config: MineLibraryRowFeedConfig) {
        onNearEndAppear = config.onNearEndAppear
        onFooterAction = config.onFooterAction
        onSelectItem = config.onSelectItem
        makeTrailingMenu = config.makeTrailingMenu
        makeContextMenu = config.makeContextMenu

        let itemsChanged = config.items != items
        let headerChanged = config.headerTitle != headerTitle
        let placeholderChanged = config.placeholderCount != placeholderCount
            || config.placeholderLabel != placeholderLabel
        let footerChanged = config.footerState != footerState
        let presentationChanged = config.coverPresentation != coverPresentation

        guard itemsChanged || headerChanged || placeholderChanged || footerChanged || presentationChanged else {
            return
        }

        let previousCount = items.count
        let previousByID = itemByID
        let hadHeader = headerTitle != nil && !items.isEmpty
        let hadFooter = footerState != .none && !items.isEmpty

        items = config.items
        itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        headerTitle = config.headerTitle
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        footerState = config.footerState
        coverPresentation = config.coverPresentation

        if items.count != previousCount {
            resetPaginationGate()
        }

        let hasHeader = headerTitle != nil && !items.isEmpty
        let hasFooter = footerState != .none && !items.isEmpty
        let boundaryChanged = hadHeader != hasHeader || hadFooter != hasFooter

        if isViewLoaded {
            var reconfigureIDs: [MineRowCellKey] = []
            if !presentationChanged {
                for item in items where previousByID[item.id] != item {
                    reconfigureIDs.append(.item(item.id))
                }
            }
            applySnapshot(reconfigureKeys: reconfigureIDs, reconfigureAll: presentationChanged)
            if boundaryChanged || presentationChanged {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            if headerChanged, hasHeader {
                updateVisibleHeader()
            }
            if footerChanged, hasFooter {
                updateVisibleFooter()
            }
        }
    }

    // MARK: - Selection, Highlight & Context Menu

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        guard let item = rowItem(at: indexPath) else { return false }
        return item.isSelectable
    }

    override func didSelectItem(at indexPath: IndexPath) {
        guard let item = rowItem(at: indexPath), item.isSelectable else { return }
        onSelectItem(item.id)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        shouldSelectItem(at: indexPath)
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard let onNearEndAppear,
              let item = rowItem(at: indexPath),
              let index = itemIndexByID[item.id] else {
            return
        }
        let key = PaginationKey(count: items.count, lastID: items.last?.id)
        triggerNearEndPaginationIfNeeded(
            index: index,
            totalCount: items.count,
            key: key,
            action: onNearEndAppear
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let makeContextMenu,
              let item = rowItem(at: indexPath),
              let menu = makeContextMenu(item.id) else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            menu
        }
    }

    // MARK: - UICollectionViewDataSourcePrefetching

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

private extension MineLibraryRowFeedController {
    func makeRegistrations() -> MineRowRegistrations {
        let row = UICollectionView.CellRegistration<
            UIKitRowVideoCell,
            MineLibraryRowItem
        > { [weak self] cell, _, item in
            guard let self else { return }
            let menu = item.hasTrailingMenu ? makeTrailingMenu?(item.id, cell) : nil
            cell.configure(UIKitRowVideoCell.Model(
                style: .library,
                title: item.title,
                sources: item.sources,
                duration: item.duration,
                subtitle: .text(item.subtitle),
                footer: item.footer,
                watchProgress: item.watchProgress,
                trailingMenu: menu,
                trailingMenuAccessibilityLabel: item.trailingMenuAccessibilityLabel,
                isTrailingMenuEnabled: item.isTrailingMenuEnabled,
                columnWidth: activeColumnWidth,
                coverPresentation: coverPresentation
            ))
        }
        let skeleton = UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int> { [weak self] cell, _, index in
            guard let self else { return }
            cell.configure(
                style: .library,
                columnWidth: activeColumnWidth,
                coverPresentation: coverPresentation,
                accessibilityLabel: index == 0 && !placeholderLabel.isEmpty ? placeholderLabel : nil
            )
        }
        let header = UICollectionView.SupplementaryRegistration<UIKitFeedSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            guard let self, let title = headerTitle else { return }
            view.configure(
                title: title,
                showsDivider: false,
                textStyle: .footnote,
                weight: .medium,
                color: .secondaryLabel
            )
        }
        let footer = UICollectionView.SupplementaryRegistration<MineFeedFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            guard let self else { return }
            view.configure(state: footerState, onAction: { [weak self] in
                self?.onFooterAction?()
            })
        }
        return MineRowRegistrations(row: row, skeleton: skeleton, header: header, footer: footer)
    }

    func configureDataSource() {
        let regs = makeRegistrations()
        let source = UICollectionViewDiffableDataSource<MineRowSectionKey, MineRowCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            guard let self else { return nil }
            switch cellKey {
            case .item(let id):
                guard let item = itemByID[id] else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: regs.row, for: indexPath, item: item)
            case .skeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: regs.skeleton, for: indexPath, item: index)
            }
        }
        source.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: regs.header, for: indexPath)
            }
            if kind == UICollectionView.elementKindSectionFooter {
                return collectionView.dequeueConfiguredReusableSupplementary(using: regs.footer, for: indexPath)
            }
            return nil
        }
        dataSource = source
    }

    func makeRowSection(
        contentWidth: CGFloat,
        horizontalInset: CGFloat,
        traitCollection: UITraitCollection,
        isSkeleton: Bool
    ) -> NSCollectionLayoutSection {
        let count = max(1, FeedColumnPolicy.columnCount(.videoRow, availableWidth: contentWidth))
        let colWidth = FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: count,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
        let isRegular = traitCollection.horizontalSizeClass == .regular
        let coverHeight = coverPresentation.height(
            forWidth: LibraryRowMetrics.coverWidth(columnWidth: colWidth, isRegularWidth: isRegular)
        )
        let estimatedHeight = max(64, coverHeight)

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(count)),
            heightDimension: .estimated(estimatedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(estimatedHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: count
        )
        group.interItemSpacing = .fixed(UIKitFeedLayoutMetrics.gridColumnSpacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = UIKitFeedLayoutMetrics.listRowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: UIKitFeedLayoutMetrics.topInset,
            leading: horizontalInset,
            bottom: UIKitFeedLayoutMetrics.bottomInset,
            trailing: horizontalInset
        )

        var supplementaries: [NSCollectionLayoutBoundarySupplementaryItem] = []
        if !isSkeleton, headerTitle != nil {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(32)
            )
            supplementaries.append(NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            ))
        }
        if !isSkeleton, footerState != .none {
            let footerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(64)
            )
            supplementaries.append(NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: footerSize,
                elementKind: UICollectionView.elementKindSectionFooter,
                alignment: .bottom
            ))
        }
        section.boundarySupplementaryItems = supplementaries
        return section
    }

    func applySnapshot(reconfigureKeys: [MineRowCellKey] = [], reconfigureAll: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<MineRowSectionKey, MineRowCellKey>()

        if items.isEmpty {
            if placeholderCount > 0 {
                snapshot.appendSections([.skeletons])
                snapshot.appendItems((0..<placeholderCount).map { .skeleton($0) }, toSection: .skeletons)
            }
        } else {
            snapshot.appendSections([.items])
            snapshot.appendItems(items.map { .item($0.id) }, toSection: .items)
        }

        if reconfigureAll {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        } else if !reconfigureKeys.isEmpty {
            let valid = Set(snapshot.itemIdentifiers)
            let targets = reconfigureKeys.filter { valid.contains($0) }
            if !targets.isEmpty { snapshot.reconfigureItems(targets) }
        }

        currentSections = snapshot.sectionIdentifiers
        lastReconfiguredWidth = currentContentWidth
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func updateVisibleHeader() {
        let indexPath = IndexPath(item: 0, section: 0)
        if let header = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: indexPath
        ) as? UIKitFeedSectionHeaderView, let title = headerTitle {
            header.configure(
                title: title,
                showsDivider: false,
                textStyle: .footnote,
                weight: .medium,
                color: .secondaryLabel
            )
        }
    }

    func updateVisibleFooter() {
        let indexPath = IndexPath(item: 0, section: 0)
        if let footer = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionFooter,
            at: indexPath
        ) as? MineFeedFooterView {
            footer.configure(state: footerState, onAction: { [weak self] in
                self?.onFooterAction?()
            })
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(reconfigureAll: true)
        }
    }

    func rowItem(at indexPath: IndexPath) -> MineLibraryRowItem? {
        guard let key = dataSource?.itemIdentifier(for: indexPath),
              case .item(let id) = key else { return nil }
        return itemByID[id]
    }

    func coverRequest(for indexPath: IndexPath) -> UIKitCoverPipeline.CoverRequest? {
        guard let item = rowItem(at: indexPath) else { return nil }
        let isRegular = traitCollection.horizontalSizeClass == .regular
        let coverWidth = LibraryRowMetrics.coverWidth(
            columnWidth: activeColumnWidth,
            isRegularWidth: isRegular
        )
        return UIKitCoverPipeline.request(
            sources: item.sources,
            drawnBox: coverPresentation.size(width: max(1, coverWidth)),
            presentation: coverPresentation,
            scale: traitCollection.displayScale
        )
    }
}
