import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func setMute(_ reason: MuteAuthority.Reason, _ active: Bool) {
        guard let muted = muteAuthority.set(reason, active: active) else { return }
        backend.isMuted = muted
        PlayerLog.log("[Player] mute → \(muted) (\(muteAuthority.reasonsDescription))")
    }

    func releaseAllMute() {
        guard let muted = muteAuthority.releaseAll() else { return }
        backend.isMuted = muted
        PlayerLog.log("[Player] mute → \(muted) (teardown)")
    }

    func reassertMuteOnActiveBackend() {
        backend.isMuted = muteAuthority.isMuted
    }

    private static func activateAudioSession() throws {
        do {
            try PlayerAudioSessionActivation.configureAndActivate()
        } catch {
            let failure = error as NSError
            PlayerLog.log("[Player] audio activation failed domain=\(failure.domain) code=\(failure.code)")
            throw error
        }
    }

    func authorizeAudioPlayback() -> Bool {
        let allowed = audioSessionPolicy.authorizePlayback(activate: Self.activateAudioSession)
        guard allowed else {
            suspendPlayback()
            return false
        }
        return true
    }

    func handleAudioSessionEvent(_ event: PlayerAudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            revokeEqualizerMaintenancePermission()
            audioSessionPolicy.beginInterruption()
            if playbackIntent == .playing { playbackIntent = .pausedBySystem }
            suspendPlayback()
        case .interruptionEnded(let shouldResume):
            if shouldResume, playbackIntent == .pausedBySystem {
                beginBackgroundPlaybackRestoration(reason: "interruption-ended")
            }
            let resume = audioSessionPolicy.endInterruption(
                shouldResume: shouldResume,
                context: .init(
                    systemPausedIntent: playbackIntent == .pausedBySystem,
                    terminal: currentPlaybackTerminalState.isTerminal,
                    pendingMediaReset: mediaResetRecovery.request != nil,
                    applicationActive: UIApplication.shared.applicationState == .active,
                    allowsBackgroundPlayback: PlayerPlaybackPreferences.playbackContinuationConfiguration
                        .allowsBackgroundPlayback
                ),
                activate: Self.activateAudioSession
            )
            if resume {
                play()
            } else {
                backgroundExecution.end(reason: "interruption-not-resumed")
                if playbackIntent == .pausedBySystem, !shouldResume { playbackIntent = .pausedByUser }
            }
        case .oldDeviceUnavailable:
            audioSessionPolicy.requireUserPlay()
            pause()
        case .mediaServicesReset:
            admitMediaServicesReset()
        }
    }

    private func capturedMediaResetSource() -> MediaResetSource? {
        if let retained = mediaResetRecovery.request, retained.owner == currentOwnerLease {
            return retained.source
        }
        switch mode {
        case .offline:
            guard let offlineAsset else { return nil }
            return .offline(offlineAsset, position: recoveryPosition)
        case .vod:
            guard let aid = currentAid, let cid = currentCid else { return nil }
            return .vod(aid: aid, cid: cid, quality: currentQuality,
                        source: currentSource, position: recoveryPosition)
        case .live:
            guard let roomID = currentRoomID else { return nil }
            return .live(roomID: roomID, quality: currentLiveQuality)
        }
    }

    private func detachResetBackend(_ instance: PlayerBackend) {
        instance.revokeAudioMaintenancePermission()
        instance.audioMaintenanceAdmission = nil
        instance.setAudioOutputStateChangeHandler(nil)
        instance.setObservedPiPLeaseChangeHandler(nil)
        instance.setPiPTransportEdgeHandler(nil)
        instance.setDemandPiPNativeTransitionHandler(nil)
        instance.setDemandPiPRestoreRequestHandler(nil)
        instance.setDemandPresentationProofHandler(nil)
        instance.setDemandPresentationFailureHandler(nil)
        instance.setRuntimeFaultHandler(nil)
        instance.setStartupTraceToken(nil)
        instance.onStateChanged = nil
        instance.onTickWithGeneration = nil
        instance.onBufferChanged = nil
        instance.updateDemandVideoLivenessContext(nil)
        instance.forceRetireDemandPiP()
        instance.stopPiP()
        instance.stop()
    }

    private func admitMediaServicesReset() {
        revokeEqualizerMaintenancePermission()
        let owner = currentOwnerLease
        let source = capturedMediaResetSource()
        audioSessionPolicy.reset()
        playbackIntent = .pausedByUser
        suspendPlayback()
        invalidatedBackendResources = true
        for instance in backendInstances.values { detachResetBackend(instance) }
        backendInstances.removeAll()
        stop(reason: .internalReload)
        lifecycleRecoveryTask?.cancel()
        relinquishLifecycleAuthority(takenOverBy: "media services reset", reason: "resources invalid")
        invalidateLifecycleReadiness()
        lifecycleRecovery.invalidate()
        decoderRecoveryAdmission.invalidate()
        nonLifecycleRecoveryTicket = nil
        explicitPlayReloadInFlight = false
        if let owner, let source {
            mediaResetRecovery.admit(owner: owner, source: source)
        }
        PlayerLog.log("[Player] media services reset — resources retired; user Play required")
    }

    func recoverMediaServicesAfterUserPlay() {
        guard let pending = mediaResetRecovery.request,
              pending.owner == currentOwnerLease, !pending.opening,
              authorizeAudioPlayback(),
              let request = mediaResetRecovery.begin(owner: currentOwnerLease) else { return }
        playbackIntent = .playing
        playbackTerminalState = .active
        terminalOpenFailure = false
        error = nil
        isBuffering = true
        handOffBackend(to: activeBackendKind, reason: "explicit media-reset recovery")
        Task { @MainActor [weak self] in
            guard let self,
                  self.mediaResetRecovery.accepts(request.id, owner: self.currentOwnerLease) else { return }
            switch request.source {
            case let .vod(aid, cid, quality, source, position):
                await self.loadVOD(aid: aid, cid: cid, quality: quality, source: source,
                                  resumeAt: position, preservePlayState: true,
                                  ownerLease: request.owner, mediaResetID: request.id)
            case let .offline(asset, position):
                self.startOfflinePlayback(asset, at: position, preservePlayState: true,
                                          mediaResetID: request.id)
            case let .live(roomID, quality):
                _ = await self.loadLive(roomID: roomID, quality: quality,
                                        preservePlayState: true, ownerLease: request.owner,
                                        mediaResetID: request.id)
            }
        }
    }

    func settleResetPreOpenFailure(
        _ completion: PlayerMediaResetRecovery<MediaResetSource>.LoadCompletion,
        retryable: Bool
    ) -> Bool {
        mediaResetRecovery.settlePreOpenFailure(
            completion, currentGeneration: loadGeneration,
            currentOwner: currentOwnerLease, retryable: retryable
        )
    }
}
