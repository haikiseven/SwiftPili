import SwiftUI

enum SetupWizardPolicy {
    static let completedStorageKey = "setup_wizard_completed_v1"
}

enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case appearance = 0, playback = 1, ready = 2

    var id: Int { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .appearance: "Appearance"
        case .playback: "Playback"
        case .ready: "Get Started"
        }
    }
    var subtitle: LocalizedStringKey {
        switch self {
        case .appearance: "Choose your preferred theme, accent color, and feed layout."
        case .playback: "Configure default streaming quality, background audio, and SponsorBlock."
        case .ready: "Sign in to sync your Bilibili account or start browsing right away."
        }
    }
    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .playback: "play.tv.fill"
        case .ready: "sparkles"
        }
    }
}

struct SetupWizardView: View {
    @AppStorage(SetupWizardPolicy.completedStorageKey) private var hasCompletedSetup = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(HomeLayoutMode.storageKey) private var homeLayoutRaw = HomeLayoutMode.grid.rawValue

    @State private var currentStep: SetupWizardStep = .appearance
    @State private var selectedTheme: AccentTheme = AccentTheme.current ?? .bilibiliPink
    @State private var coverAspect: CoverAspect = CoverAspect.current
    @State private var wifiQuality: Int = PlayerPlaybackPreferences.wifiQuality
    @State private var backgroundAudio: Bool = PlayerPlaybackPreferences.backgroundAudioEnabled
    @State private var pictureInPicture: Bool = PlayerPlaybackPreferences.pictureInPictureEnabled
    @State private var showLoginSheet = false

    @AppMotion private var motion
    @Environment(\.dismiss) private var dismiss

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepHeader.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { stepContent }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                        .frame(maxWidth: ReadableWidth.form)
                        .frame(maxWidth: .infinity)
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
                coverAspect: $coverAspect
            )
        case .playback:
            SetupWizardPlaybackStep(
                wifiQuality: $wifiQuality,
                backgroundAudio: $backgroundAudio,
                pictureInPicture: $pictureInPicture
            )
        case .ready:
            SetupWizardReadyStep(
                appearanceMode: appearanceMode,
                selectedTheme: selectedTheme,
                homeLayout: HomeLayoutMode(rawValue: homeLayoutRaw) ?? .grid,
                wifiQuality: wifiQuality,
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
    @Binding var appearanceRaw: String
    @Binding var homeLayoutRaw: String
    @Binding var selectedTheme: AccentTheme
    @Binding var coverAspect: CoverAspect

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardCard(title: "Appearance Mode", icon: "moon.circle.fill") {
                HStack(spacing: 10) {
                    ForEach(AppearanceMode.allCases) { mode in
                        pillOption(
                            label: mode.label,
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
                                    label: mode.label,
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
                                    label: LocalizedStringKey(option.label),
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
                }
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
    }

    private func pillOption(
        label: LocalizedStringKey,
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
                        Text(label).appFont(.controlLabel).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                        Text(label).appFont(.controlLabel).fontWeight(isSelected ? .semibold : .regular)
                    }
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, vertical ? 12 : 10)
            .background(fill, in: shape)
        }
        .buttonStyle(.appControl)
    }
}

private struct SetupWizardPlaybackStep: View {
    @Binding var wifiQuality: Int
    @Binding var backgroundAudio: Bool
    @Binding var pictureInPicture: Bool
    @Bindable private var sponsorBlock = SponsorBlockManager.shared
    @AppStorage(DetailStagePreferences.startsInStageKey) private var detailStartsInStage = false

    private let primaryQualities: [(id: Int, label: String)] = [
        (120, "4K Ultra HD"), (116, "1080P 60fps"), (112, "1080P+ High Bitrate"),
        (80, "1080P HD"), (64, "720P")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardCard(title: "Wi-Fi Quality", icon: "wifi") {
                VStack(spacing: 6) {
                    ForEach(primaryQualities, id: \.id) { item in
                        let isSelected = wifiQuality == item.id
                        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        Button {
                            wifiQuality = item.id
                            PlayerPlaybackPreferences.wifiQuality = item.id
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(item.label)).appFont(.rowTitle).foregroundStyle(.primary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.biliAccent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(isSelected ? AppFill.inset : Color.clear, in: shape)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            wizardCard(title: "Playback", icon: "pip") {
                VStack(spacing: 14) {
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
                    Toggle(isOn: $sponsorBlock.isEnabled) {
                        Label("Enable SponsorBlock", systemImage: "shield.lefthalf.filled").appFont(.rowTitle)
                    }
                }
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                SetupWizardDetailLayoutCard()
            }
        }
    }
}

private struct SetupWizardReadyStep: View {
    let appearanceMode: AppearanceMode
    let selectedTheme: AccentTheme
    let homeLayout: HomeLayoutMode
    let wifiQuality: Int
    let onSignIn: () -> Void

    private static let signInPrompt: LocalizedStringKey =
        "Sign in with QR code or web login to sync your recommendations, favorites, and 1080P60/4K streams."

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
                    summaryRow(label: "Appearance Mode", value: appearanceMode.label)
                    Divider()
                    summaryRow(label: "Color", value: LocalizedStringKey(selectedTheme.rawValue))
                    Divider()
                    summaryRow(label: "Homepage Layout", value: homeLayout.label)
                    Divider()
                    summaryRow(label: "Wi-Fi Quality", value: LocalizedStringKey(qualityText))
                }
            }
        }
    }

    private func summaryRow(label: LocalizedStringKey, value: LocalizedStringKey) -> some View {
        HStack {
            Text(label).appFont(.rowMeta).foregroundStyle(.secondary)
            Spacer()
            Text(value).appFont(.rowTitle).fontWeight(.medium).foregroundStyle(.primary)
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
