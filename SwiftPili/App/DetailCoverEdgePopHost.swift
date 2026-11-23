import SwiftUI
import UIKit

struct DetailCoverEdgePopHost: UIViewRepresentable {
    let isAtRoot: Bool
    var isBlocked: @MainActor () -> Bool = { false }
    let onPop: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtRoot: isAtRoot, isBlocked: isBlocked, onPop: onPop)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let coordinator = context.coordinator
        view.onAttachmentChange = { [weak coordinator] anchor in
            coordinator?.attachIfNeeded(from: anchor)
        }
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.isAtRoot = isAtRoot
        context.coordinator.isBlocked = isBlocked
        context.coordinator.onPop = onPop
        context.coordinator.attachIfNeeded(from: view)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.onAttachmentChange = nil
        coordinator.detach()
    }

    final class AnchorView: UIView {
        var onAttachmentChange: ((UIView) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onAttachmentChange?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAttachmentChange?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let popTranslationThreshold: CGFloat = 56
        private static let popVelocityThreshold: CGFloat = 420

        var isAtRoot: Bool {
            didSet { recognizer.isEnabled = isAtRoot }
        }
        var isBlocked: @MainActor () -> Bool
        var onPop: @MainActor () -> Void

        private let recognizer = UIScreenEdgePanGestureRecognizer()
        private weak var attachedView: UIView?
        private weak var coverController: UIViewController?
        private var isDragging = false
        private var isFinishingPop = false
        private var savedShadowOpacity: Float = 0
        private var savedShadowRadius: CGFloat = 0
        private var savedShadowOffset: CGSize = .zero

        init(
            isAtRoot: Bool,
            isBlocked: @escaping @MainActor () -> Bool,
            onPop: @escaping @MainActor () -> Void
        ) {
            self.isAtRoot = isAtRoot
            self.isBlocked = isBlocked
            self.onPop = onPop
            super.init()
            recognizer.edges = .left
            recognizer.isEnabled = isAtRoot
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handleEdgePan(_:)))
        }

        func attachIfNeeded(from anchor: UIView) {
            guard anchor.window != nil,
                  let controller = coverRootController(for: anchor),
                  let targetView = controller.view else {
                detach()
                return
            }
            let isRTL = targetView.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let leadingEdge: UIRectEdge = isRTL ? .right : .left
            if recognizer.edges != leadingEdge {
                recognizer.edges = leadingEdge
            }
            recognizer.isEnabled = isAtRoot
            if attachedView !== targetView {
                detach()
                targetView.addGestureRecognizer(recognizer)
                attachedView = targetView
                coverController = controller
            }
        }

        func detach() {
            if let view = attachedView {
                restoreVisualState(on: view)
                view.removeGestureRecognizer(recognizer)
            }
            attachedView = nil
            coverController = nil
            isDragging = false
            isFinishingPop = false
        }

        private func coverRootController(for anchor: UIView) -> UIViewController? {
            var responder: UIResponder? = anchor
            while let current = responder {
                if var controller = current as? UIViewController {
                    while let parent = controller.parent, controller.presentingViewController == nil {
                        controller = parent
                    }
                    return controller
                }
                responder = current.next
            }
            return nil
        }

        @objc private func handleEdgePan(_ sender: UIScreenEdgePanGestureRecognizer) {
            guard !isFinishingPop, let targetView = sender.view else { return }
            guard isAtRoot, !isBlocked() else {
                cancelDrag(on: targetView, animated: false)
                return
            }
            let isRTL = targetView.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let rawTranslation = sender.translation(in: targetView.superview ?? targetView).x
            let rawVelocity = sender.velocity(in: targetView.superview ?? targetView).x
            let translation = isRTL ? -rawTranslation : rawTranslation
            let velocity = isRTL ? -rawVelocity : rawVelocity

            switch sender.state {
            case .began:
                beginDrag(on: targetView)
            case .changed:
                guard isDragging else { return }
                let clamped = max(0, translation)
                let signedX = isRTL ? -clamped : clamped
                targetView.transform = CGAffineTransform(translationX: signedX, y: 0)
            case .ended:
                guard isDragging else { return }
                let width = max(targetView.bounds.width, 320)
                let shouldPop = translation > max(Self.popTranslationThreshold, width * 0.22)
                    || velocity > Self.popVelocityThreshold
                if shouldPop {
                    finishHorizontalPop(on: targetView, width: width, isRTL: isRTL)
                } else {
                    cancelDrag(on: targetView, animated: true)
                }
            case .cancelled, .failed:
                cancelDrag(on: targetView, animated: true)
            default:
                break
            }
        }

        private func beginDrag(on view: UIView) {
            isDragging = true
            savedShadowOpacity = view.layer.shadowOpacity
            savedShadowRadius = view.layer.shadowRadius
            savedShadowOffset = view.layer.shadowOffset
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.22
            view.layer.shadowRadius = 18
            view.layer.shadowOffset = CGSize(width: -4, height: 0)
        }

        private func finishHorizontalPop(on view: UIView, width: CGFloat, isRTL: Bool) {
            isDragging = false
            isFinishingPop = true
            let exitX = isRTL ? -width : width
            let complete: @MainActor () -> Void = { [weak self, weak view] in
                guard let self else { return }
                view?.isHidden = true
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.onPop()
                }
                self.isFinishingPop = false
            }
            if UIAccessibility.isReduceMotionEnabled {
                view.transform = CGAffineTransform(translationX: exitX, y: 0)
                complete()
                return
            }
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                view.transform = CGAffineTransform(translationX: exitX, y: 0)
            } completion: { _ in
                MainActor.assumeIsolated { complete() }
            }
        }

        private func cancelDrag(on view: UIView, animated: Bool) {
            guard isDragging || view.transform != .identity else { return }
            isDragging = false
            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                restoreVisualState(on: view)
                return
            }
            UIView.animate(
                springDuration: 0.28,
                bounce: 0.04,
                initialSpringVelocity: 0,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                view.transform = .identity
            } completion: { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, !self.isDragging, !self.isFinishingPop else { return }
                    self.restoreVisualState(on: view)
                }
            }
        }

        private func restoreVisualState(on view: UIView) {
            view.transform = .identity
            view.layer.shadowOpacity = savedShadowOpacity
            view.layer.shadowRadius = savedShadowRadius
            view.layer.shadowOffset = savedShadowOffset
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isAtRoot, !isFinishingPop, !isBlocked(),
                  coverController?.presentedViewController == nil,
                  let edgePan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer else {
                return false
            }
            let velocity = edgePan.velocity(in: edgePan.view)
            let isRTL = edgePan.view?.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let inwardVelocity = isRTL ? -velocity.x : velocity.x
            return inwardVelocity >= 0 && abs(velocity.x) >= abs(velocity.y) * 0.75
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard isAtRoot, !isBlocked(),
                  coverController?.presentedViewController == nil,
                  otherGestureRecognizer !== gestureRecognizer else {
                return false
            }
            return !(otherGestureRecognizer is UITapGestureRecognizer)
        }
    }
}
