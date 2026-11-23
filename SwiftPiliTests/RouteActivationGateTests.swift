import Foundation
import Testing
@testable import SwiftPili

@Suite("RouteActivationGate")
struct RouteActivationGateTests {
    @Test("Gates activation until didAppear and reports waited duration")
    func gatingAndDidAppearRelease() {
        var gate = RouteActivationGate(requiresAppearance: true)

        #expect(!gate.routeIsActive)
        #expect(!gate.hasAppeared)
        #expect(!gate.isReleased)
        #expect(!gate.isAwaitingAppearance)
        #expect(!gate.admits(routeIsActive: true))

        #expect(gate.handle(.routeActivity(true), now: 10.0) == .gated)
        #expect(gate.routeIsActive)
        #expect(gate.isAwaitingAppearance)
        #expect(!gate.isReleased)
        #expect(!gate.admits(routeIsActive: true))

        // Duplicate active notification is a no-op.
        #expect(gate.handle(.routeActivity(true), now: 10.5) == .unchanged)

        // didAppear releases the gate with elapsed wait time.
        #expect(gate.handle(.didAppear, now: 12.25) == .released(waited: 2.25))
        #expect(gate.hasAppeared)
        #expect(gate.isReleased)
        #expect(!gate.isAwaitingAppearance)
        #expect(gate.admits(routeIsActive: true))
        #expect(!gate.admits(routeIsActive: false))

        // Redundant didAppear while already released does nothing.
        #expect(gate.handle(.didAppear, now: 13.0) == .unchanged)
    }

    @Test("Deactivation clears release and early deactivation reports dropped")
    func deactivationAndDrop() {
        var gate = RouteActivationGate(requiresAppearance: true)

        // Activating then deactivating before didAppear returns .dropped.
        #expect(gate.handle(.routeActivity(true), now: 1.0) == .gated)
        #expect(gate.handle(.routeActivity(false), now: 1.5) == .dropped)
        #expect(!gate.routeIsActive)
        #expect(!gate.isReleased)
        #expect(!gate.isAwaitingAppearance)

        // Activating, appearing, then deactivating returns .deactivated.
        #expect(gate.handle(.routeActivity(true), now: 2.0) == .gated)
        #expect(gate.handle(.didAppear, now: 2.4) == .released(waited: 0.4))
        #expect(gate.handle(.routeActivity(false), now: 3.0) == .deactivated)
        #expect(!gate.routeIsActive)
        #expect(!gate.isReleased)
        #expect(!gate.admits(routeIsActive: true))
    }

    @Test("Stale appearance before activation records appearance and allows immediate subsequent release")
    func staleAppearanceAndLifecycleReset() {
        var gate = RouteActivationGate(requiresAppearance: true)

        #expect(gate.handle(.didAppear, now: 5.0) == .staleAppearance)
        #expect(gate.hasAppeared)
        #expect(!gate.isReleased)

        // Because the view has already appeared, becoming active releases immediately with nil wait.
        #expect(gate.handle(.routeActivity(true), now: 6.0) == .released(waited: nil))
        #expect(gate.isReleased)

        // Disappearing resets hasAppeared so the next activation must wait for didAppear again.
        #expect(gate.handle(.routeActivity(false), now: 7.0) == .deactivated)
        #expect(gate.handle(.willDisappear, now: 7.1) == .unchanged)
        #expect(!gate.hasAppeared)
        #expect(gate.handle(.didDisappear, now: 7.2) == .unchanged)
        #expect(gate.handle(.willAppear, now: 8.0) == .unchanged)
        #expect(!gate.hasAppeared)
        #expect(gate.handle(.routeActivity(true), now: 8.1) == .gated)
    }

    @Test("Bypass mode releases immediately without waiting for appearance")
    func bypassRequiresAppearance() {
        var gate = RouteActivationGate(requiresAppearance: false)

        #expect(gate.admits(routeIsActive: true))
        #expect(!gate.admits(routeIsActive: false))
        #expect(gate.handle(.routeActivity(true), now: 1.0) == .released(waited: nil))
        #expect(!gate.isAwaitingAppearance)
        #expect(gate.handle(.routeActivity(false), now: 2.0) == .deactivated)
    }
}
