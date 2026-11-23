import UIKit

@MainActor
final class PlayerFullscreenDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    static let duration: TimeInterval = 0

    func transitionDuration(
        using _: (any UIViewControllerContextTransitioning)?
    ) -> TimeInterval {
        Self.duration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from),
              let toViewController = context.viewController(forKey: .to)
        else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }

        let completed = !context.transitionWasCancelled
        let originalBackgroundColor = fromView.backgroundColor

        UIView.performWithoutAnimation {
            if let toView = context.view(forKey: .to), toView.superview == nil {
                toView.frame = context.finalFrame(for: toViewController)
                container.insertSubview(toView, belowSubview: fromView)
                toView.layoutIfNeeded()
            }
            fromView.backgroundColor = .clear
            fromView.alpha = 0
            fromView.isHidden = true
            if completed {
                fromView.removeFromSuperview()
            }
        }

        fromView.isHidden = false
        fromView.alpha = 1
        fromView.backgroundColor = originalBackgroundColor
        context.completeTransition(completed)
    }
}
