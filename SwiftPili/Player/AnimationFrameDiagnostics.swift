import Foundation
import os
import QuartzCore

/// One animation's measurement window over `UIHitchMonitor`.
///
/// The 2 s `[hitch]` report is the wrong ruler for a control or page
/// transition: the cost lands inside a few hundred milliseconds, and a window
/// that does not line up with the gesture reads as zero. This helper opens a
/// caller-bounded interval instead — the same `bodyCountSnapshot` /
/// `beginFrameInterval` pair fullscreen transitions already use — and logs
/// `start`, `settle`, `cancel`, and `supersede` through `PlayerLog`.
///
/// Diagnostics off is a no-op. `PlayerLog.isCapturing` is read first, and
/// while it is false and nothing is open the call does not take the monitor
/// lock, does not snapshot body or frame counters, and does not build a log
/// line. Call it on the animation edge, never from a per-sample gesture.
///
/// Bound: at most one open interval per `Name`. A second `begin` supersedes
/// the open one instead of growing a table, so a stuck gesture cannot
/// accumulate intervals. Fullscreen stays on `FullscreenTransitionDiagnostics`;
/// this sink does not record it.
///
/// A missing meter is `n/a`, never a numeric zero. `bodyCountDelta`'s `-`
/// means the meter was armed and no counted body ran.
enum AnimationFrameDiagnostics {
    /// Closed labels. A name is a motion class, never content or a URL.
    enum Name: String, Sendable, Hashable {
        case microControl = "micro-control"
        case control
        case page
        case settle
        /// A player route's push: path write until the page's `didAppear`.
        case routeEnter = "route-enter"
        /// A player route leaving the top: path write until its `didDisappear`.
        case routeExit = "route-exit"
        /// Playback activation: `T0 playback-requested` until the first clock
        /// tick (or abort).
        case startup
        case settingsEnter = "settings-enter"
        case settingsExit = "settings-exit"
    }

    /// What the log line claims happened. `start` opens an interval; the
    /// other three close one.
    enum Outcome: String, Sendable {
        case start
        case settle
        case cancel
        case supersede
    }

    /// Open a measurement for `name`. An interval already open under that
    /// name is logged as `supersede` first. `nil` when diagnostics are off.
    @discardableResult
    static func begin(_ name: Name) -> UInt64? {
        guard PlayerLog.isCapturing else {
            discardAbandoned()
            return nil
        }
        let now = CACurrentMediaTime()
        let bodies = UIHitchMonitor.bodyCountSnapshot()
        let token = UIHitchMonitor.beginFrameInterval()
        let swap = state.withLock { state -> Swap in
            state.nextID &+= 1
            let opened = OpenInterval(
                id: state.nextID,
                name: name,
                startedAt: now,
                bodyCounts: bodies,
                frameToken: token,
                meterArmed: token != nil || !bodies.isEmpty
            )
            let previous = state.open.updateValue(opened, forKey: name)
            return Swap(opened: opened, previous: previous)
        }
        hasOpen = true
        if let previous = swap.previous {
            logClose(.supersede, previous, now: now, bodyCountsNow: bodies)
        }
        logStart(swap.opened)
        return swap.opened.id
    }

    /// Close the open interval as settled. `nil` when none is open or
    /// diagnostics are off.
    @discardableResult
    static func settle(_ name: Name) -> UInt64? {
        finish(name, outcome: .settle)
    }

    /// Close the open interval as cancelled.
    @discardableResult
    static func cancel(_ name: Name) -> UInt64? {
        finish(name, outcome: .cancel)
    }

    /// Close the open interval as superseded without opening a replacement.
    @discardableResult
    static func supersede(_ name: Name) -> UInt64? {
        finish(name, outcome: .supersede)
    }

    // MARK: - Close

    private static func finish(_ name: Name, outcome: Outcome) -> UInt64? {
        guard PlayerLog.isCapturing else {
            discardAbandoned()
            return nil
        }
        let removed = state.withLock { state -> Finish in
            let interval = state.open.removeValue(forKey: name)
            return Finish(interval: interval, stillOpen: !state.open.isEmpty)
        }
        hasOpen = removed.stillOpen
        guard let interval = removed.interval else { return nil }
        logClose(outcome, interval, now: CACurrentMediaTime(), bodyCountsNow: nil)
        return interval.id
    }

