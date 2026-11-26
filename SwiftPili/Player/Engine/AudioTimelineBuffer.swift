import Foundation

struct AudioPCMAppend: Sendable {
    let sampleRate: Double
    let channels: Int
    let outputFloor: TimeInterval
}

struct AudioTimelineContinuity: Equatable, Sendable {
    let snapTolerance: TimeInterval

    func snaps(_ delta: TimeInterval) -> Bool {
        abs(delta) <= snapTolerance
    }

    static func needsPrerollTrim(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds > 1e-9
    }
}

struct AudioTimelineBuffer: Sendable {
    enum Rejection: Equatable, Sendable {
        case invalidPCM
        case nonFinitePTS
        case formatChange(
            expectedSampleRate: Double,
            expectedChannels: Int,
            actualSampleRate: Double,
            actualChannels: Int
        )
        case gapTooLarge(gap: TimeInterval, firstPTS: TimeInterval)
    }

    struct AppendResult: Equatable, Sendable {
        let appendedFrameCount: Int
        let droppedPrerollFrameCount: Int
        let trimmedPrerollSampleFrameCount: Int
        let insertedGapFrameCount: Int
        let droppedOverlapFrameCount: Int
        let expectedStartPTS: TimeInterval?
        let timelineDelta: TimeInterval?
        let rejection: Rejection?
    }

    private let defaultSampleRate: Double
    private let defaultChannels: Int
    private let timelineContinuity: AudioTimelineContinuity
    private let maxGapSeconds: TimeInterval

    private var samples: [Float] = []
    private var readIndex = 0
    private(set) var sampleRate: Double
    private(set) var channels: Int
    private(set) var endPTS: TimeInterval?
    private(set) var insertedGapFrameCount = 0
    private(set) var droppedOverlapFrameCount = 0

    init(
        defaultSampleRate: Double,
        defaultChannels: Int,
        timelineEpsilon: TimeInterval = 0.000_5,
        maxGapSeconds: TimeInterval = 4
    ) {
        self.defaultSampleRate = defaultSampleRate
        self.defaultChannels = defaultChannels
        self.timelineContinuity = AudioTimelineContinuity(snapTolerance: timelineEpsilon)
        self.maxGapSeconds = maxGapSeconds
        sampleRate = defaultSampleRate
        channels = defaultChannels
    }

    var contentSeconds: TimeInterval {
        guard channels > 0, sampleRate > 0 else { return 0 }
        let samplesLeft = max(0, samples.count - readIndex)
        return TimeInterval(samplesLeft / channels) / sampleRate
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        readIndex = 0
        sampleRate = defaultSampleRate
        channels = defaultChannels
        endPTS = nil
        insertedGapFrameCount = 0
        droppedOverlapFrameCount = 0
    }

    mutating func append(
        pcm: Data,
        pts: TimeInterval,
        context: AudioPCMAppend
    ) -> AppendResult {
        guard context.sampleRate.isFinite, context.sampleRate > 0, context.channels > 0 else {
            return rejected(.invalidPCM)
        }
        guard pts.isFinite else {
            return rejected(.nonFinitePTS)
        }

        let rawResult: AppendResult = pcm.withUnsafeBytes { raw in
            guard !raw.isEmpty,
                  raw.count % MemoryLayout<Float>.size == 0,
                  let base = raw.baseAddress?.assumingMemoryBound(to: Float.self)
            else {
                return rejected(.invalidPCM)
            }
            return append(
                samples: UnsafeBufferPointer(
                    start: base,
                    count: raw.count / MemoryLayout<Float>.size
                ),
                pts: pts,
                context: context
            )
        }
        return rawResult
    }

