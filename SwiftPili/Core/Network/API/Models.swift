import CoreGraphics
import Foundation

// MARK: - Video

struct VideoInfo: Decodable, Sendable {
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let desc: String
    let pic: String
    let duration: Int
    let pubdate: Int
    let copyright: Int?
    let dimension: Dimension?
    let owner: VideoOwner
    var stat: VideoStat
    let pages: [VideoPage]?
    let staff: [StaffMember]?
    let ugcSeason: UGCSeason?
    let descV2: [DescV2Node]?
    let descLinks: [String: URL]

    enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, desc, pic, duration, pubdate
        case copyright, dimension, owner, stat, pages, staff
        case ugcSeason = "ugc_season"
        case descV2 = "desc_v2"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aid = try container.decode(Int.self, forKey: .aid)
        bvid = try container.decode(String.self, forKey: .bvid)
        cid = try container.decode(Int.self, forKey: .cid)
        title = try container.decode(String.self, forKey: .title)
        desc = try container.decode(String.self, forKey: .desc)
        pic = try container.decode(String.self, forKey: .pic)
        duration = try container.decode(Int.self, forKey: .duration)
        pubdate = try container.decode(Int.self, forKey: .pubdate)
        copyright = try container.decodeIfPresent(Int.self, forKey: .copyright)
        dimension = try container.decodeIfPresent(Dimension.self, forKey: .dimension)
        owner = try container.decode(VideoOwner.self, forKey: .owner)
        stat = try container.decode(VideoStat.self, forKey: .stat)
        pages = try container.decodeIfPresent([VideoPage].self, forKey: .pages)
        staff = (try? container.decodeIfPresent([StaffMember].self, forKey: .staff)) ?? nil
        ugcSeason = (try? container.decodeIfPresent(UGCSeason.self, forKey: .ugcSeason)) ?? nil
        descV2 = try container.decodeIfPresent([DescV2Node].self, forKey: .descV2)
        descLinks = Self.prepareDescLinks(desc: desc, descV2: descV2)
    }

    struct DescV2Node: Decodable, Sendable {
        let rawText: String
        let type: Int
        let bizId: Int?

        enum CodingKeys: String, CodingKey {
            case rawText = "raw_text"
            case type
            case bizId = "biz_id"
        }
    }

    private static let descLinkDetector: NSRegularExpression? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let descAVRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Aa][Vv]\d{1,12})(?![A-Za-z0-9])"#
    )
    private static let descCVRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Cc][Vv]\d{1,12})(?![A-Za-z0-9])"#
    )
    private static let descSSRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Ss][Ss]\d{1,12})(?![A-Za-z0-9])"#
    )
    private static let descEPRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Ee][Pp]\d{1,12})(?![A-Za-z0-9])"#
    )

    private static func prepareDescLinks(desc: String, descV2: [DescV2Node]?) -> [String: URL] {
        var out: [String: URL] = [:]
        for node in descV2 ?? [] where node.type == 2 {
            if let mid = node.bizId, mid > 0, !node.rawText.isEmpty {
                out["@\(node.rawText)"] = URL(string: "https://space.bilibili.com/\(mid)")
            }
        }
        let ns = desc as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        if let detector = Self.descLinkDetector {
            for match in detector.matches(in: desc, range: fullRange) {
                guard var url = match.url else { continue }
                var literal = ns.substring(with: match.range)
                while let last = literal.last, "。，！？；：】」》）".contains(last) {
                    literal.removeLast()
                }
                guard !literal.isEmpty else { continue }
                if url.scheme?.lowercased() == "http",
                   BiliLinkHostPolicy.isBilibiliHost(url.host) || BiliLinkHostPolicy.isShortener(url.host),
                   var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.scheme = "https"
                    if let upgraded = comps.url { url = upgraded }
                }
                if out[literal] == nil { out[literal] = url }
            }
        }
        for key in desc.bvIDs where out[key] == nil {
            if let bvid = BiliLinkResolver.normalizedBVID(key) {
                out[key] = URL(string: "https://www.bilibili.com/video/\(bvid)")
            }
        }
        if let descAVRegex {
            for match in descAVRegex.matches(in: desc, range: fullRange) {
                let token = ns.substring(with: match.range(at: 1))
                if out[token] == nil,
                   let aid = BiliLinkResolver.parsedAID(token, allowBareNumeric: false) {
                    out[token] = URL(string: "https://www.bilibili.com/video/av\(aid)")
                }
            }
        }
        if let descCVRegex {
            for match in descCVRegex.matches(in: desc, range: fullRange) {
                let token = ns.substring(with: match.range(at: 1))
                if out[token] == nil,
                   let cvid = BiliLinkResolver.parsedPrefixedID(token, prefix: "cv") {
                    out[token] = URL(string: "https://www.bilibili.com/read/cv\(cvid)")
                }
            }
        }
        if let descSSRegex {
            for match in descSSRegex.matches(in: desc, range: fullRange) {
                let token = ns.substring(with: match.range(at: 1))
                if out[token] == nil,
                   let sid = BiliLinkResolver.parsedPrefixedID(token, prefix: "ss") {
                    out[token] = URL(string: "https://www.bilibili.com/bangumi/play/ss\(sid)")
                }
            }
        }
        if let descEPRegex {
            for match in descEPRegex.matches(in: desc, range: fullRange) {
                let token = ns.substring(with: match.range(at: 1))
                if out[token] == nil,
                   let epid = BiliLinkResolver.parsedPrefixedID(token, prefix: "ep") {
                    out[token] = URL(string: "https://www.bilibili.com/bangumi/play/ep\(epid)")
                }
            }
        }
        for (token, url) in EmoteText.timestampLinks(in: desc) where out[token] == nil {
            out[token] = url
        }
        return out
    }

    struct Dimension: Decodable, Sendable {
        let width: Int
        let height: Int
        let rotate: Int?

        var isPortrait: Bool {
            rotate == 1 ? width > height : height > width
        }

        var effectiveAspectRatio: CGFloat? {
            let effectiveWidth = rotate == 1 ? height : width
            let effectiveHeight = rotate == 1 ? width : height
            guard effectiveWidth > 0, effectiveHeight > 0 else { return nil }
            let ratio = CGFloat(effectiveWidth) / CGFloat(effectiveHeight)
            guard ratio.isFinite, ratio >= 0.15, ratio <= 5.0 else { return nil }
            return ratio
        }
    }

    struct VideoOwner: Decodable, Sendable {
        let mid: Int
        let name: String
        let face: String
    }

    struct VideoStat: Decodable, Sendable {
        var view: Int
        var danmaku: Int
        var reply: Int
        var favorite: Int
        var coin: Int
        var share: Int
        var like: Int
    }

    struct VideoPage: Decodable, Sendable {
        let cid: Int
        let page: Int
        let part: String
        let duration: Int
        let dimension: Dimension?
    }

    struct StaffMember: Decodable, Sendable, Identifiable, Equatable {
        let mid: Int
        let title: String
        let name: String
        let face: String
        let vip: VipInfo?
        let official: OfficialInfo?
        let follower: Int?

        var id: Int { mid }

        struct VipInfo: Decodable, Sendable, Equatable {
            let type: Int?
            let status: Int?
            let label: VipLabel?

            var isActive: Bool { status == 1 }

            struct VipLabel: Decodable, Sendable, Equatable {
                let text: String?
            }
        }

        struct OfficialInfo: Decodable, Sendable, Equatable {
            let role: Int?
            let title: String?
            let desc: String?
            let type: Int?
        }

        enum CodingKeys: String, CodingKey {
            case mid, title, name, face, vip, official, follower
        }

        init(
            mid: Int,
            title: String,
            name: String,
            face: String,
            vip: VipInfo? = nil,
            official: OfficialInfo? = nil,
            follower: Int? = nil
        ) {
            self.mid = mid
            self.title = title
            self.name = name
            self.face = face
            self.vip = vip
            self.official = official
            self.follower = follower
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mid = try container.decode(Int.self, forKey: .mid)
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            face = (try? container.decode(String.self, forKey: .face)) ?? ""
            vip = (try? container.decodeIfPresent(VipInfo.self, forKey: .vip)) ?? nil
            official = (try? container.decodeIfPresent(OfficialInfo.self, forKey: .official)) ?? nil
            follower = (try? container.decodeIfPresent(Int.self, forKey: .follower)) ?? nil
        }
    }

    struct UGCSeason: Decodable, Sendable, Identifiable {
        let id: Int
        let title: String
        let cover: String?
        let intro: String?
        let epCount: Int?
        let sections: [Section]?

        var allEpisodes: [Episode] {
            (sections ?? []).flatMap { $0.episodes ?? [] }
        }

        var totalEpisodeCount: Int {
            let flattened = allEpisodes.count
            if let epCount, epCount > 0 { return max(epCount, flattened) }
            return flattened
        }

        enum CodingKeys: String, CodingKey {
            case id, title, cover, intro, sections
            case epCount = "ep_count"
        }

        struct Section: Decodable, Sendable, Identifiable {
            let id: Int
            let title: String
            let episodes: [Episode]?

            enum CodingKeys: String, CodingKey {
                case id, title, episodes
            }

            init(id: Int, title: String, episodes: [Episode]?) {
                self.id = id
                self.title = title
                self.episodes = episodes
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? container.decode(Int.self, forKey: .id)) ?? 0
                title = (try? container.decode(String.self, forKey: .title)) ?? ""
                episodes = (try? container.decodeIfPresent([Episode].self, forKey: .episodes)) ?? nil
            }
        }

        struct Episode: Decodable, Sendable, Identifiable {
            let id: Int
            let aid: Int
            let bvid: String?
            let cid: Int
            let title: String
            let arc: Archive?
            let page: VideoPage?

            var displayTitle: String {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                return arc?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            var durationSeconds: Int? {
                arc?.duration ?? page?.duration
            }

            var coverURL: String? {
                arc?.pic
            }

            var videoID: VideoID {
                if let bvid, !bvid.isEmpty { return .bvid(bvid) }
                return .aid(aid)
            }

            struct Archive: Decodable, Sendable {
                let pic: String?
                let title: String?
                let duration: Int?
                let pubdate: Int?
                let stat: Stat?

                struct Stat: Decodable, Sendable {
                    let view: Int?
                    let danmaku: Int?
                    let reply: Int?
                    let favorite: Int?
                    let coin: Int?
                    let share: Int?
                    let like: Int?
                }
            }

            enum CodingKeys: String, CodingKey {
                case id, aid, bvid, cid, title, arc, page
            }

            init(
                id: Int,
                aid: Int,
                bvid: String? = nil,
                cid: Int,
                title: String,
                arc: Archive? = nil,
                page: VideoPage? = nil
            ) {
                self.id = id
                self.aid = aid
                self.bvid = bvid
                self.cid = cid
                self.title = title
                self.arc = arc
                self.page = page
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? container.decode(Int.self, forKey: .id)) ?? 0
                aid = (try? container.decode(Int.self, forKey: .aid)) ?? 0
                bvid = (try? container.decodeIfPresent(String.self, forKey: .bvid)) ?? nil
                cid = (try? container.decode(Int.self, forKey: .cid)) ?? 0
                title = (try? container.decode(String.self, forKey: .title)) ?? ""
                arc = (try? container.decodeIfPresent(Archive.self, forKey: .arc)) ?? nil
                page = (try? container.decodeIfPresent(VideoPage.self, forKey: .page)) ?? nil
            }
        }
    }
}

struct VideoTag: Decodable, Sendable, Identifiable {
    let tagId: Int
    let tagName: String
    let tagType: String?
    let musicId: String?
    let jumpUrl: String?

    var id: String { tagId != 0 ? "t\(tagId)" : "m\(musicId ?? tagName)" }
    var isMusic: Bool { tagType == "bgm" || (musicId?.isEmpty == false) }

    enum CodingKeys: String, CodingKey {
        case tagId = "tag_id"
        case tagName = "tag_name"
        case tagType = "tag_type"
        case musicId = "music_id"
        case jumpUrl = "jump_url"
    }
}

struct OnlineTotalResult: Decodable, Sendable {
    let total: String?
    let count: String?
}

struct PlayerV2Info: Decodable, Sendable {
    let lastPlayTime: Int?
    let lastPlayCid: Int?
    let subtitle: SubtitleBox?
    let viewPoints: [ViewPoint]?
    let dmMask: DanmakuMaskInfo?

    struct ViewPoint: Decodable, Sendable, Equatable {
        let from: Double?
        let to: Double?
        let imgURL: String?
        let content: String?

        init(from: Double?, to: Double?, imgURL: String?, content: String? = nil) {
            self.from = from
            self.to = to
            self.imgURL = imgURL
            self.content = content
        }

        private enum CodingKeys: String, CodingKey {
            case from
            case to
            case content
            case title
            case fromTime = "from_time"
            case toTime = "to_time"
            case imgURL = "imgUrl"
            case imgURLSnake = "img_url"
            case imageURL = "imageUrl"
            case imageURLSnake = "image_url"
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                from = nil
                to = nil
                imgURL = nil
                content = nil
                return
            }
            from = Self.decodeDouble(
                in: container,
                keys: [.from, .fromTime]
            )
            to = Self.decodeDouble(
                in: container,
                keys: [.to, .toTime]
            )
            imgURL = Self.decodeString(
                in: container,
                keys: [.imgURL, .imgURLSnake, .imageURL, .imageURLSnake]
            )
            let rawContent = Self.decodeString(
                in: container,
                keys: [.content, .title]
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            content = rawContent.flatMap { $0.isEmpty ? nil : $0 }
        }

        private static func decodeDouble(
            in container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Double? {
            for key in keys {
                if let value = try? container.decode(Double.self, forKey: key) {
                    return value
                }
                if let value = try? container.decode(String.self, forKey: key),
                   let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            }
            return nil
        }

        private static func decodeString(
            in container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> String? {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: key) {
                    return value
                }
            }
            return nil
        }
    }

    struct SubtitleBox: Decodable, Sendable {
        let subtitles: [SubtitleItem]?

        struct SubtitleItem: Decodable, Sendable, Equatable {
            let id: Int64?
            let idStr: String?
            let lan: String?
            let lanDoc: String?
            let subtitleUrl: String?
            let aiType: Int?
            let aiStatus: Int?

            var isAIGenerated: Bool {
                (aiType ?? 0) > 0 || (lan?.hasPrefix("ai-") == true)
            }

            var displayTitle: String {
                let trimmed = lanDoc?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    return trimmed
                }
                return lan ?? "?"
            }

            var menuDisplayTitle: String {
                let base = displayTitle
                if isAIGenerated, !base.localizedCaseInsensitiveContains("AI") {
                    return "\(base) (AI)"
                }
                return base
            }

            init(
                lan: String?,
                lanDoc: String?,
                subtitleUrl: String?,
                id: Int64? = nil,
                idStr: String? = nil,
                aiType: Int? = nil,
                aiStatus: Int? = nil
            ) {
                self.id = id
                self.idStr = idStr
                self.lan = lan
                self.lanDoc = lanDoc
                self.subtitleUrl = subtitleUrl
                self.aiType = aiType
                self.aiStatus = aiStatus
            }

            enum CodingKeys: String, CodingKey {
                case id
                case idStr = "id_str"
                case lan
                case lanDoc = "lan_doc"
                case subtitleUrl = "subtitle_url"
                case subtitleUrlV2 = "subtitle_url_v2"
                case aiType = "ai_type"
                case aiStatus = "ai_status"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let decodedID = try? container.decodeIfPresent(Int64.self, forKey: .id) {
                    id = decodedID
                } else if let decodedIDString = try? container.decodeIfPresent(String.self, forKey: .id),
                          let parsedID = Int64(decodedIDString) {
                    id = parsedID
                } else {
                    id = nil
                }
                idStr = try? container.decodeIfPresent(String.self, forKey: .idStr)
                lan = try container.decodeIfPresent(String.self, forKey: .lan)
                lanDoc = try container.decodeIfPresent(String.self, forKey: .lanDoc)
                let primaryURL = (try? container.decodeIfPresent(String.self, forKey: .subtitleUrl))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackURL = (try? container.decodeIfPresent(String.self, forKey: .subtitleUrlV2))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let primaryURL, !primaryURL.isEmpty {
                    subtitleUrl = primaryURL
                } else if let fallbackURL, !fallbackURL.isEmpty {
                    subtitleUrl = fallbackURL
                } else {
                    subtitleUrl = nil
                }
                aiType = try? container.decodeIfPresent(Int.self, forKey: .aiType)
                aiStatus = try? container.decodeIfPresent(Int.self, forKey: .aiStatus)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case subtitle
        case lastPlayTime = "last_play_time"
        case lastPlayCid = "last_play_cid"
        case viewPoints = "view_points"
        case dmMask = "dm_mask"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastPlayTime = try container.decodeIfPresent(Int.self, forKey: .lastPlayTime)
        lastPlayCid = try container.decodeIfPresent(Int.self, forKey: .lastPlayCid)
        subtitle = try container.decodeIfPresent(SubtitleBox.self, forKey: .subtitle)
        dmMask = (try? container.decodeIfPresent(DanmakuMaskInfo.self, forKey: .dmMask)) ?? nil

