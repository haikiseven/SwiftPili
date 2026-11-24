import Kingfisher
import UIKit

@MainActor
final class UIKitDynamicDrawGridView: UIView {
    struct MediaItem: Equatable {
        let url: URL
        var pixelSize: CGSize?

        var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
        var isLongImage: Bool {
            guard let size = pixelSize, size.width > 0 else { return false }
            return size.height / size.width > 2.6
        }
    }

    private final class TileView: UIView {
        let imageView = UIImageView()
        let badgeView = UIKitMediaBadgeView(horizontalPadding: 5, verticalPadding: 2)
        let overflowLabel = UILabel()
        var activeRequest: UIKitCoverPipeline.CoverRequest?
        var index: Int = 0
        var onSelect: ((Int) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.cornerCurve = .continuous
            backgroundColor = .secondarySystemFill

            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.clipsToBounds = true
            addSubview(imageView)

            badgeView.translatesAutoresizingMaskIntoConstraints = false
            badgeView.isHidden = true
            addSubview(badgeView)

            overflowLabel.translatesAutoresizingMaskIntoConstraints = false
            overflowLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            overflowLabel.textColor = .white
            overflowLabel.textAlignment = .center
            overflowLabel.isHidden = true
            addSubview(overflowLabel)

            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
                badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                badgeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                overflowLabel.topAnchor.constraint(equalTo: topAnchor),
                overflowLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                overflowLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                overflowLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func handleTap() { onSelect?(index) }
    }

    var onImageTap: ((ImagePreviewItem) -> Void)?

    private var tiles: [TileView] = []
    private var items: [MediaItem] = []
    private var currentURLs: [URL] = []
    private var originGeneration = UUID()
    private var lastWidth: CGFloat = 0
    private var maxWidth: CGFloat?
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let heightC = heightAnchor.constraint(equalToConstant: 0)
        heightC.priority = .required
        heightC.isActive = true
        heightConstraint = heightC
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [MediaItem], availableWidth: CGFloat, maxWidth: CGFloat? = nil) {
        let nextURLs = items.map(\.url)
        if nextURLs != currentURLs {
            originGeneration = UUID()
            currentURLs = nextURLs
        }
        self.items = items
        self.maxWidth = maxWidth
        self.lastWidth = max(1, availableWidth)
        ensureTileCount(min(items.count, 9))
        applyLayout(width: lastWidth)
    }

    func updateAvailableWidth(_ availableWidth: CGFloat) {
        let clamped = max(1, availableWidth)
        guard !items.isEmpty, abs(clamped - lastWidth) > 0.5 else { return }
        lastWidth = clamped
        applyLayout(width: clamped)
    }

    func prepareForReuse() {
        originGeneration = UUID()
        currentURLs = []
        items = []
        onImageTap = nil
        maxWidth = nil
        lastWidth = 0
        heightConstraint?.constant = 0
        for tile in tiles {
            UIKitCoverPipeline.cancel(on: tile.imageView, activeRequest: &tile.activeRequest)
            tile.isHidden = true
            tile.imageView.isHidden = false
            tile.overflowLabel.isHidden = true
            tile.badgeView.isHidden = true
            tile.onSelect = nil
        }
    }

    static func coverRequests(
        for items: [MediaItem],
        availableWidth: CGFloat,
        maxWidth: CGFloat? = nil,
        scale: CGFloat
    ) -> [UIKitCoverPipeline.CoverRequest] {
        let layout = computeLayout(
            count: items.count, firstPixelSize: items.first?.pixelSize,
            availableWidth: availableWidth, maxWidth: maxWidth
        )
        let drawn = min(items.count, 9)
        return (0 ..< drawn).compactMap { index -> UIKitCoverPipeline.CoverRequest? in
            let item = items[index]
            let box = layout.frames[index].size
            guard box.width > 1, box.height > 1 else { return nil }
            if item.isGIF {
                return UIKitCoverPipeline.CoverRequest(
                    url: item.url, requestBox: box, scale: scale,
                    displayMode: .fill, sourceURL: item.url.absoluteString
                )
            }
            let cropped = items.count > 1 || item.isLongImage || item.pixelSize == nil
            return UIKitCoverPipeline.request(
                urlString: item.url.absoluteString,
                drawnBox: box,
                displayMode: cropped ? .fill : .entire,
                requestsServerCrop: items.count > 1,
                scale: scale
            )
        }
    }

