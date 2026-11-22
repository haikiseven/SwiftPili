import Foundation
import os
import SwiftUI
import UIKit

// MARK: - The board

/// Everything the watchdog is allowed to read while the main thread is gone:
/// pushed by producers on their own threads, read under one lock, never queried
/// back across an actor boundary.
///
/// The signal SHAPES (`FreezePlayerSample`/`FreezePlayerSignals`) and the
/// decision table live in `FreezeSignals.swift`; this is only the mailbox they
/// arrive in.
private struct FreezeBoard {
    /// Uptime of the last main-queue acknowledgement that COMPLETED.
    var mainAckAt: TimeInterval = 0
    var player: FreezePlayerSignals?
    /// Last emitted PlayerLog line and its age. Free: no scanning, no copy
    /// beyond the string the logger already built.
    var lastLine: (text: String, at: TimeInterval)?
    /// Last line matching the small set of supply/transport/recovery markers —
    /// the events a freeze has to be correlated against.
    var lastNotable: (text: String, at: TimeInterval)?
    var screen: (name: String, at: TimeInterval)?
    /// Non-nil while the app is not `active`. Measuring across an inactive
    /// stretch produces nothing but false freezes: the main thread is
    /// legitimately unscheduled and our own queue is suspended with it.
    var inactiveSince: TimeInterval?
    /// No episode may open before this uptime. Set on becoming active, because
    /// the first foreground runloop pass legitimately does a lot of work.
    var graceUntil: TimeInterval = 0
}

// MARK: - Verdict

// MARK: - Watchdog

/// Detects visible software freezes from OUTSIDE the main thread, while they are
/// still happening.
///
/// This replaces `MainThreadStallMonitor`, whose measurement was structurally
/// unable to do that: it chained a ping to the main queue and read the clock
/// inside the reply, so the number only existed once the main thread came back.
/// A freeze the user force-quit produced no line at all, and a freeze in
/// progress produced nothing until it ended — which is precisely the window in
/// which every other signal (what is the display doing, is the clock moving,
/// what is burning CPU) still exists and can be read.
///
/// So the loop is inverted. One acknowledgement token is outstanding at a time;
/// the watchdog queue re-arms itself on its OWN schedule rather than on the
/// reply, and each tick ages the token that has not come back yet. Detection
/// therefore happens during the freeze, from a thread the freeze cannot reach,
/// and the whole snapshot is written from there.
///
/// **Constraints this type must keep.**
///  - Never `sync` to the main queue, and never touch a `@MainActor` member.
///    Every player/UI value it reports arrives by push (`notePlayer`,
///    `noteScreen`, `noteDisplayTick`) into a lock-guarded board; there is no
///    pull path to starve on. Reading `PlayerViewModel.shared.mediaTime` here
///    would deadlock against the very freeze being measured.
///  - One outstanding token, one self-rearming chain. Posting a token per tick
///    regardless of the last one would pile a hundred blocks onto a recovering
///    main queue and turn a 1s freeze into a measured 3s one.
///  - The board lock is never held across a log call. `PlayerLog` takes the
///    recorder's lock and dispatches; nesting the two invites the deadlock that
///    a freeze diagnostic must be the last thing in the app to cause.
///  - Report-only. It classifies `playerStarvation` but never acts on it:
///    recovery belongs to `watchdogTick` → `classifyPlayback` → `recover()`,
///    which is the single ladder, and a diagnostic that starts reopening
///    streams is a second one.
///
/// Armed in DEBUG only (`start()` is inert otherwise), same doctrine as
/// `PlaybackDebugRecorder`: the 10Hz queue/main round-trip is wasted wakeups on
/// a production build and skews any Energy Log baseline. The push helpers cost
/// one relaxed `Bool` read when it is not armed, so no call site needs `#if`.
///
/// MetricKit stays supplementary: `HangDiagnosticsReporter` is the only thing
/// that can name the blocked FRAMES, and it is not delivered under a debugger,
/// never in the Simulator, and sometimes only on the next launch. This watchdog
/// is what guarantees an event exists at all.
final class FreezeWatchdog: @unchecked Sendable {
    static let shared = FreezeWatchdog()

    // Construction installs no monitor or observers; those remain main-actor
    // lifecycle operations. Any-thread diagnostic pushes may first touch shared.
    private nonisolated init() {}

