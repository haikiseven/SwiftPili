import CryptoKit
import Foundation

actor SponsorBlockService {
    static let shared = SponsorBlockService()

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
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

private struct HashedVideo: Decodable {
    let videoID: String
    let segments: [RawSegment]
}

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
