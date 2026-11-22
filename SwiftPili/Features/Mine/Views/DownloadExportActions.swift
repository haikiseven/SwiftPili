import SwiftUI

// Presentation callbacks resolve the current row before destructive mutations.
extension DownloadsView {
    func completedRow(_ item: DownloadedVideo, in shown: [DownloadedVideo]) -> some View {
        HStack(spacing: 0) {
            ZoomSourceButton(
                id: item.id,
                open: { zoom in open(item, in: shown, zoom: zoom) },
                label: { downloadRow(item) }
            )
            Menu { completedActions(item, in: shown) } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Download actions")
        }
    }

    func presentExport(_ item: DownloadedVideo) {
        guard pendingExportRequestID == nil, exportRequest == nil else { return }
        let snapshot = item.fileSnapshot
        let title = item.title
        let navigationRevision = exportNavigationRevision
        let requestID = UUID()
        pendingExportRequestID = requestID
        exportPreparation = Task {
            defer {
                if pendingExportRequestID == requestID {
                    pendingExportRequestID = nil
                    exportPreparation = nil
                }
            }
            do {
                let source = try await exports.source(snapshot: snapshot, title: title)
                guard !Task.isCancelled, pendingExportRequestID == requestID, isDownloadsVisible,
                      exportNavigationRevision == navigationRevision,
                      downloads.first(where: { $0.id == snapshot.id })?.fileSnapshot == snapshot else { return }
                exportRequest = ExportPresentation(source: source)
            } catch {
                guard !Task.isCancelled, pendingExportRequestID == requestID, isDownloadsVisible,
                      exportNavigationRevision == navigationRevision,
                      downloads.first(where: { $0.id == snapshot.id })?.fileSnapshot == snapshot else { return }
                exportError = error.localizedDescription
            }
        }
    }

    func presentSave(_ artifact: ExportArtifact) {
        guard saveRequest == nil, pendingSaveID == nil else { return }
        let navigationRevision = exportNavigationRevision
        pendingSaveID = artifact.id
        Task {
            do {
                let url = try await exports.prepareSave(id: artifact.id)
                guard pendingSaveID == artifact.id, isDownloadsVisible,
                      exportNavigationRevision == navigationRevision else {
                    try await exports.finishSave(id: artifact.id, destination: nil)
                    if pendingSaveID == artifact.id { pendingSaveID = nil }
                    return
                }
                saveRequest = ExportSavePresentation(id: artifact.id, fileURL: url)
            } catch {
                if pendingSaveID == artifact.id { pendingSaveID = nil }
                if isDownloadsVisible, exportNavigationRevision == navigationRevision {
                    exportError = error.localizedDescription
                }
            }
        }
    }

    func finishExportSave(id: UUID, destination: URL?) {
        let navigationRevision = exportNavigationRevision
        Task {
            do { try await exports.finishSave(id: id, destination: destination) } catch {
                if isDownloadsVisible, exportNavigationRevision == navigationRevision {
                    exportError = error.localizedDescription
                }
            }
        }
    }

    func settleCancelledSave() {
        guard let id = pendingSaveID else { return }
        finishExportSave(id: id, destination: nil)
        pendingSaveID = nil
        saveRequest = nil
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

    /// Completed actions are shared by visible and contextual menus in both layouts. The list ALSO keeps
    /// Delete as a swipe — a context menu is a long press, and losing the swipe
    /// on iPhone to gain a grid on iPad would be trading one screen's feature
    /// for another's.
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
