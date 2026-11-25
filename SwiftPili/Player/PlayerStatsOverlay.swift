import SwiftUI

struct PlayerStatsDisplaySnapshot {
    let stats: PlaybackStats
    let status: MultiConnectionDisplay
    let mode: PlayerMode
    let enabled: Bool
    let diagnostics: Bool
    let fullscreen: Bool
    let bufferedAhead: TimeInterval?

    init(
        stats: PlaybackStats, status: MultiConnectionDisplay, mode: PlayerMode,
        enabled: Bool, diagnostics: Bool, fullscreen: Bool, bufferedAhead: TimeInterval? = nil
    ) {
        self.stats = stats
        self.status = status
        self.mode = mode
        self.enabled = enabled
        self.diagnostics = diagnostics
        self.fullscreen = fullscreen
        self.bufferedAhead = bufferedAhead
    }
}

struct PlayerStatsOverlay: View {
    let player: PlayerViewModel
    let isCurrentOwner: Bool
    let gestureDisplay: PlayerGestureDisplay
    let chromeInsets: PlayerChromeInsets
    let snapshot: PlayerStatsDisplaySnapshot?
    let onPanelBounds: ((CGRect) -> Void)?
    @AppStorage("debug_logging_enabled") private var diagnosticsVisible = false
    @AppStorage(MultiConnectionFeatureGate.defaultsKey) private var multiConnectionEnabled = false

    init(
        player: PlayerViewModel, isCurrentOwner: Bool, gestureDisplay: PlayerGestureDisplay,
        chromeInsets: PlayerChromeInsets, snapshot: PlayerStatsDisplaySnapshot? = nil,
        onPanelBounds: ((CGRect) -> Void)? = nil
    ) {
        self.player = player
        self.isCurrentOwner = isCurrentOwner
        self.gestureDisplay = gestureDisplay
        self.chromeInsets = chromeInsets
        self.snapshot = snapshot
        self.onPanelBounds = onPanelBounds
    }

    private var statistics: PlaybackStats { snapshot?.stats ?? player.stats }
    private var showsDiagnostics: Bool { snapshot?.diagnostics ?? diagnosticsVisible }
    private var fullscreen: Bool { snapshot?.fullscreen ?? player.isFullscreen }

