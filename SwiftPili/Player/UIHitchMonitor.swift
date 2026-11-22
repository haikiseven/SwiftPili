import os
import QuartzCore
import UIKit

@MainActor
final class UIHitchMonitor: NSObject {
    static let shared = UIHitchMonitor(meter: sharedMeter)

    private var displayLink: CADisplayLink?
    @MainActor private final class DisplayLinkTarget: NSObject {
        weak var monitor: UIHitchMonitor?

        init(_ monitor: UIHitchMonitor) { self.monitor = monitor }

        @objc func tick(_ link: CADisplayLink) {
            guard let monitor else { link.invalidate(); return }
            monitor.tick(link)
        }
    }
    private var lastTick: CFTimeInterval?
    private var lastExpectedInterval: CFTimeInterval?
    private var windowStart: CFTimeInterval?
    private var ticks = 0
    private var missedSlots = 0
    private var stalls = 0
    private var worstGap: CFTimeInterval = 0

    private static let reportInterval: CFTimeInterval = 2
    private static let stallThreshold: CFTimeInterval = 0.024

    // MARK: - Body-eval meter

    nonisolated static let sharedMeter = Meter()
    let meter: Meter
    private let notificationCenter: NotificationCenter
    private let applicationIsActive: @MainActor () -> Bool
    private let installsDisplayLink: Bool
    private let now: @MainActor () -> CFTimeInterval
    private var epochStartedAt: CFTimeInterval = 0
    private static let activityNotifications = [
        UIApplication.willResignActiveNotification,
        UIApplication.didEnterBackgroundNotification,
        UIApplication.willEnterForegroundNotification,
        UIApplication.didBecomeActiveNotification,
    ]
    private var active = false
    private(set) var running = false
    init(
        meter: Meter,
        notificationCenter: NotificationCenter = .default,
        applicationIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        installsDisplayLink: Bool = true,
        now: @escaping @MainActor () -> CFTimeInterval = CACurrentMediaTime
    ) {
        self.meter = meter
        self.notificationCenter = notificationCenter
        self.applicationIsActive = applicationIsActive
        self.installsDisplayLink = installsDisplayLink
        self.now = now
        super.init()
    }

    isolated deinit {
        displayLink?.invalidate()
        notificationCenter.removeObserver(self)
        _ = meter.setAuthority(metering: false, active: false)
    }

    nonisolated static func count(_ key: String) { countBody(key) }

    nonisolated static func countBody(_ key: String) { sharedMeter.count(key) }

    nonisolated static func measure<T>(_ key: String, _ work: () -> T) -> T {
        sharedMeter.measure(key, work)
    }

    nonisolated static func beginFrameInterval() -> Int? { sharedMeter.beginFrameInterval() }

    nonisolated static func endFrameInterval(_ token: Int) -> FrameInterval? {
        sharedMeter.endFrameInterval(token)
    }

    nonisolated static func bodyCountSnapshot() -> [String: Int] { sharedMeter.bodyCountSnapshot() }

    nonisolated static func bodyCountDelta(from before: [String: Int], to after: [String: Int]) -> String {
        let moved = after
            .map { (key: $0.key, delta: $0.value - (before[$0.key] ?? 0)) }
            .filter { $0.delta > 0 }
            .sorted { $0.delta > $1.delta }
        guard !moved.isEmpty else { return "-" }
        return moved.map { "\($0.key):\($0.delta)" }.joined(separator: ",")
    }

    // MARK: - Lifecycle (reference-counted owners)

    enum Owner: Hashable {
        case debugLogging
        case imageDiagnostics
        case freezeWatchdog
    }

    private var owners: Set<Owner> = []

    private var wantsMetering = false

    func addOwner(_ owner: Owner) {
        guard owners.insert(owner).inserted else { return }
        wantsMetering = owners.contains { $0 != .freezeWatchdog }
        if !running { start() } else { applyMetering() }
    }

    func removeOwner(_ owner: Owner) {
        guard owners.remove(owner) != nil else { return }
        wantsMetering = owners.contains { $0 != .freezeWatchdog }
        if owners.isEmpty { stop() } else { applyMetering() }
    }

    private func resetWindow() {
        lastTick = nil
        lastExpectedInterval = nil
        windowStart = nil
        ticks = 0
        missedSlots = 0
        stalls = 0
        worstGap = 0
    }

