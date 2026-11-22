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
