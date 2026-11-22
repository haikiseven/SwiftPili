import Foundation

struct MediaClock: Equatable, Sendable {
    private(set) var mediaTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var playbackRate: Float = 1

    mutating func reset(start: TimeInterval = 0, duration: TimeInterval = 0) {
        mediaTime = max(0, start)
        self.duration = max(0, duration)
        playbackRate = 1
    }

    mutating func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0, rate)
    }

    mutating func setDuration(_ d: TimeInterval) {
        duration = max(0, d)
    }

    mutating func seek(to time: TimeInterval) {
        let t = max(0, time)
        mediaTime = duration > 0 ? min(t, duration) : t
    }

    mutating func advanceContent(by contentSeconds: TimeInterval) {
        guard contentSeconds > 0 else { return }
        mediaTime += contentSeconds
        if duration > 0 {
            mediaTime = min(mediaTime, duration)
        }
    }

    func contentSeconds(forWallDelta wall: TimeInterval) -> TimeInterval {
        guard wall > 0 else { return 0 }
        return wall * TimeInterval(max(playbackRate, 0))
    }

    var isAtEnd: Bool {
        duration > 0 && mediaTime >= duration - 0.05
    }
}
