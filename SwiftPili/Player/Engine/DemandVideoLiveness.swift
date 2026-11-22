import Foundation

/// The only Demand modes covered by the silent-video detector in this slice.
///
/// `offline` is finite media like `vod` — the mode exists so a downloaded asset
/// fences detector state under its own identity, not so EOF or suppression
/// behaves differently. The single behavioural read of this value is the
/// `== .live` open-ended-EOF test in `MediaEngineSession`, which offline must
/// not satisfy.
enum DemandLivenessMode: String, Sendable, Equatable, Hashable {
    case vod
    case live
    case offline
}

enum DemandLivenessAppState: String, Sendable, Equatable, Hashable {
    case active
    case inactive
    case background
}

enum DemandLivenessIntent: String, Sendable, Equatable, Hashable {
    case playing
    case userPaused
    case systemPaused
}

enum DemandLivenessSeekPhase: String, Sendable, Equatable, Hashable {
    case settled
    case seeking
    case preroll
}

enum DemandLivenessLifecycle: String, Sendable, Equatable, Hashable {
    case settled
    case foregroundSettling
    case backgroundNoPiP
    case backgroundObservedPiP
}

enum DemandLivenessRenderer: String, Sendable, Equatable, Hashable {
    case ready
    case backPressure
    case failed
    case needsFlush

    var isHealthy: Bool { self == .ready }
}

enum DemandLivenessEOF: String, Sendable, Equatable, Hashable {
    case notEOF
    case finiteEOFDrained
    case liveOpenEnded
}

enum DemandLivenessSuppression: String, Sendable, Equatable, Hashable {
    case noVideoTrack
    case notReady
    case buffering
    case paused
    case startup
    case seeking
    case lifecycleSettling
    case backgroundWithoutObservedPiP
    case outputProgress
    case rendererBlocked
    case finiteEOF
    case terminal
    case generationChanged
    case invalidWindow
    case alreadyEmitted
}

enum DemandLivenessDiagnostic: String, Sendable, Equatable, Hashable {
    case inputStarvation
    case rendererOnlyLoss
    case lowFrameRate
    case callbackWithoutOutput
    case outputProgress
}

/// Source identity is deliberately value-only. It is used to fence detector
/// state and is never copied into fault diagnostics or logs.
enum DemandLivenessSourceIdentity: Sendable, Equatable, Hashable {
    case vod(aid: Int, cid: Int, quality: Int, source: String)
    case live(roomID: Int, quality: Int)
    /// A downloaded asset. Carries the same value triple as `vod` rather than the
    /// stored `OfflinePlaybackAsset`, which is `Equatable` only — this enum must
    /// stay `Hashable` because the detector fences on it.
    case offline(aid: Int, cid: Int, quality: Int)

    var mode: DemandLivenessMode {
        switch self {
        case .vod: .vod
        case .live: .live
        case .offline: .offline
        }
    }
}

/// ViewModel-owned gates that the session cannot infer from media queues.
/// Updating this value is synchronous and side-effect free; the session uses it
/// only when it closes a complete observation window.
struct DemandVideoLivenessContext: Sendable, Equatable {
    let source: DemandLivenessSourceIdentity
    /// Presentation-owner lease, distinct from the backend load generation.
    /// A replacement screen can keep the same source/session alive briefly;
    /// its lease must still start a fresh liveness sequence.
    let ownerLeaseGeneration: UInt64
    let appState: DemandLivenessAppState
    let intent: DemandLivenessIntent
    let canAutoRevive: Bool
    let lifecycle: DemandLivenessLifecycle
    let observedPiPLease: Bool
    let seek: DemandLivenessSeekPhase
    /// Terminal media is a policy fact, not an empty-window symptom. The
    /// detector stands down before considering packet/runway evidence.
    let terminalState: PlaybackTerminalState