    /// `.userInteractive` for scheduling fidelity, not for speed: a background
    /// -QoS timer competing with a busy main thread is exactly the thing whose
    /// own lateness would be misread as the freeze it is trying to measure.
    private let queue = DispatchQueue(label: "com.swiftpili.freeze-watchdog", qos: .userInteractive)
    private static let tickInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var signals = FreezeBoard()

    /// The display heartbeat lives OUTSIDE `lock`, in its own unfair lock.
    /// Its writer is the CADisplayLink tick — on the main thread, up to 120
    /// times a second — and `lock` is also taken per emitted log line, which
    /// during a capture is the busiest path in the app. Sharing one lock
    /// between those two would put main-thread frame work behind a background
    /// logger's contention, which is the exact class of stall this file exists
    /// to measure. Zero = the link has never run, which must render as `n/a`
    /// and never as "stale".
    private let displayTick = OSAllocatedUnfairLock(initialState: TimeInterval(0))

    /// Read from every push helper on arbitrary threads; written once by
    /// `start()`. A torn `Bool` read is harmless — same contract as
    /// `PlayerLog.isEnabled`.
    private nonisolated(unsafe) static var isArmed = false

    // Watchdog-queue-only state. No lock: only `tick` and `start`'s first hop
    // touch these, both on `queue`.
    private var running = false
    private var runID: UUID?
    private var runAccess: ExperimentalAccessReceipt?
    @MainActor private var monitorAccess: ExperimentalAccessReceipt?
    @MainActor private var launchCollectionRequested = false
    @MainActor private var observers: [NSObjectProtocol] = []
    /// Uptime at which the outstanding acknowledgement token was posted; nil =
    /// none in flight. Doubles as the token's identity — the reply compares the
    /// value it captured against this, so a token voided by the inactive path
    /// (which does not bump `epoch`) cannot have its late reply attributed to
    /// whatever token was posted next.
    private var pendingSince: TimeInterval?
    /// Bumped whenever a measurement must be abandoned rather than believed:
    /// app deactivation, reactivation, or a stop. An acknowledgement from a
    /// superseded epoch is discarded instead of being reported as a multi-
    /// second freeze that was really a suspension.
    private var epoch: UInt64 = 0
    /// The episode currently being reported, if any.
    private var episode: Episode?
    /// Last `[Freeze] hold` emission, so the progression stays 1/s.
    private var lastHoldAt: TimeInterval = 0
    /// Edge state for the two verdicts that do not involve a stalled ack —
    /// they are steady-state conditions and must be edge-triggered or they
    /// would emit ten lines a second.
    private var standingVerdict: FreezeVerdict?

    private struct Episode {
        let verdict: FreezeVerdict
        /// Uptime the acknowledgement was posted, i.e. when the freeze started
        /// — not when it was detected.
        let beganAt: TimeInterval
        /// Whether a durable marker was written, so recovery knows to clear it.
        var persisted: Bool
        var peakAge: TimeInterval
        /// The begin snapshot, retained for the durable entry written when the
        /// episode ends. A few KB for the duration of one freeze.
        var snapshot: String
    }

    // MARK: - Pushes (any thread)

    /// One relaxed `Bool` read when the watchdog is not armed.
    static func noteDisplayTick(at uptime: TimeInterval) {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        shared.displayTick.withLock { $0 = uptime }
    }

    /// 1Hz from the player's own sampler. Cheap by construction: the caller
    /// already holds every value, and the only work here is the lock plus the
    /// movement comparison.
    static func notePlayer(_ sample: FreezePlayerSample) {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        shared.lock.lock()
        defer { shared.lock.unlock() }
        guard var existing = shared.signals.player,
              existing.sample.streamID == sample.streamID
        else {
            shared.signals.player = FreezePlayerSignals(first: sample, at: now)
            return
        }
        existing.absorb(sample, at: now)
        shared.signals.player = existing
    }

    /// Clears the player signals when no stream is loaded, so a stale snapshot
    /// from the last video cannot be reported as a starved current one.
    static func clearPlayer() {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        shared.lock.lock()
        shared.signals.player = nil
        shared.lock.unlock()
    }

    static func noteScreen(_ name: String) {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        shared.lock.lock()
        shared.signals.screen = (name, now)
        shared.lock.unlock()
    }