        guard var points = try? container.nestedUnkeyedContainer(forKey: .viewPoints) else {
            viewPoints = nil
            return
        }
        var decoded: [ViewPoint] = []
        while !points.isAtEnd {
            guard let pointDecoder = try? points.superDecoder(),
                  let point = try? ViewPoint(from: pointDecoder) else {
                continue
            }
            decoded.append(point)
        }
        viewPoints = decoded
    }
}

enum MobileCoverSelection {
    static func firstUsable(_ candidates: String?...) -> String? {
        candidates
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct VideoCard: Decodable, Sendable, Identifiable {
    let aid: Int
    let bvid: String
    let title: String
    let pic: String
    let cover43: String?
    let duration: Int
    let dimension: VideoInfo.Dimension?
    let owner: VideoInfo.VideoOwner
    let stat: VideoInfo.VideoStat

    var id: Int { aid }

    var mobileCoverURL: String? { MobileCoverSelection.firstUsable(cover43) }
}

struct PlayURLResult: Decodable, Sendable {
    let quality: Int
    let qualitySource: QualitySource
    let acceptQuality: [Int]?
    let dash: DashInfo?
    let durl: [DurlInfo]?

    enum QualitySource: Equatable, Sendable {
        case explicit
        case dashAcceptQuality
        case dashStreamID
        case durlAcceptQuality
        case legacyDurlCompatibility
    }

    private static let legacyDurlCompatibilityQuality = 80

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitQuality = try container.decodeIfPresent(Int.self, forKey: .quality)
        let acceptQuality = try container.decodeIfPresent([Int].self, forKey: .acceptQuality)
        let dash = try container.decodeIfPresent(DashInfo.self, forKey: .dash)
        let durl = try container.decodeIfPresent([DurlInfo].self, forKey: .durl)
        let clipInfo = try container.decodeIfPresent([ClipInfo].self, forKey: .clipInfo)

        let playableDashVideo = dash?.video.filter { stream in
            stream.allURLs.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        } ?? []
        let hasPlayableDurl = durl?.contains {
            !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false

        let hasPositiveExplicitQuality = explicitQuality.map { $0 > 0 } == true
        guard hasPositiveExplicitQuality
            || !playableDashVideo.isEmpty
            || hasPlayableDurl
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .quality,
                in: container,
                debugDescription: "PlayURLResult has no playable DASH video or durl stream"
            )
        }

        let positiveAcceptQuality = (acceptQuality ?? []).filter { $0 > 0 }
        let playableDashQualityIDs = Set(
            playableDashVideo.map(\.id).filter { $0 > 0 }
        )
        let dashAcceptQuality = positiveAcceptQuality.first {
            playableDashQualityIDs.contains($0)
        }
        let qualityResolution: (quality: Int, source: QualitySource)? = {
            if let explicitQuality, explicitQuality > 0 {
                return (explicitQuality, .explicit)
            }
            if let dashAcceptQuality {
                return (dashAcceptQuality, .dashAcceptQuality)
            }
            if let dashQuality = playableDashQualityIDs.max() {
                return (dashQuality, .dashStreamID)
            }
            if hasPlayableDurl, let durlAcceptQuality = positiveAcceptQuality.first {
                return (durlAcceptQuality, .durlAcceptQuality)
            }
            guard hasPlayableDurl else { return nil }
            return (Self.legacyDurlCompatibilityQuality, .legacyDurlCompatibility)
        }()

        guard let qualityResolution else {
            throw DecodingError.dataCorruptedError(
                forKey: .quality,
                in: container,
                debugDescription: "PlayURLResult has no usable quality for its playable stream"
            )
        }

        self.quality = qualityResolution.quality
        self.qualitySource = qualityResolution.source
        self.acceptQuality = acceptQuality
        self.dash = dash
        self.durl = durl
        self.clipInfo = clipInfo
    }

    struct DashInfo: Decodable, Sendable {
        let duration: Int?
        let video: [DashStream]
        let audio: [DashStream]?
        let flac: FlacInfo?

        struct DashStream: Decodable, Sendable {
            let id: Int
            let baseUrl: String
            let backupUrl: [String]?
            let bandwidth: Int
            let codecs: String
            let mimeType: String

            var allURLs: [String] {
                [baseUrl] + (backupUrl ?? [])
            }

            enum CodingKeys: String, CodingKey {
                case id, bandwidth, codecs
                case baseUrl = "base_url"
                case backupUrl = "backup_url"
                case mimeType = "mime_type"
            }
        }
    }

    struct DurlInfo: Decodable, Sendable {
        let url: String
        let length: Int
        let size: Int
        let order: Int
    }

    let clipInfo: [ClipInfo]?

    struct ClipInfo: Decodable, Sendable {
        let clipType: String?
        let start: Int?
        let end: Int?

        enum CodingKeys: String, CodingKey {
            case start, end
            case clipType = "clip_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case quality
        case acceptQuality = "accept_quality"
        case dash
        case durl
        case clipInfo = "clip_info"
    }
}

// MARK: - Live

struct LiveAnchorInfo: Decodable, Sendable {
    let uid: Int
    let uname: String
    let face: String

    private enum RootKeys: String, CodingKey { case info }
    private enum InfoKeys: String, CodingKey { case uid, uname, face }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let info = try root.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)
        uid = (try? info.decode(Int.self, forKey: .uid)) ?? 0
        uname = (try? info.decode(String.self, forKey: .uname)) ?? ""
        face = (try? info.decode(String.self, forKey: .face)) ?? ""
    }
}

struct LiveRoomInfo: Decodable, Sendable {
    let roomId: Int
    let uid: Int
    let title: String
    let liveStatus: Int
    let areaName: String
    let parentAreaName: String
    let keyframe: String
    let online: Int
    let userCover: String
    let isPortrait: Bool

    enum CodingKeys: String, CodingKey {
        case uid, title, online, keyframe
        case roomId = "room_id"
        case liveStatus = "live_status"
        case areaName = "area_name"
        case parentAreaName = "parent_area_name"
        case userCover = "user_cover"
        case isPortrait = "is_portrait"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomId = (try? container.decode(Int.self, forKey: .roomId)) ?? 0
        uid = (try? container.decode(Int.self, forKey: .uid)) ?? 0
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        liveStatus = (try? container.decode(Int.self, forKey: .liveStatus)) ?? 0
        areaName = (try? container.decode(String.self, forKey: .areaName)) ?? ""
        parentAreaName = (try? container.decode(String.self, forKey: .parentAreaName)) ?? ""
        keyframe = (try? container.decode(String.self, forKey: .keyframe)) ?? ""
        online = (try? container.decode(Int.self, forKey: .online)) ?? 0
        userCover = (try? container.decode(String.self, forKey: .userCover)) ?? ""
        isPortrait = (try? container.decode(Bool.self, forKey: .isPortrait)) ?? false
    }

    func coverURL(for context: LiveCoverContext) -> String? {
        LiveCoverPolicy.select(
            context: context,
            liveStatus: liveStatus,
            candidates: .init(keyframe: keyframe, userCover: userCover)
        ).url
    }
}

struct LivePlayInfo: Decodable, Sendable {
    let playurlInfo: PlayurlInfo?
    let liveStatus: Int?
    let isPortrait: Bool?

    struct PlayurlInfo: Decodable, Sendable {
        let playurl: Playurl?

        struct Playurl: Decodable, Sendable {
            let stream: [StreamInfo]?
            let gQnDesc: [QnDesc]?

            struct QnDesc: Decodable, Sendable {
                let qn: Int
                let desc: String

                enum CodingKeys: String, CodingKey {
                    case qn, desc
                }
            }

            enum CodingKeys: String, CodingKey {
                case stream
                case gQnDesc = "g_qn_desc"
            }

            struct StreamInfo: Decodable, Sendable {
                let protocolName: String
                let format: [FormatInfo]

                struct FormatInfo: Decodable, Sendable {
                    let formatName: String
                    let codec: [CodecInfo]

                    struct CodecInfo: Decodable, Sendable {
                        let codecName: String
                        let currentQn: Int?
                        let acceptQn: [Int]?
                        let baseUrl: String
                        let urlInfo: [URLInfo]?

                        struct URLInfo: Decodable, Sendable {
                            let host: String
                            let extra: String
                        }

                        enum CodingKeys: String, CodingKey {
                            case codecName = "codec_name"
                            case currentQn = "current_qn"
                            case acceptQn = "accept_qn"
                            case baseUrl = "base_url"
                            case urlInfo = "url_info"
                        }
                    }

                    enum CodingKeys: String, CodingKey {
                        case formatName = "format_name"
                        case codec
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case protocolName = "protocol_name"
                    case format
                }
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case playurlInfo = "playurl_info"
        case liveStatus = "live_status"
        case isPortrait = "is_portrait"
    }

    var hasPlayableStream: Bool {
        guard let streams = playurlInfo?.playurl?.stream, !streams.isEmpty else {
            return false
        }
        return streams.contains { stream in
            stream.format.contains { format in
                format.codec.contains { codec in
                    !(codec.urlInfo ?? []).isEmpty || !codec.baseUrl.isEmpty
                }
            }
        }
    }
}

struct DanmuInfo: Decodable, Sendable {
    let token: String
    let hostList: [HostInfo]?

    struct HostInfo: Decodable, Sendable {
        let host: String
        let port: Int
        let wssPort: Int
        let wsPort: Int

        enum CodingKeys: String, CodingKey {
            case host, port
            case wssPort = "wss_port"
            case wsPort = "ws_port"
        }
    }

    enum CodingKeys: String, CodingKey {
        case token
        case hostList = "host_list"
    }
}

struct SendLiveDanmakuResult: Decodable, Sendable {
    let modeInfo: ModeInfo?

    struct ModeInfo: Decodable, Sendable {
        let extra: String?
    }

    enum CodingKeys: String, CodingKey {
        case modeInfo = "mode_info"
    }
}

struct LiveListResult: Sendable {
    let list: [LiveCard]?
    let hasMore: Int?

    struct LiveCard: Decodable, Sendable, Identifiable {
        let roomid: Int
        let uid: Int?
        let title: String
        let uname: String
        let face: String
        let cover: String?
        let userCover: String?
        let coverFromUser: String?
        let systemCover: String?
        let keyframe: String?
        let areaName: String?
        let online: Int?
        let watchedShow: WatchedShow?
        let liveStatus: Int?

        var id: Int { roomid }

        var coverCandidates: LiveCoverPolicy.Candidates {
            .init(
                keyframe: keyframe,
                userCover: userCover,
                cover: cover,
                coverFromUser: coverFromUser,
                systemCover: systemCover,
                face: face
            )
        }

        var displayCover: String {
            LiveCoverPolicy.select(
                context: .gridCard,
                liveStatus: liveStatus,
                candidates: coverCandidates
            ).url ?? ""
        }
        var displayOnline: String {
            watchedShow?.textLarge ?? watchedShow?.textSmall
                ?? (online.map { FormatUtils.viewCount($0) } ?? "")
        }

        struct WatchedShow: Decodable, Sendable {
            let textLarge: String?
            let textSmall: String?

            enum CodingKeys: String, CodingKey {
                case textLarge = "text_large"
                case textSmall = "text_small"
            }
        }

        enum CodingKeys: String, CodingKey {
            case roomid, uid, title, uname, face, cover, online, keyframe
            case areaName = "area_name"
            case watchedShow = "watched_show"
            case appId = "id"
            case userCover = "user_cover"
            case coverFromUser = "cover_from_user"
            case systemCover = "system_cover"
            case liveStatus = "live_status"
            case areaV2Name = "area_v2_name"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let rid = try? container.decode(Int.self, forKey: .roomid) {
                roomid = rid
            } else {
                roomid = try container.decode(Int.self, forKey: .appId)
            }
            uid = try container.decodeIfPresent(Int.self, forKey: .uid)
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            uname = (try? container.decode(String.self, forKey: .uname)) ?? ""
            face = (try? container.decode(String.self, forKey: .face)) ?? ""
            func firstString(_ keys: [CodingKeys]) -> String? {
                for key in keys {
                    if let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil,
                       !value.isEmpty {
                        return value
                    }
                }
                return nil
            }
            cover = firstString([.cover])
            userCover = firstString([.userCover])
            coverFromUser = firstString([.coverFromUser])
            systemCover = firstString([.systemCover])
            keyframe = firstString([.keyframe])
            areaName = firstString([.areaName, .areaV2Name])
            online = try? container.decodeIfPresent(Int.self, forKey: .online)
            watchedShow = try? container.decodeIfPresent(WatchedShow.self, forKey: .watchedShow)
            liveStatus = try? container.decodeIfPresent(Int.self, forKey: .liveStatus)
        }
    }
}

extension LiveListResult: Decodable {
    enum CodingKeys: String, CodingKey {
        case list, cardList = "card_list"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasMore = try container.decodeIfPresent(Int.self, forKey: .hasMore)

        if let webList = try? container.decodeIfPresent([LiveCard].self, forKey: .list) {
            list = webList
            return
        }

        if let cardList = try? container.decodeIfPresent([AppCardItem].self, forKey: .cardList) {
            list = cardList.compactMap { item -> LiveCard? in
                guard item.cardType == "small_card_v1",
                      let cardData = item.cardData?.smallCardV1 else { return nil }
                return cardData
            }
            return
        }

        list = nil
    }

    private struct AppCardItem: Decodable {
        let cardType: String?
        let cardData: AppCardData?

        struct AppCardData: Decodable {
            let smallCardV1: LiveCard?

            enum CodingKeys: String, CodingKey {
                case smallCardV1 = "small_card_v1"
            }
        }

        enum CodingKeys: String, CodingKey {
            case cardType = "card_type"
            case cardData = "card_data"
        }
    }
}

struct LiveParentArea: Sendable, Identifiable {
    let id: Int
    let name: String
    let list: [LiveArea]

    struct LiveArea: Sendable, Identifiable {
        let id: Int
        let parentId: Int
        let name: String
        let pic: String?

        init(id: Int, parentId: Int, name: String, pic: String? = nil) {
            self.id = id
            self.parentId = parentId
            self.name = name
            let trimmedPic = pic?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.pic = trimmedPic?.isEmpty == false ? trimmedPic : nil
        }
    }
}

extension LiveParentArea: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, list
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.flexibleInt(container, .id) ?? 0
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        list = (try? container.decodeIfPresent([LiveArea].self, forKey: .list)) ?? []
    }

    fileprivate static func flexibleInt<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K
    ) -> Int? {
        if let intValue = try? container.decode(Int.self, forKey: key) { return intValue }
        if let stringValue = try? container.decode(String.self, forKey: key) { return Int(stringValue) }
        return nil
    }
}

extension LiveParentArea.LiveArea: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, pic
        case parentId = "parent_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = LiveParentArea.flexibleInt(container, .id) ?? 0
        parentId = LiveParentArea.flexibleInt(container, .parentId) ?? 0
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        let rawPic = ((try? container.decodeIfPresent(String.self, forKey: .pic)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pic = rawPic?.isEmpty == false ? rawPic : nil
    }
}

struct LiveFollowingResult: Decodable, Sendable {
    let list: [LiveListResult.LiveCard]?
    let totalPage: Int?
    let count: Int?
}

// MARK: - Home

struct RecommendResult: Decodable, Sendable {
    let item: [RecommendItem]?

    struct RecommendItem: Decodable, Sendable, Identifiable {
        let id: Int
        let bvid: String?
        let title: String
        let pic: String
        let pic4By3: String?
        let cover43: String?
        let duration: Int?
        let owner: VideoInfo.VideoOwner?
        let stat: RecommendStat?
        let goto: String?
        let uri: String?
        let roomId: Int?

        struct RecommendStat: Decodable, Sendable {
            let view: Int?
            let like: Int?
            let danmaku: Int?
        }

        var mobileCoverURL: String? {
            MobileCoverSelection.firstUsable(pic4By3, cover43)
        }

        var aspectRatioHint: CGFloat? {
            BiliAspectRatioURIParser.parseAspectRatio(from: uri)
        }

        enum CodingKeys: String, CodingKey {
            case id, bvid, title, pic, duration, owner, stat, cover43
            case pic4By3 = "pic_4_3"
            case goto = "goto"
            case uri
            case roomId = "room_id"
        }
    }
}

struct PopularResult: Decodable, Sendable {
    let list: [VideoCard]?
    let noMore: Bool?

