import Foundation

extension MediaEngineSession {
    func pullPCM(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioRendererPull {
        guard frameCount > 0, channels > 0, sampleRate > 0 else {
            return AudioRendererPull(frames: 0, contentSeconds: 0)
        }
        let pull = audioTimelineBuffer.pullContent(
            frameCount: frameCount,
            sampleRate: sampleRate,
            channels: channels,
            into: buffer
        )
        let framesWritten = pull.frames

        let contentSeconds = TimeInterval(framesWritten) / sampleRate
        noteAudioSupplyPull(requested: frameCount, written: framesWritten)
        return AudioRendererPull(
            frames: framesWritten, contentSeconds: contentSeconds
        )
    }

    func noteAudioSupplyPull(requested: Int, written: Int) {
        if written > 0 {
            pulledAudioFrameCount += written
            if isPlaying, !isSeekInFlight {
                scheduleAudioDecodeIfNeeded()
                scheduleVideoDecodeIfNeeded()
            }
        }
        if isPlaying, !isSeekInFlight {
            handlePullOutcome(requested: requested, written: written)
        }
    }

    func audioSupplyDidReport(_ report: AudioFeederPullReport) {
        guard report.passes > 0 else { return }
        noteAudioSupplyPull(
            requested: report.requestedFrames,
            written: report.writtenFrames
        )
    }

    func renderedContentDidAdvance(bySeconds seconds: TimeInterval) {
        guard !isSeekInFlight else {
            return
        }
        guard isPlaying, !videoStarvationHoldIsActive(), seconds > 0 else {
            return
        }
        noteFlowStage(&flowClock, "clock")
        clock.advanceContent(by: seconds)
        if seconds.isFinite, clock.mediaTime.isFinite, audioRender.outputAvailability == .available {
            renderedAudioOutput = RenderedAudioOutput(
                sessionGeneration: runtimeGeneration, ownerGeneration: activeOwnerGeneration, position: clock.mediaTime
            )
        }
        if !isVideoLaneWarmSuspended {
            presentDueVideoFrames()
            evaluateVideoStarvation()
            maybeResyncDisplaySlave()
        } else {
            if !isPreparingWarmVideoLane, !isVideoLanePreparedForForeground {
                trimSuspendedVideoWindowBehindClock(audioPresentationMediaTime)
            }
            wakeSupplyLoopIfDrained()
        }
        onEvent?(.tick(
            mediaTime: clock.mediaTime,
            duration: clock.duration,
            buffered: bufferedTime
        ))
        notifyMultiConnectionPlaybackProgressIfNeeded()
        if isPlaying {
            scheduleAudioDecodeIfNeeded()
            if !isVideoLaneWarmSuspended {
                scheduleVideoDecodeIfNeeded()
            }
        }
        if clock.isAtEnd {
            emitEndedIfNeeded()
        } else if audioDrainingToEnd {
            maybeFinishAudioDrain()
        }
        maybeReportPipeInstrument()
    }

    func handlePullOutcome(requested: Int, written: Int) {
        if clock.isAtEnd {
            emitEndedIfNeeded()
            return
        }
        guard hasAudioTrack, audioDecoderOpened else { return }

        let underrun = written < requested
        if !underrun {
            if isBuffering {
                guard !videoStarvationHoldIsActive() else { return }
                isBuffering = false
                applyPipelineDemand()
                armPresentFeedIfNeeded()
                presentDueVideoFrames()
                onEvent?(.playing)
            }
            return
        }
        if audioSupplyExhausted() {
            beginAudioDrainToEnd()
            return
        }
        if !isBuffering {
            isBuffering = true
            disarmPresentFeed()
            applyPipelineDemand()
            onEvent?(.tick(
                mediaTime: clock.mediaTime,
                duration: clock.duration,
                buffered: bufferedTime
            ))
            onEvent?(.buffering)
            updateMultiConnectionPlayback()
        }
        requestSupplyWake()
        scheduleAudioDecodeIfNeeded()
    }

    func audioSupplyExhausted() -> Bool {
        demuxReachedEOF
            && audioPackets.isEmpty
            && residualAudioPackets.isEmpty
            && pendingAudioContentSeconds < 0.000_5
            && audioDecodeTask == nil
            && audioDecodeLaneOwners == 0
            && activeAudioDecodeOperationID == nil
    }

    func beginAudioDrainToEnd() {
        if !audioEOFDrain.isDraining {
            audioEOFDrain.isDraining = true
            diagnostics.log(
                "[PathA] audio EOF draining ring pending=\(audioRender.hasPendingOutput)"
            )
        }
        if isBuffering, !videoStarvationHoldIsActive() {
            isBuffering = false
            applyPipelineDemand()
            armPresentFeedIfNeeded()
            presentDueVideoFrames()
            onEvent?(.playing)
        }
        maybeFinishAudioDrain()
    }

    func maybeFinishAudioDrain() {
        guard audioEOFDrain.isDraining, isPlaying, !isSeekInFlight, !hasEmittedEnded else { return }
        if let deadline = audioEOFDrain.playoutDeadline {
            guard ContinuousClock.now >= deadline else { return }
            finishAudioDrain()
            return
        }
        guard !audioRender.hasPendingOutput else { return }
        let now = ContinuousClock.now
        let latency = max(0, audioRender.presentationTiming.wallLatencySeconds)
        audioEOFDrain.emptiedAt = now
        let deadline = now.advanced(by: .seconds(latency))
        audioEOFDrain.playoutDeadline = deadline
        guard latency > 0 else {
            finishAudioDrain()
            return
        }
        let gen = generation
        audioEOFDrain.wakeTask?.cancel()
        audioEOFDrain.wakeTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch { return }
            guard let self, !Task.isCancelled, self.isCurrentGeneration(gen) else { return }
            self.maybeFinishAudioDrain()
        }
    }

