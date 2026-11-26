import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum VideoToolboxSampleDependencyAttachmentPolicy {
    static func apply(to attachment: NSMutableDictionary, isKeyframe: Bool) {
        attachment[kCMSampleAttachmentKey_NotSync as NSString] = NSNumber(value: !isKeyframe)
    }
}

final class VideoToolboxOutputRouter: @unchecked Sendable {
    struct Record {
        let event: VideoToolboxTimingOutputEvent
        let imageBuffer: CVPixelBuffer?
        let callbackPTS: CMTime
        let callbackDuration: CMTime
    }

    struct Entry {
        let submission: VideoToolboxTimingSubmission
        let packet: MediaPacket
        let nativeTiming: CMSampleTimingInfo
        let truncated: Bool
        let keepOutput: (@Sendable (TimeInterval, TimeInterval) -> Bool)?
        var measurementStarted: ContinuousClock.Instant?
        var firstImageOffset: Duration?
        var collector = VideoToolboxTimingOutputCollector()
        var records: [Record] = []
    }

    private static let maxPendingEntries = 16

    private let lock = NSLock()
    private var activeGeneration: UInt64 = 0
    private var pendingBySubmission: [UInt64: Entry] = [:]
    private var submissionOrder: [UInt64] = []

    func reset(sessionGeneration: UInt64) {
        lock.withLock {
            activeGeneration = sessionGeneration
            pendingBySubmission.removeAll()
            submissionOrder.removeAll()
        }
    }

    func clear() {
        lock.withLock {
            pendingBySubmission.removeAll()
            submissionOrder.removeAll()
        }
    }

    func register(
        submission: VideoToolboxTimingSubmission,
        packet: MediaPacket,
        nativeTiming: CMSampleTimingInfo,
        truncated: Bool = false,
        measurementStarted: ContinuousClock.Instant? = nil,
        keepOutput: (@Sendable (TimeInterval, TimeInterval) -> Bool)? = nil
    ) {
        lock.withLock {
            let id = submission.identity.submissionID
            pendingBySubmission[id] = Entry(
                submission: submission,
                packet: packet,
                nativeTiming: nativeTiming,
                truncated: truncated,
                keepOutput: keepOutput,
                measurementStarted: measurementStarted
            )
            submissionOrder.append(id)
            while submissionOrder.count > Self.maxPendingEntries {
                let evicted = submissionOrder.removeFirst()
                pendingBySubmission.removeValue(forKey: evicted)
            }
        }
    }

    func receive(
        identity: VideoToolboxTimingIdentity,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVPixelBuffer?,
        callbackPTS: CMTime,
        callbackDuration: CMTime
    ) {
        let pts = VideoToolboxDecoder.scalarTime(callbackPTS)
        let duration = VideoToolboxDecoder.scalarTime(callbackDuration)
        lock.withLock {
            guard identity.decoderGeneration == activeGeneration,
                  var entry = pendingBySubmission[identity.submissionID] else { return }
            if imageBuffer != nil, entry.firstImageOffset == nil, let started = entry.measurementStarted {
                entry.firstImageOffset = ContinuousClock.now - started
            }
            let event = entry.collector.append(
                identity: identity,
                status: Int32(status),
                imagePresent: imageBuffer != nil,
                callbackPTS: pts,
                callbackDuration: duration,
                infoFlags: infoFlags.rawValue
            )
            let keepImage: CVPixelBuffer?
            if let imageBuffer, let keepOutput = entry.keepOutput {
                let resolvedPTS = pts ?? entry.packet.pts
                let resolvedDuration = duration ?? entry.packet.duration
                keepImage = keepOutput(resolvedPTS, resolvedDuration) ? imageBuffer : nil
            } else {
                keepImage = imageBuffer
            }
            entry.records.append(Record(
                event: event,
                imageBuffer: keepImage,
                callbackPTS: callbackPTS,
                callbackDuration: callbackDuration
            ))
            pendingBySubmission[identity.submissionID] = entry
        }
    }

