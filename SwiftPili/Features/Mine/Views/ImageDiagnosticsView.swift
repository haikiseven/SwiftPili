import SwiftUI
import UIKit

/// Settings → Image Diagnostics. The on-device control surface for the
/// cover-scroll investigation; the procedure is `docs/IMAGE_SCROLL_PROFILING.md`.
///
/// Two levels, and the split is deliberate:
///  - **Image Performance Diagnostics** arms the subsystem — counters run, the
///    shared frame-pacing link starts, and the overlay becomes available.
///  - **Start Capture** additionally records timestamped events into a bounded
///    ring. Counters answer "how much"; the ring answers "in what order", which
///    is the only way to tell whether a stall lands on a disk hit, a network
///    completion, a size probe or nothing image-related at all.
///
/// **Freeze Loading Indicators** is a third, independent switch and is NOT part
/// of that ladder: it is the A/B arm for the loading indicator's own cost (see
/// `ImageLoadingIndicatorPolicy`), so it deliberately works with the
/// diagnostics subsystem disarmed — measuring it under an armed capture would
/// mean measuring it under a perturbation.
///
/// Release-visible on purpose: the reproduction is a real phone running a real
/// build, and the export button is the whole transport off the device.
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
    /// Defaults to TRUE: `.asyncCacheTypeCheck` is what the app ships, so the
    /// neutral position of this arm is on and the experiment is turning it off.
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

            // The A/B ladder. Every arm here is deliberately NOT gated on the
            // diagnostics switch above: the point is to run each one on an
            // otherwise untouched build, and arming diagnostics is itself a
            // perturbation. Flip exactly one at a time, and read the `arms=`
            // token in the freeze report and the `A/B arms:` line in the image
            // report to confirm which configuration a capture was taken under.
            Section {
                // B — is the loading indicator's ANIMATION costing frames? A
                // circular ProgressView is a UIActivityIndicatorView behind a
                // UIViewRepresentable: its spin is render-server work, so it
                // should not appear in the main-thread stall columns. This
                // varies exactly that animation and leaves the cover, the slot
                // and the layout identical — the loading mask itself is never
                // removed.
                //
                // ⚠️ It therefore CANNOT test the other half of the suspicion,
                // "up to 54 of them created in one frame", which this comment
                // used to claim for it: the static glyph occupies the same slot
                // and is created in the same numbers, so the creation count is
                // identical in both positions of the arm. That half is now
                // MEASURED instead of A/B'd — `spinners=` in the report totals
                // and the `spin` column of the worst-stall rows count
                // indicators actually minted, and a load that resolves inside
                // the 200 ms gate mints none. Read the count before reaching
                // for an arm; if it is zero the suspicion is dead without one.
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

                // C — is the instrumentation the cost? Several freeze reports
                // stop near an image diagnostic line, which proves only that
                // logging stopped when the main thread did. This turns the
                // per-image bookkeeping off while leaving the frame-pacing
                // measurement running, so the correlation can be falsified
                // instead of believed.
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

                // D — is the app paying for the SAME cover several times over?
                // Every distinct request box mints its own CDN transcode, its
                // own download, its own decode and its own memory-cache entry;
                // rounding to whole points already removed the fractional
                // widths a flexible grid hands out, but a rotation or a Split
                // View width is still a second box. This quantises the box so
                // nearby widths collapse onto one request. It over-fetches by
                // up to one 16pt step, which is the cost being traded.
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

                // E — the most recent change to this subsystem, and therefore
                // the first thing a bisect has to be able to undo. Off puts the
                // disk read and its decode back on the calling thread.
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

                // F — is the appearance transition the cost? On removes it
                // entirely. ⚠️ Expect NO change on a run made of cache hits:
                // Kingfisher fades only `cacheType == .none`, so a warm or
                // disk-warm scroll runs no transitions to remove. That null
                // result is the useful one — it is what leaves the completion and
                // layout side as the remaining candidate.
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

                // G — is the per-completion LAYOUT the cost? Each cover wraps
                // its artwork and clip layers in a `GeometryReader` for the
                // `[cover-geo]` measurement, and that line is written only while
                // a capture runs; until this arm existed the probes were
                // installed whenever diagnostics were merely armed, which is how
                // every counter-only report was taken. Their `onChange` fires
                // when an image lands and writes no state, so the layout never
                // reaches `img.body` — a report reading `img.body == img.appear`
                // cannot see it. On restores that configuration so the
                // comparison can be made rather than argued.
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
                        // Ternary inside Text() would take the plain-String
                        // overload and bypass localization.
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

/// Plain-text view over the image event ring. Copy All is the transport: no
/// tethered Mac, no console. A static snapshot; Refresh re-reads the ring.
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
