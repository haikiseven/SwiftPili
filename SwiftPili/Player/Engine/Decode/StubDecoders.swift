import Foundation

final class StubVideoDecoder: MediaVideoDecoding, @unchecked Sendable {
    func open(formatHint: Data?) async throws {
        _ = formatHint
        throw MediaEngineError.notImplemented("VideoToolbox decoder")
    }

    func decode(_ packet: MediaPacket) async throws -> [MediaVideoFrame] {
        _ = packet
        return []
    }

    func flush() async {}
    func close() async {}
}

actor StubAudioDecoder: MediaAudioDecoding {
    func open(formatHint: Data?) async throws {
        _ = formatHint
        throw MediaEngineError.notImplemented("audio decoder")
    }

    func decode(_ packet: MediaPacket) async throws -> [MediaAudioFrame] {
        _ = packet
        return []
    }

    func flush() async {}
    func close() async {}
}
