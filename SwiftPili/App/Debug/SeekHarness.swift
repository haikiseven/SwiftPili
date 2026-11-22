#if DEBUG
import Foundation

struct SeekHarnessSpec: Equatable, Sendable {
    var bvid: String
    var dwellSeconds: TimeInterval = 4
    var seeks: [TimeInterval] = []
    var repeatCount = 1
    var exitBack = false
    var resume = false
    var switchQuality: (quality: Int, position: TimeInterval)?

    static let argumentName = "-seek-harness"
    static let environmentKey = "SEEK_HARNESS"

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bvid == rhs.bvid && lhs.dwellSeconds == rhs.dwellSeconds
            && lhs.seeks == rhs.seeks && lhs.repeatCount == rhs.repeatCount
            && lhs.exitBack == rhs.exitBack && lhs.resume == rhs.resume
            && lhs.switchQuality?.quality == rhs.switchQuality?.quality
            && lhs.switchQuality?.position == rhs.switchQuality?.position
    }

    static func requestedRaw(arguments: [String], environment: [String: String]) -> String? {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return nil }
        if let index = arguments.firstIndex(of: argumentName), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        return environment[environmentKey]
    }

    init?(parsing raw: String) {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let id = parts.first, id.hasPrefix("BV"), id.count >= 10,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        bvid = id
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, apply(key: pair[0], value: pair[1]) else { return nil }
        }
        guard !seeks.isEmpty || resume || switchQuality != nil else { return nil }
    }

    private static func time(_ text: Substring) -> TimeInterval? {
        guard let value = TimeInterval(text), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func flag(_ text: Substring) -> Bool? {
        switch text {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }

    private mutating func apply(key: Substring, value: Substring) -> Bool {
        switch key {
        case "dwell":
            guard let dwell = Self.time(value), dwell <= 120 else { return false }
            dwellSeconds = dwell
        case "repeat":
            guard let count = Int(value), (1...20).contains(count) else { return false }
            repeatCount = count
        case "seeks":
            return applySeeks(value)
        case "exitBack", "resume":
            guard let enabled = Self.flag(value) else { return false }
            if key == "exitBack" { exitBack = enabled } else { resume = enabled }
        case "switchQn":
            return applyQualitySwitch(value)
        default:
            return false
        }
        return true
    }

    private mutating func applySeeks(_ value: Substring) -> Bool {
        let times = value.split(separator: ",").map(Self.time)
        guard !times.isEmpty, times.allSatisfy({ $0 != nil }) else { return false }
        seeks = times.compactMap { $0 }
        return true
    }

    private mutating func applyQualitySwitch(_ value: Substring) -> Bool {
        let parts = value.split(separator: "@")
        guard parts.count == 2, let quality = Int(parts[0]), quality > 0,
              let position = Self.time(parts[1]) else { return false }
        switchQuality = (quality, position)
        return true
    }
}

@MainActor
enum SeekHarness {
    private static var task: Task<Void, Never>?
    private static var access: ExperimentalAccessReceipt?
    private static var isAdmitted: Bool { access?.isValid == true && !Task.isCancelled }

    static func applyExperimentalPolicy() {
        guard !ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        access = nil
        task?.cancel()
    }

    static func startIfRequested(coordinator: AppCoordinator) {
        guard task == nil,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics),
              let raw = SeekHarnessSpec.requestedRaw(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
              ) else {
            return
        }
        guard let spec = SeekHarnessSpec(parsing: raw) else {
            PlayerLog.log("[SeekHarness] rejected spec=\(raw)")
            task = Task {}
            return
        }
        self.access = access
        task = Task { @MainActor in
            guard access.isValid else { return }
            await run(spec, coordinator: coordinator)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }

    private static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private static func waitForPlayback(_ player: PlayerViewModel, timeout: TimeInterval) async -> Bool {
        let start = ContinuousClock.now
        while milliseconds(since: start) < Int(timeout * 1_000) {
            guard isAdmitted else { return false }
            if player.duration > 0, player.isPlaying, !player.isBuffering { return true }
            await sleep(0.1)
        }
        return false
    }

    private static func seek(
        _ player: PlayerViewModel,
        to target: TimeInterval,
        timeout: TimeInterval = 15
    ) async -> (settlement: String, settleMs: Int) {
        @MainActor final class Box { var settlement: PlayerViewModel.SeekSettlement? }
        let box = Box()
        guard isAdmitted else { return ("retired", 0) }
        let start = ContinuousClock.now
        player.seek(to: target) { settlement in
            box.settlement = settlement
        }
        while box.settlement == nil, milliseconds(since: start) < Int(timeout * 1_000) {
            await sleep(0.02)
            guard isAdmitted else { return ("retired", milliseconds(since: start)) }
        }
        let label: String
        switch box.settlement {
        case .arrived: label = "arrived"
        case .failed: label = "failed"
        case .handedOff: label = "handedOff"
        case nil: label = "timeout"
        }
        return (label, milliseconds(since: start))
    }

    private static func run(_ spec: SeekHarnessSpec, coordinator: AppCoordinator) async {
        guard isAdmitted else { return }
        let player = PlayerViewModel.shared
        PlayerLog.log(
            "[SeekHarness] start bvid=\(spec.bvid) seeks=\(spec.seeks.count) " +
            "repeat=\(spec.repeatCount) dwell=\(spec.dwellSeconds) resume=\(spec.resume ? 1 : 0) " +
            "switchQn=\(spec.switchQuality.map { "\($0.quality)@\($0.position)" } ?? "none") " +
            "exitBack=\(spec.exitBack ? 1 : 0) fastPreroll=" +
            "\(SeekFastPrerollSwitch.processDefault ? 1 : 0)"
        )
        await sleep(1.5)
        guard isAdmitted else { return }
        let openStart = ContinuousClock.now
        coordinator.navigate(to: .videoDetail(.bvid(spec.bvid)))
        guard await waitForPlayback(player, timeout: 30) else {
            PlayerLog.log("[SeekHarness] result=open-timeout openMs=\(milliseconds(since: openStart))")
            finish(seeks: 0)
            return
        }
        guard isAdmitted else { return }
        PlayerLog.log(
            "[SeekHarness] opened bvid=\(spec.bvid) qn=\(player.currentQuality) " +
            "codec=\(player.stats.codec) res=\(player.stats.resolution) " +
            "fps=\(String(format: "%.1f", player.stats.fps)) " +
            "position=\(String(format: "%.3f", player.displayTime)) openMs=\(milliseconds(since: openStart))"
        )
        await sleep(spec.dwellSeconds)

        guard let index = await runSeeks(spec, player: player) else { return }

        guard isAdmitted else { return }
        if let switchQuality = spec.switchQuality {
            await runQualitySwitch(switchQuality, dwell: spec.dwellSeconds, player: player)
        }

        guard isAdmitted else { return }
        if spec.exitBack {
            coordinator.goBack()
            await sleep(2)
            PlayerLog.log("[SeekHarness] exited detail screen")
        }
        finish(seeks: index)
    }

    private static func runSeeks(_ spec: SeekHarnessSpec, player: PlayerViewModel) async -> Int? {
        var index = 0
        for _ in 0..<spec.repeatCount {
            for target in spec.seeks {
                guard isAdmitted else { return nil }
                let result = await seek(player, to: target)
                guard isAdmitted else { return nil }
                PlayerLog.log(
                    "[SeekHarness] i=\(index) target=\(String(format: "%.3f", target)) " +
                    "ok=\(result.settlement == "arrived" ? 1 : 0) settlement=\(result.settlement) " +
                    "settleMs=\(result.settleMs)"
                )
                index += 1
                await sleep(spec.dwellSeconds)
            }
        }

        return index
    }

    private static func runQualitySwitch(
        _ switchQuality: (quality: Int, position: TimeInterval), dwell: TimeInterval, player: PlayerViewModel
    ) async {
        let seekResult = await seek(player, to: switchQuality.position)
        guard isAdmitted else { return }
        PlayerLog.log(
            "[SeekHarness] switch-seek target=\(String(format: "%.3f", switchQuality.position)) " +
            "settlement=\(seekResult.settlement) settleMs=\(seekResult.settleMs)"
        )
        await sleep(dwell)
        guard isAdmitted else { return }
        let switchStart = ContinuousClock.now
        await player.switchQuality(switchQuality.quality)
        let ready = await waitForPlayback(player, timeout: 30)
        guard isAdmitted else { return }
        PlayerLog.log(
            "[SeekHarness] switch qn=\(switchQuality.quality) " +
            "at=\(String(format: "%.3f", switchQuality.position)) " +
            "ok=\(ready ? 1 : 0) settleMs=\(milliseconds(since: switchStart)) " +
            "position=\(String(format: "%.3f", player.displayTime)) qnNow=\(player.currentQuality)"
        )
        await sleep(dwell)
    }

    private static func finish(seeks: Int) {
        guard isAdmitted else { return }
        PlayerLog.log("[SeekHarness] done n=\(seeks)")
        let text = PlaybackDebugRecorder.reportText(from: PlaybackDebugRecorder.shared.snapshot())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let directory = documents.appendingPathComponent("SeekHarness", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(formatter.string(from: Date())).txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            PlayerLog.log("[SeekHarness] report written \(file.lastPathComponent) bytes=\(text.utf8.count)")
        } catch {
            PlayerLog.log("[SeekHarness] report write failed: \(error.localizedDescription)")
        }
    }
}
#endif
