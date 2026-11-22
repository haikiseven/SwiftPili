import Foundation

// Foundation-only support for the Demand seek / resume-open fast preroll
// (task 10-03-demand-seek-long-preroll, design.md). Everything here is pure so
// it type-checks and runs without an SDK; the session and the VideoToolbox
// decoder own every side effect.

/// The output-floor rule, as one pure function shared by every caller.
///
/// `MediaEngineSession.isVideoFrameUsableAtOutputFloor` delegates here, and the
/// fast preroll uses `isPreTarget` — the negation of the rule's FIRST clause —
/// to decide which compressed samples may be withheld from the decoder. A
/// sample may be withheld only when its own output would be discarded by the
/// floor anyway, so the two decisions must be one definition, not two copies.
enum OutputFloorPolicy {
    /// A decoded frame may reach the pending queue / renderer only when it
    /// starts at or after the floor. A frame that starts before the floor is
    /// late even when its interval crosses it: the output-floor contract
    /// suppresses it so the renderer never receives old content against a
    /// later timebase.
    static func isUsable(
        pts: TimeInterval,
        duration: TimeInterval,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard pts.isFinite, duration.isFinite, duration > 0 else { return false }
        let end = pts + duration
        guard end.isFinite else { return false }
        return pts + epsilon >= floor && end + epsilon >= floor
    }

    /// A compressed sample is PRE-TARGET when its presentation time is below
    /// the floor. Presentation time, not decode time: under B-frame reorder a
    /// sample decoded before the target can be displayed after it. A
    /// non-finite PTS is never pre-target (fail closed: it is decoded).
    static func isPreTarget(
        pts: TimeInterval,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard pts.isFinite, floor.isFinite else { return false }
        return pts + epsilon < floor
    }
}

/// `PATHA_SEEK_FAST_PREROLL=0` (exact string) restores the legacy synchronous,
/// decode-every-sample preroll for seeks AND resume opens. Any other value, or
/// no value, keeps the approved default (on). Same exact-string rule as
/// `PATHA_BYTE_CACHE`.
enum SeekFastPrerollSwitch {
    static let environmentKey = "PATHA_SEEK_FAST_PREROLL"

    static func isEnabled(environment: [String: String]) -> Bool {
        !ExperimentalSettingsPolicy.diagnosticsEnabled || environment[environmentKey] != "0"
    }

    static var processDefault: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }
}

/// Per-native-session decode anomaly counters (design C11, review decision
/// OI-9). Counting only: none of these changes what the decoder does with the
/// frame — `kVTVideoDecoderReferenceMissingErr` stays a dropped frame, the
/// `frameDropped` info flag stays a non-fault. A classifier mistake (a
/// reference sample withheld) can surface only here, so acceptance requires
/// all four to stay 0 with fast preroll on.
struct VideoDecodeAnomalyCounters: Equatable, Sendable {
    /// `kVTVideoDecoderReferenceMissingErr` (VTErrors.h). Spelled as a literal
    /// so this type stays Foundation-only.
    static let referenceMissingStatus: Int32 = -17694
    /// `kVTDecodeInfo_FrameDropped` (VTDecompressionProperties.h): bit 1.
    static let frameDroppedInfoFlag: UInt32 = 1 << 1

    var referenceMissing = 0
    var frameDropped = 0
    var decodeErrors = 0
    var noImageOutputs = 0

    init(
        referenceMissing: Int = 0,
        frameDropped: Int = 0,
        decodeErrors: Int = 0,
        noImageOutputs: Int = 0
    ) {
        self.referenceMissing = referenceMissing
        self.frameDropped = frameDropped
        self.decodeErrors = decodeErrors
        self.noImageOutputs = noImageOutputs
    }

