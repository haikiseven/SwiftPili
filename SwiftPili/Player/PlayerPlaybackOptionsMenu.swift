import SwiftUI
import UIKit

struct PlayerPlaybackOptionsMenu: View {
    let player: PlayerViewModel
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    var onOpenSubtitleSettings: (() -> Void)? = nil
    private let experiments = ExperimentalSettingsStore.shared
    @State private var enhancementPresentation: EnhancementPresentation?
    @State private var subtitleSheetPresented = false

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
        .sheet(isPresented: $subtitleSheetPresented) {
            PlayerSubtitleSettingsSheet(player: player)
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

            Divider()
            PlayerSubtitleInlineMenu(
                player: player,
                actionAdmission: nil,
                onOpenSettings: {
                    if let onOpenSubtitleSettings {
                        onOpenSubtitleSettings()
                    } else {
                        subtitleSheetPresented = true
                    }
                },
                accessibilityID: "player.subtitles"
            )

            PlayerSleepTimerSubmenu(player: player)

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
            if player.sleepTimerOption != .off {
                Image(systemName: "moon.zzz.fill")
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel(Text("Sleep Timer"))
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

private struct PlayerSubtitleInlineMenu: View {
    let player: PlayerViewModel
    let actionAdmission: (() -> Bool)?
    let onOpenSettings: () -> Void
    let accessibilityID: String

    private func admit() -> Bool {
        actionAdmission?() ?? true
    }

    var body: some View {
        Menu {
            Button {
                guard admit() else { return }
                player.turnOffAllSubtitles()
            } label: {
                HStack {
                    Text("Off")
                    if !player.hasAnyActiveSubtitle {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !player.availableSubtitles.isEmpty {
                Section("Bilibili Cloud Subtitles") {
                    ForEach(Array(player.availableSubtitles.enumerated()), id: \.offset) { _, item in
                        Button {
                            guard admit() else { return }
                            Task { await player.selectSubtitle(item) }
                        } label: {
                            HStack {
                                Text(item.menuDisplayTitle)
                                if let lan = item.lan,
                                   lan == player.activeSubtitleLan || lan == player.secondarySubtitleLan {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    if player.availableSubtitles.count >= 2 {
                        Menu {
                            Button {
                                guard admit() else { return }
                                Task { await player.selectSecondarySubtitleTrack(id: nil) }
                            } label: {
                                HStack {
                                    Text("Off")
                                    if player.secondarySubtitleLan == nil {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            ForEach(Array(player.availableSubtitles.enumerated()), id: \.offset) { _, item in
                                if let lan = item.lan, lan != player.activeSubtitleLan {
                                    Button {
                                        guard admit() else { return }
                                        Task { await player.selectSecondarySubtitleTrack(id: lan) }
                                    } label: {
                                        HStack {
                                            Text(item.menuDisplayTitle)
                                            if lan == player.secondarySubtitleLan {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Secondary Subtitle (Bilingual)", systemImage: "captions.bubble")
                        }
                    }
                }
            }

            if !player.importedSubtitleTracks.isEmpty {
                Section("Local Subtitle File (.srt / .vtt)") {
                    ForEach(player.importedSubtitleTracks) { track in
                        Button {
                            guard admit() else { return }
                            Task { await player.selectPrimarySubtitleTrack(id: track.id) }
                        } label: {
                            HStack {
                                Text(track.displayName)
                                if track.id == player.activeSubtitleLan || track.id == player.secondarySubtitleLan {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if ((player.activeSubtitleLan != nil || player.isAutoTranslationEnabled) && player.supportsAutoSubtitleTranslation)
                || player.supportsSystemSpeechSubtitles {
                Divider()
            }

            if (player.activeSubtitleLan != nil || player.isAutoTranslationEnabled), player.supportsAutoSubtitleTranslation {
                Button {
                    guard admit() else { return }
                    player.setAutoSubtitleTranslationEnabled(!player.isAutoTranslationEnabled)
                } label: {
                    HStack {
                        Label {
                            Text("Offline Translation")
                                + Text(verbatim: " (\(player.subtitleTranslationTargetLanguage.shortLabel))")
                        } icon: {
                            Image(systemName: "translate")
                        }
                        if player.isAutoTranslationEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            if player.supportsSystemSpeechSubtitles {
                Button {
                    guard admit() else { return }
                    player.setSystemSpeechSubtitlesEnabled(!player.isSpeechSubtitleEnabled)
                } label: {
                    HStack {
                        Label("Live Speech", systemImage: "waveform")
                        if player.isSpeechSubtitleEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()
            Button {
                guard admit() else { return }
                onOpenSettings()
            } label: {
                Label("Subtitle Settings & Bilingual…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label {
                if let summary = player.activeSubtitleSummaryLabel {
                    Text("Subtitles") + Text(verbatim: " (\(summary))")
                } else {
                    Text("Subtitles")
                }
            } icon: {
                Image(systemName: player.hasAnyActiveSubtitle ? "captions.bubble.fill" : "captions.bubble")
            }
        }
        .accessibilityIdentifier(accessibilityID)
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
                    Text("Video Enhancement") + Text(verbatim: " (\(unavailableReason))")
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
            return title + Text(verbatim: " (") + Text("Paused") + Text(verbatim: ")")
        }
        var parts: [String] = []
        switch player.videoSuperResolutionMode {
        case .off:
            break
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
        return title + Text(verbatim: " (\(parts.joined(separator: " + ")))")
    }
}

enum DetailDanmakuEntryPolicy {
    static func chromeShowsToggle(
        usesOnlineVODServices: Bool,
        hasOfflineDanmaku: Bool = false
    ) -> Bool {
        usesOnlineVODServices || hasOfflineDanmaku
    }

    static func chromeShowsSettings(
        usesOnlineVODServices: Bool,
        hasOfflineDanmaku: Bool = false,
        danmakuEnabled: Bool,
        isFullscreen: Bool
    ) -> Bool {
        (usesOnlineVODServices || hasOfflineDanmaku) && danmakuEnabled && isFullscreen
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
    var onHideVideo: (() -> Void)?
    var onBlockOwner: (() -> Void)?
    var onDanmakuSettings: (() -> Void)?
    var onSubtitleSettings: (() -> Void)?
    var onEqualizer: (() -> Void)?
    let actionAdmission: () -> Bool
    var isPlayerChrome = false
    @State private var resumeOn = PlayerPlaybackPreferences.resumePlayback
    @State private var skipOn = PlayerPlaybackPreferences.animeSkipIntroOutro
    @State private var subtitleSheetPresented = false
    @State private var showChapterSheet = false

    var body: some View {
        Menu {
            if onDownload != nil || onReport != nil || onHideVideo != nil || onBlockOwner != nil {
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
                if let onHideVideo {
                    Button(role: .destructive) {
                        guard actionAdmission() else { return }
                        onHideVideo()
                    } label: {
                        Label("Locally Hide Video & Exit", systemImage: "eye.slash")
                    }
                }
                if let onBlockOwner {
                    Button(role: .destructive) {
                        guard actionAdmission() else { return }
                        onBlockOwner()
                    } label: {
                        Label("Locally Block UP & Exit", systemImage: "person.slash")
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
            if !player.videoChapters.isEmpty {
                Button {
                    guard actionAdmission() else { return }
                    player.hideControlsTask?.cancel()
                    player.hideControlsTask = nil
                    showChapterSheet = true
                } label: {
                    Label("Chapters", systemImage: "list.bullet.indent")
                }
                .accessibilityIdentifier("player.chapters")
            }
            PlayerSubtitleInlineMenu(
                player: player,
                actionAdmission: actionAdmission,
                onOpenSettings: {
                    if let onSubtitleSettings {
                        onSubtitleSettings()
                    } else {
                        subtitleSheetPresented = true
                    }
                },
                accessibilityID: "player.moreSubtitles"
            )
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
                    get: {
                        _ = resumeOn
                        return PlayerPlaybackPreferences.resumePlayback
                    },
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
                    get: {
                        _ = skipOn
                        return PlayerPlaybackPreferences.animeSkipIntroOutro
                    },
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
        .onAppear {
            resumeOn = PlayerPlaybackPreferences.resumePlayback
            skipOn = PlayerPlaybackPreferences.animeSkipIntroOutro
        }
        .sheet(isPresented: $subtitleSheetPresented) {
            PlayerSubtitleSettingsSheet(player: player)
        }
        .sheet(isPresented: $showChapterSheet) {
            PlayerChapterSheet(
                chapters: player.videoChapters,
                currentTime: player.displayTime
            ) { chapter in
                player.seek(to: chapter.from)
                if !player.isPlaying {
                    player.play()
                }
            }
        }
        .onChange(of: showChapterSheet) { _, presented in
            if !presented {
                player.scheduleHideControls()
            }
        }
        .onChange(of: player.videoChapters.isEmpty) { _, isEmpty in
            if isEmpty {
                showChapterSheet = false
            }
        }
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
        .onAppear {
            if !UIDevice.current.isBatteryMonitoringEnabled {
                UIDevice.current.isBatteryMonitoringEnabled = true
            }
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
