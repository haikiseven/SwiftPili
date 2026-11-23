import Foundation

struct AudioPCMAppend: Sendable {
    let sampleRate: Double
    let channels: Int
    let outputFloor: TimeInterval
    let displayCoverage: MediaDisplayLease?
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

    private static let replayHistorySeconds: TimeInterval = 1.0

    private var samples: [Float] = []
    private var readIndex = 0
    private var highWaterConsumedFrame = 0
    private var consumedHistorySpans: [AudioDisplayLeaseSpan] = []
    private(set) var sampleRate: Double
    private(set) var channels: Int
    private(set) var endPTS: TimeInterval?
    private var displayEnd: MediaDisplayTime?
    private(set) var insertedGapFrameCount = 0
    private(set) var droppedOverlapFrameCount = 0
    private var displaySpans = AudioDisplaySpanRoster()

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
        highWaterConsumedFrame = 0
        consumedHistorySpans.removeAll(keepingCapacity: true)
        sampleRate = defaultSampleRate
        channels = defaultChannels
        endPTS = nil
        displayEnd = nil
        insertedGapFrameCount = 0
        droppedOverlapFrameCount = 0
        displaySpans.removeAll()
    }

    /// Rewinds `readIndex` back into the retained consumed history window by up to `seconds`.
    /// Returns the actual media seconds rolled back.
    mutating func rollback(seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0, channels > 0, sampleRate > 0 else { return 0 }
        let currentReadFrame = readIndex / channels
        guard currentReadFrame > 0 else { return 0 }
        let requestedFrames = Int((seconds * sampleRate).rounded())
        let rollbackFrames = min(currentReadFrame, max(0, requestedFrames))
        guard rollbackFrames > 0 else { return 0 }
        readIndex = (currentReadFrame - rollbackFrames) * channels
        return TimeInterval(rollbackFrames) / sampleRate
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
        else { return AudioSupplyPull(frames: 0, displaySpans: []) }

        let startFrame = readIndex / channels
        var framesWritten = 0
        while framesWritten < frameCount {
            let samplesLeft = samples.count - readIndex
            guard samplesLeft >= channels else { break }
            let destination = framesWritten * channels
            let source = readIndex
            for channel in 0..<channels {
                output[destination + channel] = samples[source + channel]
            }
            readIndex += channels
            framesWritten += 1
        }
        let endFrame = startFrame + framesWritten
        var spans: [AudioDisplayLeaseSpan] = []
        if startFrame < highWaterConsumedFrame {
            spans.append(contentsOf: historySpans(
                in: startFrame..<min(endFrame, highWaterConsumedFrame),
                relativeTo: startFrame,
                sampleRate: sampleRate
            ))
        }
        let freshStart = max(startFrame, highWaterConsumedFrame)
        if freshStart < endFrame {
            let freshSpans = displaySpans.take(
                in: freshStart..<endFrame,
                sampleRate: sampleRate
            )
            let offset = freshStart - startFrame
            for span in freshSpans {
                consumedHistorySpans.append(AudioDisplayLeaseSpan(
                    frames: (span.frames.lowerBound + freshStart)..<(span.frames.upperBound + freshStart),
                    lease: span.lease
                ))
                spans.append(AudioDisplayLeaseSpan(
                    frames: (span.frames.lowerBound + offset)..<(span.frames.upperBound + offset),
                    lease: span.lease
                ))
            }
            highWaterConsumedFrame = endFrame
        }
        compactIfNeeded()
        return AudioSupplyPull(frames: framesWritten, displaySpans: spans)
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
        recordAcceptedDisplay(
            timelineEnd: timelineEnd,
            appendedFrameCount: appendedFrameCount,
            continuity: continuity,
            expectedStartPTS: expectedStartPTS,
            context: context
        )
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
        let ch = max(1, channels)
        let historyFrames = sampleRate.isFinite && sampleRate > 0
            ? Int((Self.replayHistorySeconds * sampleRate).rounded(.up))
            : 0
        let historySamples = historyFrames * ch
        let discardCandidates = readIndex - historySamples
        guard discardCandidates >= 16_384, discardCandidates * 2 >= samples.count else { return }
        let discardFrames = discardCandidates / ch
        let discardSamples = discardFrames * ch
        guard discardSamples > 0 else { return }
        samples.removeFirst(discardSamples)
        readIndex -= discardSamples
        highWaterConsumedFrame = max(readIndex / ch, highWaterConsumedFrame - discardFrames)
        displaySpans.shiftConsumed(frames: discardFrames)
        trimConsumedHistorySpans(discardFrames: discardFrames)
    }

    private func historySpans(
        in range: Range<Int>,
        relativeTo originFrame: Int,
        sampleRate: Double
    ) -> [AudioDisplayLeaseSpan] {
        guard !range.isEmpty, !consumedHistorySpans.isEmpty else { return [] }
        var result: [AudioDisplayLeaseSpan] = []
        for span in consumedHistorySpans {
            let lower = max(span.frames.lowerBound, range.lowerBound)
            let upper = min(span.frames.upperBound, range.upperBound)
            guard lower < upper,
                  let interval = span.lease.interval,
                  let start = interval.lower.adding(
                      frames: lower - span.frames.lowerBound,
                      sampleRate: sampleRate
                  ),
                  let narrowed = span.lease.producing(.pcm(
                      start: start,
                      frames: upper - lower,
                      rate: sampleRate
                  )) else { continue }
            result.append(AudioDisplayLeaseSpan(
                frames: (lower - originFrame)..<(upper - originFrame),
                lease: narrowed
            ))
        }
        return result
    }

    private mutating func trimConsumedHistorySpans(discardFrames: Int) {
        guard discardFrames > 0, !consumedHistorySpans.isEmpty else { return }
        var kept: [AudioDisplayLeaseSpan] = []
        kept.reserveCapacity(consumedHistorySpans.count)
        for span in consumedHistorySpans {
            guard span.frames.upperBound > discardFrames else { continue }
            if span.frames.lowerBound >= discardFrames {
                kept.append(AudioDisplayLeaseSpan(
                    frames: (span.frames.lowerBound - discardFrames)..<(span.frames.upperBound - discardFrames),
                    lease: span.lease
                ))
            } else if let interval = span.lease.interval,
                      let start = interval.lower.adding(
                          frames: discardFrames - span.frames.lowerBound,
                          sampleRate: sampleRate
                      ),
                      let trimmedLease = span.lease.producing(.pcm(
                          start: start,
                          frames: span.frames.upperBound - discardFrames,
                          rate: sampleRate
                      )) {
                kept.append(AudioDisplayLeaseSpan(
                    frames: 0..<(span.frames.upperBound - discardFrames),
                    lease: trimmedLease
                ))
            }
        }
        consumedHistorySpans = kept
    }
}

