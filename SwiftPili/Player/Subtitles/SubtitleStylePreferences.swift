import CoreGraphics
import Foundation
import Observation

enum PlayerSubtitleTrackID {
    static let systemSpeech = "__system_speech__"
    static let localPrefix = "local:"

    static func makeLocalID(_ uuid: UUID = UUID()) -> String {
        "\(localPrefix)\(uuid.uuidString)"
    }

    static func isLocal(_ id: String?) -> Bool {
        id?.hasPrefix(localPrefix) == true
    }

    static func isSystemSpeech(_ id: String?) -> Bool {
        id == systemSpeech
    }
}

struct ImportedSubtitleTrack: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
    let cues: [PlayerViewModel.SubtitleCue]

    static func == (lhs: ImportedSubtitleTrack, rhs: ImportedSubtitleTrack) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.fileName == rhs.fileName
            && lhs.cues.count == rhs.cues.count
    }
}

enum SubtitleFontSizeScale: String, Codable, CaseIterable, Identifiable, Sendable {
    case small = "small"
    case standard = "standard"
    case large = "large"
    case extraLarge = "extra_large"

    var id: String { rawValue }

    var multiplier: CGFloat {
        switch self {
        case .small: 0.85
        case .standard: 1.0
        case .large: 1.2
        case .extraLarge: 1.4
        }
    }

    var label: String {
        switch self {
        case .small: String(localized: "Small")
        case .standard: String(localized: "Standard")
        case .large: String(localized: "Large")
        case .extraLarge: String(localized: "Extra Large")
        }
    }
}

enum SubtitleBackgroundStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case noneWithStroke = "none_with_stroke"
    case translucentBox = "translucent_box"
    case solidBox = "solid_box"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .noneWithStroke: String(localized: "Text Outline")
        case .translucentBox: String(localized: "Translucent Box")
        case .solidBox: String(localized: "Solid Box")
        }
    }
}

enum SpeechSubtitleLocale: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case chineseSimplified = "zh-Hans-CN"
    case english = "en-US"
    case japanese = "ja-JP"
    case cantonese = "yue-CN"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .chineseSimplified: String(localized: "Chinese (Mandarin)")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        case .cantonese: String(localized: "Cantonese")
        }
    }

    /// Ordered locale identifiers to try against `SpeechTranscriber` / `SFSpeechRecognizer`.
    func candidateIdentifiers(preferredLanguages: [String] = Locale.preferredLanguages) -> [String] {
        switch self {
        case .auto:
            let primary = (preferredLanguages.first ?? "zh-Hans-CN").lowercased()
            if primary.hasPrefix("en") {
                return ["en-US", "zh-Hans-CN"]
            }
            if primary.hasPrefix("ja") {
                return ["ja-JP", "zh-Hans-CN"]
            }
            if primary.hasPrefix("yue") || primary.hasPrefix("zh-hk") || primary.hasPrefix("zh-hant-hk") {
                return ["yue-CN", "zh-HK", "zh-Hans-CN"]
            }
            return ["zh-Hans-CN", "zh-CN"]
        case .chineseSimplified:
            return ["zh-Hans-CN", "zh-CN"]
        case .english:
            return ["en-US", "en-GB"]
        case .japanese:
            return ["ja-JP"]
        case .cantonese:
            return ["yue-CN", "zh-HK", "yue-Hant-HK"]
        }
    }

    var primaryLocale: Locale {
        Locale(identifier: candidateIdentifiers().first ?? "zh-Hans-CN")
    }
}

enum SubtitleTranslationTargetLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chineseSimplified = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chineseSimplified: String(localized: "Simplified Chinese")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        }
    }

    var shortLabel: String {
        switch self {
        case .chineseSimplified: String(localized: "Chinese")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        }
    }

    var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }
}

