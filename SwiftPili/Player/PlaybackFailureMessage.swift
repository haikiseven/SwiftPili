import Foundation

enum PlaybackFailureMessage {
    static func text(for error: Error) -> String {
        if let engine = error as? MediaEngineError {
            return text(for: engine)
        }
        if error is VLCError {
            return String(localized: "Playback failed. Tap Retry.")
        }
        return String(
            format: String(localized: "Playback error: %@"),
            error.localizedDescription
        )
    }

    private static func text(for error: MediaEngineError) -> String {
        switch error {
        case .notImplemented, .unsupportedLiveSource:
            return String(localized: "The player does not support this video's format.")
        case .decodeFailed:
            return String(localized: "Decoding failed. Tap Retry.")
        case .demuxFailed, .transportFailed, .fMP4InputRejected, .liveInputRejected:
            return String(localized: "The video stream could not be loaded. Tap Retry.")
        case .renderFailed, .stopped:
            return String(localized: "Playback failed. Tap Retry.")
        }
    }
}
