import SwiftUI
import UIKit

struct MineLibraryCardItem: Identifiable, Equatable {
    let id: MineRowID
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    let subtitle: String?
    let footer: UIKitRowVideoCell.FooterMode
    let watchProgress: Double?
    let isSelectable: Bool
    let isUnavailable: Bool
    let statusBadge: String?
    let statusBadgeStyle: UIKitRowVideoCell.StatusBadgeStyle
    let hasTrailingMenu: Bool
    let trailingMenuAccessibilityLabel: String?
    let isTrailingMenuEnabled: Bool
    let menuRevision: Int
    let allowsSwipeDelete: Bool
    let swipeDeleteTitle: String?

    init(
        id: MineRowID,
        title: String,
        sources: VideoCoverSources,
        duration: Int,
        subtitle: String?,
        footer: UIKitRowVideoCell.FooterMode = .none,
        watchProgress: Double? = nil,
        isSelectable: Bool = true,
        isUnavailable: Bool? = nil,
        statusBadge: String? = nil,
        statusBadgeStyle: UIKitRowVideoCell.StatusBadgeStyle = .neutral,
        hasTrailingMenu: Bool = false,
        trailingMenuAccessibilityLabel: String? = nil,
        isTrailingMenuEnabled: Bool = true,
        menuRevision: Int = 0,
        allowsSwipeDelete: Bool = false,
        swipeDeleteTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sources = sources
        self.duration = duration
        self.subtitle = subtitle
        self.footer = footer
        self.watchProgress = watchProgress
        self.isSelectable = isSelectable
        self.isUnavailable = isUnavailable ?? !isSelectable
        self.statusBadge = statusBadge
        self.statusBadgeStyle = statusBadgeStyle
        self.hasTrailingMenu = hasTrailingMenu
        self.trailingMenuAccessibilityLabel = trailingMenuAccessibilityLabel
        self.isTrailingMenuEnabled = isTrailingMenuEnabled
        self.menuRevision = menuRevision
        self.allowsSwipeDelete = allowsSwipeDelete
        self.swipeDeleteTitle = swipeDeleteTitle
    }

    init(rowItem: MineLibraryRowItem) {
        self.init(
            id: rowItem.id,
            title: rowItem.title,
            sources: rowItem.sources,
            duration: rowItem.duration,
            subtitle: rowItem.subtitle,
            footer: rowItem.footer,
            watchProgress: rowItem.watchProgress,
            isSelectable: rowItem.isSelectable,
            isUnavailable: !rowItem.isSelectable,
            statusBadge: rowItem.isSelectable ? nil : String(localized: "Unavailable"),
            statusBadgeStyle: .warning,
            hasTrailingMenu: rowItem.hasTrailingMenu,
            trailingMenuAccessibilityLabel: rowItem.trailingMenuAccessibilityLabel,
            isTrailingMenuEnabled: rowItem.isTrailingMenuEnabled,
            menuRevision: rowItem.menuRevision
        )
    }
}

struct MineLibraryRowSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let items: [MineLibraryCardItem]
}

@MainActor
struct MineLibrarySectionedFeedConfig {
    let sections: [MineLibraryRowSection]
    let placeholderCount: Int
    let placeholderLabel: String
    let footerState: MineFeedFooterState
    let coverPresentation: CoverPresentation
    let onNearEndAppear: (() -> Void)?
    let onFooterAction: (() -> Void)?
    let onSelectItem: (MineRowID) -> Void
    let makeTrailingMenu: ((MineRowID, UIView?) -> UIMenu?)?
    let makeContextMenu: ((MineRowID) -> UIMenu?)?
    let onSwipeDelete: ((MineRowID) -> Void)?
}

struct MineLibrarySectionedFeedView: View {
    let sections: [MineLibraryRowSection]
    var placeholderCount: Int = 0
    var placeholderLabel: String = ""
    var footerState: MineFeedFooterState = .none
    var onRefresh: (@MainActor () async -> Bool)?
    var onNearEndAppear: (() -> Void)?
    var onFooterAction: (() -> Void)?
    let onSelectItem: (MineRowID) -> Void
    var makeTrailingMenu: ((MineRowID, UIView?) -> UIMenu?)?
    var makeContextMenu: ((MineRowID) -> UIMenu?)?
    var onSwipeDelete: ((MineRowID) -> Void)?

