import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// The seek / resume-open preroll batch (task 10-03-demand-seek-long-preroll,
// design §4.3, contract C1–C8, C11). The ONLY asynchronous VideoToolbox path
// in the decoder; `decode(_:)` stays synchronous with `flags: []`. Lives in its
// own file through the seam documented on `VideoToolboxDecoder`.

/// Evidence from one output callback of an asynchronous preroll submission.
struct VideoToolboxPrerollCallback {
    let identity: VideoToolboxTimingIdentity
    let status: OSStatus
    let infoFlags: VTDecodeInfoFlags
    let imagePresent: Bool
    /// Retained only when the session's `keepOutput` accepted the output; a
    /// rejected image is released inside the callback.
    let keptImage: CVPixelBuffer?
    let pts: TimeInterval?
    let duration: TimeInterval?
    let nativePTS: CMTime
    let nativeDuration: CMTime
}

/// Callbacks may run on VideoToolbox threads while later items are still being
/// submitted, so the sink is locked. One timing collector per submission
/// identity keeps callback indices per submission, as the timing policy needs.
final class VideoToolboxPrerollBatchSink: @unchecked Sendable {
    struct Record {
        let event: VideoToolboxTimingOutputEvent
        let keptImage: CVPixelBuffer?
        let nativePTS: CMTime
        let nativeDuration: CMTime
    }

    private let lock = NSLock()
    private var collectors: [VideoToolboxTimingIdentity: VideoToolboxTimingOutputCollector] = [:]
    private var records: [Record] = []

    func append(_ callback: VideoToolboxPrerollCallback) {
        lock.withLock {
            var collector = collectors[callback.identity] ?? VideoToolboxTimingOutputCollector()
            let event = collector.append(
                identity: callback.identity,
                status: Int32(callback.status),
                imagePresent: callback.imagePresent,
                callbackPTS: callback.pts,
                callbackDuration: callback.duration,
                infoFlags: callback.infoFlags.rawValue
            )
            collectors[callback.identity] = collector
            records.append(Record(event: event, keptImage: callback.keptImage,
                                  nativePTS: callback.nativePTS, nativeDuration: callback.nativeDuration))
        }
    }

    func snapshot() -> [Record] {
        lock.withLock { records }
    }
}

extension VideoToolboxDecoder {
    private struct PrerollSubmitted {
        let timing: VideoToolboxTimingSubmission
        let packet: MediaPacket
        let truncated: Bool
        let nativeTiming: CMSampleTimingInfo
    }

    private struct PrerollBatchContext {
        let session: VTDecompressionSession
        let formatDescription: CMFormatDescription
        let sink: VideoToolboxPrerollBatchSink
        let keepOutput: @Sendable (TimeInterval, TimeInterval) -> Bool
    }

    /// Up to one batch (the session caps it at 32) is submitted with
    /// `kVTDecodeFrame_EnableAsynchronousDecompression` and nothing else —
    /// never `1xRealTimePlayback`, `EnableTemporalProcessing` or
    /// `DoNotOutputFrame` (C4) — then `VTDecompressionSessionWaitForAsynchronousFrames`
    /// drains it before this returns, on every exit path (C1). The whole batch
    /// runs under `stateLock`, so `flush()`/`close()` wait at most one batch.
    /// Faults classify exactly as in `decode(_:)` (C5).
    func decodePrerollBatch(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) async throws -> VideoPrerollBatchResult {
        try stateLock.withLock {
            guard opened, let session, let formatDescription else {
                throw MediaEngineError.stopped
            }
            let started = ContinuousClock.now
            let context = PrerollBatchContext(
                session: session,
                formatDescription: formatDescription,
                sink: VideoToolboxPrerollBatchSink(),
                keepOutput: keepOutput
            )
            var result = VideoPrerollBatchResult()
            let (submitted, failure) = submitPrerollBatch(batch, context: context, result: &result)
            // C1: every callback has fired before anything below — on the
            // normal path and on both failure exits.
            let waitStarted = ContinuousClock.now
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            let waitMs = Int(waitStarted.duration(to: .now) / .milliseconds(1))

            let records = context.sink.snapshot()
            let truncated = Set(submitted.filter(\.truncated).map(\.timing.identity))
            for record in records {
                noteDecodeAnomalies(
                    submissionStatus: noErr,
                    events: [record.event],
                    truncated: truncated.contains(record.event.identity)
                )
            }
            if let failure {
                // `decode(_:)` order: a callback fault of an item submitted
                // BEFORE the failing one would have been thrown before the
                // failing item was ever reached.
                let earlier = Set(submitted.map(\.timing.identity))
                try throwFirstPrerollCallbackFault(records.filter { earlier.contains($0.event.identity) })
                throw failure
            }
            try throwFirstPrerollCallbackFault(records)
            resolvePrerollOutputs(records, submitted: submitted, into: &result)
            if !didLogFirstPrerollBatch {
                didLogFirstPrerollBatch = true
                PlayerLog.log(
                    "[PathADecoder] event=prerollBatch sessionID=\(debugSessionID) " +
                    "flags=async items=\(batch.count) submitted=\(result.submitted) " +
                    "skipped=\(result.skipped) truncated=\(result.truncated) " +
                    "outputs=\(result.outputPTS.count) " +
                    "batchMs=\(Int(started.duration(to: .now) / .milliseconds(1))) waitMs=\(waitMs)"
                )
            }
            return result
        }
    }

