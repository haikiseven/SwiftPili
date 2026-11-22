import SwiftUI

/// The app's corner radius scale. Every radius a view draws should be one of
/// these (or a capsule), so cards, chips and covers read as one family across
/// features instead of the seventeen values they had grown into.
///
/// Measured layout systems with their own derivations — `RowCardMetrics`,
/// `LibraryRowMetrics`, `FeedWidth`, `DetailStageLayout` — are not replaced by
/// this file; they decide sizes, this decides shape.
enum AppRadius {
    /// Duration and badge chips drawn on artwork.
    static let badge: CGFloat = 4
    /// Small images inside rows and posts.
    static let thumbnail: CGFloat = 8
    /// Chips, fields and content nested inside content.
    static let control: CGFloat = 10
    /// Covers and cards.
    static let card: CGFloat = 12
    /// Grouped panels and glass cards.
    static let panel: CGFloat = 20
}

/// The spacing scale for padding and stack spacing.
enum AppSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Fills for surfaces inside a page.
///
/// Semantic system colours on purpose: under a cinematic page's forced dark
/// scheme they already resolve to their dark values, so the surface context
/// (`AppSurface`) needs no fill table of its own.
enum AppFill {
    /// Grouped card / list-row surface on standard browsing screens.
    static var card: Color {
        Color(.secondarySystemGroupedBackground)
    }
    /// Chips, fields and other controls.
    static var inset: Color { Color(.tertiarySystemFill) }
    /// Content nested in content, such as a comment's reply preview.
    static var nested: Color { Color(.quaternarySystemFill) }
}
