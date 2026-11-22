import Foundation

/// The comment image grid's geometry — PiliPlus's `_calcGridInfo` — kept
/// `import Foundation` only, like the rest of `CommentMediaMetrics`, so the
/// arithmetic is executed by tests rather than inferred from a preview.
extension CommentMediaMetrics {
    /// Gap between grid cells — the same 3pt `MediaGridView` uses for moments.
    static let gridSpacing: CGFloat = 3

    /// Above this height/width a single image is boxed at this ratio and drawn
    /// top-cropped (PiliPlus `imgMaxRatio`; also `MediaGridView.Media`'s 长图
    /// threshold).
    static let singleMaxHeightRatio: CGFloat = 2.6

    /// Where each of a comment's images draws, inside a grid of `size`.
    struct GridGeometry: Equatable {
        /// The whole grid — narrower than the width it was given for 4 images
        /// (a 2×2 of third cells) and for a single image that is not wide.
        var size: CGSize
        /// One frame per DRAWN image (at most nine), top-leading origin.
        var frames: [CGRect]
        /// The single image's box differs from its source aspect, so it must be
        /// filled and top-cropped: a source taller than `singleMaxHeightRatio`,
        /// or one with no known dimensions. Always `false` for a grid.
        var singleCropsToBox: Bool
    }

    /// PiliPlus's comment image sizing (`image_grid_builder.dart`
    /// `_calcGridInfo`), at `width` = min(row width, `maxWidth`).
    ///
    /// - Grid: a THIRD cell, `(W − 2·spacing) / 3`, for every count except two,
    ///   which get halves. Four images are a 2×2 of third cells, so the grid is
    ///   narrower than `W`; three and five-plus are three columns.
    /// - Single image, with `r` = height / width of the source and `third` the
    ///   grid's third cell: wider than 1.45:1 → `W`; otherwise `r < 1.5` →
    ///   2·`third`; taller → 1.5·`third` (236 / 177pt at W = 360 — about ⅔ and
    ///   ½ of `W`, but measured in cells, exactly as PiliPlus computes them).
    ///   Never wider than the source's pixel width (taken as points, as
    ///   PiliPlus does).
    ///   Height = width × min(`r`, 2.6), so the box IS the image's aspect —
    ///   nothing to letterbox — up to the long-image cap.
    /// - No known dimensions: a two-cell square (PiliPlus treats an unknown
    ///   size as 1×1) the image is cropped into, with no pixel-width clamp.
    static func gridGeometry(
        count: Int,
        singlePixelSize: CGSize?,
        width: CGFloat,
        spacing: CGFloat = gridSpacing
    ) -> GridGeometry {
        let available = width.isFinite ? max(0, width) : 0
        let drawn = min(max(count, 0), 9)
        guard drawn > 0 else {
            return GridGeometry(size: .zero, frames: [], singleCropsToBox: false)
        }
        if drawn == 1 {
            return singleGeometry(pixelSize: singlePixelSize, width: available, spacing: spacing)
        }
        let columns = drawn == 2 || drawn == 4 ? 2 : 3
        let cell = drawn == 2
            ? max(0, (available - spacing) / 2)
            : max(0, (available - 2 * spacing) / 3)
        // Less width than the gaps: nothing to draw, and the gaps alone must not
        // report a grid wider than the width it was given.
        guard cell > 0 else {
            return GridGeometry(
                size: .zero,
                frames: Array(repeating: .zero, count: drawn),
                singleCropsToBox: false
            )
        }
        let rows = (drawn + columns - 1) / columns
        let frames = (0..<drawn).map { index in
            CGRect(
                x: CGFloat(index % columns) * (cell + spacing),
                y: CGFloat(index / columns) * (cell + spacing),
                width: cell,
                height: cell
            )
        }
        let size = CGSize(
            width: CGFloat(columns) * cell + CGFloat(columns - 1) * spacing,
            height: CGFloat(rows) * cell + CGFloat(rows - 1) * spacing
        )
        return GridGeometry(size: size, frames: frames, singleCropsToBox: false)
    }

    /// Whether a single image's box differs from its source aspect — the
    /// `GridGeometry.singleCropsToBox` verdict, which depends on no width.
    static func singleCropsToBox(_ pixelSize: CGSize?) -> Bool {
        guard let known = usableSize(pixelSize) else { return true }
        return known.height / known.width > singleMaxHeightRatio
    }

    private static func usableSize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else { return nil }
        return size
    }

    private static func singleGeometry(pixelSize: CGSize?, width: CGFloat, spacing: CGFloat) -> GridGeometry {
        let known = usableSize(pixelSize)
        // Both ratios straight from the dimensions, as PiliPlus computes them —
        // `1 / heightRatio` would round a 1450×1000 source across the 1.45 edge.
        let widthRatio = known.map { $0.width / $0.height } ?? 1
        let heightRatio = known.map { $0.height / $0.width } ?? 1
        // The narrower bands are multiples of the grid's THIRD cell, not of
        // `W` — PiliPlus's `2 * imageWidth` / `1.5 * imageWidth` — which is
        // where the PRD's 236 / 177pt at W = 360 come from (⅔·W would be 240).
        let third = max(0, (width - 2 * spacing) / 3)
        var boxWidth: CGFloat = if widthRatio > 1.45 {
            width
        } else if heightRatio < 1.5 {
            2 * third
        } else {
            1.5 * third
        }
        if let known {
            boxWidth = min(boxWidth, known.width)
        }
        let boxHeight = boxWidth * min(heightRatio, singleMaxHeightRatio)
        let box = CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight)
        return GridGeometry(
            size: box.size,
            frames: [box],
            singleCropsToBox: singleCropsToBox(pixelSize)
        )
    }
}
