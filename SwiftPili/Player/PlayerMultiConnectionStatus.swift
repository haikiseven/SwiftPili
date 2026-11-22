import SwiftUI

struct MultiConnectionDisplay: Equatable {
    enum State: String {
        case off = "Off"
        case experimentDisabled = "Experimental feature disabled"
        case unsupported = "Unavailable for this source"
        case processDisabled = "Disabled by playback configuration"
        case waitingWiFi = "Waiting for Wi-Fi"
        case checking = "Checking download status"
        case unavailable = "Unavailable for this video"
        case idle = "Standby"
        case downloading = "Downloading"
        case quiet = "Paused for CDN measurement"
        case parked = "Playback inactive"
        case suppressed = "Paused after memory pressure"
        case paused = "Playback paused"
        case coolingDown = "Nodes cooling down"
        case networkRestricted = "Network restricted"
    }
    var state: State = .off
    var activeRequests: Int?
    var concurrencyLimit = MultiConnectionPlanner.requestLimit()
    var activeHelperHosts: [String] = []
    var candidateHosts = 0
    var completedBytes: Int64 = 0
    var completedFragments = 0
    var stagedBytes: Int64 = 0
    var discardedBytes: Int64 = 0
    var completedPayloadRate: Double?

    var requestCountText: String {
        "\(activeRequests.map(String.init) ?? "—")/\(concurrencyLimit)"
    }

    struct Context {
        var savedOn = true
        var experimentAllowed = true
        var processEnabled = true
        var supported = true
        var pathAllowed = true
        var measuring = false
        var hasSource = true
        var playing = true

        var override: State? {
            if !experimentAllowed { return .experimentDisabled }
            if !hasSource { return savedOn ? .parked : .off }
            if !savedOn { return .off }
            if !processEnabled { return .processDisabled }
            if !supported { return .unsupported }
            if !pathAllowed { return .waitingWiFi }
            if measuring { return .quiet }
            return nil
        }
    }

    static func project(context: Context, telemetry: MultiConnectionTelemetry, rate: Double?) -> Self {
        guard context.hasSource, context.supported else {
            return Self(state: context.override ?? .unsupported, concurrencyLimit: telemetry.concurrencyLimit)
        }
        var result = Self(
            state: context.override ?? runtimeState(telemetry.state, context: context),
            activeRequests: telemetry.identity != nil ? telemetry.activeRequests
                : telemetry.state == .notConfigured ? 0 : nil,
            concurrencyLimit: telemetry.concurrencyLimit,
            activeHelperHosts: activeHosts(telemetry),
            candidateHosts: telemetry.candidateHosts,
            completedBytes: telemetry.completedBytes, completedFragments: telemetry.completedFragments,
            stagedBytes: telemetry.stagedBytes, discardedBytes: telemetry.discardedBytes
        )
        if result.state == .idle || result.state == .downloading { result.completedPayloadRate = rate }
        return result
    }

    private static func activeHosts(_ telemetry: MultiConnectionTelemetry) -> [String] {
        guard telemetry.identity != nil, telemetry.activeRequests > 0 else { return [] }
        switch telemetry.state {
        case .idle, .downloading, .quiet:
            return Array(Set(telemetry.activeHelperHosts.filter { host in
                host.contains(".") && host.contains(where: \.isLetter)
                    && host.unicodeScalars.allSatisfy { scalar in
                        scalar.isASCII
                            && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
                    }
            }).sorted().prefix(min(telemetry.concurrencyLimit, MultiConnectionPlanner.maximumConcurrentRequests)))
        default: return []
        }
    }

    private static func runtimeState(_ state: MultiConnectionTelemetry.State, context: Context) -> State {
        switch state {
        case .unsupported: .unsupported
        case .pending: .checking
        // No prefetcher for this load. "Applies to the next video" is a toast
        // when the switch turns on, never a persistent status (user rule).
        case .notConfigured, .unavailable: .unavailable
        case .idle: context.playing ? .idle : .paused
        case .downloading: context.playing ? .downloading : .paused
        case .quiet: .quiet
        case .parked: .parked
        case .suppressed: .suppressed
        case .coolingDown: .coolingDown
        case .networkRestricted: .networkRestricted
        }
    }
}

extension PlayerViewModel {
    private static let multiConnectionBenchmarkEnabled =
        ProcessInfo.processInfo.environment["PATHA_MULTI_CONNECTION_BENCHMARK"] == "1"

    func resetMultiConnectionRate() {
        multiConnectionPayloadSampler.reset()
        multiConnectionRateResetAt = ProcessInfo.processInfo.systemUptime
    }

    func resetMultiConnectionDisplay() {
        multiConnectionAdmissionAttempted = false
        resetMultiConnectionRate()
        multiConnectionTelemetry = MultiConnectionTelemetry(state: .pending)
        publishMultiConnectionDisplay(rate: nil)
    }

