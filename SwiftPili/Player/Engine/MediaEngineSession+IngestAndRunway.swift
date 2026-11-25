import CoreVideo
import Foundation

extension MediaEngineSession {
    var bufferedTime: TimeInterval {
        resolvedBufferEndpoints(at: clock.mediaTime).bufferedThrough ?? clock.mediaTime
    }

    var bufferDisplaySample: MediaBufferDisplaySample? {
        let time = clock.mediaTime
        guard time.isFinite else { return nil }
        let resolved = resolvedBufferEndpoints(at: time)
        return MediaBufferDisplaySample(
            position: time,
            videoPresent: videoDecoderOpened,
            audioPresent: hasAudioTrack,
            videoWarmSuspended: isVideoLaneWarmSuspended,
            videoEnd: resolved.videoEnd,
            audioEnd: resolved.audioEnd,
            bufferedThrough: resolved.bufferedThrough
        )
    }

    var tracksDrainedAtEOF: Bool {
        guard demuxReachedEOF else { return false }
        let videoDrained = !videoDecoderOpened || isVideoLaneWarmSuspended || (
            videoPacketQueue.contentSeconds <= 0
                && pendingVideoContentSeconds <= 0
                && cachedVideoRunwaySeconds <= 0
        )
        let audioDrained = !hasAudioTrack || (
            audioPacketQueue.contentSeconds <= 0
                && pendingAudioContentSeconds <= 0
                && cachedAudioRunwaySeconds <= 0
        )
        return videoDrained && audioDrained
    }

    func resolvedBufferEndpoints(at time: TimeInterval) -> (
        videoEnd: TimeInterval?,
        audioEnd: TimeInterval?,
        bufferedThrough: TimeInterval?
    ) {
        guard time.isFinite else { return (nil, nil, nil) }
        var videoEnd = videoDeliveryRunway.map { time + $0 }
        var audioEnd = audioDeliveryRunway.map { time + $0 }
        let duration = clock.duration
        let hasFiniteDuration = duration.isFinite && duration > 0
        if demuxReachedEOF, hasFiniteDuration {
            if videoDecoderOpened, !isVideoLaneWarmSuspended,
               videoPacketQueue.contentSeconds <= 0,
               pendingVideoContentSeconds <= 0,
               cachedVideoRunwaySeconds <= 0,
               videoRender.enqueuedAheadSeconds(from: time) <= 0 {
                videoEnd = max(time, duration)
            }
            if hasAudioTrack,
               audioPacketQueue.contentSeconds <= 0,
               pendingAudioContentSeconds <= 0,
               cachedAudioRunwaySeconds <= 0,
               audioRender.ringBufferedSeconds <= 0 {
                audioEnd = max(time, duration)
            }
        }
        if hasFiniteDuration {
            videoEnd = videoEnd.map { min($0, duration) }
            audioEnd = audioEnd.map { min($0, duration) }
        }
        var bufferedThrough = bindingDeliveryRunway(video: videoEnd, audio: audioEnd)
        if demuxReachedEOF, hasFiniteDuration, tracksDrainedAtEOF {
            bufferedThrough = max(bufferedThrough ?? time, duration)
        }
        if let through = bufferedThrough, hasFiniteDuration {
            bufferedThrough = min(through, duration)
        }
        return (videoEnd, audioEnd, bufferedThrough)
    }

    // MARK: - Delivery runway

    var videoDeliveryRunway: TimeInterval? {
        guard let queued = queuedVideoRunway else { return nil }
        if isVideoLaneWarmSuspended { return queued }
        return queued + cachedVideoRunwaySeconds
    }

    var audioDeliveryRunway: TimeInterval? {
        guard let queued = queuedAudioRunway else { return nil }
        return queued + cachedAudioRunwaySeconds
    }

    var queuedVideoRunway: TimeInterval? {
        guard videoDecoderOpened else { return nil }
        if isVideoLaneWarmSuspended { return suspendedVideoRunway }
        let enqueuedAhead = videoRender.enqueuedAheadSeconds(from: clock.mediaTime)
        return max(0, enqueuedAhead + videoPacketQueue.contentSeconds + pendingVideoContentSeconds)
    }

    var queuedAudioRunway: TimeInterval? {
        guard hasAudioTrack else { return nil }
        return max(
            0,
            audioRender.ringBufferedSeconds + audioPacketQueue.contentSeconds + pendingAudioContentSeconds
        )
    }

    var pipelineRunway: TimeInterval? {
        bindingDeliveryRunway(video: queuedVideoRunway, audio: queuedAudioRunway)
    }

    var admitsSourceWaitBudget: Bool {
        hasMultiConnectionHelpers && isReady && isPlaying && !isBuffering
            && !isSeekInFlight && !isVideoLaneWarmSuspended
            && !isPreparingWarmVideoLane && !warmVideoImageHoldWithholdsVideoSupply
            && warmPreparationTransaction.orphan == nil
            && playbackRate.isFinite && playbackRate > 0
    }

