import SwiftUI
import UIKit

/// Pure UIKit `UICollectionView` backing `UserSpaceView`'s scrolling canvas,
/// video/article/archive grids, 3:4 bangumi poster grid, and SwiftUI shelves.
struct UserSpaceFeedCollectionView: View {
    let mid: Int
    let viewModel: UserSpaceViewModel
    let headerIdentityKey: String
    let actions: UserSpaceFeedActions

    var body: some View {
        let presentation = CoverPresentationStore.shared.presentation
        let trigger = UserSpaceFeedTrigger(
            viewModel: viewModel, headerIdentityKey: headerIdentityKey, coverPresentation: presentation
        )
        UIKitCollectionHost(
            onRefresh: actions.onRefresh,
            makeController: { UserSpaceFeedCollectionViewController(mid: mid, viewModel: viewModel) },
            updateController: { controller in
                controller.update(mid: mid, viewModel: viewModel, trigger: trigger, actions: actions)
            }
        )
    }
}

@MainActor
private final class UserSpaceFeedCollectionViewController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let tab: UserSpaceTab
        let subMode, count: Int
        let lastID: String?
    }

    private var mid: Int
    private var viewModel: UserSpaceViewModel
    private var trigger: UserSpaceFeedTrigger?
    private var actions: UserSpaceFeedActions?
    private var dataSource: UICollectionViewDiffableDataSource<UserSpaceSectionKey, UserSpaceCellKey>?
    private var videoEntries: [String: (UIKitGridVideoCell.Model, UserSpaceVideoAction)] = [:]
    private var activeIndexByID: [String: Int] = [:]
    private var bangumiByID: [Int: BangumiFollowResult.FollowedBangumi] = [:]
    private var favoriteByID: [Int: FavoriteFolderResult.FavoriteFolder] = [:]
    private var dynamicByID: [String: DynamicFeedResult.DynamicItem] = [:]
    private var dynamicIndexByID: [String: Int] = [:]
    private var lastInlineTitleVisible = false
    private var geometryTask: Task<Void, Never>?

    init(mid: Int, viewModel: UserSpaceViewModel) {
        self.mid = mid
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var videoCols: Int { FeedColumnPolicy.columnCount(.videoGrid, availableWidth: currentContentWidth) }
    var videoColWidth: CGFloat { colWidth(for: videoCols) }
    var posterCols: Int { FeedColumnPolicy.pgcPosterColumnCount(availableWidth: currentContentWidth) }
    var posterColWidth: CGFloat { colWidth(for: posterCols) }
    var fullWidth: CGFloat { currentContentWidth + UIKitFeedLayoutMetrics.horizontalInset * 2 }
    var dynamicCardWidth: CGFloat { ReadableWidth.capped(currentContentWidth, to: ReadableWidth.feed) }

    private func colWidth(for count: Int) -> CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth, count: count, spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            let inset = UIKitFeedLayoutMetrics.horizontalInset * 2
            let width = max(1, environment.container.effectiveContentSize.width - inset)
            let isLast = sectionIndex == sections.count - 1
            return makeSectionLayout(sections[sectionIndex], contentWidth: width, isLast: isLast)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot()
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldGrid = FeedColumnPolicy.columnCount(.videoGrid, availableWidth: oldWidth)
        let oldPoster = FeedColumnPolicy.pgcPosterColumnCount(availableWidth: oldWidth)
        guard oldGrid != videoCols || oldPoster != posterCols || abs(newWidth - lastReconfiguredWidth) > 1.5 else {
            return
        }
        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() { scheduleGeometryReconfigure() }
    override func tearDown() { geometryTask?.cancel(); geometryTask = nil; super.tearDown() }

    func update(
        mid: Int, viewModel: UserSpaceViewModel, trigger newTrigger: UserSpaceFeedTrigger, actions: UserSpaceFeedActions
    ) {
        self.mid = mid; self.viewModel = viewModel; self.actions = actions
        let oldTrigger = trigger
        guard oldTrigger != newTrigger else { return }
        trigger = newTrigger
        rebuildCaches()
        if oldTrigger?.selectedTab != newTrigger.selectedTab || oldTrigger?.showsArticles != newTrigger.showsArticles {
            resetPaginationGate()
            prefetchCoordinator.cancelAll()
        }
        if let oldTrigger, oldTrigger.coverPresentation != newTrigger.coverPresentation {
            prefetchCoordinator.cancelAll()
            collectionView.collectionViewLayout.invalidateLayout()
        }
        guard isViewLoaded else { return }
        applySnapshot(
            reconfigureHeader: oldTrigger?.headerIdentityKey != newTrigger.headerIdentityKey,
            reconfigureGrid: oldTrigger?.coverPresentation != newTrigger.coverPresentation
        )
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        switch dataSource?.itemIdentifier(for: indexPath) {
        case .video, .bangumi: true
        default: false
        }
    }

    @objc(collectionView:shouldHighlightItemAtIndexPath:)
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        shouldSelectItem(at: indexPath)
    }

    override func didSelectItem(at indexPath: IndexPath) {
        guard let actions, let key = dataSource?.itemIdentifier(for: indexPath) else { return }
        switch key {
        case .video(let itemID):
            switch videoEntries[itemID]?.1 {
            case .video(let target): if let target { actions.onSelectVideo(target) }
            case .article(let articleID): actions.onNavigate(.articleReader(articleID))
            case nil: break
            }
        case .bangumi(let seasonID): actions.onNavigate(.bangumiDetail(seasonID, zoom: .none))
        default: break
        }
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard let key = dataSource?.itemIdentifier(for: indexPath) else { return }
        if case .video(let itemID) = key, viewModel.selectedTab == .video, let index = activeIndexByID[itemID] {
            let articles = viewModel.showsArticles
            guard articles ? viewModel.articlesHaveMore : viewModel.videosHaveMore else { return }
            let count = articles ? viewModel.userArticles.count : viewModel.userVideos.count
            let lastID = articles ? viewModel.userArticles.last.map { "a:\($0.id)" }
                : viewModel.userVideos.last.map { "v:\($0.aid)" }
            let pageKey = PaginationKey(tab: .video, subMode: articles ? 1 : 0, count: count, lastID: lastID)
            triggerNearEndPaginationIfNeeded(index: index, totalCount: count, key: pageKey) { [weak self] in
                Task { [weak self] in
                    guard let self else { return }
                    if articles { await self.viewModel.loadMoreArticles(mid: self.mid) } else {
                        await self.viewModel.loadMoreVideos(mid: self.mid)
                    }
                }
            }
        } else if case .dynamic(let itemID) = key, viewModel.selectedTab == .dynamic,
                  viewModel.dynamicsHasMore, let index = dynamicIndexByID[itemID] {
            let count = viewModel.userDynamics.count
            let lastID = viewModel.userDynamics.last.map { DynamicsViewModel.stableItemID($0) }
            let pageKey = PaginationKey(tab: .dynamic, subMode: 0, count: count, lastID: lastID)
            triggerNearEndPaginationIfNeeded(index: index, totalCount: count, key: pageKey, thresholdOffset: 2) {
                Task { [weak self] in
                    guard let self else { return }
                    await self.viewModel.loadMoreDynamics(mid: self.mid)
                }
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let passed = scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 88
        guard passed != lastInlineTitleVisible else { return }
        lastInlineTitleVisible = passed
        Task { @MainActor [weak self] in self?.actions?.onInlineTitleChange(passed) }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] in self?.coverRequests(for: $0) ?? [] }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }
}

