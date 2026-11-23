import SwiftUI
import UIKit

struct PlayerPlaybackOptionsMenu: View {
    let player: PlayerViewModel
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    private let experiments = ExperimentalSettingsStore.shared
    @State private var enhancementPresentation: EnhancementPresentation?

    private struct EnhancementScope: Equatable {
        let screenLease: PlayerOwnerLease
        let receipt: PlayerPresentationReceipt?
        let hostIdentity: UUID?
        let surfaceLease: PlayerSurfaceLease?
        let source: DecoderRecoveryAdmission.Source?
        let loadGeneration: Int
        let backend: ObjectIdentifier
        let backendGeneration: UInt64
        let access: ExperimentalAccessReceipt
    }

    private struct EnhancementPresentation: Identifiable {
        let id = UUID()
        let scope: EnhancementScope
    }

    var body: some View {
        let renderedScope = currentEnhancementScope
        Group {
            if player.mode.supportsPlaybackRate {
                playbackMenu(onEnhancement: renderedScope.map { scope in
                    { openEnhancement(for: scope) }
                })
            }
        }
        .sheet(item: $enhancementPresentation) { request in
            PlayerVideoEnhancementSheet(
                player: player,
                canEdit: { canEditEnhancement(request) },
                onClose: { closeEnhancement(request) }
            )
        }
        .onChange(of: enhancementPresentation.map(canEditEnhancement), initial: true) { _, _ in
            if let request = enhancementPresentation, !canEditEnhancement(request) {
                closeEnhancement(request)
            }
        }
    }

    private var currentEnhancementScope: EnhancementScope? {
        guard let screenLease, player.isCurrentOwner(screenLease),
              player.isVideoEnhancementEligibleForStream,
              let access = experiments.captureAccess(.videoEnhancement),
              player.isFullscreen == (presentationReceipt != nil) else { return nil }
        if let presentationReceipt {
            guard let fullscreenHostIdentity,
                  presentationReceipt.context.ownerLease == screenLease,
                  player.isCurrentPresentationReceipt(presentationReceipt, hostIdentity: fullscreenHostIdentity)
            else { return nil }
        }
        let backend = player.backend
        return EnhancementScope(
            screenLease: screenLease, receipt: presentationReceipt, hostIdentity: fullscreenHostIdentity,
            surfaceLease: player.activeSurfaceLease, source: player.decoderRecoverySource(),
            loadGeneration: player.loadGeneration, backend: ObjectIdentifier(backend),
            backendGeneration: backend.runtimeGeneration, access: access
        )
    }

    private func openEnhancement(for scope: EnhancementScope) {
        guard enhancementPresentation == nil, currentEnhancementScope == scope,
              experiments.isCurrentAccess(scope.access) else { return }
        enhancementPresentation = EnhancementPresentation(scope: scope)
    }

    private func canEditEnhancement(_ request: EnhancementPresentation) -> Bool {
        enhancementPresentation?.id == request.id && currentEnhancementScope == request.scope
            && experiments.isCurrentAccess(request.scope.access)
    }

    private func closeEnhancement(_ request: EnhancementPresentation) {
        if enhancementPresentation?.id == request.id { enhancementPresentation = nil }
    }

