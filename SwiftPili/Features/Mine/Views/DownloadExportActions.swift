import SwiftUI

extension DownloadsView {
    func completedRow(
        _ item: DownloadedVideo,
        in shown: [DownloadedVideo],
        columnWidth: CGFloat?
    ) -> some View {
        ZoomSourceButton(
            id: item.id,
            cornerRadius: AppRadius.card,
            open: { zoom in open(item, in: shown, zoom: zoom) },
            label: {
                completedRowCard(item, columnWidth: columnWidth)
            }
        )
        .overlay(alignment: .topTrailing) {
            rowMenuButton {
                completedActions(item, in: shown)
            }
        }
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
        .contextMenu {
            completedActions(item, in: shown)
        }
    }

    private func completedRowCard(
        _ item: DownloadedVideo,
        columnWidth: CGFloat?
    ) -> some View {
        let width = coverWidth(columnWidth: columnWidth)
        let height = coverHeight(for: width)
        return HStack(alignment: .top, spacing: RowGeometry.coverToTextSpacing) {
            downloadRowCover(
                coverURL: item.coverURL,
                width: width,
                height: height,
                durationSeconds: item.durationSeconds,
                watchedFraction: item.watchedFraction
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .appFont(.libraryRowTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, Self.trailingMenuTitleInset)

                Spacer(minLength: 2)

                if !item.ownerName.isEmpty {
                    Text(item.ownerName)
                        .appFont(.libraryRowMeta)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                completedMetadataFooter(item)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        }
        .padding(AppSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .videoCardSurface()
    }

    private func completedMetadataFooter(_ item: DownloadedVideo) -> some View {
        let isBroken = brokenIDs.contains(item.id)
        let primaryMeta = HStack(spacing: 6) {
            qualityBadge(item.qualityLabel)
                .fixedSize()
            Text(byteString(item.fileSizeBytes))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        let missingTag = HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text("Missing files")
        }
        .foregroundStyle(.red)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)

        return Group {
            if isBroken {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        primaryMeta
                        missingTag
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        primaryMeta
                        missingTag
                    }
                }
            } else {
                primaryMeta
            }
        }
        .appFont(.libraryRowMeta)
        .foregroundStyle(.secondary)
    }