    private func applyMetering() {
        if meter.setAuthority(metering: wantsMetering, active: active) {
            epochStartedAt = now()
            resetWindow()
        }
    }

    private func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        applyMetering()
    }

    private func observeActivity() {
        for name in Self.activityNotifications {
            notificationCenter.addObserver(self, selector: #selector(activityChanged(_:)), name: name, object: nil)
        }
        setActive(applicationIsActive())
    }

    @objc private func activityChanged(_ notification: Notification) {
        setActive(notification.name == UIApplication.didBecomeActiveNotification && applicationIsActive())
    }

    private func start() {
        guard !running else { return }
        running = true
        observeActivity()
        applyMetering()
        if installsDisplayLink {
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        running = false
        for name in Self.activityNotifications { notificationCenter.removeObserver(self, name: name, object: nil) }
        active = false
        _ = meter.setAuthority(metering: false, active: false)
        resetWindow()
    }

    // MARK: - Tick

    @objc private func tick(_ link: CADisplayLink) {
        FreezeWatchdog.noteDisplayTick(at: ProcessInfo.processInfo.systemUptime)
        let sample = processTick(at: link.timestamp, targetTimestamp: link.targetTimestamp)
        if let hitch = sample?.hitch {
            ImageDiagnostics.noteHitch(gapMilliseconds: hitch.milliseconds, missedSlots: hitch.missed)
        }
        if let window = sample?.window { emit(window) }
    }

    @discardableResult
    func processTick(at now: CFTimeInterval, targetTimestamp: CFTimeInterval) -> TickSample? {
        guard running else { return nil }
        setActive(applicationIsActive())
        guard active, wantsMetering, now >= epochStartedAt else { return nil }
        let currentExpected = max(targetTimestamp - now, 1.0 / 120)
        defer { lastExpectedInterval = currentExpected }
        guard let lastTick else {
            self.lastTick = now
            windowStart = now
            return nil
        }
        guard now > lastTick else { return nil }
        var hitch: (milliseconds: Int, missed: Int)?
        let expected = max(lastExpectedInterval ?? currentExpected, currentExpected)
        let gap = now - lastTick
        ticks += 1
        let missed = Int((gap / expected).rounded()) - 1
        if missed > 0 {
            missedSlots += missed
            worstGap = max(worstGap, gap)
            let isStall = gap >= Self.stallThreshold
            meter.lock.withLock { state in
                guard state.eligible, !state.frameIntervals.isEmpty else { return }
                let milliseconds = Int(gap * 1000)
                state.frameIntervals = state.frameIntervals.mapValues { open in
                    var open = open
                    guard lastTick >= open.startedAt else {
                        open.boundaryGaps += 1
                        return open
                    }
                    open.missed += missed
                    if isStall { open.stalls += 1 }
                    open.worstMilliseconds = max(open.worstMilliseconds, milliseconds)
                    return open
                }
            }
            if isStall {
                stalls += 1
                hitch = (Int(gap * 1000), missed)
            }
        }
        self.lastTick = now
        var window: WindowSnapshot?
        if let windowStart, now - windowStart >= Self.reportInterval {
            window = drainWindow(seconds: now - windowStart)
            self.windowStart = now
        }
        return TickSample(hitch: hitch, window: window)
    }

    struct TickSample {
        let hitch: (milliseconds: Int, missed: Int)?
        let window: WindowSnapshot?
    }

    struct WindowSnapshot {
        let seconds: CFTimeInterval
        let ticks: Int
        let missedSlots: Int
        let stalls: Int
        let worstGap: CFTimeInterval
        let bodies: [String: Int]
        let spentMicros: [String: Int]
    }

    private func snapshotWindow(seconds: CFTimeInterval, drain: Bool) -> WindowSnapshot {
        let pacing = (ticks: ticks, missed: missedSlots, stalls: stalls, worst: worstGap)
        return meter.lock.withLock { state in
            let window = WindowSnapshot(seconds: seconds, ticks: pacing.ticks, missedSlots: pacing.missed,
                                        stalls: pacing.stalls, worstGap: pacing.worst, bodies: state.bodyCounts,
                                        spentMicros: state.spentMicros)
            if drain {
                state.bodyCounts = [:]
                state.spentMicros = [:]
            }
            return window
        }
    }

    private func drainWindow(seconds: CFTimeInterval) -> WindowSnapshot {
        let window = snapshotWindow(seconds: seconds, drain: true)
        ticks = 0
        missedSlots = 0
        stalls = 0
        worstGap = 0
        return window
    }

    private func emit(_ snapshot: WindowSnapshot) {
        let window = snapshot.seconds
        let ticks = snapshot.ticks
        let missedSlots = snapshot.missedSlots
        let stalls = snapshot.stalls
        let worstGap = snapshot.worstGap
        let bodies = snapshot.bodies
        let spent = snapshot.spentMicros
        let transitionID = FullscreenTransitionDiagnostics.recordDisplayLinkWindow(
            seconds: window,
            ticks: ticks,
            missedSlots: missedSlots,
            stalls: stalls,
            worstGapMilliseconds: Int(worstGap * 1000)
        )
        ImageDiagnostics.noteCounterSnapshot(
            windowSeconds: window,
            stalls: stalls,
            worstMilliseconds: Int(worstGap * 1000)
        )
        guard missedSlots > 0 || !bodies.isEmpty || !spent.isEmpty else { return }
        var line = "[hitch] meter=callback-estimate-v2 stalls=\(stalls) missed=\(missedSlots)"
        line += " worst=\(Int(worstGap * 1000))ms"
        line += " ticks=\(Int(Double(ticks) / window))/s"
        if let transitionID {
            line += " transition=\(transitionID)"
        }
        if !bodies.isEmpty {
            line += " bodies[" + bodies.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ") + "]"
        }
        if !spent.isEmpty {
            line += " us[" + spent.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ") + "]"
        }
        PlayerLog.log(line)
    }
}