    /// Tap on the log path, for "what was the app doing immediately before this
    /// froze". Two records: the last line unconditionally (free — the string is
    /// already built), and the last line matching a small closed set of supply /
    /// transport / recovery markers, which is what a freeze actually has to be
    /// correlated against.
    ///
    /// Called from inside `PlayerLog`, so it must never log: that would recurse
    /// through this same tap.
    static func noteLogLine(_ line: String) {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        // Our own output would otherwise become its own "last event".
        guard !line.hasPrefix("[Freeze]"), !line.hasPrefix("⚠️ [Freeze]") else { return }
        let notable = Self.notableNeedles.contains { line.contains($0) }
        let now = ProcessInfo.processInfo.systemUptime
        shared.lock.lock()
        shared.signals.lastLine = (line, now)
        if notable { shared.signals.lastNotable = (line, now) }
        shared.lock.unlock()
    }

    /// Deliberately tiny and prefix-shaped: this runs per emitted log line
    /// while a capture is active, so it is a handful of short substring scans,
    /// not a pattern match. Supply (`[pace]`, `mdat`), pacing (`[gap]`),
    /// transport (`reopen`, `CDN switch`), and the recovery ladder.
    private static let notableNeedles = [
        "[pace]", "[gap]", "[pipe]", "mdat", "reopen", "🔁", "CDN", "recover", "stalled",
    ]

    // MARK: - Tick

    private func tick(runID id: UUID) {
        guard running, runID == id, runAccess?.isValid == true,
              ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let inactive = signals.inactiveSince != nil
        let graceUntil = signals.graceUntil
        let player = signals.player
        lock.unlock()
        let displayTickAt = displayTick.withLock { $0 }

        defer { rearm(runID: id) }

        guard !inactive else {
            pendingSince = nil
            standingVerdict = nil
            return
        }

        // Age the outstanding token, or post a fresh one. Exactly one is in
        // flight at a time — see the class comment.
        let ackAge: TimeInterval
        if let pendingSince {
            ackAge = max(0, now - pendingSince)
        } else {
            ackAge = 0
            postAcknowledgement(at: now)
        }

        let displayAge: TimeInterval? = displayTickAt > 0 ? max(0, now - displayTickAt) : nil
        let clockAge = Self.clockAge(player, now: now)
        let verdict = FreezeClassifier.classify(
            ackAge: ackAge,
            displayAge: displayAge,
            clockAge: clockAge
        )

        guard now >= graceUntil else { return }

        guard let verdict else {
            closeEpisodeIfOpen(recoveredAt: now)
            standingVerdict = nil
            return
        }

        let context = Context(
            now: now,
            ackAge: ackAge,
            displayAge: displayAge,
            clockAge: clockAge,
            player: player
        )

        guard runAccess?.isValid == true else { return }
        switch verdict {
        case .mainThreadFreeze, .mainQueueStarvation:
            openOrHoldEpisode(verdict, context: context)
        case .displayStall, .playerStarvation:
            // Steady-state conditions with no acknowledgement to recover:
            // edge-triggered once, no progression, no marker. They are the
            // "this is NOT an app freeze" half of the instrument.
            if standingVerdict != verdict {
                standingVerdict = verdict
                PlayerLog.diagnostic(
                    "[Freeze] not-an-app-freeze verdict=\(verdict.label) — \(verdict.meaning)\n" +
                        render(context: context, verdict: verdict)
                )
            }
        }
    }

    private func rearm(runID id: UUID) {
        queue.asyncAfter(deadline: .now() + Self.tickInterval) { [weak self] in
            self?.tick(runID: id)
        }
    }

    /// The heartbeat. `async`, never `sync` — a `sync` here would block the
    /// watchdog on the very thread it is measuring, which is the one mistake
    /// that turns a monitor into the outage.
    private func postAcknowledgement(at now: TimeInterval) {
        guard let id = runID, let access = runAccess, access.isValid else { return }
        let sentEpoch = epoch
        let sentAt = now
        pendingSince = sentAt
        DispatchQueue.main.async { [weak self] in
            guard let self, access.isValid else { return }
            let ackedAt = ProcessInfo.processInfo.systemUptime
            self.queue.async {
                guard self.running, self.runID == id, access.isValid,
                      self.epoch == sentEpoch, self.pendingSince == sentAt else { return }
                self.lock.lock()
                self.signals.mainAckAt = ackedAt
                self.lock.unlock()
                self.pendingSince = nil
                self.reportAcknowledgement(latency: max(0, ackedAt - sentAt))
            }
        }
    }

