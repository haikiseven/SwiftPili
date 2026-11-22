import Foundation

// Pure policy for the freeze instrumentation: the signal shapes and the
// decision table that turns three ages into a verdict. Split out of
// `FreezeWatchdog.swift` for the same reason as `NearEndClockPolicy` and
// `ForegroundDecoderPolicy` — everything here is `import Foundation` only, so
// it is testable (and runnable off-device) without a run loop, a display link
// or a main thread to block.

/// What the player pushes at 1Hz: values only. It deliberately carries no
/// "when did this last move" field — the producer is on the main actor and
/// would have to keep that history itself, while the consumer can derive it for
/// free by comparing consecutive pushes. Keeping the derivation on the watchdog
/// side means no new stored state in `PlayerViewModel` and one place where
/// "moved" is defined.
struct FreezePlayerSample: Sendable {
    /// Identity of the stream these values belong to. A new load resets the
    /// movement anchors: comparing the new video's t=0 against the previous
    /// one's t=41 would register as a jump, and "the value changed" is not
    /// "the clock is alive" across a load.
    var streamID: String
    var mode: String
    var engine: String
    var state: String
    /// Whether the player BELIEVES it should be advancing. A paused player with
    /// a frozen clock is correct, not starved — and this is the flag that keeps
    /// the starvation verdict from firing on every pause.
    var expectsProgress: Bool
    var mediaTime: TimeInterval
    /// Presentation clock (`PlayerViewModel.displayTime`) — the nearest thing
    /// either shipping backend exposes to a rendered video PTS.
    var displayTime: TimeInterval
    var fps: Double
    /// Which subsystem owns the clock, because "audio clock" means different
    /// things per engine and the report must not blur them: on Demand the media
    /// clock IS the drained-audio clock (its single writer), on libVLC the
    /// clock is internal and no separate audio clock is exposed at all.
    var clockSource: String
    /// Measured delivery runway — nil means UNMEASURED (libVLC), never zero.
    /// Same contract as `PlaybackStats.bufferHealth`. This is the BINDING track
    /// (F3), so it can be short because of either half.
    var runway: TimeInterval?
    /// The video half on its own, so a freeze report can say WHICH track ran dry.
    /// A frozen picture over a healthy soundtrack is a different bug from a
    /// stalled soundtrack, and the binding minimum alone cannot tell them apart.
    var videoRunway: TimeInterval?
    var available: TimeInterval
    /// The displayed network rate: bytes RECEIVED from the wire (store hits
    /// excluded; multi-connection read-ahead included).
    var networkKBs: Int
    /// Pipeline goodput — content entering the decode pipeline, the figure
    /// delivery health and `dataFlowing` reason about. Printed as `gp=`.
    var goodputKBs: Int
    var quality: String
    var host: String
    var recovery: String
}

/// A sample plus the ages that make it interpretable. A value alone cannot
/// answer "is the player frozen" — a mediaTime of 41.3 is healthy if it moved a
/// moment ago and a stall if it has read 41.3 for nine seconds. So every
/// quantity that can freeze carries the uptime at which it last CHANGED,
/// separately from the uptime at which it was last OBSERVED.
///
/// That split is the whole instrument. `observedAt` fresh + `mediaTimeMovedAt`
/// old is a starved player on a healthy app; both old is an app that stopped
/// running the sampler at all. Collapsing them into one "last update" stamp —
/// the obvious design — cannot tell those apart, which is the exact confusion
/// this watchdog exists to end.
struct FreezePlayerSignals: Sendable {
    var sample: FreezePlayerSample
    var observedAt: TimeInterval
    var mediaTimeMovedAt: TimeInterval
    var displayTimeMovedAt: TimeInterval
    var fpsLiveAt: TimeInterval

    init(first sample: FreezePlayerSample, at now: TimeInterval) {
        self.sample = sample
        observedAt = now
        mediaTimeMovedAt = now
        displayTimeMovedAt = now
        fpsLiveAt = now
    }

    /// Movement, not monotonic progress: a backward seek changes the clock and
    /// proves it is alive just as well as forward playback does. The epsilon is
    /// there so float noise in a backend-reported position cannot read as
    /// motion — a genuinely advancing clock clears 1ms per second easily.
    static let movementEpsilon: TimeInterval = 0.001

    mutating func absorb(_ next: FreezePlayerSample, at now: TimeInterval) {
        observedAt = now
        if abs(next.mediaTime - sample.mediaTime) > Self.movementEpsilon {
            mediaTimeMovedAt = now
        }
        if abs(next.displayTime - sample.displayTime) > Self.movementEpsilon {
            displayTimeMovedAt = now
        }
        if next.fps >= 1 { fpsLiveAt = now }
        sample = next
    }
}

