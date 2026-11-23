import SwiftUI
import UIKit

struct ExportProgressView: View {
    let save: (ExportArtifact) -> Void
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
        .background(
            AppFill.card,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
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
                guard let id = discardID else { return }
                Task {
                    do {
                        try await exports.discard(id: id)
                    } catch {
                        presentedError = error.localizedDescription
                    }
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
                    .font(.title3)
                    .foregroundStyle(stateTint(job.state))
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
                    Text(artifact.filename)
                        .appFont(.libraryRowMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: AppSpacing.s) {
                Button("Save") {
                    save(artifact)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .tint(.biliAccent)

                Button(role: .destructive) {
                    discardID = artifact.id
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("Discard exported file"))
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
        case .failed, .interrupted:
            "exclamationmark.circle.fill"
        case .finalized, .readyToSave, .saved:
            "checkmark.circle.fill"
        default:
            "square.and.arrow.up.circle.fill"
        }
    }

    private func stateTint(_ state: ExportJobState) -> Color {
        switch state {
        case .failed, .interrupted:
            .red
        case .cancelled:
            .secondary
        case .finalized, .readyToSave, .saved:
            .green
        default:
            .biliAccent
        }
    }

    private func stateLabel(_ state: ExportJobState) -> String {
        switch state {
        case .preparing: String(localized: "Preparing export")
        case .awaitingExecution: String(localized: "Waiting to start")
        case .exporting: String(localized: "Exporting")
        case .stopping: String(localized: "Stopping export")
        case .finalized, .readyToSave: String(localized: "Ready to save")
        case .saving: String(localized: "Saving")
        case .saved: String(localized: "Saved")
        case .cancelled: String(localized: "Export cancelled")
        case .failed: String(localized: "Export failed")
        case .interrupted: String(localized: "Export interrupted")
        }
    }
}
