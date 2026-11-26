import CoreMedia
import CoreVideo
import Foundation
import os

/// Dynamic, lead-matched, memory-pressure-aware output pool limits and steady presentation lookahead.
enum VideoEnhancementPoolLimits {
    struct Sizing: Equatable, Sendable {
        let lead: TimeInterval
        let superResolutionFrames: Int
        let interpolationPairsPerPhase: Int

        func interpolationFrames(phaseCount: Int) -> Int {
            max(1, phaseCount) * interpolationPairsPerPhase
        }
    }

    static let defaultLead: TimeInterval = 0.30
    static let forceLead: TimeInterval = 0.45

    private struct State: Equatable, Sendable {
        var roundedSourceFPS: Int = 30
        var roundedOutputFPS: Int = 60
        var maxPhasesPerPair: Int = 1
        var underMemoryPressure: Bool = false
        var forceFrameInterpolation: Bool = false
        var sizing: Sizing = VideoEnhancementPoolLimits.computeSizing(
            sourceFPS: 30,
            outputFPS: 60,
            maxPhasesPerPair: 1,
            underMemoryPressure: false,
            forceFrameInterpolation: false
        )
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func computeSizing(
        sourceFPS: Double,
        outputFPS: Double,
        maxPhasesPerPair: Int,
        underMemoryPressure: Bool,
        forceFrameInterpolation: Bool = false
    ) -> Sizing {
        let safeSourceFPS = (sourceFPS.isFinite && sourceFPS > 0) ? min(max(sourceFPS, 1), 240) : 30
        let safeOutputFPS = (outputFPS.isFinite && outputFPS > 0)
            ? min(max(outputFPS, safeSourceFPS), 240)
            : safeSourceFPS
        let safePhases = max(0, min(maxPhasesPerPair, VideoFrameInterpolationPlan.maximumPhasesPerPair))

        let effectivePressure = underMemoryPressure && !forceFrameInterpolation
        let lead: TimeInterval
        if effectivePressure {
            lead = 0.16
        } else if forceFrameInterpolation {
            lead = Self.forceLead
        } else if safeOutputFPS > 70 {
            lead = 0.26
        } else {
            lead = 0.30
        }

        let srFrames: Int
        let interpPairs: Int
        if effectivePressure {
            srFrames = min(26, max(8, Int(ceil((lead + 0.08) * safeOutputFPS)) + 2 * safePhases + 3))
            interpPairs = min(12, max(5, Int(ceil((lead + 0.08) * safeSourceFPS)) + 4))
        } else if forceFrameInterpolation {
            srFrames = min(76, max(16, Int(ceil((lead + 0.12) * safeOutputFPS)) + 2 * safePhases + 6))
            interpPairs = min(28, max(12, Int(ceil((lead + 0.12) * safeSourceFPS)) + 7))
        } else {
            srFrames = min(56, max(12, Int(ceil((lead + 0.10) * safeOutputFPS)) + 2 * safePhases + 4))
            interpPairs = min(20, max(8, Int(ceil((lead + 0.10) * safeSourceFPS)) + 5))
        }

        return Sizing(
            lead: lead,
            superResolutionFrames: srFrames,
            interpolationPairsPerPhase: interpPairs
        )
    }

