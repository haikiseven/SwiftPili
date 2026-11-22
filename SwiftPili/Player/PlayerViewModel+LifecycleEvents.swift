import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func handleWillEnterForeground() {
        if streamRecoveryOwnsWork { return }
        synchronizeTerminalAdmissionFromBackend()
        guard !standDownLifecycleForTerminalPlayback() else { return }
        guard usesDemandPresentationContinuity else { return }
        // A background tape that never reached bgDone (early return, or a
        // resign that never became a background) must not collect foreground
        // stages against a stale base.
        demandBackgroundStageTape = nil
        let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
        // The tape is opened only once the session is known, and any tape still open from an earlier
        // transition is closed here rather than left for a later session's proof to close.
        guard let fence = makeDemandPresentationFence(epoch: epoch) else {
            discardDemandForegroundStageTape()
            return
        }
        markDemandForegroundStage("willEnter", startsTransition: true, fence: fence)
        dispatchDemandPresentation(.foregroundTransitionBegan(fence: fence))
    }

    /// Apply continuation policy through the existing Demand coordinator or the legacy recovery path.
    func handleDidEnterBackground() {
        protectPendingBackgroundPlayback()
        reconcileAmbientStoryboard(allowWork: false)
        deferStreamRecoveryForBackground()
        noteDanmakuApplicationActivityChanged(isActive: false)
        synchronizeTerminalAdmissionFromBackend()
        snapshotNowPlayingForBackground()
        guard !standDownLifecycleForTerminalPlayback() else { return }
        markDemandBackgroundStage("enterBG")
        updateDemandVideoLivenessContext()
        let configuration = PlayerPlaybackPreferences.playbackContinuationConfiguration
        PlayerLog.log(
            "[Lifecycle] didEnterBackground backgroundAudio=" +
            "\(configuration.backgroundAudioEnabled ? 1 : 0) pictureInPicture=" +
            "\(configuration.pictureInPictureEnabled ? 1 : 0) " +
            "generation=\(playerGeneration)"
        )
        if usesDemandPresentationContinuity {
            // `willResignActive` is normally first, but lock/system transitions
            // can deliver only didEnterBackground. Preserve the same PiP edge
            // snapshot before the reducer advances its lifecycle epoch.
            backend.noteDemandPiPEnvironmentWillResignActive()
            lifecycleRecoveryTask?.cancel()
            let preservesCurrentProof = lifecycleRecovery
                .preservesPresentationLivenessAcrossEnvironmentChange
            let epoch = lifecycleRecovery.beginDemandPresentationEpoch()
            // No fence means no playback session, so this transition has nothing to measure — and the tape
            // opened by `willResignActive` must not survive to collect a later cycle's stages against a stale
            // base.
            guard let fence = makeDemandPresentationFence(epoch: epoch) else {
                demandBackgroundStageTape = nil
                return
            }
            if preservesCurrentProof {
                demandPresentationLiveness.begin(
                    fence,
                    preservingExistingProof: true
                )
            }
            markDemandBackgroundStage("dispatch")
            dispatchDemandPresentation(.didEnterBackground(
                configuration: configuration,
                observedPiPLease: backend.hasObservedPiPLease,
                fence: fence,
                userWantsPlaying: userWantsPlaying
            ))
            updateDemandVideoLivenessContext()
            markDemandBackgroundStage("bgDone")
            return
        }
        guard configuration.allowsBackgroundPlayback else {
            lifecycleRecoveryTask?.cancel()
            lifecycleRecovery.invalidate()
            decoderSessionSuspect = false
            needsReloadBeforeExplicitPlay = switch mode {
            case .vod:
                currentURL != nil && currentURL?.isFileURL == false
            case .offline:
                currentURL?.isFileURL == true && offlineAsset != nil
            case .live:
                false
            }
            // Paused playback must not auto-reload, but backgrounding can
            // still invalidate its drawable. Reattach it on foreground before
            // the user next presses play.
            needsInlineSurfaceRebuild = true
            if backend.isPiPActive || backend.hasObservedPiPLease {
                backend.stopPiP()
            }
            // This is an explicit user policy, not an audio-session
            // interruption. Remain paused after foregrounding until the user
            // presses play again.
            playbackIntent = .pausedByUser
            suspendPlayback()
            PlayerLog.log(
                "[Player] background playback disabled — paused; explicitPlayReload=" +
                "\(needsReloadBeforeExplicitPlay ? 1 : 0)"
            )
            return
        }
        // Suspect on every background: `isPiPActive` is sticky on an ordinary
        // app switch, so it is reported but never an exclusion.
        let pip = backend.isPiPActive
        decoderSessionSuspect = true
        // A background transition can invalidate the drawable even when the
        // user is paused. This non-Demand branch uses its serialized recovery
        // path; paused sessions perform only a containment rebind.
        needsInlineSurfaceRebuild = true
        backend.invalidateFrameStats()
        stats.fps = 0
        PlayerLog.log(
            "[Player] background — decoderSessionSuspect=1 pipReported=\(pip ? 1 : 0)"
        )
        let reloadWhileBackgrounded =
            configuration.mode == .pictureInPicture && !backend.hasObservedPiPLease
        let action = lifecycleRecovery.enteredBackground(
            reloadWhileBackgrounded: reloadWhileBackgrounded
        )
        if !reloadWhileBackgrounded {
            PlayerLog.log(
                "[Lifecycle] epoch=\(lifecycleRecovery.epoch) background reload deferred " +
                "mode=\(configuration.mode) observedPiP=\(backend.hasObservedPiPLease ? 1 : 0)"
            )
        }
        scheduleLifecycleRecovery(action)
    }

    /// Reconcile terminal state and the actual foreground destination before requiring or retaining picture
    /// proof.
    func scheduleForegroundLivenessCheck() {
        backgroundExecution.end(reason: "foreground")
        handleNativeAudioOutputChange()
        // Update activity first, but admit visible work only after reconciling
        // terminal backend truth (including EOF reached in the background).
        danmakuApplicationActive = UIApplication.shared.applicationState == .active
        synchronizeTerminalAdmissionFromBackend()
        guard !standDownLifecycleForTerminalPlayback() else {
            // Stopped/failed playback was already suspended by the stand-down.
            // A natural end is a held last frame: refill it like a pause.
            noteDanmakuApplicationActivityChanged(isActive: danmakuApplicationActive)
            return
        }
        noteDanmakuApplicationActivityChanged(isActive: danmakuApplicationActive)
        if usesDemandPresentationContinuity {
            let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
            // Arm liveness against the destination `didBecomeActive` will ACTUALLY reserve.
            let destination = lifecycleRecovery.foregroundPresentationDestination
            let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
            let targetRenderGeneration = decision.foregroundRenderGeneration(
                for: destination,
                currentRenderGeneration: playerGeneration
            )
            // Same rule as `willEnter`: an activation with no playback session
            // has nothing to measure, and its tape must not survive to be
            // closed by the next session's proof.
            guard let fence = makeDemandPresentationFence(
                epoch: epoch,
                renderGeneration: targetRenderGeneration
            ) else {
                discardDemandForegroundStageTape()
                return
            }
            // `willEnter` is not guaranteed — activation can arrive without it,
            // and that fallback is exactly the row worth measuring.
            markDemandForegroundStage(
                "active",
                startsTransition: demandForegroundStageTape == nil,
                fence: fence
            )
            switch destination {
            case .preservedPiP, .retainedPassiveInline:
                let previousRenderGeneration = lifecycleRecovery.presentationPhase.fence?
                    .renderGeneration
                let preservesProof = previousRenderGeneration == fence.renderGeneration
                demandPresentationLiveness.begin(
                    fence,
                    preservingExistingProof: preservesProof
                )
            case .unprovenPassiveInline, .reservedNewInline:
                beginDemandPresentationDebt(fence)
            }
            let abandonsPendingPiPStart: Bool = {
                guard destination == .reservedNewInline else { return false }
                if case .pipStarting = lifecycleRecovery.presentationPhase {
                    return true
                }
                return false
            }()
            if abandonsPendingPiPStart {
                dispatchDemandPresentation(.pipStartAbandoned(fence: fence))
            }
            dispatchDemandPresentation(.didBecomeActive(fence: fence))
            if destination == .preservedPiP {
                // Reconcile the retained PiP presentation before preparing the inline destination.
                dispatchDemandPresentation(.pipPresentationNeedsReconcile(
                    fence: fence
                ))
            }
            // This refresh is renderer-local and idempotent: a healthy displayed hold short-circuits, and no
            // hold at all is a no-op.
            backend.refreshDemandPresentationImageHold()
            updateDemandVideoLivenessContext()
            return
        }
        let retainedHealth = backend.retainedPipelineHealth
        let action = lifecycleRecovery.becameActive(
            retainedPipelineHealth: retainedHealth,
            expectsPlaying: userWantsPlaying
        )
        PlayerLog.log(
            "[Lifecycle] foreground retained-health=" +
                "\(String(describing: retainedHealth.state)) " +
                "backendGen=\(retainedHealth.backendGeneration) action=\(action)"
        )
        if InlineSurfaceBindingPolicy.shouldRebindOnForeground(
            needsInlineSurfaceRebuild: needsInlineSurfaceRebuild,
            userWantsPlaying: userWantsPlaying,
            lifecycleAction: action
        ) {
            reattachInlineSurface()
            needsInlineSurfaceRebuild = false
            PlayerLog.log("[Lifecycle] paused inline-surface-rebind generation=\(playerGeneration)")
        }
        scheduleLifecycleRecovery(action)
        reconcileAmbientStoryboard()
        updateDemandVideoLivenessContext()
    }

    private func scheduleLifecycleRecovery(_ action: LifecycleRecoveryCoordinator.Action) {
        guard case .schedule(let trigger, let epoch) = action else {
            consumeLifecycleRecovery(action)
            return
        }
        lifecycleRecoveryTask?.cancel()
        // Legacy non-Demand recovery retains its existing conditional settle.
        // Demand presentation continuity never reaches this timer: active PiP
        // is a no-op and explicit handoff waits on typed native/attachment edges.
        let pipDismissalPending = backend.isPiPActive || backend.hasObservedPiPLease
        let delay = ForegroundDecoderPolicy.settleDelay(
            forBackground: trigger == .background,
            pictureInPictureDismissalPending: pipDismissalPending
        )
        PlayerLog.log(
            "[Lifecycle] epoch=\(epoch) schedule=\(trigger) " +
                "delay=\(String(format: "%.2f", delay)) pip=\(pipDismissalPending ? 1 : 0)"
        )
        lifecycleRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.consumeLifecycleRecovery(
                self.lifecycleRecovery.settleFinished(trigger: trigger, epoch: epoch)
            )
        }
    }

    func consumeLifecycleRecovery(_ action: LifecycleRecoveryCoordinator.Action) {
        switch action {
        case .none:
            return
        case .schedule:
            scheduleLifecycleRecovery(action)
        case .reload(let trigger, let epoch):
            // Only the coordinator's scheduled action starts this lifecycle
            // open. A later foreground handoff is represented by
            // `reattachAndAwait`, never by a health assessment here.
            decoderSessionSuspect = true
            lifecycleRecoveryTask = Task { @MainActor [weak self] in
                await self?.performLifecycleRecovery(trigger: trigger, epoch: epoch)
            }
        case .rebindInline(let epoch):
            guard UIApplication.shared.applicationState == .active else { return }
            reattachInlineSurface()
            needsInlineSurfaceRebuild = false
            PlayerLog.log("[Lifecycle] epoch=\(epoch) inline-surface-rebind generation=\(playerGeneration)")
        case .reattachAndAwait(let epoch):
            guard UIApplication.shared.applicationState == .active else { return }
            _ = reattachInlineSurface()
            // The opening fence owns readiness. A starved snapshot here is
            // only an attachment fact; it is never a second lifecycle trigger.
            PlayerLog.log(
                "[Lifecycle] epoch=\(epoch) reattach-and-await " +
                    "phase=\(String(describing: lifecycleRecovery.phase))"
            )
        }
    }
}

