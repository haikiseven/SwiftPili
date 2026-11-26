import SwiftUI
import UIKit

enum SetupWizardPolicy {
    static let completedStorageKey = "setup_wizard_completed_v1"
}

enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case appearance = 0
    case playback = 1
    case networkAndCommunity = 2
    case ready = 3

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: "Appearance & Layout"
        case .playback: "Playback & Experience"
        case .networkAndCommunity: "Network & Community"
        case .ready: "Get Started"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .appearance: "Choose your theme, accent color, ambient glow, and feed layout."
        case .playback: "Configure streaming quality, danmaku, background playback, and SponsorBlock."
        case .networkAndCommunity: "Optimize CDN routing, comment filtering, and clipboard link detection."
        case .ready: "Sign in to sync your Bilibili account or start browsing right away."
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .playback: "play.tv.fill"
        case .networkAndCommunity: "network"
        case .ready: "sparkles"
        }
    }
}

struct SetupWizardView: View {
    private let experiments = ExperimentalSettingsStore.shared

    @AppStorage(SetupWizardPolicy.completedStorageKey) private var hasCompletedSetup = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(HomeLayoutMode.storageKey) private var homeLayoutRaw = HomeLayoutMode.grid.rawValue
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false
    @AppStorage(ClipboardLinkDetector.settingsKey) private var clipboardLinkDetection = false
    @AppStorage(DetailStagePreferences.startsInStageKey) private var detailStartsInStage = false

    @State private var currentStep: SetupWizardStep = .appearance
    @State private var selectedTheme: AccentTheme = AccentTheme.current ?? .bilibiliPink
    @State private var syncAppIcon: Bool = AppIconSync.isEnabled
    @State private var coverAspect: CoverAspect = CoverAspect.current
    @State private var coverDisplay: CoverDisplayMode = CoverDisplayMode.current
    @State private var wifiQuality: Int = PlayerPlaybackPreferences.wifiQuality
    @State private var backgroundAudio: Bool = PlayerPlaybackPreferences.backgroundAudioEnabled
    @State private var pictureInPicture: Bool = PlayerPlaybackPreferences.pictureInPictureEnabled
    @State private var inAppMiniPlayer: Bool = PlayerPlaybackPreferences.inAppMiniPlayerEnabled
    @State private var resumePlayback: Bool = PlayerPlaybackPreferences.resumePlayback
    @State private var smartCDNEnabled: Bool = SmartCDNSelector.isEnabled
    @State private var blockPCDN: Bool = CDNHostPolicy.blockPCDN
    @State private var showLoginSheet = false