    init(
        source: DemandLivenessSourceIdentity,
        ownerLeaseGeneration: UInt64 = 0,
        appState: DemandLivenessAppState = .active,
        intent: DemandLivenessIntent = .playing,
        canAutoRevive: Bool = true,
        lifecycle: DemandLivenessLifecycle = .settled,
        observedPiPLease: Bool = false,
        seek: DemandLivenessSeekPhase = .settled,
        terminalState: PlaybackTerminalState = .active
    ) {
        self.source = source
        self.ownerLeaseGeneration = ownerLeaseGeneration
        self.appState = appState
        self.intent = intent
        self.canAutoRevive = canAutoRevive
        self.lifecycle = lifecycle
        self.observedPiPLease = observedPiPLease
        self.seek = seek
        self.terminalState = terminalState
    }
}

struct DemandLivenessInputDelta: Sendable, Equatable {
    var videoPacketsDequeued: Int = 0
    var submittedPackets: Int = 0
    var consumedVideoSeconds: TimeInterval = 0
    var bytesRead: Int64 = 0
    var pumpCalls: Int = 0
    var ingestedPackets: Int = 0
    var emptyPump: Bool = false
    var segmentProgress: Bool = false

    init(
        videoPacketsDequeued: Int = 0,
        submittedPackets: Int = 0,
        consumedVideoSeconds: TimeInterval = 0,
        bytesRead: Int64 = 0,
        pumpCalls: Int = 0,
        ingestedPackets: Int = 0,
        emptyPump: Bool = false,
        segmentProgress: Bool = false
    ) {
        self.videoPacketsDequeued = videoPacketsDequeued
        self.submittedPackets = submittedPackets
        self.consumedVideoSeconds = consumedVideoSeconds
        self.bytesRead = bytesRead
        self.pumpCalls = pumpCalls
        self.ingestedPackets = ingestedPackets
        self.emptyPump = emptyPump
        self.segmentProgress = segmentProgress
    }
}

struct DemandLivenessOutputDelta: Sendable, Equatable {
    var successfulCallbacks: Int = 0
    var outputFrames: Int = 0
    var outputPTSAdvanced: Bool = false
    var outputPTSDelta: TimeInterval?

    init(
        successfulCallbacks: Int = 0,
        outputFrames: Int = 0,
        outputPTSAdvanced: Bool = false,
        outputPTSDelta: TimeInterval? = nil
    ) {
        self.successfulCallbacks = successfulCallbacks
        self.outputFrames = outputFrames
        self.outputPTSAdvanced = outputPTSAdvanced
        self.outputPTSDelta = outputPTSDelta
    }
}

/// Monotonic decoded-output PTS evidence used by the session collector.
/// Decoder output can arrive in decode order (including B-frame reordering),
/// so a regressing PTS must not lower the high-water mark and make a later
/// frame look like fresh progress.
enum DemandLivenessPTSObservation: Sendable, Equatable {
    case invalid
    case noProgress
    case advanced(delta: TimeInterval?)
}

struct DemandLivenessPTSProgress: Sendable, Equatable {
    private(set) var highWaterMark: TimeInterval?

    init() {
        highWaterMark = nil
    }

    mutating func reset() {
        highWaterMark = nil
    }

    mutating func observe(_ pts: TimeInterval) -> DemandLivenessPTSObservation {
        guard pts.isFinite else { return .invalid }
        guard let previous = highWaterMark else {
            highWaterMark = pts
            return .advanced(delta: nil)
        }
        guard pts > previous + 1e-6 else { return .noProgress }
        let delta = pts - previous
        guard delta.isFinite, delta > 0 else { return .noProgress }
        highWaterMark = pts
        return .advanced(delta: delta)
    }
}

struct DemandLivenessDeliveryDelta: Sendable, Equatable {
    var admittedFrames: Int = 0
    var presentedFrames: Int = 0
    var admittedPTSAdvanced: Bool = false
    var presentedPTSAdvanced: Bool = false
    var renderer: DemandLivenessRenderer = .ready
    var displayClockAdvanced: Bool = false

