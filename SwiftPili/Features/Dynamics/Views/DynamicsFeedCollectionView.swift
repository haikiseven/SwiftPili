import SwiftUI
import UIKit

struct DynamicsPeopleHeaderState: Equatable {
    let people: [DynamicFollowingPerson]
    let selectedMID: Int?
    let selectedPerson: DynamicFollowingPerson?
    let viewingPersonName: String?
    let isLoading, hasLoaded, hasMore: Bool
    let failure: String?
    let usesAccessibilityLayout: Bool
}

enum DynamicsEmptyFeedbackState: Equatable, Hashable, Sendable {
    case none, signIn
    case error(String)
    case empty(DynamicFeedSelection)
}

struct DynamicsItemFingerprint: Equatable {
    let stableID: String
    let likeCount, commentCount, forwardCount: Int?
    let liked: Bool?

    init(_ item: DynamicFeedResult.DynamicItem) {
        stableID = DynamicsViewModel.stableItemID(item)
        let stat = item.modules?.moduleStat
        likeCount = stat?.like?.count
        liked = stat?.like?.status
        commentCount = stat?.comment?.count
        forwardCount = stat?.forward?.count
    }
}

struct DynamicsFeedCollectionActions {
    let onRefresh: @MainActor () async -> Bool
    let onNearEndAppear: () -> Void
    let onOpenPost: (String) -> Void
    let onOpenProfile: (Int) -> Void
    let onOpenVideo: (VideoRouteTarget) -> Void
    let onOpenArticle: (Int) -> Void
    let onOpenLiveRoom: (Int) -> Void
    let onImageTap: (ImagePreviewItem) -> Void
    let onRepost: (DynamicFeedResult.DynamicItem) -> Void
    let onComment: (DynamicFeedResult.DynamicItem) -> Void
    let onLike: (DynamicFeedResult.DynamicItem) -> Void
    let makePeopleHeader: (DynamicsPeopleHeaderState) -> AnyView
    let makeFeedbackView: (DynamicsEmptyFeedbackState) -> AnyView
}

struct DynamicsFeedCollectionView: View {
    let items: [DynamicFeedResult.DynamicItem]
    let interactionStore: MomentInteractionStore
    let peopleHeader: DynamicsPeopleHeaderState?
    let inlineFeedback: DynamicsEmptyFeedbackState
    let placeholderCount: Int
    let showsPaginationSpinner: Bool
    let isActive: Bool
    let isDynamicsTabSelected: Bool
    let scrollToTopTick: Int
    let actions: DynamicsFeedCollectionActions

    @Environment(\.openURL) private var openURL

    var body: some View {
        let fingerprints = items.map(DynamicsItemFingerprint.init)
        UIKitCollectionHost(
            isActive: isActive,
            isTabSelected: isDynamicsTabSelected,
            scrollToTopTick: scrollToTopTick,
            onRefresh: actions.onRefresh,
            makeController: { DynamicsFeedCollectionViewController() },
            updateController: { controller in
                controller.update(view: self, fingerprints: fingerprints, onOpenURL: { openURL($0) })
            }
        )
    }
}

private enum DynamicsSectionKey: Hashable, Sendable {
    case peopleHeader, items, skeletons, feedback, footer
}

private enum DynamicsCellKey: Hashable, Sendable {
    case peopleHeader
    case item(String)
    case skeleton(Int)
    case feedback(DynamicsEmptyFeedbackState)
    case footerSpinner
}

@MainActor
private final class DynamicsLoadingFooterCell: UICollectionViewCell {
    private let indicator = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = false
        contentView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            indicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: AppSpacing.xl),
            indicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -AppSpacing.xl),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure() { if !indicator.isAnimating { indicator.startAnimating() } }
    override func prepareForReuse() { super.prepareForReuse(); indicator.stopAnimating() }
}

