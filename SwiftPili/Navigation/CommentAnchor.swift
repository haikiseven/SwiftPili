import Foundation

/// The typed identity a comment deep-link carries, and the message payload it
/// is recovered from.
///
/// Split out of `Route.swift` when the comment-anchor navigation work pushed
/// that file past SwiftLint's 500-line `file_length` threshold. The seam is
/// topical rather than arbitrary: `Route.swift` answers "where can the app go
/// and in which column", while these two answer "which reply, in which video,
/// reached from which notification" — a question the message centre asks and
/// the route model only carries.
///
/// No access-level seam to keep: both types are `internal` and already read
/// from `AppCoordinator`, `MessageCenterView` and
/// `VideoDetailViewModel+Comments.swift`.
/// A typed location inside a video comment area. Opaque Bilibili message URIs
/// remain the fallback, but comment-related navigation must carry the target
/// identity separately so the destination can page and highlight it.
struct CommentAnchor: Hashable, Sendable {
    let videoID: VideoID
    /// The comment subject id (the video's aid), not the notification id.
    let oid: Int
    let type: Int
    let rpid: Int
    let rootRpid: Int?
    /// Diagnostics only. It is deliberately not used for routing decisions.
    let source: String?

    var isNestedReply: Bool {
        guard let rootRpid else { return false }
        return rootRpid > 0 && rootRpid != rpid
    }

    init(
        videoID: VideoID,
        oid: Int,
        type: Int = 1,
        rpid: Int,
        rootRpid: Int? = nil,
        source: String? = nil
    ) {
        self.videoID = videoID
        self.oid = oid
        self.type = type
        self.rpid = rpid
        self.rootRpid = rootRpid
        self.source = source
    }

    /// Extract a video comment anchor from a native/web Bilibili URI. The
    /// parser deliberately refuses to guess from display text; a missing
    /// comment id falls back to the existing generic URI route.
    init?(
        url: URL,
        oid: Int? = nil,
        type: Int = 1,
        fallbackRpid: Int? = nil,
        fallbackRootRpid: Int? = nil,
        source: String? = nil
    ) {
        guard let route = BiliURLParser.parse(url),
              case .videoDetail(let routeTarget) = route
        else { return nil }
        let videoID = routeTarget.videoID

        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { result, item in
                result[item.name.lowercased()] = item.value
            } ?? [:]

        func integer(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = values[key], let number = Int(value) { return number }
            }
            return nil
        }

        let fragmentValue = url.fragment?
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first
        let target = integer([
            "rpid", "rpid_str", "comment_id", "comment_id_str",
            "comment_secondary_id", "reply_id", "reply_id_str"
        ]) ?? fragmentValue ?? fallbackRpid
        guard let target, target > 0 else { return nil }

        let resolvedType = integer(["comment_type", "comment_type_id"]) ?? type
        guard resolvedType == 1 else { return nil }
        let resolvedOID = oid
            ?? integer(["oid", "aid", "avid", "video_id", "video_id_str"])
            ?? Self.ifCaseAid(videoID)
        guard let resolvedOID, resolvedOID > 0 else { return nil }

        let root = integer([
            "root", "root_id", "root_rpid", "comment_root_id", "comment_root_id_str"
        ]) ?? fallbackRootRpid
        self.init(
            videoID: videoID,
            oid: resolvedOID,
            type: resolvedType,
            rpid: target,
            rootRpid: root.flatMap { $0 > 0 ? $0 : nil },
            source: source
        )
    }

    private static func ifCaseAid(_ videoID: VideoID) -> Int? {
        guard case .aid(let aid) = videoID else { return nil }
        return aid
    }
}

/// The message endpoints do not share one Swift payload type. They do share
/// the same comment-source vocabulary, however: a subject (video) id, a root
/// id, a source/target reply id, and a web/native URI. Decode that vocabulary
/// once and let every message category use the same admission rules.
struct MessageCommentAnchorPayload: Hashable, Sendable {
    let uri: String?
    let nativeURI: String?
    let subjectID: Int?
    let rootID: Int?
    let sourceID: Int?
    let targetID: Int?
    let itemID: Int?
    let businessID: Int?
    let business: String?
    let source: String?

    init(
        uri: String? = nil,
        nativeURI: String? = nil,
        subjectID: Int? = nil,
        rootID: Int? = nil,
        sourceID: Int? = nil,
        targetID: Int? = nil,
        itemID: Int? = nil,
        businessID: Int? = nil,
        business: String? = nil,
        source: String? = nil
    ) {
        self.uri = uri
        self.nativeURI = nativeURI
        self.subjectID = subjectID
        self.rootID = rootID
        self.sourceID = sourceID
        self.targetID = targetID
        self.itemID = itemID
        self.businessID = businessID
        self.business = business
        self.source = source
    }

    /// Extract only an online video comment. A display title or message body
    /// is never treated as an id, and a dynamic/article business id is never
    /// reinterpreted as a video.
    var commentAnchor: CommentAnchor? {
        let rawURIs = [nativeURI, uri].compactMap { $0 }.filter { !$0.isEmpty }
        let parsedURLs = rawURIs.compactMap(Self.url)
        let normalizedBusiness = business?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isVideoBusiness = businessID == 1
            || normalizedBusiness.map { ["video", "archive", "视频", "稿件"].contains($0) } == true
        let hasVideoURI = parsedURLs.contains { url in
            if case .videoDetail = BiliURLParser.parse(url) { return true }
            return false
        }
        guard isVideoBusiness || hasVideoURI else { return nil }

        let fallbackRpid = Self.firstPositive(sourceID, targetID, itemID, rootID)
        let fallbackRoot = Self.firstPositive(rootID)
        for url in parsedURLs {
            if let anchor = CommentAnchor(
                url: url,
                oid: subjectID,
                fallbackRpid: fallbackRpid,
                fallbackRootRpid: fallbackRoot,
                source: source
            ) {
                return anchor
            }
        }

        // A video notification can arrive with a native URI that contains an
        // aid-only path, or with no URI at all. `subject_id` is the documented
        // comment subject (the video's aid); the reply ids are the only safe
        // target candidates in the payload.
        guard isVideoBusiness,
              let oid = subjectID, oid > 0,
              let rpid = fallbackRpid, rpid > 0
        else { return nil }
        return CommentAnchor(
            videoID: .aid(oid),
            oid: oid,
            rpid: rpid,
            rootRpid: fallbackRoot,
            source: source
        )
    }

    private static func url(_ raw: String) -> URL? {
        if raw.hasPrefix("//") { return URL(string: "https:\(raw)") }
        return URL(string: raw)
    }

    private static func firstPositive(_ values: Int?...) -> Int? {
        values.compactMap { $0 }.first(where: { $0 > 0 })
    }
}
