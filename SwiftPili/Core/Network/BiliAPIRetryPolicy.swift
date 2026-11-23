import Foundation

struct BiliAPIRetryPolicy: Sendable {
    static let perAttemptInactivityTimeout: TimeInterval = 15
    static let minRetryAfterDelay: TimeInterval = 0.5
    static let maxRetryAfterDelay: TimeInterval = 8.0

    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .cannotFindHost,
        .secureConnectionFailed,
        .badServerResponse,
        .cannotLoadFromNetwork,
        .resourceUnavailable,
    ]

    static let transientHTTPStatusCodes: Set<Int> = [
        408, 412, 429, 500, 502, 503, 504,
    ]

    static let retryableWBIErrorCodes: Set<Int> = [
        -352, -403, -412,
    ]

    static func maxAttempts(for method: BiliEndpoint.HTTPMethod) -> Int {
        method == .get ? 3 : 1
    }

    static func shouldRetry(
        method: BiliEndpoint.HTTPMethod,
        attempt: Int,
        error: Error
    ) -> Bool {
        guard attempt < maxAttempts(for: method), isTransient(error) else {
            return false
        }
        return true
    }

    static func shouldRetryHTTPStatus(
        method: BiliEndpoint.HTTPMethod,
        attempt: Int,
        statusCode: Int
    ) -> Bool {
        guard attempt < maxAttempts(for: method) else {
            return false
        }
        return isTransientHTTPStatus(statusCode)
    }

    static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        transientHTTPStatusCodes.contains(statusCode)
    }

    static func isRetryableWBIErrorCode(_ code: Int) -> Bool {
        retryableWBIErrorCodes.contains(code)
    }

    static func retryDelay(
        attempt: Int,
        retryAfter: TimeInterval? = nil
    ) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return min(max(retryAfter, minRetryAfterDelay), maxRetryAfterDelay)
        }
        let baseDelay: TimeInterval
        switch attempt {
        case ...1:
            baseDelay = 0.5
        case 2:
            baseDelay = 1.2
        default:
            baseDelay = min(0.5 * pow(2.4, Double(attempt - 1)), maxRetryAfterDelay)
        }
        let jitter = Double.random(in: 0 ... 0.15)
        return min(baseDelay + jitter, maxRetryAfterDelay)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let biliError = error as? BiliError { return biliError.isCancellation }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    static func isTransient(_ error: Error) -> Bool {
        guard !isCancellation(error) else { return false }
        if let biliError = error as? BiliError {
            switch biliError {
            case .network(let inner):
                return isTransient(inner)
            case .httpError(let statusCode, _):
                return isTransientHTTPStatus(statusCode)
            case .apiError, .authRequired, .decodingFailed:
                return false
            }
        }
        guard let urlError = error as? URLError else {
            return false
        }
        return transientURLErrorCodes.contains(urlError.code)
    }
}