    var body: some View {
        let statistics = self.statistics
        let fullscreen = self.fullscreen
        return GeometryReader { geometry in
            measuredPanel {
                if geometry.size.height < 260 {
                    compactPanel(statistics: statistics)
                } else {
                    statsPanel(statistics: statistics)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, (fullscreen ? 0 : 8) + chromeInsets.horizontal)
            .padding(.top, 8 + chromeInsets.top)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
        .coordinateSpace(name: "PlayerStatsViewport")
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func measuredPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let onPanelBounds {
            content()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PlayerStatsPanelBounds.self,
                            value: proxy.frame(in: .global)
                        )
                    }
                }
                .onPreferenceChange(PlayerStatsPanelBounds.self, perform: onPanelBounds)
        } else {
            content()
        }
    }

    private func statsPanel(statistics: PlaybackStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            videoGroup(statistics: statistics, labelWidth: 74)
            audioGroup(statistics: statistics, labelWidth: 74)
            enhancementGroup(statistics: statistics, labelWidth: 74)
            networkGroup(labelWidth: 74)
            performanceGroup(statistics: statistics, labelWidth: 74)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: AppRadius.thumbnail))
    }

    private func compactPanel(statistics: PlaybackStats) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                videoGroup(statistics: statistics, labelWidth: 58)
                audioGroup(statistics: statistics, labelWidth: 58)
                enhancementGroup(statistics: statistics, labelWidth: 58)
            }
            VStack(alignment: .leading, spacing: 4) {
                networkGroup(labelWidth: 58)
                performanceGroup(statistics: statistics, labelWidth: 58)
            }
        }
        .font(.system(size: 8, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: AppRadius.thumbnail))
    }

    private func videoGroup(statistics: PlaybackStats, labelWidth: CGFloat) -> some View {
        let hasEnhancement = statistics.videoEnhancement != nil
        return statsGroup("Video") {
            if !statistics.qualityDesc.isEmpty {
                statsRow("Quality", statistics.qualityDesc, labelWidth: labelWidth)
            }
            statsRow(hasEnhancement ? "Source Res" : "Resolution", statistics.resolution, labelWidth: labelWidth)
            statsRow("Codec", statistics.codec, labelWidth: labelWidth)
            statsRow("Decoder", statistics.decoderType, labelWidth: labelWidth)
            if statistics.bitrate > 0 {
                statsRow("Video Bitrate", "\(statistics.bitrate / 1000) kbps", labelWidth: labelWidth)
            }
            if statistics.hasSeparateAudio {
                statsRow("Stream", String(localized: "DASH (split A/V)"), labelWidth: labelWidth)
            }
        }
    }

    @ViewBuilder
    private func audioGroup(statistics: PlaybackStats, labelWidth: CGFloat) -> some View {
        if !statistics.audioCodec.isEmpty {
            statsGroup("Audio") {
                statsRow("Track", statistics.audioTrackName, labelWidth: labelWidth)
                let bitrateText = statistics.audioBitrate > 0 ? "\(statistics.audioBitrate / 1000) kbps" : "—"
                statsRow("Bitrate", bitrateText, labelWidth: labelWidth)
            }
        }
    }

    @ViewBuilder
    private func enhancementGroup(statistics: PlaybackStats, labelWidth: CGFloat) -> some View {
        if let enhancement = statistics.videoEnhancement {
            statsGroup("Enhancement") {
                if let modeText = enhancementModeText(enhancement) {
                    statsRow("Mode", modeText, labelWidth: labelWidth)
                }
                statsRow("Status", enhancementStatusText(enhancement), labelWidth: labelWidth)
                if enhancement.outputWidth > 0, enhancement.outputHeight > 0 {
                    statsRow(
                        "Output Res",
                        "\(enhancement.outputWidth)×\(enhancement.outputHeight)",
                        labelWidth: labelWidth
                    )
                }
                if enhancement.outputFPS > 0.5 {
                    statsRow("Output FPS", String(format: "%.1f", enhancement.outputFPS), labelWidth: labelWidth)
                }
                if enhancement.smoothedProcessingMs > 0.01 {
                    statsRow(
                        "Latency",
                        String(format: "%.1f ms", enhancement.smoothedProcessingMs),
                        labelWidth: labelWidth
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func networkGroup(labelWidth: CGFloat) -> some View {
        let showsReceiveRate = showsNetworkReceiveRate
        if showsReceiveRate || hasNetworkRows {
            statsGroup("Network") {
                PlayerCDNSourceRows(
                    player: player, snapshot: snapshot, labelWidth: labelWidth,
                    showsReceiveRate: showsReceiveRate
                )
            }
        }
    }

    private func performanceGroup(statistics: PlaybackStats, labelWidth: CGFloat) -> some View {
        let hasEnhancement = statistics.videoEnhancement != nil
        return statsGroup("Performance") {
            statsRow(
                hasEnhancement ? "Source FPS" : "FPS",
                String(format: "%.1f", statistics.fps),
                labelWidth: labelWidth
            )
            statsRow("Dropped", droppedText(statistics), labelWidth: labelWidth)
            PlayerStatsBufferRow(
                player: player, isCurrentOwner: isCurrentOwner, gestureDisplay: gestureDisplay,
                snapshot: snapshot, deliveryRunway: statistics.bufferHealth, labelWidth: labelWidth
            )
            if showsDiagnostics {
                if !statistics.lastStartup.isEmpty {
                    statsRow("TTFF", statistics.lastStartup, labelWidth: labelWidth)
                }
                if !statistics.lastSeek.isEmpty {
                    statsRow("Last Seek", statistics.lastSeek, labelWidth: labelWidth)
                }
            }
        }
    }

    private var showsNetworkReceiveRate: Bool {
        if let snapshot { return snapshot.mode != .offline }
        guard player.mode != .offline else { return false }
        let scheme = player.currentURL?.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    private var hasNetworkRows: Bool {
        let mode = snapshot?.mode ?? player.mode
        if mode == .offline { return true }
        let experimentAllowed = ExperimentalSettingsStore.shared.isAllowed(.multiConnection)
        let mcEnabled = experimentAllowed
            && (snapshot?.enabled ?? multiConnectionEnabled)
            && mode.usesOnlineVODServices
        if mcEnabled { return true }
        return !statistics.cdnSetting.isEmpty
            || !statistics.videoHost.isEmpty
            || (statistics.hasSeparateAudio && !statistics.audioHost.isEmpty)
    }

    private func statsGroup<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    private func enhancementModeText(_ enhancement: VideoEnhancementTelemetry) -> String? {
        if enhancement.isActive {
            return activeEnhancementModeText(enhancement)
        }
        guard snapshot == nil else { return nil }
        return requestedEnhancementModeText(player.effectiveVideoEnhancementConfiguration)
    }

    private func activeEnhancementModeText(_ enhancement: VideoEnhancementTelemetry) -> String? {
        func withShare(_ name: String, _ share: Double?) -> String {
            guard let share, share < 0.995 else { return name }
            return "\(name) \(Int((share * 100).rounded()))%"
        }
        let parts = enhancement.activeModeLabel.split(separator: "+").map { segment -> String in
            let token = segment.trimmingCharacters(in: .whitespaces)
            switch token {
            case "VT ML SR": return withShare(String(localized: "VideoToolbox ML"), enhancement.superResolutionShare)
            case "MetalFX SR": return withShare("MetalFX", enhancement.superResolutionShare)
            case "VT FI", "Vision FI":
                return withShare(String(localized: "Frame Interpolation"), enhancement.interpolationShare)
            default: return token
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " + ")
    }

    private func requestedEnhancementModeText(_ config: VideoEnhancementConfiguration) -> String? {
        guard config.isRequested else { return nil }
        var parts: [String] = []
        switch config.superResolutionMode {
        case .off: break
        case .metalFXSpatial: parts.append("MetalFX")
        }
        if config.frameInterpolationEnabled {
            parts.append(String(localized: "Frame Interpolation"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " + ")
    }

    private func enhancementStatusText(_ enhancement: VideoEnhancementTelemetry) -> String {
        if enhancement.isActive {
            var text = String(localized: "Active")
            if let partial = enhancement.partialReason {
                text += " · " + VideoEnhancementBypassDisplay.shortLabel(for: partial)
            }
            if let note = enhancement.degradationNote {
                text += " " + String(format: String(localized: "(Reduced · %@)"),
                                     VideoEnhancementBypassDisplay.shortLabel(for: note))
            }
            return text
        }
        if let reason = enhancement.bypassReason {
            return VideoEnhancementBypassDisplay.pausedStatsLabel(for: reason)
        }
        return String(localized: "Standby")
    }

    private func droppedText(_ statistics: PlaybackStats) -> String {
        statistics.dropRate > 0.05
            ? "\(statistics.droppedFrames) (+\(String(format: "%.1f", statistics.dropRate))/s)"
            : "\(statistics.droppedFrames)"
    }

}

private struct PlayerStatsBufferRow: View {
    let player: PlayerViewModel
    let isCurrentOwner: Bool
    let gestureDisplay: PlayerGestureDisplay
    let snapshot: PlayerStatsDisplaySnapshot?
    let deliveryRunway: TimeInterval?
    let labelWidth: CGFloat

    private var seconds: TimeInterval? {
        if let snapshot {
            return snapshot.mode.isSeekable ? snapshot.bufferedAhead : snapshot.stats.bufferHealth
        }
        guard isCurrentOwner else { return nil }
        return player.mode.isSeekable ? player.displayedBufferAhead(gestureDisplay: gestureDisplay) : deliveryRunway
    }

    var body: some View {
        if let seconds {
            statsRow("Buffer", String(format: "%.1fs", seconds), labelWidth: labelWidth)
        }
    }
}

@MainActor
private func statsRow(
    _ label: LocalizedStringKey,
    _ value: String,
    labelWidth: CGFloat
) -> some View {
    HStack(alignment: .top, spacing: 4) {
        Text(label).foregroundStyle(.white.opacity(0.6))
            .frame(width: labelWidth, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
        Text(value).foregroundStyle(.white)
    }
}

private struct PlayerStatsPanelBounds: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

struct PlayerCDNSourceDisplay: Equatable {
    var cdnSetting: String
    var primaryVideoHost: String
    var primaryAudioHost: String
    var multiConnection: MultiConnectionDisplay?
    var helperHosts: [String]

    var helperSummary: String {
        let groups = Dictionary(grouping: helperHosts) { host in
            CDNService.allCases.first(where: { $0.host == host })?.provider ?? .other
        }
        return CDNProvider.allCases.compactMap { provider in
            guard let count = groups[provider]?.count else { return nil }
            let label: String
            switch provider {
            case .alibaba: label = String(localized: "Ali")
            case .tencent: label = String(localized: "TX")
            case .huawei: label = String(localized: "HW")
            case .other: label = String(localized: "Other")
            case .overseas: label = String(localized: "Overseas")
            }
            return "\(label)×\(count)"
        }.joined(separator: " ")
    }

    static func compactAuthority(_ authority: String) -> String {
        if let service = CDNService.allCases.first(where: { $0.host == authority }) { return service.label }
        let domain = ".bilivideo.com"
        guard authority.hasSuffix(domain) else { return authority }
        let node = String(authority.dropLast(domain.count))
        return node.hasPrefix("upos-") ? String(node.dropFirst(5)) : node
    }

    init(stats: PlaybackStats, status: MultiConnectionDisplay, enabled: Bool, onlineVOD: Bool) {
        cdnSetting = stats.cdnSetting
        primaryVideoHost = stats.videoHost
        primaryAudioHost = stats.hasSeparateAudio ? stats.audioHost : ""
        multiConnection = enabled && onlineVOD ? status : nil
        helperHosts = enabled && onlineVOD ? status.activeHelperHosts : []
    }
}

struct PlayerCDNSourceRows: View {
    let player: PlayerViewModel
    let snapshot: PlayerStatsDisplaySnapshot?
    var labelWidth: CGFloat = 70
    let showsReceiveRate: Bool

    init(
        player: PlayerViewModel, snapshot: PlayerStatsDisplaySnapshot? = nil, labelWidth: CGFloat = 70,
        showsReceiveRate: Bool
    ) {
        self.player = player
        self.snapshot = snapshot
        self.labelWidth = labelWidth
        self.showsReceiveRate = showsReceiveRate
    }

    @AppStorage(MultiConnectionFeatureGate.defaultsKey) private var enabled = false

    var body: some View {
        let stats = snapshot?.stats ?? player.stats
        let mode = snapshot?.mode ?? player.mode
        let experimentAllowed = ExperimentalSettingsStore.shared.isAllowed(.multiConnection)
        let source = PlayerCDNSourceDisplay(
            stats: stats, status: snapshot?.status ?? player.multiConnectionDisplay,
            enabled: experimentAllowed && (snapshot?.enabled ?? enabled),
            onlineVOD: mode.usesOnlineVODServices
        )
        if showsReceiveRate { row("Total Receive") { Text(verbatim: stats.networkSpeedText) } }
        if mode == .offline {
            row("Source") { Text("Downloaded") }
        } else if let status = source.multiConnection {
            row("CDN") { Text("Multi-connection") }
            row("Helper State") { Text(LocalizedStringKey(shortState(status.state))) }
            row("Concurrency") { Text(verbatim: status.requestCountText) }
            row("Helper Rate") {
                Text(verbatim: status.completedPayloadRate.map(PlayerMultiConnectionMenu.rate) ?? "—")
            }
            if !source.primaryVideoHost.isEmpty, source.primaryVideoHost == source.primaryAudioHost {
                row("Main A/V") { host(source.primaryVideoHost) }
            } else {
                if !source.primaryVideoHost.isEmpty { row("Main Video") { host(source.primaryVideoHost) } }
                if !source.primaryAudioHost.isEmpty { row("Main Audio") { host(source.primaryAudioHost) } }
            }
            if !source.helperHosts.isEmpty {
                row("Helpers") { Text(verbatim: source.helperSummary).lineLimit(1) }
                    .accessibilityLabel(Text("Helpers"))
                    .accessibilityValue(Text(verbatim: source.helperHosts.joined(separator: ", ")))
            }
        } else {
            if !source.cdnSetting.isEmpty { row("CDN") { Text(source.cdnSetting) } }
            if !source.primaryVideoHost.isEmpty { row("Video Host") { Text(source.primaryVideoHost) } }
            if !source.primaryAudioHost.isEmpty { row("Audio Host") { Text(source.primaryAudioHost) } }
        }
    }

    private func host(_ authority: String) -> some View {
        Text(PlayerCDNSourceDisplay.compactAuthority(authority)).lineLimit(1).truncationMode(.middle)
            .accessibilityLabel(Text(verbatim: authority))
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.8)
            content().foregroundStyle(.white)
        }
    }

    private func shortState(_ state: MultiConnectionDisplay.State) -> String {
        switch state {
        case .experimentDisabled, .processDisabled, .unsupported, .unavailable: "Unavailable"
        case .checking: "Checking"
        case .quiet: "CDN measurement"
        case .suppressed: "Memory pressure"
        case .parked: "Inactive"
        case .coolingDown: "Cooling down"
        case .networkRestricted: "Network restricted"
        default: state.rawValue
        }
    }
}
