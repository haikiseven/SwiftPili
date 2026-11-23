import CoreMedia
import CoreVideo
import Foundation

// MARK: - Shared value types (engine-local; not app policy)

enum MediaTrackKind: String, Sendable {
    case video
    case audio
}

struct MediaVideoCodedDimensions: Sendable {
    let width: Int32
    let height: Int32

    init?(width: Int, height: Int) {
        guard width > 0, height > 0,
              let width = Int32(exactly: width), let height = Int32(exactly: height) else {
            return nil
        }
        self.width = width
        self.height = height
    }
}

struct MediaVideoTrackConfiguration: Sendable {
    let codec: String
    let config: Data
    let codedDimensions: MediaVideoCodedDimensions?
}

struct MediaAudioPacketTiming: Sendable, Equatable {
    let ptsTicks: Int64
    let dtsTicks: Int64
    let durationTicks: UInt32
    let trackTimescale: UInt32
    let effectiveTimescale: Double
}

struct MediaAudioDecodeTiming: Sendable, Equatable {
    let packet: MediaAudioPacketTiming
    let decodedInputFrames: Int
    let resampledOutputFrames: Int
    let decoderInputSampleRate: Double
    let decoderOutputSampleRate: Double
}

struct MediaPacket: @unchecked Sendable {
    var track: MediaTrackKind
    var pts: TimeInterval
    var dts: TimeInterval?
    var duration: TimeInterval
    var data: Data
    var isKeyframe: Bool
    var pixelBuffer: CVPixelBuffer? = nil
    var pcmSampleRate: Double? = nil
    var pcmChannelCount: Int? = nil
    var audioTiming: MediaAudioPacketTiming? = nil
    var emittedAt: ContinuousClock.Instant? = nil
    var sourcePrimaryObservation: MediaSourcePrimaryObservation?
    var containerSampleIndex: Int? = nil
    var containerFragmentSequence: UInt32? = nil
    var containerSampleOffset: Int? = nil
}

struct MediaVideoFrame {
    var pts: TimeInterval
    var duration: TimeInterval
    var pixelBuffer: CVPixelBuffer
}

struct MediaAudioFrame: Sendable {
    var pts: TimeInterval
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var pcm: Data
    var decodeTiming: MediaAudioDecodeTiming? = nil
}

enum DemandLiveSourceKind: String, Sendable {
    case hlsFMP4
    case progressiveFMP4
    case hlsMPEGTS
    case httpFLV
}

struct DemandLiveSource: Sendable {
    let kind: DemandLiveSourceKind
    let ownerLease: PlayerOwnerLease?
    let hlsTSBackupPlaylistURL: URL?
}

struct MediaOpenRequest: Sendable {
    var videoURL: URL
    var audioURL: URL?
    var headers: [String: String]
    var startPosition: TimeInterval
    var preferredRate: Float
    var packetQueueHighWater: TimeInterval
    var preferHardwareVideo: Bool
    var ownerGeneration: UInt64 = 0
    var startupTraceToken: MediaEngineTraceID? = nil
    let liveSource: DemandLiveSource?
    var alternateVideoURLs: [URL] = []
    var alternateAudioURLs: [URL] = []
    var readAheadSeconds: TimeInterval?
    var multiConnectionPolicy: MultiConnectionPolicy?
    var multiConnectionQuietGate: MultiConnectionQuietGate?
    var networkByteCounter: MediaNetworkByteCounter?
    var videoBootstrapIdentity: MediaBootstrapIdentity?
    var audioBootstrapIdentity: MediaBootstrapIdentity?
}

enum MediaRuntimeFaultSubsystem: String, Sendable, Equatable, Hashable {
    case videoDecoder
    case audioDecoder
    case demux
    case videoRenderer
    case audioRenderer
}

enum MediaRuntimeFaultStage: String, Sendable, Equatable, Hashable {
    case open
    case decodeSubmission
    case decodeCallback
    case liveness
    case pump
    case render
    case seekPriming
}

