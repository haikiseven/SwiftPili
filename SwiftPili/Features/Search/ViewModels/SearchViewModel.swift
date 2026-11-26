import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SearchViewModel {
    fileprivate struct CacheKey: Hashable {
        let term: String
        let type: SearchType
        let filterKey: String

        init(query: SubmittedQuery) {
            term = query.term; type = query.type
            switch query.type {
            case .all, .video: filterKey = "\(query.videoOrder.rawValue)|\(query.duration.rawValue)"
            case .user: filterKey = query.userOrder.rawValue
            case .article: filterKey = query.articleOrder.rawValue
            case .bangumi, .liveRoom: filterKey = ""
            }
        }
    }

    fileprivate struct CachedFeed {
        let allBuckets: [AllSearchBucket]
        let rawResults: [PreparedResult]
        let results: [PreparedResult]
        let preparedBuckets: [SearchAllBucketData]
        let preparedItems: [SearchResultItemData]
        let page: Int
        let reachedEnd: Bool
    }

    var keyword = "" {
        didSet { syncEligibleSuggestions() }
    }
    var hotWords: [HotSearchResult.TrendingInfo.HotWord] = []
    private(set) var defaultSearchTerm: SearchDefaultResult?
    private(set) var suggestions: [SearchSuggestion] = [] {
        didSet { syncEligibleSuggestions() }
    }
    private(set) var hasEligibleSuggestions = false
    private(set) var allBuckets: [AllSearchBucket] = []
    private(set) var results: [PreparedResult] = []
    private(set) var preparedBuckets: [SearchAllBucketData] = []
    private(set) var preparedItems: [SearchResultItemData] = []
    private(set) var snapshotRevision: UInt64 = 0
    var isSearching = false
    private(set) var selectedType: SearchType
    private(set) var videoOrder: SearchVideoOrder = .totalrank
    private(set) var duration: SearchDuration = .all
    private(set) var userOrder: SearchUserOrder = .defaultOrder
    private(set) var articleOrder: SearchArticleOrder = .totalrank
    private(set) var submittedQuery: SubmittedQuery? {
        didSet { syncEligibleSuggestions() }
    }
    var hasSearched: Bool { submittedQuery != nil }
    var hasResults: Bool { !results.isEmpty || !allBuckets.isEmpty }
    private(set) var resultGeneration: UInt64 = 0

    @ObservationIgnored private let initialType: SearchType
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var admission = FeedLoadAdmission()
    @ObservationIgnored private var hotWordsAdmission = FeedLoadAdmission()
    @ObservationIgnored private var defaultTermAdmission = FeedLoadAdmission()
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionQueryID: UInt64 = 0
    @ObservationIgnored private var tabCache: [CacheKey: CachedFeed] = [:]
    @ObservationIgnored private var tabCacheOrder: [CacheKey] = []
    @ObservationIgnored private var rawResults: [PreparedResult] = []
    private static let maxCachedFeeds = 24

    init(initialType: SearchType = .all) {
        self.initialType = initialType
        selectedType = initialType
        LocalContentFilterStore.shared.addObserver(self) { viewModel in
            viewModel.reapplyContentFilters()
        }
    }

    func loadHotWords() async {
        guard let token = hotWordsAdmission.admit(kind: .initial, cursor: "hotWords") else {
            FeedPerformanceSignposts.duplicateSuppressed(
                .search, kind: .initial, generation: hotWordsAdmission.generation,
                count: hotWordsAdmission.duplicateSuppressionCount
            )
            return
        }
        do {
            let result = try await SearchAPI.getHotSearchTerms()
            hotWords = FeedCollectionPolicy.replaceDeduplicated(result.trending?.list ?? [], id: \.id)
            PlayerLog.log("[Search] hot words loaded: \(hotWords.count) terms")
            if hotWords.isEmpty { PlayerLog.log("[Search] ⚠️ search/square trending.list is empty") }
            hotWordsAdmission.finish(token, succeeded: true)
        } catch {
            PlayerLog.log("[Search] ⚠️ hot words failed: \(error)")
            hotWordsAdmission.finish(token, succeeded: false)
        }
    }

    func loadDefaultSearchTerm() async {
        guard let token = defaultTermAdmission.admit(kind: .initial, cursor: "defaultTerm") else { return }
        do {
            let result = try await SearchAPI.getDefaultSearchTerm()
            defaultSearchTerm = (result.name?.isEmpty == false) ? result : nil
            defaultTermAdmission.finish(token, succeeded: true)
        } catch {
            PlayerLog.log("[Search] ⚠️ default search term failed: \(error)")
            defaultTermAdmission.finish(token, succeeded: false)
        }
    }

    func updateKeyword(_ newValue: String) {
        if keyword != newValue { keyword = newValue }
        requestSuggestions(for: newValue)
    }

    func requestSuggestions(for rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespaces)
        suggestionTask?.cancel(); suggestionTask = nil; suggestionQueryID &+= 1
        guard !trimmed.isEmpty, !(hasSearched && trimmed == submittedQuery?.term) else {
            suggestions = []; return
        }
        let queryID = suggestionQueryID
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.suggestionQueryID == queryID else { return }
            do {
                let fetched = try await SearchAPI.getSuggestions(term: trimmed)
                guard !Task.isCancelled, self.suggestionQueryID == queryID else { return }
                let latest = self.keyword.trimmingCharacters(in: .whitespaces)
                guard latest == trimmed, !(self.hasSearched && latest == self.submittedQuery?.term) else { return }
                self.suggestions = FeedCollectionPolicy.replaceDeduplicated(fetched, id: \.id)
            } catch {
                if !Task.isCancelled, self.suggestionQueryID == queryID {
                    PlayerLog.log("[Search] suggest failed: \(error)")
                }
            }
        }
    }

    func clearSuggestions() {
        suggestionTask?.cancel(); suggestionTask = nil; suggestionQueryID &+= 1; suggestions = []
    }

    func cancelEditing() {
        clearSuggestions()
        if let submittedQuery { keyword = submittedQuery.term }
    }

    func prepareSearch(modelContext: ModelContext?) -> PreparedRequest? {
        var term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty {
            guard !hasSearched,
                  let fallback = defaultSearchTerm?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fallback.isEmpty else { return nil }
            keyword = fallback
            term = fallback
        } else {
            let normalized = Self.normalizedSearchTerm(from: term)
            if normalized != term {
                term = normalized
                keyword = normalized
            }
        }
        clearSuggestions()
        let request = prepareInitial(query: makeQuery(term: term, type: selectedType))
        if let modelContext { saveToHistory(keyword: term, modelContext: modelContext) }
        return request
    }

    private static func normalizedSearchTerm(from raw: String) -> String {
        guard raw.contains("://") else { return raw }
        if let directURL = URL(string: raw),
           directURL.scheme?.lowercased() == "bilibili",
           let route = BiliURLParser.parse(directURL) {
            return searchTerm(for: route) ?? raw
        }
        if case .resolved(let target, _) = BiliLinkResolver.resolve(text: raw) {
            return searchTerm(for: target.route) ?? raw
        }
        return raw
    }

    private static func searchTerm(for route: Route) -> String? {
        switch route {
        case .videoDetail(let target):
            switch target.videoID {
            case .bvid(let bvid): return bvid
            case .aid(let aid): return "av\(aid)"
            }
        case .articleReader(let cvid):
            return "cv\(cvid)"
        case .search(_, let keyword):
            return keyword
        default:
            return nil
        }
    }

    func prepareTypeChange(to type: SearchType) -> PreparedRequest? {
        guard type != selectedType else { return nil }
        selectedType = type
        guard let submittedQuery else { return nil }
        return restoreOrPrepareInitial(query: makeQuery(term: submittedQuery.term, type: type))
    }

    func prepareFilterChange(
        videoOrder: SearchVideoOrder? = nil, duration: SearchDuration? = nil,
        userOrder: SearchUserOrder? = nil, articleOrder: SearchArticleOrder? = nil
    ) -> PreparedRequest? {
        let nextVideo = videoOrder ?? self.videoOrder
        let nextDuration = duration ?? self.duration
        let nextUser = userOrder ?? self.userOrder
        let nextArticle = articleOrder ?? self.articleOrder
        guard nextVideo != self.videoOrder || nextDuration != self.duration
                || nextUser != self.userOrder || nextArticle != self.articleOrder else { return nil }
        self.videoOrder = nextVideo; self.duration = nextDuration
        self.userOrder = nextUser; self.articleOrder = nextArticle
        guard let submittedQuery else { return nil }
        let targetQuery = makeQuery(term: submittedQuery.term, type: selectedType)
        guard CacheKey(query: targetQuery) != CacheKey(query: submittedQuery) else { return nil }
        return restoreOrPrepareInitial(query: targetQuery)
    }

    func prepareLoadMore(generation: UInt64) -> PreparedRequest? {
        guard isCurrentResult(generation: generation), let submittedQuery, !isSearching, !reachedEnd else { return nil }
        let requestedPage = page
        guard let token = admission.admit(kind: .pagination, cursor: "page:\(requestedPage)") else {
            FeedPerformanceSignposts.duplicateSuppressed(
                .search, kind: .pagination, generation: admission.generation,
                count: admission.duplicateSuppressionCount
            )
            return nil
        }
        isSearching = true
        return PreparedRequest(query: submittedQuery, token: token, page: requestedPage, initialHadContent: nil)
    }

    func isCurrentResult(generation: UInt64) -> Bool { submittedQuery != nil && generation == admission.generation }

    func clearSearch() {
        admission.supersede()
        resultGeneration = admission.generation
        clearSuggestions()
        submittedQuery = nil; keyword = ""; allBuckets = []; rawResults = []; results = []
        preparedBuckets = []; preparedItems = []; snapshotRevision &+= 1
        page = 1; reachedEnd = false; isSearching = false; selectedType = initialType
        videoOrder = .totalrank; duration = .all; userOrder = .defaultOrder; articleOrder = .totalrank
    }

    func reapplyContentFilters() {
        guard let query = submittedQuery, query.type == .all || query.type == .video else { return }
        let filtered = rawResults.filter { !Self.shouldHideVideoResult($0) }
        guard filtered.map(\.id) != results.map(\.id) else { return }
        results = filtered
        preparedItems = filtered.map { Self.makeResultData($0, type: query.type) }
        snapshotRevision &+= 1
        storeCache(for: query)
    }
}

