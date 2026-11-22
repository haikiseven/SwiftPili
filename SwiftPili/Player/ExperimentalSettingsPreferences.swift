import Foundation
import CoreFoundation

/// Storage only. Bootstrap is explicit and precedes every App preference effect.
enum ExperimentalSettingsPreferences {
    static let storageKey = "experimental_settings_v1"

    struct Record {
        let snapshot: ExperimentalSettingsSnapshot
        let storageError: String?
    }

    static func bootstrap(
        defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier
    ) -> Record {
        guard let bundleID, !bundleID.isEmpty else { return unavailableRecord }
        let domain = defaults.persistentDomain(forName: bundleID) ?? [:]
        if let stored = domain[storageKey] {
            guard let data = stored as? Data, let snapshot = decode(data) else { return unavailableRecord }
            return Record(snapshot: snapshot, storageError: nil)
        }
        let snapshot = migratedSnapshot(domain: domain)
        guard persist(snapshot, defaults: defaults) else { return unavailableRecord }
        return Record(snapshot: snapshot, storageError: nil)
    }

    static func persist(_ snapshot: ExperimentalSettingsSnapshot, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    private static var unavailableRecord: Record {
        Record(
            snapshot: ExperimentalSettingsSnapshot(),
            storageError: String(localized: "Experimental settings could not be read. Saved data has been preserved.")
        )
    }

    /// Unknown fields are read-only rather than silently discarded by Codable.
    private static func decode(_ data: Data) -> ExperimentalSettingsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["schemaVersion", "masterEnabled", "grants", "diagnosticOverrides"]),
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == ExperimentalSettingsSnapshot.currentSchema,
              version.doubleValue == Double(version.intValue),
              let grants = root["grants"] as? [String: Any],
              Set(grants.keys).isSubset(of: Set(ExperimentalFeature.allCases.map(\.rawValue))),
              let overrides = root["diagnosticOverrides"] as? [String: Any],
              Set(overrides.keys).isSubset(of: ExperimentalDiagnosticOverrides.fieldNames),
              let snapshot = try? JSONDecoder().decode(ExperimentalSettingsSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    private static func migratedSnapshot(domain: [String: Any]) -> ExperimentalSettingsSnapshot {
        var snapshot = ExperimentalSettingsSnapshot()
        guard isUpgrade(domain) else { return snapshot }
        snapshot.masterEnabled = true
        snapshot.grants = [
            .ambient: domain["player_ambient_mode_enabled"] as? Bool ?? true,
            .decoderPrewarm: domain["decoder_prewarm"] as? Bool ?? true,
            .equalizer: legacyEqualizerEnabled(domain),
            .multiConnection: bool(domain["multi_connection_enabled"], defaultValue: false),
            .http2Probe: bool(domain["smart_cdn_experimental_http2"], defaultValue: false),
            .commentTools: true,
            .diagnostics: true
        ]
        snapshot.diagnosticOverrides = ExperimentalDiagnosticOverrides(
            vodEngine: (domain[PlayerEngineKind.storageKey] as? String)
                .flatMap(PlayerEngineKind.init(rawValue:)) ?? .defaultKind,
            livePin: bool(domain[PlayerEngineKind.livePinStorageKey], defaultValue: false),
            setTimeSeek: bool(domain["settime_seek_experiment"], defaultValue: true),
            prefetchFilter: bool(domain["prefetch_filter_experiment"], defaultValue: true),
            audioOutputSpeed: bool(domain["pitch_corrected_rate"], defaultValue: true),
            demandPitch: bool(domain["patha_pitch_enabled_v2"], defaultValue: true)
        )
        return snapshot
    }

    private static func legacyEqualizerEnabled(_ domain: [String: Any]) -> Bool {
        guard let data = domain[PlayerEqualizerPreferences.defaultsKey] as? Data,
              let value = try? JSONDecoder().decode(PlayerEqualizerConfiguration.self, from: data),
              value.schemaVersion == PlayerEqualizerConfiguration.currentSchemaVersion else { return false }
        return value.normalized.enabled
    }

    private static func isUpgrade(_ domain: [String: Any]) -> Bool {
        if ["buvid3", "buvid4"].contains(where: { (domain[$0] as? String)?.isEmpty == false }) { return true }
        let featureKeys: Set<String> = [
            "player_ambient_mode_enabled", "decoder_prewarm", PlayerEqualizerPreferences.defaultsKey,
            "multi_connection_enabled", "multi_connection_cellular_enabled", "smart_cdn_experimental_http2",
            "comment_check_after_post", "debug_logging_enabled", "playback_debug_report_enabled",
            "image_perf_diagnostics_enabled", "image_perf_diagnostics_overlay", "image_loading_indicator_static",
            "image_ab_suppress_diagnostics", "image_ab_stable_geometry", "image_ab_async_decode",
            "image_ab_instant_transition", "image_ab_split_layout_probes", PlayerEngineKind.storageKey,
            PlayerEngineKind.livePinStorageKey, "settime_seek_experiment", "prefetch_filter_experiment",
            "pitch_corrected_rate", "patha_pitch_enabled_v2", "wifi_quality", "cellular_quality",
            "preload_strategy", "background_audio_enabled", "picture_in_picture_enabled", "cdn_service",
            "smart_cdn_enabled", "cdn_fallback_enabled", "block_pcdn", "preferred_codec", "hardware_decode"
        ]
        return !featureKeys.isDisjoint(with: domain.keys)
    }

    private static func bool(_ raw: Any?, defaultValue: Bool) -> Bool {
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: break
            }
        }
        return defaultValue
    }
}