enum SubtitlePreferredLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case firstAvailable = "any"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chineseSimplified: String(localized: "Simplified Chinese")
        case .chineseTraditional: String(localized: "Traditional Chinese")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        case .firstAvailable: String(localized: "First Available")
        }
    }

    func matches(bilibiliLan: String) -> Bool {
        let normalized = bilibiliLan
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return false }
        let stripped = normalized.hasPrefix("ai-") ? String(normalized.dropFirst(3)) : normalized
        switch self {
        case .chineseSimplified:
            if stripped.contains("hant")
                || stripped.contains("tw")
                || stripped.contains("hk")
                || stripped.contains("mo") {
                return false
            }
            return stripped == "zh"
                || stripped == "zh-cn"
                || stripped.hasPrefix("zh-cn-")
                || stripped == "zh-hans"
                || stripped.hasPrefix("zh-hans-")
                || stripped == "chs"
                || stripped.hasPrefix("zh-")
        case .chineseTraditional:
            return stripped == "zh-hant"
                || stripped.hasPrefix("zh-hant-")
                || stripped == "zh-tw"
                || stripped.hasPrefix("zh-tw-")
                || stripped == "zh-hk"
                || stripped.hasPrefix("zh-hk-")
                || stripped == "zh-mo"
                || stripped.hasPrefix("zh-mo-")
                || stripped == "cht"
        case .english:
            return stripped == "en" || stripped.hasPrefix("en-")
        case .japanese:
            return stripped == "ja"
                || stripped.hasPrefix("ja-")
                || stripped == "jp"
                || stripped.hasPrefix("jp-")
        case .firstAvailable:
            return true
        }
    }

    static func inferred(from bilibiliLan: String) -> SubtitlePreferredLanguage? {
        if chineseTraditional.matches(bilibiliLan: bilibiliLan) {
            return .chineseTraditional
        }
        if chineseSimplified.matches(bilibiliLan: bilibiliLan) {
            return .chineseSimplified
        }
        if english.matches(bilibiliLan: bilibiliLan) {
            return .english
        }
        if japanese.matches(bilibiliLan: bilibiliLan) {
            return .japanese
        }
        return nil
    }
}

enum SubtitlePreferredSecondaryLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "Off")
        case .chineseSimplified: String(localized: "Simplified Chinese")
        case .chineseTraditional: String(localized: "Traditional Chinese")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        }
    }

    func matches(bilibiliLan: String) -> Bool {
        switch self {
        case .none:
            return false
        case .chineseSimplified:
            return SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: bilibiliLan)
        case .chineseTraditional:
            return SubtitlePreferredLanguage.chineseTraditional.matches(bilibiliLan: bilibiliLan)
        case .english:
            return SubtitlePreferredLanguage.english.matches(bilibiliLan: bilibiliLan)
        case .japanese:
            return SubtitlePreferredLanguage.japanese.matches(bilibiliLan: bilibiliLan)
        }
    }

    static func inferred(from bilibiliLan: String?) -> SubtitlePreferredSecondaryLanguage {
        guard let bilibiliLan else { return .none }
        switch SubtitlePreferredLanguage.inferred(from: bilibiliLan) {
        case .chineseSimplified: return .chineseSimplified
        case .chineseTraditional: return .chineseTraditional
        case .english: return .english
        case .japanese: return .japanese
        case .firstAvailable, nil: return .none
        }
    }
}

enum SubtitleAutoSpeechMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case whenNoCloudSubtitles = "when_no_cloud"
    case always = "always"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .whenNoCloudSubtitles: String(localized: "When No Cloud Subtitles")
        case .always: String(localized: "Always")
        }
    }
}

@MainActor
@Observable
final class SubtitleStylePreferences {
    static let shared = SubtitleStylePreferences()

    static let minBackgroundOpacity: Double = 0.2
    static let maxBackgroundOpacity: Double = 0.9
    static let defaultBackgroundOpacity: Double = 0.55

    static let minBottomOffset: Double = 0
    static let maxBottomOffset: Double = 100
    static let defaultBottomOffset: Double = 0

