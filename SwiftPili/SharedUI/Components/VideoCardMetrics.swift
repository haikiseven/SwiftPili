import SwiftUI

/// The corner radius shared by every feed/library card, so the cover,
/// interaction shape and zoom source clip to the same geometry.
enum VideoCardMetrics {
    static let cornerRadius: CGFloat = AppRadius.card
}

extension View {
    /// Bare everywhere now — no platter on either surface. Just the shared
    /// interaction/hover/zoom-origin shape: the cover's own rounded corners
    /// and bottom scrim are the card's only visual edge.
    func videoCardSurface() -> some View {
        videoCardInteractionShape()
    }

    /// Top-rounded cover frame for a vertical card whose caption sits flush
    /// against the cover's bottom edge, so the corner seam between the two
    /// doesn't pinch inward. Bare grid/live cards use `videoCoverFrame`
    /// (rounded on all four corners) instead; this remains for shelves that
    /// still draw a caption directly under the cover with no gap.
    func videoGridCoverFrame(cornerRadius: CGFloat = VideoCardMetrics.cornerRadius) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
        return overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 34)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .zoomSourceAnchor(cornerRadius: cornerRadius)
    }

    /// Rounded cover frame with a subtle bottom legibility scrim and hairline
    /// border for video thumbnails.
    func videoCoverFrame(cornerRadius: CGFloat = VideoCardMetrics.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 34)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay(
            shape
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .zoomSourceAnchor(cornerRadius: cornerRadius)
    }
}

private extension View {
    /// The hit and hover shape for a bare card. The zoom transition anchors on
    /// the cover (`videoCoverFrame`) rather than the outer VStack/HStack so the
    /// transition portal clips cleanly to the cover's rounded rectangle without
    /// including the unplattered text area or slicing text corners.
    func videoCardInteractionShape() -> some View {
        let shape = RoundedRectangle(cornerRadius: VideoCardMetrics.cornerRadius, style: .continuous)
        return contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
    }
}

/// Gold / Silver / Bronze / numbered rank badge for the Home Ranking feed.
struct RankingMedalBadge: View {
    let rank: Int

    private var gradientColors: [Color] {
        switch rank {
        case 1:
            [Color(red: 1.00, green: 0.84, blue: 0.25), Color(red: 0.86, green: 0.55, blue: 0.08)]
        case 2:
            [Color(red: 0.88, green: 0.91, blue: 0.96), Color(red: 0.55, green: 0.61, blue: 0.72)]
        case 3:
            [Color(red: 0.93, green: 0.66, blue: 0.44), Color(red: 0.68, green: 0.39, blue: 0.20)]
        default:
            [Color.black.opacity(0.68), Color.black.opacity(0.68)]
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if rank == 1 {
                Image(systemName: "crown.fill")
                    .font(.caption2)
            }
            Text(rank <= 3 ? "TOP \(rank)" : "#\(rank)")
                .appFont(.overlayBadge, monospacedDigit: true)
                .fontWeight(.bold)
        }
        .foregroundStyle(rank <= 2 ? Color.black.opacity(0.88) : Color.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5))
    }
}

/// Hero showcase card for the lead item of Recommend, Popular, and Ranking
/// feeds on Home. One information hierarchy — eyebrow, title, one metadata
/// line — drawn two ways: no "Recommend" pill and no circular play button
/// either way, only a small bold accent-coloured eyebrow (gold with a crown
/// for the ranking's #1).
///
/// Narrow windows (feed grid at 1–2 columns) keep the overlaid-caption style
/// below. Wide windows (>= 3 columns) switch to a full-width row in the style
/// of the Apple TV app's featured shelf: the cover docked to the trailing
/// edge with its leading ~35% fading into the page's own ambient glow, and a
/// text column overlapping that fade with the title, metadata and a "Play"
/// capsule — a visual cue only, since the whole row stays one tap target.
/// Callers that know they are in the wide layout pass the row's own measured
/// width through `featuredRowLayout`, so the card never measures itself.
struct HomeHeroVideoCard: View {
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    let ownerName: String
    let viewCount: Int
    var badgeText: LocalizedStringKey = "Recommend"
    var rank: Int?
    var containerWidth: CGFloat?
    /// `nil` keeps the overlaid style; a value switches to the wide row.
    var featuredRowLayout: FeaturedRowLayout?

    /// The row's own content width, measured and supplied by the caller
    /// (`FeedColumnPolicy`'s column count already told it this is the wide
    /// layout) — not remeasured inside the card.
    struct FeaturedRowLayout {
        let containerWidth: CGFloat
    }

    var body: some View {
        if let featuredRowLayout {
            featuredRow(layout: featuredRowLayout)
        } else {
            overlayCard
        }
    }

