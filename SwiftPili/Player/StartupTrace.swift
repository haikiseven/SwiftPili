import Foundation
import QuartzCore

/// Wall-clock milestones for one UGC/PGC detail-screen cold first play.
/// `begin` stamps T0 on screen-initiated loads (never internal reloads);
/// `first-clock-tick` closes the session as a lower-bound proxy while
/// `lateBracketLabels` (`first-vout`, `first-picture-displayed`) record post-proxy
/// frame presentation evidence. Emits via `PlayerLog.log` with redacted closed labels.
@MainActor
enum StartupTrace {
    /// Opaque identity for one screen-initiated startup request. Every
    /// milestone carries this token so a delayed backend callback from an old
    /// request cannot stamp or complete the successor's trace.
    struct Token: Hashable, Sendable {
        fileprivate let id: UInt64

        var mediaEngineTraceID: MediaEngineTraceID { MediaEngineTraceID(rawValue: id) }
    }

    /// Pure request-identity policy used by the runtime and by focused tests.
    /// It deliberately knows nothing about clocks or logging: a request token
    /// may record only its own milestones, and a completed request retains one
    /// late `first-vout` bracket until a successor begins.
    struct SessionPolicy: Sendable {
        enum Decision: Equatable, Sendable {
            case ignored
            case recorded
            case completed
            /// A label the bracket accepts AFTER `first-clock-tick` has closed
            /// the session — the frame-side evidence that necessarily lands
            /// later than the clock-side proxy. See `lateBracketLabels`.
            case lateBracket
        }

        private(set) var nextID: UInt64 = 0
        private(set) var activeToken: Token?
        private(set) var completedToken: Token?
        private var seen: Set<String> = []

        mutating func begin() -> Token {
            nextID &+= 1
            let token = Token(id: nextID)
            activeToken = token
            completedToken = nil
            seen.removeAll(keepingCapacity: true)
            return token
        }

        /// Labels still accepted once the session has completed.
        ///
        /// `first-clock-tick` closes the session, and the clock is only a PROXY
        /// for the picture (see the type doc): the vout's own evidence lands
        /// after it. Dropping those marks is what left this trace unable to
        /// report a measured first frame at all.
        static let lateBracketLabels: Set<String> = ["first-vout", "first-picture-displayed"]

        mutating func mark(_ label: String, token: Token) -> Decision {
            guard token == activeToken else {
                guard token == completedToken,
                      Self.lateBracketLabels.contains(label),
                      seen.insert(label).inserted else { return .ignored }
                return .lateBracket
            }
            guard seen.insert(label).inserted else { return .ignored }
            guard label == StartupTrace.completionLabel else { return .recorded }
            activeToken = nil
            completedToken = token
            return .completed
        }

        mutating func abort(token: Token) -> Bool {
            guard token == activeToken else { return false }
            activeToken = nil
            completedToken = nil
            return true
        }

        func hasStreamingMark(for token: Token) -> Bool {
            token == activeToken && seen.contains(StartupTrace.streamOpenLabel)
        }

        mutating func abortIfStreaming(token: Token) -> Bool {
            guard hasStreamingMark(for: token) else { return false }
            return abort(token: token)
        }
    }

    /// Completing this mark ends the session.
    nonisolated private static let completionLabel = "first-clock-tick"
    /// Reaching this mark means a stream was actually opened, making a later teardown an abort.
    nonisolated private static let streamOpenLabel = "stream-open-requested"
    /// The measured first PRESENTED frame. On the libVLC backend this is the
    /// first increment of the vout's displayed-picture counter; a backend that
    /// cannot observe presentation must not emit this label rather than
    /// substituting readiness, a clock tick, or a decode.
    static let measuredFirstFrameLabel = "first-picture-displayed"

    private static var sessionID: UInt64 = 0
    private static var policy = SessionPolicy()
    private static var activeToken: Token?
    private static var t0: CFTimeInterval = 0
    private static var lastMarkAt: CFTimeInterval = 0
    private static var seen: Set<String> = []
    private static var active = false
    private static var completed = false

