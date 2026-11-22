import SwiftUI
import UIKit

@MainActor
@Observable
final class RouteActivationState {
    @ObservationIgnored private var gate = RouteActivationGate()
    private(set) var isReleased = false

    func admits(routeIsActive isActive: Bool) -> Bool {
        isActive && (gate.requiresAppearance ? isReleased : true)
    }

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
