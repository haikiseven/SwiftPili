import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MediaHTTPBootstrapRegistration: Sendable {
    let url: URL
    let headers: [String: String]
    let response: HTTPURLResponse
    let requestStart: Date
    let receivedAt: Date
    let head: PathAHTTPMediaSource.InitialHead
}

struct MediaHTTPBootstrapProvenance: Sendable {
    let originalURL: String
    let responseURL: String
    let headers: [String: String]
    let info: PathAHTTPMediaSource.ResourceInfo
    let responseKind: PathAHTTPMediaSource.InitialHead.ResponseKind
    let returnedRange: Range<Int64>
    let cacheControl: String
    let vary: String?
    let entityTag: String?
    let lastModified: String?
    let freshness: MediaHTTPBootstrapFreshness

    init?(
        url: URL, headers: [String: String], response: HTTPURLResponse,
        requestStart: Date, receivedAt: Date, head: PathAHTTPMediaSource.InitialHead
    ) {
        guard let normalized = Self.normalizedHeaders(headers),
              let effectiveURL = response.url?.absoluteString,
              effectiveURL.utf8.elementsEqual(url.absoluteString.utf8),
              let length = Self.validatedLength(response: response, head: head),
              Self.admitsVary(response.value(forHTTPHeaderField: "Vary"), headers: normalized),
              response.value(forHTTPHeaderField: "Pragma") == nil,
              let cacheControl = response.value(forHTTPHeaderField: "Cache-Control"),
              let freshness = MediaHTTPBootstrapFreshness(
                response: response, requestStart: requestStart, receivedAt: receivedAt
              ) else { return nil }
        self.originalURL = url.absoluteString
        self.responseURL = effectiveURL
        self.headers = normalized
        self.info = head.info
        self.responseKind = head.responseKind
        self.returnedRange = 0..<length
        self.cacheControl = cacheControl
        self.vary = response.value(forHTTPHeaderField: "Vary")
        self.entityTag = response.value(forHTTPHeaderField: "ETag")
        self.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        self.freshness = freshness
    }

    func matches(url: URL, headers: [String: String]) -> Bool {
        guard originalURL.utf8.elementsEqual(url.absoluteString.utf8),
              let normalized = Self.normalizedHeaders(headers),
              normalized.count == self.headers.count else { return false }
        return self.headers.allSatisfy { name, value in
            normalized[name].map { value.utf8.elementsEqual($0.utf8) } ?? false
        }
    }

    static func normalizedHeaders(_ headers: [String: String]) -> [String: String]? {
        var result: [String: String] = [:]
        for (name, value) in headers {
            guard isToken(name), !Self.hasLineBreak(value) else { return nil }
            let field = name.lowercased()
            guard result[field] == nil,
                  field != "cache-control", field != "pragma", field != "range",
                  !field.hasPrefix("if-") else { return nil }
            result[field] = value
        }
        return result
    }

    private static func validatedLength(
        response: HTTPURLResponse, head: PathAHTTPMediaSource.InitialHead
    ) -> Int64? {
        guard response.statusCode == 206, head.responseKind == .httpPartial,
              !head.data.isEmpty,
              let range = try? PathAHTTPRangeValidator.parseContentRange(
                response.value(forHTTPHeaderField: "Content-Range")
              ),
              range.start == 0, range.length == Int64(head.data.count),
              let total = range.total, total == head.info.contentLength,
              let type = response.value(forHTTPHeaderField: "Content-Type"),
              let headType = head.info.contentType,
              type.utf8.elementsEqual(headType.utf8), validContentType(type) else { return nil }
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
           encoding.trimmingCharacters(in: .whitespaces).lowercased() != "identity" { return nil }
        do {
            try PathAHTTPRangeValidator.validateContentLength(
                response.value(forHTTPHeaderField: "Content-Length"),
                bodyCount: head.data.count, expectedRangeLength: range.length
            )
        } catch { return nil }
        return range.length
    }