    // MARK: - Episodes

    private struct Context {
        let now: TimeInterval
        let ackAge: TimeInterval
        let displayAge: TimeInterval?
        let clockAge: TimeInterval?
        let player: FreezePlayerSignals?
    }

    private func openOrHoldEpisode(_ verdict: FreezeVerdict, context: Context) {
        guard runAccess?.isValid == true else { return }
        guard var current = episode else {
            let debugger = Self.isDebuggerAttached()
            var opened = Episode(
                verdict: verdict,
                beganAt: context.now - context.ackAge,
                persisted: false,
                peakAge: context.ackAge,
                snapshot: ""
            )
            var header = "[Freeze] begin verdict=\(verdict.label) " +
                "class=\(FreezeClassifier.severity(ackAge: context.ackAge)) " +
                "age=\(Self.ms(context.ackAge))"
            if debugger { header += " debugger=attached" }
            header += "\n  → \(verdict.meaning)"
            let body = render(context: context, verdict: verdict)
            let snapshot = header + "\n" + body
            opened.snapshot = snapshot
            PlayerLog.diagnostic(snapshot)

            // Disk, only for the tier that earns it, and only when the reading
            // is trustworthy. A breakpoint pause under the debugger is
            // indistinguishable from a hang by duration alone, and filling the
            // durable store with paused-at-breakpoint entries would make the
            // one real orphan impossible to find.
            if context.ackAge >= FreezeClassifier.freezeSeconds {
                if debugger, context.ackAge >= 5 {
                    PlayerLog.diagnostic(
                        "[Freeze] marker suppressed: suspect=debugger-pause " +
                            "(attached, age \(Self.ms(context.ackAge)) — not persisted)"
                    )
                } else {
                    FreezeMarkerStore.shared.write(FreezeMarkerStore.Marker(
                        beganAt: Date(),
                        beganAtUptime: context.now,
                        ageAtWriteMilliseconds: Int(context.ackAge * 1000),
                        snapshot: PlayerLog.redact(snapshot)
                    ))
                    opened.persisted = true
                }
            }
            episode = opened
            lastHoldAt = context.now
            // The snapshot above says WHERE and WHAT ELSE; this says what the
            // main thread is actually executing. Requested, not taken: the
            // sampler owns its own queue precisely so the signal round-trip
            // cannot block this tick chain, whose scheduling fidelity is the
            // basis of every age printed above.
            FreezeStackSampler.beginEpisode(access: runAccess)
            FreezeStackSampler.requestSample(
                reason: "begin",
                verdict: verdict.label,
                ackAge: context.ackAge,
                escalated: context.ackAge >= FreezeClassifier.freezeSeconds,
                access: runAccess
            )
            return
        }

        current.peakAge = max(current.peakAge, context.ackAge)
        // Escalate a stall that grew into a freeze: the marker was not written
        // at open time because it had not earned one yet.
        if !current.persisted, context.ackAge >= FreezeClassifier.freezeSeconds {
            let debugger = Self.isDebuggerAttached()
            if !(debugger && context.ackAge >= 5) {
                let snapshot = "[Freeze] escalated to freeze verdict=" +
                    "\(current.verdict.label)\n" + render(context: context, verdict: current.verdict)
                FreezeMarkerStore.shared.write(FreezeMarkerStore.Marker(
                    beganAt: Date(),
                    beganAtUptime: context.now,
                    ageAtWriteMilliseconds: Int(context.ackAge * 1000),
                    snapshot: PlayerLog.redact(snapshot)
                ))
                current.persisted = true
                current.snapshot = snapshot
            }
        }
        episode = current

        // One progression line per second. This is the payload the "begin"
        // snapshot cannot carry: whether the display, the clock and the CPU
        // kept moving WHILE the main queue was stuck, which is what separates
        // the four verdicts after the fact.
        if context.now - lastHoldAt >= 1.0 {
            lastHoldAt = context.now
            // Escalation: a stall that grew past `freezeSeconds` is the tier the
            // user actually sees, and its first request bypasses the sampler's
            // interval limiter so that tier always has a stack even when the
            // 500ms one was rate-limited away.
            FreezeStackSampler.requestSample(
                reason: "hold",
                verdict: current.verdict.label,
                ackAge: context.ackAge,
                escalated: context.ackAge >= FreezeClassifier.freezeSeconds,
                access: runAccess
            )
            PlayerLog.log(
                "[Freeze] hold age=\(Self.ms(context.ackAge)) " +
                    "verdict=\(current.verdict.label) " +
                    "main=\(Self.age(context.ackAge)) " +
                    "disp=\(Self.optionalAge(context.displayAge)) " +
                    "clock=\(Self.optionalAge(context.clockAge)) " +
                    Self.systemLine()
            )
        }
    }

