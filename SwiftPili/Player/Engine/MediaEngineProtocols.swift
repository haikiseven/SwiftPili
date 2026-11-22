import CoreMedia
import CoreVideo
import Foundation

// MARK: - Shared value types (engine-local; not app policy)

/// Which elementary stream a packet/frame belongs to.
enum MediaTrackKind: String, Sendable {
    case video
    case audio
}

/// Positive coded dimensions representable by Core Media. The demuxer obtains
/// these from the selected track, independently of display size and UI quality.
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

/// Decoder metadata captured together from one selected video track.
struct MediaVideoTrackConfiguration: Sendable {
    let codec: String
    let config: Data
    let codedDimensions: MediaVideoCodedDimensions?
}

/// Raw compressed-audio timing carried alongside a packet. The declared MP4
/// track scale is the playback clock and remains authoritative. The effective
/// field is retained for cross-layer diagnostics and must equal the declared
/// scale unless a future format-specific contract explicitly proves otherwise.
struct MediaAudioPacketTiming: Sendable, Equatable {
    let ptsTicks: Int64
    let dtsTicks: Int64
    let durationTicks: UInt32
    let trackTimescale: UInt32
    let effectiveTimescale: Double
}

/// Decoder-side accounting for one access unit. This stays off the real-time
/// renderer path and makes the compressed → native PCM → engine PCM boundary
/// inspectable in bounded diagnostics and deterministic tests.
struct MediaAudioDecodeTiming: Sendable, Equatable {
    let packet: MediaAudioPacketTiming
    let decodedInputFrames: Int
    let resampledOutputFrames: Int
    let decoderInputSampleRate: Double
    let decoderOutputSampleRate: Double
}

/// Access unit between demux and decoder.
///
/// Normally compressed (`data` holds the bitstream, `pixelBuffer == nil`).
/// AVAsset bring-up may also emit **already-decompressed** video by filling
/// `pixelBuffer` (and leaving `data` empty) so a pass-through decoder can
/// present without VideoToolbox format plumbing.
///
/// `@unchecked Sendable`: `CVPixelBuffer` is not Sendable; the engine keeps
/// packet queues on MainActor and does not hop pixel buffers across isolation
/// without an explicit hop at present time.
struct MediaPacket: @unchecked Sendable {
    var track: MediaTrackKind
    /// Presentation time in **media seconds** (engine timeline, not wall).
    var pts: TimeInterval
    var dts: TimeInterval?
    var duration: TimeInterval
    var data: Data
    var isKeyframe: Bool
    /// When non-nil, demux already produced a displayable frame (A1c decompress).
    var pixelBuffer: CVPixelBuffer? = nil
    /// When set with audio track, `data` is interleaved Float32 PCM at this rate.
    var pcmSampleRate: Double? = nil
    var pcmChannelCount: Int? = nil
    var audioTiming: MediaAudioPacketTiming? = nil
    /// Monotonic instant the demuxer finished assembling this packet (streamed
    /// or buffered). Diagnostics only — the session's ingest derives the
    /// pump→ingest bridge delay from it; it never drives supply, decode, or F1.
    var emittedAt: ContinuousClock.Instant? = nil
    /// Actual primary issue consumed by this new complete packet. The session
    /// samples it only after accepting the packet in the current pump.
    var sourcePrimaryObservation: MediaSourcePrimaryObservation?
    var displayCoverage: MediaDisplayLease? = nil
    /// Payload-free container provenance for decoder diagnostics.
    var containerSampleIndex: Int? = nil
    var containerFragmentSequence: UInt32? = nil
    var containerSampleOffset: Int? = nil
}

/// Decoded video frame ready for display.
/// Not `Sendable`: `CVPixelBuffer` is thread-bound; hop explicitly on MainActor
/// at the render boundary.
struct MediaVideoFrame {
    var pts: TimeInterval
    var duration: TimeInterval
    /// Owned pixel buffer; render path must retain while on screen.
    var pixelBuffer: CVPixelBuffer
    var displayCoverage: MediaDisplayLease? = nil
}

/// Decoded PCM chunk (interleaved Float32, engine-normalized).
struct MediaAudioFrame: Sendable {
    var pts: TimeInterval
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var pcm: Data
    var decodeTiming: MediaAudioDecodeTiming? = nil
}

/// Container and transport of the selected Demand live rendition.
enum DemandLiveSourceKind: String, Sendable {
    case hlsFMP4
    case progressiveFMP4
    case hlsMPEGTS
    case httpFLV
}

/// Captured with the selected rendition so an open-time refusal cannot replace
/// playback after a screen lease changes, even if the backend instance is retained.
struct DemandLiveSource: Sendable {
    let kind: DemandLiveSourceKind
    let ownerLease: PlayerOwnerLease?
    let hlsTSBackupPlaylistURL: URL?
}