// MARK: - Execution & Models

extension SearchViewModel {
    struct SubmittedQuery: Equatable, Sendable {
        let term: String
        let type: SearchType
        let videoOrder: SearchVideoOrder
        let duration: SearchDuration
        let userOrder: SearchUserOrder
        let articleOrder: SearchArticleOrder

        init(
            term: String, type: SearchType,
            videoOrder: SearchVideoOrder = .totalrank, duration: SearchDuration = .all,
            userOrder: SearchUserOrder = .defaultOrder, articleOrder: SearchArticleOrder = .totalrank
        ) {
            self.term = term; self.type = type; self.videoOrder = videoOrder
            self.duration = duration; self.userOrder = userOrder; self.articleOrder = articleOrder
        }

        var isDefaultVideoFilter: Bool { videoOrder.isDefault && duration == .all }
        var usesAllMixedEndpoint: Bool { type == .all && isDefaultVideoFilter }
    }

    struct PreparedRequest: Sendable {
        fileprivate let query: SubmittedQuery
        fileprivate let token: FeedLoadToken
        fileprivate let page: Int
        fileprivate let initialHadContent: Bool?
    }

    @MainActor
    final class PreparedResult: Identifiable {
        let item: SearchResult.SearchResultItem
        nonisolated let id: String
        var displayTitle: String { item.cleanTitle }
        var displayDesc: String { item.cleanDesc }
        private(set) lazy var durationSeconds = Self.parseDuration(item.duration)

