import CoreGraphics
import Foundation

/// Where an image cell lives: which screen, and which call site built it.
///
/// `component` is captured with `#fileID`/`#line` DEFAULTS on `CoverImage`'s
/// initializer, so every existing call site gets exact provenance with no edit —
/// `HomeView.swift:388` rather than a hand-maintained label that would rot.
/// `screen` comes from the environment, set once per screen, so it survives
/// through the shared components in between.
struct ImageSite: Sendable {
    var screen: String
    var component: String

    static let unknown = ImageSite(screen: "?", component: "?")
}

/// Which layer paid for a resolved image.
enum ImageDiagnosticsSource: String, Sendable {
    case memory
    case disk
    case network
}

/// Bounded, opt-in, on-device instrument for the cover-scroll frame drops.
///
/// The procedure it exists to serve is `docs/IMAGE_SCROLL_PROFILING.md`. That
/// document's phase 1 reads the 2s `[hitch]` line, which is enough to say WHICH
/// class of work correlates with a stall but not enough to say when each unit of
/// work happened relative to a specific stall. This records the individual
/// events with monotonic timestamps so the three manual runs (cold scroll,
/// warm scroll, rapid back-and-forth) can be compared line by line.
///
/// **Two switches, deliberately.**
///  - `isEnabled` (Settings → Image Diagnostics) arms the subsystem: counters
///    accumulate, the frame-pacing link runs, and the overlay may show.
///  - `isCapturing` (Start Capture) additionally appends discrete events to the
///    ring. Counters alone answer "how much"; the ring answers "in what order".
///
/// Both default OFF and neither is `#if DEBUG`: the reproduction happens on a
/// Release build on a real phone, and a diagnostic you cannot arm on the device
/// that reproduces the problem is not a diagnostic.
///
/// **Cost when off.** Every entry point begins with a plain static `Bool` read
/// and returns. No lock, no clock, no hashing — call sites pass the raw URL
/// string and this type hashes it only if it is going to record. A torn read of
/// a `Bool` is harmless (same contract as `PlayerLog.isEnabled`).
///
/// **Cost when on, stated plainly.** It is not free and it perturbs what it
/// measures: an armed run adds, per cover cell, one FNV pass over the URL path
/// and a handful of uncontended `NSLock` acquisitions. Treat absolute
/// milliseconds from an armed run as indicative and compare runs against each
/// other, which is what the A/B/C workflow does. Anything claiming to be a true
/// cost figure has to come from Instruments — see §7 of the runbook for why no
/// app-side seam can straddle the disk read and decode.
///
/// **Privacy.** No URL, no aid/bvid/mid, no filename is ever stored. Each image
/// is identified by an 8-hex-character FNV-1a digest of its URL *path only* —
/// host, query and signature are excluded, so the digest is stable across CDN
/// host rewrites and across launches (unlike `Hasher`, which is per-process
/// seeded), and it cannot be reversed into a URL.
final class ImageDiagnostics: @unchecked Sendable {
    static let shared = ImageDiagnostics()

    static let enabledKey = "image_perf_diagnostics_enabled"
    static let overlayKey = "image_perf_diagnostics_overlay"

    /// Read on every metered image event; written from the main thread by the
    /// Settings toggle.
    private nonisolated(unsafe) static var runtimeEnabled = false
    static var isEnabled: Bool { ExperimentalSettingsPolicy.diagnosticsEnabled && runtimeEnabled }
    @MainActor private static var monitorActivated = false
    @MainActor private static var monitorArmed = false

    /// `isEnabled`, minus A/B arm C (Settings → Image Diagnostics → Suppress
    /// Image Instrumentation). Every entry point below gates on THIS, so the arm
    /// makes the whole per-image instrumentation path a single static `Bool`
    /// read again.
    ///
    /// It is a second switch rather than "just turn `isEnabled` off" because
    /// `isEnabled` also owns the shared frame-pacing display link and therefore
    /// the `[hitch]` line — which is the MEASUREMENT this arm has to be read
    /// against. Turning the instrument off along with the thing it measures
    /// would leave the run with nothing to compare. So: link and stall counting
    /// keep running, per-image bookkeeping stops.
    static var isRecordingImageEvents: Bool {
        isEnabled && ImagePipelinePolicy.emitsImageDiagnostics
    }

    /// Ring recording. Implies `isEnabled` — `startCapture` refuses otherwise,
    /// so a call site that checks only this one cannot record into a disarmed
    /// subsystem.
    nonisolated(unsafe) static var isCapturing = false

