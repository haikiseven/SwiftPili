import CoreVideo
import Foundation
import UIKit

/// Native callback accounting belongs to the backend seek request, separately
/// from ordinary latest-only completion. Currency ignores the media generation
/// that this same seek legitimately advances.
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

/// Provenance for the bounded video bytes held by a warm-suspended lane. A
/// packet can share the same packet store as a retained candidate while still
/// having arrived after the suspension edge; those bytes are not authority for
/// the near-future image hold.
enum DemandVideoCandidateProvenance: Equatable, Sendable {
    case suspendEdge(readGeneration: UInt64)
    case postSuspend(readGeneration: UInt64)
    case positioned(readGeneration: UInt64)
    case forwardPositioned(MediaVideoForwardReceipt)
}

/// Serializes direct decode bursts across their suspension points, for
/// either media lane.
///
/// `MediaEngineSession` is MainActor-isolated, but an async decoder call still
/// re-enters the actor. A scalar owner count can stop a scheduled burst from
/// starting while another burst is active, yet it cannot make two direct
/// callers wait for one another: both callers can observe the same state
/// between `await decode(...)` calls and then remove adjacent packets. Keep a
/// FIFO handoff so a direct caller owns its lane for the whole burst.
/// Scheduled operations continue to use the session's operation identity and
/// may overlap a cancelled predecessor as required by decoder retirement.
///
/// Named for the mechanism, not the lane: `directVideoDecodeLane` and
/// `directAudioDecodeLane` are two independent instances of this same type,
/// one per FIFO. Nothing in the type is video- or audio-specific.
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
            // Keep the gate held while transferring ownership. The resumed
            // waiter is the next owner; no scheduling window can admit a
            // third caller between these two bursts.
            next.resume()
        } else {
            isHeld = false
        }
    }
}

/// Per-stage flow-gap tracker (freeze forensics). Monotonic; window fields
/// reset each 1s pipe window, `last` persists across windows and is cleared at
/// play/pause/seek/open boundaries so a resume never reads as a stall.
private struct FlowGapStage {
    var last: ContinuousClock.Instant?
    var windowCount = 0
    var windowMaxGapMs = 0

    /// Record one event; returns the closed gap in ms when it was ≥ `stallMs`.
    mutating func note(now: ContinuousClock.Instant, stallMs: Int) -> Int? {
        defer { last = now }
        windowCount += 1
        guard let last else { return nil }
        let gap = Int(last.duration(to: now) / .milliseconds(1))
        if gap > windowMaxGapMs { windowMaxGapMs = gap }
        return gap >= stallMs ? gap : nil
    }

    /// `cnt/maxGapMs`, or `0(idle Nms)` when silent this window.
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

/// Path A session coordinator.
///
/// Owns demux / decode / render collaborators injected at init (testable,
/// swappable). Does **not** import ViewModel, SmartCDN, or SwiftVLC.
///
/// A1a: demux `pump` → packet buffers + ContentSecondQueue depth.
/// A2a: video packet → decode → present; **mediaTime does not advance** from
/// video present alone (F1).
/// A3a: audio packet → decode → PCM ring; **audio pull** advances `mediaTime`
/// by content seconds consumed (`frames / sampleRate`). Rate multiplies pull
/// demand at the renderer (`wall * rate` → content).
/// A3.5: pull underrun → `.buffering`; full pull recovers → `.playing`;
/// clock at end / dry EOF → `.ended`.
/// A2.5 / **A2-α:** with audio master, decode into a pending video frame queue and
/// enqueue frames with `pts <= mediaTime + lead` after audio pull (F1). Display
/// slave is `AVSampleBufferRenderSynchronizer` (real PTS; no DisplayImmediately).
/// There is no video-only playback shape: `decoderReadinessFault` refuses `.ready`
/// without an audio master clock, so **every** ready session paces video against
/// F1 and no path pushes frames at the renderer unpaced. App assembly supplies
/// both the unavailable stub stack and the product stack explicitly.
@MainActor
final class MediaEngineSession: MediaEnginePresentation, AudioPullSource, EnginePiPTransportDelegate,
    WarmPreparationTransactionHost {
    enum EnginePCM {
        static let sampleRate: Double = 48_000
        static let channelCount: Int = 2
        static let aacOutputQuantumSeconds: TimeInterval = 1024.0 / sampleRate
    }

    /// Scheduling runway ahead of the display clock for `AVSampleBufferRenderSynchronizer`
    /// (`<= videoFrameQueueHighWater` and `> displayResyncEpsilonSeconds`).
    private let videoPresentLeadSeconds: TimeInterval = 0.3
    // Keep only a SMALL buffer of DECODED frames — they are expensive in memory
    // (a 4K NV12 frame is ~12 MB, BGRA ~33 MB). Runway comes from the cheap
    // compressed packet buffer (8 s HWM); decode is just-in-time. At 1.0 s the
    // decoded 4K frames pinned ~2 GB and memory pressure decayed the present rate.
    private let videoFrameQueueHighWater: TimeInterval = 0.4
    private let displayResyncEpsilonSeconds: TimeInterval = 0.25
    /// Re-pin the synchronizer only once the display clock drifts this far from the
    /// master. Below this, leave the timebase free-running (no reset hitch). ~2
    /// frames @30fps of tolerance.
    private let displayDriftResyncSeconds: TimeInterval = 0.08
    private var lastDisplayResyncPresentationTime: TimeInterval = -1
    /// Offset used by the most recent display pin. AU latency may become known
    /// only after graph start; a changed offset must re-pin even when it is below
    /// the ordinary drift threshold, otherwise a fixed A/V offset survives.
    private var lastDisplayPresentationOffset: TimeInterval?
    private var lastDisplayPinGeneration: Int?
    /// A frozen visual coordinate, never an audio/seek/preparation time source.
    private var audioOutputDisplayHold: (generation: Int, time: TimeInterval)?

    var onEvent: (@MainActor @Sendable (MediaSessionEvent) -> Void)?
    private var audioOutputStateChangeHandler: (@MainActor () -> Void)?
    var onPresentationFailure:
        (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    /// Neutral direct-PiP transport edges. The Demand backend stamps its own
    /// generation before forwarding these to the App; this session never
    /// imports or knows about Now Playing/owner policy.
    var onPiPTransportEvent:
        (@MainActor @Sendable (EnginePiPTransportEvent) -> Void)?
    var onPiPSkipRequest: (@MainActor @Sendable (EnginePiPSeekRequest) -> Void)?

    private let diagnostics: any MediaEngineDiagnostics
    private let tracing: any MediaEngineTracing
    private let demux: any MediaDemuxing
    private let warmVideoPreparationDeadline: Duration
    private var videoDecoder: any MediaVideoDecoding
    /// Creates a distinct decoder object for a local warm-repair attempt. The
    /// production VT path supplies this; direct test sessions that omit it fail
    /// typed instead of reopening the same malfunctioned object.
    private let videoDecoderFactory: (@MainActor @Sendable () -> any MediaVideoDecoding)?
    private var videoDecoderWasRetired = false
    /// Tracks ownership of a successfully opened native decoder independently
    /// from `videoDecoderOpened`. A runtime fault clears the latter so no more
    /// packets are submitted, but the failed native session still needs one
    /// off-main retirement during stop/replacement.
    private var videoDecoderHasNativeSession = false
    private var videoDecoderFactoryInvocationCount = 0
    /// A closed decoder can leave the audio master and compressed packet window
    /// healthy while the ordinary video scheduler returns at its
    /// `videoDecoderOpened` guard. Coalesce one local replacement so repeated
    /// audio-clock kicks cannot create multiple decoders or a source reopen.
    private var videoDecoderRepairTask: Task<Bool, Never>?
    private var nextVideoDecoderRepairID: UInt64 = 0
    private var activeVideoDecoderRepairID: UInt64?
    private var videoDecoderRepairAttempted = false
    /// A PiP lease may arrive while a local video-lane suspension is already
    /// active. Keep one local resume in flight so that PiP can continue
    /// decoding without waiting for a later activation edge.
    private var pipVideoResumeTask: Task<Bool, Never>?
    private var nextPiPVideoResumeID: UInt64 = 0
    private var activePiPVideoResumeID: UInt64?
    /// Native VideoToolbox invalidation is allowed to outlive this actor, but
    /// it is still owned by this session. Keep one bounded identity record for
    /// every outstanding close so repeated local repair cannot accumulate
    /// untracked decoder objects/tasks.
    private static let maxOutstandingVideoDecoderRetirements = 2
    private var outstandingVideoDecoderRetirements: [ObjectIdentifier: UInt64] = [:]
    private var nextVideoDecoderRetirementID: UInt64 = 0
    private(set) var videoDecoderRetirementAdmissionFailureCount = 0
    private(set) var videoDecoderRetirementCompletionCount = 0
    /// An async `open` retains its decoder object independently of the session's
    /// current slot. Keep that exact object registered until the collaborator
    /// returns so a stop/replacement retirement remains visible even when its
    /// close completes before the stale open callback arrives. Without this
    /// ledger, a late callback can enqueue a second close after the retirement
    /// ticket has already been removed from `outstanding...`.
    private struct VideoDecoderOpeningState {
        let decoder: any MediaVideoDecoding
        var retirementNeeded = false
        var retirementRequested = false
        /// `open` has returned (successfully or with an error). A retirement
        /// requested while the open is suspended cannot start its detached
        /// close until this boundary is crossed.
        var openCompleted = false
    }
    private var openingVideoDecoders: [ObjectIdentifier: VideoDecoderOpeningState] = [:]
    private let audioDecoder: any MediaAudioDecoding
    private let videoRender: any MediaVideoPresentation
    private let audioRender: any MediaAudioRendering

    private var clock = MediaClock()
    /// Display-only representation of the same accepted F1 drain. Real PCM
    /// resets, source/seek changes and rejected reports retire its chain.
    private var audioDisplayObservation = AudioDisplayObservationChain()
    /// Register each decoder call before its first await. It can then transfer
    /// display custody only for real PCM. Reset/cancellation settles the handle.
    private struct PendingAudioDisplaySupport {
        let support: AudioPendingDisplaySupport
        let operationID: UInt64?
    }
    private var pendingAudioDisplaySupport: [ObjectIdentifier: PendingAudioDisplaySupport] = [:]
    private var videoPacketQueue = ContentSecondQueue(highWater: 20, lowWater: 4)
    private var audioPacketQueue = ContentSecondQueue(highWater: 20, lowWater: 4)
    private var videoPackets: [MediaPacket] = []
    private var audioPackets: [MediaPacket] = []
    /// Overflow from demux when a whole fMP4 moof (~5s) exceeds packet-queue HWM.
    /// Residual is drained into the main queues before the next pump; never drop.
    private var residualVideoPackets: [MediaPacket] = []
    private var residualAudioPackets: [MediaPacket] = []
    /// Audio-only lifecycle continuation keeps a moving, keyframe-rooted
    /// compressed window while ordinary VT submission and ASBD presentation
    /// are suspended. The window is shared by split fMP4 and muxed HLS because
    /// this session is the single packet-ingest owner for both topologies.
    ///
    /// W6: the window is a clock-relative TRAILING buffer, not a single GOP.
    /// New keyframes no longer reset it; the front is trimmed once a later
    /// keyframe falls at or behind the audio clock, so the head stays the last
    /// keyframe ≤ clock — exactly the bracketing decode anchor a foreground
    /// return needs.
    private var suspendedVideoGOP: [MediaPacket] = []
    private var suspendedVideoGOPContentSeconds: TimeInterval = 0
    private var suspendedVideoGOPBytes = 0
    private var suspendedVideoGOPProvenance: DemandVideoCandidateProvenance?
    /// W6/D6: set when memory pressure sheds the suspended video window.
    /// Video supply stays at zero for the rest of this suspension cycle — a
    /// shed window must not be refetched in the background, or the warning
    /// answers with fresh allocations. Cleared by the next suspend edge and
    /// by continuation-state reset.
    private var suspendedVideoSupplyMemorySuppressed = false
    /// Incremented for every scoped demux read that can include video. The
    /// suspend token snapshots this value; a result ingested after the edge is
    /// marked post-suspend even when the read began before the edge.
    private var nextVideoReadGeneration: UInt64 = 0
    /// Saturating byte total for the current session. Keeping this monotonic
    /// lets a hold report a real scoped delta even when a pathological source
    /// would otherwise wrap an `Int` counter.
    private var videoReadBytes = 0
    /// Legacy caps retained for the positioned RUN-UP accumulation and the
    /// moving-target chase budgets — those are operation-scoped bounds, not the
    /// retained window's memory policy.
    private static let suspendedVideoGOPMaxContentSeconds: TimeInterval = 8
    private static let suspendedVideoGOPMaxBytes = 16 * 1024 * 1024
    /// W6: bounds for the clock-relative suspended video window. The operative
    /// bound is the supply target (window tail = audio clock + high-water);
    /// these are the safety envelope around it: one GOP behind the clock (the
    /// bracketing anchor) plus the 8 s foreground high-water ahead plus one
    /// pump-call overshoot — ≈14 s / ≈44 MB at 25 Mbps with a 5 s GOP, so
    /// 16 s / 48 MiB leave headroom and the byte cap only engages on
    /// pathological bitrates.
    private static let suspendedVideoWindowMaxContentSeconds: TimeInterval = 16
    private static let suspendedVideoWindowMaxBytes = 48 * 1024 * 1024
    /// One bounded source-frame allowance for floating-point grid snapping and
    /// reordered PTS around a decode-order sync anchor. A materially future
    /// GOP still fails the pre-roll gate.
    private static let videoContinuityAnchorToleranceSeconds: TimeInterval = 0.05
    /// A positioned attempt decodes from its selected random-access point
    /// through the live audio target. During that bounded collection, later
    /// sync samples remain part of the run-up instead of resetting the window
    /// to a target-side keyframe returned by the same one-second pump.
    private var isCollectingWarmVideoRunUp = false
    private var nextVideoContinuityCandidateGeneration: UInt64 = 0
    private var warmVideoCandidateAuthorities: [MediaVideoContinuityCandidateAuthority] = []
    /// Closed attempt-1 decision. A future retained GOP is deliberately not
    /// called pre-roll: its first output is withheld by the audio-driven due
    /// scheduler until `notBeforePTS` becomes current.
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

    /// Typed authority for the bounded interval between preparation and the
    /// audio clock making a retained future random-access sequence due.
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
        /// Measured video-read delta since this lane's suspend edge. A
        /// near-future hold is expected to carry zero, but the value is never a
        /// literal proof constant.
        let foregroundFetchBytes: Int
        var rateRevision: UInt64
        /// Installed only by the exact successful resume transaction. Keeping
        /// the hold alive through proof lets packet supply remain audio-only
        /// until two current-generation frames are actually display-ready.
        var renderGeneration: Int?
        var hasReachedAudioDueTime: Bool
    }

    private static let suspendedVideoTargetAheadSeconds: TimeInterval = 1.0
    private var activeWarmVideoImageHold: WarmVideoImageHoldSnapshot?
    /// The post-resume hold refresh is a local continuation transaction, not a
    /// fire-and-forget callback. Keep its task handle so authority changes can
    /// cancel it and tests can await its completion without guessing how many
    /// scheduler yields are enough.
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
    /// Active burst count on the video decode lane. Held for one burst only so
    /// concurrent direct/scheduled consumers never interleave packet submissions
    /// into VideoToolbox while parked collaborators cannot permanently wedge the lane.
    private var videoDecodeLaneOwners = 0
    /// Direct bursts have no operation handle, so they need a separate FIFO
    /// gate. Scheduled bursts remain allowed to overlap a cancelled
    /// predecessor; decoder retirement depends on that behavior.
    private let directVideoDecodeLane = DecodeLaneGate()
    /// Active burst count on the audio decode lane, preventing concurrent
    /// `audioPackets` consumers from interleaving against `AudioToolboxAudioDecoder`
    /// and its shared `PCMLinearResampler`. Held for one burst only.
    private var audioDecodeLaneOwners = 0
    /// Direct bursts have no operation handle, so they need a separate FIFO
    /// gate. Scheduled bursts remain allowed to overlap a cancelled
    /// predecessor; decoder retirement depends on that behavior.
    private let directAudioDecodeLane = DecodeLaneGate()
    /// One operation-lifetime owner; media resources and progress remain here.
    private let warmPreparationTransaction: WarmPreparationTransaction
    private var isDecodingWarmVideoCandidate = false
    private var suspendedVideoFault: MediaRuntimeFault?
    private var terminalVideoPreparationFailure: DemandPresentationFailure?
    private var warmVideoPreparationLedger = WarmVideoPreparationLedger()
    private var warmVideoSubmissionsWithoutOutput = 0
    private var videoContinuityTopology: MediaVideoContinuityTopology = .unsupported
    /// The local continuity ladder permits exactly one decoder recreation after
    /// the first warm-prepare decoder fails. It never crosses the source/session
    /// boundary or changes codec authority.
    private static let warmVideoDecoderRepairLimit = 1
    /// Larger than ordinary reorder depth but bounded below a full 300-sample
    /// GOP. A decoder that consumes this many current packets without one frame
    /// has conclusively failed warm preparation.
    private static let warmVideoNoOutputSubmissionLimit = 64
    /// The renewed earlier-authority rung streams transient compressed input
    /// instead of placing the full root-to-target span in the retained GOP.
    /// These are operation-scoped bounds, not retained-memory limits or a
    /// fixed pump-count substitute.
    private static let warmVideoDirectContentSpanLimit: TimeInterval = 12
    private static let warmVideoDirectWallLimit: Duration = .seconds(5)
    private static let warmVideoDirectNoProgressLimit = 3
    /// Product bound for one warm preparation. Tests inject a short value;
    /// the shipped behavior remains the existing five-second limit.
    private static let defaultWarmVideoPreparationDeadline: Duration = .seconds(5)

    private typealias WarmVideoPreparationRun = WarmVideoPreparationRunLedger.Run

    private typealias WarmVideoPreparationAttempt = WarmVideoPreparationLedger.Attempt

    /// Await durations include collaborator execution and actor resumption. They
    /// are not hardware time, and may overlap work on other pipeline lanes.
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
        /// One selected decoder segment, never the sum of native work across rungs.
        let decoderTiming: WarmVideoDecoderTimingObservation?
    }

    struct WarmVideoDecoderTimingObservation: Equatable {
        let segmentID: Int
        /// nil means selection at run admission, before the first attempt.
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
        // Admission belongs to the shared run, even if its initiating waiter
        // is cancelled here. Fresh transfers separately require a current
        // attempt; terminal cancellation synchronously retires the run state.
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

    /// Freeze only the admitted owner. A retired decoder's late callbacks are
    /// excluded by disabling its observation, without waiting on native state.
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
    /// Nominal content charge for a packet the demuxer handed over with
    /// `duration == 0` (broken `trun`/`tfhd`/`trex` triplet — see
    /// `PathAFMP4.nominalDurationTicks`). 30 fps / one AAC AU @48 kHz.
    private let nominalZeroDurationVideoSeconds: TimeInterval = 1.0 / 30.0
    private let nominalZeroDurationAudioSeconds: TimeInterval = 1024.0 / 48_000.0
    /// Diagnostics: packets that arrived with no duration and were charged the
    /// nominal above. Non-zero means the demux layer is producing broken timing.
    private(set) var zeroDurationPacketsNormalized = 0
    private var pendingVideoFrames: [MediaVideoFrame] = []
    private var pendingVideoContentSeconds: TimeInterval = 0
    /// Decoded PCM, behind a lock so the audio ring feeder can pull it from its
    /// own queue while MainActor keeps appending. The timeline arithmetic still
    /// runs on MainActor inside `AudioTimelineBuffer`; only the read moved.
    /// Exposed to the renderer through `AudioPullSource.audioSupply`.
    private let audioTimelineBuffer = AudioTimelinePCMSupply(
        defaultSampleRate: EnginePCM.sampleRate,
        defaultChannels: EnginePCM.channelCount,
        timelineEpsilon: EnginePCM.aacOutputQuantumSeconds
    )