private extension UserSpaceFeedCollectionViewController {
    struct CellRegistrations {
        let hosted: UICollectionView.CellRegistration<UICollectionViewCell, AnyView>
        let videoGrid: UICollectionView.CellRegistration<UIKitGridVideoCell, UIKitGridVideoCell.Model>
        let posterGrid: UICollectionView.CellRegistration<UIKitPosterCardCell, UIKitPosterCardCell.Model>
        let dynamicCard: UICollectionView.CellRegistration<UIKitDynamicCardCell, UIKitDynamicCardCell.Model>
        let skeleton: UICollectionView.CellRegistration<UIKitGridSkeletonCell, UserSpaceCellKey.SkeletonKind>
        let rowSkeleton: UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int>
        let dynamicSkeleton: UICollectionView.CellRegistration<UIKitDynamicSkeletonCell, Int>
    }

    var activePresentation: CoverPresentation {
        trigger?.coverPresentation ?? CoverPresentation(aspect: .current, display: .current)
    }

    func rebuildCaches() {
        let activeTrigger = trigger ?? UserSpaceFeedTrigger(
            viewModel: viewModel, headerIdentityKey: "", coverPresentation: activePresentation
        )
        videoEntries = activeTrigger.buildVideoEntries(viewModel: viewModel, colWidth: videoColWidth)
        let activeIDs = viewModel.showsArticles
            ? viewModel.userArticles.map { "a:\($0.id)" }
            : viewModel.userVideos.map { "v:\($0.aid)" }
        activeIndexByID = keyed(activeIDs.enumerated().map { ($0.element, $0.offset) })
        bangumiByID = keyed(viewModel.userBangumi.map { ($0.seasonId, $0) })
        favoriteByID = keyed(viewModel.userFavorites.map { ($0.id, $0) })
        let dynamics = viewModel.userDynamics.enumerated().map {
            (DynamicsViewModel.stableItemID($0.element), $0.element, $0.offset)
        }
        dynamicByID = keyed(dynamics.map { ($0.0, $0.1) })
        dynamicIndexByID = keyed(dynamics.map { ($0.0, $0.2) })
    }

