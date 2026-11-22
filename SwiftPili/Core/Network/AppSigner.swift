import Foundation
import CryptoKit

actor AppSigner {
    static let shared = AppSigner()

    private let appKey = "dfca71928277209b"
    private let appSec = "b5475a8825547a4fc26c7d518eaaa02e"

    func sign(params: [String: String]) async throws -> [String: String] {
        var mutableParams = params
        mutableParams["appkey"] = appKey
        mutableParams["ts"] = String(Int(Date().timeIntervalSince1970))

        let sortedQuery = mutableParams.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        let toSign = sortedQuery + appSec
        let digest = Insecure.MD5.hash(data: Data(toSign.utf8))
        let sign = digest.map { String(format: "%02x", $0) }.joined()

        mutableParams["sign"] = sign
        return mutableParams
    }
}
