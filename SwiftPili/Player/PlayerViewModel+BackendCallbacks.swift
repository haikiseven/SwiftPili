import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func setupBackendCallbacks() {
        installEqualizerMaintenanceAdmission()
        installAudioOutputObservation()
        let callbackBackendIdentity = ObjectIdentifier(backend as AnyObject)
        backend.setPiPTransportEdgeHandler { [weak self] edge in
            guard let self,
                  ObjectIdentifier(self.backend as AnyObject) == callbackBackendIdentity else {
                return
            }
            self.handlePiPTransportEdge(edge)
        }
        backend.setObservedPiPLeaseChangeHandler { [weak self] active in
            self?.handleObservedPiPLeaseChange(active)
        }
        backend.setDemandPiPNativeTransitionHandler { [weak self] transition in
            self?.handleDemandPiPNativeTransition(transition)
        }
        backend.setDemandPiPRestoreRequestHandler { [weak self] token in
            self?.handleDemandPiPRestoreRequest(token: token)
        }
        backend.setDemandPresentationProofHandler { [weak self] sample in
            guard let self,
                  ObjectIdentifier(self.backend) == callbackBackendIdentity else { return }
            self.handleDemandPresentationSample(sample)
            self.sampleAmbientLiveFrameIfNeeded(at: CACurrentMediaTime(), force: true)
        }
        backend.setDemandPresentationFailureHandler { [weak self] failure, renderGeneration in
            self?.handleDemandPresentationFailure(
                failure,
                renderGeneration: renderGeneration
            )
        }
        backend.setRuntimeFaultHandler { [weak self] fault in
            self?.handleDemandRuntimeFault(fault)
        }
        backend.onStateChanged = { [weak self] event in
            guard let self, !self.invalidatedBackendResources,
                  ObjectIdentifier(self.backend as AnyObject) == callbackBackendIdentity else { return }
            switch event {
            case .readyToPlay:
                if self.streamRecoveryOwnsWork, self.streamRecovery?.requestID == nil { return }
                self.noteStreamReady()
                self.bindRecoveryCoverFromReadyBackend()
                self.cdnFrameCover?.bindReady(self.backend)
                self.mediaResetRecovery.settle(loadGeneration: self.loadGeneration, succeeded: true)
                if self.usesDemandPresentationContinuity {
                    let epoch = self.lifecycleRecovery.ensureDemandPresentationEpoch()
                    if let fence = self.makeDemandPresentationFence(epoch: epoch) {
                        let currentSession = self.lifecycleRecovery.presentationPhase
                            .fence?.sessionGeneration
                        if currentSession != fence.sessionGeneration {
                            self.beginDemandPresentationDebt(fence)
                            self.dispatchDemandPresentation(.installInline(fence: fence))
                        }
                        if let snapshot = self.renderAttachment?.presentationSnapshot {
                            self.backend.noteDemandInlineAttachment(
                                renderGeneration: self.playerGeneration,
                                isVisible: snapshot.isVisible,
                                boundsUsable: snapshot.boundsUsable
                            )
                        }
                    }
                }
                guard !self.terminalOpenFailure else {
                    if let cover = self.recoveryCover { self.clearRecoveryCover(matching: cover.identity) }
                    self.updateIsPlaying(transportRunning: false)
                    self.acknowledgeLifecycleReadiness(.terminalFailure)
                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
                    PlayerLog.log("[Player] ignored readyToPlay after terminal open failure")
                    return
                }
                PlayerLog.log("[Player] state → readyToPlay (t=\(String(format: "%.1f", self.mediaTime)))")
                self.isBuffering = false
                self.updateIsPlaying(transportRunning: true)

                if let track = self.backend.videoTracks().first {
                    let w = Int(track.naturalSize.width)
                    let h = Int(track.naturalSize.height)
                    if w > 0, h > 0 {
                        self.stats.resolution = "\(w)×\(h)"
                        self.applyVideoGeometry(track.naturalSize)
                    }
                }

                var recoveryOwesRestoreSeek = false
                if let resume = self.resumeAtTime {
                    self.resumeAtTime = nil
                    let t = resume
                    let tolerance: TimeInterval = self.streamRecovery != nil ? 0.05 : 2
                    let loadedAtTarget = abs(self.lastLoadStartPosition - t) < tolerance
                    if abs(t) < tolerance {
                        PlayerLog.log("[Player] readyToPlay: resume position ≈ 0 — playing from start")
                    } else if loadedAtTarget {
                        PlayerLog.log("[Player] readyToPlay: loaded at target \(String(format: "%.1f", t))s — seek skipped")
                    } else {
                        recoveryOwesRestoreSeek = true
                        self.pendingSeekTarget = t
                        let readyBackendGeneration = self.backend.runtimeGeneration
                        let readyOwnerKey = self.ownerKey
                        let readyOwnerLeaseGeneration = self.ownerLeaseGeneration
                        PlayerLog.log("[Player] readyToPlay: seeking to saved position → \(String(format: "%.1f", t))s")
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.backend.runtimeGeneration == readyBackendGeneration,
                                  self.ownerKey == readyOwnerKey,
                                  self.ownerLeaseGeneration == readyOwnerLeaseGeneration else {
                                return
                            }
                            self.seek(to: t, isRestore: true) { [weak self] settlement in
                                guard let self else { return }
                                switch settlement {
                                case .arrived:
                                    self.markAmbientVideoLoaded()
                                    self.acknowledgeLifecycleReadiness(.transportReady)
                                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendReady)
                                case .failed:
                                    self.acknowledgeLifecycleReadiness(.terminalFailure)
                                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
                                case .handedOff:
                                    PlayerLog.log(
                                        "[Player] restore seek handed off to a successor open — " +
                                            "fence follows that load"
                                    )
                                }
                            }
                        }
                    }
                }

                if !recoveryOwesRestoreSeek {
                    self.markAmbientVideoLoaded()
                    self.resumeDeferredDemandVideoSuspensionIfNeeded()
                    self.handleNativeAudioOutputChange()
                    self.acknowledgeLifecycleReadiness(.transportReady)
                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendReady)
                } else {
                    self.refreshAmbientSelection()
                }
                self.duration = self.backend.duration
                self.pushNowPlayingPlayback()

            case .buffering:
                if self.playbackIntent == .playing, !self.audioSessionInterrupted {
                    self.beginBackgroundPlaybackRestoration(reason: "buffering")
                }
                self.budget.interruptStreamStability()
                if !self.isBuffering { self.isBuffering = true }
                self.updateIsPlaying(transportRunning: false)
                self.syncDanmakuTransport()

            case .bufferFinished:
                if self.streamRecoveryOwnsWork, self.streamRecovery?.requestID == nil { return }
                guard !self.terminalOpenFailure else {
                    self.updateIsPlaying(transportRunning: false)
                    return
                }
                self.isBuffering = false
                if self.playbackIntent == .playing, !self.playbackEnded, !self.backend.isPlaying {
                    self.backend.play()
                }
                self.updateIsPlaying(transportRunning: self.backend.isPlaying)
                self.resumeDeferredDemandVideoSuspensionIfNeeded()
                self.handleNativeAudioOutputChange()
                self.syncDanmakuTransport()

            case .paused:
                self.updateIsPlaying(transportRunning: false)
                self.publishBufferedTime(
                    self.backend.playableTime, display: { self.backend.bufferDisplaySample },
                    at: CACurrentMediaTime()
                )
                if !self.playbackTerminalSettlement.suppressesPauseProjection,
                   !self.currentPlaybackTerminalState.isTerminal {
                    self.pushNowPlayingPlayback()
                }

            case .playedToTheEnd:
                self.admitNaturalPlaybackEnd()

            case .error(let error):
                if let engine = error as? MediaEngineError,
                   case .unsupportedLiveSource(let source, let ownerGeneration, _) = engine {
                    guard source.ownerLease == self.currentOwnerLease,
                          ownerGeneration == self.backend.runtimeGeneration else { return }
                    if self.handOffUnsupportedDemandLiveSource(source.kind) { return }
                }
                if let engine = error as? MediaEngineError, case .transportFailed(let failure) = engine,
                   self.handleStreamTransportFailure(failure) { return }
                let cancellation = error is CancellationError
                    || StreamTransportFailure.preserving(error, stage: .mediaOpen)?.isCancellation == true
                if cancellation, self.streamRecoveryOwnsWork {
                    self.suspendStreamRecovery()
                    return
                }
                self.backgroundExecution.end(reason: "backend-error")
                self.retireStreamRecovery(reason: "nontransient-backend")
                if self.cdnFrameCover?.ownsLoad(self.backend) == true { self.clearFreezeFrame() }
                if self.mediaResetRecovery.request?.opening == true,
                   self.mediaResetRecovery.request?.loadGeneration == self.loadGeneration {
                    self.mediaResetRecovery.settle(loadGeneration: self.loadGeneration, succeeded: false)
                    self.playbackIntent = .pausedByUser
                    self.audioSessionPolicy.requireUserPlay()
                    self.error = String(localized: "Playback failed. Tap Retry.")
                    self.isBuffering = false
                    self.suspendPlayback()
                    return
                }
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    if let cover = self.recoveryCover {
                        self.clearRecoveryCover(matching: cover.identity)
                    }
                    self.acknowledgeLifecycleReadiness(.terminalFailure)
                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
                    return
                }
                let hostIndependent = (error as? MediaEngineError)?.isHostIndependent ?? false
                guard self.mode.usesOnlineVODServices, !hostIndependent else {
                    let prefix = hostIndependent
                        ? "[Player] engine error is host-independent — no CDN switch"
                        : self.mode == .offline
                        ? "[Player] offline input error — local retry required"
                        : "[Player] live input error — stream retry required"
                    self.settleTerminalFailure(TerminalFailurePayload(
                        message: PlaybackFailureMessage.text(for: error),
                        retireStreamRecoveryReason: nil,
                        logMessage: "\(prefix) (\(error.localizedDescription))"
                    ))
                    return
                }
                PlayerLog.log("[Player] input error (\(error.localizedDescription)) — trying another host")
                self.attemptCDNSwitchAfterTransportError(error)
            }
        }

        backend.onTickWithGeneration = { [weak self] currentTime, totalTime, generation, traceToken in
            guard let self else { return }
            let tickSpan = UIHitchMonitor.beginSpan("tick.vm")
            defer { UIHitchMonitor.endSpan(tickSpan) }
            guard ObjectIdentifier(self.backend) == callbackBackendIdentity,
                  generation == self.backend.runtimeGeneration else { return }
            if self.streamRecoveryOwnsWork, self.streamRecovery?.requestID == nil { return }
            guard !self.terminalOpenFailure else {
                self.updateIsPlaying(transportRunning: false)
                return
            }
            if self.backendKind != .demandPaced
                || currentTime > self.mediaTime + 0.000_5 {
                StartupTrace.mark("first-clock-tick", token: traceToken)
                self.notePresentationStarted()
            }
            self.noteBackgroundPlaybackProgress(currentTime)
            let now = CACurrentMediaTime()
            let liveSpan = UIHitchMonitor.beginSpan("tick.live")
            self.updateDemandVideoLivenessContext()
            UIHitchMonitor.endSpan(liveSpan)

            let seeking = self.isSeekInFlight
            self.setMute(.seekTravel, seeking)
            if seeking, !self.isBuffering { self.isBuffering = true }

            if now - self.lastDisplayUpdate >= 0.25 {
                let advanced = currentTime > self.mediaTime + 0.05
                if advanced, let target = self.durableResumeTarget {
                    let forward = target >= self.durableResumeArmedFrom
                    let arrived = forward
                        ? currentTime >= target - 2
                        : currentTime <= target + 2
                    if arrived {
                        self.durableResumeTarget = nil
                        PlayerLog.log("[Player] seek-commit arrived=\(String(format: "%.1f", currentTime))s target=\(String(format: "%.1f", target))s")
                    } else if now - self.durableResumeArmedAtWall > Self.durableResumeStaleness {
                        self.durableResumeTarget = nil
                        PlayerLog.log("[Player] resume-target expired unarrived target=\(String(format: "%.1f", target))s clock=\(String(format: "%.1f", currentTime))s")
                    }
                }
                self.noteStreamProgress(currentTime, at: now)
                self.mediaTime = currentTime
                if self.settledSeekDisplaySample != nil { self.settledSeekDisplaySample = nil }
                self.duration = totalTime
                if advanced, self.backend.isPlaying, !seeking {
                    if self.isBuffering {
                        self.isBuffering = false
                    }
                    if !self.isPlaying {
                        self.updateIsPlaying(transportRunning: true)
                    }
                }

                if seeking || self.playbackEnded {
                    self.clearNearEndStall()
                } else if self.backend.isPlaying || self.isPlaying {
                    self.noteNearEndMediaSample(currentTime, duration: totalTime)
                } else if self.nearEndStallWallStart != nil,
                          !NearEndClockPolicy.isInNearEndWindow(media: currentTime, duration: totalTime) {
                    self.clearNearEndStall()
                }
                let replacementFrameIsProven = self.freezeFrameAwaitingFreshProof
                    ? (self.backendKind != .demandPaced && self.stats.fps >= 1)
                    : true
                if self.freezeFrame != nil,
                   (replacementFrameIsProven
                    && self.pendingSeekTarget == nil
                    && !self.isBuffering)
                   || (!self.freezeFrameAwaitingFreshProof
                       && now - self.freezeFrameSetAt > Self.freezeFrameSafetyTimeout) {
                    self.clearFreezeFrame()
                }
                if self.pendingSeekTarget != nil, !seeking, !self.isBuffering {
                    self.pendingSeekTarget = nil
                }
                if !seeking, self.pendingSeekTarget == nil, self.resumeAtTime == nil {
                    self.ambientSelectionMediaTime = currentTime
                }
                self.refreshAmbientSelection()
                let danmakuSpan = UIHitchMonitor.beginSpan("tick.dm")
                self.noteDanmakuMediaTick(currentTime)
                UIHitchMonitor.endSpan(danmakuSpan)
                self.lastDisplayUpdate = now
            }
            self.sampleAmbientLiveFrameIfNeeded(at: now)
            self.lastOnPlayAt = now
            let bufferSpan = UIHitchMonitor.beginSpan("tick.buf")
            self.publishBufferedTime(
                self.backend.playableTime, display: { self.backend.bufferDisplaySample }, at: now
            )
            UIHitchMonitor.endSpan(bufferSpan)

            let skipSpan = UIHitchMonitor.beginSpan("tick.subs")
            self.updateSubtitle(at: currentTime)
            self.autoSkipIfNeeded(at: currentTime)
            self.autoSkipSponsorIfNeeded(at: currentTime)
            UIHitchMonitor.endSpan(skipSpan)
            // Faster cadence while the stats overlay is visible; enhancement telemetry is a cheap
            // window summary, so it refreshes at 4 Hz there.
            if now - (self.lastDropSample?.at ?? 0) >= (self.showStats ? 0.5 : 1.0) {
                self.lastEnhancementTelemetryRefresh = now
                self.updateDynamicStats()
            } else if self.showStats, now - self.lastEnhancementTelemetryRefresh >= 0.25 {
                self.lastEnhancementTelemetryRefresh = now
                self.refreshVideoEnhancementTelemetry()
            }
        }

        backend.onBufferChanged = { [weak self] consumeTime in
            guard let self, !self.invalidatedBackendResources,
                  ObjectIdentifier(self.backend as AnyObject) == callbackBackendIdentity else { return }
            self.pendingBufferHealth = consumeTime
            if !self.isPlaying, !self.terminalOpenFailure {
                self.publishBufferedTime(
                    self.backend.playableTime, display: { self.backend.bufferDisplaySample },
                    at: CACurrentMediaTime()
                )
            }
        }
    }
}