/// Per-open request. Built by the backend adapter from `PlayerBackend.load`.
struct MediaOpenRequest: Sendable {
    var videoURL: URL
    var audioURL: URL?
    var headers: [String: String]
    var startPosition: TimeInterval
    var preferredRate: Float
    /// Content-second high water for packet queues (policy from app buffer knobs).
    var packetQueueHighWater: TimeInterval
    var preferHardwareVideo: Bool
    /// Backend-owned load identity. Runtime faults use this to reject a late
    /// callback after stop or replacement load.
    var ownerGeneration: UInt64 = 0
    /// Request-owned cold-start trace identity. Internal reloads carry nil;
    /// generation-fenced session work may mark only this exact screen request.
    var startupTraceToken: MediaEngineTraceID? = nil
    /// Fixed by live rendition selection. Nil preserves legacy URL-based dispatch.
    let liveSource: DemandLiveSource?
    /// Admitted helper URLs; empty means no speculative component is constructed.
    var alternateVideoURLs: [URL] = []
    var alternateAudioURLs: [URL] = []
    /// Unclamped Preload seconds, independent from the packet high-water limit.
    var readAheadSeconds: TimeInterval?
    /// Per-open prefetch policy resolved by the App from the network class.
    /// Nil constructs no prefetcher, exactly like empty helper lists.
    var multiConnectionPolicy: MultiConnectionPolicy?
    var multiConnectionQuietGate: MultiConnectionQuietGate?
    /// Per-stream wire-byte counter, installed by the session on every open
    /// (`MediaNetworkByteCounter`). Nil counts nothing.
    var networkByteCounter: MediaNetworkByteCounter?
    /// Selected resource identity is separate from canonical range-cache keys.
    /// Nil preserves the ordinary real initial-head request.
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
    /// Target-relative priming after a seek's demux positioning SUCCEEDED.
    ///
    /// This stage exists so a seek that positioned correctly, pulled bytes and
    /// then failed to bank content past the target is not reported as an MP4
    /// demux failure. It used to surface as
    /// `demuxFailed("seek target did not produce launch-ready audio/video")`,
    /// which sent every reader — logs included — looking at the parser for a
    /// fault that lives in the priming loop. See `SeekPrimingFailure`.
    case seekPriming
}

/// Keep decoder status classes separate at the engine boundary. Which of them
/// may request the retained-source reopen is `VideoToolboxDecoder.recoverability`
/// for decoder faults (every class but `unsupportedFormat`) and the producer's
/// own choice elsewhere (liveness, seek priming, demux).
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

/// Diagnostics intentionally contain only an optional native status, a bounded
/// label, and bounded safe details. Liveness has no OSStatus, so its status is
/// nil rather than a fabricated sentinel.
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

/// Typed runtime failure crossing the Demand engine/backend boundary.
/// `sessionGeneration` fences seek/open/stop work; `ownerGeneration` fences a
/// backend load after a source replacement. `ownerLeaseGeneration` fences a
/// screen-owner replacement that has not yet caused a backend reload.
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

/// How a target-priming failure crosses the engine/backend boundary.
///
/// **Every one of these is a LOCAL pipeline outcome, never a delivery fault**,
/// and the recoverability below is chosen on that basis. The priming loop only
/// reaches a verdict after the demuxer positioned successfully and (for three of
/// the four reasons) after bytes demonstrably arrived from the host, so none of
/// them is evidence about the CDN edge. That matters concretely: recovery
/// boundary 2 (`switchCDN`) owns the 3-host budget, and spending a host on a
/// local decode/priming outcome is the same mistake as spending one on a
/// VideoToolbox fault — the ladder would burn its hosts and still be positioned
/// at a target it cannot prime. A typed runtime fault is admitted by boundary
/// 1, not handed to the host swap the way an untyped `.failed` is (and
/// `MediaEngineError.isHostIndependent` keeps local `.failed`s off it too);
/// this upgrades the outcome from a dead-end Retry overlay to a bounded
/// automatic reopen.
///
/// So all four are `.automaticSourceAwareReopen`: after a failed prime the
/// session is flushed and repositioned with nothing playable, and the only local
/// action that can restore playback is a source-aware reopen AT the target —
/// exactly what recovery boundary 1 executes, out of the shared decoder-reload
/// bucket, bounded by `RecoveryBudget`. When that bucket is spent, admission
/// rejects with `.budgetExhausted` and the user gets Retry. That escalation is
/// the bound; the fault does not need to pre-empt it.
///
/// `.endOfStreamBeforeTarget` is included deliberately — and the premise it
/// rests on was INVERTED until CB-23. It used to read "seek targets are clamped
/// to duration before they reach the engine, so EOF short of the target is an
/// index/parse truth rather than 'the user asked past the end'". Clamping to
/// duration is what MANUFACTURED "past the end": this session cannot launch
/// without `requiredAudioSeekContentSeconds` of PCM banked past the target, so
/// a target at duration is unservable by construction and no reopen could ever
/// help — the bounded reopen was spent on a target arithmetic had invented.
/// Targets are now admitted against the engine's own reserve
/// (`SeekTargetAdmission` + `PlayerBackend.seekLaunchReserve`), which makes the
/// conclusion true rather than merely stated: what remains is a short or broken
/// index, and one bounded reopen is a reasonable answer to that. It is still
/// distinguishable in the log and in `diagnostics.label`.
extension SeekPrimingFailure {
    var faultClassification: MediaRuntimeFaultClassification {
        switch self {
        case .endOfStreamBeforeTarget, .inputStarved:
            // The input could not supply target-side content.
            return .input
        case .pipelineStalled, .prerollBudgetExhausted:
            // Bytes arrived and the decoders consumed them without yielding
            // anything past the target — the same shape the liveness detector
            // names, reached from the seek path.
            return .silentNoOutput
        }
    }

