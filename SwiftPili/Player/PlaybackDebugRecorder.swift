import Foundation
import Synchronization

final class PlaybackDebugRecorder: @unchecked Sendable {
    static let shared = PlaybackDebugRecorder()

    static let defaultsKey = "playback_debug_report_enabled"

    private static let runtimeEnabled = Atomic<Bool>(false)
    static var isEnabled: Bool {
        ExperimentalSettingsPolicy.diagnosticsEnabled && runtimeEnabled.load(ordering: .acquiring)
    }

    @MainActor
    static func applyExperimentalPolicy() {
        runtimeEnabled.store(
            ExperimentalSettingsPolicy.diagnosticsEnabled && UserDefaults.standard.bool(forKey: defaultsKey),
            ordering: .releasing
        )
    }

    @MainActor
    static func setEnabled(_ on: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        if on, !isEnabled { shared.reset() }
        UserDefaults.standard.set(on, forKey: defaultsKey)
        applyExperimentalPolicy()
        if on { shared.record("[report] capture enabled") }
    }

    private struct Event {
        let sequence: Int
        let uptime: TimeInterval
        let line: String
    }

    struct Entry: Sendable, Identifiable {
        let id: Int
        let offset: TimeInterval
        let line: String
    }

    struct Snapshot: Sendable {
        var entries: [Entry] = []
        var dropped = 0
        var capacity = PlaybackDebugRecorder.capacity
        var startedAt = Date()
        var latestSequence = -1
    }

    static let capacity = 8000

    private let lock = NSLock()
    private var events: [Event] = []
    private var head = 0
    private var droppedCount = 0
    private var nextSequence = 0
    private var startedAtUptime = ProcessInfo.processInfo.systemUptime
    private var startedAtWall = Date()

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
        head = 0
        droppedCount = 0
        nextSequence = 0
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        startedAtWall = Date()
    }

    func record(_ line: String) {
        guard Self.isEnabled,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled, access.isValid else { return }
        let event = Event(sequence: nextSequence, uptime: uptime, line: line)
        nextSequence += 1
        if events.count < Self.capacity {
            events.append(event)
        } else {
            events[head] = event
            head = (head + 1) % Self.capacity
            droppedCount += 1
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked(from: 0, count: events.count)
    }

    func snapshot(newerThan sequence: Int) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let fresh = max(0, min(events.count, (nextSequence - 1) - sequence))
        return snapshotLocked(from: events.count - fresh, count: fresh)
    }

    private func snapshotLocked(from start: Int, count: Int) -> Snapshot {
        var out: [Entry] = []
        out.reserveCapacity(count)
        let rolled = events.count == Self.capacity
        for index in start..<(start + count) {
            let event = events[rolled ? (head + index) % Self.capacity : index]
            out.append(Entry(id: event.sequence, offset: event.uptime - startedAtUptime, line: event.line))
        }
        return Snapshot(
            entries: out,
            dropped: droppedCount,
            capacity: Self.capacity,
            startedAt: startedAtWall,
            latestSequence: nextSequence - 1
        )
    }

    static var buildStamp: String {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return "unknown"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: modified)
    }

    static func reportText(from snapshot: Snapshot, filter: String? = nil) -> String {
        let query = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entries = query.isEmpty
            ? snapshot.entries
            : snapshot.entries.filter { matchesFilter($0.line, query: query) }
        let count = entries.count
        var out = "SwiftPili playback report\n"
        out += "capture started: \(snapshot.startedAt) (timestamps: monotonic uptime, relative to start)\n"
        out += "build: \(buildStamp)\n"
        if query.isEmpty {
            out += "events: \(count) of ring capacity \(snapshot.capacity), \(snapshot.dropped) older events dropped\n"
            out += lineRateSummary(for: snapshot.entries, capacity: snapshot.capacity)
            out += tagCensus(for: snapshot.entries)
        } else {
            out += "events: \(count) of \(snapshot.entries.count) captured, matching filter \"\(query)\""
            out += " (ring capacity \(snapshot.capacity), \(snapshot.dropped) older events dropped)\n"
        }
        if entries.isEmpty {
            out += query.isEmpty
                ? "\n(no events captured — enable the toggle, then reproduce the issue)\n"
                : "\n(no events matched the filter)\n"
            return out
        }
        out += "\n"
        out.reserveCapacity(out.count + count * 160)
        for entry in entries {
            out += String(format: "+%10.3fs  ", entry.offset)
            out += entry.line
            out += "\n"
        }
        return out
    }

    static func lineRateSummary(for entries: [Entry], capacity: Int) -> String {
        guard let first = entries.first, let last = entries.last else { return "" }
        let span = last.offset - first.offset
        guard span > 0.5 else { return "" }
        let rate = Double(entries.count) / span
        guard rate > 0 else { return "" }
        let window = Double(capacity) / rate
        return String(
            format: "rate: %.1f lines/s over %.1fs — ring holds ~%.1f min at this rate\n",
            rate, span, window / 60
        )
    }

    static func tagCensus(for entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for entry in entries { counts[tag(of: entry.line), default: 0] += 1 }
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(12)
        var out = "by tag:"
        for (name, n) in ranked {
            out += String(format: " %@=%d(%.0f%%)", name, n, 100 * Double(n) / Double(entries.count))
        }
        return out + "\n"
    }

    static func tag(of line: String) -> String {
        var end = line.startIndex
        while end < line.endIndex, line[end] == "[" {
            guard let close = line[end...].firstIndex(of: "]") else { break }
            end = line.index(after: close)
        }
        return end == line.startIndex ? "(untagged)" : String(line[line.startIndex..<end])
    }

    static func matchesFilter(_ line: String, query: String) -> Bool {
        line.range(of: query, options: [.caseInsensitive]) != nil
    }

    func reportText() -> String {
        Self.reportText(from: snapshot())
    }
}
