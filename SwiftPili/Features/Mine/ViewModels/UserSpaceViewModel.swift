import Foundation
import Observation
import SwiftUI

/// Owns creator space data, pagination, privacy-gated tab visibility, and lifecycle caching.
///
/// Keying loads on `LoadIdentity` makes re-entering `UserSpaceView` from pushed
/// child destinations (video player, followers, articles) an idempotent no-op
/// while preserving pull-to-refresh, retry, and account-switch resets.
@MainActor
@Observable
final class UserSpaceViewModel {
    struct LoadIdentity: Hashable, Sendable {
        let mid: Int
        let identityRevision: UInt64
        let isLoggedIn: Bool
        let sessionGeneration: UUID

        @MainActor
        static func capture(mid: Int) -> Self {
            Self(
                mid: mid,
                identityRevision: AccountManager.shared.identityRevision,
                isLoggedIn: AuthManager.shared.isLoggedIn,
                sessionGeneration: AuthManager.shared.sessionGeneration
            )
        }
    }

    var selectedTab: UserSpaceTab = .home
    var showsArticles = false

    private(set) var userInfo: UserInfo?
    private(set) var relationStat: RelationStatResult?
    private(set) var upStat: UpStatResult?
    // Split-file seam: read/written from `UserSpaceViewModel+ContentLoading.swift`.
    var hiddenTabs: Set<UserSpaceTab> = []

    var userVideos: [UserVideoResult.UserVideoItem] = []
    var totalVideoCount: Int?
    var videosHaveMore = true
    var isLoadingVideos = false
    var attemptedVideos = false
    var videosLoadFailed = false

    var userDynamics: [DynamicFeedResult.DynamicItem] = []
    var dynamicsHasMore = true
    var isLoadingDynamics = false
    var attemptedDynamics = false
    var dynamicsLoadFailed = false

    var userFavorites: [FavoriteFolderResult.FavoriteFolder] = []
    private(set) var favoriteFolderPreviews: [Int: [FavoriteContentResult.FavoriteMedia]] = [:]
    var isLoadingFavorites = false
    var attemptedFavorites = false
    var favoritesLoadFailed = false

    var userArticles: [UserArticlesResult.UserArticle] = []
    var articlesHaveMore = true
    var isLoadingArticles = false
    var attemptedArticles = false
    var articlesLoadFailed = false

    var userCoins: [SpaceArchive] = []
    var userLikes: [SpaceArchive] = []
    var userBangumi: [BangumiFollowResult.FollowedBangumi] = []
    var loadedCoins = false
    var loadedLikes = false
    var loadedBangumi = false

    private(set) var userInfoLoadFailed = false
    private(set) var isLoadingStats = true

    @ObservationIgnored private var loadedStats = false
    @ObservationIgnored var videoPage = 1
    @ObservationIgnored var dynamicOffset = ""
    @ObservationIgnored var articlePage = 1
    @ObservationIgnored private var activeIdentity: LoadIdentity?
    @ObservationIgnored private var settledIdentity: LoadIdentity?
    @ObservationIgnored private var loadingIdentity: LoadIdentity?
    @ObservationIgnored var loadGeneration: UInt64 = 0

    var headerLoadFailed: Bool {
        userInfo == nil && userInfoLoadFailed
    }

    var visibleTabs: [UserSpaceTab] {
        UserSpaceTab.allCases.filter { !hiddenTabs.contains($0) }
    }

    func cacheFavoritePreviews(_ items: [FavoriteContentResult.FavoriteMedia], for folderID: Int) {
        favoriteFolderPreviews[folderID] = items
    }

    func loadIfNeeded(identity: LoadIdentity) async {
        guard !Task.isCancelled else { return }
        if activeIdentity != identity {
            resetState(for: identity)
        }
        guard settledIdentity != identity, loadingIdentity != identity else { return }

        loadingIdentity = identity
        let generation = loadGeneration
        defer {
            if loadingIdentity == identity { loadingIdentity = nil }
        }

        await runInitialLoad(mid: identity.mid, generation: generation)
        guard !Task.isCancelled, loadGeneration == generation, activeIdentity == identity,
              !headerLoadFailed else { return }
        settledIdentity = identity
    }

    func refresh(mid: Int) async {
        let identity = LoadIdentity.capture(mid: mid)
        if activeIdentity != identity {
            resetState(for: identity)
        } else {
            loadGeneration &+= 1
            activeIdentity = identity
            settledIdentity = nil
            loadingIdentity = nil
            isLoadingVideos = false
            isLoadingDynamics = false
            isLoadingFavorites = false
            isLoadingArticles = false
        }
        let generation = loadGeneration
        loadingIdentity = identity
        defer {
            if loadingIdentity == identity { loadingIdentity = nil }
        }

        let includesArticles = attemptedArticles || showsArticles
        await runRefresh(mid: mid, generation: generation, includesArticles: includesArticles)
        guard !Task.isCancelled, loadGeneration == generation, activeIdentity == identity,
              !headerLoadFailed else { return }
        settledIdentity = identity
    }

