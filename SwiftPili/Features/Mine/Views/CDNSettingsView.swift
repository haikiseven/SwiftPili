import SwiftUI

struct CDNSettingsView: View {
    @AppMotion private var motion
    @State private var selected = CDNService.current
    @State private var results: [CDNService: CDNTestResult] = [:]
    @State private var isTesting = false
    @State private var testProgress = 0
    @State private var testTotal = 0
    @State private var testError: String?
    @State private var smartEnabled = SmartCDNSelector.isEnabled
    @State private var fallbackEnabled = PlayerPlaybackPreferences.cdnFallbackEnabled
    @State private var probeBudgetMB = SmartCDNSelector.probeBudgetMB
    @State private var scaleProbeOnCellular = SmartCDNSelector.scaleProbeOnCellular
    @State private var blockPCDN = CDNHostPolicy.blockPCDN
    private var smart: SmartCDNSelector { SmartCDNSelector.shared }

    /// Always visible — just two rows, and the most common picks.
    private let defaultCDNs: [CDNService] = [.baseUrl, .backupUrl]

    @State private var expandedProviders: Set<CDNProvider> = []

    /// See VideoDetailView: this read the raw theme and ignored `AccentScope`.
    /// Routed through the store so it agrees with every other accent surface.
    private var accent: Color { .biliAccent }