    func keyed<K: Hashable, V>(_ pairs: [(K, V)]) -> [K: V] {
        Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    func configureDataSource() {
        let regs = makeCellRegistrations()
        dataSource = UICollectionViewDiffableDataSource<UserSpaceSectionKey, UserSpaceCellKey>(
            collectionView: collectionView
        ) { [weak self] collection, indexPath, key in
            self?.dequeueCell(in: collection, at: indexPath, for: key, regs: regs)
        }
    }

    func makeCellRegistrations() -> CellRegistrations {
        typealias GridSk = UICollectionView.CellRegistration<UIKitGridSkeletonCell, UserSpaceCellKey.SkeletonKind>
        let hosted = UICollectionView.CellRegistration<UICollectionViewCell, AnyView> { cell, _, content in
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0).background(.clear)
        }
        let videoGrid = UICollectionView.CellRegistration<UIKitGridVideoCell, UIKitGridVideoCell.Model> {
            $0.configure($2) }
        let posterGrid = UICollectionView.CellRegistration<UIKitPosterCardCell, UIKitPosterCardCell.Model> {
            $0.configure($2) }
        let dynamicCard = UICollectionView.CellRegistration<UIKitDynamicCardCell, UIKitDynamicCardCell.Model> {
            $0.configure($2) }
        let skeleton = GridSk { [weak self] cell, indexPath, kind in
            self?.configureGridSkeleton(cell, isFirst: indexPath.item == 0, kind: kind)
        }
        let rowSkeleton = UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int> { [weak self] cell, _, index in
            guard let self else { return }
            let fav = String(localized: "Favorites")
            let label = index == 0 ? String(format: String(localized: "Loading %@"), fav) : nil
            cell.configure(
                style: .library, columnWidth: fullWidth,
                coverPresentation: activePresentation, accessibilityLabel: label
            )
        }
        let dynamicSkeleton = UICollectionView.CellRegistration<UIKitDynamicSkeletonCell, Int> { cell, _, index in
            let label = index == 0 ? String(localized: "Loading moments") : nil
            cell.configure(showsCardBackground: true, accessibilityLabel: label)
        }
        return CellRegistrations(
            hosted: hosted, videoGrid: videoGrid, posterGrid: posterGrid, dynamicCard: dynamicCard,
            skeleton: skeleton, rowSkeleton: rowSkeleton, dynamicSkeleton: dynamicSkeleton
        )
    }

