import SwiftUI

struct SettingsView: View {
    @State private var wifiQuality = PlayerPlaybackPreferences.wifiQuality
    @State private var cellularQuality = PlayerPlaybackPreferences.cellularQuality
    @State private var wifiAudioQuality = PlayerPlaybackPreferences.wifiAudioQuality
    @State private var cellularAudioQuality = PlayerPlaybackPreferences.cellularAudioQuality
    @State private var hardwareDecode = PlayerPlaybackPreferences.hardwareDecodeEnabled
    @State private var playbackOrder = PlayerViewModel.shared.playbackOrder
    @State private var cacheSize = "…"
    @State private var showClearConfirm = false
    @AppStorage(CacheManager.sizeLimitKey) private var cacheLimitMB = 500
    @AppStorage(DownloadNetworkPolicy.cellularSettingsKey) private var downloadOverCellular = true
    @AppStorage(DownloadNetworkPolicy.multiConnectionSettingsKey) private var multiConnectionDownloads = true
    @State private var backgroundAudio = PlayerPlaybackPreferences.backgroundAudioEnabled
    @State private var pictureInPicture = PlayerPlaybackPreferences.pictureInPictureEnabled
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(HomeLayoutMode.storageKey) private var homeLayoutRaw = HomeLayoutMode.grid.rawValue
    @State private var coverAspect = CoverAspect.current
    @State private var coverDisplay = CoverDisplayMode.current
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @AppStorage(DetailStagePreferences.startsInStageKey) private var detailStartsInStage = false
    @AppStorage("show_network_speed") private var showNetworkSpeed = false
    @AppStorage("show_comment_ornaments") private var showCommentOrnaments = false
    @AppStorage(ClipboardLinkDetector.settingsKey) private var clipboardLinkDetection = false
    @State private var smartCDNEnabled = SmartCDNSelector.isEnabled
    @State private var currentCDNLabel = CDNService.current.label
    @State private var showSetupWizard = false

