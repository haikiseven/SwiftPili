import CoreGraphics
import Foundation

struct ImageSite: Sendable {
    var screen: String
    var component: String

    static let unknown = ImageSite(screen: "?", component: "?")
}

enum ImageDiagnosticsSource: String, Sendable {
    case memory
    case disk
    case network
}

final class ImageDiagnostics: @unchecked Sendable {
    static let shared = ImageDiagnostics()

    static let enabledKey = "image_perf_diagnostics_enabled"
    static let overlayKey = "image_perf_diagnostics_overlay"

    private nonisolated(unsafe) static var runtimeEnabled = false
    static var isEnabled: Bool { ExperimentalSettingsPolicy.diagnosticsEnabled && runtimeEnabled }
    @MainActor private static var monitorActivated = false
    @MainActor private static var monitorArmed = false

    static var isRecordingImageEvents: Bool {
        isEnabled && ImagePipelinePolicy.emitsImageDiagnostics
    }

    nonisolated(unsafe) static var isCapturing = false

    nonisolated(unsafe) static var isScrolling = false

    // MARK: - Arming

    @MainActor
    static func setEnabled(_ on: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(on, forKey: enabledKey)
        applyExperimentalPolicy()
    }

    @MainActor
    static func applyExperimentalPolicy(activateMonitor: Bool = true) {
        monitorActivated = monitorActivated || activateMonitor
        let enabled = ExperimentalSettingsPolicy.isAllowed(.diagnostics)
            && UserDefaults.standard.bool(forKey: enabledKey)
        if enabled != runtimeEnabled {
            if !enabled { stopCapture() }
            runtimeEnabled = enabled
            shared.resetCounters()
        }
        let armMonitor = enabled && monitorActivated
        guard armMonitor != monitorArmed else { return }
        monitorArmed = armMonitor
        if armMonitor {
            UIHitchMonitor.shared.addOwner(.imageDiagnostics)
        } else {
            UIHitchMonitor.shared.removeOwner(.imageDiagnostics)
        }
    }

    @MainActor
    static func setOverlayEnabled(_ enabled: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(enabled, forKey: overlayKey)
    }

    @MainActor
    static func applyLaunchState() { applyExperimentalPolicy() }

    static func startCapture() {
        guard isEnabled, let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        shared.reset()
        guard access.isValid else { return }
        isCapturing = true
        shared.append(
            Event(kind: .note, detail: "capture started — counters reset")
        )
    }

    static func stopCapture() {
        guard isCapturing else { return }
        shared.append(Event(kind: .note, detail: "capture stopped"))
        isCapturing = false
    }

    static func clearLog() {
        shared.reset()
        shared.resetCounters()
    }

    // MARK: - Event model

    enum Kind: String {
        case appear
        case gone
        case probe
        case setup
        case resize
        case hitMemory = "hit.mem"
        case hitDisk = "hit.disk"
        case miss
        case fail
        case hitch
        case indicator
        case counters
        case note
    }

    struct Event {
        var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var kind: Kind
        var digest: String = ""
        var micros: Int?
        var source: ImageDiagnosticsSource?
        var pixels: CGSize?
        var rendered: CGSize?
        var visible: Bool?
        var screen: String = ""
        var component: String = ""
        var scrolling = false
        var detail: String = ""
    }

    private static let capacity = 4000

    private let lock = NSLock()
    private var events: [Event] = []
    private var head = 0
    private var dropped = 0
    private var startedAtUptime = ProcessInfo.processInfo.systemUptime
    private var startedAtWall = Date()

    struct Counters: Sendable {
        var body = 0
        var appear = 0
        var gone = 0
        var probe = 0
        var hitMemory = 0
        var hitDisk = 0
        var miss = 0
        var fail = 0
        var indicators = 0
        var hitches = 0
        var setupMicros = 0
        var completionsWhileOffscreen = 0
        var variants = 0
        var distinctImages = 0
        var requestStreams = 0
        var resizes = 0
        var untracked = 0
        var stallsWhileScrolling = 0
        var stallsAtRest = 0
    }

    private var counters = Counters()
    private var liveByDigest: [String: Int] = [:]
    private struct RequestStream: Hashable {
        let digest: String
        let component: String
    }

    private var boxesByStream: [RequestStream: Set<String>] = [:]
    private var boxesByDigest: [String: Set<String>] = [:]
    private static let maxTrackedDigests = 600

    // MARK: - Recording