    /// One output callback. `isFault` is the decoder's own classification of
    /// `status` (ReferenceMissing is never a fault). `truncated` marks a
    /// submission cut to its reference prefix: such an AV1 temporal unit has
    /// no shown frame, so a callback without an image is expected there.
    mutating func noteCallback(
        status: Int32,
        infoFlags: UInt32,
        imagePresent: Bool,
        truncated: Bool,
        isFault: Bool
    ) {
        if status == Self.referenceMissingStatus {
            referenceMissing += 1
        } else if isFault {
            decodeErrors += 1
        }
        let dropped = infoFlags & Self.frameDroppedInfoFlag != 0
        if dropped {
            frameDropped += 1
        }
        if status == 0, !imagePresent, !dropped, !truncated {
            noImageOutputs += 1
        }
    }

    /// A submission status classified as a fault (counted before the throw).
    mutating func noteSubmissionFault() {
        decodeErrors += 1
    }

    /// Field-wise delta, clamped at zero. A baseline taken from a different
    /// native session is meaningless, so callers pass `nil` and get `self`.
    func delta(since baseline: VideoDecodeAnomalyCounters?) -> VideoDecodeAnomalyCounters {
        guard let baseline else { return self }
        return VideoDecodeAnomalyCounters(
            referenceMissing: max(0, referenceMissing - baseline.referenceMissing),
            frameDropped: max(0, frameDropped - baseline.frameDropped),
            decodeErrors: max(0, decodeErrors - baseline.decodeErrors),
            noImageOutputs: max(0, noImageOutputs - baseline.noImageOutputs)
        )
    }
}

/// One priming's video run-up accounting, printed once as
/// `[PathASeekPreroll]` for seeks and for resume opens (design §8.1).
///
/// `submitted` counts every sample handed to the decoder, truncated ones
/// included; `truncated` is the subset that was cut to its reference prefix;
/// `skipped` were never handed over. `items` = `submitted + skipped`, all of
/// them PRE-TARGET packets (whichever path decoded them). In `legacy` mode the
/// same fields come from the synchronous path, so `skipped == 0` and
/// `submitted == items` — before/after captures compare line for line.
struct SeekPrerollStats: Equatable, Sendable {
    enum Mode: String, Sendable { case fast, legacy }
    enum Context: String, Sendable { case seek, open }

    var context: Context
    var mode: Mode
    var codec: String
    var target: TimeInterval
    var anchor: TimeInterval?
    var batches = 0
    var items = 0
    var submitted = 0
    var skipped = 0
    var truncated = 0
    var truncatedBytes = 0
    var discarded = 0
    var kept = 0
    var decodeSeconds: TimeInterval = 0
    var fillSeconds: TimeInterval = 0
    var fills = 0
    var firstTargetSidePTS: TimeInterval?
    var anomalies = VideoDecodeAnomalyCounters()

    init(context: Context, mode: Mode, codec: String, target: TimeInterval) {
        self.context = context
        self.mode = mode
        self.codec = codec
        self.target = target
    }

    mutating func noteAnchor(_ pts: TimeInterval) {
        guard pts.isFinite, anchor == nil else { return }
        anchor = pts
    }

    /// Timeline frames per second through the run-up decode — the number that
    /// sets seek latency (same definition as the host bench). `nil` when
    /// nothing was timed.
    var framesPerSecond: Double? {
        guard decodeSeconds > 0, items > 0 else { return nil }
        return Double(items) / decodeSeconds
    }

    func logLine(token: UInt64?) -> String {
        func t(_ value: TimeInterval?) -> String {
            guard let value, value.isFinite else { return "n/a" }
            return String(format: "%.3f", value)
        }
        func ms(_ seconds: TimeInterval) -> String {
            String(Int((seconds * 1_000).rounded()))
        }
        let runUp = anchor.map { max(0, target - $0) }
        let tokenField = token.map { " token=\($0)" } ?? ""
        return "[PathASeekPreroll] ctx=\(context.rawValue)\(tokenField) mode=\(mode.rawValue) " +
            "codec=\(codec) target=\(t(target)) anchor=\(t(anchor)) " +
            "runUp=\(runUp.map { String(format: "%.3fs", $0) } ?? "n/a") " +
            "batches=\(batches) items=\(items) submitted=\(submitted) " +
            "skipped=\(skipped) truncated=\(truncated) truncBytes=\(truncatedBytes) " +
            "discarded=\(discarded) kept=\(kept) decodeMs=\(ms(decodeSeconds)) " +
            "fillMs=\(ms(fillSeconds)) fills=\(fills) " +
            "fps=\(framesPerSecond.map { String(Int($0.rounded())) } ?? "n/a") " +
            "firstTargetSidePTS=\(t(firstTargetSidePTS)) " +
            "refMissing=\(anomalies.referenceMissing) " +
            "frameDropped=\(anomalies.frameDropped) " +
            "decodeErrors=\(anomalies.decodeErrors) " +
            "noImage=\(anomalies.noImageOutputs)"
    }
}

