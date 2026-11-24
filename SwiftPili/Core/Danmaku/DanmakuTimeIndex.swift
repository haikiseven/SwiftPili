import Foundation

struct DanmakuTimeIndex: Sendable, Equatable {
    private(set) var elements: [DanmakuElem]

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    init(_ unsorted: [DanmakuElem]) {
        var sorted = unsorted
        sorted.sort { $0.progress < $1.progress }
        elements = sorted
    }

    func elements(from: TimeInterval, to: TimeInterval) -> ArraySlice<DanmakuElem> {
        guard from < to, !elements.isEmpty else { return [] }
        let lower = lowerBound(for: from, in: 0 ..< elements.count)
        guard lower < elements.count else { return [] }
        let upper = upperBoundGalloping(for: to, from: lower)
        guard lower < upper else { return [] }
        return elements[lower ..< upper]
    }

    private func upperBoundGalloping(for time: TimeInterval, from start: Int) -> Int {
        let count = elements.count
        if elements[start].progress >= time { return start }
        var step = 1
        var probe = start + 1
        while probe < count, elements[probe].progress < time {
            step <<= 1
            probe = start + step
        }
        return lowerBound(for: time, in: (start + (step >> 1)) ..< min(probe, count))
    }

    private func lowerBound(for time: TimeInterval, in range: Range<Int>) -> Int {
        var low = range.lowerBound
        var high = range.upperBound
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