enum MediaRuntimeFaultClassification: String, Sendable, Equatable, Hashable {
    case invalidSession
    case malfunction
    case badData
    case unsupportedFormat
    case input
    case silentNoOutput
    case unknown
}

enum MediaRuntimeFaultRecoverability: String, Sendable, Equatable, Hashable {
    case automaticSourceAwareReopen
    case manualRetry

    var isAutomatic: Bool {
        self == .automaticSourceAwareReopen
    }
}

struct MediaRuntimeFaultDiagnostics: Sendable, Equatable, Hashable {
    let status: Int32?
    let label: String
    let details: String

    init(status: Int32? = nil, label: String, details: String = "") {
        self.status = status
        let safe = label.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        self.label = String((safe.isEmpty ? "fault" : safe).prefix(32))
        let safeDetails = details.filter {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ||
                $0 == "=" || $0 == "." || $0 == "," || $0 == ":" || $0 == " "
        }
        self.details = String(safeDetails.prefix(192))
    }

    var summary: String {
        let statusSummary = status.map(String.init) ?? "none"
        let detailSummary = details.isEmpty ? "" : " details=\(details)"
        return "status=\(statusSummary) label=\(label)\(detailSummary)"
    }
}

struct MediaRuntimeFault: Error, Sendable, Equatable, Hashable, LocalizedError {
    let subsystem: MediaRuntimeFaultSubsystem
    let stage: MediaRuntimeFaultStage
    let classification: MediaRuntimeFaultClassification
    let recoverability: MediaRuntimeFaultRecoverability
    let sessionGeneration: UInt64
    let ownerGeneration: UInt64
    let ownerLeaseGeneration: UInt64
    let diagnostics: MediaRuntimeFaultDiagnostics

    init(
        subsystem: MediaRuntimeFaultSubsystem,
        stage: MediaRuntimeFaultStage,
        classification: MediaRuntimeFaultClassification,
        recoverability: MediaRuntimeFaultRecoverability,
        sessionGeneration: UInt64 = 0,
        ownerGeneration: UInt64 = 0,
        ownerLeaseGeneration: UInt64 = 0,
        diagnostics: MediaRuntimeFaultDiagnostics
    ) {
        self.subsystem = subsystem
        self.stage = stage
        self.classification = classification
        self.recoverability = recoverability
        self.sessionGeneration = sessionGeneration
        self.ownerGeneration = ownerGeneration
        self.ownerLeaseGeneration = ownerLeaseGeneration
        self.diagnostics = diagnostics
    }

    var isRecoveryWorthy: Bool {
        recoverability.isAutomatic
    }

    func stamped(sessionGeneration: UInt64, ownerGeneration: UInt64) -> Self {
        Self(
            subsystem: subsystem,
            stage: stage,
            classification: classification,
            recoverability: recoverability,
            sessionGeneration: sessionGeneration,
            ownerGeneration: ownerGeneration,
            ownerLeaseGeneration: ownerLeaseGeneration,
            diagnostics: diagnostics
        )
    }

    var errorDescription: String? {
        "MediaEngine runtime fault: \(subsystem.rawValue)/\(stage.rawValue) " +
            "class=\(classification.rawValue) recovery=\(recoverability.rawValue) " +
            "session=\(sessionGeneration) owner=\(ownerGeneration) \(diagnostics.summary)"
    }
}

extension SeekPrimingFailure {
    var faultClassification: MediaRuntimeFaultClassification {
        switch self {
        case .endOfStreamBeforeTarget, .inputStarved:
            return .input
        case .pipelineStalled, .prerollBudgetExhausted:
            return .silentNoOutput
        }
    }

    var faultRecoverability: MediaRuntimeFaultRecoverability {
        .automaticSourceAwareReopen
    }

    func faultSubsystem(shortTrackIsAudio: Bool) -> MediaRuntimeFaultSubsystem {
        switch self {
        case .endOfStreamBeforeTarget, .inputStarved:
            return .demux
        case .pipelineStalled, .prerollBudgetExhausted:
            return shortTrackIsAudio ? .audioDecoder : .videoDecoder
        }
    }
}

