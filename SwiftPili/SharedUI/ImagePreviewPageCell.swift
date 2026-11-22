import Kingfisher
import UIKit

@MainActor final class ImagePreviewZoomScrollView: UIScrollView {
    weak var contentTargetView: UIView?
    var isReadingMode = false

    override func layoutSubviews() {
        super.layoutSubviews()
        centerContentViewIfNeeded()
    }

    func centerContentViewIfNeeded() {
        guard let target = contentTargetView else { return }
        var frame = target.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        if isReadingMode, frame.height > bounds.height {
            frame.origin.y = 0
        } else {
            frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        }
        if abs(target.frame.origin.x - frame.origin.x) > 0.25
            || abs(target.frame.origin.y - frame.origin.y) > 0.25 {
            target.frame.origin = frame.origin
        }
    }
}

@MainActor final class ImagePreviewPageCell: UICollectionViewCell {
    static let reuseID = "ImagePreviewPageCell"
    static let horizontalInset: CGFloat = 10

    struct Seed {
        let pixelSize: CGSize?
        let thumbnail: UIImage?
        let isServerCropped: Bool
        let deferFullReveal: Bool
    }

    struct Callbacks {
        let onSingleTap: () -> Void
        let onSave: (Int, URL) -> Void
        let onCopy: (Int, URL, UIImage?) -> Void
        let onShare: (Int, URL, UIImage?, UIView) -> Void
    }

    struct PendingFullReveal {
        let generation: UInt64
        let result: RetrieveImageResult
        let options: KingfisherParsedOptionsInfo
        let url: URL
    }

    let scrollView = ImagePreviewZoomScrollView()
    let imageView = AnimatedImageView()
    let spinner = UIActivityIndicatorView(style: .medium)
    let errorButton = UIButton(type: .system)

    var callbacks: Callbacks?
    var currentURL: URL?
    var pageIndex = 0
    var loadGeneration: UInt64 = 0
    var thumbTask: DownloadTask?
    var fullTask: DownloadTask?
    var metadataTask: Task<Void, Never>?
    var resolvedAspect: CGFloat?
    var targetMetadataAspect: CGFloat?
    var hasAuthoritativeAspect = false
    var hasFullImage = false
    var isShowingServerCroppedThumb = false
    var defersFullReveal = false
    var pendingFullReveal: PendingFullReveal?
    var thumbFailed = false
    var fullFailed = false
    var lastRasterEdge: CGFloat = 0
    private var lastLayoutSize = CGSize.zero

    var canBeginInteractiveDismissal: Bool {
        scrollView.zoomScale <= 1.02 && scrollView.contentOffset.y <= 2
    }

    var currentDisplayedImage: UIImage? { imageView.image }
    var currentAspect: CGFloat? { resolvedAspect }

    var currentDisplayMode: ImagePreviewDisplayMode {
        guard let currentURL else { return .fitted }
        return ImagePreviewRasterPolicy.displayMode(url: currentURL, aspect: resolvedAspect)
    }

    var scrollPanGestureRecognizer: UIPanGestureRecognizer { scrollView.panGestureRecognizer }

