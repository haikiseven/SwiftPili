import Foundation
import os
import SwiftUI
import UIKit

// MARK: - The board

private struct FreezeBoard {
    var mainAckAt: TimeInterval = 0
    var player: FreezePlayerSignals?
    var lastLine: (text: String, at: TimeInterval)?
    var lastNotable: (text: String, at: TimeInterval)?
    var screen: (name: String, at: TimeInterval)?
    var inactiveSince: TimeInterval?
    var graceUntil: TimeInterval = 0
}

// MARK: - Verdict

// MARK: - Watchdog

final class FreezeWatchdog: @unchecked Sendable {
    static let shared = FreezeWatchdog()

    private nonisolated init() {}

    private let queue = DispatchQueue(label: "com.swiftpili.freeze-watchdog", qos: .userInteractive)
    private static let tickInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var signals = FreezeBoard()

    private let displayTick = OSAllocatedUnfairLock(initialState: TimeInterval(0))

    private nonisolated(unsafe) static var isArmed = false

    private var running = false
    private var runID: UUID?
    private var runAccess: ExperimentalAccessReceipt?
    @MainActor private var monitorAccess: ExperimentalAccessReceipt?
    @MainActor private var launchCollectionRequested = false
    @MainActor private var observers: [NSObjectProtocol] = []
    private var pendingSince: TimeInterval?
    private var epoch: UInt64 = 0
    private var episode: Episode?
    private var lastHoldAt: TimeInterval = 0
    private var standingVerdict: FreezeVerdict?

    private struct Episode {
        let verdict: FreezeVerdict
        let beganAt: TimeInterval
        var persisted: Bool
        var peakAge: TimeInterval
        var snapshot: String
    }

    // MARK: - Pushes (any thread)

    static func noteDisplayTick(at uptime: TimeInterval) {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        shared.displayTick.withLock { $0 = uptime }
    }

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

    static func noteLogLine(_ line: String) {
        guard isArmed, ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        guard !line.hasPrefix("[Freeze]"), !line.hasPrefix("⚠️ [Freeze]") else { return }
        let notable = Self.notableNeedles.contains { line.contains($0) }
        let now = ProcessInfo.processInfo.systemUptime
        shared.lock.lock()
        shared.signals.lastLine = (line, now)
        if notable { shared.signals.lastNotable = (line, now) }
        shared.lock.unlock()
    }

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

        if context.now - lastHoldAt >= 1.0 {
            lastHoldAt = context.now
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

    private func closeEpisodeIfOpen(recoveredAt now: TimeInterval) {
        guard let current = episode else { return }
        episode = nil
        let line = "[Freeze] end verdict=\(current.verdict.label) " +
            "duration=\(Self.ms(now - current.beganAt)) " +
            "peak=\(Self.ms(current.peakAge)) (condition cleared)"
        PlayerLog.diagnostic(line)
        archive(current, endLine: line)
    }

    private func archive(_ episode: Episode, endLine: String) {
        guard episode.persisted else { return }
        let text = PlayerLog.redact(episode.snapshot + "\n" + endLine)
        DispatchQueue.global(qos: .utility).async {
            HangReportStore.shared.append(text: text)
            FreezeMarkerStore.shared.clear()
        }
    }

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
            out += "\n    audioClock=" + (
                sample.clockSource == "audio-drain"
                    ? "\(Self.seconds(sample.mediaTime)) (= mediaTime; drained-audio is its single writer)"
                    : "n/a (libVLC owns A/V sync internally — no audio clock is exposed)"
            )
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

    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

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

    static func clockAge(_ player: FreezePlayerSignals?, now: TimeInterval) -> TimeInterval? {
        guard let player else { return nil }
        guard player.sample.expectsProgress,
              now - player.observedAt < Self.staleObservationSeconds
        else { return nil }
        return max(0, now - player.mediaTimeMovedAt)
    }

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
                if state == "presenting" || state == "visible" {
                    PlayerLog.log("[Hang] keyboard \(state)")
                }
            })
        }
    }

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
    func freezeWatchdogScreen(_ name: String) -> some View {
        onAppear { FreezeWatchdog.noteScreen(name) }
            .onDisappear { FreezeWatchdog.noteScreen("\(name)/left") }
    }
}
