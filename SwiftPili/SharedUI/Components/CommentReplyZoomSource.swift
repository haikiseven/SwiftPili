import SwiftUI
import UIKit

struct CommentZoomEnvironment<Content: View>: View {
    let content: Content
    let values: EnvironmentValues

    var body: some View {
        content.environment(\.self, values)
    }
}

private typealias ReplyZoomContext = UIViewController.Transition.ZoomSourceViewProviderContext

struct CommentReplyZoomContainer<Root: View, Destination: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    @AppMotion private var motion
    let presentation: CommentZoomPresentation
    let root: Root
    let destination: Destination
    var ownsKeyboardSafeArea = true
    let onDismissed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CommentReplyNavigationController()
        controller.overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
        controller.setNavigationBarHidden(true, animated: false)
        controller.view.backgroundColor = .clear
        controller.view.clipsToBounds = true
        controller.allowsInteractivePop = ownsKeyboardSafeArea
        controller.delegate = context.coordinator
        controller.onAppearance = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        return controller
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        let style: UIUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
        if controller.overrideUserInterfaceStyle != style {
            controller.overrideUserInterfaceStyle = style
        }
        context.coordinator.update(
            navigation: controller, intent: presentation,
            configuration: CommentReplyZoomConfiguration(
                reducesMotion: motion.reducesGeometry,
                ownsKeyboardSafeArea: ownsKeyboardSafeArea,
                onDismissed: onDismissed
            ),
            root: CommentZoomEnvironment(content: root, values: environment),
            destination: CommentZoomEnvironment(content: destination, values: environment)
        )
    }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        (controller as? CommentReplyNavigationController)?.onAppearance = nil
        coordinator.retire()
    }

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, CommentZoomDismissalHost {
        private weak var navigation: UINavigationController?
        private weak var intent: CommentZoomPresentation?
        private var root: UIHostingController<CommentZoomEnvironment<Root>>?
        private var destination: UIHostingController<CommentZoomEnvironment<Destination>>?
        private var destinationContent: CommentZoomEnvironment<Destination>?
        private var reducesMotion = false
        private var ownsKeyboardSafeArea = true
        private var onDismissed: (() -> Void)?
        private var isTransitioning = false
        private var transitionTarget: ObjectIdentifier?
        private var isProgrammaticPop = false
        private var isRetired = false
        private var pendingAction: (destination: ObjectIdentifier, perform: @MainActor () -> Void)?

        private var rootVisibility: CommentReplyRootVisibility?

        func update(
            navigation: UINavigationController, intent: CommentZoomPresentation,
            configuration: CommentReplyZoomConfiguration, root: CommentZoomEnvironment<Root>,
            destination: CommentZoomEnvironment<Destination>
        ) {
            self.navigation = navigation
            if self.intent !== intent {
                self.intent?.detach(self)
                cancelPendingAction()
                self.intent = intent
                intent.attach(self)
            }
            self.reducesMotion = configuration.reducesMotion
            self.ownsKeyboardSafeArea = configuration.ownsKeyboardSafeArea
            self.onDismissed = configuration.onDismissed
            (navigation as? CommentReplyNavigationController)?.allowsInteractivePop = configuration.ownsKeyboardSafeArea
            destinationContent = destination
            let style: UIUserInterfaceStyle = root.values.colorScheme == .dark ? .dark : .light
            self.destination?.overrideUserInterfaceStyle = style
            navigation.view.backgroundColor = .clear
            self.destination?.view.backgroundColor = commentReplyDestinationSurface(
                ownsKeyboardSafeArea: self.ownsKeyboardSafeArea
            )
            self.root?.view.backgroundColor = .clear
            applyCommentKeyboardSafeAreaPolicy(self.ownsKeyboardSafeArea, to: self.destination)
            let rootID = self.root.map(ObjectIdentifier.init)
            let isPopping = isTransitioning && (isProgrammaticPop || transitionTarget == rootID)
            if !isPopping { self.destination?.rootView = destination }
            if let controller = self.root {
                controller.overrideUserInterfaceStyle = style
                applyCommentKeyboardSafeAreaPolicy(self.ownsKeyboardSafeArea, to: controller)
                controller.rootView = root
            } else {
                let controller = UIHostingController(rootView: root)
                controller.overrideUserInterfaceStyle = style
                controller.view.backgroundColor = .clear
                applyCommentKeyboardSafeAreaPolicy(self.ownsKeyboardSafeArea, to: controller)
                self.root = controller
                navigation.setViewControllers([controller], animated: false)
            }
            reconcile()
        }

        func reconcile() {
            guard !isRetired, !isTransitioning, let navigation, let intent,
                  navigation.viewIfLoaded?.window != nil, let root else { return }
            let animated = !ownsKeyboardSafeArea || !reducesMotion
            if intent.isPresented {
                cancelPendingAction()
                guard destination == nil, navigation.topViewController === root,
                      let destinationContent else { return }
                let controller = makeDestination(content: destinationContent, anchors: intent.anchors)
                destination = controller
                isProgrammaticPop = false
                isTransitioning = true
                navigation.pushViewController(
                    controller, animated: animated
                )
            } else if let destination, navigation.topViewController === destination {
                isProgrammaticPop = true
                isTransitioning = true
                navigation.popToViewController(
                    root, animated: animated
                )
            }
        }

        func dismissThenPerform(_ action: @escaping @MainActor () -> Void) {
            guard !isRetired, let intent else { return }
            intent.isPresented = false
            guard let destination else {
                action()
                return
            }
            pendingAction = (ObjectIdentifier(destination), action)
            reconcile()
        }

        func cancelPendingAction() { pendingAction = nil }

        private func makeDestination(
            content: CommentZoomEnvironment<Destination>, anchors: CommentZoomAnchors
        ) -> UIHostingController<CommentZoomEnvironment<Destination>> {
            let controller = UIHostingController(rootView: content)
            controller.overrideUserInterfaceStyle = content.values.colorScheme == .dark ? .dark : .light
            controller.view.backgroundColor = commentReplyDestinationSurface(
                ownsKeyboardSafeArea: ownsKeyboardSafeArea
            )
            applyCommentKeyboardSafeAreaPolicy(ownsKeyboardSafeArea, to: controller)
            guard ownsKeyboardSafeArea else { return controller }
            let options = UIViewController.Transition.ZoomOptions()
            options.dimmingColor = .clear
            let origin = CommentZoomTouchOrigin(anchors: anchors)
            controller.view.addGestureRecognizer(origin)
            options.interactiveDismissShouldBegin = { [weak self, weak origin, weak controller] context in
                guard let self, !self.reducesMotion else { return false }
                if origin?.permitsDismissal == true, context.velocity.dy > abs(context.velocity.dx) {
                    return true
                }
                guard let view = controller?.viewIfLoaded, view.bounds.width > 0 else { return false }
                let isRTL = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                let edgeThreshold: CGFloat = 36
                let isLeadingEdge = isRTL
                    ? context.location.x >= view.bounds.width - edgeThreshold
                    : context.location.x <= edgeThreshold
                let isLeadingSwipe = isRTL
                    ? -context.velocity.dx > abs(context.velocity.dy)
                    : context.velocity.dx > abs(context.velocity.dy)
                return isLeadingEdge && isLeadingSwipe
            }
            if !reducesMotion, let sourceController = root, let source = anchors.transitionSource,
               source.isDescendant(of: sourceController.view) {
                let sourceRoot = sourceController
                let provider: (ReplyZoomContext) -> UIView? = { [weak anchors, weak sourceRoot] context in
                    guard let source = anchors?.transitionSource, let sourceRoot,
                          context.sourceViewController === sourceRoot,
                          source.isDescendant(of: sourceRoot.view) else { return nil }
                    return source
                }
                controller.preferredTransition = .zoom(options: options, sourceViewProvider: provider)
            }
            return controller
        }

        func navigationController(
            _ navigationController: UINavigationController,
            animationControllerFor operation: UINavigationController.Operation,
            from fromVC: UIViewController,
            to toVC: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            guard !isRetired, navigationController === navigation,
                  !ownsKeyboardSafeArea,
                  operation == .push || operation == .pop,
                  fromVC.preferredTransition == nil,
                  toVC.preferredTransition == nil else {
                return nil
            }
            return CommentReplySlideAnimator(isPush: operation == .push, reducesMotion: reducesMotion)
        }

        func navigationController(
            _ navigationController: UINavigationController,
            willShow viewController: UIViewController, animated: Bool
        ) {
            guard !isRetired, navigationController === navigation else { return }
            isTransitioning = true
            transitionTarget = ObjectIdentifier(viewController)
            coordinateRootVisibility(in: navigationController, showing: viewController, animated: animated)
        }

        private func coordinateRootVisibility(
            in navigation: UINavigationController, showing controller: UIViewController, animated: Bool
        ) {
            guard let transition = navigation.transitionCoordinator else {
                restoreRootVisibility()
                return
            }
            let transitionID = ObjectIdentifier(transition)
            if rootVisibility?.transitionID == transitionID { return }
            restoreRootVisibility()
            guard ownsKeyboardSafeArea, animated, !reducesMotion, let root, let destination,
                  let fromController = transition.viewController(forKey: .from),
                  let toController = transition.viewController(forKey: .to), toController === controller,
                  (fromController === root && toController === destination)
                    || (fromController === destination && toController === root),
                  let view = root.viewIfLoaded else { return }
            let revealsRoot = toController === root
            if destination.preferredTransition != nil,
               view.mask == nil,
               let source = intent?.anchors.transitionSource,
               source.isDescendant(of: view) {
                installZoomRootMask(
                    in: transition, transitionID: transitionID, view: view, revealsRoot: revealsRoot
                )
                return
            }
        }

        private func installZoomRootMask(
            in transition: UIViewControllerTransitionCoordinator,
            transitionID: ObjectIdentifier,
            view: UIView,
            revealsRoot: Bool
        ) {
            let bounds = view.bounds
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite,
                  !bounds.isEmpty else { return }
            let mask = UIView(frame: bounds)
            mask.backgroundColor = .white
            mask.alpha = 0
            let visibility = CommentReplyRootVisibility(
                transitionID: transitionID, view: view, mask: mask, originalMask: view.mask
            )
            rootVisibility = visibility
            let queued = transition.animateAlongsideTransition(in: mask, animation: { [weak self] _ in
                guard let self, self.rootVisibility?.id == visibility.id else { return }
                guard visibility.view.mask === visibility.originalMask else {
                    self.restoreRootVisibility(id: visibility.id)
                    return
                }
                UIView.performWithoutAnimation {
                    visibility.mask.alpha = 0
                    visibility.view.mask = visibility.mask
                }
                if revealsRoot { visibility.mask.alpha = 1 }
            }, completion: { [weak self] _ in
                self?.restoreRootVisibility(id: visibility.id)
            })
            if !queued { restoreRootVisibility(id: visibility.id) }
        }

        private func restoreRootVisibility(id: UUID? = nil) {
            root?.viewIfLoaded?.alpha = 1
            guard let visibility = rootVisibility,
                  id == nil || visibility.id == id else { return }
            rootVisibility = nil
            if visibility.view.mask === visibility.mask {
                UIView.performWithoutAnimation { visibility.view.mask = visibility.originalMask }
            }
        }

        func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController, animated: Bool
        ) {
            guard !isRetired, navigationController === navigation, let intent else { return }
            isTransitioning = false
            let target = transitionTarget
            transitionTarget = nil
            if let destination, viewController === destination {
                if let root, target == ObjectIdentifier(root) {
                    cancelPendingAction()
                    intent.isPresented = true
                }
                isProgrammaticPop = false
                reconcile()
                return
            }
            guard viewController === root, let destination,
                  !navigationController.viewControllers.contains(where: { $0 === destination }) else { return }
            let reopen = isProgrammaticPop && intent.isPresented
            let action = !reopen && pendingAction?.destination == ObjectIdentifier(destination)
                ? pendingAction?.perform : nil
            cancelPendingAction()
            self.destination = nil
            isProgrammaticPop = false
            if reopen {
                reconcile()
            } else {
                intent.isPresented = false
                onDismissed?()
                action?()
            }
        }

        func retire() {
            restoreRootVisibility()
            isRetired = true
            cancelPendingAction()
            intent?.detach(self)
            intent = nil
            navigation?.delegate = nil
            onDismissed = nil
            destinationContent = nil
            destination = nil
            root = nil
            navigation = nil
        }
    }
}

