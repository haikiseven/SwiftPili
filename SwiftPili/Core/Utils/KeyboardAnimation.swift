import SwiftUI
import UIKit

@MainActor
enum KeyboardAnimation {
    private static let fallbackDuration: TimeInterval = 0.25

    private static var observedDuration: TimeInterval?
    private static var observedCurve: UIView.AnimationCurve?
    private static var isObserving = false

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

    static let panelExpand: Animation = .spring(duration: 0.40, bounce: 0.12)

    static let panelCollapse: Animation = .smooth(duration: 0.32, extraBounce: 0)

    static var panelMorph: Animation { panelExpand }
}
