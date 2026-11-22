import Observation
import SwiftUI

@MainActor
@Observable
final class RootDetailPresentationState {
    struct Input: Equatable {
        let navigation: DetailNavigation?
        let navigationRevision: UInt64
        let accountRevision: UInt64
        let isEligible: Bool
        var requiresOuterHost: Bool { isEligible && navigation != nil }
    }

    private(set) var navigation: DetailNavigation?
    private(set) var accountRevision: UInt64 = 0
    private(set) var isVisible = false
    private(set) var projectionHeld = false
    private(set) var generation = 0
    @ObservationIgnored private var committedNativePopGeneration: Int?

    func hidesDetailInRootShell(for input: Input) -> Bool {
        input.requiresOuterHost || projectionHeld
    }

    func reconcile(
        _ input: Input,
        entryAnimation: Animation?,
        exitAnimation: Animation?,
        currentInput: @escaping () -> Input
    ) {
        guard input.requiresOuterHost, let navigation = input.navigation else {
            beginExit(animation: exitAnimation, currentInput: currentInput)
            return
        }

        if isVisible, self.navigation?.root == navigation.root, accountRevision == input.accountRevision {
            if self.navigation != navigation { self.navigation = navigation }
            return
        }

        committedNativePopGeneration = nil
        generation += 1
        accountRevision = input.accountRevision
        projectionHeld = true
        if isVisible {
            withTransaction(Transaction(animation: nil)) {
                self.navigation = navigation
            }
            return
        }

        self.navigation = navigation
        Self.animate(entryAnimation, changes: { self.isVisible = true }, completion: {})
    }

    func nativePath(
        for navigation: DetailNavigation, generation: Int, input: Input
    ) -> [DetailRouteOccurrence] {
        guard isVisible else { return [] }
        if self.generation == generation, committedNativePopGeneration == generation,
           self.navigation?.root == navigation.root, !input.requiresOuterHost {
            return []
        }
        if isVisible, projectionHeld, self.generation == generation,
           self.navigation?.root == navigation.root,
           accountRevision == input.accountRevision, input.requiresOuterHost,
           let currentNavigation = input.navigation, currentNavigation.root == navigation.root {
            return currentNavigation.path
        }
        return navigation.path
    }

    func noteCommittedNativePop(
        root: DetailRouteOccurrence, generation: Int, input: Input
    ) {
        guard isVisible, projectionHeld, self.generation == generation,
              navigation?.root == root else { return }
        committedNativePopGeneration = generation
    }

    private func beginExit(animation: Animation?, currentInput: @escaping () -> Input) {
        guard projectionHeld, isVisible else { return }
        let exitAnimation = committedNativePopGeneration == generation ? nil : animation
        committedNativePopGeneration = nil
        generation += 1
        let exitGeneration = generation
        Self.animate(exitAnimation, changes: { self.isVisible = false }, completion: {
            guard exitGeneration == self.generation,
                  !self.isVisible,
                  !currentInput().requiresOuterHost
            else { return }
            self.navigation = nil
            self.projectionHeld = false
        })
    }

    private static func animate(_ animation: Animation?, changes: () -> Void, completion: @escaping () -> Void) {
        if let animation {
            withAnimation(animation, completionCriteria: .logicallyComplete, changes, completion: completion)
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, changes)
            completion()
        }
    }
}
