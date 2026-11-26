import SwiftUI
import UIKit

enum DanmakuAreaPreset: CaseIterable, Identifiable, Sendable {
    case quarter
    case half
    case threeQuarters
    case full

    var id: Self { self }

    var fraction: Double {
        switch self {
        case .quarter: 0.25
        case .half: 0.50
        case .threeQuarters: 0.75
        case .full: 1.00
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .quarter: "1/4 Screen"
        case .half: "Half Screen"
        case .threeQuarters: "3/4 Screen"
        case .full: "Full Screen Area"
        }
    }

    static func matching(_ rawArea: Double) -> Self? {
        let effective = DanmakuRenderPreferences.effectiveDisplayArea(rawArea)
        return allCases.first { abs($0.fraction - effective) < 0.03 }
    }
}

enum DanmakuSpeedPreset: CaseIterable, Identifiable, Sendable {
    case verySlow
    case slow
    case standard
    case fast
    case veryFast

    var id: Self { self }

    var scrollLifetime: Double {
        switch self {
        case .verySlow: 15.0
        case .slow: 12.0
        case .standard: DanmakuRenderPreferences.defaultScrollLifetime
        case .fast: 6.5
        case .veryFast: 4.0
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .verySlow: "DanmakuSpeedVerySlow"
        case .slow: "DanmakuSpeedSlow"
        case .standard: "DanmakuSpeedStandard"
        case .fast: "DanmakuSpeedFast"
        case .veryFast: "DanmakuSpeedVeryFast"
        }
    }

    static func nearest(for lifetime: Double) -> Self {
        let clamped = min(
            DanmakuRenderPreferences.scrollLifetimeRange.upperBound,
            max(DanmakuRenderPreferences.scrollLifetimeRange.lowerBound, lifetime)
        )
        return allCases.min {
            abs($0.scrollLifetime - clamped) < abs($1.scrollLifetime - clamped)
        } ?? .standard
    }
}

struct DanmakuSettingsView: View {
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var enabled = false
    @AppStorage(DanmakuRenderPreferences.opacityKey)
    private var opacity = DanmakuRenderPreferences.defaultOpacity
    @AppStorage(DanmakuRenderPreferences.fontScaleKey)
    private var fontScale = DanmakuRenderPreferences.defaultFontScale
    @AppStorage(DanmakuRenderPreferences.fullscreenFontScaleKey)
    private var storedFullscreenFontScale: Double?
    @AppStorage(DanmakuRenderPreferences.scrollLifetimeKey)
    private var scrollLifetime = DanmakuRenderPreferences.defaultScrollLifetime
    @AppStorage(DanmakuRenderPreferences.displayAreaKey)
    private var displayArea = DanmakuRenderPreferences.defaultDisplayArea
    @AppStorage(DanmakuRenderPreferences.showScrollKey) private var showScroll = true
    @AppStorage(DanmakuRenderPreferences.showTopKey) private var showTop = true
    @AppStorage(DanmakuRenderPreferences.showBottomKey) private var showBottom = true
    @AppStorage(DanmakuRenderPreferences.avoidOverlapKey)
    private var avoidsOverlap = DanmakuRenderPreferences.defaultAvoidOverlap
    @AppStorage(DanmakuRenderPreferences.smartMaskKey)
    private var smartMask = DanmakuRenderPreferences.defaultSmartMask
    @State private var keywordDraft = ""
    @State private var keywords = DanmakuRenderPreferences.load().blockedKeywords