    mutating func pull(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into output: UnsafeMutablePointer<Float>
    ) -> AudioSupplyPull {
        guard frameCount > 0,
              sampleRate > 0,
              channels > 0,
              abs(sampleRate - self.sampleRate) <= 0.5,
              channels == self.channels
        else { return AudioSupplyPull(frames: 0) }

        let samplesLeft = samples.count - readIndex
        let availableFrames = samplesLeft / channels
        let framesToCopy = min(frameCount, availableFrames)
        guard framesToCopy > 0 else { return AudioSupplyPull(frames: 0) }

        let sampleCount = framesToCopy * channels
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            output.update(from: base.advanced(by: readIndex), count: sampleCount)
        }
        readIndex += sampleCount
        compactIfNeeded()
        return AudioSupplyPull(frames: framesToCopy)
    }

    /// Copies currently unread buffered PCM starting at the read head (`readHeadPTS`),
    /// downmixed to mono Float32 chunks suitable for seeding live speech recognition
    /// immediately upon mid-playback activation.
    func snapshotUnreadMonoChunks(
        maxSeconds: TimeInterval = 12.0,
        chunkFrames: Int = 8_192
    ) -> [AudioPCMSubtitleChunk] {
        guard channels > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              let endPTS,
              endPTS.isFinite else {
            return []
        }
        let samplesLeft = samples.count - readIndex
        guard samplesLeft >= channels else { return [] }

        let totalUnreadFrames = samplesLeft / channels
        let framesToCopy: Int
        if maxSeconds.isFinite, maxSeconds > 0 {
            let maxFrames = Int((maxSeconds * sampleRate).rounded(.down))
            framesToCopy = min(totalUnreadFrames, max(0, maxFrames))
        } else {
            framesToCopy = totalUnreadFrames
        }
        guard framesToCopy > 0 else { return [] }

        let readHeadPTS = max(0, endPTS - Double(totalUnreadFrames) / sampleRate)
        let strideFrames = max(256, chunkFrames)
        let ch = channels
        let sr = sampleRate

        var chunks: [AudioPCMSubtitleChunk] = []
        chunks.reserveCapacity((framesToCopy + strideFrames - 1) / strideFrames)

        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            var frameOffset = 0
            while frameOffset < framesToCopy {
                let count = min(strideFrames, framesToCopy - frameOffset)
                let startSample = readIndex + frameOffset * ch
                let mono: [Float]
                if ch == 1 {
                    mono = Array(UnsafeBufferPointer(start: base.advanced(by: startSample), count: count))
                } else {
                    mono = [Float](unsafeUninitializedCapacity: count) { out, initializedCount in
                        if ch == 2 {
                            var src = startSample
                            for i in 0..<count {
                                out[i] = (base[src] + base[src + 1]) * 0.5
                                src += 2
                            }
                        } else {
                            let invCh = 1.0 / Float(ch)
                            var src = startSample
                            for i in 0..<count {
                                var sum: Float = 0
                                for c in 0..<ch {
                                    sum += base[src + c]
                                }
                                out[i] = sum * invCh
                                src += ch
                            }
                        }
                        initializedCount = count
                    }
                }
                let chunkPTS = readHeadPTS + Double(frameOffset) / sr
                chunks.append(
                    AudioPCMSubtitleChunk(
                        monoSamples: mono,
                        pts: chunkPTS,
                        sampleRate: sr
                    )
                )
                frameOffset += count
            }
        }
        return chunks
    }

    private func rejected(_ rejection: Rejection) -> AppendResult {
        AppendResult(
            appendedFrameCount: 0,
            droppedPrerollFrameCount: 0,
            trimmedPrerollSampleFrameCount: 0,
            insertedGapFrameCount: 0,
            droppedOverlapFrameCount: 0,
            expectedStartPTS: nil,
            timelineDelta: nil,
            rejection: rejection
        )
    }

    private mutating func append(
        samples input: UnsafeBufferPointer<Float>,
        pts: TimeInterval,
        context: AudioPCMAppend
    ) -> AppendResult {
        guard !input.isEmpty, input.count % context.channels == 0 else {
            return rejected(.invalidPCM)
        }
        if let rejection = prepareFormat(context) { return rejected(rejection) }
        let sampleFrameCount = input.count / context.channels
        let droppedSampleFrames = prerollFrameCount(
            frameCount: sampleFrameCount,
            pts: pts,
            outputFloor: context.outputFloor,
            sampleRate: context.sampleRate
        )
        if droppedSampleFrames >= sampleFrameCount { return rejectedPrerollAppend() }
        let firstSamplePTS = pts + Double(droppedSampleFrames) / context.sampleRate
        let expectedStartPTS = endPTS ?? context.outputFloor
        guard let continuity = planContinuity(
            firstSamplePTS: firstSamplePTS,
            expectedStartPTS: expectedStartPTS,
            sampleFrameCount: sampleFrameCount,
            droppedSampleFrames: droppedSampleFrames,
            context: context
        ) else {
            return rejected(.gapTooLarge(
                gap: firstSamplePTS - expectedStartPTS,
                firstPTS: firstSamplePTS
            ))
        }
        let firstSample = (droppedSampleFrames + continuity.overlapFrames) * context.channels
        let appendedSampleCount = input.count - firstSample
        guard appendedSampleCount > 0 else {
            endPTS = max(endPTS ?? context.outputFloor, continuity.startPTS)
            return emptyAppend(
                trimmedPreroll: droppedSampleFrames,
                continuity: continuity,
                expectedStartPTS: expectedStartPTS
            )
        }
        samples.append(contentsOf: UnsafeBufferPointer(
            start: input.baseAddress!.advanced(by: firstSample),
            count: appendedSampleCount
        ))
        let appendedFrameCount = appendedSampleCount / context.channels
        let timelineEnd = continuity.startPTS + Double(appendedFrameCount) / context.sampleRate
        endPTS = timelineEnd
        return acceptedAppend(
            appendedFrameCount: appendedFrameCount,
            trimmed: droppedSampleFrames,
            continuity: continuity,
            expectedStartPTS: expectedStartPTS
        )
    }

    private static func ceilFrameCount(
        for seconds: TimeInterval,
        sampleRate: Double
    ) -> Int {
        let frameCount = seconds * sampleRate
        guard frameCount.isFinite, frameCount > 0 else { return 0 }
        return Int(max(0, frameCount - 1e-9).rounded(.up))
    }

    private mutating func compactIfNeeded() {
        if readIndex >= samples.count {
            if !samples.isEmpty {
                samples.removeAll(keepingCapacity: true)
            }
            readIndex = 0
            return
        }
        let ch = max(1, channels)
        let discardCandidates = readIndex
        guard discardCandidates >= 16_384, discardCandidates * 2 >= samples.count else { return }
        let discardFrames = discardCandidates / ch
        let discardSamples = discardFrames * ch
        guard discardSamples > 0 else { return }
        samples.removeFirst(discardSamples)
        readIndex -= discardSamples
    }
}

