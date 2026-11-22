import Foundation
import Observation

@MainActor
@Observable
final class SMSLoginViewModel {
    var phoneNumber = ""
    var countryCode = 86
    var countryName = "中国大陆"
    var smsCode = ""
    var isLoading = false
    var errorMessage: String?
    var codeSent = false
    var cooldown = 0
    var loginSuccess = false

    var needsCaptcha = false
    var captchaGT = ""
    var captchaChallenge = ""
    var captchaToken = ""

    var countryCodes: [CountryCodeResult.CountryCode] = []

    private var captchaKey = ""
    private var cooldownTask: Task<Void, Never>?

    func loadCountryCodes() async {
        do {
            let result = try await AuthAPI.getCountryCodes()
            var all: [CountryCodeResult.CountryCode] = []
            if let common = result.common { all.append(contentsOf: common) }
            if let others = result.others { all.append(contentsOf: others) }
            countryCodes = all
        } catch {
            PlayerLog.log("[SMSLogin] loadCountryCodes failed: \(error)")
        }
    }

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
            PlayerLog.log("[SMSLogin] getCaptcha failed: \(error)")
        }

        isLoading = false
    }

    func sendCode(captcha: CaptchaValidation) async {
        needsCaptcha = false
        isLoading = true
        errorMessage = nil

        PlayerLog.log("[SMSLogin] Sending SMS to +\(countryCode) \(phoneNumber)")
        PlayerLog.log("[SMSLogin] Captcha token=\(captcha.token) validate=\(captcha.validate)")

        do {
            let result = try await AuthAPI.sendSMS(
                cid: countryCode,
                tel: phoneNumber,
                captcha: captcha
            )
            captchaKey = result.captchaKey
            codeSent = true
            PlayerLog.log("[SMSLogin] SMS sent successfully, captchaKey=\(captchaKey)")
            startCooldown()
        } catch {
            errorMessage = "\(error)"
            PlayerLog.log("[SMSLogin] sendSMS failed: \(error)")
        }

        isLoading = false
    }

    func login() async {
        guard !smsCode.isEmpty else {
            errorMessage = String(localized: "Please enter the verification code")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            _ = try await AuthAPI.loginWithSMS(
                cid: countryCode,
                tel: phoneNumber,
                code: smsCode,
                captchaKey: captchaKey
            )
            LoginCookieCommit.apply(loginSuccess: &loginSuccess, errorMessage: &errorMessage)
        } catch {
            errorMessage = "\(error)"
            PlayerLog.log("[SMSLogin] login failed: \(error)")
        }

        isLoading = false
    }

    private func startCooldown() {
        cooldown = 60
        cooldownTask?.cancel()
        cooldownTask = Task {
            while cooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                cooldown -= 1
            }
        }
    }
}
