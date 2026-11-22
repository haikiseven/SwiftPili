import Foundation

/// Helpers for future Path A resource-loader / range GETs.
/// **Not used** by `AVAssetMediaDemuxer` open yet (A4 phase-2 scaffold).
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

    /// Returns the number of bytes in an inclusive range without allowing the
    /// subtraction/addition used by the ordinary expression to wrap.
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

    /// Inclusive endpoint for `[offset, offset + length)`. `length` must be
    /// positive because this helper describes an HTTP byte range.
    static func checkedEndInclusive(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length > 0 else { return nil }
        let last = offset.addingReportingOverflow(length - 1)
        guard !last.overflow else { return nil }
        return last.partialValue
    }

    /// Exclusive endpoint for `[offset, offset + length)`. Zero-length spans
    /// are allowed here for slicing/position checks; callers that build HTTP
    /// ranges should use `checkedEndInclusive`.
    static func checkedEndExclusive(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length >= 0 else { return nil }
        let end = offset.addingReportingOverflow(length)
        guard !end.overflow else { return nil }
        return end.partialValue
    }

    static func httpRangeHeader(_ range: ClosedRange<Int64>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound)"
    }

    /// Formats a checked byte range. `nil` means an invalid offset/length and
    /// lets the source map the failure to its typed `invalidRange` error before
    /// constructing a request.
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
