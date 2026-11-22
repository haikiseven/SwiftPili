import SwiftUI
import UIKit

@MainActor
final class MomentDetailCollectionViewController: UIViewController,
    UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching {
    fileprivate struct SectionEdges {
        let comments: (first: Int?, last: Int?)
        let forwards: (first: String?, last: String?)
        let reactions: (first: String?, last: String?)
    }

    private struct PaginationKey: Hashable {
        let section: MomentDetailView.InteractionSection
        let count: Int
        let lastID: String
    }

    private struct IndexCache<Item, ID: Hashable> {
        var orderedIDs: [ID] = []
        var byID: [ID: Item] = [:]
        var indexByID: [ID: Int] = [:]

        mutating func rebuild(from items: [Item], id: (Item) -> ID) {
            var ids: [ID] = []
            var map: [ID: Item] = [:]
            var idx: [ID: Int] = [:]
            for item in items {
                let key = id(item)
                guard map[key] == nil else { continue }
                idx[key] = ids.count
                ids.append(key)
                map[key] = item
            }
            orderedIDs = ids
            byID = map
            indexByID = idx
        }
    }

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeCollectionLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .onDrag
        view.delegate = self
        view.prefetchDataSource = self
        return view
    }()

    private let refreshControl = UIRefreshControl()
    private let prefetchCoordinator = UIKitPrefetchCoordinator()
    private var dataSource: UICollectionViewDiffableDataSource<MomentDetailSectionKey, MomentDetailCellKey>?

    private var currentInput: MomentDetailSnapshotInput?
    private var hostEnvironment = EnvironmentValues()
    private var item: DynamicFeedResult.DynamicItem?
    private var commentCache = IndexCache<CommentResult.CommentItem, Int>()
    private var forwardCache = IndexCache<DynamicForwardItem, String>()
    private var reactionCache = IndexCache<MomentDetailViewModel.ReactionEntry, String>()
    private var liked = false
    private var likeCount = 0
    private var actions: MomentDetailCollectionActions?

    private var currentContentWidth: CGFloat = FeedWidth.seed
    private var hasAppliedInitialSnapshot = false
    private var externalBottomSafeAreaInset: CGFloat = 0
    private var activeRefreshToken: UUID?
    private var refreshTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var sectionScrollTask: Task<Void, Never>?
    private var lastPaginationKey: PaginationKey?

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        view.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        configureDataSource()
        registerTraitObservers()
        let measured = measuredContentWidth()
        if measured > 1 {
            currentContentWidth = measured
            hasAppliedInitialSnapshot = true
            applySnapshot()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAppliedInitialSnapshot {
            let measured = measuredContentWidth()
            if measured > 1 { currentContentWidth = measured }
            hasAppliedInitialSnapshot = true
            applySnapshot()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncBottomSafeAreaIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncBottomSafeAreaIfNeeded()
        let measured = measuredContentWidth()
        if !hasAppliedInitialSnapshot {
            if measured > 1 {
                currentContentWidth = measured
                hasAppliedInitialSnapshot = true
                applySnapshot()
            }
            return
        }
        guard measured > 1, abs(measured - currentContentWidth) > 0.5 else { return }
        currentContentWidth = measured
        prefetchCoordinator.cancelAll()
        performWithoutLayoutAnimations {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        scheduleGeometryReconfigure()
    }

    func tearDown() {
        activeRefreshToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        geometryTask?.cancel()
        geometryTask = nil
        sectionScrollTask?.cancel()
        sectionScrollTask = nil
        prefetchCoordinator.cancelAll()
    }

    func apply(
        view: MomentDetailCollectionView,
        hostEnvironment newEnv: EnvironmentValues,
        externalBottomSafeAreaInset newBottomInset: CGFloat
    ) {
        let oldInput = currentInput
        let oldEnv = hostEnvironment
        let sectionChanged = oldInput != nil
            && oldInput?.dynamicID == view.input.dynamicID
            && oldInput?.section != view.input.section

        currentInput = view.input
        hostEnvironment = newEnv
        applyEnvironmentTraits(newEnv)
        if abs(externalBottomSafeAreaInset - newBottomInset) > 0.5 {
            externalBottomSafeAreaInset = newBottomInset
            if isViewLoaded { syncBottomSafeAreaIfNeeded() }
        }
        item = view.item
        liked = view.liked
        likeCount = view.likeCount
        actions = view.actions

        let (oldEdges, oldCommentIDs) = syncCaches(oldInput: oldInput, view: view, sectionChanged: sectionChanged)
        guard isViewLoaded else { return }
        if !hasAppliedInitialSnapshot {
            let measured = measuredContentWidth()
            guard measured > 1 else { return }
            currentContentWidth = measured
            hasAppliedInitialSnapshot = true
            applySnapshot()
            return
        }
        if oldInput?.composerClearance != view.input.composerClearance {
            performWithoutLayoutAnimations {
                collectionView.collectionViewLayout.invalidateLayout()
            }
        }
        let reconfigures = computeReconfigureKeys(
            oldInput: oldInput, newInput: view.input,
            oldEnv: oldEnv, newEnv: newEnv, oldEdges: oldEdges
        )
        let resetsCommentViewport = shouldResetCommentsToHeader(
            oldInput: oldInput, newInput: view.input,
            oldCommentIDs: oldCommentIDs, newCommentIDs: commentCache.orderedIDs
        )
        applySnapshot(reconfigureKeys: reconfigures, resetCommentsToHeader: resetsCommentViewport)
        if sectionChanged {
            scheduleScrollToInteractionsHeader(expectedSection: view.input.section)
        }
    }

    private func syncCaches(
        oldInput: MomentDetailSnapshotInput?,
        view: MomentDetailCollectionView,
        sectionChanged: Bool
    ) -> (SectionEdges, [Int]) {
        let oldEdges = SectionEdges(
            comments: (first: commentCache.orderedIDs.first, last: commentCache.orderedIDs.last),
            forwards: (first: forwardCache.orderedIDs.first, last: forwardCache.orderedIDs.last),
            reactions: (first: reactionCache.orderedIDs.first, last: reactionCache.orderedIDs.last)
        )
        let oldCommentIDs = commentCache.orderedIDs
        let commentsChanged = oldInput?.commentFingerprints != view.input.commentFingerprints
        let forwardsChanged = oldInput?.forwardIDs != view.input.forwardIDs
        let reactionsChanged = oldInput?.reactionIDs != view.input.reactionIDs
        if commentsChanged { commentCache.rebuild(from: view.comments, id: \.rpid) }
        if forwardsChanged { forwardCache.rebuild(from: view.forwards, id: \.id) }
        if reactionsChanged { reactionCache.rebuild(from: view.reactions, id: \.id) }
        if commentsChanged || forwardsChanged || reactionsChanged || sectionChanged
            || oldInput?.footerFingerprint != view.input.footerFingerprint {
            lastPaginationKey = nil
        }
        return (oldEdges, oldCommentIDs)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }
    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool { false }

    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        guard let key = dataSource?.itemIdentifier(for: indexPath),
              let section = currentInput?.section else { return }
        switch key {
        case .comment(let rpid) where section == .comments:
            guard let index = commentCache.indexByID[rpid] else { return }
            let last = commentCache.orderedIDs.last.map(String.init) ?? ""
            triggerPagination(index: index, total: commentCache.orderedIDs.count, section: .comments, lastID: last) {
                actions?.onLoadMoreComments()
            }
        case .forward(let id) where section == .forwards:
            guard let index = forwardCache.indexByID[id] else { return }
            let last = forwardCache.orderedIDs.last ?? ""
            triggerPagination(index: index, total: forwardCache.orderedIDs.count, section: .forwards, lastID: last) {
                actions?.onLoadMoreForwards()
            }
        case .reaction(let id) where section == .likes:
            guard let index = reactionCache.indexByID[id] else { return }
            let last = reactionCache.orderedIDs.last ?? ""
            triggerPagination(index: index, total: reactionCache.orderedIDs.count, section: .likes, lastID: last) {
                actions?.onLoadMoreReactions()
            }
        default: break
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if ImageDiagnostics.isEnabled { ImageDiagnostics.isScrolling = true }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if ImageDiagnostics.isEnabled, !decelerate { ImageDiagnostics.isScrolling = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if ImageDiagnostics.isEnabled { ImageDiagnostics.isScrolling = false }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if ImageDiagnostics.isEnabled { ImageDiagnostics.isScrolling = false }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] in self?.mediaRequests(for: $0) ?? [] }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }
}