    private enum Keys {
        static let fontSizeScale = "subtitle_style_font_size_scale"
        static let backgroundStyle = "subtitle_style_background_style"
        static let backgroundOpacity = "subtitle_style_background_opacity"
        static let bottomOffset = "subtitle_style_bottom_offset"
        static let speechLocale = "subtitle_speech_recognition_locale"
        static let translationTargetLanguage = "subtitle_translation_target_language"
        static let autoEnableCloudSubtitles = "subtitle_pref_auto_enable_cloud"
        static let preferredPrimaryLanguage = "subtitle_pref_primary_language"
        static let preferredSecondaryLanguage = "subtitle_pref_secondary_language"
        static let autoTranslateEnabled = "subtitle_pref_auto_translate_enabled"
        static let autoSpeechMode = "subtitle_pref_auto_speech_mode"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var fontSizeScale: SubtitleFontSizeScale {
        didSet {
            defaults.set(fontSizeScale.rawValue, forKey: Keys.fontSizeScale)
        }
    }

    var backgroundStyle: SubtitleBackgroundStyle {
        didSet {
            defaults.set(backgroundStyle.rawValue, forKey: Keys.backgroundStyle)
        }
    }

    var backgroundOpacity: Double {
        didSet {
            let clamped = Self.clampOpacity(backgroundOpacity)
            if clamped != backgroundOpacity {
                backgroundOpacity = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.backgroundOpacity)
        }
    }

    var bottomOffset: Double {
        didSet {
            let clamped = Self.clampBottomOffset(bottomOffset)
            if clamped != bottomOffset {
                bottomOffset = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.bottomOffset)
        }
    }

    var speechLocale: SpeechSubtitleLocale {
        didSet {
            defaults.set(speechLocale.rawValue, forKey: Keys.speechLocale)
        }
    }

    var translationTargetLanguage: SubtitleTranslationTargetLanguage {
        didSet {
            defaults.set(translationTargetLanguage.rawValue, forKey: Keys.translationTargetLanguage)
        }
    }

    var autoEnableCloudSubtitles: Bool {
        didSet {
            defaults.set(autoEnableCloudSubtitles, forKey: Keys.autoEnableCloudSubtitles)
        }
    }

    var preferredPrimaryLanguage: SubtitlePreferredLanguage {
        didSet {
            defaults.set(preferredPrimaryLanguage.rawValue, forKey: Keys.preferredPrimaryLanguage)
        }
    }

    var preferredSecondaryLanguage: SubtitlePreferredSecondaryLanguage {
        didSet {
            defaults.set(preferredSecondaryLanguage.rawValue, forKey: Keys.preferredSecondaryLanguage)
        }
    }

    var autoTranslateEnabled: Bool {
        didSet {
            defaults.set(autoTranslateEnabled, forKey: Keys.autoTranslateEnabled)
        }
    }

    var autoSpeechMode: SubtitleAutoSpeechMode {
        didSet {
            defaults.set(autoSpeechMode.rawValue, forKey: Keys.autoSpeechMode)
        }
    }

