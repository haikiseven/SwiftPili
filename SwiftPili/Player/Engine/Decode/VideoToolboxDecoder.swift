import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The Core Media dependency bit carried by a compressed sample.
///
/// Core Media treats an absent `NotSync` attachment as sync, so the adapter
/// must write the value explicitly for both kinds of upstream packet. The
/// demuxer remains the authority for `MediaPacket.isKeyframe`; this policy only
/// maps that typed fact to the Core Media representation.
enum VideoToolboxSampleDependencyAttachmentPolicy {
    static func apply(to attachment: NSMutableDictionary, isKeyframe: Bool) {
        attachment[kCMSampleAttachmentKey_NotSync as NSString] = NSNumber(
            value: !isKeyframe
        )
    }
}

/// Path A **A2b** VideoToolbox hard-decode (partial offline).
///
/// - `open(formatHint:)` without a usable format still fails closed (no guessing
///   SPS/PPS from empty data offline).
/// - `open(formatDescription:)` creates a `VTDecompressionSession` and enables
///   `decode` → `CVPixelBuffer` frames when a real bitstream is supplied.
///
/// Production Demand session remains Stub/Fake until demux supplies a real
/// format description (A1b/A1c + codec config). Class (not actor): frames hold
/// non-Sendable `CVPixelBuffer`.
final class VideoToolboxDecoder: MediaVideoDecoding, MediaVideoDecodeTimingReporting, @unchecked Sendable {
    private static let debugSessionIDLock = NSLock()
    nonisolated(unsafe) private static var nextDebugSessionID: UInt64 = 0

    // Seam: the members below without `private` are touched by
    // `VideoToolboxDecoder+Preroll.swift` (the seek/resume-open preroll batch,
    // task 10-03). Swift scopes `private` to a file, so they are `internal`;
    // nothing outside the decoder's two files may use them. `stateLock`,
    // `session`, `formatDescription`, `opened`, `decodeCallCount`,
    // `framesProduced`, `loggedReferenceMissingBatches`,
    // `didLogFirstPrerollBatch`, `anomalyLock`, `anomalyValue`, `inputOrder`,
    // `logFaultIfNeeded`, `mediaTimeDescription`, `noteSubmissionOrder`,
    // `noteSubmittedTiling`, `makeSampleBuffer`, `noteDecodeAnomalies`,
    // `scalarTime`.

    /// `MediaVideoDecoding` is Sendable and warm repair retires an old VT
    /// decoder from a detached utility task after authority has moved to a new
    /// object. Serialize the native session and every field coupled to it so a
    /// late teardown cannot race decode/open/flush. A stuck invalidate then
    /// blocks only its retirement task, never the MainActor or replacement.
    let stateLock = NSLock()
    private let decodeTiming = MediaVideoDecodeTimingStore()

    func setDecodeTimingEnabled(_ enabled: Bool) {
        decodeTiming.setEnabled(enabled)
    }

    func decodeTimingSnapshot() -> MediaVideoDecodeTimingSnapshot? {
        decodeTiming.snapshot()
    }

    var session: VTDecompressionSession?
    var formatDescription: CMFormatDescription?
    var opened = false
    private(set) var debugSessionID: UInt64 = 0
    var framesProduced = 0
    var decodeCallCount = 0
    private var didLogFirstDecode = false
    private var didLogFirstPixelLayout = false
    private var flushCount = 0
    private var invalidateCount = 0
    private var loggedFaultStages: Set<MediaRuntimeFaultStage> = []
    /// What this decoder is being FED, as opposed to what it produces. Every
    /// other signal on this class counts output (`framesProduced`,
    /// `decodeCallCount`), which is exactly why a session decoding garbage
    /// reported health. Session-scoped: `open` resets it.
    private var integrity = VideoSubmissionIntegrity()
    /// avcC/hvcC length-prefix size for the current format, read from the
    /// format description itself rather than assumed to be 4.
    private var nalUnitHeaderLength: Int?
    /// Bounded log budget per session for each finding class, so a stream that
    /// violates one of these on every access unit costs a handful of lines
    /// rather than one per frame.
    private var loggedUnrootedSubmissions = 0
    var loggedReferenceMissingBatches = 0
    private var loggedDiscontinuities = 0
    private var loggedMalformedSamples = 0
    /// First preroll batch per native session is logged (proves on device that
    /// the async path ran), bounded like `firstDecode`.
    var didLogFirstPrerollBatch = false
    /// C11 counters. Own lock, short scalar sections only: the session reads
    /// them from the MainActor and must never wait behind a decode holding
    /// `stateLock`.
    let anomalyLock = NSLock()
    var anomalyValue = VideoDecodeAnomalyCounters()

