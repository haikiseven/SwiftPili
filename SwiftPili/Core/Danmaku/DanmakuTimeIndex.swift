import Foundation

/// One segment's bullets, ordered by time and queryable by time range.
///
/// The renderer asks the same question on every media tick — "what became due
/// since I last looked?" — and the answer has to be found without walking the
/// segment. A dense segment holds 5,861 bullets; scanning three of those per
/// tick is 17k comparisons for an answer that is usually empty.
///
/// So: sort once at decode time, then binary search. The sort is the store's
/// one-off cost on a background task; the query is `O(log n + k)` for `k`
/// results, which is what lets it sit on the tick path.
///
/// Deliberately a value type holding its own sorted array rather than a view
/// over the store's: a segment is built once and never mutated, and the copy is
/// what makes the index safe to hand to the renderer without a lock.
struct DanmakuTimeIndex: Sendable, Equatable {
    /// Ascending by `progress`. The sort is stable, so bullets sharing a
    /// timestamp keep the order the segment gave them — which is the order the
    /// server considers authoritative for overlapping scripted bullets.
    private(set) var elements: [DanmakuElem]

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    init(_ unsorted: [DanmakuElem]) {
        // `sort(by:)` on `progress` alone is not stable in the standard library.
        // Enumerating and comparing the original offset on ties makes it so,
        // which keeps scripted bullets that share a timestamp in wire order.
        elements = unsorted.enumerated()
            .sorted { lhs, rhs in
                lhs.element.progress == rhs.element.progress
                    ? lhs.offset < rhs.offset
                    : lhs.element.progress < rhs.element.progress
            }
            .map(\.element)
    }

    /// Bullets that become due in `[from, to)`.
    ///
    /// Half-open on purpose: the renderer calls this with the previous tick's
    /// `to` as the next tick's `from`, so a closed upper bound would emit a
    /// bullet sitting exactly on the boundary twice — and a duplicate bullet is
    /// visible, unlike a missing one at a boundary nobody lands on exactly.
    func elements(from: TimeInterval, to: TimeInterval) -> ArraySlice<DanmakuElem> {
        guard from < to, !elements.isEmpty else { return [] }
        let lower = lowerBound(for: from)
        guard lower < elements.count else { return [] }
        let upper = lowerBound(for: to)
        guard lower < upper else { return [] }
        return elements[lower ..< upper]
    }

    /// The first index whose `progress` is `>= time`, or `count` when none is.
    private func lowerBound(for time: TimeInterval) -> Int {
        var low = 0
        var high = elements.count
        while low < high {
            // `low + (high - low) / 2`, not `(low + high) / 2`: the latter
            // overflows for large counts, and this costs nothing.
            let mid = low + (high - low) / 2
            if elements[mid].progress < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