    var faultRecoverability: MediaRuntimeFaultRecoverability {
        .automaticSourceAwareReopen
    }

    /// Which component the evidence points at. `shortTrackIsAudio` is the
    /// gate's verdict about WHICH required track never crossed the target, so a
    /// report names the audio decoder for the 70s-fixture shape (video already
    /// target-ready, audio five seconds behind) instead of blaming video.
    func faultSubsystem(shortTrackIsAudio: Bool) -> MediaRuntimeFaultSubsystem {
        switch self {
        case .endOfStreamBeforeTarget, .inputStarved:
            return .demux
        case .pipelineStalled, .prerollBudgetExhausted:
            return shortTrackIsAudio ? .audioDecoder : .videoDecoder
        }
    }
}

/// Stable demux conditions that have a session-level recovery policy.
enum MediaDemuxFailureKind: Sendable, Equatable {
    case liveMapChangedReloadRequired
    /// The fMP4 parser rejected an otherwise current fragment. This is a
    /// content/input fault, unlike an ordinary ranged-read failure.
    case stickyFMP4InputRejection
    case terminalLiveInputRejection
}

enum MediaEngineError: Error, Sendable, LocalizedError {
    /// `PathAHLSFMP4Demuxer` currently exposes this condition through the
    /// legacy `demuxFailed(String)` payload. Keep the exact diagnostic match at
    /// the typed error boundary instead of parsing `localizedDescription`.
    /// This is the smallest compatibility seam until the producer can emit a
    /// dedicated enum case without widening this repair slice.
    static let liveMapChangedReloadRequiredDiagnostic =
        "HLS map changed; live reload required"

    case notImplemented(String)
    /// Format refusal while opening the selected libavformat live input.
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

    /// A failure no other CDN host can fix: the decoders, renderers or the
    /// engine's own capability refused, after the bytes arrived. A host swap
    /// spent on one burns the 3-host budget and blacklists a working edge.
    /// Demux and input-rejection failures stay host-dependent — a bad edge can
    /// serve a truncated or corrupt body — and so do the transport errors the
    /// open path wraps as `.demuxFailed`.
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

/// Why a demuxer cannot provide the split/indexed direct continuity stream.
/// Muxed live input has a shared segment cursor rather than a seekable video
/// reader, so it must remain on its bounded current-GOP path. Keeping this
/// outcome typed prevents the session from silently treating an unsupported
/// topology as an empty successful batch.
enum MediaVideoContinuityUnsupportedReason: String, Equatable, Sendable {
    case topology
    case unavailable
}

/// Result of an explicit request to interrupt a demuxer's currently-owned
/// blocking I/O. `unsupported` is deliberately the default: a conformer must
/// positively implement the seam before the session may claim that a pending
/// read was interrupted. `noActiveOperation` is not an acknowledgement; it
/// means there was no live operation at the instant the request was observed.
enum MediaDemuxIOInterruptResult: String, Equatable, Sendable {
    case interrupted
    case noActiveOperation
    case unsupported
}

/// One acknowledged batch from the direct positioned-video continuity path.
///
/// The reader mutation generation is owned by the demuxer and remains stable
/// across the batches of one positioned transaction. `readGeneration` is the
/// session-owned scoped read identity supplied by the caller. Packets in this
/// value are delivered directly to the session; an implementation must not
/// also publish them through the ordinary packet relay.
struct MediaVideoContinuityContentInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    init?(start: TimeInterval, end: TimeInterval) {
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        self.start = start
        self.end = end
    }
}

/// An opt-in forecast admission for video-only forward positioning. Unknown
/// delivery evidence retains the ordinary before-target path.
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
    /// Bytes consumed by this direct batch, including partial active-fragment
    /// bytes. The session uses this measured value for the continuity ceiling;
    /// it is not inferred from a pump call count or a packet count.
    let compressedByteCount: Int
    let contentInterval: MediaVideoContinuityContentInterval?
    /// Highest finite content frontier proven by complete packets in this
    /// batch. It is nil when an active fragment advanced without completing a
    /// sample yet; `madeProgress` and `compressedByteCount` still account for
    /// that byte progress.
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

/// Session-observed authority for one bounded compressed-video dependency
/// sequence. The generation makes each observation fenceable; the remaining
/// fields are payload-free facts used to prove that a repair starts at a sync
/// sample and materially precedes the rejected sequence.
struct MediaVideoContinuityCandidateAuthority: Equatable, Sendable {
    let generation: UInt64
    let anchorPTS: TimeInterval
    let firstDTS: TimeInterval?
    let endPTS: TimeInterval
    let packetCount: Int
    let byteCount: Int
    let startsWithSyncSample: Bool

    /// Decode-order anchor for random-access comparisons. PTS may lead DTS on
    /// reordered video, so PTS alone can falsely classify a valid preceding
    /// sync sample as target-side.
    var decodeAnchorTime: TimeInterval {
        firstDTS ?? anchorPTS
    }
}

/// Qualified per-track connected endpoints from one evidence-book read.
struct MediaDisplayEndpoints: Sendable {
    let video: TimeInterval?
    let audio: TimeInterval?
    let audioJoin: MediaAudioDisplayJoin?

