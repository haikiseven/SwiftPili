import Foundation

enum VoteAPI {
    static func getInfo(voteId: Int) async throws(BiliError) -> VoteInfo {
        do {
            let result = try await BiliAPIClient.shared.request(
                BiliEndpoint(
                    path: "/vote_svr/v1/vote_svr/vote_info",
                    params: ["vote_id": String(voteId)],
                    baseURL: "https://api.vc.bilibili.com"
                ),
                type: VoteInfoResult.self
            )
            if let info = result.info { return info }
            PlayerLog.log("[Vote] vote_svr info for \(voteId) decoded but carried no payload — trying polymer")
        } catch {
            if case .apiError = error { throw error }
            PlayerLog.log("[Vote] vote_svr info transport failure for \(voteId): \(error) — trying polymer")
        }

        let fallback = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/dynamic/feed/vote/info",
                params: ["vote_id": String(voteId)]
            ),
            type: VoteInfoResult.self
        )
        guard let info = fallback.info else {
            PlayerLog.log("[Vote] ⚠️ polymer info for \(voteId) ALSO carried no payload")
            throw BiliError.apiError(code: -1, message: "vote info empty on both endpoints")
        }
        return info
    }

    static func vote(voteId: Int, choices: [Int]) async throws(BiliError) {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        let votes = choices.sorted().map(String.init).joined(separator: ",")
        do {
            _ = try await BiliAPIClient.shared.request(
                BiliEndpoint(
                    path: "/vote_svr/v1/vote_svr/do_vote",
                    method: .post,
                    params: ["vote_id": String(voteId), "votes": votes, "csrf": csrf],
                    baseURL: "https://api.vc.bilibili.com"
                ),
                type: EmptyResult.self
            )
            PlayerLog.log("[Vote] vote_svr do_vote OK: vote \(voteId) → [\(votes)]")
        } catch {
            PlayerLog.log("[Vote] ⚠️ do_vote refused for \(voteId) choices=[\(votes)]: \(error)")
            throw error
        }
    }
}

struct VoteInfoResult: Decodable, Sendable {
    let info: VoteInfo?

    enum CodingKeys: String, CodingKey {
        case info
        case voteInfo = "vote_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = (try? container.decodeIfPresent(VoteInfo.self, forKey: .info))
            ?? (try? container.decodeIfPresent(VoteInfo.self, forKey: .voteInfo))
            ?? nil
    }
}

struct VoteInfo: Decodable, Sendable {
    let voteId: Int
    let title: String?
    let desc: String?
    let joinNum: Int?
    let endTime: Int?
    let choiceCnt: Int?
    let status: Int?
    let options: [VoteOption]
    let myVotes: [Int]

    struct VoteOption: Decodable, Sendable, Identifiable {
        let idx: Int
        let desc: String?
        let cnt: Int?
        let imgUrl: String?

        var id: Int { idx }

        enum CodingKeys: String, CodingKey {
            case idx, desc, cnt
            case optIdx = "opt_idx"
            case optDesc = "opt_desc"
            case imgUrl = "img_url"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let index = (try? container.decodeIfPresent(Int.self, forKey: .optIdx))
                ?? (try? container.decodeIfPresent(Int.self, forKey: .idx)) else {
                PlayerLog.log("[Vote] ⚠️ option without an index — payload keys drifted again")
                throw DecodingError.keyNotFound(
                    CodingKeys.idx,
                    .init(codingPath: decoder.codingPath, debugDescription: "no idx/opt_idx")
                )
            }
            idx = index
            desc = (try? container.decodeIfPresent(String.self, forKey: .optDesc))
                ?? (try? container.decodeIfPresent(String.self, forKey: .desc))
                ?? nil
            cnt = (try? container.decodeIfPresent(Int.self, forKey: .cnt)) ?? nil
            imgUrl = (try? container.decodeIfPresent(String.self, forKey: .imgUrl)) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, desc, status, options, cnt
        case voteId = "vote_id"
        case id
        case joinNum = "join_num"
        case joinCount = "join_count"
        case endTime = "end_time"
        case choiceCnt = "choice_cnt"
        case myVotes = "my_votes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let vid = (try? container.decodeIfPresent(Int.self, forKey: .voteId))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .id)) else {
            PlayerLog.log("[Vote] ⚠️ poll without vote_id/id — cannot render")
            throw DecodingError.keyNotFound(
                CodingKeys.voteId,
                .init(codingPath: decoder.codingPath, debugDescription: "no vote_id/id")
            )
        }
        voteId = vid
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        desc = (try? container.decodeIfPresent(String.self, forKey: .desc)) ?? nil
        joinNum = (try? container.decodeIfPresent(Int.self, forKey: .joinNum))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .joinCount))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .cnt))
            ?? nil
        endTime = (try? container.decodeIfPresent(Int.self, forKey: .endTime)) ?? nil
        choiceCnt = (try? container.decodeIfPresent(Int.self, forKey: .choiceCnt)) ?? nil
        status = (try? container.decodeIfPresent(Int.self, forKey: .status)) ?? nil
        options = (try? container.decodeIfPresent([LossyOption].self, forKey: .options))?.compactMap(\.option) ?? []
        myVotes = (try? container.decodeIfPresent([Int].self, forKey: .myVotes)) ?? []
        if options.isEmpty {
            PlayerLog.log("[Vote] ⚠️ poll \(vid) decoded with ZERO options — raw payload shape unexpected")
        }
    }

    private struct LossyOption: Decodable {
        let option: VoteOption?

        init(from decoder: Decoder) throws {
            option = try? VoteOption(from: decoder)
        }
    }
}