    var body: some View {
        List {
            Group {
                masterSection
                if enabled {
                    appearanceSection
                    filterSection
                }
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Danmaku")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var masterSection: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label {
                    Text("Show Danmaku")
                } icon: {
                    SettingsIcon(symbol: "bubble.left.and.text.bubble.right")
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Display") {
            DanmakuTypeSelectorRow(
                showScroll: $showScroll,
                showTop: $showTop,
                showBottom: $showBottom,
                surface: .settings
            )
            DanmakuAreaSelectorRow(
                displayArea: $displayArea,
                surface: .settings
            )
            DanmakuSpeedSelectorRow(
                scrollLifetime: $scrollLifetime,
                surface: .settings
            )
            DanmakuValueStepperRow(
                title: "Opacity",
                accessibilityTitle: String(localized: "Opacity"),
                symbol: "circle.lefthalf.filled",
                valueLabel: danmakuPercent(opacity),
                value: $opacity,
                range: DanmakuRenderPreferences.opacityRange,
                step: 0.05,
                surface: .settings
            )
            DanmakuValueStepperRow(
                title: "Font Size",
                accessibilityTitle: String(localized: "Font Size"),
                symbol: "textformat.size",
                valueLabel: danmakuPercent(fontScale),
                value: inlineFontScale,
                range: DanmakuRenderPreferences.fontScaleRange,
                step: 0.1,
                surface: .settings
            )
            DanmakuValueStepperRow(
                title: "Fullscreen Font Size",
                accessibilityTitle: String(localized: "Fullscreen Font Size"),
                symbol: "arrow.up.left.and.arrow.down.right",
                valueLabel: danmakuPercent(fullscreenFontScale.wrappedValue),
                value: fullscreenFontScale,
                range: DanmakuRenderPreferences.fontScaleRange,
                step: 0.1,
                surface: .settings
            )
            Toggle(isOn: $smartMask) {
                Label {
                    Text("Smart Anti-Occlusion")
                } icon: {
                    SettingsIcon(symbol: "person.crop.rectangle")
                }
            }
            Toggle(isOn: $avoidsOverlap) {
                Label {
                    Text("Keep Subtitles Clear")
                } icon: {
                    SettingsIcon(symbol: "captions.bubble")
                }
            }
        }
    }

    private var filterSection: some View {
        Section("Blocked Keywords") {
            HStack {
                TextField("Blocked Keywords", text: $keywordDraft)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword)
                    .disabled(keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(keywords, id: \.self) { keyword in
                Text(verbatim: keyword)
            }
            .onDelete(perform: deleteKeywords)
        }
    }

    private func addKeyword() {
        let text = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !keywords.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else {
            keywordDraft = ""
            return
        }
        keywords.append(text)
        keywordDraft = ""
        UserDefaults.standard.set(keywords, forKey: DanmakuRenderPreferences.blockKeywordsKey)
    }

    private func deleteKeywords(at offsets: IndexSet) {
        keywords.remove(atOffsets: offsets)
        UserDefaults.standard.set(keywords, forKey: DanmakuRenderPreferences.blockKeywordsKey)
    }

    private var inlineFontScale: Binding<Double> {
        danmakuInlineFontScale(stored: fontScale)
    }

    private var fullscreenFontScale: Binding<Double> {
        danmakuFullscreenFontScale(stored: $storedFullscreenFontScale, inline: fontScale)
    }
}

private func danmakuFullscreenFontScale(stored: Binding<Double?>, inline: Double) -> Binding<Double> {
    Binding(
        get: { stored.wrappedValue ?? inline },
        set: { stored.wrappedValue = $0 }
    )
}

private func danmakuInlineFontScale(stored: Double) -> Binding<Double> {
    Binding(
        get: { stored },
        set: { DanmakuRenderPreferences.setInlineFontScale($0) }
    )
}

private func danmakuPercent(_ value: Double) -> String {
    let whole = Int((value * 100).rounded())
    return "\(whole)%"
}

// MARK: - Player Sheet Wrapper (Inline & Portrait Fullscreen)

struct PlayerDanmakuSettingsSheet: View {
    let presentation: DanmakuPresentation
    let onClose: () -> Void

    var body: some View {
        DanmakuPlayerSettingsPanel(
            presentation: presentation,
            surface: .sheet,
            onClose: onClose
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .accentContentBoundary()
        .appAdaptiveSheet(
            compactDetents: [PresentationDetent.height(352)],
            padSizing: .form,
            dragIndicator: .visible
        )
    }
}

// MARK: - In-Player Danmaku Settings Panel

struct DanmakuPlayerSettingsPanel: View {
    let presentation: DanmakuPresentation
    enum Surface { case overlay, sheet }
    var surface: Surface = .overlay
    let onClose: () -> Void

    @AppStorage(DanmakuRenderPreferences.opacityKey)
    private var opacity = DanmakuRenderPreferences.defaultOpacity
    @AppStorage(DanmakuRenderPreferences.fontScaleKey)
    private var fontScale = DanmakuRenderPreferences.defaultFontScale
    @AppStorage(DanmakuRenderPreferences.fullscreenFontScaleKey)
    private var storedFullscreenFontScale: Double?
    @AppStorage(DanmakuRenderPreferences.scrollLifetimeKey)
    private var scrollLifetime = DanmakuRenderPreferences.defaultScrollLifetime
    @AppStorage(DanmakuRenderPreferences.displayAreaKey)
    private var displayArea = DanmakuRenderPreferences.defaultDisplayArea
    @AppStorage(DanmakuRenderPreferences.avoidOverlapKey)
    private var avoidsOverlap = DanmakuRenderPreferences.defaultAvoidOverlap
    @AppStorage(DanmakuRenderPreferences.smartMaskKey)
    private var smartMask = DanmakuRenderPreferences.defaultSmartMask
    @AppStorage(DanmakuRenderPreferences.showScrollKey) private var showScroll = true
    @AppStorage(DanmakuRenderPreferences.showTopKey) private var showTop = true
    @AppStorage(DanmakuRenderPreferences.showBottomKey) private var showBottom = true

    private var controlSurface: DanmakuControlSurface {
        surface == .overlay ? .overlay : .sheet
    }

    private var isDefaultConfiguration: Bool {
        abs(opacity - DanmakuRenderPreferences.defaultOpacity) < 0.005
            && abs(presentedFontScale.wrappedValue - DanmakuRenderPreferences.defaultFontScale) < 0.005
            && abs(scrollLifetime - DanmakuRenderPreferences.defaultScrollLifetime) < 0.05
            && abs(
                DanmakuRenderPreferences.effectiveDisplayArea(displayArea)
                    - DanmakuRenderPreferences.defaultDisplayArea
            ) < 0.005
            && smartMask == DanmakuRenderPreferences.defaultSmartMask
            && avoidsOverlap == DanmakuRenderPreferences.defaultAvoidOverlap
            && showScroll && showTop && showBottom
    }

    var body: some View {
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
            .frame(width: 336)
            .clipShape(panelShape)
            .appGlass(in: panelShape)
            .environment(\.colorScheme, .dark)
        case .sheet:
            let sheetContent = controls
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)
            ViewThatFits(in: .vertical) {
                sheetContent
                ScrollView {
                    sheetContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: surface == .overlay ? 9 : 12) {
            headerRow

            DanmakuTypeSelectorRow(
                showScroll: $showScroll,
                showTop: $showTop,
                showBottom: $showBottom,
                surface: controlSurface
            )

            protectionPillsRow

            DanmakuAreaSelectorRow(
                displayArea: $displayArea,
                surface: controlSurface
            )

            DanmakuSpeedSelectorRow(
                scrollLifetime: $scrollLifetime,
                surface: controlSurface
            )

            DanmakuValueStepperRow(
                title: "Opacity",
                accessibilityTitle: String(localized: "Opacity"),
                symbol: "circle.lefthalf.filled",
                valueLabel: danmakuPercent(opacity),
                value: $opacity,
                range: DanmakuRenderPreferences.opacityRange,
                step: 0.05,
                surface: controlSurface
            )

            DanmakuValueStepperRow(
                title: presentation == .fullscreen ? "Fullscreen Font Size" : "Font Size",
                accessibilityTitle: presentation == .fullscreen
                    ? String(localized: "Fullscreen Font Size")
                    : String(localized: "Font Size"),
                symbol: "textformat.size",
                valueLabel: danmakuPercent(presentedFontScale.wrappedValue),
                value: presentedFontScale,
                range: DanmakuRenderPreferences.fontScaleRange,
                step: 0.1,
                surface: controlSurface
            )
        }
        .font(.subheadline)
        .accentContentBoundary()
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Danmaku Settings")
                .font(surface == .overlay ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(surface == .overlay ? Color.white : Color.primary)

            Spacer(minLength: 8)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                resetToDefaults()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                    Text("Reset")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(
                    surface == .overlay
                        ? Color.white.opacity(isDefaultConfiguration ? 0.35 : 0.88)
                        : (isDefaultConfiguration ? Color.secondary.opacity(0.45) : Color.biliAccent)
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    surface == .overlay ? Color.white.opacity(0.10) : AppFill.inset,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(isDefaultConfiguration)

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

    private var protectionPillsRow: some View {
        HStack(spacing: 6) {
            DanmakuTogglePill(
                title: "Smart Anti-Occlusion",
                symbol: "person.crop.rectangle",
                isOn: $smartMask,
                equalWidth: true,
                surface: controlSurface
            )
            DanmakuTogglePill(
                title: "Keep Subtitles Clear",
                symbol: "captions.bubble",
                isOn: $avoidsOverlap,
                equalWidth: true,
                surface: controlSurface
            )
        }
    }

    private var presentedFontScale: Binding<Double> {
        switch presentation {
        case .inline: danmakuInlineFontScale(stored: fontScale)
        case .fullscreen:
            danmakuFullscreenFontScale(stored: $storedFullscreenFontScale, inline: fontScale)
        }
    }

    private func resetToDefaults() {
        opacity = DanmakuRenderPreferences.defaultOpacity
        switch presentation {
        case .inline:
            DanmakuRenderPreferences.setInlineFontScale(DanmakuRenderPreferences.defaultFontScale)
        case .fullscreen:
            storedFullscreenFontScale = DanmakuRenderPreferences.defaultFontScale
        }
        scrollLifetime = DanmakuRenderPreferences.defaultScrollLifetime
        displayArea = DanmakuRenderPreferences.defaultDisplayArea
        smartMask = DanmakuRenderPreferences.defaultSmartMask
        avoidsOverlap = DanmakuRenderPreferences.defaultAvoidOverlap
        showScroll = true
        showTop = true
        showBottom = true
    }
}

// MARK: - Shared Non-Hijacking Controls

private enum DanmakuControlSurface {
    case settings
    case overlay
    case sheet

    var compactRow: Bool { self != .settings }
}

private struct DanmakuTogglePill: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var isOn: Bool
    var equalWidth = true
    let surface: DanmakuControlSurface

    var body: some View {
        let active = isOn
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active ? "checkmark" : symbol)
                    .font(.caption2.weight(.semibold))
                    .frame(width: 12)
                Text(title)
                    .font(.caption.weight(active ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(danmakuPillForeground(isOn: active, surface: surface))
            .padding(.horizontal, equalWidth ? 6 : 9)
            .padding(.vertical, surface == .overlay ? 5.5 : 7)
            .frame(maxWidth: equalWidth ? .infinity : nil)
            .background(danmakuPillBackground(isOn: active, surface: surface), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(danmakuPillStroke(isOn: active, surface: surface), lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityValue(Text(active ? "On" : "Off"))
    }
}

private struct DanmakuChoiceSegmentRow<Option: Identifiable & Equatable>: View {
    let title: LocalizedStringKey
    let symbol: String
    let fallbackValueLabel: String?
    let options: [Option]
    let selected: Option?
    let optionTitle: (Option) -> LocalizedStringKey
    let onSelect: (Option) -> Void
    let surface: DanmakuControlSurface

    var body: some View {
        switch surface {
        case .settings:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text(title)
                    } icon: {
                        SettingsIcon(symbol: symbol)
                    }
                    Spacer(minLength: 8)
                    if let fallbackValueLabel {
                        Text(verbatim: fallbackValueLabel)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                segments
            }
        case .overlay, .sheet:
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(surface == .overlay ? Color.white.opacity(0.78) : Color.secondary)
                    .frame(width: 60, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                segments
            }
        }
    }

    private var segments: some View {
        HStack(spacing: 5) {
            ForEach(options) { option in
                let active = selected == option
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSelect(option)
                } label: {
                    Text(optionTitle(option))
                        .font(.caption.weight(active ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(danmakuPillForeground(isOn: active, surface: surface))
                        .padding(.horizontal, 4)
                        .padding(.vertical, surface == .overlay ? 5 : 6.5)
                        .frame(maxWidth: .infinity)
                        .background(danmakuPillBackground(isOn: active, surface: surface), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(danmakuPillStroke(isOn: active, surface: surface), lineWidth: 0.8)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

private struct DanmakuAreaSelectorRow: View {
    @Binding var displayArea: Double
    let surface: DanmakuControlSurface

    var body: some View {
        let matched = DanmakuAreaPreset.matching(displayArea)
        let customLabel = matched == nil
            ? danmakuPercent(DanmakuRenderPreferences.effectiveDisplayArea(displayArea))
            : nil
        DanmakuChoiceSegmentRow(
            title: "Display Area",
            symbol: "rectangle.split.1x2",
            fallbackValueLabel: customLabel,
            options: DanmakuAreaPreset.allCases,
            selected: matched,
            optionTitle: \.titleKey,
            onSelect: { displayArea = $0.fraction },
            surface: surface
        )
    }
}

private struct DanmakuSpeedSelectorRow: View {
    @Binding var scrollLifetime: Double
    let surface: DanmakuControlSurface

    var body: some View {
        let selected = DanmakuSpeedPreset.nearest(for: scrollLifetime)
        DanmakuChoiceSegmentRow(
            // Disambiguates from playback rate "Speed" ("倍速") in zh-Hans.
            title: "Danmaku Speed",
            symbol: "hare",
            fallbackValueLabel: nil,
            options: DanmakuSpeedPreset.allCases,
            selected: selected,
            optionTitle: \.titleKey,
            onSelect: { scrollLifetime = $0.scrollLifetime },
            surface: surface
        )
    }
}

private struct DanmakuValueStepperRow: View {
    let title: LocalizedStringKey
    let accessibilityTitle: String
    let symbol: String
    let valueLabel: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let surface: DanmakuControlSurface

    private var canDecrement: Bool {
        value > range.lowerBound + 0.0001
    }

    private var canIncrement: Bool {
        value < range.upperBound - 0.0001
    }

    var body: some View {
        HStack(spacing: 8) {
            switch surface {
            case .settings:
                Label {
                    Text(title)
                } icon: {
                    SettingsIcon(symbol: symbol)
                }
            case .overlay, .sheet:
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(surface == .overlay ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                stepButton(
                    symbol: "minus",
                    enabled: canDecrement,
                    accessibilityLabel: String(format: String(localized: "Decrease %@"), accessibilityTitle)
                ) {
                    nudge(by: -step)
                }

                Text(verbatim: valueLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(surface == .overlay ? Color.white : Color.primary)
                    .frame(minWidth: 46, alignment: .center)

                stepButton(
                    symbol: "plus",
                    enabled: canIncrement,
                    accessibilityLabel: String(format: String(localized: "Increase %@"), accessibilityTitle)
                ) {
                    nudge(by: step)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: valueLabel))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if canIncrement { nudge(by: step) }
            case .decrement:
                if canDecrement { nudge(by: -step) }
            @unknown default:
                break
            }
        }
    }

    private func nudge(by delta: Double) {
        let raw = value + delta
        let stepped = ((raw / step).rounded()) * step
        let clamped = min(range.upperBound, max(range.lowerBound, stepped))
        guard abs(clamped - value) > 0.0001 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        value = clamped
    }

    private func stepButton(
        symbol: String,
        enabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(stepButtonForeground(enabled: enabled))
                .frame(width: surface == .overlay ? 32 : 36, height: surface == .overlay ? 26 : 30)
                .background(stepButtonBackground(enabled: enabled), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            surface == .overlay ? Color.white.opacity(enabled ? 0.18 : 0.08) : Color.clear,
                            lineWidth: 0.8
                        )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private func stepButtonForeground(enabled: Bool) -> Color {
        switch surface {
        case .overlay:
            enabled ? .white : .white.opacity(0.28)
        case .settings, .sheet:
            enabled ? Color.biliAccent : Color.secondary.opacity(0.35)
        }
    }

    private func stepButtonBackground(enabled: Bool) -> Color {
        switch surface {
        case .overlay:
            enabled ? .white.opacity(0.14) : .white.opacity(0.05)
        case .settings, .sheet:
            enabled ? Color.biliAccent.opacity(0.14) : AppFill.inset
        }
    }
}

private struct DanmakuTypeSelectorRow: View {
    @Binding var showScroll: Bool
    @Binding var showTop: Bool
    @Binding var showBottom: Bool
    let surface: DanmakuControlSurface

    var body: some View {
        switch surface {
        case .settings:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    settingsHeader
                    Spacer(minLength: 8)
                    pillsRow(equalWidth: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    settingsHeader
                    pillsRow(equalWidth: true)
                }
            }
        case .overlay, .sheet:
            pillsRow(equalWidth: true)
        }
    }

    private var settingsHeader: some View {
        Label {
            Text("Types")
        } icon: {
            SettingsIcon(symbol: "line.3.horizontal")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pillsRow(equalWidth: Bool) -> some View {
        HStack(spacing: 6) {
            DanmakuTogglePill(
                title: "Scroll",
                symbol: "arrow.left.and.right",
                isOn: $showScroll,
                equalWidth: equalWidth,
                surface: surface
            )
            // Disambiguates from comment sort "Top" ("最热") in zh-Hans.
            DanmakuTogglePill(
                title: "Top Position",
                symbol: "arrow.up",
                isOn: $showTop,
                equalWidth: equalWidth,
                surface: surface
            )
            DanmakuTogglePill(
                title: "Bottom",
                symbol: "arrow.down",
                isOn: $showBottom,
                equalWidth: equalWidth,
                surface: surface
            )
        }
    }
}

@MainActor
private func danmakuPillForeground(isOn: Bool, surface: DanmakuControlSurface) -> Color {
    switch surface {
    case .overlay:
        isOn ? .white : .white.opacity(0.72)
    case .settings, .sheet:
        isOn ? Color.biliAccent : .secondary
    }
}

@MainActor
private func danmakuPillBackground(isOn: Bool, surface: DanmakuControlSurface) -> Color {
    switch surface {
    case .overlay:
        isOn ? AccentStore.shared.badgeFill : .white.opacity(0.10)
    case .settings, .sheet:
        isOn ? Color.biliAccent.opacity(0.15) : AppFill.inset
    }
}

@MainActor
private func danmakuPillStroke(isOn: Bool, surface: DanmakuControlSurface) -> Color {
    switch surface {
    case .overlay:
        isOn ? .white.opacity(0.26) : .white.opacity(0.14)
    case .settings, .sheet:
        isOn ? Color.biliAccent.opacity(0.55) : .clear
    }
}
