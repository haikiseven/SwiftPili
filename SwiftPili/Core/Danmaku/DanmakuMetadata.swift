import Foundation

struct DanmakuMetadata: Sendable, Equatable {
    let state: Int32
    let pageSeconds: TimeInterval?
    let totalSegments: Int?
    let specialURLs: [String]

    var isClosed: Bool { state != 0 }
}

enum DanmakuMetadataDecoder {
    static func decode(_ data: Data) throws(DanmakuDecodeError) -> DanmakuMetadata {
        let outcome = data.withUnsafeBytes { raw -> Result<DanmakuMetadata, DanmakuDecodeError> in
            do throws(DanmakuDecodeError) {
                var cursor = DanmakuWireCursor(raw)
                var state: Int32 = 0
                var pageSeconds: TimeInterval?
                var total: Int?
                var specialURLs: [String] = []
                while !cursor.isAtEnd {
                    let (field, wire) = try cursor.readTag()
                    switch (field, wire) {
                    case (1, .varint):
                        state = Int32(truncatingIfNeeded: try cursor.readVarint())
                    case (4, .lengthDelimited):
                        (pageSeconds, total) = try segmentation(cursor.readLengthDelimited())
                    case (6, .lengthDelimited):
                        specialURLs.append(try cursor.readString())
                    default:
                        try cursor.skip(wire)
                    }
                }
                return .success(DanmakuMetadata(
                    state: state, pageSeconds: pageSeconds,
                    totalSegments: total, specialURLs: specialURLs
                ))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    private static func segmentation(
        _ raw: UnsafeRawBufferPointer
    ) throws(DanmakuDecodeError) -> (TimeInterval?, Int?) {
        var cursor = DanmakuWireCursor(raw)
        var pageMS: Int64 = 0
        var total: Int64 = 0
        while !cursor.isAtEnd {
            let (field, wire) = try cursor.readTag()
            switch (field, wire) {
            case (1, .varint): pageMS = Int64(bitPattern: try cursor.readVarint())
            case (2, .varint): total = Int64(bitPattern: try cursor.readVarint())
            default: try cursor.skip(wire)
            }
        }
        return (
            DanmakuSegmentWindow.admissiblePageSeconds(TimeInterval(pageMS) / 1_000),
            total > 0 ? Int(min(total, Int64(Int32.max))) : nil
        )
    }
}

enum DanmakuSpecialTransport {
    static func url(_ raw: String) -> URL? {
        guard let candidate = URL(string: raw),
              let scheme = candidate.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = candidate.host?.lowercased(),
              host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
              candidate.user == nil, candidate.password == nil,
              candidate.port == nil || candidate.port == (scheme == "http" ? 80 : 443),
              candidate.path.hasPrefix("/bfs/dm/"), candidate.path.hasSuffix(".bin"),
              candidate.fragment == nil else { return nil }
        if scheme == "https" { return candidate }
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        var suffix = String(raw[colon...])
        if candidate.port == 80, let authorityEnd = suffix.dropFirst(3).firstIndex(of: "/") {
            let authority = suffix[..<authorityEnd]
            if authority.hasSuffix(":80") {
                suffix.removeSubrange(suffix.index(authorityEnd, offsetBy: -3) ..< authorityEnd)
            }
        }
        return URL(string: "https" + suffix)
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        return request
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectDelegate(), delegateQueue: nil)
    }()

    static func fetch(_ url: URL) async throws -> DanmakuSegmentResponse {
        guard let admitted = self.url(url.absoluteString) else { throw URLError(.badURL) }
        let (body, response) = try await session.data(for: request(admitted))
        let http = response as? HTTPURLResponse
        return DanmakuSegmentResponse(
            status: http?.statusCode ?? 0,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"), body: body
        )
    }

    static func redirectedRequest(_ proposed: URLRequest) -> URLRequest? {
        guard let source = proposed.url, let target = url(source.absoluteString) else { return nil }
        return request(target)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(DanmakuSpecialTransport.redirectedRequest(request))
        }
    }
}
