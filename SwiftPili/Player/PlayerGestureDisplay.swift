import Foundation
import Observation

@Observable
final class PlayerGestureDisplay {
    var isSeeking = false
    var seekValue: TimeInterval = 0
    var verticalAdjustValue: Double = 0

    func scrub(fraction: Double, duration: TimeInterval) {
        if !isSeeking { isSeeking = true }
        seekValue = fraction * max(duration, 1)
    }

    func commitSeek(_ commit: (TimeInterval) -> Void) {
        commit(seekValue)
        isSeeking = false
    }

    func cancelSeek() {
        isSeeking = false
    }
}
