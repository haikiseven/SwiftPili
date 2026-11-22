import Foundation

/// Media timeline for Path A engines (content time, not wall fiction).
///
/// `mediaTime` advances only via `advanceContent(by:)` (rendered content) or
/// explicit `seek` / `setMediaTime`. Multiplies pull demand by `playbackRate`
/// for buffer math — same F1 spirit as ViewModel.mediaTime.
struct MediaClock: Equatable, Sendable {
    private(set) var mediaTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// 1 = realtime content; 2 = twice content per wall second.
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

    /// Pull callback consumed `contentSeconds` of media (already rate-adjusted
    /// by the renderer: wall_dt * rate → content).
    mutating func advanceContent(by contentSeconds: TimeInterval) {
        guard contentSeconds > 0 else { return }
        mediaTime += contentSeconds
        if duration > 0 {
            mediaTime = min(mediaTime, duration)
        }
    }

    /// Content seconds the renderer should pull for a wall-time slice.
    func contentSeconds(forWallDelta wall: TimeInterval) -> TimeInterval {
        guard wall > 0 else { return 0 }
        return wall * TimeInterval(max(playbackRate, 0))
    }

    var isAtEnd: Bool {
        duration > 0 && mediaTime >= duration - 0.05
    }
}