enum MediaDemuxFailureKind: Sendable, Equatable {
    case liveMapChangedReloadRequired
    case stickyFMP4InputRejection
    case terminalLiveInputRejection
}

enum MediaEngineError: Error, Sendable, LocalizedError {
    static let liveMapChangedReloadRequiredDiagnostic =
        "HLS map changed; live reload required"

    case notImplemented(String)
    case unsupportedLiveSource(DemandLiveSource, ownerGeneration: UInt64, diagnostic: String)
    case demuxFailed(String)
    case transportFailed(StreamTransportFailure)
    case fMP4InputRejected(String)
    case liveInputRejected(String)
    case decodeFailed(String)
    case renderFailed(String)
    case stopped

    var demuxFailureKind: MediaDemuxFailureKind? {
        if case .fMP4InputRejected = self { return .stickyFMP4InputRejection }
        if case .liveInputRejected = self { return .terminalLiveInputRejection }
        guard case .demuxFailed(let diagnostic) = self else { return nil }
        guard diagnostic == Self.liveMapChangedReloadRequiredDiagnostic else {
            return nil
        }
        return .liveMapChangedReloadRequired
    }

    var isHostIndependent: Bool {
        switch self {
        case .decodeFailed, .renderFailed, .notImplemented, .unsupportedLiveSource:
            return true
        case .demuxFailed, .transportFailed, .fMP4InputRejected, .liveInputRejected, .stopped:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notImplemented(let s): return "MediaEngine: not implemented — \(s)"
        case .unsupportedLiveSource(let source, _, let diagnostic):
            return "MediaEngine unsupported live source kind=\(source.kind.rawValue): \(diagnostic)"
        case .transportFailed(let failure): return failure.localizedDescription
        case .demuxFailed(let s): return "MediaEngine demux: \(s)"
        case .fMP4InputRejected(let s): return "MediaEngine fMP4 input rejected: \(s)"
        case .liveInputRejected(let s): return "MediaEngine live input rejected: \(s)"
        case .decodeFailed(let s): return "MediaEngine decode: \(s)"
        case .renderFailed(let s): return "MediaEngine render: \(s)"
        case .stopped: return "MediaEngine: stopped"
        }
    }
}

// MARK: - Demux

enum MediaVideoContinuityTopology: String, Equatable, Sendable {
    case splitTrack
    case muxedCurrentGOP
    case localFileIndex
    case unsupported
}

enum MediaVideoContinuityUnsupportedReason: String, Equatable, Sendable {
    case topology
    case unavailable
}

enum MediaDemuxIOInterruptResult: String, Equatable, Sendable {
    case interrupted
    case noActiveOperation
    case unsupported
}

struct MediaVideoContinuityContentInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    init?(start: TimeInterval, end: TimeInterval) {
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        self.start = start
        self.end = end
    }
}

struct MediaVideoForwardRequest: Sendable {
    let target: TimeInterval
    let playbackRate: Double
    let wallAllowance: Duration
    let maximumCompressedBytes: Int
    let maximumContentSpan: TimeInterval
}

struct MediaVideoForwardReceipt: Equatable, Sendable {
    let id: UUID
    let readerMutationGeneration: UInt64
    let anchorPTS: TimeInterval
    let referenceStart: Int
    let referenceEnd: Int
    let contentInterval: MediaVideoContinuityContentInterval
    let sampledTarget: TimeInterval
    let maximumLead: TimeInterval
    let playbackRate: Double
    let selectionFetchBytes: Int
}

enum MediaVideoForwardOutcome: Sendable {
    case notSelected
    case positioned(MediaVideoForwardReceipt)
}