extension UIHitchMonitor {
    struct MeterState {
        var metering = false
        var active = false
        var epoch: UInt64 = 0

        var eligible: Bool { metering && active }
        var bodyCounts: [String: Int] = [:]
        var totalCounts: [String: Int] = [:]
        var spentMicros: [String: Int] = [:]
        var frameIntervals: [Int: FrameIntervalState] = [:]
        var nextFrameIntervalToken = 1
    }

    final class Meter: Sendable {
        let lock = OSAllocatedUnfairLock(initialState: MeterState())

        nonisolated func count(_ key: String) {
            lock.withLock { state in
                guard state.eligible else { return }
                state.bodyCounts[key, default: 0] += 1
                state.totalCounts[key, default: 0] += 1
            }
        }

        nonisolated func measure<T>(
            _ key: String,
            now: () -> CFTimeInterval = CACurrentMediaTime,
            _ work: () -> T
        ) -> T {
            guard let epoch = lock.withLock({ $0.eligible ? $0.epoch : nil }) else { return work() }
            let start = now()
            let result = work()
            let micros = Int((now() - start) * 1_000_000)
            lock.withLock { state in
                guard state.eligible, state.epoch == epoch else { return }
                state.spentMicros[key, default: 0] += micros
            }
            return result
        }

        nonisolated func beginFrameInterval(at now: CFTimeInterval = CACurrentMediaTime()) -> Int? {
            lock.withLock { state in
                guard state.eligible else { return nil }
                let token = state.nextFrameIntervalToken
                state.nextFrameIntervalToken += 1
                state.frameIntervals[token] = FrameIntervalState(startedAt: now)
                return token
            }
        }

        nonisolated func endFrameInterval(
            _ token: Int,
            at now: CFTimeInterval = CACurrentMediaTime()
        ) -> FrameInterval? {
            lock.withLock { state in
                guard let interval = state.frameIntervals.removeValue(forKey: token),
                      state.eligible
                else { return nil }
                return FrameInterval(
                    missed: interval.missed,
                    stalls: interval.stalls,
                    worstMilliseconds: interval.worstMilliseconds,
                    spanMilliseconds: Int((now - interval.startedAt) * 1000),
                    boundaryGaps: interval.boundaryGaps
                )
            }
        }

        nonisolated func bodyCountSnapshot() -> [String: Int] {
            lock.withLock { $0.metering ? $0.totalCounts : [:] }
        }

        fileprivate nonisolated func setAuthority(metering: Bool, active: Bool) -> Bool {
            lock.withLock { state in
                guard state.metering != metering || state.active != active else { return false }
                if state.metering != metering { state.totalCounts = [:] }
                state.metering = metering
                state.active = active
                state.epoch += 1
                state.bodyCounts = [:]
                state.spentMicros = [:]
                state.frameIntervals = [:]
                return true
            }
        }
    }
}
