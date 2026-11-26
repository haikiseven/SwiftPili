import Foundation

extension MediaEngineSession {
    func bindWarmDecoderTiming(run: WarmVideoPreparationRun) {
        guard warmPreparationTransaction.currentRun == run,
              activeWarmDiagnostics?.runID == run.id,
              activeVideoSuspendToken == run.token,
              runtimeGeneration == run.sessionGeneration,
              generation == run.engineGeneration,
              activeOwnerGeneration == run.ownerGeneration else { return }
        let identity = ObjectIdentifier(videoDecoder)
        if activeWarmDiagnostics?.decoderTimingOwner?.observation.decoderIdentity == identity {
            return
        }
        let segmentID = (activeWarmDiagnostics?.decoderTimingOwner?.observation.segmentID ?? 0) + 1
        freezeWarmDecoderTiming(runID: run.id)
        let reporter = videoDecoder as? any MediaVideoDecodeTimingReporting
        reporter?.setDecodeTimingEnabled(true)
        let selectionAttemptID = activeWarmDiagnostics?.attemptID
        activeWarmDiagnostics?.decoderTimingOwner = WarmVideoDecoderTimingOwner(
            runID: run.id,
            observation: WarmVideoDecoderTimingObservation(
                segmentID: segmentID,
                selectionAttemptID: selectionAttemptID,
                decoderIdentity: identity
            ),
            reporter: reporter
        )
    }

    func freezeWarmDecoderTiming(runID: UInt64, decoderIdentity: ObjectIdentifier? = nil) {
        guard var state = activeWarmDiagnostics, state.runID == runID,
              var owner = state.decoderTimingOwner, owner.runID == runID,
              decoderIdentity == nil || decoderIdentity == owner.observation.decoderIdentity,
              let reporter = owner.reporter else { return }
        owner.observation.snapshot = reporter.decodeTimingSnapshot()
        reporter.setDecodeTimingEnabled(false)
        owner.reporter = nil
        state.decoderTimingOwner = owner
        activeWarmDiagnostics = state
    }

    func freezeRetiringWarmDecoderTiming(_ identity: ObjectIdentifier) {
        guard let runID = activeWarmDiagnostics?.runID else { return }
        freezeWarmDecoderTiming(runID: runID, decoderIdentity: identity)
    }

    func warmDiagnosticPhase(_ phase: String) {
        guard var state = activeWarmDiagnostics else { return }
        if state.phases.count < 32 { state.phases.append(phase) }
        activeWarmDiagnostics = state
    }

    func warmPreparationAttemptIsActive(runID: UInt64) -> Bool {
        activeWarmDiagnostics?.runID == runID
            && warmPreparationTransaction.currentRun?.id == runID
    }

    func warmDiagnosticAttemptIsCurrent(_ attempt: WarmVideoPreparationAttempt?) -> Bool {
        guard let attempt else { return false }
        return isCurrentWarmVideoPreparationAttempt(attempt)
            && activeWarmDiagnostics?.runID == attempt.runID
            && activeWarmDiagnostics?.attemptID == attempt.id
    }

    static func warmDiagnosticMilliseconds(_ duration: Duration) -> Int {
        max(0, Int(duration / .milliseconds(1)))
    }

    func warmDiagnosticElapsedMs(
        _ start: ContinuousClock.Instant,
        _ end: ContinuousClock.Instant = ContinuousClock.now
    ) -> Int {
        Self.warmDiagnosticMilliseconds(start.duration(to: end))
    }

    func finishWarmDiagnostics(
        run: WarmVideoPreparationRun,
        result: DemandVideoLanePreparationResult
    ) {
        guard activeWarmDiagnostics?.runID == run.id else { return }
        freezeWarmDecoderTiming(runID: run.id)
        guard let state = activeWarmDiagnostics else { return }
        let now = ContinuousClock.now
        let outcome = String(describing: result)
        let decoderTiming = state.decoderTimingOwner?.observation
        let diagnostic = WarmVideoPreparationDiagnostics(
            runID: state.runID, target: state.target, phases: state.phases,
            decoderOpenMs: Self.warmDiagnosticMilliseconds(state.decoderOpenTime),
            firstDecodeAwaitMs: state.firstDecodeAwaitMs,
            totalDecodeWallMs: Self.warmDiagnosticMilliseconds(state.totalDecodeTime),
            decodedFrames: state.decodedFrames,
            prerollFramesDropped: state.prerollFramesDropped,
            targetFramesBanked: state.targetFramesBanked,
            decodeBursts: state.decodeBursts,
            demuxWaitMs: Self.warmDiagnosticMilliseconds(state.demuxWaitTime),
            schedulingWaitMs: Self.warmDiagnosticMilliseconds(state.schedulingWaitTime),
            presentationProofCallbackMs: nil, preparedToProofMs: nil,
            firstOutputMs: state.firstOutputMs,
            initialFloorDrops: state.initialFloorDrops,
            movingFloorDrops: state.movingFloorDrops,
            pumps: state.pumps, submittedPackets: state.submittedPackets,
            finalTarget: outputMediaFloor,
            totalPreparationMs: warmDiagnosticElapsedMs(state.startedAt, now),
            attemptID: state.attemptID, outcome: outcome,
            beforeDecoderOpenMs: state.beforeDecoderOpenMs,
            bankedFramesExpired: state.bankedFramesExpired,
            quiesceWaitMs: Self.warmDiagnosticMilliseconds(state.quiesceWaitTime),
            decoderTiming: decoderTiming
        )
        lastWarmVideoPreparationDiagnostics = diagnostic
        warmDiagnosticProofIdentity = result == .prepared ? .init(
            run: run, attemptID: state.attemptID, preparedAt: now,
            floor: outputMediaFloor
        ) : nil
        diagnostics.log(
            "[PathA][continuation] warm diagnostics " +
            "run=\(state.runID) attempt=\(state.attemptID ?? 0) outcome=\(outcome) " +
            "target=\(String(format: "%.3f", state.target)) finalTarget=\(String(format: "%.3f", outputMediaFloor)) " +
            "totalMs=\(diagnostic.totalPreparationMs) phases=\(state.phases.joined(separator: ",")) " +
            "decoderOpenMs=\(diagnostic.decoderOpenMs) firstDecodeAwaitMs=\(state.firstDecodeAwaitMs ?? -1) " +
            "firstOutputMs=\(state.firstOutputMs ?? -1) decodeAwaitMs=\(diagnostic.totalDecodeWallMs) " +
            "submitted=\(state.submittedPackets) decoded=\(state.decodedFrames) " +
            "initialFloorDrops=\(state.initialFloorDrops) movingFloorDrops=\(state.movingFloorDrops) " +
            "prerollDropped=\(state.prerollFramesDropped) banked=\(state.targetFramesBanked) " +
            "bursts=\(state.decodeBursts) pumps=\(state.pumps) demuxAwaitMs=\(diagnostic.demuxWaitMs) " +
            "laneAwaitMs=\(diagnostic.schedulingWaitMs) quiesceAwaitMs=\(diagnostic.quiesceWaitMs) " +
            "beforeDecoderOpenMs=\(state.beforeDecoderOpenMs ?? -1) bankedExpired=\(state.bankedFramesExpired)"
        )
        if let decoderTiming {
            diagnostics.log(
                "[PathA][continuation] warm decoder timings run=\(state.runID) " +
                "scope=selected-decoder-segment segment=\(decoderTiming.segmentID) " +
                "selectionAttempt=\(decoderTiming.selectionAttemptID ?? 0) " +
                "throughAttempt=\(state.attemptID ?? 0) " +
                (decoderTiming.snapshot?.logSummary ?? "timing=unavailable")
            )
        }
        activeWarmDiagnostics = nil
    }

