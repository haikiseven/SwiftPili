import UIKit

/// Hands the live render surface back to the returning detail page on fullscreen
/// exit without fading an opaque black host over it.
///
/// **It must not scale or cross-fade a solid-black backdrop.** Scaling the host
/// was tried and reverted (device verdict "错误位置+中途露出黑边"). Fading the
/// opaque black host (`alpha 1 -> 0`) after `toView.layoutIfNeeded()` had already
/// claimed the render surface left an empty solid-black curtain fading over the
/// returning detail page during rotation (translucent black dimming flash).
///
/// **Ordering inside the transition is load-bearing.** `toView` is inserted below
/// `fromView` and laid out BEFORE `fromView` is hidden/removed; that layout is
/// what lets the returning inline container claim the render surface atomically
/// via its own `addSubview`, preventing a black-frame gap. Once `toView` owns
/// the surface, `fromView` is cleared and removed synchronously so no black
/// curtain sits above `toView` during rotation.
///
/// ⚠️ Only an `animationController` is vended, never a `presentationController`.
/// Spec §6 forbids the latter because it takes back
/// `shouldRemovePresentersView == YES`. Measured with an animated dismissal in
/// place: `winLayers` at `sceneRotationRequested` stayed at 48, against a
/// 313–344 baseline, so the animation controller does not disturb it.
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
            if let toView = context.view(forKey: .to) {
                toView.frame = context.finalFrame(for: toViewController)
                container.insertSubview(toView, belowSubview: fromView)
                // Before hiding `fromView` — see the ordering note above.
                toView.layoutIfNeeded()
            }
            fromView.backgroundColor = .clear
            fromView.alpha = 0
            fromView.isHidden = true
            if completed {
                fromView.removeFromSuperview()
            }
        }

        // Restore host appearance after removal so any reused host starts clean.
        fromView.isHidden = false
        fromView.alpha = 1
        fromView.backgroundColor = originalBackgroundColor
        context.completeTransition(completed)
    }
}
