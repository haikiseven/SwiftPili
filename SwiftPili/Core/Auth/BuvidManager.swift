import Foundation
import CryptoKit

enum BuvidManager {
    private static let buvidKey = "buvid3"

    static func ensureBuvid() {
        if getBuvid() == nil {
            let buvid3 = generateBuvid3()
            UserDefaults.standard.set(buvid3, forKey: buvidKey)
            setCookie(name: "buvid3", value: buvid3)
        }
        if UserDefaults.standard.string(forKey: "buvid4") == nil {
            let buvid4 = "\(generateBuvid3())\(Int(Date().timeIntervalSince1970))"
            UserDefaults.standard.set(buvid4, forKey: "buvid4")
            setCookie(name: "buvid4", value: buvid4)
        }
        setCookie(name: "b_nut", value: "100")
    }

    static func getBuvid() -> String? {
        UserDefaults.standard.string(forKey: buvidKey)
    }

    static func syncServerBuvid() async {
        guard !UserDefaults.standard.bool(forKey: "buvid_server_issued") else { return }

        struct Wrapper: Decodable {
            let code: Int
            let data: SpiData?

            struct SpiData: Decodable {
                let b3: String?
                let b4: String?

                enum CodingKeys: String, CodingKey {
                    case b3 = "b_3"
                    case b4 = "b_4"
                }
            }
        }

        do {
            let data = try await BiliAPIClient.shared.requestRaw(
                BiliEndpoint(path: "/x/frontend/finger/spi")
            )
            let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
            guard wrapper.code == 0, let b3 = wrapper.data?.b3, !b3.isEmpty else {
                PlayerLog.log("[Buvid] finger/spi gave no buvid (code \(wrapper.code))")
                return
            }
            UserDefaults.standard.set(b3, forKey: buvidKey)
            setCookie(name: "buvid3", value: b3)
            if let b4 = wrapper.data?.b4, !b4.isEmpty {
                UserDefaults.standard.set(b4, forKey: "buvid4")
                setCookie(name: "buvid4", value: b4)
            }
            UserDefaults.standard.set(true, forKey: "buvid_server_issued")
            PlayerLog.log("[Buvid] Installed server-issued buvid3 (\(b3.prefix(10))…)")
        } catch {
            PlayerLog.log("[Buvid] finger/spi failed, will retry next launch: \(error)")
        }
    }

    private static func generateBuvid3() -> String {
        let uuid = UUID().uuidString
        return "\(uuid)infoc"
    }

    static func setCookie(name: String, value: String) {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: ".bilibili.com",
            .path: "/",
        ]
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    static func activateBuvid() async {
        guard let buvid = getBuvid() else { return }

        let randomBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let iendMarker: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68]
        let trailBytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
        let payload = Data(randomBytes + iendMarker + trailBytes)
        let randPngEnd = payload.base64EncodedString()
        let suffix = String(randPngEnd.suffix(50))

        let jsonPayload: [String: Any] = [
            "3064": 1,
            "39c8": "333.1387.fp.risk",
            "3c43": [
                "adca": "Linux",
                "bfe9": suffix,
            ],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        do {
            _ = try await BiliAPIClient.shared.requestRaw(
                BiliEndpoint(
                    path: "/x/internal/gaia-gateway/ExClimbWuzhi",
                    method: .post,
                    params: ["payload": jsonString],
                    signType: .none
                )
            )
            PlayerLog.log("[Buvid] Activated buvid: \(buvid)")
        } catch {
            PlayerLog.log("[Buvid] Activation failed (non-critical): \(error)")
        }
    }
}
