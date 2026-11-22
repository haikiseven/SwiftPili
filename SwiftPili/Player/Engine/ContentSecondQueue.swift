import Foundation

struct ContentSecondQueue: Equatable, Sendable {
    var highWater: TimeInterval
    var lowWater: TimeInterval
    private(set) var contentSeconds: TimeInterval = 0

    init(highWater: TimeInterval = 20, lowWater: TimeInterval = 5) {
        self.highWater = max(highWater, 0.1)
        self.lowWater = min(max(lowWater, 0), self.highWater)
    }

    @discardableResult
    mutating func enqueue(content: TimeInterval) -> TimeInterval {
        guard content > 0 else { return 0 }
        let room = max(0, highWater - contentSeconds)
        let accepted = min(content, room)
        contentSeconds += accepted
        return accepted
    }

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
