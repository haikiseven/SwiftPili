import SwiftUI
import UIKit

enum PlayerPresentationCornerPolicy {
    static let pipRestoreRadius: CGFloat = 12

    static func cornerRadius(isPiPRestoringInline: Bool) -> CGFloat {
        isPiPRestoringInline ? pipRestoreRadius : 0
    }
}

/// Hosts the backend render view controller inside a zero-intrinsic-size `UIView`
/// with responder-chain child-VC containment so SwiftUI's aspect modifiers own sizing
/// while the inner video view still receives full UIKit lifecycle callbacks.
struct PlayerRenderView: UIViewRepresentable {
    let generation: Int
    let viewController: UIViewController?
    let surfaceLease: PlayerSurfaceLease
    let presentationCornerRadius: CGFloat

    func makeUIView(context _: Context) -> PlayerContainerView {
        SurfaceMoveProbe.noteMountStep("makeUIView")
        return PlayerContainerView()
    }

    func updateUIView(_ container: PlayerContainerView, context _: Context) {
        let player = PlayerViewModel.shared
        SurfaceMoveProbe.noteMountStep(
            "updateUIView",
            detail: "gen=\(generation) vc=\(viewController != nil ? 1 : 0)"
        )
        guard generation == player.playerGeneration else { return }
        if player.registerRenderAttachment(container, surfaceLease: surfaceLease) {
            container.update(
                hostedVC: player.backend.renderViewController,
                generation: player.playerGeneration,
                presentationCornerRadius: presentationCornerRadius
            )
        } else {
            container.update(
                hostedVC: nil,
                generation: -1,
                presentationCornerRadius: 0
            )
        }
        player.renderAttachmentDidChange(container)
    }

    static func dismantleUIView(_ container: PlayerContainerView, coordinator _: Void) {
        PlayerViewModel.shared.unregisterRenderAttachment(container)
        container.update(
            hostedVC: nil,
            generation: -1,
            presentationCornerRadius: 0
        )
    }
}

final class PlayerContainerView: UIView, PlayerRenderAttachment {
    private weak var hostedVC: UIViewController?
    private var attachedGeneration: Int?
    private var presentationCornerRadius: CGFloat = 0
    private var lastLoggedSurface: CGRect = .zero

    private var recoveryCoverView: UIImageView?
    private var recoveryCoverIdentity: UInt64?

    func installRecoveryCover(_ image: UIImage, identity: UInt64) -> PlayerRecoveryCoverMount {
        let snapshot = presentationSnapshot
        guard snapshot.isVisible, snapshot.boundsUsable,
              window?.isHidden == false,
              image.size.width > 1, image.size.height > 1 else { return .unavailable }
        if let current = recoveryCoverView, recoveryCoverIdentity == identity,
           current.image === image, current.superview === self,
           !current.isHidden, current.alpha > 0.001 {
            if current.frame != bounds { current.frame = bounds }
            if subviews.last !== current { bringSubviewToFront(current) }
            return .mounted
        }
        let cover = recoveryCoverView ?? UIImageView()
        cover.isHidden = false
        cover.alpha = 1
        cover.image = image
        cover.contentMode = .scaleAspectFit
        cover.backgroundColor = .black
        cover.isUserInteractionEnabled = false
        if cover.frame != bounds { cover.frame = bounds }
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        recoveryCoverView = cover
        recoveryCoverIdentity = identity
        if cover.superview !== self { addSubview(cover) }
        if subviews.last !== cover { bringSubviewToFront(cover) }
        return .mounted
    }

    func removeRecoveryCover(identity: UInt64) {
        guard recoveryCoverIdentity == identity else { return }
        recoveryCoverView?.removeFromSuperview()
        recoveryCoverView?.image = nil
        recoveryCoverView = nil
        recoveryCoverIdentity = nil
    }

