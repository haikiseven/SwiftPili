import Foundation

import PiliPlayerApple
import PiliPlayerCore
import PiliPlayerMedia

// MARK: - Package-only runtime and clock seams

package enum PlaybackRuntimeAvailability: Hashable, Sendable {
    case available
    case unavailable
}

package enum PlaybackRuntimeCommand: Hashable, Sendable {
    case open
    case play
    case pause
    case seek
    case setRate
    case stop
    case requestPictureInPicture(PlaybackPictureInPictureRequest)
    case environment(PlaybackEnvironmentEventKind)
    case close
}

package enum PlaybackRuntimeDecision: Hashable, Sendable {
    case accepted
    case acceptedWithCapabilities(Set<PlaybackCapability>)
    case rejected(PlaybackRejection)
    case failed(PlaybackFailure)
    case unavailable
}

package protocol PlaybackRuntime: Sendable {
    var availability: PlaybackRuntimeAvailability { get }
    func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision
}

package protocol PlaybackMonotonicClock: Sendable {
    @MainActor func now() -> Duration
}

package struct SystemPlaybackMonotonicClock: PlaybackMonotonicClock {
    private let clock: ContinuousClock
    private let origin: ContinuousClock.Instant

    package init() {
        let clock = ContinuousClock()
        self.clock = clock
        self.origin = clock.now
    }

    @MainActor package func now() -> Duration {
        origin.duration(to: clock.now)
    }
}

package struct UnavailablePlaybackRuntime: PlaybackRuntime {
    package let availability: PlaybackRuntimeAvailability = .unavailable

    package init() {}

    package func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision {
        .unavailable
    }
}
