import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// The session has already applied the request (and emitted its state event) by the time the deferred
    /// projection task runs; this method only updates the App's user-intent record and publishes the settled
    /// system-media snapshot.
    func handlePiPTransportEdge(
        _ edge: PlayerBackendPiPTransportEdge
    ) {
        switch edge {
        case let .transportIntent(operation, playing, backendGeneration,
                                  sessionGeneration, pipBindingGeneration,
                                  ownerLeaseGeneration):
            guard acceptsPiPTransportGenerations(
                backendGeneration: backendGeneration,
                sessionGeneration: sessionGeneration,
                pipBindingGeneration: pipBindingGeneration,
                ownerLeaseGeneration: ownerLeaseGeneration
            ) else {
                return
            }
            // This is the only user-intent mutation for direct PiP transport.
            // The session remains the one transport authority; do not call
            // `play()`/`pause()` here or a PiP request would execute twice.
            playbackIntent = playing ? .playing : .pausedByUser
            updateDemandVideoLivenessContext()
            if usesDemandPresentationContinuity {
                let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
                if let presentationFence = makeDemandPresentationFence(
                    epoch: epoch,
                    pipBindingGeneration: pipBindingGeneration
                ) {
                    dispatchDemandPresentation(.pipTransportIntent(
                        fence: presentationFence,
                        userWantsPlaying: playing
                    ))
                }
            }
            let edgeKind: NowPlayingStateEdge = playing ? .playing : .paused
            let requestedNowPlayingFence = makeNowPlayingEdgeFence(
                backendGeneration: backendGeneration,
                sessionGeneration: sessionGeneration,
                pipBindingGeneration: pipBindingGeneration
            )
            Task { @MainActor [weak self] in
                guard let self,
                      let requestedNowPlayingFence,
                      self.acceptsNowPlayingEdgeFence(requestedNowPlayingFence),
                      self.isPlaying == playing else {
                    return
                }
                _ = self.publishNowPlayingStateEdge(
                    edgeKind,
                    fence: requestedNowPlayingFence
                )
                PlayerLog.log(
                    "[NowPlaying] PiP transport settled operation=\(operation) " +
                    "playing=\(playing ? 1 : 0)"
                )
            }

        case let .seekSettled(operation, position, backendGeneration,
                               sessionGeneration, pipBindingGeneration,
                               ownerLeaseGeneration):
            guard position.isFinite, position >= 0,
                  acceptsPiPTransportGenerations(
                      backendGeneration: backendGeneration,
                      sessionGeneration: sessionGeneration,
                      pipBindingGeneration: pipBindingGeneration,
                      ownerLeaseGeneration: ownerLeaseGeneration
                  ) else { return }
            if mode.isSeekable {
                pinSettledSeekDisplay(at: position)
                refreshBufferedDisplayAfterSeek()
            }
            guard let fence = makeNowPlayingEdgeFence(
                      backendGeneration: backendGeneration,
                      sessionGeneration: sessionGeneration,
                      pipBindingGeneration: pipBindingGeneration
                  ), acceptsNowPlayingEdgeFence(fence) else {
                return
            }
            let danmakuSettlement = DanmakuPiPSeekSettlement(operation: operation, fence: fence)
            if danmakuLastPiPSeekSettlement != danmakuSettlement {
                danmakuLastPiPSeekSettlement = danmakuSettlement
                noteDanmakuSeekSettled(at: position)
            }
            // The elapsed value comes from the session's actual post-seek
            // position, not PVM's throttled display-time sample.
            _ = publishNowPlayingStateEdge(
                .seekSettled(operation: operation),
                fence: fence,
                elapsed: position
            )
        }
    }

    func handleDemandPiPNativeTransition(
        _ transition: DemandPiPNativeTransition
    ) {
        guard usesDemandPresentationContinuity else { return }
        let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
        let decision = RenderDestinationDecision(phase: lifecycleRecovery.presentationPhase)
        let transitionRenderGeneration = decision.nativePiPRenderGeneration(
            for: transition.event,
            currentRenderGeneration: playerGeneration
        )
        guard let fence = makeDemandPresentationFence(
            epoch: epoch,
            renderGeneration: transitionRenderGeneration,
            pipBindingGeneration: transition.bindingGeneration
        ) else { return }
        let event: DemandPresentationEvent
        switch transition.event {
        case .willStart:
            event = .pipWillStart(fence: fence)
        case .didStart:
            event = .pipDidStart(fence: fence)
        case .failedToStart:
            event = .pipFailedToStart(fence: fence)
        case .willStop:
            event = .pipWillStop(fence: fence)
        case .didStop:
            event = .pipDidStop(fence: fence)
        }
        dispatchDemandPresentation(event)
    }

    func handleDemandPiPRestoreRequest(token: UInt64) {
        guard usesDemandPresentationContinuity else {
            backend.completeDemandPiPRestore(token: token, success: false)
            return
        }
        let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
        guard let fence = makeDemandPresentationFence(
            epoch: epoch,
            renderGeneration: RenderDestinationDecision.reserveNextRenderGeneration(after: playerGeneration)
        ) else {
            backend.completeDemandPiPRestore(token: token, success: false)
            return
        }
        dispatchDemandPresentation(.restoreInlineRequested(
            fence: fence,
            completionToken: token
        ))
    }

    func handleDemandPresentationSample(_ sample: DemandPresentationSample) {
        noteStreamOutput(sample)
        guard usesDemandPresentationContinuity,
              sample.sessionGeneration == backend.demandPresentationSessionGeneration else {
            return
        }
        if recoveryCover != nil {
            _ = consumeRecoveryCoverPresentationSample(sample)
        } else if freezeFrameAwaitingFreshProof,
           freezeFrame != nil,
           cdnFrameCover?.accepts(sample, backend: backend, render: playerGeneration) == true {
            clearFreezeFrame()
            PlayerLog.log(
                "[CDN-switch] freeze frame released after fresh presentation proof " +
                    "session=\(sample.sessionGeneration) render=\(sample.renderGeneration)"
            )
        }
        let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
        guard let fence = makeDemandPresentationFence(
            epoch: epoch,
            renderGeneration: sample.renderGeneration
        ) else { return }
        dispatchDemandPresentation(.presentationProved(.init(
            fence: fence,
            mediaTime: sample.mediaTime,
            rendererReady: sample.rendererReady
        )))
    }

    func handleDemandPresentationFailure(
        _ failure: DemandPresentationFailure,
        renderGeneration: Int?
    ) {
        guard usesDemandPresentationContinuity else { return }
        let phaseRenderGeneration = lifecycleRecovery.presentationPhase.fence?.renderGeneration
        let failureRenderGeneration = renderGeneration ?? phaseRenderGeneration ?? playerGeneration
        guard let phaseFence = lifecycleRecovery.presentationPhase.fence,
              phaseFence.renderGeneration == failureRenderGeneration,
              phaseFence.backendGeneration == backend.runtimeGeneration,
              phaseFence.sessionGeneration == backend.demandPresentationSessionGeneration,
              phaseFence.pipBindingGeneration == backend.demandPiPBindingGeneration else {
            return
        }
        let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
        guard let fence = makeDemandPresentationFence(
            epoch: epoch,
            renderGeneration: failureRenderGeneration
        ) else { return }
        // This is the existing typed presentation-failure path. It settles the
        // current coordinator transaction and Retry state; it never enters
        // transport/runtime recovery or reopens a source.
        dispatchDemandPresentation(.videoLaneResumeFailed(
            fence: fence,
            failure: failure
        ))
    }
}