    func noteWarmPresentationProof(renderGeneration: Int, mediaTime: TimeInterval) {
        guard let identity = warmDiagnosticProofIdentity,
              identity.renderGeneration == renderGeneration,
              identity.run.sessionGeneration == runtimeGeneration,
              identity.run.engineGeneration == generation,
              identity.run.ownerGeneration == activeOwnerGeneration,
              !isVideoLaneWarmSuspended,
              mediaTime.isFinite, mediaTime >= identity.floor,
              var diagnostic = lastWarmVideoPreparationDiagnostics,
              diagnostic.runID == identity.run.id,
              diagnostic.attemptID == identity.attemptID else { return }
        let now = ContinuousClock.now
        diagnostic.presentationProofCallbackMs = warmDiagnosticElapsedMs(identity.run.startedAt, now)
        diagnostic.preparedToProofMs = warmDiagnosticElapsedMs(identity.preparedAt, now)
        if diagnostic.phases.count < 32 { diagnostic.phases.append("presentation-proof") }
        lastWarmVideoPreparationDiagnostics = diagnostic
        warmDiagnosticProofIdentity = nil
        diagnostics.log(
            "[PathA][continuation] warm proof run=\(diagnostic.runID) " +
            "attempt=\(identity.attemptID ?? 0) render=\(renderGeneration) " +
            "preparedToProofMs=\(diagnostic.preparedToProofMs ?? -1) " +
            "totalMs=\(diagnostic.presentationProofCallbackMs ?? -1)"
        )
    }
    @discardableResult
    func warmSuspendVideoLane() -> DemandVideoSuspensionResult {
        return suspendVideoLane(
            reason: .audioOnlyBackground,
            resumesPlayback: isPlaying
        )
    }

    @discardableResult
    func suspendVideoLaneAfterPiPStop() -> DemandVideoSuspensionResult {
        suspendVideoLane(
            reason: .pipDidStop,
            resumesPlayback: isPlaying
        )
    }

    @discardableResult
    func suspendVideoLane(
        reason: DemandVideoLaneSuspensionReason,
        resumesPlayback: Bool
    ) -> DemandVideoSuspensionResult {
        guard isReady, !isSeekInFlight else { return .deferred }
        guard hasAudioTrack || usesSyntheticSilenceClock,
              videoContinuityTopology != .unsupported else { return .unsupported }
        if let activeVideoSuspendToken,
           isVideoLaneWarmSuspended,
           activeVideoSuspendToken.sessionGeneration == runtimeGeneration,
           activeVideoSuspendToken.ownerGeneration == activeOwnerGeneration,
           activeVideoSuspendToken.reason == reason,
           activeVideoSuspendToken.resumesPlayback == resumesPlayback {
            return .suspended(activeVideoSuspendToken)
        }

        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        supersedeWarmVideoPreparationRun()

        videoContinuationGeneration &+= 1
        if videoContinuationGeneration == 0 { videoContinuationGeneration = 1 }
        let token = DemandVideoSuspendToken(
            generation: videoContinuationGeneration,
            sessionGeneration: runtimeGeneration,
            audioPosition: clock.mediaTime,
            videoReadGeneration: nextVideoReadGeneration,
            videoReadBytesAtSuspend: videoReadBytes,
            ownerGeneration: activeOwnerGeneration,
            reason: reason,
            resumesPlayback: resumesPlayback
        )
        activeVideoSuspendToken = token
        isVideoLaneWarmSuspended = true
        isVideoLanePreparedForForeground = false
        terminalVideoPreparationFailure = nil
        warmVideoPreparationLedger.retireAttempt()
        let preexistingSuspendedVideoFault = suspendedVideoFault
        suspendedVideoFault = reason == .pipDidStop
            ? preexistingSuspendedVideoFault
            : nil
        isCollectingWarmVideoRunUp = false
        warmVideoCandidateAuthorities = []

        cancelVideoDecode(clearHandle: false)
        let warmSuspendBegan = ContinuousClock.now
        disarmPresentFeed()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            renderer.warmSuspendPresentation(mediaTime: audioPresentationMediaTime)
        } else {
            videoRender.flush()
        }
        let surfaceEnded = ContinuousClock.now

