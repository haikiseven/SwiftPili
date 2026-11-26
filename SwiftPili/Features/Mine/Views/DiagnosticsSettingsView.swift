import SwiftUI

struct DiagnosticsSettingsView: View {
    private let experiments = ExperimentalSettingsStore.shared
    @AppStorage("debug_logging_enabled") private var debugLogging = false

    var body: some View {
        let access = experiments.captureAccess(.diagnostics)
        List {
            Group {
                Section("Reports") {
                    NavigationLink {
                        HangReportView()
                    } label: {
                        settingsLabel("View App Reports", symbol: "exclamationmark.triangle")
                    }
                }
                Section("Playback Diagnostics") {
                    Toggle(isOn: Binding(
                        get: { debugLogging },
                        set: {
                            guard canMutate(access) else { return }
                            _ = experiments.setDebugLoggingEnabled($0)
                        }
                    )) {
                        settingsLabel("Debug Logging", symbol: "waveform.path.ecg")
                    }
                    .disabled(!canMutate(access))
                }
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Diagnostic Tools")
        .navigationBarTitleDisplayMode(.inline)
    }

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
