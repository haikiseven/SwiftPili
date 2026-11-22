import Foundation

struct BiliResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: T?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case msg
        case data
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(Int.self, forKey: .code)
        self.message = (try? container.decode(String.self, forKey: .message))
            ?? (try? container.decode(String.self, forKey: .msg))
            ?? ""
        // PGC endpoints (pgc/view/web/season, pgc/player/web/playurl) have
        // NO `data` key — the payload lives under `result`. Crucially,
        // decodeIfPresent(.data) does NOT throw for an absent key, it
        // returns nil — so a catch-based fallback never fired and `result`
        // payloads decoded to nothing (then got synthesized as empty).
        if container.contains(.data) {
            do {
                self.data = try container.decodeIfPresent(T.self, forKey: .data)
            } catch {
                PlayerLog.log("[Decode] .data failed: \(error)")
                self.data = try? container.decodeIfPresent(T.self, forKey: .result)
            }
        } else if container.contains(.result) {
            do {
                self.data = try container.decodeIfPresent(T.self, forKey: .result)
            } catch {
                PlayerLog.log("[Decode] .result failed: \(error)")
                self.data = nil
            }
        } else {
            self.data = nil
        }
    }
}

enum BiliError: Error, Sendable, LocalizedError {
    case network(any Error & Sendable)
    case httpError(statusCode: Int, retryAfter: TimeInterval? = nil)
    case apiError(code: Int, message: String)
    case authRequired
    case decodingFailed(any Error & Sendable)

    var errorDescription: String? {
        switch self {
        case .network(let error):
            String(format: String(localized: "Network error: %@"), error.localizedDescription)
        case .httpError(let code, _):
            String(format: String(localized: "HTTP error: %lld"), code)
        case .apiError(let code, let message):
            String(format: String(localized: "API error %lld: %@"), code, message)
        case .authRequired:
            String(localized: "Login required")
        case .decodingFailed(let error):
            String(format: String(localized: "Decoding failed: %@"), error.localizedDescription)
        }
    }

    /// The main-site risk control turned the request away: `-352` (校验失败),
    /// `-412` / HTTP 412 (请求被拦截), `-401` (非法访问). The same request can
    /// succeed through a different, unprotected endpoint; no other failure
    /// has that property, so only these may select a fallback source.
    var isRiskControlRejection: Bool {
        switch self {
        case .apiError(let code, _): [-352, -401, -412].contains(code)
        case .httpError(let statusCode, _): statusCode == 412
        default: false
        }
    }

    /// True when the underlying failure is a cancelled URLSession task or
    /// Swift task — a superseded load, a dismissed screen, or a network
    /// hand-off tearing down in-flight requests. Benign by definition:
    /// callers must not surface it as a user-facing error.
    var isCancellation: Bool {
        guard case .network(let inner) = self else { return false }
        if inner is CancellationError { return true }
        let ns = inner as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

/// Parse response metadata once, before the response is discarded. This does not
/// change the API client's existing request retry policy.
enum HTTPRetryAfter {
    static func delay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
           let seconds = TimeInterval(trimmed), seconds.isFinite, seconds > 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        let seconds = date.timeIntervalSinceNow
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
