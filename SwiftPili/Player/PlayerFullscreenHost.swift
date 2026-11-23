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
    enum RotationTransitionKind: Equatable, Sendable {
        case entering
        case leaving
        case steadyFullscreen
    }

    enum RotationTransitionMode {
        case entering
        case leaving(PlayerFullscreenStageGeometry.InlineSnapshot?)
        case steadyFullscreen

        var kind: RotationTransitionKind {
            switch self {
            case .entering: .entering
            case .leaving: .leaving
            case .steadyFullscreen: .steadyFullscreen
            }
        }
    }

    struct RotationPlan {
        let generation: UInt64
        let mode: RotationTransitionMode
    }

    private weak var presenter: PlayerFullscreenHostCoordinator?
    private weak var lastPresentingController: UIViewController?
    let receipt: PlayerPresentationReceipt
    let identity: UUID
    private let content: UIHostingController<PlayerFullscreenHostContent>
    private let geometry: PlayerFullscreenHostGeometry
    private let initialInlineSnapshot: PlayerFullscreenStageGeometry.InlineSnapshot?

    private let backdropView = UIView()
    private let stageContainerView = UIView()
    private var currentAnimator: UIViewPropertyAnimator?
    private var transitionGeneration: UInt64 = 0
    private var stageIsPinnedToFullBounds = false
    private var isTransitioningSize = false

    private var prefersReducedMotion: Bool {
        UIAccessibility.isReduceMotionEnabled || UIAccessibility.prefersCrossFadeTransitions
    }

    init(
        receipt: PlayerPresentationReceipt,
        presenter: PlayerFullscreenHostCoordinator,
        liveRoom: LiveRoomViewModel?,
        initialInlineSnapshot: PlayerFullscreenStageGeometry.InlineSnapshot?
    ) {
        self.receipt = receipt
        let identity = UUID()
        self.identity = identity
        self.presenter = presenter
        self.initialInlineSnapshot = initialInlineSnapshot
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
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PlayerFullscreenHostController is created in code only")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if stageIsPinnedToFullBounds, currentAnimator == nil, !isTransitioningSize {
            if stageContainerView.frame != view.bounds {
                stageContainerView.frame = view.bounds
            }
            if stageContainerView.layer.cornerRadius != 0 {
                stageContainerView.layer.cornerRadius = 0
            }
        }
        geometry.update(from: view, stageSize: stageContainerView.bounds.size)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        geometry.update(from: view, stageSize: stageContainerView.bounds.size)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : AppOrientation.shared.mask
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backdropView.backgroundColor = .black
        backdropView.alpha = 0
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdropView)

        stageContainerView.backgroundColor = .black
        stageContainerView.clipsToBounds = true
        stageContainerView.layer.cornerCurve = .continuous
        view.addSubview(stageContainerView)

        addChild(content)
        content.view.backgroundColor = .clear
        content.view.frame = stageContainerView.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.safeAreaRegions.remove(.keyboard)
        stageContainerView.addSubview(content.view)
        content.didMove(toParent: self)

        applyInitialStageGeometry()
        geometry.update(from: view, stageSize: stageContainerView.bounds.size)
        stageContainerView.layoutIfNeeded()
        content.view.layoutIfNeeded()
    }

    private func applyInitialStageGeometry() {
        let target = resolvedInlineTarget(snapshot: initialInlineSnapshot, in: view.bounds.size)
        stageIsPinnedToFullBounds = false
        if let target, !prefersReducedMotion {
            stageContainerView.autoresizingMask = []
            stageContainerView.frame = target.rect
            stageContainerView.layer.cornerRadius = target.cornerRadius
            stageContainerView.alpha = 1
        } else {
            stageContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stageContainerView.frame = view.bounds
            stageContainerView.layer.cornerRadius = 0
            stageContainerView.alpha = 0
        }
    }

    private func resolvedInlineTarget(
        snapshot: PlayerFullscreenStageGeometry.InlineSnapshot?,
        in containerSize: CGSize
    ) -> PlayerFullscreenStageGeometry.ResolvedStageTarget? {
        let hostFrame = viewIfLoaded?.window.map {
            view.convert(view.bounds, to: $0.screen.coordinateSpace)
        }
        return PlayerFullscreenStageGeometry.resolvedInlineStageRect(
            snapshot: snapshot,
            containerSize: containerSize,
            hostFrameInScreen: hostFrame
        )
    }

    private func pinStageToFullBounds(size: CGSize? = nil) {
        let bounds = size.map { CGRect(origin: .zero, size: $0) } ?? view.bounds
        stageIsPinnedToFullBounds = true
        stageContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stageContainerView.frame = bounds
        stageContainerView.layer.cornerRadius = 0
        stageContainerView.alpha = 1
        backdropView.alpha = 1
        stageContainerView.layoutIfNeeded()
        content.view.layoutIfNeeded()
    }

    func cancelActiveTransition() {
        transitionGeneration &+= 1
        if let animator = currentAnimator {
            animator.stopAnimation(true)
            currentAnimator = nil
        }
    }

    func animateEnter(completion: @escaping @MainActor (Bool) -> Void) {
        cancelActiveTransition()
        let gen = transitionGeneration
        stageIsPinnedToFullBounds = false
        view.layoutIfNeeded()

        let reduceMotion = prefersReducedMotion
        if reduceMotion {
            stageContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stageContainerView.frame = view.bounds
            stageContainerView.layer.cornerRadius = 0
            stageContainerView.layoutIfNeeded()
        } else {
            stageContainerView.autoresizingMask = []
        }

        let animator = reduceMotion
            ? UIViewPropertyAnimator(duration: 0.15, curve: .easeInOut)
            : UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.92)
        currentAnimator = animator
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.backdropView.alpha = 1
            self.stageContainerView.alpha = 1
            if !reduceMotion {
                self.stageContainerView.frame = self.view.bounds
                self.stageContainerView.layer.cornerRadius = 0
                self.stageContainerView.layoutIfNeeded()
                self.content.view.layoutIfNeeded()
            }
        }
        animator.addCompletion { [weak self] position in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == gen else { return }
                self.currentAnimator = nil
                let completed = position == .end
                if completed {
                    self.pinStageToFullBounds()
                }
                self.geometry.update(from: self.view, stageSize: self.stageContainerView.bounds.size)
                completion(completed)
            }
        }
        animator.startAnimation()
    }

    func animateLeave(
        to snapshot: PlayerFullscreenStageGeometry.InlineSnapshot?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        cancelActiveTransition()
        let gen = transitionGeneration
        stageIsPinnedToFullBounds = false
        stageContainerView.autoresizingMask = []
        view.layoutIfNeeded()

        let target = resolvedInlineTarget(snapshot: snapshot, in: view.bounds.size)
        let reduceMotion = prefersReducedMotion || target == nil
        let animator = reduceMotion
            ? UIViewPropertyAnimator(duration: prefersReducedMotion ? 0.15 : 0.20, curve: .easeInOut)
            : UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.92)
        currentAnimator = animator
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.backdropView.alpha = 0
            if reduceMotion {
                self.stageContainerView.alpha = 0
            } else if let target {
                self.stageContainerView.frame = target.rect
                self.stageContainerView.layer.cornerRadius = target.cornerRadius
                self.stageContainerView.layoutIfNeeded()
                self.content.view.layoutIfNeeded()
            }
        }
        animator.addCompletion { [weak self] position in
            MainActor.assumeIsolated {
                guard let self, self.transitionGeneration == gen else { return }
                self.currentAnimator = nil
                completion(position == .end)
            }
        }
        animator.startAnimation()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        isTransitioningSize = true
        geometry.prepareForTransition(to: size)
        let plan = presenter?.hostRotationWillBegin(self, to: size)
            ?? RotationPlan(generation: 0, mode: .steadyFullscreen)
        let rotationGen = plan.generation
        let completedKind = plan.mode.kind

        switch plan.mode {
        case .entering:
            cancelActiveTransition()
            let gen = transitionGeneration
            stageIsPinnedToFullBounds = false
            let reduceMotion = prefersReducedMotion
            stageContainerView.autoresizingMask = reduceMotion ? [.flexibleWidth, .flexibleHeight] : []
            if reduceMotion {
                stageContainerView.frame = CGRect(origin: .zero, size: size)
                stageContainerView.layer.cornerRadius = 0
            }
            coordinator.animate(alongsideTransition: { [weak self] _ in
                guard let self else { return }
                self.backdropView.alpha = 1
                self.stageContainerView.alpha = 1
                if !reduceMotion {
                    self.stageContainerView.frame = CGRect(origin: .zero, size: size)
                    self.stageContainerView.layer.cornerRadius = 0
                }
                self.stageContainerView.layoutIfNeeded()
                self.content.view.layoutIfNeeded()
            }, completion: { [weak self] ctx in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTransitioningSize = false
                    if self.transitionGeneration == gen, !ctx.isCancelled,
                       PlayerViewModel.shared.isFullscreen,
                       self.presenter?.acceptsRotationPinning(self, generation: rotationGen) == true {
                        self.pinStageToFullBounds(size: size)
                    }
                    self.geometry.update(from: self.view, stageSize: self.stageContainerView.bounds.size)
                    self.presenter?.hostDidCompleteRotation(
                        self,
                        completedMode: completedKind,
                        generation: rotationGen,
                        cancelled: ctx.isCancelled
                    )
                }
            })

        case .leaving(let snapshot):
            cancelActiveTransition()
            let gen = transitionGeneration
            stageIsPinnedToFullBounds = false
            let target = resolvedInlineTarget(snapshot: snapshot, in: size)
            let reduceMotion = prefersReducedMotion || target == nil
            coordinator.animate(alongsideTransition: { [weak self] _ in
                guard let self else { return }
                self.stageContainerView.autoresizingMask = []
                self.backdropView.alpha = 0
                if reduceMotion {
                    self.stageContainerView.alpha = 0
                } else if let target {
                    self.stageContainerView.frame = target.rect
                    self.stageContainerView.layer.cornerRadius = target.cornerRadius
                    self.stageContainerView.layoutIfNeeded()
                    self.content.view.layoutIfNeeded()
                }
            }, completion: { [weak self] ctx in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTransitioningSize = false
                    if self.transitionGeneration == gen {
                        self.geometry.update(from: self.view, stageSize: self.stageContainerView.bounds.size)
                    }
                    self.presenter?.hostDidCompleteRotation(
                        self,
                        completedMode: completedKind,
                        generation: rotationGen,
                        cancelled: ctx.isCancelled
                    )
                }
            })

        case .steadyFullscreen:
            coordinator.animate(alongsideTransition: { [weak self] _ in
                guard let self else { return }
                if self.stageIsPinnedToFullBounds {
                    self.stageContainerView.frame = CGRect(origin: .zero, size: size)
                }
                guard !self.isBeingDismissed, self.view.window != nil else { return }
                self.stageContainerView.layoutIfNeeded()
                self.content.view.layoutIfNeeded()
            }, completion: { [weak self] ctx in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTransitioningSize = false
                    self.geometry.update(from: self.view, stageSize: self.stageContainerView.bounds.size)
                    self.presenter?.hostDidCompleteRotation(
                        self,
                        completedMode: completedKind,
                        generation: rotationGen,
                        cancelled: ctx.isCancelled
                    )
                }
            })
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
