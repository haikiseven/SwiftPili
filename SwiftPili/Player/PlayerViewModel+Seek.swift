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

    func seek(
        to requestedTime: TimeInterval,
        isRestore: Bool = false,
        settlement: (@MainActor @Sendable (SeekSettlement) -> Void)? = nil
    ) {
        guard PlayerTransportControlPolicy.allowsSeek(
            whileUnavailable: unavailability != nil
        ) else {
            PlayerLog.log(
                "[Player] seek ignored — no playable stream " +
                    "(\(unavailability?.rawValue ?? "?"))"
            )
            settlement?(.failed)
            return
        }
        let replacesStreamRecovery = !isRestore && streamRecoveryOwnsWork
        if !isRestore {
            retireStreamRecovery(reason: "seek")
            retireCDNSwitchForNewIntent()
        }
        if !isRestore, let recoveryCover {
            clearRecoveryCover(matching: recoveryCover.identity)
        }
        danmakuSeekRequestSerial &+= 1
        let danmakuRequestSerial = danmakuSeekRequestSerial
        resetMultiConnectionRate()
        publishMultiConnectionDisplay(rate: nil)
        let time = admittedSeekTarget(requestedTime)

        PlayerLog.log("[Player] seek → \(String(format: "%.1f", time)) (from=\(String(format: "%.1f", mediaTime)) playing=\(isPlaying) buffering=\(isBuffering))")
        if !isRestore {
            StartupTrace.abort("seek-before-first-frame", token: startupTraceToken)
        }
        let wasNaturallyEnded = playbackTerminalState == .ended
        if !isRestore,
           wasNaturallyEnded,
           usesDemandPresentationContinuity {
            dispatchDemandPresentation(.explicitReplay)
        }
        if !isRestore, wasNaturallyEnded {
            rearmHistoryReportingAfterCompletion()
        }
        playbackTerminalState = .active
        clearNearEndStall()
        lastSeekRequest = time
        settledSeekDisplaySample = nil
        invalidateBufferedDisplayForSeek()
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
            settlement?(.handedOff)
            return
        }

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
            if !isRestore {
                SeekTrace.begin(
                    target: time,
                    from: mediaTime,
                    path: backendKind == .vlc ? "set_time" : "native"
                )
            }
        }

        pendingSeekTarget = time
        pendingSeekTask?.cancel()
        pendingSeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let target = self.pendingSeekTarget else { return }
            PlayerLog.log("[Player] ⚠️ seek to \(String(format: "%.1f", target)) NOT settled after 10s — mediaTime=\(String(format: "%.1f", self.mediaTime)) buffering=\(self.isBuffering)")
        }

        let danmakuBackendIdentity = ObjectIdentifier(backend)
        let danmakuBackendGeneration = backend.runtimeGeneration
        let danmakuOwnerGeneration = ownerLeaseGeneration
        let danmakuOwner = ownerKey
        let danmakuSession = danmakuSessionLedger.liveSession(for: currentCid)
        let danmakuURL = currentURL
        let seekLoadGeneration = loadGeneration
        performNativeSeek(to: time) { [weak self] finished in
            guard let self, self.loadGeneration == seekLoadGeneration,
                  self.danmakuSeekRequestSerial == danmakuRequestSerial,
                  self.nativeSeekCompletedRequestSerial != danmakuRequestSerial,
                  ObjectIdentifier(self.backend) == danmakuBackendIdentity,
                  self.backend.runtimeGeneration == danmakuBackendGeneration,
                  self.ownerKey == danmakuOwner,
                  self.currentURL == danmakuURL else { return }
            self.nativeSeekCompletedRequestSerial = danmakuRequestSerial
            self.invalidateBufferedDisplayForSeek()
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
            self.pushNowPlayingPlayback()
            self.isBuffering = false
            if self.rebaseDemandVideoSuspensionAfterSeek(resumesPlayback: self.canAutoRevive) {
            } else if self.canAutoRevive {
                self.backend.play()
            }
            self.resumeDeferredDemandVideoSuspensionIfNeeded()
            self.handleNativeAudioOutputChange()
            settlement?(.arrived)
        }
        isBuffering = true
    }

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

    func pinSettledSeekDisplay(at position: TimeInterval) {
        guard position.isFinite, position >= 0 else { return }
        settledSeekDisplaySample = SettledSeekDisplaySample(
            position: position, loadGeneration: loadGeneration, backend: ObjectIdentifier(backend),
            backendGeneration: backend.runtimeGeneration, owner: ownerKey, url: currentURL
        )
    }

    func refreshBufferedDisplayAfterSeek() {
        guard mode == .vod else { return }
        invalidateBufferedDisplayForSeek()
        publishBufferedTime(backend.playableTime, display: { backend.bufferDisplaySample }, at: CACurrentMediaTime())
    }

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
                settlement?(.handedOff)
                return
            }
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
                try? await Task.sleep(for: .milliseconds(32))
                guard !Task.isCancelled,
                      requestOwnerLease.map({ self.isCurrentOwner($0) }) ?? false,
                      self.isCurrentFreezeFrame(coverIdentity)
                else {
                    settlement?(.handedOff)
                    return
                }
                SeekTrace.mark("snapshot-done")
            } else {
                SeekTrace.mark("snapshot-skipped")
            }
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
                await self.loadVOD(aid: aid, cid: cid, quality: self.currentQuality,
                                   source: self.currentSource, preservePlayState: true,
                                   ownerLease: requestOwnerLease, streamRetryID: streamRetryID)
                settlement?(.handedOff)
            } else {
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
