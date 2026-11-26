import CoreGraphics
import Foundation
import Kingfisher

enum ImagePreviewDisplayMode: Equatable, Sendable {
    case fitted
    case reading
}

enum ImagePreviewRasterPolicy {
    static let initialPixelBudget: CGFloat = 16_777_216
    static let zoomedPixelBudget: CGFloat = 33_554_432
    static let maxTexturePixelEdge: CGFloat = 16_384
    static let fallbackUnknownPixelEdge: CGFloat = 4_096
    static let maxThumbnailPixelWidth: CGFloat = 2_048

    static func isBilibiliImageHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "hdslb.com"
            || host.hasSuffix(".hdslb.com")
            || host == "biliimg.com"
            || host.hasSuffix(".biliimg.com")
    }

    static func originalURL(for url: URL) -> URL {
        guard isBilibiliImageHost(url.host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let path = components.percentEncodedPath
        let segmentStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        guard let atIndex = path[segmentStart...].firstIndex(of: "@"),
              atIndex > segmentStart else {
            return url
        }
        components.percentEncodedPath = String(path[..<atIndex])
        return components.url ?? url
    }

    static func isGIF(_ url: URL) -> Bool {
        originalURL(for: url).pathExtension.lowercased() == "gif"
    }

    static func displayMode(
        url: URL,
        aspect: CGFloat?,
        viewport: CGSize? = nil
    ) -> ImagePreviewDisplayMode {
        !isGIF(url) && readsVertically(aspect: aspect, viewport: viewport) ? .reading : .fitted
    }

    static func readsVertically(aspect: CGFloat?, viewport: CGSize? = nil) -> Bool {
        guard let aspect, aspect.isFinite, aspect > 0 else { return false }
        let absoluteMaxAspect: CGFloat = 1.0 / 2.2
        guard let viewport,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return aspect < 1.0 / 2.4
        }
        let viewportAspect = viewport.width / viewport.height
        let threshold = min(absoluteMaxAspect, viewportAspect / 1.14)
        return aspect < threshold
    }

    static func initialDecodePixelEdge(
        originalPixelSize: CGSize?,
        aspect: CGFloat? = nil,
        viewport: CGSize,
        displayScale: CGFloat,
        mode: ImagePreviewDisplayMode
    ) -> CGFloat {
        if let original = validSize(originalPixelSize) {
            return budgetedPixelEdge(
                for: original,
                pixelBudget: initialPixelBudget,
                maxEdge: maxTexturePixelEdge
            )
        }
        let scale = validScale(displayScale)
        let safeViewport = CGSize(
            width: validDimension(viewport.width),
            height: validDimension(viewport.height)
        )
        let viewportPhysWidth = safeViewport.width * scale
        let viewportPhysHeight = safeViewport.height * scale
        let effectiveAspect = validAspect(aspect)

        if mode == .reading, let effectiveAspect {
            let widthMatchedEdge = max(viewportPhysWidth, viewportPhysWidth / effectiveAspect)
            let budgetEdge = sqrt(initialPixelBudget * max(effectiveAspect, 1 / effectiveAspect))
            let edge = min(max(fallbackUnknownPixelEdge, widthMatchedEdge), budgetEdge, maxTexturePixelEdge)
            return max(1, ceil(edge))
        }

        if let effectiveAspect {
            let budgetEdge = sqrt(initialPixelBudget * max(effectiveAspect, 1 / effectiveAspect))
            let desired = max(fallbackUnknownPixelEdge, max(viewportPhysWidth, viewportPhysHeight) * 2)
            let edge = min(desired, budgetEdge, maxTexturePixelEdge)
            return max(1, ceil(edge))
        }

        return fallbackUnknownPixelEdge
    }

    static func zoomedDecodePixelEdge(originalPixelSize: CGSize) -> CGFloat {
        guard let original = validSize(originalPixelSize) else {
            return fallbackUnknownPixelEdge
        }
        return budgetedPixelEdge(
            for: original,
            pixelBudget: zoomedPixelBudget,
            maxEdge: maxTexturePixelEdge
        )
    }

    static func fullProcessor(pixelEdge: CGFloat, displayScale: CGFloat) -> DownsamplingImageProcessor {
        let scale = validScale(displayScale)
        let safePixels = validDimension(pixelEdge)
        let pointEdge = ceil(safePixels / scale)
        return DownsamplingImageProcessor(size: CGSize(width: pointEdge, height: pointEdge))
    }

    static func thumbnailURL(
        for url: URL,
        viewportWidth: CGFloat,
        displayScale: CGFloat = 1
    ) -> URL {
        let canonical = originalURL(for: url)
        let scale = validScale(displayScale)
        let physicalWidth = Int(min(ceil(validDimension(viewportWidth) * scale), maxThumbnailPixelWidth))
        guard isBilibiliImageHost(canonical.host),
              !isGIF(canonical),
              canonical.query == nil,
              canonical.fragment == nil,
              !canonical.absoluteString.contains("@"),
              let thumb = URL(string: "\(canonical.absoluteString)@\(physicalWidth)w.webp") else {
            return canonical
        }
        return thumb
    }

    static func stillOptions(
        pixelEdge: CGFloat,
        displayScale: CGFloat,
        cacheOriginal: Bool = true
    ) -> KingfisherOptionsInfo {
        let scale = validScale(displayScale)
        var options: KingfisherOptionsInfo = [
            .processor(fullProcessor(pixelEdge: pixelEdge, displayScale: scale)),
            .scaleFactor(scale),
            .backgroundDecode,
            .transition(.none),
        ]
        if cacheOriginal {
            options.append(.cacheOriginalImage)
        }
        return options
    }

    private static func budgetedPixelEdge(
        for pixelSize: CGSize,
        pixelBudget: CGFloat,
        maxEdge: CGFloat
    ) -> CGFloat {
        let longestEdge = max(pixelSize.width, pixelSize.height)
        let totalPixels = pixelSize.width * pixelSize.height
        let budgetScale = totalPixels > pixelBudget ? sqrt(pixelBudget / totalPixels) : 1
        let clampedEdge = min(longestEdge, longestEdge * budgetScale, maxEdge)
        return max(1, ceil(clampedEdge))
    }

    private static func validDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0, value <= CGFloat.greatestFiniteMagnitude / 16 else { return 1 }
        return max(value, 1)
    }

    private static func validScale(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0, value <= 8 else { return 1 }
        return value
    }

    private static func validSize(_ size: CGSize?) -> CGSize? {
        guard let size,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private static func validAspect(_ aspect: CGFloat?) -> CGFloat? {
        guard let aspect, aspect.isFinite, aspect > 0 else { return nil }
        return aspect
    }
}
