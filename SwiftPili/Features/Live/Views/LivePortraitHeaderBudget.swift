import CoreGraphics

struct LivePortraitHeaderBudget: Equatable, Sendable {
    static let controlSide: CGFloat = 44
    static let avatarSide: CGFloat = 30
    static let interitemSpacing: CGFloat = 8
    static let pillLeadingPadding: CGFloat = 6
    static let pillTrailingPaddingWithoutFollow: CGFloat = 12
    static let pillTrailingPaddingWithFollow: CGFloat = 6
    static let pillFollowSpacing: CGFloat = 6
    static let overlayHorizontalPadding: CGFloat = 12
    static let qualityChipChrome: CGFloat = 11 * 2 + 12 + 4
    static let minimumHostWidth: CGFloat = 72
    static let minimumUsefulQualityLabelWidth: CGFloat = 30

    let containerWidth: CGFloat
    let reservedWidth: CGFloat
    let sharedWidth: CGFloat
    let qualityLabelMaxWidth: CGFloat
    let hostBlockWidth: CGFloat
    let showsQualityLabel: Bool
    let showsQualityControl: Bool

    static func resolve(
        containerWidth: CGFloat,
        leadingSafeAreaInset: CGFloat = 0,
        trailingSafeAreaInset: CGFloat = 0,
        preferredQualityLabelWidth: CGFloat,
        showsQualityLabel: Bool,
        followControlWidth: CGFloat = 0,
        showsQualityControl: Bool = true
    ) -> Self {
        let usable = max(
            0,
            max(0, containerWidth)
                - max(0, leadingSafeAreaInset)
                - max(0, trailingSafeAreaInset)
                - overlayHorizontalPadding * 2
        )
        let followWidth = max(0, followControlWidth)
        let pillTrailing = followWidth > 0
            ? pillTrailingPaddingWithFollow + pillFollowSpacing + followWidth
            : pillTrailingPaddingWithoutFollow
        let pillChrome = pillLeadingPadding + avatarSide + interitemSpacing + pillTrailing
        let outerSpacing = showsQualityControl ? interitemSpacing * 2 : interitemSpacing
        let fixedControls = controlSide + pillChrome
        let shared = max(0, usable - outerSpacing - fixedControls)

        guard showsQualityControl else {
            return Self(
                containerWidth: containerWidth,
                reservedWidth: usable - shared,
                sharedWidth: shared,
                qualityLabelMaxWidth: 0,
                hostBlockWidth: shared,
                showsQualityLabel: false,
                showsQualityControl: false
            )
        }

        func glyphOnly() -> Self {
            Self(
                containerWidth: containerWidth,
                reservedWidth: usable - shared,
                sharedWidth: shared,
                qualityLabelMaxWidth: 0,
                hostBlockWidth: max(0, shared - controlSide),
                showsQualityLabel: false,
                showsQualityControl: true
            )
        }

        guard showsQualityLabel else { return glyphOnly() }

        let wanted = max(0, preferredQualityLabelWidth)
        let affordable = max(0, shared - qualityChipChrome - minimumHostWidth)
        let granted = min(wanted, affordable)

        guard shared - qualityChipChrome >= minimumHostWidth,
              granted >= minimumUsefulQualityLabelWidth
        else { return glyphOnly() }

        return Self(
            containerWidth: containerWidth,
            reservedWidth: usable - shared,
            sharedWidth: shared,
            qualityLabelMaxWidth: granted,
            hostBlockWidth: max(0, shared - qualityChipChrome - granted),
            showsQualityLabel: true,
            showsQualityControl: true
        )
    }

    var allocationFitsSharedWidth: Bool {
        let quality: CGFloat = if !showsQualityControl {
            0
        } else if showsQualityLabel {
            Self.qualityChipChrome + qualityLabelMaxWidth
        } else {
            Self.controlSide
        }
        return hostBlockWidth + quality <= sharedWidth + 0.5
    }

    var containerFitsFixedControls: Bool { sharedWidth > 0 }

    var diagnosticText: String {
        "container=\(Int(containerWidth)) reserved=\(Int(reservedWidth)) "
            + "host=\(Int(hostBlockWidth)) qualityLabel=\(Int(qualityLabelMaxWidth)) "
            + "shared=\(Int(sharedWidth)) labelled=\(showsQualityLabel ? 1 : 0) "
            + "fits=\(allocationFitsSharedWidth ? 1 : 0)/\(containerFitsFixedControls ? 1 : 0)"
    }
}

enum LiveChromeLabelWidth {
    static let pointsPerCharacter: CGFloat = 9.5
    static let pointsPerWideCharacter: CGFloat = 15

    static func estimate(_ text: String, textScale: CGFloat = 1) -> CGFloat {
        var width: CGFloat = 0
        for scalar in text.unicodeScalars {
            width += isWide(scalar) ? pointsPerWideCharacter : pointsPerCharacter
        }
        return width * max(0.5, textScale)
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }
}
