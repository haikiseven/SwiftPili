import Foundation
import Observation

@MainActor
enum DynamicFeedSelection: Hashable {
    case category(DynamicsViewModel.FeedFilter)
    case people(authorMID: Int?)

    var isPeopleMode: Bool {
        if case .people = self { return true }
        return false
    }

    var authorMID: Int? {
        guard case .people(let authorMID) = self else { return nil }
        return authorMID
    }

    var apiType: String? {
        switch self {
        case .category(let filter): filter.apiType
        case .people(let authorMID): authorMID == nil ? DynamicsViewModel.FeedFilter.all.apiType : nil
        }
    }

    var title: String {
        switch self {
        case .category(let filter): filter.title
        case .people: String(localized: "Following People")
        }
    }

    var icon: String {
        switch self {
        case .category(let filter): filter.icon
        case .people: "person.2"
        }
    }
}

private struct DynamicsFeedRequest {
    let token: FeedLoadToken
    let selection: DynamicFeedSelection
    let accountMID: Int
    let wasEmpty: Bool
}

@MainActor
@Observable
final class DynamicsViewModel {
    enum FeedFilter: String, CaseIterable, Identifiable, Sendable {
        case all
        case bangumi
        case article

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .bangumi: String(localized: "Anime")
            case .article: String(localized: "Articles")
            }
        }

        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .bangumi: "sparkles.tv"
            case .article: "doc.richtext"
            }
        }

        var apiType: String {
            switch self {
            case .all: "all"
            case .bangumi: "pgc"
            case .article: "article"
            }
        }
    }

    var items: [DynamicFeedResult.DynamicItem] = [] {
        didSet { itemsRevision &+= 1 }
    }
    @ObservationIgnored private(set) var itemsRevision: UInt64 = 0
    var isLoading = false
    var selection: DynamicFeedSelection = .category(.all)
    var filter: FeedFilter {
        if case .category(let filter) = selection { return filter }
        return .all
    }
    var isPeopleMode: Bool { selection.isPeopleMode }
    var selectedAuthorMID: Int? { selection.authorMID }
    var errorMessage: String?
    private(set) var hasLoaded = false

    let interactions = MomentInteractionStore(logTag: "DynamicsVM")

    private struct CachedFeed {
        var rawItems: [DynamicFeedResult.DynamicItem]
        var items: [DynamicFeedResult.DynamicItem]
        var offset: String?
        var hasMore: Bool
        var hasLoaded: Bool
    }

    @ObservationIgnored private var rawItems: [DynamicFeedResult.DynamicItem] = []
    @ObservationIgnored private var offset: String?
    @ObservationIgnored private var hasMore = true
    @ObservationIgnored private var admission = FeedLoadAdmission()
    @ObservationIgnored private var cachedFeeds: [DynamicFeedSelection: CachedFeed] = [:]

    init() {
        LocalContentFilterStore.shared.addObserver(self) { viewModel in
            viewModel.reapplyContentFilters()
        }
    }

    func load() async {
        guard let requestedAccountMID = activeFeedAccountMID() else { return }
        guard hasMore, !isLoading else { return }
        let requestedSelection = selection
        let requestedOffset = offset ?? ""
        let kind: FeedLoadKind = requestedOffset.isEmpty ? .initial : .pagination
        guard let token = admitFeedRequest(
            kind: kind,
            accountMID: requestedAccountMID,
            selection: requestedSelection,
            offset: requestedOffset
        ) else { return }
        syncLoadingState()
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .dynamics,
            kind: kind,
            generation: token.generation,
            page: nil
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = items.isEmpty
        let request = DynamicsFeedRequest(
            token: token,
            selection: requestedSelection,
            accountMID: requestedAccountMID,
            wasEmpty: wasEmpty
        )
        defer {
            admission.finish(token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .dynamics,
                kind: kind,
                generation: token.generation,
                page: nil,
                outcome: outcome,
                count: items.count
            )
            syncLoadingState()
        }

        do {
            let result = try await DynamicAPI.getFeed(
                type: requestedSelection.apiType,
                hostMID: requestedSelection.authorMID,
                offset: requestedOffset
            )
            guard publishFeedResult(
                result,
                request: request,
                replacing: false
            ) else {
                outcome = .superseded
                return
            }
            outcome = .success
        } catch {
            outcome = recordFeedFailure(error, request: request, message: "load failed")
        }
    }

    func refresh() async {
        guard let requestedAccountMID = activeFeedAccountMID() else { return }
        let requestedSelection = selection
        let token = admission.supersedeAndAdmit(
            kind: .refresh,
            cursor: feedRequestCursor(
                accountMID: requestedAccountMID,
                selection: requestedSelection,
                offset: ""
            )
        )
        syncLoadingState()
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .dynamics,
            kind: .refresh,
            generation: token.generation,
            page: nil
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = items.isEmpty
        let request = DynamicsFeedRequest(
            token: token,
            selection: requestedSelection,
            accountMID: requestedAccountMID,
            wasEmpty: wasEmpty
        )
        defer {
            admission.finish(token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .dynamics,
                kind: .refresh,
                generation: token.generation,
                page: nil,
                outcome: outcome,
                count: items.count
            )
            syncLoadingState()
        }

        do {
            let result = try await fetchFirstFeedPage(for: requestedSelection)
            guard publishFeedResult(
                result,
                request: request,
                replacing: true
            ) else {
                outcome = .superseded
                return
            }
            outcome = .success
        } catch {
            outcome = recordFeedFailure(
                error,
                request: request,
                message: "refresh failed (keeping current items)"
            )
        }
    }

    func select(_ newSelection: DynamicFeedSelection) {
        guard newSelection != selection else { return }
        if hasLoaded {
            cachedFeeds[selection] = CachedFeed(
                rawItems: rawItems,
                items: items,
                offset: offset,
                hasMore: hasMore,
                hasLoaded: hasLoaded
            )
        }
        admission.supersede()
        syncLoadingState()
        selection = newSelection
        errorMessage = nil
        if let cached = cachedFeeds[newSelection] {
            rawItems = cached.rawItems
            items = cached.rawItems.filter { !Self.shouldHideDynamic($0) }
            offset = cached.offset
            hasMore = cached.hasMore
            hasLoaded = cached.hasLoaded
            return
        }
        rawItems = []
        items = []
        hasLoaded = false
        offset = nil
        hasMore = true
        Task { await refresh() }
    }

    func reapplyContentFilters() {
        guard !rawItems.isEmpty else { return }
        let filtered = rawItems.filter { !Self.shouldHideDynamic($0) }
        guard filtered.map(Self.stableItemID) != items.map(Self.stableItemID) else { return }
        items = filtered
        if var cached = cachedFeeds[selection] {
            cached.items = filtered
            cachedFeeds[selection] = cached
        }
    }

    func displayedItems(for target: DynamicFeedSelection) -> [DynamicFeedResult.DynamicItem] {
        if target == selection { return items }
        return (cachedFeeds[target]?.rawItems ?? []).filter { !Self.shouldHideDynamic($0) }
    }

    func displayedHasLoaded(for target: DynamicFeedSelection) -> Bool {
        if target == selection { return hasLoaded }
        return cachedFeeds[target]?.hasLoaded ?? false
    }

    func displayedError(for target: DynamicFeedSelection) -> String? {
        target == selection ? errorMessage : nil
    }

    func displayedIsLoading(for target: DynamicFeedSelection) -> Bool {
        target == selection && isLoading
    }

    nonisolated static func stableItemID(_ item: DynamicFeedResult.DynamicItem) -> String {
        if let id = item.idStr, !id.isEmpty {
            return "dynamic:\(id)"
        }
        if let commentID = item.basic?.commentIdStr, !commentID.isEmpty {
            return "comment:\(commentID)"
        }
        if let archive = item.modules?.moduleDynamic?.major?.archive {
            if let bvid = archive.bvid, !bvid.isEmpty {
                return "video:\(bvid)"
            }
            if let aid = archive.aid, !aid.isEmpty {
                return "aid:\(aid)"
            }
        }
        if let voteID = item.modules?.moduleDynamic?.additional?.vote?.voteId {
            return "vote:\(voteID)"
        }
        let author = item.modules?.moduleAuthor
        return "fallback:\(item.type ?? "unknown"):\(author?.mid ?? 0):\(author?.pubTs ?? 0)"
    }

    func likeState(for item: DynamicFeedResult.DynamicItem) -> (liked: Bool, count: Int) {
        interactions.likeState(for: item)
    }

    func toggleLike(for item: DynamicFeedResult.DynamicItem) async {
        await interactions.toggleLike(for: item)
    }

    func repost(item: DynamicFeedResult.DynamicItem, content: String) async -> Bool {
        await interactions.repost(item: item, content: content)
    }

    enum MomentPostOutcome {
        case posted
        case cancelled
        case failed(String)
    }

    func postMoment(
        text: String,
        expectedSession: UUID,
        expectedIdentityRevision: UInt64
    ) async -> MomentPostOutcome {
        guard AuthManager.shared.isLoggedIn,
              AuthManager.shared.sessionGeneration == expectedSession,
              AccountManager.shared.identityRevision == expectedIdentityRevision else {
            return .failed(BiliError.authRequired.localizedDescription)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Task.isCancelled else { return .cancelled }
        do {
            _ = try await DynamicAPI.createMoment(text: trimmed)
            return .posted
        } catch {
            PlayerLog.log("[DynamicsVM] post failed: \(error)")
            guard !Task.isCancelled, !error.isCancellation else { return .cancelled }
            return .failed(String(
                format: String(localized: "Failed to post: %@"),
                error.localizedDescription
            ))
        }
    }

}

