import Foundation

/// Follows `b23.tv` shortener redirects manually so each hop's scheme and the total
/// hop count are enforced before `BiliLinkResolver.resolveRedirect` validates the final host.
final class BiliShortLinkTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BiliShortLinkTransport()

    private static let maximumHops = 3
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration)
        super.init()
    }

    /// Refuses automatic redirects so `resolvedURL(for:)` observes and bounds every 3xx hop.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func resolvedURL(for url: URL) async throws(BiliError) -> URL {
        var current = url
        for hop in 0..<Self.maximumHops {
            guard !Task.isCancelled else { throw .network(URLError(.cancelled)) }
            guard BiliLinkHostPolicy.isSupportedScheme(current.scheme) else {
                throw .apiError(code: -1, message: String(localized: "Link Unavailable"))
            }
            var request = URLRequest(url: current)
            request.httpMethod = "HEAD"
            request.setValue(BiliAPIClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            let response: URLResponse
            do {
                (_, response) = try await session.data(for: request, delegate: self)
            } catch {
                throw .network(error)
            }
            guard !Task.isCancelled else { throw .network(URLError(.cancelled)) }
            guard let http = response as? HTTPURLResponse else { throw .network(URLError(.badServerResponse)) }

            guard (300...399).contains(http.statusCode) else {
                guard (200...299).contains(http.statusCode) else { throw .httpError(statusCode: http.statusCode) }
                return http.url ?? current
            }
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL
            else { throw .apiError(code: -1, message: String(localized: "Link Unavailable")) }
            PlayerLog.log("[BiliLink] hop \(hop + 1) → \(next.host ?? "?")\(next.path.prefix(48))")
            current = next
        }
        PlayerLog.log("[BiliLink] redirect chain exceeded \(Self.maximumHops) hops — refused")
        throw .apiError(code: -1, message: String(localized: "Link Unavailable"))
    }
}
