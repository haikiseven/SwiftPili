import Foundation

struct CDNProbeResponseMetadata: Equatable, Sendable {
    let statusCode: Int
    let contentLength: Int?
    let rangeStart: Int?
    let rangeEnd: Int?
    let rangeTotal: Int?

    init(
        statusCode: Int,
        contentLength: Int? = nil,
        rangeStart: Int? = nil,
        rangeEnd: Int? = nil,
        rangeTotal: Int? = nil
    ) {
        self.statusCode = statusCode
        self.contentLength = contentLength
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.rangeTotal = rangeTotal
    }

    init(response: HTTPURLResponse) {
        self.init(
            statusCode: response.statusCode,
            contentLength: Self.parsePositiveInt(
                response.value(forHTTPHeaderField: "Content-Length")
            ),
            range: response.value(forHTTPHeaderField: "Content-Range")
        )
    }

    private init(statusCode: Int, contentLength: Int?, range: String?) {
        self.statusCode = statusCode
        self.contentLength = contentLength
        let parsed = Self.parseRange(range)
        self.rangeStart = parsed.start
        self.rangeEnd = parsed.end
        self.rangeTotal = parsed.total
    }

    var declaredBodyLength: Int? {
        if let rangeStart, let rangeEnd, rangeEnd >= rangeStart {
            return rangeEnd - rangeStart + 1
        }
        return contentLength
    }

    private static func parsePositiveInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
            return nil
        }
        return value
    }

    private static func parseRange(
        _ raw: String?
    ) -> (start: Int?, end: Int?, total: Int?) {
        guard let raw else { return (nil, nil, nil) }
        let pieces = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else {
            return (nil, nil, nil)
        }
        let rangeAndTotal = pieces[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else { return (nil, nil, nil) }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1]),
              start >= 0,
              end >= start else {
            return (nil, nil, nil)
        }
        let total = rangeAndTotal[1] == "*" ? nil : parsePositiveInt(String(rangeAndTotal[1]))
        return (start, end, total)
    }
}

struct CDNProbeMeasurement: Equatable, Sendable {
    let requestedBytes: Int
    let receivedBytes: Int
    let endedByDeadline: Bool
    let transportTruncated: Bool
    let response: CDNProbeResponseMetadata?

    init(
        requestedBytes: Int,
        receivedBytes: Int,
        endedByDeadline: Bool = false,
        transportTruncated: Bool = false,
        response: CDNProbeResponseMetadata? = nil
    ) {
        self.requestedBytes = requestedBytes
        self.receivedBytes = receivedBytes
        self.endedByDeadline = endedByDeadline
        self.transportTruncated = transportTruncated
        self.response = response
    }
}

enum CDNProbeVerdict: String, Equatable, Sendable {
    case failed
    case partial
    case complete
}

enum CDNProbeVerdictPolicy {
    static func verdict(for measurement: CDNProbeMeasurement) -> CDNProbeVerdict {
        guard measurement.requestedBytes > 0,
              measurement.receivedBytes >= 0,
              let response = measurement.response,
              (200 ... 299).contains(response.statusCode) else {
            return .failed
        }

        let received = measurement.receivedBytes
        let requested = measurement.requestedBytes
        if received >= requested, !measurement.endedByDeadline, !measurement.transportTruncated {
            return .complete
        }
        if measurement.endedByDeadline || measurement.transportTruncated {
            return .partial
        }

        if let declaredBody = response.declaredBodyLength,
           received >= declaredBody,
           declaredBody > 0 {
            if let total = response.rangeTotal {
                return total == declaredBody && total <= requested ? .complete : .partial
            }
            if response.rangeStart == nil, response.rangeEnd == nil,
               declaredBody <= requested {
                return .complete
            }
        }
        return .partial
    }

    static func isHealthy(_ verdict: CDNProbeVerdict) -> Bool {
        verdict == .complete
    }
}