    /// Backstop close. The normal end of a main-thread episode is the
    /// acknowledgement landing (`reportAcknowledgement`, which has the exact
    /// latency). This covers an episode left open by any path that cleared the
    /// condition without a reply — a grace window opening mid-episode, say — so
    /// a leaked episode cannot suppress the NEXT freeze's `begin`.
    private func closeEpisodeIfOpen(recoveredAt now: TimeInterval) {
        guard let current = episode else { return }
        episode = nil
        let line = "[Freeze] end verdict=\(current.verdict.label) " +
            "duration=\(Self.ms(now - current.beganAt)) " +
            "peak=\(Self.ms(current.peakAge)) (condition cleared)"
        PlayerLog.diagnostic(line)
        archive(current, endLine: line)
    }

    /// A freeze that RECOVERED must leave something durable too. Without this
    /// the only trace of it is the `PlaybackDebugRecorder` ring, which needs the
    /// Playback Report toggle to have already been on when the app locked up —
    /// and the freeze nobody expected is exactly the one nobody had armed a
    /// capture for. So the marker's contents are moved into the durable store
    /// instead of just being deleted, and `HangReportView` shows freezes with no
    /// toggle and no MetricKit payload.
    ///
    /// Only the freeze tier reaches here (`persisted` is set nowhere else): a
    /// run of 600ms stalls must not evict real hang reports from that bounded
    /// store.
    private func archive(_ episode: Episode, endLine: String) {
        guard episode.persisted else { return }
        let text = PlayerLog.redact(episode.snapshot + "\n" + endLine)
        // After recovery, so the disk work is nobody's critical path. Off the
        // `.userInteractive` queue all the same — this is archiving, and the
        // tick chain's priority is for scheduling fidelity, not for IO.
        DispatchQueue.global(qos: .utility).async {
            HangReportStore.shared.append(text: text)
            // Ordered: the marker is only released once its contents are
            // somewhere else. A crash between the two promotes the orphan on
            // the next launch — a duplicate entry, which is strictly better
            // than losing the event.
            FreezeMarkerStore.shared.clear()
        }
    }

    /// The main thread answered. This is also where the old
    /// `MainThreadStallMonitor` line is preserved — same threshold, same
    /// wording — so nothing that used to be reported stopped being reported.
    private func reportAcknowledgement(latency: TimeInterval) {
        guard runAccess?.isValid == true else { return }
        if let current = episode {
            episode = nil
            standingVerdict = nil
            var line = "[Freeze] end verdict=\(current.verdict.label) " +
                "duration=\(Self.ms(latency)) " +
                "class=\(FreezeClassifier.severity(ackAge: current.peakAge))"
            if latency >= FreezeClassifier.implausibleSeconds {
                line += " suspect=implausible (a recovery this late is more " +
                    "likely a suspension than a hang)"
            }
            PlayerLog.diagnostic(line)
            archive(current, endLine: line)
        }

        guard latency > 0.12 else { return }
        let milliseconds = Int(latency * 1000)
        let detail = "[Hang] main thread stalled \(milliseconds)ms (keyboard=\(Self.keyboardState))"
        if latency >= 1.0 {
            PlayerLog.diagnostic(detail)
        } else {
            PlayerLog.log(detail)
        }
        FullscreenTransitionDiagnostics.recordMainThreadStall(
            milliseconds: milliseconds,
            keyboardState: Self.keyboardState
        )
    }

    // MARK: - Orphan recovery

    private func recoverOrphanedFreeze() {
        guard let text = FreezeMarkerStore.shared.promoteOrphan() else { return }
        PlayerLog.diagnostic(
            "[Freeze] recovered an unterminated freeze from the previous run " +
                "— promoted to the durable report store\n" + text
        )
    }

    // MARK: - Rendering

