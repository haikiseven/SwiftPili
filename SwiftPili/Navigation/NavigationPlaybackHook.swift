import Foundation

@MainActor
protocol NavigationPlaybackHook: AnyObject {
    func playerRouteWillChange(from old: PlayerRouteDestination?, to new: PlayerRouteDestination?)
    func playerRouteWillChange(
        from old: PlayerRouteDestination?,
        to new: PlayerRouteDestination?,
        departingRoute: Route?
    )
    @discardableResult
    func parkOutgoingRouteStill() -> String?
    func retireDepartedRouteStill(owner: String)
    func endCurrentOwnerPlayback()
    func clearAllOutgoingRouteStills()
}

extension NavigationPlaybackHook {
    func playerRouteWillChange(
        from old: PlayerRouteDestination?,
        to new: PlayerRouteDestination?,
        departingRoute _: Route?
    ) {
        playerRouteWillChange(from: old, to: new)
    }
}
