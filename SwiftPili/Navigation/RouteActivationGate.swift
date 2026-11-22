import Foundation

/// When a player-hosting detail route may run its activation — owner-lease
/// claim, surface claim, the inline `PlayerView` and fullscreen host mount,
/// the load itself (design §8 of `09-21-animation-frame-pacing-system`).
///
/// ## Why the path alone is no longer the trigger
///
/// The route gate (`AppCoordinator.isActivePlayerRoute` / `BangumiRouteSurfacePolicy`) flips
/// the instant the NavigationStack path is written, and for an interactive pop
/// SwiftUI writes it at FINGER-LIFT — 440–700 ms before the settle animation
/// finishes (device capture `run3-report-2026-09-26.txt`: the park line lands
/// 5–19 ms after `finger lifted — completing`, and never after `— cancelling`).
/// Everything keyed on that flip therefore ran inside the animation and held the
/// main thread 62–128 ms on its first frames. The path stays the AUTHORITY for
/// which route may own the player; this adds the second fact a transition needs,
/// "UIKit has finished showing this page", before the authority is exercised.
///
/// ## The appearance signal
///
/// `viewDidAppear` of a zero-size child controller on the page. UIKit delivers
/// it after any push/pop animation completes, promptly when there is no
/// animation, and NEVER for a cancelled interactive pop (`willAppear` →
/// `willDisappear` instead) — so a cancelled swipe cannot activate the page
/// beneath, and no separate "no transition" branch exists to get wrong. This is
/// the UIKit appearance cycle, not SwiftUI's `onAppear`/`onDisappear`, which the
/// fullscreen contract (§3.2a) rules out as a route authority because they
/// overlap during a push; it is only ever AND-ed with the route gate, never a
/// substitute for it.
///
/// ## The latch
///
/// Appearance matters only for the activation EDGE. Once released, a route
/// stays activated until the PATH takes it away — a disappearance does not
/// revoke it. That is load-bearing twice over: presenting our own `.fullScreen`
/// host delivers `viewDidDisappear` to the presenter (the reason
/// `PlayerFullscreenHostCoordinator.viewDidDisappear` guards `host == nil`), and
/// a swipe-back that the user then CANCELS delivers `willDisappear` to the page
/// that stays on top. Revoking on either would unmount the only `PlayerView`
/// mid-fullscreen, or take the video off the page the user just decided to keep.
///
/// Pure and `Foundation`-only, so the state machine is testable off-device.
struct RouteActivationGate: Equatable, Sendable {
    /// The inputs. `routeActivity` is the route gate's own value, fed on every
    /// change; the rest are the probe controller's UIKit appearance callbacks.
    enum Event: Equatable, Sendable {
        case routeActivity(Bool)
        case willAppear
        case didAppear
        case willDisappear
        case didDisappear
    }

    /// What an event did, for diagnostics and for the one caller-side reaction
    /// each edge needs (activate, pause the departing owner, release a pending
    /// navigation admission).
    enum Outcome: Equatable, Sendable {
        case unchanged
        /// The route became active while its page is not yet shown; activation
        /// waits for `didAppear`.
        case gated
        /// Activation admitted. `waited` is the gated interval, nil when the
        /// release came without a wait (already shown, or the kill switch).
        case released(waited: TimeInterval?)
        /// A released route lost the top of the path.
        case deactivated
        /// A gated route lost the top of the path before it was shown — its
        /// activation never happens.
        case dropped
        /// `didAppear` for a route that is not the active one. Recorded as
        /// "shown" but it activates nothing on its own.
        case staleAppearance
    }

    /// `ROUTE_ACTIVATION_AFTER_APPEAR=0` restores activation at the path write.
    static let killSwitchEnvironmentKey = "ROUTE_ACTIVATION_AFTER_APPEAR"

    /// Only an explicit `0` disables the deferral; absent or any other value
    /// keeps it — the same fail-safe shape as the `PATHA_*` overrides.
    static func requiresAppearance(environment: [String: String]) -> Bool {
        !ExperimentalSettingsPolicy.diagnosticsEnabled || environment[killSwitchEnvironmentKey] != "0"
    }

    /// Resolved once per process: flipping it mid-session would split one
    /// navigation between two contracts.
    static let processRequiresAppearance = requiresAppearance(
        environment: ProcessInfo.processInfo.environment
    )

    /// false = kill switch: the route gate alone admits, today's behaviour.
    let requiresAppearance: Bool
    private(set) var routeIsActive = false
    /// A `didAppear` has arrived since the last `willAppear`/`willDisappear`/
    /// `didDisappear`. `willAppear` clears it too: an appearance transition has
    /// STARTED, and until it completes the page is not a settled place to run.
    private(set) var hasAppeared = false
    /// The latch. Cleared only by the route losing the top of the path.
    private(set) var isReleased = false
    private var gatedSince: TimeInterval?

    init(requiresAppearance: Bool = RouteActivationGate.processRequiresAppearance) {
        self.requiresAppearance = requiresAppearance
    }

    /// The one read. `routeIsActive` is the LIVE route gate, not the stored
    /// copy: in the body pass where the path flips, `onChange` has not fed the
    /// new value yet, and reading the stored one there would let a departing
    /// route keep the player for one more update.
    func admits(routeIsActive active: Bool) -> Bool {
        guard active else { return false }
        return requiresAppearance ? isReleased : true
    }

    /// True while the route is active and waiting for its page to appear.
    var isAwaitingAppearance: Bool {
        requiresAppearance && routeIsActive && !isReleased
    }

    mutating func handle(_ event: Event, now: TimeInterval) -> Outcome {
        switch event {
        case .routeActivity(let active):
            return noteRouteActivity(active, now: now)
        case .willAppear, .willDisappear, .didDisappear:
            // Never revokes a release — see "The latch".
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
        // Already on screen with no transition since (an appearance that raced
        // ahead of the route value), or no deferral at all: release now.
        if !requiresAppearance || hasAppeared {
            isReleased = true
            gatedSince = nil
            return .released(waited: nil)
        }
        gatedSince = now
        return .gated
    }
}