    nonisolated var audioSupply: any AudioSupplySource { audioTimelineBuffer }
    private var hasAudioTrack = false
    // Path A redesign step 1: self-paced packet supply. Replaces the old one-shot
    // `pumpTask` that only re-armed off the bursty audio clock. See `startSupplyLoop`.
    private var supplyLoopTask: Task<Void, Never>?
    private var supplyLoopStartCount = 0
    private var supplyLoopWake: CheckedContinuation<Void, Never>?
    private var supplyLoopWakePending = false
    /// True while a `fillQueuesToHighWater` is in flight — keeps the self-paced
    /// supply loop the SINGLE `demux.pump` caller (no interleaved concurrent pumps).
    private var isFillingQueues = false
    /// Capture-only correlation; never used as a playback fence.
    private var nextQueueFillTraceID: UInt64 = 0
    /// True when the most recent fill ingested at least one packet. An
    /// UNPRODUCTIVE fill (one-track EOF/truncation with the other track full,
    /// live-HLS edge with no new segment, transient pump error) must PARK
    /// rather than retry at the stall backoff: a mid-play one-track
    /// truncation otherwise spins the loop at ~50Hz for the rest of playback.
    /// Wakes still arrive from every decode drain (wakeSupplyLoopIfDrained
    /// treats residual and below-low-water as wakes), so live-HLS polling
    /// keeps a drain-driven cadence.
    private var lastFillProducedPackets = false
    private var decodeTask: Task<Void, Never>?
    private var audioDecodeTask: Task<Void, Never>?
    /// Decode-task cancellation is cooperative: a decoder may return from an
    /// already-entered `decode` after its task has been cancelled. Keep a
    /// separate operation identity for each lane so that a late completion
    /// cannot publish into, or clear the handle belonging to, a successor
    /// operation in the same media generation.
    private var nextVideoDecodeOperationID: UInt64 = 0
    private var activeVideoDecodeOperationID: UInt64?
    private var nextAudioDecodeOperationID: UInt64 = 0
    private var activeAudioDecodeOperationID: UInt64?
    /// All demux/decoder resource transitions run through one serial chain.
    /// `MediaEngineSession` is MainActor-isolated, but its async methods yield
    /// while URL/decoder work is in flight; actor isolation alone therefore
    /// does not order an old close against a replacement open.
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
            retirePendingAudioDisplaySupport()
            audioDisplayObservation.invalidate()
        }
    }
    /// Count of demux opens in this session lifetime; audit-only provenance
    /// that distinguishes a local warm attempt from a source reopen.
    private var demuxOpenCount = 0
    /// One `seek-first-packet` log per seek: the wall moment the FIRST packets
    /// of the seek's refill actually arrived (with streaming mdat they land
    /// mid-fill, invisible to the phase lines). Reset by `prepareSeek`.
    private var seekFirstPacketLogged = true
    /// PiP callback ownership is independent from the open/seek generation.
    /// Seeks and pauses may fence media work without replacing the renderer's
    /// current controller, so their generation changes must not invalidate a
    /// live PiP lease callback.
    private struct PiPEventBindingToken: Equatable, Sendable {
        let generation: UInt64
    }

    private var nextPiPEventBindingGeneration: UInt64 = 0
    private var activePiPEventBindingToken: PiPEventBindingToken?
    /// Presentation capability, independent of media/open/seek generation.
    /// The backend applies the authoritative continuation snapshot; direct
    /// sessions remain fail-closed until explicitly enabled.
    private(set) var isAutomaticPiPEnabled = false
    private var activeOwnerGeneration: UInt64 = 0
    private var activeStartupTraceToken: MediaEngineTraceID?
    /// A runtime fault fences the current generation without incrementing it;
    /// the fault callback still carries the generation that produced it.
    private var runtimeFaultedGeneration: Int?
    private var publishedRuntimeFaultGeneration: Int?
    private var observedPiPLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var pipNativeTransitionHandler: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    private var pipRestoreRequestHandler: (@MainActor @Sendable (UInt64) -> Void)?
    private var nextPiPTransportOperationID: UInt64 = 0
    /// Snapshot captured before an inactive/background edge. It is consumed
    /// once by activation so a repeated didBecomeActive cannot stack PiP
    /// flushes or decoder replacement.
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
    /// Last decoder-open failure text, surfaced in the fail-closed `.failed` event
    /// instead of being left in the log only.
    private var lastVideoDecoderOpenError: String?
    private var lastAudioDecoderOpenError: String?
    private var lastAudioDecodeError: String?
    private var lastAudioDecodeDiagnostics = MediaAudioDecodeDiagnostics.unavailable
    private var audioDecodePacketsSubmitted = 0
    private var audioDecodePCMFramesProduced = 0
    private let videoDecodeBurstLimit = 8
    private let audioDecodeBurstLimit = 64
    /// Converter lookahead can consume several bounded decode bursts before
    /// returning PCM. This is a startup/seek no-progress budget, not a reserve
    /// value and not a packet-queue high-water change.
    private static let audioPrimeNoPCMProgressBurstLimit = 4
    private let audioPCMTargetSeconds: TimeInterval = 4
    /// Short video prime for pass-through BGRA jetsam control (A1c bring-up).
    /// Compressed production demux (phase-2) will use content-second HWM policy
    /// from PLAYER_DEMAND_PACED_ARCHITECTURE — do not retune this for fMP4 thrash.
    private let primeVideoContentBudget: TimeInterval = 0.5
    private let runtimePassThroughVideoContentHWM: TimeInterval = 1.0
    private let minTrackFillRoom: TimeInterval = 0.05
    /// Supply-loop low-water fraction of `packetQueueHighWater` (park at high-water,
    /// wake and refill once a track crosses low-water).
    private let supplyLowWaterFraction: TimeInterval = 0.5
    /// Retry cadence when the demuxer is network-starved (pump returned early/empty
    /// and not EOF). Bounded backoff — NOT a busy-spin — so the loop keeps trying to
    /// supply without the audio clock; downstream drains surface as `.buffering`.
    private let supplyStallBackoffNanos: UInt64 = 20_000_000
    /// Per-pump-call budget ceiling so individual `demux.pump` calls stay bounded
    /// while the fill loop iterates toward target across warm chunk streams.
    private let pumpCallBudgetCapSeconds: TimeInterval = 1.0

    // MARK: - F4: incremental ingest

    /// Packets reach the session through here as the demuxer completes them,
    /// instead of waiting for the budget-sized `pump` call to return.
    private let packetRelay = DemuxPacketRelay()
    /// Uptime of the last relay drain that carried packets, and the worst
    /// sample-ready → session-ingest latency observed since the window opened.
    /// This is the number that proves F4: it must stay small even when one pump
    /// spans seconds.
    private var relayDrainCount = 0
    /// When video was first observed starved, or nil. Debounced because a
    /// momentarily empty queue between two fragments is normal and must not
    /// flap the buffering state.
    private var videoStarvedSince: ContinuousClock.Instant?
    /// True while buffering was entered by VIDEO starvation rather than audio
    /// underrun — only this owner may clear it, so an audio path cannot resume
    /// playback into a still-empty video queue. Read through
    /// `videoStarvationHoldIsActive()`, never directly.
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
    private var hasEmittedEnded = false
    private var demuxReachedEOF = false
    /// True between "supply exhausted" (demux EOF, no packets, no in-flight
    /// decode, no session PCM) and the renderer finishing the audio it still
    /// has buffered. Not buffering, not ended: video keeps presenting and the
    /// clock keeps advancing from drained audio (audit finding #1 — EOF used
    /// to fire the instant the feeder underran, truncating the ring's still
    /// unplayed content).
    private var audioDrainingToEnd = false
    /// Set once the renderer reports no pending output while draining.
    private var audioDrainEmptiedAt: ContinuousClock.Instant?
    /// `.ended` fires once this deadline (ring-emptied instant + output
    /// latency) has passed.
    private var audioDrainPlayoutDeadline: ContinuousClock.Instant?
    /// True for the whole async seek window so audio pull cannot advance F1
    /// or trip underrun/display free-run while queues are being rebuilt.
    private var isSeekInFlight = false {
        didSet {
            if isSeekInFlight {
                invalidateSourceWaitBudget()
                audioDisplayObservation.invalidate()
            }
        }
    }
    /// Capture admission only: preparation awaits before seek transport owns
    /// the lane. An older return cannot clear a successor's receipt.
    private var pausedCaptureSeekPreparationReceipt: UUID?
    /// Renderer transaction identity for the current private seek preparation.
    /// The backend receives only the opaque preparation and owns latest-wins
    /// authority; session generation remains the lifecycle fence.
    private var activeSeekToken: MediaAudioSeekToken?
    private var preparedSeek: MediaEngineSeekPreparation?
    /// Lower presentation boundary for the current open/seek generation.
    ///
    /// fMP4 seek lands at a fragment/keyframe before the requested target. Video
    /// packets before this floor must still be decoded to rebuild reference state,
    /// but their decoded frames must never reach the display. Audio is filtered at
    /// decoded-PCM time because no codec dependency requires pre-target output.
    private var outputMediaFloor: TimeInterval = 0 {
        didSet {
            (videoRender as? SampleBufferVideoRenderer)?.updateDemandPresentationFloor(outputMediaFloor)
        }
    }
    private let outputMediaFloorEpsilon: TimeInterval = 1e-9
    /// Highest media position each decoder has produced OUTPUT for since the
    /// current open/seek generation began — counting output that was then
    /// discarded below `outputMediaFloor`, because consuming pre-target output
    /// IS the progress a seek's run-up makes.
    ///
    /// This is the measurement the seek readiness gate was missing. Packet-queue
    /// depth cannot tell "3.0s into a 4.0s audio run-up" from "target-side and
    /// ready"; a decode frontier can, and it also gives the run-up its own
    /// honest stall signal (frontier frozen ⇒ nothing is moving, whatever the
    /// queues hold). Audio is measured at the END of each PCM chunk because
    /// audio is trimmed at sample granularity, not frame granularity — the 70s
    /// device fixture (audio anchor 5s before the target) is exactly the case
    /// where the difference decides the verdict.
    ///
    /// `nil` = that decoder has produced nothing yet, never "position 0" — the
    /// same rule as every other unmeasured quantity in this pipeline.
    private var videoDecodeFrontierPTS: TimeInterval?
    private var audioDecodeFrontierPTS: TimeInterval?

    /// Bounded evidence for frames rejected after the moving audio floor
    /// advanced. This is intentionally aggregate state: a warm preparation may
    /// discard an old burst, but diagnostics must never become per-frame log
    /// traffic or a second recovery authority.
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
                // Pausing does not change the last accepted F1 position.
                // Real PCM resets and later discontinuous reports retire it.
            }
        }
    }
    private var activeSourceWaitBudget: MediaSourceWaitBudget?
    /// Measurement acceptance may follow normal pump return through relay or
    /// residual queues. Lifecycle retirement, unlike return, ends this epoch.
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
    /// App-selected once at construction; `false` = the legacy
    /// synchronous decode-every-sample run-up for seeks AND resume opens.
    let seekFastPrerollEnabled: Bool
    private let videoPrerollClassifierFactory: VideoPrerollClassifierFactory
    /// Built at decoder open from the same codec/config, and bound to that
    /// decoder object: under any other decoder identity it reads as absent
    /// (never skip), so retirement/replacement needs no extra bookkeeping.
    private var videoPrerollClassifier: (any VideoPrerollSampleClassifying)?
    private var videoPrerollClassifierDecoder: ObjectIdentifier?
    private var videoPrerollCodec: String?
    /// True only inside `drainPrerollBatches` (cleared by `defer` in the same
    /// frame, never across a park): the relay scheduler leaves a PRE-TARGET
    /// head packet to the batch path while set (design §4.2b, OI-12).
    private var prerollBatchingActive = false
    /// C2: at most this many submissions in flight per batch. Not device-tuned
    /// (OI-4); `[PathASeekPreroll]` decides whether it moves.
    static let seekPrerollBatchLimit = 32
    /// Run-up accounting for the priming in progress, fenced by generation.
    private var activePrerollStats: SeekPrerollStats?
    private var activePrerollStatsGeneration: Int?
    private var prerollAnomalyBaseline: (decoder: ObjectIdentifier, counters: VideoDecodeAnomalyCounters)?
    /// Last finished priming's accounting (tests, Playback Report).
    private(set) var lastPrerollStats: SeekPrerollStats?
    private var seekPhaseStopwatch: SeekPhaseStopwatch?
    var pendingVideoFrameCount: Int { pendingVideoFrames.count }
    private(set) var decodedAudioFrameCount = 0
    private(set) var droppedPrerollAudioFrameCount = 0
    private(set) var trimmedPrerollAudioSampleFrameCount = 0
    private(set) var pulledAudioFrameCount = 0
    private var audioTimelineAdjustmentLogCount = 0
    private var audioDecodeTimingLogCount = 0
    /// Pure detector state. The session owns only the complete-window
    /// collector and generation fence; it does not grant recovery authority.
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
    /// Wire bytes for the CURRENT stream. Replaced (never zeroed) on open and
    /// stop, so a retired source's late callback lands in its own instance.
    private var networkByteCounter = MediaNetworkByteCounter()
    private(set) var totalVideoPacketsIngested = 0
    private(set) var totalAudioPacketsIngested = 0
    private(set) var totalVideoPacketsDequeued = 0
    private(set) var totalVideoPacketsSubmitted = 0
    private(set) var totalVideoInputContentSecondsConsumed: TimeInterval = 0
    private(set) var totalVideoOutputPTSAdvanced = false

    // Path A frame-rate + pipe counters. The one-second frame window feeds public
    // diagnostics even when text capture is disabled; the remaining counters are
    // log-only. None drives supply / decode / mediaTime (F1).
    private var pipeWindowStartUptime: TimeInterval = 0
    private var pipeWindowStartMediaTime: TimeInterval = 0
    private var pipeWindowDecodeFrames = 0
    private var pipeWindowPresentFrames = 0
    private var pipeWindowPresentCalls = 0
    private var pipeWindowPumps = 0
    private var pipeWindowParks = 0
    private var pipeWindowWakes = 0
    /// Present-feed diagnostics: why a drain call enqueued nothing.
    private var pipeWindowNotDue = 0
    private var pipeWindowNotReady = 0

    // 1Hz `[pipe]` fields are omitted while unchanged (with an explicit omitted
    // count) and forced in full every tenth window and on any freeze window.
    private var pipeStickyFields: [String: String] = [:]
    private var pipeWindowIndex = 0
    private var wasCapturingLastWindow = false
    private var lastAudioCallbackCount = 0
    private var lastAudioRenderedFrameCount = 0

    /// One `key=value ` term of the 1Hz line, emitted only when the value
    /// changed since the previous window (or when the caller forces a full
    /// anchor line). Counts what it withholds so the line can say so.
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

    // Flow-gap forensics (1x freeze P1): one tracker per pipeline stage,
    // noted only while capturing. The 1Hz `[PathA][gap]` window line carries
    // per-stage counts + max inter-event gaps; stall-end edges and the FREEZE
    // snapshot are event-driven.
    private var flowIngestV = FlowGapStage()
    private var flowIngestA = FlowGapStage()
    private var flowDecInV = FlowGapStage()
    private var flowDecOutV = FlowGapStage()
    private var flowPresentV = FlowGapStage()
    private var flowClock = FlowGapStage()
    private var flowPCM = FlowGapStage()
    /// Max (pump-emit → session-ingest) packet age this window — the demux
    /// batching bridge delay. Large values mean samples existed but were held
    /// captive inside an unreturned `demux.pump` call.
    ///
    /// **This is the F4 proof metric.** Read it against the `[gap] pump
    /// wall=…ms` line for the same window: before the relay, a pump spanning
    /// 7969ms meant every sample it completed aged by up to that long before the
    /// session saw it. After it, `age=` must stay small — tens of milliseconds —
    /// no matter how long the pump runs, because delivery no longer waits on the
    /// pump's return. `relayDrains=` beside it is what did the delivering; a
    /// small age with zero drains is the batch path getting lucky, not the fix
    /// working.
    private var flowWindowMaxPacketAgeMs = 0
    /// Max wall time of one synchronous `videoDecoder.decode` this window.
    private var flowWindowMaxDecodeMs = 0
    private var flowLastIngestVideoPTS: TimeInterval = -1
    private var flowLastIngestAudioPTS: TimeInterval = -1
    private var lastPresentBurstLogAt: TimeInterval = 0
    private let flowStallThresholdMs = 700

    /// True once the audio master clock exists. `isReady` implies this (see
    /// `decoderReadinessFault`), so it is **not** a playback-shape switch — the
    /// only two readers left are the ones reachable BEFORE readiness, where the
    /// track is declared but its decoder has not opened yet: the buffered-horizon
    /// projection and the prime-time decode watermark.
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

    /// Observation of the existing native drain/F1 path, never clock or Play authority.
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

    /// Raw `playableTime` estimate: playhead plus the binding track's runway.
    /// Prefer `bufferDisplaySample` when presenting seekable coverage.
    var bufferedTime: TimeInterval {
        clock.mediaTime + (deliveryRunway ?? 0)
    }

    /// Current-source display evidence is independent of raw cached-runway
    /// resets before a pump. A present track with no connected evidence binds
    /// at the playhead; it cannot disappear or regain a farther raw estimate.
    var bufferDisplaySample: MediaBufferDisplaySample? {
        let time = clock.mediaTime
        guard time.isFinite else { return nil }
        if let query = demux.displayEvidenceQuery {
            let evidence = query.qualifiedEndpoints(at: time, audioPosition: audioDisplayObservation.position)
            let video = videoDecoderOpened ? (
                isVideoLaneWarmSuspended
                    ? time + (videoDeliveryRunway ?? 0)
                    : evidence.video ?? time
            ) : nil
            let audio = hasAudioTrack ? evidence.audio ?? time : nil
            return MediaBufferDisplaySample(
                position: time, videoPresent: videoDecoderOpened, audioPresent: hasAudioTrack,
                videoWarmSuspended: isVideoLaneWarmSuspended, evidence: evidence,
                resolved: MediaDisplayEndpoints(video: video, audio: audio),
                bufferedThrough: bindingDeliveryRunway(video: video, audio: audio)
            )
        }
        // Live, local/offline and unsupported demuxers retain their established
        // producer. Warm video above retains only its existing bounded window.
        let established = establishedDisplayEndpoints(at: time)
        return MediaBufferDisplaySample(
            position: time, videoPresent: videoDecoderOpened, audioPresent: hasAudioTrack,
            videoWarmSuspended: isVideoLaneWarmSuspended, evidence: nil, resolved: established,
            bufferedThrough: bindingDeliveryRunway(video: established.video, audio: established.audio)
        )
    }

    /// Raw runway plus one resident parsed fragment when no display-evidence
    /// query is supported by the demuxer.
    private func establishedDisplayEndpoints(at time: TimeInterval) -> MediaDisplayEndpoints {
        let video = videoDeliveryRunway
        let audio = audioDeliveryRunway
        let videoEnd = video.map { time + $0 }
        let audioEnd = audio.map { time + $0 }
        let supplementedVideo = videoEnd.map { endpoint in
            isVideoLaneWarmSuspended ? endpoint
                : residentVideoDisplay?.supplement(endpoint, at: time) ?? endpoint
        }
        let supplementedAudio = audioEnd.map { endpoint in
            residentAudioDisplay?.supplement(endpoint, at: time) ?? endpoint
        }
        return MediaDisplayEndpoints(video: supplementedVideo, audio: supplementedAudio)
    }

    // MARK: - Delivery runway (F3)

    /// Content seconds of VIDEO banked ahead of the playhead: queued packets
    /// plus frames already decoded and waiting on the presentation boundary.
    /// `nil` = this session carries no video (never zero — zero is the positive
    /// claim that video has run dry, which is exactly the state this measures).
    ///
    /// `videoDecoderOpened` is the video-presence predicate for the same reason
    /// `videoLivenessContext` uses it: before the decoder opens there is no
    /// video pipeline to have a runway, and reporting 0 there would read as
    /// starvation during every startup.
    ///
    /// Plus `cachedVideoRunwaySeconds`: content the byte store already holds
    /// is reachable without the network, so a stretch played from memory is
    /// not a short runway. Not while the lane is warm-suspended — that window
    /// is its own retained store and the reader may be repositioned under it.
    var videoDeliveryRunway: TimeInterval? {
        guard let queued = queuedVideoRunway else { return nil }
        if isVideoLaneWarmSuspended { return queued }
        return queued + cachedVideoRunwaySeconds
    }

    /// The audio half, same shape.
    var audioDeliveryRunway: TimeInterval? {
        guard let queued = queuedAudioRunway else { return nil }
        return queued + cachedAudioRunwaySeconds
    }

    /// Video banked IN THE PIPELINE — queued packets plus decoded frames, no
    /// store content. Starvation is about this: an empty queue freezes the
    /// picture however much the store holds behind it.
    var queuedVideoRunway: TimeInterval? {
        guard videoDecoderOpened else { return nil }
        if isVideoLaneWarmSuspended { return suspendedVideoRunway }
        return max(0, videoPacketQueue.contentSeconds + pendingVideoContentSeconds)
    }

    var queuedAudioRunway: TimeInterval? {
        guard hasAudioTrack else { return nil }
        return max(0, audioPacketQueue.contentSeconds + pendingAudioContentSeconds)
    }

    /// The binding runway IN THE PIPELINE — queued packets, decoded frames and
    /// PCM, no store content. The frozen-clock veto reads this
    /// (`PlayerBackend.bufferedPipelineAhead`): its premise is that a real
    /// stall drains the runway, and cached content drains only when a pump
    /// consumes it, so a supply that is stuck would never drain it.
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

    // MARK: - Cached runway (media cache P1)

    /// Per track, the whole fragments the byte store holds past the demuxer's
    /// CURRENT position (`MediaDemuxing.cachedContentAhead`). Invariant: a
    /// nonzero value was measured since that track's reader last moved. So it
    /// is re-measured at the end of every fill pass — where the demuxer's
    /// position and the queues it just filled agree — and zeroed before
    /// anything moves a reader or drops what it produced: every pump (the
    /// fragments it turns into packets were counted as cached, and would be
    /// counted twice, queued and cached, for as long as it runs), every
    /// video-reader repositioning, every queue flush, and the lane leaving
    /// warm suspension. A pass that exits early leaves the zero, never a
    /// figure from before its pump. Zero while a pump waits on the network is
    /// exact (nothing contiguous is held past its cursor); during a
    /// store-served pump it is a momentary underestimate. Between fills the
    /// store can only grow ahead of the reader (late chunk admissions: an
    /// underestimate) or lose bytes. Every cached-addend observation validates
    /// the retained irreversible witness, so removal does not await another fill.
    private var cachedVideoRunway: MediaCachedTrackContentAhead = .empty
    private var cachedAudioRunway: MediaCachedTrackContentAhead = .empty
    private var residentVideoDisplay: MediaResidentDisplayFragment?
    private var residentAudioDisplay: MediaResidentDisplayFragment?
    private var retireVideoDisplayBeforeRefresh = false
    private var retireAudioDisplayBeforeRefresh = false
    var cachedVideoRunwaySeconds: TimeInterval { cachedVideoRunway.seconds }
    var cachedAudioRunwaySeconds: TimeInterval { cachedAudioRunway.seconds }
    /// Bumped by every reset; a refresh that suspended across one drops its answer.
    private var cachedRunwayEpoch: UInt64 = 0

    func resetCachedRunway() {
        resetCachedRunway(video: true, audio: true)
    }

    /// Zero the tracks whose reader is about to move (or whose output was
    /// dropped). The epoch bump also drops a refresh in flight, whose answer
    /// for the moved track would describe the old position.
    private func resetCachedRunway(video: Bool, audio: Bool, preservingDisplay: Bool = false) {
        if preservingDisplay {
            cachedRunwayEpoch &+= 1
        } else {
            clearResidentDisplay(video: video, audio: audio)
        }
        if video { cachedVideoRunway = .empty }
        if audio { cachedAudioRunway = .empty }
    }

    private func clearResidentDisplay(video: Bool, audio: Bool) {
        cachedRunwayEpoch &+= 1
        if video {
            residentVideoDisplay = nil
            retireVideoDisplayBeforeRefresh = true
        }
        if audio {
            residentAudioDisplay = nil
            retireAudioDisplayBeforeRefresh = true
        }
    }

    private func refreshCachedRunway(generation gen: Int) async {
        // No store behind the demuxer (kill switch, live, files): nothing to
        // measure, so no actor hop on every fill.
        guard demux.measuresCachedContentAhead else { return }
        let epoch = cachedRunwayEpoch
        let retireVideo = retireVideoDisplayBeforeRefresh
        let retireAudio = retireAudioDisplayBeforeRefresh
        // Consume before suspension; a newer reset must retain its pending flags.
        retireVideoDisplayBeforeRefresh = false
        retireAudioDisplayBeforeRefresh = false
        if retireVideo || retireAudio {
            await demux.retireResidentDisplay(video: retireVideo, audio: retireAudio)
            guard isCurrentGeneration(gen), epoch == cachedRunwayEpoch else { return }
        }
        let ahead = await demux.cachedContentAhead()
        guard isCurrentGeneration(gen), epoch == cachedRunwayEpoch else { return }
        cachedVideoRunway = ahead.video
        cachedAudioRunway = ahead.audio
        residentVideoDisplay = ahead.videoDisplay
        residentAudioDisplay = ahead.audioDisplay
    }

    /// Delivery-health runway: the minimum runway across present tracks (`nil`
    /// only when neither track is measurable).
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
        // Compressed access units are indivisible. Leave the existing minimum
        // track room beyond the renderer reserve so a pump can include the AU
        // that crosses the exact reserve boundary.
        return requiredAudioLaunchContentSeconds + minTrackFillRoom
    }

    /// Not private: `DemandPacedPlayerBackend.seekLaunchReserve` publishes this
    /// same number as the engine's end-of-media seek reserve, so the ceiling the
    /// player clamps a target to and the requirement this session will enforce
    /// on that target are one value rather than two that agree today.
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
        // Once a quiet coordinator has drained, no traffic can restart until
        // its existing gate is released. Off/default-off adds no idle queries.
        let cached = helperTelemetry.value
        guard !(multiConnectionQuietGate.isQuiet && cached.identity != nil && cached.activeRequests == 0),
              cached.state != .unavailable, cached.state != .suppressed,
              cached.state != .unsupported else { return }
        helperTelemetry.request(generation: generation, currentGeneration: { [weak self] in
            self?.generation ?? Int.max
        }, query: { [demux] in await demux.multiConnectionTelemetry() })
    }

    /// The reason rides on the shared gate: the demuxer forwards only the Bool,
    /// and its prefetcher reads `.policy` from the gate to retire in-flight pieces.
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

    /// Rolls the prefetch horizon forward during continuous playback even when
    /// packet queues stay full and `demux.pump` is sleeping (throttled to >= 1.0s).
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
                // Rate changes wall-clock wait only. Re-authorize the same
                // content-time boundary under the new revision; never seek the
                // audio master or restamp decoder input.
                hold.rateRevision = playbackRateRevision
                activeWarmVideoImageHold = hold
            }
            if isReady {
                // Atomic with clock + audio demand; freeze display while paused/underrun.
                applyPipelineDemand()
                // Path A redesign step 1: supply is the self-paced loop; just nudge it.
                requestSupplyWake()
                scheduleAudioDecodeIfNeeded()
            }
        }
    }

    /// Display slave rate: 0 while not playing, seeking, or buffering
    /// (no silent free-run; contract rule 4).
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

    /// Speaker-facing media position. F1 remains `clock.mediaTime`; this
    /// projection is display-only and accounts for downstream audio processing.
    var audioPresentationMediaTime: TimeInterval {
        sampleAudioPresentation().mediaTime
    }

    private func sampleAudioPresentation() -> MediaAudioPresentationSnapshot {
        MediaAudioPresentationSnapshot(
            contentTime: clock.mediaTime,
            timing: hasAudioTrack ? audioRender.presentationTiming : .logical
        )
    }

    /// Single due boundary used by ASBD and poll renderers.
    var videoPresentationDueTime: TimeInterval {
        audioPresentationMediaTime + videoPresentLeadSeconds
    }

    var videoHost: UIViewController { videoRender.hostViewController }

    /// Fixed-shape, bounded seek trace. Values are limited to counters,
    /// booleans, times, and opaque identities; it must remain safe to emit from
    /// the MainActor seek transaction without exposing media or source data.
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
        // AFTER every stored property, because both of these capture `self` and
        // Swift forbids that until the instance is fully initialized. The relay
        // wake was written between `demux` and `videoDecoder` and broke the
        // build with "variable 'self.videoDecoder' used before being
        // initialized" — a definite-initialization error, which is why a
        // syntax-only parse could not see it.
        self.packetRelay.setWake { [weak self] in
            // Hops to the session's actor; the relay is the ordered buffer, so
            // whichever drain runs first takes everything in FIFO order and a
            // late one simply finds it empty. `drainPending` inside the relay
            // keeps this to one scheduled hop per burst rather than one per
            // published batch.
            Task { @MainActor [weak self] in
                self?.drainRelayedPackets()
            }
        }
    }

    func open(_ request: MediaOpenRequest) async {
        pausedCaptureSeekPreparationReceipt = nil
        helperTelemetry.invalidate(.parked)
        multiConnectionQuietGate.setParked(true)
        // Invalidate the old generation synchronously, before waiting behind
        // an older open/close operation. This stops late callbacks from
        // continuing to consume the previous session while the replacement is
        // queued.
        // A foreground warm preparation may be suspended in a non-cooperative
        // demux/decoder await. Retire that run before the replacement can
        // mutate the source or decoder; its orphan fence remains until both
        // the primary and the one requested interrupt return.
        cancelWarmVideoImageHoldRefresh()
        supersedeWarmVideoPreparationRun()
        cancelSupplyLoop()
        cancelDecode()
        clearPiPEventSource()
        generation &+= 1
        let gen = generation
        stopPipeline(emitPaused: false)
        // Record decoder retirement before waiting behind the predecessor
        // lifecycle operation. If that predecessor is still inside an async
        // decoder open, this only marks its exact opening ledger entry as
        // pending; the open completion owner starts close after the await
        // returns. The initial constructor decoder has no opening/native
        // ownership yet, so this remains a no-op for the first open.
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
        // A preceding open may have been cancelled after it started a demux or
        // decoder. Close those resources only after that operation has returned
        // so the replacement cannot race the old actor/object state.
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
        // stop()/invalidate() clears renderer-owned closures. The session keeps
        // the backend/ViewModel handler, so every successor open must reinstall
        // the bridge before the first frame can become presentation proof.
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
        // A resume open (history, quality/codec switch, CDN/decoder reload)
        // is a seek to the start position: its run-up is accounted — and, for
        // the classifier, observed — from here to the end of priming.
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
        audioDrainingToEnd = false
        audioDrainPlayoutDeadline = nil
        audioDrainEmptiedAt = nil
        isSeekInFlight = false
        audioDisplayObservation.reset(to: outputMediaFloor)
        activeSeekToken = nil
        preparedSeek = nil
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

        // Cold-start stage marks: no-ops outside a startup session (every
        // internal reload / non-cold open), deduped within one, same contract
        // as the VLC backend's marks. `first-clock-tick` stays central in
        // PlayerViewModel.
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
            // Installed BEFORE the open, so the prime's own pumps already
            // deliver incrementally. `clearPacketBuffers` (run by
            // `stopPipeline` above) has already reset it, so nothing from the
            // previous timeline can survive into this one. A demuxer that
            // cannot stream ignores this and keeps returning batches.
            await demux.setPacketRelay(packetRelay)
            demuxOpenCount &+= 1
            await demux.setMultiConnectionQuiet(multiConnectionQuiet)
            var demuxRequest = request
            demuxRequest.multiConnectionQuietGate = multiConnectionQuietGate
            demuxRequest.networkByteCounter = openNetworkCounter
            try await demux.open(demuxRequest)
            // Heads fetched (256KiB ×2, parallel), moov+sidx parsed, and — on
            // a resume — the open-at-target seek done. The per-track split is
            // in the `[PathA] http initial-head` lines.
            tracing.mark(.demandDemuxOpenDone, token: request.startupTraceToken)
            guard isCurrentGeneration(gen) else { return }
            let demuxProvidesAudio = await demux.providesAudioTrack
            videoContinuityTopology = await demux.videoContinuityTopology
            hasAudioTrack = request.audioURL != nil || demuxProvidesAudio
            await openVideoDecoderIfNeeded(expectedGeneration: gen)
            guard isCurrentGeneration(gen) else { return }
            await openAudioDecoderIfNeeded()
            guard isCurrentGeneration(gen) else { return }
            // Hide the audio-graph build (AVAudioSession activate + engine
            // build + prepare — the measured demand-play-started →
            // demand-audio-graph-ready Δ ≈ 107ms) under the prime's network
            // awaits: this actor is idle there, so the queued task runs then.
            // play()'s start(source:) reuses the prepared graph and pays only
            // eng.start(). Generation-guarded; the renderer's prewarm is a
            // no-op once a graph exists or after start.
            Task { [weak self] in
                guard let self, self.isCurrentGeneration(gen) else { return }
                self.audioRender.prewarmHardwareGraph()
            }
            let d = await demux.duration
            clock.setDuration(d)
            updatePiPPlaybackState()
            // Prime before ready. Relay ingress may submit video as soon as a
            // complete sample arrives; playback itself commits only after the
            // displayable-video + renderer-launch-reserve predicate below.
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
                // A LOCAL pipeline miss, not an input or host verdict: both
                // decoders opened (`decoderReadinessFault` passed), and the
                // prime did not bank a launch reserve. Typed like the seek
                // path's `SeekPrimingFailure` so it reaches recovery boundary 1
                // (one bounded source-aware reopen) instead of the host-swap
                // path, which refuses before the first frame and left this as
                // a terminal overlay carrying the engine sentence.
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
        // A rebuilt TimePitch graph owns the presentation offset. Start it before
        // pinning the display so pause/resume cannot reuse the stopped graph's
        // zero-offset projection.
        startAudioRenderIfNeeded(reconcileAuthorizedOutput: true)
        // The AVAudioSession activation + AVAudioEngine build/prepare/start
        // above run synchronously on this actor — the Δ from
        // `demand-play-started` is the audio bring-up cost.
        tracing.mark(.demandAudioGraphReady, token: activeStartupTraceToken)
        applyPipelineDemand()
        resetPipeInstrumentWindow()
        // Path A redesign step 3: ASBD-pull present feed (not audio-tick push).
        armPresentFeedIfNeeded()
        presentDueVideoFrames()
        startSupplyLoop()
        scheduleVideoDecodeIfNeeded()
        scheduleAudioDecodeIfNeeded()
    }

    /// Explicit App audio authority while background video remains locally owned.
    /// No video-renderer prepare, decoder recreation, source load, or video Play
    /// occurs. Already-admitted audio output repair may prepare its native graph.
    func resumeAudioWhileVideoSuspended(_ token: DemandVideoSuspendToken) -> Bool {
        guard isReady, !hasEmittedEnded, isVideoLaneWarmSuspended,
              activeVideoSuspendToken == token,
              token.sessionGeneration == runtimeGeneration,
              token.ownerGeneration == activeOwnerGeneration else { return false }
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
            activeSeekToken = nil
            preparedSeek = nil
            isSeekInFlight = false
        }
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
            audioDisplayObservation.invalidate()
            audioRender.stop()
        } else {
            audioDisplayObservation.suspendForPause(fallbackTime: clock.mediaTime)
            audioRender.pause()
        }
        cancelSupplyLoop()
        cancelDecode()
        onEvent?(.paused)
    }

    /// Park for reuse: the same quiesce as `pause()` — display pinned at rate
    /// 0, audio graph parked (it survives stop() by design), supply/decode
    /// loops cancelled — plus retirement of the live streaming-mdat requests,
    /// so a parked session downloads NOTHING. Every reusable thing survives:
    /// demux readers and cursors, packet queues, pending frames, PCM, both
    /// decoders, the clock position, `isReady`. A later `play()` resumes in
    /// place; the pump reopens its streams at the committed sample/byte
    /// boundary through the same continuity machinery a discarded pump uses.
    ///
    /// Emits NO event — the owner is exiting and must not receive a synthetic
    /// `.paused` into its teardown. Returns false when nothing is safely
    /// parkable (not ready, a seek in flight, a runtime fault delivered) —
    /// the caller then falls back to a full stop.
    func parkForReuse() -> Bool {
        let costSpan = UIHitchMonitor.beginSpan("session.park")
        defer { UIHitchMonitor.endSpan(costSpan) }
        // An ENDED session must not park: play() refuses at EOF
        // (`hasEmittedEnded, clock.isAtEnd`), so a claim would synthesize
        // readyToPlay over a frozen final frame with every play ignored.
        // Watched-to-end re-entry is a cold open, correctly starting at 0.
        guard isReady, !isSeekInFlight, !hasEmittedEnded,
              !isVideoLaneWarmSuspended, !isPreparingWarmVideoLane,
              activeWarmVideoImageHold == nil,
              runtimeFaultedGeneration == nil else {
            return false
        }
        // This precedes async stream retirement. Late pump/rate updates and
        // quiet-window completions cannot authorize another transport resume.
        helperTelemetry.invalidate(.parked)
        multiConnectionQuietGate.setParked(true)
        isPlaying = false
        isBuffering = false
        resetVideoLivenessState(resetStartup: false)
        resetFlowGapTracking()
        updatePiPPlaybackState()
        disarmPresentFeed()
        applyDisplayPlayback(rate: 0)
        audioDisplayObservation.suspendForPause(fallbackTime: clock.mediaTime)
        audioRender.pause()
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

    /// A claimed (parked → reused) session plays under a NEW backend load
    /// generation without re-running `open()`. Its runtime faults must carry
    /// that new authority — stamped with the original load's generation they
    /// would all be dropped as stale and recovery boundary 1 would be blind
    /// for the whole resumed playback.
    func adoptOwnerGeneration(_ generation: UInt64) {
        pausedCaptureSeekPreparationReceipt = nil
        (videoRender as? SampleBufferVideoRenderer)?.retireNonWarmPresentationImage()
        revokeAudioMaintenancePermission()
        let releasedImageHold = activeWarmVideoImageHold != nil
        cancelWarmVideoImageHoldRefresh()
        activeWarmVideoImageHold = nil
        if releasedImageHold {
            // Owner replacement fences both the typed hold and every frame/
            // proof candidate decoded under it. Clearing only the authority
            // would let those old frames become a current-owner proof after
            // the next audio tick.
            clearPendingVideoFrames()
            videoPackets = []
            residualVideoPackets = []
            videoPacketQueue.reset()
            // The dropped packets lie before the reader: what the store holds
            // past it is no longer contiguous with the playhead.
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
        // Retire before any awaited old decode/demux work: a foreground
        // refresh during that wait must not resurrect the pre-seek still.
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
        // Seeking changes the session generation and reader authority. A warm
        // preparation that is still awaiting the old reader must be cancelled
        // at the same synchronous boundary as the generation bump, otherwise
        // its late result can keep owning the old lane until the deadline.
        supersedeWarmVideoPreparationRun()
        cancelSupplyLoop()
        // Capture the outstanding VIDEO decode task BEFORE `cancelDecode()`
        // clears it, for the same structural reason as the audio capture
        // below and in the same shape `performWarmVideoPreparation` already
        // uses (`let previousDecodeTask = decodeTask` there):
        // `cancelVideoDecode(clearHandle: true)` requests cooperative
        // cancellation and nils `decodeTask`; it does not wait for a burst
        // already suspended inside `await decodingDecoder.decode(packet)`.
        // `MediaVideoDecoding` carries no `@MainActor` and every conformer is
        // `@unchecked Sendable`, so that submission really does run off this
        // actor and can still be inside the decoder when
        // `await videoDecoder.flush()` below runs.
        //
        // What this costs is NOT the audio lane's crash, and this must not be
        // read as if it were. `VideoToolboxDecoder` serializes decode against
        // flush under its own `stateLock` — the whole body of both is one
        // `withLock` — so neither can tear Swift state the way the
        // unsynchronized `pcmResampler` was torn. What is lost is ORDER: with
        // that lock as the only arbiter, the flush can win the race and the
        // stale pre-seek access unit is then submitted AFTER it, re-rooting
        // the decode-order baseline `integrity.noteFlush()` just dropped, so
        // the seek's first target-side submission is judged against a
        // position the stream has left and the VT session carries pre-seek
        // reference state into the target GOP. Nothing PRESENTS that frame
        // (the burst's post-await generation/operation guard drops it), which
        // is why no device crash was ever attributed to this. The point of
        // joining is that on the lane it covers the invariant then rests on
        // one fact — the flush is the last thing to touch the decoder before
        // target-side submissions — instead of three unrelated ones that each
        // independently hold it up today: VideoToolbox's internal lock, that
        // post-await guard, and a seek target always landing on a keyframe.
        //
        // What this join covers, exactly: the SCHEDULED lane.
        // `scheduleVideoDecodeIfNeeded` is the only writer of `decodeTask`, so
        // this handle names the in-playback decode pump — the burst
        // outstanding when a seek arrives during ordinary playback, which is
        // the common case by a wide margin.
        //
        // It does NOT cover a DIRECT burst, and an earlier revision of this
        // comment claimed it did. Five of the six `drainVideoDecodeBurst` call
        // sites are direct (cold prime, seek priming, runway prime, the warm
        // repair loop); each runs inside its caller's own async chain and
        // never writes `decodeTask` — which is exactly why
        // `videoDecodeLaneOwners` exists, and its declaration says so. So on a
        // background return whose warm repair loop is parked in `decode()`,
        // this handle is nil, the join is a no-op, and the window above stays
        // open on that path: `supersedeWarmVideoPreparationRun` at the top of
        // this function cancels and orphans that run without awaiting it, and
        // the interrupt it fires reaches the DEMUXER, never the decoder.
        //
        // Waiting on `videoDecodeLaneOwners`/`directVideoDecodeLane` instead
        // would cover both lanes and is deliberately NOT done here: a burst
        // parked in a non-cooperative decoder never runs its `defer`, and a
        // leaked owner turns `scheduleVideoDecodeIfNeeded` into a permanent
        // no-op — frozen video, worse than the inversion it prevents (see
        // `videoDecodeLaneOwners`), and from this MainActor function a
        // permanently held FIFO gate is a frozen UI. Closing the direct lane
        // needs a bounded exit for an orphaned burst first — the warm
        // preparation has one, direct decode does not — so it is written down
        // in `docs/PLAYER_TODO.md` instead of being approximated with a
        // wall-clock timeout here.
        //
        // The audio join below has the same shape and the same residual hole
        // (`fillPCMRing` has direct callers of its own), so this is a lane
        // boundary, not a video-side asymmetry.
        //
        // Same exposure as the audio join, stated rather than hidden: this
        // seek is lengthened by however long that decode call takes to
        // return, including a burst deliberately retained across warm
        // suspension (`cancelVideoDecode(clearHandle: false)`). No timeout —
        // nothing in this file bounds a decoder call by a wall-clock guess.
        revokeAudioMaintenancePermission()
        await audioRender.awaitAudioMaintenanceSettlement()
        guard !Task.isCancelled, generation == seekEntryGeneration,
              activeOwnerGeneration == seekEntryOwnerGeneration else { return supersededPreparation() }
        let previousDecodeTask = decodeTask
        // Capture the outstanding audio decode task BEFORE `cancelDecode()`
        // clears it: `cancelAudioDecode(clearHandle: true)` only requests
        // cooperative cancellation and nils `audioDecodeTask` — it does not
        // wait for a decode already suspended inside
        // awaiting the audio decoder to actually return.
        // `MediaAudioDecoding` carries no `@MainActor` (unlike video
        // rendering). AudioToolboxAudioDecoder now isolates native state on
        // its own actor, which excludes simultaneous decode/reset/disposal.
        // This join still owns operation ordering across the scheduled lane:
        // flush follows the actual return, not just cancellation. It originally
        // closed an array-index-out-of-range resampler race before the native
        // decoder itself acquired that isolation.
        // `performWarmVideoPreparation` (see `let previousAudioDecodeTask =
        // audioDecodeTask` there) awaits the identical handle before mutating
        // decoder state for the identical reason; this follows that pattern
        // instead of racing the flush.
        //
        // The exposure this accepts, stated rather than hidden: awaiting a
        // task that is parked inside a cancellation-ignoring decode call
        // lengthens this seek by however long that call takes to return.
        // `performWarmVideoPreparation` already accepts the matching
        // exposure on its own await ("a cancelled-but-not-yet-stopped pump
        // blocked on a ranged read"), and the alternative here — leaving the
        // window open between this cancel and the flush below — is the
        // crash, not a faster seek. No timeout is added: nothing in this
        // file bounds a decoder call by a wall-clock guess, and an arbitrary
        // one would trade a documented exposure for an unjustified one.
        let previousAudioDecodeTask = audioDecodeTask
        cancelDecode()
        // Joined in the order the two flushes below run, so each lane's last
        // submission is provably behind its own flush.
        await previousDecodeTask?.value
        await previousAudioDecodeTask?.value
        // A replacement open fences this seek synchronously by advancing the
        // session generation. Do this check before any flush, demux mutation,
        // or generation bump: the old seek must hand off silently and never
        // tear down the successor's decoder/source state.
        guard !Task.isCancelled,
              generation == seekEntryGeneration,
              activeOwnerGeneration == seekEntryOwnerGeneration else {
            return supersededPreparation()
        }
        disarmPresentFeed()
        resetVideoLivenessState(resetStartup: false)
        resetPipeInstrumentWindow()
        resetFlowGapTracking()
        // Seek retires the old sample, not the configured helper capability.
        // A demux that already reported unsupported stays terminal; otherwise
        // pending admits a fresh query under the new generation/refresh epoch.
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
        activeSeekToken = token
        preparedSeek = nil
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
        audioDrainingToEnd = false
        audioDrainPlayoutDeadline = nil
        audioDrainEmptiedAt = nil
        // A2-α seek: freeze F1 during demux/reprime, but keep a running audio
        // graph alive. Stopping it here renegotiates the hardware route and
        // creates the audible gap observed on device after every seek.
        isSeekInFlight = true
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
            audioDisplayObservation.reset(to: outputMediaFloor)
            seekFirstPacketLogged = false
            // Each flush suspends, and a newer seek can start (and even finish
            // priming) meanwhile: its entry fences only on the generation it
            // captured, not on this seek's flushes. Everything after a flush is
            // session-wide — the other decoder, the renderer queue (a stale
            // flush would drop the newer seek's enqueued frames), the preroll
            // classifier's reference state, the phase stopwatch and the
            // `[PathASeekPreroll]` stats slot — so a superseded seek hands off
            // here exactly like the post-demux guard above, touching none of it.
            await videoDecoder.flush()
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            await audioDecoder.flush()
            guard isCurrentGeneration(gen), activeSeekToken == token else {
                return notReady()
            }
            videoRender.flush()
            // The classifier's reference state belongs to the flushed decoder
            // state: both restart at the seek anchor.
            videoPrerollClassifier?.reset()
            seekPhaseStopwatch?.mark(.flush)
            logSeekTrace(
                phase: "flush",
                target: clock.mediaTime,
                token: token,
                result: true,
                decoderFlush: true
            )
            // Re-pin after decoder/discontinuity cleanup. The renderer graph is
            // still live and its old slot remains untouched behind the gate.
            resetDisplayTimeline(to: clock.mediaTime)
            // ── Target-side priming ───────────────────────────────────
            //
            // Refill until each required track holds content that survives
            // target-relative preroll (pre-target anchor run-up depth cannot
            // satisfy `SeekPrimingGate`), bounded by EOF, observed anchor
            // run-up limits, and decode-frontier progress. Post-commit top-up
            // belongs to the continuous supply loop.
            //
            // A pump that THROWS still propagates to the `catch` below and keeps
            // its existing `.demuxFailed` classification — that IS a demux
            // failure. Only the "positioned fine, primed nothing" outcome is
            // reclassified, because only that one was misfiled.
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
                // Handed off, not failed. Settling this as an error would feed
                // the recovery ladder a fault that belongs to a seek nobody is
                // waiting for any more.
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
                // Renderer staging is the only operation allowed to pull target
                // PCM. It is supply, not F1 progress, because the seek remains
                // fenced until a later committed-epoch drain.
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
            preparedSeek = preparation
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
            // A priming that threw never reaches `finishPrerollStats`; end the
            // run-up accounting (and the classifier's priming-only
            // observation) here so nothing is parsed outside priming.
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
        // `[PathASeekPhase]`, once per committed-or-refused preparation.
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
            // A backend supersession may abort the renderer while its commit
            // is waiting for the callback boundary. That is an expected stale
            // result; keep the replacement seek's fence intact instead of
            // stopping the graph and settling the old request as a failure.
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

        // The backend's serial gate is checked once more after renderer
        // acknowledgement. No target tick or F1 drain is emitted for a request
        // whose authority was revoked while waiting for an RT boundary.
        guard isAuthorized?() ?? true else {
            discardSeekPreparedContent(for: preparation.token)
            preparedSeek = nil
            activeSeekToken = nil
            isSeekInFlight = true
            isBuffering = true
            logSeekTrace(
                phase: "abort",
                target: preparation.target,
                token: preparation.token,
                result: false
            )
            return false
        }

        preparedSeek = nil
        activeSeekToken = nil
        isSeekInFlight = false
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
                self?.isSeekInFlight = false
            }
        )
    }

    func abortPreparedSeek(_ preparation: MediaEngineSeekPreparation) {
        guard activeSeekToken == preparation.token else { return }
        audioRender.abortSeekTransition(preparation.token)
        discardSeekPreparedContent(for: preparation.token)
        preparedSeek = nil
        logSeekTrace(
            phase: "abort",
            target: preparation.target,
            token: preparation.token,
            result: false
        )
        // Keep the session seek fence and renderer gate asserted for a queued
        // newer request. Lifecycle stop/load invalidates the generation and
        // tears the graph down if no replacement arrives.
    }

    func seek(to time: TimeInterval) async -> Bool {
        let preparation = await prepareSeek(to: time)
        guard preparation.isReady else { return false }
        return await commitPreparedSeek(preparation, isAuthorized: nil)
    }

    /// Result of the target-relative priming loop. `.superseded` is a distinct
    /// case on purpose: a handed-off seek is not a failure and must never reach
    /// the recovery ladder.
    private enum SeekPrimingOutcome {
        case ready(SeekPrimingGate)
        case superseded
        case failed(SeekPrimingFailure, SeekPrimingGate)
    }

    /// The open's launch prime, as the same bounded loop the seek path runs.
    ///
    /// An open is a seek to `outputMediaFloor` (0, or the resume target) with
    /// the renderer's LAUNCH reserve instead of its seek reserve, and it used
    /// to ask the readiness question once, after a single pass. Two ordinary
    /// events made that one pass come back empty-handed and fail the open
    /// ("launch reserve unavailable"): a superseded generation's pump still
    /// holding `isFillingQueues` (a reopen on the same session — quality
    /// change, host swap, re-entry — so the fill returns having pulled
    /// nothing), and a fetch that ends on a fragment boundary before the
    /// reserve is banked. Neither is evidence the pipeline is broken. The
    /// references agree (Media3 stays BUFFERING and throws only when stuck and
    /// NOT loading; AVPlayer waits; mpv starts early rather than fails): a
    /// startup that is still making progress waits.
    ///
    /// Each pass is the work the single pass did, in the same order, so the
    /// state committed at readiness is unchanged; `SeekPrimingGate` is the
    /// exit condition and its bounds are the seek path's (EOF, run-up budget,
    /// stalled real pulls, demux-gate wait) — no new number is introduced.
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

            // See `primeSeekTargetSide`: a held fill gate means this pass
            // pulled nothing, and the wait is bounded separately from the
            // stalled-pull count.
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
            // Resume-open fast preroll (design §4.2b): the same batch loop as
            // a seek, fenced by the open's generation.
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

    /// Drive supply + decode until each required track holds content that
    /// survives target-relative preroll, or until a bounded, semantic reason
    /// says it never will (`SeekPrimingPolicy` documents the contract and the
    /// device evidence).
    ///
    /// One "pass" is deliberately the SAME work the single-shot version did —
    /// capped packet refill, video decode burst, post-preroll video runway,
    /// capped PCM fill — so the committed state at readiness is what it always
    /// was. The fix is that the pass repeats while the only thing it produced
    /// was pre-target material, instead of handing that to the gate as if it
    /// were runway. No queue high-water is raised, nothing is reopened, and a
    /// pass that cannot pull does not spend the stall bound.
    ///
    /// `primeVideoRunwayAfterPreroll` keeps its original entry condition
    /// (`outputMediaFloor > ε || dropV > 0`) rather than being made
    /// unconditional. That condition is not a heuristic: a seek whose target is
    /// above zero always satisfies it, and a target of exactly zero cannot have
    /// a run-up at all — nothing is below 0 — so the only case it excludes is
    /// the one with nothing to chew. Making it unconditional would decode a full
    /// frame-queue high water on every seek-to-0 for no readiness gain, which is
    /// latency, not correctness. The banking it does on every other seek is
    /// unchanged.
    private func primeSeekTargetSide(
        generation gen: Int,
        token: MediaAudioSeekToken
    ) async throws -> SeekPrimingOutcome {
        var gate = SeekPrimingGate(
            requirements: SeekPrimingRequirements(
                target: outputMediaFloor,
                hasAudioTrack: hasAudioTrack,
                // A warm-suspended video lane decodes nothing during audio-only
                // background seeks and re-anchors to the audio position on foreground.
                requiresVideo: !isVideoLaneWarmSuspended,
                // The renderer's own reserve, not a number this loop invents:
                // `prepareSeekTransition` refuses the transaction below it, so
                // any other value would either commit a transition the renderer
                // rejects or keep priming past what it needs.
                requiredPCMContentSeconds: requiredAudioSeekContentSeconds
            )
        )

        func isSuperseded() -> Bool {
            !isCurrentGeneration(gen) || activeSeekToken != token
        }

        while true {
            if Task.isCancelled { return .superseded }
            if isSuperseded() { return .superseded }

            // `isFillingQueues` is the demuxer's re-entrancy gate, not a policy
            // flag: two concurrent pumps scramble packet order, so a fill that
            // finds it held returns having produced NOTHING. A superseded
            // generation's pump can still be awaiting its transfer here
            // (cancellation does not interrupt an await already inside demux
            // I/O), and a pass that silently produced nothing is exactly how a
            // seek reached the readiness question with an empty video queue.
            // Waiting is correct; counting the wait as evidence about the
            // demuxer is not.
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

            // Fast preroll (design §4.2): the pre-target run-up, batched and
            // pipelined. Kill switch off ⇒ not entered; the pass is today's.
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
                // Keep the trace's phase sequence intact
                // (generation → demux → flush → refill → preroll → prepare →
                // commit). Only the FIRST pass emits it: the per-pass story is
                // the priming summary logged at readiness / failure, and a line
                // per pass would bury the phases a report is read for.
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
            // The gate re-checks supersession itself so no verdict — ready or
            // failed — can be produced from a generation that no longer owns
            // the transaction.
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

    /// Demux positioning SUCCEEDED and target-relative priming did not complete.
    ///
    /// This is NOT `failSeekPreparation`, and the difference is the whole point
    /// of the split. `failSeekPreparation` reports a `MediaEngineError` through
    /// `.failed`, which the backend turns into `terminalFailure` and the
    /// ViewModel into a dead-end "Playback error" overlay — the right answer for
    /// a demuxer that could not position or a renderer that refused a commit,
    /// and the wrong answer for a pipeline that is sitting correctly positioned
    /// at the target with nothing banked. That state has a local repair (reopen
    /// the retained source AT the target) and a boundary that owns it, so the
    /// outcome crosses as a typed `MediaRuntimeFault` at the new
    /// `.seekPriming` stage instead of as a `demuxFailed` string.
    ///
    /// The seek itself still settles as unsuccessful: the caller returns a
    /// not-ready preparation, so the backend clears `pendingSeekTarget` and
    /// completes the request `false`. The recovery position survives that,
    /// because `PlayerViewModel.recoveryPosition` consumes `durableResumeTarget`
    /// (armed by every user seek and every resume intent) and the fault is
    /// published BEFORE the preparation returns.
    ///
    /// Order matters: the seek transaction is torn down first, so the renderer's
    /// staged slot is released and no later `abortPreparedSeek` can act on a
    /// token this method already retired. `publishRuntimeFault` then fences the
    /// generation and stops the pipeline — it is the last boundary event this
    /// generation will produce, so nothing else may follow it.
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
        activeSeekToken = nil
        preparedSeek = nil
        isSeekInFlight = false
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

    /// The open path's launch-reserve miss as a typed fault. The priming
    /// gate's verdict names it when there is one — the same split the seek path
    /// reports (input starved / EOF vs. a pipeline that consumed input without
    /// output); without one (a gate that said ready and a predicate that then
    /// disagreed) the short track's own input evidence decides.
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

    /// A seek's renderer step failed after demux positioning succeeded — a
    /// local miss at the target, typed like `failSeekPriming` so it reopens
    /// through recovery boundary 1 rather than surfacing as an untyped
    /// `.failed` that the ViewModel can only treat as a host problem.
    private func failSeekRendererStep(
        _ token: MediaAudioSeekToken,
        generation gen: Int,
        label: String
    ) {
        guard activeSeekToken == token else { return }
        let target = clock.mediaTime
        audioRender.abortSeekTransition(token)
        discardSeekPreparedContent(for: token)
        activeSeekToken = nil
        preparedSeek = nil
        isSeekInFlight = false
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
        activeSeekToken = nil
        preparedSeek = nil
        isSeekInFlight = false
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
        isSeekInFlight = false
        activeSeekToken = nil
        preparedSeek = nil
        // The old decoder is no longer current before any lifecycle cleanup
        // runs. Retirement is fire-and-forget on the utility executor; a
        // native VT invalidate must not block the MainActor teardown path.
        retireCurrentVideoDecoderWithoutWaiting()
        stopPipeline(emitPaused: false)
        videoDecoderOpened = false
        audioDecoderOpened = false
        isBuffering = false
        hasEmittedEnded = false
        demuxReachedEOF = false
        audioDrainingToEnd = false
        audioDrainPlayoutDeadline = nil
        audioDrainEmptiedAt = nil
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

    /// Stop every producer before publishing a typed fault. The generation is
    /// retained in the event so the backend can validate the source of it;
    /// `runtimeFaultedGeneration` fences any in-flight continuation.
    ///
    /// `mayBeLocalPresentationDebt: false` is for a fault that ENDS an open:
    /// nothing has been presented yet, so there is no presentation to keep
    /// the fault local to, and the open returns right after publishing. Held
    /// as local debt it would leave the backend with neither ready nor error.
    private func publishRuntimeFault(
        _ fault: MediaRuntimeFault,
        generation gen: Int,
        mayBeLocalPresentationDebt: Bool = true
    ) {
        guard gen == generation,
              publishedRuntimeFaultGeneration != gen else { return }
        // A timed-out warm run owns a closed local failure boundary until its
        // cancelled primary actually returns. Any decoder/renderer callback
        // that arrives from that run is late evidence, not a new runtime-fault
        // admission for the current presentation.
        if let orphanedEngineGeneration = warmPreparationTransaction.orphan?.engineGeneration,
           orphanedEngineGeneration == gen {
            return
        }
        // See `DemandVideoFaultLocalityPolicy` for why a backgrounded app makes
        // this local, and for the regression that moved the rule out here.
        let isLocalSuspendedVideoFault = mayBeLocalPresentationDebt && DemandVideoFaultLocalityPolicy
            .isLocalPresentationDebt(
                subsystem: fault.subsystem,
                videoLaneIsWarmSuspended: isVideoLaneWarmSuspended,
                hasObservedPiPLease: hasObservedPiPLease,
                appIsBackgrounded: videoLivenessContext?.appState == .background
            )
        if isLocalSuspendedVideoFault {
            guard suspendedVideoFault == nil else { return }
            // Order is semantics, not style. `isCurrentWarmVideoPreparationAttempt`
            // reads the AMBIENT `Task.isCancelled`, and the relay delivery path
            // raises this fault from inside `decodeTask` itself — so reading the
            // predicate after `cancelVideoDecode` makes the transaction cancel
            // itself and then fail its own currency test, publishing a fault the
            // comment below says must stay local. Nothing the two statements in
            // between mutate (`suspendedVideoFault`, `activeVideoDecodeOperationID`,
            // `decodeTask`, `videoDecoderOpened`) is an input to that predicate, and
            // this class is `@MainActor` with no suspension point here, so hoisting
            // the read is a pure reorder. External cancellation still reads as
            // cancelled at this point and still publishes, unchanged.
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
                // The warm-prepare transaction owns this fault. Keep it local
                // until the one permitted fresh-decoder retry either proves
                // output or returns one typed terminal failure. Publishing the
                // first fault here would start a competing recovery authority.
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

    /// Capture the PiP presentation facts before UIKit/background transition.
    /// This is intentionally independent from the lease itself: the lease
    /// remains the owner, while the snapshot is only evidence for a later
    /// renderer-local repair.
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

    /// Retire only an unresolved native start. The current binding remains
    /// usable for a later explicit start; the renderer replaces the controller
    /// identity so callbacks from the abandoned native request are stale.
    func abandonPendingPiPStart() {
        (videoRender as? any MediaPiPLeaseEventSource)?.abandonPendingPiPStart()
    }

    /// Reconcile one PiP lock/unlock interval. A healthy interval is a no-op;
    /// an unhealthy or progress-less interval gets one renderer flush/re-pin,
    /// followed by the existing local decoder/re-prepare ladder when needed.
    /// No source/open/session replacement is allowed here. The render
    /// generation is supplied by the current presentation fence so a warm
    /// lane can reuse the complete resume state machine safely.
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
            // The renderer flush above is the single presentation repair for
            // this activation. The shared lease-driven task now completes the
            // full warm prepare + PiP resume state machine, avoiding a second
            // preparation if native didStart already began it in background.
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
                // Only the failed-renderer path needs a second renderer flush;
                // decoder-only repair keeps the first successful flush.
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

    /// Capture the current displayed frame for a source-switch cover. The
    /// session only forwards the renderer's real display output; it never
    /// substitutes a queued packet or a future decoded frame.
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
            // A PiP stop can suspend an already-paused transport. Its first
            // post-return decoder fault is still local presentation debt and
            // must not be promoted to terminal/source recovery merely because
            // the user has not pressed Play yet.
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

    /// Re-present the retained paused/warm-suspend still at the didBecomeActive
    /// visibility edge. The renderer decides from its own hold/health state;
    /// this carries no preparation, recovery, or proof authority.
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

    /// Suspend a video lane after native PiP really stopped while the app is
    /// still backgrounded. Unlike the audio-only entry point this contract is
    /// valid for a paused transport: it retains source/index/GOP authority and
    /// records the paused intent in the token, without issuing play or opening
    /// another source/session.
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
        // A token is retained across an unresolved post-resume image hold so
        // that a stale-tail refresh can re-enter the same lane authority. If a
        // new background edge arrives while that hold is still active, it is a
        // new suspension and must receive a fresh token/baseline instead of
        // silently reusing the resumed hold.
        // A seek advances `runtimeGeneration` without ending the suspension;
        // its token is then unusable (`prepareVideoLaneForForeground` requires
        // the current generation), so a re-suspension after a seek must mint a
        // fresh token rather than hand the stale one back.
        if let activeVideoSuspendToken,
           isVideoLaneWarmSuspended,
           activeVideoSuspendToken.sessionGeneration == runtimeGeneration,
           activeVideoSuspendToken.ownerGeneration == activeOwnerGeneration,
           activeVideoSuspendToken.reason == reason,
           activeVideoSuspendToken.resumesPlayback == resumesPlayback {
            return .suspended(activeVideoSuspendToken)
        }

        // A new suspend token supersedes any not-yet-due image hold from the
        // preceding return. The pending output remains generation-fenced, but
        // it no longer owns a release diagnostic or preparation claim.
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

        // Keep the cancelled handle registered until foreground preparation
        // awaits it. A VT submission already inside decode() may ignore task
        // cancellation briefly; dropping the handle would let preparation
        // close/reopen the same decoder underneath that old submission.
        cancelVideoDecode(clearHandle: false)
        // Stage marks for the visible transition. `surface` brackets the two
        // AVFoundation calls that cross into mediaserverd — the synchronizer
        // rate change and the display-layer flush — and `bufs` brackets the
        // CVPixelBuffer release plus the GOP re-bank. Those are the only two
        // sub-steps here that could plausibly cost tens of ms, and until they
        // are measured separately the 2-3 ms total is an aggregate that hides
        // which one moves under load.
        let warmSuspendBegan = ContinuousClock.now
        disarmPresentFeed()
        resetDisplayTimeline(to: audioPresentationMediaTime)
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            renderer.warmSuspendPresentation(mediaTime: audioPresentationMediaTime)
        } else {
            videoRender.flush()
        }
        let surfaceEnded = ContinuousClock.now

        let retainedPackets = videoPackets + residualVideoPackets
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

    /// Keep source/audio ownership after a video-local failure. Never turn a
    /// source-terminal fault or an active PiP transaction into this fallback.
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
        // A timed-out primary may still own a non-cooperative collaborator.
        // It is unsafe to start another preparation against that reader or
        // decoder, even if a caller presents a newer token. Fail closed until
        // the exact orphan reports its return.
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
                // The ACTIVATION VALIDATION, and deliberately a MEASUREMENT
                // rather than a decision.
                //
                // Acting on this — clearing the prepared flag and re-running
                // the refresh — was implemented and reverted. It converted a
                // path that could not fail into one with four terminal exits,
                // on the designed common path: the refresh discards
                // `suspendedVideoGOP`, and `prepareVideoContinuity` closes the
                // active chunk stream and issues ranged reads, so one timeout
                // on a just-woken radio settled `.unsupportedVideoContinuity`
                // — pausing playback behind "Tap Retry" while a decoded,
                // presentable frame sat unreachable in `pendingVideoFrames`,
                // because `resumeVideoLane` requires the flag that was
                // cleared. Even when the refresh SUCCEEDS it tears down the
                // connection the first preparation just established and
                // re-pumps inside the visible window — the very hitch this
                // transaction exists to remove.
                //
                // Whether staleness is real is unknown: no device evidence
                // shows it. So log the answer and change nothing. If the
                // capture shows covers=0 on returns that actually look wrong,
                // the fix belongs at the producer — refresh WITHOUT discarding
                // the fallback GOP — not here.
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

            // Observation only: collect VideoToolbox decode phase timings for this
            // warm transaction. These values never affect admission or rendering.
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
            // Leaving warm suspension: same rule as `resumeVideoLane`.
            resetCachedRunway(video: true, audio: false)
            isVideoLanePreparedForForeground = false
            isPreparingWarmVideoLane = false
            isDecodingWarmVideoCandidate = false
        case .supplyRestartOpportunity:
            resumeSupplyAfterWarmPreparation()
        }
    }

    /// A late primary closes only its own diagnostic scope.
    private func recordWarmPreparationPrimaryReturn(
        _ run: WarmVideoPreparationRun, result: DemandVideoLanePreparationResult
    ) {
        if activeWarmDiagnostics?.runID == run.id {
            warmDiagnosticPhase(result == .prepared ? "prepared" : "completed")
            finishWarmDiagnostics(run: run, result: result)
        }
    }

    /// W1: a diagnostic snapshot of every quantity a warm-preparation timeout
    /// needs explained, taken before this function clears any state (in
    /// particular before `activeWarmVideoImageHold` is cleared below). Purely
    /// observational — nothing here feeds a decision.
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

    /// Cooperative expiry shares the watchdog's exactly-once public owner.
    /// It never returns anonymous cancellation while leaving waiters pending.
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

    /// Supply is SHARED, so it resumes as soon as warm preparation stops
    /// owning the reader — whatever the preparation's verdict was.
    ///
    /// The guards are the existing ownership model, not a new one: an orphaned
    /// run whose primary or interrupt has not come back still owns the reader,
    /// and the orphan protocol is the only thing that knows it. Both call sites
    /// are points at which that protocol has just answered; whichever runs
    /// second is the one that actually starts the loop, and the first is a
    /// no-op.
    private func resumeSupplyAfterWarmPreparation() {
        guard isReady,
              !isPreparingWarmVideoLane,
              warmPreparationTransaction.orphan == nil,
              !warmPreparationTransaction.hasPendingInterrupt else { return }
        startSupplyLoop()
        requestSupplyWake()
    }

    /// The preparation itself. Owned by exactly one `run`; every abandonment
    /// goes through `abandonWarmVideoPreparation` so no path can exit leaving
    /// the lane warm-suspended with no owner and no terminal error.
    func performWarmVideoPreparation(
        _ run: WarmVideoPreparationRunLedger.Run
    ) async -> DemandVideoLanePreparationResult {
        let token = run.token
        // The supply loop is the single demux caller. Quiesce it before moving
        // the retained GOP into the normal decode queue so a late pump cannot
        // publish background packets into foreground preparation or grow the
        // residual video store without bound.
        let previousSupplyLoop = supplyLoopTask
        cancelSupplyLoop()
        // Put the retained still image back on the passive layer before any of
        // this runs. It is what the viewer looks at for the whole preparation,
        // and every other path that renders it is either downstream of this
        // transaction SUCCEEDING or dependent on a layout edge happening to
        // fire — see `refreshPresentationImageHold`.
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
        // Deliberately NOT hoisted above the supply-loop drain with the run
        // slot. This flag gates two AUDIO producers — the relayed-packet drain
        // (`drainRelayedPackets`) and the ring refill (`fillPCMRing`) — and the
        // drain above is a cancelled-but-not-yet-stopped pump blocked on a
        // ranged read. Covering that window would suppress audio refill for its
        // duration, on the foreground path, while a ~360ms audio dropout is
        // under investigation. Single-flight does not need it: the
        // `warmPreparationTransaction.currentRun` slot alone provides the exclusion.
        isPreparingWarmVideoLane = true
        defer {
            // Key cleanup on the active run ID so finishing one run never
            // clears state owned by a successor run.
            if warmPreparationTransaction.currentRun?.id == run.id {
                isDecodingWarmVideoCandidate = false
                isCollectingWarmVideoRunUp = false
            }
            if warmVideoPreparationLedger.currentAttempt?.runID == run.id {
                warmVideoPreparationLedger.retireAttempt()
            }
        }
        // An audio decode fill may already own the shared demux pump when the
        // supply loop is cancelled. Let that structured fill finish before the
        // video-only reader mutation; later audio fills may drain retained
        // packets but cannot start another pump while this flag is set.
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

        // Any relay packets that were published by the pre-edge pump but had
        // not reached this actor yet are not part of the immutable suspend-edge
        // snapshot. Drop them after every producer has joined; otherwise a
        // delayed relay hop could arrive after resume and bypass the hold's
        // video-supply gate as if it were current foreground input.
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
            // Audio remains authoritative while VT is retired/recreated. Keep
            // the attempt-start sample for diagnostics, but do not treat it as
            // the commit target: the audio master can advance during reader,
            // decoder, or collaborator awaits.
            let startTarget = audioPresentationMediaTime
            guard startTarget.isFinite else {
                return finishWarmVideoPreparation(
                    token: token,
                    failure: .decoderPreparationExhausted
                )
            }
            let target = max(0, startTarget)

            // Reposition on DEMAND, not on principle.
            //
            // `prepareVideoContinuity` closes the active chunk stream and
            // issues ranged reads, and it is followed here by a wipe of
            // `suspendedVideoGOP` — so an unconditional reposition discards a
            // retained GOP that could have satisfied this attempt and pays for
            // network I/O to fetch it again, on the visible foreground path, on
            // a just-woken radio.
            //
            // The skip test is `retainedVideoWindowBrackets`, NOT the looser
            // `suspendedVideoCandidate(at:) != nil` one line below. Read that
            // method's comment before touching this: the loose predicate
            // accepts a window lying entirely in the future, which is the
            // COMMON shape here, and preparing against it is a black screen
            // reported as prepared.
            //
            // An ESCALATED rung repositions regardless. A rung must buy
            // something materially new or the ladder collapses into a retry
            // loop against identical inputs — and a rung that escalated because
            // the bytes themselves looked wrong needs different bytes.
            //
            // Degrades to the old behaviour exactly: an unbracketed window
            // repositions as before, so this is never worse than always
            // repositioning. How often the skip actually fires is an open
            // device question — the retained window is frozen at the read-ahead
            // frontier while audio advances toward it — which is what the
            // `gop=` field below is for.
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
                // Shared live cursor: use only the bounded current GOP. A live
                // seek or whole-demux reposition remains forbidden.
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
                        // The renewed rung is a transient direct stream. It
                        // must install decoder 2 before consuming the newly
                        // positioned reader; the retained 8 s GOP remains a
                        // separate memory policy and is not used as a run-up
                        // accumulator here.
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
                    // The video reader now starts at a keyframe-safe local
                    // anchor. Pump it alone; audio/source/session are untouched.
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
                // A target-side sync packet is not compressed pre-roll. Do not
                // let the loose tail-reaches-target candidate predicate turn a
                // forward-only sample window into a prepared lane. Spend the
                // one local renewal before creating any decoder; the renewed
                // rung must still prove an earlier, distinct dependency input.
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
            // Ordinary audio-only suspension uses a fresh VideoToolbox session
            // first because the signed device evidence shows that retained VT
            // sessions commonly return `kVTInvalidSessionErr` after a
            // background edge. A paused PiP-stop transaction is different: its
            // first explicit Play must test the retained decoder and spend one
            // fresh local replacement only when that transaction actually
            // reports a decoder fault. This preserves a healthy paused lane's
            // identity and gives the physical invalid-session case exactly one
            // bounded local repair.
            let triesRetainedPausedPiPDecoder = token.reason == .pipDidStop
                && !token.resumesPlayback
                && repairIndex == 0
                && suspendedVideoFault == nil
            let usedFreshDecoder = triesRetainedPausedPiPDecoder
                ? false
                : installFreshVideoDecoder(retiringCurrent: true, warmPreparationAttempt: attempt)
            if !usedFreshDecoder {
                guard triesRetainedPausedPiPDecoder || repairIndex == 0 else {
                    // An escalated rung must bring a new decoder identity or it
                    // is a retry against identical inputs.
                    retireCurrentVideoDecoderWithoutWaiting()
                    return finishWarmVideoPreparation(
                        token: token,
                        failure: .decoderPreparationExhausted
                    )
                }
                // No factory, a factory that handed back the identity already
                // held, or the intentional paused-PiP first rung. Flush the
                // retained session and decode the candidate GOP through it.
                // The paused-PiP rung is the only path where this is preferred
                // before a decoder fault proves replacement necessary.
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
            // Delay creation of a near-future image hold until the moving
            // target has been revalidated below. A candidate can become due
            // while decoder setup is suspended; that case is ordinary current
            // floor preparation, not a future hold.
            activeWarmVideoImageHold = nil
            // W6: the candidate can exceed the foreground queue high-water —
            // the retained window spans one GOP behind the clock plus the
            // full high-water ahead of it. Route the tail into the residual
            // store (the existing moof-overflow "never drop" path, drained as
            // decode frees room) instead of silently truncating it: resume
            // clears the retained window, so a truncated tail would leave an
            // unfillable hole between the queue end and the demux read cursor.
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
                // A malformed decoder may emit frames whose PTS never becomes
                // distinct. Once those frames fill the bounded pending queue,
                // the decode burst correctly applies back-pressure and consumes
                // nothing. Without this progress fence the outer preparation
                // loop spins synchronously on MainActor forever. Treat the
                // bounded no-progress exit like other insufficient-output
                // cases so the one strict earlier-authority rung gets its turn.
                //
                // Queue depth alone is not progress: with the W6 candidate
                // overflow routed into the residual store, a burst can consume
                // the queued prefix while `drainResidualPackets()` refills it
                // to the same count. Residual movement and actual submissions
                // count as progress here exactly as they do in the
                // moving-target continuation's fence.
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

    /// Complete candidate identity travels with its proof. A rescue replaces
    /// this entire value; no old receipt/authority can leak into a new hold.
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

    /// Ordinary and decoder-2 input converge here before any prepared result.
    /// All future hold/proof publication uses this same current candidate.
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

    /// The primary is the only rescue executor. Closing admission precedes the
    /// exact scheduled producer join; timeout can settle publicly but never
    /// starts a competing reader/decoder operation while that join is parked.
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
        /// Attempt 1 selected a retained near-future image hold, but its
        /// tail expired while the same reader made no further progress. This
        /// is the one bounded edge that may hand control back to the existing
        /// strict video-only positioning path; other moving-target budget
        /// exhaustion remains terminal.
        case tailExpired
        case exhausted
        case cancelled
    }

    /// Keep one warm preparation attempt alive while the audio-master target
    /// moves. This continuation deliberately uses the already selected reader
    /// and decoder: stale target-side output is discarded at the monotonic
    /// floor, then the same decoder consumes further packets until a current
    /// pending frame exists. It is not a second recovery rung or positioning
    /// transaction.
    /// Name the bound that ended a moving-target chase.
    ///
    /// Three of the four caps returned `.exhausted` in silence, so a chase that
    /// ran out of BUDGET was indistinguishable in a capture from one that ran
    /// out of TIME — only the wall limit printed anything. The distinction
    /// matters at 4K, where the arithmetic says the byte cap is the one that
    /// will fire: a 12.1 MB candidate against the 16 MiB budget leaves ~4.6 MB,
    /// under 2 s of this content, while the next fragment is another ~12 MB.
    /// Report-only; every cap keeps its current value.
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
              // The initial candidate comes from the retained window, whose
              // budget is the W6 window cap; the incremental chase budget
              // below keeps its own, tighter 16-MiB accounting.
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

        // Report-only readBytes accounting across all ingest paths feeding this
        // run, rate-limited to the first hit plus one closing summary.
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
                // Once the audio master has reached the future anchor, this is
                // no longer a future hold. Keep the candidate's decoder output
                // on the ordinary current-floor proof path.
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
                    // Continue from the reader selected by this attempt. A
                    // moving target must never call prepareVideoContinuity or
                    // prepareEarlierVideoContinuity again.
                    resetCachedRunway(video: true, audio: false)
                    // A fetched future candidate is receipt-scoped. Once
                    // its acknowledged input is exhausted, do not silently
                    // switch it to ordinary relay input under that receipt.
                    // The existing bounded failure/repair policy owns this
                    // result; W5b adds no reposition loop or decoder rung.
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
        (videoPackets + residualVideoPackets)
            .filter { $0.pts.isFinite && $0.duration.isFinite && $0.duration > 0 }
            .map { $0.pts + $0.duration }
            .filter(\.isFinite)
            .max()
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

    /// Only direct batches bearing the installed mutation receipt can create
    /// forward provenance. Ordinary relay/post-suspend packets cannot borrow it.
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
        // Future output is a presentation boundary. DTS may legitimately
        // precede it on reordered video; the actual sync-rooted first packet
        // and moof PTS proof, rather than a PTS==DTS assumption, authorize it.
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

    /// The one renewed earlier-authority rung. Unlike ordinary warm
    /// preparation, this path never materializes its root-to-target run-up in
    /// `suspendedVideoGOP`: decoder 2 owns the positioned packets directly and
    /// the session keeps only the minimum target-side decoded frames needed by
    /// the normal resume/proof path.
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
        // The preceding ordinary producer has been joined by the caller. A
        // direct batch must begin with an empty relay so packets cannot be
        // consumed once through the direct path and again by a delayed
        // ordinary drain.
        packetRelay.reset()
        // Reserve/install decoder 2 before the first direct packet is pulled.
        // `installFreshVideoDecoder` transfers authority synchronously and
        // queues decoder 1 retirement off-main; no native close is awaited here.
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
        // Keep only bounded authority/progress state. The session's packet
        // queue owns the direct compressed input while it is being decoded;
        // retaining a second root-to-target `[MediaPacket]` array here would
        // duplicate the potentially multi-megabyte transient run-up.
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
                    // A direct batch's measured source-byte charge must cover
                    // every compressed access unit it returns. Otherwise a
                    // faulty demux can hand the collector an uncharged packet
                    // array that grows beyond the 16 MiB transaction budget.
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
                    // A small test HWM can park the tail of a whole fragment.
                    // Drain the accepted prefix before looking for target-side
                    // output; the next direct batch remains the only source of
                    // additional compressed input.
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

                // Decode in demux order. Every await is followed by the exact
                // run/token/session/engine/decoder fence before its output can
                // participate in readiness.
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
                    // The original direct phase closes only after fixed-target
                    // coverage inside its 5s cap. Shared live-floor convergence
                    // then uses the same run remainder, carrying actual charges.
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

    /// Does the already-prepared video lane still cover the LIVE audio
    /// position?
    ///
    /// Audio is the sole clock writer, so preparation that completed while the
    /// application was inactive was anchored to an earlier position.
    ///
    /// **Diagnostic only — nothing branches on this.** See the call site for
    /// why acting on it was implemented and reverted.
    ///
    /// Fail-SAFE toward `true`: without a computable upper bound the honest
    /// answer is "unknown", and reporting "stale" there would overstate the
    /// problem. Note the upper bound is governed by where the `videoBudget: 1`
    /// pump in the preparation loop happened to stop, not by anything the
    /// preparation guarantees — so a `covers=0` reading is evidence to
    /// investigate, not proof that the frame on screen was wrong.
    private func preparedVideoLaneCoversCurrentAudio() -> Bool {
        let target = audioPresentationMediaTime
        guard target.isFinite else { return true }
        // The prepared GOP begins at the floor its attempt reset. A target
        // BELOW that would present a forward jump.
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

    /// The single typed exit for abandoning a run.
    ///
    /// `.cancelled` is correct ONLY when something newer genuinely owns the
    /// lane — a newer run, a newer suspension, a newer session/engine
    /// generation, or a cancelled task — because that owner drives recovery.
    ///
    /// **Honesty about the second branch.** Today it is a backstop that should
    /// never fire: every caller's guard re-evaluates predicates this function
    /// re-checks synchronously with no suspension between, so the two always
    /// agree and every current site resolves to `.cancelled`. Invariant I3 —
    /// never park in `warmSuspended` with no owner — is actually established
    /// by the single-flight join and the entry guards, NOT here. This function
    /// exists to keep that reasoning in one place and to fail loudly rather
    /// than silently if a future caller abandons without a successor, which is
    /// exactly the shape of the permanent-black dead end. Do not delete it and
    /// do not describe it as the thing providing the guarantee.
    private func abandonWarmVideoPreparation(
        _ run: WarmVideoPreparationRun
    ) -> DemandVideoLanePreparationResult {
        // A nil slot means `resetVideoContinuationState` released ownership out
        // from under this run, so it is superseded. Reading nil as "still mine"
        // was safe only because that same reset also nils the token; keying the
        // answer on that coincidence is how this becomes a spurious
        // "Tap Retry" the first time something releases the run alone.
        let supersededByRun = warmPreparationTransaction.currentRun.map { $0.id != run.id } ?? true
        let supersededBySuspension = activeVideoSuspendToken != run.token
        let supersededBySession = runtimeGeneration != run.sessionGeneration
            || generation != run.engineGeneration
        let supersededByOwner = activeOwnerGeneration != run.ownerGeneration
        // Task cancellation belongs in this set, and not only for tidiness.
        // `demandContinuationEffectTask` is replaced without being cancelled,
        // so the only thing that cancels it is `stop()` — and a stop tears the
        // session down, which is itself the owner. Listing it here also makes
        // the guarantee below STRUCTURAL rather than accidental:
        // `finishWarmVideoPreparation` starts with `guard !Task.isCancelled`
        // and would otherwise quietly hand back the very `.cancelled` this
        // function exists to avoid.
        let cancelled = Task.isCancelled
        if supersededByRun || supersededBySuspension || supersededBySession
            || supersededByOwner || cancelled {
            return .cancelled
        }
        // Past this point the guard inside `finishWarmVideoPreparation` cannot
        // fail: the token matches, the generation matches, and the task is
        // live. The typed failure is therefore guaranteed, not hoped for.
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
            // The rung's RUN must still own the lane. Without this a rung
            // could commit into a lane a newer run has taken over.
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
        // Resume owns the latest audio-master floor. Never lower it back to the
        // attempt-start target, and never submit a pending frame whose PTS is
        // already behind this timebase.
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
            // Audio can advance between preparation commit and the real
            // foreground surface resume. Continue from the same reader and
            // decoder, keeping the passive image visible while stale pending
            // frames are removed and fresh target-side output is decoded.
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
                // This continuation runs after preparation has already handed
                // the lane to resume and has no run/attempt owner through
                // which to spend the existing renewed rung. Do not invent an
                // inline decoder swap or a second positioning transaction;
                // the established typed resume-failure caller owns this edge.
                return false
            case .tailExpired:
                guard strictRefreshes == 0 else { return false }
                strictRefreshes += 1
                // Keep the suspend token and retained GOP alive; the existing
                // preparation owner owns strict positioning. Clear only the
                // prepared/hold attempt state below, avoiding an inline
                // decoder swap and giving the one-refresh fence one owner.
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
                // The lane remains warm-suspended; the caller surfaces the
                // existing typed failure after this bounded local continuation
                // exhausts its wall/byte/content/no-progress authority.
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
            // PiP is the current presentation destination, so the passive
            // inline hold must not keep the video-supply gate closed forever.
            activeWarmVideoImageHold = nil
        }
        isVideoLaneWarmSuspended = false
        clearDisplayOutputContinuity()
        // Cached video was not counted while suspended, and the preparation
        // may have repositioned the reader under it: the next fill re-measures.
        resetCachedRunway(video: true, audio: false)
        suspendedVideoSupplyMemorySuppressed = false
        isVideoLanePreparedForForeground = false
        // A near-future hold keeps the same suspended-lane token alive until
        // proof or a strict refresh. Without this, a post-resume stale-tail
        // observation would have no authority through which to reposition.
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
            // Do not hide a real renderer fault behind the restore call. The
            // ViewModel maps a false result to rendererHealthChanged, allowing
            // the existing coordinator-owned flush/recreate ladder to run.
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
            // Warm preparation already owns the same install-before-retire
            // boundary. Let it perform the one local replacement rather than
            // taking over once here and then replacing the successor again.
            isVideoLanePreparedForForeground = false
            return await prepareVideoLaneForForeground(token) == .prepared
        }
        // Transfer decoder authority before retiring the old object. The old
        // VideoToolbox session may block inside native invalidation; waiting on
        // `close()` here would freeze this MainActor and strand presentation
        // recovery. A factory-created successor is opened while the detached
        // retirement owns the old decoder.
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
            // The old decode task may have been suspended in a decoder callback.
            // Its identity is no longer current, so it cannot publish output or
            // faults while this bounded wait lets the task release its resources.
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

    /// Toggle only the optional PiP presentation/binding capability. This does
    /// not replace the renderer, reopen media, or advance media generation.
    func setAutomaticPiPEnabled(_ enabled: Bool) {
        if isAutomaticPiPEnabled == enabled {
            // A stopped cached session retains its desired capability while
            // its binding is cleared. Reactivation may restore that one
            // presentation binding before the next open.
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

    /// Install the current Demand mode/source/lifecycle gates. The session
    /// keeps the value and the pure detector consumes a snapshot only when an
    /// existing one-second pipe window completes.
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
            // Native PiP can win the race while a local video-lane suspension
            // is already active. The lease is now the presentation authority,
            // so resume locally without waiting for didBecomeActive; waiting
            // for activation would leave PiP frozen during that interval.
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

    /// Start at most one warm-lane resume for an already-observed PiP lease.
    /// This is deliberately session-local: the native lease callback is the
    /// earliest reliable edge, and routing the operation through the
    /// foreground coordinator would suspend video until unlock.
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

    /// Await the lease-driven resume when activation reconciliation reaches a
    /// warm-suspended lane first. The same task is shared with the native lease
    /// callback, so the foreground edge cannot create a second preparation.
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
                // A callback from a previous controller/source binding is stale.
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
            // Stop while the current handler can observe the explicit false,
            // then remove the controller identity before UIKit can deliver a
            // late callback from this generation.
            pipSource.stopPiP()
            // Capability/source teardown is a forced retirement, not an
            // ordinary handoff: invalidate lease authority now and reject the
            // controller's later didStop through the binding token below.
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
        // A direct PiP callback is an external user-intent request. Publish
        // that origin before the session emits its synchronous playing/paused
        // state event, so the App can update intent without calling transport
        // a second time. The state event remains the settlement publication
        // boundary.
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
            // Demand live has an open-ended, non-seekable timeline. Complete
            // the AVKit request without moving the clock; this is a truthful
            // no-op rather than a fabricated seek success.
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
                // Publish actual post-seek time before AVKit completion; the
                // backend worker already owns latest serial/epoch admission.
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

    /// Forward the handoff-only mask to the renderer that owns the actual
    /// AVSampleBufferDisplayLayer. Keeping this at the session boundary makes
    /// the source-layer update part of the same Demand presentation contract
    /// as the render-generation fence; no ViewModel code reaches into UIKit.
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
            return AudioRendererPull(frames: 0, contentSeconds: 0, displaySpans: [])
        }
        let pull = audioTimelineBuffer.pullContent(
            frameCount: frameCount,
            sampleRate: sampleRate,
            channels: channels,
            into: buffer
        )
        // Direct reserve/seek fills retain this PCM in the same real ring as
        // the feeder. Their caller must transfer these spans before releasing
        // this pull; only a genuinely immediate sink discards them on return.
        let framesWritten = pull.frames

        let contentSeconds = TimeInterval(framesWritten) / sampleRate
        noteAudioSupplyPull(requested: frameCount, written: framesWritten)
        return AudioRendererPull(
            frames: framesWritten, contentSeconds: contentSeconds, displaySpans: pull.displaySpans
        )
    }

    /// The consequences of having handed PCM to a renderer, from either supply
    /// entry point: this MainActor `pullPCM` (the seek/start transaction paths) or
    /// the off-MainActor ring feeder's report.
    ///
    /// **SUPPLY ONLY.** Handing PCM to a renderer is not evidence that it was
    /// heard, so this path must never touch F1 — `mediaTime` advances only in
    /// `renderedContentDidAdvance`. Keep DECODE fed so PCM keeps flowing; packet
    /// supply is the self-paced supply loop, not this tick.
    ///
    /// One body for both entry points on purpose. Two copies of decode scheduling
    /// and buffering-state transitions, differing only in who called them, is how
    /// a feeder-fed build and a transaction-fed build drift apart.
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

    /// The eventually-consistent half of `pullPCM`, reported by the audio ring
    /// feeder on MainActor's own drain tick.
    ///
    /// Lateness here is tolerable — and only here — because there are
    /// `audioPCMTargetSeconds` of decoded PCM banked behind it. That reservoir is
    /// exactly what the ownership move buys: audio's tolerance to MainActor
    /// lateness rises from the ring's 0.25 s reserve to the bank, because the
    /// feeder keeps running while this report waits.
    func audioSupplyDidReport(_ report: AudioFeederPullReport) {
        guard report.passes > 0 else { return }
        noteAudioSupplyPull(
            requested: report.requestedFrames,
            written: report.writtenFrames
        )
    }

    /// Single F1 advance path: called by the audio renderer with rendered content
    /// drained since the previous report so `mediaTime` tracks audio output directly.
    func renderedContentDidAdvance(
        bySeconds seconds: TimeInterval, displayObservation: AudioRenderedDisplayObservation?
    ) {
        guard !isSeekInFlight else {
            audioDisplayObservation.invalidate()
            return
        }
        guard isPlaying, !videoStarvationHoldIsActive(), seconds > 0 else {
            return
        }
        let sessionSpan = UIHitchMonitor.beginSpan("tick.sess")
        defer { UIHitchMonitor.endSpan(sessionSpan) }
        audioDisplayObservation.accept(seconds.isFinite ? displayObservation : nil)
        noteFlowStage(&flowClock, "clock")
        clock.advanceContent(by: seconds)
        if clock.duration > 0, clock.mediaTime >= clock.duration {
            // The scalar clock clamps at duration; an unclamped ring endpoint
            // no longer represents that accepted position.
            audioDisplayObservation.invalidate()
        }
        if seconds.isFinite, clock.mediaTime.isFinite, audioRender.outputAvailability == .available {
            renderedAudioOutput = RenderedAudioOutput(
                sessionGeneration: runtimeGeneration, ownerGeneration: activeOwnerGeneration, position: clock.mediaTime
            )
        }
        if !isVideoLaneWarmSuspended {
            let presentSpan = UIHitchMonitor.beginSpan("tick.present")
            presentDueVideoFrames()
            UIHitchMonitor.endSpan(presentSpan)
            // Immediately after the present attempt, and on the one path that keeps
            // running while video is dry: if there was nothing to present and
            // nothing queued, the clock must stop here rather than run on past the
            // picture (F4). Audio-only continuation intentionally owns no inline
            // video consumer, so it is excluded from that starvation hold.
            let starveSpan = UIHitchMonitor.beginSpan("tick.starve")
            evaluateVideoStarvation()
            UIHitchMonitor.endSpan(starveSpan)
            let resyncSpan = UIHitchMonitor.beginSpan("tick.resync")
            maybeResyncDisplaySlave()
            UIHitchMonitor.endSpan(resyncSpan)
        } else {
            // The clock can cross retained sync samples while the producer is
            // parked (or at EOF). Keep its bracketing root current even when
            // no new keyframe arrives, without mutating a preparation's input.
            if !isPreparingWarmVideoLane, !isVideoLanePreparedForForeground {
                trimSuspendedVideoWindowBehindClock(audioPresentationMediaTime)
            }
            // The gated wake owns the per-track low-water and hold gates.
            // A fixed 1-second gate here delayed an 8-second window's refill
            // until only half a second remained.
            wakeSupplyLoopIfDrained()
        }
        onEvent?(.tick(
            mediaTime: clock.mediaTime,
            duration: clock.duration,
            buffered: bufferedTime
        ))
        notifyMultiConnectionPlaybackProgressIfNeeded()
        // Drain clock: mediaTime + present + decode kick only. Packet supply is
        // `runSupplyLoop` (not armed from the audio path).
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
            // The ring may have just emptied on this very tick's delta; do not
            // wait for the feeder's next underrun report to notice.
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
                // Audio recovering does not release a VIDEO hold. Only the
                // owner that entered buffering may leave it — otherwise a
                // healthy soundtrack resumes playback into a still-empty video
                // queue and the freeze → overdue-burst cycle restarts (F4).
                guard !videoStarvationHoldIsActive() else { return }
                isBuffering = false
                // Resume display slave only after underrun clears (no silent free-run).
                applyPipelineDemand()
                armPresentFeedIfNeeded()
                presentDueVideoFrames()
                onEvent?(.playing)
            }
            return
        }
        if audioSupplyExhausted() {
            // Supply is exhausted but the renderer's ring may still hold up to
            // its reserve of unplayed audio (the feeder requests ring *room*,
            // not ring *content*). Drain it out rather than ending here —
            // ending now truncated the last ~0.25s x rate of every video.
            beginAudioDrainToEnd()
            return
        }
        if !isBuffering {
            isBuffering = true
            disarmPresentFeed()
            applyPipelineDemand()
            onEvent?(.buffering)
        }
        // Underrun = starved ring; force-wake the supply loop (it will refill the
        // packet queue if network allows) and drain packets into the PCM ring.
        requestSupplyWake()
        scheduleAudioDecodeIfNeeded()
    }

    private func audioSupplyExhausted() -> Bool {
        demuxReachedEOF
            && audioPackets.isEmpty
            && pendingAudioContentSeconds < 0.000_5
            // Packets are dequeued before `await audioDecoder.decode`, so an
            // in-flight decode can still deliver PCM after the queue reads empty.
            && audioDecodeTask == nil
            && audioDecodeLaneOwners == 0
            && activeAudioDecodeOperationID == nil
    }

    /// Enter the draining state (idempotent): not buffering (video keeps
    /// presenting, the clock keeps advancing from drained audio), not yet
    /// ended. Called from every "supply exhausted" tick — both the feeder's
    /// own underrun report (`handlePullOutcome`) and `renderedContentDidAdvance`
    /// keep calling this as long as supply stays exhausted, which is what lets
    /// `maybeFinishAudioDrain` make progress after the ring itself empties and
    /// no further drain delta is reported.
    private func beginAudioDrainToEnd() {
        if !audioDrainingToEnd {
            audioDrainingToEnd = true
            diagnostics.log(
                "[PathA] audio EOF draining ring pending=\(audioRender.hasPendingOutput)"
            )
        }
        // Draining is not starvation: an underrun entered while the final
        // packet was still decoding must not keep video frozen through the
        // tail. Same exit, and same video-hold precedence, as the recovery
        // branch in `handlePullOutcome`.
        if isBuffering, !videoStarvationHoldIsActive() {
            isBuffering = false
            applyPipelineDemand()
            armPresentFeedIfNeeded()
            presentDueVideoFrames()
            onEvent?(.playing)
        }
        maybeFinishAudioDrain()
    }

    /// Adjudicates the actual end of a draining session: `.ended` fires only
    /// once the renderer has nothing left pending AND the output latency past
    /// that point has elapsed (the audio may still be in the output pipeline,
    /// not yet actually heard).
    private func maybeFinishAudioDrain() {
        guard audioDrainingToEnd else { return }
        if let deadline = audioDrainPlayoutDeadline {
            guard ContinuousClock.now >= deadline else { return }
            finishAudioDrain()
            return
        }
        guard !audioRender.hasPendingOutput else { return }
        let now = ContinuousClock.now
        // `.logical`/`.unavailable` already carry `wallLatencySeconds == 0`;
        // only `.outputPipeline`/`.processingOnly` report a real estimate.
        let latency = max(0, audioRender.presentationTiming.wallLatencySeconds)
        audioDrainEmptiedAt = now
        audioDrainPlayoutDeadline = now.advanced(by: .seconds(latency))
        guard latency > 0 else {
            finishAudioDrain()
            return
        }
    }

    /// Logs the measured playout time, then settles through the existing
    /// `emitEndedIfNeeded` terminal path.
    private func finishAudioDrain() {
        if let emptiedAt = audioDrainEmptiedAt, let deadline = audioDrainPlayoutDeadline {
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
        audioDrainingToEnd = false
        audioDrainEmptiedAt = nil
        audioDrainPlayoutDeadline = nil
        audioRender.stop()
        cancelSupplyLoop()
        cancelDecode()
        disarmPresentFeed()
        if clock.duration > 0, clock.mediaTime < clock.duration {
            audioDisplayObservation.invalidate()
            clock.seek(to: clock.duration)
        }
        updatePiPPlaybackState()
        // Freeze display at final media pin (ended policy may advance mediaTime).
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
            // Room-based, the same shape as the foreground/audio clauses:
            // the low-water hysteresis lives on the wake side
            // (`supplyBelowLowWater`). Gating the FILL on low-water would
            // stall every refill at half the target now that the split-track
            // target is the full high-water. The image-hold gate keeps the
            // zero-fetch-until-proof contract of a near-future hold.
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
        // Residual moof tail must drain into the main queue before more pumping.
        if !residualVideoPackets.isEmpty || !residualAudioPackets.isEmpty {
            if !residualAudioPackets.isEmpty { return true }
            if !warmVideoImageHoldWithholdsVideoSupply { return true }
        }
        if warmVideoImageHoldWithholdsVideoSupply {
            // The retained candidate already owns every compressed byte needed
            // to reach proof. Until that proof arrives, split-video range I/O
            // would turn the scoped zero-fetch proof into a diagnostic fiction.
            // Audio remains independently refillable below.
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
    //
    // Keeps packet queues topped on its own hysteresis cadence (fill to high-water,
    // park until a track drops below low-water), decoupled from audio clock ticks.

    /// Start (or nudge) the continuous supply loop. Called on `play` / seek-resume.
    private func startSupplyLoop() {
        // `terminalVideoPreparationFailure` is video-lane-only and must not stop
        // audio packet supply; `isPreparingWarmVideoLane` does gate this loop
        // because warm preparation exclusively owns the demux reader while active.
        guard isReady,
              !isPreparingWarmVideoLane else { return }
        if supplyLoopTask != nil {
            // Already running — nudge in case queues drained while we were arming.
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

    /// Continuous producer: keep `videoPacketQueue` / `audioPacketQueue` at
    /// high-water, PARK (not spin) when full, and refill when a decode drain drops
    /// either track below low-water. Never triggered by the audio clock.
    private func runSupplyLoop(generation gen: Int) async {
        while isCurrentGeneration(gen) {
            if Task.isCancelled { return }
            // Reader ownership only — see `startSupplyLoop` for why a video
            // verdict is not a reason to stop supplying audio.
            if isPreparingWarmVideoLane {
                return
            }
            if needsPacketFill() {
                try? await fillQueuesToHighWater(generation: gen, initiator: .supplyLoop, phase: .playback)
                pipeWindowPumps += 1
                guard isCurrentGeneration(gen), !Task.isCancelled else { return }
                // Let decode self-drive from freshly supplied packets even when the
                // audio tick is sparse (decode still gates on its own frameQueue
                // watermark, so this is a kick, not a per-frame chain).
                if isPlaying {
                    scheduleVideoDecodeIfNeeded()
                    scheduleAudioDecodeIfNeeded()
                }
                // Retry only while a pump could actually make progress and we
                // are not at EOF (network-starved pump → brief backoff).
                // Residual-only pressure PARKS instead: it drains on decode
                // wakes (supplyBelowLowWater treats residual as a wake), and
                // spinning on it at the 20ms backoff was the capture's
                // pumps=40–71/s with parks=0.
                if canPumpNow(), !demuxReachedEOF, lastFillProducedPackets {
                    if supplyLoopWakePending {
                        supplyLoopWakePending = false
                    } else {
                        try? await Task.sleep(nanoseconds: supplyStallBackoffNanos)
                    }
                    continue
                }
            }
            // At high-water (or EOF): suspend until a real drain / lifecycle wake.
            await parkSupplyLoop()
        }
    }

    /// Park until `requestSupplyWake()` fires (a track drained below low-water) or
    /// lifecycle bumps the generation / cancels. `@MainActor` serial execution makes
    /// the pending-flag ↔ continuation handoff race-free (no missed wakeups).
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

    /// Resume a parked supply loop, or remember the wake if it is mid-fill.
    private func requestSupplyWake() {
        guard supplyLoopTask != nil else { return }
        if let continuation = supplyLoopWake {
            supplyLoopWake = nil
            continuation.resume()
        } else {
            supplyLoopWakePending = true
        }
    }

    /// Wake the supply loop only when a decode drain actually dropped a track below
    /// its low-water — the low side of the watermark hysteresis.
    private func wakeSupplyLoopIfDrained() {
        guard supplyLoopTask != nil, supplyBelowLowWater() else { return }
        pipeWindowWakes += 1
        requestSupplyWake()
    }

    /// A track is below low-water = `supplyLowWaterFraction` × its (effective,
    /// memory-aware) high-water. Pass-through BGRA video keeps its tighter
    /// memory-bounded HWM and its accept-slot gate (bounded memory unchanged).
    private func supplyBelowLowWater() -> Bool {
        // Residual drains synchronously before wake checks in decode bursts;
        // only low-water crossings (or explicit audio underrun wakes) trigger new pumps.
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

    /// A pump could make progress right now: at least one track has real queue
    /// room AND no parked residual of its own. Residual-only pressure is NOT
    /// pumpable — it drains on decode wakes. Spinning the supply loop on it at
    /// the stall backoff was the capture's pumps=40–71/s with parks=0.
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
        // Resume a parked loop so it observes cancellation / generation bump and exits.
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

    /// Cancel a video operation and invalidate its identity. Warm suspension
    /// deliberately keeps the cancelled handle until foreground preparation
    /// joins it, so an in-flight decoder call cannot be closed/replaced under
    /// that preparation. Ordinary pause/stop clears the handle immediately.
    private func cancelVideoDecode(clearHandle: Bool) {
        activeVideoDecodeOperationID = nil
        decodeTask?.cancel()
        if clearHandle {
            decodeTask = nil
        }
    }

    private func cancelAudioDecode(clearHandle: Bool) {
        if let operationID = activeAudioDecodeOperationID {
            let pending = pendingAudioDisplaySupport.values.filter { $0.operationID == operationID }
            for entry in pending { retirePendingAudioDisplaySupport(entry.support) }
        }
        activeAudioDecodeOperationID = nil
        audioDecodeTask?.cancel()
        if clearHandle {
            audioDecodeTask = nil
        }
    }

    /// Fence a hold-refresh task before dropping the hold's authority. The
    /// task's generation/token guards remain the final late-result fence, but
    /// cancellation keeps a superseded local transaction from consuming work
    /// after pause, seek, owner replacement, or teardown.
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
        // The relay holds packets for the timeline being flushed. Its own
        // contract requires this to run AFTER the demux-side fence for the same
        // event — `seek`/`open` bump `readerMutationGeneration`, which makes
        // `commitStreamedProgress` refuse, so no further publish can follow.
        packetRelay.reset()
        resetCachedRunway()
        videoStarvedSince = nil
        bufferingForVideoStarvation = false
    }

    /// Invalidate lifetime ownership before installing a successor token.
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

    /// W6: a warm-suspended split/indexed lane keeps the SAME supply target
    /// the foreground packet queue has — the window tail tracks
    /// audio clock + high-water, so a foreground return finds the buffer
    /// already covering the clock and decodes from it without repositioning.
    /// Muxed live keeps its bounded current-GOP target (shared cursor, no
    /// video-only repositioning exists there).
    private var suspendedVideoSupplyTarget: TimeInterval {
        guard !suspendedVideoSupplyMemorySuppressed else { return 0 }
        switch videoContinuityTopology {
        case .muxedCurrentGOP:
            return Self.suspendedVideoTargetAheadSeconds
        case .splitTrack, .localFileIndex:
            // Preparation has already transferred its candidate into the
            // decode queue/residual. Do not fetch a second suspended suffix
            // that resume would discard. A tracked strict hold refresh also
            // owns the next video input before its async task begins.
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
        // A pump admitted before the warning may still return or publish via
        // the relay. Shed those late background bytes too. Foreground-owned
        // positioned run-up remains allowed to rebuild the missing window.
        guard packet.track == .video,
              !suspendedVideoSupplyMemorySuppressed
            || isCollectingWarmVideoRunUp else { return }
        let packet = normalizingZeroDuration(packet)
        if suspendedVideoGOP.isEmpty, !packet.isKeyframe {
            // A suffix without its keyframe cannot recreate VT safely.
            return
        }
        if suspendedVideoGOPProvenance == nil {
            suspendedVideoGOPProvenance = provenance
        } else if suspendedVideoGOPProvenance != provenance {
            // A packet that completes after the suspend edge is deliberately
            // enough to taint the candidate. It may remain useful for the
            // strict positioning path, but it can no longer authorize the
            // retained-memory near-future hold.
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
            // A positioned run-up is rooted at its decode anchor, not at the
            // audio clock: no horizon trim applies, and the legacy
            // whole-window clear stays the fail-safe while the attempt owns
            // this storage.
            if suspendedVideoGOPContentSeconds > Self.suspendedVideoGOPMaxContentSeconds
                || suspendedVideoGOPBytes > Self.suspendedVideoGOPMaxBytes {
                // Preserve bounded memory and wait for the next keyframe
                // instead of retaining an undecodable suffix or falling back
                // to a source reopen.
                suspendedVideoGOP = []
                suspendedVideoGOPContentSeconds = 0
                suspendedVideoGOPBytes = 0
                suspendedVideoGOPProvenance = nil
            }
            return
        }
        // W6: a new keyframe no longer resets the window. Once a LATER
        // keyframe sits at or behind the audio clock, the older GOP can never
        // be the decode anchor a foreground return needs, so the front is
        // trimmed instead — the head tracks the last keyframe ≤ clock.
        if packet.isKeyframe {
            trimSuspendedVideoWindowBehindClock(audioPresentationMediaTime)
        }
        enforceSuspendedVideoWindowCaps()
    }

    /// Index of the window's SECOND keyframe, if any. The window is always
    /// keyframe-rooted (a keyless suffix is refused at ingest), so index 0 is
    /// the first.
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

    /// Drop every GOP that ends at or behind the audio clock: while a second
    /// keyframe exists and its PTS is already ≤ the horizon, the leading GOP
    /// is dead weight for any future resume.
    private func trimSuspendedVideoWindowBehindClock(_ horizon: TimeInterval) {
        guard horizon.isFinite else { return }
        while let second = suspendedVideoWindowSecondKeyframeIndex(),
              suspendedVideoGOP[second].pts <= horizon {
            dropSuspendedVideoWindowPrefix(before: second)
        }
    }

    /// The supply target (window tail = audio clock + high-water) is the
    /// operative bound; these caps are the safety envelope. Shed the OLDEST
    /// GOPs first — the fresh tail is what a foreground return decodes from.
    /// A single GOP that alone exceeds the budget keeps the legacy fail-safe:
    /// clear and wait for the next keyframe.
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

    /// W6/D6: memory pressure sheds the compressed suspended video window —
    /// the only large, rebuildable background allocation this session holds
    /// (audio packets/PCM are seconds-scale; the still-image hold is one
    /// CVPixelBuffer). Supply is suppressed for the rest of this suspension
    /// cycle, so the foreground return takes the ordinary repositioning
    /// path instead of decoding from the window. A no-op when the lane is
    /// not warm-suspended: foreground pressure is handled elsewhere (parked
    /// session eviction, queue high-water).
    func discardSuspendedVideoWindowForMemoryPressure() {
        guard isVideoLaneWarmSuspended else { return }
        // Only independent readers can rebuild this cache on foreground
        // return. The muxed live cursor must retain its sole decode root.
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

    /// Exact, bounded decoder-input comparison used only before the second
    /// decoder rung. Timing metadata is deliberately excluded: VideoToolbox
    /// still receives the same compressed dependency bytes when an identical
    /// access-unit sequence is restamped at another PTS. A timestamp change is
    /// not the renewed compressed authority required after `badData`.
    /// Diagnostics expose metadata, never this payload comparison or a digest.
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

    /// Does the retained keyframe window BRACKET the target — keyframe at or
    /// before it, tail at or after it?
    ///
    /// Deliberately stricter than `suspendedVideoCandidate(at:)`, which asks
    /// only whether the tail REACHES the target. That is sufficient where it is
    /// used, because the window there was just re-pumped from a keyframe anchor
    /// at or below the target. It is NOT sufficient as a reposition-skip test:
    /// W6 can supply split-track video up to the foreground high-water, but an
    /// already-ahead runway (or the explicit hold gate) can still leave the
    /// retained window ahead of the live audio position. The loose predicate
    /// accepts such a window, and preparing against it decodes frames the video
    /// slave cannot release until audio catches up: a black screen, reported as
    /// prepared.
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

    /// Classify an attempt-1 candidate before any reader positioning or decoder
    /// creation. The near-future mode is intentionally narrow: split-track,
    /// already-retained, positively sync-rooted, bounded by the retained
    /// window's budgets, and with at least two distinct finite source PTS
    /// values.
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

    /// While this typed authority exists the split-video reader must not pump.
    /// The hold ends at presentation proof, not when its first frame merely
    /// becomes due; otherwise the supply loop can start foreground range I/O
    /// in the one-frame interval before proof and falsify the zero-fetch row.
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

    /// Classify whether candidate frames may be submitted on this due boundary.
    /// A stale authority or a clock that has already crossed the candidate tail
    /// fails closed: no stale frames or false proof; the same lane then enters
    /// the existing strict video-only refresh path.
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

    /// Atomically abandon a stale post-resume hold and re-enter the existing
    /// suspended-lane preparation owner. The lane remains warm-suspended while
    /// the asynchronous reader transaction runs, so ordinary split-video
    /// supply cannot wake against the stale candidate. This is a continuation
    /// of the same token/run authority, not a new recovery rung or watchdog.
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
        // `flush()` drops stale proof candidates while retaining the last
        // displayed image. The strict video-only preparation below owns the
        // next dependency sequence and will re-pin this renderer.
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
                // A newer token/owner/session owns the presentation. The
                // successor's coordinator will emit its own typed result.
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
        // Proof closes the same token that authorized the hold. A later
        // background edge must receive a new token rather than reusing a
        // completed candidate authority.
        if !isVideoLaneWarmSuspended {
            activeVideoSuspendToken = nil
        }
        requestSupplyWake()
    }

    private func clearPendingVideoFrames() {
        pendingVideoFrames = []
        pendingVideoContentSeconds = 0
    }

    /// Drop all target-side data that was privately prepared for a seek. The
    /// renderer owns its staged PCM slot, while the session owns compressed
    /// packets, decoded video frames, and the timeline buffer. Abort and pause
    /// must release the latter immediately so a superseded target cannot be
    /// presented or retained until a later lifecycle event.
    private func discardSeekPreparedContent(for token: MediaAudioSeekToken? = nil) {
        if let token, activeSeekToken != token { return }
        guard activeSeekToken != nil else { return }
        clearPacketBuffers()
        clearPendingVideoFrames()
        clearPendingPCM()
    }

    private func clearPendingPCM() {
        retirePendingAudioDisplaySupport()
        audioDisplayObservation.invalidate()
        audioTimelineBuffer.reset()
        audioTimelineAdjustmentLogCount = 0
        audioDecodeTimingLogCount = 0
    }

    private func retirePendingAudioDisplaySupport() {
        for entry in pendingAudioDisplaySupport.values { entry.support.retire() }
        pendingAudioDisplaySupport.removeAll()
    }

    private func retirePendingAudioDisplaySupport(_ support: AudioPendingDisplaySupport) {
        support.retire()
        pendingAudioDisplaySupport.removeValue(forKey: ObjectIdentifier(support))
    }

    private var lastPresentNotReadyLogAt: TimeInterval = 0
    /// True while SampleBufferVideoRenderer has an active
    /// `requestMediaDataWhenReady` handler (Path A redesign step 3).
    private var presentFeedArmed = false

    /// Arm ASBD-pull present feed when the live renderer supports it.
    /// Fake/placeholder renderers keep the poll-only `presentDueVideoFrames` path.
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

    /// Result of one present-feed drain attempt.
    private enum PresentDrainResult {
        /// Enqueued until ASBD back-pressure; keep request armed.
        case blockedOnASBD
        /// The head is retained while its optional enhancement is pending.
        case waitingOnEnhancement
        /// Head PTS still in the future (or queue empty).
        case nothingDue
        /// Enqueued at least one frame and queue still wants more later.
        case enqueued
    }

    /// Stop native requests when only a clock advance or an enhancement wake
    /// can make another sample available.
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

    /// Drain pending due frames into the renderer while ASBD accepts data.
    private func enqueueDueFramesWhileASBDReady(
        _ renderer: SampleBufferVideoRenderer
    ) -> PresentDrainResult {
        var didEnqueue = false
        let burstFirstPTS = diagnostics.isCapturing ? pendingVideoFrames.first?.pts : nil
        var burstEnqueued = 0
        defer { reportLateVideoPresentBurst(firstPTS: burstFirstPTS, enqueued: burstEnqueued) }
        // Both callers gate on `isPlaying`, which `play()` gates on `isReady`,
        // which the readiness fault gates on an audio master clock — so the due
        // boundary is always meaningful here and there is no unpaced fallback.
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
                pendingVideoContentSeconds = pendingVideoFrames.reduce(0) {
                    $0 + max(0, $1.duration)
                }
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
                case .enqueued:
                    break
                }
                recordAdmittedVideoHead(head)
                burstEnqueued += 1
                didEnqueue = true
            } catch {
                pipeWindowNotReady += 1
                logPresentBackpressureIfNeeded(error)
                return .blockedOnASBD
            }
        }
        if !didEnqueue {
            pipeWindowNotDue += 1
        }
        return didEnqueue ? .enqueued : .nothingDue
    }

    private func recordAdmittedVideoHead(_ head: MediaVideoFrame) {
        tracing.mark(.firstVout, token: activeStartupTraceToken)
        _ = pendingVideoFrames.removeFirst()
        pendingVideoContentSeconds = max(0, pendingVideoContentSeconds - head.duration)
        presentedVideoFrameCount += 1
        pipeWindowPresentFrames += 1
        pipeWindowRendererAdmitted += 1
        pipeWindowRendererPTSAdvanced = true
        noteFlowStage(&flowPresentV, "presentV")
    }

    private func reportLateVideoPresentBurst(firstPTS: TimeInterval?, enqueued: Int) {
        // A late burst can account for visible catch-up after a freeze.
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

    /// Kick present from clock advance, decode completion, or enhancement wake.
    private func presentDueVideoFrames() {
        guard !isVideoLaneWarmSuspended else { return }
        guard isPlaying, !isBuffering, !isSeekInFlight else { return }
        if let renderer = videoRender as? SampleBufferVideoRenderer {
            pipeWindowPresentCalls += 1
            switch enqueueDueFramesWhileASBDReady(renderer) {
            case .waitingOnEnhancement:
                // Native readiness cannot advance this head. Completion or its
                // deadline will wake the same drain with the original still pending.
                if presentFeedArmed { disarmPresentFeed() }
            case .blockedOnASBD, .enqueued:
                armPresentFeedIfNeeded()
            case .nothingDue:
                // Leave an existing pull armed until its callback sees no due frame.
                break
            }
            maybeReportPipeInstrument()
            return
        }
        // Placeholder / Fake: poll-only present (no ASBD ready signal). Same
        // audio-master due boundary — the `isPlaying` guard above implies it.
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
                pendingVideoContentSeconds = pendingVideoFrames.reduce(0) {
                    $0 + max(0, $1.duration)
                }
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

    /// Reset wall-clock frame sampling and the optional pipe log window.
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
            // A full reset means a new stream / session, so the 1Hz line's
            // "unchanged since last window" state is about a window that no
            // longer exists. Dropping it forces the next line to be a full
            // anchor — otherwise the first line of a new load would omit
            // fields on the strength of the PREVIOUS load's values.
            pipeStickyFields.removeAll(keepingCapacity: true)
            // NOT reset here: `lastAudioCallbackCount` / `lastAudioRenderedFrameCount`.
            // They are the baseline for a per-window DELTA, and the renderer's
            // own counters are reset only by `EngineAudioRenderer.start`, which
            // `startAudioRenderIfNeeded` skips while the renderer is already
            // running. A seek takes this path without stopping audio, so
            // zeroing the baseline here made the next line print the
            // session-cumulative total under a `/s` label — a reading that
            // looks like a measurement and is not one. A renderer restart is
            // detected instead, by the counter going backwards.
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

    /// One event on a stage; logs a stall-end edge when the gap it closed was
    /// ≥ the threshold. Edges are logged only mid-play (pause/seek idles are
    /// not stalls) and the whole path is capture-gated.
    /// Half the queue's own low-water mark: the depth below which a supply gap
    /// is a stall rather than the park phase of the sawtooth.
    ///
    /// Derived rather than constant so it tracks `packetQueueHighWater` instead
    /// of assuming one. A floor at or above low-water makes every trough a
    /// "stall" — which is what the previous constant did at the shipping 8 s
    /// cap, where low-water is 1.6 s.
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
        // Supply-side stages idle benignly while their queue sits at/above its
        // derived starvation floor (`ingestStarvationFloor`, or 0.25x target for PCM);
        // only gaps observed below that floor (or during `isBuffering`) log as stalls.
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
            // Diagnostic A/V clock delta (`displayClock - audioPresentationMediaTime`);
            // `n/a` when the active video renderer exposes no display clock.
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
            // Force a full anchor line every tenth window and on any freeze window.
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
            // Omitted while unchanged. `srcCB`/`srcF` were cumulative, so they
            // differed every window and could never compress; the useful
            // quantity was always the per-window rate anyway.
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
            // `present` is `audioPresentationMediaTime`, which `:1202-1207`
            // defines as `clock.mediaTime - audioRender.contentTimePresentationOffset`.
            // It is a pure function of two quantities this same line already
            // carries (`mt` always, `audioOffset` as an omit-while-unchanged
            // field), so it is anchor-only for the same reason `due` is.
            //
            // An earlier version printed it whenever it differed from `mt` and
            // called that an F1 violation detector. That was wrong twice: the
            // two agree because the TimePitch offset is 0 while bypassed at
            // 1.0x, not because F1 has one writer; and at any other rate — the
            // reason this engine exists — the offset is 20-90ms, so the
            // "violation" would have fired every second forever.
            if fullLine {
                line += "present=\(String(format: "%.2f", presentMediaTime)) "
            }
            // `due` is `videoPresentationDueTime`, which is defined as
            // `audioPresentationMediaTime + videoPresentLeadSeconds`. It is
            // not a measurement; it cannot diverge from `present` by anything
            // but the constant. Anchor lines only.
            if fullLine {
                line += "due=\(String(format: "%.2f", due)) "
            }
            if omitted > 0 {
                // Explicit, so an absent field is never read as a zero one.
                line += "(+\(omitted) unchanged)"
            }
            diagnostics.log(line)
            let flowNow = ContinuousClock.now
            // Emitted unconditionally, on purpose. A de-duplicating version of
            // this line was written and removed the same day: an idle stage
            // renders as `0(idle Nms)` where N grows every window, so the key
            // differed on every window of exactly the stall the suppression was
            // meant to compress — it could only fire when all seven stages held
            // identical counts AND identical max gaps. Worse, the key covered
            // only the stage terms, so `age` / `relayDrains` / `dec` could
            // change and be dropped with no omission marker, which is the one
            // thing this whole change promises never to do.
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
                // A whole playing window with zero presents is the visible
                // freeze. The idle ordering names the stage that stopped first;
                // mtΔ > 0 proves the audio clock ran through it (scenario 5).
                //
                // Only the fields the two lines above do NOT carry. This used
                // to repeat twelve of them; `fullLine` is forced for a freeze
                // window precisely so that repetition is unnecessary rather
                // than merely redundant. `pcmSec` is renamed from `pcm`: the
                // `[gap]` line's `pcm=` is a flow-window event count, and two
                // different quantities shared one name one millisecond apart.
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

    /// Decoded output by PTS alone — the preroll batch releases discarded
    /// pixel buffers inside the decoder, so only their timestamps arrive.
    private func noteVideoLivenessOutput(pts: TimeInterval) {
        pipeWindowVideoOutputFrames += 1
        switch videoLivenessPTSProgress.observe(pts) {
        case .invalid, .noProgress:
            return
        case .advanced(let delta):
            // The first real output frame establishes progress for this
            // generation even though there is no preceding PTS to subtract.
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
        // Rate-limit: one line / 2s (device soak had 10k+ spam lines).
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
        // The native configuration can change during the timing read. Make the
        // final running/held decision from current output facts, not that sample.
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
            // Timing quality alone must not strand available audio/video. This
            // preserves visual continuity until the normal drain path can sample
            // audio again; it never becomes F1 or a seek/warm preparation target.
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

    /// Only an explicit timeline owner may replace a visual hold with media time.
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
        // Observation reconciles video only; normal transport owns audio rate,
        // activation, decode/supply work and every playback permission.
        if rate > 0, effectiveDisplayRate > 0 { presentDueVideoFrames() }
    }

    /// Drift correction for the display timebase.
    ///
    /// It re-pins through `applyPipelineDemand` rather than the display alone,
    /// which is a deliberate belt: the guard above means `effectiveDisplayRate`
    /// is the real rate here, so the audio write is a no-op store at steady
    /// state — but if any lifecycle path ever clears `isBuffering` without
    /// restoring audio demand, this repairs it instead of leaving the stream
    /// silent. Silent audio with a running picture is the failure mode that
    /// pairing these two exists to prevent, and it is not one a user can
    /// diagnose.
    private func maybeResyncDisplaySlave() {
        guard isPlaying, !isBuffering, !isSeekInFlight else { return }
        // Metadata retirement follows the real native clock, not a timebase reset.
        // It must also run when no frame is due or audio timing is unavailable.
        let displayClock = (videoRender as? SampleBufferVideoRenderer)?
            .sampleDisplayClockAndRetireCompletedEvidence()
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
        // Re-pin only when the display clock drifts past `displayDriftResyncSeconds`
        // so the synchronizer free-runs smoothly during steady tracking.
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
        // Keep `pendingVideoFrames` sorted by ascending PTS: synchronous VT decode
        // emits B-frame streams in decode order, while presentation and drop-oldest
        // both consume from the earliest-PTS head.
        var idx = pendingVideoFrames.count
        while idx > 0, pendingVideoFrames[idx - 1].pts > frame.pts {
            idx -= 1
        }
        pendingVideoFrames.insert(frame, at: idx)
        pendingVideoContentSeconds += max(frame.duration, 0)
    }

    private func resetOutputMediaFloor(to mediaTime: TimeInterval) {
        outputMediaFloor = max(0, mediaTime.isFinite ? mediaTime : 0)
        droppedPrerollVideoFrameCount = 0
        droppedPrerollAudioFrameCount = 0
        trimmedPrerollAudioSampleFrameCount = 0
        staleVideoOutputRejectionCount = 0
        staleVideoOutputRejectionMinPTS = nil
        staleVideoOutputRejectionMaxPTS = nil
        // The decode frontiers belong to the SAME per-generation preroll
        // accounting as the drop counters, and they are reset in the same place
        // for the same reason: a frontier carried in from the previous
        // generation would let old-generation output satisfy a new seek target
        // on the first pass. Every reader of these is fenced by
        // `isCurrentGeneration`, and every writer of them runs behind the same
        // fence, so this reset is the only way a value crosses a generation —
        // and it clears them.
        videoDecodeFrontierPTS = nil
        audioDecodeFrontierPTS = nil
    }

    /// Advance the presentation floor monotonically when a warm preparation
    /// outlives the target sampled at its start. Decoded output below the new
    /// floor is no longer a candidate for the active renderer and can be
    /// discarded safely; compressed packets remain available to rebuild the
    /// decoder's dependency chain.
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
        // One definition shared with the fast preroll's pre-target test
        // (`OutputFloorPolicy.isPreTarget` is the negation of its first clause).
        // A frame that starts before the floor is late even when its interval
        // crosses it. The output-floor contract suppresses that frame so the
        // renderer never receives old content against a later timebase.
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

    /// Record decoder output progress. Called for EVERY decoded frame, before
    /// the preroll drop test — a frame discarded below the floor is still proof
    /// the run-up advanced, and treating only kept frames as progress is what
    /// made "consumed 3 of 4 run-up seconds" indistinguishable from "stalled".
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

    /// Allocate the identity for one demux read that was admitted with a
    /// non-zero video budget. The identity is captured before the await and is
    /// passed into `ingest`; if the read returns after warm suspension, that
    /// completion is explicitly post-edge rather than silently becoming
    /// retained-at-suspend authority.
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

    /// Called only inside capture admission; fake renderers have no native
    /// ring or short-read authority, so their corresponding facts are unknown.
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
        // Path A redesign step 1: single concurrent supplier. The self-paced supply
        // loop is the producer; a re-entrant inline caller (`fillPCMRing` when its
        // audio packet store momentarily empties) must NOT run a SECOND `demux.pump`
        // in parallel — two interleaved pumps could scramble packet (esp. audio)
        // order. The skipped caller retries on its next schedule once the loop tops
        // up. Prime / seek call this sequentially before the loop starts, so the
        // guard never blocks priming.
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
            // The retained candidate already owns every compressed byte needed
            // to reach presentation proof; withhold split-video supply until proved.
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
        // Admit all extra clocks/snapshots/counting through console OR report
        // capture. Capped prime fills are included; no-op wakes remain silent.
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
                // Publishing a fault cancels this lane and marks its generation
                // faulted. Preserve the initiating error while withholding those
                // terminal inventories; a successor still takes precedence.
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
            // A cooperative handoff ends after the in-flight batch has been
            // ingested. Without this, a keyless suspended window stays empty
            // and a cancelled fill can keep fetching forever to reach its HWM.
            guard !Task.isCancelled,
                  isCurrentAudioDecodeOperation(audioDecodeOperationID) else {
                return
            }

            // Drain residual first so we never re-pump across a PTS hole while
            // unconsumed moof tail still sits in residual.
            drainResidualPackets()

            let videoDepth = isVideoLaneWarmSuspended
                ? suspendedVideoRunway
                : videoPacketQueue.contentSeconds
            let audioDepth = audioPacketQueue.contentSeconds
            // Residual gates only its own track's pump so a parked audio
            // fragment never blocks video supply (or vice versa).
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

            // Per-track budgets: each track gets its OWN room, capped per call
            // (see pumpCallBudgetCapSeconds). The old joint
            // min(videoRoom, audioRoom) let a full audio queue throttle video's
            // refill below its 1x drain rate — the vQ ratchet.
            // Lifecycle/pressure can change while awaiting EOF or a previous
            // pump in this fill. Recheck admission at the read boundary rather
            // than reusing the fill's entry target for an audio-driven refill.
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
            // The pump turns cached fragments into queued packets: zero the
            // moving tracks' cached figure until the end of the pass
            // re-measures it (see `cachedVideoRunwaySeconds`).
            resetCachedRunway(
                video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5, preservingDisplay: true
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
                clearResidentDisplay(video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5)
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
                clearResidentDisplay(video: videoBudget > 0.000_5, audio: audioBudget > 0.000_5)
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
            // After ingest, move any HWM-rejected samples into residual (done inside
            // ingest) and try one more residual drain into free room.
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
            // Before the tick, so the `buffered` it carries includes it.
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
            // A cancelled fill (pause/park quiesce) must not fire one last
            // tick into an owner that is mid-teardown.
            if isReady, !isSeekInFlight {
                onEvent?(.tick(
                    mediaTime: clock.mediaTime,
                    duration: clock.duration,
                    buffered: bufferedTime
                ))
            }
        }
    }

    /// Fail-closed gate for `.ready` (assessment seam repair 4 / review **R2**).
    ///
    /// A session that reports `.ready` with a decoder that never opened plays
    /// audio over a black screen and calls it success — the exact failure
    /// `PATHA_A2_DISPLAY_CONTRACT.md` §1 exists to prevent, reached from the other
    /// side. Before failing, retry the open **once**: priming has now seen real
    /// packets, and a demuxer may only be able to state its codec config after
    /// parsing them (this is the shape an FFmpeg-class demuxer has).
    ///
    /// The requirement is **the media clock, not the track list**. `mediaTime` has
    /// exactly one writer — `renderedContentDidAdvance`, fed by drained audio — so
    /// an input with no audio track has no clock at all: it would report `.ready`,
    /// paint moving video, and leave position, duration, `.ended`, and playback
    /// order frozen at the open position forever. That state is false, and the
    /// `.error`-keyed recovery ladder cannot see it, so the producer refuses it
    /// here (offline downloads with no `audio.m4s`, `durl`/muxed single-URL VOD).
    ///
    /// Returns a human-readable fault, or `nil` when the session will have both a
    /// working video decoder and a working audio master clock.
    private func decoderReadinessFault(generation gen: Int) async -> String? {
        if !videoDecoderOpened {
            await openVideoDecoderIfNeeded(expectedGeneration: gen)
            guard isCurrentGeneration(gen) else { return nil }
        }
        if !audioDecoderOpened {
            // No-op without a declared audio track; the missing clock is reported
            // below with the shape of the input that caused it.
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
            // No audio decoder ⇒ no drain report ⇒ no F1 master clock.
            return "audio decoder \(type(of: audioDecoder)) did not open" +
                (lastAudioDecoderOpenError.map { " (\($0))" } ?? "")
        }
        return nil
    }

    /// Open or rebuild the decoder from one snapshot of the selected video
    /// track. The decoder owns construction of its native format description.
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
        // Reserve one bounded retirement slot for this object before the first
        // async decoder call. A stop/replacement can then mark the exact open
        // as logically retired without admitting a third detached close while
        // two older invalidations are still outstanding.
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
            // A pending state is retained only when a close could not yet be
            // admitted. The completion owner drains it after an older ticket
            // completes; otherwise the exact close ticket is already the
            // durable once-only evidence.
            if let state = openingVideoDecoders[openingIdentity],
               state.retirementNeeded && !state.retirementRequested {
                // Keep the pending obligation for the retirement completion
                // owner to drain.
            } else {
                openingVideoDecoders.removeValue(forKey: openingIdentity)
            }
        }
        // `open` is an async collaborator and may have acquired native
        // resources before throwing. Mark the object as owning a potentially
        // live decoder session before the await so the catch path retires it
        // even when the collaborator cannot expose partial-open state.
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

    /// Completes one exact decoder-open operation. This is the only owner that
    /// may turn an opening retirement obligation into a detached close. In
    /// particular, `stop()` and replacement only set `retirementNeeded` while
    /// `open` is suspended; they never race the native decoder with `close()`.
    private func finishVideoDecoderOpen(
        openingDecoder: any MediaVideoDecoding,
        openingIdentity: ObjectIdentifier,
        authorityIsCurrent: Bool,
        succeeded: Bool,
        errorDescription: String?
    ) {
        guard var state = openingVideoDecoders[openingIdentity] else {
            // The completion was already consumed by this exact opening
            // identity. Never infer the current slot from a late callback.
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

        // A stale success/failure, or an open whose authority was retired while
        // it was suspended, is still a cleanup obligation. The helper records
        // the exact identity and starts close only now that the open returned.
        requestVideoDecoderRetirement(openingDecoder)
    }

    /// Replace decoder authority synchronously. Native retirement is queued on
    /// a non-main executor: a malfunctioned VT session can block inside
    /// `VTDecompressionSessionInvalidate`, and that cleanup must never prevent
    /// the replacement decoder from being created/opened or the transaction
    /// from settling.
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
        // The replacement itself will soon reserve an opening slot. If the
        // current object is still opening, its reservation is converted to a
        // pending close by `enqueueVideoDecoderRetirement`; it is not another
        // slot. Recovery may therefore proceed only when both that existing
        // obligation and the replacement's reservation fit below the ceiling.
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
            // Admission above reserves this slot. Keep the rollback explicit
            // if the tracker invariant is ever violated.
            guard enqueueVideoDecoderRetirement(current) else {
                videoDecoder = current
                videoDecoderOpened = currentWasOpened
                videoDecoderHasNativeSession = currentHadNativeSession
                videoDecoderWasRetired = false
                return false
            }
        }
        warmVideoPreparationLedger.clearProgress()
        // Diagnostics follow the successful transfer only after rollback is
        // no longer possible. Non-warm and stale callers cannot arm a successor.
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
            // The open owns the native boundary. Mark the exact object as
            // logically retired and let its completion owner start close after
            // the await returns. This is the stop/replacement no-race path.
            videoDecoderOpened = false
            videoDecoderHasNativeSession = false
            videoDecoderWasRetired = true
            return requestVideoDecoderRetirement(videoDecoder)
        }
        // Retire the current object even when its open failed or the native
        // session flag was never observed. The object may still own decoder
        // resources (and test/alternate implementations use `close()` to
        // release them), while `videoDecoderWasRetired` remains the
        // exactly-once fence. Gating retirement on the best-effort native
        // session observation can strand an opened decoder on teardown.
        // Do not mark the constructor-provided decoder retired before the
        // first open: `performOpen` runs this cleanup as part of its initial
        // resource barrier, and doing so would force an unnecessary factory
        // replacement before the first decoder ever opened. Once an open was
        // observed (or the session still advertises itself opened), close the
        // object even if a fault already cleared `videoDecoderOpened`.
        guard !videoDecoderWasRetired,
              videoDecoderHasNativeSession || videoDecoderOpened else { return true }
        let retired = videoDecoder
        let wasOpened = videoDecoderOpened
        let hadNativeSession = videoDecoderHasNativeSession
        videoDecoderOpened = false
        videoDecoderHasNativeSession = false
        videoDecoderWasRetired = true
        guard enqueueVideoDecoderRetirement(retired) else {
            // The two-slot ceiling is a hard limit. Keep the current identity
            // and ownership evidence so a later terminal stop can retry the
            // admission instead of silently dropping cleanup.
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
            // Do not call close while the collaborator's open is suspended.
            // The opening ledger is the durable pending obligation and the
            // open completion owns conversion to an actual ticket.
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
                // Keep the logical current-slot fence consistent even when a
                // caller reaches this helper directly rather than through
                // `retireCurrentVideoDecoderWithoutWaiting`.
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
            // The exact identity already has one cleanup owner.
            diagnostics.log(
                "[PathA][continuation] duplicate decoder retirement ignored"
            )
            return true
        }
        // When draining a completed opening, its reservation is converted to
        // this active ticket. Exclude that one reservation from the admission
        // check; all other active/pending identities still count.
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
        // An unstructured task retains both its operation and captured decoder
        // until completion. Keeping completed/stuck task handles on the session
        // would instead grow one permanent array entry per repair cycle, while
        // teardown must deliberately not await a native invalidate that can
        // block. Decoder implementations serialize their own state.
        // This is cleanup for a live presentation hand-off. Keep it detached
        // from MainActor, but give the retirement enough priority to begin
        // promptly while the successor is being prepared; a utility-priority
        // task can be starved behind the simulator's test workload and make
        // the old decoder appear to remain current.
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

    /// A pending opening state is a reservation even before its exact close
    /// ticket exists. This keeps the two-slot bound meaningful across the
    /// open/stop/late-callback ordering, while a successfully adopted open
    /// releases its reservation immediately.
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

    /// Converts completed opening obligations to detached close tickets when a
    /// slot is available. The opening identity stays in the ledger until the
    /// open helper returns, even if this close completes immediately.
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
            // A stale completion cannot release a successor that reused a
            // memory address or an identity already released by this session.
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
        // Fail closed (assessment seam repair 1 + R2): without a rendered-content
        // report there is no legal F1 writer, so this renderer would play audio
        // while `mediaTime` froze — a silent clock failure three layers from its
        // symptom. Refuse loudly instead.
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
                    // `AVAudioEngine.start()` is still running off the main
                    // actor; the outcome is logged by the renderer as
                    // `audio render start hardware …` / `bring-up timing mode=async`.
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
        // The decoder resource, not public playback readiness, owns submission.
        // During cold prime the relay can therefore turn a complete streamed
        // sample into a displayable frame while the same pump is still gathering
        // audio. Seek stays on its explicit prepare/commit transaction.
        guard !isSeekInFlight,
              !isVideoLaneWarmSuspended || isDecodingWarmVideoCandidate else {
            return
        }
        if !videoDecoderOpened {
            // A local PiP decoder fault intentionally keeps the audio master and
            // bounded compressed queue alive, but the old guard made every
            // scheduler kick a no-op forever. Re-enter the existing local
            // decoder replacement path once; it never reopens the source.
            guard isReady, isPlaying, runtimeFaultedGeneration == nil else { return }
            scheduleVideoDecoderRepairIfNeeded()
            return
        }
        guard !videoPackets.isEmpty else { return }
        // OI-12: while the resume-open preroll is batching, a PRE-TARGET head
        // belongs to the batch path (a relay decode would take it the old,
        // synchronous way). Target-side heads are never held back.
        if Self.relayDecodeYieldsToPrerollBatch(
            batchingActive: prerollBatchingActive,
            head: videoPackets.first,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        ) {
            return
        }
        // A burst already owns the FIFO. `decodeTask` below cannot see a DIRECT
        // burst (it sets no handle), which is how a relay wake started a second
        // consumer in the middle of a warm candidate decode and transposed its
        // submissions — see `videoDecodeLaneOwners`. Declining is free here:
        // every owner releases inside a flow that kicks decode again
        // afterwards (`performOpen` at the supply-loop start, `resumeVideoLane`,
        // the supply loop's own drain), so nothing is stranded.
        // A cancelled scheduled predecessor deliberately keeps its owner
        // count until the native decode await returns, but it has already
        // lost `activeVideoDecodeOperationID` and must not block its
        // successor. A live scheduled owner, or a direct owner held by the
        // FIFO gate, still excludes a new scheduled consumer.
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
        // `!isSeekInFlight` mirrors `scheduleVideoDecodeIfNeeded`'s own guard
        // ("Seek stays on its explicit prepare/commit transaction") — an
        // invariant that comment ASSERTED for this lane but only ENFORCED for
        // video. Without it, `drainRelayedPackets`' unconditional relay wake
        // could schedule a fill concurrent with a seek's own direct
        // `fillPCMRing` prime, and both drain the same `audioPackets` FIFO
        // into the one shared `pcmResampler` — the reproducible seek crash in
        // `PCMLinearResampler.process`. Nothing is stranded:
        // `commitPreparedSeek` re-kicks both schedulers after the seek
        // settles, and the seek's own priming never goes through this
        // scheduler in the first place.
        guard isReady, audioDecoderOpened, !isSeekInFlight else { return }
        let needsMorePCM = pendingAudioContentSeconds < audioPCMTargetSeconds
            && (!audioPackets.isEmpty || needsPacketFill())
        guard needsMorePCM else { return }
        // A burst already owns the FIFO. Mirrors `scheduleVideoDecodeIfNeeded`'s
        // own lane guard — see `audioDecodeLaneOwners` — for the identical
        // reason: a cancelled scheduled predecessor deliberately keeps its
        // owner count until the native decode await returns, but it has
        // already lost `activeAudioDecodeOperationID` and must not block its
        // successor. A live scheduled owner, or a direct owner held by the
        // FIFO gate, still excludes a new scheduled consumer.
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

    /// The optional identity is nil for synchronous/open/seek/warm callers
    /// that do not own a scheduled lane task. Those callers still inherit the
    /// cooperative cancellation check; scheduled callers additionally need to
    /// prove that their exact operation is still the current handle owner.
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

    /// Clear a scheduled video decode only when its caller still owns the
    /// operation identity. A stale task must leave a successor's handle alone.
    private func finishVideoDecodeOperation(
        _ operationID: UInt64,
        generation gen: Int
    ) {
        let ownsCurrentOperation = activeVideoDecodeOperationID == operationID
        guard ownsCurrentOperation || activeVideoDecodeOperationID == nil else {
            // A successor owns the shared task handle. A stale completion must
            // never clear or reschedule that successor.
            return
        }
        // Warm-suspension/fault boundaries invalidate the operation before the
        // cancellation-ignoring decoder returns, but may deliberately retain
        // its handle until that return. With no successor owner present, this
        // completion is the exact point at which that retained handle can be
        // released. MainActor serialization makes the nil-owner check and
        // clear atomic with respect to a subsequent schedule attempt.
        if ownsCurrentOperation {
            activeVideoDecodeOperationID = nil
        }
        decodeTask = nil
        guard ownsCurrentOperation else {
            // The operation was canceled at a warm/fault boundary. Its
            // retained handle is now released, but cancellation must not
            // immediately re-arm video work against that retired boundary.
            return
        }
        guard isPlaying,
              isCurrentGeneration(gen),
              videoDecoderOpened,
              !videoPackets.isEmpty,
              videoFrameQueueNeedsFill else { return }
        scheduleVideoDecodeIfNeeded()
    }

    /// Audio's scheduled fill owns a separate operation identity from video.
    /// Its completion can only clear the handle that it installed.
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

    /// `contentCap` bounds the PCM this fill targets; `packetContentCap` bounds
    /// the PACKETS it may pump to get there, and defaults to `contentCap` so
    /// every existing caller is unchanged.
    ///
    /// They are separate because they answer different questions and the seek
    /// path needs different answers. The PCM target is the renderer's reserve
    /// exactly — priming past it is wasted seek latency. The packet cap has to
    /// leave `minTrackFillRoom` beyond that reserve, for the same reason
    /// `audioSeekPumpContentBudget` exists on the sibling refill: compressed
    /// access units are indivisible, so a cap set exactly AT the reserve cannot
    /// admit the AU that crosses it. Collapsed into one number, a reserve below
    /// `minTrackFillRoom` made `canPump` unsatisfiable and this fill could not
    /// pump at ALL — it would consume whatever packets happened to be present,
    /// then break with the ring still empty. That is precisely the shape the
    /// seek readiness gate cannot afford, because "no packets left, ring empty"
    /// reads identically to "target-side content does not exist".
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
            // Livelock guard: a burst that consumed packets but produced no PCM
            // means the audio decoder is not yielding usable frames. Re-pumping
            // the demuxer cannot fix that, and without this the ring never reaches
            // pcmTarget so fillPCMRing re-pumps forever and prime never completes
            // (device D3). Allow a small bounded lookahead window: compressed
            // converters may consume a few access units before their first PCM,
            // but this remains a finite startup/seek budget rather than a
            // reserve relaxation or an unbounded retry loop.
            if consumedPackets > 0, pendingAudioContentSeconds <= pcmBefore + 1e-9 {
                if droppedPrerollAudioFrameCount > prerollDropsBefore {
                    // Deliberately consumed pre-target PCM. Keep decoding until
                    // target-side audio arrives; this is progress, not a decoder stall.
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

    /// The DIRECT-burst prologue, shared by `drainVideoDecodeBurst` and the
    /// preroll batch path: join the scheduled consumer (following any
    /// successor it installs), then take the direct FIFO gate. Returns `false`
    /// — holding nothing — when authority was lost while waiting; on `true`
    /// the caller owns `directVideoDecodeLane` and must release it.
    private func joinScheduledVideoDecodeAndAcquireDirectLane(
        generation gen: Int,
        warmPreparationAttempt: WarmVideoPreparationAttempt?
    ) async -> Bool {
        do {
            // A scheduled task can finish and immediately install a successor
            // from its completion fence. Follow that chain before taking the
            // direct gate, otherwise multiple direct callers can all wake on
            // the first task and race the successor as well.
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
                // The completed task clears its operation identity. If a
                // successor owns the lane, the loop awaits that successor;
                // cancellation boundaries intentionally leave no active ID.
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
        // A DIRECT burst joins the scheduled consumer instead of racing it.
        //
        // The scheduler cannot start one while a burst holds the lane (below),
        // but the warm repair loop RESUMES between its bursts, and a relay wake
        // queued in that window starts a task legitimately. Awaiting it here is
        // the same move `performOpen` already makes before its prime burst, and
        // it is the only one available: a direct caller must never BAIL on a
        // busy lane, because `primeVideoRunwayAfterPreroll` and the warm repair
        // loop both compare queue/frame counts across their own burst call and
        // treat no movement as exhaustion — a bail would settle as
        // `.decoderPreparationExhausted`, a user-visible Retry in place of
        // seconds of self-healing corruption. Order is what matters, not which
        // consumer does the work: the scheduled task drains the same FIFO in
        // FIFO order and its progress counts for the caller's fence.
        //
        // A scheduled burst never reaches this (it owns `decodeOperationID`),
        // so it cannot await itself, and `Task.value` on a finished task
        // returns at once.
        let isDirectBurst = decodeOperationID == nil
        if isDirectBurst {
            guard await joinScheduledVideoDecodeAndAcquireDirectLane(
                generation: gen,
                warmPreparationAttempt: warmPreparationAttempt
            ) else { return }
        }
        // Hold the lane for this burst. Self-scoped by `defer`, so it cannot
        // outlive the call: an owner that leaked would make
        // `scheduleVideoDecodeIfNeeded` a permanent no-op and freeze video,
        // which is why nothing holds it across a whole transaction — the warm
        // preparation can be left parked in a non-cooperative collaborator (the
        // orphan protocol above exists for exactly that), and a `defer` in a
        // parked frame never runs.
        videoDecodeLaneOwners += 1
        defer { videoDecodeLaneOwners -= 1 }
        if warmDiagnosticAttemptIsCurrent(warmPreparationAttempt) {
            if var state = activeWarmDiagnostics {
                state.decodeBursts += 1
                activeWarmDiagnostics = state
            }
            warmDiagnosticPhase("decode-burst-start")
        }
        // Register this after the scalar owner decrement so a waiting direct
        // burst is resumed while the shared owner count is still non-zero.
        // That closes the scheduler window between adjacent direct bursts.
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
            // Unguarded by `isReady`: `performOpen` and `primeVideoRunwayAfterPreroll`
            // call this during prime, when the audio decoder may not have opened
            // yet. The frame-queue watermark applies only once the master exists —
            // prime must be allowed to bank its `primeVideoContentBudget`
            // regardless, so the condition stays conditional here.
            if usesAudioMasterForVideo, !videoFrameQueueNeedsFill {
                // Pass-through packets already own their pixel buffers. When
                // the memory cap is full but no frame has crossed into the
                // display queue yet, move exactly one packet across the same
                // cap so launch readiness is not circular.
                guard holdsPassThroughVideo, pendingVideoFrames.isEmpty else { break }
            }
            let packet = videoPackets.removeFirst()
            observeVideoPrerollSample(packet)
            // Legacy-path run-up accounting (also the fast path's target-side
            // stragglers, e.g. a reordered pre-target B-frame): same fields in
            // both modes so captures compare line for line.
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
            // Empty compressed packets never reach VideoToolbox, while AVAsset
            // pass-through packets carry their submission in `pixelBuffer`.
            // Count only access units the decoder can actually consume toward
            // the consecutive no-output bound.
            let countsAsWarmSubmission = !packet.data.isEmpty || packet.pixelBuffer != nil
            noteVideoPacketDequeued(packet)
            noteVideoPacketSubmitted()
            tracing.mark(
                .demandFirstVideoSubmit,
                token: activeStartupTraceToken
            )
            budget -= 1

            // Capture the decoder owner before the await. A generic
            // presentation repair may take over this session while decode is
            // suspended; output/faults from the retired object must not enter
            // the successor's queues or recovery state.
            let decodingDecoder = videoDecoder
            let decodingDecoderIdentity = ObjectIdentifier(decodingDecoder)
            // Scheduled relay consumers join the same warm FIFO as explicit
            // callers. Capture their admitted attempt at this submission;
            // output must never borrow a successor's attempt after the await.
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
                    // Decoder submission errors must not disappear into a
                    // continue loop. The VT implementation normally preserves
                    // the OSStatus as MediaRuntimeFault; this unknown path
                    // covers a decoder implementation that can only expose a
                    // generic Error, and takes the same recoverability an
                    // unknown VT status does (one bounded reopen).
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
                // Decode NEVER presents. A decoded frame is only ever banked here;
                // release is `presentDueVideoFrames` / the ASBD feed, both against
                // the audio master's due boundary. The old `else if isPlaying`
                // branch pushed frames straight at the renderer whenever there was
                // no master — the shape that made an audio-less download show
                // moving video over a clock frozen at the open position.
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
            // Path A redesign step 1: this decode burst drained video packets — if
            // that dropped us below low-water, wake the supply loop to refill. No
            // more decode→pump chaining; the loop owns supply cadence.
            if isPlaying {
                // Free residual into the main queue before (or instead of) a pump.
                drainResidualPackets()
                wakeSupplyLoopIfDrained()
            }
        }
        // Reuse the existing one-second pipe cadence even when a decoder
        // callback returns no frames and therefore no presentation callback
        // would otherwise close the window.
        maybeReportPipeInstrument()
    }

    /// Content accounting for a packet taken off `videoPackets`, whether it
    /// is then submitted or (fast preroll) withheld.
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

    /// Which transaction a preroll batch loop serves, and therefore its fence:
    /// a seek checks generation + seek token, an open (no token) generation
    /// alone — the same authority `primeOpenLaunchReserve.isSuperseded` uses.
    private enum PrerollContext {
        case seek(MediaAudioSeekToken)
        case open

        var isSeek: Bool {
            if case .seek = self { return true }
            return false
        }
    }

    /// The fault a decoder that can only throw a generic `Error` maps to —
    /// the same one recoverability as an unknown VT status (one bounded reopen).
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

    /// Bind a classifier to the decoder object that just opened, from the same
    /// codec/config the decoder was opened with (design §3.1). Kill switch off
    /// ⇒ never built.
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

    /// A packet the batch path may take: compressed (never pass-through) and
    /// PRE-TARGET by presentation time (`OutputFloorPolicy.isPreTarget`).
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

    /// OI-12, the only scheduler change: while a resume-open preroll is
    /// batching, a relay-scheduled synchronous decode yields a PRE-TARGET head
    /// to the batch path. A target-side head is never held back.
    static func relayDecodeYieldsToPrerollBatch(
        batchingActive: Bool,
        head: MediaPacket?,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard batchingActive, let head else { return false }
        return isPrerollBatchCandidate(head, floor: floor, epsilon: epsilon)
    }

    /// The classifier's verdict for one sample. It is consulted for every
    /// compressed sample consumed during priming, in decode order, whichever
    /// path consumes it — AV1 reference-slot state depends on it.
    private func classifyVideoPrerollSample(_ packet: MediaPacket) -> VideoPrerollSampleAction {
        guard !packet.data.isEmpty,
              packet.pixelBuffer == nil,
              videoPrerollClassifier != nil,
              videoPrerollClassifierDecoder == ObjectIdentifier(videoDecoder) else {
            return .submit
        }
        return videoPrerollClassifier?.classify(packet.data, isKeyframe: packet.isKeyframe) ?? .submit
    }

    /// A sample the synchronous path consumes during priming still passes
    /// through the classifier (result unused), so its state stays in decode
    /// order. Outside priming nothing is parsed.
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

    /// `[PathASeekPreroll]`, once per seek / resume open (design §8.1).
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

    /// `presentDueVideoFrames()`, reporting whether it enqueued a frame (the
    /// `presented=` field of `[PathASeekPhase]`).
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

    /// The pre-target run-up of a seek or resume open, batched and pipelined
    /// (design §4.2 / §4.2b). Exits at the first TARGET-side packet (which,
    /// with everything after it, stays on `drainVideoDecodeBurst` unchanged),
    /// when nothing more can be read, or on loss of authority. Never entered
    /// with the kill switch off or for pass-through video (C10).
    private func drainPrerollBatches(generation gen: Int, context: PrerollContext) async throws {
        // No run-up (seek/open at 0, or a floor nothing precedes) ⇒ nothing to
        // batch and nothing to fetch: the pass is exactly today's.
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
                // Refill only while the run-up is still outstanding — once
                // decoded output has reached the target side, fetching more is
                // the target-side path's business, as it is today.
                guard prerollRunUpIsOutstanding, !(await demux.isEOF),
                      prerollContextIsCurrent(context, generation: gen) else {
                    return
                }
                // The same capped fill `primeVideoRunwayAfterPreroll` uses, so
                // fetch granularity and the gate's pull accounting are today's.
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

    /// True until decoded output (kept or discarded) reaches the floor.
    private var prerollRunUpIsOutstanding: Bool {
        guard let frontier = videoDecodeFrontierPTS else { return true }
        return OutputFloorPolicy.isPreTarget(
            pts: frontier,
            floor: outputMediaFloor,
            epsilon: outputMediaFloorEpsilon
        )
    }

    /// One batch: ≤ `seekPrerollBatchLimit` leading pre-target packets,
    /// classified, decoded through `decodePrerollBatch`, fenced afterwards by
    /// generation, seek token and decoder identity (C6). Called holding the
    /// direct lane; releases it. Returns `false` when the loop must stop.
    private func runPrerollBatch(generation gen: Int, context: PrerollContext) async -> Bool {
        // Same owner/lane ordering as a direct burst (see `drainVideoDecodeBurst`).
        videoDecodeLaneOwners += 1
        defer { videoDecodeLaneOwners -= 1 }
        defer { directVideoDecodeLane.release() }

        let submissions = takePrerollBatch(generation: gen)
        // A scheduled consumer joined above may have taken the head while the
        // lane was awaited: let the loop re-read the queue (refill while the
        // run-up is outstanding, stop at a target-side head) instead of
        // leaving the rest of the run-up to the synchronous path.
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
            // C5: the same fence and the same typed fault the sync burst uses.
            guard prerollContextIsCurrent(context, generation: gen),
                  ObjectIdentifier(videoDecoder) == decoderIdentity else {
                return false
            }
            publishPrerollBatchFault(error, generation: gen)
            return false
        }
        // C6: a superseded seek, a stop/load, or a replaced decoder discards
        // the whole batch — frames, counters and frontier.
        guard prerollContextIsCurrent(context, generation: gen),
              ObjectIdentifier(videoDecoder) == decoderIdentity else {
            return false
        }
        notePrerollBatchStats(result, items: submissions.count, generation: gen, decodeStart: decodeStart)
        applyPrerollBatchOutput(result)
        return true
    }

    /// Dequeue the leading pre-target run (≤ the batch limit) and decide each
    /// sample's action. Every candidate is classified (keeps AV1 state in
    /// decode order) and every candidate is PRE-TARGET, so a non-reference
    /// verdict only removes output the floor would discard anyway (design
    /// §3.3). Reference samples are submitted.
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

    /// C9: the same accounting a burst does for its decoded output.
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

    /// After a segment-aligned seek, decode through all pre-target output and
    /// establish normal target-side scheduling runway before the audio master is
    /// allowed to advance. Compressed pre-roll is consumed, never skipped.
    private func primeVideoRunwayAfterPreroll(
        generation gen: Int,
        phase: MediaQueueFillPhase
    ) async throws {
        while isCurrentGeneration(gen), videoDecoderOpened, videoFrameQueueNeedsFill {
            if Task.isCancelled { return }
            if videoPackets.isEmpty {
                drainResidualPackets()
                if videoPackets.isEmpty, !(await demux.isEOF) {
                    // Capped like every other prime fill: uncapped, this
                    // interior call climbed to the full HWM — defeating the
                    // open's prime caps on resume opens and ballooning seeks
                    // whose run-up spans a fragment boundary. Each call still
                    // fetches whole fragments; the cap stops the climb.
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
        // A DIRECT burst joins the scheduled consumer instead of racing it —
        // mirrors `drainVideoDecodeBurst`'s own join (see `audioDecodeLaneOwners`
        // for why). This lane must not bail where the video lane merely
        // shouldn't: `fillPCMRing`'s no-progress fence
        // (`if consumedPackets == 0, !audioPackets.isEmpty { break }`) trips on
        // the FIRST bailed pass, which `SeekPrimingGate` reads as "target-side
        // audio does not exist" — the exact seek-priming misclassification the
        // design comment above `primeSeekTargetSide` exists to prevent. A
        // direct caller must never bail here; it AWAITS.
        //
        // A scheduled burst never reaches this (it owns `decodeOperationID`),
        // so it cannot await itself, and `Task.value` on a finished task
        // returns at once.
        if decodeOperationID == nil {
            // Follow a completion-fence successor chain before taking the
            // direct gate, for the identical reason `drainVideoDecodeBurst`
            // does: a scheduled task can finish and immediately install a
            // successor, and every direct caller must join that successor
            // too rather than race it.
            while let scheduled = audioDecodeTask,
                  let scheduledOperationID = activeAudioDecodeOperationID {
                await scheduled.value
                guard isCurrentGeneration(gen), audioDecoderOpened else {
                    return 0
                }
                // The completed task clears its operation identity. If a
                // successor owns the lane, the loop awaits that successor;
                // cancellation boundaries intentionally leave no active ID.
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
        // Hold the lane for this burst only. Self-scoped by `defer` — see
        // `audioDecodeLaneOwners` for why nothing may hold it across a whole
        // transaction.
        audioDecodeLaneOwners += 1
        defer { audioDecodeLaneOwners -= 1 }
        // Register this after the scalar owner decrement so a waiting direct
        // burst is resumed while the shared owner count is still non-zero —
        // closes the scheduler window between adjacent direct bursts, exactly
        // as the video lane's matching pair of defers does.
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

        // Path A redesign step 1: audio decode drained packets — wake the supply
        // loop if a track fell below low-water (was decode→pump chaining).
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
        let support = AudioPendingDisplaySupport()
        let supportID = ObjectIdentifier(support)
        pendingAudioDisplaySupport[supportID] = PendingAudioDisplaySupport(support: support, operationID: operationID)
        audioDecodePacketsSubmitted += 1

        func isCurrent() -> Bool {
            isCurrentGeneration(gen) && isCurrentAudioDecodeOperation(operationID)
                && pendingAudioDisplaySupport[supportID] != nil
        }

        return await withTaskCancellationHandler {
            defer { retirePendingAudioDisplaySupport(support) }
            let frames: [MediaAudioFrame]
            do {
                frames = try await audioDecoder.decode(packet, pendingDisplaySupport: support)
            } catch {
                support.retire()
                guard isCurrent() else { return false }
                let snapshot = await audioDecoder.decodeDiagnostics()
                guard isCurrent() else { return false }
                lastAudioDecodeError = error.localizedDescription
                lastAudioDecodeDiagnostics = snapshot
                diagnostics.log("[PathA] audio decode failed: \(error.localizedDescription)")
                return true
            }
            guard isCurrent() else { return false }
            if frames.isEmpty { support.retire() }
            let snapshot = await audioDecoder.decodeDiagnostics()
            guard isCurrent() else { return false }
            lastAudioDecodeDiagnostics = snapshot
            audioDecodePCMFramesProduced += frames.reduce(into: 0) { total, frame in
                guard frame.duration.isFinite, frame.duration > 0,
                      frame.sampleRate.isFinite, frame.sampleRate > 0 else { return }
                total += Int((frame.duration * frame.sampleRate).rounded())
            }
            let displayCoverage = frames.count == 1 ? support.decodedCoverage : nil
            for frame in frames {
                appendPCM(frame, displayCoverage: displayCoverage)
                decodedAudioFrameCount += 1
            }
            return true
        } onCancel: {
            support.retire()
        }
    }

    private func appendPCM(_ frame: MediaAudioFrame, displayCoverage: MediaDisplayLease?) {
        noteFlowStage(
            &flowPCM,
            "pcmA",
            starvingBelow: 1.0,
            depth: pendingAudioContentSeconds
        )
        // Frontier first, and at the chunk's END: whether this PCM is kept,
        // trimmed, or dropped whole is decided inside the timeline buffer
        // below, and all three outcomes advance the run-up equally.
        noteAudioDecodeFrontier(frame.pts + max(0, frame.duration))
        let result = audioTimelineBuffer.append(
            pcm: frame.pcm,
            pts: frame.pts,
            context: AudioPCMAppend(
                sampleRate: frame.sampleRate,
                channels: frame.channelCount,
                outputFloor: outputMediaFloor,
                displayCoverage: displayCoverage
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

    // MARK: - F4: relay drain + video-starvation buffering

    /// Take everything the demuxer has completed since the last drain and put it
    /// into the pipeline — while the pump that produced it is very possibly
    /// still running.
    ///
    /// This is the whole point of the relay: the packets are ingested, decode is
    /// kicked, and a video queue that had run dry can refill DURING a pump that
    /// will not return for another several seconds.
    func drainRelayedPackets() {
        if warmPreparationTransaction.orphan != nil {
            // A pump that crossed the warm edge may deliver one final relay hop
            // after its cancellation request. Drop that late batch rather than
            // letting retired bytes mutate the timed-out presentation state.
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
        // Ingest alone only fills the packet QUEUE. Decode is what makes the
        // samples renderable, and the supply loop is the thing that normally
        // kicks it — but the supply loop is precisely what is blocked inside the
        // pump we are bypassing.
        scheduleVideoDecodeIfNeeded()
        if !isPreparingWarmVideoLane {
            scheduleAudioDecodeIfNeeded()
        }
        resolveVideoStarvationIfRecovered()
    }

    /// Enter buffering when video runs dry (`queuedVideoRunway` and `pendingVideoFrames`
    /// both empty across `videoStarvationConfirmWindow`) so the audio master clock
    /// pauses before running seconds ahead of the last displayed frame.
    private func evaluateVideoStarvation() {
        guard isPlaying, !isSeekInFlight, !isBuffering,
              !isVideoLaneWarmSuspended,
              videoDecoderOpened, !demuxReachedEOF,
              let runway = queuedVideoRunway else {
            videoStarvedSince = nil
            return
        }
        // Starved = nothing queued AND nothing decoded waiting to present.
        // Both, because either alone is an ordinary momentary state.
        //
        // Known and accepted imprecision: with the Sample Buffer renderer,
        // frames handed to the layer have already left `pendingVideoFrames`, so
        // the renderer may still hold a little picture when both of these read
        // empty. That makes the hold fire slightly EARLY, which is the intent —
        // the requirement is to enter buffering before the clock runs seconds
        // past the picture, not at the last frame. A packet queue whose high
        // water is 20s sitting at zero for the confirm window is a supply
        // failure, not a fragment seam.
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
        // Audio demand goes to zero WITH the display. Freezing only the display
        // would leave the soundtrack draining the ring and dragging the media
        // clock further from the picture — the runaway this exists to stop.
        applyPipelineDemand()
        diagnostics.diagnostic(
            "[PathA] ⚠️ video starvation → buffering at t=\(String(format: "%.2f", clock.mediaTime)) " +
            "vQ=\(String(format: "%.2f", runway))s aQ=\(String(format: "%.2f", audioPacketQueue.contentSeconds))s " +
            "pcm=\(String(format: "%.2f", pendingAudioContentSeconds))s"
        )
        onEvent?(.buffering)
        requestSupplyWake()
    }

    /// Leave the video-starvation hold once enough video is back to play
    /// through rather than immediately re-stall.
    ///
    /// The resume level is the packet queue's OWN low-water, not a new constant:
    /// that watermark already means "this track needs refilling", so resuming
    /// above it is resuming into the queue's healthy band. Resuming at the first
    /// packet is what turns one stall into the repeated freeze → burst cycle.
    /// Whether a video hold is actually in force — and the only legal way to
    /// read `bufferingForVideoStarvation`.
    ///
    /// The flag is meaningful only while `isBuffering`, and `isBuffering` is
    /// cleared by half a dozen lifecycle paths (play, pause, stop, ended, the
    /// seek transitions) that know nothing about this owner. A flag that
    /// outlived its state would make `handlePullOutcome` refuse to clear
    /// buffering ever again — a permanent spinner with a healthy pipeline behind
    /// it. So the read repairs it rather than trusting the writers to.
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

    /// Video may be empty for up to this long without counting as starvation —
    /// it is the boundary between "between two fragments" and "nothing is
    /// arriving". Zero would fire on every fragment seam.
    private static let videoStarvationRunwayFloor: TimeInterval = 0.001
    /// How long video must stay empty before the hold engages.
    ///
    /// Wall time, not a tick count: this is evaluated from the audio clock path,
    /// whose cadence is the renderer's fill period, so a count would mean
    /// different durations on different graphs and could silently drift into
    /// "seconds" — which is exactly what this must engage before. 300ms is long
    /// enough to ride out a fragment seam and short enough that the clock cannot
    /// have run far past the picture.
    private static let videoStarvationConfirmWindow: Duration = .milliseconds(300)

    /// Buffering always freezes the display. Audio demand remains active through
    /// an ordinary audio underrun so refilled PCM can be consumed, but video
    /// starvation, pause, and seek freeze both audio consumption and F1.
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
                // Preserve per-track FIFO order: never enqueue ahead of a non-empty residual queue.
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
                    // Never drop — park for residual drain (moof-overshoot fix).
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

    /// Move residual packets into the main queues when HWM room opens. Preserves
    /// the demuxer's packet order and never drops. Call before every pump and
    /// after decode drains packets. Reordering here would hide a real parser or
    /// fragment-order discontinuity by converting it into apparently clean PCM.
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

    /// Give a zero/absent-duration packet a nominal content charge.
    ///
    /// A packet with `duration == 0` is still real media. The old shape
    /// (`guard packet.duration > 0 else { return true }` inside the enqueue
    /// helpers) reported it as *accepted* while storing nothing: it was not put
    /// in `videoPackets`, not parked in `residualVideoPackets`, and not counted
    /// as rejected — it evaporated, leaving exactly the presentation hole the
    /// residual-moof fix (`6770908`) set out to end. Normalizing once, at
    /// ingest, keeps a single number flowing through queue accounting, decode
    /// drain and pending-frame math.
    ///
    /// This is content-second bookkeeping only; it never touches F1 `mediaTime`.
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
        // Re-assert the invariant locally: never `return true` for a packet that
        // is not actually stored (that is a silent drop, see above).
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
        store: inout [MediaPacket]
    ) -> Bool {
        // Same contract as `enqueueVideoPacket`: a zero-duration packet is
        // normalized and queued, never reported as accepted-and-discarded.
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

    /// Clear any pre-background/seek rate sample immediately. The next public
    /// FPS value is produced only by frames observed in a fresh wall window.
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
        audioDrainingToEnd = false
        audioDrainPlayoutDeadline = nil
        audioDrainEmptiedAt = nil
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
