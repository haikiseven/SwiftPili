import Foundation
import Observation

/// Stable, view-local samples. The player root observes only the seeking edge;
/// the seek strip/time row and HUD bodies observe the displayed values.
/// Like the existing raw drag store, initialization is not actor isolated.
@Observable
final class PlayerGestureDisplay {
    var isSeeking = false
    var seekValue: TimeInterval = 0
    var verticalAdjustValue: Double = 0

    func scrub(fraction: Double, duration: TimeInterval) {
        if !isSeeking { isSeeking = true }
        seekValue = fraction * max(duration, 1)
    }

    /// CompactSeekBar calls this on its existing GestureState reset, including
    /// system cancellation. Keep the displayed target through the callback.
    func commitSeek(_ commit: (TimeInterval) -> Void) {
        commit(seekValue)
        isSeeking = false
    }

    /// A cancelled surface gesture hides its sample without issuing a seek.
    func cancelSeek() {
        isSeeking = false
    }
}
