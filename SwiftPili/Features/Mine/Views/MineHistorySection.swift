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

    private func historyRow(_ item: HistoryResult.HistoryItem) -> some View {
        HStack(spacing: 10) {
            VideoCoverImage(sources: VideoCoverSources(widescreen: item.cover), width: 80)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
                .overlay(alignment: .bottomTrailing) {
                    if item.duration > 0 {
                        let pct = FormatUtils.historyProgressFraction(
                            progress: item.progress,
                            duration: item.duration
                        )
                        GeometryReader { geo in
                            Rectangle()
                                .fill(.biliAccent)
                                .frame(width: geo.size.width * pct, height: 2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
                    }
                }
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
