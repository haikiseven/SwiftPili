import CoreGraphics
import Foundation

struct ImagePreviewZoomMetrics: Equatable, Sendable {
    let baseSize: CGSize
    let minimumZoomScale: CGFloat
    let nativePixelZoomScale: CGFloat
    let fillViewportZoomScale: CGFloat
    let maximumZoomScale: CGFloat
    let doubleTapZoomScale: CGFloat
}

enum ImagePreviewMath {
    static func fittedSize(in size: CGSize, aspect: CGFloat?) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        guard let aspect, aspect.isFinite, aspect > 0 else { return size }
        if aspect >= size.width / size.height {
            return CGSize(width: size.width, height: size.width / aspect)
        }
        return CGSize(width: size.height * aspect, height: size.height)
    }

    static func baseSize(
        in viewport: CGSize,
        aspect: CGFloat?,
        mode: ImagePreviewDisplayMode
    ) -> CGSize {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        guard let aspect, aspect.isFinite, aspect > 0 else { return viewport }
        if mode == .reading {
            return CGSize(width: viewport.width, height: viewport.width / aspect)
        }
        return fittedSize(in: viewport, aspect: aspect)
    }

    static func zoomMetrics(
        originalPixelSize: CGSize?,
        aspect: CGFloat? = nil,
        viewport: CGSize,
        displayScale: CGFloat,
        mode: ImagePreviewDisplayMode
    ) -> ImagePreviewZoomMetrics {
        let safeScale = (displayScale.isFinite && displayScale > 0) ? displayScale : 1
        let validOriginal = validSize(originalPixelSize)
        let resolvedAspect: CGFloat? = validOriginal.map { $0.width / $0.height } ?? validAspect(aspect)
        let base = baseSize(in: viewport, aspect: resolvedAspect, mode: mode)
        guard base.width > 0, base.height > 0,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return ImagePreviewZoomMetrics(
                baseSize: base,
                minimumZoomScale: 1,
                nativePixelZoomScale: 1,
                fillViewportZoomScale: 1,
                maximumZoomScale: 3,
                doubleTapZoomScale: 2
            )
        }

        let minScale: CGFloat = 1
        let nativeScale: CGFloat = validOriginal.map {
            $0.width / (base.width * safeScale)
        } ?? 1
        let fillScale = max(
            1,
            max(viewport.width / base.width, viewport.height / base.height)
        )
        let maxScale = computeMaximumZoomScale(
            hasOriginalPixels: validOriginal != nil,
            nativeScale: nativeScale,
            fillScale: fillScale,
            mode: mode
        )
        let doubleTapScale = computeDoubleTapZoomScale(
            hasOriginalPixels: validOriginal != nil,
            nativeScale: nativeScale,
            fillScale: fillScale,
            minScale: minScale,
            maxScale: maxScale
        )

        return ImagePreviewZoomMetrics(
            baseSize: base,
            minimumZoomScale: minScale,
            nativePixelZoomScale: nativeScale,
            fillViewportZoomScale: fillScale,
            maximumZoomScale: maxScale,
            doubleTapZoomScale: doubleTapScale
        )
    }

    static func aspectFillFrame(aspect: CGFloat, in box: CGSize, topAligned: Bool) -> CGRect {
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0,
              aspect.isFinite, aspect > 0 else {
            return CGRect(origin: .zero, size: box)
        }
        let boxAspect = box.width / box.height
        let width: CGFloat
        let height: CGFloat
        if aspect > boxAspect {
            height = box.height
            width = height * aspect
        } else {
            width = box.width
            height = width / aspect
        }
        let originX = (box.width - width) / 2
        let originY = topAligned ? 0 : (box.height - height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func zoomRect(
        at point: CGPoint,
        scale: CGFloat,
        viewport: CGSize,
        contentSize: CGSize? = nil
    ) -> CGRect {
        guard scale.isFinite, scale > 0,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return CGRect(origin: .zero, size: viewport)
        }
        let width = viewport.width / scale
        let height = viewport.height / scale
        let rawX = point.x - width / 2
        let rawY = point.y - height / 2
        guard let content = validSize(contentSize) else {
            return CGRect(x: rawX, y: rawY, width: width, height: height)
        }
        let maxX = max(0, content.width - width)
        let maxY = max(0, content.height - height)
        let originX = min(max(rawX, 0), maxX)
        let originY = min(max(rawY, 0), maxY)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static func computeMaximumZoomScale(
        hasOriginalPixels: Bool,
        nativeScale: CGFloat,
        fillScale: CGFloat,
        mode: ImagePreviewDisplayMode
    ) -> CGFloat {
        guard hasOriginalPixels else {
            return max(3, min(fillScale * 1.25, 8))
        }
        if mode == .reading {
            if nativeScale < 0.4 {
                return max(2, nativeScale * 4)
            }
            return min(max(nativeScale * 3, 3), 12)
        }
        if nativeScale < 0.5 {
            return min(max(2, nativeScale * 4), 2.5)
        }
        if nativeScale < 1 {
            return max(nativeScale * 3, min(fillScale * 1.15, 3.5), 2.5)
        }
        let upperCap = max(12, min(max(nativeScale * 2, fillScale * 1.5), 24))
        let desired = max(nativeScale * 2, fillScale * 1.25, 3)
        return min(desired, upperCap)
    }

    private static func computeDoubleTapZoomScale(
        hasOriginalPixels: Bool,
        nativeScale: CGFloat,
        fillScale: CGFloat,
        minScale: CGFloat,
        maxScale: CGFloat
    ) -> CGFloat {
        let rawTarget: CGFloat
        if hasOriginalPixels, nativeScale < 0.5 {
            rawTarget = min(2, maxScale)
        } else if fillScale > 1.35, fillScale <= maxScale {
            rawTarget = max(nativeScale, min(fillScale, 6))
        } else if nativeScale > 1.25 {
            rawTarget = max(nativeScale, 2)
        } else {
            rawTarget = 2
        }
        return min(max(rawTarget, minScale), maxScale)
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

extension CGRect {
    var isUsableImageRect: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
