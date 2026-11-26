import Foundation

enum ExperimentalFeature: String, Codable, CaseIterable, Sendable {
    case equalizer, ambient, multiConnection, http2Probe
    case decoderPrewarm, commentTools, diagnostics, aiCommentFilter, videoEnhancement

    var mask: UInt32 {
        switch self {
        case .equalizer: 1 << 0
        case .ambient: 1 << 1
        case .multiConnection: 1 << 2
        case .http2Probe: 1 << 3
        case .decoderPrewarm: 1 << 4
        case .commentTools: 1 << 5
        case .diagnostics: 1 << 6
        case .aiCommentFilter: 1 << 7
        case .videoEnhancement: 1 << 8
        }
    }

    /// Mature features graduated to regular Settings / Advanced Settings and no longer gated
    /// by `ExperimentalSettingsSnapshot.masterEnabled`.
    var isGraduated: Bool {
        self != .http2Probe
    }

    /// Graduated features whose capability gate is always available because they expose
    /// direct feature-specific controls (SR/FI, EQ enabled, Parallel Connections, Auto-Verify,
    /// Debug Logging) or standalone tools (Comment Check, App Reports).
    var isAlwaysAvailableGraduated: Bool {
        switch self {
        case .equalizer, .multiConnection, .commentTools, .diagnostics, .videoEnhancement:
            true
        case .ambient, .decoderPrewarm, .aiCommentFilter, .http2Probe:
            false
        }
    }
}

struct ExperimentalDiagnosticOverrides: Codable, Equatable, Sendable {
    var vodEngine: PlayerEngineKind = .demandPaced
    var livePin = false
    var setTimeSeek = true
    var prefetchFilter = true
    var audioOutputSpeed = true
    var demandPitch = true

    static let stock = Self()
    static let fieldNames: Set<String> = [
        "vodEngine", "livePin", "setTimeSeek", "prefetchFilter", "audioOutputSpeed", "demandPitch"
    ]
}

struct ExperimentalSettingsSnapshot: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let defaultGrants: [ExperimentalFeature: Bool] = [
        .ambient: true,
        .decoderPrewarm: true,
        .equalizer: true,
        .multiConnection: true,
        .commentTools: true,
        .diagnostics: true,
        .videoEnhancement: true,
        .aiCommentFilter: false,
        .http2Probe: false
    ]

    var schemaVersion = currentSchema
    // swiftlint:disable:next inclusive_language
    var masterEnabled = false
    var grants: [ExperimentalFeature: Bool] = defaultGrants
    var diagnosticOverrides = ExperimentalDiagnosticOverrides.stock

    func isAllowed(_ feature: ExperimentalFeature) -> Bool {
        if feature.isAlwaysAvailableGraduated {
            return true
        }
        if feature.isGraduated {
            return grants[feature] == true
        }
        return masterEnabled && grants[feature] == true
    }

    /// Evaluates whether `feature` was effectively enabled under pre-graduation rules
    /// (where every feature required both `masterEnabled` and an explicit grant).
    func wasLegacyAllowed(_ feature: ExperimentalFeature) -> Bool {
        masterEnabled && grants[feature] == true
    }

    var effectiveMask: UInt32 {
        ExperimentalFeature.allCases.reduce(0) { $0 | (isAllowed($1) ? $1.mask : 0) }
    }

    private enum CodingKeys: String, CodingKey {
        // swiftlint:disable:next inclusive_language
        case schemaVersion, masterEnabled, grants, diagnosticOverrides
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        masterEnabled = try container.decode(Bool.self, forKey: .masterEnabled)
        let raw = try container.decode([String: Bool].self, forKey: .grants)
        grants = try Dictionary(uniqueKeysWithValues: raw.map { key, value in
            guard let feature = ExperimentalFeature(rawValue: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .grants, in: container, debugDescription: "Unknown feature"
                )
            }
            return (feature, value)
        })
        if grants[.ambient] == nil {
            if raw.isEmpty, !masterEnabled {
                masterEnabled = true
            }
            grants[.ambient] = true
        }
        diagnosticOverrides = try container.decode(ExperimentalDiagnosticOverrides.self, forKey: .diagnosticOverrides)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(masterEnabled, forKey: .masterEnabled)
        let rawGrants = Dictionary(uniqueKeysWithValues: grants.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawGrants, forKey: .grants)
        try container.encode(diagnosticOverrides, forKey: .diagnosticOverrides)
    }
}
