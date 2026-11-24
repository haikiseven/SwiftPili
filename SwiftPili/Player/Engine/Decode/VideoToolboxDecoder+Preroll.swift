import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

extension VideoToolboxDecoder {
    private struct PrerollSubmitted {
        let timing: VideoToolboxTimingSubmission
        let packet: MediaPacket
        let truncated: Bool
    }

    func decodePrerollBatch(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) async throws -> VideoPrerollBatchResult {
        try await onDecodeQueue {
            UncheckedQueueResult(
                value: try self.decodePrerollBatchOnQueue(batch, keepOutput: keepOutput)
            )
        }.value
    }

    private func decodePrerollBatchOnQueue(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) throws -> VideoPrerollBatchResult {
        guard opened else {
            throw MediaEngineError.stopped
        }
        let started = ContinuousClock.now
        var result = VideoPrerollBatchResult()
        var preSwitchEntries: [VideoToolboxOutputRouter.Entry] = []
        let (submitted, failure) = submitPrerollBatchOnQueue(
            batch, keepOutput: keepOutput, result: &result, preSwitchEntries: &preSwitchEntries
        )
        let waitStarted = ContinuousClock.now
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        let waitMs = Int(waitStarted.duration(to: .now) / .milliseconds(1))

        let entries = preSwitchEntries + outputRouter.drain(
            identities: submitted.map(\.timing.identity),
            forGeneration: queueSessionID
        )
        let entriesByIdentity = Dictionary(uniqueKeysWithValues: entries.map { ($0.submission.identity, $0) })
        let truncated = Set(submitted.filter(\.truncated).map(\.timing.identity))

        for entry in entries {
            noteDecodeAnomalies(
                submissionStatus: noErr,
                events: entry.records.map(\.event),
                truncated: truncated.contains(entry.submission.identity)
            )
        }
        if let failure {
            try throwFirstPrerollCallbackFault(entries)
            throw failure
        }
        try throwFirstPrerollCallbackFault(entries)
        resolvePrerollOutputs(entriesByIdentity, submitted: submitted, preSwitchEntries: preSwitchEntries, into: &result)
        if !didLogFirstPrerollBatch {
            didLogFirstPrerollBatch = true
            PlayerLog.log(
                "[PathADecoder] event=prerollBatch sessionID=\(queueSessionID) " +
                "flags=async items=\(batch.count) submitted=\(result.submitted) " +
                "skipped=\(result.skipped) truncated=\(result.truncated) " +
                "outputs=\(result.outputPTS.count) " +
                "batchMs=\(Int(started.duration(to: .now) / .milliseconds(1))) waitMs=\(waitMs)"
            )
        }
        return result
    }

    func noteDecodeAnomalies(
        submissionStatus: OSStatus,
        events: [VideoToolboxTimingOutputEvent],
        truncated: Bool
    ) {
        let submissionFault = Self.classification(for: submissionStatus) != nil
        var hasEventAnomaly = false
        for event in events {
            let status = OSStatus(event.status)
            if event.status == VideoDecodeAnomalyCounters.referenceMissingStatus
                || Self.classification(for: status) != nil
                || (event.infoFlags & VideoDecodeAnomalyCounters.frameDroppedInfoFlag) != 0
                || (event.status == 0 && !event.imagePresent && !truncated) {
                hasEventAnomaly = true
                break
            }
        }
        guard submissionFault || hasEventAnomaly else { return }
        anomalyLock.withLock {
            if submissionFault {
                anomalyValue.noteSubmissionFault()
            }
            for event in events {
                anomalyValue.noteCallback(
                    status: event.status,
                    infoFlags: event.infoFlags,
                    imagePresent: event.imagePresent,
                    truncated: truncated,
                    isFault: Self.classification(for: OSStatus(event.status)) != nil
                )
            }
        }
    }

    private func submitPrerollBatchOnQueue(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool,
        result: inout VideoPrerollBatchResult,
        preSwitchEntries: inout [VideoToolboxOutputRouter.Entry]
    ) -> (submitted: [PrerollSubmitted], failure: Error?) {
        var submitted: [PrerollSubmitted] = []
        for item in batch where item.packet.track == .video {
            noteSubmissionOrder(item.packet)
            var data = item.packet.data
            var truncated = false
            switch item.action {
            case .skip:
                result.skipped += 1
                continue
            case .truncate(let byteCount):
                if byteCount > 0, byteCount < data.count {
                    result.truncatedBytes += data.count - byteCount
                    data = Data(data.prefix(byteCount))
                }
                truncated = true
                result.truncated += 1
            case .submit:
                break
            }
            result.submitted += 1
            decodeCallCount += 1
            guard !data.isEmpty else { continue }
            do {
                if let entry = try submitPrerollItemOnQueue(
                    item.packet,
                    data: data,
                    truncated: truncated,
                    keepOutput: keepOutput,
                    preSwitchEntries: &preSwitchEntries
                ) {
                    submitted.append(entry)
                }
            } catch {
                return (submitted, error)
            }
        }
        return (submitted, nil)
    }

