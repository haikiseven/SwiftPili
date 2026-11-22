import Foundation
import Observation

@MainActor
enum LoginCookieCommit {
    static func apply(loginSuccess: inout Bool, errorMessage: inout String?) {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://passport.bilibili.com")!) else {
            errorMessage = String(localized: "Login succeeded but cookies not found")
            return
        }

        let captured = AuthManager.captureLoginCookies(from: cookies)

        if let sessData = captured.sessData, let biliJct = captured.biliJct,
           let dedeUserID = captured.dedeUserID {
            AuthManager.shared.loginWithCookies(
                sessData: sessData,
                biliJct: biliJct,
                dedeUserID: dedeUserID,
                ckMd5: captured.ckMd5
            )
            loginSuccess = true
        } else {
            errorMessage = String(localized: "Missing credentials in cookies")
        }
    }
}

@MainActor
@Observable
final class PasswordLoginViewModel {
    var username = ""
    var password = ""
    var isLoading = false
    var errorMessage: String?
    var loginSuccess = false

    var needsCaptcha = false
    var captchaGT = ""
    var captchaChallenge = ""
    var captchaToken = ""

    func requestCaptcha() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await AuthAPI.getCaptcha()
            captchaGT = result.geetest.gt
            captchaChallenge = result.geetest.challenge
            captchaToken = result.token
            needsCaptcha = true
        } catch {
            errorMessage = "\(error)"
            PlayerLog.log("[PasswordLogin] getCaptcha failed: \(error)")
        }

        isLoading = false
    }

    func login(captcha: CaptchaValidation) async {
        needsCaptcha = false
        isLoading = true
        errorMessage = nil

        do {
            let rsaKey = try await AuthAPI.getRSAKey()

            guard let encrypted = RSAEncryptor.encrypt(
                password: password,
                salt: rsaKey.hash,
                publicKeyPEM: rsaKey.key
            ) else {
                errorMessage = String(localized: "Password encryption failed")
                isLoading = false
                return
            }

            _ = try await AuthAPI.loginWithPassword(
                username: username,
                encryptedPassword: encrypted,
                captcha: captcha
            )
            LoginCookieCommit.apply(loginSuccess: &loginSuccess, errorMessage: &errorMessage)
        } catch {
            errorMessage = "\(error)"
            PlayerLog.log("[PasswordLogin] login failed: \(error)")
        }

        isLoading = false
    }
}
