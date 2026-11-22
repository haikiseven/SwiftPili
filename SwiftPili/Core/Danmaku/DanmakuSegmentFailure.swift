import Foundation

/// One `seg.so` reply, before anybody has decided what it is.
///
/// Status and content type travel with the bytes because the device captures
/// of 2026-09-26 could not answer the one question that mattered: 24 of 38
/// fetches logged `0 bullets`, and nothing in the log said whether those were
/// empty segments or risk-control envelopes. Carrying the evidence to the one
/// place that classifies it is what lets a single capture answer that.
struct DanmakuSegmentResponse: Sendable, Equatable {
    let status: Int
    let contentType: String?
    let body: Data
}

/// Why a segment did not become bullets.
///
/// Every case except `.malformed` backs off and tries again later; the kind
/// decides how long, and the log line names it so a capture can tell risk
/// control from a dead network from real emptiness.
enum DanmakuSegmentFailureKind: Equatable, Sendable, CustomStringConvertible {
    /// The request never completed: DNS, TLS, timeout, connection lost.
    /// `BiliAPIClient` has already spent its own GET retries by the time this
    /// is recorded, so one of these is up to three wire attempts.
    case transport
    /// A non-2xx status that is not a risk-control verdict.
    case http(status: Int)
    /// A risk-control verdict — a known code in a JSON envelope (which arrives
    /// as HTTP 200) or HTTP 412. Backs off longer than the rest: asking again
    /// quickly is what keeps the verdict in force.
    case riskControl(code: Int)
    /// A JSON envelope with some other code, or a `{` body that is not an
    /// envelope at all. Not protobuf either way, so it must not reach the
    /// decoder — and must not be recorded as an empty segment.
    case apiEnvelope(code: Int?)
    /// A 200 whose body is text that is neither protobuf nor a JSON envelope:
    /// an HTML page (`<`-first, or labelled `text/html`) from a carrier portal
    /// or a WAF, or a byte-order mark. Never `.malformed`: the next request
    /// may well reach `seg.so`, and a terminal verdict here would drop the
    /// segment's bullets for the rest of the content over a captive portal.
    case unexpectedBody
    /// Bytes that claimed to be protobuf and are not. Terminal for this
    /// segment of this content: the same request returns the same bytes, and
    /// asking again only spends the risk-control budget of a healthy client.
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

/// What a reply is, decided once, before any decode.
enum DanmakuSegmentVerdict: Equatable, Sendable {
    /// Protobuf — including a zero-byte body, which is a valid message with no
    /// fields and therefore a genuinely empty segment.
    case protobuf
    case failure(DanmakuSegmentFailureKind)
}

/// Classifies a `seg.so` reply without decoding it.
///
/// **Order of evidence.** Status first: a non-2xx never carries bullets.
/// Then emptiness: zero bytes is the empty protobuf message, so a quiet video
/// stays a valid empty segment rather than being retried forever. Then text
/// that can never be a `seg.so` message, judged by its first byte — every
/// real reply opens with `0x0A` (field 1, length-delimited):
///
/// - `<` (`0x3C`, wire type 4, end-group) or a `text/html` label: an HTML page
///   from a carrier portal or WAF → `.unexpectedBody`. The label alone is
///   enough because the costs are asymmetric: misreading a mislabelled
///   protobuf body as a page costs one retry, misreading a page as protobuf
///   costs a terminal `.malformed` for the rest of the content.
/// - `{` (`0x7B`, field 15, start-group): a JSON envelope — risk control
///   answers HTTP 200 with `{"code":-352,…}`, so neither the status line nor
///   (in practice) the content type is enough on its own.
/// - A UTF-8 byte-order mark (`0xEF`, wire type 7, which does not exist).
///
/// Leading whitespace is the one ambiguous case: `0x0A` is also `\n`, and
/// `\n{` is a legitimate reply whose first element is 123 bytes long. So a
/// body behind whitespace (or a BOM) is judged a failure only on positive
/// evidence — it parses as a JSON object, or it opens with markup — and is
/// otherwise left to the decoder. A `json` content type proves nothing on its
/// own: a JSON body is caught by the byte rules above whatever its label, and
/// a protobuf body mislabelled `json` keeps its bullets.
enum DanmakuSegmentClassifier {
    /// Codes BiliBili uses for risk control / rate limiting on web endpoints:
    /// -352 risk-control check failed, -412 request intercepted, -509 and
    /// -799 request too frequent. Anything else in an envelope is an ordinary
    /// API error — still a failure, backed off on the shorter schedule.
    static let riskControlCodes: Set<Int> = [-352, -412, -509, -799]

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func classify(_ response: DanmakuSegmentResponse) -> DanmakuSegmentVerdict {
        guard (200 ... 299).contains(response.status) else {
            // BiliBili's 412 is its risk-control interception page, the same
            // verdict the envelope spells as -412.
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
            // Whitespace alone is not a reply either (`\t`/`\r` are wire types
            // `seg.so` never uses, and a lone `\n` is a truncated field).
            if text.isEmpty || opensWithMarkup(text) {
                return .failure(.unexpectedBody)
            }
        }
        return hasByteOrderMark ? .failure(.unexpectedBody) : .protobuf
    }

