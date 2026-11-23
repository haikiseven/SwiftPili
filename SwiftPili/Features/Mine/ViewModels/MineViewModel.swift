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

    @ObservationIgnored private var authManager: AuthManager
    @ObservationIgnored private var accountManager: AccountManager

    init(
        authManager: AuthManager = .shared,
        accountManager: AccountManager = .shared
    ) {
        self.authManager = authManager
        self.accountManager = accountManager
    }

    func bind(authManager: AuthManager, accountManager: AccountManager) {
        self.authManager = authManager
        self.accountManager = accountManager
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        guard authManager.isLoggedIn else { return }

        let mid = Int(authManager.dedeUserID ?? "0") ?? 0

        do {
            userInfo = try await UserAPI.getMyInfo()
            if let userInfo {
                accountManager.noteUserInfo(userInfo)
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
        guard authManager.isLoggedIn else { return }
        do {
            let result = try await UserAPI.getHistory()
            history = result.list ?? []
        } catch {
            guard !Task.isCancelled, !BiliAPIRetryPolicy.isCancellation(error), !error.isCancellation else { return }
            PlayerLog.log("[MineVM] load history failed: \(error)")
        }
    }

    func updateUsername(_ name: String) async throws {
        do {
            _ = try await UserAPI.updateUsername(name)
            PlayerLog.log("[Profile] username updated → \(name) (6 coins deducted)")
            await load()
        } catch {
            PlayerLog.log("[Profile] rename failed: \(error)")
            throw error
        }
    }

    func updateSignature(_ signature: String) async throws {
        do {
            _ = try await UserAPI.updateSignature(signature)
            PlayerLog.log("[Profile] signature updated (\(signature.count) chars)")
            await load()
        } catch {
            PlayerLog.log("[Profile] signature update failed: \(error)")
            throw error
        }
    }

    func updateAvatar(jpegData: Data) async throws {
        do {
            try await UploadAPI.updateAvatar(jpegData)
            await load()
        } catch {
            PlayerLog.log("[Profile] avatar update failed: \(error)")
            throw error
        }
    }
}