    /// Open a new session and stamp T0. `context` is a short closed label for
    /// the screen that asked for playback (e.g. "vod-detail") — never a title,
    /// URL, or any identifier beyond the aid/cid numbers already logged
    /// elsewhere. A previous session still open is reported as abandoned
    /// first, so a start that never reached a frame is never silently lost.
    @discardableResult
    static func begin(_ context: String) -> Token {
        let now = CACurrentMediaTime()
        if active {
            PlayerLog.log("[Startup] sid=\(sessionID) abandoned at +\(elapsedMilliseconds(from: t0, to: now))ms")
        }
        let token = policy.begin()
        sessionID = token.id
        activeToken = token
        t0 = now
        lastMarkAt = now
        seen.removeAll(keepingCapacity: true)
        active = true
        completed = false
        PlayerLog.log("[Startup] sid=\(sessionID) T0 playback-requested (\(context))")
        AnimationFrameDiagnostics.begin(.startup)
        return token
    }

    /// Record a milestone. No-op when no session is open, and each label is
    /// logged at most once per session — so a hook on a repeating event (buffer
    /// progress, clock ticks) is free to fire on every one of them.
    static func mark(_ label: String, token: Token?) {
        guard let token else { return }
        let decision = policy.mark(label, token: token)
        guard decision != .ignored else { return }
        let now = CACurrentMediaTime()
        let total = elapsedMilliseconds(from: t0, to: now)
        let delta = elapsedMilliseconds(from: lastMarkAt, to: now)
        lastMarkAt = now
        seen.insert(label)
        PlayerLog.log("[Startup] sid=\(sessionID) \(label) +\(total)ms (Δ\(delta)ms)")
        if decision == .lateBracket {
            PlayerLog.log("[Startup] sid=\(sessionID) late bracket \(label) closes at +\(total)ms")
        }
        // The one number the TTFF contract actually asks for: a PRESENTED
        // frame, not a clock tick, not readiness, not first audio. Logged
        // separately from COMPLETE because it can land on either side of it.
        if label == Self.measuredFirstFrameLabel {
            PlayerLog.log("[Startup] sid=\(sessionID) ttff-measured=\(total)ms (first presented frame)")
        }
        if decision == .completed {
            PlayerLog.log("[Startup] sid=\(sessionID) COMPLETE ttff-proxy=\(total)ms")
            active = false
            completed = true
            AnimationFrameDiagnostics.settle(.startup)
            onComplete?(total)
        }
    }

    /// Fired on every COMPLETE (never on abort/abandon), after the log line,
    /// with the ttff-proxy in ms. Installed once by PlayerViewModel to feed the
    /// stats overlay, so a device test does not need a tethered console. The
    /// proxy caveat above applies to the displayed number identically.
    static var onComplete: (@MainActor (Int) -> Void)?

    /// Close an open session that will never reach a first frame. `reason` is a
    /// short closed label. No-op when no session is open.
    static func abort(_ reason: String, token: Token?) {
        guard let token, active, policy.abort(token: token) else { return }
        PlayerLog.log("[Startup] sid=\(sessionID) aborted (\(reason)) at +\(elapsedMilliseconds(from: t0, to: CACurrentMediaTime()))ms")
        active = false
        completed = false
        AnimationFrameDiagnostics.cancel(.startup)
    }

    /// Abort ONLY a session that already opened a stream.
    ///
    /// `PlayerViewModel.stop()` runs inside `performLoadVOD`, i.e. *after* the
    /// screen has already called `begin` — an unconditional abort there would
    /// kill the very session the load is starting. The distinction that makes
    /// the call site honest is whether a stream was ever opened: before
    /// `stream-open-requested` a stop is the load's own preparatory teardown
    /// and the fresh session must survive it; after it, a stop is a real
    /// teardown of a start that was in flight, and the session ends here.
    static func abortIfStreaming(_ reason: String, token: Token?) {
        guard let token, active, policy.hasStreamingMark(for: token) else { return }
        abort(reason, token: token)
    }

    private static func elapsedMilliseconds(from start: CFTimeInterval, to end: CFTimeInterval) -> Int {
        Int(((end - start) * 1000).rounded())
    }
}

/// Stateless App bridge retaining StartupTrace's identity and milestone policy.
@MainActor
final class StartupTraceMediaEngineTracing: MediaEngineTracing {
    func mark(_ milestone: MediaEngineTraceMilestone, token: MediaEngineTraceID?) {
        StartupTrace.mark(milestone.rawValue, token: token.map { StartupTrace.Token(id: $0.rawValue) })
    }
}
