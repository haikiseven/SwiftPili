import Foundation

extension MediaEngineSession {
    func finishVideoDecoderRepair(_ repairID: UInt64) {
        guard activeVideoDecoderRepairID == repairID else { return }
        activeVideoDecoderRepairID = nil
        videoDecoderRepairTask = nil
    }

    func beginVideoDecoderRepair(
        expectedGeneration: Int?,
        expectedOwnerGeneration: UInt64?,
        expectedPiPBindingGeneration: UInt64?,
        requiresPlaying: Bool,
        awaitPreviousDecodeTask: Bool
    ) -> Task<Bool, Never> {
        nextVideoDecoderRepairID &+= 1
        if nextVideoDecoderRepairID == 0 { nextVideoDecoderRepairID = 1 }
        let repairID = nextVideoDecoderRepairID
        activeVideoDecoderRepairID = repairID
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let result = await self.performVideoDecoderRepair(
                expectedGeneration: expectedGeneration,
                expectedOwnerGeneration: expectedOwnerGeneration,
                expectedPiPBindingGeneration: expectedPiPBindingGeneration,
                requiresPlaying: requiresPlaying,
                awaitPreviousDecodeTask: awaitPreviousDecodeTask
            )
            diagnostics.log(
                "[PathA][continuation] local video decoder repair result=" +
                    "\(result ? 1 : 0) source-reopen=0"
            )
            self.finishVideoDecoderRepair(repairID)
            return result
        }
        videoDecoderRepairTask = task
        return task
    }

    func scheduleVideoDecoderRepairIfNeeded() {
        guard videoDecoderRepairTask == nil,
              !videoDecoderRepairAttempted else { return }
        videoDecoderRepairAttempted = true
        _ = beginVideoDecoderRepair(
            expectedGeneration: generation,
            expectedOwnerGeneration: activeOwnerGeneration,
            expectedPiPBindingGeneration: currentPiPBindingGeneration,
            requiresPlaying: true,
            awaitPreviousDecodeTask: false
        )
    }

    func videoDecoderRepairAuthorityIsCurrent(
        expectedGeneration: Int?,
        expectedOwnerGeneration: UInt64?,
        expectedPiPBindingGeneration: UInt64?,
        requiresPlaying: Bool
    ) -> Bool {
        guard !Task.isCancelled,
              isReady,
              runtimeFaultedGeneration == nil else {
            return false
        }
        if let expectedGeneration, generation != expectedGeneration {
            return false
        }
        if let expectedOwnerGeneration,
           activeOwnerGeneration != expectedOwnerGeneration {
            return false
        }
        if let expectedPiPBindingGeneration,
           currentPiPBindingGeneration != expectedPiPBindingGeneration {
            return false
        }
        return !requiresPlaying || isPlaying
    }

    func performVideoDecoderRepair(
        expectedGeneration: Int?,
        expectedOwnerGeneration: UInt64?,
        expectedPiPBindingGeneration: UInt64?,
        requiresPlaying: Bool,
        awaitPreviousDecodeTask: Bool
    ) async -> Bool {
        guard videoDecoderRepairAuthorityIsCurrent(
            expectedGeneration: expectedGeneration,
            expectedOwnerGeneration: expectedOwnerGeneration,
            expectedPiPBindingGeneration: expectedPiPBindingGeneration,
            requiresPlaying: requiresPlaying
        ) else {
            return false
        }
        let replacementGeneration = generation
        let previousDecodeTask = decodeTask
        cancelVideoDecode(clearHandle: true)
        if let token = activeVideoSuspendToken, isVideoLaneWarmSuspended {
            isVideoLanePreparedForForeground = false
            return await prepareVideoLaneForForeground(token) == .prepared
        }
        guard installFreshVideoDecoder(retiringCurrent: true) else {
            return false
        }
        let replacementIdentity = ObjectIdentifier(videoDecoder)
        clearPendingVideoFrames()
        await openVideoDecoderIfNeeded(expectedGeneration: replacementGeneration)
        let replacementIsCurrent = ObjectIdentifier(videoDecoder) == replacementIdentity
        guard replacementIsCurrent,
              videoDecoderRepairAuthorityIsCurrent(
                  expectedGeneration: expectedGeneration,
                  expectedOwnerGeneration: expectedOwnerGeneration,
                  expectedPiPBindingGeneration: expectedPiPBindingGeneration,
                  requiresPlaying: requiresPlaying
              ),
              videoDecoderOpened else {
            if replacementIsCurrent, videoDecoderOpened {
                retireCurrentVideoDecoderWithoutWaiting()
            }
            return false
        }
        if awaitPreviousDecodeTask {
            await previousDecodeTask?.value
        }
        guard replacementIsCurrent,
              videoDecoderRepairAuthorityIsCurrent(
                  expectedGeneration: expectedGeneration,
                  expectedOwnerGeneration: expectedOwnerGeneration,
                  expectedPiPBindingGeneration: expectedPiPBindingGeneration,
                  requiresPlaying: requiresPlaying
              ) else {
            if ObjectIdentifier(videoDecoder) == replacementIdentity,
               videoDecoderOpened {
                retireCurrentVideoDecoderWithoutWaiting()
            }
            return false
        }
        suspendedVideoFault = nil
        scheduleVideoDecodeIfNeeded()
        return true
    }

    func recreateVideoDecoderForPresentation() async -> Bool {
        if let task = videoDecoderRepairTask {
            return await task.value
        }
        let task = beginVideoDecoderRepair(
            expectedGeneration: nil,
            expectedOwnerGeneration: nil,
            expectedPiPBindingGeneration: nil,
            requiresPlaying: false,
            awaitPreviousDecodeTask: true
        )
        return await task.value
    }

    func cancelDecode() {
        cancelPiPVideoResume()
        videoDecoderRepairTask?.cancel()
        videoDecoderRepairTask = nil
        activeVideoDecoderRepairID = nil
        cancelVideoDecode(clearHandle: true)
        cancelAudioDecode(clearHandle: true)
    }

    func cancelVideoDecode(clearHandle: Bool) {
        activeVideoDecodeOperationID = nil
        decodeTask?.cancel()
        if clearHandle {
            decodeTask = nil
        }
    }

    func cancelAudioDecode(clearHandle: Bool) {
        activeAudioDecodeOperationID = nil
        audioDecodeTask?.cancel()
        if clearHandle {
            audioDecodeTask = nil
        }
    }

    func decoderReadinessFault(generation gen: Int) async -> String? {
        if !videoDecoderOpened {
            await openVideoDecoderIfNeeded(expectedGeneration: gen)
            guard isCurrentGeneration(gen) else { return nil }
        }
        if !audioDecoderOpened {
            await openAudioDecoderIfNeeded()
            guard isCurrentGeneration(gen) else { return nil }
        }
        if !videoDecoderOpened {
            return "video decoder \(type(of: videoDecoder)) did not open" +
                (lastVideoDecoderOpenError.map { " (\($0))" } ?? "")
        }
        if hasAudioTrack, !audioDecoderOpened {
            return "audio decoder \(type(of: audioDecoder)) did not open" +
                (lastAudioDecoderOpenError.map { " (\($0))" } ?? "")
        }
        return nil
    }

    func openVideoDecoderIfNeeded(
        expectedGeneration: Int? = nil,
        warmPreparationAttempt: WarmVideoPreparationAttempt? = nil
    ) async {
        let warmOpenStartedAt = warmPreparationAttempt.map { _ in ContinuousClock.now }
        if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt) {
            if let state = activeWarmDiagnostics, state.beforeDecoderOpenMs == nil {
                activeWarmDiagnostics?.beforeDecoderOpenMs = warmDiagnosticElapsedMs(state.startedAt)
            }
            warmDiagnosticPhase("decoder-open-start")
        }
        func hasCurrentAuthority() -> Bool {
            guard !Task.isCancelled else { return false }
            if let expectedGeneration,
               !isCurrentGeneration(expectedGeneration) {
                return false
            }
            if let warmPreparationAttempt,
               !isCurrentWarmVideoPreparationAttempt(warmPreparationAttempt) {
                return false
            }
            return true
        }
        guard hasCurrentAuthority() else { return }
        guard !videoDecoderOpened else { return }
        if videoDecoderWasRetired {
            guard hasCurrentAuthority() else { return }
            guard installFreshVideoDecoder(
                retiringCurrent: false,
                warmPreparationAttempt: warmPreparationAttempt
            ) else {
                guard hasCurrentAuthority() else { return }
                lastVideoDecoderOpenError =
                    videoDecoderRetirementCapacityAvailableForOpening
                    ? "decoder factory unavailable after retirement"
                    : "decoder retirement admission saturated"
                return
            }
        }
        let track = await demux.videoTrackConfiguration()
        guard hasCurrentAuthority(), !videoDecoderOpened else { return }
        let codec = track?.codec
        let config = track?.config ?? Data()
        let openingDecoder = videoDecoder
        let openingIdentity = ObjectIdentifier(openingDecoder)
        guard openingVideoDecoders[openingIdentity] == nil,
              videoDecoderRetirementCapacityAvailableForOpening else {
            videoDecoderRetirementAdmissionFailureCount &+= 1
            lastVideoDecoderOpenError = "decoder retirement admission saturated"
            diagnostics.log(
                "[PathA][continuation] decoder open reservation saturated " +
                    "capacity=\(videoDecoderRetirementCapacityUsed)"
            )
            return
        }
        openingVideoDecoders[openingIdentity] = VideoDecoderOpeningState(
            decoder: openingDecoder
        )
        defer {
            if let state = openingVideoDecoders[openingIdentity],
               state.retirementNeeded && !state.retirementRequested {
            } else {
                openingVideoDecoders.removeValue(forKey: openingIdentity)
            }
        }
        if ObjectIdentifier(videoDecoder) == openingIdentity {
            videoDecoderHasNativeSession = true
        }
        do {
            logVideoDecoderOpen(track)
            try await openingDecoder.open(format: .codecConfig(
                codec: codec,
                config: config,
                codedDimensions: track?.codedDimensions,
                extensionAtoms: track?.extensionAtoms ?? [:]
            ))
            if let warmOpenStartedAt, warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
               var state = activeWarmDiagnostics {
                state.decoderOpenTime += warmOpenStartedAt.duration(to: .now)
                activeWarmDiagnostics = state
                warmDiagnosticPhase("decoder-open-end")
            }
            finishVideoDecoderOpen(
                openingDecoder: openingDecoder,
                openingIdentity: openingIdentity,
                authorityIsCurrent: hasCurrentAuthority(),
                succeeded: true,
                errorDescription: nil
            )
            installVideoPrerollClassifier(codec: codec, config: config, decoder: openingIdentity)
        } catch {
            if let warmOpenStartedAt, warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
               var state = activeWarmDiagnostics {
                state.decoderOpenTime += warmOpenStartedAt.duration(to: .now)
                activeWarmDiagnostics = state
                warmDiagnosticPhase("decoder-open-end")
            }
            finishVideoDecoderOpen(
                openingDecoder: openingDecoder,
                openingIdentity: openingIdentity,
                authorityIsCurrent: hasCurrentAuthority(),
                succeeded: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func logVideoDecoderOpen(_ track: MediaVideoTrackConfiguration?) {
        guard diagnostics.isCapturing, let track else { return }
        var message = "[PathA] video decoder open codec=\(track.codec) config=\(track.config.count)B"
        if track.codec.lowercased() == "av01" {
            let codedSize = track.codedDimensions.map { "\($0.width)x\($0.height)" }
            message += " coded=\(codedSize ?? "missing-or-invalid")"
        }
        diagnostics.log(message)
    }

    func finishVideoDecoderOpen(
        openingDecoder: any MediaVideoDecoding,
        openingIdentity: ObjectIdentifier,
        authorityIsCurrent: Bool,
        succeeded: Bool,
        errorDescription: String?
    ) {
        guard var state = openingVideoDecoders[openingIdentity] else {
            diagnostics.log(
                "[PathA][continuation] decoder open completion already handled"
            )
            return
        }
        state.openCompleted = true
        openingVideoDecoders[openingIdentity] = state

        let isCurrentObject = ObjectIdentifier(videoDecoder) == openingIdentity
        let mayAdopt = authorityIsCurrent
            && isCurrentObject
            && !state.retirementNeeded
        if mayAdopt, succeeded {
            videoDecoderOpened = true
            videoDecoderHasNativeSession = true
            lastVideoDecoderOpenError = nil
            openingVideoDecoders.removeValue(forKey: openingIdentity)
            diagnostics.log(
                "[PathA] video decoder open ok type=\(type(of: videoDecoder))"
            )
            return
        }

        if mayAdopt, !succeeded {
            videoDecoderOpened = false
            videoDecoderHasNativeSession = false
            videoDecoderWasRetired = true
            lastVideoDecoderOpenError = errorDescription
            diagnostics.log(
                "[PathA] video decoder open failed: \(errorDescription ?? "unknown")"
            )
        }

        requestVideoDecoderRetirement(openingDecoder)
    }

    func installFreshVideoDecoder(
        retiringCurrent: Bool,
        warmPreparationAttempt: WarmVideoPreparationAttempt? = nil
    ) -> Bool {
        guard let videoDecoderFactory else { return false }
        let currentIdentity = ObjectIdentifier(videoDecoder)
        let currentIsOpening = openingVideoDecoders[currentIdentity] != nil
        let currentRetirementAddsCapacity = retiringCurrent
            && !videoDecoderWasRetired
            && !currentIsOpening
        let projectedCapacity = videoDecoderRetirementCapacityUsed
            + (currentRetirementAddsCapacity ? 1 : 0)
            + 1
        guard projectedCapacity <= Self.maxOutstandingVideoDecoderRetirements else {
            videoDecoderRetirementAdmissionFailureCount &+= 1
            let intent = retiringCurrent ? "recovery" : "open"
            diagnostics.log(
                "[PathA][continuation] decoder retirement admission saturated " +
                    "capacity=\(videoDecoderRetirementCapacityUsed) " +
                    "intent=\(intent)"
            )
            return false
        }
        let shouldRetireCurrent = retiringCurrent && !videoDecoderWasRetired
        let replacement = videoDecoderFactory()
        let current = videoDecoder
        let currentWasOpened = videoDecoderOpened
        let currentHadNativeSession = videoDecoderHasNativeSession
        let replacementIdentity = ObjectIdentifier(replacement)
        guard replacementIdentity != ObjectIdentifier(current) else {
            diagnostics.log(
                "[PathA][continuation] decoder factory rejected same identity"
            )
            return false
        }
        guard outstandingVideoDecoderRetirements[replacementIdentity] == nil,
              openingVideoDecoders[replacementIdentity] == nil else {
            diagnostics.log(
                "[PathA][continuation] decoder factory returned active identity"
            )
            return false
        }
        videoDecoder = replacement
        videoDecoderOpened = false
        videoDecoderHasNativeSession = false
        videoDecoderWasRetired = false
        if shouldRetireCurrent {
            guard enqueueVideoDecoderRetirement(current) else {
                videoDecoder = current
                videoDecoderOpened = currentWasOpened
                videoDecoderHasNativeSession = currentHadNativeSession
                videoDecoderWasRetired = false
                return false
            }
        }
        warmVideoPreparationLedger.clearProgress()
        if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
           let run = warmPreparationTransaction.currentRun {
            bindWarmDecoderTiming(run: run)
        }
        return true
    }

    @discardableResult
    func retireCurrentVideoDecoderWithoutWaiting() -> Bool {
        let currentIdentity = ObjectIdentifier(videoDecoder)
        if openingVideoDecoders[currentIdentity] != nil {
            videoDecoderOpened = false
            videoDecoderHasNativeSession = false
            videoDecoderWasRetired = true
            return requestVideoDecoderRetirement(videoDecoder)
        }
        guard !videoDecoderWasRetired,
              videoDecoderHasNativeSession || videoDecoderOpened else { return true }
        let retired = videoDecoder
        let wasOpened = videoDecoderOpened
        let hadNativeSession = videoDecoderHasNativeSession
        videoDecoderOpened = false
        videoDecoderHasNativeSession = false
        videoDecoderWasRetired = true
        guard enqueueVideoDecoderRetirement(retired) else {
            videoDecoderOpened = wasOpened
            videoDecoderHasNativeSession = hadNativeSession
            videoDecoderWasRetired = false
            diagnostics.log(
                "[PathA][continuation] decoder retirement could not be admitted"
            )
            return false
        }
        return true
    }

    @discardableResult
    func enqueueVideoDecoderRetirement(
        _ decoder: any MediaVideoDecoding
    ) -> Bool {
        if openingVideoDecoders[ObjectIdentifier(decoder)] != nil {
            return requestVideoDecoderRetirement(decoder)
        }
        return enqueueDetachedVideoDecoderRetirement(decoder)
    }

    @discardableResult
    func requestVideoDecoderRetirement(
        _ decoder: any MediaVideoDecoding
    ) -> Bool {
        let identity = ObjectIdentifier(decoder)
        if var state = openingVideoDecoders[identity] {
            if ObjectIdentifier(videoDecoder) == identity {
                videoDecoderOpened = false
                videoDecoderHasNativeSession = false
                videoDecoderWasRetired = true
            }
            if !state.retirementNeeded {
                state.retirementNeeded = true
                openingVideoDecoders[identity] = state
            }
            freezeRetiringWarmDecoderTiming(identity)
            drainPendingVideoDecoderRetirements()
            return true
        }
        return enqueueDetachedVideoDecoderRetirement(decoder)
    }

    @discardableResult
    func enqueueDetachedVideoDecoderRetirement(
        _ decoder: any MediaVideoDecoding
    ) -> Bool {
        let identity = ObjectIdentifier(decoder)
        if outstandingVideoDecoderRetirements[identity] != nil {
            freezeRetiringWarmDecoderTiming(identity)
            diagnostics.log(
                "[PathA][continuation] duplicate decoder retirement ignored"
            )
            return true
        }
        let openingReservation = openingVideoDecoders[identity] != nil ? 1 : 0
        guard videoDecoderRetirementCapacityUsed - openingReservation
                < Self.maxOutstandingVideoDecoderRetirements else {
            videoDecoderRetirementAdmissionFailureCount &+= 1
            diagnostics.log(
                "[PathA][continuation] decoder retirement ceiling reached " +
                    "capacity=\(videoDecoderRetirementCapacityUsed)"
            )
            return false
        }
        nextVideoDecoderRetirementID &+= 1
        if nextVideoDecoderRetirementID == 0 {
            nextVideoDecoderRetirementID = 1
        }
        let retirementID = nextVideoDecoderRetirementID
        outstandingVideoDecoderRetirements[identity] = retirementID
        freezeRetiringWarmDecoderTiming(identity)
        Task.detached(priority: .userInitiated) { [weak self] in
            await decoder.close()
            guard let self else { return }
            await self.completeVideoDecoderRetirement(
                identity: identity,
                retirementID: retirementID
            )
        }
        return true
    }

    private var videoDecoderRetirementCapacityUsed: Int {
        outstandingVideoDecoderRetirements.count + openingVideoDecoders.reduce(0) {
            result, entry in
            result + (outstandingVideoDecoderRetirements[entry.key] == nil ? 1 : 0)
        }
    }

    private var videoDecoderRetirementCapacityAvailableForOpening: Bool {
        videoDecoderRetirementCapacityUsed < Self.maxOutstandingVideoDecoderRetirements
    }

    func drainPendingVideoDecoderRetirements() {
        guard !openingVideoDecoders.isEmpty else { return }
        let identities = Array(openingVideoDecoders.keys)
        for identity in identities where outstandingVideoDecoderRetirements.count
                < Self.maxOutstandingVideoDecoderRetirements {
            guard var state = openingVideoDecoders[identity],
                  state.openCompleted,
                  state.retirementNeeded,
                  !state.retirementRequested,
                  outstandingVideoDecoderRetirements[identity] == nil else {
                continue
            }
            guard enqueueDetachedVideoDecoderRetirement(state.decoder) else {
                continue
            }
            state.retirementRequested = true
            openingVideoDecoders[identity] = state
        }
    }

    func completeVideoDecoderRetirement(
        identity: ObjectIdentifier,
        retirementID: UInt64
    ) {
        guard outstandingVideoDecoderRetirements[identity] == retirementID else {
            diagnostics.log(
                "[PathA][continuation] stale decoder retirement completion ignored"
            )
            return
        }
        outstandingVideoDecoderRetirements.removeValue(forKey: identity)
        videoDecoderRetirementCompletionCount &+= 1
        drainPendingVideoDecoderRetirements()
        diagnostics.log(
            "[PathA][continuation] decoder retirement completed " +
                "outstanding=\(outstandingVideoDecoderRetirements.count)"
        )
    }

    func openAudioDecoderIfNeeded() async {
        guard hasAudioTrack, !audioDecoderOpened else { return }
        let codec = await demux.codec(for: .audio)
        let config = await demux.formatConfig(for: .audio)
        do {
            if codec != nil || !config.isEmpty {
                diagnostics.log(
                    "[PathA] audio decoder open codec=\(codec ?? "?") config=\(config.count)B " +
                    "hex=\(config.prefix(32).map { String(format: "%02x", $0) }.joined())"
                )
            }
            try await audioDecoder.open(codec: codec, formatHint: config.isEmpty ? nil : config)
            audioDecoderOpened = true
            lastAudioDecoderOpenError = nil
            diagnostics.log("[PathA] audio decoder open ok type=\(type(of: audioDecoder))")
        } catch {
            audioDecoderOpened = false
            lastAudioDecoderOpenError = error.localizedDescription
            diagnostics.log("[PathA] audio decoder open failed: \(error.localizedDescription)")
        }
    }

    func startAudioRenderIfNeeded(reconcileAuthorizedOutput: Bool = false) {
        guard isPlaying, drivesAudioClockPipeline else { return }
        if audioRender.isRunning {
            if reconcileAuthorizedOutput {
                do {
                    try audioRender.reconcileOutputForAuthorizedPlayback()
                } catch {
                    diagnostics.log("[PathA] authorized audio output repair failed: \(error.localizedDescription)")
                }
            }
            return
        }
        guard audioRender.reportsRenderedContent else {
            diagnostics.log(
                "[PathA] audio render refused: \(type(of: audioRender)) does not report " +
                "rendered content — no master clock (F1)"
            )
            onEvent?(.failed(.renderFailed(
                "audio renderer \(type(of: audioRender)) does not report rendered content"
            )))
            return
        }
        do {
            try audioRender.start(source: self)
            if diagnostics.isCapturing {
                if let engine = audioRender as? EngineAudioRenderer {
                    let mode: String
                    if engine.hardwareStartPending {
                        mode = "hardware-pending"
                    } else if engine.fillOnlyMode {
                        mode = "fill-only"
                    } else if engine.isResamplingToHardware {
                        mode = "hardware-resample"
                    } else {
                        mode = "hardware"
                    }
                    let hwNote = engine.hardwareSampleRate > 0
                        ? " hwSR=\(String(format: "%.0f", engine.hardwareSampleRate))"
                        : ""
                    diagnostics.log(
                        "[PathA] audio render start \(mode) " +
                        "engineStarted=\(engine.engineStarted)\(hwNote) " +
                        "rate=\(String(format: "%.2f", playbackRate))"
                    )
                } else {
                    diagnostics.log("[PathA] audio render start ok type=\(type(of: audioRender))")
                }
            }
        } catch {
            diagnostics.log("[PathA] audio render start skipped: \(error.localizedDescription)")
        }
    }

    func scheduleVideoDecodeIfNeeded() {
        guard !isSeekInFlight,
              !isVideoLaneWarmSuspended || isDecodingWarmVideoCandidate else {
            return
        }
        if !videoDecoderOpened {
            guard isReady, isPlaying, runtimeFaultedGeneration == nil else { return }
            scheduleVideoDecoderRepairIfNeeded()
            return
        }
        guard !videoPackets.isEmpty else { return }
        if Self.relayDecodeYieldsToPrerollBatch(
            batchingActive: prerollBatchingActive,
            head: videoPackets.first,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        ) {
            return
        }
        if videoDecodeLaneOwners > 0,
           activeVideoDecodeOperationID != nil
            || directVideoDecodeLane.isHeldForScheduling {
            return
        }
        if !videoFrameQueueNeedsFill { return }
        if decodeTask != nil { return }
        let gen = generation
        let operationID = beginVideoDecodeOperation()
        decodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainVideoDecodeBurst(
                generation: gen,
                decodeOperationID: operationID
            )
            self.finishVideoDecodeOperation(operationID, generation: gen)
        }
    }

    func scheduleAudioDecodeIfNeeded() {
        guard isReady, audioDecoderOpened, !isSeekInFlight else { return }
        let needsMorePCM = pendingAudioContentSeconds < audioPCMTargetSeconds
            && (!audioPackets.isEmpty || needsPacketFill())
        guard needsMorePCM else { return }
        if audioDecodeLaneOwners > 0,
           activeAudioDecodeOperationID != nil
            || directAudioDecodeLane.isHeldForScheduling {
            return
        }
        if audioDecodeTask != nil { return }
        let gen = generation
        let operationID = beginAudioDecodeOperation()
        audioDecodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.fillPCMRing(
                generation: gen,
                phase: .playback,
                decodeOperationID: operationID
            )
            self.finishAudioDecodeOperation(operationID, generation: gen)
        }
    }

    func beginVideoDecodeOperation() -> UInt64 {
        nextVideoDecodeOperationID &+= 1
        if nextVideoDecodeOperationID == 0 {
            nextVideoDecodeOperationID = 1
        }
        activeVideoDecodeOperationID = nextVideoDecodeOperationID
        return nextVideoDecodeOperationID
    }

    func beginAudioDecodeOperation() -> UInt64 {
        nextAudioDecodeOperationID &+= 1
        if nextAudioDecodeOperationID == 0 {
            nextAudioDecodeOperationID = 1
        }
        activeAudioDecodeOperationID = nextAudioDecodeOperationID
        return nextAudioDecodeOperationID
    }

    func isCurrentVideoDecodeOperation(_ operationID: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let operationID else { return true }
        return activeVideoDecodeOperationID == operationID
    }

    func isCurrentAudioDecodeOperation(_ operationID: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let operationID else { return true }
        return activeAudioDecodeOperationID == operationID
    }

    func finishVideoDecodeOperation(
        _ operationID: UInt64,
        generation gen: Int
    ) {
        let ownsCurrentOperation = activeVideoDecodeOperationID == operationID
        guard ownsCurrentOperation || activeVideoDecodeOperationID == nil else {
            return
        }
        if ownsCurrentOperation {
            activeVideoDecodeOperationID = nil
        }
        decodeTask = nil
        guard ownsCurrentOperation else {
            return
        }
        guard isPlaying,
              isCurrentGeneration(gen),
              videoDecoderOpened,
              !videoPackets.isEmpty,
              videoFrameQueueNeedsFill else { return }
        scheduleVideoDecodeIfNeeded()
    }

    func finishAudioDecodeOperation(
        _ operationID: UInt64,
        generation gen: Int
    ) {
        guard activeAudioDecodeOperationID == operationID else { return }
        activeAudioDecodeOperationID = nil
        audioDecodeTask = nil
        guard isPlaying,
              isCurrentGeneration(gen),
              audioDecoderOpened,
              pendingAudioContentSeconds < audioPCMTargetSeconds,
              (!audioPackets.isEmpty || needsPacketFill()) else { return }
        scheduleAudioDecodeIfNeeded()
    }

    func fillPCMRing(
        generation gen: Int,
        phase: MediaQueueFillPhase,
        contentCap: TimeInterval? = nil,
        packetContentCap: TimeInterval? = nil,
        decodeOperationID: UInt64? = nil
    ) async throws {
        guard hasAudioTrack, audioDecoderOpened else { return }
        let pcmTarget = min(
            audioPCMTargetSeconds,
            contentCap ?? audioPCMTargetSeconds
        )
        let packetCap = packetContentCap ?? contentCap
        var noPCMProgressBursts = 0
        while isCurrentGeneration(gen), audioDecoderOpened {
            guard isCurrentAudioDecodeOperation(decodeOperationID) else {
                return
            }
            if pendingAudioContentSeconds >= pcmTarget {
                break
            }
            if audioPackets.isEmpty {
                let canPump: Bool
                if let cap = packetCap {
                    let depth = audioPacketQueue.contentSeconds
                    canPump = (min(cap, audioPacketQueue.highWater) - depth) >= minTrackFillRoom
                } else {
                    canPump = needsPacketFill()
                }
                if canPump, !isPreparingWarmVideoLane {
                    try await fillQueuesToHighWater(
                        generation: gen,
                        initiator: .audioRefill,
                        phase: phase,
                        videoContentCap: packetCap != nil ? primeVideoContentBudget : nil,
                        audioContentCap: packetCap,
                        audioDecodeOperationID: decodeOperationID
                    )
                    guard isCurrentGeneration(gen),
                          isCurrentAudioDecodeOperation(decodeOperationID) else {
                        return
                    }
                }
                if audioPackets.isEmpty {
                    break
                }
            }
            let pcmBefore = pendingAudioContentSeconds
            let prerollDropsBefore = droppedPrerollAudioFrameCount
            let consumedPackets = await drainAudioDecodeBurst(
                generation: gen,
                decodeOperationID: decodeOperationID
            )
            guard isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(decodeOperationID) else {
                return
            }
            if consumedPackets > 0, pendingAudioContentSeconds <= pcmBefore + 1e-9 {
                if droppedPrerollAudioFrameCount > prerollDropsBefore {
                    noPCMProgressBursts = 0
                } else {
                    noPCMProgressBursts += 1
                    if noPCMProgressBursts >= Self.audioPrimeNoPCMProgressBurstLimit {
                        diagnostics.log(
                            "[PathA] prime PCM stall — audio decode produced no PCM " +
                            "(aPkts consumed, pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s); ending fill"
                        )
                        break
                    }
                }
            } else {
                noPCMProgressBursts = 0
            }
            if consumedPackets == 0, pendingAudioContentSeconds < pcmTarget,
               audioPackets.isEmpty {
                break
            }
            if consumedPackets == 0, !audioPackets.isEmpty {
                break
            }
        }
    }

    func joinScheduledVideoDecodeAndAcquireDirectLane(
        generation gen: Int,
        warmPreparationAttempt: WarmVideoPreparationAttempt?
    ) async -> Bool {
        do {
            while let scheduled = decodeTask,
                  let scheduledOperationID = activeVideoDecodeOperationID {
                let laneWaitStart = ContinuousClock.now
                await scheduled.value
                if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt) {
                    activeWarmDiagnostics?.schedulingWaitTime += laneWaitStart.duration(to: .now)
                }
                guard isCurrentGeneration(gen), videoDecoderOpened,
                      !isVideoLaneWarmSuspended || isDecodingWarmVideoCandidate else { return false }
                if let warmPreparationAttempt,
                   !isCurrentWarmVideoPreparationAttempt(warmPreparationAttempt) {
                    return false
                }
                guard activeVideoDecodeOperationID != scheduledOperationID else {
                    break
                }
            }
        }
        do {
            let laneWaitStart = ContinuousClock.now
            await directVideoDecodeLane.acquire()
            if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt) {
                activeWarmDiagnostics?.schedulingWaitTime += laneWaitStart.duration(to: .now)
            }
            guard isCurrentGeneration(gen), videoDecoderOpened,
                  !isVideoLaneWarmSuspended || isDecodingWarmVideoCandidate else {
                directVideoDecodeLane.release()
                return false
            }
            if let warmPreparationAttempt,
               !isCurrentWarmVideoPreparationAttempt(warmPreparationAttempt) {
                directVideoDecodeLane.release()
                return false
            }
        }
        return true
    }

    func drainVideoDecodeBurst(
        generation gen: Int,
        warmPreparationAttempt: WarmVideoPreparationAttempt? = nil,
        decodeOperationID: UInt64? = nil
    ) async {
        guard isCurrentGeneration(gen), videoDecoderOpened,
              !isVideoLaneWarmSuspended || isDecodingWarmVideoCandidate else { return }
        guard isCurrentVideoDecodeOperation(decodeOperationID) else { return }
        if let warmPreparationAttempt,
           !isCurrentWarmVideoPreparationAttempt(warmPreparationAttempt) {
            return
        }
        let isDirectBurst = decodeOperationID == nil
        if isDirectBurst {
            guard await joinScheduledVideoDecodeAndAcquireDirectLane(
                generation: gen,
                warmPreparationAttempt: warmPreparationAttempt
            ) else { return }
        }
        videoDecodeLaneOwners += 1
        defer { videoDecodeLaneOwners -= 1 }
        if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt) {
            if var state = activeWarmDiagnostics {
                state.decodeBursts += 1
                activeWarmDiagnostics = state
            }
            warmDiagnosticPhase("decode-burst-start")
        }
        defer {
            if isDirectBurst {
                directVideoDecodeLane.release()
            }
        }
        var budget = videoDecodeBurstLimit
        while budget > 0, isCurrentGeneration(gen), !videoPackets.isEmpty {
            guard isCurrentVideoDecodeOperation(decodeOperationID) else { return }
            if warmPreparationAttempt != nil,
               warmVideoSubmissionsWithoutOutput
                >= Self.warmVideoNoOutputSubmissionLimit {
                return
            }
            if usesAudioMasterForVideo, !videoFrameQueueNeedsFill {
                guard holdsPassThroughVideo, pendingVideoFrames.isEmpty else { break }
            }
            let packet = videoPackets.removeFirst()
            observeVideoPrerollSample(packet)
            let accountsPrerollItem = activePrerollStats != nil
                && activePrerollStatsGeneration == gen
                && OutputFloorPolicy.isPreTarget(
                    pts: packet.pts,
                    floor: outputMediaFloor,
                    epsilon: outputMediaFloorEpsilon
                )
            if activePrerollStatsGeneration == gen {
                activePrerollStats?.noteAnchor(packet.pts)
            }
            if accountsPrerollItem {
                activePrerollStats?.items += 1
                activePrerollStats?.submitted += 1
            }
            let countsAsWarmSubmission = !packet.data.isEmpty || packet.pixelBuffer != nil
            noteVideoPacketDequeued(packet)
            noteVideoPacketSubmitted()
            tracing.mark(
                .demandFirstVideoSubmit,
                token: activeStartupTraceToken
            )
            budget -= 1

            let decodingDecoder = videoDecoder
            let decodingDecoderIdentity = ObjectIdentifier(decodingDecoder)
            let warmProgressAttempt = (warmPreparationAttempt ?? warmVideoPreparationLedger.currentAttempt).flatMap {
                isCurrentWarmVideoPreparationAttempt($0) && isDecodingWarmVideoCandidate
                    && videoDecoderOpened && !videoDecoderWasRetired ? $0 : nil
            }
            let decodeStart = diagnostics.isCapturing ? ContinuousClock.now : nil
            let warmDecodeStart = warmPreparationAttempt.map { _ in ContinuousClock.now }
            if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt) {
                activeWarmDiagnostics?.submittedPackets += 1
            }
            if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
               var state = activeWarmDiagnostics,
               state.firstDecodeStartedAt == nil {
                state.firstDecodeStartedAt = warmDecodeStart
                activeWarmDiagnostics = state
            }
            var warmDecodeEndedAt: ContinuousClock.Instant?
            defer {
                if let warmDecodeStart, warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
                   var state = activeWarmDiagnostics {
                    let duration = warmDecodeStart.duration(to: warmDecodeEndedAt ?? .now)
                    state.totalDecodeTime += duration
                    if state.firstDecodeAwaitMs == nil {
                        state.firstDecodeAwaitMs = Self.warmDiagnosticMilliseconds(duration)
                    }
                    activeWarmDiagnostics = state
                }
            }
            let frames: [MediaVideoFrame]
            do {
                frames = try await decodingDecoder.decode(packet)
                warmDecodeEndedAt = .now
                guard isCurrentGeneration(gen),
                      isCurrentVideoDecodeOperation(decodeOperationID),
                      ObjectIdentifier(videoDecoder) == decodingDecoderIdentity else {
                    return
                }
                if let decodeStart {
                    let elapsed = decodeStart.duration(to: ContinuousClock.now)
                    let ms = Int(elapsed / .milliseconds(1))
                    if ms > flowWindowMaxDecodeMs { flowWindowMaxDecodeMs = ms }
                    if accountsPrerollItem {
                        activePrerollStats?.decodeSeconds += SeekPhaseStopwatch.seconds(elapsed)
                    }
                }
            } catch {
                warmDecodeEndedAt = .now
                guard isCurrentGeneration(gen),
                      isCurrentVideoDecodeOperation(decodeOperationID),
                      ObjectIdentifier(videoDecoder) == decodingDecoderIdentity else {
                    return
                }
                if let warmPreparationAttempt,
                   !isCurrentWarmVideoPreparationAttempt(warmPreparationAttempt) {
                    return
                }
                publishVideoDecodeFault(error, generation: gen)
                return
            }
            guard isCurrentGeneration(gen),
                  isCurrentVideoDecodeOperation(decodeOperationID),
                  ObjectIdentifier(videoDecoder) == decodingDecoderIdentity,
                  !isVideoLaneWarmSuspended || isDecodingWarmVideoCandidate else {
                return
            }
            if let warmPreparationAttempt,
               !isCurrentWarmVideoPreparationAttempt(warmPreparationAttempt) {
                return
            }
            pipeWindowVideoCallbacks += 1
            if warmPreparationAttempt != nil {
                if frames.isEmpty {
                    if countsAsWarmSubmission {
                        warmVideoSubmissionsWithoutOutput += 1
                    }
                } else {
                    warmVideoSubmissionsWithoutOutput = 0
                }
            }
            if let warmProgressAttempt {
                observeWarmVideoPreparationProgress(
                    frames, attempt: warmProgressAttempt,
                    decoderIdentity: decodingDecoderIdentity
                )
            }
            if !frames.isEmpty {
                noteFlowStage(&flowDecOutV, "decOutV")
                tracing.mark(
                    .demandFirstVideoOutput,
                    token: activeStartupTraceToken
                )
            }
            decodedVideoFrameCount += frames.count
            pipeWindowDecodeFrames += frames.count
            if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
               var state = activeWarmDiagnostics {
                state.decodedFrames += frames.count
                if !frames.isEmpty, state.firstOutputMs == nil {
                    state.firstOutputMs = warmDiagnosticElapsedMs(state.startedAt)
                }
                activeWarmDiagnostics = state
            }

            for frame in frames {
                noteVideoFrameSize(from: frame.pixelBuffer)
                noteVideoLivenessOutput(frame)
                noteVideoDecodeFrontier(frame.pts)
                if shouldDropVideoBeforeOutputFloor(frame) {
                    droppedPrerollVideoFrameCount += 1
                    if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
                       var state = activeWarmDiagnostics {
                        state.prerollFramesDropped += 1
                        if frame.pts < state.target { state.initialFloorDrops += 1 }
                        else { state.movingFloorDrops += 1 }
                        activeWarmDiagnostics = state
                    }
                    continue
                }
                enqueuePendingVideoFrame(frame)
                if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt),
                   var state = activeWarmDiagnostics {
                    state.targetFramesBanked += 1
                    activeWarmDiagnostics = state
                }
            }
        }

        guard isCurrentGeneration(gen),
              isCurrentVideoDecodeOperation(decodeOperationID) else {
            return
        }
        presentDueVideoFrames()

        if isCurrentGeneration(gen), isReady, !isSeekInFlight {
            onEvent?(.tick(
                mediaTime: clock.mediaTime,
                duration: clock.duration,
                buffered: bufferedTime
            ))
            if isPlaying {
                drainResidualPackets()
                wakeSupplyLoopIfDrained()
            }
        }
        maybeReportPipeInstrument()
    }

    func noteVideoPacketDequeued(_ packet: MediaPacket) {
        pipeWindowVideoPacketsDequeued += 1
        pipeWindowVideoInputSeconds += max(0, packet.duration)
        totalVideoPacketsDequeued += 1
        totalVideoInputContentSecondsConsumed += max(0, packet.duration)
        if packet.duration.isFinite, packet.duration > 0 {
            videoLivenessPacketDurations.append(packet.duration)
        }
        drainPacketDuration(packet.duration, from: &videoPacketQueue, packets: videoPackets)
    }

    func noteVideoPacketSubmitted() {
        pipeWindowVideoPacketsSubmitted += 1
        totalVideoPacketsSubmitted += 1
        noteFlowStage(&flowDecInV, "decInV")
    }

    @discardableResult
    func drainAudioDecodeBurst(
        generation gen: Int,
        decodeOperationID: UInt64? = nil
    ) async -> Int {
        guard isCurrentGeneration(gen),
              audioDecoderOpened,
              isCurrentAudioDecodeOperation(decodeOperationID) else { return 0 }
        if decodeOperationID == nil {
            while let scheduled = audioDecodeTask,
                  let scheduledOperationID = activeAudioDecodeOperationID {
                await scheduled.value
                guard isCurrentGeneration(gen), audioDecoderOpened else {
                    return 0
                }
                guard activeAudioDecodeOperationID != scheduledOperationID else {
                    break
                }
            }
        }
        let isDirectBurst = decodeOperationID == nil
        if isDirectBurst {
            await directAudioDecodeLane.acquire()
            guard isCurrentGeneration(gen), audioDecoderOpened else {
                directAudioDecodeLane.release()
                return 0
            }
        }
        audioDecodeLaneOwners += 1
        defer { audioDecodeLaneOwners -= 1 }
        defer {
            if isDirectBurst {
                directAudioDecodeLane.release()
            }
        }
        var budget = audioDecodeBurstLimit
        var consumedPackets = 0
        while budget > 0, isCurrentGeneration(gen), !audioPackets.isEmpty {
            guard isCurrentAudioDecodeOperation(decodeOperationID) else {
                return consumedPackets
            }
            let packet = audioPackets.removeFirst()
            consumedPackets += 1
            drainPacketDuration(packet.duration, from: &audioPacketQueue, packets: audioPackets)
            budget -= 1

            guard await decodeAndAppendAudioPacket(packet, generation: gen, operationID: decodeOperationID) else {
                return consumedPackets
            }
        }

        if isCurrentGeneration(gen),
           isCurrentAudioDecodeOperation(decodeOperationID),
           isReady, isPlaying {
            drainResidualPackets()
            wakeSupplyLoopIfDrained()
        }
        return consumedPackets
    }

    private func decodeAndAppendAudioPacket(
        _ packet: MediaPacket, generation gen: Int, operationID: UInt64?
    ) async -> Bool {
        guard isCurrentGeneration(gen), isCurrentAudioDecodeOperation(operationID) else { return false }
        audioDecodePacketsSubmitted += 1

        func isCurrent() -> Bool {
            isCurrentGeneration(gen) && isCurrentAudioDecodeOperation(operationID)
        }

        let frames: [MediaAudioFrame]
        do {
            frames = try await audioDecoder.decode(packet)
        } catch {
            guard isCurrent() else { return false }
            lastAudioDecodeError = error.localizedDescription
            diagnostics.log("[PathA] audio decode failed: \(error.localizedDescription)")
            return true
        }
        guard isCurrent() else { return false }
        if !isReady {
            audioDecodePCMFramesProduced += frames.reduce(into: 0) { total, frame in
                guard frame.duration.isFinite, frame.duration > 0,
                      frame.sampleRate.isFinite, frame.sampleRate > 0 else { return }
                total += Int((frame.duration * frame.sampleRate).rounded())
            }
        }
        for frame in frames {
            appendPCM(frame)
            decodedAudioFrameCount += 1
        }
        return true
    }

    func appendPCM(_ frame: MediaAudioFrame) {
        noteFlowStage(
            &flowPCM,
            "pcmA",
            starvingBelow: 1.0,
            depth: pendingAudioContentSeconds
        )
        noteAudioDecodeFrontier(frame.pts + max(0, frame.duration))
        let result = audioTimelineBuffer.append(
            pcm: frame.pcm,
            pts: frame.pts,
            context: AudioPCMAppend(
                sampleRate: frame.sampleRate,
                channels: frame.channelCount,
                outputFloor: outputMediaFloor
            )
        )
        if let tap = subtitlePCMTap,
           result.rejection == nil,
           result.appendedFrameCount > 0 {
            tap.ingest(
                pcm: frame.pcm,
                pts: frame.pts,
                sampleRate: frame.sampleRate,
                channels: frame.channelCount,
                trimmedLeadingFrames: result.trimmedPrerollSampleFrameCount
            )
        }
        if let timing = frame.decodeTiming, audioDecodeTimingLogCount < 8 {
            audioDecodeTimingLogCount += 1
            diagnostics.log(
                "[PathA] AAC AU #\(audioDecodeTimingLogCount) " +
                "ptsTicks=\(timing.packet.ptsTicks) dtsTicks=\(timing.packet.dtsTicks) " +
                "durTicks=\(timing.packet.durationTicks) ts=\(timing.packet.trackTimescale) " +
                "effectiveTS=\(String(format: "%.3f", timing.packet.effectiveTimescale)) " +
                "decodedF=\(timing.decodedInputFrames) resampledF=\(timing.resampledOutputFrames) " +
                "pcmPTS=\(String(format: "%.6f", frame.pts)) " +
                "pcmDur=\(String(format: "%.6f", frame.duration)) " +
                "timelineDelta=\(String(format: "%.6f", result.timelineDelta ?? 0))"
            )
        }
        droppedPrerollAudioFrameCount += result.droppedPrerollFrameCount
        trimmedPrerollAudioSampleFrameCount += result.trimmedPrerollSampleFrameCount
        if let delta = result.timelineDelta,
           abs(delta) > EnginePCM.aacOutputQuantumSeconds {
            audioTimelineAdjustmentLogCount += 1
            if audioTimelineAdjustmentLogCount <= 8
                    || audioTimelineAdjustmentLogCount % 100 == 0 {
                diagnostics.log(
                    "[PathA] audio timeline adjust #\(audioTimelineAdjustmentLogCount) " +
                    "framePTS=\(String(format: "%.6f", frame.pts)) " +
                    "expected=\(String(format: "%.6f", result.expectedStartPTS ?? 0)) " +
                    "delta=\(String(format: "%.6f", delta)) " +
                    "gapF=\(result.insertedGapFrameCount) " +
                    "overlapF=\(result.droppedOverlapFrameCount)"
                )
            }
        }

        switch result.rejection {
        case .none, .invalidPCM:
            break
        case .nonFinitePTS:
            diagnostics.diagnostic("[PathA] audio PCM frame with non-finite PTS dropped")
        case let .formatChange(expectedSampleRate, expectedChannels, actualSampleRate, actualChannels):
            diagnostics.log(
                "[PathA] audio PCM format change ignored " +
                "(\(actualSampleRate)Hz/\(actualChannels)ch vs " +
                "\(expectedSampleRate)Hz/\(expectedChannels)ch)"
            )
        case let .gapTooLarge(gap, firstPTS):
            diagnostics.diagnostic(
                "[PathA] audio PCM timeline gap too large — " +
                "gap=\(String(format: "%.3f", gap))s; " +
                "holding frame at \(String(format: "%.3f", firstPTS))"
            )
        }
    }
}
