import UIKit

/// The app's own window, and the safe-area values that can be trusted from it.
///
/// **Why this exists, and it is not defensive tidying.** Four screens read the
/// home-indicator inset with the same expression:
///
/// ```swift
/// UIApplication.shared.connectedScenes
///     .compactMap { $0 as? UIWindowScene }
///     .flatMap(\.windows)
///     .first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
/// ```
///
/// That search space admits **any** `UIWindow` in **any** connected scene, and
/// `UIWindowScene.windows` includes UIKit's own: `UITextEffectsWindow` and
/// `UIRemoteKeyboardWindow` are both `UIWindow` subclasses, both are created the
/// first time a keyboard appears, and both then persist for the life of the
/// scene — so a wrong pick survives keyboard dismissal. They report **zero**
/// safe-area insets. `connectedScenes` is also an unordered `Set`, so
/// `flatMap` + `first` is not deterministic once more than one scene has a key
/// window.
///
/// The failure is silent and asymmetric, which is what made it a device bug
/// rather than a crash: a **nil** result falls back to a GeometryReader value
/// and is right by accident, while a **wrong** result has no fallback at all and
/// takes the layout boundary with it. In portrait live that cost exactly
/// `safeAreaBottom(34) − bottomDesignSpacing(10) = 24pt`, and the danmaku input
/// row sat 24pt below the safe-area boundary on every notched iPhone with the
/// keyboard down, while every height budget on that screen was healthy.
///
/// Three filters, each excluding a specific impostor:
///  - `activationState == .foregroundActive` — a background or unattached scene
///    can still hold a key window with stale metrics;
///  - `windowLevel == .normal` — the keyboard windows sit above `.normal`;
///  - `rootViewController != nil` — UIKit's service windows host no controller,
///    and the app's window always does.
///
/// `isKeyWindow` is then a preference among the survivors rather than the test
/// itself: during a modal transition or a scene handoff the app's window can
/// briefly not be key, and its insets are still the right ones.
@MainActor
enum AppWindowMetrics {
    /// The app's foreground window, or nil before one exists (previews, early
    /// launch, a scene being torn down).
    static var current: UIWindow? {
        let candidates = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil }
        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }

    /// PHYSICAL device insets — notch/Dynamic Island and home indicator. Never
    /// the keyboard: `UIWindow.safeAreaInsets` does not include it, which is the
    /// property that made a window probe attractive here in the first place.
    ///
    /// `.zero` when no window is available, so a caller that needs a floor must
    /// say so — see `bottomInset(orAtLeast:)`.
    static var safeAreaInsets: UIEdgeInsets { current?.safeAreaInsets ?? .zero }

    /// The window's frame in SCREEN coordinates. Keyboard notifications are in
    /// screen space, so this is the rectangle a keyboard frame may be compared
    /// against — and the one a full-bleed overlay is actually laid out in.
    static var frameInScreen: CGRect? {
        guard let window = current else { return nil }
        return window.convert(window.bounds, to: nil)
    }

    /// The bottom inset, floored by a value the LAYOUT owns.
    ///
    /// The floor is the whole point: a probe that comes back wrong must only
    /// ever be ignored, never allowed to lower a boundary. Pass the container's
    /// own `safeAreaInsets.bottom` when the caller sits in a context whose safe
    /// area still describes the physical inset — a `GeometryReader` that has
    /// already opted out of the keyboard region does, and that value cannot be
    /// faked by a foreign window because it comes from the layout system.
    static func bottomInset(orAtLeast layoutOwned: CGFloat) -> CGFloat {
        max(safeAreaInsets.bottom, max(0, layoutOwned))
    }
}
