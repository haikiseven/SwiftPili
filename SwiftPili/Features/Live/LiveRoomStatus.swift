import Foundation

/// What a room's `live_status` means, as its own type rather than a bare Int
/// compared against 1.
///
/// BiliBili uses three values: 0 offline, 1 live, 2 轮播 (round / carousel — the
/// room replays recorded content while the streamer is away). All three are
/// legitimate room states; only the third was being handled as an accident.
enum LiveRoomPlaybackState: Equatable, Sendable {
    case offline
    case live
    /// 轮播. NOT "replay": a replay is a past broadcast the viewer chose, a
    /// round is a carousel the room plays on its own.
    case roundPlay
    /// A value this client does not know. Kept distinct from offline so a new
    /// server state is never silently presented as "nobody is streaming".
    case unknown(Int)
}

/// Decides what the UI and the player may do with a room's status.
///
/// **Observed 2026-08-21**, and the whole reason this is a policy rather than a
/// `status == 1` check:
///
/// - `xlive/web-room/v2/index/getRoomPlayInfo` returns `code 0` with
///   `playurl_info: null` for every clean (unencrypted, unhidden)
///   `live_status == 2` room sampled — rooms 78347, 5067, 46938, 21551827,
///   22462095. Status-1 rooms in the same sample returned 2–6
///   protocol/format/codec combinations.
/// - The legacy `room/v1/Room/playUrl` DOES return a `durl` for every status,
///   including offline. Those URLs are not playable: a status-1 room's URL
///   served HTTP 200 / 5.4 MB, while a status-2 room's and a status-0 room's
///   both returned HTTP 404. So the presence of a legacy `durl` is not evidence
///   of playability, and routing round rooms through it would open a 404.
///
/// Therefore the gate is **the presence of an actual stream**, not the status
/// code. That keeps round rooms out of a doomed open today, and starts playing
/// them automatically if BiliBili ever does expose a round stream — without
/// anyone having to hardcode `2 == 1`.
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

    /// Recommended and area feeds omit this field; only an explicit zero proves offline.
    static func shouldDimListCard(liveStatus: Int?) -> Bool {
        liveStatus == 0
    }

    /// Why a load was not attempted, for the log and the UI.
    enum Refusal: Equatable, Sendable {
        /// Nobody is streaming and nothing is queued.
        case roomOffline
        /// Round play is in effect but the server exposed no stream for it.
        case roundPlayWithoutStream
    }

    enum Decision: Equatable, Sendable {
        case attempt(LiveRoomPlaybackState)
        case refuse(Refusal)
    }

    /// `hasStream` is whether the play-info response actually carried a
    /// stream/format/codec the client could open — not whether the request
    /// succeeded. `getRoomPlayInfo` answers `code 0` for offline and round
    /// rooms alike; only `playurl_info` distinguishes them.
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
                // A status-1 room with no stream is functionally offline for
                // this viewer (ended between the list and the open, or
                // region/permission gated). `.offline` is the honest report:
                // there is nothing to play and no round to explain.
                return .refuse(.roomOffline)
            }
        }
        // A stream exists. Play it and label it by the state it came from — an
        // unknown status with a real stream is still playable content.
        return .attempt(state)
    }
}

/// Badge labels for room lists.
extension LiveRoomPlaybackState {
    /// Badge text for a room CARD in a list, where — unlike inside the room —
    /// "LIVE" is exactly what the viewer is scanning for.
    var listBadgeText: String {
        switch self {
        case .live: return String(localized: "LIVE")
        case .roundPlay: return String(localized: "ROUND")
        case .offline: return String(localized: "OFFLINE")
        // An unknown status is presenting something; do not claim to know what.
        case .unknown: return String(localized: "LIVE")
        }
    }
}
