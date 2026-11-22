import Foundation

enum AuthAPI {
    private static let passportBase = "https://passport.bilibili.com"

    // MARK: - Captcha

    static func getCaptcha() async throws(BiliError) -> CaptchaResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/passport-login/captcha",
                params: ["source": "main_web"],
                signType: .none,
                baseURL: passportBase
            ),
            type: CaptchaResult.self
        )
    }

    // MARK: - SMS Login

    static func sendSMS(
        cid: Int,
        tel: String,
        captcha: CaptchaValidation
    ) async throws(BiliError) -> SMSSendResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/passport-login/web/sms/send",
                method: .post,
                params: [
                    "cid": String(cid),
                    "tel": tel,
                    "source": "main_web",
                    "token": captcha.token,
                    "challenge": captcha.challenge,
                    "validate": captcha.validate,
                    "seccode": captcha.seccode,
                ],
                signType: .none,
                baseURL: passportBase
            ),
            type: SMSSendResult.self
        )
    }

    static func loginWithSMS(
        cid: Int,
        tel: String,
        code: String,
        captchaKey: String
    ) async throws(BiliError) -> LoginResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/passport-login/web/login/sms",
                method: .post,
                params: [
                    "cid": String(cid),
                    "tel": tel,
                    "code": code,
                    "source": "main_web",
                    "captcha_key": captchaKey,
                    "keep": "true",
                ],
                signType: .none,
                baseURL: passportBase
            ),
            type: LoginResult.self
        )
    }

    // MARK: - Password Login

    static func getRSAKey() async throws(BiliError) -> RSAKeyResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/passport-login/web/key",
                signType: .none,
                baseURL: passportBase
            ),
            type: RSAKeyResult.self
        )
    }

    static func loginWithPassword(
        username: String,
        encryptedPassword: String,
        captcha: CaptchaValidation
    ) async throws(BiliError) -> LoginResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/passport-login/web/login",
                method: .post,
                params: [
                    "username": username,
                    "password": encryptedPassword,
                    "keep": "0",
                    "source": "main_web",
                    "token": captcha.token,
                    "challenge": captcha.challenge,
                    "validate": captcha.validate,
                    "seccode": captcha.seccode,
                ],
                signType: .none,
                baseURL: passportBase
            ),
            type: LoginResult.self
        )
    }

    // MARK: - Country Codes

    static func getCountryCodes() async throws(BiliError) -> CountryCodeResult {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/web/generic/country/list",
                signType: .none,
                baseURL: passportBase
            ),
            type: CountryCodeResult.self
        )
    }
}

// MARK: - Models

struct CaptchaResult: Decodable, Sendable {
    let token: String
    let geetest: GeetestInfo

    struct GeetestInfo: Decodable, Sendable {
        let challenge: String
        let gt: String
    }
}

struct CaptchaValidation: Sendable {
    let token: String
    let challenge: String
    let validate: String
    var seccode: String { "\(validate)|jordan" }
}

struct SMSSendResult: Decodable, Sendable {
    let captchaKey: String

    enum CodingKeys: String, CodingKey {
        case captchaKey = "captcha_key"
    }
}

struct LoginResult: Decodable, Sendable {
    let status: Int?
    let url: String?
    let refreshToken: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, url, message
        case refreshToken = "refresh_token"
    }
}

struct RSAKeyResult: Decodable, Sendable {
    let hash: String
    let key: String
}

struct CountryCodeResult: Decodable, Sendable {
    let common: [CountryCode]?
    let others: [CountryCode]?

    struct CountryCode: Decodable, Sendable, Identifiable {
        let id: Int
        let cname: String
        let countryId: String

        var displayName: String { "\(cname) +\(countryId)" }

        enum CodingKeys: String, CodingKey {
            case id, cname
            case countryId = "country_id"
        }
    }
}

extension AuthAPI {
    static func sessionIdentity() async throws(BiliError) -> SessionIdentity {
        do {
            return try await BiliAPIClient.shared.request(
                BiliEndpoint(path: "/x/web-interface/nav", signType: .none),
                type: SessionIdentity.self
            )
        } catch {
            if case .apiError(let code, _) = error, code == -101 {
                return SessionIdentity(isLogin: false, mid: nil)
            }
            throw error
        }
    }
}

struct SessionIdentity: Decodable, Sendable {
    let isLogin: Bool
    let mid: Int?
}
