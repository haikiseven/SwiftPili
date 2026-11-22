import SwiftUI

struct ExperimentalSettingsView: View {
    @AppMotion private var motion
    private let experiments = ExperimentalSettingsStore.shared
    @AppStorage(MultiConnectionFeatureGate.defaultsKey) private var multiConnectionEnabled = false
    @AppStorage(MultiConnectionFeatureGate.cellularDefaultsKey) private var multiConnectionCellularEnabled = false
    @AppStorage("comment_check_after_post") private var autoVerify = false
    @State private var toast: ToastMessage?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { experiments.snapshot.masterEnabled },
                    set: { _ = experiments.setMasterEnabled($0) }
                )) {
                    settingsLabel("Enable Experimental Features", symbol: "flask")
                }
                .disabled(experiments.storageError != nil)
                if let error = experiments.storageError {
                    Text(error).foregroundStyle(.red)
                }
            }

            playbackSection
            videoEnhancementSection
            multiConnectionSection
            networkSection
            aiCommentFilterSection
            commentVerificationSection
            diagnosticsSection
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Experimental Features")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast { ToastView(message: toast).padding(.bottom, 24) }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: toast)
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            grantToggle(.equalizer, title: "Equalizer Feature", symbol: "slider.vertical.3")
            grantToggle(.ambient, title: "Ambient Mode", symbol: "circle.lefthalf.filled")
            grantToggle(.decoderPrewarm, title: "Preload Video Decoder", symbol: "bolt.badge.clock")
        }
    }

    private var videoEnhancementSection: some View {
        Section("Video Enhancement") {
            grantToggle(.videoEnhancement, title: "Video Enhancement", symbol: "sparkles.tv")
            if let enhancementAccess = experiments.captureAccess(.videoEnhancement) {
                NavigationLink {
                    VideoEnhancementSettingsView(access: enhancementAccess)
                } label: {
                    LabeledContent {
                        Text(videoEnhancementSummary)
                    } label: {
                        settingsLabel("Video Enhancement Settings", symbol: "wand.and.stars")
                    }
                }
            }
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

    @ViewBuilder
    private var multiConnectionSection: some View {
        let access = experiments.captureAccess(.multiConnection)
        Section("Multi-connection") {
            grantToggle(.multiConnection, title: "Multi-connection Feature", symbol: "arrow.triangle.branch")
            if let access {
                Toggle(isOn: Binding(
                    get: { multiConnectionEnabled },
                    set: {
                        guard experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        multiConnectionEnabled = $0
                        PlayerViewModel.shared.refreshMultiConnectionQuiet()
                        if $0 { showNextVideoNotice() }
                    }
                )) {
                    settingsLabel("Parallel Connections", symbol: "network")
                }
                .disabled(experiments.storageError != nil)
                Toggle(isOn: Binding(
                    get: { multiConnectionCellularEnabled },
                    set: {
                        guard experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        multiConnectionCellularEnabled = $0
                        PlayerViewModel.shared.refreshMultiConnectionQuiet()
                        if $0 { showNextVideoNotice() }
                    }
                )) {
                    settingsLabel("Use on Cellular", symbol: "antenna.radiowaves.left.and.right")
                }
                .disabled(experiments.storageError != nil || !multiConnectionEnabled)
            }
        }
    }

    private var networkSection: some View {
        Section("Network") {
            grantToggle(.http2Probe, title: "HTTP/2 Probe", symbol: "bolt.horizontal")
        }
    }

    private var aiCommentFilterSection: some View {
        let aiFilterAccess = experiments.captureAccess(.aiCommentFilter)
        let aiFilterConfig = experiments.commentAIFilter
        return Section("AI Comment Filter") {
            grantToggle(.aiCommentFilter, title: "AI Comment Auto-Filter", symbol: "sparkles")
            if let aiFilterAccess {
                NavigationLink {
                    CommentAIFilterSettingsView(access: aiFilterAccess)
                } label: {
                    LabeledContent {
                        Text(aiFilterSummary(for: aiFilterConfig))
                    } label: {
                        settingsLabel("AI Comment Filter Settings", symbol: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    private func aiFilterSummary(for config: CommentAIFilterConfiguration) -> String {
        if config.rules.customThresholdOverride != nil {
            return "\(config.mode.localizedTitle) \(config.effectiveThreshold)%"
        }
        return config.sensitivity.localizedTitle
    }

    private var commentVerificationSection: some View {
        let access = experiments.captureAccess(.commentTools)
        return Section("Comment Verification") {
            grantToggle(.commentTools, title: "Comment Verification Tools", symbol: "checkmark.shield")
            if let access {
                Toggle(isOn: Binding(
                    get: { autoVerify },
                    set: {
                        guard experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        _ = experiments.setAutoVerifyEnabled($0)
                    }
                )) {
                    settingsLabel("Verify Comments After Posting", symbol: "text.badge.checkmark")
                }
                .disabled(experiments.storageError != nil)
                NavigationLink {
                    CommentCheckView(access: access)
                } label: {
                    settingsLabel("Comment Check", symbol: "eye.trianglebadge.exclamationmark")
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            grantToggle(.diagnostics, title: "Diagnostic Features", symbol: "waveform.path.ecg")
            NavigationLink {
                DiagnosticsSettingsView()
            } label: {
                settingsLabel("Diagnostic Tools", symbol: "stethoscope")
            }
        }
    }

    private func grantToggle(
        _ feature: ExperimentalFeature, title: LocalizedStringKey, symbol: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { experiments.snapshot.grants[feature] ?? false },
            set: {
                guard experiments.snapshot.masterEnabled, experiments.storageError == nil else { return }
                _ = experiments.setGranted($0, for: feature)
            }
        )) {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(symbol: symbol)
            }
        }
        .disabled(!experiments.snapshot.masterEnabled || experiments.storageError != nil)
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
