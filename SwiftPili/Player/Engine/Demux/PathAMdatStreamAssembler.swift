import Foundation

/// Path A — incremental fragment-payload assembler.
///
/// The streaming-`mdat` pump knows every sample's byte span from the buffered
/// `moof` (the layout phase) before a single payload byte arrives. This type is
/// the consumption phase: it is fed the fragment's bytes in arbitrary chunks —
/// the probe window first, then live HTTP chunks — and emits each sample's
/// complete compressed bytes the moment its last byte lands. It never emits a
/// partial sample, holds at most the bytes of the one sample in progress
/// (consumed gap/skip bytes are discarded immediately), and its byte cursor is
/// the exact resume offset for a reopened stream.
///
/// Pure value logic, Foundation-only, no I/O — deliberately compilable into the
/// off-device differential harness exactly as shipped.
struct PathAMdatStreamAssembler: Sendable {

    /// One completed sample: `sampleIndex` addresses the layout array the
    /// assembler was built from (after zero-size spans were dropped — the
    /// buffered packetizer never emitted those either).
    struct Emitted: Sendable {
        let sampleIndex: Int
        let data: Data
        let displayCoverage: MediaDisplayLease?
    }

    /// Byte spans in ABSOLUTE resource coordinates, strictly ordered.
    private struct Span: Sendable {
        let index: Int
        let start: Int
        let end: Int
    }

    private let spans: [Span]
    private var nextSpan = 0
    /// Absolute offset of the next byte the assembler expects to be fed.
    private(set) var cursor: Int
    private var partial = Data()
    private var displayPartial: MediaDisplayLease?
    var displayTrack: MediaDisplayTrack?
    var displaySamples: [Int: MediaDisplaySample] = [:]
    /// Defensive state for a caller that violates the validated span/cursor
    /// invariant.  `consume` remains non-throwing for its existing API, so the
    /// demuxer observes this bit and turns it into one typed fragment failure
    /// before any staged packets can be published.
    private(set) var isMalformed = false

    /// All spans emitted. True for an empty layout; zero-size media samples are
    /// rejected by the initializer rather than silently treated as empty.
    var isComplete: Bool { nextSpan >= spans.count }

    /// Total bytes fed so far, as an absolute resume offset: a replacement
    /// stream must begin delivering at exactly this byte.
    var resumeOffset: Int { cursor }

    /// Build from the layout. `samples` are (absolute offset, size) pairs in
    /// layout order; `streamStart` is the absolute offset of the first byte
    /// that will be fed (the fragment start, since the probe window is fed
    /// first). Returns nil when the spans are not strictly ordered and
    /// non-overlapping, or start before `streamStart` — the caller falls back
    /// to the fully-buffered path rather than guessing.
    init?(samples: [(offset: Int, size: Int)], streamStart: Int) {
        guard streamStart >= 0,
              samples.count <= PathAFMP4.maxSamplesPerMoof else { return nil }
        var built: [Span] = []
        built.reserveCapacity(samples.count)
        var previousEnd = streamStart
        for (index, sample) in samples.enumerated() {
            // The parser rejects zero-size declared media samples before this
            // boundary. Keep the assembler fail-closed if a caller bypasses
            // that typed result; silently dropping a row would desynchronise
            // the staged fragment.
            guard sample.size > 0,
                  sample.size <= PathAFMP4.maxSampleBytesPerMoof else { return nil }
            guard sample.offset >= previousEnd else { return nil }
            let endResult = sample.offset.addingReportingOverflow(sample.size)
            guard !endResult.overflow, endResult.partialValue > sample.offset else {
                return nil
            }
            built.append(Span(
                index: index,
                start: sample.offset,
                end: endResult.partialValue
            ))
            previousEnd = endResult.partialValue
        }
        spans = built
        cursor = streamStart
    }

