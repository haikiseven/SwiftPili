import Foundation
import Synchronization

/// Bounded in-memory rolling capture of playback diagnostic lines, for
/// on-device forensics of the 1x freeze→burst pathology. Everything that
/// flows through `PlayerLog` is mirrored here while the recorder is enabled —
/// including with the Debug Logging toggle OFF, so a capture never requires
/// the console firehose (and never requires a tethered Mac at all: the report
/// view's Copy All is the transport off the device).
///
/// Deliberately NOT the stats overlay: the overlay shows the present; this
/// keeps the recent past, so a freeze that already happened can still be
/// correlated with the transport/supply/clock events around it.
///
/// Cost model: one static Bool read per `PlayerLog` call when disabled
/// (identical to the existing `isEnabled` gate); when enabled, one lock-guarded
/// ring append per EMITTED line — and emission stays event-level (fills,
/// stream opens/ends, state edges, 1Hz instruments), never per packet/frame.
///
/// Timestamps are `ProcessInfo.systemUptime` — monotonic (mach_absolute_time
/// based, same clock family as CACurrentMediaTime), immune to wall-clock
/// adjustments; the report renders them relative to capture start.
final class PlaybackDebugRecorder: @unchecked Sendable {
    static let shared = PlaybackDebugRecorder()

    static let defaultsKey = "playback_debug_report_enabled"

    /// Read on every `PlayerLog` call from any thread; written on MainActor by Settings.
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

    /// Settings-toggle entry point: persists the choice and starts each
    /// capture clean, so a report never mixes two repro sessions.
    @MainActor
    static func setEnabled(_ on: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        if on, !isEnabled { shared.reset() }
        UserDefaults.standard.set(on, forKey: defaultsKey)
        applyExperimentalPolicy()
        if on { shared.record("[report] capture enabled") }
    }

    private struct Event {
        /// Monotonic record sequence, assigned under the lock. Survives the
        /// ring rolling over it, which is what lets a live reader ask for
        /// "everything after N" in O(new) instead of re-reading the ring.
        let sequence: Int
        let uptime: TimeInterval
        let line: String
    }

    /// One captured line, prepared for a consumer: the timestamp already
    /// resolved against the capture origin (so nothing downstream needs the
    /// origin), plus the record sequence as a stable identity.
    ///
    /// The ring hands these out instead of formatted text because the report
    /// viewer renders one row per event: a snapshot must not force the
    /// whole-ring serialization that only Copy All actually needs.
    struct Entry: Sendable, Identifiable {
        let id: Int
        /// Seconds since capture start — exactly the number the report prints.
        let offset: TimeInterval
        let line: String
    }

    /// A consistent read of the ring. Taken under the lock, consumed outside
    /// it: `Sendable` so a background task can format rows, filter, or
    /// serialize the whole thing without holding up `record`.
    struct Snapshot: Sendable {
        var entries: [Entry] = []
        var dropped = 0
        var capacity = PlaybackDebugRecorder.capacity
        var startedAt = Date()
        /// Newest sequence the ring held at snapshot time, and the cursor an
        /// incremental reader passes back to `snapshot(newerThan:)`. `-1` on an
        /// empty capture, so a fresh cursor of `-1` reads everything.
        var latestSequence = -1
    }

    /// Ring capacity in lines (~1.2 MB at ~150 B/line); the report header prints
    /// the measured emission rate and implied time window.
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

    /// Consistent copy of the whole ring, oldest first. The lock covers the
    /// copy and NOTHING else — no formatting, no string building — so a reader
    /// on any thread stalls `record` for O(events) element copies at worst.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked(from: 0, count: events.count)
    }

    /// Incremental read for a live viewer: only what was recorded after
    /// `sequence`. Appending N lines therefore costs O(N), never O(capacity),
    /// which is what keeps a 1 Hz tail off the "rebuild everything per event"
    /// shape. A cursor that fell further behind than the ring can hold clamps
    /// to the ring — the viewer then shows the oldest retained event, which is
    /// the truth, rather than reading past the head.
    func snapshot(newerThan sequence: Int) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let fresh = max(0, min(events.count, (nextSequence - 1) - sequence))
        return snapshotLocked(from: events.count - fresh, count: fresh)
    }

    /// `count` events beginning at logical index `start` (0 = oldest retained).
    /// Caller holds the lock.
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

    /// Executable modification timestamp identifying the installed build in exported reports.
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

    /// Measured capture rate and the ring window it implies. Printed instead of
    /// a comment's guess: the rate depends on which toggles are on and on what
    /// the session was doing, so only the capture itself can state it.
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

    /// Per-tag line census, densest first. This exists because an earlier audit
    /// of a real capture could not attribute ~79% of the line rate to any
    /// emitter: the only surviving excerpt was the one someone had already
    /// hand-filtered down to the interesting lines, which are by definition not
    /// the ones doing the flooding. A capture that carries its own census can
    /// be acted on without a second capture.
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

    /// Leading bracket run, so `[PathA][pipe] …` censuses as one emitter family
    /// rather than collapsing into `[PathA]` with everything else under it.
    static func tag(of line: String) -> String {
        var end = line.startIndex
        while end < line.endIndex, line[end] == "[" {
            guard let close = line[end...].firstIndex(of: "]") else { break }
            end = line.index(after: close)
        }
        return end == line.startIndex ? "(untagged)" : String(line[line.startIndex..<end])
    }

    /// The report's ONE filter predicate — the on-screen search, the live-tail
    /// append and the export all call this, so a filtered export cannot show
    /// something other than what the screen showed. Case-insensitive substring,
    /// because the queries this serves are log tags like `[WindowSpike]`, not
    /// patterns.
    static func matchesFilter(_ line: String, query: String) -> Bool {
        line.range(of: query, options: [.caseInsensitive]) != nil
    }

    /// Snapshot + serialize in one call, for a caller that wants the text and
    /// nothing else.
    func reportText() -> String {
        Self.reportText(from: snapshot())
    }
}
