import Foundation
import SwiftUI

// Seam companion to `UserSpaceViewModel.swift` keeping both files below
// SwiftLint's 500-line file threshold. Nothing outside `UserSpaceViewModel`
// may mutate the backing storage exposed for this file-split seam.
extension UserSpaceViewModel {
    func loadPrivacyGatedLists(mid: Int, generation: UInt64, force: Bool) async {
        async let coins: () = loadCoinsIfNeeded(mid: mid, generation: generation, force: force)
        async let likes: () = loadLikesIfNeeded(mid: mid, generation: generation, force: force)
        async let bangumi: () = loadBangumiIfNeeded(mid: mid, generation: generation, force: force)
        _ = await (coins, likes, bangumi)
    }

    func loadCoinsIfNeeded(mid: Int, generation: UInt64, force: Bool) async {
        guard force || !loadedCoins else { return }
        await loadCoins(mid: mid, generation: generation)
    }

    func loadLikesIfNeeded(mid: Int, generation: UInt64, force: Bool) async {
        guard force || !loadedLikes else { return }
        await loadLikes(mid: mid, generation: generation)
    }

    func loadBangumiIfNeeded(mid: Int, generation: UInt64, force: Bool) async {
        guard force || !loadedBangumi else { return }
        await loadBangumi(mid: mid, generation: generation)
    }

