import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    private func performNativeSeek(
        to time: TimeInterval, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        backend.seek(to: time, completion: completion)
    }

    func logDemandSeekTrace(
        phase: String,
        target: TimeInterval,
        ready: Bool? = nil,
        result: Bool? = nil
    ) {
        guard backendKind == .demandPaced else { return }
        let safeTarget = target.isFinite ? max(0, target) : 0
        let pending = backend.pendingSeekTarget ?? -1
        let safePending = pending.isFinite ? pending : -1
        let readyValue = ready.map { $0 ? 1 : 0 } ?? -1
        let resultValue = result.map { $0 ? 1 : 0 } ?? -1
        PlayerLog.log(
            "[PathASeekViewModel] phase=\(phase) playerGen=\(playerGeneration) " +
            "loadGen=\(loadGeneration) backendGen=\(backend.runtimeGeneration) " +
            "target=\(String(format: "%.3f", safeTarget)) " +
            "pending=\(String(format: "%.3f", safePending)) " +
            "ready=\(readyValue) result=\(resultValue)"
        )
    }

    /// Settle exactly once as arrived, failed or handed off; a replacement open owns its own readiness.
    func seek(
        to requestedTime: TimeInterval,
        isRestore: Bool = false,
        settlement: (@MainActor @Sendable (SeekSettlement) -> Void)? = nil
    ) {
        guard PlayerTransportControlPolicy.allowsSeek(
            whileUnavailable: unavailability != nil
        ) else {
            // Not "is final": a retryable `streamUnreachable` blocks a seek too, because there is no stream to
            // seek IN, not because the refusal is settled.
            PlayerLog.log(
                "[Player] seek ignored — no playable stream " +
                    "(\(unavailability?.rawValue ?? "?"))"
            )
            settlement?(.failed)
            return
        }
        let replacesStreamRecovery = !isRestore && streamRecoveryOwnsWork
        // A new user positioning operation also supersedes queued CDN work,
        // before the asynchronous native seek can advance its session identity.
        if !isRestore {
            retireStreamRecovery(reason: "seek")
            retireCDNSwitchForNewIntent()
        }
        // A new user positioning operation retires this recovery picture;
        // its native seek can advance session generation without another ready.
        if !isRestore, let recoveryCover {
            clearRecoveryCover(matching: recoveryCover.identity)
        }
        danmakuSeekRequestSerial &+= 1
        let danmakuRequestSerial = danmakuSeekRequestSerial
        resetMultiConnectionRate()
        publishMultiConnectionDisplay(rate: nil)
        // Admitted before anything else reads it, so the log line, the pin, the durable resume target and the
        // reopen all describe the position that will actually be served.
        let time = admittedSeekTarget(requestedTime)

        PlayerLog.log("[Player] seek → \(String(format: "%.1f", time)) (from=\(String(format: "%.1f", mediaTime)) playing=\(isPlaying) buffering=\(isBuffering))")
        // A cold session that has not shown a frame yet stops being a cold-start measurement the moment the
        // USER asks for a different position: whatever frame arrives next is the seek's, and folding it into
        // `ttff-proxy` would quietly inflate the startup distribution with seek time.
        if !isRestore {
            StartupTrace.abort("seek-before-first-frame", token: startupTraceToken)
        }
        let wasNaturallyEnded = playbackTerminalState == .ended
        // Clear only the coordinator's terminal presentation admission so the seek can produce its normal
        // runtime/presentation effects.
        if !isRestore,
           wasNaturallyEnded,
           usesDemandPresentationContinuity {
            dispatchDemandPresentation(.explicitReplay)
        }
        // The user is watching content again that the finished marker has already closed the books on.
        if !isRestore, wasNaturallyEnded {
            rearmHistoryReportingAfterCompletion()
        }
        playbackTerminalState = .active
        clearNearEndStall()
        lastSeekRequest = time
        settledSeekDisplaySample = nil
        invalidateBufferedDisplayForSeek()
        // A seek is intent: it must survive a reopen/recovery that interrupts
        // its travel. A near-0 target clears the durable intent (starting at
        // the head is then deliberate, never a fallback).
        armDurableResumeTarget(time > 2 ? time : nil, source: "seek")
        PlayerLog.log("[Player] seek-start target=\(String(format: "%.1f", time))s")
        logDemandSeekTrace(phase: "request", target: time, ready: backend.isReadyToPlay)
        updateDemandVideoLivenessContext()

        if replacesStreamRecovery {
            armDurableResumeTarget(time, source: "seek")
            reopenForSeek(to: time, settlement: settlement)
            return
        }

        guard nativeSeekIsReady else {
            PlayerLog.log("[Player] seek before readyToPlay — deferring \(String(format: "%.1f", time))s")
            resumeAtTime = time
            resumeIsFromHistory = false
            pendingSeekTarget = time
            // The armed resume is consumed by the next `readyToPlay`, which owns
            // the travel and its outcome from there.
            settlement?(.handedOff)
            return
        }

        // Every VOD seek reopens the demuxer AT the target (reopenForSeek).
        if mode.isSeekable, backendKind == .vlc, (mode == .offline || !ExperimentalSettingsPolicy.diagnosticBool(
            key: "settime_seek_experiment", saved: ExperimentalSettingsPolicy.diagnosticOverrides.setTimeSeek
        )) {
            reopenForSeek(to: time, isRestore: isRestore, settlement: settlement)
            return
        }
        if mode == .vod {
            PlayerLog.log(
                backendKind == .vlc
                    ? "[Player] ⚡︎ seek → set_time \(String(format: "%.1f", time))s (experiment; no reopen)"
                    : "[Player] ⚡︎ seek → \(backendKind.shortLabel) native \(String(format: "%.1f", time))s (no reopen)"
            )
            // Live seeks stay unmeasured — no seek bar, defensive path only.
            if !isRestore {
                SeekTrace.begin(
                    target: time,
                    from: mediaTime,
                    path: backendKind == .vlc ? "set_time" : "native"
                )
            }
        }

        // A live stream has no stable signed URL to reopen at a position, so in-demuxer set_time is the only
        // option; on failure it holds and lets §2.5's ladder own recovery.
        pendingSeekTarget = time
        pendingSeekTask?.cancel()
        pendingSeekTask = Task { [weak self] in
            // Longer than the backend's 8s settlement ceiling, and REPORT-ONLY.
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let target = self.pendingSeekTarget else { return }
            PlayerLog.log("[Player] ⚠️ seek to \(String(format: "%.1f", target)) NOT settled after 10s — mediaTime=\(String(format: "%.1f", self.mediaTime)) buffering=\(self.isBuffering)")
        }

        // A Seek changes Demand's media-work generation itself. Fence its
        // owning backend/load, owner and source, not the pre-seek work number.
        let danmakuBackendIdentity = ObjectIdentifier(backend)
        let danmakuBackendGeneration = backend.runtimeGeneration
        let danmakuOwnerGeneration = ownerLeaseGeneration
        let danmakuOwner = ownerKey
        let danmakuSession = danmakuSessionLedger.liveSession(for: currentCid)
        let danmakuURL = currentURL
        let seekLoadGeneration = loadGeneration
        performNativeSeek(to: time) { [weak self] finished in
            // A same-source rehost can renew the screen lease and renderer
            // generation without replacing this native seek's source/load.
            // Danmaku keeps its separate lease/session checks below.
            guard let self, self.loadGeneration == seekLoadGeneration,
                  self.danmakuSeekRequestSerial == danmakuRequestSerial,
                  self.nativeSeekCompletedRequestSerial != danmakuRequestSerial,
                  ObjectIdentifier(self.backend) == danmakuBackendIdentity,
                  self.backend.runtimeGeneration == danmakuBackendGeneration,
                  self.ownerKey == danmakuOwner,
                  self.currentURL == danmakuURL else { return }
            self.nativeSeekCompletedRequestSerial = danmakuRequestSerial
            self.invalidateBufferedDisplayForSeek()
            // VLC's settle already marked `arrived` before invoking this (the seen-dedup makes the repeat a
            // no-op), so this is not a second completion there.
            if self.backendKind != .vlc {
                if finished {
                    SeekTrace.mark("arrived")
                } else {
                    SeekTrace.abort("native-seek-failed")
                }
            }
            self.logDemandSeekTrace(
                phase: "completion",
                target: time,
                ready: self.backend.isReadyToPlay,
                result: finished
            )
            let settledPosition = finished ? self.nativeSeekSettledPosition : nil
            self.settleNativeSeekDisplay(at: settledPosition)
            guard finished else {
                self.settleFailedNativeSeek(at: time, settlement: settlement)
                return
            }
            if let settledPosition, settledPosition.isFinite, settledPosition >= 0,
               self.danmakuSeekRequestSerial == danmakuRequestSerial,
               self.danmakuSettledSeekRequestSerial != danmakuRequestSerial,
               ObjectIdentifier(self.backend) == danmakuBackendIdentity,
               self.backend.runtimeGeneration == danmakuBackendGeneration,
               self.ownerLeaseGeneration == danmakuOwnerGeneration,
               self.ownerKey == danmakuOwner,
               let danmakuSession,
               self.danmakuSessionLedger.liveSession(for: self.currentCid) == danmakuSession,
               self.currentURL == danmakuURL {
                self.danmakuSettledSeekRequestSerial = danmakuRequestSerial
                self.noteDanmakuSeekSettled(at: settledPosition)
            }
            // A completed seek is a timing edge. Republish the existing
            // display-time authority only after the backend settled, so the
            // system card cannot claim success for a rejected target.
            self.pushNowPlayingPlayback()
            // A settled seek always ends the seek spinner, even when playback
            // is paused/interrupted (canAutoRevive false) — otherwise a paused
            // seek leaves the spinner stuck over the paused frame.
            self.isBuffering = false
            if self.rebaseDemandVideoSuspensionAfterSeek(resumesPlayback: self.canAutoRevive) {
                // The local video-lane suspension owns resumption; a generic
                // play is refused while it holds the lane.
            } else if self.canAutoRevive {
                self.backend.play()
            }
            self.resumeDeferredDemandVideoSuspensionIfNeeded()
            self.handleNativeAudioOutputChange()
            settlement?(.arrived)
        }
        isBuffering = true
    }

    /// Settle ViewModel presentation and seek mute before any transport restart.
    private func settleNativeSeekDisplay(at position: TimeInterval?) {
        let arrived = position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let arrived { pinSettledSeekDisplay(at: arrived) }
        pendingSeekTarget = nil
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        setMute(.seekTravel, false)
        if arrived != nil { refreshBufferedDisplayAfterSeek() }
        refreshAmbientSelection()
    }

    /// Use the acknowledged position until the next ordinary display clock publication.
    func pinSettledSeekDisplay(at position: TimeInterval) {
        guard position.isFinite, position >= 0 else { return }
        settledSeekDisplaySample = SettledSeekDisplaySample(
            position: position, loadGeneration: loadGeneration, backend: ObjectIdentifier(backend),
            backendGeneration: backend.runtimeGeneration, owner: ownerKey, url: currentURL
        )
    }

    /// Demand's commit tick precedes settlement. A paused session may emit no later tick.
    func refreshBufferedDisplayAfterSeek() {
        guard mode == .vod else { return }
        invalidateBufferedDisplayForSeek()
        publishBufferedTime(backend.playableTime, display: { backend.bufferDisplaySample }, at: CACurrentMediaTime())
    }

    /// A seek changes the native session generation; rebind an existing video-lane suspension to that
    /// generation.
    private func rebaseDemandVideoSuspensionAfterSeek(resumesPlayback: Bool) -> Bool {
        guard usesDemandPresentationContinuity else { return false }
        switch lifecycleRecovery.presentationPhase {
        case .warmSuspendingForAudioOnly, .warmSuspended:
            break
        default:
            return false
        }
        guard let fence = makeDemandPresentationFence(
            epoch: lifecycleRecovery.ensureDemandPresentationEpoch()
        ) else { return false }
        _ = dispatchDemandPresentation(.videoLaneSeekCommitted(
            fence: fence,
            resumesPlayback: resumesPlayback
        ))
        return true
    }

    /// Reopen VLC at the target using the current signed URL; a successor owns arrival and superseded work
    /// reports handoff.
    private func reopenForSeek(
        to time: TimeInterval,
        isRestore: Bool = false,
        settlement: (@MainActor @Sendable (SeekSettlement) -> Void)? = nil
    ) {
        let requestOwnerLease = currentOwnerLease
        let seekRequestSerial = danmakuSeekRequestSerial
        let seekLoadGeneration = loadGeneration
        let streamRetryID = isRestore ? streamRecovery?.requestID : nil
        let backward = time < backend.openedAtPosition - 0.5
        PlayerLog.log("[Player] ↩︎ seek → reopening at \(String(format: "%.1f", time))s\(backward ? " (before open pos \(String(format: "%.1f", backend.openedAtPosition))s)" : "")")
        // The restore seek is the same case arriving through seek(to:) — the durl fallback opens at 0 and
        // travels to the resume point from readyToPlay — so it must not open a seek session either.
        if !isRestore {
            SeekTrace.begin(target: time, from: mediaTime, path: "reopen")
        }
        pendingSeekTarget = time
        resumeAtTime = time
        resumeIsFromHistory = false
        isBuffering = true
        reopenSeekTask?.cancel()
        reopenSeekTask = Task { @MainActor [weak self] in
            guard let self else { settlement?(.handedOff); return }
            guard requestOwnerLease.map({ self.isCurrentOwner($0) }) ?? false else {
                // Ownership moved before this reopen ran; the successor owns the
                // transport and its readiness.
                settlement?(.handedOff)
                return
            }
            // Cover the reopen with a freeze frame, or the seek flashes black
            // for the length of the demuxer open.
            if let snapshot = await self.backend.thumbnailAtCurrentTime() {
                guard !Task.isCancelled,
                      requestOwnerLease.map({ self.isCurrentOwner($0) }) ?? false
                else {
                    settlement?(.handedOff)
                    return
                }
                let coverIdentity = self.installFreezeFrame(
                    snapshot,
                    awaitingFreshProof: false
                )
                // Let SwiftUI COMPOSITE the cover before the vout is torn down.
                try? await Task.sleep(for: .milliseconds(32))
                // Cancellation is the ONLY supersede signal: a newer seek and stop() both cancel this task.
                guard !Task.isCancelled,
                      requestOwnerLease.map({ self.isCurrentOwner($0) }) ?? false,
                      self.isCurrentFreezeFrame(coverIdentity)
                else {
                    // Superseded by a newer seek, or by stop(). Not a failure of
                    // the position — a transfer of who is travelling to one.
                    settlement?(.handedOff)
                    return
                }
                SeekTrace.mark("snapshot-done")
            } else {
                // No freeze frame to composite — the reopen is not waiting on the
                // snapshot or the display hop, so its cost is a different shape.
                SeekTrace.mark("snapshot-skipped")
            }
            // Revalidate cancellation, owner and retry identity after either snapshot outcome.
            guard !Task.isCancelled,
                  self.danmakuSeekRequestSerial == seekRequestSerial,
                  self.loadGeneration == seekLoadGeneration,
                  requestOwnerLease.map({ self.isCurrentOwner($0) }) ?? false,
                  streamRetryID.map(self.acceptsStreamRequest) ?? true else {
                settlement?(.handedOff)
                return
            }
            SeekTrace.mark("reopen-issued")
            if let url = self.currentURL, Self.urlStillFresh(url) {
                self.playURL(url, audioURL: self.isDASHMode ? self.currentDASHAudioURL : nil,
                    startAt: time, isSeekReopen: true, streamRetryID: streamRetryID)
                settlement?(.handedOff)
            } else if let aid = self.currentAid, let cid = self.currentCid {
                // Signature expired — only a fresh playurl can reach it.
                await self.loadVOD(aid: aid, cid: cid, quality: self.currentQuality,
                                   source: self.currentSource, preservePlayState: true,
                                   ownerLease: requestOwnerLease, streamRetryID: streamRetryID)
                settlement?(.handedOff)
            } else {
                // Nothing left to reopen: no fresh URL and no VOD identity to
                // refetch one with. Whoever was waiting on this position has to
                // hear that it is not coming.
                PlayerLog.log(
                    "[Player] ↩︎ seek reopen abandoned — no fresh URL and no VOD identity"
                )
                self.resumeAtTime = nil
                self.settleNativeSeekDisplay(at: nil)
                self.isBuffering = false
                SeekTrace.abort("no-reopen-source")
                settlement?(.failed)
            }
        }
        bindStreamRestoreTask(requestID: streamRetryID)
    }

    private func admittedSeekTarget(_ requestedTime: TimeInterval) -> TimeInterval {
        let time = SeekTargetAdmission.admissibleTarget(
            requested: requestedTime,
            duration: duration,
            reserve: backend.seekLaunchReserve
        )
        if SeekTargetAdmission.wasClamped(requested: requestedTime, admitted: time) {
            PlayerLog.log(
                "[Player] seek target \(String(format: "%.3f", requestedTime))s is inside " +
                    "the engine's end-of-media reserve " +
                    "(\(String(format: "%.3f", backend.seekLaunchReserve))s of " +
                    "\(String(format: "%.3f", duration))s) — admitted " +
                    "\(String(format: "%.3f", time))s"
            )
        }
        return time
    }

    /// If stream recovery took over, leave its spinner and outcome under the replacement operation.
    private func settleFailedNativeSeek(
        at time: TimeInterval, settlement: (@MainActor @Sendable (SeekSettlement) -> Void)?
    ) {
        if streamRecoveryOwnsWork {
            isBuffering = streamRecoveryMayRun
            updateIsPlaying(transportRunning: false)
            settlement?(.handedOff)
            return
        }
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        PlayerLog.log("[Player] ❌ native seek to \(String(format: "%.1f", time)) failed")
        settlement?(.failed)
    }
}
