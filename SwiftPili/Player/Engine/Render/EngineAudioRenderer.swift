import AVFoundation
import Foundation
import Observation
import Synchronization
import os

/// Path A A3c flag — pitch-correct rate at the pull boundary.
///
/// Default **ON** for Demand playback. Disable only as a diagnostic rollback
/// with env `PATHA_PITCH=0`, process arg `-patha-pitch 0` /
/// `patha-pitch=0`, or DEBUG `UserDefaults` key `patha_pitch_enabled_v2`.
/// Independent from the default-on A1d demux selection and Demand engine choice.
/// See `docs/PATHA_A3C_PITCH_DESIGN.md`.
enum PathAPitchFlag {
    static let envKey = "PATHA_PITCH"
    /// New key intentionally does not inherit the former default-off setting.
    static let defaultsKey = "patha_pitch_enabled_v2"

    /// Resolves process-level enablement. Unknown overrides fail safe to the
    /// pitch-correct path; only an explicit false value selects varispeed.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        userDefaults: UserDefaults? = nil
    ) -> Bool {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return true }
        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let resolved = parseOverride(raw) {
            return resolved
        }
        let args = arguments
        if let idx = args.firstIndex(of: "-patha-pitch"), idx + 1 < args.count,
           let resolved = parseOverride(args[idx + 1]) {
            return resolved
        }
        for arg in args {
            if arg.hasPrefix("patha-pitch="),
               let resolved = parseOverride(String(arg.dropFirst("patha-pitch=".count))) {
                return resolved
            }
            if arg.hasPrefix("PATHA_PITCH="),
               let resolved = parseOverride(String(arg.dropFirst("PATHA_PITCH=".count))) {
                return resolved
            }
        }
        #if DEBUG
        _ = userDefaults
        return ExperimentalSettingsPolicy.diagnosticBool(
            key: defaultsKey,
            saved: ExperimentalSettingsPolicy.diagnosticOverrides.demandPitch
        )
        #else
        _ = userDefaults
        return true
        #endif
    }

    private static func parseOverride(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on", "yes": return true
        case "0", "false", "off", "no": return false
        default: return nil
        }
    }
}

/// One bounded wall-clock jitter reserve for the rate-agnostic PCM ring.
///
/// The ring stores content frames, so the content depth grows with playback
/// rate while the listener keeps the same wall-time protection at 0.5×, 1×,
/// and 2×. This is deliberately much smaller than the ring capacity: it masks
/// scheduler jitter without turning rate/seek edges into a deep-audio queue.
enum AudioRingReserve {
    static let wallSeconds: TimeInterval = 0.25
    static let ringCapacitySeconds: TimeInterval = 4
    /// Keep one second of ring capacity free for the producer/consumer race and
    /// for an in-flight source callback. The ring itself holds four seconds.
    static let maximumContentSeconds = ringCapacitySeconds - 1

    static func contentSeconds(forRate rate: Float) -> TimeInterval {
        min(maximumContentSeconds, wallSeconds * TimeInterval(max(rate, 0)))
    }

    static func contentFrames(forRate rate: Float, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return max(0, Int((contentSeconds(forRate: rate) * sampleRate).rounded(.up)))
    }
}

/// Pure source-read math for the real-time callback.
///
/// The virtual source for one callback is the carried frame(s) from the
/// previous callback followed by a fresh ring read. Output frame `k` sits at
/// virtual position `p_k = phase + k * step`; carrying `phase` and the
/// boundary frame(s) across callbacks (rather than restarting both at 0 every
/// callback) keeps long-run ring consumption equal to `frames * step` with
/// continuous interpolation — matching FFmpeg/Sonic/AVAudioConverter practice
/// (audit finding #2).
enum PCMSourceReadPlan {
    /// New ring frames needed this callback so the virtual source (carry ++
    /// fresh read) covers every `floor(p_k)` / `floor(p_k)+1` index the
    /// interpolation loop below will touch.
    static func requiredReadFrames(
        outputFrames: Int,
        step: Double,
        phase: Double,
        carryFrames: Int
    ) -> Int {
        guard outputFrames > 0, step.isFinite, step > 0,
              phase.isFinite, phase >= 0 else { return 0 }
        let end = phase + Double(outputFrames) * step
        let last = phase + Double(outputFrames - 1) * step
        let neededVirtualLength = max(
            Int(end.rounded(.down)) + 1,
            Int(last.rounded(.down)) + 2
        )
        return max(0, neededVirtualLength - carryFrames)
    }

    /// The interpolation pair for output frame `outputFrame`, as indices into
    /// the virtual source (carry frames at `0..<carryFrames`, then the fresh
    /// read — callers resolve the index to the right buffer).
    static func framePair(
        outputFrame: Int,
        phase: Double,
        step: Double,
        availableVirtualFrames: Int
    ) -> (first: Int, second: Int, fraction: Float)? {
        guard outputFrame >= 0, availableVirtualFrames > 0,
              step.isFinite, step > 0, phase.isFinite, phase >= 0 else {
            return nil
        }
        let position = phase + Double(outputFrame) * step
        let first = Int(position.rounded(.towardZero))
        guard first >= 0, first < availableVirtualFrames else { return nil }
        return (
            first,
            min(first + 1, availableVirtualFrames - 1),
            Float(position - Double(first))
        )
    }

    /// The boundary this callback leaves for the next one: how many trailing
    /// virtual frames to carry (`floor(end)..<virtualLength`, per the module
    /// doc) and the fractional phase the next callback starts from.
    static func carryBoundary(
        outputFrames: Int,
        step: Double,
        phase: Double,
        virtualLength: Int
    ) -> (start: Int, count: Int, nextPhase: Double) {
        guard outputFrames > 0, step.isFinite, step > 0,
              phase.isFinite, phase >= 0, virtualLength > 0 else {
            return (virtualLength, 0, 0)
        }
        let end = phase + Double(outputFrames) * step
        let endFloor = max(0, Int(end.rounded(.down)))
        let start = min(endFloor, virtualLength)
        return (start, max(0, virtualLength - start), end - Double(endFloor))
    }
}

/// Low-cost counters for the hardware source boundary. These are sampled by
/// the main actor; the render callback only performs relaxed atomic updates and
/// never formats or emits a log.
struct AudioRenderDiagnosticsSnapshot: Sendable {
    let callbackCount: Int
    let renderedFrameCount: Int
    let sourceNonFiniteSampleCount: Int
    let sourceOverrangeSampleCount: Int
    let sourcePeakAbs: Float
}

final class AudioRenderDiagnostics: @unchecked Sendable {
    private let callbackCount = Atomic<Int>(0)
    private let renderedFrameCount = Atomic<Int>(0)
    private let sourceNonFiniteSampleCount = Atomic<Int>(0)
    private let sourceOverrangeSampleCount = Atomic<Int>(0)
    private let sourcePeakAbsBits = Atomic<UInt32>(0)

    func reset() {
        callbackCount.store(0, ordering: .relaxed)
        renderedFrameCount.store(0, ordering: .relaxed)
        sourceNonFiniteSampleCount.store(0, ordering: .relaxed)
        sourceOverrangeSampleCount.store(0, ordering: .relaxed)
        sourcePeakAbsBits.store(0, ordering: .relaxed)
    }

    /// Called from the source render callback. It is intentionally split from
    /// sample inspection so the normal production path can keep the scan off
    /// when debug logging was disabled when the graph was built.
    func recordCallback(frameCount: Int) {
        _ = callbackCount.wrappingAdd(1, ordering: .relaxed)
        _ = renderedFrameCount.wrappingAdd(max(0, frameCount), ordering: .relaxed)
    }

    func recordSourceSample(_ sample: Float) {
        guard sample.isFinite else {
            _ = sourceNonFiniteSampleCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let magnitude = abs(sample)
        if magnitude > 1 {
            _ = sourceOverrangeSampleCount.wrappingAdd(1, ordering: .relaxed)
        }
        // The render thread is the only writer. The atomic keeps the main-actor
        // snapshot race-free while preserving a cheap relaxed hot path.
        let bits = magnitude.bitPattern
        if bits > sourcePeakAbsBits.load(ordering: .relaxed) {
            sourcePeakAbsBits.store(bits, ordering: .relaxed)
        }
    }

    func snapshot() -> AudioRenderDiagnosticsSnapshot {
        AudioRenderDiagnosticsSnapshot(
            callbackCount: callbackCount.load(ordering: .relaxed),
            renderedFrameCount: renderedFrameCount.load(ordering: .relaxed),
            sourceNonFiniteSampleCount: sourceNonFiniteSampleCount.load(ordering: .relaxed),
            sourceOverrangeSampleCount: sourceOverrangeSampleCount.load(ordering: .relaxed),
            sourcePeakAbs: Float(
                bitPattern: sourcePeakAbsBits.load(ordering: .relaxed)
            )
        )
    }
}

/// The pair published to the real-time callback. Keeping slot and epoch in one
/// atomic word means a callback quantum cannot observe a new slot with an old
/// generation (or vice versa).
struct AudioRingPublication: Equatable, Sendable {
    let slot: Int
    let epoch: UInt64

    static let initial = AudioRingPublication(slot: 0, epoch: 0)

    init(slot: Int, epoch: UInt64) {
        self.slot = slot
        self.epoch = epoch
    }

    fileprivate var packed: UInt64 {
        (epoch &<< 1) | UInt64(slot & 1)
    }

    fileprivate init(packed: UInt64) {
        slot = Int(packed & 1)
        epoch = packed &>> 1
    }
}

/// Two permanently allocated PCM slots and the lock-free publication seam
/// shared by the MainActor producer and the audio render callback. The MainActor
/// owns slot contents; the callback only reads the published slot and writes an
/// acknowledgement at a callback boundary.
final class PCMFloatRingRouter: @unchecked Sendable {
    let slot0: PCMFloatRing
    let slot1: PCMFloatRing
    let publishedPair = Atomic<UInt64>(AudioRingPublication.initial.packed)
    let acknowledgedPair = Atomic<UInt64>(AudioRingPublication.initial.packed)
    let outputGate = Atomic<UInt32>(0)
    /// A gate acknowledgement is separate from the publication pair. The
    /// callback can acknowledge a publication and still be in the same
    /// quantum that read its slot; a gate acknowledgement written after the
    /// zeroed/gated boundary proves that quantum has completed.
    let outputGateGeneration = Atomic<UInt64>(0)
    let acknowledgedOutputGateGeneration = Atomic<UInt64>(0)
    let acknowledgedOutputGatePair = Atomic<UInt64>(AudioRingPublication.initial.packed)

    init(capacity: Int = PCMFloatRing.defaultCapacitySamples) {
        slot0 = PCMFloatRing(capacity: capacity)
        slot1 = PCMFloatRing(capacity: capacity)
    }

    func ring(at slot: Int) -> PCMFloatRing {
        slot == 0 ? slot0 : slot1
    }

    func publish(_ publication: AudioRingPublication) {
        publishedPair.store(publication.packed, ordering: .releasing)
    }

    func publishedPublication() -> AudioRingPublication {
        AudioRingPublication(packed: publishedPair.load(ordering: .acquiring))
    }

    func acknowledgePublishedPublication() {
        let pair = publishedPair.load(ordering: .acquiring)
        acknowledgedPair.store(pair, ordering: .releasing)
    }

    func acknowledgedPublication() -> AudioRingPublication {
        AudioRingPublication(packed: acknowledgedPair.load(ordering: .acquiring))
    }

    func setOutputGated(_ gated: Bool, generation: UInt64? = nil) {
        if gated, let generation {
            outputGateGeneration.store(generation, ordering: .releasing)
        }
        outputGate.store(gated ? 1 : 0, ordering: .releasing)
    }

    func acknowledgeOutputGateAtCallbackBoundary(publication: AudioRingPublication) {
        let generation = outputGateGeneration.load(ordering: .acquiring)
        acknowledgedOutputGateGeneration.store(generation, ordering: .releasing)
        acknowledgedOutputGatePair.store(publication.packed, ordering: .releasing)
    }

    func acknowledgeOutputGateSynchronously() {
        let generation = outputGateGeneration.load(ordering: .acquiring)
        acknowledgedOutputGateGeneration.store(generation, ordering: .releasing)
        acknowledgedOutputGatePair.store(
            publishedPair.load(ordering: .acquiring),
            ordering: .releasing
        )
    }

    func isOutputGateAcknowledged(
        generation: UInt64,
        publication: AudioRingPublication
    ) -> Bool {
        acknowledgedOutputGateGeneration.load(ordering: .acquiring) == generation
            && acknowledgedOutputGatePair.load(ordering: .acquiring) == publication.packed
    }

    var isOutputGated: Bool {
        outputGate.load(ordering: .acquiring) != 0
    }

    func resetForLifecycle() {
        slot0.reset()
        slot1.reset()
        publishedPair.store(AudioRingPublication.initial.packed, ordering: .releasing)
        acknowledgedPair.store(AudioRingPublication.initial.packed, ordering: .releasing)
        outputGate.store(0, ordering: .releasing)
        outputGateGeneration.store(0, ordering: .releasing)
        acknowledgedOutputGateGeneration.store(0, ordering: .releasing)
        acknowledgedOutputGatePair.store(AudioRingPublication.initial.packed, ordering: .releasing)
    }
}

/// Path A audio pull graph (source → optional TimePitch → EQ → mixer).
/// Ring stays 48 kHz; hardware connects at the live route rate with linear resample.
/// Rate is applied downstream by `AVAudioUnitTimePitch` so the ring stays rate-agnostic
/// (`PATHA_PITCH=0` retains diagnostic varispeed rollback).
@MainActor
@Observable
final class EngineAudioRenderer: MediaAudioRendering {
    // `nonisolated` so the render-block builder (`makeSourceNode`) can read them from
    // an off-actor context; they are immutable Sendable constants.
    nonisolated static let engineSampleRate: Double = 48_000
    nonisolated static let engineChannels: Int = 2
    static let defaultFillPeriod: TimeInterval = 0.02
    /// Per-callback source scratch cap (2 s stereo @ 48 kHz). Bounds the RT read so the
    /// preallocated scratch never overflows even under a large render quantum × rate.
    nonisolated static let maxRenderScratchFloats: Int = 48_000 * 2 * 2

    private var engine: AVAudioEngine?
    private let nativeOutput: AudioNativeOutputBinding
    private var nativeOutputUnavailable = false
    @ObservationIgnored
    private lazy var outputStateNotifier = AudioOutputStateNotifier { [weak self] in
        self?.outputAvailability ?? .stopped
    }
    /// Runtime loss must never inherit the cold-start simulated fallback.
    private var repairingNativeOutput = false
    /// Per-call timing of the latest hardware bring-up (diagnostics only).
    private var bringUpTiming = AudioBringUpTiming(enabled: false)
    private var sourceNode: AVAudioSourceNode?
    /// The connect format and pitch mode of the currently ATTACHED chain —
    /// the reuse-compatibility key for a graph kept across stop()/start()
    /// (or built ahead by `prewarmHardwareGraph`). Cleared on teardown/detach.
    /// Pitch mode is part of the key because it is baked into the source
    /// node's render closure, not just the node topology.
    private var cachedGraphConnectFormat: AVAudioFormat?
    private var cachedGraphPitchMode = false
    /// The render block captures `PlayerLog.isEnabled` at node creation, so a
    /// kept graph freezes that capture. Part of the reuse key: toggling Debug
    /// Logging forces a full rebuild on the next start instead of leaving the
    /// audio-callback diagnostics silently stale for the graph's lifetime.
    private var cachedGraphDiagnosticsEnabled = false
    /// A3c: optional TimePitch unit on the hardware graph (source → pitch → mixer).
    private var timePitchNode: AVAudioUnitTimePitch?
    private var equalizerNode: AVAudioUnitEQ?
    private var equalizerRevision: UInt64 = 0
    private var configuredEqualizerRevision: UInt64?
    private var equalizerHistoryDirty = false
    private var configuredEqualizerBypassed = true
    private var pendingEqualizerReset = false
    private var pendingPitchReset = false
    private var equalizerLatency: AudioProcessingLatency = .bypassed
    private var pitchLatency: AudioProcessingLatency = .bypassed
    private(set) var equalizerStatus: PlayerEqualizerStatus = .retainedNoGraph
    var equalizerConfiguration = PlayerEqualizerConfiguration.defaults {
        didSet {
            guard oldValue != equalizerConfiguration else { return }
            if !oldValue.isBypassed, equalizerConfiguration.isBypassed { equalizerHistoryDirty = true }
            equalizerRevision &+= 1
            if oldValue.isBypassed, !equalizerConfiguration.isBypassed {
                pendingEqualizerReset = equalizerHistoryDirty || equalizerMaintenance != nil
            }
            adoptEqualizerConfiguration()
        }
    }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? {
        didSet { revokeAudioMaintenancePermission() }
    }
    private struct EqualizerMaintenance {
        let serial: UInt64
        let graph: AudioEqualizerNativeGraph
        let seek: MediaAudioSeekToken?
        var permit: AudioMaintenancePermit?
        var retired = false
    }
    private var equalizerMaintenance: EqualizerMaintenance?
    private var nextEqualizerMaintenanceSerial: UInt64 = 0
    private var continuousEqualizerTask: Task<Void, Never>?
    private var deferredAuthorizedOutputTask: Task<Void, Never>?
    private var deferredAuthorizedOutputSerial: UInt64 = 0
    private var deferredAuthorizedOutputPermit: AudioMaintenancePermit?
    private var continuingDeferredAuthorizedOutput = false
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private var hardwareQueueWaiters: [CheckedContinuation<Void, Never>] = []
    private var maintenanceOutputHeld = false
    private var retainedMaintenancePaused = false
    private var seekRequiresEqualizerMaintenance: Bool {
        engine != nil && equalizerNode != nil
            && !nativeOutputUnavailable && !nativeOutput.hasUnresolvedConfiguration
            && (retainedMaintenancePaused || !equalizerConfiguration.isBypassed
                || !configuredEqualizerBypassed || pendingEqualizerReset)
    }
    private var latestParametersRequirePausedReset: Bool { pendingEqualizerReset || pendingPitchReset }
    private var nativeParametersExclusive: Bool {
        hardwareStart.mayReuseEngine && equalizerMaintenance == nil
    }
    /// The two slots live for the entire renderer lifetime. A running seek only
    /// writes the inactive slot and publishes it after target PCM is ready.
    private let ringRouter = PCMFloatRingRouter()
    private let renderDiagnostics = AudioRenderDiagnostics()
    private weak var pullSource: (any AudioPullSource)?
    /// MainActor tick running `reportDrain()` only; ring refill runs off-actor in `feeder`.
    private var drainReportTask: Task<Void, Never>?
    /// The audio-owned ring producer. One per session: `stop()` retires it (a
    /// retired feeder is not resumable) and `start()` builds a fresh one, so a
    /// parked or stopped session cannot leave a producer alive against the
    /// successor's slots.
    private var feeder: AudioRingFeeder?
    private var retiredFeederPullCallCount = 0
    private let rateBox = AtomicFloatBox(1)
    /// What `rateBox` would carry with no hardware-queue work outstanding. The
    /// box itself is written only by `refreshRenderRateBox`, which holds it at
    /// 0 while a start/stop is in flight on `hardwareQueue` — see
    /// `AudioHardwareStartAdmission.renderRate`.
    private var requestedRenderRate: Float = 1
    /// Serial off-main queue for `AVAudioEngine.start()`/`stop()` so hardware bring-up
    /// cannot block the main thread or overtake an in-flight start.
    nonisolated private static let hardwareQueue = DispatchQueue(
        label: "com.swiftpili.patha.audio-hw",
        qos: .userInitiated
    )
    /// Pending/token/outstanding-operation rules for the off-main start.
    private var hardwareStart = AudioHardwareStartAdmission()
    /// Main-actor facts the accepted start needs. Only meaningful while
    /// `hardwareStart.isPending`; cleared by every invalidation.
    private var pendingHardwareStartContext: PendingHardwareStart?
    private struct PendingHardwareStart {
        let connectFormat: AVAudioFormat
        let reusedGraph: Bool
        let nativeStamp: AudioNativeOutputBinding.Stamp
        /// A reused-graph start that fails falls back to the full build (the
        /// synchronous path's behaviour), which needs the session facts the
        /// original install already read — without a second session prepare.
        let sessionSampleRate: Double
        let sessionChannels: Int
        var maintenancePermit: AudioMaintenancePermit?
    }
    private let muteBox = OSAllocatedUnfairLock(initialState: false)
    private let volumeBox = OSAllocatedUnfairLock(initialState: Float(1))
    /// Hardware/TimePitch graph startup can produce a route-negotiation transient.
    /// Keep the mixer silent until the graph is running, then ramp to the requested
    /// gain. This is an output-boundary guard; it does not alter PCM or F1 timing.
    private var mixerRampTask: Task<Void, Never>?
    private static let mixerStartupRampSteps = 5
    private static let mixerStartupRampStep: Duration = .milliseconds(8)

