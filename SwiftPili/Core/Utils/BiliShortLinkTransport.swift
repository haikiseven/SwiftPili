import Foundation

final class BiliShortLinkTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BiliShortLinkTransport()

    private static let maximumHops = 5
    private static let headFallbackStatusCodes: Set<Int> = [403, 405, 412]
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

            var http = try await probe(current, method: "HEAD")
            if Self.headFallbackStatusCodes.contains(http.statusCode) {
                PlayerLog.log("[BiliLink] hop \(hop + 1) HEAD returned \(http.statusCode) — retrying with GET")
                http = try await probe(current, method: "GET")
            }

            guard (300...399).contains(http.statusCode) else {
                guard (200...299).contains(http.statusCode) else { throw .httpError(statusCode: http.statusCode) }
                return http.url ?? current
            }
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL
            else { throw .apiError(code: -1, message: String(localized: "Link Unavailable")) }
            PlayerLog.log("[BiliLink] hop \(hop + 1) → \(next.host ?? "?")\(next.path.prefix(48))")

            if next.scheme?.lowercased() == "bilibili" {
                return next
            }
            if BiliLinkHostPolicy.isSupportedScheme(next.scheme), !BiliLinkHostPolicy.isShortener(next.host) {
                return next
            }
            current = next
        }
        PlayerLog.log("[BiliLink] redirect chain exceeded \(Self.maximumHops) hops — refused")
        throw .apiError(code: -1, message: String(localized: "Link Unavailable"))
    }

    private func probe(_ url: URL, method: String) async throws(BiliError) -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(BiliAPIClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let response: URLResponse
        do {
            if method == "HEAD" {
                (_, response) = try await session.data(for: request, delegate: self)
            } else {
                let (bytes, urlResponse) = try await session.bytes(for: request, delegate: self)
                bytes.task.cancel()
                response = urlResponse
            }
        } catch {
            throw .network(error)
        }
        guard !Task.isCancelled else { throw .network(URLError(.cancelled)) }
        guard let http = response as? HTTPURLResponse else { throw .network(URLError(.badServerResponse)) }
        return http
    }
}
