import SwiftUI
import UIKit

enum CommentFeedSectionKey: Hashable, Sendable {
    case header, items, skeletons, footer
}

enum CommentFeedCellKey: Hashable, Sendable {
    case header(AnyHashableSendable)
    case item(AnyHashableSendable)
    case skeleton(Int)
    case footer
}

struct CommentFeedSnapshotDiffInput {
    let oldConfig: UIKitCommentFeedConfiguration
    let newConfig: UIKitCommentFeedConfiguration
    let oldEnv: EnvironmentValues
    let newEnv: EnvironmentValues
    let oldOrderedIDs: [AnyHashableSendable]
    let oldItemByID: [AnyHashableSendable: UIKitCommentFeedItem]
    let oldHeaderByID: [AnyHashableSendable: UIKitCommentFeedItem]
}

@MainActor
final class UIKitCommentFeedViewController: UIViewController,
    UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching {
    lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeCollectionLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.delegate = self
        view.prefetchDataSource = self
        return view
    }()

    let refreshControl = UIRefreshControl()
    private let prefetchCoordinator = UIKitPrefetchCoordinator()
    var dataSource: UICollectionViewDiffableDataSource<CommentFeedSectionKey, CommentFeedCellKey>?

    var config = UIKitCommentFeedConfiguration()
    var hostEnvironment = EnvironmentValues()
    var orderedHeaderIDs: [AnyHashableSendable] = []
    var headerByID: [AnyHashableSendable: UIKitCommentFeedItem] = [:]
    var orderedItemIDs: [AnyHashableSendable] = []
    var itemByID: [AnyHashableSendable: UIKitCommentFeedItem] = [:]
    private var itemIndexByID: [AnyHashableSendable: Int] = [:]

    var currentColumnWidth: CGFloat = FeedWidth.seed
    private var hasAppliedInitialSnapshot = false
    private var externalBottomSafeAreaInset: CGFloat = 0
    private var activeRefreshToken: UUID?
    private var refreshTask: Task<Void, Never>?
    private var lastReportedScrollOffset: CGFloat?
    var pendingScrollToItemID: AnyHashableSendable?
    private var lastHandledScrollToItemID: AnyHashableSendable?
    private var geometryTask: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?

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
        syncRefreshControlAttachment()
        dataSource = makeDiffableDataSource(for: collectionView)
        registerTraitObservers()
        if seedColumnWidthFromCollectionViewIfReady() {
            hasAppliedInitialSnapshot = true
            applySnapshot()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAppliedInitialSnapshot {
            _ = seedColumnWidthFromCollectionViewIfReady()
            hasAppliedInitialSnapshot = true
            applySnapshot()
        }
        performPendingScrollIfReady()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncBottomSafeAreaIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncBottomSafeAreaIfNeeded()
        let width = measuredColumnWidth(for: collectionView.bounds.width, safeAreaInsets: collectionView.safeAreaInsets)
        if !hasAppliedInitialSnapshot {
            if width > 1 {
                currentColumnWidth = width
                hasAppliedInitialSnapshot = true
                applySnapshot()
            }
        } else if width > 1, abs(width - currentColumnWidth) > 0.5 {
            currentColumnWidth = width
            prefetchCoordinator.cancelAll()
            performWithoutLayoutAnimations {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            scheduleGeometryReconfigure()
        }
        performPendingScrollIfReady()
    }

    func tearDown() {
        activeRefreshToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        geometryTask?.cancel()
        geometryTask = nil
        scrollTask?.cancel()
        scrollTask = nil
        prefetchCoordinator.cancelAll()
    }

    func apply(
        config newConfig: UIKitCommentFeedConfiguration,
        hostEnvironment newEnv: EnvironmentValues,
        externalBottomSafeAreaInset newBottomInset: CGFloat
    ) {
        let diffInput = CommentFeedSnapshotDiffInput(
            oldConfig: config,
            newConfig: newConfig,
            oldEnv: hostEnvironment,
            newEnv: newEnv,
            oldOrderedIDs: orderedItemIDs,
            oldItemByID: itemByID,
            oldHeaderByID: headerByID
        )

        config = newConfig
        hostEnvironment = newEnv
        applyEnvironmentTraits(newEnv)
        collectionView.showsVerticalScrollIndicator = newConfig.showsScrollIndicators
        collectionView.keyboardDismissMode = newConfig.keyboardDismissMode

        if abs(externalBottomSafeAreaInset - newBottomInset) > 0.5 {
            externalBottomSafeAreaInset = newBottomInset
            if isViewLoaded { syncBottomSafeAreaIfNeeded() }
        }
        if isViewLoaded { syncRefreshControlAttachment() }

        rebuildCaches(from: newConfig)
        updateScrollTarget(newConfig.scrollToItemID)

        guard isViewLoaded else { return }
        if !hasAppliedInitialSnapshot {
            guard seedColumnWidthFromCollectionViewIfReady() else {
                schedulePendingScrollIfNeeded()
                return
            }
            hasAppliedInitialSnapshot = true
            applySnapshot()
            schedulePendingScrollIfNeeded()
            return
        }
        if layoutMetricsChanged(old: diffInput.oldConfig, new: newConfig) {
            performWithoutLayoutAnimations {
                collectionView.collectionViewLayout.invalidateLayout()
            }
        }
        let reconfigures = computeReconfigureKeys(diffInput)
        let resetsScroll = shouldResetScrollToTop(
            oldIDs: diffInput.oldOrderedIDs,
            newIDs: orderedItemIDs,
            skeletonCount: newConfig.skeletonCount
        )
        applySnapshot(reconfigureKeys: reconfigures, resetScrollToTop: resetsScroll)
        schedulePendingScrollIfNeeded()
    }

    // MARK: - UICollectionViewDelegate & Prefetch

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        false
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let key = dataSource?.itemIdentifier(for: indexPath),
              case .item(let id) = key,
              let index = itemIndexByID[id] else { return }
        let totalCount = orderedItemIDs.count
        guard totalCount > 0 else { return }
        let thresholdIndex = max(0, totalCount - max(1, config.thresholdOffset))
        guard index >= thresholdIndex else { return }
        config.onWillDisplayItemAt?(index)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        if let last = lastReportedScrollOffset, abs(last - offset) <= 0.25 { return }
        lastReportedScrollOffset = offset
        config.onScrollOffsetChange?(offset)
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
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] indexPath in
            self?.prefetchRequests(for: indexPath) ?? []
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }
}

