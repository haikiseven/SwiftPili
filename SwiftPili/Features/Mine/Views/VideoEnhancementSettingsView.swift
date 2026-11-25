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

            Section {
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
            Toggle(isOn: Binding(
                get: { experiments.videoEnhancementDefaultSRMode == .metalFXSpatial },
                set: { enabled in
                    guard canMutate else { return }
                    _ = experiments.setVideoEnhancementDefaultSRMode(enabled ? .metalFXSpatial : .off)
                }
            )) {
                Label {
                    Text("Default Super Resolution")
                } icon: {
                    SettingsIcon(symbol: "sparkles.tv")
                }
            }

            if experiments.videoEnhancementDefaultSRMode == .metalFXSpatial {
                VideoEnhancementTargetResolutionControls(
                    targetResolution: experiments.videoEnhancementDefaultTargetResolution,
                    isDisabled: false
                ) { target in
                    guard canMutate else { return }
                    _ = experiments.setVideoEnhancementDefaultTargetResolution(target)
                }

                Picker(
                    "Sharpness",
                    selection: binding(
                        \.videoEnhancementDefaultSharpness, experiments.setVideoEnhancementDefaultSharpness
                    )
                ) {
                    ForEach(VideoSuperResolutionSharpness.allCases) { sharpness in
                        Text(sharpness.label).tag(sharpness)
                    }
                }
                .pickerStyle(.menu)
                .menuOrder(.fixed)
            }

            Picker(
                "Max Input Resolution",
                selection: binding(
                    \.videoEnhancementMaxInputResolution, experiments.setVideoEnhancementMaxInputResolution
                )
            ) {
                ForEach(VideoEnhancementMaxInputResolution.allCases) { limit in
                    Text(limit.label).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)

            if experiments.videoEnhancementDefaultSRMode != .metalFXSpatial
                || !experiments.videoEnhancementDefaultTargetResolution.isManual {
                Toggle(isOn: binding(\.videoEnhancementLimitToScreen, experiments.setVideoEnhancementLimitToScreen)) {
                    Label {
                        Text("Limit to Screen Resolution")
                    } icon: {
                        SettingsIcon(symbol: "display")
                    }
                }
            }
        } header: {
            Text("Super Resolution")
        } footer: {
            Text(
                """
                Applies to SDR Demand VOD streams within the max input resolution. \
                MetalFX Spatial supports manual target resolution, which overrides Limit to Screen Resolution. \
                High temperatures pause enhancement.
                """
            )
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
                "Target Frame Rate",
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