    init(
        admittedFrames: Int = 0,
        presentedFrames: Int = 0,
        admittedPTSAdvanced: Bool = false,
        presentedPTSAdvanced: Bool = false,
        renderer: DemandLivenessRenderer = .ready,
        displayClockAdvanced: Bool = false
    ) {
        self.admittedFrames = admittedFrames
        self.presentedFrames = presentedFrames
        self.admittedPTSAdvanced = admittedPTSAdvanced
        self.presentedPTSAdvanced = presentedPTSAdvanced
        self.renderer = renderer
        self.displayClockAdvanced = displayClockAdvanced
    }
}

/// A fixed, already-complete observation window. The detector does not read a
/// clock or assemble windows; callers must provide the elapsed window duration
/// and all deltas from the same session/owner generation.
struct DemandLivenessWindow: Sendable, Equatable {
    let windowIndex: UInt64
    let durationSeconds: TimeInterval
    let sessionGeneration: UInt64
    let ownerGeneration: UInt64
    let ownerLeaseGeneration: UInt64
    let source: DemandLivenessSourceIdentity
    let appState: DemandLivenessAppState
    let intent: DemandLivenessIntent
    let lifecycle: DemandLivenessLifecycle
    let seek: DemandLivenessSeekPhase
    let isReady: Bool
    let isBuffering: Bool
    let hasVideoTrack: Bool
    let canAutoRevive: Bool
    let startupElapsedSeconds: TimeInterval
    let input: DemandLivenessInputDelta
    let output: DemandLivenessOutputDelta
    let delivery: DemandLivenessDeliveryDelta
    let mediaTimeDelta: TimeInterval
    let renderedContentDelta: TimeInterval
    let compressedRunwaySeconds: TimeInterval
    let decodedRunwaySeconds: TimeInterval
    let audioRunwaySeconds: TimeInterval
    let eof: DemandLivenessEOF
    let observedPiPLease: Bool
    let terminalState: PlaybackTerminalState
    /// Stable packet-duration or output-PTS estimate. Unknown values are nil;
    /// nil never shortens the baseline three-window policy.
    let expectedFramePeriodSeconds: TimeInterval?

    init(
        windowIndex: UInt64,
        durationSeconds: TimeInterval,
        sessionGeneration: UInt64,
        ownerGeneration: UInt64,
        ownerLeaseGeneration: UInt64 = 0,
        source: DemandLivenessSourceIdentity,
        appState: DemandLivenessAppState = .active,
        intent: DemandLivenessIntent = .playing,
        lifecycle: DemandLivenessLifecycle = .settled,
        seek: DemandLivenessSeekPhase = .settled,
        isReady: Bool = true,
        isBuffering: Bool = false,
        hasVideoTrack: Bool = true,
        canAutoRevive: Bool = true,
        startupElapsedSeconds: TimeInterval = .infinity,
        input: DemandLivenessInputDelta = DemandLivenessInputDelta(),
        output: DemandLivenessOutputDelta = DemandLivenessOutputDelta(),
        delivery: DemandLivenessDeliveryDelta = DemandLivenessDeliveryDelta(),
        mediaTimeDelta: TimeInterval = 0,
        renderedContentDelta: TimeInterval = 0,
        compressedRunwaySeconds: TimeInterval = 0,
        decodedRunwaySeconds: TimeInterval = 0,
        audioRunwaySeconds: TimeInterval = 0,
        eof: DemandLivenessEOF = .notEOF,
        observedPiPLease: Bool = false,
        expectedFramePeriodSeconds: TimeInterval? = nil,
        terminalState: PlaybackTerminalState = .active
    ) {
        self.windowIndex = windowIndex
        self.durationSeconds = durationSeconds
        self.sessionGeneration = sessionGeneration
        self.ownerGeneration = ownerGeneration
        self.ownerLeaseGeneration = ownerLeaseGeneration
        self.source = source
        self.appState = appState
        self.intent = intent
        self.lifecycle = lifecycle
        self.seek = seek
        self.isReady = isReady
        self.isBuffering = isBuffering
        self.hasVideoTrack = hasVideoTrack
        self.canAutoRevive = canAutoRevive
        self.startupElapsedSeconds = startupElapsedSeconds
        self.input = input
        self.output = output
        self.delivery = delivery
        self.mediaTimeDelta = mediaTimeDelta
        self.renderedContentDelta = renderedContentDelta
        self.compressedRunwaySeconds = compressedRunwaySeconds
        self.decodedRunwaySeconds = decodedRunwaySeconds
        self.audioRunwaySeconds = audioRunwaySeconds
        self.eof = eof
        self.observedPiPLease = observedPiPLease
        self.terminalState = terminalState
        self.expectedFramePeriodSeconds = expectedFramePeriodSeconds
    }
}