    func retryHeader(mid: Int) async {
        await refresh(mid: mid)
    }

    func retryHomeSections(mid: Int) async {
        let generation = ensureActiveIdentity(mid: mid)
        async let videosTask: () = retryVideosIfFailed(mid: mid, generation: generation)
        async let dynamicsTask: () = retryDynamicsIfFailed(mid: mid, generation: generation)
        async let favoritesTask: () = retryFavoritesIfFailed(mid: mid, generation: generation)
        _ = await (videosTask, dynamicsTask, favoritesTask)
    }

    func loadVideosIfNeeded(mid: Int) async {
        guard !attemptedVideos, !isLoadingVideos else { return }
        let generation = ensureActiveIdentity(mid: mid)
        await loadVideos(mid: mid, generation: generation)
    }

    func loadMoreVideos(mid: Int) async {
        let generation = ensureActiveIdentity(mid: mid)
        await fetchVideos(mid: mid, generation: generation, replaceExisting: false)
    }

    func loadDynamicsIfNeeded(mid: Int) async {
        guard !attemptedDynamics, !isLoadingDynamics else { return }
        let generation = ensureActiveIdentity(mid: mid)
        await loadDynamics(mid: mid, generation: generation)
    }

    func loadMoreDynamics(mid: Int) async {
        let generation = ensureActiveIdentity(mid: mid)
        await fetchDynamics(mid: mid, generation: generation, replaceExisting: false)
    }

    func loadFavoritesIfNeeded(mid: Int) async {
        guard !attemptedFavorites, !isLoadingFavorites else { return }
        let generation = ensureActiveIdentity(mid: mid)
        await loadFavorites(mid: mid, generation: generation)
    }

    func retryFavorites(mid: Int) async {
        let generation = ensureActiveIdentity(mid: mid)
        await fetchFavorites(mid: mid, generation: generation)
    }

    func loadArticlesIfNeeded(mid: Int) async {
        guard !attemptedArticles, !isLoadingArticles else { return }
        let generation = ensureActiveIdentity(mid: mid)
        await fetchArticles(mid: mid, generation: generation, replaceExisting: false)
    }

    func loadMoreArticles(mid: Int) async {
        let generation = ensureActiveIdentity(mid: mid)
        await fetchArticles(mid: mid, generation: generation, replaceExisting: false)
    }
}

// MARK: - Internal Fetching & State Transitions

private extension UserSpaceViewModel {
    func ensureActiveIdentity(mid: Int) -> UInt64 {
        let identity = LoadIdentity.capture(mid: mid)
        if activeIdentity != identity {
            resetState(for: identity)
        }
        return loadGeneration
    }

    func resetState(for identity: LoadIdentity) {
        let sameCreator = activeIdentity?.mid == identity.mid
        loadGeneration &+= 1
        activeIdentity = identity
        settledIdentity = nil
        loadingIdentity = nil

        if !sameCreator {
            selectedTab = .home
            showsArticles = false
            userInfo = nil
            relationStat = nil
            upStat = nil
            isLoadingStats = true
            favoriteFolderPreviews = [:]
        } else {
            isLoadingStats = (relationStat == nil && upStat == nil)
        }

        userInfoLoadFailed = false
        loadedStats = false
        hiddenTabs = []

        userVideos = []
        totalVideoCount = nil
        videosHaveMore = true
        videoPage = 1
        isLoadingVideos = false
        attemptedVideos = false
        videosLoadFailed = false

        userDynamics = []
        dynamicOffset = ""
        dynamicsHasMore = true
        isLoadingDynamics = false
        attemptedDynamics = false
        dynamicsLoadFailed = false

        userFavorites = []
        isLoadingFavorites = false
        attemptedFavorites = false
        favoritesLoadFailed = false

        userArticles = []
        articlePage = 1
        articlesHaveMore = true
        isLoadingArticles = false
        attemptedArticles = false
        articlesLoadFailed = false

        userCoins = []
        userLikes = []
        userBangumi = []
        loadedCoins = false
        loadedLikes = false
        loadedBangumi = false
    }

