import SwiftUI

/// History refresh invalidates only the compact history section.
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
            // 80pt wide, and the height is the configured Cover Aspect's — the
            // progress bar below stays attached to this view so it tracks the
            // derived box instead of restating a 16:9 number.
            //
            // Case B: `x/web-interface/history/cursor` composes no mobile
            // variant, so the widescreen asset is the fallback by API limitation.
            // Calling it OFFICIAL widescreen is licensed by `UserAPI.getHistory`
            // asking for `type=archive` — an unfiltered history is heterogeneous
            // (live artwork, column images) and this label would then be a false
            // claim of an authored match. See the note on `getHistory`.
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
