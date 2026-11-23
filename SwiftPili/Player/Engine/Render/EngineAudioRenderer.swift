import AVFoundation
import Foundation
import Observation
import Synchronization
import os

enum PathAPitchFlag {
    static let envKey = "PATHA_PITCH"
    static let defaultsKey = "patha_pitch_enabled_v2"

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

enum AudioRingReserve {
    static let wallSeconds: TimeInterval = 0.25
    static let ringCapacitySeconds: TimeInterval = 4
    static let maximumContentSeconds = ringCapacitySeconds - 1

    static func contentSeconds(forRate rate: Float) -> TimeInterval {
        min(maximumContentSeconds, wallSeconds * TimeInterval(max(rate, 0)))
    }

    static func contentFrames(forRate rate: Float, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return max(0, Int((contentSeconds(forRate: rate) * sampleRate).rounded(.up)))
    }
}

enum PCMSourceReadPlan {
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

struct AudioRingPublication: Equatable, Sendable {
    let slot: Int
    let epoch: UInt64

    static let initial = AudioRingPublication(slot: 0, epoch: 0)

    init(slot: Int, epoch: UInt64) {
        self.slot = slot & 0x3
        self.epoch = epoch & 0x3FFF_FFFF_FFFF_FFFF
    }

    fileprivate var packed: UInt64 {
        (epoch &<< 2) | UInt64(slot & 0x3)
    }

    fileprivate init(packed: UInt64) {
        slot = Int(packed & 0x3)
        epoch = packed &>> 2
    }
}

final class PCMFloatRingRouter: @unchecked Sendable {
    static let slotCount = 4

    private final class AtomicPointerSlot: @unchecked Sendable {
        let address: Atomic<UInt>
        init(_ ring: PCMFloatRing) {
            address = Atomic<UInt>(UInt(bitPattern: Unmanaged.passUnretained(ring).toOpaque()))
        }
    }

    private let capacity: Int
    private let fixedSlots: [PCMFloatRing]
    private let slotPointers: [AtomicPointerSlot]
    private var overflowRetainedRings: [PCMFloatRing] = []

    let publishedPair = Atomic<UInt64>(AudioRingPublication.initial.packed)
    let acknowledgedPair = Atomic<UInt64>(AudioRingPublication.initial.packed)
    let outputGate = Atomic<UInt32>(0)
    let outputGateGeneration = Atomic<UInt64>(0)
    let acknowledgedOutputGateGeneration = Atomic<UInt64>(0)
    let acknowledgedOutputGatePair = Atomic<UInt64>(AudioRingPublication.initial.packed)

    init(capacity: Int = PCMFloatRing.defaultCapacitySamples) {
        self.capacity = capacity
        let allocated = (0..<Self.slotCount).map { _ in PCMFloatRing(capacity: capacity) }
        self.fixedSlots = allocated
        self.slotPointers = allocated.map { AtomicPointerSlot($0) }
    }

    func ring(at slot: Int) -> PCMFloatRing {
        let bits = slotPointers[slot & 0x3].address.load(ordering: .acquiring)
        return Unmanaged<PCMFloatRing>.fromOpaque(
            UnsafeMutableRawPointer(bitPattern: bits)!
        ).takeUnretainedValue()
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

    func retireAllDisplayContent() {
        for slot in 0..<Self.slotCount {
            ring(at: slot).retireDisplayContent()
        }
        for overflow in overflowRetainedRings {
            overflow.retireDisplayContent()
        }
    }

    func replaceRingInSlot(_ slot: Int) {
        let index = slot & 0x3
        let fresh = PCMFloatRing(capacity: capacity)
        overflowRetainedRings.append(fresh)
        slotPointers[index].address.store(
            UInt(bitPattern: Unmanaged.passUnretained(fresh).toOpaque()),
            ordering: .releasing
        )
    }

    func reclaimOverflowRingsIfSafe(preservingSlot: Int, pendingFeederCounts: [Int]) {
        let preserved = preservingSlot & 0x3
        for index in 0..<Self.slotCount where index != preserved && pendingFeederCounts[index] == 0 {
            let fixed = fixedSlots[index]
            if ring(at: index) !== fixed {
                fixed.reset()
                slotPointers[index].address.store(
                    UInt(bitPattern: Unmanaged.passUnretained(fixed).toOpaque()),
                    ordering: .releasing
                )
            }
        }
        guard !overflowRetainedRings.isEmpty else { return }
        let liveIDs = Set((0..<Self.slotCount).map { ObjectIdentifier(ring(at: $0)) })
        overflowRetainedRings.removeAll { !liveIDs.contains(ObjectIdentifier($0)) }
    }
}

@MainActor
@Observable
final class EngineAudioRenderer: MediaAudioRendering {
    nonisolated static let engineSampleRate: Double = 48_000
    nonisolated static let engineChannels: Int = 2
    static let defaultFillPeriod: TimeInterval = 0.02
    nonisolated static let maxRenderScratchFloats: Int = 48_000 * 2 * 2

