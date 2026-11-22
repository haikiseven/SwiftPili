import Foundation

/// Diagnostic call boundaries, never supply/decode admission authority.
enum MediaQueueFillInitiator: String {
    case openPrime = "open-prime"
    case seekPrime = "seek-prime"
    case supplyLoop = "supply-loop"
    case audioRefill = "audio-refill"
    case preroll = "preroll"
    case postPreroll = "post-preroll"
}

enum MediaQueueFillPhase: String {
    case open, seek, playback
}

/// Inventories sampled on the session owner. PCM/ring transfer is concurrent;
/// these components do not promise a contiguous or atomic playable runway.
struct MediaQueueFillSnapshot {
    let videoSeconds: TimeInterval
    let audioSeconds: TimeInterval
    let pcmSeconds: TimeInterval
    let ringSeconds: TimeInterval?
    let videoFrameSeconds: TimeInterval
    let sourceUnderflows: UInt64?

    static func seconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.3f", $0) + "s" } ?? "n/a"
    }

    var fields: String {
        "vQ=\(Self.seconds(videoSeconds)) aQ=\(Self.seconds(audioSeconds)) "
            + "pcmSec=\(Self.seconds(pcmSeconds)) rBuf=\(Self.seconds(ringSeconds)) "
            + "vFramesSec=\(Self.seconds(videoFrameSeconds)) "
            + "srcUF=\(sourceUnderflows.map(String.init) ?? "n/a")"
    }
}

/// Created only during capture. Immutable identity survives an awaited pump;
/// counts distinguish attempts from nonempty returns, not HLS segment commits.
struct MediaQueueFillTrace {
    enum Outcome: String {
        case completed, empty, error, cancelled, superseded
    }

    let generation: Int
    let fillID: UInt64
    let initiator: MediaQueueFillInitiator
    let phase: MediaQueueFillPhase
    let priming: Bool
    let seeking: Bool
    let playing: Bool
    let warmSuspended: Bool
    let entry: MediaQueueFillSnapshot
    let start: ContinuousClock.Instant = .now
    var attempts = 0
    var pumps = 0
    var packets = 0
    var gathered: TimeInterval = 0
    var outcome: Outcome = .completed
    /// The pump's own fault publication can cancel and retire its scheduled
    /// lane without creating a successor operation.
    var initiatedRuntimeFault = false

    private var identityFields: String {
        "gen=\(generation) fillID=\(fillID) initiator=\(initiator.rawValue) "
            + "phase=\(phase.rawValue) priming=\(priming ? 1 : 0) "
            + "seek=\(seeking ? 1 : 0) playing=\(playing ? 1 : 0) "
            + "warm=\(warmSuspended ? 1 : 0)"
    }

    var beginLine: String {
        "[PathA][pace] fill-begin v=\(String(format: "%.1f", entry.videoSeconds))s "
            + "a=\(String(format: "%.1f", entry.audioSeconds))s "
            + identityFields + " " + entry.fields
    }

    func endLine(outcome: Outcome, exit: MediaQueueFillSnapshot?) -> String {
        let elapsedMilliseconds = Int(start.duration(to: .now) / .milliseconds(1))
        let videoExit = exit.map { String(format: "%.1f", $0.videoSeconds) } ?? "n/a"
        let audioExit = exit.map { String(format: "%.1f", $0.audioSeconds) } ?? "n/a"
        let exitFields = exit?.fields
            ?? "vQ=n/a aQ=n/a pcmSec=n/a rBuf=n/a vFramesSec=n/a srcUF=n/a"
        return "[PathA][pace] fill v=\(String(format: "%.1f", entry.videoSeconds))→\(videoExit)s "
            + "a=\(String(format: "%.1f", entry.audioSeconds))→\(audioExit)s "
            + "gathered=\(String(format: "%.2f", gathered))s pkts=\(packets) "
            + "pumps=\(pumps) attempts=\(attempts) in=\(elapsedMilliseconds)ms "
            + identityFields + " outcome=\(outcome.rawValue) " + exitFields
    }
}
