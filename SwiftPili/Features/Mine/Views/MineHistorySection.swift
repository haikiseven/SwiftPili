import SwiftUI

struct MineHistorySection: View {
    let viewModel: MineViewModel

    var body: some View {
        Section {
            if viewModel.history.isEmpty {
                Text("No watch history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.history.prefix(3)) { item in
                    VideoNavigationButton(target: VideoRouteTarget.make(
                        bvid: nil, aid: item.kid, title: item.title, coverURL: item.cover,
                        ownerName: item.authorName, durationSeconds: item.duration
                    )) {
                        historyRow(item)
                            .contentShape(Rectangle())
                    }
                }
            }
        } header: {
            Text("Recent History")
        }
        .listRowBackground(AppFill.card)
    }

    private static let coverWidth: CGFloat = 80

    private func historyRow(_ item: HistoryResult.HistoryItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
        return HStack(spacing: 10) {
            VideoCoverImage(sources: VideoCoverSources(widescreen: item.cover), width: Self.coverWidth)
                .overlay(alignment: .bottomLeading) {
                    if item.duration > 0 {
                        let pct = FormatUtils.historyProgressFraction(
                            progress: item.progress,
                            duration: item.duration
                        )
                        Rectangle()
                            .fill(.biliAccent)
                            .frame(width: Self.coverWidth * pct, height: 2)
                    }
                }
                .clipShape(shape)
                .overlay(
                    shape
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: AppStroke.hairlineWidth)
                        .allowsHitTesting(false)
                )
                .zoomSourceAnchor(cornerRadius: AppRadius.badge)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .appFont(.messageTitle)
                    .lineLimit(1)
                Text(item.authorName)
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
