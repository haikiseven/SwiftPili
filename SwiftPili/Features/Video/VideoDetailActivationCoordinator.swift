import Foundation

@MainActor
protocol VideoDetailActivationModel: AnyObject {
    var playerLease: PlayerOwnerLease? { get }
    func adoptPlayerLease(_ lease: PlayerOwnerLease)
    func revokeLoadForRouteDeparture()
    func load(id: VideoID, owner: String?, lease: PlayerOwnerLease?) async -> Bool
}

@MainActor
protocol VideoDetailActivationPlayer: AnyObject {
    func endForeignOwnerForRouteActivation(incomingOwner: String)
    func claimOwnerLease(owner: String) -> PlayerOwnerLease
    func isCurrentOwner(_ lease: PlayerOwnerLease) -> Bool
    @discardableResult
    func pauseForRouteDeparture(lease: PlayerOwnerLease?) -> Bool
}

@MainActor
protocol VideoDetailActivationNavigation: AnyObject {
    func settleVideoNavigation(_ target: VideoID)
    func cancelVideoNavigation(_ target: VideoID)
}

extension VideoDetailViewModel: VideoDetailActivationModel {}
extension PlayerViewModel: VideoDetailActivationPlayer {}
extension AppCoordinator: VideoDetailActivationNavigation {}

/// One detail route's activation lifetime, separate from rendering and model data.
/// The model remains the sole lease owner. Ports and live reads belong only to
/// the current call; no environment, task or completion closure is stored here.
@MainActor
final class VideoDetailActivationCoordinator {
    struct Ports {
        let model: any VideoDetailActivationModel
        let player: any VideoDetailActivationPlayer
        let navigation: any VideoDetailActivationNavigation
    }

    struct RouteRead {
        let isActive: @MainActor () -> Bool
        let currentVideoID: @MainActor () -> VideoID
    }

    private let routeActivation = RouteActivationState()

    func admits(routeIsActive: Bool) -> Bool {
        routeActivation.admits(routeIsActive: routeIsActive)
    }

    func handleAppearance(_ event: RouteActivationGate.Event, owner: String) {
        routeActivation.handle(event, owner: owner)
    }

    /// Departure revokes load admission before sampling the lease for pause.
    /// A route dropped before release must also free its matching navigation.
    func handleRouteActivity(_ active: Bool, owner: String, route: RouteRead, ports: Ports) {
        switch routeActivation.handle(.routeActivity(active), owner: owner) {
        case .deactivated where routeActivation.defersActivation:
            ports.model.revokeLoadForRouteDeparture()
            ports.player.pauseForRouteDeparture(lease: ports.model.playerLease)
        case .dropped:
            ports.navigation.cancelVideoNavigation(route.currentVideoID())
        default:
            break
        }
    }

    /// This prefix stays synchronous: claim/adopt precedes the View's original
    /// activation await. A retained nonnil lease is not silently replaced.
    func beginRoute(owner: String, route: RouteRead, ports: Ports) -> Bool {
        let targetID = route.currentVideoID()
        guard route.isActive() else {
            ports.navigation.cancelVideoNavigation(targetID)
            PlayerLog.log("[Navigation] historical VOD route activation ignored")
            return false
        }
        // A gated route retains navigation admission until appearance releases it.
        guard admits(routeIsActive: route.isActive()) else { return false }
        if ports.model.playerLease == nil {
            if routeActivation.defersActivation {
                ports.player.endForeignOwnerForRouteActivation(incomingOwner: owner)
            }
            ports.model.adoptPlayerLease(ports.player.claimOwnerLease(owner: owner))
        }
        return true
    }

    func activate(
        owner: String,
        route: RouteRead,
        ports: Ports,
        settlesNavigationAdmission: Bool = false
    ) async {
        let targetID = route.currentVideoID()
        defer {
            if settlesNavigationAdmission {
                if route.isActive() {
                    ports.navigation.settleVideoNavigation(targetID)
                } else {
                    ports.navigation.cancelVideoNavigation(targetID)
                }
            }
        }
        guard route.isActive(),
              let lease = ports.model.playerLease,
              ports.player.isCurrentOwner(lease) else { return }
        _ = await ports.model.load(id: targetID, owner: owner, lease: lease)
    }
}
