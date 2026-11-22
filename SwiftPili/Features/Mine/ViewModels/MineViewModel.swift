import Foundation
import Observation

@MainActor
@Observable
final class MineViewModel {
    var userInfo: UserInfo?
    var userStat: UserStatResult?
    var history: [HistoryResult.HistoryItem] = []
    var favorites: [FavoriteFolderResult.FavoriteFolder] = []
    var isLoading = false

    func load() async {
        isLoading = true
        defer { isLoading = false }

        guard AuthManager.shared.isLoggedIn else { return }

        let mid = Int(AuthManager.shared.dedeUserID ?? "0") ?? 0

        do {
            userInfo = try await UserAPI.getMyInfo()
            if let userInfo {
                AccountManager.shared.noteUserInfo(userInfo)
            }
        } catch {
            if Task.isCancelled { return }
            PlayerLog.log("[MineVM] getMyInfo failed: \(error), trying getUserInfo with mid=\(mid)")
        }

        if userInfo == nil, mid > 0 {
            do {
                userInfo = try await UserAPI.getUserInfo(mid: mid)
            } catch {
                if Task.isCancelled { return }
                PlayerLog.log("[MineVM] getUserInfo fallback failed: \(error)")
            }
        }

        if mid > 0 {
            async let stat = try? UserAPI.getStat()
            async let favs = try? UserAPI.getFavorites(mid: mid)

            if let stat = await stat { userStat = stat }
            if let favs = await favs { favorites = favs.list ?? [] }
        }
    }

    func loadHistory() async {
        guard AuthManager.shared.isLoggedIn else { return }
        do {
            let result = try await UserAPI.getHistory()
            history = result.list ?? []
        } catch {
            guard !Task.isCancelled, !BiliAPIRetryPolicy.isCancellation(error), !error.isCancellation else { return }
            PlayerLog.log("[MineVM] load history failed: \(error)")
        }
    }
}
