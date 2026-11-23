import Kingfisher
import ImageIO
import SwiftUI

private struct PlayerAmbientAtlasProcessor: ImageProcessor {
    let tile: PlayerAmbientAtlasTile
    var identifier: String { tile.processorIdentifier }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> UIImage? {
        guard options.scaleFactor == 1, hasBoundedSource(item),
              let image = resolvedAtlasImage(from: item, options: options),
              let pixels = image.cgImage,
              pixels.width <= PlayerAmbientAtlasTile.maximumPixelEdge,
              pixels.height <= PlayerAmbientAtlasTile.maximumPixelEdge else { return nil }
        let expectedWidth = Double(pixels.height) * tile.aspect
        guard abs(Double(pixels.width) - expectedWidth) <= max(4, tile.aspect * 2),
              pixels.width >= tile.columns, pixels.height >= tile.rows else { return nil }
        let left = pixels.width * tile.column / tile.columns
        let top = pixels.height * tile.row / tile.rows
        let right = pixels.width * (tile.column + 1) / tile.columns
        let bottom = pixels.height * (tile.row + 1) / tile.rows
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard let cropped = pixels.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    private func resolvedAtlasImage(
        from item: ImageProcessItem,
        options: KingfisherParsedOptionsInfo
    ) -> UIImage? {
        switch item {
        case .image(let image):
            return image
        case .data:
            return DownsamplingImageProcessor(size: tile.requestSize).process(item: item, options: options)
        }
    }

    private func hasBoundedSource(_ item: ImageProcessItem) -> Bool {
        let limit = PlayerAmbientAtlasTile.maximumPixelEdge
        switch item {
        case .image(let image):
            guard let pixels = image.cgImage else { return false }
            return pixels.width <= limit && pixels.height <= limit
        case .data(let data):
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
            return width > 0 && height > 0 && width <= limit && height <= limit
        }
    }
}

struct AmbientLiveLayerView: UIViewRepresentable {
    func makeUIView(context _: Context) -> AmbientLiveLayerHostView {
        AmbientLiveLayerHostView()
    }

    func updateUIView(_ uiView: AmbientLiveLayerHostView, context _: Context) {}

    static func dismantleUIView(_ uiView: AmbientLiveLayerHostView, coordinator _: Void) {
        AmbientLiveFrameBroadcaster.shared.unregister(uiView)
    }
}

@MainActor
final class AmbientLiveLayerHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        layer.contentsGravity = .resizeAspectFill
        layer.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            AmbientLiveFrameBroadcaster.shared.register(self)
        } else {
            AmbientLiveFrameBroadcaster.shared.unregister(self)
        }
    }

    func apply(frame: CGImage?, animated: Bool) {
        if let frame {
            if animated, !UIAccessibility.isReduceMotionEnabled {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.25
                layer.add(transition, forKey: "ambientFade")
            } else {
                layer.removeAnimation(forKey: "ambientFade")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = frame
            layer.opacity = 1
            CATransaction.commit()
        } else {
            layer.removeAnimation(forKey: "ambientFade")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = nil
            layer.opacity = 0
            CATransaction.commit()
        }
    }
}

struct PlayerAmbientArtworkView: View {
    let source: PlayerAmbientSource
    var crossFadeDuration = PlayerAmbientPolicy.crossFadeDuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(white: 0.035)
            if let cover = source.fallbackCover, !cover.hasPrefix("ambient://") {
                image(cover)
            }
            preview
                .id(source.artwork)
                .transition(.opacity)
        }
        .frame(width: PlayerAmbientPolicy.analysisBox.width, height: PlayerAmbientPolicy.analysisBox.height)
        .clipped()
        .animation(
            reduceMotion ? nil : .easeInOut(duration: crossFadeDuration),
            value: source.artwork
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let tile = source.artwork.tile {
            if let url = tile.resizedURL(source.artwork.url) {
                KFImage(url)
                    .cancelOnDisappear(true)
                    .setProcessor(PlayerAmbientAtlasProcessor(tile: tile))
                    .scaleFactor(1)
                    .cacheOriginalImage()
                    .imageFadePolicy(reduceMotion: reduceMotion)
                    .resizable()
                    .scaledToFill()
                    .frame(width: PlayerAmbientPolicy.analysisBox.width, height: PlayerAmbientPolicy.analysisBox.height)
                    .clipped()
            }
        } else if source.artwork.url != source.fallbackCover,
                  !source.artwork.url.hasPrefix("ambient://") {
            image(source.artwork.url)
        }
    }

    private func image(_ url: String) -> some View {
        CoverImage(
            urlString: url,
            displaySize: PlayerAmbientPolicy.analysisBox,
            contentMode: .fill,
            requestSize: PlayerAmbientPolicy.analysisBox,
            groundColor: Color(white: 0.035),
            isDecorative: true
        )
    }
}
