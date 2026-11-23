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

struct PlayerScreenHostKey: Equatable {
    let screenID: UUID
    let ownerLease: PlayerOwnerLease
    let route: PlayerScreenRoute
    let position: PlayerRoutePosition
}

struct PlayerScreenPresentationContext: Equatable {
    let hostKey: PlayerScreenHostKey
    let source: PlayerPresentationSource?

    var screenID: UUID { hostKey.screenID }
    var ownerLease: PlayerOwnerLease { hostKey.ownerLease }
    var route: PlayerScreenRoute { hostKey.route }
    var position: PlayerRoutePosition { hostKey.position }

    init(
        screenID: UUID,
        ownerLease: PlayerOwnerLease,
        route: PlayerScreenRoute,
        position: PlayerRoutePosition,
        source: PlayerPresentationSource?
    ) {
        self.hostKey = PlayerScreenHostKey(
            screenID: screenID,
            ownerLease: ownerLease,
            route: route,
            position: position
        )
        self.source = source
    }
}

struct PlayerPresentationReceipt: Equatable {
    let id: UUID
    let context: PlayerScreenPresentationContext

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.context.hostKey == rhs.context.hostKey
    }
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

enum PlayerFullscreenStageGeometry {
    struct InlineSnapshot: Equatable, Sendable {
        let frameInWindow: CGRect
        let frameInScreen: CGRect
        let windowSize: CGSize
        let windowFrameInScreen: CGRect
        let cornerRadius: CGFloat
    }

    struct ResolvedStageTarget: Equatable, Sendable {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    static func resolvedInlineStageRect(
        snapshot: InlineSnapshot?,
        containerSize: CGSize,
        hostFrameInScreen: CGRect?
    ) -> ResolvedStageTarget? {
        guard let snapshot,
              isUsableSize(containerSize),
              isUsableRect(snapshot.frameInWindow)
        else { return nil }

        let cornerRadius = snapshot.cornerRadius.isFinite ? max(0, snapshot.cornerRadius) : 0
        if isUsableSize(snapshot.windowSize),
           abs(snapshot.windowSize.width - containerSize.width) <= 2,
           abs(snapshot.windowSize.height - containerSize.height) <= 2,
           rectIntersectsContainer(snapshot.frameInWindow, containerSize: containerSize) {
            return ResolvedStageTarget(rect: snapshot.frameInWindow, cornerRadius: cornerRadius)
        }

        if let hostFrameInScreen,
           isUsableSize(snapshot.windowSize),
           abs(snapshot.windowSize.width - containerSize.width) <= 2,
           abs(snapshot.windowSize.height - containerSize.height) <= 2,
           hostFrameInScreen.minX.isFinite, hostFrameInScreen.minY.isFinite,
           isUsableSize(hostFrameInScreen.size),
           abs(hostFrameInScreen.width - containerSize.width) <= 2,
           abs(hostFrameInScreen.height - containerSize.height) <= 2,
           isUsableRect(snapshot.frameInScreen) {
            let local = CGRect(
                x: snapshot.frameInScreen.minX - hostFrameInScreen.minX,
                y: snapshot.frameInScreen.minY - hostFrameInScreen.minY,
                width: snapshot.frameInScreen.width,
                height: snapshot.frameInScreen.height
            )
            if rectIntersectsContainer(local, containerSize: containerSize) {
                return ResolvedStageTarget(rect: local, cornerRadius: cornerRadius)
            }
        }

        return nil
    }

    private static func isUsableSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 1 && size.height > 1
    }

    private static func isUsableRect(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && isUsableSize(rect.size)
    }

    private static func rectIntersectsContainer(_ rect: CGRect, containerSize: CGSize) -> Bool {
        let bounds = CGRect(origin: .zero, size: containerSize).insetBy(dx: -4, dy: -4)
        return bounds.intersects(rect)
    }
}