    init(video: TimeInterval?, audio: TimeInterval?, audioJoin: MediaAudioDisplayJoin? = nil) {
        self.video = video
        self.audio = audio
        self.audioJoin = audioJoin
    }
}

/// Value-only diagnostic from the same query that produced the audio endpoint.
struct MediaAudioDisplayJoin: Sendable {
    enum Result: String, Sendable {
        case appendWouldDiscontinue
        case successorUnavailable
        case joined
    }

    let pcmEnd: MediaDisplayTime
    let sourceEnd: MediaDisplayTime?
    let appendEnd: TimeInterval?
    let result: Result
}

/// One display read: qualified proof and the endpoints actually used by UI.
/// Nil evidence means no query provider; a nil endpoint inside evidence means
/// that provider did not prove connected coverage for that track.
struct MediaBufferDisplaySample: Sendable {
    let position: TimeInterval
    let videoPresent: Bool
    let audioPresent: Bool
    let videoWarmSuspended: Bool
    let evidence: MediaDisplayEndpoints?
    let resolved: MediaDisplayEndpoints
    let bufferedThrough: TimeInterval?
}

/// Exact representation of an accepted audio-owned content position. The book
/// must still match its audio track before using it for display connectivity.
struct MediaAudioDisplayPosition: Sendable {
    let track: UUID
    let time: MediaDisplayTime
}

/// Synchronous, lock-protected view of a demuxer's display-evidence book.
/// Reading it never awaits, never calls a producer and never extends ownership.
protocol MediaDisplayEvidenceQuerying: Sendable {
    /// Both tracks share one current snapshot. A nil endpoint means no live
    /// owner proves media past `seconds`, not that the source lacks that track.
    func qualifiedEndpoints(
        at seconds: Double, audioPosition: MediaAudioDisplayPosition?
    ) -> MediaDisplayEndpoints
}

