import Foundation

final class BiliAPIClient: Sendable {
    static let shared = BiliAPIClient()

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let defaultReferer = "https://www.bilibili.com"

    private let session: URLSession

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
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = BiliAPIRetryPolicy.perAttemptInactivityTimeout
        self.session = URLSession(configuration: config)
    }

    fileprivate struct RequestResult: Sendable {
        let data: Data
        let response: HTTPURLResponse
        let didRefreshWBI: Bool
    }

    fileprivate enum TransientStatusAction: Sendable {
        case proceed
        case retry
        case retryWithWBIRefresh
    }

    func request<T: Decodable>(
        _ endpoint: BiliEndpoint,
        type: T.Type = T.self
    ) async throws(BiliError) -> T {
        var didRefreshWBI = false

        while true {
            PlayerLog.log("[API] \(endpoint.method.rawValue) \(endpoint.path)")
            let result = try await performRequest(
                endpoint,
                allowHTTP412WBIRefresh: !didRefreshWBI
            )
            didRefreshWBI = didRefreshWBI || result.didRefreshWBI

            let httpResponse = result.response
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 412,
                   canRefreshWBI(for: endpoint, didRefreshWBI: didRefreshWBI) {
                    if Task.isCancelled { throw .network(URLError(.cancelled)) }
                    didRefreshWBI = true
                    PlayerLog.log(
                        "[API] HTTP 412 for WBI GET \(endpoint.path) — refreshing WBI key and retrying once"
                    )
                    await WBISigner.shared.invalidate()
                    continue
                }
                PlayerLog.log("[API] HTTP \(httpResponse.statusCode) for \(endpoint.path)")
                throw httpError(from: httpResponse)
            }

            let decoder = JSONDecoder()
            let wrapper: BiliResponse<T>
            do {
                wrapper = try decoder.decode(BiliResponse<T>.self, from: result.data)
            } catch {
                let preview = String(data: result.data.prefix(500), encoding: .utf8) ?? "<binary>"
                PlayerLog.log("[API] Decode error for \(endpoint.path): \(error)\nResponse: \(preview)")
                throw .decodingFailed(error)
            }

            guard wrapper.code == 0 else {
                if canRefreshWBI(for: endpoint, didRefreshWBI: didRefreshWBI),
                   BiliAPIRetryPolicy.isRetryableWBIErrorCode(wrapper.code) {
                    if Task.isCancelled { throw .network(URLError(.cancelled)) }
                    didRefreshWBI = true
                    PlayerLog.log(
                        "[API] \(endpoint.path) WBI code=\(wrapper.code) — refreshing WBI key and retrying once"
                    )
                    await WBISigner.shared.invalidate()
                    continue
                }
                let preview = String(data: result.data.prefix(300), encoding: .utf8) ?? "<binary>"
                PlayerLog.log("[API] \(endpoint.path) code=\(wrapper.code): \(preview)")
                throw .apiError(code: wrapper.code, message: wrapper.message)
            }

            return try unwrapResponseData(
                wrapper,
                rawData: result.data,
                endpoint: endpoint,
                decoder: decoder
            )
        }
    }

    func requestRaw(_ endpoint: BiliEndpoint) async throws(BiliError) -> Data {
        let (data, httpResponse) = try await requestRawResponse(endpoint)

        guard (200...299).contains(httpResponse.statusCode) else {
            PlayerLog.log("[API] HTTP \(httpResponse.statusCode) for \(endpoint.path)")
            throw httpError(from: httpResponse)
        }

        return data
    }

    func requestRawResponse(
        _ endpoint: BiliEndpoint
    ) async throws(BiliError) -> (Data, HTTPURLResponse) {
        let result = try await performRequest(endpoint, allowHTTP412WBIRefresh: true)
        return (result.data, result.response)
    }

    private func performRequest(
        _ endpoint: BiliEndpoint,
        allowHTTP412WBIRefresh: Bool
    ) async throws(BiliError) -> RequestResult {
        let maxAttempts = BiliAPIRetryPolicy.maxAttempts(for: endpoint.method)
        var cachedRequest: URLRequest?
        var didRefreshWBI = false

        for attempt in 1 ... maxAttempts {
            if Task.isCancelled { throw .network(URLError(.cancelled)) }

            let urlRequest: URLRequest
            if let existing = cachedRequest {
                urlRequest = existing
            } else {
                guard let built = try await buildRequestOrRetry(
                    endpoint,
                    attempt: attempt,
                    maxAttempts: maxAttempts
                ) else {
                    continue
                }
                cachedRequest = built
                urlRequest = built
            }

            guard let (data, httpResponse) = try await executeAttemptOrRetry(
                urlRequest,
                endpoint: endpoint,
                attempt: attempt,
                maxAttempts: maxAttempts
            ) else {
                continue
            }

            switch try await handleTransientHTTPStatus(
                httpResponse,
                endpoint: endpoint,
                attempt: attempt,
                maxAttempts: maxAttempts
            ) {
            case .proceed:
                return RequestResult(data: data, response: httpResponse, didRefreshWBI: didRefreshWBI)
            case .retry:
                continue
            case .retryWithWBIRefresh:
                if allowHTTP412WBIRefresh,
                   canRefreshWBI(for: endpoint, didRefreshWBI: didRefreshWBI) {
                    didRefreshWBI = true
                    cachedRequest = nil
                    PlayerLog.log(
                        "[API] HTTP 412 for WBI GET \(endpoint.path) — refreshing WBI key before retry"
                    )
                    await WBISigner.shared.invalidate()
                }
                continue
            }
        }
        throw .network(URLError(.unknown))
    }
}