private extension AudioTimelineBuffer {
    mutating func prepareFormat(_ context: AudioPCMAppend) -> Rejection? {
        let formatMismatch = abs(context.sampleRate - sampleRate) > 0.5 || context.channels != channels
        if samples.isEmpty || (readIndex >= samples.count && formatMismatch) {
            samples.removeAll(keepingCapacity: true)
            readIndex = 0
            sampleRate = defaultSampleRate
            channels = defaultChannels
        }
        if abs(context.sampleRate - sampleRate) > 0.5 || context.channels != channels {
            return .formatChange(
                expectedSampleRate: sampleRate,
                expectedChannels: channels,
                actualSampleRate: context.sampleRate,
                actualChannels: context.channels
            )
        }
        return nil
    }

    func prerollFrameCount(
        frameCount: Int,
        pts: TimeInterval,
        outputFloor: TimeInterval,
        sampleRate: Double
    ) -> Int {
        let preFloorSeconds = outputFloor - pts
        guard AudioTimelineContinuity.needsPrerollTrim(preFloorSeconds) else { return 0 }
        let requestedFrames = min(
            Double(frameCount),
            max(0, (preFloorSeconds * sampleRate).rounded(.up))
        )
        return Int(requestedFrames)
    }

    func rejectedPrerollAppend() -> AppendResult {
        AppendResult(
            appendedFrameCount: 0,
            droppedPrerollFrameCount: 1,
            trimmedPrerollSampleFrameCount: 0,
            insertedGapFrameCount: 0,
            droppedOverlapFrameCount: 0,
            expectedStartPTS: nil,
            timelineDelta: nil,
            rejection: nil
        )
    }

    mutating func planContinuity(
        firstSamplePTS: TimeInterval,
        expectedStartPTS: TimeInterval,
        sampleFrameCount: Int,
        droppedSampleFrames: Int,
        context: AudioPCMAppend
    ) -> ContinuityPlan? {
        let delta = firstSamplePTS - expectedStartPTS
        var startPTS = expectedStartPTS
        var gapFrames = 0
        var overlapFrames = 0
        if delta > 0, !timelineContinuity.snaps(delta) {
            guard delta <= maxGapSeconds else { return nil }
            gapFrames = Self.ceilFrameCount(for: delta, sampleRate: context.sampleRate)
            if gapFrames > 0 {
                samples.append(contentsOf: repeatElement(
                    0,
                    count: gapFrames * context.channels
                ))
                insertedGapFrameCount += gapFrames
                startPTS += Double(gapFrames) / context.sampleRate
            }
        } else if delta < 0, !timelineContinuity.snaps(delta) {
            overlapFrames = min(
                sampleFrameCount - droppedSampleFrames,
                Self.ceilFrameCount(for: -delta, sampleRate: context.sampleRate)
            )
            droppedOverlapFrameCount += overlapFrames
        }
        return ContinuityPlan(
            startPTS: startPTS,
            gapFrames: gapFrames,
            overlapFrames: overlapFrames,
            delta: delta
        )
    }

    func emptyAppend(
        trimmedPreroll: Int,
        continuity: ContinuityPlan,
        expectedStartPTS: TimeInterval
    ) -> AppendResult {
        AppendResult(
            appendedFrameCount: 0,
            droppedPrerollFrameCount: 0,
            trimmedPrerollSampleFrameCount: trimmedPreroll,
            insertedGapFrameCount: continuity.gapFrames,
            droppedOverlapFrameCount: continuity.overlapFrames,
            expectedStartPTS: expectedStartPTS,
            timelineDelta: continuity.delta,
            rejection: nil
        )
    }

    func acceptedAppend(
        appendedFrameCount: Int,
        trimmed: Int,
        continuity: ContinuityPlan,
        expectedStartPTS: TimeInterval
    ) -> AppendResult {
        AppendResult(
            appendedFrameCount: appendedFrameCount,
            droppedPrerollFrameCount: 0,
            trimmedPrerollSampleFrameCount: trimmed,
            insertedGapFrameCount: continuity.gapFrames,
            droppedOverlapFrameCount: continuity.overlapFrames,
            expectedStartPTS: expectedStartPTS,
            timelineDelta: continuity.delta,
            rejection: nil
        )
    }

    struct ContinuityPlan {
        let startPTS: TimeInterval
        let gapFrames: Int
        let overlapFrames: Int
        let delta: TimeInterval
    }
}
