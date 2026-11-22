import Foundation

final class FreezeMarkerStore: @unchecked Sendable {
    static let shared = FreezeMarkerStore()

    struct Marker: Codable, Sendable, Equatable {
        let beganAt: Date
        let beganAtUptime: TimeInterval
        let ageAtWriteMilliseconds: Int
        let snapshot: String
    }

    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freeze-marker.json")
    }

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
