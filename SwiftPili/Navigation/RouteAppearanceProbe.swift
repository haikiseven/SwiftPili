import SwiftUI
import UIKit

/// One detail page's activation state: the pure `RouteActivationGate` plus the
/// observation surface SwiftUI reads (design §8).
///
/// A reference type, and only the latch is observed. The probe's
/// `viewWillAppear`/`viewWillDisappear` can be delivered from INSIDE a SwiftUI
/// update — SwiftUI applies a path change by pushing/popping the
/// `UINavigationController`, and UIKit calls the "will" methods synchronously
/// from that — so they must not write anything a body reads. They only touch
/// the ignored gate; the one observed write, `isReleased`, happens on
/// `didAppear` (a transition completion) or from an `onChange` handler.
@MainActor
@Observable
final class RouteActivationState {
    @ObservationIgnored private var gate = RouteActivationGate()
    private(set) var isReleased = false

    /// Whether this page's route may run its activation right now. `isActive`
    /// is the live route gate; see `RouteActivationGate.admits`.
    func admits(routeIsActive isActive: Bool) -> Bool {
        isActive && (gate.requiresAppearance ? isReleased : true)
    }

    /// false under `ROUTE_ACTIVATION_AFTER_APPEAR=0`. The departure pause and
    /// the pre-claim outgoing exit exist only to serve the deferred activation,
    /// so the kill switch turns them off with it and the old path returns whole.
    var defersActivation: Bool { gate.requiresAppearance }

    @discardableResult
    func handle(_ event: RouteActivationGate.Event, owner: String) -> RouteActivationGate.Outcome {
        let now = ProcessInfo.processInfo.systemUptime
        let outcome = gate.handle(event, now: now)
        if isReleased != gate.isReleased { isReleased = gate.isReleased }
        if event == .didDisappear { AnimationFrameDiagnostics.settle(.routeExit) }
        switch outcome {
        case .gated:
            AnimationFrameDiagnostics.begin(.routeEnter)
            PlayerLog.log("[Route] activation gated owner=\(owner) (awaiting appear)")
        case .released(let waited):
            if let waited {
                AnimationFrameDiagnostics.settle(.routeEnter)
                PlayerLog.log(
                    "[Route] activation released owner=\(owner) waited=\(Int((waited * 1000).rounded()))ms"
                )
            } else if gate.requiresAppearance {
                PlayerLog.log("[Route] activation released owner=\(owner) waited=0ms (already shown)")
            }
        case .dropped:
            AnimationFrameDiagnostics.cancel(.routeEnter)
            PlayerLog.log("[Route] activation dropped (stale) owner=\(owner) — route left before appearing")
        case .staleAppearance:
            // Not a drop: a page can also appear a moment BEFORE its route
            // value reaches `onChange` (tab switch, un-animated swap), and the
            // gate then releases at that edge. Only `.dropped` ends anything.
            PlayerLog.log("[Route] appearance recorded while not the active route owner=\(owner)")
        case .deactivated:
            AnimationFrameDiagnostics.begin(.routeExit)
        case .unchanged:
            break
        }
        return outcome
    }
}

extension View {
    /// Mounts the page's UIKit appearance probe. Zero-sized, hit-test
    /// transparent and hidden from accessibility, like
    /// `keepsInteractivePopGesture()` — it is an observation point, never a
    /// participant in layout or touches.
    func routeAppearanceProbe(
        _ onEvent: @escaping @MainActor (RouteActivationGate.Event) -> Void
    ) -> some View {
        background(
            RouteAppearanceProbe(onEvent: onEvent)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

/// A zero-size child view controller whose only job is to forward its own
/// appearance cycle. As a child of the page's hosting controller it receives
/// the page's appearance transitions, which is the fact SwiftUI does not expose:
/// `viewDidAppear` "when any transition animations have completed", nothing for
/// a cancelled interactive pop. It does not look for, or drive, the navigation
/// controller — the system pop recognizer stays the only swipe-back authority.
private struct RouteAppearanceProbe: UIViewControllerRepresentable {
    let onEvent: @MainActor (RouteActivationGate.Event) -> Void

    func makeUIViewController(context _: Context) -> ProbeController {
        let controller = ProbeController()
        controller.onEvent = onEvent
        return controller
    }

    func updateUIViewController(_ controller: ProbeController, context _: Context) {
        controller.onEvent = onEvent
    }

    @MainActor
    final class ProbeController: UIViewController {
        var onEvent: (@MainActor (RouteActivationGate.Event) -> Void)?

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.view = view
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onEvent?(.willAppear)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onEvent?(.didAppear)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onEvent?(.willDisappear)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            onEvent?(.didDisappear)
        }
    }
}

/// What a player-hosting detail page shows in its player band while it does
/// not mount the shared `PlayerView`: a historical page under a successor, or
/// an active page whose activation is still waiting for its transition.
///
/// Its own route still first — the pixels this owner last displayed. Otherwise
/// its own cover, fitted like the video it stands for. Otherwise black, the
/// same ground `PlayerView` draws before a first frame, so the band never flips
/// between nothing and black at the moment of activation. Never the OUTGOING
/// owner's picture: nothing here reads the render surface, and one `PlayerView`
/// remains the only thing that can.
struct RouteActivationPlaceholderView: View {
    let still: UIImage?
    let coverURL: String?
    let height: CGFloat
    var cornerRadius: CGFloat = 0

    var body: some View {
        Group {
            if let still {
                OutgoingRouteStillView(image: still, height: height)
            } else {
                Color.black
                    .overlay {
                        if let coverURL, !coverURL.isEmpty {
                            CoverImage(
                                urlString: coverURL,
                                contentMode: .fit,
                                groundColor: .black,
                                isDecorative: true
                            )
                        }
                    }
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