        fileprivate init(item: SearchResult.SearchResultItem) { self.item = item; id = item.id }

        private static func parseDuration(_ duration: String?) -> Int {
            guard let duration else { return 0 }
            let parts = duration.split(separator: ":").compactMap { Int($0) }
            guard !parts.isEmpty else { return 0 }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
    }

    enum AllBucketKind: String, Sendable, Hashable, CaseIterable {
        case bangumi, user, liveRoom, article

        var targetType: SearchType {
            switch self {
            case .bangumi: .bangumi
            case .user: .user
            case .liveRoom: .liveRoom
            case .article: .article
            }
        }
    }

    @MainActor
    final class AllSearchBucket: Identifiable {
        let kind: AllBucketKind
        let items: [PreparedResult]
        let totalCount: Int
        let hasMore: Bool
        nonisolated var id: AllBucketKind { kind }
        var targetType: SearchType { kind.targetType }

        fileprivate init(kind: AllBucketKind, items: [PreparedResult], totalCount: Int, hasMore: Bool) {
            self.kind = kind; self.items = items; self.totalCount = totalCount; self.hasMore = hasMore
        }
    }

    func perform(_ request: PreparedRequest) async {
        let token = request.token
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .search, kind: token.kind, generation: token.generation, page: request.page
        )
        var outcome: FeedLoadOutcome = .failed
        defer {
            admission.finish(token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID, screen: .search, kind: token.kind,
                generation: token.generation, page: request.page,
                outcome: outcome, count: results.count
            )
            if isCurrent(request) { isSearching = false }
        }
        outcome = await executeRequest(request)
    }