    enum CodingKeys: String, CodingKey {
        case list
        case noMore = "no_more"
    }
}

// MARK: - User

struct UserInfo: Decodable, Sendable {
    let mid: Int
    let name: String
    let face: String
    let sign: String?
    let level: Int?
    let sex: String?
    let vip: VipInfo?
    let fansMedal: FansMedal?
    let official: OfficialInfo?
    let ipLocation: String?
    let topPhoto: String?
    let birthday: String?
    let coins: Double?
    let cardFollowing: Int?
    let cardFollowers: Int?
    let cardLikes: Int?

    struct VipInfo: Decodable, Sendable {
        let status: Int
        let type: Int
        let label: VipLabel?

        struct VipLabel: Decodable, Sendable {
            let text: String?
        }
    }

    struct FansMedal: Decodable, Sendable {
        let show: Bool?
        let wear: Bool?
        let medal: Medal?

        struct Medal: Decodable, Sendable {
            let uid: Int?
            let targetId: Int?
            let medalName: String?
            let level: Int?
            let color: Int?
            let colorStart: Int?
            let colorEnd: Int?
            let colorBorder: Int?

            enum CodingKeys: String, CodingKey {
                case uid, level, color
                case targetId = "target_id"
                case medalName = "medal_name"
                case colorStart = "color_start"
                case colorEnd = "color_end"
                case colorBorder = "color_border"
            }
        }
    }

    struct OfficialInfo: Decodable, Sendable {
        let role: Int?
        let title: String?
        let desc: String?
        let type: Int?

        var verificationTier: OfficialVerificationTier? {
            if let type {
                switch type {
                case 0: return .personal
                case 1: return .organization
                default: if (role ?? 0) <= 0 { return nil }
                }
            }
            switch role ?? 0 {
            case 1, 2, 7, 9: return .personal
            case 3, 4, 5, 6: return .organization
            case let value where value > 0: return .personal
            default: return nil
            }
        }

        var displayTitle: String? {
            for candidate in [title, desc] {
                if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case mid, name, face, sign, level, sex, vip, official, birthday, coins
        case fansMedal = "fans_medal"
        case ipLocation = "ip_location"
        case topPhoto = "top_photo"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decode(Int.self, forKey: .mid)
        name = try container.decode(String.self, forKey: .name)
        face = try container.decode(String.self, forKey: .face)
        sign = (try? container.decodeIfPresent(String.self, forKey: .sign)) ?? nil
        level = (try? container.decodeIfPresent(Int.self, forKey: .level)) ?? nil
        sex = (try? container.decodeIfPresent(String.self, forKey: .sex)) ?? nil
        vip = (try? container.decodeIfPresent(VipInfo.self, forKey: .vip)) ?? nil
        fansMedal = (try? container.decodeIfPresent(FansMedal.self, forKey: .fansMedal)) ?? nil
        official = (try? container.decodeIfPresent(OfficialInfo.self, forKey: .official)) ?? nil
        ipLocation = (try? container.decodeIfPresent(String.self, forKey: .ipLocation)) ?? nil
        topPhoto = (try? container.decodeIfPresent(String.self, forKey: .topPhoto)) ?? nil
        birthday = Self.decodeBirthday(container)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .coins) {
            coins = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .coins) {
            coins = Double(text)
        } else {
            coins = nil
        }
        cardFollowing = nil
        cardFollowers = nil
        cardLikes = nil
    }

    private static func decodeBirthday(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: .birthday) {
            return text
        }
        guard let seconds = try? container.decodeIfPresent(Int.self, forKey: .birthday),
              seconds != 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

struct UserCardSpace: Decodable, Sendable {
    let lImg: String?

    enum CodingKeys: String, CodingKey { case lImg = "l_img" }
}

struct UserCardLevelInfo: Decodable, Sendable {
    let currentLevel: Int?

    enum CodingKeys: String, CodingKey { case currentLevel = "current_level" }
}

struct UserCardPayload: Decodable, Sendable {
    let mid: Int
    let name: String
    let face: String
    let sign: String?
    let sex: String?
    let birthday: String?
    let level: Int?
    let vip: UserInfo.VipInfo?
    let official: UserInfo.OfficialInfo?
    let fans: Int?
    let friend: Int?

    enum CodingKeys: String, CodingKey {
        case mid, name, face, sign, sex, birthday, vip, fans, friend
        case levelInfo = "level_info"
        case official = "Official"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int.self, forKey: .mid) {
            mid = number
        } else {
            let text = try container.decode(String.self, forKey: .mid)
            guard let number = Int(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mid, in: container, debugDescription: "mid is not numeric: \(text)"
                )
            }
            mid = number
        }
        name = try container.decode(String.self, forKey: .name)
        face = try container.decode(String.self, forKey: .face)
        sign = (try? container.decodeIfPresent(String.self, forKey: .sign)) ?? nil
        sex = (try? container.decodeIfPresent(String.self, forKey: .sex)) ?? nil
        birthday = (try? container.decodeIfPresent(String.self, forKey: .birthday)) ?? nil
        level = ((try? container.decodeIfPresent(UserCardLevelInfo.self, forKey: .levelInfo)) ?? nil)?.currentLevel
        vip = (try? container.decodeIfPresent(UserInfo.VipInfo.self, forKey: .vip)) ?? nil
        official = (try? container.decodeIfPresent(UserInfo.OfficialInfo.self, forKey: .official)) ?? nil
        fans = (try? container.decodeIfPresent(Int.self, forKey: .fans)) ?? nil
        friend = (try? container.decodeIfPresent(Int.self, forKey: .friend)) ?? nil
    }
}

struct UserCardResult: Decodable, Sendable {
    let card: UserCardPayload
    let space: UserCardSpace?
    let follower: Int?
    let likeNum: Int?

    enum CodingKeys: String, CodingKey {
        case card, space, follower
        case likeNum = "like_num"
    }
}

extension UserInfo {
    init(card result: UserCardResult) {
        let card = result.card
        mid = card.mid
        name = card.name
        face = card.face
        sign = card.sign
        level = card.level
        sex = card.sex
        vip = card.vip
        fansMedal = nil
        official = card.official
        ipLocation = nil
        topPhoto = result.space?.lImg
        birthday = card.birthday
        coins = nil
        cardFollowing = card.friend
        cardFollowers = result.follower ?? card.fans
        cardLikes = result.likeNum
    }
}

struct HistoryResult: Decodable, Sendable {
    let list: [HistoryItem]?
    let cursor: HistoryCursor?

    struct HistoryItem: Decodable, Sendable, Identifiable {
        struct HistoryEntry: Decodable, Sendable {
            let oid: Int?
            let bvid: String?
            let business: String?
        }

        let kid: Int
        let title: String
        let cover: String
        let authorName: String
        let authorMid: Int
        let viewAt: Int
        let progress: Int
        let duration: Int
        let badge: String?
        let history: HistoryEntry?

        var id: Int { kid }

        var bvid: String? {
            guard let value = history?.bvid, !value.isEmpty else { return nil }
            return value
        }

        var historyBusiness: String {
            let value = history?.business?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "archive" : value
        }

        var isWatched: Bool {
            if progress == -1 { return true }
            guard duration > 0, progress > 0 else { return false }
            return duration > 5 ? progress >= duration - 5 : progress >= duration
        }

        enum CodingKeys: String, CodingKey {
            case kid, title, cover, progress, duration, badge, history
            case authorName = "author_name"
            case authorMid = "author_mid"
            case viewAt = "view_at"
        }
    }

    struct HistoryCursor: Decodable, Sendable {
        let max: Int
        let viewAt: Int

        enum CodingKeys: String, CodingKey {
            case max
            case viewAt = "view_at"
        }
    }
}

struct FollowingResult: Decodable, Sendable {
    let list: [FollowingItem]?
    let total: Int?

    struct FollowingItem: Decodable, Sendable, Identifiable {
        let mid: Int
        let uname: String
        let face: String
        let sign: String?
        let attribute: Int?

        var id: Int { mid }
    }
}

struct WatchLaterResult: Decodable, Sendable {
    let list: [WatchLaterItem]?
    let count: Int?

    struct WatchLaterItem: Decodable, Sendable, Identifiable {
        let aid: Int
        let bvid: String?
        let title: String
        let pic: String
        let duration: Int?
        let dimension: VideoInfo.Dimension?
        let owner: VideoInfo.VideoOwner?
        let stat: VideoInfo.VideoStat?
        let progress: Int?
        let state: Int?

        var id: Int { aid }

        var isWatched: Bool {
            guard let progress else { return false }
            if progress == -1 { return true }
            guard let duration, duration > 0, progress > 0 else { return false }
            return duration > 5 ? progress >= duration - 5 : progress >= duration
        }

        var watchProgressFraction: Double? {
            guard let progress, progress != 0, let duration, duration > 0 else { return nil }
            return FormatUtils.historyProgressFraction(progress: progress, duration: duration)
        }

        var isUnavailable: Bool {
            if let state, state < 0 { return true }
            return false
        }
    }
}

struct FavoriteFolderResult: Decodable, Sendable {
    let list: [FavoriteFolder]?
    let count: Int?
    let hasMore: Bool?

    struct FavoriteFolder: Decodable, Sendable, Identifiable {
        let id: Int
        let title: String
        let mediaCount: Int?
        let attr: Int?
        let mid: Int?
        let cover: String?
        let upper: FavoriteContentResult.FavoriteMedia.Upper?

        var isPrivate: Bool {
            ((attr ?? 0) & 1) == 1
        }

        var isDefault: Bool {
            guard let attr else { return false }
            return ((attr >> 1) & 1) == 0
        }

        enum CodingKeys: String, CodingKey {
            case id, title, attr, mid, cover, upper
            case mediaCount = "media_count"
        }
    }

    enum CodingKeys: String, CodingKey {
        case list, count
        case hasMore = "has_more"
    }
}

struct FavoriteContentResult: Decodable, Sendable {
    let info: FolderInfo?
    let medias: [FavoriteMedia]?
    let hasMore: Bool?

    struct FolderInfo: Decodable, Sendable {
        let id: Int?
        let mid: Int?
        let attr: Int?
        let title: String?
        let mediaCount: Int?
        let intro: String?

        enum CodingKeys: String, CodingKey {
            case id, mid, attr, title, intro
            case mediaCount = "media_count"
        }
    }

    struct FavoriteMedia: Decodable, Sendable, Identifiable {
        let id: Int
        let type: Int?
        let attr: Int?
        let title: String
        let cover: String?
        let intro: String?
        let page: Int?
        let duration: Int?
        let dimension: VideoInfo.Dimension?
        let upper: Upper?
        let cntInfo: CntInfo?
        let bvid: String?

        var resourceKey: String { "\(type ?? -1):\(id)" }
        var isVideo: Bool { type == 2 && id > 0 }
        var isPlayableVideo: Bool { isVideo && (attr == nil || attr == 0 || attr == 16) }

        struct Upper: Decodable, Sendable {
            let mid: Int?
            let name: String?
            let face: String?
        }

        struct CntInfo: Decodable, Sendable {
            let collect: Int?
            let play: Int?
            let danmaku: Int?

            enum CodingKeys: String, CodingKey {
                case collect, play, danmaku
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, type, attr, title, cover, intro, page, duration, dimension, upper, bvid
            case cntInfo = "cnt_info"
        }
    }

    enum CodingKeys: String, CodingKey {
        case info, medias
        case hasMore = "has_more"
    }
}

struct UserStatResult: Decodable, Sendable {
    let following: Int?
    let follower: Int?
    let dynamicCount: Int?

    enum CodingKeys: String, CodingKey {
        case following, follower
        case dynamicCount = "dynamic_count"
    }
}

struct EmptyResult: Decodable, Sendable {}

struct RelationResult: Decodable, Sendable {
    let attribute: Int?
    var isFollowing: Bool { [1, 2, 6].contains(attribute ?? 0) }
    var isBlocked: Bool { attribute == 128 }
}

struct BlacklistResult: Decodable, Sendable {
    let list: [BlockedUser]?
    let total: Int?

    struct BlockedUser: Decodable, Sendable, Identifiable {
        let mid: Int
        let uname: String?
        let face: String?
        let sign: String?
        let mtime: Int?

        var id: Int { mid }
    }
}

// MARK: - Search

private enum SearchHTMLText {
    static func stripAndDecode(_ raw: String) -> String {
        guard raw.contains("<") || raw.contains("&") else { return raw }
        let stripped: String
        if raw.contains("<") {
            let scalars = raw.unicodeScalars
            var output = String.UnicodeScalarView()
            output.reserveCapacity(scalars.count)
            var index = scalars.startIndex
            while index < scalars.endIndex {
                if scalars[index] == "<" {
                    let afterOpen = scalars.index(after: index)
                    var close = afterOpen
                    while close < scalars.endIndex, scalars[close] != ">" {
                        close = scalars.index(after: close)
                    }
                    if close < scalars.endIndex, close > afterOpen {
                        index = scalars.index(after: close)
                        continue
                    }
                }
                output.append(scalars[index])
                index = scalars.index(after: index)
            }
            stripped = String(output)
        } else {
            stripped = raw
        }
        return HTMLEntityDecoder.decode(stripped)
    }

    static func parseHighlightSegments(_ raw: String) -> [SearchSuggestion.Segment] {
        guard !raw.isEmpty else { return [] }
        var segments: [SearchSuggestion.Segment] = []
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            if let openRange = raw.range(of: "<em", range: cursor..<raw.endIndex),
               let openEnd = raw.range(of: ">", range: openRange.upperBound..<raw.endIndex) {
                if openRange.lowerBound > cursor {
                    let plain = stripAndDecode(String(raw[cursor..<openRange.lowerBound]))
                    if !plain.isEmpty { segments.append(.init(text: plain, isHighlighted: false)) }
                }
                if let closeRange = raw.range(of: "</em>", range: openEnd.upperBound..<raw.endIndex) {
                    let highlighted = stripAndDecode(String(raw[openEnd.upperBound..<closeRange.lowerBound]))
                    if !highlighted.isEmpty { segments.append(.init(text: highlighted, isHighlighted: true)) }
                    cursor = closeRange.upperBound
                    continue
                }
            }
            let tail = stripAndDecode(String(raw[cursor..<raw.endIndex]))
            if !tail.isEmpty { segments.append(.init(text: tail, isHighlighted: false)) }
            break
        }
        return segments
    }
}

private struct AnyDecodableSkip: Decodable {}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum OfficialVerificationTier: Sendable, Equatable {
    case personal
    case organization
}

struct SearchUserOfficialVerify: Decodable, Sendable, Equatable {
    let type: Int?
    let desc: String?

    var verificationTier: OfficialVerificationTier? {
        switch type {
        case 0: .personal
        case 1: .organization
        default: nil
        }
    }
}

struct SearchMediaScore: Decodable, Sendable, Equatable {
    let score: Double?
    let userCount: Int?

    enum CodingKeys: String, CodingKey {
        case score
        case userCount = "user_count"
    }
}

struct SearchRepresentativeVideo: Decodable, Sendable, Identifiable, Equatable {
    let aid: Int?
    let bvid: String?
    let title: String
    let cleanTitle: String
    let pic: String?
    let play: Int?
    let duration: String?
    let durationSeconds: Int
    let pubdate: Int?
    let danmaku: Int?

    var id: String { bvid ?? "\(aid ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case aid, bvid, title, pic, play, duration, pubdate, danmaku
        case dmCount = "dm"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aid = try? container.decodeIfPresent(Int.self, forKey: .aid)
        bvid = try? container.decodeIfPresent(String.self, forKey: .bvid)
        let decodedTitle = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        title = decodedTitle
        cleanTitle = SearchHTMLText.stripAndDecode(decodedTitle)
        pic = try? container.decodeIfPresent(String.self, forKey: .pic)
        play = Self.decodePlayCount(container)
        let (rawDuration, seconds) = Self.decodeDuration(container)
        duration = rawDuration
        durationSeconds = seconds
        pubdate = try? container.decodeIfPresent(Int.self, forKey: .pubdate)
        danmaku = (try? container.decodeIfPresent(Int.self, forKey: .danmaku))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .dmCount))
    }

    private static func decodePlayCount(_ container: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: .play) {
            return intVal
        }
        guard let strVal = try? container.decodeIfPresent(String.self, forKey: .play) else {
            return nil
        }
        let trimmed = strVal.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = Int(trimmed) { return exact }
        if trimmed.hasSuffix("万"), let num = Double(trimmed.dropLast()) {
            return Int(num * 10_000)
        }
        if trimmed.hasSuffix("亿"), let num = Double(trimmed.dropLast()) {
            return Int(num * 100_000_000)
        }
        return nil
    }

    private static func decodeDuration(_ container: KeyedDecodingContainer<CodingKeys>) -> (String?, Int) {
        if let str = try? container.decodeIfPresent(String.self, forKey: .duration) {
            let parts = str.split(separator: ":").compactMap { Int($0) }
            let secs = parts.isEmpty ? 0 : parts.reduce(0) { $0 * 60 + $1 }
            return (str, secs)
        }
        if let secs = try? container.decodeIfPresent(Int.self, forKey: .duration), secs >= 0 {
            let hours = secs / 3600
            let mins = (secs % 3600) / 60
            let rem = secs % 60
            let formatted = hours > 0
                ? String(format: "%d:%02d:%02d", hours, mins, rem)
                : String(format: "%d:%02d", mins, rem)
            return (formatted, secs)
        }
        return (nil, 0)
    }
}

