import SwiftUI

enum PlayerContainerPresentation: Equatable, Sendable {
    case inlineSafeArea
    case inlineFullBleed(
        hostChromeTop: CGFloat,
        hostChromeBottom: CGFloat,
        hostOwnsTransportRow: Bool
    )
    case fullscreen
}

struct PlayerChromeInsets: Equatable, Sendable {
    let top: CGFloat
    let bottom: CGFloat
    let horizontal: CGFloat

    static let zero = Self(top: 0, bottom: 0, horizontal: 0)

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

enum PlayerTransportPlacement: Equatable, Sendable {
    case playerBottomEdge
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
