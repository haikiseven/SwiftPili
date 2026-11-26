import SwiftUI
import UIKit

struct SearchAllBucketData: Identifiable, Equatable, Sendable {
    let targetType: SearchType
    let items: [SearchResultItemData]
    let totalCount: Int
    let hasMore: Bool

    var id: SearchType { targetType }
}

struct SearchRepresentativeVideoData: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sources: VideoCoverSources
    let durationSeconds: Int
    let playCount: Int
    let routeTarget: VideoRouteTarget?
}

struct SearchResultItemData: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case video(VideoPayload)
        case bangumi(BangumiPayload)
        case user(UserPayload)
        case liveRoom(LivePayload)
        case article(ArticlePayload)
    }

    struct VideoPayload: Equatable, Sendable {
        let title: String
        let sources: VideoCoverSources
        let durationSeconds: Int
        let author: String
        let playCount: Int
        let routeTarget: VideoRouteTarget?
        var aid: Int?
        var bvid: String?
        var ownerMid: Int?
        var ownerFace: String?

        init(
            title: String,
            sources: VideoCoverSources,
            durationSeconds: Int,
            author: String,
            playCount: Int,
            routeTarget: VideoRouteTarget?,
            aid: Int? = nil,
            bvid: String? = nil,
            ownerMid: Int? = nil,
            ownerFace: String? = nil
        ) {
            self.title = title
            self.sources = sources
            self.durationSeconds = durationSeconds
            self.author = author
            self.playCount = playCount
            self.routeTarget = routeTarget
            self.aid = aid
            self.bvid = bvid
            self.ownerMid = ownerMid
            self.ownerFace = ownerFace
        }
    }

    struct BangumiPayload: Equatable, Sendable {
        let seasonID: Int?
        let title: String
        let coverURL: String
        let seasonTypeName: String?
        let score: Double?
        let userCount: Int?
        let areas: String?
        let styles: String?
        let indexShow: String?
        let desc: String
    }

    struct UserPayload: Equatable, Sendable {
        let mid: Int?
        let uname: String
        let avatarURL: String
        let officialVerifyType: Int?
        let officialVerifyDesc: String?
        let fans: Int
        let videos: Int
        let usign: String
        let isLive: Bool
        let representativeVideos: [SearchRepresentativeVideoData]
    }

    struct LivePayload: Equatable, Sendable {
        let roomID: Int?
        let title: String
        let uname: String
        let areaName: String?
        let coverURL: String
        let online: Int
        let liveStatus: Int?
    }

    struct ArticlePayload: Equatable, Sendable {
        let articleID: Int?
        let title: String
        let coverURL: String?
        let author: String
        let categoryName: String?
        let viewCount: Int
        let likeCount: Int
        let desc: String
    }

    let id: String
    let kind: Kind
}

@MainActor
struct SearchResultsActions {
    let isCurrentResult: (UInt64) -> Bool
    let onLoadMore: (UInt64) -> Void
    let onSelectVideo: (VideoRouteTarget) -> Void
    let onSelectLiveRoom: (Int) -> Void
    let onSelectUser: (Int) -> Void
    let onSelectBangumi: (Int) -> Void
    let onSelectArticle: (Int) -> Void
    let onSwitchToType: (SearchType) -> Void
}

@MainActor
struct SearchResultsConfiguration {
    let searchType: SearchType
    let generation: UInt64
    let buckets: [SearchAllBucketData]
    let items: [SearchResultItemData]
    let snapshotRevision: UInt64?
    let isSearching: Bool
    let coverPresentation: CoverPresentation
    let actions: SearchResultsActions
}

enum SearchSectionKey: Hashable, Sendable {
    case bucket(SearchType)
    case results
    case skeletons
    case loadingFooter
}

enum SearchCellKey: Hashable, Sendable {
    case bucketItem(generation: UInt64, bucket: SearchType, id: String)
    case resultItem(generation: UInt64, tab: SearchType, id: String)
    case skeletonRow(Int)
    case skeletonLive(Int)
    case skeletonUser(Int)
    case loadingFooter
}

struct SearchResultsCollectionView: View {
    let searchType: SearchType
    let generation: UInt64
    var buckets: [SearchAllBucketData] = []
    let items: [SearchResultItemData]
    var snapshotRevision: UInt64? = nil
    let isSearching: Bool
    var isActive = true
    var isTabSelected = true
    var scrollToTopTick = 0
    let actions: SearchResultsActions

