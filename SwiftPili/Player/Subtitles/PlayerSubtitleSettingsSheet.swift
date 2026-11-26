import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlayerSubtitleSettingsSheet: View {
    let player: PlayerViewModel
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                SubtitlePlayerSettingsPanel(
                    player: player,
                    surface: .sheet,
                    onClose: closeSheet
                )
                .presentationSizing(.fitted)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
            } else {
                SubtitlePlayerSettingsPanel(
                    player: player,
                    surface: .sheet,
                    onClose: closeSheet
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
            }
        }
        .accentContentBoundary()
        .onAppear {
            player.setDanmakuSettingsHold(true)
        }
        .onDisappear {
            player.setDanmakuSettingsHold(false)
        }
    }

    private func closeSheet() {
        if let onClose {
            onClose()
        }
        dismiss()
    }
}

struct SubtitlePlayerSettingsPanel: View {
    enum Surface {
        case overlay
        case sheet
    }

    let player: PlayerViewModel
    var surface: Surface = .sheet
    let onClose: () -> Void

    private let preferences = SubtitleStylePreferences.shared
    @State private var fileImporterPresented = false
    @State private var importErrorMessage: String?
    @State private var isDownloadingModel = false

    private enum SecondarySubtitleSelection: Hashable {
        case none
        case autoTranslate
        case track(String)
    }

    private var allowedSubtitleTypes: [UTType] {
        var types: [UTType] = []
        if let srt = UTType(filenameExtension: "srt") {
            types.append(srt)
        }
        if let vtt = UTType(filenameExtension: "vtt") {
            types.append(vtt)
        }
        types.append(.plainText)
        types.append(.data)
        return types
    }

    private var cloudTracks: [(lan: String, item: PlayerV2Info.SubtitleBox.SubtitleItem)] {
        player.availableSubtitles.compactMap { item in
            guard let lan = item.lan, !lan.isEmpty else { return nil }
            return (lan: lan, item: item)
        }
    }

    private var secondaryCloudTracks: [(lan: String, item: PlayerV2Info.SubtitleBox.SubtitleItem)] {
        cloudTracks.filter { $0.lan != player.activeSubtitleLan }
    }

    private var secondaryLocalTracks: [ImportedSubtitleTrack] {
        player.importedSubtitleTracks.filter { $0.id != player.activeSubtitleLan }
    }

    private var canSelectSystemSpeechAsSecondary: Bool {
        player.supportsSystemSpeechSubtitles
            && !PlayerSubtitleTrackID.isSystemSpeech(player.activeSubtitleLan)
    }

    private var shouldShowBilingualAndLanguageSection: Bool {
        player.hasAnyActiveSubtitle
            || player.isAutoTranslationEnabled
            || player.isSpeechSubtitleEnabled
    }

    private var isDefaultAppearance: Bool {
        preferences.fontSizeScale == .standard
            && preferences.backgroundStyle == .translucentBox
            && abs(preferences.backgroundOpacity - SubtitleStylePreferences.defaultBackgroundOpacity) < 0.005
            && abs(preferences.bottomOffset - SubtitleStylePreferences.defaultBottomOffset) < 0.5
    }

    private var secondarySelection: SecondarySubtitleSelection {
        if let secondaryLan = player.secondarySubtitleLan,
           !secondaryLan.isEmpty,
           secondaryLan != player.activeSubtitleLan {
            let matchesCloud = secondaryCloudTracks.contains { $0.lan == secondaryLan }
            let matchesLocal = secondaryLocalTracks.contains { $0.id == secondaryLan }
            let matchesSpeech = canSelectSystemSpeechAsSecondary
                && PlayerSubtitleTrackID.isSystemSpeech(secondaryLan)
            if matchesCloud || matchesLocal || matchesSpeech {
                return .track(secondaryLan)
            }
        }
        if player.isAutoTranslationEnabled && player.supportsAutoSubtitleTranslation {
            return .autoTranslate
        }
        return .none
    }

    private var secondarySelectionLabel: String {
        switch secondarySelection {
        case .none:
            return String(localized: "Off")
        case .autoTranslate:
            return String(localized: "Offline Translation")
        case .track(let id):
            if PlayerSubtitleTrackID.isSystemSpeech(id) {
                return String(localized: "Live Speech")
            }
            if let cloud = secondaryCloudTracks.first(where: { $0.lan == id }) {
                return cloud.item.menuDisplayTitle
            }
            if let local = secondaryLocalTracks.first(where: { $0.id == id }) {
                return local.displayName
            }
            return String(localized: "Off")
        }
    }

