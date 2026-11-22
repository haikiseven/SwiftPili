import Foundation

struct DanmakuSegmentResponse: Sendable, Equatable {
    let status: Int
    let contentType: String?
    let body: Data
}

enum DanmakuSegmentFailureKind: Equatable, Sendable, CustomStringConvertible {
    case transport
    case http(status: Int)
    case riskControl(code: Int)
    case apiEnvelope(code: Int?)
    case unexpectedBody
    case malformed

    var isTerminal: Bool { self == .malformed }

    var description: String {
        switch self {
        case .transport: "transport"
        case .http(let status): "http(\(status))"
        case .riskControl(let code): "riskControl(\(code))"
        case .apiEnvelope(let code): "apiEnvelope(\(code.map(String.init) ?? "unparsed"))"
        case .unexpectedBody: "unexpectedBody"
        case .malformed: "malformed"
        }
    }
}

enum DanmakuSegmentVerdict: Equatable, Sendable {
    case protobuf
    case failure(DanmakuSegmentFailureKind)
}

enum DanmakuSegmentClassifier {
    static let riskControlCodes: Set<Int> = [-352, -412, -509, -799]

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func classify(_ response: DanmakuSegmentResponse) -> DanmakuSegmentVerdict {
        guard (200 ... 299).contains(response.status) else {
            return .failure(
                response.status == 412
                    ? .riskControl(code: -412)
                    : .http(status: response.status)
            )
        }
        let body = response.body
        guard let first = body.first else { return .protobuf }
        let contentType = response.contentType?.lowercased() ?? ""
        if first == UInt8(ascii: "<") || contentType.contains("text/html") {
            return .failure(.unexpectedBody)
        }
        if first == UInt8(ascii: "{") {
            return .failure(envelopeKind(in: body) ?? .apiEnvelope(code: nil))
        }
        let hasByteOrderMark = body.starts(with: byteOrderMark)
        let text = strippingTextPreamble(body)
        let hadPreamble = text.count < body.count
        if hadPreamble {
            if text.first == UInt8(ascii: "{"), let kind = envelopeKind(in: text) {
                return .failure(kind)
            }
            if text.isEmpty || opensWithMarkup(text) {
                return .failure(.unexpectedBody)
            }
        }
        return hasByteOrderMark ? .failure(.unexpectedBody) : .protobuf
    }

    private static func envelopeKind(in body: Data) -> DanmakuSegmentFailureKind? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return nil }
        guard let code = envelope.code else { return .apiEnvelope(code: nil) }
        return riskControlCodes.contains(code) ? .riskControl(code: code) : .apiEnvelope(code: code)
    }

    private struct Envelope: Decodable {
        let code: Int?

        private enum Key: CodingKey { case code }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
        }
    }

    private static func strippingTextPreamble(_ body: Data) -> Data {
        var rest = body.starts(with: byteOrderMark) ? body.dropFirst(byteOrderMark.count) : body[...]
        while let byte = rest.first, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            rest = rest.dropFirst()
        }
        return Data(rest)
    }

    private static func opensWithMarkup(_ text: Data) -> Bool {
        guard text.first == UInt8(ascii: "<"), text.count >= 2 else { return false }
        let second = text[text.startIndex + 1]
        if second == UInt8(ascii: "!") || second == UInt8(ascii: "?") { return true }
        let head = String(decoding: text.prefix(5), as: UTF8.self).lowercased()
        return head == "<html" || head == "<head" || head == "<body"
    }
}

enum DanmakuSegmentRetryPolicy {
    static let maxAttempts = 4
    static let ceiling: TimeInterval = 60
    static let exhaustedCooldown: TimeInterval = 600

    static func baseDelay(for kind: DanmakuSegmentFailureKind) -> TimeInterval {
        switch kind {
        case .riskControl: 15
        case .transport, .http, .apiEnvelope, .unexpectedBody, .malformed: 4
        }
    }

    static func delay(after kind: DanmakuSegmentFailureKind, attempts: Int) -> TimeInterval? {
        guard !kind.isTerminal, attempts >= 1 else { return nil }
        guard attempts < maxAttempts else { return exhaustedCooldown }
        let exponent = Double(min(attempts - 1, 16))
        return min(ceiling, baseDelay(for: kind) * pow(2, exponent))
    }
}

struct DanmakuSegmentFailureState: Equatable, Sendable {
    let kind: DanmakuSegmentFailureKind
    let attempts: Int
    let nextEligibleAt: TimeInterval?

    var isTerminal: Bool { nextEligibleAt == nil }

    func isEligible(at now: TimeInterval) -> Bool {
        nextEligibleAt.map { now >= $0 } ?? false
    }

    static func recording(
        _ kind: DanmakuSegmentFailureKind,
        after previous: DanmakuSegmentFailureState?,
        at now: TimeInterval
    ) -> DanmakuSegmentFailureState {
        let previousAttempts = previous?.attempts ?? 0
        let attempts = previousAttempts >= DanmakuSegmentRetryPolicy.maxAttempts
            ? 1
            : previousAttempts + 1
        let delay = DanmakuSegmentRetryPolicy.delay(after: kind, attempts: attempts)
        return DanmakuSegmentFailureState(
            kind: kind,
            attempts: attempts,
            nextEligibleAt: delay.map { now + $0 }
        )
    }

    func resetForNetworkChange(at now: TimeInterval) -> DanmakuSegmentFailureState {
        guard !kind.isTerminal else { return self }
        return DanmakuSegmentFailureState(kind: kind, attempts: 0, nextEligibleAt: now)
    }
}