    static func configure(
        sourceFPS: Double,
        outputFPS: Double,
        maxPhasesPerPair: Int,
        underMemoryPressure: Bool = VideoEnhancementGuardrails.isUnderMemoryPressure,
        forceFrameInterpolation: Bool = false
    ) {
        let safeSourceFPS = (sourceFPS.isFinite && sourceFPS > 0) ? min(max(sourceFPS, 1), 240) : 30
        let safeOutputFPS = (outputFPS.isFinite && outputFPS > 0)
            ? min(max(outputFPS, safeSourceFPS), 240)
            : safeSourceFPS
        let roundedSource = Int(safeSourceFPS.rounded())
        let roundedOutput = Int(safeOutputFPS.rounded())
        let safePhases = max(0, min(maxPhasesPerPair, VideoFrameInterpolationPlan.maximumPhasesPerPair))

        state.withLock { current in
            guard current.roundedSourceFPS != roundedSource
                || current.roundedOutputFPS != roundedOutput
                || current.maxPhasesPerPair != safePhases
                || current.underMemoryPressure != underMemoryPressure
                || current.forceFrameInterpolation != forceFrameInterpolation else {
                return
            }
            current.roundedSourceFPS = roundedSource
            current.roundedOutputFPS = roundedOutput
            current.maxPhasesPerPair = safePhases
            current.underMemoryPressure = underMemoryPressure
            current.forceFrameInterpolation = forceFrameInterpolation
            current.sizing = computeSizing(
                sourceFPS: Double(roundedSource),
                outputFPS: Double(roundedOutput),
                maxPhasesPerPair: safePhases,
                underMemoryPressure: underMemoryPressure,
                forceFrameInterpolation: forceFrameInterpolation
            )
        }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    private static func currentSizing() -> Sizing {
        let livePressure = VideoEnhancementGuardrails.isUnderMemoryPressure
        return state.withLock { current in
            if livePressure, !current.underMemoryPressure, !current.forceFrameInterpolation {
                return computeSizing(
                    sourceFPS: Double(current.roundedSourceFPS),
                    outputFPS: Double(current.roundedOutputFPS),
                    maxPhasesPerPair: current.maxPhasesPerPair,
                    underMemoryPressure: true,
                    forceFrameInterpolation: false
                )
            }
            return current.sizing
        }
    }

    static var currentLead: TimeInterval {
        currentSizing().lead
    }

    static var superResolutionFrames: Int {
        currentSizing().superResolutionFrames
    }

    static func interpolationFrames(phaseCount: Int) -> Int {
        currentSizing().interpolationFrames(phaseCount: phaseCount)
    }
}

struct PostProcessFrameBox: @unchecked Sendable {
    let frame: MediaVideoFrame
}

struct EnhancementFrameIdentity: Equatable, Sendable {
    private let buffer: ObjectIdentifier
    private let pts: TimeInterval
    private let duration: TimeInterval

    init(_ frame: MediaVideoFrame) {
        buffer = ObjectIdentifier(frame.pixelBuffer)
        pts = frame.pts
        duration = frame.duration
    }
}

struct VideoEnhancementDeadlines: Sendable {
    let original: ContinuousClock.Instant
    let midpoint: ContinuousClock.Instant?

    func workDeadline(upscaling: Bool) -> ContinuousClock.Instant {
        upscaling ? original : midpoint ?? original
    }
}

struct VideoEnhancementSuperResolutionPlan: Equatable, Sendable {
    let scaleCap: Float
    let targetDimensions: VideoSuperResolutionDimensions?
}

/// Single-pass admission snapshot for a `(previous, current)` frame pair, capturing guardrails,
/// super-resolution sizing, and frame-interpolation planning without redundant re-evaluation.
struct VideoEnhancementAdmission: Sendable {
    let configuration: VideoEnhancementConfiguration
    let superResolution: VideoEnhancementSuperResolutionPlan?
    let superResolutionBypassReason: String?
    let interpolationPlan: VideoFrameInterpolationPlan?
    let interpolationBypassReason: String?
    let activeOriginalDuration: TimeInterval?

    var canUpscale: Bool { superResolution != nil }
    var hasInterpolationPhases: Bool { interpolationPlan.map { !$0.phases.isEmpty } ?? false }
}

enum VideoEnhancementAdmissionOutcome: Sendable {
    case eligible(VideoEnhancementAdmission)
    case ineligible(bypassReason: String?, activeOriginalDuration: TimeInterval?)
}

struct VideoFrameEnhancementResult: Sendable {
    let midpoints: [PostProcessFrameBox]
    let enhancedOriginal: PostProcessFrameBox?
    let telemetry: VideoEnhancementTelemetry
    let interpolationBypassReason: String?
    let originalSuperResolutionBypassReason: String?
    let midpointsUpscaled: Bool
    let resolvedInterpolationBackend: VideoFrameInterpolationBackend?

