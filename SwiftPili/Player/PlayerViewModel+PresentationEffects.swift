import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Execute coordinator effects at their existing admission edges without creating a second lifecycle
    /// owner.
    func performDemandPresentationEffect(_ effect: DemandPresentationEffect) {
        switch effect {
        case let .resumeSuspendedAudio(fence, token):
            guard canAutoRevive, acceptsCurrentDemandPresentationFence(fence),
                  let demand = backend as? DemandPacedPlayerBackend,
                  demand.resumeAudioWhileVideoSuspended(token) else { return }
            updateIsPlaying(transportRunning: true)
            resumePollingTasks()
            pushNowPlayingPlayback()

        case .warmSuspendVideoLane(let fence):
            markDemandBackgroundStage("warm.begin")
            defer { markDemandBackgroundStage("warm.end") }
            completeDemandVideoSuspension(backend.warmSuspendDemandVideoLane(), fence: fence)

        case .suspendVideoLaneAfterPiPStop(let fence):
            markDemandBackgroundStage("pipStopSuspend.begin")
            defer { markDemandBackgroundStage("pipStopSuspend.end") }
            let result = (backend as? DemandPacedPlayerBackend)?
                .suspendDemandVideoLaneAfterPiPStop() ?? .unsupported
            completeDemandVideoSuspension(result, fence: fence)

        case let .prepareVideoLaneForForeground(fence, token):
            markDemandForegroundStage("prepare", fence: fence)
            continuationOperationRunner().prepareVideoLane(fence: fence, token: token)

        case .attachInline(let fence):
            guard let snapshot = reattachInlineSurface() else {
                // Keep the typed transaction pending; registerRenderAttachment() adopts the already-reserved
                // generation and replays the real snapshot.
                PlayerLog.log(
                    "[Lifecycle] inline attachment awaiting container " +
                    "render=\(fence.renderGeneration)"
                )
                return
            }
            guard playerGeneration == fence.renderGeneration else {
                dispatchDemandPresentation(.inlineAttachmentFailed(fence: fence))
                return
            }
            if snapshot.renderGeneration == fence.renderGeneration,
               snapshot.isAttached,
               snapshot.isVisible,
               snapshot.boundsUsable {
                dispatchDemandPresentation(.inlineAttached(fence: fence))
                escalateDemandPresentationFaultOnReturn(fence)
            } else {
                PlayerLog.log(
                    "[Lifecycle] inline attachment awaiting visible bounds " +
                    "render=\(fence.renderGeneration) attached=\(snapshot.isAttached ? 1 : 0) " +
                    "visible=\(snapshot.isVisible ? 1 : 0) bounds=\(snapshot.boundsUsable ? 1 : 0)"
                )
            }

        case let .attachPausedInline(fence):
            guard let snapshot = reattachInlineSurface() else {
                // The representable may be temporarily absent during the
                // restore animation. Its eventual registration feeds the same
                // inlineAttached acknowledgement through renderAttachmentDidChange.
                return
            }
            needsInlineSurfaceRebuild = false
            guard playerGeneration == fence.renderGeneration else {
                dispatchDemandPresentation(.inlineAttachmentFailed(fence: fence))
                return
            }
            guard snapshot.renderGeneration == fence.renderGeneration,
                  snapshot.isAttached,
                  snapshot.isVisible,
                  snapshot.boundsUsable else {
                // Attachment is only containment; wait for the real visible,
                // usable snapshot before the paused lane records ownership.
                return
            }
            dispatchDemandPresentation(.inlineAttached(fence: fence))

        case let .resumeVideoLane(fence, token):
            continuationOperationRunner().resumeVideoLane(fence: fence, token: token)

        case .restoreInlinePresentation(let fence):
            continuationOperationRunner().restoreInline(fence: fence)

        case .playDemandVideoLane(let fence):
            guard canAutoRevive, acceptsCurrentDemandPresentationFence(fence) else { return }
            backend.play()
            updateIsPlaying(transportRunning: true)
            resumePollingTasks()
            pushNowPlayingPlayback()

        case .abandonPiPStart:
            backend.abandonDemandPiPStart()

        case .reconcilePiPPresentation(let fence):
            // The single-flight marker for this reconcile lives in the reducer and is cleared only by a
            // completion event.
            let fenceIsCurrent = acceptsCurrentDemandPresentationFence(fence)
            let leaseIsObserved = backend.hasObservedPiPLease
            guard fenceIsCurrent, leaseIsObserved else {
                PlayerLog.log(
                    "[Lifecycle][PiP] activation reconcile refused " +
                        "fence=\(fenceIsCurrent ? 1 : 0) " +
                        "lease=\(leaseIsObserved ? 1 : 0) " +
                        "render=\(fence.renderGeneration)"
                )
                dispatchDemandPresentation(.pipPresentationReconcileFailed(
                    fence: fence,
                    failure: .staleAuthority
                ))
                return
            }
            continuationOperationRunner().reconcilePiP(fence: fence)

        case .requestPiPStop:
            // Do not rely on the later SwiftUI updateUIView pass to shape the inline host; apply the
            // already-committed restore shape synchronously before invoking the native stop.
            let appliedRadius = syncDemandPresentationCornerRadius()
            // Report only what can actually be false.
            let surface = renderAttachment?.presentationSnapshot
            PlayerLog.log(
                "[Lifecycle][PiP] native stop requested " +
                    "phase=\(lifecycleRecovery.presentationPhase.diagnosticName) " +
                    "radius=\(Int(appliedRadius.rounded())) " +
                    "attached=\(surface?.isAttached == true ? 1 : 0) " +
                    "visible=\(surface?.isVisible == true ? 1 : 0) " +
                    "bounds=\(surface?.boundsUsable == true ? 1 : 0) " +
                    "render=\(surface?.renderGeneration.map(String.init) ?? "-")"
            )
            backend.stopPiP()

        case .forceRetirePiP:
            backend.forceRetireDemandPiP()

        case let .completeAVKitRestore(token, success):
            backend.completeDemandPiPRestore(token: token, success: success)

        case .flushAndPrimeRenderer(let fence):
            let ok = backend.flushAndPrimeDemandRenderer(
                renderGeneration: fence.renderGeneration
            )
            if !ok {
                dispatchDemandPresentation(.rendererHealthChanged(
                    fence: fence,
                    health: .rendererFailed
                ))
            }

        case .recreateVideoDecoder(let fence):
            continuationOperationRunner().recreateVideoDecoder(fence: fence)

        case .settlePresentation(let proof):
            guard proof.fence.sessionGeneration
                    == backend.demandPresentationSessionGeneration,
                  proof.fence.renderGeneration == playerGeneration else { return }
            decoderSessionSuspect = false
            needsInlineSurfaceRebuild = false
            isBuffering = false
            demandPresentationLiveness.prove(proof.fence)
            markDemandForegroundStage("proof", fence: proof.fence)
            PlayerLog.log(
                "[Lifecycle] inlineVisible epoch=\(proof.fence.lifecycleEpoch) " +
                "render=\(proof.fence.renderGeneration) " +
                "pts=\(String(format: "%.3f", proof.mediaTime))"
            )

        case let .settleFailure(fence, failure):
            guard acceptsCurrentDemandPresentationFence(fence) else {
                // The reducer effect outlived its owner/session. Do not pause
                // the successor or clear/write its system-media projection.
                return
            }
            if !currentPlaybackTerminalState.isTerminal,
               let token = backend.retainAudioAfterDemandVideoFailure() {
                dispatchDemandPresentation(.videoFailureKeptAudio(
                    fence: fence, token: token, failure: failure
                ))
                isBuffering = false
                markDemandForegroundStage("video-failed-audio-retained", fence: fence)
                pushNowPlayingPlayback()
                PlayerLog.log(
                    "[Lifecycle] video-only failure=\(failure.rawValue) " +
                        "session=\(fence.sessionGeneration) audio-retained=1"
                )
                return
            }
            playbackTerminalSettlement.settle(
                fence: fence,
                failure: failure,
                ui: self,
                transport: self,
                projection: self
            )

        case .pauseForContinuationPolicy:
            needsReloadBeforeExplicitPlay = switch mode {
            case .vod:
                currentURL != nil && currentURL?.isFileURL == false
            case .offline:
                currentURL?.isFileURL == true && offlineAsset != nil
            case .live:
                false
            }
            needsInlineSurfaceRebuild = true
            playbackIntent = .pausedByUser
            suspendPlayback()
        }
    }

    private func completeDemandVideoSuspension(
        _ result: DemandVideoSuspensionResult,
        fence: DemandPresentationFence
    ) {
        switch result {
        case .suspended(let token):
            decoderSessionSuspect = false
            needsInlineSurfaceRebuild = true
            dispatchDemandPresentation(.videoLaneSuspended(fence: fence, token: token))
        case .deferred:
            // Open/seek completion revisits this same coordinator state.
            PlayerLog.log("[Lifecycle] video suspension deferred session=\(fence.sessionGeneration)")
        case .unsupported:
            dispatchDemandPresentation(.videoLaneResumeFailed(
                fence: fence, failure: .unsupportedVideoContinuity
            ))
        }
    }

    /// A ready/playing/seek-completion edge pays a deferred suspension. Native
    /// PiP owns its own transition; no timer or duplicate playback owner is needed.
    @discardableResult
    func resumeDeferredDemandVideoSuspensionIfNeeded() -> Bool {
        guard usesDemandPresentationContinuity,
              !currentPlaybackTerminalState.isTerminal,
              backend.isPlaying || !userWantsPlaying || audioSessionInterrupted,
              let fence = makeDemandPresentationFence(
                epoch: lifecycleRecovery.ensureDemandPresentationEpoch()
              ) else { return false }
        switch lifecycleRecovery.presentationPhase {
        case .warmSuspendingForAudioOnly:
            dispatchDemandPresentation(.videoLaneSuspensionMayProceed(fence: fence))
            return true
        case .warmSuspended:
            return true
        case .pipStarting, .pipActive, .pipStopping, .restoringInline:
            return false
        default:
            guard UIApplication.shared.applicationState == .background,
                  PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsBackgroundPlayback,
                  !backend.hasObservedPiPLease else { return false }
            dispatchDemandPresentation(.didEnterBackground(
                configuration: PlayerPlaybackPreferences.playbackContinuationConfiguration,
                observedPiPLease: false,
                fence: fence,
                userWantsPlaying: userWantsPlaying
            ))
            return true
        }
    }

    /// Video-specific feedback does not make healthy audio terminal. The
    /// existing explicit Retry button owns reopening the current source.
    var videoPresentationFailureMessage: String? {
        guard usesDemandPresentationContinuity,
              case .warmSuspended(let state) = lifecycleRecovery.presentationPhase,
              state.videoFailure != nil,
              acceptsCurrentDemandPresentationFence(state.fence) else { return nil }
        return String(localized: "Video could not be restored. Tap Retry to reload.")
    }

    func beginPresentationFailure(fence: DemandPresentationFence) {
        retireStreamRecovery(reason: "presentation-failure")
        markDemandForegroundStage("failed", fence: fence)
        isBuffering = false
        terminalOpenFailure = true
    }

    func pauseForPresentationFailure() {
        revokeEqualizerMaintenancePermission()
        backend.pause()
    }

    func finishPresentationFailure(message: String) {
        isPlaying = false
        error = message
    }

    func publishPresentationFailure(fence: DemandPresentationFence) {
        if let nowPlayingFence = makeNowPlayingEdgeFence(
            backendGeneration: fence.backendGeneration,
            sessionGeneration: fence.sessionGeneration,
            pipBindingGeneration: fence.pipBindingGeneration
        ) {
            _ = publishNowPlayingStateEdge(
                .terminal,
                fence: nowPlayingFence,
                rate: 0,
                isPlaying: false,
                isActionable: false
            )
        }
    }
}
