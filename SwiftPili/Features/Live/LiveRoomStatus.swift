import Foundation

enum LiveRoomPlaybackState: Equatable, Sendable {
    case offline
    case live
    case roundPlay
    case unknown(Int)
}

enum LiveRoomStatusPolicy {
    static func state(liveStatus: Int?) -> LiveRoomPlaybackState {
        switch liveStatus {
        case 0: return .offline
        case 1: return .live
        case 2: return .roundPlay
        case .some(let other): return .unknown(other)
        case nil: return .offline
        }
    }

    static func shouldDimListCard(liveStatus: Int?) -> Bool {
        liveStatus == 0
    }

    enum Refusal: Equatable, Sendable {
        case roomOffline
        case roundPlayWithoutStream
    }

    enum Decision: Equatable, Sendable {
        case attempt(LiveRoomPlaybackState)
        case refuse(Refusal)
    }

    static func decide(
        liveStatus: Int?,
        hasStream: Bool
    ) -> Decision {
        let state = state(liveStatus: liveStatus)
        guard hasStream else {
            switch state {
            case .roundPlay:
                return .refuse(.roundPlayWithoutStream)
            case .offline, .live, .unknown:
                return .refuse(.roomOffline)
            }
        }
        return .attempt(state)
    }
}

extension LiveRoomPlaybackState {
    var listBadgeText: String {
        switch self {
        case .live: return String(localized: "LIVE")
        case .roundPlay: return String(localized: "ROUND")
        case .offline: return String(localized: "OFFLINE")
        case .unknown: return String(localized: "LIVE")
        }
    }
}