private extension BiliAPIClient {
    func handleTransientHTTPStatus(
        _ httpResponse: HTTPURLResponse,
        endpoint: BiliEndpoint,
        attempt: Int,
        maxAttempts: Int
    ) async throws(BiliError) -> TransientStatusAction {
        let statusCode = httpResponse.statusCode
        guard !(200...299).contains(statusCode),
              BiliAPIRetryPolicy.shouldRetryHTTPStatus(
                  method: endpoint.method,
                  attempt: attempt,
                  statusCode: statusCode
              ) else {
            return .proceed
        }

        let retryAfter = HTTPRetryAfter.delay(
            httpResponse.value(forHTTPHeaderField: "Retry-After")
        )
        let delay = BiliAPIRetryPolicy.retryDelay(attempt: attempt, retryAfter: retryAfter)
        PlayerLog.log(
            "[API] transient HTTP \(statusCode) for \(endpoint.path) "
                + "(attempt \(attempt)/\(maxAttempts)) — retrying in "
                + String(format: "%.2fs", delay)
        )
        try await sleepForRetry(delay)
        return statusCode == 412 ? .retryWithWBIRefresh : .retry
    }

    func buildRequestOrRetry(
        _ endpoint: BiliEndpoint,
        attempt: Int,
        maxAttempts: Int
    ) async throws(BiliError) -> URLRequest? {
        do {
            return try await endpoint.buildRequest()
        } catch {
            guard BiliAPIRetryPolicy.shouldRetry(
                method: endpoint.method,
                attempt: attempt,
                error: error
            ) else {
                if !BiliAPIRetryPolicy.isCancellation(error) {
                    PlayerLog.log("[API] Request build error for \(endpoint.path): \(error)")
                }
                throw mapBuildError(error)
            }
            let delay = BiliAPIRetryPolicy.retryDelay(
                attempt: attempt,
                retryAfter: extractRetryAfter(from: error)
            )
            PlayerLog.log(
                "[API] transient build error \(error) for \(endpoint.path) "
                    + "(attempt \(attempt)/\(maxAttempts)) — retrying in "
                    + String(format: "%.2fs", delay)
            )
            try await sleepForRetry(delay)
            return nil
        }
    }

    func executeAttemptOrRetry(
        _ request: URLRequest,
        endpoint: BiliEndpoint,
        attempt: Int,
        maxAttempts: Int
    ) async throws(BiliError) -> (Data, HTTPURLResponse)? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
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
            let delay = BiliAPIRetryPolicy.retryDelay(attempt: attempt)
            PlayerLog.log(
                "[API] transient \(error) for \(endpoint.path) "
                    + "(attempt \(attempt)/\(maxAttempts)) — retrying in "
                    + String(format: "%.2fs", delay)
            )
            try await sleepForRetry(delay)
            return nil
        }
    }

    func unwrapResponseData<T: Decodable>(
        _ wrapper: BiliResponse<T>,
        rawData: Data,
        endpoint: BiliEndpoint,
        decoder: JSONDecoder
    ) throws(BiliError) -> T {
        guard let result = wrapper.data else {
            if let empty = try? decoder.decode(T.self, from: Data("{}".utf8)) {
                if T.self != EmptyResult.self {
                    PlayerLog.log(
                        "[API] ⚠️ \(endpoint.path) returned no data/result payload — synthesized empty \(T.self)"
                    )
                }
                return empty
            }
            let preview = String(data: rawData.prefix(500), encoding: .utf8) ?? "<binary>"
            PlayerLog.log("[API] Data is nil for \(endpoint.path) (code=0). Response: \(preview)")
            throw .apiError(code: wrapper.code, message: String(localized: "Data decode failed"))
        }
        return result
    }

    func canRefreshWBI(for endpoint: BiliEndpoint, didRefreshWBI: Bool) -> Bool {
        !didRefreshWBI && endpoint.method == .get && endpoint.signType == .wbi
    }

    func httpError(from response: HTTPURLResponse) -> BiliError {
        .httpError(
            statusCode: response.statusCode,
            retryAfter: [429, 503].contains(response.statusCode)
                ? HTTPRetryAfter.delay(response.value(forHTTPHeaderField: "Retry-After")) : nil
        )
    }

    func mapBuildError(_ error: any Error) -> BiliError {
        if let biliError = error as? BiliError {
            return biliError
        }
        return .network(error)
    }

    func extractRetryAfter(from error: any Error) -> TimeInterval? {
        guard let biliError = error as? BiliError,
              case .httpError(_, let retryAfter) = biliError else {
            return nil
        }
        return retryAfter
    }

    func sleepForRetry(_ delay: TimeInterval) async throws(BiliError) {
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            throw .network(URLError(.cancelled))
        }
    }
}
