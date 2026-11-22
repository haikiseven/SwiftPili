import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    private func ownsStreamRecovery(_ cycle: StreamRecoveryCycle) -> Bool {
        streamRecovery === cycle && cycle.budgetID == recoveryBudgetIdentity
            && isCurrentOwner(cycle.owner) && mode.usesOnlineVODServices
            && currentAid == cycle.aid && currentCid == cycle.cid && currentSource == cycle.source
            && loadGeneration == cycle.loadGeneration && (cycle.requestAdmission?() ?? true)
    }

    func acceptsStreamRequest(_ id: UUID) -> Bool {
        guard let cycle = streamRecovery else { return false }
        return ownsStreamRecovery(cycle) && cycle.requestID == id
            && cycle.recovering && !cycle.suspended && streamRecoveryMayRun && !Task.isCancelled
    }

    func issueStreamRetry(_ id: UUID) -> Bool {
        guard acceptsStreamRequest(id), let cycle = streamRecovery else { return false }
        if cycle.issued { return true }
        guard budget.spendStreamRetry(at: CACurrentMediaTime()) else {
            finishStreamRecovery(cycle, reason: "allowance")
            return false
        }
        cycle.issued = true
        cycle.attemptSerial += 1
        PlayerLog.log(
            "[StreamRetry] cycle=\(cycle.id) attempt=\(cycle.attemptSerial) " +
                "issued target=\(cycle.target) \(budget.summary)"
        )
        return true
    }

    @discardableResult
    func handleStreamTransportFailure(
        _ failure: StreamTransportFailure, quality: Int? = nil, loadGeneration failedLoad: Int? = nil
    ) -> Bool {
        guard mode.usesOnlineVODServices, failure.isEligible,
              failedLoad.map({ $0 == loadGeneration }) ?? true,
              let owner = currentOwnerLease, let aid = currentAid, let cid = currentCid,
              mediaResetRecovery.request == nil else { return false }
        if let generation = failure.backendGeneration {
            guard generation == backend.runtimeGeneration,
                  failure.sessionGeneration == backend.demandPresentationSessionGeneration else { return true }
        }
        let cycle: StreamRecoveryCycle
        if let existing = streamRecovery {
            guard ownsStreamRecovery(existing) else {
                retireStreamRecovery(reason: "superseded")
                return true
            }
            if existing.recovering, !existing.issued { return true }
            cycle = existing
            if !cycle.recovering {
                cycle.target = pendingSeekTarget ?? cycle.lastProgress ?? cycle.target
            }
        } else {
            let position = recoveryPosition
            let target = position.isFinite ? max(0, duration > 0 ? min(position, duration) : position) : 0
            cycle = StreamRecoveryCycle(owner: owner, budgetID: recoveryBudgetIdentity,
                aid: aid, cid: cid, source: currentSource, quality: quality ?? currentQuality,
                audio: audioTierOverride, requestAdmission: streamSourceRequestAdmission,
                loadGeneration: loadGeneration, target: target, failure: failure)
            if currentURL != nil, failure.backendGeneration != nil {
                cycle.installed = .init(backend: ObjectIdentifier(backend as AnyObject),
                    generation: backend.runtimeGeneration)
            }
            streamRecovery = cycle
        }
        cycle.failure = failure
        cycle.recovering = true
        cycle.outputSession = nil
        cycle.lastProgress = nil
        budget.beginStreamRecovery(at: CACurrentMediaTime())
        acknowledgeLifecycleReadiness(.terminalFailure,
            evidence: failedLoad != nil ? .loaderReturn : .backendCallback)
        finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        cycle.ticket = nil
        cycle.operation?.cancel()
        cycle.operation = nil
        cycle.requestID = nil
        cycle.issued = false
        retireCDNSwitch()
        if cycle.installed != nil { backend.pause() }
        error = nil
        unavailability = nil
        terminalOpenFailure = false
        isBuffering = true
        PlayerLog.log(
            "[StreamRetry] cycle=\(cycle.id) failure=\(failure.diagnostic) " +
                "remaining=\(budget.streamRemaining(at: CACurrentMediaTime()))"
        )
        scheduleStreamRecovery(cycle)
        return true
    }

    private func scheduleStreamRecovery(_ cycle: StreamRecoveryCycle) {
        guard ownsStreamRecovery(cycle), cycle.recovering,
              cycle.operation == nil, cycle.requestID == nil else { return }
        guard streamRecoveryMayRun else {
            cycle.suspended = true
            return
        }
        cycle.suspended = false
        beginBackgroundPlaybackRestoration(reason: "stream-retry")
        let remaining = budget.streamRemaining(at: CACurrentMediaTime())
        guard remaining > 0, budget.streamRetries < RecoveryBudget.maxStreamRetries else {
            finishStreamRecovery(cycle, reason: remaining <= 0 ? "deadline" : "count")
            return
        }
        armStreamDeadline(cycle)
        let delay = budget.streamRetryDelay(jitter: Double.random(in: 0.8...1.2), retryAfter: cycle.failure.retryAfter)
        PlayerLog.log(
            "[StreamRetry] cycle=\(cycle.id) next=\(budget.streamRetries + 1) " +
                "delay=\(delay) remaining=\(remaining) target=\(cycle.target)"
        )
        guard delay < remaining else { return }
        let requestID = UUID()
        cycle.operation = Task { @MainActor [weak self, weak cycle] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let cycle, self.ownsStreamRecovery(cycle), !Task.isCancelled else { return }
            cycle.operation = nil
            self.beginStreamRetry(cycle, requestID: requestID)
        }
    }

    private func finishStreamLoaderReturn(_ cycle: StreamRecoveryCycle, requestID: UUID) {
        guard ownsStreamRecovery(cycle), cycle.requestID == requestID else { return }
        cycle.operation = nil
        if cycle.installed == nil, !cycle.suspended {
            finishStreamRecovery(cycle, reason: "submission")
        }
    }

    private func armStreamDeadline(_ cycle: StreamRecoveryCycle) {
        guard cycle.deadline == nil else { return }
        let remaining = budget.streamRemaining(at: CACurrentMediaTime())
        cycle.deadline = Task { @MainActor [weak self, weak cycle] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, let cycle, self.ownsStreamRecovery(cycle), cycle.recovering else { return }
            cycle.deadline = nil
            guard self.streamRecoveryMayRun else {
                self.suspendStreamRecovery()
                return
            }
            self.finishStreamRecovery(cycle, reason: "deadline")
        }
    }

    private func cancelStreamOperation(_ cycle: StreamRecoveryCycle) {
        let installed = cycle.installed
        let wasIssued = cycle.issued
        cycle.requestID = nil
        cycle.issued = false
        cycle.operation?.cancel()
        cycle.operation = nil
        cycle.deadline?.cancel()
        cycle.deadline = nil
        if cycle.ticket == nonLifecycleRecoveryTicket?.token {
            finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        }
        cycle.ticket = nil
        guard ownsStreamRecovery(cycle), wasIssued || installed != nil else { return }
        loadGeneration += 1
        cycle.loadGeneration = loadGeneration
        if let installed, installed.backend == ObjectIdentifier(backend as AnyObject),
           installed.generation == backend.runtimeGeneration {
            backend.stop()
        }
        cycle.installed = nil
        cycle.outputSession = nil
    }

    func suspendStreamRecovery() {
        guard let cycle = streamRecovery, ownsStreamRecovery(cycle) else { return }
        budget.interruptStreamStability()
        guard cycle.recovering else { return }
        cycle.suspended = true
        cancelStreamOperation(cycle)
        isBuffering = false
        PlayerLog.log(
            "[StreamRetry] cycle=\(cycle.id) suspended " +
                "remaining=\(budget.streamRemaining(at: CACurrentMediaTime()))"
        )
    }

    func resumeStreamRecoveryIfNeeded() -> Bool {
        guard let cycle = streamRecovery, cycle.recovering else { return false }
        guard ownsStreamRecovery(cycle) else {
            retireStreamRecovery(reason: "superseded")
            return false
        }
        error = nil
        terminalOpenFailure = false
        isBuffering = true
        scheduleStreamRecovery(cycle)
        return true
    }

    func retireStreamRecovery(reason: String) {
        guard let cycle = streamRecovery else { return }
        if cycle.recovering { cancelStreamOperation(cycle) }
        cycle.operation?.cancel()
        cycle.deadline?.cancel()
        streamRecovery = nil
        if cycle.budgetID == recoveryBudgetIdentity { budget.clearStreamRecovery() }
        PlayerLog.log("[StreamRetry] cycle=\(cycle.id) retired=\(reason)")
    }

    private func finishStreamRecovery(_ cycle: StreamRecoveryCycle, reason: String) {
        guard ownsStreamRecovery(cycle) else { return }
        let message = cycle.failure.localizedDescription
        backgroundExecution.end(reason: "stream-retry-\(reason)")
        cancelStreamOperation(cycle)
        streamRecovery = nil
        resumeAtTime = cycle.target
        armDurableResumeTarget(cycle.target, source: "stream-retry-final")
        terminalOpenFailure = true
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        if cycle.failure.stage == .probe {
            markTransientStreamUnreachable()
        } else if cycle.failure.stage == .resolver {
            error = message
        } else {
            error = PlaybackFailureMessage.text(for: MediaEngineError.transportFailed(cycle.failure))
        }
        pushNowPlayingPlayback()
        PlayerLog.log(
            "[StreamRetry] cycle=\(cycle.id) final=\(reason) " +
                "attempts=\(budget.streamRetries) target=\(cycle.target)"
        )
        budget.clearStreamRecovery()
    }

    func noteStreamReady() {
        guard let cycle = streamRecovery, ownsStreamRecovery(cycle),
              var installed = cycle.installed,
              installed.backend == ObjectIdentifier(backend as AnyObject),
              installed.generation == backend.runtimeGeneration else { return }
        installed.readySession = backend.demandPresentationSessionGeneration
        cycle.installed = installed
        cycle.lastProgress = nil
    }

    func noteStreamOutput(_ sample: DemandPresentationSample) {
        guard let cycle = streamRecovery, ownsStreamRecovery(cycle),
              let installed = cycle.installed, installed.readySession != nil,
              installed.backend == ObjectIdentifier(backend as AnyObject),
              installed.generation == backend.runtimeGeneration,
              sample.sessionGeneration == backend.demandPresentationSessionGeneration,
              sample.renderGeneration == playerGeneration, sample.rendererReady else { return }
        cycle.outputSession = sample.sessionGeneration
    }

    func noteStreamProgress(_ position: TimeInterval, at now: TimeInterval) {
        guard let cycle = streamRecovery, ownsStreamRecovery(cycle),
              let installed = cycle.installed, installed.readySession != nil,
              installed.backend == ObjectIdentifier(backend as AnyObject),
              installed.generation == backend.runtimeGeneration else { return }
        guard playbackIntent == .playing, !audioSessionInterrupted,
              backend.isPlaying, !isSeekInFlight, !isBuffering else {
            budget.interruptStreamStability()
            return
        }
        guard position.isFinite,
              position > (cycle.lastProgress ?? max(mediaTime, cycle.target)) + 0.000_5 else { return }
        guard hasStreamRecoveryOutput(cycle, at: position), position >= cycle.target - 0.05 else { return }
        cycle.lastProgress = position
        cycle.target = position
        if cycle.recovering {
            cycle.recovering = false
            cycle.deadline?.cancel()
            cycle.deadline = nil
            cycle.operation = nil
            PlayerLog.log("[StreamRetry] cycle=\(cycle.id) provisional-success target=\(position)")
        }
        if budget.noteStreamProgress(at: now) {
            streamRecovery = nil
            PlayerLog.log("[StreamRetry] cycle=\(cycle.id) stable-success")
        }
    }

    private func hasStreamRecoveryOutput(_ cycle: StreamRecoveryCycle, at position: TimeInterval) -> Bool {
        if backendKind != .demandPaced || cycle.outputSession == backend.demandPresentationSessionGeneration {
            return true
        }
        guard PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsBackgroundPlayback,
              UIApplication.shared.applicationState != .active, !backend.hasObservedPiPLease,
              let renderedPosition = (backend as? DemandPacedPlayerBackend)?.renderedAudioOutputPosition else {
            return false
        }
        return renderedPosition >= position
    }

    private func beginStreamRetry(_ cycle: StreamRecoveryCycle, requestID: UUID) {
        guard self.streamRecoveryMayRun else {
            cycle.suspended = true
            return
        }
        guard self.budget.streamRemaining(at: CACurrentMediaTime()) > 0 else {
            self.finishStreamRecovery(cycle, reason: "deadline")
            return
        }
        cycle.requestID = requestID
        cycle.issued = false
        self.resumeAtTime = cycle.target
        self.audioTierOverride = cycle.audio
        if cycle.installed != nil, self.decoderRecoveryContext() != nil {
            let decision = self.admitRecovery(
                trigger: .streamTransport(cycle: cycle.id, request: requestID), position: cycle.target
            )
            if case .admitted = decision { return }
            self.finishStreamRecovery(cycle, reason: "admission")
            return
        }
        cycle.operation = Task { @MainActor [weak self, weak cycle] in
            guard let self, let cycle, self.acceptsStreamRequest(requestID) else { return }
            await self.loadVOD(aid: cycle.aid, cid: cycle.cid, quality: cycle.quality,
                source: cycle.source, resumeAt: cycle.target, preservePlayState: true,
                ownerLease: cycle.owner, streamRetryID: requestID)
            self.finishStreamLoaderReturn(cycle, requestID: requestID)
        }
    }

    func acceptsStreamRecoveryTrigger(_ trigger: DecoderRecoveryAdmission.Trigger) -> Bool {
        guard case .streamTransport(let cycleID, let requestID) = trigger else { return true }
        return streamRecovery?.id == cycleID && acceptsStreamRequest(requestID)
    }

    func finishStreamRecoveryLoaderIfNeeded(requestID: UUID?) {
        guard let requestID, let cycle = streamRecovery else { return }
        finishStreamLoaderReturn(cycle, requestID: requestID)
    }

    func bindStreamRestoreTask(requestID: UUID?) {
        guard let requestID, streamRecovery?.requestID == requestID else { return }
        streamRecovery?.operation = reopenSeekTask
    }

    func deferStreamRecoveryForBackground() {
        if !PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsBackgroundPlayback {
            suspendStreamRecovery()
        }
    }

    func preservesStreamRetryForReload(id: UUID?, reason: PlayerTeardownReason) -> Bool {
        let preserves = reason == .internalReload && id.map(acceptsStreamRequest) == true
        if preserves {
            streamRecovery?.installed = nil
        } else {
            retireStreamRecovery(reason: "stop")
        }
        return preserves
    }

    func migrateStreamRetryLoad(preserving: Bool) {
        if preserving { streamRecovery?.loadGeneration = loadGeneration }
    }
}
