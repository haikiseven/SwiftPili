import Foundation

/// Typed admission state for media that is no longer allowed to be revived by
/// an environment or health event. Natural end is deliberately distinct from
/// a failed open: both stand down lifecycle/recovery work, while only `.ended`
/// is eligible for the explicit replay path.
enum PlaybackTerminalState: String, Equatable, Sendable {
    case active
    case ended
    case terminalFailure
    case stopped

    var isTerminal: Bool { self != .active }
    var isNaturalEnd: Bool { self == .ended }
}

/// Explicit replay is a new normal start, never a recovery ticket. Keeping its
/// origin in a playback-state policy boundary prevents a stopped backend from
/// being kicked at its old EOF position.
enum PlaybackReplayPolicy {
    static let canonicalOrigin: TimeInterval = 0

    static func allows(from terminalState: PlaybackTerminalState) -> Bool {
        terminalState == .ended
    }
}

/// One sample of everything the player knows about whether playback is alive.
///
/// Sampled once per health tick, from one place. The point of this type is that
/// the *classification* below is a pure function of it: no detector may reach
/// back into the player and ask a different question, which is how the previous
/// three overlapping detectors ended up guarding against each other.
///
/// See `docs/PLAYER_DESIGN.md` §2.4.
struct PlaybackSignals: Equatable {
    /// The real clock. Never `player.currentTime`, which SwiftVLC stamps to the
    /// seek target (design doc F1).
    var position: TimeInterval
    /// The clock moved since the previous tick.
    var clockAdvancing: Bool
    /// Frames are being displayed right now.
    var framesAdvancing: Bool
    /// Frames have been displayed at least once for this load. Until they have,
    /// their absence proves nothing: libVLC's `displayedPictures` lives on the
    /// main input's stats and may not track every configuration (design doc F9).
    var framesProven: Bool
    /// Bytes arrived during the last sampling window.
    var dataFlowing: Bool
    /// The media declares a video track. Audio-only media must not look "dead".
    var hasVideoTrack: Bool
    /// The clock has advanced at least once since this stream started. Before it
    /// has, a frozen clock is normal priming — a demand-paced session filling its
    /// content queues, or a resume-at-N stream buffering the target fragment —
    /// not a stall. Only after first play is a motionless clock a fault.
    var hasStartedPlaying: Bool = true
    /// Decodable content is PROVEN buffered ahead of the play head. A demand-paced
    /// session that has filled its runway legitimately stops downloading (net=0),
    /// so `dataFlowing` goes false while several seconds of content sit ready —
    /// that is NOT input starvation, the input already supplied ahead. Defaults
    /// false so the VLC path (which cannot measure a runway at all) is unchanged.
    ///
    /// Set only through `hasProvenBufferedRunway`, which is where the unknown case
    /// is decided. Never assign a coalesced `?? 0` here: this flag is a veto, and
    /// an unmeasured runway must not cast a vote.
    var hasBufferedRunway: Bool = false
    /// The backend runs its own decoder-liveness detector, which owns decoder
    /// death for this session — so `.deadDecoder` is not classified here at all.
    ///
    /// The demand-paced session has one, and its evidence is strictly better than
    /// the frame counter below: video packets actually dequeued AND content-seconds
    /// consumed AND no monotonic decoded-PTS progress — where `framesAdvancing` is
    /// the exact signal this file's header records as untrustworthy (device:
    /// fps=21.6 while black). Two detectors for one fault is how they ended up
    /// starving each other's reload budget; the weaker one does not vote. libVLC
    /// has no such detector, so this defaults false and frame liveness stands.
    var decoderLivenessOwnedByBackend: Bool = false
    /// Seconds since this stream started. The frame counter needs a warm-up, and
    /// a stream is allowed to take a moment to produce its first picture.
    var elapsedSinceStart: TimeInterval
    /// Typed terminal admission state. An ended stream can legitimately have
    /// no bytes and no runway; those observations must never be reinterpreted
    /// as starvation by the health policy.
    var terminalState: PlaybackTerminalState = .active
}

