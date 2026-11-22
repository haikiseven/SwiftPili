import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How matched AI-generated comments are handled in comment feeds.
enum CommentAIFilterMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case badgeOnly
    case autoCollapse
    case hideCompletely

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .badgeOnly: String(localized: "Badge Only")
        case .autoCollapse: String(localized: "Auto-Collapse")
        case .hideCompletely: String(localized: "Hide Completely")
        }
    }

    var localizedSummary: String {
        switch self {
        case .badgeOnly:
            String(localized: "Show a subtle AI suspicion badge next to the author name.")
        case .autoCollapse:
            String(localized: "Collapse suspected AI comments into a compact bar you can expand.")
        case .hideCompletely:
            String(localized: "Hide suspected AI comments from the feed without breaking pagination.")
        }
    }
}

/// Score threshold preset for classifying a comment as suspected AI.
enum CommentAIFilterSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case lenient
    case standard
    case strict

    var id: String { rawValue }

    /// Minimum 0–100 score required to trigger filtering.
    var threshold: Int {
        switch self {
        case .lenient: 75
        case .standard: 58
        case .strict: 42
        }
    }

    var localizedTitle: String {
        switch self {
        case .lenient: String(localized: "Lenient")
        case .standard: String(localized: "Standard")
        case .strict: String(localized: "Strict")
        }
    }
}

/// 4-way sensitivity selection unifying preset sensitivity levels and a custom score threshold.
enum CommentAIFilterSensitivityOption: String, CaseIterable, Identifiable, Sendable {
    case lenient
    case standard
    case strict
    case custom

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .lenient: String(localized: "Lenient")
        case .standard: String(localized: "Standard")
        case .strict: String(localized: "Strict")
        case .custom: String(localized: "Custom")
        }
    }
}

/// User-customizable detection rules and keyword lists for the AI comment auto-filter.
struct CommentAIFilterRuleSet: Codable, Equatable, Sendable {
    var accountIdentityEnabled: Bool = true
    var avatarBlueEnabled: Bool = true
    var textPersonaEnabled: Bool = true
    var lowLevelBoostEnabled: Bool = true
    var customAccountKeywords: [String] = []
    var customContentKeywords: [String] = []
    /// Optional explicit 30–90 score threshold override; `nil` uses `sensitivity.threshold`.
    var customThresholdOverride: Int?

    static let `default` = Self()

    var activeDimensionCount: Int {
        [accountIdentityEnabled, avatarBlueEnabled, textPersonaEnabled, lowLevelBoostEnabled]
            .filter { $0 }.count
    }

    var customKeywordCount: Int {
        customAccountKeywords.count + customContentKeywords.count
    }

    func effectiveThreshold(for sensitivity: CommentAIFilterSensitivity) -> Int {
        if let override = customThresholdOverride {
            return max(30, min(90, override))
        }
        return sensitivity.threshold
    }
}