    var effectiveViewportSize: CGSize {
        let size = scrollView.bounds.size
        if size.width > 1, size.height > 1 { return size }
        return CGSize(
            width: max(1, contentView.bounds.width - Self.horizontalInset * 2),
            height: max(1, contentView.bounds.height)
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        setupScrollView()
        setupStatusViews()
        setupGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelActiveLoads()
        currentURL = nil
        callbacks = nil
        resolvedAspect = nil
        targetMetadataAspect = nil
        hasAuthoritativeAspect = false
        hasFullImage = false
        isShowingServerCroppedThumb = false
        defersFullReveal = false
        pendingFullReveal = nil
        thumbFailed = false
        fullFailed = false
        lastRasterEdge = 0
        lastLayoutSize = .zero
        imageView.stopAnimating()
        imageView.layer.removeAllAnimations()
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = 1
        imageView.image = nil
        imageView.isHidden = false
        scrollView.isReadingMode = false
        scrollView.zoomScale = 1.0
        scrollView.contentOffset = .zero
        spinner.stopAnimating()
        errorButton.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewportFrame = contentView.bounds.insetBy(dx: Self.horizontalInset, dy: 0)
        guard viewportFrame.isUsableImageRect else { return }
        if scrollView.frame != viewportFrame {
            scrollView.frame = viewportFrame
        }
        spinner.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        errorButton.center = spinner.center
        if lastLayoutSize != viewportFrame.size {
            lastLayoutSize = viewportFrame.size
            layoutImageContent(resetZoom: true, animated: false)
        }
    }

    func configure(url: URL, index: Int, seed: Seed, callbacks: Callbacks) {
        cancelActiveLoads()
        loadGeneration &+= 1
        let generation = loadGeneration
        currentURL = url
        pageIndex = index
        self.callbacks = callbacks
        hasFullImage = false
        hasAuthoritativeAspect = false
        isShowingServerCroppedThumb = seed.isServerCropped && seed.thumbnail != nil
        defersFullReveal = seed.deferFullReveal
        pendingFullReveal = nil
        thumbFailed = false
        fullFailed = false
        lastRasterEdge = 0
        imageView.stopAnimating()
        imageView.layer.removeAllAnimations()
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = false
        errorButton.isHidden = true
        scrollView.zoomScale = 1.0
        scrollView.contentOffset = .zero

        targetMetadataAspect = Self.validAspect(from: seed.pixelSize)
        let thumbAspect = Self.validAspect(from: seed.thumbnail)
        let targetMode = targetMetadataAspect.map {
            ImagePreviewRasterPolicy.displayMode(url: url, aspect: $0)
        } ?? .fitted
        if isShowingServerCroppedThumb, targetMode == .reading {
            resolvedAspect = thumbAspect ?? targetMetadataAspect
        } else {
            resolvedAspect = targetMetadataAspect ?? thumbAspect
        }

        if let thumbnail = seed.thumbnail {
            imageView.alpha = 1
            imageView.image = thumbnail
            spinner.stopAnimating()
        } else {
            imageView.alpha = 0
            imageView.image = nil
            spinner.startAnimating()
        }

        let viewportFrame = contentView.bounds.insetBy(dx: Self.horizontalInset, dy: 0)
        if viewportFrame.isUsableImageRect {
            scrollView.frame = viewportFrame
            lastLayoutSize = viewportFrame.size
            layoutImageContent(resetZoom: true, animated: false)
        }
        startLoading(url: url, generation: generation)
    }

    func visibleImageFrame(in targetView: UIView) -> CGRect {
        guard imageView.bounds.isUsableImageRect else {
            return scrollView.convert(scrollView.bounds, to: targetView)
        }
        if isShowingServerCroppedThumb, let thumbAspect = Self.validAspect(from: imageView.image) {
            let fitted = ImagePreviewMath.fittedSize(in: imageView.bounds.size, aspect: thumbAspect)
            let localRect = CGRect(
                x: (imageView.bounds.width - fitted.width) / 2,
                y: (imageView.bounds.height - fitted.height) / 2,
                width: fitted.width,
                height: fitted.height
            )
            return imageView.convert(localRect, to: targetView)
        }
        return imageView.convert(imageView.bounds, to: targetView)
    }

    func layoutImageContent(
        resetZoom: Bool,
        animated: Bool,
        onComplete: (() -> Void)? = nil
    ) {
        let viewport = effectiveViewportSize
        guard viewport.width > 1, viewport.height > 1 else {
            onComplete?()
            return
        }
        if !resetZoom, scrollView.zoomScale > 1.02 {
            onComplete?()
            return
        }
        if resetZoom, scrollView.zoomScale != 1.0 {
            scrollView.zoomScale = 1.0
        }
        let mode = currentDisplayMode
        scrollView.isReadingMode = mode == .reading
        let baseSize = targetBaseSize(in: viewport, mode: mode)
        let originX = baseSize.width < viewport.width ? (viewport.width - baseSize.width) / 2 : 0
        let originY: CGFloat = mode == .reading && baseSize.height > viewport.height
            ? 0
            : (baseSize.height < viewport.height ? (viewport.height - baseSize.height) / 2 : 0)
        let nextFrame = CGRect(x: originX, y: originY, width: baseSize.width, height: baseSize.height)

        let applyLayout = {
            self.imageView.frame = nextFrame
            self.scrollView.contentSize = baseSize
            if resetZoom {
                self.scrollView.contentOffset = .zero
            }
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction],
                animations: applyLayout,
                completion: { _ in onComplete?() }
            )
        } else {
            applyLayout()
            onComplete?()
        }
    }

    private func targetBaseSize(in viewport: CGSize, mode: ImagePreviewDisplayMode) -> CGSize {
        guard let aspect = resolvedAspect, aspect > 0 else { return viewport }
        return mode == .reading
            ? CGSize(width: viewport.width, height: viewport.width / aspect)
            : ImagePreviewMath.fittedSize(in: viewport, aspect: aspect)
    }

    private func setupScrollView() {
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        contentView.addSubview(scrollView)

        imageView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.autoPlayAnimatedImage = true
        imageView.purgeFramesOnBackground = true
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        scrollView.contentTargetView = imageView
    }

    private func setupStatusViews() {
        spinner.color = .white
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "arrow.clockwise.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        )
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.75)
        errorButton.configuration = config
        errorButton.sizeToFit()
        errorButton.isHidden = true
        errorButton.accessibilityLabel = String(localized: "Retry")
        errorButton.addTarget(self, action: #selector(handleRetryTap), for: .touchUpInside)
        contentView.addSubview(errorButton)
    }

    private func setupGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        scrollView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @objc private func handleSingleTap() {
        callbacks?.onSingleTap()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let animated = !UIAccessibility.isReduceMotionEnabled
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.05 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
            return
        }
        let rawPoint = recognizer.location(in: imageView)
        let clampedPoint = CGPoint(
            x: min(max(rawPoint.x, 0), imageView.bounds.width),
            y: min(max(rawPoint.y, 0), imageView.bounds.height)
        )
        let rect = ImagePreviewMath.zoomRect(at: clampedPoint, scale: 2.5, viewport: scrollView.bounds.size)
        scrollView.zoom(to: rect, animated: animated)
    }

    @objc private func handleRetryTap() {
        guard let currentURL else { return }
        loadGeneration &+= 1
        thumbFailed = false
        fullFailed = false
        errorButton.isHidden = true
        spinner.startAnimating()
        startLoading(url: currentURL, generation: loadGeneration)
    }
}

extension ImagePreviewPageCell: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        self.scrollView.centerContentViewIfNeeded()
    }
}

extension ImagePreviewPageCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let url = currentURL else { return nil }
        let index = pageIndex
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let save = UIAction(
                title: String(localized: "Save"),
                image: UIImage(systemName: "square.and.arrow.down")
            ) { [weak self] _ in
                self?.callbacks?.onSave(index, url)
            }
            let copy = UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.callbacks?.onCopy(index, url, self?.imageView.image)
            }
            let share = UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                guard let self else { return }
                self.callbacks?.onShare(index, url, self.imageView.image, self.imageView)
            }
            return UIMenu(children: [save, copy, share])
        }
    }
}
