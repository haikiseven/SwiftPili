import SwiftUI

struct PlayerPageNavigationButtons: View {
    static let buttonSize: CGFloat = 44
    static let spacing: CGFloat = 6
    static let slotWidth = 2 * buttonSize + spacing
    static let inlineHorizontalPadding: CGFloat = 12
    static let topPadding: CGFloat = 8

    let actions: PlayerPageNavigationActions

    var body: some View {
        HStack(spacing: Self.spacing) {
            Button(action: actions.onBack) {
                Image(systemName: "chevron.backward")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("player.pageBack")
            .accessibilityLabel(Text("Back"))

            Button(action: actions.onHome) {
                Image(systemName: "house")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("player.pageHome")
            .accessibilityLabel(Text("Home"))
        }
    }
}

struct PlayerTopControlBar: View {
    let player: PlayerViewModel
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    let liveQualityControl: LiveQualityControl?
    let pageNavigationActions: PlayerPageNavigationActions?
    let showsAnimeOptions: Bool
    let chromeInsets: PlayerChromeInsets
    @Binding var danmakuPanelPresented: Bool
    @Binding var subtitlePanelPresented: Bool
    @Binding var showSponsorBlock: Bool
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @State private var playlistSheetPresented = false
    @State private var barWidth: CGFloat = 0

    private var isNarrowFullscreenBar: Bool {
        player.isFullscreen && barWidth > 0 && barWidth < 540
    }

    private var activeFullscreenPlaylist: PlaybackQueueContext? {
        player.isFullscreen ? player.activePlaylistQueue : nil
    }

    private var hasDanmakuSupport: Bool {
        player.supportsDanmakuControls
            || (player.mode == .offline && player.hasRegisteredOfflineDanmaku)
    }

    var body: some View {
        HStack(spacing: (player.isFullscreen && !isNarrowFullscreenBar) ? 12 : 8) {
            if !player.isFullscreen, let pageNavigationActions {
                if pageNavigationActions.pageOwnsInlineNavigation {
                    Color.clear
                        .frame(
                            width: PlayerPageNavigationButtons.slotWidth,
                            height: PlayerPageNavigationButtons.buttonSize
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    PlayerPageNavigationButtons(actions: pageNavigationActions)
                }
            } else if player.isFullscreen {
                Button {
                    player.requestFullscreenTransition(target: false, source: .button)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(Text("Exit fullscreen"))

                if barWidth == 0 || barWidth >= 400 {
                    LandscapeStatusInfo()
                }
            }

            Spacer(minLength: 4)

            if let live = liveQualityControl, !live.options.isEmpty {
                let label = live.currentLabel ?? String(localized: "Auto")
                Menu {
                    ForEach(live.options) { option in
                        Button {
                            live.select(option.qn)
                        } label: {
                            HStack {
                                Text(option.label)
                                if option.qn == live.current {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(label)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .playerChromeCapsule()
                }
                .accessibilityLabel(Text("Video quality \(label)"))
            }

            PlayerPlaybackOptionsMenu(
                player: player, screenLease: screenLease,
                presentationReceipt: presentationReceipt, fullscreenHostIdentity: fullscreenHostIdentity,
                onOpenSubtitleSettings: { toggleSubtitleSettingsPanel() }
            )

            if !player.mode.supportsPlaybackRate {
                liveSleepTimerMenu
            }

            if DetailDanmakuEntryPolicy.chromeShowsToggle(
                usesOnlineVODServices: hasDanmakuSupport,
                hasOfflineDanmaku: player.hasRegisteredOfflineDanmaku
            ) {
                Button {
                    danmakuEnabled.toggle()
                } label: {
                    DanmakuSymbolIcon(
                        isOn: danmakuEnabled,
                        fontSize: 16,
                        activeColor: Color.biliAccent,
                        inactiveColor: .white.opacity(0.92)
                    )
                    .playerChromeCapsule(horizontal: 10, minHeight: 44)
                    .accessibilityHidden(true)
                }
                .danmakuToggleAccessibility(isOn: danmakuEnabled)
            }

            if isNarrowFullscreenBar {
                narrowFullscreenToolsMenu
            } else {
                if DetailDanmakuEntryPolicy.chromeShowsSettings(
                    usesOnlineVODServices: hasDanmakuSupport,
                    hasOfflineDanmaku: player.hasRegisteredOfflineDanmaku,
                    danmakuEnabled: danmakuEnabled,
                    isFullscreen: player.isFullscreen
                ) {
                    Button {
                        toggleDanmakuSettingsPanel()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(Text("Danmaku Settings"))
                }

                if showsSponsorBlockControl {
                    Button {
                        showSponsorBlock = true
                    } label: {
                        Image(systemName: "shield.lefthalf.filled")
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier("player.sponsorBlock")
                    .accessibilityLabel(Text("SponsorBlock"))
                }

                if player.isFullscreen {
                    if let playlist = activeFullscreenPlaylist {
                        Button {
                            playlistSheetPresented = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "list.bullet.rectangle")
                                Text("\(playlist.displayIndex)/\(playlist.totalCount)")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                            .accessibilityHidden(true)
                        }
                        .accessibilityIdentifier("player.topBarPlaylist")
                        .accessibilityLabel(Text("Playlist"))
                        .accessibilityValue(Text("\(playlist.displayIndex)/\(playlist.totalCount)"))
                    }

                    Menu {
                        scaleModeMenuItems
                    } label: {
                        Image(systemName: "aspectratio")
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(Text("Aspect Mode"))
                    .accessibilityValue(Text(player.scaleMode.label))

                    Menu {
                        subtitleMenuItems
                    } label: {
                        Image(systemName: player.hasAnyActiveSubtitle ? "captions.bubble.fill" : "captions.bubble")
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier("player.topBarSubtitles")
                    .accessibilityLabel(Text("Subtitles"))
                    .accessibilityValue(Text(activeSubtitleAccessibilityValue))

                    Button { player.showStats.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(Text("Playback Info"))
                    .accessibilityValue(player.showStats ? Text("On") : Text("Off"))
                }
            }

            PlayerMoreControl(
                player: player, screenLease: screenLease,
                presentationReceipt: presentationReceipt, fullscreenHostIdentity: fullscreenHostIdentity,
                showsAnimeOptions: showsAnimeOptions,
                onDownload: pageNavigationActions?.onDownload,
                onReport: pageNavigationActions?.onReport,
                onHideVideo: pageNavigationActions?.onHideVideo,
                onBlockOwner: pageNavigationActions?.onBlockOwner,
                onDanmakuSettings: showsInlineMenuDanmakuSettings ? {
                    toggleDanmakuSettingsPanel()
                } : nil,
                onSubtitleSettings: {
                    toggleSubtitleSettingsPanel()
                }
            )
            .accessibilityIdentifier("player.more")
        }
        .padding(
            .horizontal,
            (player.isFullscreen ? 0 : PlayerPageNavigationButtons.inlineHorizontalPadding) + chromeInsets.horizontal
        )
        .padding(.top, PlayerPageNavigationButtons.topPadding + chromeInsets.top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(barWidth - width) > 1 {
                barWidth = width
            }
        }
        .onChange(of: danmakuPanelPresented) { _, _ in
            syncControlsHold()
        }
        .onChange(of: player.isFullscreen) { _, _ in
            danmakuPanelPresented = false
            subtitlePanelPresented = false
            playlistSheetPresented = false
            syncControlsHold()
        }
        .onChange(of: danmakuEnabled) { _, enabled in
            if !enabled {
                danmakuPanelPresented = false
                syncControlsHold()
            }
        }
        .onChange(of: subtitlePanelPresented) { _, _ in
            syncControlsHold()
        }
        .onChange(of: playlistSheetPresented) { _, _ in
            syncControlsHold()
        }
        .onChange(of: player.activePlaylistQueue == nil) { _, isGone in
            if isGone {
                playlistSheetPresented = false
            }
        }
        .onDisappear {
            playlistSheetPresented = false
            if screenLease.map(player.isCurrentOwner) ?? false {
                danmakuPanelPresented = false
                subtitlePanelPresented = false
                player.setDanmakuSettingsHold(false)
            }
        }
        .sheet(isPresented: $playlistSheetPresented) {
            PlayerPlaylistDrawerSheet(player: player)
        }
    }

    private func syncControlsHold() {
        player.setDanmakuSettingsHold(
            danmakuPanelPresented
                || subtitlePanelPresented
                || playlistSheetPresented
        )
    }

    private func toggleSubtitleSettingsPanel() {
        subtitlePanelPresented.toggle()
        syncControlsHold()
    }

    private var showsSponsorBlockControl: Bool {
        player.mode.usesOnlineVODServices && SponsorBlockManager.shared.isEnabled
    }

    private var activeSubtitleAccessibilityValue: String {
        player.activeSubtitleSummaryLabel ?? String(localized: "Off")
    }

    private func toggleDanmakuSettingsPanel() {
        danmakuPanelPresented.toggle()
        syncControlsHold()
    }

    @ViewBuilder
    private var scaleModeMenuItems: some View {
        ForEach(VideoScaleMode.allCases) { mode in
            Button {
                player.scaleMode = mode
            } label: {
                HStack {
                    Text(mode.label)
                    if mode == player.scaleMode {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleMenuItems: some View {
        Button {
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
            toggleSubtitleSettingsPanel()
        } label: {
            Label("Subtitle Settings & Bilingual…", systemImage: "slider.horizontal.3")
        }
    }

    private var liveSleepTimerMenu: some View {
        Menu {
            ForEach(PlayerSleepTimerOption.options(allowsEndOfVideo: false)) { option in
                Button {
                    player.setSleepTimer(option)
                } label: {
                    HStack {
                        Text(option.label)
                        if option == player.sleepTimerOption {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: player.sleepTimerOption == .off ? "moon.zzz" : "moon.zzz.fill")
                if let badge = player.sleepTimerMenuBadge {
                    Text(verbatim: badge)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .playerChromeCapsule(horizontal: 10, minHeight: 44)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("player.liveSleepTimer")
        .accessibilityLabel(Text("Sleep Timer"))
        .accessibilityValue(Text(player.sleepTimerMenuBadge ?? String(localized: "Off")))
    }

    private var narrowFullscreenToolsMenu: some View {
        Menu {
            if let playlist = activeFullscreenPlaylist {
                Button {
                    playlistSheetPresented = true
                } label: {
                    Label(
                        String(
                            format: String(localized: "Playlist (%lld/%lld)"),
                            playlist.displayIndex,
                            playlist.totalCount
                        ),
                        systemImage: "list.bullet.rectangle"
                    )
                }
            }
            if DetailDanmakuEntryPolicy.chromeShowsSettings(
                usesOnlineVODServices: hasDanmakuSupport,
                hasOfflineDanmaku: player.hasRegisteredOfflineDanmaku,
                danmakuEnabled: danmakuEnabled,
                isFullscreen: player.isFullscreen
            ) {
                Button {
                    toggleDanmakuSettingsPanel()
                } label: {
                    Label("Danmaku Settings", systemImage: "slider.horizontal.3")
                }
            }
            if showsSponsorBlockControl {
                Button {
                    showSponsorBlock = true
                } label: {
                    Label("SponsorBlock", systemImage: "shield.lefthalf.filled")
                }
            }
            Menu {
                scaleModeMenuItems
            } label: {
                Label("Aspect Mode", systemImage: "aspectratio")
            }
            Menu {
                subtitleMenuItems
            } label: {
                Label(
                    "Subtitles",
                    systemImage: player.hasAnyActiveSubtitle ? "captions.bubble.fill" : "captions.bubble"
                )
            }
            Toggle(isOn: Binding(get: { player.showStats }, set: { player.showStats = $0 })) {
                Label("Playback Info", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .playerChromeCapsule(horizontal: 10, minHeight: 44)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(Text("Player Tools"))
    }

    private var showsInlineMenuDanmakuSettings: Bool {
        !player.isFullscreen && hasDanmakuSupport && danmakuEnabled
    }
}
