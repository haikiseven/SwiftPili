import SwiftUI

/// Press feedback for custom plain controls. Uses lightweight system opacity
/// feedback without per-button geometry readers or state observers.
struct AppControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

extension ButtonStyle where Self == AppControlButtonStyle {
    static var appControl: AppControlButtonStyle { AppControlButtonStyle() }
}

extension View {
    func appValueFeedback<Value: Equatable>(value: Value) -> some View {
        contentTransition(.opacity)
    }

    func appToggleFeedback(
        isOn: Bool, userActionInFlight: Bool = false, userTaps: Int = 0, playsHaptic: Bool = true
    ) -> some View {
        contentTransition(.symbolEffect(.replace))
            .sensoryFeedback(.impact(weight: .light), trigger: playsHaptic ? userTaps : 0)
    }

    func appToggleHaptic(isOn: Bool, userActionInFlight: Bool = false, userTaps: Int = 0) -> some View {
        sensoryFeedback(.impact(weight: .light), trigger: userTaps)
    }

    func appStateLabelFeedback(isOn: Bool, userActionInFlight _: Bool) -> some View {
        contentTransition(.interpolate)
    }

    func appCountFeedback(value: Int) -> some View {
        contentTransition(.numericText(value: Double(value)))
    }

    func appSelectionHaptic(userPicks: Int) -> some View {
        sensoryFeedback(.selection, trigger: userPicks)
    }

    func appDisclosureRotation(isExpanded: Bool) -> some View {
        rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
            .animation(.snappy(duration: 0.2), value: isExpanded)
    }
}