    @AppMotion private var motion
    @Environment(\.dismiss) private var dismiss

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepHeader.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Color.clear
                                .frame(height: 0)
                                .id("wizardTop")
                            stepContent
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                        .frame(maxWidth: ReadableWidth.form)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: currentStep) { _, _ in
                        withAnimation(motion.animation(normal: .snappy(duration: 0.22))) {
                            proxy.scrollTo("wizardTop", anchor: .top)
                        }
                    }
                }
                bottomBar.padding(.horizontal, 20).padding(.vertical, 14)
            }
            .appAmbientBrowseBackground()
            .navigationTitle("Setup Wizard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { completeAndDismiss() }.foregroundStyle(.secondary)
                }
            }
        }
        .accentContentBoundary()
        .preferredColorScheme(appearanceMode.colorScheme)
        .sheet(isPresented: $showLoginSheet) {
            NavigationStack {
                LoginView().toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showLoginSheet = false }
                    }
                }
            }
            .accentContentBoundary()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .appearance:
            SetupWizardAppearanceStep(
                appearanceRaw: $appearanceRaw,
                homeLayoutRaw: $homeLayoutRaw,
                selectedTheme: $selectedTheme,
                syncAppIcon: $syncAppIcon,
                coverAspect: $coverAspect,
                coverDisplay: $coverDisplay
            )
        case .playback:
            SetupWizardPlaybackStep(
                wifiQuality: $wifiQuality,
                danmakuEnabled: $danmakuEnabled,
                backgroundAudio: $backgroundAudio,
                pictureInPicture: $pictureInPicture,
                inAppMiniPlayer: $inAppMiniPlayer,
                resumePlayback: $resumePlayback
            )
        case .networkAndCommunity:
            SetupWizardNetworkCommunityStep(
                smartCDNEnabled: $smartCDNEnabled,
                blockPCDN: $blockPCDN,
                clipboardLinkDetection: $clipboardLinkDetection
            )
        case .ready:
            SetupWizardReadyStep(
                appearanceMode: appearanceMode,
                selectedTheme: selectedTheme,
                ambientModeEnabled: experiments.ambientModeEnabled,
                homeLayout: HomeLayoutMode(rawValue: homeLayoutRaw) ?? .grid,
                coverAspect: coverAspect,
                coverDisplay: coverDisplay,
                detailStartsInStage: detailStartsInStage,
                wifiQuality: wifiQuality,
                danmakuEnabled: danmakuEnabled,
                backgroundAudio: backgroundAudio,
                pictureInPicture: pictureInPicture,
                inAppMiniPlayer: inAppMiniPlayer,
                sponsorBlockEnabled: SponsorBlockManager.shared.isEnabled,
                resumePlayback: resumePlayback,
                smartCDNEnabled: smartCDNEnabled,
                aiCommentFilterEnabled: experiments.isAllowed(.aiCommentFilter),
                onSignIn: { showLoginSheet = true }
            )
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(SetupWizardStep.allCases) { step in
                    let isReached = step.rawValue <= currentStep.rawValue
                    Capsule()
                        .fill(isReached ? AccentStore.shared.badgeFill : Color.primary.opacity(0.14))
                        .frame(height: 5)
                }
            }
            .animation(motion.animation(normal: .snappy(duration: 0.22)), value: currentStep)

            HStack(spacing: 12) {
                let iconShape = RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                Image(systemName: currentStep.icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .frame(width: 44, height: 44)
                    .background(AppFill.inset, in: iconShape)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentStep.title).appFont(.screenTitle).fontWeight(.bold)
                    Text(currentStep.subtitle)
                        .appFont(.messageMeta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if currentStep != .appearance {
                Button {
                    if let prev = SetupWizardStep(rawValue: currentStep.rawValue - 1) {
                        currentStep = prev
                    }
                } label: {
                    Text("Back")
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(AppFill.inset, in: Capsule())
                }
                .buttonStyle(.appControl)
            }

            Button {
                if let next = SetupWizardStep(rawValue: currentStep.rawValue + 1) {
                    currentStep = next
                } else {
                    completeAndDismiss()
                }
            } label: {
                let isLast = currentStep == .ready
                HStack(spacing: 6) {
                    Text(isLast ? "Get Started" : "Next").appFont(.controlLabel).fontWeight(.bold)
                    Image(systemName: isLast ? "checkmark.circle.fill" : "arrow.right")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AccentStore.shared.badgeFill, in: Capsule())
            }
            .buttonStyle(.appControl)
        }
    }

    private func completeAndDismiss() {
        hasCompletedSetup = true
        dismiss()
    }
}

private struct SetupWizardAppearanceStep: View {
    private let experiments = ExperimentalSettingsStore.shared

    @Binding var appearanceRaw: String
    @Binding var homeLayoutRaw: String
    @Binding var selectedTheme: AccentTheme
    @Binding var syncAppIcon: Bool
    @Binding var coverAspect: CoverAspect
    @Binding var coverDisplay: CoverDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardCard(title: "Appearance Mode", icon: "moon.circle.fill") {
                HStack(spacing: 10) {
                    ForEach(AppearanceMode.allCases) { mode in
                        pillOption(
                            title: Text(mode.label),
                            icon: mode.icon,
                            isSelected: appearanceRaw == mode.rawValue,
                            vertical: true
                        ) { appearanceRaw = mode.rawValue }
                    }
                }
            }

            wizardCard(title: "Accent Color", icon: "paintpalette.fill") {
                VStack(spacing: 8) {
                    ForEach(AccentTheme.allCases) { theme in themeRow(theme) }
                    if UIApplication.shared.supportsAlternateIcons {
                        Divider()
                            .padding(.vertical, 4)
                        Toggle(isOn: Binding(
                            get: { syncAppIcon },
                            set: { newValue in
                                syncAppIcon = newValue
                                AppIconSync.isEnabled = newValue
                                if newValue {
                                    AppIconSync.syncIfEnabled(for: selectedTheme)
                                }
                            }
                        )) {
                            Label("Sync App Icon", systemImage: "app.badge").appFont(.rowTitle)
                        }
                    }
                }
            }

