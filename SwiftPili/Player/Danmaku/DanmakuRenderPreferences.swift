import Foundation

enum DanmakuPresentation: Sendable, Equatable {
    case inline
    case fullscreen
}

struct DanmakuRenderPreferences: Equatable, Sendable {
    static let opacityKey = "danmaku_opacity"
    static let fontScaleKey = "danmaku_font_scale"
    static let fullscreenFontScaleKey = "danmaku_font_scale_fullscreen"

    static func setInlineFontScale(_ value: Double, in defaults: UserDefaults = .standard) {
        if defaults.object(forKey: fullscreenFontScaleKey) == nil {
            defaults.set(load(defaults).fullscreenFontScale, forKey: fullscreenFontScaleKey)
        }
        defaults.set(value, forKey: fontScaleKey)
    }
    static let scrollLifetimeKey = "danmaku_scroll_lifetime"
    static let displayAreaKey = "danmaku_display_area"
    static let showScrollKey = "danmaku_show_scroll"
    static let showTopKey = "danmaku_show_top"
    static let showBottomKey = "danmaku_show_bottom"
    static let avoidOverlapKey = "danmaku_avoid_overlap"
    static let smartMaskKey = "danmaku_smart_mask"
    static let defaultSmartMask = true
    static let blockKeywordsKey = "danmaku_block_keywords"

    static let opacityRange: ClosedRange<Double> = 0 ... 1
    static let fontScaleRange: ClosedRange<Double> = 0.5 ... 2
    static let scrollLifetimeRange: ClosedRange<Double> = 4 ... 16
    static let displayAreaRange: ClosedRange<Double> = 0.1 ... 1

