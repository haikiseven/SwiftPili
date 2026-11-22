import Foundation
import Observation
import os

struct CapturedLoginCookies: Sendable {
    let sessData: String?
    let biliJct: String?
    let dedeUserID: String?
    let ckMd5: String?
}

@Observable
final class AuthManager: @unchecked Sendable {
    static let shared = AuthManager()

    private(set) var isLoggedIn = false

    /// Non-secret lifetime for account-derived work. A same-account login is
    /// a replacement too: MID equality cannot authorize an old response.
    private let sessionIdentity = OSAllocatedUnfairLock(initialState: UUID())
    var sessionGeneration: UUID { sessionIdentity.withLock { $0 } }

    /// The stored identity, cached. Unlike the other three, dedeUserID is read
    /// from view BODIES — CommentRowView asks "is this my comment?" per row, so
    /// scrolling the comment list turned into a stream of synchronous securityd
    /// IPCs. Safe because the Keychain entry has exactly TWO writers
    /// (loginWithCookies, logout — an account switch replays the former), and
    /// both refresh this box, so a switch can never be read stale.
    /// Double optional: outer nil = never read (or every read so far came back
    /// empty), `.some(...)` = a known-good state written by a write site or a
    /// successful read. A nil READ is deliberately NOT cached: the Keychain
    /// answers nil both for "absent" and for "device locked" (background
    /// launch, background audio resume), and caching the latter would read as
    /// logged-out for the rest of the process. Logged-out sessions therefore
    /// keep re-querying per read — the pre-cache behavior, and the write sites
    /// still cache `.some(nil)` on logout, which covers the common case.
    /// Locked because the getter is reached from any thread (request signing,
    /// the live danmaku client) while both writers are @MainActor.
    private let cachedDedeUserID = OSAllocatedUnfairLock<String??>(initialState: nil)

    var sessData: String? { KeychainService.get(key: "SESSDATA") }
    var biliJct: String? { KeychainService.get(key: "bili_jct") }
    var dedeUserID: String? {
        cachedDedeUserID.withLock { box in
            if let cached = box { return cached }
            let stored = KeychainService.get(key: "DedeUserID")
            // Cache only a real value — see the box's comment for why a nil
            // read (absent OR locked device) must stay uncached.
            if let stored { box = .some(stored) }
            return stored
        }
    }

    var ckMd5: String? { KeychainService.get(key: "DedeUserID__ckMd5") }

    /// Refreshes (not merely invalidates) the identity cache: the new value is
    /// already in hand at both write sites, and DedeUserID must read as
    /// switched the instant it lands — the ckMd5 it is validated against
    /// changes in the same breath.
    private func cacheDedeUserID(_ value: String?) {
        cachedDedeUserID.withLock { $0 = .some(value) }
    }

    private init() {
        isLoggedIn = KeychainService.get(key: "SESSDATA") != nil
        restoreCookies()
    }

    /// ckMd5 is DedeUserID__ckMd5 — BiliBili validates it AGAINST
    /// DedeUserID, so the pair must switch atomically. Leaving another
    /// account's ckMd5 in the jar made the API treat the switched-to
    /// session as invalid (empty myinfo/fav payloads): only the most
    /// recently network-logged-in account "worked". nil means unknown:
    /// the stale cookie is DELETED — an absent ckMd5 passes where a
    /// mismatched one fails risk validation.
    @MainActor
    func loginWithCookies(sessData: String, biliJct: String, dedeUserID: String, ckMd5: String? = nil) {
        sessionIdentity.withLock { $0 = UUID() }
        KeychainService.set(key: "SESSDATA", value: sessData)
        KeychainService.set(key: "bili_jct", value: biliJct)
        KeychainService.set(key: "DedeUserID", value: dedeUserID)
        cacheDedeUserID(dedeUserID)
        if let ckMd5 {
            KeychainService.set(key: "DedeUserID__ckMd5", value: ckMd5)
        } else {
            KeychainService.delete(key: "DedeUserID__ckMd5")
        }
        isLoggedIn = true
        syncCookiesToStorage(sessData: sessData, biliJct: biliJct, dedeUserID: dedeUserID, ckMd5: ckMd5)
        AccountManager.shared.upsert(mid: dedeUserID, sessData: sessData, biliJct: biliJct, ckMd5: ckMd5)
    }

