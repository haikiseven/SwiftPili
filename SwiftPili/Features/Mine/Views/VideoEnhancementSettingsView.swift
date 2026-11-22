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

            superResolutionSection
            interpolationSection
            adaptiveQualitySection
            resourcesSection

            Section {
                capabilityRow("VideoToolbox ML", status: capabilities.videoToolboxML)
                capabilityRow("MetalFX Spatial", status: capabilities.metalFXSpatial)
                capabilityRow("Frame Interpolation", status: capabilities.frameInterpolation)
            } header: {
                Text("Device Support")
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Video Enhancement Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Super resolution

    private var superResolutionSection: some View {
        Section {
            Picker(selection: binding(\.videoEnhancementDefaultSRMode, experiments.setVideoEnhancementDefaultSRMode)) {
                ForEach(VideoSuperResolutionMode.allCases) { mode in
                    Text(mode.settingsLabel).tag(mode)
                }
            } label: {
                Text("Default Super Resolution")
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Picker(
                "Maximum Scale",
                selection: binding(\.videoEnhancementDefaultScale, experiments.setVideoEnhancementDefaultScale)
            ) {
                ForEach(VideoSuperResolutionScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)

            Toggle(isOn: binding(\.videoEnhancementLimitToScreen, experiments.setVideoEnhancementLimitToScreen)) {
                Label {
                    Text("Limit to Screen Resolution")
                } icon: {
                    SettingsIcon(symbol: "display")
                }
            }
        } header: {
            Text("Super Resolution")
        } footer: {
            Text("VideoEnhancementSRFooter", tableName: nil, comment: "Super resolution section footer")
        }
        .disabled(!canMutate)
    }

    // MARK: Frame interpolation

    private var interpolationSection: some View {
        Section {
            Toggle(isOn: binding(
                \.videoEnhancementDefaultFrameInterpolation, experiments.setVideoEnhancementDefaultFrameInterpolation
            )) {
                Label {
                    Text("Default Frame Interpolation")
                } icon: {
                    SettingsIcon(symbol: "film.stack")
                }
            }

            Picker(
                "Interpolation Rate",
                selection: binding(\.videoEnhancementDefaultRate, experiments.setVideoEnhancementDefaultRate)
            ) {
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

    // MARK: Adaptive quality

    private var adaptiveQualitySection: some View {
        Section {
            Toggle(isOn: binding(\.videoEnhancementAdaptiveQuality, experiments.setVideoEnhancementAdaptiveQuality)) {
                Label {
                    Text("Adaptive Quality")
                } icon: {
                    SettingsIcon(symbol: "gauge.with.dots.needle.33percent")
                }
            }

            if experiments.videoEnhancementAdaptiveQuality {
                Picker(
                    "Degradation Sensitivity",
                    selection: binding(
                        \.videoEnhancementAdaptiveSensitivity, experiments.setVideoEnhancementAdaptiveSensitivity
                    )
                ) {
                    ForEach(VideoEnhancementAdaptiveSensitivity.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .menuOrder(.fixed)
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("When the device can't keep up, runs warm, or is in Low Power Mode, enhancement steps down gradually (lower interpolation rate, smaller scale, lighter upscaler, no interpolation) and recovers automatically. Turning this off keeps your settings; frames that miss their deadline are shown unenhanced and the device may heat up faster.")
        }
        .disabled(!canMutate)
    }

    // MARK: Resources

    private var resourcesSection: some View {
        Section {
            Picker(
                "Buffer Memory",
                selection: binding(\.videoEnhancementBufferBudget, experiments.setVideoEnhancementBufferBudget)
            ) {
                ForEach(VideoEnhancementBufferBudget.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)

            Picker(
                "Lookahead",
                selection: binding(\.videoEnhancementMaxLookahead, experiments.setVideoEnhancementMaxLookahead)
            ) {
                ForEach(VideoEnhancementLookahead.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        } header: {
            Text("Advanced")
        } footer: {
            Text("VideoEnhancementResourcesFooter", tableName: nil, comment: "Buffer memory / lookahead footer")
        }
        .disabled(!canMutate)
    }

    // MARK: Helpers

    /// Binding that reads from the store and writes through its setter only while access is current.
    private func binding<Value>(
        _ keyPath: KeyPath<ExperimentalSettingsStore, Value>,
        _ setter: @escaping @MainActor (Value) -> Bool
    ) -> Binding<Value> {
        Binding(
            get: { experiments[keyPath: keyPath] },
            set: { value in
                guard canMutate else { return }
                _ = setter(value)
            }
        )
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