    private func executeRequest(_ request: PreparedRequest) async -> FeedLoadOutcome {
        do {
            guard isCurrent(request) else { return .superseded }
            try Task.checkCancellation()
            if request.query.usesAllMixedEndpoint {
                let allResult = try await SearchAPI.searchAll(keyword: request.query.term, page: request.page)
                guard isCurrent(request) else { return .superseded }
                try Task.checkCancellation()
                publishAll(allResult, for: request)
            } else {
                let (orderParam, durationParam) = searchParams(for: request.query)
                let apiType: SearchType = request.query.type == .all ? .video : request.query.type
                let result = try await SearchAPI.search(
                    keyword: request.query.term, type: apiType, page: request.page,
                    order: orderParam, duration: durationParam
                )
                guard isCurrent(request) else { return .superseded }
                try Task.checkCancellation()
                publish(result, for: request)
            }
            storeCache(for: request.query)
            return .success
        } catch {
            guard isCurrent(request) else { return .superseded }
            let isCancelled = Task.isCancelled || error is CancellationError
                || (error as? BiliError)?.isCancellation == true
            if !isCancelled { logFailure(error, for: request) }
            return isCancelled ? .cancelled : .failed
        }
    }
}

// MARK: - Internal Helpers

private extension SearchViewModel {
    func makeQuery(term: String, type: SearchType) -> SubmittedQuery {
        SubmittedQuery(
            term: term, type: type, videoOrder: videoOrder,
            duration: duration, userOrder: userOrder, articleOrder: articleOrder
        )
    }

    func restoreOrPrepareInitial(query: SubmittedQuery) -> PreparedRequest? {
        let key = CacheKey(query: query)
        if let cached = touchCache(for: key) {
            admission.supersede()
            resultGeneration = admission.generation
            let hadContent = hasResults
            submittedQuery = query
            allBuckets = cached.allBuckets
            rawResults = cached.rawResults
            let filteredResults = (query.type == .all || query.type == .video)
                ? cached.rawResults.filter { !Self.shouldHideVideoResult($0) }
                : cached.results
            results = filteredResults
            preparedBuckets = cached.preparedBuckets
            preparedItems = (query.type == .all || query.type == .video)
                ? filteredResults.map { Self.makeResultData($0, type: query.type) }
                : cached.preparedItems
            snapshotRevision &+= 1
            page = cached.page
            reachedEnd = cached.reachedEnd
            isSearching = false
            if !hadContent, hasResults {
                let bucketCount = allBuckets.reduce(0) { $0 + $1.items.count }
                FeedPerformanceSignposts.firstContent(
                    .search, generation: admission.generation, count: results.count + bucketCount
                )
            }
            return nil
        }
        return prepareInitial(query: query)
    }

    func prepareInitial(query: SubmittedQuery) -> PreparedRequest {
        let token = admission.supersedeAndAdmit(kind: .initial, cursor: "page:1")
        resultGeneration = admission.generation
        let hadContent = hasResults
        submittedQuery = query
        page = 1
        reachedEnd = false
        allBuckets = []
        rawResults = []
        results = []
        preparedBuckets = []
        preparedItems = []
        snapshotRevision &+= 1
        isSearching = true
        return PreparedRequest(query: query, token: token, page: 1, initialHadContent: hadContent)
    }