    private var engine: AVAudioEngine?
    private let nativeOutput: AudioNativeOutputBinding
    private var nativeOutputUnavailable = false
    @ObservationIgnored
    private lazy var outputStateNotifier = AudioOutputStateNotifier { [weak self] in
        self?.outputAvailability ?? .stopped
    }
    private var repairingNativeOutput = false
    private var bringUpTiming = AudioBringUpTiming(enabled: false)
    private var sourceNode: AVAudioSourceNode?
    private var cachedGraphConnectFormat: AVAudioFormat?
    private var cachedGraphPitchMode = false
    private var cachedGraphDiagnosticsEnabled = false
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
            let toggledBypass = oldValue.isBypassed != equalizerConfiguration.isBypassed
            if !oldValue.isBypassed, equalizerConfiguration.isBypassed { equalizerHistoryDirty = true }
            equalizerRevision &+= 1
            if oldValue.isBypassed, !equalizerConfiguration.isBypassed, equalizerMaintenance != nil {
                pendingEqualizerReset = true
            }
            adoptEqualizerConfiguration(toggledBypass: toggledBypass)
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
    private let ringRouter = PCMFloatRingRouter()
    private let renderDiagnostics = AudioRenderDiagnostics()
    private weak var pullSource: (any AudioPullSource)?
    private var drainReportTask: Task<Void, Never>?
    private var feeder: AudioRingFeeder?
    private var retiredFeederPullCallCount = 0
    private let rateBox = AtomicFloatBox(1)
    private var requestedRenderRate: Float = 1
    nonisolated private static let hardwareQueue = DispatchQueue(
        label: "com.swiftpili.patha.audio-hw",
        qos: .userInitiated
    )
    private var hardwareStart = AudioHardwareStartAdmission()
    private var pendingHardwareStartContext: PendingHardwareStart?
    private struct PendingHardwareStart {
        let connectFormat: AVAudioFormat
        let reusedGraph: Bool
        let nativeStamp: AudioNativeOutputBinding.Stamp
        let sessionSampleRate: Double
        let sessionChannels: Int
        var maintenancePermit: AudioMaintenancePermit?
    }
    private let muteBox = OSAllocatedUnfairLock(initialState: false)
    private let volumeBox = OSAllocatedUnfairLock(initialState: Float(1))
    private var mixerRampTask: Task<Void, Never>?
    private var softTransitionSerial: UInt64 = 0
    private var softTransitionActions: [@MainActor () -> Void] = []
    private static let mixerStartupRampSteps = 5
    private static let mixerStartupRampStep: Duration = .milliseconds(8)
    private static let softTransitionFadeOutSteps = 3
    private static let softTransitionFadeOutStep: Duration = .milliseconds(4)

    private(set) var isRunning = false
    private(set) var engineStarted = false
    private(set) var fillOnlyMode = false
    var hardwareStartPending: Bool { hardwareStart.isPending }
    private(set) var isResamplingToHardware = false
    private(set) var hardwareSampleRate: Double = 0
    var fillCallCount: Int {
        transactionPullCallCount + retiredFeederPullCallCount + (feeder?.pullCallCount ?? 0)
    }
    private(set) var transactionPullCallCount = 0
    private var activeSlotIndex = 0
    private var activeEpoch: UInt64 = 0
    private var nextPublicationEpoch: UInt64 = 1
    private var slotDrainProgress = Array(repeating: AudioDrainProgress(), count: PCMFloatRingRouter.slotCount)
    private var slotRetiredEpoch = Array(repeating: UInt64(0), count: PCMFloatRingRouter.slotCount)
    private var slotPendingFeederCount = Array(repeating: 0, count: PCMFloatRingRouter.slotCount)
    private var seekTokenGeneration: UInt64 = 0
    private var activeSeekToken: MediaAudioSeekToken?
    private var stagedSeekSlot: Int?
    private var stagedSeekWasPublished = false
    private var nextSeekGateGeneration: UInt64 = 0
    private var activeSeekGateGeneration: UInt64 = 0
    private var preserveCommittedSlotOnNextStart = false
    private var lastPublishedSeekEpoch: UInt64 = 0
    private var lastAcknowledgedSeekEpoch: UInt64 = 0

    private(set) var seekPublicationCount = 0
    private(set) var seekAcknowledgementCount = 0
    private(set) var seekAbortCount = 0
    private(set) var isSeekOutputGated = false