    /// The failure a JSON object body spells, or nil when `body` is not a JSON
    /// object at all. An object without a usable integer `code` is still not
    /// protobuf: `.apiEnvelope(code: nil)`.
    private static func envelopeKind(in body: Data) -> DanmakuSegmentFailureKind? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return nil }
        guard let code = envelope.code else { return .apiEnvelope(code: nil) }
        return riskControlCodes.contains(code) ? .riskControl(code: code) : .apiEnvelope(code: code)
    }

    /// Decodes only as a JSON object; `code` is read leniently so a string or
    /// missing code still identifies the body as an envelope.
    private struct Envelope: Decodable {
        let code: Int?

        private enum Key: CodingKey { case code }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
        }
    }

    /// `body` without a leading UTF-8 BOM and ASCII whitespace.
    private static func strippingTextPreamble(_ body: Data) -> Data {
        var rest = body.starts(with: byteOrderMark) ? body.dropFirst(byteOrderMark.count) : body[...]
        while let byte = rest.first, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            rest = rest.dropFirst()
        }
        return Data(rest)
    }

    /// `<!` (doctype / comment), `<?` (XML declaration) or an `<html`, `<head`
    /// or `<body` tag. Stricter than `<` alone on purpose: behind a `\n`, a
    /// `<` byte is also a protobuf length (60).
    private static func opensWithMarkup(_ text: Data) -> Bool {
        guard text.first == UInt8(ascii: "<"), text.count >= 2 else { return false }
        let second = text[text.startIndex + 1]
        if second == UInt8(ascii: "!") || second == UInt8(ascii: "?") { return true }
        let head = String(decoding: text.prefix(5), as: UTF8.self).lowercased()
        return head == "<html" || head == "<head" || head == "<body"
    }
}

/// How long a failed segment waits before it may be asked for again.
///
/// Exponential with a ceiling, in rounds of `maxAttempts`, then a long
/// cool-down:
///
/// | kind | after 1st | after 2nd | after 3rd | after 4th |
/// |---|---|---|---|---|
/// | transport / http / apiEnvelope / unexpectedBody | 4s | 8s | 16s | 10 min, new round |
/// | riskControl | 15s | 30s | 60s | 10 min, new round |
/// | malformed | never | | | |
///
/// Why these numbers: the store's plan runs at the 4Hz media tick, so without
/// a schedule a failing segment was re-requested ~4×/s (D1), each request
/// itself up to three GET attempts inside `BiliAPIClient`. Four attempts
/// spread over ~half a minute (transport) or ~two minutes (risk control)
/// rides out a network hand-off or a short risk-control window without
/// turning a soft ban into a hard one.
///
/// **Exhaustion is a cool-down, not a verdict (A1a).** None of the retryable
/// kinds says anything about the segment itself — a dead network, a WAF page
/// or a risk-control window all end — so after the fourth failure the segment
/// waits `exhaustedCooldown` and then starts a fresh round of four. Ten
/// minutes is long enough that a player sitting on a risk-controlled video
/// spends at most four requests per segment per ten minutes (the budget a
/// soft ban tolerates), and short enough that a long film is not left without
/// bullets for the rest of the session over one bad minute. A network path
/// change ends every wait early (`DanmakuSegmentFailureState.resetForNetworkChange`).
///
/// Only `.malformed` is terminal: the same request returns the same bytes.
/// A new content (`reset(oid:)`) starts over either way.
enum DanmakuSegmentRetryPolicy {
    static let maxAttempts = 4
    static let ceiling: TimeInterval = 60
    /// The wait after the last attempt of a round. See the type comment.
    static let exhaustedCooldown: TimeInterval = 600

    static func baseDelay(for kind: DanmakuSegmentFailureKind) -> TimeInterval {
        switch kind {
        case .riskControl: 15
        case .transport, .http, .apiEnvelope, .unexpectedBody, .malformed: 4
        }
    }

    /// Seconds to wait after the `attempts`-th consecutive failure of the
    /// current round, or nil when the kind admits no further attempt at all.
    /// The round's last attempt (`attempts >= maxAttempts`) earns the
    /// cool-down; `DanmakuSegmentFailureState.recording` then starts the next
    /// round at attempt 1.
    static func delay(after kind: DanmakuSegmentFailureKind, attempts: Int) -> TimeInterval? {
        guard !kind.isTerminal, attempts >= 1 else { return nil }
        guard attempts < maxAttempts else { return exhaustedCooldown }
        // `attempts < maxAttempts` already bounds the exponent; the `min` is
        // there so a future cap change cannot overflow `pow` into infinity.
        let exponent = Double(min(attempts - 1, 16))
        return min(ceiling, baseDelay(for: kind) * pow(2, exponent))
    }
}

/// One segment's failure record: what went wrong, how often, and when it may
/// be asked for again. Kept per content, across window moves and across a
/// same-content reload, so neither a seek loop nor a quality-switch loop can
/// reset the budget and re-hammer a risk-control verdict.
struct DanmakuSegmentFailureState: Equatable, Sendable {
    let kind: DanmakuSegmentFailureKind
    /// Consecutive failed attempts in the current round, including this one.
    /// Zero only after `resetForNetworkChange`: no attempt yet in this round.
    let attempts: Int
    /// Monotonic seconds after which a retry is admitted; nil means never
    /// again for this content (`.malformed` only).
    let nextEligibleAt: TimeInterval?

    var isTerminal: Bool { nextEligibleAt == nil }

    func isEligible(at now: TimeInterval) -> Bool {
        nextEligibleAt.map { now >= $0 } ?? false
    }

    /// The record after one more failure of `kind` at `now`. A failure after
    /// a finished round (its cool-down elapsed) opens the next round at 1.
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

    /// The record once the network path has changed: eligible at `now` with
    /// a fresh round, or unchanged when terminal (the bytes were the problem,
    /// not the route).
    ///
    /// Deliberately still a record rather than no record: `admitCursor` treats
    /// a failed segment as resolved, so the retry this admits cannot park the
    /// cursor and then land the stretch it waited on as one stale burst (A1).
    func resetForNetworkChange(at now: TimeInterval) -> DanmakuSegmentFailureState {
        guard !kind.isTerminal else { return self }
        return DanmakuSegmentFailureState(kind: kind, attempts: 0, nextEligibleAt: now)
    }
}
