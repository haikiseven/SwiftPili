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
    @Binding var showSponsorBlock: Bool
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @State private var inlineDanmakuPopoverPresented = false
    @State private var inlineDanmakuPopoverTask: Task<Void, Never>?
    @State private var barWidth: CGFloat = 0

    private var isNarrowFullscreenBar: Bool {
        player.isFullscreen && barWidth > 0 && barWidth < 540
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
                presentationReceipt: presentationReceipt, fullscreenHostIdentity: fullscreenHostIdentity
            )

            if DetailDanmakuEntryPolicy.chromeShowsToggle(
                usesOnlineVODServices: player.mode.usesOnlineVODServices
            ) {
                Button {
                    danmakuEnabled.toggle()
                } label: {
                    Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                        .playerChromeCapsule(horizontal: 10, minHeight: 44)
                        .accessibilityHidden(true)
                }
                .danmakuToggleAccessibility(isOn: danmakuEnabled)
                .popover(isPresented: $inlineDanmakuPopoverPresented) {
                    inlineDanmakuSettingsPanel
                        .presentationCompactAdaptation(.popover)
                }
            }

            if isNarrowFullscreenBar {
                narrowFullscreenToolsMenu
            } else {
                if DetailDanmakuEntryPolicy.chromeShowsSettings(
                    usesOnlineVODServices: player.mode.usesOnlineVODServices,
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
                    Menu {
                        scaleModeMenuItems
                    } label: {
                        Image(systemName: "aspectratio")
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(Text("Aspect Mode"))
                    .accessibilityValue(Text(player.scaleMode.label))

                    if !player.availableSubtitles.isEmpty {
                        Menu {
                            subtitleMenuItems
                        } label: {
                            Image(systemName: player.activeSubtitleLan == nil ? "captions.bubble" : "captions.bubble.fill")
                                .playerChromeCapsule(horizontal: 10, minHeight: 44)
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel(Text("Subtitles"))
                        .accessibilityValue(Text(activeSubtitleAccessibilityValue))
                    }

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
                onDanmakuSettings: showsInlineMenuDanmakuSettings ? {
                    presentInlineDanmakuPopoverFromMenu()
                } : nil
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
        .onChange(of: inlineDanmakuPopoverPresented) { _, presented in
            player.setDanmakuSettingsHold(presented || danmakuPanelPresented)
        }
        .onChange(of: player.isFullscreen) { _, fullscreen in
            if fullscreen {
                inlineDanmakuPopoverPresented = false
            } else {
                danmakuPanelPresented = false
            }
            player.setDanmakuSettingsHold(inlineDanmakuPopoverPresented || danmakuPanelPresented)
        }
        .onChange(of: danmakuEnabled) { _, enabled in
            if !enabled {
                inlineDanmakuPopoverPresented = false
                danmakuPanelPresented = false
                player.setDanmakuSettingsHold(false)
            }
        }
        .onDisappear {
            inlineDanmakuPopoverTask?.cancel()
            inlineDanmakuPopoverTask = nil
            inlineDanmakuPopoverPresented = false
            if screenLease.map(player.isCurrentOwner) ?? false {
                danmakuPanelPresented = false
                player.setDanmakuSettingsHold(false)
            }
        }
    }

    private var showsSponsorBlockControl: Bool {
        player.mode.usesOnlineVODServices && SponsorBlockManager.shared.isEnabled
    }

    private var activeSubtitleAccessibilityValue: String {
        guard let active = player.activeSubtitleLan else { return String(localized: "Off") }
        let matched = player.availableSubtitles.first { $0.lan == active }
        return matched?.lanDoc ?? matched?.lan ?? active
    }

    private func toggleDanmakuSettingsPanel() {
        danmakuPanelPresented.toggle()
        player.setDanmakuSettingsHold(danmakuPanelPresented)
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
            Task { await player.selectSubtitle(nil) }
        } label: {
            HStack {
                Text("Off")
                if player.activeSubtitleLan == nil {
                    Image(systemName: "checkmark")
                }
            }
        }
        ForEach(player.availableSubtitles, id: \.lan) { item in
            Button {
                Task { await player.selectSubtitle(item) }
            } label: {
                HStack {
                    Text(item.lanDoc ?? item.lan ?? "?")
                    if item.lan == player.activeSubtitleLan {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private var narrowFullscreenToolsMenu: some View {
        Menu {
            if DetailDanmakuEntryPolicy.chromeShowsSettings(
                usesOnlineVODServices: player.mode.usesOnlineVODServices,
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
            if !player.availableSubtitles.isEmpty {
                Menu {
                    subtitleMenuItems
                } label: {
                    Label(
                        "Subtitles",
                        systemImage: player.activeSubtitleLan == nil ? "captions.bubble" : "captions.bubble.fill"
                    )
                }
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
        !player.isFullscreen && player.mode.usesOnlineVODServices && danmakuEnabled
    }

    private func presentInlineDanmakuPopoverFromMenu() {
        player.setDanmakuSettingsHold(true)
        inlineDanmakuPopoverTask?.cancel()
        inlineDanmakuPopoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, showsInlineMenuDanmakuSettings else {
                if !Task.isCancelled {
                    player.setDanmakuSettingsHold(danmakuPanelPresented)
                }
                return
            }
            inlineDanmakuPopoverPresented = true
        }
    }

    private var inlineDanmakuSettingsPanel: some View {
        DanmakuPlayerSettingsPanel(presentation: .inline, surface: .popover) {
            inlineDanmakuPopoverPresented = false
        }
    }
}
