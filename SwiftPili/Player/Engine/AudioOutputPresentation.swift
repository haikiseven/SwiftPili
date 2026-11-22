import Foundation

/// A current audio-output timing estimate, never a hardware sample-clock reading.
struct MediaAudioPresentationTiming: Sendable, Equatable {
    enum Basis: Sendable, Equatable {
        case unavailable
        case logical
        case processingOnly
        case outputPipeline
    }

    let basis: Basis
    let wallLatencySeconds: TimeInterval
    let appliedRate: Float
    let contentTimeOffset: TimeInterval

    static let unavailable = Self(basis: .unavailable)
    static let logical = Self(basis: .logical)

    private init(basis: Basis) {
        self.basis = basis
        wallLatencySeconds = 0
        appliedRate = 0
        contentTimeOffset = 0
    }

    /// The cumulative result already contains downstream processing and device
    /// latency. Zero/invalid means that only the existing processor estimate is
    /// available; it is not evidence of zero hardware delay.
    init(outputLatency: TimeInterval, processingLatency: TimeInterval, appliedRate: Float) {
        let hasOutputLatency = outputLatency.isFinite && outputLatency > 0
        let wall = hasOutputLatency ? outputLatency : processingLatency
        let content = wall * TimeInterval(appliedRate)
        guard wall.isFinite, wall >= 0, appliedRate.isFinite, appliedRate >= 0,
              content.isFinite else {
            self = .unavailable
            return
        }
        basis = hasOutputLatency ? .outputPipeline : .processingOnly
        wallLatencySeconds = wall
        self.appliedRate = appliedRate
        contentTimeOffset = content
    }

    var isAvailable: Bool { basis != .unavailable }
}

/// One native timing read supplies all fields of a single presentation decision.
struct MediaAudioPresentationSnapshot: Sendable {
    let timing: MediaAudioPresentationTiming
    let mediaTime: TimeInterval

    init(contentTime: TimeInterval, timing: MediaAudioPresentationTiming) {
        self.timing = timing
        mediaTime = AudioPresentationTiming.presentationMediaTime(
            mediaTime: contentTime, contentTimeOffset: timing.contentTimeOffset
        )
    }
}
