import Foundation

// MARK: - Video Cloud Dislike ("Not Interested")

extension VideoAPI {
    /// Reports "not interested" (`dislike = true` -> `"1"`) or reverts it (`dislike = false` -> `"2"`)
    /// via Bilibili's cloud archive dislike endpoint (`POST /x/web-interface/archive/dislike`).
    @discardableResult
    static func dislikeArchive(
        aid: Int?,
        bvid: String?,
        dislike: Bool = true
    ) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        var params: [String: String] = [
            "dislike": dislike ? "1" : "2",
            "csrf": csrf,
        ]
        if let aid, aid > 0 {
            params["aid"] = String(aid)
        } else if let trimmed = bvid?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            params["bvid"] = trimmed
        } else {
            throw .apiError(code: -400, message: "Missing video identifier")
        }

        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/archive/dislike",
                method: .post,
                params: params
            ),
            type: EmptyResult.self
        )
    }
}

// MARK: - Cloud Danmaku Filter Models

struct CloudDanmakuFilterResult: Decodable, Sendable {
    let rule: [CloudDanmakuFilterRule]?

    enum CodingKeys: String, CodingKey {
        case rule
    }

    init(rule: [CloudDanmakuFilterRule]?) {
        self.rule = rule
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rule = try container.decodeIfPresent([CloudDanmakuFilterRule].self, forKey: .rule)
    }
}

struct CloudDanmakuFilterRule: Decodable, Sendable, Identifiable, Hashable {
    enum RuleKind: Int, Sendable, Hashable {
        case keyword = 0
        case regex = 1
        case userHash = 2
    }

    let id: Int
    let mid: Int?
    let type: Int
    let filter: String
    let comment: String?
    let ctime: Int?
    let mtime: Int?

    var kind: RuleKind? { RuleKind(rawValue: type) }
    var isRegex: Bool { type == RuleKind.regex.rawValue }
    var isImportableAsKeywordRule: Bool {
        type == RuleKind.keyword.rawValue || type == RuleKind.regex.rawValue
    }

    init(
        id: Int,
        mid: Int? = nil,
        type: Int,
        filter: String,
        comment: String? = nil,
        ctime: Int? = nil,
        mtime: Int? = nil
    ) {
        self.id = id
        self.mid = mid
        self.type = type
        self.filter = filter
        self.comment = comment
        self.ctime = ctime
        self.mtime = mtime
    }

    enum CodingKeys: String, CodingKey {
        case id, mid, type, filter, comment, ctime, mtime
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? container.decode(Int.self, forKey: .id) {
            id = intID
        } else if let strID = try? container.decode(String.self, forKey: .id), let parsed = Int(strID) {
            id = parsed
        } else {
            id = 0
        }
        if let intMid = try? container.decodeIfPresent(Int.self, forKey: .mid) {
            mid = intMid
        } else if let strMid = try? container.decodeIfPresent(String.self, forKey: .mid) {
            mid = Int(strMid)
        } else {
            mid = nil
        }
        if let intType = try? container.decode(Int.self, forKey: .type) {
            type = intType
        } else if let strType = try? container.decode(String.self, forKey: .type), let parsed = Int(strType) {
            type = parsed
        } else {
            type = 0
        }
        filter = (try? container.decode(String.self, forKey: .filter)) ?? ""
        comment = try? container.decodeIfPresent(String.self, forKey: .comment)
        ctime = try? container.decodeIfPresent(Int.self, forKey: .ctime)
        mtime = try? container.decodeIfPresent(Int.self, forKey: .mtime)
    }
}