    var body: some View {
        let config = SearchResultsConfiguration(
            searchType: searchType,
            generation: generation,
            buckets: buckets,
            items: items,
            snapshotRevision: snapshotRevision,
            isSearching: isSearching,
            coverPresentation: CoverPresentationStore.shared.presentation,
            actions: actions
        )
        UIKitCollectionHost(
            isActive: isActive,
            isTabSelected: isTabSelected,
            scrollToTopTick: scrollToTopTick,
            keyboardDismissMode: .onDrag,
            makeController: { SearchResultsCollectionViewController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
final class SearchResultsCollectionViewController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let generation: UInt64
        let count: Int
        let lastID: String?
    }

    var dataSource: UICollectionViewDiffableDataSource<SearchSectionKey, SearchCellKey>?
    var currentSections: [SearchSectionKey] = []
    var searchType: SearchType = .all
    var generation: UInt64 = 0
    var buckets: [SearchAllBucketData] = []
    var bucketByType: [SearchType: SearchAllBucketData] = [:]
    var items: [SearchResultItemData] = []
    var itemByID: [String: SearchResultItemData] = [:]
    var itemIndexByID: [String: Int] = [:]
    private var lastSnapshotRevision: UInt64?
    var isSearching = false
    var coverPresentation = CoverPresentationStore.shared.presentation
    var actions: SearchResultsActions?
    var geometryTask: Task<Void, Never>?

    var videoColumnCount: Int {
        FeedColumnPolicy.columnCount(.videoRow, availableWidth: currentContentWidth)
    }

    var videoColumnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth,
            count: videoColumnCount,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    var liveColumnCount: Int {
        max(1, FeedColumnPolicy.columnCount(.liveGrid, availableWidth: currentContentWidth))
    }

    var liveColumnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: currentContentWidth,
            count: liveColumnCount,
            spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
        )
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = currentSections
            guard sectionIndex < sections.count else { return nil }
            let effectiveWidth = environment.container.effectiveContentSize.width
            let contentWidth = max(1, effectiveWidth - UIKitFeedLayoutMetrics.horizontalInset * 2)
            return layoutSection(
                for: sections[sectionIndex],
                contentWidth: contentWidth,
                traitCollection: environment.traitCollection,
                isFirst: sectionIndex == 0,
                isLast: sectionIndex == sections.count - 1
            )
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot()
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldVideoCols = FeedColumnPolicy.columnCount(.videoRow, availableWidth: oldWidth)
        let oldLiveCols = FeedColumnPolicy.columnCount(.liveGrid, availableWidth: oldWidth)
        let widthChanged = abs(newWidth - lastReconfiguredWidth) > 1.5
        guard oldVideoCols != videoColumnCount || oldLiveCols != liveColumnCount || widthChanged else { return }
        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    func update(_ config: SearchResultsConfiguration) {
        actions = config.actions
        let generationChanged = config.generation != generation
        let typeChanged = config.searchType != searchType
        let presentationChanged = config.coverPresentation != coverPresentation
        let dataChanged: Bool
        let bucketsChanged: Bool
        if let incomingRev = config.snapshotRevision, let currentRev = lastSnapshotRevision,
           incomingRev == currentRev {
            dataChanged = false
            bucketsChanged = false
        } else {
            bucketsChanged = config.buckets != buckets
            dataChanged = bucketsChanged || config.items != items
        }
        guard generationChanged || typeChanged || presentationChanged || dataChanged
            || config.isSearching != isSearching else { return }

        let previousCount = items.count
        let previousLastID = items.last?.id
        let previousByID = itemByID
        applyIncomingConfig(config, dataChanged: dataChanged)

        if generationChanged || typeChanged || items.count != previousCount {
            if generationChanged || typeChanged { prefetchCoordinator.cancelAll() }
            resetPaginationGate()
        }
        guard isViewLoaded else { return }
        if typeChanged || generationChanged || presentationChanged || bucketsChanged {
            collectionView.collectionViewLayout.invalidateLayout()
        }

        let reconfigureKeys = changedCellKeys(
            generationChanged: generationChanged,
            typeChanged: typeChanged,
            presentationChanged: presentationChanged,
            dataChanged: dataChanged,
            previousByID: previousByID,
            previousLastID: items.count > previousCount ? previousLastID : nil
        )
        applySnapshot(reconfigureKeys: reconfigureKeys, reconfigureSkeletons: typeChanged || presentationChanged)
        if generationChanged || typeChanged { scrollToTop(animated: false) }
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        super.tearDown()
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        item(at: indexPath) != nil
    }

    override func didSelectItem(at indexPath: IndexPath) {
        guard let actions, actions.isCurrentResult(generation), let item = item(at: indexPath) else { return }
        routeSelection(for: item.kind, actions: actions)
    }

    @objc func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = item(at: indexPath),
              case .video(let payload) = item.kind else {
            return nil
        }
        let resolvedAID: Int? = {
            if let aid = payload.aid, aid > 0 { return aid }
            if case .aid(let aid) = payload.routeTarget?.videoID, aid > 0 { return aid }
            return nil
        }()
        let resolvedBVID: String? = {
            if let bvid = payload.bvid, !bvid.isEmpty { return bvid }
            if case .bvid(let bvid) = payload.routeTarget?.videoID, !bvid.isEmpty { return bvid }
            return nil
        }()
        let target = VideoCardContextMenuTarget(
            aid: resolvedAID,
            bvid: resolvedBVID,
            title: payload.title,
            ownerMid: payload.ownerMid,
            ownerName: payload.author,
            ownerFace: payload.ownerFace
        )
        return VideoCardContextMenuBuilder.configuration(for: target)
    }