    var body: some View {
        let coverPresentation = CoverPresentationStore.shared.presentation
        let config = MineLibrarySectionedFeedConfig(
            sections: sections,
            placeholderCount: placeholderCount,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            coverPresentation: coverPresentation,
            onNearEndAppear: onNearEndAppear,
            onFooterAction: onFooterAction,
            onSelectItem: onSelectItem,
            makeTrailingMenu: makeTrailingMenu,
            makeContextMenu: makeContextMenu,
            onSwipeDelete: onSwipeDelete
        )
        UIKitCollectionHost(
            onRefresh: onRefresh,
            makeController: { MineLibraryRowFeedController() },
            updateController: { controller in controller.updateSectioned(config) }
        )
    }
}

private enum MineRowSectionKey: Hashable, Sendable {
    case section(String)
    case skeletons
}

private enum MineRowCellKey: Hashable, Sendable {
    case item(MineRowID)
    case skeleton(Int)
}

private struct MineRowRegistrations {
    let row: UICollectionView.CellRegistration<UIKitRowVideoCell, MineLibraryCardItem>
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
    private var sections: [MineLibraryRowSection] = []
    private var sectionTitleByID: [String: String] = [:]
    private var flatItems: [MineLibraryCardItem] = []
    private var itemByID: [MineRowID: MineLibraryCardItem] = [:]
    private var itemIndexByID: [MineRowID: Int] = [:]
    private var anyItemAllowsSwipeDelete = false
    private var placeholderCount = 0
    private var placeholderLabel = ""
    private var footerState: MineFeedFooterState = .none
    private var coverPresentation = CoverPresentationStore.shared.presentation

    private var onNearEndAppear: (() -> Void)?
    private var onFooterAction: (() -> Void)?
    private var onSelectItem: (MineRowID) -> Void = { _ in }
    private var makeTrailingMenu: ((MineRowID, UIView?) -> UIMenu?)?
    private var makeContextMenu: ((MineRowID) -> UIMenu?)?
    private var onSwipeDelete: ((MineRowID) -> Void)?
    private var geometryTask: Task<Void, Never>?

    private static func resolvedInsets(
        for totalWidth: CGFloat
    ) -> (contentWidth: CGFloat, horizontalInset: CGFloat) {
        let safeWidth = totalWidth > 1 ? totalWidth : FeedWidth.fullContainerSeed
        let baseMargin = FeedColumnPolicy.horizontalMargin(for: safeWidth)
        let natural = max(1, safeWidth - baseMargin * 2)
        let contentWidth = min(natural, LibraryRowMetrics.maximumContentWidth)
        let horizontalInset = max(baseMargin, ((safeWidth - contentWidth) / 2).rounded(.down))
        return (contentWidth, horizontalInset)
    }

