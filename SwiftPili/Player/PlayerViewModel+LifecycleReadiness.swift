import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    @discardableResult
    func beginLifecycleOpening(
        trigger: LifecycleRecoveryCoordinator.Trigger,
        epoch: UInt64,
        token: UInt64
    ) -> Bool {
        guard !ownerKey.isEmpty, let retainedSource = decoderRecoverySource() else {
            return false
        }
        let source = decoderRecoveryAdmission.inFlight?.request.context.source ?? retainedSource
        let fence = LifecycleReadinessFence(
            lifecycleEpoch: epoch,
            initialTrigger: trigger,
            admissionToken: token,
            ownerKey: ownerKey,
            ownerLeaseGeneration: ownerLeaseGeneration,
            source: source,
            loadGeneration: loadGeneration,
            backendGeneration: backend.runtimeGeneration
        )
        guard lifecycleRecovery.beginOpening(fence) else { return false }
        pendingLifecycleAdmission = PendingLifecycleAdmission(
            epoch: epoch,
            trigger: trigger,
            token: token,
            provisionalFence: fence
        )
        lifecycleReadinessFence = nil
        PlayerLog.log(
            "[Lifecycle] epoch=\(epoch) opening token=\(token) " +
                "loadGen=\(loadGeneration) backendGen=\(backend.runtimeGeneration)"
        )
        return true
    }

    func submitLifecycleOpeningIfNeeded() {
        if let pending = pendingLifecycleAdmission {
            guard ownerKey == pending.provisionalFence.ownerKey,
                  ownerLeaseGeneration == pending.provisionalFence.ownerLeaseGeneration,
                  decoderRecoverySource() != nil else {
                return
            }

            guard let ticket = decoderRecoveryAdmission.inFlight,
                  ticket.token == pending.token else {
                return
            }
            let source = ticket.request.context.source
            let fence = LifecycleReadinessFence(
                lifecycleEpoch: pending.epoch,
                initialTrigger: pending.trigger,
                admissionToken: pending.token,
                ownerKey: ownerKey,
                ownerLeaseGeneration: ownerLeaseGeneration,
                source: source,
                loadGeneration: loadGeneration,
                backendGeneration: backend.runtimeGeneration
            )
            guard fence.source.hasSameAuthority(as: pending.provisionalFence.source),
                  !terminalOpenFailure,
                  lifecycleRecovery.replaceOpeningFence(fence) else {
                return
            }
            lifecycleReadinessFence = fence
            pendingLifecycleAdmission = nil
            PlayerLog.log(
                "[Lifecycle] epoch=\(fence.lifecycleEpoch) load submitted " +
                    "token=\(fence.admissionToken) loadGen=\(fence.loadGeneration) " +
                    "backendGen=\(fence.backendGeneration)"
            )
            return
        }

        guard let current = lifecycleReadinessFence,
              ownerKey == current.ownerKey,
              ownerLeaseGeneration == current.ownerLeaseGeneration,
              decoderRecoverySource() != nil,
              let ticket = decoderRecoveryAdmission.inFlight,
              ticket.token == current.admissionToken else {
            return
        }
        let source = ticket.request.context.source
        let successor = LifecycleReadinessFence(
            lifecycleEpoch: current.lifecycleEpoch,
            initialTrigger: current.initialTrigger,
            admissionToken: current.admissionToken,
            ownerKey: current.ownerKey,
            ownerLeaseGeneration: current.ownerLeaseGeneration,
            source: source,
            loadGeneration: loadGeneration,
            backendGeneration: backend.runtimeGeneration
        )
        guard successor.source.hasSameAuthority(as: current.source),
              lifecycleRecovery.replaceOpeningFence(successor) else {
            return
        }
        lifecycleReadinessFence = successor
        PlayerLog.log(
            "[Lifecycle] epoch=\(successor.lifecycleEpoch) successor submitted " +
                "token=\(successor.admissionToken) loadGen=\(successor.loadGeneration) " +
                "backendGen=\(successor.backendGeneration)"
        )
    }

    func invalidateLifecycleReadiness() {
        pendingLifecycleAdmission = nil
        lifecycleReadinessFence = nil
    }

    func relinquishLifecycleAuthority(takenOverBy takeover: String, reason: String) {
        var releasedLifecycle = false
        var releasedToken: UInt64?
        if let epoch = pendingLifecycleAdmission?.epoch
            ?? lifecycleReadinessFence?.lifecycleEpoch,
           let token = pendingLifecycleAdmission?.token
            ?? lifecycleReadinessFence?.admissionToken {
            releasedLifecycle = true
            releasedToken = token
            if let ticket = decoderRecoveryAdmission.inFlight, ticket.token == token {
                _ = decoderRecoveryAdmission.finishAuthoritatively(
                    token: token,
                    matchingAuthority: ticket.request.context,
                    now: CACurrentMediaTime(),
                    outcome: .terminalLoaderFailure
                )
            }
            nonLifecycleRecoveryTicket = nil
            let stage = pendingLifecycleAdmission != nil ? "provisional" : "submitted"
            let trigger = pendingLifecycleAdmission?.trigger
                ?? lifecycleReadinessFence?.initialTrigger
            invalidateLifecycleReadiness()
            lifecycleRecovery.abandon(epoch: epoch)
            PlayerLog.log(
                "[Lifecycle] epoch=\(epoch) abandoned — \(takeover) (\(reason)) " +
                    "took over transport; token=\(token) released " +
                    "stage=\(stage) trigger=\(trigger.map { "\($0)" } ?? "-") " +
                    "error=\(error == nil ? 0 : 1) buffering=\(isBuffering ? 1 : 0)"
            )
        }
        if let ticket = nonLifecycleRecoveryTicket ?? decoderRecoveryAdmission.inFlight,
           !ticket.request.trigger.isLifecycle {
            let ticketToken = ticket.token
            let finished = decoderRecoveryAdmission.finishAuthoritatively(
                token: ticketToken,
                matchingAuthority: ticket.request.context,
                now: CACurrentMediaTime(),
                outcome: .terminalLoaderFailure
            )
            nonLifecycleRecoveryTicket = nil
            clearCoalescedWatchdogTracking(for: ticketToken)
            if finished, !releasedLifecycle {
                PlayerLog.log(
                    "[Recovery] boundary=1 ticket=\(ticketToken) released — " +
                        "\(takeover) (\(reason)) took over transport " +
                        "trigger=\(String(describing: ticket.request.trigger)) " +
                        "\(budget.summary)"
                )
            }
        } else if let releasedToken {
            clearCoalescedWatchdogTracking(for: releasedToken)
        }
    }

    func clearCoalescedWatchdogTracking(for token: UInt64? = nil) {
        if let token {
            if coalescedRecoveryWatchdog?.token == token {
                coalescedRecoveryWatchdog = nil
            }
        } else {
            coalescedRecoveryWatchdog = nil
        }
    }

    func acknowledgeLifecycleReadiness(
        _ outcome: LifecycleReadinessOutcome,
        evidence: LifecycleReadinessEvidence = .backendCallback
    ) {
        let fence: LifecycleReadinessFence
        let isProvisional: Bool
        if let current = lifecycleReadinessFence {
            fence = current
            isProvisional = false
        } else if let pending = pendingLifecycleAdmission {
            fence = pending.provisionalFence
            isProvisional = true
        } else {
            return
        }

        guard ownerKey == fence.ownerKey,
              ownerLeaseGeneration == fence.ownerLeaseGeneration,
              let currentSource = decoderRecoverySource(),
              currentSource.hasSameAuthority(as: fence.source) else {
            PlayerLog.log("[Lifecycle] stale readiness ignored owner/source")
            return
        }
        if isProvisional {
            guard evidence == .loaderReturn else {
                PlayerLog.log("[Lifecycle] provisional readiness callback ignored")
                return
            }
        } else {
            guard fence.loadGeneration == loadGeneration,
                  fence.backendGeneration == backend.runtimeGeneration else {
                PlayerLog.log(
                    "[Lifecycle] stale readiness ignored generation " +
                        "load=\(fence.loadGeneration)/\(loadGeneration) " +
                        "backend=\(fence.backendGeneration)/\(backend.runtimeGeneration)"
                )
                return
            }
        }

        guard let ticket = decoderRecoveryAdmission.inFlight,
              ticket.token == fence.admissionToken else {
            PlayerLog.log("[Lifecycle] stale readiness ignored ticket=\(fence.admissionToken)")
            return
        }
        let currentTicketContext = ticket.request.context
        guard currentTicketContext.owner == fence.ownerKey,
              currentTicketContext.ownerLeaseGeneration == fence.ownerLeaseGeneration,
              currentTicketContext.source.hasSameAuthority(as: fence.source) else {
            PlayerLog.log("[Lifecycle] stale readiness ignored ticket authority")
            return
        }

        let acknowledgement = lifecycleRecovery.reloadFinished(
            fence: fence,
            outcome: outcome,
            appIsActive: UIApplication.shared.applicationState == .active
        )
        switch acknowledgement {
        case .ignored:
            return
        case .transportReady(let action):
            _ = decoderRecoveryAdmission.finishAuthoritatively(
                token: fence.admissionToken,
                matchingAuthority: currentTicketContext,
                now: CACurrentMediaTime(),
                outcome: .backendReady
            )
            lifecycleReadinessFence = nil
            pendingLifecycleAdmission = nil
            PlayerLog.log(
                "[Lifecycle] epoch=\(fence.lifecycleEpoch) transport ready " +
                    "token=\(fence.admissionToken)"
            )
            consumeLifecycleRecovery(action)
        case .terminalFailure(let action):
            let completion: DecoderRecoveryCompletion
            switch evidence {
            case .backendCallback:
                completion = .backendError
            case .loaderReturn:
                completion = .terminalLoaderFailure
            }
            _ = decoderRecoveryAdmission.finishAuthoritatively(
                token: fence.admissionToken,
                matchingAuthority: currentTicketContext,
                now: CACurrentMediaTime(),
                outcome: completion
            )
            lifecycleReadinessFence = nil
            pendingLifecycleAdmission = nil
            terminalOpenFailure = true
            isBuffering = false
            updateIsPlaying(transportRunning: false)
            if error == nil {
                error = String(localized: "Playback failed. Tap Retry.")
            }
            pushNowPlayingPlayback()
            PlayerLog.log(
                "[Lifecycle] epoch=\(fence.lifecycleEpoch) terminal failure " +
                    "token=\(fence.admissionToken)"
            )
            consumeLifecycleRecovery(action)
        }
    }

    func rememberNonLifecycleRecoveryTicket(
        token: UInt64,
        authority: DecoderRecoveryAdmission.Context
    ) {
        guard let ticket = decoderRecoveryAdmission.authoritativeTicket(
            for: token,
            matchingAuthority: authority
        ), !ticket.request.trigger.isLifecycle else {
            return
        }
        nonLifecycleRecoveryTicket = ticket
    }

    func finishNonLifecycleRecoveryIfNeeded(
        outcome: DecoderRecoveryCompletion
    ) {
        guard pendingLifecycleAdmission == nil,
              lifecycleReadinessFence == nil,
              let pending = nonLifecycleRecoveryTicket,
              let ticket = decoderRecoveryAdmission.authoritativeTicket(
                  for: pending.token,
                  matchingAuthority: pending.request.context
              ),
              !ticket.request.trigger.isLifecycle else {
            return
        }
        let finished = decoderRecoveryAdmission.finishAuthoritatively(
            token: pending.token,
            matchingAuthority: pending.request.context,
            now: CACurrentMediaTime(),
            outcome: outcome
        )
        if finished {
            nonLifecycleRecoveryTicket = nil
            clearCoalescedWatchdogTracking(for: pending.token)
            PlayerLog.log(
                "[Recovery] boundary=1 ticket=\(pending.token) closed " +
                    "outcome=\(outcome) trigger=\(String(describing: pending.request.trigger)) " +
                    "\(budget.summary)"
            )
        }
    }

    func finishNonLifecycleRecoveryAfterLoaderIfNeeded(
        token: UInt64,
        authority: DecoderRecoveryAdmission.Context,
        outcome: DecoderRecoveryCompletion
    ) {
        guard outcome == .terminalLoaderFailure,
              pendingLifecycleAdmission == nil,
              lifecycleReadinessFence == nil,
              nonLifecycleRecoveryTicket?.token == token,
              let ticket = decoderRecoveryAdmission.authoritativeTicket(
                  for: token,
                  matchingAuthority: authority
              ),
              !ticket.request.trigger.isLifecycle else {
            return
        }
        if decoderRecoveryAdmission.finishAuthoritatively(
            token: token,
            matchingAuthority: authority,
            now: CACurrentMediaTime(),
            outcome: outcome
        ) {
            nonLifecycleRecoveryTicket = nil
            PlayerLog.log(
                "[Recovery] boundary=1 ticket=\(token) closed " +
                    "outcome=\(outcome) evidence=loaderReturn \(budget.summary)"
            )
        }
    }

    func failLifecycleOpeningIfNeeded() {
        guard lifecycleReadinessFence == nil, pendingLifecycleAdmission != nil else { return }
        acknowledgeLifecycleReadiness(
            .terminalFailure,
            evidence: .loaderReturn
        )
    }
}
