import Foundation

enum OutputFloorPolicy {
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

    static func isPreTarget(
        pts: TimeInterval,
        floor: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard pts.isFinite, floor.isFinite else { return false }
        return pts + epsilon < floor
    }
}

enum SeekFastPrerollSwitch {
    static let environmentKey = "PATHA_SEEK_FAST_PREROLL"

    static func isEnabled(environment: [String: String]) -> Bool {
        !ExperimentalSettingsPolicy.diagnosticsEnabled || environment[environmentKey] != "0"
    }

    static var processDefault: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }
}

struct VideoDecodeAnomalyCounters: Equatable, Sendable {
    static let referenceMissingStatus: Int32 = -17694
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

    mutating func noteSubmissionFault() {
        decodeErrors += 1
    }

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

struct SeekPhaseLap {
    private var last: ContinuousClock.Instant?

    init(isEnabled: Bool) {
        last = isEnabled ? .now : nil
    }

    mutating func split() -> TimeInterval {
        guard let last else { return 0 }
        let now = ContinuousClock.now
        self.last = now
        return SeekPhaseStopwatch.seconds(last.duration(to: now))
    }
}