    var body: some View {
        Group {
            switch surface {
            case .overlay:
                let panelShape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                let overlayContent = controls
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                ViewThatFits(in: .vertical) {
                    overlayContent
                    ScrollView {
                        overlayContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: 344)
                .clipShape(panelShape)
                .appGlass(in: panelShape)
                .environment(\.colorScheme, .dark)
            case .sheet:
                let sheetContent = controls
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 16)
                ViewThatFits(in: .vertical) {
                    sheetContent
                    ScrollView {
                        sheetContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .background {
            SubtitleTranslationHostBridge(player: player, priority: 2)
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: allowedSubtitleTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: surface == .overlay ? 10 : 13) {
            headerRow

            primaryTrackSection

            if shouldShowBilingualAndLanguageSection {
                bilingualAndLanguageSection
            }

            panelDivider

            appearanceSection

            panelDivider

            actionsSection
        }
        .font(.subheadline)
        .accentContentBoundary()
    }

    private var panelDivider: some View {
        Divider()
            .opacity(surface == .overlay ? 0.22 : 0.45)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Subtitles")
                .font(surface == .overlay ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(surface == .overlay ? Color.white : Color.primary)

            Spacer(minLength: 8)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                preferences.resetAppearanceToDefaults()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                    Text("Reset")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(
                    surface == .overlay
                        ? Color.white.opacity(isDefaultAppearance ? 0.35 : 0.88)
                        : (isDefaultAppearance ? Color.secondary.opacity(0.45) : Color.biliAccent)
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    surface == .overlay ? Color.white.opacity(0.10) : AppFill.inset,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(isDefaultAppearance)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(surface == .overlay ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        surface == .overlay ? Color.white.opacity(0.12) : AppFill.inset,
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    // MARK: - Section 1: Primary Subtitle Pills

    private var primaryTrackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowHeaderLabel("Primary Language", symbol: "captions.bubble")

            FlowLayout(spacing: 6) {
                let offSelected = !player.hasAnyActiveSubtitle
                trackPill(
                    isSelected: offSelected,
                    action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.turnOffAllSubtitles()
                    },
                    label: {
                        Text("Off")
                            .font(.caption.weight(offSelected ? .semibold : .medium))
                    }
                )
                .accessibilityIdentifier("player.subtitles.primary.off")
                .accessibilityAddTraits(offSelected ? .isSelected : [])

                ForEach(Array(cloudTracks.enumerated()), id: \.offset) { _, entry in
                    let isSelected = player.activeSubtitleLan == entry.lan
                    trackPill(
                        isSelected: isSelected,
                        action: {
                            guard !isSelected else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await player.selectPrimarySubtitleTrack(id: entry.lan) }
                        },
                        label: {
                            HStack(spacing: 4) {
                                Text(entry.item.displayTitle)
                                    .font(.caption.weight(isSelected ? .semibold : .medium))
                                    .lineLimit(1)
                                if entry.item.isAIGenerated {
                                    Text(verbatim: "AI")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(
                                            isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.10),
                                            in: Capsule()
                                        )
                                }
                            }
                        }
                    )
                    .accessibilityIdentifier("player.subtitles.primary.cloud.\(entry.lan)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                ForEach(player.importedSubtitleTracks) { track in
                    let isSelected = player.activeSubtitleLan == track.id
                    HStack(spacing: 2) {
                        trackPill(
                            isSelected: isSelected,
                            action: {
                                guard !isSelected else { return }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                Task { await player.selectPrimarySubtitleTrack(id: track.id) }
                            },
                            label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text")
                                        .font(.caption2.weight(.semibold))
                                    Text(track.displayName)
                                        .font(.caption.weight(isSelected ? .semibold : .medium))
                                        .lineLimit(1)
                                }
                            }
                        )
                        .accessibilityIdentifier("player.subtitles.primary.local.\(track.id)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])

                        Button(role: .destructive) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            player.removeImportedSubtitleTrack(id: track.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(surface == .overlay ? Color.white.opacity(0.6) : Color.secondary)
                                .frame(width: 22, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove"))
                    }
                }

                if player.supportsSystemSpeechSubtitles {
                    let isSelected = PlayerSubtitleTrackID.isSystemSpeech(player.activeSubtitleLan)
                    trackPill(
                        isSelected: isSelected,
                        action: {
                            guard !isSelected else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await player.selectPrimarySubtitleTrack(id: PlayerSubtitleTrackID.systemSpeech) }
                        },
                        label: {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform")
                                    .font(.caption2.weight(.semibold))
                                Text("Live Speech")
                                    .font(.caption.weight(isSelected ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                        }
                    )
                    .accessibilityIdentifier("player.subtitles.primary.speech")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            if cloudTracks.isEmpty,
               player.importedSubtitleTracks.isEmpty,
               !player.supportsSystemSpeechSubtitles,
               player.mode.usesOnlineVODServices {
                Label("No Bilibili cloud subtitles for this video", systemImage: "captions.bubble")
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
            }
        }
    }

    // MARK: - Section 2: Bilingual & Language Rows

    private var bilingualAndLanguageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                rowHeaderLabel("Secondary Subtitle", symbol: "captions.bubble.fill")
                Spacer(minLength: 6)
                Menu {
                    Button {
                        selectSecondary(.none)
                    } label: {
                        HStack {
                            Text("Off")
                            if secondarySelection == .none { Image(systemName: "checkmark") }
                        }
                    }

                    if player.supportsAutoSubtitleTranslation {
                        Button {
                            selectSecondary(.autoTranslate)
                        } label: {
                            HStack {
                                Text("Offline Translation")
                                if secondarySelection == .autoTranslate { Image(systemName: "checkmark") }
                            }
                        }
                    }

                    ForEach(Array(secondaryCloudTracks.enumerated()), id: \.offset) { _, entry in
                        Button {
                            selectSecondary(.track(entry.lan))
                        } label: {
                            HStack {
                                Text(entry.item.menuDisplayTitle)
                                if secondarySelection == .track(entry.lan) { Image(systemName: "checkmark") }
                            }
                        }
                    }

                    ForEach(secondaryLocalTracks) { track in
                        Button {
                            selectSecondary(.track(track.id))
                        } label: {
                            HStack {
                                Text(track.displayName)
                                if secondarySelection == .track(track.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }

                    if canSelectSystemSpeechAsSecondary {
                        Button {
                            selectSecondary(.track(PlayerSubtitleTrackID.systemSpeech))
                        } label: {
                            HStack {
                                Text("Live Speech")
                                if secondarySelection == .track(PlayerSubtitleTrackID.systemSpeech) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    menuCapsuleLabel(secondarySelectionLabel, isActive: secondarySelection != .none)
                }
                .disabled(
                    player.activeSubtitleLan == nil
                        && !player.isAutoTranslationEnabled
                        && player.secondarySubtitleLan == nil
                )
                .accessibilityIdentifier("player.subtitles.secondaryPicker")
            }

            if player.isAutoTranslationEnabled {
                HStack(spacing: 8) {
                    rowHeaderLabel("Target Language", symbol: "translate")
                    Spacer(minLength: 6)
                    Menu {
                        ForEach(SubtitleTranslationTargetLanguage.allCases) { language in
                            Button {
                                player.setSubtitleTranslationTargetLanguage(language)
                            } label: {
                                HStack {
                                    Text(language.label)
                                    if language == player.subtitleTranslationTargetLanguage {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        menuCapsuleLabel(player.subtitleTranslationTargetLanguage.label, isActive: true)
                    }
                    .disabled(!player.supportsAutoSubtitleTranslation)
                    .accessibilityIdentifier("player.subtitles.translationTargetPicker")
                }

                translationStatusRow
            }

            if player.isSpeechSubtitleEnabled {
                HStack(spacing: 8) {
                    rowHeaderLabel("Recognition Language", symbol: "mic")
                    Spacer(minLength: 6)
                    Menu {
                        ForEach(SpeechSubtitleLocale.allCases) { locale in
                            Button {
                                player.setSpeechSubtitleLocale(locale)
                            } label: {
                                HStack {
                                    Text(locale.label)
                                    if locale == player.speechSubtitleLocale {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        menuCapsuleLabel(player.speechSubtitleLocale.label, isActive: true)
                    }
                    .disabled(!player.supportsSystemSpeechSubtitles)
                    .accessibilityIdentifier("player.subtitles.speechLocalePicker")
                }

                speechStatusRow

                if player.speechSubtitleCanDownloadModel {
                    Button {
                        guard !isDownloadingModel else { return }
                        isDownloadingModel = true
                        Task {
                            _ = await player.downloadSpeechAnalyzerModel()
                            isDownloadingModel = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption.weight(.semibold))
                            Text("Download Offline Speech Model")
                                .font(.caption.weight(.medium))
                            Spacer(minLength: 4)
                            if isDownloadingModel {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .foregroundStyle(Color.biliAccent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(capsuleUnselectedFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloadingModel)
                }
            }
        }
    }

    private func selectSecondary(_ value: SecondarySubtitleSelection) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch value {
        case .none:
            player.setAutoSubtitleTranslationEnabled(false)
            Task { await player.selectSecondarySubtitleTrack(id: nil) }
        case .autoTranslate:
            player.setAutoSubtitleTranslationEnabled(true)
        case .track(let trackID):
            player.setAutoSubtitleTranslationEnabled(false)
            Task { await player.selectSecondarySubtitleTrack(id: trackID) }
        }
    }

    // MARK: - Section 3: Appearance Controls (Danmaku-Style Segments & Steppers)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: surface == .overlay ? 8 : 10) {
            VStack(alignment: .leading, spacing: 6) {
                rowHeaderLabel("Font Size", symbol: "textformat.size")
                HStack(spacing: 5) {
                    ForEach(SubtitleFontSizeScale.allCases) { scale in
                        let selected = preferences.fontSizeScale == scale
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            preferences.fontSizeScale = scale
                        } label: {
                            Text(scale.label)
                                .font(.caption.weight(selected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(pillForeground(isSelected: selected))
                                .padding(.horizontal, 6)
                                .padding(.vertical, surface == .overlay ? 5.5 : 7)
                                .frame(maxWidth: .infinity)
                                .background(pillBackground(isSelected: selected), in: Capsule())
                                .overlay {
                                    Capsule()
                                        .strokeBorder(pillStroke(isSelected: selected), lineWidth: 0.8)
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                rowHeaderLabel("Background Style", symbol: "rectangle.inset.filled")
                HStack(spacing: 5) {
                    ForEach(SubtitleBackgroundStyle.allCases) { style in
                        let selected = preferences.backgroundStyle == style
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            preferences.backgroundStyle = style
                        } label: {
                            Text(style.label)
                                .font(.caption.weight(selected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(pillForeground(isSelected: selected))
                                .padding(.horizontal, 6)
                                .padding(.vertical, surface == .overlay ? 5.5 : 7)
                                .frame(maxWidth: .infinity)
                                .background(pillBackground(isSelected: selected), in: Capsule())
                                .overlay {
                                    Capsule()
                                        .strokeBorder(pillStroke(isSelected: selected), lineWidth: 0.8)
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if preferences.backgroundStyle == .translucentBox {
                stepperRow(
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

            stepperRow(
                title: "Bottom Offset",
                symbol: "arrow.up.and.down.text.horizontal",
                valueLabel: "\(Int(preferences.bottomOffset.rounded())) pt",
                value: Binding(
                    get: { preferences.bottomOffset },
                    set: { preferences.bottomOffset = $0 }
                ),
                range: SubtitleStylePreferences.minBottomOffset...SubtitleStylePreferences.maxBottomOffset,
                step: 4
            )
        }
        .accessibilityIdentifier("player.subtitles.styleAndDefaults")
    }

    // MARK: - Section 4: Actions & Auto-Enable Cloud Pill

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    importErrorMessage = nil
                    fileImporterPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.badge.plus")
                            .font(.caption.weight(.semibold))
                        Text("Import Local Subtitle (.srt / .vtt)")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(surface == .overlay ? Color.white.opacity(0.92) : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7.5)
                    .frame(maxWidth: .infinity)
                    .background(capsuleUnselectedFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(pillStroke(isSelected: false), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("player.subtitles.importButton")

                let autoCloud = preferences.autoEnableCloudSubtitles
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    preferences.autoEnableCloudSubtitles.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: autoCloud ? "checkmark" : "captions.bubble")
                            .font(.caption2.weight(.semibold))
                        Text("Auto Cloud Subtitles")
                            .font(.caption.weight(autoCloud ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(pillForeground(isSelected: autoCloud))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7.5)
                    .background(pillBackground(isSelected: autoCloud), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(pillStroke(isSelected: autoCloud), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
            }

            if let importErrorMessage {
                Label(importErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Status Rows

    @ViewBuilder
    private var translationStatusRow: some View {
        switch player.subtitleTranslationStatus {
        case .idle:
            EmptyView()
        case .waitingForPrimaryTrack:
            Label("Select a primary subtitle track to begin auto-translation.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(secondaryTextColor)
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing offline translation…")
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
            }
        case .translating(let completed, let total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(format: String(localized: "Translating %lld / %lld cues…"), completed, total))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }
        case .ready(let translatedCount, let totalCount):
            Label(
                String(format: String(localized: "Translated %lld / %lld cues"), translatedCount, totalCount),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption2)
            .foregroundStyle(.green)
        case .liveActive:
            Label("Translating live speech on-device", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .sameLanguage:
            Label("Primary subtitle already matches the target language.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .unsupportedPair:
            Label("Selected language pair is not supported on this device.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Retry") {
                    player.retrySubtitleTranslation()
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.biliAccent)
            }
        }
    }

    @ViewBuilder
    private var speechStatusRow: some View {
        switch player.speechSubtitleStatus {
        case .idle:
            EmptyView()
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing speech recognizer…")
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
            }
        case .downloadingModel:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading offline speech model…")
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
            }
        case .active(let engine, let localeID):
            HStack(spacing: 6) {
                Text("Speech Engine")
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
                Spacer(minLength: 4)
                Text("\(engine.displayLabel) (\(localeID))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(secondaryTextColor)
            }
        case .unsupportedBackend:
            Label("Unavailable on current playback engine", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(secondaryTextColor)
        case .permissionDenied:
            HStack(spacing: 8) {
                Label("Speech recognition permission denied", systemImage: "lock.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.biliAccent)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Shared Styling Helpers

    private var secondaryTextColor: Color {
        surface == .overlay ? Color.white.opacity(0.68) : Color.secondary
    }

    private var capsuleUnselectedFill: Color {
        surface == .overlay ? Color.white.opacity(0.10) : AppFill.inset
    }

    private func rowHeaderLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryTextColor)
                .frame(width: 14)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(surface == .overlay ? Color.white.opacity(0.86) : Color.secondary)
        }
    }

    private func trackPill<LabelView: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> LabelView
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(pillForeground(isSelected: isSelected))
                .padding(.horizontal, 11)
                .padding(.vertical, surface == .overlay ? 6 : 7)
                .background(pillBackground(isSelected: isSelected), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(pillStroke(isSelected: isSelected), lineWidth: 0.8)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
    }

    private func menuCapsuleLabel(_ text: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: text)
                .font(.caption.weight(isActive ? .semibold : .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(pillForeground(isSelected: isActive))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(pillBackground(isSelected: isActive), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(pillStroke(isSelected: isActive), lineWidth: 0.8)
        }
        .contentShape(Capsule())
    }

    private func stepperRow(
        title: LocalizedStringKey,
        symbol: String,
        valueLabel: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        let canDecrement = value.wrappedValue > range.lowerBound + 0.0001
        let canIncrement = value.wrappedValue < range.upperBound - 0.0001
        return HStack(spacing: 8) {
            rowHeaderLabel(title, symbol: symbol)
            Spacer(minLength: 6)
            Text(verbatim: valueLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(surface == .overlay ? Color.white.opacity(0.92) : Color.primary)
                .frame(minWidth: 44, alignment: .trailing)

            HStack(spacing: 0) {
                Button {
                    guard canDecrement else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canDecrement)
                .opacity(canDecrement ? 1.0 : 0.35)

                Divider()
                    .frame(height: 14)
                    .opacity(0.35)

                Button {
                    guard canIncrement else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canIncrement)
                .opacity(canIncrement ? 1.0 : 0.35)
            }
            .foregroundStyle(surface == .overlay ? Color.white : Color.primary)
            .background(capsuleUnselectedFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(pillStroke(isSelected: false), lineWidth: 0.8)
            }
        }
    }

    private func pillForeground(isSelected: Bool) -> Color {
        if isSelected {
            return surface == .overlay ? .white : Color.biliAccent
        }
        return surface == .overlay ? Color.white.opacity(0.84) : Color.primary
    }

    private func pillBackground(isSelected: Bool) -> Color {
        if isSelected {
            return surface == .overlay
                ? Color.biliAccent.opacity(0.82)
                : Color.biliAccent.opacity(0.15)
        }
        return capsuleUnselectedFill
    }

    private func pillStroke(isSelected: Bool) -> Color {
        if isSelected {
            return surface == .overlay ? Color.white.opacity(0.26) : Color.biliAccent.opacity(0.48)
        }
        return surface == .overlay ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                _ = try player.importLocalSubtitle(from: url)
                importErrorMessage = nil
            } catch {
                importErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }
}
