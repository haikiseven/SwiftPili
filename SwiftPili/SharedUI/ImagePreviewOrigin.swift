import Kingfisher
import SwiftUI
import UIKit

@MainActor struct ImagePreviewSourceSnapshot {
    let frameInWindow: CGRect
    let visibleFrameInWindow: CGRect
    let cornerRadius: CGFloat
    let cornerCurve: CALayerCornerCurve
    let topAligned: Bool
    let pixelSize: CGSize?
    let thumbnailImage: UIImage?
    let isServerCropped: Bool
    weak var sourceView: UIView?
}

@MainActor protocol ImagePreviewOriginProvider: AnyObject {
    func resolveSource(generation: UUID, urls: [URL], index: Int, in window: UIWindow) -> ImagePreviewSourceSnapshot?
    func pixelSize(generation: UUID, urls: [URL], index: Int) -> CGSize?
}

@MainActor struct ImagePreviewOrigin {
    private weak var provider: (any ImagePreviewOriginProvider)?
    let generation: UUID
    let urls: [URL]

    init(provider: any ImagePreviewOriginProvider, generation: UUID, urls: [URL]) {
        self.provider = provider
        self.generation = generation
        self.urls = urls
    }

    func resolve(index: Int, in window: UIWindow) -> ImagePreviewSourceSnapshot? {
        provider?.resolveSource(generation: generation, urls: urls, index: index, in: window)
    }

    func pixelSize(at index: Int) -> CGSize? {
        provider?.pixelSize(generation: generation, urls: urls, index: index)
    }
}

@MainActor enum ImagePreviewMemoryLookup {
    static func resolveOpeningImage(
        url: URL,
        tileImage: UIImage?,
        viewportSize: CGSize,
        pixelSize: CGSize?
    ) -> (image: UIImage?, isServerCropped: Bool) {
        if let cachedFull = cachedUncroppedImage(for: url, viewportSize: viewportSize, pixelSize: pixelSize) {
            return (cachedFull, false)
        }
        guard let tileImage else { return (nil, false) }
        return (tileImage, detectsServerCrop(tileImage: tileImage, pixelSize: pixelSize))
    }

    static func cachedUncroppedImage(
        for url: URL, viewportSize: CGSize, pixelSize: CGSize?
    ) -> UIImage? {
        let cache = KingfisherManager.shared.cache
        let aspect = validAspect(from: pixelSize)
        let mode = ImagePreviewRasterPolicy.displayMode(url: url, aspect: aspect)
        let target = mode == .reading
            ? ImagePreviewRasterPolicy.readingTarget(width: viewportSize.width, aspect: aspect)
            : ImagePreviewRasterPolicy.zoomTarget(size: viewportSize, aspect: aspect)
        let processedOpts = KingfisherParsedOptionsInfo([
            .processor(ImagePreviewRasterPolicy.fullProcessor(target: target))
        ])
        if let processed = cache.retrieveImageInMemoryCache(forKey: url.cacheKey, options: processedOpts) {
            return processed
        }
        if let original = cache.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            return original
        }
        let thumbURL = ImagePreviewRasterPolicy.thumbnailURL(for: url, viewportWidth: viewportSize.width)
        if thumbURL != url,
           let thumb = cache.retrieveImageInMemoryCache(forKey: thumbURL.cacheKey, options: processedOpts)
            ?? cache.retrieveImageInMemoryCache(forKey: thumbURL.cacheKey) {
            return thumb
        }
        return nil
    }

    static func detectsServerCrop(tileImage: UIImage, pixelSize: CGSize?) -> Bool {
        guard let fullAspect = validAspect(from: pixelSize),
              let thumbAspect = validAspect(from: CGSize(
                width: tileImage.size.width * tileImage.scale,
                height: tileImage.size.height * tileImage.scale
              )) else { return false }
        return abs(thumbAspect / fullAspect - 1) > 0.05
    }

    private static func validAspect(from size: CGSize?) -> CGFloat? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}

@MainActor enum ImagePreviewSourceVisibilityCheck {
    static func visibleFrame(of view: UIView, in window: UIWindow) -> (frame: CGRect, visible: CGRect)? {
        guard view.window === window,
              window.windowScene?.activationState == .foregroundActive,
              view.bounds.isUsableImageRect,
              window.bounds.isUsableImageRect else { return nil }
        let frame = view.convert(view.bounds, to: window)
        guard frame.isUsableImageRect else { return nil }
        var visible = frame.intersection(window.bounds)
        var cursor: UIView? = view
        while let current = cursor {
            guard !current.isHidden, current.alpha > 0.01 else { return nil }
            if current !== view, current.clipsToBounds || current is UIScrollView {
                let insets = (current as? UIScrollView)?.adjustedContentInset ?? .zero
                let clipRect = current.convert(current.bounds.inset(by: insets), to: window)
                guard clipRect.isUsableImageRect else { return nil }
                visible = visible.intersection(clipRect)
            }
            cursor = current.superview
        }
        guard visible.isUsableImageRect else { return nil }
        return (frame, visible)
    }
}

@MainActor final class ImagePreviewSourceGroup: ImagePreviewOriginProvider {
    private var generation = UUID()
    private var sourceID: String?
    private var urls: [URL] = []
    private var anchors: [Int: WeakAnchor] = [:]
    private var loadedThumbnails: [Int: RecordedThumbnail] = [:]

    private struct WeakAnchor {
        weak var view: ImagePreviewSourceAnchor?
    }

