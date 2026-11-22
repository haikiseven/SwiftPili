import Foundation

/// Which player presentation the overlay is drawn in.
///
/// Ordinary bullets are sized by this, not by the picture's height: a
/// vertical video's picture is the tallest one on screen and used to get the
/// largest glyphs in the narrowest band. Mode 7 keeps its own picture-height
/// sizing and stage scaling.
enum DanmakuPresentation: Sendable, Equatable {
    case inline
    case fullscreen
}

/// How the renderer draws, read from `UserDefaults`.
///
/// Not a SwiftUI observable. The master switch stays `DanmakuFeatureGate`
/// (`danmaku_enabled`). Every other value defaults to what the renderer did
/// before this type existed, and a missing key is that default — `bool(forKey:)`
/// and `double(forKey:)` would both return zero, which is not today's picture.
struct DanmakuRenderPreferences: Equatable, Sendable {
    static let opacityKey = "danmaku_opacity"
    /// The INLINE font scale. It was the only one until 2026-09-28, so every
    /// stored value under it keeps the meaning it had for inline bullets.
    static let fontScaleKey = "danmaku_font_scale"
    /// The fullscreen font scale, like PiliPlus's `danmakuFontScaleFS`. An
    /// iPad watches inline in a player taller than a phone's fullscreen one,
    /// so one shared scale forced a choice between the two. When this key is
    /// absent the value is read from `fontScaleKey` — the one scale the user
    /// had set before the split applied to both — so fullscreen does not move
    /// on upgrade. `load` writes nothing; the first inline write pins this key
    /// (`setInlineFontScale`), or a live fallback would carry every later
    /// inline change into fullscreen.
    static let fullscreenFontScaleKey = "danmaku_font_scale_fullscreen"

    /// Writes the inline scale. While the fullscreen key is still absent it is
    /// first pinned to what fullscreen draws now, so moving the inline slider
    /// never moves fullscreen bullets.
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
    /// "Keep Subtitles Clear": the bottom-25% reserve. The key predates the
    /// rename and is kept, so the user's value survives it.
    static let avoidOverlapKey = "danmaku_avoid_overlap"
    /// "Smart Anti-Occlusion": Bilibili's person mask (Phase C). Default on —
    /// it does nothing on a video without a mask.
    static let smartMaskKey = "danmaku_smart_mask"
    static let defaultSmartMask = true
    static let blockKeywordsKey = "danmaku_block_keywords"

    static let opacityRange: ClosedRange<Double> = 0 ... 1
    static let fontScaleRange: ClosedRange<Double> = 0.5 ... 2
    /// Seconds a scroll bullet takes to cross. Shorter is faster. Not a multiplier.
    static let scrollLifetimeRange: ClosedRange<Double> = 4 ... 16
    /// Share of the picture danmaku may use. The floor is 10%, like PiliPlus:
    /// below it the region is thinner than one lane, and "at least one lane"
    /// then drew bullets outside it. A value stored under the old 0...1 range
    /// is clamped up on load.
    static let displayAreaRange: ClosedRange<Double> = 0.1 ... 1

    /// `displayArea` as the renderer uses it: inside `displayAreaRange`, and
    /// the default when it is not a number. The settings labels read this so
    /// they never print a value the renderer is not using.
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

    /// Wire font 25 is the size lane stride is measured from.
    static let referenceWireFontSize = 25
    /// Divisor for the compressed picture height. The mode-7 stage is 720,
    /// and dividing a raw picture height by that pinned every phone picture
    /// (about 200–400pt) onto one floor, so 18, 25 and 36 drew as the same
    /// 13pt. 360 is applied after height compression, not to the raw height.
    static let fontPictureReference: Double = 360
    /// Picture height where compression is the identity (`sqrt(h * anchor) == h`).
    /// A 16:9 portrait picture is about this tall. A taller fullscreen picture
    /// is folded toward it so the glyph does not jump with the raw height.
    static let fontHeightAnchor: Double = 220
    /// Glyph point size is clamped after picture height and font scale.
    /// The floor stays under the standard wire size. The ceiling only stops
    /// an iPad-height picture from drawing a headline.
    static let bulletPointSizeRange: ClosedRange<Double> = 10 ... 48
    /// Lane stride is the unscaled reference glyph times this, then font scale.
    static let laneHeightFactor = 1.52

    /// Point size of wire font 25 at font scale 1, per presentation.
    ///
    /// Inline uses 15pt for balanced portrait playback at the default scale.
    /// Fullscreen uses 18.5pt. Both are fixed per presentation, independent of
    /// picture height; glyph and lane geometry share this reference and
    /// preserve the user's saved scale.
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

    /// Bottom fraction kept clear when overlap avoidance is on. Subtitles and
    /// the subject sit there. This is not a cloud mask.
    static let overlapClearFraction = 0.25

    var opacity: Double
    /// Inline. Read per presentation through `fontScale(for:)`.
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

    /// Mode 7 only: `wireFontSize * (sqrt(pictureHeight * 220) / 360) * fontScale`,
    /// then clamped to 10...48.
    ///
    /// Height is compressed first: `effective = sqrt(pictureHeight * fontHeightAnchor)`.
    /// At 220pt that equals the picture height. A taller picture grows slower
    /// than the raw height.
    ///
    /// A missing or non-finite picture height substitutes the 360 reference as
    /// the height, then the same compression. A non-finite result falls back
    /// to the floor. Ordinary bullets no longer use this — see
    /// `bulletPointSize(wireFontSize:presentation:fontScale:)`. Mode-7
    /// *placement* still uses the 720 stage; this reference is only the glyph.
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