    func configureGridSkeleton(_ cell: UIKitGridSkeletonCell, isFirst: Bool, kind: UserSpaceCellKey.SkeletonKind) {
        if kind == .video {
            let label = isFirst ? String(format: String(localized: "Loading %@"), String(localized: "Videos")) : nil
            cell.configure(columnWidth: videoColWidth, coverPresentation: activePresentation, accessibilityLabel: label)
        } else if kind == .poster {
            let label = isFirst ? String(format: String(localized: "Loading %@"), String(localized: "Anime")) : nil
            cell.configurePoster(columnWidth: posterColWidth, accessibilityLabel: label)
        }
    }

    func dequeueCell(
        in collection: UICollectionView, at indexPath: IndexPath, for key: UserSpaceCellKey, regs: CellRegistrations
    ) -> UICollectionViewCell? {
        switch key {
        case .video(let id):
            guard let model = videoEntries[id]?.0 else { return nil }
            return collection.dequeueConfiguredReusableCell(using: regs.videoGrid, for: indexPath, item: model)
        case .bangumi(let id):
            guard let season = bangumiByID[id] else { return nil }
            return collection.dequeueConfiguredReusableCell(
                using: regs.posterGrid, for: indexPath, item: makePosterModel(season)
            )
        case .dynamic(let id):
            guard let item = dynamicByID[id] else { return nil }
            return collection.dequeueConfiguredReusableCell(
                using: regs.dynamicCard, for: indexPath, item: makeDynamicCardModel(for: item)
            )
        case .skeleton(let kind, let index):
            return dequeueSkeletonCell(in: collection, at: indexPath, kind: kind, index: index, regs: regs)
        default:
            guard let view = hostedView(for: key) else { return nil }
            return collection.dequeueConfiguredReusableCell(using: regs.hosted, for: indexPath, item: view)
        }
    }

    func dequeueSkeletonCell(
        in collection: UICollectionView, at indexPath: IndexPath,
        kind: UserSpaceCellKey.SkeletonKind, index: Int, regs: CellRegistrations
    ) -> UICollectionViewCell {
        switch kind {
        case .row: return collection.dequeueConfiguredReusableCell(using: regs.rowSkeleton, for: indexPath, item: index)
        case .dynamic:
            return collection.dequeueConfiguredReusableCell(using: regs.dynamicSkeleton, for: indexPath, item: index)
        case .video, .poster:
            return collection.dequeueConfiguredReusableCell(using: regs.skeleton, for: indexPath, item: kind)
        }
    }

    func makePosterModel(_ season: BangumiFollowResult.FollowedBangumi) -> UIKitPosterCardCell.Model {
        let meta = [season.progressText, season.newEpShow]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return UIKitPosterCardCell.Model(
            title: season.title ?? "", meta: meta, coverURL: season.cover ?? "", badge: nil,
            cardWidth: posterColWidth, displayMode: .fill, requestsServerCrop: true, titleRole: .cardTitle
        )
    }

