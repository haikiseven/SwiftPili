import Foundation

/// Bounded queue measured in **content seconds** (Path A HWM model).
///
/// Demux fills while `contentSeconds < highWater`; decode/render drain.
/// Unlike libVLC slave demux, capacity is policy, not "one moof ahead of master".
struct ContentSecondQueue: Equatable, Sendable {
    var highWater: TimeInterval
    var lowWater: TimeInterval
    private(set) var contentSeconds: TimeInterval = 0

    init(highWater: TimeInterval = 20, lowWater: TimeInterval = 5) {
        self.highWater = max(highWater, 0.1)
        self.lowWater = min(max(lowWater, 0), self.highWater)
    }

    /// Returns accepted content seconds (may be less if hitting HWM).
    @discardableResult
    mutating func enqueue(content: TimeInterval) -> TimeInterval {
        guard content > 0 else { return 0 }
        let room = max(0, highWater - contentSeconds)
        let accepted = min(content, room)
        contentSeconds += accepted
        return accepted
    }

    /// Returns actual drained amount.
    @discardableResult
    mutating func drain(content: TimeInterval) -> TimeInterval {
        guard content > 0 else { return 0 }
        let drained = min(content, contentSeconds)
        contentSeconds -= drained
        return drained
    }

    mutating func reset() {
        contentSeconds = 0
    }
}
