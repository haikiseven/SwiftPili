import Foundation

/// Video decoder stub. Real impl: VideoToolbox (`VTDecompressionSession`).
/// Class (not actor): `MediaVideoFrame` holds non-Sendable `CVPixelBuffer`.
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

/// Audio decoder stub. Real impl: AudioToolbox AAC or FFmpeg audio only.
actor StubAudioDecoder: MediaAudioDecoding {
    func open(formatHint: Data?) async throws {
        _ = formatHint
        throw MediaEngineError.notImplemented("audio decoder")
    }

    func decode(
        _ packet: MediaPacket, pendingDisplaySupport _: AudioPendingDisplaySupport
    ) async throws -> [MediaAudioFrame] {
        _ = packet
        return []
    }

    func flush() async {}
    func close() async {}
}