struct MediaVideoContinuityBatch: @unchecked Sendable {
    let readerMutationGeneration: UInt64
    let readGeneration: UInt64
    let packets: [MediaPacket]
    let compressedByteCount: Int
    let contentInterval: MediaVideoContinuityContentInterval?
    let contentFrontier: TimeInterval?
    let reachedEOF: Bool
    let madeProgress: Bool
    var forwardReceipt: MediaVideoForwardReceipt?
    var fetchedByteCount: Int = 0
    var forwardReferenceExhausted: Bool = false
}

enum MediaVideoContinuityBatchOutcome: @unchecked Sendable {
    case supported(MediaVideoContinuityBatch)
    case unsupported(MediaVideoContinuityUnsupportedReason)
}

struct MediaVideoContinuityCandidateAuthority: Equatable, Sendable {
    let generation: UInt64
    let anchorPTS: TimeInterval
    let firstDTS: TimeInterval?
    let endPTS: TimeInterval
    let packetCount: Int
    let byteCount: Int
    let startsWithSyncSample: Bool

    var decodeAnchorTime: TimeInterval {
        firstDTS ?? anchorPTS
    }
}

struct MediaBufferDisplaySample: Sendable {
    let position: TimeInterval
    let videoPresent: Bool
    let audioPresent: Bool
    let videoWarmSuspended: Bool
    let videoEnd: TimeInterval?
    let audioEnd: TimeInterval?
    let bufferedThrough: TimeInterval?
}

protocol MediaDemuxing: AnyObject, Sendable {
    func open(_ request: MediaOpenRequest) async throws
    var duration: TimeInterval { get async }
    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket]
    func pump(videoBudget: TimeInterval, audioBudget: TimeInterval) async throws -> [MediaPacket]
    func pump(
        videoBudget: TimeInterval, audioBudget: TimeInterval,
        sourceWaitBudget: MediaSourceWaitBudget?
    ) async throws -> [MediaPacket]
    var isEOF: Bool { get async }
    var providesAudioTrack: Bool { get async }
    var videoContinuityTopology: MediaVideoContinuityTopology { get async }
    func prepareVideoContinuity(at mediaTime: TimeInterval) async throws -> Bool
    func prepareForwardVideoContinuity(
        _ request: MediaVideoForwardRequest
    ) async throws -> MediaVideoForwardOutcome
    func prepareEarlierVideoContinuity(
        before excludedAnchorPTS: TimeInterval
    ) async throws -> Bool
    func pumpPositionedVideoContinuity(
        readGeneration: UInt64,
        contentBudget: TimeInterval
    ) async throws -> MediaVideoContinuityBatchOutcome
    func seek(to mediaTime: TimeInterval) async throws
    func close() async

    func setPacketRelay(_ relay: DemuxPacketRelay?) async

    func codec(for kind: MediaTrackKind) async -> String?

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration?

    func formatConfig(for kind: MediaTrackKind) async -> Data

    func retireLiveStreams() async

    func interruptActiveIO() async -> MediaDemuxIOInterruptResult

    func cachedContentAhead() async -> MediaCachedContentAhead

    func multiConnectionTelemetry() async -> MultiConnectionTelemetry
    func setMultiConnectionQuiet(_ quiet: Bool) async
    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async
    func cancelMultiConnectionPrefetching() async

    var measuresCachedContentAhead: Bool { get }
}

extension MediaDemuxing {
    func multiConnectionTelemetry() async -> MultiConnectionTelemetry { .unsupported }
    var providesAudioTrack: Bool { false }
    var videoContinuityTopology: MediaVideoContinuityTopology { .unsupported }
    func prepareVideoContinuity(at _: TimeInterval) async throws -> Bool { false }
    func prepareEarlierVideoContinuity(before _: TimeInterval) async throws -> Bool { false }
    func prepareForwardVideoContinuity(
        _: MediaVideoForwardRequest
    ) async throws -> MediaVideoForwardOutcome { .notSelected }
    func pumpPositionedVideoContinuity(
        readGeneration: UInt64,
        contentBudget: TimeInterval
    ) async throws -> MediaVideoContinuityBatchOutcome {
        _ = readGeneration
        _ = contentBudget
        return .unsupported(.topology)
    }

