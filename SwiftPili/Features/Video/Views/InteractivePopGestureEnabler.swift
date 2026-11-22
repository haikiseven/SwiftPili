import ObjectiveC
import SwiftUI
import UIKit

/// Keeps the system interactive pop gesture enabled across navigation stacks,
/// including screens that hide their navigation bar.
extension View {
    /// Preserves native leading-edge swipe-back on pushed destinations and
    /// prioritizes the edge pan over competing horizontal/player gestures.
    func keepsInteractivePopGesture() -> some View {
        background(
            InteractivePopGestureEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> ProbeController {
        ProbeController()
    }

    func updateUIViewController(_ controller: ProbeController, context _: Context) {
        controller.adoptIfPossible()
    }

    @MainActor
    final class ProbeController: UIViewController {
        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.view = view
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            adoptIfPossible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            adoptIfPossible()
        }

        func adoptIfPossible() {
            guard let navigation = nearestNavigationController else {
                PlayerLog.log("[PopGesture] probe: no UINavigationController in the parent chain")
                return
            }
            NavigationPopGestureOwner.owner(for: navigation).adopt()
        }

        private var nearestNavigationController: UINavigationController? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if let navigation = current as? UINavigationController { return navigation }
                if let navigation = current.navigationController { return navigation }
                candidate = current.parent
            }
            return nil
        }
    }
}

/// One pop-gesture delegate per `UINavigationController` instance.
///
/// Storing ownership on the navigation controller instead of per-page probes
/// prevents out-of-order dismantle (e.g. `goHome()` or tab reselect) from
/// restoring a dying probe's `replacedDelegate` and leaving `pop.delegate == nil`.
@MainActor
private final class NavigationPopGestureOwner: NSObject, UIGestureRecognizerDelegate {
    private nonisolated(unsafe) static var associatedKey: UInt8 = 0
    private static var measuringPop = false

    private weak var navigation: UINavigationController?
    private weak var systemDelegate: (any UIGestureRecognizerDelegate)?
    private var hasAddedTarget = false
    private var loggedCompetitors: Set<String> = []

    init(navigation: UINavigationController) {
        self.navigation = navigation
    }

    static func owner(for navigation: UINavigationController) -> NavigationPopGestureOwner {
        if let existing = objc_getAssociatedObject(navigation, &associatedKey) as? NavigationPopGestureOwner {
            return existing
        }
        let owner = NavigationPopGestureOwner(navigation: navigation)
        objc_setAssociatedObject(navigation, &associatedKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return owner
    }

    /// Re-asserts ownership on appearance and updates so SwiftUI's hidden-bar pass cannot disable the recognizer.
    func adopt() {
        guard let navigation, let pop = navigation.interactivePopGestureRecognizer else {
            PlayerLog.log("[PopGesture] adopt: navigation has NO interactivePopGestureRecognizer")
            return
        }

        if systemDelegate == nil, let existing = pop.delegate, !(existing is NavigationPopGestureOwner) {
            systemDelegate = existing
        }

        let isInitialAdopt = !hasAddedTarget
        if !hasAddedTarget {
            pop.addTarget(self, action: #selector(popStateChanged(_:)))
            hasAddedTarget = true
            PlayerLog.log(
                "[PopGesture] adopt: stack=\(navigation.viewControllers.count) " +
                    "recognizer=\(type(of: pop)) enabled=\(pop.isEnabled) " +
                    "delegate=\(pop.delegate.map { String(describing: type(of: $0)) } ?? "nil")"
            )
        }

        let delegateDrifted = pop.delegate !== self
        let wasDisabled = !pop.isEnabled
        if delegateDrifted { pop.delegate = self }
        if wasDisabled { pop.isEnabled = true }

        if !isInitialAdopt, delegateDrifted || wasDisabled {
            PlayerLog.log(
                "[PopGesture] re-asserted — delegate drifted: \(delegateDrifted), " +
                    "was disabled: \(wasDisabled)"
            )
        }
    }

    /// Competing recognizers on the leading edge defer when a pushed page can interactively pop.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard let navigation,
              navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil else {
            return false
        }
        let name = String(describing: type(of: other))
        if loggedCompetitors.insert(name).inserted {
            PlayerLog.log("[PopGesture] competitor defers to the edge pan: \(name)")
        }
        return true
    }

    /// Measures swipe-back as a `[Motion] name=page` interval from `.began` through settle.
    @objc private func popStateChanged(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began, let navigation else { return }
        guard let transition = navigation.transitionCoordinator else {
            if PlayerLog.isCapturing {
                PlayerLog.log("[PopGesture] began with no transition coordinator — not measured")
            }
            return
        }
        guard PlayerLog.isCapturing, !Self.measuringPop else { return }
        Self.measuringPop = true
        AnimationFrameDiagnostics.begin(.page)
        PlayerLog.log("[PopGesture] interactive pop began")
        transition.notifyWhenInteractionChanges { context in
            PlayerLog.log(
                "[PopGesture] finger lifted — \(context.isCancelled ? "cancelling" : "completing")"
            )
        }
        transition.animate(alongsideTransition: nil) { context in
            Self.measuringPop = false
            if context.isCancelled {
                AnimationFrameDiagnostics.cancel(.page)
            } else {
                AnimationFrameDiagnostics.settle(.page)
            }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation else {
            PlayerLog.log("[PopGesture] shouldBegin: refused — no navigation controller held")
            return false
        }
        guard navigation.viewControllers.count > 1 else {
            PlayerLog.log(
                "[PopGesture] shouldBegin: refused — stack depth " +
                    "\(navigation.viewControllers.count), nothing beneath"
            )
            return false
        }
        // Prevent starting a second interactive pop while a push or pop transition is still running.
        guard navigation.transitionCoordinator == nil else {
            PlayerLog.log("[PopGesture] shouldBegin: refused — a transition is still running")
            return false
        }
        PlayerLog.log("[PopGesture] shouldBegin: admitted")
        return true
    }
}