private extension DynamicsViewModel {
    var activeAccountMID: Int? {
        guard AuthManager.shared.isLoggedIn else { return nil }
        let rosterMID = AccountManager.shared.activeMid.flatMap(Int.init)
        let authenticatedMID = AuthManager.shared.dedeUserID.flatMap(Int.init)
        if let rosterMID, let authenticatedMID, rosterMID != authenticatedMID { return nil }
        return rosterMID ?? authenticatedMID
    }

    func activeFeedAccountMID() -> Int? {
        guard AuthManager.shared.isLoggedIn else { return nil }
        guard let activeAccountMID else {
            errorMessage = String(localized: "Could not identify the current account.")
            return nil
        }
        return activeAccountMID
    }

    func isCurrentFeedRequest(_ request: DynamicsFeedRequest) -> Bool {
        admission.isCurrent(request.token)
            && selection == request.selection
            && activeAccountMID == request.accountMID
    }

    func feedRequestCursor(
        accountMID: Int,
        selection: DynamicFeedSelection,
        offset: String
    ) -> String {
        let source: String
        switch selection {
        case .category(let filter): source = "category:\(filter.rawValue)"
        case .people(let authorMID): source = "people:\(authorMID.map(String.init) ?? "all")"
        }
        let cursor = offset.isEmpty ? "initial" : offset
        return "account:\(accountMID)|\(source)|offset:\(cursor)"
    }

