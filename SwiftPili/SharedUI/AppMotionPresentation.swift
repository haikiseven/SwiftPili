import Observation
import SwiftUI
import UIKit

@MainActor @Observable
private final class AppMotionSystemPreferences: NSObject {
    static let shared = AppMotionSystemPreferences()
    private(set) var prefersCrossFade = UIAccessibility.prefersCrossFadeTransitions

    private override init() {
        super.init()
        let center = NotificationCenter.default
        for notification in [UIAccessibility.prefersCrossFadeTransitionsStatusDidChange,
                             UIAccessibility.reduceMotionStatusDidChangeNotification,
                             UIApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(refresh), name: notification, object: nil)
        }
    }

    @objc private func refresh() {
        prefersCrossFade = UIAccessibility.prefersCrossFadeTransitions
    }
}

struct AppMotionPreferences {
    let reduceMotion: Bool
    let prefersCrossFade: Bool

    var reducesGeometry: Bool {
        !AppMotionPolicy.usesGeometry(for: .control, reduceMotion: reduceMotion,
                                      prefersCrossFade: prefersCrossFade)
    }

    func animation(normal: Animation) -> Animation? {
        reducesGeometry ? nil : normal
    }

    @MainActor func settle(normal: Animation, changes: () -> Void, completion: @escaping () -> Void) {
        if reducesGeometry {
            withAnimation(nil, changes)
            completion()
        } else {
            withAnimation(normal, completionCriteria: .logicallyComplete, changes, completion: completion)
        }
    }

    func transition(normal: AnyTransition) -> AnyTransition {
        reducesGeometry ? .opacity : normal
    }

    func feedbackAnimation(normal: Animation) -> Animation {
        reducesGeometry ? .easeInOut(duration: AppMotionPolicy.duration(
            for: .control, reduceMotion: reduceMotion, prefersCrossFade: prefersCrossFade
        )) : normal
    }

    @MainActor static var current: Self {
        .init(reduceMotion: UIAccessibility.isReduceMotionEnabled,
              prefersCrossFade: UIAccessibility.prefersCrossFadeTransitions)
    }
}

@propertyWrapper
struct AppMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor var wrappedValue: AppMotionPreferences {
        .init(reduceMotion: reduceMotion,
              prefersCrossFade: AppMotionSystemPreferences.shared.prefersCrossFade)
    }
}

enum AppTransitionMotion {
    struct ContentEntrance: Sendable {
        let initialOpacity: Double
        let initialScale: CGFloat
        let verticalOffset: CGFloat
    }

    static let localContentEntrance = ContentEntrance(
        initialOpacity: 0.84,
        initialScale: 1.0,
        verticalOffset: 6
    )

    static let contentDuration: TimeInterval = 0.22
    static var contentSpring: Spring {
        .smooth(duration: contentDuration, extraBounce: 0)
    }

    static let detailInsertionOpacity = 0.70
    static let detailInsertionScale: CGFloat = 0.985
    static let detailInsertionOffset: CGFloat = 72
    static let detailRemovalScale: CGFloat = 0.995
    static let detailRemovalOffset: CGFloat = 30

    static var detailTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: DetailTransitionModifier(
                    opacity: detailInsertionOpacity,
                    scale: detailInsertionScale,
                    trailingOffset: detailInsertionOffset
                ),
                identity: DetailTransitionModifier(opacity: 1, scale: 1, trailingOffset: 0)
            ),
            removal: .modifier(
                active: DetailTransitionModifier(
                    opacity: 0,
                    scale: detailRemovalScale,
                    trailingOffset: detailRemovalOffset
                ),
                identity: DetailTransitionModifier(opacity: 1, scale: 1, trailingOffset: 0)
            )
        )
    }

    static var detailEntryAnimation: Animation {
        .spring(duration: 0.46, bounce: 0.10)
    }

    static var detailExitAnimation: Animation {
        .smooth(duration: 0.28, extraBounce: 0)
    }
}

private struct DetailTransitionModifier: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let trailingOffset: CGFloat
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let horizontalOffset = layoutDirection == .leftToRight ? trailingOffset : -trailingOffset
        content
            .opacity(opacity)
            .scaleEffect(scale, anchor: .trailing)
            .offset(x: horizontalOffset)
    }
}

private struct ContentSwitchMotionModifier<Trigger: Equatable & Sendable>: ViewModifier {
    let trigger: Trigger
    @AppMotion private var motion

    func body(content: Content) -> some View {
        let animation = motion.feedbackAnimation(
            normal: .easeOut(duration: AppTransitionMotion.contentDuration)
        )
        content
            .animation(animation, value: trigger)
    }
}

extension View {
    func appContentSwitchMotion<Trigger: Equatable & Sendable>(trigger: Trigger) -> some View {
        modifier(ContentSwitchMotionModifier(trigger: trigger))
    }
}
