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
        Section {
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

            switch player.videoSuperResolutionMode {
            case .off:
                EmptyView()
            case .videoToolboxML:
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
            case .metalFXSpatial:
                VideoEnhancementTargetResolutionControls(
                    targetResolution: player.videoSuperResolutionTargetResolution,
                    isDisabled: false
                ) { target in
                    guard canEdit() else { return }
                    player.setVideoSuperResolutionTargetResolution(target)
                }
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
        } footer: {
            if player.videoSuperResolutionMode == .metalFXSpatial,
               player.videoSuperResolutionTargetResolution.isManual {
                Text(
                    """
                    Manual target resolution overrides Limit to Screen Resolution. \
                    Inputs already at or above the target skip upscaling.
                    """
                )
            }
        }
    }

    private var interpolationSection: some View {
        Section("Frame Interpolation") {
            Toggle("Frame Interpolation", isOn: Binding(
                get: { player.videoFrameInterpolationEnabled },
                set: { enabled in
                    guard canEdit() else { return }
                    player.setVideoFrameInterpolationEnabled(enabled)
                }
            ))

            VideoEnhancementTargetFPSControls(
                rate: player.videoInterpolationRate,
                isDisabled: !player.videoFrameInterpolationEnabled
            ) { rate in
                guard canEdit() else { return }
                player.setVideoInterpolationRate(rate)
            }
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

struct VideoEnhancementTargetFPSControls: View {
    let rate: VideoInterpolationRate
    let isDisabled: Bool
    let onCommit: (VideoInterpolationRate) -> Void

    @State private var draftFPS: Double?
    @State private var isDragging = false

    private var activeFPS: Int {
        if let draftFPS {
            return VideoInterpolationRate.clampedCustomFPS(Int(draftFPS.rounded()))
        }
        return rate.targetFPS ?? 60
    }

    var body: some View {
        presetPicker
        if rate.targetFPS != nil {
            manualAdjustmentRow
        }
    }

    private var presetPicker: some View {
        Picker("Target Frame Rate", selection: Binding(
            get: { rate.preset },
            set: { preset in
                draftFPS = nil
                isDragging = false
                switch preset {
                case .doubleRate: onCommit(.doubleRate)
                case .fps48: onCommit(.fps48)
                case .fps60: onCommit(.fps60)
                case .fps90: onCommit(.fps90)
                case .fps120: onCommit(.fps120)
                case .custom: onCommit(VideoInterpolationRate.customDefault(from: rate))
                }
            }
        )) {
            ForEach(VideoInterpolationRate.Preset.allCases) { preset in
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
                Text("Target FPS")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(activeFPS) fps")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Stepper(
                    "Target FPS",
                    value: Binding(
                        get: { activeFPS },
                        set: { value in
                            draftFPS = nil
                            isDragging = false
                            onCommit(.fromTargetFPS(value))
                        }
                    ),
                    in: VideoInterpolationRate.minimumCustomFPS ... VideoInterpolationRate.maximumCustomFPS,
                    step: VideoInterpolationRate.customStep
                )
                .labelsHidden()
            }

            Slider(
                value: Binding(
                    get: { draftFPS ?? Double(rate.targetFPS ?? 60) },
                    set: { value in
                        if isDragging {
                            draftFPS = value
                        } else {
                            draftFPS = nil
                            onCommit(.fromTargetFPS(Int(value.rounded())))
                        }
                    }
                ),
                in: Double(VideoInterpolationRate.minimumCustomFPS)
                    ... Double(VideoInterpolationRate.maximumCustomFPS),
                step: Double(VideoInterpolationRate.customStep),
                onEditingChanged: { editing in
                    isDragging = editing
                    if editing {
                        draftFPS = Double(rate.targetFPS ?? 60)
                    } else if let draft = draftFPS {
                        draftFPS = nil
                        onCommit(.fromTargetFPS(Int(draft.rounded())))
                    }
                }
            )

            HStack {
                Text(verbatim: "30 fps")
                Spacer()
                Text(verbatim: "60 fps")
                Spacer()
                Text(verbatim: "90 fps")
                Spacer()
                Text(verbatim: "120 fps")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .disabled(isDisabled)
        .onChange(of: rate) { _, _ in
            if !isDragging { draftFPS = nil }
        }
        .onDisappear {
            draftFPS = nil
            isDragging = false
        }
    }
}
