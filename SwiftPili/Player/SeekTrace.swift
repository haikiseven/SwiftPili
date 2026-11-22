import Foundation
import QuartzCore

/// Wall-clock milestones for ONE seek — the "why did that scrub take so long to
/// land" trace, and the deliberate twin of `StartupTrace`. A session is a single
/// reopen-at-target: `begin` stamps T0 with the position arithmetic, each `mark`
/// records the wall time of a milestone on the way to the target, and the
/// session closes when the real clock reaches it (`arrived`) or at an explicit
/// abort. Nothing here measures steady-state playback, and nothing here is a
/// rate or an average — every number is one observation from one seek.
///
/// **A seek on this backend is a demuxer REOPEN** (design doc F13, §2.3), so the
/// milestones are deliberately the same labels the startup trace uses:
/// `vlc-open-started` → `vlc-opening` → `first-buffering-progress` →
/// `ready-to-play` → `first-vout` → `first-tick`. Reading the two traces side by
/// side is the point — a seek that costs as much as a cold start costs it in the
/// same places, and the `[Seek]` / `[Startup]` prefixes keep the sessions apart.
///
/// **`arrived` is the settle, not the first picture.** It fires when the real
/// clock reaches the target, which is the moment the player stops treating the
/// seek as in flight (unpins the progress bar, unmutes, re-arms the fault
/// detectors). The visible frame lands earlier, somewhere after `first-vout`.
/// The split that matters is printed with it: `first-tick` is where the reopened
/// stream's clock first spoke, so `run-up` is how long the clock then took to
/// crawl from its landing position to the target — the cost of libVLC landing on
/// a fragment boundary short of the ask, which is a different problem from a slow
/// open and must not be read as one.
///
/// **Only a reopen-for-seek begins a session.** A resume open — watch history, a
/// quality switch, a CDN switch — is `:start-time` too and enters the same
/// pending-seek state in the backend, but it is not a seek the user asked for and
/// belongs to `StartupTrace`. Marks are **no-ops when no session is open**, which
/// is what lets the backend hooks be installed unconditionally beside the startup
/// ones: they cost nothing on every load that is not a seek.
///
/// A scrub is a burst of seeks, each superseding the last. `begin` reports the
/// abandoned session instead of dropping it, so coalescing is measurable rather
/// than invisible.
///
/// Everything is emitted through `PlayerLog.log`, so this whole subsystem
/// inherits the Settings → Playback → Debug Logging gate and costs nothing when
/// diagnostics are off. Only closed labels, positions and small integers are
/// logged — never URLs, tokens, or queries.
@MainActor
enum SeekTrace {
    /// Completing this mark ends the session (see the settle caveat above).
    private static let completionLabel = "arrived"
    /// Recorded separately from `seen` because its wall time is the `run-up`
    /// split's origin.
    private static let firstTickLabel = "first-tick"

    private static var sessionID: UInt64 = 0
    private static var t0: CFTimeInterval = 0
    private static var lastMarkAt: CFTimeInterval = 0
    /// Wall time of `first-tick`, 0 when the reopened stream has not ticked yet.
    private static var firstTickAt: CFTimeInterval = 0
    /// Wall time of the clock settle (`arrived`), 0 until it happens. A session
    /// with `settledAt > 0` is in its EPILOGUE: the clock has arrived but the
    /// visible-frame proxy has not fired yet — `visible` routinely lands AFTER
    /// settle (the vout's A/V-gap deferral holds pictures past the first tick),
    /// so the session stays open for it and the summary fires once, complete.
    private static var settledAt: CFTimeInterval = 0
    private static var settleMs: Int = 0
    private static var settleRunUpMs: Int?
    /// Wall time of the visible-frame proxy, 0 until it fires.
    private static var visibleAt: CFTimeInterval = 0
    private static var target: TimeInterval = 0
    private static var path: String = ""
    private static var seen: Set<String> = []
    private static var active = false

    /// One completed seek, for the on-screen debug counter. Everything here is
    /// also in the log; this exists so a device test does not need a tethered
    /// console.
    struct Timing: Equatable, Sendable {
        /// Which seek mechanism ran: "reopen" (demuxer reopen) / "set_time"
        /// (in-demuxer, the experiment) / "native" (non-VLC backends).
        let path: String
        let target: TimeInterval
        /// T0 → clock settle, ms.
        let settleMs: Int
        /// T0 → the visible-frame PROXY, ms: the first increment of libVLC's
        /// displayed-picture counter after the seek was issued. A rendered-
        /// output count from the engine, not a screen-refresh timestamp —
        /// sampled on the ~30Hz event cadence, and on the set_time path one
        /// already-in-flight pre-seek picture can mark it a frame early.
        /// nil when the session closed (next seek / teardown) before any
        /// picture was counted.
        let visibleMs: Int?
        /// first-tick → settle, ms — the clock's crawl from its landing
        /// position to the target. nil when the stream never ticked.
        let runUpMs: Int?
    }

