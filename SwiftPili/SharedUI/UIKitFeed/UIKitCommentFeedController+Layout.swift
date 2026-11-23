import SwiftUI
import UIKit

extension UIKitCommentFeedViewController {
    private var resolvedRowColumnWidth: CGFloat? {
        guard currentColumnWidth > 1 else { return hostEnvironment.snapshot.rowCardColumnWidth }
        if let outer = hostEnvironment.snapshot.rowCardColumnWidth, outer.isFinite, outer > 1 {
            return min(outer, currentColumnWidth)
        }
        return currentColumnWidth
    }

    func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            return makeSectionLayout(
                sections[sectionIndex],
                effectiveWidth: environment.container.effectiveContentSize.width,
                isFirst: sectionIndex == 0,
                isLast: sectionIndex == sections.count - 1
            )
        }
    }

    func measuredColumnWidth(for boundsWidth: CGFloat, safeAreaInsets: UIEdgeInsets) -> CGFloat {
        let insetWidth = boundsWidth - safeAreaInsets.left - safeAreaInsets.right
        return max(0, insetWidth - resolvedSideInset(for: insetWidth) * 2)
    }

    func makeDiffableDataSource(
        for collectionView: UICollectionView
    ) -> UICollectionViewDiffableDataSource<CommentFeedSectionKey, CommentFeedCellKey> {
        let hostedReg = UICollectionView.CellRegistration<UICollectionViewCell, CommentFeedCellKey>(
            handler: { [weak self] cell, _, key in
                self?.configureHostedCell(cell, for: key)
            }
        )
        let skeletonReg = UICollectionView.CellRegistration<UIKitCommentSkeletonCell, Int>(
            handler: { cell, _, index in
                cell.configure(accessibilityLabel: index == 0 ? String(localized: "Loading comments") : nil)
            }
        )
        return UICollectionViewDiffableDataSource<CommentFeedSectionKey, CommentFeedCellKey>(
            collectionView: collectionView
        ) { collection, indexPath, cellKey in
            switch cellKey {
            case .skeleton(let index):
                return collection.dequeueConfiguredReusableCell(using: skeletonReg, for: indexPath, item: index)
            case .header, .item, .footer:
                return collection.dequeueConfiguredReusableCell(using: hostedReg, for: indexPath, item: cellKey)
            }
        }
    }

    func performWithoutLayoutAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            body()
        }
        CATransaction.commit()
    }

    func shouldResetScrollToTop(
        oldIDs: [AnyHashableSendable],
        newIDs: [AnyHashableSendable],
        skeletonCount: Int
    ) -> Bool {
        guard !oldIDs.isEmpty else { return false }
        if newIDs.isEmpty { return skeletonCount > 0 }
        if oldIDs == newIDs { return false }
        if newIDs.count > oldIDs.count, newIDs.prefix(oldIDs.count).elementsEqual(oldIDs) {
            return false
        }
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)
        if newSet.isSubset(of: oldSet) || oldSet.isSubset(of: newSet) {
            let shared = oldSet.intersection(newSet)
            return oldIDs.filter { shared.contains($0) } != newIDs.filter { shared.contains($0) }
        }
        return true
    }

    func applySnapshot(
        reconfigureKeys: [CommentFeedCellKey] = [],
        reconfigureAll: Bool = false,
        resetScrollToTop: Bool = false
    ) {
        guard let dataSource,
              let snapshot = buildSnapshot(
                  currentSnapshot: dataSource.snapshot(),
                  reconfigureKeys: reconfigureKeys,
                  reconfigureAll: reconfigureAll
              ) else { return }
        let shouldResetOffset = resetScrollToTop
            && !refreshControl.isRefreshing
            && !collectionView.isTracking
            && pendingScrollToItemID == nil
        performWithoutLayoutAnimations {
            if shouldResetOffset {
                resetContentOffsetToTopIfNeeded()
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            if shouldResetOffset {
                collectionView.layoutIfNeeded()
                resetContentOffsetToTopIfNeeded()
            }
        }
    }

    private func buildSnapshot(
        currentSnapshot: NSDiffableDataSourceSnapshot<CommentFeedSectionKey, CommentFeedCellKey>,
        reconfigureKeys: [CommentFeedCellKey],
        reconfigureAll: Bool
    ) -> NSDiffableDataSourceSnapshot<CommentFeedSectionKey, CommentFeedCellKey>? {
        var snapshot = NSDiffableDataSourceSnapshot<CommentFeedSectionKey, CommentFeedCellKey>()
        if !orderedHeaderIDs.isEmpty {
            snapshot.appendSections([.header])
            snapshot.appendItems(orderedHeaderIDs.map { .header($0) }, toSection: .header)
        }
        if !orderedItemIDs.isEmpty {
            snapshot.appendSections([.items])
            snapshot.appendItems(orderedItemIDs.map { .item($0) }, toSection: .items)
        } else if config.skeletonCount > 0 {
            snapshot.appendSections([.skeletons])
            snapshot.appendItems((0 ..< config.skeletonCount).map { .skeleton($0) }, toSection: .skeletons)
        }
        if config.footerContent != nil {
            snapshot.appendSections([.footer])
            snapshot.appendItems([.footer], toSection: .footer)
        }
        let existing = Set(currentSnapshot.itemIdentifiers)
        var hasReconfigureTargets = false
        if reconfigureAll {
            let targets = snapshot.itemIdentifiers.filter { existing.contains($0) }
            if !targets.isEmpty {
                snapshot.reconfigureItems(targets)
                hasReconfigureTargets = true
            }
        } else if !reconfigureKeys.isEmpty {
            let valid = Set(snapshot.itemIdentifiers)
            var seen: Set<CommentFeedCellKey> = []
            let targets = reconfigureKeys.filter {
                existing.contains($0) && valid.contains($0) && seen.insert($0).inserted
            }
            if !targets.isEmpty {
                snapshot.reconfigureItems(targets)
                hasReconfigureTargets = true
            }
        }
        if !hasReconfigureTargets,
           currentSnapshot.sectionIdentifiers == snapshot.sectionIdentifiers,
           currentSnapshot.itemIdentifiers == snapshot.itemIdentifiers {
            return nil
        }
        return snapshot
    }

    private func resetContentOffsetToTopIfNeeded() {
        let topY = -collectionView.adjustedContentInset.top
        if collectionView.contentOffset.y > topY + 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: topY), animated: false)
        }
    }

    func computeReconfigureKeys(_ input: CommentFeedSnapshotDiffInput) -> [CommentFeedCellKey] {
        if shouldReconfigureAllItems(for: input) {
            var all = orderedHeaderIDs.map { CommentFeedCellKey.header($0) }
            all.append(contentsOf: orderedItemIDs.map { CommentFeedCellKey.item($0) })
            if input.newConfig.footerContent != nil { all.append(.footer) }
            return all
        }

        var keys: [CommentFeedCellKey] = []
        for id in orderedHeaderIDs {
            let item = headerByID[id]
            let isUnkeyed = item?.hasExplicitFingerprint == false
            if isUnkeyed || input.oldHeaderByID[id]?.fingerprint != item?.fingerprint {
                keys.append(.header(id))
            }
        }
        for id in orderedItemIDs where input.oldItemByID[id]?.fingerprint != itemByID[id]?.fingerprint {
            keys.append(.item(id))
        }
        if input.oldConfig.highlightedItemID != input.newConfig.highlightedItemID {
            if let oldHighlight = input.oldConfig.highlightedItemID { keys.append(.item(oldHighlight)) }
            if let newHighlight = input.newConfig.highlightedItemID { keys.append(.item(newHighlight)) }
        }
        if input.newConfig.showsItemDividers {
            keys.append(contentsOf: dividerBoundaryReconfigureKeys(oldOrderedIDs: input.oldOrderedIDs))
        }
        if input.newConfig.footerContent != nil,
           input.newConfig.footerFingerprint == nil
            || input.oldConfig.footerFingerprint != input.newConfig.footerFingerprint {
            keys.append(.footer)
        }
        return keys
    }

    private func shouldReconfigureAllItems(for input: CommentFeedSnapshotDiffInput) -> Bool {
        input.oldEnv != input.newEnv
            || input.oldConfig.showsItemDividers != input.newConfig.showsItemDividers
            || input.oldConfig.dividerLeadingInset != input.newConfig.dividerLeadingInset
            || (input.newConfig.showsItemDividers && input.oldConfig.itemSpacing != input.newConfig.itemSpacing)
    }

    private func dividerBoundaryReconfigureKeys(oldOrderedIDs: [AnyHashableSendable]) -> [CommentFeedCellKey] {
        var keys: [CommentFeedCellKey] = []
        if oldOrderedIDs.first != orderedItemIDs.first {
            if let oldFirst = oldOrderedIDs.first { keys.append(.item(oldFirst)) }
            if let newFirst = orderedItemIDs.first { keys.append(.item(newFirst)) }
        }
        if oldOrderedIDs.last != orderedItemIDs.last {
            if let oldLast = oldOrderedIDs.last { keys.append(.item(oldLast)) }
            if let newLast = orderedItemIDs.last { keys.append(.item(newLast)) }
        }
        return keys
    }

    func layoutMetricsChanged(old: UIKitCommentFeedConfiguration, new: UIKitCommentFeedConfiguration) -> Bool {
        old.bottomClearance != new.bottomClearance
            || old.horizontalInset != new.horizontalInset
            || old.topInset != new.topInset
            || old.itemSpacing != new.itemSpacing
            || old.headerSpacing != new.headerSpacing
            || old.maxContentWidth != new.maxContentWidth
            || old.showsItemDividers != new.showsItemDividers
    }
}

