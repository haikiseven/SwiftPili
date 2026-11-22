import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Use measured pipeline runway, excluding cached content that a stalled pump may never consume.
    static func watchdogHasBufferedRunway(_ backend: any PlayerBackend, floor: TimeInterval) -> Bool {
        hasProvenBufferedRunway(contentAhead: backend.bufferedPipelineAhead, floor: floor)
    }

    /// Start one evaluator without reseeding the last media sample into a false clock advance.
    func startPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        // Deliberately NOT re-seeding lastWatchdogTime: playURL seeds it to the open position (its comment
        // says why), and every other caller (unpause) arrives with a recent ticked value.
        currentFault = nil
        faultTicks = 0
        healthOutcome = nil
        coalescedRecoveryWatchdog = nil
        playbackWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.watchdogTick()
            }
        }
    }

    /// Classify one current signal snapshot after excluding normal seek, background and terminal states.
    private func watchdogTick() {
        PowerProfiler.tick(.watchdog)
        synchronizeTerminalAdmissionFromBackend()

        // The phases in which "no clock, no frames" is CORRECT rather than faulty.
        if let standDown = watchdogStandDownReason {
            noteHealthOutcome(
                standDown,
                "mode=\(mode) t=\(String(format: "%.1f", mediaTime)) " +
                    "st=\(isBuffering ? "buffering" : (isPlaying ? "playing" : "paused"))"
            )
            currentFault = nil
            faultTicks = 0
            lastWatchdogTime = mediaTime
            return
        }

        // Policy clock = mediaTime only. Never wall/display fiction.
        let t = mediaTime
        defer { lastWatchdogTime = t }

        if stats.fps >= 1 { fpsEverLive = true }
        // First real forward motion of the media clock proves the stream has
        // begun playing — after this a frozen clock is a stall, before it a
        // frozen clock is priming (see `hasStartedPlaying`).
        if isPlaying, t > lastWatchdogTime + 1e-6 { clockEverAdvancedThisStream = true }

        // Playback has moved clear of a position that was accumulating
        // escalations — the region decoded after all (or was skipped); future
        // faults start the strategy ladder over.
        if budget.stallStreak > 0, isPlaying, !isBuffering, budget.hasMovedClear(of: t) {
            budget.clearStallStreak()
        }
        if isPlaying, !isBuffering, budget.refundDecoderReloadsIfMovedClear(at: t) {
            PlayerLog.log(
                "[Recovery] decoder reloads refunded — playback moved clear of the last reload " +
                    "at=\(String(format: "%.1f", t)) \(budget.summary)"
            )
        }

        // `dataFlowing` = bytes advanced within the window, not the instantaneous rate: Path A's HTTP source
        // fetches in bursts, so goodput reads 0 between fragments even while data is flowing.
        let dataFlowing = CACurrentMediaTime() - lastBytesAdvanceAt < Self.dataFlowWindow
        // The PIPELINE half of the delivery channel, `backend.bufferedPipelineAhead` — not `bufferedTime`,
        // which is the AVAILABILITY horizon and for an offline file is the whole remaining video, and not the
        // cache-inclusive `bufferedContentAhead`, which a stuck supply never drains.
        let hasBufferedRunway = Self.watchdogHasBufferedRunway(
            backend,
            floor: Self.bufferedRunwayFloor
        )
        let hasCurrentPresentationProof = backendKind == .demandPaced
            ? demandPresentationLiveness.hasCurrentProof
            : fpsEverLive
        let signals = PlaybackSignals(
            position: t,
            clockAdvancing: t != lastWatchdogTime,
            framesAdvancing: stats.fps >= 1,
            framesProven: hasCurrentPresentationProof,
            dataFlowing: dataFlowing,
            hasVideoTrack: !backend.videoTracks().isEmpty,
            hasStartedPlaying: clockEverAdvancedThisStream
                || CACurrentMediaTime() - lastStreamStartAt > Self.primingCeiling,
            hasBufferedRunway: hasBufferedRunway,
            // It owns that fault; this evaluator keeps the frozen-clock ladder, which Demand has no other
            // detector for.
            decoderLivenessOwnedByBackend: backendKind == .demandPaced
                && hasCurrentPresentationProof,
            elapsedSinceStart: CACurrentMediaTime() - lastStreamStartAt,
            terminalState: currentPlaybackTerminalState
        )

        guard let fault = classifyPlayback(signals) else {
            noteHealthOutcome(
                signals.suppressionReason ?? "unclassified",
                healthSignalDetail(signals)
            )
            currentFault = nil
            faultTicks = 0
            return
        }
        // A classified fault ends the suppression run, so the next one logs as
        // an edge rather than waiting out a heartbeat.
        healthOutcome = nil
        if fault == currentFault {
            faultTicks += 1
        } else {
            currentFault = fault
            faultTicks = 1
        }
        PlayerLog.log("[Player] ⚠️ \(fault.rawValue) (tick \(faultTicks)) t=\(String(format: "%.1f", t)) fps=\(String(format: "%.1f", stats.fps)) net=\(Int(stats.networkSpeed / 1024))KB/s gp=\(Int(pipelineGoodput / 1024))KB/s buffering=\(isBuffering) started=\(clockEverAdvancedThisStream) runway=\(runwayLogText) dataFlow=\(signals.dataFlowing)")
        recover(from: fault, ticks: faultTicks, at: t, isStartup: signals.isStartup)
    }

    /// The evidence behind a suppressed tick, in the same shape as the fault line
    /// above so the two read as one series. Numbers and flags only.
    private func healthSignalDetail(_ s: PlaybackSignals) -> String {
        "mode=\(mode) t=\(String(format: "%.1f", s.position)) " +
            "clk=\(s.clockAdvancing ? 1 : 0) fps=\(String(format: "%.1f", stats.fps)) " +
            // `net=` is the displayed wire rate; `gp=` the pipeline goodput that
            // `dataFlow` and delivery health are derived from.
            "net=\(Int(stats.networkSpeed / 1024))KB/s " +
            "gp=\(Int(pipelineGoodput / 1024))KB/s " +
            // Two different quantities, deliberately both printed and no longer both called "runway": the
            // measured delivery channel (or `n/a`), and the availability horizon the seek UI draws from.
            "runway=\(runwayLogText) " +
            "avail=\(String(format: "%.1f", bufferedTime)) " +
            "dataFlow=\(s.dataFlowing ? 1 : 0) started=\(s.hasStartedPlaying ? 1 : 0) " +
            "framesProven=\(s.framesProven ? 1 : 0) video=\(s.hasVideoTrack ? 1 : 0) " +
            "elapsed=\(Int(s.elapsedSinceStart))s"
    }

    /// The other half of the evaluator's output.
    private func noteHealthOutcome(_ reason: String, _ detail: @autoclosure () -> String) {
        let repeated = healthOutcome?.reason == reason
        let ticks = repeated ? (healthOutcome?.ticks ?? 0) + 1 : 1
        healthOutcome = (reason, ticks)
        guard !repeated || ticks % Self.healthOutcomeHeartbeatTicks == 0 else { return }
        PlayerLog.log("[Health] no recovery — \(reason) (tick \(ticks)) \(detail())")
    }

    /// Escalate bounded same-position failures through the existing source-aware host/encode/decoder
    /// recovery ladder.
    private func recover(from fault: PlaybackFault, ticks: Int, at t: TimeInterval, isStartup: Bool) {
        guard !currentPlaybackTerminalState.isTerminal,
              mode == .offline || (currentAid != nil && currentCid != nil) else { return }

        switch fault {
        case .deadDecoder:
            // libVLC only — `classifyPlayback` no longer produces this fault when the backend runs its own
            // liveness detector.
            guard ticks >= 2 else { return }
            faultTicks = 0
            // Recover to the user's intended target, not the frozen/undershot
            // clock: a post-seek stall can leave t below the requested position.
            let recoverTo = max(t, lastSeekRequest ?? 0)
            switch admitRecovery(trigger: .runtimeFault, position: recoverTo) {
            case .admitted(let token):
                clearCoalescedWatchdogTracking()
                coalescedRecoveryWatchdog = nil
                _ = token
                terminalOpenFailure = true
                PlayerLog.log("[Player] 🔁 decoder dead — retained-source reopen (attempt \(budget.decoderReloads)) at \(String(format: "%.1f", recoverTo))")
            case .coalesced(let token):
                handleCoalescedWatchdogRecovery(token: token, fault: fault, at: recoverTo)
            case .rejected(.budgetExhausted):
                // Out of source-aware reopens and still no frames — stop pretending.
                // Setting error idles this evaluator (top guard) and puts the
                // Retry overlay up; Retry restores the budgets.
                PlayerLog.log("[Player] ❌ decoder still dead after \(budget.decoderReloads) source-aware reopens — surfacing Retry")
                error = String(localized: "Video decoder failed. Tap Retry.")
                isBuffering = false
            case .rejected:
                break
            }

        case .stalledPipeline, .starvedInput:
            recoverFromDeliveryStall(fault: fault, ticks: ticks, isStartup: isStartup)
        }
    }

    private func recoverFromDeliveryStall(fault: PlaybackFault, ticks: Int, isStartup: Bool) {
        if let failure = (backend as? DemandPacedPlayerBackend)?.unresolvedPrimaryTransportFailure,
           handleStreamTransportFailure(failure) { return }
        // Tick 1 never spends the ladder.
        if !isStartup, ticks == 1, backend.isReadyToPlay {
            // Cheap first attempt: VLC sometimes just needs a kick after pausing itself (drained buffer,
            // interruption end).
            PlayerLog.log("[Player] \(fault.rawValue) — kicking the transport")
            backend.play()
            return
        }
        guard ticks >= 2 else { return }
        faultTicks = 0

        // `recoveryPosition`, not `t`: a recovery stream that never reached readyToPlay reports t≈0, which
        // both restarts the video from 0:00 and breaks the streak (0 never matches the real spot, so
        // attempt 1 re-runs forever).
        let position = recoveryPosition
        let streak = budget.recordStall(at: position)

        // The first two rungs are host swaps (boundary 2 — no ticket, because a replacement host that
        // answers nothing would never release one).
        switch streak {
        case 1 where mode.usesOnlineVODServices
                && PlayerPlaybackPreferences.cdnFallbackEnabled
                && budget.canSwitchCDN:
            PlayerLog.log("[Player] 🔁 \(fault.rawValue) at t=\(String(format: "%.1f", position)) — switching CDN")
            scheduleCDNSwitch(reason: fault.rawValue)
        case 2 where mode.usesOnlineVODServices
                && PlayerPlaybackPreferences.cdnFallbackEnabled
                && budget.canSwitchCDN:
            PlayerLog.log("[Player] 🔁 \(fault.rawValue) #2 at t=\(String(format: "%.1f", position)) — same spot on a second CDN, skipping past the undecodable region to \(String(format: "%.1f", position + 10))")
            scheduleCDNSwitch(reason: "skip past undecodable region", resumeOverride: position + 10)
        default:
            let lowerEncode = availableQualities.map(\.id).filter { $0 < currentQuality }.max()
            let trigger: DecoderRecoveryAdmission.Trigger = lowerEncode.map {
                .differentEncode(quality: $0, reason: fault.rawValue)
            } ?? .runtimeFault
            let hostRungs = if !mode.usesOnlineVODServices {
                "none(\(mode))"
            } else if !PlayerPlaybackPreferences.cdnFallbackEnabled {
                "disabled"
            } else if budget.canSwitchCDN {
                "passed(streak>2)"
            } else {
                "exhausted(\(budget.cdnSwitches)/\(RecoveryBudget.maxCDNSwitches))"
            }
            PlayerLog.log(
                "[Player] 🔁 \(fault.rawValue) #\(streak) at t=\(String(format: "%.1f", position)) " +
                    "hosts=\(hostRungs) — " +
                    (lowerEncode.map { "dropping quality \(currentQuality) → \($0) (different encode)" }
                        ?? "reopening the retained \(mode == .offline ? "local asset" : "source")")
            )
            admitAndHandleWatchdogRecovery(
                trigger: trigger,
                position: position,
                fault: fault,
                streak: streak
            )
        }
    }

    private func admitAndHandleWatchdogRecovery(
        trigger: DecoderRecoveryAdmission.Trigger,
        position: TimeInterval,
        fault: PlaybackFault,
        streak: Int
    ) {
        switch admitRecovery(trigger: trigger, position: position) {
        case .admitted:
            clearCoalescedWatchdogTracking()
        case .coalesced(let token):
            handleCoalescedWatchdogRecovery(token: token, fault: fault, at: position)
        case .rejected(let rejection):
            // Only a verdict on the stream may surface Retry: `error != nil`
            // stands this evaluator down for good, so a transient or
            // ownership rejection would freeze the ladder mid-stall.
            guard rejection.endsAutomaticRecovery else {
                PlayerLog.log("[Player] \(fault.rawValue) #\(streak) — \(rejection), not terminal; re-evaluated next tick")
                return
            }
            PlayerLog.log("[Player] ❌ \(fault.rawValue) #\(streak) — \(rejection), surfacing Retry")
            error = String(localized: "Playback timed out. Try again.")
            isBuffering = false
        }
    }

    private func handleCoalescedWatchdogRecovery(
        token: UInt64,
        fault: PlaybackFault,
        at position: TimeInterval
    ) {
        guard token != 0 else { return }
        let priorTicks = coalescedRecoveryWatchdog?.token == token ? (coalescedRecoveryWatchdog?.ticks ?? 0) : 0
        let ticks = priorTicks + 1
        coalescedRecoveryWatchdog = (token, ticks)
        guard ticks >= Self.maxCoalescedWatchdogTicks else { return }

        coalescedRecoveryWatchdog = nil
        var abandoned = false
        if let ticket = decoderRecoveryAdmission.inFlight, ticket.token == token {
            abandoned = decoderRecoveryAdmission.finishAuthoritatively(
                token: token,
                matchingAuthority: ticket.request.context,
                now: CACurrentMediaTime(),
                outcome: .terminalLoaderFailure
            )
            if nonLifecycleRecoveryTicket?.token == token {
                nonLifecycleRecoveryTicket = nil
            }
            if pendingLifecycleAdmission?.token == token || lifecycleReadinessFence?.admissionToken == token {
                if let epoch = pendingLifecycleAdmission?.epoch ?? lifecycleReadinessFence?.lifecycleEpoch {
                    lifecycleRecovery.abandon(epoch: epoch)
                }
                invalidateLifecycleReadiness()
            }
        }
        if abandoned {
            PlayerLog.log(
                "[Recovery] boundary=1 ticket=\(token) abandoned after \(ticks) coalesced watchdog ticks " +
                    "(\(fault.rawValue) at \(String(format: "%.1f", position))s)"
            )
        }
    }
}