/// Resolve a backend's optional delivery measurement into `PlaybackSignals.hasBufferedRunway`.
/// `nil` (unmeasurable, e.g. libVLC's sticky cache-fill) returns `false` so unknown
/// runway never vetoes frozen-clock recovery; `.starvedInput` still requires `!dataFlowing`.
func hasProvenBufferedRunway(
    contentAhead: TimeInterval?,
    floor: TimeInterval
) -> Bool {
    guard let contentAhead, contentAhead.isFinite else { return false }
    return contentAhead >= floor
}

/// Exactly one thing can be wrong at a time. Each fault has exactly one meaning
/// and (in the ViewModel) exactly one recovery.
enum PlaybackFault: String, Equatable {
    /// The clock advances but no frames come out. Data is irrelevant — whatever
    /// is decoding has stopped decoding.
    case deadDecoder
    /// Nothing moves, yet bytes keep arriving: the pipeline is wedged, not the
    /// network.
    case stalledPipeline
    /// Nothing moves and nothing arrives: the input is starved.
    case starvedInput
}

extension PlaybackSignals {
    /// Before playback has really begun, looking dead is normal — the first
    /// fragments have to arrive and decode. Only past this horizon is a
    /// motionless player a fault.
    var isStartup: Bool { position < 0.5 }

    /// A stream is allowed this long to produce its first picture.
    static let startupGracePeriod: TimeInterval = 5
    /// libVLC's statistics counters need this long before their zeroes mean
    /// anything.
    static let statsWarmUp: TimeInterval = 15

    /// Which guard in `classifyPlayback` decided there is no fault — `nil`
    /// exactly when a fault WAS classified.
    ///
    /// The evaluator only ever logged the half of its output where it recovered.
    /// On the other half a device capture was silent, so "the runway veto held
    /// recovery off", "nothing is wrong" and "the watchdog never ticked" all
    /// looked identical in a log — which is precisely the question an offline
    /// freeze asks. This names the deciding guard instead.
    ///
    /// It decides nothing: every branch mirrors one `return nil` below, in the
    /// same order, and the strings are log labels. Keeping it in this file, next
    /// to the classifier, is what stops the two drifting; the mirror is pinned in
    /// `PlaybackHealthTests` over the whole signal space.
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
            return nil // .deadDecoder
        }
        if !dataFlowing, !hasBufferedRunway { return nil } // .starvedInput
        if framesAdvancing { return "frozen-clock/frames-advancing" }
        if hasBufferedRunway {
            if framesProven || !hasVideoTrack { return "frozen-clock/runway-veto" }
            if elapsedSinceStart <= Self.statsWarmUp { return "frozen-clock/runway-warmup" }
            // Fall through when runway no longer vetoes so the next classifier guard decides.
        }
        if !hasStartedPlaying { return "frozen-clock/priming" }
        return nil // .stalledPipeline
    }
}

/// Shared per-video recovery budget across CDN switches (`switchCDN`) and
/// decoder reloads (`DecoderRecoveryAdmission.admit`).
struct RecoveryBudget: Equatable {
    /// Four hosts tried. Beyond that, a fifth mirror is not the answer.
    static let maxCDNSwitches = 3
    static let maxDecoderReloads = 2
    /// Two recoveries within this of each other are about the same position.
    static let samePositionWindow: TimeInterval = 5
    /// Playback this far past a poisoned position has cleared it.
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

    /// Spend one host. `false` means the pool is exhausted and the caller must
    /// escalate to something that isn't a host swap.
    mutating func spendCDNSwitch() -> Bool {
        guard canSwitchCDN else { return false }
        cdnSwitches += 1
        return true
    }

    /// The switch never happened (no aid/cid to reload) — give the host back.
    mutating func refundCDNSwitch() {
        cdnSwitches = max(0, cdnSwitches - 1)
    }

    /// Spend one decoder reload for a fault at `position`.
    mutating func spendDecoderReload(at position: TimeInterval) -> Bool {
        guard decoderReloads < Self.maxDecoderReloads else { return false }
        decoderReloads += 1
        lastDecoderReloadPosition = position
        return true
    }

