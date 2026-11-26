import Foundation
import os

/// Mono Float32 PCM audio chunk captured ahead of playback for on-device speech recognition.
struct AudioPCMSubtitleChunk: Sendable, Equatable {
    let monoSamples: [Float]
    let pts: TimeInterval
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(monoSamples.count) / sampleRate
    }

    var endPTS: TimeInterval {
        pts + duration
    }
}

enum AudioPCMSubtitleDiscontinuityReason: String, Sendable, Equatable {
    case seek
    case streamReset
    case sessionStopped
    case timelineJump
}

enum AudioPCMSubtitleEvent: Sendable, Equatable {
    case pcm(AudioPCMSubtitleChunk)
    case discontinuity(reason: AudioPCMSubtitleDiscontinuityReason, targetPTS: TimeInterval?)
}

/// Lock-protected, non-blocking audio PCM tap positioned at the MediaEngine decode stage.
///
/// When inactive (`continuation == nil`), `ingest` performs a single unfair-lock read (~5ns)
/// with zero allocations and zero downmixing overhead. When active, it downmixes interleaved
/// Float32 PCM to mono and delivers into a bounded `bufferingNewest` `AsyncStream`, so slow
/// speech recognition can never backpressure or stall audio decoding.
final class AudioPCMSubtitleTap: Sendable {
    private struct State: Sendable {
        var continuation: AsyncStream<AudioPCMSubtitleEvent>.Continuation?
        var activeStreamID: UInt64 = 0
        var lastEndPTS: TimeInterval?
        var lastSampleRate: Double?
        var onStreamActivated: (@Sendable (AudioPCMSubtitleTap) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    static let defaultBufferCapacity = 256
    private static let backwardJumpTolerance: TimeInterval = 0.15
    private static let forwardJumpTolerance: TimeInterval = 1.5

    var isActive: Bool {
        state.withLock { $0.continuation != nil }
    }

    /// Registers a callback invoked immediately whenever `makeStream` activates a new consumer,
    /// allowing `MediaEngineSession` to seed unread buffered PCM starting at current `mediaTime`.
    func setOnStreamActivated(_ handler: (@Sendable (AudioPCMSubtitleTap) -> Void)?) {
        state.withLock { $0.onStreamActivated = handler }
    }

    /// Creates a bounded consumer stream for ahead-of-playback PCM events.
    /// Any previously active stream is finished cleanly before installing the new one.
    func makeStream(
        bufferingNewest maxBufferedElements: Int = AudioPCMSubtitleTap.defaultBufferCapacity
    ) -> AsyncStream<AudioPCMSubtitleEvent> {
        let capacity = max(1, maxBufferedElements)
        let (stream, continuation) = AsyncStream<AudioPCMSubtitleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )

        let (previousContinuation, streamID, onActivated) = state.withLock { state -> (
            AsyncStream<AudioPCMSubtitleEvent>.Continuation?,
            UInt64,
            (@Sendable (AudioPCMSubtitleTap) -> Void)?
        ) in
            let previous = state.continuation
            state.activeStreamID &+= 1
            if state.activeStreamID == 0 {
                state.activeStreamID = 1
            }
            let id = state.activeStreamID
            state.continuation = continuation
            state.lastEndPTS = nil
            state.lastSampleRate = nil
            return (previous, id, state.onStreamActivated)
        }

        previousContinuation?.finish()

        continuation.onTermination = { [weak self] _ in
            self?.clearContinuation(matching: streamID)
        }

        onActivated?(self)

        return stream
    }

