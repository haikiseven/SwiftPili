import Foundation

/// Durable, bounded store for MetricKit hang, crash, and exit forensics (`HangDiagnosticsReporter`
/// writes, `HangReportView` reads), surviving relaunches independently of the debug log ring.
final class HangReportStore: @unchecked Sendable {
    static let shared = HangReportStore()

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        let id: UUID
        let capturedAt: Date
        let text: String
    }

    private let fileURL: URL
    private let capacity = 20
    private let lock = NSLock()
    /// Loaded lazily under `lock`; `nil` means disk has not been read yet this process.
    private var cached: [Entry]?

    private init() {
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hang-reports.json")
    }

    func append(text: String, capturedAt: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard var entries = loadLocked() else {
            // Transient read failure (e.g. file protection before first unlock): drop this
            // copy rather than overwriting existing archived reports with a truncated file.
            return
        }
        entries.append(Entry(id: UUID(), capturedAt: capturedAt, text: text))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        cached = entries
        saveLocked(entries)
    }

    /// Newest first; empty on transient read failure without caching the failure.
    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return (loadLocked() ?? []).reversed()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Disk (callers hold `lock`)

    private func loadLocked() -> [Entry]? {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cached = []
            return []
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let loaded = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        cached = loaded
        return loaded
    }

    private func saveLocked(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
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
}
