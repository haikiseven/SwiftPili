import SwiftUI

/// The playback menu owns the presentation and validates its scope on every edit.
struct PlayerVideoEnhancementSheet: View {
    let player: PlayerViewModel
    let canEdit: () -> Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let reason = player.videoEnhancementControlStatus.bypassReason {
                    Section {
                        Label(VideoEnhancementBypassDisplay.pausedMenuLabel(for: reason), systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                superResolutionSection
                interpolationSection
            }
            .disabled(!canEdit())
            .navigationTitle("Video Enhancement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .accentContentBoundary()
        .appAdaptiveSheet()
    }

    private var superResolutionSection: some View {
        Section("Super Resolution") {
            Picker("Super Resolution", selection: Binding(
                get: { player.videoSuperResolutionMode },
                set: { mode in
                    guard canEdit() else { return }
                    player.setVideoSuperResolutionMode(mode)
                }
            )) {
                ForEach(VideoSuperResolutionMode.allCases) { mode in
                    Text(mode.settingsLabel).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Picker("Maximum Scale", selection: Binding(
                get: { player.videoSuperResolutionScale },
                set: { scale in
                    guard canEdit() else { return }
                    player.setVideoSuperResolutionScale(scale)
                }
            )) {
                ForEach(VideoSuperResolutionScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            .disabled(player.videoSuperResolutionMode == .off)
        }
    }

    private var interpolationSection: some View {
        Section {
            Toggle("Frame Interpolation", isOn: Binding(
                get: { player.videoFrameInterpolationEnabled },
                set: { enabled in
                    guard canEdit() else { return }
                    player.setVideoFrameInterpolationEnabled(enabled)
                }
            ))

            Picker("Interpolation Rate", selection: Binding(
                get: { player.videoInterpolationRate },
                set: { rate in
                    guard canEdit() else { return }
                    player.setVideoInterpolationRate(rate)
                }
            )) {
                ForEach(VideoInterpolationRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            .disabled(!player.videoFrameInterpolationEnabled)
        }
    }
}
