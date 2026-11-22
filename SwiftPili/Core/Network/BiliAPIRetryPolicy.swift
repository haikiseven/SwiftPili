import Foundation

/// Pure retry/timeout policy for Bili API requests.
///
/// The transport keeps one bounded inactivity window per attempt. Only
/// idempotent GET requests receive transient retries; POST requests and
/// cancellation/non-transient failures stop immediately.
struct BiliAPIRetryPolicy: Sendable {
    static let perAttemptInactivityTimeout: TimeInterval = 15

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

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    static func isTransient(_ error: Error) -> Bool {
        guard !isCancellation(error),
              let urlError = error as? URLError else {
            return false
        }
        return [
            .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .cannotFindHost,
            .secureConnectionFailed,
        ].contains(urlError.code)
    }
}