extension PlayerViewModel {

    func continuationOperationRunner() -> DemandContinuationOperationRunner {
        if let demandContinuationOperationRunner {
            return demandContinuationOperationRunner
        }
        let runner = DemandContinuationOperationRunner(owner: self)
        demandContinuationOperationRunner = runner
        return runner
    }

    func submitDemandContinuationOperationEvent(_ event: DemandPresentationEvent) {
        dispatchDemandPresentation(event)
    }

    func noteDemandContinuationPrepared(fence: DemandPresentationFence) {
        markDemandForegroundStage("prepared", fence: fence)
    }

    /// Two-phase continuation dispatch. Commit the reducer's value state before
    /// invoking any collaborator so synchronous effect callbacks may safely
    /// submit their next event against the committed coordinator.
    @discardableResult
    func dispatchDemandPresentation(
        _ event: DemandPresentationEvent
    ) -> [DemandPresentationEffect] {
        let phaseBeforeReduction = lifecycleRecovery.presentationPhase
        let reduction = demandContinuationAdapter.reduce(
            event,
            coordinator: lifecycleRecovery
        )
        lifecycleRecovery = reduction.coordinator
        // Synchronize the derived handoff shape at the reducer commit edge so the source layer and the current
        // app-owned host receive the same state before any returned effect runs.
        syncDemandPresentationCornerRadius()
        // Bounded by construction: presentation events are transition-driven, not per-frame, and this fires
        // only on a genuine no-op.
        if reduction.effects.isEmpty,
           lifecycleRecovery.presentationPhase == phaseBeforeReduction,
           let eventFence = event.diagnosticFence {
            let phaseFence = lifecycleRecovery.presentationPhase.fence
            PlayerLog.log(
                "[Lifecycle] presentation event dropped \(event.diagnosticName) " +
                "event(epoch=\(eventFence.lifecycleEpoch) " +
                "render=\(eventFence.renderGeneration) " +
                "session=\(eventFence.sessionGeneration)) " +
                "phase=\(lifecycleRecovery.presentationPhase.diagnosticName)" +
                (phaseFence.map {
                    "(epoch=\($0.lifecycleEpoch) render=\($0.renderGeneration) " +
                    "session=\($0.sessionGeneration))"
                } ?? "(no fence)")
            )
        }
        if let fence = reduction.effects.compactMap(demandPresentationDebtFence).last {
            beginDemandPresentationDebt(fence)
        }
        demandContinuationAdapter.perform(reduction.effects)
        reconcileAmbientStoryboard()
        return reduction.effects
    }

