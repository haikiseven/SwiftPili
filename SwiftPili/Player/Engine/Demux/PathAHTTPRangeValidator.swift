import Foundation

enum PathAHTTPRangeValidator {
    typealias SourceError = PathAHTTPMediaSource.SourceError
    struct ByteWindow: Sendable {
        let offset: Int64
        let count: Int
        let count64: Int64
        let endExclusive: Int64
        let endInclusive: Int64
    }

    struct ParsedContentRange: Sendable, Equatable {
        let start: Int64
        let end: Int64
        let total: Int64?
        let length: Int64
    }

    static func makeByteWindow(offset: Int64, count: Int) -> ByteWindow? {
        guard count > 0,
              offset >= 0,
              let count64 = Int64(exactly: count),
              let endExclusive = MediaByteRange.checkedEndExclusive(
                offset: offset,
                length: count64
              ),
              let endInclusive = MediaByteRange.checkedEndInclusive(
                offset: offset,
                length: count64
              ) else { return nil }
        return ByteWindow(
            offset: offset,
            count: count,
            count64: count64,
            endExclusive: endExclusive,
            endInclusive: endInclusive
        )
    }

    private static func parseUnsignedInt64(_ raw: String) -> Int64? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              token.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 48 && scalar.value <= 57
              }) else { return nil }
        return Int64(token)
    }

    static func parseContentRange(_ raw: String?) throws -> ParsedContentRange? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split { character in
            character == " " || character == "\t"
        }
        guard fields.count == 2,
              fields[0].lowercased() == "bytes" else {
            throw SourceError.invalidRange
        }

        let rangeAndTotal = fields[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else { throw SourceError.invalidRange }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Self.parseUnsignedInt64(String(bounds[0])),
              let end = Self.parseUnsignedInt64(String(bounds[1])),
              let length = MediaByteRange.checkedLength(start: start, end: end) else {
            throw SourceError.invalidRange
        }

        let totalToken = String(rangeAndTotal[1])
        let total: Int64?
        if totalToken == "*" {
            total = nil
        } else {
            guard let parsedTotal = Self.parseUnsignedInt64(totalToken),
                  parsedTotal > end else { throw SourceError.invalidRange }
            total = parsedTotal
        }
        return ParsedContentRange(start: start, end: end, total: total, length: length)
    }

    static func validatePartialResponse(
        _ raw: String?,
        requested: ByteWindow,
        bodyCount: Int?
    ) throws -> ParsedContentRange? {
        guard let parsed = try parseContentRange(raw) else {
            if let bodyCount, bodyCount > requested.count {
                throw SourceError.invalidRange
            }
            return nil
        }
        guard parsed.start == requested.offset,
              parsed.end <= requested.endInclusive,
              parsed.length <= requested.count64 else {
            throw SourceError.invalidRange
        }
        if let total = parsed.total, parsed.end < requested.endInclusive {
            let resourceEnd = parsed.end.addingReportingOverflow(1)
            guard !resourceEnd.overflow, total == resourceEnd.partialValue else {
                throw SourceError.invalidRange
            }
        }
        if let bodyCount {
            guard let bodyLength = Int64(exactly: bodyCount),
                  bodyLength == parsed.length else { throw SourceError.invalidRange }
        }
        return parsed
    }

    static func declaredContentLength(_ raw: String?) throws -> Int64? {
        guard let raw else { return nil }
        guard let length = parseUnsignedInt64(raw) else {
            throw SourceError.invalidRange
        }
        return length
    }

    static func validateIdentityContentEncoding(_ raw: String?) throws {
        guard let raw else { return }
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity" else {
            throw SourceError.invalidRange
        }
    }

    static func validateContentLength(
        _ raw: String?,
        bodyCount: Int,
        expectedRangeLength: Int64?
    ) throws {
        guard raw != nil else { return }
        guard let declared = try declaredContentLength(raw),
              let bodyLength = Int64(exactly: bodyCount),
              declared == bodyLength,
              expectedRangeLength == nil || declared == expectedRangeLength else {
            throw SourceError.invalidRange
        }
    }

}
