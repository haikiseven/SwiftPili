import SwiftUI

struct AdvancedSettingsView: View {
    @AppMotion private var motion
    private let experiments = ExperimentalSettingsStore.shared

    @State private var hardwareDecode = PlayerPlaybackPreferences.hardwareDecodeEnabled
    @State private var preferredCodec = PlayerPlaybackPreferences.preferredCodec
    @State private var preloadStrategy = PlayerPlaybackPreferences.preloadStrategy
    @State private var smartCDNEnabled = SmartCDNSelector.isEnabled
    @State private var currentCDNLabel = CDNService.current.label

    @AppStorage(MultiConnectionFeatureGate.defaultsKey) private var multiConnectionEnabled = false
    @AppStorage(MultiConnectionFeatureGate.cellularDefaultsKey) private var multiConnectionCellularEnabled = false
    @AppStorage("show_network_speed") private var showNetworkSpeed = false
    @AppStorage("debug_logging_enabled") private var debugLogging = false

    @State private var toast: ToastMessage?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        List {
            Group {
                videoEnhancementSection
                decodingAndEngineSection
                networkAndDeliverySection
                diagnosticsSection
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Advanced Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hardwareDecode = PlayerPlaybackPreferences.hardwareDecodeEnabled
            preferredCodec = PlayerPlaybackPreferences.preferredCodec
            preloadStrategy = PlayerPlaybackPreferences.preloadStrategy
            smartCDNEnabled = SmartCDNSelector.isEnabled
            currentCDNLabel = CDNService.current.label
        }
        .onDisappear {
            toastDismissTask?.cancel()
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast { ToastView(message: toast).padding(.bottom, 24) }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: toast)
        }
    }

    private var videoEnhancementSection: some View {
        Section("Video Enhancement") {
            NavigationLink {
                VideoEnhancementSettingsView()
            } label: {
                LabeledContent {
                    Text(videoEnhancementSummary)
                } label: {
                    settingsLabel("Video Enhancement", symbol: "sparkles.tv")
                }
            }
        }
    }

    private var decodingAndEngineSection: some View {
        Section("Decoding & Engine") {
            Toggle(isOn: Binding(
                get: { hardwareDecode },
                set: { newValue in
                    hardwareDecode = newValue
                    PlayerPlaybackPreferences.hardwareDecodeEnabled = newValue
                }
            )) {
                settingsLabel("Hardware Decoding", symbol: "cpu")
            }

            Picker(selection: Binding(
                get: { preferredCodec },
                set: { newValue in
                    preferredCodec = newValue
                    PlayerPlaybackPreferences.preferredCodec = newValue
                }
            )) {
                ForEach(VideoCodecPreference.allCases, id: \.self) { codec in
                    Text(codec.label).tag(codec)
                }
            } label: {
                settingsLabel("Preferred Codec", symbol: "film")
            }

            Picker(selection: Binding(
                get: { preloadStrategy },
                set: { newValue in
                    preloadStrategy = newValue
                    PlayerPlaybackPreferences.preloadStrategy = newValue
                }
            )) {
                ForEach(PlayerPlaybackPreferences.PreloadStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.label).tag(strategy)
                }
            } label: {
                settingsLabel("Preload Strategy", symbol: "arrow.down.circle.dotted")
            }

            Toggle(isOn: Binding(
                get: { experiments.decoderPrewarmEnabled },
                set: { _ = experiments.setDecoderPrewarmEnabled($0) }
            )) {
                settingsLabel("Prewarm Decoder", symbol: "bolt.badge.clock")
            }
        }
    }

    private var networkAndDeliverySection: some View {
        Section("Network & Delivery") {
            NavigationLink {
                CDNSettingsView()
            } label: {
                LabeledContent {
                    if smartCDNEnabled {
                        Text("Smart CDN")
                    } else {
                        Text(currentCDNLabel)
                    }
                } label: {
                    settingsLabel("CDN Settings", symbol: "server.rack")
                }
            }

            Toggle(isOn: Binding(
                get: { multiConnectionEnabled },
                set: { newValue in
                    multiConnectionEnabled = newValue
                    PlayerViewModel.shared.refreshMultiConnectionQuiet()
                    if newValue { showNextVideoNotice() }
                }
            )) {
                settingsLabel("Parallel Connections", symbol: "arrow.triangle.branch")
            }

            Toggle(isOn: Binding(
                get: { multiConnectionCellularEnabled },
                set: { newValue in
                    multiConnectionCellularEnabled = newValue
                    PlayerViewModel.shared.refreshMultiConnectionQuiet()
                    if newValue { showNextVideoNotice() }
                }
            )) {
                settingsLabel("Use on Cellular", symbol: "antenna.radiowaves.left.and.right")
            }
            .disabled(!multiConnectionEnabled)

            Toggle(isOn: $showNetworkSpeed) {
                settingsLabel("Show Network Speed", symbol: "speedometer")
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                HangReportView()
            } label: {
                settingsLabel("View App Reports", symbol: "exclamationmark.triangle")
            }

            Toggle(isOn: Binding(
                get: { debugLogging },
                set: { newValue in
                    debugLogging = newValue
                    _ = experiments.setDebugLoggingEnabled(newValue)
                }
            )) {
                settingsLabel("Debug Logging", symbol: "waveform.path.ecg")
            }

            #if DEBUG
            NavigationLink {
                DiagnosticsSettingsView()
            } label: {
                settingsLabel("Diagnostic Tools", symbol: "stethoscope")
            }
            #endif
        }
    }

    private var videoEnhancementSummary: String {
        let srMode = experiments.videoEnhancementDefaultSRMode
        let frcEnabled = experiments.videoEnhancementDefaultFrameInterpolation
        switch (srMode, frcEnabled) {
        case (.off, false):
            return String(localized: "Off")
        case (.off, true):
            return String(localized: "FRC")
        case (_, false):
            return srMode.shortLabel
        case (_, true):
            return "\(srMode.shortLabel) + \(String(localized: "FRC"))"
        }
    }

    private func showNextVideoNotice() {
        toastDismissTask?.cancel()
        toast = ToastMessage(text: String(localized: "Applies to the next video"), style: .success)
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}