    init(
        midpoints: [PostProcessFrameBox],
        enhancedOriginal: PostProcessFrameBox?,
        telemetry: VideoEnhancementTelemetry,
        interpolationBypassReason: String?,
        originalSuperResolutionBypassReason: String?,
        midpointsUpscaled: Bool = false,
        resolvedInterpolationBackend: VideoFrameInterpolationBackend? = nil
    ) {
        self.midpoints = midpoints
        self.enhancedOriginal = enhancedOriginal
        self.telemetry = telemetry
        self.interpolationBypassReason = interpolationBypassReason
        self.originalSuperResolutionBypassReason = originalSuperResolutionBypassReason
        self.midpointsUpscaled = midpointsUpscaled
        self.resolvedInterpolationBackend = resolvedInterpolationBackend
    }
}

enum VideoFrameEnhancementUpdate: Sendable {
    case midpointReady([PostProcessFrameBox])
    case finished(VideoFrameEnhancementResult)
}

/// Tracks actual inter-frame presentation cadence from decoded PTS deltas, insulating
/// interpolation decisions from misdeclared container durations (e.g. 30 fps content in a 60 fps
/// track) and single-tick timescale quantization jitter (e.g. 19/600s on a 30 fps stream).
///
/// Uses a fixed 16-element inline ring buffer and caches `medianInterval` / `isConstantRate`
/// on insertion so per-frame reads perform zero heap allocations and zero sorting.
struct VideoFrameCadenceEstimator: Sendable {
    private static let maxSamples = 16
    private static let minimumDelta: TimeInterval = 1.0 / 240.0
    private static let maximumDelta: TimeInterval = 0.25

    private typealias SampleRing = (
        TimeInterval, TimeInterval, TimeInterval, TimeInterval,
        TimeInterval, TimeInterval, TimeInterval, TimeInterval,
        TimeInterval, TimeInterval, TimeInterval, TimeInterval,
        TimeInterval, TimeInterval, TimeInterval, TimeInterval
    )

    private var lastObservedPTS: TimeInterval?
    private var ring: SampleRing = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private var writeIndex = 0
    private(set) var sampleCount = 0
    private(set) var medianInterval: TimeInterval?
    /// True when observed deltas behave like constant-frame-rate content (interquartile spread
    /// within 8% of the median). Returns `true` before 4 deltas are collected so standard CFR
    /// streams can immediately enter the fast dyadic path when their declared duration matches.
    private(set) var isConstantRate = true

    mutating func reset() {
        lastObservedPTS = nil
        clearSamples()
    }

    mutating func observe(pts: TimeInterval) {
        guard pts.isFinite else { return }
        if lastObservedPTS == pts { return }
        defer { lastObservedPTS = pts }
        guard let previous = lastObservedPTS else { return }
        let delta = pts - previous
        guard delta.isFinite, delta >= Self.minimumDelta, delta <= Self.maximumDelta else {
            if delta < 0 || delta > 0.5 {
                clearSamples()
            }
            return
        }
        let slot = writeIndex
        withUnsafeMutableBytes(of: &ring) { raw in
            let buffer = raw.bindMemory(to: TimeInterval.self)
            buffer[slot] = delta
        }
        writeIndex = (slot + 1) & 15
        if sampleCount < Self.maxSamples {
            sampleCount += 1
        }
        recomputeStats()
    }

    func estimatedInterval(fallbackDuration: TimeInterval) -> TimeInterval? {
        if let median = medianInterval {
            return median
        }
        guard fallbackDuration.isFinite, fallbackDuration > 0 else { return nil }
        return fallbackDuration
    }

    private mutating func clearSamples() {
        writeIndex = 0
        sampleCount = 0
        medianInterval = nil
        isConstantRate = true
    }

    private mutating func recomputeStats() {
        let count = sampleCount
        guard count > 0 else {
            medianInterval = nil
            isConstantRate = true
            return
        }
        var sorted = ring
        let stats: (median: TimeInterval, constant: Bool) = withUnsafeMutableBytes(of: &sorted) { raw in
            let values = raw.bindMemory(to: TimeInterval.self)
            for i in 1..<count {
                let key = values[i]
                var j = i - 1
                while j >= 0 && values[j] > key {
                    values[j + 1] = values[j]
                    j -= 1
                }
                values[j + 1] = key
            }
            let mid = count / 2
            let median = count.isMultiple(of: 2)
                ? (values[mid - 1] + values[mid]) * 0.5
                : values[mid]
            let constant: Bool
            if count >= 4, median > 0 {
                let q1 = values[count / 4]
                let q3 = values[(count * 3) / 4]
                constant = (q3 - q1) / median <= 0.08
            } else {
                constant = true
            }
            return (median, constant)
        }
        medianInterval = stats.median
        isConstantRate = stats.constant
    }
}

struct VideoFrameInterpolationTiming {
    static let tolerance: TimeInterval = 1e-9
    static let maximumDelta: TimeInterval = 0.25
    let delta: TimeInterval