extension PlayerViewModel {

    func updateDemandVideoLivenessContext() {
        guard backendKind == .demandPaced else {
            backend.updateDemandVideoLivenessContext(nil)
            return
        }
        guard let source = demandLivenessSourceIdentity() else {
            backend.updateDemandVideoLivenessContext(nil)
            return
        }

        let appState: DemandLivenessAppState
        switch UIApplication.shared.applicationState {
        case .active:
            appState = .active
        case .background:
            appState = .background
        case .inactive:
            appState = .inactive
        @unknown default:
            appState = .inactive
        }
        let lifecycle: DemandLivenessLifecycle
        switch appState {
        case .background:
            lifecycle = backend.hasObservedPiPLease
                ? .backgroundObservedPiP
                : .backgroundNoPiP
        case .inactive:
            lifecycle = .foregroundSettling
        case .active:
            if needsInlineSurfaceRebuild {
                lifecycle = .foregroundSettling
            } else {
                switch lifecycleRecovery.phase {
                case .idle:
                    lifecycle = .settled
                case .waiting(_, _), .reloading(_, _), .waitingForBackgroundReload(_),
                     .opening(_), .awaitingForeground(_), .ready(_), .failed(_):
                    lifecycle = .foregroundSettling
                }
            }
        }
        let intent: DemandLivenessIntent = switch playbackIntent {
        case .playing: .playing
        case .pausedByUser: .userPaused
        case .pausedBySystem: .systemPaused
        }
        let seek: DemandLivenessSeekPhase = backend.pendingSeekTarget == nil
            ? .settled
            : .seeking
        backend.updateDemandVideoLivenessContext(
            DemandVideoLivenessContext(
                source: source,
                ownerLeaseGeneration: ownerLeaseGeneration,
                appState: appState,
                intent: intent,
                canAutoRevive: canAutoRevive,
                lifecycle: lifecycle,
                observedPiPLease: backend.hasObservedPiPLease,
                seek: seek,
                terminalState: currentPlaybackTerminalState
            )
        )
    }