private struct CommentReplyRootVisibility {
    let id = UUID()
    let transitionID: ObjectIdentifier
    let view: UIView
    let mask: UIView
    let originalMask: UIView?
}

struct CommentReplyZoomConfiguration {
    let reducesMotion: Bool
    let ownsKeyboardSafeArea: Bool
    let onDismissed: () -> Void
}

@MainActor
private final class CommentReplyNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    var onAppearance: (() -> Void)?
    var allowsInteractivePop = false

    override func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.isEnabled = true
        interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *), let contentPop = interactiveContentPopGestureRecognizer {
            contentPop.isEnabled = true
            contentPop.delegate = self
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppearance?()
    }

    private var canBeginInteractivePop: Bool {
        allowsInteractivePop
            && viewControllers.count > 1
            && transitionCoordinator == nil
            && topViewController?.preferredTransition == nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === interactivePopGestureRecognizer {
            return canBeginInteractivePop
        }
        if #available(iOS 26.0, *), gestureRecognizer === interactiveContentPopGestureRecognizer {
            guard canBeginInteractivePop, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            return isLeadingEdgeHorizontalSwipe(pan)
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === interactivePopGestureRecognizer {
            if #available(iOS 26.0, *), otherGestureRecognizer === interactiveContentPopGestureRecognizer {
                return true
            }
            return otherGestureRecognizer.view is UIScrollView
        }
        if #available(iOS 26.0, *), gestureRecognizer === interactiveContentPopGestureRecognizer {
            return otherGestureRecognizer.view is UIScrollView
        }
        return false
    }

    private func isLeadingEdgeHorizontalSwipe(_ pan: UIPanGestureRecognizer) -> Bool {
        guard let targetView = pan.view ?? view, targetView.bounds.width > 0 else { return false }
        let isRTL = targetView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let translation = pan.translation(in: targetView)
        let velocity = pan.velocity(in: targetView)
        let startX = pan.location(in: targetView).x - translation.x
        let edgeThreshold: CGFloat = 40
        let isLeadingEdge = isRTL
            ? startX >= targetView.bounds.width - edgeThreshold
            : startX <= edgeThreshold
        let isLeadingDirection = isRTL
            ? velocity.x < -abs(velocity.y)
            : velocity.x > abs(velocity.y)
        return isLeadingEdge && isLeadingDirection
    }
}