    func retireLiveStreams() async {}

    func interruptActiveIO() async -> MediaDemuxIOInterruptResult {
        .unsupported
    }

    func pump(videoBudget: TimeInterval, audioBudget: TimeInterval) async throws -> [MediaPacket] {
        try await pump(contentBudget: max(videoBudget, audioBudget))
    }

    func pump(
        videoBudget: TimeInterval, audioBudget: TimeInterval,
        sourceWaitBudget: MediaSourceWaitBudget?
    ) async throws -> [MediaPacket] {
        try await pump(videoBudget: videoBudget, audioBudget: audioBudget)
    }

    func setPacketRelay(_ relay: DemuxPacketRelay?) async {
        _ = relay
    }

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration? { nil }

    func codec(for kind: MediaTrackKind) async -> String? {
        _ = kind
        return nil
    }

    func formatConfig(for kind: MediaTrackKind) async -> Data {
        _ = kind
        return Data()
    }
}

// MARK: - Decode

enum MediaVideoFormat: @unchecked Sendable {
    case description(CMFormatDescription)
    case codecConfig(codec: String?, config: Data, codedDimensions: MediaVideoCodedDimensions? = nil)
}

protocol MediaVideoDecoding: AnyObject, Sendable {
    var debugSessionID: UInt64 { get }

    func open(formatHint: Data?) async throws

    func open(format: MediaVideoFormat) async throws
    func decode(_ packet: MediaPacket) async throws -> [MediaVideoFrame]
    func decodePrerollBatch(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) async throws -> VideoPrerollBatchResult
    var decodeAnomalyCounters: VideoDecodeAnomalyCounters { get }
    func flush() async
    func close() async
}

struct VideoPrerollSubmission: @unchecked Sendable {
    var packet: MediaPacket
    var action: VideoPrerollSampleAction
}

struct VideoPrerollBatchResult {
    var keptFrames: [MediaVideoFrame] = []
    var outputPTS: [TimeInterval] = []
    var discardedFrames = 0
    var submitted = 0
    var skipped = 0
    var truncated = 0
    var truncatedBytes = 0

    mutating func noteOutput(_ frame: MediaVideoFrame, keep: Bool) {
        outputPTS.append(frame.pts)
        if keep {
            keptFrames.append(frame)
        } else {
            discardedFrames += 1
        }
    }
}

extension MediaVideoDecoding {
    var debugSessionID: UInt64 { 0 }

    var decodeAnomalyCounters: VideoDecodeAnomalyCounters { VideoDecodeAnomalyCounters() }

    func decodePrerollBatch(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) async throws -> VideoPrerollBatchResult {
        try await sequentialPrerollBatch(batch, keepOutput: keepOutput)
    }

    func sequentialPrerollBatch(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) async throws -> VideoPrerollBatchResult {
        var result = VideoPrerollBatchResult()
        for item in batch {
            var packet = item.packet
            switch item.action {
            case .skip:
                result.skipped += 1
                continue
            case .truncate(let byteCount):
                if byteCount > 0, byteCount < packet.data.count {
                    result.truncatedBytes += packet.data.count - byteCount
                    packet.data = Data(packet.data.prefix(byteCount))
                }
                result.truncated += 1
            case .submit:
                break
            }
            result.submitted += 1
            for frame in try await decode(packet) {
                result.noteOutput(frame, keep: keepOutput(frame.pts, frame.duration))
            }
        }
        return result
    }

    func open(format: MediaVideoFormat) async throws {
        switch format {
        case .description:
            throw MediaEngineError.notImplemented(
                "\(type(of: self)) cannot open from a CMFormatDescription"
            )
        case .codecConfig(_, let config, _):
            try await open(formatHint: config.isEmpty ? nil : config)
        }
    }
}

protocol MediaAudioDecoding: AnyObject, Sendable {
    func open(formatHint: Data?) async throws
    func open(codec: String?, formatHint: Data?) async throws
    func decode(_ packet: MediaPacket) async throws -> [MediaAudioFrame]
    func decodeDiagnostics() async -> MediaAudioDecodeDiagnostics
    func flush() async
    func close() async
}