private extension UIKitCommentFeedViewController {
    func makeSectionLayout(
        _ sectionKey: CommentFeedSectionKey,
        effectiveWidth: CGFloat,
        isFirst: Bool,
        isLast: Bool
    ) -> NSCollectionLayoutSection {
        let sideInset = resolvedSideInset(for: effectiveWidth)
        let estimatedHeight: CGFloat = switch sectionKey {
        case .header: 64
        case .items: 132
        case .skeletons: 112
        case .footer: 80
        }
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(estimatedHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: itemSize,
            subitems: [NSCollectionLayoutItem(layoutSize: itemSize)]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = sectionSpacing(for: sectionKey)
        let top = isFirst ? config.topInset : 0
        let bottom = sectionBottomInset(for: sectionKey, isLast: isLast)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: top, leading: sideInset, bottom: bottom, trailing: sideInset
        )
        return section
    }

    func sectionSpacing(for sectionKey: CommentFeedSectionKey) -> CGFloat {
        switch sectionKey {
        case .header: config.headerSpacing
        case .items: config.showsItemDividers ? 0 : config.itemSpacing
        case .skeletons: config.itemSpacing
        case .footer: 0
        }
    }

    func sectionBottomInset(for sectionKey: CommentFeedSectionKey, isLast: Bool) -> CGFloat {
        let clearance = isLast ? max(0, config.bottomClearance) : 0
        guard !isLast else { return clearance }
        return switch sectionKey {
        case .header: config.headerSpacing
        case .items, .skeletons: config.itemSpacing
        case .footer: 0
        }
    }