    func sampleMultiConnectionDisplay() {
        // Reading is synchronous; refresh starts one fenced actor query and returns.
        let value = backend.dynamicInfo?.multiConnection ?? .unsupported
        if Self.multiConnectionBenchmarkEnabled, ExperimentalSettingsPolicy.isAllowed(.multiConnection) {
            PlayerLog.log("[MultiConnectionBench] identity=\(value.identity?.uuidString ?? "none") " +
                          "epoch=\(value.epoch) sampleUptime=\(String(format: "%.6f", value.observedAt)) " +
                          "activeRequests=\(value.activeRequests) limit=\(value.concurrencyLimit) " +
                          "completedBytes=\(value.completedBytes) completedFragments=\(value.completedFragments) " +
                          "discardedBytes=\(value.discardedBytes) state=\(value.state)")
        }
        multiConnectionTelemetry = value
        let eligible = MultiConnectionFeatureGate.isEnabled() && mode.usesOnlineVODServices
            && backendKind == .demandPaced
            && Self.multiConnectionNetworkPath.admits(cellularEnabled: MultiConnectionFeatureGate.cellularEnabled())
            && !multiConnectionQuietWindows.isQuiet && isPlaying && currentURL != nil
        let rate: Double?
        if eligible, value.observedAt > multiConnectionRateResetAt {
            rate = multiConnectionPayloadSampler.sample(value)
        } else {
            resetMultiConnectionRate()
            rate = nil
        }
        publishMultiConnectionDisplay(rate: rate)
        backend.refreshMultiConnectionTelemetry()
    }

    func publishMultiConnectionDisplay(rate: Double?) {
        let context = MultiConnectionDisplay.Context(
            savedOn: UserDefaults.standard.bool(forKey: MultiConnectionFeatureGate.defaultsKey),
            experimentAllowed: ExperimentalSettingsPolicy.isAllowed(.multiConnection),
            processEnabled: MultiConnectionFeatureGate.processEnabled(),
            supported: mode.usesOnlineVODServices && backendKind == .demandPaced,
            pathAllowed: Self.multiConnectionNetworkPath.admits(
                cellularEnabled: MultiConnectionFeatureGate.cellularEnabled()
            ),
            measuring: multiConnectionQuietWindows.isQuiet,
            hasSource: currentURL != nil, playing: isPlaying
        )
        let value = MultiConnectionDisplay.project(context: context, telemetry: multiConnectionTelemetry, rate: rate)
        if multiConnectionDisplay != value { multiConnectionDisplay = value }
    }
}

/// Actual child bodies own observation of helper status, not their menu/player parents.
struct PlayerMultiConnectionMenu: View {
    let player: PlayerViewModel
    @AppStorage(MultiConnectionFeatureGate.defaultsKey) private var enabled = false

    /// Commit both preference and synchronous quiet gate in the native Menu action.
    func preferenceBinding(access: ExperimentalAccessReceipt?) -> Binding<Bool> {
        let owner = player.currentOwnerLease
        let generation = player.loadGeneration
        return Binding(get: { enabled }, set: { value in
            guard let access, ExperimentalSettingsStore.shared.isCurrentAccess(access),
                  owner == player.currentOwnerLease, generation == player.loadGeneration else { return }
            enabled = value
            player.refreshMultiConnectionQuiet()
            // A prefetcher is built per load: switching on resumes one this load
            // already admitted; otherwise it applies from the next video.
            if value, !player.multiConnectionAdmissionAttempted, player.backendKind == .demandPaced {
                player.showNotice(String(localized: "Applies to the next video"))
            }
        })
    }

    var body: some View {
        let status = player.multiConnectionDisplay
        let access = ExperimentalSettingsStore.shared.captureAccess(.multiConnection)
        Menu {
            Toggle("Multi-connection", isOn: preferenceBinding(access: access))
                .disabled(!ExperimentalSettingsStore.shared.isAllowed(.multiConnection))
            Text(LocalizedStringKey(status.state.rawValue))
            Menu("Download details") {
                Text("Concurrent requests: \(status.requestCountText)")
                Text("Candidate hosts: \(status.candidateHosts)")
                Text("Completed download data: \(Self.bytes(status.completedBytes))")
                Text("Completed fragments: \(status.completedFragments)")
                Text("Staged data: \(Self.bytes(status.stagedBytes))")
                Text("Discarded staged data: \(Self.bytes(status.discardedBytes))")
                if let rate = status.completedPayloadRate {
                    Text("Helper download: \(Self.rate(rate))")
                }
                ForEach(status.activeHelperHosts, id: \.self) { host in
                    Text("Active download node: \(host)")
                }
                Text("Speed counts completed helper downloads, excluding data still transferring.")
            }
        } label: {
            Label {
                Text("Multi-connection") + Text(": ") + Text(LocalizedStringKey(status.state.rawValue))
            } icon: { Image(systemName: "network") }
        }
    }

    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1024 * 1024 { return String(format: "%.1f MB/s", value / (1024 * 1024)) }
        return String(format: "%.1f KB/s", value / 1024)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
