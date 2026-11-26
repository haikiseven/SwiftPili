import SwiftUI

struct SubtitleSettingsView: View {
    let embeddedInSheet: Bool
    private let preferences = SubtitleStylePreferences.shared
    private let player = PlayerViewModel.shared

    init(embeddedInSheet: Bool = false) {
        self.embeddedInSheet = embeddedInSheet
    }

    private var navigationTitleKey: LocalizedStringKey {
        embeddedInSheet ? "Subtitle Style & Defaults" : "Subtitles"
    }

    var body: some View {
        configuredList
            .navigationTitle(navigationTitleKey)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var configuredList: some View {
        if embeddedInSheet {
            Form {
                defaultSubtitlesSection
                translationAndSpeechSection
                appearanceSection
            }
            .accentContentBoundary()
        } else {
            List {
                Group {
                    defaultSubtitlesSection
                    translationAndSpeechSection
                    appearanceSection
                }
                .listRowBackground(AppFill.card)
            }
            .readableFormWidth()
            .accentContentBoundary()
        }
    }

    // MARK: - Section 1: Default Subtitles

    private var defaultSubtitlesSection: some View {
        Section("Default Subtitles") {
            Toggle(isOn: Binding(
                get: { preferences.autoEnableCloudSubtitles },
                set: { preferences.autoEnableCloudSubtitles = $0 }
            )) {
                settingsLabel("Auto Cloud Subtitles", symbol: "captions.bubble")
            }
            .accessibilityIdentifier("settings.subtitles.autoEnableCloud")

            if preferences.autoEnableCloudSubtitles {
                Picker(selection: Binding(
                    get: { preferences.preferredPrimaryLanguage },
                    set: { preferences.preferredPrimaryLanguage = $0 }
                )) {
                    ForEach(SubtitlePreferredLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                } label: {
                    settingsLabel("Primary Language", symbol: "globe")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.subtitles.primaryLanguage")

                Picker(selection: Binding(
                    get: { preferences.preferredSecondaryLanguage },
                    set: { preferences.preferredSecondaryLanguage = $0 }
                )) {
                    ForEach(SubtitlePreferredSecondaryLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                } label: {
                    settingsLabel("Secondary Language", symbol: "captions.bubble.fill")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.subtitles.secondaryLanguage")
            }

            Picker(selection: Binding(
                get: { preferences.autoSpeechMode },
                set: { preferences.autoSpeechMode = $0 }
            )) {
                ForEach(SubtitleAutoSpeechMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingsLabel("Live Speech", symbol: "waveform")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.subtitles.autoSpeechMode")
        }
    }

    // MARK: - Section 2: Translation & Speech

    private var translationAndSpeechSection: some View {
        Section("Translation & Speech") {
            Toggle(isOn: Binding(
                get: { preferences.autoTranslateEnabled },
                set: { enabled in
                    preferences.autoTranslateEnabled = enabled
                    if player.hasAnyActiveSubtitle || player.isAutoTranslationEnabled != enabled {
                        player.setAutoSubtitleTranslationEnabled(enabled)
                    }
                }
            )) {
                settingsLabel("Offline Translation", symbol: "translate")
            }
            .disabled(!player.supportsAutoSubtitleTranslation)
            .accessibilityIdentifier("settings.subtitles.autoTranslate")

            Picker(selection: Binding(
                get: { preferences.translationTargetLanguage },
                set: { player.setSubtitleTranslationTargetLanguage($0) }
            )) {
                ForEach(SubtitleTranslationTargetLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            } label: {
                settingsLabel("Target Language", symbol: "character.bubble")
            }
            .pickerStyle(.menu)
            .disabled(!player.supportsAutoSubtitleTranslation)
            .accessibilityIdentifier("settings.subtitles.translationTarget")

            Picker(selection: Binding(
                get: { preferences.speechLocale },
                set: { player.setSpeechSubtitleLocale($0) }
            )) {
                ForEach(SpeechSubtitleLocale.allCases) { locale in
                    Text(locale.label).tag(locale)
                }
            } label: {
                settingsLabel("Recognition Language", symbol: "mic")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.subtitles.speechLocale")
        }
    }

    // MARK: - Section 3: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: Binding(
                get: { preferences.fontSizeScale },
                set: { preferences.fontSizeScale = $0 }
            )) {
                ForEach(SubtitleFontSizeScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            } label: {
                settingsLabel("Font Size", symbol: "textformat.size")
            }
            .pickerStyle(.menu)

            Picker(selection: Binding(
                get: { preferences.backgroundStyle },
                set: { preferences.backgroundStyle = $0 }
            )) {
                ForEach(SubtitleBackgroundStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            } label: {
                settingsLabel("Background Style", symbol: "rectangle.inset.filled")
            }
            .pickerStyle(.menu)

            if preferences.backgroundStyle == .translucentBox {
                sliderRow(
                    title: "Background Opacity",
                    symbol: "circle.lefthalf.filled",
                    valueLabel: "\(Int((preferences.backgroundOpacity * 100).rounded()))%",
                    value: Binding(
                        get: { preferences.backgroundOpacity },
                        set: { preferences.backgroundOpacity = $0 }
                    ),
                    range: SubtitleStylePreferences.minBackgroundOpacity...SubtitleStylePreferences.maxBackgroundOpacity,
                    step: 0.05
                )
            }

            sliderRow(
                title: "Bottom Offset",
                symbol: "arrow.up.and.down.text.horizontal",
                valueLabel: "\(Int(preferences.bottomOffset.rounded())) pt",
                value: Binding(
                    get: { preferences.bottomOffset },
                    set: { preferences.bottomOffset = $0 }
                ),
                range: SubtitleStylePreferences.minBottomOffset...SubtitleStylePreferences.maxBottomOffset,
                step: 2
            )

            Button {
                preferences.resetAppearanceToDefaults()
            } label: {
                settingsLabel("Reset Appearance", symbol: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - Helpers

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }

    private func sliderRow(
        title: LocalizedStringKey,
        symbol: String,
        valueLabel: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                settingsLabel(title, symbol: symbol)
                Spacer()
                Text(verbatim: valueLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(Text(title))
        }
    }
}
