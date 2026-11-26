import Foundation

extension MediaEngineSession {
    // MARK: - Launch & Seek Reserve Budgets

    var requiredAudioLaunchContentSeconds: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return max(0.000_5, audioRender.launchReserveContentSeconds)
    }

    var audioLaunchPumpContentBudget: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return requiredAudioLaunchContentSeconds + minTrackFillRoom
    }

    var requiredAudioSeekContentSeconds: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return max(0.000_5, audioRender.seekTransitionReserveContentSeconds)
    }

    var audioSeekPumpContentBudget: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return requiredAudioSeekContentSeconds + minTrackFillRoom
    }

    var launchReadiness: (video: Bool, audio: Bool) {
        (
            video: videoDecoderOpened && !pendingVideoFrames.isEmpty,
            audio: !hasAudioTrack || (
                audioDecoderOpened
                    && pendingAudioContentSeconds + 1e-9 >= requiredAudioLaunchContentSeconds
            )
        )
    }

    // MARK: - Seek Lifecycle

    func logSeekTrace(
        phase: String,
        target: TimeInterval,
        token: MediaAudioSeekToken? = nil,
        result: Bool? = nil,
        demuxResult: Bool? = nil,
        decoderFlush: Bool? = nil,
        videoReady: Bool? = nil,
        audioReady: Bool? = nil
    ) {
        guard diagnostics.isCapturing else { return }
        func boundedTime(_ value: TimeInterval) -> TimeInterval {
            value.isFinite ? max(0, value) : 0
        }
        func flag(_ value: Bool?) -> Int {
            value.map { $0 ? 1 : 0 } ?? -1
        }
        diagnostics.log(
            "[PathASeekSession] phase=\(phase) sessionGen=\(runtimeGeneration) " +
            "seekGen=\(generation) " +
            "tokenGen=\(token?.generation ?? 0) decoderID=\(videoDecoder.debugSessionID) " +
            "target=\(String(format: "%.3f", boundedTime(target))) " +
            "result=\(flag(result)) demux=\(flag(demuxResult)) " +
            "flush=\(flag(decoderFlush)) vOpen=\(videoDecoderOpened ? 1 : 0) " +
            "vReady=\(flag(videoReady)) aReady=\(flag(audioReady)) " +
            "vPkts=\(videoPackets.count) aPkts=\(audioPackets.count) " +
            "vRes=\(residualVideoPackets.count) aRes=\(residualAudioPackets.count) " +
            "pendingV=\(pendingVideoFrames.count) " +
            "pcm=\(String(format: "%.3f", boundedTime(pendingAudioContentSeconds))) " +
            "eof=\(demuxReachedEOF ? 1 : 0)"
        )
    }

    func prepareSeek(to time: TimeInterval) async -> MediaEngineSeekPreparation {
        let captureReceipt = UUID()
        pausedCaptureSeekPreparationReceipt = captureReceipt
        defer {
            if pausedCaptureSeekPreparationReceipt == captureReceipt {
                pausedCaptureSeekPreparationReceipt = nil
            }
        }
        (videoRender as? SampleBufferVideoRenderer)?.retireNonWarmPresentationImage()
        let seekEntryGeneration = generation
        let seekEntryOwnerGeneration = activeOwnerGeneration
        func supersededPreparation() -> MediaEngineSeekPreparation {
            MediaEngineSeekPreparation(
                token: MediaAudioSeekToken(generation: 0),
                target: max(0, time),
                stagedContentSeconds: 0,
                isReady: false
            )
        }
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        supersedeWarmVideoPreparationRun()
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        revokeAudioMaintenancePermission()
        await audioRender.awaitAudioMaintenanceSettlement()
        guard !Task.isCancelled, generation == seekEntryGeneration,
              activeOwnerGeneration == seekEntryOwnerGeneration else { return supersededPreparation() }
        let previousDecodeTask = decodeTask
        let previousAudioDecodeTask = audioDecodeTask
        cancelDecode()
        await previousDecodeTask?.value
        await previousAudioDecodeTask?.value
        guard !Task.isCancelled,
              generation == seekEntryGeneration,
              activeOwnerGeneration == seekEntryOwnerGeneration else {
            return supersededPreparation()
        }
        disarmPresentFeed()
        resetVideoLivenessState(resetStartup: false)
        resetPipeInstrumentWindow()
        resetFlowGapTracking()
        let helperState: MultiConnectionTelemetry.State = hasMultiConnectionHelpers
            ? (helperTelemetry.value.state == .unsupported ? .unsupported : .pending)
            : .notConfigured
        lastMultiConnectionPlaybackPosition = nil
        helperTelemetry.invalidate(helperState)
        generation &+= 1
        let gen = generation
        let predecessor = lifecycleSerialTask
        await predecessor?.value
        guard isCurrentGeneration(gen) else {
            return supersededPreparation()
        }
        runtimeFaultedGeneration = nil
        publishedRuntimeFaultGeneration = nil
        let token = audioRender.beginSeekTransition(source: self)
        beginSeekTransaction(token: token)
        consecutiveVideoPresentErrorCount = 0
        seekPhaseStopwatch = SeekPhaseStopwatch(
            token: token.generation,
            isEnabled: diagnostics.isCapturing
        )
        logSeekTrace(
            phase: "generation",
            target: time,
            token: token,
            result: true
        )
        hasEmittedEnded = false
        isBuffering = false
        demuxReachedEOF = false
        audioEOFDrain.reset()
        let audioGraphWasRunning = audioRender.isRunning
        diagnostics.log(
            "[PathA] seek audio graph " +
            (audioGraphWasRunning ? "kept running" : "already stopped")
        )
        applyDisplayPlayback(rate: 0)

        func notReady() -> MediaEngineSeekPreparation {
            MediaEngineSeekPreparation(
                token: token,
                target: clock.mediaTime,
                stagedContentSeconds: 0,
                isReady: false
            )
        }

        do {
            try await demux.seek(to: time)
            seekPhaseStopwatch?.mark(.demux)
            logSeekTrace(
                phase: "demux",
                target: time,
                token: token,
                result: true,
                demuxResult: true
            )
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            clock.seek(to: time)
            updatePiPPlaybackState()
            resetOutputMediaFloor(to: clock.mediaTime)
            clearPacketBuffers()
            clearPendingVideoFrames()
            clearPendingPCM()
            seekFirstPacketLogged = false
            await videoDecoder.flush()
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            await audioDecoder.flush()
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            videoRender.flush()
            videoPrerollClassifier?.reset()
            seekPhaseStopwatch?.mark(.flush)
            logSeekTrace(
                phase: "flush",
                target: clock.mediaTime,
                token: token,
                result: true,
                decoderFlush: true
            )
            resetDisplayTimeline(to: clock.mediaTime)
            beginPrerollStats(context: .seek, generation: gen)
            let primingOutcome = try await primeSeekTargetSide(
                generation: gen,
                token: token
            )
            seekPhaseStopwatch?.mark(.gate)
            logPrerollSuppression(context: "seek")
            finishPrerollStats(generation: gen, token: token)
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            let targetVideoReady: Bool
            let targetAudioReady: Bool
            switch primingOutcome {
            case .superseded:
                return notReady()
            case .ready(let gate):
                targetVideoReady = gate.videoLaunchReady
                targetAudioReady = gate.audioLaunchReady
                logSeekTrace(
                    phase: "preroll",
                    target: clock.mediaTime,
                    token: token,
                    result: true,
                    videoReady: targetVideoReady,
                    audioReady: targetAudioReady
                )
            case .failed(let failure, let gate):
                logSeekTrace(
                    phase: "preroll",
                    target: clock.mediaTime,
                    token: token,
                    result: false,
                    videoReady: gate.videoLaunchReady,
                    audioReady: gate.audioLaunchReady
                )
                diagnostics.diagnostic(
                    "[PathA] ⚠️ SEEK PRIMING FAILED (\(failure.rawValue)) — target=" +
                    "\(String(format: "%.1f", time))s floor=" +
                    "\(String(format: "%.1f", outputMediaFloor))s: demux positioning " +
                    "succeeded, target-side content did not; audioReady=" +
                    "\(gate.audioLaunchReady) " +
                    "videoReady=\(gate.videoLaunchReady) dropV=\(droppedPrerollVideoFrameCount) " +
                    "dropA=\(droppedPrerollAudioFrameCount) " +
                    "trimA=\(trimmedPrerollAudioSampleFrameCount) " +
                    "aPkts=\(audioPackets.count) aQ=\(String(format: "%.2f", audioPacketQueue.contentSeconds)) " +
                    "aRes=\(residualAudioPackets.count) pcm=\(String(format: "%.2f", pendingAudioContentSeconds)) " +
                    "vPkts=\(videoPackets.count) vQ=\(String(format: "%.2f", videoPacketQueue.contentSeconds)) " +
                    "vRes=\(residualVideoPackets.count) eof=\(demuxReachedEOF) " +
                    gate.diagnosticSummary
                )
                logSeekTrace(
                    phase: "prepare",
                    target: clock.mediaTime,
                    token: token,
                    result: false,
                    videoReady: gate.videoLaunchReady,
                    audioReady: gate.audioLaunchReady
                )
                failSeekPriming(
                    token,
                    generation: gen,
                    failure: failure,
                    gate: gate
                )
                return notReady()
            }

            let audioPreparation: MediaAudioSeekPreparation
            if usesSyntheticSilenceClock {
                audioTimelineBuffer.configureSyntheticSilence(
                    enabled: true,
                    startPTS: clock.mediaTime,
                    duration: clock.duration
                )
            }
            if drivesAudioClockPipeline {
                audioPreparation = audioRender.prepareSeekTransition(
                    token,
                    source: self
                )
            } else {
                audioPreparation = MediaAudioSeekPreparation(
                    token: token,
                    stagedContentSeconds: 0,
                    isReady: true
                )
            }
            seekPhaseStopwatch?.mark(.stage)

            guard audioPreparation.token == token, audioPreparation.isReady else {
                diagnostics.diagnostic(
                    "[PathA] seek renderer staging not ready — target=" +
                    String(format: "%.1f", clock.mediaTime) +
                    " staged=" +
                    String(format: "%.3f", audioPreparation.stagedContentSeconds) + "s"
                )
                logSeekTrace(
                    phase: "prepare",
                    target: clock.mediaTime,
                    token: token,
                    result: false,
                    videoReady: targetVideoReady,
                    audioReady: false
                )
                failSeekRendererStep(
                    token,
                    generation: gen,
                    label: "seek-audio-staging"
                )
                return notReady()
            }

            let preparation = MediaEngineSeekPreparation(
                token: token,
                target: clock.mediaTime,
                stagedContentSeconds: audioPreparation.stagedContentSeconds,
                isReady: true
            )
            seekTransaction.markPrepared(preparation)
            logSeekTrace(
                phase: "prepare",
                target: preparation.target,
                token: preparation.token,
                result: true,
                videoReady: targetVideoReady,
                audioReady: targetAudioReady
            )
            return preparation
        } catch {
            if activePrerollStatsGeneration == gen {
                activePrerollStats = nil
                activePrerollStatsGeneration = nil
                prerollAnomalyBaseline = nil
            }
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            logSeekTrace(
                phase: "demux",
                target: time,
                token: token,
                result: false,
                demuxResult: false
            )
            let engineError = transportEngineError(error, stage: .mediaSeek)
            failSeekPreparation(token, error: engineError)
            return notReady()
        }
    }

    func commitPreparedSeek(
        _ preparation: MediaEngineSeekPreparation,
        isAuthorized: (@MainActor @Sendable () -> Bool)? = nil
    ) async -> Bool {
        var phase = (result: false, presented: false)
        defer { emitSeekPhase(token: preparation.token, result: phase.result, presented: phase.presented) }
        guard preparation.isReady,
              activeSeekToken == preparation.token,
              preparedSeek == preparation,
              isAuthorized?() ?? true
        else {
            logSeekTrace(
                phase: "commit",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        let gen = generation
        logSeekTrace(
            phase: "commit",
            target: preparation.target,
            token: preparation.token,
            result: nil,
            videoReady: !pendingVideoFrames.isEmpty,
            audioReady: !hasAudioTrack || pendingAudioContentSeconds > 0.000_5
        )
        let committed = await commitPreparedAudioSeek(preparation, generation: gen, isAuthorized: isAuthorized)
        markSeekPhaseCommitAck(preparation.token)
        logSeekTrace(
            phase: "commit",
            target: preparation.target,
            token: preparation.token,
            result: committed,
            videoReady: !pendingVideoFrames.isEmpty,
            audioReady: !hasAudioTrack || pendingAudioContentSeconds > 0.000_5
        )
        guard isCurrentGeneration(gen),
              activeSeekToken == preparation.token,
              committed
        else {
            if !committed, isAuthorized?() ?? true {
                failSeekRendererStep(
                    preparation.token,
                    generation: gen,
                    label: "seek-renderer-commit"
                )
            } else {
                discardSeekPreparedContent(for: preparation.token)
            }
            logSeekTrace(
                phase: "abort",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        guard isAuthorized?() ?? true else {
            discardSeekPreparedContent(for: preparation.token)
            clearSeekTransaction()
            logSeekTrace(
                phase: "abort",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        clearSeekTransaction()
        isBuffering = false
        audioOutputDisplayHold = nil
        onEvent?(.tick(
            mediaTime: clock.mediaTime,
            duration: clock.duration,
            buffered: bufferedTime
        ))
        if isPlaying {
            resetPipeInstrumentWindow()
            startAudioRenderIfNeeded()
            applyPipelineDemand()
            armPresentFeedIfNeeded()
            phase.presented = presentDueVideoFramesReportingPresentation()
            startSupplyLoop()
            scheduleVideoDecodeIfNeeded()
            scheduleAudioDecodeIfNeeded()
            if !hasAudioTrack, !drivesAudioClockPipeline {
                startVideoTailDrainIfNeeded()
            }
        } else {
            applyDisplayPlayback(rate: 0)
            startPausedRunwayRefreshIfNeeded()
        }
        phase.result = true
        return true
    }

    func commitPreparedAudioSeek(
        _ preparation: MediaEngineSeekPreparation, generation gen: Int,
        isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool {
        await audioRender.commitSeekTransition(
            preparation.token,
            isAuthorized: { [weak self] in
                guard let self else { return false }
                return self.isCurrentGeneration(gen) && self.activeSeekToken == preparation.token
                    && self.preparedSeek == preparation && (isAuthorized?() ?? true)
            },
            resumesPlayback: isPlaying,
            resumeAdmission: { [weak self] in
                guard let self, self.isCurrentGeneration(gen), self.activeSeekToken == preparation.token,
                      self.preparedSeek == preparation, isAuthorized?() ?? true else { return nil }
                return self.admitAudioMaintenanceResume()
            },
            beforeGateRelease: { [weak self] in
                self?.seekTransaction.finishCommitGate()
            }
        )
    }

    private func abortActiveSeekTransition(
        _ token: MediaAudioSeekToken,
        target: TimeInterval,
        beforeTrace: () -> Void = {}
    ) -> Bool {
        guard activeSeekToken == token else { return false }
        audioRender.abortSeekTransition(token)
        discardSeekPreparedContent(for: token)
        clearSeekTransaction()
        beforeTrace()
        logSeekTrace(
            phase: "abort",
            target: target,
            token: token,
            result: false
        )
        return true
    }

    func abortPreparedSeek(_ preparation: MediaEngineSeekPreparation) {
        _ = abortActiveSeekTransition(preparation.token, target: preparation.target)
    }

    func seek(to time: TimeInterval) async -> Bool {
        let preparation = await prepareSeek(to: time)
        guard preparation.isReady else { return false }
        return await commitPreparedSeek(preparation, isAuthorized: nil)
    }

    // MARK: - Unified Launch & Seek Priming

    enum SeekPrimingOutcome {
        case ready(SeekPrimingGate)
        case superseded
        case failed(SeekPrimingFailure, SeekPrimingGate)
    }

    func primeOpenLaunchReserve(
        generation gen: Int
    ) async throws -> SeekPrimingOutcome {
        try await primeLaunchReserve(generation: gen, context: .open)
    }

    private func primeSeekTargetSide(
        generation gen: Int,
        token: MediaAudioSeekToken
    ) async throws -> SeekPrimingOutcome {
        try await primeLaunchReserve(generation: gen, context: .seek(token))
    }

    private func primeLaunchReserve(
        generation gen: Int,
        context: PrerollContext
    ) async throws -> SeekPrimingOutcome {
        let seekToken: MediaAudioSeekToken? = if case .seek(let token) = context { token } else { nil }
        let isSeek = seekToken != nil
        let phase: MediaQueueFillPhase = isSeek ? .seek : .open
        let requiredAudioSeconds = isSeek
            ? requiredAudioSeekContentSeconds
            : requiredAudioLaunchContentSeconds
        let audioPumpBudget = isSeek
            ? audioSeekPumpContentBudget
            : audioLaunchPumpContentBudget

        var gate = SeekPrimingGate(
            requirements: SeekPrimingRequirements(
                target: outputMediaFloor,
                hasAudioTrack: hasAudioTrack,
                requiresVideo: isSeek ? !isVideoLaneWarmSuspended : true,
                requiredPCMContentSeconds: requiredAudioSeconds
            )
        )
        func isSuperseded() -> Bool { !prerollContextIsCurrent(context, generation: gen) }

        while true {
            if Task.isCancelled || isSuperseded() { return .superseded }

            var lap = SeekPhaseLap(isEnabled: isSeek && seekPhaseStopwatch?.isEnabled == true)
            let demuxGateBusy = isFillingQueues
            var gateWaitSeconds: TimeInterval = 0
            if demuxGateBusy {
                let waitStart = ContinuousClock.now
                try? await Task.sleep(nanoseconds: supplyStallBackoffNanos)
                let waited = waitStart.duration(to: ContinuousClock.now)
                gateWaitSeconds = Double(waited.components.seconds)
                    + Double(waited.components.attoseconds) / 1e18
                if Task.isCancelled || isSuperseded() { return .superseded }
            } else {
                try await fillQueuesToHighWater(
                    generation: gen,
                    initiator: isSeek ? .seekPrime : .openPrime,
                    phase: phase,
                    videoContentCap: primeVideoContentBudget,
                    audioContentCap: audioPumpBudget
                )
                if isSuperseded() { return .superseded }
            }

            if !isSeek, let decodeTask {
                await decodeTask.value
            }
            try await drainPrerollBatches(generation: gen, context: context)
            if isSuperseded() { return .superseded }
            if isSeek || pendingVideoFrames.isEmpty {
                await drainVideoDecodeBurst(generation: gen)
            }
            if isSuperseded() { return .superseded }
            if isSeek {
                seekPhaseStopwatch?.addPreroll(lap.split())
            }
            if outputMediaFloor > outputMediaFloorEpsilon
                    || droppedPrerollVideoFrameCount > 0 {
                try await primeVideoRunwayAfterPreroll(generation: gen, phase: phase)
                if isSuperseded() { return .superseded }
            }
            if isSeek {
                seekPhaseStopwatch?.addRunway(lap.split())
            }
            try await fillPCMRing(
                generation: gen,
                phase: phase,
                contentCap: requiredAudioSeconds,
                packetContentCap: isSeek ? audioSeekPumpContentBudget : nil
            )
            if isSeek {
                seekPhaseStopwatch?.addAudio(lap.split())
            }
            if isSuperseded() { return .superseded }
            if let seekToken, gate.passCount == 0 {
                logSeekTrace(
                    phase: "refill",
                    target: clock.mediaTime,
                    token: seekToken,
                    result: true
                )
            }

            let pass = SeekPrimingPass(
                videoDecodeFrontier: videoDecodeFrontierPTS,
                audioDecodeFrontier: audioDecodeFrontierPTS,
                bytesRead: bytesRead,
                postPrerollVideoFrames: pendingVideoFrames.count,
                postPrerollPCMContentSeconds: pendingAudioContentSeconds,
                videoDecoderOpened: videoDecoderOpened,
                audioDecoderOpened: audioDecoderOpened,
                demuxReachedEOF: demuxReachedEOF,
                didAttemptDemuxPull: !demuxGateBusy,
                demuxGateWaitSeconds: gateWaitSeconds
            )
            switch gate.evaluate(pass, isSuperseded: isSuperseded()) {
            case .launchReady:
                if isSeek, gate.passCount > 1 {
                    diagnostics.log(
                        "[PathA] seek priming completed after \(gate.passCount) " +
                        "passes: \(gate.diagnosticSummary)"
                    )
                }
                return .ready(gate)
            case .continuePriming:
                continue
            case .superseded:
                return .superseded
            case .failed(let failure):
                return .failed(failure, gate)
            }
        }
    }

    private func failSeekPriming(
        _ token: MediaAudioSeekToken,
        generation gen: Int,
        failure: SeekPrimingFailure,
        gate: SeekPrimingGate
    ) {
        let target = clock.mediaTime
        guard abortActiveSeekTransition(token, target: target) else { return }
        publishRuntimeFault(
            MediaRuntimeFault(
                subsystem: failure.faultSubsystem(
                    shortTrackIsAudio: !gate.audioLaunchReady
                ),
                stage: .seekPriming,
                classification: failure.faultClassification,
                recoverability: failure.faultRecoverability,
                ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                diagnostics: MediaRuntimeFaultDiagnostics(
                    label: failure.rawValue,
                    details: "target=\(String(format: "%.2f", target)) " +
                        gate.diagnosticSummary
                )
            ),
            generation: gen
        )
    }

    func launchReserveFault(
        videoReady: Bool,
        audioReady: Bool,
        primingFailure: SeekPrimingFailure?
    ) -> MediaRuntimeFault {
        let shortTrackIsAudio = videoReady
        let hadInput = shortTrackIsAudio
            ? audioDecodePacketsSubmitted > 0 || audioPacketQueue.contentSeconds > 0
            : totalVideoPacketsSubmitted > 0 || videoPacketQueue.contentSeconds > 0
        let subsystem = primingFailure?.faultSubsystem(shortTrackIsAudio: shortTrackIsAudio)
            ?? (hadInput ? (shortTrackIsAudio ? .audioDecoder : .videoDecoder) : .demux)
        let classification = primingFailure?.faultClassification
            ?? (hadInput ? .silentNoOutput : .input)
        return MediaRuntimeFault(
            subsystem: subsystem,
            stage: .open,
            classification: classification,
            recoverability: .automaticSourceAwareReopen,
            ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
            diagnostics: MediaRuntimeFaultDiagnostics(
                label: "launch-reserve",
                details: "\(primingFailure?.rawValue ?? "predicate") " +
                    "video=\(videoReady ? 1 : 0) audio=\(audioReady ? 1 : 0) " +
                    "pcm=\(String(format: "%.3f", pendingAudioContentSeconds)) " +
                    "pendingV=\(pendingVideoFrames.count)"
            )
        )
    }

    private func failSeekRendererStep(
        _ token: MediaAudioSeekToken,
        generation gen: Int,
        label: String
    ) {
        let target = clock.mediaTime
        guard abortActiveSeekTransition(token, target: target) else { return }
        publishRuntimeFault(
            MediaRuntimeFault(
                subsystem: .audioRenderer,
                stage: .seekPriming,
                classification: .silentNoOutput,
                recoverability: .automaticSourceAwareReopen,
                ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                diagnostics: MediaRuntimeFaultDiagnostics(
                    label: label,
                    details: "target=\(String(format: "%.2f", target))"
                )
            ),
            generation: gen
        )
    }

    private func failSeekPreparation(
        _ token: MediaAudioSeekToken,
        error: MediaEngineError
    ) {
        let target = clock.mediaTime
        guard abortActiveSeekTransition(token, target: target, beforeTrace: {
            isPlaying = false
            isReady = false
            isBuffering = false
            audioRender.stop()
            applyDisplayPlayback(rate: 0)
        }) else { return }
        onEvent?(.failed(error))
    }

    func discardSeekPreparedContent(for token: MediaAudioSeekToken? = nil) {
        if let token, activeSeekToken != token { return }
        guard activeSeekToken != nil else { return }
        clearPacketBuffers()
        clearPendingVideoFrames()
        clearPendingPCM()
    }

    func logPrerollSuppression(context: String) {
        guard droppedPrerollVideoFrameCount > 0
                || droppedPrerollAudioFrameCount > 0
                || trimmedPrerollAudioSampleFrameCount > 0
        else {
            return
        }
        diagnostics.log(
            "[PathA] \(context) preroll suppressed " +
            "target=\(String(format: "%.3f", outputMediaFloor)) " +
            "dropV=\(droppedPrerollVideoFrameCount) " +
            "dropA=\(droppedPrerollAudioFrameCount) " +
            "trimASamples=\(trimmedPrerollAudioSampleFrameCount) " +
            "pendingV=\(pendingVideoFrameCount) " +
            "pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s"
        )
    }

    // MARK: - Seek & Resume-Open Fast Preroll

    static let seekPrerollBatchLimit = 32

    enum PrerollContext {
        case seek(MediaAudioSeekToken)
        case open

        var isSeek: Bool {
            if case .seek = self { return true }
            return false
        }
    }

    static func unknownVideoDecodeFault() -> MediaRuntimeFault {
        MediaRuntimeFault(
            subsystem: .videoDecoder,
            stage: .decodeSubmission,
            classification: .unknown,
            recoverability: VideoToolboxDecoder.recoverability(for: .unknown),
            diagnostics: MediaRuntimeFaultDiagnostics(
                status: nil,
                label: "decode"
            )
        )
    }

    func prerollContextIsCurrent(_ context: PrerollContext, generation gen: Int) -> Bool {
        guard isCurrentGeneration(gen) else { return false }
        if case .seek(let token) = context {
            return activeSeekToken == token
        }
        return true
    }

    func installVideoPrerollClassifier(
        codec: String?,
        config: Data,
        decoder identity: ObjectIdentifier
    ) {
        guard videoDecoderOpened, ObjectIdentifier(videoDecoder) == identity else { return }
        videoPrerollCodec = codec
        if activePrerollStats != nil, activePrerollStatsGeneration == generation {
            activePrerollStats?.codec = codec ?? "unknown"
            prerollAnomalyBaseline = (identity, videoDecoder.decodeAnomalyCounters)
        }
        guard seekFastPrerollEnabled else {
            videoPrerollClassifier = nil
            videoPrerollClassifierDecoder = nil
            return
        }
        videoPrerollClassifier = videoPrerollClassifierFactory(codec, config)
        videoPrerollClassifierDecoder = identity
    }

    static func isPrerollBatchCandidate(
        _ packet: MediaPacket,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        packet.pixelBuffer == nil
            && OutputFloorPolicy.isPreTarget(pts: packet.pts, floor: floor, epsilon: epsilon)
    }

    func isPrerollBatchCandidate(_ packet: MediaPacket) -> Bool {
        Self.isPrerollBatchCandidate(
            packet,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        )
    }

    static func relayDecodeYieldsToPrerollBatch(
        batchingActive: Bool,
        head: MediaPacket?,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard batchingActive, let head else { return false }
        return isPrerollBatchCandidate(head, floor: floor, epsilon: epsilon)
    }

    func classifyVideoPrerollSample(_ packet: MediaPacket) -> VideoPrerollSampleAction {
        guard !packet.data.isEmpty,
              packet.pixelBuffer == nil,
              videoPrerollClassifier != nil,
              videoPrerollClassifierDecoder == ObjectIdentifier(videoDecoder) else {
            return .submit
        }
        return videoPrerollClassifier?.classify(packet.data, isKeyframe: packet.isKeyframe) ?? .submit
    }

    func observeVideoPrerollSample(_ packet: MediaPacket) {
        guard activePrerollStats != nil, activePrerollStatsGeneration == generation else { return }
        _ = classifyVideoPrerollSample(packet)
    }

    func beginPrerollStats(context: SeekPrerollStats.Context, generation gen: Int) {
        activePrerollStats = SeekPrerollStats(
            context: context,
            mode: seekFastPrerollEnabled ? .fast : .legacy,
            codec: videoPrerollCodec ?? "unknown",
            target: outputMediaFloor
        )
        activePrerollStatsGeneration = gen
        prerollAnomalyBaseline = (ObjectIdentifier(videoDecoder), videoDecoder.decodeAnomalyCounters)
    }

    func notePrerollFill(generation gen: Int, startedAt: ContinuousClock.Instant?) {
        guard activePrerollStats != nil, activePrerollStatsGeneration == gen else { return }
        activePrerollStats?.fills += 1
        if let startedAt {
            activePrerollStats?.fillSeconds += SeekPhaseStopwatch.seconds(startedAt.duration(to: .now))
        }
    }

    func finishPrerollStats(generation gen: Int, token: MediaAudioSeekToken?) {
        guard var stats = activePrerollStats, activePrerollStatsGeneration == gen else { return }
        activePrerollStats = nil
        activePrerollStatsGeneration = nil
        stats.mode = seekFastPrerollEnabled && !holdsPassThroughVideo ? .fast : .legacy
        if stats.codec == "unknown", let codec = videoPrerollCodec {
            stats.codec = codec
        }
        stats.discarded = droppedPrerollVideoFrameCount
        stats.firstTargetSidePTS = pendingVideoFrames.first?.pts
        let identity = ObjectIdentifier(videoDecoder)
        let baseline = prerollAnomalyBaseline.flatMap { $0.decoder == identity ? $0.counters : nil }
        stats.anomalies = videoDecoder.decodeAnomalyCounters.delta(since: baseline)
        prerollAnomalyBaseline = nil
        lastPrerollStats = stats
        diagnostics.log(stats.logLine(token: token?.generation))
    }

    func markSeekPhaseCommitAck(_ token: MediaAudioSeekToken) {
        guard seekPhaseStopwatch?.token == token.generation else { return }
        seekPhaseStopwatch?.mark(.commitAck)
    }

    func presentDueVideoFramesReportingPresentation() -> Bool {
        let before = presentedVideoFrameCount
        presentDueVideoFrames()
        return presentedVideoFrameCount > before
    }

    func emitSeekPhase(token: MediaAudioSeekToken, result: Bool, presented: Bool) {
        guard let stopwatch = seekPhaseStopwatch, stopwatch.token == token.generation else { return }
        seekPhaseStopwatch = nil
        guard stopwatch.isEnabled else { return }
        diagnostics.log(stopwatch.logLine(result: result, presented: presented))
    }

    func drainPrerollBatches(generation gen: Int, context: PrerollContext) async throws {
        guard seekFastPrerollEnabled, !holdsPassThroughVideo, videoDecoderOpened,
              outputMediaFloor > outputMediaFloorEpsilon,
              prerollContextIsCurrent(context, generation: gen) else {
            return
        }
        prerollBatchingActive = true
        defer { prerollBatchingActive = false }
        while !Task.isCancelled, prerollContextIsCurrent(context, generation: gen), videoDecoderOpened {
            if videoPackets.isEmpty {
                drainResidualPackets()
            }
            if videoPackets.isEmpty {
                guard prerollRunUpIsOutstanding, !(await demux.isEOF),
                      prerollContextIsCurrent(context, generation: gen) else {
                    return
                }
                let fillStart: ContinuousClock.Instant? = diagnostics.isCapturing ? .now : nil
                try await fillQueuesToHighWater(
                    generation: gen,
                    initiator: .preroll,
                    phase: context.isSeek ? .seek : .open,
                    videoContentCap: primeVideoContentBudget,
                    audioContentCap: context.isSeek
                        ? audioSeekPumpContentBudget
                        : audioLaunchPumpContentBudget
                )
                guard prerollContextIsCurrent(context, generation: gen) else { return }
                notePrerollFill(generation: gen, startedAt: fillStart)
                drainResidualPackets()
                if videoPackets.isEmpty { return }
                continue
            }
            guard let head = videoPackets.first, isPrerollBatchCandidate(head) else { return }
            guard await joinScheduledVideoDecodeAndAcquireDirectLane(
                generation: gen,
                warmPreparationAttempt: nil
            ) else { return }
            guard await runPrerollBatch(generation: gen, context: context) else { return }
        }
    }

    var prerollRunUpIsOutstanding: Bool {
        guard let frontier = videoDecodeFrontierPTS else { return true }
        return OutputFloorPolicy.isPreTarget(
            pts: frontier,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        )
    }

    func runPrerollBatch(generation gen: Int, context: PrerollContext) async -> Bool {
        videoDecodeLaneOwners += 1
        defer { videoDecodeLaneOwners -= 1 }
        defer { directVideoDecodeLane.release() }

        let submissions = takePrerollBatch(generation: gen)
        guard !submissions.isEmpty else { return true }
        let decoder = videoDecoder
        let decoderIdentity = ObjectIdentifier(decoder)
        let floor = outputMediaFloor
        let epsilon = outputMediaFloorEpsilon
        let keepOutput: @Sendable (TimeInterval, TimeInterval) -> Bool = { pts, duration in
            OutputFloorPolicy.isUsable(pts: pts, duration: duration, floor: floor, epsilon: epsilon)
        }
        let decodeStart: ContinuousClock.Instant? = diagnostics.isCapturing ? .now : nil
        let result: VideoPrerollBatchResult
        do {
            result = try await decoder.decodePrerollBatch(submissions, keepOutput: keepOutput)
        } catch {
            guard prerollContextIsCurrent(context, generation: gen),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return false
            }
            publishVideoDecodeFault(error, generation: gen)
            return false
        }
        guard prerollContextIsCurrent(context, generation: gen),
              ObjectIdentifier(videoDecoder) == decoderIdentity else {
            return false
        }
        notePrerollBatchStats(result, items: submissions.count, generation: gen, decodeStart: decodeStart)
        applyPrerollBatchOutput(result)
        return true
    }

    func takePrerollBatch(generation gen: Int) -> [VideoPrerollSubmission] {
        var submissions: [VideoPrerollSubmission] = []
        while submissions.count < Self.seekPrerollBatchLimit,
              let head = videoPackets.first,
              isPrerollBatchCandidate(head) {
            let packet = videoPackets.removeFirst()
            noteVideoPacketDequeued(packet)
            if activePrerollStatsGeneration == gen {
                activePrerollStats?.noteAnchor(packet.pts)
            }
            let action = classifyVideoPrerollSample(packet)
            if action != .skip {
                noteVideoPacketSubmitted()
                tracing.mark(.demandFirstVideoSubmit, token: activeStartupTraceToken)
            }
            submissions.append(VideoPrerollSubmission(packet: packet, action: action))
        }
        return submissions
    }

    func publishVideoDecodeFault(_ error: Error, generation gen: Int) {
        let fault: MediaRuntimeFault
        if let typed = error as? MediaRuntimeFault {
            fault = typed
        } else {
            fault = Self.unknownVideoDecodeFault()
            diagnostics.log("[PathA] video decode failed; publishing terminal runtime fault")
        }
        if isSeekInFlight {
            logSeekTrace(
                phase: "fault",
                target: clock.mediaTime,
                token: activeSeekToken,
                result: false
            )
        }
        publishRuntimeFault(fault, generation: gen)
    }

    func notePrerollBatchStats(
        _ result: VideoPrerollBatchResult,
        items: Int,
        generation gen: Int,
        decodeStart: ContinuousClock.Instant?
    ) {
        guard activePrerollStatsGeneration == gen, var stats = activePrerollStats else { return }
        stats.batches += 1
        stats.items += items
        stats.submitted += result.submitted
        stats.skipped += result.skipped
        stats.truncated += result.truncated
        stats.truncatedBytes += result.truncatedBytes
        stats.kept += result.keptFrames.count
        if let decodeStart {
            stats.decodeSeconds += SeekPhaseStopwatch.seconds(decodeStart.duration(to: .now))
        }
        activePrerollStats = stats
    }

    func applyPrerollBatchOutput(_ result: VideoPrerollBatchResult) {
        pipeWindowVideoCallbacks += result.submitted
        if !result.outputPTS.isEmpty {
            noteFlowStage(&flowDecOutV, "decOutV")
            tracing.mark(.demandFirstVideoOutput, token: activeStartupTraceToken)
        }
        decodedVideoFrameCount += result.outputPTS.count
        pipeWindowDecodeFrames += result.outputPTS.count
        for pts in result.outputPTS {
            noteVideoLivenessOutput(pts: pts)
            noteVideoDecodeFrontier(pts)
        }
        droppedPrerollVideoFrameCount += result.discardedFrames
        for frame in result.keptFrames {
            noteVideoFrameSize(from: frame.pixelBuffer)
            if shouldDropVideoBeforeOutputFloor(frame) {
                droppedPrerollVideoFrameCount += 1
                continue
            }
            enqueuePendingVideoFrame(frame)
        }
        maybeReportPipeInstrument()
    }

    func primeVideoRunwayAfterPreroll(
        generation gen: Int,
        phase: MediaQueueFillPhase
    ) async throws {
        while isCurrentGeneration(gen), videoDecoderOpened, videoFrameQueueNeedsFill {
            if Task.isCancelled { return }
            if videoPackets.isEmpty {
                drainResidualPackets()
                if videoPackets.isEmpty, !(await demux.isEOF) {
                    let fillStart: ContinuousClock.Instant? = diagnostics.isCapturing ? .now : nil
                    try await fillQueuesToHighWater(
                        generation: gen,
                        initiator: .postPreroll,
                        phase: phase,
                        videoContentCap: primeVideoContentBudget,
                        audioContentCap: isSeekInFlight
                            ? audioSeekPumpContentBudget
                            : audioLaunchPumpContentBudget
                    )
                    guard isCurrentGeneration(gen) else { return }
                    notePrerollFill(generation: gen, startedAt: fillStart)
                    drainResidualPackets()
                }
            }
            guard !videoPackets.isEmpty else { break }
            let packetsBefore = videoPackets.count
            let decodedBefore = decodedVideoFrameCount
            await drainVideoDecodeBurst(generation: gen)
            guard isCurrentGeneration(gen) else { return }
            if videoPackets.count >= packetsBefore,
               decodedVideoFrameCount == decodedBefore {
                break
            }
        }
    }
}