/// What the ages actually mean. Four cases, not the two a main-thread stall
/// timer can see.
///
/// The pair that matters most is `mainThreadFreeze` vs `mainQueueStarvation`.
/// The CADisplayLink runs on the MAIN RUN LOOP in `.common` mode, so a blocked
/// main thread stops it too — display stale alongside a stalled acknowledgement
/// is the signature of a genuinely blocked thread. But a run loop spinning in a
/// nested mode (scroll tracking, a modal CFRunLoop, a synchronous drag) keeps
/// servicing the display link while `DispatchQueue.main.async` blocks are not
/// drained at all: frames keep coming, the UI even animates, and every
/// main-queue continuation is starved. That reads to a user as a freeze and to a
/// stall timer as a blocked thread, and it is neither.
enum FreezeVerdict: Equatable, Sendable {
    /// Main-queue acknowledgement stalled AND the display link stopped.
    case mainThreadFreeze
    /// Acknowledgement stalled while the display link kept ticking.
    case mainQueueStarvation
    /// Acknowledgement healthy, display link stale — render/display pipeline.
    case displayStall
    /// App healthy, media clock not advancing while the player expects it to.
    case playerStarvation

    var label: String {
        switch self {
        case .mainThreadFreeze: "main-thread-freeze"
        case .mainQueueStarvation: "main-queue-starvation"
        case .displayStall: "display-stall"
        case .playerStarvation: "player-starvation"
        }
    }

    /// One line saying what the reader should conclude. A verdict nobody can
    /// act on is a label, not a diagnosis.
    var meaning: String {
        switch self {
        case .mainThreadFreeze:
            "main thread blocked — display link stopped with it; the whole UI is dead"
        case .mainQueueStarvation:
            "run loop alive (display ticking) but main-queue work not draining — "
                + "nested run loop / tracking mode, NOT a blocked thread"
        case .displayStall:
            "main thread responsive, display link stale — render/display pipeline, not an app freeze"
        case .playerStarvation:
            "UI and display healthy, media clock frozen — player starvation, NOT an app freeze"
        }
    }
}

/// Pure classification, so the decision table is pinnable by a test with no
/// queue, no clock and no device.
enum FreezeClassifier {
    /// Above this, a main-queue acknowledgement is late enough to be visible.
    static let stallSeconds: TimeInterval = 0.5
    /// Above this, the user is looking at a frozen app.
    static let freezeSeconds: TimeInterval = 1.0
    /// 30 missed frames at 60Hz — well past any legitimate ProMotion rate
    /// shift or single dropped slot.
    static let displayStaleSeconds: TimeInterval = 0.5
    /// The media clock is sampled at 1Hz and the reactive ladder already owns
    /// recovery at 5s; 3s is late enough not to fire on sampling jitter and
    /// early enough to precede the ladder's own verdict.
    static let clockStaleSeconds: TimeInterval = 3.0
    /// A "freeze" that recovers after this long is far likelier to be a
    /// suspension or debugger artefact than a hang. Reported, never persisted.
    static let implausibleSeconds: TimeInterval = 60

    /// nil = nothing to report. `displayAge` nil = the display link is not
    /// running, which is an ABSENT measurement: it must not be resolved to
    /// "stale" and let a healthy app be reported as a freeze.
    static func classify(
        ackAge: TimeInterval,
        displayAge: TimeInterval?,
        clockAge: TimeInterval?
    ) -> FreezeVerdict? {
        if ackAge >= stallSeconds {
            // Display unmeasured ⇒ cannot separate the two main-thread cases.
            // Report the one that does not overclaim: a stalled ack with no
            // display evidence is still a blocked main thread as far as any
            // main-queue work is concerned.
            guard let displayAge else { return .mainThreadFreeze }
            return displayAge >= displayStaleSeconds ? .mainThreadFreeze : .mainQueueStarvation
        }
        if let displayAge, displayAge >= displayStaleSeconds { return .displayStall }
        if let clockAge, clockAge >= clockStaleSeconds { return .playerStarvation }
        return nil
    }

    /// `stall` below the freeze threshold, `freeze` at or above it. Only the
    /// second tier earns a disk write.
    static func severity(ackAge: TimeInterval) -> String {
        ackAge >= freezeSeconds ? "freeze" : "stall"
    }
}
