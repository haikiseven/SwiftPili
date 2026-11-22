import SwiftUI
import UIKit

@MainActor
final class PlayerFullscreenHostCoordinator: UIViewController, PlayerFullscreenPresentation {
    private var context: PlayerScreenPresentationContext
    private weak var navigation: AppCoordinator?
    private weak var liveRoom: LiveRoomViewModel?
    private var receipt: PlayerPresentationReceipt?
    private weak var host: PlayerFullscreenHostController?
    private var reservedHost: PlayerFullscreenHostController?
    private enum Phase { case inline, entering, fullscreen, leaving, retired }
    private var phase: Phase = .inline
    private var dismissalInFlight = false
    private var pendingMask: UIInterfaceOrientationMask?
    private var pendingMaskLabel: String?
    private var rotationInFlight = false

    init(
        context: PlayerScreenPresentationContext,
        navigation: AppCoordinator,
        liveRoom: LiveRoomViewModel?
    ) {
        self.context = context
        self.navigation = navigation
        self.liveRoom = liveRoom
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PlayerFullscreenHostCoordinator is created in code only")
    }

    func update(context: PlayerScreenPresentationContext) {
        if self.context != context {
            if let receipt {
                PlayerViewModel.shared.unregisterFullscreenPresentation(self, receipt: receipt)
            }
            self.context = context
            receipt = nil
            phase = .inline
        }
        registerIfCurrent()
    }

    private func registerIfCurrent() {
        guard routeIsActive, PlayerViewModel.shared.isCurrentPresentationContext(context) else { return }
        receipt = PlayerViewModel.shared.registerFullscreenPresentation(self, context: context)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        registerIfCurrent()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { registerIfCurrent() } else { tearDown() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        registerIfCurrent()
        reconcile()
    }

    var routeIsActive: Bool {
        navigation?.isActivePlayerRoute(context.route, position: context.position) == true
    }

    private var isCurrent: Bool {
        guard let receipt else { return false }
        return PlayerViewModel.shared.isCurrentPresentation(self, receipt: receipt)
    }

    func accepts(_ controller: PlayerFullscreenHostController) -> Bool {
        isCurrent && host === controller && controller.receipt == receipt
    }

    var coverage: PlayerPresentationCoverage {
        guard isCurrent, let controller = host else { return .none }
        return PlayerPresentationHostPresence.coverage(of: controller, entering: phase == .entering)
    }

    var hasPresentedHost: Bool { host != nil }

    private var modalPresentingAncestor: UIViewController? {
        guard viewIfLoaded?.window != nil else { return nil }
        var current: UIViewController = self
        while let parent = current.parent {
            current = parent
        }
        return current
    }

    func isCurrentHost(_ identity: UUID) -> Bool {
        isCurrent && host?.identity == identity
    }

    func reserveHost(receipt: PlayerPresentationReceipt) -> Bool {
        guard self.receipt == receipt, isCurrent, host == nil,
              !dismissalInFlight, presentedViewController == nil,
              let presenter = modalPresentingAncestor,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else { return false }
        let controller = PlayerFullscreenHostController(
            receipt: receipt, presenter: self, liveRoom: liveRoom
        )
        controller.transitioningDelegate = self
        reservedHost = controller
        host = controller
        phase = .entering
        return true
    }

    func cancelReservedHost(receipt: PlayerPresentationReceipt) {
        guard self.receipt == receipt, isCurrent, phase == .entering,
              host?.presentingViewController == nil else { return }
        host = nil
        reservedHost = nil
        phase = .inline
        pendingMask = nil
        pendingMaskLabel = nil
    }

    func reconcile() {
        guard isCurrent else { return }
        if PlayerViewModel.shared.isFullscreen {
            presentHostIfNeeded()
        } else {
            if host != nil { phase = .leaving }
            dismissHostWhenSceneSettled()
        }
    }

    func applyOrientation(mask: UIInterfaceOrientationMask, label: String) {
        guard isCurrent else { return }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            pendingMask = nil
            pendingMaskLabel = nil
            rotationInFlight = false
            return
        }
        pendingMask = mask
        pendingMaskLabel = label
        if phase == .fullscreen || phase == .leaving {
            commitPendingOrientation(reason: "hostPresented")
        } else if !PlayerViewModel.shared.isFullscreen {
            commitPendingOrientation(reason: "entryCancelled")
        }
    }