    func isCurrent(_ request: PreparedRequest) -> Bool {
        admission.isCurrent(request.token) && submittedQuery == request.query
    }

    func searchParams(for query: SubmittedQuery) -> (order: String, duration: Int) {
        switch query.type {
        case .all, .video: (query.videoOrder.rawValue, query.duration.rawValue)
        case .user: (query.userOrder.rawValue, 0)
        case .article: (query.articleOrder.rawValue, 0)
        case .bangumi, .liveRoom: ("", 0)
        }
    }

    func publishAll(_ allResult: SearchAllResult, for request: PreparedRequest) {
        let extracted = extractAllBuckets(from: allResult.result ?? [])
        if let hadContent = request.initialHadContent {
            let builtBuckets = buildAllBuckets(from: extracted.byKind, tlist: allResult.topTlist ?? [:])
            let dedupedRawVideos = FeedCollectionPolicy.replaceDeduplicated(extracted.videos, id: \.id)
            let visibleVideos = dedupedRawVideos.filter { !Self.shouldHideVideoResult($0) }
            allBuckets = builtBuckets
            rawResults = dedupedRawVideos
            results = visibleVideos
            preparedBuckets = builtBuckets.map(Self.makeBucketData)
            preparedItems = visibleVideos.map { Self.makeResultData($0, type: request.query.type) }
            snapshotRevision &+= 1
            page = 2
            reachedEnd = extracted.videos.isEmpty
            if !hadContent, hasResults {
                let bucketCount = builtBuckets.reduce(0) { $0 + $1.items.count }
                FeedPerformanceSignposts.firstContent(
                    .search, generation: request.token.generation, count: results.count + bucketCount
                )
            }
            PlayerLog.log("[Search] type=all → \(builtBuckets.count) buckets, \(results.count) videos")
        } else {
            FeedCollectionPolicy.appendDeduplicated(to: &rawResults, incoming: extracted.videos, id: \.id)
            let visibleIncoming = extracted.videos.filter { !Self.shouldHideVideoResult($0) }
            let previousCount = results.count
            FeedCollectionPolicy.appendDeduplicated(to: &results, incoming: visibleIncoming, id: \.id)
            if results.count > previousCount {
                preparedItems.append(contentsOf: results[previousCount...].map {
                    Self.makeResultData($0, type: request.query.type)
                })
                snapshotRevision &+= 1
            }
            page = max(page, request.page + 1)
            reachedEnd = extracted.videos.isEmpty
        }
    }

    func extractAllBuckets(
        from buckets: [SearchAllResult.SearchAllBucket]
    ) -> (videos: [PreparedResult], byKind: [AllBucketKind: [SearchResult.SearchResultItem]]) {
        var videos: [PreparedResult] = []
        var byKind: [AllBucketKind: [SearchResult.SearchResultItem]] = [:]
        for bucket in buckets {
            switch bucket.resultType {
            case "video": videos.append(contentsOf: bucket.data.map { PreparedResult(item: $0) })
            case "media_bangumi", "media_ft": byKind[.bangumi, default: []].append(contentsOf: bucket.data)
            case "bili_user": byKind[.user, default: []].append(contentsOf: bucket.data)
            case "live_room", "live_user": byKind[.liveRoom, default: []].append(contentsOf: bucket.data)
            case "article": byKind[.article, default: []].append(contentsOf: bucket.data)
            default: break
            }
        }
        return (videos, byKind)
    }

    func buildAllBuckets(
        from byKind: [AllBucketKind: [SearchResult.SearchResultItem]], tlist: [String: Int]
    ) -> [AllSearchBucket] {
        let limits: [(AllBucketKind, Int)] = [(.bangumi, 3), (.user, 2), (.liveRoom, 3), (.article, 2)]
        return limits.compactMap { kind, limit in
            guard let rawItems = byKind[kind], !rawItems.isEmpty else { return nil }
            let deduped = FeedCollectionPolicy.replaceDeduplicated(rawItems.map { PreparedResult(item: $0) }, id: \.id)
            guard !deduped.isEmpty else { return nil }
            let preview = Array(deduped.prefix(limit))
            let total = max(deduped.count, tlistCount(for: kind, tlist: tlist))
            return AllSearchBucket(kind: kind, items: preview, totalCount: total, hasMore: total > preview.count)
        }
    }

