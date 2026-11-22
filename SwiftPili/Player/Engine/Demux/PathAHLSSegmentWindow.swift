import Foundation

/// Bounded queue/history for one HLS media-sequence timeline.
///
/// Media sequence is the authoritative identity inside one open playlist.
/// Query tokens may rotate between refreshes, so including the full signed URL
/// in identity would enqueue the same segment twice.
struct PathAHLSSegmentWindow: Sendable {
    private(set) var pending: [PathAHLSMediaPlaylist.Segment] = []
    private(set) var completedCount = 0

    private var queuedSequences: Set<Int> = []
    private var completedSequences: Set<Int> = []
    private var completionOrder: [Int] = []
    private var completionHead = 0
    private var historyLimit = 32
    /// The ordered reader keeps a watermark even after bounded history evicts old identities.
    private var lastExposed: (sequence: Int, discontinuitySequence: Int)?
    private(set) var orderedEndListSeen = false
    /// History is a memory bound, not a playlist legality rule. A larger valid
    /// playlist may still parse; only completed identity retention is capped.
    private static let maxHistoryLimit = 16_384

    mutating func apply(_ playlist: PathAHLSPlaylist) -> Int {
        apply(segments: playlist.segments)
    }

    /// Admit one TS playlist snapshot. A finite playlist begins at its first segment.
    /// A new live context enters the newest uninterrupted, available suffix so a
    /// reload can move across an epoch boundary still present in the sliding window.
    mutating func applyOrdered(_ playlist: PathAHLSMediaPlaylist) {
        guard let last = playlist.segments.last else {
            // Empty live snapshots leave the current window alone. An explicit
            // ENDLIST can end an empty finite input or seal existing pending work.
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
        // No request is in flight at refresh time. Re-admit signed URLs from
        // the current snapshot, including segments whose query token rotated.
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

    /// Commit only after the complete HTTP response has been admitted. The
    /// serial byte reader drains that segment before fetching another one.
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
        // A live window can advance repeatedly while a segment request is
        // stalled. Retain only pending identities still advertised by the
        // latest non-empty window; otherwise queued state grows without a
        // completion to trim it. An empty refresh is intentionally ignored so
        // transient live emptiness does not discard already-admitted work.
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

    /// Peek without mutating queue identity.  Packetization must complete
    /// successfully before a segment leaves `pending`; otherwise a malformed
    /// complete segment would partially advance the HLS reader state.
    func firstPending() -> PathAHLSMediaPlaylist.Segment? {
        pending.first
    }

    /// Commit the segment that was peeked and fully packetized.  The identity
    /// check prevents a stale completion from removing a successor segment.
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
        // Keep the retained history bounded without making every completion
        // shift the entire array (which becomes quadratic for the named
        // 4x-window ceiling).
        if completionHead >= historyLimit,
           completionHead * 2 >= completionOrder.count {
            completionOrder.removeFirst(completionHead)
            completionHead = 0
        }
        completedCount = completedSequences.count
    }
}
