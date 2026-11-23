import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func decoderRecoverySource() -> DecoderRecoveryAdmission.Source? {
        switch mode {
        case .vod:
            guard let aid = currentAid, let cid = currentCid else { return nil }
            let source = switch currentSource {
            case .ugc: "ugc"
            case .pgc(let epID): "pgc-\(epID)"
            }
            return .vod(
                aid: aid,
                cid: cid,
                quality: currentQuality,
                source: source
            )
        case .live:
            guard let roomID = currentRoomID else { return nil }
            return .live(roomID: roomID, quality: currentLiveQuality)
        case .offline:
            guard let asset = offlineAsset else { return nil }
            return .offline(asset)
        }
    }

    func decoderRecoveryContext() -> DecoderRecoveryAdmission.Context? {
        guard !ownerKey.isEmpty,
              backend.runtimeGeneration > 0,
              let source = decoderRecoverySource() else { return nil }
        return DecoderRecoveryAdmission.Context(
            owner: ownerKey,
            ownerLeaseGeneration: ownerLeaseGeneration,
            backendGeneration: backend.runtimeGeneration,
            source: source
        )
    }

    private func surfaceDemandRuntimeFault(_ fault: MediaRuntimeFault) {
        settleTerminalFailure(TerminalFailurePayload(
            message: MediaRuntimeFaultPresentation.message(for: fault),
            retireStreamRecoveryReason: "decoder-fault",
            logMessage: "[PathA] runtime fault rejected/terminal class=\(fault.classification.rawValue) "
                + "stage=\(fault.stage.rawValue) recovery=\(fault.recoverability.rawValue) "
                + fault.diagnostics.summary
        ))
    }

    @discardableResult
    func admitRecovery(
        trigger: DecoderRecoveryAdmission.Trigger,
        position: TimeInterval,
        fault: MediaRuntimeFault? = nil
    ) -> DecoderRecoveryAdmission.Decision {
        guard let context = decoderRecoveryContext() else {
            PlayerLog.log(
                "[Recovery] \(String(describing: trigger)) rejected — no retained authority"
            )
            return .rejected(.noAuthority)
        }
        let request = DecoderRecoveryAdmission.Request(
            context: context,
            trigger: trigger,
            position: position,
            fault: fault
        )
        let ticketBeforeAdmit = decoderRecoveryAdmission.inFlight?.token
        let decision = decoderRecoveryAdmission.admit(
            request,
            now: CACurrentMediaTime(),
            budget: &budget
        )
        PlayerLog.log(
            "[Recovery] boundary=1 \(String(describing: trigger)) → \(String(describing: decision)) " +
                "at=\(String(format: "%.1f", position)) " +
                "bucket=\(trigger.spendsAutomaticRuntimeBudget ? "decoderReload" : "none") " +
                "\(budget.summary)"
        )
        switch decision {
        case .admitted(let token), .coalesced(let token):
            rememberNonLifecycleRecoveryTicket(token: token, authority: context)
        case .rejected(.nonRecoverableFault):
            if let pending = nonLifecycleRecoveryTicket, pending.token == ticketBeforeAdmit {
                nonLifecycleRecoveryTicket = nil
                PlayerLog.log(
                    "[Recovery] boundary=1 ticket=\(pending.token) closed " +
                        "outcome=\(DecoderRecoveryCompletion.backendError) " +
                        "trigger=\(String(describing: pending.request.trigger)) \(budget.summary)"
                )
            }
            return decision
        case .rejected:
            return decision
        }
        guard case .admitted(let token) = decision, !trigger.isLifecycle else {
            return decision
        }
        clearCoalescedWatchdogTracking()
        let isStreamTransport: Bool
        if case .streamTransport = trigger {
            isStreamTransport = true
        } else {
            isStreamTransport = false
        }
        if !isStreamTransport {
            nonLifecycleRecoveryTask?.task.cancel()
        }
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAdmittedRecovery(token: token, request: request)
            if self.nonLifecycleRecoveryTask?.token == token {
                self.nonLifecycleRecoveryTask = nil
            }
        }
        if case .streamTransport(let cycleID, let requestID) = trigger,
           streamRecovery?.id == cycleID, streamRecovery?.requestID == requestID {
            streamRecovery?.ticket = token
            streamRecovery?.operation = operation
        } else {
            nonLifecycleRecoveryTask = (token, operation)
        }
        return decision
    }

    func handleDemandRuntimeFault(_ fault: MediaRuntimeFault) {
        guard backendKind == .demandPaced else { return }
        guard !currentPlaybackTerminalState.isTerminal else {
            PlayerLog.log("[PathA] runtime fault ignored after terminal playback state")
            return
        }
        guard fault.ownerLeaseGeneration == 0
                || fault.ownerLeaseGeneration == ownerLeaseGeneration else {
            PlayerLog.log(
                "[PathA] stale runtime fault ignored owner lease=" +
                    "\(fault.ownerLeaseGeneration) current=\(ownerLeaseGeneration)"
            )
            return
        }
        if usesDemandPresentationContinuity,
           (fault.subsystem == .videoDecoder || fault.subsystem == .videoRenderer) {
            let inputs = DemandContinuationInputs(phase: lifecycleRecovery.presentationPhase)
            if inputs.ownsLocalVideoFaultDebt {
                let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
                if let fence = makeDemandPresentationFence(epoch: epoch) {
                    dispatchDemandPresentation(.runtimeVideoFault(
                        fence: fence,
                        decoderInvalid: fault.subsystem == .videoDecoder
                    ))
                    return
                }
            }
        }
        guard canAutoRevive else {
            surfaceDemandRuntimeFault(fault)
            return
        }
        let position = clampedDecoderRecoveryPosition
        logDemandSeekTrace(
            phase: "recovery",
            target: position,
            ready: backend.isReadyToPlay
        )
        switch admitRecovery(trigger: .runtimeFault, position: position, fault: fault) {
        case .admitted:
            terminalOpenFailure = true
            isBuffering = true
            if case .waiting = lifecycleRecovery.phase {
                lifecycleRecoveryTask?.cancel()
                lifecycleRecovery.invalidate()
            }
        case .coalesced:
            isBuffering = true
            PlayerLog.log(
                "[PathA] runtime fault coalesced into in-flight recovery " +
                    "class=\(fault.classification.rawValue)"
            )
        case .rejected(let rejection) where rejection.endsAutomaticRecovery:
            surfaceDemandRuntimeFault(fault)
        case .rejected(let rejection):
            PlayerLog.log(
                "[PathA] runtime fault not admitted (\(rejection)) class=\(fault.classification.rawValue) " +
                    "owner=\(fault.ownerGeneration) lease=\(fault.ownerLeaseGeneration)"
            )
        }
    }

    func retryPlayback() {
        if mediaResetRecovery.request != nil {
            recoverMediaServicesAfterUserPlay()
            return
        }
        guard authorizeAudioPlayback() else { return }
        if let unavailability, !unavailability.isRetryable {
            PlayerLog.log("[Player] retry refused — \(unavailability.rawValue) is final")
            return
        }
        if let unavailability {
            PlayerLog.log("[Player] retry accepted — \(unavailability.rawValue) is transient")
        }
        self.unavailability = nil
        playbackTerminalState = .active
        terminalOpenFailure = false
        error = nil
        isBuffering = true
        resetRecoveryBudget()
        cdnFallbackActive = false
        switch admitRecovery(
            trigger: .manualRetry,
            position: clampedDecoderRecoveryPosition
        ) {
        case .admitted:
            terminalOpenFailure = true
            playbackIntent = .playing
        case .coalesced:
            break
        case .rejected:
            settleTerminalFailure(TerminalFailurePayload(
                message: String(localized: "Playback failed. Tap Retry.")
            ))
        }
    }
}
