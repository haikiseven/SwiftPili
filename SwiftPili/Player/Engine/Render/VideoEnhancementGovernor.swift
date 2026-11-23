import Foundation

/// Degradation ladder applied on top of the user's requested enhancement configuration.
/// Each level is cumulative and ordered from cheapest-to-lose to most visible.
enum VideoEnhancementDegradationLevel: Int, Comparable, CaseIterable, Sendable {
    /// User configuration as requested.
    case none = 0
    /// Interpolation capped at 60 fps (at most one midpoint for 30 fps sources).
    case reducedInterpolation
    /// Super resolution capped at 2×.
    case reducedScale
    /// VideoToolbox ML super resolution swapped for the much cheaper MetalFX spatial scaler.
    case lightweightUpscaler
    /// Frame interpolation disabled; super resolution (if any) keeps running.
    case interpolationSuspended
    /// All enhancement suspended until the device recovers.
    case suspended

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }

    func apply(
        to requested: VideoEnhancementConfiguration,
        metalFXAvailable: Bool = VideoEnhancementGovernor.metalFXAvailable
    ) -> VideoEnhancementConfiguration {
        var config = requested
        if self >= .reducedInterpolation, config.interpolationRate == .fps90 || config.interpolationRate == .fps120 {
            config.interpolationRate = .fps60
        }
        if self >= .reducedScale {
            config.superResolutionScale = .two
        }
        if self >= .lightweightUpscaler, config.superResolutionMode == .videoToolboxML, metalFXAvailable {
            config.superResolutionMode = .metalFXSpatial
        }
        if self >= .interpolationSuspended {
            config.frameInterpolationEnabled = false
        }
        if self >= .suspended {
            config.superResolutionMode = .off
            config.frameInterpolationEnabled = false
        }
        return config
    }
}

struct VideoEnhancementSystemState: Equatable, Sendable {
    var thermalState: ProcessInfo.ThermalState
    var isLowPowerModeEnabled: Bool

    static var current: Self {
        let info = ProcessInfo.processInfo
        return Self(thermalState: info.thermalState, isLowPowerModeEnabled: info.isLowPowerModeEnabled)
    }

    /// Minimum degradation imposed by system conditions regardless of measured performance.
    /// `.serious` / `.critical` thermal is already a hard bypass in `VideoEnhancementGuardrails`.
    var floor: VideoEnhancementDegradationLevel {
        var level = VideoEnhancementDegradationLevel.none
        if thermalState == .fair { level = max(level, .reducedScale) }
        if isLowPowerModeEnabled { level = max(level, .interpolationSuspended) }
        if thermalState == .serious || thermalState == .critical { level = .suspended }
        return level
    }
}

/// Adaptive performance governor for super resolution / frame interpolation.
///
/// The renderer enforces per-frame deadlines, so an overloaded device "only" drops enhancement on
/// individual frames. Left alone that produces the worst of both worlds: SR flickers between
/// sharp and soft frames, interpolation cadence alternates between 60 and 30 fps (more judder than
/// no interpolation), and the device keeps burning GPU/ANE on work that is thrown away until it
/// eventually hits thermal throttling.
///
/// The governor watches the miss rate and worker load over short windows and steps down the
/// `VideoEnhancementDegradationLevel` ladder to a level the device can sustain, then cautiously
/// probes back up with exponential back-off so it does not oscillate.
struct VideoEnhancementGovernor: Sendable {
    struct Tuning: Sendable {
        var windowDuration: Duration = .seconds(2)
        var minimumSamples = 12
        /// Miss ratio that steps down immediately after a single window.
        var severeMissRatio = 0.4
        /// Miss ratio that steps down after two consecutive windows.
        var missRatio = 0.15
        /// Worker load (processing time / source frame interval) that steps down after two windows.
        var overloadRatio = 1.0
        /// Recovery requires windows at or below these values.
        var recoveryMissRatio = 0.03
        var recoveryLoadRatio = 0.6
        var baseCooldown: Duration = .seconds(8)
        var maxCooldown: Duration = .seconds(120)
        /// A step down within this period after a step up counts as a failed probe.
        var probeFailureWindow: Duration = .seconds(10)
        /// Samples are ignored for this long after a seek / configuration change / flush storm.
        var discontinuityGrace: Duration = .milliseconds(1500)

