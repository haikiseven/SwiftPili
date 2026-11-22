import SwiftUI
import UIKit

struct ImageDiagnosticsView: View {
    private let experiments = ExperimentalSettingsStore.shared
    @AppStorage(ImageDiagnostics.enabledKey) private var enabled = false
    @AppStorage(ImageDiagnostics.overlayKey) private var overlayOn = false
    @AppStorage(ImageLoadingIndicatorPolicy.staticIndicatorKey)
    private var staticIndicator = false
    @AppStorage(ImagePipelinePolicy.suppressDiagnosticsKey)
    private var suppressInstrumentation = false
    @AppStorage(ImagePipelinePolicy.stableRequestGeometryKey)
    private var stableGeometry = false
    @AppStorage(ImagePipelinePolicy.asyncDecodeKey)
    private var asyncDecode = true
    @AppStorage(ImagePipelinePolicy.instantTransitionKey)
    private var instantTransition = false
    @AppStorage(ImagePipelinePolicy.splitLayoutProbesKey)
    private var splitLayoutProbes = false
    @State private var capturing = ImageDiagnostics.isCapturing
    @State private var showClearConfirm = false

    var body: some View {
        let access = experiments.captureAccess(.diagnostics)
        let canMutate = access.map { experiments.isCurrentAccess($0) } == true && experiments.storageError == nil
        List {
            Section("Reports") {
                NavigationLink {
                    ImageDiagnosticsLogView()
                } label: {
                    Label {
                        Text("View Image Report")
                    } icon: {
                        SettingsIcon(symbol: "doc.plaintext")
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImageDiagnostics.setEnabled(newValue)
                        capturing = ImageDiagnostics.isCapturing
                    }
                )) {
                    Label {
                        Text("Image Performance Diagnostics")
                    } icon: {
                        SettingsIcon(symbol: "photo.badge.checkmark")
                    }
                }
                Toggle(isOn: Binding(
                    get: { overlayOn },
                    set: {
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImageDiagnostics.setOverlayEnabled($0)
                    }
                )) {
                    Label {
                        Text("Show Counter Overlay")
                    } icon: {
                        SettingsIcon(symbol: "square.text.square")
                    }
                }
                .disabled(!enabled)

            } header: {
                Text("Image Diagnostics")
            }
            .disabled(!canMutate)

            Section {
                Toggle(isOn: Binding(
                    get: { staticIndicator },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImageLoadingIndicatorPolicy.setStatic(newValue)
                    }
                )) {
                    Label {
                        Text("Freeze Loading Indicators")
                    } icon: {
                        SettingsIcon(symbol: "circle.dashed")
                    }
                }

                Toggle(isOn: Binding(
                    get: { suppressInstrumentation },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImagePipelinePolicy.setSuppressesDiagnostics(newValue)
                    }
                )) {
                    Label {
                        Text("Suppress Image Instrumentation")
                    } icon: {
                        SettingsIcon(symbol: "eye.slash")
                    }
                }

                Toggle(isOn: Binding(
                    get: { stableGeometry },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImagePipelinePolicy.setUsesStableRequestGeometry(newValue)
                    }
                )) {
                    Label {
                        Text("Stabilize Request Geometry")
                    } icon: {
                        SettingsIcon(symbol: "ruler")
                    }
                }

                Toggle(isOn: Binding(
                    get: { asyncDecode },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImagePipelinePolicy.setUsesAsyncCacheTypeCheck(newValue)
                    }
                )) {
                    Label {
                        Text("Async Image Decode")
                    } icon: {
                        SettingsIcon(symbol: "arrow.triangle.branch")
                    }
                }

                Toggle(isOn: Binding(
                    get: { instantTransition },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImagePipelinePolicy.setUsesInstantTransition(newValue)
                    }
                )) {
                    Label {
                        Text("Instant Image Transition")
                    } icon: {
                        SettingsIcon(symbol: "bolt.horizontal")
                    }
                }

                Toggle(isOn: Binding(
                    get: { splitLayoutProbes },
                    set: { newValue in
                        guard let access, experiments.isCurrentAccess(access),
                              experiments.storageError == nil else { return }
                        ImagePipelinePolicy.setSplitsLayoutProbes(newValue)
                    }
                )) {
                    Label {
                        Text("Split Layout Probes")
                    } icon: {
                        SettingsIcon(symbol: "square.on.square.dashed")
                    }
                }
            } header: {
                Text("A/B Arms")
            }
            .disabled(!canMutate)

            Section {
                Button {
                    guard let access, experiments.isCurrentAccess(access),
                          experiments.storageError == nil else { return }
                    if capturing {
                        ImageDiagnostics.stopCapture()
                    } else {
                        ImageDiagnostics.startCapture()
                    }
                    capturing = ImageDiagnostics.isCapturing
                } label: {
                    Label {
                        capturing ? Text("Stop Capture") : Text("Start Capture")
                    } icon: {
                        SettingsIcon(
                            symbol: capturing ? "stop.circle.fill" : "record.circle",
                            tint: capturing ? .red : nil
                        )
                    }
                }
                .disabled(!enabled || !canMutate)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label {
                        Text("Clear Image Log")
                            .foregroundStyle(.red)
                    } icon: {
                        SettingsIcon(symbol: "trash.fill", tint: .red)
                    }
                }
                .confirmationDialog(
                    "Discard the captured image events?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear Image Log", role: .destructive) {
                        ImageDiagnostics.clearLog()
                    }
                }
            } header: {
                Text("Capture")
            }
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle(Text("Image Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { capturing = ImageDiagnostics.isCapturing }
        .onChange(of: access) { _, _ in capturing = ImageDiagnostics.isCapturing }
    }
}

struct ImageDiagnosticsLogView: View {
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: report)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle(Text("Image Report"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label {
                        copied ? Text("Copied") : Text("Copy All")
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    report = ImageDiagnostics.shared.reportText()
                    copied = false
                } label: {
                    Label {
                        Text("Refresh")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { report = ImageDiagnostics.shared.reportText() }
    }
}