    func invalidateSourceWaitBudget() {
        activeSourceWaitBudget?.cancel()
        activeSourceWaitBudget = nil
        sourceObservationEpoch &+= 1
        if sourceObservationEpoch == 0 { sourceObservationEpoch = 1 }
    }

    func usefulPrimaryLatency(at now: TimeInterval) -> TimeInterval {
        usefulPrimarySamples[.video]?.removeAll { now - $0.acceptedAt > 30 }
        usefulPrimarySamples[.audio]?.removeAll { now - $0.acceptedAt > 30 }
        var maxElapsed: TimeInterval = 0
        if let videoSamples = usefulPrimarySamples[.video] {
            for sample in videoSamples where sample.elapsed > maxElapsed {
                maxElapsed = sample.elapsed
            }
        }
        if hasAudioTrack, let audioSamples = usefulPrimarySamples[.audio] {
            for sample in audioSamples where sample.elapsed > maxElapsed {
                maxElapsed = sample.elapsed
            }
        }
        return maxElapsed
    }

    func beginSourceWaitBudget() -> MediaSourceWaitBudget? {
        guard admitsSourceWaitBudget, let reserve = pipelineRunway,
              reserve.isFinite, reserve >= 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let budget = MediaSourceWaitBudget(
            reserve: reserve, rate: playbackRate,
            sampledAt: now, usefulLatency: usefulPrimaryLatency(at: now),
            observationEpoch: sourceObservationEpoch
        )
        activeSourceWaitBudget = budget
        return budget
    }

    func noteAcceptedPrimaryObservation(_ packet: MediaPacket) {
        guard admitsSourceWaitBudget, let observation = packet.sourcePrimaryObservation,
              observation.track == packet.track,
              observation.observationEpoch == sourceObservationEpoch else { return }
        unresolvedPrimaryTransportFailure = nil
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - observation.issuedAt
        guard elapsed.isFinite, elapsed >= 0 else { return }
        var samples = usefulPrimarySamples[packet.track] ?? []
        samples.removeAll { now - $0.acceptedAt > 30 }
        guard !samples.contains(where: { $0.acceptedAU.observation.issueID == observation.issueID }) else { return }
        let acceptedAU = MediaSourceAcceptedAU(
            observation: observation, pts: packet.pts, payloadBytes: packet.data.count
        )
        samples.append(UsefulPrimarySample(acceptedAU: acceptedAU, acceptedAt: now, elapsed: elapsed))
        usefulPrimarySamples[packet.track] = Array(samples.suffix(8))
    }

    // MARK: - Cached runway

    var cachedVideoRunwaySeconds: TimeInterval { cachedVideoRunway.seconds }
    var cachedAudioRunwaySeconds: TimeInterval { cachedAudioRunway.seconds }

    func resetCachedRunway() {
        resetCachedRunway(video: true, audio: true)
    }

    func resetCachedRunway(video: Bool, audio: Bool) {
        cachedRunwayEpoch &+= 1
        if video { cachedVideoRunway = .empty }
        if audio { cachedAudioRunway = .empty }
    }

    func refreshCachedRunway(generation gen: Int) async {
        guard demux.measuresCachedContentAhead else { return }
        let epoch = cachedRunwayEpoch
        let ahead = await demux.cachedContentAhead()
        guard isCurrentGeneration(gen), epoch == cachedRunwayEpoch else { return }
        cachedVideoRunway = ahead.video
        cachedAudioRunway = ahead.audio
    }

    func cancelPausedRunwayRefresh() {
        activePausedRunwayRefreshID = nil
        pausedRunwayRefreshTask?.cancel()
        pausedRunwayRefreshTask = nil
    }

    func isPausedPrefetchQuiet(_ telemetry: MultiConnectionTelemetry) -> Bool {
        if !hasMultiConnectionHelpers || demuxReachedEOF { return true }
        return telemetry.activeRequests == 0
            && telemetry.state != .downloading
            && telemetry.state != .pending
    }

