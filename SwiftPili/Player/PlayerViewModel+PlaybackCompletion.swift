import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Retire pending recovery and presentation work after a terminal playback outcome.
    @discardableResult
    func standDownLifecycleForTerminalPlayback() -> Bool {
        let state = currentPlaybackTerminalState
        guard state.isTerminal else { return false }
        if let recoveryCover { clearRecoveryCover(matching: recoveryCover.identity) }
        retireCDNFrameCover()
        retireCDNSwitch()
        noteDanmakuTerminalPlaybackEdge()
        if lifecycleRecovery.terminalState != state {
            lifecycleRecovery.enterTerminal(state)
        }
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = nil
        demandContinuationOperationRunner?.cancelCurrent()
        demandForegroundStageTape = nil
        demandBackgroundStageTape = nil
        demandPresentationLiveness.invalidate()
        return true
    }

    /// Reconcile an authoritative Demand EOF if its callback is delayed; empty runway alone is not EOF.
    func synchronizeTerminalAdmissionFromBackend() {
        guard backendKind == .demandPaced,
              currentPlaybackTerminalState == .active,
              backend.isReadyToPlay,
              case .requiresRecovery(.terminal) = backend.retainedPipelineHealth.state
        else { return }
        PlayerLog.log("[Player] terminal admission reconciled from Demand EOF")
        admitNaturalPlaybackEnd()
    }

    /// Admit natural end once, close lifecycle work, report completion, then schedule the end policy for
    /// this generation.
    func admitNaturalPlaybackEnd() {
        guard currentPlaybackTerminalState == .active else {
            if playbackTerminalState == .ended {
                PlayerLog.log("[Player] playedToTheEnd (repeat) — end policy already applied")
            } else {
                PlayerLog.log("[Player] playedToTheEnd ignored after terminal state")
            }
            return
        }

        retireStreamRecovery(reason: "ended")
        PlayerLog.log("[Player] playedToTheEnd")
        playbackTerminalState = .ended
        // Background/foreground notifications that arrive after this edge must be no-ops; they may not
        // manufacture presentation debt or recovery.
        standDownLifecycleForTerminalPlayback()
        if usesDemandPresentationContinuity {
            dispatchDemandPresentation(.playbackEnded)
        }
        updateDemandVideoLivenessContext()
        clearNearEndStall()
        // Explicit end policy: snap media truth to duration so
        // history/recovery agree after a near-EOF DASH gap froze timeChanged
        // short of the end. displayTime also returns duration.
        if duration > 0 {
            mediaTime = duration
            bufferedTime = max(bufferedTime, duration)
        }
        // VOD-gated inside the method, so the offline counterpart below stays the only writer for a local
        // asset.
        reportCompletionNow()
        // Ahead of the end-order hand-off below, because `.playNext`/`.loopOne` both stop() into a successor
        // whose own load then owns the row.
        persistOfflineProgressNow()
        updateIsPlaying(transportRunning: false)
        // The card may remain visible until the next explicit replay or owner replacement.
        pushNowPlayingPlayback()

        // Apply the order on the next main-actor turn.
        let endedGeneration = playerGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.playerGeneration == endedGeneration,
                  self.playbackTerminalState == .ended else { return }
            self.applyEndOfPlaybackOrder()
        }
    }

    /// Settings → Playback → Playback Order, applied at the natural end of a stream.
    private func applyEndOfPlaybackOrder() {
        guard mode.isSeekable else { return }
        switch playbackOrder {
        case .pauseAtEnd:
            break
        case .playNext:
            // `onPlaybackEnded` is non-nil only while the screen that installed it still holds the player:
            // every load starts with stop(), and stop() clears it — so there is no torn-down or re-claimed
            // session to second-guess here, only "is there a next item at all".
            guard let advance = onPlaybackEnded else {
                PlayerLog.log("[Player] end policy: playNext — nothing registered, stopping at end")
                return
            }
            PlayerLog.log("[Player] end policy: playNext → owner=\(ownerKey.isEmpty ? "-" : ownerKey)")
            advance()
        case .loopOne:
            restartForLoop()
        }
    }

    /// Reset terminal and recovery state for a deliberate replay without issuing a recovery operation.
    private func prepareExplicitReplay() -> Bool {
        guard PlaybackReplayPolicy.allows(from: playbackTerminalState) else {
            return false
        }
        let hasReplayAuthority: Bool = switch mode {
        case .vod:
            currentAid != nil && currentCid != nil
        case .offline:
            offlineAsset != nil
        case .live:
            false
        }
        guard hasReplayAuthority else { return false }
        playbackTerminalState = .active
        terminalOpenFailure = false
        error = nil
        unavailability = nil
        decoderSessionSuspect = false
        needsInlineSurfaceRebuild = false
        needsReloadBeforeExplicitPlay = false
        resumeAtTime = nil
        resumeIsFromHistory = false
        pendingSeekTarget = nil
        mediaTime = PlaybackReplayPolicy.canonicalOrigin
        lastSeekRequest = nil
        armDurableResumeTarget(nil, source: "explicit-replay")
        clearFreezeFrame()
        currentFault = nil
        faultTicks = 0
        healthOutcome = nil
        pendingRestartNotice = false
        resetRecoveryBudget()
        cdnFallbackActive = false
        // Explicit replay is a new normal admission. Do not let a delayed
        // lifecycle/recovery task or its ticket migrate into the replay load.
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = nil
        demandContinuationOperationRunner?.cancelCurrent()
        invalidateLifecycleReadiness()
        decoderRecoveryAdmission.invalidate()
        nonLifecycleRecoveryTicket = nil
        lifecycleRecovery.clearTerminalForReplay()
        demandPresentationLiveness.invalidate()
        if usesDemandPresentationContinuity {
            dispatchDemandPresentation(.explicitReplay)
        }
        rearmHistoryReportingAfterCompletion()
        updateDemandVideoLivenessContext()
        return true
    }

    /// Reopen an ended item at zero; seeking a stopped VLC player cannot reliably start a new pass.
    func restartForLoop() {
        guard prepareExplicitReplay() else { return }
        let reloadOwnerLease = currentOwnerLease
        // Left at duration it would show a full progress bar and hand `recoveryPosition` the end of the video
        // until the first tick.
        mediaTime = 0
        // The restart IS the position; nothing is owed a resume seek.
        resumeAtTime = nil
        resumeIsFromHistory = false
        // They survive a same-video reload because a RECOVERY reload lands back INSIDE a segment and must not
        // bounce forward again; that reasoning does not hold for a deliberate restart at 0:00, where every
        // segment is ahead of the playhead again.
        sponsorSkippedUUIDs = []
        autoSkippedSegmentKeys = []

        if let url = currentURL, Self.urlStillFresh(url) {
            guard reloadOwnerLease.map({ isCurrentOwner($0) }) ?? false else { return }
            PlayerLog.log("[Player] 🔁 end policy: loop — reopening at 0:00")
            playURL(url, audioURL: isDASHMode ? currentDASHAudioURL : nil, startAt: 0)
            return
        }
        // The playurl signature expired while the video played out, so only a fresh playurl can reach 0 again.
        guard let aid = currentAid, let cid = currentCid else {
            PlayerLog.log("[Player] end policy: loop — nothing to reopen, stopping at end")
            return
        }
        PlayerLog.log("[Player] 🔁 end policy: loop — URL signature expired, full reload")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadVOD(
                aid: aid,
                cid: cid,
                quality: self.currentQuality,
                source: self.currentSource,
                ownerLease: reloadOwnerLease
            )
        }
    }
}