    override var layoutHorizontalInset: CGFloat {
        let width = isViewLoaded && collectionView.bounds.width > 1
            ? collectionView.bounds.width
                - collectionView.safeAreaInsets.left
                - collectionView.safeAreaInsets.right
            : FeedWidth.fullContainerSeed
        return Self.resolvedInsets(for: width).horizontalInset
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
            let metrics = Self.resolvedInsets(for: effectiveWidth)
            let sectionKey = currentSections[sectionIndex]
            let isSkeleton = sectionKey == .skeletons
            let hasHeader: Bool = switch sectionKey {
            case .section(let id): sectionTitleByID[id] != nil
            case .skeletons: false
            }
            let isLastItemSection = !isSkeleton && sectionIndex == currentSections.count - 1
            let hasFooter = isLastItemSection && footerState != .none
            return makeRowSection(
                contentWidth: metrics.contentWidth,
                horizontalInset: metrics.horizontalInset,
                layoutEnvironment: environment,
                isSkeleton: isSkeleton,
                hasHeader: hasHeader,
                hasFooter: hasFooter,
                isFirstSection: sectionIndex == 0,
                isLastSection: sectionIndex == currentSections.count - 1
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
        let cardItems = config.items.map(MineLibraryCardItem.init(rowItem:))
        let wrappedSections: [MineLibraryRowSection] = cardItems.isEmpty
            ? []
            : [MineLibraryRowSection(id: "items", title: config.headerTitle, items: cardItems)]
        updateSectioned(MineLibrarySectionedFeedConfig(
            sections: wrappedSections,
            placeholderCount: config.placeholderCount,
            placeholderLabel: config.placeholderLabel,
            footerState: config.footerState,
            coverPresentation: config.coverPresentation,
            onNearEndAppear: config.onNearEndAppear,
            onFooterAction: config.onFooterAction,
            onSelectItem: config.onSelectItem,
            makeTrailingMenu: config.makeTrailingMenu,
            makeContextMenu: config.makeContextMenu,
            onSwipeDelete: nil
        ))
    }

    func updateSectioned(_ config: MineLibrarySectionedFeedConfig) {
        onNearEndAppear = config.onNearEndAppear
        onFooterAction = config.onFooterAction
        onSelectItem = config.onSelectItem
        makeTrailingMenu = config.makeTrailingMenu
        makeContextMenu = config.makeContextMenu
        let swipeHandlerChanged = (config.onSwipeDelete != nil) != (onSwipeDelete != nil)
        onSwipeDelete = config.onSwipeDelete

        let nonEmptySections = config.sections.filter { !$0.items.isEmpty }
        let sectionsChanged = nonEmptySections != sections
        let placeholderChanged = config.placeholderCount != placeholderCount
            || config.placeholderLabel != placeholderLabel
        let footerChanged = config.footerState != footerState
        let presentationChanged = config.coverPresentation != coverPresentation

        guard sectionsChanged || placeholderChanged || footerChanged || presentationChanged || swipeHandlerChanged else {
            return
        }

        let previousCount = flatItems.count
        let previousByID = itemByID
        let previousTitles = sectionTitleByID
        let previousSwipeAllowed = anyItemAllowsSwipeDelete
        let hadFooter = footerState != .none && !flatItems.isEmpty

        sections = nonEmptySections
        var nextTitleByID: [String: String] = [:]
        var nextFlat: [MineLibraryCardItem] = []
        var nextByID: [MineRowID: MineLibraryCardItem] = [:]
        var nextIndexByID: [MineRowID: Int] = [:]
        var nextSwipeAllowed = false

        for section in nonEmptySections {
            if let title = section.title, !title.isEmpty {
                nextTitleByID[section.id] = title
            }
            for item in section.items where nextByID[item.id] == nil {
                nextIndexByID[item.id] = nextFlat.count
                nextFlat.append(item)
                nextByID[item.id] = item
                if item.allowsSwipeDelete {
                    nextSwipeAllowed = true
                }
            }
        }

        sectionTitleByID = nextTitleByID
        flatItems = nextFlat
        itemByID = nextByID
        itemIndexByID = nextIndexByID
        anyItemAllowsSwipeDelete = nextSwipeAllowed
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        footerState = config.footerState
        coverPresentation = config.coverPresentation

        if flatItems.count != previousCount {
            resetPaginationGate()
        }

        let hasFooter = footerState != .none && !flatItems.isEmpty
        let headerPresenceChanged = Set(previousTitles.keys) != Set(nextTitleByID.keys)
        let headerTextChanged = previousTitles != nextTitleByID
        let swipeLayoutChanged = swipeHandlerChanged || previousSwipeAllowed != nextSwipeAllowed
        let boundaryChanged = headerPresenceChanged || (hadFooter != hasFooter) || swipeLayoutChanged

        if isViewLoaded {
            var reconfigureIDs: [MineRowCellKey] = []
            if !presentationChanged {
                for item in flatItems where previousByID[item.id] != item {
                    reconfigureIDs.append(.item(item.id))
                }
            }
            applySnapshot(reconfigureKeys: reconfigureIDs, reconfigureAll: presentationChanged)
            if boundaryChanged || presentationChanged {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            if headerTextChanged {
                updateVisibleHeaders()
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
        let key = PaginationKey(count: flatItems.count, lastID: flatItems.last?.id)
        triggerNearEndPaginationIfNeeded(
            index: index,
            totalCount: flatItems.count,
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
    func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let onSwipeDelete,
              let item = rowItem(at: indexPath),
              item.allowsSwipeDelete else {
            return nil
        }
        let title = item.swipeDeleteTitle ?? String(localized: "Delete")
        let action = UIContextualAction(style: .destructive, title: title) { _, _, completion in
            onSwipeDelete(item.id)
            completion(true)
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func makeRegistrations() -> MineRowRegistrations {
        let row = UICollectionView.CellRegistration<
            UIKitRowVideoCell,
            MineLibraryCardItem
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
                isUnavailable: item.isUnavailable,
                statusBadge: item.statusBadge,
                statusBadgeStyle: item.statusBadgeStyle,
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
        ) { [weak self] view, _, indexPath in
            guard let self,
                  indexPath.section < currentSections.count,
                  case .section(let sectionID) = currentSections[indexPath.section],
                  let title = sectionTitleByID[sectionID] else { return }
            let isMultiSection = sections.count > 1
            view.configure(
                title: title,
                showsDivider: false,
                textStyle: isMultiSection ? .subheadline : .footnote,
                weight: isMultiSection ? .semibold : .medium,
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
        layoutEnvironment: any NSCollectionLayoutEnvironment,
        isSkeleton: Bool,
        hasHeader: Bool,
        hasFooter: Bool,
        isFirstSection: Bool,
        isLastSection: Bool
    ) -> NSCollectionLayoutSection {
        let count = max(1, FeedColumnPolicy.columnCount(.videoRow, availableWidth: contentWidth))
        let topInset = isFirstSection ? UIKitFeedLayoutMetrics.topInset : AppSpacing.xs
        let bottomInset = isLastSection ? UIKitFeedLayoutMetrics.bottomInset : AppSpacing.s

        let usesSwipeList = !isSkeleton && count == 1 && onSwipeDelete != nil && anyItemAllowsSwipeDelete
        if usesSwipeList {
            var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
            listConfig.backgroundColor = .clear
            listConfig.showsSeparators = false
            listConfig.headerMode = hasHeader ? .supplementary : .none
            listConfig.footerMode = hasFooter ? .supplementary : .none
            listConfig.headerTopPadding = 0
            listConfig.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipeActions(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: layoutEnvironment)
            section.interGroupSpacing = UIKitFeedLayoutMetrics.listRowSpacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: topInset,
                leading: horizontalInset,
                bottom: bottomInset,
                trailing: horizontalInset
            )
            return section
        }

        let colWidth = FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: count,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
        let isRegular = layoutEnvironment.traitCollection.horizontalSizeClass == .regular
        let coverHeight = coverPresentation.height(
            forWidth: LibraryRowMetrics.coverWidth(columnWidth: colWidth, isRegularWidth: isRegular)
        )
        let estimatedHeight = max(84, coverHeight)

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
            top: topInset,
            leading: horizontalInset,
            bottom: bottomInset,
            trailing: horizontalInset
        )

        var supplementaries: [NSCollectionLayoutBoundarySupplementaryItem] = []
        if hasHeader {
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
        if hasFooter {
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

        if flatItems.isEmpty {
            if placeholderCount > 0 {
                snapshot.appendSections([.skeletons])
                snapshot.appendItems((0..<placeholderCount).map { .skeleton($0) }, toSection: .skeletons)
            }
        } else {
            var seen = Set<MineRowID>()
            for section in sections {
                let uniqueIDs = section.items.compactMap { item -> MineRowCellKey? in
                    guard seen.insert(item.id).inserted else { return nil }
                    return .item(item.id)
                }
                guard !uniqueIDs.isEmpty else { continue }
                let key = MineRowSectionKey.section(section.id)
                snapshot.appendSections([key])
                snapshot.appendItems(uniqueIDs, toSection: key)
            }
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

    func updateVisibleHeaders() {
        let isMultiSection = sections.count > 1
        for (index, key) in currentSections.enumerated() {
            guard case .section(let sectionID) = key,
                  let title = sectionTitleByID[sectionID] else { continue }
            let indexPath = IndexPath(item: 0, section: index)
            if let header = collectionView.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader,
                at: indexPath
            ) as? UIKitFeedSectionHeaderView {
                header.configure(
                    title: title,
                    showsDivider: false,
                    textStyle: isMultiSection ? .subheadline : .footnote,
                    weight: isMultiSection ? .semibold : .medium,
                    color: .secondaryLabel
                )
            }
        }
    }

    func updateVisibleFooter() {
        guard !currentSections.isEmpty else { return }
        let indexPath = IndexPath(item: 0, section: currentSections.count - 1)
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

    func rowItem(at indexPath: IndexPath) -> MineLibraryCardItem? {
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
