import Foundation

enum SearchAPI {
    static func searchAll(
        keyword: String,
        page: Int = 1
    ) async throws(BiliError) -> SearchAllResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/wbi/search/all/v2",
                params: [
                    "keyword": keyword,
                    "page": String(page),
                ]
            ),
            type: SearchAllResult.self
        )
    }

    static func search(
        keyword: String,
        type: SearchType = .video,
        page: Int = 1,
        order: String = "",
        duration: Int = 0,
        orderSort: Int? = nil
    ) async throws(BiliError) -> SearchResult {
        let effectiveType: SearchType = type == .all ? .video : type
        var params: [String: String] = [
            "keyword": keyword,
            "search_type": effectiveType.rawValue,
            "page": String(page),
            "order": order,
            "duration": String(duration),
        ]
        if let resolvedOrderSort = orderSort ?? (effectiveType == .user && !order.isEmpty ? 0 : nil) {
            params["order_sort"] = String(resolvedOrderSort)
        }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/wbi/search/type",
                params: params
            ),
            type: SearchResult.self
        )
    }

    static func getHotSearchTerms(limit: Int = 20) async throws(BiliError) -> HotSearchResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/web-interface/wbi/search/square",
                params: ["limit": String(limit)]
            ),
            type: HotSearchResult.self
        )
    }

    static func getDefaultSearchTerm() async throws(BiliError) -> SearchDefaultResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(path: "/x/web-interface/wbi/search/default"),
            type: SearchDefaultResult.self
        )
    }

    static func getSuggestions(term: String) async throws(BiliError) -> [SearchSuggestion] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let raw = try await BiliAPIClient.shared.requestRaw(
            BiliEndpoint(
                path: "/main/suggest",
                params: [
                    "term": trimmed,
                    "main_ver": "v1",
                ],
                signType: .none,
                baseURL: "https://s.search.bilibili.com"
            )
        )
        do {
            return try SearchSuggestDecoder.decode(from: raw)
        } catch let error as BiliError {
            throw error
        } catch {
            throw .decodingFailed(error)
        }
    }
}

private struct SuggestAnySkip: Decodable {}

private struct SuggestDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct SuggestEnvelope: Decodable {
    let code: Int?
    let message: String?
    let msg: String?
    let result: SuggestResultContainer?
}

private struct SuggestResultContainer: Decodable {
    let suggestions: [SearchSuggestion]

    enum CodingKeys: String, CodingKey {
        case tag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.tag) else {
            suggestions = []
            return
        }
        if var array = try? container.nestedUnkeyedContainer(forKey: .tag) {
            var parsed: [SearchSuggestion] = []
            while !array.isAtEnd {
                if let item = try? array.decode(SearchSuggestion.self), !item.value.isEmpty {
                    parsed.append(item)
                } else {
                    _ = try? array.decode(SuggestAnySkip.self)
                }
            }
            suggestions = parsed
            return
        }
        if let dictContainer = try? container.nestedContainer(keyedBy: SuggestDynamicKey.self, forKey: .tag) {
            let sortedKeys = dictContainer.allKeys.sorted {
                (Int($0.stringValue) ?? Int.max, $0.stringValue)
                    < (Int($1.stringValue) ?? Int.max, $1.stringValue)
            }
            suggestions = sortedKeys.compactMap { key in
                guard let item = try? dictContainer.decode(SearchSuggestion.self, forKey: key),
                      !item.value.isEmpty
                else { return nil }
                return item
            }
            return
        }
        suggestions = []
    }
}

private struct SuggestTopLevelMap: Decodable {
    let suggestions: [SearchSuggestion]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SuggestDynamicKey.self)
        let sortedKeys = container.allKeys.sorted {
            (Int($0.stringValue) ?? Int.max, $0.stringValue)
                < (Int($1.stringValue) ?? Int.max, $1.stringValue)
        }
        suggestions = sortedKeys.compactMap { key in
            guard let item = try? container.decode(SearchSuggestion.self, forKey: key),
                  !item.value.isEmpty
            else { return nil }
            return item
        }
    }
}

private enum SearchSuggestDecoder {
    static func decode(from data: Data) throws -> [SearchSuggestion] {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SuggestEnvelope.self, from: data),
           envelope.code != nil || envelope.result != nil {
            if let code = envelope.code, code != 0 {
                throw BiliError.apiError(code: code, message: envelope.message ?? envelope.msg ?? "")
            }
            return envelope.result?.suggestions ?? []
        }
        if let topLevel = try? decoder.decode(SuggestTopLevelMap.self, from: data) {
            return topLevel.suggestions
        }
        return []
    }
}

enum SearchType: String, CaseIterable, Sendable, Hashable {
    case all
    case video
    case bangumi = "media_bangumi"
    case liveRoom = "live_room"
    case user = "bili_user"
    case article
}

enum SearchVideoOrder: String, CaseIterable, Sendable, Hashable {
    case totalrank
    case click
    case pubdate
    case danmaku = "dm"

    var isDefault: Bool { self == .totalrank }
}

enum SearchDuration: Int, CaseIterable, Sendable, Hashable {
    case all = 0
    case under10 = 1
    case tenTo30 = 2
    case thirtyTo60 = 3
    case over60 = 4
}

enum SearchUserOrder: String, CaseIterable, Sendable, Hashable {
    case defaultOrder = ""
    case fans
    case level
}

enum SearchArticleOrder: String, CaseIterable, Sendable, Hashable {
    case totalrank
    case click
    case pubdate
    case attention
}