    /// Keep all app-controlled presentation layers in one state transition.
    @discardableResult
    func syncDemandPresentationCornerRadius() -> CGFloat {
        guard usesDemandPresentationContinuity else { return 0 }
        let radius = PlayerPresentationCornerPolicy.cornerRadius(
            isPiPRestoringInline: lifecycleRecovery.isPiPRestoringInline
        )
        backend.setDemandPresentationCornerRadius(radius)
        renderAttachment?.setPresentationCornerRadius(radius)
        return radius
    }

    private func demandPresentationDebtFence(
        _ effect: DemandPresentationEffect
    ) -> DemandPresentationFence? {
        switch effect {
        case .warmSuspendVideoLane(let fence), .attachInline(let fence),
             .suspendVideoLaneAfterPiPStop(let fence),
             .resumeVideoLane(let fence, _), .restoreInlinePresentation(let fence),
             .flushAndPrimeRenderer(let fence), .recreateVideoDecoder(let fence):
            return fence
        case .prepareVideoLaneForForeground, .attachPausedInline,
             .resumeSuspendedAudio, .playDemandVideoLane, .requestPiPStop, .forceRetirePiP, .completeAVKitRestore,
             .abandonPiPStart, .reconcilePiPPresentation,
             .settlePresentation, .settleFailure, .pauseForContinuationPolicy:
            return nil
        }
    }

