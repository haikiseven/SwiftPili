import ObjectiveC
import SwiftUI
import UIKit

extension View {
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

    static func dismantleUIViewController(_ controller: ProbeController, coordinator _: Void) {
        controller.relinquishIfNeeded()
    }

    @MainActor
    final class ProbeController: UIViewController {
        private weak var adoptedNavigation: UINavigationController?

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

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            relinquishIfNeeded()
        }

        func adoptIfPossible() {
            guard let navigation = nearestNavigationController else {
                PlayerLog.log("[PopGesture] probe: no UINavigationController in the parent chain")
                return
            }
            if let previous = adoptedNavigation, previous !== navigation {
                NavigationPopGestureOwner.owner(for: previous).relinquish(probe: ObjectIdentifier(self))
            }
            adoptedNavigation = navigation
            NavigationPopGestureOwner.owner(for: navigation).adopt(probe: ObjectIdentifier(self))
        }

        func relinquishIfNeeded() {
            let navigation = adoptedNavigation ?? nearestNavigationController
            adoptedNavigation = nil
            guard let navigation else { return }
            NavigationPopGestureOwner.owner(for: navigation).relinquish(probe: ObjectIdentifier(self))
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

@MainActor
private final class NavigationPopGestureOwner: NSObject, UIGestureRecognizerDelegate {
    private nonisolated(unsafe) static var associatedKey: UInt8 = 0
    private static var measuringPop = false

    private weak var navigation: UINavigationController?
    private weak var systemDelegate: (any UIGestureRecognizerDelegate)?
    private var hasAddedTarget = false
    private var activeProbes: Set<ObjectIdentifier> = []
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

    func adopt(probe: ObjectIdentifier) {
        activeProbes.insert(probe)
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

    func relinquish(probe: ObjectIdentifier) {
        activeProbes.remove(probe)
        guard activeProbes.isEmpty,
              let navigation,
              let pop = navigation.interactivePopGestureRecognizer else { return }
        if hasAddedTarget {
            pop.removeTarget(self, action: #selector(popStateChanged(_:)))
            hasAddedTarget = false
        }
        if pop.delegate === self {
            pop.delegate = systemDelegate
            PlayerLog.log("[PopGesture] relinquished — restored system delegate")
        }
    }

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
        PlayerLog.log("[PopGesture] interactive pop began")
        transition.notifyWhenInteractionChanges { context in
            PlayerLog.log(
                "[PopGesture] finger lifted — \(context.isCancelled ? "cancelling" : "completing")"
            )
        }
        transition.animate(alongsideTransition: nil) { _ in
            Self.measuringPop = false
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
        guard navigation.transitionCoordinator == nil else {
            PlayerLog.log("[PopGesture] shouldBegin: refused — a transition is still running")
            return false
        }
        PlayerLog.log("[PopGesture] shouldBegin: admitted")
        return true
    }
}
