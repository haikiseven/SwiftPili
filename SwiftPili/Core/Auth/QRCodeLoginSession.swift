import Foundation

struct QRLoginCredentials: Sendable {
    let sessData: String
    let biliJct: String
    let dedeUserID: String
    let ckMd5: String?

    init?(values: [String: String]) {
        guard let sessData = values["SESSDATA"], !sessData.isEmpty,
              let biliJct = values["bili_jct"], !biliJct.isEmpty,
              let dedeUserID = values["DedeUserID"], !dedeUserID.isEmpty else { return nil }
        self.sessData = sessData
        self.biliJct = biliJct
        self.dedeUserID = dedeUserID
        ckMd5 = values["DedeUserID__ckMd5"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One QR attempt owns its cookie jar. Nothing reaches shared account storage
/// until the current MainActor owner commits a complete credential value.
final class QRCodeLoginSession: Sendable {
    enum PollResult: Sendable {
        case waiting
        case scanning
        case expired
        case confirmed(QRLoginCredentials)
    }

    private let session: URLSession
    private let redirectDelegate = QRLoginRedirectDelegate()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": BiliAPIClient.defaultUserAgent,
            "Referer": BiliAPIClient.defaultReferer,
            "Origin": BiliAPIClient.defaultReferer,
        ]
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        // Ephemeral configurations supply a private, in-memory cookie store.
        // Never replace it with .shared or import the active account's cookies.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = BiliAPIRetryPolicy.perAttemptInactivityTimeout
        session = URLSession(configuration: configuration)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func generateQRCode() async throws -> QRGenerateResponse {
        let (result, _) = try await request(
            BiliEndpoint(
                path: "/x/passport-login/web/qrcode/generate",
                signType: .none,
                baseURL: "https://passport.bilibili.com"
            ),
            type: QRGenerateResponse.self
        )
        return result
    }

    func poll(qrcodeKey: String) async throws -> PollResult {
        let (result, response) = try await request(
            BiliEndpoint(
                path: "/x/passport-login/web/qrcode/poll",
                params: ["qrcode_key": qrcodeKey],
                signType: .none,
                baseURL: "https://passport.bilibili.com"
            ),
            type: QRPollResponse.self
        )
        try Task.checkCancellation()
        switch result.code {
        case 0:
            // Complete this successful poll once, including any ticket exchange.
            // A consumed QR key must never be polled again for missing cookies.
            return .confirmed(try await completeLogin(result, response: response))
        case 86101: return .waiting
        case 86090: return .scanning
        case 86038: return .expired
        default: throw BiliError.apiError(code: result.code, message: result.message)
        }
    }

    private func completeLogin(_ result: QRPollResponse, response: HTTPURLResponse) async throws -> QRLoginCredentials {
        try Task.checkCancellation()
        let values = cookieValues(from: response)
        if let credentials = QRLoginCredentials(values: values) { return credentials }

        guard let loginURL = result.url, !loginURL.isEmpty else { throw LoginError.missingCredentials }
        guard let components = URLComponents(string: loginURL), let url = components.url else {
            throw LoginError.invalidResponse
        }
        // URLComponents decodes legacy query values once. Cookie values above
        // are already wire values and must not be percent-decoded again.
        let queryValues = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        // A partial cookie set must not override a complete legacy set. Keep
        // these sources independent instead of assembling mixed credentials.
        if let credentials = QRLoginCredentials(values: queryValues) { return credentials }
        return try await exchangeTicket(at: url)
    }

    private func exchangeTicket(at url: URL) async throws -> QRLoginCredentials {
        var current = url
        // Ticket requests are deliberately single-attempt: replaying a consumed
        // ticket or returning to the completed QR poll can destroy the login.
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard Self.isTrustedLoginURL(current) else { throw LoginError.invalidResponse }
            let (_, response) = try await requestData(URLRequest(url: current), retryMethod: nil)
            try Task.checkCancellation()
            let isRedirect = [301, 302, 303, 307, 308].contains(response.statusCode)
            guard (200...299).contains(response.statusCode) || isRedirect else {
                throw BiliError.httpError(statusCode: response.statusCode)
            }
            // The private jar retains intermediate response cookies. Re-read it
            // each hop so deleted/expired cookies cannot survive in an accumulator.
            let values = cookieValues(from: response)
            if let credentials = QRLoginCredentials(values: values) { return credentials }
            guard isRedirect else { throw LoginError.missingCredentials }
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                throw LoginError.invalidResponse
            }
            current = next
        }
        throw LoginError.invalidResponse
    }