    private func ensureTileCount(_ count: Int) {
        while tiles.count < count {
            let tile = TileView()
            tile.index = tiles.count
            addSubview(tile)
            tiles.append(tile)
        }
    }

    private func applyLayout(width: CGFloat) {
        let layout = Self.computeLayout(
            count: items.count, firstPixelSize: items.first?.pixelSize,
            availableWidth: width, maxWidth: maxWidth
        )
        heightConstraint?.constant = layout.totalHeight
        let urls = currentURLs
        let drawn = min(items.count, 9)
        let cornerRadius = drawn == 1 ? AppRadius.control : AppRadius.thumbnail
        let traits = traitCollection

        for (index, tile) in tiles.enumerated() {
            guard index < drawn else {
                UIKitCoverPipeline.cancel(on: tile.imageView, activeRequest: &tile.activeRequest)
                tile.isHidden = true
                continue
            }
            let item = items[index]
            tile.isHidden = false
            tile.frame = layout.frames[index]
            tile.layer.cornerRadius = cornerRadius
            tile.onSelect = { [weak self] tapped in
                guard let self else { return }
                let origin = ImagePreviewOrigin(
                    provider: self,
                    generation: self.originGeneration,
                    urls: urls
                )
                self.onImageTap?(ImagePreviewItem(urls: urls, index: tapped, origin: origin))
            }
            configureTileImage(tile, item: item, size: layout.frames[index].size, isSingle: drawn == 1)
            configureTileOverlays(tile, item: item, index: index, totalCount: items.count, traits: traits)
        }
    }