/// Pulls compressed packets. Implementations may use FFmpeg libavformat;
/// callers never import FFmpeg. Session owns content-second queues and stores
/// returned packets — demux does not hold app policy HWM state.
protocol MediaDemuxing: AnyObject, Sendable {
    /// Present only for demuxers that own a display-evidence book (the network
    /// progressive fMP4 path). `nil` everywhere else keeps the established
    /// display fallback for live, local/offline and other backends.
    nonisolated var displayEvidenceQuery: (any MediaDisplayEvidenceQuerying)? { get }
    /// Prepare readers for video (and optional separate audio URL).
    func open(_ request: MediaOpenRequest) async throws
    /// Best-effort duration after open; 0 if unknown.
    var duration: TimeInterval { get async }
    /// Produce up to `budget` content-seconds of packets **per track** (or until
    /// EOF). Session enqueues into its packet buffers / ContentSecondQueues.
    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket]
    /// Per-track budgets: produce up to `videoBudget` seconds of video and
    /// `audioBudget` seconds of audio. A track with a ~0 budget is not pumped
    /// at all — its reader and any live stream are left untouched. Demuxers
    /// that cannot address tracks separately (muxed HLS segments, AVAsset
    /// round-robin, test fakes) take the extension default, which forwards to
    /// the single-budget form; the session's per-track residual accounting
    /// absorbs any cross-track overshoot without halting the other track.
    func pump(videoBudget: TimeInterval, audioBudget: TimeInterval) async throws -> [MediaPacket]
    func pump(
        videoBudget: TimeInterval, audioBudget: TimeInterval,
        sourceWaitBudget: MediaSourceWaitBudget?
    ) async throws -> [MediaPacket]
    /// True when both tracks have reported EOF (or single track if audio nil).
    var isEOF: Bool { get async }
    /// Track topology discovered from the container after `open`.
    ///
    /// Split DASH exposes audio through `audioURL`, while muxed inputs such as
    /// live HLS carry it beside video. The demuxer is the only layer that can
    /// state that topology without guessing from URL shape.
    var providesAudioTrack: Bool { get async }
    /// Declares how the current source can retain a keyframe-safe local video
    /// resume while the audio cursor continues. Unsupported is explicit and
    /// may not be converted into a lifecycle source reopen.
    var videoContinuityTopology: MediaVideoContinuityTopology { get async }
    /// Reposition only the video reader to a keyframe-safe local anchor while
    /// retaining the audio reader/cursor and the existing open source. Split
    /// fMP4 and local indexed inputs implement this; muxed live returns false
    /// because its current-GOP window is the only legal continuation.
    func prepareVideoContinuity(at mediaTime: TimeInterval) async throws -> Bool
    /// Reposition only the video reader to a keyframe-safe random-access
    /// authority strictly before `excludedAnchorPTS`.
    ///
    /// This is the one permitted warm-repair escalation for split/indexed
    /// inputs. Repeating `prepareVideoContinuity(at:)` at the same audio target
    /// can select the same fragment and return byte-identical access units, so
    /// it is not a repair. The session still validates the emitted keyframe and
    /// exact compressed candidate before admitting the second decoder rung.
    /// Muxed live and demuxers without an earlier local authority return false;
    /// they may not convert this request into a live seek or source reopen.
    func prepareForwardVideoContinuity(
        _ request: MediaVideoForwardRequest
    ) async throws -> MediaVideoForwardOutcome
    func prepareEarlierVideoContinuity(
        before excludedAnchorPTS: TimeInterval
    ) async throws -> Bool
    /// Pull one direct batch from the video reader positioned by the renewed
    /// continuity transaction. The demuxer acknowledges active-fragment
    /// progress and returns packets directly; it must not duplicate them into
    /// the ordinary relay. The reader mutation generation is stable across
    /// batches until another reader mutation fences the transaction.
    func pumpPositionedVideoContinuity(
        readGeneration: UInt64,
        contentBudget: TimeInterval
    ) async throws -> MediaVideoContinuityBatchOutcome
    func seek(to mediaTime: TimeInterval) async throws
    func close() async

    /// Install the channel through which packets may reach the session BEFORE
    /// the pump that produced them returns (F4).
    ///
    /// Opt-in, with a no-op default: a demuxer that cannot produce packets
    /// incrementally — a muxed HLS segment reader, an AVAsset round-robin, the
    /// test fakes — simply ignores it and keeps returning batches from `pump`.
    /// That is a capability declaration, not a measurement, so unlike
    /// `bufferedContentAhead` a default here fabricates nothing.
    ///
    /// A demuxer that DOES adopt it must route every packet of a pumped track
    /// through the relay and return an empty array for that track. Splitting one
    /// track across both channels inverts decode order.
    func setPacketRelay(_ relay: DemuxPacketRelay?) async

    /// Codec fourcc for a track once `open` has parsed the container
    /// (`avc1` / `hvc1` / `av01` / `mp4a` …). `nil` = the demuxer cannot say.
    ///
    /// **Seam repair 2** (`docs/MEDIAENGINE_ASSESSMENT.md` §3.2 L7): every
    /// container format has this; it used to live on `PathAFMP4Demuxer` alone and
    /// the session reached it by downcast. Any other demuxer therefore handed the
    /// decoder `nil`, VT open failed, and the session still reported `.ready` —
    /// audio with no picture.
    func codec(for kind: MediaTrackKind) async -> String?

    /// Snapshot the selected video track in a single demux operation. `nil`
    /// means the demuxer has no compressed video metadata to provide.
    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration?

    /// Decoder config payload for a track (avcC / hvcC / av1C / esds / ASC).
    /// Empty when the container carries none (e.g. Annex-B in-band parameter sets).
    func formatConfig(for kind: MediaTrackKind) async -> Data

    /// Park support: retire any live network reads (the streaming-mdat chunk
    /// streams) WITHOUT touching reader/cursor state, so a parked session
    /// downloads nothing. A later pump reopens at the committed sample/byte
    /// boundary through the same continuity machinery every discarded pump
    /// uses. Default no-op: demuxers without live streams have nothing to
    /// retire.
    func retireLiveStreams() async

    /// Explicitly interrupt the currently-owned blocking I/O for a bounded
    /// local operation. This is separate from `retireLiveStreams()`: the park
    /// optimization's default no-op must never be treated as cancellation
    /// acknowledgement.
    func interruptActiveIO() async -> MediaDemuxIOInterruptResult

    /// Per track, content seconds past the demuxed position that the byte
    /// store already holds as whole fragments — reachable without the network.
    /// Default `.empty`; see `MediaCachedContentAhead`.
    func cachedContentAhead() async -> MediaCachedContentAhead
    /// Retire display evidence after a true Session reset, without moving readers.
    func retireResidentDisplay(video: Bool, audio: Bool) async

    /// Explicit capabilities: the adaptive product wrapper must forward these.
    func multiConnectionTelemetry() async -> MultiConnectionTelemetry
    func setMultiConnectionQuiet(_ quiet: Bool) async
    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async
    /// Memory pressure suppresses speculative transfers for the current open.
    func cancelMultiConnectionPrefetching() async

    /// Whether `cachedContentAhead` can ever answer non-empty — a byte store
    /// is behind this demuxer. Fixed for the demuxer's lifetime, so the
    /// session skips the query (an actor hop per fill) when it cannot.
    /// Default `false`.
    var measuresCachedContentAhead: Bool { get }
}

extension MediaDemuxing {
    /// Demuxers without a display book keep the session's established display
    /// producer (raw runway plus the resident-fragment supplement).
    nonisolated var displayEvidenceQuery: (any MediaDisplayEvidenceQuerying)? { nil }
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

    /// "I cannot deliver incrementally." The session keeps ingesting this
    /// demuxer's batch returns exactly as before.
    func setPacketRelay(_ relay: DemuxPacketRelay?) async {
        _ = relay
    }

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration? { nil }

