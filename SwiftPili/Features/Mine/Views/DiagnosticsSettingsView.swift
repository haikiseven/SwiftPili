import SwiftUI

struct DiagnosticsSettingsView: View {
    private let experiments = ExperimentalSettingsStore.shared
    @AppStorage("debug_logging_enabled") private var debugLogging = false

    var body: some View {
        let access = experiments.captureAccess(.diagnostics)
        List {
            Section("Reports") {
                NavigationLink {
                    HangReportView()
                } label: {
                    settingsLabel("View App Reports", symbol: "exclamationmark.triangle")
                }
            }
            #if DEBUG
            playbackOverrides(access: access)
            #endif
            Section("Playback Diagnostics") {
                Toggle(isOn: Binding(
                    get: { debugLogging },
                    set: {
                        guard canMutate(access) else { return }
                        PlayerLog.setEnabled($0)
                    }
                )) {
                    settingsLabel("Debug Logging", symbol: "waveform.path.ecg")
                }
                .disabled(!canMutate(access))
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Diagnostic Tools")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if DEBUG
    private func playbackOverrides(access: ExperimentalAccessReceipt?) -> some View {
        Section("Playback Experiments") {
            Picker(selection: Binding(
                get: { experiments.snapshot.diagnosticOverrides.vodEngine },
                set: { value in
                    updateOverrides(access: access) { $0.vodEngine = value }
                }
            )) {
                ForEach(PlayerEngineKind.userSelectableCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                Label {
                    Text("VOD Engine")
                } icon: {
                    SettingsIcon(symbol: "gearshape.2")
                }
            }
            overrideToggle("Pin Live Engine", symbol: "pin", keyPath: \.livePin, access: access)
            overrideToggle("set_time Seek", symbol: "flask", keyPath: \.setTimeSeek, access: access)
            overrideToggle("Prefetch Filter", symbol: "memorychip", keyPath: \.prefetchFilter, access: access)
            overrideToggle(
                "Audio-Output Speed Engine", symbol: "gauge.with.needle", keyPath: \.audioOutputSpeed,
                access: access
            )
            overrideToggle(
                "Demand Pitch Correction", symbol: "waveform.badge.magnifyingglass", keyPath: \.demandPitch,
                access: access
            )
        }
        .disabled(!canMutate(access))
    }

    private func overrideToggle(
        _ title: LocalizedStringKey, symbol: String,
        keyPath: WritableKeyPath<ExperimentalDiagnosticOverrides, Bool>, access: ExperimentalAccessReceipt?
    ) -> some View {
        Toggle(isOn: Binding(
            get: { experiments.snapshot.diagnosticOverrides[keyPath: keyPath] },
            set: { value in updateOverrides(access: access) { $0[keyPath: keyPath] = value } }
        )) {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(symbol: symbol)
            }
        }
    }

    private func updateOverrides(
        access: ExperimentalAccessReceipt?, edit: (inout ExperimentalDiagnosticOverrides) -> Void
    ) {
        guard canMutate(access) else { return }
        var overrides = experiments.snapshot.diagnosticOverrides
        edit(&overrides)
        _ = experiments.updateDiagnosticOverrides(overrides)
    }
    #endif

    private func canMutate(_ access: ExperimentalAccessReceipt?) -> Bool {
        guard let access else { return false }
        return experiments.storageError == nil && experiments.isCurrentAccess(access)
    }

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}
