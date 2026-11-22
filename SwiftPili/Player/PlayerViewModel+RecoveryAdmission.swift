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

    /// Return only retained authority.
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

    /// Surface the typed failure and close any lifecycle or runtime ticket that will receive no later
    /// outcome.
    private func surfaceDemandRuntimeFault(_ fault: MediaRuntimeFault) {
        retireStreamRecovery(reason: "decoder-fault")
        terminalOpenFailure = true
        error = MediaRuntimeFaultPresentation.message(for: fault)
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
        // A lifecycle ticket is closed by the acknowledgement above; a NON-lifecycle ticket (runtime fault,
        // manual Retry, encode drop) owns no readiness fence and would otherwise stay open forever, coalescing
        // every later detector — including Retry — into a dead operation.
        finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        PlayerLog.log(
            "[PathA] runtime fault rejected/terminal class=\(fault.classification.rawValue) " +
                "stage=\(fault.stage.rawValue) recovery=\(fault.recoverability.rawValue) " +
                fault.diagnostics.summary
        )
    }

    /// Single admission boundary for observable source reopens. CDN host swaps retain their separate
    /// transaction and budget.
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
        // Note who it retires, so the mirror below cannot outlive it.
        let ticketBeforeAdmit = decoderRecoveryAdmission.inFlight?.token
        let decision = decoderRecoveryAdmission.admit(
            request,
            now: CACurrentMediaTime(),
            budget: &budget
        )
        // `bucket` is the resource the TRIGGER draws (`none` for lifecycle/manual/encode-drop, which are their
        // own authorities), not a claim that this decision spent it; `budget.summary` is the state after the
        // charge, so it is also what remains.
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
            // Retire the mirror with the ticket admission just closed, through the same line every other
            // terminal path logs.
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
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAdmittedRecovery(token: token, request: request)
        }
        if case .streamTransport(let cycleID, let requestID) = trigger,
           streamRecovery?.id == cycleID, streamRecovery?.requestID == requestID {
            streamRecovery?.ticket = token
            streamRecovery?.operation = operation
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
        // `canAutoRevive` stays: it is a user intent gate, not a property of the fault, and a paused or
        // interrupted session must not be reopened whatever the fault says.
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
            // A fault arriving while lifecycle recovery is still waiting joins
            // this ticket; it must not leave a second delayed reload behind.
            if case .waiting = lifecycleRecovery.phase {
                lifecycleRecoveryTask?.cancel()
                lifecycleRecovery.invalidate()
            }
        case .coalesced:
            // A runtime fault never JOINS an operation.
            surfaceDemandRuntimeFault(fault)
        case .rejected(let rejection) where rejection.endsAutomaticRecovery:
            surfaceDemandRuntimeFault(fault)
        case .rejected(let rejection):
            // The same answer as the lease mismatch above, for the same reason: a fault carrying a superseded
            // BACKEND generation is rejected `.staleFault`, and a terminal overlay raised on its behalf
            // strands the live ticket — the next Retry would coalesce into an operation nothing finishes.
            PlayerLog.log(
                "[PathA] runtime fault not admitted (\(rejection)) class=\(fault.classification.rawValue) " +
                    "owner=\(fault.ownerGeneration) lease=\(fault.ownerLeaseGeneration)"
            )
        }
    }

    /// A user retry resets the failed operation's budget and submits a real source reopen.
    func retryPlayback() {
        if mediaResetRecovery.request != nil {
            recoverMediaServicesAfterUserPlay()
            return
        }
        guard authorizeAudioPlayback() else { return }
        // Without this, the overlay's Retry re-ran the same permanently-failing load — restoring the budgets
        // each time, so the reactive ladder got a fresh set of reopens to spend against a source that will
        // never answer.
        if let unavailability, !unavailability.isRetryable {
            PlayerLog.log("[Player] retry refused — \(unavailability.rawValue) is final")
            return
        }
        if let unavailability {
            PlayerLog.log("[Player] retry accepted — \(unavailability.rawValue) is transient")
        }
        // Cleared here, not left standing: the point of a retryable refusal is
        // that the next attempt starts from no verdict at all. Leaving it set
        // would keep every Retry gate closed after the first press.
        self.unavailability = nil
        terminalOpenFailure = false
        error = nil
        isBuffering = true
        // An explicit Retry is consent to start recovery over — restore
        // the budget the failed session spent, or the reload below
        // inherits a burned CDN fallback and zero decoder reloads.
        resetRecoveryBudget()
        cdnFallbackActive = false
        // What makes a Retry tap play is the `.admitted` case below: the TAP is the authority, and it is
        // written here before the executor task runs.
        switch admitRecovery(
            trigger: .manualRetry,
            position: clampedDecoderRecoveryPosition
        ) {
        case .admitted:
            terminalOpenFailure = true
            playbackIntent = .playing
        case .coalesced:
            // A recovery is already reopening this source; Retry restored its
            // budget and must not start a second open beside it.
            break
        case .rejected:
            error = String(localized: "Playback failed. Tap Retry.")
            isBuffering = false
        }
    }
}
