import Foundation
import Observation

/// One saved credential set keyed by `mid` (`DedeUserID`); display metadata is
/// populated from `myinfo` while the account is active.
struct StoredAccount: Codable, Identifiable, Equatable {
    let mid: String
    var name: String
    var avatarURL: String?
    var sessData: String
    var biliJct: String
    /// `DedeUserID__ckMd5` validated against `DedeUserID` on switches; `nil`
    /// clears any stale jar cookie rather than sending a mismatched pair.
    var ckMd5: String?
    /// Set when the post-switch `nav` probe finds the server invalidated this session.
    var sessionExpired: Bool?

    var id: String { mid }
}

/// Manages saved accounts and switching while `AuthManager` holds the active
/// per-cookie Keychain keys (`SESSDATA`, `bili_jct`, `DedeUserID`, `DedeUserID__ckMd5`).
@MainActor
@Observable
final class AccountManager {
    static let shared = AccountManager()

    private(set) var accounts: [StoredAccount] = []
    /// Observable mirror of the active `DedeUserID` so root tabs re-key on account switch or logout.
    private(set) var activeMid: String?
    private(set) var identityRevision: UInt64 = 0

    /// Active roster entry for display labels (`nil` means no stored display record, not signed-out).
    var activeAccount: StoredAccount? {
        guard let activeMid else { return nil }
        return accounts.first { $0.mid == activeMid }
    }

    /// Display name for a newly detected expired session, presented by `MineView`.
    var expiredSessionAlert: String?

    /// Stored in Keychain so `SESSDATA` never enters `UserDefaults` backups.
    private static let rosterKey = "accounts.v1"

    private init() {
        accounts = Self.loadRoster()
        activeMid = AuthManager.shared.dedeUserID
        if accounts.isEmpty,
           let mid = activeMid,
           let sessData = AuthManager.shared.sessData,
           let biliJct = AuthManager.shared.biliJct {
            let jarCkMd5 = AuthManager.shared.ckMd5 ?? HTTPCookieStorage.shared.cookies?
                .first(where: { $0.name == "DedeUserID__ckMd5" && $0.domain.contains("bilibili.com") })?.value
            accounts = [
                StoredAccount(
                    mid: mid,
                    name: "",
                    avatarURL: nil,
                    sessData: sessData,
                    biliJct: biliJct,
                    ckMd5: jarCkMd5
                ),
            ]
            persist()
        }
    }

    /// Upserts from `AuthManager.loginWithCookies`; `nil` `ckMd5` preserves any
    /// existing roster value during switches.
    func upsert(mid: String, sessData: String, biliJct: String, ckMd5: String?) {
        identityRevision &+= 1
        if let index = accounts.firstIndex(where: { $0.mid == mid }) {
            accounts[index].sessData = sessData
            accounts[index].biliJct = biliJct
            if let ckMd5 {
                accounts[index].ckMd5 = ckMd5
            }
        } else {
            accounts.append(
                StoredAccount(
                    mid: mid,
                    name: "",
                    avatarURL: nil,
                    sessData: sessData,
                    biliJct: biliJct,
                    ckMd5: ckMd5
                )
            )
        }
        activeMid = mid
        persist()
        Task { await validateActiveSession() }
    }

    /// Verifies the active credential set via `nav` and flags invalidated sessions.
    func validateActiveSession() async {
        guard let expected = activeMid else { return }
        guard let identity = try? await AuthAPI.sessionIdentity() else { return }
        guard activeMid == expected else { return }
        let valid = identity.isLogin && identity.mid.map(String.init) == expected
        if let index = accounts.firstIndex(where: { $0.mid == expected }) {
            let flaggedExpired = accounts[index].sessionExpired == true
            if flaggedExpired == valid {
                accounts[index].sessionExpired = valid ? nil : true
                persist()
            }
        }
        if valid {
            PlayerLog.log("[Account] session validated: mid=\(expected)")
        } else {
            let name = accounts.first(where: { $0.mid == expected })?.name ?? ""
            let midDescription = identity.mid.map(String.init) ?? "nil"
            PlayerLog.log(
                "[Account] ⚠️ session for \(name.isEmpty ? expected : name) is DEAD "
                    + "(isLogin=\(identity.isLogin) mid=\(midDescription)) — re-login required"
            )
            expiredSessionAlert = name.isEmpty ? "UID \(expected)" : name
        }
    }

    /// Updates display metadata from `myinfo`.
    func noteUserInfo(_ user: UserInfo) {
        guard let index = accounts.firstIndex(where: { $0.mid == String(user.mid) }),
              accounts[index].name != user.name || accounts[index].avatarURL != user.face else { return }
        accounts[index].name = user.name
        accounts[index].avatarURL = user.face
        persist()
    }

    func switchTo(_ mid: String) {
        guard mid != activeMid,
              let account = accounts.first(where: { $0.mid == mid }) else { return }
        PlayerLog.log("[Account] switching to \(account.name.isEmpty ? mid : account.name)")
        AuthManager.shared.loginWithCookies(
            sessData: account.sessData,
            biliJct: account.biliJct,
            dedeUserID: account.mid,
            ckMd5: account.ckMd5
        )
    }

    func remove(_ mid: String) {
        if mid == activeMid {
            AuthManager.shared.logout()
            return
        }
        accounts.removeAll { $0.mid == mid }
        persist()
    }

    /// Removes the active account's credentials from the roster while keeping other saved accounts.
    func noteLogout() {
        identityRevision &+= 1
        if let mid = activeMid {
            accounts.removeAll { $0.mid == mid }
            persist()
        }
        activeMid = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts),
           let json = String(data: data, encoding: .utf8) {
            KeychainService.set(key: Self.rosterKey, value: json)
        }
    }

    private static func loadRoster() -> [StoredAccount] {
        guard let json = KeychainService.get(key: rosterKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([StoredAccount].self, from: data) else { return [] }
        return list
    }
}