struct SearchResultItemModel: Decodable, Sendable, Identifiable, Equatable {
    typealias OfficialVerify = SearchUserOfficialVerify
    typealias MediaScore = SearchMediaScore
    typealias RepresentativeVideo = SearchRepresentativeVideo

    let resultType: String?
    let aid: Int?
    let bvid: String?
    let title: String
    let cleanTitle: String
    let desc: String?
    let cleanDesc: String
    let pic: String?
    let liveArtwork: String?
    let cover: String?
    let author: String?
    let mid: Int?
    let duration: String?
    let play: Int?
    let danmaku: Int?
    let pubdate: Int?
    let roomid: Int?

    let uname: String?
    let upic: String?
    let usign: String?
    let fans: Int?
    let videos: Int?
    let level: Int?
    let officialVerify: OfficialVerify?
    let isLive: Bool?
    let res: [RepresentativeVideo]?

    let seasonId: Int?
    let mediaId: Int?
    let seasonTypeName: String?
    let areas: String?
    let styles: String?
    let indexShow: String?
    let mediaScore: MediaScore?
    let epSize: Int?
    let pubtime: Int?

    let uface: String?
    let liveStatus: Int?
    let cateName: String?
    let areaName: String?
    let online: Int?

    let articleId: Int?
    let imageUrls: [String]?
    let categoryName: String?
    let view: Int?
    let like: Int?
    let reply: Int?

    var id: String {
        let prefix = inferredKindPrefix
        if let bvid, !bvid.isEmpty { return "\(prefix):\(bvid)" }
        if let seasonId { return "\(prefix):s\(seasonId)" }
        if let articleId, resultType == "article" || imageUrls != nil || categoryName != nil {
            return "\(prefix):cv\(articleId)"
        }
        if let roomid, roomid > 0 { return "\(prefix):r\(roomid)" }
        if let aid { return "\(prefix):a\(aid)" }
        if let mid { return "\(prefix):u\(mid)" }
        if let mediaId { return "\(prefix):m\(mediaId)" }
        if let articleId { return "\(prefix):cv\(articleId)" }
        return "\(prefix):\(cleanTitle)"
    }

    private var inferredKindPrefix: String {
        if let resultType, !resultType.isEmpty { return resultType }
        if seasonId != nil || mediaId != nil { return "bangumi" }
        if imageUrls != nil || categoryName != nil || (articleId != nil && bvid == nil && roomid == nil) {
            return "article"
        }
        if let roomid, roomid > 0 { return "live" }
        if bvid != nil || aid != nil { return "video" }
        if mid != nil { return "user" }
        return "item"
    }

    fileprivate func withBucketResultTypeIfMissing(_ bucketType: String) -> SearchResultItemModel {
        guard resultType == nil || resultType?.isEmpty == true else { return self }
        return SearchResultItemModel(copying: self, resultType: bucketType)
    }

    private init(copying other: SearchResultItemModel, resultType: String) {
        self.resultType = resultType
        aid = other.aid
        bvid = other.bvid
        title = other.title
        cleanTitle = other.cleanTitle
        desc = other.desc
        cleanDesc = other.cleanDesc
        pic = other.pic
        liveArtwork = other.liveArtwork
        cover = other.cover
        author = other.author
        mid = other.mid
        duration = other.duration
        play = other.play
        danmaku = other.danmaku
        pubdate = other.pubdate
        roomid = other.roomid
        uname = other.uname
        upic = other.upic
        usign = other.usign
        fans = other.fans
        videos = other.videos
        level = other.level
        officialVerify = other.officialVerify
        isLive = other.isLive
        res = other.res
        seasonId = other.seasonId
        mediaId = other.mediaId
        seasonTypeName = other.seasonTypeName
        areas = other.areas
        styles = other.styles
        indexShow = other.indexShow
        mediaScore = other.mediaScore
        epSize = other.epSize
        pubtime = other.pubtime
        uface = other.uface
        liveStatus = other.liveStatus
        cateName = other.cateName
        areaName = other.areaName
        online = other.online
        articleId = other.articleId
        imageUrls = other.imageUrls
        categoryName = other.categoryName
        view = other.view
        like = other.like
        reply = other.reply
    }

    enum CodingKeys: String, CodingKey {
        case aid, bvid, title, desc, pic, author, mid, duration, play, danmaku, pubdate, roomid
        case resultType = "result_type"
        case type
        case uname, upic, usign, fans, videos, level, res, cover, uid, online
        case officialVerify = "official_verify"
        case isLive = "is_live"
        case roomIdSnake = "room_id"
        case userCover = "user_cover"
        case uface
        case liveStatus = "live_status"
        case cateName = "cate_name"
        case areaName = "area_name"
        case areaV2Name = "area_v2_name"
        case seasonId = "season_id"
        case mediaId = "media_id"
        case seasonTypeName = "season_type_name"
        case areas, styles, pubtime
        case indexShow = "index_show"
        case mediaScore = "media_score"
        case epSize = "ep_size"
        case id, view, like, reply
        case imageUrls = "image_urls"
        case categoryName = "category_name"
        case pubTime = "pub_time"
        case videoReview = "video_review"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultType = Self.firstString(container, keys: [.resultType, .type])
        aid = Self.firstInt(container, keys: [.aid])
        bvid = Self.firstString(container, keys: [.bvid])
        let rawUname = Self.firstString(container, keys: [.uname])
        uname = rawUname.map(SearchHTMLText.stripAndDecode)
        let decodedTitle = Self.firstString(container, keys: [.title]) ?? rawUname ?? ""
        title = decodedTitle
        cleanTitle = SearchHTMLText.stripAndDecode(decodedTitle)
        let rawUsign = Self.firstString(container, keys: [.usign])
        usign = rawUsign.map(SearchHTMLText.stripAndDecode)
        let rawDesc = Self.firstString(container, keys: [.desc]) ?? rawUsign
        desc = rawDesc
        cleanDesc = rawDesc.map(SearchHTMLText.stripAndDecode) ?? ""
        let decodedImageUrls = try? container.decodeIfPresent([String].self, forKey: .imageUrls)
        imageUrls = decodedImageUrls
        upic = Self.firstString(container, keys: [.upic, .uface])
        uface = Self.firstString(container, keys: [.uface])
        cover = Self.firstString(container, keys: [.cover])
        liveArtwork = Self.firstString(container, keys: [.userCover, .cover, .uface])
        pic = Self.firstString(container, keys: [.pic, .upic, .userCover, .cover, .uface])
            ?? decodedImageUrls?.first
        author = Self.firstString(container, keys: [.author, .uname]).map(SearchHTMLText.stripAndDecode)
        mid = Self.firstInt(container, keys: [.mid, .uid])
        duration = Self.decodeDurationString(container)
        online = Self.firstInt(container, keys: [.online])
        view = Self.firstInt(container, keys: [.view])
        play = Self.firstInt(container, keys: [.play, .online, .view])
        danmaku = Self.firstInt(container, keys: [.danmaku, .videoReview])
        pubtime = Self.firstInt(container, keys: [.pubtime])
        pubdate = Self.firstInt(container, keys: [.pubdate, .pubTime, .pubtime])
        roomid = Self.firstInt(container, keys: [.roomid, .roomIdSnake])
        fans = Self.firstInt(container, keys: [.fans])
        videos = Self.firstInt(container, keys: [.videos])
        level = Self.firstInt(container, keys: [.level])
        officialVerify = try? container.decodeIfPresent(OfficialVerify.self, forKey: .officialVerify)
        isLive = Self.decodeBool(container, key: .isLive)
        res = Self.decodeRepresentativeVideos(container)
        seasonId = Self.firstInt(container, keys: [.seasonId])
        mediaId = Self.firstInt(container, keys: [.mediaId])
        seasonTypeName = Self.firstString(container, keys: [.seasonTypeName])
        areas = Self.firstString(container, keys: [.areas])
        styles = Self.firstString(container, keys: [.styles])
        indexShow = Self.firstString(container, keys: [.indexShow])
        mediaScore = try? container.decodeIfPresent(MediaScore.self, forKey: .mediaScore)
        epSize = Self.firstInt(container, keys: [.epSize])
        liveStatus = Self.firstInt(container, keys: [.liveStatus])
        cateName = Self.firstString(container, keys: [.cateName])
        areaName = Self.firstString(container, keys: [.areaName, .areaV2Name, .cateName])
        articleId = Self.firstInt(container, keys: [.id])
        categoryName = Self.firstString(container, keys: [.categoryName])
        like = Self.firstInt(container, keys: [.like])
        reply = Self.firstInt(container, keys: [.reply])
    }
}

struct SearchResult: Decodable, Sendable {
    typealias SearchResultItem = SearchResultItemModel

    let numResults: Int?
    let numPages: Int?
    let page: Int?
    let pagesize: Int?
    let result: [SearchResultItem]?

    enum CodingKeys: String, CodingKey {
        case result
        case numResults
        case numPages
        case page
        case pagesize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numResults = try? container.decodeIfPresent(Int.self, forKey: .numResults)
        numPages = try? container.decodeIfPresent(Int.self, forKey: .numPages)
        page = try? container.decodeIfPresent(Int.self, forKey: .page)
        pagesize = try? container.decodeIfPresent(Int.self, forKey: .pagesize)
        if container.contains(.result),
           var array = try? container.nestedUnkeyedContainer(forKey: .result) {
            var decoded: [SearchResultItem] = []
            while !array.isAtEnd {
                if let item = try? array.decode(SearchResultItem.self) {
                    decoded.append(item)
                } else {
                    _ = try? array.decode(AnyDecodableSkip.self)
                }
            }
            result = decoded
        } else {
            result = nil
        }
    }
}

private extension SearchResultItemModel {
    static func firstString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    static func firstInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let str = try? container.decodeIfPresent(String.self, forKey: key),
               let value = Int(str) {
                return value
            }
        }
        return nil
    }

    static func decodeBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intValue != 0
        }
        return nil
    }

    static func decodeDurationString(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let str = try? container.decodeIfPresent(String.self, forKey: .duration) {
            return str
        }
        if let secs = try? container.decodeIfPresent(Int.self, forKey: .duration), secs >= 0 {
            let hours = secs / 3600
            let mins = (secs % 3600) / 60
            let rem = secs % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, mins, rem)
                : String(format: "%d:%02d", mins, rem)
        }
        return nil
    }

    static func decodeRepresentativeVideos(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> [RepresentativeVideo]? {
        guard container.contains(.res),
              var array = try? container.nestedUnkeyedContainer(forKey: .res)
        else { return nil }
        var items: [RepresentativeVideo] = []
        while !array.isAtEnd {
            if let video = try? array.decode(RepresentativeVideo.self) {
                items.append(video)
            } else {
                _ = try? array.decode(AnyDecodableSkip.self)
            }
        }
        return items
    }
}

struct SearchAllBucketModel: Decodable, Sendable {
    let resultType: String
    let data: [SearchResult.SearchResultItem]

    enum CodingKeys: String, CodingKey {
        case resultType = "result_type"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultType = try container.decode(String.self, forKey: .resultType)
        guard container.contains(.data),
              var array = try? container.nestedUnkeyedContainer(forKey: .data)
        else {
            data = []
            return
        }
        var items: [SearchResult.SearchResultItem] = []
        while !array.isAtEnd {
            if let item = try? array.decode(SearchResult.SearchResultItem.self) {
                items.append(item.withBucketResultTypeIfMissing(resultType))
            } else {
                _ = try? array.decode(AnyDecodableSkip.self)
            }
        }
        data = items
    }
}

struct SearchAllResult: Decodable, Sendable {
    typealias SearchAllBucket = SearchAllBucketModel

    let numResults: Int?
    let numPages: Int?
    let page: Int?
    let pagesize: Int?
    let topTlist: [String: Int]?
    let result: [SearchAllBucket]?

    enum CodingKeys: String, CodingKey {
        case numResults
        case numPages
        case page
        case pagesize
        case topTlist = "top_tlist"
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numResults = try? container.decodeIfPresent(Int.self, forKey: .numResults)
        numPages = try? container.decodeIfPresent(Int.self, forKey: .numPages)
        page = try? container.decodeIfPresent(Int.self, forKey: .page)
        pagesize = try? container.decodeIfPresent(Int.self, forKey: .pagesize)

        if container.contains(.topTlist),
           let tlistContainer = try? container.nestedContainer(
               keyedBy: DynamicCodingKey.self,
               forKey: .topTlist
           ) {
            var counts: [String: Int] = [:]
            for key in tlistContainer.allKeys {
                if let count = try? tlistContainer.decode(Int.self, forKey: key) {
                    counts[key.stringValue] = count
                }
            }
            topTlist = counts
        } else {
            topTlist = nil
        }

        if container.contains(.result),
           var array = try? container.nestedUnkeyedContainer(forKey: .result) {
            var buckets: [SearchAllBucket] = []
            while !array.isAtEnd {
                if let bucket = try? array.decode(SearchAllBucket.self) {
                    buckets.append(bucket)
                } else {
                    _ = try? array.decode(AnyDecodableSkip.self)
                }
            }
            result = buckets
        } else {
            result = nil
        }
    }
}

struct SearchDefaultResult: Decodable, Sendable, Equatable {
    let showName: String?
    let name: String?
    let url: String?
    let gotoType: Int?
    let gotoValue: String?

    enum CodingKeys: String, CodingKey {
        case showName = "show_name"
        case name
        case url
        case gotoType = "goto_type"
        case gotoValue = "goto_value"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawShowName = (try? container.decodeIfPresent(String.self, forKey: .showName))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = (try? container.decodeIfPresent(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanShow = rawShowName.flatMap { $0.isEmpty ? nil : $0 }
        let cleanName = rawName.flatMap { $0.isEmpty ? nil : $0 }
        showName = cleanShow ?? cleanName
        name = cleanName ?? cleanShow
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        gotoType = try? container.decodeIfPresent(Int.self, forKey: .gotoType)
        gotoValue = try? container.decodeIfPresent(String.self, forKey: .gotoValue)
    }
}

struct SearchSuggestion: Decodable, Sendable, Identifiable, Equatable, Hashable {
    struct Segment: Sendable, Equatable, Hashable {
        let text: String
        let isHighlighted: Bool
    }

    let value: String
    let term: String
    let name: String
    let cleanName: String
    let segments: [Segment]

    var id: String { value }

    enum CodingKeys: String, CodingKey {
        case value, term, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        let parsedSegments = SearchHTMLText.parseHighlightSegments(rawName)
        let strippedName = parsedSegments.isEmpty
            ? SearchHTMLText.stripAndDecode(rawName)
            : parsedSegments.map(\.text).joined()
        let rawValue = (try? container.decodeIfPresent(String.self, forKey: .value))
            ?? (try? container.decodeIfPresent(String.self, forKey: .term))
            ?? strippedName
        let decodedValue = HTMLEntityDecoder.decode(rawValue)
        let rawTerm = (try? container.decodeIfPresent(String.self, forKey: .term)) ?? decodedValue
        value = decodedValue
        term = HTMLEntityDecoder.decode(rawTerm)
        name = rawName
        cleanName = strippedName.isEmpty ? decodedValue : strippedName
        if parsedSegments.isEmpty, !cleanName.isEmpty {
            segments = [Segment(text: cleanName, isHighlighted: false)]
        } else {
            segments = parsedSegments
        }
    }
}

struct HotSearchResult: Decodable, Sendable {
    let trending: TrendingInfo?

    struct TrendingInfo: Decodable, Sendable {
        let list: [HotWord]?

        struct HotWord: Decodable, Sendable, Identifiable {
            let keyword: String
            let showName: String?
            let icon: String?
            let position: Int?

            var id: String { keyword }

            enum CodingKeys: String, CodingKey {
                case keyword, icon, position
                case showName = "show_name"
            }
        }
    }
}

// MARK: - Dynamic

struct DynamicRichPicture: Decodable, Sendable, Equatable {
    let src: String?
    let url: String?
    let width: Int?
    let height: Int?

