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
                // Keep the roster's display name/avatar current.
                AccountManager.shared.noteUserInfo(userInfo)
            }
        } catch {
            // Switching away from the Mine tab cancels the .task, which
            // surfaces as NSURLError -999 — not a real failure, and the
            // fallback would just die cancelled too. The tab's .task
            // refires on reappearance.
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

            // Assign only on success — a cancelled/failed refresh must not
            // blank out stats and favorites that are already on screen.
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
