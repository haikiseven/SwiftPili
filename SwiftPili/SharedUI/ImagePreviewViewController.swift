import UIKit

@MainActor final class ImagePreviewViewController: UIViewController {
    enum Phase { case idle, opening, presented, dragging, dismissing }

    var onRequestDismiss: ((UUID) -> Void)?
    var onDidFinishDismissal: ((UUID) -> Void)?

    let backdropView = UIView()
    let flowLayout = UICollectionViewFlowLayout()
    lazy var pagerView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    let transitionClipView = UIView()
    let transitionImageView = UIImageView()
    let chromeView = ImagePreviewChromeView()
    let actions = ImagePreviewActions()
    let dismissPan = UIPanGestureRecognizer()

    var phase: Phase = .idle
    var item: ImagePreviewItem?
    weak var sourceWindow: UIWindow?
    var currentIndex = 0
    var initialSourceIndex: Int?
    var initialSourceSnapshot: ImagePreviewSourceSnapshot?
    weak var hiddenSourceView: UIView?
    var activeAnimator: UIViewPropertyAnimator?
    var hidesStatusBar = false
    private var lastLayoutSize = CGSize.zero

    override var prefersStatusBarHidden: Bool { hidesStatusBar }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.accessibilityViewIsModal = true
        setupPlanes()
        setupActions()
        setupDismissGesture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        guard bounds.isUsableImageRect else { return }
        backdropView.frame = bounds
        chromeView.frame = bounds
        if lastLayoutSize != bounds.size {
            lastLayoutSize = bounds.size
            layoutPager(preservingIndex: currentIndex)
        }
    }

    func prepareForPresentation(
        item: ImagePreviewItem, sourceWindow: UIWindow, initialSource: ImagePreviewSourceSnapshot?
    ) {
        loadViewIfNeeded()
        cancelActiveTransition()

        self.item = item
        self.sourceWindow = sourceWindow
        self.currentIndex = item.index
        self.initialSourceIndex = item.index
        self.initialSourceSnapshot = initialSource
        setStatusBarImmersive(false, animated: false)

        chromeView.reset()
        chromeView.setTopInset(sourceWindow.safeAreaInsets.top)
        chromeView.updateCounter(index: item.index, total: item.urls.count)
        chromeView.updateSaveStatus(actions.saveState.status)

        view.frame = sourceWindow.bounds
        backdropView.frame = view.bounds
        chromeView.frame = view.bounds
        lastLayoutSize = view.bounds.size
        layoutPager(preservingIndex: item.index)
        pagerView.reloadData()
        pagerView.layoutIfNeeded()
        scrollPager(to: item.index)
        pagerView.layoutIfNeeded()

        prepareInitialVisualState(item: item, source: initialSource)
    }

    func startOpenAnimation() {
        guard let item else { return }
        animateOpen(item: item, source: initialSourceSnapshot)
    }

    func dismiss(animated: Bool) {
        guard let dismissingItem = item, phase != .dismissing, phase != .idle else { return }
        onRequestDismiss?(dismissingItem.id)
        if let presented = presentedViewController {
            presented.dismiss(animated: false)
        }
        stopActiveAnimator()
        phase = .dismissing

        guard animated else {
            finishDismissal(itemID: dismissingItem.id)
            return
        }
        let destSource = sourceWindow.flatMap { dismissingItem.origin?.resolve(index: currentIndex, in: $0) }
        animateDismiss(item: dismissingItem, destination: destSource)
    }

    func cancelActiveTransition() {
        stopActiveAnimator()
        restoreHiddenSourceView()
        setStatusBarImmersive(false, animated: false)
        if let presented = presentedViewController {
            presented.dismiss(animated: false)
        }
        pagerView.transform = .identity
        pagerView.alpha = 1
        pagerView.isHidden = false
        pagerView.isScrollEnabled = true
        transitionClipView.isHidden = true
        transitionImageView.image = nil
        if phase != .presented {
            phase = .idle
        }
    }

    func finishDismissal(itemID: UUID) {
        guard item?.id == itemID else { return }
        stopActiveAnimator()
        restoreHiddenSourceView()
        setStatusBarImmersive(false, animated: false)
        if let presented = presentedViewController {
            presented.dismiss(animated: false)
        }
        item = nil
        sourceWindow = nil
        initialSourceIndex = nil
        initialSourceSnapshot = nil
        phase = .idle
        pagerView.transform = .identity
        pagerView.alpha = 1
        pagerView.isHidden = false
        pagerView.isScrollEnabled = true
        pagerView.reloadData()
        transitionClipView.isHidden = true
        transitionImageView.image = nil
        backdropView.alpha = 0
        chromeView.alpha = 0
        chromeView.reset()
        onDidFinishDismissal?(itemID)
    }

    func stopActiveAnimator() {
        guard let animator = activeAnimator else { return }
        activeAnimator = nil
        animator.stopAnimation(true)
    }

    func restoreHiddenSourceView() {
        hiddenSourceView?.isHidden = false
        hiddenSourceView = nil
    }

    func setStatusBarImmersive(_ immersive: Bool, animated: Bool) {
        if immersive {
            view.window?.backgroundColor = .black
            view.window?.isOpaque = true
            hidesStatusBar = true
        } else {
            hidesStatusBar = false
            view.window?.isOpaque = false
            view.window?.backgroundColor = .clear
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.20) {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        } else {
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    func activePageCell() -> ImagePreviewPageCell? {
        pagerView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? ImagePreviewPageCell
    }

    func rectFromSourceWindow(_ rect: CGRect) -> CGRect {
        guard let sourceWindow else { return rect }
        if let overlayWindow = view.window, overlayWindow.bounds == sourceWindow.bounds {
            return view.convert(rect, from: overlayWindow)
        }
        return rect
    }

    private func setupPlanes() {
        backdropView.backgroundColor = .black
        backdropView.isUserInteractionEnabled = false
        backdropView.accessibilityElementsHidden = true
        backdropView.alpha = 0
        view.addSubview(backdropView)

        flowLayout.scrollDirection = .horizontal
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        pagerView.backgroundColor = .clear
        pagerView.isPagingEnabled = true
        pagerView.showsHorizontalScrollIndicator = false
        pagerView.showsVerticalScrollIndicator = false
        pagerView.contentInsetAdjustmentBehavior = .never
        pagerView.dataSource = self
        pagerView.delegate = self
        pagerView.register(ImagePreviewPageCell.self, forCellWithReuseIdentifier: ImagePreviewPageCell.reuseID)
        view.addSubview(pagerView)

        transitionClipView.clipsToBounds = true
        transitionClipView.isUserInteractionEnabled = false
        transitionClipView.isHidden = true
        transitionImageView.contentMode = .scaleAspectFill
        transitionImageView.clipsToBounds = true
        transitionClipView.addSubview(transitionImageView)
        view.addSubview(transitionClipView)

        chromeView.alpha = 0
        view.addSubview(chromeView)
    }

    private func setupActions() {
        chromeView.onSave = { [weak self] in
            guard let self, let item = self.item, item.urls.indices.contains(self.currentIndex) else { return }
            self.actions.save(url: item.urls[self.currentIndex])
        }
        chromeView.onClose = { [weak self] in
            self?.dismiss(animated: true)
        }
        actions.onSaveStateChange = { [weak self] status in
            self?.chromeView.updateSaveStatus(status)
        }
        actions.onCopyCompleted = { [weak self] in
            self?.chromeView.showCopiedToast()
        }
    }

    private func setupDismissGesture() {
        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        dismissPan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(dismissPan)
    }

    private func layoutPager(preservingIndex index: Int) {
        let pagerFrame = view.bounds.insetBy(dx: -ImagePreviewPageCell.horizontalInset, dy: 0)
        guard pagerFrame.isUsableImageRect else { return }
        if pagerView.frame != pagerFrame {
            pagerView.frame = pagerFrame
        }
        if flowLayout.itemSize != pagerFrame.size {
            flowLayout.itemSize = pagerFrame.size
            flowLayout.invalidateLayout()
        }
        scrollPager(to: index)
    }

    private func scrollPager(to index: Int) {
        guard let count = item?.urls.count, count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        let targetX = CGFloat(clamped) * pagerView.bounds.width
        if abs(pagerView.contentOffset.x - targetX) > 0.5 {
            pagerView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        }
    }

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            phase = .dragging
            pagerView.isScrollEnabled = false
            setStatusBarImmersive(false, animated: true)
        case .changed:
            let translation = recognizer.translation(in: view)
            let progress = min(max(translation.y / 320, 0), 1)
            let scale: CGFloat = translation.y > 0 ? max(0.55, 1.0 - progress * 0.42) : 1.0
            pagerView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                .scaledBy(x: scale, y: scale)
            backdropView.alpha = max(0, 1.0 - progress * 1.15)
            chromeView.alpha = max(0, 1.0 - min(1, max(0, translation.y) / 48))
        case .ended, .cancelled, .failed:
            pagerView.isScrollEnabled = true
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            if recognizer.state == .ended, translation.y > 100 || velocity.y > 600 {
                dismiss(animated: true)
            } else {
                cancelInteractiveDrag()
            }
        default:
            break
        }
    }
}