    var decodeAnomalyCounters: VideoDecodeAnomalyCounters {
        anomalyLock.withLock { anomalyValue }
    }

    /// PathAFMP4/HLS compressed packets arrive in decode order. Keeping this
    /// declaration on the decoder makes the CMSampleTimingInfo choice explicit
    /// and leaves presentation-order callers a constructible opt-out.
    let inputOrder: VideoToolboxTimingInputOrder

    init(inputOrder: VideoToolboxTimingInputOrder = .decodeOrder) {
        self.inputOrder = inputOrder
    }

    private static func allocateDebugSessionID() -> UInt64 {
        debugSessionIDLock.lock()
        defer { debugSessionIDLock.unlock() }
        nextDebugSessionID &+= 1
        if nextDebugSessionID == 0 {
            nextDebugSessionID = 1
        }
        return nextDebugSessionID
    }

    func logFaultIfNeeded(_ fault: MediaRuntimeFault, status: OSStatus) {
        guard loggedFaultStages.insert(fault.stage).inserted else { return }
        PlayerLog.log(
            "[PathADecoder] event=fault sessionID=\(debugSessionID) " +
            "stage=\(fault.stage.rawValue) status=\(status) " +
            "class=\(fault.classification.rawValue) decodeCount=\(decodeCallCount)"
        )
    }

    /// Preserve the OSStatus distinction before the session decides whether a
    /// fault is eligible for an automatic retained-source reopen.
    ///
    /// `nil` means "not a fault". `kVTVideoDecoderReferenceMissingErr` is one:
    /// it is a per-frame status (the frame's reference was not decoded — e.g.
    /// an unrooted submission after an open), and VLC's VideoToolbox module
    /// maps it to OK and keeps decoding. The frame is simply not output; a
    /// decoder that never produces again is caught by the silent-no-output
    /// liveness detector, which measures frames in against frames out.
    static func classification(for status: OSStatus) -> MediaRuntimeFaultClassification? {
        switch status {
        case noErr, kVTVideoDecoderReferenceMissingErr:
            return nil
        case kVTInvalidSessionErr:
            return .invalidSession
        case kVTVideoDecoderMalfunctionErr:
            return .malfunction
        case kVTVideoDecoderBadDataErr:
            return .badData
        case kVTVideoDecoderUnsupportedDataFormatErr:
            return .unsupportedFormat
        case kVTVideoDecoderNotAvailableNowErr:
            return .input
        default:
            return .unknown
        }
    }

    /// A per-frame decoder error is a glitch, not a verdict: no mainstream
    /// stack ends playback on the first one. VLC restarts the VT session and
    /// resyncs at the next keyframe for BadData/InvalidSession/Malfunction and
    /// falls back to a software decoder for the rest; FFmpeg, mpv and
    /// GStreamer log and continue. The closest action this engine has to
    /// "restart and resync at a keyframe" is recovery boundary 1's bounded
    /// source-aware reopen at the current position, so every class that a
    /// fresh session can plausibly clear takes it.
    ///
    /// `unsupportedFormat` stays manual: VLC's answer to it is a DIFFERENT
    /// decoder, Demand has none, and reopening the same format into the same
    /// hardware decoder would spend the budget to reach the same refusal.
    static func recoverability(
        for classification: MediaRuntimeFaultClassification
    ) -> MediaRuntimeFaultRecoverability {
        switch classification {
        case .unsupportedFormat:
            return .manualRetry
        case .invalidSession, .malfunction, .badData, .input, .silentNoOutput, .unknown:
            return .automaticSourceAwareReopen
        }
    }