    func tlistCount(for kind: AllBucketKind, tlist: [String: Int]) -> Int {
        switch kind {
        case .bangumi: (tlist["media_bangumi"] ?? 0) + (tlist["media_ft"] ?? 0)
        case .user: tlist["bili_user"] ?? 0
        case .liveRoom: max(tlist["live_room"] ?? 0, tlist["live_user"] ?? 0)
        case .article: tlist["article"] ?? 0
        }
    }

    func publish(_ result: SearchResult, for request: PreparedRequest) {
        let incoming = (result.result ?? []).map { PreparedResult(item: $0) }
        let filtersVideo = request.query.type == .all || request.query.type == .video
        if let hadContent = request.initialHadContent {
            let dedupedRaw = FeedCollectionPolicy.replaceDeduplicated(incoming, id: \.id)
            let visible = filtersVideo ? dedupedRaw.filter { !Self.shouldHideVideoResult($0) } : dedupedRaw
            allBuckets = []
            rawResults = dedupedRaw
            results = visible
            preparedBuckets = []
            preparedItems = visible.map { Self.makeResultData($0, type: request.query.type) }
            snapshotRevision &+= 1
            page = 2
            reachedEnd = incoming.isEmpty
            if !hadContent, !results.isEmpty {
                FeedPerformanceSignposts.firstContent(
                    .search, generation: request.token.generation, count: results.count
                )
            }
            PlayerLog.log("[Search] type=\(request.query.type.rawValue) → \(results.count) results")
        } else {
            FeedCollectionPolicy.appendDeduplicated(to: &rawResults, incoming: incoming, id: \.id)
            let visibleIncoming = filtersVideo ? incoming.filter { !Self.shouldHideVideoResult($0) } : incoming
            let previousCount = results.count
            FeedCollectionPolicy.appendDeduplicated(to: &results, incoming: visibleIncoming, id: \.id)
            if results.count > previousCount {
                preparedItems.append(contentsOf: results[previousCount...].map {
                    Self.makeResultData($0, type: request.query.type)
                })
                snapshotRevision &+= 1
            }
            page = max(page, request.page + 1)
            reachedEnd = incoming.isEmpty
        }
    }

    func storeCache(for query: SubmittedQuery) {
        let key = CacheKey(query: query)
        tabCache[key] = CachedFeed(
            allBuckets: allBuckets,
            rawResults: rawResults,
            results: results,
            preparedBuckets: preparedBuckets,
            preparedItems: preparedItems,
            page: page,
            reachedEnd: reachedEnd
        )
        tabCacheOrder.removeAll { $0 == key }
        tabCacheOrder.append(key)
        while tabCacheOrder.count > Self.maxCachedFeeds {
            tabCache.removeValue(forKey: tabCacheOrder.removeFirst())
        }
    }

    static func shouldHideVideoResult(_ prepared: PreparedResult) -> Bool {
        let item = prepared.item
        return LocalContentFilterStore.shared.shouldHideVideo(
            aid: item.aid,
            bvid: item.bvid,
            mid: item.mid,
            title: prepared.displayTitle
        )
    }

    func syncEligibleSuggestions() {
        let eligible: Bool
        if suggestions.isEmpty {
            eligible = false
        } else {
            let trimmed = keyword.trimmingCharacters(in: .whitespaces)
            eligible = !trimmed.isEmpty && (!hasSearched || trimmed != submittedQuery?.term)
        }
        if hasEligibleSuggestions != eligible {
            hasEligibleSuggestions = eligible
        }
    }

    static func makeBucketData(_ bucket: AllSearchBucket) -> SearchAllBucketData {
        .init(
            targetType: bucket.targetType,
            items: bucket.items.map { makeResultData($0, type: bucket.targetType) },
            totalCount: bucket.totalCount,
            hasMore: bucket.hasMore
        )
    }

