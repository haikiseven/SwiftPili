import Foundation

// MARK: - Public runtime, event channel, and clock seams

public enum PlaybackRuntimeAvailability: Hashable, Sendable {
    case available
    case unavailable
}

public enum PlaybackSeekMode: Hashable, Sendable {
    case accurate
    case fast
}

public enum PlaybackRuntimeCommand: Hashable, Sendable {
    case open(source: PlaybackSource, configuration: PlaybackConfiguration)
    case play
    case pause
    case seek(to: TimeInterval, mode: PlaybackSeekMode = .accurate)
    case setRate(Float)
    case stop(reason: PlaybackStopReason)
    case requestPictureInPicture(PlaybackPictureInPictureRequest)
    case environment(PlaybackEnvironmentEventKind)
    case close
}

public enum PlaybackRuntimeEvent: Hashable, Sendable {
    case ready(duration: PlaybackDuration? = nil, capabilities: Set<PlaybackCapability>? = nil)
    case buffering(Bool)
    case progress(mediaTime: TimeInterval, duration: PlaybackDuration? = nil)
    case ended
    case failed(PlaybackFailure)
}

public enum PlaybackRuntimeDecision: Hashable, Sendable {
    case accepted
    case acceptedWithCapabilities(Set<PlaybackCapability>)
    case rejected(PlaybackRejection)
    case failed(PlaybackFailure)
    case unavailable
}

public protocol PlaybackRuntime: Sendable {
    var availability: PlaybackRuntimeAvailability { get }
    var runtimeEvents: AsyncStream<PlaybackRuntimeEvent> { get }
    func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision
}

public extension PlaybackRuntime {
    var runtimeEvents: AsyncStream<PlaybackRuntimeEvent> {
        AsyncStream { $0.finish() }
    }
}

public protocol PlaybackMonotonicClock: Sendable {
    @MainActor func now() -> Duration
}

public struct SystemPlaybackMonotonicClock: PlaybackMonotonicClock {
    private let clock: ContinuousClock
    private let origin: ContinuousClock.Instant

    public init() {
        let clock = ContinuousClock()
        self.clock = clock
        self.origin = clock.now
    }

    @MainActor public func now() -> Duration {
        origin.duration(to: clock.now)
    }
}

public struct UnavailablePlaybackRuntime: PlaybackRuntime {
    public let availability: PlaybackRuntimeAvailability = .unavailable

    public init() {}

    public func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision {
        .unavailable
    }
}
