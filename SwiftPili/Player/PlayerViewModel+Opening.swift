import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Validate the source, replace the admitted stream and bind successor identities before consuming
    /// readiness.
    func playURL(
        _ url: URL,
        audioURL: URL? = nil,
        startAt: TimeInterval = 0,
        isSeekReopen: Bool = false,
        videoBootstrapIdentity: MediaBootstrapIdentity? = nil,
        audioBootstrapIdentity: MediaBootstrapIdentity? = nil,
        cdnSwitchID: UUID? = nil,
        streamRetryID: UUID? = nil,
        liveSource: DemandLiveSource? = nil
    ) {
        if let streamRetryID {
            guard acceptsStreamRequest(streamRetryID), issueStreamRetry(streamRetryID) else { return }
            streamRecovery?.installed = nil
        } else {
            retireStreamRecovery(reason: "source-replacement")
        }
        if let cdnSwitchID {
            guard activeCDNSwitch?.id == cdnSwitchID,
                  activeCDNSwitch.map(ownsCDNSwitch) == true, !Task.isCancelled else { return }
        } else {
            retireCDNSwitch()
        }
        // It must run before terminal state reset, probing, backend.stop/load, recovery installation, or
        // currentURL publication.
        if mode == .offline {
            guard OfflinePlaybackAssetValidator.allows(
                videoURL: url,
                audioURL: audioURL
            ) else {
                markTerminalNoReachableStreamFailure()
                return
            }
        } else {
            guard Self.admittedNetworkURL(url, stage: "playURL") != nil else {
                markTerminalNoReachableStreamFailure()
                return
            }
            if let audioURL,
               Self.admittedNetworkURL(audioURL, stage: "playURL-audio") == nil {
                markTerminalNoReachableStreamFailure()
                return
            }
        }
        resetStreamDisplayForOpen(videoURL: url, audioURL: audioURL, isSeekReopen: isSeekReopen)
        terminalOpenFailure = false
        // The stream is admitted: this is the danmaku session's one writer.
        admitDanmakuSession(openingAt: startAt)
        lastStreamStartAt = CACurrentMediaTime()
        let traceToken = PlayerStartupTraceScope.tokenForStream(
            mode: mode,
            retainedToken: startupTraceToken
        )
        StartupTrace.mark("stream-open-requested", token: traceToken)
        PlayerLog.log(
            mode == .offline
                ? "[Player] ▶ starting validated offline asset"
                : "[Player] ▶ starting video stream on host=\(url.host() ?? "?")"
        )

        // Re-arm before the probe is told to wait on it: this open has not
        // presented anything yet, whatever the previous one did.
        resetPresentationGate()
        if mode == .vod, SmartCDNSelector.isEnabled, !url.isFileURL {
            probeVideoAcrossHosts(videoURL: url, generation: loadGeneration)
        }
        if mode == .live || mode == .offline {
            stats.cdnSetting = ""
        } else if SmartCDNSelector.isEnabled {
            stats.cdnSetting = String(localized: "Smart CDN")
        } else {
            let label = CDNService.current.label
            stats.cdnSetting = cdnFallbackActive ? "\(label) → fallback" : label
        }

        let hadFreeze = freezeFrame != nil
        // Only this reason: an in-place reopen (CDN switch, quality change) lands back at the same position,
        // so a mute segment still under the playhead must stay muted across it rather than blipping audible
        // until the next tick re-asserts.
        setMute(.seekTravel, false)
        // Stopping here would destroy the warm re-entry before it could ever fire.
        if !backend.hasParkedSession {
            backend.stop()
        }
        // `lastLoadStartPosition = 0` then makes `loadedAtTarget` false in readyToPlay, which issues that
        // initial seek. resumeAtTime must carry the real target for that path to fire.
        let openAt = PlayerBackendLoadConfiguration.openPosition(
            startAt,
            useAbsoluteVLCSeek: ExperimentalSettingsPolicy.diagnosticBool(
                key: "settime_seek_experiment", saved: ExperimentalSettingsPolicy.diagnosticOverrides.setTimeSeek
            )
                && mode == .vod && backendKind == .vlc
        )
        if openAt != startAt, startAt > 2 || (streamRetryID != nil && startAt > 0) {
            resumeAtTime = startAt
            resumeIsFromHistory = false
        }
        lastLoadStartPosition = openAt
        // The most recent positioning request: drives both the decoder-health
        // recovery target and the A/V fragment catch-up guard.
        lastSeekRequest = startAt > 0.5 ? startAt : nil
        fpsEverLive = false
        // New stream: clock has not advanced yet (so a frozen clock is priming, not a stall), and the byte
        // window starts fresh so prime is not read as starvation before the first sample lands.
        clockEverAdvancedThisStream = false
        lastBytesAdvanceAt = CACurrentMediaTime()
        lastWatchdogTime = startAt
        // New demux/decoder session from a normal load — clear lifecycle dirty
        // bits. Background recovery re-sets needsInlineSurfaceRebuild after its
        // own loadVOD when the reload ran off-screen.
        decoderSessionSuspect = false
        // Do NOT clear needsInlineSurfaceRebuild here unconditionally: the background recovery path calls
        // loadVOD → playURL and must keep the flag so didBecomeActive can rebuild the inline surface.
        if UIApplication.shared.applicationState == .active {
            needsInlineSurfaceRebuild = false
        }
        let bufferSeconds = PlayerBackendLoadConfiguration.maxBufferDuration(
            for: mode,
            configured: PlayerPlaybackPreferences.preloadStrategy.maxBufferDuration,
            nominalBitrate: streamNominalBitrate
        )

        // VOD + libVLC only: force bilivideo https→http so libVLC uses HTTP/1.1 (h2 without Content-Length
        // defeats Range-resume).
        let useVLCTransport = mode == .vod && backendKind == .vlc
        let (loadURL, loadAudioURL) = PlayerBackendLoadConfiguration.transportURLs(
            video: url, audio: audioURL, useVLCTransport: useVLCTransport
        )
        if loadURL != url {
            PlayerLog.log("[Player] transport: https → http for libVLC (forces HTTP/1.1; h2 without Content-Length defeats VLC's Range-resume)")
        } else if mode == .vod, backendKind != .vlc, url.scheme == "https" {
            PlayerLog.log("[Player] transport: keep https for \(backendKind.shortLabel) (no VLC http rewrite)")
        }

        // Same synchronous scope as the load below — the one-shot flag cannot
        // leak across loads.
        if isSeekReopen, let vlc = backend as? VLCPlayerBackend {
            vlc.nextLoadIsSeekReopen = true
        }
        // Capture the request token at the backend open boundary.
        backend.setStartupTraceToken(traceToken)
        multiConnectionAdmissionAttempted = MultiConnectionVODCandidates.admitsLoad(
            enabled: MultiConnectionFeatureGate.isEnabled(), mode: mode,
            demandBackend: backendKind == .demandPaced,
            path: Self.multiConnectionNetworkPath, primary: loadURL,
            cellularEnabled: MultiConnectionFeatureGate.cellularEnabled()
        )
        let alternateVideoURLs = multiConnectionHelpers(primary: loadURL, rawURLs: multiConnectionVideoURLs)
        let alternateAudioURLs = loadAudioURL.map {
            multiConnectionHelpers(primary: $0, rawURLs: multiConnectionAudioURLs)
        } ?? []
        let multiConnectionPolicy = multiConnectionPolicyForLoad(
            hasHelpers: !alternateVideoURLs.isEmpty || !alternateAudioURLs.isEmpty
        )
        refreshMultiConnectionQuiet()
        Self.prepareSelectedDASHBootstrapIdentities(
            for: backend, mode: mode,
            video: videoBootstrapIdentity, audio: audioBootstrapIdentity
        )
        let loadBackend = backend
        revokeEqualizerMaintenancePermission()
        loadBackend.equalizerConfiguration = effectiveEqualizerConfiguration
        syncVideoEnhancementToBackend(loadBackend)
        let configuration = PlayerBackendLoadConfiguration(
            url: loadURL,
            audioURL: loadAudioURL,
            headers: PlayerBackendLoadConfiguration.biliHeaders,
            startPosition: openAt,
            playbackRate: playbackRate,
            hardwareDecode: PlayerPlaybackPreferences.hardwareDecodeEnabled,
            networkCaching: PlayerBackendLoadConfiguration.networkCaching(for: mode),
            maxBuffer: bufferSeconds,
            preferNativeVideoToolbox: currentVideoIsAV1,
            alternateVideoURLs: alternateVideoURLs,
            alternateAudioURLs: alternateAudioURLs,
            readAheadSeconds: alternateVideoURLs.isEmpty && alternateAudioURLs.isEmpty
                ? nil : PlayerPlaybackPreferences.preloadStrategy.maxBufferDuration,
            multiConnectionPolicy: multiConnectionPolicy,
            liveSource: liveSource
        )
        configuration.load(using: loadBackend)
        if recoveryCover != nil {
            prepareRecoveryCoverForSuccessorLoad()
        } else if freezeFrameAwaitingFreshProof, usesDemandPresentationContinuity {
            cdnFrameCover = CDNFrameCoverPolicy(backend: backend)
            freezeFrameExpectedSessionGeneration = nil
            PlayerLog.log("[CDN-switch] waiting for actual ready then current presentation proof")
        }
        if let cdnSwitchID, activeCDNSwitch?.id == cdnSwitchID {
            activeCDNSwitch?.submittedOpen = true
            activeCDNSwitch?.budgetCommitted = true
        }
        // A replacement backend/session may start with its default gravity;
        // reapply the screen's user choice without changing that choice.
        applyScaleMode()

        if hadFreeze {
            let transitionLabel = cdnSwitchInFlight ? "[CDN-switch]" : "[Player]"
            PlayerLog.log(
                "\(transitionLabel) player reloaded: "
                    + "transitionCover=\(freezeFrame != nil ? 1 : 0) "
                    + "gen=\(playerGeneration + 1)"
            )
        }

        // A load that really is new user content sets `playbackIntent = .playing` in `performLoadVOD` /
        // `startOfflinePlayback` / `loadLive`, so the promotion added nothing there either — it only ever
        // fired for reopens that are not user actions.
        advanceGeneration("playURL")
        playbackTerminalState = .active
        clearNearEndStall()
        currentURL = url
        currentDASHAudioURL = audioURL
        // The pending sample can now project against the admitted source.
        publishMultiConnectionDisplay(rate: nil)
        if let streamRetryID, streamRecovery?.requestID == streamRetryID {
            streamRecovery?.installed = .init(backend: ObjectIdentifier(backend as AnyObject),
                generation: backend.runtimeGeneration)
        }
        installEqualizerMaintenanceAdmission()
        isDASHMode = audioURL != nil
        if let context = decoderRecoveryContext() {
            // DecoderRecoveryAdmission migrates an active lifecycle/runtime
            // ticket to this successor backend generation. `install` is not
            // a completion signal and must not clear that ticket.
            decoderRecoveryAdmission.install(context)
        } else {
            decoderRecoveryAdmission.invalidate()
            nonLifecycleRecoveryTicket = nil
        }
        submitLifecycleOpeningIfNeeded()
        // Demand/VLC test doubles may report readiness synchronously from
        // `load`. Replay the current backend state after the generation fence
        // is published so that event ordering cannot leave the ticket opening.
        let restoreTolerance: TimeInterval = streamRetryID != nil ? 0.05 : 2
        let replayOwesRestoreSeek = pendingSeekTarget != nil || (resumeAtTime.map {
            abs($0) >= restoreTolerance && abs(lastLoadStartPosition - $0) >= restoreTolerance
        } ?? false)
        if backend.isReadyToPlay { noteStreamReady() }
        if backend.isReadyToPlay, !terminalOpenFailure, !replayOwesRestoreSeek {
            markAmbientVideoLoaded()
            acknowledgeLifecycleReadiness(.transportReady)
            finishNonLifecycleRecoveryIfNeeded(outcome: .backendReady)
        } else if terminalOpenFailure {
            finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        }
        updateDemandVideoLivenessContext()
        isBuffering = true
        if mode.usesPlaybackWatchdog {
            startPlaybackWatchdog()
        }
        startSpeedSampling()
        if let meta = nowPlayingMeta {
            setNowPlaying(title: meta.title, artist: meta.artist, cover: meta.cover)
        }
    }

    /// Retire the outgoing display samples before publishing the admitted
    /// source or loading a backend that can call back synchronously.
    private func resetStreamDisplayForOpen(videoURL: URL, audioURL: URL?, isSeekReopen: Bool) {
        // A validated local seek reopen retains its whole-file range for the same inputs.
        let retainsLocalRange = isSeekReopen && mode == .offline
            && videoURL == currentURL && audioURL == currentDASHAudioURL
        resetBufferedTime(raw: 0, displayedEnd: retainsLocalRange ? displayedBufferedTime : nil)
        pendingBufferHealth = nil
        resetMultiConnectionDisplay()

        var openingStats = stats
        openingStats.droppedFrames = 0
        openingStats.dropRate = 0
        openingStats.fps = 0
        openingStats.networkSpeed = 0
        openingStats.bufferHealth = nil
        openingStats.videoHost = mode == .offline ? "" : (videoURL.host() ?? "")
        openingStats.audioHost = mode == .offline ? "" : (audioURL?.host() ?? "")
        openingStats.hasSeparateAudio = audioURL != nil
        stats = openingStats
        lastDropSample = nil
    }
}

