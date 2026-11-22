import CoreGraphics
import QuartzCore

/// The two states of the iPad landscape VOD detail page.
///
/// `.hero` opens the page: an inset rounded player with the content column
/// below it and no comment panel. `.stage` is the working layout: the player
/// pinned top-left, the content column under it, and a floating comment panel
/// on the right. Scrolling switches between them (`DetailStageSwitchPolicy`).
enum DetailStagePresentation: Equatable, Sendable {
    case hero
    case stage
}

/// Geometry of the cinematic iPad landscape detail page. Every number here is
/// App policy, not an Apple threshold.
///
/// The selecting verdict is still `DetailSplitPolicy.usesSplit`; this only
/// lays out a container that verdict already admitted. The container is the
/// width the detail page is OFFERED (measured on a `minWidth: 0` frame, so a
/// player sized from a previous width can never feed its own size back in).
enum DetailStageLayout {
    static let outerMargin: CGFloat = 24
    static let columnGap: CGFloat = 20
    static let playerCornerRadius: CGFloat = 20
    static let panelCornerRadius: CGFloat = 28
    static let stageHeightFraction: CGFloat = 0.62
    static let panelFraction: CGFloat = 0.30
    static let panelMinimumWidth: CGFloat = 340
    static let panelMaximumWidth: CGFloat = 420
    /// The hero's tighter top margin and player-to-content gap, which make
    /// room for the hero bar under a full-width player (user decision D1).
    static let heroTopMargin: CGFloat = 16
    static let heroContentGap: CGFloat = 12

    /// Space above the player for a presentation.
    static func topMargin(for presentation: DetailStagePresentation) -> CGFloat {
        presentation == .hero ? heroTopMargin : outerMargin
    }

    /// Gap between the player's bottom edge and the content column.
    static func contentGap(for presentation: DetailStagePresentation) -> CGFloat {
        presentation == .hero ? heroContentGap : columnGap
    }

    struct Geometry: Equatable {
        var playerSize: CGSize
        var playerOriginX: CGFloat
        var columnWidth: CGFloat
        var columnOriginX: CGFloat
        var panelWidth: CGFloat
    }

    static func panelWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return panelMinimumWidth }
        return min(max(containerWidth * panelFraction, panelMinimumWidth), panelMaximumWidth)
    }

    /// - Parameter heroReserve: the height the hero must keep visible under the
    ///   player — the hero bar plus the content gap — measured by the page.
    ///   Zero means unmeasured, and the hero keeps its full-width player.
    static func geometry(
        for presentation: DetailStagePresentation,
        containerSize: CGSize,
        heroReserve: CGFloat = 0
    ) -> Geometry {
        let width = containerSize.width.isFinite ? max(0, containerSize.width) : 0
        let height = containerSize.height.isFinite ? max(0, containerSize.height) : 0
        let panel = panelWidth(containerWidth: width)
        switch presentation {
        case .hero:
            // Full width between the outer margins whenever the hero bar still
            // fits under the player (11" and 13" landscape). Only a container
            // too short for both (iPad mini landscape, short windows) narrows
            // the player, and then it centres, so the extra space is shared by
            // both sides rather than left on the trailing one.
            let fullWidth = max(0, width - outerMargin * 2)
            var playerWidth = fullWidth
            if heroReserve > 0, heroReserve.isFinite {
                let heightCap = max(0, height - heroTopMargin - heroReserve)
                playerWidth = min(fullWidth, heightCap * 16 / 9)
            }
            playerWidth = floor(playerWidth)
            let column = floor(width)
            return Geometry(
                playerSize: CGSize(width: playerWidth, height: floor(playerWidth * 9 / 16)),
                playerOriginX: floor((width - playerWidth) / 2),
                columnWidth: column,
                columnOriginX: 0,
                panelWidth: panel
            )
        case .stage:
            let available = width - outerMargin * 2 - columnGap - panel
            let player = videoBox(availableWidth: available, heightCap: height * stageHeightFraction)
            return Geometry(
                playerSize: player,
                playerOriginX: outerMargin,
                columnWidth: max(0, floor(available)),
                columnOriginX: outerMargin,
                panelWidth: panel
            )
        }
    }

    /// A 16:9 box as wide as `availableWidth`, narrowed when its height
    /// would pass `heightCap`.
    static func videoBox(availableWidth: CGFloat, heightCap: CGFloat) -> CGSize {
        guard availableWidth.isFinite, availableWidth > 0 else { return .zero }
        var width = availableWidth
        if heightCap.isFinite, heightCap > 0 {
            width = min(width, heightCap * 16 / 9)
        }
        width = floor(width)
        return CGSize(width: width, height: floor(width * 9 / 16))
    }

    /// Where the content column's first row starts: below the player's top
    /// margin, height and gap, measured from the top of the safe area.
    static func contentTopInset(
        playerHeight: CGFloat, presentation: DetailStagePresentation
    ) -> CGFloat {
        topMargin(for: presentation) + max(0, playerHeight) + contentGap(for: presentation)
    }
}

/// Scroll-driven hero ↔ stage switching (user decision H3: both directions).
///
/// `offset` is the content column's scroll position relative to its resting
/// top: positive when the content has moved up, negative while it is pulled
/// down past the top.
///
/// Collapse needs a real scroll up; expansion needs a deliberate pull at the
/// top — merely arriving at the top never expands. The asymmetry and the
/// cooldown are what keep this from re-creating the flip-flop that removed
/// the portrait player's old expand-on-scroll band: the switch changes the
/// column's top inset, which perturbs the next offset sample.
enum DetailStageSwitchPolicy {
    static let collapseOffset: CGFloat = 48
    static let expandPull: CGFloat = 56
    static let cooldown: CFTimeInterval = 0.5

    static func next(
        current: DetailStagePresentation,
        offset: CGFloat
    ) -> DetailStagePresentation? {
        guard offset.isFinite else { return nil }
        switch current {
        case .hero:
            return offset > collapseOffset ? .stage : nil
        case .stage:
            return offset < -expandPull ? .hero : nil
        }
    }
}
