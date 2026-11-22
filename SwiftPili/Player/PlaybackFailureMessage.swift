import Foundation

/// The overlay sentence for a terminal backend `.error`.
///
/// `MediaEngineError` and `VLCError` describe themselves for the LOG — "MediaEngine
/// decode: no audio track …", "Playback failed: VLC error" — and every log line in
/// the player reads that text through `localizedDescription`. Painting it into the
/// overlay put an engineering sentence in front of the user. The mapping lives
/// here, at the one place a backend error becomes `PlayerViewModel.error`, and
/// is chosen by failure KIND, so the payload (codec labels, OSStatus values,
/// libVLC reasons) stays in the log where it is useful.
///
/// Any other error keeps the old shape: `URLError` and the system's own errors
/// already carry a localized, user-facing description.
enum PlaybackFailureMessage {
    static func text(for error: Error) -> String {
        if let engine = error as? MediaEngineError {
            return text(for: engine)
        }
        if error is VLCError {
            // libVLC's `encounteredError` carries no cause, and a premature
            // end has already been through the host ladder by the time it
            // reaches the overlay — there is nothing more specific to say.
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
            // A format answer from demux admission or the native decoders.
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
