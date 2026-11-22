import CryptoKit
import Foundation

/// Networking against a BilibiliSponsorBlock server (default `bsbsb.top`,
/// overridable). Separate from `BiliAPIClient`: a different host, no
/// BiliBili response envelope, and the extension's own required headers.
///
/// Reads use the privacy-preserving hash-prefix endpoint — only the first
/// four hex chars of SHA-256(BVID) leave the device; the full list for
/// that prefix comes back and is filtered locally.
actor SponsorBlockService {
    static let shared = SponsorBlockService()

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            // The API validates the extension's origin / version headers.
            "Origin": "chrome-extension://eaoelafamejbnggahofapllmfhlhajdd",
            "x-ext-version": "0.5.0",
            "User-Agent": "SwiftPili/SponsorBlock",
        ]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: Server

    private func root(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed.isEmpty ? "https://bsbsb.top" : trimmed
        if !base.hasPrefix("http") { base = "https://\(base)" }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func jsonArray(_ items: [String]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    // MARK: Fetch

    /// Fetches segments for `videoID` (a BVID). Returns `[]` on 404 (the
    /// server's "no data" answer). Filters to the requested categories,
    /// drops server categories/actions this client doesn't model, and — if
    /// a `cid` is known — keeps only segments scoped to that part or to no
    /// part at all.
    func fetchSegments(
        videoID: String,
        cid: Int?,
        categories: [SponsorCategory],
        server: String
    ) async throws -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }

        let digest = SHA256.hash(data: Data(videoID.utf8))
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hashHex.prefix(4))

        var comps = URLComponents(string: "\(root(server))/api/skipSegments/\(prefix)")
        comps?.queryItems = [
            URLQueryItem(name: "categories", value: jsonArray(categories.map(\.apiValue))),
            URLQueryItem(name: "actionTypes", value: jsonArray(["skip", "mute", "poi"])),
        ]
        guard let url = comps?.url else { throw SponsorBlockError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Short retry on transient network errors (a Wi-Fi⇄cellular
        // hand-off, dropped connection): without it a single blip left the
        // whole video with no segments — one of the "sometimes doesn't
        // skip" cases. Reads are idempotent, so retrying is safe.
        var data = Data()
        var response: URLResponse?
        for attempt in 1 ... 3 {
            do {
                (data, response) = try await session.data(for: request)
                break
            } catch {
                let code = (error as? URLError)?.code
                let transient: Set<URLError.Code> = [
                    .timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet,
                ]
                if let code, transient.contains(code), attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                    continue
                }
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else { throw SponsorBlockError.badResponse }
        if http.statusCode == 404 { return [] }
        guard (200 ... 299).contains(http.statusCode) else { throw SponsorBlockError.http(http.statusCode) }

        let videos = try decoder.decode([HashedVideo].self, from: data)
        let allowed = Set(categories)
        let raw = videos.first(where: { $0.videoID == videoID })?.segments ?? []
        return raw
            .compactMap { $0.toSegment() }
            .filter { allowed.contains($0.category) }
            .filter { seg in
                guard let cid, let segCID = seg.cid, !segCID.isEmpty else { return true }
                return segCID == String(cid)
            }
    }

    // MARK: Submit

    /// Submits a new segment. Throws a typed `SponsorBlockError` for the
    /// documented failure codes (403 auto-moderation, 409 duplicate, 429
    /// rate-limit) so the UI can show the server's reason.
    func submit(
        videoID: String,
        cid: Int?,
        userID: String,
        duration: Double,
        start: Double,
        end: Double,
        category: SponsorCategory,
        actionType: SponsorActionType,
        server: String
    ) async throws {
        guard let url = URL(string: "\(root(server))/api/skipSegments") else {
            throw SponsorBlockError.badResponse
        }
        var body: [String: Any] = [
            "videoID": videoID,
            "userID": userID,
            "userAgent": "SwiftPili/SponsorBlock",
            "videoDuration": duration,
            "segments": [[
                "segment": [start, end],
                "category": category.apiValue,
                "actionType": actionType.rawValue,
            ]],
        ]
        if let cid { body["cid"] = String(cid) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SponsorBlockError.badResponse }
        switch http.statusCode {
        case 200 ... 299: return
        case 409: throw SponsorBlockError.duplicate
        case 429: throw SponsorBlockError.rateLimited
        case 403, 400: throw SponsorBlockError.rejected(String(data: data, encoding: .utf8) ?? "")
        default: throw SponsorBlockError.http(http.statusCode)
        }
    }

    // MARK: Vote

    /// `type`: 0 = downvote, 1 = upvote, 20 = retract.
    func vote(uuid: String, userID: String, type: Int, server: String) async throws {
        var comps = URLComponents(string: "\(root(server))/api/voteOnSponsorTime")
        comps?.queryItems = [
            URLQueryItem(name: "UUID", value: uuid),
            URLQueryItem(name: "userID", value: userID),
            URLQueryItem(name: "type", value: String(type)),
        ]
        guard let url = comps?.url else { throw SponsorBlockError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SponsorBlockError.badResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SponsorBlockError.rejected(String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Viewed

    /// Best-effort skip telemetry — powers the segment's view count on the
    /// server. Failures are swallowed; it never blocks playback.
    func reportViewed(uuid: String, server: String) async {
        var comps = URLComponents(string: "\(root(server))/api/viewedVideoSponsorTime")
        comps?.queryItems = [URLQueryItem(name: "UUID", value: uuid)]
        guard let url = comps?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }
}

// MARK: - Wire decoding

/// Response element from `GET /api/skipSegments/:hashPrefix`.
private struct HashedVideo: Decodable {
    let videoID: String
    let segments: [RawSegment]
}

/// Lenient per-segment decode: category / actionType stay strings so an
/// unrecognized value drops just that segment (via `toSegment`) instead of
/// throwing and losing the whole array.
private struct RawSegment: Decodable {
    let UUID: String
    let category: String
    let actionType: String?
    let segment: [Double]
    let locked: Int?
    let votes: Int?
    let videoDuration: Double?
    let cid: String?

    func toSegment() -> SponsorSegment? {
        guard let category = SponsorCategory(rawValue: category),
              segment.count == 2 else { return nil }
        let action = SponsorActionType(apiValue: actionType ?? "skip")
        // full / chapter are whole-video labels, not skippable ranges.
        guard action != .full, action != .chapter else { return nil }
        return SponsorSegment(
            uuid: UUID,
            category: category,
            actionType: action,
            start: segment[0],
            end: segment[1],
            videoDuration: videoDuration ?? 0,
            locked: (locked ?? 0) == 1,
            votes: votes ?? 0,
            cid: cid
        )
    }
}
