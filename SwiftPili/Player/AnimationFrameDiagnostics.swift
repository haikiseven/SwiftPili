import Foundation
import os
import QuartzCore

enum AnimationFrameDiagnostics {
    enum Name: String, Sendable, Hashable {
        case microControl = "micro-control"
        case control
        case page
        case settle
        case routeEnter = "route-enter"
        case routeExit = "route-exit"
        case startup
        case settingsEnter = "settings-enter"
        case settingsExit = "settings-exit"
    }

    enum Outcome: String, Sendable {
        case start
        case settle
        case cancel
        case supersede
    }

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

    @discardableResult
    static func settle(_ name: Name) -> UInt64? {
        finish(name, outcome: .settle)
    }

    @discardableResult
    static func cancel(_ name: Name) -> UInt64? {
        finish(name, outcome: .cancel)
    }

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

    nonisolated(unsafe) private static var hasOpen = false
}