    private(set) var isRunning = false
    private(set) var engineStarted = false
    private(set) var fillOnlyMode = false
    /// True between an async `AVAudioEngine.start()` submission and its
    /// accepted/failed completion on the main actor. While true
    /// `engineStarted == false` and `fillOnlyMode == false`: there is neither a
    /// hardware consumer nor a simulated one, so the media clock holds.
    var hardwareStartPending: Bool { hardwareStart.isPending }
    private(set) var isResamplingToHardware = false
    private(set) var hardwareSampleRate: Double = 0
    /// Pull calls made against the PCM supply, from both entry points: the
    /// synchronous transaction pulls on MainActor and the feeder's own passes.
    /// Both count, because what this answers is "is the ring being fed at all".
    var fillCallCount: Int {
        transactionPullCallCount + retiredFeederPullCallCount + (feeder?.pullCallCount ?? 0)
    }
    private(set) var transactionPullCallCount = 0
    /// Active slot and publication epoch are MainActor-owned. The callback
    /// reads the packed publication and acknowledges it atomically.
    private var activeSlotIndex = 0
    private var activeEpoch: UInt64 = 0
    private var nextPublicationEpoch: UInt64 = 1
    /// Per-slot rendered-frame accounting. Its inputs come from
    /// `PCMFloatRing.drainSnapshot()`; there is deliberately no second counter
    /// mirroring the ring's write cursor, because a mirror is a value that can
    /// disagree with the thing it mirrors.
    private var slotDrainProgress = [AudioDrainProgress(), AudioDrainProgress()]
    private var seekTokenGeneration: UInt64 = 0
    private var activeSeekToken: MediaAudioSeekToken?
    private var stagedSeekSlot: Int?
    private var stagedSeekWasPublished = false
    /// A superseded publication may still be observed by the RT callback after
    /// the backend revokes its token. Keep that slot intact until the callback
    /// acknowledges the exact publication epoch; only then can the slot be
    /// reused by the next latest-wins target.
    private var retiredSeekPublication: AudioRingPublication?
    private var nextSeekGateGeneration: UInt64 = 0
    private var activeSeekGateGeneration: UInt64 = 0
    private var preserveCommittedSlotOnNextStart = false
    private var lastPublishedSeekEpoch: UInt64 = 0
    private var lastAcknowledgedSeekEpoch: UInt64 = 0

    private(set) var seekPublicationCount = 0
    private(set) var seekAcknowledgementCount = 0
    private(set) var seekAbortCount = 0
    private(set) var isSeekOutputGated = false

    /// Wall instant of the last simulated drain (fill-only mode only).
    private var lastDrainWall: ContinuousClock.Instant?
    /// Discard buffer for the fill-only simulated consumer (0.1 s stereo).
    private var drainScratch = [Float](repeating: 0, count: 4_800 * 2)
    /// Published from the source callback through `PCMFloatRing`; read/logged
    /// only on MainActor so the real-time path never formats or emits a log.
    private(set) var sourceUnderflowCount: UInt64 = 0
    private var lastUnderflowLogAt: TimeInterval = 0

    /// Resolved at `start` — whether this session runs the A3c pitch path.
    private(set) var pitchCorrectionActive = false
    /// True when an `AVAudioUnitTimePitch` is attached to the live hardware graph.
    private(set) var timePitchInstalled = false
    /// Last rate applied to TimePitch (or the offline seam when no unit). 1 when bypassed.
    private(set) var timePitchRate: Float = 1
    /// Prefer hard unity (bypass TimePitch) at rate ≈ 1 for bit-identical C2 path.
    private(set) var timePitchBypassed = true
    /// Processing latency reported by the live TimePitch node, in output seconds.
    /// Read only on MainActor; never from the RT source callback.
    private(set) var timePitchProcessingLatencySeconds: TimeInterval = 0
    /// Counts `reset()` / re-apply on seek, stop, media change, and unity rate edges.
    private(set) var timePitchResetCount = 0

    var presentationTiming: MediaAudioPresentationTiming {
        // Diagnostic Logging only: sampled several times per tick and reads native
        // AVAudioNode/AVAudioEngine state, so it is timed on its own.
        let timingSpan = UIHitchMonitor.beginSpan("audio.timing")
        defer { UIHitchMonitor.endSpan(timingSpan) }
        if knownOutputAvailability == .fillOnly {
            cachedOutputLatency = nil
            return .logical
        }
        guard canSamplePresentationTiming, let engine, let sourceNode,
              sourceNode.engine === engine else {
            cachedOutputLatency = nil
            return .unavailable
        }
        let stamp = nativeOutput.stamp
        let rate = appliedOutputRate
        let processing = pitchLatency.wallSeconds + equalizerLatency.wallSeconds
        let now = ProcessInfo.processInfo.systemUptime
        // Cache `outputPresentationLatency` across unchanged graph inputs within
        // `outputLatencyMaxAge` (0.5 s) so repeated per-tick reads avoid CoreAudio queries.
        if let cached = cachedOutputLatency,
           cached.matches(
               stamp: stamp, rate: rate, engine: engine, sourceNode: sourceNode,
               processing: processing, equalizerRevision: configuredEqualizerRevision
           ),
           now - cached.sampledAt < Self.outputLatencyMaxAge {
            return MediaAudioPresentationTiming(
                outputLatency: cached.seconds, processingLatency: processing, appliedRate: rate
            )
        }
        // This cumulative boundary already includes downstream TimePitch/EQ and
        // the device. Fetch when needed; never add an overlapping latency sum.
        let latencySpan = UIHitchMonitor.beginSpan("audio.latency")
        let outputLatency = sourceNode.outputPresentationLatency
        UIHitchMonitor.endSpan(latencySpan)
        guard nativeOutput.isCurrent(stamp), canSamplePresentationTiming,
              self.engine === engine, self.sourceNode === sourceNode,
              sourceNode.engine === engine, appliedOutputRate == rate else {
            cachedOutputLatency = nil
            return .unavailable
        }
        cachedOutputLatency = CachedOutputLatency(
            seconds: outputLatency, sampledAt: now, stamp: stamp, rate: rate,
            engine: ObjectIdentifier(engine), sourceNode: ObjectIdentifier(sourceNode),
            processing: processing, equalizerRevision: configuredEqualizerRevision
        )
        return MediaAudioPresentationTiming(
            outputLatency: outputLatency, processingLatency: processing, appliedRate: rate
        )
    }

    /// Last `outputPresentationLatency` read and every input it was valid for.
    /// MainActor only; dropped whenever the getter reports anything but a
    /// fresh, validated output pipeline.
    private struct CachedOutputLatency {
        let seconds: TimeInterval
        let sampledAt: TimeInterval
        let stamp: AudioNativeOutputBinding.Stamp
        let rate: Float
        let engine: ObjectIdentifier
        let sourceNode: ObjectIdentifier
        let processing: TimeInterval
        let equalizerRevision: UInt64?

        func matches(
            stamp: AudioNativeOutputBinding.Stamp, rate: Float, engine: AVAudioEngine,
            sourceNode: AVAudioSourceNode, processing: TimeInterval, equalizerRevision: UInt64?
        ) -> Bool {
            self.stamp.binding == stamp.binding && self.stamp.revision == stamp.revision
                && self.rate == rate && self.engine == ObjectIdentifier(engine)
                && self.sourceNode == ObjectIdentifier(sourceNode)
                && self.processing == processing && self.equalizerRevision == equalizerRevision
        }
    }

    private var cachedOutputLatency: CachedOutputLatency?
    private static let outputLatencyMaxAge: TimeInterval = 0.5

    private var canSamplePresentationTiming: Bool {
        knownOutputAvailability == .available && engineStarted && nativeParametersExclusive
            && configuredEqualizerRevision == equalizerRevision
            && cachedGraphPitchMode == pitchCorrectionActive
            && !nativeOutput.hasUnresolvedConfiguration && nativeOutput.reportsRunning
    }

    private var appliedOutputRate: Float {
        pitchCorrectionActive ? (timePitchBypassed ? 1 : timePitchRate) : max(0, requestedRenderRate)
    }

    var launchReserveContentSeconds: TimeInterval {
        AudioRingReserve.contentSeconds(forRate: playbackRate)
    }

    var seekTransitionReserveContentSeconds: TimeInterval {
        AudioRingReserve.contentSeconds(forRate: max(playbackRate, 1))
    }

    var preferHardwareGraph = false
    var playbackRate: Float = 1 {
        didSet {
            applyPlaybackRate(max(0, playbackRate), previous: max(0, oldValue))
        }
    }
    var volume: Float = 1 {
        didSet {
            let v = max(0, min(volume, 1))
            volumeBox.withLock { $0 = v }
            applyMixerGain()
        }
    }
    var isMuted = false {
        didSet {
            let m = isMuted
            muteBox.withLock { $0 = m }
            applyMixerGain()
        }
    }
    var fillPeriod: TimeInterval = EngineAudioRenderer.defaultFillPeriod

    /// MainActor drain-report scheduling state. Bounded to five reports per
    /// `start()` so a pathological session cannot spam the log. This does not
    /// describe the feeder's cadence or an audible outage.
    private var lastDrainReportAt: ContinuousClock.Instant?
    private var lastDrainReportDiagnostics: AudioRenderDiagnosticsSnapshot?
    private var lastDrainReportFeederPullCalls: Int?
    private var lastDrainReportShortReadCount: UInt64?
    private var drainReportGapLogCount = 0

    var renderRingContentSeconds: TimeInterval {
        ringRouter.ring(at: activeSlotIndex).contentSeconds(
            sampleRate: Self.engineSampleRate,
            channels: Self.engineChannels
        )
    }

    var renderDiagnosticsSnapshot: AudioRenderDiagnosticsSnapshot {
        renderDiagnostics.snapshot()
    }

    func start(source: AudioPullSource) throws {
        defer { noteOutputStateChange() }
        let deferredForMaintenance = equalizerMaintenance != nil
        let preserveCommittedContent = preserveCommittedSlotOnNextStart
        stop(preserveCommittedContent: preserveCommittedContent)
        // A gap measured across a stop/start is outside one report session, and
        // each session gets its own scheduling-gap budget.
        resetDrainReportSession()
        pullSource = source
        pitchCorrectionActive = PathAPitchFlag.isEnabled()
        let initialRate = max(0, playbackRate)
        let initialVolume = max(0, min(volume, 1))
        let initialMute = isMuted
        // Pitch path: source feeds content at unity; TimePitch owns rate.
        // Explicit rollback: rateBox drives the historical varispeed RT stride.
        setRenderRate(pitchCorrectionActive
            ? (initialRate <= 0.000_1 ? 0 : 1)
            : initialRate)
        volumeBox.withLock { $0 = initialVolume }
        muteBox.withLock { $0 = initialMute }
        renderDiagnostics.reset()
        if !preserveCommittedContent {
            ringRouter.resetForLifecycle()
            activeSlotIndex = 0
            activeEpoch = 0
            nextPublicationEpoch = 1
            slotDrainProgress = [AudioDrainProgress(), AudioDrainProgress()]
            lastPublishedSeekEpoch = 0
            lastAcknowledgedSeekEpoch = 0
            retiredSeekPublication = nil
        }
        sourceUnderflowCount = 0
        lastUnderflowLogAt = 0
        lastDrainWall = ContinuousClock.now
        fillOnlyMode = true
        engineStarted = false
        isResamplingToHardware = false
        hardwareSampleRate = 0
        timePitchInstalled = false
        timePitchProcessingLatencySeconds = 0
        timePitchResetCount = 0
        applyTimePitchRate(initialRate, resetUnit: false)
        isSeekOutputGated = false
        ringRouter.setOutputGated(false)
        fillRingTowardReserve(source: source, slotIndex: activeSlotIndex)
        PlayerLog.log(
            "[PathA] A3c pitch-correct \(pitchCorrectionActive ? "ON" : "OFF") " +
            "(default on; PATHA_PITCH=0 rollback)"
        )
        #if targetEnvironment(simulator)
        PlayerLog.log("[PathA] audio render start fill-only (no hardware graph)")
        #else
        if preferHardwareGraph {
            installHardwareGraphBestEffort()
        } else {
            PlayerLog.log("[PathA] audio render start fill-only (no hardware graph)")
        }
        #endif
        isRunning = true
        startDrainReportTask()
        startFeeder(source: source)
        if equalizerNode == nil { adoptEqualizerConfiguration() }
        if deferredForMaintenance { deferAuthorizedOutputUntilMaintenanceSettles(source: source) }
    }

    private func resetDrainReportSession() {
        lastDrainReportAt = nil
        lastDrainReportDiagnostics = nil
        lastDrainReportFeederPullCalls = nil
        lastDrainReportShortReadCount = nil
        drainReportGapLogCount = 0
    }

    var outputAvailability: MediaAudioOutputAvailability {
        let known = knownOutputAvailability
        if known != .stopped, known != .pending { sampleNativeOutputAvailability() }
        noteOutputStateChange()
        return knownOutputAvailability
    }

    private var knownOutputAvailability: MediaAudioOutputAvailability {
        guard isRunning else { return .stopped }
        if maintenanceOutputHeld || hardwareStart.isPending || !hardwareStart.mayReuseEngine { return .pending }
        if retainedMaintenancePaused || nativeOutputUnavailable || nativeOutput.hasUnresolvedConfiguration {
            return .unavailable
        }
        return fillOnlyMode ? .fillOnly : .available
    }

    /// True while the active ring slot still holds undrained PCM. Used only to
    /// adjudicate end-of-stream drain (audit finding #1): the feeder requests
    /// ring *room*, so a feeder underrun at EOF does not mean the ring is
    /// empty — the render callback may still have up to the ring reserve left
    /// to play out.
    var hasPendingOutput: Bool {
        ringRouter.ring(at: activeSlotIndex)
            .drainSnapshot(channels: Self.engineChannels)
            .pendingFrames > 0
    }

    func setOutputStateChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        outputStateNotifier.setHandler(handler)
        noteOutputStateChange()
    }

    private func noteOutputStateChange() {
        outputStateNotifier.note(knownOutputAvailability)
    }

    private func sampleNativeOutputAvailability() {
        guard nativeParametersExclusive, !retainedMaintenancePaused else { return }
        let stoppedNativeConsumer = engineStarted && !fillOnlyMode && !nativeOutput.reportsRunning
        guard nativeOutput.hasUnresolvedConfiguration || stoppedNativeConsumer else { return }
        noteNativeOutputUnavailable()
    }

    private func noteNativeOutputUnavailable() {
        // Keep logical transport and PCM ownership. Only an admitted Play may
        // prepare/start replacement hardware; the observer publishes no effect.
        revokeAudioMaintenancePermission()
        equalizerLatency = .unreported
        pitchLatency = .unreported
        nativeOutputUnavailable = true
        hardwareStart.invalidate()
        pendingHardwareStartContext = nil
        mixerRampTask?.cancel()
        mixerRampTask = nil
        refreshRenderRateBox()
    }

    private func bindNativeOutput(_ eng: AVAudioEngine) {
        bindNativeOutput(object: eng, nativeIsRunning: { [weak eng] in eng?.isRunning ?? false })
    }

