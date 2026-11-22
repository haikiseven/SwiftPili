import Foundation

struct RouteActivationGate: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case routeActivity(Bool)
        case willAppear
        case didAppear
        case willDisappear
        case didDisappear
    }

    enum Outcome: Equatable, Sendable {
        case unchanged
        case gated
        case released(waited: TimeInterval?)
        case deactivated
        case dropped
        case staleAppearance
    }

    static let killSwitchEnvironmentKey = "ROUTE_ACTIVATION_AFTER_APPEAR"

    static func requiresAppearance(environment: [String: String]) -> Bool {
        !ExperimentalSettingsPolicy.diagnosticsEnabled || environment[killSwitchEnvironmentKey] != "0"
    }

    static let processRequiresAppearance = requiresAppearance(
        environment: ProcessInfo.processInfo.environment
    )

    let requiresAppearance: Bool
    private(set) var routeIsActive = false
    private(set) var hasAppeared = false
    private(set) var isReleased = false
    private var gatedSince: TimeInterval?

    init(requiresAppearance: Bool = RouteActivationGate.processRequiresAppearance) {
        self.requiresAppearance = requiresAppearance
    }

    func admits(routeIsActive active: Bool) -> Bool {
        guard active else { return false }
        return requiresAppearance ? isReleased : true
    }

    var isAwaitingAppearance: Bool {
        requiresAppearance && routeIsActive && !isReleased
    }

    mutating func handle(_ event: Event, now: TimeInterval) -> Outcome {
        switch event {
        case .routeActivity(let active):
            return noteRouteActivity(active, now: now)
        case .willAppear, .willDisappear, .didDisappear:
            hasAppeared = false
            return .unchanged
        case .didAppear:
            hasAppeared = true
            guard routeIsActive else { return .staleAppearance }
            guard !isReleased else { return .unchanged }
            isReleased = true
            let waited = gatedSince.map { max(0, now - $0) }
            gatedSince = nil
            return .released(waited: waited)
        }
    }

    private mutating func noteRouteActivity(_ active: Bool, now: TimeInterval) -> Outcome {
        guard active != routeIsActive else { return .unchanged }
        routeIsActive = active
        guard active else {
            let wasReleased = isReleased
            isReleased = false
            gatedSince = nil
            return wasReleased ? .deactivated : .dropped
        }
        if !requiresAppearance || hasAppeared {
            isReleased = true
            gatedSince = nil
            return .released(waited: nil)
        }
        gatedSince = now
        return .gated
    }
}