    static func makeResultData(_ result: PreparedResult, type: SearchType) -> SearchResultItemData {
        let item = result.item
        let kind: SearchResultItemData.Kind
        switch type {
        case .all, .video:
            let cover = fixScheme(item.pic)
            let ownerFace = item.uface.map(fixScheme)
            kind = .video(.init(
                title: result.displayTitle,
                sources: VideoCoverSources(widescreen: cover),
                durationSeconds: result.durationSeconds,
                author: item.author ?? "",
                playCount: item.play ?? 0,
                routeTarget: .make(
                    bvid: item.bvid, aid: item.aid, title: result.displayTitle,
                    coverURL: cover, ownerName: item.author ?? "", durationSeconds: result.durationSeconds
                ),
                aid: item.aid,
                bvid: item.bvid,
                ownerMid: item.mid,
                ownerFace: ownerFace?.isEmpty == false ? ownerFace : nil
            ))
        case .bangumi:
            kind = .bangumi(.init(
                seasonID: item.seasonId, title: result.displayTitle,
                coverURL: fixScheme(item.cover ?? item.pic), seasonTypeName: item.seasonTypeName,
                score: item.mediaScore?.score, userCount: item.mediaScore?.userCount,
                areas: item.areas, styles: item.styles, indexShow: item.indexShow, desc: result.displayDesc
            ))
        case .user:
            kind = .user(makeUserPayload(result))
        case .liveRoom:
            kind = .liveRoom(.init(
                roomID: item.roomid, title: result.displayTitle, uname: item.uname ?? item.author ?? "",
                areaName: item.areaName ?? item.cateName,
                coverURL: fixScheme(item.liveArtwork ?? item.pic),
                online: item.online ?? item.play ?? 0, liveStatus: item.liveStatus
            ))
        case .article:
            let cover = fixScheme(item.imageUrls?.first ?? item.pic)
            kind = .article(.init(
                articleID: item.articleId ?? item.aid, title: result.displayTitle,
                coverURL: cover.isEmpty ? nil : cover, author: item.author ?? item.uname ?? "",
                categoryName: item.categoryName, viewCount: item.view ?? item.play ?? 0,
                likeCount: item.like ?? 0, desc: result.displayDesc
            ))
        }
        return SearchResultItemData(id: result.id, kind: kind)
    }

    static func makeUserPayload(_ result: PreparedResult) -> SearchResultItemData.UserPayload {
        let item = result.item
        let ownerName = item.uname ?? item.author ?? ""
        let repVideos: [SearchRepresentativeVideoData] = (item.res ?? []).map { rep in
            let cover = fixScheme(rep.pic)
            return .init(
                id: rep.id, title: rep.cleanTitle, sources: VideoCoverSources(widescreen: cover),
                durationSeconds: rep.durationSeconds, playCount: rep.play ?? 0,
                routeTarget: .make(
                    bvid: rep.bvid, aid: rep.aid, title: rep.cleanTitle, coverURL: cover,
                    ownerName: ownerName, durationSeconds: rep.durationSeconds
                )
            )
        }
        return .init(
            mid: item.mid, uname: item.uname ?? result.displayTitle,
            avatarURL: fixScheme(item.upic ?? item.pic),
            officialVerifyType: item.officialVerify?.type, officialVerifyDesc: item.officialVerify?.desc,
            fans: item.fans ?? 0, videos: item.videos ?? 0, usign: item.usign ?? result.displayDesc,
            isLive: item.isLive ?? false, representativeVideos: repVideos
        )
    }

    static func fixScheme(_ pic: String?) -> String {
        guard let pic else { return "" }
        if pic.hasPrefix("//") { return "https:" + pic }
        return pic.replacingOccurrences(of: "http://", with: "https://")
    }

    func touchCache(for key: CacheKey) -> CachedFeed? {
        guard let cached = tabCache[key] else { return nil }
        tabCacheOrder.removeAll { $0 == key }
        tabCacheOrder.append(key)
        return cached
    }

    func logFailure(_ error: any Error, for request: PreparedRequest) {
        let kind = request.initialHadContent != nil ? "type=\(request.query.type.rawValue)" : "pagination"
        PlayerLog.log("[Search] ⚠️ \(kind) failed: \(error)")
    }

    func saveToHistory(keyword: String, modelContext: ModelContext) {
        let existing = try? modelContext.fetch(
            FetchDescriptor<SearchHistoryItem>(predicate: #Predicate { $0.keyword == keyword })
        )
        existing?.forEach { modelContext.delete($0) }
        modelContext.insert(SearchHistoryItem(keyword: keyword))
    }
}
