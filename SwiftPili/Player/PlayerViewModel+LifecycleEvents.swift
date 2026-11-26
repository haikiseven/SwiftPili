import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func handleWillEnterForeground() {
        if streamRecoveryOwnsWork { return }
        synchronizeTerminalAdmissionFromBackend()
        guard !standDownLifecycleForTerminalPlayback() else { return }
        guard usesDemandPresentationContinuity else { return }
        demandBackgroundStageTape = nil
        let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
        guard let fence = makeDemandPresentationFence(epoch: epoch) else {
            discardDemandForegroundStageTape()
            return
        }
        markDemandForegroundStage("willEnter", startsTransition: true, fence: fence)
        dispatchDemandPresentation(.foregroundTransitionBegan(fence: fence))
    }

    func handleDidEnterBackground() {
        protectPendingBackgroundPlayback()
        reconcileAmbientStoryboard(allowWork: false)
        deferStreamRecoveryForBackground()
        noteDanmakuApplicationActivityChanged(isActive: false)
        synchronizeTerminalAdmissionFromBackend()
        snapshotNowPlayingForBackground()
        if mode == .vod {
            reportHistoryNow()
        } else if mode == .offline {
            persistOfflineProgressNow()
        }
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
            backend.noteDemandPiPEnvironmentWillResignActive()
            lifecycleRecoveryTask?.cancel()
            let preservesCurrentProof = lifecycleRecovery
                .preservesPresentationLivenessAcrossEnvironmentChange
            let epoch = lifecycleRecovery.beginDemandPresentationEpoch()
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
            needsInlineSurfaceRebuild = true
            if backend.isPiPActive || backend.hasObservedPiPLease {
                backend.stopPiP()
            }
            playbackIntent = .pausedByUser
            suspendPlayback()
            PlayerLog.log(
                "[Player] background playback disabled — paused; explicitPlayReload=" +
                "\(needsReloadBeforeExplicitPlay ? 1 : 0)"
            )
            return
        }
        let pip = backend.isPiPActive
        decoderSessionSuspect = true
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

    func synchronizeForegroundEnvironment() {
        backgroundExecution.end(reason: "foreground")
        handleNativeAudioOutputChange()
        let isActive = UIApplication.shared.applicationState == .active
        if isActive {
            lifecycleRecovery.presentationApplicationPhase = .active
        }
        synchronizeTerminalAdmissionFromBackend()
        _ = standDownLifecycleForTerminalPlayback()
        noteDanmakuApplicationActivityChanged(isActive: isActive)
    }

    func scheduleForegroundLivenessCheck() {
        guard !currentPlaybackTerminalState.isTerminal else { return }
        if usesDemandPresentationContinuity {
            let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
            let destination = lifecycleRecovery.foregroundPresentationDestination
            let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
            let targetRenderGeneration = decision.foregroundRenderGeneration(
                for: destination,
                currentRenderGeneration: playerGeneration
            )
            guard let fence = makeDemandPresentationFence(
                epoch: epoch,
                renderGeneration: targetRenderGeneration
            ) else {
                discardDemandForegroundStageTape()
                return
            }
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
                dispatchDemandPresentation(.pipPresentationNeedsReconcile(
                    fence: fence
                ))
            }
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
        syncDemandPresentationCornerRadius()
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

    @discardableResult
    func syncDemandPresentationCornerRadius() -> CGFloat {
        guard usesDemandPresentationContinuity else { return 0 }
        let baseRadius = PlayerPresentationCornerPolicy.cornerRadius(
            isPiPRestoringInline: lifecycleRecovery.isPiPRestoringInline
        )
        let isMiniSurface = renderAttachmentSurfaceLease?.role == .miniPlayer
            || activeSurfaceLease?.role == .miniPlayer
        let radius = isMiniSurface
            ? max(baseRadius, InAppMiniPlayerLayoutPolicy.cornerRadius)
            : baseRadius
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

    func escalateDemandPresentationFaultOnReturn(
        _ fence: DemandPresentationFence
    ) {
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

    func beginDemandPresentationDebt(_ fence: DemandPresentationFence) {
        demandPresentationLiveness.begin(fence)
        fpsEverLive = false
        backend.invalidateFrameStats()
        stats.fps = 0
        PlayerLog.log(
            "[Lifecycle] presentation debt armed epoch=\(fence.lifecycleEpoch) " +
            "render=\(fence.renderGeneration) session=\(fence.sessionGeneration) " +
            "live=\(playerGeneration)"
        )
    }

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