    func finishAudioDrain() {
        if let emptiedAt = audioEOFDrain.emptiedAt, let deadline = audioEOFDrain.playoutDeadline {
            let elapsedMs = Int(emptiedAt.duration(to: ContinuousClock.now) / .milliseconds(1))
            let latencyMs = Int(emptiedAt.duration(to: deadline) / .milliseconds(1))
            diagnostics.log(
                "[PathA] audio EOF played out after \(elapsedMs)ms (latency \(latencyMs)ms)"
            )
        }
        emitEndedIfNeeded()
    }

    func emitEndedIfNeeded() {
        revokeAudioMaintenancePermission()
        guard !hasEmittedEnded else { return }
        helperTelemetry.invalidate(.parked)
        hasEmittedEnded = true
        isPlaying = false
        isBuffering = false
        audioEOFDrain.reset()
        audioRender.stop()
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        cancelDecode()
        disarmPresentFeed()
        if clock.duration > 0, clock.mediaTime < clock.duration {
            clock.seek(to: clock.duration)
        }
        updatePiPPlaybackState()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        onEvent?(.tick(
            mediaTime: clock.mediaTime,
            duration: clock.duration,
            buffered: bufferedTime
        ))
        onEvent?(.ended)
    }

    func needsPacketFill() -> Bool {
        if isVideoLaneWarmSuspended {
            if !residualAudioPackets.isEmpty { return true }
            if !warmVideoImageHoldWithholdsVideoSupply,
               suspendedVideoSupplyTarget > 0,
               (suspendedVideoSupplyTarget - suspendedVideoRunway)
                    >= minTrackFillRoom {
                return true
            }
            return hasAudioTrack
                && (audioPacketQueue.highWater - audioPacketQueue.contentSeconds)
                    >= minTrackFillRoom
        }
        if !residualVideoPackets.isEmpty || !residualAudioPackets.isEmpty {
            if !residualAudioPackets.isEmpty { return true }
            if !warmVideoImageHoldWithholdsVideoSupply { return true }
        }
        if warmVideoImageHoldWithholdsVideoSupply {
        } else if holdsPassThroughVideo {
            let videoTarget = min(
                videoPacketQueue.highWater,
                runtimePassThroughVideoContentHWM
            )
            if (videoTarget - videoPacketQueue.contentSeconds) >= minTrackFillRoom,
               canAcceptAnotherPassThroughVideoPacket() {
                return true
            }
        } else if (videoPacketQueue.highWater - videoPacketQueue.contentSeconds) >= minTrackFillRoom {
            return true
        }
        if hasAudioTrack,
           (audioPacketQueue.highWater - audioPacketQueue.contentSeconds) >= minTrackFillRoom {
            return true
        }
        return false
    }

    // MARK: - Self-paced supply loop

