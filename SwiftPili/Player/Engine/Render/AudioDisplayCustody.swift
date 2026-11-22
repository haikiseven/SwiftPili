import Foundation

struct AudioDisplayLeaseSpan: Sendable {
    let frames: Range<Int>
    let lease: MediaDisplayLease
}

final class AudioPendingDisplaySupport: @unchecked Sendable {
    private struct PendingOutput {
        let decodedCoverage: MediaDisplayLease?
        let sourceAccessUnit: MediaDisplayLease?
    }

    private enum State {
        case awaitingOutput
        case pending(PendingOutput)
        case retired
    }

    private let lock = NSLock()
    private var state: State = .awaitingOutput

    func install(
        source: MediaDisplayLease?, interval: MediaDisplayInterval?,
        verifiedTail: AudioDisplayDecodedTail?
    ) {
        lock.withLock {
            guard case .awaitingOutput = state else { return }
            let tail = verifiedTail.flatMap { proof in
                source?.isCurrent == true && source?.interval?.upper == proof.sourceEnd ? proof : nil
            }
            let decodedCoverage = source?.producingDecodedAudio(interval, tail: tail)
            let sourceAccessUnit = tail != nil && decodedCoverage != nil ? source : nil
            state = .pending(PendingOutput(decodedCoverage: decodedCoverage, sourceAccessUnit: sourceAccessUnit))
        }
    }

    var decodedCoverage: MediaDisplayLease? {
        lock.withLock {
            guard case .pending(let output) = state else { return nil }
            return output.decodedCoverage
        }
    }

    func retire() {
        let retired = lock.withLock {
            let previous = state
            state = .retired
            return previous
        }
        withExtendedLifetime(retired) {}
    }
}

struct AudioSupplyPull: Sendable {
    let frames: Int
    let displaySpans: [AudioDisplayLeaseSpan]
}

struct AudioRendererPull: Sendable {
    let frames: Int
    let contentSeconds: TimeInterval
    let displaySpans: [AudioDisplayLeaseSpan]
}

struct AudioRenderedDisplayObservation: Sendable {
    let publication: AudioRingPublication
    let frames: Range<Int>
    let track: UUID
    let interval: MediaDisplayInterval

    var position: MediaAudioDisplayPosition {
        MediaAudioDisplayPosition(track: track, time: interval.upper)
    }
}

struct AudioDisplayObservationChain {
    private var anchor: MediaDisplayTime?
    private var accepted: AudioRenderedDisplayObservation?
    private var resumedAfterPause = false

    var position: MediaAudioDisplayPosition? { accepted?.position }

    mutating func reset(to time: TimeInterval) {
        anchor = MediaDisplayTime(seconds: time)
        accepted = nil
        resumedAfterPause = false
    }

    mutating func suspendForPause(fallbackTime: TimeInterval) {
        if accepted == nil, anchor == nil, fallbackTime.isFinite {
            anchor = MediaDisplayTime(seconds: fallbackTime)
        }
        resumedAfterPause = true
    }

    mutating func invalidate() {
        anchor = nil
        accepted = nil
        resumedAfterPause = false
    }

    mutating func accept(_ observation: AudioRenderedDisplayObservation?) {
        guard let observation else {
            invalidate()
            return
        }
        if resumedAfterPause {
            if let accepted,
               accepted.publication == observation.publication,
               accepted.track == observation.track,
               accepted.frames.upperBound == observation.frames.lowerBound,
               observation.interval.lower == accepted.interval.upper {
                self.accepted = observation
                resumedAfterPause = false
                return
            }
            guard observation.frames.lowerBound == 0,
                  accepted == nil || accepted?.track == observation.track else {
                invalidate()
                return
            }
            accepted = observation
            resumedAfterPause = false
            return
        }
        guard observation.interval.lower == (accepted?.interval.upper ?? anchor) else {
            invalidate()
            return
        }
        if let accepted {
            guard accepted.publication == observation.publication,
                  accepted.track == observation.track,
                  accepted.frames.upperBound == observation.frames.lowerBound else {
                invalidate()
                return
            }
        } else if observation.frames.lowerBound != 0 {
            invalidate()
            return
        }
        accepted = observation
    }
}

struct AudioDisplayAcceptedTail: Equatable, Sendable {
    let timelineEnd: TimeInterval
    let outputFloor: TimeInterval
    let continuity: AudioTimelineContinuity

    func canContinue(at sourceStart: TimeInterval) -> Bool {
        !AudioTimelineContinuity.needsPrerollTrim(outputFloor - sourceStart)
            && continuity.snaps(sourceStart - timelineEnd)
    }
}

struct AudioDisplaySpanRoster: Sendable {
    private struct Span: Sendable {
        let frames: Range<Int>
        let interval: MediaDisplayInterval
        let lease: MediaDisplayLease
    }

    private var spans: [Span] = []

    mutating func record(
        lease: MediaDisplayLease?,
        interval: MediaDisplayInterval?,
        startFrame: Int,
        frames: Int,
        acceptedTail: AudioDisplayAcceptedTail
    ) {
        guard let lease, let interval, frames > 0,
              let narrowed = lease.producingAcceptedAudio(interval, tail: acceptedTail) else { return }
        spans.append(Span(frames: startFrame..<(startFrame + frames), interval: interval, lease: narrowed))
    }

