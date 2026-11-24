import SwiftUI

enum AppRadius {
    static let badge: CGFloat = 4
    static let thumbnail: CGFloat = 8
    static let control: CGFloat = 10
    static let card: CGFloat = 12
    static let panel: CGFloat = 20
}

enum AppSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum AppFill {
    static var card: Color {
        Color(.secondarySystemGroupedBackground)
    }
    static var inset: Color { Color(.tertiarySystemFill) }
    static var nested: Color { Color(.quaternarySystemFill) }
}

enum AppStroke {
    static let hairlineWidth: CGFloat = 0.5

    static func cardBorder(for colorScheme: ColorScheme, surface: AppSurface = .standard) -> Color {
        switch surface {
        case .cinematic:
            Color.white.opacity(0.10)
        case .standard:
            colorScheme == .dark
                ? Color.white.opacity(0.09)
                : Color.primary.opacity(0.07)
        }
    }

    static func chipBorder(
        isSelected: Bool,
        tint: Color,
        colorScheme: ColorScheme,
        reduceTransparency: Bool = false
    ) -> Color {
        if isSelected {
            return tint.opacity(reduceTransparency ? 0.48 : (colorScheme == .dark ? 0.42 : 0.34))
        }
        return colorScheme == .dark
            ? Color.white.opacity(reduceTransparency ? 0.16 : 0.10)
            : Color.primary.opacity(reduceTransparency ? 0.14 : 0.08)
    }

    static func glassBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.primary.opacity(0.10)
    }
}