struct DemandVideoLivenessPolicy: Sendable, Equatable {
    var observationWindowSeconds: TimeInterval = 1
    var minimumConsecutiveSilentWindows: Int = 3
    var minimumSilentSpanSeconds: TimeInterval = 3
    var startupGraceSeconds: TimeInterval = 5
    /// Two expected frame periods are required before a low-rate source can
    /// enter the provisional silent span. Normal 24/30/60 fps sources remain
    /// governed by the three-window baseline.
    var expectedFramePeriodMultiplier: TimeInterval = 2

    static let provisional = Self()

    init(
        observationWindowSeconds: TimeInterval = 1,
        minimumConsecutiveSilentWindows: Int = 3,
        minimumSilentSpanSeconds: TimeInterval = 3,
        startupGraceSeconds: TimeInterval = 5,
        expectedFramePeriodMultiplier: TimeInterval = 2
    ) {
        self.observationWindowSeconds = observationWindowSeconds
        self.minimumConsecutiveSilentWindows = minimumConsecutiveSilentWindows
        self.minimumSilentSpanSeconds = minimumSilentSpanSeconds
        self.startupGraceSeconds = startupGraceSeconds
        self.expectedFramePeriodMultiplier = expectedFramePeriodMultiplier
    }

    func requiredSilentWindows(expectedFramePeriodSeconds: TimeInterval?) -> Int {
        let minimumWindows = max(1, minimumConsecutiveSilentWindows)
        let window = observationWindowSeconds.isFinite && observationWindowSeconds > 0
            ? observationWindowSeconds
            : 1
        let minimumSpan = Self.finiteNonNegative(minimumSilentSpanSeconds)
        let baselineProduct = Double(minimumWindows) * window
        let baselineSpan = max(
            minimumSpan,
            baselineProduct
        )
        let stablePeriod = expectedFramePeriodSeconds.flatMap { period in
            period.isFinite && period > 0 ? period : nil
        }
        // An unknown frame period keeps the three-window baseline; only a
        // stable low frame rate may extend the span beyond it.
        var span = baselineSpan
        if let stablePeriod {
            let extensionSpan = Self.finiteNonNegative(expectedFramePeriodMultiplier)
                * stablePeriod
            span = extensionSpan.isFinite ? max(baselineSpan, extensionSpan) : .infinity
        }
        return max(minimumWindows, Self.safeCeilToInt(span / window - 1e-9))
    }

    private static func finiteNonNegative(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func safeCeilToInt(_ value: TimeInterval) -> Int {
        guard value.isFinite else { return Int.max }
        // Double(Int.max) rounds to 2^63. Never pass that boundary to Int(),
        // which traps even though the policy result is meant to be bounded.
        guard value < Double(Int.max) else { return Int.max }
        return max(0, Int(ceil(value)))
    }
}

enum DemandLivenessState: Sendable, Equatable {
    case idle
    case warmup
    case observing(consecutiveSilentWindows: Int)
    case emitted(sessionGeneration: UInt64, ownerGeneration: UInt64)
}

enum DemandLivenessDecision: Sendable, Equatable {
    case hold(reason: DemandLivenessSuppression)
    case observe(consecutiveSilentWindows: Int)
    case diagnostic(DemandLivenessDiagnostic)
    case emit(fault: MediaRuntimeFault)
}

struct DemandLivenessStep: Sendable, Equatable {
    let state: DemandLivenessState
    let decision: DemandLivenessDecision
}

/// Pure Demand video liveness state machine. It accepts only complete windows
/// and produces a typed fault; it does not own a Task, Timer, renderer,
/// demuxer, backend, network request, or reload authority.
struct DemandVideoSilentNoOutputDetector: Sendable, Equatable {
    private struct Identity: Sendable, Equatable {
        let sessionGeneration: UInt64
        let ownerGeneration: UInt64
        let ownerLeaseGeneration: UInt64
        let source: DemandLivenessSourceIdentity
    }