private func commentReplyDestinationSurface(ownsKeyboardSafeArea: Bool) -> UIColor {
    ownsKeyboardSafeArea ? .secondarySystemGroupedBackground : .clear
}

@MainActor
private func applyCommentKeyboardSafeAreaPolicy<T: View>(
    _ ownsKeyboard: Bool,
    to controller: UIHostingController<T>?
) {
    guard let controller else { return }
    if ownsKeyboard {
        if !controller.safeAreaRegions.contains(.keyboard) {
            controller.safeAreaRegions.insert(.keyboard)
        }
    } else if controller.safeAreaRegions.contains(.keyboard) {
        controller.safeAreaRegions.remove(.keyboard)
    }
}

@MainActor
private final class CommentReplySlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPush: Bool
    private let reducesMotion: Bool

    init(isPush: Bool, reducesMotion: Bool) {
        self.isPush = isPush
        self.reducesMotion = reducesMotion
        super.init()
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        reducesMotion ? 0.18 : 0.28
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        guard let fromVC = transitionContext.viewController(forKey: .from),
              let toVC = transitionContext.viewController(forKey: .to),
              let fromView = transitionContext.view(forKey: .from) ?? fromVC.view,
              let toView = transitionContext.view(forKey: .to) ?? toVC.view else {
            transitionContext.completeTransition(false)
            return
        }

        let container = transitionContext.containerView
        container.clipsToBounds = true
        container.backgroundColor = .clear

        let finalFrame = transitionContext.finalFrame(for: toVC)
        let targetFrame = finalFrame.isEmpty ? container.bounds : finalFrame
        toView.frame = targetFrame
        if toView.superview !== container {
            container.addSubview(toView)
        }

        let width = targetFrame.width > 0 ? targetFrame.width : container.bounds.width
        UIView.performWithoutAnimation {
            toView.layoutIfNeeded()
            fromView.transform = .identity
            fromView.alpha = 1
            if reducesMotion {
                toView.transform = .identity
            } else {
                toView.transform = CGAffineTransform(translationX: isPush ? width : -width, y: 0)
            }
            toView.alpha = 0
        }

        let duration = transitionDuration(using: transitionContext)
        let fromEndX = isPush ? -width : width
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            if !self.reducesMotion {
                fromView.transform = CGAffineTransform(translationX: fromEndX, y: 0)
            }
            fromView.alpha = 0
            toView.transform = .identity
            toView.alpha = 1
        } completion: { _ in
            let completed = !transitionContext.transitionWasCancelled
            fromView.transform = .identity
            fromView.alpha = 1
            toView.transform = .identity
            toView.alpha = 1
            if !completed {
                toView.removeFromSuperview()
            }
            transitionContext.completeTransition(completed)
        }
    }
}
