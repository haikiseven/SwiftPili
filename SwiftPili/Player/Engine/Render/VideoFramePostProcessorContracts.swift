import CoreMedia
import CoreVideo
import Foundation
#if !targetEnvironment(simulator)
import VideoToolbox
#endif

/// Fixed, memory-pressure-aware output pool limits and steady presentation lookahead.
enum VideoEnhancementPoolLimits {
    static let defaultLead: TimeInterval = 0.35

    static var superResolutionFrames: Int {
        VideoEnhancementGuardrails.isUnderMemoryPressure ? 6 : 12
    }

    static func interpolationFrames(phaseCount: Int) -> Int {
        max(1, phaseCount) * (VideoEnhancementGuardrails.isUnderMemoryPressure ? 3 : 5)
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

    init(
        midpoints: [PostProcessFrameBox],
        enhancedOriginal: PostProcessFrameBox?,
        telemetry: VideoEnhancementTelemetry,
        interpolationBypassReason: String?,
        originalSuperResolutionBypassReason: String?,
        midpointsUpscaled: Bool = false
    ) {
        self.midpoints = midpoints
        self.enhancedOriginal = enhancedOriginal
        self.telemetry = telemetry
        self.interpolationBypassReason = interpolationBypassReason
        self.originalSuperResolutionBypassReason = originalSuperResolutionBypassReason
        self.midpointsUpscaled = midpointsUpscaled
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
        guard Self.sourceFPS(current) != nil, previousPTS.isFinite,
              previousDuration.isFinite, previousDuration > 0 else { return nil }
        let delta = current.pts - previousPTS
        let midpointPTS = previousPTS + delta * 0.5
        let referenceInterval = max(previousDuration, expectedInterval ?? previousDuration)
        // Permit normal VFR swings and misdeclared container durations (e.g. 30 fps frames inside
        // a 60 fps timebase) while still rejecting genuine multi-frame gaps / discontinuities.
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
    /// Small relative interval tolerance covering 1 ms container PTS quantization (used by dyadic fallback).
    static let jitterFactor: Double = 1.0165

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

    /// Whether the active interpolation backend supports arbitrary phases in `(0, 1)` (used for
    /// 3×/5× integer multiples as well as non-integer CFR resampling such as 24/30.6/40/50→60 fps).
    static var supportsArbitraryPhases: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        if #available(iOS 26.0, *) {
            // VTFrameRateConversionConfiguration accepts arbitrary phases in (0, 1);
            // VTLowLatencyFrameInterpolationConfiguration only produces 2^x - 1 dyadic phases.
            // Restrict to dyadic multipliers only when a device supports LLFI without FRC.
            return VTFrameRateConversionConfiguration.isSupported
                || !VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return true
        #endif
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
        let effectiveInterval = interval * jitterFactor + VideoFrameInterpolationTiming.tolerance
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
}
