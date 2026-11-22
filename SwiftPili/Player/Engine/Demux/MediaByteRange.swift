import Foundation

enum MediaByteRange {
    static func parse(_ raw: String?) -> ClosedRange<Int64>? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
              start >= 0,
              start <= end else { return nil }
        guard checkedLength(start: start, end: end) != nil else { return nil }
        return start...end
    }

    static func length(_ range: ClosedRange<Int64>) -> Int64? {
        checkedLength(start: range.lowerBound, end: range.upperBound)
    }

    static func checkedLength(start: Int64, end: Int64) -> Int64? {
        guard start >= 0, start <= end else { return nil }
        let difference = end.subtractingReportingOverflow(start)
        guard !difference.overflow else { return nil }
        let result = difference.partialValue.addingReportingOverflow(1)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    static func checkedEndInclusive(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length > 0 else { return nil }
        let last = offset.addingReportingOverflow(length - 1)
        guard !last.overflow else { return nil }
        return last.partialValue
    }

    static func checkedEndExclusive(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length >= 0 else { return nil }
        let end = offset.addingReportingOverflow(length)
        guard !end.overflow else { return nil }
        return end.partialValue
    }

    static func httpRangeHeader(_ range: ClosedRange<Int64>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound)"
    }

    static func httpRangeHeader(offset: Int64, length: Int64?) -> String? {
        guard offset >= 0 else { return nil }
        if let length {
            guard length >= 0 else { return nil }
            if length > 0 {
                guard let end = checkedEndInclusive(offset: offset, length: length) else {
                    return nil
                }
                return "bytes=\(offset)-\(end)"
            }
        }
        return "bytes=\(offset)-"
    }
}
