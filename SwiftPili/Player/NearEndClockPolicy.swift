import Foundation

enum NearEndClockPolicy {
    static let stallWindow: TimeInterval = 8
    static let freezeThreshold: TimeInterval = 0.4
    static let minRemaining: TimeInterval = 0.05

    static func isInNearEndWindow(media: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 0 else { return false }
        let remaining = duration - media
        return remaining <= stallWindow && remaining > minRemaining
    }

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
