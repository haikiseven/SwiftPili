import SwiftUI

struct VideoEnhancementSettingsView: View {
    private let experiments = ExperimentalSettingsStore.shared
    let access: ExperimentalAccessReceipt

    private var canMutate: Bool {
        experiments.storageError == nil && experiments.isCurrentAccess(access)
    }

    var body: some View {
        let capabilities = VideoEnhancementCapabilities.current

        List {
            superResolutionDefaults
            interpolationDefaults

            Section {
                capabilityRow("VideoToolbox ML", status: capabilities.videoToolboxML)
                capabilityRow("MetalFX Spatial", status: capabilities.metalFXSpatial)
                capabilityRow("Frame Interpolation", status: capabilities.frameInterpolation)
            } header: {
                Text("Device Support")
            }

            if let storageError = experiments.storageError {
                Section {
                    Text(verbatim: storageError)
                        .foregroundStyle(.red)
                }
            } else if !experiments.isCurrentAccess(access) {
                Section {
                    Text("Video enhancement is disabled in Experimental Features.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Video Enhancement Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var superResolutionDefaults: some View {
        Section {
            Picker(selection: Binding(
                get: { experiments.videoEnhancementDefaultSRMode },
                set: { mode in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementDefaultSRMode(mode)
                }
            )) {
                ForEach(VideoSuperResolutionMode.allCases) { mode in
                    Text(mode.settingsLabel).tag(mode)
                }
            } label: {
                Text("Default Super Resolution")
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Picker("Maximum Scale", selection: Binding(
                get: { experiments.videoEnhancementDefaultScale },
                set: { scale in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementDefaultScale(scale)
                }
            )) {
                ForEach(VideoSuperResolutionScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        } header: {
            Text("Default Super Resolution")
        } footer: {
            Text("Applies to SDR Demand VOD streams up to 1080p. High temperatures pause enhancement.")
        }
        .disabled(!canMutate)
    }

    private var interpolationDefaults: some View {
        Section {
            Toggle(isOn: Binding(
                get: { experiments.videoEnhancementDefaultFrameInterpolation },
                set: { enabled in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementDefaultFrameInterpolation(enabled)
                }
            )) {
                Label {
                    Text("Default Frame Interpolation")
                } icon: {
                    SettingsIcon(symbol: "film.stack")
                }
            }

            Picker("Interpolation Rate", selection: Binding(
                get: { experiments.videoEnhancementDefaultRate },
                set: { rate in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementDefaultRate(rate)
                }
            )) {
                ForEach(VideoInterpolationRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        } header: {
            Text("Frame Interpolation")
        } footer: {
            Text("Applies to supported progressive SDR Demand VOD streams. High temperatures pause enhancement.")
        }
        .disabled(!canMutate)
    }

    private func capabilityRow(
        _ title: LocalizedStringKey,
        status: VideoEnhancementCapabilityStatus
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.isSupported ? Color.green : Color.secondary)
                Text(status.localizedText)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