    /// Scroll, top, bottom and reverse:
    /// `wireFontSize / 25 × referencePointSize(presentation) × fontScale`,
    /// clamped to 10...48.
    ///
    /// Independent of the picture's size and aspect. A non-finite or
    /// non-positive scale falls back to 1; a non-finite result to the floor.
    static func bulletPointSize(
        wireFontSize: Int,
        presentation: DanmakuPresentation,
        fontScale: Double
    ) -> Double {
        let scale = fontScale.isFinite && fontScale > 0 ? fontScale : defaultFontScale
        // Ratio first: wire 25 is exactly 1, so it lands exactly on the reference.
        let wireRatio = Double(wireFontSize) / Double(referenceWireFontSize)
        let raw = wireRatio * referencePointSize(for: presentation) * scale
        guard raw.isFinite else { return bulletPointSizeRange.lowerBound }
        return min(bulletPointSizeRange.upperBound, max(bulletPointSizeRange.lowerBound, raw))
    }

    /// Points of one lane in this presentation.
    ///
    /// Base stride is the unscaled size of wire font 25 (font scale 1, same
    /// formula and clamp as a bullet), times `laneHeightFactor`, then times
    /// this presentation's font scale (`fontScale(for:)`). Scale 2 doubles
    /// the lane even when the glyph is clamped.
    /// A non-finite or non-positive scale falls back to 1.
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

    /// `(pictureHeight * displayArea) / laneHeight`, at least one.
    ///
    /// The fraction is applied to the height before dividing. Dividing first
    /// and then shrinking the count would drop a partial lane the region
    /// still has room for. A zero-height host still keeps one lane.
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
        // `Int(Double)` traps when the value does not fit. Truncate, then refuse
        // a magnitude `Int` cannot name instead of converting it.
        let whole = fitted.rounded(.towardZero)
        guard let raw = Int(exactly: whole) else { return 1 }
        if presentation == .inline {
            let inlineCap = max(1, Int((6.0 * Self.effectiveDisplayArea(displayArea)).rounded()))
            return max(1, min(raw, inlineCap))
        }
        return max(1, raw)
    }

    /// Lane geometry for bullets admitted under these preferences on a
    /// `width × height` picture: lane count, stride, the display-area
    /// region bottom bullets stack up from, and the scroll lifetime.
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
        // The region bottom bullets stack up from. `laneCount` keeps at least
        // one lane even when the region is thinner than a lane (a large font
        // scale at 10%), so the region grows to hold the lanes it has —
        // otherwise the lowest bottom lane starts above the picture's top edge
        // and is clipped. Never past the usable picture itself.
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

    /// True when bullets admitted from now on are laid out or filtered
    /// differently. Bullets already flying are NOT dropped for this: they keep
    /// their size, speed and lane, and the allocator keeps their occupancy
    /// (`DanmakuTrackLayout.Allocator.retarget`). Opacity is the container's
    /// alpha and applies live, so it is not a layout change. Font scale,
    /// display area, scroll lifetime, overlap avoidance, block words and the
    /// three kind switches are.
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

    /// The font scale bullets drawn in `presentation` use.
    func fontScale(for presentation: DanmakuPresentation) -> Double {
        switch presentation {
        case .inline: fontScale
        case .fullscreen: fullscreenFontScale
        }
    }

    /// Share of the picture danmaku may occupy, from the top.
    ///
    /// Display area scales that share. Overlap avoidance then keeps the bottom
    /// quarter clear, so a full area with avoidance on is 75% of the picture.
    var regionFraction: Double {
        let area = Self.effectiveDisplayArea(displayArea)
        let cap = avoidsOverlap ? (1 - Self.overlapClearFraction) : 1
        return area * cap
    }

    /// Substring block. Matching is case-insensitive. Empty keywords never match.
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

    /// Kind filter applied before a lane or a mode-7 placement.
    ///
    /// `.reverse` follows scroll: it is the same crossing motion, only mirrored,
    /// and it is rare. Default-on scroll therefore still draws it, which is the
    /// behavior before this filter existed. `.advanced` ignores these three
    /// switches and follows the master gate only. `.unsupported` stays dropped.
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

    /// The admission filter for one bullet, before it is rasterized.
    ///
    /// The viewer's own bullet (`isSelfSent`) always passes: the kind switches
    /// and block words are about other people's bullets, and hiding the one
    /// the user just typed reads as a failed send (B4). Everyone else's must
    /// pass `admits(kind)` and, except mode 7, the block words. Mode 7's
    /// content is a script, so its keyword check waits for the parsed text —
    /// matching the raw coordinates would let a short keyword drop every one.
    /// `.unsupported` is refused by `admits` for everyone else and never
    /// drawn for anyone.
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

    /// Read on its own, not through `load()`: the mask is not a layout input
    /// (toggling it never moves a bullet), and the player asks at clock rate.
    static func smartMaskEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        bool(defaults, smartMaskKey, defaultSmartMask)
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