    func admitFeedRequest(
        kind: FeedLoadKind,
        accountMID: Int,
        selection: DynamicFeedSelection,
        offset: String
    ) -> FeedLoadToken? {
        guard let token = admission.admit(
            kind: kind,
            cursor: feedRequestCursor(accountMID: accountMID, selection: selection, offset: offset)
        ) else {
            FeedPerformanceSignposts.duplicateSuppressed(
                .dynamics,
                kind: kind,
                generation: admission.generation,
                count: admission.duplicateSuppressionCount
            )
            return nil
        }
        return token
    }

    func publishFeedResult(
        _ result: DynamicFeedResult,
        request: DynamicsFeedRequest,
        replacing: Bool
    ) -> Bool {
        guard isCurrentFeedRequest(request) else { return false }

        if replacing {
            rawItems = FeedCollectionPolicy.replaceDeduplicated(result.items ?? [], id: Self.stableItemID)
            items = rawItems.filter { !Self.shouldHideDynamic($0) }
            interactions.reset()
        } else {
            FeedCollectionPolicy.appendDeduplicated(
                to: &rawItems,
                incoming: result.items ?? [],
                id: Self.stableItemID
            )
            items = rawItems.filter { !Self.shouldHideDynamic($0) }
        }
        offset = result.offset
        hasMore = result.hasMore ?? false
        hasLoaded = true
        errorMessage = nil
        cachedFeeds[request.selection] = CachedFeed(
            rawItems: rawItems,
            items: items,
            offset: offset,
            hasMore: hasMore,
            hasLoaded: hasLoaded
        )
        if request.wasEmpty, !items.isEmpty {
            FeedPerformanceSignposts.firstContent(
                .dynamics,
                generation: request.token.generation,
                count: items.count
            )
        }
        return true
    }

    func recordFeedFailure(
        _ error: Error,
        request: DynamicsFeedRequest,
        message: String
    ) -> FeedLoadOutcome {
        guard isCurrentFeedRequest(request) else {
            return Task.isCancelled ? .cancelled : .superseded
        }
        PlayerLog.log("[DynamicsVM] \(message): \(error)")
        errorMessage = Self.describe(error)
        return Task.isCancelled ? .cancelled : .failed
    }

    func fetchFirstFeedPage(for selection: DynamicFeedSelection) async throws -> DynamicFeedResult {
        let fetch = Task {
            try await DynamicAPI.getFeed(
                type: selection.apiType,
                hostMID: selection.authorMID
            )
        }
        return try await fetch.value
    }

    static func describe(_ error: Error) -> String {
        if case let BiliError.apiError(code, message) = error {
            return "\(message) (\(code))"
        }
        return error.localizedDescription
    }

    func syncLoadingState() {
        let currentIsLoading = admission.hasInFlight
        if isLoading != currentIsLoading {
            isLoading = currentIsLoading
        }
    }

    static func shouldHideDynamic(_ item: DynamicFeedResult.DynamicItem) -> Bool {
        if matchesDynamicPayload(item) {
            return true
        }
        if let orig = item.orig?.item, matchesDynamicPayload(orig) {
            return true
        }
        return false
    }

    private static func matchesDynamicPayload(_ item: DynamicFeedResult.DynamicItem) -> Bool {
        let mid = item.modules?.moduleAuthor?.mid
        let major = item.modules?.moduleDynamic?.major
        let archive = major?.archive
        let aid = archive?.aid.flatMap(Int.init) ?? major?.ugcSeason?.aid
        let bvid = archive?.bvid
        let titleParts: [String] = [
            archive?.title,
            major?.opus?.title,
            major?.article?.title,
            major?.ugcSeason?.title,
            major?.pgc?.title,
            item.modules?.moduleDynamic?.desc?.text,
            major?.opus?.summary?.text,
        ].compactMap { raw in
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
        let combinedText = titleParts.isEmpty ? nil : titleParts.joined(separator: "\n")
        return LocalContentFilterStore.shared.shouldHideVideo(
            aid: aid,
            bvid: bvid,
            mid: mid,
            title: combinedText
        )
    }
}
