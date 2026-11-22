import SwiftUI

enum VideoCardMetrics {
    static let cornerRadius: CGFloat = AppRadius.card
}

extension View {
    func videoCardSurface() -> some View {
        videoCardInteractionShape()
    }

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
    func videoCardInteractionShape() -> some View {
        let shape = RoundedRectangle(cornerRadius: VideoCardMetrics.cornerRadius, style: .continuous)
        return contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
    }
}

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

struct HomeHeroVideoCard: View {
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    let ownerName: String
    let viewCount: Int
    var badgeText: LocalizedStringKey = "Recommend"
    var rank: Int?
    var containerWidth: CGFloat?
    var featuredRowLayout: FeaturedRowLayout?

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