/// Wall-clock split of one seek between the existing `[PathASeekSession]`
/// phase points (design §8.2), printed once as `[PathASeekPhase]` at the end of
/// `commitPreparedSeek`. Diagnostics only: nothing reads it to decide anything,
/// and a disabled stopwatch takes no timestamps.
struct SeekPhaseStopwatch: Sendable {
    enum Mark: Sendable {
        case demux, flush, gate, stage, commitAck
    }

    let token: UInt64
    let isEnabled: Bool
    private let started: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private(set) var demuxSeconds: TimeInterval = 0
    private(set) var flushSeconds: TimeInterval = 0
    private(set) var prerollSeconds: TimeInterval = 0
    private(set) var runwaySeconds: TimeInterval = 0
    private(set) var audioSeconds: TimeInterval = 0
    private(set) var gateSeconds: TimeInterval = 0
    private(set) var stageSeconds: TimeInterval = 0
    private(set) var commitAckSeconds: TimeInterval = 0

    init(token: UInt64, isEnabled: Bool) {
        self.token = token
        self.isEnabled = isEnabled
        let now: ContinuousClock.Instant? = isEnabled ? .now : nil
        started = now
        last = now
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Close the segment that ends at a sequential phase point.
    mutating func mark(_ mark: Mark) {
        guard isEnabled, let last else { return }
        let now = ContinuousClock.now
        let elapsed = Self.seconds(last.duration(to: now))
        switch mark {
        case .demux: demuxSeconds += elapsed
        case .flush: flushSeconds += elapsed
        case .gate: gateSeconds += elapsed
        case .stage: stageSeconds += elapsed
        case .commitAck: commitAckSeconds += elapsed
        }
        self.last = now
    }

    /// Sub-phases inside priming (accumulated across passes). They do not
    /// move the sequential cursor: `gate` still covers the whole priming.
    mutating func addPreroll(_ seconds: TimeInterval) { prerollSeconds += max(0, seconds) }
    mutating func addRunway(_ seconds: TimeInterval) { runwaySeconds += max(0, seconds) }
    mutating func addAudio(_ seconds: TimeInterval) { audioSeconds += max(0, seconds) }

    func logLine(result: Bool, presented: Bool) -> String {
        func ms(_ seconds: TimeInterval) -> String { String(Int((seconds * 1_000).rounded())) }
        let total = started.map { Self.seconds($0.duration(to: .now)) } ?? 0
        return "[PathASeekPhase] token=\(token) result=\(result ? 1 : 0) " +
            "demuxMs=\(ms(demuxSeconds)) flushMs=\(ms(flushSeconds)) " +
            "prerollMs=\(ms(prerollSeconds)) runwayMs=\(ms(runwaySeconds)) " +
            "audioMs=\(ms(audioSeconds)) gateMs=\(ms(gateSeconds)) " +
            "stageMs=\(ms(stageSeconds)) commitAckMs=\(ms(commitAckSeconds)) " +
            "totalMs=\(ms(total)) presented=\(presented ? 1 : 0)"
    }
}

/// Consecutive sub-phase laps inside one priming pass (no timestamps when
/// disabled), so the pass adds no branches for diagnostics.
struct SeekPhaseLap {
    private var last: ContinuousClock.Instant?

    init(isEnabled: Bool) {
        last = isEnabled ? .now : nil
    }

    /// Seconds since the previous split (0 when disabled).
    mutating func split() -> TimeInterval {
        guard let last else { return 0 }
        let now = ContinuousClock.now
        self.last = now
        return SeekPhaseStopwatch.seconds(last.duration(to: now))
    }
}