    private func submitPrerollItemOnQueue(
        _ packet: MediaPacket,
        data: Data,
        truncated: Bool,
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool,
        preSwitchEntries: inout [VideoToolboxOutputRouter.Entry]
    ) throws -> PrerollSubmitted? {
        noteSubmittedTiling(data, packet: packet)
        guard let prepared = try prepareSessionForPacketOnQueue(data) else {
            return nil
        }
        preSwitchEntries.append(contentsOf: prepared.drainedEntries)
        let timing = VideoToolboxTimingSubmission(
            submissionID: UInt64(decodeCallCount),
            decoderGeneration: queueSessionID,
            inputPTS: packet.pts,
            inputDTS: packet.dts,
            inputDuration: packet.duration,
            inputOrder: inputOrder
        )
        let (sample, sampleTiming) = try makeSampleBuffer(
            data: data,
            packet: packet,
            formatDescription: prepared.formatDescription,
            timingSubmission: timing
        )
        let identity = timing.identity
        let router = outputRouter
        router.register(
            submission: timing,
            packet: packet,
            nativeTiming: sampleTiming,
            truncated: truncated,
            keepOutput: keepOutput
        )
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            prepared.session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { status, callbackInfoFlags, imageBuffer, callbackPTS, callbackDuration in
            router.receive(
                identity: identity,
                status: status,
                infoFlags: callbackInfoFlags,
                imageBuffer: imageBuffer,
                callbackPTS: callbackPTS,
                callbackDuration: callbackDuration
            )
        }
        if let fault = Self.runtimeFault(for: status, stage: .decodeSubmission) {
            noteDecodeAnomalies(submissionStatus: status, events: [], truncated: truncated)
            logFaultIfNeeded(fault, status: status)
            throw fault
        }
        return PrerollSubmitted(timing: timing, packet: packet, truncated: truncated)
    }

    private func throwFirstPrerollCallbackFault(
        _ entries: [VideoToolboxOutputRouter.Entry]
    ) throws {
        for entry in entries {
            guard let failing = entry.records.first(where: {
                Self.classification(for: OSStatus($0.event.status)) != nil
            }) else {
                continue
            }
            let status = OSStatus(failing.event.status)
            if let fault = Self.runtimeFault(for: status, stage: .decodeCallback) {
                logFaultIfNeeded(fault, status: status)
                throw fault
            }
        }
    }

    private func resolvePrerollOutputs(
        _ entriesByIdentity: [VideoToolboxTimingIdentity: VideoToolboxOutputRouter.Entry],
        submitted: [PrerollSubmitted],
        preSwitchEntries: [VideoToolboxOutputRouter.Entry],
        into result: inout VideoPrerollBatchResult
    ) {
        let policy = VideoToolboxTimingPolicy()
        let preSwitchIdentities = Set(preSwitchEntries.map(\.submission.identity))
        let orderedEntries: [VideoToolboxOutputRouter.Entry] = preSwitchEntries + submitted.compactMap {
            guard !preSwitchIdentities.contains($0.timing.identity) else { return nil }
            return entriesByIdentity[$0.timing.identity]
        }
        for entry in orderedEntries {
            let events = entry.records.map(\.event)
            if events.first?.status == kVTVideoDecoderReferenceMissingErr,
               loggedReferenceMissingBatches < 4 {
                loggedReferenceMissingBatches += 1
                PlayerLog.log(
                    "[PathADecoder] event=referenceMissing sessionID=\(queueSessionID) " +
                    "pts=\(Self.mediaTimeDescription(entry.packet.pts)) " +
                    "keyframe=\(entry.packet.isKeyframe ? 1 : 0) — frame dropped, decoding continues"
                )
            }
            let resolution = policy.resolve(submission: entry.submission, outputEvents: events)
            for record in entry.records where record.event.imagePresent {
                guard let resolved = resolution.resolution(for: record.event) else { continue }
                switch resolved {
                case .callback(let pts, let duration), .oneToOneInputFallback(let pts, let duration, _):
                    framesProduced += 1
                    if let image = record.imageBuffer {
                        result.noteOutput(
                            MediaVideoFrame(
                                pts: pts, duration: duration, pixelBuffer: image
                            ),
                            keep: true
                        )
                    } else {
                        result.outputPTS.append(pts)
                        result.discardedFrames += 1
                    }
                case .unknown:
                    continue
                }
            }
        }
    }
}
