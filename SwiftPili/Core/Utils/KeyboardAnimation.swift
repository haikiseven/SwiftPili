import SwiftUI
import UIKit

/// The system keyboard's own animation, so anything that moves with it moves on
/// its curve rather than on a guess beside it.
///
/// A composer panel raised from a launcher has exactly one source of motion:
/// the keyboard lifts it from the button's position to its own. Every transition
/// layered on top of that has been a second, competing answer — a
/// `matchedGeometryEffect` frame interpolation, a `.scale` anchor, a
/// `.move(edge:)`, each expressed relative to a frame the keyboard was already
/// moving. What is left is the panel's own insertion, which still changes its
/// container's height; on a different curve from the keyboard's that reads as
/// the panel stretching while it travels.
///
/// `UIResponder.keyboardWillShowNotification` publishes the real duration and
/// curve, so there is nothing to guess. They are cached rather than read live
/// because the panel is inserted BEFORE the field it contains can take focus —
/// the animation is chosen one step ahead of the notification that describes
/// it. Both values are stable for a given keyboard, so the previous show's
/// numbers describe this one.
@MainActor
enum KeyboardAnimation {
    /// UIKit's documented default for keyboard transitions, and the value the
    /// system has published for every keyboard observed here. Used until a real
    /// notification replaces it — on the very first open of a session there has
    /// been no keyboard to learn from.
    private static let fallbackDuration: TimeInterval = 0.25

    private static var observedDuration: TimeInterval?
    private static var observedCurve: UIView.AnimationCurve?
    private static var isObserving = false

    /// Start learning from the keyboard. Idempotent; call it once at launch.
    static func beginObserving() {
        guard !isObserving else { return }
        isObserving = true
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notification in
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
                let curveRawValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
                MainActor.assumeIsolated {
                    record(duration: duration, curveRawValue: curveRawValue)
                }
            }
        }
    }

    private static func record(duration: Double?, curveRawValue: Int?) {
        if let duration,
           duration.isFinite,
           duration > 0 {
            observedDuration = duration
        }
        if let curveRawValue,
           let curve = UIView.AnimationCurve(rawValue: curveRawValue) {
            observedCurve = curve
        }
    }

    /// The animation to give a state change that the keyboard will also move.
    ///
    /// The private curve UIKit uses for the keyboard (raw value 7) has no
    /// `Animation` equivalent; `.easeOut` is its closest public approximation
    /// and is what the system falls back to for third-party animations
    /// alongside it. The DURATION is the half that actually has to match — a
    /// curve mismatch reads as a slightly different ease, a duration mismatch
    /// reads as one of the two arriving late.
    static var current: Animation {
        let duration = observedDuration ?? fallbackDuration
        switch observedCurve {
        case .easeIn: return .easeIn(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        case .linear: return .linear(duration: duration)
        case .easeOut, .none: return .easeOut(duration: duration)
        @unknown default: return .easeOut(duration: duration)
        }
    }

    /// Apple `.snappy`-style slightly underdamped spring (`duration: 0.40s`,
    /// `bounce: 0.12` / `dampingRatio ≈ 0.88`) for expanding the comment composer
    /// from its `54×54` launcher to above the rising keyboard.
    static let panelExpand: Animation = .spring(duration: 0.40, bounce: 0.12)

    /// Apple critically damped spring (`duration: 0.32s`, `bounce: 0`) for folding
    /// the comment composer back into its `54×54` launcher without overshoot
    /// in lockstep with UIKit's keyboard descent.
    static let panelCollapse: Animation = .smooth(duration: 0.32, extraBounce: 0)

    static var panelMorph: Animation { panelExpand }
}