    /// Preserve the existing distance-based decoder refund. A user seek may
    /// clear decoder debt; it never proves the stream's continuous stability.
    mutating func refundDecoderReloadsIfMovedClear(at position: TimeInterval) -> Bool {
        guard decoderReloads > 0,
              abs(position - lastDecoderReloadPosition) > Self.clearOfStallDistance
        else { return false }
        decoderReloads = 0
        return true
    }

    /// Consecutive recoveries within `samePositionWindow` of one position mean
    /// the POSITION is poisoned (a corrupt segment, an undecodable GOP), not the
    /// host — "next CDN, same spot" would re-download the same origin bytes
    /// forever. Returns the new streak, which selects the ladder rung.
    mutating func recordStall(at position: TimeInterval) -> Int {
        stallStreak = abs(position - lastStallPosition) < Self.samePositionWindow
            ? stallStreak + 1
            : 1
        lastStallPosition = position
        return stallStreak
    }

    /// Playback has moved clear of the position that was accumulating
    /// escalations — the region decoded after all, or was skipped.
    func hasMovedClear(of position: TimeInterval) -> Bool {
        abs(position - lastStallPosition) > Self.clearOfStallDistance
    }

    mutating func clearStallStreak() { stallStreak = 0 }

    /// For the `[stress]` line: the whole recovery state in one field.
    var summary: String {
        "cdn:\(cdnSwitches)/\(Self.maxCDNSwitches) dec:\(decoderReloads)/\(Self.maxDecoderReloads) stall:\(stallStreak)"
    }
}

/// The single classifier. Returns the one fault in effect, or nil.
///
/// The caller MUST already have excluded the phases in which these symptoms are
/// CORRECT rather than faulty: a seek in flight (the video legitimately holds a
/// frame while the clock travels), backgrounded (no display link, so no frames),
/// paused, or an error already surfaced. This function does not second-guess
/// them; it assumes it is only asked when playback is supposed to be running.
func classifyPlayback(_ s: PlaybackSignals) -> PlaybackFault? {
    // EOF is a typed terminal admission state, not an empty input window. It
    // must be checked before every byte/runway heuristic so natural end cannot
    // kick transport or spend a recovery budget.
    guard !s.terminalState.isTerminal else { return nil }

    if !s.hasStartedPlaying, s.elapsedSinceStart < PlaybackSignals.startupGracePeriod {
        return nil
    }

    if s.clockAdvancing {
        // The clock is fine, so the input and the demuxer are fine. The only
        // thing that can be wrong is downstream of them — and only if the frame
        // counter has ever proven it tracks reality, and no better-informed
        // detector already owns decoder death for this backend.
        guard !s.decoderLivenessOwnedByBackend,
              s.hasVideoTrack,
              s.framesProven,
              !s.framesAdvancing,
              s.elapsedSinceStart > PlaybackSignals.statsWarmUp
        else { return nil }
        return .deadDecoder
    }

    // The clock is frozen. Nothing arriving means the input is starved, and no
    // amount of frame counting changes that: a video output repainting its held
    // picture advances `displayedPictures` while the demuxer is dead. Observed
    // Only empty-AND-idle is input starvation; a full buffered runway with `net=0` is idle-because-full.
    if !s.dataFlowing, !s.hasBufferedRunway { return .starvedInput }

    if s.framesAdvancing { return nil }

    // A measured pipeline runway vetoes frozen-clock recovery only once presentation
    // is proven (`framesProven` or audio-only) or during initial `statsWarmUp`.
    if s.hasBufferedRunway,
       s.framesProven || !s.hasVideoTrack
           || s.elapsedSinceStart <= PlaybackSignals.statsWarmUp {
        return nil
    }

    // A frozen clock while bytes flow is only a stall once the stream has
    // actually played. Before first play it is normal priming — a demand-paced
    // session filling its queues, or resume-at-N buffering — where a motionless
    // clock is expected, not a wedged pipeline. (Genuine no-data still surfaced
    // above as `.starvedInput`, so a dead CDN during prime still fails over.)
    return s.hasStartedPlaying ? .stalledPipeline : nil
}