    func resolvedSideInset(for effectiveWidth: CGFloat) -> CGFloat {
        let horizontal = max(0, config.horizontalInset)
        guard let maxWidth = config.maxContentWidth, maxWidth.isFinite, maxWidth > 0 else {
            return horizontal
        }
        let column = max(1, min(effectiveWidth - horizontal * 2, maxWidth))
        return max(horizontal, ((effectiveWidth - column) / 2).rounded(.down))
    }

    func configureHostedCell(_ cell: UICollectionViewCell, for key: CommentFeedCellKey) {
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.clipsToBounds = false
        cell.contentView.clipsToBounds = false

        let body: AnyView? = switch key {
        case .header(let id):
            headerByID[id]?.makeContent()
        case .item(let id):
            itemByID[id].map { item in
                let isHighlighted = config.highlightedItemID == id
                let isFirst = id == orderedItemIDs.first
                let showsDivider = config.showsItemDividers && id != orderedItemIDs.last
                return AnyView(decoratedItemView(
                    item.makeContent(),
                    isHighlighted: isHighlighted,
                    isFirst: isFirst,
                    showsBottomDivider: showsDivider
                ))
            }
        case .footer:
            config.footerContent
        case .skeleton:
            nil
        }
        guard let body else {
            cell.contentConfiguration = nil
            return
        }
        let env = hostEnvironment
        let width = resolvedRowColumnWidth
        let openURL = OpenURLAction { [weak self] url in
            guard let action = self?.hostEnvironment.openURL else { return .systemAction }
            action(url)
            return .handled
        }
        cell.contentConfiguration = UIHostingConfiguration {
            body
                .modifier(CommentFeedHostedEnvironmentModifier(
                    snapshot: env.snapshot,
                    resolvedColumnWidth: width,
                    coordinator: env.coordinator,
                    contentLinkContext: env.contentLinkContext,
                    openURL: openURL
                ))
        }
        .margins(.all, 0)
        .background(.clear)
    }

    @ViewBuilder
    func decoratedItemView(
        _ base: AnyView,
        isHighlighted: Bool,
        isFirst: Bool,
        showsBottomDivider: Bool
    ) -> some View {
        let halfGap: CGFloat = config.itemSpacing <= 10 ? 8 : 10
        VStack(alignment: .leading, spacing: 0) {
            base
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: AppRadius.control)
                            .fill(Color.biliAccent.opacity(0.14))
                            .padding(-6)
                    }
                }
                .padding(.top, (config.showsItemDividers && !isFirst) ? halfGap : 0)
            if showsBottomDivider {
                Divider()
                    .opacity(0.45)
                    .padding(.top, halfGap)
                    .padding(.leading, config.dividerLeadingInset)
            }
        }
    }
}

private struct CommentFeedHostedEnvironmentModifier: ViewModifier {
    let snapshot: CommentFeedEnvironmentSnapshot
    let resolvedColumnWidth: CGFloat?
    let coordinator: AppCoordinator?
    let contentLinkContext: ContentLinkContext?
    let openURL: OpenURLAction

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, snapshot.colorScheme)
            .environment(\.dynamicTypeSize, snapshot.dynamicTypeSize)
            .environment(\.horizontalSizeClass, snapshot.horizontalSizeClass)
            .environment(\.appSurface, snapshot.appSurface)
            .environment(\.layoutDirection, snapshot.layoutDirection)
            .environment(\.displayScale, snapshot.displayScale)
            .environment(\.locale, snapshot.locale)
            .environment(\.imageDiagnosticsScreen, snapshot.imageDiagnosticsScreen)
            .environment(\.contentLinkDefersToParent, snapshot.contentLinkDefersToParent)
            .environment(\.navigationZoomNamespace, snapshot.navigationZoomNamespace)
            .environment(\.contentLinkContext, contentLinkContext)
            .environment(\.openURL, openURL)
            .rowCardColumnWidth(resolvedColumnWidth)
            .environment(coordinator)
    }
}
