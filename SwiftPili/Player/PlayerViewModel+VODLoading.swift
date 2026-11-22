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
        // A load whose initiating screen has since lost the player must not start.
        guard requestAdmission?() ?? true else {
            // A pager's latest-wins request can become stale after loadVOD leaves the caller's task but before
            // this cancellation-shielded worker starts.
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
        // Internal VOD reloads must still identify the media they were launched for.
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
        // stop() clears the stored bvid. A same-content reload (quality, codec,
        // CDN) has no fresh string; keep the one this video already carried.
        // A different load with no string stays nil — never derived from the aid.
        let retainedBvid = sameContent ? currentBvid : nil
        // The admitted switch owns the outgoing video URL. Carry its host
        // across teardown and the playurl refresh for both track selections.
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
        // Queue-next/new-content and ordinary same-content reloads are normal
        // load admissions. Reset the prior EOF before stop/API awaits so a
        // delayed lifecycle callback cannot poison the successor epoch.
        playbackTerminalState = .active

        if !sameContent {
            cdnFallbackActive = false
            resumeAtTime = nil
            resumeIsFromHistory = false
            // An in-player audio pick belongs to the video it was made on.
            audioTierOverride = nil
            // New content, new budget. An internal reload of the SAME video
            // (quality drop, codec switch, CDN switch) must NOT reset it, or
            // the ladder it is climbing loops forever.
            resetRecoveryBudget()
            nowPlayingMeta = nil
            // Episode chrome/context belongs to the previous content —
            // its owning screen re-installs them right after loadVOD.
            onPreviousEpisode = nil
            onNextEpisode = nil
            pgcSeasonContext = nil
            inlineCondensed = false
            portraitCondenseLocked = false
            // New content: forget which SponsorBlock segments were skipped
            // (a quality/CDN reload of the SAME video keeps them, so a
            // segment already skipped doesn't bounce forward again).
            sponsorSkippedUUIDs = []
            // Same reasoning for OP/ED: a same-video reload keeps the set so an
            // already-skipped intro doesn't bounce forward again; only a new
            // video forgets it.
            autoSkippedSegmentKeys = []
            pendingSponsorManualSegment = nil
        }
        // A parked backend session must survive the load's own preparatory teardown: backend.load adjudicates
        // the ticket right after (claims the same content, discards+stops anything else), so destroying it
        // here would make the warm re-entry path unreachable.
        stop(reason: teardownReason, preservingParkedBackend: backend.hasParkedSession,
             mediaResetID: mediaResetID, recoveryCoverIdentity: recoveryCoverIdentity,
             cdnSwitchID: cdnSwitchID, streamRetryID: streamRetryID)
        presentationResetPendingForOwnerChange = false
        // Placed after the park-aware teardown deliberately: `hasParkedSession` is then read on the instance
        // that actually holds the ticket, and an engine that returns `false` for `parkForReuse` (libVLC) can
        // never be holding one to destroy here.
        restorePreferredBackendForLoad("vod load")
        // AFTER stop(): stop() bumps loadGeneration to invalidate
        // in-flight loads, so this load's own generation must be
        // captured past that bump or its guards would kill it.
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
        // A screen request owns its trace token. Internal reloads pass nil and
        // intentionally retain the current screen token, if one is still
        // active, without starting a second cold-start session.
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
            isPortraitContent = UIDevice.current.userInterfaceIdiom != .pad
                && (effectivePortraitHint ?? false)
        } else if let effectivePortraitHint {
            isPortraitContent = UIDevice.current.userInterfaceIdiom != .pad
                && effectivePortraitHint
        }
        portraitPropagation = PlayerPortraitPropagationState(
            mode: .vod,
            apiHint: effectivePortraitHint,
            initialIsPortrait: isPortraitContent
        )
        // A quality/codec pick from the menus while paused must NOT
        // restart playback against the user's intent.
        if !preservePlayState {
            playbackIntent = .playing
        }
        // Fresh decision per load — a stale flag from a video that never
        // reached readyToPlay must not toast over the next one.
        pendingRestartNotice = false
        // Reopen visibility + durable intent: every load states why it is (re)opening and what position it
        // owes the user.
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
            // The demuxer opens there and no clock tick fires until the gated start releases, so leaving 0
            // here meant a load abandoned mid-align reported progress=0s at teardown and clobbered the very
            // history point it was resuming from.
            mediaTime = resumeAt
            PlayerLog.log("[Player] loadVOD: will resume at \(String(format: "%.0f", resumeAt))s once ready")
        } else if let resumeAt, resumeAt < 0 {
            // Deferred to readyToPlay: showing it here (or in the lookup, as before) put it in the notice slot
            // that stop() above just cleared — the toast died within the frame it was born.
            pendingRestartNotice = true
        } else if let resumeAt {
            PlayerLog.log("[Player] loadVOD: resume point \(String(format: "%.1f", resumeAt))s too early — starting from 0")
        }
        // CC subtitle list, concurrent with the stream fetches.
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
        // Same-session reloads (CDN switch, decoder/quality/codec reload) keep it to recover the user's
        // intended position.
        if !preservePlayState { lastSeekRequest = nil }
        error = nil
        // A new load is a new verdict: a refusal belongs to the source that
        // produced it, and carrying it forward would make the successor
        // unplayable and un-retryable before it ever asked the server.
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
            // Shared preparation outlives a cancelled waiter. Route its local
            // cancellation through the existing owned failure/Retry policy.
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
            // 4K/HDR/Dolby/8K (qn ≥ 120): rank CDN nodes by measured throughput before geo proximity — a fat
            // distant pipe beats a thin near one.
            SmartCDNSelector.shared.preferThroughput = effectiveQ >= 120

            if resumeIsFromHistory, let t = resumeAtTime,
               let dur = (dashResult.dash?.duration).map(TimeInterval.init), dur > 10,
               t >= dur - max(15, dur * 0.02) {
                PlayerLog.log("[Player] saved position \(String(format: "%.1f", t))s is at the end of \(String(format: "%.1f", dur))s — playing from beginning")
                resumeAtTime = nil
                resumeIsFromHistory = false
                pendingRestartNotice = true
                // Undo the resume-armed clock preset — playback continues from 0 now.
                armDurableResumeTarget(nil, source: "restart")
                mediaTime = 0
            }
            // Captured once: a user scrub during the load reassigns resumeAtTime, and readyToPlay only skips
            // its restore seek when the pending target still matches what the demuxer opened at
            // (options.startPlayTime).
            let startAt = resumeAtTime ?? 0

            // The offered-codec list only matches strings, without native queries.
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
                // Audio tier: the in-player pick for this content, else the Wi-Fi/cellular preference — and
                // only among tiers the RUNNING engine decodes.
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

                // Probe video and audio mirrors in PARALLEL — running
                // them serially added a full probe round trip to every
                // time-to-first-frame.
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
                    // Settle while this load still owns its captured generation;
                    // retiring retry work then invalidates that generation.
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
                // Authoritative demand for the delivery-health monitor —
                // stable across the decoder's instantaneous-rate stat.
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

            // Last resort: durl at whatever quality. The DASH path above
            // skipped the fetch — do it now, since a broken DASH manifest
            // beats no playback at all.
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
                // durl is one progressive file with audio and video muxed together — Bilibili serves it only
                // for very old uploads that were never transcoded to DASH (the web player falls back to flv.js
                // for them).
                guard handOffBackend(to: .vlc, reason: "vod durl (muxed progressive)")
                    || activeBackendKind == .vlc else {
                    // Demand cannot play a muxed durl and libVLC cannot run here: a settled "nothing openable".
                    guard settleResetPreOpenFailure(loadCompletion, retryable: false) else { return }
                    retireStreamRecovery(reason: "durl-engine-unavailable")
                    markUnavailable(.noPlayableStream, detail: "durl-libvlc-engine-unavailable")
                    return
                }
                availableCodecs = []
                availableAudioTiers = []
                playingAudioTier = nil
                // durl is a muxed AVC fallback. Do not retain codec/audio
                // metadata from an earlier DASH candidate.
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
                currentVideoIsAV1 = false // durl is muxed (AVC/HEVC), never AV1
                streamNominalBitrate = 0 // muxed durl: no per-stream bandwidth
                PlayerLog.log("[Player] durl fallback: qn=\(fallback.quality)")
                // No startAt here: this path can serve FLV/multi-segment durl, where an avformat pre-seek
                // stalls or lands on garbage (no index) — the readyToPlay restore seek attempts the position
                // the ordinary way instead.
                playURL(durlURL, cdnSwitchID: cdnSwitchID, streamRetryID: streamRetryID)
                startHistoryReporting()
                return
            }

            // The durl probe above awaits too — a stale load resuming here
            // must not paint terminal failure over the live successor, and a
            // withdrawn one must not paint it over a page nobody is watching.
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
            // Probe outcome (durl candidates), not a server verdict: retryable.
            guard settleResetPreOpenFailure(
                loadCompletion, retryable: PlaybackUnavailability.streamUnreachable.isRetryable
            ) else { return }
            retireStreamRecovery(reason: "permanent-durl")
            markTransientStreamUnreachable()
        } catch {
            // A stale load's failure must not paint an error over the video that superseded it.
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
            // A cancelled playurl fetch (screen dismissed, network hand-off tearing down sockets, Swift task
            // cancellation) is not a playback failure — surfacing it painted "Network error: cancelled" over
            // perfectly recoverable situations.
            if error.isCancellation {
                // Benign only when something else owns the screen's fate: a newer load superseded us
                // (generation moved) or the screen tore down (stop() moved it too).
                if generation == loadGeneration, currentURL == nil {
                    PlayerLog.log("[Player] loadVOD cancelled after teardown with no successor — surfacing Retry")
                    // No successor and no stream: nothing else will ever
                    // close this load's trace session.
                    StartupTrace.abort("load-cancelled", token: startupTraceToken ?? self.startupTraceToken)
                    self.error = String(localized: "Loading was interrupted. Tap Retry.")
                } else {
                    // Benign: a successor's begin() already replaced the
                    // session (or the owner-exit stop closed it) — do NOT
                    // abort here, that would kill the successor's session.
                    PlayerLog.log("[Player] loadVOD cancelled (benign) — no error surfaced")
                }
                return
            }
            // A settled refusal (deleted, private, region-locked, unpublished, paid, sign-in) is not a failure
            // to retry.
            if let reason = refusal {
                markUnavailable(reason, detail: "loadVOD")
                return
            }
            // Generation-guarded above: the active session is this load's.
            StartupTrace.abort("load-failed", token: startupTraceToken ?? self.startupTraceToken)
            self.error = error.localizedDescription
            isBuffering = false
            PlayerLog.log("[Player] loadVOD failed: \(error)")
        }
    }
}