    func drainReady(forGeneration generation: UInt64) -> [Entry] {
        lock.withLock {
            guard generation == activeGeneration, !submissionOrder.isEmpty else { return [] }
            if submissionOrder.count == 1 {
                let id = submissionOrder[0]
                guard let entry = pendingBySubmission[id] else {
                    submissionOrder.removeAll(keepingCapacity: true)
                    return []
                }
                guard !entry.records.isEmpty else { return [] }
                pendingBySubmission.removeValue(forKey: id)
                submissionOrder.removeAll(keepingCapacity: true)
                return [entry]
            }
            var ready: [Entry] = []
            var remainingOrder: [UInt64] = []
            remainingOrder.reserveCapacity(submissionOrder.count)
            for id in submissionOrder {
                guard let entry = pendingBySubmission[id] else { continue }
                if entry.records.isEmpty {
                    remainingOrder.append(id)
                    continue
                }
                ready.append(entry)
                pendingBySubmission.removeValue(forKey: id)
            }
            submissionOrder = remainingOrder
            return ready
        }
    }

    func drain(identities: [VideoToolboxTimingIdentity], forGeneration generation: UInt64) -> [Entry] {
        lock.withLock {
            guard generation == activeGeneration else { return [] }
            let targetIDs = Set(identities.map(\.submissionID))
            var drained: [Entry] = []
            for id in identities.map(\.submissionID) {
                if let entry = pendingBySubmission.removeValue(forKey: id) {
                    drained.append(entry)
                }
            }
            submissionOrder.removeAll { targetIDs.contains($0) }
            return drained
        }
    }
}

final class VideoToolboxDecoder: MediaVideoDecoding, MediaVideoDecodeTimingReporting, @unchecked Sendable {
    private static let debugSessionIDLock = NSLock()
    nonisolated(unsafe) private static var nextDebugSessionID: UInt64 = 0

    let decodeQueue = DispatchQueue(label: "com.swiftpili.videotoolbox.decode", qos: .userInitiated)
    private let sessionIDAccessLock = NSLock()
    private var _debugSessionID: UInt64 = 0
    private let decodeTiming = MediaVideoDecodeTimingStore()

    var debugSessionID: UInt64 {
        sessionIDAccessLock.withLock { _debugSessionID }
    }

    func setDecodeTimingEnabled(_ enabled: Bool) {
        decodeTiming.setEnabled(enabled)
    }

    func decodeTimingSnapshot() -> MediaVideoDecodeTimingSnapshot? {
        decodeTiming.snapshot()
    }

    var session: VTDecompressionSession?
    var formatDescription: CMFormatDescription?
    var opened = false
    var queueSessionID: UInt64 = 0
    var framesProduced = 0
    var decodeCallCount = 0
    private var didLogFirstDecode = false
    private var didLogFirstPixelLayout = false
    private var flushCount = 0
    private var invalidateCount = 0
    private var loggedFaultStages: Set<MediaRuntimeFaultStage> = []
    private var integrity = VideoSubmissionIntegrity()
    private var nalUnitHeaderLength: Int?
    private var pendingInBandCodec: PathACodecConfig.InBandVideoCodec?
    private var currentParameterSets: [Data] = []
    private var loggedUnrootedSubmissions = 0
    var loggedReferenceMissingBatches = 0
    private var loggedDiscontinuities = 0
    private var loggedMalformedSamples = 0
    var didLogFirstPrerollBatch = false
    let anomalyLock = NSLock()
    var anomalyValue = VideoDecodeAnomalyCounters()
    let outputRouter = VideoToolboxOutputRouter()

    var decodeAnomalyCounters: VideoDecodeAnomalyCounters {
        anomalyLock.withLock { anomalyValue }
    }

    let inputOrder: VideoToolboxTimingInputOrder

    init(inputOrder: VideoToolboxTimingInputOrder = .decodeOrder) {
        self.inputOrder = inputOrder
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        outputRouter.clear()
    }