    init?(
        previousPTS: TimeInterval,
        previousDuration: TimeInterval,
        current: MediaVideoFrame,
        expectedInterval: TimeInterval? = nil
    ) {
        guard current.pts.isFinite, previousPTS.isFinite else { return nil }
        let validPrevDuration = (previousDuration.isFinite && previousDuration > 0) ? previousDuration : nil
        let validCurrentDuration = (current.duration.isFinite && current.duration > 0) ? current.duration : nil
        let validExpected = expectedInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let referenceInterval = [validPrevDuration, validExpected, validCurrentDuration]
            .compactMap({ $0 })
            .max() else {
            return nil
        }
        let delta = current.pts - previousPTS
        let midpointPTS = previousPTS + delta * 0.5
        // Permit normal VFR swings and misdeclared container durations (e.g. 30 fps frames inside
        // a 60 fps timebase or 0-duration packets) while still rejecting genuine multi-frame gaps.
        let allowedDelta = min(Self.maximumDelta, max(referenceInterval * 1.75, 0.055))
        guard delta.isFinite, delta > 0, delta <= allowedDelta + Self.tolerance,
              midpointPTS > previousPTS, midpointPTS < current.pts else { return nil }
        self.delta = delta
    }

    static func sourceFPS(_ frame: MediaVideoFrame) -> Double? {
        guard frame.pts.isFinite, frame.duration.isFinite, frame.duration > 0 else { return nil }
        let fps = 1 / frame.duration
        return fps.isFinite ? fps : nil
    }
}

enum VideoInterpolationPlanOutcome: Sendable {
    case plan(VideoFrameInterpolationPlan)
    case bypass(String)
}

struct VideoFrameInterpolationPlan: Sendable {
    static let maximumMultiplier = 5
    static let maximumPhasesPerPair = 6
    /// Multipliers supported by arbitrary-phase backends (`VTFrameRateConversionConfiguration` on
    /// iOS 26+ and `VisionFrameInterpolationBackend`'s optical-flow Metal shader on iOS 18–25).
    static let fullMultipliers = [5, 4, 3, 2]
    /// Dyadic-only multipliers supported by `VTLowLatencyFrameInterpolationConfiguration`
    /// (`numberOfInterpolatedFrames = 1` → 2× `[0.5]`, `2` → 4× `[0.25, 0.5, 0.75]`).
    static let dyadicMultipliers = [4, 2]
    /// Relative tolerance for treating a stream as already at or above the requested target FPS
    /// (e.g. 59.4–60.0 fps for a 60 fps target).
    static let targetReachedTolerance: Double = 1.015
    /// Relative tolerance for taking the exact integer fast path (2×/3×/4×/5×), keeping all
    /// original frames and using low-latency LLFI for 2×/4× (e.g. 29.97/30→60, 23.976/24→48/96).
    static let exactIntegerTolerance: Double = 0.012
    /// Widened relative headroom for dyadic LLFI multipliers so slightly-above-nominal 30.x fps
    /// and VFR streams (up to ~33 fps for 60 fps 2× / 120 fps 4×, and ~66 fps for 120 fps 2×)
    /// stay cleanly on hardware-fast LLFI instead of bypassing or ping-ponging multipliers.
    static let dyadicHeadroom: Double = 1.10

    let phases: [Float]
    let pts: [TimeInterval]
    let sourceInterval: TimeInterval
    /// True only for exact uniform dyadic plans (`[0.5]` / `[0.25, 0.5, 0.75]`), eligible for LLFI.
    let allowsLowLatency: Bool
    /// Whether the renderer should also present `current` after the synthesized frames.
    let emitsOriginal: Bool
    /// Presentation duration for each synthesized frame.
    let outputFrameDuration: TimeInterval
    /// Next CFR grid timestamp to commit once this frame pair is admitted; `nil` in integer mode.
    let nextGridPTS: TimeInterval?
    /// Nominal output frame rate produced by this plan.
    let targetOutputFPS: Double