    var body: some View {
        List {
            Group {
                smartSection
                if smartEnabled {
                    Section("Automatic Selection Status") {
                        smartStatusRows
                    }
                }
                smartConfigurationSection
                fallbackSection
                blockPCDNSection
                manualSelectionSection
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle(Text("CDN Settings", comment: "CDN settings nav title"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(motion.animation(normal: .default), value: selected)
        .animation(motion.animation(normal: .default), value: smartEnabled)
        .onAppear {
            // Open the group holding the current pick; everything else
            // starts collapsed.
            if let current = selected.provider {
                expandedProviders.insert(current)
            }
            // "My Network" must show the interface in use RIGHT NOW —
            // cheap re-detect on every appear, full re-test only if the
            // public IP actually moved.
            Task { await smart.refreshClientNetwork(trigger: "settings opened") }
        }
    }

    private var manualSelectionSection: some View {
        Section {
            LabeledContent("Saved Selection", value: selected.label)

            Button {
                Task { await testAll() }
            } label: {
                HStack {
                    Label {
                        // Action row — accent text marks it tappable.
                        Text("Test CDN Speed", comment: "CDN speed test button")
                            .foregroundStyle(accent)
                    } icon: {
                        SettingsIcon(symbol: "speedometer")
                    }
                    Spacer()
                    if isTesting {
                        HStack(spacing: 6) {
                            Text("\(testProgress)/\(testTotal)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            ProgressView()
                        }
                    }
                }
            }
            .disabled(isTesting)

            if let testError {
                Text(testError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(defaultCDNs) { cdn in cdnRow(cdn) }

            ForEach(CDNProvider.allCases) { provider in
                categoryGroup(provider)
            }
        } header: {
            if smartEnabled {
                Text("Manual CDN Fallback")
            } else {
                Text("Manual CDN Selection")
            }
        }
    }

    /// Collapsible provider group: brand-tinted mark, node count, and —
    /// while collapsed — a pill naming the selected node inside, so the
    /// folding never hides the current pick.
    @ViewBuilder
    private func categoryGroup(_ provider: CDNProvider) -> some View {
        let expanded = expandedProviders.contains(provider)
        Button {
            withAnimation(motion.animation(normal: .snappy(duration: 0.28))) {
                if expanded {
                    expandedProviders.remove(provider)
                } else {
                    expandedProviders.insert(provider)
                }
            }
        } label: {
            HStack(spacing: 12) {
                CDNProviderMark(provider: provider)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(provider.services.count) nodes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !expanded, selected.provider == provider {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                        Text(selected.label)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)

        if expanded {
            ForEach(provider.services) { cdn in cdnRow(cdn) }
        }
    }

    // MARK: - Smart CDN Selection (智能CDN选择)

    private var smartSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { smartEnabled },
                set: { on in
                    smartEnabled = on
                    SmartCDNSelector.isEnabled = on
                    PlayerLog.log("[SmartCDN] toggle → \(on ? "ON" : "OFF")")
                    if on {
                        Task { await smart.warmUp(trigger: "toggle enabled", force: true) }
                    } else {
                        smart.invalidateCache(reason: "toggle disabled")
                    }
                }
            )) {
                Label {
                    Text("Smart CDN Selection")
                } icon: {
                    SettingsIcon(symbol: "wand.and.stars")
                }
            }
        }
    }

    // MARK: - Automatic CDN Fallback

    private var fallbackSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { fallbackEnabled },
                set: { on in
                    fallbackEnabled = on
                    PlayerPlaybackPreferences.cdnFallbackEnabled = on
                    PlayerLog.log("[CDN] automatic fallback toggle → \(on ? "ON" : "OFF")")
                }
            )) {
                Label {
                    Text("Automatic CDN Fallback")
                } icon: {
                    SettingsIcon(symbol: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private var blockPCDNSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { blockPCDN },
                set: {
                    blockPCDN = $0
                    CDNHostPolicy.blockPCDN = $0
                }
            )) {
                Label {
                    Text("Block PCDN")
                } icon: {
                    SettingsIcon(symbol: "network.badge.shield.half.filled")
                }
            }
        }
    }

    @ViewBuilder
    private var smartStatusRows: some View {
        if let client = smart.client {
            statusRow(
                title: Text("My Network"),
                value: "\(client.ip) · \(client.isp) · \(client.province)"
            )
        }

        // The VPN tell is fake-IP DNS answers (through a tunnel the
        // server still sees a public exit address, so the client IP
        // looks normal). Falls back to a reserved client address for
        // the rare double-failure case.
        if smart.fakeIPDNSDetected || smart.client?.isPublicAddress == false {
            Label {
                Text("Fake-IP DNS server detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                // Semantic warning — stays orange regardless of theme.
                SettingsIcon(symbol: "exclamationmark.shield", tint: .orange)
            }
        }

        if let best = smart.best {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Automatically Selected Node")
                        .font(.subheadline)
                    Spacer()
                    if best.sameISP {
                        matchBadge(Text("Same ISP"))
                    }
                    if best.sameProvince {
                        matchBadge(Text("Same Province"))
                    }
                    Text("\(best.latencyMs) ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(best.latencyMs < 100 ? .green : best.latencyMs < 300 ? .orange : .red)
                }
                // Full domain (the label alone abbreviated away the
                // actual node identity).
                Text(best.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                // The actual connect target: the IP this device resolved
                // for the node (what latency was measured against), plus
                // its ISP/region when known. Under a fake-IP VPN resolver
                // this is a virtual address from the reserved range.
                Text(verbatim: "IP: \(best.ip)\(best.isp.isEmpty ? "" : " · \(best.isp)")\(best.province.isEmpty ? "" : " · \(best.province)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        } else if !smart.isTesting {
            Text("No node selected yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack {
            Button {
                Task { await smart.warmUp(trigger: "manual re-test", force: true) }
            } label: {
                Label {
                    // Action row — accent text marks it tappable.
                    Text("Re-test Nodes")
                        .foregroundStyle(accent)
                } icon: {
                    SettingsIcon(symbol: "arrow.clockwise")
                }
            }
            .disabled(smart.isTesting)

            Spacer()

            if smart.isTesting {
                ProgressView()
            } else if let at = smart.lastTestAt {
                Text(at, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var smartConfigurationSection: some View {
        Section("Automatic CDN Configuration") {
            NavigationLink {
                CDNProviderPriorityView()
            } label: {
                Label {
                    Text("Provider Priority")
                } icon: {
                    SettingsIcon(symbol: "arrow.up.arrow.down")
                }
            }

            VStack(spacing: 6) {
                HStack {
                    Label {
                        Text("Probe Data Budget")
                    } icon: {
                        SettingsIcon(symbol: "chart.bar")
                    }
                    Spacer()
                    Text(verbatim: String(format: "%.1f MB", probeBudgetMB))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { probeBudgetMB },
                        set: { v in
                            // 0.5 MB steps.
                            probeBudgetMB = (v * 2).rounded() / 2
                            SmartCDNSelector.probeBudgetMB = probeBudgetMB
                        }
                    ),
                    in: 0.5 ... 8, step: 0.5
                )
                .tint(accent)
            }

            Toggle(isOn: Binding(
                get: { scaleProbeOnCellular },
                set: { on in
                    scaleProbeOnCellular = on
                    SmartCDNSelector.scaleProbeOnCellular = on
                }
            )) {
                Label {
                    Text("Scale Probe on Cellular")
                } icon: {
                    SettingsIcon(symbol: "antenna.radiowaves.left.and.right")
                }
            }
        }
    }

    private func statusRow(title: Text, value: String) -> some View {
        HStack {
            title.font(.subheadline)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    private func matchBadge(_ label: Text) -> some View {
        label
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.green.opacity(0.12))
            .foregroundStyle(.green)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func cdnRow(_ cdn: CDNService) -> some View {
        Button {
            selected = cdn
            CDNService.current = cdn
        } label: {
            HStack(spacing: 12) {
                // Radio-style selection, tinted by the global accent.
                Image(systemName: selected == cdn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected == cdn ? accent : Color(.tertiaryLabel))

                // Readable name leads; the technical domain drops to a
                // monospaced caption. Base/Backup URL have no fixed
                // host, so those rows are label-only.
                VStack(alignment: .leading, spacing: 2) {
                    Text(cdn.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let host = cdn.host {
                        Text(verbatim: host)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }

                Spacer()

                if let result = results[cdn] {
                    speedBadge(result)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func speedBadge(_ result: CDNTestResult) -> some View {
        let color: Color = if result.succeeded {
            result.speed >= 5 ? .green : result.speed >= 1 ? .orange : .red
        } else {
            .red
        }
        Text(result.displayText)
            .font(.caption2)
            .fontWeight(.medium)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func testAll() async {
        let quietToken = SmartCDNSelector.shared.beginMeasurementWindow()
        defer { SmartCDNSelector.shared.endMeasurementWindow(quietToken) }
        isTesting = true
        testProgress = 0
        testError = nil
        results = [:]

        let sampleURL: String
        do {
            sampleURL = try await CDNService.fetchSampleVideoURL()
        } catch {
            testError = error.localizedDescription
            isTesting = false
            return
        }

        let cdns = CDNService.publishableServices
        testTotal = cdns.count

        for cdn in cdns {
            let result = await CDNService.testDownloadSpeed(cdn, sampleURL: sampleURL)
            results[cdn] = result
            testProgress += 1
        }

        isTesting = false
    }
}

// MARK: - Provider identity

/// Brand tints for the provider marks. Deliberately NOT the accent theme:
/// these identify content (which cloud a node belongs to), not menu options.
extension CDNProvider {
    var tint: Color {
        switch self {
        case .alibaba: .orange
        case .tencent: .blue
        case .huawei: .red
        case .other: .gray
        case .overseas: .indigo
        }
    }

    /// One glyph per provider, so the mark does not depend on hue alone.
    ///
    /// All three mainland clouds shared `cloud.fill` and were told apart only
    /// by `tint`, putting the mark's whole identity in colour — it fails a
    /// red/green-deficient viewer, and the glyph carried nothing the coloured
    /// square did not. HIG § Color: "Avoid relying solely on color to
    /// differentiate between objects… you can use text labels or glyph shapes
    /// to identify objects or states." Two of the five are corrections rather
    /// than differentiation: `.overseas` was a globe centred on Asia, the
    /// region these nodes are NOT in, and `.other` was a shipping box, which
    /// reads as a download. The three mainland assignments are arbitrary among
    /// peers and cannot be otherwise — same kind of thing, no brand logos in
    /// SF Symbols — so they need only be distinct, legible at 13pt, and
    /// STABLE. Do not reshuffle them for taste.
    var symbol: String {
        switch self {
        case .alibaba: "square.stack.3d.up.fill"
        case .tencent: "server.rack"
        case .huawei: "antenna.radiowaves.left.and.right"
        case .other: "questionmark.folder.fill"
        case .overseas: "globe.americas.fill"
        }
    }
}

/// Small rounded-square brand mark, shared by the node list groups and the
/// Provider Priority screen.
struct CDNProviderMark: View {
    let provider: CDNProvider

    var body: some View {
        Image(systemName: provider.symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
                    .fill(provider.tint.gradient)
            )
    }
}