    private func configureTileImage(_ tile: TileView, item: MediaItem, size: CGSize, isSingle: Bool) {
        let safeScale = max(1, traitCollection.displayScale)
        if item.isGIF {
            let gifRequest = UIKitCoverPipeline.CoverRequest(
                url: item.url,
                requestBox: size,
                scale: safeScale,
                displayMode: .fill,
                sourceURL: item.url.absoluteString
            )
            tile.imageView.contentMode = .scaleAspectFill
            tile.imageView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            guard tile.activeRequest != gifRequest else { return }
            tile.activeRequest = gifRequest
            tile.imageView.kf.setImage(
                with: item.url,
                options: [.backgroundDecode, .scaleFactor(safeScale), .transition(.none)]
            )
            return
        }
        let cropped = !isSingle || item.isLongImage || item.pixelSize == nil
        let request = UIKitCoverPipeline.request(
            urlString: item.url.absoluteString,
            drawnBox: size,
            displayMode: cropped ? .fill : .entire,
            requestsServerCrop: !isSingle,
            scale: safeScale
        )
        UIKitCoverPipeline.apply(to: tile.imageView, request: request, activeRequest: &tile.activeRequest)
        if item.isLongImage, let pixelSize = item.pixelSize,
           pixelSize.width > 0, pixelSize.height > 0, size.width > 0 {
            let boxRatio = size.height / size.width
            let imgRatio = pixelSize.height / pixelSize.width
            tile.imageView.contentMode = .scaleToFill
            tile.imageView.layer.contentsRect = CGRect(
                x: 0, y: 0, width: 1, height: min(1, max(0.05, boxRatio / imgRatio))
            )
        } else {
            tile.imageView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    private func configureTileOverlays(
        _ tile: TileView,
        item: MediaItem,
        index: Int,
        totalCount: Int,
        traits: UITraitCollection
    ) {
        if item.isGIF {
            tile.badgeView.configurePill(
                text: "GIF", backgroundColor: UIColor.black.withAlphaComponent(0.55), traitCollection: traits
            )
        } else if item.isLongImage {
            tile.badgeView.configurePill(
                text: String(localized: "Long Image"),
                backgroundColor: UIColor.black.withAlphaComponent(0.55),
                traitCollection: traits
            )
        } else {
            tile.badgeView.isHidden = true
        }

        if index == 8, totalCount > 9 {
            tile.overflowLabel.isHidden = false
            tile.overflowLabel.text = "+\(totalCount - 9)"
            tile.overflowLabel.font = UIKitFeedFont.systemFont(
                textStyle: .headline, weight: .bold, traitCollection: traits
            )
        } else {
            tile.overflowLabel.isHidden = true
        }
    }

    private static func computeLayout(
        count: Int,
        firstPixelSize: CGSize?,
        availableWidth: CGFloat,
        maxWidth: CGFloat?
    ) -> (frames: [CGRect], totalHeight: CGFloat) {
        let drawn = min(max(count, 0), 9)
        guard drawn > 0 else { return ([], 0) }
        let spacing = CommentMediaMetrics.gridSpacing
        let cappedWidth = max(1, min(availableWidth, maxWidth ?? availableWidth))

        if drawn == 1 {
            let limit = min(maxWidth ?? 320, 320)
            let width = max(1, min(availableWidth, limit))
            let size: CGSize
            if let pixelSize = firstPixelSize, pixelSize.width > 0, pixelSize.height > 0 {
                let ratio = pixelSize.height / pixelSize.width
                if ratio > 2.6 {
                    size = CGSize(width: width, height: min(width * 1.5, 360).rounded())
                } else {
                    let fitted = min(width, 360 / ratio)
                    size = CGSize(width: fitted.rounded(), height: (fitted * ratio).rounded())
                }
            } else {
                size = CGSize(width: width.rounded(), height: (width * 3 / 4).rounded())
            }
            return ([CGRect(origin: .zero, size: size)], size.height)
        }

        let cols = (drawn == 2 || drawn == 4) ? 2 : 3
        let side = max(1, ((cappedWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down))
        let frames = (0 ..< drawn).map { index in
            CGRect(
                x: CGFloat(index % cols) * (side + spacing),
                y: CGFloat(index / cols) * (side + spacing),
                width: side,
                height: side
            )
        }
        let rows = (drawn + cols - 1) / cols
        let totalHeight = CGFloat(rows) * side + CGFloat(rows - 1) * spacing
        return (frames, totalHeight)
    }
}

extension UIKitDynamicDrawGridView: ImagePreviewOriginProvider {
    func resolveSource(
        generation: UUID, urls: [URL], index: Int, in window: UIWindow
    ) -> ImagePreviewSourceSnapshot? {
        guard originGeneration == generation, currentURLs == urls,
              tiles.indices.contains(index), items.indices.contains(index) else { return nil }
        let tile = tiles[index]
        guard !tile.isHidden,
              let rects = ImagePreviewSourceVisibilityCheck.visibleFrame(of: tile, in: window) else {
            return nil
        }
        let item = items[index]
        let resolved = ImagePreviewMemoryLookup.resolveOpeningImage(
            url: item.url,
            tileImage: tile.imageView.image,
            viewportSize: window.bounds.size,
            pixelSize: item.pixelSize
        )
        return ImagePreviewSourceSnapshot(
            frameInWindow: rects.frame,
            visibleFrameInWindow: rects.visible,
            cornerRadius: tile.layer.cornerRadius,
            cornerCurve: tile.layer.cornerCurve,
            topAligned: item.isLongImage && !item.isGIF,
            pixelSize: item.pixelSize,
            thumbnailImage: resolved.image,
            isServerCropped: resolved.isServerCropped,
            sourceView: tile.imageView
        )
    }

    func pixelSize(generation: UUID, urls: [URL], index: Int) -> CGSize? {
        guard originGeneration == generation, currentURLs == urls,
              items.indices.contains(index) else { return nil }
        return items[index].pixelSize
    }
}