    func startSupplyLoop() {
        guard isReady,
              !isPreparingWarmVideoLane else { return }
        if supplyLoopTask != nil {
            requestSupplyWake()
            return
        }
        let gen = generation
        supplyLoopWakePending = false
        diagnostics.log(
            "[PathA] supply loop start gen=\(gen) " +
            "vHWM=\(String(format: "%.1f", videoPacketQueue.highWater))s " +
            "aHWM=\(String(format: "%.1f", audioPacketQueue.highWater))s " +
            "lowFrac=\(String(format: "%.2f", supplyLowWaterFraction))"
        )
        supplyLoopTask = Task { @MainActor [weak self] in
            await self?.runSupplyLoop(generation: gen)
        }
    }

    func runSupplyLoop(generation gen: Int) async {
        while isCurrentGeneration(gen) {
            if Task.isCancelled { return }
            if isPreparingWarmVideoLane {
                return
            }
            if needsPacketFill() {
                try? await fillQueuesToHighWater(generation: gen, initiator: .supplyLoop, phase: .playback)
                pipeWindowPumps += 1
                guard isCurrentGeneration(gen), !Task.isCancelled else { return }
                if isPlaying {
                    scheduleVideoDecodeIfNeeded()
                    scheduleAudioDecodeIfNeeded()
                }
                if canPumpNow(), !demuxReachedEOF, lastFillProducedPackets {
                    if supplyLoopWakePending {
                        supplyLoopWakePending = false
                    } else {
                        try? await Task.sleep(nanoseconds: supplyStallBackoffNanos)
                    }
                    continue
                }
            }
            await parkSupplyLoop()
        }
    }