enum MediaAudioDecodeStatus: String, Sendable, Equatable {
    case unavailable
    case idle
    case producedPCM
    case inputConsumedNoPCM
    case waitingForInput
    case drained
    case converterError
}

struct MediaAudioDecodeDiagnostics: Sendable, Equatable {
    let status: MediaAudioDecodeStatus
    let converterStatus: Int32?
    let inputPacketConsumed: Bool
    let outputFrames: Int
    let inputCallbackRequests: Int
    let inputCallbackAskedForMore: Bool
    let pendingAccessUnits: Int
    let noPCMReturns: Int

    static let unavailable = MediaAudioDecodeDiagnostics(
        status: .unavailable,
        converterStatus: nil,
        inputPacketConsumed: false,
        outputFrames: 0,
        inputCallbackRequests: 0,
        inputCallbackAskedForMore: false,
        pendingAccessUnits: 0,
        noPCMReturns: 0
    )
}

extension MediaAudioDecoding {
    func open(codec: String?, formatHint: Data?) async throws {
        _ = codec
        try await open(formatHint: formatHint)
    }

    func decodeDiagnostics() async -> MediaAudioDecodeDiagnostics {
        .unavailable
    }
}

// MARK: - Render

@MainActor
protocol MediaVideoRendering: AnyObject {
    var demandLivenessRenderer: DemandLivenessRenderer { get }
    func setScaleMode(_ mode: VideoScaleMode)
    func present(_ frame: MediaVideoFrame) throws
    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval)
    func enqueuedAheadSeconds(from mediaTime: TimeInterval) -> TimeInterval
    func flush()
    func invalidate()
}

extension MediaVideoRendering {
    var demandLivenessRenderer: DemandLivenessRenderer { .ready }

    func enqueuedAheadSeconds(from mediaTime: TimeInterval) -> TimeInterval {
        _ = mediaTime
        return 0
    }

    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval) {
        _ = rate
        _ = mediaTime
    }
}

enum MediaAudioOutputAvailability: Sendable, Equatable {
    case stopped
    case fillOnly
    case pending
    case available
    case unavailable
}

@MainActor
protocol MediaAudioRendering: AnyObject {
    var equalizerConfiguration: PlayerEqualizerConfiguration { get set }
    var equalizerStatus: PlayerEqualizerStatus { get }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? { get set }
    func awaitAudioMaintenanceSettlement() async
    func revokeAudioMaintenancePermission()
    var isRunning: Bool { get }
    var outputAvailability: MediaAudioOutputAvailability { get }
    var hasPendingOutput: Bool { get }
    func setOutputStateChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?)
    func reconcileOutputForAuthorizedPlayback() throws
    var playbackRate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var launchReserveContentSeconds: TimeInterval { get }
    var seekTransitionReserveContentSeconds: TimeInterval { get }
    var ringBufferedSeconds: TimeInterval { get }
    var presentationTiming: MediaAudioPresentationTiming { get }
    var contentTimePresentationOffset: TimeInterval { get }
    func start(source: AudioPullSource) throws
    func pause()
    func stop()

    func prewarmHardwareGraph()

    func beginSeekTransition(source: AudioPullSource) -> MediaAudioSeekToken
    func prepareSeekTransition(
        _ token: MediaAudioSeekToken,
        source: AudioPullSource
    ) -> MediaAudioSeekPreparation
    func commitSeekTransition(_ token: MediaAudioSeekToken) async -> Bool
    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool
    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool
    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        resumesPlayback: Bool,
        resumeAdmission: @escaping @MainActor () -> AudioMaintenancePermit?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool
    func abortSeekTransition(_ token: MediaAudioSeekToken)

    func flush()

    var reportsRenderedContent: Bool { get }
}

struct MediaAudioSeekToken: Hashable, Sendable {
    let generation: UInt64
}

