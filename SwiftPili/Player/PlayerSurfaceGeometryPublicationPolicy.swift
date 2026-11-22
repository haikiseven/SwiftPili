import Foundation

enum PlayerSurfaceGeometryPublicationPolicy {
    enum DeviceClass: Equatable, Sendable {
        case iPhone
        case iPad
        case other
    }

    enum SceneSizeClass: Equatable, Sendable {
        case compact
        case regular
        case unknown
    }

    struct Context: Equatable, Sendable {
        let isFullscreen: Bool
        let sceneSizeClass: SceneSizeClass
        let deviceClass: DeviceClass
    }

    enum Decision: Equatable, Sendable {
        case publish(CGSize)
        case keepCurrent

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.keepCurrent, .keepCurrent):
                return true
            case let (.publish(left), .publish(right)):
                return left.width == right.width && left.height == right.height
            default:
                return false
            }
        }
    }

    static func decision(
        for candidateSize: CGSize,
        context: Context,
        currentPublishedSize: CGSize
    ) -> Decision {
        guard isUsable(candidateSize) else { return .keepCurrent }
        guard candidateSize.width != currentPublishedSize.width
                || candidateSize.height != currentPublishedSize.height else {
            return .keepCurrent
        }

        guard context.deviceClass == .iPhone else {
            return .publish(candidateSize)
        }

        if context.isFullscreen {
            return candidateSize.width > candidateSize.height
                ? .publish(candidateSize)
                : .keepCurrent
        }

        guard context.sceneSizeClass != .compact else { return .keepCurrent }
        return .publish(candidateSize)
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}
