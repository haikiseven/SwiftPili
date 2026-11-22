import Foundation
import os
import UIKit

@MainActor
final class PowerProfiler {
    static let shared = PowerProfiler()
    private static let reportInterval: TimeInterval = 10

    // MARK: - Hot-loop tick counters

    struct LoopTicks {
        var watchdog = 0
        var netSampler = 0
    }

    enum Loop: Sendable {
        case watchdog, netSampler
    }

    private struct HotState {
        var streaming = false
        var ticks = LoopTicks()
    }

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

    var playerMetrics: (() -> String?)?

    // MARK: - Streaming lifecycle

    private var reportTask: Task<Void, Never>?
    private var streamingAccess: ExperimentalAccessReceipt?
    private var observers: [NSObjectProtocol] = []
    private var drainBaseline: (level: Float, at: Date)?

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

    private var drainLabel: String {
        guard UIDevice.current.batteryState == .unplugged,
              let baseline = drainBaseline else { return "" }
        let hours = Date().timeIntervalSince(baseline.at) / 3600
        guard hours > 0.05 else { return "" }
        let delta = Double(UIDevice.current.batteryLevel - baseline.level) * 100
        return String(format: "(%+.1f%%/h)", delta / hours)
    }

    // MARK: - Labels

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

    struct ThreadSample: Sendable {
        let name: String
        let usage: Double
        let machPort: mach_port_t
        let isMain: Bool
        let runState: Int32

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

        var label: String {
            "\(displayName):\(String(format: "%.0f", usage))%/\(runStateLabel)"
        }
    }

    private static func memoryLabel(_ sys: SystemSample) -> String {
        var label = " mem=\(sys.footprintMB)MB"
        if let available = sys.availableMB {
            label += " memAvail=\(available)MB memLimit≈\(sys.footprintMB + available)MB"
        }
        return label
    }

    nonisolated private static func availableMemoryMB() -> Int? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int(bytes / 1_048_576) : nil
    }

    struct SystemSample: Sendable {
        let cpuPercent: Double
        let threads: [ThreadSample]
        let threadCount: Int
        let footprintMB: Int
        let availableMB: Int?

        var hottestThread: ThreadSample? { threads.first }

        var topThreads: [ThreadSample] {
            Array(threads.prefix(3).filter { $0.usage >= 1 })
        }
    }

    nonisolated static func sampleSystem() -> SystemSample {
        var total = 0.0
        var samples: [ThreadSample] = []
        var totalThreads = 0
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
                mach_port_deallocate(mach_task_self_, port)
                guard kr == KERN_SUCCESS else { continue }
                let usage = Double(info.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100
                let isMain = mainPort != 0 && port == mainPort
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