    /// Forward a retained local video fault when inline presentation returns; native PiP retains its own
    /// repair transaction.
    func escalateDemandPresentationFaultOnReturn(
        _ fence: DemandPresentationFence
    ) {
        // Not while native PiP owns presentation.
        guard usesDemandPresentationContinuity, !backend.hasObservedPiPLease else {
            return
        }
        let health = backend.demandPresentationHealth
        switch health {
        case .needsFlush, .rendererFailed, .decoderInvalid:
            PlayerLog.log(
                "[Lifecycle] inline return found \(health) — handing to the " +
                    "presentation repair ladder render=\(fence.renderGeneration)"
            )
            dispatchDemandPresentation(.rendererHealthChanged(
                fence: fence,
                health: health
            ))
        case .visible, .attachedButUnproven, .warmSuspended, .missingSurface:
            break
        }
    }

    /// Require current-generation picture proof after attachment or recovery; stale FPS cannot satisfy it.
    func beginDemandPresentationDebt(_ fence: DemandPresentationFence) {
        demandPresentationLiveness.begin(fence)
        fpsEverLive = false
        backend.invalidateFrameStats()
        stats.fps = 0
        // The arming edge, and the generation the debt will only accept a proof AT.
        PlayerLog.log(
            "[Lifecycle] presentation debt armed epoch=\(fence.lifecycleEpoch) " +
            "render=\(fence.renderGeneration) session=\(fence.sessionGeneration) " +
            "live=\(playerGeneration)"
        )
    }

    /// Capture the current owner, source, native session and presentation generations together.
    func makeDemandPresentationFence(
        epoch: UInt64,
        renderGeneration: Int? = nil,
        pipBindingGeneration: UInt64? = nil
    ) -> DemandPresentationFence? {
        guard usesDemandPresentationContinuity,
              !ownerKey.isEmpty,
              let source = decoderRecoverySource() else { return nil }
        return DemandPresentationFence(
            lifecycleEpoch: epoch,
            ownerKey: ownerKey,
            ownerLeaseGeneration: ownerLeaseGeneration,
            source: source,
            backendGeneration: backend.runtimeGeneration,
            sessionGeneration: backend.demandPresentationSessionGeneration,
            renderGeneration: renderGeneration ?? playerGeneration,
            pipBindingGeneration: pipBindingGeneration
                ?? backend.demandPiPBindingGeneration,
            userWantsPlaying: userWantsPlaying,
            playbackSuppressed: audioSessionInterrupted
        )
    }
}