    var body: some View {
        List {
            Group {
                appearanceSection
                playbackSection
                browsingSection
                storageSection
                advancedAndAboutSection
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView()
        }
        .onAppear {
            smartCDNEnabled = SmartCDNSelector.isEnabled
            currentCDNLabel = CDNService.current.label
        }
        .task { await refreshCacheSize() }
    }

    private func refreshCacheSize() async {
        let bytes = await CacheManager.currentDiskUsage()
        cacheSize = CacheManager.format(bytes)
    }
}

// MARK: - Sections

private extension SettingsView {
    var appearanceSection: some View {
        Section("Appearance & Display") {
            Picker(selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            } label: {
                settingsLabel("Appearance Mode", symbol: "circle.lefthalf.filled")
            }

            NavigationLink {
                ColorSettingsView()
            } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AccentStore.shared.theme?.color ?? Color.accentColor)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: AppStroke.hairlineWidth)
                            )
                            .frame(width: 11, height: 11)
                        if let theme = AccentStore.shared.theme {
                            Text(LocalizedStringKey(theme.rawValue))
                        } else {
                            Text("System (accent)")
                        }
                    }
                } label: {
                    settingsLabel("Color", symbol: "paintpalette")
                }
            }

            Picker(selection: $homeLayoutRaw) {
                ForEach(HomeLayoutMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            } label: {
                settingsLabel("Homepage Layout", symbol: "square.grid.2x2")
            }

            if DeviceCapability.supportsPadDetailSplit {
                Picker(selection: $detailStartsInStage) {
                    Text("Hero First").tag(false)
                    Text("Direct Stage").tag(true)
                } label: {
                    settingsLabel("iPad Landscape Detail Layout", symbol: "rectangle.split.2x1")
                }
                Text(detailStartsInStage
                    ? "Video and comments appear side by side as soon as a page opens."
                    : "Pages open with a large preview; scroll down to reveal comments.")
                    .appFont(.rowMeta)
                    .foregroundStyle(.secondary)
            }

            Picker(selection: Binding(
                get: { coverAspect },
                set: { newValue in
                    coverAspect = newValue
                    CoverAspect.current = newValue
                    CoverPresentationStore.shared.reload()
                }
            )) {
                ForEach(CoverAspect.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                settingsLabel("Cover Aspect", symbol: "rectangle.on.rectangle")
            }

            Picker(selection: Binding(
                get: { coverDisplay },
                set: { newValue in
                    coverDisplay = newValue
                    CoverDisplayMode.current = newValue
                    CoverPresentationStore.shared.reload()
                }
            )) {
                ForEach(CoverDisplayMode.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                settingsLabel("Cover Display", symbol: "aspectratio")
            }
        }
    }

    var playbackSection: some View {
        Section("Playback & Danmaku") {
            qualityPicker(
                title: "Wi-Fi Quality",
                icon: "wifi",
                selection: $wifiQuality,
                isWiFi: true
            )
            qualityPicker(
                title: "Cellular Quality",
                icon: "antenna.radiowaves.left.and.right",
                selection: $cellularQuality,
                isWiFi: false
            )
            audioQualityPicker(
                title: "Wi-Fi Audio Quality",
                icon: "waveform",
                selection: $wifiAudioQuality,
                onSelect: { PlayerPlaybackPreferences.wifiAudioQuality = $0 }
            )
            audioQualityPicker(
                title: "Cellular Audio Quality",
                icon: "waveform.badge.minus",
                selection: $cellularAudioQuality,
                onSelect: { PlayerPlaybackPreferences.cellularAudioQuality = $0 }
            )

            NavigationLink {
                DanmakuSettingsView()
            } label: {
                LabeledContent {
                    Text(danmakuEnabled ? "On" : "Off")
                } label: {
                    settingsLabel("Danmaku", symbol: "text.bubble")
                }
            }

            NavigationLink {
                SponsorBlockSettingsView()
            } label: {
                LabeledContent {
                    Text(SponsorBlockManager.shared.isEnabled ? "On" : "Off")
                } label: {
                    settingsLabel("SponsorBlock", symbol: "shield.lefthalf.filled")
                }
            }

            Toggle(isOn: Binding(
                get: { backgroundAudio },
                set: { newValue in
                    backgroundAudio = newValue
                    PlayerPlaybackPreferences.backgroundAudioEnabled = newValue
                    PlayerViewModel.shared.applyPlaybackContinuationSettings()
                }
            )) {
                settingsLabel("Background Audio", symbol: "speaker.wave.2")
            }

            Toggle(isOn: Binding(
                get: { pictureInPicture },
                set: { newValue in
                    pictureInPicture = newValue
                    PlayerPlaybackPreferences.pictureInPictureEnabled = newValue
                    PlayerViewModel.shared.applyPlaybackContinuationSettings()
                }
            )) {
                settingsLabel("Picture in Picture", symbol: "pip")
            }
            .disabled(!backgroundAudio)

            Picker(selection: Binding(
                get: { playbackOrder },
                set: { newValue in
                    playbackOrder = newValue
                    PlayerViewModel.shared.playbackOrder = newValue
                }
            )) {
                ForEach(PlaybackOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            } label: {
                settingsLabel("When Playback Ends", symbol: "repeat")
            }

            Toggle(isOn: $showNetworkSpeed) {
                settingsLabel("Show Network Speed", symbol: "speedometer")
            }

            Toggle(isOn: Binding(
                get: { hardwareDecode },
                set: { newValue in
                    hardwareDecode = newValue
                    PlayerPlaybackPreferences.hardwareDecodeEnabled = newValue
                }
            )) {
                settingsLabel("Hardware Decoding", symbol: "cpu")
            }
        }
    }

    var browsingSection: some View {
        Section("Browsing & Community") {
            Toggle(isOn: $showCommentOrnaments) {
                settingsLabel("Show Comment Ornaments", symbol: "sparkles")
            }

            Toggle(isOn: Binding(
                get: { BlocklistManager.shared.isEnabled },
                set: { BlocklistManager.shared.isEnabled = $0 }
            )) {
                settingsLabel("Enable Blocking", symbol: "hand.raised")
            }

            NavigationLink {
                BlacklistView()
            } label: {
                let blockedCount = BlocklistManager.shared.blockedMids.count
                LabeledContent {
                    if blockedCount > 0 {
                        Text(verbatim: "\(blockedCount)")
                            .monospacedDigit()
                    }
                } label: {
                    settingsLabel("Blocked Users", symbol: "person.crop.circle.badge.xmark")
                }
            }

            Toggle(isOn: $clipboardLinkDetection) {
                settingsLabel("Automatically Detect Bilibili Links from Clipboard", symbol: "doc.on.clipboard")
            }
        }
    }

    var storageSection: some View {
        Section {
            Toggle(isOn: $multiConnectionDownloads) {
                settingsLabel("Multi-Connection Downloads", symbol: "arrow.triangle.branch")
            }

            Toggle(isOn: $downloadOverCellular) {
                settingsLabel("Download over Cellular", symbol: "arrow.down.circle")
            }

            LabeledContent {
                Text(cacheSize)
                    .monospacedDigit()
            } label: {
                settingsLabel("Cached Data", symbol: "internaldrive")
            }

            Picker(selection: $cacheLimitMB) {
                Text("100 MB").tag(100)
                Text("250 MB").tag(250)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
                Text("Unlimited").tag(0)
            } label: {
                settingsLabel("Max Cache Size", symbol: "gauge.with.needle")
            }
            .onChange(of: cacheLimitMB) {
                CacheManager.apply()
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label {
                    Text("Clear Cache")
                        .foregroundStyle(.red)
                } icon: {
                    SettingsIcon(symbol: "trash", tint: .red)
                }
            }
            .confirmationDialog(
                "Clear all cached images and data?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await CacheManager.clearAll()
                        await refreshCacheSize()
                    }
                }
            }
        } header: {
            Text("Downloads & Storage")
        } footer: {
            Text("Downloads use parallel CDN connections on Wi-Fi for faster speeds and automatically limit concurrency on cellular.")
        }
    }

    var advancedAndAboutSection: some View {
        Section("Advanced & About") {
            NavigationLink {
                AdvancedSettingsView()
            } label: {
                LabeledContent {
                    if smartCDNEnabled {
                        Text("Smart CDN")
                    } else {
                        Text(currentCDNLabel)
                    }
                } label: {
                    settingsLabel("Advanced Settings", symbol: "slider.horizontal.3")
                }
            }

            NavigationLink {
                ExperimentalSettingsView()
            } label: {
                LabeledContent {
                    Text(ExperimentalSettingsStore.shared.snapshot.masterEnabled ? "On" : "Off")
                } label: {
                    settingsLabel("Experimental Features", symbol: "flask")
                }
            }

            Button {
                showSetupWizard = true
            } label: {
                settingsLabel("Setup Wizard", symbol: "wand.and.stars")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                AboutView()
            } label: {
                LabeledContent {
                    if let version = AppBuildInfo.current.version {
                        Text(verbatim: version)
                            .monospacedDigit()
                    }
                } label: {
                    settingsLabel("About", symbol: "info.circle")
                }
            }
        }
    }

    func qualityPicker(
        title: LocalizedStringKey,
        icon: String,
        selection: Binding<Int>,
        isWiFi: Bool
    ) -> some View {
        NavigationLink {
            QualityPickerView(
                title: title,
                selectedQuality: selection,
                onSelect: { quality in
                    if isWiFi {
                        PlayerPlaybackPreferences.wifiQuality = quality
                    } else {
                        PlayerPlaybackPreferences.cellularQuality = quality
                    }
                }
            )
        } label: {
            LabeledContent {
                Text(PlayerViewModel.qualityMap[selection.wrappedValue] ?? "\(selection.wrappedValue)")
            } label: {
                settingsLabel(title, symbol: icon)
            }
        }
    }

    func audioQualityPicker(
        title: LocalizedStringKey,
        icon: String,
        selection: Binding<AudioQualityTier>,
        onSelect: @escaping (AudioQualityTier) -> Void
    ) -> some View {
        NavigationLink {
            AudioQualityPickerView(
                title: title,
                selectedTier: selection,
                onSelect: onSelect
            )
        } label: {
            LabeledContent {
                Text(selection.wrappedValue.label)
            } label: {
                settingsLabel(title, symbol: icon)
            }
        }
    }

    func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}