    var source: String? {
        if let src, !src.isEmpty { return src }
        return url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        src = try container.decodeIfPresent(String.self, forKey: .src)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        width = (try? container.decodeIfPresent(Int.self, forKey: .width))
            ?? Int((try? container.decodeIfPresent(String.self, forKey: .width)) ?? "")
        height = (try? container.decodeIfPresent(Int.self, forKey: .height))
            ?? Int((try? container.decodeIfPresent(String.self, forKey: .height)) ?? "")
    }

    enum CodingKeys: String, CodingKey { case src, url, width, height }
}

struct DynamicRichEmoji: Decodable, Sendable, Equatable {
    let webpURL: String?
    let gifURL: String?
    let iconURL: String?
    let size: Double?

    var source: String? {
        [webpURL, gifURL, iconURL].compactMap { $0 }.first { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case size
        case webpURL = "webp_url"
        case gifURL = "gif_url"
        case iconURL = "icon_url"
    }
}

struct DynamicRichTextNode: Decodable, Sendable, Equatable {
    let type: String?
    let text: String?
    let origText: String?
    let jumpUrl: String?
    let rid: String?
    let pics: [Picture]?
    let emoji: Emoji?

    typealias Picture = DynamicRichPicture
    typealias Emoji = DynamicRichEmoji

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        origText = try container.decodeIfPresent(String.self, forKey: .origText)
        jumpUrl = try container.decodeIfPresent(String.self, forKey: .jumpUrl)
        rid = (try? container.decodeIfPresent(String.self, forKey: .rid))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .rid)).map { String($0) }
        pics = try container.decodeIfPresent([Picture].self, forKey: .pics)
        emoji = try container.decodeIfPresent(Emoji.self, forKey: .emoji)
    }

    enum CodingKeys: String, CodingKey {
        case type, text, rid, pics, emoji
        case origText = "orig_text"
        case jumpUrl = "jump_url"
    }
}

struct DynamicOpusSummary: Decodable, Sendable {
    let text: String?
    let richTextNodes: [DynamicRichTextNode]?

    enum CodingKeys: String, CodingKey {
        case text
        case richTextNodes = "rich_text_nodes"
    }
}

struct DynamicFeedResult: Decodable, Sendable {
    let items: [DynamicItem]?
    let offset: String?
    let hasMore: Bool?

    struct DynamicItem: Decodable, Sendable, Identifiable {
        let idStr: String?
        let type: String?
        let modules: DynamicModules?
        let basic: DynamicBasic?
        let orig: DynamicOrig?

        var id: String {
            if let idStr, !idStr.isEmpty {
                return idStr
            }
            if let commentId = basic?.commentIdStr, !commentId.isEmpty {
                return "comment:\(commentId)"
            }
            if let bvid = modules?.moduleDynamic?.major?.archive?.bvid, !bvid.isEmpty {
                return "archive:\(bvid)"
            }
            if let author = modules?.moduleAuthor, author.mid != nil || author.pubTs != nil {
                return "author:\(author.mid ?? 0):\(author.pubTs ?? 0)"
            }
            return "dynamic-empty"
        }

        final class DynamicOrig: Decodable, Sendable {
            let item: DynamicItem

            init(from decoder: Decoder) throws {
                item = try DynamicItem(from: decoder)
            }
        }

        struct DynamicBasic: Decodable, Sendable {
            let commentIdStr: String?
            let commentType: Int?

            enum CodingKeys: String, CodingKey {
                case commentIdStr = "comment_id_str"
                case commentType = "comment_type"
            }
        }

        struct DynamicModules: Decodable, Sendable {
            let moduleAuthor: ModuleAuthor?
            let moduleDynamic: ModuleDynamic?
            let moduleStat: ModuleStat?

            struct ModuleStat: Decodable, Sendable {
                let comment: StatItem?
                let forward: StatItem?
                let like: LikeStat?

                struct StatItem: Decodable, Sendable {
                    let count: Int?
                }

                struct LikeStat: Decodable, Sendable {
                    let count: Int?
                    let status: Bool?
                }
            }

            struct ModuleAuthor: Decodable, Sendable {
                let name: String?
                let face: String?
                let mid: Int?
                let pubTs: Int?

                enum CodingKeys: String, CodingKey {
                    case name, face, mid
                    case pubTs = "pub_ts"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decodeIfPresent(String.self, forKey: .name)
                    face = try container.decodeIfPresent(String.self, forKey: .face)
                    mid = try container.decodeIfPresent(Int.self, forKey: .mid)
                    if let intVal = try? container.decodeIfPresent(Int.self, forKey: .pubTs) {
                        pubTs = intVal
                    } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .pubTs) {
                        pubTs = Int(strVal)
                    } else {
                        pubTs = nil
                    }
                }
            }

            struct ModuleDynamic: Decodable, Sendable {
                let major: DynamicMajor?
                let desc: DynamicDesc?
                let additional: DynamicAdditional?

                struct DynamicAdditional: Decodable, Sendable {
                    let type: String?
                    let vote: AdditionalVote?

                    struct AdditionalVote: Decodable, Sendable {
                        let voteId: Int?
                        let desc: String?
                        let joinNum: Int?
                        let endTime: Int?
                        let choiceCnt: Int?

                        enum CodingKeys: String, CodingKey {
                            case desc
                            case voteId = "vote_id"
                            case joinNum = "join_num"
                            case endTime = "end_time"
                            case choiceCnt = "choice_cnt"
                        }
                    }
                }

                struct DynamicMajor: Decodable, Sendable {
                    let type: String?
                    let archive: ArchiveInfo?
                    let draw: DrawInfo?
                    let pgc: PGCInfo?
                    let common: CommonInfo?
                    let liveRcmd: LiveRcmdInfo?
                    let opus: OpusInfo?
                    let article: ArticleInfo?
                    let ugcSeason: UgcSeasonInfo?

                    struct ArchiveInfo: Decodable, Sendable {
                        let aid: String?
                        let bvid: String?
                        let title: String?
                        let cover: String?
                        let desc: String?
                        let durationText: String?

                        enum CodingKeys: String, CodingKey {
                            case aid, bvid, title, cover, desc
                            case durationText = "duration_text"
                        }
                    }

                    struct DrawInfo: Decodable, Sendable {
                        let items: [DrawItem]?

                        struct DrawItem: Decodable, Sendable {
                            let src: String?
                            let width: Int?
                            let height: Int?

                            init(src: String?, width: Int?, height: Int?) {
                                self.src = src; self.width = width; self.height = height
                            }

                            init(from decoder: Decoder) throws {
                                let container = try decoder.container(keyedBy: CodingKeys.self)
                                src = try container.decodeIfPresent(String.self, forKey: .src)
                                width = (try? container.decodeIfPresent(Int.self, forKey: .width))
                                    ?? Int((try? container.decodeIfPresent(String.self, forKey: .width)) ?? "")
                                height = (try? container.decodeIfPresent(Int.self, forKey: .height))
                                    ?? Int((try? container.decodeIfPresent(String.self, forKey: .height)) ?? "")
                            }

                            enum CodingKeys: String, CodingKey {
                                case src, width, height
                            }
                        }
                    }

                    struct PGCInfo: Decodable, Sendable {
                        let title: String?
                        let cover: String?
                        let epid: Int?
                    }

                    struct CommonInfo: Decodable, Sendable {
                        let title: String?
                        let cover: String?
                        let desc: String?
                        let label: String?
                        let jumpUrl: String?

                        enum CodingKeys: String, CodingKey {
                            case title, cover, desc, label
                            case jumpUrl = "jump_url"
                        }
                    }

                    struct LiveRcmdInfo: Decodable, Sendable {
                        let content: String?
                        let parsed: Parsed

                        struct Parsed: Sendable {
                            let title: String?
                            let cover: String?
                            let areaName: String?
                            let roomID: Int?
                        }

                        init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            content = try container.decodeIfPresent(String.self, forKey: .content)
                            if let content,
                               let data = content.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let info = json["live_play_info"] as? [String: Any] {
                                parsed = Parsed(
                                    title: info["title"] as? String,
                                    cover: info["cover"] as? String,
                                    areaName: info["area_name"] as? String,
                                    roomID: info["room_id"] as? Int
                                )
                            } else {
                                parsed = Parsed(title: nil, cover: nil, areaName: nil, roomID: nil)
                            }
                        }

                        private enum CodingKeys: String, CodingKey {
                            case content
                        }
                    }

                    struct OpusInfo: Decodable, Sendable {
                        let title: String?
                        let summary: OpusSummary?
                        let pics: [OpusPic]?

                        typealias OpusSummary = DynamicOpusSummary

                        struct OpusPic: Decodable, Sendable {
                            let url: String?
                            let width: Int?
                            let height: Int?

                            init(from decoder: Decoder) throws {
                                let container = try decoder.container(keyedBy: CodingKeys.self)
                                url = try container.decodeIfPresent(String.self, forKey: .url)
                                width = (try? container.decodeIfPresent(Int.self, forKey: .width))
                                    ?? Int((try? container.decodeIfPresent(String.self, forKey: .width)) ?? "")
                                height = (try? container.decodeIfPresent(Int.self, forKey: .height))
                                    ?? Int((try? container.decodeIfPresent(String.self, forKey: .height)) ?? "")
                            }

                            enum CodingKeys: String, CodingKey {
                                case url, width, height
                            }
                        }
                    }

                    struct ArticleInfo: Decodable, Sendable {
                        let title: String?
                        let desc: String?
                        let covers: [String]?
                        let label: String?
                        let jumpUrl: String?

                        enum CodingKeys: String, CodingKey {
                            case title, desc, covers, label
                            case jumpUrl = "jump_url"
                        }
                    }

                    struct UgcSeasonInfo: Decodable, Sendable {
                        let aid: Int?
                        let title: String?
                        let cover: String?
                        let desc: String?
                        let durationText: String?
                        let badge: BadgeInfo?

                        struct BadgeInfo: Decodable, Sendable {
                            let text: String?
                        }

                        enum CodingKeys: String, CodingKey {
                            case aid, title, cover, desc, badge
                            case durationText = "duration_text"
                        }

                        init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            if let intValue = try? container.decode(Int.self, forKey: .aid) {
                                aid = intValue
                            } else if let stringValue = try? container.decode(String.self, forKey: .aid) {
                                aid = Int(stringValue)
                            } else {
                                aid = nil
                            }
                            title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
                            cover = (try? container.decodeIfPresent(String.self, forKey: .cover)) ?? nil
                            desc = (try? container.decodeIfPresent(String.self, forKey: .desc)) ?? nil
                            durationText = (try? container.decodeIfPresent(String.self, forKey: .durationText)) ?? nil
                            badge = (try? container.decodeIfPresent(BadgeInfo.self, forKey: .badge)) ?? nil
                        }
                    }

                    enum CodingKeys: String, CodingKey {
                        case type, archive, draw, pgc, common, opus, article
                        case liveRcmd = "live_rcmd"
                        case ugcSeason = "ugc_season"
                    }
                }

                struct DynamicDesc: Decodable, Sendable {
                    let text: String?
                    let richTextNodes: [RichTextNode]?

                    typealias RichTextNode = DynamicRichTextNode

                    enum CodingKeys: String, CodingKey {
                        case text
                        case richTextNodes = "rich_text_nodes"
                    }
                }
            }

            enum CodingKeys: String, CodingKey {
                case moduleAuthor = "module_author"
                case moduleDynamic = "module_dynamic"
                case moduleStat = "module_stat"
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, modules, basic, orig
            case idStr = "id_str"
        }
    }

    enum CodingKeys: String, CodingKey {
        case items, offset
        case hasMore = "has_more"
    }

    private struct AnyJSONValue: Decodable {
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { return }
            if (try? container.decode(Bool.self)) != nil { return }
            if (try? container.decode(Double.self)) != nil { return }
            if (try? container.decode(String.self)) != nil { return }
            if (try? container.decode([AnyJSONValue].self)) != nil { return }
            _ = try container.decode([String: AnyJSONValue].self)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decodeIfPresent(String.self, forKey: .offset)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
        guard container.contains(.items),
              !((try? container.decodeNil(forKey: .items)) ?? false) else {
            items = nil
            return
        }
        var itemsC = try container.nestedUnkeyedContainer(forKey: .items)
        var decoded: [DynamicItem] = []
        while !itemsC.isAtEnd {
            do {
                decoded.append(try itemsC.decode(DynamicItem.self))
            } catch {
                let index = itemsC.currentIndex
                _ = try? itemsC.decode(AnyJSONValue.self)
                guard itemsC.currentIndex > index else { break }
                PlayerLog.log("[Dynamics] dropped undecodable feed item #\(index): \(error)")
            }
        }
        items = decoded
    }
}

struct DynamicUpItem: Decodable, Sendable, Identifiable {
    let mid: Int
    let uname: String?
    let face: String?
    let hasUpdate: Bool?

    var id: Int { mid }

    private enum CodingKeys: String, CodingKey {
        case mid, uname, face
        case hasUpdate = "has_update"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .mid) {
            mid = value
        } else if let value = try? container.decode(Int64.self, forKey: .mid),
                  value > 0, value <= Int64(Int.max) {
            mid = Int(value)
        } else if let value = try? container.decode(String.self, forKey: .mid),
                  let parsed = Int(value), parsed > 0 {
            mid = parsed
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .mid,
                in: container,
                debugDescription: "Following update user mid must be a positive integer"
            )
        }
        guard mid > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .mid,
                in: container,
                debugDescription: "Following update user mid must be a positive integer"
            )
        }
        uname = try? container.decode(String.self, forKey: .uname)
        face = try? container.decode(String.self, forKey: .face)
        if let value = try? container.decode(Bool.self, forKey: .hasUpdate) {
            hasUpdate = value
        } else if let value = try? container.decode(Int.self, forKey: .hasUpdate) {
            hasUpdate = value != 0
        } else if let value = try? container.decode(String.self, forKey: .hasUpdate),
                  let parsed = Int(value) {
            hasUpdate = parsed != 0
        } else {
            hasUpdate = nil
        }
    }
}

struct DynamicFollowingUpdatePage: Decodable, Sendable {
    let items: [DynamicUpItem]?
    let hasMore: Bool?
    let offset: String?

    private enum CodingKeys: String, CodingKey {
        case items, offset
        case hasMore = "has_more"
    }
}

struct DynamicPortalResult: Decodable, Sendable {
    let upList: DynamicFollowingUpdatePage?

    private enum CodingKeys: String, CodingKey {
        case upList = "up_list"
    }
}

struct DynamicForwardResult: Decodable, Sendable {
    let items: [DynamicForwardItem]
    let offset: String?
    let hasMore: Bool
    let total: Int?

    private enum CodingKeys: String, CodingKey {
        case items, offset, total
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([DynamicForwardItem].self, forKey: .items)
        offset = try container.decodeIfPresent(String.self, forKey: .offset)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct DynamicForwardItem: Decodable, Sendable, Identifiable {
    let idStr: String
    let pubTime: String
    let user: ForwardUser
    let desc: ForwardDescription

    var id: String { idStr }

    enum CodingKeys: String, CodingKey {
        case user, desc
        case idStr = "id_str"
        case pubTime = "pub_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idStr = try container.decode(String.self, forKey: .idStr)
        guard !idStr.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .idStr,
                in: container,
                debugDescription: "Forward item id_str must not be empty"
            )
        }
        pubTime = try container.decode(String.self, forKey: .pubTime)
        user = try container.decode(ForwardUser.self, forKey: .user)
        desc = try container.decode(ForwardDescription.self, forKey: .desc)
    }

    struct ForwardUser: Decodable, Sendable {
        let mid: String?
        let name: String?
        let face: String?

        var numericMID: Int? { mid.flatMap(Int.init) }

        private enum CodingKeys: String, CodingKey { case mid, name, face }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(String.self, forKey: .mid) {
                mid = value
            } else if let value = try? container.decode(Int64.self, forKey: .mid) {
                mid = String(value)
            } else {
                mid = nil
            }
            name = try? container.decode(String.self, forKey: .name)
            face = try? container.decode(String.self, forKey: .face)
        }
    }

    struct ForwardDescription: Decodable, Sendable {
        let text: String?
        let richTextNodes: [DynamicRichTextNode]?

        enum CodingKeys: String, CodingKey {
            case text
            case richTextNodes = "rich_text_nodes"
        }
    }
}

struct CreateDynamicResult: Decodable, Sendable {
    let dynId: Int?
    let dynIdStr: String?

    enum CodingKeys: String, CodingKey {
        case dynId = "dyn_id"
        case dynIdStr = "dyn_id_str"
    }
}

// MARK: - Comment

struct CommentResult: Decodable, Sendable {
    let replies: [CommentItem]?
    let page: CommentPage?
    let topReplies: [CommentItem]?

    enum CodingKeys: String, CodingKey {
        case replies, page
        case topReplies = "top_replies"
    }