    private var lastDrainWall: ContinuousClock.Instant?
    private var drainScratch = [Float](repeating: 0, count: 4_800 * 2)
    private(set) var sourceUnderflowCount: UInt64 = 0
    private var lastUnderflowLogAt: TimeInterval = 0

    private(set) var pitchCorrectionActive = false
    private(set) var timePitchInstalled = false
    private(set) var timePitchRate: Float = 1
    private(set) var timePitchBypassed = true
    private(set) var timePitchProcessingLatencySeconds: TimeInterval = 0
    private(set) var timePitchResetCount = 0

    var presentationTiming: MediaAudioPresentationTiming {
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
        resetDrainReportSession()
        pullSource = source
        pitchCorrectionActive = PathAPitchFlag.isEnabled()
        let initialRate = max(0, playbackRate)
        let initialVolume = max(0, min(volume, 1))
        let initialMute = isMuted
        setRenderRate(pitchCorrectionActive
            ? (initialRate <= 0.000_1 ? 0 : 1)
            : initialRate)
        volumeBox.withLock { $0 = initialVolume }
        muteBox.withLock { $0 = initialMute }
        renderDiagnostics.reset()
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
        revokeAudioMaintenancePermission()
        equalizerLatency = .unreported
        pitchLatency = .unreported
        nativeOutputUnavailable = true
        hardwareStart.invalidate()
        pendingHardwareStartContext = nil
        mixerRampTask?.cancel()
        mixerRampTask = nil
        softTransitionActions.removeAll()
        refreshRenderRateBox()
    }

    private func bindNativeOutput(_ eng: AVAudioEngine) {
        bindNativeOutput(object: eng, nativeIsRunning: { [weak eng] in eng?.isRunning ?? false })
    }

