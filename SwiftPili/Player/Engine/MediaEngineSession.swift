import CoreVideo
import Foundation
import UIKit

@MainActor
final class EnginePiPSeekRequest {
    let interval: TimeInterval
    let ownerGeneration: UInt64
    let currentAdmission: @MainActor @Sendable () -> Bool
    let settlement: @MainActor @Sendable (Bool) -> Void
    var didSettle = false

    init(
        interval: TimeInterval,
        ownerGeneration: UInt64,
        currentAdmission: @escaping @MainActor @Sendable () -> Bool,
        settlement: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.interval = interval
        self.ownerGeneration = ownerGeneration
        self.currentAdmission = currentAdmission
        self.settlement = settlement
    }

    var isCurrent: Bool { !didSettle && currentAdmission() }

    func finish(success: Bool) {
        guard !didSettle else { return }
        didSettle = true
        settlement(success)
    }
}

enum DemandVideoCandidateProvenance: Equatable, Sendable {
    case suspendEdge(readGeneration: UInt64)
    case postSuspend(readGeneration: UInt64)
    case positioned(readGeneration: UInt64)
    case forwardPositioned(MediaVideoForwardReceipt)
}

@MainActor
final class DecodeLaneGate {
    var isHeld = false
    var waiters: [CheckedContinuation<Void, Never>] = []

    var isHeldForScheduling: Bool { isHeld }

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard isHeld else { return }
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isHeld = false
        }
    }
}

struct FlowGapStage {
    var last: ContinuousClock.Instant?
    var windowCount = 0
    var windowMaxGapMs = 0

    mutating func note(now: ContinuousClock.Instant, stallMs: Int) -> Int? {
        defer { last = now }
        windowCount += 1
        guard let last else { return nil }
        let gap = Int(last.duration(to: now) / .milliseconds(1))
        if gap > windowMaxGapMs { windowMaxGapMs = gap }
        return gap >= stallMs ? gap : nil
    }

    func windowField(now: ContinuousClock.Instant) -> String {
        if windowCount > 0 { return "\(windowCount)/\(windowMaxGapMs)ms" }
        guard let last else { return "0(-)" }
        return "0(idle \(Int(last.duration(to: now) / .milliseconds(1)))ms)"
    }

    mutating func resetWindow() {
        windowCount = 0
        windowMaxGapMs = 0
    }

    mutating func resetAll() {
        last = nil
        resetWindow()
    }
}