    /// Drop leftover intervals after the log gate turns off.
    ///
    /// The steady state (`hasOpen == false`) returns before any monitor call.
    /// A token left open from a capture that has since stopped is released
    /// and the `FrameInterval` value is discarded: reading it into a log is
    /// the work this path must not do, but leaving the token installed keeps
    /// every later hitch updating an interval nobody will read.
    private static func discardAbandoned() {
        guard hasOpen else { return }
        let tokens = state.withLock { state -> [Int] in
            let tokens = state.open.values.compactMap(\.frameToken)
            state.open.removeAll(keepingCapacity: true)
            return tokens
        }
        hasOpen = false
        for token in tokens {
            _ = UIHitchMonitor.endFrameInterval(token)
        }
    }

    // MARK: - Log

    private static func logStart(_ interval: OpenInterval) {
        let meter = interval.meterArmed ? "on" : "off"
        PlayerLog.log(
            "[Motion] outcome=start name=\(interval.name.rawValue) "
                + "id=\(interval.id) meter=\(meter)"
        )
    }

    private static func logClose(
        _ outcome: Outcome,
        _ interval: OpenInterval,
        now: CFTimeInterval,
        bodyCountsNow: [String: Int]?
    ) {
        let frame = endedFrame(interval.frameToken)
        let bodies = bodyField(interval, bodyCountsNow: bodyCountsNow)
        let elapsed = elapsedMilliseconds(from: interval.startedAt, to: now)
        PlayerLog.log(
            "[Motion] outcome=\(outcome.rawValue) "
                + "name=\(interval.name.rawValue) id=\(interval.id) "
                + "elapsed=\(elapsed)ms bodies=\(bodies) "
                + frameField(frame)
        )
    }

    private static func endedFrame(_ token: Int?) -> UIHitchMonitor.FrameInterval? {
        guard let token else { return nil }
        return UIHitchMonitor.endFrameInterval(token)
    }

    /// `n/a` when the opening snapshot was not a real baseline. An empty
    /// dictionary at close after a non-empty open means metering reset the
    /// totals underneath the interval; differencing that would print a
    /// negative that `bodyCountDelta` then hides.
    private static func bodyField(
        _ interval: OpenInterval,
        bodyCountsNow: [String: Int]?
    ) -> String {
        guard interval.meterArmed else { return "n/a" }
        let after = bodyCountsNow ?? UIHitchMonitor.bodyCountSnapshot()
        if after.isEmpty, !interval.bodyCounts.isEmpty { return "n/a" }
        return UIHitchMonitor.bodyCountDelta(from: interval.bodyCounts, to: after)
    }

    private static func frameField(_ frame: UIHitchMonitor.FrameInterval?) -> String {
        guard let frame else { return "frame=n/a" }
        return "frameMissed=\(frame.missed) frameStalls=\(frame.stalls) "
            + "frameWorst=\(frame.worstMilliseconds) "
            + "frameSpan=\(frame.spanMilliseconds) "
            + "frameBoundaryGaps=\(frame.boundaryGaps) frameMeter=callback-estimate-v2"
    }

    private static func elapsedMilliseconds(
        from start: CFTimeInterval,
        to end: CFTimeInterval
    ) -> Int {
        max(0, Int(((end - start) * 1000).rounded()))
    }

    // MARK: - State

    private struct OpenInterval: Sendable {
        let id: UInt64
        let name: Name
        let startedAt: CFTimeInterval
        let bodyCounts: [String: Int]
        let frameToken: Int?
        /// False when both the body snapshot and the frame token came back
        /// empty. Later totals must not be differenced against that hole.
        let meterArmed: Bool
    }

    private struct Swap: Sendable {
        let opened: OpenInterval
        let previous: OpenInterval?
    }

    private struct Finish: Sendable {
        let interval: OpenInterval?
        let stillOpen: Bool
    }

    private struct State: Sendable {
        var nextID: UInt64 = 0
        var open: [Name: OpenInterval] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Fast path for the log gate. Written only after the lock section that
    /// changed `open`, and read only to skip the monitor when nothing is
    /// armed. A torn `Bool` read is the same contract as `PlayerLog.isEnabled`:
    /// stale `true` takes the lock and finds an empty table; stale `false`
    /// lasts one call.
    nonisolated(unsafe) private static var hasOpen = false
}
