import SwiftUI
import UIKit

struct ExportErrorCopyView: View {
    let message: String
    @State private var copiedMessage: String?

    private var isCopied: Bool { copiedMessage == message }

    var body: some View {
        Button {
            UIPasteboard.general.string = message
            copiedMessage = message
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: message)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Label {
                    isCopied ? Text("Copied") : Text("Copy")
                } icon: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
            }
            .appFont(.libraryRowMeta)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: message) { _, _ in copiedMessage = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCopied ? Text("Copied") : Text("Copy"))
        .accessibilityValue(Text(verbatim: message))
    }
}

struct ExportProgressView: View {
    let save: (ExportArtifact) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var discardID: UUID?
    @State private var error: String?
    private let exports = DownloadExportCoordinator.shared

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
            if let error {
                ExportErrorCopyView(message: error)
            }
        }
        .padding(AppSpacing.l)
        .background(
            AppFill.card,
            in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        )
        .confirmationDialog("Discard exported file?", isPresented: Binding(
            get: { discardID != nil }, set: { if !$0 { discardID = nil } }
        )) {
            Button("Discard", role: .destructive) {
                guard let id = discardID else { return }
                Task {
                    do { try await exports.discard(id: id) } catch { self.error = error.localizedDescription }
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
            HStack(alignment: .top, spacing: AppSpacing.m) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.biliAccent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
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
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if exports.hasActiveOperation {
                    Button {
                        exports.cancel()
                    } label: {
                        Text("Cancel")
                            .appFont(.controlLabel)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, AppSpacing.m)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(AppFill.inset, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.appControl)
                    .disabled(job.state == .stopping)
                }
            }

            if let validProgress {
                ProgressView(value: validProgress)
                    .tint(.biliAccent)
            } else if exports.hasActiveOperation {
                ProgressView()
                    .tint(.biliAccent)
            }

            if let jobError = job.error {
                ExportErrorCopyView(message: jobError)
            }
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
                Button {
                    save(artifact)
                } label: {
                    Text("Save")
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpacing.l)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(AccentStore.shared.badgeFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.appControl)

                Button(role: .destructive) {
                    discardID = artifact.id
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .background(AppFill.inset, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.appControl)
                .accessibilityLabel("Discard exported file")
            }
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
