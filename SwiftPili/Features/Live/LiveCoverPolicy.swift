import Foundation

enum LiveCoverContext: Equatable, Sendable {
    case gridCard
    case roomPoster
}

enum LiveCoverPolicy {
    struct Candidates: Equatable, Sendable {
        var keyframe: String?
        var userCover: String?
        var cover: String?
        var coverFromUser: String?
        var systemCover: String?
        var face: String?

        init(
            keyframe: String? = nil,
            userCover: String? = nil,
            cover: String? = nil,
            coverFromUser: String? = nil,
            systemCover: String? = nil,
            face: String? = nil
        ) {
            self.keyframe = keyframe
            self.userCover = userCover
            self.cover = cover
            self.coverFromUser = coverFromUser
            self.systemCover = systemCover
            self.face = face
        }
    }

    enum Source: String, Equatable, Sendable {
        case keyframe
        case userCover
        case cover
        case coverFromUser
        case systemCover
        case face
        case none
    }

    struct Selection: Equatable, Sendable {
        let url: String?
        let source: Source
    }

    static func select(
        context: LiveCoverContext,
        liveStatus: Int?,
        candidates: Candidates
    ) -> Selection {
        let isLive = LiveRoomStatusPolicy.state(liveStatus: liveStatus) == .live
        let keyframe = isLive ? nonEmpty(candidates.keyframe) : nil
        let systemCover = isLive ? nonEmpty(candidates.systemCover) : nil

        let ordered: [(Source, String?)]
        switch context {
        case .roomPoster:
            ordered = [
                (.keyframe, keyframe),
                (.userCover, nonEmpty(candidates.userCover)),
                (.cover, nonEmpty(candidates.cover)),
                (.coverFromUser, nonEmpty(candidates.coverFromUser)),
                (.systemCover, systemCover),
                (.face, nonEmpty(candidates.face)),
            ]
        case .gridCard:
            ordered = [
                (.cover, nonEmpty(candidates.cover)),
                (.userCover, nonEmpty(candidates.userCover)),
                (.coverFromUser, nonEmpty(candidates.coverFromUser)),
                (.systemCover, systemCover),
                (.keyframe, keyframe),
                (.face, nonEmpty(candidates.face)),
            ]
        }

        for (source, value) in ordered {
            if let value { return Selection(url: value, source: source) }
        }
        return Selection(url: nil, source: .none)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