    func onDecodeQueue<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            decodeQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func onDecodeQueue(_ work: @Sendable @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                work()
                continuation.resume()
            }
        }
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
            "[PathADecoder] event=fault sessionID=\(queueSessionID) " +
            "stage=\(fault.stage.rawValue) status=\(status) " +
            "class=\(fault.classification.rawValue) decodeCount=\(decodeCallCount)"
        )
    }

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

    static func recoverability(
        for classification: MediaRuntimeFaultClassification
    ) -> MediaRuntimeFaultRecoverability {
        switch classification {
        case .invalidSession, .malfunction, .badData, .unsupportedFormat, .input, .silentNoOutput, .unknown:
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

    func open(formatHint: Data?) async throws {
        try await open(format: .codecConfig(codec: nil, config: formatHint ?? Data()))
    }

    func open(format: MediaVideoFormat) async throws {
        switch format {
        case .description(let description):
            try await open(formatDescription: description)
        case .codecConfig(let codec, let config, let codedDimensions, let extensionAtoms):
            if let bootstrap = PathACodecConfig.inBandBootstrap(codec: codec, config: config) {
                if !config.isEmpty,
                   let description = try? Self.makeFormatDescription(
                       codec: codec,
                       config: config,
                       codedDimensions: codedDimensions,
                       extensionAtoms: extensionAtoms
                   ) {
                    try await open(formatDescription: description)
                    return
                }
                await onDecodeQueue {
                    self.openDeferredInBandOnQueue(codec: bootstrap.codec, nalLengthSize: bootstrap.nalLengthSize)
                }
                return
            }
            guard !config.isEmpty || codec?.lowercased() == "av01" else {
                throw MediaEngineError.notImplemented(
                    "VideoToolbox needs CMFormatDescription or avcC/hvcC config (A2b/D3)"
                )
            }
            try await open(formatDescription: try Self.makeFormatDescription(
                codec: codec,
                config: config,
                codedDimensions: codedDimensions,
                extensionAtoms: extensionAtoms
            ))
        }
    }

    private static func makeFormatDescription(
        codec: String?,
        config: Data,
        codedDimensions: MediaVideoCodedDimensions?,
        extensionAtoms: [String: Data] = [:]
    ) throws -> CMFormatDescription {
        if let codec {
            return try PathACodecConfig.makeVideoFormatDescription(
                codec: codec,
                config: config,
                codedDimensions: codedDimensions,
                extensionAtoms: extensionAtoms
            )
        }
        do {
            return try PathACodecConfig.makeVideoFormatDescription(codec: "avc1", config: config)
        } catch {
            return try PathACodecConfig.makeVideoFormatDescription(codec: "hvc1", config: config)
        }
    }

    func open(formatDescription: CMFormatDescription) async throws {
        try await onDecodeQueue {
            try self.openSessionOnQueue(formatDescription: formatDescription, resetSessionStats: true)
        }
    }

    private func openDeferredInBandOnQueue(
        codec: PathACodecConfig.InBandVideoCodec,
        nalLengthSize: Int
    ) {
        closeOnQueue()
        let sessionID = Self.allocateDebugSessionID()
        setSessionID(sessionID)
        self.opened = true
        self.pendingInBandCodec = codec
        self.nalUnitHeaderLength = nalLengthSize
        self.currentParameterSets = []
        resetPerSessionCountersOnQueue()
        outputRouter.reset(sessionGeneration: sessionID)
        PlayerLog.log(
            "[PathADecoder] event=create sessionID=\(sessionID) opened=1 deferredInBand=1 nalLen=\(nalLengthSize)"
        )
    }

    private func openSessionOnQueue(
        formatDescription: CMFormatDescription,
        resetSessionStats: Bool
    ) throws {
        if resetSessionStats {
            closeOnQueue()
        } else if let existing = session {
            VTDecompressionSessionInvalidate(existing)
            session = nil
        }

        let pixelFormat = Self.preferredPixelFormatType(for: formatDescription)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

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
        self.pendingInBandCodec = Self.inBandCodec(for: formatDescription)
        self.nalUnitHeaderLength = Self.nalUnitHeaderLength(of: formatDescription)
        self.currentParameterSets = Self.extractParameterSets(from: formatDescription)

        let sessionID = resetSessionStats ? Self.allocateDebugSessionID() : queueSessionID
        setSessionID(sessionID)
        outputRouter.reset(sessionGeneration: sessionID)
        if resetSessionStats {
            resetPerSessionCountersOnQueue()
        }
        PlayerLog.log(
            "[PathADecoder] event=create sessionID=\(sessionID) opened=1 " +
            "nalLen=\(self.nalUnitHeaderLength.map(String.init) ?? "unknown") " +
            "pixelFmt=\(pixelFormat)"
        )
    }

    private func setSessionID(_ id: UInt64) {
        queueSessionID = id
        sessionIDAccessLock.withLock { _debugSessionID = id }
    }

    private func resetPerSessionCountersOnQueue() {
        framesProduced = 0
        decodeCallCount = 0
        didLogFirstDecode = false
        didLogFirstPixelLayout = false
        flushCount = 0
        invalidateCount = 0
        loggedFaultStages = []
        integrity.reset()
        loggedUnrootedSubmissions = 0
        loggedReferenceMissingBatches = 0
        loggedDiscontinuities = 0
        loggedMalformedSamples = 0
        didLogFirstPrerollBatch = false
        anomalyLock.withLock { anomalyValue = VideoDecodeAnomalyCounters() }
    }

    private static func preferredPixelFormatType(for formatDescription: CMFormatDescription) -> OSType {
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any]
        let fullRange = (extensions?[kCMFormatDescriptionExtension_FullRangeVideo] as? NSNumber)?.boolValue == true
        let isDolbyVision = CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_DolbyVisionHEVC
        if isDolbyVision || is10BitOrHDR(extensions: extensions) {
            return fullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        return fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static func is10BitOrHDR(extensions: [CFString: Any]?) -> Bool {
        guard let extensions else { return false }
        if let bits = (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue,
           bits >= 10 {
            return true
        }
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] {
            let transferString = String(describing: transfer)
            if transferString == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                || transferString == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                || transferString == (kCVImageBufferTransferFunction_Linear as String) {
                return true
            }
        }
        if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any] {
            if atoms["dvcC"] != nil || atoms["dvvC"] != nil || atoms["dvwC"] != nil {
                return true
            }
            if let hvcC = atoms["hvcC"] as? Data {
                let bytes = [UInt8](hvcC)
                if bytes.count >= 2 && (bytes[1] & 0x1F) == 2 { return true }
                if bytes.count >= 19 && ((bytes[17] & 0x07) >= 2 || (bytes[18] & 0x07) >= 2) { return true }
            }
            if let av1C = atoms["av1C"] as? Data {
                let bytes = [UInt8](av1C)
                if bytes.count >= 4 && (bytes[2] & 0x40) != 0 { return true }
            }
        }
        return false
    }

    private static func inBandCodec(for formatDescription: CMFormatDescription) -> PathACodecConfig.InBandVideoCodec? {
        switch CMFormatDescriptionGetMediaSubType(formatDescription) {
        case kCMVideoCodecType_H264: .h264
        case kCMVideoCodecType_HEVC: .hevc
        default: nil
        }
    }

    private static func extractParameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var count = 0
        switch CMFormatDescriptionGetMediaSubType(formatDescription) {
        case kCMVideoCodecType_H264:
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            return (0..<count).compactMap { index in
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let ptr, size > 0 else { return nil }
                return Data(bytes: ptr, count: size)
            }
        case kCMVideoCodecType_HEVC:
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            return (0..<count).compactMap { index in
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let ptr, size > 0 else { return nil }
                return Data(bytes: ptr, count: size)
            }
        default:
            return []
        }
    }

    func prepareSessionForPacketOnQueue(
        _ data: Data
    ) throws -> (session: VTDecompressionSession, formatDescription: CMFormatDescription, drainedEntries: [VideoToolboxOutputRouter.Entry])? {
        var drainedEntries: [VideoToolboxOutputRouter.Entry] = []
        if let codec = pendingInBandCodec {
            let nalLength = nalUnitHeaderLength ?? 4
            if let parameterSets = PathACodecConfig.extractInBandParameterSets(
                from: data, nalLengthSize: nalLength, codec: codec
            ), parameterSets != currentParameterSets {
                let newDescription = try PathACodecConfig.makeInBandFormatDescription(
                    codec: codec, parameterSets: parameterSets, nalLengthSize: nalLength
                )
                if let existing = session {
                    if VTDecompressionSessionCanAcceptFormatDescription(existing, formatDescription: newDescription) {
                        self.formatDescription = newDescription
                        self.currentParameterSets = parameterSets
                    } else {
                        VTDecompressionSessionWaitForAsynchronousFrames(existing)
                        drainedEntries = outputRouter.drainReady(forGeneration: queueSessionID)
                        try openSessionOnQueue(formatDescription: newDescription, resetSessionStats: false)
                    }
                } else {
                    try openSessionOnQueue(formatDescription: newDescription, resetSessionStats: false)
                }
            }
        }
        guard let session, let formatDescription else { return nil }
        return (session, formatDescription, drainedEntries)
    }

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
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &length
            )
            if status != noErr,
               let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
               let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any],
               let hvcC = atoms["hvcC"] as? Data,
               hvcC.count >= 22 {
                let fallbackLen = Int(hvcC[21] & 0x03) + 1
                if (1...4).contains(fallbackLen) { return fallbackLen }
            }
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
            "[PathADecoder] event=submission\(kind) sessionID=\(queueSessionID) " +
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

    func noteSubmissionOrder(_ packet: MediaPacket) {
        if case let .unrooted(submissionsSinceOpen) = integrity.noteRandomAccess(
            isKeyframe: packet.isKeyframe
        ), loggedUnrootedSubmissions < 4 {
            loggedUnrootedSubmissions += 1
            PlayerLog.log(
                "[PathADecoder] event=unrootedSubmission sessionID=\(queueSessionID) " +
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

    func noteSubmittedTiling(_ data: Data, packet: MediaPacket) {
        let tiling = VideoSubmissionIntegrity.tiling(
            of: data,
            nalLengthSize: nalUnitHeaderLength
        )
        integrity.note(tiling: tiling)
        if tiling.isMalformed, loggedMalformedSamples < 8 {
            loggedMalformedSamples += 1
            PlayerLog.log(
                "[PathADecoder] event=malformedSample sessionID=\(queueSessionID) " +
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

    struct UncheckedQueueResult<Value>: @unchecked Sendable {
        let value: Value
    }

    func decode(_ packet: MediaPacket) async throws -> [MediaVideoFrame] {
        try await onDecodeQueue {
            UncheckedQueueResult(value: try self.decodeOnQueue(packet))
        }.value
    }

    private func decodeOnQueue(_ packet: MediaPacket) throws -> [MediaVideoFrame] {
        var trace = decodeTiming.observationID().map(VideoToolboxDecodeTimingTrace.init)
        defer {
            if let measurement = trace?.finish() {
                decodeTiming.record(measurement)
            }
        }
        trace?.advance(to: .integrity)
        trace?.value.decoderSessionID = queueSessionID
        guard opened else {
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

        guard let prepared = try prepareSessionForPacketOnQueue(packet.data) else {
            trace?.value.failures = 0
            return []
        }

        trace?.advance(to: .sampleConstruction)
        let dataCopy = packet.data
        let timingSubmission = VideoToolboxTimingSubmission(
            submissionID: UInt64(decodeCallCount),
            decoderGeneration: queueSessionID,
            inputPTS: packet.pts,
            inputDTS: packet.dts,
            inputDuration: packet.duration,
            inputOrder: inputOrder
        )
        let (sample, timing) = try makeSampleBuffer(
            data: dataCopy,
            packet: packet,
            formatDescription: prepared.formatDescription,
            timingSubmission: timingSubmission
        )

        let router = outputRouter
        router.register(
            submission: timingSubmission,
            packet: packet,
            nativeTiming: timing,
            measurementStarted: trace?.started
        )
        let identity = timingSubmission.identity
        var infoFlags = VTDecodeInfoFlags()
        trace?.advance(to: .nativeCall)
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            prepared.session,
            sampleBuffer: sample,
            flags: [],
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

        trace?.advance(to: .postprocess)
        let newlyReady = router.drainReady(forGeneration: queueSessionID)
        let drainedEntries = prepared.drainedEntries.isEmpty
            ? newlyReady
            : (prepared.drainedEntries + newlyReady)
        let currentEntry = drainedEntries.first { $0.submission.identity == identity }
        trace?.value.firstImageCallOffset = currentEntry?.firstImageOffset

        if let fault = Self.runtimeFault(for: decodeStatus, stage: .decodeSubmission) {
            noteDecodeAnomalies(
                submissionStatus: decodeStatus,
                events: currentEntry?.records.map(\.event) ?? [],
                truncated: false
            )
            logFaultIfNeeded(fault, status: decodeStatus)
            throw fault
        }
        if currentEntry == nil {
            noteDecodeAnomalies(submissionStatus: decodeStatus, events: [], truncated: false)
        }

        let frames = try resolveRouterEntriesOnQueue(drainedEntries, currentSubmissionStatus: decodeStatus)
        trace?.value.outputFrames = frames.count
        trace?.value.failures = 0
        return frames
    }

    private func resolveRouterEntriesOnQueue(
        _ entries: [VideoToolboxOutputRouter.Entry],
        currentSubmissionStatus: OSStatus
    ) throws -> [MediaVideoFrame] {
        let timingPolicy = VideoToolboxTimingPolicy()
        var frames: [MediaVideoFrame] = []
        for entry in entries {
            let events = entry.records.map(\.event)
            noteDecodeAnomalies(
                submissionStatus: currentSubmissionStatus,
                events: events,
                truncated: entry.truncated
            )
            if entry.collector.firstFailureStatus == kVTVideoDecoderReferenceMissingErr,
               loggedReferenceMissingBatches < 4 {
                loggedReferenceMissingBatches += 1
                PlayerLog.log(
                    "[PathADecoder] event=referenceMissing sessionID=\(queueSessionID) " +
                    "pts=\(Self.mediaTimeDescription(entry.packet.pts)) " +
                    "keyframe=\(entry.packet.isKeyframe ? 1 : 0) — frame dropped, decoding continues"
                )
            }
            var callbackFaultStatus: OSStatus = noErr
            for record in entry.records {
                let status = OSStatus(record.event.status)
                if Self.classification(for: status) != nil {
                    callbackFaultStatus = status
                    break
                }
            }
            if let fault = Self.runtimeFault(for: callbackFaultStatus, stage: .decodeCallback) {
                logFaultIfNeeded(fault, status: callbackFaultStatus)
                throw fault
            }
            if !didLogFirstDecode {
                didLogFirstDecode = true
                let imageCount = entry.records.reduce(into: 0) { count, record in
                    if record.imageBuffer != nil { count += 1 }
                }
                PlayerLog.log(
                    "[PathADecoder] event=firstDecode sessionID=\(queueSessionID) " +
                    "decodeCount=\(decodeCallCount) frames=\(imageCount)"
                )
            }
            if !didLogFirstPixelLayout, let firstPixelBuffer = entry.records.compactMap(\.imageBuffer).first {
                didLogFirstPixelLayout = true
                let layout = VideoPixelBufferDiagnostics.snapshot(firstPixelBuffer)
                PlayerLog.log(
                    "[PathADecoder] pixelLayout sessionID=\(queueSessionID) " +
                    layout.logDescription
                )
            }
            let timingResolution = timingPolicy.resolve(
                submission: entry.submission,
                outputEvents: events
            )
            if case .outputs = timingResolution.outcome {
                for record in entry.records {
                    guard let pixelBuffer = record.imageBuffer,
                          let resolvedOutput = timingResolution.resolution(for: record.event) else {
                        continue
                    }
                    switch resolvedOutput {
                    case .callback(let pts, let duration),
                         .oneToOneInputFallback(let pts, let duration, _):
                        frames.append(
                            MediaVideoFrame(
                                pts: pts,
                                duration: duration,
                                pixelBuffer: pixelBuffer
                            )
                        )
                        framesProduced += 1
                    case .unknown:
                        continue
                    }
                }
            }
        }
        return frames
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
        let timescale: CMTimeScale = 60_000
        let maxRepresentableSeconds = Double(Int64.max - 1) / Double(timescale)
        guard abs(value) <= maxRepresentableSeconds else { return .invalid }
        let converted = CMTime(seconds: value, preferredTimescale: timescale)
        guard CMTIME_IS_VALID(converted), CMTIME_IS_NUMERIC(converted),
              converted.isValid, converted.isNumeric else {
            return .invalid
        }
        let roundTripped = CMTimeGetSeconds(converted)
        guard roundTripped.isFinite,
              value == 0 || (roundTripped != 0 && value.sign == roundTripped.sign) else {
            return .invalid
        }
        return converted
    }

    func flush() async {
        await onDecodeQueue {
            self.integrity.noteFlush()
            if let session = self.session {
                self.flushCount &+= 1
                if self.flushCount <= 4 {
                    PlayerLog.log(
                        "[PathADecoder] event=flush sessionID=\(self.queueSessionID) " +
                        "count=\(self.flushCount)"
                    )
                }
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
            self.outputRouter.clear()
        }
    }

    func close() async {
        await onDecodeQueue {
            self.closeOnQueue()
        }
    }

    private func closeOnQueue() {
        outputRouter.clear()
        if let session {
            invalidateCount &+= 1
            if invalidateCount <= 2 {
                PlayerLog.log(
                    "[PathADecoder] event=invalidate sessionID=\(queueSessionID) " +
                    "count=\(invalidateCount)"
                )
            }
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        opened = false
        pendingInBandCodec = nil
        currentParameterSets = []
        setSessionID(0)
    }
}
