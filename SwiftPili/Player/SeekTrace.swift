import Foundation
import QuartzCore

@MainActor
enum SeekTrace {
    private static let completionLabel = "arrived"
    private static let firstTickLabel = "first-tick"

    private static var sessionID: UInt64 = 0
    private static var t0: CFTimeInterval = 0
    private static var lastMarkAt: CFTimeInterval = 0
    private static var firstTickAt: CFTimeInterval = 0
    private static var settledAt: CFTimeInterval = 0
    private static var settleMs: Int = 0
    private static var settleRunUpMs: Int?
    private static var visibleAt: CFTimeInterval = 0
    private static var target: TimeInterval = 0
    private static var path: String = ""
    private static var seen: Set<String> = []
    private static var active = false

    struct Timing: Equatable, Sendable {
        let path: String
        let target: TimeInterval
        let settleMs: Int
        let visibleMs: Int?
        let runUpMs: Int?
    }

    static var onComplete: (@MainActor (Timing) -> Void)?

    static var wantsVisibleFrame: Bool {
        active && !seen.contains("visible-frame")
    }

    static func begin(target: TimeInterval, from current: TimeInterval, path: String = "reopen") {
        let now = CACurrentMediaTime()
        if active, settledAt > 0 {
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

    static func mark(_ label: String) {
        guard active else { return }
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
        if visibleAt > 0 || path == "native" { finish() }
    }

    static func visibleProbeTimedOut() {
        guard active, settledAt > 0 else { return }
        finishEpilogueWithoutVisible(closedBy: "probe-timeout")
    }

    static func markVisibleFrame() {
        guard active, seen.insert("visible-frame").inserted else { return }
        let now = CACurrentMediaTime()
        visibleAt = now
        PlayerLog.log(
            "[Seek] sid=\(sessionID) visible-frame +\(elapsedMilliseconds(from: t0, to: now))ms"
        )
        if settledAt > 0 { finish() }
    }

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

    private static func finishEpilogueWithoutVisible(closedBy reason: String) {
        guard active, settledAt > 0 else { return }
        PlayerLog.log("[Seek] sid=\(sessionID) visible never fired (closed by \(reason))")
        finish()
    }

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

    static func abort(_ reason: String) {
        guard active else { return }
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

    private static func position(_ t: TimeInterval) -> String {
        t.isFinite ? String(format: "%.1fs", t) : "n/a"
    }

    private static func signedPosition(_ t: TimeInterval) -> String {
        t.isFinite ? String(format: "%+.1fs", t) : "n/a"
    }
}