    private(set) var state: DemandLivenessState = .idle
    private var identity: Identity?
    private var lastWindowIndex: UInt64?

    mutating func reset() {
        state = .idle
        identity = nil
        lastWindowIndex = nil
    }

    mutating func observe(
        _ window: DemandLivenessWindow,
        policy: DemandVideoLivenessPolicy = .provisional
    ) -> DemandLivenessStep {
        let currentIdentity = Identity(
            sessionGeneration: window.sessionGeneration,
            ownerGeneration: window.ownerGeneration,
            ownerLeaseGeneration: window.ownerLeaseGeneration,
            source: window.source
        )

        guard isComplete(window, policy: policy) else {
            state = .idle
            identity = currentIdentity
            lastWindowIndex = window.windowIndex
            return step(.hold(reason: .invalidWindow))
        }

        if let identity, identity != currentIdentity {
            // A replacement starts with a clean detector. Do not allow the
            // replacement's first window to inherit old silent count.
            state = .idle
            self.identity = currentIdentity
            lastWindowIndex = window.windowIndex
            return step(.hold(reason: .generationChanged))
        }
        self.identity = currentIdentity

        if let lastWindowIndex {
            guard lastWindowIndex != UInt64.max,
                  window.windowIndex == lastWindowIndex + 1 else {
                state = .idle
                self.lastWindowIndex = window.windowIndex
                return step(.hold(reason: .invalidWindow))
            }
        }
        lastWindowIndex = window.windowIndex

        if case .emitted = state {
            return step(.hold(reason: .alreadyEmitted))
        }
        guard window.hasVideoTrack else {
            state = .idle
            return step(.hold(reason: .noVideoTrack))
        }
        guard window.isReady else {
            state = .warmup
            return step(.hold(reason: .notReady))
        }
        guard !window.isBuffering else {
            state = .idle
            return step(.hold(reason: .buffering))
        }
        guard window.intent == .playing, window.canAutoRevive else {
            state = .idle
            return step(.hold(reason: .paused))
        }
        guard window.seek == .settled else {
            state = .idle
            return step(.hold(reason: .seeking))
        }
        guard lifecycleAllowsObservation(window) else {
            state = .idle
            switch window.lifecycle {
            case .backgroundNoPiP:
                return step(.hold(reason: .backgroundWithoutObservedPiP))
            case .settled:
                return step(.hold(reason: .lifecycleSettling))
            case .foregroundSettling, .backgroundObservedPiP:
                return step(.hold(reason: .lifecycleSettling))
            }
        }
        guard !window.terminalState.isTerminal else {
            state = .idle
            return step(.hold(reason: .terminal))
        }
        guard window.eof != .finiteEOFDrained else {
            state = .idle
            return step(.hold(reason: .finiteEOF))
        }
        guard startupHasSettled(window, policy: policy) else {
            state = .warmup
            return step(.hold(reason: .startup))
        }

        let consumed = window.input.videoPacketsDequeued > 0
            && window.input.consumedVideoSeconds.isFinite
            && window.input.consumedVideoSeconds > 0
        guard consumed else {
            state = .idle
            return step(.diagnostic(.inputStarvation))
        }

        let outputProgress = window.output.outputFrames > 0
            && window.output.outputPTSAdvanced
        if outputProgress {
            state = .observing(consecutiveSilentWindows: 0)
            if window.delivery.admittedFrames <= 0
                    || window.delivery.presentedFrames <= 0 {
                return step(.diagnostic(.rendererOnlyLoss))
            }
            return step(.diagnostic(.outputProgress))
        }

        // A callback that produced a frame without a trustworthy advancing PTS
        // is not enough to identify VT as the failing layer. Keep it diagnostic
        // and reset the high-confidence sequence.
        if window.output.outputFrames > 0 {
            state = .idle
            return step(.diagnostic(.callbackWithoutOutput))
        }

        guard window.delivery.renderer.isHealthy else {
            state = .idle
            return step(.hold(reason: .rendererBlocked))
        }

        let silent: Int
        if case .observing(let previous) = state {
            silent = previous == Int.max ? Int.max : previous + 1
        } else {
            silent = 1
        }
        let required = policy.requiredSilentWindows(
            expectedFramePeriodSeconds: window.expectedFramePeriodSeconds
        )
        if silent >= required {
            let fault = makeFault(window: window, silentWindows: silent)
            state = .emitted(
                sessionGeneration: window.sessionGeneration,
                ownerGeneration: window.ownerGeneration
            )
            return step(.emit(fault: fault))
        }

        state = .observing(consecutiveSilentWindows: silent)
        if required > max(1, policy.minimumConsecutiveSilentWindows) {
            return step(.diagnostic(.lowFrameRate))
        }
        return step(.observe(consecutiveSilentWindows: silent))
    }