    private func render(context: Context, verdict: FreezeVerdict) -> String {
        lock.lock()
        let signals = self.signals
        lock.unlock()

        var out = "  main: ack \(Self.age(context.ackAge)) late"
        let sinceAck = signals.mainAckAt > 0 ? context.now - signals.mainAckAt : nil
        out += ", last ack \(Self.optionalAge(sinceAck))"
        out += "\n  display: heartbeat \(Self.optionalAge(context.displayAge))"
        if context.displayAge == nil {
            out += " (display link not running — no owner)"
        }
        let screen = signals.screen
            .map { "\($0.name) (noted \(Self.age(context.now - $0.at)))" } ?? "unknown"
        out += "\n  screen: \(screen)"
        // Which image-pipeline A/B arms were active. A freeze report that cannot
        // say which configuration produced it is not comparable with the next
        // one, and bisecting the arms is the whole reason they exist.
        out += "\n  arms: \(ImagePipelinePolicy.activeArmSummary)"
        out += "\n  " + Self.systemLine()

        if let player = signals.player {
            let sample = player.sample
            out += "\n  player: \(sample.mode)/\(sample.engine) \(sample.state)"
            out += " observed \(Self.age(context.now - player.observedAt))"
            out += "\n    mediaTime=\(Self.seconds(sample.mediaTime))"
            out += " moved \(Self.age(context.now - player.mediaTimeMovedAt))"
            out += " clock=\(sample.clockSource)"
            out += "\n    renderedVideoPTS≈displayTime=\(Self.seconds(sample.displayTime))"
            out += " moved \(Self.age(context.now - player.displayTimeMovedAt))"
            out += " fps=\(String(format: "%.1f", sample.fps))"
            out += " last≥1fps \(Self.age(context.now - player.fpsLiveAt))"
            // Named explicitly rather than left to be inferred from `clock=`.
            // On Demand the media clock IS the drained-audio clock and its only
            // writer; on libVLC there is no separate audio clock to report, and
            // printing mediaTime under that name would be a fabrication.
            out += "\n    audioClock=" + (
                sample.clockSource == "audio-drain"
                    ? "\(Self.seconds(sample.mediaTime)) (= mediaTime; drained-audio is its single writer)"
                    : "n/a (libVLC owns A/V sync internally — no audio clock is exposed)"
            )
            // runway nil = unmeasured, never zero (see PlaybackStats.bufferHealth).
            let runway = sample.runway
                .map { "+\(Self.seconds($0))" } ?? "n/a (unmeasured on libVLC — not zero)"
            let videoRunway = sample.videoRunway
                .map { "+\(Self.seconds($0))" } ?? "n/a"
            out += "\n    buffered: runway=\(runway) video=\(videoRunway)"
            out += " availability=\(Self.seconds(sample.available))"
            out += " net=\(sample.networkKBs)KB/s gp=\(sample.goodputKBs)KB/s"
            out += " q=\(sample.quality) host=\(sample.host)"
            out += "\n    rec[\(sample.recovery)]"
            out += " expectsProgress=\(sample.expectsProgress)"
        } else {
            out += "\n  player: no stream loaded"
        }

        // Packet-queue depths are not re-read here: they live inside the
        // engine on the main actor, which is the one place this queue must not
        // reach. The 1Hz `[PathA][pipe]` line already carries them into the
        // ring, and the marker below names the last one with its age.
        if let notable = signals.lastNotable {
            out += "\n  last event (\(Self.age(context.now - notable.at))): \(notable.text)"
        } else {
            out += "\n  last event: none captured (enable Playback Report or Debug Logging)"
        }
        if let last = signals.lastLine, last.text != signals.lastNotable?.text {
            out += "\n  last line  (\(Self.age(context.now - last.at))): \(last.text)"
        }
        out += "\n  → \(verdict.meaning)"
        return out
    }

