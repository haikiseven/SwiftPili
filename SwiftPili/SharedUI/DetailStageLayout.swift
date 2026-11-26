import CoreGraphics
import QuartzCore

enum DetailStagePresentation: Equatable, Sendable {
    case hero
    case stage
}

enum DetailStageLayout {
    static let outerMargin: CGFloat = 24
    static let columnGap: CGFloat = 20
    static let playerCornerRadius: CGFloat = 20
    static let panelCornerRadius: CGFloat = 28
    static let stageHeightFraction: CGFloat = 0.62
    static let panelFraction: CGFloat = 0.32
    static let panelMinimumWidth: CGFloat = 340
    static let panelMaximumWidth: CGFloat = 440
    static let heroTopMargin: CGFloat = 16
    static let heroContentGap: CGFloat = 12
    static let defaultHeroBarHeight: CGFloat = 96

    static func topMargin(for presentation: DetailStagePresentation) -> CGFloat {
        presentation == .hero ? heroTopMargin : outerMargin
    }

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

    static func videoBox(availableWidth: CGFloat, heightCap: CGFloat) -> CGSize {
        guard availableWidth.isFinite, availableWidth > 0 else { return .zero }
        var width = availableWidth
        if heightCap.isFinite, heightCap > 0 {
            width = min(width, heightCap * 16 / 9)
        }
        width = floor(width)
        return CGSize(width: width, height: floor(width * 9 / 16))
    }

    static func contentTopInset(
        playerHeight: CGFloat, presentation: DetailStagePresentation
    ) -> CGFloat {
        topMargin(for: presentation) + max(0, playerHeight) + contentGap(for: presentation)
    }
}

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
