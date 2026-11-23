import SwiftUI
import UIKit

struct CommentDrawerPresenter<Destination: View>: UIViewControllerRepresentable {
    let presentation: CommentZoomPresentation
    let isPresented: Bool
    let rootView: CommentDrawerRoot<Destination>
    let allowsInteractiveDismissal: Bool
    let reducesMotion: Bool
    let interfaceStyle: UIUserInterfaceStyle
    let onPresentationChanged: (Bool) -> Void
    let onDismissed: () -> Void

    func makeUIViewController(context: Context) -> CommentDrawerViewController<Destination> {
        CommentDrawerViewController<Destination>()
    }

    func updateUIViewController(_ controller: CommentDrawerViewController<Destination>, context: Context) {
        controller.update(self)
    }

    static func dismantleUIViewController(
        _ controller: CommentDrawerViewController<Destination>,
        coordinator: ()
    ) {
        controller.teardown()
    }
}

final class CommentDrawerPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

@MainActor
final class CommentDrawerViewController<Destination: View>: UIViewController,
    UIGestureRecognizerDelegate, CommentZoomDismissalHost {
    private static var detachedTopCornerRadius: CGFloat { 20 }
    private static var maxScrimAlpha: CGFloat { 0.28 }

    private var props: CommentDrawerPresenter<Destination>?
    private var host: UIHostingController<CommentDrawerRoot<Destination>>?
    private let scrimView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.alpha = 0
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    private weak var attachedPresentation: CommentZoomPresentation?
    private var pendingRoot: CommentDrawerRoot<Destination>?
    private var pendingAction: (@MainActor () -> Void)?
    private var lastPresented: Bool?
    private var isShown = false
    private var isAnimating = false
    private var isDragging = false
    private var transitionToken: UInt64 = 0

    private var isBusy: Bool { isAnimating || isDragging }
    private var hiddenOffset: CGFloat { max(view.bounds.height, 480) }
    private var isMounted: Bool { host.map { !$0.view.isHidden } ?? false }

    override func loadView() {
        view = CommentDrawerPassthroughView()
        view.backgroundColor = .clear
        view.addSubview(scrimView)
        NSLayoutConstraint.activate([
            scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrimView.topAnchor.constraint(equalTo: view.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let host, !isShown, !isAnimating, props?.reducesMotion == false else { return }
        host.view.transform = CGAffineTransform(translationX: 0, y: hiddenOffset)
    }

    func update(_ new: CommentDrawerPresenter<Destination>) {
        props = new
        if attachedPresentation !== new.presentation {
            attachedPresentation?.detach(self)
            attachedPresentation = new.presentation
            new.presentation.attach(self)
        }
        host?.view.overrideUserInterfaceStyle = new.interfaceStyle
        pendingRoot = new.rootView
        let previous = lastPresented
        lastPresented = new.isPresented
        if previous == nil {
            if new.isPresented { present() }
            return
        }
        if previous != new.isPresented {
            new.onPresentationChanged(new.isPresented)
            if new.isPresented {
                cancelPendingAction()
                present()
            } else {
                dismiss()
            }
        } else if isShown {
            flushRoot()
        }
    }

    func teardown() {
        transitionToken &+= 1
        cancelPendingAction()
        attachedPresentation?.detach(self)
        attachedPresentation = nil
    }

    // MARK: CommentZoomDismissalHost

    func dismissThenPerform(_ action: @escaping @MainActor () -> Void) {
        if isMounted {
            pendingAction = action
        } else {
            pendingAction = nil
            action()
        }
    }

    func cancelPendingAction() { pendingAction = nil }

    // MARK: Content

    private func flushRoot() {
        guard !isBusy, let host, let root = pendingRoot else { return }
        pendingRoot = nil
        host.rootView = root
    }

    private func mountHostIfNeeded(_ props: CommentDrawerPresenter<Destination>) -> Bool {
        guard host == nil, let root = pendingRoot else { return false }
        pendingRoot = nil
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        controller.view.overrideUserInterfaceStyle = props.interfaceStyle
        controller.view.layer.cornerRadius = 0
        controller.view.layer.cornerCurve = .continuous
        controller.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        controller.view.layer.masksToBounds = true
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        controller.view.addGestureRecognizer(pan)
        host = controller
        return true
    }

    // MARK: Presentation

    private func present() {
        guard let props else { return }
        transitionToken &+= 1
        let token = transitionToken
        let reduces = props.reducesMotion
        let mountedNow = mountHostIfNeeded(props)
        guard let host else { return }
        if !mountedNow { flushRoot() }
        isDragging = false
        scrimView.isHidden = false
        host.view.isHidden = false
        host.view.isUserInteractionEnabled = true
        if mountedNow || !isShown {
            host.view.transform = reduces ? .identity : CGAffineTransform(translationX: 0, y: hiddenOffset)
            host.view.alpha = reduces ? 0 : 1
            host.view.layer.cornerRadius = reduces ? 0 : Self.detachedTopCornerRadius
            scrimView.alpha = 0
        }
        isShown = true
        isAnimating = true
        let start: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, transitionToken == token, lastPresented == true else { return }
            animate(
                reduces: reduces,
                transform: .identity,
                alpha: 1,
                cornerRadius: 0,
                scrimAlpha: Self.maxScrimAlpha,
                token: token
            ) { [weak self] in
                self?.finishSettling()
            }
        }
        if mountedNow {
            view.layoutIfNeeded()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async { MainActor.assumeIsolated { start() } }
        } else {
            start()
        }
    }

    private func dismiss() {
        transitionToken &+= 1
        let token = transitionToken
        isDragging = false
        guard let host, isMounted, let props else {
            isShown = false
            isAnimating = false
            scrimView.alpha = 0
            scrimView.isHidden = true
            consumePendingAction()?()
            return
        }
        isShown = false
        isAnimating = true
        host.view.isUserInteractionEnabled = false
        animate(
            reduces: props.reducesMotion,
            transform: CGAffineTransform(translationX: 0, y: hiddenOffset),
            alpha: 0,
            cornerRadius: props.reducesMotion ? 0 : Self.detachedTopCornerRadius,
            scrimAlpha: 0,
            token: token
        ) { [weak self] in
            guard let self, let host = self.host, lastPresented == false else { return }
            isAnimating = false
            scrimView.alpha = 0
            scrimView.isHidden = true
            host.view.isHidden = true
            host.view.alpha = 1
            host.view.layer.cornerRadius = 0
            host.view.transform = CGAffineTransform(translationX: 0, y: hiddenOffset)
            props.onDismissed()
            consumePendingAction()?()
        }
    }

    private func animate(
        reduces: Bool,
        transform: CGAffineTransform,
        alpha: CGFloat,
        cornerRadius: CGFloat,
        scrimAlpha: CGFloat,
        token: UInt64,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let host else { return }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        let animations = {
            if reduces {
                host.view.alpha = alpha
            } else {
                host.view.transform = transform
                host.view.layer.cornerRadius = cornerRadius
            }
            self.scrimView.alpha = scrimAlpha
        }
        let done: (Bool) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transitionToken == token else { return }
                completion()
            }
        }
        if reduces {
            UIView.animate(withDuration: 0.18, delay: 0, options: options.union(.curveEaseInOut),
                           animations: animations, completion: done)
        } else {
            UIView.animate(springDuration: 0.34, bounce: 0.05, initialSpringVelocity: 0,
                           delay: 0, options: options, animations: animations, completion: done)
        }
    }

    private func finishSettling() {
        isAnimating = false
        if isShown { flushRoot() }
    }

    private func consumePendingAction() -> (@MainActor () -> Void)? {
        defer { pendingAction = nil }
        return pendingAction
    }

    // MARK: Interactive dismissal

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let props, let window = view.window else { return true }
        let velocity = pan.velocity(in: view)
        return props.allowsInteractiveDismissal
            && !props.reducesMotion
            && isShown
            && velocity.y > abs(velocity.x)
            && props.presentation.anchors.isDismissalOrigin(pan.location(in: window), in: window)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let host, let props else { return }
        switch pan.state {
        case .began:
            transitionToken &+= 1
            isAnimating = false
            isDragging = true
            host.view.layer.removeAllAnimations()
            scrimView.layer.removeAllAnimations()
        case .changed:
            guard isDragging else { return }
            let dragY = max(0, pan.translation(in: view).y)
            host.view.transform = CGAffineTransform(translationX: 0, y: dragY)
            let detachProgress = min(1, dragY / 36)
            host.view.layer.cornerRadius = Self.detachedTopCornerRadius * detachProgress
            let dismissProgress = min(1, dragY / max(hiddenOffset * 0.6, 220))
            scrimView.alpha = Self.maxScrimAlpha * (1 - dismissProgress)
        case .ended, .cancelled, .failed:
            guard isDragging else { return }
            let dragY = max(0, pan.translation(in: view).y)
            let shouldDismiss = pan.state == .ended && (dragY > 90 || pan.velocity(in: view).y > 700)
            isDragging = false
            if shouldDismiss {
                props.presentation.isPresented = false
            } else {
                transitionToken &+= 1
                let token = transitionToken
                isAnimating = true
                animate(
                    reduces: false,
                    transform: .identity,
                    alpha: 1,
                    cornerRadius: 0,
                    scrimAlpha: Self.maxScrimAlpha,
                    token: token
                ) { [weak self] in
                    self?.finishSettling()
                }
            }
        default:
            break
        }
    }
}