/// Persisted preferences for the experimental AI comment auto-filter.
struct CommentAIFilterConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var mode: CommentAIFilterMode = .autoCollapse
    var sensitivity: CommentAIFilterSensitivity = .standard
    var foundationModelsRefinerEnabled: Bool = true
    var allowedAuthorMIDs: Set<Int> = []
    var allowedAuthorNames: [Int: String] = [:]
    var rules: CommentAIFilterRuleSet = .default

    static let `default` = Self()

    init(
        schemaVersion: Int = currentSchemaVersion,
        mode: CommentAIFilterMode = .autoCollapse,
        sensitivity: CommentAIFilterSensitivity = .standard,
        foundationModelsRefinerEnabled: Bool = true,
        allowedAuthorMIDs: Set<Int> = [],
        allowedAuthorNames: [Int: String] = [:],
        rules: CommentAIFilterRuleSet = .default
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.sensitivity = sensitivity
        self.foundationModelsRefinerEnabled = foundationModelsRefinerEnabled
        self.allowedAuthorMIDs = allowedAuthorMIDs
        self.allowedAuthorNames = allowedAuthorNames
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        mode = try container.decodeIfPresent(CommentAIFilterMode.self, forKey: .mode) ?? .autoCollapse
        sensitivity = try container.decodeIfPresent(CommentAIFilterSensitivity.self, forKey: .sensitivity) ?? .standard
        foundationModelsRefinerEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .foundationModelsRefinerEnabled
        ) ?? true
        allowedAuthorMIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .allowedAuthorMIDs) ?? []
        allowedAuthorNames = try container.decodeIfPresent([Int: String].self, forKey: .allowedAuthorNames) ?? [:]
        rules = try container.decodeIfPresent(CommentAIFilterRuleSet.self, forKey: .rules) ?? .default
    }

    var effectiveThreshold: Int {
        rules.effectiveThreshold(for: sensitivity)
    }

    /// Clamps a score threshold to `30...90` and rounds it to the nearest step of 5.
    static func normalizedCustomThreshold(_ value: Int) -> Int {
        let clamped = max(30, min(90, value))
        return ((clamped + 2) / 5) * 5
    }

    /// Unified 4-way sensitivity selector backed by `sensitivity` and `rules.customThresholdOverride`.
    var sensitivitySelection: CommentAIFilterSensitivityOption {
        get {
            if rules.customThresholdOverride != nil {
                return .custom
            }
            switch sensitivity {
            case .lenient: return .lenient
            case .standard: return .standard
            case .strict: return .strict
            }
        }
        set {
            switch newValue {
            case .lenient:
                sensitivity = .lenient
                rules.customThresholdOverride = nil
            case .standard:
                sensitivity = .standard
                rules.customThresholdOverride = nil
            case .strict:
                sensitivity = .strict
                rules.customThresholdOverride = nil
            case .custom:
                rules.customThresholdOverride = Self.normalizedCustomThreshold(effectiveThreshold)
            }
        }
    }

    /// Concise summary of the active sensitivity mode (`"\(effectiveThreshold)%"` when custom).
    var effectiveSensitivitySummary: String {
        if rules.customThresholdOverride != nil {
            return "\(effectiveThreshold)%"
        }
        return sensitivity.localizedTitle
    }

    var sortedAllowedAuthors: [(mid: Int, name: String?)] {
        allowedAuthorMIDs.sorted().map { mid in
            (mid: mid, name: allowedAuthorNames[mid])
        }
    }
}

/// UserDefaults persistence for `CommentAIFilterConfiguration`.
enum CommentAIFilterPreferences {
    static let storageKey = "comment_ai_filter_config_v1"

    static func load(defaults: UserDefaults = .standard) -> CommentAIFilterConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(CommentAIFilterConfiguration.self, from: data),
              decoded.schemaVersion == CommentAIFilterConfiguration.currentSchemaVersion else {
            return .default
        }
        return decoded
    }

    @discardableResult
    static func save(
        _ config: CommentAIFilterConfiguration,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}

/// Output of the two-stage local AI comment detection pipeline.
struct CommentAIAssessment: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case heuristic
        case refined
    }

    /// 0–100 suspicion score.
    let score: Int
    /// Concise human-readable rationale tags explaining why the score was assigned.
    let reasons: [String]
    let stage: Stage

    /// Borderline Stage 1 scores eligible for Stage 2 on-device model refinement.
    static let borderlineRange: ClosedRange<Int> = 30...69

    var isBorderline: Bool {
        stage == .heuristic && Self.borderlineRange.contains(score)
    }

    func matches(_ config: CommentAIFilterConfiguration) -> Bool {
        score >= config.effectiveThreshold
    }

    func matches(_ sensitivity: CommentAIFilterSensitivity) -> Bool {
        score >= sensitivity.threshold
    }
}

/// Runtime availability of Apple's on-device `FoundationModels` refiner.
enum CommentAIFilterAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedOS

    var isAvailable: Bool { self == .available }

    var localizedStatusText: String {
        switch self {
        case .available:
            String(localized: "On-device Apple Intelligence model is available for borderline comments.")
        case .deviceNotEligible:
            String(localized: "This device does not support Apple Intelligence. Using local heuristic rules only.")
        case .appleIntelligenceNotEnabled:
            String(localized: "Apple Intelligence is turned off in System Settings. Using local heuristic rules only.")
        case .modelNotReady:
            String(localized: "On-device language model is still preparing. Falling back to local heuristic rules.")
        case .unsupportedOS:
            String(localized: "Requires iOS 26 or later with Apple Intelligence. Using local heuristic rules only.")
        }
    }

    static var current: Self {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .modelNotReady
                }
            }
        }
        #endif
        return .unsupportedOS
    }
}
