import CoreVideo
import Foundation

final class PassThroughVideoDecoder: MediaVideoDecoding, @unchecked Sendable {
    private let stateLock = NSLock()
    private var opened = false
    private var storedFramesProduced = 0
    var framesProduced: Int { stateLock.withLock { storedFramesProduced } }

    func open(formatHint: Data?) async throws {
        _ = formatHint
        stateLock.withLock {
            opened = true
            storedFramesProduced = 0
        }
    }

    func decode(_ packet: MediaPacket) async throws -> [MediaVideoFrame] {
        try stateLock.withLock {
            guard opened else { throw MediaEngineError.stopped }
            guard packet.track == .video, let pb = packet.pixelBuffer else {
                return []
            }
            storedFramesProduced += 1
            return [
                MediaVideoFrame(
                    pts: packet.pts,
                    duration: max(packet.duration, 0.001),
                    pixelBuffer: pb
                )
            ]
        }
    }

    func flush() async {}
    func close() async { stateLock.withLock { opened = false } }
}

final class PassThroughAudioDecoder: MediaAudioDecoding, @unchecked Sendable {
    private var opened = false
    private(set) var framesProduced = 0

    func open(formatHint: Data?) async throws {
        _ = formatHint
        opened = true
        framesProduced = 0
    }

    func decode(
        _ packet: MediaPacket, pendingDisplaySupport _: AudioPendingDisplaySupport
    ) async throws -> [MediaAudioFrame] {
        guard opened else { throw MediaEngineError.stopped }
        guard packet.track == .audio, !packet.data.isEmpty else {
            return []
        }
        let sr = packet.pcmSampleRate ?? MediaEngineSession.EnginePCM.sampleRate
        let ch = packet.pcmChannelCount ?? MediaEngineSession.EnginePCM.channelCount
        guard ch > 0, sr > 0 else { return [] }
        let sampleCount = packet.data.count / MemoryLayout<Float>.size
        guard sampleCount > 0, sampleCount % ch == 0 else { return [] }
        let frameCount = sampleCount / ch
        let duration = packet.duration > 0
            ? packet.duration
            : TimeInterval(frameCount) / sr
        framesProduced += 1
        return [
            MediaAudioFrame(
                pts: packet.pts,
                duration: duration,
                sampleRate: sr,
                channelCount: ch,
                pcm: packet.data
            )
        ]
    }

    func flush() async {}
    func close() async { opened = false }
}