    /// CPU / footprint / thermal, read off-main. Reuses `PowerProfiler`'s Mach
    /// walk rather than carrying a second copy.
    ///
    /// Each thread now prints as `name:cpu%/runState`, and both halves of that
    /// were added because their absence produced unreadable field reports. The
    /// name is `main` by Mach PORT identity rather than by pthread name — the
    /// main thread had no name at all until `MainThreadIdentity.adopt()` gave it
    /// one, so every archived report reads `threads[unnamed:99%]` and leaves the
    /// reader to guess which thread that was. The run state separates the two
    /// readings a CPU column cannot: `running` at 99% is a computation,
    /// `waiting` at 99% is a blocked thread with an accounting artefact.
    ///
    /// The FRAMES are `FreezeStackSampler`'s job; this line says who, that one
    /// says what.
    private static func systemLine() -> String {
        let sample = PowerProfiler.sampleSystem()
        var out = "cpu=\(String(format: "%.0f", sample.cpuPercent))%"
        if !sample.topThreads.isEmpty {
            out += " threads[" + sample.topThreads
                .map(\.label)
                .joined(separator: " ") + "]"
        }
        out += " mem=\(sample.footprintMB)MB"
        out += " thermal=\(PowerProfiler.thermalLabel)"
        out += " lowPower=\(PowerProfiler.lowPowerLabel)"
        return out
    }

    /// Whether a debugger is attached RIGHT NOW — checked at classification
    /// time rather than cached at launch, because Xcode can attach mid-run and
    /// a breakpoint pause looks exactly like a multi-second hang. `sysctl` is
    /// safe from any thread and costs nothing at this rate.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Keyboard presentation state, carried over from `MainThreadStallMonitor`:
    /// keyboard bring-up is one of the few main-thread costs big enough to show
    /// up as a stall on its own, and a stall line without it invites the wrong
    /// investigation. Observed on the main queue, read from the watchdog queue —
    /// a torn `String` reference is not possible for an enum-like constant.
    private nonisolated(unsafe) static var keyboardStateStorage = "hidden"
    private static let keyboardLock = NSLock()

    static var keyboardState: String {
        keyboardLock.lock()
        defer { keyboardLock.unlock() }
        return keyboardStateStorage
    }

    static func noteKeyboardState(_ state: String) {
        keyboardLock.lock()
        keyboardStateStorage = state
        keyboardLock.unlock()
    }

    // MARK: - Formatting

    /// Internal, not private: the two gates below are the subtle part of the
    /// starvation verdict and are pinned by `FreezeWatchdogTests`.
    static func clockAge(_ player: FreezePlayerSignals?, now: TimeInterval) -> TimeInterval? {
        guard let player else { return nil }
        // Only a player that BELIEVES it is advancing can be starved, and only
        // a fresh observation can be trusted: a stale snapshot's ages grow on
        // their own and would eventually report every paused player as starved.
        guard player.sample.expectsProgress,
              now - player.observedAt < Self.staleObservationSeconds
        else { return nil }
        return max(0, now - player.mediaTimeMovedAt)
    }

    /// A snapshot older than this casts no vote. The producer runs at 1Hz, so
    /// 2.5s tolerates one missed push; beyond that the ages inside the snapshot
    /// are growing on their own, and believing them would eventually report
    /// every torn-down player as a starved one.
    static let staleObservationSeconds: TimeInterval = 2.5

    private static func ms(_ seconds: TimeInterval) -> String {
        "\(Int(seconds * 1000))ms"
    }

    private static func age(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int(seconds * 1000))ms" : String(format: "%.1fs", seconds)
    }

    private static func optionalAge(_ seconds: TimeInterval?) -> String {
        seconds.map { age($0) } ?? "n/a"
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1fs", value)
    }
}

extension FreezeWatchdog {
    // MARK: - Lifecycle

    @MainActor
    func applyExperimentalPolicy() {
        if launchCollectionRequested, ExperimentalSettingsPolicy.isAllowed(.diagnostics) {
            startMonitoring()
        } else {
            stop()
        }
    }

    /// One main-actor monitor lease and one queue-owned tick chain per grant.
    @MainActor
    func start() {
        launchCollectionRequested = true
        applyExperimentalPolicy()
    }

    @MainActor
    private func startMonitoring() {
        #if DEBUG
        guard monitorAccess == nil,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        monitorAccess = access
        let id = UUID()
        Self.isArmed = true
        queue.async { [weak self] in
            guard let self, access.isValid else { return }
            self.running = true
            self.runID = id
            self.runAccess = access
            self.epoch &+= 1
            self.pendingSince = nil
            self.episode = nil
            self.standingVerdict = nil
            self.lock.lock()
            self.signals.inactiveSince = ProcessInfo.processInfo.systemUptime
            self.lock.unlock()
        }
        UIHitchMonitor.shared.addOwner(.freezeWatchdog)
        observeActivity(access: access)
        observeKeyboard(access: access)
        // Existing durable evidence is independent of starting new sampling.
        DispatchQueue.global(qos: .utility).async { self.recoverOrphanedFreeze() }
        queue.async { [weak self] in self?.tick(runID: id) }
        #endif
    }

