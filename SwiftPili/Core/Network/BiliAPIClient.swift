import Foundation

actor BiliAPIClient {
    static let shared = BiliAPIClient()

    nonisolated static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    nonisolated static let defaultReferer = "https://www.bilibili.com"

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": Self.defaultUserAgent,
            "Referer": Self.defaultReferer,
            "Origin": Self.defaultReferer,
        ]
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = .shared
        // No URL cache for API traffic: responses are authenticated,
        // per-account JSON — a cached myinfo/feed served after an
        // account switch bleeds one account's data into another.
        // (Images are unaffected: Kingfisher runs its own session/cache.)
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // One bounded inactivity window per attempt. GET retry count and
        // transient-error membership live in the pure policy seam so the
        // request and raw-response paths cannot drift.
        config.timeoutIntervalForRequest = BiliAPIRetryPolicy.perAttemptInactivityTimeout
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
    }

    func request<T: Decodable>(
        _ endpoint: BiliEndpoint,
        type: T.Type = T.self
    ) async throws(BiliError) -> T {
        let urlRequest: URLRequest
        do {
            urlRequest = try await endpoint.buildRequest()
        } catch {
            throw .network(error)
        }

        PlayerLog.log("[API] \(endpoint.method.rawValue) \(endpoint.path)")

        let (data, response) = try await requestData(
            urlRequest,
            endpoint: endpoint
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw .network(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            PlayerLog.log("[API] HTTP \(httpResponse.statusCode) for \(endpoint.path)")
            throw .httpError(
                statusCode: httpResponse.statusCode,
                retryAfter: [429, 503].contains(httpResponse.statusCode)
                    ? HTTPRetryAfter.delay(httpResponse.value(forHTTPHeaderField: "Retry-After")) : nil
            )
        }

        let wrapper: BiliResponse<T>
        do {
            wrapper = try decoder.decode(BiliResponse<T>.self, from: data)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            PlayerLog.log("[API] Decode error for \(endpoint.path): \(error)\nResponse: \(preview)")
            throw .decodingFailed(error)
        }

        guard wrapper.code == 0 else {
            // Full body: risk-control rejections (-401) carry diagnostic
            // fields like v_voucher that the typed error would swallow.
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            PlayerLog.log("[API] \(endpoint.path) code=\(wrapper.code): \(preview)")
            throw .apiError(code: wrapper.code, message: wrapper.message)
        }

        guard let result = wrapper.data else {
            // Write endpoints (like, share, history report…) legitimately
            // return {"code":0,"message":"OK"} with NO data field. Synthesize
            // an empty object so empty result types decode instead of
            // failing a successful call.
            if let empty = try? decoder.decode(T.self, from: Data("{}".utf8)) {
                // An all-optional CONTENT model also decodes from {} —
                // which silently masked the missing-envelope bug on PGC
                // endpoints. Make any non-EmptyResult synthesis visible.
                if T.self != EmptyResult.self {
                    PlayerLog.log("[API] ⚠️ \(endpoint.path) returned no data/result payload — synthesized empty \(T.self)")
                }
                return empty
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            PlayerLog.log("[API] Data is nil for \(endpoint.path) (code=0). Response: \(preview)")
            throw .apiError(code: wrapper.code, message: String(localized: "Data decode failed"))
        }

        return result
    }

    func requestRaw(_ endpoint: BiliEndpoint) async throws(BiliError) -> Data {
        let (data, httpResponse) = try await requestRawResponse(endpoint)

        guard (200...299).contains(httpResponse.statusCode) else {
            PlayerLog.log("[API] HTTP \(httpResponse.statusCode) for \(endpoint.path)")
            throw .httpError(
                statusCode: httpResponse.statusCode,
                retryAfter: [429, 503].contains(httpResponse.statusCode)
                    ? HTTPRetryAfter.delay(httpResponse.value(forHTTPHeaderField: "Retry-After")) : nil
            )
        }

        return data
    }

    /// `requestRaw` without the status verdict: the same request building and
    /// the same `requestData` retry policy (GET-only, transient errors only),
    /// but the HTTP response comes back unjudged. For a caller that has to
    /// classify the reply itself — `seg.so` answers risk control as HTTP 200
    /// with a JSON body, so the status line alone cannot say what arrived, and
    /// its log has to carry status and byte count either way.
    func requestRawResponse(
        _ endpoint: BiliEndpoint
    ) async throws(BiliError) -> (Data, HTTPURLResponse) {
        let urlRequest: URLRequest
        do {
            urlRequest = try await endpoint.buildRequest()
        } catch {
            throw .network(error)
        }

        let (data, response) = try await requestData(
            urlRequest,
            endpoint: endpoint
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw .network(URLError(.badServerResponse))
        }
        return (data, httpResponse)
    }

    private func requestData(
        _ request: URLRequest,
        endpoint: BiliEndpoint
    ) async throws(BiliError) -> (Data, URLResponse) {
        let maxAttempts = BiliAPIRetryPolicy.maxAttempts(for: endpoint.method)
        for attempt in 1 ... maxAttempts {
            do {
                return try await session.data(for: request)
            } catch {
                guard BiliAPIRetryPolicy.shouldRetry(
                    method: endpoint.method,
                    attempt: attempt,
                    error: error
                ) else {
                    if !BiliAPIRetryPolicy.isCancellation(error) {
                        PlayerLog.log("[API] Network error: \(error)")
                    }
                    throw .network(error)
                }
                PlayerLog.log(
                    "[API] transient \(error) for \(endpoint.path) "
                        + "(attempt \(attempt)/\(maxAttempts)) — retrying"
                )
                do {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                } catch {
                    throw .network(URLError(.cancelled))
                }
            }
        }
        // The closed range above always returns or throws. Keep a typed,
        // unreachable fallback for future policy changes and compiler flow.
        throw .network(URLError(.unknown))
    }
}
