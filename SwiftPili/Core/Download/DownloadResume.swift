import Foundation

// MARK: - Byte ranges

struct DownloadByteRange: Codable, Equatable, Hashable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { max(0, end - start) }
    var isEmpty: Bool { end <= start }
    var range: Range<Int64> {
        let lower = max(0, start)
        return lower..<max(lower, end)
    }

    init(start: Int64, end: Int64) {
        let normalizedStart = max(0, start)
        self.start = normalizedStart
        self.end = max(normalizedStart, end)
    }

    init(_ range: Range<Int64>) {
        self.init(start: range.lowerBound, end: range.upperBound)
    }

    static func coalesce(_ ranges: [DownloadByteRange]) -> [DownloadByteRange] {
        let valid = ranges
            .filter { $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var merged: [DownloadByteRange] = []
        merged.reserveCapacity(valid.count)
        for range in valid {
            if let last = merged.last, range.start <= last.end {
                if range.end > last.end {
                    merged[merged.count - 1] = DownloadByteRange(start: last.start, end: range.end)
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func clamped(_ ranges: [DownloadByteRange], totalBytes: Int64) -> [DownloadByteRange] {
        guard totalBytes > 0 else { return [] }
        let bounded = ranges.compactMap { range -> DownloadByteRange? in
            let lower = max(0, range.start)
            let upper = min(totalBytes, range.end)
            return upper > lower ? DownloadByteRange(start: lower, end: upper) : nil
        }
        return coalesce(bounded)
    }

    static func missingRanges(
        in completed: [DownloadByteRange],
        totalBytes: Int64
    ) -> [DownloadByteRange] {
        guard totalBytes > 0 else { return [] }
        let merged = clamped(completed, totalBytes: totalBytes)
        var missing: [DownloadByteRange] = []
        var cursor: Int64 = 0
        for range in merged {
            if range.start > cursor {
                missing.append(DownloadByteRange(start: cursor, end: range.start))
            }
            cursor = max(cursor, range.end)
        }
        if cursor < totalBytes {
            missing.append(DownloadByteRange(start: cursor, end: totalBytes))
        }
        return missing
    }

    @discardableResult
    static func insert(_ incoming: DownloadByteRange, into sortedCoalesced: inout [DownloadByteRange]) -> Int64 {
        guard incoming.start >= 0, incoming.end > incoming.start else { return 0 }
        let count = sortedCoalesced.count
        if count == 0 {
            sortedCoalesced.append(incoming)
            return incoming.length
        }
        // Fast path: appending at or past the tail.
        let lastIndex = count - 1
        let last = sortedCoalesced[lastIndex]
        if incoming.start > last.end {
            sortedCoalesced.append(incoming)
            return incoming.length
        }
        if incoming.start >= last.start {
            guard incoming.end > last.end else { return 0 }
            let added = incoming.end - last.end
            sortedCoalesced[lastIndex] = DownloadByteRange(start: last.start, end: incoming.end)
            return added
        }

        // Binary search for the first range whose end >= incoming.start.
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if sortedCoalesced[mid].end < incoming.start {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low == count || sortedCoalesced[low].start > incoming.end {
            sortedCoalesced.insert(incoming, at: low)
            return incoming.length
        }

        let mergedStart = min(incoming.start, sortedCoalesced[low].start)
        var mergedEnd = max(incoming.end, sortedCoalesced[low].end)
        var replacedBytes = sortedCoalesced[low].length
        var mergeEndIndex = low + 1
        while mergeEndIndex < count, sortedCoalesced[mergeEndIndex].start <= mergedEnd {
            let next = sortedCoalesced[mergeEndIndex]
            replacedBytes += next.length
            if next.end > mergedEnd { mergedEnd = next.end }
            mergeEndIndex += 1
        }
        let merged = DownloadByteRange(start: mergedStart, end: mergedEnd)
        sortedCoalesced[low] = merged
        if mergeEndIndex > low + 1 {
            sortedCoalesced.removeSubrange((low + 1)..<mergeEndIndex)
        }
        return merged.length - replacedBytes
    }

    static func totalBytes(in ranges: [DownloadByteRange]) -> Int64 {
        guard !ranges.isEmpty else { return 0 }
        var isAlreadyCoalesced = true
        var previousEnd: Int64 = -1
        for range in ranges {
            if range.start < 0 || range.end <= range.start || range.start <= previousEnd {
                isAlreadyCoalesced = false
                break
            }
            previousEnd = range.end
        }
        let source = isAlreadyCoalesced ? ranges : coalesce(ranges)
        return source.reduce(into: Int64(0)) { total, range in
            let (sum, overflow) = total.addingReportingOverflow(range.length)
            total = overflow ? Int64.max : sum
        }
    }

    static func isComplete(_ completed: [DownloadByteRange], totalBytes: Int64) -> Bool {
        guard totalBytes > 0 else { return false }
        let merged = clamped(completed, totalBytes: totalBytes)
        return merged.count == 1 && merged[0].start == 0 && merged[0].end == totalBytes
    }

    static func covers(_ completed: [DownloadByteRange], target: Range<Int64>) -> Bool {
        guard target.lowerBound >= 0, target.upperBound > target.lowerBound else { return true }
        return coalesce(completed).contains {
            $0.start <= target.lowerBound && $0.end >= target.upperBound
        }
    }

    static func contiguousPrefixLength(in ranges: [DownloadByteRange]) -> Int64 {
        let merged = coalesce(ranges)
        guard let first = merged.first, first.start == 0 else { return 0 }
        return first.end
    }
}

// MARK: - Manifest

struct DownloadManifest: Codable, Equatable, Sendable {
    static let fileName = "manifest.json"
    static let currentVersion = 2
    static let supportedVersions: ClosedRange<Int> = 1...currentVersion

    var version: Int
    let contentID: String
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let coverURL: String
    let ownerName: String
    let durationSeconds: Int
    let requestedQuality: Int
    var resolvedQuality: Int?
    var codecs: String?
    var hasSeparateAudio: Bool?
    var expectedBytes: [String: Int64]
    var userPaused: Bool?
    var completedRanges: [String: [DownloadByteRange]]?

    var allowsAutomaticResume: Bool { userPaused != true }

    init(
        version: Int = DownloadManifest.currentVersion,
        contentID: String,
        aid: Int,
        bvid: String,
        cid: Int,
        title: String,
        coverURL: String,
        ownerName: String,
        durationSeconds: Int,
        requestedQuality: Int,
        resolvedQuality: Int? = nil,
        codecs: String? = nil,
        hasSeparateAudio: Bool? = nil,
        expectedBytes: [String: Int64] = [:],
        completedRanges: [String: [DownloadByteRange]]? = nil
    ) {
        self.version = version
        self.contentID = contentID
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
        self.requestedQuality = requestedQuality
        self.resolvedQuality = resolvedQuality
        self.codecs = codecs
        self.hasSeparateAudio = hasSeparateAudio
        self.userPaused = nil
        self.expectedBytes = expectedBytes
        self.completedRanges = completedRanges
    }

    func expected(_ stage: DownloadStage) -> Int64? {
        guard let value = expectedBytes[stage.rawValue], value > 0 else { return nil }
        return value
    }

    mutating func setExpected(_ stage: DownloadStage, bytes: Int64) {
        guard bytes > 0 else { return }
        expectedBytes[stage.rawValue] = bytes
    }

    func completedRanges(for stage: DownloadStage) -> [DownloadByteRange]? {
        completedRanges?[stage.rawValue]
    }

    mutating func setCompletedRanges(_ ranges: [DownloadByteRange], for stage: DownloadStage) {
        var map = completedRanges ?? [:]
        map[stage.rawValue] = DownloadByteRange.coalesce(ranges)
        completedRanges = map
    }

    mutating func clearCompletedRanges(for stage: DownloadStage) {
        completedRanges?[stage.rawValue] = nil
        if completedRanges?.isEmpty == true {
            completedRanges = nil
        }
    }

    func effectiveCompletedRanges(
        for stage: DownloadStage,
        fileLength: Int64
    ) -> [DownloadByteRange] {
        let onDisk = max(0, fileLength)
        guard onDisk > 0 else { return [] }
        if let recorded = completedRanges?[stage.rawValue] {
            return DownloadByteRange.clamped(recorded, totalBytes: onDisk)
        }
        return [DownloadByteRange(start: 0, end: onDisk)]
    }

    func effectiveDownloadedBytes(for stage: DownloadStage, fileLength: Int64) -> Int64 {
        DownloadByteRange.totalBytes(
            in: effectiveCompletedRanges(for: stage, fileLength: fileLength)
        )
    }

    var expectedBytesByStage: [DownloadStage: Int64] {
        var mapped: [DownloadStage: Int64] = [:]
        for (key, value) in expectedBytes {
            guard let stage = DownloadStage(rawValue: key), value > 0 else { continue }
            mapped[stage] = value
        }
        return mapped
    }

    var totalExpectedBytes: Int64? {
        guard let hasSeparateAudio else { return nil }
        let required: [DownloadStage] = hasSeparateAudio ? [.video, .audio] : [.video]
        var total: Int64 = 0
        for stage in required {
            guard let value = expected(stage) else { return nil }
            total += value
        }
        return total
    }

    func matchesResolvedStream(quality: Int, codecs: String) -> Bool {
        guard let resolvedQuality, let existingCodecs = self.codecs else { return true }
        return resolvedQuality == quality && existingCodecs == codecs
    }

    var isCurrentVersion: Bool { version == Self.currentVersion }
    var isSupportedVersion: Bool { Self.supportedVersions.contains(version) }
}

struct DownloadAutomaticResumeQueue: Equatable, Sendable {
    private var ids: Set<String> = []

    var isEmpty: Bool { ids.isEmpty }

    mutating func enqueue<S: Sequence>(_ newIDs: S) where S.Element == String {
        ids.formUnion(newIDs)
    }

    mutating func revoke(_ id: String) {
        ids.remove(id)
    }

    mutating func takeNext(isBackgrounded: Bool) -> String? {
        guard !isBackgrounded, let id = ids.min() else { return nil }
        ids.remove(id)
        return id
    }
}

// MARK: - Stage planning

enum DownloadStagePlan: Equatable, Sendable {
    case complete
    case restart
    case resume(fromByte: Int64)
}

enum DownloadResumePolicy {
    static func stagePlan(bytesOnDisk: Int64, expectedBytes: Int64?) -> DownloadStagePlan {
        let onDisk = max(0, bytesOnDisk)
        guard onDisk > 0 else { return .restart }
        guard let expectedBytes, expectedBytes > 0 else {
            return .resume(fromByte: onDisk)
        }
        if onDisk >= expectedBytes {
            return onDisk == expectedBytes ? .complete : .restart
        }
        return .resume(fromByte: onDisk)
    }
}

// MARK: - Content-Range

struct DownloadContentRange: Equatable, Sendable {
    let firstByte: Int64
    let lastByte: Int64
    let totalLength: Int64?

    static func parse(_ header: String?) -> DownloadContentRange? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
            .trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let rangePart = parts.first else { return nil }
        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let last = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              first >= 0,
              last >= first
        else { return nil }

        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        let total: Int64?
        if totalText == "*" {
            total = nil
        } else {
            guard let parsed = Int64(totalText), parsed > last else { return nil }
            total = parsed
        }
        guard last < Int64.max else { return nil }
        return DownloadContentRange(firstByte: first, lastByte: last, totalLength: total)
    }
}

// MARK: - Range response admission

enum DownloadRangeVerdict: Equatable, Sendable {
    case append(atByte: Int64, totalLength: Int64?)
    case replaceFromZero(totalLength: Int64?)
    case restartRequest
    case reject(DownloadTransferError)
}

enum DownloadRangeResponsePolicy {
    static func verdict(
        statusCode: Int,
        contentRange: String?,
        contentLength: Int64?,
        requestedOffset: Int64,
        knownTotalLength: Int64?,
        host: String
    ) -> DownloadRangeVerdict {
        if statusCode == 416 {
            return requestedOffset > 0 ? .restartRequest
                : .reject(.httpStatus(host: host, code: statusCode))
        }
        if statusCode == 200 {
            let stated = contentLength.flatMap { $0 > 0 ? $0 : nil }
            if requestedOffset > 0, let stated, let knownTotalLength, knownTotalLength > 0,
               stated != knownTotalLength {
                return .restartRequest
            }
            return .replaceFromZero(totalLength: stated ?? knownTotalLength)
        }
        guard statusCode == 206 else {
            return .reject(.httpStatus(host: host, code: statusCode))
        }
        guard let range = DownloadContentRange.parse(contentRange),
              contentLength == nil || contentLength == range.lastByte - range.firstByte + 1
        else { return .reject(.rangeNotHonoured(host: host)) }
        guard range.totalLength != nil || knownTotalLength != nil else {
            return .reject(.rangeNotHonoured(host: host))
        }
        let total = range.totalLength ?? knownTotalLength
        if let total, range.lastByte >= total {
            return .reject(.rangeNotHonoured(host: host))
        }
        if requestedOffset > 0, let knownTotalLength,
           let stated = range.totalLength, stated != knownTotalLength {
            return .restartRequest
        }
        guard range.firstByte == requestedOffset else {
            guard range.firstByte == 0 else {
                return .reject(.rangeNotHonoured(host: host))
            }
            return .replaceFromZero(totalLength: total)
        }
        return .append(atByte: range.firstByte, totalLength: total)
    }
}

// MARK: - Completeness

enum DownloadCompletenessVerdict: Equatable, Sendable {
    case complete(totalBytes: Int64)
    case short(stage: DownloadStage, onDisk: Int64, expected: Int64)
    case missing(stage: DownloadStage)
    case unverifiable(stage: DownloadStage, onDisk: Int64)

    var isVerified: Bool {
        switch self {
        case .complete: true
        case .unverifiable, .short, .missing: false
        }
    }
}

enum DownloadCompletenessPolicy {
    static func verdict(
        stages: [DownloadStage],
        bytesOnDisk: [DownloadStage: Int64],
        expected: [DownloadStage: Int64]
    ) -> DownloadCompletenessVerdict {
        var total: Int64 = 0
        var unverifiable: DownloadCompletenessVerdict?
        for stage in stages {
            let onDisk = bytesOnDisk[stage] ?? 0
            guard onDisk > 0 else { return .missing(stage: stage) }
            total += onDisk
            guard let expectedBytes = expected[stage], expectedBytes > 0 else {
                if unverifiable == nil {
                    unverifiable = .unverifiable(stage: stage, onDisk: onDisk)
                }
                continue
            }
            guard onDisk == expectedBytes else {
                return .short(stage: stage, onDisk: onDisk, expected: expectedBytes)
            }
        }
        return unverifiable ?? .complete(totalBytes: total)
    }
}

// MARK: - Staging identity

enum DownloadStagingIdentity {
    static func folderName(contentID: String) -> String { contentID }

    static func matches(folderName: String, contentID: String) -> Bool {
        folderName == contentID
    }
}
