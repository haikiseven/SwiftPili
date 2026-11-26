import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

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
        if !isSeekReopen, currentURL == nil {
            hasRenderedFirstFrame = false
        }
        liveNeedsReconnectOnResume = false
        terminalOpenFailure = false
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
        setMute(.seekTravel, false)
        if !backend.hasParkedSession {
            backend.stop()
        }
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
        lastSeekRequest = startAt > 0.5 ? startAt : nil
        fpsEverLive = false
        clockEverAdvancedThisStream = false
        lastBytesAdvanceAt = CACurrentMediaTime()
        lastWatchdogTime = startAt
        decoderSessionSuspect = false
        if UIApplication.shared.applicationState == .active {
            needsInlineSurfaceRebuild = false
        }
        let bufferSeconds = PlayerBackendLoadConfiguration.maxBufferDuration(
            for: mode,
            configured: PlayerPlaybackPreferences.preloadStrategy.maxBufferDuration,
            nominalBitrate: streamNominalBitrate
        )

        let useVLCTransport = mode == .vod && backendKind == .vlc
        let (loadURL, loadAudioURL) = PlayerBackendLoadConfiguration.transportURLs(
            video: url, audio: audioURL, useVLCTransport: useVLCTransport
        )
        if loadURL != url {
            PlayerLog.log("[Player] transport: https → http for libVLC (forces HTTP/1.1; h2 without Content-Length defeats VLC's Range-resume)")
        } else if mode == .vod, backendKind != .vlc, url.scheme == "https" {
            PlayerLog.log("[Player] transport: keep https for \(backendKind.shortLabel) (no VLC http rewrite)")
        }

        if isSeekReopen, let vlc = backend as? VLCPlayerBackend {
            vlc.nextLoadIsSeekReopen = true
        }
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
        if playbackIntent == .playing, audioSessionInterrupted,
           audioSessionPolicy.interrupted || !authorizeAudioPlayback() {
            if playbackIntent == .playing {
                playbackIntent = .pausedBySystem
            }
            PlayerLog.log("[Player] playURL opening paused — audio session interrupted")
        }
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
        if !userWantsPlaying || audioSessionInterrupted {
            loadBackend.pause()
        }
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
        applyScaleMode()

        if hadFreeze {
            let transitionLabel = cdnSwitchInFlight ? "[CDN-switch]" : "[Player]"
            PlayerLog.log(
                "\(transitionLabel) player reloaded: "
                    + "transitionCover=\(freezeFrame != nil ? 1 : 0) "
                    + "gen=\(playerGeneration + 1)"
            )
        }

        advanceGeneration("playURL")
        playbackTerminalState = .active
        clearNearEndStall()
        currentURL = url
        currentDASHAudioURL = audioURL
        publishMultiConnectionDisplay(rate: nil)
        if let streamRetryID, streamRecovery?.requestID == streamRetryID {
            streamRecovery?.installed = .init(backend: ObjectIdentifier(backend as AnyObject),
                generation: backend.runtimeGeneration)
        }
        installEqualizerMaintenanceAdmission()
        if audioURL != nil {
            isDASHMode = true
        }
        if let context = decoderRecoveryContext() {
            decoderRecoveryAdmission.install(context)
        } else {
            decoderRecoveryAdmission.invalidate()
            nonLifecycleRecoveryTicket = nil
        }
        submitLifecycleOpeningIfNeeded()
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
        flushPendingDecodeFallbackNoticeIfNeeded()
    }

    private func resetStreamDisplayForOpen(videoURL: URL, audioURL: URL?, isSeekReopen: Bool) {
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

    func markFirstVideoFrameRendered() {
        guard !terminalOpenFailure, error == nil else { return }
        if !hasRenderedFirstFrame {
            hasRenderedFirstFrame = true
            PlayerLog.log("[Player] first video frame rendered owner=\(ownerKey.isEmpty ? "-" : ownerKey)")
        }
        if !ownerKey.isEmpty {
            clearOutgoingRouteStill(owner: ownerKey)
        }
        notePresentationStarted()
    }

    func notePresentationStarted() {
        guard !hasStartedPresenting else { return }
        hasStartedPresenting = true
        markAmbientVideoLoaded()
        let gates = presentationGates
        presentationGates.removeAll()
        for (_, continuation) in gates { continuation.resume() }
    }

    func resetPresentationGate() {
        hasStartedPresenting = false
    }

    func awaitPresentationStart(timeout: TimeInterval) async {
        if hasStartedPresenting { return }
        let id = nextPresentationGateID
        nextPresentationGateID &+= 1
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            self?.resumePresentationGate(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
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

    private func resumePresentationGate(_ id: Int) {
        presentationGates.removeValue(forKey: id)?.resume()
    }
}
