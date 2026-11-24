import SwiftUI
import UIKit

enum AccentTheme: String, CaseIterable, Identifiable {
    case bilibiliPink = "Bilibili Pink"
    case blue = "System Blue"
    case pink = "Pink"
    case green = "Green"
    case orange = "Orange"
    case red = "Red"

    static let storageKey = "accent_theme"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .bilibiliPink: Color(red: 0.984, green: 0.447, blue: 0.600)
        case .blue: Color(uiColor: .systemBlue)
        case .pink: Color(red: 0.988, green: 0.690, blue: 0.851)
        case .green: Color(red: 0.392, green: 0.745, blue: 0.490)
        case .orange: Color(red: 0.949, green: 0.616, blue: 0.294)
        case .red: Color(red: 0.906, green: 0.376, blue: 0.376)
        }
    }

    var alternateIconName: String? {
        switch self {
        case .bilibiliPink: nil
        case .blue: "AppIconBlue"
        case .pink: "AppIconPink"
        case .green: "AppIconGreen"
        case .orange: "AppIconOrange"
        case .red: "AppIconRed"
        }
    }

    static var current: AccentTheme? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let theme = AccentTheme(rawValue: raw) else {
                return .bilibiliPink
            }
            return theme
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storageKey)
            }
        }
    }
}

@MainActor
enum AppIconSync {
    static let storageKey = "sync_app_icon_with_accent"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: storageKey)
        }
    }

    static func targetIconName(for theme: AccentTheme?) -> String? {
        (theme ?? .bilibiliPink).alternateIconName
    }

    static func syncIfEnabled(for theme: AccentTheme?) {
        guard isEnabled else { return }
        let application = UIApplication.shared
        guard application.supportsAlternateIcons else { return }
        let targetName = targetIconName(for: theme)
        guard application.alternateIconName != targetName else { return }
        Task { @MainActor in
            try? await application.setAlternateIconName(targetName)
        }
    }
}

enum AccentScope: String, CaseIterable, Identifiable, Sendable {
    case bottomNavigationOnly
    case controls
    case semanticAccent = "global"

    static let storageKey = "accent_scope"
    static let migrationMarkerKey = "accent_scope_migrated_v1"

    struct Migration: Equatable, Sendable {
        let effectiveScope: AccentScope
        let rewriteStoredValue: String?
        let stampMarker: Bool

        var writesToStore: Bool { rewriteStoredValue != nil || stampMarker }
    }

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

    static func persist(_ scope: AccentScope) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: migrationMarkerKey)
        defaults.set(scope.rawValue, forKey: storageKey)
    }
}

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

    var navigationTint: Color? { theme?.color }

    var semanticAccent: Color {
        guard scope.includesControls, let theme else { return .accentColor }
        return theme.color
    }

    var contentTint: Color? {
        scope.includesControls ? theme?.color : nil
    }

    var badgeFill: Color {
        semanticAccent
    }
}

extension View {
    @MainActor func accentContentBoundary() -> some View {
        tint(AccentStore.shared.contentTint)
    }
}

struct SettingsIcon: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint ?? Color.secondary)
    }
}

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
    @MainActor static var biliAccent: Color { AccentStore.shared.semanticAccent }

    static var imagePlaceholder: Color { Color(uiColor: .secondarySystemFill) }

    static var imagePlaceholderOpaque: Color { Color(uiColor: .secondarySystemBackground) }
}

extension ShapeStyle where Self == Color {
    @MainActor static var biliAccent: Color { AccentStore.shared.semanticAccent }
}