    /// Small, bold text — no capsule background. The ranking's lead item
    /// swaps it for a crown and gold text, matching the medal styling the rest
    /// of that feed uses. `onCover`: drawn over the artwork's scrim, where
    /// accent text loses contrast against dark frames, so it reads white there
    /// and accent only on the page backdrop (the wide row).
    @ViewBuilder
    private func eyebrowLabel(onCover: Bool) -> some View {
        if let rank {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                Text("TOP \(rank)")
                    .monospacedDigit()
            }
            .appFont(.overlayBadge)
            .fontWeight(.bold)
            .foregroundStyle(Color(red: 1.00, green: 0.84, blue: 0.25))
        } else {
            Text(badgeText)
                .appFont(.overlayBadge)
                .fontWeight(.bold)
                .foregroundStyle(onCover ? Color.white.opacity(0.9) : Color.biliAccent)
        }
    }

    @ViewBuilder
    private var durationLabel: some View {
        if duration > 0 {
            Text(FormatUtils.duration(duration))
                .appFont(.overlayBadge, monospacedDigit: true)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.68), in: Capsule())
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if !ownerName.isEmpty {
                Text(ownerName)
                    .lineLimit(1)
            }
            HStack(spacing: 3) {
                Image(systemName: "play.rectangle")
                    .imageScale(.small)
                Text(FormatUtils.viewCount(viewCount))
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
        .appFont(.cardMeta)
    }

    /// The "Play" capsule in the wide row: a visual cue, not its own tap
    /// target — the row beneath it is already one.
    private var playButton: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .font(.subheadline.weight(.bold))
            Text("Play")
                .appFont(.controlLabel)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AccentStore.shared.badgeFill, in: Capsule())
    }

    private var overlayCard: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        return VideoCoverImage(
            sources: sources,
            columnWidth: containerWidth,
            aspectOverride: .sixteenByNine
        )
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.80), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    if rank != nil {
                        eyebrowLabel(onCover: true)
                    }

                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        metaLine
                            .foregroundStyle(.white.opacity(0.86))
                        Spacer(minLength: 4)
                        if duration > 0 {
                            Text(FormatUtils.duration(duration))
                                .appFont(.overlayBadge, monospacedDigit: true)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .clipShape(shape)
            .overlay(
                shape
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
            .zoomSourceAnchor(cornerRadius: AppRadius.panel)
    }

    private func featuredRow(layout: FeaturedRowLayout) -> some View {
        let estimatedCoverWidth = max(0, layout.containerWidth * HomeHeroFeaturedRowLayout.coverFraction)
        let coverShape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)

        return HomeHeroFeaturedRowLayout {
            VStack(alignment: .leading, spacing: 10) {
                eyebrowLabel(onCover: false)

                Text(title)
                    .appFont(.editorialTitle)
                    .fontWeight(.bold)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                metaLine
                    .foregroundStyle(.secondary)

                playButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .zIndex(1)

            VideoCoverImage(
                sources: sources,
                columnWidth: estimatedCoverWidth > 1 ? estimatedCoverWidth : nil,
                aspectOverride: .sixteenByNine
            )
                .overlay(alignment: .topTrailing) {
                    durationLabel.padding(10)
                }
                .clipShape(coverShape)
                // The leading ~35% fades to clear so the cover's edge melts
                // into the page's own ambient glow instead of cutting hard
                // against it.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.35),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .zoomSourceAnchor(cornerRadius: AppRadius.panel)
        }
        .contentShape(.interaction, Rectangle())
        .contentShape(.hoverEffect, Rectangle())
        .hoverEffect(.highlight)
    }
}

/// Proposal-driven wide layout for `HomeHeroVideoCard` so expanding or
/// collapsing the iPad sidebar resizes the featured row synchronously with
/// the container proposal instead of locking the parent `VStack` at a stale
/// fixed width.
private struct HomeHeroFeaturedRowLayout: Layout {
    static let coverFraction: CGFloat = 0.62
    private static let textFraction: CGFloat = 0.42
    private static let idealFallbackWidth: CGFloat = 320

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        if let proposedWidth = proposal.width, !proposedWidth.isFinite {
            return CGSize(width: proposedWidth, height: 180)
        }
        let totalWidth = max(0, proposal.width ?? Self.idealFallbackWidth)
        guard totalWidth > 0 else { return .zero }
        let coverWidth = (totalWidth * Self.coverFraction).rounded(.down)
        let coverHeight = (coverWidth * 9 / 16).rounded(.down)
        let textWidth = (totalWidth * Self.textFraction).rounded(.down)
        let textSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: textWidth, height: nil)
        )
        return CGSize(width: totalWidth, height: max(coverHeight, textSize.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2, bounds.width > 0 else { return }
        let totalWidth = bounds.width
        let coverWidth = (totalWidth * Self.coverFraction).rounded(.down)
        let coverHeight = (coverWidth * 9 / 16).rounded(.down)
        let textWidth = (totalWidth * Self.textFraction).rounded(.down)
        let textSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: textWidth, height: nil)
        )

        subviews[1].place(
            at: CGPoint(x: bounds.maxX - coverWidth, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: coverWidth, height: coverHeight)
        )
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: textWidth, height: textSize.height)
        )
    }
}

/// Top section bar for Home: clean text tabs with an accent underline capsule,
/// matching the previous header design while using a horizontally scrollable
/// row with `.basedOnSize` bounce so narrow sidebar/Split View widths never
/// wrap or force container overflow.
struct HomeSectionPillBar: View {
    let selection: HomeSection
    let onSelect: (HomeSection) -> Void

    var body: some View {
        SectionTabBar(
            values: Array(HomeSection.allCases),
            selection: selection,
            isScrollable: true,
            label: { Text($0.title) },
            onSelect: onSelect
        )
        .accessibilityElement(children: .contain)
    }
}