        static func preset(_ sensitivity: VideoEnhancementAdaptiveSensitivity) -> Self {
            var tuning = Self()
            switch sensitivity {
            case .sensitive:
                tuning.missRatio = 0.08
                tuning.severeMissRatio = 0.25
                tuning.overloadRatio = 0.9
                tuning.baseCooldown = .seconds(15)
            case .standard:
                break
            case .relaxed:
                tuning.missRatio = 0.25
                tuning.severeMissRatio = 0.6
                tuning.overloadRatio = 1.2
                tuning.baseCooldown = .seconds(6)
            }
            return tuning
        }
    }

    private struct Window {
        var start: ContinuousClock.Instant
        var attempts = 0
        var misses = 0
        var loadSum = 0.0
        var loadSamples = 0

        var missRatio: Double { attempts > 0 ? Double(misses) / Double(attempts) : 0 }
        var meanLoad: Double { loadSamples > 0 ? loadSum / Double(loadSamples) : 0 }
    }

    static let metalFXAvailable = VideoEnhancementCapabilities.current.metalFXSpatial.isSupported

    let tuning: Tuning
    let requested: VideoEnhancementConfiguration
    private let metalFXAvailable: Bool
    private(set) var adaptiveLevel = VideoEnhancementDegradationLevel.none
    private(set) var systemFloor = VideoEnhancementDegradationLevel.none
    /// Minimum level imposed because the configured output rate cannot fit the buffer memory budget
    /// (e.g. 4 output frames per source frame at screen resolution). Deterministic, so it is not
    /// probed away; cleared when the input raster / display surface / configuration changes.
    private(set) var structuralFloor = VideoEnhancementDegradationLevel.none
    private var window: Window
    private var consecutiveBadWindows = 0
    private var lastChange: ContinuousClock.Instant
    private var lastStepUp: ContinuousClock.Instant?
    private var failedProbes = 0
    private var graceUntil: ContinuousClock.Instant?

    init(
        requested: VideoEnhancementConfiguration = .disabled,
        tuning: Tuning? = nil,
        metalFXAvailable: Bool = Self.metalFXAvailable,
        now: ContinuousClock.Instant = .now
    ) {
        self.requested = requested
        self.tuning = tuning ?? .preset(requested.adaptiveSensitivity)
        self.metalFXAvailable = metalFXAvailable
        window = Window(start: now)
        lastChange = now
    }

    var level: VideoEnhancementDegradationLevel { max(adaptiveLevel, systemFloor, structuralFloor) }

    /// Short reason for the current degradation, used in telemetry / UI.
    var reason: String? {
        guard level > .none, effectiveConfiguration != requested else { return nil }
        if structuralFloor > .none, structuralFloor >= max(adaptiveLevel, systemFloor) {
            return "Memory limited"
        }
        if systemFloor >= adaptiveLevel {
            return systemFloor == .suspended ? "Thermal throttling"
                : (systemFloor >= .interpolationSuspended ? "Low Power Mode" : "Thermal fair")
        }
        return "Performance limited"
    }

    var effectiveConfiguration: VideoEnhancementConfiguration { configuration(at: level) }

    private func configuration(at level: VideoEnhancementDegradationLevel) -> VideoEnhancementConfiguration {
        level.apply(to: requested, metalFXAvailable: metalFXAvailable)
    }

    /// Full reset: the user changed the configuration explicitly, so give it a fresh chance.
    mutating func reset(requested: VideoEnhancementConfiguration, now: ContinuousClock.Instant = .now) {
        self = Self(requested: requested, metalFXAvailable: metalFXAvailable, now: now)
    }

    /// Steps the structural floor one effective rung below the current level. Never suspends
    /// super resolution entirely: SR alone degrades gracefully with a shallower lookahead.
    @discardableResult
    mutating func raiseStructuralFloor(now: ContinuousClock.Instant = .now) -> Bool {
        guard requested.adaptiveQualityEnabled else { return false }
        let current = configuration(at: level)
        var candidate = level.next
        while let rung = candidate, rung < .suspended, configuration(at: rung) == current {
            candidate = rung.next
        }
        guard let next = candidate, next <= .interpolationSuspended else { return false }
        structuralFloor = next
        lastChange = now
        return true
    }

    mutating func resetStructuralFloor() {
        structuralFloor = .none
    }