            wizardCard(title: "Ambient Mode", icon: "sun.haze.fill") {
                Toggle(isOn: Binding(
                    get: { experiments.ambientModeEnabled },
                    set: { _ = experiments.setAmbientModeEnabled($0) }
                )) {
                    Label("Ambient Mode", systemImage: "sun.haze").appFont(.rowTitle)
                }
            }

            wizardCard(title: "Homepage Layout", icon: "square.grid.2x2.fill") {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Layout")
                            .appFont(.rowMeta)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(HomeLayoutMode.allCases) { mode in
                                pillOption(
                                    title: Text(mode.label),
                                    icon: mode.icon,
                                    isSelected: homeLayoutRaw == mode.rawValue,
                                    vertical: false
                                ) { homeLayoutRaw = mode.rawValue }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cover Aspect")
                            .appFont(.rowMeta)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(CoverAspect.allCases) { option in
                                pillOption(
                                    title: Text(verbatim: option.label),
                                    icon: option.icon,
                                    isSelected: coverAspect == option,
                                    vertical: false
                                ) {
                                    coverAspect = option
                                    CoverAspect.current = option
                                    CoverPresentationStore.shared.reload()
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cover Display")
                            .appFont(.rowMeta)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(CoverDisplayMode.allCases) { option in
                                pillOption(
                                    title: Text(option.label),
                                    icon: option.icon,
                                    isSelected: coverDisplay == option,
                                    vertical: false
                                ) {
                                    coverDisplay = option
                                    CoverDisplayMode.current = option
                                    CoverPresentationStore.shared.reload()
                                }
                            }
                        }
                    }
                }
            }

