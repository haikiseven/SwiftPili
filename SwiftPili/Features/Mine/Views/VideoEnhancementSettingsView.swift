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
            adaptiveQualitySection
            advancedSection

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

    private var adaptiveQualitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { experiments.videoEnhancementAdaptiveQuality },
                set: { enabled in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementAdaptiveQuality(enabled)
                }
            )) {
                Label {
                    Text("Adaptive Quality")
                } icon: {
                    SettingsIcon(symbol: "gauge.with.dots.needle.33percent")
                }
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("When the device can't keep up, runs warm, or is in Low Power Mode, enhancement steps down gradually (lower interpolation rate, smaller scale, lighter upscaler, no interpolation) and recovers automatically. Turning this off keeps your settings; frames that miss their deadline are shown unenhanced and the device may heat up faster.")
        }
        .disabled(!canMutate)
    }

    private var advancedSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { experiments.videoEnhancementLimitToScreen },
                set: { enabled in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementLimitToScreen(enabled)
                }
            )) {
                Label {
                    Text("Limit to Screen Resolution")
                } icon: {
                    SettingsIcon(symbol: "iphone.gen3")
                }
            }

            Picker("Buffer Memory", selection: Binding(
                get: { experiments.videoEnhancementBufferBudget },
                set: { value in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementBufferBudget(value)
                }
            )) {
                ForEach(VideoEnhancementBufferBudget.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)

            Picker("Lookahead", selection: Binding(
                get: { experiments.videoEnhancementMaxLookahead },
                set: { value in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementMaxLookahead(value)
                }
            )) {
                ForEach(VideoEnhancementLookahead.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)

            Picker("Degradation Sensitivity", selection: Binding(
                get: { experiments.videoEnhancementAdaptiveSensitivity },
                set: { value in
                    guard canMutate else { return }
                    experiments.setVideoEnhancementAdaptiveSensitivity(value)
                }
            )) {
                ForEach(VideoEnhancementAdaptiveSensitivity.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            .disabled(!experiments.videoEnhancementAdaptiveQuality)
        } header: {
            Text("Advanced")
        } footer: {
            Text("Limit to Screen Resolution: super resolution never outputs more pixels than the video occupies on screen, and is skipped when it would not be visible. Buffer Memory: memory for enhanced frames waiting to be shown; Automatic uses 25% of currently available memory (128 MB–1 GB) and halves after a memory warning. Larger values allow higher output frame rates and a deeper lookahead, but too large may get the app terminated by the system. Lookahead: how far ahead frames are enhanced; deeper absorbs occasional slow frames but uses more memory. Degradation Sensitivity: how quickly quality is reduced when frames are missed.")
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