private extension AudioTimelineBuffer {
    mutating func prepareFormat(_ context: AudioPCMAppend) -> Rejection? {
        let formatMismatch = abs(context.sampleRate - sampleRate) > 0.5 || context.channels != channels
        if samples.isEmpty || (readIndex >= samples.count && formatMismatch) {
            samples.removeAll(keepingCapacity: true)
            readIndex = 0
            highWaterConsumedFrame = 0
            consumedHistorySpans.removeAll(keepingCapacity: true)
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

    mutating func recordAcceptedDisplay(
        timelineEnd: TimeInterval,
        appendedFrameCount: Int,
        continuity: ContinuityPlan,
        expectedStartPTS: TimeInterval,
        context: AudioPCMAppend
    ) {
        let start = (displayEnd ?? MediaDisplayTime(seconds: expectedStartPTS))?.adding(
            frames: continuity.gapFrames, sampleRate: context.sampleRate
        )
        let interval = MediaDisplayInterval.pcm(
            start: start, frames: appendedFrameCount, rate: context.sampleRate
        )
        displayEnd = interval?.upper
        displaySpans.record(
            lease: context.displayCoverage,
            interval: interval,
            startFrame: samples.count / context.channels - appendedFrameCount,
            frames: appendedFrameCount,
            acceptedTail: AudioDisplayAcceptedTail(
                timelineEnd: timelineEnd, outputFloor: context.outputFloor, continuity: timelineContinuity
            )
        )
    }

    struct ContinuityPlan {
        let startPTS: TimeInterval
        let gapFrames: Int
        let overlapFrames: Int
        let delta: TimeInterval
    }
}
