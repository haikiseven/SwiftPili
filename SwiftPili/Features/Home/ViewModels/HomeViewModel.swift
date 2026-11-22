import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {
    private(set) var recommendationFeed = RecommendationFeed()
    var recommendedItems: [RecommendResult.RecommendItem] { recommendationFeed.items }

    enum RecommendationRefreshResult: Equatable {
        case published(UInt64)
        case unchanged
    }

    @ObservationIgnored
    private let fetchRecommendations: @MainActor (Int, Int) async throws -> RecommendResult
    @ObservationIgnored
    private var recommendationRefresh: FeedLoadToken?
    @ObservationIgnored
    private var pendingRecommendationLoad = false
    private static let refreshCardLimit = 13
    private static let refreshRequestLimit = 3

    init(
        fetchRecommendations: @escaping @MainActor (Int, Int) async throws -> RecommendResult = {
            try await HomeAPI.getRecommended(freshIdx: $0, ps: $1)
        }
    ) {
        self.fetchRecommendations = fetchRecommendations
    }
    var popularItems: [VideoCard] = []
    var rankingItems: [RankingResult.RankItem] = []
    var animeItems: [PGCIndexResult.PGCItem] = []
    var movieItems: [PGCIndexResult.PGCItem] = []
    /// 我的追番 / 追剧 rails shown at the top of the Anime and Movies
    /// sections (follow type 1 = anime, 2 = shows/movies).
    var followedAnime: [BangumiFollowResult.FollowedBangumi] = []
    var followedShows: [BangumiFollowResult.FollowedBangumi] = []

    @ObservationIgnored private var freshIdx = 1
    @ObservationIgnored private var popularPage = 1
    @ObservationIgnored private var noMorePopular = false
    @ObservationIgnored private var animePage = 1
    @ObservationIgnored private var noMoreAnime = false
    @ObservationIgnored private var moviePage = 1
    @ObservationIgnored private var noMoreMovie = false
    @ObservationIgnored private var popularRefresh: FeedLoadToken?
    @ObservationIgnored private var pendingPopularLoad = false
    @ObservationIgnored private var pgcRefreshes: [Int: FeedLoadToken] = [:]
    @ObservationIgnored private var pendingPGCLoads: Set<Int> = []

    @ObservationIgnored private var admissions: [HomeFeedKey: FeedLoadAdmission] = [:]
    private var feedbackStates: [HomeFeedKey: HomeFeedFeedback] = [:]

    func feedback(for key: HomeFeedKey) -> HomeFeedFeedback {
        feedbackStates[key, default: HomeFeedFeedback()]
    }

    /// The value passed by the button is the rendered failure, never a live tab.
    func retry(_ failure: HomeFeedFailure) async {
        switch (failure.key, failure.token.kind) {
        case (.recommended, .refresh):
            await refresh(retrying: failure)
        case (.recommended, _):
            await loadRecommended(retrying: failure)
        case (.popular, .refresh):
            await refreshPopular(retrying: failure)
        case (.popular, _):
            await loadPopular(retrying: failure)
        case (.ranking, _):
            await loadRanking(retrying: failure)
        case let (.pgc(indexType), .refresh):
            await refreshPGC(indexType: indexType, retrying: failure)
        case let (.pgc(indexType), _):
            await loadPGC(indexType: indexType, retrying: failure)
        case let (.followed(indexType), _):
            await loadFollowedBangumi(indexType: indexType, retrying: failure)
        }
    }

    func loadRecommended(retrying failure: HomeFeedFailure? = nil) async {
        guard !Task.isCancelled else { return }
        guard recommendationRefresh == nil else {
            if failure == nil { pendingRecommendationLoad = true }
            return
        }
        let requestedFreshIdx = freshIdx
        let key: HomeFeedKey = .recommended
        let kind: FeedLoadKind = requestedFreshIdx == 1 ? .initial : .pagination
        guard let token = admit(
            key,
            kind: kind,
            cursor: "fresh:\(requestedFreshIdx)",
            retrying: failure
        ) else {
            recordDuplicate(for: key, kind: kind)
            return
        }
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: kind,
            generation: token.generation,
            page: requestedFreshIdx
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = recommendedItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: kind,
                generation: token.generation,
                page: requestedFreshIdx,
                outcome: outcome,
                count: recommendedItems.count
            )
        }

        do {
            try Task.checkCancellation()
            let result = try await fetchRecommendations(requestedFreshIdx, 30)
            try Task.checkCancellation()
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            let prepared = try await recommendationFeed.appendingPage(result.item ?? [])
            try Task.checkCancellation()
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            // Same-cursor admission and refresh supersession fence the snapshot.
            recommendationFeed = prepared
            freshIdx = max(freshIdx, requestedFreshIdx + 1)
            if wasEmpty, !recommendedItems.isEmpty {
                FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: recommendedItems.count)
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error is CancellationError || (error as? BiliError)?.isCancellation == true {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] loadRecommended failed: \(error)")
            }
        }
    }

    func loadPopular(retrying failure: HomeFeedFailure? = nil) async {
        guard !Task.isCancelled else { return }
        guard popularRefresh == nil else {
            if failure == nil { pendingPopularLoad = true }
            return
        }
        guard !noMorePopular else { return }
        let requestedPage = popularPage
        let key: HomeFeedKey = .popular
        let kind: FeedLoadKind = requestedPage == 1 ? .initial : .pagination
        guard let token = admit(key, kind: kind, cursor: "page:\(requestedPage)", retrying: failure) else {
            recordDuplicate(for: key, kind: kind)
            return
        }
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: kind,
            generation: token.generation,
            page: requestedPage
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = popularItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: kind,
                generation: token.generation,
                page: requestedPage,
                outcome: outcome,
                count: popularItems.count
            )
        }

        do {
            let result = try await HomeAPI.getPopular(page: requestedPage)
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            FeedCollectionPolicy.appendDeduplicated(
                to: &popularItems, incoming: result.list ?? [], id: \.id
            )
            noMorePopular = result.noMore ?? false
            popularPage = max(popularPage, requestedPage + 1)
            if wasEmpty, !popularItems.isEmpty {
                FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: popularItems.count)
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error.isCancellation {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] loadPopular failed: \(error)")
            }
        }
    }

    func refreshPopular(retrying failure: HomeFeedFailure? = nil) async {
        let key: HomeFeedKey = .popular
        guard let token = supersedeAndAdmit(key, kind: .refresh, cursor: "page:1", retrying: failure) else { return }
        popularRefresh = token
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: .refresh,
            generation: token.generation,
            page: 1
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = popularItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: .refresh,
                generation: token.generation,
                page: 1,
                outcome: outcome,
                count: popularItems.count
            )
            settlePopularRefresh(token)
        }

        let fetch = Task { try await HomeAPI.getPopular(page: 1) }
        do {
            let result = try await fetch.value
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            popularItems = FeedCollectionPolicy.replaceDeduplicated(result.list ?? [], id: \.id)
            noMorePopular = result.noMore ?? false
            popularPage = 2
            if wasEmpty, !popularItems.isEmpty {
                FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: popularItems.count)
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error is CancellationError || (error as? BiliError)?.isCancellation == true {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] refreshPopular failed (keeping current items): \(error)")
            }
        }
    }

    func loadRanking(retrying failure: HomeFeedFailure? = nil) async {
        let key: HomeFeedKey = .ranking
        guard let token = admit(key, kind: .initial, cursor: "ranking", retrying: failure) else {
            recordDuplicate(for: key, kind: .initial)
            return
        }
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: .initial,
            generation: token.generation,
            page: nil
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = rankingItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: .initial,
                generation: token.generation,
                page: nil,
                outcome: outcome,
                count: rankingItems.count
            )
        }

        do {
            let result = try await HomeAPI.getRanking()
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            rankingItems = FeedCollectionPolicy.replaceDeduplicated(result.list ?? [], id: \.id)
            if wasEmpty, !rankingItems.isEmpty {
                FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: rankingItems.count)
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error.isCancellation {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] loadRanking failed: \(error)")
            }
        }
    }

    func loadPGC(indexType: Int, retrying failure: HomeFeedFailure? = nil) async {
        guard !Task.isCancelled else { return }
        guard pgcRefreshes[indexType] == nil else {
            if failure == nil { pendingPGCLoads.insert(indexType) }
            return
        }
        if indexType == 1 {
            guard !noMoreAnime else { return }
        } else {
            guard !noMoreMovie else { return }
        }
        let key: HomeFeedKey = .pgc(indexType)
        let requestedPage = indexType == 1 ? animePage : moviePage
        let kind: FeedLoadKind = requestedPage == 1 ? .initial : .pagination
        guard let token = admit(key, kind: kind, cursor: "page:\(requestedPage)", retrying: failure) else {
            recordDuplicate(for: key, kind: kind)
            return
        }
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: kind,
            generation: token.generation,
            page: requestedPage
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = indexType == 1 ? animeItems.isEmpty : movieItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: kind,
                generation: token.generation,
                page: requestedPage,
                outcome: outcome,
                count: indexType == 1 ? animeItems.count : movieItems.count
            )
        }

        do {
            let result = try await HomeAPI.getPGCIndex(indexType: indexType, page: requestedPage)
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            let items = result.list ?? []
            if indexType == 1 {
                FeedCollectionPolicy.appendDeduplicated(
                    to: &animeItems,
                    incoming: items,
                    id: \.id
                )
                noMoreAnime = (result.hasNext ?? 0) == 0
                animePage = max(animePage, requestedPage + 1)
                if wasEmpty, !animeItems.isEmpty {
                    FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: animeItems.count)
                }
            } else {
                FeedCollectionPolicy.appendDeduplicated(
                    to: &movieItems,
                    incoming: items,
                    id: \.id
                )
                noMoreMovie = (result.hasNext ?? 0) == 0
                moviePage = max(moviePage, requestedPage + 1)
                if wasEmpty, !movieItems.isEmpty {
                    FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: movieItems.count)
                }
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error.isCancellation {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] loadPGC(\(indexType)) failed: \(error)")
            }
        }
    }

    func loadFollowedBangumi(indexType: Int, retrying failure: HomeFeedFailure? = nil) async {
        guard let midString = AuthManager.shared.dedeUserID, let mid = Int(midString) else { return }
        let key: HomeFeedKey = .followed(indexType)
        guard let token = admit(key, kind: .initial, cursor: "followed:\(indexType)", retrying: failure) else {
            recordDuplicate(for: key, kind: .initial)
            return
        }
        let wasEmpty = indexType == 1 ? followedAnime.isEmpty : followedShows.isEmpty
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: .initial,
            generation: token.generation,
            page: nil
        )
        var outcome: FeedLoadOutcome = .failed
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: .initial,
                generation: token.generation,
                page: nil,
                outcome: outcome,
                count: indexType == 1 ? followedAnime.count : followedShows.count
            )
        }

        do {
            let result = try await PGCAPI.getFollowedBangumi(mid: mid, type: indexType)
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            if indexType == 1 {
                followedAnime = FeedCollectionPolicy.replaceDeduplicated(result.list ?? [], id: \.seasonId)
                if wasEmpty, !followedAnime.isEmpty {
                    FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: followedAnime.count)
                }
            } else {
                followedShows = FeedCollectionPolicy.replaceDeduplicated(result.list ?? [], id: \.seasonId)
                if wasEmpty, !followedShows.isEmpty {
                    FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: followedShows.count)
                }
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error.isCancellation {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] loadFollowedBangumi(\(indexType)) failed: \(error)")
            }
        }
    }

    // Refreshes fetch first and replace on success — clearing up front
    // meant a cancelled .refreshable gesture (early release, re-pull, tab
    // switch → URLError -999) blanked the list permanently. The fetch runs
    // unstructured so the gesture's cancellation can't kill it either.

    func refreshPGC(indexType: Int, retrying failure: HomeFeedFailure? = nil) async {
        let key: HomeFeedKey = .pgc(indexType)
        guard let token = supersedeAndAdmit(key, kind: .refresh, cursor: "page:1", retrying: failure) else { return }
        pgcRefreshes[indexType] = token
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home,
            kind: .refresh,
            generation: token.generation,
            page: 1
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = indexType == 1 ? animeItems.isEmpty : movieItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID,
                screen: .home,
                kind: .refresh,
                generation: token.generation,
                page: 1,
                outcome: outcome,
                count: indexType == 1 ? animeItems.count : movieItems.count
            )
            settlePGCRefresh(indexType: indexType, token: token)
        }

        let fetch = Task { try await HomeAPI.getPGCIndex(indexType: indexType, page: 1) }
        do {
            let result = try await fetch.value
            let items = result.list ?? []
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return
            }
            if indexType == 1 {
                animeItems = FeedCollectionPolicy.replaceDeduplicated(items, id: \.id)
                noMoreAnime = (result.hasNext ?? 0) == 0
                animePage = 2
                if wasEmpty, !animeItems.isEmpty {
                    FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: animeItems.count)
                }
            } else {
                movieItems = FeedCollectionPolicy.replaceDeduplicated(items, id: \.id)
                noMoreMovie = (result.hasNext ?? 0) == 0
                moviePage = 2
                if wasEmpty, !movieItems.isEmpty {
                    FeedPerformanceSignposts.firstContent(.home, generation: token.generation, count: movieItems.count)
                }
            }
            outcome = .success
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error is CancellationError || (error as? BiliError)?.isCancellation == true {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] refreshPGC(\(indexType)) failed (keeping current items): \(error)")
            }
        }
    }

    @discardableResult
    func refresh(retrying failure: HomeFeedFailure? = nil) async -> RecommendationRefreshResult {
        let key: HomeFeedKey = .recommended
        guard let token = supersedeAndAdmit(key, kind: .refresh, cursor: "fresh:1", retrying: failure) else {
            return .unchanged
        }
        recommendationRefresh = token
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .home, kind: .refresh, generation: token.generation, page: 1
        )
        var outcome: FeedLoadOutcome = .failed
        let wasEmpty = recommendedItems.isEmpty
        defer {
            finish(key, token: token, succeeded: outcome == .success)
            FeedPerformanceSignposts.end(
                signpostID, screen: .home, kind: .refresh, generation: token.generation,
                page: 1, outcome: outcome, count: recommendedItems.count
            )
            settleRecommendationRefresh(token)
        }

        do {
            guard let batch = try await collectRecommendationBatch(token) else {
                outcome = .superseded
                return .unchanged
            }
            try Task.checkCancellation()
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return .unchanged
            }
            guard !batch.items.isEmpty else {
                outcome = .success
                return .unchanged
            }
            let prepared = try await recommendationFeed.prepending(batch.items)
            try Task.checkCancellation()
            guard isCurrent(key, token: token) else {
                outcome = .superseded
                return .unchanged
            }
            // Current refresh owns the feed exclusively until this atomic commit.
            recommendationFeed = prepared.feed
            freshIdx = max(freshIdx, batch.lastRequestIndex + 1)
            outcome = .success
            if wasEmpty {
                FeedPerformanceSignposts.firstContent(
                    .home, generation: token.generation, count: recommendedItems.count
                )
            }
            return .published(prepared.generationID)
        } catch {
            if !isCurrent(key, token: token) {
                outcome = .superseded
            } else if Task.isCancelled || error is CancellationError || (error as? BiliError)?.isCancellation == true {
                outcome = .cancelled
            } else {
                publishFailure(key, token: token, error: error)
                PlayerLog.log("[HomeVM] refresh failed (keeping current items): \(error)")
            }
            return .unchanged
        }
    }

    private func collectRecommendationBatch(
        _ token: FeedLoadToken
    ) async throws -> (items: [RecommendResult.RecommendItem], lastRequestIndex: Int)? {
        var candidates: [RecommendResult.RecommendItem] = []
        var lastRequestIndex = 0
        for index in 1...Self.refreshRequestLimit {
            try Task.checkCancellation()
            guard isCurrent(.recommended, token: token) else { return nil }
            let result = try await fetchRecommendations(index, Self.refreshCardLimit - candidates.count)
            try Task.checkCancellation()
            guard isCurrent(.recommended, token: token) else { return nil }
            lastRequestIndex = index
            let rawItems = result.item ?? []
            let accepted = try await recommendationFeed.newItems(
                from: rawItems, excluding: candidates, limit: Self.refreshCardLimit - candidates.count
            )
            try Task.checkCancellation()
            guard isCurrent(.recommended, token: token) else { return nil }
            candidates.append(contentsOf: accepted)
            if candidates.count == Self.refreshCardLimit || rawItems.isEmpty { break }
        }
        return (candidates, lastRequestIndex)
    }

    private func settleRecommendationRefresh(_ token: FeedLoadToken) {
        guard recommendationRefresh == token else { return }
        recommendationRefresh = nil
        guard pendingRecommendationLoad else { return }
        // Keep demand pending until the replay actually starts. A replacement
        // refresh inherits it; an older completion cannot consume its demand.
        Task { [weak self] in
            guard let self, self.recommendationRefresh == nil,
                  self.isCurrent(.recommended, token: token), self.pendingRecommendationLoad else { return }
            self.pendingRecommendationLoad = false
            await self.loadRecommended()
        }
    }

    private func settlePopularRefresh(_ token: FeedLoadToken) {
        guard popularRefresh == token else { return }
        popularRefresh = nil
        guard pendingPopularLoad else { return }
        // Leave demand with the feed until a current replay starts, so a
        // replacement refresh inherits it without admitting the old cursor.
        Task { [weak self] in
            guard let self, self.popularRefresh == nil,
                  self.isCurrent(.popular, token: token), self.pendingPopularLoad else { return }
            self.pendingPopularLoad = false
            await self.loadPopular()
        }
    }

    private func settlePGCRefresh(indexType: Int, token: FeedLoadToken) {
        guard pgcRefreshes[indexType] == token else { return }
        pgcRefreshes[indexType] = nil
        guard pendingPGCLoads.contains(indexType) else { return }
        Task { [weak self] in
            guard let self, self.pgcRefreshes[indexType] == nil,
                  self.isCurrent(.pgc(indexType), token: token),
                  self.pendingPGCLoads.contains(indexType) else { return }
            self.pendingPGCLoads.remove(indexType)
            await self.loadPGC(indexType: indexType)
        }
    }

    private func hasContent(for key: HomeFeedKey) -> Bool {
        switch key {
        case .recommended: !recommendedItems.isEmpty
        case .popular: !popularItems.isEmpty
        case .ranking: !rankingItems.isEmpty
        case .pgc(1): !animeItems.isEmpty
        case .pgc: !movieItems.isEmpty
        case .followed(1): !followedAnime.isEmpty
        case .followed: !followedShows.isEmpty
        }
    }

    private func updateFeedback(
        for key: HomeFeedKey,
        mutate: (inout HomeFeedFeedback) -> Void
    ) {
        var next = feedbackStates[key, default: HomeFeedFeedback()]
        mutate(&next)
        next.isLoading = !hasContent(for: key) && (admissions[key]?.hasInFlight ?? false)
        if feedbackStates[key] != next {
            feedbackStates[key] = next
        }
    }

    private func admit(
        _ key: HomeFeedKey,
        kind: FeedLoadKind,
        cursor: String,
        retrying failure: HomeFeedFailure? = nil
    ) -> FeedLoadToken? {
        guard canRetry(failure, key: key, kind: kind, cursor: cursor) else { return nil }
        var policy = admissions[key, default: FeedLoadAdmission()]
        let token = policy.admit(kind: kind, cursor: cursor)
        admissions[key] = policy
        if token != nil {
            updateFeedback(for: key) { $0.failure = nil }
        }
        return token
    }

    private func supersedeAndAdmit(
        _ key: HomeFeedKey,
        kind: FeedLoadKind,
        cursor: String,
        retrying failure: HomeFeedFailure? = nil
    ) -> FeedLoadToken? {
        guard canRetry(failure, key: key, kind: kind, cursor: cursor) else { return nil }
        var policy = admissions[key, default: FeedLoadAdmission()]
        let token = policy.supersedeAndAdmit(kind: kind, cursor: cursor)
        admissions[key] = policy
        updateFeedback(for: key) { $0.failure = nil }
        return token
    }

    private func canRetry(
        _ failure: HomeFeedFailure?,
        key: HomeFeedKey,
        kind: FeedLoadKind,
        cursor: String
    ) -> Bool {
        guard let failure else { return true }
        return failure.key == key && failure.token.kind == kind && failure.token.cursor == cursor
            && feedbackStates[key]?.failure == failure && isCurrent(key, token: failure.token)
    }

    private func publishFailure(_ key: HomeFeedKey, token: FeedLoadToken, error: any Error) {
        updateFeedback(for: key) {
            $0.failure = HomeFeedFailure(
                key: key, token: token, message: error.localizedDescription
            )
        }
    }

    private func isCurrent(_ key: HomeFeedKey, token: FeedLoadToken) -> Bool {
        admissions[key]?.isCurrent(token) ?? false
    }

    private func finish(_ key: HomeFeedKey, token: FeedLoadToken, succeeded: Bool) {
        var policy = admissions[key, default: FeedLoadAdmission()]
        policy.finish(token, succeeded: succeeded)
        admissions[key] = policy
        if succeeded, isCurrent(key, token: token) {
            updateFeedback(for: key) {
                $0.hasSucceeded = true
                $0.failure = nil
            }
        } else {
            updateFeedback(for: key) { _ in }
        }
    }

    private func recordDuplicate(for key: HomeFeedKey, kind: FeedLoadKind) {
        let policy = admissions[key, default: FeedLoadAdmission()]
        FeedPerformanceSignposts.duplicateSuppressed(
            .home,
            kind: kind,
            generation: policy.generation,
            count: policy.duplicateSuppressionCount
        )
    }
}