struct MediaAudioSeekPreparation: Sendable, Equatable {
    let token: MediaAudioSeekToken
    let stagedContentSeconds: TimeInterval
    let isReady: Bool
}

extension MediaAudioRendering {
    var equalizerConfiguration: PlayerEqualizerConfiguration {
        get { .defaults }
        set { _ = newValue }
    }
    var equalizerStatus: PlayerEqualizerStatus { .unsupported("No native EQ output") }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? {
        get { nil }
        set { _ = newValue }
    }
    func awaitAudioMaintenanceSettlement() async {}
    func revokeAudioMaintenancePermission() {}

    var outputAvailability: MediaAudioOutputAvailability { isRunning ? .available : .stopped }
    func setOutputStateChangeHandler(_: (@MainActor @Sendable () -> Void)?) {}
    func reconcileOutputForAuthorizedPlayback() throws {}

    var reportsRenderedContent: Bool { true }
    var presentationTiming: MediaAudioPresentationTiming { .logical }
    var contentTimePresentationOffset: TimeInterval { presentationTiming.contentTimeOffset }
    var launchReserveContentSeconds: TimeInterval { 0 }
    var seekTransitionReserveContentSeconds: TimeInterval {
        launchReserveContentSeconds
    }
    var ringBufferedSeconds: TimeInterval { 0 }

    func prewarmHardwareGraph() {}

    func pause() {
        stop()
    }

    func beginSeekTransition(source: AudioPullSource) -> MediaAudioSeekToken {
        _ = source
        return MediaAudioSeekToken(generation: 0)
    }

    func prepareSeekTransition(
        _ token: MediaAudioSeekToken,
        source: AudioPullSource
    ) -> MediaAudioSeekPreparation {
        _ = source
        return MediaAudioSeekPreparation(
            token: token,
            stagedContentSeconds: 0,
            isReady: true
        )
    }

    func commitSeekTransition(_ token: MediaAudioSeekToken) async -> Bool {
        _ = token
        return true
    }

    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool {
        guard isAuthorized?() ?? true else { return false }
        let committed = await commitSeekTransition(token)
        guard committed else { return false }
        guard isAuthorized?() ?? true else {
            abortSeekTransition(token)
            return false
        }
        return true
    }

    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool {
        let committed = await commitSeekTransition(token, isAuthorized: isAuthorized)
        if committed {
            beforeGateRelease?()
        }
        return committed
    }

    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        resumesPlayback: Bool,
        resumeAdmission: @escaping @MainActor () -> AudioMaintenancePermit?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool {
        await commitSeekTransition(token, isAuthorized: isAuthorized, beforeGateRelease: beforeGateRelease)
    }

    func abortSeekTransition(_ token: MediaAudioSeekToken) {
        _ = token
    }
}

struct AudioPresentationTiming: Sendable, Equatable {
    static func contentTimeOffset(
        processingLatencySeconds: TimeInterval,
        appliedRate: Float,
        isActive: Bool,
        isBypassed: Bool
    ) -> TimeInterval {
        guard isActive, !isBypassed,
              processingLatencySeconds.isFinite, processingLatencySeconds > 0,
              appliedRate.isFinite, appliedRate > 0 else {
            return 0
        }
        let offset = processingLatencySeconds * TimeInterval(appliedRate)
        return offset.isFinite ? max(0, offset) : 0
    }

    static func presentationMediaTime(
        mediaTime: TimeInterval,
        contentTimeOffset: TimeInterval
    ) -> TimeInterval {
        let safeMediaTime = mediaTime.isFinite ? max(0, mediaTime) : 0
        let safeOffset = contentTimeOffset.isFinite ? max(0, contentTimeOffset) : 0
        return max(0, safeMediaTime - safeOffset)
    }
}

@MainActor
protocol AudioPullSource: AnyObject {
    func pullPCM(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioRendererPull

    func renderedContentDidAdvance(bySeconds seconds: TimeInterval)

    nonisolated var audioSupply: any AudioSupplySource { get }

    func audioSupplyDidReport(_ report: AudioFeederPullReport)
}

extension AudioPullSource {
    func renderedContentDidAdvance(bySeconds seconds: TimeInterval) {
        _ = seconds
    }