    /// Yields pre-buffered mono PCM chunks (for example, unread audio already decoded ahead of
    /// playback) into the active consumer stream so speech recognition starts at current media time.
    func seedChunks(_ chunks: [AudioPCMSubtitleChunk]) {
        guard !chunks.isEmpty else { return }
        let activeStreamID = state.withLock { state -> UInt64? in
            guard state.continuation != nil else { return nil }
            return state.activeStreamID
        }
        guard let activeStreamID else { return }

        for chunk in chunks {
            guard !chunk.monoSamples.isEmpty,
                  chunk.pts.isFinite,
                  chunk.sampleRate.isFinite,
                  chunk.sampleRate > 0 else {
                continue
            }
            let delivery = state.withLock { state -> (
                continuation: AsyncStream<AudioPCMSubtitleEvent>.Continuation,
                emitTimelineJump: Bool
            )? in
                guard state.activeStreamID == activeStreamID,
                      let continuation = state.continuation else {
                    return nil
                }
                let sampleRateChanged = state.lastSampleRate.map { abs($0 - chunk.sampleRate) > 0.5 } ?? false
                let ptsJumped: Bool
                if let lastEndPTS = state.lastEndPTS {
                    ptsJumped = chunk.pts < lastEndPTS - Self.backwardJumpTolerance
                        || chunk.pts > lastEndPTS + Self.forwardJumpTolerance
                } else {
                    ptsJumped = false
                }
                state.lastEndPTS = chunk.endPTS
                state.lastSampleRate = chunk.sampleRate
                return (continuation, sampleRateChanged || ptsJumped)
            }
            guard let delivery else { return }
            if delivery.emitTimelineJump {
                delivery.continuation.yield(.discontinuity(reason: .timelineJump, targetPTS: chunk.pts))
            }
            delivery.continuation.yield(.pcm(chunk))
        }
    }

    /// Stops forwarding audio and finishes any active consumer stream.
    func deactivate() {
        let previous = state.withLock { state -> AsyncStream<AudioPCMSubtitleEvent>.Continuation? in
            let existing = state.continuation
            state.activeStreamID &+= 1
            state.continuation = nil
            state.lastEndPTS = nil
            state.lastSampleRate = nil
            return existing
        }
        previous?.finish()
    }

    /// Notifies the active consumer that the decoded audio timeline was reset or seeked.
    func notifyDiscontinuity(
        reason: AudioPCMSubtitleDiscontinuityReason,
        targetPTS: TimeInterval? = nil
    ) {
        let continuation = state.withLock { state -> AsyncStream<AudioPCMSubtitleEvent>.Continuation? in
            state.lastEndPTS = nil
            return state.continuation
        }
        continuation?.yield(.discontinuity(reason: reason, targetPTS: targetPTS))
    }

    /// Non-blocking decode hot-path entry point.
    ///
    /// Returns immediately with zero allocations when no speech consumer is attached.
    func ingest(
        pcm: Data,
        pts: TimeInterval,
        sampleRate: Double,
        channels: Int,
        trimmedLeadingFrames: Int = 0
    ) {
        // Fast path: single unfair-lock read when inactive (~5ns, zero allocation).
        let activeStreamID = state.withLock { state -> UInt64? in
            guard state.continuation != nil else { return nil }
            return state.activeStreamID
        }
        guard let activeStreamID else { return }

        guard pts.isFinite,
              sampleRate.isFinite,
              sampleRate > 0,
              channels > 0 else {
            return
        }

        let skipFrames = max(0, trimmedLeadingFrames)
        let monoSamples = Self.downmixInterleavedFloat32ToMono(
            pcm: pcm,
            channels: channels,
            skipLeadingFrames: skipFrames
        )
        guard !monoSamples.isEmpty else { return }

        let effectivePTS = pts + Double(skipFrames) / sampleRate
        let chunk = AudioPCMSubtitleChunk(
            monoSamples: monoSamples,
            pts: effectivePTS,
            sampleRate: sampleRate
        )

        let delivery = state.withLock { state -> (
            continuation: AsyncStream<AudioPCMSubtitleEvent>.Continuation,
            emitTimelineJump: Bool
        )? in
            guard state.activeStreamID == activeStreamID,
                  let continuation = state.continuation else {
                return nil
            }
            let sampleRateChanged = state.lastSampleRate.map { abs($0 - sampleRate) > 0.5 } ?? false
            let ptsJumped: Bool
            if let lastEndPTS = state.lastEndPTS {
                ptsJumped = effectivePTS < lastEndPTS - Self.backwardJumpTolerance
                    || effectivePTS > lastEndPTS + Self.forwardJumpTolerance
            } else {
                ptsJumped = false
            }
            state.lastEndPTS = chunk.endPTS
            state.lastSampleRate = sampleRate
            return (continuation, sampleRateChanged || ptsJumped)
        }

        guard let delivery else { return }
        if delivery.emitTimelineJump {
            delivery.continuation.yield(.discontinuity(reason: .timelineJump, targetPTS: effectivePTS))
        }
        delivery.continuation.yield(.pcm(chunk))
    }