    /// Logs inner hosted render-view geometry from `layoutSubviews` whenever its frame moves.
    private func logSurfaceIfMoved() {
        guard PlayerLog.isCapturing else { return }
        let surface = hostedVC?.view.frame ?? .zero
        let moved = abs(surface.minY - lastLoggedSurface.minY) > 0.5
            || abs(surface.height - lastLoggedSurface.height) > 0.5
            || abs(surface.width - lastLoggedSurface.width) > 0.5
        guard moved else { return }
        lastLoggedSurface = surface
        PlayerLog.log(
            "[PlayerChrome] surface container=\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded())) "
                + "hosted=\(Int(surface.width.rounded()))x\(Int(surface.height.rounded())) "
                + "at=\(Int(surface.minX.rounded())),\(Int(surface.minY.rounded()))"
        )
    }

    var presentationSnapshot: PlayerRenderAttachmentSnapshot {
        let hostedView = hostedVC?.view
        let isAttached = hostedView?.superview === self
        let containerBoundsUsable = bounds.width > 1 && bounds.height > 1
        let hostedBoundsUsable = (hostedView?.bounds.width ?? 0) > 1
            && (hostedView?.bounds.height ?? 0) > 1
        return PlayerRenderAttachmentSnapshot(
            renderGeneration: attachedGeneration,
            isAttached: isAttached,
            isVisible: isAttached
                && window != nil
                && hostedView?.window != nil
                && !isHidden
                && alpha > 0.001,
            boundsUsable: containerBoundsUsable && hostedBoundsUsable
        )
    }

    private func surfaceFacts(
        incoming next: UIViewController?
    ) -> InlineSurfaceBindingPolicy.InlineSurfaceFacts {
        let hosted = hostedVC
        return InlineSurfaceBindingPolicy.InlineSurfaceFacts(
            hasIncomingController: next != nil,
            hasHostedController: hosted != nil,
            controllerIdentityMatches: hosted === next,
            hostedViewIsAttached: hosted?.view.superview === self,
            hasLiveContainment: hosted?.parent != nil,
            containerIsInWindow: window != nil
        )
    }

    func attach(hostedVC: UIViewController?, generation: Int) {
        update(hostedVC: hostedVC, generation: generation)
    }

    func setPresentationCornerRadius(_ radius: CGFloat) {
        updatePresentationCornerRadius(
            radius,
            generation: attachedGeneration ?? -1
        )
    }

    @discardableResult
    func update(
        hostedVC next: UIViewController?,
        generation: Int,
        presentationCornerRadius: CGFloat? = nil
    ) -> Bool {
        if generation < 0, let recoveryCoverIdentity {
            removeRecoveryCover(identity: recoveryCoverIdentity)
        }
        if let presentationCornerRadius {
            updatePresentationCornerRadius(
                presentationCornerRadius,
                generation: generation
            )
        }
        let facts = surfaceFacts(incoming: next)
        let needsReattach = InlineSurfaceBindingPolicy.needsReattach(facts)
        FullscreenTransitionDiagnostics.recordRenderContainer(
            phase: "update",
            generation: generation,
            hasController: next != nil,
            reattaches: needsReattach
        )
        guard needsReattach else {
            // Record logical generation advances even when physical containment stays intact
            // so `presentationSnapshot` and presentation-proof fencing remain aligned.
            let previousGeneration = attachedGeneration
            attachedGeneration = generation
            guard previousGeneration != generation else { return false }
            PlayerLog.log(
                "[Surface] inline generation advanced " +
                    "\(previousGeneration.map { "\($0)" } ?? "-") → \(generation) " +
                    "surface=kept controller=\(facts.hasIncomingController ? "y" : "n") " +
                    "attached=\(facts.hostedViewIsAttached ? 1 : 0) " +
                    "containment=\(facts.hasLiveContainment ? 1 : 0) " +
                    "window=\(facts.containerIsInWindow ? 1 : 0)"
            )
            return false
        }
        if hostedVC != nil {
            FullscreenTransitionDiagnostics.recordRenderContainer(
                phase: "detach",
                generation: attachedGeneration ?? -1,
                hasController: true,
                reattaches: true
            )
            PlayerLog.log(
                "[Surface] inline detach generation=\(attachedGeneration ?? -1) " +
                    "attached=\(facts.hostedViewIsAttached ? 1 : 0) " +
                    "containment=\(facts.hasLiveContainment ? 1 : 0)"
            )
            if facts.hostedViewIsAttached {
                SurfaceMoveProbe.noteTeardown(generation: attachedGeneration ?? -1)
            }
        }
        removeCurrentChild()
        hostedVC = next
        attachedGeneration = generation
        embedIfNeeded()
        if next != nil {
            FullscreenTransitionDiagnostics.recordRenderContainer(
                phase: "attach",
                generation: generation,
                hasController: true,
                reattaches: true
            )
            PlayerLog.log(
                "[Surface] inline attached generation=\(generation) " +
                    "embedded=\(next?.view.superview === self ? 1 : 0) " +
                    "window=\(window != nil ? 1 : 0)"
            )
        }
        return true
    }