    /// Production object/status binding; fixture objects exercise exactly the
    /// same observer delivery without constructing Simulator audio hardware.
    func bindNativeOutput(object: AnyObject, nativeIsRunning: @escaping @MainActor () -> Bool) {
        nativeOutput.bind(
            object: object,
            notification: .AVAudioEngineConfigurationChange,
            nativeIsRunning: nativeIsRunning,
            onInvalidation: { [weak self] in
                guard let self else { return }
                // A stopped/prewarmed graph has no transport permission either.
                if self.isRunning || self.hardwareStart.isPending {
                    self.noteNativeOutputUnavailable()
                }
            }
        )
    }

    func reconcileOutputForAuthorizedPlayback() throws {
        if equalizerMaintenance != nil, let source = pullSource {
            deferAuthorizedOutputUntilMaintenanceSettles(source: source)
            return
        }
        guard outputAvailability == .unavailable else { return }
        repairingNativeOutput = true
        // This is graph-only teardown: feeder, slots, publications, drain
        // epochs, source and F1 are untouched. No session activation here.
        teardownHardwareGraph()
        fillOnlyMode = false
        let session = AVAudioSession.sharedInstance()
        installFreshHardwareGraph(
            sessionSampleRate: session.sampleRate,
            sessionChannels: session.outputNumberOfChannels,
            startMode: AudioHardwareStartMode.resolve(environment: ProcessInfo.processInfo.environment)
        )
        refreshRenderRateBox()
    }

    init(notificationCenter: NotificationCenter = .default) {
        nativeOutput = AudioNativeOutputBinding(notificationCenter: notificationCenter)
    }

    private var seekLaunchReserveFrames: Int {
        Int((seekTransitionReserveContentSeconds * Self.engineSampleRate).rounded(.up))
    }

    /// False while a hardware start is pending, so seek publication keeps its
    /// synchronous acknowledgement (design §7). The render callback may already
    /// be firing in that window; it is held at rate 0 and reads nothing.
    private var hasRealtimeConsumer: Bool {
        sampleNativeOutputAvailability()
        return AudioHardwareStartAdmission.hasRealtimeConsumer(
            isRunning: isRunning,
            engineStarted: engineStarted,
            fillOnlyMode: fillOnlyMode,
            startPending: hardwareStart.isPending,
            nativeOutputUnavailable: nativeOutputUnavailable,
            queueOutstanding: maintenanceOutputHeld || retainedMaintenancePaused || !hardwareStart.mayReuseEngine
        )
    }

    private func assertSeekOutputGate() {
        // Superseding a transaction while its gate is already closed does not
        // need a second RT fence. Keeping one generation lets the next target
        // reuse the retired slot immediately after the existing gated
        // callback boundary; incrementing here would create an artificial
        // prepare-not-ready race before the next callback quantum.
        guard !isSeekOutputGated, !maintenanceOutputHeld, !retainedMaintenancePaused else { return }
        nextSeekGateGeneration &+= 1
        activeSeekGateGeneration = nextSeekGateGeneration
        ringRouter.setOutputGated(true, generation: activeSeekGateGeneration)
        if !hasRealtimeConsumer {
            ringRouter.acknowledgeOutputGateSynchronously()
        }
        isSeekOutputGated = true
    }

    private func isSeekGateAcknowledged(for publication: AudioRingPublication) -> Bool {
        !hasRealtimeConsumer
            || ringRouter.isOutputGateAcknowledged(
                generation: activeSeekGateGeneration,
                publication: publication
            )
    }

    private func isSeekPublicationAcknowledged(_ publication: AudioRingPublication) -> Bool {
        ringRouter.acknowledgedPublication() == publication
            && isSeekGateAcknowledged(for: publication)
    }

    /// A currently published slot is reusable only after the callback has
    /// acknowledged the exact pair and, for a running graph, the asserted
    /// gate boundary. Comparing only slot indexes is insufficient: the same
    /// slot is intentionally reused across different publication epochs.
    private func canReuseSeekSlot(_ slot: Int) -> Bool {
        guard slot == 0 || slot == 1, slot != activeSlotIndex else { return false }
        let publication = ringRouter.publishedPublication()
        if hasRealtimeConsumer {
            // If the published pair points at this slot, it may have been read
            // by an in-flight quantum. Reuse requires a callback boundary that
            // observed the asserted gate after that quantum completed.
            if publication.slot == slot {
                return isSeekOutputGated && isSeekGateAcknowledged(for: publication)
            }
            // The other slot is not named by the current publication, so it is
            // private staging storage even if the pair acknowledgement is
            // still catching up.
            return true
        }
        return ringRouter.acknowledgedPublication() == publication
    }

    /// Reclaim a superseded published slot once its callback boundary is known
    /// to be past. In fill-only/stopped mode there is no RT consumer, so the
    /// logical acknowledgement is synchronous just like commit's fill-only
    /// path.
    private func reclaimRetiredSeekPublicationIfSafe() {
        guard let retired = retiredSeekPublication else { return }
        let acknowledged = ringRouter.acknowledgedPublication()
        guard acknowledged == retired,
              isSeekGateAcknowledged(for: retired)
                || !hasRealtimeConsumer
        else { return }

        let slot = retired.slot
        ringRouter.ring(at: slot).reset()
        slotDrainProgress[slot].reset()
        retiredSeekPublication = nil

        if !hasRealtimeConsumer {
            let active = AudioRingPublication(slot: activeSlotIndex, epoch: activeEpoch)
            ringRouter.publish(active)
            ringRouter.acknowledgePublishedPublication()
        }
    }

    func beginSeekTransition(source: AudioPullSource) -> MediaAudioSeekToken {
        revokeAudioMaintenancePermission()
        equalizerHistoryDirty = true
        pullSource = source
        seekTokenGeneration &+= 1
        let token = MediaAudioSeekToken(generation: seekTokenGeneration)

        // The transaction CUTS the feeder OVER rather than cooperating with it, and
        // it stays stood down for the whole transaction — including across
        // `commitSeekTransition`'s acknowledgement await. During a seek the ring is
        // filled by MainActor exactly as it was before this move, which is
        // acceptable because a seek already asserts the output gate (silence), so
        // a MainActor stall inside a seek creates no new audible artifact.
        standDownFeederForTransaction()

        assertSeekOutputGate()
        // The old content is no longer admissible for this seek even when its
        // native slot must wait for callback acknowledgement before reset.
        ringRouter.ring(at: 0).retireDisplayContent()
        ringRouter.ring(at: 1).retireDisplayContent()
        reclaimRetiredSeekPublicationIfSafe()

        // A superseded preparation is private staging. It is safe to retire it
        // before a new publication because the callback still owns the active
        // slot and the output gate is already asserted.
        if let oldSlot = stagedSeekSlot, !stagedSeekWasPublished {
            if canReuseSeekSlot(oldSlot) {
                ringRouter.ring(at: oldSlot).reset()
                slotDrainProgress[oldSlot].reset()
            }
        }

        let inactiveSlot = 1 - activeSlotIndex
        stagedSeekSlot = inactiveSlot
        stagedSeekWasPublished = false
        activeSeekToken = token
        lastDrainWall = ContinuousClock.now

        // If the previous callback has not acknowledged the exact published
        // epoch, the inactive slot is not reusable yet. Preparation fails
        // closed rather than resetting memory that an RT callback could still
        // be reading.
        if canReuseSeekSlot(inactiveSlot) {
            ringRouter.ring(at: inactiveSlot).reset()
            slotDrainProgress[inactiveSlot].reset()
        }
        return token
    }

    func prepareSeekTransition(
        _ token: MediaAudioSeekToken,
        source: AudioPullSource
    ) -> MediaAudioSeekPreparation {
        guard activeSeekToken == token,
              let slot = stagedSeekSlot,
              !stagedSeekWasPublished,
              canReuseSeekSlot(slot)
        else {
            return MediaAudioSeekPreparation(
                token: token,
                stagedContentSeconds: 0,
                isReady: false
            )
        }

        let targetFrames = seekLaunchReserveFrames
        var stagedFrames = ringRouter.ring(at: slot).frameCount
        var noProgress = 0
        while stagedFrames < targetFrames, noProgress < 3 {
            let requestFrames = targetFrames - stagedFrames
            let sampleCount = requestFrames * Self.engineChannels
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            buffer.initialize(repeating: 0, count: sampleCount)
            let result = source.pullPCM(
                frameCount: requestFrames,
                sampleRate: Self.engineSampleRate,
                channels: Self.engineChannels,
                into: buffer
            )
            let frames = max(0, min(result.frames, requestFrames))
            let written = ringRouter.ring(at: slot).write(
                buffer,
                count: frames * Self.engineChannels,
                displaySpans: result.displaySpans,
                sampleRate: Self.engineSampleRate,
                channels: Self.engineChannels
            ) / Self.engineChannels
            buffer.deallocate()
            transactionPullCallCount += 1
            stagedFrames += written
            noProgress = written == 0 ? noProgress + 1 : 0
        }

        let seconds = TimeInterval(stagedFrames) / Self.engineSampleRate
        return MediaAudioSeekPreparation(
            token: token,
            stagedContentSeconds: seconds,
            isReady: stagedFrames >= targetFrames
        )
    }

    func commitSeekTransition(_ token: MediaAudioSeekToken) async -> Bool {
        await commitSeekTransition(
            token,
            isAuthorized: nil,
            beforeGateRelease: nil
        )
    }

    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool {
        await commitSeekTransition(
            token,
            isAuthorized: isAuthorized,
            beforeGateRelease: nil
        )
    }

    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool {
        await commitSeekTransition(
            token, isAuthorized: isAuthorized, resumesPlayback: isRunning,
            resumeAdmission: { [weak self] in self?.audioMaintenanceAdmission?() },
            beforeGateRelease: beforeGateRelease
        )
    }

    func commitSeekTransition(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        resumesPlayback: Bool,
        resumeAdmission: @escaping @MainActor () -> AudioMaintenancePermit?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool {
        let committed = await commitSeekWithEqualizerMaintenance(
            token, isAuthorized: isAuthorized, resumesPlayback: resumesPlayback,
            resumeAdmission: resumeAdmission, beforeGateRelease: beforeGateRelease
        )
        if let operation = equalizerMaintenance, operation.seek == token {
            await finishRejectedMaintenance(operation.serial)
        }
        return committed
    }

    private func commitSeekWithEqualizerMaintenance(
        _ token: MediaAudioSeekToken,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        resumesPlayback: Bool,
        resumeAdmission: @escaping @MainActor () -> AudioMaintenancePermit?,
        beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) async -> Bool {
        guard let slot = currentUnpublishedSeekSlot(token) else { return false }

        guard isAuthorized?() ?? true else {
            abortSeekTransition(token)
            return false
        }

        await awaitAudioMaintenanceSettlement()
        sampleNativeOutputAvailability()
        guard seekRequestIsCurrent(token, slot: slot, isAuthorized: isAuthorized) else { return false }
        let needsMaintenance = seekRequiresEqualizerMaintenance
        var maintenanceSerial: UInt64?
        if needsMaintenance {
            guard let serial = reserveEqualizerMaintenance(seek: token) else { return false }
            maintenanceSerial = serial
            guard await pauseAndConfigureEqualizer(serial, isAuthorized: isAuthorized) else {
                await finishRejectedMaintenance(serial)
                abortSeekTransition(token)
                return false
            }
        }

        guard let publication = await publishAndAcknowledgeSeek(slot: slot, token: token) else { return false }

        // A superseded commit can be waiting here after its token was revoked.
        // Reclaim its slot only after the callback has acknowledged the exact
        // publication; this is the handoff that makes rapid latest-wins seeks
        // safe with exactly two slots.
        reclaimRetiredSeekPublicationIfSafe()

        // Keep the output gate asserted until the backend's authority is still
        // valid after the callback boundary. Without this second check, a new
        // seek could arrive after acknowledgement but before the MainActor
        // resumed and briefly expose the superseded slot to the speaker.
        guard isAuthorized?() ?? true else {
            abortSeekTransition(token)
            return false
        }

        guard await resumeSeekEqualizerIfNeeded(
            maintenanceSerial, token: token, resumesPlayback: resumesPlayback,
            isAuthorized: isAuthorized, resumeAdmission: resumeAdmission
        ) else { return false }

        // The acknowledgement may have arrived while this MainActor task was
        // suspended. A superseding seek can abort/re-publish during that gap;
        // never promote the old slot after that abort has invalidated its token.
        guard currentSeekPublicationCanPromote(publication, token: token, slot: slot) else { return false }

        return finishCurrentSeekPublication(
            publication, token: token, slot: slot, maintenanceSerial: maintenanceSerial,
            beforeGateRelease: beforeGateRelease
        )
    }

    private func resumeSeekEqualizerIfNeeded(
        _ serial: UInt64?, token: MediaAudioSeekToken, resumesPlayback: Bool,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        resumeAdmission: @escaping @MainActor () -> AudioMaintenancePermit?
    ) async -> Bool {
        guard let serial else { return true }
        guard await resumeEqualizerMaintenance(
            serial, resumesPlayback: resumesPlayback, isAuthorized: isAuthorized, resumeAdmission: resumeAdmission
        ) else {
            await finishRejectedMaintenance(serial)
            abortSeekTransition(token)
            return false
        }
        return true
    }

    private func currentSeekPublicationCanPromote(
        _ publication: AudioRingPublication, token: MediaAudioSeekToken, slot: Int
    ) -> Bool {
        activeSeekToken == token && stagedSeekSlot == slot && stagedSeekWasPublished
            && ringRouter.publishedPublication() == publication && isSeekPublicationAcknowledged(publication)
    }

    private func currentUnpublishedSeekSlot(_ token: MediaAudioSeekToken) -> Int? {
        guard activeSeekToken == token, !stagedSeekWasPublished else { return nil }
        return stagedSeekSlot
    }

    private func seekRequestIsCurrent(
        _ token: MediaAudioSeekToken, slot: Int, isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) -> Bool {
        activeSeekToken == token && stagedSeekSlot == slot && !Task.isCancelled && (isAuthorized?() ?? true)
    }

    private func publishAndAcknowledgeSeek(slot: Int, token: MediaAudioSeekToken) async -> AudioRingPublication? {
        let publication = AudioRingPublication(slot: slot, epoch: nextPublicationEpoch)
        nextPublicationEpoch &+= 1
        stagedSeekWasPublished = true
        ringRouter.publish(publication)
        lastPublishedSeekEpoch = publication.epoch
        seekPublicationCount += 1
        if !hasRealtimeConsumer {
            ringRouter.acknowledgePublishedPublication()
            ringRouter.acknowledgeOutputGateSynchronously()
        } else if !(await awaitSeekAcknowledgement(publication)) {
            abortSeekTransition(token)
            return nil
        }
        return publication
    }

    private func finishCurrentSeekPublication(
        _ publication: AudioRingPublication, token: MediaAudioSeekToken, slot: Int,
        maintenanceSerial: UInt64?, beforeGateRelease: (@MainActor @Sendable () -> Void)?
    ) -> Bool {
        lastAcknowledgedSeekEpoch = publication.epoch
        seekAcknowledgementCount += 1
        activeSlotIndex = slot
        activeEpoch = publication.epoch
        // The staged frames are all still pending at the callback boundary.
        // Rebase this epoch at zero rendered frames; only later drain may report
        // F1 to the session.
        slotDrainProgress[slot].reset()
        lastDrainWall = ContinuousClock.now
        preserveCommittedSlotOnNextStart = !isRunning
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false

        // Unity bypass has no stretcher state to clear. At non-unity, reset and
        // reapply while the output gate remains asserted; the gate is released
        // only after the callback has acknowledged the new slot.
        if maintenanceSerial == nil, pitchCorrectionActive, !timePitchBypassed {
            if nativeOutputUnavailable || nativeOutput.hasUnresolvedConfiguration {
                pendingPitchReset = true
            } else {
                resetTimePitchState()
            }
        }
        // The session clears its F1 fence synchronously here, immediately
        // before the output gate opens. This closes the tiny ordering window
        // in which target PCM could be drained/heard but rejected by the
        // session's `isSeekInFlight` guard.
        beforeGateRelease?()
        if let serial = maintenanceSerial { releaseEqualizerMaintenance(serial, accepted: true) }
        ringRouter.setOutputGated(false)
        isSeekOutputGated = false
        // Only now, with the new slot active and the gate released, may the feeder
        // resume — into the slot the callback is reading.
        syncFeederAdmission()
        return true
    }
    private func awaitSeekAcknowledgement(_ publication: AudioRingPublication) async -> Bool {
        for _ in 0..<60 {
            let current = ringRouter.acknowledgedPublication()
            if current == publication, isSeekGateAcknowledged(for: publication) { break }
            if !hasRealtimeConsumer {
                ringRouter.acknowledgePublishedPublication()
                ringRouter.acknowledgeOutputGateSynchronously()
                break
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isSeekPublicationAcknowledged(publication)
    }

    func abortSeekTransition(_ token: MediaAudioSeekToken) {
        if equalizerMaintenance?.seek == token { revokeAudioMaintenancePermission() }
        guard activeSeekToken == token else { return }
        standDownFeederForTransaction()
        seekAbortCount += 1
        if let slot = stagedSeekSlot {
            if stagedSeekWasPublished {
                let publication = ringRouter.publishedPublication()
                // Keep the published slot intact until the callback observes
                // this exact epoch. The output gate is already asserted, so it
                // cannot drain stale PCM while the retired slot is waiting.
                retiredSeekPublication = publication
                reclaimRetiredSeekPublicationIfSafe()
            } else {
                if canReuseSeekSlot(slot) {
                    ringRouter.ring(at: slot).reset()
                    slotDrainProgress[slot].reset()
                }
            }
        }
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false
        // Keep the gate asserted. Backend supersession starts the next
        // transaction immediately; stop/open lifecycle cleanup releases it.
        isSeekOutputGated = true
        ringRouter.setOutputGated(true, generation: activeSeekGateGeneration)
    }

    @discardableResult
    private func preparePlaybackSessionBestEffort() -> (sampleRate: Double, channels: Int)? {
        let session = AVAudioSession.sharedInstance()
        do {
            try bringUpTiming.measure(.category) {
                try PlayerAudioSessionActivation.configure()
            }
            bringUpTiming.measure(.preferred) {
                try? session.setPreferredSampleRate(Self.engineSampleRate)
                try? session.setPreferredOutputNumberOfChannels(Self.engineChannels)
            }
            try bringUpTiming.measure(.activate) {
                try PlayerAudioSessionActivation.activate()
            }
            return (session.sampleRate, session.outputNumberOfChannels)
        } catch {
            let failure = error as NSError
            PlayerLog.log("[PathA] AVAudioSession activation failed domain=\(failure.domain) code=\(failure.code)")
            // A device that failed to activate has no native consumer. Keep
            // PCM and the clock held; the App observes unavailable output and
            // owns any checked continuation of the user's playback request.
            noteNativeOutputUnavailable()
            return nil
        }
    }

    /// Build and PREPARE the hardware graph without starting it. Called from
    /// the session's open so the expensive share of audio bring-up
    /// (AVAudioSession activation, engine build, `prepare()` — the measured
    /// demand-play-started → demand-audio-graph-ready Δ) runs while the open
    /// prime is waiting on the network; `start(source:)` then takes the
    /// reuse fast path and pays only `eng.start()`. A prepared-but-unstarted
    /// engine's render callback cannot fire, so no ring, drain, or clock
    /// state is touched. No-op when a graph already exists, while running,
    /// and on the fill-only/simulator paths. The post-prepare sample-rate
    /// flip case is deliberately NOT handled here — the fast path re-probes
    /// the live rate and falls back to the full build on a mismatch.
    func prewarmHardwareGraph() {
        #if targetEnvironment(simulator)
        return
        #else
        guard preferHardwareGraph, !isRunning, engine == nil else { return }
        if ExperimentalSettingsPolicy.isAllowed(.diagnostics),
           ProcessInfo.processInfo.environment["PATHA_AUDIO_HW"] == "0" { return }
        pitchCorrectionActive = PathAPitchFlag.isEnabled()
        guard let sessionInfo = preparePlaybackSessionBestEffort() else { return }
        let eng = AVAudioEngine()
        engine = eng
        bindNativeOutput(eng)
        guard let connectFormat = resolveHardwareConnectFormat(
            engine: eng,
            sessionSampleRate: sessionInfo.sampleRate,
            sessionChannels: sessionInfo.channels
        ) else {
            teardownHardwareGraph()
            return
        }
        _ = attachSourceChain(engine: eng, connectFormat: connectFormat)
        prepareMixerForGraphStart()
        eng.prepare()
        PlayerLog.log(
            "[PathA] audio graph prewarmed sr=\(String(format: "%.0f", connectFormat.sampleRate)) " +
            "pitch=\(pitchCorrectionActive ? 1 : 0)"
        )
        #endif
    }

    private func teardownHardwareGraph() {
        // Whatever start is in flight loses its authority first: its completion
        // must find the engine gone and publish nothing.
        if continuingDeferredAuthorizedOutput {
            equalizerMaintenance?.permit?.revoke()
            if equalizerMaintenance != nil { equalizerMaintenance?.retired = true }
        } else {
            revokeAudioMaintenancePermission()
        }
        hardwareStart.invalidate()
        pendingHardwareStartContext = nil
        nativeOutput.retire()
        if let eng = engine {
            // Stop at silence so route teardown cannot turn the last non-zero
            // render quantum into a click/pop on the physical output.
            if nativeParametersExclusive {
                eng.mainMixerNode.outputVolume = 0
                if eng.isRunning { eng.stop() }
                if let equalizer = equalizerNode {
                    eng.disconnectNodeOutput(equalizer)
                    eng.detach(equalizer)
                }
                // Detach TimePitch before source so the chain tears down cleanly.
                if let pitch = timePitchNode {
                    eng.disconnectNodeOutput(pitch)
                    eng.detach(pitch)
                }
                if let node = sourceNode {
                    eng.disconnectNodeOutput(node)
                    eng.detach(node)
                }
            } else {
                // A start (or a stop queued behind one) still owns this engine
                // on `hardwareQueue`. A main-actor `stop()` could run BEFORE that
                // start and leave the engine running with nobody holding it, and
                // detaching nodes would race the start on the same instance. The
                // whole teardown goes behind it instead; main does not wait.
                let chain: [AVAudioNode?] = [equalizerNode, timePitchNode, sourceNode]
                enqueueHardwareStop(eng, detaching: chain.compactMap { $0 })
            }
        }
        retireEqualizerGraph()
        timePitchNode = nil
        timePitchInstalled = false
        timePitchProcessingLatencySeconds = 0
        sourceNode = nil
        engine = nil
        cachedGraphConnectFormat = nil
        cachedGraphPitchMode = false
        engineStarted = false
        fillOnlyMode = !nativeOutputUnavailable
        isResamplingToHardware = false
        hardwareSampleRate = 0
    }

    private func softFailHardware(reason: String, allowsLogicalOutput: Bool = false) {
        if !allowsLogicalOutput || repairingNativeOutput || nativeOutput.hasUnresolvedConfiguration {
            nativeOutputUnavailable = true
        }
        teardownHardwareGraph()
        refreshRenderRateBox()
        let disposition = nativeOutputUnavailable ? "unavailable (clock held)" : "fill-only"
        PlayerLog.log("[PathA] AVAudioEngine hardware soft-fail → \(disposition): \(reason)")
    }

    private func resolveHardwareConnectFormat(
        engine: AVAudioEngine,
        sessionSampleRate: Double,
        sessionChannels: Int
    ) -> AVAudioFormat? {
        let mixerFmt = engine.mainMixerNode.outputFormat(forBus: 0)
        let outputInFmt = engine.outputNode.inputFormat(forBus: 0)
        let native = [outputInFmt, mixerFmt].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 })
        let hwSR = native?.sampleRate ?? sessionSampleRate
        let hwCh = Int(native?.channelCount ?? 0)
        let resolvedCh = hwCh > 0 ? hwCh : max(sessionChannels, 0)
        PlayerLog.log(
            "[PathA] audio HW native format sr=\(String(format: "%.0f", hwSR)) ch=\(resolvedCh)"
        )
        guard hwSR > 0, resolvedCh == 1 || resolvedCh == 2 else { return nil }
        if abs(hwSR - Self.engineSampleRate) >= 1.0 {
            PlayerLog.log(
                "[PathA] audio HW sampleRate mismatch ring=\(Int(Self.engineSampleRate)) " +
                "hw=\(Int(hwSR.rounded())) — linear resample in source callback"
            )
        }
        if let native,
           native.commonFormat == .pcmFormatFloat32,
           !native.isInterleaved,
           Int(native.channelCount) == 1 || Int(native.channelCount) == 2 {
            return native
        }
        let connectChannels = resolvedCh == 1 ? 1 : Self.engineChannels
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwSR,
            channels: AVAudioChannelCount(connectChannels),
            interleaved: false
        )
    }