private extension ImagePreviewViewController {
    func presentShareSheet(url: URL, fallbackImage: UIImage?, anchorView: UIView) {
        let activeID = item?.id
        Task { [weak self] in
            guard let self else { return }
            let items = await self.actions.shareItems(for: url, fallbackImage: fallbackImage)
            guard self.item?.id == activeID, self.phase == .presented else { return }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = anchorView
                popover.sourceRect = anchorView.bounds
            }
            self.present(sheet, animated: true)
        }
    }
}

extension ImagePreviewViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        item?.urls.count ?? 0
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ImagePreviewPageCell.reuseID, for: indexPath
        ) as? ImagePreviewPageCell,
              let item, item.urls.indices.contains(indexPath.item) else {
            return UICollectionViewCell()
        }
        let isInitialPage = indexPath.item == initialSourceIndex
        let snapshot = isInitialPage ? initialSourceSnapshot : nil
        let seed = ImagePreviewPageCell.Seed(
            pixelSize: item.origin?.pixelSize(at: indexPath.item),
            thumbnail: snapshot?.thumbnailImage,
            isServerCropped: snapshot?.isServerCropped ?? false,
            deferFullReveal: isInitialPage && snapshot?.thumbnailImage != nil && phase != .presented
        )
        let callbacks = ImagePreviewPageCell.Callbacks(
            onSingleTap: { [weak self] in self?.dismiss(animated: true) },
            onSave: { [weak self] _, url in self?.actions.save(url: url) },
            onCopy: { [weak self] _, url, image in self?.actions.copy(url: url, fallbackImage: image) },
            onShare: { [weak self] _, url, image, anchor in
                self?.presentShareSheet(url: url, fallbackImage: image, anchorView: anchor)
            }
        )
        cell.configure(url: item.urls[indexPath.item], index: indexPath.item, seed: seed, callbacks: callbacks)
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pagerView, let count = item?.urls.count, count > 0,
              pagerView.bounds.width > 0 else { return }
        let page = Int((pagerView.contentOffset.x / pagerView.bounds.width).rounded())
        let clamped = min(max(page, 0), count - 1)
        if clamped != currentIndex {
            currentIndex = clamped
            chromeView.updateCounter(index: clamped, total: count)
        }
    }
}

extension ImagePreviewViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan, phase == .presented,
              presentedViewController == nil,
              !pagerView.isDragging, !pagerView.isDecelerating else { return false }
        let velocity = dismissPan.velocity(in: view)
        guard velocity.y > 0, abs(velocity.y) > abs(velocity.x) * 1.15 else { return false }
        return activePageCell()?.canBeginInteractiveDismissal ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === dismissPan,
              let scrollPan = activePageCell()?.scrollPanGestureRecognizer else { return false }
        return otherGestureRecognizer === scrollPan
    }
}
