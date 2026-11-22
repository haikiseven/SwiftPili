import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

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

    func synchronizeTerminalAdmissionFromBackend() {
        guard backendKind == .demandPaced,
              currentPlaybackTerminalState == .active,
              backend.isReadyToPlay,
              case .requiresRecovery(.terminal) = backend.retainedPipelineHealth.state
        else { return }
        PlayerLog.log("[Player] terminal admission reconciled from Demand EOF")
        admitNaturalPlaybackEnd()
    }

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
        standDownLifecycleForTerminalPlayback()
        if usesDemandPresentationContinuity {
            dispatchDemandPresentation(.playbackEnded)
        }
        updateDemandVideoLivenessContext()
        clearNearEndStall()
        if duration > 0 {
            mediaTime = duration
            bufferedTime = max(bufferedTime, duration)
        }
        reportCompletionNow()
        persistOfflineProgressNow()
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()

        let endedGeneration = playerGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.playerGeneration == endedGeneration,
                  self.playbackTerminalState == .ended else { return }
            self.applyEndOfPlaybackOrder()
        }
    }

    private func applyEndOfPlaybackOrder() {
        guard mode.isSeekable else { return }
        switch playbackOrder {
        case .pauseAtEnd:
            break
        case .playNext:
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

    func restartForLoop() {
        guard prepareExplicitReplay() else { return }
        let reloadOwnerLease = currentOwnerLease
        mediaTime = 0
        resumeAtTime = nil
        resumeIsFromHistory = false
        sponsorSkippedUUIDs = []
        autoSkippedSegmentKeys = []

        if let url = currentURL, Self.urlStillFresh(url) {
            guard reloadOwnerLease.map({ isCurrentOwner($0) }) ?? false else { return }
            PlayerLog.log("[Player] 🔁 end policy: loop — reopening at 0:00")
            playURL(url, audioURL: isDASHMode ? currentDASHAudioURL : nil, startAt: 0)
            return
        }
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