    private struct RecordedThumbnail {
        let url: URL
        let image: UIImage
    }

    func recordThumbnail(_ image: UIImage, for url: URL, index: Int) {
        loadedThumbnails[index] = RecordedThumbnail(url: url, image: image)
    }

    func makeItem(urls: [URL], index: Int, sourceID: String? = nil) -> ImagePreviewItem {
        bind(urls: urls, sourceID: sourceID)
        guard let sourceID, !sourceID.isEmpty else {
            return ImagePreviewItem(urls: urls, index: index)
        }
        let origin = ImagePreviewOrigin(provider: self, generation: generation, urls: urls)
        return ImagePreviewItem(urls: urls, index: index, origin: origin)
    }

    func resolveSource(
        generation: UUID, urls: [URL], index: Int, in window: UIWindow
    ) -> ImagePreviewSourceSnapshot? {
        guard self.generation == generation, self.urls == urls,
              let sourceID, !sourceID.isEmpty, urls.indices.contains(index),
              let anchor = anchors[index]?.view,
              anchor.generation == generation, anchor.sourceID == sourceID,
              anchor.urls == urls, anchor.index == index,
              let rects = ImagePreviewSourceVisibilityCheck.visibleFrame(of: anchor, in: window) else {
            return nil
        }
        let scale = rects.frame.width / anchor.bounds.width
        let radius = (anchor.cornerRadius * scale).isFinite ? max(0, anchor.cornerRadius * scale) : 0
        let pixels = validPixelSize(anchor.pixelSize)
        let recorded = loadedThumbnails[index].flatMap { $0.url == urls[index] ? $0.image : nil }
        let resolved = ImagePreviewMemoryLookup.resolveOpeningImage(
            url: urls[index],
            tileImage: recorded,
            viewportSize: window.bounds.size,
            pixelSize: pixels
        )
        return ImagePreviewSourceSnapshot(
            frameInWindow: rects.frame,
            visibleFrameInWindow: rects.visible,
            cornerRadius: radius,
            cornerCurve: .continuous,
            topAligned: anchor.alignment.vertical == .top,
            pixelSize: pixels,
            thumbnailImage: resolved.image,
            isServerCropped: resolved.isServerCropped,
            sourceView: nil
        )
    }

    func pixelSize(generation: UUID, urls: [URL], index: Int) -> CGSize? {
        guard self.generation == generation, self.urls == urls,
              let sourceID, !sourceID.isEmpty, urls.indices.contains(index),
              let anchor = anchors[index]?.view,
              anchor.generation == generation, anchor.sourceID == sourceID,
              anchor.urls == urls, anchor.index == index else { return nil }
        return validPixelSize(anchor.pixelSize)
    }

    fileprivate func bind(urls: [URL], sourceID: String?) {
        guard self.urls != urls || self.sourceID != sourceID else { return }
        generation = UUID()
        self.urls = urls
        self.sourceID = sourceID
        anchors.removeAll()
        loadedThumbnails = loadedThumbnails.filter { index, recorded in
            urls.indices.contains(index) && urls[index] == recorded.url
        }
    }

    fileprivate func register(_ view: ImagePreviewSourceAnchor) {
        bind(urls: view.urls, sourceID: view.sourceID)
        view.group = self
        view.generation = generation
        anchors[view.index] = WeakAnchor(view: view)
    }

    fileprivate func unregister(_ view: ImagePreviewSourceAnchor) {
        guard anchors[view.index]?.view === view else { return }
        anchors[view.index] = nil
    }

    private func validPixelSize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

@MainActor final class ImagePreviewSourceAnchor: UIView {
    fileprivate weak var group: ImagePreviewSourceGroup?
    var generation = UUID()
    var sourceID: String?
    var urls: [URL] = []
    var index = 0
    var pixelSize: CGSize?
    var cornerRadius: CGFloat = 0
    var cropped = false
    var alignment = Alignment.center
}

private struct ImagePreviewSourceRegistration: UIViewRepresentable {
    let group: ImagePreviewSourceGroup
    let sourceID: String?
    let urls: [URL]
    let index: Int
    let pixelSize: CGSize?
    let cornerRadius: CGFloat
    let cropped: Bool
    let alignment: Alignment

    func makeUIView(context: Context) -> ImagePreviewSourceAnchor {
        let view = ImagePreviewSourceAnchor()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ImagePreviewSourceAnchor, context: Context) {
        if view.group !== group || view.index != index || view.sourceID != sourceID || view.urls != urls {
            view.group?.unregister(view)
        }
        view.sourceID = sourceID
        view.urls = urls
        view.index = index
        view.pixelSize = pixelSize
        view.cornerRadius = cornerRadius
        view.cropped = cropped
        view.alignment = alignment
        group.register(view)
    }

    static func dismantleUIView(_ view: ImagePreviewSourceAnchor, coordinator: ()) {
        view.group?.unregister(view)
    }
}

extension View {
    // swiftlint:disable:next function_parameter_count
    func imagePreviewSource(
        group: ImagePreviewSourceGroup, sourceID: String?, urls: [URL], index: Int,
        pixelSize: CGSize?, cornerRadius: CGFloat, cropped: Bool,
        alignment: Alignment = .center
    ) -> some View {
        overlay {
            ImagePreviewSourceRegistration(
                group: group, sourceID: sourceID, urls: urls, index: index,
                pixelSize: pixelSize, cornerRadius: cornerRadius,
                cropped: cropped, alignment: alignment
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
