import Foundation
import CryptoKit

struct WBISignerInFlightPolicy: Sendable {
    struct ProducerToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    enum Decision: Equatable, Sendable {
        case waiterCancelled
        case start(ProducerToken)
        case join(ProducerToken)
    }

    private(set) var nextID: UInt64 = 0
    private(set) var producer: ProducerToken?

    mutating func request(waiterIsCancelled: Bool) -> Decision {
        guard !waiterIsCancelled else { return .waiterCancelled }
        if let producer { return .join(producer) }
        nextID &+= 1
        let token = ProducerToken(id: nextID)
        producer = token
        return .start(token)
    }

    mutating func finish(_ token: ProducerToken) {
        guard producer == token else { return }
        producer = nil
    }
}

actor WBISigner {
    static let shared = WBISigner()

    private var generation: UInt64 = 0
    private var mixinKey: String?
    private var lastFetchDate: Date?
    private var inflightFetch: (
        token: WBISignerInFlightPolicy.ProducerToken,
        task: Task<String, Error>
    )?
    private var inflightPolicy = WBISignerInFlightPolicy()

    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]

    func invalidate() {
        generation &+= 1
        mixinKey = nil
        lastFetchDate = nil
        if let inflight = inflightFetch {
            inflightPolicy.finish(inflight.token)
            inflightFetch = nil
        }
        PlayerLog.log("[WBI] mixin key invalidated")
    }

    func sign(params: [String: String]) async throws -> [String: String] {
        let key = try await getMixinKey()
        var mutableParams = params
        let wts = String(Int(Date().timeIntervalSince1970))
        mutableParams["wts"] = wts

        let filteredCharacters = CharacterSet(charactersIn: "!'()*")
        let canonicalParams = mutableParams.mapValues {
            $0.components(separatedBy: filteredCharacters).joined()
        }
        let sortedQuery = BiliQueryEncoding.encode(canonicalParams)

        let toSign = sortedQuery + key
        let digest = Insecure.MD5.hash(data: Data(toSign.utf8))
        let wRid = digest.map { String(format: "%02x", $0) }.joined()

        mutableParams["w_rid"] = wRid
        return mutableParams
    }

    private func getMixinKey() async throws -> String {
        if let key = mixinKey,
           let date = lastFetchDate,
           Date().timeIntervalSince(date) < 3600 {
            return key
        }

        let decision = inflightPolicy.request(waiterIsCancelled: Task.isCancelled)
        let producerToken: WBISignerInFlightPolicy.ProducerToken
        switch decision {
        case .waiterCancelled:
            throw CancellationError()
        case .join(let token):
            guard let inflight = inflightFetch, inflight.token == token else {
                inflightPolicy.finish(token)
                return try await getMixinKey()
            }
            let key = try await inflight.task.value
            try Task.checkCancellation()
            return key
        case .start(let token):
            producerToken = token
        }

        let fetchGeneration = generation
        PlayerLog.log("[WBI] mixin key cold — fetching nav (blocking this signed request)")
        let fetch = Task.detached(priority: nil) { () throws -> String in
            let data = try await BiliAPIClient.shared.requestRaw(
                BiliEndpoint(path: "/x/web-interface/nav", signType: .none)
            )
            return try Self.decodeMixinKey(from: data)
        }
        inflightFetch = (token: producerToken, task: fetch)
        let key: String
        do {
            key = try await fetch.value
        } catch {
            inflightPolicy.finish(producerToken)
            if inflightFetch?.token == producerToken {
                inflightFetch = nil
            }
            throw error
        }
        if generation == fetchGeneration {
            mixinKey = key
            lastFetchDate = Date()
        }
        inflightPolicy.finish(producerToken)
        if inflightFetch?.token == producerToken {
            inflightFetch = nil
        }
        try Task.checkCancellation()
        return key
    }

    private nonisolated static func decodeMixinKey(from data: Data) throws -> String {
        let wrapper = try JSONDecoder().decode(BiliResponse<NavResponse>.self, from: data)
        guard let nav = wrapper.data else {
            throw BiliError.apiError(code: wrapper.code, message: wrapper.message)
        }

        let imgKey = extractKey(from: nav.wbiImg.imgUrl)
        let subKey = extractKey(from: nav.wbiImg.subUrl)
        let raw = imgKey + subKey
        let requiredLength = (mixinKeyEncTab.prefix(32).max() ?? 0) + 1
        guard raw.count >= requiredLength else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid WBI key material")
            )
        }
        return String(
            mixinKeyEncTab.prefix(32).map { raw[raw.index(raw.startIndex, offsetBy: $0)] }
        )
    }

    private nonisolated static func extractKey(from url: String) -> String {
        let filename = URL(string: url)?.deletingPathExtension().lastPathComponent ?? ""
        return filename
    }
}

struct NavResponse: Decodable {
    let wbiImg: WbiImg

    struct WbiImg: Decodable {
        let imgUrl: String
        let subUrl: String

        enum CodingKeys: String, CodingKey {
            case imgUrl = "img_url"
            case subUrl = "sub_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case wbiImg = "wbi_img"
    }
}