    func handleGatedFailure(_ error: BiliError, tab: UserSpaceTab, what: String, generation: UInt64) {
        guard loadGeneration == generation else { return }
        if case .apiError(let code, _) = error, code == 53013 {
            PlayerLog.log("[UserSpace] \(what) hidden by privacy (53013) — removing tab")
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hiddenTabs.insert(tab)
                if selectedTab == tab { selectedTab = .home }
            }
        } else {
            PlayerLog.log("[UserSpace] \(what) failed: \(error)")
        }
    }

    func loadCoins(mid: Int, generation: UInt64) async {
        do {
            let coins = try await UserAPI.getUserCoinVideos(mid: mid)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            userCoins = coins
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { _ = hiddenTabs.remove(.coins) }
        } catch {
            handleGatedFailure(error, tab: .coins, what: "coin list", generation: generation)
        }
        if !Task.isCancelled, loadGeneration == generation {
            loadedCoins = true
        }
    }

    func loadLikes(mid: Int, generation: UInt64) async {
        do {
            let likes = try await UserAPI.getUserLikeVideos(mid: mid).list ?? []
            guard !Task.isCancelled, loadGeneration == generation else { return }
            userLikes = likes
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { _ = hiddenTabs.remove(.likes) }
        } catch {
            handleGatedFailure(error, tab: .likes, what: "like list", generation: generation)
        }
        if !Task.isCancelled, loadGeneration == generation {
            loadedLikes = true
        }
    }

    func loadBangumi(mid: Int, generation: UInt64) async {
        do {
            let bangumi = try await PGCAPI.getFollowedBangumi(mid: mid).list ?? []
            guard !Task.isCancelled, loadGeneration == generation else { return }
            userBangumi = bangumi
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { _ = hiddenTabs.remove(.bangumi) }
        } catch {
            handleGatedFailure(error, tab: .bangumi, what: "bangumi list", generation: generation)
        }
        if !Task.isCancelled, loadGeneration == generation {
            loadedBangumi = true
        }
    }

    func loadVideos(mid: Int, generation: UInt64) async {
        guard !attemptedVideos, !isLoadingVideos else { return }
        await fetchVideos(mid: mid, generation: generation, replaceExisting: true)
    }

    func fetchVideos(mid: Int, generation: UInt64, replaceExisting: Bool) async {
        guard !isLoadingVideos, replaceExisting || videosHaveMore else { return }
        let requestedPage = replaceExisting ? 1 : videoPage
        isLoadingVideos = true
        defer {
            if loadGeneration == generation {
                isLoadingVideos = false
                if !Task.isCancelled { attemptedVideos = true }
            }
        }

        do {
            let result = try await MessageAPI.getUserVideos(mid: mid, pn: requestedPage)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let fresh = result.list?.vlist ?? []
            if replaceExisting {
                userVideos = fresh
                videoPage = 2
            } else {
                userVideos.append(contentsOf: fresh)
                videoPage = requestedPage + 1
            }
            if let total = result.page?.count {
                totalVideoCount = total
                videosHaveMore = !fresh.isEmpty && userVideos.count < total
            } else {
                videosHaveMore = !fresh.isEmpty
            }
            videosLoadFailed = false
        } catch {
            guard loadGeneration == generation else { return }
            PlayerLog.log("[UserSpace] videos failed: \(error)")
            if userVideos.isEmpty, !BiliAPIRetryPolicy.isCancellation(error) {
                videosLoadFailed = true
            }
        }
    }

    func loadDynamics(mid: Int, generation: UInt64) async {
        guard !attemptedDynamics, !isLoadingDynamics else { return }
        await fetchDynamics(mid: mid, generation: generation, replaceExisting: true)
    }

    func fetchDynamics(mid: Int, generation: UInt64, replaceExisting: Bool) async {
        guard !isLoadingDynamics, replaceExisting || dynamicsHasMore else { return }
        let requestedOffset = replaceExisting ? "" : dynamicOffset
        isLoadingDynamics = true
        defer {
            if loadGeneration == generation {
                isLoadingDynamics = false
                if !Task.isCancelled { attemptedDynamics = true }
            }
        }

        do {
            let result = try await MessageAPI.getUserDynamics(mid: mid, offset: requestedOffset)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let fresh = result.items ?? []
            if replaceExisting {
                userDynamics = fresh
            } else {
                userDynamics.append(contentsOf: fresh)
            }
            dynamicOffset = result.offset ?? ""
            dynamicsHasMore = !fresh.isEmpty && !dynamicOffset.isEmpty
            dynamicsLoadFailed = false
        } catch {
            guard loadGeneration == generation else { return }
            PlayerLog.log("[UserSpace] dynamics failed: \(error)")
            if userDynamics.isEmpty, !BiliAPIRetryPolicy.isCancellation(error) {
                dynamicsLoadFailed = true
            }
        }
    }

    func loadFavorites(mid: Int, generation: UInt64) async {
        guard !attemptedFavorites, !isLoadingFavorites else { return }
        await fetchFavorites(mid: mid, generation: generation)
    }

    func fetchFavorites(mid: Int, generation: UInt64) async {
        guard !isLoadingFavorites else { return }
        isLoadingFavorites = true
        defer {
            if loadGeneration == generation {
                isLoadingFavorites = false
                if !Task.isCancelled { attemptedFavorites = true }
            }
        }
        do {
            let result = try await UserAPI.getFavorites(mid: mid)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            userFavorites = result.list ?? []
            favoritesLoadFailed = false
        } catch {
            guard loadGeneration == generation else { return }
            PlayerLog.log("[UserSpace] favorites failed: \(error)")
            if userFavorites.isEmpty, !BiliAPIRetryPolicy.isCancellation(error) {
                favoritesLoadFailed = true
            }
        }
    }

    func fetchArticles(mid: Int, generation: UInt64, replaceExisting: Bool) async {
        guard !isLoadingArticles, replaceExisting || articlesHaveMore else { return }
        let requestedPage = replaceExisting ? 1 : articlePage
        isLoadingArticles = true
        defer {
            if loadGeneration == generation {
                isLoadingArticles = false
                if !Task.isCancelled { attemptedArticles = true }
            }
        }
        do {
            let result = try await UserAPI.getUserArticles(mid: mid, pn: requestedPage)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let fresh = result.articles ?? []
            if replaceExisting {
                userArticles = fresh
                articlePage = 2
            } else {
                userArticles.append(contentsOf: fresh)
                articlePage = requestedPage + 1
            }
            articlesHaveMore = !fresh.isEmpty && userArticles.count < (result.count ?? .max)
            articlesLoadFailed = false
        } catch {
            guard loadGeneration == generation else { return }
            PlayerLog.log("[UserSpace] articles failed: \(error)")
            if userArticles.isEmpty, !BiliAPIRetryPolicy.isCancellation(error) {
                articlesLoadFailed = true
            }
        }
    }
}
