import SwiftUI

struct ExperimentalSettingsView: View {
    private let experiments = ExperimentalSettingsStore.shared

    var body: some View {
        List {
            Group {
                Section {
                    Toggle(isOn: Binding(
                        get: { experiments.snapshot.masterEnabled },
                        set: { _ = experiments.setMasterEnabled($0) }
                    )) {
                        settingsLabel("Experimental Features", symbol: "flask")
                    }
                    .disabled(experiments.storageError != nil)
                    if let error = experiments.storageError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                networkExperimentsSection

                #if DEBUG
                playbackEngineExperimentsSection
                #endif
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Experimental Features")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var networkExperimentsSection: some View {
        Section("Network Experiments") {
            grantToggle(.http2Probe, title: "HTTP/2 Probe", symbol: "bolt.horizontal")
        }
    }

    #if DEBUG
    private var playbackEngineExperimentsSection: some View {
        let canEdit = experiments.storageError == nil && experiments.isAllowed(.diagnostics)
        return Section("Playback Engine Experiments") {
            Picker(selection: Binding(
                get: { experiments.snapshot.diagnosticOverrides.vodEngine },
                set: { value in updateOverrides { $0.vodEngine = value } }
            )) {
                ForEach(PlayerEngineKind.userSelectableCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                settingsLabel("VOD Engine", symbol: "gearshape.2")
            }
            overrideToggle("Pin Live Engine", symbol: "pin", keyPath: \.livePin)
        }
        .disabled(!canEdit)
    }

    private func overrideToggle(
        _ title: LocalizedStringKey, symbol: String,
        keyPath: WritableKeyPath<ExperimentalDiagnosticOverrides, Bool>
    ) -> some View {
        Toggle(isOn: Binding(
            get: { experiments.snapshot.diagnosticOverrides[keyPath: keyPath] },
            set: { value in updateOverrides { $0[keyPath: keyPath] = value } }
        )) {
            settingsLabel(title, symbol: symbol)
        }
    }

    private func updateOverrides(_ edit: (inout ExperimentalDiagnosticOverrides) -> Void) {
        guard experiments.storageError == nil, experiments.isAllowed(.diagnostics) else { return }
        var overrides = experiments.snapshot.diagnosticOverrides
        edit(&overrides)
        _ = experiments.updateDiagnosticOverrides(overrides)
    }
    #endif

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
            settingsLabel(title, symbol: symbol)
        }
        .disabled(!experiments.snapshot.masterEnabled || experiments.storageError != nil)
    }

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}