    private func prepareRetainedHardwareGraph(_ eng: AVAudioEngine) {
        prepareMixerForGraphStart()
        resetStoppedEqualizerGraph()
        applyTimePitchRate(max(0, playbackRate), resetUnit: true)
        pendingPitchReset = false
        bringUpTiming.measure(.prepare) { eng.prepare() }
    }

    private func installHardwareGraphBestEffort() {
        guard equalizerMaintenance == nil else { return }
        bringUpTiming = AudioBringUpTiming(enabled: PlayerLog.isCapturing)
        let startMode = AudioHardwareStartMode.resolve(environment: ProcessInfo.processInfo.environment)
        bringUpTiming.mode = startMode.rawValue
        // An async start logs once, from its completion, so `start=` is the
        // time `start()` actually took on `hardwareQueue`.
        defer {
            if !hardwareStart.isPending { bringUpTiming.log() }
        }
        if ExperimentalSettingsPolicy.isAllowed(.diagnostics),
           ProcessInfo.processInfo.environment["PATHA_AUDIO_HW"] == "0" {
            softFailHardware(reason: "PATHA_AUDIO_HW=0", allowsLogicalOutput: true)
            return
        }
        // One session prepare serves both paths below — a compat-miss start
        // used to pay it twice back-to-back (review F3).
        guard let sessionInfo = preparePlaybackSessionBestEffort() else { return }
        reuseOrInstallHardwareGraph(sessionInfo: sessionInfo, startMode: startMode)
    }

    private func reuseOrInstallHardwareGraph(
        sessionInfo: (sampleRate: Double, channels: Int),
        startMode: AudioHardwareStartMode
    ) {
        // Fast path: a graph kept across stop() (or built ahead by
        // `prewarmHardwareGraph`) restarts without alloc/attach/prepare —
        // valid only while the live route still matches its connect format,
        // the pitch mode it was built with, and the diagnostics capture baked
        // into its render block. Any miss falls through to the full build.
        if let eng = engine, let cachedFormat = cachedGraphConnectFormat,
           cachedGraphPitchMode == pitchCorrectionActive,
           cachedGraphDiagnosticsEnabled == PlayerLog.isEnabled {
            // An engine the hardware queue still owns (a stop taken while its
            // start was in flight, still draining) is not the main actor's to
            // `prepare()`: that would race `start()`/`stop()` on the same
            // instance. Build a fresh one; the old one is torn down behind its
            // own queued work. Never true under `PATHA_AUDIO_ASYNC_START=0`.
            if hardwareStart.mayReuseEngine {
                bringUpTiming.path = "reused"
                let stamp = nativeOutput.stamp
                prepareRetainedHardwareGraph(eng)
                if let live = liveHardwareFormat(engine: eng),
                   Self.hardwareConnectFormatMatches(live, cachedFormat) {
                    guard nativeOutput.markPrepared(stamp) else {
                        noteNativeOutputUnavailable()
                        return
                    }
                    switch startMode {
                    case .sync:
                        if (try? startPreparedHardwareGraph(
                            eng, stamp: stamp, connectFormat: cachedFormat, reusedGraph: true
                        )) != nil {
                            return
                        }
                    case .async:
                        submitHardwareStart(
                            engine: eng,
                            context: PendingHardwareStart(
                                connectFormat: cachedFormat,
                                reusedGraph: true,
                                nativeStamp: stamp,
                                sessionSampleRate: sessionInfo.sampleRate,
                                sessionChannels: sessionInfo.channels
                            )
                        )
                        return
                    }
                }
            } else {
                bringUpTiming.path = "reused-busy"
                PlayerLog.log(
                    "[PathA] audio graph reuse skipped: hardware queue still owns the engine"
                )
            }
            teardownHardwareGraph()
        }
        installFreshHardwareGraph(
            sessionSampleRate: sessionInfo.sampleRate,
            sessionChannels: sessionInfo.channels,
            startMode: startMode
        )
    }

    /// The full build: new engine, attach, prepare (with the one post-prepare
    /// sample-rate-flip rebuild), start. Split out so a failed async reused-graph
    /// start can fall through to it from its completion exactly as the
    /// synchronous path falls through inline.
    private func markFreshHardwareInstall() {
        if bringUpTiming.path == "reused" { bringUpTiming.path = "reused-miss" }
    }

