import Foundation

enum PlayerEngineKind: String, CaseIterable, Codable, Sendable {
    case vlc = "vlc"
    case demandPaced = "demand"

    static let storageKey = "vod_player_engine_v2"
    static let defaultKind: PlayerEngineKind = .demandPaced

    static var vodPreferred: PlayerEngineKind {
        resolvePreference(
            defaults: .standard,
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func resolvePreference(
        defaults: UserDefaults,
        environment: [String: String],
        arguments: [String]
    ) -> PlayerEngineKind {
        guard ExperimentalSettingsPolicy.diagnosticsEnabled else { return defaultKind }
        if let override = processArgumentEngineOverride(environment: environment, arguments: arguments) {
            return override
        }
        if let raw = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[storageKey] as? String,
           let kind = PlayerEngineKind(rawValue: raw) { return kind }
        return ExperimentalSettingsPolicy.diagnosticOverrides.vodEngine
    }

    static let livePinStorageKey = "live_engine_pin"

    static var pinsLiveEngine: Bool {
        guard ExperimentalSettingsPolicy.diagnosticsEnabled else { return false }
        if let env = ProcessInfo.processInfo.environment["LIVE_ENGINE_PIN"] {
            return env == "1" || env.lowercased() == "true"
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-live-engine-pin") || args.contains("live-engine-pin=1") {
            return true
        }
        #if DEBUG
        if let raw = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[livePinStorageKey] {
            return (raw as? Bool) ?? (raw as? String).map {
                ["1", "true", "yes", "on"].contains($0.lowercased())
            } ?? false
        }
        return ExperimentalSettingsPolicy.diagnosticOverrides.livePin
        #else
        return false
        #endif
    }

    private static func processArgumentEngineOverride(
        environment: [String: String],
        arguments: [String]
    ) -> PlayerEngineKind? {
        if let env = environment["VOD_ENGINE"],
           let kind = PlayerEngineKind(rawValue: env) {
            return kind
        }
        let args = arguments
        if let idx = args.firstIndex(of: "-vod-engine"),
           idx + 1 < args.count,
           let kind = PlayerEngineKind(rawValue: args[idx + 1]) {
            return kind
        }
        for arg in args {
            if arg.hasPrefix("vod-engine="),
               let kind = PlayerEngineKind(rawValue: String(arg.dropFirst("vod-engine=".count))) {
                return kind
            }
        }
        return nil
    }

    var displayName: String {
        switch self {
        case .vlc: return String(localized: "libVLC")
        case .demandPaced: return String(localized: "In-house engine")
        }
    }

    static var userSelectableCases: [PlayerEngineKind] { [.vlc, .demandPaced] }

    var shortLabel: String {
        switch self {
        case .vlc: return "vlc"
        case .demandPaced: return "demand"
        }
    }

    var supportsHoldFastForward: Bool {
        switch self {
        case .vlc: return false
        case .demandPaced: return true
        }
    }

    func decodesAudio(_ tier: AudioQualityTier) -> Bool {
        switch tier {
        case .hiRes, .k192, .k132, .k64:
            return true
        }
    }
}
