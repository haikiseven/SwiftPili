import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func performLoadVOD(
        aid: Int,
        cid: Int,
        bvid: String?,
        quality: Int?,
        source: StreamSource,
        resumeAt: TimeInterval?,
        portraitHint: Bool?,
        preservePlayState: Bool,
        owner: String?,
        ownerLease: PlayerOwnerLease?,
        startupTraceToken: StartupTrace.Token?,
        requestAdmission: (@MainActor @Sendable () -> Bool)?,
        mediaResetID: UUID?,
        recoveryCoverIdentity: UInt64?,
        cdnSwitchID: UUID?,
        streamRetryID: UUID?
    ) async {
        if let streamRetryID, !acceptsStreamRequest(streamRetryID) { return }
        let originalRequestAdmission = requestAdmission
        let requestAdmission: (@MainActor @Sendable () -> Bool)? = { [weak self] in
            guard originalRequestAdmission?() ?? true else { return false }
            guard let streamRetryID else { return true }
            return self?.acceptsStreamRequest(streamRetryID) == true
        }
        if let mediaResetID,
           !mediaResetRecovery.accepts(mediaResetID, owner: currentOwnerLease) { return }
        guard requestAdmission?() ?? true else {
            PlayerLog.log("[Player] loadVOD dropped — page request is stale")
            return
        }
        guard PlayerLoadAdmissionPolicy.allows(
            targetMode: .vod,
            requestedOwner: owner,
            currentOwner: ownerKey,
            currentMode: mode,
            requestedLease: ownerLease,
            currentLeaseGeneration: ownerLeaseGeneration
        ),
        (owner != nil || (
            mode == .vod
                && currentAid == aid
                && currentCid == cid
                && currentSource == source
        )) else {
            clearPlayerInfoHandoff(matching: ownerLease)
            PlayerLog.log(
                "[Player] loadVOD dropped — requestedOwner=\(owner ?? "internal") " +
                "currentOwner=\(ownerKey.isEmpty ? "-" : ownerKey) mode=\(mode)"
            )
            return
        }
        if let streamRetryID, !issueStreamRetry(streamRetryID) { return }
        let sameContent = mode == .vod
            && aid == currentAid
            && cid == currentCid
            && source == currentSource
        let retainedBvid = sameContent ? currentBvid : nil
        let failedResumeHost = activeCDNSwitch.flatMap { transaction in
            cdnSwitchID == transaction.id ? CDNHostPolicy.canonicalHost(transaction.authority.videoURL?.host()) : nil
        }
        let preloadedPlayerInfo = takePlayerInfoHandoff(
            aid: aid,
            cid: cid,
            owner: owner,
            ownerLease: ownerLease
        )
        let teardownReason = PlayerReloadPresentationPolicy.reason(
            targetMode: .vod,
            currentMode: mode,
            sameContent: sameContent,
            newOwner: presentationResetPendingForOwnerChange
        )
        let retainedPortraitHint = sameContent ? portraitPropagation.apiHint : nil
        playbackTerminalState = .active

        if !sameContent {
            cdnFallbackActive = false
            resumeAtTime = nil
            resumeIsFromHistory = false
            audioTierOverride = nil
            resetRecoveryBudget()
            nowPlayingMeta = nil
            onPreviousEpisode = nil
            onNextEpisode = nil
            pgcSeasonContext = nil
            inlineCondensed = false
            portraitCondenseLocked = false
            sponsorSkippedUUIDs = []
            autoSkippedSegmentKeys = []
            pendingSponsorManualSegment = nil
        }
        stop(reason: teardownReason, preservingParkedBackend: backend.hasParkedSession,
             mediaResetID: mediaResetID, recoveryCoverIdentity: recoveryCoverIdentity,
             cdnSwitchID: cdnSwitchID, streamRetryID: streamRetryID)
        presentationResetPendingForOwnerChange = false
        restorePreferredBackendForLoad("vod load")
        resetMultiConnectionDisplay()
        loadGeneration += 1
        let generation = loadGeneration
        if let streamRetryID, streamRecovery?.requestID == streamRetryID {
            streamRecovery?.loadGeneration = generation
        }
        streamSourceRequestAdmission = streamRetryID == nil
            ? originalRequestAdmission : streamRecovery?.requestAdmission
        if let cdnSwitchID, activeCDNSwitch?.id == cdnSwitchID {
            activeCDNSwitch?.reloadGeneration = generation
        }
        if let mediaResetID { mediaResetRecovery.bind(mediaResetID, loadGeneration: generation) }
        let loadCompletion = PlayerMediaResetRecovery<MediaResetSource>.LoadCompletion(
            generation: generation, owner: ownerLease, resetID: mediaResetID
        )
        if let startupTraceToken {
            self.startupTraceToken = startupTraceToken
        }
        mode = .vod
        currentAid = aid
        currentCid = cid
        let suppliedBvid = bvid?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentBvid = (suppliedBvid?.isEmpty == false ? suppliedBvid : nil) ?? retainedBvid
        currentSource = source
        if let owner = currentOwnerLease {
            ambientStoryboardRequest = PlayerAmbientStoryboardLoader.Request(
                content: .init(aid: aid, cid: cid, owner: owner),
                loadGeneration: generation
            )
        }
        reconcileAmbientStoryboard()
        let effectivePortraitHint = portraitHint ?? retainedPortraitHint
        if !sameContent {
            isPortraitContent = DeviceCapability.usesCompactPortraitVideoFraming
                && (effectivePortraitHint ?? false)
        } else if let effectivePortraitHint {
            isPortraitContent = DeviceCapability.usesCompactPortraitVideoFraming
                && effectivePortraitHint
        }
        portraitPropagation = PlayerPortraitPropagationState(
            mode: .vod,
            apiHint: effectivePortraitHint,
            initialIsPortrait: isPortraitContent
        )
        if !preservePlayState {
            playbackIntent = .playing
        }
        pendingRestartNotice = false
        let effectiveResumeIntent = resumeAt ?? resumeAtTime
        PlayerLog.log(
            "[Player] reopen-reason=\(String(describing: teardownReason)) " +
            "reopen-resume-target=\((effectiveResumeIntent ?? 0) > 2 ? String(format: "%.1f", effectiveResumeIntent ?? 0) + "s" : "none")"
        )
        let durableIntent = streamRetryID != nil
            ? effectiveResumeIntent : ((effectiveResumeIntent ?? 0) > 2 ? effectiveResumeIntent : nil)
        armDurableResumeTarget(
            durableIntent,
            source: "load"
        )
        if let resumeAt, resumeAt > 2 || (streamRetryID != nil && resumeAt >= 0) {
            resumeAtTime = resumeAt
            resumeIsFromHistory = streamRetryID == nil
            mediaTime = resumeAt
            PlayerLog.log("[Player] loadVOD: will resume at \(String(format: "%.0f", resumeAt))s once ready")
        } else if let resumeAt, resumeAt < 0 {
            pendingRestartNotice = true
        } else if let resumeAt {
            PlayerLog.log("[Player] loadVOD: resume point \(String(format: "%.1f", resumeAt))s too early — starting from 0")
        }
        Task { [weak self] in
            await self?.loadSubtitleList(
                aid: aid,
                cid: cid,
                generation: generation,
                ownerLease: ownerLease,
                preloadedInfo: preloadedPlayerInfo
            )
        }
        let q = quality ?? Self.preferredQuality
        if !preservePlayState { lastSeekRequest = nil }
        error = nil
        unavailability = nil

        do {
            StartupTrace.mark("playurl-request-started", token: startupTraceToken ?? self.startupTraceToken)
            let dashResult = try await fetchPlayURL(aid: aid, cid: cid, quality: q, fnval: 4048, source: source)
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                  admitsLoadRequest(
                    requestAdmission?() ?? true,
                    after: "playurl",
                    token: startupTraceToken ?? self.startupTraceToken
                  ) else { return }
            StartupTrace.mark("playurl-ready", token: startupTraceToken ?? self.startupTraceToken)

            let hardwareCapabilities = await VideoHardwareCapabilities.snapshot()
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                  admitsLoadRequest(
                    requestAdmission?() ?? true,
                    after: "hardware-capabilities",
                    token: startupTraceToken ?? self.startupTraceToken
                  ) else { return }
            try Self.checkLoadCancellation()
            StartupTrace.mark("hardware-capabilities-ready", token: startupTraceToken ?? self.startupTraceToken)

            if case .pgc = source, let clips = dashResult.clipInfo, !clips.isEmpty {
                skipSegments = clips.compactMap { clip in
                    guard let s = clip.start, let e = clip.end, e > s else { return nil }
                    let label = clip.clipType?.contains("ED") == true ? "ED" : "OP"
                    return (label: label, start: Double(s), end: Double(e))
                }
                if !skipSegments.isEmpty {
                    PlayerLog.log("[Player] clip_info skip marks: \(skipSegments.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" }.joined(separator: ", "))")
                }
            }

            if let acceptQuality = dashResult.acceptQuality {
                availableQualities = acceptQuality.compactMap { qn in
                    if let desc = Self.qualityMap[qn] {
                        return (id: qn, desc: desc)
                    }
                    return (id: qn, desc: "\(qn)")
                }
                PlayerLog.log("[Player] DASH quality=\(dashResult.quality) available=\(acceptQuality) requested=\(q) preservePlay=\(preservePlayState) currentQ=\(currentQuality) codecPref=\(PlayerPlaybackPreferences.preferredCodec)")
            }

            let effectiveQ = availableQualities.contains(where: { $0.id == q }) ? q : (dashResult.quality)
            currentQuality = effectiveQ
            SmartCDNSelector.shared.preferThroughput = effectiveQ >= 120

            if resumeIsFromHistory, let t = resumeAtTime,
               let dur = (dashResult.dash?.duration).map(TimeInterval.init), dur > 10,
               t >= dur - max(15, dur * 0.02) {
                PlayerLog.log("[Player] saved position \(String(format: "%.1f", t))s is at the end of \(String(format: "%.1f", dur))s — playing from beginning")
                resumeAtTime = nil
                resumeIsFromHistory = false
                pendingRestartNotice = true
                armDurableResumeTarget(nil, source: "restart")
                mediaTime = 0
            }
            let startAt = resumeAtTime ?? 0

            if let dash = dashResult.dash,
               let videoStream = selectVideoStream(
                from: dash.video, quality: effectiveQ, hardwareCapabilities: hardwareCapabilities
               ) {
                PlayerLog.log("[Player] preferring DASH split over durl")
                availableCodecs = codecsOffered(in: dash.video, quality: videoStream.id)
                stats.codec = videoStream.codecs
                stats.bitrate = videoStream.bandwidth
                stats.quality = videoStream.id
                stats.qualityDesc = Self.qualityMap[videoStream.id] ?? "\(videoStream.id)"
                let runningEngine = backendKind
                let audioPreference = audioTierOverride ?? Self.preferredAudioQuality
                let bestAudio = AudioStreamSelection.select(
                    in: dash,
                    preference: audioPreference,
                    decodable: { runningEngine.decodesAudio($0) }
                )
                availableAudioTiers = AudioStreamSelection.availableTiers(
                    in: dash,
                    decodable: { runningEngine.decodesAudio($0) }
                )
                playingAudioTier = bestAudio.flatMap { AudioQualityTier(rawValue: $0.id) }
                if let audioStream = bestAudio {
                    stats.audioCodec = audioStream.codecs
                    stats.audioBitrate = audioStream.bandwidth
                    stats.audioTier = playingAudioTier
                }
                PlayerLog.log(
                    "[Player] audio tier pref=\(audioPreference.statsLabel)" +
                    (audioTierOverride != nil ? "(in-player)" : "") +
                    " offered=\(AudioStreamSelection.candidates(dash).map { String($0.id) }.joined(separator: ","))" +
                    " picked=\(bestAudio.map { "\($0.id) \($0.codecs) \($0.bandwidth / 1000)kbps" } ?? "none")"
                )

                StartupTrace.mark("cdn-probe-started", token: startupTraceToken ?? self.startupTraceToken)
                let probeOwner = currentOwnerLease
                let probeAdmission: @MainActor @Sendable () -> Bool = { [weak self] in
                    guard let self, self.currentOwnerLease == probeOwner,
                          self.mediaResetRecovery.allowsLoadCompletion(
                            loadCompletion, currentGeneration: self.loadGeneration, currentOwner: probeOwner
                          ) else { return false }
                    return requestAdmission?() ?? true
                }
                async let probedVideo = selectReachableURL(
                    videoStream.allURLs,
                    resume: runningEngine == .demandPaced ? .init(
                        startAt: startAt, track: .video, failedHost: failedResumeHost
                    ) : nil,
                    requestAdmission: probeAdmission
                )
                async let probedAudio: StreamURLSelection? = { () async -> StreamURLSelection? in
                    guard let bestAudio else { return nil }
                    return await self.selectReachableURL(
                        bestAudio.allURLs,
                        resume: runningEngine == .demandPaced ? .init(
                            startAt: startAt, track: .audio, failedHost: failedResumeHost
                        ) : nil,
                        requestAdmission: probeAdmission
                    )
                }()
                let videoSelection = await probedVideo
                let audioSelection = await probedAudio
                let videoURL = videoSelection.url
                let audioURL = audioSelection?.url
                guard mediaResetRecovery.allowsLoadCompletion(
                          loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                      ),
                      ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                      admitsLoadRequest(
                        requestAdmission?() ?? true,
                        after: "cdn-probe",
                        token: startupTraceToken ?? self.startupTraceToken
                      ) else { return }
                StartupTrace.mark("cdn-selected", token: startupTraceToken ?? self.startupTraceToken)
                try Self.checkLoadCancellation()
                if let audioSelection, audioSelection.url == nil {
                    PlayerLog.log(
                        "[StreamRetry] offered-audio probe failed reasons=\(audioSelection.outcomes.map(\.diagnostic))"
                    )
                }
                guard let videoURL else {
                    PlayerLog.log(
                        "[StreamRetry] video probe failed reasons=\(videoSelection.outcomes.map(\.diagnostic))"
                    )
                    if let failure = videoSelection.eligibleFailure,
                       handleStreamTransportFailure(failure, quality: q, loadGeneration: generation) { return }
                    guard settleResetPreOpenFailure(
                        loadCompletion, retryable: PlaybackUnavailability.streamUnreachable.isRetryable
                    ) else { return }
                    retireStreamRecovery(reason: "permanent-probe")
                    markTransientStreamUnreachable()
                    return
                }

                stats.decoderType = decoderLabel(
                    codecs: videoStream.codecs,
                    hardwareSupported: hardwareCapabilities.supports(codecs: videoStream.codecs)
                )
                stats.videoURL = Self.diagnosticURL(videoURL)
                stats.hasSeparateAudio = audioURL != nil
                stats.audioHost = audioURL?.host() ?? ""
                currentQuality = videoStream.id
                isDASHMode = true
                currentVideoIsAV1 = VideoCodecPreference.av1.matches(videoStream.codecs)
                streamNominalBitrate = videoStream.bandwidth + (bestAudio?.bandwidth ?? 0)
                PlayerLog.log("[Player] DASH: \(videoStream.codecs) qn=\(videoStream.id) audio=\(audioURL != nil)")

                multiConnectionVideoURLs = videoStream.allURLs
                multiConnectionAudioURLs = bestAudio?.allURLs ?? []
                let videoBootstrapIdentity = Self.selectedDASHBootstrapIdentity(
                    aid: aid, cid: cid, source: source, track: .video, stream: videoStream
                )
                let audioBootstrapIdentity = audioURL == nil ? nil : bestAudio.map {
                    Self.selectedDASHBootstrapIdentity(
                        aid: aid, cid: cid, source: source, track: .audio, stream: $0
                    )
                }
                playURL(videoURL, audioURL: audioURL, startAt: startAt,
                    videoBootstrapIdentity: videoBootstrapIdentity,
                    audioBootstrapIdentity: audioBootstrapIdentity,
                    cdnSwitchID: cdnSwitchID,
                    streamRetryID: streamRetryID
                )
                startHistoryReporting()
                return
            }

            let durlResult = try await fetchPlayURL(aid: aid, cid: cid, quality: effectiveQ, fnval: 1, source: source)
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                  admitsLoadRequest(
                    requestAdmission?() ?? true,
                    after: "durl-playurl",
                    token: startupTraceToken ?? self.startupTraceToken
                  ) else { return }
            let durlSelection = await selectReachableURL(durlResult.durl?.first.map { [$0.url] } ?? [])
            let fallback = durlResult
            if let durlURL = durlSelection.url {
                guard mediaResetRecovery.allowsLoadCompletion(
                          loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                      ),
                      ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                      admitsLoadRequest(
                        requestAdmission?() ?? true,
                        after: "durl-probe",
                        token: startupTraceToken ?? self.startupTraceToken
                      ) else { return }
                guard handOffBackend(to: .vlc, reason: "vod durl (muxed progressive)")
                    || activeBackendKind == .vlc else {
                    guard settleResetPreOpenFailure(loadCompletion, retryable: false) else { return }
                    retireStreamRecovery(reason: "durl-engine-unavailable")
                    markUnavailable(.noPlayableStream, detail: "durl-libvlc-engine-unavailable")
                    return
                }
                availableCodecs = []
                availableAudioTiers = []
                playingAudioTier = nil
                stats.codec = "avc1"
                stats.decoderType = decoderLabel(
                    codecs: "avc1", hardwareSupported: hardwareCapabilities.supports(codecs: "avc1")
                )
                stats.bitrate = 0
                stats.audioCodec = ""
                stats.audioBitrate = 0
                stats.audioTier = nil
                stats.quality = fallback.quality
                stats.qualityDesc = Self.qualityMap[fallback.quality] ?? "\(fallback.quality)"
                stats.videoURL = String(durlURL.absoluteString.prefix(80))
                stats.hasSeparateAudio = false
                stats.audioHost = ""
                currentQuality = fallback.quality
                isDASHMode = false
                currentVideoIsAV1 = false
                streamNominalBitrate = 0
                PlayerLog.log("[Player] durl fallback: qn=\(fallback.quality)")
                playURL(durlURL, cdnSwitchID: cdnSwitchID, streamRetryID: streamRetryID)
                startHistoryReporting()
                return
            }

            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                  admitsLoadRequest(
                    requestAdmission?() ?? true,
                    after: "durl-unreachable",
                    token: startupTraceToken ?? self.startupTraceToken
                  ) else { return }
            try Self.checkLoadCancellation()
            PlayerLog.log("[StreamRetry] durl probe failed reasons=\(durlSelection.outcomes.map(\.diagnostic))")
            if let failure = durlSelection.eligibleFailure,
               handleStreamTransportFailure(failure, quality: q, loadGeneration: generation) { return }
            guard settleResetPreOpenFailure(
                loadCompletion, retryable: PlaybackUnavailability.streamUnreachable.isRetryable
            ) else { return }
            retireStreamRecovery(reason: "permanent-durl")
            markTransientStreamUnreachable()
        } catch {
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                  admitsLoadRequest(
                    requestAdmission?() ?? true,
                    after: "failure",
                    token: startupTraceToken ?? self.startupTraceToken
                  ) else { return }
            if let failure = StreamTransportFailure.preserving(error, stage: .resolver),
               handleStreamTransportFailure(failure, quality: q, loadGeneration: generation) { return }
            if streamRetryID != nil, error.isCancellation { return }
            let refusal = PlaybackAvailabilityPolicy.unavailability(forAny: error)
            guard settleResetPreOpenFailure(
                loadCompletion, retryable: error.isCancellation || (refusal?.isRetryable ?? true)
            ) else { return }
            retireStreamRecovery(reason: "permanent-resolver")
            if error.isCancellation {
                if generation == loadGeneration, currentURL == nil {
                    settleTerminalFailure(TerminalFailurePayload(
                        message: String(localized: "Loading was interrupted. Tap Retry."),
                        retireStreamRecoveryReason: nil,
                        startupTraceAbortLabel: "load-cancelled",
                        logMessage: "[Player] loadVOD cancelled after teardown with no successor — surfacing Retry"
                    ))
                } else {
                    PlayerLog.log("[Player] loadVOD cancelled (benign) — no error surfaced")
                }
                return
            }
            if let reason = refusal {
                markUnavailable(reason, detail: "loadVOD")
                return
            }
            settleTerminalFailure(TerminalFailurePayload(
                message: error.localizedDescription,
                retireStreamRecoveryReason: nil,
                startupTraceAbortLabel: "load-failed",
                logMessage: "[Player] loadVOD failed: \(error)"
            ))
        }
    }
}
