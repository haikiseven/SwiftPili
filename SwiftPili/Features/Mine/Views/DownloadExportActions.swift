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
        HStack(spacing: 6) {
            qualityBadge(item.qualityLabel)
                .fixedSize()
            Text(byteString(item.fileSizeBytes))
                .monospacedDigit()
                .lineLimit(1)
            if brokenIDs.contains(item.id) {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text("Missing files")
                }
                .foregroundStyle(.red)
                .lineLimit(1)
            }
        }
        .appFont(.libraryRowMeta)
        .foregroundStyle(.secondary)
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