@MainActor
final class MediaEngineSession: MediaEnginePresentation, AudioPullSource, EnginePiPTransportDelegate,
    WarmPreparationTransactionHost {
    enum EnginePCM {
        static let sampleRate: Double = 48_000
        static let channelCount: Int = 2
        static let aacOutputQuantumSeconds: TimeInterval = 1024.0 / sampleRate
    }

    /// 0.3 s normally; video enhancement may raise it (memory-bounded) so the worker has slack.
    var videoPresentLeadSeconds: TimeInterval {
        (videoRender as? SampleBufferVideoRenderer)?.preferredPresentLeadSeconds ?? 0.3
    }
    var videoFrameQueueHighWater: TimeInterval { max(0.4, videoPresentLeadSeconds + 0.15) }
    let displayResyncEpsilonSeconds: TimeInterval = 0.25
    let displayDriftResyncSeconds: TimeInterval = 0.08
    var lastDisplayResyncPresentationTime: TimeInterval = -1
    var lastDisplayPresentationOffset: TimeInterval?
    var lastDisplayPinGeneration: Int?
    var audioOutputDisplayHold: (generation: Int, time: TimeInterval)?

    var onEvent: (@MainActor @Sendable (MediaSessionEvent) -> Void)?
    var audioOutputStateChangeHandler: (@MainActor () -> Void)?
    var onPresentationFailure:
        (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    var onPiPTransportEvent:
        (@MainActor @Sendable (EnginePiPTransportEvent) -> Void)?
    var onPiPSkipRequest: (@MainActor @Sendable (EnginePiPSeekRequest) -> Void)?

    let diagnostics: any MediaEngineDiagnostics
    let tracing: any MediaEngineTracing
    let demux: any MediaDemuxing
    let warmVideoPreparationDeadline: Duration
    var videoDecoder: any MediaVideoDecoding
    let videoDecoderFactory: (@MainActor @Sendable () -> any MediaVideoDecoding)?
    var videoDecoderWasRetired = false
    var videoDecoderHasNativeSession = false
    var videoDecoderRepairTask: Task<Bool, Never>?
    var nextVideoDecoderRepairID: UInt64 = 0
    var activeVideoDecoderRepairID: UInt64?
    var videoDecoderRepairAttempted = false
    var pipVideoResumeTask: Task<Bool, Never>?
    var nextPiPVideoResumeID: UInt64 = 0
    var activePiPVideoResumeID: UInt64?
    static let maxOutstandingVideoDecoderRetirements = 2
    var outstandingVideoDecoderRetirements: [ObjectIdentifier: UInt64] = [:]
    var nextVideoDecoderRetirementID: UInt64 = 0
    var videoDecoderRetirementAdmissionFailureCount = 0
    var videoDecoderRetirementCompletionCount = 0
    struct VideoDecoderOpeningState {
        let decoder: any MediaVideoDecoding
        var retirementNeeded = false
        var retirementRequested = false
        var openCompleted = false
    }
    var openingVideoDecoders: [ObjectIdentifier: VideoDecoderOpeningState] = [:]
    let audioDecoder: any MediaAudioDecoding
    let videoRender: any MediaVideoPresentation
    let audioRender: any MediaAudioRendering

    var clock = MediaClock()
    var pausedRunwayRefreshTask: Task<Void, Never>?
    var nextPausedRunwayRefreshID: UInt64 = 0
    var activePausedRunwayRefreshID: UInt64?
    var videoPacketQueue = ContentSecondQueue(highWater: 20, lowWater: 4)
    var audioPacketQueue = ContentSecondQueue(highWater: 20, lowWater: 4)
    var videoPackets = PacketRingBuffer()
    var audioPackets = PacketRingBuffer()
    var residualVideoPackets = PacketRingBuffer()
    var residualAudioPackets = PacketRingBuffer()
    var suspendedVideoGOP: [MediaPacket] = []
    var suspendedVideoGOPContentSeconds: TimeInterval = 0
    var suspendedVideoGOPBytes = 0
    var suspendedVideoGOPProvenance: DemandVideoCandidateProvenance?
    var suspendedVideoSupplyMemorySuppressed = false
    var nextVideoReadGeneration: UInt64 = 0
    var videoReadBytes = 0
    static let suspendedVideoGOPMaxContentSeconds: TimeInterval = 8
    static let suspendedVideoGOPMaxBytes = 16 * 1024 * 1024
    static let suspendedVideoWindowMaxContentSeconds: TimeInterval = 16
    static let suspendedVideoWindowMaxBytes = 48 * 1024 * 1024
    static let videoContinuityAnchorToleranceSeconds: TimeInterval = 0.05
    var isCollectingWarmVideoRunUp = false
    var nextVideoContinuityCandidateGeneration: UInt64 = 0
    var warmVideoCandidateAuthorities: [MediaVideoContinuityCandidateAuthority] = []
    enum WarmVideoCandidateDisposition: Equatable, Sendable {
        case bracketingPreRoll
        case nearFutureImageHold(notBeforePTS: TimeInterval)
        case positionedFutureImageHold(MediaVideoForwardReceipt)
        case requiresPositioning

        var futureNotBeforePTS: TimeInterval? {
            switch self {
            case .nearFutureImageHold(let value): value
            case .positionedFutureImageHold(let receipt): receipt.anchorPTS
            case .bracketingPreRoll, .requiresPositioning: nil
            }
        }

        var diagnosticName: String {
            switch self {
            case .bracketingPreRoll:
                "bracketing-pre-roll"
            case .nearFutureImageHold:
                "near-future-image-hold"
            case .positionedFutureImageHold:
                "positioned-future-image-hold"
            case .requiresPositioning:
                "requires-positioning"
            }
        }
    }

    struct WarmVideoImageHoldSnapshot: Equatable, Sendable {
        let runID: UInt64
        let token: DemandVideoSuspendToken
        let sessionGeneration: UInt64
        let engineGeneration: Int
        let ownerGeneration: UInt64
        let candidateAuthorityGeneration: UInt64
        let candidateProvenance: DemandVideoCandidateProvenance
        let notBeforePTS: TimeInterval
        let candidateTailPTS: TimeInterval
        let foregroundFetchBytes: Int
        var rateRevision: UInt64
        var renderGeneration: Int?
        var hasReachedAudioDueTime: Bool
    }

    static let suspendedVideoTargetAheadSeconds: TimeInterval = 1.0
    var activeWarmVideoImageHold: WarmVideoImageHoldSnapshot?
    var warmVideoImageHoldRefreshTask: Task<Void, Never>?
    var nextWarmVideoImageHoldRefreshID: UInt64 = 0
    var activeWarmVideoImageHoldRefreshID: UInt64?
    var playbackRateRevision: UInt64 = 0
    var videoContinuationGeneration: UInt64 = 0
    var activeVideoSuspendToken: DemandVideoSuspendToken?
    var isVideoLaneWarmSuspended = false {
        didSet { if isVideoLaneWarmSuspended { invalidateSourceWaitBudget() } }
    }
    var isVideoLanePreparedForForeground = false
    var isPreparingWarmVideoLane = false {
        didSet { if isPreparingWarmVideoLane { invalidateSourceWaitBudget() } }
    }
    var videoDecodeLaneOwners = 0
    let directVideoDecodeLane = DecodeLaneGate()
    var audioDecodeLaneOwners = 0
    let directAudioDecodeLane = DecodeLaneGate()
    let warmPreparationTransaction: WarmPreparationTransaction
    var isDecodingWarmVideoCandidate = false
    var suspendedVideoFault: MediaRuntimeFault?
    var terminalVideoPreparationFailure: DemandPresentationFailure?
    var warmVideoPreparationLedger = WarmVideoPreparationLedger()
    var warmVideoSubmissionsWithoutOutput = 0
    var videoContinuityTopology: MediaVideoContinuityTopology = .unsupported
    static let warmVideoDecoderRepairLimit = 1
    static let warmVideoNoOutputSubmissionLimit = 64
    static let warmVideoDirectContentSpanLimit: TimeInterval = 12
    static let warmVideoDirectWallLimit: Duration = .seconds(5)
    static let warmVideoDirectNoProgressLimit = 3

    typealias WarmVideoPreparationRun = WarmVideoPreparationRunLedger.Run

    typealias WarmVideoPreparationAttempt = WarmVideoPreparationLedger.Attempt

    struct WarmVideoPreparationDiagnostics: Equatable {
        let runID: UInt64
        let target: TimeInterval
        var phases: [String]
        let decoderOpenMs: Int
        let firstDecodeAwaitMs: Int?
        let totalDecodeWallMs: Int
        let decodedFrames: Int
        let prerollFramesDropped: Int
        let targetFramesBanked: Int
        let decodeBursts: Int
        let demuxWaitMs: Int
        let schedulingWaitMs: Int
        var presentationProofCallbackMs: Int?
        var preparedToProofMs: Int?
        let firstOutputMs: Int?
        let initialFloorDrops: Int
        let movingFloorDrops: Int
        let pumps: Int
        let submittedPackets: Int
        let finalTarget: TimeInterval
        let totalPreparationMs: Int
        let attemptID: UInt64?
        let outcome: String
        let beforeDecoderOpenMs: Int?
        let bankedFramesExpired: Int
        let quiesceWaitMs: Int
        let decoderTiming: WarmVideoDecoderTimingObservation?
    }

    struct WarmVideoDecoderTimingObservation: Equatable {
        let segmentID: Int
        let selectionAttemptID: UInt64?
        let decoderIdentity: ObjectIdentifier
        var snapshot: MediaVideoDecodeTimingSnapshot?
    }

    struct WarmVideoDecoderTimingOwner {
        let runID: UInt64
        var observation: WarmVideoDecoderTimingObservation
        var reporter: (any MediaVideoDecodeTimingReporting)?
    }

    var activeWarmDiagnostics: WarmVideoPreparationDiagnosticsState?
    var lastWarmVideoPreparationDiagnostics: WarmVideoPreparationDiagnostics?
    struct WarmDiagnosticProofIdentity {
        let run: WarmVideoPreparationRun
        let attemptID: UInt64?
        let preparedAt: ContinuousClock.Instant
        var renderGeneration: Int?
        var floor: TimeInterval
    }
    var warmDiagnosticProofIdentity: WarmDiagnosticProofIdentity?

    struct WarmVideoPreparationDiagnosticsState {
        let runID: UInt64
        let target: TimeInterval
        let startedAt: ContinuousClock.Instant
        var phases: [String] = []
        var decoderOpenTime: Duration = .zero
        var firstDecodeAwaitMs: Int?
        var totalDecodeTime: Duration = .zero
        var decodedFrames = 0
        var prerollFramesDropped = 0
        var targetFramesBanked = 0
        var decodeBursts = 0
        var demuxWaitTime: Duration = .zero
        var schedulingWaitTime: Duration = .zero
        var firstDecodeStartedAt: ContinuousClock.Instant?
        var firstOutputMs: Int?
        var initialFloorDrops = 0
        var movingFloorDrops = 0
        var pumps = 0
        var submittedPackets = 0
        var attemptID: UInt64?
        var beforeDecoderOpenMs: Int?
        var bankedFramesExpired = 0
        var quiesceWaitTime: Duration = .zero
        var decoderTimingOwner: WarmVideoDecoderTimingOwner?
    }

    let nominalZeroDurationVideoSeconds: TimeInterval = 1.0 / 30.0
    let nominalZeroDurationAudioSeconds: TimeInterval = 1024.0 / 48_000.0
    var zeroDurationPacketsNormalized = 0
    var pendingVideoFrames: [MediaVideoFrame] = []
    var pendingVideoContentSeconds: TimeInterval = 0
    let audioTimelineBuffer = AudioTimelinePCMSupply(
        defaultSampleRate: EnginePCM.sampleRate,
        defaultChannels: EnginePCM.channelCount,
        timelineEpsilon: EnginePCM.aacOutputQuantumSeconds
    )
    var subtitlePCMTap: AudioPCMSubtitleTap?

    nonisolated var audioSupply: any AudioSupplySource { audioTimelineBuffer }
    var hasAudioTrack = false
    var supplyLoopTask: Task<Void, Never>?
    var supplyLoopWake: CheckedContinuation<Void, Never>?
    var supplyLoopWakePending = false
    var isFillingQueues = false
    var nextQueueFillTraceID: UInt64 = 0
    var lastFillProducedPackets = false
    var decodeTask: Task<Void, Never>?
    var audioDecodeTask: Task<Void, Never>?
    var nextVideoDecodeOperationID: UInt64 = 0
    var activeVideoDecodeOperationID: UInt64?
    var nextAudioDecodeOperationID: UInt64 = 0
    var activeAudioDecodeOperationID: UInt64?
    var lifecycleSerialTask: Task<Void, Never>?
    var lifecycleOperationID: UInt64?
    var activeOpenTask: Task<Void, Never>?
    var nextLifecycleOperationID: UInt64 = 0
    var generation = 0 {
        didSet {
            audioRender.revokeAudioMaintenancePermission()
            invalidateSourceWaitBudget()
            usefulPrimarySamples.removeAll()
            unresolvedPrimaryTransportFailure = nil
            renderedAudioOutput = nil
        }
    }
    var seekFirstPacketLogged = true
    struct PiPEventBindingToken: Equatable, Sendable {
        let generation: UInt64
    }

    var nextPiPEventBindingGeneration: UInt64 = 0
    var activePiPEventBindingToken: PiPEventBindingToken?
    var isAutomaticPiPEnabled = false
    var activeOwnerGeneration: UInt64 = 0
    var activeStartupTraceToken: MediaEngineTraceID?
    var runtimeFaultedGeneration: Int?
    var publishedRuntimeFaultGeneration: Int?
    var observedPiPLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?
    var pipNativeTransitionHandler: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    var pipRestoreRequestHandler: (@MainActor @Sendable (UInt64) -> Void)?
    var nextPiPTransportOperationID: UInt64 = 0
    struct PiPPresentationContinuitySnapshot: Equatable {
        let sessionGeneration: UInt64
        let ownerGeneration: UInt64
        let bindingGeneration: UInt64
        let mediaTime: TimeInterval
        let displayClockSeconds: TimeInterval
        let videoDecoderOpened: Bool
        let presentationProgress: DemandPresentationProgressWitness
        let rendererHealth: DemandPresentationHealth
    }

    var pendingPiPPresentationSnapshot: PiPPresentationContinuitySnapshot?
    var presentationProofHandler: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    var hasObservedPiPLease = false
    var videoDecoderOpened = false
    var audioDecoderOpened = false
    var lastVideoDecoderOpenError: String?
    var lastAudioDecoderOpenError: String?
    var lastAudioDecodeError: String?
    var audioDecodePacketsSubmitted = 0
    var audioDecodePCMFramesProduced = 0
    let videoDecodeBurstLimit = 8
    let audioDecodeBurstLimit = 64
    static let audioPrimeNoPCMProgressBurstLimit = 4
    let audioPCMTargetSeconds: TimeInterval = 4
    let primeVideoContentBudget: TimeInterval = 0.5
    let runtimePassThroughVideoContentHWM: TimeInterval = 1.0
    let minTrackFillRoom: TimeInterval = 0.05
    let supplyLowWaterFraction: TimeInterval = 0.5
    let supplyStallBackoffNanos: UInt64 = 20_000_000
    let pumpCallBudgetCapSeconds: TimeInterval = 1.0

    // MARK: - incremental ingest

    let packetRelay = DemuxPacketRelay()
    var relayDrainCount = 0
    var videoStarvedSince: ContinuousClock.Instant?
    var bufferingForVideoStarvation = false
    let videoPixelFrameBudgetBytes: Int = 120 * 1024 * 1024
    let minPassThroughVideoPackets = 4
    let maxPassThroughVideoPacketsAbsolute = 16
    let defaultVideoFrameWidth = 1920
    let defaultVideoFrameHeight = 1080
    var knownVideoFrameWidth = 0
    var knownVideoFrameHeight = 0
    var holdsPassThroughVideo = false
    var videoEnqueueCap: TimeInterval?
    let primeProgressLogInterval: TimeInterval = 0.5
    var isBuffering = false {
        didSet { if isBuffering { invalidateSourceWaitBudget() } }
    }
    struct SessionSeekTransaction {
        private(set) var activeToken: MediaAudioSeekToken?
        private(set) var prepared: MediaEngineSeekPreparation?
        private(set) var isInFlight = false

        mutating func begin(token: MediaAudioSeekToken) {
            activeToken = token
            prepared = nil
            isInFlight = true
        }

        mutating func markPrepared(_ preparation: MediaEngineSeekPreparation) {
            guard activeToken == preparation.token else { return }
            prepared = preparation
        }

        mutating func finishCommitGate() {
            isInFlight = false
        }

        mutating func clear() {
            activeToken = nil
            prepared = nil
            isInFlight = false
        }
    }

    struct AudioEOFDrainState {
        var isDraining = false
        var emptiedAt: ContinuousClock.Instant?
        var playoutDeadline: ContinuousClock.Instant?
        var wakeTask: Task<Void, Never>?

        mutating func reset() {
            isDraining = false
            emptiedAt = nil
            playoutDeadline = nil
            wakeTask?.cancel()
            wakeTask = nil
        }
    }

    var hasEmittedEnded = false
    var demuxReachedEOF = false
    var audioEOFDrain = AudioEOFDrainState()
    var audioDrainingToEnd: Bool { audioEOFDrain.isDraining }
    var seekTransaction = SessionSeekTransaction()
    var isSeekInFlight: Bool { seekTransaction.isInFlight }
    var pausedCaptureSeekPreparationReceipt: UUID?
    var activeSeekToken: MediaAudioSeekToken? { seekTransaction.activeToken }
    var preparedSeek: MediaEngineSeekPreparation? { seekTransaction.prepared }
    var consecutiveVideoPresentErrorCount = 0

    func beginSeekTransaction(token: MediaAudioSeekToken) {
        seekTransaction.begin(token: token)
        invalidateSourceWaitBudget()
        subtitlePCMTap?.notifyDiscontinuity(reason: .seek, targetPTS: nil)
    }

    func clearSeekTransaction() {
        seekTransaction.clear()
    }
    var outputMediaFloor: TimeInterval = 0 {
        didSet {
            (videoRender as? SampleBufferVideoRenderer)?.updateDemandPresentationFloor(outputMediaFloor)
        }
    }
    let outputMediaFloorEpsilon: TimeInterval = 1e-9
    var videoDecodeFrontierPTS: TimeInterval?
    var audioDecodeFrontierPTS: TimeInterval?

    var staleVideoOutputRejectionCount = 0
    var staleVideoOutputRejectionMinPTS: TimeInterval?
    var staleVideoOutputRejectionMaxPTS: TimeInterval?

    var isReady = false {
        didSet { if !isReady { invalidateSourceWaitBudget() } }
    }
    var isPlaying = false {
        didSet {
            if !isPlaying {
                invalidateSourceWaitBudget()
            }
        }
    }
    var activeSourceWaitBudget: MediaSourceWaitBudget?
    var sourceObservationEpoch: UInt64 = 1
    struct UsefulPrimarySample {
        let acceptedAU: MediaSourceAcceptedAU
        let acceptedAt: TimeInterval
        let elapsed: TimeInterval
    }
    var usefulPrimarySamples: [MediaTrackKind: [UsefulPrimarySample]] = [:]
    var presentedVideoFrameCount = 0
    var decodedVideoFrameCount = 0
    var decodedVideoFPS: Double = 0
    var presentedVideoFPS: Double = 0
    var droppedPrerollVideoFrameCount = 0

    // MARK: Seek / resume-open fast preroll (task 10-03-demand-seek-long-preroll)

    typealias VideoPrerollClassifierFactory = @Sendable (String?, Data) -> (any VideoPrerollSampleClassifying)?
    let seekFastPrerollEnabled: Bool
    let videoPrerollClassifierFactory: VideoPrerollClassifierFactory
    var videoPrerollClassifier: (any VideoPrerollSampleClassifying)?
    var videoPrerollClassifierDecoder: ObjectIdentifier?
    var videoPrerollCodec: String?
    var prerollBatchingActive = false
    var activePrerollStats: SeekPrerollStats?
    var activePrerollStatsGeneration: Int?
    var prerollAnomalyBaseline: (decoder: ObjectIdentifier, counters: VideoDecodeAnomalyCounters)?
    var lastPrerollStats: SeekPrerollStats?
    var seekPhaseStopwatch: SeekPhaseStopwatch?
    var pendingVideoFrameCount: Int { pendingVideoFrames.count }
    var decodedAudioFrameCount = 0
    var droppedPrerollAudioFrameCount = 0
    var trimmedPrerollAudioSampleFrameCount = 0
    var pulledAudioFrameCount = 0
    var audioTimelineAdjustmentLogCount = 0
    var audioDecodeTimingLogCount = 0
    var videoLivenessContext: DemandVideoLivenessContext?
    var videoLivenessDetector = DemandVideoSilentNoOutputDetector()
    let videoLivenessPolicy = DemandVideoLivenessPolicy.provisional
    var videoLivenessStartupUptime: TimeInterval = 0
    var videoLivenessWindowIndex: UInt64 = 0
    var videoLivenessPacketDurations = RollingTimeIntervalWindow()
    var videoLivenessOutputPeriods = RollingTimeIntervalWindow()
    var videoLivenessPTSProgress = DemandLivenessPTSProgress()
    var pipeWindowVideoPacketsDequeued = 0
    var pipeWindowVideoPacketsSubmitted = 0
    var pipeWindowVideoInputSeconds = 0.0
    var pipeWindowVideoBytesRead: Int64 = 0
    var pipeWindowVideoPacketsIngested = 0
    var pipeWindowVideoOutputFrames = 0
    var pipeWindowVideoOutputPTSAdvanced = false
    var pipeWindowVideoOutputPTSDelta: TimeInterval?
    var pipeWindowVideoCallbacks = 0
    var pipeWindowRendererAdmitted = 0
    var pipeWindowRendererPTSAdvanced = false
    var pipeWindowRendererBlocked = false
    var pipeWindowRendererFailed = false
    var insertedAudioTimelineGapSampleFrameCount: Int {
        audioTimelineBuffer.insertedGapFrameCount
    }
    var droppedAudioTimelineOverlapSampleFrameCount: Int {
        audioTimelineBuffer.droppedOverlapFrameCount
    }
    var bytesRead: Int64 = 0
    var networkByteCounter = MediaNetworkByteCounter()
    var totalVideoPacketsIngested = 0
    var totalAudioPacketsIngested = 0
    var totalVideoPacketsDequeued = 0
    var totalVideoPacketsSubmitted = 0
    var totalVideoInputContentSecondsConsumed: TimeInterval = 0
    var totalVideoOutputPTSAdvanced = false

    var pipeWindowStartUptime: TimeInterval = 0
    var pipeWindowStartMediaTime: TimeInterval = 0
    var pipeWindowDecodeFrames = 0
    var pipeWindowPresentFrames = 0
    var pipeWindowPresentCalls = 0
    var pipeWindowPumps = 0
    var pipeWindowParks = 0
    var pipeWindowWakes = 0
    var pipeWindowNotDue = 0
    var pipeWindowNotReady = 0

    var pipeStickyFields: [String: String] = [:]
    var pipeWindowIndex = 0
    var wasCapturingLastWindow = false
    var lastAudioCallbackCount = 0
    var lastAudioRenderedFrameCount = 0

    var flowIngestV = FlowGapStage()
    var flowIngestA = FlowGapStage()
    var flowDecInV = FlowGapStage()
    var flowDecOutV = FlowGapStage()
    var flowPresentV = FlowGapStage()
    var flowClock = FlowGapStage()
    var flowPCM = FlowGapStage()
    var flowWindowMaxPacketAgeMs = 0
    var flowWindowMaxDecodeMs = 0
    var flowLastIngestVideoPTS: TimeInterval = -1
    var flowLastIngestAudioPTS: TimeInterval = -1
    var lastPresentBurstLogAt: TimeInterval = 0
    let flowStallThresholdMs = 700

    var usesSyntheticSilenceClock: Bool {
        !hasAudioTrack && audioRender.reportsRenderedContent
    }

    var drivesAudioClockPipeline: Bool {
        (hasAudioTrack && audioDecoderOpened) || usesSyntheticSilenceClock
    }

    var usesAudioMasterForVideo: Bool {
        drivesAudioClockPipeline
    }

    var mediaTime: TimeInterval { clock.mediaTime }
    var runtimeGeneration: UInt64 { UInt64(max(0, generation)) }
    var duration: TimeInterval { clock.duration }
    var unresolvedPrimaryTransportFailure: StreamTransportFailure?
    struct RenderedAudioOutput {
        let sessionGeneration: UInt64
        let ownerGeneration: UInt64
        let position: TimeInterval
    }
    var renderedAudioOutput: RenderedAudioOutput?

    var cachedVideoRunway: MediaCachedTrackContentAhead = .empty
    var cachedAudioRunway: MediaCachedTrackContentAhead = .empty
    var cachedRunwayEpoch: UInt64 = 0
    var multiConnectionQuiet = false
    let multiConnectionQuietGate = MultiConnectionQuietGate()
    var hasMultiConnectionHelpers = false
    var lastMultiConnectionPlaybackPosition: TimeInterval?
    let helperTelemetry = MultiConnectionTelemetryRefresh()

    var equalizerConfiguration: PlayerEqualizerConfiguration {
        get { audioRender.equalizerConfiguration }
        set { audioRender.equalizerConfiguration = newValue }
    }
    var equalizerStatus: PlayerEqualizerStatus { audioRender.equalizerStatus }
    var videoEnhancementConfiguration: VideoEnhancementConfiguration {
        get { (videoRender as? SampleBufferVideoRenderer)?.videoEnhancementConfiguration ?? .disabled }
        set { (videoRender as? SampleBufferVideoRenderer)?.videoEnhancementConfiguration = newValue }
    }
    var videoEnhancementTelemetry: VideoEnhancementTelemetry {
        (videoRender as? SampleBufferVideoRenderer)?.videoEnhancementTelemetry
            ?? VideoEnhancementTelemetry()
    }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? {
        didSet { audioRender.revokeAudioMaintenancePermission() }
    }
    func revokeAudioMaintenancePermission() { audioRender.revokeAudioMaintenancePermission() }

    func admitAudioMaintenanceResume() -> AudioMaintenancePermit? {
        guard isReady, isPlaying, !hasEmittedEnded,
              runtimeFaultedGeneration != generation, activeOwnerGeneration != 0 else { return nil }
        if isVideoLaneWarmSuspended {
            guard let token = activeVideoSuspendToken,
                  token.sessionGeneration == runtimeGeneration,
                  token.ownerGeneration == activeOwnerGeneration else { return nil }
        }
        return audioMaintenanceAdmission?()
    }

    var playbackRate: Float {
        get { clock.playbackRate }
        set {
            let previousRate = clock.playbackRate
            clock.setPlaybackRate(newValue)
            updateMultiConnectionPlayback()
            audioRender.playbackRate = newValue
            playbackRateRevision &+= 1
            if playbackRateRevision == 0 { playbackRateRevision = 1 }
            if !admitsSourceWaitBudget {
                invalidateSourceWaitBudget()
            } else if newValue > previousRate, let reserve = pipelineRunway {
                let now = ProcessInfo.processInfo.systemUptime
                activeSourceWaitBudget?.tighten(
                    reserve: reserve, rate: newValue,
                    sampledAt: now, usefulLatency: usefulPrimaryLatency(at: now)
                )
            }
            if var hold = activeWarmVideoImageHold {
                hold.rateRevision = playbackRateRevision
                activeWarmVideoImageHold = hold
            }
            if isReady {
                applyPipelineDemand()
                requestSupplyWake()
                scheduleAudioDecodeIfNeeded()
            }
        }
    }

    var effectiveDisplayRate: Float {
        guard isPlaying, !isBuffering, !isSeekInFlight, !isVideoLaneWarmSuspended else { return 0 }
        if drivesAudioClockPipeline {
            switch audioRender.outputAvailability {
            case .available, .fillOnly: break
            case .stopped, .pending, .unavailable: return 0
            }
        }
        return max(0, clock.playbackRate)
    }

    var audioPresentationMediaTime: TimeInterval {
        sampleAudioPresentation().mediaTime
    }

    func sampleAudioPresentation() -> MediaAudioPresentationSnapshot {
        MediaAudioPresentationSnapshot(
            contentTime: clock.mediaTime,
            timing: drivesAudioClockPipeline ? audioRender.presentationTiming : .logical
        )
    }

    var videoPresentationDueTime: TimeInterval {
        audioPresentationMediaTime + videoPresentLeadSeconds
    }

    var videoHost: UIViewController { videoRender.hostViewController }

    var lastPresentNotReadyLogAt: TimeInterval = 0
    var presentFeedArmed = false

    func renderedAudioOutputPosition(ownerGeneration: UInt64) -> TimeInterval? {
        guard isReady, isPlaying, !isSeekInFlight,
              audioRender.outputAvailability == .available,
              let output = renderedAudioOutput,
              output.sessionGeneration == runtimeGeneration, output.ownerGeneration == ownerGeneration,
              activeOwnerGeneration == ownerGeneration else { return nil }
        return output.position
    }

    func transportEngineError(_ error: any Error, stage: StreamTransportFailure.Stage) -> MediaEngineError {
        if let failure = StreamTransportFailure.preserving(error, stage: stage) {
            return .transportFailed(failure.stamped(backend: activeOwnerGeneration, session: runtimeGeneration))
        }
        return error as? MediaEngineError ?? .demuxFailed(error.localizedDescription)
    }

    func retainedPipelineHealth(
        backendGeneration: UInt64
    ) -> RetainedPipelineHealth {
        guard activeOwnerGeneration == backendGeneration else {
            return RetainedPipelineHealth(
                backendGeneration: activeOwnerGeneration,
                state: .requiresRecovery(.staleGeneration)
            )
        }
        guard isReady, runtimeFaultedGeneration == nil else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .requiresRecovery(.transportNotReady)
            )
        }
        guard !isBuffering else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .requiresRecovery(.transportNotReady)
            )
        }
        guard !hasEmittedEnded else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .requiresRecovery(.terminal)
            )
        }
        guard !isSeekInFlight else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .requiresRecovery(.seekInFlight)
            )
        }
        guard videoDecoderOpened, !hasAudioTrack || audioDecoderOpened else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .requiresRecovery(.missingResources)
            )
        }
        guard isPlaying else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .pausedReady
            )
        }
        guard supplyLoopTask != nil, !drivesAudioClockPipeline || audioRender.isRunning else {
            return RetainedPipelineHealth(
                backendGeneration: backendGeneration,
                state: .requiresRecovery(.missingProducer)
            )
        }
        return RetainedPipelineHealth(
            backendGeneration: backendGeneration,
            state: .playingWithProducer
        )
    }

    init(
        demux: any MediaDemuxing,
        videoDecoder: any MediaVideoDecoding,
        videoDecoderFactory: (@MainActor @Sendable () -> any MediaVideoDecoding)? = nil,
        audioDecoder: any MediaAudioDecoding,
        videoRender: any MediaVideoPresentation,
        audioRender: any MediaAudioRendering,
        warmVideoPreparationDeadline: Duration = .seconds(5),
        seekFastPreroll: Bool,
        videoPrerollClassifierFactory: @escaping VideoPrerollClassifierFactory,
        diagnostics: any MediaEngineDiagnostics,
        tracing: any MediaEngineTracing
    ) {
        self.tracing = tracing
        self.diagnostics = diagnostics
        self.seekFastPrerollEnabled = seekFastPreroll
        self.videoPrerollClassifierFactory = videoPrerollClassifierFactory
        self.demux = demux
        self.warmVideoPreparationDeadline = warmVideoPreparationDeadline
        self.warmPreparationTransaction = WarmPreparationTransaction(
            progressWindow: warmVideoPreparationDeadline, directWindow: Self.warmVideoDirectWallLimit,
            diagnostics: diagnostics
        )
        self.videoDecoder = videoDecoder
        self.videoDecoderFactory = videoDecoderFactory
        self.audioDecoder = audioDecoder
        self.videoRender = videoRender
        self.audioRender = audioRender
        audioRender.audioMaintenanceAdmission = { [weak self] in self?.admitAudioMaintenanceResume() }
        audioRender.setOutputStateChangeHandler { [weak self] in self?.audioOutputStateDidChange() }
        self.packetRelay.setWake { [weak self] in
            Task { @MainActor [weak self] in
                self?.drainRelayedPackets()
            }
        }
    }

    func open(_ request: MediaOpenRequest) async {
        pausedCaptureSeekPreparationReceipt = nil
        helperTelemetry.invalidate(.parked)
        multiConnectionQuietGate.setParked(true)
        cancelWarmVideoImageHoldRefresh()
        supersedeWarmVideoPreparationRun()
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        cancelDecode()
        clearPiPEventSource()
        generation &+= 1
        let gen = generation
        stopPipeline(emitPaused: false)
        retireCurrentVideoDecoderWithoutWaiting()

        activeOpenTask?.cancel()
        activeOpenTask = nil
        nextLifecycleOperationID &+= 1
        let operationID = nextLifecycleOperationID
        let predecessor = lifecycleSerialTask
        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentGeneration(gen) else {
                return
            }
            defer { self.finishLifecycleOperation(operationID, isOpen: true) }
            await self.performOpen(request, generation: gen)
        }
        lifecycleOperationID = operationID
        lifecycleSerialTask = operation
        activeOpenTask = operation
        await operation.value
    }

    func performOpen(_ request: MediaOpenRequest, generation gen: Int) async {
        await closeEngineResources()
        guard isCurrentGeneration(gen), !Task.isCancelled else { return }

        multiConnectionQuietGate.setParked(false)
        hasMultiConnectionHelpers = !request.alternateVideoURLs.isEmpty || !request.alternateAudioURLs.isEmpty
        lastMultiConnectionPlaybackPosition = nil
        helperTelemetry.invalidate(hasMultiConnectionHelpers ? .pending : .notConfigured)
        activeOwnerGeneration = request.ownerGeneration
        activeStartupTraceToken = request.startupTraceToken
        runtimeFaultedGeneration = nil
        publishedRuntimeFaultGeneration = nil
        bindPiPEventSource()
        setPresentationProofHandler(presentationProofHandler)
        clock.reset(start: request.startPosition, duration: 0)
        clock.setPlaybackRate(request.preferredRate)
        audioRender.playbackRate = request.preferredRate
        let hwm = max(request.packetQueueHighWater, 2)
        videoPacketQueue = ContentSecondQueue(
            highWater: hwm,
            lowWater: max(hwm * 0.2, 0.5)
        )
        audioPacketQueue = ContentSecondQueue(
            highWater: hwm,
            lowWater: max(hwm * 0.2, 0.5)
        )
        videoPackets = []
        audioPackets = []
        residualVideoPackets = []
        residualAudioPackets = []
        resetCachedRunway()
        resetVideoContinuationState()
        clearPendingVideoFrames()
        clearPendingPCM()
        subtitlePCMTap?.notifyDiscontinuity(reason: .streamReset, targetPTS: request.startPosition)
        pendingPiPPresentationSnapshot = nil
        resetOutputMediaFloor(to: request.startPosition)
        if outputMediaFloor > outputMediaFloorEpsilon {
            beginPrerollStats(context: .open, generation: gen)
        } else {
            activePrerollStats = nil
            activePrerollStatsGeneration = nil
        }
        hasAudioTrack = request.audioURL != nil
        isReady = false
        isPlaying = false
        isBuffering = false
        hasEmittedEnded = false
        demuxReachedEOF = false
        audioEOFDrain.reset()
        clearSeekTransaction()
        consecutiveVideoPresentErrorCount = 0
        videoDecoderOpened = false
        videoDecoderRepairAttempted = false
        audioDecoderOpened = false
        lastVideoDecoderOpenError = nil
        lastAudioDecoderOpenError = nil
        lastAudioDecodeError = nil
        audioDecodePacketsSubmitted = 0
        audioDecodePCMFramesProduced = 0
        resetSessionCounters()
        let openNetworkCounter = networkByteCounter
        resetVideoLivenessState(resetStartup: true)
        resetFlowGapTracking()
        resetDisplayTimeline(to: clock.mediaTime)

        tracing.mark(.demandOpenStarted, token: request.startupTraceToken)
        diagnostics.log(
            "[PathA] session open video=\(request.videoURL.host ?? "?") " +
            "audio=\(request.audioURL?.host ?? "none") start=\(String(format: "%.1f", request.startPosition)) " +
            "hwm=\(String(format: "%.0f", hwm))s " +
            "primeV=\(String(format: "%.1f", primeVideoContentBudget))s " +
            "launchA=\(String(format: "%.3f", requiredAudioLaunchContentSeconds))s " +
            "pixelBudgetMB=\(videoPixelFrameBudgetBytes / (1024 * 1024))"
        )

        do {
            await demux.setPacketRelay(packetRelay)
            await demux.setMultiConnectionQuiet(multiConnectionQuiet)
            var demuxRequest = request
            demuxRequest.multiConnectionQuietGate = multiConnectionQuietGate
            demuxRequest.networkByteCounter = openNetworkCounter
            try await demux.open(demuxRequest)
            tracing.mark(.demandDemuxOpenDone, token: request.startupTraceToken)
            guard isCurrentGeneration(gen) else { return }
            let demuxProvidesAudio = await demux.providesAudioTrack
            videoContinuityTopology = await demux.videoContinuityTopology
            hasAudioTrack = request.audioURL != nil || demuxProvidesAudio
            await openVideoDecoderIfNeeded(expectedGeneration: gen)
            guard isCurrentGeneration(gen) else { return }
            await openAudioDecoderIfNeeded()
            guard isCurrentGeneration(gen) else { return }
            Task { [weak self] in
                guard let self, self.isCurrentGeneration(gen) else { return }
                self.audioRender.prewarmHardwareGraph()
            }
            let d = await demux.duration
            clock.setDuration(d)
            if !hasAudioTrack {
                audioTimelineBuffer.configureSyntheticSilence(
                    enabled: audioRender.reportsRenderedContent,
                    startPTS: request.startPosition,
                    duration: d
                )
                diagnostics.log(
                    "[PathA] video-only stream configured syntheticSilence=" +
                    "\(audioRender.reportsRenderedContent ? 1 : 0) duration=\(String(format: "%.1f", d))s"
                )
            }
            updatePiPPlaybackState()
            let priming = try await primeOpenLaunchReserve(generation: gen)
            guard isCurrentGeneration(gen) else { return }
            let primingFailure: (SeekPrimingFailure, SeekPrimingGate)?
            switch priming {
            case .superseded:
                return
            case .ready(let gate):
                primingFailure = nil
                if gate.passCount > 1 {
                    diagnostics.log(
                        "[PathA] open priming completed after \(gate.passCount) " +
                        "passes: \(gate.diagnosticSummary)"
                    )
                }
            case .failed(let failure, let gate):
                primingFailure = (failure, gate)
            }
            logPrerollSuppression(context: "open")
            finishPrerollStats(generation: gen, token: nil)
            if let fault = await decoderReadinessFault(generation: gen) {
                guard isCurrentGeneration(gen) else { return }
                diagnostics.log("[PathA] open fails closed: \(fault)")
                onEvent?(.failed(.decodeFailed(fault)))
                return
            }
            guard isCurrentGeneration(gen) else { return }
            let readiness = launchReadiness
            guard readiness.video, readiness.audio else {
                if diagnostics.isCapturing {
                    let audioDiagnostics = await audioDecoder.decodeDiagnostics()
                    guard isCurrentGeneration(gen) else { return }
                    diagnostics.log(
                        "[PathA] launch reserve unavailable " +
                        "video=\(readiness.video ? 1 : 0) audio=\(readiness.audio ? 1 : 0) " +
                        "hasAudio=\(hasAudioTrack ? 1 : 0) " +
                        "vOpen=\(videoDecoderOpened ? 1 : 0) aOpen=\(audioDecoderOpened ? 1 : 0) " +
                        "pendingV=\(pendingVideoFrames.count) " +
                        "pcm=\(String(format: "%.3f", pendingAudioContentSeconds)) " +
                        "launchA=\(String(format: "%.3f", requiredAudioLaunchContentSeconds)) " +
                        "vQ=\(String(format: "%.3f", videoPacketQueue.contentSeconds)) " +
                        "aQ=\(String(format: "%.3f", audioPacketQueue.contentSeconds)) " +
                        "vRes=\(residualVideoPackets.count) aRes=\(residualAudioPackets.count) " +
                        "eof=\(demuxReachedEOF ? 1 : 0) " +
                        "audioStatus=\(audioDiagnostics.status.rawValue) " +
                        "audioOSStatus=\(audioDiagnostics.converterStatus.map(String.init) ?? "-") " +
                        "audioCB=\(audioDiagnostics.inputCallbackRequests) " +
                        "audioWait=\(audioDiagnostics.inputCallbackAskedForMore ? 1 : 0) " +
                        "audioPendAU=\(audioDiagnostics.pendingAccessUnits) " +
                        "audioErr=\(lastAudioDecodeError == nil ? 0 : 1) " +
                        "audioPacketsSubmitted=\(audioDecodePacketsSubmitted) " +
                        "audioFramesProduced=\(audioDecodePCMFramesProduced) " +
                        "priming=\(primingFailure.map { "\($0.0.rawValue) \($0.1.diagnosticSummary)" } ?? "ready")"
                    )
                }
                publishRuntimeFault(
                    launchReserveFault(
                        videoReady: readiness.video,
                        audioReady: readiness.audio,
                        primingFailure: primingFailure?.0
                    ),
                    generation: gen,
                    mayBeLocalPresentationDebt: false
                )
                return
            }
            isReady = true
            videoLivenessStartupUptime = ProcessInfo.processInfo.systemUptime
            diagnostics.log({
                let maxV = maxPassThroughVideoPackets()
                let frameBytes = estimatedVideoFrameBytes()
                return "[PathA] prime done vPkts=\(videoPacketCount) aPkts=\(audioPacketCount) " +
                    "vDepth=\(String(format: "%.2f", videoPacketQueue.contentSeconds))s " +
                    "aDepth=\(String(format: "%.2f", audioPacketQueue.contentSeconds))s " +
                    "pendingV=\(pendingVideoFrameCount) pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s " +
                    "decodedV=\(decodedVideoFrameCount) duration=\(String(format: "%.1f", d))s " +
                    "cap video packets \(maxV) (≈\(frameBytes * maxV / (1024 * 1024))MB)" +
                    (holdsPassThroughVideo ? " passThrough=1" : "")
            }())
            tracing.mark(.demandPrimeDone, token: request.startupTraceToken)
            onEvent?(.ready(duration: d))
        } catch {
            guard isCurrentGeneration(gen) else { return }
            onEvent?(.failed(transportEngineError(error, stage: .mediaOpen)))
        }
    }

    func play() {
        guard isReady else { return }
        if hasEmittedEnded, clock.isAtEnd { return }
        guard !isVideoLaneWarmSuspended,
              !isPreparingWarmVideoLane,
              terminalVideoPreparationFailure == nil else {
            diagnostics.log(
                "[PathA][continuation] generic play ignored while video lane is owned"
            )
            return
        }
        multiConnectionQuietGate.setParked(false)
        cancelPausedRunwayRefresh()
        isPlaying = true
        isBuffering = false
        updateMultiConnectionPlayback()
        resetVideoLivenessState(resetStartup: false)
        resetFlowGapTracking()
        updatePiPPlaybackState()
        diagnostics.log(
            "[PathA] session play start mediaTime=\(String(format: "%.2f", clock.mediaTime)) " +
            "rate=\(String(format: "%.2f", clock.playbackRate)) " +
            "vPkts=\(videoPacketCount) aPkts=\(audioPacketCount) " +
            "pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s"
        )
        onEvent?(.playing)
        tracing.mark(.demandPlayStarted, token: activeStartupTraceToken)
        startAudioRenderIfNeeded(reconcileAuthorizedOutput: true)
        tracing.mark(.demandAudioGraphReady, token: activeStartupTraceToken)
        applyPipelineDemand()
        resetPipeInstrumentWindow()
        armPresentFeedIfNeeded()
        presentDueVideoFrames()
        startSupplyLoop()
        scheduleVideoDecodeIfNeeded()
        scheduleAudioDecodeIfNeeded()
        if !hasAudioTrack, !drivesAudioClockPipeline {
            startVideoTailDrainIfNeeded()
        }
    }

    func resumeAudioWhileVideoSuspended(_ token: DemandVideoSuspendToken) -> Bool {
        guard isReady, !hasEmittedEnded, isVideoLaneWarmSuspended,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration else { return false }
        cancelPausedRunwayRefresh()
        isPlaying = true
        isBuffering = false
        resetFlowGapTracking()
        updatePiPPlaybackState()
        onEvent?(.playing)
        startAudioRenderIfNeeded(reconcileAuthorizedOutput: true)
        applyPipelineDemand()
        startSupplyLoop()
        scheduleAudioDecodeIfNeeded()
        return true
    }

    func pause() {
        let wasSeekingAtEntry = isSeekInFlight
        revokeAudioMaintenancePermission()
        helperTelemetry.invalidateKeepingValue()
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        if !isVideoLaneWarmSuspended {
            activeVideoSuspendToken = nil
        }
        if isSeekInFlight {
            generation &+= 1
            if let token = activeSeekToken {
                audioRender.abortSeekTransition(token)
            }
            discardSeekPreparedContent()
            clearSeekTransaction()
        }
        audioEOFDrain.reset()
        isPlaying = false
        isBuffering = false
        resetVideoLivenessState(resetStartup: false)
        resetFlowGapTracking()
        updatePiPPlaybackState()
        disarmPresentFeed()
        applyDisplayPlayback(rate: 0)
        if isReady, videoDecoderOpened, !hasEmittedEnded, !wasSeekingAtEntry,
           pausedCaptureSeekPreparationReceipt == nil,
           !isVideoLaneWarmSuspended, !isPreparingWarmVideoLane,
           !hasObservedPiPLease {
            (videoRender as? SampleBufferVideoRenderer)?.capturePausedPresentationImage()
        }
        if wasSeekingAtEntry {
            audioRender.stop()
        } else {
            audioRender.pause()
        }
        cancelSupplyLoop()
        cancelDecode()
        onEvent?(.paused)
        startPausedRunwayRefreshIfNeeded()
    }

    func parkForReuse() -> Bool {
        guard isReady, !isSeekInFlight, !hasEmittedEnded,
              !isVideoLaneWarmSuspended, !isPreparingWarmVideoLane,
              activeWarmVideoImageHold == nil,
              runtimeFaultedGeneration == nil else {
            return false
        }
        helperTelemetry.invalidate(.parked)
        multiConnectionQuietGate.setParked(true)
        isPlaying = false
        isBuffering = false
        resetVideoLivenessState(resetStartup: false)
        resetFlowGapTracking()
        updatePiPPlaybackState()
        disarmPresentFeed()
        applyDisplayPlayback(rate: 0)
        audioRender.pause()
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        cancelDecode()
        let parkedGeneration = generation
        nextLifecycleOperationID &+= 1
        let operationID = nextLifecycleOperationID
        let predecessor = lifecycleSerialTask
        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.finishLifecycleOperation(operationID, isOpen: false) }
            guard self.isCurrentGeneration(parkedGeneration),
                  !self.isPlaying else { return }
            await self.demux.retireLiveStreams()
        }
        lifecycleOperationID = operationID
        lifecycleSerialTask = operation
        return true
    }

    func adoptOwnerGeneration(_ generation: UInt64) {
        pausedCaptureSeekPreparationReceipt = nil
        (videoRender as? SampleBufferVideoRenderer)?.retireNonWarmPresentationImage()
        revokeAudioMaintenancePermission()
        let releasedImageHold = activeWarmVideoImageHold != nil
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        if releasedImageHold {
            clearVideoTrackQueues()
            resetCachedRunway(video: true, audio: false)
            videoRender.flush()
            if !isVideoLaneWarmSuspended {
                activeVideoSuspendToken = nil
            }
        }
        activeOwnerGeneration = generation
        if releasedImageHold { requestSupplyWake() }
    }

    func stop() {
        pausedCaptureSeekPreparationReceipt = nil
        helperTelemetry.invalidate(.parked)
        multiConnectionQuietGate.setParked(true)
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        cancelDecode()
        disarmPresentFeed()
        clearPiPEventSource()
        pendingPiPPresentationSnapshot = nil
        activeOpenTask?.cancel()
        activeOpenTask = nil
        generation &+= 1
        activeOwnerGeneration = 0
        activeStartupTraceToken = nil
        runtimeFaultedGeneration = nil
        publishedRuntimeFaultGeneration = nil
        clearSeekTransaction()
        consecutiveVideoPresentErrorCount = 0
        retireCurrentVideoDecoderWithoutWaiting()
        stopPipeline(emitPaused: false)
        videoDecoderOpened = false
        audioDecoderOpened = false
        isBuffering = false
        hasEmittedEnded = false
        demuxReachedEOF = false
        audioEOFDrain.reset()
        resetSessionCounters()
        resetVideoContinuationState()
        resetVideoLivenessState(resetStartup: true)
        resetFlowGapTracking()
        resetOutputMediaFloor(to: 0)
        clearPendingVideoFrames()
        clearPendingPCM()
        subtitlePCMTap?.notifyDiscontinuity(reason: .sessionStopped, targetPTS: nil)
        enqueueResourceClose()
        videoRender.invalidate()
        clock.reset()
        clearDisplayOutputContinuity()
        isReady = false
    }

    private func resetSessionCounters() {
        holdsPassThroughVideo = false
        knownVideoFrameWidth = 0
        knownVideoFrameHeight = 0
        videoEnqueueCap = nil
        presentedVideoFrameCount = 0
        decodedVideoFrameCount = 0
        decodedVideoFPS = 0
        presentedVideoFPS = 0
        decodedAudioFrameCount = 0
        pulledAudioFrameCount = 0
        bytesRead = 0
        networkByteCounter = MediaNetworkByteCounter()
        totalVideoPacketsIngested = 0
        totalAudioPacketsIngested = 0
        totalVideoPacketsDequeued = 0
        totalVideoPacketsSubmitted = 0
        totalVideoInputContentSecondsConsumed = 0
        totalVideoOutputPTSAdvanced = false
    }

    private func closeEngineResources() async {
        await demux.close()
        retireCurrentVideoDecoderWithoutWaiting()
        await audioDecoder.close()
    }

    private func enqueueResourceClose() {
        nextLifecycleOperationID &+= 1
        let operationID = nextLifecycleOperationID
        let predecessor = lifecycleSerialTask
        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.finishLifecycleOperation(operationID, isOpen: false) }
            await self.closeEngineResources()
        }
        lifecycleOperationID = operationID
        lifecycleSerialTask = operation
    }

    private func finishLifecycleOperation(_ operationID: UInt64, isOpen: Bool) {
        guard lifecycleOperationID == operationID else { return }
        lifecycleOperationID = nil
        lifecycleSerialTask = nil
        if isOpen {
            activeOpenTask = nil
        }
    }

    func isCurrentGeneration(_ gen: Int) -> Bool {
        gen == generation && runtimeFaultedGeneration != gen
    }

    static func isExpectedCancelledPumpExit(
        _ error: MediaEngineError,
        taskWasCancelled: Bool
    ) -> Bool {
        guard taskWasCancelled else { return false }
        if case .stopped = error { return true }
        return false
    }

    func publishRuntimeFault(
        _ fault: MediaRuntimeFault,
        generation gen: Int,
        mayBeLocalPresentationDebt: Bool = true
    ) {
        guard gen == generation,
              publishedRuntimeFaultGeneration != gen else { return }
        if let orphanedEngineGeneration = warmPreparationTransaction.orphan?.engineGeneration,
           orphanedEngineGeneration == gen {
            return
        }
        let isLocalSuspendedVideoFault = mayBeLocalPresentationDebt && DemandVideoFaultLocalityPolicy
            .isLocalPresentationDebt(
                subsystem: fault.subsystem,
                videoLaneIsWarmSuspended: isVideoLaneWarmSuspended,
                hasObservedPiPLease: hasObservedPiPLease,
                appIsBackgrounded: videoLivenessContext?.appState == .background
            )
        if isLocalSuspendedVideoFault {
            guard suspendedVideoFault == nil else { return }
            let owningWarmAttempt = warmVideoPreparationLedger.currentAttempt.flatMap {
                isPreparingWarmVideoLane && isCurrentWarmVideoPreparationAttempt($0) ? $0 : nil
            }
            suspendedVideoFault = fault
            cancelVideoDecode(clearHandle: false)
            if fault.subsystem == .videoDecoder {
                videoDecoderOpened = false
                videoDecoderRepairAttempted = false
                diagnostics.log(
                    "[PathA][continuation] video decoder closed under PiP lease " +
                        "vbuf=n/a queued=\(videoPackets.count) " +
                        "pending=\(pendingVideoFrames.count) source-reopen=0"
                )
            }
            if let attempt = owningWarmAttempt {
                diagnostics.log(
                    "[PathA][continuation] warm attempt fault " +
                    "token=\(attempt.token.generation) attempt=\(attempt.id) " +
                    "stage=\(fault.stage.rawValue) " +
                    "class=\(fault.classification.rawValue)"
                )
                return
            }
            let stamped = fault.stamped(
                sessionGeneration: UInt64(max(0, gen)),
                ownerGeneration: activeOwnerGeneration
            )
            diagnostics.log(
                "[PathA][continuation] suspended video debt " +
                "stage=\(stamped.stage.rawValue) class=\(stamped.classification.rawValue) " +
                "session=\(stamped.sessionGeneration)"
            )
            onEvent?(.runtimeFault(stamped))
            return
        }
        let pictureHandoff: RuntimeFaultPictureHandoff? =
            mayBeLocalPresentationDebt && isReady && activeOwnerGeneration != 0
                && (fault.subsystem == .videoDecoder || fault.subsystem == .videoRenderer)
                && fault.recoverability.isAutomatic
                && !isSeekInFlight && pausedCaptureSeekPreparationReceipt == nil
                && !isVideoLaneWarmSuspended && !isPreparingWarmVideoLane
                && !hasObservedPiPLease ? .currentVideoFault : nil
        publishedRuntimeFaultGeneration = gen
        runtimeFaultedGeneration = gen
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        cancelDecode()
        disarmPresentFeed()
        isPlaying = false
        isBuffering = false
        isReady = false
        stopPipeline(emitPaused: false, pictureHandoff: pictureHandoff)
        let stamped = fault.stamped(
            sessionGeneration: UInt64(max(0, gen)),
            ownerGeneration: activeOwnerGeneration
        )
        diagnostics.log(
            "[PathA] runtime fault subsystem=\(stamped.subsystem.rawValue) " +
            "stage=\(stamped.stage.rawValue) class=\(stamped.classification.rawValue) " +
            "recovery=\(stamped.recoverability.rawValue) " +
            "session=\(stamped.sessionGeneration) owner=\(stamped.ownerGeneration) " +
            stamped.diagnostics.summary
        )
        onEvent?(.runtimeFault(stamped))
    }

    var hasLocalPresentationFault: Bool {
        suspendedVideoFault != nil
            && runtimeFaultedGeneration == nil
            && isReady
            && (isPlaying || isVideoLaneWarmSuspended)
    }

    func setScaleMode(_ mode: VideoScaleMode) {
        videoRender.setScaleMode(mode)
    }

    func setPresentationCornerRadius(_ radius: CGFloat) {
        videoRender.setPresentationCornerRadius(radius)
    }

    func setAudioVolume(_ volume: Float) {
        audioRender.volume = max(0, min(volume, 1))
    }

    func setAudioMuted(_ muted: Bool) {
        audioRender.isMuted = muted
    }

    func setSubtitlePCMTap(_ tap: AudioPCMSubtitleTap?) {
        if let previous = subtitlePCMTap, previous !== tap {
            previous.setOnStreamActivated(nil)
        }
        subtitlePCMTap = tap
        guard let tap else { return }
        tap.setOnStreamActivated { [weak supply = audioTimelineBuffer] activatedTap in
            guard let supply else { return }
            let chunks = supply.snapshotUnreadMonoChunks(maxSeconds: 12.0)
            if !chunks.isEmpty {
                activatedTap.seedChunks(chunks)
            }
        }
        if tap.isActive {
            let chunks = audioTimelineBuffer.snapshotUnreadMonoChunks(maxSeconds: 12.0)
            if !chunks.isEmpty {
                tap.seedChunks(chunks)
            }
        }
    }

    var audioOutputAvailability: MediaAudioOutputAvailability { audioRender.outputAvailability }

    func setAudioOutputStateChangeHandler(_ handler: (@MainActor () -> Void)?) {
        audioOutputStateChangeHandler = handler
    }

    func reconcileAudioOutputForAuthorizedPlayback() -> Bool {
        guard isReady, isPlaying, !hasEmittedEnded,
              runtimeFaultedGeneration != generation,
              !isSeekInFlight, activeSeekToken == nil, preparedSeek == nil else { return false }
        startAudioRenderIfNeeded(reconcileAuthorizedOutput: true)
        return true
    }

    private func audioOutputStateDidChange() {
        audioOutputStateChangeHandler?()
        guard isReady, !hasEmittedEnded,
              runtimeFaultedGeneration != generation,
              !isSeekInFlight, activeSeekToken == nil, preparedSeek == nil,
              !isVideoLaneWarmSuspended, !isPreparingWarmVideoLane else { return }
        let rate = effectiveDisplayRate
        applyDisplayPlayback(rate: rate)
        if rate > 0, effectiveDisplayRate > 0 { presentDueVideoFrames() }
    }

    private enum RuntimeFaultPictureHandoff {
        case currentVideoFault
    }

    private func stopPipeline(
        emitPaused: Bool,
        pictureHandoff: RuntimeFaultPictureHandoff? = nil
    ) {
        revokeAudioMaintenancePermission()
        helperTelemetry.invalidate(.parked)
        multiConnectionQuietGate.setParked(true)
        isPlaying = false
        isBuffering = false
        audioEOFDrain.reset()
        consecutiveVideoPresentErrorCount = 0
        disarmPresentFeed()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        audioRender.stop()
        if case .currentVideoFault? = pictureHandoff,
           let renderer = videoRender as? SampleBufferVideoRenderer {
            renderer.flushForRuntimeFaultPictureHandoff()
        } else {
            videoRender.flush()
        }
        audioRender.flush()
        clearPacketBuffers()
        clearPendingVideoFrames()
        clearPendingPCM()
        subtitlePCMTap?.notifyDiscontinuity(reason: .sessionStopped, targetPTS: nil)
        if emitPaused {
            onEvent?(.paused)
        }
    }
}

