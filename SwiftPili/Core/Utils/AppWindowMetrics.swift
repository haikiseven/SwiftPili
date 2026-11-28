import UIKit

@MainActor
enum AppWindowMetrics {
    private static var lastKnownActiveSafeAreaInsets: UIEdgeInsets?
    private static var lastKnownActiveBounds: CGRect?
    private static var lastKnownActiveFrameInScreen: CGRect?

    private static func normalWindows(in scene: UIWindowScene) -> [UIWindow] {
        scene.windows.filter {
            $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil
        }
    }

    private static func preferredWindow(in scenes: [UIWindowScene]) -> UIWindow? {
        let candidates = scenes.flatMap(normalWindows(in:))
        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }

    private static func hasValidPositiveBounds(_ bounds: CGRect) -> Bool {
        bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }

    private static func hasMatchingBoundsOrOrientation(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1 {
            return true
        }
        return (lhs.width >= lhs.height) == (rhs.width >= rhs.height)
    }

    private static func recordActiveWindow(_ window: UIWindow) {
        guard hasValidPositiveBounds(window.bounds) else { return }
        lastKnownActiveBounds = window.bounds
        lastKnownActiveFrameInScreen = window.convert(window.bounds, to: nil)
        if window.safeAreaInsets != .zero || lastKnownActiveSafeAreaInsets == nil {
            lastKnownActiveSafeAreaInsets = window.safeAreaInsets
        }
    }

    private static func resolveActiveWindow() -> UIWindow? {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let window = preferredWindow(in: activeScenes) else { return nil }
        recordActiveWindow(window)
        return window
    }

    private static func resolvedSafeAreaInsets(for window: UIWindow?) -> UIEdgeInsets {
        guard let window else {
            return lastKnownActiveSafeAreaInsets ?? .zero
        }
        let isActiveScene = window.windowScene?.activationState == .foregroundActive
        if isActiveScene {
            recordActiveWindow(window)
            if window.safeAreaInsets == .zero,
               let cached = lastKnownActiveSafeAreaInsets,
               cached != .zero,
               let cachedBounds = lastKnownActiveBounds,
               hasMatchingBoundsOrOrientation(window.bounds, cachedBounds) {
                return cached
            }
            return window.safeAreaInsets
        }
        if let cached = lastKnownActiveSafeAreaInsets,
           cached != .zero,
           lastKnownActiveBounds.map({ hasMatchingBoundsOrOrientation(window.bounds, $0) }) ?? true {
            return cached
        }
        return window.safeAreaInsets != .zero
            ? window.safeAreaInsets
            : (lastKnownActiveSafeAreaInsets ?? .zero)
    }

    static func window(for scene: UIWindowScene?) -> UIWindow? {
        guard let scene else { return current }
        let candidates = normalWindows(in: scene)
        let selected = candidates.first(where: \.isKeyWindow) ?? candidates.first
        if let selected, scene.activationState == .foregroundActive {
            recordActiveWindow(selected)
        }
        return selected
    }

    static func safeAreaInsets(for scene: UIWindowScene?) -> UIEdgeInsets {
        guard let scene else { return safeAreaInsets }
        return resolvedSafeAreaInsets(for: window(for: scene))
    }

    static func frameInScreen(for scene: UIWindowScene?) -> CGRect? {
        guard let scene else { return frameInScreen }
        if let window = window(for: scene), hasValidPositiveBounds(window.bounds) {
            if scene.activationState == .foregroundActive {
                return window.convert(window.bounds, to: nil)
            }
            return lastKnownActiveFrameInScreen ?? window.convert(window.bounds, to: nil)
        }
        return lastKnownActiveFrameInScreen
    }

    static func bottomInset(for scene: UIWindowScene?, orAtLeast layoutOwned: CGFloat) -> CGFloat {
        max(safeAreaInsets(for: scene).bottom, max(0, layoutOwned))
    }

    static var current: UIWindow? {
        if let active = resolveActiveWindow() {
            return active
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let inactiveScenes = scenes.filter { $0.activationState == .foregroundInactive }
        if let inactive = preferredWindow(in: inactiveScenes) {
            return inactive
        }
        let otherScenes = scenes.filter {
            $0.activationState != .foregroundActive && $0.activationState != .foregroundInactive
        }
        return preferredWindow(in: otherScenes)
    }

    static var resolvedBounds: CGRect? {
        if let active = resolveActiveWindow(), hasValidPositiveBounds(active.bounds) {
            return active.bounds
        }
        if let cached = lastKnownActiveBounds, hasValidPositiveBounds(cached) {
            return cached
        }
        if let fallback = current, hasValidPositiveBounds(fallback.bounds) {
            return fallback.bounds
        }
        return nil
    }

    static var safeAreaInsets: UIEdgeInsets {
        resolvedSafeAreaInsets(for: current)
    }

    static var frameInScreen: CGRect? {
        if let active = resolveActiveWindow(), hasValidPositiveBounds(active.bounds) {
            return active.convert(active.bounds, to: nil)
        }
        if let cached = lastKnownActiveFrameInScreen {
            return cached
        }
        guard let window = current, hasValidPositiveBounds(window.bounds) else { return nil }
        return window.convert(window.bounds, to: nil)
    }

    static func bottomInset(orAtLeast layoutOwned: CGFloat) -> CGFloat {
        max(safeAreaInsets.bottom, max(0, layoutOwned))
    }
}