    private func installFreshHardwareGraph(
        sessionSampleRate: Double,
        sessionChannels: Int,
        startMode: AudioHardwareStartMode
    ) {
        guard equalizerMaintenance == nil else { return }
        markFreshHardwareInstall()
        let eng = AVAudioEngine()
        engine = eng
        bindNativeOutput(eng)
        guard let initialFormat = resolveHardwareConnectFormat(
            engine: eng,
            sessionSampleRate: sessionSampleRate,
            sessionChannels: sessionChannels
        ) else {
            softFailHardware(reason: "no safe connect format")
            return
        }
        do {
            let stamp = nativeOutput.stamp
            _ = attachSourceChain(engine: eng, connectFormat: initialFormat)
            prepareMixerForGraphStart()
            bringUpTiming.measure(.prepare) { eng.prepare() }
            guard let live = liveHardwareFormat(engine: eng) else {
                softFailHardware(reason: "post-prepare hardware format unknown")
                return
            }
            var connectFormat = initialFormat
            if !Self.hardwareConnectFormatMatches(live, initialFormat) {
                PlayerLog.log(
                    "[PathA] audio HW post-prepare format changed " +
                    "sr=\(Int(initialFormat.sampleRate.rounded()))→\(Int(live.sampleRate.rounded())) " +
                    "ch=\(initialFormat.channelCount)→\(live.channelCount) — rebuild connect once"
                )
                detachSourceChain(engine: eng)
                guard let rebuilt = resolveHardwareConnectFormat(
                    engine: eng,
                    sessionSampleRate: live.sampleRate,
                    sessionChannels: Int(live.channelCount)
                ) else {
                    softFailHardware(reason: "post-prepare rebuild failed")
                    return
                }
                connectFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: live.sampleRate,
                    channels: rebuilt.channelCount,
                    interleaved: false
                ) ?? rebuilt
                _ = attachSourceChain(engine: eng, connectFormat: connectFormat)
                prepareMixerForGraphStart()
                bringUpTiming.measure(.prepare) { eng.prepare() }
                guard let live2 = liveHardwareFormat(engine: eng),
                      Self.hardwareConnectFormatMatches(live2, connectFormat) else {
                    softFailHardware(reason: "post-rebuild hardware format mismatch")
                    return
                }
            }
            guard nativeOutput.markPrepared(stamp) else {
                noteNativeOutputUnavailable()
                return
            }
            switch startMode {
            case .sync:
                try startPreparedHardwareGraph(
                    eng, stamp: stamp, connectFormat: connectFormat, reusedGraph: false
                )
            case .async:
                submitHardwareStart(
                    engine: eng,
                    context: PendingHardwareStart(
                        connectFormat: connectFormat,
                        reusedGraph: false,
                        nativeStamp: stamp,
                        sessionSampleRate: sessionSampleRate,
                        sessionChannels: sessionChannels
                    )
                )
            }
        } catch {
            softFailHardware(reason: error.localizedDescription)
        }
    }

    private func startPreparedHardwareGraph(
        _ eng: AVAudioEngine,
        stamp: AudioNativeOutputBinding.Stamp,
        connectFormat: AVAudioFormat,
        reusedGraph: Bool
    ) throws {
        guard nativeParametersExclusive, deferredAuthorizedOutputPermit?.isValid ?? true else { return }
        try bringUpTiming.measure(.start) { try eng.start() }
        guard nativeOutput.isCurrent(stamp), eng.isRunning,
              deferredAuthorizedOutputPermit?.isValid ?? true else {
            noteNativeOutputUnavailable()
            return
        }
        acceptHardwareStart(connectFormat: connectFormat, reusedGraph: reusedGraph)
    }

    /// Everything that follows a successful `start()`, in the order the
    /// synchronous path always ran it. Called inline by the sync path and from
    /// the accepted completion by the async one.
    private func acceptHardwareStart(connectFormat: AVAudioFormat, reusedGraph: Bool) {
        defer { noteOutputStateChange() }
        nativeOutputUnavailable = false
        repairingNativeOutput = false
        engineStarted = true
        fillOnlyMode = false
        retainedMaintenancePaused = false
        timePitchInstalled = timePitchNode != nil
        hardwareSampleRate = connectFormat.sampleRate
        isResamplingToHardware = abs(connectFormat.sampleRate - Self.engineSampleRate) >= 1.0
        if latestParametersRequirePausedReset {
            retainedMaintenancePaused = true
            scheduleContinuousEqualizerMaintenance()
            refreshRenderRateBox()
            return
        }
        refreshRenderRateBox()
        if reusedGraph {
            // The fast path bypasses attachSourceChain — the only other
            // place that flips this on. Without it, TimePitch latency
            // compensation (contentTimePresentationOffset, the reportDrain
            // latency repair) is silently dead on the reused graph and
            // video leads audio by the unit's real latency (review F1).
            timePitchInstalled = timePitchNode != nil
        }
        hardwareSampleRate = connectFormat.sampleRate
        isResamplingToHardware = abs(connectFormat.sampleRate - Self.engineSampleRate) >= 1.0
        rampMixerInAfterGraphStart()
        applyTimePitchRate(max(0, playbackRate), resetUnit: false)
        adoptEqualizerConfiguration()
        refreshTimePitchProcessingLatency()
        restoreFeederAdmissionForCurrentOutput()
        if reusedGraph {
            PlayerLog.log(
                "[PathA] audio render start hardware (reused graph) " +
                "sr=\(String(format: "%.0f", connectFormat.sampleRate))" +
                (isResamplingToHardware ? " resample" : "") +
                (cachedGraphPitchMode ? " pitch=TimePitch" : " pitch=off")
            )
            return
        }
        let pitchNote: String
        if pitchCorrectionActive {
            pitchNote = timePitchInstalled
                ? " pitch=TimePitch rate=\(String(format: "%.2f", timePitchRate))" +
                  (timePitchBypassed ? " bypass" : "")
                : " pitch=ON(no-unit)"
        } else {
            pitchNote = " pitch=off"
        }
        PlayerLog.log(
            "[PathA] audio render start hardware sr=\(String(format: "%.0f", connectFormat.sampleRate))" +
            (isResamplingToHardware ? " resample" : "") +
            pitchNote
        )
    }

    /// Submit `start()` — and ONLY `start()` — to `hardwareQueue` (design §7).
    ///
    /// Everything before it (session, build, `prepare()`, sample-rate checks)
    /// already ran on the main actor; everything after it runs in
    /// `completeHardwareStart`. Until then the renderer is PENDING:
    /// `engineStarted == false`, `fillOnlyMode == false`, the drain tick holds
    /// the clock, seek publication acknowledges synchronously, and the render
    /// callback — which starts firing as soon as `start()` returns over there,
    /// before main hears about it — is held at rate 0 and reads nothing.
    private func submitHardwareStart(engine eng: AVAudioEngine, context: PendingHardwareStart) {
        let token = hardwareStart.beginStart()
        var admittedContext = context
        admittedContext.maintenancePermit = deferredAuthorizedOutputPermit
        let authorizedPermit = admittedContext.maintenancePermit
        pendingHardwareStartContext = admittedContext
        engineStarted = false
        fillOnlyMode = false
        refreshRenderRateBox()
        bringUpTiming.markMainThreadReleased()
        // Transfer the engine across the serial hardware queue in an explicit
        // `@unchecked Sendable` box so iOS 26 SDK builds stay concurrency-clean.
        let transfer = AudioHardwareEngineTransfer(eng)
        Self.hardwareQueue.async { [weak self] in
            let began = CACurrentMediaTime()
            var failure: String?
            do {
                if authorizedPermit?.isValid ?? true { try transfer.engine.start() }
            } catch {
                failure = error.localizedDescription
            }
            let startMilliseconds = (CACurrentMediaTime() - began) * 1000
            let running = transfer.engine.isRunning
            // `DispatchQueue.main`, not a `Task`: completions of this serial
            // queue must reach the main actor in the order they were issued
            // (a start before the stop queued behind it).
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        // Renderer gone: nobody will ever stop this engine.
                        if running { Self.stopOrphanedEngine(transfer) }
                        return
                    }
                    self.completeHardwareStart(
                        token: token,
                        engine: transfer.engine,
                        failure: failure,
                        startMilliseconds: startMilliseconds,
                        engineReportsRunning: running
                    )
                }
            }
        }
    }

    private func completeHardwareStart(
        token: AudioHardwareStartAdmission.Token,
        engine eng: AVAudioEngine,
        failure: String?,
        startMilliseconds: Double,
        engineReportsRunning: Bool
    ) {
        let context = pendingHardwareStartContext
        // A stop may already be executing behind this completed start. Its
        // queue-captured fact is sufficient for discard/serialized cleanup;
        // only exclusive ownership permits a fresh native read for acceptance.
        let exclusiveNativeAccess = hardwareStart.maySampleNativeStateForCompletingStart
        let currentNativeRunning = engineReportsRunning && (!exclusiveNativeAccess || eng.isRunning)
        let configurationCurrent = exclusiveNativeAccess
            && (context.map { nativeOutput.isCurrent($0.nativeStamp) } ?? false)
            && (context?.maintenancePermit?.isValid ?? true)
        let verdict = hardwareStart.complete(
            token: token,
            succeeded: failure == nil,
            rendererRunning: isRunning,
            engineIsCurrent: engine === eng,
            engineReportsRunning: currentNativeRunning,
            configurationCurrent: configurationCurrent
        )
        // Last, after every state flip below: from here the callback may read.
        defer {
            settleHardwareQueueWaiters()
            refreshRenderRateBox()
        }
        switch verdict {
        case .accept:
            pendingHardwareStartContext = nil
            if equalizerMaintenance != nil { return }
            guard let context else {
                // Unreachable (the context is set and cleared with the token).
                // Fail CLOSED: returning here would leave a running engine with
                // `engineStarted == false` and no pending start, i.e. the drain
                // tick's simulated consumer and the restored-rate callback both
                // reading one SPSC ring. The queue has acknowledged this start,
                // so the engine is the main actor's to tear down.
                lastDrainWall = ContinuousClock.now
                softFailHardware(reason: "accepted start without context")
                return
            }
            bringUpTiming.record(.start, milliseconds: startMilliseconds)
            acceptHardwareStart(connectFormat: context.connectFormat, reusedGraph: context.reusedGraph)
            bringUpTiming.log()
        case .unavailable:
            noteNativeOutputUnavailable()
            // A changed configuration can still report native-running. Hold
            // its callback until a later admitted repair or lifecycle stop.
            PlayerLog.log("[PathA] audio start has no current native output; clock held")
        case .softFail:
            pendingHardwareStartContext = nil
            let carriedDeferredPermit = context?.maintenancePermit
            bringUpTiming.record(.start, milliseconds: startMilliseconds)
            // The fill-only consumer simulates from its last wall stamp. That
            // stamp predates the pending interval, during which nothing drained;
            // without this it would discard the whole start duration at once.
            lastDrainWall = ContinuousClock.now
            if let context, context.reusedGraph {
                // The synchronous path's reused-graph failure: tear down and
                // take the full build. That build is async again, and logs
                // from its own completion.
                deferredAuthorizedOutputPermit = carriedDeferredPermit
                continuingDeferredAuthorizedOutput = carriedDeferredPermit?.isValid ?? false
                teardownHardwareGraph()
                installFreshHardwareGraph(
                    sessionSampleRate: context.sessionSampleRate,
                    sessionChannels: context.sessionChannels,
                    startMode: .async
                )
                continuingDeferredAuthorizedOutput = false
            } else {
                softFailHardware(reason: failure ?? "AVAudioEngine.start failed")
            }
            if !hardwareStart.isPending { bringUpTiming.log() }
        case .discard(let stopStaleEngine):
            PlayerLog.log(
                "[PathA] audio hardware start discarded (superseded) " +
                "start=\(Int(startMilliseconds.rounded()))ms " +
                "engineRunning=\(engineReportsRunning ? 1 : 0)"
            )
            if stopStaleEngine || currentNativeRunning, !(engine === eng && equalizerMaintenance != nil) {
                enqueueHardwareStop(eng, detaching: [])
            }
        }
    }

    /// Stop (and optionally detach a chain from) an engine on `hardwareQueue`,
    /// behind whatever is already queued for it. Main never waits; the
    /// acknowledgement returns the engine to the main actor.
    private func enqueueHardwareStop(_ eng: AVAudioEngine, detaching nodes: [AVAudioNode]) {
        hardwareStart.noteOperationSubmitted()
        refreshRenderRateBox()
        let transfer = AudioHardwareEngineTransfer(eng, nodes: nodes)
        Self.hardwareQueue.async { [weak self] in
            Self.stopAndDetach(transfer.engine, nodes: transfer.nodes)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.acknowledgeHardwareOperation()
                }
            }
        }
    }

    private func acknowledgeHardwareOperation() {
        hardwareStart.acknowledgeOperation()
        settleHardwareQueueWaiters()
        refreshRenderRateBox()
    }

    /// Runs ON `hardwareQueue`. Same order as the main-actor teardown: stop,
    /// then TimePitch before source.
    nonisolated private static func stopAndDetach(_ eng: AVAudioEngine, nodes: [AVAudioNode]) {
        eng.mainMixerNode.outputVolume = 0
        if eng.isRunning { eng.stop() }
        for node in nodes {
            eng.disconnectNodeOutput(node)
            eng.detach(node)
        }
    }

    nonisolated private static func stopOrphanedEngine(_ transfer: AudioHardwareEngineTransfer) {
        hardwareQueue.async {
            transfer.engine.mainMixerNode.outputVolume = 0
            if transfer.engine.isRunning { transfer.engine.stop() }
        }
    }

    /// source → (optional TimePitch) → mixer. Rate changes never run on the RT thread.
    @discardableResult
    private func attachSourceChain(engine: AVAudioEngine, connectFormat: AVAudioFormat) -> AVAudioSourceNode {
        let node = Self.makeSourceNode(
            ringRouter: ringRouter,
            rateBox: rateBox,
            connectFormat: connectFormat,
            pitchMode: pitchCorrectionActive,
            diagnostics: renderDiagnostics
        )
        engine.attach(node)
        let equalizer = AVAudioUnitEQ(numberOfBands: PlayerEqualizerConfiguration.frequencies.count)
        engine.attach(equalizer)
        equalizerNode = equalizer
        equalizerHistoryDirty = false
        if pitchCorrectionActive {
            let pitch = AVAudioUnitTimePitch()
            engine.attach(pitch)
            engine.connect(node, to: pitch, format: connectFormat)
            engine.connect(pitch, to: equalizer, format: connectFormat)
            timePitchNode = pitch
            timePitchInstalled = true
            applyTimePitchRate(max(0, playbackRate), resetUnit: false)
        } else {
            engine.connect(node, to: equalizer, format: connectFormat)
            timePitchNode = nil
            timePitchInstalled = false
        }
        engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
        sourceNode = node
        cachedGraphConnectFormat = connectFormat
        cachedGraphPitchMode = pitchCorrectionActive
        cachedGraphDiagnosticsEnabled = PlayerLog.isEnabled
        pendingEqualizerReset = false
        pendingPitchReset = false
        applyEqualizerToCurrentGraph()
        return node
    }

    private func detachSourceChain(engine: AVAudioEngine) {
        if !continuingDeferredAuthorizedOutput { revokeAudioMaintenancePermission() }
        if let equalizer = equalizerNode {
            engine.disconnectNodeOutput(equalizer)
            engine.detach(equalizer)
        }
        retireEqualizerGraph()
        if let pitch = timePitchNode {
            engine.disconnectNodeOutput(pitch)
            engine.detach(pitch)
        }
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        timePitchNode = nil
        timePitchInstalled = false
        timePitchProcessingLatencySeconds = 0
        sourceNode = nil
        cachedGraphConnectFormat = nil
        cachedGraphPitchMode = false
    }

    static func hardwareConnectFormatMatches(_ live: AVAudioFormat, _ connected: AVAudioFormat) -> Bool {
        live.sampleRate > 0 && live.channelCount > 0
            && abs(live.sampleRate - connected.sampleRate) < 1
            && live.channelCount == connected.channelCount
    }

    private func liveHardwareFormat(engine: AVAudioEngine) -> AVAudioFormat? {
        let output = engine.outputNode.inputFormat(forBus: 0)
        if output.sampleRate > 0, output.channelCount > 0 { return output }
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        return mixer.sampleRate > 0 && mixer.channelCount > 0 ? mixer : nil
    }

    /// Built `nonisolated` so the render-block closure does not inherit `@MainActor`
    /// isolation when CoreAudio invokes it on the real-time render thread.
    /// When `pitchMode` is true, the source feeds content at unity into TimePitch
    /// and `rateBox` only gates silence at rate 0.
    nonisolated private static func makeSourceNode(
        ringRouter: PCMFloatRingRouter,
        rateBox: AtomicFloatBox,
        connectFormat: AVAudioFormat,
        pitchMode: Bool,
        diagnostics: AudioRenderDiagnostics
    ) -> AVAudioSourceNode {
        let ringChannels = engineChannels
        let ringSampleRate = Self.engineSampleRate
        let connectSampleRate = connectFormat.sampleRate
        let sourceInterleaved = connectFormat.isInterleaved
        let sourceChannels = Int(connectFormat.channelCount)
        let ringPerHW = ringSampleRate / max(connectSampleRate, 1)
        let diagnosticsEnabled = PlayerLog.isEnabled
        let diagnosticsPermit = ExperimentalSettingsPolicy.capturePermit(.diagnostics)
        // Preallocate the per-callback source scratch ONCE. The render block runs on the
        // audio real-time thread: it must not allocate heap or take a lock. `scratch` is a
        // fixed buffer captured by the block (freed when the node is torn down); `ring.read`
        // copies into it without allocating; `rateBox` is an atomic load, not a lock.
        let scratch = RenderScratch(capacity: Self.maxRenderScratchFloats)
        let resample = RenderResampleState(channels: ringChannels)
        return AVAudioSourceNode(format: connectFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            // Only lock-free scalars are read on the native audio thread. An
            // old graph cannot resume collecting after its permission retires.
            let capturesDiagnostics = diagnosticsEnabled
                && diagnosticsPermit?.isValid == true && PlayerLog.isEnabled
            if capturesDiagnostics {
                diagnostics.recordCallback(frameCount: frames)
            }
            let publication = AudioRingPublication(
                packed: ringRouter.publishedPair.load(ordering: .acquiring)
            )
            if publication.packed != resample.lastPacked {
                // A new slot/epoch is a seek or content switch: the carried
                // frame(s) belong to a different timeline and must not bleed
                // into the next interpolation.
                resample.lastPacked = publication.packed
                resample.reset()
            }
            let acknowledged = AudioRingPublication(
                packed: ringRouter.acknowledgedPair.load(ordering: .relaxed)
            )
            if publication != acknowledged {
                // One packed load and one acknowledgement per quantum. The RT
                // path never allocates, locks, logs, swaps ARC graph objects, or
                // calls TimePitch.
                ringRouter.acknowledgedPair.store(
                    publication.packed,
                    ordering: .releasing
                )
            }
            let rate = max(rateBox.value, 0)
            for buf in abl {
                if let raw = buf.mData { memset(raw, 0, Int(buf.mDataByteSize)) }
            }
            let outputGated = ringRouter.outputGate.load(ordering: .acquiring) != 0
            if outputGated {
                // Written after the gated quantum has zeroed its buffers. This
                // is the ownership fence used before the main actor resets a
                // slot that a prior ungated quantum may have been reading.
                ringRouter.acknowledgeOutputGateAtCallbackBoundary(publication: publication)
            }
            if outputGated
                    || rate <= 0.000_1 || frames <= 0 {
                // Dead air: nothing carries forward across the silent gap.
                resample.reset()
                return noErr
            }
            // Pitch path: content-rate feed (TimePitch owns tempo). Varispeed: rate stride.
            let stretch = pitchMode ? 1.0 : Double(rate)
            let step = ringPerHW * stretch
            if step == 1, resample.phase != 0 || resample.carryFrames != 0 {
                // A varispeed rate edge landed back on unity: accept one
                // sub-sample step rather than carry fractional state from a
                // different stride into the fast path below.
                resample.reset()
            }

            let temp = scratch.buffer
            func writeFrameSample(_ frame: Int, _ sample0: Float, _ sample1: Float) {
                if capturesDiagnostics {
                    diagnostics.recordSourceSample(sample0)
                    if ringChannels > 1 { diagnostics.recordSourceSample(sample1) }
                }
                if sourceInterleaved {
                    guard abl.count >= 1, let raw = abl[0].mData else { return }
                    let dst = raw.assumingMemoryBound(to: Float.self)
                    let maxFloats = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                    let chOut = max(min(sourceChannels, ringChannels), 1)
                    for channel in 0..<chOut where frame * chOut + channel < maxFloats {
                        dst[frame * chOut + channel] = channel == 0 ? sample0 : sample1
                    }
                } else {
                    let chLimit = min(ringChannels, min(sourceChannels, abl.count))
                    for channel in 0..<chLimit {
                        guard let raw = abl[channel].mData else { continue }
                        let maxFloats = Int(abl[channel].mDataByteSize) / MemoryLayout<Float>.size
                        if frame < maxFloats {
                            raw.assumingMemoryBound(to: Float.self)[frame] = channel == 0 ? sample0 : sample1
                        }
                    }
                }
            }

            // Fast path: unity stride with no phase/carry in play is a direct
            // copy — bit-exact, and the common case (48 kHz hardware route).
            if step == 1, resample.phase == 0, resample.carryFrames == 0 {
                let wantSamples = min(frames * ringChannels, scratch.buffer.count)
                let got = ringRouter.ring(at: publication.slot).read(
                    into: temp.baseAddress!, maxSamples: wantSamples
                )
                let gotFrames = got / max(ringChannels, 1)
                if gotFrames < frames {
                    ringRouter.ring(at: publication.slot).recordShortRead()
                }
                for frame in 0..<gotFrames {
                    let base = frame * ringChannels
                    let s0 = temp[base]
                    let s1 = ringChannels > 1 ? temp[base + 1] : s0
                    writeFrameSample(frame, s0, s1)
                }
                return noErr
            }

            // General path: carry the fractional phase and the 1-2 boundary
            // frames across callbacks (see `PCMSourceReadPlan`).
            let readFrames = PCMSourceReadPlan.requiredReadFrames(
                outputFrames: frames, step: step,
                phase: resample.phase, carryFrames: resample.carryFrames
            )
            let wantSamples = min(readFrames * ringChannels, scratch.buffer.count)
            let got: Int = readFrames > 0
                ? ringRouter.ring(at: publication.slot).read(
                    into: temp.baseAddress!, maxSamples: wantSamples
                )
                : 0
            let gotFrames = got / max(ringChannels, 1)
            let priorCarryFrames = resample.carryFrames
            let virtualLength = priorCarryFrames + gotFrames
            let shortRead = gotFrames < readFrames
            if shortRead {
                ringRouter.ring(at: publication.slot).recordShortRead()
            }

            // Non-escaping local helper (no heap context — it closes only over
            // this call's stack values and is never stored). Resolves a virtual
            // index to the carry buffer or the fresh read.
            func virtualSample(_ index: Int, _ channel: Int) -> Float {
                index < priorCarryFrames
                    ? resample.carry[index * ringChannels + channel]
                    : temp[(index - priorCarryFrames) * ringChannels + channel]
            }

            for f in 0..<frames {
                guard let pair = PCMSourceReadPlan.framePair(
                    outputFrame: f, phase: resample.phase, step: step,
                    availableVirtualFrames: virtualLength
                ) else { continue }
                let i0 = pair.first
                let i1 = pair.second
                let frac = pair.fraction
                let s00 = virtualSample(i0, 0)
                let s10 = virtualSample(i1, 0)
                let out0 = s00 + (s10 - s00) * frac
                let out1: Float
                if ringChannels > 1 {
                    let s01 = virtualSample(i0, 1)
                    let s11 = virtualSample(i1, 1)
                    if capturesDiagnostics { diagnostics.recordSourceSample(s10); diagnostics.recordSourceSample(s11) }
                    out1 = s01 + (s11 - s01) * frac
                } else {
                    if capturesDiagnostics { diagnostics.recordSourceSample(s10) }
                    out1 = out0
                }
                writeFrameSample(f, out0, out1)
            }

            if shortRead {
                // Ring dry: the rest of the output is the zero fill from the
                // top of this callback (today's underrun behavior). Do not
                // carry a boundary frame across the gap.
                resample.reset()
            } else {
                let boundary = PCMSourceReadPlan.carryBoundary(
                    outputFrames: frames, step: step,
                    phase: resample.phase, virtualLength: virtualLength
                )
                let carryCount = max(0, min(boundary.count, resample.carry.count / ringChannels))
                for i in 0..<carryCount {
                    let srcIndex = boundary.start + i
                    for c in 0..<ringChannels {
                        resample.carry[i * ringChannels + c] = virtualSample(srcIndex, c)
                    }
                }
                resample.carryFrames = carryCount
                resample.phase = boundary.nextPhase
            }
            return noErr
        }
    }

    func revokeAudioMaintenancePermission() {
        deferredAuthorizedOutputPermit?.revoke()
        deferredAuthorizedOutputPermit = nil
        deferredAuthorizedOutputSerial &+= 1
        deferredAuthorizedOutputTask?.cancel()
        deferredAuthorizedOutputTask = nil
        equalizerMaintenance?.permit?.revoke()
        if equalizerMaintenance != nil { equalizerMaintenance?.retired = true }
    }

    private func deferAuthorizedOutputUntilMaintenanceSettles(source: AudioPullSource) {
        deferredAuthorizedOutputTask?.cancel()
        deferredAuthorizedOutputSerial &+= 1
        let serial = deferredAuthorizedOutputSerial
        maintenanceOutputHeld = true
        refreshRenderRateBox()
        deferredAuthorizedOutputTask = Task { @MainActor [weak self, weak source] in
            guard let self else { return }
            defer {
                if self.deferredAuthorizedOutputSerial == serial {
                    self.deferredAuthorizedOutputTask = nil
                    if self.equalizerMaintenance == nil {
                        self.maintenanceOutputHeld = false
                        self.refreshRenderRateBox()
                    }
                }
            }
            await self.awaitAudioMaintenanceSettlement()
            await self.awaitHardwareQueueAccess()
            guard !Task.isCancelled, self.deferredAuthorizedOutputSerial == serial,
                  self.isRunning, let source, self.pullSource === source,
                  let permit = self.audioMaintenanceAdmission?(), permit.isValid else { return }
            self.deferredAuthorizedOutputPermit = permit
            self.deferredAuthorizedOutputTask = nil
            self.maintenanceOutputHeld = false
            // Original source/PCM/clock ownership remains intact. This continues
            // only the already-authorized native output action delayed by cleanup.
            self.continuingDeferredAuthorizedOutput = true
            if self.equalizerMaintenance != nil || self.retainedMaintenancePaused
                || self.nativeOutputUnavailable || self.nativeOutput.hasUnresolvedConfiguration {
                try? self.reconcileOutputForAuthorizedPlayback()
            } else if self.fillOnlyMode {
                // An initial start delayed by maintenance still needs hardware.
                // Healthy resumed output must not prepare or reset its graph again.
                self.installHardwareGraphBestEffort()
            }
            self.continuingDeferredAuthorizedOutput = false
            self.refreshRenderRateBox()
            self.restoreFeederAdmissionForCurrentOutput()
        }
    }

    func awaitAudioMaintenanceSettlement() async {
        guard equalizerMaintenance != nil else { return }
        await withCheckedContinuation { maintenanceWaiters.append($0) }
    }

    private func awaitHardwareQueueAccess() async {
        guard !hardwareStart.mayReuseEngine else { return }
        await withCheckedContinuation { hardwareQueueWaiters.append($0) }
    }

    private func settleHardwareQueueWaiters() {
        guard hardwareStart.mayReuseEngine else { return }
        let waiters = hardwareQueueWaiters
        hardwareQueueWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func retireEqualizerGraph() {
        equalizerNode = nil
        configuredEqualizerRevision = nil
        configuredEqualizerBypassed = true
        equalizerHistoryDirty = false
        equalizerLatency = .bypassed
        pitchLatency = .bypassed
        equalizerStatus = .retainedNoGraph
        retainedMaintenancePaused = false
    }

    private func resetStoppedEqualizerGraph() {
        guard nativeParametersExclusive, let eng = engine, !eng.isRunning else { return }
        equalizerNode?.reset()
        equalizerHistoryDirty = false
        pendingEqualizerReset = false
        applyEqualizerToCurrentGraph()
    }

    private func adoptEqualizerConfiguration() {
        guard equalizerNode != nil else {
            equalizerStatus = fillOnlyMode ? .unsupported("No native audio output") : .retainedNoGraph
            return
        }
        guard nativeParametersExclusive else {
            equalizerStatus = .pendingNativeAccess
            return
        }
        if pendingEqualizerReset || pendingPitchReset, let eng = engine, eng.isRunning {
            equalizerStatus = .pendingNativeAccess
            scheduleContinuousEqualizerMaintenance()
            return
        }
        if pendingEqualizerReset { resetStoppedEqualizerGraph() }
        applyEqualizerToCurrentGraph()
        refreshEqualizerLatency()
    }

    private func applyEqualizerToCurrentGraph() {
        guard hardwareStart.mayReuseEngine, !nativeOutput.hasUnresolvedConfiguration,
              let node = equalizerNode,
              let format = cachedGraphConnectFormat else { return }
        let desired = equalizerConfiguration
        guard desired == desired.normalized else {
            node.bypass = true
            configuredEqualizerBypassed = true
            configuredEqualizerRevision = equalizerRevision
            equalizerLatency = .bypassed
            equalizerStatus = .unsupported("Invalid equalizer configuration")
            return
        }
        guard desired.isBypassed || PlayerEqualizerConfiguration.frequencies.allSatisfy({
            Double($0) < format.sampleRate / 2
        }) else {
            node.bypass = true
            configuredEqualizerBypassed = true
            configuredEqualizerRevision = equalizerRevision
            equalizerLatency = .bypassed
            equalizerStatus = .unsupported("Output sample rate cannot support all ten EQ bands")
            return
        }
        for (index, band) in node.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = PlayerEqualizerConfiguration.frequencies[index]
            band.bandwidth = 1
            band.gain = desired.bandGains[index]
            band.bypass = false
        }
        node.globalGain = desired.effectivePreamp
        node.bypass = desired.isBypassed
        configuredEqualizerBypassed = desired.isBypassed
        configuredEqualizerRevision = equalizerRevision
        equalizerStatus = desired.isBypassed ? .bypassed : .configuredCurrentGraph
    }

    private func refreshEqualizerLatency() {
        guard hardwareStart.mayReuseEngine, !maintenanceOutputHeld, !nativeOutputUnavailable,
              !nativeOutput.hasUnresolvedConfiguration,
              configuredEqualizerRevision == equalizerRevision, let node = equalizerNode else { return }
        if configuredEqualizerBypassed {
            equalizerLatency = .bypassed
        } else {
            let value = node.latency
            equalizerLatency = value.isFinite && value > 0 ? .reported(value) : .unreported
        }
    }

    private func reserveEqualizerMaintenance(seek: MediaAudioSeekToken?) -> UInt64? {
        guard equalizerMaintenance == nil, let eng = engine, let node = equalizerNode,
              !nativeOutputUnavailable, !nativeOutput.hasUnresolvedConfiguration else { return nil }
        nextEqualizerMaintenanceSerial &+= 1
        let serial = nextEqualizerMaintenanceSerial
        equalizerMaintenance = EqualizerMaintenance(
            serial: serial,
            graph: AudioEqualizerNativeGraph(
                engine: eng, equalizer: node, pitch: timePitchNode, stamp: nativeOutput.stamp
            ), seek: seek
        )
        maintenanceOutputHeld = true
        equalizerStatus = .pendingNativeAccess
        equalizerLatency = .unreported
        pitchLatency = .unreported
        mixerRampTask?.cancel()
        mixerRampTask = nil
        if seek == nil {
            feeder?.setTargetFrames(0)
        } else {
            feeder?.standDown()
        }
        refreshRenderRateBox()
        if hardwareStart.mayReuseEngine { eng.mainMixerNode.outputVolume = 0 }
        return serial
    }

    private func maintenanceIsCurrent(_ serial: UInt64, isAuthorized: (@MainActor @Sendable () -> Bool)?) -> Bool {
        guard let operation = equalizerMaintenance, operation.serial == serial, !operation.retired,
              engine === operation.graph.engine, equalizerNode === operation.graph.equalizer,
              nativeOutput.isCurrent(operation.graph.stamp), !nativeOutputUnavailable,
              !Task.isCancelled, isAuthorized?() ?? true else { return false }
        if let token = operation.seek { return activeSeekToken == token }
        return isRunning && pullSource != nil && activeSeekToken == nil
    }

    private func performEqualizerNativeAction(
        _ action: AudioEqualizerNativeAction, serial: UInt64
    ) async -> AudioEqualizerNativeResult? {
        guard let operation = equalizerMaintenance, operation.serial == serial else { return nil }
        let graph = operation.graph
        let operationID = hardwareStart.beginNativeOperation()
        refreshRenderRateBox()
        let permit = operation.permit
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.hardwareQueue.async { [weak self] in
                    let result = AudioEqualizerNativeExecution.perform(action, graph: graph)
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.hardwareStart.completeNativeOperation(operationID)
                            self?.settleHardwareQueueWaiters()
                            self?.refreshRenderRateBox()
                            continuation.resume(returning: result)
                        }
                    }
                }
            }
        } onCancel: {
            permit?.revoke()
        }
    }

    private func pauseAndConfigureEqualizer(
        _ serial: UInt64, isAuthorized: (@MainActor @Sendable () -> Bool)?
    ) async -> Bool {
        if equalizerMaintenance?.seek == nil, let feeder {
            await feeder.joinAfterStandDown()
            feeder.standDown()
        }
        await awaitHardwareQueueAccess()
        guard maintenanceIsCurrent(serial, isAuthorized: isAuthorized) else { return false }
        guard let result = await performEqualizerNativeAction(.pauseAndReset, serial: serial),
              result.performedReset, !result.running, result.failure == nil else {
            if maintenanceIsCurrent(serial, isAuthorized: isAuthorized) {
                equalizerStatus = .failed("Could not establish paused audio for EQ reset")
            }
            return false
        }
        await awaitHardwareQueueAccess()
        guard maintenanceIsCurrent(serial, isAuthorized: isAuthorized) else { return false }
        equalizerHistoryDirty = false
        pendingEqualizerReset = false
        pendingPitchReset = false
        timePitchResetCount += 1
        applyTimePitchRate(max(0, playbackRate), resetUnit: false)
        applyEqualizerToCurrentGraph()
        applyMixerGain()
        equalizerStatus = .pendingNativeAccess
        return true
    }

    private func resumeEqualizerMaintenance(
        _ serial: UInt64,
        resumesPlayback: Bool,
        isAuthorized: (@MainActor @Sendable () -> Bool)?,
        resumeAdmission: @escaping @MainActor () -> AudioMaintenancePermit?
    ) async -> Bool {
        while maintenanceIsCurrent(serial, isAuthorized: isAuthorized) {
            if !resumesPlayback {
                engineStarted = false
                return true
            }
            guard let permit = resumeAdmission(), permit.isValid else { return false }
            equalizerMaintenance?.permit = permit
            let result = await performEqualizerNativeAction(.resume(permit, permit.ticket()), serial: serial)
            await awaitHardwareQueueAccess()
            guard maintenanceIsCurrent(serial, isAuthorized: isAuthorized), permit.isValid,
                  let result, result.failure == nil, result.running,
                  equalizerMaintenance?.graph.engine.isRunning == true else {
                if maintenanceIsCurrent(serial, isAuthorized: isAuthorized), let failure = result?.failure {
                    equalizerStatus = .failed(failure)
                }
                return false
            }
            // A dirty-enable or rate reset arriving during native resume must go
            // back to the paused boundary before any output/PCM is accepted.
            if latestParametersRequirePausedReset {
                permit.revoke()
                equalizerMaintenance?.permit = nil
                guard await pauseAndConfigureEqualizer(serial, isAuthorized: isAuthorized) else { return false }
                continue
            }
            applyTimePitchRate(max(0, playbackRate), resetUnit: false)
            applyEqualizerToCurrentGraph()
            engineStarted = true
            fillOnlyMode = false
            return true
        }
        return false
    }

    private func finishRejectedMaintenance(_ serial: UInt64) async {
        guard let operation = equalizerMaintenance, operation.serial == serial else { return }
        operation.permit?.revoke()
        // Join all submitted operations, including original lifecycle stop,
        // before the backend worker can prepare a successor on this same graph.
        await awaitHardwareQueueAccess()
        if engine === operation.graph.engine {
            _ = await performEqualizerNativeAction(.pause, serial: serial)
        } else {
            let operationID = hardwareStart.beginNativeOperation()
            await withCheckedContinuation { continuation in
                Self.hardwareQueue.async { [weak self] in
                    if operation.graph.engine.isRunning { operation.graph.engine.stop() }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.hardwareStart.completeNativeOperation(operationID)
                            self?.settleHardwareQueueWaiters()
                            continuation.resume()
                        }
                    }
                }
            }
        }
        await awaitHardwareQueueAccess()
        if engine === operation.graph.engine {
            engineStarted = false
            retainedMaintenancePaused = isRunning
            equalizerHistoryDirty = true
            if case .failed = equalizerStatus {} else { equalizerStatus = .pendingNativeAccess }
        }
        releaseEqualizerMaintenance(serial, accepted: false)
    }

    private func releaseEqualizerMaintenance(_ serial: UInt64, accepted: Bool) {
        defer { noteOutputStateChange() }
        guard let operation = equalizerMaintenance, operation.serial == serial,
              hardwareStart.mayReuseEngine else { return }
        operation.permit?.revoke()
        equalizerMaintenance = nil
        maintenanceOutputHeld = false
        if accepted {
            retainedMaintenancePaused = false
            nativeOutputUnavailable = false
            applyTimePitchRate(max(0, playbackRate), resetUnit: false)
            applyEqualizerToCurrentGraph()
            refreshTimePitchProcessingLatency()
            refreshEqualizerLatency()
            applyMixerGain()
        }
        refreshRenderRateBox()
        let waiters = maintenanceWaiters
        maintenanceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if deferredAuthorizedOutputTask != nil {
            maintenanceOutputHeld = true
            refreshRenderRateBox()
        } else if accepted {
            syncFeederAdmission()
        }
    }

    private func scheduleContinuousEqualizerMaintenance() {
        guard continuousEqualizerTask == nil, activeSeekToken == nil else { return }
        continuousEqualizerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.continuousEqualizerTask = nil }
            await self.awaitAudioMaintenanceSettlement()
            guard self.pendingEqualizerReset || self.pendingPitchReset,
                  self.isRunning, self.activeSeekToken == nil,
                  let serial = self.reserveEqualizerMaintenance(seek: nil) else { return }
            guard await self.pauseAndConfigureEqualizer(serial, isAuthorized: nil),
                  await self.resumeEqualizerMaintenance(
                    serial, resumesPlayback: true, isAuthorized: nil,
                    resumeAdmission: { [weak self] in self?.audioMaintenanceAdmission?() }
                  ) else {
                await self.finishRejectedMaintenance(serial)
                return
            }
            self.releaseEqualizerMaintenance(serial, accepted: true)
        }
    }

    func stop() {
        stop(preserveCommittedContent: false)
    }

    func pause() {
        let activeRing = ringRouter.ring(at: activeSlotIndex)
        let hasCommittedContent = preserveCommittedSlotOnNextStart
            || activeRing.frameCount > 0
            || activeRing.drainSnapshot(channels: Self.engineChannels).writtenFrames > 0
        stop(preserveCommittedContent: hasCommittedContent)
        preserveCommittedSlotOnNextStart = hasCommittedContent
    }

    private func stop(preserveCommittedContent: Bool) {
        let costSpan = UIHitchMonitor.beginSpan("audio.stop")
        defer { UIHitchMonitor.endSpan(costSpan) }
        defer { noteOutputStateChange() }
        revokeAudioMaintenancePermission()
        equalizerHistoryDirty = true
        // Order matters: the feeder is retired BEFORE any slot state below is
        // touched, and before the session's `stopPipeline` goes on to reset the
        // PCM store. After `retireFeeder` returns no source pull or ring write
        // can occur. It may wait for admitted synchronous data work, but does not
        // join the whole pass; retained storage supports its remaining bookkeeping.
        drainReportTask?.cancel()
        drainReportTask = nil
        UIHitchMonitor.measureCounted("audio.stop.feeder") { retireFeeder() }
        mixerRampTask?.cancel()
        mixerRampTask = nil
        // A start still in flight on `hardwareQueue` loses its authority here:
        // its completion is discarded and publishes nothing.
        hardwareStart.invalidate()
        pendingHardwareStartContext = nil
        if let eng = engine {
            if nativeParametersExclusive {
                UIHitchMonitor.measureCounted("audio.stop.native") {
                    eng.mainMixerNode.outputVolume = 0
                    if eng.isRunning { eng.stop() }
                }
            } else {
                // `isRunning` may still be false here and flip true when the
                // queued start lands — a main-actor stop now would leave a
                // running engine behind. Serialize the stop behind that start;
                // the graph is kept, and becomes reusable once the queue has
                // acknowledged both.
                enqueueHardwareStop(eng, detaching: [])
            }
            // KEEP the attached chain (engine, source node, TimePitch): the
            // next start() reuses it when the route and pitch mode still
            // match — paying only eng.start() instead of the full
            // session-activate + build + prepare (the measured
            // demand-play-started → demand-audio-graph-ready ≈ 107ms). A
            // stopped engine's render callback cannot fire, so no gate is
            // needed while parked. Full teardown happens on a compatibility
            // miss (install) or when this renderer deallocates.
        } else {
            timePitchNode = nil
            timePitchInstalled = false
            sourceNode = nil
        }
        nativeOutputUnavailable = false
        retainedMaintenancePaused = false
        repairingNativeOutput = false
        engineStarted = false
        fillOnlyMode = false
        isResamplingToHardware = false
        hardwareSampleRate = 0
        isRunning = false
        pullSource = nil
        isSeekOutputGated = false
        ringRouter.setOutputGated(false)
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false
        retiredSeekPublication = nil
        if preserveCommittedContent {
            preserveCommittedSlotOnNextStart = false
        } else {
            ringRouter.resetForLifecycle()
            activeSlotIndex = 0
            activeEpoch = 0
            nextPublicationEpoch = 1
            slotDrainProgress = [AudioDrainProgress(), AudioDrainProgress()]
            lastPublishedSeekEpoch = 0
            lastAcknowledgedSeekEpoch = 0
            preserveCommittedSlotOnNextStart = false
        }
        lastDrainWall = nil
        // Media switch / stop: no sticky rate residual (VLC early pitch class).
        pitchCorrectionActive = false
        timePitchRate = 1
        timePitchBypassed = true
        timePitchProcessingLatencySeconds = 0
        timePitchResetCount += 1
    }

    func flush() {
        defer { noteOutputStateChange() }
        revokeAudioMaintenancePermission()
        equalizerHistoryDirty = true
        // Destructive lifecycle boundary only. Running seeks use
        // begin/prepare/commit above so the callback never reads a reset ring.
        standDownFeederForTransaction()
        ringRouter.resetForLifecycle()
        activeSlotIndex = 0
        activeEpoch = 0
        nextPublicationEpoch = 1
        slotDrainProgress = [AudioDrainProgress(), AudioDrainProgress()]
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false
        retiredSeekPublication = nil
        isSeekOutputGated = false
        preserveCommittedSlotOnNextStart = false
        lastDrainWall = ContinuousClock.now
        // Keep the requested playbackRate but do not resurrect a synthetic
        // non-unity TimePitch state on a stopped/opening graph.
        if pitchCorrectionActive {
            resetTimePitchState()
        } else {
            timePitchRate = 1
            timePitchBypassed = true
            timePitchProcessingLatencySeconds = 0
        }
        syncFeederAdmission()
    }

    /// Rate change off the RT thread only. Pitch path: source stays unity; TimePitch
    /// owns tempo. Diagnostic rollback: atomic varispeed stride (historical).
    private func applyPlaybackRate(_ rate: Float, previous: Float) {
        // The feeder recomputes its depth on its next pass, at most one period
        // late. That is not a rate-response cost: `AVAudioUnitTimePitch` re-times
        // downstream of the ring, so the audible edge is bounded by the unit's
        // processing latency and not by how much content is banked. The ring keeps
        // holding 0.25 s x rate of CONTENT, i.e. a constant 0.25 s of wall time.
        feeder?.setTargetFrames(
            AudioRingReserve.contentFrames(forRate: max(0, rate), sampleRate: Self.engineSampleRate)
        )
        if pitchCorrectionActive {
            setRenderRate(rate <= 0.000_1 ? 0 : 1)
            let wasUnity = previous <= 0.000_1 || abs(previous - 1) < 0.001
            let isUnity = rate <= 0.000_1 || abs(rate - 1) < 0.001
            // K2.2 residual class: clear unit buffers on unity↔non-unity crossings.
            if wasUnity != isUnity, !configuredEqualizerBypassed, engineStarted {
                pendingPitchReset = true
                scheduleContinuousEqualizerMaintenance()
            } else {
                applyTimePitchRate(rate, resetUnit: wasUnity != isUnity)
            }
        } else {
            setRenderRate(rate)
        }
    }

    private func setRenderRate(_ value: Float) {
        requestedRenderRate = value
        refreshRenderRateBox()
    }

    /// The single writer of `rateBox`. With no hardware-queue work outstanding
    /// (always, under `PATHA_AUDIO_ASYNC_START=0`) this is exactly the old
    /// direct assignment.
    private func refreshRenderRateBox() {
        rateBox.value = hardwareStart.renderRate(
            requested: requestedRenderRate,
            nativeOutputUnavailable: maintenanceOutputHeld || retainedMaintenancePaused
                || nativeOutputUnavailable || nativeOutput.hasUnresolvedConfiguration
        )
        noteOutputStateChange()
    }

    /// Apply / bypass TimePitch. Safe on main / graph serial only — never from RT.
    private func applyTimePitchRate(_ rate: Float, resetUnit: Bool) {
        guard !nativeOutput.hasUnresolvedConfiguration,
              nativeParametersExclusive || (hardwareStart.mayReuseEngine && equalizerMaintenance != nil) else {
            pendingPitchReset = pendingPitchReset || resetUnit
            pitchLatency = .unreported
            return
        }
        if resetUnit, let eng = engine, eng.isRunning, equalizerMaintenance != nil {
            pendingPitchReset = true
            return
        }
        if rate <= 0.000_1 {
            timePitchRate = 1
            timePitchBypassed = true
            timePitchProcessingLatencySeconds = 0
            if let pitch = timePitchNode {
                if resetUnit { pitch.reset(); timePitchResetCount += 1 }
                pitch.rate = 1
                pitch.bypass = true
            } else if resetUnit {
                timePitchResetCount += 1
            }
            return
        }
        let unity = abs(rate - 1) < 0.001
        timePitchBypassed = unity
        // Clamp to AU TimePitch legal range; bypass at unity for clean C2 path.
        let applied: Float = unity ? 1 : max(1.0 / 32.0, min(rate, 32))
        timePitchRate = applied
        if let pitch = timePitchNode {
            if resetUnit { pitch.reset(); timePitchResetCount += 1 }
            pitch.rate = applied
            pitch.bypass = unity
            refreshTimePitchProcessingLatency()
        } else if resetUnit {
            // Offline / fill-only seam: still count the reset so seek/stop tests pin it.
            timePitchResetCount += 1
            timePitchProcessingLatencySeconds = 0
        } else {
            timePitchProcessingLatencySeconds = 0
        }
    }

    private func resetTimePitchState() {
        applyTimePitchRate(max(0, playbackRate), resetUnit: true)
    }

    /// Cache the AU's downstream processing latency off the audio thread. The
    /// value can become available only after graph prepare/start, so `reportDrain`
    /// retries while a live non-unity node still reports zero.
    private func refreshTimePitchProcessingLatency() {
        guard hardwareStart.mayReuseEngine, !nativeOutputUnavailable,
              !nativeOutput.hasUnresolvedConfiguration else { return }
        guard pitchCorrectionActive, timePitchInstalled, !timePitchBypassed,
              let pitch = timePitchNode else {
            timePitchProcessingLatencySeconds = 0
            pitchLatency = .bypassed
            return
        }
        let measured = pitch.latency
        let sanitized = measured.isFinite ? max(0, measured) : 0
        let changed = abs(sanitized - timePitchProcessingLatencySeconds) > 0.000_001
        timePitchProcessingLatencySeconds = sanitized
        pitchLatency = sanitized > 0 ? .reported(sanitized) : .unreported
        if changed {
            PlayerLog.log(
                "[PathA] A3c TimePitch latency wall=\(String(format: "%.4f", sanitized))s " +
                "contentOffset=\(String(format: "%.4f", contentTimePresentationOffset))s " +
                "rate=\(String(format: "%.2f", timePitchRate))"
            )
        }
    }

    /// MainActor tick. It reports the drain and nothing else.
    ///
    /// The period is unchanged from the loop this replaces, and so is the feeder's
    /// (below). Nothing here buys headroom: what changed is who runs the refill,
    /// not how often it runs or how deep it fills.
    private func startDrainReportTask() {
        drainReportTask?.cancel()
        let period = max(fillPeriod, 0.01)
        drainReportTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                try? await Task.sleep(for: .seconds(period))
                guard !Task.isCancelled, self.isRunning else { break }
                self.reportDrain()
            }
        }
    }

    /// Build and admit this session's feeder. Called at the end of `start`, after
    /// the launch reserve has already been staged synchronously on MainActor, so
    /// the feeder's first pass finds the ring at the reserve and writes nothing —
    /// exactly the steady state the old loop reached on its first tick.
    private func startFeeder(source: AudioPullSource) {
        let next = AudioRingFeeder(
            ringRouter: ringRouter,
            sampleRate: Self.engineSampleRate,
            channels: Self.engineChannels,
            maximumContentSeconds: AudioRingReserve.maximumContentSeconds
        )
        feeder = next
        next.resume(
            supply: source.audioSupply,
            slot: activeSlotIndex,
            targetFrames: reserveTargetFrames,
            period: max(fillPeriod, 0.01)
        )
    }

    /// Retire this session's feeder. Must run before any slot state is touched,
    /// and must be SYNCHRONOUS in its effect: `MediaEngineSession.stop()` bumps
    /// its generation and enqueues the async close, so a stop immediately followed
    /// by a load must not leave the previous feeder able to consume successor
    /// PCM or write against successor slots.
    ///
    /// The gate may wait for an admitted synchronous pull/write and nested-lock
    /// contention; it does not join the whole pass. Once it returns, later source
    /// consumption and ring publication are refused as `.retired`. A residual
    /// pass retains its storage while finishing metadata reads, lease release,
    /// diagnostics and `endPass`; retention alone would not fence reused content.
    private func retireFeeder() {
        guard let feeder else { return }
        feeder.retire()
        retiredFeederPullCallCount += feeder.pullCallCount
        // The residual report is DISCARDED, not delivered. `audioSupplyDidReport`
        // runs the same body as `pullPCM`'s tail, which can move buffering state
        // and emit `.buffering`; a teardown must not do that on its way out. What
        // is lost is one decode nudge for a pipeline that is stopping anyway.
        _ = feeder.drainReport()
        self.feeder = nil
    }

    /// Cut the feeder over so slot state is safe to mutate. Every transaction
    /// calls this FIRST — not "checks a flag and hopes".
    ///
    /// `beginSeekTransition`, `abortSeekTransition` and `flush` use the guarded
    /// pull/write cutover plus content invalidation before reset/prime/readmit;
    /// `stop` instead terminally retires the feeder. An obsolete pass can neither
    /// consume replacement PCM nor publish to a reused slot. This can wait for
    /// admitted synchronous PCM/display/compaction work and contention, without a
    /// hard time bound, but does not join every instruction in the pass. Retained
    /// storage supports its remaining bookkeeping. Whole-pass completion is a
    /// separate boundary, requested by the existing async EQ maintenance path.
    private func standDownFeederForTransaction() {
        guard let feeder else { return }
        // Order matters: revoke admission first, THEN bump the generation. After
        // the first statement no pull/write can occur while stood down; the
        // second keeps an old pass inadmissible after `syncFeederAdmission`.
        feeder.standDown()
        feeder.invalidateContent()
    }

    /// Output repair preserves a feeder that EQ may have stood down. Sampling
    /// can discover native loss; only current output may restore steady feeding.
    private func restoreFeederAdmissionForCurrentOutput() {
        let availability = outputAvailability
        guard availability == .available || availability == .fillOnly,
              activeSeekToken == nil, equalizerMaintenance == nil, !retainedMaintenancePaused else { return }
        syncFeederAdmission()
    }

    /// Re-admit the feeder after a transaction, if and only if the renderer is in
    /// a state that wants steady-state feeding.
    ///
    /// `abortSeekTransition` deliberately leaves the output gate asserted until a
    /// stop/open releases it, and this refuses to feed through an asserted gate —
    /// which is exactly the `guard !isSeekOutputGated` the old fill loop had.
    private func syncFeederAdmission() {
        guard let feeder, isRunning, !isSeekOutputGated, !maintenanceOutputHeld, pullSource != nil else { return }
        feeder.readmit(slot: activeSlotIndex, targetFrames: reserveTargetFrames)
    }

    private var reserveTargetFrames: Int {
        AudioRingReserve.contentFrames(
            forRate: playbackRate,
            sampleRate: Self.engineSampleRate
        )
    }

    /// Hand the feeder's supply facts to the session. Decode scheduling and
    /// buffering state, never the clock.
    private func drainFeederReport() {
        guard let feeder, let pullSource else { return }
        let report = feeder.drainReport()
        guard !report.isEmpty else { return }
        if report.refusedWrites > 0 {
            // A pass whose pulled PCM was thrown away because it raced a
            // transaction. Correct behaviour, and expected at up to one per
            // transaction that lands on a slow pull. Logged rather than counted
            // silently — a counter with no reader is not a measurement.
            PlayerLog.log(
                "[PathA] audio feeder refused \(report.refusedWrites) stale write(s) " +
                "passes=\(report.passes)"
            )
        }
        pullSource.audioSupplyDidReport(report)
    }

    /// MainActor. **The single delta producer for the media clock.**
    ///
    /// `AudioDrainProgress.advance` has exactly one call site (here) and
    /// `renderedContentDidAdvance` exactly one caller (here). Nothing else in this
    /// file — and nothing off MainActor — may report rendered content.
    func reportDrain() {
        // Diagnostic Logging only. Inclusive: it contains the session's clock
        // advance and the VM tick callback timed under `tick.sess`/`tick.vm`.
        let drainSpan = UIHitchMonitor.beginSpan("tick.drain")
        defer { UIHitchMonitor.endSpan(drainSpan) }
        // Sample actual short reads before the scheduling-gap report so the one
        // report can distinguish a late MainActor tick from a real source
        // starvation event. A seek gate intentionally suppresses this sample:
        // gated callback quanta are not source reads.
        if pullSource != nil, isRunning, !isSeekOutputGated {
            consumeSourceUnderflows()
        }
        noteDrainReportSchedulingGap()
        guard let pullSource, isRunning else { return }
        // While a seek is gated, the callback must not drain or report the old
        // active slot, and the producer must not refill it. Target PCM is filled
        // synchronously into the inactive slot by prepareSeekTransition.
        guard !isSeekOutputGated, !maintenanceOutputHeld, !retainedMaintenancePaused else { return }
        if pitchCorrectionActive, timePitchInstalled, !timePitchBypassed,
           timePitchProcessingLatencySeconds <= 0 {
            refreshTimePitchProcessingLatency()
        }
        let nativeSpan = UIHitchMonitor.beginSpan("drain.native")
        refreshEqualizerLatency()
        sampleNativeOutputAvailability()
        UIHitchMonitor.endSpan(nativeSpan)
        switch AudioHardwareStartAdmission.drainTickAction(
            startPending: hardwareStart.isPending,
            engineStarted: engineStarted,
            fillOnlyMode: fillOnlyMode,
            nativeOutputUnavailable: nativeOutputUnavailable,
            queueOutstanding: maintenanceOutputHeld || retainedMaintenancePaused || !hardwareStart.mayReuseEngine
        ) {
        case .holdClock:
            // An async hardware start is in flight (design §7). Nothing anyone
            // hears is consuming the ring — the render callback, if already
            // firing, is held at rate 0 — so the clock HOLDS: no simulated
            // drain (it would advance F1 across the ~300 ms start and skip
            // audio that was never played) and no report. Video, slaved to this
            // clock, waits on its first frame exactly as it did while `start()`
            // blocked the main thread — only now the UI thread is free. Supply
            // facts still flow; they never touch the clock.
            drainFeederReport()
            return
        case .simulateConsumer:
            // No hardware consumer owns the ring (Simulator, `PATHA_AUDIO_HW=0`,
            // or a soft-failed graph). Simulate one at real time × rate so the
            // SAME drain accounting below runs — the alternative (a second,
            // fill-side clock selected by a downcast) is the leak seam repair 1
            // removed, and it left the shipping clock path with no offline test.
            drainRingWithoutHardware()
        case .reportHardwareDrain:
            break
        }
        // Report DRAIN progress every tick (even when the ring is already full and
        // the refill below writes nothing): playback position = total written − what
        // is still in the ring. The ring drains smoothly at real time, so this rises
        // smoothly and the master clock stops jumping in fill-sized bursts.
        //
        // ONE snapshot supplies both terms — see `PCMRingDrainSnapshot`. Reading
        // `written` and `pending` from two independent places is a tear as soon as
        // the producer is not this actor.
        let ring = ringRouter.ring(at: activeSlotIndex)
        let snapshot = ring.drainSnapshot(channels: Self.engineChannels)
        let previouslyReportedFrames = slotDrainProgress[activeSlotIndex].reportedFrames
        let delta = slotDrainProgress[activeSlotIndex].advance(
            totalPulledFrames: snapshot.writtenFrames,
            pendingFrames: snapshot.pendingFrames
        )
        // Same observation and same still-current slot, before the callback
        // can settle EOF or otherwise retire/reuse it. There is no await or
        // external callback between the snapshot and this metadata retirement.
        let displayObservation = ring.observeAndRetireDisplayContent(
            using: snapshot,
            previouslyReportedFrames: previouslyReportedFrames,
            sampleRate: Self.engineSampleRate,
            publication: AudioRingPublication(slot: activeSlotIndex, epoch: activeEpoch)
        )
        if delta > 0 {
            pullSource.renderedContentDidAdvance(
                bySeconds: Double(delta) / Self.engineSampleRate,
                displayObservation: displayObservation
            )
        }
        // Supply facts last, and deliberately after the clock report: this is the
        // half that is allowed to be late, and it must never be able to influence
        // the delta above.
        drainFeederReport()
    }

    /// Top the named slot up to the reserve, and never above it. The ring's own
    /// write cursor is the frame accounting — there is no second counter to keep
    /// in step with it.
    private func fillRingTowardReserve(
        source: AudioPullSource,
        slotIndex: Int
    ) {
        let targetFrames = AudioRingReserve.contentFrames(
            forRate: playbackRate,
            sampleRate: Self.engineSampleRate
        )
        guard targetFrames > 0 else { return }
        let frameCount = targetFrames - ringRouter.ring(at: slotIndex).frameCount
        guard frameCount > 0 else { return }
        let sampleCount = frameCount * Self.engineChannels
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: sampleCount)
        let result = source.pullPCM(
            frameCount: frameCount,
            sampleRate: Self.engineSampleRate,
            channels: Self.engineChannels,
            into: buffer
        )
        transactionPullCallCount += 1
        let frames = max(0, min(result.frames, frameCount))
        guard frames > 0 else { return }
        ringRouter.ring(at: slotIndex).write(
            buffer,
            count: frames * Self.engineChannels,
            displaySpans: result.displaySpans,
            sampleRate: Self.engineSampleRate,
            channels: Self.engineChannels
        )
    }

    /// Record a gap between MainActor drain/report ticks.
    ///
    /// Audio supply is owned by `AudioRingFeeder` on its own queue, so this is
    /// not a feeder-fill heartbeat and does not prove an audible outage. The
    /// bounded deltas below keep the report diagnostic: hardware callback and
    /// rendered-frame progress, feeder pull-call progress, and actual source
    /// short reads are separate facts. Only the distinct source-underflow log
    /// below is evidence of audio starvation.
    private func noteDrainReportSchedulingGap() {
        let now = ContinuousClock.now
        let snapshot = renderDiagnosticsSnapshot
        let feederPullCalls = feeder?.pullCallCount ?? 0
        let shortReadCount = sourceUnderflowCount
        defer {
            lastDrainReportAt = now
            lastDrainReportDiagnostics = snapshot
            lastDrainReportFeederPullCalls = feederPullCalls
            lastDrainReportShortReadCount = shortReadCount
        }
        guard let lastDrainReportAt, drainReportGapLogCount < 5 else { return }
        let gap = now - lastDrainReportAt
        let gapMilliseconds = gap.components.seconds * 1000
            + gap.components.attoseconds / 1_000_000_000_000_000
        // Three report periods. Below that it is ordinary scheduler jitter; the
        // threshold is not a claim about feeder cadence or audible continuity.
        guard gapMilliseconds >= 60 else { return }
        drainReportGapLogCount += 1
        let callbackDelta = nonWrappingCounterDelta(
            current: snapshot.callbackCount,
            previous: lastDrainReportDiagnostics?.callbackCount ?? 0
        )
        let frameDelta = nonWrappingCounterDelta(
            current: snapshot.renderedFrameCount,
            previous: lastDrainReportDiagnostics?.renderedFrameCount ?? 0
        )
        let hardwareRenderedSeconds = Double(frameDelta) / Self.engineSampleRate
        let feederPullDelta = nonWrappingCounterDelta(
            current: feederPullCalls,
            previous: lastDrainReportFeederPullCalls ?? 0
        )
        let shortReadDelta: UInt64
        if let lastDrainReportShortReadCount,
           shortReadCount >= lastDrainReportShortReadCount {
            shortReadDelta = shortReadCount - lastDrainReportShortReadCount
        } else {
            shortReadDelta = 0
        }
        PlayerLog.log(
            "[PathA] MainActor audio drain-report scheduling gap=\(gapMilliseconds)ms " +
            "ring=\(String(format: "%.3f", renderRingContentSeconds))s " +
            "hardwareCallbacksDelta=\(callbackDelta) " +
            "hardwareRenderedSecondsDelta=\(String(format: "%.3f", hardwareRenderedSeconds)) " +
            "feederPullCallsDelta=\(feederPullDelta) " +
            "sourceShortReadDelta=\(shortReadDelta) " +
            "rate=\(String(format: "%.2f", playbackRate))"
        )
    }

    /// Return a diagnostic delta only while both snapshots are from the same
    /// monotone counter epoch. A reset or atomic counter wrap makes the current
    /// value smaller or negative; report no delta rather than evaluating an
    /// overflowing subtraction or manufacturing a huge hardware/feed interval.
    private func nonWrappingCounterDelta(current: Int, previous: Int) -> Int {
        guard current >= 0, previous >= 0, current >= previous else { return 0 }
        return current - previous
    }

    private func consumeSourceUnderflows() {
        let shortReads = ringRouter.ring(at: activeSlotIndex).takeShortReadCount()
        guard shortReads > 0 else { return }
        let (updatedCount, overflowed) = sourceUnderflowCount.addingReportingOverflow(
            UInt64(shortReads)
        )
        sourceUnderflowCount = overflowed ? .max : updatedCount
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUnderflowLogAt >= 1 else { return }
        lastUnderflowLogAt = now
        let sinceDrainReport = lastDrainReportAt.map { entry -> Int in
            let elapsed = ContinuousClock.now - entry
            return Int(elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000)
        } ?? -1
        PlayerLog.log(
            "[PathA] audio source underflow callbacks=\(shortReads) total=\(sourceUnderflowCount) " +
            "reserve=\(String(format: "%.3f", AudioRingReserve.contentSeconds(forRate: playbackRate)))s " +
            "rate=\(String(format: "%.2f", playbackRate)) " +
            // Empirically closes the "a gate returned silence while PCM > 0"
            // hypothesis on device: a gated or rate-0 quantum returns before
            // the ring read and records NO short read, so a non-zero count
            // already proves the ring itself was short.
            "ring=\(String(format: "%.3f", renderRingContentSeconds))s " +
            "gate=\(isSeekOutputGated ? 1 : 0) " +
            "sinceDrainReport=\(sinceDrainReport)ms"
        )
    }

    /// Fill-only consumer: discard `wall × rate` content seconds from the ring.
    ///
    /// This is a stand-in for the CoreAudio render callback, **not** a clock: it
    /// only decides how much of the ring has been consumed. The reported position
    /// is still counted in ring frames (content), so no wall time reaches F1.
    private func drainRingWithoutHardware() {
        let now = ContinuousClock.now
        guard let last = lastDrainWall else {
            lastDrainWall = now
            return
        }
        let measured = last.duration(to: now)
        let wallDelta = Double(measured.components.seconds)
            + Double(measured.components.attoseconds) / 1e18
        lastDrainWall = now
        guard wallDelta > 0 else { return }
        let rate = TimeInterval(max(playbackRate, 0))
        let frames = Int((wallDelta * rate * Self.engineSampleRate).rounded(.towardZero))
        guard frames > 0 else { return }
        var wantedSamples = frames * Self.engineChannels
        while wantedSamples > 0 {
            let chunk = min(wantedSamples, drainScratch.count)
            let got = ringRouter.ring(at: activeSlotIndex).read(
                into: &drainScratch,
                maxSamples: chunk
            )
            guard got > 0 else { break }
            wantedSamples -= got
        }
    }

    private func applyMixerGain() {
        guard hardwareStart.mayReuseEngine, let eng = engine else { return }
        eng.mainMixerNode.outputVolume = desiredMixerGain()
    }

    private func desiredMixerGain() -> Float {
        let muted = muteBox.withLock { $0 }
        let vol = volumeBox.withLock { $0 }
        return muted || maintenanceOutputHeld ? 0 : vol
    }

    private func prepareMixerForGraphStart() {
        mixerRampTask?.cancel()
        mixerRampTask = nil
        if hardwareStart.mayReuseEngine { engine?.mainMixerNode.outputVolume = 0 }
    }

    private func rampMixerInAfterGraphStart() {
        mixerRampTask?.cancel()
        mixerRampTask = nil
        guard nativeParametersExclusive, let eng = engine, engineStarted else { return }
        guard desiredMixerGain() > 0 else {
            eng.mainMixerNode.outputVolume = 0
            return
        }
        mixerRampTask = Task { @MainActor [weak self, weak eng] in
            for step in 1...Self.mixerStartupRampSteps {
                do {
                    try await Task.sleep(for: Self.mixerStartupRampStep)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      let eng,
                      self.engine === eng,
                      self.engineStarted, self.nativeParametersExclusive
                else { return }
                // Read the current setting at every step (not a captured target)
                // so a mute/volume edge during the ramp is honored at the next
                // step instead of being overwritten by a stale value.
                eng.mainMixerNode.outputVolume = self.desiredMixerGain() *
                    Float(step) / Float(Self.mixerStartupRampSteps)
            }
            guard let self, let eng, self.engine === eng, self.engineStarted,
                  self.nativeParametersExclusive else { return }
            eng.mainMixerNode.outputVolume = self.desiredMixerGain()
        }
    }
}

