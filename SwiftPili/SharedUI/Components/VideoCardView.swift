import SwiftUI

struct VideoCardView: View, Equatable {
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    var durationText: String?
    let ownerName: String
    let viewCount: Int
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

    private var coverWidth: CGFloat {
        RowCardMetrics.coverWidth(columnWidth: columnWidth, isRegularWidth: sizeClass == .regular)
    }
    private var coverHeight: CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: coverWidth)
    }

    var body: some View {
        let _ = UIHitchMonitor.countBody("card")
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
        .frame(height: coverHeight)
        .videoCardSurface()
    }
}

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
