import CoreGraphics

/// Width budget for the portrait-live host card.
///
/// **The overflow this exists to prevent.** Every control in that row is either
/// fixed (a 44pt tap target, a 32pt avatar) or bounded (the quality chip's
/// label). Exactly ONE element is flexible: the host name/title block. It
/// carried `.frame(maxWidth: .infinity)` *and* `.layoutPriority(1)` — the
/// highest priority in the row — so SwiftUI offered it the whole remaining
/// width first and it took all of it. The lower-priority siblings were then
/// offered nothing, and neither of them can compress to nothing: the quality
/// chip has 22pt of horizontal padding plus a chevron, and the options button is
/// a hard 44pt. The row's content therefore exceeded the container and the
/// trailing controls were pushed past the visible edge.
///
/// The rule this encodes: **the flexible element receives the remainder, never
/// the whole width.** Fixed controls are reserved first, the quality label is
/// bounded by what is left, and the host block absorbs whatever remains above a
/// readable floor. That ordering is what makes the layout fit by construction
/// instead of by clipping.
struct LivePortraitHeaderBudget: Equatable, Sendable {
    /// Standard tap target — back button and glyph-only quality.
    static let controlSide: CGFloat = 44
    static let avatarSide: CGFloat = 30
    static let interitemSpacing: CGFloat = 8
    /// Internal padding + avatar-to-text gap inside the broadcaster glass pill.
    static let pillLeadingPadding: CGFloat = 6
    static let pillTrailingPaddingWithoutFollow: CGFloat = 12
    static let pillTrailingPaddingWithFollow: CGFloat = 6
    static let pillFollowSpacing: CGFloat = 6
    /// Between the bar and the screen edge.
    static let overlayHorizontalPadding: CGFloat = 12
    /// Inflexible chrome inside the labelled quality chip: 11pt padding each
    /// side, the chevron glyph, and the gap before it. The label itself is the
    /// only part that can give.
    static let qualityChipChrome: CGFloat = 11 * 2 + 12 + 4
    /// Below this the host name is not readable, so the quality label yields
    /// its width first and then the chip drops to glyph-only.
    static let minimumHostWidth: CGFloat = 72
    /// A label narrower than this shows an ellipsis and nothing else, so the
    /// chip's 38pt of chrome buys a control that says less than the glyph does.
    /// Below it, glyph-only is the better answer — and this is what makes the
    /// fallback reachable rather than theoretical.
    static let minimumUsefulQualityLabelWidth: CGFloat = 30

    let containerWidth: CGFloat
    /// Width taken by fixed controls, spacing and padding.
    let reservedWidth: CGFloat
    /// What the host block and the quality control have to share.
    let sharedWidth: CGFloat
    /// Ceiling for the quality label's text. 0 when the chip is glyph-only.
    let qualityLabelMaxWidth: CGFloat
    /// What the flexible host block can actually use.
    let hostBlockWidth: CGFloat
    /// May be false even when the caller asked for a label: a container too
    /// narrow to seat both a readable host name and a label falls back to the
    /// glyph, rather than overflowing.
    let showsQualityLabel: Bool
    /// Whether the quality control is mounted alongside the host pill.
    let showsQualityControl: Bool

    /// `preferredQualityLabelWidth` is what the label would like — an estimate
    /// from the string and the current text scale. It is a request, not a claim.
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
        // What host + quality must share.
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
        // Serve the chip's request only out of what is left above the host
        // floor. This subtraction — not a priority — is what guarantees the row
        // fits: the label can never take width the host block needs.
        let affordable = max(0, shared - qualityChipChrome - minimumHostWidth)
        let granted = min(wanted, affordable)

        // Even a zero-width label still costs the chip's chrome. If that alone
        // does not leave a readable host block — or if what the label can be
        // granted is too narrow to say anything — the labelled chip does not
        // belong here and the glyph is the honest answer.
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

    /// The invariant, as a value the caller (and the tests) can check: the two
    /// elements that share the flexible space never ask for more than it holds.
    ///
    /// Stated over `sharedWidth`, not `containerWidth`, on purpose. A container
    /// narrower than its own fixed controls cannot fit anything, and reporting
    /// that as a budget violation would confuse a real overflow with a
    /// physically impossible width — `containerFitsFixedControls` answers that
    /// separately.
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

    /// False only for a container too narrow to seat the fixed controls at all
    /// — no supported device width, but a value the diagnostics can name rather
    /// than silently producing a squeezed row.
    var containerFitsFixedControls: Bool { sharedWidth > 0 }

    /// One line of geometry for a device capture, so an overflow report can be
    /// read against the numbers that produced it.
    var diagnosticText: String {
        "container=\(Int(containerWidth)) reserved=\(Int(reservedWidth)) "
            + "host=\(Int(hostBlockWidth)) qualityLabel=\(Int(qualityLabelMaxWidth)) "
            + "shared=\(Int(sharedWidth)) labelled=\(showsQualityLabel ? 1 : 0) "
            + "fits=\(allocationFitsSharedWidth ? 1 : 0)/\(containerFitsFixedControls ? 1 : 0)"
    }
}

/// Estimates the width a short chrome label wants, without measuring it.
///
/// A real text measurement needs a layout pass, and this value is an *input* to
/// the layout — so it has to be derived, not measured. It is deliberately an
/// over-estimate per character: granting slightly too much only shifts width
/// from the host block, which has a floor, whereas under-estimating would let
/// the label exceed its ceiling and reintroduce the overflow.
enum LiveChromeLabelWidth {
    /// Generous per-character advance for a semibold footnote.
    static let pointsPerCharacter: CGFloat = 9.5
    /// CJK renditions ("原画", "蓝光") are full-width.
    static let pointsPerWideCharacter: CGFloat = 15

    static func estimate(_ text: String, textScale: CGFloat = 1) -> CGFloat {
        var width: CGFloat = 0
        for scalar in text.unicodeScalars {
            width += isWide(scalar) ? pointsPerWideCharacter : pointsPerCharacter
        }
        return width * max(0.5, textScale)
    }

    /// CJK, fullwidth forms and Hangul occupy roughly two Latin advances.
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
