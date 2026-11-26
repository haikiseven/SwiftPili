import SwiftUI

struct MineHistorySection: View {
    let viewModel: MineViewModel
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Section {
            if viewModel.history.isEmpty {
                Text("No Watch History")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.history.prefix(3)) { item in
                    VideoNavigationButton(target: VideoRouteTarget.make(
                        bvid: item.bvid, aid: item.kid, title: item.title, coverURL: item.cover,
                        ownerName: item.authorName, durationSeconds: item.duration
                    )) {
                        historyRow(item)
                            .contentShape(Rectangle())
                    }
                }
            }
        } header: {
            HStack {
                Text("Recent History")
                Spacer()
                Button {
                    coordinator.navigate(to: .history)
                } label: {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.biliAccent)
                    .textCase(nil)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(AppFill.card)
    }

    private static let coverWidth: CGFloat = 104

    private func historyRow(_ item: HistoryResult.HistoryItem) -> some View {
        let coverHeight = CoverPresentationStore.shared.presentation.height(forWidth: Self.coverWidth)
        let progressFraction: Double? = if item.duration > 0, item.progress != 0 {
            FormatUtils.historyProgressFraction(progress: item.progress, duration: item.duration)
        } else {
            nil
        }
        return HStack(alignment: .top, spacing: RowGeometry.coverToTextSpacing) {
            ZStack(alignment: .bottomTrailing) {
                VideoCoverImage(sources: VideoCoverSources(widescreen: item.cover), width: Self.coverWidth)
                    .videoCoverFrame(cornerRadius: AppRadius.thumbnail)

                if let progressFraction {
                    CoverWatchProgressBar(
                        progress: progressFraction,
                        width: Self.coverWidth,
                        height: coverHeight
                    )
                }

                if item.duration > 0 {
                    Text(FormatUtils.duration(item.duration))
                        .appFont(.overlayBadge, monospacedDigit: true)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            .black.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                        )
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .appFont(.messageTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if !item.authorName.isEmpty {
                        Text(item.authorName)
                            .lineLimit(1)
                    }
                    if !item.authorName.isEmpty, item.viewAt > 0 {
                        Spacer(minLength: 8)
                    }
                    if item.viewAt > 0 {
                        Text(FormatUtils.timeAgo(from: item.viewAt))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .appFont(.messageMeta)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: coverHeight, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