    @MainActor
    func logout() {
        sessionIdentity.withLock { $0 = UUID() }
        KeychainService.delete(key: "SESSDATA")
        KeychainService.delete(key: "bili_jct")
        KeychainService.delete(key: "DedeUserID")
        cacheDedeUserID(nil)
        KeychainService.delete(key: "DedeUserID__ckMd5")
        isLoggedIn = false
        clearCookies()
        AccountManager.shared.noteLogout()
    }

    private func restoreCookies() {
        guard let sessData = KeychainService.get(key: "SESSDATA"),
              let biliJct = KeychainService.get(key: "bili_jct"),
              let dedeUserID = KeychainService.get(key: "DedeUserID") else { return }
        syncCookiesToStorage(sessData: sessData, biliJct: biliJct, dedeUserID: dedeUserID, ckMd5: ckMd5)
    }

    private func syncCookiesToStorage(sessData: String, biliJct: String, dedeUserID: String, ckMd5: String?) {
        // Purge EVERY stored variant of the auth cookies before setting
        // ours: server-set copies (passport logins run with
        // httpCookieAcceptPolicy .always) can differ in domain spelling
        // ("bilibili.com" vs ".bilibili.com") or path, and
        // HTTPCookieStorage keys on (name, domain, path) — setCookie
        // does NOT replace them. Requests then carried TWO SESSDATAs and
        // the server honored the other account's: nav identified the
        // PREVIOUS account after a switch (observed on device).
        clearCookies()
        var cookies: [(String, String)] = [
            ("SESSDATA", sessData),
            ("bili_jct", biliJct),
            ("DedeUserID", dedeUserID),
        ]
        if let ckMd5 {
            cookies.append(("DedeUserID__ckMd5", ckMd5))
        }

        for (name, value) in cookies {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: ".bilibili.com",
                .path: "/",
                .secure: "TRUE",
                .expires: Date.distantFuture,
            ]
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
        PlayerLog.log("[Auth] Cookies synced to HTTPCookieStorage")
    }

    /// Picks the auth cookies out of a jar snapshot that may hold BOTH
    /// the active account's cookies and a fresh login's server-set ones
    /// (Add Account runs while another account is live, and the jar can
    /// carry variant duplicates of the same name). When a name appears
    /// more than once, prefer a value that is NOT the active account's —
    /// the point of the capture is the NEW session. Re-logging into the
    /// SAME account still works: its values only collide when identical,
    /// and the fallback takes them.
    ///
    /// ckMd5 does not get a new Set-Cookie on every SMS/password login, so
    /// a single remaining value is the PREVIOUS account's, not "the new
    /// session". Pairing that hash with a different DedeUserID fails
    /// nav/myinfo. nil means unknown: the caller deletes the cookie
    /// (absent passes, mismatched fails). Same-UID re-login keeps it; a
    /// distinct new ckMd5 is kept as picked.
    static func captureLoginCookies(from cookies: [HTTPCookie]) -> CapturedLoginCookies {
        var byName: [String: [String]] = [:]
        for cookie in cookies {
            byName[cookie.name, default: []].append(cookie.value)
        }
        func pick(_ name: String, avoiding active: String?) -> String? {
            guard let values = byName[name], !values.isEmpty else { return nil }
            if values.count > 1, let active,
               let fresh = values.last(where: { $0 != active }) {
                return fresh
            }
            return values.last
        }
        let active = AuthManager.shared
        let dedeUserID = pick("DedeUserID", avoiding: active.dedeUserID)
        var ckMd5 = pick("DedeUserID__ckMd5", avoiding: active.ckMd5)
        if let dedeUserID, dedeUserID != active.dedeUserID,
           let capturedCkMd5 = ckMd5, capturedCkMd5 == active.ckMd5 {
            ckMd5 = nil
        }
        return CapturedLoginCookies(
            sessData: pick("SESSDATA", avoiding: active.sessData),
            biliJct: pick("bili_jct", avoiding: active.biliJct),
            dedeUserID: dedeUserID,
            ckMd5: ckMd5
        )
    }

    private func clearCookies() {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return }
        for cookie in cookies where cookie.domain.contains("bilibili.com") {
            if ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(cookie.name) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }
}