    /// Set by `imageDiagnosticsScrollTracking()` from `onScrollPhaseChange`.
    /// Plain `Bool`: read on every metered event, written on phase edges only.
    nonisolated(unsafe) static var isScrolling = false

    // MARK: - Arming

    /// Explicit choices persist; changing policy only projects runtime state.
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
        /// The same call site requested an image at a new box, creating another
        /// cache key/CDN variant. Different call sites may use different boxes
        /// without counting as churn.
        case resize
        case hitMemory = "hit.mem"
        case hitDisk = "hit.disk"
        case miss
        case fail
        case hitch
        /// A loading indicator was actually MINTED — the moment
        /// `LoadingCover`'s 200 ms gate elapsed without the image arriving and
        /// a `ProgressView` (a `UIActivityIndicatorView`) came into existence.
        /// Not "a placeholder appeared": the placeholder is present from frame
        /// zero and is the requirement, whereas the indicator is the thing whose
        /// per-frame creation burst was suspected, so only its creation is an
        /// event.
        case indicator
        case counters
        case note
    }

    struct Event {
        var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var kind: Kind
        var digest: String = ""
        /// Duration in microseconds, or nil when the event is instantaneous.
        var micros: Int?
        var source: ImageDiagnosticsSource?
        /// Native pixel size of the delivered bitmap, when the layer reports it.
        var pixels: CGSize?
        /// Point box the cell actually draws into.
        var rendered: CGSize?
        /// Whether any cell showing this digest was still on screen when the
        /// work finished. Nil when the event is not a completion.
        var visible: Bool?
        /// Which screen the cell was on (`imageDiagnosticsScreen`), and which
        /// call site built it (`#fileID:#line`). Without these, a log of 300
        /// events cannot tell a Home grid cell from a moment thumbnail, so a
        /// re-materialisation problem cannot be attributed to a component.
        var screen: String = ""
        var component: String = ""
        /// Whether a scroll was in progress. The capture had an interval with no
        /// network and no disk activity that still produced 8 stalls — telling
        /// "stalls while scrolling" from "stalls at rest" is what separates
        /// layout cost from delivery cost.
        var scrolling = false
        var detail: String = ""
    }

    /// ~4000 events is a few minutes of ordinary scrolling and stays under
    /// ~1 MB rendered. Image events are far denser than playback ones, hence
    /// the larger ring than `PlaybackDebugRecorder`'s 2500.
    private static let capacity = 4000

    private let lock = NSLock()
    private var events: [Event] = []
    private var head = 0
    private var dropped = 0
    private var startedAtUptime = ProcessInfo.processInfo.systemUptime
    private var startedAtWall = Date()

    /// Live counters. Read by the overlay ~2x/s and snapshotted into the ring
    /// on the frame-pacing window boundary, so the log carries both the
    /// discrete events and the rolling totals they sum to.
    struct Counters: Sendable {
        var body = 0
        var appear = 0
        var gone = 0
        var probe = 0
        var hitMemory = 0
        var hitDisk = 0
        var miss = 0
        var fail = 0
        /// Loading indicators minted. The suspected shape was "~54
        /// `UIActivityIndicatorView`s in one frame"; this is the count that
        /// either shows it or does not, and `stallWindows` says whether they
        /// landed inside a stall.
        var indicators = 0
        var hitches = 0
        var setupMicros = 0
        var completionsWhileOffscreen = 0
        /// Distinct (image, box) cache variants across all call sites.
        var variants = 0
        /// Distinct pictures.
        var distinctImages = 0
        /// Distinct (image, call site) pairs; the non-churn floor for variants.
        var requestStreams = 0
        /// New boxes requested by an existing image/call-site pair.
        var resizes = 0
        /// Requests omitted after the bounded tracking tables reach capacity.
        var untracked = 0
        var stallsWhileScrolling = 0
        var stallsAtRest = 0
    }

    private var counters = Counters()
    /// How many cells currently on screen are showing each digest. The
    /// visible-at-completion field is derived from this rather than from a
    /// view's `@State`, which SwiftUI may already have torn down by the time a
    /// completion callback runs.
    private var liveByDigest: [String: Int] = [:]
    /// Tracks one image at one call site. Screen is excluded so a shared
    /// component's geometry remains comparable across screens.
    private struct RequestStream: Hashable {
        let digest: String
        let component: String
    }

    /// Per-call-site boxes used to diagnose request churn.
    private var boxesByStream: [RequestStream: Set<String>] = [:]
    /// Per-image boxes used to count cache variants across call sites. The
    /// stream table is the admission boundary so both bounded tables agree.
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

    /// Body evaluations. Counter only — one ring entry per render would flood
    /// the log with the highest-frequency and least informative event in the
    /// set. The rolling total lands in every `counters` snapshot instead, which
    /// is what makes repeated-invalidation visible.
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

    /// Wraps the `KFImage` request-builder chain, and is also where a REQUEST is
    /// minted — so it is the right place to notice that this image has been asked
    /// for at a box it has not been asked for before. A pure passthrough when
    /// disarmed.
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
        // Emit a separate event only when this call site adds a new box.
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

    /// A loading indicator came into existence.
    ///
    /// Called from `LoadingCover` at the one point where the spinner is
    /// actually created — after the 200 ms delay has elapsed AND the sleep was
    /// not cancelled — so the count is indicators, not placeholders. A load
    /// that resolves faster than the gate mints nothing and records nothing,
    /// which is exactly the distinction the "mass spinner creation" suspicion
    /// needs and which no existing counter could make.
    ///
    /// `shorterSide` is carried because the size gate (< 28 pt ⇒ ground only)
    /// means avatar-scale slots can never reach here; a report full of 22 pt
    /// sides would be a bug in that gate rather than a scroll cost.
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

    /// Updates per-stream churn and global variant counters under one lock.
    /// Returns prior boxes only when this call site adds a new box.
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
            // Untracked requests cannot be safely classified as new variants.
            counters.untracked += 1
            return []
        }

        // Count global (image, box) variants independently from per-site churn.
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

        // A new box is churn only within the same call site.
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

    /// Updates counters and the visible-cell census; request boxes stay
    /// isolated to `noteRequest`.
    private func withState(
        _ mutate: (inout Counters, inout [String: Int]) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled else { return }
        mutate(&counters, &liveByDigest)
    }

    // MARK: - Digest

    /// FNV-1a over the URL's PATH only, rendered as 8 hex characters.
    ///
    /// Path only, for three reasons: it excludes the signed query so nothing
    /// sensitive is stored; it is stable when Smart CDN rewrites the host, so
    /// the same image correlates across runs; and it keeps the CDN resize
    /// suffix (`@360w_203h.webp`), which IS part of the request identity.
    /// `Hasher` is deliberately not used — it is seeded per process, so a
    /// digest would not match between the three runs of the workflow.
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

    /// One stall, with the image work that happened INSIDE its gap.
    ///
    /// **Why this exists.** The `[hitch]` line reports `worst=96ms` beside
    /// `img.body=50 img.appear=50 img.hit.disk=50`, and those two halves are
    /// measured over DIFFERENT intervals: the gap is one inter-tick interval,
    /// the counters are a 2 s window. So the line cannot distinguish "all fifty
    /// covers materialised inside that one 96 ms gap" from "fifty covers spread
    /// evenly across two seconds and something else stalled the frame" — and
    /// those two readings point at opposite causes. Every input needed to tell
    /// them apart is already in the ring (each event carries a monotonic
    /// `uptime`, and `noteHitch` records the gap); nothing was computing it.
    struct StallWindow: Sendable {
        /// End of the gap, relative to capture start.
        var atSeconds: TimeInterval
        var gapMilliseconds: Int
        var scrolling: Bool
        var appears = 0
        var setups = 0
        /// Wall time the request builders inside this gap actually measured.
        /// This is the one directly ATTRIBUTED main-thread number in the
        /// report: a gap of 96 ms carrying 300 µs of setup is not a request
        /// building cost, whatever else it is.
        var setupMicros = 0
        var probes = 0
        var indicators = 0
        var memoryHits = 0
        var diskHits = 0
        var misses = 0
        var failures = 0
        /// Native bitmap volume delivered inside the gap. A frame gap is a
        /// PRESENTATION measurement, not a main-thread one, so texture volume
        /// is a candidate cause that no count of events can stand in for.
        var kilopixels = 0

        var completions: Int { memoryHits + diskHits + misses + failures }
    }

    /// The events that fall inside each stall's own gap.
    ///
    /// `events` must be in chronological order, which is what `reportText`'s
    /// unrolled ring already guarantees. A `.hitch` event is timestamped when
    /// the display-link tick FIRED, i.e. at the END of the gap, so the window
    /// is `(uptime - gap, uptime]` — half-open on the left, because an event
    /// landing exactly on that instant belongs to the previous tick interval and
    /// would otherwise be counted twice. Consecutive gaps cannot overlap, so
    /// walking backwards from each hitch until the first event older than its
    /// own start makes the whole scan linear.
    ///
    /// Pure and taking its input, so the attribution can be executed and
    /// asserted off the device — which is the only place it can be checked at
    /// all, since the numbers it derives come from a phone.
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

    /// How long one resolved image took, from the moment its request was BUILT
    /// to the moment its completion landed on main.
    struct CompletionLatency: Sendable {
        var source: ImageDiagnosticsSource
        var seconds: TimeInterval
        var component: String
    }

    /// Request-mint → completion, paired FIFO per digest.
    ///
    /// **What this measures that nothing else does.** `CacheManager.apply()`
    /// passes `.asyncCacheTypeCheck`, which moves the disk probe onto
    /// `ImageCache`'s I/O queue — and because that probe's callback queue is
    /// `.untouch` while `KFImage.Context` unconditionally sets
    /// `.loadDiskFileSynchronously`, the read, the deserialize and
    /// `kf.decoded()`'s redraw all run on that queue too
    /// (ImageCache.swift:746). That queue is SERIAL
    /// (`DispatchQueue(label:)`, ImageCache.swift:199, no `.concurrent`), and
    /// the SwiftUI path installs no staleness checker
    /// (`referenceTaskIdentifierChecker` is passed only by the four UIKit/AppKit
    /// view paths; it is consumed at KingfisherManager.swift:328-333), so
    /// `isSourceTaskStale` is permanently false and nothing queued is ever
    /// abandoned. `ioQueue` also carries every disk STORE
    /// (ImageCache.swift:362), so a network arrival's write queues against the
    /// same reads. A burst of disk
    /// hits therefore completes strictly in submission order, each waiting
    /// behind every predecessor's decode. That queueing delay is invisible to
    /// every existing counter — a disk hit is a disk hit whether it took 4 ms
    /// or 400 — and it is the difference between the two candidate readings of
    /// arm E.
    ///
    /// FIFO rather than most-recent-first for exactly that reason: the queue is
    /// FIFO, so the k-th completion for a digest belongs to the k-th request
    /// for it. Unmatched setups (still in flight when the capture ended) and
    /// unmatched completions (started before it began) are dropped rather than
    /// guessed at — a fabricated pair would show up as a spuriously small
    /// latency, which is the direction that would hide the effect.
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

    /// `LoadingCover`'s own delay gate, restated here because it is what makes
    /// the tail of the latency distribution actionable rather than merely
    /// interesting: a request that resolves faster than this mints no indicator
    /// at all, so `>=200ms` is the exact population that can produce a spinner
    /// burst. Keep the two in step — a divergence would make this column claim
    /// a threshold the view does not use.
    static let indicatorGateSeconds: TimeInterval = 0.200

    /// Nearest-rank percentile over an already-sorted array.
    static func percentile(_ sorted: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// One line per cache class: how many, how fast, and how many crossed the
    /// indicator gate.
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
            // Which call site owned the slowest one. A distribution without a
            // component cannot be acted on: "disk max 285 ms" is a number,
            // "disk max 285 ms on GridVideoCardView.swift:24" is a place to
            // look, and the two surfaces differ by whether they even state a
            // request box.
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

    /// Plain text, one event per line, oldest first, timestamps relative to
    /// capture start. Built to be pasted back verbatim.
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
        // Which A/B arms were active. A capture that cannot state its own
        // configuration cannot be compared against another one, and the whole
        // point of the arms is comparison.
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
        // Layered call sites may add legitimate variants, so compare against
        // distinct (image, call-site) streams rather than images.
        if totals.requestStreams > 0 {
            let ratio = Double(totals.variants) / Double(totals.requestStreams)
            out += String(format: "  variants-per-stream=%.2f", ratio)
            out += ratio > 1.05 ? "  <-- GEOMETRY CHURN\n" : "\n"
        } else {
            out += "\n"
        }

        // Report per-call-site box changes; independent layers stay separate.
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

        // WHAT WAS INSIDE THE WORST GAPS. The `[hitch]` line's `worst=` and its
        // `bodies[…]` counts are measured over different intervals — one
        // inter-tick gap versus a 2 s window — so that line cannot say whether
        // the covers it counted are the covers the gap paid for. These rows can,
        // because every event already carries a monotonic timestamp.
        //
        // Read `setup=` first: it is the only column that is a MEASURED
        // main-thread duration rather than a count, so it bounds from below how
        // much of the gap belongs to this app's own request building. A 96 ms
        // gap carrying 0.3 ms of setup is not a request-building cost.
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

        // HOW LONG EACH RESOLVED IMAGE TOOK. See `completionLatencies` for what
        // this measures and why the serial I/O queue makes it the readout for
        // A/B arm E: with the arm ON a disk burst must show a climbing tail,
        // with it OFF the disk column collapses towards the memory column
        // because the read happens inline on the calling thread. The `>=` column
        // is the population that can mint a loading indicator at all.
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