    func makeDynamicCardModel(for item: DynamicFeedResult.DynamicItem) -> UIKitDynamicCardCell.Model {
        let postID = item.idStr.flatMap { $0.isEmpty ? nil : $0 }
        let cardActions = UIKitDynamicCardCell.Actions(
            onOpenPost: postID.map { id in { [weak self] in self?.actions?.onNavigate(.momentDetail(id)) } },
            onOpenQuotedPost: { [weak self] id in self?.actions?.onNavigate(.momentDetail(id)) },
            onOpenProfile: { [weak self] mid in self?.actions?.onNavigate(.userSpace(mid)) },
            onOpenVideo: { [weak self] target in self?.actions?.onSelectVideo(target) },
            onOpenArticle: { [weak self] id in self?.actions?.onNavigate(.articleReader(id)) },
            onOpenLiveRoom: { [weak self] id in self?.actions?.onNavigate(.liveRoom(id)) },
            onOpenURL: { [weak self] url in self?.actions?.onOpenURL(url) },
            onImageTap: { [weak self] preview in self?.actions?.onPreviewImages(preview) },
            onRepost: { [weak self] in self?.actions?.onRepostDynamic(item) },
            onComment: { [weak self] in self?.actions?.onCommentDynamic(item) }
        )
        return UIKitDynamicCardCell.Model(
            item: item, interactionStore: actions?.interactionStore,
            fallbackLikeState: actions?.interactionStore.likeState(for: item) ?? (false, 0),
            availableWidth: dynamicCardWidth, actions: cardActions
        )
    }

    func hostedView(for key: UserSpaceCellKey) -> AnyView? {
        guard let actions else { return nil }
        switch key {
        case .profileHeader: return actions.makeProfileHeader()
        case .submissionFilter: return actions.makeSubmissionFilter()
        case .shelfHeader(let kind): return actions.makeShelfHeader(kind)
        case .favoriteFolder(let id, let div):
            return favoriteByID[id].map { actions.makeFavoriteRow($0, fullWidth, div) }
        case .paginationSpinner:
            return AnyView(ProgressView().frame(maxWidth: .infinity).padding(.vertical, AppSpacing.l))
        case .feedback(let kind): return actions.makeFeedbackView(kind)
        default: return nil
        }
    }

    func makeSectionLayout(
        _ key: UserSpaceSectionKey, contentWidth: CGFloat, isLast: Bool
    ) -> NSCollectionLayoutSection {
        let bottom = isLast ? UIKitFeedLayoutMetrics.bottomInset : 0
        let hInset = UIKitFeedLayoutMetrics.horizontalInset
        switch key {
        case .profileHeader: return layoutSection(est: 240, insetH: 0, bottom: AppSpacing.m)
        case .submissionFilter: return layoutSection(est: 44, insetH: hInset, bottom: AppSpacing.s)
        case .shelfHeader: return layoutSection(est: 44, insetH: hInset, top: AppSpacing.xs, bottom: AppSpacing.xs)
        case .shelfVideos, .videoGrid:
            let count = max(1, FeedColumnPolicy.columnCount(.videoGrid, availableWidth: contentWidth))
            let est = activePresentation.height(forWidth: max(1, videoColWidth)) + 68
            return layoutSection(
                count: count, est: max(80, est), insetH: hInset,
                bottom: key == .shelfVideos ? AppSpacing.xl : bottom, spacing: UIKitFeedLayoutMetrics.gridRowSpacing
            )
        case .posterGrid:
            let count = max(1, FeedColumnPolicy.pgcPosterColumnCount(availableWidth: contentWidth))
            let est = max(80, (max(1, posterColWidth) * 4 / 3).rounded() + 58)
            return layoutSection(count: count, est: est, insetH: hInset, bottom: bottom, spacing: 16)
        case .shelfMoments:
            let side = centeredReadableInset(for: contentWidth)
            return layoutSection(est: 220, insetH: side, trailingH: side, bottom: AppSpacing.xl, spacing: AppSpacing.m)
        case .shelfFavorites: return layoutSection(est: 180, insetH: 0, bottom: bottom)
        case .list:
            let isFav = viewModel.selectedTab == .favorite
            let sideInset = isFav ? 0 : centeredReadableInset(for: contentWidth)
            return layoutSection(
                est: isFav ? 180 : 220, insetH: sideInset, trailingH: sideInset,
                top: isFav ? 0 : AppSpacing.xs, bottom: bottom, spacing: isFav ? 0 : AppSpacing.m
            )
        case .footer: return layoutSection(est: 80, insetH: hInset, top: AppSpacing.s, bottom: bottom)
        }
    }

