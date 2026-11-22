import Foundation

/// Pure near-EOF display clock helpers.
/// Media truth is never derived from wall clock; display may pin to a seek
/// target or a temporary near-EOF value once media freezes inside `stallWindow`.
enum NearEndClockPolicy {
    /// Eligibility window before `duration` (covers typical ~4s DASH tail gaps).
    static let stallWindow: TimeInterval = 8
    /// Media must remain frozen this long while playing before wall
    /// presentation may arm. Being "in window" alone is not enough (A3).
    static let freezeThreshold: TimeInterval = 0.4
    /// Minimum remaining media time still treated as "near end" (not finished).
    static let minRemaining: TimeInterval = 0.05

    /// True when media sits inside the near-EOF eligibility window.
    static func isInNearEndWindow(media: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 0 else { return false }
        let remaining = duration - media
        return remaining <= stallWindow && remaining > minRemaining
    }

    /// Arm wall presentation only after a real freeze while eligible (A3).
    /// - Parameters:
    ///   - media: Latest media sample.
    ///   - duration: Declared duration.
    ///   - freezeDuration: How long media has not advanced while playing.
    ///   - isPlaying: Transport / intent is live (not paused / seek / ended).
    static func shouldArmPresentation(
        media: TimeInterval,
        duration: TimeInterval,
        freezeDuration: TimeInterval,
        isPlaying: Bool
    ) -> Bool {
        guard isPlaying else { return false }
        guard isInNearEndWindow(media: media, duration: duration) else { return false }
        return freezeDuration >= freezeThreshold
    }

    /// Priority: ended → duration; seek pin; near-EOF display; else mediaTime.
    static func resolveDisplayTime(
        playbackEnded: Bool,
        duration: TimeInterval,
        pendingSeek: TimeInterval?,
        nearEndDisplay: TimeInterval?,
        mediaTime: TimeInterval
    ) -> TimeInterval {
        if playbackEnded, duration > 0 { return duration }
        if let pending = pendingSeek { return pending }
        if let shown = nearEndDisplay { return shown }
        return mediaTime
    }
}
