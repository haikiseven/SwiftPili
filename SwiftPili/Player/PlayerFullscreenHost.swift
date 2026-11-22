import SwiftUI
import UIKit

/// Converts the presented host's measured bounds into the aspect used by the
/// fullscreen PlayerView. The physical screen is not the app window on iPad
/// Split View or Stage Manager, and can also be portrait while the host is
/// visible; the container is the only authoritative geometry.
enum PlayerFullscreenViewportPolicy {
    static let fallbackAspect: CGFloat = 16.0 / 9.0

    static func aspect(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1
        else { return fallbackAspect }
        return size.width / size.height
    }
}

@MainActor
protocol PlayerFullscreenPresentation: AnyObject {
    var routeIsActive: Bool { get }
    var coverage: PlayerPresentationCoverage { get }
    var hasPresentedHost: Bool { get }
    func isCurrentHost(_ identity: UUID) -> Bool
    func reserveHost(receipt: PlayerPresentationReceipt) -> Bool
    func cancelReservedHost(receipt: PlayerPresentationReceipt)
    func reconcile()
    func applyOrientation(mask: UIInterfaceOrientationMask, label: String)
    func relinquishForOwnerReplacement()
}

/// The host reads the actual room model while its parent is off-window.
/// Retaining this port does not retain a popped room or freeze a menu snapshot.
@MainActor
final class PlayerFullscreenLiveControls {
    private weak var room: LiveRoomViewModel?
    private let receipt: PlayerPresentationReceipt
    private let hostIdentity: UUID
    private var context: PlayerScreenPresentationContext { receipt.context }

    init(room: LiveRoomViewModel?, receipt: PlayerPresentationReceipt, hostIdentity: UUID) {
        self.room = room
        self.receipt = receipt
        self.hostIdentity = hostIdentity
    }

    var qualityControl: LiveQualityControl? {
        guard case .live(let roomID) = context.source,
              let room, room.playerOwnerLease == context.ownerLease,
              PlayerViewModel.shared.isCurrentPresentationReceipt(receipt, hostIdentity: hostIdentity),
              room.streamUnavailable == nil, !room.availableQualities.isEmpty else { return nil }
        return LiveQualityControl(
            options: room.availableQualities.map { .init(qn: $0.qn, label: $0.label) },
            current: room.currentQuality,
            select: { [weak self, weak room] quality in
                guard let self, let room, room.playerOwnerLease == self.context.ownerLease,
                      PlayerViewModel.shared.isCurrentPresentationReceipt(
                        self.receipt, hostIdentity: self.hostIdentity
                      ), room.streamUnavailable == nil,
                      room.availableQualities.contains(where: { $0.qn == quality }) else { return }
                Task { @MainActor [weak self, weak room] in
                    // Queueing must not outlive this host's original receipt or room lease.
                    guard let self, let room, room.playerOwnerLease == self.context.ownerLease,
                          PlayerViewModel.shared.isCurrentPresentationReceipt(
                            self.receipt, hostIdentity: self.hostIdentity
                          ), room.streamUnavailable == nil,
                          room.availableQualities.contains(where: { $0.qn == quality }) else { return }
                    await room.switchQuality(roomID: roomID, quality: quality)
                }
            }
        )
    }
}

// MARK: - The presented host

/// The fullscreen surface: a UIKit `.fullScreen` presentation carrying one
/// `PlayerView`.
///
/// Uses UIKit `.fullScreen` so the presenting detail tree leaves the window
/// before scene rotation. `.overFullScreen`/SwiftUI covers retain that tree and
/// defeat this ordering. Stage 0 evidence is recorded in the fullscreen spec
/// and research/evidence/capture-zero-round-two-uikit-fullscreen-2026-09-05.txt.
/// Orientation remains AppOrientation's authority on phone; iPad keeps all masks.
@MainActor
final class PlayerFullscreenHostController: UIViewController, PlayerPresentationHost {
    /// Weak: the coordinator owns this controller's lifetime through UIKit's
    /// presentation, and a host must never keep a popped screen's coordinator
    /// alive.
    private weak var presenter: PlayerFullscreenHostCoordinator?
    private weak var lastPresentingController: UIViewController?
    let receipt: PlayerPresentationReceipt
    let identity: UUID
    private let content: UIHostingController<PlayerFullscreenHostContent>
    private let geometry: PlayerFullscreenHostGeometry

    init(
        receipt: PlayerPresentationReceipt,
        presenter: PlayerFullscreenHostCoordinator,
        liveRoom: LiveRoomViewModel?
    ) {
        self.receipt = receipt
        let identity = UUID()
        self.identity = identity
        self.presenter = presenter
        let geometry = PlayerFullscreenHostGeometry()
        self.geometry = geometry
        content = UIHostingController(
            rootView: PlayerFullscreenHostContent(
                receipt: receipt,
                hostIdentity: identity,
                geometry: geometry,
                liveControls: PlayerFullscreenLiveControls(
                    room: liveRoom, receipt: receipt, hostIdentity: identity
                ),
                // The on-window observer. The coordinator's own SwiftUI mount
                // sits inside the presenter's view, which this presentation
                // takes OUT of the window — so an update SwiftUI defers for an
                // off-window hosting controller would defer the dismissal with
                // it. This content is in the window for the whole presentation
                // by construction, which is what makes it a sound observer of
                // the state that ends the presentation.
                reconcile: { [weak presenter] in presenter?.reconcile() }
            )
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PlayerFullscreenHostController is created in code only")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        geometry.update(from: view)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        geometry.update(from: view)
    }

    /// One authority, forwarded — see the type comment. iPad matches
    /// `AppDelegate`'s rule so multitasking is never gated by a mask meant for
    /// the phone.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : AppOrientation.shared.mask
    }

