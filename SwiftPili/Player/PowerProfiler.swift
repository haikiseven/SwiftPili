import Foundation
import os
import UIKit

/// Battery-drain / power-consumption telemetry. Streams through the
/// same os_log ring as the stress diagnostics, and rides the SAME
/// switch (Settings → Playback → Debug Logging) — no toggle of its own.
///
/// Every 10s, two `[Power]` lines:
///  - system: whole-app CPU% with the top named threads, memory
///    footprint, thermal state, Low Power Mode, battery level and the
///    session drain rate (meaningful only unplugged).
///  - loops/s: MEASURED tick rates of the app's own periodic loops —
///    watchdog (0.2/s: the liveness evaluator) and netSampler (1/s
///    while a stream lives) — plus the player's fps / decoder path /
///    network pull when one is active.
///
/// It once also reported videoSync/audioSync, the KSPlayer-era A/V align
/// loops. libVLC owns A/V sync now (design doc F10), nothing ever ticked
/// them, and they printed `0.0` forever — a reading that looks like a
/// measurement and is not one. Removed.
///
/// One-shot lines mark thermal-state, Low Power Mode, and charger
/// transitions, since each re-baselines any drain reading.
///
/// GPU utilization has NO public API on iOS; its share of the profile is
/// covered by proxies (render fps, hardware- vs-software decoder path).
/// For absolute joules, run Instruments' Energy Log against these
/// timestamps.
@MainActor
final class PowerProfiler {
    static let shared = PowerProfiler()
    private static let reportInterval: TimeInterval = 10

    // MARK: - Hot-loop tick counters

    struct LoopTicks {
        var watchdog = 0
        var netSampler = 0
    }

    /// Enum, not a WritableKeyPath<LoopTicks, Int>: key paths are not
    /// Sendable, and the counter bump crosses into withLock's @Sendable
    /// closure from the render thread.
    enum Loop: Sendable {
        case watchdog, netSampler
    }

    private struct HotState {
        var streaming = false
        var ticks = LoopTicks()
    }

    /// The hot path is one uncontended unfair-lock increment, and nothing
    /// at all while streaming is off.
    /// nonisolated: statics on a @MainActor class are otherwise
    /// MainActor-isolated, and tick() runs on the render thread.
    private nonisolated static let hotState = OSAllocatedUnfairLock(initialState: HotState())

    nonisolated static func tick(_ loop: Loop) {
        guard ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        hotState.withLock { state in
            guard state.streaming else { return }
            switch loop {
            case .watchdog: state.ticks.watchdog += 1
            case .netSampler: state.ticks.netSampler += 1
            }
        }
    }

    /// Player extras for the loops line — installed by PlayerViewModel,
    /// returns nil when no stream is active.
    var playerMetrics: (() -> String?)?

    // MARK: - Streaming lifecycle

    private var reportTask: Task<Void, Never>?
    private var streamingAccess: ExperimentalAccessReceipt?
    private var observers: [NSObjectProtocol] = []
    /// Battery baseline for the drain rate; re-anchored on charger
    /// transitions. nil when the level is unknown (simulator).
    private var drainBaseline: (level: Float, at: Date)?

    /// Follows the Debug Logging toggle — called at launch with
    /// the persisted value and from the Settings binding on change.
    func setStreaming(_ requested: Bool) {
        let on = requested && PlayerLog.isEnabled
        let wasOn = Self.hotState.withLock { state in
            let was = state.streaming
            if was != on {
                state.streaming = on
                state.ticks = LoopTicks()
            }
            return was
        }
        guard on != wasOn else { return }
        if on { start() } else { stop() }
    }