        let previousVideoPackets = videoPackets
        let previousResidualVideoPackets = residualVideoPackets
        let retainedCount = previousVideoPackets.count + previousResidualVideoPackets.count
        clearVideoTrackQueues()
        clearSuspendedVideoGOP()
        suspendedVideoSupplyMemorySuppressed = false
        let suspendEdgeProvenance = DemandVideoCandidateProvenance.suspendEdge(
            readGeneration: token.videoReadGeneration
        )
        for packet in previousVideoPackets {
            retainSuspendedVideoPacket(packet, provenance: suspendEdgeProvenance)
        }
        for packet in previousResidualVideoPackets {
            retainSuspendedVideoPacket(packet, provenance: suspendEdgeProvenance)
        }
        resetVideoLivenessState(resetStartup: false)
        requestSupplyWake()
        if diagnostics.isCapturing {
            let warmSuspendEnded = ContinuousClock.now
            let totalMs = Self.warmDiagnosticMilliseconds(warmSuspendBegan.duration(to: warmSuspendEnded))
            let surfaceMs = Self.warmDiagnosticMilliseconds(warmSuspendBegan.duration(to: surfaceEnded))
            let bufsMs = Self.warmDiagnosticMilliseconds(surfaceEnded.duration(to: warmSuspendEnded))
            diagnostics.log(
                "[PathA][continuation] video warm-suspended token=\(token.generation) " +
                "reason=\(token.reason.rawValue) resumes=\(token.resumesPlayback ? 1 : 0) " +
                "session=\(token.sessionGeneration) audio=\(String(format: "%.3f", token.audioPosition)) " +
                "gop=\(suspendedVideoGOP.count) " +
                "in=\(totalMs)ms " +
                "surface=\(surfaceMs)ms " +
                "bufs=\(bufsMs)ms " +
                "retained=\(retainedCount)"
            )
        }
        schedulePiPVideoResumeIfNeeded()
        return .suspended(token)
    }

    func retainAudioAfterVideoFailure() -> DemandVideoSuspendToken? {
        guard isReady, hasAudioTrack, audioDecoderOpened, !hasEmittedEnded,
              runtimeFaultedGeneration != generation, !hasObservedPiPLease else { return nil }
        if isVideoLaneWarmSuspended, let token = activeVideoSuspendToken,
           token.sessionGeneration == runtimeGeneration,
           token.ownerGeneration == activeOwnerGeneration {
            return token
        }
        guard case .suspended(let token) = warmSuspendVideoLane() else { return nil }
        return token
    }

    func prepareVideoLaneForForeground(
        _ token: DemandVideoSuspendToken
    ) async -> DemandVideoLanePreparationResult {
        guard !Task.isCancelled else { return .cancelled }
        if activeVideoSuspendToken == token,
           token.ownerGeneration == activeOwnerGeneration,
           let terminalVideoPreparationFailure {
            return .failed(terminalVideoPreparationFailure)
        }
        if let orphan = warmPreparationTransaction.orphan {
            return .failed(orphan.failure)
        }
        guard activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration,
              isVideoLaneWarmSuspended,
              !isVideoLanePreparedForForeground else {
            let alreadyPrepared = activeVideoSuspendToken == token
                && token.ownerGeneration == activeOwnerGeneration
                && isVideoLanePreparedForForeground
            if alreadyPrepared {
                diagnostics.log(
                    "[PathA][continuation] activation validation covers=" +
                    (preparedVideoLaneCoversCurrentAudio() ? "1" : "0") + " " +
                    "target=\(String(format: "%.3f", audioPresentationMediaTime)) " +
                    "pending=\(pendingVideoFrames.count)"
                )
            }
            return alreadyPrepared ? .prepared : .cancelled
        }

        let run = warmPreparationTransaction.begin(token: token, host: self)
        return await warmPreparationTransaction.result(for: run, host: self)
    }

    func makeWarmVideoPreparationRun(
        id: UInt64, token: DemandVideoSuspendToken
    ) -> WarmVideoPreparationRunLedger.Run {
        WarmVideoPreparationRunLedger.Run(
            id: id,
            token: token,
            sessionGeneration: runtimeGeneration,
            engineGeneration: generation,
            ownerGeneration: activeOwnerGeneration,
            startedAt: ContinuousClock.now
        )
    }

    func captureWarmPreparationInterrupt() -> WarmPreparationTransaction.InterruptOperation {
        let demux = self.demux
        return { @MainActor [demux] in await demux.interruptActiveIO() }
    }

    func applyWarmPreparationNotice(_ notice: WarmPreparationTransaction.Notice) {
        switch notice {
        case .runStarted(let run):
            warmVideoPreparationLedger.clearProgress()
            warmDiagnosticProofIdentity = nil
            activeWarmDiagnostics = WarmVideoPreparationDiagnosticsState(
                runID: run.id,
                target: audioPresentationMediaTime,
                startedAt: run.startedAt
            )
            warmDiagnosticPhase("run-start")

            bindWarmDecoderTiming(run: run)
        case .primaryReturned(let run, let result):
            recordWarmPreparationPrimaryReturn(run, result: result)
        case .timeoutObserved(let run):
            logWarmVideoPreparationTimeoutSnapshot(run)
            warmDiagnosticPhase("timeout")
        case .timeoutWillSettle(let run):
            finishWarmDiagnostics(run: run, result: .failed(.warmPreparationTimedOut))
        case .timeoutResultStored:
            terminalVideoPreparationFailure = .warmPreparationTimedOut
            isVideoLanePreparedForForeground = false
            activeWarmVideoImageHold = nil
            warmVideoPreparationLedger.retireAttempt()
            isDecodingWarmVideoCandidate = false
            isCollectingWarmVideoRunUp = false
        case .currentRunReleased:
            warmVideoPreparationLedger.clearProgress()
            isPreparingWarmVideoLane = false
        case .matchingOrphanRunReleased:
            warmVideoPreparationLedger.clearProgress()
        case .runCancelled(let run):
            finishWarmDiagnostics(run: run, result: .cancelled)
        case .resetInvalidation:
            activeVideoSuspendToken = nil
            isVideoLaneWarmSuspended = false
            resetCachedRunway(video: true, audio: false)
            isVideoLanePreparedForForeground = false
            isPreparingWarmVideoLane = false
            isDecodingWarmVideoCandidate = false
        case .supplyRestartOpportunity:
            resumeSupplyAfterWarmPreparation()
        }
    }

    func recordWarmPreparationPrimaryReturn(
        _ run: WarmVideoPreparationRun, result: DemandVideoLanePreparationResult
    ) {
        if activeWarmDiagnostics?.runID == run.id {
            warmDiagnosticPhase(result == .prepared ? "prepared" : "completed")
            finishWarmDiagnostics(run: run, result: result)
        }
    }

    private func logWarmVideoPreparationTimeoutSnapshot(
        _ run: WarmVideoPreparationRun
    ) {
        guard diagnostics.isCapturing else { return }
        let elapsedMs = Int(
            run.startedAt.duration(to: ContinuousClock.now) / .milliseconds(1)
        )
        let audioTarget = audioPresentationMediaTime
        let inputEndPTS = videoPacketEndPTS()
        let decodeEndPTS = videoDecodeFrontierPTS
        let pendingEndPTS = pendingVideoFrameEndPTS()
        let readBytesDelta = videoReadBytesDelta(since: run.token)
        func fmt(_ value: TimeInterval?) -> String {
            guard let value, value.isFinite else { return "nil" }
            return String(format: "%.3f", value)
        }
        diagnostics.log(
            "[PathA][continuation] warm preparation timeout snapshot " +
                "run=\(run.id) elapsedMs=\(elapsedMs) " +
                "audioTarget=\(fmt(audioTarget)) " +
                "outputFloor=\(fmt(outputMediaFloor)) " +
                "inputEndPTS=\(fmt(inputEndPTS)) " +
                "decodeEndPTS=\(fmt(decodeEndPTS)) " +
                "pendingEndPTS=\(fmt(pendingEndPTS)) " +
                "videoReadBytesDelta=\(readBytesDelta)"
        )
    }

    func warmVideoRunIsCurrent(_ run: WarmVideoPreparationRun) -> Bool {
        !Task.isCancelled && warmPreparationTransaction.currentRun == run
            && activeVideoSuspendToken == run.token
            && run.sessionGeneration == runtimeGeneration
            && run.engineGeneration == generation
            && run.ownerGeneration == activeOwnerGeneration
    }

    func warmVideoRunPolicy(_ run: WarmVideoPreparationRun) -> WarmVideoRecoveryPolicy {
        warmPreparationTransaction.policy(for: run)
    }

    func warmVideoRunHasTime(_ run: WarmVideoPreparationRun) -> Bool {
        guard warmVideoRunIsCurrent(run) else { return false }
        return warmPreparationTransaction.hasTime(for: run, host: self)
    }

    func observeWarmVideoPreparationProgress(
        _ frames: [MediaVideoFrame],
        attempt: WarmVideoPreparationAttempt,
        decoderIdentity: ObjectIdentifier
    ) {
        guard isCurrentWarmVideoPreparationAttempt(attempt),
              ObjectIdentifier(videoDecoder) == decoderIdentity,
              !videoDecoderWasRetired,
              let frontier = frames.lazy.filter({ frame in
                frame.pts.isFinite && frame.duration.isFinite && frame.duration >= 0
                    && (frame.pts + frame.duration).isFinite
              }).map(\.pts).max() else { return }
        let sampledAudio = audioPresentationMediaTime
        let sampledFloor = outputMediaFloor
        let floor: TimeInterval? = sampledAudio.isFinite && sampledFloor.isFinite
            ? max(sampledAudio, sampledFloor) : nil
        warmVideoPreparationLedger.observe(
            frontier: frontier, attempt: attempt, decoderIdentity: decoderIdentity,
            floor: floor, observedAt: .now
        )
    }

    func consumeWarmVideoPreparationProgress(for run: WarmVideoPreparationRunLedger.Run) -> Bool {
        guard let attempt = warmVideoPreparationLedger.currentAttempt,
              attempt.runID == run.id,
              isCurrentWarmVideoPreparationAttempt(attempt),
              videoDecoderOpened, !videoDecoderWasRetired else { return false }
        return warmVideoPreparationLedger.consume(
            attempt: attempt, decoderIdentity: ObjectIdentifier(videoDecoder)
        )
    }

    func resumeSupplyAfterWarmPreparation() {
        guard isReady,
              !isPreparingWarmVideoLane,
              warmPreparationTransaction.orphan == nil,
              !warmPreparationTransaction.hasPendingInterrupt else { return }
        startSupplyLoop()
        requestSupplyWake()
    }

    enum VideoLaneResumeDestination: Equatable {
        case inline
        case pictureInPicture
    }

    func resumeVideoLane(
        _ token: DemandVideoSuspendToken,
        renderGeneration: Int,
        destination: VideoLaneResumeDestination = .inline
    ) async -> Bool {
        var strictRefreshes = 0
        while true {
            guard activeVideoSuspendToken == token,
                  token.sessionGeneration == runtimeGeneration,
                  token.ownerGeneration == activeOwnerGeneration,
                  isVideoLaneWarmSuspended,
                  isVideoLanePreparedForForeground else { return false }
            let resumeMediaTime = audioPresentationMediaTime
            guard resumeMediaTime.isFinite else { return false }
            var target = max(0, resumeMediaTime)
        advanceOutputMediaFloor(to: target, reason: "resume")

        let holdNeedsRefresh: Bool
        if let hold = activeWarmVideoImageHold {
            let holdStillCoversAudio = target <= hold.candidateTailPTS
                + Self.videoContinuityAnchorToleranceSeconds
            holdNeedsRefresh = hold.token != token
                || !warmVideoImageHoldIsCurrent(
                    hold,
                    requiresActiveSuspendToken: true
                )
                || !holdStillCoversAudio
        } else {
            holdNeedsRefresh = false
        }
        if holdNeedsRefresh || !warmVideoCandidateHasRequiredOutput(
            disposition: .bracketingPreRoll,
            target: target
        ) {
            if let hold = activeWarmVideoImageHold {
                diagnostics.log(
                    "[PathA][continuation] resume floor advanced " +
                    "floor=\(String(format: "%.3f", target)) " +
                    "candidateEnd=\(String(format: "%.3f", hold.candidateTailPTS)) " +
                    "rejectedStale=\(staleVideoOutputRejectionCount)"
                )
            } else {
                diagnostics.log(
                    "[PathA][continuation] resume requires current-floor frame " +
                    "floor=\(String(format: "%.3f", target)) " +
                    "rejectedStale=\(staleVideoOutputRejectionCount)"
                )
            }
            let continuationDisposition: WarmVideoCandidateDisposition = {
                guard let hold = activeWarmVideoImageHold else {
                    return .bracketingPreRoll
                }
                if case .forwardPositioned(let receipt) = hold.candidateProvenance {
                    return .positionedFutureImageHold(receipt)
                }
                return .nearFutureImageHold(notBeforePTS: hold.notBeforePTS)
            }()
            let continuationCandidateTailPTS =
                activeWarmVideoImageHold?.candidateTailPTS
            activeWarmVideoImageHold = nil
            let decoderIdentity = ObjectIdentifier(videoDecoder)
            let initialTail = max(
                pendingVideoFrameEndPTS() ?? -.infinity,
                videoPacketEndPTS() ?? -.infinity
            )
            var minPendingPTS: TimeInterval?
            for frame in pendingVideoFrames where frame.pts.isFinite {
                minPendingPTS = minPendingPTS.map { min($0, frame.pts) } ?? frame.pts
            }
            let initialAnchor = minPendingPTS ?? target
            let initialByteCount = videoPackets.reduce(into: 0) { total, packet in
                let (updated, overflowed) =
                    total.addingReportingOverflow(packet.data.count)
                total = overflowed ? Int.max : updated
            }
            isDecodingWarmVideoCandidate = true
            var resumeRecovery: WarmVideoRecoveryPolicy?
            let continuation = await continueWarmVideoPreparationToMovingTarget(
                run: nil,
                attempt: nil,
                token: token,
                startTarget: target,
                disposition: continuationDisposition,
                initialCandidateTailPTS: initialTail.isFinite
                    ? initialTail
                    : (continuationCandidateTailPTS ?? target),
                initialCandidateAnchorPTS: initialAnchor,
                initialCandidateByteCount: initialByteCount,
                decoderIdentity: decoderIdentity,
                generation: generation,
                recovery: &resumeRecovery
            )
            isDecodingWarmVideoCandidate = false
            switch continuation {
            case let .covered(coveredTarget, _, _):
                target = max(
                    target,
                    max(
                        coveredTarget,
                        audioPresentationMediaTime.isFinite
                            ? audioPresentationMediaTime
                            : target
                    )
                )
            case .retryLocal, .needsForwardRescue:
                return false
            case .tailExpired:
                guard strictRefreshes == 0 else { return false }
                strictRefreshes += 1
                activeWarmVideoImageHold = nil
                warmVideoPreparationLedger.retireAttempt()
                isDecodingWarmVideoCandidate = false
                isVideoLanePreparedForForeground = false
                terminalVideoPreparationFailure = nil
                suspendedVideoFault = nil
                diagnostics.log(
                    "[PathA][continuation] resume near-future tail " +
                    "refreshing through strict preparation"
                )
                guard await prepareVideoLaneForForeground(token) == .prepared,
                      activeVideoSuspendToken == token,
                      isVideoLaneWarmSuspended else {
                    return false
                }
                continue
            case .exhausted, .cancelled:
                return false
            }
            advanceOutputMediaFloor(to: target, reason: "resume-commit")
        }
        let rendererReady: Bool
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            switch destination {
            case .inline:
                rendererReady = renderer.resumePresentation(
                    renderGeneration: renderGeneration,
                    mediaTime: target,
                    rate: effectiveDisplayRate,
                    mediaFloor: outputMediaFloor
                )
            case .pictureInPicture:
                rendererReady = renderer.resumePiPPresentation(
                    renderGeneration: renderGeneration,
                    mediaTime: target,
                    rate: effectiveDisplayRate,
                    mediaFloor: outputMediaFloor
                )
            }
        } else {
            videoRender.flush()
            rendererReady = true
        }
        guard rendererReady else { return false }

        if var hold = activeWarmVideoImageHold {
            guard hold.token == token,
                  warmVideoImageHoldIsCurrent(
                    hold,
                    requiresActiveSuspendToken: true
                  ) else {
                activeWarmVideoImageHold = nil
                return false
            }
            hold.renderGeneration = renderGeneration
            activeWarmVideoImageHold = hold
        }

        if var identity = warmDiagnosticProofIdentity,
           identity.run.token == token,
           identity.run.sessionGeneration == runtimeGeneration,
           identity.run.engineGeneration == generation,
           identity.run.ownerGeneration == activeOwnerGeneration {
            identity.renderGeneration = renderGeneration
            identity.floor = outputMediaFloor
            warmDiagnosticProofIdentity = identity
        }
        let keepsHoldAuthority = destination == .inline
            && activeWarmVideoImageHold != nil
        if !keepsHoldAuthority {
            activeWarmVideoImageHold = nil
        }
        isVideoLaneWarmSuspended = false
        clearDisplayOutputContinuity()
        resetCachedRunway(video: true, audio: false)
        suspendedVideoSupplyMemorySuppressed = false
        isVideoLanePreparedForForeground = false
        if !keepsHoldAuthority {
            activeVideoSuspendToken = nil
        }
        warmVideoPreparationLedger.retireAttempt()
        terminalVideoPreparationFailure = nil
        suspendedVideoFault = nil
        clearSuspendedVideoGOP()
        applyPipelineDemand()
        armPresentFeedIfNeeded()
        presentDueVideoFrames()
        startSupplyLoop()
        requestSupplyWake()
        scheduleVideoDecodeIfNeeded()
        diagnostics.log(
            "[PathA][continuation] video resumed token=\(token.generation) " +
            "destination=\(destination == .pictureInPicture ? "pip" : "inline") " +
            "render=\(renderGeneration) target=\(String(format: "%.3f", target))"
        )
        return true
        }
    }

    func restoreInlinePresentation(renderGeneration: Int) async -> Bool {
        guard isReady else { return false }
        clearDisplayOutputContinuity()
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            let floor = audioPresentationMediaTime
            guard floor.isFinite else { return false }
            advanceOutputMediaFloor(to: floor, reason: "inline-adoption")
            let adoption = renderer.adoptInlinePresentation(
                renderGeneration: renderGeneration,
                mediaTime: floor,
                rate: effectiveDisplayRate,
                mediaFloor: outputMediaFloor
            )
            guard adoption == .adopted else { return false }
        } else {
            videoRender.setDisplayPlayback(
                rate: effectiveDisplayRate,
                mediaTime: audioPresentationMediaTime
            )
        }
        applyPipelineDemand()
        if isPlaying {
            armPresentFeedIfNeeded()
            presentDueVideoFrames()
            scheduleVideoDecodeIfNeeded()
        }
        return true
    }

    func flushAndPrimeRenderer(renderGeneration: Int) -> Bool {
        clearDisplayOutputContinuity()
        let target = audioPresentationMediaTime
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            return renderer.resumePresentation(
                renderGeneration: renderGeneration,
                mediaTime: target,
                rate: effectiveDisplayRate
            )
        }
        videoRender.flush()
        videoRender.setDisplayPlayback(rate: effectiveDisplayRate, mediaTime: target)
        return true
    }

    func cancelWarmVideoImageHoldRefresh() {
        warmVideoImageHoldRefreshTask?.cancel()
        warmVideoImageHoldRefreshTask = nil
        activeWarmVideoImageHoldRefreshID = nil
    }

    func supersedeWarmVideoPreparationRun() {
        warmPreparationTransaction.supersede(host: self)
    }

    func clearSuspendedVideoGOP() {
        suspendedVideoGOP = []
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPProvenance = nil
    }

    func resetVideoContinuationState() {
        warmPreparationTransaction.reset(host: self)
        warmVideoPreparationLedger.retireAttempt()
        warmVideoSubmissionsWithoutOutput = 0
        isCollectingWarmVideoRunUp = false
        warmVideoCandidateAuthorities = []
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        nextVideoReadGeneration = 0
        videoReadBytes = 0
        clearSuspendedVideoGOP()
        suspendedVideoSupplyMemorySuppressed = false
        suspendedVideoFault = nil
        terminalVideoPreparationFailure = nil
        videoContinuityTopology = .unsupported
    }

    var suspendedVideoRunway: TimeInterval {
        guard let end = suspendedVideoGOP.last.map({ $0.pts + max(0, $0.duration) }) else {
            return 0
        }
        return max(0, end - audioPresentationMediaTime)
    }

    var suspendedVideoSupplyTarget: TimeInterval {
        guard !suspendedVideoSupplyMemorySuppressed else { return 0 }
        switch videoContinuityTopology {
        case .muxedCurrentGOP:
            return Self.suspendedVideoTargetAheadSeconds
        case .splitTrack, .localFileIndex:
            guard !isPreparingWarmVideoLane, !isVideoLanePreparedForForeground,
                  activeWarmVideoImageHoldRefreshID == nil else { return 0 }
            return videoPacketQueue.highWater
        case .unsupported:
            return 0
        }
    }

    func retainSuspendedVideoPacket(
        _ packet: MediaPacket,
        provenance: DemandVideoCandidateProvenance
    ) {
        guard packet.track == .video,
              !suspendedVideoSupplyMemorySuppressed
            || isCollectingWarmVideoRunUp else { return }
        let packet = normalizingZeroDuration(packet)
        if suspendedVideoGOP.isEmpty, !packet.isKeyframe {
            return
        }
        if suspendedVideoGOPProvenance == nil {
            suspendedVideoGOPProvenance = provenance
        } else if suspendedVideoGOPProvenance != provenance {
            switch provenance {
            case .postSuspend:
                suspendedVideoGOPProvenance = provenance
            case .positioned, .forwardPositioned:
                suspendedVideoGOPProvenance = provenance
            case .suspendEdge:
                break
            }
        }
        suspendedVideoGOP.append(packet)
        suspendedVideoGOPContentSeconds += max(0, packet.duration)
        suspendedVideoGOPBytes += packet.data.count
        if isCollectingWarmVideoRunUp {
            if suspendedVideoGOPContentSeconds > Self.suspendedVideoGOPMaxContentSeconds
                || suspendedVideoGOPBytes > Self.suspendedVideoGOPMaxBytes {
                clearSuspendedVideoGOP()
            }
            return
        }
        if packet.isKeyframe {
            trimSuspendedVideoWindowBehindClock(audioPresentationMediaTime)
        }
        enforceSuspendedVideoWindowCaps()
    }

    private func suspendedVideoWindowSecondKeyframeIndex() -> Int? {
        var foundFirst = false
        for (index, packet) in suspendedVideoGOP.enumerated() where packet.isKeyframe {
            if foundFirst { return index }
            foundFirst = true
        }
        return nil
    }

    private func dropSuspendedVideoWindowPrefix(before index: Int) {
        guard index > 0, index <= suspendedVideoGOP.count else { return }
        for packet in suspendedVideoGOP[..<index] {
            suspendedVideoGOPContentSeconds -= max(0, packet.duration)
            suspendedVideoGOPBytes -= packet.data.count
        }
        suspendedVideoGOP.removeFirst(index)
        suspendedVideoGOPContentSeconds = max(0, suspendedVideoGOPContentSeconds)
        suspendedVideoGOPBytes = max(0, suspendedVideoGOPBytes)
    }

    func trimSuspendedVideoWindowBehindClock(_ horizon: TimeInterval) {
        guard horizon.isFinite else { return }
        while let second = suspendedVideoWindowSecondKeyframeIndex(),
              suspendedVideoGOP[second].pts <= horizon {
            dropSuspendedVideoWindowPrefix(before: second)
        }
    }

    private func enforceSuspendedVideoWindowCaps() {
        guard suspendedVideoGOPContentSeconds > Self.suspendedVideoWindowMaxContentSeconds
            || suspendedVideoGOPBytes > Self.suspendedVideoWindowMaxBytes else { return }
        while let second = suspendedVideoWindowSecondKeyframeIndex(),
              suspendedVideoGOPContentSeconds > Self.suspendedVideoWindowMaxContentSeconds
                || suspendedVideoGOPBytes > Self.suspendedVideoWindowMaxBytes {
            dropSuspendedVideoWindowPrefix(before: second)
        }
        if suspendedVideoGOPContentSeconds > Self.suspendedVideoWindowMaxContentSeconds
            || suspendedVideoGOPBytes > Self.suspendedVideoWindowMaxBytes {
            clearSuspendedVideoGOP()
        }
    }

    func discardSuspendedVideoWindowForMemoryPressure() {
        guard isVideoLaneWarmSuspended else { return }
        switch videoContinuityTopology {
        case .splitTrack, .localFileIndex: break
        case .muxedCurrentGOP, .unsupported: return
        }
        clearSuspendedVideoGOP()
        suspendedVideoSupplyMemorySuppressed = true
        diagnostics.log(
            "[PathA][continuation] suspended video window shed (memory pressure) " +
            "audio=\(String(format: "%.3f", audioPresentationMediaTime))"
        )
    }

    func suspendedVideoCandidate(at target: TimeInterval) -> [MediaPacket]? {
        guard let first = suspendedVideoGOP.first,
              first.isKeyframe,
              target.isFinite,
              let last = suspendedVideoGOP.last,
              let lastEnd = finiteMediaIntervalEnd(
                  start: last.pts,
                  duration: last.duration
              ),
              lastEnd + Self.videoContinuityAnchorToleranceSeconds >= target else {
            return nil
        }
        return suspendedVideoGOP
    }

    func recordWarmVideoCandidateAuthority(
        _ candidate: [MediaPacket]
    ) -> MediaVideoContinuityCandidateAuthority {
        let first = candidate.first
        let endPTS = candidate.reduce(0) {
            max($0, $1.pts + max(0, $1.duration))
        }
        return recordWarmVideoCandidateAuthority(
            anchorPTS: first?.pts ?? 0,
            firstDTS: first?.dts,
            endPTS: endPTS,
            packetCount: candidate.count,
            byteCount: candidate.reduce(0) { $0 + $1.data.count },
            startsWithSyncSample: first?.isKeyframe == true
        )
    }

    func recordWarmVideoCandidateAuthority(
        anchorPTS: TimeInterval,
        firstDTS: TimeInterval?,
        endPTS: TimeInterval,
        packetCount: Int,
        byteCount: Int,
        startsWithSyncSample: Bool
    ) -> MediaVideoContinuityCandidateAuthority {
        nextVideoContinuityCandidateGeneration &+= 1
        if nextVideoContinuityCandidateGeneration == 0 {
            nextVideoContinuityCandidateGeneration = 1
        }
        let authority = MediaVideoContinuityCandidateAuthority(
            generation: nextVideoContinuityCandidateGeneration,
            anchorPTS: anchorPTS,
            firstDTS: firstDTS,
            endPTS: endPTS,
            packetCount: packetCount,
            byteCount: byteCount,
            startsWithSyncSample: startsWithSyncSample
        )
        warmVideoCandidateAuthorities.append(authority)
        let limit = Self.warmVideoDecoderRepairLimit + 1
        if warmVideoCandidateAuthorities.count > limit {
            warmVideoCandidateAuthorities.removeFirst(
                warmVideoCandidateAuthorities.count - limit
            )
        }
        return authority
    }

    func sameCompressedPacket(
        _ lhs: MediaPacket,
        _ rhs: MediaPacket
    ) -> Bool {
        let samePixelBuffer: Bool
        switch (lhs.pixelBuffer, rhs.pixelBuffer) {
        case (nil, nil):
            samePixelBuffer = true
        case let (left?, right?):
            samePixelBuffer = left === right
        default:
            samePixelBuffer = false
        }
        return lhs.track == rhs.track
            && lhs.data == rhs.data
            && samePixelBuffer
    }

    func sameCompressedCandidate(
        _ lhs: [MediaPacket],
        _ rhs: [MediaPacket]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            sameCompressedPacket(left, right)
        }
    }

    func formatOptionalMediaTime(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.3f", value)
    }

    func retainedVideoWindowBrackets(_ target: TimeInterval) -> Bool {
        guard let first = suspendedVideoGOP.first,
              first.isKeyframe,
              target.isFinite,
              first.pts <= target + Self.videoContinuityAnchorToleranceSeconds,
              let last = suspendedVideoGOP.last,
              let lastEnd = finiteMediaIntervalEnd(
                  start: last.pts,
                  duration: last.duration
              ),
              lastEnd + Self.videoContinuityAnchorToleranceSeconds >= target else {
            return false
        }
        return true
    }

    static func classifyWarmVideoCandidate(
        _ candidate: [MediaPacket],
        topology: MediaVideoContinuityTopology,
        target: TimeInterval,
        retainedInMemory: Bool,
        contentSeconds: TimeInterval,
        byteCount: Int
    ) -> WarmVideoCandidateDisposition {
        guard target.isFinite,
              let first = candidate.first,
              first.isKeyframe else {
            return .requiresPositioning
        }
        let decodeAnchor = (first.dts?.isFinite == true ? first.dts : first.pts) ?? first.pts
        guard decodeAnchor.isFinite else { return .requiresPositioning }
        let endPTS = candidate.reduce(-TimeInterval.infinity) { partial, packet in
            guard packet.pts.isFinite, packet.duration.isFinite else { return partial }
            return max(partial, packet.pts + max(0, packet.duration))
        }
        guard endPTS.isFinite,
              endPTS + videoContinuityAnchorToleranceSeconds >= target else {
            return .requiresPositioning
        }
        if decodeAnchor <= target + videoContinuityAnchorToleranceSeconds {
            return .bracketingPreRoll
        }

        let lead = decodeAnchor - target
        guard topology == .splitTrack,
              retainedInMemory,
              lead > videoContinuityAnchorToleranceSeconds,
              lead <= suspendedVideoTargetAheadSeconds + 1e-9,
              contentSeconds.isFinite,
              contentSeconds >= 0,
              contentSeconds <= suspendedVideoWindowMaxContentSeconds + 1e-9,
              byteCount >= 0,
              byteCount <= suspendedVideoWindowMaxBytes else {
            return .requiresPositioning
        }

        var distinctPTS: [TimeInterval] = []
        for packet in candidate where packet.pts.isFinite
            && packet.pts + 1e-9 >= decodeAnchor {
            if !distinctPTS.contains(where: { abs($0 - packet.pts) <= 1e-9 }) {
                distinctPTS.append(packet.pts)
                if distinctPTS.count >= 2 {
                    return .nearFutureImageHold(notBeforePTS: decodeAnchor)
                }
            }
        }
        return .requiresPositioning
    }

    func warmVideoCandidateHasRequiredOutput(
        disposition: WarmVideoCandidateDisposition,
        target: TimeInterval
    ) -> Bool {
        guard target.isFinite else { return false }
        switch disposition {
        case .bracketingPreRoll, .requiresPositioning:
            let floor = max(outputMediaFloor, target)
            return pendingVideoFrames.contains {
                isVideoFrameUsableAtOutputFloor($0, floor: floor)
                    && $0.pts + $0.duration + 1e-9 >= floor
            }
        case .nearFutureImageHold, .positionedFutureImageHold:
            guard let notBeforePTS = disposition.futureNotBeforePTS else { return false }
            let floor = max(outputMediaFloor, max(target, notBeforePTS))
            var firstPTS: TimeInterval?
            for frame in pendingVideoFrames where frame.pts.isFinite
                && isVideoFrameUsableAtOutputFloor(frame, floor: floor)
                && frame.pts + frame.duration + 1e-9 >= floor {
                guard let firstPTS else {
                    firstPTS = frame.pts
                    continue
                }
                if abs(frame.pts - firstPTS) > 1e-9 {
                    return true
                }
            }
            return false
        }
    }

    var warmVideoImageHoldWithholdsVideoSupply: Bool {
        activeWarmVideoImageHold != nil
    }

    func warmVideoImageHoldCandidateIsCurrent(
        _ hold: WarmVideoImageHoldSnapshot
    ) -> Bool {
        switch hold.candidateProvenance {
        case .suspendEdge(let readGeneration):
            guard readGeneration == hold.token.videoReadGeneration,
                  hold.foregroundFetchBytes == 0 else { return false }
        case .forwardPositioned(let receipt):
            let remainingLead = max(0, receipt.anchorPTS - audioPresentationMediaTime)
            let wallSeconds = Double(warmVideoPreparationDeadline / .seconds(1))
            guard hold.foregroundFetchBytes >= receipt.selectionFetchBytes,
                  receipt.anchorPTS == hold.notBeforePTS,
                  hold.candidateTailPTS <= receipt.contentInterval.end + 1e-9,
                  playbackRate.isFinite, playbackRate > 0,
                  remainingLead.isFinite, remainingLead <= receipt.maximumLead,
                  remainingLead / Double(playbackRate) <= wallSeconds else { return false }
        case .postSuspend, .positioned:
            return false
        }
        return warmVideoCandidateAuthorities.contains { authority in
            authority.generation == hold.candidateAuthorityGeneration
                && authority.startsWithSyncSample
                && warmVideoHoldAnchorMatches(authority, hold: hold)
                && abs(authority.endPTS - hold.candidateTailPTS) <= 1e-9
        }
    }

    func warmVideoHoldAnchorMatches(
        _ authority: MediaVideoContinuityCandidateAuthority,
        hold: WarmVideoImageHoldSnapshot
    ) -> Bool {
        switch hold.candidateProvenance {
        case .forwardPositioned(let receipt):
            return abs(authority.anchorPTS - receipt.anchorPTS) <= 1e-9
                && receipt.anchorPTS == hold.notBeforePTS
        case .suspendEdge:
            return abs(authority.decodeAnchorTime - hold.notBeforePTS) <= 1e-9
        case .positioned, .postSuspend:
            return false
        }
    }

    func warmVideoImageHoldIsCurrent(
        _ hold: WarmVideoImageHoldSnapshot,
        requiresActiveSuspendToken: Bool
    ) -> Bool {
        let tokenIsCurrent = requiresActiveSuspendToken
            ? (isVideoLaneWarmSuspended && activeVideoSuspendToken == hold.token)
            : (!isVideoLaneWarmSuspended
                && hold.renderGeneration != nil
                && activeVideoSuspendToken == hold.token)
        return hold.runID != 0
            && runtimeGeneration == hold.sessionGeneration
            && generation == hold.engineGeneration
            && activeOwnerGeneration == hold.ownerGeneration
            && playbackRateRevision == hold.rateRevision
            && tokenIsCurrent
            && warmVideoImageHoldCandidateIsCurrent(hold)
    }

    func releaseWarmVideoImageHoldIfDue(
        _ due: TimeInterval
    ) -> WarmVideoImageHoldReleaseOutcome {
        guard let hold = activeWarmVideoImageHold else {
            return .released
        }
        guard warmVideoImageHoldIsCurrent(
            hold,
            requiresActiveSuspendToken: isVideoLaneWarmSuspended
        ) else {
            refreshWarmVideoImageHold(hold, reason: "authority")
            return .refreshRequired
        }
        let liveAudio = audioPresentationMediaTime
        guard liveAudio.isFinite,
              due.isFinite,
              liveAudio <= hold.candidateTailPTS
                + Self.videoContinuityAnchorToleranceSeconds else {
            diagnostics.log(
                "[PathA][continuation] hold stale before proof " +
                "notBefore=\(String(format: "%.3f", hold.notBeforePTS)) " +
                "tail=\(String(format: "%.3f", hold.candidateTailPTS)) " +
                "audio=\(String(format: "%.3f", liveAudio))"
            )
            refreshWarmVideoImageHold(hold, reason: "tail-or-clock")
            return .refreshRequired
        }
        guard due + 1e-9 >= hold.notBeforePTS else {
            return .waiting
        }
        guard !hold.hasReachedAudioDueTime else {
            return .released
        }
        var released = hold
        released.hasReachedAudioDueTime = true
        activeWarmVideoImageHold = released
        diagnostics.log(
            "[PathA][continuation] hold release " +
            "token=\(hold.token.generation) " +
            "notBefore=\(String(format: "%.3f", hold.notBeforePTS)) " +
            "due=\(String(format: "%.3f", due)) " +
            "foregroundFetchBytes=\(hold.foregroundFetchBytes)"
        )
        return .released
    }

    func refreshWarmVideoImageHold(
        _ hold: WarmVideoImageHoldSnapshot,
        reason: String
    ) {
        guard activeWarmVideoImageHold == hold else { return }
        activeWarmVideoImageHold = nil
        clearVideoTrackQueues()
        resetCachedRunway(video: true, audio: false)
        clearSuspendedVideoGOP()

        guard activeVideoSuspendToken == hold.token,
              hold.token.sessionGeneration == runtimeGeneration,
              hold.engineGeneration == generation,
              hold.ownerGeneration == activeOwnerGeneration else {
            return
        }

        let token = hold.token
        let renderGeneration = hold.renderGeneration
        isVideoLaneWarmSuspended = true
        isVideoLanePreparedForForeground = false
        isPreparingWarmVideoLane = false
        terminalVideoPreparationFailure = nil
        suspendedVideoFault = nil
        disarmPresentFeed()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        videoRender.flush()
        diagnostics.log(
            "[PathA][continuation] hold refresh required reason=\(reason) " +
            "token=\(token.generation) " +
            "render=\(renderGeneration.map(String.init) ?? "n/a")"
        )

        nextWarmVideoImageHoldRefreshID &+= 1
        if nextWarmVideoImageHoldRefreshID == 0 {
            nextWarmVideoImageHoldRefreshID = 1
        }
        let refreshID = nextWarmVideoImageHoldRefreshID
        activeWarmVideoImageHoldRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            defer { self?.completeWarmVideoImageHoldRefresh(id: refreshID) }
            guard let self,
                  self.activeWarmVideoImageHoldRefreshID == refreshID,
                  self.activeVideoSuspendToken == token,
                  self.isVideoLaneWarmSuspended,
                  token.sessionGeneration == self.runtimeGeneration,
                  hold.engineGeneration == self.generation,
                  hold.ownerGeneration == self.activeOwnerGeneration else { return }
            let result = await self.prepareVideoLaneForForeground(token)
            guard self.activeWarmVideoImageHoldRefreshID == refreshID,
                  self.activeVideoSuspendToken == token,
                  token.sessionGeneration == self.runtimeGeneration,
                  hold.engineGeneration == self.generation,
                  hold.ownerGeneration == self.activeOwnerGeneration else { return }
            switch result {
            case .prepared:
                guard let renderGeneration else { return }
                let resumed = await self.resumeVideoLane(
                    token,
                    renderGeneration: renderGeneration
                )
                guard self.activeWarmVideoImageHoldRefreshID == refreshID,
                      self.activeVideoSuspendToken == token else { return }
                if !resumed {
                    diagnostics.log(
                        "[PathA][continuation] hold refresh resume failed " +
                        "render=\(renderGeneration)"
                    )
                    self.onPresentationFailure?(.decoderRecoveryFailed, renderGeneration)
                }
            case .failed(let failure):
                diagnostics.log(
                    "[PathA][continuation] hold refresh terminal " +
                    "failure=\(failure.rawValue)"
                )
                self.onPresentationFailure?(failure, renderGeneration)
            case .cancelled:
                break
            }
        }
        warmVideoImageHoldRefreshTask = task
    }

    func completeWarmVideoImageHoldRefresh(id: UInt64) {
        guard activeWarmVideoImageHoldRefreshID == id else { return }
        activeWarmVideoImageHoldRefreshID = nil
        warmVideoImageHoldRefreshTask = nil
    }

    func completeWarmVideoImageHoldIfProved(
        renderGeneration: Int,
        mediaTime: TimeInterval,
        rendererReady: Bool
    ) {
        guard let hold = activeWarmVideoImageHold,
              hold.hasReachedAudioDueTime,
              hold.renderGeneration == renderGeneration,
              rendererReady,
              mediaTime.isFinite,
              mediaTime + 1e-9 >= hold.notBeforePTS,
              mediaTime <= hold.candidateTailPTS
                + Self.videoContinuityAnchorToleranceSeconds,
              warmVideoImageHoldIsCurrent(
                hold,
                requiresActiveSuspendToken: false
              ) else {
            return
        }
        activeWarmVideoImageHold = nil
        if !isVideoLaneWarmSuspended {
            activeVideoSuspendToken = nil
        }
        requestSupplyWake()
    }
}