    private static func isTrustedLoginURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return [
            "passport.bilibili.com", "account.bilibili.com", "passport.biligame.com", "www.bilibili.com",
        ].contains(url.host?.lowercased() ?? "")
    }

    private func cookieValues(from response: HTTPURLResponse? = nil) -> [String: String] {
        var values: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] where Self.isLoginCookie(cookie) {
            values[cookie.name] = cookie.value
        }
        if let response, let url = response.url, let host = url.host?.lowercased() {
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, field in
                fields[String(describing: field.key)] = String(describing: field.value)
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                where Self.isLoginCookie(cookie) {
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard host == domain || host.hasSuffix("." + domain) else { continue }
                values[cookie.name] = cookie.value
            }
        }
        return values
    }

    private static func isLoginCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (domain == "bilibili.com" || domain.hasSuffix(".bilibili.com"))
            && ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(cookie.name)
            && !cookie.value.isEmpty
            && (cookie.expiresDate.map { $0 > Date() } ?? true)
    }

    private func request<Value: Decodable & Sendable>(
        _ endpoint: BiliEndpoint,
        type: Value.Type
    ) async throws -> (Value, HTTPURLResponse) {
        let request = try await endpoint.buildRequest()
        try Task.checkCancellation()
        let (data, response) = try await requestData(request, retryMethod: endpoint.method)
        guard (200...299).contains(response.statusCode) else {
            throw BiliError.httpError(statusCode: response.statusCode)
        }
        let envelope: QRLoginEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(QRLoginEnvelope<Value>.self, from: data)
        } catch {
            throw BiliError.decodingFailed(error)
        }
        guard envelope.code == 0 else {
            throw BiliError.apiError(code: envelope.code, message: envelope.message)
        }
        guard let value = envelope.data else {
            throw BiliError.apiError(code: 0, message: String(localized: "Data decode failed"))
        }
        return (value, response)
    }

    private func requestData(
        _ request: URLRequest,
        retryMethod: BiliEndpoint.HTTPMethod?
    ) async throws(BiliError) -> (Data, HTTPURLResponse) {
        let maxAttempts = retryMethod.map(BiliAPIRetryPolicy.maxAttempts(for:)) ?? 1
        for attempt in 1...maxAttempts {
            do {
                try Task.checkCancellation()
                // Passing the delegate here is required to refuse redirects.
                let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, response)
            } catch {
                guard !Task.isCancelled, let retryMethod,
                      BiliAPIRetryPolicy.shouldRetry(method: retryMethod, attempt: attempt, error: error) else {
                    throw .network(error)
                }
                do {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                } catch {
                    throw .network(URLError(.cancelled))
                }
            }
        }
        throw .network(URLError(.unknown))
    }

    private enum LoginError: Error, LocalizedError {
        case invalidResponse
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .invalidResponse: String(localized: "Invalid login response")
            case .missingCredentials: String(localized: "Missing credentials in response")
            }
        }
    }
}

/// A stateless delegate keeps every redirect inside the validated manual walk.
private final class QRLoginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Decode the API verdict before its payload, preserving API failures without
/// shared transport logging or permissive empty-payload synthesis.
private struct QRLoginEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: Value?

    private enum CodingKeys: String, CodingKey {
        case code, message, msg, data, result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .msg) ?? ""
        if code == 0 {
            data = try container.decodeIfPresent(Value.self, forKey: container.contains(.data) ? .data : .result)
        } else {
            data = nil
        }
    }
}

struct QRGenerateResponse: Decodable, Sendable {
    let url: String
    let qrcodeKey: String

    enum CodingKeys: String, CodingKey {
        case url
        case qrcodeKey = "qrcode_key"
    }
}

private struct QRPollResponse: Decodable, Sendable {
    let code: Int
    let url: String?
    let message: String
}