    func relinquishForOwnerReplacement() {
        phase = .retired
        pendingMask = nil
        pendingMaskLabel = nil
        rotationInFlight = false
        reservedHost = nil
        guard let controller = host else { return }
        if controller.presentingViewController == nil {
            host = nil
        } else {
            requestHostDismissal(controller, animated: false)
        }
    }

    private func presentHostIfNeeded() {
        guard phase == .entering, let controller = reservedHost,
              let receipt, accepts(controller) else { return }
        guard presentedViewController == nil,
              let presenter = modalPresentingAncestor,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
            cancelReservedHost(receipt: receipt)
            reconcile()
            return
        }
        logEvent("presentRequested", detail: "style:fullScreen")
        reservedHost = nil
        present(controller, animated: false) { [weak self, weak controller] in
            guard let self, let controller, self.accepts(controller) else { return }
            guard controller.presentingViewController != nil,
                  controller.viewIfLoaded?.window != nil else {
                PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
                self.hostDidDismiss(controller, source: "presentationRefused")
                return
            }
            self.phase = PlayerViewModel.shared.isFullscreen ? .fullscreen : .leaving
            self.logEvent("hostPresented")
            self.commitPendingOrientation(reason: "presented")
            self.reconcile()
        }
        if controller.presentingViewController == nil, accepts(controller) {
            PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
            hostDidDismiss(controller, source: "presentationRefused")
        }
    }

    private func dismissHostWhenSceneSettled() {
        guard let controller = host, pendingMask == nil, !rotationInFlight else { return }
        if controller.presentingViewController == nil {
            hostDidDismiss(controller, source: "unsubmitted")
            return
        }
        requestHostDismissal(controller, animated: true)
    }

    private func requestHostDismissal(_ controller: PlayerFullscreenHostController, animated: Bool) {
        guard host === controller, !dismissalInFlight else { return }
        dismissalInFlight = true
        controller.dismiss(animated: animated) { [weak self] in
            self?.hostDidDismiss(controller, source: "completion")
        }
    }

    func hostDidDismiss(_ controller: PlayerFullscreenHostController, source: String) {
        guard host === controller else { return }
        let current = accepts(controller)
        if current, let receipt {
            PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
        }
        host = nil
        reservedHost = nil
        dismissalInFlight = false
        rotationInFlight = false
        if current {
            phase = .inline
            pendingMask = nil
            pendingMaskLabel = nil
            FullscreenLoginHandoff.shared.release()
        }
        logEvent("hostDismissed", detail: source)
    }

    func hostDidDisappear(_ controller: PlayerFullscreenHostController) {
        hostDidDismiss(controller, source: "viewDidDisappear")
    }

    func hostRotationDidBegin(_ controller: PlayerFullscreenHostController) {
        guard accepts(controller), !PlayerViewModel.shared.isFullscreen else { return }
        rotationInFlight = false
        dismissHostWhenSceneSettled()
    }

    func hostDidCompleteRotation(_ controller: PlayerFullscreenHostController) {
        guard accepts(controller) else { return }
        rotationInFlight = false
        reconcile()
    }

    func hostWillDisappear(_ controller: PlayerFullscreenHostController) {
        guard accepts(controller), let receipt,
              controller.isBeingDismissed || controller.presentingViewController == nil else { return }
        PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
    }

    private func sceneWillRotate(to mask: UIInterfaceOrientationMask) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let window = host?.viewIfLoaded?.window ?? AppWindowMetrics.current
        guard let scene = window?.windowScene else { return false }
        let current = PlayerPresentationCensus.mask(for: scene.interfaceOrientation)
        return !current.isEmpty && !mask.contains(current)
    }

    private func commitPendingOrientation(reason: String) {
        guard isCurrent, let mask = pendingMask, let receipt else { return }
        let label = pendingMaskLabel ?? PlayerPresentationCensus.maskLabel(mask)
        pendingMask = nil
        pendingMaskLabel = nil
        rotationInFlight = sceneWillRotate(to: mask)
        AppOrientation.shared.set(mask)
        host?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let window = host?.viewIfLoaded?.window ?? AppWindowMetrics.current
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        FullscreenTransitionDiagnostics.recordSceneGeometryRequest(mask: label, windowResolved: window != nil)
        logEvent("sceneRotationRequested", detail: "mask:\(label),why:\(reason)")
        let rotatingHost = host
        window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: mask)
        ) { [weak self, weak rotatingHost] error in
            guard let self, self.receipt == receipt, self.isCurrent,
                  let rotatingHost, self.accepts(rotatingHost) else { return }
            PlayerLog.log("[Fullscreen] scene rotation rejected mask=\(label) error=\(error.localizedDescription)")
            self.rotationInFlight = false
            self.reconcile()
        }
    }

    func tearDown() {
        if let receipt {
            PlayerViewModel.shared.unregisterFullscreenPresentation(self, receipt: receipt)
        }
        relinquishForOwnerReplacement()
    }

    // MARK: - Reporting
    private func logEvent(_ event: String, detail: String? = nil) {
        SurfaceMoveProbe.noteHostMilestone(event)
        guard PlayerLog.isCapturing else { return }
        let window = AppWindowMetrics.current
        var line = "[Fullscreen] host event=\(event)"
        if let window {
            let census = PlayerPresentationCensus.census(of: window.layer)
            line += " winLayers=\(census.count) winDepth=\(census.depth)"
        } else {
            line += " winLayers=n/a winDepth=n/a"
        }
        if let hostView = host?.viewIfLoaded {
            let census = PlayerPresentationCensus.census(of: hostView.layer)
            line += " hostLayers=\(census.count) hostDepth=\(census.depth)"
            line += " hostOnWindow=\(hostView.window != nil ? "y" : "n")"
        } else {
            line += " hostLayers=n/a hostDepth=n/a hostOnWindow=n/a"
        }
        line += " presenterOffWindow=\(viewIfLoaded?.window == nil ? "y" : "n")"
        line += " mask=\(PlayerPresentationCensus.maskLabel(AppOrientation.shared.mask))"
        let scene = (host?.viewIfLoaded?.window ?? window)?.windowScene
        line += " orient=\(scene.map { PlayerPresentationCensus.orientationLabel($0.interfaceOrientation) } ?? "n/a")"
        let player = PlayerViewModel.shared
        line += " vmFS=\(player.isFullscreen ? "y" : "n")"
        line += " play=\(player.isPlaying ? "y" : "n")"
        line += " mt=\(String(format: "%.2f", player.mediaTime))"
        line += " detail=\(detail ?? "-")"
        PlayerLog.log(line)
    }
}

