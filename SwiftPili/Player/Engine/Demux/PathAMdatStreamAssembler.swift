import Foundation

struct PathAMdatStreamAssembler: Sendable {

    struct Emitted: Sendable {
        let sampleIndex: Int
        let data: Data
    }

    private struct Span: Sendable {
        let index: Int
        let start: Int
        let end: Int
    }

    private let spans: [Span]
    private var nextSpan = 0
    private(set) var cursor: Int
    private var partial = Data()
    private(set) var isMalformed = false

    var isComplete: Bool { nextSpan >= spans.count }

    var resumeOffset: Int { cursor }

    init?(samples: [(offset: Int, size: Int)], streamStart: Int) {
        guard streamStart >= 0,
              samples.count <= PathAFMP4.maxSamplesPerMoof else { return nil }
        var built: [Span] = []
        built.reserveCapacity(samples.count)
        var previousEnd = streamStart
        for (index, sample) in samples.enumerated() {
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

    mutating func consume(_ chunk: Data) -> [Emitted] {
        guard !isMalformed else { return [] }
        var emitted: [Emitted] = []
        var position = chunk.startIndex
        let endIndex = chunk.endIndex
        while position < endIndex, nextSpan < spans.count {
            let span = spans[nextSpan]
            let available = endIndex - position
            if cursor < span.start {
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
                let nextPosition = position.addingReportingOverflow(take)
                guard !nextPosition.overflow else {
                    isMalformed = true
                    return []
                }
                emitted.append(Emitted(
                    sampleIndex: span.index,
                    data: chunk.subdata(in: position..<nextPosition.partialValue)
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
                if take == needed {
                    emitted.append(Emitted(
                        sampleIndex: span.index, data: partial
                    ))
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

    mutating func finishTruncated() -> Bool {
        let truncated = !isComplete
        partial = Data()
        nextSpan = spans.count
        return truncated
    }
}
