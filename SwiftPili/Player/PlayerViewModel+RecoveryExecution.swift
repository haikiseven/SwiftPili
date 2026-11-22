import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// The single executor for an admitted ticket: reopen the retained source.
    /// Nothing here re-decides what to do — the ticket already said — and nothing
    /// here charges a budget.
    func performAdmittedRecovery(
        token: UInt64,
        request: DecoderRecoveryAdmission.Request
    ) async {
        // Authority comes from admission, not from the ViewModel: `currentQuality`
        // can change while the play-info response is normalized, so the mutable
        // fields are not a safe identity for this ticket.
        guard let admittedTicket = decoderRecoveryAdmission.authoritativeTicket(
            for: token,
            matchingAuthority: request.context
        ) else { return }
        let authority = admittedTicket.request.context
        let position = request.position
        let streamRequestID = request.trigger.streamRequestID
        guard acceptsStreamRecoveryTrigger(request.trigger) else { return }
        // Set before every admitted reopen and cleared only by `playURL` after submission, so it still
        // standing below is exactly "the loader never submitted a backend open".
        terminalOpenFailure = true

        switch authority.source {
        case .vod(let aid, let cid, let retainedQuality, _):
            let capture = await captureAdmittedRecoveryCover(token: token, authority: authority)
            guard !capture.isStale, streamRequestID.map(acceptsStreamRequest) ?? true else { return }
            let recoveryCoverIdentity = capture.identity
            defer { finishRecoveryCoverSubmission(recoveryCoverIdentity) }
            // An encode drop is the same retained source at a lower tier; every
            // other trigger reopens the tier the source already carries.
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
                    // Ownership moved while this ticket waited; the successor
                    // owns the transport and this reopen must not fire.
                    PlayerLog.log("[Recovery] retained-URL reopen abandoned — owner changed")
                    break
                }
                // `playURL` is the same tail `loadVOD` reaches, so the lifecycle fence, the ticket and the
                // readiness callback all behave identically — what is skipped is only the playurl round trip
                // in front of it.
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
            // `.manualRetry` still plays because `retryPlayback` sets `.playing` itself before this task runs
            // — the authority comes from the tap, not from the reopen.
            await loadLive(
                roomID: roomID,
                quality: quality,
                preservePlayState: true,
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
        // A loader return is never a success — the backend's ready/error callback owns that — so only a ticket
        // whose reopen never reached a backend open is closed here.
        if pendingLifecycleAdmission?.token == token {
            // Still provisional: no successor fence was ever published, which is
            // itself the terminal-failure evidence.
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
            // `consumeLifecycleRecovery(.reload)` schedules this task after changing the phase.
            break
        default:
            return
        }
        // Live is non-seekable but still has a stable recovery identity
        // (room + quality). Excluding it here left a background-invalidated
        // VideoToolbox session consuming packets forever at 0 fps.
        guard currentURL != nil else {
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        if trigger == .foreground,
           UIApplication.shared.applicationState != .active {
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        // Being backgrounded is deliberately not a bail-out: requiring
        // `.active` left black PiP unrecovered until the user came back.
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

        // The coordinator's reload action is the only lifecycle trigger. A
        // later foreground handoff joins this opening; it never re-assesses
        // starvation as a second lifecycle reload.
        let sessionDirty = decoderSessionSuspect
            || needsInlineSurfaceRebuild
            || trigger == .foreground
        // Retained deliberately: this is NOT dead.
        guard sessionDirty else {
            lifecycleRecovery.abandon(epoch: epoch)
            return
        }
        backend.invalidateFrameStats()
        stats.fps = 0
        updateDynamicStats()
        let freshFPS = stats.fps // diagnostic only — never a reopen veto.
        let hasRecoverySource = switch mode {
        case .vod:
            currentAid != nil && currentCid != nil
        case .offline:
            offlineAsset != nil
        case .live:
            currentRoomID != nil
        }
        // `error != nil` is read directly, not inferred from intent.
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

        // Warm resume, before a reload is spent.
        let warmResumeLease = currentOwnerLease
        if trigger == .foreground, userWantsPlaying,
           await backend.confirmRetainedLiveness(within: 1.0) {
            // The window is an await: the screen can be replaced inside it. A
            // verdict about the pipeline that WAS playing must not stand down
            // the successor's epoch or rebind its surface.
            guard lifecycleRecovery.epoch == epoch,
                  warmResumeLease.map({ isCurrentOwner($0) }) ?? true else {
                PlayerLog.log(
                    "[Lifecycle] epoch=\(epoch) warm-resume verdict discarded — ownership moved"
                )
                return
            }
            // The pipeline survived; only the ATTACHMENT may not have. A
            // backgrounded drawable is exactly the case where audio keeps
            // running over a dead surface, so rebind before standing down.
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
        // Every backend, not just Demand: the fence is only followable when it carries a live ticket, and a
        // token-0 fence was what let an unrelated reopen re-stamp somebody else's epoch.
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
            // The existing runtime/manual ticket owns the one backend open.
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
            // A background reload may restore audio/decoder but cannot prove
            // the inline drawable exists; foreground consumes this rebind.
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