    /// Defaults keep Stub / Fake / AVAsset demuxers compiling: "I do not know".
    /// A decoder that needs a config will then fail **closed** at open.
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

/// What a video decoder is opened with.
///
/// Engine-local on purpose: the session hands over what the **demuxer** knows and
/// lets the **decoder** decide how to turn it into whatever its backend needs.
/// Before this existed the session built a `CMFormatDescription` itself and then
/// downcast to `VideoToolboxDecoder` to hand it over (assessment §3.2 L8), so a
/// non-VT decoder could only ever be reached through the byte-blob path.
///
/// `@unchecked Sendable`: `CMFormatDescription` is an immutable CoreMedia value
/// object; it is created once at open and only read afterwards.
enum MediaVideoFormat: @unchecked Sendable {
    /// Container already produced a CoreMedia description (AVAsset-class demux).
    case description(CMFormatDescription)
    /// Sample-entry codec configuration and any coded dimensions supplied by the demuxer.
    case codecConfig(codec: String?, config: Data, codedDimensions: MediaVideoCodedDimensions? = nil)
}

protocol MediaVideoDecoding: AnyObject, Sendable {
    /// Opaque identity for the currently retained native decoder session.
    ///
    /// The default is intentionally harmless for Stub/Fake decoders. Production
    /// decoders may expose a stable value across flushes and replace it when
    /// their native session is recreated; callers must not infer behavior from
    /// the value itself.
    var debugSessionID: UInt64 { get }

    func open(formatHint: Data?) async throws

    /// Open with everything the demuxer could state about the track.
    ///
    /// Default implementation flattens to `open(formatHint:)` so byte-blob
    /// decoders keep working; a decoder that cannot consume a CoreMedia
    /// description fails **closed** instead of opening blind.
    func open(format: MediaVideoFormat) async throws
    /// Decode one packet; may return 0…N frames (B-frame reorder).
    /// Caller owns returned frames and must present/release on an appropriate queue.
    func decode(_ packet: MediaPacket) async throws -> [MediaVideoFrame]
    /// Seek / resume-open preroll only (task 10-03, design §3.2 / §5): decode
    /// a bounded run of PRE-TARGET packets, applying each submission's
    /// already-decided action. Returns only after every output of the batch
    /// has been delivered (VideoToolbox: `WaitForAsynchronousFrames`), so no
    /// callback, image or fault outlives the call. Outputs that `keepOutput`
    /// rejects are counted and released, never returned.
    ///
    /// The default (every decoder without a native override) is sequential
    /// `decode(_:)`: `.skip` is honoured, `.truncate` cuts `packet.data`.
    func decodePrerollBatch(
        _ batch: [VideoPrerollSubmission],
        keepOutput: @escaping @Sendable (TimeInterval, TimeInterval) -> Bool
    ) async throws -> VideoPrerollBatchResult
    /// Cumulative per-native-session anomaly counters (design C11). Counting
    /// only. Default: zero, for decoders that observe nothing.
    var decodeAnomalyCounters: VideoDecodeAnomalyCounters { get }
    func flush() async
    func close() async
}

/// One pre-target packet and what the preroll decided to do with it.
struct VideoPrerollSubmission: @unchecked Sendable {
    var packet: MediaPacket
    var action: VideoPrerollSampleAction
}

/// Result of one `decodePrerollBatch` call. Not `Sendable` for the same reason
/// as `MediaVideoFrame`.
struct VideoPrerollBatchResult {
    /// Decoded frames `keepOutput` accepted, in callback (decode) order.
    var keptFrames: [MediaVideoFrame] = []
    /// PTS of EVERY decoded output in callback order, kept or discarded —
    /// decode-frontier and liveness progress (discarded output is progress).
    var outputPTS: [TimeInterval] = []
    /// Decoded, rejected by `keepOutput`, pixel buffer already released.
    var discardedFrames = 0
    /// Samples handed to the decoder (truncated ones included).
    var submitted = 0
    /// Samples never handed to the decoder.
    var skipped = 0
    /// Subset of `submitted` cut to their reference prefix.
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

    /// The protocol default's body, callable by overrides that only want to
    /// observe the batch (test decoders).
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
                // Same bound as the VideoToolbox batch: a non-positive cut
                // is not a prefix, so the whole sample is submitted.
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
    /// Open with the track's sample-entry fourcc (`mp4a`, `fLaC`, …) as well
    /// as its codec-config payload — the audio analogue of the video seam's
    /// `MediaVideoFormat.codecConfig(codec:config:)`.
    ///
    /// Default implementation drops the codec and forwards to
    /// `open(formatHint:)`, so a codec-blind decoder keeps its behaviour. A
    /// decoder that serves more than one codec must implement this and fail
    /// **closed** on a codec it does not decode.
    func open(codec: String?, formatHint: Data?) async throws
    /// `pendingDisplaySupport` is registered before the decoder await. A decoder
    /// may install display evidence for a result containing one real PCM frame.
    func decode(
        _ packet: MediaPacket, pendingDisplaySupport: AudioPendingDisplaySupport
    ) async throws -> [MediaAudioFrame]
    /// Bounded evidence for the most recent compressed-input conversion.
    ///
    /// A converter may consume an access unit and return no PCM while it is
    /// waiting for more input.  Keeping that fact at the decoder boundary lets
    /// startup distinguish lookahead from EOF or a real converter error without
    /// making the session infer codec behavior from a packet count.
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

/// Decoded-video scheduling and renderer health, independent of native hosts.
@MainActor
protocol MediaVideoRendering: AnyObject {
    /// Native renderer health sampled at a complete liveness-window boundary.
    /// The default keeps placeholder/test renderers neutral; the ASBD
    /// implementation reports back-pressure/failure/flush state directly.
    var demandLivenessRenderer: DemandLivenessRenderer { get }
    func setScaleMode(_ mode: VideoScaleMode)
    /// Enqueue a decoded frame for display.
    ///
    /// **A2-α:** implementations that own a display timebase must schedule by
    /// `frame.pts` (media timeline). Steady-state must **not** use
    /// `DisplayImmediately` / invalid PTS. Placeholders may no-op or throw.
    func present(_ frame: MediaVideoFrame) throws
    /// Drive the display slave clock (A2-α `AVSampleBufferRenderSynchronizer`).
    ///
    /// - `rate == 0`: freeze display at `mediaTime` (pause / underrun).
    /// - `rate > 0`: run display timeline from `mediaTime` at that rate.
    /// Default no-op so Fake/placeholder renderers stay free of AVFoundation display.
    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval)
    func flush()
    func invalidate()
}

extension MediaVideoRendering {
    var demandLivenessRenderer: DemandLivenessRenderer { .ready }

    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval) {
        _ = rate
        _ = mediaTime
    }
}

