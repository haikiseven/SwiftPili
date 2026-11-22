import SwiftUI

struct GridVideoCardView: View, Equatable {
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    var durationText: String?
    let ownerName: String
    let viewCount: Int
    var publishedAt: Int?
    var explicitColumnWidth: CGFloat?

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VideoCoverImage(sources: sources, columnWidth: columnWidth)
                .videoCoverFrame(cornerRadius: VideoCardMetrics.cornerRadius)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                            Text(FormatUtils.viewCount(viewCount))
                                .appFont(.overlayBadge, monospacedDigit: true)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let durationText, !durationText.isEmpty {
                            Text(durationText)
                                .appFont(.overlayBadge, monospacedDigit: true)
                                .fontWeight(.medium)
                        } else if duration > 0 {
                            Text(FormatUtils.duration(duration))
                                .appFont(.overlayBadge, monospacedDigit: true)
                                .fontWeight(.medium)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .appFont(.cardTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if !ownerName.isEmpty {
                    Text(ownerName)
                        .appFont(.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let publishedAt, publishedAt > 0 {
                    Text(FormatUtils.timeAgo(from: publishedAt))
                        .appFont(.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 6)
        }
        .videoCardSurface()
    }
}
