import Foundation
import UIKit

extension MediaEngineSession {
    // MARK: - Session Stats & Pipe Field Helpers

    private func pipeField(
        _ key: String,
        _ value: String,
        force: Bool,
        omitted: inout Int
    ) -> String {
        if !force, pipeStickyFields[key] == value {
            omitted += 1
            return ""
        }
        pipeStickyFields[key] = value
        return "\(key)=\(value) "
    }

    var stats: MediaEngineStats {
        MediaEngineStats(
            multiConnection: helperTelemetry.value,
            bytesRead: bytesRead,
            networkBytesReceived: networkByteCounter.total,
            videoPackets: totalVideoPacketsIngested,
            videoPacketsDequeued: totalVideoPacketsDequeued,
            videoPacketsSubmitted: totalVideoPacketsSubmitted,
            videoInputContentSecondsConsumed: totalVideoInputContentSecondsConsumed,
            audioPackets: totalAudioPacketsIngested,
            pendingVideoFrames: pendingVideoFrames.count,
            pendingPCMSeconds: pendingAudioContentSeconds,
            mediaTime: clock.mediaTime,
            bufferedTime: bufferedTime,
            isBuffering: isBuffering,
            decodedVideoFrames: decodedVideoFrameCount,
            presentedVideoFrames: presentedVideoFrameCount,
            videoOutputPTSAdvanced: totalVideoOutputPTSAdvanced,
            decodedVideoFPS: decodedVideoFPS,
            presentedVideoFPS: presentedVideoFPS,
            videoWidth: knownVideoFrameWidth,
            videoHeight: knownVideoFrameHeight,
            pulledAudioFrames: pulledAudioFrameCount
        )
    }

    // MARK: - PiP Lifecycle & Presentation Continuity

    @discardableResult
    func startPiP() -> Bool {
        guard isAutomaticPiPEnabled,
              isPlaying,
              !hasEmittedEnded,
              activePiPEventBindingToken != nil else {
            diagnostics.log("[PathA] startPiP: capability disabled, not playing, or unbound")
            return false
        }
        if let pipHost = videoRender as? any MediaPiPLeaseEventSource {
            updatePiPPlaybackState()
            return pipHost.startPiP()
        }
        diagnostics.log("[PathA] startPiP: video renderer has no event-backed PiP")
        return false
    }

    func stopPiP() {
        (videoRender as? any MediaPiPLeaseEventSource)?.stopPiP()
    }

    var isPiPActive: Bool {
        (videoRender as? any MediaPiPLeaseEventSource)?.isPiPActive ?? false
    }

