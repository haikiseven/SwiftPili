import SwiftUI
import UIKit

@MainActor
struct UIKitHostEnvironment {
    var isActive: Bool = true
    var isTabSelected: Bool = true
    var scrollToTopTick: Int = 0
    var bottomSafeAreaInset: CGFloat = 0
    var keyboardDismissMode: UIScrollView.KeyboardDismissMode = .onDrag
    var onRefresh: (@MainActor () async -> Bool)?
}

@MainActor
protocol UIKitCollectionControllable: UIViewController {
    func applyHostEnvironment(_ environment: UIKitHostEnvironment)
    func didFinishHostUpdate()
    func tearDown()
}

extension UIKitCollectionControllable {
    func didFinishHostUpdate() {}
}

@MainActor
struct UIKitCollectionHost<Controller: UIKitCollectionControllable>: View {
    var isActive: Bool = true
    var isTabSelected: Bool = true
    var scrollToTopTick: Int = 0
    var keyboardDismissMode: UIScrollView.KeyboardDismissMode = .onDrag
    var onRefresh: (@MainActor () async -> Bool)?
    let makeController: @MainActor () -> Controller
    let updateController: @MainActor (Controller) -> Void

    @State private var bottomSafeAreaInset: CGFloat = 0

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateBottomSafeArea(proxy.safeAreaInsets.bottom) }
                    .onChange(of: proxy.safeAreaInsets.bottom) { _, inset in
                        updateBottomSafeArea(inset)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            UIKitCollectionRepresentable(
                environment: UIKitHostEnvironment(
                    isActive: isActive,
                    isTabSelected: isTabSelected,
                    scrollToTopTick: scrollToTopTick,
                    bottomSafeAreaInset: bottomSafeAreaInset,
                    keyboardDismissMode: keyboardDismissMode,
                    onRefresh: onRefresh
                ),
                makeController: makeController,
                updateController: updateController
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func updateBottomSafeArea(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard abs(bottomSafeAreaInset - clamped) > 0.5 else { return }
        bottomSafeAreaInset = clamped
    }
}

private struct UIKitCollectionRepresentable<Controller: UIKitCollectionControllable>:
    UIViewControllerRepresentable {
    final class Coordinator {
        var hasAppliedInitialUpdate = false
    }

    let environment: UIKitHostEnvironment
    let makeController: @MainActor () -> Controller
    let updateController: @MainActor (Controller) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = makeController()
        context.coordinator.hasAppliedInitialUpdate = true
        controller.applyHostEnvironment(environment)
        updateController(controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.applyHostEnvironment(environment)
        guard environment.isActive || !context.coordinator.hasAppliedInitialUpdate else { return }
        context.coordinator.hasAppliedInitialUpdate = true
        updateController(uiViewController)
        uiViewController.didFinishHostUpdate()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Coordinator) {
        uiViewController.tearDown()
    }
}

@MainActor
class UIKitBaseCollectionViewController: UIViewController,
    UIKitCollectionControllable,
    UICollectionViewDelegate {
    lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeCollectionLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .onDrag
        view.delegate = self
        return view
    }()

    let refreshControl = UIRefreshControl()
    let prefetchCoordinator = UIKitPrefetchCoordinator()

    var currentContentWidth: CGFloat = FeedWidth.seed
    var lastReconfiguredWidth: CGFloat = 0

    private(set) var isHostActive = true
    private(set) var isHostTabSelected = true
    private var externalBottomSafeAreaInset: CGFloat = 0
    private var lastHandledScrollToTopTick = 0
    private var hasAppliedInitialHostState = false

    private var onRefreshHandler: (@MainActor () async -> Bool)?
    private var activeRefreshToken: UUID?
    private var refreshTask: Task<Void, Never>?
    private var pendingScrollToTopAfterRefresh = false
    private var refreshScrollGeneration: UInt64 = 0
    private var refreshScrollTask: Task<Void, Never>?
    private var lastPaginationKey: AnyHashable?

    var layoutHorizontalInset: CGFloat { UIKitFeedLayoutMetrics.horizontalInset }
    var allowsSelectionHighlight: Bool { true }

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
        registerTraitObservers()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncBottomSafeAreaIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncBottomSafeAreaIfNeeded()
        let insetWidth = collectionView.bounds.width
            - collectionView.safeAreaInsets.left
            - collectionView.safeAreaInsets.right
        let measured = max(0, insetWidth - layoutHorizontalInset * 2)
        guard measured > 1, abs(measured - currentContentWidth) > 0.5 else { return }

        let oldWidth = currentContentWidth
        currentContentWidth = measured
        contentWidthDidChange(from: oldWidth, to: measured)
    }

    func applyHostEnvironment(_ environment: UIKitHostEnvironment) {
        isHostActive = environment.isActive
        isHostTabSelected = environment.isTabSelected
        let targetScrollsToTop = environment.isActive && environment.isTabSelected
        if collectionView.scrollsToTop != targetScrollsToTop {
            collectionView.scrollsToTop = targetScrollsToTop
        }
        if collectionView.keyboardDismissMode != environment.keyboardDismissMode {
            collectionView.keyboardDismissMode = environment.keyboardDismissMode
        }
        onRefreshHandler = environment.onRefresh
        if isViewLoaded, (environment.onRefresh != nil) != (collectionView.refreshControl != nil) {
            syncRefreshControlAttachment()
        }

        if abs(externalBottomSafeAreaInset - environment.bottomSafeAreaInset) > 0.5 {
            externalBottomSafeAreaInset = environment.bottomSafeAreaInset
            if isViewLoaded { syncBottomSafeAreaIfNeeded() }
        }

        if !hasAppliedInitialHostState {
            lastHandledScrollToTopTick = environment.scrollToTopTick
            hasAppliedInitialHostState = true
        } else if environment.scrollToTopTick != lastHandledScrollToTopTick {
            lastHandledScrollToTopTick = environment.scrollToTopTick
            if environment.isActive && environment.isTabSelected {
                scrollToTop(animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }

    @objc dynamic func tearDown() {
        activeRefreshToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancelPendingRefreshScrollToTop()
        prefetchCoordinator.cancelAll()
    }

    /// Resting top content offset excluding any temporary `UIRefreshControl` inset expansion.
    var restingTopContentOffsetY: CGFloat {
        -(collectionView.safeAreaInsets.top + collectionView.contentInset.top)
    }

    @objc dynamic func scrollToTop(animated: Bool) {
        cancelPendingRefreshScrollToTop()
        let topOffset = CGPoint(x: 0, y: restingTopContentOffsetY)
        collectionView.setContentOffset(topOffset, animated: animated)
    }

    func didFinishHostUpdate() {
        guard pendingScrollToTopAfterRefresh else { return }
        pendingScrollToTopAfterRefresh = false
        scheduleSettledRefreshScrollToTop(afterSnapshot: true)
    }

    func resetPaginationGate() {
        lastPaginationKey = nil
    }

    func triggerNearEndPaginationIfNeeded<Key: Hashable>(
        index: Int,
        totalCount: Int,
        key: Key,
        thresholdOffset: Int = 4,
        action: () -> Void
    ) {
        guard totalCount > 0 else { return }
        let thresholdIndex = max(0, totalCount - thresholdOffset)
        guard index >= thresholdIndex else { return }
        let boxed = AnyHashable(key)
        guard lastPaginationKey != boxed else { return }
        lastPaginationKey = boxed
        action()
    }

    // MARK: - Subclass Hooks

    @objc dynamic func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewFlowLayout()
    }

    @objc dynamic func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {}

    @objc dynamic func traitsDidChange() {}

    @objc dynamic func shouldSelectItem(at indexPath: IndexPath) -> Bool { true }

    @objc dynamic func didSelectItem(at indexPath: IndexPath) {}

    @objc dynamic func willDisplayItem(at indexPath: IndexPath) {}

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        didSelectItem(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        shouldSelectItem(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didHighlightItemAt indexPath: IndexPath
    ) {
        guard allowsSelectionHighlight,
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        if UIAccessibility.isReduceMotionEnabled {
            cell.contentView.alpha = 0.82
        } else {
            UIView.animate(withDuration: 0.12) { cell.contentView.alpha = 0.82 }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUnhighlightItemAt indexPath: IndexPath
    ) {
        guard allowsSelectionHighlight,
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        if UIAccessibility.isReduceMotionEnabled {
            cell.contentView.alpha = 1.0
        } else {
            UIView.animate(withDuration: 0.16) { cell.contentView.alpha = 1.0 }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        willDisplayItem(at: indexPath)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelPendingRefreshScrollToTop()
    }

    // MARK: - Private Helpers

    private func syncRefreshControlAttachment() {
        let wantsRefresh = onRefreshHandler != nil
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

    @objc
    private func handleRefreshControl() {
        guard let onRefreshHandler else {
            refreshControl.endRefreshing()
            return
        }
        refreshTask?.cancel()
        cancelPendingRefreshScrollToTop()
        let token = UUID()
        activeRefreshToken = token
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didPublishNewTop = await onRefreshHandler()
            guard !Task.isCancelled, activeRefreshToken == token else { return }
            activeRefreshToken = nil
            if didPublishNewTop {
                pendingScrollToTopAfterRefresh = true
                refreshControl.endRefreshing()
                // Fallback if SwiftUI already flushed the new snapshot synchronously before returning.
                scheduleSettledRefreshScrollToTop(afterSnapshot: false)
            } else {
                refreshControl.endRefreshing()
            }
        }
    }

    private func cancelPendingRefreshScrollToTop() {
        pendingScrollToTopAfterRefresh = false
        refreshScrollGeneration &+= 1
        refreshScrollTask?.cancel()
        refreshScrollTask = nil
    }

    private func scheduleSettledRefreshScrollToTop(afterSnapshot: Bool) {
        refreshScrollGeneration &+= 1
        let generation = refreshScrollGeneration
        refreshScrollTask?.cancel()
        refreshScrollTask = Task { @MainActor [weak self] in
            // Wait for SwiftUI to commit the refreshed diffable snapshot (if not yet applied)
            // and for UIRefreshControl.endRefreshing() to collapse its top inset.
            let initialDelayMs = afterSnapshot ? 60 : 120
            try? await Task.sleep(for: .milliseconds(initialDelayMs))
            guard let self, !Task.isCancelled, self.refreshScrollGeneration == generation else { return }
            self.pendingScrollToTopAfterRefresh = false
            self.scrollToRestingTopIfIdle()

            // Follow-up check after UIRefreshControl's ~0.3s collapse animation settles
            // in case UIKit's collapse offset clashed with the newly prepended top section.
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, self.refreshScrollGeneration == generation else { return }
            self.scrollToRestingTopIfIdle()
        }
    }

    private func scrollToRestingTopIfIdle() {
        guard isViewLoaded,
              view.window != nil,
              !collectionView.isTracking,
              !collectionView.isDragging else { return }
        collectionView.layoutIfNeeded()
        let targetY = restingTopContentOffsetY
        guard abs(collectionView.contentOffset.y - targetY) > 0.5 else { return }
        let animated = !UIAccessibility.isReduceMotionEnabled
        collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
    }

    private func syncBottomSafeAreaIfNeeded() {
        let naturalBottom = max(0, view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom)
        let desiredAdditional = max(0, externalBottomSafeAreaInset - naturalBottom)
        guard abs(additionalSafeAreaInsets.bottom - desiredAdditional) > 0.5 else { return }
        additionalSafeAreaInsets.bottom = desiredAdditional
    }

    private func registerTraitObservers() {
        registerForTraitChanges([
            UITraitHorizontalSizeClass.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
        ]) { (self: UIKitBaseCollectionViewController, _) in
            self.prefetchCoordinator.cancelAll()
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.traitsDidChange()
        }
    }
}