/// Resource availability is independent of durable playback intent and source health.
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
    /// True while this renderer still holds undrained/unplayed PCM. Deliberately
    /// has **no default** (same rule as `reportsRenderedContent`'s siblings
    /// `runtimeGeneration`/`hasParkedSession`): a conformance that always answers
    /// `false` would end playback a buffer early, silently, on whichever
    /// implementation forgot to opt in.
    var hasPendingOutput: Bool { get }
    /// Invalidates current output facts; never carries a captured resume command.
    func setOutputStateChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?)
    /// Requires an already-admitted Play/resume; never an environment callback.
    /// Repair only local output resources, retaining source, PCM and clock.
    func reconcileOutputForAuthorizedPlayback() throws
    var playbackRate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    /// Content seconds that must be available before playback can be committed.
    /// A renderer with no local reservoir may return zero; a ring-backed renderer
    /// reports the reserve it will synchronously pull during `start(source:)`.
    var launchReserveContentSeconds: TimeInterval { get }
    /// Reserve required by the renderer's private seek staging slot. This may
    /// differ from cold-start reserve at slow playback rates.
    var seekTransitionReserveContentSeconds: TimeInterval { get }
    /// Current cumulative output estimate or explicitly limited fallback. This
    /// is a display projection, not a sample-accurate audible clock or F1 writer.
    var presentationTiming: MediaAudioPresentationTiming { get }
    /// Compatibility projection; one implementation owns the native timing read.
    var contentTimePresentationOffset: TimeInterval { get }
    /// Start pull graph; puller asks session for PCM via `AudioPullSource`.
    func start(source: AudioPullSource) throws
    func pause()
    func stop()

    /// Optional: build + prepare the output graph ahead of `start(source:)`
    /// so the session can hide the bring-up cost under its open prime.
    /// Defaulted to a no-op — only renderers with an expensive hardware
    /// graph implement it. Must be safe to call at any point before start
    /// and must not start rendering or touch clock-facing state.
    func prewarmHardwareGraph()

    /// Begin a running-seek handoff. Implementations keep their graph alive,
    /// gate output, and stage into storage that is not being consumed by the
    /// real-time callback. `flush()` is intentionally not part of this path.
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

    /// Destructive lifecycle cleanup. Call only while stopping, opening, or
    /// closing a renderer; a running seek uses the transaction above.
    func flush()

    /// This renderer reports the content it has actually **rendered** through
    /// `AudioPullSource.renderedContentDidAdvance`.
    ///
    /// That report is the session's single F1 advance input (A2-α rule 2), so a
    /// renderer answering `false` is **not a legal master clock** and the session
    /// refuses to start it rather than play audio over a frozen `mediaTime`.
    ///
    /// **Seam repair 1** (assessment §3.2 L5): which of the two legal `mediaTime`
    /// writers was live used to be decided by
    /// `(audioRender as? EngineAudioRenderer)?.engineStarted`, i.e. by a class
    /// identity. Any other correct audio graph silently got the bursty ring-FILL
    /// clock that commit `eeb96ca` removed — judder, no error, no test.
    /// Hardware renderers report on drain; fill-only renderers report on pull.
    var reportsRenderedContent: Bool { get }
}

/// Opaque renderer-owned identity for one staged PCM publication.
struct MediaAudioSeekToken: Hashable, Sendable {
    let generation: UInt64
}

/// Readiness returned after target PCM has been synchronously staged. Session
/// PCM existence alone is not enough: the renderer must have its bounded launch
/// reserve before a backend may authorize a commit.
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

    /// Renderers without an expensive graph have nothing to warm.
    func prewarmHardwareGraph() {}

    func pause() {
        stop()
    }

    /// Test/fill-only renderers without a local PCM queue still participate in
    /// the same logical transaction. Their session-owned PCM remains available
    /// for the next start, while the hardware renderer overrides these methods
    /// with the fixed two-slot publication.
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

/// Pure A3c latency projection shared by the renderer and session.
///
/// `AVAudioUnitTimePitch.latency` is expressed in output/wall seconds. Convert
/// it to content seconds at the applied rate before comparing it with media PTS.
/// Invalid values fail closed to zero rather than moving display time.
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