/// How much audio content has actually been RENDERED, in content frames.
///
/// `drained = totalPulled − stillInRing`. The consumer (CoreAudio render block on
/// device, the simulated drain offline) empties the ring at real time, so this
/// rises smoothly while the producer fills it in bursts. It is the arithmetic
/// behind the session's single F1 input, so it is a value type with no isolation
/// and no I/O — the shipping clock maths is unit-testable on its own.
struct AudioDrainProgress: Sendable, Equatable {
    private(set) var reportedFrames = 0

    /// Frames rendered since the last report. Never negative, never double-counts.
    mutating func advance(totalPulledFrames: Int, pendingFrames: Int) -> Int {
        let drained = max(0, totalPulledFrames - max(0, pendingFrames))
        let delta = drained - reportedFrames
        guard delta > 0 else { return 0 }
        reportedFrames = drained
        return delta
    }

    mutating func reset() {
        reportedFrames = 0
    }
}

/// Per-step timing telemetry for hardware audio bring-up when log capture is active.
struct AudioBringUpTiming {
    enum Step: CaseIterable {
        case category, preferred, activate, prepare, start
    }

    let enabled: Bool
    var path = "full"
    /// `AudioHardwareStartMode.rawValue`: `async` (start measured on the
    /// hardware queue) or `sync` (the `PATHA_AUDIO_ASYNC_START=0` rollback).
    var mode = AudioHardwareStartMode.sync.rawValue
    private let startedAt: CFTimeInterval
    /// When the main actor handed `start()` to the hardware queue. `nil` on
    /// the sync path, where the main actor is held for the whole bring-up.
    private var mainReleasedAt: CFTimeInterval?
    private var milliseconds: [Step: Double] = [:]

