import SwiftUI
import UIKit

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

@MainActor
final class PlayerFullscreenHostController: UIViewController, PlayerPresentationHost {
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

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : AppOrientation.shared.mask
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlayerViewModel.shared.isFullscreen ? .black : .clear
        addChild(content)
        content.view.backgroundColor = .clear
        content.view.translatesAutoresizingMaskIntoConstraints = false
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
        content.view.layoutIfNeeded()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
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

    func enterLeavingState() {
        viewIfLoaded?.backgroundColor = .clear
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