    /// Whether the active interpolation backend supports arbitrary phases in `(0, 1)`.
    /// On iOS 26+, the default Auto/LLFI path uses hardware-fast dyadic Apple LLFI (2× / 4×);
    /// Vision optical flow accepts arbitrary phases on both iOS 18–25 and iOS 26+ when selected.
    static var supportsArbitraryPhases: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26.0, *) {
            return false
        }
        return true
        #endif
    }

    /// Backend-aware arbitrary-phase capability: `.videoToolbox` is strictly dyadic LLFI (2× / 4×),
    /// whereas `.visionOpticalFlow` supports arbitrary phases (2×–5× and CFR resampling) on iOS 18+
    /// including iOS 26+.
    static func supportsArbitraryPhases(
        for backend: VideoFrameInterpolationBackend,
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> Bool {
        backend.supportsArbitraryPhases(vtSupported: vtSupported)
    }

    static var defaultMultipliers: [Int] {
        supportsArbitraryPhases ? fullMultipliers : dyadicMultipliers
    }

    static func normalizedPlaybackRate(_ playbackRate: Double) -> Double {
        (playbackRate.isFinite && playbackRate > 0) ? playbackRate : 1.0
    }

    /// Checks whether a stream with the given source cadence is eligible for interpolation under
    /// `rate` at the given `playbackRate`, returning a diagnostic bypass reason only when genuinely
    /// ineligible.
    static func streamEligibilityBypassReason(
        sourceInterval: TimeInterval,
        rate: VideoInterpolationRate,
        playbackRate: Double = 1.0,
        supportsArbitraryPhases: Bool = Self.supportsArbitraryPhases
    ) -> String? {
        guard sourceInterval.isFinite, sourceInterval > 0 else { return "Frame timing invalid" }
        guard let targetFPS = rate.targetFPS else { return nil }
        let speed = normalizedPlaybackRate(playbackRate)
        let wallCadence = sourceInterval / speed
        let targetPeriod = 1.0 / Double(targetFPS)
        if wallCadence <= targetPeriod * targetReachedTolerance {
            return "Target frame rate reached"
        }
        if !supportsArbitraryPhases,
           bestMultiplier(forInterval: wallCadence, rate: rate, allowedMultipliers: dyadicMultipliers) == nil {
            return "Interpolation ratio unsupported"
        }
        return nil
    }

    static func bestMultiplier(
        forInterval interval: TimeInterval,
        rate: VideoInterpolationRate,
        allowedMultipliers: [Int] = Self.defaultMultipliers
    ) -> Int? {
        guard interval.isFinite, interval > 0 else { return nil }
        guard let targetFPS = rate.targetFPS else { return 2 }
        let cap = Double(targetFPS)
        let effectiveInterval = interval * dyadicHeadroom + VideoFrameInterpolationTiming.tolerance
        return allowedMultipliers
            .filter { $0 >= 2 && $0 <= maximumMultiplier }
            .sorted(by: >)
            .first { effectiveInterval >= Double($0) / cap }
    }

    static func plan(
        previousPTS: TimeInterval,
        currentPTS: TimeInterval,
        interval: TimeInterval,
        cadenceInterval: TimeInterval? = nil,
        isCadenceStable: Bool = true,
        gridNextPTS: TimeInterval? = nil,
        rate: VideoInterpolationRate,
        playbackRate: Double = 1.0,
        supportsArbitraryPhases: Bool = Self.supportsArbitraryPhases
    ) -> VideoInterpolationPlanOutcome {
        guard interval.isFinite, interval > 0, previousPTS.isFinite, currentPTS.isFinite,
              currentPTS > previousPTS else {
            return .bypass("Frame timing gap")
        }
        let speed = normalizedPlaybackRate(playbackRate)
        guard let targetFPS = rate.targetFPS else {
            return makeIntegerPlan(
                previousPTS: previousPTS,
                currentPTS: currentPTS,
                interval: interval,
                cadenceInterval: cadenceInterval,
                playbackRate: speed,
                multiplier: 2
            )
        }
        let cap = Double(targetFPS)
        let targetPeriod = 1.0 / cap
        let effectiveCadence = (cadenceInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }) ?? interval
        let wallCadence = effectiveCadence / speed
        if wallCadence <= targetPeriod * targetReachedTolerance {
            return .bypass("Target frame rate reached")
        }

        let allowedMultipliers = supportsArbitraryPhases ? fullMultipliers : dyadicMultipliers
        let ratio = cap * wallCadence
        if gridNextPTS == nil, isCadenceStable,
           let exactMultiplier = allowedMultipliers.first(where: { multiplier in
               let target = Double(multiplier)
               return abs(ratio - target) / target <= exactIntegerTolerance
           }) {
            return makeIntegerPlan(
                previousPTS: previousPTS,
                currentPTS: currentPTS,
                interval: interval,
                cadenceInterval: effectiveCadence,
                playbackRate: speed,
                multiplier: exactMultiplier
            )
        }

        guard supportsArbitraryPhases else {
            if let multiplier = bestMultiplier(
                forInterval: wallCadence, rate: rate, allowedMultipliers: dyadicMultipliers
            ) {
                return makeIntegerPlan(
                    previousPTS: previousPTS,
                    currentPTS: currentPTS,
                    interval: interval,
                    cadenceInterval: effectiveCadence,
                    playbackRate: speed,
                    multiplier: multiplier
                )
            }
            return .bypass("Interpolation ratio unsupported")
        }

        // Convert wall-clock target period into media time so display cadence hits `cap` fps at any playback speed.
        let mediaTargetPeriod = targetPeriod * speed
        return makeCFRGridPlan(
            previousPTS: previousPTS,
            currentPTS: currentPTS,
            interval: interval,
            targetPeriod: mediaTargetPeriod,
            targetFPS: cap,
            gridNextPTS: gridNextPTS
        )
    }

