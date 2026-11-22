import Foundation
import os
import QuartzCore

/// Lock-guarded monotonic timing probe (`CACurrentMediaTime()`) around render-surface
/// moves: `embed`, window membership (`offWindow`/`onWindow`), first non-zero `sized`
/// layout, and `firstFrame` enqueue (an upper bound on the presentation gap).
enum SurfaceMoveProbe {
    private struct State {
        var movedAt: CFTimeInterval?
        var leftWindowAt: CFTimeInterval?
        var lastMountStepAt: CFTimeInterval?
        var sawSized = false
        var sawFrame = false
        var generation = -1
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Maximum interval after detach during which stamps attribute to the move.
    private static let armedWindow: CFTimeInterval = 3.0

    /// Stamped inside `embedIfNeeded()` immediately before `addSubview(vc.view)`.
    static func noteEmbed(generation: Int, wasHosted: Bool, inWindow: Bool) {
        let now = CACurrentMediaTime()
        let sincePrevious: CFTimeInterval? = state.withLock { state in
            let previous = state.movedAt
            state.movedAt = now
            state.sawSized = false
            state.sawFrame = false
            state.generation = generation
            return previous.map { now - $0 }
        }
        let gap = sincePrevious.map { " sincePreviousEmbed=\(ms($0))" } ?? ""
        PlayerLog.log(
            "[SurfaceGap] embed generation=\(generation) "
                + "kind=\(wasHosted ? "move" : "cold") "
                + "window=\(inWindow ? 1 : 0)\(gap)"
        )
    }

    /// Stamped when a container tears down a hosted view it still holds.
    static func noteTeardown(generation: Int) {
        let now = CACurrentMediaTime()
        state.withLock { state in
            state.movedAt = now
            state.sawSized = false
            state.sawFrame = false
            state.generation = generation
        }
        PlayerLog.log("[SurfaceGap] teardown generation=\(generation)")
    }

    /// Stamped from `didMoveToWindow()` on the display view itself to measure exact off-window duration.
    static func noteWindowMembership(inWindow: Bool, generation: Int) {
        let now = CACurrentMediaTime()
        if !inWindow {
            state.withLock { state in
                state.leftWindowAt = now
                state.lastMountStepAt = nil
                state.sawSized = false
                state.sawFrame = false
                state.generation = generation
            }
            PlayerLog.log("[SurfaceGap] offWindow generation=\(generation)")
            return
        }
        let away: CFTimeInterval? = state.withLock { state in
            let leftAt = state.leftWindowAt
            state.leftWindowAt = nil
            state.movedAt = now
            state.sawSized = false
            state.sawFrame = false
            return leftAt.map { now - $0 }
        }
        let awayText = away.map { " away=\(ms($0))" } ?? " away=n/a(firstEntry)"
        PlayerLog.log("[SurfaceGap] onWindow generation=\(generation)\(awayText)")
    }

    /// Stamped for named steps on the host's mount path while an off-window gap is open.
    static func noteMountStep(_ step: String, detail: String = "") {
        let now = CACurrentMediaTime()
        let stamps: (CFTimeInterval, CFTimeInterval)? = state.withLock { state in
            guard let leftAt = state.leftWindowAt, now - leftAt < armedWindow else {
                return nil
            }
            let previous = state.lastMountStepAt ?? leftAt
            state.lastMountStepAt = now
            return (now - leftAt, now - previous)
        }
        guard let stamps else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        PlayerLog.log(
            "[SurfaceGap] step=\(step) intoGap=\(ms(stamps.0)) sincePrev=\(ms(stamps.1))\(suffix)"
        )
    }

    static func noteHostMilestone(_ event: String) {
        let now = CACurrentMediaTime()
        let intoGap: CFTimeInterval? = state.withLock { state in
            guard let leftAt = state.leftWindowAt, now - leftAt < armedWindow else {
                return nil
            }
            return now - leftAt
        }
        let offset = intoGap.map { " intoGap=\(ms($0))" } ?? " intoGap=-"
        PlayerLog.log("[SurfaceGap] host event=\(event)\(offset)")
    }

    /// Records the first non-zero display-view layout after a move.
    @discardableResult
    static func noteDisplaySized(bounds: CGRect) -> CFTimeInterval? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let now = CACurrentMediaTime()
        let sinceEmbed: CFTimeInterval? = state.withLock { state in
            guard !state.sawSized,
                  let movedAt = state.movedAt,
                  now - movedAt < armedWindow
            else { return nil }
            state.sawSized = true
            return now - movedAt
        }
        guard let sinceEmbed else { return nil }
        PlayerLog.log(
            "[SurfaceGap] sized sinceEmbed=\(ms(sinceEmbed)) "
                + "size=\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))"
        )
        return sinceEmbed
    }

    /// Records the first sample enqueued after a move.
    @discardableResult
    static func noteFrameEnqueued() -> CFTimeInterval? {
        let now = CACurrentMediaTime()
        let sinceEmbed: CFTimeInterval? = state.withLock { state in
            guard !state.sawFrame,
                  let movedAt = state.movedAt,
                  now - movedAt < armedWindow
            else { return nil }
            state.sawFrame = true
            return now - movedAt
        }
        guard let sinceEmbed else { return nil }
        PlayerLog.log(
            "[SurfaceGap] firstFrame sinceEmbed=\(ms(sinceEmbed))"
        )
        return sinceEmbed
    }

    private static func ms(_ seconds: CFTimeInterval) -> String {
        String(format: "%.1fms", Double(seconds) * 1000)
    }
}