    func audioSupplyDidReport(_ report: AudioFeederPullReport) {}
}

// MARK: - Session events (backend translates → PlayerStateEvent)

enum MediaSessionEvent: Sendable {
    case ready(duration: TimeInterval)
    case buffering
    case playing
    case paused
    case ended
    case failed(MediaEngineError)
    case runtimeFault(MediaRuntimeFault)
    case tick(mediaTime: TimeInterval, duration: TimeInterval, buffered: TimeInterval)
    case buffered(TimeInterval)
}

struct MediaFrameRateSample: Sendable, Equatable {
    var decodedFPS: Double
    var presentedFPS: Double

    static func calculate(
        decodedFrames: Int,
        presentedFrames: Int,
        elapsed: TimeInterval
    ) -> MediaFrameRateSample? {
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        return MediaFrameRateSample(
            decodedFPS: Double(max(0, decodedFrames)) / elapsed,
            presentedFPS: Double(max(0, presentedFrames)) / elapsed
        )
    }
}

struct MediaEngineStats: Sendable, Equatable {
    var multiConnection = MultiConnectionTelemetry.unsupported
    var bytesRead: Int64
    var networkBytesReceived: Int64
    var videoPackets: Int
    var videoPacketsDequeued: Int
    var videoPacketsSubmitted: Int
    var videoInputContentSecondsConsumed: TimeInterval
    var audioPackets: Int
    var pendingVideoFrames: Int
    var pendingPCMSeconds: TimeInterval
    var mediaTime: TimeInterval
    var bufferedTime: TimeInterval
    var isBuffering: Bool
    var decodedVideoFrames: Int
    var presentedVideoFrames: Int
    var videoOutputPTSAdvanced: Bool
    var decodedVideoFPS: Double
    var presentedVideoFPS: Double
    var videoWidth: Int
    var videoHeight: Int
    var pulledAudioFrames: Int

    static let zero = MediaEngineStats(
        bytesRead: 0,
        networkBytesReceived: 0,
        videoPackets: 0,
        videoPacketsDequeued: 0,
        videoPacketsSubmitted: 0,
        videoInputContentSecondsConsumed: 0,
        audioPackets: 0,
        pendingVideoFrames: 0,
        pendingPCMSeconds: 0,
        mediaTime: 0,
        bufferedTime: 0,
        isBuffering: false,
        decodedVideoFrames: 0,
        presentedVideoFrames: 0,
        videoOutputPTSAdvanced: false,
        decodedVideoFPS: 0,
        presentedVideoFPS: 0,
        videoWidth: 0,
        videoHeight: 0,
        pulledAudioFrames: 0
    )
}

struct MediaEngineSeekPreparation: Sendable, Equatable {
    let token: MediaAudioSeekToken
    let target: TimeInterval
    let stagedContentSeconds: TimeInterval
    let isReady: Bool
}

@MainActor
protocol MediaEngining: AnyObject {
    var onEvent: (@MainActor @Sendable (MediaSessionEvent) -> Void)? { get set }
    var mediaTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var bufferedTime: TimeInterval { get }
    var isReady: Bool { get }
    var isPlaying: Bool { get }
    var runtimeGeneration: UInt64 { get }
    var playbackRate: Float { get set }
    var stats: MediaEngineStats { get }

    func open(_ request: MediaOpenRequest) async
    func play()
    func pause()
    func prepareSeek(to time: TimeInterval) async -> MediaEngineSeekPreparation
    func commitPreparedSeek(
        _ preparation: MediaEngineSeekPreparation,
        isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool
    func abortPreparedSeek(_ preparation: MediaEngineSeekPreparation)
    func seek(to time: TimeInterval) async -> Bool
    func stop()
    func setScaleMode(_ mode: VideoScaleMode)
}