    /// Feed the next contiguous chunk. Returns every sample completed by it,
    /// in stream order. Bytes between/after spans (box headers, padding,
    /// foreign-track interleave gaps) are discarded, never buffered.
    mutating func consume(_ chunk: Data) -> [Emitted] {
        guard !isMalformed else { return [] }
        var emitted: [Emitted] = []
        // Rebase once: `chunk` may be a slice with a non-zero start index.
        var position = chunk.startIndex
        let endIndex = chunk.endIndex
        while position < endIndex, nextSpan < spans.count {
            let span = spans[nextSpan]
            let available = endIndex - position
            if cursor < span.start {
                // Gap before the next sample — skip, do not retain.
                let distance = span.start.subtractingReportingOverflow(cursor)
                guard !distance.overflow, distance.partialValue >= 0 else {
                    isMalformed = true
                    partial = Data()
                    return []
                }
                let skip = min(distance.partialValue, available)
                let nextPosition = position.addingReportingOverflow(skip)
                let nextCursor = cursor.addingReportingOverflow(skip)
                guard !nextPosition.overflow, !nextCursor.overflow else {
                    isMalformed = true
                    partial = Data()
                    return []
                }
                position = nextPosition.partialValue
                cursor = nextCursor.partialValue
                continue
            }
            // Inside the span: cursor ∈ [span.start, span.end).
            let neededResult = span.end.subtractingReportingOverflow(cursor)
            guard !neededResult.overflow, neededResult.partialValue > 0 else {
                isMalformed = true
                partial = Data()
                return []
            }
            let needed = neededResult.partialValue
            let take = min(needed, available)
            let spanLengthResult = span.end.subtractingReportingOverflow(span.start)
            guard !spanLengthResult.overflow, spanLengthResult.partialValue > 0,
                  partial.count <= spanLengthResult.partialValue else {
                isMalformed = true
                partial = Data()
                return []
            }
            if partial.isEmpty, take == spanLengthResult.partialValue {
                // Whole sample inside this chunk — one fresh copy, no staging.
                let nextPosition = position.addingReportingOverflow(take)
                guard !nextPosition.overflow else {
                    isMalformed = true
                    return []
                }
                emitted.append(Emitted(
                    sampleIndex: span.index,
                    data: chunk.subdata(in: position..<nextPosition.partialValue),
                    displayCoverage: displaySamples[span.index].flatMap { displayTrack?.own($0.interval) }
                ))
            } else {
                let appendedCount = partial.count.addingReportingOverflow(take)
                guard !appendedCount.overflow,
                      appendedCount.partialValue <= spanLengthResult.partialValue else {
                    isMalformed = true
                    partial = Data()
                    return []
                }
                let nextPosition = position.addingReportingOverflow(take)
                guard !nextPosition.overflow else {
                    isMalformed = true
                    partial = Data()
                    return []
                }
                partial.append(chunk.subdata(in: position..<nextPosition.partialValue))
                displayPartial = displayTrack?.own(
                    bytes: Int64(span.start)..<Int64(cursor + take)
                )
                if take == needed {
                    emitted.append(Emitted(
                        sampleIndex: span.index, data: partial,
                        displayCoverage: displaySamples[span.index].flatMap { displayTrack?.own($0.interval) }
                    ))
                    displayPartial = nil
                    partial = Data()
                }
            }
            let nextPosition = position.addingReportingOverflow(take)
            let nextCursor = cursor.addingReportingOverflow(take)
            guard !nextPosition.overflow, !nextCursor.overflow else {
                isMalformed = true
                partial = Data()
                return []
            }
            position = nextPosition.partialValue
            cursor = nextCursor.partialValue
            if take == needed {
                let nextIndex = nextSpan.addingReportingOverflow(1)
                guard !nextIndex.overflow else {
                    isMalformed = true
                    partial = Data()
                    return []
                }
                nextSpan = nextIndex.partialValue
            }
        }
        // Bytes past the last span (trailing padding) are consumed and dropped
        // so `resumeOffset` keeps tracking the stream position.
        if nextSpan >= spans.count, position < endIndex {
            let trailing = endIndex - position
            let nextCursor = cursor.addingReportingOverflow(trailing)
            guard !nextCursor.overflow else {
                isMalformed = true
                partial = Data()
                return []
            }
            cursor = nextCursor.partialValue
        }
        return emitted
    }

    /// End-of-stream arrived. Any sample in progress is dropped — a truncated
    /// fragment keeps only the samples that completed (never a partial one).
    /// Returns true when the truncation actually cut a sample or left spans
    /// unemitted (i.e. the fragment did not complete cleanly).
    mutating func finishTruncated() -> Bool {
        let truncated = !isComplete
        partial = Data()
        displayPartial = nil
        nextSpan = spans.count
        return truncated
    }
}