    private func step(_ decision: DemandLivenessDecision) -> DemandLivenessStep {
        DemandLivenessStep(state: state, decision: decision)
    }

    private func isComplete(
        _ window: DemandLivenessWindow,
        policy: DemandVideoLivenessPolicy
    ) -> Bool {
        guard window.durationSeconds.isFinite,
              window.durationSeconds > 0,
              policy.observationWindowSeconds.isFinite,
              policy.observationWindowSeconds > 0
        else { return false }
        let tolerance = max(0.05, policy.observationWindowSeconds * 0.1)
        guard tolerance.isFinite else { return false }
        return abs(window.durationSeconds - policy.observationWindowSeconds) <= tolerance
    }

    private func lifecycleAllowsObservation(_ window: DemandLivenessWindow) -> Bool {
        switch window.appState {
        case .active:
            return window.lifecycle == .settled
        case .inactive:
            return false
        case .background:
            return window.lifecycle == .backgroundObservedPiP
                && window.observedPiPLease
        }
    }

    private func startupHasSettled(
        _ window: DemandLivenessWindow,
        policy: DemandVideoLivenessPolicy
    ) -> Bool {
        guard policy.startupGraceSeconds.isFinite else { return false }
        guard policy.startupGraceSeconds > 0 else { return true }
        // The default window initializer uses +infinity as an explicit
        // "startup timing is not supplied; treat as settled" sentinel. Other
        // non-finite elapsed values are invalid and must not enable recovery.
        if window.startupElapsedSeconds == .infinity { return true }
        guard window.startupElapsedSeconds.isFinite,
              window.startupElapsedSeconds >= 0 else { return false }
        return window.startupElapsedSeconds >= policy.startupGraceSeconds
    }

    private func makeFault(
        window: DemandLivenessWindow,
        silentWindows: Int
    ) -> MediaRuntimeFault {
        let pts = window.output.outputPTSDelta.map {
            String(format: "%.3f", $0)
        } ?? "none"
        let details =
            "windows=\(silentWindows) span=\(String(format: "%.1f", Double(silentWindows) * window.durationSeconds)) " +
            "dq=\(max(0, window.input.videoPacketsDequeued)) " +
            "sub=\(max(0, window.input.submittedPackets)) " +
            "sec=\(String(format: "%.3f", max(0, window.input.consumedVideoSeconds))) " +
            "out=\(max(0, window.output.outputFrames)) pts=\(pts) " +
            "vRun=\(String(format: "%.2f", max(0, window.decodedRunwaySeconds)))"
        return MediaRuntimeFault(
            subsystem: .videoDecoder,
            stage: .liveness,
            classification: .silentNoOutput,
            recoverability: .automaticSourceAwareReopen,
            sessionGeneration: window.sessionGeneration,
            ownerGeneration: window.ownerGeneration,
            ownerLeaseGeneration: window.ownerLeaseGeneration,
            diagnostics: MediaRuntimeFaultDiagnostics(
                status: nil,
                label: "silentNoOutput",
                details: details
            )
        )
    }
}
