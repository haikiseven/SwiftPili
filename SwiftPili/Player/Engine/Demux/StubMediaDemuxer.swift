import Foundation

actor StubMediaDemuxer: MediaDemuxing {
    func multiConnectionTelemetry() async -> MultiConnectionTelemetry { .unsupported }
    func setMultiConnectionQuiet(_ quiet: Bool) async {}
    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async {}
    func cancelMultiConnectionPrefetching() async {}

    private(set) var duration: TimeInterval = 0
    private(set) var isEOF = false
    private var opened = false

    func open(_ request: MediaOpenRequest) async throws {
        _ = request
        opened = false
        duration = 0
        isEOF = true
        throw MediaEngineError.notImplemented(
            "FFmpeg demux not linked yet (Path A A1b). Use libVLC for VOD."
        )
    }

    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket] {
        _ = contentBudget
        guard opened else {
            throw MediaEngineError.stopped
        }
        return []
    }

    func seek(to mediaTime: TimeInterval) async throws {
        _ = mediaTime
        throw MediaEngineError.notImplemented("demux seek")
    }

    func close() async {
        opened = false
        isEOF = true
    }
}