    mutating func take(in consumed: Range<Int>, sampleRate: Double) -> [AudioDisplayLeaseSpan] {
        guard !spans.isEmpty, !consumed.isEmpty else { return [] }
        var transferred: [AudioDisplayLeaseSpan] = []
        var remaining: [Span] = []
        for span in spans {
            let lower = max(span.frames.lowerBound, consumed.lowerBound)
            let upper = min(span.frames.upperBound, consumed.upperBound)
            guard lower < upper else {
                remaining.append(span)
                continue
            }
            if let lease = narrowed(span, from: lower, to: upper, sampleRate: sampleRate) {
                transferred.append(AudioDisplayLeaseSpan(
                    frames: (lower - consumed.lowerBound)..<(upper - consumed.lowerBound),
                    lease: lease
                ))
            }
            if span.frames.lowerBound < lower,
               let lease = narrowed(span, from: span.frames.lowerBound, to: lower, sampleRate: sampleRate),
               let interval = lease.interval {
                remaining.append(Span(
                    frames: span.frames.lowerBound..<lower, interval: interval, lease: lease
                ))
            }
            if upper < span.frames.upperBound,
               let lease = narrowed(span, from: upper, to: span.frames.upperBound, sampleRate: sampleRate),
               let interval = lease.interval {
                remaining.append(Span(
                    frames: upper..<span.frames.upperBound, interval: interval, lease: lease
                ))
            }
        }
        spans = remaining
        return transferred
    }

    mutating func shiftConsumed(frames: Int) {
        guard frames > 0, !spans.isEmpty else { return }
        spans = spans.map { span in
            Span(
                frames: shifted(span.frames.lowerBound, by: frames)..<shifted(span.frames.upperBound, by: frames),
                interval: span.interval,
                lease: span.lease
            )
        }
    }

    mutating func removeAll() {
        spans.removeAll()
    }

    private func narrowed(
        _ span: Span, from lowerFrame: Int, to upperFrame: Int, sampleRate: Double
    ) -> MediaDisplayLease? {
        guard lowerFrame < upperFrame,
              let start = span.interval.lower.adding(
                  frames: lowerFrame - span.frames.lowerBound,
                  sampleRate: sampleRate
              ),
              let interval = MediaDisplayInterval.pcm(
                  start: start, frames: upperFrame - lowerFrame, rate: sampleRate
              ) else { return nil }
        return span.lease.producing(interval)
    }

    private func shifted(_ frame: Int, by frames: Int) -> Int {
        max(0, frame - frames)
    }
}

final class AudioRingDisplayCustody: @unchecked Sendable {
    private struct Entry {
        let frames: Range<Int>
        let lease: MediaDisplayLease
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(
        startFrame: Int, frames: Int, spans: [AudioDisplayLeaseSpan], sampleRate: Double
    ) {
        guard frames > 0, !spans.isEmpty else { return }
        var collected: [Entry] = []
        for span in spans {
            let lower = max(0, span.frames.lowerBound)
            let upper = min(frames, span.frames.upperBound)
            let beginning = startFrame.addingReportingOverflow(lower)
            let end = startFrame.addingReportingOverflow(upper)
            guard lower < upper, !beginning.overflow, !end.overflow else { continue }
            if let interval = span.lease.interval,
               let start = interval.lower.adding(
                   frames: lower - span.frames.lowerBound, sampleRate: sampleRate
               ),
               let narrowed = span.lease.producing(.pcm(
                   start: start,
                   frames: upper - lower,
                   rate: sampleRate
               )) {
                collected.append(Entry(frames: beginning.partialValue..<end.partialValue, lease: narrowed))
            }
        }
        lock.lock()
        entries.append(contentsOf: collected)
        lock.unlock()
    }

    func observeAndRetireConsumed(
        using snapshot: PCMRingDrainSnapshot,
        previouslyReportedFrames: Int,
        sampleRate: Double,
        publication: AudioRingPublication
    ) -> AudioRenderedDisplayObservation? {
        lock.lock()
        defer {
            entries.removeAll { $0.frames.upperBound <= snapshot.consumedFrames }
            lock.unlock()
        }
        guard previouslyReportedFrames >= 0, previouslyReportedFrames < snapshot.consumedFrames else { return nil }
        let frames = previouslyReportedFrames..<snapshot.consumedFrames
        guard let resolved = interval(in: frames, sampleRate: sampleRate) else { return nil }
        return AudioRenderedDisplayObservation(
            publication: publication, frames: frames, track: resolved.track, interval: resolved.interval
        )
    }

    private func interval(
        in frames: Range<Int>, sampleRate: Double
    ) -> (track: UUID, interval: MediaDisplayInterval)? {
        var cursor = frames.lowerBound
        var track: UUID?
        var start: MediaDisplayTime?
        var end: MediaDisplayTime?
        for entry in entries where entry.frames.upperBound > cursor {
            guard entry.frames.lowerBound <= cursor,
                  entry.lease.isCurrent,
                  let interval = entry.lease.interval else { return nil }
            let upperFrame = min(frames.upperBound, entry.frames.upperBound)
            guard let lower = interval.lower.adding(
                frames: cursor - entry.frames.lowerBound, sampleRate: sampleRate
            ), let upper = interval.lower.adding(
                frames: upperFrame - entry.frames.lowerBound, sampleRate: sampleRate
            ), upper <= interval.upper else { return nil }
            if let end {
                guard lower == end, track == entry.lease.trackIdentity else { return nil }
            } else {
                start = lower
                track = entry.lease.trackIdentity
            }
            end = upper
            cursor = upperFrame
            if cursor == frames.upperBound {
                guard let track, let interval = MediaDisplayInterval(start, end) else { return nil }
                return (track, interval)
            }
        }
        return nil
    }

    func retireAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
