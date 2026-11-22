import SwiftUI
import UIKit

enum AccentTheme: String, CaseIterable, Identifiable {
    /// Bilibili's `#FB7299`, distinct from the paler `.pink` (`#FCB0D9`) palette preset.
    case bilibiliPink = "Bilibili Pink"
    case pink = "Pink"
    case green = "Green"
    case orange = "Orange"
    case red = "Red"

    static let storageKey = "accent_theme"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .bilibiliPink: Color(red: 0.984, green: 0.447, blue: 0.600)
        case .pink: Color(red: 0.988, green: 0.690, blue: 0.851)
        case .green: Color(red: 0.392, green: 0.745, blue: 0.490)
        case .orange: Color(red: 0.949, green: 0.616, blue: 0.294)
        case .red: Color(red: 0.906, green: 0.376, blue: 0.376)
        }
    }

    /// Selected accent theme; defaults to `.bilibiliPink` when unset or unparseable.
    static var current: AccentTheme? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let theme = AccentTheme(rawValue: raw) else {
                return .bilibiliPink
            }
            return theme
        }
        set {
            // Nonisolated setter; callers reload `AccentStore.shared` after persisting.
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storageKey)
            }
        }
    }
}

/// Controls which surfaces receive a user-selected custom accent.
/// Settings icons, navigation/wayfinding glyphs, and status colors always remain neutral/fixed.
enum AccentScope: String, CaseIterable, Identifiable, Sendable {
    /// Applies the custom accent only to the bottom navigation's selected state.
    case bottomNavigationOnly
    /// Applies the custom accent to interactive controls and semantic accent surfaces (default).
    case controls
    /// Retained for decoding legacy `"global"` values; behaviorally equivalent to `.controls`.
    case semanticAccent = "global"

    static let storageKey = "accent_scope"
    static let migrationMarkerKey = "accent_scope_migrated_v1"

    struct Migration: Equatable, Sendable {
        let effectiveScope: AccentScope
        let rewriteStoredValue: String?
        let stampMarker: Bool

        var writesToStore: Bool { rewriteStoredValue != nil || stampMarker }
    }

    /// One-time migration from the legacy `bottomNavigationOnly` default to `.controls`.
    static func migrationDecision(storedRaw: String?, hasMigrated: Bool) -> Migration {
        let stored = storedRaw.flatMap(AccentScope.init(rawValue:))
        guard !hasMigrated else {
            return Migration(
                effectiveScope: stored ?? .controls,
                rewriteStoredValue: nil,
                stampMarker: false
            )
        }
        if stored == .bottomNavigationOnly {
            return Migration(
                effectiveScope: .controls,
                rewriteStoredValue: AccentScope.controls.rawValue,
                stampMarker: true
            )
        }
        return Migration(
            effectiveScope: stored ?? .controls,
            rewriteStoredValue: nil,
            stampMarker: true
        )
    }

    /// Rewrites `storageKey` before stamping `migrationMarkerKey` so a partial write never blesses the legacy default.
    @discardableResult
    static func resolveApplyingMigration() -> AccentScope {
        let defaults = UserDefaults.standard
        let decision = migrationDecision(
            storedRaw: defaults.string(forKey: storageKey),
            hasMigrated: defaults.bool(forKey: migrationMarkerKey)
        )
        if let rewrite = decision.rewriteStoredValue {
            defaults.set(rewrite, forKey: storageKey)
        }
        if decision.stampMarker {
            defaults.set(true, forKey: migrationMarkerKey)
        }
        return decision.effectiveScope
    }

    var id: String { rawValue }

    static let selectableCases: [AccentScope] = [.bottomNavigationOnly, .controls]

    /// Maps legacy `.semanticAccent` (`"global"`) to `.controls` for picker selection display.
    var pickerEquivalent: AccentScope {
        self == .semanticAccent ? .controls : self
    }

    var label: String {
        switch self {
        case .bottomNavigationOnly: return String(localized: "Bottom Navigation Only")
        case .controls: return String(localized: "Controls")
        case .semanticAccent: return String(localized: "Accent Elements")
        }
    }

    var includesControls: Bool { self != .bottomNavigationOnly }

    static var current: AccentScope {
        get { resolveApplyingMigration() }
        set { persist(newValue) }
    }

    /// Stamps `migrationMarkerKey` before writing `storageKey` so an explicit `.bottomNavigationOnly` pick is never re-migrated.
    static func persist(_ scope: AccentScope) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: migrationMarkerKey)
        defaults.set(scope.rawValue, forKey: storageKey)
    }
}

/// Observable source of truth for live accent updates across navigation chrome and content boundaries.
@Observable
@MainActor
final class AccentStore {
    static let shared = AccentStore()

    private(set) var theme: AccentTheme?
    private(set) var scope: AccentScope

    private init() {
        theme = AccentTheme.current
        scope = AccentScope.current
    }

    func reload() {
        let nextTheme = AccentTheme.current
        let nextScope = AccentScope.current
        if theme != nextTheme { theme = nextTheme }
        if scope != nextScope { scope = nextScope }
    }

    /// Tint for bottom navigation, or `nil` to keep the platform's default selected appearance.
    var navigationTint: Color? { theme?.color }

    /// Semantic accent for controls, selection states, links, and badges; falls back to `.accentColor` when unscoped or unset.
    var semanticAccent: Color {
        guard scope.includesControls, let theme else { return .accentColor }
        return theme.color
    }

    /// Environment tint applied inside `NavigationStack` content boundaries (`nil` falls back to platform accent).
    var contentTint: Color? {
        scope.includesControls ? theme?.color : nil
    }

    /// Raw semantic accent fill for white-text badges (`UPBadge`, `UPLikedTag`).
    var badgeFill: Color {
        semanticAccent
    }
}

extension View {
    /// Re-establishes content-scoped tint inside each `NavigationStack` without affecting `.tabItem` chrome.
    @MainActor func accentContentBoundary() -> some View {
        tint(AccentStore.shared.contentTint)
    }
}

/// Neutral SF Symbol glyph for settings rows; pass `tint` only for semantic overrides (e.g. destructive actions).
struct SettingsIcon: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint ?? Color.secondary)
    }
}

/// Homepage video list layout — single-column rows or a multi-column grid.
enum HomeLayoutMode: String, CaseIterable, Identifiable {
    case grid
    case list

    static let storageKey = "home_layout_mode_v2"

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        }
    }

    var icon: String {
        switch self {
        case .list: "rectangle.grid.1x2"
        case .grid: "square.grid.2x2"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance_mode"

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Color {
    /// Semantic accent resolved through `AccentStore` (falls back to platform `.accentColor` when unscoped or unset).
    @MainActor static var biliAccent: Color { AccentStore.shared.semanticAccent }

    /// Translucent placeholder and fitted-image letterbox fill (`secondarySystemFill`).
    static var imagePlaceholder: Color { Color(uiColor: .secondarySystemFill) }

    /// Opaque placeholder background (`secondarySystemBackground`) for standalone covers, avatars, and media cells.
    static var imagePlaceholderOpaque: Color { Color(uiColor: .secondarySystemBackground) }
}

extension ShapeStyle where Self == Color {
    @MainActor static var biliAccent: Color { AccentStore.shared.semanticAccent }
}