private extension UIKitCommentFeedViewController {
    func rebuildCaches(from newConfig: UIKitCommentFeedConfiguration) {
        var headers: [AnyHashableSendable] = []
        var headerMap: [AnyHashableSendable: UIKitCommentFeedItem] = [:]
        for item in newConfig.headerItems where headerMap[item.id] == nil {
            headers.append(item.id)
            headerMap[item.id] = item
        }
        orderedHeaderIDs = headers
        headerByID = headerMap

        var ids: [AnyHashableSendable] = []
        var itemsMap: [AnyHashableSendable: UIKitCommentFeedItem] = [:]
        var indexMap: [AnyHashableSendable: Int] = [:]
        for item in newConfig.items where itemsMap[item.id] == nil {
            indexMap[item.id] = ids.count
            ids.append(item.id)
            itemsMap[item.id] = item
        }
        orderedItemIDs = ids
        itemByID = itemsMap
        itemIndexByID = indexMap
    }

    func applyEnvironmentTraits(_ env: EnvironmentValues) {
        let style: UIUserInterfaceStyle = env.colorScheme == .dark ? .dark : .light
        if overrideUserInterfaceStyle != style {
            overrideUserInterfaceStyle = style
        }
    }

    func seedColumnWidthFromCollectionViewIfReady() -> Bool {
        guard collectionView.bounds.width > 1 else { return false }
        let width = measuredColumnWidth(
            for: collectionView.bounds.width,
            safeAreaInsets: collectionView.safeAreaInsets
        )
        guard width > 1 else { return false }
        currentColumnWidth = width
        return true
    }

