import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    static func watchdogHasBufferedRunway(_ backend: any PlayerBackend, floor: TimeInterval) -> Bool {
        hasProvenBufferedRunway(contentAhead: backend.bufferedPipelineAhead, floor: floor)
    }

    func startPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
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

    private func watchdogTick() {
        PowerProfiler.tick(.watchdog)
        synchronizeTerminalAdmissionFromBackend()

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

        let t = mediaTime
        defer { lastWatchdogTime = t }

        if stats.fps >= 1 { fpsEverLive = true }
        if isPlaying, t > lastWatchdogTime + 1e-6 { clockEverAdvancedThisStream = true }

        if budget.stallStreak > 0, isPlaying, !isBuffering, budget.hasMovedClear(of: t) {
            budget.clearStallStreak()
        }
        if isPlaying, !isBuffering, budget.refundDecoderReloadsIfMovedClear(at: t) {
            PlayerLog.log(
                "[Recovery] decoder reloads refunded — playback moved clear of the last reload " +
                    "at=\(String(format: "%.1f", t)) \(budget.summary)"
            )
        }

        let dataFlowing = CACurrentMediaTime() - lastBytesAdvanceAt < Self.dataFlowWindow
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

    private func healthSignalDetail(_ s: PlaybackSignals) -> String {
        "mode=\(mode) t=\(String(format: "%.1f", s.position)) " +
            "clk=\(s.clockAdvancing ? 1 : 0) fps=\(String(format: "%.1f", stats.fps)) " +
            "net=\(Int(stats.networkSpeed / 1024))KB/s " +
            "gp=\(Int(pipelineGoodput / 1024))KB/s " +
            "runway=\(runwayLogText) " +
            "avail=\(String(format: "%.1f", bufferedTime)) " +
            "dataFlow=\(s.dataFlowing ? 1 : 0) started=\(s.hasStartedPlaying ? 1 : 0) " +
            "framesProven=\(s.framesProven ? 1 : 0) video=\(s.hasVideoTrack ? 1 : 0) " +
            "elapsed=\(Int(s.elapsedSinceStart))s"
    }

    private func noteHealthOutcome(_ reason: String, _ detail: @autoclosure () -> String) {
        let repeated = healthOutcome?.reason == reason
        let ticks = repeated ? (healthOutcome?.ticks ?? 0) + 1 : 1
        healthOutcome = (reason, ticks)
        guard !repeated || ticks % Self.healthOutcomeHeartbeatTicks == 0 else { return }
        PlayerLog.log("[Health] no recovery — \(reason) (tick \(ticks)) \(detail())")
    }

    private func recover(from fault: PlaybackFault, ticks: Int, at t: TimeInterval, isStartup: Bool) {
        guard !currentPlaybackTerminalState.isTerminal,
              mode == .offline || (currentAid != nil && currentCid != nil) else { return }

        switch fault {
        case .deadDecoder:
            guard ticks >= 2 else { return }
            faultTicks = 0
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
                settleTerminalFailure(TerminalFailurePayload(
                    message: String(localized: "Video decoder failed. Tap Retry."),
                    logMessage: "[Player] ❌ decoder still dead after \(budget.decoderReloads) source-aware reopens — surfacing Retry"
                ))
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
        if !isStartup, ticks == 1, backend.isReadyToPlay {
            PlayerLog.log("[Player] \(fault.rawValue) — kicking the transport")
            backend.play()
            return
        }
        guard ticks >= 2 else { return }
        faultTicks = 0

        let position = recoveryPosition
        let streak = budget.recordStall(at: position)

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
            guard rejection.endsAutomaticRecovery else {
                PlayerLog.log("[Player] \(fault.rawValue) #\(streak) — \(rejection), not terminal; re-evaluated next tick")
                return
            }
            settleTerminalFailure(TerminalFailurePayload(
                message: String(localized: "Playback timed out. Try again."),
                logMessage: "[Player] ❌ \(fault.rawValue) #\(streak) — \(rejection), surfacing Retry"
            ))
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
            if nonLifecycleRecoveryTask?.token == token {
                nonLifecycleRecoveryTask?.task.cancel()
                nonLifecycleRecoveryTask = nil
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