            if DeviceCapability.supportsPadDetailSplit {
                SetupWizardDetailLayoutCard()
            }
        }
    }

    private func themeRow(_ theme: AccentTheme) -> some View {
        let isSelected = selectedTheme == theme
        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        return Button {
            selectedTheme = theme
            AccentTheme.current = theme
            AccentStore.shared.reload()
            AppIconSync.syncIfEnabled(for: theme)
        } label: {
            HStack(spacing: 12) {
                Circle().fill(theme.color).frame(width: 24, height: 24)
                Text(LocalizedStringKey(theme.rawValue)).appFont(.rowTitle).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(theme.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? AppFill.inset : Color.clear, in: shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pillOption(
        title: Text,
        icon: String,
        isSelected: Bool,
        vertical: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let fill = isSelected ? AnyShapeStyle(AccentStore.shared.badgeFill) : AnyShapeStyle(AppFill.inset)
        let shape = RoundedRectangle(cornerRadius: vertical ? AppRadius.card : AppRadius.control, style: .continuous)
        return Button(action: action) {
            Group {
                if vertical {
                    VStack(spacing: 8) {
                        Image(systemName: icon).font(.title3.weight(.semibold))
                        title.appFont(.controlLabel).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                        title
                            .appFont(.controlLabel)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, vertical ? 12 : 10)
            .padding(.horizontal, 8)
            .background(fill, in: shape)
        }
        .buttonStyle(.appControl)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SetupWizardPlaybackStep: View {
    @Binding var wifiQuality: Int
    @Binding var danmakuEnabled: Bool
    @Binding var backgroundAudio: Bool
    @Binding var pictureInPicture: Bool
    @Binding var inAppMiniPlayer: Bool
    @Binding var resumePlayback: Bool
    @Bindable private var sponsorBlock = SponsorBlockManager.shared

    private let qualityColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardCard(title: "Wi-Fi Quality", icon: "wifi") {
                LazyVGrid(columns: qualityColumns, spacing: 8) {
                    ForEach(PlayerViewModel.selectableQualities, id: \.id) { quality in
                        qualityTile(quality)
                    }
                }
            }

            wizardCard(title: "Playback & Experience", icon: "play.circle.fill") {
                VStack(spacing: 14) {
                    Toggle(isOn: $danmakuEnabled) {
                        Label("Danmaku", systemImage: "bubble.left.and.text.bubble.right").appFont(.rowTitle)
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { backgroundAudio },
                        set: { newValue in
                            backgroundAudio = newValue
                            PlayerPlaybackPreferences.backgroundAudioEnabled = newValue
                            PlayerViewModel.shared.applyPlaybackContinuationSettings()
                        }
                    )) { Label("Background Audio", systemImage: "speaker.wave.2").appFont(.rowTitle) }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { pictureInPicture },
                        set: { newValue in
                            pictureInPicture = newValue
                            PlayerPlaybackPreferences.pictureInPictureEnabled = newValue
                            PlayerViewModel.shared.applyPlaybackContinuationSettings()
                        }
                    )) { Label("Picture in Picture", systemImage: "pip").appFont(.rowTitle) }
                    .disabled(!backgroundAudio)
                    Divider()
                    Toggle(isOn: Binding(
                        get: { inAppMiniPlayer },
                        set: { newValue in
                            inAppMiniPlayer = newValue
                            PlayerPlaybackPreferences.inAppMiniPlayerEnabled = newValue
                            if !newValue {
                                PlayerViewModel.shared.dismissMiniPlayer()
                            }
                        }
                    )) {
                        Label("In-App Mini Player", systemImage: "rectangle.inset.bottomright.filled")
                            .appFont(.rowTitle)
                    }
                    Divider()
                    Toggle(isOn: $sponsorBlock.isEnabled) {
                        Label("Enable SponsorBlock", systemImage: "shield.lefthalf.filled").appFont(.rowTitle)
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { resumePlayback },
                        set: { newValue in
                            resumePlayback = newValue
                            PlayerPlaybackPreferences.resumePlayback = newValue
                        }
                    )) {
                        Label("Resume Last Position", systemImage: "clock.arrow.circlepath").appFont(.rowTitle)
                    }
                }
            }
        }
    }

    private func qualityTile(_ quality: (id: Int, desc: String)) -> some View {
        let isSelected = wifiQuality == quality.id
        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        return Button {
            wifiQuality = quality.id
            PlayerPlaybackPreferences.wifiQuality = quality.id
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.desc)
                        .appFont(.rowTitle)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(qualityNote(quality.id))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.biliAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppFill.inset : Color.primary.opacity(0.035), in: shape)
            .overlay(
                shape.strokeBorder(
                    isSelected ? Color.biliAccent.opacity(0.55) : Color.clear,
                    lineWidth: 1.25
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

private struct SetupWizardNetworkCommunityStep: View {
    private let experiments = ExperimentalSettingsStore.shared

    @Binding var smartCDNEnabled: Bool
    @Binding var blockPCDN: Bool
    @Binding var clipboardLinkDetection: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardCard(title: "Network & Delivery", icon: "server.rack") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { smartCDNEnabled },
                        set: { enabled in
                            smartCDNEnabled = enabled
                            SmartCDNSelector.isEnabled = enabled
                            if enabled {
                                Task { await SmartCDNSelector.shared.warmUp(trigger: "setup wizard", force: true) }
                            } else {
                                SmartCDNSelector.shared.invalidateCache(reason: "setup wizard")
                            }
                        }
                    )) {
                        Label("Smart CDN Selection", systemImage: "wand.and.stars").appFont(.rowTitle)
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { blockPCDN },
                        set: { enabled in
                            blockPCDN = enabled
                            CDNHostPolicy.blockPCDN = enabled
                        }
                    )) {
                        Label("Block PCDN", systemImage: "network.badge.shield.half.filled").appFont(.rowTitle)
                    }
                }
            }

            wizardCard(title: "Browsing & Community", icon: "bubble.left.and.bubble.right.fill") {
                VStack(spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { experiments.isAllowed(.aiCommentFilter) },
                        set: { enabled in
                            guard experiments.storageError == nil else { return }
                            _ = experiments.setGranted(enabled, for: .aiCommentFilter)
                        }
                    )) {
                        Label("AI Comment Filter", systemImage: "sparkle.magnifyingglass").appFont(.rowTitle)
                    }
                    .disabled(experiments.storageError != nil)
                    Divider()
                    Toggle(isOn: $clipboardLinkDetection) {
                        Label("Clipboard Link Detection", systemImage: "doc.on.clipboard")
                            .appFont(.rowTitle)
                    }
                }
            }
        }
    }
}