    func syncBottomSafeAreaIfNeeded() {
        let targetInset = config.ignoresBottomSafeArea ? externalBottomSafeAreaInset : 0
        let naturalBottom = max(0, view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom)
        let desiredAdditional = max(0, targetInset - naturalBottom)
        guard abs(additionalSafeAreaInsets.bottom - desiredAdditional) > 0.5 else { return }
        performWithoutLayoutAnimations {
            additionalSafeAreaInsets.bottom = desiredAdditional
        }
    }

    func syncRefreshControlAttachment() {
        let wantsRefresh = config.onRefresh != nil
        if wantsRefresh, collectionView.refreshControl !== refreshControl {
            collectionView.refreshControl = refreshControl
        } else if !wantsRefresh, collectionView.refreshControl != nil {
            activeRefreshToken = nil
            refreshTask?.cancel()
            refreshTask = nil
            refreshControl.endRefreshing()
            collectionView.refreshControl = nil
        }
    }

    @objc func handleRefreshControl() {
        guard let onRefresh = config.onRefresh else {
            refreshControl.endRefreshing()
            return
        }
        refreshTask?.cancel()
        let token = UUID()
        activeRefreshToken = token
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didPublishNewTop = await onRefresh()
            guard !Task.isCancelled, activeRefreshToken == token else { return }
            activeRefreshToken = nil
            refreshControl.endRefreshing()
            if didPublishNewTop {
                let top = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
                collectionView.setContentOffset(top, animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }

    func updateScrollTarget(_ newTarget: AnyHashableSendable?) {
        let active = pendingScrollToItemID ?? lastHandledScrollToItemID
        guard newTarget != active else { return }
        if let newTarget {
            pendingScrollToItemID = newTarget
        } else {
            pendingScrollToItemID = nil
            lastHandledScrollToItemID = nil
        }
    }

    func schedulePendingScrollIfNeeded() {
        guard pendingScrollToItemID != nil else { return }
        scrollTask?.cancel()
        scrollTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            performPendingScrollIfReady()
        }
    }

    func performPendingScrollIfReady() {
        guard let targetID = pendingScrollToItemID,
              let dataSource,
              collectionView.window != nil,
              collectionView.bounds.height > 0 else { return }
        let indexPath = dataSource.indexPath(for: .item(targetID))
            ?? dataSource.indexPath(for: .header(targetID))
        guard let indexPath else { return }
        pendingScrollToItemID = nil
        lastHandledScrollToItemID = targetID
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(
            at: indexPath,
            at: config.scrollToPosition,
            animated: !UIAccessibility.isReduceMotionEnabled
        )
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(reconfigureAll: true)
        }
    }

    func registerTraitObservers() {
        registerForTraitChanges([
            UITraitHorizontalSizeClass.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
        ]) { (self: UIKitCommentFeedViewController, _) in
            self.prefetchCoordinator.cancelAll()
            self.performWithoutLayoutAnimations {
                self.collectionView.collectionViewLayout.invalidateLayout()
            }
            self.scheduleGeometryReconfigure()
        }
    }

    func prefetchRequests(for indexPath: IndexPath) -> [UIKitCoverPipeline.CoverRequest] {
        guard let key = dataSource?.itemIdentifier(for: indexPath),
              case .item(let id) = key,
              let item = itemByID[id],
              let comment = item.comment else { return [] }
        return UIKitCommentPrefetchExtractor.coverRequests(
            for: comment,
            avatarPointSize: item.prefetchAvatarPointSize,
            scale: max(1, traitCollection.displayScale)
        )
    }
}
