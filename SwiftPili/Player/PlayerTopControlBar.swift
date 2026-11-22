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

    var body: some View {
        HStack(spacing: player.isFullscreen ? 12 : 8) {
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
                }
                .accessibilityLabel(Text("Exit fullscreen"))

                LandscapeStatusInfo()
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
                }
                .danmakuToggleAccessibility(isOn: danmakuEnabled)
                .popover(isPresented: $inlineDanmakuPopoverPresented) {
                    inlineDanmakuSettingsPanel
                        .presentationCompactAdaptation(.popover)
                }
            }
            if DetailDanmakuEntryPolicy.chromeShowsSettings(
                usesOnlineVODServices: player.mode.usesOnlineVODServices,
                danmakuEnabled: danmakuEnabled,
                isFullscreen: player.isFullscreen
            ) {
                Button {
                    danmakuPanelPresented.toggle()
                    player.setDanmakuSettingsHold(danmakuPanelPresented)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .playerChromeCapsule(horizontal: 10, minHeight: 44)
                }
                .accessibilityLabel(Text("Danmaku Settings"))
            }

            if player.mode.usesOnlineVODServices, SponsorBlockManager.shared.isEnabled {
                Button {
                    showSponsorBlock = true
                } label: {
                    Image(systemName: "shield.lefthalf.filled")
                        .playerChromeCapsule(horizontal: 10, minHeight: 44)
                }
            }

            if player.isFullscreen {
                Menu {
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
                } label: {
                    Image(systemName: "aspectratio")
                        .playerChromeCapsule(horizontal: 10, minHeight: 44)
                }

                if !player.availableSubtitles.isEmpty {
                    Menu {
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
                    } label: {
                        Image(systemName: player.activeSubtitleLan == nil ? "captions.bubble" : "captions.bubble.fill")
                            .playerChromeCapsule(horizontal: 10, minHeight: 44)
                    }
                }

                Button { player.showStats.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Playback Info"))
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
    }

    private var showsInlineMenuDanmakuSettings: Bool {
        !player.isFullscreen && player.mode.usesOnlineVODServices && danmakuEnabled
    }

    private func presentInlineDanmakuPopoverFromMenu() {
        player.setDanmakuSettingsHold(true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard showsInlineMenuDanmakuSettings else {
                player.setDanmakuSettingsHold(danmakuPanelPresented)
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
