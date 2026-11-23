import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func performAdmittedRecovery(
        token: UInt64,
        request: DecoderRecoveryAdmission.Request
    ) async {
        guard let admittedTicket = decoderRecoveryAdmission.authoritativeTicket(
            for: token,
            matchingAuthority: request.context
        ) else { return }
        let authority = admittedTicket.request.context
        let position = request.position
        let streamRequestID = request.trigger.streamRequestID
        guard acceptsStreamRecoveryTrigger(request.trigger) else { return }
        terminalOpenFailure = true

        switch authority.source {
        case .vod(let aid, let cid, let retainedQuality, _):
            let capture = await captureAdmittedRecoveryCover(token: token, authority: authority)
            guard !capture.isStale, streamRequestID.map(acceptsStreamRequest) ?? true else { return }
            let recoveryCoverIdentity = capture.identity
            defer { finishRecoveryCoverSubmission(recoveryCoverIdentity) }
            resumeAtTime = streamRequestID != nil ? position : (position > 2 ? position : nil)
            let recoveryLease = PlayerOwnerLease(
                owner: authority.owner,
                generation: authority.ownerLeaseGeneration
            )
            let retainedURL = currentURL
            switch RetainedSourceReopenPolicy.decision(
                isManualRetry: request.trigger == .manualRetry,
                replacementQuality: request.trigger.replacementQuality,
                hasRetainedURL: retainedURL != nil,
                retainedURLIsFresh: retainedURL.map(Self.urlStillFresh) ?? false
            ) {
            case .reopenRetainedURL:
                guard let retainedURL, isCurrentOwner(recoveryLease) else {
                    PlayerLog.log("[Recovery] retained-URL reopen abandoned — owner changed")
                    break
                }
                PlayerLog.log(
                    "[Recovery] reopening retained source in place at " +
                        "\(String(format: "%.1f", position))s — no playurl refetch"
                )
                playURL(
                    retainedURL,
                    audioURL: isDASHMode ? currentDASHAudioURL : nil,
                    startAt: streamRequestID != nil ? position : (position > 2 ? position : 0),
                    streamRetryID: streamRequestID
                )
            case .refetchPlayURL(let reason):
                PlayerLog.log("[Recovery] playurl refetch required — \(reason)")
                await loadVOD(
                    aid: aid,
                    cid: cid,
                    quality: request.trigger.replacementQuality ?? retainedQuality,
                    source: streamRecovery?.source ?? currentSource,
                    resumeAt: streamRequestID != nil ? position : nil,
                    preservePlayState: request.trigger != .manualRetry,
                    ownerLease: recoveryLease,
                    recoveryCoverIdentity: recoveryCoverIdentity,
                    streamRetryID: streamRequestID
                )
            }
        case .live(let roomID, let quality):
            await loadLive(
                roomID: roomID,
                quality: quality,
                preservePlayState: request.trigger != .manualRetry,
                owner: authority.owner,
                ownerLease: PlayerOwnerLease(
                    owner: authority.owner,
                    generation: authority.ownerLeaseGeneration
                )
            )
        case .offline(let asset):
            let recovery = OfflinePlaybackRecoveryPolicy.request(
                for: asset,
                position: position
            )
            startOfflinePlayback(
                recovery.asset,
                at: recovery.position,
                preservePlayState: request.trigger != .manualRetry
            )
        }

        settleAdmittedRecoveryLoaderReturn(token: token, authority: request.context)
        finishStreamRecoveryLoaderIfNeeded(requestID: streamRequestID)
    }

    private func settleAdmittedRecoveryLoaderReturn(
        token: UInt64,
        authority: DecoderRecoveryAdmission.Context
    ) {
        if pendingLifecycleAdmission?.token == token {
            failLifecycleOpeningIfNeeded()
        } else if terminalOpenFailure {
            if lifecycleReadinessFence?.admissionToken == token {
                acknowledgeLifecycleReadiness(.terminalFailure, evidence: .loaderReturn)
            } else {
                finishNonLifecycleRecoveryAfterLoaderIfNeeded(
                    token: token,
                    authority: authority,
                    outcome: .terminalLoaderFailure
                )
            }
        }
    }

    func performLifecycleRecovery(
        trigger: LifecycleRecoveryCoordinator.Trigger,
        epoch: UInt64
    ) async {
        guard lifecycleRecovery.epoch == epoch else { return }
        switch lifecycleRecovery.phase {
        case .reloading(let activeTrigger, let activeEpoch)
                where activeTrigger == trigger && activeEpoch == epoch:
            break
        case .waitingForBackgroundReload(let activeEpoch)
                where trigger == .background && activeEpoch == epoch:
            break
        default:
            return
        }
        guard currentURL != nil else {
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        if trigger == .foreground,
           UIApplication.shared.applicationState != .active {
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        if trigger == .background {
            let configuration = PlayerPlaybackPreferences.playbackContinuationConfiguration
            if configuration.mode != .pictureInPicture || backend.hasObservedPiPLease {
                lifecycleRecovery.deferBackgroundReloadUntilForeground(epoch: epoch)
                PlayerLog.log(
                    "[Lifecycle] epoch=\(epoch) background reload preserved transport " +
                    "mode=\(configuration.mode) observedPiP=\(backend.hasObservedPiPLease ? 1 : 0)"
                )
                return
            }
        }

        let sessionDirty = decoderSessionSuspect
            || needsInlineSurfaceRebuild
            || trigger == .foreground
        guard sessionDirty else {
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        backend.invalidateFrameStats()
        stats.fps = 0
        updateDynamicStats()
        let freshFPS = stats.fps
        let hasRecoverySource = switch mode {
        case .vod:
            currentAid != nil && currentCid != nil
        case .offline:
            offlineAsset != nil
        case .live:
            currentRoomID != nil
        }
        guard ForegroundDecoderPolicy.shouldReopenInPlace(
            sessionSuspect: sessionDirty,
            userWantsPlaying: userWantsPlaying,
            canAutoRevive: canAutoRevive,
            hasSurfacedFailure: error != nil
        ), hasRecoverySource else {
            PlayerLog.log("[Lifecycle] epoch=\(epoch) \(trigger) abandoned wantsPlay=\(userWantsPlaying) canRevive=\(canAutoRevive) errorSurfaced=\(error == nil ? 0 : 1)")
            decoderSessionSuspect = false
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }

        let warmResumeLease = currentOwnerLease
        if trigger == .foreground, userWantsPlaying,
           await backend.confirmRetainedLiveness(within: 1.0) {
            guard lifecycleRecovery.epoch == epoch,
                  warmResumeLease.map({ isCurrentOwner($0) }) ?? true else {
                PlayerLog.log(
                    "[Lifecycle] epoch=\(epoch) warm-resume verdict discarded — ownership moved"
                )
                return
            }
            if needsInlineSurfaceRebuild {
                reattachInlineSurface()
                needsInlineSurfaceRebuild = false
                PlayerLog.log("[Lifecycle] epoch=\(epoch) warm resume rebound the inline surface")
            }
            decoderSessionSuspect = false
            isBuffering = false
            lifecycleRecovery.abandon(epoch: epoch)
            PlayerLog.log(
                "[Lifecycle] epoch=\(epoch) foreground resumed the retained pipeline — no reload"
            )
            return
        }

        let recoverTo = clampedDecoderRecoveryPosition
        let lifecycleToken: UInt64
        let lifecycleAdmissionWasCoalesced: Bool
        switch admitRecovery(trigger: .lifecycle(epoch: epoch), position: recoverTo) {
        case .admitted(let token):
            lifecycleToken = token
            lifecycleAdmissionWasCoalesced = false
            terminalOpenFailure = true
            isBuffering = true
        case .coalesced(let token):
            lifecycleToken = token
            lifecycleAdmissionWasCoalesced = true
        case .rejected(let rejection):
            PlayerLog.log("[Lifecycle] epoch=\(epoch) recovery not admitted — \(rejection)")
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        guard beginLifecycleOpening(
            trigger: trigger,
            epoch: epoch,
            token: lifecycleToken
        ) else {
            if !lifecycleAdmissionWasCoalesced,
               let ticket = decoderRecoveryAdmission.inFlight,
               ticket.token == lifecycleToken {
                _ = decoderRecoveryAdmission.finishAuthoritatively(
                    token: lifecycleToken,
                    matchingAuthority: ticket.request.context,
                    now: CACurrentMediaTime(),
                    outcome: .terminalLoaderFailure
                )
            }
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        if lifecycleAdmissionWasCoalesced {
            submitLifecycleOpeningIfNeeded()
            decoderSessionSuspect = false
            PlayerLog.log(
                "[Lifecycle] epoch=\(epoch) joined existing recovery token=" +
                    "\(lifecycleToken) — no second backend open"
            )
            return
        }
        decoderSessionSuspect = false
        if trigger == .background {
            needsInlineSurfaceRebuild = true
        }
        if backend.isPiPActive {
            PlayerLog.log("[Lifecycle] epoch=\(epoch) stopping raw PiP before \(trigger) reload")
            backend.stopPiP()
        }
        PlayerLog.log(
            "[Lifecycle] epoch=\(epoch) reload=\(trigger) at=\(String(format: "%.1f", recoverTo)) diagFps=\(String(format: "%.1f", freshFPS))"
        )
        guard let ticket = decoderRecoveryAdmission.inFlight,
              ticket.token == lifecycleToken else {
            failLifecycleOpeningIfNeeded()
            return
        }
        await performAdmittedRecovery(
            token: lifecycleToken,
            request: ticket.request
        )
    }
}