    func setObservedPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        observedPiPLeaseChangeHandler = handler
        if handler == nil {
            hasObservedPiPLease = false
            cancelPiPVideoResume()
        }
    }

    var currentPiPBindingGeneration: UInt64 {
        activePiPEventBindingToken?.generation ?? 0
    }

    func setPiPNativeTransitionHandler(
        _ handler: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    ) {
        pipNativeTransitionHandler = handler
    }

    func setPiPRestoreRequestHandler(
        _ handler: (@MainActor @Sendable (UInt64) -> Void)?
    ) {
        pipRestoreRequestHandler = handler
    }

    func completePiPRestore(token: UInt64, success: Bool) {
        (videoRender as? any MediaPiPLeaseEventSource)?.completePiPRestore(
            token: token,
            success: success
        )
    }

    func forceRetirePiP() {
        clearPiPEventSource()
    }

    var demandPresentationHealth: DemandPresentationHealth {
        if terminalVideoPreparationFailure != nil { return .decoderInvalid }
        if isVideoLaneWarmSuspended { return .warmSuspended }
        if runtimeFaultedGeneration == generation || !videoDecoderOpened {
            return .decoderInvalid
        }
        if hasObservedPiPLease {
            return (videoRender as? SampleBufferVideoRenderer)?.pipPresentationHealth
                ?? .missingSurface
        }
        return (videoRender as? SampleBufferVideoRenderer)?.demandPresentationHealth
            ?? .missingSurface
    }

    func notePiPEnvironmentWillResignActive() {
        guard pendingPiPPresentationSnapshot == nil,
              isReady,
              isPlaying,
              hasObservedPiPLease,
              let snapshot = makePiPPresentationContinuitySnapshot() else {
            return
        }
        pendingPiPPresentationSnapshot = snapshot
        diagnostics.log(
            "[PathA][PiP] environment snapshot session=\(snapshot.sessionGeneration) " +
                "owner=\(snapshot.ownerGeneration) binding=\(snapshot.bindingGeneration) " +
                "media=\(String(format: "%.3f", snapshot.mediaTime)) " +
                "decoder=\(snapshot.videoDecoderOpened ? 1 : 0) " +
                "progress=\(snapshot.presentationProgress.serial)"
        )
    }

    func abandonPendingPiPStart() {
        (videoRender as? any MediaPiPLeaseEventSource)?.abandonPendingPiPStart()
    }

    func reconcilePiPPresentationAfterActivation(
        renderGeneration: Int
    ) async -> Bool {
        guard let snapshot = pendingPiPPresentationSnapshot else { return true }
        pendingPiPPresentationSnapshot = nil

        guard isReady,
              isPlaying,
              hasObservedPiPLease,
              snapshot.sessionGeneration == runtimeGeneration,
              snapshot.ownerGeneration == activeOwnerGeneration,
              snapshot.bindingGeneration == currentPiPBindingGeneration,
              snapshot.bindingGeneration != 0,
              let renderer = videoRender as? SampleBufferVideoRenderer,
              let current = makePiPPresentationContinuitySnapshot() else {
            diagnostics.log("[PathA][PiP] activation snapshot stale or no longer playable")
            return true
        }

        let audioDelta = current.mediaTime - snapshot.mediaTime
        let recentPresentationProgress = DemandPresentationProgressPolicy.isRecent(
            current: current.presentationProgress,
            since: snapshot.presentationProgress,
            nowUptime: ProcessInfo.processInfo.systemUptime
        )
        let decoderResourceMissing = !current.videoDecoderOpened
            || !snapshot.videoDecoderOpened
        func isRendererFaulted(_ health: DemandPresentationHealth) -> Bool {
            switch health {
            case .needsFlush, .rendererFailed, .decoderInvalid:
                return true
            case .visible, .attachedButUnproven, .warmSuspended, .missingSurface:
                return false
            }
        }
        let rendererFaulted = isRendererFaulted(current.rendererHealth)
            || isRendererFaulted(snapshot.rendererHealth)
        let readinessLost = current.rendererHealth == .missingSurface
            || snapshot.rendererHealth == .missingSurface
        let displayClockStalled: Bool = {
            guard audioDelta >= 0.25,
                  snapshot.displayClockSeconds.isFinite,
                  current.displayClockSeconds.isFinite else {
                return false
            }
            return abs(current.displayClockSeconds - snapshot.displayClockSeconds) < 0.05
        }()
        let noVideoProgress = audioDelta >= 0.25
            && !recentPresentationProgress
        let needsRepair = rendererFaulted
            || decoderResourceMissing
            || readinessLost
            || noVideoProgress
            || displayClockStalled
        guard needsRepair else {
            diagnostics.log(
                "[PathA][PiP] activation healthy — no repair " +
                    "audioΔ=\(String(format: "%.3f", max(0, audioDelta))) " +
                    "decoder=\(current.videoDecoderOpened ? 1 : 0) " +
                    "recent=\(recentPresentationProgress ? 1 : 0)"
            )
            return true
        }

        diagnostics.log(
            "[PathA][PiP] activation reconcile " +
                "reason=\(decoderResourceMissing ? "decoder" : rendererFaulted ? "renderer" : readinessLost ? "readiness" : "no-progress") " +
                "audioΔ=\(String(format: "%.3f", max(0, audioDelta))) " +
                "decoder=\(current.videoDecoderOpened ? 1 : 0) " +
                "recent=\(recentPresentationProgress ? 1 : 0)"
        )
        let target = audioPresentationMediaTime
        var rendererReady = renderer.reconcilePiPPresentation(
            mediaTime: target,
            rate: effectiveDisplayRate
        )
        if isVideoLaneWarmSuspended {
            guard rendererReady,
                  await resumeWarmVideoLaneForActivePiP(
                      renderGeneration: renderGeneration
                  ) else {
                return false
            }
            return true
        }
        if decoderResourceMissing || !rendererReady {
            guard await recreateVideoDecoderForPresentation() else { return false }
            if !rendererReady {
                rendererReady = renderer.reconcilePiPPresentation(
                    mediaTime: audioPresentationMediaTime,
                    rate: effectiveDisplayRate
                )
            }
        }
        guard rendererReady else { return false }

        applyPipelineDemand()
        updatePiPPlaybackState()
        armPresentFeedIfNeeded()
        presentDueVideoFrames()
        startSupplyLoop()
        requestSupplyWake()
        scheduleVideoDecodeIfNeeded()
        return true
    }

    func currentDisplayedFrameForTransition() -> UIImage? {
        guard let renderer = videoRender as? SampleBufferVideoRenderer else {
            return nil
        }
        return renderer.currentDisplayedImage()
    }

    func currentDisplayedFrameCaptureSource() -> DisplayedFrameCaptureSource? {
        guard let renderer = videoRender as? SampleBufferVideoRenderer else {
            return nil
        }
        return renderer.currentDisplayedFrameCaptureSource()
    }

    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage? {
        guard let renderer = videoRender as? SampleBufferVideoRenderer else {
            return nil
        }
        return renderer.currentAmbientSampleImage(targetSize: targetSize)
    }

    func thumbnailAtCurrentTime() async -> UIImage? {
        currentDisplayedFrameForTransition()
    }

    private func makePiPPresentationContinuitySnapshot()
        -> PiPPresentationContinuitySnapshot? {
        guard let renderer = videoRender as? SampleBufferVideoRenderer else {
            return nil
        }
        return PiPPresentationContinuitySnapshot(
            sessionGeneration: runtimeGeneration,
            ownerGeneration: activeOwnerGeneration,
            bindingGeneration: currentPiPBindingGeneration,
            mediaTime: audioPresentationMediaTime,
            displayClockSeconds: renderer.displayClockSeconds,
            videoDecoderOpened: videoDecoderOpened,
            presentationProgress: renderer.presentationProgressWitness,
            rendererHealth: renderer.pipPresentationHealth
        )
    }

    func setPresentationProofHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    ) {
        presentationProofHandler = handler
        guard let renderer = videoRender as? SampleBufferVideoRenderer else { return }
        renderer.setPresentationProofHandler { [weak self] renderGeneration, mediaTime, ready in
            guard let self else { return }
            self.completeWarmVideoImageHoldIfProved(
                renderGeneration: renderGeneration,
                mediaTime: mediaTime,
                rendererReady: ready
            )
            if ready { self.noteWarmPresentationProof(renderGeneration: renderGeneration, mediaTime: mediaTime) }
            self.presentationProofHandler?(.init(
                sessionGeneration: self.runtimeGeneration,
                renderGeneration: renderGeneration,
                mediaTime: mediaTime,
                rendererReady: ready
            ))
        }
    }

    func setPresentationFailureHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    ) {
        onPresentationFailure = handler
    }

    func noteInlineAttachment(
        renderGeneration: Int,
        isVisible: Bool,
        boundsUsable: Bool
    ) {
        (videoRender as? SampleBufferVideoRenderer)?.noteInlineAttachment(
            renderGeneration: renderGeneration,
            isVisible: isVisible,
            boundsUsable: boundsUsable
        )
    }

    func refreshPresentationImageHold() {
        (videoRender as? SampleBufferVideoRenderer)?.refreshPresentationImageHold()
    }

    func setAutomaticPiPEnabled(_ enabled: Bool) {
        if isAutomaticPiPEnabled == enabled {
            if enabled, activePiPEventBindingToken == nil {
                bindPiPEventSource()
            }
            return
        }

        isAutomaticPiPEnabled = enabled
        if enabled {
            bindPiPEventSource()
        } else {
            clearPiPEventSource()
        }
        diagnostics.log(
            "[PathA] PiP capability transition enabled=" +
            (enabled ? "1" : "0") +
            " binding=" +
            String(activePiPEventBindingToken?.generation ?? 0)
        )
    }

    func updateVideoLivenessContext(_ context: DemandVideoLivenessContext?) {
        guard videoLivenessContext != context else { return }
        videoLivenessContext = context
        resetVideoLivenessState(resetStartup: false)
    }

    func updatePiPPlaybackState() {
        guard let pipHost = videoRender as? SampleBufferVideoRenderer else { return }
        pipHost.updatePiPPlaybackState(
            currentTime: clock.mediaTime,
            duration: clock.duration,
            isPlaying: isPlaying && !hasEmittedEnded
        )
    }

    func updateObservedPiPLease(_ active: Bool) {
        guard hasObservedPiPLease != active else { return }
        hasObservedPiPLease = active
        if !active {
            pendingPiPPresentationSnapshot = nil
            cancelPiPVideoResume()
        }
        observedPiPLeaseChangeHandler?(active)
        if active {
            schedulePiPVideoResumeIfNeeded()
            scheduleVideoDecodeIfNeeded()
        }
    }

    func finishPiPVideoResume(_ resumeID: UInt64) {
        guard activePiPVideoResumeID == resumeID else { return }
        activePiPVideoResumeID = nil
        pipVideoResumeTask = nil
    }

    func cancelPiPVideoResume() {
        pipVideoResumeTask?.cancel()
        pipVideoResumeTask = nil
        activePiPVideoResumeID = nil
    }

    func schedulePiPVideoResumeIfNeeded(
        renderGeneration requestedRenderGeneration: Int? = nil
    ) {
        guard hasObservedPiPLease,
              isPlaying,
              isVideoLaneWarmSuspended,
              let token = activeVideoSuspendToken,
              let renderer = videoRender as? SampleBufferVideoRenderer,
              pipVideoResumeTask == nil else {
            return
        }

        nextPiPVideoResumeID &+= 1
        if nextPiPVideoResumeID == 0 { nextPiPVideoResumeID = 1 }
        let resumeID = nextPiPVideoResumeID
        activePiPVideoResumeID = resumeID
        let expectedSessionGeneration = runtimeGeneration
        let expectedEngineGeneration = generation
        let expectedOwnerGeneration = activeOwnerGeneration
        let expectedBindingGeneration = currentPiPBindingGeneration
        let renderGeneration = requestedRenderGeneration
            ?? renderer.currentPresentationRenderGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.finishPiPVideoResume(resumeID) }
            guard self.activePiPVideoResumeID == resumeID,
                  self.hasObservedPiPLease,
                  self.isPlaying,
                  self.activeVideoSuspendToken == token,
                  self.runtimeGeneration == expectedSessionGeneration,
                  self.generation == expectedEngineGeneration,
                  self.activeOwnerGeneration == expectedOwnerGeneration,
                  self.currentPiPBindingGeneration == expectedBindingGeneration,
                  self.isVideoLaneWarmSuspended else {
                return false
            }
            let result = await self.prepareVideoLaneForForeground(token)
            guard !Task.isCancelled,
                  self.activePiPVideoResumeID == resumeID,
                  self.hasObservedPiPLease,
                  self.isPlaying,
                  self.activeVideoSuspendToken == token,
                  self.runtimeGeneration == expectedSessionGeneration,
                  self.generation == expectedEngineGeneration,
                  self.activeOwnerGeneration == expectedOwnerGeneration,
                  self.currentPiPBindingGeneration == expectedBindingGeneration,
                  self.isVideoLaneWarmSuspended else {
                return false
            }
            guard result == .prepared else {
                diagnostics.log(
                    "[PathA][PiP] lease video resume preparation failed " +
                        "result=\(String(describing: result)) source-reopen=0"
                )
                return false
            }
            let resumed = await self.resumeVideoLane(
                token,
                renderGeneration: renderGeneration,
                destination: .pictureInPicture
            )
            diagnostics.log(
                "[PathA][PiP] lease video resume result=\(resumed ? 1 : 0) " +
                    "warm=\(self.isVideoLaneWarmSuspended ? 1 : 0) " +
                    "source-reopen=0"
            )
            return resumed
        }
        pipVideoResumeTask = task
    }

    func resumeWarmVideoLaneForActivePiP(
        renderGeneration: Int
    ) async -> Bool {
        guard hasObservedPiPLease, isPlaying else { return false }
        guard isVideoLaneWarmSuspended else { return true }
        schedulePiPVideoResumeIfNeeded(renderGeneration: renderGeneration)
        guard let task = pipVideoResumeTask else { return false }
        return await task.value
    }

    func bindPiPEventSource() {
        guard isAutomaticPiPEnabled,
              activePiPEventBindingToken == nil else {
            return
        }
        guard let pipSource = videoRender as? any MediaPiPLeaseEventSource else {
            return
        }
        let bindingToken = replacePiPEventBinding()
        if let pipHost = videoRender as? SampleBufferVideoRenderer {
            pipHost.setPiPTransportDelegate(self)
        }
        pipSource.setPiPNativeTransitionHandler { [weak self] event in
            guard let self, self.activePiPEventBindingToken == bindingToken else {
                return
            }
            self.pipNativeTransitionHandler?(.init(
                event: event,
                bindingGeneration: bindingToken.generation
            ))
        }
        pipSource.setPiPRestoreRequestHandler { [weak self] token in
            guard let self, self.activePiPEventBindingToken == bindingToken else {
                return
            }
            self.pipRestoreRequestHandler?(token)
        }
        pipSource.setPiPLeaseChangeHandler { [weak self] active in
            guard let self, self.activePiPEventBindingToken == bindingToken else {
                return
            }
            self.updateObservedPiPLease(active)
        }
    }

    func replacePiPEventBinding() -> PiPEventBindingToken {
        nextPiPEventBindingGeneration &+= 1
        let token = PiPEventBindingToken(generation: nextPiPEventBindingGeneration)
        activePiPEventBindingToken = token
        return token
    }

    func invalidatePiPEventBinding() {
        nextPiPEventBindingGeneration &+= 1
        activePiPEventBindingToken = nil
    }

    func clearPiPEventSource() {
        pendingPiPPresentationSnapshot = nil
        cancelPiPVideoResume()
        guard activePiPEventBindingToken != nil else {
            updateObservedPiPLease(false)
            return
        }
        if let pipSource = videoRender as? any MediaPiPLeaseEventSource {
            pipSource.stopPiP()
            updateObservedPiPLease(false)
            pipSource.setPiPLeaseChangeHandler(nil)
            pipSource.setPiPNativeTransitionHandler(nil)
            pipSource.setPiPRestoreRequestHandler(nil)
        }
        if let pipHost = videoRender as? SampleBufferVideoRenderer {
            pipHost.setPiPTransportDelegate(nil)
        }
        invalidatePiPEventBinding()
        updateObservedPiPLease(false)
    }

    // MARK: - EnginePiPTransportDelegate

    func setPlayingFromPiP(_ playing: Bool) {
        nextPiPTransportOperationID &+= 1
        if nextPiPTransportOperationID == 0 { nextPiPTransportOperationID = 1 }
        let operation = nextPiPTransportOperationID
        let sessionGeneration = runtimeGeneration
        let bindingGeneration = activePiPEventBindingToken?.generation
        onPiPTransportEvent?(.transportIntent(
            operation: operation,
            playing: playing,
            sessionGeneration: sessionGeneration,
            pipBindingGeneration: bindingGeneration,
            ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0
        ))
        if playing {
            play()
        } else {
            pause()
        }
    }

    func skipFromPiP(
        by interval: TimeInterval,
        completion: EnginePiPTransportCompletion
    ) {
        guard interval.isFinite, interval != 0 else {
            diagnostics.log("[PathA] PiP skip ignored — invalid interval")
            completion.complete()
            return
        }
        guard duration > 0, duration.isFinite else {
            diagnostics.log("[PathA] PiP skip ignored — live timeline is non-seekable")
            completion.complete()
            return
        }

        nextPiPTransportOperationID &+= 1
        if nextPiPTransportOperationID == 0 { nextPiPTransportOperationID = 1 }
        let operation = nextPiPTransportOperationID
        guard let requestBindingGeneration = activePiPEventBindingToken?.generation,
              hasObservedPiPLease, activeOwnerGeneration != 0 else {
            completion.complete()
            return
        }
        let requestOwnerGeneration = activeOwnerGeneration
        let requestOwnerLeaseGeneration = videoLivenessContext?.ownerLeaseGeneration ?? 0
        guard requestOwnerLeaseGeneration != 0 else {
            completion.complete()
            return
        }
        let currentAdmission: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.activeOwnerGeneration == requestOwnerGeneration
                && self.activePiPEventBindingToken?.generation == requestBindingGeneration
                && self.hasObservedPiPLease
                && self.videoLivenessContext?.ownerLeaseGeneration == requestOwnerLeaseGeneration
                && self.runtimeFaultedGeneration != self.generation
        }
        let request = EnginePiPSeekRequest(
            interval: interval,
            ownerGeneration: requestOwnerGeneration,
            currentAdmission: currentAdmission,
            settlement: { [weak self] succeeded in
                defer { completion.complete() }
                guard succeeded, currentAdmission(), let self else { return }
                let actualPosition = self.clock.mediaTime
                guard actualPosition.isFinite else { return }
                self.onPiPTransportEvent?(.seekSettled(
                    operation: operation,
                    position: max(0, actualPosition),
                    sessionGeneration: self.runtimeGeneration,
                    pipBindingGeneration: requestBindingGeneration,
                    ownerLeaseGeneration: requestOwnerLeaseGeneration
                ))
            }
        )
        guard let onPiPSkipRequest else {
            request.finish(success: false)
            return
        }
        onPiPSkipRequest(request)
    }

    // MARK: - Video Liveness & Pipe Diagnostics

    private func resetVideoLivenessWindowCounters() {
        pipeWindowVideoPacketsDequeued = 0
        pipeWindowVideoPacketsSubmitted = 0
        pipeWindowVideoInputSeconds = 0
        pipeWindowVideoBytesRead = 0
        pipeWindowVideoPacketsIngested = 0
        pipeWindowVideoOutputFrames = 0
        pipeWindowVideoOutputPTSAdvanced = false
        pipeWindowVideoOutputPTSDelta = nil
        pipeWindowVideoCallbacks = 0
        pipeWindowRendererAdmitted = 0
        pipeWindowRendererPTSAdvanced = false
        pipeWindowRendererBlocked = false
        pipeWindowRendererFailed = false
    }

    func resetVideoLivenessState(resetStartup: Bool) {
        videoLivenessDetector.reset()
        videoLivenessWindowIndex = 0
        videoLivenessPacketDurations.removeAll()
        videoLivenessOutputPeriods.removeAll()
        videoLivenessPTSProgress.reset()
        if resetStartup {
            videoLivenessStartupUptime = 0
        }
        resetVideoLivenessWindowCounters()
        resetPipeInstrumentWindow()
    }

    func resetPipeInstrumentWindow(clearSample: Bool = true) {
        pipeWindowStartUptime = ProcessInfo.processInfo.systemUptime
        pipeWindowStartMediaTime = clock.mediaTime
        pipeWindowDecodeFrames = 0
        pipeWindowPresentFrames = 0
        pipeWindowPresentCalls = 0
        pipeWindowPumps = 0
        pipeWindowParks = 0
        pipeWindowWakes = 0
        pipeWindowNotDue = 0
        pipeWindowNotReady = 0
        resetVideoLivenessWindowCounters()
        if clearSample {
            decodedVideoFPS = 0
            presentedVideoFPS = 0
            pipeStickyFields.removeAll(keepingCapacity: true)
        }
        flowIngestV.resetWindow()
        flowIngestA.resetWindow()
        flowDecInV.resetWindow()
        flowDecOutV.resetWindow()
        flowPresentV.resetWindow()
        flowClock.resetWindow()
        flowPCM.resetWindow()
        flowWindowMaxPacketAgeMs = 0
        flowWindowMaxDecodeMs = 0
        relayDrainCount = 0
    }

    func resetFlowGapTracking() {
        flowIngestV.resetAll()
        flowIngestA.resetAll()
        flowDecInV.resetAll()
        flowDecOutV.resetAll()
        flowPresentV.resetAll()
        flowClock.resetAll()
        flowPCM.resetAll()
        flowWindowMaxPacketAgeMs = 0
        flowWindowMaxDecodeMs = 0
        flowLastIngestVideoPTS = -1
        flowLastIngestAudioPTS = -1
    }

    func ingestStarvationFloor(_ queue: ContentSecondQueue) -> TimeInterval {
        max(queue.lowWater * 0.5, 0.25)
    }

    func noteFlowStage(
        _ stage: inout FlowGapStage,
        _ name: String,
        starvingBelow floor: TimeInterval? = nil,
        depth: TimeInterval = 0
    ) {
        guard diagnostics.isCapturing else { return }
        guard let gap = stage.note(now: ContinuousClock.now, stallMs: flowStallThresholdMs),
              isPlaying, !isSeekInFlight else { return }
        if let floor, !isBuffering, depth >= floor { return }
        diagnostics.log(
            "[PathA][gap] stall-end stage=\(name) gap=\(gap)ms " +
            "mt=\(String(format: "%.2f", clock.mediaTime)) " +
            "vQ=\(String(format: "%.1f", videoPacketQueue.contentSeconds)) " +
            "aQ=\(String(format: "%.1f", audioPacketQueue.contentSeconds)) " +
            "pendV=\(pendingVideoFrames.count) " +
            "pcm=\(String(format: "%.2f", pendingAudioContentSeconds)) " +
            "buf=\(isBuffering ? 1 : 0)"
        )
    }

    func maybeReportPipeInstrument() {
        guard isPlaying else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if pipeWindowStartUptime <= 0 {
            resetPipeInstrumentWindow()
            return
        }
        let elapsed = now - pipeWindowStartUptime
        guard elapsed >= 1.0 else { return }
        let mtDelta = clock.mediaTime - pipeWindowStartMediaTime
        let mtRate = elapsed > 0 ? mtDelta / elapsed : 0
        guard let frameRates = MediaFrameRateSample.calculate(
            decodedFrames: pipeWindowDecodeFrames,
            presentedFrames: pipeWindowPresentFrames,
            elapsed: elapsed
        ) else {
            resetPipeInstrumentWindow()
            return
        }
        let decFps = frameRates.decodedFPS
        let presFps = frameRates.presentedFPS
        decodedVideoFPS = decFps
        presentedVideoFPS = presFps
        if diagnostics.isCapturing {
            let calls = Double(pipeWindowPresentCalls) / elapsed
            let headPTS = pendingVideoFrames.first?.pts
            let due = videoPresentationDueTime
            let engineAudio = audioRender as? EngineAudioRenderer
            let renderDiagnostics = engineAudio?.renderDiagnosticsSnapshot
            let displayClock = (videoRender as? SampleBufferVideoRenderer)?.displayClockSeconds
            let displayClockDelta: TimeInterval? = {
                guard let displayClock, displayClock.isFinite else { return nil }
                return displayClock - audioPresentationMediaTime
            }()
            let avDeltaField = displayClockDelta.map { String(format: "%+.3f", $0) } ?? "n/a"
            if !wasCapturingLastWindow {
                pipeStickyFields.removeAll(keepingCapacity: true)
            }
            wasCapturingLastWindow = true
            pipeWindowIndex &+= 1
            let isFreezeWindow = isPlaying && !isBuffering
                && pipeWindowPresentFrames == 0 && presentedVideoFrameCount > 0
            let fullLine = isFreezeWindow || pipeWindowIndex % 10 == 1
            var omitted = 0
            let presentMediaTime = audioPresentationMediaTime
            let mediaTime = clock.mediaTime
            let callbacks = renderDiagnostics?.callbackCount ?? 0
            let renderedFrames = renderDiagnostics?.renderedFrameCount ?? 0
            let callbackDelta = callbacks >= lastAudioCallbackCount
                ? callbacks - lastAudioCallbackCount
                : callbacks
            let renderedFrameDelta = renderedFrames >= lastAudioRenderedFrameCount
                ? renderedFrames - lastAudioRenderedFrameCount
                : renderedFrames
            lastAudioCallbackCount = callbacks
            lastAudioRenderedFrameCount = renderedFrames

            var line = "[PathA][pipe] decFps=\(String(format: "%.0f", decFps)) " +
                "presFps=\(String(format: "%.0f", presFps)) " +
                "mtRate=\(String(format: "%.2f", mtRate))x " +
                "avDelta=\(avDeltaField)s " +
                "vdec=\(videoDecoderOpened ? 1 : 0) " +
                "pendV=\(pendingVideoFrames.count) " +
                "vQ=\(String(format: "%.1f", videoPacketQueue.contentSeconds))s " +
                "aQ=\(String(format: "%.1f", audioPacketQueue.contentSeconds))s " +
                "pcmSec=\(MediaQueueFillSnapshot.seconds(pendingAudioContentSeconds)) " +
                "vFramesSec=\(MediaQueueFillSnapshot.seconds(pendingVideoContentSeconds)) " +
                "rBuf=\(MediaQueueFillSnapshot.seconds(engineAudio?.renderRingContentSeconds)) " +
                "srcUF=\(engineAudio.map { String($0.sourceUnderflowCount) } ?? "n/a") " +
                "gen=\(generation) seek=\(isSeekInFlight ? 1 : 0) " +
                "head=\(headPTS.map { String(format: "%.2f", $0) } ?? "-") " +
                "mt=\(String(format: "%.2f", mediaTime)) "
            line += pipeField("calls/s", String(format: "%.0f", calls), force: fullLine, omitted: &omitted)
            line += pipeField("buf", isBuffering ? "1" : "0", force: fullLine, omitted: &omitted)
            line += pipeField("pumps", "\(pipeWindowPumps)", force: fullLine, omitted: &omitted)
            line += pipeField("parks", "\(pipeWindowParks)", force: fullLine, omitted: &omitted)
            line += pipeField("wakes", "\(pipeWindowWakes)", force: fullLine, omitted: &omitted)
            line += pipeField("notDue", "\(pipeWindowNotDue)", force: fullLine, omitted: &omitted)
            line += pipeField("notRdy", "\(pipeWindowNotReady)", force: fullLine, omitted: &omitted)
            line += pipeField(
                "aGap", "\(insertedAudioTimelineGapSampleFrameCount)",
                force: fullLine, omitted: &omitted
            )
            line += pipeField(
                "aOv", "\(droppedAudioTimelineOverlapSampleFrameCount)",
                force: fullLine, omitted: &omitted
            )
            line += pipeField("srcCB/s", "\(callbackDelta)", force: fullLine, omitted: &omitted)
            line += pipeField("srcF/s", "\(renderedFrameDelta)", force: fullLine, omitted: &omitted)
            line += pipeField(
                "srcNF", "\(renderDiagnostics?.sourceNonFiniteSampleCount ?? 0)",
                force: fullLine, omitted: &omitted
            )
            line += pipeField(
                "srcOR", "\(renderDiagnostics?.sourceOverrangeSampleCount ?? 0)",
                force: fullLine, omitted: &omitted
            )
            line += pipeField(
                "srcPeak", String(format: "%.3f", renderDiagnostics?.sourcePeakAbs ?? 0),
                force: fullLine, omitted: &omitted
            )
            line += pipeField("armed", presentFeedArmed ? "1" : "0", force: fullLine, omitted: &omitted)
            line += pipeField(
                "audioOffset", String(format: "%.4f", audioRender.contentTimePresentationOffset),
                force: fullLine, omitted: &omitted
            )
            if fullLine {
                line += "present=\(String(format: "%.2f", presentMediaTime)) "
            }
            if fullLine {
                line += "due=\(String(format: "%.2f", due)) "
            }
            if omitted > 0 {
                line += "(+\(omitted) unchanged)"
            }
            diagnostics.log(line)
            let flowNow = ContinuousClock.now
            diagnostics.log(
                "[PathA][gap] inV=\(flowIngestV.windowField(now: flowNow)) " +
                "inA=\(flowIngestA.windowField(now: flowNow)) " +
                "decIn=\(flowDecInV.windowField(now: flowNow)) " +
                "decOut=\(flowDecOutV.windowField(now: flowNow)) " +
                "pres=\(flowPresentV.windowField(now: flowNow)) " +
                "clk=\(flowClock.windowField(now: flowNow)) " +
                "pcm=\(flowPCM.windowField(now: flowNow)) " +
                "age=\(flowWindowMaxPacketAgeMs)ms relayDrains=\(relayDrainCount) " +
                "dec=\(flowWindowMaxDecodeMs)ms"
            )
            if isFreezeWindow {
                diagnostics.log(
                    "[PathA][gap] FREEZE mtΔ=\(String(format: "%.2f", mtDelta))s " +
                    "pcmSec=\(String(format: "%.2f", pendingAudioContentSeconds)) " +
                    "lastInV=\(String(format: "%.2f", flowLastIngestVideoPTS)) " +
                    "lastInA=\(String(format: "%.2f", flowLastIngestAudioPTS)) " +
                    "eof=\(demuxReachedEOF ? 1 : 0)"
                )
            }
        }
        evaluateVideoLivenessWindow(elapsed: elapsed)
        resetPipeInstrumentWindow(clearSample: false)
    }

    private func evaluateVideoLivenessWindow(elapsed: TimeInterval) {
        guard let context = videoLivenessContext,
              generation > 0,
              activeOwnerGeneration > 0 else {
            return
        }

        let renderer: DemandLivenessRenderer
        switch videoRender.demandLivenessRenderer {
        case .needsFlush:
            renderer = .needsFlush
        case .failed:
            renderer = .failed
        case .backPressure:
            renderer = .backPressure
        case .ready where pipeWindowRendererFailed:
            renderer = .failed
        case .ready where pipeWindowRendererBlocked || pipeWindowNotReady > 0:
            renderer = .backPressure
        case .ready:
            renderer = .ready
        }
        let seek: DemandLivenessSeekPhase
        if isSeekInFlight {
            seek = outputMediaFloor > outputMediaFloorEpsilon ? .preroll : .seeking
        } else {
            seek = context.seek
        }
        let eof: DemandLivenessEOF
        let queuesDrained = videoPackets.isEmpty
            && residualVideoPackets.isEmpty
            && pendingVideoFrames.isEmpty
            && videoPacketQueue.contentSeconds < 0.000_5
            && audioPackets.isEmpty
            && residualAudioPackets.isEmpty
            && audioPacketQueue.contentSeconds < 0.000_5
            && pendingAudioContentSeconds < 0.000_5
        if clock.duration > 0,
           hasEmittedEnded || (demuxReachedEOF && queuesDrained) {
            eof = .finiteEOFDrained
        } else if context.source.mode == .live {
            eof = .liveOpenEnded
        } else {
            eof = .notEOF
        }
        let startupElapsed = videoLivenessStartupUptime > 0
            ? max(0, ProcessInfo.processInfo.systemUptime - videoLivenessStartupUptime)
            : 0
        let input = DemandLivenessInputDelta(
            videoPacketsDequeued: pipeWindowVideoPacketsDequeued,
            submittedPackets: pipeWindowVideoPacketsSubmitted,
            consumedVideoSeconds: pipeWindowVideoInputSeconds,
            bytesRead: pipeWindowVideoBytesRead,
            pumpCalls: pipeWindowPumps,
            ingestedPackets: pipeWindowVideoPacketsIngested,
            emptyPump: pipeWindowPumps > 0 && pipeWindowVideoPacketsDequeued == 0,
            segmentProgress: false
        )
        let output = DemandLivenessOutputDelta(
            successfulCallbacks: pipeWindowVideoCallbacks,
            outputFrames: pipeWindowVideoOutputFrames,
            outputPTSAdvanced: pipeWindowVideoOutputPTSAdvanced,
            outputPTSDelta: pipeWindowVideoOutputPTSDelta
        )
        let delivery = DemandLivenessDeliveryDelta(
            admittedFrames: pipeWindowRendererAdmitted,
            presentedFrames: pipeWindowRendererAdmitted,
            admittedPTSAdvanced: pipeWindowRendererPTSAdvanced,
            presentedPTSAdvanced: pipeWindowRendererPTSAdvanced,
            renderer: renderer,
            displayClockAdvanced: false
        )
        let window = DemandLivenessWindow(
            windowIndex: videoLivenessWindowIndex,
            durationSeconds: elapsed,
            sessionGeneration: runtimeGeneration,
            ownerGeneration: activeOwnerGeneration,
            ownerLeaseGeneration: context.ownerLeaseGeneration,
            source: context.source,
            appState: context.appState,
            intent: context.intent,
            lifecycle: context.lifecycle,
            seek: seek,
            isReady: isReady,
            isBuffering: isBuffering,
            hasVideoTrack: videoDecoderOpened,
            canAutoRevive: context.canAutoRevive,
            startupElapsedSeconds: startupElapsed,
            input: input,
            output: output,
            delivery: delivery,
            mediaTimeDelta: clock.mediaTime - pipeWindowStartMediaTime,
            renderedContentDelta: 0,
            compressedRunwaySeconds: videoPacketQueue.contentSeconds,
            decodedRunwaySeconds: pendingVideoContentSeconds,
            audioRunwaySeconds: pendingAudioContentSeconds,
            eof: eof,
            observedPiPLease: context.observedPiPLease,
            expectedFramePeriodSeconds: stableVideoFramePeriod(),
            terminalState: context.terminalState
        )
        videoLivenessWindowIndex &+= 1
        let step = videoLivenessDetector.observe(window, policy: videoLivenessPolicy)
        switch step.decision {
        case .emit(let fault):
            publishRuntimeFault(fault, generation: generation)
        case .diagnostic(let diagnostic):
            if diagnostics.isCapturing {
                diagnostics.log(
                    "[PathA][liveness] diagnostic=\(diagnostic.rawValue) " +
                    "window=\(window.windowIndex) dq=\(window.input.videoPacketsDequeued) " +
                    "out=\(window.output.outputFrames)"
                )
            }
        case .hold, .observe:
            break
        }
    }

    private func stableVideoFramePeriod() -> TimeInterval? {
        var samples: [TimeInterval] = []
        samples.reserveCapacity(videoLivenessPacketDurations.count + videoLivenessOutputPeriods.count)
        videoLivenessPacketDurations.appendPositiveFinite(into: &samples)
        videoLivenessOutputPeriods.appendPositiveFinite(into: &samples)
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    func noteVideoLivenessOutput(_ frame: MediaVideoFrame) {
        noteVideoLivenessOutput(pts: frame.pts)
    }

    func noteVideoLivenessOutput(pts: TimeInterval) {
        pipeWindowVideoOutputFrames += 1
        switch videoLivenessPTSProgress.observe(pts) {
        case .invalid, .noProgress:
            return
        case .advanced(let delta):
            pipeWindowVideoOutputPTSAdvanced = true
            totalVideoOutputPTSAdvanced = true
            guard let delta else { return }
            pipeWindowVideoOutputPTSDelta = max(
                pipeWindowVideoOutputPTSDelta ?? 0,
                delta
            )
            videoLivenessOutputPeriods.append(delta)
        }
    }

    func invalidateFrameStats() {
        resetPipeInstrumentWindow()
    }
}
