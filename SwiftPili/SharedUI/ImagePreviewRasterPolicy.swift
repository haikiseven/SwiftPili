import Foundation
import Kingfisher

enum ImagePreviewDisplayMode {
    case fitted
    case reading
}

/// Pixel headroom at scaleFactor 1 and display-mode classification for stills and GIFs.
enum ImagePreviewRasterPolicy {
    static func isGIF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }

    static func displayMode(url: URL, aspect: CGFloat?) -> ImagePreviewDisplayMode {
        !isGIF(url) && readsVertically(aspect: aspect) ? .reading : .fitted
    }

    static func imageFrame(in size: CGSize, aspect: CGFloat, mode: ImagePreviewDisplayMode) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              aspect.isFinite, aspect > 0 else { return nil }
        let fitted = mode == .reading
            ? CGSize(width: size.width, height: size.width / aspect)
            : ImagePreviewMath.fittedSize(in: size, aspect: aspect)
        let frame = CGRect(
            x: (size.width - fitted.width) / 2,
            y: mode == .reading ? 0 : (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        return frame.isUsableImageRect ? frame : nil
    }

    static func readsVertically(aspect: CGFloat?) -> Bool {
        guard let aspect, aspect.isFinite, aspect > 0 else { return false }
        return aspect < 1.0 / 2.6
    }

    static func zoomTarget(size: CGSize, aspect: CGFloat? = nil) -> CGSize {
        let viewport = CGSize(width: validDimension(size.width), height: validDimension(size.height))
        let fitted = ImagePreviewMath.fittedSize(in: viewport, aspect: aspect)
        return CGSize(width: fitted.width * 2, height: fitted.height * 2)
    }

    static func readingTarget(width: CGFloat, aspect: CGFloat? = nil) -> CGSize {
        let width = validDimension(width)
        let cap = width * 16
        guard let aspect, aspect.isFinite, aspect > 0 else {
            return CGSize(width: width * 2, height: cap)
        }
        let edge = min(cap, max(width * 2, width * 2 / aspect))
        return aspect <= 1
            ? CGSize(width: edge * aspect, height: edge)
            : CGSize(width: edge, height: edge / aspect)
    }

    nonisolated static func canonicalEdge(target: CGSize) -> CGFloat {
        max(target.width, target.height)
    }

    static func fullProcessor(target: CGSize) -> DownsamplingImageProcessor {
        let edge = canonicalEdge(target: target)
        return DownsamplingImageProcessor(size: CGSize(width: edge, height: edge))
    }

    /// Only hdslb.com and its subdomains without query, fragment, or `@` receive a resize suffix.
    static func thumbnailURL(for url: URL, viewportWidth: CGFloat) -> URL {
        let base = url.absoluteString
        let width = Int(validDimension(viewportWidth).rounded())
        guard let host = url.host?.lowercased(),
              host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
              url.query == nil, url.fragment == nil, !base.contains("@"),
              let thumb = URL(string: "\(base)@\(width)w.webp") else {
            return url
        }
        return thumb
    }

    static func stillOptions(target: CGSize, cacheOriginal: Bool = true) -> KingfisherOptionsInfo {
        var options: KingfisherOptionsInfo = [
            .processor(fullProcessor(target: target)),
            .backgroundDecode,
            .transition(.none),
        ]
        if cacheOriginal {
            options.append(.cacheOriginalImage)
        }
        return options
    }

    private static func validDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0, value <= CGFloat.greatestFiniteMagnitude / 16 else { return 1 }
        return max(value, 1)
    }
}