    @MainActor
    private func stop() {
        guard let retired = monitorAccess else { return }
        monitorAccess = nil
        Self.isArmed = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        UIHitchMonitor.shared.removeOwner(.freezeWatchdog)
        queue.async { [weak self] in
            guard let self, self.runAccess == retired else { return }
            self.running = false
            self.runID = nil
            self.runAccess = nil
            self.epoch &+= 1
            self.pendingSince = nil
            self.standingVerdict = nil
            if let episode = self.episode {
                self.episode = nil
                self.archive(episode, endLine: "[Freeze] end duration=unknown (diagnostic permission retired)")
            }
        }
    }

    /// Carried over from `MainThreadStallMonitor`. Keyboard bring-up is one of
    /// the few main-thread costs large enough to show up as a stall on its own,
    /// and a stall line without it invites the wrong investigation.
    @MainActor
    private func observeKeyboard(access: ExperimentalAccessReceipt) {
        let center = NotificationCenter.default
        let states: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "presenting"),
            (UIResponder.keyboardDidShowNotification, "visible"),
            (UIResponder.keyboardWillHideNotification, "dismissing"),
            (UIResponder.keyboardDidHideNotification, "hidden"),
        ]
        for (name, state) in states {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                guard access.isValid else { return }
                Self.noteKeyboardState(state)
                // Kept from the old monitor: the show edges were logged so a
                // stall landing on one could be attributed without guessing.
                if state == "presenting" || state == "visible" {
                    PlayerLog.log("[Hang] keyboard \(state)")
                }
            })
        }
    }

    /// Active ⇔ measuring. Anything else — backgrounded, or merely inactive
    /// behind Control Center, an incoming call, or the app switcher — means the
    /// main thread may legitimately not be scheduled and our own queue is
    /// suspended alongside it, so an acknowledgement spanning that stretch
    /// measures the suspension and not a freeze.
    @MainActor
    private func observeActivity(access: ExperimentalAccessReceipt) {
        let center = NotificationCenter.default
        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setActive(false, access: access)
            })
        }
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setActive(true, access: access)
        })
        // Cover a launch that is already active by the time we registered.
        if UIApplication.shared.applicationState == .active {
            setActive(true, access: access)
        } else {
            setActive(false, access: access)
        }
    }

    private func setActive(_ active: Bool, access: ExperimentalAccessReceipt) {
        queue.async { [weak self] in
            guard let self, self.running, self.runAccess == access, access.isValid else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            self.signals.inactiveSince = active ? nil : now
            self.signals.graceUntil = now + 2.0
            self.lock.unlock()
            self.epoch &+= 1
            self.pendingSince = nil
            self.standingVerdict = nil
            if let episode = self.episode {
                self.episode = nil
                let line = "[Freeze] end verdict=\(episode.verdict.label) " +
                    "duration=unknown peak=\(Self.ms(episode.peakAge)) " +
                    "(app became \(active ? "active" : "inactive") mid-episode — " +
                    "measurement abandoned, not a recovery)"
                guard access.isValid else { return }
                PlayerLog.diagnostic(line)
                self.archive(episode, endLine: line)
            }
        }
    }

}

// MARK: - Screen provenance

extension View {
    /// Names the screen for any freeze reported while it is on top.
    ///
    /// A freeze report that cannot say WHERE the app was is most of the way to
    /// useless: "the UI locked up" plus a call stack still leaves which list was
    /// scrolling, which player was mounted, which sheet was presented. The
    /// watchdog cannot read that itself — the SwiftUI environment only exists
    /// inside a body, on the actor that is frozen — so screens push it.
    ///
    /// A last-noted name with its age, not a stack: coarse on purpose. It is
    /// extended by adding calls, and it never claims more precision than that —
    /// the report prints how long ago the name was noted so a reader can judge
    /// it. Cheap: two closures, and each fires once per appearance.
    func freezeWatchdogScreen(_ name: String) -> some View {
        onAppear { FreezeWatchdog.noteScreen(name) }
            .onDisappear { FreezeWatchdog.noteScreen("\(name)/left") }
    }
}
