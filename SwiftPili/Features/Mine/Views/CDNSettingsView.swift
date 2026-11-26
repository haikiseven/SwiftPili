import SwiftUI

struct CDNSettingsView: View {
    @AppMotion private var motion
    private let experiments = ExperimentalSettingsStore.shared
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

    private let defaultCDNs: [CDNService] = [.baseUrl, .backupUrl]

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

            ForEach(defaultCDNs) { cdn in defaultCDNRow(cdn) }

            ForEach(CDNProvider.allCases) { provider in
                providerRow(provider)
            }
        } header: {
            if smartEnabled {
                Text("Manual CDN Fallback")
            } else {
                Text("Manual CDN Selection")
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: CDNProvider) -> some View {
        let isSelected = selected.provider == provider
        Button {
            let target = provider.primaryService
            selected = target
            CDNService.current = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? accent : Color(.tertiaryLabel))

                CDNProviderMark(provider: provider)

                Text(provider.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                if let result = results[provider.primaryService] {
                    speedBadge(result)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
                value: [client.ip, client.isp, client.province]
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
            )
        }

        if smart.fakeIPDNSDetected || smart.client?.isPublicAddress == false {
            Label {
                Text("Fake-IP DNS server detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
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
                Text(verbatim: CDNHostDisplay.formatted(best.host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "IP: \(best.ip)\(best.isp.isEmpty ? "" : " / \(best.isp)")\(best.province.isEmpty ? "" : " / \(best.province)")")
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

            Toggle(isOn: Binding(
                get: { experiments.http2ProbeEnabled },
                set: { _ = experiments.setHTTP2ProbeEnabled($0) }
            )) {
                Label {
                    Text("HTTP/2 Probe")
                } icon: {
                    SettingsIcon(symbol: "bolt.horizontal")
                }
            }
            .disabled(experiments.storageError != nil)
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
    private func defaultCDNRow(_ cdn: CDNService) -> some View {
        Button {
            selected = cdn
            CDNService.current = cdn
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == cdn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected == cdn ? accent : Color(.tertiaryLabel))

                Text(cdn.label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

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

        let cdns = defaultCDNs + CDNProvider.allCases.map(\.primaryService)
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

extension CDNProvider {
    var tint: Color {
        switch self {
        case .alibaba: .orange
        case .tencent: .blue
        case .huawei: .red
        case .baidu: .cyan
        case .other: .gray
        case .overseas: .indigo
        }
    }

    var symbol: String {
        switch self {
        case .alibaba: "square.stack.3d.up.fill"
        case .tencent: "server.rack"
        case .huawei: "antenna.radiowaves.left.and.right"
        case .baidu: "cloud.fill"
        case .other: "square.grid.2x2.fill"
        case .overseas: "globe.americas.fill"
        }
    }
}

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
