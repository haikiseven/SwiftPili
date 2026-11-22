import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    @discardableResult
    func loadLive(
        roomID: Int,
        quality: Int = LiveAPI.defaultLiveQuality,
        playInfo preloaded: LivePlayInfo? = nil,
        preservePlayState: Bool = false,
        owner: String? = nil,
        ownerLease: PlayerOwnerLease? = nil,
        mediaResetID: UUID? = nil
    ) async -> Int? {
        await Task {
            await performLoadLive(
                roomID: roomID,
                quality: quality,
                playInfo: preloaded,
                preservePlayState: preservePlayState,
                owner: owner,
                ownerLease: ownerLease,
                mediaResetID: mediaResetID
            )
        }.value
    }

    private func openResolvedLiveTuple(
        _ resolved: LiveDemandResolvedTuple,
        playInfo: LivePlayInfo,
        hardwareCapabilities: VideoHardwareCapabilities.Snapshot
    ) -> Int {
        currentLiveQuality = resolved.actualQn
        publishLiveQualityStats(resolved.actualQn, from: playInfo)
        stats.decoderType = decoderLabel(
            codecs: resolved.codecFourCC,
            hardwareSupported: hardwareCapabilities.supports(codecs: resolved.codecFourCC)
        )
        stats.codec = resolved.codecFourCC
        isDASHMode = false
        currentVideoIsAV1 = resolved.metadata.codecName == "av1"
        playURL(resolved.url, liveSource: resolved.demandSource(for: currentOwnerLease))
        return resolved.actualQn
    }

    private func logLiveEngineRoute(
        _ route: LiveEngineRoute,
        requestedQn: Int,
        demand: LiveDemandSelection,
        native: LiveDemandSelection,
        pinned: Bool
    ) {
        let verdict: String
        switch route {
        case .demand(let resolved):
            verdict = "engine=demand qn=\(resolved.actualQn) " +
                "tuple=\(resolved.metadata.tupleFamily)"
        case .libVLC(let resolved, let reason):
            verdict = "engine=vlc qn=\(resolved.actualQn) " +
                "tuple=\(resolved.metadata.tupleFamily) reason=\(reason.rawValue)"
        case .refused(let failure):
            verdict = "engine=none refused=\(failure.classification.rawValue) " +
                "blocking=\(failure.blockingLabelsForLogging) " +
                "reasons=\(failure.rejectionReasonSummary)"
        }
        PlayerLog.log(
            "[Player] live engine route requestedQn=\(requestedQn) " +
            "pinned=\(pinned ? 1 : 0) " +
            "demandQn=\(demand.selected.map { String($0.actualQn) } ?? "-") " +
            "nativeQn=\(native.selected.map { String($0.actualQn) } ?? "-") " +
            verdict
        )
    }

    private func publishLiveQualityStats(_ qn: Int, from playInfo: LivePlayInfo) {
        let advertised = (playInfo.playurlInfo?.playurl?.gQnDesc ?? [])
            .map { (qn: $0.qn, desc: $0.desc) }
        stats.quality = qn
        stats.qualityDesc = LiveQualityDescription.text(for: qn, advertised: advertised)
    }

    private func livePlayInfo(
        roomID: Int,
        quality: Int,
        preloaded: LivePlayInfo?
    ) async throws(BiliError) -> LivePlayInfo {
        if let preloaded { return preloaded }
        return try await LiveAPI.getPlayInfo(roomID: roomID, quality: quality)
    }

    private func performLoadLive(
        roomID: Int,
        quality: Int,
        playInfo preloaded: LivePlayInfo?,
        preservePlayState: Bool,
        owner: String?,
        ownerLease: PlayerOwnerLease?,
        mediaResetID: UUID?
    ) async -> Int? {
        if let mediaResetID,
           !mediaResetRecovery.accepts(mediaResetID, owner: currentOwnerLease) { return nil }
        guard PlayerLoadAdmissionPolicy.allows(
            targetMode: .live,
            requestedOwner: owner,
            currentOwner: ownerKey,
            currentMode: mode
        ),
        (owner != nil || (mode == .live && currentRoomID == roomID)),
        ownerLease?.matches(
            currentOwner: ownerKey,
            currentGeneration: ownerLeaseGeneration
        ) ?? true else {
            PlayerLog.log(
                "[Player] loadLive dropped — requestedOwner=\(owner ?? "internal") " +
                "currentOwner=\(ownerKey.isEmpty ? "-" : ownerKey) mode=\(mode)"
            )
            return nil
        }
        retireStartupTraceBeforeNonVODLoad(.live)
        let sameContent = mode == .live && currentRoomID == roomID
        let teardownReason = PlayerReloadPresentationPolicy.reason(
            targetMode: .live,
            currentMode: mode,
            sameContent: sameContent,
            newOwner: presentationResetPendingForOwnerChange
        )
        playbackTerminalState = .active
        if !sameContent {
            nowPlayingMeta = nil
        }
        terminalOpenFailure = true
        stop(reason: teardownReason, mediaResetID: mediaResetID)
        presentationResetPendingForOwnerChange = false
        resetMultiConnectionDisplay()
        loadGeneration += 1
        let generation = loadGeneration
        if let mediaResetID { mediaResetRecovery.bind(mediaResetID, loadGeneration: generation) }
        let loadCompletion = PlayerMediaResetRecovery<MediaResetSource>.LoadCompletion(
            generation: generation, owner: ownerLease, resetID: mediaResetID
        )
        mode = .live
        armDurableResumeTarget(nil, source: "live-load")
        currentRoomID = roomID
        currentLiveQuality = quality
        playbackRate = 1.0
        if !preservePlayState {
            playbackIntent = .playing
        }
        error = nil
        unavailability = nil
        availableQualities = []
        availableCodecs = []
        availableAudioTiers = []
        playingAudioTier = nil
        stats.quality = 0
        stats.qualityDesc = ""
        seedLivePortraitOrientation(from: preloaded, sameContent: sameContent)
        inlineCondensed = false
        portraitCondenseLocked = false

        do {
            let playInfo = try await livePlayInfo(roomID: roomID, quality: quality, preloaded: preloaded)
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  PlayerLoadAdmissionPolicy.allows(
                      targetMode: .live,
                      requestedOwner: owner,
                      currentOwner: ownerKey,
                      currentMode: mode
                  ),
                  (owner != nil || (mode == .live && currentRoomID == roomID)),
                  ownerLease?.matches(
                      currentOwner: ownerKey,
                      currentGeneration: ownerLeaseGeneration
                  ) ?? true else { return nil }
            seedLivePortraitOrientation(from: playInfo, sameContent: true)

            let hardwareCapabilities = await VideoHardwareCapabilities.snapshot()
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  PlayerLoadAdmissionPolicy.allows(
                      targetMode: .live,
                      requestedOwner: owner,
                      currentOwner: ownerKey,
                      currentMode: mode
                  ),
                  owner != nil || (mode == .live && currentRoomID == roomID),
                  ownerLease?.matches(
                      currentOwner: ownerKey,
                      currentGeneration: ownerLeaseGeneration
                  ) ?? true else { return nil }
            try Self.checkLoadCancellation()

            if preferredBackendKind == .demandPaced {
                return openDemandPreferredLiveRoute(
                    playInfo: playInfo,
                    quality: quality,
                    hardwareCapabilities: hardwareCapabilities,
                    loadCompletion: loadCompletion
                )
            }

            guard let url = resolveLiveURL(playInfo) else {
                guard settleResetPreOpenFailure(loadCompletion, retryable: true) else { return nil }
                error = String(localized: "No live stream URL found")
                return nil
            }
            publishLiveQualityStats(quality, from: playInfo)
            stats.decoderType = decoderLabel(
                codecs: "avc1", hardwareSupported: hardwareCapabilities.supports(codecs: "avc1")
            )
            stats.codec = "live"
            isDASHMode = false
            currentVideoIsAV1 = false
            playURL(url)
            return quality
        } catch {
            guard mediaResetRecovery.allowsLoadCompletion(
                      loadCompletion, currentGeneration: loadGeneration, currentOwner: currentOwnerLease
                  ),
                  PlayerLoadAdmissionPolicy.allows(
                      targetMode: .live,
                      requestedOwner: owner,
                      currentOwner: ownerKey,
                      currentMode: mode
                  ),
                  owner != nil || (mode == .live && currentRoomID == roomID) else { return nil }
            let refusal = PlaybackAvailabilityPolicy.unavailability(forAny: error)
            guard settleResetPreOpenFailure(
                loadCompletion, retryable: error.isCancellation || (refusal?.isRetryable ?? true)
            ) else { return nil }
            if error.isCancellation {
                PlayerLog.log("[Player] loadLive cancelled (benign) — no error surfaced")
                return nil
            }
            if let reason = refusal {
                markUnavailable(reason, detail: "loadLive")
                return nil
            }
            self.error = error.localizedDescription
            isBuffering = false
            PlayerLog.log("[Player] loadLive failed: \(error)")
            return nil
        }
    }

    private func openDemandPreferredLiveRoute(
        playInfo: LivePlayInfo,
        quality: Int,
        hardwareCapabilities: VideoHardwareCapabilities.Snapshot,
        loadCompletion: PlayerMediaResetRecovery<MediaResetSource>.LoadCompletion
    ) -> Int? {
        let demandSelection = LiveDemandCandidateResolver.select(
            info: playInfo,
            requestedQn: quality,
            capabilities: LiveDemandDeviceCapabilities(
                supportsHLSFMP4: true,
                supportsProgressiveFMP4: true,
                supportsLibavformatLive: DemandMediaEngineAssembly.supportsLibavformatLive,
                supportsAVC: true,
                supportsHEVC: hardwareCapabilities.hevc,
                supportsAV1: hardwareCapabilities.av1
            )
        )
        logLiveCandidateSelection(demandSelection)
        let nativeSelection = LiveDemandCandidateResolver.selectNative(
            info: playInfo,
            requestedQn: quality
        )
        let pinned = PlayerEngineKind.pinsLiveEngine
        let route = LiveEngineRoutePolicy.route(
            demand: demandSelection,
            native: nativeSelection,
            pinsPreferredEngine: pinned
        )
        logLiveEngineRoute(
            route,
            requestedQn: quality,
            demand: demandSelection,
            native: nativeSelection,
            pinned: pinned
        )

        switch route {
        case .refused(let failure):
            guard settleResetPreOpenFailure(
                loadCompletion, retryable: failure.isRetryable
            ) else { return nil }
            markTerminalOpenFailure(failure)
            return nil

        case .demand(let resolved):
            handOffBackend(to: .demandPaced, reason: "live route")
            return openResolvedLiveTuple(
                resolved, playInfo: playInfo, hardwareCapabilities: hardwareCapabilities
            )

        case .libVLC(let resolved, let reason):
            guard handOffBackend(to: .vlc, reason: "live \(reason.rawValue)")
                || activeBackendKind == .vlc else {
                guard settleResetPreOpenFailure(loadCompletion, retryable: false) else { return nil }
                markUnavailable(.noPlayableStream, detail: "live-libvlc-engine-unavailable")
                return nil
            }
            return openResolvedLiveTuple(
                resolved, playInfo: playInfo, hardwareCapabilities: hardwareCapabilities
            )
        }
    }
}

