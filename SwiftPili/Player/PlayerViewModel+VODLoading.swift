import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func loadVOD(
        aid: Int,
        cid: Int,
        bvid: String? = nil,
        quality: Int? = nil,
        source: StreamSource = .ugc,
        resumeAt: TimeInterval? = nil,
        resumedPartNumber: Int?,
        portraitHint: Bool? = nil,
        aspectRatioHint: CGFloat? = nil,
        preservePlayState: Bool = false,
        owner: String? = nil,
        ownerLease: PlayerOwnerLease? = nil,
        startupTraceToken: StartupTrace.Token? = nil,
        requestAdmission: (@MainActor @Sendable () -> Bool)? = nil,
        mediaResetID: UUID? = nil,
        recoveryCoverIdentity: UInt64? = nil,
        cdnSwitchID: UUID? = nil,
        streamRetryID: UUID? = nil
    ) async {
        let loadTask = Task {
            await performLoadVOD(
                aid: aid,
                cid: cid,
                bvid: bvid,
                quality: quality,
                source: source,
                resumeAt: resumeAt,
                resumedPartNumber: resumedPartNumber,
                portraitHint: portraitHint,
                aspectRatioHint: aspectRatioHint,
                preservePlayState: preservePlayState,
                owner: owner,
                ownerLease: ownerLease,
                startupTraceToken: startupTraceToken,
                requestAdmission: requestAdmission,
                mediaResetID: mediaResetID,
                recoveryCoverIdentity: recoveryCoverIdentity,
                cdnSwitchID: cdnSwitchID,
                streamRetryID: streamRetryID
            )
        }
        await withTaskCancellationHandler {
            await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
    }

    func performLoadVOD(
        aid: Int,
        cid: Int,
        bvid: String?,
        quality: Int?,
        source: StreamSource,
        resumeAt: TimeInterval?,
        resumedPartNumber: Int? = nil,
        portraitHint: Bool?,
        aspectRatioHint: CGFloat? = nil,
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
        if consumeMiniPlayerReturnIfLiveVOD(
            aid: aid,
            cid: cid,
            bvid: bvid,
            source: source,
            quality: quality,
            ownerLease: ownerLease,
            startupTraceToken: startupTraceToken,
            mediaResetID: mediaResetID,
            recoveryCoverIdentity: recoveryCoverIdentity,
            cdnSwitchID: cdnSwitchID,
            streamRetryID: streamRetryID
        ) {
            clearPlayerInfoHandoff(matching: ownerLease)
            return
        }
        let sameContent = mode == .vod
            && aid == currentAid
            && cid == currentCid
            && source == currentSource
        let retainedBvid = sameContent ? currentBvid : nil
        let failedResumeHost = activeCDNSwitch.flatMap { transaction in
            cdnSwitchID == transaction.id ? CDNHostPolicy.canonicalHost(transaction.authority.videoURL?.host()) : nil
        }
        let failedFallbackHost = failedResumeHost
            ?? (sameContent && cdnFallbackActive
                ? CDNHostPolicy.canonicalHost(currentURL?.host() ?? stats.videoHost)
                : nil)
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
        let initialAspectHint = DetailPlayerGeometry.normalizedAspect(aspectRatioHint)
        let retainedAspectRatio = sameContent ? videoAspectRatio : nil
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
            portraitPureViewEnabled = false
            if portraitFullscreenContext?.ownerLease != ownerLease {
                portraitFullscreenContext = nil
            }
            sponsorSkippedUUIDs = []
            autoSkippedSegmentKeys = []
            pendingSponsorManualSegment = nil
        }
        let fallbackContentKey = Self.vodDecodeFallbackContentKey(aid: aid, cid: cid, source: source)
        if !sameContent || session.decodeFallback.contentKey != fallbackContentKey {
            session.decodeFallback = PlayerDecodeFallbackState(contentKey: fallbackContentKey)
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
        let effectivePortraitHint = portraitHint
            ?? initialAspectHint.map { DetailPlayerGeometry.isPortraitAspect($0) }
            ?? retainedPortraitHint
        videoAspectRatio = sameContent ? (retainedAspectRatio ?? initialAspectHint) : initialAspectHint
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
        pendingHistoryResumeNotice = nil
        pendingPartLocationNotice = nil
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
            PlayerLog.log("[Player] loadVOD: saved history marked watched to end — starting from 0")
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
                armDurableResumeTarget(nil, source: "restart")
                mediaTime = 0
            }
            let startAt = resumeAtTime ?? 0
            if !preservePlayState, mediaResetID == nil, cdnSwitchID == nil, streamRetryID == nil {
                if resumeIsFromHistory, let resumedSeconds = resumeAtTime, resumedSeconds > 2 {
                    pendingHistoryResumeNotice = PendingHistoryResumeNotice(
                        resumedSeconds: resumedSeconds,
                        partNumber: resumedPartNumber
                    )
                    pendingPartLocationNotice = nil
                } else if let resumedPartNumber, startAt <= 2 {
                    pendingHistoryResumeNotice = nil
                    pendingPartLocationNotice = resumedPartNumber
                }
            }

            var resolvedVideoStream: PlayURLResult.DashInfo.DashStream?
            if let dash = dashResult.dash {
                resolvedVideoStream = selectVideoStream(
                    from: dash.video,
                    quality: effectiveQ,
                    hardwareCapabilities: hardwareCapabilities,
                    requiresHardwareSupport: activeBackendKind == .demandPaced,
                    rejectedCodecKeys: session.decodeFallback.rejectedCodecKeys
                )
                if resolvedVideoStream == nil,
                   !dash.video.isEmpty,
                   activeBackendKind == .demandPaced,
                   handOffBackend(to: .vlc, reason: "vod dash stream requires software decode")
                       || activeBackendKind == .vlc {
                    session.decodeFallback.engineOverride = .vlc
                    session.decodeFallback.rejectedCodecKeys.removeAll()
                    queueDecodeFallbackNoticeIfNeeded(switchedEngine: true)
                    resolvedVideoStream = selectVideoStream(
                        from: dash.video,
                        quality: effectiveQ,
                        hardwareCapabilities: hardwareCapabilities,
                        requiresHardwareSupport: false,
                        rejectedCodecKeys: []
                    )
                }
            }

            if let dash = dashResult.dash,
               let videoStream = resolvedVideoStream {
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
                        startAt: startAt, track: .video, failedHost: failedFallbackHost
                    ) : nil,
                    failedHost: failedFallbackHost,
                    requestAdmission: probeAdmission
                )
                async let probedAudio: StreamURLSelection? = { () async -> StreamURLSelection? in
                    guard let bestAudio else { return nil }
                    return await self.selectReachableURL(
                        bestAudio.allURLs,
                        resume: runningEngine == .demandPaced ? .init(
                            startAt: startAt, track: .audio, failedHost: failedFallbackHost
                        ) : nil,
                        failedHost: failedFallbackHost,
                        requestAdmission: probeAdmission
                    )
                }()
                let videoSelection = await probedVideo
                let audioSelection = await probedAudio
                let videoURL = videoSelection.url
                var selectedAudio = bestAudio
                var audioURL = audioSelection?.url
                var audioFallbackEvidence: StreamProbeEvidence?
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

                if let primaryAudio = selectedAudio, audioURL == nil {
                    let fallbackEvidence = StreamProbeEvidence()
                    audioFallbackEvidence = fallbackEvidence
                    if let recovered = await recoverOfferedAudioURL(
                        primary: primaryAudio,
                        dash: dash,
                        preference: audioPreference,
                        videoURL: videoURL,
                        runningEngine: runningEngine,
                        startAt: startAt,
                        failedHost: failedFallbackHost,
                        evidence: fallbackEvidence,
                        requestAdmission: probeAdmission
                    ) {
                        selectedAudio = recovered.stream
                        audioURL = recovered.url
                        playingAudioTier = AudioQualityTier(rawValue: recovered.stream.id)
                        stats.audioCodec = recovered.stream.codecs
                        stats.audioBitrate = recovered.stream.bandwidth
                        stats.audioTier = playingAudioTier
                    }
                    guard mediaResetRecovery.allowsLoadCompletion(
                              loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                          ),
                          ownerLease.map({ self.isCurrentOwner($0) }) ?? true,
                          admitsLoadRequest(
                            requestAdmission?() ?? true,
                            after: "audio-fallback-probe",
                            token: startupTraceToken ?? self.startupTraceToken
                          ) else { return }
                    try Self.checkLoadCancellation()
                }

                if selectedAudio != nil, audioURL == nil, runningEngine == .demandPaced {
                    let combinedOutcomes = (audioSelection?.outcomes ?? [])
                        + (audioFallbackEvidence?.outcomes ?? [])
                    let combinedSelection = StreamURLSelection(
                        url: nil,
                        outcomes: combinedOutcomes,
                        cancelled: Task.isCancelled || !probeAdmission()
                    )
                    PlayerLog.log(
                        "[StreamRetry] offered-audio unreachable after fallback — aborting video-only demand open " +
                            "reasons=\(combinedOutcomes.map(\.diagnostic))"
                    )
                    if let failure = combinedSelection.eligibleFailure,
                       handleStreamTransportFailure(failure, quality: q, loadGeneration: generation) { return }
                    guard settleResetPreOpenFailure(
                        loadCompletion, retryable: PlaybackUnavailability.streamUnreachable.isRetryable
                    ) else { return }
                    retireStreamRecovery(reason: "permanent-audio-probe")
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
                streamNominalBitrate = videoStream.bandwidth + (selectedAudio?.bandwidth ?? 0)
                PlayerLog.log("[Player] DASH: \(videoStream.codecs) qn=\(videoStream.id) audio=\(audioURL != nil)")

                multiConnectionVideoURLs = videoStream.allURLs
                multiConnectionAudioURLs = selectedAudio?.allURLs ?? []
                let videoBootstrapIdentity = Self.selectedDASHBootstrapIdentity(
                    aid: aid, cid: cid, source: source, track: .video, stream: videoStream
                )
                let audioBootstrapIdentity = audioURL == nil ? nil : selectedAudio.map {
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
            let durlSelection = await selectReachableURL(
                durlResult.durl?.first.map { [$0.url] } ?? [],
                failedHost: failedFallbackHost
            )
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

    private func recoverOfferedAudioURL(
        primary: PlayURLResult.DashInfo.DashStream,
        dash: PlayURLResult.DashInfo,
        preference: AudioQualityTier,
        videoURL: URL,
        runningEngine: PlayerEngineKind,
        startAt: TimeInterval,
        failedHost: String?,
        evidence: StreamProbeEvidence,
        requestAdmission: @escaping @MainActor @Sendable () -> Bool
    ) async -> (stream: PlayURLResult.DashInfo.DashStream, url: URL)? {
        guard !Task.isCancelled, requestAdmission() else { return nil }
        if let sameHost = AudioStreamSelection.rewriteStreamURL(primary.allURLs, toHostOf: videoURL),
           await probeURL(sameHost, evidence: evidence),
           !Task.isCancelled, requestAdmission() {
            PlayerLog.log(
                "[CDN] recovered offered audio id=\(primary.id) on proven video host=" +
                    "\(CDNHostPolicy.diagnosticHost(sameHost.host()))"
            )
            return (primary, sameHost)
        }
        let alternates = AudioStreamSelection.fallbackCandidates(
            in: dash,
            preference: preference,
            excludingID: primary.id,
            decodable: { runningEngine.decodesAudio($0) }
        )
        for alternate in alternates {
            guard !Task.isCancelled, requestAdmission() else { return nil }
            if let sameHost = AudioStreamSelection.rewriteStreamURL(alternate.allURLs, toHostOf: videoURL),
               await probeURL(sameHost, evidence: evidence),
               !Task.isCancelled, requestAdmission() {
                PlayerLog.log(
                    "[CDN] recovered audio via alternate tier id=\(alternate.id) on proven video host=" +
                        "\(CDNHostPolicy.diagnosticHost(sameHost.host()))"
                )
                return (alternate, sameHost)
            }
            guard !Task.isCancelled, requestAdmission() else { return nil }
            let selection = await selectReachableURL(
                alternate.allURLs,
                resume: runningEngine == .demandPaced ? .init(
                    startAt: startAt, track: .audio, failedHost: failedHost
                ) : nil,
                failedHost: failedHost,
                requestAdmission: requestAdmission
            )
            evidence.outcomes.append(contentsOf: selection.outcomes)
            if let recovered = selection.url, !Task.isCancelled, requestAdmission() {
                PlayerLog.log(
                    "[CDN] recovered audio via alternate tier id=\(alternate.id) host=" +
                        "\(CDNHostPolicy.diagnosticHost(recovered.host()))"
                )
                return (alternate, recovered)
            }
        }
        return nil
    }
}