    /// Counting only (design C11) — called under `stateLock`.
    func noteDecodeAnomalies(
        submissionStatus: OSStatus,
        events: [VideoToolboxTimingOutputEvent],
        truncated: Bool
    ) {
        anomalyLock.withLock {
            if Self.classification(for: submissionStatus) != nil {
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

    /// Called under `stateLock`. Stops at the first failure (sample
    /// construction or a submission status classified as a fault).
    private func submitPrerollBatch(
        _ batch: [VideoPrerollSubmission],
        context: PrerollBatchContext,
        result: inout VideoPrerollBatchResult
    ) -> (submitted: [PrerollSubmitted], failure: Error?) {
        var submitted: [PrerollSubmitted] = []
        for item in batch where item.packet.track == .video {
            // Every consumed packet feeds the order baseline, skipped ones
            // included, so an intentional skip is not a reported gap (C8).
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
                submitted.append(try submitPrerollItem(item.packet, data: data, truncated: truncated, context: context))
            } catch {
                return (submitted, error)
            }
        }
        return (submitted, nil)
    }

    private func submitPrerollItem(
        _ packet: MediaPacket,
        data: Data,
        truncated: Bool,
        context: PrerollBatchContext
    ) throws -> PrerollSubmitted {
        noteSubmittedTiling(data, packet: packet)
        let timing = VideoToolboxTimingSubmission(
            submissionID: UInt64(decodeCallCount),
            decoderGeneration: debugSessionID,
            inputPTS: packet.pts,
            inputDTS: packet.dts,
            inputDuration: packet.duration,
            inputOrder: inputOrder
        )
        let (sample, sampleTiming) = try makeSampleBuffer(
            data: data,
            packet: packet,
            formatDescription: context.formatDescription,
            timingSubmission: timing
        )
        let identity = timing.identity
        let inputPTS = packet.pts
        let inputDuration = packet.duration
        let keepOutput = context.keepOutput
        let sink = context.sink
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            context.session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { status, callbackInfoFlags, imageBuffer, callbackPTS, callbackDuration in
            let pts = VideoToolboxDecoder.scalarTime(callbackPTS)
            let duration = VideoToolboxDecoder.scalarTime(callbackDuration)
            // The same timing the one-to-one resolution would pick.
            let keep = imageBuffer != nil
                && keepOutput(pts ?? inputPTS, duration ?? inputDuration)
            sink.append(VideoToolboxPrerollCallback(
                identity: identity,
                status: status,
                infoFlags: callbackInfoFlags,
                imagePresent: imageBuffer != nil,
                keptImage: keep ? imageBuffer : nil,
                pts: pts,
                duration: duration, nativePTS: callbackPTS, nativeDuration: callbackDuration
            ))
        }
        if let fault = Self.runtimeFault(for: status, stage: .decodeSubmission) {
            noteDecodeAnomalies(submissionStatus: status, events: [], truncated: truncated)
            logFaultIfNeeded(fault, status: status)
            throw fault
        }
        return PrerollSubmitted(timing: timing, packet: packet, truncated: truncated, nativeTiming: sampleTiming)
    }

    /// First callback status that IS a fault, in callback order (C5).
    /// ReferenceMissing and `frameDropped` are not faults.
    private func throwFirstPrerollCallbackFault(
        _ records: [VideoToolboxPrerollBatchSink.Record]
    ) throws {
        guard let failing = records.first(where: {
            Self.classification(for: OSStatus($0.event.status)) != nil
        }) else {
            return
        }
        let status = OSStatus(failing.event.status)
        if let fault = Self.runtimeFault(for: status, stage: .decodeCallback) {
            logFaultIfNeeded(fault, status: status)
            throw fault
        }
    }

    /// Per-submission timing resolution through the same policy
    /// `decode(_:)` uses (C3). Unknown timing is withheld, as there.
    private func resolvePrerollOutputs(
        _ records: [VideoToolboxPrerollBatchSink.Record],
        submitted: [PrerollSubmitted],
        into result: inout VideoPrerollBatchResult
    ) {
        let policy = VideoToolboxTimingPolicy()
        for item in submitted {
            let events = records.filter { $0.event.identity == item.timing.identity }
            if events.first?.event.status == kVTVideoDecoderReferenceMissingErr,
               loggedReferenceMissingBatches < 4 {
                loggedReferenceMissingBatches += 1
                PlayerLog.log(
                    "[PathADecoder] event=referenceMissing sessionID=\(debugSessionID) " +
                    "pts=\(Self.mediaTimeDescription(item.packet.pts)) " +
                    "keyframe=\(item.packet.isKeyframe ? 1 : 0) — frame dropped, decoding continues"
                )
            }
            let resolution = policy.resolve(submission: item.timing, outputEvents: events.map(\.event))
            for record in events where record.event.imagePresent {
                guard let resolved = resolution.resolution(for: record.event) else { continue }
                switch resolved {
                case .callback(let pts, let duration), .oneToOneInputFallback(let pts, let duration, _):
                    framesProduced += 1
                    if let image = record.keptImage {
                        result.noteOutput(
                            MediaVideoFrame(
                                pts: pts, duration: duration, pixelBuffer: image,
                                displayCoverage: VideoToolboxOutputRecord(
                                    event: record.event, imageBuffer: image,
                                    callbackPTS: record.nativePTS, callbackDuration: record.nativeDuration
                                ).displayCoverage(packet: item.packet,
                                                  resolution: resolved,
                                                  submitted: item.nativeTiming)
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