    /// Seek, stream switch, etc. Keep the learned level but ignore the transient late frames.
    mutating func noteDiscontinuity(now: ContinuousClock.Instant = .now) {
        graceUntil = now.advanced(by: tuning.discontinuityGrace)
        window = Window(start: now)
        consecutiveBadWindows = 0
    }

    mutating func record(missed: Bool, now: ContinuousClock.Instant = .now) {
        guard !isInGrace(now) else { return }
        window.attempts += 1
        if missed { window.misses += 1 }
    }

    mutating func recordLoad(processingMs: Double, frameInterval: TimeInterval, now: ContinuousClock.Instant = .now) {
        guard !isInGrace(now), processingMs.isFinite, processingMs > 0,
              frameInterval.isFinite, frameInterval > 0 else { return }
        window.loadSum += processingMs / (frameInterval * 1000)
        window.loadSamples += 1
    }

    /// Re-evaluates the level. Returns `true` when the effective level changed.
    @discardableResult
    mutating func evaluate(
        system: VideoEnhancementSystemState = .current,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        let before = level
        guard requested.adaptiveQualityEnabled else {
            // User opted out: only the hard thermal safety stop applies.
            adaptiveLevel = .none
            systemFloor = system.floor == .suspended ? .suspended : .none
            return level != before
        }
        systemFloor = system.floor
        if window.start.duration(to: now) >= tuning.windowDuration {
            closeWindow(now: now)
        }
        return level != before
    }

    private func isInGrace(_ now: ContinuousClock.Instant) -> Bool {
        if let graceUntil, now < graceUntil { return true }
        return false
    }

    private mutating func closeWindow(now: ContinuousClock.Instant) {
        let closed = window
        window = Window(start: now)
        guard !isInGrace(now) else { return }

        let hasSamples = closed.attempts >= tuning.minimumSamples
        let overloaded = closed.loadSamples >= tuning.minimumSamples && closed.meanLoad > tuning.overloadRatio
        if hasSamples, closed.missRatio >= tuning.severeMissRatio {
            stepDown(now: now)
            return
        }
        if (hasSamples && closed.missRatio >= tuning.missRatio) || overloaded {
            consecutiveBadWindows += 1
            if consecutiveBadWindows >= 2 { stepDown(now: now) }
            return
        }
        consecutiveBadWindows = 0

        if let lastStepUp, lastStepUp.duration(to: now) >= tuning.probeFailureWindow {
            failedProbes = 0
            self.lastStepUp = nil
        }
        // While suspended there is no work to measure, so recovery is purely time based.
        let clean = closed.missRatio <= tuning.recoveryMissRatio
            && (closed.loadSamples == 0 || closed.meanLoad <= tuning.recoveryLoadRatio)
        if adaptiveLevel > .none, clean, lastChange.duration(to: now) >= cooldown {
            stepUp(now: now)
        }
    }

    private var cooldown: Duration {
        let factor = 1 << min(failedProbes, 4)
        return min(tuning.baseCooldown * factor, tuning.maxCooldown)
    }

    private mutating func stepDown(now: ContinuousClock.Instant) {
        consecutiveBadWindows = 0
        // Degradations already imposed by the system/structural floor are not the bottleneck; go below them.
        let base = level
        let current = configuration(at: base)
        var candidate = base.next
        // Skip rungs that do not change anything for this configuration (e.g. SR scale when only FI is on).
        while let level = candidate, level != .suspended, configuration(at: level) == current {
            candidate = level.next
        }
        guard let next = candidate else { return }
        if let lastStepUp, lastStepUp.duration(to: now) < tuning.probeFailureWindow {
            failedProbes += 1
        }
        lastStepUp = nil
        adaptiveLevel = next
        lastChange = now
    }

    private mutating func stepUp(now: ContinuousClock.Instant) {
        let current = configuration(at: adaptiveLevel)
        var candidate = adaptiveLevel.previous
        while let level = candidate, level != .none, configuration(at: level) == current {
            candidate = level.previous
        }
        guard var previous = candidate else { return }
        // Land on the lowest rung producing that configuration so the level reflects reality.
        let target = configuration(at: previous)
        while let lower = previous.previous, configuration(at: lower) == target { previous = lower }
        adaptiveLevel = previous
        lastChange = now
        lastStepUp = now
    }
}
