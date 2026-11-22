import Observation
import SwiftUI
import UIKit

@MainActor
protocol CommentZoomDismissalHost: AnyObject {
    func dismissThenPerform(_ action: @escaping @MainActor () -> Void)
    func cancelPendingAction()
}

/// Presentation intent survives fullscreen and adaptive-layout removal.
@MainActor
@Observable
final class CommentZoomPresentation {
    var isPresented = false
    @ObservationIgnored let anchors = CommentZoomAnchors()
    @ObservationIgnored private weak var dismissalHost: (any CommentZoomDismissalHost)?

    /// The existing native host owns completion; wide layouts have no modal.
    func dismissThenPerform(_ action: @escaping @MainActor () -> Void) {
        isPresented = false
        if let dismissalHost {
            dismissalHost.dismissThenPerform(action)
        } else {
            action()
        }
    }

    func cancelPendingAction() { dismissalHost?.cancelPendingAction() }

    func attach(_ host: any CommentZoomDismissalHost) {
        dismissalHost = host
    }

    func detach(_ host: any CommentZoomDismissalHost) {
        if dismissalHost === host { dismissalHost = nil }
    }
}

/// UIKit references are decoration/gesture geometry, never observable page state.
@MainActor
final class CommentZoomAnchors {
    weak var source: UIView?
    weak var header: UIView?
    weak var closeControl: UIView?
    weak var backControl: UIView?
    weak var sortControl: UIView?
    var sourceProvider: (@MainActor () -> UIView?)?
    var crossDissolvesWithoutSource = false

    var transitionSource: UIView? {
        if let sourceProvider { return sourceProvider() }
        return source
    }

    func isDismissalOrigin(globalPoint: CGPoint) -> Bool {
        guard let header, let window = header.window else { return false }
        return isDismissalOrigin(globalPoint, in: window)
    }

    func isDismissalOrigin(_ point: CGPoint, in view: UIView) -> Bool {
        guard let header, header.window === view.window,
              header.convert(header.bounds, to: view).contains(point) else { return false }
        if let closeControl, closeControl.window === view.window,
           closeControl.convert(closeControl.bounds, to: view).contains(point) { return false }
        if let backControl, backControl.window === view.window,
           backControl.convert(backControl.bounds, to: view).contains(point) { return false }
        if let sortControl, sortControl.window === view.window,
           sortControl.convert(sortControl.bounds, to: view).contains(point) { return false }
        return true
    }
}

/// Passthrough wrapper retained for caller compatibility. The compact comment
/// surface now presents as a smooth bottom slide-up drawer rather than a
/// cross-sibling UIKit zoom portal, so the source preview card never needs a
/// nested `UIHostingController` or snapshot reparenting.
struct CommentZoomSource<Content: View>: View {
    let anchors: CommentZoomAnchors
    let content: Content

    init(anchors: CommentZoomAnchors, @ViewBuilder content: () -> Content) {
        self.anchors = anchors
        self.content = content()
    }

    var body: some View {
        content
    }
}

/// Marks only the measured header or excluded controls. Sort/close/back controls
/// are excluded from drag dismissal admission inside the header.
struct CommentZoomRegion: UIViewRepresentable {
    enum Role { case header, closeControl, backControl, sortControl }
    let anchors: CommentZoomAnchors
    let role: Role

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        register(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { register(view) }

    private func register(_ view: UIView) {
        switch role {
        case .header: anchors.header = view
        case .closeControl: anchors.closeControl = view
        case .backControl: anchors.backControl = view
        case .sortControl: anchors.sortControl = view
        }
    }
}

/// Presents the compact comment sheet as a bottom slide-up drawer. Open, close
/// and drag are driven by `CALayer` transforms on a retained UIKit host so no
/// SwiftUI invalidation happens while the drawer moves.
struct CommentZoomContainer<Destination: View>: View {
    @AppMotion private var motion
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    let presentation: CommentZoomPresentation
    let destination: Destination
    let onPresentationChanged: (Bool) -> Void
    var allowsInteractiveDismissal = true
    var onDismissed: () -> Void = {}

    var body: some View {
        CommentDrawerPresenter(
            presentation: presentation,
            isPresented: presentation.isPresented,
            rootView: CommentDrawerRoot(environment: environment, destination: destination),
            allowsInteractiveDismissal: allowsInteractiveDismissal,
            reducesMotion: motion.reducesGeometry,
            interfaceStyle: colorScheme == .dark ? .dark : .light,
            onPresentationChanged: onPresentationChanged,
            onDismissed: onDismissed
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Re-injects the caller's environment, which does not cross the UIKit hosting
/// boundary on its own, and applies the drawer's notice overlay.
struct CommentDrawerRoot<Destination: View>: View {
    let environment: EnvironmentValues
    let destination: Destination

    var body: some View {
        destination
            .appNoticeOverlay(bottomPadding: 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.self, environment)
    }
}

/// Captures the starting region, then immediately releases gesture recognition.
/// UIKit alone drives Zoom. Weak event/touch references identify the live sequence
/// without retaining UIKit events or confusing an initial count with live touches.
@MainActor
final class CommentZoomTouchOrigin: UIGestureRecognizer {
    private weak var anchors: CommentZoomAnchors?
    private weak var initialEvent: UIEvent?
    private weak var initialTouch: UITouch?
    private var beganInHeader = false

    var permitsDismissal: Bool {
        guard beganInHeader, let initialEvent, let initialTouch, let view,
              initialTouch.window === view.window,
              let touches = initialEvent.allTouches else { return false }
        let active = touches.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }
        return active.count == 1 && active.first === initialTouch
    }

    init(anchors: CommentZoomAnchors) {
        self.anchors = anchors
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        initialEvent = event
        initialTouch = touches.first
        beganInHeader = if let touch = touches.first, let view, touches.count == 1 {
            anchors?.isDismissalOrigin(touch.location(in: view), in: view) == true
        } else { false }
        // Keep the snapshot through UIKit's reset until the next touch begins.
        // The weak live touch rejects an ended/cancelled or replaced sequence.
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Repeated comments use a native elevated content surface so comment text,
/// avatars, and inline images maintain full contrast without decorative blur.
struct CommentZoomContentSurface: View {
    var body: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
    }
}
