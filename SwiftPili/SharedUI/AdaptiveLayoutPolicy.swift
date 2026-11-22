import Foundation

/// Column counts derived from the feed's usable width (inside horizontal padding) rather than size class alone.
enum FeedColumnPolicy {
    enum Surface {
        /// Cover above title — `GridVideoCardView`.
        case videoGrid
        /// Cover beside text — `VideoCardView`.
        case videoRow
        /// Live cover plus streamer line.
        case liveGrid
        /// Short text-only search term chips.
        case termChips
    }

    /// First multi-column step, placed with >16pt clearance between half Split View (646pt) and iPad mini portrait (712pt).
    private static let firstStep: CGFloat = 680

    /// Column count for `availableWidth` (usable width inside the feed's horizontal padding).
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

    /// Column count for portrait PGC posters on Home Anime and Movies sections.
    static func pgcPosterColumnCount(availableWidth: CGFloat) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 3 }
        if availableWidth < firstStep { return 3 }
        if availableWidth < 900 { return 4 }
        if availableWidth < 1100 { return 5 }
        return 6
    }

    /// Single-column width: usable width minus inter-column gaps, divided by `count`.
    static func columnWidth(availableWidth: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0, availableWidth.isFinite, availableWidth > 0 else { return 0 }
        let gaps = spacing * CGFloat(count - 1)
        return max(0, (availableWidth - gaps) / CGFloat(count))
    }

    /// Card width on horizontal folder-preview shelves (Favorites).
    static func shelfCardWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return 128 }
        if availableWidth < firstStep { return 128 }
        if availableWidth < 1070 { return 196 }
        return 220
    }
}

/// Card width for the followed-anime/show preview rail on Home.
enum PGCFollowedRailPolicy {
    static func cardWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return 96 }
        if availableWidth < 680 { return 96 }
        if availableWidth < 1070 { return 128 }
        return 160
    }
}

/// Shared row spacing and inset constants used across feed and library row layouts.
enum RowGeometry {
    /// Gap between a cover and the text beside it.
    static let coverToTextSpacing: CGFloat = 12
    /// Horizontal inset per side on library rows.
    static let libraryRowHorizontalInset: CGFloat = 16
}

/// Cover sizing for feed and related-video row cards (`VideoCardView`), capped at 38% of column width (max 220pt) so text always keeps the majority share.
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

/// Cover sizing for library rows (`VideoListRowView` and active download rows), capped at 33% of column width (max 140pt).
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

/// Maximum width for attached comment media grids so wide iPad columns keep phone-scale inline attachments.
enum CommentMediaMetrics {
    static let maxWidth: CGFloat = 360
}

/// Maximum readable width for single-column feeds, comments, settings, and forms on wide displays.
enum ReadableWidth {
    static let feed: CGFloat = 760
    static let form: CGFloat = 760

    static func capped(_ availableWidth: CGFloat, to limit: CGFloat = feed) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return limit }
        return min(availableWidth, limit)
    }
}

/// Split-column thresholds and width allocation for landscape iPad detail screens.
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

/// Shared duration and geometry-travel policy for UI and playback chrome transitions.
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

    /// Suppresses spatial travel when Reduce Motion, cross-fade preference, or degraded mode is active.
    static func usesGeometry(
        for kind: Kind,
        reduceMotion: Bool,
        prefersCrossFade: Bool = false,
        degraded: Bool = false
    ) -> Bool {
        !reduceMotion && !prefersCrossFade && !degraded && kind != .microControl
    }
}

/// Shared geometry for detail screens that pin an inline player above scrollable content.
enum DetailPlayerGeometry {
    static let headerBottomInset: CGFloat = 4

    static func headerBottomInset(isFullscreen: Bool) -> CGFloat {
        isFullscreen ? 0 : headerBottomInset
    }

    /// Breathing room between the pinned player header and the first scrollable content row.
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