// MARK: - Quality Picker

struct QualityPickerView: View {
    let title: LocalizedStringKey
    @Binding var selectedQuality: Int
    let onSelect: (Int) -> Void

    var body: some View {
        List {
            Section {
                ForEach(PlayerViewModel.selectableQualities, id: \.id) { quality in
                    let isSelected = quality.id == selectedQuality
                    Button {
                        selectedQuality = quality.id
                        onSelect(quality.id)
                    } label: {
                        HStack(spacing: AppSpacing.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quality.desc)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(qualityNote(quality.id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.biliAccent)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func qualityNote(_ qualityID: Int) -> String {
        switch qualityID {
        case 127, 126, 125, 120, 116, 112: return String(localized: "Requires VIP")
        case 80, 74: return String(localized: "Requires login")
        case 64, 32, 16: return String(localized: "Free")
        default: return ""
        }
    }
}

struct AudioQualityPickerView: View {
    let title: LocalizedStringKey
    @Binding var selectedTier: AudioQualityTier
    let onSelect: (AudioQualityTier) -> Void

    var body: some View {
        List {
            Section {
                ForEach(AudioQualityTier.byRankDescending, id: \.self) { tier in
                    let isSelected = tier == selectedTier
                    Button {
                        selectedTier = tier
                        onSelect(tier)
                    } label: {
                        HStack(spacing: AppSpacing.m) {
                            Text(tier.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.biliAccent)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
