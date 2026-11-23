import Foundation
import os

final class AudioTimelinePCMSupply: AudioSupplySource {
    private let state: OSAllocatedUnfairLock<AudioTimelineBuffer>

    init(
        defaultSampleRate: Double,
        defaultChannels: Int,
        timelineEpsilon: TimeInterval
    ) {
        state = OSAllocatedUnfairLock(
            initialState: AudioTimelineBuffer(
                defaultSampleRate: defaultSampleRate,
                defaultChannels: defaultChannels,
                timelineEpsilon: timelineEpsilon
            )
        )
    }

    var contentSeconds: TimeInterval { state.withLock { $0.contentSeconds } }
    var endPTS: TimeInterval? { state.withLock { $0.endPTS } }
    var insertedGapFrameCount: Int { state.withLock { $0.insertedGapFrameCount } }
    var droppedOverlapFrameCount: Int { state.withLock { $0.droppedOverlapFrameCount } }

    func append(
        pcm: Data,
        pts: TimeInterval,
        context: AudioPCMAppend
    ) -> AudioTimelineBuffer.AppendResult {
        state.withLock {
            $0.append(
                pcm: pcm,
                pts: pts,
                context: context
            )
        }
    }

    func reset() {
        state.withLock { $0.reset() }
    }

    func rollback(seconds: TimeInterval) -> TimeInterval {
        state.withLock { $0.rollback(seconds: seconds) }
    }

    // MARK: - AudioSupplySource

    func pullContent(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioSupplyPull {
        nonisolated(unsafe) let buffer = buffer
        return state.withLock {
            $0.pull(
                frameCount: frameCount,
                sampleRate: sampleRate,
                channels: channels,
                into: buffer
            )
        }
    }
}