private struct SetupWizardReadyStep: View {
    let appearanceMode: AppearanceMode
    let selectedTheme: AccentTheme
    let ambientModeEnabled: Bool
    let homeLayout: HomeLayoutMode
    let coverAspect: CoverAspect
    let coverDisplay: CoverDisplayMode
    let detailStartsInStage: Bool
    let wifiQuality: Int
    let danmakuEnabled: Bool
    let backgroundAudio: Bool
    let pictureInPicture: Bool
    let inAppMiniPlayer: Bool
    let sponsorBlockEnabled: Bool
    let resumePlayback: Bool
    let smartCDNEnabled: Bool
    let aiCommentFilterEnabled: Bool
    let onSignIn: () -> Void

    private static let signInPrompt: LocalizedStringKey =
        "Sign in with QR Code, SMS, Password, or Cookie Import to sync your recommendations, favorites, and high-bitrate streams."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardCard(title: "Accounts", icon: "person.crop.circle.fill") {
                if AuthManager.shared.isLoggedIn {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                        Text("Signed in to Bilibili").appFont(.rowTitle).fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Self.signInPrompt).appFont(.messageMeta).foregroundStyle(.secondary)
                        Button(action: onSignIn) {
                            HStack(spacing: 6) {
                                Image(systemName: "qrcode.viewfinder")
                                Text("Log In").appFont(.controlLabel).fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(AccentStore.shared.badgeFill, in: Capsule())
                        }
                        .buttonStyle(.appControl)
                    }
                }
            }

            wizardCard(title: "Summary", icon: "checkmark.circle.fill") {
                VStack(spacing: 10) {
                    let qualityText = PlayerViewModel.qualityMap[wifiQuality] ?? "\(wifiQuality)"
                    summaryRow(label: "Appearance Mode", value: Text(appearanceMode.label))
                    Divider()
                    summaryRow(label: "Color", value: Text(LocalizedStringKey(selectedTheme.rawValue)))
                    Divider()
                    summaryRow(label: "Ambient Mode", value: Text(ambientModeEnabled ? "On" : "Off"))
                    Divider()
                    summaryRow(
                        label: "Homepage Layout",
                        value: Text(homeLayout.label)
                            + Text(verbatim: " / \(coverAspect.label) / \(coverDisplay.label)")
                    )
                    if DeviceCapability.supportsPadDetailSplit {
                        Divider()
                        summaryRow(
                            label: "iPad Detail Layout",
                            value: Text(detailStartsInStage ? "Direct Stage" : "Hero First")
                        )
                    }
                    Divider()
                    summaryRow(label: "Wi-Fi Quality", value: Text(qualityText))
                    Divider()
                    summaryRow(label: "Danmaku", value: Text(danmakuEnabled ? "On" : "Off"))
                    Divider()
                    summaryRow(
                        label: "Background Audio",
                        value: Text(backgroundAudio && pictureInPicture ? "On (PiP)" : backgroundAudio ? "On" : "Off")
                    )
                    Divider()
                    summaryRow(label: "In-App Mini Player", value: Text(inAppMiniPlayer ? "On" : "Off"))
                    Divider()
                    summaryRow(label: "SponsorBlock", value: Text(sponsorBlockEnabled ? "On" : "Off"))
                    Divider()
                    summaryRow(label: "Resume Last Position", value: Text(resumePlayback ? "On" : "Off"))
                    Divider()
                    summaryRow(label: "Smart CDN Selection", value: Text(smartCDNEnabled ? "On" : "Off"))
                    Divider()
                    summaryRow(label: "AI Comment Filter", value: Text(aiCommentFilterEnabled ? "On" : "Off"))
                }
            }
        }
    }

    private func summaryRow(label: LocalizedStringKey, value: Text) -> some View {
        HStack(spacing: 12) {
            Text(label).appFont(.rowMeta).foregroundStyle(.secondary)
            Spacer()
            value
                .appFont(.rowTitle)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

@MainActor
func wizardCard<Content: View>(
    title: LocalizedStringKey,
    icon: String,
    @ViewBuilder content: () -> Content
) -> some View {
    let shape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
    return VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(Color.biliAccent)
            Text(title).font(.headline).foregroundStyle(.primary)
        }
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .appCardSurface(in: shape)
}
