import SwiftUI

/// Danmaku preferences. Same shape as `SponsorBlockSettingsView`: the master
/// switch, then the drawing controls only while it is on. Values are the
/// `UserDefaults` keys `DanmakuRenderPreferences` reads. This view does not
/// observe the player.
struct DanmakuSettingsView: View {
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var enabled = false
    @AppStorage(DanmakuRenderPreferences.opacityKey)
    private var opacity = DanmakuRenderPreferences.defaultOpacity
    @AppStorage(DanmakuRenderPreferences.fontScaleKey)
    private var fontScale = DanmakuRenderPreferences.defaultFontScale
    /// nil until the fullscreen slider is first moved: fullscreen then reads
    /// the inline scale, the same fallback `DanmakuRenderPreferences.load` uses.
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
    @State private var keywords: [String] = []

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
        .onAppear {
            keywords = DanmakuRenderPreferences.load().blockedKeywords
        }
    }

    private var masterSection: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label {
                    Text("Show Danmaku")
                } icon: {
                    SettingsIcon(symbol: "text.bubble")
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Display") {
            sliderRow(
                title: "Opacity",
                symbol: "circle.lefthalf.filled",
                valueLabel: percent(opacity),
                value: $opacity,
                range: DanmakuRenderPreferences.opacityRange,
                step: 0.05
            )
            sliderRow(
                title: "Font Size",
                symbol: "textformat.size",
                valueLabel: percent(fontScale),
                value: inlineFontScale,
                range: DanmakuRenderPreferences.fontScaleRange,
                step: 0.1
            )
            sliderRow(
                title: "Fullscreen Font Size",
                symbol: "arrow.up.left.and.arrow.down.right",
                valueLabel: percent(fullscreenFontScale.wrappedValue),
                value: fullscreenFontScale,
                range: DanmakuRenderPreferences.fontScaleRange,
                step: 0.1
            )
            sliderRow(
                title: "Danmaku Speed",
                symbol: "hare",
                valueLabel: speedPercent(scrollLifetime),
                value: scrollSpeed,
                range: DanmakuRenderPreferences.scrollLifetimeRange,
                step: 1
            )
            sliderRow(
                title: "Display Area",
                symbol: "rectangle.split.1x2",
                valueLabel: percent(DanmakuRenderPreferences.effectiveDisplayArea(displayArea)),
                value: $displayArea,
                range: DanmakuRenderPreferences.displayAreaRange,
                step: 0.05
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
            Toggle(isOn: $showScroll) {
                Label {
                    Text("Scroll")
                } icon: {
                    SettingsIcon(symbol: "arrow.left.and.right")
                }
            }
            Toggle(isOn: $showTop) {
                Label {
                    // "Top" is the comment-sort key (hottest). This switch is the
                    // top of the picture, so it cannot share that key.
                    Text("Top Position")
                } icon: {
                    SettingsIcon(symbol: "arrow.up")
                }
            }
            Toggle(isOn: $showBottom) {
                Label {
                    Text("Bottom")
                } icon: {
                    SettingsIcon(symbol: "arrow.down")
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
                Label {
                    Text(title)
                } icon: {
                    SettingsIcon(symbol: symbol)
                }
                Spacer()
                Text(verbatim: valueLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    /// Right is faster. The stored value stays a lifetime in seconds.
    private var scrollSpeed: Binding<Double> {
        danmakuScrollSpeed(lifetime: $scrollLifetime)
    }

    private var inlineFontScale: Binding<Double> {
        danmakuInlineFontScale(stored: fontScale)
    }

    private var fullscreenFontScale: Binding<Double> {
        danmakuFullscreenFontScale(stored: $storedFullscreenFontScale, inline: fontScale)
    }

    private func percent(_ value: Double) -> String {
        let whole = Int((value * 100).rounded())
        return "\(whole)%"
    }

    private func speedPercent(_ lifetime: Double) -> String {
        danmakuSpeedPercent(lifetime)
    }
}

/// Slider position for `danmaku_scroll_lifetime`. The key stays seconds
/// (shorter is faster); the control's right end is the short lifetime.
private func danmakuScrollSpeed(lifetime: Binding<Double>) -> Binding<Double> {
    let range = DanmakuRenderPreferences.scrollLifetimeRange
    let span = range.lowerBound + range.upperBound
    return Binding(
        get: { span - lifetime.wrappedValue },
        set: { lifetime.wrappedValue = span - $0 }
    )
}

/// The fullscreen font scale as a control: the stored value, or the inline
/// scale while nothing is stored (`DanmakuRenderPreferences.load`'s fallback).
/// Moving the control writes the fullscreen key; the inline key is never touched.
private func danmakuFullscreenFontScale(stored: Binding<Double?>, inline: Double) -> Binding<Double> {
    Binding(
        get: { stored.wrappedValue ?? inline },
        set: { stored.wrappedValue = $0 }
    )
}

/// The inline font scale as a control. Writes go through
/// `DanmakuRenderPreferences.setInlineFontScale`, which pins the fullscreen
/// scale first while it is still unset, so this slider never moves fullscreen.
private func danmakuInlineFontScale(stored: Double) -> Binding<Double> {
    Binding(
        get: { stored },
        set: { DanmakuRenderPreferences.setInlineFontScale($0) }
    )
}

/// Speed-slider position as a percent. Higher is faster, not a longer lifetime.
private func danmakuSpeedPercent(_ lifetime: Double) -> String {
    let range = DanmakuRenderPreferences.scrollLifetimeRange
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return "0%" }
    let fraction = min(max((range.upperBound - lifetime) / span, 0), 1)
    return "\(Int((fraction * 100).rounded()))%"
}

/// Landscape in-player danmaku controls. The same `UserDefaults` keys as
/// `DanmakuSettingsView`. Keyword blocking stays on that page.
struct DanmakuPlayerSettingsPanel: View {
    /// Which presentation the panel was opened from; its font-size slider
    /// adjusts that presentation's scale only.
    let presentation: DanmakuPresentation
    /// Where it is drawn. The overlay sits on the video, dark, with its own
    /// Close; the popover (iPad inline band) is ordinary system chrome and is
    /// dismissed by tapping outside it.
    enum Surface { case overlay, popover }
    var surface: Surface = .overlay
    let onClose: () -> Void

    @AppStorage(DanmakuRenderPreferences.opacityKey)
    private var opacity = DanmakuRenderPreferences.defaultOpacity
    @AppStorage(DanmakuRenderPreferences.fontScaleKey)
    private var fontScale = DanmakuRenderPreferences.defaultFontScale
    /// nil until the fullscreen slider is first moved: fullscreen then reads
    /// the inline scale, the same fallback `DanmakuRenderPreferences.load` uses.
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

    var body: some View {
        switch surface {
        case .overlay:
            let overlayContent = controls
                .foregroundStyle(.white)
                .padding(12)
            // No panel-wide `.tint(.white)`: an ON toggle took it as its track,
            // under a white knob, and read the same as OFF. Only the sliders
            // are white (`slider(_:…)`); toggles use the scoped content accent.
            ViewThatFits(in: .vertical) {
                overlayContent
                ScrollView {
                    overlayContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: 260)
            .frame(maxHeight: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.card))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .environment(\.colorScheme, .dark)
        case .popover:
            let popoverContent = controls.padding(16)
            ViewThatFits(in: .vertical) {
                popoverContent
                ScrollView {
                    popoverContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: 300)
            .frame(maxHeight: 460)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if surface == .overlay {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Label("Close", systemImage: "xmark")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            slider(
                "Opacity",
                value: $opacity,
                range: DanmakuRenderPreferences.opacityRange,
                step: 0.05,
                valueLabel: percent(opacity)
            )
            slider(
                presentation == .fullscreen ? "Fullscreen Font Size" : "Font Size",
                value: presentedFontScale,
                range: DanmakuRenderPreferences.fontScaleRange,
                step: 0.1,
                valueLabel: percent(presentedFontScale.wrappedValue)
            )
            slider(
                "Danmaku Speed",
                value: scrollSpeed,
                range: DanmakuRenderPreferences.scrollLifetimeRange,
                step: 1,
                valueLabel: danmakuSpeedPercent(scrollLifetime)
            )
            slider(
                "Display Area",
                value: $displayArea,
                range: DanmakuRenderPreferences.displayAreaRange,
                step: 0.05,
                valueLabel: percent(DanmakuRenderPreferences.effectiveDisplayArea(displayArea))
            )
            Toggle("Smart Anti-Occlusion", isOn: $smartMask)
            Toggle("Keep Subtitles Clear", isOn: $avoidsOverlap)
            Toggle("Scroll", isOn: $showScroll)
            Toggle("Top Position", isOn: $showTop)
            Toggle("Bottom", isOn: $showBottom)
        }
        .font(.subheadline)
        .accentContentBoundary()
    }

    /// Right is faster. The stored value stays a lifetime in seconds.
    private var scrollSpeed: Binding<Double> {
        danmakuScrollSpeed(lifetime: $scrollLifetime)
    }

    private var presentedFontScale: Binding<Double> {
        switch presentation {
        case .inline: danmakuInlineFontScale(stored: fontScale)
        case .fullscreen:
            danmakuFullscreenFontScale(stored: $storedFullscreenFontScale, inline: fontScale)
        }
    }

    private func percent(_ value: Double) -> String {
        let whole = Int((value * 100).rounded())
        return "\(whole)%"
    }

    private func slider(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(verbatim: valueLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(surface == .overlay ? Color.white.opacity(0.7) : Color.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(surface == .overlay ? Color.white : AccentStore.shared.contentTint)
        }
    }
}