    init(enabled: Bool) {
        self.enabled = enabled
        self.startedAt = enabled ? CACurrentMediaTime() : 0
    }

    /// Accumulates, so the full path's second `prepare()` (sample-rate flip
    /// rebuild) adds to the first instead of replacing it.
    mutating func measure<T>(_ step: Step, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let begin = CACurrentMediaTime()
        defer { milliseconds[step, default: 0] += (CACurrentMediaTime() - begin) * 1000 }
        return try body()
    }

    /// A step measured elsewhere — the async `start()`, timed on the hardware
    /// queue and handed back with its completion. Accumulates like `measure`,
    /// so a failed reused start plus the full-build start report their sum.
    mutating func record(_ step: Step, milliseconds value: Double) {
        guard enabled, value.isFinite, value >= 0 else { return }
        milliseconds[step, default: 0] += value
    }

    /// First call wins: a reused-graph failure that falls through to a second
    /// async start keeps the first hand-off, which is when the main actor
    /// actually stopped paying for this bring-up.
    mutating func markMainThreadReleased() {
        guard enabled, mainReleasedAt == nil else { return }
        mainReleasedAt = CACurrentMediaTime()
    }

    func log() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let total = (now - startedAt) * 1000
        // `main=` is the part of `total` the main actor was held for. It is
        // what a `[Hang]` line can be compared against; on the async path the
        // remainder of `total` is queue time nobody blocked on.
        let main = ((mainReleasedAt ?? now) - startedAt) * 1000
        let fields = Step.allCases.map { step -> String in
            guard let value = milliseconds[step] else { return "\(step)=-" }
            return "\(step)=\(Int(value.rounded()))"
        }
        PlayerLog.log(
            "[PathA] audio bring-up timing path=\(path) mode=\(mode) "
                + fields.joined(separator: " ")
                + " main=\(Int(main.rounded()))ms"
                + " total=\(Int(total.rounded()))ms"
        )
    }
}

