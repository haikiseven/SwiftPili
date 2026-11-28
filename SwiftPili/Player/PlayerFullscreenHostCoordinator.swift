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
    private var presentInFlight = false
    private var dismissalInFlight = false
    private var activeAnimationPhase: Phase?
    private var pendingMask: UIInterfaceOrientationMask?
    private var pendingMaskLabel: String?
    private var rotationInFlight = false
    private var rotationGeneration: UInt64 = 0
    private var rotationFallbackTask: Task<Void, Never>?
    private var awaitingEnterAttachment = false
    private var enterAttachmentCommitScheduled = false
    private var enterAttachmentWaitTask: Task<Void, Never>?
    private var awaitingInlineReattach = false
    private var inlineReattachCommitScheduled = false
    private var inlineReattachWaitTask: Task<Void, Never>?
    private var pendingInlineDismissSource: String?
    private var handoffWaitGeneration: UInt64 = 0

    private static let enterAttachmentTimeout: Duration = .milliseconds(100)
    private static let inlineReattachTimeout: Duration = .milliseconds(120)

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
        if self.context.hostKey != context.hostKey {
            if let receipt {
                PlayerViewModel.shared.unregisterFullscreenPresentation(self, receipt: receipt)
            }
            self.context = context
            receipt = nil
            phase = .inline
        } else if self.context != context {
            self.context = context
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

    private func cancelHandoffWaits() {
        handoffWaitGeneration &+= 1
        awaitingEnterAttachment = false
        enterAttachmentCommitScheduled = false
        enterAttachmentWaitTask?.cancel()
        enterAttachmentWaitTask = nil
        awaitingInlineReattach = false
        inlineReattachCommitScheduled = false
        inlineReattachWaitTask?.cancel()
        inlineReattachWaitTask = nil
        pendingInlineDismissSource = nil
    }

    func reserveHost(
        receipt: PlayerPresentationReceipt,
        transitionCover: PlayerFullscreenTransitionCover?
    ) -> Bool {
        guard self.receipt == receipt, isCurrent, !dismissalInFlight else { return false }
        if let existingHost = host,
           phase == .leaving,
           existingHost.presentingViewController != nil {
            let wasAwaitingInlineReattach = awaitingInlineReattach
            cancelHandoffWaits()
            rotationGeneration &+= 1
            rotationFallbackTask?.cancel()
            rotationFallbackTask = nil
            existingHost.cancelActiveTransition()
            phase = .entering
            activeAnimationPhase = nil
            PlayerFullscreenTransitionState.shared.update(hostID: existingHost.identity, phase: .entering)
            if wasAwaitingInlineReattach || !PlayerViewModel.shared.hasUsableRenderAttachment(
                forRole: .fullscreen,
                ownerLease: receipt.context.ownerLease
            ) {
                if let transitionCover, !existingHost.hasTransitionCover {
                    existingHost.installTransitionCover(transitionCover)
                }
                armEnterSurfaceReadinessWait(for: existingHost)
            } else {
                existingHost.clearTransitionCover()
            }
            return true
        }
        guard host == nil,
              presentedViewController == nil,
              let presenter = modalPresentingAncestor,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else { return false }
        let controller = PlayerFullscreenHostController(
            receipt: receipt,
            presenter: self,
            liveRoom: liveRoom,
            initialInlineSnapshot: PlayerViewModel.shared.inlineStageSnapshot,
            initialTransitionCover: transitionCover
        )
        controller.transitioningDelegate = self
        reservedHost = controller
        host = controller
        phase = .entering
        activeAnimationPhase = nil
        PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .entering)
        return true
    }

    func cancelReservedHost(receipt: PlayerPresentationReceipt) {
        guard self.receipt == receipt, isCurrent, phase == .entering,
              let controller = host else { return }
        cancelHandoffWaits()
        guard controller.presentingViewController == nil else {
            reconcile()
            return
        }
        rotationFallbackTask?.cancel()
        rotationFallbackTask = nil
        host = nil
        reservedHost = nil
        presentInFlight = false
        activeAnimationPhase = nil
        phase = .inline
        pendingMask = nil
        pendingMaskLabel = nil
        PlayerFullscreenTransitionState.shared.clear(matching: controller.identity)
    }

    func reconcile() {
        guard isCurrent else { return }
        if PlayerViewModel.shared.isFullscreen {
            if reservedHost != nil {
                presentHostIfNeeded()
            } else if let controller = host,
                      phase == .entering,
                      !presentInFlight,
                      !awaitingEnterAttachment,
                      !rotationInFlight,
                      pendingMask == nil,
                      activeAnimationPhase != .entering {
                beginEnterAnimationIfNeeded(controller)
            }
        } else if let controller = host {
            if phase != .leaving, phase != .retired {
                cancelHandoffWaits()
                rotationGeneration &+= 1
                phase = .leaving
                activeAnimationPhase = nil
                controller.cancelActiveTransition()
                PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .leaving)
            }
            if phase == .leaving,
               !presentInFlight,
               !awaitingInlineReattach,
               !rotationInFlight,
               pendingMask == nil,
               activeAnimationPhase != .leaving,
               !dismissalInFlight {
                beginLeaveAnimationIfNeeded(controller)
            }
        }
    }

    func applyOrientation(mask: UIInterfaceOrientationMask, label: String) {
        guard isCurrent else { return }
        guard DeviceCapability.supportsOrientationLock else {
            pendingMask = nil
            pendingMaskLabel = nil
            rotationInFlight = false
            return
        }
        pendingMask = mask
        pendingMaskLabel = label
        if !PlayerViewModel.shared.isFullscreen, let controller = host, phase != .leaving, phase != .retired {
            cancelHandoffWaits()
            rotationGeneration &+= 1
            phase = .leaving
            activeAnimationPhase = nil
            controller.cancelActiveTransition()
            PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .leaving)
        }
        if !presentInFlight,
           !awaitingEnterAttachment,
           (phase == .fullscreen || phase == .leaving || (phase == .entering && reservedHost == nil)) {
            commitPendingOrientation(reason: "hostPresented")
        } else if !PlayerViewModel.shared.isFullscreen {
            commitPendingOrientation(reason: "entryCancelled")
        }
    }

    func surfaceAttachmentDidChange() {
        guard isCurrent, let controller = host, let receipt else { return }
        let ownerLease = receipt.context.ownerLease

        if awaitingEnterAttachment {
            if PlayerViewModel.shared.hasUsableRenderAttachment(
                forRole: .fullscreen,
                ownerLease: ownerLease
            ) {
                scheduleEnterSurfaceReadyCommit(
                    for: controller,
                    generation: handoffWaitGeneration,
                    reason: "surfaceAttached"
                )
            }
            return
        }

        if awaitingInlineReattach {
            if PlayerViewModel.shared.hasUsableRenderAttachment(
                forRole: .inline,
                ownerLease: ownerLease
            ) {
                scheduleInlineReattachDismissal(
                    for: controller,
                    generation: handoffWaitGeneration,
                    source: pendingInlineDismissSource ?? "inlineSurfaceAttached"
                )
            }
            return
        }

        if (phase == .entering || phase == .fullscreen),
           controller.hasTransitionCover,
           PlayerViewModel.shared.hasUsableRenderAttachment(
               forRole: .fullscreen,
               ownerLease: ownerLease
           ) {
            let generation = handoffWaitGeneration
            DispatchQueue.main.async { [weak self, weak controller] in
                MainActor.assumeIsolated {
                    guard let self, let controller,
                          self.accepts(controller),
                          self.handoffWaitGeneration == generation,
                          (self.phase == .entering || self.phase == .fullscreen) else { return }
                    controller.clearTransitionCover()
                }
            }
        }
    }

    func relinquishForOwnerReplacement() {
        let outgoingHost = host
        cancelHandoffWaits()
        rotationGeneration &+= 1
        phase = .retired
        presentInFlight = false
        activeAnimationPhase = nil
        pendingMask = nil
        pendingMaskLabel = nil
        rotationInFlight = false
        rotationFallbackTask?.cancel()
        rotationFallbackTask = nil
        reservedHost = nil
        outgoingHost?.cancelActiveTransition()
        outgoingHost?.clearTransitionCover()
        if DeviceCapability.supportsOrientationLock, AppOrientation.shared.mask != .portrait {
            AppOrientation.shared.set(.portrait)
            let window = outgoingHost?.viewIfLoaded?.window ?? AppWindowMetrics.current
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        if PlayerViewModel.shared.isCurrentOwner(context.ownerLease),
           PlayerViewModel.shared.activeSurfaceLease?.role == .fullscreen {
            _ = PlayerViewModel.shared.handoffSurfaceSlot(ownerLease: context.ownerLease, to: .inline)
        }
        PlayerFullscreenTransitionState.shared.clear(matching: outgoingHost?.identity)
        guard let controller = outgoingHost else { return }
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
        logEvent("presentRequested", detail: "style:overFullScreen")
        reservedHost = nil
        presentInFlight = true
        present(controller, animated: false) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.presentInFlight = false
            guard self.accepts(controller) else {
                if controller.presentingViewController != nil, !controller.isBeingDismissed {
                    controller.dismiss(animated: false)
                }
                return
            }
            guard controller.presentingViewController != nil,
                  controller.viewIfLoaded?.window != nil else {
                PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
                self.completeLeaveAndDismiss(controller, source: "presentationRefused")
                return
            }
            controller.prepareContentForWindowPresentation()
            if !PlayerViewModel.shared.isFullscreen {
                self.cancelHandoffWaits()
                self.phase = .leaving
                PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .leaving)
                self.logEvent("hostPresented")
                self.commitPendingOrientation(reason: "presented")
                self.reconcile()
                return
            }
            self.logEvent("hostPresented")
            self.armEnterSurfaceReadinessWait(for: controller)
        }
        if controller.presentingViewController == nil, accepts(controller) {
            presentInFlight = false
            PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
            completeLeaveAndDismiss(controller, source: "presentationRefused")
        }
    }

    private func armEnterSurfaceReadinessWait(for controller: PlayerFullscreenHostController) {
        guard accepts(controller), phase == .entering, let receipt else { return }
        cancelHandoffWaits()
        let waitGen = handoffWaitGeneration
        awaitingEnterAttachment = true

        if PlayerViewModel.shared.hasUsableRenderAttachment(
            forRole: .fullscreen,
            ownerLease: receipt.context.ownerLease
        ) {
            if controller.hasTransitionCover {
                scheduleEnterSurfaceReadyCommit(
                    for: controller,
                    generation: waitGen,
                    reason: "alreadyUsable"
                )
            } else {
                finishEnterSurfaceReadiness(
                    for: controller,
                    generation: waitGen,
                    reason: "alreadyUsable"
                )
            }
            return
        }

        enterAttachmentWaitTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: Self.enterAttachmentTimeout)
            guard !Task.isCancelled, let self, let controller,
                  self.accepts(controller),
                  self.awaitingEnterAttachment,
                  self.handoffWaitGeneration == waitGen else { return }
            PlayerLog.log("[Fullscreen] enter surface wait timeout — continuing transition")
            self.finishEnterSurfaceReadiness(
                for: controller,
                generation: waitGen,
                reason: "timeout"
            )
        }
    }

    private func scheduleEnterSurfaceReadyCommit(
        for controller: PlayerFullscreenHostController,
        generation: UInt64,
        reason: String
    ) {
        guard awaitingEnterAttachment,
              !enterAttachmentCommitScheduled,
              handoffWaitGeneration == generation else { return }
        enterAttachmentCommitScheduled = true
        DispatchQueue.main.async { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.finishEnterSurfaceReadiness(
                    for: controller,
                    generation: generation,
                    reason: reason
                )
            }
        }
    }

    private func finishEnterSurfaceReadiness(
        for controller: PlayerFullscreenHostController,
        generation: UInt64,
        reason: String
    ) {
        guard accepts(controller),
              awaitingEnterAttachment,
              handoffWaitGeneration == generation else { return }
        let currentReceipt = receipt
        cancelHandoffWaits()
        if let currentReceipt,
           PlayerViewModel.shared.hasUsableRenderAttachment(
               forRole: .fullscreen,
               ownerLease: currentReceipt.context.ownerLease
           ) {
            controller.clearTransitionCover()
        }
        guard phase == .entering, PlayerViewModel.shared.isFullscreen else {
            reconcile()
            return
        }
        logEvent("enterSurfaceReady", detail: reason)
        commitPendingOrientation(reason: "enterSurfaceReady")
        reconcile()
    }

    private func beginEnterAnimationIfNeeded(_ controller: PlayerFullscreenHostController) {
        guard accepts(controller), phase == .entering, activeAnimationPhase != .entering else { return }
        activeAnimationPhase = .entering
        controller.animateEnter { [weak self, weak controller] completed in
            guard let self, let controller, self.accepts(controller) else { return }
            if self.activeAnimationPhase == .entering {
                self.activeAnimationPhase = nil
            }
            if completed, self.phase == .entering, PlayerViewModel.shared.isFullscreen {
                self.phase = .fullscreen
                PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .fullscreen)
                self.logEvent("enterSettled")
            } else {
                self.reconcile()
            }
        }
    }

    private func beginLeaveAnimationIfNeeded(_ controller: PlayerFullscreenHostController) {
        guard accepts(controller), phase == .leaving, activeAnimationPhase != .leaving, !dismissalInFlight else { return }
        if controller.presentingViewController == nil {
            completeLeaveAndDismiss(controller, source: "unsubmitted")
            return
        }
        activeAnimationPhase = .leaving
        let snapshot = PlayerViewModel.shared.inlineStageSnapshot
        if controller.usesFadeOutLeave(to: snapshot),
           let receipt,
           PlayerViewModel.shared.isCurrentOwner(receipt.context.ownerLease),
           PlayerViewModel.shared.activeSurfaceLease?.role == .fullscreen {
            if controller.isStageVisuallyVisible,
               !controller.hasTransitionCover,
               let cover = PlayerViewModel.shared.captureFullscreenTransitionCover() {
                controller.installTransitionCover(cover)
            }
            _ = PlayerViewModel.shared.handoffSurfaceSlot(ownerLease: receipt.context.ownerLease, to: .inline)
        }
        controller.animateLeave(to: snapshot) { [weak self, weak controller] completed in
            guard let self, let controller, self.accepts(controller) else { return }
            if self.activeAnimationPhase == .leaving {
                self.activeAnimationPhase = nil
            }
            if completed, self.phase == .leaving, !PlayerViewModel.shared.isFullscreen {
                self.completeLeaveAndDismiss(controller, source: "leaveAnimation")
            } else {
                self.reconcile()
            }
        }
    }

    private func completeLeaveAndDismiss(_ controller: PlayerFullscreenHostController, source: String) {
        guard host === controller, !dismissalInFlight, !awaitingInlineReattach else { return }
        if controller.presentingViewController == nil {
            cancelHandoffWaits()
            if let receipt,
               PlayerViewModel.shared.isCurrentOwner(receipt.context.ownerLease),
               PlayerViewModel.shared.activeSurfaceLease?.role == .fullscreen {
                _ = PlayerViewModel.shared.handoffSurfaceSlot(ownerLease: receipt.context.ownerLease, to: .inline)
            }
            hostDidDismiss(controller, source: source)
            return
        }

        if accepts(controller),
           let receipt,
           controller.isViewLoaded,
           controller.view.window != nil,
           PlayerViewModel.shared.isCurrentOwner(receipt.context.ownerLease) {
            let isFullscreenSlot = PlayerViewModel.shared.activeSurfaceLease?.role == .fullscreen
            let expectsInlineAttachment = PlayerViewModel.shared.currentURL != nil
                || PlayerViewModel.shared.retainsRecoveryRenderContainer(owner: receipt.context.ownerLease.owner)
            let needsInlineReattach = isFullscreenSlot
                || (expectsInlineAttachment
                    && !PlayerViewModel.shared.hasUsableRenderAttachment(
                        forRole: .inline,
                        ownerLease: receipt.context.ownerLease
                    ))
            if needsInlineReattach {
                if controller.isStageVisuallyVisible,
                   !controller.hasTransitionCover,
                   let cover = PlayerViewModel.shared.captureFullscreenTransitionCover() {
                    controller.installTransitionCover(cover)
                }
                if isFullscreenSlot {
                    _ = PlayerViewModel.shared.handoffSurfaceSlot(ownerLease: receipt.context.ownerLease, to: .inline)
                }
                beginInlineReattachWait(
                    for: controller,
                    ownerLease: receipt.context.ownerLease,
                    source: source
                )
                return
            }
        }

        cancelHandoffWaits()
        if let receipt,
           PlayerViewModel.shared.isCurrentOwner(receipt.context.ownerLease),
           PlayerViewModel.shared.activeSurfaceLease?.role == .fullscreen {
            _ = PlayerViewModel.shared.handoffSurfaceSlot(ownerLease: receipt.context.ownerLease, to: .inline)
        }
        requestHostDismissal(controller, animated: false)
    }

    private func beginInlineReattachWait(
        for controller: PlayerFullscreenHostController,
        ownerLease: PlayerOwnerLease,
        source: String
    ) {
        cancelHandoffWaits()
        let waitGen = handoffWaitGeneration
        awaitingInlineReattach = true
        pendingInlineDismissSource = source

        if PlayerViewModel.shared.hasUsableRenderAttachment(
            forRole: .inline,
            ownerLease: ownerLease
        ) {
            scheduleInlineReattachDismissal(
                for: controller,
                generation: waitGen,
                source: source
            )
            return
        }

        inlineReattachWaitTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: Self.inlineReattachTimeout)
            guard !Task.isCancelled, let self, let controller,
                  self.host === controller,
                  self.awaitingInlineReattach,
                  self.handoffWaitGeneration == waitGen else { return }
            PlayerLog.log("[Fullscreen] inline reattach wait timeout — dismissing host")
            self.finishInlineReattachAndDismiss(
                for: controller,
                generation: waitGen,
                source: "\(source)-timeout"
            )
        }
    }

    private func scheduleInlineReattachDismissal(
        for controller: PlayerFullscreenHostController,
        generation: UInt64,
        source: String
    ) {
        guard awaitingInlineReattach,
              !inlineReattachCommitScheduled,
              handoffWaitGeneration == generation else { return }
        inlineReattachCommitScheduled = true
        DispatchQueue.main.async { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.finishInlineReattachAndDismiss(
                    for: controller,
                    generation: generation,
                    source: source
                )
            }
        }
    }

    private func finishInlineReattachAndDismiss(
        for controller: PlayerFullscreenHostController,
        generation: UInt64,
        source: String
    ) {
        guard host === controller,
              awaitingInlineReattach,
              handoffWaitGeneration == generation else { return }
        cancelHandoffWaits()
        guard phase == .leaving, !PlayerViewModel.shared.isFullscreen else {
            reconcile()
            return
        }
        if controller.presentingViewController == nil {
            hostDidDismiss(controller, source: source)
        } else {
            requestHostDismissal(controller, animated: false)
        }
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
        cancelHandoffWaits()
        controller.clearTransitionCover()
        rotationFallbackTask?.cancel()
        rotationFallbackTask = nil
        let current = accepts(controller)
        if current, let receipt {
            if PlayerViewModel.shared.isCurrentOwner(receipt.context.ownerLease),
               PlayerViewModel.shared.activeSurfaceLease?.role == .fullscreen {
                _ = PlayerViewModel.shared.handoffSurfaceSlot(ownerLease: receipt.context.ownerLease, to: .inline)
            }
            PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
        }
        host = nil
        reservedHost = nil
        presentInFlight = false
        dismissalInFlight = false
        activeAnimationPhase = nil
        rotationInFlight = false
        PlayerFullscreenTransitionState.shared.clear(matching: controller.identity)
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

    func acceptsRotationPinning(_ controller: PlayerFullscreenHostController, generation: UInt64) -> Bool {
        accepts(controller) && generation != 0 && generation == rotationGeneration
    }

    func hostRotationWillBegin(
        _ controller: PlayerFullscreenHostController,
        to size: CGSize
    ) -> PlayerFullscreenHostController.RotationPlan {
        guard accepts(controller) else {
            return .init(generation: 0, mode: .steadyFullscreen)
        }
        let isPhone = DeviceCapability.supportsOrientationLock
        let isLandscapeSize = size.width > size.height

        if !PlayerViewModel.shared.isFullscreen {
            if awaitingInlineReattach {
                return .init(generation: 0, mode: .steadyFullscreen)
            }
            if isPhone, isLandscapeSize {
                return .init(generation: 0, mode: .steadyFullscreen)
            }
            if awaitingEnterAttachment {
                cancelHandoffWaits()
            }
            rotationFallbackTask?.cancel()
            rotationFallbackTask = nil
            phase = .leaving
            activeAnimationPhase = .leaving
            PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .leaving)
            return .init(
                generation: rotationGeneration,
                mode: .leaving(PlayerViewModel.shared.inlineStageSnapshot)
            )
        }
        if phase == .entering {
            if isPhone, !PlayerViewModel.shared.isPortraitContent, !isLandscapeSize {
                return .init(generation: 0, mode: .steadyFullscreen)
            }
            if awaitingEnterAttachment {
                cancelHandoffWaits()
                if let receipt,
                   PlayerViewModel.shared.hasUsableRenderAttachment(
                       forRole: .fullscreen,
                       ownerLease: receipt.context.ownerLease
                   ) {
                    controller.clearTransitionCover()
                }
            }
            rotationFallbackTask?.cancel()
            rotationFallbackTask = nil
            activeAnimationPhase = .entering
            return .init(generation: rotationGeneration, mode: .entering)
        }
        rotationFallbackTask?.cancel()
        rotationFallbackTask = nil
        return .init(generation: rotationGeneration, mode: .steadyFullscreen)
    }

    func hostDidCompleteRotation(
        _ controller: PlayerFullscreenHostController,
        completedMode: PlayerFullscreenHostController.RotationTransitionKind,
        generation: UInt64,
        cancelled: Bool
    ) {
        guard accepts(controller) else { return }
        let isCurrentRotation = generation != 0 && generation == rotationGeneration
        if isCurrentRotation {
            rotationFallbackTask?.cancel()
            rotationFallbackTask = nil
            rotationInFlight = false
            if (completedMode == .entering && activeAnimationPhase == .entering)
                || (completedMode == .leaving && activeAnimationPhase == .leaving) {
                activeAnimationPhase = nil
            }
        }
        if pendingMask != nil {
            commitPendingOrientation(reason: "rotationCompleted")
        }
        if PlayerViewModel.shared.isFullscreen {
            if DeviceCapability.supportsOrientationLock,
               !PlayerViewModel.shared.isPortraitContent,
               sceneWillRotate(to: .landscape) {
                if !rotationInFlight {
                    pendingMask = .landscape
                    pendingMaskLabel = "landscape"
                    commitPendingOrientation(reason: "reenterToLandscape")
                }
                return
            }
            if isCurrentRotation, !cancelled, completedMode == .entering,
               !rotationInFlight, phase == .entering {
                phase = .fullscreen
                PlayerFullscreenTransitionState.shared.update(hostID: controller.identity, phase: .fullscreen)
                logEvent("enterRotationSettled")
                return
            }
            if !rotationInFlight {
                reconcile()
            }
            return
        }
        if phase == .leaving {
            if DeviceCapability.supportsOrientationLock, sceneWillRotate(to: .portrait) {
                if !rotationInFlight {
                    pendingMask = .portrait
                    pendingMaskLabel = "portrait"
                    commitPendingOrientation(reason: "reverseToPortrait")
                }
                return
            }
            if isCurrentRotation, !cancelled, completedMode == .leaving,
               !rotationInFlight, pendingMask == nil, !dismissalInFlight {
                completeLeaveAndDismiss(controller, source: "rotationCompletion")
                return
            }
        }
        if !rotationInFlight {
            reconcile()
        }
    }

    func hostWillDisappear(_ controller: PlayerFullscreenHostController) {
        guard accepts(controller), let receipt,
              controller.isBeingDismissed || controller.presentingViewController == nil else { return }
        PlayerViewModel.shared.exitFullscreen(presentation: self, receipt: receipt)
    }

    private func sceneWillRotate(to mask: UIInterfaceOrientationMask) -> Bool {
        guard DeviceCapability.supportsOrientationLock else { return false }
        let window = host?.viewIfLoaded?.window ?? AppWindowMetrics.current
        guard let scene = window?.windowScene else { return false }
        let current = Self.interfaceOrientationMask(for: scene.interfaceOrientation)
        return !current.isEmpty && !mask.contains(current)
    }

    private func commitPendingOrientation(reason: String) {
        guard isCurrent, let mask = pendingMask, let receipt else { return }
        let label = pendingMaskLabel ?? Self.maskLabel(mask)
        pendingMask = nil
        pendingMaskLabel = nil
        rotationFallbackTask?.cancel()
        rotationFallbackTask = nil
        rotationGeneration &+= 1
        let expectedGeneration = rotationGeneration
        let willRotate = sceneWillRotate(to: mask)
        rotationInFlight = willRotate
        AppOrientation.shared.set(mask)
        host?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let window = host?.viewIfLoaded?.window ?? AppWindowMetrics.current
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        logEvent("sceneRotationRequested", detail: "mask:\(label),why:\(reason)")
        let rotatingHost = host
        if willRotate, let rotatingHost {
            scheduleRotationFallback(for: rotatingHost, expectedGeneration: expectedGeneration)
        }
        window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: mask)
        ) { [weak self, weak rotatingHost] error in
            guard let self, self.receipt == receipt, self.isCurrent,
                  let rotatingHost, self.accepts(rotatingHost),
                  self.rotationGeneration == expectedGeneration else { return }
            PlayerLog.log("[Fullscreen] scene rotation rejected mask=\(label) error=\(error.localizedDescription)")
            self.rotationFallbackTask?.cancel()
            self.rotationFallbackTask = nil
            self.rotationInFlight = false
            self.reconcile()
        }
    }

    private func scheduleRotationFallback(
        for rotatingHost: PlayerFullscreenHostController,
        expectedGeneration: UInt64
    ) {
        rotationFallbackTask = Task { @MainActor [weak self, weak rotatingHost] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, let rotatingHost,
                  self.accepts(rotatingHost), self.rotationInFlight,
                  self.rotationGeneration == expectedGeneration else { return }
            PlayerLog.log("[Fullscreen] rotation fallback triggered phase=\(self.phase)")
            self.rotationFallbackTask = nil
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
        guard PlayerLog.isCapturing else { return }
        let window = AppWindowMetrics.current
        var line = "[Fullscreen] host event=\(event)"
        if let hostView = host?.viewIfLoaded {
            line += " hostOnWindow=\(hostView.window != nil ? "y" : "n")"
        } else {
            line += " hostOnWindow=n/a"
        }
        line += " presenterOffWindow=\(viewIfLoaded?.window == nil ? "y" : "n")"
        line += " mask=\(Self.maskLabel(AppOrientation.shared.mask))"
        let scene = (host?.viewIfLoaded?.window ?? window)?.windowScene
        line += " orient=\(scene.map { Self.orientationLabel($0.interfaceOrientation) } ?? "n/a")"
        let player = PlayerViewModel.shared
        line += " vmFS=\(player.isFullscreen ? "y" : "n")"
        line += " play=\(player.isPlaying ? "y" : "n")"
        line += " mt=\(String(format: "%.2f", player.mediaTime))"
        line += " detail=\(detail ?? "-")"
        PlayerLog.log(line)
    }

    private static func maskLabel(_ mask: UIInterfaceOrientationMask) -> String {
        switch mask {
        case .landscape: "landscape"
        case .portrait: "portrait"
        case .all: "all"
        case .allButUpsideDown: "allButUpsideDown"
        default: "other"
        }
    }

    private static func orientationLabel(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func interfaceOrientationMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown: []
        @unknown default: []
        }
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