    private static func validContentType(_ raw: String) -> Bool {
        guard !Self.hasLineBreak(raw) else { return false }
        guard let first = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return false
        }
        let mediaType = first.trimmingCharacters(in: .whitespaces)
        let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { isToken(String($0)) } &&
            mediaType.lowercased() != "multipart/byteranges"
    }

    private static func admitsVary(_ raw: String?, headers: [String: String]) -> Bool {
        guard let raw else { return true }
        return raw.split(separator: ",", omittingEmptySubsequences: false).allSatisfy {
            let field = $0.trimmingCharacters(in: .whitespaces)
            return field != "*" && isToken(field) && headers[field.lowercased()] != nil
        }
    }

    fileprivate static func isToken(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    fileprivate static func hasLineBreak(_ raw: String) -> Bool {
        raw.utf8.contains(13) || raw.utf8.contains(10)
    }
}

struct MediaHTTPBootstrapVersionBaseline: Sendable {
    let identity: MediaBootstrapIdentity
    let entityTag: String?
    let lastModified: String?
    let contentType: String?

    init(
        identity: MediaBootstrapIdentity, response: HTTPURLResponse,
        info: PathAHTTPMediaSource.ResourceInfo, previous: Self? = nil
    ) {
        self.identity = identity
        self.entityTag = response.value(forHTTPHeaderField: "ETag") ?? previous?.entityTag
        self.lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? previous?.lastModified
        self.contentType = info.contentType ?? previous?.contentType
    }

    func hasChanged(
        identity: MediaBootstrapIdentity?, response: HTTPURLResponse, info: PathAHTTPMediaSource.ResourceInfo
    ) -> Bool {
        if let identity, !identity.asset.isEmpty, !identity.representation.isEmpty,
           identity != self.identity { return true }
        let pairs = [
            (entityTag, response.value(forHTTPHeaderField: "ETag")),
            (lastModified, response.value(forHTTPHeaderField: "Last-Modified")),
            (contentType, info.contentType)
        ]
        return pairs.contains { previous, current in
            guard let previous, let current else { return false }
            return !previous.utf8.elementsEqual(current.utf8)
        }
    }
}

struct MediaHTTPBootstrapFreshness: Sendable {
    let requestStart: Date
    let receivedAt: Date
    let responseDate: Date
    let age: TimeInterval
    let maxAge: TimeInterval
    let correctedInitialAge: TimeInterval

    init?(response: HTTPURLResponse, requestStart: Date, receivedAt: Date) {
        guard let directives = Self.directives(response.value(forHTTPHeaderField: "Cache-Control")),
              directives["no-store"] == nil, directives["no-cache"] == nil,
              let maxAgeRaw = directives["max-age"],
              let maxAge = Self.seconds(maxAgeRaw), maxAge > 0,
              let dateRaw = response.value(forHTTPHeaderField: "Date"),
              let responseDate = Self.httpDate(dateRaw) else { return nil }
        let age: TimeInterval
        if let raw = response.value(forHTTPHeaderField: "Age") {
            guard let parsed = Self.seconds(raw) else { return nil }
            age = parsed
        } else {
            age = 0
        }
        let delay = receivedAt.timeIntervalSince(requestStart)
        let apparentAge = receivedAt.timeIntervalSince(responseDate)
        guard delay.isFinite, delay >= 0, apparentAge.isFinite else { return nil }
        let corrected = max(max(0, apparentAge), age + delay)
        guard corrected.isFinite, corrected < maxAge else { return nil }
        self.requestStart = requestStart
        self.receivedAt = receivedAt
        self.responseDate = responseDate
        self.age = age
        self.maxAge = maxAge
        self.correctedInitialAge = corrected
    }

    func isFresh(at now: Date) -> Bool {
        let resident = now.timeIntervalSince(receivedAt)
        guard resident.isFinite, resident >= 0 else { return false }
        return correctedInitialAge + resident < maxAge
    }

    private static func directives(_ raw: String?) -> [String: String]? {
        guard let raw else { return nil }
        var parsed: [String: String] = [:]
        for piece in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let fields = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = fields.first else { return nil }
            let name = first.trimmingCharacters(in: .whitespaces).lowercased()
            guard MediaHTTPBootstrapProvenance.isToken(name), parsed[name] == nil else { return nil }
            var value = fields.count == 2 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            if value.hasPrefix("\"") && value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.utf8.contains(34), !MediaHTTPBootstrapProvenance.hasLineBreak(value) else { return nil }
            parsed[name] = value
        }
        return parsed
    }

    private static func seconds(_ raw: String) -> TimeInterval? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int64(token) else { return nil }
        return TimeInterval(seconds)
    }

    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return date
    }
}