    /// Downmixes interleaved Float32 PCM bytes into mono Float32 samples.
    static func downmixInterleavedFloat32ToMono(
        pcm: Data,
        channels: Int,
        skipLeadingFrames: Int = 0
    ) -> [Float] {
        guard channels > 0, !pcm.isEmpty else { return [] }
        let bytesPerSample = MemoryLayout<Float>.size
        let frameStrideBytes = channels * bytesPerSample
        guard frameStrideBytes > 0, pcm.count >= frameStrideBytes else { return [] }

        let totalFrames = pcm.count / frameStrideBytes
        let startFrame = max(0, skipLeadingFrames)
        guard startFrame < totalFrames else { return [] }
        let frameCount = totalFrames - startFrame

        return pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            let startOffset = startFrame * channels
            let isAligned = Int(bitPattern: base) % MemoryLayout<Float>.alignment == 0

            if isAligned {
                let floatPtr = base.assumingMemoryBound(to: Float.self)
                if channels == 1 {
                    return Array(UnsafeBufferPointer(start: floatPtr.advanced(by: startOffset), count: frameCount))
                }
                return [Float](unsafeUninitializedCapacity: frameCount) { outBuffer, initializedCount in
                    if channels == 2 {
                        var src = startOffset
                        for frame in 0..<frameCount {
                            outBuffer[frame] = (floatPtr[src] + floatPtr[src + 1]) * 0.5
                            src += 2
                        }
                    } else {
                        let invChannels = 1.0 / Float(channels)
                        var src = startOffset
                        for frame in 0..<frameCount {
                            var sum: Float = 0
                            for ch in 0..<channels {
                                sum += floatPtr[src + ch]
                            }
                            outBuffer[frame] = sum * invChannels
                            src += channels
                        }
                    }
                    initializedCount = frameCount
                }
            }

            let invChannels = 1.0 / Float(channels)
            return [Float](unsafeUninitializedCapacity: frameCount) { outBuffer, initializedCount in
                var byteOffset = startOffset * bytesPerSample
                for frame in 0..<frameCount {
                    if channels == 1 {
                        outBuffer[frame] = raw.loadUnaligned(fromByteOffset: byteOffset, as: Float.self)
                        byteOffset += bytesPerSample
                    } else if channels == 2 {
                        let l = raw.loadUnaligned(fromByteOffset: byteOffset, as: Float.self)
                        let r = raw.loadUnaligned(fromByteOffset: byteOffset + bytesPerSample, as: Float.self)
                        outBuffer[frame] = (l + r) * 0.5
                        byteOffset += frameStrideBytes
                    } else {
                        var sum: Float = 0
                        for ch in 0..<channels {
                            sum += raw.loadUnaligned(
                                fromByteOffset: byteOffset + ch * bytesPerSample,
                                as: Float.self
                            )
                        }
                        outBuffer[frame] = sum * invChannels
                        byteOffset += frameStrideBytes
                    }
                }
                initializedCount = frameCount
            }
        }
    }

    private func clearContinuation(matching streamID: UInt64) {
        state.withLock { state in
            guard state.activeStreamID == streamID else { return }
            state.continuation = nil
            state.lastEndPTS = nil
            state.lastSampleRate = nil
        }
    }
}
