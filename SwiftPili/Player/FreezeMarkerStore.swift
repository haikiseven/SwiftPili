import Foundation

/// Crash-durable record of an in-progress main-thread freeze.
///
/// Written synchronously from the watchdog queue on freeze classification and cleared
/// when the main thread answers. If the process is force-quit or watchdog-killed before
/// clearing, `promoteOrphan()` converts the marker into a `HangReportStore` entry on
/// the next launch.
final class FreezeMarkerStore: @unchecked Sendable {
    static let shared = FreezeMarkerStore()

    struct Marker: Codable, Sendable, Equatable {
        let beganAt: Date
        /// Monotonic uptime at classification; compared against next-launch uptime to detect device reboots.
        let beganAtUptime: TimeInterval
        /// Elapsed freeze duration when the marker was written (total duration is unknowable after termination).
        let ageAtWriteMilliseconds: Int
        /// Redacted `[Freeze] begin` snapshot.
        let snapshot: String
    }

    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freeze-marker.json")
    }

    /// Called from the watchdog queue DURING the freeze. Synchronous and
    /// atomic on purpose: the whole point is that the bytes are on disk before
    /// the process can be killed, so deferring the write would defeat it. One
    /// small write per freeze episode — never per stall, never per tick.
    func write(_ marker: Marker) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }

    /// The main thread answered — this freeze is being reported by the live
    /// path, so the marker has no orphan to describe.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func load() -> Marker? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Promotes a surviving marker from a terminated freeze into `HangReportStore` and clears the slot.
    @discardableResult
    func promoteOrphan() -> String? {
        guard let marker = load() else { return nil }
        clear()
        let text = Self.orphanText(
            marker,
            now: Date(),
            uptime: ProcessInfo.processInfo.systemUptime
        )
        HangReportStore.shared.append(text: text, capturedAt: marker.beganAt)
        return text
    }

    private static func orphanText(
        _ marker: Marker,
        now: Date,
        uptime: TimeInterval
    ) -> String {
        // uptime below the marker's own reading can only mean the device
        // rebooted between the freeze and this launch — which distinguishes
        // "the user force-quit the app" from "the whole device went down".
        let rebooted = uptime < marker.beganAtUptime
        var out = "[Freeze] UNTERMINATED — the process did not survive this freeze.\n"
        out += "began: \(marker.beganAt) "
        out += "(already frozen \(marker.ageAtWriteMilliseconds)ms when this marker was written;\n"
        out += " the total duration is unknown — nothing ran afterwards to measure it)\n"
        out += "recovered: \(now) after a \(rebooted ? "device reboot" : "process restart")\n"
        out += "\n"
        out += marker.snapshot
        return out
    }
}
