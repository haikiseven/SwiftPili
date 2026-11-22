import Foundation

/// No-op audio graph until pull renderer lands.
@MainActor
final class PlaceholderAudioRenderer: MediaAudioRendering {
    private(set) var isRunning = false
    var playbackRate: Float = 1
    var volume: Float = 1
    var isMuted = false
    /// Never holds PCM: `start` always fails before any is accepted.
    var hasPendingOutput: Bool { false }

    func start(source: AudioPullSource) throws {
        _ = source
        throw MediaEngineError.notImplemented("audio pull renderer")
    }

    func stop() {
        isRunning = false
    }

    func flush() {}
}