    func seriesGroupRow(
        _ group: DownloadSeriesGroup,
        columnWidth: CGFloat?
    ) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        let shape = RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedGroupIDs.remove(group.id)
                    } else {
                        expandedGroupIDs.insert(group.id)
                    }
                }
            } label: {
                seriesGroupHeaderCard(group, isExpanded: isExpanded, columnWidth: columnWidth)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                rowMenuButton {
                    seriesGroupActions(group, isExpanded: isExpanded)
                }
            }
            .contextMenu {
                seriesGroupActions(group, isExpanded: isExpanded)
            }

            if isExpanded {
                Divider()
                    .padding(.horizontal, AppSpacing.m)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.episodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 {
                            Divider()
                                .padding(.leading, AppSpacing.m)
                        }
                        seriesEpisodeRow(episode, in: group)
                    }
                }
                .padding(.vertical, AppSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardSurface(in: shape)
        .contentShape(.contextMenuPreview, shape)
    }

    private func seriesGroupHeaderCard(
        _ group: DownloadSeriesGroup,
        isExpanded: Bool,
        columnWidth: CGFloat?
    ) -> some View {
        let width = coverWidth(columnWidth: columnWidth)
        let height = coverHeight(for: width)
        let episodeCountText = String(format: String(localized: "%d episodes"), group.episodes.count)
        let metaText: String = if let subtitle = group.subtitle, !subtitle.isEmpty {
            "\(subtitle) - \(episodeCountText)"
        } else {
            episodeCountText
        }

        return HStack(alignment: .top, spacing: RowGeometry.coverToTextSpacing) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
                    .fill(AppFill.inset)
                    .frame(width: max(0, width - 12), height: height)
                    .offset(x: 6, y: -4)

                downloadRowCover(
                    coverURL: group.coverURL,
                    width: width,
                    height: height
                )

                HStack(spacing: 3) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(verbatim: "\(group.episodes.count)")
                        .appFont(.overlayBadge, monospacedDigit: true)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    .black.opacity(0.74),
                    in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                )
                .padding(5)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(group.title)
                    .appFont(.libraryRowTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, Self.trailingMenuTitleInset)

                Spacer(minLength: 2)

                Text(metaText)
                    .appFont(.libraryRowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(byteString(group.totalBytes))
                        .monospacedDigit()
                        .lineLimit(1)
                    if group.brokenCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                            Text(verbatim: "\(group.brokenCount)")
                                .monospacedDigit()
                        }
                        .foregroundStyle(.red)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .appFont(.libraryRowMeta)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: height + 4, alignment: .leading)
        }
        .padding(AppSpacing.m)
        .contentShape(Rectangle())
    }

    private func seriesEpisodeRow(
        _ episode: DownloadedVideo,
        in group: DownloadSeriesGroup
    ) -> some View {
        let isBroken = brokenIDs.contains(episode.id)
        let shortTitle = Self.episodeShortTitle(for: episode, in: group)
        return HStack(alignment: .center, spacing: AppSpacing.s) {
            Button {
                open(episode, in: group.episodes)
            } label: {
                HStack(alignment: .top, spacing: AppSpacing.s) {
                    Image(systemName: isBroken ? "exclamationmark.triangle.fill" : "play.circle.fill")
                        .font(.callout)
                        .foregroundStyle(isBroken ? Color.red : Color.biliAccent)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortTitle)
                            .appFont(.libraryRowMeta)
                            .fontWeight(.medium)
                            .foregroundStyle(isBroken ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            qualityBadge(episode.qualityLabel)
                                .fixedSize()
                            if episode.durationSeconds > 0 {
                                Text(FormatUtils.duration(episode.durationSeconds))
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            Text(byteString(episode.fileSizeBytes))
                                .monospacedDigit()
                                .lineLimit(1)
                            if isBroken {
                                Text("Missing files")
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                        .appFont(.libraryRowFooter)
                        .foregroundStyle(.secondary)

                        if let fraction = episode.watchedFraction {
                            ProgressView(value: min(max(fraction, 0), 1))
                                .tint(.biliAccent)
                                .frame(maxWidth: 140)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, AppSpacing.s)
                .padding(.leading, AppSpacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                completedActions(episode, in: group.episodes)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, AppSpacing.xs)
            .accessibilityLabel(Text("Download actions"))
        }
        .contextMenu {
            completedActions(episode, in: group.episodes)
        }
    }

    @ViewBuilder
    private func seriesGroupActions(_ group: DownloadSeriesGroup, isExpanded: Bool) -> some View {
        let playable = group.episodes.filter { !brokenIDs.contains($0.id) }
        if let first = playable.first {
            Button {
                open(first, in: playable)
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
        }
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedGroupIDs.remove(group.id)
                } else {
                    expandedGroupIDs.insert(group.id)
                }
            }
        } label: {
            Label(
                isExpanded ? LocalizedStringKey("Collapse") : LocalizedStringKey("Expand"),
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
        }
        Button(role: .destructive) {
            pendingGroupDelete = group
        } label: {
            Label("Delete All", systemImage: "trash")
        }
    }

    func presentExport(_ item: DownloadedVideo) {
        guard exportRequest == nil else { return }
        do {
            let source = try exports.source(snapshot: item.fileSnapshot, title: item.title)
            exportRequest = ExportPresentation(source: source)
        } catch {
            if error as? ExportFailure == .sourceUnavailable {
                brokenIDs.insert(item.id)
            }
            exportError = error.localizedDescription
        }
    }

    func presentSaveToFiles(_ artifact: ExportArtifact) {
        guard saveRequest == nil, exports.savingArtifactID == nil else { return }
        guard FileManager.default.fileExists(atPath: artifact.fileURL.path) else {
            exports.discard(id: artifact.id)
            exportError = ExportFailure.invalidOutput.errorDescription
            return
        }
        saveRequest = ExportSavePresentation(id: artifact.id, fileURL: artifact.fileURL)
    }

    func requestMutation(_ item: DownloadedVideo, redownload: Bool) {
        if exports.sourceIsLocked(downloadID: item.id) {
            mutationRequest = ExportMutationPresentation(
                downloadID: item.id, folderName: item.folderName, addedAt: item.addedAt, redownload: redownload
            )
        } else if redownload { performRedownload(item) } else { manager.delete(item) }
    }

    func settleMutation() {
        guard let request = mutationRequest else { return }
        mutationRequest = nil
        Task {
            await exports.cancelAndWaitForSource(downloadID: request.downloadID)
            guard let item = downloads.first(where: { $0.id == request.downloadID }),
                  item.folderName == request.folderName, item.addedAt == request.addedAt else { return }
            requestMutation(item, redownload: request.redownload)
        }
    }

    @ViewBuilder
    func completedActions(_ item: DownloadedVideo, in shown: [DownloadedVideo]) -> some View {
        Button { open(item, in: shown) } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button { presentExport(item) } label: {
            Label("Export video", systemImage: "square.and.arrow.up")
        }
        .disabled(exports.hasActiveOperation || brokenIDs.contains(item.id))
        Button {
            redownload(item)
        } label: {
            Label("Re-download", systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            requestMutation(item, redownload: false)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    func redownload(_ item: DownloadedVideo) {
        requestMutation(item, redownload: true)
    }

    func performRedownload(_ item: DownloadedVideo) {
        let (aid, cid, bvid, title, cover, owner, duration, quality) = (
            item.aid, item.cid, item.bvid, item.title, item.coverURL,
            item.ownerName, item.durationSeconds, item.qualityCode
        )
        guard manager.delete(item) else { return }
        Task {
            await manager.startDownload(
                aid: aid, cid: cid, bvid: bvid, title: title, coverURL: cover,
                ownerName: owner, durationSeconds: duration, quality: quality
            )
        }
    }
}
