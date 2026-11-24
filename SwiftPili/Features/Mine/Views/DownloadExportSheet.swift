import SwiftUI
import UIKit

struct DownloadExportSheet: View {
    let source: DownloadExportSource
    @AppMotion private var motion
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: ExportMediaInventory?
    @State private var filename = ""
    @State private var mode: ExportMode = .original
    @State private var codec: ExportVideoCodec = .h264
    @State private var resolution: ExportResolution = .source
    @State private var color: ExportColorMode = .sdr
    @State private var includeAudio = true
    @State private var error: String?
    @State private var prepareError: String?
    @State private var loading = true
    @State private var starting = false
    private let exports = DownloadExportCoordinator.shared

    private var matchingRecipes: [ExportRecipe] {
        inventory?.recipes.filter { $0.codec == codec && $0.color == color } ?? []
    }

    private var canStart: Bool {
        guard inventory != nil, !starting, !exports.hasActiveOperation,
              !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if mode == .original { return inventory?.canRemuxOriginal == true }
        return matchingRecipes.contains { $0.resolution == resolution }
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("File name", text: $filename)
                            .autocorrectionDisabled()
                    } header: {
                        Text("File")
                    } footer: {
                        Text("MP4 · Save to Photos, Files, or Share after export finishes.")
                    }

                    if loading {
                        Section {
                            HStack(spacing: AppSpacing.s) {
                                ProgressView()
                                Text("Reading local tracks…")
                                    .appFont(.libraryRowMeta)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, AppSpacing.xs)
                        }
                    } else if let inventory {
                        sourceSection(inventory)
                        optionsSection(inventory)
                    } else if let prepareError {
                        Section {
                            HStack(spacing: AppSpacing.s) {
                                Label("Export failed", systemImage: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                Spacer(minLength: 0)
                                Button("Details") {
                                    error = prepareError
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .buttonBorderShape(.capsule)
                            }
                        }
                    }
                }
                .listRowBackground(AppFill.card)
            }
            .scrollContentBackground(.hidden)
            .appAmbientBrowseBackground()
            .animation(motion.animation(normal: .snappy(duration: 0.22)), value: loading)
            .animation(motion.animation(normal: .snappy(duration: 0.22)), value: mode)
            .navigationTitle("Export video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { start() }.disabled(!canStart)
                }
            }
            .alert(
                "Export Failed",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                )
            ) {
                if let message = error {
                    Button("Copy") {
                        UIPasteboard.general.string = message
                    }
                }
                Button("OK", role: .cancel) {
                    error = nil
                }
            } message: {
                Text(verbatim: error ?? "")
            }
        }
        .accentContentBoundary()
        .task {
            filename = source.title
            do {
                let result = try await exports.prepare(source: source)
                guard !Task.isCancelled else { return }
                inventory = result
                if !result.canRemuxOriginal { mode = .transcode }
                includeAudio = result.audioCodec != nil
                if let first = result.recipes.first {
                    codec = first.codec
                    color = first.color
                    resolution = first.resolution
                }
                if !result.canRemuxOriginal && result.recipes.isEmpty {
                    let message = String(localized: "No supported export recipe is available for these local tracks.")
                    prepareError = message
                    error = message
                }
            } catch {
                guard !Task.isCancelled else { return }
                prepareError = error.localizedDescription
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func sourceSection(_ inventory: ExportMediaInventory) -> some View {
        Section("Local source") {
            LabeledContent("Video", value: inventory.videoCodec)
            LabeledContent("Dimensions") {
                Text(verbatim: "\(inventory.width) × \(inventory.height)")
                    .monospacedDigit()
            }
            if let audio = inventory.audioCodec { LabeledContent("Audio", value: audio) }
            if let profile = inventory.dolbyVisionProfile {
                LabeledContent("Dolby Vision") {
                    Text(verbatim: "Profile \(profile)")
                        .monospacedDigit()
                }
            } else {
                LabeledContent("Color", value: inventory.hdr ? "HDR" : "SDR")
            }
        }
    }

    private func optionsSection(_ inventory: ExportMediaInventory) -> some View {
        Section {
            Picker("Mode", selection: $mode) {
                if inventory.canRemuxOriginal { Text("Original tracks").tag(ExportMode.original) }
                Text("Transcode MP4").tag(ExportMode.transcode)
            }
            if mode == .transcode {
                Picker("Codec", selection: $codec) {
                    ForEach([ExportVideoCodec.h264, .hevc], id: \.self) { value in
                        if inventory.recipes.contains(where: { $0.codec == value }) {
                            Text(value == .h264 ? "H.264" : "HEVC").tag(value)
                        }
                    }
                }
                .onChange(of: codec) { _, _ in reconcileRecipe() }
                Picker("Color", selection: $color) {
                    ForEach([ExportColorMode.sdr, .sourceHDR], id: \.self) { value in
                        if inventory.recipes.contains(where: { $0.codec == codec && $0.color == value }) {
                            Text(value == .sdr ? "SDR" : "Source HDR").tag(value)
                        }
                    }
                }
                .onChange(of: color) { _, _ in reconcileRecipe() }
                Picker("Resolution", selection: $resolution) {
                    ForEach([ExportResolution.source, .hd720, .hd1080, .uhd4K], id: \.self) { value in
                        if matchingRecipes.contains(where: { $0.resolution == value }) {
                            Text(resolutionLabel(value)).tag(value)
                        }
                    }
                }
                if inventory.audioCodec != nil {
                    Toggle("Include local audio", isOn: $includeAudio)
                }
            }
        } header: {
            Text("Output")
        } footer: {
            outputFooter(for: inventory)
        }
    }

    private func outputFooter(for inventory: ExportMediaInventory) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if mode == .original {
                Text("Preserves source video, audio and available HDR / Dolby information without re-encoding.")
            } else {
                Text("Fits within the selected resolution without enlarging the source.")
                Text("Transcoding removes Dolby Vision metadata.")
                if inventory.audioCodec != nil {
                    Text("Included audio becomes AAC and loses Dolby / Atmos information.")
                } else {
                    Text("No local audio track — silent export.")
                }
            }
        }
    }

    private func reconcileRecipe() {
        guard let recipes = inventory?.recipes else { return }
        if !recipes.contains(where: { $0.codec == codec && $0.color == color }),
           let first = recipes.first(where: { $0.codec == codec }) { color = first.color }
        if !matchingRecipes.contains(where: { $0.resolution == resolution }),
           let first = matchingRecipes.first { resolution = first.resolution }
    }

    private func start() {
        guard !starting else { return }
        let options = ExportOptions(
            filename: filename, mode: mode, codec: codec, resolution: resolution,
            color: color, includeAudio: mode == .original ? inventory?.audioCodec != nil : includeAudio
        )
        starting = true
        Task {
            defer { starting = false }
            do {
                try await exports.start(source: source, options: options)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func resolutionLabel(_ value: ExportResolution) -> String {
        switch value {
        case .source: String(localized: "Source size")
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        }
    }
}