    private func append(_ event: Event) {
        guard ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard ExperimentalSettingsPolicy.diagnosticsEnabled else { return }
        if events.count < Self.capacity {
            events.append(event)
        } else {
            events[head] = event
            head = (head + 1) % Self.capacity
            dropped += 1
        }
    }

    private func reset() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
        head = 0
        dropped = 0
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        startedAtWall = Date()
    }

    private func resetCounters() {
        lock.lock()
        defer { lock.unlock() }
        counters = Counters()
        liveByDigest.removeAll(keepingCapacity: true)
        boxesByStream.removeAll(keepingCapacity: true)
        boxesByDigest.removeAll(keepingCapacity: true)
    }

    func snapshot() -> Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    // MARK: - Call sites

    static func noteBody() {
        guard isRecordingImageEvents else { return }
        shared.bump { $0.body += 1 }
    }

    static func noteAppear(url: String, rendered: CGSize, at site: ImageSite) {
        guard isRecordingImageEvents else { return }
        let digest = shortDigest(url)
        shared.withState { counters, live in
            counters.appear += 1
            live[digest, default: 0] += 1
        }
        guard isCapturing else { return }
        shared.append(Event(kind: .appear, digest: digest, rendered: rendered,
                            screen: site.screen, component: site.component,
                            scrolling: isScrolling))
    }

    static func noteDisappear(url: String, at site: ImageSite) {
        guard isRecordingImageEvents else { return }
        let digest = shortDigest(url)
        shared.withState { counters, live in
            counters.gone += 1
            if let n = live[digest] {
                if n <= 1 { live.removeValue(forKey: digest) } else { live[digest] = n - 1 }
            }
        }
        guard isCapturing else { return }
        shared.append(Event(kind: .gone, digest: digest,
                            screen: site.screen, component: site.component,
                            scrolling: isScrolling))
    }

    static func noteProbe(url: String, rendered: CGSize, at site: ImageSite) {
        guard isRecordingImageEvents else { return }
        shared.bump { $0.probe += 1 }
        guard isCapturing else { return }
        shared.append(Event(kind: .probe, digest: shortDigest(url), rendered: rendered,
                            screen: site.screen, component: site.component,
                            scrolling: isScrolling))
    }

    static func measuringSetup<T>(
        url: String,
        rendered: CGSize,
        at site: ImageSite,
        _ work: () -> T
    ) -> T {
        guard isRecordingImageEvents,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return work() }
        let start = ProcessInfo.processInfo.systemUptime
        let result = work()
        guard access.isValid, isRecordingImageEvents else { return result }
        let micros = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000_000)
        let digest = shortDigest(url)
        let previous = shared.noteRequest(
            digest: digest,
            component: site.component,
            box: describe(rendered),
            setupMicros: micros
        )
        guard isCapturing else { return result }
        shared.append(Event(kind: .setup, digest: digest, micros: micros, rendered: rendered,
                            screen: site.screen, component: site.component,
                            scrolling: isScrolling))
        if !previous.isEmpty {
            shared.append(Event(kind: .resize, digest: digest, rendered: rendered,
                                screen: site.screen, component: site.component,
                                scrolling: isScrolling,
                                detail: "was " + previous.joined(separator: ",")))
        }
        return result
    }

    static func noteCompletion(
        url: String,
        source: ImageDiagnosticsSource,
        pixels: CGSize?,
        rendered: CGSize?,
        at site: ImageSite
    ) {
        guard isRecordingImageEvents else { return }
        let digest = shortDigest(url)
        var visible = false
        shared.withState { counters, live in
            switch source {
            case .memory: counters.hitMemory += 1
            case .disk: counters.hitDisk += 1
            case .network: counters.miss += 1
            }
            visible = (live[digest] ?? 0) > 0
            if !visible { counters.completionsWhileOffscreen += 1 }
        }
        guard isCapturing else { return }
        let kind: Kind = switch source {
        case .memory: .hitMemory
        case .disk: .hitDisk
        case .network: .miss
        }
        shared.append(Event(kind: kind, digest: digest, source: source, pixels: pixels,
                            rendered: rendered, visible: visible,
                            screen: site.screen, component: site.component,
                            scrolling: isScrolling))
    }

    static func noteFailure(url: String, rendered: CGSize?, at site: ImageSite) {
        guard isRecordingImageEvents else { return }
        let digest = shortDigest(url)
        var visible = false
        shared.withState { counters, live in
            counters.fail += 1
            visible = (live[digest] ?? 0) > 0
            if !visible { counters.completionsWhileOffscreen += 1 }
        }
        guard isCapturing else { return }
        shared.append(Event(kind: .fail, digest: digest, rendered: rendered, visible: visible,
                            screen: site.screen, component: site.component,
                            scrolling: isScrolling))
    }

    static func noteIndicatorShown(shorterSide: CGFloat?) {
        guard isRecordingImageEvents else { return }
        shared.bump { $0.indicators += 1 }
        guard isCapturing else { return }
        shared.append(Event(
            kind: .indicator,
            scrolling: isScrolling,
            detail: shorterSide.map { "side=\(Int($0.rounded()))" } ?? "side=?"
        ))
    }

    static func noteHitch(gapMilliseconds: Int, missedSlots: Int) {
        guard isEnabled else { return }
        let scrolling = isScrolling
        shared.bump {
            $0.hitches += 1
            if scrolling { $0.stallsWhileScrolling += 1 } else { $0.stallsAtRest += 1 }
        }
        guard isCapturing else { return }
        shared.append(Event(kind: .hitch, micros: gapMilliseconds * 1000,
                            scrolling: scrolling,
                            detail: "gap=\(gapMilliseconds)ms missed=\(missedSlots)"))
    }

    static func noteCounterSnapshot(windowSeconds: Double, stalls: Int, worstMilliseconds: Int) {
        guard isEnabled, isCapturing else { return }
        let c = shared.snapshot()
        shared.append(Event(
            kind: .counters,
            scrolling: isScrolling,
            detail: "window=\(String(format: "%.1f", windowSeconds))s "
                + "stalls=\(stalls) worst=\(worstMilliseconds)ms "
                + "body=\(c.body) appear=\(c.appear) gone=\(c.gone) probe=\(c.probe) "
                + "mem=\(c.hitMemory) disk=\(c.hitDisk) miss=\(c.miss) fail=\(c.fail) "
                + "spinners=\(c.indicators) "
                + "offscreen=\(c.completionsWhileOffscreen) "
                + "images=\(c.distinctImages) streams=\(c.requestStreams) "
                + "variants=\(c.variants) resizes=\(c.resizes) "
                + "setup=\(c.setupMicros)us"
        ))
    }

    // MARK: - Locked helpers

    private func noteRequest(
        digest: String,
        component: String,
        box: String,
        setupMicros: Int
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled else { return [] }
        counters.setupMicros += setupMicros

        let stream = RequestStream(digest: digest, component: component)
        let seenHere = boxesByStream[stream]
        guard seenHere != nil || boxesByStream.count < Self.maxTrackedDigests else {
            counters.untracked += 1
            return []
        }

        if let seenAnywhere = boxesByDigest[digest] {
            if !seenAnywhere.contains(box) {
                boxesByDigest[digest]?.insert(box)
                counters.variants += 1
            }
        } else {
            boxesByDigest[digest] = [box]
            counters.distinctImages += 1
            counters.variants += 1
        }

        guard let seenHere else {
            boxesByStream[stream] = [box]
            counters.requestStreams += 1
            return []
        }
        guard !seenHere.contains(box) else { return [] }
        boxesByStream[stream]?.insert(box)
        counters.resizes += 1
        return seenHere.sorted()
    }

    private func bump(_ mutate: (inout Counters) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled else { return }
        mutate(&counters)
    }

    private func withState(
        _ mutate: (inout Counters, inout [String: Int]) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled else { return }
        mutate(&counters, &liveByDigest)
    }

    // MARK: - Digest

    static func shortDigest(_ urlString: String) -> String {
        let path: Substring
        if let range = urlString.range(of: "://"),
           let slash = urlString[range.upperBound...].firstIndex(of: "/") {
            let afterHost = urlString[slash...]
            path = afterHost.prefix { $0 != "?" && $0 != "#" }
        } else {
            path = urlString.prefix { $0 != "?" && $0 != "#" }
        }
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash.multipliedReportingOverflow(by: 16_777_619).partialValue
        }
        return String(format: "%08x", hash)
    }

    // MARK: - Derived attribution

    struct StallWindow: Sendable {
        var atSeconds: TimeInterval
        var gapMilliseconds: Int
        var scrolling: Bool
        var appears = 0
        var setups = 0
        var setupMicros = 0
        var probes = 0
        var indicators = 0
        var memoryHits = 0
        var diskHits = 0
        var misses = 0
        var failures = 0
        var kilopixels = 0

        var completions: Int { memoryHits + diskHits + misses + failures }
    }

    static func stallWindows(_ events: [Event], origin: TimeInterval) -> [StallWindow] {
        var windows: [StallWindow] = []
        for (index, hitch) in events.enumerated() where hitch.kind == .hitch {
            let gapMicros = hitch.micros ?? 0
            guard gapMicros > 0 else { continue }
            let start = hitch.uptime - Double(gapMicros) / 1_000_000
            var window = StallWindow(
                atSeconds: hitch.uptime - origin,
                gapMilliseconds: gapMicros / 1000,
                scrolling: hitch.scrolling
            )
            var cursor = index - 1
            while cursor >= 0, events[cursor].uptime > start {
                let event = events[cursor]
                cursor -= 1
                switch event.kind {
                case .appear: window.appears += 1
                case .probe: window.probes += 1
                case .indicator: window.indicators += 1
                case .setup:
                    window.setups += 1
                    window.setupMicros += event.micros ?? 0
                case .hitMemory: window.memoryHits += 1
                case .hitDisk: window.diskHits += 1
                case .miss: window.misses += 1
                case .fail: window.failures += 1
                default: break
                }
                if let pixels = event.pixels {
                    window.kilopixels += Int(pixels.width * pixels.height / 1000)
                }
            }
            windows.append(window)
        }
        return windows
    }

    struct CompletionLatency: Sendable {
        var source: ImageDiagnosticsSource
        var seconds: TimeInterval
        var component: String
    }

    static func completionLatencies(_ events: [Event]) -> [CompletionLatency] {
        var pending: [String: [TimeInterval]] = [:]
        var result: [CompletionLatency] = []
        for event in events {
            switch event.kind {
            case .setup:
                pending[event.digest, default: []].append(event.uptime)
            case .hitMemory, .hitDisk, .miss, .fail:
                guard var queue = pending[event.digest], !queue.isEmpty else { continue }
                let started = queue.removeFirst()
                pending[event.digest] = queue.isEmpty ? nil : queue
                let source = event.source ?? (
                    event.kind == .hitMemory ? .memory
                        : event.kind == .hitDisk ? .disk : .network
                )
                result.append(CompletionLatency(
                    source: source,
                    seconds: max(0, event.uptime - started),
                    component: event.component
                ))
            default: break
            }
        }
        return result
    }

    static let indicatorGateSeconds: TimeInterval = 0.200

    static func percentile(_ sorted: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    static func latencyLines(_ events: [Event]) -> [String] {
        let all = completionLatencies(events)
        guard !all.isEmpty else { return [] }
        var lines: [String] = []
        for source in [ImageDiagnosticsSource.memory, .disk, .network] {
            let ofClass = all.filter { $0.source == source }
            let times = ofClass.map(\.seconds).sorted()
            guard !times.isEmpty else { continue }
            let overGate = times.filter { $0 >= indicatorGateSeconds }.count
            let label = source.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            let slowest = ofClass.max { $0.seconds < $1.seconds }
            lines.append(
                "  \(label)n=\(times.count)"
                + String(
                    format: "  p50=%.1fms  p90=%.1fms  max=%.1fms",
                    percentile(times, 0.5) * 1000,
                    percentile(times, 0.9) * 1000,
                    (times.last ?? 0) * 1000
                )
                + "  >=\(Int(indicatorGateSeconds * 1000))ms: \(overGate)"
                + ((slowest?.component).flatMap { $0.isEmpty ? nil : "  slowest@\($0)" } ?? "")
            )
        }
        return lines
    }

    // MARK: - Export

    func reportText() -> String {
        lock.lock()
        let ordered = events.count < Self.capacity
            ? events
            : Array(events[head...]) + Array(events[..<head])
        let droppedCount = dropped
        let origin = startedAtUptime
        let started = startedAtWall
        let totals = counters
        let liveNow = liveByDigest.values.reduce(0, +)
        let streams = boxesByStream
        lock.unlock()

        var out = "SwiftPili image performance report\n"
        out += "capture started: \(started)\n"
        out += "timestamps: monotonic uptime, relative to capture start\n"
        out += "identity: 8-hex FNV-1a of the URL path only (no URLs, no user ids)\n"
        out += "A/B arms: \(ImagePipelinePolicy.activeArmSummary)\n"
        out += "events: \(ordered.count) of ring capacity \(Self.capacity)"
        out += droppedCount > 0 ? ", \(droppedCount) older events dropped\n" : "\n"

        out += "\ntotals  body=\(totals.body) appear=\(totals.appear) gone=\(totals.gone)"
        out += " probe=\(totals.probe) mem=\(totals.hitMemory) disk=\(totals.hitDisk)"
        out += " miss=\(totals.miss) fail=\(totals.fail)"
        out += " spinners=\(totals.indicators)\n"
        out += "        hitches=\(totals.hitches)"
        out += " (scrolling=\(totals.stallsWhileScrolling) at-rest=\(totals.stallsAtRest))\n"
        out += "        completions-while-offscreen=\(totals.completionsWhileOffscreen)"
        out += " setup-total=\(totals.setupMicros)us cells-live-now=\(liveNow)\n"
        out += "        images=\(totals.distinctImages) streams=\(totals.requestStreams)"
        out += " variants=\(totals.variants) resizes=\(totals.resizes)"
        if totals.untracked > 0 { out += " untracked=\(totals.untracked)" }
        if totals.requestStreams > 0 {
            let ratio = Double(totals.variants) / Double(totals.requestStreams)
            out += String(format: "  variants-per-stream=%.2f", ratio)
            out += ratio > 1.05 ? "  <-- GEOMETRY CHURN\n" : "\n"
        } else {
            out += "\n"
        }

        let churn = streams.filter { $0.value.count > 1 }
        let worst = churn.sorted { $0.value.count > $1.value.count }.prefix(25)
        if !worst.isEmpty {
            out += "\ncall sites that requested ONE image at MORE THAN ONE box"
            out += " (\(churn.count) of \(streams.count) tracked streams):\n"
            for (stream, sizes) in worst {
                out += "  \(stream.digest)  \(stream.component)"
                out += "  \(sizes.count) boxes: \(sizes.sorted().joined(separator: " -> "))\n"
            }
        }

        if ordered.isEmpty {
            out += "\n(no events — arm Image Diagnostics, press Start Capture, then scroll)\n"
            return out
        }

        let windows = Self.stallWindows(ordered, origin: origin)
        if !windows.isEmpty {
            let worstStalls = windows.sorted { $0.gapMilliseconds > $1.gapMilliseconds }
            out += "\nworst stalls, and the image work INSIDE each gap"
            out += " (\(windows.count) stalls recorded):\n"
            out += "        at      gap  scr  appear  setup  setup-us  probe"
            out += "  spin   mem  disk  miss  fail     kpx\n"
            for window in worstStalls.prefix(12) {
                out += String(format: "  %+8.3f  %5dms  ",
                              window.atSeconds, window.gapMilliseconds)
                out += Self.pad(window.scrolling ? "SCR" : "-", 3)
                out += String(
                    format: " %6d %6d  %8d %6d %5d %5d %5d %5d %5d %7d\n",
                    window.appears, window.setups, window.setupMicros,
                    window.probes, window.indicators,
                    window.memoryHits, window.diskHits,
                    window.misses, window.failures, window.kilopixels
                )
            }
        }

        let latencies = Self.latencyLines(ordered)
        if !latencies.isEmpty {
            out += "\nrequest built -> completion on main, by cache class:\n"
            for line in latencies { out += line + "\n" }
        }
        out += "\n  +seconds  event      digest    dur      src      pixels      rendered    vis  scr  screen/component\n"
        out.reserveCapacity(out.count + ordered.count * 128)
        for event in ordered {
            out += String(format: "%+10.3f  ", event.uptime - origin)
            out += event.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            out += " "
            out += (event.digest.isEmpty ? "-" : event.digest)
                .padding(toLength: 9, withPad: " ", startingAt: 0)
            out += Self.pad(event.micros.map { "\($0)us" }, 8)
            out += Self.pad(event.source?.rawValue, 8)
            out += Self.pad(event.pixels.map(Self.describe), 11)
            out += Self.pad(event.rendered.map(Self.describe), 11)
            out += Self.pad(event.visible.map { $0 ? "yes" : "NO" }, 4)
            out += Self.pad(event.scrolling ? "SCR" : "-", 4)
            if !event.screen.isEmpty || !event.component.isEmpty {
                out += "\(event.screen)/\(event.component) "
            }
            if !event.detail.isEmpty { out += event.detail }
            out += "\n"
        }
        return out
    }

    private static func pad(_ value: String?, _ width: Int) -> String {
        let text = value ?? "-"
        return text.count >= width
            ? text + " "
            : text.padding(toLength: width, withPad: " ", startingAt: 0) + " "
    }

    static func describe(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}
