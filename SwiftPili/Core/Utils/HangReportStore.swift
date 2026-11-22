import Foundation

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
            return
        }
        entries.append(Entry(id: UUID(), capturedAt: capturedAt, text: text))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        cached = entries
        saveLocked(entries)
    }

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
