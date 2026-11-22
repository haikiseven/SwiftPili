import SwiftUI

/// Screen provenance for image diagnostics, carried through the environment.
///
/// A cover cell is built by a shared component (`VideoCardView`,
/// `GridVideoCardView`, `MediaGridView`) that has no idea which screen it is on,
/// and the screen is exactly what a re-materialisation problem has to be
/// attributed to. Passing it as a parameter would mean threading it through
/// every intermediate component; the environment carries it for free and
/// survives arbitrary nesting.
private struct ImageDiagnosticsScreenKey: EnvironmentKey {
    static let defaultValue = "-"
}

extension EnvironmentValues {
    var imageDiagnosticsScreen: String {
        get { self[ImageDiagnosticsScreenKey.self] }
        set { self[ImageDiagnosticsScreenKey.self] = newValue }
    }
}

extension View {
    /// Names the screen for every image cell below this point. Cheap
    /// unconditionally: one environment value, no observation, no work when
    /// diagnostics are off.
    func imageDiagnosticsScreen(_ name: String) -> some View {
        environment(\.imageDiagnosticsScreen, name)
    }

    /// Publishes scroll-active state to `ImageDiagnostics`.
    ///
    /// The device capture had an interval with **no new network or disk activity
    /// that still produced 8 stalls, worst 83ms**. Nothing in the log could say
    /// whether those landed during a drag or while the list sat still, and that
    /// distinction is what separates layout/re-materialisation cost from
    /// delivery cost. `onScrollPhaseChange` fires on phase edges only — a few
    /// times per gesture, not per frame — so this is not itself a scroll cost.
    ///
    /// `.idle` is the only phase that counts as not scrolling; `.decelerating`
    /// and `.animating` still produce frames that can drop.
    func imageDiagnosticsScrollTracking() -> some View {
        onScrollPhaseChange { _, newPhase in
            guard ImageDiagnostics.isEnabled else { return }
            ImageDiagnostics.isScrolling = newPhase != .idle
        }
    }
}