@MainActor
private final class DynamicsFeedCollectionViewController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let count: Int
        let lastID: String?
    }

    private var dataSource: UICollectionViewDiffableDataSource<DynamicsSectionKey, DynamicsCellKey>?
    private var items: [DynamicFeedResult.DynamicItem] = []
    private var fingerprints: [DynamicsItemFingerprint] = []
    private var fingerprintByID: [String: DynamicsItemFingerprint] = [:]
    private var itemByID: [String: DynamicFeedResult.DynamicItem] = [:]
    private var itemIndexByID: [String: Int] = [:]
    private var orderedItemIDs: [String] = []
    private var interactionStore: MomentInteractionStore?
    private var peopleHeader: DynamicsPeopleHeaderState?
    private var inlineFeedback: DynamicsEmptyFeedbackState = .none
    private var placeholderCount = 0
    private var showsPaginationSpinner = false
    private var onOpenURL: ((URL) -> Void)?
    private var actions: DynamicsFeedCollectionActions?
    private var geometryTask: Task<Void, Never>?

    override var layoutHorizontalInset: CGFloat { AppSpacing.m }
    override var allowsSelectionHighlight: Bool { false }

    private var readableCardWidth: CGFloat {
        max(1, min(currentContentWidth, ReadableWidth.feed - AppSpacing.m * 2))
    }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            let next: DynamicsSectionKey? = sectionIndex + 1 < sections.count ? sections[sectionIndex + 1] : nil
            return makeSectionLayout(
                sections[sectionIndex], effectiveWidth: environment.container.effectiveContentSize.width,
                isFirst: sectionIndex == 0, nextSection: next
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
        let oldReadable = min(oldWidth, ReadableWidth.feed - AppSpacing.m * 2)
        guard abs(readableCardWidth - oldReadable) > 0.5 || abs(newWidth - lastReconfiguredWidth) > 1.5 else { return }
        prefetchCoordinator.cancelAll()
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() { scheduleGeometryReconfigure() }
    override func tearDown() { geometryTask?.cancel(); geometryTask = nil; super.tearDown() }
    override func shouldSelectItem(at indexPath: IndexPath) -> Bool { false }

    @objc(collectionView:shouldHighlightItemAtIndexPath:)
    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAtIndexPath indexPath: IndexPath
    ) -> Bool { false }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard isHostActive,
              let cellKey = dataSource?.itemIdentifier(for: indexPath),
              case .item(let id) = cellKey,
              let index = itemIndexByID[id] else { return }
        let key = PaginationKey(count: items.count, lastID: orderedItemIDs.last)
        triggerNearEndPaginationIfNeeded(
            index: index, totalCount: items.count, key: key, thresholdOffset: 4,
            action: { [weak self] in self?.actions?.onNearEndAppear() }
        )
    }

    func update(
        view: DynamicsFeedCollectionView,
        fingerprints newFingerprints: [DynamicsItemFingerprint],
        onOpenURL newOpenURL: @escaping (URL) -> Void
    ) {
        actions = view.actions
        onOpenURL = newOpenURL
        interactionStore = view.interactionStore

        let itemsChanged = newFingerprints != fingerprints
        let peopleChanged = view.peopleHeader != peopleHeader
        let feedbackChanged = view.inlineFeedback != inlineFeedback
        let placeholderChanged = view.placeholderCount != placeholderCount
        let footerChanged = view.showsPaginationSpinner != showsPaginationSpinner
        guard itemsChanged || peopleChanged || feedbackChanged || placeholderChanged || footerChanged else { return }

        let previousCount = items.count
        let previousLastID = orderedItemIDs.last
        let previousFingerprints = fingerprintByID

        items = view.items
        fingerprints = newFingerprints
        peopleHeader = view.peopleHeader
        inlineFeedback = view.inlineFeedback
        placeholderCount = view.placeholderCount
        showsPaginationSpinner = view.showsPaginationSpinner

        if itemsChanged {
            rebuildItemCaches()
            if items.count != previousCount || orderedItemIDs.last != previousLastID { resetPaginationGate() }
        }
        guard isViewLoaded else { return }
        var reconfigure: [DynamicsCellKey] = []
        if peopleChanged, peopleHeader != nil { reconfigure.append(.peopleHeader) }
        if itemsChanged {
            for fingerprint in fingerprints where previousFingerprints[fingerprint.stableID] != fingerprint {
                reconfigure.append(.item(fingerprint.stableID))
            }
        }
        applySnapshot(reconfigureKeys: reconfigure)
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] in self?.mediaRequests(for: $0) ?? [] }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }
}

