import SwiftUI
import UIKit

// MARK: - Floating Playlist Capsule (VideoDetail Bottom Overlay)

struct VideoDetailFloatingPlaylistCapsule: View {
    let queue: PlaybackQueueContext
    let isPlaying: Bool
    let onTap: () -> Void

    private var playlistName: String {
        queue.playlistName ?? String(localized: "Playlist")
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "waveform" : "list.bullet")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .accessibilityHidden(true)

                Text(playlistName)
                    .appFont(.controlLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if queue.playlistOrderMode != .sequential {
                    Image(systemName: queue.playlistOrderMode.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                Text("\(queue.displayIndex)/\(queue.totalCount)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .appGlass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("videoDetail.playlistCapsule")
        .accessibilityLabel(
            Text(String(format: String(localized: "Playing: %@"), playlistName))
        )
        .accessibilityValue(Text("\(queue.displayIndex)/\(queue.totalCount)"))
        .accessibilityHint(Text("Open playlist"))
    }
}

// MARK: - Half-Screen Playlist Drawer Sheet

struct PlayerPlaylistDrawerSheet: View {
    let player: PlayerViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive

    private var queue: PlaybackQueueContext? {
        player.activePlaylistQueue
    }

    private var navigationTitleText: String {
        if let queue {
            let name = queue.playlistName ?? String(localized: "Playlist")
            return "\(name) (\(queue.displayIndex)/\(queue.totalCount))"
        }
        return String(localized: "Playlist")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let queue {
                    playlistContent(queue: queue)
                } else {
                    ContentUnavailableView(
                        "Playlist Ended",
                        systemImage: "list.bullet.rectangle"
                    )
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if queue != nil {
                        Button("Exit Playlist", role: .destructive) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            player.exitPlaylistMode()
                            dismiss()
                        }
                        .accessibilityIdentifier("playlistDrawer.exit")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let queue {
                        Menu {
                            Picker(
                                "Playback Order",
                                selection: Binding(
                                    get: { queue.playlistOrderMode },
                                    set: { mode in
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        player.setPlaylistOrderMode(mode)
                                    }
                                )
                            ) {
                                ForEach(PlaylistOrderMode.allCases) { mode in
                                    Label(mode.label, systemImage: mode.systemImage)
                                        .tag(mode)
                                        .accessibilityIdentifier("playlistDrawer.mode.\(mode.rawValue)")
                                }
                            }
                            .pickerStyle(.inline)

                            Divider()

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.snappy(duration: 0.22)) {
                                    editMode = editMode == .active ? .inactive : .active
                                }
                            } label: {
                                Label(
                                    editMode == .active
                                        ? String(localized: "Done Reordering")
                                        : String(localized: "Reorder"),
                                    systemImage: "arrow.up.arrow.down"
                                )
                            }
                            .accessibilityIdentifier("playlistDrawer.reorder")
                        } label: {
                            Image(systemName: queue.playlistOrderMode.systemImage)
                        }
                        .accessibilityLabel(Text("Playback Order"))
                        .accessibilityValue(Text(queue.playlistOrderMode.label))
                    }

                    Button("Done") {
                        if editMode == .active {
                            withAnimation(.snappy(duration: 0.22)) {
                                editMode = .inactive
                            }
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .appAdaptiveSheet(compactDetents: [.medium, .large], padSizing: .form)
        .accentContentBoundary()
        .onChange(of: queue == nil) { _, isGone in
            if isGone {
                dismiss()
            }
        }
    }

    private func playlistContent(queue: PlaybackQueueContext) -> some View {
        let indexByID = Dictionary(
            uniqueKeysWithValues: queue.items.enumerated().map { ($0.element.id, $0.offset) }
        )
        let activeID = queue.currentItem?.id

        return ScrollViewReader { proxy in
            List {
                ForEach(queue.items) { item in
                    let rowIndex = indexByID[item.id] ?? 0
                    let isActive = item.id == activeID
                    playlistRow(
                        item: item,
                        index: rowIndex,
                        isActive: isActive
                    )
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    .listRowBackground(
                        isActive ? Color.biliAccent.opacity(0.10) : nil
                    )
                }
                .onMove { source, destination in
                    player.movePlaylistItems(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    let idsToRemove = offsets.compactMap { index in
                        queue.items.indices.contains(index) ? queue.items[index].id : nil
                    }
                    for id in idsToRemove {
                        player.removePlaylistItem(id: id)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .onAppear {
                if let activeID {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    private func playlistRow(
        item: PlaybackQueueItem,
        index: Int,
        isActive: Bool
    ) -> some View {
        Button {
            guard editMode != .active else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            _ = player.jumpToPlaylistItem(id: item.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                rowLeadingIndex(index: index, isActive: isActive)
                rowThumbnail(item: item)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.biliAccent : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let partBadge = item.partBadge {
                        HStack(spacing: 5) {
                            Text(partBadge)
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(isActive ? Color.biliAccent : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    isActive
                                        ? Color.biliAccent.opacity(0.15)
                                        : AppFill.inset,
                                    in: Capsule()
                                )
                            if let partTitle = item.partTitle, !partTitle.isEmpty {
                                Text(partTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    if !item.artist.isEmpty {
                        Text(item.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func rowLeadingIndex(index: Int, isActive: Bool) -> some View {
        Group {
            if isActive {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.biliAccent)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            } else {
                Text("\(index + 1)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, alignment: .center)
        .accessibilityHidden(true)
    }

    private func rowThumbnail(item: PlaybackQueueItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let coverURL = item.coverURL, !coverURL.isEmpty {
                CoverImage(
                    urlString: coverURL,
                    displaySize: CGSize(width: 88, height: 50),
                    contentMode: .fill
                )
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
                    .fill(AppFill.inset)
                    .frame(width: 88, height: 50)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
            }

            if let duration = item.duration, duration > 0 {
                Text(FormatUtils.duration(Int(duration)))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .frame(width: 88, height: 50)
    }
}