    static func effectiveDisplayArea(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDisplayArea }
        return min(displayAreaRange.upperBound, max(displayAreaRange.lowerBound, value))
    }

    static let defaultOpacity = 0.85
    static let defaultFontScale = 1.0
    static let defaultScrollLifetime = 9.0
    static let defaultDisplayArea = 0.5
    static let defaultAvoidOverlap = true
    private static let displayTuningMigrationV2Key = "danmaku_display_tuning_v2"

    static let referenceWireFontSize = 25
    static let fontPictureReference: Double = 360
    static let fontHeightAnchor: Double = 220
    static let bulletPointSizeRange: ClosedRange<Double> = 10 ... 48
    static let laneHeightFactor = 1.52

    static let inlineReferencePointSize: Double = 15
    static let fullscreenReferencePointSize: Double = 18.5

    static func referencePointSize(for presentation: DanmakuPresentation) -> Double {
        switch presentation {
        case .inline: inlineReferencePointSize
        case .fullscreen: fullscreenReferencePointSize
        }
    }

    static func verticalInset(for presentation: DanmakuPresentation) -> Double {
        switch presentation {
        case .inline: 6
        case .fullscreen: 12
        }
    }

    static let overlapClearFraction = 0.25

    var opacity: Double
    var fontScale: Double
    var fullscreenFontScale: Double
    var scrollLifetime: TimeInterval
    var displayArea: Double
    var showsScroll: Bool
    var showsTop: Bool
    var showsBottom: Bool
    var avoidsOverlap: Bool
    var blockedKeywords: [String]

    init(
        opacity: Double,
        fontScale: Double,
        fullscreenFontScale: Double? = nil,
        scrollLifetime: TimeInterval,
        displayArea: Double,
        showsScroll: Bool,
        showsTop: Bool,
        showsBottom: Bool,
        avoidsOverlap: Bool = defaultAvoidOverlap,
        blockedKeywords: [String] = []
    ) {
        self.opacity = opacity
        self.fontScale = fontScale
        self.fullscreenFontScale = fullscreenFontScale ?? fontScale
        self.scrollLifetime = scrollLifetime
        self.displayArea = displayArea
        self.showsScroll = showsScroll
        self.showsTop = showsTop
        self.showsBottom = showsBottom
        self.avoidsOverlap = avoidsOverlap
        self.blockedKeywords = blockedKeywords
    }

    static let `default` = DanmakuRenderPreferences(
        opacity: defaultOpacity,
        fontScale: defaultFontScale,
        scrollLifetime: defaultScrollLifetime,
        displayArea: defaultDisplayArea,
        showsScroll: true,
        showsTop: true,
        showsBottom: true,
        avoidsOverlap: defaultAvoidOverlap
    )

    static func load(_ defaults: UserDefaults = .standard) -> DanmakuRenderPreferences {
        if defaults === UserDefaults.standard,
           !defaults.bool(forKey: displayTuningMigrationV2Key) {
            defaults.set(true, forKey: displayTuningMigrationV2Key)
            if defaults.object(forKey: displayAreaKey) == nil || defaults.double(forKey: displayAreaKey) >= 0.99 {
                defaults.set(defaultDisplayArea, forKey: displayAreaKey)
            }
            if defaults.object(forKey: opacityKey) == nil || defaults.double(forKey: opacityKey) >= 0.99 {
                defaults.set(defaultOpacity, forKey: opacityKey)
            }
            if defaults.object(forKey: scrollLifetimeKey) == nil || defaults.double(forKey: scrollLifetimeKey) == 8.0 {
                defaults.set(defaultScrollLifetime, forKey: scrollLifetimeKey)
            }
            if defaults.object(forKey: avoidOverlapKey) == nil {
                defaults.set(defaultAvoidOverlap, forKey: avoidOverlapKey)
            }
        }
        let inlineScale = double(defaults, fontScaleKey, defaultFontScale, fontScaleRange)
        return DanmakuRenderPreferences(
            opacity: double(defaults, opacityKey, defaultOpacity, opacityRange),
            fontScale: inlineScale,
            fullscreenFontScale: double(defaults, fullscreenFontScaleKey, inlineScale, fontScaleRange),
            scrollLifetime: double(
                defaults,
                scrollLifetimeKey,
                defaultScrollLifetime,
                scrollLifetimeRange
            ),
            displayArea: double(defaults, displayAreaKey, defaultDisplayArea, displayAreaRange),
            showsScroll: bool(defaults, showScrollKey, true),
            showsTop: bool(defaults, showTopKey, true),
            showsBottom: bool(defaults, showBottomKey, true),
            avoidsOverlap: bool(defaults, avoidOverlapKey, defaultAvoidOverlap),
            blockedKeywords: keywords(defaults)
        )
    }

    static func bulletPointSize(
        wireFontSize: Int,
        pictureHeight: Double,
        fontScale: Double
    ) -> Double {
        let height = pictureHeight.isFinite && pictureHeight > 0
            ? pictureHeight
            : fontPictureReference
        let scale = fontScale.isFinite && fontScale > 0 ? fontScale : defaultFontScale
        let effective = (height * fontHeightAnchor).squareRoot()
        let raw = Double(wireFontSize) * (effective / fontPictureReference) * scale
        guard raw.isFinite else { return bulletPointSizeRange.lowerBound }
        return min(bulletPointSizeRange.upperBound, max(bulletPointSizeRange.lowerBound, raw))
    }

    static func bulletPointSize(
        wireFontSize: Int,
        presentation: DanmakuPresentation,
        fontScale: Double
    ) -> Double {
        let scale = fontScale.isFinite && fontScale > 0 ? fontScale : defaultFontScale
        let wireRatio = Double(wireFontSize) / Double(referenceWireFontSize)
        let raw = wireRatio * referencePointSize(for: presentation) * scale
        guard raw.isFinite else { return bulletPointSizeRange.lowerBound }
        return min(bulletPointSizeRange.upperBound, max(bulletPointSizeRange.lowerBound, raw))
    }

    func laneHeight(presentation: DanmakuPresentation) -> Double {
        let chosen = fontScale(for: presentation)
        let scale = chosen.isFinite && chosen > 0 ? chosen : Self.defaultFontScale
        let unscaled = Self.bulletPointSize(
            wireFontSize: Self.referenceWireFontSize,
            presentation: presentation,
            fontScale: Self.defaultFontScale
        )
        return unscaled * Self.laneHeightFactor * scale
    }

    func laneCount(forHeight height: Double, presentation: DanmakuPresentation) -> Int {
        guard height.isFinite, height > 0 else { return 1 }
        let stride = laneHeight(presentation: presentation)
        guard stride.isFinite, stride > 0 else { return 1 }
        let inset = Self.verticalInset(for: presentation)
        let usableHeight = max(stride, height - inset * 2)
        let fraction = regionFraction
        let span = usableHeight * fraction
        guard span.isFinite else { return 1 }
        let fitted = span / stride
        guard fitted.isFinite else { return 1 }
        let whole = fitted.rounded(.towardZero)
        guard let raw = Int(exactly: whole) else { return 1 }
        if presentation == .inline {
            let inlineCap = max(1, Int((6.0 * Self.effectiveDisplayArea(displayArea)).rounded()))
            return max(1, min(raw, inlineCap))
        }
        return max(1, raw)
    }

    func trackMetrics(
        width: Double,
        height: Double,
        presentation: DanmakuPresentation
    ) -> DanmakuTrackLayout.Metrics {
        let safeHeight = height.isFinite ? max(0, height) : 0
        let lanes = laneCount(forHeight: safeHeight, presentation: presentation)
        let stride = laneHeight(presentation: presentation)
        let inset = safeHeight > stride + 12 ? Self.verticalInset(for: presentation) : 0
        let maxRegion = max(0, safeHeight - inset)
        let fitted = max(inset + max(0, safeHeight - inset * 2) * regionFraction, inset + Double(lanes) * stride)
        return DanmakuTrackLayout.Metrics(
            width: width.isFinite ? width : 1,
            laneCount: lanes,
            scrollLifetime: scrollLifetime,
            laneStride: stride,
            regionHeight: safeHeight > 0 ? min(maxRegion, fitted) : 0,
            topInset: inset
        )
    }

    func layoutChanged(from previous: DanmakuRenderPreferences) -> Bool {
        fontScale != previous.fontScale
            || fullscreenFontScale != previous.fullscreenFontScale
            || displayArea != previous.displayArea
            || scrollLifetime != previous.scrollLifetime
            || showsScroll != previous.showsScroll
            || showsTop != previous.showsTop
            || showsBottom != previous.showsBottom
            || avoidsOverlap != previous.avoidsOverlap
            || blockedKeywords != previous.blockedKeywords
    }

    func fontScale(for presentation: DanmakuPresentation) -> Double {
        switch presentation {
        case .inline: fontScale
        case .fullscreen: fullscreenFontScale
        }
    }

    var regionFraction: Double {
        let area = Self.effectiveDisplayArea(displayArea)
        let cap = avoidsOverlap ? (1 - Self.overlapClearFraction) : 1
        return area * cap
    }

    func blocks(_ text: String) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for keyword in blockedKeywords {
            let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            let folded = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if haystack.contains(folded) { return true }
        }
        return false
    }

    func admits(_ kind: DanmakuRenderKind) -> Bool {
        switch kind {
        case .scroll, .reverse:
            return showsScroll
        case .top:
            return showsTop
        case .bottom:
            return showsBottom
        case .advanced:
            return true
        case .unsupported:
            return false
        }
    }

    func admitsElement(_ item: DanmakuElem) -> Bool {
        let kind = item.renderKind
        guard kind != .unsupported else { return false }
        if item.isSelfSent { return true }
        guard admits(kind) else { return false }
        if kind != .advanced, blocks(item.content) { return false }
        return true
    }

    private static func keywords(_ defaults: UserDefaults) -> [String] {
        let raw = defaults.stringArray(forKey: blockKeywordsKey) ?? []
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func double(
        _ defaults: UserDefaults,
        _ key: String,
        _ fallback: Double,
        _ range: ClosedRange<Double>
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func smartMaskEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(defaults, smartMaskKey, defaultSmartMask)
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
