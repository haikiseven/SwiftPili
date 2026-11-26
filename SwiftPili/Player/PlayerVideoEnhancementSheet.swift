import SwiftUI

struct PlayerVideoEnhancementSheet: View {
    let player: PlayerViewModel
    let canEdit: () -> Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let reason = player.videoEnhancementControlStatus.bypassReason {
                    Section {
                        Label(
                            VideoEnhancementBypassDisplay.pausedMenuLabel(for: reason),
                            systemImage: "pause.circle"
                        )
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
        Section {
            Toggle("MetalFX Spatial", isOn: Binding(
                get: { player.videoSuperResolutionMode == .metalFXSpatial },
                set: { enabled in
                    guard canEdit() else { return }
                    player.setVideoSuperResolutionMode(enabled ? .metalFXSpatial : .off)
                }
            ))

            if player.videoSuperResolutionMode == .metalFXSpatial {
                VideoEnhancementTargetResolutionControls(
                    targetResolution: player.videoSuperResolutionTargetResolution,
                    isDisabled: false
                ) { target in
                    guard canEdit() else { return }
                    player.setVideoSuperResolutionTargetResolution(target)
                }

                Picker("Sharpness", selection: Binding(
                    get: { player.videoSuperResolutionSharpness },
                    set: { sharpness in
                        guard canEdit() else { return }
                        player.setVideoSuperResolutionSharpness(sharpness)
                    }
                )) {
                    ForEach(VideoSuperResolutionSharpness.allCases) { sharpness in
                        Text(sharpness.label).tag(sharpness)
                    }
                }
                .pickerStyle(.menu)
                .menuOrder(.fixed)

                Toggle("Split-Screen Compare", isOn: Binding(
                    get: { player.videoSuperResolutionSplitCompare },
                    set: { enabled in
                        guard canEdit() else { return }
                        player.setVideoSuperResolutionSplitCompare(enabled)
                    }
                ))
            }

            Picker("Max Input Resolution", selection: Binding(
                get: { player.videoEnhancementMaxInputResolution },
                set: { limit in
                    guard canEdit() else { return }
                    player.setVideoEnhancementMaxInputResolution(limit)
                }
            )) {
                ForEach(VideoEnhancementMaxInputResolution.allCases) { limit in
                    Text(limit.label).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        } header: {
            Text("Super Resolution")
        }
    }

    private var interpolationSection: some View {
        let vtSupported = VideoEnhancementCapabilities.current.supportsVideoToolboxFrameInterpolation
        return Section("Frame Interpolation") {
            Toggle("Frame Interpolation", isOn: Binding(
                get: { player.videoFrameInterpolationEnabled },
                set: { enabled in
                    guard canEdit() else { return }
                    player.setVideoFrameInterpolationEnabled(enabled)
                }
            ))

            Picker("Target Frame Rate", selection: Binding(
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

            Picker("Interpolation Engine", selection: Binding(
                get: {
                    let current = player.videoFrameInterpolationBackend
                    return current.isSelectable(vtSupported: vtSupported)
                        ? current
                        : current.resolved(vtSupported: vtSupported)
                },
                set: { backend in
                    guard canEdit(), backend.isSelectable(vtSupported: vtSupported) else { return }
                    player.setVideoFrameInterpolationBackend(backend)
                }
            )) {
                ForEach(VideoFrameInterpolationBackend.allCases) { backend in
                    let selectable = backend.isSelectable(vtSupported: vtSupported)
                    Text(backend.label)
                        .selectionDisabled(!selectable)
                        .disabled(!selectable)
                        .tag(backend)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            .disabled(!player.videoFrameInterpolationEnabled)

            Toggle("Force Frame Interpolation", isOn: Binding(
                get: { player.videoForceFrameInterpolation },
                set: { enabled in
                    guard canEdit() else { return }
                    player.setVideoForceFrameInterpolation(enabled)
                }
            ))
            .disabled(!player.videoFrameInterpolationEnabled)
        }
    }
}

struct VideoEnhancementTargetResolutionControls: View {
    let targetResolution: VideoSuperResolutionTargetResolution
    let isDisabled: Bool
    let onCommit: (VideoSuperResolutionTargetResolution) -> Void

    @State private var draftShortEdge: Double?
    @State private var isDragging = false

    private var activeShortEdge: Int {
        if let draftShortEdge {
            return VideoSuperResolutionTargetResolution.clampedCustomShortEdge(Int(draftShortEdge.rounded()))
        }
        return targetResolution.shortEdge ?? 1440
    }

    var body: some View {
        presetPicker
        if targetResolution.isManual {
            manualAdjustmentRow
        }
    }

    private var presetPicker: some View {
        Picker("Target Resolution", selection: Binding(
            get: { targetResolution.preset },
            set: { preset in
                draftShortEdge = nil
                isDragging = false
                switch preset {
                case .auto: onCommit(.auto)
                case .p1080: onCommit(.p1080)
                case .p1440: onCommit(.p1440)
                case .p2160: onCommit(.p2160)
                case .custom: onCommit(VideoSuperResolutionTargetResolution.customDefault(from: targetResolution))
                }
            }
        )) {
            ForEach(VideoSuperResolutionTargetResolution.Preset.allCases) { preset in
                Text(preset.label).tag(preset)
            }
        }
        .pickerStyle(.menu)
        .menuOrder(.fixed)
        .disabled(isDisabled)
    }

    private var manualAdjustmentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Target Output")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(activeShortEdge)p")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Stepper(
                    "Target Output",
                    value: Binding(
                        get: { activeShortEdge },
                        set: { value in
                            draftShortEdge = nil
                            isDragging = false
                            onCommit(.fromShortEdge(value))
                        }
                    ),
                    in: VideoSuperResolutionTargetResolution.minimumCustomShortEdge
                        ... VideoSuperResolutionTargetResolution.maximumCustomShortEdge,
                    step: VideoSuperResolutionTargetResolution.customStep
                )
                .labelsHidden()
            }

            Slider(
                value: Binding(
                    get: { draftShortEdge ?? Double(targetResolution.shortEdge ?? 1440) },
                    set: { value in
                        if isDragging {
                            draftShortEdge = value
                        } else {
                            draftShortEdge = nil
                            onCommit(.fromShortEdge(Int(value.rounded())))
                        }
                    }
                ),
                in: Double(VideoSuperResolutionTargetResolution.minimumCustomShortEdge)
                    ... Double(VideoSuperResolutionTargetResolution.maximumCustomShortEdge),
                step: Double(VideoSuperResolutionTargetResolution.customStep),
                onEditingChanged: { editing in
                    isDragging = editing
                    if editing {
                        draftShortEdge = Double(targetResolution.shortEdge ?? 1440)
                    } else if let draft = draftShortEdge {
                        draftShortEdge = nil
                        onCommit(.fromShortEdge(Int(draft.rounded())))
                    }
                }
            )

            HStack {
                Text(verbatim: "720p")
                Spacer()
                Text(verbatim: "1440p")
                Spacer()
                Text(verbatim: "2160p")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .disabled(isDisabled)
        .onChange(of: targetResolution) { _, _ in
            if !isDragging { draftShortEdge = nil }
        }
        .onDisappear {
            draftShortEdge = nil
            isDragging = false
        }
    }
}
