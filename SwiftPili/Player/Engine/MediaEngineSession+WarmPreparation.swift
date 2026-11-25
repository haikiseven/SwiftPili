import Foundation

extension MediaEngineSession {
    func performWarmVideoPreparation(
        _ run: WarmVideoPreparationRunLedger.Run
    ) async -> DemandVideoLanePreparationResult {
        let token = run.token
        let previousSupplyLoop = supplyLoopTask
        cancelSupplyLoop()
        (videoRender as? SampleBufferVideoRenderer)?.refreshPresentationImageHold()
        let quiesceSupplyStart = ContinuousClock.now
        await previousSupplyLoop?.value
        if warmPreparationAttemptIsActive(runID: run.id) {
            activeWarmDiagnostics?.quiesceWaitTime += quiesceSupplyStart.duration(to: .now)
        }
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration else {
            return abandonWarmVideoPreparation(run)
        }
        isPreparingWarmVideoLane = true
        defer {
            if warmPreparationTransaction.currentRun?.id == run.id {
                isDecodingWarmVideoCandidate = false
                isCollectingWarmVideoRunUp = false
            }
            if warmVideoPreparationLedger.currentAttempt?.runID == run.id {
                warmVideoPreparationLedger.retireAttempt()
            }
        }
        let previousAudioDecodeTask = audioDecodeTask
        let quiesceAudioStart = ContinuousClock.now
        await previousAudioDecodeTask?.value
        if warmPreparationAttemptIsActive(runID: run.id) {
            activeWarmDiagnostics?.quiesceWaitTime += quiesceAudioStart.duration(to: .now)
        }
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
            return abandonWarmVideoPreparation(run)
        }
        let previousDecodeTask = decodeTask
        cancelVideoDecode(clearHandle: false)
        let quiesceVideoStart = ContinuousClock.now
        await previousDecodeTask?.value
        if warmPreparationAttemptIsActive(runID: run.id) {
            activeWarmDiagnostics?.quiesceWaitTime += quiesceVideoStart.duration(to: .now)
        }
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
            return abandonWarmVideoPreparation(run)
        }
        decodeTask = nil

        packetRelay.reset()

        var recovery = warmVideoRunPolicy(run)
        var rejectedCandidate: [MediaPacket]?
        var rejectedCandidateAuthority: MediaVideoContinuityCandidateAuthority?
        for repairIndex in 0...Self.warmVideoDecoderRepairLimit {
            guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                  activeVideoSuspendToken == token,
                  token.sessionGeneration == runtimeGeneration,
                  token.ownerGeneration == activeOwnerGeneration else {
                return abandonWarmVideoPreparation(run)
            }
            let startTarget = audioPresentationMediaTime
            guard startTarget.isFinite else {
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }
            let target = max(0, startTarget)

            let escalatedRung = repairIndex > 0
            let retainedCandidate = suspendedVideoCandidate(at: target) ?? []
            let retainedCandidateIsAtSuspendEdge: Bool = {
                guard let provenance = suspendedVideoGOPProvenance else {
                    return false
                }
                guard case .suspendEdge(let readGeneration) = provenance else {
                    return false
                }
                return readGeneration == token.videoReadGeneration
            }()
            var candidateDisposition: WarmVideoCandidateDisposition = escalatedRung
                ? .requiresPositioning
                : Self.classifyWarmVideoCandidate(
                    retainedCandidate,
                    topology: videoContinuityTopology,
                    target: target,
                    retainedInMemory: retainedCandidateIsAtSuspendEdge
                        && videoReadBytesDelta(since: token) == 0,
                    contentSeconds: suspendedVideoGOPContentSeconds,
                    byteCount: suspendedVideoGOPBytes
                )
            let retainedWindowBracketsTarget = retainedVideoWindowBrackets(target)
            let repositionsVideoReader: Bool
            switch videoContinuityTopology {
            case .splitTrack, .localFileIndex:
                switch candidateDisposition {
                case .bracketingPreRoll, .nearFutureImageHold, .positionedFutureImageHold:
                    repositionsVideoReader = false
                case .requiresPositioning:
                    repositionsVideoReader = true
                }
            case .muxedCurrentGOP:
                repositionsVideoReader = false
            case .unsupported:
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .unsupportedVideoContinuity
                )
            }
            diagnostics.log({
                let retainedWindowRange: String
                if let first = suspendedVideoGOP.first, let last = suspendedVideoGOP.last {
                    retainedWindowRange = String(format: "%.3f..%.3f", first.pts, last.pts + max(0, last.duration))
                } else {
                    retainedWindowRange = "empty"
                }
                return "[PathA][continuation] prepare attempt=\(repairIndex + 1) " +
                    "reposition=\(repositionsVideoReader ? 1 : 0) " +
                    "brackets=\(retainedWindowBracketsTarget ? 1 : 0) " +
                    "candidateMode=\(candidateDisposition.diagnosticName) " +
                    "gop=\(retainedWindowRange) " +
                    "topology=\(videoContinuityTopology.rawValue) " +
                    "target=\(String(format: "%.3f", target))"
            }())
            var forwardReceipt: MediaVideoForwardReceipt?
            var forwardFetchedBytes = 0
            var forwardChargedBytes = 0
            if repositionsVideoReader {
                do {
                    let positioned: Bool
                    let demuxWaitStartedAt = ContinuousClock.now
                    let renewedRungStarted = escalatedRung ? ContinuousClock.now : nil
                    if escalatedRung {
                        guard let rejectedCandidateAuthority else {
                            retireCurrentVideoDecoderWithoutWaiting()
                            return finishWarmVideoPreparation(
                                token: token,
                                failure: .decoderPreparationExhausted
                            )
                        }
                        resetCachedRunway(video: true, audio: false)
                        positioned = try await demux.prepareEarlierVideoContinuity(
                            before: rejectedCandidateAuthority.anchorPTS
                        )
                    } else {
                        resetCachedRunway(video: true, audio: false)
                        let rateRevision = playbackRateRevision
                        let forward = try await demux.prepareForwardVideoContinuity(
                            MediaVideoForwardRequest(
                                target: target, playbackRate: Double(playbackRate),
                                wallAllowance: warmVideoPreparationDeadline - run.startedAt.duration(to: .now),
                                maximumCompressedBytes: Self.suspendedVideoGOPMaxBytes,
                                maximumContentSpan: Self.suspendedVideoGOPMaxContentSeconds
                            )
                        )
                        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                              activeVideoSuspendToken == token,
                              playbackRateRevision == rateRevision else {
                            return abandonWarmVideoPreparation(run)
                        }
                        switch forward {
                        case .notSelected:
                            positioned = try await demux.prepareVideoContinuity(at: target)
                        case .positioned(let receipt):
                            forwardReceipt = receipt
                            positioned = true
                        }
                    }
                    guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                          activeVideoSuspendToken == token,
                          token.sessionGeneration == runtimeGeneration,
                          token.ownerGeneration == activeOwnerGeneration else {
                        return abandonWarmVideoPreparation(run)
                    }
                    if warmPreparationAttemptIsActive(runID: run.id),
                       var state = activeWarmDiagnostics {
                        state.demuxWaitTime += demuxWaitStartedAt.duration(to: .now)
                        activeWarmDiagnostics = state
                        warmDiagnosticPhase("demux-positioned")
                    }
                    guard positioned else {
                        if escalatedRung {
                            retireCurrentVideoDecoderWithoutWaiting()
                        }
                        return finishWarmVideoPreparation(
                            token: token,
                            failure: escalatedRung
                                ? .decoderPreparationExhausted
                                : .unsupportedVideoContinuity
                        )
                    }
                    if let renewedRungStarted,
                       renewedRungStarted.duration(to: ContinuousClock.now)
                            >= Self.warmVideoDirectWallLimit {
                        if escalatedRung {
                            retireCurrentVideoDecoderWithoutWaiting()
                        }
                        return finishWarmVideoPreparation(
                            token: token,
                            failure: .decoderPreparationExhausted
                        )
                    }

                    if escalatedRung {
                        guard let rejectedCandidate,
                              let rejectedCandidateAuthority else {
                            retireCurrentVideoDecoderWithoutWaiting()
                            return finishWarmVideoPreparation(
                                token: token,
                                failure: .decoderPreparationExhausted
                            )
                        }
                        return await performRenewedWarmVideoStreaming(
                            run: run,
                            token: token,
                            target: target,
                            rejectedCandidate: rejectedCandidate,
                            rejectedCandidateAuthority: rejectedCandidateAuthority,
                            generation: generation,
                            started: renewedRungStarted ?? ContinuousClock.now,
                            recovery: &recovery
                        )
                    }

                    clearSuspendedVideoGOP()
                    isCollectingWarmVideoRunUp = true
                    if let forwardReceipt {
                        let collection = try await collectForwardVideoCandidate(
                            receipt: forwardReceipt, run: run,
                            phaseStarted: run.startedAt, phaseAllowance: warmVideoPreparationDeadline
                        )
                        forwardFetchedBytes = collection.fetchedBytes
                        forwardChargedBytes = collection.chargedBytes
                        let forwardCandidate = suspendedVideoCandidate(at: target) ?? []
                        candidateDisposition = classifyForwardVideoCandidate(
                            forwardCandidate, receipt: forwardReceipt, target: target
                        )
                        guard candidateDisposition != .requiresPositioning else {
                            return finishWarmVideoPreparation(
                                token: token, failure: .decoderPreparationExhausted
                            )
                        }
                        diagnostics.log(
                            "[PathA][continuation] forward candidate receipt=\(forwardReceipt.id) " +
                            "anchor=\(String(format: "%.3f", forwardReceipt.anchorPTS)) " +
                            "foregroundFetchBytes=\(forwardFetchedBytes)"
                        )
                    } else {
                        for _ in 0..<8 where suspendedVideoCandidate(at: target) == nil {
                            let readGeneration = beginVideoReadGeneration()
                            let demuxWaitStartedAt = ContinuousClock.now
                            resetCachedRunway(video: true, audio: false)
                            let packets = try await demux.pump(
                                videoBudget: 1,
                                audioBudget: 0
                            )
                            if warmPreparationAttemptIsActive(runID: run.id),
                               var state = activeWarmDiagnostics {
                                state.demuxWaitTime += demuxWaitStartedAt.duration(to: .now)
                                activeWarmDiagnostics = state
                                activeWarmDiagnostics?.pumps += 1
                                warmDiagnosticPhase("demux-pump")
                            }
                            guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                                  activeVideoSuspendToken == token,
                                  token.sessionGeneration == runtimeGeneration,
                                  token.ownerGeneration == activeOwnerGeneration else {
                                return abandonWarmVideoPreparation(run)
                            }
                            if !packets.isEmpty {
                                ingest(
                                    packets,
                                    videoReadGeneration: readGeneration,
                                    warmVideoProvenance: .positioned(
                                        readGeneration: readGeneration
                                    )
                                )
                            }
                            drainRelayedPackets()
                            if packets.isEmpty, suspendedVideoGOP.isEmpty {
                                let reachedEOF = await demux.isEOF
                                guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
                                    return abandonWarmVideoPreparation(run)
                                }
                                if reachedEOF { break }
                            }
                        }
                    }
                    isCollectingWarmVideoRunUp = false
                } catch {
                    guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                          activeVideoSuspendToken == token,
                          token.sessionGeneration == runtimeGeneration,
                          token.ownerGeneration == activeOwnerGeneration else {
                        return abandonWarmVideoPreparation(run)
                    }
                    diagnostics.log(
                        "[PathA][continuation] video-only prepare failed " +
                        "topology=\(videoContinuityTopology.rawValue)"
                    )
                    if escalatedRung {
                        retireCurrentVideoDecoderWithoutWaiting()
                    }
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: escalatedRung
                            ? .decoderPreparationExhausted
                            : .unsupportedVideoContinuity
                    )
                }
            }
            guard let candidate = suspendedVideoCandidate(at: target) else {
                diagnostics.log(
                    "[PathA][continuation] prepare failed — no current keyframe GOP " +
                    "target=\(String(format: "%.3f", target))"
                )
                if escalatedRung {
                    retireCurrentVideoDecoderWithoutWaiting()
                }
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }

            let candidateAuthority = recordWarmVideoCandidateAuthority(candidate)
            diagnostics.log(
                "[PathA][continuation] candidate authority=" +
                "\(candidateAuthority.generation) attempt=\(repairIndex + 1) " +
                "sync=\(candidateAuthority.startsWithSyncSample ? 1 : 0) " +
                "packets=\(candidateAuthority.packetCount) " +
                "bytes=\(candidateAuthority.byteCount) " +
                "pts=\(String(format: "%.3f..%.3f", candidateAuthority.anchorPTS, candidateAuthority.endPTS)) " +
                "dts=" + formatOptionalMediaTime(candidateAuthority.firstDTS)
            )
            let candidateStartsAtOrBeforeTarget = candidateAuthority.decodeAnchorTime
                <= target + Self.videoContinuityAnchorToleranceSeconds
            let nearFutureNotBeforePTS = candidateDisposition.futureNotBeforePTS
            if let rejectedCandidate, let rejectedCandidateAuthority {
                let hasEarlierAnchor = candidateAuthority.decodeAnchorTime
                    < rejectedCandidateAuthority.decodeAnchorTime - 1e-6
                let hasDistinctCompressedSequence = !sameCompressedCandidate(
                    candidate,
                    rejectedCandidate
                )
                guard candidateAuthority.startsWithSyncSample,
                      candidateStartsAtOrBeforeTarget,
                      hasEarlierAnchor,
                      hasDistinctCompressedSequence else {
                    diagnostics.log(
                        "[PathA][continuation] renewed candidate rejected " +
                        "attempt=\(repairIndex + 1) " +
                        "brackets=\(candidateStartsAtOrBeforeTarget ? 1 : 0) " +
                        "earlier=\(hasEarlierAnchor ? 1 : 0) " +
                        "distinct=\(hasDistinctCompressedSequence ? 1 : 0) " +
                        "packets=\(candidateAuthority.packetCount)"
                    )
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
            } else if !candidateAuthority.startsWithSyncSample
                || (!candidateStartsAtOrBeforeTarget && nearFutureNotBeforePTS == nil) {
                guard repairIndex < Self.warmVideoDecoderRepairLimit else {
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
                diagnostics.log(
                    "[PathA][continuation] candidate lacks target pre-roll " +
                    "attempt=\(repairIndex + 1) " +
                    "sync=\(candidateAuthority.startsWithSyncSample ? 1 : 0) " +
                    "anchor=\(String(format: "%.3f", candidateAuthority.decodeAnchorTime)) " +
                    "target=\(String(format: "%.3f", target))"
                )
                rejectedCandidate = candidate
                rejectedCandidateAuthority = candidateAuthority
                continue
            }

            if let nearFutureNotBeforePTS {
                diagnostics.log(
                    "[PathA][continuation] candidateMode=near-future-image-hold " +
                    "lead=\(String(format: "%.3f", nearFutureNotBeforePTS - target)) " +
                    "notBefore=\(String(format: "%.3f", nearFutureNotBeforePTS)) " +
                    "foregroundFetchBytes=\(videoReadBytesDelta(since: token))"
                )
            }

            guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
                return abandonWarmVideoPreparation(run)
            }
            let attempt = beginWarmVideoPreparationAttempt(run: run, target: target)
            suspendedVideoFault = nil
            terminalVideoPreparationFailure = nil
            let triesRetainedPausedPiPDecoder = token.reason == .pipDidStop
                && !token.resumesPlayback
                && repairIndex == 0
                && suspendedVideoFault == nil
            let usedFreshDecoder = triesRetainedPausedPiPDecoder
                ? false
                : installFreshVideoDecoder(retiringCurrent: true, warmPreparationAttempt: attempt)
            if !usedFreshDecoder {
                guard triesRetainedPausedPiPDecoder || repairIndex == 0 else {
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
                await videoDecoder.flush()
            }
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                return abandonWarmVideoPreparation(run)
            }
            await openVideoDecoderIfNeeded(warmPreparationAttempt: attempt)
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                return abandonWarmVideoPreparation(run)
            }
            guard videoDecoderOpened else {
                retireCurrentVideoDecoderWithoutWaiting()
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }

            clearVideoTrackQueues()
            resetOutputMediaFloor(to: nearFutureNotBeforePTS ?? target)
            activeWarmVideoImageHold = nil
            enqueueVideoCandidatePackets(candidate)
            guard !videoPackets.isEmpty else {
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }

            isDecodingWarmVideoCandidate = true
            while !Task.isCancelled,
                  videoDecoderOpened,
                  suspendedVideoFault == nil,
                  warmVideoSubmissionsWithoutOutput
                    < Self.warmVideoNoOutputSubmissionLimit,
                  !videoPackets.isEmpty,
                  !warmVideoCandidateHasRequiredOutput(
                    disposition: candidateDisposition,
                    target: target
                  ) {
                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                    return abandonWarmVideoPreparation(run)
                }
                let packetCountBeforeDrain = videoPackets.count
                let frameCountBeforeDrain = pendingVideoFrames.count
                let residualCountBeforeDrain = residualVideoPackets.count
                let submissionsBeforeDrain = totalVideoPacketsSubmitted
                await drainVideoDecodeBurst(
                    generation: generation,
                    warmPreparationAttempt: attempt
                )
                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                    return abandonWarmVideoPreparation(run)
                }
                if recovery.needsForwardRescue(
                    observation: warmVideoPreparationLedger.observation,
                    epsilon: outputMediaFloorEpsilon
                ) { break }
                if videoPackets.count == packetCountBeforeDrain,
                   pendingVideoFrames.count == frameCountBeforeDrain,
                   residualVideoPackets.count == residualCountBeforeDrain,
                   totalVideoPacketsSubmitted == submissionsBeforeDrain {
                    break
                }
            }
            if let fault = suspendedVideoFault, !isLocallyRepairableWarmVideoFault(fault) {
                retireCurrentVideoDecoderWithoutWaiting()
                return finishWarmVideoPreparation(token: token, failure: .decoderPreparationExhausted)
            }
            let context = WarmVideoCandidateContext(
                attempt: attempt, candidate: candidate, authority: candidateAuthority,
                target: target, disposition: candidateDisposition,
                provenance: suspendedVideoGOPProvenance
                    ?? .suspendEdge(readGeneration: token.videoReadGeneration),
                fetchedBytes: forwardReceipt == nil
                    ? videoReadBytesDelta(since: token) : forwardFetchedBytes,
                chaseByteCount: forwardReceipt == nil ? candidateAuthority.byteCount : forwardChargedBytes,
                chargedContentTailPTS: candidateAuthority.endPTS,
                decoderIdentity: ObjectIdentifier(videoDecoder)
            )
            let completion = await completeWarmVideoCandidate(
                context, run: run, recovery: &recovery
            )
            if warmPreparationTransaction.currentRun?.id == run.id {
                isDecodingWarmVideoCandidate = false
                isCollectingWarmVideoRunUp = false
            }
            switch completion {
            case .prepared:
                return .prepared
            case .cancelled:
                return abandonWarmVideoPreparation(run)
            case .exhausted:
                return finishWarmVideoPreparation(token: token, failure: .decoderPreparationExhausted)
            case let .repair(rejected):
                guard repairIndex < Self.warmVideoDecoderRepairLimit else {
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(token: token, failure: .decoderPreparationExhausted)
                }
                rejectedCandidate = rejected.candidate
                rejectedCandidateAuthority = rejected.authority
                activeWarmVideoImageHold = nil
                warmVideoPreparationLedger.retireAttempt()
                continue
            }

        }

        retireCurrentVideoDecoderWithoutWaiting()
        return finishWarmVideoPreparation(
            token: token,
            failure: .decoderPreparationExhausted
        )
    }

    struct WarmVideoCandidateContext {
        let attempt: WarmVideoPreparationAttempt
        let candidate: [MediaPacket]
        let authority: MediaVideoContinuityCandidateAuthority
        let target: TimeInterval
        let disposition: WarmVideoCandidateDisposition
        let provenance: DemandVideoCandidateProvenance
        let fetchedBytes: Int
        let chaseByteCount: Int
        let chargedContentTailPTS: TimeInterval
        let decoderIdentity: ObjectIdentifier
    }

    enum WarmVideoCandidateCompletion {
        case prepared
        case repair(WarmVideoCandidateContext)
        case exhausted
        case cancelled
    }

    func warmVideoCandidateContextIsCurrent(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        requiresDecoderOpen: Bool = true
    ) -> Bool {
        warmVideoContinuationAuthorityIsCurrent(
            run: run, attempt: context.attempt, token: run.token,
            decoderIdentity: context.decoderIdentity, generation: context.attempt.engineGeneration,
            requiresDecoderOpen: requiresDecoderOpen
        ) && !videoDecoderWasRetired
    }

    enum WarmVideoCandidateStep {
        case finished(WarmVideoCandidateCompletion)
        case needsRescue
    }

    func completeWarmVideoCandidate(
        _ initial: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> WarmVideoCandidateCompletion {
        var context = initial
        while true {
            switch await evaluateWarmVideoCandidate(context, run: run, recovery: &recovery) {
            case .finished(let completion):
                return completion
            case .needsRescue:
                guard let rescued = await rescueWarmVideoCandidate(context, run: run, recovery: &recovery) else {
                    return warmVideoRescueFailure(context, run: run)
                }
                context = rescued
                guard await decodeWarmVideoCandidate(context, run: run, recovery: &recovery) else {
                    return .cancelled
                }
            }
        }
    }

    func warmVideoCandidateFailure(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun
    ) -> WarmVideoCandidateCompletion? {
        guard warmVideoRunHasTime(run),
              warmVideoCandidateContextIsCurrent(context, run: run, requiresDecoderOpen: false) else {
            return .cancelled
        }
        if let fault = suspendedVideoFault {
            return isLocallyRepairableWarmVideoFault(fault) ? .repair(context) : .exhausted
        }
        return videoDecoderOpened ? nil : .repair(context)
    }

    func warmVideoRescueFailure(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun
    ) -> WarmVideoCandidateCompletion {
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else { return .cancelled }
        if let fault = suspendedVideoFault, isLocallyRepairableWarmVideoFault(fault) {
            return .repair(context)
        }
        return .exhausted
    }

    func evaluateWarmVideoCandidate(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> WarmVideoCandidateStep {
        if let failure = warmVideoCandidateFailure(context, run: run) { return .finished(failure) }
        if recovery.needsForwardRescue(
            observation: warmVideoPreparationLedger.observation, epsilon: outputMediaFloorEpsilon
        ) { return .needsRescue }
        guard warmVideoCandidateHasRequiredOutput(disposition: context.disposition, target: context.target) else {
            return .finished(.repair(context))
        }
        var continuationRecovery: WarmVideoRecoveryPolicy? = recovery
        let outcome = await continueWarmVideoPreparationToMovingTarget(
            run: run, attempt: context.attempt, token: run.token,
            startTarget: context.target, disposition: context.disposition,
            initialCandidateTailPTS: context.authority.endPTS,
            initialCandidateAnchorPTS: context.authority.decodeAnchorTime,
            initialCandidateByteCount: context.chaseByteCount,
            decoderIdentity: context.decoderIdentity,
            generation: context.attempt.engineGeneration, recovery: &continuationRecovery,
            initialChargedContentTailPTS: context.chargedContentTailPTS
        )
        if let continuationRecovery { recovery = continuationRecovery }
        if let failure = warmVideoCandidateFailure(context, run: run) { return .finished(failure) }
        return warmVideoCandidateStep(outcome, context: context, run: run)
    }

    func warmVideoCandidateStep(
        _ outcome: WarmVideoMovingTargetContinuationOutcome,
        context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun
    ) -> WarmVideoCandidateStep {
        switch outcome {
        case let .covered(target, disposition, tail):
            isDecodingWarmVideoCandidate = false
            return .finished(commitWarmVideoCandidate(
                context, run: run, target: target, disposition: disposition, tail: tail
            ))
        case .needsForwardRescue:
            return .needsRescue
        case .retryLocal:
            return .finished(.repair(context))
        case .tailExpired:
            if case .nearFutureImageHold = context.disposition { return .finished(.repair(context)) }
            return .finished(.exhausted)
        case .exhausted:
            return .finished(.exhausted)
        case .cancelled:
            return .finished(.cancelled)
        }
    }

    func commitWarmVideoCandidate(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        target: TimeInterval,
        disposition: WarmVideoCandidateDisposition,
        tail: TimeInterval
    ) -> WarmVideoCandidateCompletion {
        guard warmVideoRunHasTime(run) else { return .cancelled }
        guard warmVideoCandidateContextIsCurrent(context, run: run) else { return .cancelled }
        let liveAudio = audioPresentationMediaTime
        guard liveAudio.isFinite else { return .exhausted }
        let commitTarget = max(target, max(liveAudio, outputMediaFloor))
        guard commitTarget.isFinite, suspendedVideoFault == nil,
              warmVideoCandidateHasRequiredOutput(disposition: disposition, target: commitTarget) else {
            return .exhausted
        }
        advanceOutputMediaFloor(to: commitTarget, reason: "warm-commit")
        if let notBefore = disposition.futureNotBeforePTS {
            activeWarmVideoImageHold = WarmVideoImageHoldSnapshot(
                runID: run.id, token: run.token, sessionGeneration: runtimeGeneration,
                engineGeneration: generation, ownerGeneration: activeOwnerGeneration,
                candidateAuthorityGeneration: context.authority.generation,
                candidateProvenance: context.provenance, notBeforePTS: notBefore,
                candidateTailPTS: tail, foregroundFetchBytes: context.fetchedBytes,
                rateRevision: playbackRateRevision, renderGeneration: nil,
                hasReachedAudioDueTime: false
            )
            guard let hold = activeWarmVideoImageHold,
                  commitTarget <= tail + Self.videoContinuityAnchorToleranceSeconds,
                  warmVideoImageHoldIsCurrent(hold, requiresActiveSuspendToken: true) else {
                activeWarmVideoImageHold = nil
                return .exhausted
            }
        }
        suspendedVideoFault = nil
        terminalVideoPreparationFailure = nil
        warmVideoPreparationLedger.retireAttempt()
        isVideoLanePreparedForForeground = true
        diagnostics.log(
            "[PathA][continuation] video prepared token=\(run.token.generation) " +
                "candidateMode=\(disposition.diagnosticName) " +
                "target=\(String(format: "%.3f", commitTarget)) " +
                "pending=\(pendingVideoFrames.count)"
        )
        return .prepared
    }

    func decodeWarmVideoCandidate(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> Bool {
        isDecodingWarmVideoCandidate = true
        while !Task.isCancelled, videoDecoderOpened, suspendedVideoFault == nil,
              warmVideoSubmissionsWithoutOutput < Self.warmVideoNoOutputSubmissionLimit,
              !videoPackets.isEmpty,
              !warmVideoCandidateHasRequiredOutput(disposition: context.disposition, target: context.target) {
            guard warmVideoRunHasTime(run), warmVideoCandidateContextIsCurrent(context, run: run) else { return false }
            let packets = videoPackets.count
            let frames = pendingVideoFrames.count
            let residual = residualVideoPackets.count
            let submissions = totalVideoPacketsSubmitted
            await drainVideoDecodeBurst(
                generation: context.attempt.engineGeneration, warmPreparationAttempt: context.attempt
            )
            guard warmVideoRunHasTime(run),
                  warmVideoCandidateContextIsCurrent(context, run: run, requiresDecoderOpen: false) else {
                return false
            }
            if recovery.needsForwardRescue(
                observation: warmVideoPreparationLedger.observation, epsilon: outputMediaFloorEpsilon
            ) { break }
            if videoPackets.count == packets, pendingVideoFrames.count == frames,
               residualVideoPackets.count == residual, totalVideoPacketsSubmitted == submissions { break }
        }
        return true
    }

    private func enqueueVideoCandidatePackets(_ candidate: [MediaPacket]) {
        var overflows = false
        for packet in candidate {
            if overflows || !enqueueVideoPacket(packet) {
                overflows = true
                residualVideoPackets.append(packet)
            }
        }
    }

    private func enqueueWarmVideoCandidate(_ candidate: [MediaPacket], target: TimeInterval) {
        clearVideoTrackQueues()
        advanceOutputMediaFloor(to: target, reason: "warm-rescue-input")
        activeWarmVideoImageHold = nil
        enqueueVideoCandidatePackets(candidate)
    }

    private func rescueWarmVideoCandidate(
        _ rejected: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> WarmVideoCandidateContext? {
        guard warmVideoRunHasTime(run), warmVideoCandidateContextIsCurrent(rejected, run: run),
              suspendedVideoFault == nil, recovery.claimRescue() else { return nil }
        isDecodingWarmVideoCandidate = false
        let previousDecode = decodeTask
        cancelVideoDecode(clearHandle: false)
        await previousDecode?.value
        guard warmVideoRunHasTime(run), warmVideoCandidateContextIsCurrent(rejected, run: run),
              suspendedVideoFault == nil else { return nil }
        decodeTask = nil
        packetRelay.reset()
        clearVideoTrackQueues()
        activeWarmVideoImageHold = nil
        clearSuspendedVideoGOP()
        let attemptTarget = audioPresentationMediaTime
        guard attemptTarget.isFinite, attemptTarget >= rejected.authority.anchorPTS else { return nil }
        warmVideoPreparationLedger.retireAttempt()
        let attempt = beginWarmVideoPreparationAttempt(run: run, target: attemptTarget)
        await videoDecoder.flush()
        guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
              ObjectIdentifier(videoDecoder) == rejected.decoderIdentity,
              videoDecoderOpened, !videoDecoderWasRetired, suspendedVideoFault == nil else { return nil }
        let target = audioPresentationMediaTime
        guard target.isFinite, target >= rejected.authority.anchorPTS else { return nil }
        let phaseStarted = ContinuousClock.now
        let phaseAllowance = min(warmVideoPreparationDeadline, recovery.remaining(at: phaseStarted))
        guard phaseAllowance > .zero else { return nil }
        return await selectRescuedWarmVideoCandidate(
            rejected, run: run, attempt: attempt, target: target,
            phase: (startedAt: phaseStarted, allowance: phaseAllowance)
        )
    }

    func selectRescuedWarmVideoCandidate(
        _ rejected: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        attempt: WarmVideoPreparationAttempt,
        target: TimeInterval,
        phase: (startedAt: ContinuousClock.Instant, allowance: Duration)
    ) async -> WarmVideoCandidateContext? {
        let rateRevision = playbackRateRevision
        do {
            resetCachedRunway(video: true, audio: false)
            let selected = try await demux.prepareForwardVideoContinuity(MediaVideoForwardRequest(
                target: target, playbackRate: Double(playbackRate), wallAllowance: phase.allowance,
                maximumCompressedBytes: Self.suspendedVideoGOPMaxBytes,
                maximumContentSpan: Self.suspendedVideoGOPMaxContentSeconds
            ))
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == rejected.decoderIdentity,
                  playbackRateRevision == rateRevision, videoDecoderOpened,
                  !videoDecoderWasRetired, suspendedVideoFault == nil,
                  phase.startedAt.duration(to: .now) < phase.allowance,
                  case .positioned(let receipt) = selected,
                  receipt.sampledTarget == target, receipt.anchorPTS > target,
                  receipt.anchorPTS > rejected.authority.anchorPTS else { return nil }
            isCollectingWarmVideoRunUp = true
            let collection = try await collectForwardVideoCandidate(
                receipt: receipt, run: run, phaseStarted: phase.startedAt,
                phaseAllowance: phase.allowance, attempt: attempt
            )
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == rejected.decoderIdentity,
                  playbackRateRevision == rateRevision, videoDecoderOpened,
                  !videoDecoderWasRetired, suspendedVideoFault == nil,
                  let candidate = suspendedVideoCandidate(at: target) else { return nil }
            isCollectingWarmVideoRunUp = false
            let disposition = classifyForwardVideoCandidate(candidate, receipt: receipt, target: target)
            guard disposition != .requiresPositioning else { return nil }
            let authority = recordWarmVideoCandidateAuthority(candidate)
            enqueueWarmVideoCandidate(candidate, target: disposition.futureNotBeforePTS ?? target)
            return WarmVideoCandidateContext(
                attempt: attempt, candidate: candidate, authority: authority, target: target,
                disposition: disposition, provenance: .forwardPositioned(receipt),
                fetchedBytes: collection.fetchedBytes, chaseByteCount: collection.chargedBytes,
                chargedContentTailPTS: authority.endPTS,
                decoderIdentity: rejected.decoderIdentity
            )
        } catch {
            _ = warmVideoRunHasTime(run)
            return nil
        }
    }

    func warmVideoContinuationAuthorityIsCurrent(
        run: WarmVideoPreparationRun?,
        attempt: WarmVideoPreparationAttempt?,
        token: DemandVideoSuspendToken,
        decoderIdentity: ObjectIdentifier,
        generation: Int,
        requiresDecoderOpen: Bool = true
    ) -> Bool {
        guard !Task.isCancelled,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration,
              generation == self.generation,
              ObjectIdentifier(videoDecoder) == decoderIdentity else {
            return false
        }
        guard !requiresDecoderOpen || videoDecoderOpened else { return false }
        if let run, let attempt {
            return warmPreparationTransaction.currentRun?.id == run.id
                && isCurrentWarmVideoPreparationAttempt(attempt)
        }
        return isVideoLaneWarmSuspended
    }

    enum WarmVideoMovingTargetContinuationOutcome {
        case covered(
            target: TimeInterval,
            disposition: WarmVideoCandidateDisposition,
            candidateTailPTS: TimeInterval
        )
        case retryLocal
        case needsForwardRescue
        case tailExpired
        case exhausted
        case cancelled
    }

    private func exhaustedByWarmChaseLimit(
        _ limit: String,
        measured: @autoclosure () -> String
    ) -> WarmVideoMovingTargetContinuationOutcome {
        diagnostics.log(
            "[PathA][continuation] warm chase exhausted limit=\(limit) \(measured())"
        )
        return .exhausted
    }

    func continueWarmVideoPreparationToMovingTarget(
        run: WarmVideoPreparationRun?,
        attempt: WarmVideoPreparationAttempt?,
        token: DemandVideoSuspendToken,
        startTarget: TimeInterval,
        disposition: WarmVideoCandidateDisposition,
        initialCandidateTailPTS: TimeInterval,
        initialCandidateAnchorPTS: TimeInterval,
        initialCandidateByteCount: Int,
        decoderIdentity: ObjectIdentifier,
        generation: Int,
        recovery: inout WarmVideoRecoveryPolicy?,
        initialChargedContentTailPTS: TimeInterval? = nil
    ) async -> WarmVideoMovingTargetContinuationOutcome {
        guard startTarget.isFinite,
              initialCandidateTailPTS.isFinite,
              initialCandidateAnchorPTS.isFinite,
              initialChargedContentTailPTS?.isFinite ?? true,
              initialCandidateByteCount >= 0,
              initialCandidateByteCount <= Self.suspendedVideoWindowMaxBytes else {
            return .exhausted
        }
        guard !Task.isCancelled,
              warmVideoContinuationAuthorityIsCurrent(
                  run: run,
                  attempt: attempt,
                  token: token,
                  decoderIdentity: decoderIdentity,
                  generation: generation
              ) else {
            return .cancelled
        }

        var currentTarget = startTarget
        var currentDisposition = disposition
        var candidateTailPTS = initialCandidateTailPTS
        var candidateByteCount = initialCandidateByteCount
        var chargedContentTailPTS = max(
            initialCandidateTailPTS, initialChargedContentTailPTS ?? initialCandidateTailPTS
        )
        var noProgressBatches = 0
        let startedAsNearFutureImageHold: Bool = {
            if case .nearFutureImageHold = disposition { return true }
            return false
        }()
        let continuationStarted = ContinuousClock.now

        var loggedReadBytesWouldExhaustHit = false
        defer {
            if loggedReadBytesWouldExhaustHit {
                diagnostics.log(
                    "[PathA][continuation] would-exhaust summary limit=readBytes " +
                        "final=\(videoReadBytesDelta(since: token)) " +
                        "cap=\(Self.suspendedVideoGOPMaxBytes)"
                )
            }
        }

        while !Task.isCancelled {
            if let run, !warmVideoRunHasTime(run) { return .cancelled }
            guard warmVideoContinuationAuthorityIsCurrent(
                run: run,
                attempt: attempt,
                token: token,
                decoderIdentity: decoderIdentity,
                generation: generation
            ) else {
                return .cancelled
            }

            if let run {
                guard warmVideoRunHasTime(run) else { return .cancelled }
                if recovery?.needsForwardRescue(
                    observation: warmVideoPreparationLedger.observation,
                    epsilon: outputMediaFloorEpsilon
                ) == true { return .needsForwardRescue }
            }
            guard run != nil || continuationStarted.duration(to: ContinuousClock.now)
                    < Self.warmVideoDirectWallLimit else {
                diagnostics.log(
                    "[PathA][continuation] moving target budget exhausted " +
                    "start=\(String(format: "%.3f", startTarget)) " +
                    "current=\(String(format: "%.3f", currentTarget))"
                )
                return .exhausted
            }

            let sampledAudioTarget = audioPresentationMediaTime
            guard sampledAudioTarget.isFinite else { return .exhausted }
            if sampledAudioTarget > currentTarget {
                currentTarget = sampledAudioTarget
            }
            advanceOutputMediaFloor(to: currentTarget, reason: "warm-moving-target")

            if let notBeforePTS = currentDisposition.futureNotBeforePTS,
               currentTarget + Self.videoContinuityAnchorToleranceSeconds
                    >= notBeforePTS {
                currentDisposition = .bracketingPreRoll
                activeWarmVideoImageHold = nil
            }

            let requiredTarget: TimeInterval
            requiredTarget = max(currentTarget, currentDisposition.futureNotBeforePTS ?? currentTarget)
            if warmVideoCandidateHasRequiredOutput(
                disposition: currentDisposition,
                target: requiredTarget
            ) {
                return .covered(
                    target: currentTarget,
                    disposition: currentDisposition,
                    candidateTailPTS: candidateTailPTS
                )
            }

            let packetsBefore = videoPackets.count
            let pendingBefore = pendingVideoFrames.count
            let residualBefore = residualVideoPackets.count
            let submittedBefore = totalVideoPacketsSubmitted
            var madeProgress = false
            if !videoPackets.isEmpty {
                await drainVideoDecodeBurst(
                    generation: generation,
                    warmPreparationAttempt: attempt
                )
                if let run, !warmVideoRunHasTime(run) { return .cancelled }
                guard warmVideoContinuationAuthorityIsCurrent(
                    run: run,
                    attempt: attempt,
                    token: token,
                    decoderIdentity: decoderIdentity,
                    generation: generation,
                    requiresDecoderOpen: false
                ) else {
                    return .cancelled
                }
                madeProgress = videoPackets.count != packetsBefore
                    || pendingVideoFrames.count != pendingBefore
                    || residualVideoPackets.count != residualBefore
                    || totalVideoPacketsSubmitted != submittedBefore
            } else {
                let readGeneration = beginVideoReadGeneration()
                let packets: [MediaPacket]
                do {
                    let diagnosticPumpStart = ContinuousClock.now
                    defer {
                        if warmDiagnosticAttemptIsCurrent(attempt) {
                            activeWarmDiagnostics?.demuxWaitTime += diagnosticPumpStart.duration(to: .now)
                            activeWarmDiagnostics?.pumps += 1
                        }
                    }
                    resetCachedRunway(video: true, audio: false)
                    if case .positionedFutureImageHold = currentDisposition {
                        return .exhausted
                    }
                    packets = try await demux.pump(
                        videoBudget: 1,
                        audioBudget: 0
                    )
                } catch {
                    if let run, !warmVideoRunHasTime(run) { return .cancelled }
                    guard warmVideoContinuationAuthorityIsCurrent(
                        run: run,
                        attempt: attempt,
                        token: token,
                        decoderIdentity: decoderIdentity,
                        generation: generation
                    ) else {
                        return .cancelled
                    }
                    diagnostics.log(
                        "[PathA][continuation] moving target pump failed " +
                        "start=\(String(format: "%.3f", startTarget)) " +
                        "current=\(String(format: "%.3f", currentTarget))"
                    )
                    return .exhausted
                }
                if let run, !warmVideoRunHasTime(run) { return .cancelled }
                guard warmVideoContinuationAuthorityIsCurrent(
                    run: run,
                    attempt: attempt,
                    token: token,
                    decoderIdentity: decoderIdentity,
                    generation: generation
                ) else {
                    return .cancelled
                }
                if packets.isEmpty {
                    let reachedEOF = await demux.isEOF
                    if let run, !warmVideoRunHasTime(run) { return .cancelled }
                guard warmVideoContinuationAuthorityIsCurrent(
                            run: run, attempt: attempt, token: token,
                            decoderIdentity: decoderIdentity, generation: generation
                          ) else { return .cancelled }
                    if reachedEOF { return .exhausted }
                } else {
                    madeProgress = true
                    ingest(
                        packets,
                        videoReadGeneration: readGeneration,
                        warmVideoProvenance: .positioned(
                            readGeneration: readGeneration
                        )
                    )
                    drainResidualPackets()
                    for packet in packets where packet.track == .video {
                        guard let packetEnd = finiteMediaIntervalEnd(
                            start: packet.pts,
                            duration: packet.duration
                        ) else { return .exhausted }
                        let (updatedByteCount, byteCountOverflowed) =
                            candidateByteCount.addingReportingOverflow(packet.data.count)
                        guard !byteCountOverflowed,
                              updatedByteCount <= Self.suspendedVideoGOPMaxBytes else {
                            return exhaustedByWarmChaseLimit(
                                "candidateBytes",
                                measured: "bytes=\(updatedByteCount) " +
                                    "cap=\(Self.suspendedVideoGOPMaxBytes) " +
                                    "overflow=\(byteCountOverflowed ? 1 : 0)"
                            )
                        }
                        candidateByteCount = updatedByteCount
                        candidateTailPTS = max(
                            candidateTailPTS,
                            packetEnd
                        )
                        chargedContentTailPTS = max(chargedContentTailPTS, packetEnd)
                        guard chargedContentTailPTS - initialCandidateAnchorPTS
                                <= Self.warmVideoDirectContentSpanLimit + 1e-9 else {
                            return exhaustedByWarmChaseLimit(
                                "contentSpan",
                                measured: "span=" + String(
                                    format: "%.3f",
                                    chargedContentTailPTS - initialCandidateAnchorPTS
                                ) + " cap=" + String(
                                    format: "%.3f",
                                    Self.warmVideoDirectContentSpanLimit
                                )
                            )
                        }
                    }
                }
            }

            let readBytesDelta = videoReadBytesDelta(since: token)
            if readBytesDelta > Self.suspendedVideoGOPMaxBytes,
               !loggedReadBytesWouldExhaustHit {
                loggedReadBytesWouldExhaustHit = true
                diagnostics.log(
                    "[PathA][continuation] would-exhaust limit=readBytes " +
                        "bytes=\(readBytesDelta) " +
                        "cap=\(Self.suspendedVideoGOPMaxBytes)"
                )
            }

            if let fault = suspendedVideoFault {
                return isLocallyRepairableWarmVideoFault(fault)
                    ? .retryLocal
                    : .exhausted
            }
            guard videoDecoderOpened else { return .exhausted }
            madeProgress = madeProgress
                || videoPackets.count != packetsBefore
                || pendingVideoFrames.count != pendingBefore
                || residualVideoPackets.count != residualBefore
                || totalVideoPacketsSubmitted != submittedBefore
            if !madeProgress {
                noProgressBatches += 1
            } else {
                noProgressBatches = 0
            }
            if warmVideoSubmissionsWithoutOutput
                    >= Self.warmVideoNoOutputSubmissionLimit {
                return .retryLocal
            }
            if noProgressBatches >= Self.warmVideoDirectNoProgressLimit {
                if startedAsNearFutureImageHold,
                   currentTarget
                        > candidateTailPTS
                            + Self.videoContinuityAnchorToleranceSeconds,
                   videoPackets.isEmpty {
                    diagnostics.log(
                        "[PathA][continuation] near-future tail expired " +
                        "target=\(String(format: "%.3f", currentTarget)) " +
                        "tail=\(String(format: "%.3f", candidateTailPTS))"
                    )
                    return .tailExpired
                }
                return .exhausted
            }
        }
        return Task.isCancelled ? .cancelled : .exhausted
    }

    func pendingVideoFrameEndPTS() -> TimeInterval? {
        var result: TimeInterval?
        for frame in pendingVideoFrames {
            guard frame.pts.isFinite, frame.duration.isFinite, frame.duration > 0 else { continue }
            let end = frame.pts + frame.duration
            guard end.isFinite else { continue }
            result = result.map { max($0, end) } ?? end
        }
        return result
    }

    func videoPacketEndPTS() -> TimeInterval? {
        var result: TimeInterval?
        for packet in videoPackets {
            guard packet.pts.isFinite, packet.duration.isFinite, packet.duration > 0 else { continue }
            let end = packet.pts + packet.duration
            guard end.isFinite else { continue }
            result = result.map { max($0, end) } ?? end
        }
        for packet in residualVideoPackets {
            guard packet.pts.isFinite, packet.duration.isFinite, packet.duration > 0 else { continue }
            let end = packet.pts + packet.duration
            guard end.isFinite else { continue }
            result = result.map { max($0, end) } ?? end
        }
        return result
    }

    func finiteMediaIntervalEnd(
        start: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard start.isFinite, duration.isFinite, duration >= 0 else {
            return nil
        }
        let end = start + duration
        return end.isFinite ? end : nil
    }

    struct ForwardVideoCollection {
        var chargedBytes = 0
        var fetchedBytes = 0
        var noProgressBatches = 0
    }

    func collectForwardVideoCandidate(
        receipt: MediaVideoForwardReceipt,
        run: WarmVideoPreparationRun,
        phaseStarted: ContinuousClock.Instant,
        phaseAllowance: Duration,
        attempt: WarmVideoPreparationAttempt? = nil
    ) async throws -> ForwardVideoCollection {
        var collection = ForwardVideoCollection(
            chargedBytes: receipt.selectionFetchBytes,
            fetchedBytes: receipt.selectionFetchBytes
        )
        let rateRevision = playbackRateRevision
        let decoderIdentity = ObjectIdentifier(videoDecoder)
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard warmVideoRunIsCurrent(run),
                  warmVideoForwardAttemptIsCurrent(attempt, decoderIdentity: decoderIdentity),
                  activeVideoSuspendToken == run.token,
                  playbackRateRevision == rateRevision,
                  Double(playbackRate) == receipt.playbackRate,
                  warmVideoRunHasTime(run),
                  phaseStarted.duration(to: .now) < phaseAllowance else {
                throw MediaEngineError.stopped
            }
            let readGeneration = beginVideoReadGeneration()
            let pumpStarted = ContinuousClock.now
            let outcome = try await demux.pumpPositionedVideoContinuity(
                readGeneration: readGeneration, contentBudget: 1
            )
            if warmPreparationAttemptIsActive(runID: run.id) {
                activeWarmDiagnostics?.demuxWaitTime += pumpStarted.duration(to: .now)
                activeWarmDiagnostics?.pumps += 1
            }
            try Task.checkCancellation()
            guard warmVideoRunIsCurrent(run),
                  warmVideoForwardAttemptIsCurrent(attempt, decoderIdentity: decoderIdentity),
                  activeVideoSuspendToken == run.token,
                  playbackRateRevision == rateRevision,
                  run.sessionGeneration == runtimeGeneration,
                  run.engineGeneration == generation,
                  run.ownerGeneration == activeOwnerGeneration,
                  warmVideoRunHasTime(run),
                  phaseStarted.duration(to: .now) < phaseAllowance,
                  case .supported(let batch) = outcome else { throw MediaEngineError.stopped }
            try acceptForwardVideoBatch(
                batch, receipt: receipt, readGeneration: readGeneration,
                collection: &collection
            )
            if batch.forwardReferenceExhausted {
                guard forwardCandidateHasDistinctPTS(suspendedVideoGOP) else { break }
                return collection
            }
            guard !batch.reachedEOF,
                  collection.noProgressBatches < Self.warmVideoDirectNoProgressLimit else { break }
        }
        throw MediaEngineError.demuxFailed("forward continuity has no bounded sync candidate")
    }

    func warmVideoForwardAttemptIsCurrent(
        _ attempt: WarmVideoPreparationAttempt?,
        decoderIdentity: ObjectIdentifier
    ) -> Bool {
        guard let attempt else { return true }
        return isCurrentWarmVideoPreparationAttempt(attempt) && videoDecoderOpened
            && !videoDecoderWasRetired && ObjectIdentifier(videoDecoder) == decoderIdentity
    }

    func acceptForwardVideoBatch(
        _ batch: MediaVideoContinuityBatch,
        receipt: MediaVideoForwardReceipt,
        readGeneration: UInt64,
        collection: inout ForwardVideoCollection
    ) throws {
        let charged = collection.chargedBytes.addingReportingOverflow(batch.compressedByteCount)
        let fetched = collection.fetchedBytes.addingReportingOverflow(batch.fetchedByteCount)
        guard batch.forwardReceipt == receipt,
              batch.readerMutationGeneration == receipt.readerMutationGeneration,
              batch.readGeneration == readGeneration,
              batch.compressedByteCount >= 0, batch.fetchedByteCount >= 0,
              !charged.overflow, !fetched.overflow,
              charged.partialValue <= Self.suspendedVideoGOPMaxBytes,
              batch.packets.allSatisfy({ packet in
                packet.track == .video && packet.pts.isFinite
                    && (packet.dts?.isFinite ?? true)
                    && packet.duration.isFinite && packet.duration >= 0
                    && packet.pts >= receipt.contentInterval.start - 1e-9
                    && packet.pts + packet.duration <= receipt.contentInterval.end + 1e-9
              }) else { throw MediaEngineError.demuxFailed("forward continuity receipt mismatch") }
        if suspendedVideoGOP.isEmpty, let first = batch.packets.first {
            guard first.isKeyframe, abs(first.pts - receipt.anchorPTS) <= 1e-9 else {
                throw MediaEngineError.demuxFailed("forward continuity lacks proven first sync sample")
            }
        }
        collection.chargedBytes = charged.partialValue
        collection.fetchedBytes = fetched.partialValue
        collection.noProgressBatches = batch.madeProgress ? 0 : collection.noProgressBatches + 1
        ingest(
            batch.packets, videoReadGeneration: readGeneration,
            warmVideoProvenance: .forwardPositioned(receipt)
        )
    }

    func forwardCandidateHasDistinctPTS(_ candidate: [MediaPacket]) -> Bool {
        guard let first = candidate.first, first.isKeyframe, first.pts.isFinite else { return false }
        return candidate.dropFirst().contains { $0.pts.isFinite && abs($0.pts - first.pts) > 1e-9 }
    }

    func classifyForwardVideoCandidate(
        _ candidate: [MediaPacket],
        receipt: MediaVideoForwardReceipt,
        target: TimeInterval
    ) -> WarmVideoCandidateDisposition {
        guard forwardCandidateHasDistinctPTS(candidate), let first = candidate.first,
              suspendedVideoGOPProvenance == .forwardPositioned(receipt),
              target.isFinite, receipt.anchorPTS.isFinite,
              abs(first.pts - receipt.anchorPTS) <= 1e-9,
              Double(playbackRate) == receipt.playbackRate else { return .requiresPositioning }
        if receipt.anchorPTS <= target + Self.videoContinuityAnchorToleranceSeconds {
            return .bracketingPreRoll
        }
        let lead = receipt.anchorPTS - audioPresentationMediaTime
        guard lead.isFinite, lead <= receipt.maximumLead,
              playbackRate > 0,
              lead / Double(playbackRate) <= Double(warmVideoPreparationDeadline / .seconds(1)) else {
            return .requiresPositioning
        }
        return .positionedFutureImageHold(receipt)
    }

    func performRenewedWarmVideoStreaming(
        run: WarmVideoPreparationRun,
        token: DemandVideoSuspendToken,
        target: TimeInterval,
        rejectedCandidate: [MediaPacket],
        rejectedCandidateAuthority: MediaVideoContinuityCandidateAuthority,
        generation: Int,
        started: ContinuousClock.Instant,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> DemandVideoLanePreparationResult {
        guard warmVideoRunHasTime(run), target.isFinite,
              !Task.isCancelled,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration,
              warmPreparationTransaction.currentRun?.id == run.id else {
            return cancelRenewedWarmVideoPreparation(run: run)
        }

        let attempt = beginWarmVideoPreparationAttempt(run: run, target: target)
        suspendedVideoFault = nil
        terminalVideoPreparationFailure = nil
        activeWarmVideoImageHold = nil
        isCollectingWarmVideoRunUp = false
        clearVideoTrackQueues()
        resetCachedRunway(video: true, audio: false)
        packetRelay.reset()
        guard installFreshVideoDecoder(retiringCurrent: true, warmPreparationAttempt: attempt) else {
            return failRenewedWarmVideoPreparation(token: token)
        }
        guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
            return cancelRenewedWarmVideoPreparation(run: run)
        }
        guard started.duration(to: ContinuousClock.now)
                < Self.warmVideoDirectWallLimit else {
            return failRenewedWarmVideoPreparation(token: token)
        }
        await openVideoDecoderIfNeeded(
            expectedGeneration: attempt.engineGeneration,
            warmPreparationAttempt: attempt
        )
        guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
            return cancelRenewedWarmVideoPreparation(run: run)
        }
        guard videoDecoderOpened else { return failRenewedWarmVideoPreparation(token: token) }
        guard started.duration(to: ContinuousClock.now)
                < Self.warmVideoDirectWallLimit else {
            return failRenewedWarmVideoPreparation(token: token)
        }

        let decoderIdentity = ObjectIdentifier(videoDecoder)
        resetOutputMediaFloor(to: target)
        isDecodingWarmVideoCandidate = true
        var directPacketCount = 0
        var directCompressedPacketBytes = 0
        var directAnchorPTS: TimeInterval?
        var directFirstDTS: TimeInterval?
        var directContentStartPTS: TimeInterval?
        var directEndPTS = -TimeInterval.infinity
        var directStartsWithSyncSample = false
        var directCandidateMatchesRejected = true
        var positionedReaderGeneration: UInt64?
        var compressedBytes = 0
        var noProgressBatches = 0
        while true {
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return cancelRenewedWarmVideoPreparation(run: run)
            }
            guard started.duration(to: ContinuousClock.now)
                    < Self.warmVideoDirectWallLimit else {
                return failRenewedWarmVideoPreparation(token: token)
            }

            let readGeneration = beginVideoReadGeneration()
            let batchOutcome: MediaVideoContinuityBatchOutcome
            do {
                let diagnosticPumpStart = ContinuousClock.now
                defer {
                    if warmDiagnosticAttemptIsCurrent(attempt) {
                        activeWarmDiagnostics?.demuxWaitTime += diagnosticPumpStart.duration(to: .now)
                        activeWarmDiagnostics?.pumps += 1
                    }
                }
                resetCachedRunway(video: true, audio: false)
                batchOutcome = try await demux.pumpPositionedVideoContinuity(
                    readGeneration: readGeneration,
                    contentBudget: 1
                )
            } catch {
                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                      ObjectIdentifier(videoDecoder) == decoderIdentity else {
                    return cancelRenewedWarmVideoPreparation(run: run)
                }
                diagnostics.log(
                    "[PathA][continuation] direct positioned stream failed " +
                    "error=\(error.localizedDescription)"
                )
                return failRenewedWarmVideoPreparation(token: token)
            }
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return cancelRenewedWarmVideoPreparation(run: run)
            }

            switch batchOutcome {
            case .unsupported(let reason):
                diagnostics.log(
                    "[PathA][continuation] direct positioned stream unsupported " +
                    "reason=\(reason.rawValue)"
                )
                return failRenewedWarmVideoPreparation(token: token)

            case .supported(let batch):
                guard batch.readGeneration == readGeneration,
                      batch.compressedByteCount >= 0 else {
                    return failRenewedWarmVideoPreparation(token: token)
                }
                if let positionedReaderGeneration {
                    guard positionedReaderGeneration == batch.readerMutationGeneration else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                } else {
                    positionedReaderGeneration = batch.readerMutationGeneration
                }

                let (updatedBytes, bytesOverflowed) = compressedBytes
                    .addingReportingOverflow(batch.compressedByteCount)
                guard !bytesOverflowed,
                      updatedBytes <= Self.suspendedVideoGOPMaxBytes else {
                    diagnostics.log(
                        "[PathA][continuation] direct positioned byte budget exhausted " +
                        "bytes=\(updatedBytes)"
                    )
                    return failRenewedWarmVideoPreparation(token: token)
                }
                compressedBytes = updatedBytes

                if let interval = batch.contentInterval {
                    guard interval.start.isFinite,
                          interval.end.isFinite,
                          interval.end >= interval.start else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    directContentStartPTS = directContentStartPTS ?? interval.start
                }
                if let frontier = batch.contentFrontier {
                    guard frontier.isFinite else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                }

                if !batch.packets.isEmpty {
                    guard batch.packets.allSatisfy({ packet in
                        packet.track == .video
                            && packet.pts.isFinite
                            && packet.duration.isFinite
                            && packet.duration >= 0
                    }) else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    let (batchPacketBytes, packetBytesOverflowed) = batch.packets.reduce(
                        into: (total: 0, overflowed: false)
                    ) { result, packet in
                        guard !result.overflowed else { return }
                        let (updated, overflowed) = result.total.addingReportingOverflow(
                            packet.data.count
                        )
                        result.total = updated
                        result.overflowed = overflowed
                    }
                    guard !packetBytesOverflowed,
                          batchPacketBytes <= batch.compressedByteCount else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    if directPacketCount == 0 {
                        guard let first = batch.packets.first else {
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        let firstAnchor = first.dts?.isFinite == true
                            ? first.dts!
                            : first.pts
                        guard first.isKeyframe,
                              firstAnchor.isFinite,
                              firstAnchor
                                <= target + Self.videoContinuityAnchorToleranceSeconds else {
                            diagnostics.log(
                                "[PathA][continuation] direct sequence lacks sync root"
                            )
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        directAnchorPTS = first.pts
                        directFirstDTS = first.dts?.isFinite == true
                            ? first.dts
                            : nil
                        directStartsWithSyncSample = first.isKeyframe
                    }
                    for packet in batch.packets {
                        guard let packetEnd = finiteMediaIntervalEnd(
                            start: packet.pts,
                            duration: packet.duration
                        ) else {
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        if directCandidateMatchesRejected {
                            if directPacketCount >= rejectedCandidate.count {
                                directCandidateMatchesRejected = false
                            } else if !sameCompressedPacket(
                                packet,
                                rejectedCandidate[directPacketCount]
                            ) {
                                directCandidateMatchesRejected = false
                            }
                        }
                        directPacketCount += 1
                        let (updatedPacketBytes, packetBytesOverflowed) =
                            directCompressedPacketBytes.addingReportingOverflow(
                                packet.data.count
                            )
                        guard !packetBytesOverflowed else {
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        directCompressedPacketBytes = updatedPacketBytes
                        directEndPTS = max(
                            directEndPTS,
                            packetEnd
                        )
                    }
                    ingest(
                        batch.packets,
                        videoReadGeneration: readGeneration,
                        warmVideoProvenance: .positioned(
                            readGeneration: readGeneration
                        )
                    )
                    drainResidualPackets()
                }

                let contentFrontier = max(
                    batch.contentFrontier
                        ?? batch.contentInterval?.end
                        ?? -TimeInterval.infinity,
                    directEndPTS
                )
                if let firstAnchor = directFirstDTS
                    ?? directAnchorPTS
                    ?? directContentStartPTS,
                   contentFrontier.isFinite {
                    guard contentFrontier >= firstAnchor,
                          contentFrontier - firstAnchor
                            <= Self.warmVideoDirectContentSpanLimit + 1e-9 else {
                        diagnostics.log(
                            "[PathA][continuation] direct positioned content budget exhausted " +
                            "span=\(String(format: "%.3f", contentFrontier - firstAnchor))"
                        )
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                }

                while !videoPackets.isEmpty,
                      !warmVideoCandidateHasRequiredOutput(
                        disposition: .requiresPositioning,
                        target: target
                      ) {
                    let packetsBefore = videoPackets.count
                    let framesBefore = pendingVideoFrames.count
                    let residualBefore = residualVideoPackets.count
                    let submittedBefore = totalVideoPacketsSubmitted
                    await drainVideoDecodeBurst(
                        generation: generation,
                        warmPreparationAttempt: attempt
                    )
                    guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                          ObjectIdentifier(videoDecoder) == decoderIdentity else {
                        return cancelRenewedWarmVideoPreparation(run: run)
                    }
                    drainResidualPackets()
                    _ = recovery.needsForwardRescue(
                        observation: warmVideoPreparationLedger.observation,
                        epsilon: outputMediaFloorEpsilon
                    )
                    if videoPackets.count == packetsBefore,
                       pendingVideoFrames.count == framesBefore,
                       residualVideoPackets.count == residualBefore,
                       totalVideoPacketsSubmitted == submittedBefore {
                        break
                    }
                }

                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                      ObjectIdentifier(videoDecoder) == decoderIdentity else {
                    return cancelRenewedWarmVideoPreparation(run: run)
                }
                if suspendedVideoFault != nil || !videoDecoderOpened {
                    return failRenewedWarmVideoPreparation(token: token)
                }
                if warmVideoCandidateHasRequiredOutput(
                    disposition: .requiresPositioning,
                    target: target
                ) {
                    guard started.duration(to: ContinuousClock.now)
                            < Self.warmVideoDirectWallLimit else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    let authority = recordWarmVideoCandidateAuthority(
                        anchorPTS: directAnchorPTS ?? 0,
                        firstDTS: directFirstDTS,
                        endPTS: directEndPTS,
                        packetCount: directPacketCount,
                        byteCount: directCompressedPacketBytes,
                        startsWithSyncSample: directStartsWithSyncSample
                    )
                    let isDistinct = !directCandidateMatchesRejected
                        || directPacketCount != rejectedCandidate.count
                    let isEarlier = authority.decodeAnchorTime
                        < rejectedCandidateAuthority.decodeAnchorTime - 1e-6
                    guard authority.startsWithSyncSample,
                          authority.decodeAnchorTime
                            <= target + Self.videoContinuityAnchorToleranceSeconds,
                          isEarlier,
                          isDistinct else {
                        diagnostics.log(
                            "[PathA][continuation] direct renewed candidate rejected " +
                            "sync=\(authority.startsWithSyncSample ? 1 : 0) " +
                            "earlier=\(isEarlier ? 1 : 0) " +
                            "distinct=\(isDistinct ? 1 : 0)"
                        )
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    let context = WarmVideoCandidateContext(
                        attempt: attempt, candidate: [], authority: authority, target: target,
                        disposition: .bracketingPreRoll,
                        provenance: .positioned(readGeneration: readGeneration),
                        fetchedBytes: videoReadBytesDelta(since: token),
                        chaseByteCount: compressedBytes, chargedContentTailPTS: contentFrontier,
                        decoderIdentity: decoderIdentity
                    )
                    switch await completeWarmVideoCandidate(context, run: run, recovery: &recovery) {
                    case .prepared:
                        return .prepared
                    case .cancelled:
                        return cancelRenewedWarmVideoPreparation(run: run)
                    case .repair, .exhausted:
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                }

                guard !batch.reachedEOF else {
                    return failRenewedWarmVideoPreparation(token: token)
                }
                noProgressBatches = batch.madeProgress ? 0 : noProgressBatches + 1
                guard noProgressBatches < Self.warmVideoDirectNoProgressLimit else {
                    diagnostics.log(
                        "[PathA][continuation] direct positioned no-progress budget exhausted"
                    )
                    return failRenewedWarmVideoPreparation(token: token)
                }
            }
        }
    }

    func failRenewedWarmVideoPreparation(
        token: DemandVideoSuspendToken
    ) -> DemandVideoLanePreparationResult {
        isDecodingWarmVideoCandidate = false
        isCollectingWarmVideoRunUp = false
        warmVideoPreparationLedger.retireAttempt()
        activeWarmVideoImageHold = nil
        retireCurrentVideoDecoderWithoutWaiting()
        return finishWarmVideoPreparation(
            token: token,
            failure: .decoderPreparationExhausted
        )
    }

    func cancelRenewedWarmVideoPreparation(
        run: WarmVideoPreparationRun
    ) -> DemandVideoLanePreparationResult {
        guard warmPreparationTransaction.currentRun == run,
              activeVideoSuspendToken == run.token,
              runtimeGeneration == run.sessionGeneration,
              generation == run.engineGeneration,
              activeOwnerGeneration == run.ownerGeneration else { return .cancelled }
        isDecodingWarmVideoCandidate = false
        isCollectingWarmVideoRunUp = false
        warmVideoPreparationLedger.retireAttempt()
        activeWarmVideoImageHold = nil
        retireCurrentVideoDecoderWithoutWaiting()
        return abandonWarmVideoPreparation(run)
    }

    func preparedVideoLaneCoversCurrentAudio() -> Bool {
        let target = audioPresentationMediaTime
        guard target.isFinite else { return true }
        guard target + outputMediaFloorEpsilon >= outputMediaFloor else { return false }
        var upperBound: TimeInterval?
        for frame in pendingVideoFrames {
            let end = frame.pts + max(0, frame.duration)
            upperBound = upperBound.map { max($0, end) } ?? end
        }
        for packet in videoPackets {
            let end = packet.pts + max(0, packet.duration)
            upperBound = upperBound.map { max($0, end) } ?? end
        }
        guard let upperBound, upperBound.isFinite else {
            return true
        }
        return target <= upperBound
    }

    func abandonWarmVideoPreparation(
        _ run: WarmVideoPreparationRun
    ) -> DemandVideoLanePreparationResult {
        let supersededByRun = warmPreparationTransaction.currentRun.map { $0.id != run.id } ?? true
        let supersededBySuspension = activeVideoSuspendToken != run.token
        let supersededBySession = runtimeGeneration != run.sessionGeneration
            || generation != run.engineGeneration
        let supersededByOwner = activeOwnerGeneration != run.ownerGeneration
        let cancelled = Task.isCancelled
        if supersededByRun || supersededBySuspension || supersededBySession
            || supersededByOwner || cancelled {
            return .cancelled
        }
        diagnostics.log(
            "[PathA][continuation] INVARIANT: prepare abandoned with no " +
            "successor run=\(run.id) token=\(run.token.generation) — " +
            "settling typed failure instead of parking the lane"
        )
        return finishWarmVideoPreparation(token: run.token, failure: .staleAuthority)
    }

    func beginWarmVideoPreparationAttempt(
        run: WarmVideoPreparationRun,
        target: TimeInterval
    ) -> WarmVideoPreparationAttempt {
        let attempt = warmVideoPreparationLedger.beginAttempt(.init(
            runID: run.id,
            token: run.token,
            sessionGeneration: runtimeGeneration,
            engineGeneration: generation,
            ownerGeneration: activeOwnerGeneration,
            target: target
        ))
        if activeWarmDiagnostics?.runID == run.id {
            activeWarmDiagnostics?.attemptID = attempt.id
        }
        warmVideoSubmissionsWithoutOutput = 0
        return attempt
    }

    func isCurrentWarmVideoPreparationAttempt(
        _ attempt: WarmVideoPreparationAttempt
    ) -> Bool {
        warmVideoPreparationLedger.currentAttempt == attempt
            && !Task.isCancelled
            && warmPreparationTransaction.currentRun?.id == attempt.runID
            && activeVideoSuspendToken == attempt.token
            && runtimeGeneration == attempt.sessionGeneration
            && generation == attempt.engineGeneration
            && activeOwnerGeneration == attempt.ownerGeneration
            && isVideoLaneWarmSuspended
            && isPreparingWarmVideoLane
    }

    func isLocallyRepairableWarmVideoFault(_ fault: MediaRuntimeFault) -> Bool {
        guard fault.subsystem == .videoDecoder else { return false }
        switch fault.classification {
        case .invalidSession, .malfunction, .badData, .unsupportedFormat:
            return true
        case .input, .silentNoOutput, .unknown:
            return false
        }
    }

    func finishWarmVideoPreparation(
        token: DemandVideoSuspendToken,
        failure: DemandPresentationFailure
    ) -> DemandVideoLanePreparationResult {
        guard !Task.isCancelled,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration else {
            return .cancelled
        }
        warmVideoPreparationLedger.retireAttempt()
        activeWarmVideoImageHold = nil
        isVideoLanePreparedForForeground = false
        terminalVideoPreparationFailure = failure
        diagnostics.log(
            "[PathA][continuation] video preparation terminal " +
            "token=\(token.generation) failure=\(failure.rawValue)"
        )
        return .failed(failure)
    }
}