struct PacketRingBuffer: Sequence, ExpressibleByArrayLiteral {
    private var storage: [MediaPacket?] = []
    private var head: Int = 0
    private(set) var count: Int = 0

    init() {}

    init(arrayLiteral elements: MediaPacket...) {
        guard !elements.isEmpty else { return }
        var capacity = 16
        while capacity < elements.count {
            capacity &<<= 1
        }
        storage = [MediaPacket?](repeating: nil, count: capacity)
        for (index, element) in elements.enumerated() {
            storage[index] = element
        }
        count = elements.count
    }

    var isEmpty: Bool { count == 0 }
    var underestimatedCount: Int { count }
    var first: MediaPacket? { count > 0 ? storage[head] : nil }

    mutating func append(_ packet: MediaPacket) {
        if count == storage.count {
            grow()
        }
        storage[(head + count) & (storage.count - 1)] = packet
        count += 1
    }

    @discardableResult
    mutating func removeFirst() -> MediaPacket {
        precondition(count > 0, "Cannot removeFirst from empty PacketRingBuffer")
        let packet = storage[head]!
        storage[head] = nil
        head = (head + 1) & (storage.count - 1)
        count -= 1
        if count == 0 {
            head = 0
        }
        return packet
    }

    private mutating func grow() {
        let oldCapacity = storage.count
        let newCapacity = Swift.max(16, oldCapacity * 2)
        var newStorage = [MediaPacket?](repeating: nil, count: newCapacity)
        if count > 0 {
            let mask = oldCapacity - 1
            for i in 0..<count {
                newStorage[i] = storage[(head + i) & mask]
            }
        }
        storage = newStorage
        head = 0
    }