private extension DynamicsFeedCollectionViewController {
    struct Registrations {
        let peopleHeader: UICollectionView.CellRegistration<UICollectionViewCell, DynamicsPeopleHeaderState>
        let card: UICollectionView.CellRegistration<UIKitDynamicCardCell, DynamicFeedResult.DynamicItem>
        let skeleton: UICollectionView.CellRegistration<UIKitDynamicSkeletonCell, Int>
        let feedback: UICollectionView.CellRegistration<UICollectionViewCell, DynamicsEmptyFeedbackState>
        let footer: UICollectionView.CellRegistration<DynamicsLoadingFooterCell, Void>
    }

    func rebuildItemCaches() {
        var ids: [String] = []
        var itemsMap: [String: DynamicFeedResult.DynamicItem] = [:]
        var indexMap: [String: Int] = [:]
        var fingerprintMap: [String: DynamicsItemFingerprint] = [:]
        for (offset, item) in items.enumerated() {
            let id = fingerprints[offset].stableID
            guard itemsMap[id] == nil else { continue }
            ids.append(id)
            itemsMap[id] = item
            indexMap[id] = offset
            fingerprintMap[id] = fingerprints[offset]
        }
        orderedItemIDs = ids
        itemByID = itemsMap
        itemIndexByID = indexMap
        fingerprintByID = fingerprintMap
    }

    func configureDataSource() {
        let regs = makeRegistrations()
        dataSource = UICollectionViewDiffableDataSource<DynamicsSectionKey, DynamicsCellKey>(
            collectionView: collectionView
        ) { [weak self] collection, indexPath, cellKey in
            guard let self else { return nil }
            switch cellKey {
            case .peopleHeader:
                return peopleHeader.map {
                    collection.dequeueConfiguredReusableCell(using: regs.peopleHeader, for: indexPath, item: $0)
                }
            case .item(let id):
                return itemByID[id].map {
                    collection.dequeueConfiguredReusableCell(using: regs.card, for: indexPath, item: $0)
                }
            case .skeleton(let index):
                return collection.dequeueConfiguredReusableCell(using: regs.skeleton, for: indexPath, item: index)
            case .feedback(let state):
                return collection.dequeueConfiguredReusableCell(using: regs.feedback, for: indexPath, item: state)
            case .footerSpinner:
                return collection.dequeueConfiguredReusableCell(using: regs.footer, for: indexPath, item: ())
            }
        }
    }

    func makeRegistrations() -> Registrations {
        let peopleHeader = UICollectionView.CellRegistration<UICollectionViewCell, DynamicsPeopleHeaderState>(
            handler: { [weak self] cell, _, state in
                guard let self, let view = actions?.makePeopleHeader(state) else { return }
                cell.backgroundColor = .clear
                cell.contentView.backgroundColor = .clear
                cell.contentConfiguration = UIHostingConfiguration { view }.margins(.all, 0).background(.clear)
            }
        )
        let card = UICollectionView.CellRegistration<UIKitDynamicCardCell, DynamicFeedResult.DynamicItem>(
            handler: { [weak self] cell, _, item in
                guard let self else { return }
                cell.configure(UIKitDynamicCardCell.Model(
                    item: item,
                    interactionStore: interactionStore,
                    availableWidth: readableCardWidth,
                    actions: makeCardActions(for: item)
                ))
            }
        )
        let skeleton = UICollectionView.CellRegistration<UIKitDynamicSkeletonCell, Int> { cell, _, index in
            cell.configure(
                showsCardBackground: true,
                accessibilityLabel: index == 0 ? String(localized: "Loading moments") : nil
            )
        }
        let feedback = UICollectionView.CellRegistration<UICollectionViewCell, DynamicsEmptyFeedbackState>(
            handler: { [weak self] cell, _, state in
                guard let self, let view = actions?.makeFeedbackView(state) else { return }
                cell.backgroundColor = .clear
                cell.contentView.backgroundColor = .clear
                cell.contentConfiguration = UIHostingConfiguration {
                    view.frame(maxWidth: .infinity).padding(.vertical, AppSpacing.xl)
                }.margins(.all, 0).background(.clear)
            }
        )
        let footer = UICollectionView.CellRegistration<DynamicsLoadingFooterCell, Void> { cell, _, _ in
            cell.configure()
        }
        return Registrations(
            peopleHeader: peopleHeader, card: card, skeleton: skeleton, feedback: feedback, footer: footer
        )
    }