    func bindNativeOutput(object: AnyObject, nativeIsRunning: @escaping @MainActor () -> Bool) {
        nativeOutput.bind(
            object: object,
            notification: .AVAudioEngineConfigurationChange,
            nativeIsRunning: nativeIsRunning,
            onInvalidation: { [weak self] in
                guard let self else { return }
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

    private func isSlotSafeToReset(_ slot: Int, excludingStaged: Bool = true) -> Bool {
        guard (0..<PCMFloatRingRouter.slotCount).contains(slot) else { return false }
        let published = ringRouter.publishedPublication()
        if slot == activeSlotIndex || slot == published.slot { return false }
        if excludingStaged, slot == stagedSeekSlot { return false }
        if slotPendingFeederCount[slot] > 0 { return false }
        if hasRealtimeConsumer || !hardwareStart.mayReuseEngine {
            return slotRetiredEpoch[slot] <= ringRouter.acknowledgedPublication().epoch
        }
        return true
    }

    private func acquireSafeIdleSlot(excludingStaged: Bool = true) -> Int {
        if let safe = (0..<PCMFloatRingRouter.slotCount)
            .filter({ isSlotSafeToReset($0, excludingStaged: excludingStaged) })
            .min(by: { slotRetiredEpoch[$0] < slotRetiredEpoch[$1] }) {
            ringRouter.ring(at: safe).reset()
            slotDrainProgress[safe].reset()
            return safe
        }
        let published = ringRouter.publishedPublication()
        let fallback = (0..<PCMFloatRingRouter.slotCount)
            .filter {
                $0 != published.slot
                    && (!excludingStaged || $0 != stagedSeekSlot)
                    && slotPendingFeederCount[$0] == 0
            }
            .min(by: { slotRetiredEpoch[$0] < slotRetiredEpoch[$1] })
            ?? (0..<PCMFloatRingRouter.slotCount).first {
                $0 != published.slot && (!excludingStaged || $0 != stagedSeekSlot)
            }
            ?? ((published.slot + 1) & 0x3)
        ringRouter.replaceRingInSlot(fallback)
        slotDrainProgress[fallback].reset()
        return fallback
    }

    private func publishSlot(_ slot: Int) -> AudioRingPublication {
        let previousPublished = ringRouter.publishedPublication()
        let epoch = nextPublicationEpoch
        nextPublicationEpoch &+= 1
        if nextPublicationEpoch == 0 || (nextPublicationEpoch >> 62) != 0 {
            nextPublicationEpoch = 1
        }
        let publication = AudioRingPublication(slot: slot, epoch: epoch)
        ringRouter.publish(publication)
        if previousPublished.slot != slot {
            slotRetiredEpoch[previousPublished.slot] = epoch
        }
        if !hasRealtimeConsumer && hardwareStart.mayReuseEngine {
            ringRouter.acknowledgePublishedPublication()
            reclaimSafeRetiredSlots()
        }
        return publication
    }

    private func reclaimSafeRetiredSlots() {
        guard !hasRealtimeConsumer, hardwareStart.mayReuseEngine else { return }
        let publishedSlot = ringRouter.publishedPublication().slot
        for index in 0..<PCMFloatRingRouter.slotCount
        where index != publishedSlot && slotPendingFeederCount[index] == 0 {
            slotRetiredEpoch[index] = 0
        }
        ringRouter.reclaimOverflowRingsIfSafe(
            preservingSlot: publishedSlot,
            pendingFeederCounts: slotPendingFeederCount
        )
    }

    func beginSeekTransition(source: AudioPullSource) -> MediaAudioSeekToken {
        revokeAudioMaintenancePermission()
        equalizerHistoryDirty = true
        pullSource = source
        seekTokenGeneration &+= 1
        let token = MediaAudioSeekToken(generation: seekTokenGeneration)

        standDownFeederForTransaction()

        assertSeekOutputGate()
        ringRouter.retireAllDisplayContent()

        if let oldSlot = stagedSeekSlot, !stagedSeekWasPublished,
           isSlotSafeToReset(oldSlot, excludingStaged: false) {
            ringRouter.ring(at: oldSlot).reset()
            slotDrainProgress[oldSlot].reset()
        }
        stagedSeekSlot = nil
        stagedSeekWasPublished = false

        let targetSlot = acquireSafeIdleSlot()
        stagedSeekSlot = targetSlot
        activeSeekToken = token
        lastDrainWall = ContinuousClock.now
        return token
    }

    func prepareSeekTransition(
        _ token: MediaAudioSeekToken,
        source: AudioPullSource
    ) -> MediaAudioSeekPreparation {
        guard activeSeekToken == token,
              let slot = stagedSeekSlot,
              !stagedSeekWasPublished
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

        guard isAuthorized?() ?? true else {
            abortSeekTransition(token)
            return false
        }

        guard await resumeSeekEqualizerIfNeeded(
            maintenanceSerial, token: token, resumesPlayback: resumesPlayback,
            isAuthorized: isAuthorized, resumeAdmission: resumeAdmission
        ) else { return false }

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
        let publication = publishSlot(slot)
        stagedSeekWasPublished = true
        lastPublishedSeekEpoch = publication.epoch
        seekPublicationCount += 1
        if !hasRealtimeConsumer {
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
        slotDrainProgress[slot].reset()
        lastDrainWall = ContinuousClock.now
        preserveCommittedSlotOnNextStart = !isRunning
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false

        if maintenanceSerial == nil, pitchCorrectionActive, !timePitchBypassed {
            if nativeOutputUnavailable || nativeOutput.hasUnresolvedConfiguration {
                pendingPitchReset = true
            } else {
                resetTimePitchState()
            }
        }
        beforeGateRelease?()
        if let serial = maintenanceSerial { releaseEqualizerMaintenance(serial, accepted: true) }
        ringRouter.setOutputGated(false)
        isSeekOutputGated = false
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
        if let slot = stagedSeekSlot, !stagedSeekWasPublished,
           isSlotSafeToReset(slot, excludingStaged: false) {
            ringRouter.ring(at: slot).reset()
            slotDrainProgress[slot].reset()
        }
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false
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
            noteNativeOutputUnavailable()
            return nil
        }
    }

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
        if continuingDeferredAuthorizedOutput {
            equalizerMaintenance?.permit?.revoke()
            if equalizerMaintenance != nil { equalizerMaintenance?.retired = true }
        } else {
            revokeAudioMaintenancePermission()
        }
        hardwareStart.invalidate()
        pendingHardwareStartContext = nil
        mixerRampTask?.cancel()
        mixerRampTask = nil
        softTransitionActions.removeAll()
        nativeOutput.retire()
        if let eng = engine {
            if nativeParametersExclusive {
                eng.mainMixerNode.outputVolume = 0
                if eng.isRunning { eng.stop() }
                if let equalizer = equalizerNode {
                    eng.disconnectNodeOutput(equalizer)
                    eng.detach(equalizer)
                }
                if let pitch = timePitchNode {
                    eng.disconnectNodeOutput(pitch)
                    eng.detach(pitch)
                }
                if let node = sourceNode {
                    eng.disconnectNodeOutput(node)
                    eng.detach(node)
                }
            } else {
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
        defer {
            if !hardwareStart.isPending { bringUpTiming.log() }
        }
        if ExperimentalSettingsPolicy.isAllowed(.diagnostics),
           ProcessInfo.processInfo.environment["PATHA_AUDIO_HW"] == "0" {
            softFailHardware(reason: "PATHA_AUDIO_HW=0", allowsLogicalOutput: true)
            return
        }
        guard let sessionInfo = preparePlaybackSessionBestEffort() else { return }
        reuseOrInstallHardwareGraph(sessionInfo: sessionInfo, startMode: startMode)
    }

    private func reuseOrInstallHardwareGraph(
        sessionInfo: (sampleRate: Double, channels: Int),
        startMode: AudioHardwareStartMode
    ) {
        if let eng = engine, let cachedFormat = cachedGraphConnectFormat,
           cachedGraphPitchMode == pitchCorrectionActive,
           cachedGraphDiagnosticsEnabled == PlayerLog.isEnabled {
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
            if pendingEqualizerReset {
                equalizerNode?.reset()
                equalizerHistoryDirty = false
                pendingEqualizerReset = false
            }
            let resetPitch = pendingPitchReset
            pendingPitchReset = false
            applyTimePitchRate(max(0, playbackRate), resetUnit: resetPitch)
        } else {
            applyTimePitchRate(max(0, playbackRate), resetUnit: false)
        }
        applyEqualizerToCurrentGraph()
        refreshEqualizerLatency()
        refreshRenderRateBox()
        if reusedGraph {
            timePitchInstalled = timePitchNode != nil
        }
        hardwareSampleRate = connectFormat.sampleRate
        isResamplingToHardware = abs(connectFormat.sampleRate - Self.engineSampleRate) >= 1.0
        rampMixerInAfterGraphStart()
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
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
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
        defer {
            settleHardwareQueueWaiters()
            refreshRenderRateBox()
        }
        switch verdict {
        case .accept:
            pendingHardwareStartContext = nil
            if equalizerMaintenance != nil { return }
            guard let context else {
                lastDrainWall = ContinuousClock.now
                softFailHardware(reason: "accepted start without context")
                return
            }
            bringUpTiming.record(.start, milliseconds: startMilliseconds)
            acceptHardwareStart(connectFormat: context.connectFormat, reusedGraph: context.reusedGraph)
            bringUpTiming.log()
        case .unavailable:
            noteNativeOutputUnavailable()
            PlayerLog.log("[PathA] audio start has no current native output; clock held")
        case .softFail:
            pendingHardwareStartContext = nil
            let carriedDeferredPermit = context?.maintenancePermit
            bringUpTiming.record(.start, milliseconds: startMilliseconds)
            lastDrainWall = ContinuousClock.now
            if let context, context.reusedGraph {
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

    private func enqueueHardwareStop(_ eng: AVAudioEngine, detaching nodes: [AVAudioNode], rampDown: Bool = false) {
        hardwareStart.noteOperationSubmitted()
        refreshRenderRateBox()
        let transfer = AudioHardwareEngineTransfer(eng, nodes: nodes)
        Self.hardwareQueue.async { [weak self] in
            if rampDown {
                Self.rampDownAndStop(transfer.engine)
            } else {
                Self.stopAndDetach(transfer.engine, nodes: transfer.nodes)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.acknowledgeHardwareOperation()
                }
            }
        }
    }

    private func acknowledgeHardwareOperation() {
        hardwareStart.acknowledgeOperation()
        reclaimSafeRetiredSlots()
        settleHardwareQueueWaiters()
        refreshRenderRateBox()
    }

    nonisolated private static func rampDownAndStop(_ eng: AVAudioEngine) {
        let startVolume = eng.mainMixerNode.outputVolume
        if eng.isRunning, startVolume > 0.000_1 {
            let steps = 4
            for step in 1...steps {
                Thread.sleep(forTimeInterval: 0.003)
                eng.mainMixerNode.outputVolume = startVolume * Float(steps - step) / Float(steps)
            }
        }
        eng.mainMixerNode.outputVolume = 0
        if eng.isRunning { eng.stop() }
    }

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
        let scratch = RenderScratch(capacity: Self.maxRenderScratchFloats)
        let resample = RenderResampleState(channels: ringChannels)
        return AVAudioSourceNode(format: connectFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let capturesDiagnostics = diagnosticsEnabled
                && diagnosticsPermit?.isValid == true && PlayerLog.isEnabled
            if capturesDiagnostics {
                diagnostics.recordCallback(frameCount: frames)
            }
            let publication = AudioRingPublication(
                packed: ringRouter.publishedPair.load(ordering: .acquiring)
            )
            if publication.packed != resample.lastPacked {
                resample.lastPacked = publication.packed
                resample.reset()
            }
            let acknowledged = AudioRingPublication(
                packed: ringRouter.acknowledgedPair.load(ordering: .relaxed)
            )
            if publication != acknowledged {
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
                ringRouter.acknowledgeOutputGateAtCallbackBoundary(publication: publication)
            }
            if outputGated
                    || rate <= 0.000_1 || frames <= 0 {
                resample.reset()
                return noErr
            }
            let stretch = pitchMode ? 1.0 : Double(rate)
            let step = ringPerHW * stretch
            if step == 1, resample.phase != 0 || resample.carryFrames != 0 {
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
            self.continuingDeferredAuthorizedOutput = true
            if self.equalizerMaintenance != nil || self.retainedMaintenancePaused
                || self.nativeOutputUnavailable || self.nativeOutput.hasUnresolvedConfiguration {
                try? self.reconcileOutputForAuthorizedPlayback()
            } else if self.fillOnlyMode {
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

    private func adoptEqualizerConfiguration(toggledBypass: Bool = false) {
        guard equalizerNode != nil else {
            equalizerStatus = fillOnlyMode ? .unsupported("No native audio output") : .retainedNoGraph
            return
        }
        guard nativeParametersExclusive else {
            equalizerStatus = .pendingNativeAccess
            return
        }
        if let eng = engine, eng.isRunning, engineStarted {
            let needsSoftReset = toggledBypass
                || (!equalizerConfiguration.isBypassed && (equalizerHistoryDirty || pendingEqualizerReset))
            if needsSoftReset {
                performSoftParameterTransition { [weak self] in
                    guard let self else { return }
                    if self.equalizerHistoryDirty, !self.equalizerConfiguration.isBypassed {
                        self.equalizerNode?.reset()
                        self.equalizerHistoryDirty = false
                    }
                    self.pendingEqualizerReset = false
                    self.applyEqualizerToCurrentGraph()
                    self.refreshEqualizerLatency()
                }
            } else {
                applyEqualizerToCurrentGraph()
                refreshEqualizerLatency()
            }
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
        softTransitionActions.removeAll()
        if seek == nil {
            feeder?.setTargetFrames(0)
        } else {
            standDownFeederForTransaction()
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
        if let feeder {
            let receipt = feeder.standDown()
            trackFeederStandDown(receipt, slot: feeder.admission.admittedSlot)
            feeder.invalidateContent()
            await receipt.join()
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
            rampMixerInAfterGraphStart()
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

    private func performSoftParameterTransition(_ action: @escaping @MainActor () -> Void) {
        guard nativeParametersExclusive, let eng = engine, eng.isRunning, engineStarted else {
            action()
            return
        }
        mixerRampTask?.cancel()
        mixerRampTask = nil
        softTransitionActions.append(action)
        softTransitionSerial &+= 1
        let serial = softTransitionSerial
        let startVolume = eng.mainMixerNode.outputVolume
        if startVolume <= 0.000_1 {
            eng.mainMixerNode.outputVolume = 0
            let pending = softTransitionActions
            softTransitionActions.removeAll()
            for pendingAction in pending { pendingAction() }
            rampMixerInAfterGraphStart()
            return
        }
        mixerRampTask = Task { @MainActor [weak self, weak eng] in
            for step in 1...Self.softTransitionFadeOutSteps {
                do {
                    try await Task.sleep(for: Self.softTransitionFadeOutStep)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      let eng,
                      self.softTransitionSerial == serial,
                      self.engine === eng,
                      eng.isRunning,
                      self.nativeParametersExclusive
                else { return }
                eng.mainMixerNode.outputVolume = startVolume
                    * Float(Self.softTransitionFadeOutSteps - step)
                    / Float(Self.softTransitionFadeOutSteps)
            }
            guard !Task.isCancelled,
                  let self,
                  let eng,
                  self.softTransitionSerial == serial,
                  self.engine === eng,
                  eng.isRunning,
                  self.nativeParametersExclusive
            else { return }
            eng.mainMixerNode.outputVolume = 0
            let pending = self.softTransitionActions
            self.softTransitionActions.removeAll()
            for pendingAction in pending { pendingAction() }
            self.rampMixerInAfterGraphStart()
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
        drainReportTask?.cancel()
        drainReportTask = nil
        UIHitchMonitor.measureCounted("audio.stop.feeder") { retireFeeder() }
        mixerRampTask?.cancel()
        mixerRampTask = nil
        softTransitionActions.removeAll()
        hardwareStart.invalidate()
        pendingHardwareStartContext = nil
        if let eng = engine {
            if nativeParametersExclusive {
                if preserveCommittedContent, eng.isRunning, eng.mainMixerNode.outputVolume > 0.000_1 {
                    enqueueHardwareStop(eng, detaching: [], rampDown: true)
                } else {
                    UIHitchMonitor.measureCounted("audio.stop.native") {
                        eng.mainMixerNode.outputVolume = 0
                        if eng.isRunning { eng.stop() }
                    }
                }
            } else {
                enqueueHardwareStop(eng, detaching: [])
            }
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
        if preserveCommittedContent {
            preserveCommittedSlotOnNextStart = false
        } else {
            ringRouter.retireAllDisplayContent()
            let nextSlot = acquireSafeIdleSlot()
            let publication = publishSlot(nextSlot)
            activeSlotIndex = nextSlot
            activeEpoch = publication.epoch
            lastPublishedSeekEpoch = 0
            lastAcknowledgedSeekEpoch = 0
            preserveCommittedSlotOnNextStart = false
        }
        lastDrainWall = nil
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
        standDownFeederForTransaction()
        ringRouter.retireAllDisplayContent()
        activeSeekToken = nil
        stagedSeekSlot = nil
        stagedSeekWasPublished = false
        isSeekOutputGated = false
        ringRouter.setOutputGated(false)
        let nextSlot = acquireSafeIdleSlot()
        let publication = publishSlot(nextSlot)
        activeSlotIndex = nextSlot
        activeEpoch = publication.epoch
        preserveCommittedSlotOnNextStart = false
        lastDrainWall = ContinuousClock.now
        if pitchCorrectionActive {
            resetTimePitchState()
        } else {
            timePitchRate = 1
            timePitchBypassed = true
            timePitchProcessingLatencySeconds = 0
        }
        syncFeederAdmission()
    }

    private func applyPlaybackRate(_ rate: Float, previous: Float) {
        feeder?.setTargetFrames(
            AudioRingReserve.contentFrames(forRate: max(0, rate), sampleRate: Self.engineSampleRate)
        )
        if pitchCorrectionActive {
            setRenderRate(rate <= 0.000_1 ? 0 : 1)
            let wasUnity = previous <= 0.000_1 || abs(previous - 1) < 0.001
            let isUnity = rate <= 0.000_1 || abs(rate - 1) < 0.001
            if wasUnity != isUnity, engineStarted, let eng = engine, eng.isRunning, nativeParametersExclusive {
                performSoftParameterTransition { [weak self] in
                    guard let self else { return }
                    self.pendingPitchReset = false
                    self.applyTimePitchRate(max(0, self.playbackRate), resetUnit: true)
                }
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

    private func refreshRenderRateBox() {
        rateBox.value = hardwareStart.renderRate(
            requested: requestedRenderRate,
            nativeOutputUnavailable: maintenanceOutputHeld || retainedMaintenancePaused
                || nativeOutputUnavailable || nativeOutput.hasUnresolvedConfiguration
        )
        noteOutputStateChange()
    }

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
        let applied: Float = unity ? 1 : max(1.0 / 32.0, min(rate, 32))
        timePitchRate = applied
        if let pitch = timePitchNode {
            if resetUnit { pitch.reset(); timePitchResetCount += 1 }
            pitch.rate = applied
            pitch.bypass = unity
            refreshTimePitchProcessingLatency()
        } else if resetUnit {
            timePitchResetCount += 1
            timePitchProcessingLatencySeconds = 0
        } else {
            timePitchProcessingLatencySeconds = 0
        }
    }

    private func resetTimePitchState() {
        applyTimePitchRate(max(0, playbackRate), resetUnit: true)
    }

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

    private func retireFeeder() {
        guard let feeder else { return }
        let slot = feeder.admission.admittedSlot
        let receipt = feeder.retire()
        trackFeederStandDown(receipt, slot: slot)
        retiredFeederPullCallCount += feeder.pullCallCount
        _ = feeder.drainReport()
        self.feeder = nil
    }

    private func standDownFeederForTransaction() {
        guard let feeder else { return }
        let slot = feeder.admission.admittedSlot
        let receipt = feeder.standDown()
        trackFeederStandDown(receipt, slot: slot)
        feeder.invalidateContent()
    }

    private func trackFeederStandDown(_ receipt: FeederStandDownReceipt, slot: Int) {
        guard receipt.requiresJoin else { return }
        let index = slot & 0x3
        slotPendingFeederCount[index] += 1
        receipt.onQuiesce { [weak self] in
            guard let self else { return }
            self.slotPendingFeederCount[index] = max(0, self.slotPendingFeederCount[index] - 1)
            self.reclaimSafeRetiredSlots()
        }
    }

    private func restoreFeederAdmissionForCurrentOutput() {
        let availability = outputAvailability
        guard availability == .available || availability == .fillOnly,
              activeSeekToken == nil, equalizerMaintenance == nil, !retainedMaintenancePaused else { return }
        syncFeederAdmission()
    }

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

    private func drainFeederReport() {
        guard let feeder, let pullSource else { return }
        let report = feeder.drainReport()
        guard !report.isEmpty else { return }
        if report.refusedWrites > 0 {
            PlayerLog.log(
                "[PathA] audio feeder refused \(report.refusedWrites) stale write(s) " +
                "passes=\(report.passes)"
            )
        }
        pullSource.audioSupplyDidReport(report)
    }

    func reportDrain() {
        let drainSpan = UIHitchMonitor.beginSpan("tick.drain")
        defer { UIHitchMonitor.endSpan(drainSpan) }
        if pullSource != nil, isRunning, !isSeekOutputGated {
            consumeSourceUnderflows()
        }
        noteDrainReportSchedulingGap()
        guard let pullSource, isRunning else { return }
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
            drainFeederReport()
            return
        case .simulateConsumer:
            drainRingWithoutHardware()
        case .reportHardwareDrain:
            break
        }
        let ring = ringRouter.ring(at: activeSlotIndex)
        let snapshot = ring.drainSnapshot(channels: Self.engineChannels)
        let previouslyReportedFrames = slotDrainProgress[activeSlotIndex].reportedFrames
        let delta = slotDrainProgress[activeSlotIndex].advance(
            totalPulledFrames: snapshot.writtenFrames,
            pendingFrames: snapshot.pendingFrames
        )
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
        drainFeederReport()
    }

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
            "ring=\(String(format: "%.3f", renderRingContentSeconds))s " +
            "gate=\(isSeekOutputGated ? 1 : 0) " +
            "sinceDrainReport=\(sinceDrainReport)ms"
        )
    }

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
        softTransitionActions.removeAll()
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
                eng.mainMixerNode.outputVolume = self.desiredMixerGain() *
                    Float(step) / Float(Self.mixerStartupRampSteps)
            }
            guard let self, let eng, self.engine === eng, self.engineStarted,
                  self.nativeParametersExclusive else { return }
            eng.mainMixerNode.outputVolume = self.desiredMixerGain()
        }
    }
}

struct AudioDrainProgress: Sendable, Equatable {
    private(set) var reportedFrames = 0

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

struct AudioBringUpTiming {
    enum Step: CaseIterable {
        case category, preferred, activate, prepare, start
    }

    let enabled: Bool
    var path = "full"
    var mode = AudioHardwareStartMode.sync.rawValue
    private let startedAt: CFTimeInterval
    private var mainReleasedAt: CFTimeInterval?
    private var milliseconds: [Step: Double] = [:]

    init(enabled: Bool) {
        self.enabled = enabled
        self.startedAt = enabled ? CACurrentMediaTime() : 0
    }

    mutating func measure<T>(_ step: Step, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let begin = CACurrentMediaTime()
        defer { milliseconds[step, default: 0] += (CACurrentMediaTime() - begin) * 1000 }
        return try body()
    }

    mutating func record(_ step: Step, milliseconds value: Double) {
        guard enabled, value.isFinite, value >= 0 else { return }
        milliseconds[step, default: 0] += value
    }

    mutating func markMainThreadReleased() {
        guard enabled, mainReleasedAt == nil else { return }
        mainReleasedAt = CACurrentMediaTime()
    }

    func log() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let total = (now - startedAt) * 1000
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

final class AtomicFloatBox: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic<UInt32>(value.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

final class RenderScratch: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Float>
    init(capacity: Int) {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(capacity, 2))
        b.initialize(repeating: 0)
        buffer = b
    }
    deinit { buffer.deallocate() }
}

final class RenderResampleState: @unchecked Sendable {
    var phase: Double = 0
    var carryFrames = 0
    let carry: UnsafeMutableBufferPointer<Float>
    var lastPacked: UInt64 = .max

    init(channels: Int) {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(channels, 1) * 2)
        b.initialize(repeating: 0)
        carry = b
    }

    func reset() {
        phase = 0
        carryFrames = 0
    }

    deinit { carry.deallocate() }
}

struct PCMRingDrainSnapshot: Sendable, Equatable {
    let writtenFrames: Int
    let pendingFrames: Int

    var consumedFrames: Int { writtenFrames - pendingFrames }
}

final class PCMFloatRing: @unchecked Sendable {
    static let defaultCapacitySamples = Int(EngineAudioRenderer.engineSampleRate)
        * EngineAudioRenderer.engineChannels
        * Int(AudioRingReserve.ringCapacitySeconds)
    private let capacity: Int
    private let backing: UnsafeMutableBufferPointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let shortReadCount = Atomic<Int>(0)
    private let displayCustody = AudioRingDisplayCustody()

    init(capacity: Int = PCMFloatRing.defaultCapacitySamples) {
        let cap = max(capacity, 2)
        self.capacity = cap
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        buf.initialize(repeating: 0)
        backing = buf
    }
    deinit { backing.deallocate() }

    func reset() {
        displayCustody.retireAll()
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
        shortReadCount.store(0, ordering: .relaxed)
    }

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

    func recordShortRead() {
        _ = shortReadCount.wrappingAdd(1, ordering: .relaxed)
    }

    func takeShortReadCount() -> Int {
        shortReadCount.exchange(0, ordering: .acquiringAndReleasing)
    }

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