    /// Fired on every COMPLETE (never on abort/supersede), after the log lines.
    /// Installed once by PlayerViewModel to feed the stats overlay.
    static var onComplete: (@MainActor (Timing) -> Void)?

    /// True while a session could still accept the visible-frame mark — the
    /// backend's probe disarms itself the moment this goes false, which is
    /// what scopes the probe (and its per-event `player.statistics` crossing)
    /// to the session it measures: a baseline left armed by a session that
    /// closed, or armed by a restore reopen that never opened one, dies on
    /// the first event instead of firing into the wrong session.
    static var wantsVisibleFrame: Bool {
        active && !seen.contains("visible-frame")
    }

    /// Open a new session and stamp T0. `target` is where the seek is going and
    /// `from` is the clock it left — both plain media positions, which is the
    /// only kind of value this trace ever prints.
    static func begin(target: TimeInterval, from current: TimeInterval, path: String = "reopen") {
        let now = CACurrentMediaTime()
        if active, settledAt > 0 {
            // Not a superseded seek — a COMPLETED one whose visible proxy
            // never fired; close it with its summary so it doesn't vanish.
            finishEpilogueWithoutVisible(closedBy: "next-seek")
        } else if active {
            PlayerLog.log(
                "[Seek] sid=\(sessionID) superseded at " +
                "+\(elapsedMilliseconds(from: t0, to: now))ms " +
                "(was heading for \(position(self.target)))"
            )
        }
        sessionID &+= 1
        t0 = now
        lastMarkAt = now
        firstTickAt = 0
        settledAt = 0
        settleMs = 0
        settleRunUpMs = nil
        visibleAt = 0
        self.target = target
        self.path = path
        seen.removeAll(keepingCapacity: true)
        active = true
        let jump = target - current
        PlayerLog.log(
            "[Seek] sid=\(sessionID) T0 path=\(path) target=\(position(target)) from=\(position(current)) " +
            "jump=\(signedPosition(jump))\(jump < 0 ? " BACKWARD" : "")"
        )
    }

    /// Record a milestone. No-op when no session is open, and each label is
    /// logged at most once per session — so a hook on a repeating event (buffer
    /// progress, vout changes) is free to fire on every one of them, and a load
    /// that reopens again mid-session (a CDN switch) cannot double-print.
    static func mark(_ label: String) {
        guard active else { return }
        // A settled session's epilogue is waiting for the visible proxy and
        // nothing else: an unrelated in-place reopen (CDN switch, recovery)
        // must not print its open marks into a session whose COMPLETE line
        // already went out.
        if settledAt > 0, label != completionLabel { return }
        guard seen.insert(label).inserted else { return }
        let now = CACurrentMediaTime()
        let total = elapsedMilliseconds(from: t0, to: now)
        let delta = elapsedMilliseconds(from: lastMarkAt, to: now)
        lastMarkAt = now
        PlayerLog.log("[Seek] sid=\(sessionID) \(label) +\(total)ms (Δ\(delta)ms)")
        guard label == completionLabel else { return }
        settledAt = now
        settleMs = total
        settleRunUpMs = firstTickAt > 0
            ? elapsedMilliseconds(from: firstTickAt, to: now)
            : nil
        PlayerLog.log(
            "[Seek] sid=\(sessionID) COMPLETE path=\(path) settle=\(total)ms " +
            "run-up=\(settleRunUpMs.map { "\($0)ms" } ?? "n/a")"
        )
        // Epilogue: the settle is the CLOCK's completion, not the picture's —
        // the session stays open until the visible-frame proxy fires (or the
        // next begin/abort/timeout closes it with visible=n/a), so the summary
        // carries both numbers. The native path has no probe at all, so it
        // finishes here — an epilogue nothing can ever close would only leak.
        if visibleAt > 0 || path == "native" { finish() }
    }

