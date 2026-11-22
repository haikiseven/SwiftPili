import Foundation

/// Preferred engine for the shared player: VOD, offline, and supported live input.
/// Live capability routing may hand incompatible input to libVLC separately.
/// Selection lasts for the shared `PlayerViewModel`'s process lifetime;
/// changing the setting takes effect on the next app launch.
enum PlayerEngineKind: String, CaseIterable, Codable, Sendable {
    /// Clock-paced push (SwiftVLC / libVLC), explicitly selectable.
    case vlc = "vlc"
    /// Demand-paced pull MediaEngine (Path A), the product default.
    case demandPaced = "demand"

    // The legacy key was rewritten to VLC by Release builds, so it cannot
    // distinguish a user choice from that reset. Only this version is active.
    static let storageKey = "vod_player_engine_v2"
    static let defaultKind: PlayerEngineKind = .demandPaced

    static var vodPreferred: PlayerEngineKind {
        resolvePreference(
            defaults: .standard,
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /// Read-only in both Debug and Release. Explicit launch overrides do not
    /// change the stored preference; absent/invalid active values use Demand.
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

    /// Pin LIVE playback to the selected engine even when that engine cannot
    /// demux what the room streams.
    ///
    /// Off (the default), a live load whose topology Demand cannot open is
    /// routed to libVLC at the requested rendition
    /// (`LiveEngineRoutePolicy`) — that is the whole point of the routing, and
    /// it is what makes ordinary TS/FLV rooms play when Demand is preferred. But it
    /// also means the gap stops being observable: with routing on, "Demand has
    /// no MPEG-TS demuxer" and "Demand plays every live room" produce the same
    /// screen. This pin is how the refusal stays reachable on a device, so the
    /// gap can be seen, filed and tested rather than inferred from source.
    ///
    /// Read the same three ways `vodPreferred` is, and for the same reasons:
    /// env first (`devicectl` eats dashed args), then a process arg, then a
    /// sticky DEBUG-only setting. Release ignores the stored pin so normal
    /// playback retains capability routing. Explicit launch pins remain
    /// available for diagnostics in either configuration.
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

    /// One-shot process override for device soak.
    ///
    /// Accepts (first match wins):
    /// 1. Env `VOD_ENGINE=demand|vlc` (prefer for `devicectl` —
    ///    dashed args like `-player-debug` get eaten as short options)
    /// 2. Args `-vod-engine demand` or `vod-engine=demand`
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

    /// Localized, unlike the previous plain-`String` names, which could never
    /// translate.
    var displayName: String {
        switch self {
        case .vlc: return String(localized: "libVLC")
        case .demandPaced: return String(localized: "In-house engine")
        }
    }

    /// Diagnostic picker choices. The picker stays DEBUG-only; the Demand
    /// default and explicit stored/launch selections work in both builds.
    static var userSelectableCases: [PlayerEngineKind] { [.vlc, .demandPaced] }

    var shortLabel: String {
        switch self {
        case .vlc: return "vlc"
        case .demandPaced: return "demand"
        }
    }

    /// Whether press-and-hold 2× is offered on this engine.
    ///
    /// Hold is only worth having if the speed-up is heard while the finger is
    /// still down. Demand applies rate at the last inch of the graph, so it
    /// engages in hundreds of milliseconds. libVLC re-strides only NEW output
    /// behind its `pts_delay`: device-measured, the audible change arrives
    /// ~10 s after the rate edge — typically after the finger has already
    /// lifted, so the gesture would speed up the wrong stretch of video.
    /// The speed menu stays available on both engines; only the hold is
    /// withdrawn.
    var supportsHoldFastForward: Bool {
        switch self {
        case .vlc: return false
        case .demandPaced: return true
        }
    }

    /// Whether this engine decodes an audio tier's codec — asked of the
    /// RUNNING engine by audio-stream selection, so a tier it cannot play is
    /// never chosen (Media3's "within renderer capabilities first").
    ///
    /// Every current tier is AAC or FLAC, and both engines decode both: Demand
    /// through `AudioToolboxAudioDecoder`, libVLC through its codec-agnostic
    /// audio slave. The switch is exhaustive on purpose — a Dolby tier added
    /// to `AudioQualityTier` must state its answer here per engine.
    func decodesAudio(_ tier: AudioQualityTier) -> Bool {
        switch tier {
        case .hiRes, .k192, .k132, .k64:
            return true
        }
    }
}
