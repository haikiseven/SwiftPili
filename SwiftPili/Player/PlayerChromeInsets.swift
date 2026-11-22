import SwiftUI

/// Container geometry contract supplied by the host to `PlayerView`.
/// Explicit rather than inferred because `UIView.safeAreaInsets` reports zeros
/// when a child sits inside an already-expanded container safe area.
enum PlayerContainerPresentation: Equatable, Sendable {
    /// Host already excluded the safe area; flat inline constants apply.
    case inlineSafeArea
    /// Full-bleed inline host drawing its own chrome (`hostChromeTop`/`hostChromeBottom`
    /// act as safe-area-inclusive floors, and `hostOwnsTransportRow` suppresses the
    /// player's bottom transport row when the host's bottom region intercepts touches).
    case inlineFullBleed(
        hostChromeTop: CGFloat,
        hostChromeBottom: CGFloat,
        hostOwnsTransportRow: Bool
    )
    /// Presented fullscreen container.
    case fullscreen
}

/// Additive chrome insets added to inline design constants (`.zero` for `.inlineSafeArea`).
struct PlayerChromeInsets: Equatable, Sendable {
    let top: CGFloat
    let bottom: CGFloat
    let horizontal: CGFloat

    static let zero = Self(top: 0, bottom: 0, horizontal: 0)

    /// Safety floors applied only to `.fullscreen` (inline full-bleed stays unfloored
    /// so devices without hardware cutouts are not artificially inset).
    static let fullscreenBottomFloor: CGFloat = 12
    static let fullscreenHorizontalPadding: CGFloat = 4
    static let fullscreenHorizontalFloor: CGFloat = 24

    static func resolve(
        presentation: PlayerContainerPresentation,
        windowTop: CGFloat,
        windowBottom: CGFloat,
        windowLeft: CGFloat,
        windowRight: CGFloat
    ) -> Self {
        switch presentation {
        case .inlineSafeArea:
            return .zero
        case let .inlineFullBleed(hostChromeTop, hostChromeBottom, _):
            return Self(
                top: max(max(0, windowTop), max(0, hostChromeTop)),
                bottom: max(max(0, windowBottom), max(0, hostChromeBottom)),
                horizontal: max(0, max(windowLeft, windowRight))
            )
        case .fullscreen:
            return Self(
                top: max(0, windowTop),
                bottom: max(max(0, windowBottom), fullscreenBottomFloor),
                horizontal: max(
                    max(0, max(windowLeft, windowRight)) + fullscreenHorizontalPadding,
                    fullscreenHorizontalFloor
                )
            )
        }
    }
}

/// Exclusive ownership of the bottom transport row (play/pause and fullscreen toggle),
/// resolved from the same `PlayerContainerPresentation` as `PlayerChromeInsets`.
enum PlayerTransportPlacement: Equatable, Sendable {
    /// Drawn by `PlayerView` at its bottom edge.
    case playerBottomEdge
    /// Owned by the full-bleed host; `PlayerView` mounts no transport row.
    case hostOwned

    static func resolve(presentation: PlayerContainerPresentation) -> Self {
        switch presentation {
        case let .inlineFullBleed(_, _, hostOwnsTransportRow):
            hostOwnsTransportRow ? .hostOwned : .playerBottomEdge
        case .inlineSafeArea, .fullscreen:
            .playerBottomEdge
        }
    }
}

extension View {
    @ViewBuilder
    func playerChromeCapsule(
        horizontal: CGFloat = 12,
        vertical: CGFloat = 6,
        minHeight: CGFloat? = nil
    ) -> some View {
        let base = font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
        if let minHeight {
            base
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
        } else {
            base
        }
    }
}
