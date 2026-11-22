import Foundation

struct VideoSubmissionIntegrity {

    // MARK: - Findings

    enum RandomAccess: Equatable {
        case rooted
        case unrooted(submissionsSinceOpen: Int)
    }

    enum Continuity: Equatable {
        case first
        case contiguous
        case gap(previousEnd: TimeInterval, next: TimeInterval)
        case regression(previousEnd: TimeInterval, next: TimeInterval)
        case unmeasurable
    }

    enum Tiling: Equatable {
        case exact(nalCount: Int)
        case unknownLengthSize
        case empty
        case truncatedPrefix(offset: Int, remaining: Int)
        case zeroLength(offset: Int)
        case overrun(offset: Int, declared: Int, size: Int)

        var isMalformed: Bool {
            switch self {
            case .exact, .unknownLengthSize, .empty: false
            case .truncatedPrefix, .zeroLength, .overrun: true
            }
        }

        var diagnosticName: String {
            switch self {
            case .exact(let count): "exact(nals=\(count))"
            case .unknownLengthSize: "unknown-length-size"
            case .empty: "empty"
            case let .truncatedPrefix(offset, remaining):
                "truncated-prefix(at=\(offset) remaining=\(remaining))"
            case .zeroLength(let offset): "zero-length(at=\(offset))"
            case let .overrun(offset, declared, size):
                "overrun(at=\(offset) declared=\(declared) size=\(size))"
            }
        }
    }

    // MARK: - State

    private(set) var hasRandomAccess = false
    private(set) var submissionsBeforeRandomAccess = 0
    private(set) var observedSubmissions = 0
    private(set) var discontinuityCount = 0
    private(set) var malformedCount = 0
    private var previousDecodeEnd: TimeInterval?

    static func tolerance(forDuration duration: TimeInterval) -> TimeInterval {
        max(duration * 0.25, 0.001)
    }

    mutating func reset() {
        self = VideoSubmissionIntegrity()
    }

    mutating func noteFlush() {
        previousDecodeEnd = nil
    }

    // MARK: - Rule 1

    mutating func noteRandomAccess(isKeyframe: Bool) -> RandomAccess {
        observedSubmissions += 1
        if isKeyframe { hasRandomAccess = true }
        guard hasRandomAccess else {
            submissionsBeforeRandomAccess += 1
            return .unrooted(submissionsSinceOpen: submissionsBeforeRandomAccess)
        }
        return .rooted
    }

    // MARK: - Rule 2

    mutating func noteDecodeOrder(
        dts: TimeInterval?,
        duration: TimeInterval
    ) -> Continuity {
        guard let dts, dts.isFinite, duration.isFinite, duration > 0 else {
            return .unmeasurable
        }
        defer { previousDecodeEnd = dts + duration }
        guard let previousEnd = previousDecodeEnd, previousEnd.isFinite else {
            return .first
        }
        let tolerance = Self.tolerance(forDuration: duration)
        if dts > previousEnd + tolerance {
            discontinuityCount += 1
            return .gap(previousEnd: previousEnd, next: dts)
        }
        if dts < previousEnd - tolerance {
            discontinuityCount += 1
            return .regression(previousEnd: previousEnd, next: dts)
        }
        return .contiguous
    }

    static func missingFrames(
        previousEnd: TimeInterval,
        next: TimeInterval,
        duration: TimeInterval
    ) -> Int? {
        guard duration.isFinite, duration > 0, next > previousEnd else { return nil }
        return Int(((next - previousEnd) / duration).rounded())
    }

    // MARK: - Rule 3

    mutating func note(tiling: Tiling) {
        if tiling.isMalformed { malformedCount += 1 }
    }

    static func tiling(of data: Data, nalLengthSize: Int?) -> Tiling {
        guard let nalLengthSize, (1...4).contains(nalLengthSize) else {
            return .unknownLengthSize
        }
        guard !data.isEmpty else { return .empty }
        return data.withUnsafeBytes { raw in
            tiling(of: raw, nalLengthSize: nalLengthSize)
        }
    }

    static func tiling(
        of raw: UnsafeRawBufferPointer,
        nalLengthSize: Int
    ) -> Tiling {
        guard (1...4).contains(nalLengthSize) else { return .unknownLengthSize }
        let size = raw.count
        guard size > 0 else { return .empty }
        var offset = 0
        var nalCount = 0
        while offset < size {
            guard size - offset >= nalLengthSize else {
                return .truncatedPrefix(offset: offset, remaining: size - offset)
            }
            var declared = 0
            for index in 0..<nalLengthSize {
                declared = (declared << 8) | Int(raw[offset + index])
            }
            guard declared > 0 else { return .zeroLength(offset: offset) }
            let next = offset + nalLengthSize + declared
            guard next <= size else {
                return .overrun(offset: offset, declared: declared, size: size)
            }
            offset = next
            nalCount += 1
        }
        return .exact(nalCount: nalCount)
    }
}