/// Lock-free float box for the audio render thread. The render callback reads `value` with
/// a relaxed atomic load — no `os_unfair_lock` (which can priority-invert a real-time thread).
final class AtomicFloatBox: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic<UInt32>(value.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Fixed source scratch owned by one render node. Allocated on the main thread when the node
/// is built and freed (ARC deinit) when the node is torn down — never on the render thread.
final class RenderScratch: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Float>
    init(capacity: Int) {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(capacity, 2))
        b.initialize(repeating: 0)
        buffer = b
    }
    deinit { buffer.deallocate() }
}

/// Per-node RT resampler phase/carry state (`PCMSourceReadPlan`'s companion).
/// Allocated once with the node (like `RenderScratch`) and mutated only on the
/// audio render thread; never touched from MainActor.
final class RenderResampleState: @unchecked Sendable {
    var phase: Double = 0
    var carryFrames = 0
    /// Up to 2 carried virtual-source frames, interleaved by channel.
    let carry: UnsafeMutableBufferPointer<Float>
    /// Last observed packed slot/epoch — detects a seek/content switch on the
    /// render thread from the word already loaded for ring selection, with no
    /// extra atomic.
    var lastPacked: UInt64 = .max

    init(channels: Int) {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(channels, 1) * 2)
        b.initialize(repeating: 0)
        carry = b
    }

    /// Drop continuity: used on a publication change, an output gate, or a
    /// short (ring-dry) read, so interpolation never spans a discontinuity.
    func reset() {
        phase = 0
        carryFrames = 0
    }

    deinit { carry.deallocate() }
}

/// Consistent producer/consumer cursor pair for the drain report.
/// Both terms derive from one pair of loads sharing `writtenFrames`, so
/// `written − pending` telescopes to the consumer's monotone cursor without torn over-reports.
struct PCMRingDrainSnapshot: Sendable, Equatable {
    /// Frames the producer has written into this slot since its last reset.
    let writtenFrames: Int
    /// Frames still in the ring: `writtenFrames − consumedFrames`.
    let pendingFrames: Int

    /// Frames the CONSUMER has taken. `written − pending` collapses to the
    /// consumer's own monotone cursor, which is the definition of "rendered":
    /// only `PCMFloatRing.read` moves it, and only the render callback (or the
    /// fill-only stand-in) calls that.
    var consumedFrames: Int { writtenFrames - pendingFrames }
}

/// Lock-free single-producer / single-consumer float ring.
///
/// Producer = the audio ring feeder (`write`); consumer = the audio render thread (`read`).
/// The consumer path performs no heap allocation and takes no lock, so it is safe to call from
/// an `AVAudioSourceNode` render block. Coordination is a pair of monotonic sample counters:
/// the producer owns `writeIndex`, the consumer owns `readIndex`, published with
/// acquire/release ordering. `used = write - read` never exceeds `capacity`, so slot ranges the
/// two sides touch are disjoint.
final class PCMFloatRing: @unchecked Sendable {
    static let defaultCapacitySamples = Int(EngineAudioRenderer.engineSampleRate)
        * EngineAudioRenderer.engineChannels
        * Int(AudioRingReserve.ringCapacitySeconds)
    private let capacity: Int
    private let backing: UnsafeMutableBufferPointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let shortReadCount = Atomic<Int>(0)
    /// Non-realtime metadata shared by every producer of this exact slot.
    /// `read` and the audio callback never access it.
    private let displayCustody = AudioRingDisplayCustody()

    init(capacity: Int = PCMFloatRing.defaultCapacitySamples) {
        let cap = max(capacity, 2)
        self.capacity = cap
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        buf.initialize(repeating: 0)
        backing = buf
    }
    deinit { backing.deallocate() }

    /// Best-effort reset. Call while the graph is paused/stopped: a concurrent reset only risks a
    /// bounded glitch (indices clamp), never an out-of-bounds access.
    func reset() {
        displayCustody.retireAll()
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
        shortReadCount.store(0, ordering: .relaxed)
    }

    /// Producer side (main actor). Copies into the fixed backing; on overflow only what fits is
    /// written. The reserve policy caps content depth at 3 s for this 4 s ring.
    @discardableResult
    func write(
        _ ptr: UnsafePointer<Float>, count: Int,
        displaySpans: [AudioDisplayLeaseSpan] = [], sampleRate: Double = 0, channels: Int = 0
    ) -> Int {
        guard count > 0 else { return 0 }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        guard free > 0 else { return 0 }
        let n = min(count, free)
        let start = w % capacity
        let firstLen = min(n, capacity - start)
        backing.baseAddress!.advanced(by: start).update(from: ptr, count: firstLen)
        if n > firstLen {
            backing.baseAddress!.update(from: ptr.advanced(by: firstLen), count: n - firstLen)
        }
        if channels > 0 {
            displayCustody.record(
                startFrame: w / channels, frames: n / channels,
                spans: displaySpans, sampleRate: sampleRate
            )
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Called only off the realtime thread, from the existing F1 snapshot and
    /// before consumed leases retire. This does not sample any cursor again.
    func observeAndRetireDisplayContent(
        using snapshot: PCMRingDrainSnapshot,
        previouslyReportedFrames: Int,
        sampleRate: Double,
        publication: AudioRingPublication
    ) -> AudioRenderedDisplayObservation? {
        displayCustody.observeAndRetireConsumed(
            using: snapshot, previouslyReportedFrames: previouslyReportedFrames,
            sampleRate: sampleRate, publication: publication
        )
    }

    func retireDisplayContent() {
        displayCustody.retireAll()
    }

    func write(_ floats: [Float]) {
        floats.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { write(base, count: buf.count) }
        }
    }

    /// Consumer side (audio render thread). No allocation, no lock. Returns samples copied.
    func read(into out: UnsafeMutablePointer<Float>, maxSamples: Int) -> Int {
        guard maxSamples > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(maxSamples, max(0, w - r))
        guard n > 0 else { return 0 }
        let start = r % capacity
        let firstLen = min(n, capacity - start)
        out.update(from: backing.baseAddress!.advanced(by: start), count: firstLen)
        if n > firstLen {
            out.advanced(by: firstLen).update(from: backing.baseAddress!, count: n - firstLen)
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// Called only by the source callback after a partial or empty read.
    func recordShortRead() {
        _ = shortReadCount.wrappingAdd(1, ordering: .relaxed)
    }

    /// MainActor diagnostic drain. Counts are advisory and deliberately do not
    /// participate in the SPSC audio-data ownership protocol.
    func takeShortReadCount() -> Int {
        shortReadCount.exchange(0, ordering: .acquiringAndReleasing)
    }

    /// Array convenience for non-realtime callers/tests (allocates via the caller's buffer only).
    func read(into out: inout [Float], maxSamples: Int) -> Int {
        let want = min(max(maxSamples, 0), out.count)
        guard want > 0 else { return 0 }
        return out.withUnsafeMutableBufferPointer { buf in
            read(into: buf.baseAddress!, maxSamples: want)
        }
    }

    func contentSeconds(sampleRate: Double, channels: Int) -> TimeInterval {
        guard channels > 0, sampleRate > 0 else { return 0 }
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return TimeInterval(max(0, w - r) / channels) / sampleRate
    }

    var frameCount: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return max(0, (w - r) / EngineAudioRenderer.engineChannels)
    }

    /// Consistent cursor snapshot for `reportDrain()`. Reads `readIndex` before
    /// `writeIndex` (both acquiring) so `r <= w` holds across monotone writes; any
    /// concurrent quiesced `reset()` clamps to zero and is absorbed by `AudioDrainProgress.advance`.
    func drainSnapshot(
        channels: Int = EngineAudioRenderer.engineChannels
    ) -> PCMRingDrainSnapshot {
        guard channels > 0 else {
            return PCMRingDrainSnapshot(writtenFrames: 0, pendingFrames: 0)
        }
        let r = readIndex.load(ordering: .acquiring)
        let w = writeIndex.load(ordering: .acquiring)
        let written = max(0, w / channels)
        let pending = max(0, min(written, (w - r) / channels))
        return PCMRingDrainSnapshot(writtenFrames: written, pendingFrames: pending)
    }
}