    private func updatePresentationCornerRadius(
        _ requestedRadius: CGFloat,
        generation: Int
    ) {
        let radius = max(0, requestedRadius)
        guard presentationCornerRadius != radius else { return }
        presentationCornerRadius = radius
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        clipsToBounds = radius > 0
        PlayerLog.log(
            "[Surface] PiP restore mask radius=\(Int(radius.rounded())) " +
                "clips=\(clipsToBounds ? 1 : 0) generation=\(generation) " +
                "bounds=\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded())) " +
                "window=\(window != nil ? 1 : 0) " +
                "hosted=\(hostedVC?.view.superview === self ? 1 : 0) " +
                "hostedBounds=\(Int((hostedVC?.view.bounds.width ?? 0).rounded()))x" +
                "\(Int((hostedVC?.view.bounds.height ?? 0).rounded()))"
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        SurfaceMoveProbe.noteMountStep(
            "container.didMoveToWindow",
            detail: "window=\(window != nil ? 1 : 0)"
        )
        embedIfNeeded()
        PlayerViewModel.shared.renderAttachmentDidChange(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        UIHitchMonitor.count("surface")
        PlayerViewModel.shared.noteInlineVideoRect(from: self)
        PlayerViewModel.shared.renderAttachmentDidChange(self)
        logSurfaceIfMoved()
    }

    private func embedIfNeeded() {
        guard let vc = hostedVC, window != nil else {
            SurfaceMoveProbe.noteMountStep(
                "embedIfNeeded.refused",
                detail: "vc=\(hostedVC != nil ? 1 : 0) window=\(window != nil ? 1 : 0)"
            )
            return
        }
        if vc.view.superview === self, vc.parent != nil { return }

        // If already a subview without child-VC containment, add only containment
        // without activating duplicate edge constraints.
        if vc.view.superview === self {
            if let parentVC = parentViewController {
                parentVC.addChild(vc)
                vc.didMove(toParent: parentVC)
            }
            return
        }

        if vc.parent != nil {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }

        SurfaceMoveProbe.noteEmbed(
            generation: attachedGeneration ?? -1,
            wasHosted: vc.view.superview != nil,
            inWindow: window != nil
        )
        if let parentVC = parentViewController {
            parentVC.addChild(vc)
            addSubview(vc.view)
            pinEdges(vc.view)
            vc.didMove(toParent: parentVC)
        } else {
            addSubview(vc.view)
            pinEdges(vc.view)
        }
        if let recoveryCoverView { bringSubviewToFront(recoveryCoverView) }
    }

    private func removeCurrentChild() {
        for sub in subviews {
            if sub === recoveryCoverView { continue }
            if let vc = sub.next as? UIViewController, vc.view === sub {
                vc.willMove(toParent: nil)
                sub.removeFromSuperview()
                vc.removeFromParent()
            } else {
                sub.removeFromSuperview()
            }
        }
    }

    private func pinEdges(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return nil
    }
}
