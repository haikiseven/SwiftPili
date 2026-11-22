import Foundation

struct BiliEndpoint: Sendable {
    let path: String
    let method: HTTPMethod
    let params: [String: String]
    let signType: SignType
    let baseURL: String
    let headers: [String: String]

    enum HTTPMethod: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    enum SignType: Sendable {
        case none
        case wbi
        case app
    }

    init(
        path: String,
        method: HTTPMethod = .get,
        params: [String: String] = [:],
        signType: SignType = .wbi,
        baseURL: String = "https://api.bilibili.com",
        headers: [String: String] = [:]
    ) {
        self.path = path
        self.method = method
        self.params = params
        self.signType = signType
        self.baseURL = baseURL
        self.headers = headers
    }

    func buildRequest() async throws -> URLRequest {
        let signedParams: [String: String]

        switch signType {
        case .none:
            signedParams = params
        case .wbi:
            signedParams = try await WBISigner.shared.sign(params: params)
        case .app:
            signedParams = try await AppSigner.shared.sign(params: params)
        }

        guard var components = URLComponents(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        let encodedQuery = BiliQueryEncoding.encode(signedParams)

        var request: URLRequest
        switch method {
        case .get:
            components.percentEncodedQuery = encodedQuery
            guard let url = components.url else { throw URLError(.badURL) }
            request = URLRequest(url: url)

        case .post:
            guard let url = components.url else { throw URLError(.badURL) }
            request = URLRequest(url: url)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = encodedQuery.data(using: .utf8)
        }

        request.httpMethod = method.rawValue
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}

/// One UTF-8 encoding contract for WBI canonical input and request parameters.
/// Only ASCII unreserved bytes survive; spaces become `%20`, and literal `+`
/// becomes `%2B` so form decoders cannot reinterpret it as a space.
enum BiliQueryEncoding {
    static func encode(_ params: [String: String]) -> String {
        params.sorted(by: { $0.key < $1.key })
            .map { "\(encodeComponent($0.key))=\(encodeComponent($0.value))" }
            .joined(separator: "&")
    }

    private static func encodeComponent(_ value: String) -> String {
        let hexDigits = Array("0123456789ABCDEF".utf8)
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            default:
                encoded.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hexDigits[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hexDigits[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }
}