extension PlayerViewModel {

    /// Announce that the stream is presenting, releasing anything that deferred
    /// work until the startup burst was over. One-shot per stream open.
    func notePresentationStarted() {
        guard !hasStartedPresenting else { return }
        hasStartedPresenting = true
        markAmbientVideoLoaded()
        let gates = presentationGates
        presentationGates.removeAll()
        for (_, continuation) in gates { continuation.resume() }
    }

    /// Re-arm the gate for a stream that is about to open.
    func resetPresentationGate() {
        hasStartedPresenting = false
    }

    /// Resolve exactly once on playback start, timeout or cancellation, including cancellation before waiter
    /// installation.
    func awaitPresentationStart(timeout: TimeInterval) async {
        if hasStartedPresenting { return }
        let id = nextPresentationGateID
        nextPresentationGateID &+= 1
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            self?.resumePresentationGate(id)
        }
        // Cancellation has to resolve the gate too, or "cancel the probe" stops meaning the task is gone: a
        // `withCheckedContinuation` is cancellation-blind, so a cancelled caller would stay parked for the
        // whole timeout.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Re-checked inside the installer: the tick can land between the early return above and here,
                // and cancellation can arrive before the gate is installed — in which case `onCancel` has
                // already run and found nothing to resolve.
                if hasStartedPresenting || Task.isCancelled {
                    continuation.resume()
                } else {
                    presentationGates[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumePresentationGate(id) }
        }
        timeoutTask.cancel()
    }

    /// Remove the waiter before resuming so competing completion edges cannot resume it twice.
    private func resumePresentationGate(_ id: Int) {
        presentationGates.removeValue(forKey: id)?.resume()
    }
}
