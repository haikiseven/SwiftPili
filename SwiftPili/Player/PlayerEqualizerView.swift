import SwiftUI

struct PlayerEqualizerView: View {
    let player: PlayerViewModel
    let presentation: PlayerEqualizerPresentationIdentity
    let access: ExperimentalAccessReceipt
    let presentationAdmission: () -> Bool
    private let experiments = ExperimentalSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Equalizer", isOn: Binding(
                        get: { player.equalizerConfiguration.enabled },
                        set: { enabled in update { $0.enabled = enabled } }
                    ))
                    LabeledContent("Status", value: statusLabel)
                }

                Section("Preset") {
                    Picker("Preset", selection: Binding(
                        get: { player.equalizerConfiguration.presetID },
                        set: {
                            guard isCurrentPresentation else { return }
                            player.updateEqualizer(
                                player.equalizerConfiguration.selectingPreset($0),
                                presentation: presentation, access: access
                            )
                        }
                    )) {
                        ForEach(PlayerEqualizerConfiguration.presets) { preset in
                            Text(presetLabel(preset.id)).tag(preset.id)
                        }
                        if player.equalizerConfiguration.presetID == "custom" {
                            Text("Custom").tag("custom")
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Frequency Bands") {
                    ForEach(PlayerEqualizerConfiguration.frequencies.indices, id: \.self) { index in
                        bandControl(index)
                    }
                }

                Section("Preamp") {
                    gainRow("Automatic Headroom", gain: -player.equalizerConfiguration.autoHeadroom)
                    VStack(alignment: .leading, spacing: 6) {
                        gainRow("Manual Attenuation", gain: player.equalizerConfiguration.userAttenuation)
                        Slider(value: Binding(
                            get: { Double(player.equalizerConfiguration.userAttenuation) },
                            set: { value in update { $0.userAttenuation = Float(value) } }
                        ), in: -12...0, step: 0.5)
                        .accessibilityLabel(Text("Manual Attenuation"))
                        .accessibilityValue(gainLabel(player.equalizerConfiguration.userAttenuation))
                    }
                    gainRow("Effective Preamp", gain: player.equalizerConfiguration.effectivePreamp)
                }

                Section {
                    Button("Restore Defaults") {
                        guard isCurrentPresentation else { return }
                        player.updateEqualizer(.defaults, presentation: presentation, access: access)
                    }
                }
            }
            .disabled(!isCurrentPresentation)
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: isCurrentPresentation, initial: true) { _, current in
                if !current { dismiss() }
            }
        }
        .accentContentBoundary()
    }

    private var isCurrentPresentation: Bool {
        presentationAdmission() && player.equalizerPresentationIdentity == presentation
            && experiments.isCurrentAccess(access)
    }

    private func bandControl(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(frequencyLabel(PlayerEqualizerConfiguration.frequencies[index]))
                Spacer()
                Text(gainLabel(player.equalizerConfiguration.bandGains[index]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(player.equalizerConfiguration.bandGains[index]) },
                set: { value in
                    update {
                        $0.bandGains[index] = Float(value)
                        $0.presetID = "custom"
                    }
                }
            ), in: -12...12, step: 0.5)
            .accessibilityLabel(frequencyLabel(PlayerEqualizerConfiguration.frequencies[index]))
            .accessibilityValue(gainLabel(player.equalizerConfiguration.bandGains[index]))
        }
    }

    private func update(_ edit: (inout PlayerEqualizerConfiguration) -> Void) {
        guard isCurrentPresentation else { return }
        var configuration = player.equalizerConfiguration
        edit(&configuration)
        player.updateEqualizer(configuration, presentation: presentation, access: access)
    }

    private func gainRow(_ title: LocalizedStringKey, gain: Float) -> some View {
        LabeledContent(title) { Text(gainLabel(gain)).monospacedDigit() }
    }

    private func gainLabel(_ gain: Float) -> String { String(format: "%+.1f dB", gain) }

    private func frequencyLabel(_ frequency: Float) -> String {
        if frequency >= 1_000 { return String(format: "%.0f kHz", frequency / 1_000) }
        return String(format: "%g Hz", frequency)
    }

    private func presetLabel(_ id: String) -> String {
        switch id {
        case "bass": String(localized: "Bass")
        case "vocal": String(localized: "Vocal")
        case "treble": String(localized: "Treble")
        default: String(localized: "Flat")
        }
    }

    private var statusLabel: String {
        switch player.equalizerStatus {
        case .retainedNoGraph: String(localized: "Saved for Playback")
        case .pendingNativeAccess: String(localized: "Pending Audio Update")
        case .configuredCurrentGraph: String(localized: "Configured")
        case .bypassed: String(localized: "Bypassed")
        case .unsupported: String(localized: "Equalizer Unavailable")
        case .failed: String(localized: "Audio Update Failed")
        }
    }
}