    /// The backend's probe hit its wall (armed too long — e.g. a settled seek
    /// backgrounded before any picture): close a settled epilogue with
    /// visible=n/a rather than keep it open indefinitely. No-op otherwise.
    static func visibleProbeTimedOut() {
        guard active, settledAt > 0 else { return }
        finishEpilogueWithoutVisible(closedBy: "probe-timeout")
    }

    /// The visible-frame PROXY: the backend calls this when libVLC's
    /// displayed-picture counter first increments after the seek was issued —
    /// a rendered-output count sampled on the event cadence, not a
    /// screen-refresh timestamp (and on the set_time path one in-flight
    /// pre-seek picture can fire it a frame early). No-op with no session.
    static func markVisibleFrame() {
        guard active, seen.insert("visible-frame").inserted else { return }
        let now = CACurrentMediaTime()
        visibleAt = now
        PlayerLog.log(
            "[Seek] sid=\(sessionID) visible-frame +\(elapsedMilliseconds(from: t0, to: now))ms"
        )
        if settledAt > 0 { finish() }
    }

    /// Both phases (clock settle + visible proxy) are in — emit the one
    /// summary and close.
    private static func finish() {
        let visibleMs = visibleAt > 0 ? elapsedMilliseconds(from: t0, to: visibleAt) : nil
        PlayerLog.log(
            "[Seek] sid=\(sessionID) SUMMARY path=\(path) clock=\(settleMs)ms " +
            "visible=\(visibleMs.map { "\($0)ms" } ?? "n/a") " +
            "run-up=\(settleRunUpMs.map { "\($0)ms" } ?? "n/a")"
        )
        active = false
        onComplete?(Timing(
            path: path, target: target,
            settleMs: settleMs, visibleMs: visibleMs, runUpMs: settleRunUpMs
        ))
    }

    /// A settled session whose visible proxy never fired, closed by the next
    /// seek or a teardown: the clock phase DID complete, so the summary still
    /// fires — with visible=n/a — instead of vanishing.
    private static func finishEpilogueWithoutVisible(closedBy reason: String) {
        guard active, settledAt > 0 else { return }
        PlayerLog.log("[Seek] sid=\(sessionID) visible never fired (closed by \(reason))")
        finish()
    }

    /// The reopened stream's first clock tick. `clock` is where it actually
    /// landed: `residual` is what the clock still has to cover to reach the
    /// target, so a large residual with a small `run-up` is a healthy catch-up
    /// and a large residual with a large `run-up` is the whole cost of the seek.
    static func markFirstTick(landedAt clock: TimeInterval) {
        guard active, settledAt == 0, seen.insert(firstTickLabel).inserted else { return }
        let now = CACurrentMediaTime()
        let total = elapsedMilliseconds(from: t0, to: now)
        let delta = elapsedMilliseconds(from: lastMarkAt, to: now)
        lastMarkAt = now
        firstTickAt = now
        PlayerLog.log(
            "[Seek] sid=\(sessionID) \(firstTickLabel) +\(total)ms (Δ\(delta)ms) " +
            "landed=\(position(clock)) residual=\(signedPosition(target - clock))"
        )
    }

    /// Close an open session that will never reach its target — the backend's
    /// seek-silence watchdog, or any teardown. `reason` is a short closed label.
    /// No-op when no session is open.
    static func abort(_ reason: String) {
        guard active else { return }
        // A settled session in its epilogue completed its clock phase — close
        // it with the summary (visible=n/a) rather than as an abort. A
        // pre-settle abort stays log-only, per the aborted-seeks contract.
        if settledAt > 0 {
            finishEpilogueWithoutVisible(closedBy: reason)
            return
        }
        PlayerLog.log(
            "[Seek] sid=\(sessionID) aborted (\(reason)) " +
            "at +\(elapsedMilliseconds(from: t0, to: CACurrentMediaTime()))ms"
        )
        active = false
    }

    private static func elapsedMilliseconds(from start: CFTimeInterval, to end: CFTimeInterval) -> Int {
        Int(((end - start) * 1000).rounded())
    }

    /// A media position, unit included, or `n/a` — an unset clock reads as NaN in
    /// a few places and "nan" in a trace line looks like a measurement. The unit
    /// lives in here so it is never glued onto the `n/a`.
    private static func position(_ t: TimeInterval) -> String {
        t.isFinite ? String(format: "%.1fs", t) : "n/a"
    }

    private static func signedPosition(_ t: TimeInterval) -> String {
        t.isFinite ? String(format: "%+.1fs", t) : "n/a"
    }
}