    struct Iterator: IteratorProtocol {
        private let storage: [MediaPacket?]
        private let mask: Int
        private var index: Int
        private var remaining: Int

        fileprivate init(storage: [MediaPacket?], head: Int, count: Int) {
            self.storage = storage
            self.mask = storage.count - 1
            self.index = head
            self.remaining = count
        }

        mutating func next() -> MediaPacket? {
            guard remaining > 0 else { return nil }
            let element = storage[index]
            index = (index + 1) & mask
            remaining -= 1
            return element
        }
    }

    func makeIterator() -> Iterator {
        Iterator(storage: storage, head: head, count: count)
    }
}

/// Fixed-capacity O(1) rolling window for recent `TimeInterval` samples (avoids O(N) Array.removeFirst shifts).
struct RollingTimeIntervalWindow {
    private static let capacity = 32
    private var storage: [TimeInterval] = []
    private var writeIndex = 0

    var count: Int { storage.count }

    mutating func append(_ value: TimeInterval) {
        if storage.count < Self.capacity {
            if storage.isEmpty {
                storage.reserveCapacity(Self.capacity)
            }
            storage.append(value)
        } else {
            storage[writeIndex] = value
            writeIndex = (writeIndex + 1) & (Self.capacity - 1)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        writeIndex = 0
    }

    func appendPositiveFinite(into target: inout [TimeInterval]) {
        for value in storage where value.isFinite && value > 0 {
            target.append(value)
        }
    }
}