    private func routeSelection(for kind: SearchResultItemData.Kind, actions: SearchResultsActions) {
        switch kind {
        case .video(let payload): payload.routeTarget.map(actions.onSelectVideo)
        case .bangumi(let payload): payload.seasonID.map(actions.onSelectBangumi)
        case .user(let payload): payload.mid.map(actions.onSelectUser)
        case .liveRoom(let payload): payload.roomID.map(actions.onSelectLiveRoom)
        case .article(let payload): payload.articleID.map(actions.onSelectArticle)
        }
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard !isSearching, let actions, actions.isCurrentResult(generation),
              let cellKey = dataSource?.itemIdentifier(for: indexPath),
              case .resultItem(_, _, let id) = cellKey,
              let index = itemIndexByID[id] else { return }
        let key = PaginationKey(generation: generation, count: items.count, lastID: items.last?.id)
        let activeGeneration = generation
        triggerNearEndPaginationIfNeeded(index: index, totalCount: items.count, key: key, thresholdOffset: 4) {
            actions.onLoadMore(activeGeneration)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] indexPath in
            self?.coverRequest(for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }

    func showsUserSeparator(at indexPath: IndexPath) -> Bool {
        guard indexPath.section < currentSections.count else { return false }
        let sectionItems: [SearchResultItemData]
        switch currentSections[indexPath.section] {
        case .bucket(let bucketType):
            sectionItems = bucketByType[bucketType]?.items ?? []
        case .results:
            sectionItems = items
        case .skeletons, .loadingFooter:
            return false
        }
        let nextIndex = indexPath.item + 1
        guard nextIndex < sectionItems.count else { return false }
        if case .user(let nextPayload) = sectionItems[nextIndex].kind,
           !nextPayload.representativeVideos.isEmpty {
            return false
        }
        return true
    }

    func sectionHasRepresentativeVideos(for entityType: SearchType) -> Bool {
        guard entityType == .user else { return false }
        let userItems = searchType == .all ? (bucketByType[.user]?.items ?? []) : items
        return userItems.contains { item in
            guard case .user(let payload) = item.kind else { return false }
            return !payload.representativeVideos.isEmpty
        }
    }

    private func applyIncomingConfig(_ config: SearchResultsConfiguration, dataChanged: Bool) {
        searchType = config.searchType
        generation = config.generation
        lastSnapshotRevision = config.snapshotRevision
        isSearching = config.isSearching
        coverPresentation = config.coverPresentation

        guard dataChanged else { return }
        buckets = config.buckets
        bucketByType = Dictionary(uniqueKeysWithValues: buckets.map { ($0.targetType, $0) })
        items = config.items

        var combined: [String: SearchResultItemData] = [:]
        combined.reserveCapacity(items.count + buckets.reduce(0) { $0 + $1.items.count })
        for bucket in buckets {
            for item in bucket.items { combined[item.id] = item }
        }
        for item in items { combined[item.id] = item }
        itemByID = combined
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func changedCellKeys(
        generationChanged: Bool,
        typeChanged: Bool,
        presentationChanged: Bool,
        dataChanged: Bool,
        previousByID: [String: SearchResultItemData],
        previousLastID: String?
    ) -> [SearchCellKey] {
        guard !generationChanged, !typeChanged, (presentationChanged || dataChanged) else { return [] }
        var keys: [SearchCellKey] = []
        for bucket in buckets {
            for item in bucket.items where presentationChanged || previousByID[item.id] != item {
                keys.append(.bucketItem(generation: generation, bucket: bucket.targetType, id: item.id))
            }
        }
        for item in items where presentationChanged || item.id == previousLastID || previousByID[item.id] != item {
            keys.append(.resultItem(generation: generation, tab: searchType, id: item.id))
        }
        return keys
    }
}

@MainActor
final class SearchBucketDisclosureFooterView: UICollectionReusableView {
    private let button = UIButton(type: .system)
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    func configure(title: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        let traits = traitCollection
        let font = UIKitFeedFont.systemFont(textStyle: .subheadline, weight: .medium, traitCollection: traits)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        config.baseForegroundColor = UIColor(AccentStore.shared.semanticAccent)
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font]))
        config.image = UIImage(systemName: "chevron.right")
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font, scale: .small)
        button.configuration = config
        button.accessibilityLabel = title
    }

    @objc private func handleTap() {
        onTap?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }
}

@MainActor
final class SearchPaginationSpinnerCell: UICollectionViewCell {
    private let indicator = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isUserInteractionEnabled = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            indicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            indicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure() { if !indicator.isAnimating { indicator.startAnimating() } }
    override func prepareForReuse() { super.prepareForReuse(); indicator.stopAnimating() }
}