    var hasAutoSubtitleBehaviorEnabled: Bool {
        autoEnableCloudSubtitles || autoSpeechMode != .off || autoTranslateEnabled
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawScale = defaults.string(forKey: Keys.fontSizeScale),
           let parsedScale = SubtitleFontSizeScale(rawValue: rawScale) {
            fontSizeScale = parsedScale
        } else {
            fontSizeScale = .standard
        }

        if let rawStyle = defaults.string(forKey: Keys.backgroundStyle),
           let parsedStyle = SubtitleBackgroundStyle(rawValue: rawStyle) {
            backgroundStyle = parsedStyle
        } else {
            backgroundStyle = .translucentBox
        }

        if defaults.object(forKey: Keys.backgroundOpacity) != nil {
            backgroundOpacity = Self.clampOpacity(defaults.double(forKey: Keys.backgroundOpacity))
        } else {
            backgroundOpacity = Self.defaultBackgroundOpacity
        }

        if defaults.object(forKey: Keys.bottomOffset) != nil {
            bottomOffset = Self.clampBottomOffset(defaults.double(forKey: Keys.bottomOffset))
        } else {
            bottomOffset = Self.defaultBottomOffset
        }

        if let rawLocale = defaults.string(forKey: Keys.speechLocale),
           let parsedLocale = SpeechSubtitleLocale(rawValue: rawLocale) {
            speechLocale = parsedLocale
        } else {
            speechLocale = .auto
        }

        if let rawTarget = defaults.string(forKey: Keys.translationTargetLanguage),
           let parsedTarget = SubtitleTranslationTargetLanguage(rawValue: rawTarget) {
            translationTargetLanguage = parsedTarget
        } else {
            translationTargetLanguage = .chineseSimplified
        }

        if defaults.object(forKey: Keys.autoEnableCloudSubtitles) != nil {
            autoEnableCloudSubtitles = defaults.bool(forKey: Keys.autoEnableCloudSubtitles)
        } else {
            autoEnableCloudSubtitles = false
        }

        if let rawPrimary = defaults.string(forKey: Keys.preferredPrimaryLanguage),
           let parsedPrimary = SubtitlePreferredLanguage(rawValue: rawPrimary) {
            preferredPrimaryLanguage = parsedPrimary
        } else {
            preferredPrimaryLanguage = .chineseSimplified
        }

        if let rawSecondary = defaults.string(forKey: Keys.preferredSecondaryLanguage),
           let parsedSecondary = SubtitlePreferredSecondaryLanguage(rawValue: rawSecondary) {
            preferredSecondaryLanguage = parsedSecondary
        } else {
            preferredSecondaryLanguage = .none
        }

        if defaults.object(forKey: Keys.autoTranslateEnabled) != nil {
            autoTranslateEnabled = defaults.bool(forKey: Keys.autoTranslateEnabled)
        } else {
            autoTranslateEnabled = false
        }

        if let rawSpeechMode = defaults.string(forKey: Keys.autoSpeechMode),
           let parsedSpeechMode = SubtitleAutoSpeechMode(rawValue: rawSpeechMode) {
            autoSpeechMode = parsedSpeechMode
        } else {
            autoSpeechMode = .off
        }
    }

    func resolveInitialCloudTracks(
        from available: [PlayerV2Info.SubtitleBox.SubtitleItem]
    ) -> (primaryLan: String?, secondaryLan: String?) {
        guard autoEnableCloudSubtitles else {
            return (nil, nil)
        }
        let validItems = available.compactMap { item -> (item: PlayerV2Info.SubtitleBox.SubtitleItem, lan: String)? in
            guard let lan = item.lan,
                  !lan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return (item, lan)
        }
        guard !validItems.isEmpty else {
            return (nil, nil)
        }

        let primaryMatch =
            validItems.first(where: { !$0.item.isAIGenerated && preferredPrimaryLanguage.matches(bilibiliLan: $0.lan) })
            ?? validItems.first(where: { $0.item.isAIGenerated && preferredPrimaryLanguage.matches(bilibiliLan: $0.lan) })
            ?? validItems.first

        guard let primaryLan = primaryMatch?.lan else {
            return (nil, nil)
        }

        let secondaryLan: String?
        if preferredSecondaryLanguage != .none {
            let candidates = validItems.filter { $0.lan != primaryLan }
            let secondaryMatch =
                candidates.first(where: { !$0.item.isAIGenerated && preferredSecondaryLanguage.matches(bilibiliLan: $0.lan) })
                ?? candidates.first(where: { $0.item.isAIGenerated && preferredSecondaryLanguage.matches(bilibiliLan: $0.lan) })
            secondaryLan = secondaryMatch?.lan
        } else {
            secondaryLan = nil
        }

        return (primaryLan, secondaryLan)
    }

    func resetAppearanceToDefaults() {
        fontSizeScale = .standard
        backgroundStyle = .translucentBox
        backgroundOpacity = Self.defaultBackgroundOpacity
        bottomOffset = Self.defaultBottomOffset
    }

    static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBackgroundOpacity }
        return min(max(value, minBackgroundOpacity), maxBackgroundOpacity)
    }

    static func clampBottomOffset(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBottomOffset }
        return min(max(value, minBottomOffset), maxBottomOffset)
    }
}
