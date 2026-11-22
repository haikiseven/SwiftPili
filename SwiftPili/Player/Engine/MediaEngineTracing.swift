struct MediaEngineTraceID: Hashable, Sendable {
    let rawValue: UInt64
}

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

@MainActor
protocol MediaEngineTracing: AnyObject {
    func mark(_ milestone: MediaEngineTraceMilestone, token: MediaEngineTraceID?)
}
