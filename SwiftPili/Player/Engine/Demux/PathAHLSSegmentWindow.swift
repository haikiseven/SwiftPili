import Foundation

struct PathAHLSSegmentWindow: Sendable {
    private(set) var pending: [PathAHLSMediaPlaylist.Segment] = []
    private(set) var completedCount = 0

    private var queuedSequences: Set<Int> = []
    private var completedSequences: Set<Int> = []
    private var completionOrder: [Int] = []
    private var completionHead = 0
    private var historyLimit = 32
    private var lastExposed: (sequence: Int, discontinuitySequence: Int)?
    private(set) var orderedEndListSeen = false
    private static let maxHistoryLimit = 16_384

    mutating func apply(_ playlist: PathAHLSPlaylist) -> Int {
        apply(segments: playlist.segments)
    }

    mutating func applyOrdered(_ playlist: PathAHLSMediaPlaylist) {
        guard let last = playlist.segments.last else {
            if playlist.isEndList { orderedEndListSeen = true }
            return
        }
        let admitted: ArraySlice<PathAHLSMediaPlaylist.Segment>
        if let lastExposed {
            guard last.sequence >= lastExposed.sequence else { return }
            admitted = playlist.segments.drop(while: { $0.sequence <= lastExposed.sequence })
        } else if playlist.isEndList {
            admitted = playlist.segments[...]
        } else {
            let boundary = playlist.segments.lastIndex {
                $0.isGap || $0.discontinuitySequence != last.discontinuitySequence
            }
            admitted = playlist.segments[(boundary.map { $0 + 1 } ?? 0)...]
        }
        orderedEndListSeen = playlist.isEndList
        pending.removeAll(keepingCapacity: true)
        queuedSequences.removeAll(keepingCapacity: true)
        apply(segments: admitted)
    }

    enum OrderedBoundary: String, Error {
        case sequenceGap, discontinuity
    }

    func firstOrderedPending() throws -> PathAHLSMediaPlaylist.Segment? {
        guard let next = firstPending() else { return nil }
        guard !next.isGap else { throw OrderedBoundary.sequenceGap }
        if let lastExposed {
            let expected = lastExposed.sequence.addingReportingOverflow(1)
            guard !expected.overflow, next.sequence == expected.partialValue else {
                throw OrderedBoundary.sequenceGap
            }
            guard next.discontinuitySequence == lastExposed.discontinuitySequence else {
                throw OrderedBoundary.discontinuity
            }
        }
        return next
    }

    mutating func commitOrderedFirst(_ segment: PathAHLSMediaPlaylist.Segment) -> Bool {
        guard commitFirst(segment) else { return false }
        lastExposed = (segment.sequence, segment.discontinuitySequence)
        return true
    }

    @discardableResult
    private mutating func apply(segments: some Collection<PathAHLSMediaPlaylist.Segment>) -> Int {
        let expandedHistoryResult = segments.count.addingReportingOverflow(4)
        let expandedHistory = expandedHistoryResult.overflow
            ? Self.maxHistoryLimit
            : expandedHistoryResult.partialValue
        historyLimit = min(
            Self.maxHistoryLimit,
            max(32, expandedHistory)
        )
        if !segments.isEmpty {
            let advertised = Set(segments.map(\.sequence))
            let stale = Set(
                pending.lazy.map(\.sequence).filter { !advertised.contains($0) }
            )
            pending.removeAll { stale.contains($0.sequence) }
            for sequence in stale { queuedSequences.remove(sequence) }
        }
        var enqueued = 0
        for segment in segments {
            guard !completedSequences.contains(segment.sequence),
                  !queuedSequences.contains(segment.sequence) else {
                continue
            }
            pending.append(segment)
            queuedSequences.insert(segment.sequence)
            enqueued += 1
        }
        pending.sort { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
        return enqueued
    }

    func firstPending() -> PathAHLSMediaPlaylist.Segment? {
        pending.first
    }

    @discardableResult
    mutating func commitFirst(_ segment: PathAHLSMediaPlaylist.Segment) -> Bool {
        guard pending.first == segment else { return false }
        pending.removeFirst()
        queuedSequences.remove(segment.sequence)
        complete(segment)
        return true
    }

    mutating func retry(_ segment: PathAHLSMediaPlaylist.Segment) {
        guard !completedSequences.contains(segment.sequence),
              queuedSequences.insert(segment.sequence).inserted else {
            return
        }
        pending.insert(segment, at: 0)
    }

    mutating func complete(_ segment: PathAHLSMediaPlaylist.Segment) {
        guard completedSequences.insert(segment.sequence).inserted else { return }
        completionOrder.append(segment.sequence)
        while completionOrder.count - completionHead > historyLimit {
            completedSequences.remove(completionOrder[completionHead])
            completionHead += 1
        }
        if completionHead >= historyLimit,
           completionHead * 2 >= completionOrder.count {
            completionOrder.removeFirst(completionHead)
            completionHead = 0
        }
        completedCount = completedSequences.count
    }
}
