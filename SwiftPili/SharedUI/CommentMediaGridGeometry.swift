import Foundation

extension CommentMediaMetrics {
    static let gridSpacing: CGFloat = 3

    static let singleMaxHeightRatio: CGFloat = 2.6

    struct GridGeometry: Equatable {
        var size: CGSize
        var frames: [CGRect]
        var singleCropsToBox: Bool
    }

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
        let widthRatio = known.map { $0.width / $0.height } ?? 1
        let heightRatio = known.map { $0.height / $0.width } ?? 1
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