    private func centeredReadableInset(for contentWidth: CGFloat) -> CGFloat {
        let readable = ReadableWidth.capped(contentWidth, to: ReadableWidth.feed)
        return UIKitFeedLayoutMetrics.horizontalInset + max(0, ((contentWidth - readable) / 2).rounded(.down))
    }
    func layoutSection(
        count: Int = 1, est: CGFloat, insetH: CGFloat, trailingH: CGFloat? = nil,
        top: CGFloat = 0, bottom: CGFloat = 0, spacing: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(count)), heightDimension: .estimated(est)
        )
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(est))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = count == 1
            ? NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            : NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: count)
        if count > 1 { group.interItemSpacing = .fixed(UIKitFeedLayoutMetrics.gridColumnSpacing) }
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: top, leading: insetH, bottom: bottom, trailing: trailingH ?? insetH
        )
        return section
    }

    func applySnapshot(reconfigureHeader: Bool = false, reconfigureGrid: Bool = false, reconfigureAll: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<UserSpaceSectionKey, UserSpaceCellKey>()
        snapshot.appendSections([.profileHeader])
        snapshot.appendItems([.profileHeader], toSection: .profileHeader)
        let activeTrigger = trigger ?? UserSpaceFeedTrigger(
            viewModel: viewModel, headerIdentityKey: "", coverPresentation: activePresentation
        )
        var seen = Set(snapshot.itemIdentifiers)
        for (section, keys) in activeTrigger.buildSections(
            viewModel: viewModel, videoCols: videoCols, posterCols: posterCols
        ) {
            let unique = keys.filter { seen.insert($0).inserted }
            guard !unique.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(unique, toSection: section)
        }
        if reconfigureAll {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        } else {
            var targets: [UserSpaceCellKey] = reconfigureHeader ? [.profileHeader] : []
            if reconfigureGrid {
                targets.append(contentsOf: snapshot.itemIdentifiers.filter {
                    if case .video = $0 { return true }
                    if case .skeleton(let kind, _) = $0 { return kind == .video || kind == .poster }
                    return false
                })
            }
            if !targets.isEmpty { snapshot.reconfigureItems(targets) }
        }
        lastReconfiguredWidth = currentContentWidth
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            rebuildCaches()
            applySnapshot(reconfigureAll: true)
        }
    }

    func coverRequests(for indexPath: IndexPath) -> [UIKitCoverPipeline.CoverRequest] {
        guard let key = dataSource?.itemIdentifier(for: indexPath) else { return [] }
        let scale = traitCollection.displayScale
        switch key {
        case .video(let itemID):
            guard let model = videoEntries[itemID]?.0 else { return [] }
            let box = activePresentation.size(width: max(1, videoColWidth))
            return [UIKitCoverPipeline.request(
                sources: model.sources, drawnBox: box, presentation: activePresentation, scale: scale
            )]
        case .bangumi(let seasonID):
            guard let season = bangumiByID[seasonID] else { return [] }
            let width = max(1, posterColWidth)
            let box = CGSize(width: width, height: (width * 4 / 3).rounded())
            return [UIKitCoverPipeline.request(
                urlString: season.cover ?? "", drawnBox: box, displayMode: .fill, requestsServerCrop: true, scale: scale
            )]
        case .dynamic(let itemID):
            guard let item = dynamicByID[itemID] else { return [] }
            return UIKitDynamicCardMediaExtractor.coverRequests(for: item, cardWidth: dynamicCardWidth, scale: scale)
        default: return []
        }
    }
}