// MARK: - Transition

extension PlayerFullscreenHostCoordinator: UIViewControllerTransitioningDelegate {
    func animationController(
        forDismissed _: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        PlayerFullscreenDismissAnimator()
    }
}

// MARK: - Mount

struct PlayerFullscreenHostMount: UIViewControllerRepresentable {
    let presentationContext: PlayerScreenPresentationContext
    let navigation: AppCoordinator
    let liveRoom: LiveRoomViewModel?
    let isFullscreen: Bool

    func makeUIViewController(context _: Context) -> PlayerFullscreenHostCoordinator {
        PlayerFullscreenHostCoordinator(
            context: presentationContext, navigation: navigation, liveRoom: liveRoom
        )
    }

    func updateUIViewController(_ coordinator: PlayerFullscreenHostCoordinator, context _: Context) {
        coordinator.update(context: presentationContext)
        coordinator.reconcile()
    }

    static func dismantleUIViewController(_ controller: PlayerFullscreenHostCoordinator, coordinator _: Void) {
        controller.tearDown()
    }
}

struct PlayerFullscreenHost: View {
    let context: PlayerScreenPresentationContext
    let navigation: AppCoordinator
    var liveRoom: LiveRoomViewModel?

    var body: some View {
        PlayerFullscreenHostMount(
            presentationContext: context, navigation: navigation,
            liveRoom: liveRoom, isFullscreen: PlayerViewModel.shared.isFullscreen
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}
