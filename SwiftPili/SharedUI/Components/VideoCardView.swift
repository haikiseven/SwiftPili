import SwiftUI

struct VideoCardView: View, Equatable {
    let title: String
    /// Both official covers the endpoint gave us; which one is drawn, and the
    /// box it is drawn in, are `CoverPresentation`'s decision, not this card's.
    let sources: VideoCoverSources
    let duration: Int
    /// Pre-formatted length ("12:34") for APIs that don't give seconds —
    /// wins over `duration` when set.
    var durationText: String?
    let ownerName: String
    let viewCount: Int
    /// Unix publish timestamp; shown as relative time after the play count.
    var publishedAt: Int?
    var explicitColumnWidth: CGFloat?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    private var columnWidth: CGFloat? {
        explicitColumnWidth ?? envColumnWidth
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.sources == rhs.sources
            && lhs.duration == rhs.duration
            && lhs.durationText == rhs.durationText
            && lhs.ownerName == rhs.ownerName
            && lhs.viewCount == rhs.viewCount
            && lhs.publishedAt == rhs.publishedAt
            && lhs.explicitColumnWidth == rhs.explicitColumnWidth
    }

    /// The WIDTH is this card's own layout decision (a size-class constant);
    /// the height is not. It is derived from the configured Cover Aspect so a
    /// 4:3 choice makes the row taller instead of squeezing 4:3 artwork into a
    /// 16:9 box — keeping the frame and swapping only the bitmap is the bug
    /// this indirection exists to prevent.
    ///
    /// The SETTING, not a per-item resolution against `sources`. A build took
    /// this box from `resolved(for: sources)` so the row would follow a fallback
    /// asset's own official class; that is reverted, and it has to stay reverted
    /// here as well as in the policy — a chrome box derived from the sources is
    /// the same aspect heuristic growing back through the layout instead of
    /// through `CoverPresentation`. `VideoCoverImage` frames its artwork from
    /// this same setting, so the two agree by construction.
    private var coverWidth: CGFloat {
        RowCardMetrics.coverWidth(columnWidth: columnWidth, isRegularWidth: sizeClass == .regular)
    }
    private var coverHeight: CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: coverWidth)
    }

    var body: some View {
        let _ = UIHitchMonitor.countBody("card")
        // The spacing the cover/text invariant is stated in terms of, taken
        // from the policy rather than written here as well:
        // `RowCardMetrics.textWidth` subtracts exactly this gap, and widening
        // it would desync that invariant from the rendered row.
        HStack(spacing: RowGeometry.coverToTextSpacing) {
            VideoCoverImage(sources: sources, width: coverWidth)
                .videoCoverFrame(cornerRadius: VideoCardMetrics.cornerRadius)
                .overlay(alignment: .bottomTrailing) {
                    if durationText != nil || duration > 0 {
                        Text(durationText ?? FormatUtils.duration(duration))
                            .appFont(.overlayBadge, monospacedDigit: true)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                .black.opacity(0.68),
                                in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                            )
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .appFont(.rowTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                // One line: "owner  views", matching every other video card.
                // When there is no owner to show (a person's own space, where
                // it would just repeat the page), the publish time takes its
                // place alongside the play count instead of a second line.
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
                    if ownerName.isEmpty, let publishedAt {
                        Text(FormatUtils.timeAgo(from: publishedAt))
                            .lineLimit(1)
                    }
                }
                .appFont(.rowMeta)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)

            Spacer(minLength: 0)
        }
        // Follows the DERIVED cover height: a row frame that stayed at the
        // 16:9 number would clip the taller cover it is supposed to contain.
        .frame(height: coverHeight)
        .videoCardSurface()
    }
}

/// A source belongs to this rendered card occurrence, not merely to a video.
/// Reusing a row for another video creates a fresh source without changing a
/// destination's identity or playback lifetime.
struct VideoNavigationButton<Label: View>: View {
    let target: VideoRouteTarget?
    var isCurrent: () -> Bool = { true }
    var anchorMode: ZoomSourceBindingMode = .childAnchor
    @ViewBuilder var label: () -> Label
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ZoomSourceButton(
            id: target?.videoID,
            isEnabled: target != nil,
            anchorMode: anchorMode,
            isCurrent: isCurrent,
            open: { zoom in
                guard let target else { return }
                coordinator.navigateToVideo(zoom.id.map(target.opening(from:)) ?? target)
            },
            label: label
        )
    }
}

extension View {
    func videoZoomDestination(sourceID: UUID?) -> some View {
        zoomDestination(RouteZoomSource(id: sourceID))
    }
}