    private func start() {
        guard let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        streamingAccess = access
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIHitchMonitor.shared.addOwner(.debugLogging)
        rebaselineDrain()
        PlayerLog.log("[Power] profiling ON (\(Int(Self.reportInterval))s cadence) thermal=\(Self.thermalLabel) lowPower=\(Self.lowPowerLabel) batt=\(Self.batteryLabel) \(Self.batteryStateLabel)")
        observe(ProcessInfo.thermalStateDidChangeNotification) {
            // serious/critical = the OS is already throttling; any drain
            // numbers around this line have a hardware cofactor.
            PlayerLog.log("[Power] ⚠️ thermal state → \(Self.thermalLabel)")
        }
        observe(.NSProcessInfoPowerStateDidChange) {
            PlayerLog.log("[Power] Low Power Mode → \(Self.lowPowerLabel)")
        }
        observe(UIDevice.batteryStateDidChangeNotification) { [weak self] in
            self?.rebaselineDrain()
            PlayerLog.log("[Power] battery state → \(Self.batteryStateLabel) at \(Self.batteryLabel)")
        }
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.reportInterval))
                guard let self, !Task.isCancelled, access.isValid else { return }
                await self.report(access: access)
            }
        }
    }

    private func stop() {
        streamingAccess = nil
        UIHitchMonitor.shared.removeOwner(.debugLogging)
        reportTask?.cancel()
        reportTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        drainBaseline = nil
        PlayerLog.log("[Power] profiling OFF")
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor @Sendable () -> Void) {
        guard let access = streamingAccess else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard access.isValid, PlayerLog.isEnabled else { return }
                handler()
            }
        })
    }

    private func rebaselineDrain() {
        let level = UIDevice.current.batteryLevel
        drainBaseline = level >= 0 ? (level, Date()) : nil
    }

    // MARK: - Periodic report

    private func report(access: ExperimentalAccessReceipt) async {
        guard streamingAccess == access, access.isValid, PlayerLog.isEnabled else { return }
        let ticks = Self.hotState.withLock { state in
            let t = state.ticks
            state.ticks = LoopTicks()
            return t
        }
        // Mach thread walk off-main; ~1ms, but the main thread is the
        // resource under observation.
        let sys = await Task.detached(priority: .utility) {
            guard access.isValid else { return nil as SystemSample? }
            return Self.sampleSystem()
        }.value
        guard let sys, streamingAccess == access, access.isValid, PlayerLog.isEnabled else { return }

        var line = "[Power] cpu=\(String(format: "%.1f", sys.cpuPercent))%"
        if !sys.topThreads.isEmpty {
            line += " top[" + sys.topThreads
                .map(\.label)
                .joined(separator: " | ") + "]"
        }
        line += Self.memoryLabel(sys)
        line += " thermal=\(Self.thermalLabel)"
        line += " lowPower=\(Self.lowPowerLabel)"
        line += " batt=\(Self.batteryLabel)\(drainLabel)"
        PlayerLog.log(line)

        func rate(_ count: Int) -> String {
            String(format: "%.1f", Double(count) / Self.reportInterval)
        }
        var loops = "[Power] loops/s: watchdog=\(rate(ticks.watchdog))"
        loops += " netSampler=\(rate(ticks.netSampler))"
        if let extra = playerMetrics?() {
            loops += " | \(extra)"
        }
        PlayerLog.log(loops)
    }

    /// Session drain rate, unplugged only — battery level granularity
    /// is 1%, so the first minutes read 0 and the number firms up as
    /// the window grows.
    private var drainLabel: String {
        guard UIDevice.current.batteryState == .unplugged,
              let baseline = drainBaseline else { return "" }
        let hours = Date().timeIntervalSince(baseline.at) / 3600
        guard hours > 0.05 else { return "" }
        let delta = Double(UIDevice.current.batteryLevel - baseline.level) * 100
        return String(format: "(%+.1f%%/h)", delta / hours)
    }

    // MARK: - Labels

    /// nonisolated + internal: `ProcessInfo` is thread-safe, and
    /// `FreezeWatchdog` reads both of these from its own queue DURING a main-
    /// thread freeze — the one moment when hopping to the main actor for a
    /// label is exactly what must not happen.
    nonisolated static var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    nonisolated static var lowPowerLabel: String {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
    }

    private static var batteryLabel: String {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? "\(Int(level * 100))%" : "?"
    }

    private static var batteryStateLabel: String {
        switch UIDevice.current.batteryState {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    // MARK: - System sampling (Mach)

    /// One thread of this task, as much of it as the Mach thread walk can say.
    ///
    /// It carries three fields a plain `(name, usage)` pair could not, and each
    /// of them closed a specific hole in a real freeze report:
    ///
    ///  - `isMain`, decided by Mach port identity rather than by name. Nothing
    ///    on Darwin names the main thread, so before `MainThreadIdentity.adopt()`
    ///    started naming it, EVERY report in this project's archive read
    ///    `threads[unnamed:99%]` and left the reader to infer which thread that
    ///    was. Port identity does not require the name to exist.
    ///  - `runState`, straight out of `thread_extended_info.pth_run_state`,
    ///    which separates the two readings that look identical in a CPU column:
    ///    a thread RUNNING at 99% is computing, a thread WAITING at 99% has an
    ///    accounting artefact and is blocked. That distinction is the difference
    ///    between hunting a busy loop and hunting a lock.
    ///  - `machPort`, purely as a correlation token between rows of ONE census.
    ///    It is deliberately not a handle: the walk deallocates every port name
    ///    it was handed before it returns (it must, or each census leaks a send
    ///    right per thread), so by the time a caller reads this field the name
    ///    may already have been recycled onto a different port. Anything that
    ///    wants to ACT on a thread has to resolve it inside the walk, while the
    ///    reference is still held — see the note in `FreezeStackSampler` for why
    ///    that is also why no non-main stack is taken.
    struct ThreadSample: Sendable {
        /// pthread name, empty when the thread has none. Dispatch worker
        /// threads and Swift concurrency pool threads are unnamed BY DESIGN
        /// (libdispatch recycles them across queues, so a name stamped on one
        /// would persist onto unrelated work), and libVLC's threads cannot be
        /// renamed from this side of the boundary. So an empty name here is
        /// information, not a defect to fix by naming everything.
        let name: String
        let usage: Double
        let machPort: mach_port_t
        let isMain: Bool
        /// `TH_STATE_*`.
        let runState: Int32

        /// `main` wins over the pthread name: the port comparison is
        /// authoritative and the name is a convenience.
        var displayName: String {
            if isMain { return "main" }
            return name.isEmpty ? "unnamed" : name
        }

        var runStateLabel: String {
            switch runState {
            case TH_STATE_RUNNING: "running"
            case TH_STATE_STOPPED: "stopped"
            case TH_STATE_WAITING: "waiting"
            case TH_STATE_UNINTERRUPTIBLE: "uninterruptible"
            case TH_STATE_HALTED: "halted"
            default: "state\(runState)"
            }
        }

        /// One printable token, identical in the `[Power]` and `[Freeze]` lines
        /// so the two can be read against each other without a translation
        /// table.
        var label: String {
            "\(displayName):\(String(format: "%.0f", usage))%/\(runStateLabel)"
        }
    }

    /// ` mem=…MB`, plus what the system still lets this process allocate and
    /// the ceiling that implies on this device (Apple publishes none). The
    /// media cache's byte caps are sized from these — see the 09-28 cache
    /// evaluation.
    private static func memoryLabel(_ sys: SystemSample) -> String {
        var label = " mem=\(sys.footprintMB)MB"
        if let available = sys.availableMB {
            label += " memAvail=\(available)MB memLimit≈\(sys.footprintMB + available)MB"
        }
        return label
    }

    /// `os_proc_available_memory()` in MB; nil where it reports 0.
    nonisolated private static func availableMemoryMB() -> Int? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int(bytes / 1_048_576) : nil
    }

    struct SystemSample: Sendable {
        let cpuPercent: Double
        /// Every thread with measurable CPU, hottest first.
        let threads: [ThreadSample]
        /// Total threads in the task, including the idle ones `threads` drops.
        let threadCount: Int
        let footprintMB: Int
        /// `os_proc_available_memory()` in MB; nil where it reports 0 (the
        /// simulator, or a process with no limit to report).
        let availableMB: Int?

        /// The single biggest consumer, with no minimum. `topThreads` filters at
        /// 1% to keep the 10s line short; a freeze report must be able to name
        /// the hot thread even when the whole task is otherwise quiet.
        var hottestThread: ThreadSample? { threads.first }

        /// Top consumers only — a 17-thread dump every 10s is noise.
        var topThreads: [ThreadSample] {
            Array(threads.prefix(3).filter { $0.usage >= 1 })
        }
    }

    /// Internal, not private: `FreezeWatchdog` needs the same CPU/thread/
    /// footprint reading during a freeze, and a second copy of this Mach walk
    /// is the last thing this repo needs. Already `nonisolated` — it touches
    /// nothing but the task port.
    nonisolated static func sampleSystem() -> SystemSample {
        var total = 0.0
        var samples: [ThreadSample] = []
        var totalThreads = 0
        // 0 when the identity was never adopted, and 0 is not a valid port name
        // — so an un-adopted process simply reports no main thread rather than
        // mislabelling thread zero as one.
        let mainPort = MainThreadIdentity.machPort
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        if task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList {
            totalThreads = Int(threadCount)
            for i in 0..<Int(threadCount) {
                var info = thread_extended_info_data_t()
                var count = mach_msg_type_number_t(
                    MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size
                )
                let kr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_info(threadList[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
                    }
                }
                let port = threadList[i]
                // Released here, exactly as before. Our own reference to the
                // main thread's port came from `mach_thread_self()` and is never
                // deallocated, so dropping this one cannot invalidate the name
                // the `isMain` comparison below depends on. The name in the
                // sample is a correlation token only, for the reason recorded on
                // the field — it is dead the moment this line runs.
                mach_port_deallocate(mach_task_self_, port)
                guard kr == KERN_SUCCESS else { continue }
                let usage = Double(info.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100
                let isMain = mainPort != 0 && port == mainPort
                // A thread with no measurable CPU is dropped — EXCEPT main,
                // which a freeze report must be able to report as idle rather
                // than as absent. "Main is not in the list" and "main used no
                // CPU" are opposite conclusions.
                guard usage > 0 || isMain else { continue }
                total += usage
                let name = withUnsafeBytes(of: info.pth_name) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                samples.append(ThreadSample(
                    name: name,
                    usage: usage,
                    machPort: port,
                    isMain: isMain,
                    runState: info.pth_run_state
                ))
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }
        samples.sort { $0.usage > $1.usage }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let vmKr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        let footprintMB = vmKr == KERN_SUCCESS ? Int(vmInfo.phys_footprint / 1_048_576) : 0

        return SystemSample(
            cpuPercent: total,
            threads: samples,
            threadCount: totalThreads,
            footprintMB: footprintMB,
            availableMB: availableMemoryMB()
        )
    }
}