    /// The retained source identity, rebuilt only when aid/cid/quality/mode/owner
    /// change. A miss still goes through `decoderRecoverySource` so the label
    /// cannot drift from recovery admission.
    private func demandLivenessSourceIdentity() -> DemandLivenessSourceIdentity? {
        guard let key = demandLivenessIdentityKey() else {
            cachedDemandLivenessIdentity = nil
            return nil
        }
        if let cachedDemandLivenessIdentity, cachedDemandLivenessIdentity.key == key {
            return cachedDemandLivenessIdentity.source
        }
        guard let retainedSource = decoderRecoverySource() else {
            cachedDemandLivenessIdentity = nil
            return nil
        }
        let source: DemandLivenessSourceIdentity
        switch retainedSource {
        case .vod(let aid, let cid, let quality, let sourceLabel):
            source = .vod(aid: aid, cid: cid, quality: quality, source: sourceLabel)
        case .live(let roomID, let quality):
            source = .live(roomID: roomID, quality: quality)
        case .offline(let asset):
            source = .offline(aid: asset.aid, cid: asset.cid, quality: asset.quality)
        }
        cachedDemandLivenessIdentity = CachedDemandLivenessIdentity(key: key, source: source)
        return source
    }

    private func demandLivenessIdentityKey() -> CachedDemandLivenessIdentity.Key? {
        switch mode {
        case .vod:
            guard let aid = currentAid, let cid = currentCid else { return nil }
            return .vod(
                aid: aid,
                cid: cid,
                quality: currentQuality,
                source: currentSource,
                ownerKey: ownerKey,
                ownerLeaseGeneration: ownerLeaseGeneration
            )
        case .live:
            guard let roomID = currentRoomID else { return nil }
            return .live(
                roomID: roomID,
                quality: currentLiveQuality,
                ownerKey: ownerKey,
                ownerLeaseGeneration: ownerLeaseGeneration
            )
        case .offline:
            guard let asset = offlineAsset else { return nil }
            return .offline(
                aid: asset.aid,
                cid: asset.cid,
                quality: asset.quality,
                ownerKey: ownerKey,
                ownerLeaseGeneration: ownerLeaseGeneration
            )
        }
    }
}