    /// Chrome the presenter used to own. `.statusBarHidden(player.isFullscreen)`
    /// and `.navigationBarHidden(player.isFullscreen)` are modifiers on the
    /// OWNING screen, and once its view leaves the window they describe
    /// something the user is not looking at.
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Opaque black only while fullscreen is active: the presenter's view is
        // off-window, so nothing is behind this to show through. Dismissal clears
        // the backdrop once the returning page claims the render surface.
        view.backgroundColor = PlayerViewModel.shared.isFullscreen ? .black : .clear
        addChild(content)
        content.view.backgroundColor = .clear
        content.view.translatesAutoresizingMaskIntoConstraints = false
        // The send bar positions itself from the keyboard frame. Leaving the
        // keyboard in the hosting controller's safe-area regions would shrink
        // the root, and the video with it, the moment the field took focus.
        content.safeAreaRegions.remove(.keyboard)
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        content.didMove(toParent: self)
        geometry.update(from: view)
        // **This line is the black-frame fix.** Load-bearing, not a tidy-up.
        //
        // Without it the video region is black for 158–826 ms on entering
        // fullscreen, and the device stamps name the step exactly:
        //
        //     step=container.didMoveToWindow  intoGap=0.0ms   sincePrev=0.0ms
        //     step=embedIfNeeded.refused      intoGap=0.1ms   sincePrev=0.0ms
        //     ... nothing at all ...
        //     step=updateUIView               intoGap=659.9ms sincePrev=659.8ms
        //
        // The host's `PlayerContainerView` reaches the window immediately, but
        // `embedIfNeeded` refuses because `hostedVC` is still nil — the only
        // thing that assigns it is `update(hostedVC:)`, called from
        // `updateUIView`. SwiftUI then does not run that update pass for
        // 158–826 ms, and across the whole of it NEITHER the inline view nor
        // the host holds the render surface, so nothing draws. `sincePrev`
        // equals `intoGap` on that line: the step is LATE, not slow.
        //
        // Forcing the layout here runs SwiftUI's first update pass inside the
        // present hop, so the container is told what to host before the inline
        // view gives it up, and the handover becomes atomic.
        //
        // Measured, three arms of three entries each, no overlap between them:
        // baseline 661.7 / 10.2 / 450.0 ms; flipping `isFullscreen` outside its
        // `withAnimation` transaction 825.3 / 158.5 / 360.6 ms (no effect —
        // that hypothesis is dead); **this line 0.2 / 0.2 / 0.2 ms.**
        content.view.layoutIfNeeded()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        // Both edges of the rotation are real events from the coordinator, and
        // neither is a delay; the START edge runs exit dismissal inside the
        // rotation animation so dismissal does not serialize after it.
        // Publish the incoming host aspect before UIKit commits the rotation
        // bounds animation so PlayerView never clamps a portrait 9:19 frame inside
        // landscape bounds (or vice versa) on the transition's opening pass.
        geometry.prepareForTransition(to: size)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.presenter?.hostRotationDidBegin(self)
            guard !self.isBeingDismissed, self.view.window != nil else { return }
            self.content.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.geometry.update(from: self.view)
            self.presenter?.hostDidCompleteRotation(self)
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.backgroundColor = PlayerViewModel.shared.isFullscreen ? .black : .clear
        if let presentingViewController {
            lastPresentingController = presentingViewController
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let presentingViewController {
            lastPresentingController = presentingViewController
        }
        if isBeingDismissed || presentingViewController == nil {
            restorePresentingAppearanceAndSafeArea()
        }
        presenter?.hostWillDisappear(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A host can also disappear because another controller covers it. That
        // is not a dismissal acknowledgement: keep the coordinator's physical
        // identity in that case so a later reconcile can still dismiss it.
        guard isBeingDismissed || presentingViewController == nil else { return }
        restorePresentingAppearanceAndSafeArea()
        lastPresentingController = nil
        presenter?.hostDidDisappear(self)
    }

    private func restorePresentingAppearanceAndSafeArea() {
        let target = presentingViewController
            ?? lastPresentingController
            ?? view.window?.rootViewController
            ?? AppWindowMetrics.current?.rootViewController
        guard let target else { return }
        target.setNeedsStatusBarAppearanceUpdate()
        target.setNeedsUpdateOfHomeIndicatorAutoHidden()
        target.viewIfLoaded?.setNeedsLayout()
        if let windowRoot = target.viewIfLoaded?.window?.rootViewController,
           windowRoot !== target {
            windowRoot.setNeedsStatusBarAppearanceUpdate()
            windowRoot.setNeedsUpdateOfHomeIndicatorAutoHidden()
            windowRoot.viewIfLoaded?.setNeedsLayout()
        }
    }
}
