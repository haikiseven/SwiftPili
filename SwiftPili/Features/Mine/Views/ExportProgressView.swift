import SwiftUI
import UIKit

struct ExportProgressView: View {
    let saveToFiles: (ExportArtifact) -> Void
    @AppMotion private var motion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var discardID: UUID?
    @State private var presentedError: String?
    @State private var lastAutoPresentedJobError: JobErrorToken?
    private let exports = DownloadExportCoordinator.shared

    private struct JobErrorToken: Equatable {
        let jobID: UUID
        let message: String
    }

    private var currentJobErrorToken: JobErrorToken? {
        guard let job = exports.activeJob,
              let message = surfacedJobError(for: job) else { return nil }
        return JobErrorToken(jobID: job.id, message: message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            if let job = exports.activeJob {
                activeJobRow(job)
            }
            if exports.activeJob != nil, !exports.artifacts.isEmpty {
                Divider()
            }
            ForEach(Array(exports.artifacts.enumerated()), id: \.element.id) { index, artifact in
                if index > 0 {
                    Divider()
                }
                artifactRow(artifact)
            }
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, AppSpacing.m)
        .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .animation(motion.animation(normal: .snappy(duration: 0.22)), value: exports.savingArtifactID)
        .animation(motion.animation(normal: .snappy(duration: 0.22)), value: exports.activeJob?.state)
        .onChange(of: currentJobErrorToken) { _, token in
            guard let token, token != lastAutoPresentedJobError else { return }
            lastAutoPresentedJobError = token
            presentedError = token.message
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { presentedError != nil },
                set: { if !$0 { presentedError = nil } }
            )
        ) {
            if let message = presentedError {
                Button("Copy") {
                    UIPasteboard.general.string = message
                }
            }
            Button("OK", role: .cancel) {
                presentedError = nil
            }
        } message: {
            Text(verbatim: presentedError ?? "")
        }
        .confirmationDialog("Discard exported file?", isPresented: Binding(
            get: { discardID != nil }, set: { if !$0 { discardID = nil } }
        )) {
            Button("Discard", role: .destructive) {
                if let id = discardID {
                    exports.discard(id: id)
                }
                discardID = nil
            }
        }
    }

    private func activeJobRow(_ job: ExportJobView) -> some View {
        let validProgress: Double? = if exports.hasActiveOperation, let progress = job.progress, progress.isFinite {
            min(max(progress, 0), 1)
        } else {
            nil
        }
        return VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .center, spacing: AppSpacing.m) {
                Image(systemName: stateIcon(job.state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateTint(job.state))
                    .frame(width: 36, height: 36)
                    .background(
                        stateTint(job.state).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .appFont(.libraryRowTitle)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: AppSpacing.s) {
                        Text(stateLabel(job.state))
                        Spacer(minLength: 0)
                        if let validProgress {
                            Text(downloadPercentText(validProgress))
                                .monospacedDigit()
                        }
                    }
                    .appFont(.libraryRowMeta)
                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if exports.hasActiveOperation {
                    Button("Cancel") {
                        exports.cancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .disabled(job.state == .stopping)
                } else {
                    Button {
                        exports.dismissInactiveJob()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(Text("Dismiss"))
                }
            }

            if let validProgress {
                ProgressView(value: validProgress)
                    .tint(.biliAccent)
            } else if exports.hasActiveOperation {
                ProgressView()
                    .controlSize(.small)
                    .tint(.biliAccent)
            }

            if let jobError = surfacedJobError(for: job) {
                failedStatusRow(message: jobError)
            }
        }
    }

    private func failedStatusRow(message: String) -> some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: AppSpacing.s))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .appFont(.libraryRowMeta)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Details") {
                presentedError = message
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
        }
    }

    private func artifactRow(_ artifact: ExportArtifact) -> some View {
        let isSavingThis = exports.savingArtifactID == artifact.id
        let isAnySaving = exports.savingArtifactID != nil
        let sizeText = ByteCountFormatter.string(
            fromByteCount: artifact.fileSizeBytes,
            countStyle: .file
        )
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: AppSpacing.m))
        return layout {
            HStack(alignment: .center, spacing: AppSpacing.m) {
                Image(systemName: "film.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.biliAccent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .appFont(.libraryRowTitle)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: AppSpacing.xs) {
                        Text(artifact.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: "·")
                        Text(sizeText)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .appFont(.libraryRowMeta)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: AppSpacing.s) {
                Menu {
                    Button {
                        saveToPhotos(artifact)
                    } label: {
                        Label("Save to Photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        saveToFiles(artifact)
                    } label: {
                        Label("Save to Files", systemImage: "folder")
                    }
                    Button {
                        shareArtifact(artifact)
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    if isSavingThis {
                        HStack(spacing: AppSpacing.xs) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Saving")
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Save")
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .tint(.biliAccent)
                .disabled(isAnySaving)

                Button(role: .destructive) {
                    discardID = artifact.id
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .disabled(isSavingThis)
                .accessibilityLabel(Text("Discard exported file"))
            }
        }
    }

    private func saveToPhotos(_ artifact: ExportArtifact) {
        guard exports.savingArtifactID == nil else { return }
        let id = artifact.id
        Task {
            do {
                try await exports.saveToPhotoLibrary(id: id)
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    private func shareArtifact(_ artifact: ExportArtifact) {
        guard exports.savingArtifactID == nil else { return }
        guard FileManager.default.fileExists(atPath: artifact.fileURL.path) else {
            exports.discard(id: artifact.id)
            presentedError = ExportFailure.invalidOutput.errorDescription
            return
        }
        let id = artifact.id
        let fileURL = artifact.fileURL
        let coordinator = exports
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard coordinator.savingArtifactID == nil,
                  coordinator.artifacts.contains(where: { $0.id == id }) else { return }
            ActivitySharePresenter.present(items: [fileURL]) { completed in
                guard completed else { return }
                Task { @MainActor in
                    coordinator.completeExternalSave(id: id)
                }
            }
        }
    }

    private func surfacedJobError(for job: ExportJobView) -> String? {
        guard let message = job.error, !message.isEmpty else { return nil }
        if job.state == .cancelled, message == ExportFailure.cancelled.errorDescription {
            return nil
        }
        return message
    }

    private func stateIcon(_ state: ExportJobState) -> String {
        switch state {
        case .failed:
            "exclamationmark.triangle.fill"
        case .cancelled:
            "xmark.circle.fill"
        case .preparing, .exporting, .stopping:
            "square.and.arrow.up"
        }
    }

    private func stateTint(_ state: ExportJobState) -> Color {
        switch state {
        case .failed:
            .red
        case .cancelled:
            .secondary
        case .preparing, .exporting, .stopping:
            .biliAccent
        }
    }

    private func stateLabel(_ state: ExportJobState) -> String {
        switch state {
        case .preparing: String(localized: "Preparing export")
        case .exporting: String(localized: "Exporting")
        case .stopping: String(localized: "Stopping export")
        case .cancelled: String(localized: "Export cancelled")
        case .failed: String(localized: "Export failed")
        }
    }
}