    private static func makeIntegerPlan(
        previousPTS: TimeInterval,
        currentPTS: TimeInterval,
        interval: TimeInterval,
        cadenceInterval: TimeInterval? = nil,
        playbackRate: Double = 1.0,
        multiplier: Int
    ) -> VideoInterpolationPlanOutcome {
        let phases = (1..<multiplier).map { Float($0) / Float(multiplier) }
        let pts = phases.map { previousPTS + interval * Double($0) }
        var lastPTS = previousPTS
        for point in pts {
            guard point > lastPTS, point < currentPTS else { return .bypass("Frame timing gap") }
            lastPTS = point
        }
        let fpsInterval = (cadenceInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }) ?? interval
        let speed = normalizedPlaybackRate(playbackRate)
        return .plan(VideoFrameInterpolationPlan(
            phases: phases,
            pts: pts,
            sourceInterval: interval,
            allowsLowLatency: multiplier == 2 || multiplier == 4,
            emitsOriginal: true,
            outputFrameDuration: interval / Double(multiplier),
            nextGridPTS: nil,
            targetOutputFPS: (Double(multiplier) / fpsInterval) * speed
        ))
    }

    private static func makeCFRGridPlan(
        previousPTS: TimeInterval,
        currentPTS: TimeInterval,
        interval: TimeInterval,
        targetPeriod: TimeInterval,
        targetFPS: Double,
        gridNextPTS: TimeInterval?
    ) -> VideoInterpolationPlanOutcome {
        // Keep snapEpsilon dependent solely on targetPeriod so consecutive VFR pairs share the
        // exact same snap threshold at their shared boundary without ever dropping a grid tick.
        let snapEpsilon = max(0.001, targetPeriod * 0.12)
        var tick: TimeInterval
        if let anchor = gridNextPTS,
           anchor.isFinite,
           anchor > previousPTS - snapEpsilon,
           anchor <= currentPTS + targetPeriod + snapEpsilon {
            tick = anchor
        } else {
            tick = previousPTS + targetPeriod
        }
        while tick <= previousPTS + snapEpsilon {
            tick += targetPeriod
        }

        var phases: [Float] = []
        var pts: [TimeInterval] = []
        var emitsOriginal = false
        var lastPTS = previousPTS

        while tick <= currentPTS + snapEpsilon {
            if tick >= currentPTS - snapEpsilon {
                emitsOriginal = true
                tick += targetPeriod
                break
            }
            let phase = Float((tick - previousPTS) / interval)
            if phase > 0.001, phase < 0.999, tick > lastPTS, tick < currentPTS {
                phases.append(phase)
                pts.append(tick)
                lastPTS = tick
            }
            tick += targetPeriod
            if phases.count >= maximumPhasesPerPair {
                emitsOriginal = true
                tick = currentPTS + targetPeriod
                break
            }
        }

        return .plan(VideoFrameInterpolationPlan(
            phases: phases,
            pts: pts,
            sourceInterval: interval,
            allowsLowLatency: false,
            emitsOriginal: emitsOriginal,
            outputFrameDuration: targetPeriod,
            nextGridPTS: tick,
            targetOutputFPS: targetFPS
        ))
    }

    init?(
        previousPTS: TimeInterval,
        currentPTS: TimeInterval,
        interval: TimeInterval,
        rate: VideoInterpolationRate,
        supportsArbitraryPhases: Bool = Self.supportsArbitraryPhases
    ) {
        switch Self.plan(
            previousPTS: previousPTS,
            currentPTS: currentPTS,
            interval: interval,
            rate: rate,
            supportsArbitraryPhases: supportsArbitraryPhases
        ) {
        case let .plan(resolved):
            self = resolved
        case .bypass:
            return nil
        }
    }

    private init(
        phases: [Float],
        pts: [TimeInterval],
        sourceInterval: TimeInterval,
        allowsLowLatency: Bool,
        emitsOriginal: Bool,
        outputFrameDuration: TimeInterval,
        nextGridPTS: TimeInterval?,
        targetOutputFPS: Double
    ) {
        self.phases = phases
        self.pts = pts
        self.sourceInterval = sourceInterval
        self.allowsLowLatency = allowsLowLatency
        self.emitsOriginal = emitsOriginal
        self.outputFrameDuration = outputFrameDuration
        self.nextGridPTS = nextGridPTS
        self.targetOutputFPS = targetOutputFPS
    }

    var sourceFPS: Double { 1 / sourceInterval }
    var isCFRResampling: Bool { nextGridPTS != nil }

    func makeFrames(buffers: [CVPixelBuffer]) -> [MediaVideoFrame] {
        precondition(buffers.count == pts.count)
        return zip(pts, buffers).map { MediaVideoFrame(pts: $0, duration: outputFrameDuration, pixelBuffer: $1) }
    }

    static func outputPoolLimit(phaseCount: Int) -> Int {
        VideoEnhancementPoolLimits.interpolationFrames(phaseCount: phaseCount)
    }

    /// Synthesizes a representative interpolation plan for non-blocking session prewarm using
    /// the initial reference frame's cadence and timestamp. When `frame.pts >= interval`, places
    /// the synthetic pair at `(pts - interval, pts)` so low-latency VideoToolbox sessions stay
    /// strictly monotonic and reusable for the very first real `(Frame 0, Frame 1)` pair.
    static func prewarmPlan(
        for frame: MediaVideoFrame,
        cadenceInterval: TimeInterval? = nil,
        rate: VideoInterpolationRate,
        playbackRate: Double = 1.0,
        supportsArbitraryPhases: Bool = Self.supportsArbitraryPhases
    ) -> (previousPTS: TimeInterval, currentPTS: TimeInterval, plan: VideoFrameInterpolationPlan)? {
        let rawInterval = (cadenceInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
            ?? (frame.duration.isFinite && frame.duration > 0 ? frame.duration : nil)
        guard let interval = rawInterval,
              interval >= 1.0 / 240.0,
              interval <= VideoFrameInterpolationTiming.maximumDelta,
              frame.pts.isFinite else {
            return nil
        }
        let safePTS = max(0, frame.pts)
        let previousPTS: TimeInterval
        let currentPTS: TimeInterval
        if safePTS >= interval {
            previousPTS = safePTS - interval
            currentPTS = safePTS
        } else {
            previousPTS = safePTS
            currentPTS = safePTS + interval
        }
        switch Self.plan(
            previousPTS: previousPTS,
            currentPTS: currentPTS,
            interval: interval,
            cadenceInterval: interval,
            isCadenceStable: true,
            gridNextPTS: nil,
            rate: rate,
            playbackRate: playbackRate,
            supportsArbitraryPhases: supportsArbitraryPhases
        ) {
        case let .plan(resolved) where !resolved.phases.isEmpty:
            return (previousPTS, currentPTS, resolved)
        default:
            return nil
        }
    }
}
