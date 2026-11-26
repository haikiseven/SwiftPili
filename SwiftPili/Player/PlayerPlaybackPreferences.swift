import Foundation

enum PlayerPlaybackPreferences {
    static let ambientModeDefaultsKey = "player_ambient_mode_enabled"
    static let inAppMiniPlayerDefaultsKey = "in_app_mini_player_enabled"
    static let portraitVideoModeKey = "player_portrait_video_mode"
    static let defaultWifiAudioQuality: AudioQualityTier = .hiRes
    static let defaultCellularAudioQuality: AudioQualityTier = .k192

    static var wifiQuality: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "wifi_quality")
            return value > 0 ? value : 116
        }
        set { UserDefaults.standard.set(newValue, forKey: "wifi_quality") }
    }

    static var cellularQuality: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "cellular_quality")
            return value > 0 ? value : 64
        }
        set { UserDefaults.standard.set(newValue, forKey: "cellular_quality") }
    }

    static func preferredQuality(for network: NetworkType) -> Int {
        switch network {
        case .wifi: return wifiQuality
        case .cellular: return cellularQuality
        }
    }

    static var wifiAudioQuality: AudioQualityTier {
        get {
            AudioQualityTier(rawValue: UserDefaults.standard.integer(forKey: "wifi_audio_quality"))
                ?? defaultWifiAudioQuality
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "wifi_audio_quality") }
    }

    static var cellularAudioQuality: AudioQualityTier {
        get {
            AudioQualityTier(rawValue: UserDefaults.standard.integer(forKey: "cellular_audio_quality"))
                ?? defaultCellularAudioQuality
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cellular_audio_quality") }
    }

    static func preferredAudioQuality(for network: NetworkType) -> AudioQualityTier {
        switch network {
        case .wifi: return wifiAudioQuality
        case .cellular: return cellularAudioQuality
        }
    }

    static var playbackOrder: PlaybackOrder {
        get {
            if let raw = UserDefaults.standard.string(forKey: "playback_order"),
               let order = PlaybackOrder(rawValue: raw) {
                return order
            }
            return UserDefaults.standard.bool(forKey: "loop_playback") ? .loopOne : .playNext
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "playback_order") }
    }

    static var ambientModeEnabled: Bool {
        get {
            guard let value = UserDefaults.standard.object(
                forKey: ambientModeDefaultsKey
            ) as? Bool else { return true }
            return value
        }
        set { UserDefaults.standard.set(newValue, forKey: ambientModeDefaultsKey) }
    }

    static var animeSkipIntroOutro: Bool {
        get { UserDefaults.standard.bool(forKey: "anime_skip_op_ed") }
        set { UserDefaults.standard.set(newValue, forKey: "anime_skip_op_ed") }
    }

    static var backgroundAudioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "background_audio_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "background_audio_enabled") }
    }

    static var cdnFallbackEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cdn_fallback_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cdn_fallback_enabled") }
    }

    static var pictureInPictureEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "picture_in_picture_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "picture_in_picture_enabled") }
    }

    static var inAppMiniPlayerEnabled: Bool {
        get {
            PlayerDefaultBool.resolve(
                key: inAppMiniPlayerDefaultsKey,
                defaultValue: true
            )
        }
        set { UserDefaults.standard.set(newValue, forKey: inAppMiniPlayerDefaultsKey) }
    }

    static var portraitVideoMode: PortraitVideoPresentationMode {
        get { portraitVideoMode(from: .standard) }
        set { setPortraitVideoMode(newValue, in: .standard) }
    }

    static func portraitVideoMode(from defaults: UserDefaults) -> PortraitVideoPresentationMode {
        guard let raw = defaults.string(forKey: portraitVideoModeKey),
              let mode = PortraitVideoPresentationMode(rawValue: raw) else {
            return .inlineExpandable
        }
        return mode
    }

    static func setPortraitVideoMode(
        _ mode: PortraitVideoPresentationMode,
        in defaults: UserDefaults
    ) {
        defaults.set(mode.rawValue, forKey: portraitVideoModeKey)
    }

    static var playbackContinuationConfiguration: PlaybackContinuationConfiguration {
        PlaybackContinuationConfiguration(
            backgroundAudioEnabled: backgroundAudioEnabled,
            pictureInPictureEnabled: pictureInPictureEnabled
        )
    }

    static var resumePlayback: Bool {
        get {
            UserDefaults.standard.object(forKey: "resume_playback") as? Bool
                ?? UserDefaults.standard.object(forKey: "anime_resume_playback") as? Bool
                ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "resume_playback") }
    }

    static var preferredCodec: VideoCodecPreference {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "preferred_codec"),
                  let preference = VideoCodecPreference(rawValue: raw) else { return .auto }
            return preference
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "preferred_codec") }
    }

    static var hardwareDecodeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hardware_decode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hardware_decode") }
    }

    enum PreloadStrategy: String, CaseIterable {
        case minimal, standard, extended, maximum

        var maxBufferDuration: Double {
            switch self {
            case .minimal: 15
            case .standard: 30
            case .extended: 60
            case .maximum: 120
            }
        }

        var label: String {
            switch self {
            case .minimal: String(localized: "Minimal (15s)")
            case .standard: String(localized: "Standard (30s)")
            case .extended: String(localized: "Extended (60s)")
            case .maximum: String(localized: "Maximum (120s)")
            }
        }
    }

    static var preloadStrategy: PreloadStrategy {
        get {
            PreloadStrategy(rawValue: UserDefaults.standard.string(forKey: "preload_strategy") ?? "") ?? .extended
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "preload_strategy") }
    }

    static func clearDebugOnlyPlaybackExperiments() {
        let retiredKeys = [
            "settime_seek_experiment",
            "prefetch_filter_experiment",
            "pitch_corrected_rate",
            "patha_pitch_enabled_v2"
        ]
        for key in retiredKeys where UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum PlayerDefaultBool {
    static func resolve(
        key: String,
        defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let raw = defaults.object(forKey: key) else { return defaultValue }
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return defaultValue
            }
        }
        return defaultValue
    }
}

enum VideoCodecPreference: String, CaseIterable, Sendable {
    case auto
    case avc
    case hevc
    case av1

    var label: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .avc: "AVC (H.264)"
        case .hevc: "HEVC (H.265)"
        case .av1: "AV1"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .avc: "AVC"
        case .hevc: "HEVC"
        case .av1: "AV1"
        }
    }

    func matches(_ codecs: String) -> Bool {
        switch self {
        case .auto: true
        case .avc: codecs.hasPrefix("avc") || codecs.hasPrefix("h264")
        case .hevc: codecs.hasPrefix("hev") || codecs.hasPrefix("hvc") || codecs.hasPrefix("dvh")
        case .av1: codecs.hasPrefix("av01") || codecs.hasPrefix("av1")
        }
    }

    static func from(codecs: String) -> VideoCodecPreference? {
        [.avc, .hevc, .av1].first { $0.matches(codecs) }
    }
}