    private func playbackMenu(onEnhancement: (() -> Void)?) -> some View {
        Menu {
            if player.mode.usesOnlineVODServices, !player.availableQualities.isEmpty {
                Menu {
                    ForEach(player.availableQualities, id: \.id) { quality in
                        Button { Task { await player.switchQuality(quality.id) } } label: {
                            HStack {
                                Text(quality.desc)
                                if quality.id == player.currentQuality {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Resolution", systemImage: "rectangle.on.rectangle")
                }
            }

            if player.mode.usesOnlineVODServices,
               experiments.isAllowed(.multiConnection) {
                PlayerMultiConnectionMenu(player: player)
            }

            if player.mode.usesOnlineVODServices, player.availableAudioTiers.count > 1 {
                Menu {
                    ForEach(player.availableAudioTiers, id: \.self) { tier in
                        Button {
                            Task { await player.switchAudioQuality(tier) }
                        } label: {
                            HStack {
                                Text(tier.label)
                                if tier == player.playingAudioTier {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Audio Quality", systemImage: "waveform")
                }
            }

            if player.mode == .offline {
                playbackRateOptions
            } else {
                Menu {
                    playbackRateOptions
                } label: {
                    Label("Speed", systemImage: "speedometer")
                }
            }

            if player.mode.usesOnlineVODServices, player.availableCodecs.count > 1 {
                codecMenu
            }

            if experiments.isAllowed(.videoEnhancement) {
                PlayerVideoEnhancementMenuItems(player: player, onOpen: onEnhancement)
            }
        } label: {
            playbackMenuLabel
        }
    }

    private var codecMenu: some View {
        let active = VideoCodecPreference.from(codecs: player.activeStreamCodec)
        return Menu {
            ForEach(player.availableCodecs, id: \.self) { pref in
                Button { Task { await player.switchCodec(pref) } } label: {
                    HStack {
                        Text(pref.label)
                        if pref == active {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Codec", systemImage: "cpu")
        }
    }

    private var playbackMenuLabel: some View {
        HStack(spacing: 4) {
            if player.videoEnhancementControlStatus.isActive {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel(Text("Enhanced"))
            }
            if player.mode.usesOnlineVODServices, !player.availableQualities.isEmpty {
                Text(PlayerViewModel.qualityMap[player.currentQuality] ?? "\(player.currentQuality)")
                    .lineLimit(1)
            } else if player.mode == .offline {
                Image(systemName: "speedometer")
                Text("\(player.playbackRate, specifier: "%.2g")x")
                    .lineLimit(1)
            } else {
                Image(systemName: "slider.horizontal.3")
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .fixedSize(horizontal: true, vertical: false)
        .playerChromeCapsule()
    }

    @ViewBuilder
    private var playbackRateOptions: some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
            Button { player.setRate(Float(rate), flushPipeline: true) } label: {
                HStack {
                    Text("\(rate, specifier: "%.2g")x")
                    if Float(rate) == player.playbackRate {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
}

private struct PlayerVideoEnhancementMenuItems: View {
    let player: PlayerViewModel
    let onOpen: (() -> Void)?

    var body: some View {
        let unavailableReason = player.videoEnhancementUnavailableDisplayReason
        Divider()
        Button(action: onOpen ?? {}) {
            Label {
                if let unavailableReason {
                    Text("Video Enhancement") + Text(verbatim: " · \(unavailableReason)")
                } else {
                    menuSummaryText
                }
            } icon: {
                Image(systemName: "sparkles.tv")
            }
        }
        .disabled(unavailableReason != nil || onOpen == nil)
        .accessibilityIdentifier("player.videoEnhancement")
    }

    private var menuSummaryText: Text {
        let title = Text("Video Enhancement") + Text(verbatim: "…")
        if player.videoSuperResolutionMode == .off, !player.videoFrameInterpolationEnabled {
            return title
        }
        if player.videoEnhancementControlStatus.bypassReason != nil {
            return title + Text(verbatim: " · ") + Text("Paused")
        }
        var parts: [String] = []
        switch player.videoSuperResolutionMode {
        case .off:
            break
        case .videoToolboxML:
            parts.append(player.videoSuperResolutionMode.menuLabel)
        case .metalFXSpatial:
            if let shortEdge = player.videoSuperResolutionTargetResolution.shortEdge {
                parts.append("\(player.videoSuperResolutionMode.menuLabel) \(shortEdge)p")
            } else {
                parts.append(player.videoSuperResolutionMode.menuLabel)
            }
        }
        if player.videoFrameInterpolationEnabled {
            if let fps = player.videoInterpolationRate.targetFPS {
                parts.append("\(String(localized: "FRC")) \(fps)fps")
            } else {
                parts.append(String(localized: "FRC"))
            }
        }
        return title + Text(verbatim: " · \(parts.joined(separator: " + "))")
    }
}

enum DetailDanmakuEntryPolicy {
    static func chromeShowsToggle(usesOnlineVODServices: Bool) -> Bool {
        usesOnlineVODServices
    }

    static func chromeShowsSettings(
        usesOnlineVODServices: Bool,
        danmakuEnabled: Bool,
        isFullscreen: Bool
    ) -> Bool {
        usesOnlineVODServices && danmakuEnabled && isFullscreen
    }

    static func chromeShowsSendEntry(
        usesOnlineVODServices: Bool,
        danmakuEnabled: Bool,
        isLoggedIn: Bool,
        isFullscreen: Bool
    ) -> Bool {
        usesOnlineVODServices && danmakuEnabled && isLoggedIn && isFullscreen
    }

    static func chromeShowsLoginToSend(
        usesOnlineVODServices: Bool,
        danmakuEnabled: Bool,
        isLoggedIn: Bool,
        isFullscreen: Bool
    ) -> Bool {
        usesOnlineVODServices && danmakuEnabled && !isLoggedIn && isFullscreen
    }
}

extension View {
    func danmakuToggleAccessibility(isOn: Bool) -> some View {
        accessibilityLabel(Text("Danmaku"))
            .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

struct PlayerOptionsMenu: View {
    let player: PlayerViewModel
    var showsAnimeOptions = false
    var onDownload: (() -> Void)?
    var onReport: (() -> Void)?
    var onDanmakuSettings: (() -> Void)?
    var onEqualizer: (() -> Void)?
    let actionAdmission: () -> Bool
    var isPlayerChrome = false
    @State private var resumeOn = PlayerPlaybackPreferences.resumePlayback
    @State private var skipOn = PlayerPlaybackPreferences.animeSkipIntroOutro

    var body: some View {
        Menu {
            if onDownload != nil || onReport != nil {
                if let onDownload {
                    Button {
                        guard actionAdmission() else { return }
                        onDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                if let onReport {
                    Button(role: .destructive) {
                        guard actionAdmission() else { return }
                        onReport()
                    } label: {
                        Label("Report Video", systemImage: "exclamationmark.triangle")
                    }
                }
                Divider()
            }
            if let onDanmakuSettings {
                Button(action: onDanmakuSettings) {
                    Label("Danmaku Settings", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("player.danmakuSettings")
            }
            if let onEqualizer {
                Button(action: onEqualizer) {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
                .accessibilityIdentifier("player.equalizer")
            }
            Toggle(isOn: Binding(
                get: { player.showStats },
                set: {
                    guard actionAdmission() else { return }
                    player.showStats = $0
                }
            )) {
                Label("Playback Info", systemImage: "info.circle")
            }
            Menu {
                ForEach(VideoScaleMode.allCases) { mode in
                    Button {
                        guard actionAdmission() else { return }
                        player.scaleMode = mode
                    } label: {
                        HStack {
                            Text(mode.label)
                            if mode == player.scaleMode { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Aspect Mode", systemImage: "aspectratio")
            }
            if player.mode.usesOnlineVODServices {
                Divider()
                Toggle(isOn: Binding(
                    get: { resumeOn },
                    set: {
                        guard actionAdmission() else { return }
                        resumeOn = $0
                        PlayerPlaybackPreferences.resumePlayback = $0
                        PlayerLog.log("[PlayerOptions] resume last position → \($0 ? "ON" : "OFF")")
                    }
                )) {
                    Label("Resume Last Position", systemImage: "clock.arrow.circlepath")
                }
            }
            if !player.mode.supportsPlaybackRate,
               ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement) {
                PlayerVideoEnhancementMenuItems(player: player, onOpen: nil)
            }
            if showsAnimeOptions {
                Toggle(isOn: Binding(
                    get: { skipOn },
                    set: {
                        guard actionAdmission() else { return }
                        skipOn = $0
                        PlayerPlaybackPreferences.animeSkipIntroOutro = $0
                        PlayerLog.log("[PlayerOptions] skip intro/outro → \($0 ? "ON" : "OFF")")
                    }
                )) {
                    Label("Skip Intro/Outro", systemImage: "forward.frame")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(isPlayerChrome ? .title3 : .body)
                .fontWeight(isPlayerChrome ? .semibold : .regular)
                .foregroundStyle(isPlayerChrome ? .white : .primary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("More"))
    }
}

struct LandscapeStatusInfo: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                Text(context.date, format: .dateTime.hour().minute())
                    .monospacedDigit()
                batteryInfo
            }
            .font(.footnote)
            .fontWeight(.medium)
            .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var batteryInfo: some View {
        let level = UIDevice.current.batteryLevel
        let percent = level >= 0 ? Int(level * 100) : nil
        let symbol: String = switch percent {
        case .some(..<13): "battery.0percent"
        case .some(..<38): "battery.25percent"
        case .some(..<63): "battery.50percent"
        case .some(..<88): "battery.75percent"
        case .some: "battery.100percent"
        case nil: "battery.50percent"
        }
        return HStack(spacing: 3) {
            Image(systemName: symbol)
            if let percent {
                Text("\(percent)%")
                    .monospacedDigit()
            }
        }
    }
}