    var repliesWithPinned: [CommentItem] {
        let pinned = (topReplies ?? []).map { item in
            var flagged = item
            flagged.isPinned = true
            return flagged
        }
        guard !pinned.isEmpty else { return replies ?? [] }
        let pinnedIDs = Set(pinned.map(\.rpid))
        return pinned + (replies ?? []).filter { !pinnedIDs.contains($0.rpid) }
    }

    struct CommentItem: Decodable, Sendable, Identifiable {
        var isPinned = false
        let rpid: Int
        let mid: Int
        let oid: Int?
        let type: Int?
        let content: CommentContent
        let ctime: Int
        let like: Int
        let action: Int?
        let rcount: Int
        let member: CommentMember
        let replies: [CommentItem]?
        let replyControl: ReplyControl?
        let upAction: UpAction?

        var id: Int { rpid }

        var ipLocation: String? {
            replyControl?.location.flatMap { loc in
                let cleaned = loc.replacingOccurrences(of: "IP属地：", with: "")
                return cleaned.isEmpty ? nil : cleaned
            }
        }

        struct CommentContent: Decodable, Sendable {
            let message: String
            let pictures: [CommentPicture]?
            let emote: [String: CommentEmote]?
            let jumpUrl: [String: JumpTarget]?
            let atNameToMid: [String: FlexibleID]?
            let members: [AtMember]?
            let vote: CommentVote?
            let richText: RichTextInfo?

            let displayMessage: String

            let resolvedLinks: [String: URL]
            let emoteURLs: [String: String]

            private static func prepareDisplayMessage(_ message: String) -> String {
                guard message.contains("{vote:") else { return message }
                return message
                    .replacingOccurrences(of: #"\{vote:\d+\}"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            struct CommentVote: Decodable, Sendable {
                let id: Int?
                let title: String?
                let cnt: Int?
            }

            struct RichTextInfo: Decodable, Sendable {
                let note: Note?

                struct Note: Decodable, Sendable {
                    let summary: String?
                    let images: [String]?
                    let clickUrl: String?
                    let lastMtimeText: String?

                    enum CodingKeys: String, CodingKey {
                        case summary, images
                        case clickUrl = "click_url"
                        case lastMtimeText = "last_mtime_text"
                    }
                }
            }

            struct AtMember: Decodable, Sendable {
                let mid: FlexibleID?
                let uname: String?
            }

            struct FlexibleID: Decodable, Sendable {
                let value: Int?

                init(from decoder: Decoder) throws {
                    let container = try? decoder.singleValueContainer()
                    if let intValue = try? container?.decode(Int.self) {
                        value = intValue
                    } else if let stringValue = try? container?.decode(String.self) {
                        value = Int(stringValue)
                    } else {
                        value = nil
                    }
                }
            }

            struct CommentEmote: Decodable, Sendable {
                let url: String
                let meta: EmoteMeta?
            }

            struct JumpTarget: Decodable, Sendable {
                let title: String?
                let pcUrl: String?
                let appUrlSchema: String?

                enum CodingKeys: String, CodingKey {
                    case title
                    case pcUrl = "pc_url"
                    case appUrlSchema = "app_url_schema"
                }
            }

            private static let commentURLRegex = try? NSRegularExpression(
                pattern: #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
            )
            private static let commentAVRegex = try? NSRegularExpression(
                pattern: #"(?<![A-Za-z0-9])([Aa][Vv]\d{1,12})(?![A-Za-z0-9])"#
            )

            private static func normalizedJumpURL(_ raw: String?) -> URL? {
                guard let raw else { return nil }
                var trimmed = HTMLEntityDecoder.decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.hasPrefix("//") {
                    trimmed = "https:" + trimmed
                }
                let lower = trimmed.lowercased()
                guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("bilibili://") else {
                    return nil
                }
                return URL(string: trimmed) ?? URL(string: trimmed, encodingInvalidCharacters: true)
            }

            private static func prepareLinks(
                message: String,
                jumpUrl: [String: JumpTarget]?,
                atNameToMid: [String: FlexibleID]?,
                members: [AtMember]?
            ) -> [String: URL] {
                var out: [String: URL] = [:]
                for (rawKey, target) in jumpUrl ?? [:] {
                    let key = HTMLEntityDecoder.decode(rawKey)
                    guard !key.isEmpty else { continue }
                    if let url = normalizedJumpURL(key) {
                        out[key] = url
                    } else if let url = normalizedJumpURL(target.pcUrl) {
                        out[key] = url
                    } else if let url = normalizedJumpURL(target.appUrlSchema) {
                        out[key] = url
                    } else if let bvid = BiliLinkResolver.normalizedBVID(key),
                              let url = URL(string: "https://www.bilibili.com/video/\(bvid)") {
                        out[key] = url
                    } else if let aid = BiliLinkResolver.parsedAID(key, allowBareNumeric: false),
                              let url = URL(string: "https://www.bilibili.com/video/av\(aid)") {
                        out[key] = url
                    }
                }
                for (name, id) in atNameToMid ?? [:] {
                    if let mid = id.value {
                        out["@\(name)"] = URL(string: "https://space.bilibili.com/\(mid)")
                    }
                }
                for member in members ?? [] {
                    if let mid = member.mid?.value, let name = member.uname,
                       out["@\(name)"] == nil {
                        out["@\(name)"] = URL(string: "https://space.bilibili.com/\(mid)")
                    }
                }
                let nsMessage = message as NSString
                let fullRange = NSRange(location: 0, length: nsMessage.length)
                if let commentURLRegex {
                    for match in commentURLRegex.matches(in: message, range: fullRange) {
                        var raw = nsMessage.substring(with: match.range)
                        while let last = raw.last, ".,;:!?)]}。，！？；：】」》）".contains(last) {
                            raw.removeLast()
                        }
                        if out[raw] == nil, let url = URL(string: raw) {
                            out[raw] = url
                        }
                    }
                }
                for key in message.bvIDs where out[key] == nil {
                    if let bvid = BiliLinkResolver.normalizedBVID(key) {
                        out[key] = URL(string: "https://www.bilibili.com/video/\(bvid)")
                    }
                }
                if let commentAVRegex {
                    for match in commentAVRegex.matches(in: message, range: fullRange) {
                        let token = nsMessage.substring(with: match.range(at: 1))
                        if out[token] == nil,
                           let aid = BiliLinkResolver.parsedAID(token, allowBareNumeric: false) {
                            out[token] = URL(string: "https://www.bilibili.com/video/av\(aid)")
                        }
                    }
                }
                return out
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = HTMLEntityDecoder.decode(try container.decode(String.self, forKey: .message))
                pictures = try container.decodeIfPresent([CommentPicture].self, forKey: .pictures)
                emote = try container.decodeIfPresent([String: CommentEmote].self, forKey: .emote)
                jumpUrl = try container.decodeIfPresent([String: JumpTarget].self, forKey: .jumpUrl)
                atNameToMid = try container.decodeIfPresent([String: FlexibleID].self, forKey: .atNameToMid)
                members = try container.decodeIfPresent([AtMember].self, forKey: .members)
                vote = try container.decodeIfPresent(CommentVote.self, forKey: .vote)
                richText = try container.decodeIfPresent(RichTextInfo.self, forKey: .richText)
                displayMessage = Self.prepareDisplayMessage(message)
                resolvedLinks = Self.prepareLinks(
                    message: message, jumpUrl: jumpUrl, atNameToMid: atNameToMid, members: members
                )
                emoteURLs = (emote ?? [:]).mapValues(\.url)
            }

            enum CodingKeys: String, CodingKey {
                case message, pictures, emote, members, vote
                case jumpUrl = "jump_url"
                case atNameToMid = "at_name_to_mid"
                case richText = "rich_text"
            }

            struct CommentPicture: Decodable, Sendable {
                let imgSrc: String
                let imgWidth: Int?
                let imgHeight: Int?

                enum CodingKeys: String, CodingKey {
                    case imgSrc = "img_src"
                    case imgWidth = "img_width"
                    case imgHeight = "img_height"
                }
            }
        }

        struct ReplyControl: Decodable, Sendable {
            let location: String?
        }

        struct CommentMember: Decodable, Sendable {
            let mid: String
            let uname: String
            let avatar: String
            let sign: String?
            let levelInfo: LevelInfo?
            let vip: CommentMemberVip?
            let officialVerify: CommentMemberOfficialVerify?
            let userSailing: UserSailing?

            struct LevelInfo: Decodable, Sendable {
                let currentLevel: Int?

                enum CodingKeys: String, CodingKey {
                    case currentLevel = "current_level"
                }
            }

            struct UserSailing: Decodable, Sendable {
                let cardbg: CardBg?

                private enum CardBgKey: String, CodingKey {
                    case cardBg = "card_bg"
                    case cardbg
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CardBgKey.self)
                    if let bg = try container.decodeIfPresent(CardBg.self, forKey: .cardBg) {
                        self.cardbg = bg
                    } else {
                        self.cardbg = try container.decodeIfPresent(CardBg.self, forKey: .cardbg)
                    }
                }

                struct CardBg: Decodable, Sendable {
                    let name: String?
                    let image: String?
                    let fan: Fan?

                    struct Fan: Decodable, Sendable {
                        let isFan: Int?
                        let number: Int?
                        let color: String?
                        let numDesc: String?

                        enum CodingKeys: String, CodingKey {
                            case number, color
                            case isFan = "is_fan"
                            case numDesc = "num_desc"
                        }
                    }
                }
            }

            enum CodingKeys: String, CodingKey {
                case mid, uname, avatar, sign, vip
                case levelInfo = "level_info"
                case officialVerify = "official_verify"
                case userSailing = "user_sailing"
            }
        }

        struct UpAction: Decodable, Sendable {
            let like: Bool?
            let reply: Bool?
        }

        enum CodingKeys: String, CodingKey {
            case rpid, mid, oid, type, content, ctime, like, action, rcount, member, replies
            case replyControl = "reply_control"
            case upAction = "up_action"
        }
    }

    struct CommentPage: Decodable, Sendable {
        let count: Int?
        let num: Int?
        let size: Int?
    }
}

struct CommentMemberVip: Decodable, Sendable {
    let vipType: Int?
    let vipStatus: Int?

    private enum CodingKeys: String, CodingKey {
        case vipType
        case vipStatus
        case vipTypeSnake = "vip_type"
        case vipStatusSnake = "vip_status"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vipType = (try? container.decodeIfPresent(Int.self, forKey: .vipType))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .vipTypeSnake))
        vipStatus = (try? container.decodeIfPresent(Int.self, forKey: .vipStatus))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .vipStatusSnake))
    }
}

struct CommentMemberOfficialVerify: Decodable, Sendable {
    let type: Int?
    let desc: String?
}

struct PostCommentResult: Decodable, Sendable {
    let rpid: Int?
    let rpidStr: String?
    let reply: CommentResult.CommentItem?

    enum CodingKeys: String, CodingKey {
        case rpid
        case rpidStr = "rpid_str"
        case reply
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try container.decodeIfPresent(Int.self, forKey: .rpid)
        rpidStr = try container.decodeIfPresent(String.self, forKey: .rpidStr)
        reply = try? container.decode(CommentResult.CommentItem.self, forKey: .reply)
    }
}

extension PostCommentResult {
    func acceptedTopLevelReply(
        matching rpid: Int?, root: Int?, parent: Int?
    ) -> CommentResult.CommentItem? {
        guard root == nil, parent == nil, let rpid, let reply, reply.rpid == rpid else { return nil }
        return reply
    }
}

extension Array where Element == CommentResult.CommentItem {
    @discardableResult
    mutating func insertAcceptedTopLevelCommentIfNeeded(_ item: CommentResult.CommentItem) -> Bool {
        guard !contains(where: { $0.rpid == item.rpid }) else { return false }
        let index = firstIndex(where: { !$0.isPinned }) ?? count
        insert(item, at: index)
        return true
    }
}

struct LikeResult: Decodable, Sendable {}

struct TripleLikeResult: Decodable, Sendable, Equatable {
    let like: Bool?
    let coin: Bool?
    let fav: Bool?
    let multiply: Int?
}

struct CoinResult: Decodable, Sendable {
    let like: Bool?
}

struct FavoriteResult: Decodable, Sendable {
    let prompt: Bool?
}

struct ShareResult: Decodable, Sendable {}

struct HasLikedResult: Decodable, Sendable {
    let liked: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        liked = try? container.decode(Int.self)
    }
}

struct HasCoinedResult: Decodable, Sendable {
    let multiply: Int?
}

struct HasFavouredResult: Decodable, Sendable {
    let favoured: Bool?
}

struct DefaultFolderResult: Decodable, Sendable {
    let list: [FolderItem]?

    var firstId: Int? { list?.first?.id }

    struct FolderItem: Decodable, Sendable {
        let id: Int
    }
}

struct FavFolderListResult: Decodable, Sendable {
    let list: [FavFolder]?

    struct FavFolder: Decodable, Sendable, Identifiable {
        let id: Int
        let title: String
        let mediaCount: Int?
        let favState: Int?

        var containsVideo: Bool { (favState ?? 0) == 1 }

        enum CodingKeys: String, CodingKey {
            case id, title
            case mediaCount = "media_count"
            case favState = "fav_state"
        }
    }
}

// MARK: - Home Sections

struct PGCIndexResult: Decodable, Sendable {
    let list: [PGCItem]?
    let hasNext: Int?

    struct PGCItem: Decodable, Sendable, Identifiable {
        let seasonId: Int
        let title: String
        let cover: String
        let badge: String?
        let badgeType: Int?
        let order: String?
        let indexShow: String?

        var id: Int { seasonId }

        enum CodingKeys: String, CodingKey {
            case title, cover, badge, order
            case seasonId = "season_id"
            case badgeType = "badge_type"
            case indexShow = "index_show"
        }
    }

    enum CodingKeys: String, CodingKey {
        case list
        case hasNext = "has_next"
    }
}

// MARK: - Messages

struct MessageUnreadCount: Decodable, Sendable {
    let at: Int?
    let reply: Int?
    let like: Int?
    let sysMsg: Int?
    let up: Int?

    enum CodingKeys: String, CodingKey {
        case at, reply, like, up
        case sysMsg = "sys_msg"
    }
}

struct ReplyMessageResult: Decodable, Sendable {
    let cursor: MsgCursor?
    let items: [ReplyMsgItem]?

    struct MsgCursor: Decodable, Sendable {
        let id: Int?
        let time: Int?
        let isEnd: Bool?

        enum CodingKeys: String, CodingKey {
            case id, time
            case isEnd = "is_end"
        }
    }

    struct ReplyMsgItem: Decodable, Sendable, Identifiable {
        let id: Int
        let user: MsgUser?
        let item: ReplyItem?
        let counts: Int?
        let replyTime: Int?
        let isMulti: Int?

        struct ReplyItem: Decodable, Sendable {
            let subjectId: Int?
            let rootId: Int?
            let sourceId: Int?
            let targetId: Int?
            let sourceContent: String?
            let targetReplyContent: String?
            let title: String?
            let uri: String?
            let type: String?
            let businessId: Int?
            let business: String?
            let desc: String?
            let image: String?
            let nativeUri: String?

            enum CodingKeys: String, CodingKey {
                case title, uri, type, business, desc, image
                case subjectId = "subject_id"
                case rootId = "root_id"
                case sourceId = "source_id"
                case targetId = "target_id"
                case sourceContent = "source_content"
                case targetReplyContent = "target_reply_content"
                case businessId = "business_id"
                case nativeUri = "native_uri"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, user, item, counts
            case replyTime = "reply_time"
            case isMulti = "is_multi"
        }
    }
}

struct AtMessageResult: Decodable, Sendable {
    let cursor: ReplyMessageResult.MsgCursor?
    let items: [AtMsgItem]?

    struct AtMsgItem: Decodable, Sendable, Identifiable {
        let id: Int
        let user: MsgUser?
        let item: AtItem?
        let atTime: Int?

        struct AtItem: Decodable, Sendable {
            let subjectId: Int?
            let rootId: Int?
            let sourceId: Int?
            let targetId: Int?
            let businessId: Int?
            let sourceContent: String?
            let title: String?
            let uri: String?
            let type: String?
            let business: String?
            let nativeUri: String?
            let image: String?

            enum CodingKeys: String, CodingKey {
                case title, uri, type, business, image
                case subjectId = "subject_id"
                case rootId = "root_id"
                case sourceId = "source_id"
                case targetId = "target_id"
                case businessId = "business_id"
                case sourceContent = "source_content"
                case nativeUri = "native_uri"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, user, item
            case atTime = "at_time"
        }
    }
}

struct LikeMessageResult: Decodable, Sendable {
    let total: LikeTotal?
    let latest: LikeLatest?

