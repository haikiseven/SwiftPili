import Foundation
import Testing
@testable import SwiftPili

@Suite("RootDetailPresentationState")
@MainActor
struct RootDetailPresentationStateTests {
    private func makeDetailNavigation(
        routes: [Route],
        tab: AppTab = .home,
        sidebarID: String? = nil
    ) -> DetailNavigation {
        guard let nav = DetailNavigation(stack: routes, tab: tab, sidebarID: sidebarID) else {
            preconditionFailure("Expected at least one detail route in stack")
        }
        return nav
    }

    @Test("Entry, same-root path update, and exit lifecycle")
    func entryUpdateAndExit() {
        let state = RootDetailPresentationState()
        let video1 = Route.videoDetail(.aid(1))
        let nav1 = makeDetailNavigation(routes: [video1])

        let enterInput = RootDetailPresentationState.Input(
            navigation: nav1,
            navigationRevision: 1,
            accountRevision: 0,
            isEligible: true
        )
        #expect(!state.isVisible)
        #expect(!state.projectionHeld)

        state.reconcile(enterInput, entryAnimation: nil, exitAnimation: nil, currentInput: { enterInput })
        #expect(state.isVisible)
        #expect(state.projectionHeld)
        #expect(state.navigation == nav1)
        #expect(state.generation == 1)
        #expect(state.hidesDetailInRootShell(for: enterInput))

        // Pushing another route onto the same root keeps generation stable.
        let nav2 = makeDetailNavigation(routes: [video1, .userSpace(99)])
        let pushInput = RootDetailPresentationState.Input(
            navigation: nav2,
            navigationRevision: 2,
            accountRevision: 0,
            isEligible: true
        )
        state.reconcile(pushInput, entryAnimation: nil, exitAnimation: nil, currentInput: { pushInput })
        #expect(state.isVisible)
        #expect(state.navigation == nav2)
        #expect(state.generation == 1)

        // Clearing navigation exits cleanly.
        let exitInput = RootDetailPresentationState.Input(
            navigation: nil,
            navigationRevision: 3,
            accountRevision: 0,
            isEligible: true
        )
        state.reconcile(exitInput, entryAnimation: nil, exitAnimation: nil, currentInput: { exitInput })
        #expect(!state.isVisible)
        #expect(!state.projectionHeld)
        #expect(state.navigation == nil)
        #expect(state.generation == 2)
        #expect(!state.hidesDetailInRootShell(for: exitInput))
    }

    @Test("Losing outer-host eligibility exits cleanly for compact split view")
    func compactSplitViewIneligibilityExits() {
        let state = RootDetailPresentationState()
        let nav = makeDetailNavigation(routes: [.videoDetail(.aid(10))])
        let regularInput = RootDetailPresentationState.Input(
            navigation: nav,
            navigationRevision: 1,
            accountRevision: 0,
            isEligible: true
        )
        state.reconcile(regularInput, entryAnimation: nil, exitAnimation: nil, currentInput: { regularInput })
        #expect(state.isVisible)
        #expect(state.projectionHeld)

        let compactInput = RootDetailPresentationState.Input(
            navigation: nil,
            navigationRevision: 2,
            accountRevision: 0,
            isEligible: false
        )
        state.reconcile(compactInput, entryAnimation: nil, exitAnimation: nil, currentInput: { compactInput })
        #expect(!state.isVisible)
        #expect(!state.projectionHeld)
        #expect(state.navigation == nil)
        #expect(!state.hidesDetailInRootShell(for: compactInput))
    }

    @Test("Native pop reconciliation suppresses stale path during dismissal")
    func nativePopReconciliation() {
        let state = RootDetailPresentationState()
        let video = Route.videoDetail(.aid(42))
        let nav = makeDetailNavigation(routes: [video, .userSpace(7)])
        let activeInput = RootDetailPresentationState.Input(
            navigation: nav,
            navigationRevision: 1,
            accountRevision: 0,
            isEligible: true
        )
        state.reconcile(activeInput, entryAnimation: nil, exitAnimation: nil, currentInput: { activeInput })
        let generation = state.generation

        // While visible and eligible, nativePath reflects current input path.
        #expect(state.nativePath(for: nav, generation: generation, input: activeInput) == nav.path)

        // Mismatched generation is ignored.
        let poppedInput = RootDetailPresentationState.Input(
            navigation: nil,
            navigationRevision: 2,
            accountRevision: 0,
            isEligible: true
        )
        state.noteCommittedNativePop(root: nav.root, generation: generation + 99, input: poppedInput)
        #expect(state.nativePath(for: nav, generation: generation, input: poppedInput) == nav.path)

        // Matching generation marks committed native pop and empties nativePath once outer host is no longer required.
        state.noteCommittedNativePop(root: nav.root, generation: generation, input: poppedInput)
        #expect(state.nativePath(for: nav, generation: generation, input: poppedInput).isEmpty)

        state.reconcile(poppedInput, entryAnimation: nil, exitAnimation: nil, currentInput: { poppedInput })
        #expect(!state.isVisible)
        #expect(!state.projectionHeld)
    }

    @Test("Account revision bump forces a new generation even for an identical root route")
    func accountRevisionHandling() {
        let state = RootDetailPresentationState()
        let nav = makeDetailNavigation(routes: [.videoDetail(.aid(77))])

        let rev1Input = RootDetailPresentationState.Input(
            navigation: nav,
            navigationRevision: 1,
            accountRevision: 1,
            isEligible: true
        )
        state.reconcile(rev1Input, entryAnimation: nil, exitAnimation: nil, currentInput: { rev1Input })
        #expect(state.generation == 1)
        #expect(state.accountRevision == 1)

        // Same root under a new account revision must increment generation and update accountRevision.
        let rev2Input = RootDetailPresentationState.Input(
            navigation: nav,
            navigationRevision: 2,
            accountRevision: 2,
            isEligible: true
        )
        state.reconcile(rev2Input, entryAnimation: nil, exitAnimation: nil, currentInput: { rev2Input })
        #expect(state.isVisible)
        #expect(state.generation == 2)
        #expect(state.accountRevision == 2)

        // Account switch clearing navigation exits completely.
        let rev3Cleared = RootDetailPresentationState.Input(
            navigation: nil,
            navigationRevision: 3,
            accountRevision: 3,
            isEligible: true
        )
        state.reconcile(rev3Cleared, entryAnimation: nil, exitAnimation: nil, currentInput: { rev3Cleared })
        #expect(!state.isVisible)
        #expect(!state.projectionHeld)
        #expect(state.navigation == nil)
    }
}
