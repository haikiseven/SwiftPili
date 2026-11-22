import Foundation

/// One accepted PCM run moved out of the timeline buffer by a pull. The lease
/// carries the exact media interval; `frames` preserves its offset inside the
/// pulled buffer, including prefixes or holes without qualified evidence.
struct AudioDisplayLeaseSpan: Sendable {
    let frames: Range<Int>
    let lease: MediaDisplayLease
}

/// Follows one decode call from submission to timeline settlement. Only real
/// pending PCM can install source custody; retiring before installation keeps
/// a late decoder return from restoring it. Owns no PCM.
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
            // A decoded lease starts contributing as soon as the book creates
            // it. Publish while the handle can still own and retire it.
            let tail = verifiedTail.flatMap { proof in
                source?.isCurrent == true && source?.interval?.upper == proof.sourceEnd ? proof : nil
            }
            let decodedCoverage = source?.producingDecodedAudio(interval, tail: tail)
            // The real PCM and the emitted FIFO head have different custody.
            // Keep the original source receipt until this append settles.
            let sourceAccessUnit = tail != nil && decodedCoverage != nil ? source : nil
            state = .pending(PendingOutput(decodedCoverage: decodedCoverage, sourceAccessUnit: sourceAccessUnit))
        }
    }

    /// Read only at synchronous append after the session validates this call.
    var decodedCoverage: MediaDisplayLease? {
        lock.withLock {
            guard case .pending(let output) = state else { return nil }
            return output.decodedCoverage
        }
    }

    /// Also callable by task cancellation; never reached by the RT callback.
    func retire() {
        let retired = lock.withLock {
            let previous = state
            state = .retired
            return previous
        }
        withExtendedLifetime(retired) {}
    }
}

/// Result of one supply pull: PCM frames written plus the display evidence
/// that moved with them. The caller owns `displaySpans` until it either writes
/// them into the ring or drops them.
struct AudioSupplyPull: Sendable {
    let frames: Int
    let displaySpans: [AudioDisplayLeaseSpan]
}

struct AudioRendererPull: Sendable {
    let frames: Int
    let contentSeconds: TimeInterval
    let displaySpans: [AudioDisplayLeaseSpan]
}

/// Value metadata from the same ring snapshot as one F1 report. No consumed
/// lease or PCM is retained by the observation.
struct AudioRenderedDisplayObservation: Sendable {
    let publication: AudioRingPublication
    let frames: Range<Int>
    let track: UUID
    let interval: MediaDisplayInterval

    var position: MediaAudioDisplayPosition {
        MediaAudioDisplayPosition(track: track, time: interval.upper)
    }
}

/// A representation of accepted F1 observations, never a second advancing
/// clock. A missed/rejected span remains unqualified until a real timeline
/// reset supplies a new anchor; a later absolute ring time cannot repair it.
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

/// Timeline-side roster of accepted output coverage. It owns no PCM: each span
/// is a frame range in the buffer's own frame space plus the decoder-produced
/// display lease. Recording never invents an interval; a piece that cannot be
/// expressed exactly simply contributes no evidence.
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

    /// Split every span across the consumed range: the consumed part is handed
    /// to the caller, the untouched remainder stays here.
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

    /// Keep frame indices aligned after the buffer drops a consumed prefix.
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

/// Display-evidence custody for PCM that has left the timeline buffer.
///
/// One instance belongs to one real PCM ring, shared by its feeder and direct
/// reserve/seek writers. The callback never touches this object. The renderer
/// retires entries using the SAME coherent cursor snapshot that reports F1;
/// a quiesced ring reset clears this roster before cursor indices are reused.
final class AudioRingDisplayCustody: @unchecked Sendable {
    private struct Entry {
        /// Actual cumulative ring write range for this accepted PCM lease.
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

    /// Every reported frame must have current, contiguous accepted PCM timing.
    /// A silence/unknown prefix or an interior gap cannot supply an absolute pin.
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

    /// Actual content retirement/reset, not an ordinary paused feeder.
    func retireAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
