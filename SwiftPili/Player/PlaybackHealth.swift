import Foundation

enum PlaybackTerminalState: String, Equatable, Sendable {
    case active
    case ended
    case terminalFailure
    case stopped

    var isTerminal: Bool { self != .active }
    var isNaturalEnd: Bool { self == .ended }
}

enum PlaybackReplayPolicy {
    static let canonicalOrigin: TimeInterval = 0

    static func allows(from terminalState: PlaybackTerminalState) -> Bool {
        terminalState == .ended
    }
}

struct PlaybackSignals: Equatable {
    var position: TimeInterval
    var clockAdvancing: Bool
    var framesAdvancing: Bool
    var framesProven: Bool
    var dataFlowing: Bool
    var hasVideoTrack: Bool
    var hasStartedPlaying: Bool = true
    var hasBufferedRunway: Bool = false
    var decoderLivenessOwnedByBackend: Bool = false
    var elapsedSinceStart: TimeInterval
    var terminalState: PlaybackTerminalState = .active
}

func hasProvenBufferedRunway(
    contentAhead: TimeInterval?,
    floor: TimeInterval
) -> Bool {
    guard let contentAhead, contentAhead.isFinite else { return false }
    return contentAhead >= floor
}

enum PlaybackFault: String, Equatable {
    case deadDecoder
    case stalledPipeline
    case starvedInput
}

extension PlaybackSignals {
    var isStartup: Bool { position < 0.5 }

    static let startupGracePeriod: TimeInterval = 5
    static let statsWarmUp: TimeInterval = 15

    var suppressionReason: String? {
        switch terminalState {
        case .active:
            break
        case .ended:
            return "terminal/ended"
        case .terminalFailure:
            return "terminal/failure"
        case .stopped:
            return "terminal/stopped"
        }
        if !hasStartedPlaying, elapsedSinceStart < Self.startupGracePeriod {
            return "startup-grace"
        }
        if clockAdvancing {
            if decoderLivenessOwnedByBackend { return "clock-ok/backend-owns-liveness" }
            if !hasVideoTrack { return "clock-ok/audio-only" }
            if !framesProven { return "clock-ok/frames-never-proven" }
            if framesAdvancing { return "clock-ok/frames-advancing" }
            if elapsedSinceStart <= Self.statsWarmUp { return "clock-ok/stats-cold" }
            return nil
        }
        if !dataFlowing, !hasBufferedRunway { return nil }
        if framesAdvancing { return "frozen-clock/frames-advancing" }
        if hasBufferedRunway {
            if framesProven || !hasVideoTrack { return "frozen-clock/runway-veto" }
            if elapsedSinceStart <= Self.statsWarmUp { return "frozen-clock/runway-warmup" }
        }
        if !hasStartedPlaying { return "frozen-clock/priming" }
        return nil
    }
}

struct RecoveryBudget: Equatable {
    static let maxCDNSwitches = 3
    static let maxDecoderReloads = 2
    static let samePositionWindow: TimeInterval = 5
    static let clearOfStallDistance: TimeInterval = 15

    private(set) var cdnSwitches = 0
    private(set) var decoderReloads = 0
    private(set) var stallStreak = 0

