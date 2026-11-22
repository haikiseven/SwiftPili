import Foundation
import os

/// `AudioTimelineBuffer` behind a lock, so the audio ring feeder can pull from its
/// own queue while MainActor keeps appending decoded PCM into it.
///
/// This is the whole of the isolation change on the session side. The timeline
/// arithmetic — gap insertion, overlap trim, preroll drop, format rejection, the
/// `AppendResult` MainActor logs and accounts — stays exactly where it is, inside
/// `AudioTimelineBuffer`, called from MainActor. What moved is only *who may read*.
///
/// **The lock is never taken by the real-time thread.** The render block reads
/// `PCMFloatRing` and `AtomicFloatBox` and nothing else, and
/// `EngineAudioRenderer.makeSourceNode`'s signature is the enforcement — this type
/// is not reachable from its captured state. So `append` growing the heap inside
/// the lock, and `compactIfNeeded`'s memmove, are off-realtime and admissible;
/// contention is MainActor-append against feeder-pull, both non-realtime.
///
/// Before `reset`, callers stand down/invalidate or retire the feeder. Its gate
/// atomically admits/pulls; supply locking alone cannot fence obsolete consumers.
/// Cutover may wait on synchronous work/contention, with no join or time bound.
/// Lock order is gate → supply → display book, with no callbacks into the gate.
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

    // MARK: - AudioSupplySource

    func pullContent(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioSupplyPull {
        // Same assertion as `AudioRingFeeder`'s, for the same reason:
        // `withLock` takes a `@Sendable` closure and a raw pointer is not
        // `Sendable`. The buffer belongs to the caller (the feeder's scratch),
        // is written only by the `pull` below, synchronously under the lock,
        // and does not escape. `swiftc -parse` cannot see this class of error,
        // which is why it survived to the first real compile.
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
