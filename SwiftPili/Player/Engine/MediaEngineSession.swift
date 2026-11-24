import CoreVideo
import Foundation
import UIKit

@MainActor
final class EnginePiPSeekRequest {
    let interval: TimeInterval
    let ownerGeneration: UInt64
    private let currentAdmission: @MainActor @Sendable () -> Bool
    private let settlement: @MainActor @Sendable (Bool) -> Void
    private var didSettle = false

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
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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

private struct FlowGapStage {
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
    private var videoPresentLeadSeconds: TimeInterval {
        (videoRender as? SampleBufferVideoRenderer)?.preferredPresentLeadSeconds ?? 0.3
    }
    private var videoFrameQueueHighWater: TimeInterval { max(0.4, videoPresentLeadSeconds + 0.15) }
    private let displayResyncEpsilonSeconds: TimeInterval = 0.25
    private let displayDriftResyncSeconds: TimeInterval = 0.08
    private var lastDisplayResyncPresentationTime: TimeInterval = -1
    private var lastDisplayPresentationOffset: TimeInterval?
    private var lastDisplayPinGeneration: Int?
    private var audioOutputDisplayHold: (generation: Int, time: TimeInterval)?

    var onEvent: (@MainActor @Sendable (MediaSessionEvent) -> Void)?
    private var audioOutputStateChangeHandler: (@MainActor () -> Void)?
    var onPresentationFailure:
        (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    var onPiPTransportEvent:
        (@MainActor @Sendable (EnginePiPTransportEvent) -> Void)?
    var onPiPSkipRequest: (@MainActor @Sendable (EnginePiPSeekRequest) -> Void)?

    private let diagnostics: any MediaEngineDiagnostics
    private let tracing: any MediaEngineTracing
    private let demux: any MediaDemuxing
    private let warmVideoPreparationDeadline: Duration
    private var videoDecoder: any MediaVideoDecoding
    private let videoDecoderFactory: (@MainActor @Sendable () -> any MediaVideoDecoding)?
    private var videoDecoderWasRetired = false
    private var videoDecoderHasNativeSession = false
    private var videoDecoderFactoryInvocationCount = 0
    private var videoDecoderRepairTask: Task<Bool, Never>?
    private var nextVideoDecoderRepairID: UInt64 = 0
    private var activeVideoDecoderRepairID: UInt64?
    private var videoDecoderRepairAttempted = false
    private var pipVideoResumeTask: Task<Bool, Never>?
    private var nextPiPVideoResumeID: UInt64 = 0
    private var activePiPVideoResumeID: UInt64?
    private static let maxOutstandingVideoDecoderRetirements = 2
    private var outstandingVideoDecoderRetirements: [ObjectIdentifier: UInt64] = [:]
    private var nextVideoDecoderRetirementID: UInt64 = 0
    private(set) var videoDecoderRetirementAdmissionFailureCount = 0
    private(set) var videoDecoderRetirementCompletionCount = 0
    private struct VideoDecoderOpeningState {
        let decoder: any MediaVideoDecoding
        var retirementNeeded = false
        var retirementRequested = false
        var openCompleted = false
    }
    private var openingVideoDecoders: [ObjectIdentifier: VideoDecoderOpeningState] = [:]
    private let audioDecoder: any MediaAudioDecoding
    private let videoRender: any MediaVideoPresentation
    private let audioRender: any MediaAudioRendering

    private var clock = MediaClock()
    private var pausedRunwayRefreshTask: Task<Void, Never>?
    private var nextPausedRunwayRefreshID: UInt64 = 0
    private var activePausedRunwayRefreshID: UInt64?
    private var videoPacketQueue = ContentSecondQueue(highWater: 20, lowWater: 4)
    private var audioPacketQueue = ContentSecondQueue(highWater: 20, lowWater: 4)
    private var videoPackets = PacketRingBuffer()
    private var audioPackets = PacketRingBuffer()
    private var residualVideoPackets = PacketRingBuffer()
    private var residualAudioPackets = PacketRingBuffer()
    private var suspendedVideoGOP: [MediaPacket] = []
    private var suspendedVideoGOPContentSeconds: TimeInterval = 0
    private var suspendedVideoGOPBytes = 0
    private var suspendedVideoGOPProvenance: DemandVideoCandidateProvenance?
    private var suspendedVideoSupplyMemorySuppressed = false
    private var nextVideoReadGeneration: UInt64 = 0
    private var videoReadBytes = 0
    private static let suspendedVideoGOPMaxContentSeconds: TimeInterval = 8
    private static let suspendedVideoGOPMaxBytes = 16 * 1024 * 1024
    private static let suspendedVideoWindowMaxContentSeconds: TimeInterval = 16
    private static let suspendedVideoWindowMaxBytes = 48 * 1024 * 1024
    private static let videoContinuityAnchorToleranceSeconds: TimeInterval = 0.05
    private var isCollectingWarmVideoRunUp = false
    private var nextVideoContinuityCandidateGeneration: UInt64 = 0
    private var warmVideoCandidateAuthorities: [MediaVideoContinuityCandidateAuthority] = []
    enum WarmVideoCandidateDisposition: Equatable, Sendable {
        case bracketingPreRoll
        case nearFutureImageHold(notBeforePTS: TimeInterval)
        case positionedFutureImageHold(MediaVideoForwardReceipt)
        case requiresPositioning

        fileprivate var futureNotBeforePTS: TimeInterval? {
            switch self {
            case .nearFutureImageHold(let value): value
            case .positionedFutureImageHold(let receipt): receipt.anchorPTS
            case .bracketingPreRoll, .requiresPositioning: nil
            }
        }

        fileprivate var diagnosticName: String {
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

    private static let suspendedVideoTargetAheadSeconds: TimeInterval = 1.0
    private var activeWarmVideoImageHold: WarmVideoImageHoldSnapshot?
    private var warmVideoImageHoldRefreshTask: Task<Void, Never>?
    private var nextWarmVideoImageHoldRefreshID: UInt64 = 0
    private var activeWarmVideoImageHoldRefreshID: UInt64?
    private var playbackRateRevision: UInt64 = 0
    private var videoContinuationGeneration: UInt64 = 0
    private var activeVideoSuspendToken: DemandVideoSuspendToken?
    private var isVideoLaneWarmSuspended = false {
        didSet { if isVideoLaneWarmSuspended { invalidateSourceWaitBudget() } }
    }
    private var isVideoLanePreparedForForeground = false
    private var isPreparingWarmVideoLane = false {
        didSet { if isPreparingWarmVideoLane { invalidateSourceWaitBudget() } }
    }
    private var videoDecodeLaneOwners = 0
    private let directVideoDecodeLane = DecodeLaneGate()
    private var audioDecodeLaneOwners = 0
    private let directAudioDecodeLane = DecodeLaneGate()
    private let warmPreparationTransaction: WarmPreparationTransaction
    private var isDecodingWarmVideoCandidate = false
    private var suspendedVideoFault: MediaRuntimeFault?
    private var terminalVideoPreparationFailure: DemandPresentationFailure?
    private var warmVideoPreparationLedger = WarmVideoPreparationLedger()
    private var warmVideoSubmissionsWithoutOutput = 0
    private var videoContinuityTopology: MediaVideoContinuityTopology = .unsupported
    private static let warmVideoDecoderRepairLimit = 1
    private static let warmVideoNoOutputSubmissionLimit = 64
    private static let warmVideoDirectContentSpanLimit: TimeInterval = 12
    private static let warmVideoDirectWallLimit: Duration = .seconds(5)
    private static let warmVideoDirectNoProgressLimit = 3
    private static let defaultWarmVideoPreparationDeadline: Duration = .seconds(5)

    private typealias WarmVideoPreparationRun = WarmVideoPreparationRunLedger.Run

    private typealias WarmVideoPreparationAttempt = WarmVideoPreparationLedger.Attempt

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

    private struct WarmVideoDecoderTimingOwner {
        let runID: UInt64
        var observation: WarmVideoDecoderTimingObservation
        var reporter: (any MediaVideoDecodeTimingReporting)?
    }

    private var activeWarmDiagnostics: WarmVideoPreparationDiagnosticsState?
    private var lastWarmVideoPreparationDiagnostics: WarmVideoPreparationDiagnostics?
    private struct WarmDiagnosticProofIdentity {
        let run: WarmVideoPreparationRun
        let attemptID: UInt64?
        let preparedAt: ContinuousClock.Instant
        var renderGeneration: Int?
        var floor: TimeInterval
    }
    private var warmDiagnosticProofIdentity: WarmDiagnosticProofIdentity?

    private struct WarmVideoPreparationDiagnosticsState {
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

    private func bindWarmDecoderTiming(run: WarmVideoPreparationRun) {
        guard warmPreparationTransaction.currentRun == run,
              activeWarmDiagnostics?.runID == run.id,
              activeVideoSuspendToken == run.token,
              runtimeGeneration == run.sessionGeneration,
              generation == run.engineGeneration,
              activeOwnerGeneration == run.ownerGeneration else { return }
        let identity = ObjectIdentifier(videoDecoder)
        if activeWarmDiagnostics?.decoderTimingOwner?.observation.decoderIdentity == identity {
            return
        }
        let segmentID = (activeWarmDiagnostics?.decoderTimingOwner?.observation.segmentID ?? 0) + 1
        freezeWarmDecoderTiming(runID: run.id)
        let reporter = videoDecoder as? any MediaVideoDecodeTimingReporting
        reporter?.setDecodeTimingEnabled(true)
        let selectionAttemptID = activeWarmDiagnostics?.attemptID
        activeWarmDiagnostics?.decoderTimingOwner = WarmVideoDecoderTimingOwner(
            runID: run.id,
            observation: WarmVideoDecoderTimingObservation(
                segmentID: segmentID,
                selectionAttemptID: selectionAttemptID,
                decoderIdentity: identity
            ),
            reporter: reporter
        )
    }

    private func freezeWarmDecoderTiming(runID: UInt64, decoderIdentity: ObjectIdentifier? = nil) {
        guard var state = activeWarmDiagnostics, state.runID == runID,
              var owner = state.decoderTimingOwner, owner.runID == runID,
              decoderIdentity == nil || decoderIdentity == owner.observation.decoderIdentity,
              let reporter = owner.reporter else { return }
        owner.observation.snapshot = reporter.decodeTimingSnapshot()
        reporter.setDecodeTimingEnabled(false)
        owner.reporter = nil
        state.decoderTimingOwner = owner
        activeWarmDiagnostics = state
    }

    private func freezeRetiringWarmDecoderTiming(_ identity: ObjectIdentifier) {
        guard let runID = activeWarmDiagnostics?.runID else { return }
        freezeWarmDecoderTiming(runID: runID, decoderIdentity: identity)
    }

    private func warmDiagnosticPhase(_ phase: String) {
        guard var state = activeWarmDiagnostics else { return }
        if state.phases.count < 32 { state.phases.append(phase) }
        activeWarmDiagnostics = state
    }

    private func warmPreparationAttemptIsActive(runID: UInt64) -> Bool {
        activeWarmDiagnostics?.runID == runID
            && warmPreparationTransaction.currentRun?.id == runID
    }

    private func warmDiagnosticAttemptIsCurrent(_ attempt: WarmVideoPreparationAttempt?) -> Bool {
        guard let attempt else { return false }
        return isCurrentWarmVideoPreparationAttempt(attempt)
            && activeWarmDiagnostics?.runID == attempt.runID
            && activeWarmDiagnostics?.attemptID == attempt.id
    }

    static func warmDiagnosticMilliseconds(_ duration: Duration) -> Int {
        max(0, Int(duration / .milliseconds(1)))
    }

    private func warmDiagnosticElapsedMs(
        _ start: ContinuousClock.Instant,
        _ end: ContinuousClock.Instant = ContinuousClock.now
    ) -> Int {
        Self.warmDiagnosticMilliseconds(start.duration(to: end))
    }

    private func finishWarmDiagnostics(
        run: WarmVideoPreparationRun,
        result: DemandVideoLanePreparationResult
    ) {
        guard activeWarmDiagnostics?.runID == run.id else { return }
        freezeWarmDecoderTiming(runID: run.id)
        guard let state = activeWarmDiagnostics else { return }
        let now = ContinuousClock.now
        let outcome = String(describing: result)
        let decoderTiming = state.decoderTimingOwner?.observation
        let diagnostic = WarmVideoPreparationDiagnostics(
            runID: state.runID, target: state.target, phases: state.phases,
            decoderOpenMs: Self.warmDiagnosticMilliseconds(state.decoderOpenTime),
            firstDecodeAwaitMs: state.firstDecodeAwaitMs,
            totalDecodeWallMs: Self.warmDiagnosticMilliseconds(state.totalDecodeTime),
            decodedFrames: state.decodedFrames,
            prerollFramesDropped: state.prerollFramesDropped,
            targetFramesBanked: state.targetFramesBanked,
            decodeBursts: state.decodeBursts,
            demuxWaitMs: Self.warmDiagnosticMilliseconds(state.demuxWaitTime),
            schedulingWaitMs: Self.warmDiagnosticMilliseconds(state.schedulingWaitTime),
            presentationProofCallbackMs: nil, preparedToProofMs: nil,
            firstOutputMs: state.firstOutputMs,
            initialFloorDrops: state.initialFloorDrops,
            movingFloorDrops: state.movingFloorDrops,
            pumps: state.pumps, submittedPackets: state.submittedPackets,
            finalTarget: outputMediaFloor,
            totalPreparationMs: warmDiagnosticElapsedMs(state.startedAt, now),
            attemptID: state.attemptID, outcome: outcome,
            beforeDecoderOpenMs: state.beforeDecoderOpenMs,
            bankedFramesExpired: state.bankedFramesExpired,
            quiesceWaitMs: Self.warmDiagnosticMilliseconds(state.quiesceWaitTime),
            decoderTiming: decoderTiming
        )
        lastWarmVideoPreparationDiagnostics = diagnostic
        warmDiagnosticProofIdentity = result == .prepared ? .init(
            run: run, attemptID: state.attemptID, preparedAt: now,
            floor: outputMediaFloor
        ) : nil
        diagnostics.log(
            "[PathA][continuation] warm diagnostics " +
            "run=\(state.runID) attempt=\(state.attemptID ?? 0) outcome=\(outcome) " +
            "target=\(String(format: "%.3f", state.target)) finalTarget=\(String(format: "%.3f", outputMediaFloor)) " +
            "totalMs=\(diagnostic.totalPreparationMs) phases=\(state.phases.joined(separator: ",")) " +
            "decoderOpenMs=\(diagnostic.decoderOpenMs) firstDecodeAwaitMs=\(state.firstDecodeAwaitMs ?? -1) " +
            "firstOutputMs=\(state.firstOutputMs ?? -1) decodeAwaitMs=\(diagnostic.totalDecodeWallMs) " +
            "submitted=\(state.submittedPackets) decoded=\(state.decodedFrames) " +
            "initialFloorDrops=\(state.initialFloorDrops) movingFloorDrops=\(state.movingFloorDrops) " +
            "prerollDropped=\(state.prerollFramesDropped) banked=\(state.targetFramesBanked) " +
            "bursts=\(state.decodeBursts) pumps=\(state.pumps) demuxAwaitMs=\(diagnostic.demuxWaitMs) " +
            "laneAwaitMs=\(diagnostic.schedulingWaitMs) quiesceAwaitMs=\(diagnostic.quiesceWaitMs) " +
            "beforeDecoderOpenMs=\(state.beforeDecoderOpenMs ?? -1) bankedExpired=\(state.bankedFramesExpired)"
        )
        if let decoderTiming {
            diagnostics.log(
                "[PathA][continuation] warm decoder timings run=\(state.runID) " +
                "scope=selected-decoder-segment segment=\(decoderTiming.segmentID) " +
                "selectionAttempt=\(decoderTiming.selectionAttemptID ?? 0) " +
                "throughAttempt=\(state.attemptID ?? 0) " +
                (decoderTiming.snapshot?.logSummary ?? "timing=unavailable")
            )
        }
        activeWarmDiagnostics = nil
    }

    private func noteWarmPresentationProof(renderGeneration: Int, mediaTime: TimeInterval) {
        guard let identity = warmDiagnosticProofIdentity,
              identity.renderGeneration == renderGeneration,
              identity.run.sessionGeneration == runtimeGeneration,
              identity.run.engineGeneration == generation,
              identity.run.ownerGeneration == activeOwnerGeneration,
              !isVideoLaneWarmSuspended,
              mediaTime.isFinite, mediaTime >= identity.floor,
              var diagnostic = lastWarmVideoPreparationDiagnostics,
              diagnostic.runID == identity.run.id,
              diagnostic.attemptID == identity.attemptID else { return }
        let now = ContinuousClock.now
        diagnostic.presentationProofCallbackMs = warmDiagnosticElapsedMs(identity.run.startedAt, now)
        diagnostic.preparedToProofMs = warmDiagnosticElapsedMs(identity.preparedAt, now)
        if diagnostic.phases.count < 32 { diagnostic.phases.append("presentation-proof") }
        lastWarmVideoPreparationDiagnostics = diagnostic
        warmDiagnosticProofIdentity = nil
        diagnostics.log(
            "[PathA][continuation] warm proof run=\(diagnostic.runID) " +
            "attempt=\(identity.attemptID ?? 0) render=\(renderGeneration) " +
            "preparedToProofMs=\(diagnostic.preparedToProofMs ?? -1) " +
            "totalMs=\(diagnostic.presentationProofCallbackMs ?? -1)"
        )
    }
    private let nominalZeroDurationVideoSeconds: TimeInterval = 1.0 / 30.0
    private let nominalZeroDurationAudioSeconds: TimeInterval = 1024.0 / 48_000.0
    private(set) var zeroDurationPacketsNormalized = 0
    private var pendingVideoFrames: [MediaVideoFrame] = []
    private var pendingVideoContentSeconds: TimeInterval = 0
    private let audioTimelineBuffer = AudioTimelinePCMSupply(
        defaultSampleRate: EnginePCM.sampleRate,
        defaultChannels: EnginePCM.channelCount,
        timelineEpsilon: EnginePCM.aacOutputQuantumSeconds
    )

    nonisolated var audioSupply: any AudioSupplySource { audioTimelineBuffer }
    private var hasAudioTrack = false
    private var supplyLoopTask: Task<Void, Never>?
    private var supplyLoopStartCount = 0
    private var supplyLoopWake: CheckedContinuation<Void, Never>?
    private var supplyLoopWakePending = false
    private var isFillingQueues = false
    private var nextQueueFillTraceID: UInt64 = 0
    private var lastFillProducedPackets = false
    private var decodeTask: Task<Void, Never>?
    private var audioDecodeTask: Task<Void, Never>?
    private var nextVideoDecodeOperationID: UInt64 = 0
    private var activeVideoDecodeOperationID: UInt64?
    private var nextAudioDecodeOperationID: UInt64 = 0
    private var activeAudioDecodeOperationID: UInt64?
    private var lifecycleSerialTask: Task<Void, Never>?
    private var lifecycleOperationID: UInt64?
    private var activeOpenTask: Task<Void, Never>?
    private var nextLifecycleOperationID: UInt64 = 0
    private var generation = 0 {
        didSet {
            audioRender.revokeAudioMaintenancePermission()
            invalidateSourceWaitBudget()
            usefulPrimarySamples.removeAll()
            unresolvedPrimaryTransportFailure = nil
            renderedAudioOutput = nil
        }
    }
    private var demuxOpenCount = 0
    private var seekFirstPacketLogged = true
    private struct PiPEventBindingToken: Equatable, Sendable {
        let generation: UInt64
    }

    private var nextPiPEventBindingGeneration: UInt64 = 0
    private var activePiPEventBindingToken: PiPEventBindingToken?
    private(set) var isAutomaticPiPEnabled = false
    private var activeOwnerGeneration: UInt64 = 0
    private var activeStartupTraceToken: MediaEngineTraceID?
    private var runtimeFaultedGeneration: Int?
    private var publishedRuntimeFaultGeneration: Int?
    private var observedPiPLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var pipNativeTransitionHandler: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    private var pipRestoreRequestHandler: (@MainActor @Sendable (UInt64) -> Void)?
    private var nextPiPTransportOperationID: UInt64 = 0
    private struct PiPPresentationContinuitySnapshot: Equatable {
        let sessionGeneration: UInt64
        let ownerGeneration: UInt64
        let bindingGeneration: UInt64
        let mediaTime: TimeInterval
        let displayClockSeconds: TimeInterval
        let videoDecoderOpened: Bool
        let presentationProgress: DemandPresentationProgressWitness
        let rendererHealth: DemandPresentationHealth
    }

    private var pendingPiPPresentationSnapshot: PiPPresentationContinuitySnapshot?
    private var presentationProofHandler: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    private(set) var hasObservedPiPLease = false
    private var videoDecoderOpened = false
    private var audioDecoderOpened = false
    private var lastVideoDecoderOpenError: String?
    private var lastAudioDecoderOpenError: String?
    private var lastAudioDecodeError: String?
    private var lastAudioDecodeDiagnostics = MediaAudioDecodeDiagnostics.unavailable
    private var audioDecodePacketsSubmitted = 0
    private var audioDecodePCMFramesProduced = 0
    private let videoDecodeBurstLimit = 8
    private let audioDecodeBurstLimit = 64
    private static let audioPrimeNoPCMProgressBurstLimit = 4
    private let audioPCMTargetSeconds: TimeInterval = 4
    private let primeVideoContentBudget: TimeInterval = 0.5
    private let runtimePassThroughVideoContentHWM: TimeInterval = 1.0
    private let minTrackFillRoom: TimeInterval = 0.05
    private let supplyLowWaterFraction: TimeInterval = 0.5
    private let supplyStallBackoffNanos: UInt64 = 20_000_000
    private let pumpCallBudgetCapSeconds: TimeInterval = 1.0

    // MARK: - incremental ingest

    private let packetRelay = DemuxPacketRelay()
    private var relayDrainCount = 0
    private var videoStarvedSince: ContinuousClock.Instant?
    private var bufferingForVideoStarvation = false
    private let videoPixelFrameBudgetBytes: Int = 120 * 1024 * 1024
    private let minPassThroughVideoPackets = 4
    private let maxPassThroughVideoPacketsAbsolute = 16
    private let defaultVideoFrameWidth = 1920
    private let defaultVideoFrameHeight = 1080
    private var knownVideoFrameWidth = 0
    private var knownVideoFrameHeight = 0
    private var holdsPassThroughVideo = false
    private var videoEnqueueCap: TimeInterval?
    private let primeProgressLogInterval: TimeInterval = 0.5
    private var isBuffering = false {
        didSet { if isBuffering { invalidateSourceWaitBudget() } }
    }
    private struct SessionSeekTransaction {
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

    private struct AudioEOFDrainState {
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

    private var hasEmittedEnded = false
    private var demuxReachedEOF = false
    private var audioEOFDrain = AudioEOFDrainState()
    private var audioDrainingToEnd: Bool { audioEOFDrain.isDraining }
    private var seekTransaction = SessionSeekTransaction()
    private var isSeekInFlight: Bool { seekTransaction.isInFlight }
    private var pausedCaptureSeekPreparationReceipt: UUID?
    private var activeSeekToken: MediaAudioSeekToken? { seekTransaction.activeToken }
    private var preparedSeek: MediaEngineSeekPreparation? { seekTransaction.prepared }
    private var consecutiveVideoPresentErrorCount = 0

    private func beginSeekTransaction(token: MediaAudioSeekToken) {
        seekTransaction.begin(token: token)
        invalidateSourceWaitBudget()
    }

    private func clearSeekTransaction() {
        seekTransaction.clear()
    }
    private var outputMediaFloor: TimeInterval = 0 {
        didSet {
            (videoRender as? SampleBufferVideoRenderer)?.updateDemandPresentationFloor(outputMediaFloor)
        }
    }
    private let outputMediaFloorEpsilon: TimeInterval = 1e-9
    private var videoDecodeFrontierPTS: TimeInterval?
    private var audioDecodeFrontierPTS: TimeInterval?

    private(set) var staleVideoOutputRejectionCount = 0
    private var staleVideoOutputRejectionMinPTS: TimeInterval?
    private var staleVideoOutputRejectionMaxPTS: TimeInterval?

    private(set) var isReady = false {
        didSet { if !isReady { invalidateSourceWaitBudget() } }
    }
    private(set) var isPlaying = false {
        didSet {
            if !isPlaying {
                invalidateSourceWaitBudget()
            }
        }
    }
    private var activeSourceWaitBudget: MediaSourceWaitBudget?
    private var sourceObservationEpoch: UInt64 = 1
    private struct UsefulPrimarySample {
        let acceptedAU: MediaSourceAcceptedAU
        let acceptedAt: TimeInterval
        let elapsed: TimeInterval
    }
    private var usefulPrimarySamples: [MediaTrackKind: [UsefulPrimarySample]] = [:]
    private(set) var presentedVideoFrameCount = 0
    private(set) var decodedVideoFrameCount = 0
    private var decodedVideoFPS: Double = 0
    private var presentedVideoFPS: Double = 0
    private(set) var droppedPrerollVideoFrameCount = 0

    // MARK: Seek / resume-open fast preroll (task 10-03-demand-seek-long-preroll)

    typealias VideoPrerollClassifierFactory = @Sendable (String?, Data) -> (any VideoPrerollSampleClassifying)?
    let seekFastPrerollEnabled: Bool
    private let videoPrerollClassifierFactory: VideoPrerollClassifierFactory
    private var videoPrerollClassifier: (any VideoPrerollSampleClassifying)?
    private var videoPrerollClassifierDecoder: ObjectIdentifier?
    private var videoPrerollCodec: String?
    private var prerollBatchingActive = false
    static let seekPrerollBatchLimit = 32
    private var activePrerollStats: SeekPrerollStats?
    private var activePrerollStatsGeneration: Int?
    private var prerollAnomalyBaseline: (decoder: ObjectIdentifier, counters: VideoDecodeAnomalyCounters)?
    private(set) var lastPrerollStats: SeekPrerollStats?
    private var seekPhaseStopwatch: SeekPhaseStopwatch?
    var pendingVideoFrameCount: Int { pendingVideoFrames.count }
    private(set) var decodedAudioFrameCount = 0
    private(set) var droppedPrerollAudioFrameCount = 0
    private(set) var trimmedPrerollAudioSampleFrameCount = 0
    private(set) var pulledAudioFrameCount = 0
    private var audioTimelineAdjustmentLogCount = 0
    private var audioDecodeTimingLogCount = 0
    private var videoLivenessContext: DemandVideoLivenessContext?
    private var videoLivenessDetector = DemandVideoSilentNoOutputDetector()
    private let videoLivenessPolicy = DemandVideoLivenessPolicy.provisional
    private var videoLivenessStartupUptime: TimeInterval = 0
    private var videoLivenessWindowIndex: UInt64 = 0
    private var videoLivenessPacketDurations: [TimeInterval] = []
    private var videoLivenessOutputPeriods: [TimeInterval] = []
    private var videoLivenessPTSProgress = DemandLivenessPTSProgress()
    private var pipeWindowVideoPacketsDequeued = 0
    private var pipeWindowVideoPacketsSubmitted = 0
    private var pipeWindowVideoInputSeconds = 0.0
    private var pipeWindowVideoBytesRead: Int64 = 0
    private var pipeWindowVideoPacketsIngested = 0
    private var pipeWindowVideoOutputFrames = 0
    private var pipeWindowVideoOutputPTSAdvanced = false
    private var pipeWindowVideoOutputPTSDelta: TimeInterval?
    private var pipeWindowVideoCallbacks = 0
    private var pipeWindowRendererAdmitted = 0
    private var pipeWindowRendererPTSAdvanced = false
    private var pipeWindowRendererBlocked = false
    private var pipeWindowRendererFailed = false
    var insertedAudioTimelineGapSampleFrameCount: Int {
        audioTimelineBuffer.insertedGapFrameCount
    }
    var droppedAudioTimelineOverlapSampleFrameCount: Int {
        audioTimelineBuffer.droppedOverlapFrameCount
    }
    private(set) var bytesRead: Int64 = 0
    private var networkByteCounter = MediaNetworkByteCounter()
    private(set) var totalVideoPacketsIngested = 0
    private(set) var totalAudioPacketsIngested = 0
    private(set) var totalVideoPacketsDequeued = 0
    private(set) var totalVideoPacketsSubmitted = 0
    private(set) var totalVideoInputContentSecondsConsumed: TimeInterval = 0
    private(set) var totalVideoOutputPTSAdvanced = false

    private var pipeWindowStartUptime: TimeInterval = 0
    private var pipeWindowStartMediaTime: TimeInterval = 0
    private var pipeWindowDecodeFrames = 0
    private var pipeWindowPresentFrames = 0
    private var pipeWindowPresentCalls = 0
    private var pipeWindowPumps = 0
    private var pipeWindowParks = 0
    private var pipeWindowWakes = 0
    private var pipeWindowNotDue = 0
    private var pipeWindowNotReady = 0

    private var pipeStickyFields: [String: String] = [:]
    private var pipeWindowIndex = 0
    private var wasCapturingLastWindow = false
    private var lastAudioCallbackCount = 0
    private var lastAudioRenderedFrameCount = 0

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

    private var flowIngestV = FlowGapStage()
    private var flowIngestA = FlowGapStage()
    private var flowDecInV = FlowGapStage()
    private var flowDecOutV = FlowGapStage()
    private var flowPresentV = FlowGapStage()
    private var flowClock = FlowGapStage()
    private var flowPCM = FlowGapStage()
    private var flowWindowMaxPacketAgeMs = 0
    private var flowWindowMaxDecodeMs = 0
    private var flowLastIngestVideoPTS: TimeInterval = -1
    private var flowLastIngestAudioPTS: TimeInterval = -1
    private var lastPresentBurstLogAt: TimeInterval = 0
    private let flowStallThresholdMs = 700

    private var usesAudioMasterForVideo: Bool {
        hasAudioTrack && audioDecoderOpened
    }

    var mediaTime: TimeInterval { clock.mediaTime }
    var runtimeGeneration: UInt64 { UInt64(max(0, generation)) }
    var duration: TimeInterval { clock.duration }
    private(set) var unresolvedPrimaryTransportFailure: StreamTransportFailure?
    private struct RenderedAudioOutput {
        let sessionGeneration: UInt64
        let ownerGeneration: UInt64
        let position: TimeInterval
    }
    private var renderedAudioOutput: RenderedAudioOutput?

    func renderedAudioOutputPosition(ownerGeneration: UInt64) -> TimeInterval? {
        guard isReady, isPlaying, !isSeekInFlight,
              audioRender.outputAvailability == .available,
              let output = renderedAudioOutput,
              output.sessionGeneration == runtimeGeneration, output.ownerGeneration == ownerGeneration,
              activeOwnerGeneration == ownerGeneration else { return nil }
        return output.position
    }

    private func transportEngineError(_ error: any Error, stage: StreamTransportFailure.Stage) -> MediaEngineError {
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
        guard supplyLoopTask != nil, !hasAudioTrack || audioRender.isRunning else {
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

    var bufferedTime: TimeInterval {
        resolvedBufferEndpoints(at: clock.mediaTime).bufferedThrough ?? clock.mediaTime
    }

    var bufferDisplaySample: MediaBufferDisplaySample? {
        let time = clock.mediaTime
        guard time.isFinite else { return nil }
        let resolved = resolvedBufferEndpoints(at: time)
        return MediaBufferDisplaySample(
            position: time,
            videoPresent: videoDecoderOpened,
            audioPresent: hasAudioTrack,
            videoWarmSuspended: isVideoLaneWarmSuspended,
            videoEnd: resolved.videoEnd,
            audioEnd: resolved.audioEnd,
            bufferedThrough: resolved.bufferedThrough
        )
    }

    private var tracksDrainedAtEOF: Bool {
        guard demuxReachedEOF else { return false }
        let videoDrained = !videoDecoderOpened || isVideoLaneWarmSuspended || (
            videoPacketQueue.contentSeconds <= 0
                && pendingVideoContentSeconds <= 0
                && cachedVideoRunwaySeconds <= 0
        )
        let audioDrained = !hasAudioTrack || (
            audioPacketQueue.contentSeconds <= 0
                && pendingAudioContentSeconds <= 0
                && cachedAudioRunwaySeconds <= 0
        )
        return videoDrained && audioDrained
    }

    private func resolvedBufferEndpoints(at time: TimeInterval) -> (
        videoEnd: TimeInterval?,
        audioEnd: TimeInterval?,
        bufferedThrough: TimeInterval?
    ) {
        guard time.isFinite else { return (nil, nil, nil) }
        var videoEnd = videoDeliveryRunway.map { time + $0 }
        var audioEnd = audioDeliveryRunway.map { time + $0 }
        let duration = clock.duration
        let hasFiniteDuration = duration.isFinite && duration > 0
        if demuxReachedEOF, hasFiniteDuration {
            if videoDecoderOpened, !isVideoLaneWarmSuspended,
               videoPacketQueue.contentSeconds <= 0,
               pendingVideoContentSeconds <= 0,
               cachedVideoRunwaySeconds <= 0,
               videoRender.enqueuedAheadSeconds(from: time) <= 0 {
                videoEnd = max(time, duration)
            }
            if hasAudioTrack,
               audioPacketQueue.contentSeconds <= 0,
               pendingAudioContentSeconds <= 0,
               cachedAudioRunwaySeconds <= 0,
               audioRender.ringBufferedSeconds <= 0 {
                audioEnd = max(time, duration)
            }
        }
        if hasFiniteDuration {
            videoEnd = videoEnd.map { min($0, duration) }
            audioEnd = audioEnd.map { min($0, duration) }
        }
        var bufferedThrough = bindingDeliveryRunway(video: videoEnd, audio: audioEnd)
        if demuxReachedEOF, hasFiniteDuration, tracksDrainedAtEOF {
            bufferedThrough = max(bufferedThrough ?? time, duration)
        }
        if let through = bufferedThrough, hasFiniteDuration {
            bufferedThrough = min(through, duration)
        }
        return (videoEnd, audioEnd, bufferedThrough)
    }

    // MARK: - Delivery runway

    var videoDeliveryRunway: TimeInterval? {
        guard let queued = queuedVideoRunway else { return nil }
        if isVideoLaneWarmSuspended { return queued }
        return queued + cachedVideoRunwaySeconds
    }

    var audioDeliveryRunway: TimeInterval? {
        guard let queued = queuedAudioRunway else { return nil }
        return queued + cachedAudioRunwaySeconds
    }

    var queuedVideoRunway: TimeInterval? {
        guard videoDecoderOpened else { return nil }
        if isVideoLaneWarmSuspended { return suspendedVideoRunway }
        let enqueuedAhead = videoRender.enqueuedAheadSeconds(from: clock.mediaTime)
        return max(0, enqueuedAhead + videoPacketQueue.contentSeconds + pendingVideoContentSeconds)
    }

    var queuedAudioRunway: TimeInterval? {
        guard hasAudioTrack else { return nil }
        return max(
            0,
            audioRender.ringBufferedSeconds + audioPacketQueue.contentSeconds + pendingAudioContentSeconds
        )
    }

    var pipelineRunway: TimeInterval? {
        bindingDeliveryRunway(video: queuedVideoRunway, audio: queuedAudioRunway)
    }

    private var admitsSourceWaitBudget: Bool {
        hasMultiConnectionHelpers && isReady && isPlaying && !isBuffering
            && !isSeekInFlight && !isVideoLaneWarmSuspended
            && !isPreparingWarmVideoLane && !warmVideoImageHoldWithholdsVideoSupply
            && warmPreparationTransaction.orphan == nil
            && playbackRate.isFinite && playbackRate > 0
    }

    private func invalidateSourceWaitBudget() {
        activeSourceWaitBudget?.cancel()
        activeSourceWaitBudget = nil
        sourceObservationEpoch &+= 1
        if sourceObservationEpoch == 0 { sourceObservationEpoch = 1 }
    }

    private func usefulPrimaryLatency(at now: TimeInterval) -> TimeInterval {
        for track in [MediaTrackKind.video, .audio] {
            usefulPrimarySamples[track]?.removeAll { now - $0.acceptedAt > 30 }
        }
        let tracks: [MediaTrackKind] = hasAudioTrack ? [.video, .audio] : [.video]
        return tracks.flatMap { usefulPrimarySamples[$0] ?? [] }.map(\.elapsed).max() ?? 0
    }

    private func beginSourceWaitBudget() -> MediaSourceWaitBudget? {
        guard admitsSourceWaitBudget, let reserve = pipelineRunway,
              reserve.isFinite, reserve >= 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let budget = MediaSourceWaitBudget(
            reserve: reserve, rate: playbackRate,
            sampledAt: now, usefulLatency: usefulPrimaryLatency(at: now),
            observationEpoch: sourceObservationEpoch
        )
        activeSourceWaitBudget = budget
        return budget
    }

    private func noteAcceptedPrimaryObservation(_ packet: MediaPacket) {
        guard admitsSourceWaitBudget, let observation = packet.sourcePrimaryObservation,
              observation.track == packet.track,
              observation.observationEpoch == sourceObservationEpoch else { return }
        unresolvedPrimaryTransportFailure = nil
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - observation.issuedAt
        guard elapsed.isFinite, elapsed >= 0 else { return }
        var samples = usefulPrimarySamples[packet.track] ?? []
        samples.removeAll { now - $0.acceptedAt > 30 }
        guard !samples.contains(where: { $0.acceptedAU.observation.issueID == observation.issueID }) else { return }
        let acceptedAU = MediaSourceAcceptedAU(
            observation: observation, pts: packet.pts, payloadBytes: packet.data.count
        )
        samples.append(UsefulPrimarySample(acceptedAU: acceptedAU, acceptedAt: now, elapsed: elapsed))
        usefulPrimarySamples[packet.track] = Array(samples.suffix(8))
    }

    // MARK: - Cached runway

    private var cachedVideoRunway: MediaCachedTrackContentAhead = .empty
    private var cachedAudioRunway: MediaCachedTrackContentAhead = .empty
    var cachedVideoRunwaySeconds: TimeInterval { cachedVideoRunway.seconds }
    var cachedAudioRunwaySeconds: TimeInterval { cachedAudioRunway.seconds }
    private var cachedRunwayEpoch: UInt64 = 0

    func resetCachedRunway() {
        resetCachedRunway(video: true, audio: true)
    }

    private func resetCachedRunway(video: Bool, audio: Bool) {
        cachedRunwayEpoch &+= 1
        if video { cachedVideoRunway = .empty }
        if audio { cachedAudioRunway = .empty }
    }

    private func refreshCachedRunway(generation gen: Int) async {
        guard demux.measuresCachedContentAhead else { return }
        let epoch = cachedRunwayEpoch
        let ahead = await demux.cachedContentAhead()
        guard isCurrentGeneration(gen), epoch == cachedRunwayEpoch else { return }
        cachedVideoRunway = ahead.video
        cachedAudioRunway = ahead.audio
    }

    private func cancelPausedRunwayRefresh() {
        activePausedRunwayRefreshID = nil
        pausedRunwayRefreshTask?.cancel()
        pausedRunwayRefreshTask = nil
    }

    private func isPausedPrefetchQuiet(_ telemetry: MultiConnectionTelemetry) -> Bool {
        if !hasMultiConnectionHelpers || demuxReachedEOF { return true }
        return telemetry.activeRequests == 0
            && telemetry.state != .downloading
            && telemetry.state != .pending
    }

    private func startPausedRunwayRefreshIfNeeded() {
        guard isReady, !isPlaying, !hasEmittedEnded,
              !isSeekInFlight, demux.measuresCachedContentAhead else {
            cancelPausedRunwayRefresh()
            return
        }
        guard pausedRunwayRefreshTask == nil else { return }
        let gen = generation
        nextPausedRunwayRefreshID &+= 1
        let taskID = nextPausedRunwayRefreshID
        activePausedRunwayRefreshID = taskID
        pausedRunwayRefreshTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.activePausedRunwayRefreshID == taskID {
                    self.activePausedRunwayRefreshID = nil
                    self.pausedRunwayRefreshTask = nil
                }
            }
            guard let self else { return }
            var lastBuffered = self.bufferedTime
            var stagnantQuietCount = 0
            while !Task.isCancelled,
                  self.isCurrentGeneration(gen),
                  self.activePausedRunwayRefreshID == taskID,
                  self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                  !self.isSeekInFlight {
                do {
                    try await Task.sleep(for: .milliseconds(255))
                } catch {
                    break
                }
                guard !Task.isCancelled,
                      self.isCurrentGeneration(gen),
                      self.activePausedRunwayRefreshID == taskID,
                      self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                      !self.isSeekInFlight else { break }

                let telemetry = await self.demux.multiConnectionTelemetry()
                guard !Task.isCancelled,
                      self.isCurrentGeneration(gen),
                      self.activePausedRunwayRefreshID == taskID,
                      self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                      !self.isSeekInFlight else { break }

                await self.refreshCachedRunway(generation: gen)
                guard !Task.isCancelled,
                      self.isCurrentGeneration(gen),
                      self.activePausedRunwayRefreshID == taskID,
                      self.isReady, !self.isPlaying, !self.hasEmittedEnded,
                      !self.isSeekInFlight else { break }

                let currentBuffered = self.bufferedTime
                if abs(currentBuffered - lastBuffered) > 0.005 {
                    lastBuffered = currentBuffered
                    stagnantQuietCount = 0
                    self.onEvent?(.buffered(currentBuffered))
                } else if self.isPausedPrefetchQuiet(telemetry) {
                    stagnantQuietCount += 1
                    if stagnantQuietCount >= 2 { break }
                } else {
                    stagnantQuietCount = 0
                }
            }
        }
    }

    var deliveryRunway: TimeInterval? {
        bindingDeliveryRunway(video: videoDeliveryRunway, audio: audioDeliveryRunway)
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

    var videoPacketBufferSeconds: TimeInterval { videoPacketQueue.contentSeconds }
    var audioPacketBufferSeconds: TimeInterval { audioPacketQueue.contentSeconds }
    var videoPacketCount: Int { videoPackets.count }
    var audioPacketCount: Int { audioPackets.count }

    var pendingAudioContentSeconds: TimeInterval {
        audioTimelineBuffer.contentSeconds
    }

    private var requiredAudioLaunchContentSeconds: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return max(0.000_5, audioRender.launchReserveContentSeconds)
    }

    private var audioLaunchPumpContentBudget: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return requiredAudioLaunchContentSeconds + minTrackFillRoom
    }

    var requiredAudioSeekContentSeconds: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return max(0.000_5, audioRender.seekTransitionReserveContentSeconds)
    }

    private var audioSeekPumpContentBudget: TimeInterval {
        guard hasAudioTrack else { return 0 }
        return requiredAudioSeekContentSeconds + minTrackFillRoom
    }

    private var launchReadiness: (video: Bool, audio: Bool) {
        (
            video: videoDecoderOpened && !pendingVideoFrames.isEmpty,
            audio: !hasAudioTrack || (
                audioDecoderOpened
                    && pendingAudioContentSeconds + 1e-9 >= requiredAudioLaunchContentSeconds
            )
        )
    }

    private var multiConnectionQuiet = false
    private let multiConnectionQuietGate = MultiConnectionQuietGate()
    private var hasMultiConnectionHelpers = false
    private var lastMultiConnectionPlaybackPosition: TimeInterval?
    private let helperTelemetry = MultiConnectionTelemetryRefresh()

    func refreshMultiConnectionTelemetry() {
        guard hasMultiConnectionHelpers, isReady, !hasEmittedEnded,
              !multiConnectionQuietGate.isParked else { return }
        let cached = helperTelemetry.value
        guard !(multiConnectionQuietGate.isQuiet && cached.identity != nil && cached.activeRequests == 0),
              cached.state != .unavailable, cached.state != .suppressed,
              cached.state != .unsupported else { return }
        helperTelemetry.request(generation: generation, currentGeneration: { [weak self] in
            self?.generation ?? Int.max
        }, query: { [demux] in await demux.multiConnectionTelemetry() })
    }

    func setMultiConnectionQuiet(_ quiet: MultiConnectionQuiet) {
        multiConnectionQuiet = quiet.isQuiet
        multiConnectionQuietGate.setQuiet(quiet)
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(gen) else { return }
            await self.demux.setMultiConnectionQuiet(self.multiConnectionQuiet)
        }
    }

    func cancelMultiConnectionPrefetching() async {
        hasMultiConnectionHelpers = false
        lastMultiConnectionPlaybackPosition = nil
        helperTelemetry.invalidate(.suppressed)
        await demux.cancelMultiConnectionPrefetching()
    }

    private func updateMultiConnectionPlayback() {
        guard hasMultiConnectionHelpers else { return }
        lastMultiConnectionPlaybackPosition = mediaTime
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(gen) else { return }
            await self.demux.updateMultiConnectionPlayback(
                position: self.mediaTime, rate: self.playbackRate
            )
        }
    }

    private func notifyMultiConnectionPlaybackProgressIfNeeded() {
        guard hasMultiConnectionHelpers, isPlaying, !hasEmittedEnded,
              !multiConnectionQuietGate.isParked else { return }
        let current = clock.mediaTime
        guard current.isFinite else { return }
        if let last = lastMultiConnectionPlaybackPosition, abs(current - last) < 1.0 { return }
        updateMultiConnectionPlayback()
    }

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

    private func admitAudioMaintenanceResume() -> AudioMaintenancePermit? {
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

    private var effectiveDisplayRate: Float {
        guard isPlaying, !isBuffering, !isSeekInFlight, !isVideoLaneWarmSuspended else { return 0 }
        if hasAudioTrack {
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

    private func sampleAudioPresentation() -> MediaAudioPresentationSnapshot {
        MediaAudioPresentationSnapshot(
            contentTime: clock.mediaTime,
            timing: hasAudioTrack ? audioRender.presentationTiming : .logical
        )
    }

    var videoPresentationDueTime: TimeInterval {
        audioPresentationMediaTime + videoPresentLeadSeconds
    }

    var videoHost: UIViewController { videoRender.hostViewController }

    private func logSeekTrace(
        phase: String,
        target: TimeInterval,
        token: MediaAudioSeekToken? = nil,
        result: Bool? = nil,
        demuxResult: Bool? = nil,
        decoderFlush: Bool? = nil,
        videoReady: Bool? = nil,
        audioReady: Bool? = nil
    ) {
        func boundedTime(_ value: TimeInterval) -> TimeInterval {
            value.isFinite ? max(0, value) : 0
        }
        func flag(_ value: Bool?) -> Int {
            value.map { $0 ? 1 : 0 } ?? -1
        }
        diagnostics.log(
            "[PathASeekSession] phase=\(phase) sessionGen=\(runtimeGeneration) " +
            "seekGen=\(generation) " +
            "tokenGen=\(token?.generation ?? 0) decoderID=\(videoDecoder.debugSessionID) " +
            "target=\(String(format: "%.3f", boundedTime(target))) " +
            "result=\(flag(result)) demux=\(flag(demuxResult)) " +
            "flush=\(flag(decoderFlush)) vOpen=\(videoDecoderOpened ? 1 : 0) " +
            "vReady=\(flag(videoReady)) aReady=\(flag(audioReady)) " +
            "vPkts=\(videoPackets.count) aPkts=\(audioPackets.count) " +
            "vRes=\(residualVideoPackets.count) aRes=\(residualAudioPackets.count) " +
            "pendingV=\(pendingVideoFrames.count) " +
            "pcm=\(String(format: "%.3f", boundedTime(pendingAudioContentSeconds))) " +
            "eof=\(demuxReachedEOF ? 1 : 0)"
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

    private func performOpen(_ request: MediaOpenRequest, generation gen: Int) async {
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
        lastAudioDecodeDiagnostics = .unavailable
        audioDecodePacketsSubmitted = 0
        audioDecodePCMFramesProduced = 0
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
        let openNetworkCounter = networkByteCounter
        totalVideoPacketsIngested = 0
        totalAudioPacketsIngested = 0
        totalVideoPacketsDequeued = 0
        totalVideoPacketsSubmitted = 0
        totalVideoInputContentSecondsConsumed = 0
        totalVideoOutputPTSAdvanced = false
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
            demuxOpenCount &+= 1
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
                let audioDiagnostics = lastAudioDecodeDiagnostics
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
            let maxV = maxPassThroughVideoPackets()
            let frameBytes = estimatedVideoFrameBytes()
            diagnostics.log(
                "[PathA] prime done vPkts=\(videoPacketCount) aPkts=\(audioPacketCount) " +
                "vDepth=\(String(format: "%.2f", videoPacketQueue.contentSeconds))s " +
                "aDepth=\(String(format: "%.2f", audioPacketQueue.contentSeconds))s " +
                "pendingV=\(pendingVideoFrameCount) pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s " +
                "decodedV=\(decodedVideoFrameCount) duration=\(String(format: "%.1f", d))s " +
                "cap video packets \(maxV) (≈\(frameBytes * maxV / (1024 * 1024))MB)" +
                (holdsPassThroughVideo ? " passThrough=1" : "")
            )
            tracing.mark(.demandPrimeDone, token: request.startupTraceToken)
            onEvent?(.ready(duration: d))
        } catch let err as MediaEngineError {
            guard isCurrentGeneration(gen) else { return }
            onEvent?(.failed(transportEngineError(err, stage: .mediaOpen)))
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
        let costSpan = UIHitchMonitor.beginSpan("session.pause")
        defer { UIHitchMonitor.endSpan(costSpan) }
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
        let costSpan = UIHitchMonitor.beginSpan("session.park")
        defer { UIHitchMonitor.endSpan(costSpan) }
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
            clearPendingVideoFrames()
            videoPackets = []
            residualVideoPackets = []
            videoPacketQueue.reset()
            resetCachedRunway(video: true, audio: false)
            videoRender.flush()
            if !isVideoLaneWarmSuspended {
                activeVideoSuspendToken = nil
            }
        }
        activeOwnerGeneration = generation
        if releasedImageHold { requestSupplyWake() }
    }

    func prepareSeek(to time: TimeInterval) async -> MediaEngineSeekPreparation {
        let captureReceipt = UUID()
        pausedCaptureSeekPreparationReceipt = captureReceipt
        defer {
            if pausedCaptureSeekPreparationReceipt == captureReceipt {
                pausedCaptureSeekPreparationReceipt = nil
            }
        }
        (videoRender as? SampleBufferVideoRenderer)?.retireNonWarmPresentationImage()
        let seekEntryGeneration = generation
        let seekEntryOwnerGeneration = activeOwnerGeneration
        func supersededPreparation() -> MediaEngineSeekPreparation {
            MediaEngineSeekPreparation(
                token: MediaAudioSeekToken(generation: 0),
                target: max(0, time),
                stagedContentSeconds: 0,
                isReady: false
            )
        }
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        supersedeWarmVideoPreparationRun()
        cancelPausedRunwayRefresh()
        cancelSupplyLoop()
        revokeAudioMaintenancePermission()
        await audioRender.awaitAudioMaintenanceSettlement()
        guard !Task.isCancelled, generation == seekEntryGeneration,
              activeOwnerGeneration == seekEntryOwnerGeneration else { return supersededPreparation() }
        let previousDecodeTask = decodeTask
        let previousAudioDecodeTask = audioDecodeTask
        cancelDecode()
        await previousDecodeTask?.value
        await previousAudioDecodeTask?.value
        guard !Task.isCancelled,
              generation == seekEntryGeneration,
              activeOwnerGeneration == seekEntryOwnerGeneration else {
            return supersededPreparation()
        }
        disarmPresentFeed()
        resetVideoLivenessState(resetStartup: false)
        resetPipeInstrumentWindow()
        resetFlowGapTracking()
        let helperState: MultiConnectionTelemetry.State = hasMultiConnectionHelpers
            ? (helperTelemetry.value.state == .unsupported ? .unsupported : .pending)
            : .notConfigured
        lastMultiConnectionPlaybackPosition = nil
        helperTelemetry.invalidate(helperState)
        generation &+= 1
        let gen = generation
        let predecessor = lifecycleSerialTask
        await predecessor?.value
        guard isCurrentGeneration(gen) else {
            return supersededPreparation()
        }
        runtimeFaultedGeneration = nil
        publishedRuntimeFaultGeneration = nil
        let token = audioRender.beginSeekTransition(source: self)
        beginSeekTransaction(token: token)
        consecutiveVideoPresentErrorCount = 0
        seekPhaseStopwatch = SeekPhaseStopwatch(
            token: token.generation,
            isEnabled: diagnostics.isCapturing
        )
        logSeekTrace(
            phase: "generation",
            target: time,
            token: token,
            result: true
        )
        hasEmittedEnded = false
        isBuffering = false
        demuxReachedEOF = false
        audioEOFDrain.reset()
        let audioGraphWasRunning = audioRender.isRunning
        diagnostics.log(
            "[PathA] seek audio graph " +
            (audioGraphWasRunning ? "kept running" : "already stopped")
        )
        applyDisplayPlayback(rate: 0)

        func notReady() -> MediaEngineSeekPreparation {
            MediaEngineSeekPreparation(
                token: token,
                target: clock.mediaTime,
                stagedContentSeconds: 0,
                isReady: false
            )
        }

        do {
            try await demux.seek(to: time)
            seekPhaseStopwatch?.mark(.demux)
            logSeekTrace(
                phase: "demux",
                target: time,
                token: token,
                result: true,
                demuxResult: true
            )
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            clock.seek(to: time)
            updatePiPPlaybackState()
            resetOutputMediaFloor(to: clock.mediaTime)
            clearPacketBuffers()
            clearPendingVideoFrames()
            clearPendingPCM()
            seekFirstPacketLogged = false
            await videoDecoder.flush()
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            await audioDecoder.flush()
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            videoRender.flush()
            videoPrerollClassifier?.reset()
            seekPhaseStopwatch?.mark(.flush)
            logSeekTrace(
                phase: "flush",
                target: clock.mediaTime,
                token: token,
                result: true,
                decoderFlush: true
            )
            resetDisplayTimeline(to: clock.mediaTime)
            beginPrerollStats(context: .seek, generation: gen)
            let primingOutcome = try await primeSeekTargetSide(
                generation: gen,
                token: token
            )
            seekPhaseStopwatch?.mark(.gate)
            logPrerollSuppression(context: "seek")
            finishPrerollStats(generation: gen, token: token)
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            let targetVideoReady: Bool
            let targetAudioReady: Bool
            switch primingOutcome {
            case .superseded:
                return notReady()
            case .ready(let gate):
                targetVideoReady = gate.videoLaunchReady
                targetAudioReady = gate.audioLaunchReady
                logSeekTrace(
                    phase: "preroll",
                    target: clock.mediaTime,
                    token: token,
                    result: true,
                    videoReady: targetVideoReady,
                    audioReady: targetAudioReady
                )
            case .failed(let failure, let gate):
                logSeekTrace(
                    phase: "preroll",
                    target: clock.mediaTime,
                    token: token,
                    result: false,
                    videoReady: gate.videoLaunchReady,
                    audioReady: gate.audioLaunchReady
                )
                let audioQueueDepth = String(
                    format: "%.2f",
                    audioPacketQueue.contentSeconds
                )
                let pendingPCMSeconds = String(
                    format: "%.2f",
                    pendingAudioContentSeconds
                )
                let videoQueueDepth = String(
                    format: "%.2f",
                    videoPacketQueue.contentSeconds
                )
                diagnostics.diagnostic(
                    "[PathA] ⚠️ SEEK PRIMING FAILED (\(failure.rawValue)) — target=" +
                    "\(String(format: "%.1f", time))s floor=" +
                    "\(String(format: "%.1f", outputMediaFloor))s: demux positioning " +
                    "succeeded, target-side content did not; audioReady=" +
                    "\(gate.audioLaunchReady) " +
                    "videoReady=\(gate.videoLaunchReady) dropV=\(droppedPrerollVideoFrameCount) " +
                    "dropA=\(droppedPrerollAudioFrameCount) " +
                    "trimA=\(trimmedPrerollAudioSampleFrameCount) " +
                    "aPkts=\(audioPackets.count) aQ=\(audioQueueDepth) " +
                    "aRes=\(residualAudioPackets.count) pcm=\(pendingPCMSeconds) " +
                    "vPkts=\(videoPackets.count) vQ=\(videoQueueDepth) " +
                    "vRes=\(residualVideoPackets.count) eof=\(demuxReachedEOF) " +
                    gate.diagnosticSummary
                )
                logSeekTrace(
                    phase: "prepare",
                    target: clock.mediaTime,
                    token: token,
                    result: false,
                    videoReady: gate.videoLaunchReady,
                    audioReady: gate.audioLaunchReady
                )
                failSeekPriming(
                    token,
                    generation: gen,
                    failure: failure,
                    gate: gate
                )
                return notReady()
            }

            let audioPreparation: MediaAudioSeekPreparation
            if hasAudioTrack, audioDecoderOpened {
                audioPreparation = audioRender.prepareSeekTransition(
                    token,
                    source: self
                )
            } else {
                audioPreparation = MediaAudioSeekPreparation(
                    token: token,
                    stagedContentSeconds: 0,
                    isReady: true
                )
            }
            seekPhaseStopwatch?.mark(.stage)

            guard audioPreparation.token == token, audioPreparation.isReady else {
                diagnostics.diagnostic(
                    "[PathA] seek renderer staging not ready — target=" +
                    String(format: "%.1f", clock.mediaTime) +
                    " staged=" +
                    String(format: "%.3f", audioPreparation.stagedContentSeconds) + "s"
                )
                logSeekTrace(
                    phase: "prepare",
                    target: clock.mediaTime,
                    token: token,
                    result: false,
                    videoReady: targetVideoReady,
                    audioReady: false
                )
                failSeekRendererStep(
                    token,
                    generation: gen,
                    label: "seek-audio-staging"
                )
                return notReady()
            }

            let preparation = MediaEngineSeekPreparation(
                token: token,
                target: clock.mediaTime,
                stagedContentSeconds: audioPreparation.stagedContentSeconds,
                isReady: true
            )
            seekTransaction.markPrepared(preparation)
            logSeekTrace(
                phase: "prepare",
                target: preparation.target,
                token: preparation.token,
                result: true,
                videoReady: targetVideoReady,
                audioReady: targetAudioReady
            )
            return preparation
        } catch {
            if activePrerollStatsGeneration == gen {
                activePrerollStats = nil
                activePrerollStatsGeneration = nil
                prerollAnomalyBaseline = nil
            }
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            logSeekTrace(
                phase: "demux",
                target: time,
                token: token,
                result: false,
                demuxResult: false
            )
            let engineError = transportEngineError(error, stage: .mediaSeek)
            failSeekPreparation(token, error: engineError)
            return notReady()
        }
    }

    func commitPreparedSeek(
        _ preparation: MediaEngineSeekPreparation,
        isAuthorized: (@MainActor @Sendable () -> Bool)? = nil
    ) async -> Bool {
        var phase = (result: false, presented: false)
        defer { emitSeekPhase(token: preparation.token, result: phase.result, presented: phase.presented) }
        guard preparation.isReady,
              activeSeekToken == preparation.token,
              preparedSeek == preparation,
              isAuthorized?() ?? true
        else {
            logSeekTrace(
                phase: "commit",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        let gen = generation
        logSeekTrace(
            phase: "commit",
            target: preparation.target,
            token: preparation.token,
            result: nil,
            videoReady: !pendingVideoFrames.isEmpty,
            audioReady: !hasAudioTrack || pendingAudioContentSeconds > 0.000_5
        )
        let committed = await commitPreparedAudioSeek(preparation, generation: gen, isAuthorized: isAuthorized)
        markSeekPhaseCommitAck(preparation.token)
        logSeekTrace(
            phase: "commit",
            target: preparation.target,
            token: preparation.token,
            result: committed,
            videoReady: !pendingVideoFrames.isEmpty,
            audioReady: !hasAudioTrack || pendingAudioContentSeconds > 0.000_5
        )
        guard isCurrentGeneration(gen),
              activeSeekToken == preparation.token,
              committed
        else {
            if !committed, isAuthorized?() ?? true {
                failSeekRendererStep(
                    preparation.token,
                    generation: gen,
                    label: "seek-renderer-commit"
                )
            } else {
                discardSeekPreparedContent(for: preparation.token)
            }
            logSeekTrace(
                phase: "abort",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        guard isAuthorized?() ?? true else {
            discardSeekPreparedContent(for: preparation.token)
            clearSeekTransaction()
            logSeekTrace(
                phase: "abort",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        clearSeekTransaction()
        isBuffering = false
        audioOutputDisplayHold = nil
        onEvent?(.tick(
            mediaTime: clock.mediaTime,
            duration: clock.duration,
            buffered: bufferedTime
        ))
        if isPlaying {
            resetPipeInstrumentWindow()
            startAudioRenderIfNeeded()
            applyPipelineDemand()
            armPresentFeedIfNeeded()
            phase.presented = presentDueVideoFramesReportingPresentation()
            startSupplyLoop()
            scheduleVideoDecodeIfNeeded()
            scheduleAudioDecodeIfNeeded()
        } else {
            applyDisplayPlayback(rate: 0)
            startPausedRunwayRefreshIfNeeded()
        }
        phase.result = true
        return true
    }

    private func commitPreparedAudioSeek(
        _ preparation: MediaEngineSeekPreparation, generation gen: Int,
        isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool {
        await audioRender.commitSeekTransition(
            preparation.token,
            isAuthorized: { [weak self] in
                guard let self else { return false }
                return self.isCurrentGeneration(gen) && self.activeSeekToken == preparation.token
                    && self.preparedSeek == preparation && (isAuthorized?() ?? true)
            },
            resumesPlayback: isPlaying,
            resumeAdmission: { [weak self] in
                guard let self, self.isCurrentGeneration(gen), self.activeSeekToken == preparation.token,
                      self.preparedSeek == preparation, isAuthorized?() ?? true else { return nil }
                return self.admitAudioMaintenanceResume()
            },
            beforeGateRelease: { [weak self] in
                self?.seekTransaction.finishCommitGate()
            }
        )
    }

    func abortPreparedSeek(_ preparation: MediaEngineSeekPreparation) {
        guard activeSeekToken == preparation.token else { return }
        audioRender.abortSeekTransition(preparation.token)
        discardSeekPreparedContent(for: preparation.token)
        clearSeekTransaction()
        logSeekTrace(
            phase: "abort",
            target: preparation.target,
            token: preparation.token,
            result: false
        )
    }

    func seek(to time: TimeInterval) async -> Bool {
        let preparation = await prepareSeek(to: time)
        guard preparation.isReady else { return false }
        return await commitPreparedSeek(preparation, isAuthorized: nil)
    }

    private enum SeekPrimingOutcome {
        case ready(SeekPrimingGate)
        case superseded
        case failed(SeekPrimingFailure, SeekPrimingGate)
    }

    private func primeOpenLaunchReserve(
        generation gen: Int
    ) async throws -> SeekPrimingOutcome {
        var gate = SeekPrimingGate(
            requirements: SeekPrimingRequirements(
                target: outputMediaFloor,
                hasAudioTrack: hasAudioTrack,
                requiredPCMContentSeconds: requiredAudioLaunchContentSeconds
            )
        )
        func isSuperseded() -> Bool { !isCurrentGeneration(gen) }

        while true {
            if Task.isCancelled || isSuperseded() { return .superseded }

            let demuxGateBusy = isFillingQueues
            var gateWaitSeconds: TimeInterval = 0
            if demuxGateBusy {
                let waitStart = ContinuousClock.now
                try? await Task.sleep(nanoseconds: supplyStallBackoffNanos)
                let waited = waitStart.duration(to: ContinuousClock.now)
                gateWaitSeconds = Double(waited.components.seconds)
                    + Double(waited.components.attoseconds) / 1e18
                if Task.isCancelled || isSuperseded() { return .superseded }
            } else {
                try await fillQueuesToHighWater(
                    generation: gen,
                    initiator: .openPrime,
                    phase: .open,
                    videoContentCap: primeVideoContentBudget,
                    audioContentCap: audioLaunchPumpContentBudget
                )
                if isSuperseded() { return .superseded }
            }
            if let decodeTask {
                await decodeTask.value
            }
            try await drainPrerollBatches(generation: gen, context: .open)
            if isSuperseded() { return .superseded }
            if pendingVideoFrames.isEmpty {
                await drainVideoDecodeBurst(generation: gen)
            }
            if isSuperseded() { return .superseded }
            if outputMediaFloor > outputMediaFloorEpsilon
                    || droppedPrerollVideoFrameCount > 0 {
                try await primeVideoRunwayAfterPreroll(generation: gen, phase: .open)
                if isSuperseded() { return .superseded }
            }
            try await fillPCMRing(
                generation: gen,
                phase: .open,
                contentCap: requiredAudioLaunchContentSeconds
            )
            if isSuperseded() { return .superseded }

            let pass = SeekPrimingPass(
                videoDecodeFrontier: videoDecodeFrontierPTS,
                audioDecodeFrontier: audioDecodeFrontierPTS,
                bytesRead: bytesRead,
                postPrerollVideoFrames: pendingVideoFrames.count,
                postPrerollPCMContentSeconds: pendingAudioContentSeconds,
                videoDecoderOpened: videoDecoderOpened,
                audioDecoderOpened: audioDecoderOpened,
                demuxReachedEOF: demuxReachedEOF,
                didAttemptDemuxPull: !demuxGateBusy,
                demuxGateWaitSeconds: gateWaitSeconds
            )
            switch gate.evaluate(pass, isSuperseded: isSuperseded()) {
            case .launchReady:
                return .ready(gate)
            case .continuePriming:
                continue
            case .superseded:
                return .superseded
            case .failed(let failure):
                return .failed(failure, gate)
            }
        }
    }

    private func primeSeekTargetSide(
        generation gen: Int,
        token: MediaAudioSeekToken
    ) async throws -> SeekPrimingOutcome {
        var gate = SeekPrimingGate(
            requirements: SeekPrimingRequirements(
                target: outputMediaFloor,
                hasAudioTrack: hasAudioTrack,
                requiresVideo: !isVideoLaneWarmSuspended,
                requiredPCMContentSeconds: requiredAudioSeekContentSeconds
            )
        )

        func isSuperseded() -> Bool {
            !isCurrentGeneration(gen) || activeSeekToken != token
        }

        while true {
            if Task.isCancelled { return .superseded }
            if isSuperseded() { return .superseded }

            var lap = SeekPhaseLap(isEnabled: seekPhaseStopwatch?.isEnabled == true)
            let demuxGateBusy = isFillingQueues
            var gateWaitSeconds: TimeInterval = 0
            if demuxGateBusy {
                let waitStart = ContinuousClock.now
                try? await Task.sleep(nanoseconds: supplyStallBackoffNanos)
                let waited = waitStart.duration(to: ContinuousClock.now)
                gateWaitSeconds = Double(waited.components.seconds)
                    + Double(waited.components.attoseconds) / 1e18
                if Task.isCancelled { return .superseded }
                if isSuperseded() { return .superseded }
            } else {
                try await fillQueuesToHighWater(
                    generation: gen,
                    initiator: .seekPrime,
                    phase: .seek,
                    videoContentCap: primeVideoContentBudget,
                    audioContentCap: audioSeekPumpContentBudget
                )
                if isSuperseded() { return .superseded }
            }

            try await drainPrerollBatches(generation: gen, context: .seek(token))
            if isSuperseded() { return .superseded }
            await drainVideoDecodeBurst(generation: gen)
            if isSuperseded() { return .superseded }
            seekPhaseStopwatch?.addPreroll(lap.split())
            if outputMediaFloor > outputMediaFloorEpsilon
                    || droppedPrerollVideoFrameCount > 0 {
                try await primeVideoRunwayAfterPreroll(generation: gen, phase: .seek)
                if isSuperseded() { return .superseded }
            }
            seekPhaseStopwatch?.addRunway(lap.split())
            try await fillPCMRing(
                generation: gen,
                phase: .seek,
                contentCap: requiredAudioSeekContentSeconds,
                packetContentCap: audioSeekPumpContentBudget
            )
            seekPhaseStopwatch?.addAudio(lap.split())
            if isSuperseded() { return .superseded }
            if gate.passCount == 0 {
                logSeekTrace(
                    phase: "refill",
                    target: clock.mediaTime,
                    token: token,
                    result: true
                )
            }

            let pass = SeekPrimingPass(
                videoDecodeFrontier: videoDecodeFrontierPTS,
                audioDecodeFrontier: audioDecodeFrontierPTS,
                bytesRead: bytesRead,
                postPrerollVideoFrames: pendingVideoFrames.count,
                postPrerollPCMContentSeconds: pendingAudioContentSeconds,
                videoDecoderOpened: videoDecoderOpened,
                audioDecoderOpened: audioDecoderOpened,
                demuxReachedEOF: demuxReachedEOF,
                didAttemptDemuxPull: !demuxGateBusy,
                demuxGateWaitSeconds: gateWaitSeconds
            )
            switch gate.evaluate(pass, isSuperseded: isSuperseded()) {
            case .launchReady:
                if gate.passCount > 1 {
                    diagnostics.log(
                        "[PathA] seek priming completed after \(gate.passCount) " +
                        "passes: \(gate.diagnosticSummary)"
                    )
                }
                return .ready(gate)
            case .continuePriming:
                continue
            case .superseded:
                return .superseded
            case .failed(let failure):
                return .failed(failure, gate)
            }
        }
    }

    private func failSeekPriming(
        _ token: MediaAudioSeekToken,
        generation gen: Int,
        failure: SeekPrimingFailure,
        gate: SeekPrimingGate
    ) {
        guard activeSeekToken == token else { return }
        let target = clock.mediaTime
        audioRender.abortSeekTransition(token)
        discardSeekPreparedContent(for: token)
        clearSeekTransaction()
        logSeekTrace(
            phase: "abort",
            target: target,
            token: token,
            result: false
        )
        publishRuntimeFault(
            MediaRuntimeFault(
                subsystem: failure.faultSubsystem(
                    shortTrackIsAudio: !gate.audioLaunchReady
                ),
                stage: .seekPriming,
                classification: failure.faultClassification,
                recoverability: failure.faultRecoverability,
                ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                diagnostics: MediaRuntimeFaultDiagnostics(
                    label: failure.rawValue,
                    details: "target=\(String(format: "%.2f", target)) " +
                        gate.diagnosticSummary
                )
            ),
            generation: gen
        )
    }

    private func launchReserveFault(
        videoReady: Bool,
        audioReady: Bool,
        primingFailure: SeekPrimingFailure?
    ) -> MediaRuntimeFault {
        let shortTrackIsAudio = videoReady
        let hadInput = shortTrackIsAudio
            ? audioDecodePacketsSubmitted > 0 || audioPacketQueue.contentSeconds > 0
            : totalVideoPacketsSubmitted > 0 || videoPacketQueue.contentSeconds > 0
        let subsystem = primingFailure?.faultSubsystem(shortTrackIsAudio: shortTrackIsAudio)
            ?? (hadInput ? (shortTrackIsAudio ? .audioDecoder : .videoDecoder) : .demux)
        let classification = primingFailure?.faultClassification
            ?? (hadInput ? .silentNoOutput : .input)
        return MediaRuntimeFault(
            subsystem: subsystem,
            stage: .open,
            classification: classification,
            recoverability: .automaticSourceAwareReopen,
            ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
            diagnostics: MediaRuntimeFaultDiagnostics(
                label: "launch-reserve",
                details: "\(primingFailure?.rawValue ?? "predicate") " +
                    "video=\(videoReady ? 1 : 0) audio=\(audioReady ? 1 : 0) " +
                    "pcm=\(String(format: "%.3f", pendingAudioContentSeconds)) " +
                    "pendingV=\(pendingVideoFrames.count)"
            )
        )
    }

    private func failSeekRendererStep(
        _ token: MediaAudioSeekToken,
        generation gen: Int,
        label: String
    ) {
        guard activeSeekToken == token else { return }
        let target = clock.mediaTime
        audioRender.abortSeekTransition(token)
        discardSeekPreparedContent(for: token)
        clearSeekTransaction()
        logSeekTrace(
            phase: "abort",
            target: target,
            token: token,
            result: false
        )
        publishRuntimeFault(
            MediaRuntimeFault(
                subsystem: .audioRenderer,
                stage: .seekPriming,
                classification: .silentNoOutput,
                recoverability: .automaticSourceAwareReopen,
                ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                diagnostics: MediaRuntimeFaultDiagnostics(
                    label: label,
                    details: "target=\(String(format: "%.2f", target))"
                )
            ),
            generation: gen
        )
    }

    private func failSeekPreparation(
        _ token: MediaAudioSeekToken,
        error: MediaEngineError
    ) {
        guard activeSeekToken == token else { return }
        let target = clock.mediaTime
        audioRender.abortSeekTransition(token)
        discardSeekPreparedContent(for: token)
        clearSeekTransaction()
        isPlaying = false
        isReady = false
        isBuffering = false
        audioRender.stop()
        applyDisplayPlayback(rate: 0)
        logSeekTrace(
            phase: "abort",
            target: target,
            token: token,
            result: false
        )
        onEvent?(.failed(error))
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
        resetVideoContinuationState()
        resetVideoLivenessState(resetStartup: true)
        resetFlowGapTracking()
        resetOutputMediaFloor(to: 0)
        clearPendingVideoFrames()
        clearPendingPCM()
        enqueueResourceClose()
        videoRender.invalidate()
        clock.reset()
        clearDisplayOutputContinuity()
        isReady = false
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

    private func isCurrentGeneration(_ gen: Int) -> Bool {
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

    private func publishRuntimeFault(
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

    @discardableResult
    func startPiP() -> Bool {
        guard isAutomaticPiPEnabled,
              activePiPEventBindingToken != nil else {
            diagnostics.log("[PathA] startPiP: capability disabled or unbound")
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
        let rendererFaulted: Bool = {
            switch current.rendererHealth {
            case .needsFlush, .rendererFailed, .decoderInvalid:
                return true
            case .visible, .attachedButUnproven, .warmSuspended, .missingSurface:
                return false
            }
        }() || {
            switch snapshot.rendererHealth {
            case .needsFlush, .rendererFailed, .decoderInvalid:
                return true
            case .visible, .attachedButUnproven, .warmSuspended, .missingSurface:
                return false
            }
        }()
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

    var hasLocalPresentationFault: Bool {
        suspendedVideoFault != nil
            && runtimeFaultedGeneration == nil
            && isReady
            && (isPlaying || isVideoLaneWarmSuspended)
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

    @discardableResult
    func warmSuspendVideoLane() -> DemandVideoSuspensionResult {
        return suspendVideoLane(
            reason: .audioOnlyBackground,
            resumesPlayback: isPlaying
        )
    }

    @discardableResult
    func suspendVideoLaneAfterPiPStop() -> DemandVideoSuspensionResult {
        suspendVideoLane(
            reason: .pipDidStop,
            resumesPlayback: isPlaying
        )
    }

    @discardableResult
    private func suspendVideoLane(
        reason: DemandVideoLaneSuspensionReason,
        resumesPlayback: Bool
    ) -> DemandVideoSuspensionResult {
        guard isReady, !isSeekInFlight else { return .deferred }
        guard hasAudioTrack, videoContinuityTopology != .unsupported else { return .unsupported }
        if let activeVideoSuspendToken,
           isVideoLaneWarmSuspended,
           activeVideoSuspendToken.sessionGeneration == runtimeGeneration,
           activeVideoSuspendToken.ownerGeneration == activeOwnerGeneration,
           activeVideoSuspendToken.reason == reason,
           activeVideoSuspendToken.resumesPlayback == resumesPlayback {
            return .suspended(activeVideoSuspendToken)
        }

        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        supersedeWarmVideoPreparationRun()

        videoContinuationGeneration &+= 1
        if videoContinuationGeneration == 0 { videoContinuationGeneration = 1 }
        let token = DemandVideoSuspendToken(
            generation: videoContinuationGeneration,
            sessionGeneration: runtimeGeneration,
            audioPosition: clock.mediaTime,
            videoReadGeneration: nextVideoReadGeneration,
            videoReadBytesAtSuspend: videoReadBytes,
            ownerGeneration: activeOwnerGeneration,
            reason: reason,
            resumesPlayback: resumesPlayback
        )
        activeVideoSuspendToken = token
        isVideoLaneWarmSuspended = true
        isVideoLanePreparedForForeground = false
        terminalVideoPreparationFailure = nil
        warmVideoPreparationLedger.retireAttempt()
        let preexistingSuspendedVideoFault = suspendedVideoFault
        suspendedVideoFault = reason == .pipDidStop
            ? preexistingSuspendedVideoFault
            : nil
        isCollectingWarmVideoRunUp = false
        warmVideoCandidateAuthorities = []

        cancelVideoDecode(clearHandle: false)
        let warmSuspendBegan = ContinuousClock.now
        disarmPresentFeed()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            renderer.warmSuspendPresentation(mediaTime: audioPresentationMediaTime)
        } else {
            videoRender.flush()
        }
        let surfaceEnded = ContinuousClock.now

        var retainedPackets: [MediaPacket] = []
        retainedPackets.reserveCapacity(videoPackets.count + residualVideoPackets.count)
        for packet in videoPackets { retainedPackets.append(packet) }
        for packet in residualVideoPackets { retainedPackets.append(packet) }
        videoPackets = []
        residualVideoPackets = []
        videoPacketQueue.reset()
        clearPendingVideoFrames()
        suspendedVideoGOP = []
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPProvenance = nil
        suspendedVideoSupplyMemorySuppressed = false
        for packet in retainedPackets {
            retainSuspendedVideoPacket(
                packet,
                provenance: .suspendEdge(readGeneration: token.videoReadGeneration)
            )
        }
        resetVideoLivenessState(resetStartup: false)
        requestSupplyWake()
        let warmSuspendEnded = ContinuousClock.now
        func milliseconds(_ elapsed: Duration) -> Int {
            Int(elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }
        diagnostics.log(
            "[PathA][continuation] video warm-suspended token=\(token.generation) " +
            "reason=\(token.reason.rawValue) resumes=\(token.resumesPlayback ? 1 : 0) " +
            "session=\(token.sessionGeneration) audio=\(String(format: "%.3f", token.audioPosition)) " +
            "gop=\(suspendedVideoGOP.count) " +
            "in=\(milliseconds(warmSuspendEnded - warmSuspendBegan))ms " +
            "surface=\(milliseconds(surfaceEnded - warmSuspendBegan))ms " +
            "bufs=\(milliseconds(warmSuspendEnded - surfaceEnded))ms " +
            "retained=\(retainedPackets.count)"
        )
        schedulePiPVideoResumeIfNeeded()
        return .suspended(token)
    }

    func retainAudioAfterVideoFailure() -> DemandVideoSuspendToken? {
        guard isReady, hasAudioTrack, audioDecoderOpened, !hasEmittedEnded,
              runtimeFaultedGeneration != generation, !hasObservedPiPLease else { return nil }
        if isVideoLaneWarmSuspended, let token = activeVideoSuspendToken,
           token.sessionGeneration == runtimeGeneration,
           token.ownerGeneration == activeOwnerGeneration {
            return token
        }
        guard case .suspended(let token) = warmSuspendVideoLane() else { return nil }
        return token
    }

    func prepareVideoLaneForForeground(
        _ token: DemandVideoSuspendToken
    ) async -> DemandVideoLanePreparationResult {
        guard !Task.isCancelled else { return .cancelled }
        if activeVideoSuspendToken == token,
           token.ownerGeneration == activeOwnerGeneration,
           let terminalVideoPreparationFailure {
            return .failed(terminalVideoPreparationFailure)
        }
        if let orphan = warmPreparationTransaction.orphan {
            return .failed(orphan.failure)
        }
        guard activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration,
              isVideoLaneWarmSuspended,
              !isVideoLanePreparedForForeground else {
            let alreadyPrepared = activeVideoSuspendToken == token
                && token.ownerGeneration == activeOwnerGeneration
                && isVideoLanePreparedForForeground
            if alreadyPrepared {
                diagnostics.log(
                    "[PathA][continuation] activation validation covers=" +
                    (preparedVideoLaneCoversCurrentAudio() ? "1" : "0") + " " +
                    "target=\(String(format: "%.3f", audioPresentationMediaTime)) " +
                    "pending=\(pendingVideoFrames.count)"
                )
            }
            return alreadyPrepared ? .prepared : .cancelled
        }

        let run = warmPreparationTransaction.begin(token: token, host: self)
        return await warmPreparationTransaction.result(for: run, host: self)
    }

    func makeWarmVideoPreparationRun(
        id: UInt64, token: DemandVideoSuspendToken
    ) -> WarmVideoPreparationRunLedger.Run {
        WarmVideoPreparationRunLedger.Run(
            id: id,
            token: token,
            sessionGeneration: runtimeGeneration,
            engineGeneration: generation,
            ownerGeneration: activeOwnerGeneration,
            startedAt: ContinuousClock.now
        )
    }

    func captureWarmPreparationInterrupt() -> WarmPreparationTransaction.InterruptOperation {
        let demux = self.demux
        return { @MainActor [demux] in await demux.interruptActiveIO() }
    }

    func applyWarmPreparationNotice(_ notice: WarmPreparationTransaction.Notice) {
        switch notice {
        case .runStarted(let run):
            warmVideoPreparationLedger.clearProgress()
            warmDiagnosticProofIdentity = nil
            activeWarmDiagnostics = WarmVideoPreparationDiagnosticsState(
                runID: run.id,
                target: audioPresentationMediaTime,
                startedAt: run.startedAt
            )
            warmDiagnosticPhase("run-start")

            bindWarmDecoderTiming(run: run)
        case .primaryReturned(let run, let result):
            recordWarmPreparationPrimaryReturn(run, result: result)
        case .timeoutObserved(let run):
            logWarmVideoPreparationTimeoutSnapshot(run)
            warmDiagnosticPhase("timeout")
        case .timeoutWillSettle(let run):
            finishWarmDiagnostics(run: run, result: .failed(.warmPreparationTimedOut))
        case .timeoutResultStored:
            terminalVideoPreparationFailure = .warmPreparationTimedOut
            isVideoLanePreparedForForeground = false
            activeWarmVideoImageHold = nil
            warmVideoPreparationLedger.retireAttempt()
            isDecodingWarmVideoCandidate = false
            isCollectingWarmVideoRunUp = false
        case .currentRunReleased:
            warmVideoPreparationLedger.clearProgress()
            isPreparingWarmVideoLane = false
        case .matchingOrphanRunReleased:
            warmVideoPreparationLedger.clearProgress()
        case .runCancelled(let run):
            finishWarmDiagnostics(run: run, result: .cancelled)
        case .resetInvalidation:
            activeVideoSuspendToken = nil
            isVideoLaneWarmSuspended = false
            resetCachedRunway(video: true, audio: false)
            isVideoLanePreparedForForeground = false
            isPreparingWarmVideoLane = false
            isDecodingWarmVideoCandidate = false
        case .supplyRestartOpportunity:
            resumeSupplyAfterWarmPreparation()
        }
    }

    private func recordWarmPreparationPrimaryReturn(
        _ run: WarmVideoPreparationRun, result: DemandVideoLanePreparationResult
    ) {
        if activeWarmDiagnostics?.runID == run.id {
            warmDiagnosticPhase(result == .prepared ? "prepared" : "completed")
            finishWarmDiagnostics(run: run, result: result)
        }
    }

    private func logWarmVideoPreparationTimeoutSnapshot(
        _ run: WarmVideoPreparationRun
    ) {
        let elapsedMs = Int(
            run.startedAt.duration(to: ContinuousClock.now) / .milliseconds(1)
        )
        let audioTarget = audioPresentationMediaTime
        let inputEndPTS = videoPacketEndPTS()
        let decodeEndPTS = videoDecodeFrontierPTS
        let pendingEndPTS = pendingVideoFrameEndPTS()
        let readBytesDelta = videoReadBytesDelta(since: run.token)
        func fmt(_ value: TimeInterval?) -> String {
            guard let value, value.isFinite else { return "nil" }
            return String(format: "%.3f", value)
        }
        diagnostics.log(
            "[PathA][continuation] warm preparation timeout snapshot " +
                "run=\(run.id) elapsedMs=\(elapsedMs) " +
                "audioTarget=\(fmt(audioTarget)) " +
                "outputFloor=\(fmt(outputMediaFloor)) " +
                "inputEndPTS=\(fmt(inputEndPTS)) " +
                "decodeEndPTS=\(fmt(decodeEndPTS)) " +
                "pendingEndPTS=\(fmt(pendingEndPTS)) " +
                "videoReadBytesDelta=\(readBytesDelta)"
        )
    }

    private func warmVideoRunIsCurrent(_ run: WarmVideoPreparationRun) -> Bool {
        !Task.isCancelled && warmPreparationTransaction.currentRun == run
            && activeVideoSuspendToken == run.token
            && run.sessionGeneration == runtimeGeneration
            && run.engineGeneration == generation
            && run.ownerGeneration == activeOwnerGeneration
    }

    private func warmVideoRunPolicy(_ run: WarmVideoPreparationRun) -> WarmVideoRecoveryPolicy {
        warmPreparationTransaction.policy(for: run)
    }

    private func warmVideoRunHasTime(_ run: WarmVideoPreparationRun) -> Bool {
        guard warmVideoRunIsCurrent(run) else { return false }
        return warmPreparationTransaction.hasTime(for: run, host: self)
    }

    private func observeWarmVideoPreparationProgress(
        _ frames: [MediaVideoFrame],
        attempt: WarmVideoPreparationAttempt,
        decoderIdentity: ObjectIdentifier
    ) {
        guard isCurrentWarmVideoPreparationAttempt(attempt),
              ObjectIdentifier(videoDecoder) == decoderIdentity,
              !videoDecoderWasRetired,
              let frontier = frames.lazy.filter({ frame in
                frame.pts.isFinite && frame.duration.isFinite && frame.duration >= 0
                    && (frame.pts + frame.duration).isFinite
              }).map(\.pts).max() else { return }
        let sampledAudio = audioPresentationMediaTime
        let sampledFloor = outputMediaFloor
        let floor: TimeInterval? = sampledAudio.isFinite && sampledFloor.isFinite
            ? max(sampledAudio, sampledFloor) : nil
        warmVideoPreparationLedger.observe(
            frontier: frontier, attempt: attempt, decoderIdentity: decoderIdentity,
            floor: floor, observedAt: .now
        )
    }

    func consumeWarmVideoPreparationProgress(for run: WarmVideoPreparationRunLedger.Run) -> Bool {
        guard let attempt = warmVideoPreparationLedger.currentAttempt,
              attempt.runID == run.id,
              isCurrentWarmVideoPreparationAttempt(attempt),
              videoDecoderOpened, !videoDecoderWasRetired else { return false }
        return warmVideoPreparationLedger.consume(
            attempt: attempt, decoderIdentity: ObjectIdentifier(videoDecoder)
        )
    }

    private func resumeSupplyAfterWarmPreparation() {
        guard isReady,
              !isPreparingWarmVideoLane,
              warmPreparationTransaction.orphan == nil,
              !warmPreparationTransaction.hasPendingInterrupt else { return }
        startSupplyLoop()
        requestSupplyWake()
    }

    func performWarmVideoPreparation(
        _ run: WarmVideoPreparationRunLedger.Run
    ) async -> DemandVideoLanePreparationResult {
        let token = run.token
        let previousSupplyLoop = supplyLoopTask
        cancelSupplyLoop()
        (videoRender as? SampleBufferVideoRenderer)?.refreshPresentationImageHold()
        let quiesceSupplyStart = ContinuousClock.now
        await previousSupplyLoop?.value
        if warmPreparationAttemptIsActive(runID: run.id) {
            activeWarmDiagnostics?.quiesceWaitTime += quiesceSupplyStart.duration(to: .now)
        }
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration else {
            return abandonWarmVideoPreparation(run)
        }
        isPreparingWarmVideoLane = true
        defer {
            if warmPreparationTransaction.currentRun?.id == run.id {
                isDecodingWarmVideoCandidate = false
                isCollectingWarmVideoRunUp = false
            }
            if warmVideoPreparationLedger.currentAttempt?.runID == run.id {
                warmVideoPreparationLedger.retireAttempt()
            }
        }
        let previousAudioDecodeTask = audioDecodeTask
        let quiesceAudioStart = ContinuousClock.now
        await previousAudioDecodeTask?.value
        if warmPreparationAttemptIsActive(runID: run.id) {
            activeWarmDiagnostics?.quiesceWaitTime += quiesceAudioStart.duration(to: .now)
        }
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
            return abandonWarmVideoPreparation(run)
        }
        let previousDecodeTask = decodeTask
        cancelVideoDecode(clearHandle: false)
        let quiesceVideoStart = ContinuousClock.now
        await previousDecodeTask?.value
        if warmPreparationAttemptIsActive(runID: run.id) {
            activeWarmDiagnostics?.quiesceWaitTime += quiesceVideoStart.duration(to: .now)
        }
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
            return abandonWarmVideoPreparation(run)
        }
        decodeTask = nil

        packetRelay.reset()

        var recovery = warmVideoRunPolicy(run)
        var rejectedCandidate: [MediaPacket]?
        var rejectedCandidateAuthority: MediaVideoContinuityCandidateAuthority?
        for repairIndex in 0...Self.warmVideoDecoderRepairLimit {
            guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                  activeVideoSuspendToken == token,
                  token.sessionGeneration == runtimeGeneration,
                  token.ownerGeneration == activeOwnerGeneration else {
                return abandonWarmVideoPreparation(run)
            }
            let startTarget = audioPresentationMediaTime
            guard startTarget.isFinite else {
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }
            let target = max(0, startTarget)

            let escalatedRung = repairIndex > 0
            let retainedCandidate = suspendedVideoCandidate(at: target) ?? []
            let retainedCandidateIsAtSuspendEdge: Bool = {
                guard let provenance = suspendedVideoGOPProvenance else {
                    return false
                }
                guard case .suspendEdge(let readGeneration) = provenance else {
                    return false
                }
                return readGeneration == token.videoReadGeneration
            }()
            var candidateDisposition: WarmVideoCandidateDisposition = escalatedRung
                ? .requiresPositioning
                : Self.classifyWarmVideoCandidate(
                    retainedCandidate,
                    topology: videoContinuityTopology,
                    target: target,
                    retainedInMemory: retainedCandidateIsAtSuspendEdge
                        && videoReadBytesDelta(since: token) == 0,
                    contentSeconds: suspendedVideoGOPContentSeconds,
                    byteCount: suspendedVideoGOPBytes
                )
            let retainedWindowBracketsTarget = retainedVideoWindowBrackets(target)
            let repositionsVideoReader: Bool
            switch videoContinuityTopology {
            case .splitTrack, .localFileIndex:
                switch candidateDisposition {
                case .bracketingPreRoll, .nearFutureImageHold, .positionedFutureImageHold:
                    repositionsVideoReader = false
                case .requiresPositioning:
                    repositionsVideoReader = true
                }
            case .muxedCurrentGOP:
                repositionsVideoReader = false
            case .unsupported:
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .unsupportedVideoContinuity
                )
            }
            let retainedWindowRange: String
            if let first = suspendedVideoGOP.first, let last = suspendedVideoGOP.last {
                retainedWindowRange = String(format: "%.3f", first.pts)
                    + ".."
                    + String(format: "%.3f", last.pts + max(0, last.duration))
            } else {
                retainedWindowRange = "empty"
            }
            diagnostics.log(
                "[PathA][continuation] prepare attempt=\(repairIndex + 1) " +
                "reposition=\(repositionsVideoReader ? 1 : 0) " +
                "brackets=\(retainedWindowBracketsTarget ? 1 : 0) " +
                "candidateMode=\(candidateDisposition.diagnosticName) " +
                "gop=\(retainedWindowRange) " +
                "topology=\(videoContinuityTopology.rawValue) " +
                "target=\(String(format: "%.3f", target))"
            )
            var forwardReceipt: MediaVideoForwardReceipt?
            var forwardFetchedBytes = 0
            var forwardChargedBytes = 0
            if repositionsVideoReader {
                do {
                    let positioned: Bool
                    let demuxWaitStartedAt = ContinuousClock.now
                    let renewedRungStarted = escalatedRung ? ContinuousClock.now : nil
                    if escalatedRung {
                        guard let rejectedCandidateAuthority else {
                            retireCurrentVideoDecoderWithoutWaiting()
                            return finishWarmVideoPreparation(
                                token: token,
                                failure: .decoderPreparationExhausted
                            )
                        }
                        resetCachedRunway(video: true, audio: false)
                        positioned = try await demux.prepareEarlierVideoContinuity(
                            before: rejectedCandidateAuthority.anchorPTS
                        )
                    } else {
                        resetCachedRunway(video: true, audio: false)
                        let rateRevision = playbackRateRevision
                        let forward = try await demux.prepareForwardVideoContinuity(
                            MediaVideoForwardRequest(
                                target: target, playbackRate: Double(playbackRate),
                                wallAllowance: warmVideoPreparationDeadline - run.startedAt.duration(to: .now),
                                maximumCompressedBytes: Self.suspendedVideoGOPMaxBytes,
                                maximumContentSpan: Self.suspendedVideoGOPMaxContentSeconds
                            )
                        )
                        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                              activeVideoSuspendToken == token,
                              playbackRateRevision == rateRevision else {
                            return abandonWarmVideoPreparation(run)
                        }
                        switch forward {
                        case .notSelected:
                            positioned = try await demux.prepareVideoContinuity(at: target)
                        case .positioned(let receipt):
                            forwardReceipt = receipt
                            positioned = true
                        }
                    }
                    guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                          activeVideoSuspendToken == token,
                          token.sessionGeneration == runtimeGeneration,
                          token.ownerGeneration == activeOwnerGeneration else {
                        return abandonWarmVideoPreparation(run)
                    }
                    if warmPreparationAttemptIsActive(runID: run.id),
                       var state = activeWarmDiagnostics {
                        state.demuxWaitTime += demuxWaitStartedAt.duration(to: .now)
                        activeWarmDiagnostics = state
                        warmDiagnosticPhase("demux-positioned")
                    }
                    guard positioned else {
                        if escalatedRung {
                            retireCurrentVideoDecoderWithoutWaiting()
                        }
                        return finishWarmVideoPreparation(
                            token: token,
                            failure: escalatedRung
                                ? .decoderPreparationExhausted
                                : .unsupportedVideoContinuity
                        )
                    }
                    if let renewedRungStarted,
                       renewedRungStarted.duration(to: ContinuousClock.now)
                            >= Self.warmVideoDirectWallLimit {
                        if escalatedRung {
                            retireCurrentVideoDecoderWithoutWaiting()
                        }
                        return finishWarmVideoPreparation(
                            token: token,
                            failure: .decoderPreparationExhausted
                        )
                    }

                    if escalatedRung {
                        guard let rejectedCandidate,
                              let rejectedCandidateAuthority else {
                            retireCurrentVideoDecoderWithoutWaiting()
                            return finishWarmVideoPreparation(
                                token: token,
                                failure: .decoderPreparationExhausted
                            )
                        }
                        return await performRenewedWarmVideoStreaming(
                            run: run,
                            token: token,
                            target: target,
                            rejectedCandidate: rejectedCandidate,
                            rejectedCandidateAuthority: rejectedCandidateAuthority,
                            generation: generation,
                            started: renewedRungStarted ?? ContinuousClock.now,
                            recovery: &recovery
                        )
                    }

                    suspendedVideoGOP = []
                    suspendedVideoGOPContentSeconds = 0
                    suspendedVideoGOPBytes = 0
                    suspendedVideoGOPProvenance = nil
                    isCollectingWarmVideoRunUp = true
                    if let forwardReceipt {
                        let collection = try await collectForwardVideoCandidate(
                            receipt: forwardReceipt, run: run,
                            phaseStarted: run.startedAt, phaseAllowance: warmVideoPreparationDeadline
                        )
                        forwardFetchedBytes = collection.fetchedBytes
                        forwardChargedBytes = collection.chargedBytes
                        let forwardCandidate = suspendedVideoCandidate(at: target) ?? []
                        candidateDisposition = classifyForwardVideoCandidate(
                            forwardCandidate, receipt: forwardReceipt, target: target
                        )
                        guard candidateDisposition != .requiresPositioning else {
                            return finishWarmVideoPreparation(
                                token: token, failure: .decoderPreparationExhausted
                            )
                        }
                        diagnostics.log(
                            "[PathA][continuation] forward candidate receipt=\(forwardReceipt.id) " +
                            "anchor=\(String(format: "%.3f", forwardReceipt.anchorPTS)) " +
                            "foregroundFetchBytes=\(forwardFetchedBytes)"
                        )
                    } else {
                        for _ in 0..<8 where suspendedVideoCandidate(at: target) == nil {
                            let readGeneration = beginVideoReadGeneration()
                            let demuxWaitStartedAt = ContinuousClock.now
                            resetCachedRunway(video: true, audio: false)
                            let packets = try await demux.pump(
                                videoBudget: 1,
                                audioBudget: 0
                            )
                            if warmPreparationAttemptIsActive(runID: run.id),
                               var state = activeWarmDiagnostics {
                                state.demuxWaitTime += demuxWaitStartedAt.duration(to: .now)
                                activeWarmDiagnostics = state
                                activeWarmDiagnostics?.pumps += 1
                                warmDiagnosticPhase("demux-pump")
                            }
                            guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                                  activeVideoSuspendToken == token,
                                  token.sessionGeneration == runtimeGeneration,
                                  token.ownerGeneration == activeOwnerGeneration else {
                                return abandonWarmVideoPreparation(run)
                            }
                            if !packets.isEmpty {
                                ingest(
                                    packets,
                                    videoReadGeneration: readGeneration,
                                    warmVideoProvenance: .positioned(
                                        readGeneration: readGeneration
                                    )
                                )
                            }
                            drainRelayedPackets()
                            if packets.isEmpty, suspendedVideoGOP.isEmpty {
                                let reachedEOF = await demux.isEOF
                                guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
                                    return abandonWarmVideoPreparation(run)
                                }
                                if reachedEOF { break }
                            }
                        }
                    }
                    isCollectingWarmVideoRunUp = false
                } catch {
                    guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run),
                          activeVideoSuspendToken == token,
                          token.sessionGeneration == runtimeGeneration,
                          token.ownerGeneration == activeOwnerGeneration else {
                        return abandonWarmVideoPreparation(run)
                    }
                    diagnostics.log(
                        "[PathA][continuation] video-only prepare failed " +
                        "topology=\(videoContinuityTopology.rawValue)"
                    )
                    if escalatedRung {
                        retireCurrentVideoDecoderWithoutWaiting()
                    }
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: escalatedRung
                            ? .decoderPreparationExhausted
                            : .unsupportedVideoContinuity
                    )
                }
            }
            guard let candidate = suspendedVideoCandidate(at: target) else {
                diagnostics.log(
                    "[PathA][continuation] prepare failed — no current keyframe GOP " +
                    "target=\(String(format: "%.3f", target))"
                )
                if escalatedRung {
                    retireCurrentVideoDecoderWithoutWaiting()
                }
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }

            let candidateAuthority = recordWarmVideoCandidateAuthority(candidate)
            let candidateRange = String(format: "%.3f", candidateAuthority.anchorPTS)
                + ".."
                + String(format: "%.3f", candidateAuthority.endPTS)
            diagnostics.log(
                "[PathA][continuation] candidate authority=" +
                "\(candidateAuthority.generation) attempt=\(repairIndex + 1) " +
                "sync=\(candidateAuthority.startsWithSyncSample ? 1 : 0) " +
                "packets=\(candidateAuthority.packetCount) " +
                "bytes=\(candidateAuthority.byteCount) " +
                "pts=\(candidateRange) " +
                "dts=" + formatOptionalMediaTime(candidateAuthority.firstDTS)
            )
            let candidateStartsAtOrBeforeTarget = candidateAuthority.decodeAnchorTime
                <= target + Self.videoContinuityAnchorToleranceSeconds
            let nearFutureNotBeforePTS = candidateDisposition.futureNotBeforePTS
            if let rejectedCandidate, let rejectedCandidateAuthority {
                let hasEarlierAnchor = candidateAuthority.decodeAnchorTime
                    < rejectedCandidateAuthority.decodeAnchorTime - 1e-6
                let hasDistinctCompressedSequence = !sameCompressedCandidate(
                    candidate,
                    rejectedCandidate
                )
                guard candidateAuthority.startsWithSyncSample,
                      candidateStartsAtOrBeforeTarget,
                      hasEarlierAnchor,
                      hasDistinctCompressedSequence else {
                    diagnostics.log(
                        "[PathA][continuation] renewed candidate rejected " +
                        "attempt=\(repairIndex + 1) " +
                        "brackets=\(candidateStartsAtOrBeforeTarget ? 1 : 0) " +
                        "earlier=\(hasEarlierAnchor ? 1 : 0) " +
                        "distinct=\(hasDistinctCompressedSequence ? 1 : 0) " +
                        "packets=\(candidateAuthority.packetCount)"
                    )
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
            } else if !candidateAuthority.startsWithSyncSample
                || (!candidateStartsAtOrBeforeTarget && nearFutureNotBeforePTS == nil) {
                guard repairIndex < Self.warmVideoDecoderRepairLimit else {
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
                diagnostics.log(
                    "[PathA][continuation] candidate lacks target pre-roll " +
                    "attempt=\(repairIndex + 1) " +
                    "sync=\(candidateAuthority.startsWithSyncSample ? 1 : 0) " +
                    "anchor=\(String(format: "%.3f", candidateAuthority.decodeAnchorTime)) " +
                    "target=\(String(format: "%.3f", target))"
                )
                rejectedCandidate = candidate
                rejectedCandidateAuthority = candidateAuthority
                continue
            }

            if let nearFutureNotBeforePTS {
                diagnostics.log(
                    "[PathA][continuation] candidateMode=near-future-image-hold " +
                    "lead=\(String(format: "%.3f", nearFutureNotBeforePTS - target)) " +
                    "notBefore=\(String(format: "%.3f", nearFutureNotBeforePTS)) " +
                    "foregroundFetchBytes=\(videoReadBytesDelta(since: token))"
                )
            }

            guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else {
                return abandonWarmVideoPreparation(run)
            }
            let attempt = beginWarmVideoPreparationAttempt(run: run, target: target)
            suspendedVideoFault = nil
            terminalVideoPreparationFailure = nil
            let triesRetainedPausedPiPDecoder = token.reason == .pipDidStop
                && !token.resumesPlayback
                && repairIndex == 0
                && suspendedVideoFault == nil
            let usedFreshDecoder = triesRetainedPausedPiPDecoder
                ? false
                : installFreshVideoDecoder(retiringCurrent: true, warmPreparationAttempt: attempt)
            if !usedFreshDecoder {
                guard triesRetainedPausedPiPDecoder || repairIndex == 0 else {
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
                await videoDecoder.flush()
            }
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                return abandonWarmVideoPreparation(run)
            }
            await openVideoDecoderIfNeeded(warmPreparationAttempt: attempt)
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                return abandonWarmVideoPreparation(run)
            }
            guard videoDecoderOpened else {
                retireCurrentVideoDecoderWithoutWaiting()
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }

            clearPendingVideoFrames()
            videoPackets = []
            residualVideoPackets = []
            videoPacketQueue.reset()
            resetOutputMediaFloor(to: nearFutureNotBeforePTS ?? target)
            activeWarmVideoImageHold = nil
            var candidateOverflowsQueue = false
            for packet in candidate {
                if candidateOverflowsQueue {
                    residualVideoPackets.append(packet)
                    continue
                }
                if !enqueueVideoPacket(packet) {
                    candidateOverflowsQueue = true
                    residualVideoPackets.append(packet)
                }
            }
            guard !videoPackets.isEmpty else {
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }

            isDecodingWarmVideoCandidate = true
            while !Task.isCancelled,
                  videoDecoderOpened,
                  suspendedVideoFault == nil,
                  warmVideoSubmissionsWithoutOutput
                    < Self.warmVideoNoOutputSubmissionLimit,
                  !videoPackets.isEmpty,
                  !warmVideoCandidateHasRequiredOutput(
                    disposition: candidateDisposition,
                    target: target
                  ) {
                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                    return abandonWarmVideoPreparation(run)
                }
                let packetCountBeforeDrain = videoPackets.count
                let frameCountBeforeDrain = pendingVideoFrames.count
                let residualCountBeforeDrain = residualVideoPackets.count
                let submissionsBeforeDrain = totalVideoPacketsSubmitted
                await drainVideoDecodeBurst(
                    generation: generation,
                    warmPreparationAttempt: attempt
                )
                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
                    return abandonWarmVideoPreparation(run)
                }
                if recovery.needsForwardRescue(
                    observation: warmVideoPreparationLedger.observation,
                    epsilon: outputMediaFloorEpsilon
                ) { break }
                if videoPackets.count == packetCountBeforeDrain,
                   pendingVideoFrames.count == frameCountBeforeDrain,
                   residualVideoPackets.count == residualCountBeforeDrain,
                   totalVideoPacketsSubmitted == submissionsBeforeDrain {
                    break
                }
            }
            if let fault = suspendedVideoFault, !isLocallyRepairableWarmVideoFault(fault) {
                retireCurrentVideoDecoderWithoutWaiting()
                return finishWarmVideoPreparation(token: token, failure: .decoderPreparationExhausted)
            }
            let context = WarmVideoCandidateContext(
                attempt: attempt, candidate: candidate, authority: candidateAuthority,
                target: target, disposition: candidateDisposition,
                provenance: suspendedVideoGOPProvenance
                    ?? .suspendEdge(readGeneration: token.videoReadGeneration),
                fetchedBytes: forwardReceipt == nil
                    ? videoReadBytesDelta(since: token) : forwardFetchedBytes,
                chaseByteCount: forwardReceipt == nil ? candidateAuthority.byteCount : forwardChargedBytes,
                chargedContentTailPTS: candidateAuthority.endPTS,
                decoderIdentity: ObjectIdentifier(videoDecoder)
            )
            let completion = await completeWarmVideoCandidate(
                context, run: run, recovery: &recovery
            )
            if warmPreparationTransaction.currentRun?.id == run.id {
                isDecodingWarmVideoCandidate = false
                isCollectingWarmVideoRunUp = false
            }
            switch completion {
            case .prepared:
                return .prepared
            case .cancelled:
                return abandonWarmVideoPreparation(run)
            case .exhausted:
                return finishWarmVideoPreparation(token: token, failure: .decoderPreparationExhausted)
            case let .repair(rejected):
                guard repairIndex < Self.warmVideoDecoderRepairLimit else {
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(token: token, failure: .decoderPreparationExhausted)
                }
                rejectedCandidate = rejected.candidate
                rejectedCandidateAuthority = rejected.authority
                activeWarmVideoImageHold = nil
                warmVideoPreparationLedger.retireAttempt()
                continue
            }

        }

        retireCurrentVideoDecoderWithoutWaiting()
        return finishWarmVideoPreparation(
            token: token,
            failure: .decoderPreparationExhausted
        )
    }

    private struct WarmVideoCandidateContext {
        let attempt: WarmVideoPreparationAttempt
        let candidate: [MediaPacket]
        let authority: MediaVideoContinuityCandidateAuthority
        let target: TimeInterval
        let disposition: WarmVideoCandidateDisposition
        let provenance: DemandVideoCandidateProvenance
        let fetchedBytes: Int
        let chaseByteCount: Int
        let chargedContentTailPTS: TimeInterval
        let decoderIdentity: ObjectIdentifier
    }

    private enum WarmVideoCandidateCompletion {
        case prepared
        case repair(WarmVideoCandidateContext)
        case exhausted
        case cancelled
    }

    private func warmVideoCandidateContextIsCurrent(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        requiresDecoderOpen: Bool = true
    ) -> Bool {
        warmVideoContinuationAuthorityIsCurrent(
            run: run, attempt: context.attempt, token: run.token,
            decoderIdentity: context.decoderIdentity, generation: context.attempt.engineGeneration,
            requiresDecoderOpen: requiresDecoderOpen
        ) && !videoDecoderWasRetired
    }

    private enum WarmVideoCandidateStep {
        case finished(WarmVideoCandidateCompletion)
        case needsRescue
    }

    private func completeWarmVideoCandidate(
        _ initial: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> WarmVideoCandidateCompletion {
        var context = initial
        while true {
            switch await evaluateWarmVideoCandidate(context, run: run, recovery: &recovery) {
            case .finished(let completion):
                return completion
            case .needsRescue:
                guard let rescued = await rescueWarmVideoCandidate(context, run: run, recovery: &recovery) else {
                    return warmVideoRescueFailure(context, run: run)
                }
                context = rescued
                guard await decodeWarmVideoCandidate(context, run: run, recovery: &recovery) else {
                    return .cancelled
                }
            }
        }
    }

    private func warmVideoCandidateFailure(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun
    ) -> WarmVideoCandidateCompletion? {
        guard warmVideoRunHasTime(run),
              warmVideoCandidateContextIsCurrent(context, run: run, requiresDecoderOpen: false) else {
            return .cancelled
        }
        if let fault = suspendedVideoFault {
            return isLocallyRepairableWarmVideoFault(fault) ? .repair(context) : .exhausted
        }
        return videoDecoderOpened ? nil : .repair(context)
    }

    private func warmVideoRescueFailure(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun
    ) -> WarmVideoCandidateCompletion {
        guard warmVideoRunHasTime(run), warmVideoRunIsCurrent(run) else { return .cancelled }
        if let fault = suspendedVideoFault, isLocallyRepairableWarmVideoFault(fault) {
            return .repair(context)
        }
        return .exhausted
    }

    private func evaluateWarmVideoCandidate(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> WarmVideoCandidateStep {
        if let failure = warmVideoCandidateFailure(context, run: run) { return .finished(failure) }
        if recovery.needsForwardRescue(
            observation: warmVideoPreparationLedger.observation, epsilon: outputMediaFloorEpsilon
        ) { return .needsRescue }
        guard warmVideoCandidateHasRequiredOutput(disposition: context.disposition, target: context.target) else {
            return .finished(.repair(context))
        }
        var continuationRecovery: WarmVideoRecoveryPolicy? = recovery
        let outcome = await continueWarmVideoPreparationToMovingTarget(
            run: run, attempt: context.attempt, token: run.token,
            startTarget: context.target, disposition: context.disposition,
            initialCandidateTailPTS: context.authority.endPTS,
            initialCandidateAnchorPTS: context.authority.decodeAnchorTime,
            initialCandidateByteCount: context.chaseByteCount,
            decoderIdentity: context.decoderIdentity,
            generation: context.attempt.engineGeneration, recovery: &continuationRecovery,
            initialChargedContentTailPTS: context.chargedContentTailPTS
        )
        if let continuationRecovery { recovery = continuationRecovery }
        if let failure = warmVideoCandidateFailure(context, run: run) { return .finished(failure) }
        return warmVideoCandidateStep(outcome, context: context, run: run)
    }

    private func warmVideoCandidateStep(
        _ outcome: WarmVideoMovingTargetContinuationOutcome,
        context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun
    ) -> WarmVideoCandidateStep {
        switch outcome {
        case let .covered(target, disposition, tail):
            isDecodingWarmVideoCandidate = false
            return .finished(commitWarmVideoCandidate(
                context, run: run, target: target, disposition: disposition, tail: tail
            ))
        case .needsForwardRescue:
            return .needsRescue
        case .retryLocal:
            return .finished(.repair(context))
        case .tailExpired:
            if case .nearFutureImageHold = context.disposition { return .finished(.repair(context)) }
            return .finished(.exhausted)
        case .exhausted:
            return .finished(.exhausted)
        case .cancelled:
            return .finished(.cancelled)
        }
    }

    private func commitWarmVideoCandidate(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        target: TimeInterval,
        disposition: WarmVideoCandidateDisposition,
        tail: TimeInterval
    ) -> WarmVideoCandidateCompletion {
        guard warmVideoRunHasTime(run) else { return .cancelled }
        guard warmVideoCandidateContextIsCurrent(context, run: run) else { return .cancelled }
        let liveAudio = audioPresentationMediaTime
        guard liveAudio.isFinite else { return .exhausted }
        let commitTarget = max(target, max(liveAudio, outputMediaFloor))
        guard commitTarget.isFinite, suspendedVideoFault == nil,
              warmVideoCandidateHasRequiredOutput(disposition: disposition, target: commitTarget) else {
            return .exhausted
        }
        advanceOutputMediaFloor(to: commitTarget, reason: "warm-commit")
        if let notBefore = disposition.futureNotBeforePTS {
            activeWarmVideoImageHold = WarmVideoImageHoldSnapshot(
                runID: run.id, token: run.token, sessionGeneration: runtimeGeneration,
                engineGeneration: generation, ownerGeneration: activeOwnerGeneration,
                candidateAuthorityGeneration: context.authority.generation,
                candidateProvenance: context.provenance, notBeforePTS: notBefore,
                candidateTailPTS: tail, foregroundFetchBytes: context.fetchedBytes,
                rateRevision: playbackRateRevision, renderGeneration: nil,
                hasReachedAudioDueTime: false
            )
            guard let hold = activeWarmVideoImageHold,
                  commitTarget <= tail + Self.videoContinuityAnchorToleranceSeconds,
                  warmVideoImageHoldIsCurrent(hold, requiresActiveSuspendToken: true) else {
                activeWarmVideoImageHold = nil
                return .exhausted
            }
        }
        suspendedVideoFault = nil
        terminalVideoPreparationFailure = nil
        warmVideoPreparationLedger.retireAttempt()
        isVideoLanePreparedForForeground = true
        diagnostics.log(
            "[PathA][continuation] video prepared token=\(run.token.generation) " +
                "candidateMode=\(disposition.diagnosticName) " +
                "target=\(String(format: "%.3f", commitTarget)) " +
                "pending=\(pendingVideoFrames.count)"
        )
        return .prepared
    }

    private func decodeWarmVideoCandidate(
        _ context: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> Bool {
        isDecodingWarmVideoCandidate = true
        while !Task.isCancelled, videoDecoderOpened, suspendedVideoFault == nil,
              warmVideoSubmissionsWithoutOutput < Self.warmVideoNoOutputSubmissionLimit,
              !videoPackets.isEmpty,
              !warmVideoCandidateHasRequiredOutput(disposition: context.disposition, target: context.target) {
            guard warmVideoRunHasTime(run), warmVideoCandidateContextIsCurrent(context, run: run) else { return false }
            let packets = videoPackets.count
            let frames = pendingVideoFrames.count
            let residual = residualVideoPackets.count
            let submissions = totalVideoPacketsSubmitted
            await drainVideoDecodeBurst(
                generation: context.attempt.engineGeneration, warmPreparationAttempt: context.attempt
            )
            guard warmVideoRunHasTime(run),
                  warmVideoCandidateContextIsCurrent(context, run: run, requiresDecoderOpen: false) else {
                return false
            }
            if recovery.needsForwardRescue(
                observation: warmVideoPreparationLedger.observation, epsilon: outputMediaFloorEpsilon
            ) { break }
            if videoPackets.count == packets, pendingVideoFrames.count == frames,
               residualVideoPackets.count == residual, totalVideoPacketsSubmitted == submissions { break }
        }
        return true
    }

    private func enqueueWarmVideoCandidate(_ candidate: [MediaPacket], target: TimeInterval) {
        clearPendingVideoFrames()
        videoPackets = []
        residualVideoPackets = []
        videoPacketQueue.reset()
        advanceOutputMediaFloor(to: target, reason: "warm-rescue-input")
        activeWarmVideoImageHold = nil
        var overflows = false
        for packet in candidate {
            if overflows || !enqueueVideoPacket(packet) {
                overflows = true
                residualVideoPackets.append(packet)
            }
        }
    }

    private func rescueWarmVideoCandidate(
        _ rejected: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> WarmVideoCandidateContext? {
        guard warmVideoRunHasTime(run), warmVideoCandidateContextIsCurrent(rejected, run: run),
              suspendedVideoFault == nil, recovery.claimRescue() else { return nil }
        isDecodingWarmVideoCandidate = false
        let previousDecode = decodeTask
        cancelVideoDecode(clearHandle: false)
        await previousDecode?.value
        guard warmVideoRunHasTime(run), warmVideoCandidateContextIsCurrent(rejected, run: run),
              suspendedVideoFault == nil else { return nil }
        decodeTask = nil
        packetRelay.reset()
        clearPendingVideoFrames()
        videoPackets = []
        residualVideoPackets = []
        videoPacketQueue.reset()
        activeWarmVideoImageHold = nil
        suspendedVideoGOP = []
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPProvenance = nil
        let attemptTarget = audioPresentationMediaTime
        guard attemptTarget.isFinite, attemptTarget >= rejected.authority.anchorPTS else { return nil }
        warmVideoPreparationLedger.retireAttempt()
        let attempt = beginWarmVideoPreparationAttempt(run: run, target: attemptTarget)
        await videoDecoder.flush()
        guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
              ObjectIdentifier(videoDecoder) == rejected.decoderIdentity,
              videoDecoderOpened, !videoDecoderWasRetired, suspendedVideoFault == nil else { return nil }
        let target = audioPresentationMediaTime
        guard target.isFinite, target >= rejected.authority.anchorPTS else { return nil }
        let phaseStarted = ContinuousClock.now
        let phaseAllowance = min(warmVideoPreparationDeadline, recovery.remaining(at: phaseStarted))
        guard phaseAllowance > .zero else { return nil }
        return await selectRescuedWarmVideoCandidate(
            rejected, run: run, attempt: attempt, target: target,
            phase: (startedAt: phaseStarted, allowance: phaseAllowance)
        )
    }

    private func selectRescuedWarmVideoCandidate(
        _ rejected: WarmVideoCandidateContext,
        run: WarmVideoPreparationRun,
        attempt: WarmVideoPreparationAttempt,
        target: TimeInterval,
        phase: (startedAt: ContinuousClock.Instant, allowance: Duration)
    ) async -> WarmVideoCandidateContext? {
        let rateRevision = playbackRateRevision
        do {
            resetCachedRunway(video: true, audio: false)
            let selected = try await demux.prepareForwardVideoContinuity(MediaVideoForwardRequest(
                target: target, playbackRate: Double(playbackRate), wallAllowance: phase.allowance,
                maximumCompressedBytes: Self.suspendedVideoGOPMaxBytes,
                maximumContentSpan: Self.suspendedVideoGOPMaxContentSeconds
            ))
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == rejected.decoderIdentity,
                  playbackRateRevision == rateRevision, videoDecoderOpened,
                  !videoDecoderWasRetired, suspendedVideoFault == nil,
                  phase.startedAt.duration(to: .now) < phase.allowance,
                  case .positioned(let receipt) = selected,
                  receipt.sampledTarget == target, receipt.anchorPTS > target,
                  receipt.anchorPTS > rejected.authority.anchorPTS else { return nil }
            isCollectingWarmVideoRunUp = true
            let collection = try await collectForwardVideoCandidate(
                receipt: receipt, run: run, phaseStarted: phase.startedAt,
                phaseAllowance: phase.allowance, attempt: attempt
            )
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == rejected.decoderIdentity,
                  playbackRateRevision == rateRevision, videoDecoderOpened,
                  !videoDecoderWasRetired, suspendedVideoFault == nil,
                  let candidate = suspendedVideoCandidate(at: target) else { return nil }
            isCollectingWarmVideoRunUp = false
            let disposition = classifyForwardVideoCandidate(candidate, receipt: receipt, target: target)
            guard disposition != .requiresPositioning else { return nil }
            let authority = recordWarmVideoCandidateAuthority(candidate)
            enqueueWarmVideoCandidate(candidate, target: disposition.futureNotBeforePTS ?? target)
            return WarmVideoCandidateContext(
                attempt: attempt, candidate: candidate, authority: authority, target: target,
                disposition: disposition, provenance: .forwardPositioned(receipt),
                fetchedBytes: collection.fetchedBytes, chaseByteCount: collection.chargedBytes,
                chargedContentTailPTS: authority.endPTS,
                decoderIdentity: rejected.decoderIdentity
            )
        } catch {
            _ = warmVideoRunHasTime(run)
            return nil
        }
    }

    private func warmVideoContinuationAuthorityIsCurrent(
        run: WarmVideoPreparationRun?,
        attempt: WarmVideoPreparationAttempt?,
        token: DemandVideoSuspendToken,
        decoderIdentity: ObjectIdentifier,
        generation: Int,
        requiresDecoderOpen: Bool = true
    ) -> Bool {
        guard !Task.isCancelled,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration,
              generation == self.generation,
              ObjectIdentifier(videoDecoder) == decoderIdentity else {
            return false
        }
        guard !requiresDecoderOpen || videoDecoderOpened else { return false }
        if let run, let attempt {
            return warmPreparationTransaction.currentRun?.id == run.id
                && isCurrentWarmVideoPreparationAttempt(attempt)
        }
        return isVideoLaneWarmSuspended
    }

    private enum WarmVideoMovingTargetContinuationOutcome {
        case covered(
            target: TimeInterval,
            disposition: WarmVideoCandidateDisposition,
            candidateTailPTS: TimeInterval
        )
        case retryLocal
        case needsForwardRescue
        case tailExpired
        case exhausted
        case cancelled
    }

    private func exhaustedByWarmChaseLimit(
        _ limit: String,
        measured: String
    ) -> WarmVideoMovingTargetContinuationOutcome {
        diagnostics.log(
            "[PathA][continuation] warm chase exhausted limit=\(limit) \(measured)"
        )
        return .exhausted
    }

    private func continueWarmVideoPreparationToMovingTarget(
        run: WarmVideoPreparationRun?,
        attempt: WarmVideoPreparationAttempt?,
        token: DemandVideoSuspendToken,
        startTarget: TimeInterval,
        disposition: WarmVideoCandidateDisposition,
        initialCandidateTailPTS: TimeInterval,
        initialCandidateAnchorPTS: TimeInterval,
        initialCandidateByteCount: Int,
        decoderIdentity: ObjectIdentifier,
        generation: Int,
        recovery: inout WarmVideoRecoveryPolicy?,
        initialChargedContentTailPTS: TimeInterval? = nil
    ) async -> WarmVideoMovingTargetContinuationOutcome {
        guard startTarget.isFinite,
              initialCandidateTailPTS.isFinite,
              initialCandidateAnchorPTS.isFinite,
              initialChargedContentTailPTS?.isFinite ?? true,
              initialCandidateByteCount >= 0,
              initialCandidateByteCount <= Self.suspendedVideoWindowMaxBytes else {
            return .exhausted
        }
        guard !Task.isCancelled,
              warmVideoContinuationAuthorityIsCurrent(
                  run: run,
                  attempt: attempt,
                  token: token,
                  decoderIdentity: decoderIdentity,
                  generation: generation
              ) else {
            return .cancelled
        }

        var currentTarget = startTarget
        var currentDisposition = disposition
        var candidateTailPTS = initialCandidateTailPTS
        var candidateByteCount = initialCandidateByteCount
        var chargedContentTailPTS = max(
            initialCandidateTailPTS, initialChargedContentTailPTS ?? initialCandidateTailPTS
        )
        var noProgressBatches = 0
        let startedAsNearFutureImageHold: Bool = {
            if case .nearFutureImageHold = disposition { return true }
            return false
        }()
        let continuationStarted = ContinuousClock.now

        var loggedReadBytesWouldExhaustHit = false
        defer {
            if loggedReadBytesWouldExhaustHit {
                diagnostics.log(
                    "[PathA][continuation] would-exhaust summary limit=readBytes " +
                        "final=\(videoReadBytesDelta(since: token)) " +
                        "cap=\(Self.suspendedVideoGOPMaxBytes)"
                )
            }
        }

        while !Task.isCancelled {
            if let run, !warmVideoRunHasTime(run) { return .cancelled }
            guard warmVideoContinuationAuthorityIsCurrent(
                run: run,
                attempt: attempt,
                token: token,
                decoderIdentity: decoderIdentity,
                generation: generation
            ) else {
                return .cancelled
            }

            if let run {
                guard warmVideoRunHasTime(run) else { return .cancelled }
                if recovery?.needsForwardRescue(
                    observation: warmVideoPreparationLedger.observation,
                    epsilon: outputMediaFloorEpsilon
                ) == true { return .needsForwardRescue }
            }
            guard run != nil || continuationStarted.duration(to: ContinuousClock.now)
                    < Self.warmVideoDirectWallLimit else {
                diagnostics.log(
                    "[PathA][continuation] moving target budget exhausted " +
                    "start=\(String(format: "%.3f", startTarget)) " +
                    "current=\(String(format: "%.3f", currentTarget))"
                )
                return .exhausted
            }

            let sampledAudioTarget = audioPresentationMediaTime
            guard sampledAudioTarget.isFinite else { return .exhausted }
            if sampledAudioTarget > currentTarget {
                currentTarget = sampledAudioTarget
            }
            advanceOutputMediaFloor(to: currentTarget, reason: "warm-moving-target")

            if let notBeforePTS = currentDisposition.futureNotBeforePTS,
               currentTarget + Self.videoContinuityAnchorToleranceSeconds
                    >= notBeforePTS {
                currentDisposition = .bracketingPreRoll
                activeWarmVideoImageHold = nil
            }

            let requiredTarget: TimeInterval
            requiredTarget = max(currentTarget, currentDisposition.futureNotBeforePTS ?? currentTarget)
            if warmVideoCandidateHasRequiredOutput(
                disposition: currentDisposition,
                target: requiredTarget
            ) {
                return .covered(
                    target: currentTarget,
                    disposition: currentDisposition,
                    candidateTailPTS: candidateTailPTS
                )
            }

            let packetsBefore = videoPackets.count
            let pendingBefore = pendingVideoFrames.count
            let residualBefore = residualVideoPackets.count
            let submittedBefore = totalVideoPacketsSubmitted
            var madeProgress = false
            if !videoPackets.isEmpty {
                await drainVideoDecodeBurst(
                    generation: generation,
                    warmPreparationAttempt: attempt
                )
                if let run, !warmVideoRunHasTime(run) { return .cancelled }
                guard warmVideoContinuationAuthorityIsCurrent(
                    run: run,
                    attempt: attempt,
                    token: token,
                    decoderIdentity: decoderIdentity,
                    generation: generation,
                    requiresDecoderOpen: false
                ) else {
                    return .cancelled
                }
                madeProgress = videoPackets.count != packetsBefore
                    || pendingVideoFrames.count != pendingBefore
                    || residualVideoPackets.count != residualBefore
                    || totalVideoPacketsSubmitted != submittedBefore
            } else {
                let readGeneration = beginVideoReadGeneration()
                let packets: [MediaPacket]
                do {
                    let diagnosticPumpStart = ContinuousClock.now
                    defer {
                        if warmDiagnosticAttemptIsCurrent(attempt) {
                            activeWarmDiagnostics?.demuxWaitTime += diagnosticPumpStart.duration(to: .now)
                            activeWarmDiagnostics?.pumps += 1
                        }
                    }
                    resetCachedRunway(video: true, audio: false)
                    if case .positionedFutureImageHold = currentDisposition {
                        return .exhausted
                    }
                    packets = try await demux.pump(
                        videoBudget: 1,
                        audioBudget: 0
                    )
                } catch {
                    if let run, !warmVideoRunHasTime(run) { return .cancelled }
                    guard warmVideoContinuationAuthorityIsCurrent(
                        run: run,
                        attempt: attempt,
                        token: token,
                        decoderIdentity: decoderIdentity,
                        generation: generation
                    ) else {
                        return .cancelled
                    }
                    diagnostics.log(
                        "[PathA][continuation] moving target pump failed " +
                        "start=\(String(format: "%.3f", startTarget)) " +
                        "current=\(String(format: "%.3f", currentTarget))"
                    )
                    return .exhausted
                }
                if let run, !warmVideoRunHasTime(run) { return .cancelled }
                guard warmVideoContinuationAuthorityIsCurrent(
                    run: run,
                    attempt: attempt,
                    token: token,
                    decoderIdentity: decoderIdentity,
                    generation: generation
                ) else {
                    return .cancelled
                }
                if packets.isEmpty {
                    let reachedEOF = await demux.isEOF
                    if let run, !warmVideoRunHasTime(run) { return .cancelled }
                guard warmVideoContinuationAuthorityIsCurrent(
                            run: run, attempt: attempt, token: token,
                            decoderIdentity: decoderIdentity, generation: generation
                          ) else { return .cancelled }
                    if reachedEOF { return .exhausted }
                } else {
                    madeProgress = true
                    ingest(
                        packets,
                        videoReadGeneration: readGeneration,
                        warmVideoProvenance: .positioned(
                            readGeneration: readGeneration
                        )
                    )
                    drainResidualPackets()
                    for packet in packets where packet.track == .video {
                        guard let packetEnd = finiteMediaIntervalEnd(
                            start: packet.pts,
                            duration: packet.duration
                        ) else { return .exhausted }
                        let (updatedByteCount, byteCountOverflowed) =
                            candidateByteCount.addingReportingOverflow(packet.data.count)
                        guard !byteCountOverflowed,
                              updatedByteCount <= Self.suspendedVideoGOPMaxBytes else {
                            return exhaustedByWarmChaseLimit(
                                "candidateBytes",
                                measured: "bytes=\(updatedByteCount) " +
                                    "cap=\(Self.suspendedVideoGOPMaxBytes) " +
                                    "overflow=\(byteCountOverflowed ? 1 : 0)"
                            )
                        }
                        candidateByteCount = updatedByteCount
                        candidateTailPTS = max(
                            candidateTailPTS,
                            packetEnd
                        )
                        chargedContentTailPTS = max(chargedContentTailPTS, packetEnd)
                        guard chargedContentTailPTS - initialCandidateAnchorPTS
                                <= Self.warmVideoDirectContentSpanLimit + 1e-9 else {
                            return exhaustedByWarmChaseLimit(
                                "contentSpan",
                                measured: "span=" + String(
                                    format: "%.3f",
                                    chargedContentTailPTS - initialCandidateAnchorPTS
                                ) + " cap=" + String(
                                    format: "%.3f",
                                    Self.warmVideoDirectContentSpanLimit
                                )
                            )
                        }
                    }
                }
            }

            let readBytesDelta = videoReadBytesDelta(since: token)
            if readBytesDelta > Self.suspendedVideoGOPMaxBytes,
               !loggedReadBytesWouldExhaustHit {
                loggedReadBytesWouldExhaustHit = true
                diagnostics.log(
                    "[PathA][continuation] would-exhaust limit=readBytes " +
                        "bytes=\(readBytesDelta) " +
                        "cap=\(Self.suspendedVideoGOPMaxBytes)"
                )
            }

            if let fault = suspendedVideoFault {
                return isLocallyRepairableWarmVideoFault(fault)
                    ? .retryLocal
                    : .exhausted
            }
            guard videoDecoderOpened else { return .exhausted }
            madeProgress = madeProgress
                || videoPackets.count != packetsBefore
                || pendingVideoFrames.count != pendingBefore
                || residualVideoPackets.count != residualBefore
                || totalVideoPacketsSubmitted != submittedBefore
            if !madeProgress {
                noProgressBatches += 1
            } else {
                noProgressBatches = 0
            }
            if warmVideoSubmissionsWithoutOutput
                    >= Self.warmVideoNoOutputSubmissionLimit {
                return .retryLocal
            }
            if noProgressBatches >= Self.warmVideoDirectNoProgressLimit {
                if startedAsNearFutureImageHold,
                   currentTarget
                        > candidateTailPTS
                            + Self.videoContinuityAnchorToleranceSeconds,
                   videoPackets.isEmpty {
                    diagnostics.log(
                        "[PathA][continuation] near-future tail expired " +
                        "target=\(String(format: "%.3f", currentTarget)) " +
                        "tail=\(String(format: "%.3f", candidateTailPTS))"
                    )
                    return .tailExpired
                }
                return .exhausted
            }
        }
        return Task.isCancelled ? .cancelled : .exhausted
    }

    private func pendingVideoFrameEndPTS() -> TimeInterval? {
        pendingVideoFrames
            .filter { $0.pts.isFinite && $0.duration.isFinite && $0.duration > 0 }
            .map { $0.pts + $0.duration }
            .filter(\.isFinite)
            .max()
    }

    private func videoPacketEndPTS() -> TimeInterval? {
        var result: TimeInterval?
        for packet in videoPackets {
            guard packet.pts.isFinite, packet.duration.isFinite, packet.duration > 0 else { continue }
            let end = packet.pts + packet.duration
            guard end.isFinite else { continue }
            result = result.map { max($0, end) } ?? end
        }
        for packet in residualVideoPackets {
            guard packet.pts.isFinite, packet.duration.isFinite, packet.duration > 0 else { continue }
            let end = packet.pts + packet.duration
            guard end.isFinite else { continue }
            result = result.map { max($0, end) } ?? end
        }
        return result
    }

    private func finiteMediaIntervalEnd(
        start: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard start.isFinite, duration.isFinite, duration >= 0 else {
            return nil
        }
        let end = start + duration
        return end.isFinite ? end : nil
    }

    private struct ForwardVideoCollection {
        var chargedBytes = 0
        var fetchedBytes = 0
        var noProgressBatches = 0
    }

    private func collectForwardVideoCandidate(
        receipt: MediaVideoForwardReceipt,
        run: WarmVideoPreparationRun,
        phaseStarted: ContinuousClock.Instant,
        phaseAllowance: Duration,
        attempt: WarmVideoPreparationAttempt? = nil
    ) async throws -> ForwardVideoCollection {
        var collection = ForwardVideoCollection(
            chargedBytes: receipt.selectionFetchBytes,
            fetchedBytes: receipt.selectionFetchBytes
        )
        let rateRevision = playbackRateRevision
        let decoderIdentity = ObjectIdentifier(videoDecoder)
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard warmVideoRunIsCurrent(run),
                  warmVideoForwardAttemptIsCurrent(attempt, decoderIdentity: decoderIdentity),
                  activeVideoSuspendToken == run.token,
                  playbackRateRevision == rateRevision,
                  Double(playbackRate) == receipt.playbackRate,
                  warmVideoRunHasTime(run),
                  phaseStarted.duration(to: .now) < phaseAllowance else {
                throw MediaEngineError.stopped
            }
            let readGeneration = beginVideoReadGeneration()
            let pumpStarted = ContinuousClock.now
            let outcome = try await demux.pumpPositionedVideoContinuity(
                readGeneration: readGeneration, contentBudget: 1
            )
            if warmPreparationAttemptIsActive(runID: run.id) {
                activeWarmDiagnostics?.demuxWaitTime += pumpStarted.duration(to: .now)
                activeWarmDiagnostics?.pumps += 1
            }
            try Task.checkCancellation()
            guard warmVideoRunIsCurrent(run),
                  warmVideoForwardAttemptIsCurrent(attempt, decoderIdentity: decoderIdentity),
                  activeVideoSuspendToken == run.token,
                  playbackRateRevision == rateRevision,
                  run.sessionGeneration == runtimeGeneration,
                  run.engineGeneration == generation,
                  run.ownerGeneration == activeOwnerGeneration,
                  warmVideoRunHasTime(run),
                  phaseStarted.duration(to: .now) < phaseAllowance,
                  case .supported(let batch) = outcome else { throw MediaEngineError.stopped }
            try acceptForwardVideoBatch(
                batch, receipt: receipt, readGeneration: readGeneration,
                collection: &collection
            )
            if batch.forwardReferenceExhausted {
                guard forwardCandidateHasDistinctPTS(suspendedVideoGOP) else { break }
                return collection
            }
            guard !batch.reachedEOF,
                  collection.noProgressBatches < Self.warmVideoDirectNoProgressLimit else { break }
        }
        throw MediaEngineError.demuxFailed("forward continuity has no bounded sync candidate")
    }

    private func warmVideoForwardAttemptIsCurrent(
        _ attempt: WarmVideoPreparationAttempt?,
        decoderIdentity: ObjectIdentifier
    ) -> Bool {
        guard let attempt else { return true }
        return isCurrentWarmVideoPreparationAttempt(attempt) && videoDecoderOpened
            && !videoDecoderWasRetired && ObjectIdentifier(videoDecoder) == decoderIdentity
    }

    private func acceptForwardVideoBatch(
        _ batch: MediaVideoContinuityBatch,
        receipt: MediaVideoForwardReceipt,
        readGeneration: UInt64,
        collection: inout ForwardVideoCollection
    ) throws {
        let charged = collection.chargedBytes.addingReportingOverflow(batch.compressedByteCount)
        let fetched = collection.fetchedBytes.addingReportingOverflow(batch.fetchedByteCount)
        guard batch.forwardReceipt == receipt,
              batch.readerMutationGeneration == receipt.readerMutationGeneration,
              batch.readGeneration == readGeneration,
              batch.compressedByteCount >= 0, batch.fetchedByteCount >= 0,
              !charged.overflow, !fetched.overflow,
              charged.partialValue <= Self.suspendedVideoGOPMaxBytes,
              batch.packets.allSatisfy({ packet in
                packet.track == .video && packet.pts.isFinite
                    && (packet.dts?.isFinite ?? true)
                    && packet.duration.isFinite && packet.duration >= 0
                    && packet.pts >= receipt.contentInterval.start - 1e-9
                    && packet.pts + packet.duration <= receipt.contentInterval.end + 1e-9
              }) else { throw MediaEngineError.demuxFailed("forward continuity receipt mismatch") }
        if suspendedVideoGOP.isEmpty, let first = batch.packets.first {
            guard first.isKeyframe, abs(first.pts - receipt.anchorPTS) <= 1e-9 else {
                throw MediaEngineError.demuxFailed("forward continuity lacks proven first sync sample")
            }
        }
        collection.chargedBytes = charged.partialValue
        collection.fetchedBytes = fetched.partialValue
        collection.noProgressBatches = batch.madeProgress ? 0 : collection.noProgressBatches + 1
        ingest(
            batch.packets, videoReadGeneration: readGeneration,
            warmVideoProvenance: .forwardPositioned(receipt)
        )
    }

    private func forwardCandidateHasDistinctPTS(_ candidate: [MediaPacket]) -> Bool {
        guard let first = candidate.first, first.isKeyframe, first.pts.isFinite else { return false }
        return candidate.dropFirst().contains { $0.pts.isFinite && abs($0.pts - first.pts) > 1e-9 }
    }

    private func classifyForwardVideoCandidate(
        _ candidate: [MediaPacket],
        receipt: MediaVideoForwardReceipt,
        target: TimeInterval
    ) -> WarmVideoCandidateDisposition {
        guard forwardCandidateHasDistinctPTS(candidate), let first = candidate.first,
              suspendedVideoGOPProvenance == .forwardPositioned(receipt),
              target.isFinite, receipt.anchorPTS.isFinite,
              abs(first.pts - receipt.anchorPTS) <= 1e-9,
              Double(playbackRate) == receipt.playbackRate else { return .requiresPositioning }
        if receipt.anchorPTS <= target + Self.videoContinuityAnchorToleranceSeconds {
            return .bracketingPreRoll
        }
        let lead = receipt.anchorPTS - audioPresentationMediaTime
        guard lead.isFinite, lead <= receipt.maximumLead,
              playbackRate > 0,
              lead / Double(playbackRate) <= Double(warmVideoPreparationDeadline / .seconds(1)) else {
            return .requiresPositioning
        }
        return .positionedFutureImageHold(receipt)
    }

    private func performRenewedWarmVideoStreaming(
        run: WarmVideoPreparationRun,
        token: DemandVideoSuspendToken,
        target: TimeInterval,
        rejectedCandidate: [MediaPacket],
        rejectedCandidateAuthority: MediaVideoContinuityCandidateAuthority,
        generation: Int,
        started: ContinuousClock.Instant,
        recovery: inout WarmVideoRecoveryPolicy
    ) async -> DemandVideoLanePreparationResult {
        guard warmVideoRunHasTime(run), target.isFinite,
              !Task.isCancelled,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration,
              warmPreparationTransaction.currentRun?.id == run.id else {
            return cancelRenewedWarmVideoPreparation(run: run)
        }

        let attempt = beginWarmVideoPreparationAttempt(run: run, target: target)
        suspendedVideoFault = nil
        terminalVideoPreparationFailure = nil
        activeWarmVideoImageHold = nil
        isCollectingWarmVideoRunUp = false
        clearPendingVideoFrames()
        videoPackets = []
        residualVideoPackets = []
        videoPacketQueue.reset()
        resetCachedRunway(video: true, audio: false)
        packetRelay.reset()
        guard installFreshVideoDecoder(retiringCurrent: true, warmPreparationAttempt: attempt) else {
            return failRenewedWarmVideoPreparation(token: token)
        }
        guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
            return cancelRenewedWarmVideoPreparation(run: run)
        }
        guard started.duration(to: ContinuousClock.now)
                < Self.warmVideoDirectWallLimit else {
            return failRenewedWarmVideoPreparation(token: token)
        }
        await openVideoDecoderIfNeeded(
            expectedGeneration: attempt.engineGeneration,
            warmPreparationAttempt: attempt
        )
        guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt) else {
            return cancelRenewedWarmVideoPreparation(run: run)
        }
        guard videoDecoderOpened else { return failRenewedWarmVideoPreparation(token: token) }
        guard started.duration(to: ContinuousClock.now)
                < Self.warmVideoDirectWallLimit else {
            return failRenewedWarmVideoPreparation(token: token)
        }

        let decoderIdentity = ObjectIdentifier(videoDecoder)
        resetOutputMediaFloor(to: target)
        isDecodingWarmVideoCandidate = true
        var directPacketCount = 0
        var directCompressedPacketBytes = 0
        var directAnchorPTS: TimeInterval?
        var directFirstDTS: TimeInterval?
        var directContentStartPTS: TimeInterval?
        var directEndPTS = -TimeInterval.infinity
        var directStartsWithSyncSample = false
        var directCandidateMatchesRejected = true
        var positionedReaderGeneration: UInt64?
        var compressedBytes = 0
        var noProgressBatches = 0
        while true {
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return cancelRenewedWarmVideoPreparation(run: run)
            }
            guard started.duration(to: ContinuousClock.now)
                    < Self.warmVideoDirectWallLimit else {
                return failRenewedWarmVideoPreparation(token: token)
            }

            let readGeneration = beginVideoReadGeneration()
            let batchOutcome: MediaVideoContinuityBatchOutcome
            do {
                let diagnosticPumpStart = ContinuousClock.now
                defer {
                    if warmDiagnosticAttemptIsCurrent(attempt) {
                        activeWarmDiagnostics?.demuxWaitTime += diagnosticPumpStart.duration(to: .now)
                        activeWarmDiagnostics?.pumps += 1
                    }
                }
                resetCachedRunway(video: true, audio: false)
                batchOutcome = try await demux.pumpPositionedVideoContinuity(
                    readGeneration: readGeneration,
                    contentBudget: 1
                )
            } catch {
                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                      ObjectIdentifier(videoDecoder) == decoderIdentity else {
                    return cancelRenewedWarmVideoPreparation(run: run)
                }
                diagnostics.log(
                    "[PathA][continuation] direct positioned stream failed " +
                    "error=\(error.localizedDescription)"
                )
                return failRenewedWarmVideoPreparation(token: token)
            }
            guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return cancelRenewedWarmVideoPreparation(run: run)
            }

            switch batchOutcome {
            case .unsupported(let reason):
                diagnostics.log(
                    "[PathA][continuation] direct positioned stream unsupported " +
                    "reason=\(reason.rawValue)"
                )
                return failRenewedWarmVideoPreparation(token: token)

            case .supported(let batch):
                guard batch.readGeneration == readGeneration,
                      batch.compressedByteCount >= 0 else {
                    return failRenewedWarmVideoPreparation(token: token)
                }
                if let positionedReaderGeneration {
                    guard positionedReaderGeneration == batch.readerMutationGeneration else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                } else {
                    positionedReaderGeneration = batch.readerMutationGeneration
                }

                let (updatedBytes, bytesOverflowed) = compressedBytes
                    .addingReportingOverflow(batch.compressedByteCount)
                guard !bytesOverflowed,
                      updatedBytes <= Self.suspendedVideoGOPMaxBytes else {
                    diagnostics.log(
                        "[PathA][continuation] direct positioned byte budget exhausted " +
                        "bytes=\(updatedBytes)"
                    )
                    return failRenewedWarmVideoPreparation(token: token)
                }
                compressedBytes = updatedBytes

                if let interval = batch.contentInterval {
                    guard interval.start.isFinite,
                          interval.end.isFinite,
                          interval.end >= interval.start else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    directContentStartPTS = directContentStartPTS ?? interval.start
                }
                if let frontier = batch.contentFrontier {
                    guard frontier.isFinite else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                }

                if !batch.packets.isEmpty {
                    guard batch.packets.allSatisfy({ packet in
                        packet.track == .video
                            && packet.pts.isFinite
                            && packet.duration.isFinite
                            && packet.duration >= 0
                    }) else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    let (batchPacketBytes, packetBytesOverflowed) = batch.packets.reduce(
                        into: (total: 0, overflowed: false)
                    ) { result, packet in
                        guard !result.overflowed else { return }
                        let (updated, overflowed) = result.total.addingReportingOverflow(
                            packet.data.count
                        )
                        result.total = updated
                        result.overflowed = overflowed
                    }
                    guard !packetBytesOverflowed,
                          batchPacketBytes <= batch.compressedByteCount else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    if directPacketCount == 0 {
                        guard let first = batch.packets.first else {
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        let firstAnchor = first.dts?.isFinite == true
                            ? first.dts!
                            : first.pts
                        guard first.isKeyframe,
                              firstAnchor.isFinite,
                              firstAnchor
                                <= target + Self.videoContinuityAnchorToleranceSeconds else {
                            diagnostics.log(
                                "[PathA][continuation] direct sequence lacks sync root"
                            )
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        directAnchorPTS = first.pts
                        directFirstDTS = first.dts?.isFinite == true
                            ? first.dts
                            : nil
                        directStartsWithSyncSample = first.isKeyframe
                    }
                    for packet in batch.packets {
                        guard let packetEnd = finiteMediaIntervalEnd(
                            start: packet.pts,
                            duration: packet.duration
                        ) else {
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        if directCandidateMatchesRejected {
                            if directPacketCount >= rejectedCandidate.count {
                                directCandidateMatchesRejected = false
                            } else if !sameCompressedPacket(
                                packet,
                                rejectedCandidate[directPacketCount]
                            ) {
                                directCandidateMatchesRejected = false
                            }
                        }
                        directPacketCount += 1
                        let (updatedPacketBytes, packetBytesOverflowed) =
                            directCompressedPacketBytes.addingReportingOverflow(
                                packet.data.count
                            )
                        guard !packetBytesOverflowed else {
                            return failRenewedWarmVideoPreparation(token: token)
                        }
                        directCompressedPacketBytes = updatedPacketBytes
                        directEndPTS = max(
                            directEndPTS,
                            packetEnd
                        )
                    }
                    ingest(
                        batch.packets,
                        videoReadGeneration: readGeneration,
                        warmVideoProvenance: .positioned(
                            readGeneration: readGeneration
                        )
                    )
                    drainResidualPackets()
                }

                let contentFrontier = max(
                    batch.contentFrontier
                        ?? batch.contentInterval?.end
                        ?? -TimeInterval.infinity,
                    directEndPTS
                )
                if let firstAnchor = directFirstDTS
                    ?? directAnchorPTS
                    ?? directContentStartPTS,
                   contentFrontier.isFinite {
                    guard contentFrontier >= firstAnchor,
                          contentFrontier - firstAnchor
                            <= Self.warmVideoDirectContentSpanLimit + 1e-9 else {
                        diagnostics.log(
                            "[PathA][continuation] direct positioned content budget exhausted " +
                            "span=\(String(format: "%.3f", contentFrontier - firstAnchor))"
                        )
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                }

                while !videoPackets.isEmpty,
                      !warmVideoCandidateHasRequiredOutput(
                        disposition: .requiresPositioning,
                        target: target
                      ) {
                    let packetsBefore = videoPackets.count
                    let framesBefore = pendingVideoFrames.count
                    let residualBefore = residualVideoPackets.count
                    let submittedBefore = totalVideoPacketsSubmitted
                    await drainVideoDecodeBurst(
                        generation: generation,
                        warmPreparationAttempt: attempt
                    )
                    guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                          ObjectIdentifier(videoDecoder) == decoderIdentity else {
                        return cancelRenewedWarmVideoPreparation(run: run)
                    }
                    drainResidualPackets()
                    _ = recovery.needsForwardRescue(
                        observation: warmVideoPreparationLedger.observation,
                        epsilon: outputMediaFloorEpsilon
                    )
                    if videoPackets.count == packetsBefore,
                       pendingVideoFrames.count == framesBefore,
                       residualVideoPackets.count == residualBefore,
                       totalVideoPacketsSubmitted == submittedBefore {
                        break
                    }
                }

                guard warmVideoRunHasTime(run), isCurrentWarmVideoPreparationAttempt(attempt),
                      ObjectIdentifier(videoDecoder) == decoderIdentity else {
                    return cancelRenewedWarmVideoPreparation(run: run)
                }
                if suspendedVideoFault != nil || !videoDecoderOpened {
                    return failRenewedWarmVideoPreparation(token: token)
                }
                if warmVideoCandidateHasRequiredOutput(
                    disposition: .requiresPositioning,
                    target: target
                ) {
                    guard started.duration(to: ContinuousClock.now)
                            < Self.warmVideoDirectWallLimit else {
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    let authority = recordWarmVideoCandidateAuthority(
                        anchorPTS: directAnchorPTS ?? 0,
                        firstDTS: directFirstDTS,
                        endPTS: directEndPTS,
                        packetCount: directPacketCount,
                        byteCount: directCompressedPacketBytes,
                        startsWithSyncSample: directStartsWithSyncSample
                    )
                    let isDistinct = !directCandidateMatchesRejected
                        || directPacketCount != rejectedCandidate.count
                    let isEarlier = authority.decodeAnchorTime
                        < rejectedCandidateAuthority.decodeAnchorTime - 1e-6
                    guard authority.startsWithSyncSample,
                          authority.decodeAnchorTime
                            <= target + Self.videoContinuityAnchorToleranceSeconds,
                          isEarlier,
                          isDistinct else {
                        diagnostics.log(
                            "[PathA][continuation] direct renewed candidate rejected " +
                            "sync=\(authority.startsWithSyncSample ? 1 : 0) " +
                            "earlier=\(isEarlier ? 1 : 0) " +
                            "distinct=\(isDistinct ? 1 : 0)"
                        )
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                    let context = WarmVideoCandidateContext(
                        attempt: attempt, candidate: [], authority: authority, target: target,
                        disposition: .bracketingPreRoll,
                        provenance: .positioned(readGeneration: readGeneration),
                        fetchedBytes: videoReadBytesDelta(since: token),
                        chaseByteCount: compressedBytes, chargedContentTailPTS: contentFrontier,
                        decoderIdentity: decoderIdentity
                    )
                    switch await completeWarmVideoCandidate(context, run: run, recovery: &recovery) {
                    case .prepared:
                        return .prepared
                    case .cancelled:
                        return cancelRenewedWarmVideoPreparation(run: run)
                    case .repair, .exhausted:
                        return failRenewedWarmVideoPreparation(token: token)
                    }
                }

                guard !batch.reachedEOF else {
                    return failRenewedWarmVideoPreparation(token: token)
                }
                noProgressBatches = batch.madeProgress ? 0 : noProgressBatches + 1
                guard noProgressBatches < Self.warmVideoDirectNoProgressLimit else {
                    diagnostics.log(
                        "[PathA][continuation] direct positioned no-progress budget exhausted"
                    )
                    return failRenewedWarmVideoPreparation(token: token)
                }
            }
        }
    }

    private func failRenewedWarmVideoPreparation(
        token: DemandVideoSuspendToken
    ) -> DemandVideoLanePreparationResult {
        isDecodingWarmVideoCandidate = false
        isCollectingWarmVideoRunUp = false
        warmVideoPreparationLedger.retireAttempt()
        activeWarmVideoImageHold = nil
        retireCurrentVideoDecoderWithoutWaiting()
        return finishWarmVideoPreparation(
            token: token,
            failure: .decoderPreparationExhausted
        )
    }

    private func cancelRenewedWarmVideoPreparation(
        run: WarmVideoPreparationRun
    ) -> DemandVideoLanePreparationResult {
        guard warmPreparationTransaction.currentRun == run,
              activeVideoSuspendToken == run.token,
              runtimeGeneration == run.sessionGeneration,
              generation == run.engineGeneration,
              activeOwnerGeneration == run.ownerGeneration else { return .cancelled }
        isDecodingWarmVideoCandidate = false
        isCollectingWarmVideoRunUp = false
        warmVideoPreparationLedger.retireAttempt()
        activeWarmVideoImageHold = nil
        retireCurrentVideoDecoderWithoutWaiting()
        return abandonWarmVideoPreparation(run)
    }

    private func preparedVideoLaneCoversCurrentAudio() -> Bool {
        let target = audioPresentationMediaTime
        guard target.isFinite else { return true }
        guard target + outputMediaFloorEpsilon >= outputMediaFloor else { return false }
        let decodedUpperBound = pendingVideoFrames
            .map { $0.pts + max(0, $0.duration) }
            .max()
        let queuedUpperBound = videoPackets
            .map { $0.pts + max(0, $0.duration) }
            .max()
        guard let upperBound = [decodedUpperBound, queuedUpperBound]
            .compactMap({ $0 })
            .max(), upperBound.isFinite else {
            return true
        }
        return target <= upperBound
    }

    private func abandonWarmVideoPreparation(
        _ run: WarmVideoPreparationRun
    ) -> DemandVideoLanePreparationResult {
        let supersededByRun = warmPreparationTransaction.currentRun.map { $0.id != run.id } ?? true
        let supersededBySuspension = activeVideoSuspendToken != run.token
        let supersededBySession = runtimeGeneration != run.sessionGeneration
            || generation != run.engineGeneration
        let supersededByOwner = activeOwnerGeneration != run.ownerGeneration
        let cancelled = Task.isCancelled
        if supersededByRun || supersededBySuspension || supersededBySession
            || supersededByOwner || cancelled {
            return .cancelled
        }
        diagnostics.log(
            "[PathA][continuation] INVARIANT: prepare abandoned with no " +
            "successor run=\(run.id) token=\(run.token.generation) — " +
            "settling typed failure instead of parking the lane"
        )
        return finishWarmVideoPreparation(token: run.token, failure: .staleAuthority)
    }

    private func beginWarmVideoPreparationAttempt(
        run: WarmVideoPreparationRun,
        target: TimeInterval
    ) -> WarmVideoPreparationAttempt {
        let attempt = warmVideoPreparationLedger.beginAttempt(.init(
            runID: run.id,
            token: run.token,
            sessionGeneration: runtimeGeneration,
            engineGeneration: generation,
            ownerGeneration: activeOwnerGeneration,
            target: target
        ))
        if activeWarmDiagnostics?.runID == run.id {
            activeWarmDiagnostics?.attemptID = attempt.id
        }
        warmVideoSubmissionsWithoutOutput = 0
        return attempt
    }

    private func isCurrentWarmVideoPreparationAttempt(
        _ attempt: WarmVideoPreparationAttempt
    ) -> Bool {
        warmVideoPreparationLedger.currentAttempt == attempt
            && !Task.isCancelled
            && warmPreparationTransaction.currentRun?.id == attempt.runID
            && activeVideoSuspendToken == attempt.token
            && runtimeGeneration == attempt.sessionGeneration
            && generation == attempt.engineGeneration
            && activeOwnerGeneration == attempt.ownerGeneration
            && isVideoLaneWarmSuspended
            && isPreparingWarmVideoLane
    }

    private func isLocallyRepairableWarmVideoFault(_ fault: MediaRuntimeFault) -> Bool {
        guard fault.subsystem == .videoDecoder else { return false }
        switch fault.classification {
        case .invalidSession, .malfunction, .badData, .unsupportedFormat:
            return true
        case .input, .silentNoOutput, .unknown:
            return false
        }
    }

    private func finishWarmVideoPreparation(
        token: DemandVideoSuspendToken,
        failure: DemandPresentationFailure
    ) -> DemandVideoLanePreparationResult {
        guard !Task.isCancelled,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration else {
            return .cancelled
        }
        warmVideoPreparationLedger.retireAttempt()
        activeWarmVideoImageHold = nil
        isVideoLanePreparedForForeground = false
        terminalVideoPreparationFailure = failure
        diagnostics.log(
            "[PathA][continuation] video preparation terminal " +
            "token=\(token.generation) failure=\(failure.rawValue)"
        )
        return .failed(failure)
    }

    enum VideoLaneResumeDestination: Equatable {
        case inline
        case pictureInPicture
    }

    func resumeVideoLane(
        _ token: DemandVideoSuspendToken,
        renderGeneration: Int,
        destination: VideoLaneResumeDestination = .inline
    ) async -> Bool {
        var strictRefreshes = 0
        while true {
            guard activeVideoSuspendToken == token,
                  token.sessionGeneration == runtimeGeneration,
                  token.ownerGeneration == activeOwnerGeneration,
                  isVideoLaneWarmSuspended,
                  isVideoLanePreparedForForeground else { return false }
            let resumeMediaTime = audioPresentationMediaTime
            guard resumeMediaTime.isFinite else { return false }
            var target = max(0, resumeMediaTime)
        advanceOutputMediaFloor(to: target, reason: "resume")

        let holdNeedsRefresh: Bool
        if let hold = activeWarmVideoImageHold {
            let holdStillCoversAudio = target <= hold.candidateTailPTS
                + Self.videoContinuityAnchorToleranceSeconds
            holdNeedsRefresh = hold.token != token
                || !warmVideoImageHoldIsCurrent(
                    hold,
                    requiresActiveSuspendToken: true
                )
                || !holdStillCoversAudio
        } else {
            holdNeedsRefresh = false
        }
        if holdNeedsRefresh || !warmVideoCandidateHasRequiredOutput(
            disposition: .bracketingPreRoll,
            target: target
        ) {
            if let hold = activeWarmVideoImageHold {
                diagnostics.log(
                    "[PathA][continuation] resume floor advanced " +
                    "floor=\(String(format: "%.3f", target)) " +
                    "candidateEnd=\(String(format: "%.3f", hold.candidateTailPTS)) " +
                    "rejectedStale=\(staleVideoOutputRejectionCount)"
                )
            } else {
                diagnostics.log(
                    "[PathA][continuation] resume requires current-floor frame " +
                    "floor=\(String(format: "%.3f", target)) " +
                    "rejectedStale=\(staleVideoOutputRejectionCount)"
                )
            }
            let continuationDisposition: WarmVideoCandidateDisposition = {
                guard let hold = activeWarmVideoImageHold else {
                    return .bracketingPreRoll
                }
                if case .forwardPositioned(let receipt) = hold.candidateProvenance {
                    return .positionedFutureImageHold(receipt)
                }
                return .nearFutureImageHold(notBeforePTS: hold.notBeforePTS)
            }()
            let continuationCandidateTailPTS =
                activeWarmVideoImageHold?.candidateTailPTS
            activeWarmVideoImageHold = nil
            let decoderIdentity = ObjectIdentifier(videoDecoder)
            let initialTail = max(
                pendingVideoFrameEndPTS() ?? -.infinity,
                videoPacketEndPTS() ?? -.infinity
            )
            let initialAnchor = pendingVideoFrames
                .compactMap { $0.pts.isFinite ? $0.pts : nil }
                .min() ?? target
            let initialByteCount = videoPackets.reduce(into: 0) { total, packet in
                let (updated, overflowed) =
                    total.addingReportingOverflow(packet.data.count)
                total = overflowed ? Int.max : updated
            }
            isDecodingWarmVideoCandidate = true
            var resumeRecovery: WarmVideoRecoveryPolicy?
            let continuation = await continueWarmVideoPreparationToMovingTarget(
                run: nil,
                attempt: nil,
                token: token,
                startTarget: target,
                disposition: continuationDisposition,
                initialCandidateTailPTS: initialTail.isFinite
                    ? initialTail
                    : (continuationCandidateTailPTS ?? target),
                initialCandidateAnchorPTS: initialAnchor,
                initialCandidateByteCount: initialByteCount,
                decoderIdentity: decoderIdentity,
                generation: generation,
                recovery: &resumeRecovery
            )
            isDecodingWarmVideoCandidate = false
            switch continuation {
            case let .covered(coveredTarget, _, _):
                target = max(
                    target,
                    max(
                        coveredTarget,
                        audioPresentationMediaTime.isFinite
                            ? audioPresentationMediaTime
                            : target
                    )
                )
            case .retryLocal, .needsForwardRescue:
                return false
            case .tailExpired:
                guard strictRefreshes == 0 else { return false }
                strictRefreshes += 1
                activeWarmVideoImageHold = nil
                warmVideoPreparationLedger.retireAttempt()
                isDecodingWarmVideoCandidate = false
                isVideoLanePreparedForForeground = false
                terminalVideoPreparationFailure = nil
                suspendedVideoFault = nil
                diagnostics.log(
                    "[PathA][continuation] resume near-future tail " +
                    "refreshing through strict preparation"
                )
                guard await prepareVideoLaneForForeground(token) == .prepared,
                      activeVideoSuspendToken == token,
                      isVideoLaneWarmSuspended else {
                    return false
                }
                continue
            case .exhausted, .cancelled:
                return false
            }
            advanceOutputMediaFloor(to: target, reason: "resume-commit")
        }
        let rendererReady: Bool
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            switch destination {
            case .inline:
                rendererReady = renderer.resumePresentation(
                    renderGeneration: renderGeneration,
                    mediaTime: target,
                    rate: effectiveDisplayRate,
                    mediaFloor: outputMediaFloor
                )
            case .pictureInPicture:
                rendererReady = renderer.resumePiPPresentation(
                    renderGeneration: renderGeneration,
                    mediaTime: target,
                    rate: effectiveDisplayRate,
                    mediaFloor: outputMediaFloor
                )
            }
        } else {
            videoRender.flush()
            rendererReady = true
        }
        guard rendererReady else { return false }

        if var hold = activeWarmVideoImageHold {
            guard hold.token == token,
                  warmVideoImageHoldIsCurrent(
                    hold,
                    requiresActiveSuspendToken: true
                  ) else {
                activeWarmVideoImageHold = nil
                return false
            }
            hold.renderGeneration = renderGeneration
            activeWarmVideoImageHold = hold
        }

        if var identity = warmDiagnosticProofIdentity,
           identity.run.token == token,
           identity.run.sessionGeneration == runtimeGeneration,
           identity.run.engineGeneration == generation,
           identity.run.ownerGeneration == activeOwnerGeneration {
            identity.renderGeneration = renderGeneration
            identity.floor = outputMediaFloor
            warmDiagnosticProofIdentity = identity
        }
        let keepsHoldAuthority = destination == .inline
            && activeWarmVideoImageHold != nil
        if !keepsHoldAuthority {
            activeWarmVideoImageHold = nil
        }
        isVideoLaneWarmSuspended = false
        clearDisplayOutputContinuity()
        resetCachedRunway(video: true, audio: false)
        suspendedVideoSupplyMemorySuppressed = false
        isVideoLanePreparedForForeground = false
        if !keepsHoldAuthority {
            activeVideoSuspendToken = nil
        }
        warmVideoPreparationLedger.retireAttempt()
        terminalVideoPreparationFailure = nil
        suspendedVideoFault = nil
        suspendedVideoGOP = []
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPProvenance = nil
        applyPipelineDemand()
        armPresentFeedIfNeeded()
        presentDueVideoFrames()
        startSupplyLoop()
        requestSupplyWake()
        scheduleVideoDecodeIfNeeded()
        diagnostics.log(
            "[PathA][continuation] video resumed token=\(token.generation) " +
            "destination=\(destination == .pictureInPicture ? "pip" : "inline") " +
            "render=\(renderGeneration) target=\(String(format: "%.3f", target))"
        )
        return true
        }
    }

    func restoreInlinePresentation(renderGeneration: Int) async -> Bool {
        guard isReady else { return false }
        clearDisplayOutputContinuity()
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            let floor = audioPresentationMediaTime
            guard floor.isFinite else { return false }
            advanceOutputMediaFloor(to: floor, reason: "inline-adoption")
            let adoption = renderer.adoptInlinePresentation(
                renderGeneration: renderGeneration,
                mediaTime: floor,
                rate: effectiveDisplayRate,
                mediaFloor: outputMediaFloor
            )
            guard adoption == .adopted else { return false }
        } else {
            videoRender.setDisplayPlayback(
                rate: effectiveDisplayRate,
                mediaTime: audioPresentationMediaTime
            )
        }
        applyPipelineDemand()
        if isPlaying {
            armPresentFeedIfNeeded()
            presentDueVideoFrames()
            scheduleVideoDecodeIfNeeded()
        }
        return true
    }

    func flushAndPrimeRenderer(renderGeneration: Int) -> Bool {
        clearDisplayOutputContinuity()
        let target = audioPresentationMediaTime
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            return renderer.resumePresentation(
                renderGeneration: renderGeneration,
                mediaTime: target,
                rate: effectiveDisplayRate
            )
        }
        videoRender.flush()
        videoRender.setDisplayPlayback(rate: effectiveDisplayRate, mediaTime: target)
        return true
    }

    private func finishVideoDecoderRepair(_ repairID: UInt64) {
        guard activeVideoDecoderRepairID == repairID else { return }
        activeVideoDecoderRepairID = nil
        videoDecoderRepairTask = nil
    }

    private func beginVideoDecoderRepair(
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

    private func scheduleVideoDecoderRepairIfNeeded() {
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

    private func videoDecoderRepairAuthorityIsCurrent(
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

    private func performVideoDecoderRepair(
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

    private func updatePiPPlaybackState() {
        guard let pipHost = videoRender as? SampleBufferVideoRenderer else { return }
        pipHost.updatePiPPlaybackState(
            currentTime: clock.mediaTime,
            duration: clock.duration,
            isPlaying: isPlaying
        )
    }

    private func updateObservedPiPLease(_ active: Bool) {
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

    private func finishPiPVideoResume(_ resumeID: UInt64) {
        guard activePiPVideoResumeID == resumeID else { return }
        activePiPVideoResumeID = nil
        pipVideoResumeTask = nil
    }

    private func cancelPiPVideoResume() {
        pipVideoResumeTask?.cancel()
        pipVideoResumeTask = nil
        activePiPVideoResumeID = nil
    }

    private func schedulePiPVideoResumeIfNeeded(
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

    private func resumeWarmVideoLaneForActivePiP(
        renderGeneration: Int
    ) async -> Bool {
        guard hasObservedPiPLease, isPlaying else { return false }
        guard isVideoLaneWarmSuspended else { return true }
        schedulePiPVideoResumeIfNeeded(renderGeneration: renderGeneration)
        guard let task = pipVideoResumeTask else { return false }
        return await task.value
    }

    private func bindPiPEventSource() {
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

    private func replacePiPEventBinding() -> PiPEventBindingToken {
        nextPiPEventBindingGeneration &+= 1
        let token = PiPEventBindingToken(generation: nextPiPEventBindingGeneration)
        activePiPEventBindingToken = token
        return token
    }

    private func invalidatePiPEventBinding() {
        nextPiPEventBindingGeneration &+= 1
        activePiPEventBindingToken = nil
    }

    private func clearPiPEventSource() {
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

    private func noteAudioSupplyPull(requested: Int, written: Int) {
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
        let sessionSpan = UIHitchMonitor.beginSpan("tick.sess")
        defer { UIHitchMonitor.endSpan(sessionSpan) }
        noteFlowStage(&flowClock, "clock")
        clock.advanceContent(by: seconds)
        if seconds.isFinite, clock.mediaTime.isFinite, audioRender.outputAvailability == .available {
            renderedAudioOutput = RenderedAudioOutput(
                sessionGeneration: runtimeGeneration, ownerGeneration: activeOwnerGeneration, position: clock.mediaTime
            )
        }
        if !isVideoLaneWarmSuspended {
            let presentSpan = UIHitchMonitor.beginSpan("tick.present")
            presentDueVideoFrames()
            UIHitchMonitor.endSpan(presentSpan)
            let starveSpan = UIHitchMonitor.beginSpan("tick.starve")
            evaluateVideoStarvation()
            UIHitchMonitor.endSpan(starveSpan)
            let resyncSpan = UIHitchMonitor.beginSpan("tick.resync")
            maybeResyncDisplaySlave()
            UIHitchMonitor.endSpan(resyncSpan)
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
            let scheduleSpan = UIHitchMonitor.beginSpan("tick.sched")
            scheduleAudioDecodeIfNeeded()
            if !isVideoLaneWarmSuspended {
                scheduleVideoDecodeIfNeeded()
            }
            UIHitchMonitor.endSpan(scheduleSpan)
        }
        if clock.isAtEnd {
            emitEndedIfNeeded()
        } else if audioDrainingToEnd {
            maybeFinishAudioDrain()
        }
        maybeReportPipeInstrument()
    }

    private func handlePullOutcome(requested: Int, written: Int) {
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

    private func audioSupplyExhausted() -> Bool {
        demuxReachedEOF
            && audioPackets.isEmpty
            && residualAudioPackets.isEmpty
            && pendingAudioContentSeconds < 0.000_5
            && audioDecodeTask == nil
            && audioDecodeLaneOwners == 0
            && activeAudioDecodeOperationID == nil
    }

    private func beginAudioDrainToEnd() {
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

    private func maybeFinishAudioDrain() {
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

    private func finishAudioDrain() {
        if let emptiedAt = audioEOFDrain.emptiedAt, let deadline = audioEOFDrain.playoutDeadline {
            let elapsedMs = Int(emptiedAt.duration(to: ContinuousClock.now) / .milliseconds(1))
            let latencyMs = Int(emptiedAt.duration(to: deadline) / .milliseconds(1))
            diagnostics.log(
                "[PathA] audio EOF played out after \(elapsedMs)ms (latency \(latencyMs)ms)"
            )
        }
        emitEndedIfNeeded()
    }

    private func emitEndedIfNeeded() {
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

    private func needsPacketFill() -> Bool {
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

    private func startSupplyLoop() {
        guard isReady,
              !isPreparingWarmVideoLane else { return }
        if supplyLoopTask != nil {
            requestSupplyWake()
            return
        }
        let gen = generation
        supplyLoopWakePending = false
        supplyLoopStartCount += 1
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

    private func runSupplyLoop(generation gen: Int) async {
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

    private func parkSupplyLoop() async {
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

    private func requestSupplyWake() {
        guard supplyLoopTask != nil else { return }
        if let continuation = supplyLoopWake {
            supplyLoopWake = nil
            continuation.resume()
        } else {
            supplyLoopWakePending = true
        }
    }

    private func wakeSupplyLoopIfDrained() {
        guard supplyLoopTask != nil, supplyBelowLowWater() else { return }
        pipeWindowWakes += 1
        requestSupplyWake()
    }

    private func supplyBelowLowWater() -> Bool {
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

    private func canPumpNow() -> Bool {
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

    private func cancelSupplyLoop() {
        invalidateSourceWaitBudget()
        supplyLoopTask?.cancel()
        supplyLoopTask = nil
        if let continuation = supplyLoopWake {
            supplyLoopWake = nil
            continuation.resume()
        }
        supplyLoopWakePending = false
    }

    private func cancelDecode() {
        cancelPiPVideoResume()
        videoDecoderRepairTask?.cancel()
        videoDecoderRepairTask = nil
        activeVideoDecoderRepairID = nil
        cancelVideoDecode(clearHandle: true)
        cancelAudioDecode(clearHandle: true)
    }

    private func cancelVideoDecode(clearHandle: Bool) {
        activeVideoDecodeOperationID = nil
        decodeTask?.cancel()
        if clearHandle {
            decodeTask = nil
        }
    }

    private func cancelAudioDecode(clearHandle: Bool) {
        activeAudioDecodeOperationID = nil
        audioDecodeTask?.cancel()
        if clearHandle {
            audioDecodeTask = nil
        }
    }

    private func cancelWarmVideoImageHoldRefresh() {
        warmVideoImageHoldRefreshTask?.cancel()
        warmVideoImageHoldRefreshTask = nil
        activeWarmVideoImageHoldRefreshID = nil
    }

    private func clearPacketBuffers() {
        videoPackets = []
        audioPackets = []
        residualVideoPackets = []
        residualAudioPackets = []
        videoPacketQueue.reset()
        audioPacketQueue.reset()
        packetRelay.reset()
        resetCachedRunway()
        videoStarvedSince = nil
        bufferingForVideoStarvation = false
    }

    private func supersedeWarmVideoPreparationRun() {
        warmPreparationTransaction.supersede(host: self)
    }

    private func resetVideoContinuationState() {
        warmPreparationTransaction.reset(host: self)
        warmVideoPreparationLedger.retireAttempt()
        warmVideoSubmissionsWithoutOutput = 0
        isCollectingWarmVideoRunUp = false
        warmVideoCandidateAuthorities = []
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        nextVideoReadGeneration = 0
        videoReadBytes = 0
        suspendedVideoGOP = []
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPProvenance = nil
        suspendedVideoSupplyMemorySuppressed = false
        suspendedVideoFault = nil
        terminalVideoPreparationFailure = nil
        videoContinuityTopology = .unsupported
    }

    private var suspendedVideoRunway: TimeInterval {
        guard let end = suspendedVideoGOP.last.map({ $0.pts + max(0, $0.duration) }) else {
            return 0
        }
        return max(0, end - audioPresentationMediaTime)
    }

    private var suspendedVideoSupplyTarget: TimeInterval {
        guard !suspendedVideoSupplyMemorySuppressed else { return 0 }
        switch videoContinuityTopology {
        case .muxedCurrentGOP:
            return Self.suspendedVideoTargetAheadSeconds
        case .splitTrack, .localFileIndex:
            guard !isPreparingWarmVideoLane, !isVideoLanePreparedForForeground,
                  activeWarmVideoImageHoldRefreshID == nil else { return 0 }
            return videoPacketQueue.highWater
        case .unsupported:
            return 0
        }
    }

    private func retainSuspendedVideoPacket(
        _ packet: MediaPacket,
        provenance: DemandVideoCandidateProvenance
    ) {
        guard packet.track == .video,
              !suspendedVideoSupplyMemorySuppressed
            || isCollectingWarmVideoRunUp else { return }
        let packet = normalizingZeroDuration(packet)
        if suspendedVideoGOP.isEmpty, !packet.isKeyframe {
            return
        }
        if suspendedVideoGOPProvenance == nil {
            suspendedVideoGOPProvenance = provenance
        } else if suspendedVideoGOPProvenance != provenance {
            switch provenance {
            case .postSuspend:
                suspendedVideoGOPProvenance = provenance
            case .positioned, .forwardPositioned:
                suspendedVideoGOPProvenance = provenance
            case .suspendEdge:
                break
            }
        }
        suspendedVideoGOP.append(packet)
        suspendedVideoGOPContentSeconds += max(0, packet.duration)
        suspendedVideoGOPBytes += packet.data.count
        if isCollectingWarmVideoRunUp {
            if suspendedVideoGOPContentSeconds > Self.suspendedVideoGOPMaxContentSeconds
                || suspendedVideoGOPBytes > Self.suspendedVideoGOPMaxBytes {
                suspendedVideoGOP = []
                suspendedVideoGOPContentSeconds = 0
                suspendedVideoGOPBytes = 0
                suspendedVideoGOPProvenance = nil
            }
            return
        }
        if packet.isKeyframe {
            trimSuspendedVideoWindowBehindClock(audioPresentationMediaTime)
        }
        enforceSuspendedVideoWindowCaps()
    }

    private func suspendedVideoWindowSecondKeyframeIndex() -> Int? {
        var foundFirst = false
        for (index, packet) in suspendedVideoGOP.enumerated() where packet.isKeyframe {
            if foundFirst { return index }
            foundFirst = true
        }
        return nil
    }

    private func dropSuspendedVideoWindowPrefix(before index: Int) {
        guard index > 0, index <= suspendedVideoGOP.count else { return }
        for packet in suspendedVideoGOP[..<index] {
            suspendedVideoGOPContentSeconds -= max(0, packet.duration)
            suspendedVideoGOPBytes -= packet.data.count
        }
        suspendedVideoGOP.removeFirst(index)
        suspendedVideoGOPContentSeconds = max(0, suspendedVideoGOPContentSeconds)
        suspendedVideoGOPBytes = max(0, suspendedVideoGOPBytes)
    }

    private func trimSuspendedVideoWindowBehindClock(_ horizon: TimeInterval) {
        guard horizon.isFinite else { return }
        while let second = suspendedVideoWindowSecondKeyframeIndex(),
              suspendedVideoGOP[second].pts <= horizon {
            dropSuspendedVideoWindowPrefix(before: second)
        }
    }

    private func enforceSuspendedVideoWindowCaps() {
        guard suspendedVideoGOPContentSeconds > Self.suspendedVideoWindowMaxContentSeconds
            || suspendedVideoGOPBytes > Self.suspendedVideoWindowMaxBytes else { return }
        while let second = suspendedVideoWindowSecondKeyframeIndex(),
              suspendedVideoGOPContentSeconds > Self.suspendedVideoWindowMaxContentSeconds
                || suspendedVideoGOPBytes > Self.suspendedVideoWindowMaxBytes {
            dropSuspendedVideoWindowPrefix(before: second)
        }
        if suspendedVideoGOPContentSeconds > Self.suspendedVideoWindowMaxContentSeconds
            || suspendedVideoGOPBytes > Self.suspendedVideoWindowMaxBytes {
            suspendedVideoGOP = []
            suspendedVideoGOPContentSeconds = 0
            suspendedVideoGOPBytes = 0
            suspendedVideoGOPProvenance = nil
        }
    }

    func discardSuspendedVideoWindowForMemoryPressure() {
        guard isVideoLaneWarmSuspended else { return }
        switch videoContinuityTopology {
        case .splitTrack, .localFileIndex: break
        case .muxedCurrentGOP, .unsupported: return
        }
        suspendedVideoGOP = []
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPProvenance = nil
        suspendedVideoSupplyMemorySuppressed = true
        diagnostics.log(
            "[PathA][continuation] suspended video window shed (memory pressure) " +
            "audio=\(String(format: "%.3f", audioPresentationMediaTime))"
        )
    }

    private func suspendedVideoCandidate(at target: TimeInterval) -> [MediaPacket]? {
        guard let first = suspendedVideoGOP.first,
              first.isKeyframe,
              target.isFinite,
              let last = suspendedVideoGOP.last,
              let lastEnd = finiteMediaIntervalEnd(
                  start: last.pts,
                  duration: last.duration
              ),
              lastEnd + Self.videoContinuityAnchorToleranceSeconds >= target else {
            return nil
        }
        return suspendedVideoGOP
    }

    private func recordWarmVideoCandidateAuthority(
        _ candidate: [MediaPacket]
    ) -> MediaVideoContinuityCandidateAuthority {
        let first = candidate.first
        let endPTS = candidate.reduce(0) {
            max($0, $1.pts + max(0, $1.duration))
        }
        return recordWarmVideoCandidateAuthority(
            anchorPTS: first?.pts ?? 0,
            firstDTS: first?.dts,
            endPTS: endPTS,
            packetCount: candidate.count,
            byteCount: candidate.reduce(0) { $0 + $1.data.count },
            startsWithSyncSample: first?.isKeyframe == true
        )
    }

    private func recordWarmVideoCandidateAuthority(
        anchorPTS: TimeInterval,
        firstDTS: TimeInterval?,
        endPTS: TimeInterval,
        packetCount: Int,
        byteCount: Int,
        startsWithSyncSample: Bool
    ) -> MediaVideoContinuityCandidateAuthority {
        nextVideoContinuityCandidateGeneration &+= 1
        if nextVideoContinuityCandidateGeneration == 0 {
            nextVideoContinuityCandidateGeneration = 1
        }
        let authority = MediaVideoContinuityCandidateAuthority(
            generation: nextVideoContinuityCandidateGeneration,
            anchorPTS: anchorPTS,
            firstDTS: firstDTS,
            endPTS: endPTS,
            packetCount: packetCount,
            byteCount: byteCount,
            startsWithSyncSample: startsWithSyncSample
        )
        warmVideoCandidateAuthorities.append(authority)
        let limit = Self.warmVideoDecoderRepairLimit + 1
        if warmVideoCandidateAuthorities.count > limit {
            warmVideoCandidateAuthorities.removeFirst(
                warmVideoCandidateAuthorities.count - limit
            )
        }
        return authority
    }

    private func sameCompressedPacket(
        _ lhs: MediaPacket,
        _ rhs: MediaPacket
    ) -> Bool {
        let samePixelBuffer: Bool
        switch (lhs.pixelBuffer, rhs.pixelBuffer) {
        case (nil, nil):
            samePixelBuffer = true
        case let (left?, right?):
            samePixelBuffer = left === right
        default:
            samePixelBuffer = false
        }
        return lhs.track == rhs.track
            && lhs.data == rhs.data
            && samePixelBuffer
    }

    private func sameCompressedCandidate(
        _ lhs: [MediaPacket],
        _ rhs: [MediaPacket]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            sameCompressedPacket(left, right)
        }
    }

    private func formatOptionalMediaTime(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.3f", value)
    }

    private func retainedVideoWindowBrackets(_ target: TimeInterval) -> Bool {
        guard let first = suspendedVideoGOP.first,
              first.isKeyframe,
              target.isFinite,
              first.pts <= target + Self.videoContinuityAnchorToleranceSeconds,
              let last = suspendedVideoGOP.last,
              let lastEnd = finiteMediaIntervalEnd(
                  start: last.pts,
                  duration: last.duration
              ),
              lastEnd + Self.videoContinuityAnchorToleranceSeconds >= target else {
            return false
        }
        return true
    }

    private static func classifyWarmVideoCandidate(
        _ candidate: [MediaPacket],
        topology: MediaVideoContinuityTopology,
        target: TimeInterval,
        retainedInMemory: Bool,
        contentSeconds: TimeInterval,
        byteCount: Int
    ) -> WarmVideoCandidateDisposition {
        guard target.isFinite,
              let first = candidate.first,
              first.isKeyframe else {
            return .requiresPositioning
        }
        let decodeAnchor = (first.dts?.isFinite == true ? first.dts : first.pts) ?? first.pts
        guard decodeAnchor.isFinite else { return .requiresPositioning }
        let endPTS = candidate.reduce(-TimeInterval.infinity) { partial, packet in
            guard packet.pts.isFinite, packet.duration.isFinite else { return partial }
            return max(partial, packet.pts + max(0, packet.duration))
        }
        guard endPTS.isFinite,
              endPTS + videoContinuityAnchorToleranceSeconds >= target else {
            return .requiresPositioning
        }
        if decodeAnchor <= target + videoContinuityAnchorToleranceSeconds {
            return .bracketingPreRoll
        }

        let lead = decodeAnchor - target
        guard topology == .splitTrack,
              retainedInMemory,
              lead > videoContinuityAnchorToleranceSeconds,
              lead <= suspendedVideoTargetAheadSeconds + 1e-9,
              contentSeconds.isFinite,
              contentSeconds >= 0,
              contentSeconds <= suspendedVideoWindowMaxContentSeconds + 1e-9,
              byteCount >= 0,
              byteCount <= suspendedVideoWindowMaxBytes else {
            return .requiresPositioning
        }

        var distinctPTS: [TimeInterval] = []
        for packet in candidate where packet.pts.isFinite
            && packet.pts + 1e-9 >= decodeAnchor {
            if !distinctPTS.contains(where: { abs($0 - packet.pts) <= 1e-9 }) {
                distinctPTS.append(packet.pts)
                if distinctPTS.count >= 2 {
                    return .nearFutureImageHold(notBeforePTS: decodeAnchor)
                }
            }
        }
        return .requiresPositioning
    }

    private func warmVideoCandidateHasRequiredOutput(
        disposition: WarmVideoCandidateDisposition,
        target: TimeInterval
    ) -> Bool {
        guard target.isFinite else { return false }
        switch disposition {
        case .bracketingPreRoll, .requiresPositioning:
            let floor = max(outputMediaFloor, target)
            return pendingVideoFrames.contains {
                isVideoFrameUsableAtOutputFloor($0, floor: floor)
                    && $0.pts + $0.duration + 1e-9 >= floor
            }
        case .nearFutureImageHold, .positionedFutureImageHold:
            guard let notBeforePTS = disposition.futureNotBeforePTS else { return false }
            let floor = max(outputMediaFloor, max(target, notBeforePTS))
            var firstPTS: TimeInterval?
            for frame in pendingVideoFrames where frame.pts.isFinite
                && isVideoFrameUsableAtOutputFloor(frame, floor: floor)
                && frame.pts + frame.duration + 1e-9 >= floor {
                guard let firstPTS else {
                    firstPTS = frame.pts
                    continue
                }
                if abs(frame.pts - firstPTS) > 1e-9 {
                    return true
                }
            }
            return false
        }
    }

    private var warmVideoImageHoldWithholdsVideoSupply: Bool {
        activeWarmVideoImageHold != nil
    }

    private func warmVideoImageHoldCandidateIsCurrent(
        _ hold: WarmVideoImageHoldSnapshot
    ) -> Bool {
        switch hold.candidateProvenance {
        case .suspendEdge(let readGeneration):
            guard readGeneration == hold.token.videoReadGeneration,
                  hold.foregroundFetchBytes == 0 else { return false }
        case .forwardPositioned(let receipt):
            let remainingLead = max(0, receipt.anchorPTS - audioPresentationMediaTime)
            let wallSeconds = Double(warmVideoPreparationDeadline / .seconds(1))
            guard hold.foregroundFetchBytes >= receipt.selectionFetchBytes,
                  receipt.anchorPTS == hold.notBeforePTS,
                  hold.candidateTailPTS <= receipt.contentInterval.end + 1e-9,
                  playbackRate.isFinite, playbackRate > 0,
                  remainingLead.isFinite, remainingLead <= receipt.maximumLead,
                  remainingLead / Double(playbackRate) <= wallSeconds else { return false }
        case .postSuspend, .positioned:
            return false
        }
        return warmVideoCandidateAuthorities.contains { authority in
            authority.generation == hold.candidateAuthorityGeneration
                && authority.startsWithSyncSample
                && warmVideoHoldAnchorMatches(authority, hold: hold)
                && abs(authority.endPTS - hold.candidateTailPTS) <= 1e-9
        }
    }

    private func warmVideoHoldAnchorMatches(
        _ authority: MediaVideoContinuityCandidateAuthority,
        hold: WarmVideoImageHoldSnapshot
    ) -> Bool {
        switch hold.candidateProvenance {
        case .forwardPositioned(let receipt):
            return abs(authority.anchorPTS - receipt.anchorPTS) <= 1e-9
                && receipt.anchorPTS == hold.notBeforePTS
        case .suspendEdge:
            return abs(authority.decodeAnchorTime - hold.notBeforePTS) <= 1e-9
        case .positioned, .postSuspend:
            return false
        }
    }

    private func warmVideoImageHoldIsCurrent(
        _ hold: WarmVideoImageHoldSnapshot,
        requiresActiveSuspendToken: Bool
    ) -> Bool {
        let tokenIsCurrent = requiresActiveSuspendToken
            ? (isVideoLaneWarmSuspended && activeVideoSuspendToken == hold.token)
            : (!isVideoLaneWarmSuspended
                && hold.renderGeneration != nil
                && activeVideoSuspendToken == hold.token)
        return hold.runID != 0
            && runtimeGeneration == hold.sessionGeneration
            && generation == hold.engineGeneration
            && activeOwnerGeneration == hold.ownerGeneration
            && playbackRateRevision == hold.rateRevision
            && tokenIsCurrent
            && warmVideoImageHoldCandidateIsCurrent(hold)
    }

    private func releaseWarmVideoImageHoldIfDue(
        _ due: TimeInterval
    ) -> WarmVideoImageHoldReleaseOutcome {
        guard let hold = activeWarmVideoImageHold else {
            return .released
        }
        guard warmVideoImageHoldIsCurrent(
            hold,
            requiresActiveSuspendToken: isVideoLaneWarmSuspended
        ) else {
            refreshWarmVideoImageHold(hold, reason: "authority")
            return .refreshRequired
        }
        let liveAudio = audioPresentationMediaTime
        guard liveAudio.isFinite,
              due.isFinite,
              liveAudio <= hold.candidateTailPTS
                + Self.videoContinuityAnchorToleranceSeconds else {
            diagnostics.log(
                "[PathA][continuation] hold stale before proof " +
                "notBefore=\(String(format: "%.3f", hold.notBeforePTS)) " +
                "tail=\(String(format: "%.3f", hold.candidateTailPTS)) " +
                "audio=\(String(format: "%.3f", liveAudio))"
            )
            refreshWarmVideoImageHold(hold, reason: "tail-or-clock")
            return .refreshRequired
        }
        guard due + 1e-9 >= hold.notBeforePTS else {
            return .waiting
        }
        guard !hold.hasReachedAudioDueTime else {
            return .released
        }
        var released = hold
        released.hasReachedAudioDueTime = true
        activeWarmVideoImageHold = released
        diagnostics.log(
            "[PathA][continuation] hold release " +
            "token=\(hold.token.generation) " +
            "notBefore=\(String(format: "%.3f", hold.notBeforePTS)) " +
            "due=\(String(format: "%.3f", due)) " +
            "foregroundFetchBytes=\(hold.foregroundFetchBytes)"
        )
        return .released
    }

    private func refreshWarmVideoImageHold(
        _ hold: WarmVideoImageHoldSnapshot,
        reason: String
    ) {
        guard activeWarmVideoImageHold == hold else { return }
        activeWarmVideoImageHold = nil
        clearPendingVideoFrames()
        videoPackets = []
        residualVideoPackets = []
        videoPacketQueue.reset()
        resetCachedRunway(video: true, audio: false)
        suspendedVideoGOP = []
        suspendedVideoGOPContentSeconds = 0
        suspendedVideoGOPBytes = 0
        suspendedVideoGOPProvenance = nil

        guard activeVideoSuspendToken == hold.token,
              hold.token.sessionGeneration == runtimeGeneration,
              hold.engineGeneration == generation,
              hold.ownerGeneration == activeOwnerGeneration else {
            return
        }

        let token = hold.token
        let renderGeneration = hold.renderGeneration
        isVideoLaneWarmSuspended = true
        isVideoLanePreparedForForeground = false
        isPreparingWarmVideoLane = false
        terminalVideoPreparationFailure = nil
        suspendedVideoFault = nil
        disarmPresentFeed()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        videoRender.flush()
        diagnostics.log(
            "[PathA][continuation] hold refresh required reason=\(reason) " +
            "token=\(token.generation) " +
            "render=\(renderGeneration.map(String.init) ?? "n/a")"
        )

        nextWarmVideoImageHoldRefreshID &+= 1
        if nextWarmVideoImageHoldRefreshID == 0 {
            nextWarmVideoImageHoldRefreshID = 1
        }
        let refreshID = nextWarmVideoImageHoldRefreshID
        activeWarmVideoImageHoldRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            defer { self?.completeWarmVideoImageHoldRefresh(id: refreshID) }
            guard let self,
                  self.activeWarmVideoImageHoldRefreshID == refreshID,
                  self.activeVideoSuspendToken == token,
                  self.isVideoLaneWarmSuspended,
                  token.sessionGeneration == self.runtimeGeneration,
                  hold.engineGeneration == self.generation,
                  hold.ownerGeneration == self.activeOwnerGeneration else { return }
            let result = await self.prepareVideoLaneForForeground(token)
            guard self.activeWarmVideoImageHoldRefreshID == refreshID,
                  self.activeVideoSuspendToken == token,
                  token.sessionGeneration == self.runtimeGeneration,
                  hold.engineGeneration == self.generation,
                  hold.ownerGeneration == self.activeOwnerGeneration else { return }
            switch result {
            case .prepared:
                guard let renderGeneration else { return }
                let resumed = await self.resumeVideoLane(
                    token,
                    renderGeneration: renderGeneration
                )
                guard self.activeWarmVideoImageHoldRefreshID == refreshID,
                      self.activeVideoSuspendToken == token else { return }
                if !resumed {
                    diagnostics.log(
                        "[PathA][continuation] hold refresh resume failed " +
                        "render=\(renderGeneration)"
                    )
                    self.onPresentationFailure?(.decoderRecoveryFailed, renderGeneration)
                }
            case .failed(let failure):
                diagnostics.log(
                    "[PathA][continuation] hold refresh terminal " +
                    "failure=\(failure.rawValue)"
                )
                self.onPresentationFailure?(failure, renderGeneration)
            case .cancelled:
                break
            }
        }
        warmVideoImageHoldRefreshTask = task
    }

    private func completeWarmVideoImageHoldRefresh(id: UInt64) {
        guard activeWarmVideoImageHoldRefreshID == id else { return }
        activeWarmVideoImageHoldRefreshID = nil
        warmVideoImageHoldRefreshTask = nil
    }

    private func completeWarmVideoImageHoldIfProved(
        renderGeneration: Int,
        mediaTime: TimeInterval,
        rendererReady: Bool
    ) {
        guard let hold = activeWarmVideoImageHold,
              hold.hasReachedAudioDueTime,
              hold.renderGeneration == renderGeneration,
              rendererReady,
              mediaTime.isFinite,
              mediaTime + 1e-9 >= hold.notBeforePTS,
              mediaTime <= hold.candidateTailPTS
                + Self.videoContinuityAnchorToleranceSeconds,
              warmVideoImageHoldIsCurrent(
                hold,
                requiresActiveSuspendToken: false
              ) else {
            return
        }
        activeWarmVideoImageHold = nil
        if !isVideoLaneWarmSuspended {
            activeVideoSuspendToken = nil
        }
        requestSupplyWake()
    }

    private func clearPendingVideoFrames() {
        pendingVideoFrames = []
        pendingVideoContentSeconds = 0
    }

    private func discardSeekPreparedContent(for token: MediaAudioSeekToken? = nil) {
        if let token, activeSeekToken != token { return }
        guard activeSeekToken != nil else { return }
        clearPacketBuffers()
        clearPendingVideoFrames()
        clearPendingPCM()
    }

    private func clearPendingPCM() {
        audioTimelineBuffer.reset()
        audioTimelineAdjustmentLogCount = 0
        audioDecodeTimingLogCount = 0
    }

    private var lastPresentNotReadyLogAt: TimeInterval = 0
    private var presentFeedArmed = false

    private func armPresentFeedIfNeeded() {
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

    private func disarmPresentFeed() {
        presentFeedArmed = false
        (videoRender as? SampleBufferVideoRenderer)?.stopRequestingMediaData()
    }

    private enum PresentDrainResult {
        case blockedOnASBD
        case waitingOnEnhancement
        case nothingDue
        case enqueued
    }

    private func drainPresentFeedFromASBD(_ renderer: SampleBufferVideoRenderer) {
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

    private func enqueueDueFramesWhileASBDReady(
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

    private func recordAdmittedVideoHead(_ head: MediaVideoFrame) {
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

    private func reportLateVideoPresentBurst(firstPTS: TimeInterval?, enqueued: Int) {
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

    private func presentDueVideoFrames() {
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

    private func resetVideoLivenessState(resetStartup: Bool) {
        videoLivenessDetector.reset()
        videoLivenessWindowIndex = 0
        videoLivenessPacketDurations = []
        videoLivenessOutputPeriods = []
        videoLivenessPTSProgress.reset()
        if resetStartup {
            videoLivenessStartupUptime = 0
        }
        resetVideoLivenessWindowCounters()
        resetPipeInstrumentWindow()
    }

    private func resetPipeInstrumentWindow(clearSample: Bool = true) {
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

    private func resetFlowGapTracking() {
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

    private func ingestStarvationFloor(_ queue: ContentSecondQueue) -> TimeInterval {
        max(queue.lowWater * 0.5, 0.25)
    }

    private func noteFlowStage(
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

    private func maybeReportPipeInstrument() {
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
        let samples = (videoLivenessPacketDurations + videoLivenessOutputPeriods)
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        guard !samples.isEmpty else { return nil }
        return samples[samples.count / 2]
    }

    private func noteVideoLivenessOutput(_ frame: MediaVideoFrame) {
        noteVideoLivenessOutput(pts: frame.pts)
    }

    private func noteVideoLivenessOutput(pts: TimeInterval) {
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
            if videoLivenessOutputPeriods.count > 32 {
                videoLivenessOutputPeriods.removeFirst()
            }
        }
    }

    private func logPresentBackpressureIfNeeded(_ error: Error) {
        pipeWindowRendererBlocked = true
        if error.localizedDescription.lowercased().contains("failed") {
            pipeWindowRendererFailed = true
        }
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

    private func applyDisplayPlayback(rate: Float, presentation: MediaAudioPresentationSnapshot? = nil) {
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

    private var currentNativeDisplayTime: TimeInterval? {
        guard let renderer = videoRender as? SampleBufferVideoRenderer else { return nil }
        let time = renderer.displayClockSeconds
        return time.isFinite ? max(0, time) : nil
    }

    private func pinDisplay(rate: Float, time: TimeInterval, offset: TimeInterval?) {
        guard time.isFinite else { return }
        videoRender.setDisplayPlayback(rate: max(0, rate), mediaTime: max(0, time))
        lastDisplayResyncPresentationTime = max(0, time)
        lastDisplayPresentationOffset = offset
        lastDisplayPinGeneration = generation
    }

    private func holdDisplayForAudioOutput() {
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

    private func clearDisplayOutputContinuity() {
        audioOutputDisplayHold = nil
        lastDisplayPinGeneration = nil
        lastDisplayPresentationOffset = nil
        lastDisplayResyncPresentationTime = -1
    }

    private func resetDisplayTimeline(to time: TimeInterval) {
        clearDisplayOutputContinuity()
        pinDisplay(rate: 0, time: time, offset: nil)
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

    private func maybeResyncDisplaySlave() {
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

    private func enqueuePendingVideoFrame(_ frame: MediaVideoFrame) {
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

    private func resetOutputMediaFloor(to mediaTime: TimeInterval) {
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
    private func advanceOutputMediaFloor(
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

        var removed = 0
        var retained: [MediaVideoFrame] = []
        retained.reserveCapacity(pendingVideoFrames.count)
        for frame in pendingVideoFrames {
            if isVideoFrameUsableAtOutputFloor(frame, floor: requestedFloor) {
                retained.append(frame)
            } else {
                removed += 1
                noteStaleVideoOutputRejection(frame)
            }
        }
        activeWarmDiagnostics?.bankedFramesExpired += removed
        pendingVideoFrames = retained
        pendingVideoContentSeconds = retained.reduce(0) {
            $0 + max(0, $1.duration)
        }

        if removed > 0 {
            let range = staleVideoOutputRejectionRangeDescription()
            diagnostics.log(
                "[PathA][continuation] output floor advanced " +
                    "reason=\(reason) " +
                    "from=\(String(format: "%.3f", previousFloor)) " +
                    "to=\(String(format: "%.3f", requestedFloor)) " +
                    "rejected=\(removed) " +
                    "range=\(range)"
            )
        }
        return removed
    }

    private func isVideoFrameUsableAtOutputFloor(
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

    private func noteStaleVideoOutputRejection(_ frame: MediaVideoFrame) {
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

    private func staleVideoOutputRejectionRangeDescription() -> String {
        guard let minPTS = staleVideoOutputRejectionMinPTS,
              let maxPTS = staleVideoOutputRejectionMaxPTS else {
            return "n/a"
        }
        return String(format: "%.3f..%.3f", minPTS, maxPTS)
    }

    private func shouldDropVideoBeforeOutputFloor(_ frame: MediaVideoFrame) -> Bool {
        !isVideoFrameUsableAtOutputFloor(frame, floor: outputMediaFloor)
    }

    private func noteVideoDecodeFrontier(_ pts: TimeInterval) {
        guard pts.isFinite else { return }
        videoDecodeFrontierPTS = max(videoDecodeFrontierPTS ?? pts, pts)
    }

    private func noteAudioDecodeFrontier(_ endPTS: TimeInterval) {
        guard endPTS.isFinite else { return }
        audioDecodeFrontierPTS = max(audioDecodeFrontierPTS ?? endPTS, endPTS)
    }

    private func logPrerollSuppression(context: String) {
        guard droppedPrerollVideoFrameCount > 0
                || droppedPrerollAudioFrameCount > 0
                || trimmedPrerollAudioSampleFrameCount > 0
        else {
            return
        }
        diagnostics.log(
            "[PathA] \(context) preroll suppressed " +
            "target=\(String(format: "%.3f", outputMediaFloor)) " +
            "dropV=\(droppedPrerollVideoFrameCount) " +
            "dropA=\(droppedPrerollAudioFrameCount) " +
            "trimASamples=\(trimmedPrerollAudioSampleFrameCount) " +
            "pendingV=\(pendingVideoFrameCount) " +
            "pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s"
        )
    }

    private var videoFrameQueueNeedsFill: Bool {
        if holdsPassThroughVideo {
            if !canAcceptAnotherPassThroughVideoPacket() { return false }
            return pendingVideoContentSeconds < min(videoFrameQueueHighWater, 0.5)
        }
        return pendingVideoContentSeconds < videoFrameQueueHighWater
    }

    private func beginVideoReadGeneration() -> UInt64 {
        if nextVideoReadGeneration < .max {
            nextVideoReadGeneration += 1
        }
        return nextVideoReadGeneration
    }

    private func videoReadBytesDelta(
        since token: DemandVideoSuspendToken
    ) -> Int {
        let (delta, overflowed) = videoReadBytes
            .subtractingReportingOverflow(token.videoReadBytesAtSuspend)
        guard !overflowed else { return .max }
        return max(0, delta)
    }

    private func queueFillDiagnosticSnapshot() -> MediaQueueFillSnapshot {
        let nativeAudio = audioRender as? EngineAudioRenderer
        return MediaQueueFillSnapshot(
            videoSeconds: videoPacketQueue.contentSeconds,
            audioSeconds: audioPacketQueue.contentSeconds,
            pcmSeconds: pendingAudioContentSeconds,
            ringSeconds: nativeAudio?.renderRingContentSeconds,
            videoFrameSeconds: pendingVideoContentSeconds,
            sourceUnderflows: nativeAudio?.sourceUnderflowCount
        )
    }

    private func fillQueuesToHighWater(
        generation gen: Int,
        initiator: MediaQueueFillInitiator,
        phase: MediaQueueFillPhase,
        videoContentCap: TimeInterval? = nil,
        audioContentCap: TimeInterval? = nil,
        audioDecodeOperationID: UInt64? = nil
    ) async throws {
        guard isCurrentGeneration(gen),
              isCurrentAudioDecodeOperation(audioDecodeOperationID) else {
            return
        }
        if isFillingQueues { return }
        isFillingQueues = true
        defer { isFillingQueues = false }
        lastFillProducedPackets = false
        let effectiveVideoHWM: TimeInterval
        if warmVideoImageHoldWithholdsVideoSupply {
            effectiveVideoHWM = 0
        } else if isVideoLaneWarmSuspended {
            effectiveVideoHWM = suspendedVideoSupplyTarget
        } else if holdsPassThroughVideo {
            effectiveVideoHWM = min(
                videoPacketQueue.highWater,
                runtimePassThroughVideoContentHWM
            )
        } else {
            effectiveVideoHWM = videoPacketQueue.highWater
        }
        let videoTarget = min(effectiveVideoHWM, videoContentCap ?? effectiveVideoHWM)
        let audioTarget = min(
            audioPacketQueue.highWater,
            audioContentCap ?? audioPacketQueue.highWater
        )
        let isPriming = videoContentCap != nil || audioContentCap != nil
        var lastLoggedDepth: TimeInterval = -primeProgressLogInterval
        let previousVideoCap = videoEnqueueCap
        videoEnqueueCap = videoTarget
        defer { videoEnqueueCap = previousVideoCap }
        var pace: MediaQueueFillTrace?
        if diagnostics.isCapturing {
            nextQueueFillTraceID &+= 1
            pace = MediaQueueFillTrace(
                generation: gen,
                fillID: nextQueueFillTraceID,
                initiator: initiator,
                phase: phase,
                priming: isPriming,
                seeking: isSeekInFlight,
                playing: isPlaying,
                warmSuspended: isVideoLaneWarmSuspended,
                entry: queueFillDiagnosticSnapshot()
            )
        }
        defer {
            if diagnostics.isCapturing, let pace, pace.attempts > 0 {
                let operationCurrent = audioDecodeOperationID.map {
                    activeAudioDecodeOperationID == $0
                        || (pace.initiatedRuntimeFault
                            && runtimeFaultedGeneration == gen
                            && activeAudioDecodeOperationID == nil)
                } ?? true
                let ownerCurrent = gen == generation
                    && operationCurrent
                    && warmPreparationTransaction.orphan == nil
                let current = ownerCurrent && isCurrentGeneration(gen)
                    && isCurrentAudioDecodeOperation(audioDecodeOperationID)
                let outcome: MediaQueueFillTrace.Outcome
                if !ownerCurrent {
                    outcome = .superseded
                } else if pace.outcome == .error {
                    outcome = .error
                } else if Task.isCancelled {
                    outcome = .cancelled
                } else {
                    outcome = current ? pace.outcome : .superseded
                }
                diagnostics.log(pace.endLine(
                    outcome: outcome,
                    exit: current ? queueFillDiagnosticSnapshot() : nil
                ))
            }
        }

        while isCurrentGeneration(gen) {
            guard !Task.isCancelled,
                  isCurrentAudioDecodeOperation(audioDecodeOperationID) else {
                return
            }

            drainResidualPackets()

            let videoDepth = isVideoLaneWarmSuspended
                ? suspendedVideoRunway
                : videoPacketQueue.contentSeconds
            let audioDepth = audioPacketQueue.contentSeconds
            let residualBlockingVideo = !isVideoLaneWarmSuspended
                && !residualVideoPackets.isEmpty
            let residualBlockingAudio = hasAudioTrack && !residualAudioPackets.isEmpty

            let videoAtMemoryCap = !isVideoLaneWarmSuspended && holdsPassThroughVideo
                && !canAcceptAnotherPassThroughVideoPacket()
            let videoNeeds = !videoAtMemoryCap && !residualBlockingVideo
                && (videoTarget - videoDepth) >= minTrackFillRoom
            let audioNeeds = hasAudioTrack && !residualBlockingAudio
                && (audioTarget - audioDepth) >= minTrackFillRoom
            let needsMore: Bool
            if isPriming || holdsPassThroughVideo {
                needsMore = videoNeeds || audioNeeds
            } else {
                needsMore = needsPacketFill()
            }
            guard needsMore else { break }

            let reachedEOF = await demux.isEOF
            guard !Task.isCancelled, isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(audioDecodeOperationID),
                  warmPreparationTransaction.orphan == nil else {
                return
            }
            if reachedEOF {
                demuxReachedEOF = true
                break
            }

            let currentVideoTarget: TimeInterval
            if warmVideoImageHoldWithholdsVideoSupply {
                currentVideoTarget = 0
            } else if isVideoLaneWarmSuspended {
                currentVideoTarget = min(videoTarget, suspendedVideoSupplyTarget)
            } else {
                currentVideoTarget = videoTarget
            }
            let videoBudget = videoNeeds
                ? min(max(0, currentVideoTarget - videoDepth), pumpCallBudgetCapSeconds)
                : 0
            let audioBudget = audioNeeds
                ? min(max(0, audioTarget - audioDepth), pumpCallBudgetCapSeconds)
                : 0
            guard videoBudget > 0.000_5 || audioBudget > 0.000_5 else { break }

            let packets: [MediaPacket]
            let acceptedPacketsBeforePump = totalVideoPacketsIngested + totalAudioPacketsIngested
            let videoReadGeneration = videoBudget > 0.000_5
                ? beginVideoReadGeneration()
                : nil
            resetCachedRunway(
                video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5
            )
            var sourceWaitBudget: MediaSourceWaitBudget?
            defer {
                if activeSourceWaitBudget?.id == sourceWaitBudget?.id {
                    activeSourceWaitBudget = nil
                }
                sourceWaitBudget?.cancel()
            }
            do {
                if hasMultiConnectionHelpers {
                    lastMultiConnectionPlaybackPosition = mediaTime
                    await demux.updateMultiConnectionPlayback(position: mediaTime, rate: playbackRate)
                }
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil,
                      !Task.isCancelled else { return }
                sourceWaitBudget = beginSourceWaitBudget()
                if diagnostics.isCapturing, pace != nil {
                    if let trace = pace, trace.attempts == 0 {
                        diagnostics.log(trace.beginLine)
                    }
                    pace?.attempts += 1
                }
                packets = try await demux.pump(
                    videoBudget: videoBudget,
                    audioBudget: audioBudget,
                    sourceWaitBudget: sourceWaitBudget
                )
                if isCurrentGeneration(gen), !Task.isCancelled,
                   !packets.isEmpty
                    || totalVideoPacketsIngested + totalAudioPacketsIngested > acceptedPacketsBeforePump {
                    unresolvedPrimaryTransportFailure = nil
                }
                if diagnostics.isCapturing, pace != nil, !packets.isEmpty {
                    pace?.pumps += 1
                    pace?.packets += packets.count
                    pace?.gathered += packets.reduce(0) { $0 + $1.duration }
                }
            } catch let error as MediaEngineError {
                if diagnostics.isCapturing {
                    pace?.outcome = Self.isExpectedCancelledPumpExit(
                        error, taskWasCancelled: Task.isCancelled
                    ) ? .cancelled : .error
                }
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil else {
                    return
                }
                resetCachedRunway(video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5)
                if Self.isExpectedCancelledPumpExit(
                    error,
                    taskWasCancelled: Task.isCancelled
                ) {
                    unresolvedPrimaryTransportFailure = nil
                    return
                }
                if error.demuxFailureKind == .liveMapChangedReloadRequired {
                    if !isReady || isSeekInFlight {
                        throw error
                    }
                    let fault = MediaRuntimeFault(
                        subsystem: .demux,
                        stage: .pump,
                        classification: .input,
                        recoverability: .automaticSourceAwareReopen,
                        ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                        diagnostics: MediaRuntimeFaultDiagnostics(
                            label: "hlsMapChanged",
                            details: "reload-required"
                        )
                    )
                    if diagnostics.isCapturing { pace?.initiatedRuntimeFault = true }
                    publishRuntimeFault(fault, generation: gen)
                    return
                }
                if isCurrentGeneration(gen),
                   error.demuxFailureKind == .stickyFMP4InputRejection
                    || error.demuxFailureKind == .terminalLiveInputRejection {
                    let fault = MediaRuntimeFault(
                        subsystem: .demux,
                        stage: .pump,
                        classification: .input,
                        recoverability: .manualRetry,
                        ownerLeaseGeneration: videoLivenessContext?.ownerLeaseGeneration ?? 0,
                        diagnostics: MediaRuntimeFaultDiagnostics(
                            label: "demux",
                            details: error.localizedDescription
                        )
                    )
                    if !isReady || isSeekInFlight {
                        throw error
                    }
                    if diagnostics.isCapturing { pace?.initiatedRuntimeFault = true }
                    publishRuntimeFault(fault, generation: gen)
                    return
                }
                if isCurrentGeneration(gen) {
                    diagnostics.log("[PathA] pump failed: \(error.localizedDescription)")
                }
                if !isReady || isSeekInFlight {
                    throw error
                }
                unresolvedPrimaryTransportFailure = StreamTransportFailure.preserving(error, stage: .mediaSupply)?
                    .stamped(backend: activeOwnerGeneration, session: runtimeGeneration)
                break
            } catch {
                if diagnostics.isCapturing {
                    pace?.outcome = error is CancellationError ? .cancelled : .error
                }
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil else {
                    return
                }
                resetCachedRunway(video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5)
                if isCurrentGeneration(gen) {
                    diagnostics.log("[PathA] pump failed: \(error.localizedDescription)")
                }
                if Task.isCancelled
                    || StreamTransportFailure.preserving(error, stage: .mediaSupply)?.isCancellation == true {
                    unresolvedPrimaryTransportFailure = nil
                    return
                }
                if !isReady || isSeekInFlight {
                    throw transportEngineError(error, stage: isSeekInFlight ? .mediaSeek : .mediaOpen)
                }
                unresolvedPrimaryTransportFailure = StreamTransportFailure.preserving(error, stage: .mediaSupply)?
                    .stamped(backend: activeOwnerGeneration, session: runtimeGeneration)
                break
            }
            guard isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(audioDecodeOperationID),
                  warmPreparationTransaction.orphan == nil else { return }
            if packets.isEmpty {
                if diagnostics.isCapturing { pace?.outcome = .empty }
                let reachedEOF = await demux.isEOF
                guard isCurrentGeneration(gen),
                      isCurrentAudioDecodeOperation(audioDecodeOperationID),
                      warmPreparationTransaction.orphan == nil else {
                    return
                }
                if reachedEOF {
                    demuxReachedEOF = true
                }
                break
            }
            ingest(
                packets,
                videoReadGeneration: videoReadGeneration
            )
            lastFillProducedPackets = true
            resolveVideoStarvationIfRecovered()
            if isSeekInFlight, !seekFirstPacketLogged, !packets.isEmpty {
                seekFirstPacketLogged = true
                diagnostics.log(
                    "[PathA] seek-first-packet count=\(packets.count) " +
                    "firstPTS=\(String(format: "%.2f", packets.first?.pts ?? -1))"
                )
            }
            drainResidualPackets()

            if isPriming {
                let depth = hasAudioTrack
                    ? max(videoPacketQueue.contentSeconds, audioPacketQueue.contentSeconds)
                    : videoPacketQueue.contentSeconds
                if depth - lastLoggedDepth >= primeProgressLogInterval - 1e-9 {
                    lastLoggedDepth = depth
                    diagnostics.log(
                        "[PathA] prime progress vPkts=\(videoPacketCount) " +
                        "aPkts=\(audioPacketCount) " +
                        "vDepth=\(String(format: "%.2f", videoPacketQueue.contentSeconds))s " +
                        "aDepth=\(String(format: "%.2f", audioPacketQueue.contentSeconds))s " +
                        "cap video packets \(maxPassThroughVideoPackets())"
                    )
                }
            }
        }

        if isCurrentGeneration(gen),
           isCurrentAudioDecodeOperation(audioDecodeOperationID) {
            await refreshCachedRunway(generation: gen)
            let reachedEOF = await demux.isEOF
            guard isCurrentGeneration(gen),
                  isCurrentAudioDecodeOperation(audioDecodeOperationID),
                  warmPreparationTransaction.orphan == nil else {
                return
            }
            if reachedEOF {
                demuxReachedEOF = true
            }
            if isReady, !isSeekInFlight {
                onEvent?(.tick(
                    mediaTime: clock.mediaTime,
                    duration: clock.duration,
                    buffered: bufferedTime
                ))
            }
        }
    }

    private func decoderReadinessFault(generation gen: Int) async -> String? {
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
        guard hasAudioTrack else {
            return "no audio track (video-only input) — mediaTime advances only " +
                "from rendered audio, so this session would have no media clock"
        }
        if !audioDecoderOpened {
            return "audio decoder \(type(of: audioDecoder)) did not open" +
                (lastAudioDecoderOpenError.map { " (\($0))" } ?? "")
        }
        return nil
    }

    private func openVideoDecoderIfNeeded(
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
                codec: codec, config: config, codedDimensions: track?.codedDimensions
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
        guard let track else { return }
        var message = "[PathA] video decoder open codec=\(track.codec) config=\(track.config.count)B"
        if track.codec.lowercased() == "av01" {
            let codedSize = track.codedDimensions.map { "\($0.width)x\($0.height)" }
            message += " coded=\(codedSize ?? "missing-or-invalid")"
        }
        diagnostics.log(message)
    }

    private func finishVideoDecoderOpen(
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

    private func installFreshVideoDecoder(
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
        videoDecoderFactoryInvocationCount += 1
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
    private func retireCurrentVideoDecoderWithoutWaiting() -> Bool {
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
    private func enqueueVideoDecoderRetirement(
        _ decoder: any MediaVideoDecoding
    ) -> Bool {
        if openingVideoDecoders[ObjectIdentifier(decoder)] != nil {
            return requestVideoDecoderRetirement(decoder)
        }
        return enqueueDetachedVideoDecoderRetirement(decoder)
    }

    @discardableResult
    private func requestVideoDecoderRetirement(
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
    private func enqueueDetachedVideoDecoderRetirement(
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

    private var videoDecoderRetirementCount: Int {
        outstandingVideoDecoderRetirements.count + openingVideoDecoders.reduce(0) {
            result, entry in
            result + (entry.value.retirementNeeded
                && outstandingVideoDecoderRetirements[entry.key] == nil ? 1 : 0)
        }
    }

    private var videoDecoderRetirementCapacityAvailableForOpening: Bool {
        videoDecoderRetirementCapacityUsed < Self.maxOutstandingVideoDecoderRetirements
    }

    private func drainPendingVideoDecoderRetirements() {
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

    private func completeVideoDecoderRetirement(
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

    private func openAudioDecoderIfNeeded() async {
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

    private func startAudioRenderIfNeeded(reconcileAuthorizedOutput: Bool = false) {
        guard isPlaying, audioDecoderOpened else { return }
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
        } catch {
            diagnostics.log("[PathA] audio render start skipped: \(error.localizedDescription)")
        }
    }

    private func scheduleVideoDecodeIfNeeded() {
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

    private func scheduleAudioDecodeIfNeeded() {
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

    private func beginVideoDecodeOperation() -> UInt64 {
        nextVideoDecodeOperationID &+= 1
        if nextVideoDecodeOperationID == 0 {
            nextVideoDecodeOperationID = 1
        }
        activeVideoDecodeOperationID = nextVideoDecodeOperationID
        return nextVideoDecodeOperationID
    }

    private func beginAudioDecodeOperation() -> UInt64 {
        nextAudioDecodeOperationID &+= 1
        if nextAudioDecodeOperationID == 0 {
            nextAudioDecodeOperationID = 1
        }
        activeAudioDecodeOperationID = nextAudioDecodeOperationID
        return nextAudioDecodeOperationID
    }

    private func isCurrentVideoDecodeOperation(_ operationID: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let operationID else { return true }
        return activeVideoDecodeOperationID == operationID
    }

    private func isCurrentAudioDecodeOperation(_ operationID: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let operationID else { return true }
        return activeAudioDecodeOperationID == operationID
    }

    private func finishVideoDecodeOperation(
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

    private func finishAudioDecodeOperation(
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

    private func fillPCMRing(
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

    private func joinScheduledVideoDecodeAndAcquireDirectLane(
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

    private func drainVideoDecodeBurst(
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
            } catch let fault as MediaRuntimeFault {
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
                if isSeekInFlight {
                    logSeekTrace(
                        phase: "fault",
                        target: clock.mediaTime,
                        token: activeSeekToken,
                        result: false
                    )
                }
                publishRuntimeFault(fault, generation: gen)
                return
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
                if isCurrentGeneration(gen) {
                    let fault = Self.unknownVideoDecodeFault()
                    if isSeekInFlight {
                        logSeekTrace(
                            phase: "fault",
                            target: clock.mediaTime,
                            token: activeSeekToken,
                            result: false
                        )
                    }
                    diagnostics.log(
                        "[PathA] video decode failed; publishing terminal runtime fault"
                    )
                    publishRuntimeFault(fault, generation: gen)
                }
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

    private func noteVideoPacketDequeued(_ packet: MediaPacket) {
        pipeWindowVideoPacketsDequeued += 1
        pipeWindowVideoInputSeconds += max(0, packet.duration)
        totalVideoPacketsDequeued += 1
        totalVideoInputContentSecondsConsumed += max(0, packet.duration)
        if packet.duration.isFinite, packet.duration > 0 {
            videoLivenessPacketDurations.append(packet.duration)
            if videoLivenessPacketDurations.count > 32 {
                videoLivenessPacketDurations.removeFirst()
            }
        }
        let drained = videoPacketQueue.drain(content: packet.duration)
        if drained + 1e-9 < packet.duration {
            videoPacketQueue.reset()
            for p in videoPackets {
                _ = videoPacketQueue.enqueue(content: p.duration)
            }
        }
    }

    private func noteVideoPacketSubmitted() {
        pipeWindowVideoPacketsSubmitted += 1
        totalVideoPacketsSubmitted += 1
        noteFlowStage(&flowDecInV, "decInV")
    }

    // MARK: - Seek / resume-open fast preroll (task 10-03, design §3–§5)

    private enum PrerollContext {
        case seek(MediaAudioSeekToken)
        case open

        var isSeek: Bool {
            if case .seek = self { return true }
            return false
        }
    }

    static func unknownVideoDecodeFault() -> MediaRuntimeFault {
        MediaRuntimeFault(
            subsystem: .videoDecoder,
            stage: .decodeSubmission,
            classification: .unknown,
            recoverability: VideoToolboxDecoder.recoverability(for: .unknown),
            diagnostics: MediaRuntimeFaultDiagnostics(
                status: nil,
                label: "decode"
            )
        )
    }

    private func prerollContextIsCurrent(_ context: PrerollContext, generation gen: Int) -> Bool {
        guard isCurrentGeneration(gen) else { return false }
        if case .seek(let token) = context {
            return activeSeekToken == token
        }
        return true
    }

    private func installVideoPrerollClassifier(
        codec: String?,
        config: Data,
        decoder identity: ObjectIdentifier
    ) {
        guard videoDecoderOpened, ObjectIdentifier(videoDecoder) == identity else { return }
        videoPrerollCodec = codec
        if activePrerollStats != nil, activePrerollStatsGeneration == generation {
            activePrerollStats?.codec = codec ?? "unknown"
            prerollAnomalyBaseline = (identity, videoDecoder.decodeAnomalyCounters)
        }
        guard seekFastPrerollEnabled else {
            videoPrerollClassifier = nil
            videoPrerollClassifierDecoder = nil
            return
        }
        videoPrerollClassifier = videoPrerollClassifierFactory(codec, config)
        videoPrerollClassifierDecoder = identity
    }

    static func isPrerollBatchCandidate(
        _ packet: MediaPacket,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        packet.pixelBuffer == nil
            && OutputFloorPolicy.isPreTarget(pts: packet.pts, floor: floor, epsilon: epsilon)
    }

    private func isPrerollBatchCandidate(_ packet: MediaPacket) -> Bool {
        Self.isPrerollBatchCandidate(
            packet,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        )
    }

    static func relayDecodeYieldsToPrerollBatch(
        batchingActive: Bool,
        head: MediaPacket?,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard batchingActive, let head else { return false }
        return isPrerollBatchCandidate(head, floor: floor, epsilon: epsilon)
    }

    private func classifyVideoPrerollSample(_ packet: MediaPacket) -> VideoPrerollSampleAction {
        guard !packet.data.isEmpty,
              packet.pixelBuffer == nil,
              videoPrerollClassifier != nil,
              videoPrerollClassifierDecoder == ObjectIdentifier(videoDecoder) else {
            return .submit
        }
        return videoPrerollClassifier?.classify(packet.data, isKeyframe: packet.isKeyframe) ?? .submit
    }

    private func observeVideoPrerollSample(_ packet: MediaPacket) {
        guard activePrerollStats != nil, activePrerollStatsGeneration == generation else { return }
        _ = classifyVideoPrerollSample(packet)
    }

    private func beginPrerollStats(context: SeekPrerollStats.Context, generation gen: Int) {
        activePrerollStats = SeekPrerollStats(
            context: context,
            mode: seekFastPrerollEnabled ? .fast : .legacy,
            codec: videoPrerollCodec ?? "unknown",
            target: outputMediaFloor
        )
        activePrerollStatsGeneration = gen
        prerollAnomalyBaseline = (ObjectIdentifier(videoDecoder), videoDecoder.decodeAnomalyCounters)
    }

    private func notePrerollFill(generation gen: Int, startedAt: ContinuousClock.Instant?) {
        guard activePrerollStats != nil, activePrerollStatsGeneration == gen else { return }
        activePrerollStats?.fills += 1
        if let startedAt {
            activePrerollStats?.fillSeconds += SeekPhaseStopwatch.seconds(startedAt.duration(to: .now))
        }
    }

    private func finishPrerollStats(generation gen: Int, token: MediaAudioSeekToken?) {
        guard var stats = activePrerollStats, activePrerollStatsGeneration == gen else { return }
        activePrerollStats = nil
        activePrerollStatsGeneration = nil
        stats.mode = seekFastPrerollEnabled && !holdsPassThroughVideo ? .fast : .legacy
        if stats.codec == "unknown", let codec = videoPrerollCodec {
            stats.codec = codec
        }
        stats.discarded = droppedPrerollVideoFrameCount
        stats.firstTargetSidePTS = pendingVideoFrames.first?.pts
        let identity = ObjectIdentifier(videoDecoder)
        let baseline = prerollAnomalyBaseline.flatMap { $0.decoder == identity ? $0.counters : nil }
        stats.anomalies = videoDecoder.decodeAnomalyCounters.delta(since: baseline)
        prerollAnomalyBaseline = nil
        lastPrerollStats = stats
        diagnostics.log(stats.logLine(token: token?.generation))
    }

    private func markSeekPhaseCommitAck(_ token: MediaAudioSeekToken) {
        guard seekPhaseStopwatch?.token == token.generation else { return }
        seekPhaseStopwatch?.mark(.commitAck)
    }

    private func presentDueVideoFramesReportingPresentation() -> Bool {
        let before = presentedVideoFrameCount
        presentDueVideoFrames()
        return presentedVideoFrameCount > before
    }

    private func emitSeekPhase(token: MediaAudioSeekToken, result: Bool, presented: Bool) {
        guard let stopwatch = seekPhaseStopwatch, stopwatch.token == token.generation else { return }
        seekPhaseStopwatch = nil
        guard stopwatch.isEnabled else { return }
        diagnostics.log(stopwatch.logLine(result: result, presented: presented))
    }

    private func drainPrerollBatches(generation gen: Int, context: PrerollContext) async throws {
        guard seekFastPrerollEnabled, !holdsPassThroughVideo, videoDecoderOpened,
              outputMediaFloor > outputMediaFloorEpsilon,
              prerollContextIsCurrent(context, generation: gen) else {
            return
        }
        prerollBatchingActive = true
        defer { prerollBatchingActive = false }
        while !Task.isCancelled, prerollContextIsCurrent(context, generation: gen), videoDecoderOpened {
            if videoPackets.isEmpty {
                drainResidualPackets()
            }
            if videoPackets.isEmpty {
                guard prerollRunUpIsOutstanding, !(await demux.isEOF),
                      prerollContextIsCurrent(context, generation: gen) else {
                    return
                }
                let fillStart: ContinuousClock.Instant? = diagnostics.isCapturing ? .now : nil
                try await fillQueuesToHighWater(
                    generation: gen,
                    initiator: .preroll,
                    phase: context.isSeek ? .seek : .open,
                    videoContentCap: primeVideoContentBudget,
                    audioContentCap: context.isSeek
                        ? audioSeekPumpContentBudget
                        : audioLaunchPumpContentBudget
                )
                guard prerollContextIsCurrent(context, generation: gen) else { return }
                notePrerollFill(generation: gen, startedAt: fillStart)
                drainResidualPackets()
                if videoPackets.isEmpty { return }
                continue
            }
            guard let head = videoPackets.first, isPrerollBatchCandidate(head) else { return }
            guard await joinScheduledVideoDecodeAndAcquireDirectLane(
                generation: gen,
                warmPreparationAttempt: nil
            ) else { return }
            guard await runPrerollBatch(generation: gen, context: context) else { return }
        }
    }

    private var prerollRunUpIsOutstanding: Bool {
        guard let frontier = videoDecodeFrontierPTS else { return true }
        return OutputFloorPolicy.isPreTarget(
            pts: frontier,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        )
    }

    private func runPrerollBatch(generation gen: Int, context: PrerollContext) async -> Bool {
        videoDecodeLaneOwners += 1
        defer { videoDecodeLaneOwners -= 1 }
        defer { directVideoDecodeLane.release() }

        let submissions = takePrerollBatch(generation: gen)
        guard !submissions.isEmpty else { return true }
        let decoder = videoDecoder
        let decoderIdentity = ObjectIdentifier(decoder)
        let floor = outputMediaFloor
        let epsilon = outputMediaFloorEpsilon
        let keepOutput: @Sendable (TimeInterval, TimeInterval) -> Bool = { pts, duration in
            OutputFloorPolicy.isUsable(pts: pts, duration: duration, floor: floor, epsilon: epsilon)
        }
        let decodeStart: ContinuousClock.Instant? = diagnostics.isCapturing ? .now : nil
        let result: VideoPrerollBatchResult
        do {
            result = try await decoder.decodePrerollBatch(submissions, keepOutput: keepOutput)
        } catch {
            guard prerollContextIsCurrent(context, generation: gen),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return false
            }
            publishPrerollBatchFault(error, generation: gen)
            return false
        }
        guard prerollContextIsCurrent(context, generation: gen),
              ObjectIdentifier(videoDecoder) == decoderIdentity else {
            return false
        }
        notePrerollBatchStats(result, items: submissions.count, generation: gen, decodeStart: decodeStart)
        applyPrerollBatchOutput(result)
        return true
    }

    private func takePrerollBatch(generation gen: Int) -> [VideoPrerollSubmission] {
        var submissions: [VideoPrerollSubmission] = []
        while submissions.count < Self.seekPrerollBatchLimit,
              let head = videoPackets.first,
              isPrerollBatchCandidate(head) {
            let packet = videoPackets.removeFirst()
            noteVideoPacketDequeued(packet)
            if activePrerollStatsGeneration == gen {
                activePrerollStats?.noteAnchor(packet.pts)
            }
            let action = classifyVideoPrerollSample(packet)
            if action != .skip {
                noteVideoPacketSubmitted()
                tracing.mark(.demandFirstVideoSubmit, token: activeStartupTraceToken)
            }
            submissions.append(VideoPrerollSubmission(packet: packet, action: action))
        }
        return submissions
    }

    private func publishPrerollBatchFault(_ error: Error, generation gen: Int) {
        let fault: MediaRuntimeFault
        if let typed = error as? MediaRuntimeFault {
            fault = typed
        } else {
            fault = Self.unknownVideoDecodeFault()
            diagnostics.log("[PathA] video decode failed; publishing terminal runtime fault")
        }
        if isSeekInFlight {
            logSeekTrace(
                phase: "fault",
                target: clock.mediaTime,
                token: activeSeekToken,
                result: false
            )
        }
        publishRuntimeFault(fault, generation: gen)
    }

    private func notePrerollBatchStats(
        _ result: VideoPrerollBatchResult,
        items: Int,
        generation gen: Int,
        decodeStart: ContinuousClock.Instant?
    ) {
        guard activePrerollStatsGeneration == gen, var stats = activePrerollStats else { return }
        stats.batches += 1
        stats.items += items
        stats.submitted += result.submitted
        stats.skipped += result.skipped
        stats.truncated += result.truncated
        stats.truncatedBytes += result.truncatedBytes
        stats.kept += result.keptFrames.count
        if let decodeStart {
            stats.decodeSeconds += SeekPhaseStopwatch.seconds(decodeStart.duration(to: .now))
        }
        activePrerollStats = stats
    }

    private func applyPrerollBatchOutput(_ result: VideoPrerollBatchResult) {
        pipeWindowVideoCallbacks += result.submitted
        if !result.outputPTS.isEmpty {
            noteFlowStage(&flowDecOutV, "decOutV")
            tracing.mark(.demandFirstVideoOutput, token: activeStartupTraceToken)
        }
        decodedVideoFrameCount += result.outputPTS.count
        pipeWindowDecodeFrames += result.outputPTS.count
        for pts in result.outputPTS {
            noteVideoLivenessOutput(pts: pts)
            noteVideoDecodeFrontier(pts)
        }
        droppedPrerollVideoFrameCount += result.discardedFrames
        for frame in result.keptFrames {
            noteVideoFrameSize(from: frame.pixelBuffer)
            if shouldDropVideoBeforeOutputFloor(frame) {
                droppedPrerollVideoFrameCount += 1
                continue
            }
            enqueuePendingVideoFrame(frame)
        }
        maybeReportPipeInstrument()
    }

    private func primeVideoRunwayAfterPreroll(
        generation gen: Int,
        phase: MediaQueueFillPhase
    ) async throws {
        while isCurrentGeneration(gen), videoDecoderOpened, videoFrameQueueNeedsFill {
            if Task.isCancelled { return }
            if videoPackets.isEmpty {
                drainResidualPackets()
                if videoPackets.isEmpty, !(await demux.isEOF) {
                    let fillStart: ContinuousClock.Instant? = diagnostics.isCapturing ? .now : nil
                    try await fillQueuesToHighWater(
                        generation: gen,
                        initiator: .postPreroll,
                        phase: phase,
                        videoContentCap: primeVideoContentBudget,
                        audioContentCap: isSeekInFlight
                            ? audioSeekPumpContentBudget
                            : audioLaunchPumpContentBudget
                    )
                    guard isCurrentGeneration(gen) else { return }
                    notePrerollFill(generation: gen, startedAt: fillStart)
                    drainResidualPackets()
                }
            }
            guard !videoPackets.isEmpty else { break }
            let packetsBefore = videoPackets.count
            let decodedBefore = decodedVideoFrameCount
            await drainVideoDecodeBurst(generation: gen)
            guard isCurrentGeneration(gen) else { return }
            if videoPackets.count >= packetsBefore,
               decodedVideoFrameCount == decodedBefore {
                break
            }
        }
    }

    @discardableResult
    private func drainAudioDecodeBurst(
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
            let drained = audioPacketQueue.drain(content: packet.duration)
            if drained + 1e-9 < packet.duration {
                audioPacketQueue.reset()
                for p in audioPackets {
                    _ = audioPacketQueue.enqueue(content: p.duration)
                }
            }
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
            let snapshot = await audioDecoder.decodeDiagnostics()
            guard isCurrent() else { return false }
            lastAudioDecodeError = error.localizedDescription
            lastAudioDecodeDiagnostics = snapshot
            diagnostics.log("[PathA] audio decode failed: \(error.localizedDescription)")
            return true
        }
        guard isCurrent() else { return false }
        let snapshot = await audioDecoder.decodeDiagnostics()
        guard isCurrent() else { return false }
        lastAudioDecodeDiagnostics = snapshot
        audioDecodePCMFramesProduced += frames.reduce(into: 0) { total, frame in
            guard frame.duration.isFinite, frame.duration > 0,
                  frame.sampleRate.isFinite, frame.sampleRate > 0 else { return }
            total += Int((frame.duration * frame.sampleRate).rounded())
        }
        for frame in frames {
            appendPCM(frame)
            decodedAudioFrameCount += 1
        }
        return true
    }

    private func appendPCM(_ frame: MediaAudioFrame) {
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

    // MARK: - relay drain + video-starvation buffering

    func drainRelayedPackets() {
        if warmPreparationTransaction.orphan != nil {
            packetRelay.reset()
            return
        }
        let packets = packetRelay.drain()
        guard !packets.isEmpty else { return }
        relayDrainCount += 1
        ingest(
            packets,
            warmVideoProvenance: isVideoLaneWarmSuspended
                ? .postSuspend(readGeneration: nextVideoReadGeneration)
                : nil
        )
        lastFillProducedPackets = true
        scheduleVideoDecodeIfNeeded()
        if !isPreparingWarmVideoLane {
            scheduleAudioDecodeIfNeeded()
        }
        resolveVideoStarvationIfRecovered()
    }

    private func evaluateVideoStarvation() {
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

    private func videoStarvationHoldIsActive() -> Bool {
        if bufferingForVideoStarvation, !isBuffering {
            bufferingForVideoStarvation = false
        }
        return bufferingForVideoStarvation
    }

    private func resolveVideoStarvationIfRecovered() {
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

    private static let videoStarvationRunwayFloor: TimeInterval = 0.001
    private static let videoStarvationConfirmWindow: Duration = .milliseconds(300)

    private func applyPipelineDemand(presentation: MediaAudioPresentationSnapshot? = nil) {
        applyDisplayPlayback(rate: effectiveDisplayRate, presentation: presentation)
        audioRender.playbackRate =
            isPlaying && !isSeekInFlight && !videoStarvationHoldIsActive()
            ? max(0, clock.playbackRate)
            : 0
    }

    private func ingest(
        _ packets: [MediaPacket],
        videoReadGeneration: UInt64? = nil,
        warmVideoProvenance: DemandVideoCandidateProvenance? = nil
    ) {
        if packets.contains(where: {
            $0.track == .video || ($0.track == .audio && hasAudioTrack)
        }) {
            tracing.mark(
                .demandFirstSampleReady,
                token: activeStartupTraceToken
            )
        }
        var rejectedVideo = 0
        var rejectedAudio = 0
        for rawPacket in packets {
            let packet = normalizingZeroDuration(rawPacket)
            switch packet.track {
            case .video:
                let (updatedVideoReadBytes, overflowed) = videoReadBytes.addingReportingOverflow(
                    max(0, packet.data.count)
                )
                videoReadBytes = overflowed ? Int.max : updatedVideoReadBytes
                if isVideoLaneWarmSuspended, !isDecodingWarmVideoCandidate {
                    let provenance = warmVideoProvenance
                        ?? .postSuspend(
                            readGeneration: videoReadGeneration
                                ?? nextVideoReadGeneration
                        )
                    retainSuspendedVideoPacket(
                        packet,
                        provenance: provenance
                    )
                    totalVideoPacketsIngested += 1
                    pipeWindowVideoPacketsIngested += 1
                    pipeWindowVideoBytesRead += Int64(packet.data.count)
                    bytesRead += Int64(packet.data.count)
                    continue
                }
                noteFlowStage(
                    &flowIngestV,
                    "ingestV",
                    starvingBelow: ingestStarvationFloor(videoPacketQueue),
                    depth: videoPacketQueue.contentSeconds
                )
                if diagnostics.isCapturing {
                    flowLastIngestVideoPTS = packet.pts
                    if let born = packet.emittedAt {
                        let age = Int(born.duration(to: ContinuousClock.now) / .milliseconds(1))
                        if age > flowWindowMaxPacketAgeMs { flowWindowMaxPacketAgeMs = age }
                    }
                }
                if packet.pixelBuffer != nil {
                    holdsPassThroughVideo = true
                    noteVideoFrameSize(from: packet.pixelBuffer)
                }
                if residualVideoPackets.isEmpty, enqueueVideoPacket(packet) {
                    noteAcceptedPrimaryObservation(packet)
                    totalVideoPacketsIngested += 1
                    pipeWindowVideoPacketsIngested += 1
                    pipeWindowVideoBytesRead += Int64(packet.data.count)
                    let sampleBytes = packet.data.count > 0
                        ? packet.data.count
                        : estimatedVideoFrameBytes()
                    bytesRead += Int64(sampleBytes)
                } else {
                    residualVideoPackets.append(packet)
                    rejectedVideo += 1
                }
            case .audio:
                guard hasAudioTrack else { continue }
                noteFlowStage(
                    &flowIngestA,
                    "ingestA",
                    starvingBelow: ingestStarvationFloor(audioPacketQueue),
                    depth: audioPacketQueue.contentSeconds
                )
                if diagnostics.isCapturing {
                    flowLastIngestAudioPTS = packet.pts
                    if let born = packet.emittedAt {
                        let age = Int(born.duration(to: ContinuousClock.now) / .milliseconds(1))
                        if age > flowWindowMaxPacketAgeMs { flowWindowMaxPacketAgeMs = age }
                    }
                }
                if residualAudioPackets.isEmpty,
                   enqueueFullPacket(packet, queue: &audioPacketQueue, store: &audioPackets) {
                    noteAcceptedPrimaryObservation(packet)
                    totalAudioPacketsIngested += 1
                    bytesRead += Int64(packet.data.count)
                } else {
                    residualAudioPackets.append(packet)
                    rejectedAudio += 1
                }
            }
        }
        if rejectedVideo > 0 || rejectedAudio > 0, diagnostics.isCapturing {
            let firstRejectedPTS = residualVideoPackets.first?.pts
            diagnostics.log(
                "[PathA] residual park v=\(rejectedVideo) a=\(rejectedAudio) " +
                "vRes=\(residualVideoPackets.count) aRes=\(residualAudioPackets.count) " +
                "vQ=\(String(format: "%.2f", videoPacketQueue.contentSeconds))s " +
                "firstV=\(firstRejectedPTS.map { String(format: "%.2f", $0) } ?? "-")"
            )
        }
        enforcePassThroughVideoMemoryBudget(dropOldest: true)
    }

    private func drainResidualPackets() {
        while let head = residualVideoPackets.first {
            if enqueueVideoPacket(head) {
                noteAcceptedPrimaryObservation(head)
                residualVideoPackets.removeFirst()
                totalVideoPacketsIngested += 1
                pipeWindowVideoPacketsIngested += 1
                pipeWindowVideoBytesRead += Int64(head.data.count)
                let sampleBytes = head.data.count > 0
                    ? head.data.count
                    : estimatedVideoFrameBytes()
                bytesRead += Int64(sampleBytes)
            } else {
                break
            }
        }
        while let head = residualAudioPackets.first {
            if enqueueFullPacket(head, queue: &audioPacketQueue, store: &audioPackets) {
                noteAcceptedPrimaryObservation(head)
                residualAudioPackets.removeFirst()
                totalAudioPacketsIngested += 1
                bytesRead += Int64(head.data.count)
            } else {
                break
            }
        }
    }

    private func normalizingZeroDuration(_ packet: MediaPacket) -> MediaPacket {
        guard packet.duration <= 0 else { return packet }
        var normalized = packet
        normalized.duration = packet.track == .video
            ? nominalZeroDurationVideoSeconds
            : nominalZeroDurationAudioSeconds
        zeroDurationPacketsNormalized += 1
        if zeroDurationPacketsNormalized == 1 || zeroDurationPacketsNormalized % 200 == 0 {
            diagnostics.log(
                "[PathA] zero-duration \(packet.track.rawValue) packet normalized " +
                "pts=\(String(format: "%.3f", packet.pts)) → " +
                "\(String(format: "%.4f", normalized.duration))s " +
                "total=\(zeroDurationPacketsNormalized)"
            )
        }
        return normalized
    }

    private func enqueueVideoPacket(_ packet: MediaPacket) -> Bool {
        let packet = normalizingZeroDuration(packet)
        let isPassThrough = packet.pixelBuffer != nil || holdsPassThroughVideo
        let contentHWM = effectiveVideoContentHWM()

        if isPassThrough {
            while !canAcceptAnotherPassThroughVideoPacket(), !videoPackets.isEmpty {
                dropOldestVideoPacket()
            }
            while !canAcceptAnotherPassThroughVideoPacket(), !pendingVideoFrames.isEmpty {
                let dropped = pendingVideoFrames.removeFirst()
                pendingVideoContentSeconds = max(
                    0,
                    pendingVideoContentSeconds - dropped.duration
                )
            }
            guard canAcceptAnotherPassThroughVideoPacket() else { return false }
            while videoPacketQueue.contentSeconds + packet.duration > contentHWM + 1e-9,
                  !videoPackets.isEmpty {
                dropOldestVideoPacket()
            }
            if videoPacketQueue.contentSeconds + packet.duration > contentHWM + 1e-9 {
                return false
            }
        } else if videoPacketQueue.contentSeconds + packet.duration > contentHWM + 1e-9 {
            return false
        }

        let accepted = videoPacketQueue.enqueue(content: packet.duration)
        guard accepted + 1e-9 >= packet.duration else {
            _ = videoPacketQueue.drain(content: accepted)
            return false
        }
        videoPackets.append(packet)
        return true
    }

    private func effectiveVideoContentHWM() -> TimeInterval {
        var cap = videoPacketQueue.highWater
        if holdsPassThroughVideo {
            cap = min(cap, runtimePassThroughVideoContentHWM)
        }
        if let active = videoEnqueueCap {
            cap = min(cap, active)
        }
        return cap
    }

    private func dropOldestVideoPacket() {
        guard !videoPackets.isEmpty else { return }
        let dropped = videoPackets.removeFirst()
        let drained = videoPacketQueue.drain(content: dropped.duration)
        if drained + 1e-9 < dropped.duration {
            videoPacketQueue.reset()
            for p in videoPackets {
                _ = videoPacketQueue.enqueue(content: p.duration)
            }
        }
    }

    private func enqueueFullPacket(
        _ packet: MediaPacket,
        queue: inout ContentSecondQueue,
        store: inout PacketRingBuffer
    ) -> Bool {
        let packet = normalizingZeroDuration(packet)
        let room = queue.highWater - queue.contentSeconds
        guard room + 1e-9 >= packet.duration else { return false }
        let accepted = queue.enqueue(content: packet.duration)
        guard accepted + 1e-9 >= packet.duration else {
            _ = queue.drain(content: accepted)
            return false
        }
        store.append(packet)
        return true
    }

    private func noteVideoFrameSize(from pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }
        if knownVideoFrameWidth != w || knownVideoFrameHeight != h {
            knownVideoFrameWidth = w
            knownVideoFrameHeight = h
            if holdsPassThroughVideo {
                let maxV = maxPassThroughVideoPackets()
                let frameBytes = estimatedVideoFrameBytes()
                diagnostics.log(
                    "[PathA] cap video packets \(maxV) " +
                    "(≈\(frameBytes * maxV / (1024 * 1024))MB) for \(w)x\(h)"
                )
            } else {
                diagnostics.log("[PathA] decoded video size \(w)x\(h)")
            }
        }
    }

    func invalidateFrameStats() {
        resetPipeInstrumentWindow()
    }

    private func estimatedVideoFrameBytes() -> Int {
        let w = knownVideoFrameWidth > 0 ? knownVideoFrameWidth : defaultVideoFrameWidth
        let h = knownVideoFrameHeight > 0 ? knownVideoFrameHeight : defaultVideoFrameHeight
        return max(w * h * 4, 64 * 1024)
    }

    private func maxPassThroughVideoPackets() -> Int {
        let frameBytes = estimatedVideoFrameBytes()
        let byBudget = max(1, videoPixelFrameBudgetBytes / frameBytes)
        return max(
            minPassThroughVideoPackets,
            min(byBudget, maxPassThroughVideoPacketsAbsolute)
        )
    }

    private func heldPassThroughVideoFrameCount() -> Int {
        videoPackets.count + pendingVideoFrames.count
    }

    private func canAcceptAnotherPassThroughVideoPacket() -> Bool {
        heldPassThroughVideoFrameCount() < maxPassThroughVideoPackets()
    }

    private func enforcePassThroughVideoMemoryBudget(dropOldest: Bool) {
        guard holdsPassThroughVideo, dropOldest else { return }
        let maxFrames = maxPassThroughVideoPackets()
        while heldPassThroughVideoFrameCount() > maxFrames, !videoPackets.isEmpty {
            dropOldestVideoPacket()
        }
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
        if emitPaused {
            onEvent?(.paused)
        }
    }
}

private struct PacketRingBuffer: Sequence, ExpressibleByArrayLiteral {
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
