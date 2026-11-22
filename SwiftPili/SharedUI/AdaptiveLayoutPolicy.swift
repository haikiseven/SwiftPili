import Foundation

enum FeedColumnPolicy {
    enum Surface {
        case videoGrid
        case videoRow
        case liveGrid
        case termChips
    }

    private static let firstStep: CGFloat = 680

    static func columnCount(_ surface: Surface, availableWidth: CGFloat) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 1 }
        switch surface {
        case .videoGrid:
            if availableWidth < firstStep { return 2 }
            if availableWidth < 1070 { return 3 }
            return 4
        case .videoRow:
            if availableWidth < firstStep { return 1 }
            if availableWidth < 1250 { return 2 }
            return 3
        case .liveGrid:
            if availableWidth < firstStep { return 2 }
            if availableWidth < 960 { return 3 }
            return 4
        case .termChips:
            if availableWidth < firstStep { return 2 }
            return 3
        }
    }

    static func pgcPosterColumnCount(availableWidth: CGFloat) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 3 }
        if availableWidth < firstStep { return 3 }
        if availableWidth < 900 { return 4 }
        if availableWidth < 1100 { return 5 }
        return 6
    }

    static func columnWidth(availableWidth: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0, availableWidth.isFinite, availableWidth > 0 else { return 0 }
        let gaps = spacing * CGFloat(count - 1)
        return max(0, (availableWidth - gaps) / CGFloat(count))
    }

    static func shelfCardWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return 128 }
        if availableWidth < firstStep { return 128 }
        if availableWidth < 1070 { return 196 }
        return 220
    }
}

enum PGCFollowedRailPolicy {
    static func cardWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return 96 }
        if availableWidth < 680 { return 96 }
        if availableWidth < 1070 { return 128 }
        return 160
    }
}

enum RowGeometry {
    static let coverToTextSpacing: CGFloat = 12
    static let libraryRowHorizontalInset: CGFloat = 16
}

enum RowCardMetrics {
    static let compactCoverWidth: CGFloat = 160
    static let maximumCoverWidth: CGFloat = 220
    static let coverFraction: CGFloat = 0.38
    static var coverToTextSpacing: CGFloat { RowGeometry.coverToTextSpacing }

    static func coverWidth(columnWidth: CGFloat?, isRegularWidth: Bool) -> CGFloat {
        guard isRegularWidth else { return compactCoverWidth }
        guard let columnWidth, columnWidth.isFinite, columnWidth > 0 else {
            return maximumCoverWidth
        }
        return min(columnWidth * coverFraction, maximumCoverWidth)
    }

    static func textWidth(columnWidth: CGFloat, isRegularWidth: Bool) -> CGFloat {
        let cover = coverWidth(columnWidth: columnWidth, isRegularWidth: isRegularWidth)
        return max(0, columnWidth - cover - coverToTextSpacing)
    }
}

enum LibraryRowMetrics {
    static let maximumCoverWidth: CGFloat = 140
    static let coverFraction: CGFloat = 0.33

    static func coverWidth(columnWidth: CGFloat?, isRegularWidth: Bool) -> CGFloat {
        guard isRegularWidth else { return 110 }
        guard let columnWidth, columnWidth.isFinite, columnWidth > 0 else {
            return maximumCoverWidth
        }
        return min(columnWidth * coverFraction, maximumCoverWidth)
    }

    static func textWidth(columnWidth: CGFloat, isRegularWidth: Bool) -> CGFloat {
        let cover = coverWidth(columnWidth: columnWidth, isRegularWidth: isRegularWidth)
        return max(0, columnWidth - cover - rowInsetsAndSpacing)
    }

    static var coverToTextSpacing: CGFloat { RowGeometry.coverToTextSpacing }
    static var horizontalInset: CGFloat { RowGeometry.libraryRowHorizontalInset }
    static var rowInsetsAndSpacing: CGFloat { horizontalInset * 2 + coverToTextSpacing }
}

enum CommentMediaMetrics {
    static let maxWidth: CGFloat = 360
}

enum ReadableWidth {
    static let feed: CGFloat = 760
    static let form: CGFloat = 760

    static func capped(_ availableWidth: CGFloat, to limit: CGFloat = feed) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return limit }
        return min(availableWidth, limit)
    }
}

enum DetailSplitPolicy {
    static let companionPreferredFraction: CGFloat = 0.4
    static let companionMinimumWidth: CGFloat = 340
    static let primaryMinimumWidth: CGFloat = 400
    static let companionMaximumWidth: CGFloat = 420
    static let primaryMaximumWidth: CGFloat = 820

    static func usesSplit(
        isPad: Bool,
        containerSize: CGSize
    ) -> Bool {
        guard isPad,
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              containerSize.width > 0,
              containerSize.height > 0
        else { return false }
        return containerSize.width > containerSize.height
            && containerSize.width >= primaryMinimumWidth + companionMinimumWidth
    }

    static func companionColumnWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return companionMinimumWidth }
        let preferred = containerWidth * companionPreferredFraction
        return min(max(preferred, companionMinimumWidth), companionMaximumWidth)
    }

    static func primaryColumnWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return 0 }
        let available = max(0, containerWidth - companionColumnWidth(containerWidth: containerWidth))
        return min(available, primaryMaximumWidth)
    }
}

enum AppMotionPolicy {
    enum Kind: Equatable, Sendable {
        case microControl
        case control
        case page
        case settle
    }

    static func duration(
        for kind: Kind,
        reduceMotion: Bool,
        prefersCrossFade: Bool = false,
        degraded: Bool = false
    ) -> TimeInterval {
        if reduceMotion || prefersCrossFade || degraded {
            return kind == .microControl ? 0.08 : 0.12
        }
        switch kind {
        case .microControl:
            return 0.12
        case .control:
            return 0.20
        case .page:
            return 0.24
        case .settle:
            return 0.24
        }
    }

    static func usesGeometry(
        for kind: Kind,
        reduceMotion: Bool,
        prefersCrossFade: Bool = false,
        degraded: Bool = false
    ) -> Bool {
        !reduceMotion && !prefersCrossFade && !degraded && kind != .microControl
    }
}

enum DetailPlayerGeometry {
    static let headerBottomInset: CGFloat = 4

    static func headerBottomInset(isFullscreen: Bool) -> CGFloat {
        isFullscreen ? 0 : headerBottomInset
    }

    static let contentTopGap: CGFloat = 8

    static func pinnedHeaderHeight(
        videoHeight: CGFloat,
        isFullscreen: Bool
    ) -> CGFloat {
        max(0, videoHeight) + headerBottomInset(isFullscreen: isFullscreen)
    }

    static func videoHeight(
        containerWidth: CGFloat,
        primaryColumnWidth: CGFloat?,
        isPortraitContent: Bool,
        isCondensed: Bool
    ) -> CGFloat {
        let base = containerWidth > 0 ? containerWidth : 0
        let width = primaryColumnWidth.map { min(base, $0) } ?? base
        guard width > 0 else { return 0 }
        let aspect: CGFloat = isPortraitContent
            ? (isCondensed ? 16.0 / 9.0 : 3.0 / 4.0)
            : 16.0 / 9.0
        return width / aspect
    }
}