private extension MomentDetailCollectionViewController {
    var readableCardWidth: CGFloat {
        max(1, min(currentContentWidth, ReadableWidth.feed))
    }

    func makeCollectionLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, env in
            guard let self else { return nil }
            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            return makeSectionLayout(sections[sectionIndex], effectiveWidth: env.container.effectiveContentSize.width)
        }
        layout.register(
            MomentDetailPanelBackgroundView.self,
            forDecorationViewOfKind: MomentDetailPanelBackgroundView.kind
        )
        return layout
    }

    func makeSectionLayout(_ key: MomentDetailSectionKey, effectiveWidth: CGFloat) -> NSCollectionLayoutSection {
        let column = max(1, min(effectiveWidth - AppSpacing.l * 2, ReadableWidth.feed))
        let sideInset = max(AppSpacing.l, ((effectiveWidth - column) / 2).rounded(.down))
        let estHeight: CGFloat = switch key {
        case .state: 180
        case .card: 280
        case .interactions: 120
        }
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(estHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: itemSize, subitems: [NSCollectionLayoutItem(layoutSize: itemSize)]
        )
        let section = NSCollectionLayoutSection(group: group)
        let clearance = currentInput?.composerClearance ?? 0
        switch key {
        case .state:
            section.contentInsets = NSDirectionalEdgeInsets(
                top: AppSpacing.l, leading: sideInset, bottom: AppSpacing.l, trailing: sideInset
            )
        case .card:
            section.contentInsets = NSDirectionalEdgeInsets(
                top: AppSpacing.l, leading: sideInset, bottom: AppSpacing.s, trailing: sideInset
            )
        case .interactions:
            let innerInset = sideInset + AppSpacing.l
            section.interGroupSpacing = 0
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: innerInset, bottom: AppSpacing.l + clearance, trailing: innerInset
            )
            let background = NSCollectionLayoutDecorationItem.background(
                elementKind: MomentDetailPanelBackgroundView.kind
            )
            background.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: sideInset, bottom: 0, trailing: sideInset
            )
            section.decorationItems = [background]
        }
        return section
    }

    func configureDataSource() {
        let cardReg = UICollectionView.CellRegistration<UIKitDynamicCardCell, DynamicFeedResult.DynamicItem>(
            handler: { [weak self] cell, _, item in
                guard let self else { return }
                cell.configure(UIKitDynamicCardCell.Model(
                    item: item,
                    interactionStore: nil,
                    fallbackLikeState: (liked, likeCount),
                    availableWidth: readableCardWidth,
                    expanded: true,
                    showsCardBackground: true,
                    actions: makeCardActions()
                ))
            }
        )
        let skeletonReg = UICollectionView.CellRegistration<UIKitCommentSkeletonCell, Int> { cell, _, index in
            cell.configure(accessibilityLabel: index == 0 ? String(localized: "Loading comments") : nil)
        }
        let hostedReg = UICollectionView.CellRegistration<UICollectionViewCell, MomentDetailCellKey>(
            handler: { [weak self] cell, _, key in
                self?.configureHostedCell(cell, for: key)
            }
        )
        dataSource = UICollectionViewDiffableDataSource<MomentDetailSectionKey, MomentDetailCellKey>(
            collectionView: collectionView
        ) { [weak self] collection, indexPath, key in
            guard let self else { return nil }
            switch key {
            case .card:
                return item.map { collection.dequeueConfiguredReusableCell(using: cardReg, for: indexPath, item: $0) }
            case .commentSkeleton(let idx):
                return collection.dequeueConfiguredReusableCell(using: skeletonReg, for: indexPath, item: idx)
            default:
                return collection.dequeueConfiguredReusableCell(using: hostedReg, for: indexPath, item: key)
            }
        }
    }

    func configureHostedCell(_ cell: UICollectionViewCell, for key: MomentDetailCellKey) {
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        let content: AnyView? = switch key {
        case .state: actions?.makeStateView()
        case .header: actions?.makeHeaderView()
        case .comment(let rpid): commentCache.byID[rpid].flatMap { comment in
            makeDividedCellView(
                actions?.makeCommentRow(comment),
                showsTopSpacing: rpid != commentCache.orderedIDs.first,
                showsBottomDivider: rpid != commentCache.orderedIDs.last,
                verticalPadding: 10,
                dividerLeadingInset: 48
            )
        }
        case .forward(let id): forwardCache.byID[id].flatMap { forward in
            makeDividedCellView(
                actions?.makeForwardRow(forward),
                showsTopSpacing: id != forwardCache.orderedIDs.first,
                showsBottomDivider: id != forwardCache.orderedIDs.last,
                verticalPadding: 8,
                dividerLeadingInset: 46
            )
        }
        case .reaction(let id): reactionCache.byID[id].flatMap { entry in
            makeDividedCellView(
                actions?.makeReactionRow(entry),
                showsTopSpacing: id != reactionCache.orderedIDs.first,
                showsBottomDivider: id != reactionCache.orderedIDs.last,
                verticalPadding: 8,
                dividerLeadingInset: 46
            )
        }
        case .reactionBanner: actions?.makeReactionBanner()
        case .footer: actions?.makeFooterView()
        case .card, .commentSkeleton: nil
        }
        guard let content else { cell.contentConfiguration = nil; return }
        let env = hostEnvironment
        let innerWidth = max(1, readableCardWidth - AppSpacing.l * 2)
        cell.contentConfiguration = UIHostingConfiguration {
            content.environment(\.self, env).rowCardColumnWidth(innerWidth)
        }.margins(.all, 0).background(.clear)
    }

    func makeDividedCellView(
        _ row: AnyView?,
        showsTopSpacing: Bool,
        showsBottomDivider: Bool,
        verticalPadding: CGFloat,
        dividerLeadingInset: CGFloat
    ) -> AnyView? {
        guard let row else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                row
                    .padding(.top, showsTopSpacing ? verticalPadding : 0)
                if showsBottomDivider {
                    Divider()
                        .opacity(0.45)
                        .padding(.top, verticalPadding)
                        .padding(.leading, dividerLeadingInset)
                }
            }
        )
    }

    func makeCardActions() -> UIKitDynamicCardCell.Actions {
        UIKitDynamicCardCell.Actions(
            onOpenPost: nil,
            onOpenQuotedPost: { [weak self] qid in self?.actions?.onOpenPost(qid) },
            onOpenProfile: { [weak self] mid in self?.actions?.onOpenProfile(mid) },
            onOpenVideo: { [weak self] target in self?.actions?.onOpenVideo(target) },
            onOpenArticle: { [weak self] cvid in self?.actions?.onOpenArticle(cvid) },
            onOpenLiveRoom: { [weak self] roomID in self?.actions?.onOpenLiveRoom(roomID) },
            onOpenURL: { [weak self] url in self?.hostEnvironment.openURL(url) },
            onImageTap: { [weak self] preview in self?.actions?.onImageTap(preview) },
            onRepost: { [weak self] in self?.actions?.onRepost() },
            onComment: { [weak self] in self?.actions?.onFocusComment() },
            onLike: { [weak self] in self?.actions?.onToggleLike() }
        )
    }

    func performWithoutLayoutAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            body()
        }
        CATransaction.commit()
    }

    func measuredContentWidth() -> CGFloat {
        let boundsWidth = collectionView.bounds.width
        guard boundsWidth > 1 else { return 0 }
        let insetWidth = boundsWidth
            - collectionView.safeAreaInsets.left
            - collectionView.safeAreaInsets.right
        return max(1, min(insetWidth - AppSpacing.l * 2, ReadableWidth.feed))
    }

    func shouldResetCommentsToHeader(
        oldInput: MomentDetailSnapshotInput?,
        newInput: MomentDetailSnapshotInput,
        oldCommentIDs: [Int],
        newCommentIDs: [Int]
    ) -> Bool {
        guard let oldInput,
              oldInput.section == .comments,
              newInput.section == .comments,
              !oldCommentIDs.isEmpty else { return false }
        if oldInput.headerFingerprint.commentSort != newInput.headerFingerprint.commentSort {
            return true
        }
        if newCommentIDs.isEmpty { return newInput.skeletonCount > 0 }
        if oldCommentIDs == newCommentIDs { return false }
        if newCommentIDs.count > oldCommentIDs.count,
           newCommentIDs.prefix(oldCommentIDs.count).elementsEqual(oldCommentIDs) {
            return false
        }
        let oldSet = Set(oldCommentIDs)
        let newSet = Set(newCommentIDs)
        if newSet.isSubset(of: oldSet) || oldSet.isSubset(of: newSet) {
            let shared = oldSet.intersection(newSet)
            return oldCommentIDs.filter { shared.contains($0) } != newCommentIDs.filter { shared.contains($0) }
        }
        return true
    }

    func applySnapshot(
        reconfigureKeys: [MomentDetailCellKey] = [],
        reconfigureAll: Bool = false,
        resetCommentsToHeader: Bool = false
    ) {
        guard let dataSource, let input = currentInput else { return }
        let currentSnapshot = dataSource.snapshot()
        var snapshot = NSDiffableDataSourceSnapshot<MomentDetailSectionKey, MomentDetailCellKey>()
        if let item {
            snapshot.appendSections([.card, .interactions])
            snapshot.appendItems([.card(item.id)], toSection: .card)
            snapshot.appendItems([.header], toSection: .interactions)
            appendInteractionItems(for: input, to: &snapshot)
        } else {
            snapshot.appendSections([.state])
            snapshot.appendItems([.state], toSection: .state)
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
            var seen: Set<MomentDetailCellKey> = []
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
            return
        }
        let shouldAnchorHeader = resetCommentsToHeader
            && !refreshControl.isRefreshing
            && !collectionView.isTracking
        performWithoutLayoutAnimations {
            if shouldAnchorHeader {
                anchorScrollToInteractionsHeaderIfScrolledPast()
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            if shouldAnchorHeader {
                collectionView.layoutIfNeeded()
                anchorScrollToInteractionsHeaderIfScrolledPast()
            }
        }
    }

    func anchorScrollToInteractionsHeaderIfScrolledPast() {
        guard let headerPath = dataSource?.indexPath(for: .header),
              let attrs = collectionView.layoutAttributesForItem(at: headerPath) else { return }
        let targetY = attrs.frame.minY - collectionView.adjustedContentInset.top
        if collectionView.contentOffset.y > targetY + 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }
    }

    func appendInteractionItems(
        for input: MomentDetailSnapshotInput,
        to snapshot: inout NSDiffableDataSourceSnapshot<MomentDetailSectionKey, MomentDetailCellKey>
    ) {
        switch input.section {
        case .comments:
            if !commentCache.orderedIDs.isEmpty {
                snapshot.appendItems(commentCache.orderedIDs.map { .comment($0) }, toSection: .interactions)
            } else if input.skeletonCount > 0 {
                let skeletons = (0..<input.skeletonCount).map { MomentDetailCellKey.commentSkeleton($0) }
                snapshot.appendItems(skeletons, toSection: .interactions)
            }
        case .forwards:
            snapshot.appendItems(forwardCache.orderedIDs.map { .forward($0) }, toSection: .interactions)
        case .likes:
            snapshot.appendItems(reactionCache.orderedIDs.map { .reaction($0) }, toSection: .interactions)
            if input.showsReactionBanner { snapshot.appendItems([.reactionBanner], toSection: .interactions) }
        }
        if input.footerFingerprint != nil {
            snapshot.appendItems([.footer], toSection: .interactions)
        }
    }

    func computeReconfigureKeys(
        oldInput: MomentDetailSnapshotInput?, newInput: MomentDetailSnapshotInput,
        oldEnv: EnvironmentValues, newEnv: EnvironmentValues,
        oldEdges: SectionEdges
    ) -> [MomentDetailCellKey] {
        guard let oldInput else { return [] }
        if environmentsDiffer(oldEnv, newEnv) {
            return dataSource?.snapshot().itemIdentifiers ?? []
        }
        var keys: [MomentDetailCellKey] = []
        if oldInput.stateFingerprint != newInput.stateFingerprint { keys.append(.state) }
        if let card = newInput.cardFingerprint, oldInput.cardFingerprint != card { keys.append(.card(card.id)) }
        if oldInput.headerFingerprint != newInput.headerFingerprint { keys.append(.header) }
        if oldInput.footerFingerprint != newInput.footerFingerprint { keys.append(.footer) }
        let oldComments = Dictionary(
            oldInput.commentFingerprints.map { ($0.rpid, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for fingerprint in newInput.commentFingerprints where oldComments[fingerprint.rpid] != fingerprint {
            keys.append(.comment(fingerprint.rpid))
        }
        if oldInput.section == newInput.section {
            keys.append(contentsOf: sectionBoundaryReconfigureKeys(section: newInput.section, oldEdges: oldEdges))
        }
        return keys
    }

    func sectionBoundaryReconfigureKeys(
        section: MomentDetailView.InteractionSection,
        oldEdges: SectionEdges
    ) -> [MomentDetailCellKey] {
        switch section {
        case .comments:
            return boundaryReconfigureKeys(
                old: oldEdges.comments,
                new: (commentCache.orderedIDs.first, commentCache.orderedIDs.last),
                cellKey: MomentDetailCellKey.comment
            )
        case .forwards:
            return boundaryReconfigureKeys(
                old: oldEdges.forwards,
                new: (forwardCache.orderedIDs.first, forwardCache.orderedIDs.last),
                cellKey: MomentDetailCellKey.forward
            )
        case .likes:
            return boundaryReconfigureKeys(
                old: oldEdges.reactions,
                new: (reactionCache.orderedIDs.first, reactionCache.orderedIDs.last),
                cellKey: MomentDetailCellKey.reaction
            )
        }
    }

    func boundaryReconfigureKeys<ID: Equatable>(
        old: (first: ID?, last: ID?),
        new: (first: ID?, last: ID?),
        cellKey: (ID) -> MomentDetailCellKey
    ) -> [MomentDetailCellKey] {
        var keys: [MomentDetailCellKey] = []
        if old.first != new.first {
            if let oldFirst = old.first { keys.append(cellKey(oldFirst)) }
            if let newFirst = new.first { keys.append(cellKey(newFirst)) }
        }
        if old.last != new.last {
            if let oldLast = old.last { keys.append(cellKey(oldLast)) }
            if let newLast = new.last { keys.append(cellKey(newLast)) }
        }
        return keys
    }

    func environmentsDiffer(_ lhs: EnvironmentValues, _ rhs: EnvironmentValues) -> Bool {
        lhs.colorScheme != rhs.colorScheme
            || lhs.dynamicTypeSize != rhs.dynamicTypeSize
            || lhs.horizontalSizeClass != rhs.horizontalSizeClass
            || lhs.appSurface != rhs.appSurface
            || lhs.layoutDirection != rhs.layoutDirection
    }

    func triggerPagination(
        index: Int, total: Int, section: MomentDetailView.InteractionSection, lastID: String, action: () -> Void
    ) {
        guard total > 0, index >= max(0, total - 4) else { return }
        let key = PaginationKey(section: section, count: total, lastID: lastID)
        guard lastPaginationKey != key else { return }
        lastPaginationKey = key
        action()
    }

    func scheduleScrollToInteractionsHeader(expectedSection: MomentDetailView.InteractionSection) {
        sectionScrollTask?.cancel()
        sectionScrollTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.currentInput?.section == expectedSection,
                  let indexPath = self.dataSource?.indexPath(for: .header) else { return }
            let visibleBounds = self.collectionView.bounds.inset(by: self.collectionView.adjustedContentInset)
            if self.collectionView.indexPathsForVisibleItems.contains(indexPath),
               let attrs = self.collectionView.layoutAttributesForItem(at: indexPath),
               attrs.frame.intersects(visibleBounds) {
                return
            }
            self.collectionView.layoutIfNeeded()
            self.collectionView.scrollToItem(
                at: indexPath, at: .top, animated: !UIAccessibility.isReduceMotionEnabled
            )
        }
    }

    func syncBottomSafeAreaIfNeeded() {
        let naturalBottom = max(0, view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom)
        let desiredAdditional = max(0, externalBottomSafeAreaInset - naturalBottom)
        guard abs(additionalSafeAreaInsets.bottom - desiredAdditional) > 0.5 else { return }
        performWithoutLayoutAnimations {
            additionalSafeAreaInsets.bottom = desiredAdditional
        }
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.applySnapshot(reconfigureAll: true)
        }
    }

    func applyEnvironmentTraits(_ env: EnvironmentValues) {
        let style: UIUserInterfaceStyle = env.colorScheme == .dark ? .dark : .light
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    func registerTraitObservers() {
        registerForTraitChanges([
            UITraitHorizontalSizeClass.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
        ]) { (self: MomentDetailCollectionViewController, _) in
            self.prefetchCoordinator.cancelAll()
            self.performWithoutLayoutAnimations {
                self.collectionView.collectionViewLayout.invalidateLayout()
            }
            self.scheduleGeometryReconfigure()
        }
    }

    @objc func handleRefreshControl() {
        guard let onRefresh = actions?.onRefresh else { refreshControl.endRefreshing(); return }
        refreshTask?.cancel()
        let token = UUID()
        activeRefreshToken = token
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await onRefresh()
            guard !Task.isCancelled, activeRefreshToken == token else { return }
            activeRefreshToken = nil
            refreshControl.endRefreshing()
        }
    }

    func mediaRequests(for indexPath: IndexPath) -> [UIKitCoverPipeline.CoverRequest] {
        guard let key = dataSource?.itemIdentifier(for: indexPath) else { return [] }
        let scale = max(1, traitCollection.displayScale)
        switch key {
        case .card:
            guard let item else { return [] }
            return UIKitDynamicCardMediaExtractor.coverRequests(
                for: item, cardWidth: readableCardWidth, scale: scale
            )
        case .comment(let rpid):
            guard let comment = commentCache.byID[rpid] else { return [] }
            return UIKitCommentPrefetchExtractor.coverRequests(for: comment, scale: scale)
        case .forward(let id):
            guard let face = forwardCache.byID[id]?.user.face else { return [] }
            let req = UIKitCoverPipeline.avatarRequest(urlString: face, pointSize: 36, scale: scale)
            return req.url != nil ? [req] : []
        case .reaction(let id):
            guard let face = reactionCache.byID[id]?.item.face else { return [] }
            let req = UIKitCoverPipeline.avatarRequest(urlString: face, pointSize: 36, scale: scale)
            return req.url != nil ? [req] : []
        default: return []
        }
    }
}
