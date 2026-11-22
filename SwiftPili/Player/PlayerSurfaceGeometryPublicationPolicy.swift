import Foundation

/// The caller supplies all platform state so this policy remains a pure,
/// deterministic decision about the size cached for surface gestures.
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

    /// Returns the next cached surface size, if this geometry sample is
    /// useful to the gesture layer. Layout and diagnostics still observe
    /// every GeometryReader sample at the call site.
    ///
    /// On iPhone, fullscreen is the landscape authority. A portrait-shaped
    /// sample while fullscreen is active is therefore an orientation
    /// intermediate and must not invalidate the cached inline size. During
    /// exit, compact vertical size class is the corresponding intermediate;
    /// regular (or unavailable) context keeps the legacy full publication
    /// behavior so ambiguous multi-window layouts are not filtered.
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

        // iPad and unknown device classes intentionally retain the old
        // all-samples publication behavior. Their size class is not a safe
        // proxy for orientation under Stage Manager or multi-window layouts.
        guard context.deviceClass == .iPhone else {
            return .publish(candidateSize)
        }

        if context.isFullscreen {
            // Do not encode a video aspect ratio or device pixel size. The
            // final settled sample only needs to be wider than it is tall.
            return candidateSize.width > candidateSize.height
                ? .publish(candidateSize)
                : .keepCurrent
        }

        // A compact iPhone scene while the VM is inline is the exit/rotation
        // intermediate. Regular and unknown contexts preserve the existing
        // publication behavior for stable inline, portrait VOD, and portrait
        // live surfaces.
        guard context.sceneSizeClass != .compact else { return .keepCurrent }
        return .publish(candidateSize)
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}
