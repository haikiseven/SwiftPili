import Foundation

/// BiliBili polls (投票), as embedded in comments and dynamic feeds.
///
/// Two API generations serve polls and the public documentation of both
/// is thin, so every call here is belt-and-suspenders: the polymer
/// endpoint (api.bilibili.com/x/dynamic/feed/vote/…) is tried first and
/// the legacy vote_svr service (api.vc.bilibili.com) second, with the
/// failure of each leg logged in full — per the field rule of logging
/// loudly wherever the contract is uncertain.
enum VoteAPI {
    /// Full poll state: question, options with counts, my own choices.
    ///
    /// vote_svr first — field logs proved that host is the live poll
    /// service (its do_vote sibling answers business verdicts while the
    /// polymer do path 404s). Polymer stays as a transport-failure
    /// fallback only: a coded apiError is the server's final answer
    /// (deleted poll, restricted account) and is surfaced directly.
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

    /// Cast (or change) a vote. `choices` are option indexes.
    ///
    /// vote_svr only: field logs proved it is THE submit endpoint (it
    /// answers real business verdicts like 260016 年龄限制) while the
    /// polymer /x/dynamic/feed/vote/do path plain 404s — the old
    /// fallback chain replaced meaningful refusals with "HTTP 404".
    /// A coded apiError here is the server's final answer; surface it.
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

/// Envelope: polymer wraps the poll in "info", vote_svr in "vote_info".
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

/// One poll. Decodes BOTH generations' key spellings lossily — a
/// missing decorative field never sinks the card, and every fallback
/// hit is visible in the option/field values themselves.
struct VoteInfo: Decodable, Sendable {
    let voteId: Int
    let title: String?
    let desc: String?
    let joinNum: Int?
    let endTime: Int?
    /// How many options one ballot may pick (1 = single choice).
    let choiceCnt: Int?
    let status: Int?
    let options: [VoteOption]
    /// Option indexes I already voted for; empty = not voted yet.
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
            // polymer: opt_idx/opt_desc; vote_svr: idx/desc.
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

    /// One bad option must not sink its siblings.
    private struct LossyOption: Decodable {
        let option: VoteOption?

        init(from decoder: Decoder) throws {
            option = try? VoteOption(from: decoder)
        }
    }
}