    struct LikeTotal: Decodable, Sendable {
        let cursor: ReplyMessageResult.MsgCursor?
        let items: [LikeMsgItem]?
    }

    struct LikeLatest: Decodable, Sendable {
        let items: [LikeMsgItem]?
    }

    struct LikeMsgItem: Decodable, Sendable, Identifiable {
        let id: Int
        let users: [MsgUser]?
        let item: LikeItem?
        let counts: Int?
        let likeTime: Int?

        struct LikeItem: Decodable, Sendable {
            let itemId: Int?
            let title: String?
            let uri: String?
            let type: String?
            let business: String?
            let image: String?
            let nativeUri: String?
            let desc: String?

            enum CodingKeys: String, CodingKey {
                case title, uri, type, business, image, desc
                case itemId = "item_id"
                case nativeUri = "native_uri"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, users, item, counts
            case likeTime = "like_time"
        }
    }
}

struct IMUserInfo: Decodable, Sendable {
    let mid: Int
    let name: String?
    let face: String?

    enum CodingKeys: String, CodingKey {
        case mid, uid, name, uname, face
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = (try? container.decode(Int.self, forKey: .mid))
            ?? (try? container.decode(Int.self, forKey: .uid))
            ?? 0
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .uname))
        face = try? container.decode(String.self, forKey: .face)
    }
}

struct MsgUser: Decodable, Sendable {
    let mid: Int
    let nickname: String?
    let avatar: String?

    var displayName: String { nickname ?? "uid:\(mid)" }
    var avatarURL: String { avatar?.httpsURL ?? "" }

    enum CodingKeys: String, CodingKey {
        case mid, nickname, avatar, face
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = (try? container.decode(Int.self, forKey: .mid)) ?? 0
        nickname = try? container.decode(String.self, forKey: .nickname)
        let decodedAvatar = try? container.decode(String.self, forKey: .avatar)
        let decodedFace = try? container.decode(String.self, forKey: .face)
        avatar = decodedAvatar ?? decodedFace
    }
}

extension String {
    var httpsURL: String {
        if hasPrefix("//") { return "https:" + self }
        if hasPrefix("http://") { return "https://" + dropFirst("http://".count) }
        return self
    }

    private static let bvIDRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Bb][Vv][A-HJ-NP-Za-km-z1-9]{10})(?![A-Za-z0-9])"#
    )

    var bvIDs: [String] {
        guard let regex = Self.bvIDRegex else { return [] }
        let ns = self as NSString
        guard ns.length >= 12 else { return [] }
        return regex
            .matches(in: self, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    func biliResized(toPixel px: CGSize, crop: Bool = false) -> String {
        let normalized = httpsURL
        guard normalized.contains("hdslb.com") || normalized.contains("biliimg.com"),
              px.width >= 1, px.height >= 1 else { return normalized }
        let base = normalized.firstIndex(of: "@").map { String(normalized[..<$0]) } ?? normalized
        let box = "\(Int(px.width.rounded()))w_\(Int(px.height.rounded()))h"
        return "\(base)@\(box)\(crop ? "_1c" : "").webp"
    }
}

struct SystemNotifyResult: Decodable, Sendable {
    let systemNotifyList: [SystemNotifyItem]?

    struct ParsedContent: Equatable, Sendable {
        let text: String
        let url: String?
        let linkLabel: String?
    }

    struct Source: Decodable, Sendable {
        let name: String?
        let logo: String?
    }

    struct Publisher: Decodable, Sendable {
        let mid: Int?
        let name: String?
        let face: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: PublisherCodingKeys.self)
            mid = SystemNotifyResult.decodeInt(container, forKey: .mid)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            face = try? container.decodeIfPresent(String.self, forKey: .face)
        }
    }

    private enum PublisherCodingKeys: String, CodingKey {
        case mid, name, face
    }

    struct SystemNotifyItem: Decodable, Sendable, Identifiable {
        let id: Int
        let cursor: Int?
        let title: String?
        let content: String?
        let displayContent: String
        let notifyTime: Int?
        let timeAtText: String?
        let type: Int?
        let isStation: Bool?
        let cardType: Int?
        let cardBrief: String?
        let mcCode: String?
        let mcId: Int?
        let url: String?
        let jumpUri: String?
        let resolvedURL: String?
        let linkLabel: String?
        let source: Source?
        let publisher: Publisher?

        var displayTitle: String {
            for candidate in [title, source?.name, publisher?.name] {
                if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                    return trimmed
                }
            }
            return String(localized: "System")
        }

        var avatarURL: String? {
            for candidate in [source?.logo, publisher?.face] {
                if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                    return trimmed.httpsURL
                }
            }
            return nil
        }

        var timestampText: String? {
            if let notifyTime { return FormatUtils.timeAgo(from: notifyTime) }
            guard let timeAtText = timeAtText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !timeAtText.isEmpty else { return nil }
            return timeAtText
        }

        var actionURL: URL? {
            resolvedURL.flatMap(URL.init(string:))
        }

        enum CodingKeys: String, CodingKey {
            case id, cursor, title, content, type, url, source, publisher
            case notifyTime = "notify_time"
            case timeAt = "time_at"
            case isStation = "is_station"
            case cardType = "card_type"
            case cardBrief = "card_brief"
            case mcCode = "mc"
            case mcId = "mc_id"
            case jumpUri = "jump_uri"
            case cardUri = "card_uri"
            case cardLinkUri = "card_link_uri"
            case notifyCursor = "notify_cursor"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedCursor = SystemNotifyResult.decodeInt(container, forKey: .cursor)
                ?? SystemNotifyResult.decodeInt(container, forKey: .notifyCursor)
            cursor = decodedCursor
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            let rawContent = try? container.decodeIfPresent(String.self, forKey: .content)
            content = rawContent
            let rawTimeAtText = try? container.decodeIfPresent(String.self, forKey: .timeAt)
            timeAtText = rawTimeAtText
            notifyTime = SystemNotifyResult.decodeTimestamp(container, forKey: .notifyTime)
                ?? SystemNotifyResult.decodeTimestamp(container, forKey: .timeAt)
                ?? SystemNotifyResult.parseShanghaiTimestamp(rawTimeAtText)
            type = SystemNotifyResult.decodeInt(container, forKey: .type)
            isStation = SystemNotifyResult.decodeBool(container, forKey: .isStation)
            cardType = SystemNotifyResult.decodeInt(container, forKey: .cardType)
            cardBrief = try? container.decodeIfPresent(String.self, forKey: .cardBrief)
            mcCode = SystemNotifyResult.decodeStringOrInt(container, forKey: .mcCode)
            mcId = SystemNotifyResult.decodeInt(container, forKey: .mcId)
            let directURL = SystemNotifyResult.nonEmptyString(container, forKey: .url)
            let directJump = SystemNotifyResult.nonEmptyString(container, forKey: .jumpUri)
                ?? SystemNotifyResult.nonEmptyString(container, forKey: .cardLinkUri)
                ?? SystemNotifyResult.nonEmptyString(container, forKey: .cardUri)
            url = directURL
            jumpUri = directJump
            source = try? container.decodeIfPresent(Source.self, forKey: .source)
            publisher = try? container.decodeIfPresent(Publisher.self, forKey: .publisher)
            let parsed = SystemNotifyResult.parseContent(rawContent)
            displayContent = parsed.text
            linkLabel = parsed.linkLabel
            resolvedURL = BiliIMMessageParser.normalizeURL(directURL ?? directJump ?? parsed.url)
            id = SystemNotifyResult.decodeInt(container, forKey: .id)
                ?? decodedCursor
                ?? SystemNotifyResult.stableNotifyID(title: title, content: rawContent, timeAt: rawTimeAtText)
        }
    }

    enum CodingKeys: String, CodingKey {
        case systemNotifyList = "system_notify_list"
        case items
    }

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            systemNotifyList = []
            return
        }
        if let directItems = try? decoder.singleValueContainer().decode([SystemNotifyItem].self) {
            systemNotifyList = directItems
            return
        }
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            systemNotifyList = []
            return
        }
        if let list = try? container.decode([SystemNotifyItem].self, forKey: .systemNotifyList) {
            systemNotifyList = list
        } else if let list = try? container.decode([SystemNotifyItem].self, forKey: .items) {
            systemNotifyList = list
        } else {
            systemNotifyList = []
        }
    }
}

extension SystemNotifyResult {
    private static let markdownLinkRegex = try? NSRegularExpression(
        pattern: "\\[([^\\]\\n]+)\\]\\(((?:https?:|//|bilibili://)[^)\\s]+)\\)"
    )

    static func parseContent(_ raw: String?) -> ParsedContent {
        guard let raw else { return ParsedContent(text: "", url: nil, linkLabel: nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedContent(text: "", url: nil, linkLabel: nil) }

        if let fullDict = BiliIMMessageParser.parseJSONObject(from: trimmed) as? [String: Any] {
            let directURL = BiliIMMessageParser.extractActionURL(from: fullDict)
            let directLabel = BiliIMMessageParser.firstString(in: fullDict, keys: ["text", "title", "name", "label"])
            let body = BiliIMMessageParser.firstString(
                in: fullDict, keys: ["content", "text", "desc", "summary", "brief", "title"]
            ) ?? ""
            let nested = parseInlineMarkup(body)
            return ParsedContent(
                text: nested.text.isEmpty ? (directLabel ?? "") : nested.text,
                url: directURL ?? nested.url,
                linkLabel: nested.linkLabel ?? (directURL != nil ? directLabel : nil)
            )
        }
        if let fullArray = BiliIMMessageParser.parseJSONObject(from: trimmed) as? [Any],
           case .systemNotice(let text, let url) = BiliIMMessageParser.parseNoticeSegments(
               fullArray, fallbackURL: nil
           ) {
            return ParsedContent(
                text: text == String(localized: "[Notification]") ? "" : text,
                url: url,
                linkLabel: nil
            )
        }
        if BiliIMMessageParser.looksLikeTruncatedJSON(trimmed) {
            let extracted = BiliIMMessageParser.extractFirstTruncatedField(from: trimmed) ?? ""
            return ParsedContent(
                text: extracted,
                url: BiliIMMessageParser.extractFirstURL(in: trimmed),
                linkLabel: nil
            )
        }
        return parseInlineMarkup(trimmed)
    }

    private static func parseInlineMarkup(_ input: String) -> ParsedContent {
        var foundURL: String?
        var foundLabel: String?
        var text = replaceDoubleBraceLinks(in: input, url: &foundURL, label: &foundLabel)
        text = replaceEmbeddedJSONTokens(in: text, url: &foundURL, label: &foundLabel)
        text = replaceMarkdownLinks(in: text, url: &foundURL, label: &foundLabel)
        if foundURL == nil { foundURL = BiliIMMessageParser.extractFirstURL(in: text) }
        return ParsedContent(
            text: normalizeLines(text),
            url: foundURL.flatMap(BiliIMMessageParser.normalizeURL),
            linkLabel: foundLabel
        )
    }

    private static func replaceDoubleBraceLinks(
        in input: String, url: inout String?, label: inout String?
    ) -> String {
        guard input.contains("#{") else { return input }
        let chars = Array(input)
        var output = ""
        output.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            if chars[index] == "#", index + 1 < chars.count, chars[index + 1] == "{",
               let firstEnd = findMatchingBrace(in: chars, from: index + 1),
               firstEnd + 1 < chars.count, chars[firstEnd + 1] == "{",
               let secondEnd = findMatchingBrace(in: chars, from: firstEnd + 1) {
                let rawLabel = stripQuotes(String(chars[(index + 2) ..< firstEnd]))
                let secondBrace = String(chars[(firstEnd + 1) ... secondEnd])
                if let resolved = resolveDoubleBraceTarget(secondBrace) {
                    if url == nil, let resolvedURL = resolved {
                        url = resolvedURL
                        if !rawLabel.isEmpty { label = rawLabel }
                    }
                    output.append(rawLabel)
                    index = secondEnd + 1
                    continue
                }
            }
            output.append(chars[index])
            index += 1
        }
        return output
    }

    private static func resolveDoubleBraceTarget(_ secondBrace: String) -> String?? {
        if let dict = BiliIMMessageParser.parseJSONObject(from: secondBrace) as? [String: Any],
           isNotificationTokenDict(dict) {
            let resolved = BiliIMMessageParser.extractActionURL(from: dict)
                ?? BiliIMMessageParser.firstString(in: dict, keys: ["all_uri", "web_uri", "ios", "ios_uri"])
                    .flatMap(BiliIMMessageParser.normalizeURL)
            return .some(resolved)
        }
        guard secondBrace.count >= 2 else { return nil }
        let inner = String(secondBrace.dropFirst().dropLast())
        guard let normalized = BiliIMMessageParser.normalizeURL(stripQuotes(inner)) else { return nil }
        return .some(normalized)
    }

