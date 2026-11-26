import Foundation
import os

final class AudioTimelinePCMSupply: AudioSupplySource {
    private struct SyntheticSilenceState: Sendable {
        var enabled = false
        var currentPTS: TimeInterval = 0
        var maxDuration: TimeInterval = 0
        var exhausted = false
    }

    private struct State: Sendable {
        var buffer: AudioTimelineBuffer
        var syntheticSilence = SyntheticSilenceState()
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        defaultSampleRate: Double,
        defaultChannels: Int,
        timelineEpsilon: TimeInterval
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                buffer: AudioTimelineBuffer(
                    defaultSampleRate: defaultSampleRate,
                    defaultChannels: defaultChannels,
                    timelineEpsilon: timelineEpsilon
                )
            )
        )
    }

    var contentSeconds: TimeInterval {
        state.withLock { s in
            if s.syntheticSilence.enabled {
                guard !s.syntheticSilence.exhausted else { return 0 }
                if s.syntheticSilence.maxDuration > 0 {
                    return min(4.0, max(0, s.syntheticSilence.maxDuration - s.syntheticSilence.currentPTS))
                }
                return 4.0
            }
            return s.buffer.contentSeconds
        }
    }

    var endPTS: TimeInterval? {
        state.withLock { s in
            s.syntheticSilence.enabled ? s.syntheticSilence.currentPTS : s.buffer.endPTS
        }
    }

    var insertedGapFrameCount: Int { state.withLock { $0.buffer.insertedGapFrameCount } }
    var droppedOverlapFrameCount: Int { state.withLock { $0.buffer.droppedOverlapFrameCount } }

    func configureSyntheticSilence(
        enabled: Bool,
        startPTS: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        state.withLock { s in
            if enabled {
                s.buffer.reset()
                s.syntheticSilence = SyntheticSilenceState(
                    enabled: true,
                    currentPTS: max(0, startPTS),
                    maxDuration: max(0, duration),
                    exhausted: false
                )
            } else {
                s.syntheticSilence = SyntheticSilenceState()
            }
        }
    }

    func markSyntheticSilenceExhausted() {
        state.withLock { s in
            if s.syntheticSilence.enabled {
                s.syntheticSilence.exhausted = true
            }
        }
    }

    func append(
        pcm: Data,
        pts: TimeInterval,
        context: AudioPCMAppend
    ) -> AudioTimelineBuffer.AppendResult {
        state.withLock {
            $0.buffer.append(
                pcm: pcm,
                pts: pts,
                context: context
            )
        }
    }

    func reset() {
        state.withLock {
            $0.buffer.reset()
            $0.syntheticSilence = SyntheticSilenceState()
        }
    }

    func snapshotUnreadMonoChunks(
        maxSeconds: TimeInterval = 12.0,
        chunkFrames: Int = 8_192
    ) -> [AudioPCMSubtitleChunk] {
        state.withLock { s in
            guard !s.syntheticSilence.enabled else { return [] }
            return s.buffer.snapshotUnreadMonoChunks(maxSeconds: maxSeconds, chunkFrames: chunkFrames)
        }
    }

    // MARK: - AudioSupplySource

    func pullContent(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioSupplyPull {
        nonisolated(unsafe) let buffer = buffer
        return state.withLock { s in
            if s.syntheticSilence.enabled {
                guard frameCount > 0,
                      sampleRate > 0,
                      channels > 0,
                      !s.syntheticSilence.exhausted else {
                    return AudioSupplyPull(frames: 0)
                }
                let framesToProduce: Int
                if s.syntheticSilence.maxDuration > 0 {
                    let remaining = s.syntheticSilence.maxDuration - s.syntheticSilence.currentPTS
                    guard remaining > 1e-6 else {
                        s.syntheticSilence.exhausted = true
                        return AudioSupplyPull(frames: 0)
                    }
                    let maxFrames = max(1, Int((remaining * sampleRate).rounded(.up)))
                    framesToProduce = min(frameCount, maxFrames)
                } else {
                    framesToProduce = frameCount
                }
                buffer.update(repeating: 0, count: framesToProduce * channels)
                s.syntheticSilence.currentPTS += TimeInterval(framesToProduce) / sampleRate
                if s.syntheticSilence.maxDuration > 0,
                   s.syntheticSilence.currentPTS >= s.syntheticSilence.maxDuration - 1e-6 {
                    s.syntheticSilence.exhausted = true
                }
                return AudioSupplyPull(frames: framesToProduce)
            }
            return s.buffer.pull(
                frameCount: frameCount,
                sampleRate: sampleRate,
                channels: channels,
                into: buffer
            )
        }
    }
}