extension PlayerViewModel {

    private func logLiveCandidateSelection(_ selection: LiveDemandSelection) {
        PlayerLog.diagnostic(
            "[Player] live resolver summary requestedQn=\(selection.requestedQn) " +
                "candidateCount=\(selection.candidateCount) " +
                "inputShape=\(selection.inputShape.sanitizedSummary)"
        )
        PlayerLog.diagnostic(
            "[Player] live resolver input-shape requestedQn=\(selection.requestedQn) " +
                selection.inputShape.sanitizedSummary
        )

        let maxLoggedCandidates = 24
        let visible = Array(selection.candidates.prefix(maxLoggedCandidates))
        let omitted = selection.candidates.count - visible.count
        let accepted = visible
            .filter { $0.rejectionReason == nil }
            .map(\.sanitizedSummary)
        let rejected = visible
            .filter { $0.rejectionReason != nil }
            .map(\.sanitizedSummary)
        let suffix = omitted > 0 ? " +\(omitted) more" : ""
        PlayerLog.log(
            "[Player] live resolver requestedQn=\(selection.requestedQn) " +
                "candidateCount=\(selection.candidateCount) " +
                "accepted=[\(accepted.joined(separator: " | "))]\(suffix) " +
                "rejected=[\(rejected.joined(separator: " | "))]"
        )

        if let selected = selection.selected {
            PlayerLog.log(
                "[Player] live resolver selected=\(selected.metadata.sanitizedSummary) " +
                    "actualQn=\(selected.actualQn)"
            )
            if let fallback = selection.qualityFallback {
                PlayerLog.diagnostic(
                    "[Player] live resolver quality fallback " +
                        "requestedQn=\(fallback.requestedQn) actualQn=\(fallback.actualQn)"
                )
            }
        } else if let failure = selection.failure {
            PlayerLog.diagnostic(
                "[Player] live resolver terminal " +
                    "classification=\(failure.classification.rawValue) " +
                    "blocking=\(failure.blockingLabelsForLogging) " +
                    "retryable=\(failure.isRetryable) " +
                    "reason=\(failure.rejectionReasonSummary) " +
                    "requestedQn=\(selection.requestedQn) " +
                    "families=\(failure.availableFamiliesForLogging)"
            )
        }
    }