    private static func replaceEmbeddedJSONTokens(
        in input: String, url: inout String?, label: inout String?
    ) -> String {
        guard input.contains("{") else { return input }
        let chars = Array(input)
        var output = ""
        output.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            let hasHash = chars[index] == "#" && index + 1 < chars.count && chars[index + 1] == "{"
            let start = hasHash ? index + 1 : index
            if chars[start] == "{", let end = findMatchingBrace(in: chars, from: start),
               let dict = BiliIMMessageParser.parseJSONObject(from: String(chars[start ... end])) as? [String: Any],
               isNotificationTokenDict(dict) {
                let tokenLabel = BiliIMMessageParser.firstString(in: dict, keys: ["text", "title", "name", "label"])
                    ?? ""
                if url == nil, let tokenURL = BiliIMMessageParser.extractActionURL(from: dict) {
                    url = tokenURL
                    if !tokenLabel.isEmpty { label = tokenLabel }
                }
                output.append(tokenLabel)
                index = end + 1 + (hasHash && end + 1 < chars.count && chars[end + 1] == "#" ? 1 : 0)
                continue
            }
            output.append(chars[index])
            index += 1
        }
        return output
    }

    private static func replaceMarkdownLinks(
        in input: String, url: inout String?, label: inout String?
    ) -> String {
        guard let regex = markdownLinkRegex else { return input }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }
        let result = NSMutableString(string: input)
        var firstURL: String?
        var firstLabel: String?
        for match in matches.reversed() {
            let textPart = nsInput.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let urlPart = nsInput.substring(with: match.range(at: 2))
            if let normalized = BiliIMMessageParser.normalizeURL(urlPart) {
                firstURL = normalized
                firstLabel = textPart.isEmpty ? nil : textPart
            }
            result.replaceCharacters(in: match.range, with: textPart)
        }
        if url == nil, let firstURL {
            url = firstURL
            label = firstLabel
        }
        return result as String
    }

    private static func findMatchingBrace(in chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for idx in start ..< chars.count {
            let char = chars[idx]
            if escaped { escaped = false; continue }
            if inString {
                if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            if char == "\"" { inString = true } else if char == "{" { depth += 1 } else if char == "}" {
                depth -= 1
                if depth == 0 { return idx }
            }
        }
        return nil
    }

    private static func isNotificationTokenDict(_ dict: [String: Any]) -> Bool {
        let tokenKeys: Set<String> = [
            "web", "url", "uri", "jump_uri", "jump_url", "link", "text", "ios", "android", "app", "name",
        ]
        return dict.keys.contains { tokenKeys.contains($0) }
    }

    static func parseShanghaiTimestamp(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let numeric = Int(trimmed) { return normalizeEpochSeconds(numeric) }

        let normalized = trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "T", with: " ")
        let sections = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard sections.count == 2 else { return nil }
        let dateParts = sections[0].split(separator: "-").compactMap { Int($0) }
        let timeParts = sections[1].prefix { $0.isNumber || $0 == ":" }.split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, timeParts.count >= 2 else { return nil }
        let second = timeParts.count >= 3 ? timeParts[2] : 0
        guard (1 ... 12).contains(dateParts[1]), (1 ... 31).contains(dateParts[2]),
              (0 ... 23).contains(timeParts[0]), (0 ... 59).contains(timeParts[1]),
              (0 ... 59).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
        let components = DateComponents(
            year: dateParts[0], month: dateParts[1], day: dateParts[2],
            hour: timeParts[0], minute: timeParts[1], second: second
        )
        return calendar.date(from: components).map { Int($0.timeIntervalSince1970) }
    }

    private static func normalizeEpochSeconds(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        if value > 4_000_000_000_000 { return value / 1_000_000 }
        if value > 4_000_000_000 { return value / 1_000 }
        return value
    }

    private static func decodeInt<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return Int(exactly: value) }
        if let text = try? container.decode(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func decodeTimestamp<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> Int? {
        decodeInt(container, forKey: key).flatMap(normalizeEpochSeconds)
    }

    private static func decodeBool<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> Bool? {
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        return decodeInt(container, forKey: key).map { $0 != 0 }
    }

    private static func decodeStringOrInt<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> String? {
        if let text = nonEmptyString(container, forKey: key) { return text }
        return decodeInt(container, forKey: key).map(String.init)
    }

    private static func nonEmptyString<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> String? {
        guard let text = try? container.decode(String.self, forKey: key) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableNotifyID(title: String?, content: String?, timeAt: String?) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(title ?? "")|\(content ?? "")|\(timeAt ?? "")".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let positive = Int(bitPattern: UInt(truncatingIfNeeded: hash & 0x7FFF_FFFF_FFFF_FFFF))
        return positive == 0 ? 1 : positive
    }

    private static func stripQuotes(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func normalizeLines(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionListResult: Decodable, Sendable {
    let sessionList: [SessionItem]?
    let hasMore: Int?

    struct SessionItem: Decodable, Sendable, Identifiable {
        let talkerId: Int
        let sessionType: Int?
        let atSeqno: Int?
        let topTs: Int?
        let groupName: String?
        let groupCover: String?
        let isFollow: Int?
        let isDnd: Int?
        let ackSeqno: Int?
        let ackTs: Int?
        let sessionTs: Int?
        let unreadCount: Int?
        let lastMsg: LastMsg?
        let systemMsgType: Int?
        let accountInfo: AccountInfo?

        var id: Int { talkerId }

        struct LastMsg: Decodable, Sendable {
            let senderUid: Int?
            let receiverType: Int?
            let receiverId: Int?
            let msgType: Int?
            let content: String?
            let msgSeqno: Int?
            let timestamp: Int?
            let msgKey: Int?
            let msgStatus: Int?
            let notifyCode: String?
            let displayContent: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                senderUid = try container.decodeIfPresent(Int.self, forKey: .senderUid)
                receiverType = try container.decodeIfPresent(Int.self, forKey: .receiverType)
                receiverId = try container.decodeIfPresent(Int.self, forKey: .receiverId)
                msgType = try container.decodeIfPresent(Int.self, forKey: .msgType)
                let rawContent = try container.decodeIfPresent(String.self, forKey: .content)
                content = rawContent
                msgSeqno = try container.decodeIfPresent(Int.self, forKey: .msgSeqno)
                timestamp = try container.decodeIfPresent(Int.self, forKey: .timestamp)
                msgKey = try container.decodeIfPresent(Int.self, forKey: .msgKey)
                msgStatus = try container.decodeIfPresent(Int.self, forKey: .msgStatus)
                notifyCode = try container.decodeIfPresent(String.self, forKey: .notifyCode)
                displayContent = BiliIMMessageParser.previewText(
                    msgType: msgType,
                    rawContent: rawContent
                )
            }

            enum CodingKeys: String, CodingKey {
                case content, timestamp
                case senderUid = "sender_uid"
                case receiverType = "receiver_type"
                case receiverId = "receiver_id"
                case msgType = "msg_type"
                case msgSeqno = "msg_seqno"
                case msgKey = "msg_key"
                case msgStatus = "msg_status"
                case notifyCode = "notify_code"
            }
        }

        struct AccountInfo: Decodable, Sendable {
            let name: String?
            let face: String?
        }

        enum CodingKeys: String, CodingKey {
            case talkerId = "talker_id"
            case sessionType = "session_type"
            case atSeqno = "at_seqno"
            case topTs = "top_ts"
            case groupName = "group_name"
            case groupCover = "group_cover"
            case isFollow = "is_follow"
            case isDnd = "is_dnd"
            case ackSeqno = "ack_seqno"
            case ackTs = "ack_ts"
            case sessionTs = "session_ts"
            case unreadCount = "unread_count"
            case lastMsg = "last_msg"
            case systemMsgType = "system_msg_type"
            case accountInfo = "account_info"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionList = "session_list"
        case hasMore = "has_more"
    }
}

struct SessionMsgsResult: Decodable, Sendable {
    let messages: [ChatMessage]?
    let hasMore: Int?
    let minSeqno: Int?
    let maxSeqno: Int?

    struct ChatMessage: Decodable, Sendable, Identifiable {
        let senderUid: Int?
        let receiverId: Int?
        let msgType: Int?
        let content: String?
        let msgSeqno: Int?
        let timestamp: Int?
        let msgKey: Int?
        let msgStatus: Int?

        var id: Int { msgKey ?? msgSeqno ?? 0 }

        var textContent: String {
            guard let content, let data = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return content ?? ""
            }
            return json["content"] as? String ?? content
        }

        var imageURL: String? {
            guard msgType == 2, let content, let data = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["url"] as? String
        }

        var cardInfo: (title: String, subtitle: String?, thumb: String?, url: String?)? {
            guard msgType != 1, msgType != 2, msgType != 5,
                  let content, let data = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = (json["title"] as? String) ?? (json["headline"] as? String),
                  !title.isEmpty else {
                return nil
            }
            let subtitle = (json["text"] as? String)
                ?? (json["desc"] as? String)
                ?? (json["source_desc"] as? String)
                ?? (json["author"] as? String)
            let thumb = (json["thumb"] as? String)
                ?? (json["cover"] as? String)
                ?? (json["pic"] as? String)
                ?? (json["image_url"] as? String)
            let url = (json["url"] as? String)
                ?? (json["jump_uri"] as? String)
                ?? (json["jump_url"] as? String)
            return (title, subtitle, thumb, url)
        }

        enum CodingKeys: String, CodingKey {
            case content, timestamp
            case senderUid = "sender_uid"
            case receiverId = "receiver_id"
            case msgType = "msg_type"
            case msgSeqno = "msg_seqno"
            case msgKey = "msg_key"
            case msgStatus = "msg_status"
        }
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
        case minSeqno = "min_seqno"
        case maxSeqno = "max_seqno"
    }
}

struct SendMsgResult: Decodable, Sendable {
    let msgKey: Int?

    enum CodingKeys: String, CodingKey {
        case msgKey = "msg_key"
    }
}

// MARK: - User Space Extra

struct RelationStatResult: Decodable, Sendable {
    let mid: Int?
    let following: Int?
    let follower: Int?
    let whisper: Int?
    let black: Int?
}

struct UpStatResult: Decodable, Sendable {
    let likes: Int?
    let archive: ArchiveView?

    struct ArchiveView: Decodable, Sendable {
        let view: Int?
    }
}

struct UserVideoResult: Decodable, Sendable {
    let list: VideoList?
    let page: PageInfo?

    struct VideoList: Decodable, Sendable {
        let vlist: [UserVideoItem]?
    }

    struct UserVideoItem: Decodable, Sendable, Identifiable {
        let aid: Int
        let bvid: String?
        let title: String
        let pic: String?
        let length: String?
        let play: Int?
        let comment: Int?
        let created: Int?
        let description: String?

        var id: Int { aid }
    }

    struct PageInfo: Decodable, Sendable {
        let pn: Int?
        let ps: Int?
        let count: Int?
    }
}

// MARK: - Rankings

struct RankingResult: Decodable, Sendable {
    let list: [RankItem]?
    let note: String?

    struct RankItem: Decodable, Sendable, Identifiable {
        let aid: Int
        let bvid: String
        let title: String
        let pic: String
        let cover43: String?
        let duration: Int?
        let dimension: VideoInfo.Dimension?
        let owner: VideoInfo.VideoOwner?
        let stat: VideoInfo.VideoStat?
        let score: Int?
        let tname: String?

        var id: Int { aid }

        var mobileCoverURL: String? { MobileCoverSelection.firstUsable(cover43) }
    }
}

// MARK: - Emotes & Comment Images

struct EmoteMeta: Decodable, Sendable {
    let size: Int?
    let alias: String?
}

struct EmotePanelResult: Decodable, Sendable {
    let packages: [EmotePackage]?

    struct EmotePackage: Decodable, Sendable, Identifiable {
        let id: Int
        let text: String?
        let url: String?
        let type: Int?
        let emote: [EmoteItem]?

        var isTextPackage: Bool { type == 4 }

        var usesLargeStickerGrid: Bool {
            type == 2 || type == 3 || (emote?.contains(where: \.isLargeSticker) ?? false)
        }

        struct EmoteItem: Decodable, Sendable, Identifiable {
            let id: Int
            let text: String
            let url: String
            let type: Int?
            let meta: EmoteMeta?

            var isLargeSticker: Bool { meta?.size == 2 }
        }
    }
}

struct BFSUploadResult: Decodable, Sendable {
    let imageUrl: String
    let imageWidth: Double?
    let imageHeight: Double?

    enum CodingKeys: String, CodingKey {
        case imageUrl = "image_url"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageUrl = try container.decode(String.self, forKey: .imageUrl)
        imageWidth = (try? container.decodeIfPresent(Double.self, forKey: .imageWidth))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .imageWidth)).map(Double.init)
        imageHeight = (try? container.decodeIfPresent(Double.self, forKey: .imageHeight))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .imageHeight)).map(Double.init)
    }
}

struct ComposedPicture: Sendable, Equatable {
    let imgSrc: String
    let width: Double
    let height: Double

    var asJSONObject: [String: Any] {
        ["img_src": imgSrc, "img_width": width, "img_height": height]
    }
}

struct DynamicDetailResult: Decodable, Sendable {
    let item: DynamicFeedResult.DynamicItem?
}

extension DynamicFeedResult.DynamicItem {
    var articleCvid: Int? {
        if basic?.commentType == 12, let idStr = basic?.commentIdStr, let cvid = Int(idStr) {
            return cvid
        }
        let jump = modules?.moduleDynamic?.major?.article?.jumpUrl ?? ""
        if let range = jump.range(of: "cv[0-9]+", options: .regularExpression),
           let cvid = Int(jump[range].dropFirst(2)) {
            return cvid
        }
        return nil
    }
}

struct ArticleViewInfo: Decodable, Sendable {
    let title: String?
    let authorName: String?
    let mid: Int?
    let bannerUrl: String?
    let like: Int?
    let stats: ArticleStats?

    struct ArticleStats: Decodable, Sendable {
        let view: Int?
        let like: Int?
        let reply: Int?
    }

    enum CodingKeys: String, CodingKey {
        case title, stats, mid, like
        case authorName = "author_name"
        case bannerUrl = "banner_url"
    }
}

// MARK: - PGC Season (Bangumi / Anime detail)

struct PGCSeasonInfo: Decodable, Sendable {
    let seasonId: Int?
    let type: Int?
    let title: String?
    let cover: String?
    let evaluate: String?
    let subtitle: String?
    let rating: Rating?
    let stat: Stat?
    let newEp: NewEP?
    let episodes: [Episode]?
    let seasons: [SeasonBrief]?
    let styles: [String]?
    let areas: [Area]?
    let userStatus: UserStatus?

    struct UserStatus: Decodable, Sendable {
        let progress: WatchProgress?

        struct WatchProgress: Decodable, Sendable {
            let lastEpId: Int?
            let lastEpIndex: String?
            let lastTime: Int?

            enum CodingKeys: String, CodingKey {
                case lastEpId = "last_ep_id"
                case lastEpIndex = "last_ep_index"
                case lastTime = "last_time"
            }
        }
    }

    struct Rating: Decodable, Sendable {
        let score: Double?
        let count: Int?
    }

    struct Stat: Decodable, Sendable {
        let views: Int?
        let danmakus: Int?
        let favorites: Int?
    }

    struct NewEP: Decodable, Sendable {
        let desc: String?
    }

    struct Episode: Decodable, Sendable, Identifiable {
        let id: Int
        let aid: Int?
        let cid: Int?
        let bvid: String?
        let title: String?
        let longTitle: String?
        let cover: String?
        let badge: String?
        let skip: SkipInfo?

        struct SkipInfo: Decodable, Sendable {
            let op: SkipRange?
            let ed: SkipRange?

            struct SkipRange: Decodable, Sendable {
                let start: Int?
                let end: Int?
            }
        }

        var indexLabel: String {
            guard let title, !title.isEmpty else { return "EP" }
            return Int(title) != nil ? "第\(title)话" : title
        }

        var displayTitle: String {
            if let longTitle, !longTitle.isEmpty {
                return "\(indexLabel) \(longTitle)"
            }
            return indexLabel
        }

        enum CodingKeys: String, CodingKey {
            case id, aid, cid, bvid, title, cover, badge, skip
            case longTitle = "long_title"
        }
    }

    struct SeasonBrief: Decodable, Sendable, Identifiable {
        let seasonId: Int
        let seasonTitle: String?
        let cover: String?

        var id: Int { seasonId }

        enum CodingKeys: String, CodingKey {
            case cover
            case seasonId = "season_id"
            case seasonTitle = "season_title"
        }
    }

    struct Area: Decodable, Sendable {
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case type, title, cover, evaluate, subtitle, rating, stat, episodes, seasons, styles, areas
        case seasonId = "season_id"
        case newEp = "new_ep"
        case userStatus = "user_status"
    }
}

struct DynamicReactionResult: Decodable, Sendable {
    let items: [ReactionItem]
    let hasMore: Bool
    let offset: String?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items, offset, total
        case hasMore = "has_more"
    }

    struct ReactionItem: Decodable, Sendable {
        let mid: String?
        let name: String?
        let face: String?
        let action: String?
        let desc: String?
        let attend: Int?

        var numericMID: Int? { mid.flatMap(Int.init) }

        private enum CodingKeys: String, CodingKey {
            case mid, name, face, action, desc, attend
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(String.self, forKey: .mid) {
                mid = value
            } else if let value = try? container.decode(Int64.self, forKey: .mid) {
                mid = String(value)
            } else {
                mid = nil
            }
            name = try? container.decode(String.self, forKey: .name)
            face = try? container.decode(String.self, forKey: .face)
            action = try? container.decode(String.self, forKey: .action)
            desc = try? container.decode(String.self, forKey: .desc)
            attend = try? container.decode(Int.self, forKey: .attend)
        }
    }
}

struct RelationTag: Decodable, Sendable, Identifiable {
    let tagid: Int
    let name: String?
    let count: Int?

    var id: Int { tagid }
}

struct RelationTagCreated: Decodable, Sendable {
    let tagid: Int?
}

struct SpaceArchive: Decodable, Sendable, Identifiable {
    let aid: Int
    let bvid: String?
    let title: String?
    let pic: String?
    let duration: Int?
    let dimension: VideoInfo.Dimension?
    let owner: Owner?
    let stat: Stat?

    var id: Int { aid }

    struct Owner: Decodable, Sendable {
        let mid: Int?
        let name: String?
    }

    struct Stat: Decodable, Sendable {
        let view: Int?
    }
}

struct SpaceLikeResult: Decodable, Sendable {
    let list: [SpaceArchive]?
}

struct UserArticlesResult: Decodable, Sendable {
    let articles: [UserArticle]?
    let count: Int?

    struct UserArticle: Decodable, Sendable, Identifiable {
        let id: Int
        let title: String?
        let summary: String?
        let bannerUrl: String?
        let imageUrls: [String]?
        let publishTime: Int?
        let stats: Stats?

        struct Stats: Decodable, Sendable {
            let view: Int?
        }

        enum CodingKeys: String, CodingKey {
            case id, title, summary, stats
            case bannerUrl = "banner_url"
            case imageUrls = "image_urls"
            case publishTime = "publish_time"
        }
    }
}

struct BangumiFollowResult: Decodable, Sendable {
    let list: [FollowedBangumi]?
    let total: Int?

    struct FollowedBangumi: Decodable, Sendable, Identifiable {
        let seasonId: Int
        let title: String?
        let cover: String?
        let newEpShow: String?
        let progressText: String?

        var id: Int { seasonId }

        enum CodingKeys: String, CodingKey {
            case title, cover, progress
            case seasonId = "season_id"
            case newEp = "new_ep"
        }

        enum NestedKeys: String, CodingKey {
            case indexShow = "index_show"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seasonId = try container.decode(Int.self, forKey: .seasonId)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            cover = try? container.decodeIfPresent(String.self, forKey: .cover)
            if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .newEp) {
                newEpShow = try? nested.decodeIfPresent(String.self, forKey: .indexShow)
            } else {
                newEpShow = nil
            }
            if let text = try? container.decodeIfPresent(String.self, forKey: .progress) {
                progressText = text
            } else if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .progress) {
                progressText = try? nested.decodeIfPresent(String.self, forKey: .indexShow)
            } else {
                progressText = nil
            }
        }
    }
}

extension PlayURLResult.DashInfo {
    struct FlacInfo: Decodable, Sendable {
        let display: Bool?
        let audio: DashStream?
    }

    enum CodingKeys: String, CodingKey {
        case duration, video, audio, flac
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        video = try container.decode([DashStream].self, forKey: .video)
        audio = try container.decodeIfPresent([DashStream].self, forKey: .audio)
        flac = (try? container.decodeIfPresent(FlacInfo.self, forKey: .flac)) ?? nil
    }
}
