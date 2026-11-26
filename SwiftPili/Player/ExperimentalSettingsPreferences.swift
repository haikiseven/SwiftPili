import Foundation
import CoreFoundation

enum ExperimentalSettingsPreferences {
    static let storageKey = "experimental_settings_v1"
    static let graduationMarkerKey = "experimental_features_graduated_v1"
    static let decoderPrewarmDefaultsKey = "decoder_prewarm"

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
            guard let data = stored as? Data, let decoded = decode(data) else { return unavailableRecord }
            if bool(domain[graduationMarkerKey], defaultValue: false) {
                let normalized = normalizeGraduatedSnapshot(decoded, domain: domain)
                return Record(snapshot: normalized, storageError: nil)
            }
            let migrated = graduateLegacySnapshot(decoded, domain: domain, defaults: defaults)
            guard persist(migrated, defaults: defaults) else { return unavailableRecord }
            defaults.set(true, forKey: graduationMarkerKey)
            return Record(snapshot: migrated, storageError: nil)
        }
        let snapshot = migratedSnapshot(domain: domain)
        guard persist(snapshot, defaults: defaults) else { return unavailableRecord }
        defaults.set(true, forKey: graduationMarkerKey)
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

    private static func normalizeGraduatedSnapshot(
        _ decoded: ExperimentalSettingsSnapshot,
        domain: [String: Any]
    ) -> ExperimentalSettingsSnapshot {
        var snapshot = decoded
        for feature in ExperimentalFeature.allCases where feature.isAlwaysAvailableGraduated {
            snapshot.grants[feature] = true
        }
        if let rawAmbient = domain[PlayerPlaybackPreferences.ambientModeDefaultsKey] {
            snapshot.grants[.ambient] = bool(rawAmbient, defaultValue: snapshot.grants[.ambient] ?? true)
        } else if snapshot.grants[.ambient] == nil {
            snapshot.grants[.ambient] = true
        }
        if let rawPrewarm = domain[decoderPrewarmDefaultsKey] {
            snapshot.grants[.decoderPrewarm] = bool(
                rawPrewarm,
                defaultValue: snapshot.grants[.decoderPrewarm] ?? true
            )
        } else if snapshot.grants[.decoderPrewarm] == nil {
            snapshot.grants[.decoderPrewarm] = true
        }
        return snapshot
    }

    private static func graduateLegacySnapshot(
        _ legacy: ExperimentalSettingsSnapshot,
        domain: [String: Any],
        defaults: UserDefaults
    ) -> ExperimentalSettingsSnapshot {
        let ambientOn = legacy.wasLegacyAllowed(.ambient)
        defaults.set(ambientOn, forKey: PlayerPlaybackPreferences.ambientModeDefaultsKey)

        let decoderPrewarmOn: Bool
        if let explicit = legacy.grants[.decoderPrewarm] {
            decoderPrewarmOn = legacy.masterEnabled && explicit
        } else {
            decoderPrewarmOn = true
        }
        defaults.set(decoderPrewarmOn, forKey: decoderPrewarmDefaultsKey)

        if !legacy.wasLegacyAllowed(.equalizer),
           let data = domain[PlayerEqualizerPreferences.defaultsKey] as? Data,
           var eq = try? JSONDecoder().decode(PlayerEqualizerConfiguration.self, from: data),
           eq.schemaVersion == PlayerEqualizerConfiguration.currentSchemaVersion,
           eq.normalized.enabled {
            eq = eq.normalized
            eq.enabled = false
            if let encoded = try? JSONEncoder().encode(eq) {
                defaults.set(encoded, forKey: PlayerEqualizerPreferences.defaultsKey)
            }
        }

        if !legacy.wasLegacyAllowed(.videoEnhancement) {
            if domain[VideoEnhancementPreferences.defaultSRBackendKey] != nil {
                defaults.set(
                    VideoSuperResolutionMode.off.persistenceValue,
                    forKey: VideoEnhancementPreferences.defaultSRBackendKey
                )
            }
            if bool(domain[VideoEnhancementPreferences.defaultFrameInterpolationKey], defaultValue: false) {
                defaults.set(false, forKey: VideoEnhancementPreferences.defaultFrameInterpolationKey)
            }
        }

        if !legacy.wasLegacyAllowed(.multiConnection),
           bool(domain[MultiConnectionFeatureGate.defaultsKey], defaultValue: false) {
            defaults.set(false, forKey: MultiConnectionFeatureGate.defaultsKey)
        }

        if !legacy.wasLegacyAllowed(.commentTools),
           bool(domain["comment_check_after_post"], defaultValue: false) {
            defaults.set(false, forKey: "comment_check_after_post")
        }

        let diagnosticsWasAllowed = legacy.wasLegacyAllowed(.diagnostics)
        if !diagnosticsWasAllowed,
           bool(domain["debug_logging_enabled"], defaultValue: false) {
            defaults.set(false, forKey: "debug_logging_enabled")
        }

        let aiCommentFilterOn = legacy.wasLegacyAllowed(.aiCommentFilter)
        let http2ProbeOn = legacy.wasLegacyAllowed(.http2Probe)

        var migrated = ExperimentalSettingsSnapshot()
        migrated.masterEnabled = http2ProbeOn
        migrated.grants = [
            .ambient: ambientOn,
            .decoderPrewarm: decoderPrewarmOn,
            .equalizer: true,
            .multiConnection: true,
            .commentTools: true,
            .diagnostics: true,
            .videoEnhancement: true,
            .aiCommentFilter: aiCommentFilterOn,
            .http2Probe: http2ProbeOn
        ]
        migrated.diagnosticOverrides = diagnosticsWasAllowed ? legacy.diagnosticOverrides : .stock
        return migrated
    }

    private static func migratedSnapshot(domain: [String: Any]) -> ExperimentalSettingsSnapshot {
        var snapshot = ExperimentalSettingsSnapshot()
        guard isUpgrade(domain) else { return snapshot }
        let http2ProbeOn = bool(domain["smart_cdn_experimental_http2"], defaultValue: false)
        snapshot.masterEnabled = http2ProbeOn
        snapshot.grants = [
            .ambient: bool(domain[PlayerPlaybackPreferences.ambientModeDefaultsKey], defaultValue: true),
            .decoderPrewarm: bool(domain[decoderPrewarmDefaultsKey], defaultValue: true),
            .equalizer: true,
            .multiConnection: true,
            .http2Probe: http2ProbeOn,
            .commentTools: true,
            .diagnostics: true,
            .videoEnhancement: true,
            .aiCommentFilter: false
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
