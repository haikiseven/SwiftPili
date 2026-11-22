/// Lossless request identity supplied by the App for cold-start milestones.
struct MediaEngineTraceID: Hashable, Sendable {
    let rawValue: UInt64
}

/// Existing engine observations; none establishes displayed-picture proof.
enum MediaEngineTraceMilestone: String, Sendable {
    case demandOpenStarted = "demand-open-started"
    case demandDemuxOpenDone = "demand-demux-open-done"
    case demandPrimeDone = "demand-prime-done"
    case demandPlayStarted = "demand-play-started"
    case demandAudioGraphReady = "demand-audio-graph-ready"
    case firstVout = "first-vout"
    case demandFirstVideoSubmit = "demand-first-video-submit"
    case demandFirstVideoOutput = "demand-first-video-output"
    case demandFirstSampleReady = "demand-first-sample-ready"
}

/// Synchronous App trace forwarding at the engine's original mark points.
@MainActor
protocol MediaEngineTracing: AnyObject {
    func mark(_ milestone: MediaEngineTraceMilestone, token: MediaEngineTraceID?)
}
