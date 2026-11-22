import Foundation

@MainActor
final class PlaceholderAudioRenderer: MediaAudioRendering {
    private(set) var isRunning = false
    var playbackRate: Float = 1
    var volume: Float = 1
    var isMuted = false
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