    func makeCardActions(for item: DynamicFeedResult.DynamicItem) -> UIKitDynamicCardCell.Actions {
        let openPost: (() -> Void)? = item.idStr.flatMap { postID in
            guard !postID.isEmpty else { return nil }
            return { [weak self] in self?.actions?.onOpenPost(postID) }
        }
        return UIKitDynamicCardCell.Actions(
            onOpenPost: openPost,
            onOpenQuotedPost: { [weak self] qid in self?.actions?.onOpenPost(qid) },
            onOpenProfile: { [weak self] mid in self?.actions?.onOpenProfile(mid) },
            onOpenVideo: { [weak self] target in self?.actions?.onOpenVideo(target) },
            onOpenArticle: { [weak self] cvid in self?.actions?.onOpenArticle(cvid) },
            onOpenLiveRoom: { [weak self] roomID in self?.actions?.onOpenLiveRoom(roomID) },
            onOpenURL: { [weak self] url in self?.onOpenURL?(url) },
            onImageTap: { [weak self] preview in self?.actions?.onImageTap(preview) },
            onRepost: { [weak self] in self?.actions?.onRepost(item) },
            onComment: { [weak self] in self?.actions?.onComment(item) },
            onLike: { [weak self] in self?.actions?.onLike(item) }
        )
    }

    func makeSectionLayout(
        _ sectionKey: DynamicsSectionKey, effectiveWidth: CGFloat, isFirst: Bool, nextSection: DynamicsSectionKey?
    ) -> NSCollectionLayoutSection {
        let columnWidth = max(1, min(effectiveWidth, ReadableWidth.feed) - AppSpacing.m * 2)
        let sideInset = max(AppSpacing.m, ((effectiveWidth - columnWidth) / 2).rounded(.down))
        let estimatedHeight: CGFloat = switch sectionKey {
        case .peopleHeader: 108
        case .items: 240
        case .skeletons: 196
        case .feedback: 220
        case .footer: 68
        }
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: itemSize, subitems: [NSCollectionLayoutItem(layoutSize: itemSize)]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = AppSpacing.m
        let topInset: CGFloat = isFirst ? AppSpacing.s : 0
        let bottomInset: CGFloat = (sectionKey == .footer || nextSection == .footer) ? 0 : AppSpacing.m
        section.contentInsets = NSDirectionalEdgeInsets(
            top: topInset, leading: sideInset, bottom: bottomInset, trailing: sideInset
        )
        return section
    }

    func applySnapshot(reconfigureKeys: [DynamicsCellKey] = [], reconfigureAll: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<DynamicsSectionKey, DynamicsCellKey>()
        if peopleHeader != nil {
            snapshot.appendSections([.peopleHeader])
            snapshot.appendItems([.peopleHeader], toSection: .peopleHeader)
        }
        if !orderedItemIDs.isEmpty {
            snapshot.appendSections([.items])
            snapshot.appendItems(orderedItemIDs.map { .item($0) }, toSection: .items)
            if showsPaginationSpinner {
                snapshot.appendSections([.footer])
                snapshot.appendItems([.footerSpinner], toSection: .footer)
            }
        } else if inlineFeedback != .none {
            snapshot.appendSections([.feedback])
            snapshot.appendItems([.feedback(inlineFeedback)], toSection: .feedback)
        } else if placeholderCount > 0 {
            snapshot.appendSections([.skeletons])
            snapshot.appendItems((0..<placeholderCount).map { .skeleton($0) }, toSection: .skeletons)
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

    func mediaRequests(for indexPath: IndexPath) -> [UIKitCoverPipeline.CoverRequest] {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath),
              case .item(let id) = cellKey, let item = itemByID[id] else { return [] }
        return UIKitDynamicCardMediaExtractor.coverRequests(
            for: item, cardWidth: readableCardWidth, scale: max(1, traitCollection.displayScale)
        )
    }
}
