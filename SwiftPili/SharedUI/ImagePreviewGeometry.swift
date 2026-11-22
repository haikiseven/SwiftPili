import CoreGraphics
import Foundation

/// Pure geometry helpers for fitted frames, aspect-fill source morphing, and zoom targets.
enum ImagePreviewMath {
    static func fittedSize(in size: CGSize, aspect: CGFloat?) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        guard let aspect, aspect.isFinite, aspect > 0 else { return size }
        if aspect >= size.width / size.height {
            return CGSize(width: size.width, height: size.width / aspect)
        }
        return CGSize(width: size.height * aspect, height: size.height)
    }

    /// Computes an aspect-filled child frame inside `box`, aligned either to `.top` (long images) or `.center`.
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

    /// Computes the `UIScrollView.zoom(to:animated:)` rectangle centered around a tap point.
    static func zoomRect(at point: CGPoint, scale: CGFloat, viewport: CGSize) -> CGRect {
        guard scale.isFinite, scale > 0, viewport.width > 0, viewport.height > 0 else {
            return CGRect(origin: .zero, size: viewport)
        }
        let width = viewport.width / scale
        let height = viewport.height / scale
        return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }
}

extension CGRect {
    var isUsableImageRect: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
