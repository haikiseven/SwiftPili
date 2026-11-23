import Foundation
import Observation
import QuartzCore

/// High-frequency playback timing and buffer state isolated into its own `@Observable` scope.
///
/// Mutating `mediaTime`, `bufferedTime`, `duration`, or `isBuffering` only invalidates views
/// observing this store (such as seek bars and time readouts) without triggering re-evaluation
/// of chrome, session, or route-ownership observers.
@MainActor
@Observable
final class PlaybackClockState {
    var mediaTime: TimeInterval = 0 {
        didSet {
            if mediaTime == 0 {
                mediaTimeMovedAt = 0
            } else if abs(mediaTime - oldValue) > 0.001 {
                mediaTimeMovedAt = CACurrentMediaTime()
            }
        }
    }

    @ObservationIgnored
    var mediaTimeMovedAt: TimeInterval = 0

    @ObservationIgnored
    var bufferedTimeStorage: TimeInterval = 0

    @ObservationIgnored
    var bufferedTimeProjection = BufferedTimeUIProjection()

    @ObservationIgnored
    var bufferedDisplayDiagnostic: BufferedDisplayDiagnosticSample?

    var bufferedTime: TimeInterval {
        get {
            access(keyPath: \.bufferedTime)
            return bufferedTimeStorage
        }
        set {
            let value = Self.normalizedBufferedTime(newValue)
            resetBufferedTime(raw: value, displayedEnd: value > 0 ? value : nil, isOffline: false)
        }
    }

    var publishedBufferedRange: BufferedDisplayRange? {
        access(keyPath: \.bufferedTime)
        return bufferedTimeProjection.publishedRange
    }

    var duration: TimeInterval = 0
    var isBuffering = false
    var pendingSeekTarget: TimeInterval?
    var nearEndDisplayTime: TimeInterval?
    var settledSeekDisplaySample: PlayerViewModel.SettledSeekDisplaySample?

    @ObservationIgnored
    var lastDisplayUpdate: CFTimeInterval = 0

    static func normalizedBufferedTime(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    func mutateBufferedTime(_ body: () -> Void) {
        withMutation(keyPath: \.bufferedTime, body)
    }

    func resetBufferedTime(raw: TimeInterval, displayedEnd: TimeInterval?, isOffline: Bool) {
        withMutation(keyPath: \.bufferedTime) {
            bufferedTimeStorage = raw
            let range = displayedEnd.flatMap { end in
                BufferedDisplayRange(start: isOffline ? 0 : end, end: end)
            }
            bufferedTimeProjection.reset(range: range)
            bufferedDisplayDiagnostic = nil
        }
    }
}