struct PlayerMoreControl: View {
    let player: PlayerViewModel
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    var showsAnimeOptions = false
    var onDownload: (() -> Void)?
    var onReport: (() -> Void)?
    var onDanmakuSettings: (() -> Void)?
    private let experiments = ExperimentalSettingsStore.shared
    @State private var presentation: Presentation?

    private struct Presentation: Identifiable {
        let id = UUID()
        let identity: PlayerEqualizerPresentationIdentity
        let access: ExperimentalAccessReceipt
        let screenLease: PlayerOwnerLease
        let receipt: PlayerPresentationReceipt?
        let hostIdentity: UUID?
    }

    var body: some View {
        let renderedIdentity = player.equalizerPresentationIdentity
        let renderedGeneration = player.loadGeneration
        let renderedSource = player.currentSource
        let renderedAccess = experiments.captureAccess(.equalizer)
        let admit = {
            isCurrentMenu && player.loadGeneration == renderedGeneration
                && player.currentSource == renderedSource
                && player.equalizerPresentationIdentity == renderedIdentity
        }
        PlayerOptionsMenu(
            player: player, showsAnimeOptions: includesAnimeOptions,
            onDownload: onDownload, onReport: onReport,
            onDanmakuSettings: onDanmakuSettings.map { action in
                {
                    guard admit() else { return }
                    action()
                }
            },
            onEqualizer: renderedAccess != nil && renderedIdentity != nil ? {
                guard admit(), let identity = renderedIdentity, let access = renderedAccess,
                      let screenLease, identity.owner == screenLease,
                      experiments.isCurrentAccess(access) else { return }
                presentation = Presentation(
                    identity: identity, access: access, screenLease: screenLease,
                    receipt: presentationReceipt, hostIdentity: fullscreenHostIdentity
                )
            } : nil,
            actionAdmission: admit, isPlayerChrome: true
        )
        .disabled(!isCurrentMenu)
        .sheet(item: $presentation) { request in
            PlayerEqualizerView(
                player: player, presentation: request.identity, access: request.access,
                presentationAdmission: {
                    isCurrentMenu && screenLease == request.screenLease
                        && presentationReceipt == request.receipt && fullscreenHostIdentity == request.hostIdentity
                }
            )
        }
        .onChange(of: isCurrentPresentation, initial: true) { _, current in
            if !current { presentation = nil }
        }
    }

    private var includesAnimeOptions: Bool {
        if showsAnimeOptions { return true }
        if let presentationReceipt, case .vod(_, _, .pgc) = presentationReceipt.context.source { return true }
        return false
    }

    private var isCurrentMenu: Bool {
        guard let screenLease, player.isCurrentOwner(screenLease) else { return false }
        guard let presentationReceipt else { return !player.isFullscreen }
        guard let fullscreenHostIdentity else { return false }
        return player.isCurrentPresentationReceipt(presentationReceipt, hostIdentity: fullscreenHostIdentity)
    }

    private var isCurrentPresentation: Bool {
        guard let presentation else { return true }
        return isCurrentMenu && player.equalizerPresentationIdentity == presentation.identity
            && experiments.isCurrentAccess(presentation.access)
            && screenLease == presentation.screenLease && presentationReceipt == presentation.receipt
            && fullscreenHostIdentity == presentation.hostIdentity
    }
}