    func parkSupplyLoop() async {
        if Task.isCancelled { return }
        if supplyLoopWakePending {
            supplyLoopWakePending = false
            return
        }
        pipeWindowParks += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            supplyLoopWake = continuation
        }
    }

    func requestSupplyWake() {
        guard supplyLoopTask != nil else { return }
        if let continuation = supplyLoopWake {
            supplyLoopWake = nil
            continuation.resume()
        } else {
            supplyLoopWakePending = true
        }
    }

    func wakeSupplyLoopIfDrained() {
        guard supplyLoopTask != nil, supplyBelowLowWater() else { return }
        pipeWindowWakes += 1
        requestSupplyWake()
    }

    func supplyBelowLowWater() -> Bool {
        if isVideoLaneWarmSuspended {
            if !warmVideoImageHoldWithholdsVideoSupply,
               suspendedVideoSupplyTarget > 0,
               suspendedVideoRunway
                    < suspendedVideoSupplyTarget * supplyLowWaterFraction {
                return true
            }
            return hasAudioTrack
                && audioPacketQueue.contentSeconds
                    < audioPacketQueue.highWater * supplyLowWaterFraction
        }
        if !warmVideoImageHoldWithholdsVideoSupply {
            let videoHigh = holdsPassThroughVideo
                ? min(videoPacketQueue.highWater, runtimePassThroughVideoContentHWM)
                : videoPacketQueue.highWater
            let videoHasRoom = !holdsPassThroughVideo
                || canAcceptAnotherPassThroughVideoPacket()
            if videoHasRoom,
               videoPacketQueue.contentSeconds < videoHigh * supplyLowWaterFraction {
                return true
            }
        }
        if hasAudioTrack,
           audioPacketQueue.contentSeconds < audioPacketQueue.highWater * supplyLowWaterFraction {
            return true
        }
        return false
    }

    func canPumpNow() -> Bool {
        if isVideoLaneWarmSuspended {
            if !warmVideoImageHoldWithholdsVideoSupply,
               suspendedVideoSupplyTarget > 0,
               suspendedVideoRunway < suspendedVideoSupplyTarget {
                return true
            }
            return hasAudioTrack
                && residualAudioPackets.isEmpty
                && (audioPacketQueue.highWater - audioPacketQueue.contentSeconds)
                    >= minTrackFillRoom
        }
        if !warmVideoImageHoldWithholdsVideoSupply {
            let videoTarget = holdsPassThroughVideo
                ? min(videoPacketQueue.highWater, runtimePassThroughVideoContentHWM)
                : videoPacketQueue.highWater
            let videoAtMemoryCap = holdsPassThroughVideo
                && !canAcceptAnotherPassThroughVideoPacket()
            if residualVideoPackets.isEmpty, !videoAtMemoryCap,
               (videoTarget - videoPacketQueue.contentSeconds) >= minTrackFillRoom {
                return true
            }
        }
        if hasAudioTrack, residualAudioPackets.isEmpty,
           (audioPacketQueue.highWater - audioPacketQueue.contentSeconds) >= minTrackFillRoom {
            return true
        }
        return false
    }

    func cancelSupplyLoop() {
        invalidateSourceWaitBudget()
        supplyLoopTask?.cancel()
        supplyLoopTask = nil
        if let continuation = supplyLoopWake {
            supplyLoopWake = nil
            continuation.resume()
        }
        supplyLoopWakePending = false
    }

    func clearPendingVideoFrames() {
        pendingVideoFrames = []
        pendingVideoContentSeconds = 0
    }

    func clearPendingPCM() {
        audioTimelineBuffer.reset()
        audioTimelineAdjustmentLogCount = 0
        audioDecodeTimingLogCount = 0
    }

    func armPresentFeedIfNeeded() {
        guard isPlaying, !isBuffering, !isSeekInFlight,
              !isVideoLaneWarmSuspended,
              let asbd = videoRender as? SampleBufferVideoRenderer else { return }
        asbd.requestMediaDataWhenReady { [weak self, weak asbd] in
            guard let self, let asbd, self.presentFeedArmed,
                  (self.videoRender as? SampleBufferVideoRenderer) === asbd else { return }
            self.drainPresentFeedFromASBD(asbd)
        }
        presentFeedArmed = true
    }

    func disarmPresentFeed() {
        presentFeedArmed = false
        (videoRender as? SampleBufferVideoRenderer)?.stopRequestingMediaData()
    }

    enum PresentDrainResult {
        case blockedOnASBD
        case waitingOnEnhancement
        case nothingDue
        case enqueued
    }

    func drainPresentFeedFromASBD(_ renderer: SampleBufferVideoRenderer) {
        guard isPlaying, !isBuffering, !isSeekInFlight, !isVideoLaneWarmSuspended else {
            disarmPresentFeed()
            return
        }
        pipeWindowPresentCalls += 1
        switch enqueueDueFramesWhileASBDReady(renderer) {
        case .blockedOnASBD, .enqueued:
            break
        case .nothingDue, .waitingOnEnhancement:
            disarmPresentFeed()
        }
        maybeReportPipeInstrument()
    }

    func enqueueDueFramesWhileASBDReady(
        _ renderer: SampleBufferVideoRenderer
    ) -> PresentDrainResult {
        var didEnqueue = false
        let burstFirstPTS = diagnostics.isCapturing ? pendingVideoFrames.first?.pts : nil
        var burstEnqueued = 0
        defer { reportLateVideoPresentBurst(firstPTS: burstFirstPTS, enqueued: burstEnqueued) }
        let due = videoPresentationDueTime
        switch releaseWarmVideoImageHoldIfDue(due) {
        case .waiting, .refreshRequired:
            pipeWindowNotDue += 1
            return .nothingDue
        case .released:
            break
        }
        while let head = pendingVideoFrames.first, head.pts <= due + 1e-9 {
            guard isVideoFrameUsableAtOutputFloor(head, floor: outputMediaFloor) else {
                _ = pendingVideoFrames.removeFirst()
                pendingVideoContentSeconds = pendingVideoFrames.isEmpty
                    ? 0
                    : max(0, pendingVideoContentSeconds - max(0, head.duration))
                noteStaleVideoOutputRejection(head)
                continue
            }
            do {
                let result = try renderer.presentDemandFrame(
                    head, mediaTime: audioPresentationMediaTime,
                    playbackRate: Double(playbackRate)
                ) { [weak self, weak renderer] in
                    guard let self, let renderer,
                          (self.videoRender as? SampleBufferVideoRenderer) === renderer else { return }
                    self.presentDueVideoFrames()
                }
                switch result {
                case .waitingOnEnhancement:
                    return .waitingOnEnhancement
                case .blockedOnASBD:
                    pipeWindowNotReady += 1
                    pipeWindowRendererBlocked = true
                    return .blockedOnASBD
                case .recoveredNeedsRefeed:
                    pipeWindowNotReady += 1
                    applyDisplayPlayback(rate: effectiveDisplayRate)
                    return .blockedOnASBD
                case .terminalFault(let fault):
                    disarmPresentFeed()
                    publishRuntimeFault(fault, generation: generation)
                    return .nothingDue
                case .enqueued:
                    break
                }
                recordAdmittedVideoHead(head)
                burstEnqueued += 1
                didEnqueue = true
            } catch {
                pipeWindowNotReady += 1
                logPresentBackpressureIfNeeded(error)
                _ = pendingVideoFrames.removeFirst()
                pendingVideoContentSeconds = pendingVideoFrames.isEmpty
                    ? 0
                    : max(0, pendingVideoContentSeconds - max(0, head.duration))
                consecutiveVideoPresentErrorCount += 1
                if consecutiveVideoPresentErrorCount >= 3 {
                    disarmPresentFeed()
                    publishRuntimeFault(
                        MediaRuntimeFault(
                            subsystem: .videoRenderer,
                            stage: .render,
                            classification: .malfunction,
                            recoverability: .automaticSourceAwareReopen,
                            ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                            diagnostics: MediaRuntimeFaultDiagnostics(
                                label: "present-frame-error",
                                details: error.localizedDescription
                            )
                        ),
                        generation: generation
                    )
                    return .nothingDue
                }
                continue
            }
        }
        if !didEnqueue {
            pipeWindowNotDue += 1
        }
        return didEnqueue ? .enqueued : .nothingDue
    }

    func recordAdmittedVideoHead(_ head: MediaVideoFrame) {
        consecutiveVideoPresentErrorCount = 0
        tracing.mark(.firstVout, token: activeStartupTraceToken)
        _ = pendingVideoFrames.removeFirst()
        pendingVideoContentSeconds = pendingVideoFrames.isEmpty
            ? 0
            : max(0, pendingVideoContentSeconds - max(0, head.duration))
        presentedVideoFrameCount += 1
        pipeWindowPresentFrames += 1
        pipeWindowRendererAdmitted += 1
        pipeWindowRendererPTSAdvanced = true
        noteFlowStage(&flowPresentV, "presentV")
    }

    func reportLateVideoPresentBurst(firstPTS: TimeInterval?, enqueued: Int) {
        guard let firstPTS, enqueued >= 8 else { return }
        let lateness = audioPresentationMediaTime - firstPTS
        let now = ProcessInfo.processInfo.systemUptime
        guard lateness > 0.5, now - lastPresentBurstLogAt >= 1.0 else { return }
        lastPresentBurstLogAt = now
        diagnostics.log(
            "[PathA][gap] present-burst n=\(enqueued) " +
            "late=\(String(format: "%.2f", lateness))s " +
            "mt=\(String(format: "%.2f", clock.mediaTime)) " +
            "pendVAfter=\(pendingVideoFrames.count)"
        )
    }

    func presentDueVideoFrames() {
        guard !isVideoLaneWarmSuspended else { return }
        guard isPlaying, !isBuffering, !isSeekInFlight else { return }
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            pipeWindowPresentCalls += 1
            switch enqueueDueFramesWhileASBDReady(renderer) {
            case .waitingOnEnhancement:
                if presentFeedArmed { disarmPresentFeed() }
            case .blockedOnASBD, .enqueued:
                armPresentFeedIfNeeded()
            case .nothingDue:
                break
            }
            maybeReportPipeInstrument()
            return
        }
        pipeWindowPresentCalls += 1
        let due = videoPresentationDueTime
        switch releaseWarmVideoImageHoldIfDue(due) {
        case .waiting, .refreshRequired:
            pipeWindowNotDue += 1
            maybeReportPipeInstrument()
            return
        case .released:
            break
        }
        while let head = pendingVideoFrames.first, head.pts <= due + 1e-9 {
            guard isVideoFrameUsableAtOutputFloor(head, floor: outputMediaFloor) else {
                _ = pendingVideoFrames.removeFirst()
                pendingVideoContentSeconds = pendingVideoFrames.isEmpty
                    ? 0
                    : max(0, pendingVideoContentSeconds - max(0, head.duration))
                noteStaleVideoOutputRejection(head)
                continue
            }
            do {
                try videoRender.present(head)
                recordAdmittedVideoHead(head)
            } catch {
                logPresentBackpressureIfNeeded(error)
                break
            }
        }
        maybeReportPipeInstrument()
    }

    private func logPresentBackpressureIfNeeded(_ error: Error) {
        pipeWindowRendererBlocked = true
        if error.localizedDescription.lowercased().contains("failed") {
            pipeWindowRendererFailed = true
        }
        guard diagnostics.isCapturing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPresentNotReadyLogAt >= 2.0 else { return }
        lastPresentNotReadyLogAt = now
        let displayClock = (videoRender as? SampleBufferVideoRenderer)?.displayClockSeconds
        let headPTS = pendingVideoFrames.first?.pts
        diagnostics.log(
            "[PathA] video present back-pressure: \(error.localizedDescription) " +
            "pendingV=\(pendingVideoFrames.count) mediaTime=\(String(format: "%.2f", clock.mediaTime)) " +
            "presentationTime=\(String(format: "%.2f", audioPresentationMediaTime)) " +
            "displayClock=\(displayClock.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "headPTS=\(headPTS.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "dispRate=\(String(format: "%.2f", effectiveDisplayRate))"
        )
    }

    func applyDisplayPlayback(rate: Float, presentation: MediaAudioPresentationSnapshot? = nil) {
        let sample = presentation ?? sampleAudioPresentation()
        if hasAudioTrack {
            switch audioRender.outputAvailability {
            case .stopped, .pending, .unavailable:
                holdDisplayForAudioOutput()
                return
            case .available, .fillOnly: break
            }
        }
        audioOutputDisplayHold = nil
        if sample.timing.isAvailable {
            pinDisplay(rate: rate, time: sample.mediaTime, offset: sample.timing.contentTimeOffset)
        } else if let time = currentNativeDisplayTime {
            pinDisplay(rate: rate, time: time, offset: nil)
        }
    }

    var currentNativeDisplayTime: TimeInterval? {
        guard let renderer = videoRender as? SampleBufferVideoRenderer else { return nil }
        let time = renderer.displayClockSeconds
        return time.isFinite ? max(0, time) : nil
    }

    func pinDisplay(rate: Float, time: TimeInterval, offset: TimeInterval?) {
        guard time.isFinite else { return }
        videoRender.setDisplayPlayback(rate: max(0, rate), mediaTime: max(0, time))
        lastDisplayResyncPresentationTime = max(0, time)
        lastDisplayPresentationOffset = offset
        lastDisplayPinGeneration = generation
    }

    func holdDisplayForAudioOutput() {
        if audioOutputDisplayHold?.generation != generation { audioOutputDisplayHold = nil }
        if audioOutputDisplayHold == nil {
            let hasCurrentPin = lastDisplayPinGeneration == generation
                && lastDisplayResyncPresentationTime >= 0
            let previous: TimeInterval? = hasCurrentPin ? lastDisplayResyncPresentationTime : nil
            guard let time = currentNativeDisplayTime ?? previous else { return }
            audioOutputDisplayHold = (generation, time)
        }
        guard let hold = audioOutputDisplayHold else { return }
        pinDisplay(rate: 0, time: hold.time, offset: nil)
    }

    func clearDisplayOutputContinuity() {
        audioOutputDisplayHold = nil
        lastDisplayPinGeneration = nil
        lastDisplayPresentationOffset = nil
        lastDisplayResyncPresentationTime = -1
    }

    func resetDisplayTimeline(to time: TimeInterval) {
        clearDisplayOutputContinuity()
        pinDisplay(rate: 0, time: time, offset: nil)
    }

    func maybeResyncDisplaySlave() {
        guard isPlaying, !isBuffering, !isSeekInFlight else { return }
        let displayClock = (videoRender as? SampleBufferVideoRenderer)?.displayClockSeconds
        let sample = sampleAudioPresentation()
        if effectiveDisplayRate == 0 {
            applyDisplayPlayback(rate: 0, presentation: sample)
            return
        }
        guard sample.timing.isAvailable else { return }
        let t = sample.mediaTime
        let offset = sample.timing.contentTimeOffset
        if lastDisplayPresentationOffset.map({ abs(offset - $0) > 0.000_5 }) ?? true {
            applyPipelineDemand(presentation: sample)
            return
        }
        if let displayClock, displayClock.isFinite {
            if abs(displayClock - t) >= displayDriftResyncSeconds {
                applyPipelineDemand(presentation: sample)
            }
            return
        }
        if lastDisplayResyncPresentationTime < 0 {
            lastDisplayResyncPresentationTime = t
            return
        }
        if abs(t - lastDisplayResyncPresentationTime) >= displayResyncEpsilonSeconds {
            applyPipelineDemand(presentation: sample)
        }
    }

    func enqueuePendingVideoFrame(_ frame: MediaVideoFrame) {
        guard isVideoFrameUsableAtOutputFloor(frame, floor: outputMediaFloor) else {
            noteStaleVideoOutputRejection(frame)
            return
        }
        if holdsPassThroughVideo, !canAcceptAnotherPassThroughVideoPacket() {
            if pendingVideoFrames.isEmpty { return }
            let dropped = pendingVideoFrames.removeFirst()
            pendingVideoContentSeconds = max(0, pendingVideoContentSeconds - dropped.duration)
        }
        var idx = pendingVideoFrames.count
        while idx > 0, pendingVideoFrames[idx - 1].pts > frame.pts {
            idx -= 1
        }
        pendingVideoFrames.insert(frame, at: idx)
        pendingVideoContentSeconds += max(frame.duration, 0)
        (videoRender as? SampleBufferVideoRenderer)?.prewarmEnhancementIfNeeded(with: frame)
    }

    func resetOutputMediaFloor(to mediaTime: TimeInterval) {
        outputMediaFloor = max(0, mediaTime.isFinite ? mediaTime : 0)
        droppedPrerollVideoFrameCount = 0
        droppedPrerollAudioFrameCount = 0
        trimmedPrerollAudioSampleFrameCount = 0
        staleVideoOutputRejectionCount = 0
        staleVideoOutputRejectionMinPTS = nil
        staleVideoOutputRejectionMaxPTS = nil
        videoDecodeFrontierPTS = nil
        audioDecodeFrontierPTS = nil
    }

    @discardableResult
    func advanceOutputMediaFloor(
        to mediaTime: TimeInterval,
        reason: String
    ) -> Int {
        guard mediaTime.isFinite else { return 0 }
        let requestedFloor = max(0, mediaTime)
        guard requestedFloor > outputMediaFloor + outputMediaFloorEpsilon else {
            return 0
        }
        let previousFloor = outputMediaFloor
        outputMediaFloor = requestedFloor

        guard pendingVideoFrames.contains(where: {
            !isVideoFrameUsableAtOutputFloor($0, floor: requestedFloor)
        }) else {
            return 0
        }

        var removed = 0
        var retained: [MediaVideoFrame] = []
        retained.reserveCapacity(pendingVideoFrames.count)
        var retainedDuration: TimeInterval = 0
        for frame in pendingVideoFrames {
            if isVideoFrameUsableAtOutputFloor(frame, floor: requestedFloor) {
                retained.append(frame)
                retainedDuration += max(0, frame.duration)
            } else {
                removed += 1
                noteStaleVideoOutputRejection(frame)
            }
        }
        activeWarmDiagnostics?.bankedFramesExpired += removed
        pendingVideoFrames = retained
        pendingVideoContentSeconds = retainedDuration

        if removed > 0 {
            diagnostics.log(
                "[PathA][continuation] output floor advanced " +
                    "reason=\(reason) " +
                    "from=\(String(format: "%.3f", previousFloor)) " +
                    "to=\(String(format: "%.3f", requestedFloor)) " +
                    "rejected=\(removed) " +
                    "range=\(staleVideoOutputRejectionRangeDescription())"
            )
        }
        return removed
    }

    func isVideoFrameUsableAtOutputFloor(
        _ frame: MediaVideoFrame,
        floor: TimeInterval
    ) -> Bool {
        OutputFloorPolicy.isUsable(
            pts: frame.pts,
            duration: frame.duration,
            floor: floor,
            epsilon: outputMediaFloorEpsilon
        )
    }

    func noteStaleVideoOutputRejection(_ frame: MediaVideoFrame) {
        if staleVideoOutputRejectionCount < Int.max {
            staleVideoOutputRejectionCount += 1
        }
        guard frame.pts.isFinite else { return }
        staleVideoOutputRejectionMinPTS = min(
            staleVideoOutputRejectionMinPTS ?? frame.pts,
            frame.pts
        )
        staleVideoOutputRejectionMaxPTS = max(
            staleVideoOutputRejectionMaxPTS ?? frame.pts,
            frame.pts
        )
    }

    func staleVideoOutputRejectionRangeDescription() -> String {
        guard let minPTS = staleVideoOutputRejectionMinPTS,
              let maxPTS = staleVideoOutputRejectionMaxPTS else {
            return "n/a"
        }
        return String(format: "%.3f..%.3f", minPTS, maxPTS)
    }

    func shouldDropVideoBeforeOutputFloor(_ frame: MediaVideoFrame) -> Bool {
        !isVideoFrameUsableAtOutputFloor(frame, floor: outputMediaFloor)
    }

    func noteVideoDecodeFrontier(_ pts: TimeInterval) {
        guard pts.isFinite else { return }
        videoDecodeFrontierPTS = max(videoDecodeFrontierPTS ?? pts, pts)
    }

    func noteAudioDecodeFrontier(_ endPTS: TimeInterval) {
        guard endPTS.isFinite else { return }
        audioDecodeFrontierPTS = max(audioDecodeFrontierPTS ?? endPTS, endPTS)
    }

    var videoFrameQueueNeedsFill: Bool {
        if holdsPassThroughVideo {
            if !canAcceptAnotherPassThroughVideoPacket() { return false }
            return pendingVideoContentSeconds < min(videoFrameQueueHighWater, 0.5)
        }
        return pendingVideoContentSeconds < videoFrameQueueHighWater
    }

    func evaluateVideoStarvation() {
        guard isPlaying, !isSeekInFlight, !isBuffering,
              !isVideoLaneWarmSuspended,
              videoDecoderOpened, !demuxReachedEOF,
              let runway = queuedVideoRunway else {
            videoStarvedSince = nil
            return
        }
        guard runway <= Self.videoStarvationRunwayFloor, pendingVideoFrames.isEmpty else {
            videoStarvedSince = nil
            return
        }
        let now = ContinuousClock.now
        guard let since = videoStarvedSince else {
            videoStarvedSince = now
            return
        }
        guard since.duration(to: now) >= Self.videoStarvationConfirmWindow else { return }
        videoStarvedSince = nil
        bufferingForVideoStarvation = true
        isBuffering = true
        disarmPresentFeed()
        applyPipelineDemand()
        diagnostics.diagnostic(
            "[PathA] ⚠️ video starvation → buffering at t=\(String(format: "%.2f", clock.mediaTime)) " +
            "vQ=\(String(format: "%.2f", runway))s aQ=\(String(format: "%.2f", audioPacketQueue.contentSeconds))s " +
            "pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s"
        )
        onEvent?(.tick(
            mediaTime: clock.mediaTime,
            duration: clock.duration,
            buffered: bufferedTime
        ))
        onEvent?(.buffering)
        updateMultiConnectionPlayback()
        requestSupplyWake()
    }

    func videoStarvationHoldIsActive() -> Bool {
        if bufferingForVideoStarvation, !isBuffering {
            bufferingForVideoStarvation = false
        }
        return bufferingForVideoStarvation
    }

    func resolveVideoStarvationIfRecovered() {
        guard videoStarvationHoldIsActive(), !isSeekInFlight else { return }
        let runway = queuedVideoRunway ?? 0
        let recovered = runway >= min(videoPacketQueue.lowWater, videoPacketQueue.highWater)
        guard recovered || demuxReachedEOF else { return }
        bufferingForVideoStarvation = false
        isBuffering = false
        applyPipelineDemand()
        armPresentFeedIfNeeded()
        presentDueVideoFrames()
        diagnostics.log(
            "[PathA] video starvation cleared — resuming at " +
            "vQ=\(String(format: "%.2f", runway))s"
        )
        onEvent?(.playing)
        scheduleVideoDecodeIfNeeded()
    }

    static let videoStarvationRunwayFloor: TimeInterval = 0.001
    static let videoStarvationConfirmWindow: Duration = .milliseconds(300)

    func applyPipelineDemand(presentation: MediaAudioPresentationSnapshot? = nil) {
        applyDisplayPlayback(rate: effectiveDisplayRate, presentation: presentation)
        audioRender.playbackRate =
            isPlaying && !isSeekInFlight && !videoStarvationHoldIsActive()
            ? max(0, clock.playbackRate)
            : 0
    }
}