    static let maxStreamRetries = 6
    static let streamRecoveryDuration: TimeInterval = 120
    static let streamStableDuration: TimeInterval = 15
    private(set) var streamRetries = 0
    private(set) var streamStartedAt: TimeInterval?
    private var streamStableSince: TimeInterval?
    private var streamLastProgressAt: TimeInterval?
    mutating func beginStreamRecovery(at now: TimeInterval) {
        if streamStartedAt == nil { streamStartedAt = now }
        interruptStreamStability()
    }
    func streamRemaining(at now: TimeInterval) -> TimeInterval {
        guard let start = streamStartedAt else { return Self.streamRecoveryDuration }
        return max(0, Self.streamRecoveryDuration - (now - start))
    }
    mutating func spendStreamRetry(at now: TimeInterval) -> Bool {
        guard streamStartedAt != nil, streamRemaining(at: now) > 0,
              streamRetries < Self.maxStreamRetries else { return false }
        streamRetries += 1
        return true
    }
    func streamRetryDelay(jitter: Double, retryAfter: TimeInterval?) -> TimeInterval {
        let schedule: [TimeInterval] = [1, 2, 4, 8, 12, 12]
        let base = schedule[min(streamRetries, schedule.count - 1)]
        return max(base * min(1.2, max(0.8, jitter)), retryAfter ?? 0)
    }
    mutating func interruptStreamStability() {
        streamStableSince = nil
        streamLastProgressAt = nil
    }
    mutating func noteStreamProgress(at now: TimeInterval) -> Bool {
        guard streamStartedAt != nil else { return false }
        if let last = streamLastProgressAt, now - last > 2 { streamStableSince = nil }
        if streamStableSince == nil { streamStableSince = now }
        streamLastProgressAt = now
        guard let start = streamStableSince, now - start >= Self.streamStableDuration else { return false }
        clearStreamRecovery()
        return true
    }
    mutating func clearStreamRecovery() {
        streamRetries = 0
        streamStartedAt = nil
        interruptStreamStability()
    }

    private var lastStallPosition: TimeInterval = -1000
    private var lastDecoderReloadPosition: TimeInterval = -1000

    var canSwitchCDN: Bool { cdnSwitches < Self.maxCDNSwitches }

    mutating func spendCDNSwitch() -> Bool {
        guard canSwitchCDN else { return false }
        cdnSwitches += 1
        return true
    }

    mutating func refundCDNSwitch() {
        cdnSwitches = max(0, cdnSwitches - 1)
    }

    mutating func spendDecoderReload(at position: TimeInterval) -> Bool {
        guard decoderReloads < Self.maxDecoderReloads else { return false }
        decoderReloads += 1
        lastDecoderReloadPosition = position
        return true
    }

    mutating func refundDecoderReloadsIfMovedClear(at position: TimeInterval) -> Bool {
        guard decoderReloads > 0,
              abs(position - lastDecoderReloadPosition) > Self.clearOfStallDistance
        else { return false }
        decoderReloads = 0
        return true
    }

    mutating func recordStall(at position: TimeInterval) -> Int {
        stallStreak = abs(position - lastStallPosition) < Self.samePositionWindow
            ? stallStreak + 1
            : 1
        lastStallPosition = position
        return stallStreak
    }

    func hasMovedClear(of position: TimeInterval) -> Bool {
        abs(position - lastStallPosition) > Self.clearOfStallDistance
    }

    mutating func clearStallStreak() { stallStreak = 0 }

    var summary: String {
        "cdn:\(cdnSwitches)/\(Self.maxCDNSwitches) dec:\(decoderReloads)/\(Self.maxDecoderReloads) stall:\(stallStreak)"
    }
}

func classifyPlayback(_ s: PlaybackSignals) -> PlaybackFault? {
    guard !s.terminalState.isTerminal else { return nil }

    if !s.hasStartedPlaying, s.elapsedSinceStart < PlaybackSignals.startupGracePeriod {
        return nil
    }

    if s.clockAdvancing {
        guard !s.decoderLivenessOwnedByBackend,
              s.hasVideoTrack,
              s.framesProven,
              !s.framesAdvancing,
              s.elapsedSinceStart > PlaybackSignals.statsWarmUp
        else { return nil }
        return .deadDecoder
    }

    if !s.dataFlowing, !s.hasBufferedRunway { return .starvedInput }

    if s.framesAdvancing { return nil }

    if s.hasBufferedRunway,
       s.framesProven || !s.hasVideoTrack
           || s.elapsedSinceStart <= PlaybackSignals.statsWarmUp {
        return nil
    }

    return s.hasStartedPlaying ? .stalledPipeline : nil
}
