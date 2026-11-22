import UIKit

enum PlayerScreenRoute: Equatable {
    case video(VideoID)
    case bangumi(Int)
    case live(Int)
    case offline(OfflinePortraitPagingContext)

    init?(route: Route?) {
        switch route {
        case .videoDetail(let target): self = .video(target.videoID)
        case .bangumiDetail(let id, _): self = .bangumi(id)
        case .liveRoom(let id, _): self = .live(id)
        case .offlinePlayer(let id, _): self = .offline(.single(id))
        case .offlinePager(let context, _): self = .offline(context)
        default: return nil
        }
    }
}

enum PlayerPresentationSource: Equatable {
    case vod(aid: Int, cid: Int, source: PlayerViewModel.StreamSource)
    case live(roomID: Int)
    case offline(OfflinePlaybackAsset)
}

struct PlayerRoutePosition: Equatable, Hashable {
    let tab: AppTab
    let sidebarID: String?
    let depth: Int
}

struct PlayerRouteDestination: Equatable {
    let route: PlayerScreenRoute
    let position: PlayerRoutePosition
}

struct PlayerScreenPresentationContext: Equatable {
    let screenID: UUID
    let ownerLease: PlayerOwnerLease
    let route: PlayerScreenRoute
    let position: PlayerRoutePosition
    let source: PlayerPresentationSource
}

struct PlayerPresentationReceipt: Equatable {
    let id: UUID
    let context: PlayerScreenPresentationContext
}

enum PlayerPresentationCoverage {
    case none
    case enteringCurrentHost
    case coveredByCurrentHost

    var retainsLease: Bool {
        switch self {
        case .none: false
        case .enteringCurrentHost, .coveredByCurrentHost: true
        }
    }
}

protocol PlayerPresentationHost: UIViewController {}

@MainActor
enum PlayerPresentationHostPresence {
    static func coverage(
        of controller: UIViewController,
        entering: Bool
    ) -> PlayerPresentationCoverage {
        guard controller is PlayerPresentationHost,
              controller.presentingViewController != nil,
              !controller.isBeingDismissed else { return .none }
        if let window = AppWindowMetrics.current,
           controller.viewIfLoaded?.window === window {
            return .coveredByCurrentHost
        }
        return entering && controller.isBeingPresented ? .enteringCurrentHost : .none
    }
}