    private func resolveLiveURL(_ info: LivePlayInfo) -> URL? {
        guard let streams = info.playurlInfo?.playurl?.stream, !streams.isEmpty else {
            PlayerLog.log("[Player] live: no streams in playInfo")
            return nil
        }

        let protocolOrder = ["http_hls", "http_stream"]
        let sortedStreams = streams.sorted { a, b in
            let ai = protocolOrder.firstIndex(of: a.protocolName) ?? protocolOrder.count
            let bi = protocolOrder.firstIndex(of: b.protocolName) ?? protocolOrder.count
            return ai < bi
        }

        let formatOrder = ["fmp4", "ts", "flv"]
        for stream in sortedStreams {
            let sortedFormats = stream.format.sorted { a, b in
                let ai = formatOrder.firstIndex(of: a.formatName) ?? formatOrder.count
                let bi = formatOrder.firstIndex(of: b.formatName) ?? formatOrder.count
                return ai < bi
            }

            for format in sortedFormats {
                let codecOrder = ["avc", "hevc", "av1"]
                let sortedCodecs = format.codec.sorted { a, b in
                    let ai = codecOrder.firstIndex(of: a.codecName) ?? codecOrder.count
                    let bi = codecOrder.firstIndex(of: b.codecName) ?? codecOrder.count
                    return ai < bi
                }

                for codec in sortedCodecs {
                    for urlInfo in codec.urlInfo ?? [] {
                        let rawURL = urlInfo.host + codec.baseUrl + urlInfo.extra
                        guard let url = URL(string: rawURL) else { continue }
                        PlayerLog.log(
                            "[Player] live: \(stream.protocolName)/\(format.formatName)/" +
                                "\(codec.codecName) qn=\(codec.currentQn ?? 0)"
                        )
                        return url
                    }
                    if codec.urlInfo == nil || codec.urlInfo?.isEmpty == true,
                       let url = URL(string: codec.baseUrl) {
                        return url
                    }
                }
            }
        }

        if let stream = streams.first,
           let format = stream.format.first,
           let codec = format.codec.first {
            PlayerLog.log(
                "[Player] live fallback: \(stream.protocolName)/\(format.formatName)/\(codec.codecName)"
            )
            if let urlInfo = codec.urlInfo?.first,
               let url = URL(string: urlInfo.host + codec.baseUrl + urlInfo.extra) {
                return url
            }
            if let url = URL(string: codec.baseUrl) {
                return url
            }
        }

        PlayerLog.log("[Player] live: no usable stream found")
        return nil
    }

    func seedLivePortraitOrientation(from playInfo: LivePlayInfo?, sameContent: Bool) {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let hint = isPad ? false : playInfo?.isPortrait
        if !sameContent {
            isPortraitContent = hint ?? false
        } else if let hint, !portraitPropagation.hasValidVideoGeometry {
            isPortraitContent = hint
        } else {
            return
        }
        portraitPropagation = PlayerPortraitPropagationState(
            mode: .live,
            apiHint: hint,
            initialIsPortrait: isPortraitContent
        )
    }
}