/// Audio renderer pulls content-seconds of PCM; session supplies frames.
@MainActor
protocol AudioPullSource: AnyObject {
    /// Fill `buffer` with up to `frameCount` interleaved Float32 frames at the
    /// engine sample rate. Returns frames written and content seconds advanced.
    func pullPCM(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioRendererPull

    /// Report that `seconds` of audio content has actually been RENDERED (drained
    /// from the ring to the consumer) since the last report.
    ///
    /// **This is the session's only F1 advance input.** The master clock must
    /// track drain (smooth, real-time playback), not the bursty ring FILL —
    /// pulling fills 1.5 s in one shot then idles, so advancing the clock on the
    /// supply side makes `mediaTime` jump in bursts and the video slave judder
    /// (commit `eeb96ca`). Handing PCM to a renderer is *supply*, not evidence
    /// that it was heard, so `pullPCM` never advances the clock.
    ///
    /// Every renderer reports: a hardware graph reports what its ring drained, a
    /// fill-only / test renderer reports what it consumed (for it, supplied and
    /// rendered are the same event). See `MediaAudioRendering.reportsRenderedContent`.
    /// Optional exact sidecar from this same drain snapshot. It has no clock
    /// authority of its own and must pass the session's existing F1 gate.
    func renderedContentDidAdvance(
        bySeconds seconds: TimeInterval, displayObservation: AudioRenderedDisplayObservation?
    )

    /// The same PCM, reachable **without** MainActor.
    ///
    /// A ring-backed renderer feeds its ring from its own queue, because the ring
    /// holds a quarter second and MainActor has been measured 283–400 ms late on a
    /// background transition. That producer cannot call `pullPCM` — this protocol
    /// is `@MainActor` — so it pulls through here instead. `pullPCM` keeps its
    /// exact shape and stays the MainActor path for the transaction call sites
    /// (`start`, `prepareSeekTransition`). Its returned display spans move with
    /// retained ring PCM; both entry points reach the same
    /// PCM through the same lock, so there is one supply and no branch.
    ///
    /// **No default on purpose.** A default returning an empty supply would let a
    /// conformance feed the hardware silence forever with no error — the same
    /// silent-failure shape that `parkForReuse` and `runtimeGeneration` had their
    /// defaults removed for.
    nonisolated var audioSupply: any AudioSupplySource { get }

    /// What the off-MainActor feeder pulled since the last report.
    ///
    /// This is the eventually-consistent half of `pullPCM`: decode scheduling and
    /// buffering state, which tolerate lateness because there are seconds of banked
    /// PCM behind them. It is **supply**, so like `pullPCM` it must never move the
    /// clock; `renderedContentDidAdvance` remains the only F1 input.
    func audioSupplyDidReport(_ report: AudioFeederPullReport)
}

extension AudioPullSource {
    func renderedContentDidAdvance(bySeconds seconds: TimeInterval) {
        renderedContentDidAdvance(bySeconds: seconds, displayObservation: nil)
    }

    /// Default no-op for pull sources that are not a session (test doubles).
    func renderedContentDidAdvance(
        bySeconds seconds: TimeInterval, displayObservation: AudioRenderedDisplayObservation?
    ) {}

    /// Default no-op: a double with no packet queue has no decode to schedule and
    /// no buffering state to move. Unlike `audioSupply` this is safe to default —
    /// skipping it loses a scheduling nudge, not the audio itself.
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
}

/// Snapshot for health / SmartCDN / backend `dynamicInfo` (Path A **A7**).
struct MediaFrameRateSample: Sendable, Equatable {
    var decodedFPS: Double
    var presentedFPS: Double

    /// Convert one wall-clock counter window into rates. Absolute media time is
    /// deliberately not an input: resume/seek targets are timeline positions,
    /// not elapsed sampling duration.
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
    /// Pipeline goodput counter: payload bytes of packets INGESTED (store-fed
    /// included). Delivery health and liveness read this.
    var bytesRead: Int64
    /// Bytes received from the network for this stream (primary source +
    /// multi-connection helpers + HLS), store hits excluded. The display reads this.
    var networkBytesReceived: Int64
    var videoPackets: Int
    /// Generation-scoped compressed-video consumption counters. These are not
    /// inferred from bytes, queue depth, ingest, or FPS.
    var videoPacketsDequeued: Int
    var videoPacketsSubmitted: Int
    var videoInputContentSecondsConsumed: TimeInterval
    var audioPackets: Int
    var pendingVideoFrames: Int
    var pendingPCMSeconds: TimeInterval
    var mediaTime: TimeInterval
    var bufferedTime: TimeInterval
    var isBuffering: Bool
    /// Decoded video frames this open (not display FPS).
    var decodedVideoFrames: Int
    var presentedVideoFrames: Int
    var videoOutputPTSAdvanced: Bool
    /// Latest wall-clock window rates; independent from absolute media PTS.
    var decodedVideoFPS: Double
    var presentedVideoFPS: Double
    /// Dimensions observed from an actual decoded pixel buffer.
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

/// Coordinator: demux ↔ queues ↔ decode ↔ render. No app/CDN/VLC types.
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
    /// Session generation used to reject late runtime-fault callbacks.
    var runtimeGeneration: UInt64 { get }
    var playbackRate: Float { get set }
    /// Engine diagnostics (A7). Default implementations may return `.zero`.
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