    static func runtimeFault(
        for status: OSStatus,
        stage: MediaRuntimeFaultStage
    ) -> MediaRuntimeFault? {
        guard let classification = classification(for: status) else { return nil }
        return MediaRuntimeFault(
            subsystem: .videoDecoder,
            stage: stage,
            classification: classification,
            recoverability: recoverability(for: classification),
            diagnostics: MediaRuntimeFaultDiagnostics(
                status: Int32(status),
                label: stage.rawValue
            )
        )
    }

    /// Carry the demuxer's dependency truth onto the CMSampleBuffer before it
    /// crosses the Core Media → VideoToolbox boundary. This is deliberately
    /// codec-agnostic: AVC, HEVC, and AV1 all use the same sample attachment
    /// contract.
    @discardableResult
    static func applySampleDependencyAttachment(
        to sample: CMSampleBuffer,
        isKeyframe: Bool
    ) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
        let attachment = attachments.first else {
            return false
        }
        VideoToolboxSampleDependencyAttachmentPolicy.apply(
            to: attachment,
            isKeyframe: isKeyframe
        )
        return true
    }

    /// Fail closed without a format description (A2a shell contract preserved).
    ///
    /// D3: when `formatHint` is an fMP4 **avcC/hvcC payload** (from
    /// `PathAFMP4Demuxer.formatConfig`), build a `CMFormatDescription` and open VT.
    /// Callers may still pass a real description via `open(formatDescription:)`.
    func open(formatHint: Data?) async throws {
        try await open(format: .codecConfig(codec: nil, config: formatHint ?? Data()))
    }

    /// Resolve demuxer-provided codec configuration into a `CMFormatDescription`
    /// inside the decoder boundary.
    func open(format: MediaVideoFormat) async throws {
        switch format {
        case .description(let description):
            try await open(formatDescription: description)
        case .codecConfig(let codec, let config, let codedDimensions):
            guard !config.isEmpty || codec?.lowercased() == "av01" else {
                throw MediaEngineError.notImplemented(
                    "VideoToolbox needs CMFormatDescription or avcC/hvcC config (A2b/D3)"
                )
            }
            try await open(formatDescription: try Self.makeFormatDescription(
                codec: codec,
                config: config,
                codedDimensions: codedDimensions
            ))
        }
    }

    /// Build a description from a sample-entry config payload. With no fourcc from
    /// the demuxer, prefer H.264 avcC (most Bili VOD) and fall back to HEVC —
    /// the behaviour the old `open(formatHint:)` had.
    private static func makeFormatDescription(
        codec: String?,
        config: Data,
        codedDimensions: MediaVideoCodedDimensions?
    ) throws -> CMFormatDescription {
        if let codec {
            return try PathACodecConfig.makeVideoFormatDescription(
                codec: codec, config: config, codedDimensions: codedDimensions
            )
        }
        do {
            return try PathACodecConfig.makeVideoFormatDescription(codec: "avc1", config: config)
        } catch {
            return try PathACodecConfig.makeVideoFormatDescription(codec: "hvc1", config: config)
        }
    }

    /// Open a VT decompression session for the given video format.
    func open(formatDescription: CMFormatDescription) async throws {
        try stateLock.withLock {
            closeLocked()

            // Request bi-planar 4:2:0 (NV12), AVSampleBufferDisplayLayer's native
            // pixel format (~1.5 bytes/pixel vs 4 bytes/pixel for BGRA).
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]

            // Nil outputCallback: use the block-based DecodeFrame API below.
            var sessionOut: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &sessionOut
            )
            guard status == noErr, let created = sessionOut else {
                throw MediaEngineError.decodeFailed(
                    "VTDecompressionSessionCreate status=\(status)"
                )
            }
            self.session = created
            self.formatDescription = formatDescription
            self.opened = true
            self.debugSessionID = Self.allocateDebugSessionID()
            self.framesProduced = 0
            self.decodeCallCount = 0
            self.didLogFirstDecode = false
            self.didLogFirstPixelLayout = false
            self.flushCount = 0
            self.invalidateCount = 0
            self.loggedFaultStages = []
            // A new native session means an empty reference buffer and an
            // unknown decode position; both integrity rules are session-scoped.
            self.integrity.reset()
            self.nalUnitHeaderLength = Self.nalUnitHeaderLength(of: formatDescription)
            self.loggedUnrootedSubmissions = 0
            self.loggedReferenceMissingBatches = 0
            self.loggedDiscontinuities = 0
            self.loggedMalformedSamples = 0
            self.didLogFirstPrerollBatch = false
            anomalyLock.withLock { anomalyValue = VideoDecodeAnomalyCounters() }
            PlayerLog.log(
                "[PathADecoder] event=create sessionID=\(debugSessionID) opened=1 " +
                "nalLen=\(self.nalUnitHeaderLength.map(String.init) ?? "unknown")"
            )
        }
    }

    /// avcC/hvcC length-prefix size, from the format description rather than
    /// assumed. `nil` means the walk is not attempted for this format — an
    /// unknown prefix size must not be reported as well-formed bytes.
    private static func nalUnitHeaderLength(
        of formatDescription: CMFormatDescription
    ) -> Int? {
        var length: Int32 = 0
        let status: OSStatus
        switch CMFormatDescriptionGetMediaSubType(formatDescription) {
        case kCMVideoCodecType_H264:
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &length
            )
        case kCMVideoCodecType_HEVC:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &length
            )
        default:
            return nil
        }
        guard status == noErr, (1...4).contains(Int(length)) else { return nil }
        return Int(length)
    }

    static func mediaTimeDescription(_ time: TimeInterval?) -> String {
        guard let time, time.isFinite else { return "n/a" }
        return String(format: "%.3f", time)
    }

    /// Called under `stateLock` from `decode`.
    private func logSubmissionDiscontinuity(
        _ kind: String,
        previousEnd: TimeInterval,
        next: TimeInterval,
        packet: MediaPacket
    ) {
        guard loggedDiscontinuities < 8 else { return }
        loggedDiscontinuities += 1
        let missing = VideoSubmissionIntegrity.missingFrames(
            previousEnd: previousEnd,
            next: next,
            duration: packet.duration
        )
        PlayerLog.log(
            "[PathADecoder] event=submission\(kind) sessionID=\(debugSessionID) " +
            "prevEnd=\(Self.mediaTimeDescription(previousEnd)) " +
            "dts=\(Self.mediaTimeDescription(next)) " +
            "pts=\(Self.mediaTimeDescription(packet.pts)) " +
            "frames=\(missing.map(String.init) ?? "n/a") " +
            "dur=\(Self.mediaTimeDescription(packet.duration)) " +
            "keyframe=\(packet.isKeyframe ? 1 : 0) " +
            "sample=\(packet.containerSampleIndex.map(String.init) ?? "n/a") " +
            "frag=\(packet.containerFragmentSequence.map(String.init) ?? "n/a") " +
            "offset=\(packet.containerSampleOffset.map(String.init) ?? "n/a") " +
            "submitted=\(integrity.observedSubmissions) " +
            "breaks=\(integrity.discontinuityCount)"
        )
    }

    /// What this decoder is being HANDED, observed before it is handed over.
    /// Called under `stateLock` for EVERY packet the caller consumed — the
    /// preroll batch calls it for skipped samples too, so an intentional skip
    /// is never reported as a decode-order gap (design C8).
    func noteSubmissionOrder(_ packet: MediaPacket) {
        // All three rules REPORT and none blocks the submission — see
        // `VideoSubmissionIntegrity` for why blocking rule 1 here was evaluated
        // and rejected (a dropped GOP crosses the 64-submission no-output limit
        // and settles as a user-visible Retry, which is worse than the seconds
        // of corruption it would replace).
        if case let .unrooted(submissionsSinceOpen) = integrity.noteRandomAccess(
            isKeyframe: packet.isKeyframe
        ), loggedUnrootedSubmissions < 4 {
            loggedUnrootedSubmissions += 1
            PlayerLog.log(
                "[PathADecoder] event=unrootedSubmission sessionID=\(debugSessionID) " +
                "sinceOpen=\(submissionsSinceOpen) " +
                "pts=\(Self.mediaTimeDescription(packet.pts)) " +
                "dts=\(Self.mediaTimeDescription(packet.dts)) " +
                "sample=\(packet.containerSampleIndex.map(String.init) ?? "n/a") " +
                "frag=\(packet.containerFragmentSequence.map(String.init) ?? "n/a")"
            )
        }
        switch integrity.noteDecodeOrder(dts: packet.dts, duration: packet.duration) {
        case let .gap(previousEnd, next):
            logSubmissionDiscontinuity(
                "gap", previousEnd: previousEnd, next: next, packet: packet
            )
        case let .regression(previousEnd, next):
            logSubmissionDiscontinuity(
                "regression", previousEnd: previousEnd, next: next, packet: packet
            )
        case .first, .contiguous, .unmeasurable:
            break
        }
    }

    /// Tiling is judged on the bytes actually submitted (a truncated AV1
    /// prefix in the preroll batch). Called under `stateLock`.
    func noteSubmittedTiling(_ data: Data, packet: MediaPacket) {
        let tiling = VideoSubmissionIntegrity.tiling(
            of: data,
            nalLengthSize: nalUnitHeaderLength
        )
        integrity.note(tiling: tiling)
        if tiling.isMalformed, loggedMalformedSamples < 8 {
            loggedMalformedSamples += 1
            PlayerLog.log(
                "[PathADecoder] event=malformedSample sessionID=\(debugSessionID) " +
                "tiling=\(tiling.diagnosticName) size=\(data.count) " +
                "nalLen=\(nalUnitHeaderLength.map(String.init) ?? "unknown") " +
                "keyframe=\(packet.isKeyframe ? 1 : 0) " +
                "pts=\(Self.mediaTimeDescription(packet.pts)) " +
                "sample=\(packet.containerSampleIndex.map(String.init) ?? "n/a") " +
                "frag=\(packet.containerFragmentSequence.map(String.init) ?? "n/a") " +
                "offset=\(packet.containerSampleOffset.map(String.init) ?? "n/a") " +
                "malformed=\(integrity.malformedCount)"
            )
        }
    }

    /// The one CMSampleBuffer construction, shared by `decode(_:)` and the
    /// preroll batch. Called under `stateLock`.
    func makeSampleBuffer(
        data dataCopy: Data,
        packet: MediaPacket,
        formatDescription: CMFormatDescription,
        timingSubmission: VideoToolboxTimingSubmission
    ) throws -> (CMSampleBuffer, CMSampleTimingInfo) {
        let sampleBlock = try Self.makeBlockBuffer(copying: dataCopy)
        let sampleTiming = VideoToolboxTimingPolicy().sampleTiming(for: timingSubmission)
        var timing = CMSampleTimingInfo(
            duration: Self.cmTime(sampleTiming.duration),
            presentationTimeStamp: Self.cmTime(sampleTiming.presentationTimeStamp),
            decodeTimeStamp: Self.cmTime(sampleTiming.decodeTimeStamp)
        )
        var sampleSize = dataCopy.count
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: sampleBlock,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sample = sampleBuffer else {
            throw MediaEngineError.decodeFailed(
                "CMSampleBufferCreateReady status=\(sbStatus)"
            )
        }
        guard Self.applySampleDependencyAttachment(
            to: sample,
            isKeyframe: packet.isKeyframe
        ) else {
            throw MediaEngineError.decodeFailed(
                "CMSampleBuffer sample dependency attachments unavailable"
            )
        }
        return (sample, timing)
    }

    private static func makeBlockBuffer(copying dataCopy: Data) throws -> CMBlockBuffer {
        var ownedBlock: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataCopy.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataCopy.count,
            flags: 0,
            blockBufferOut: &ownedBlock
        )
        guard createStatus == noErr, let sampleBlock = ownedBlock else {
            throw MediaEngineError.decodeFailed(
                "CMBlockBufferCreateWithMemoryBlock status=\(createStatus)"
            )
        }
        let replaceStatus: OSStatus = dataCopy.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else {
                return OSStatus(kCMBlockBufferBadLengthParameterErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: sampleBlock,
                offsetIntoDestination: 0,
                dataLength: dataCopy.count
            )
        }
        guard replaceStatus == noErr else {
            throw MediaEngineError.decodeFailed(
                "CMBlockBufferReplaceDataBytes status=\(replaceStatus)"
            )
        }
        return sampleBlock
    }

    func decode(_ packet: MediaPacket) async throws -> [MediaVideoFrame] {
        var trace = decodeTiming.observationID().map(VideoToolboxDecodeTimingTrace.init)
        defer {
            if let measurement = trace?.finish() {
                decodeTiming.record(measurement)
            }
        }
        return try stateLock.withLock {
            trace?.advance(to: .integrity)
            trace?.value.decoderSessionID = debugSessionID
            guard opened, let session, let formatDescription else {
            throw MediaEngineError.stopped
            }
            guard packet.track == .video else {
                trace?.value.failures = 0
                return []
            }
            decodeCallCount += 1

        guard !packet.data.isEmpty else {
            trace?.value.failures = 0
            return []
        }

        noteSubmissionOrder(packet)
        noteSubmittedTiling(packet.data, packet: packet)

        trace?.advance(to: .sampleConstruction)
        let dataCopy = packet.data
        let timingPolicy = VideoToolboxTimingPolicy()
        let timingSubmission = VideoToolboxTimingSubmission(
            submissionID: UInt64(decodeCallCount),
            decoderGeneration: debugSessionID,
            inputPTS: packet.pts,
            inputDTS: packet.dts,
            inputDuration: packet.duration,
            inputOrder: inputOrder
        )
        let (sample, timing) = try makeSampleBuffer(
            data: dataCopy,
            packet: packet,
            formatDescription: formatDescription,
            timingSubmission: timingSubmission
        )

        // Class box avoids Sendable mutation warnings on the VT output callback.
        // The call below intentionally uses flags: []: output callbacks are
        // consumed before decode returns. If asynchronous/temporal flags are
        // ever enabled, this local sink is not a delayed-output implementation;
        // a separate pending-submission boundary must be added first.
        final class PixelSink: @unchecked Sendable {
            let measurementStarted: ContinuousClock.Instant?
            var firstImageOffset: Duration?
            init(measurementStarted: ContinuousClock.Instant?) {
                self.measurementStarted = measurementStarted
            }
            var records: [VideoToolboxOutputRecord] = []
            var timingCollector = VideoToolboxTimingOutputCollector()

            var firstCallbackFailureStatus: OSStatus? {
                timingCollector.firstFailureStatus
            }

            func append(
                identity: VideoToolboxTimingIdentity,
                status: OSStatus,
                imageBuffer: CVPixelBuffer?,
                callbackPTS: CMTime,
                callbackDuration: CMTime,
                infoFlags: VTDecodeInfoFlags
            ) {
                if imageBuffer != nil, firstImageOffset == nil, let measurementStarted {
                    firstImageOffset = ContinuousClock.now - measurementStarted
                }
                let event = timingCollector.append(
                    identity: identity,
                    status: Int32(status),
                    imagePresent: imageBuffer != nil,
                    callbackPTS: VideoToolboxDecoder.scalarTime(callbackPTS),
                    callbackDuration: VideoToolboxDecoder.scalarTime(callbackDuration),
                    infoFlags: infoFlags.rawValue
                )
                records.append(VideoToolboxOutputRecord(
                    event: event,
                    imageBuffer: imageBuffer,
                    callbackPTS: callbackPTS,
                    callbackDuration: callbackDuration
                ))
            }
        }
        let sink = PixelSink(measurementStarted: trace?.started)
        var infoFlags = VTDecodeInfoFlags()
        // Synchronous decode fires the callback before returning (~one HW-decode
        // latency, no B-frame reorder queue stall) and emits frames in decode order
        // with display PTS; AVSampleBufferDisplayLayer reorders by PTS at display time.
        trace?.advance(to: .nativeCall)
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { status, callbackInfoFlags, imageBuffer, callbackPTS, callbackDuration in
            // A synchronous decode can still deliver more than one callback.
            // Preserve the first failure instead of allowing a later success
            // callback to overwrite it and make the submission look healthy.
            sink.append(
                identity: timingSubmission.identity,
                status: status,
                imageBuffer: imageBuffer,
                callbackPTS: callbackPTS,
                callbackDuration: callbackDuration,
                infoFlags: callbackInfoFlags
            )
        }

        trace?.advance(to: .postprocess)
        trace?.value.firstImageCallOffset = sink.firstImageOffset

        noteDecodeAnomalies(
            submissionStatus: decodeStatus,
            events: sink.records.map(\.event),
            truncated: false
        )
        if let fault = Self.runtimeFault(
            for: decodeStatus,
            stage: .decodeSubmission
        ) {
            logFaultIfNeeded(fault, status: decodeStatus)
            throw fault
        }
        // The first status that IS a fault, not merely the first non-zero one:
        // a ReferenceMissing frame ahead of a BadData frame in the same batch
        // must not hide the BadData.
        let callbackFaultStatus = sink.records
            .map { OSStatus($0.event.status) }
            .first { Self.classification(for: $0) != nil } ?? noErr
        if sink.firstCallbackFailureStatus == kVTVideoDecoderReferenceMissingErr,
           loggedReferenceMissingBatches < 4 {
            loggedReferenceMissingBatches += 1
            PlayerLog.log(
                "[PathADecoder] event=referenceMissing sessionID=\(debugSessionID) " +
                "pts=\(Self.mediaTimeDescription(packet.pts)) " +
                "keyframe=\(packet.isKeyframe ? 1 : 0) — frame dropped, decoding continues"
            )
        }
        if let fault = Self.runtimeFault(
            for: callbackFaultStatus,
            stage: .decodeCallback
        ) {
            logFaultIfNeeded(fault, status: callbackFaultStatus)
            throw fault
        }

        if !didLogFirstDecode {
            didLogFirstDecode = true
            let imageCount = sink.records.reduce(into: 0) { count, record in
                if record.imageBuffer != nil { count += 1 }
            }
            PlayerLog.log(
                "[PathADecoder] event=firstDecode sessionID=\(debugSessionID) " +
                "decodeCount=\(decodeCallCount) frames=\(imageCount)"
            )
        }

        if !didLogFirstPixelLayout, let firstPixelBuffer = sink.records.compactMap(\.imageBuffer).first {
            didLogFirstPixelLayout = true
            let layout = VideoPixelBufferDiagnostics.snapshot(firstPixelBuffer)
            PlayerLog.log(
                "[PathADecoder] pixelLayout sessionID=\(debugSessionID) " +
                layout.logDescription
            )
        }

        let timingResolution = timingPolicy.resolve(
            submission: timingSubmission,
            outputEvents: sink.records.map(\.event)
        )
        var frames: [MediaVideoFrame] = []
        if case .outputs = timingResolution.outcome {
            for record in sink.records {
                guard let pixelBuffer = record.imageBuffer else { continue }
                guard let resolvedOutput = timingResolution.resolution(for: record.event) else {
                    // A resolution without the matching callback identity is
                    // not safe to associate with this image. This should be
                    // unreachable for the current policy, but failing closed
                    // here prevents a future reorder/partial-result bug from
                    // stamping one callback's timing onto another image.
                    continue
                }
                switch resolvedOutput {
                case .callback(let pts, let duration),
                     .oneToOneInputFallback(let pts, let duration, _):
                    frames.append(
                        MediaVideoFrame(
                            pts: pts,
                            duration: duration,
                            pixelBuffer: pixelBuffer,
                            displayCoverage: record.displayCoverage(
                                packet: packet, resolution: resolvedOutput, submitted: timing
                            )
                        )
                    )
                    framesProduced += 1
                case .unknown:
                    // An unresolved callback is an observed event, not a
                    // timed frame. Withholding it keeps presentation proof
                    // from being satisfied by guessed timing.
                    continue
                }
            }
        }
            trace?.value.outputFrames = frames.count
            trace?.value.failures = 0
            return frames
        }
    }

    static func scalarTime(_ time: CMTime) -> TimeInterval? {
        guard CMTIME_IS_VALID(time), CMTIME_IS_NUMERIC(time), time.isValid, time.isNumeric else {
            return nil
        }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return nil }
        return seconds
    }

    private static func cmTime(_ value: TimeInterval?) -> CMTime {
        guard let value, value.isFinite else { return .invalid }
        // CMTime stores its value in Int64 at the requested timescale. Reject
        // values that cannot fit before calling the conversion routine; a
        // finite Double is not by itself a representable Core Media time.
        let maxRepresentableSeconds = Double(Int64.max - 1) / 600
        guard abs(value) <= maxRepresentableSeconds else { return .invalid }
        let converted = CMTime(seconds: value, preferredTimescale: 600)
        guard CMTIME_IS_VALID(converted), CMTIME_IS_NUMERIC(converted),
              converted.isValid, converted.isNumeric else {
            return .invalid
        }
        // Do not silently turn a non-zero scalar into a zero CMTime through
        // preferred-timescale quantization. Returning invalid makes Core Media
        // reject the submission instead of manufacturing a duplicate timing
        // point or zero duration.
        let roundTripped = CMTimeGetSeconds(converted)
        guard roundTripped.isFinite,
              value == 0 || (roundTripped != 0 && value.sign == roundTripped.sign) else {
            return .invalid
        }
        return converted
    }

    func flush() async {
        stateLock.withLock {
            // Every flush here precedes submissions from a different position,
            // so the decode-order baseline is dropped; the session's random
            // access fact survives (see `noteFlush`).
            integrity.noteFlush()
            if let session {
                flushCount &+= 1
                if flushCount <= 4 {
                    PlayerLog.log(
                        "[PathADecoder] event=flush sessionID=\(debugSessionID) " +
                        "count=\(flushCount)"
                    )
                }
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
        }
    }

    func close() async {
        stateLock.withLock {
            closeLocked()
        }
    }

    private func closeLocked() {
        if let session {
            invalidateCount &+= 1
            if invalidateCount <= 2 {
                PlayerLog.log(
                    "[PathADecoder] event=invalidate sessionID=\(debugSessionID) " +
                    "count=\(invalidateCount)"
                )
            }
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        opened = false
        debugSessionID = 0
    }
}
