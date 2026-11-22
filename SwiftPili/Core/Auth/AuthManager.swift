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

    private let sessionIdentity = OSAllocatedUnfairLock(initialState: UUID())
    var sessionGeneration: UUID { sessionIdentity.withLock { $0 } }

    private let cachedDedeUserID = OSAllocatedUnfairLock<String??>(initialState: nil)

    var sessData: String? { KeychainService.get(key: "SESSDATA") }
    var biliJct: String? { KeychainService.get(key: "bili_jct") }
    var dedeUserID: String? {
        cachedDedeUserID.withLock { box in
            if let cached = box { return cached }
            let stored = KeychainService.get(key: "DedeUserID")
            if let stored { box = .some(stored) }
            return stored
        }
    }

    var ckMd5: String? { KeychainService.get(key: "DedeUserID__ckMd5") }

    private func cacheDedeUserID(_ value: String?) {
        cachedDedeUserID.withLock { $0 = .some(value) }
    }

    private init() {
        isLoggedIn = KeychainService.get(key: "SESSDATA") != nil
        restoreCookies()
    }

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