    func startPausedRunwayRefreshIfNeeded() {
        guard isReady, !isPlaying, !hasEmittedEnded,
              !isSeekInFlight, demux.measuresCachedContentAhead else {
            cancelPausedRunwayRefresh()
            return
        }
        guard pausedRunwayRefreshTask == nil else { return }
        let gen = generation
        nextPausedRunwayRefreshID &+= 1
        let taskID = nextPausedRunwayRefreshID
        activePausedRunwayRefreshID = taskID
        pausedRunwayRefreshTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.activePausedRunwayRefreshID == taskID {
                    self.activePausedRunwayRefreshID = nil
                    self.pausedRunwayRefreshTask = nil
                }
            }
            guard let self else { return }
            var lastBuffered = self.bufferedTime
            var stagnantQuietCount = 0
            while !Task.isCancelled,
                  self.isCurrentGeneration(gen),
                  self.activePausedRunwayRefreshID == taskID,
                  self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                  !self.isSeekInFlight {
                do {
                    try await Task.sleep(for: .milliseconds(255))
                } catch {
                    break
                }
                guard !Task.isCancelled,
                      self.isCurrentGeneration(gen),
                      self.activePausedRunwayRefreshID == taskID,
                      self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                      !self.isSeekInFlight else { break }

                let telemetry = await self.demux.multiConnectionTelemetry()
                guard !Task.isCancelled,
                      self.isCurrentGeneration(gen),
                      self.activePausedRunwayRefreshID == taskID,
                      self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                      !self.isSeekInFlight else { break }

                await self.refreshCachedRunway(generation: gen)
                guard !Task.isCancelled,
                      self.isCurrentGeneration(gen),
                      self.activePausedRunwayRefreshID == taskID,
                      self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                      !self.isSeekInFlight else { break }

                let currentBuffered = self.bufferedTime
                if abs(currentBuffered - lastBuffered) > 0.005 {
                    lastBuffered = currentBuffered
                    stagnantQuietCount = 0
                    self.onEvent?(.buffered(currentBuffered))
                } else if self.isPausedPrefetchQuiet(telemetry) {
                    stagnantQuietCount += 1
                    if stagnantQuietCount >= 2 { break }
                } else {
                    stagnantQuietCount = 0
                }
            }
        }
    }

    var deliveryRunway: TimeInterval? {
        bindingDeliveryRunway(video: videoDeliveryRunway, audio: audioDeliveryRunway)
    }

    var videoPacketBufferSeconds: TimeInterval { videoPacketQueue.contentSeconds }
    var audioPacketBufferSeconds: TimeInterval { audioPacketQueue.contentSeconds }
    var videoPacketCount: Int { videoPackets.count }
    var audioPacketCount: Int { audioPackets.count }

    var pendingAudioContentSeconds: TimeInterval {
        audioTimelineBuffer.contentSeconds
    }

    func refreshMultiConnectionTelemetry() {
        guard hasMultiConnectionHelpers, isReady, !hasEmittedEnded,
              !multiConnectionQuietGate.isParked else { return }
        let cached = helperTelemetry.value
        guard !(multiConnectionQuietGate.isQuiet && cached.identity != nil && cached.activeRequests == 0),
              cached.state != .unavailable, cached.state != .suppressed,
              cached.state != .unsupported else { return }
        helperTelemetry.request(generation: generation, currentGeneration: { [weak self] in
            self?.generation ?? Int.max
        }, query: { [demux] in await demux.multiConnectionTelemetry() })
    }

    func setMultiConnectionQuiet(_ quiet: MultiConnectionQuiet) {
        multiConnectionQuiet = quiet.isQuiet
        multiConnectionQuietGate.setQuiet(quiet)
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(gen) else { return }
            await self.demux.setMultiConnectionQuiet(self.multiConnectionQuiet)
        }
    }

    func cancelMultiConnectionPrefetching() async {
        hasMultiConnectionHelpers = false
        lastMultiConnectionPlaybackPosition = nil
        helperTelemetry.invalidate(.suppressed)
        await demux.cancelMultiConnectionPrefetching()
    }

    func updateMultiConnectionPlayback() {
        guard hasMultiConnectionHelpers else { return }
        lastMultiConnectionPlaybackPosition = mediaTime
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(gen) else { return }
            await self.demux.updateMultiConnectionPlayback(
                position: self.mediaTime, rate: self.playbackRate
            )
        }
    }

    func notifyMultiConnectionPlaybackProgressIfNeeded() {
        guard hasMultiConnectionHelpers, isPlaying, !hasEmittedEnded,
              !multiConnectionQuietGate.isParked else { return }
        let current = clock.mediaTime
        guard current.isFinite else { return }
        if let last = lastMultiConnectionPlaybackPosition, abs(current - last) < 1.0 { return }
        updateMultiConnectionPlayback()
    }

    func clearPacketBuffers() {
        videoPackets = []
        audioPackets = []
        residualVideoPackets = []
        residualAudioPackets = []
        videoPacketQueue.reset()
        audioPacketQueue.reset()
        packetRelay.reset()
        resetCachedRunway()
        videoStarvedSince = nil
        bufferingForVideoStarvation = false
    }

    func beginVideoReadGeneration() -> UInt64 {
        if nextVideoReadGeneration < .max {
            nextVideoReadGeneration += 1
        }
        return nextVideoReadGeneration
    }

    func videoReadBytesDelta(
        since token: DemandVideoSuspendToken
    ) -> Int {
        let (delta, overflowed) = videoReadBytes
            .subtractingReportingOverflow(token.videoReadBytesAtSuspend)
        guard !overflowed else { return .max }
        return max(0, delta)
    }

    func queueFillDiagnosticSnapshot() -> MediaQueueFillSnapshot {
        let nativeAudio = audioRender as? EngineAudioRenderer
        return MediaQueueFillSnapshot(
            videoSeconds: videoPacketQueue.contentSeconds,
            audioSeconds: audioPacketQueue.contentSeconds,
            pcmSeconds: pendingAudioContentSeconds,
            ringSeconds: nativeAudio?.renderRingContentSeconds,
            videoFrameSeconds: pendingVideoContentSeconds,
            sourceUnderflows: nativeAudio?.sourceUnderflowCount
        )
    }

    func fillQueuesToHighWater(
        generation gen: Int,
        initiator: MediaQueueFillInitiator,
        phase: MediaQueueFillPhase,
        videoContentCap: TimeInterval? = nil,
        audioContentCap: TimeInterval? = nil,
        audioDecodeOperationID: UInt64? = nil
    ) async throws {
        guard isCurrentGeneration(gen),
              isCurrentAudioDecodeOperation(audioDecodeOperationID) else {
            return
        }
        if isFillingQueues { return }
        isFillingQueues = true
        defer { isFillingQueues = false }
        lastFillProducedPackets = false
        let effectiveVideoHWM: TimeInterval
        if warmVideoImageHoldWithholdsVideoSupply {
            effectiveVideoHWM = 0
        } else if isVideoLaneWarmSuspended {
            effectiveVideoHWM = suspendedVideoSupplyTarget
        } else if holdsPassThroughVideo {
            effectiveVideoHWM = min(
                videoPacketQueue.highWater,
                runtimePassThroughVideoContentHWM
            )
        } else {
            effectiveVideoHWM = videoPacketQueue.highWater
        }
        let videoTarget = min(effectiveVideoHWM, videoContentCap ?? effectiveVideoHWM)
        let audioTarget = min(
            audioPacketQueue.highWater,
            audioContentCap ?? audioPacketQueue.highWater
        )
        let isPriming = videoContentCap != nil || audioContentCap != nil
        var lastLoggedDepth: TimeInterval = -primeProgressLogInterval
        let previousVideoCap = videoEnqueueCap
        videoEnqueueCap = videoTarget
        defer { videoEnqueueCap = previousVideoCap }
        var pace: MediaQueueFillTrace?
        if diagnostics.isCapturing {
            nextQueueFillTraceID &+= 1
            pace = MediaQueueFillTrace(
                generation: gen,
                fillID: nextQueueFillTraceID,
                initiator: initiator,
                phase: phase,
                priming: isPriming,
                seeking: isSeekInFlight,
                playing: isPlaying,
                warmSuspended: isVideoLaneWarmSuspended,
                entry: queueFillDiagnosticSnapshot()
            )
        }
        defer {
            if diagnostics.isCapturing, let pace, pace.attempts > 0 {
                let operationCurrent = audioDecodeOperationID.map {
                    activeAudioDecodeOperationID == $0
                        || (pace.initiatedRuntimeFault
                            && runtimeFaultedGeneration == gen
                            && activeAudioDecodeOperationID == nil)
                } ?? true
                let ownerCurrent = gen == generation
                    && operationCurrent
                    && warmPreparationTransaction.orphan == nil
                let current = ownerCurrent && isCurrentGeneration(gen)
                    && isCurrentAudioDecodeOperation(audioDecodeOperationID)
                let outcome: MediaQueueFillTrace.Outcome
                if !ownerCurrent {
                    outcome = .superseded
                } else if pace.outcome == .error {
                    outcome = .error
                } else if Task.isCancelled {
                    outcome = .cancelled
                } else {
                    outcome = current ? pace.outcome : .superseded
                }
                diagnostics.log(pace.endLine(
                    outcome: outcome,
                    exit: current ? queueFillDiagnosticSnapshot() : nil
                ))
            }
        }

        while isCurrentGeneration(gen) {
            guard !Task.isCancelled,
                  isCurrentAudioDecodeOperation(audioDecodeOperationID) else {
                return
            }

            drainResidualPackets()

            let videoDepth = isVideoLaneWarmSuspended
                ? suspendedVideoRunway
                : videoPacketQueue.contentSeconds
            let audioDepth = audioPacketQueue.contentSeconds
            let residualBlockingVideo = !isVideoLaneWarmSuspended
                && !residualVideoPackets.isEmpty
            let residualBlockingAudio = hasAudioTrack && !residualAudioPackets.isEmpty

            let videoAtMemoryCap = !isVideoLaneWarmSuspended && holdsPassThroughVideo
                && !canAcceptAnotherPassThroughVideoPacket()
            let videoNeeds = !videoAtMemoryCap && !residualBlockingVideo
                && (videoTarget - videoDepth) >= minTrackFillRoom
            let audioNeeds = hasAudioTrack && !residualBlockingAudio
                && (audioTarget - audioDepth) >= minTrackFillRoom
            let needsMore: Bool
            if isPriming || holdsPassThroughVideo {
                needsMore = videoNeeds || audioNeeds
            } else {
                needsMore = needsPacketFill()
            }
            guard needsMore else { break }

            let reachedEOF = await demux.isEOF
            guard !Task.isCancelled, isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(audioDecodeOperationID),
                  warmPreparationTransaction.orphan == nil else {
                return
            }
            if reachedEOF {
                demuxReachedEOF = true
                break
            }

            let currentVideoTarget: TimeInterval
            if warmVideoImageHoldWithholdsVideoSupply {
                currentVideoTarget = 0
            } else if isVideoLaneWarmSuspended {
                currentVideoTarget = min(videoTarget, suspendedVideoSupplyTarget)
            } else {
                currentVideoTarget = videoTarget
            }
            let videoBudget = videoNeeds
                ? min(max(0, currentVideoTarget - videoDepth), pumpCallBudgetCapSeconds)
                : 0
            let audioBudget = audioNeeds
                ? min(max(0, audioTarget - audioDepth), pumpCallBudgetCapSeconds)
                : 0
            guard videoBudget > 0.000_5 || audioBudget > 0.000_5 else { break }

            let packets: [MediaPacket]
            let acceptedPacketsBeforePump = totalVideoPacketsIngested + totalAudioPacketsIngested
            let videoReadGeneration = videoBudget > 0.000_5
                ? beginVideoReadGeneration()
                : nil
            resetCachedRunway(
                video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5
            )
            var sourceWaitBudget: MediaSourceWaitBudget?
            defer {
                if activeSourceWaitBudget?.id == sourceWaitBudget?.id {
                    activeSourceWaitBudget = nil
                }
                sourceWaitBudget?.cancel()
            }
            do {
                if hasMultiConnectionHelpers {
                    lastMultiConnectionPlaybackPosition = mediaTime
                    await demux.updateMultiConnectionPlayback(position: mediaTime, rate: playbackRate)
                }
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil,
                      !Task.isCancelled else { return }
                sourceWaitBudget = beginSourceWaitBudget()
                if diagnostics.isCapturing, pace != nil {
                    if let trace = pace, trace.attempts == 0 {
                        diagnostics.log(trace.beginLine)
                    }
                    pace?.attempts += 1
                }
                packets = try await demux.pump(
                    videoBudget: videoBudget,
                    audioBudget: audioBudget,
                    sourceWaitBudget: sourceWaitBudget
                )
                if isCurrentGeneration(gen), !Task.isCancelled,
                   !packets.isEmpty
                    || totalVideoPacketsIngested + totalAudioPacketsIngested > acceptedPacketsBeforePump {
                    unresolvedPrimaryTransportFailure = nil
                }
                if diagnostics.isCapturing, pace != nil, !packets.isEmpty {
                    pace?.pumps += 1
                    pace?.packets += packets.count
                    pace?.gathered += packets.reduce(0) { $0 + $1.duration }
                }
            } catch let error as MediaEngineError {
                if diagnostics.isCapturing {
                    pace?.outcome = Self.isExpectedCancelledPumpExit(
                        error, taskWasCancelled: Task.isCancelled
                    ) ? .cancelled : .error
                }
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil else {
                    return
                }
                resetCachedRunway(video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5)
                if Self.isExpectedCancelledPumpExit(
                    error,
                    taskWasCancelled: Task.isCancelled
                ) {
                    unresolvedPrimaryTransportFailure = nil
                    return
                }
                if error.demuxFailureKind == .liveMapChangedReloadRequired {
                    if !isReady || isSeekInFlight {
                        throw error
                    }
                    let fault = MediaRuntimeFault(
                        subsystem: .demux,
                        stage: .pump,
                        classification: .input,
                        recoverability: .automaticSourceAwareReopen,
                        ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                        diagnostics: MediaRuntimeFaultDiagnostics(
                            label: "hlsMapChanged",
                            details: "reload-required"
                        )
                    )
                    if diagnostics.isCapturing { pace?.initiatedRuntimeFault = true }
                    publishRuntimeFault(fault, generation: gen)
                    return
                }
                if isCurrentGeneration(gen),
                   error.demuxFailureKind == .stickyFMP4InputRejection
                    || error.demuxFailureKind == .terminalLiveInputRejection {
                    let fault = MediaRuntimeFault(
                        subsystem: .demux,
                        stage: .pump,
                        classification: .input,
                        recoverability: .manualRetry,
                        ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                        diagnostics: MediaRuntimeFaultDiagnostics(
                            label: "demux",
                            details: error.localizedDescription
                        )
                    )
                    if !isReady || isSeekInFlight {
                        throw error
                    }
                    if diagnostics.isCapturing { pace?.initiatedRuntimeFault = true }
                    publishRuntimeFault(fault, generation: gen)
                    return
                }
                if isCurrentGeneration(gen) {
                    diagnostics.log("[PathA] pump failed: \(error.localizedDescription)")
                }
                if !isReady || isSeekInFlight {
                    throw error
                }
                unresolvedPrimaryTransportFailure = StreamTransportFailure.preserving(error, stage: .mediaSupply)?
                    .stamped(backend: activeOwnerGeneration, session: runtimeGeneration)
                break
            } catch {
                if diagnostics.isCapturing {
                    pace?.outcome = error is CancellationError ? .cancelled : .error
                }
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil else {
                    return
                }
                resetCachedRunway(video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5)
                if isCurrentGeneration(gen) {
                    diagnostics.log("[PathA] pump failed: \(error.localizedDescription)")
                }
                if Task.isCancelled
                    || StreamTransportFailure.preserving(error, stage: .mediaSupply)?.isCancellation == true {
                    unresolvedPrimaryTransportFailure = nil
                    return
                }
                if !isReady || isSeekInFlight {
                    throw transportEngineError(error, stage: isSeekInFlight ? .mediaSeek : .mediaOpen)
                }
                unresolvedPrimaryTransportFailure = StreamTransportFailure.preserving(error, stage: .mediaSupply)?
                    .stamped(backend: activeOwnerGeneration, session: runtimeGeneration)
                break
            }
            guard isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(audioDecodeOperationID),
                  warmPreparationTransaction.orphan == nil else { return }
            if packets.isEmpty {
                if diagnostics.isCapturing { pace?.outcome = .empty }
                let reachedEOF = await demux.isEOF
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil else {
                    return
                }
                if reachedEOF {
                    demuxReachedEOF = true
                }
                break
            }
            ingest(
                packets,
                videoReadGeneration: videoReadGeneration
            )
            lastFillProducedPackets = true
            resolveVideoStarvationIfRecovered()
            if isSeekInFlight, !seekFirstPacketLogged, !packets.isEmpty {
                seekFirstPacketLogged = true
                diagnostics.log(
                    "[PathA] seek-first-packet count=\(packets.count) " +
                    "firstPTS=\(String(format: "%.2f", packets.first?.pts ?? -1))"
                )
            }
            drainResidualPackets()

            if isPriming {
                let depth = hasAudioTrack
                    ? max(videoPacketQueue.contentSeconds, audioPacketQueue.contentSeconds)
                    : videoPacketQueue.contentSeconds
                if depth - lastLoggedDepth >= primeProgressLogInterval - 1e-9 {
                    lastLoggedDepth = depth
                    diagnostics.log(
                        "[PathA] prime progress vPkts=\(videoPacketCount) " +
                        "aPkts=\(audioPacketCount) " +
                        "vDepth=\(String(format: "%.2f", videoPacketQueue.contentSeconds))s " +
                        "aDepth=\(String(format: "%.2f", audioPacketQueue.contentSeconds))s " +
                        "cap video packets \(maxPassThroughVideoPackets())"
                    )
                }
            }
        }

        if isCurrentGeneration(gen),
           isCurrentAudioDecodeOperation(audioDecodeOperationID) {
            await refreshCachedRunway(generation: gen)
            let reachedEOF = await demux.isEOF
            guard isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(audioDecodeOperationID),
                  warmPreparationTransaction.orphan == nil else {
                return
            }
            if reachedEOF {
                demuxReachedEOF = true
            }
            if isReady, !isSeekInFlight {
                onEvent?(.tick(
                    mediaTime: clock.mediaTime,
                    duration: clock.duration,
                    buffered: bufferedTime
                ))
            }
        }
    }

    // MARK: - relay drain + video-starvation buffering

    func drainRelayedPackets() {
        if warmPreparationTransaction.orphan != nil {
            packetRelay.reset()
            return
        }
        let packets = packetRelay.drain()
        guard !packets.isEmpty else { return }
        relayDrainCount += 1
        ingest(
            packets,
            warmVideoProvenance: isVideoLaneWarmSuspended
                ? .postSuspend(readGeneration: nextVideoReadGeneration)
                : nil
        )
        lastFillProducedPackets = true
        scheduleVideoDecodeIfNeeded()
        if !isPreparingWarmVideoLane {
            scheduleAudioDecodeIfNeeded()
        }
        resolveVideoStarvationIfRecovered()
    }

    func clearVideoTrackQueues() {
        clearPendingVideoFrames()
        videoPackets = []
        residualVideoPackets = []
        videoPacketQueue.reset()
    }

    func drainPacketDuration(
        _ duration: TimeInterval,
        from queue: inout ContentSecondQueue,
        packets: PacketRingBuffer
    ) {
        let drained = queue.drain(content: duration)
        if drained + 1e-9 < duration {
            queue.reset()
            for packet in packets {
                _ = queue.enqueue(content: packet.duration)
            }
        }
    }

    func ingest(
        _ packets: [MediaPacket],
        videoReadGeneration: UInt64? = nil,
        warmVideoProvenance: DemandVideoCandidateProvenance? = nil
    ) {
        var markedFirstSample = false
        var rejectedVideo = 0
        var rejectedAudio = 0
        for rawPacket in packets {
            let packet = normalizingZeroDuration(rawPacket)
            switch packet.track {
            case .video:
                if !markedFirstSample {
                    markedFirstSample = true
                    tracing.mark(.demandFirstSampleReady, token: activeStartupTraceToken)
                }
                let (updatedVideoReadBytes, overflowed) = videoReadBytes.addingReportingOverflow(
                    max(0, packet.data.count)
                )
                videoReadBytes = overflowed ? Int.max : updatedVideoReadBytes
                if isVideoLaneWarmSuspended, !isDecodingWarmVideoCandidate {
                    let provenance = warmVideoProvenance
                        ?? .postSuspend(
                            readGeneration: videoReadGeneration
                                ?? nextVideoReadGeneration
                        )
                    retainSuspendedVideoPacket(
                        packet,
                        provenance: provenance
                    )
                    totalVideoPacketsIngested += 1
                    pipeWindowVideoPacketsIngested += 1
                    pipeWindowVideoBytesRead += Int64(packet.data.count)
                    bytesRead += Int64(packet.data.count)
                    continue
                }
                noteFlowStage(
                    &flowIngestV,
                    "ingestV",
                    starvingBelow: ingestStarvationFloor(videoPacketQueue),
                    depth: videoPacketQueue.contentSeconds
                )
                if diagnostics.isCapturing {
                    flowLastIngestVideoPTS = packet.pts
                    if let born = packet.emittedAt {
                        let age = Int(born.duration(to: ContinuousClock.now) / .milliseconds(1))
                        if age > flowWindowMaxPacketAgeMs { flowWindowMaxPacketAgeMs = age }
                    }
                }
                if packet.pixelBuffer != nil {
                    holdsPassThroughVideo = true
                    noteVideoFrameSize(from: packet.pixelBuffer)
                }
                if residualVideoPackets.isEmpty, enqueueVideoPacket(packet) {
                    noteAcceptedPrimaryObservation(packet)
                    totalVideoPacketsIngested += 1
                    pipeWindowVideoPacketsIngested += 1
                    pipeWindowVideoBytesRead += Int64(packet.data.count)
                    let sampleBytes = packet.data.count > 0
                        ? packet.data.count
                        : estimatedVideoFrameBytes()
                    bytesRead += Int64(sampleBytes)
                } else {
                    residualVideoPackets.append(packet)
                    rejectedVideo += 1
                }
            case .audio:
                guard hasAudioTrack else { continue }
                if !markedFirstSample {
                    markedFirstSample = true
                    tracing.mark(.demandFirstSampleReady, token: activeStartupTraceToken)
                }
                noteFlowStage(
                    &flowIngestA,
                    "ingestA",
                    starvingBelow: ingestStarvationFloor(audioPacketQueue),
                    depth: audioPacketQueue.contentSeconds
                )
                if diagnostics.isCapturing {
                    flowLastIngestAudioPTS = packet.pts
                    if let born = packet.emittedAt {
                        let age = Int(born.duration(to: ContinuousClock.now) / .milliseconds(1))
                        if age > flowWindowMaxPacketAgeMs { flowWindowMaxPacketAgeMs = age }
                    }
                }
                if residualAudioPackets.isEmpty,
                   enqueueFullPacket(packet, queue: &audioPacketQueue, store: &audioPackets) {
                    noteAcceptedPrimaryObservation(packet)
                    totalAudioPacketsIngested += 1
                    bytesRead += Int64(packet.data.count)
                } else {
                    residualAudioPackets.append(packet)
                    rejectedAudio += 1
                }
            }
        }
        if rejectedVideo > 0 || rejectedAudio > 0, diagnostics.isCapturing {
            let firstRejectedPTS = residualVideoPackets.first?.pts
            diagnostics.log(
                "[PathA] residual park v=\(rejectedVideo) a=\(rejectedAudio) " +
                "vRes=\(residualVideoPackets.count) aRes=\(residualAudioPackets.count) " +
                "vQ=\(String(format: "%.2f", videoPacketQueue.contentSeconds))s " +
                "firstV=\(firstRejectedPTS.map { String(format: "%.2f", $0) } ?? "-")"
            )
        }
        enforcePassThroughVideoMemoryBudget(dropOldest: true)
    }

    func drainResidualPackets() {
        while let head = residualVideoPackets.first {
            if enqueueVideoPacket(head) {
                noteAcceptedPrimaryObservation(head)
                residualVideoPackets.removeFirst()
                totalVideoPacketsIngested += 1
                pipeWindowVideoPacketsIngested += 1
                pipeWindowVideoBytesRead += Int64(head.data.count)
                let sampleBytes = head.data.count > 0
                    ? head.data.count
                    : estimatedVideoFrameBytes()
                bytesRead += Int64(sampleBytes)
            } else {
                break
            }
        }
        while let head = residualAudioPackets.first {
            if enqueueFullPacket(head, queue: &audioPacketQueue, store: &audioPackets) {
                noteAcceptedPrimaryObservation(head)
                residualAudioPackets.removeFirst()
                totalAudioPacketsIngested += 1
                bytesRead += Int64(head.data.count)
            } else {
                break
            }
        }
    }

    func normalizingZeroDuration(_ packet: MediaPacket) -> MediaPacket {
        guard packet.duration <= 0 else { return packet }
        var normalized = packet
        normalized.duration = packet.track == .video
            ? nominalZeroDurationVideoSeconds
            : nominalZeroDurationAudioSeconds
        zeroDurationPacketsNormalized += 1
        if zeroDurationPacketsNormalized == 1 || zeroDurationPacketsNormalized % 200 == 0 {
            diagnostics.log(
                "[PathA] zero-duration \(packet.track.rawValue) packet normalized " +
                "pts=\(String(format: "%.3f", packet.pts)) → " +
                "\(String(format: "%.4f", normalized.duration))s " +
                "total=\(zeroDurationPacketsNormalized)"
            )
        }
        return normalized
    }

    func enqueueVideoPacket(_ packet: MediaPacket) -> Bool {
        let packet = normalizingZeroDuration(packet)
        let isPassThrough = packet.pixelBuffer != nil || holdsPassThroughVideo
        let contentHWM = effectiveVideoContentHWM()

        if isPassThrough {
            while !canAcceptAnotherPassThroughVideoPacket(), !videoPackets.isEmpty {
                dropOldestVideoPacket()
            }
            while !canAcceptAnotherPassThroughVideoPacket(), !pendingVideoFrames.isEmpty {
                let dropped = pendingVideoFrames.removeFirst()
                pendingVideoContentSeconds = max(
                    0,
                    pendingVideoContentSeconds - dropped.duration
                )
            }
            guard canAcceptAnotherPassThroughVideoPacket() else { return false }
            while videoPacketQueue.contentSeconds + packet.duration > contentHWM + 1e-9,
                  !videoPackets.isEmpty {
                dropOldestVideoPacket()
            }
            if videoPacketQueue.contentSeconds + packet.duration > contentHWM + 1e-9 {
                return false
            }
        } else if videoPacketQueue.contentSeconds + packet.duration > contentHWM + 1e-9 {
            return false
        }

        let accepted = videoPacketQueue.enqueue(content: packet.duration)
        guard accepted + 1e-9 >= packet.duration else {
            _ = videoPacketQueue.drain(content: accepted)
            return false
        }
        videoPackets.append(packet)
        return true
    }

    func effectiveVideoContentHWM() -> TimeInterval {
        var cap = videoPacketQueue.highWater
        if holdsPassThroughVideo {
            cap = min(cap, runtimePassThroughVideoContentHWM)
        }
        if let active = videoEnqueueCap {
            cap = min(cap, active)
        }
        return cap
    }

    private func dropOldestVideoPacket() {
        guard !videoPackets.isEmpty else { return }
        let dropped = videoPackets.removeFirst()
        drainPacketDuration(dropped.duration, from: &videoPacketQueue, packets: videoPackets)
    }

    func enqueueFullPacket(
        _ packet: MediaPacket,
        queue: inout ContentSecondQueue,
        store: inout PacketRingBuffer
    ) -> Bool {
        let packet = normalizingZeroDuration(packet)
        let room = queue.highWater - queue.contentSeconds
        guard room + 1e-9 >= packet.duration else { return false }
        let accepted = queue.enqueue(content: packet.duration)
        guard accepted + 1e-9 >= packet.duration else {
            _ = queue.drain(content: accepted)
            return false
        }
        store.append(packet)
        return true
    }

    func noteVideoFrameSize(from pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }
        if knownVideoFrameWidth != w || knownVideoFrameHeight != h {
            knownVideoFrameWidth = w
            knownVideoFrameHeight = h
            if holdsPassThroughVideo {
                let maxV = maxPassThroughVideoPackets()
                let frameBytes = estimatedVideoFrameBytes()
                diagnostics.log(
                    "[PathA] cap video packets \(maxV) " +
                    "(≈\(frameBytes * maxV / (1024 * 1024))MB) for \(w)x\(h)"
                )
            } else {
                diagnostics.log("[PathA] decoded video size \(w)x\(h)")
            }
        }
    }

    func estimatedVideoFrameBytes() -> Int {
        let w = knownVideoFrameWidth > 0 ? knownVideoFrameWidth : defaultVideoFrameWidth
        let h = knownVideoFrameHeight > 0 ? knownVideoFrameHeight : defaultVideoFrameHeight
        return max(w * h * 4, 64 * 1024)
    }

    func maxPassThroughVideoPackets() -> Int {
        let frameBytes = estimatedVideoFrameBytes()
        let byBudget = max(1, videoPixelFrameBudgetBytes / frameBytes)
        return max(
            minPassThroughVideoPackets,
            min(byBudget, maxPassThroughVideoPacketsAbsolute)
        )
    }

    func heldPassThroughVideoFrameCount() -> Int {
        videoPackets.count + pendingVideoFrames.count
    }

    func canAcceptAnotherPassThroughVideoPacket() -> Bool {
        heldPassThroughVideoFrameCount() < maxPassThroughVideoPackets()
    }

    func enforcePassThroughVideoMemoryBudget(dropOldest: Bool) {
        guard holdsPassThroughVideo, dropOldest else { return }
        let maxFrames = maxPassThroughVideoPackets()
        while heldPassThroughVideoFrameCount() > maxFrames, !videoPackets.isEmpty {
            dropOldestVideoPacket()
        }
    }
}
