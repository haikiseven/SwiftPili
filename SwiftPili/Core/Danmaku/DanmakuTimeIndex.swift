import Foundation

struct DanmakuTimeIndex: Sendable, Equatable {
    private(set) var elements: [DanmakuElem]

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    init(_ unsorted: [DanmakuElem]) {
        elements = unsorted.enumerated()
            .sorted { lhs, rhs in
                lhs.element.progress == rhs.element.progress
                    ? lhs.offset < rhs.offset
                    : lhs.element.progress < rhs.element.progress
            }
            .map(\.element)
    }

    func elements(from: TimeInterval, to: TimeInterval) -> ArraySlice<DanmakuElem> {
        guard from < to, !elements.isEmpty else { return [] }
        let lower = lowerBound(for: from)
        guard lower < elements.count else { return [] }
        let upper = lowerBound(for: to)
        guard lower < upper else { return [] }
        return elements[lower ..< upper]
    }

    private func lowerBound(for time: TimeInterval) -> Int {
        var low = 0
        var high = elements.count
        while low < high {
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
