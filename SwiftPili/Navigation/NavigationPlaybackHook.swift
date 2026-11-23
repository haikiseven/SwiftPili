import Foundation

@MainActor
protocol NavigationPlaybackHook: AnyObject {
    func playerRouteWillChange(from old: PlayerRouteDestination?, to new: PlayerRouteDestination?)
    @discardableResult
    func parkOutgoingRouteStill() -> String?
    func retireDepartedRouteStill(owner: String)
    func endCurrentOwnerPlayback()
    func clearAllOutgoingRouteStills()
}