    func runInitialLoad(mid: Int, generation: UInt64) async {
        async let userTask: () = loadUserInfoIfNeeded(mid: mid, generation: generation)
        async let statsTask: () = loadStatsIfNeeded(mid: mid, generation: generation)
        async let videosTask: () = loadVideos(mid: mid, generation: generation)
        async let dynamicsTask: () = loadDynamics(mid: mid, generation: generation)
        async let favoritesTask: () = loadFavorites(mid: mid, generation: generation)
        async let gatedTask: () = loadPrivacyGatedLists(mid: mid, generation: generation, force: false)
        _ = await (userTask, statsTask, videosTask, dynamicsTask, favoritesTask, gatedTask)
    }

    func runRefresh(mid: Int, generation: UInt64, includesArticles: Bool) async {
        let showPlaceholder = relationStat == nil && upStat == nil
        async let userTask: () = fetchUserInfo(mid: mid, generation: generation)
        async let statsTask: () = fetchStats(
            mid: mid,
            generation: generation,
            showPlaceholderIfEmpty: showPlaceholder
        )
        async let videosTask: () = fetchVideos(mid: mid, generation: generation, replaceExisting: true)
        async let dynamicsTask: () = fetchDynamics(mid: mid, generation: generation, replaceExisting: true)
        async let favoritesTask: () = fetchFavorites(mid: mid, generation: generation)
        async let gatedTask: () = loadPrivacyGatedLists(mid: mid, generation: generation, force: true)
        async let articlesTask: () = fetchArticlesIfIncluded(
            mid: mid, generation: generation, included: includesArticles
        )
        _ = await (userTask, statsTask, videosTask, dynamicsTask, favoritesTask, gatedTask, articlesTask)
    }

    func fetchArticlesIfIncluded(mid: Int, generation: UInt64, included: Bool) async {
        guard included else { return }
        await fetchArticles(mid: mid, generation: generation, replaceExisting: true)
    }

    func retryVideosIfFailed(mid: Int, generation: UInt64) async {
        guard videosLoadFailed else { return }
        await fetchVideos(mid: mid, generation: generation, replaceExisting: true)
    }

    func retryDynamicsIfFailed(mid: Int, generation: UInt64) async {
        guard dynamicsLoadFailed else { return }
        await fetchDynamics(mid: mid, generation: generation, replaceExisting: true)
    }

    func retryFavoritesIfFailed(mid: Int, generation: UInt64) async {
        guard favoritesLoadFailed else { return }
        await fetchFavorites(mid: mid, generation: generation)
    }

    func loadUserInfoIfNeeded(mid: Int, generation: UInt64) async {
        guard userInfo == nil else { return }
        await fetchUserInfo(mid: mid, generation: generation)
    }

    func fetchUserInfo(mid: Int, generation: UInt64) async {
        userInfoLoadFailed = false
        do {
            let loaded = try await UserAPI.getUserInfo(mid: mid)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            userInfo = loaded
            userInfoLoadFailed = false
        } catch {
            guard loadGeneration == generation else { return }
            PlayerLog.log("[UserSpace] user info failed: \(error)")
            if userInfo == nil, !BiliAPIRetryPolicy.isCancellation(error) {
                userInfoLoadFailed = true
            }
        }
    }

    func loadStatsIfNeeded(mid: Int, generation: UInt64) async {
        guard !loadedStats else { return }
        await fetchStats(
            mid: mid,
            generation: generation,
            showPlaceholderIfEmpty: relationStat == nil && upStat == nil
        )
    }

    func fetchStats(mid: Int, generation: UInt64, showPlaceholderIfEmpty: Bool) async {
        if showPlaceholderIfEmpty {
            isLoadingStats = true
        }
        async let fetchedRelationStat = fetchRelationStat(mid: mid)
        async let fetchedUpStat = fetchUpStat(mid: mid)
        let (resolvedRelationStat, resolvedUpStat) = await (fetchedRelationStat, fetchedUpStat)
        guard !Task.isCancelled, loadGeneration == generation else {
            if loadGeneration == generation { isLoadingStats = false }
            return
        }
        if let resolvedRelationStat { relationStat = resolvedRelationStat }
        if let resolvedUpStat { upStat = resolvedUpStat }
        loadedStats = resolvedRelationStat != nil || resolvedUpStat != nil
        isLoadingStats = false
    }

    func fetchRelationStat(mid: Int) async -> RelationStatResult? {
        do {
            return try await MessageAPI.getRelationStat(mid: mid)
        } catch {
            PlayerLog.log("[UserSpace] relation stat failed: \(error)")
            return nil
        }
    }

    func fetchUpStat(mid: Int) async -> UpStatResult? {
        do {
            return try await MessageAPI.getUpStat(mid: mid)
        } catch {
            PlayerLog.log("[UserSpace] up stat failed: \(error)")
            return nil
        }
    }
}
