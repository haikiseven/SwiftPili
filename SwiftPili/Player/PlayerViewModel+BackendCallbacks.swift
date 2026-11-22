import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Fence backend events by their originating instance and generation before updating playback state.
    func setupBackendCallbacks() {
        installEqualizerMaintenanceAdmission()
        installAudioOutputObservation()
        let callbackBackendIdentity = ObjectIdentifier(backend as AnyObject)
        backend.setPiPTransportEdgeHandler { [weak self] edge in
            guard let self,
                  ObjectIdentifier(self.backend as AnyObject) == callbackBackendIdentity else {
                // The callback belongs to an outgoing backend instance. It is
                // stale even if a replacement happens to reuse the same raw
                // runtime-generation number.
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
                    // The load's own startPosition is the only honest signal — a CDN switch or resume with
                    // startAt=X already opened VLC there, and seeking again would restart the whole travel.
                    let tolerance: TimeInterval = self.streamRecovery != nil ? 0.05 : 2
                    let loadedAtTarget = abs(self.lastLoadStartPosition - t) < tolerance
                    if abs(t) < tolerance {
                        PlayerLog.log("[Player] readyToPlay: resume position ≈ 0 — playing from start")
                    } else if loadedAtTarget {
                        PlayerLog.log("[Player] readyToPlay: loaded at target \(String(format: "%.1f", t))s — seek skipped")
                    } else {
                        recoveryOwesRestoreSeek = true
                        // Publish the owed transaction before yielding.
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
                                    // Acking here would close it before the position exists; failing here
                                    // would put Retry over a reopen that is working.
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
                // Edge-triggered write only: `.buffering` republishes on every buffering-progress tick, and
                // `isBuffering` is @Observable.
                if !self.isBuffering { self.isBuffering = true }
                self.updateIsPlaying(transportRunning: false)

            case .bufferFinished:
                if self.streamRecoveryOwnsWork, self.streamRecovery?.requestID == nil { return }
                guard !self.terminalOpenFailure else {
                    self.updateIsPlaying(transportRunning: false)
                    return
                }
                self.isBuffering = false
                // Guard on !playbackEnded: a trailing bufferFinished after
                // end-of-video must NOT restart the ended player from 0:00.
                if self.playbackIntent == .playing, !self.playbackEnded, !self.backend.isPlaying {
                    self.backend.play()
                }
                self.updateIsPlaying(transportRunning: self.backend.isPlaying)
                self.resumeDeferredDemandVideoSuspensionIfNeeded()
                self.handleNativeAudioOutputChange()

            case .paused:
                self.updateIsPlaying(transportRunning: false)
                self.publishBufferedTime(
                    self.backend.playableTime, display: { self.backend.bufferDisplaySample },
                    at: CACurrentMediaTime()
                )
                // Backend-originated pause (including interruption) is a
                // settled timing edge. It does not mutate playback intent;
                // only the direct PiP intent edge does that.
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
                    // A current lifecycle/runtime/manual open must still close its ticket; otherwise a
                    // cancelled open can permanently coalesce every later Retry.
                    self.acknowledgeLifecycleReadiness(.terminalFailure)
                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
                    return
                }
                // Before the first frame `switchCDN` refuses anyway, so this only ever reached the overlay by
                // way of a pointless attempt; after it, the swap blacklisted a working edge.
                let hostIndependent = (error as? MediaEngineError)?.isHostIndependent ?? false
                guard self.mode.usesOnlineVODServices, !hostIndependent else {
                    self.terminalOpenFailure = true
                    PlayerLog.log(
                        (hostIndependent
                            ? "[Player] engine error is host-independent — no CDN switch"
                            : self.mode == .offline
                            ? "[Player] offline input error — local retry required"
                            : "[Player] live input error — stream retry required")
                            + " (\(error.localizedDescription))"
                    )
                    self.error = PlaybackFailureMessage.text(for: error)
                    self.isBuffering = false
                    self.updateIsPlaying(transportRunning: false)
                    self.pushNowPlayingPlayback()
                    self.acknowledgeLifecycleReadiness(.terminalFailure)
                    self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
                    return
                }
                // Try another host.
                PlayerLog.log("[Player] input error (\(error.localizedDescription)) — trying another host")
                self.attemptCDNSwitchAfterTransportError(error)
            }
        }

        backend.onTickWithGeneration = { [weak self] currentTime, totalTime, generation, traceToken in
            guard let self else { return }
            // Diagnostic Logging only: main-thread cost of one accepted clock
            // callback and of its unconditional (outside the 4Hz gate) parts.
            let tickSpan = UIHitchMonitor.beginSpan("tick.vm")
            defer { UIHitchMonitor.endSpan(tickSpan) }
            // The backend includes the generation captured by the event source; a late clock tick from a
            // superseded open must not complete the successor's startup trace or mutate its lifecycle clock.
            guard ObjectIdentifier(self.backend) == callbackBackendIdentity,
                  generation == self.backend.runtimeGeneration else { return }
            if self.streamRecoveryOwnsWork, self.streamRecovery?.requestID == nil { return }
            guard !self.terminalOpenFailure else {
                // A stopped backend can deliver one last clock sample after
                // resolver/admission failure. It must not make the failed
                // live request look playable again.
                self.updateIsPlaying(transportRunning: false)
                return
            }
            // A Demand tick counts as the first CLOCK tick only once the clock has advanced past the last
            // accepted sample (`mediaTime` is assigned further down, so here it still holds the previous tick
            // — or the armed resume preset, which the ready seed exactly equals).
            if self.backendKind != .demandPaced
                || currentTime > self.mediaTime + 0.000_5 {
                StartupTrace.mark("first-clock-tick", token: traceToken)
                // Same edge, published to the app rather than to the trace: work that must not compete with
                // the startup burst waits on this instead of on a fixed timer.
                self.notePresentationStarted()
            }
            self.noteBackgroundPlaybackProgress(currentTime)
            let now = CACurrentMediaTime()
            // Refresh app/intent/source/lifecycle gates on the existing backend
            // cadence. The session still closes only complete one-second
            // windows, so this adds no reload timer or independent wall path.
            let liveSpan = UIHitchMonitor.beginSpan("tick.live")
            self.updateDemandVideoLivenessContext()
            UIHitchMonitor.endSpan(liveSpan)

            // ── Seek-in-flight contract ────────────────────────────────── While a seek travels to its
            // target, libVLC is playing several seconds of audio from BEFORE the requested position (which it
            // will then discard) and has no video frame for the current clock.
            let seeking = self.isSeekInFlight
            self.setMute(.seekTravel, seeking)
            // readyToPlay and bufferFinished both clear the spinner; a seek is
            // still in progress regardless of what libVLC has buffered.
            if seeking, !self.isBuffering { self.isBuffering = true }

            // Publish transport text and sampled display fields at ~4Hz.
            if now - self.lastDisplayUpdate >= 0.25 {
                // Always accept real media samples into mediaTime.
                // Wall presentation never blocks truth updates.
                let advanced = currentTime > self.mediaTime + 0.05
                // ARRIVAL clears the durable resume/seek intent — the clock actually getting there
                // ("seek-commit" at the media-truth level).
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
                // Never during a seek: the clock advances there too, but it is travelling, not playing what
                // the user asked for.
                if advanced, self.backend.isPlaying, !seeking {
                    if self.isBuffering {
                        self.isBuffering = false
                    }
                    if !self.isPlaying {
                        self.updateIsPlaying(transportRunning: true)
                    }
                }

                // Near-EOF DASH gap: libVLC timeChanged freezes ~4s early while
                // audio still drains (device: 95.1/99.1). Arm wall presentation
                // only after a real freeze; drive display only.
                if seeking || self.playbackEnded {
                    self.clearNearEndStall()
                } else if self.backend.isPlaying || self.isPlaying {
                    self.noteNearEndMediaSample(currentTime, duration: totalTime)
                } else if self.nearEndStallWallStart != nil,
                          !NearEndClockPolicy.isInNearEndWindow(media: currentTime, duration: totalTime) {
                    self.clearNearEndStall()
                }
                // `pendingSeekTarget == nil && !isBuffering` is reached only AFTER the new stream advanced
                // past its landing (the gate below clears pendingSeekTarget on exactly that condition), so
                // real frames are on screen when the cover lifts.
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
                // `seek()` clears it from its completion, but every reopen-at- position — CDN switch, decoder
                // reload, a scrub before the demuxer's open position — arms the pin and then takes
                // readyToPlay's "loaded at target — seek skipped" path, so no completion ever fires.
                if self.pendingSeekTarget != nil, !seeking, !self.isBuffering {
                    self.pendingSeekTarget = nil
                }
                if !seeking, self.pendingSeekTarget == nil, self.resumeAtTime == nil {
                    // Keep decorative selection on this accepted UI cadence;
                    // deferred positioning and native travel retain its anchor.
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
            // No duplicate settlement here — the backend owns the position-matching logic; the ViewModel's
            // pendingSeekTarget gates other systems (health monitor, sponsor skip) and is cleared when the
            // backend confirms arrival.

            // Per-tick work — subtitles, auto-skip (OP/ED and
            // SponsorBlock), and stats (FPS, bitrate, drops). Stats are
            // throttled to ~1Hz to avoid unnecessary struct copies.
            let skipSpan = UIHitchMonitor.beginSpan("tick.subs")
            self.updateSubtitle(at: currentTime)
            self.autoSkipIfNeeded(at: currentTime)
            self.autoSkipSponsorIfNeeded(at: currentTime)
            UIHitchMonitor.endSpan(skipSpan)
            if now - (self.lastDropSample?.at ?? 0) >= 1.0 {
                self.updateDynamicStats()
            }
        }

        backend.onBufferChanged = { [weak self] consumeTime in
            guard let self, !self.invalidatedBackendResources,
                  ObjectIdentifier(self.backend as AnyObject) == callbackBackendIdentity else { return }
            self.pendingBufferHealth = consumeTime
        }
    }
}
