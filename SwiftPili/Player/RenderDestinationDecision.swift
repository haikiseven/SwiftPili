import Foundation

struct RenderDestinationDecision {
    let phase: DemandVideoPresentationPhase

    enum Registration {
        case adoptReservedFence
        case adoptTransactionDestination(Int)
        case newContainer
    }

    enum Reattachment {
        case advance
        case adoptCurrent
    }

    var foregroundDestination: DemandForegroundPresentationDestination {
        switch phase {
        case .pipActive, .pipStopping, .restoringInline:
            return .preservedPiP
        case .inlineVisible, .inlineAttachedUnproven, .inlineAttachPending:
            return .retainedPassiveInline
        case .idle, .failed:
            return .unprovenPassiveInline
        case .pausedInline, .inlineNeedsAttachment, .pipStarting,
             .pipStartFailed, .warmSuspendingForAudioOnly, .warmSuspended:
            return .reservedNewInline
        }
    }

    func foregroundRenderGeneration(
        for destination: DemandForegroundPresentationDestination,
        currentRenderGeneration: Int
    ) -> Int {
        switch destination {
        case .preservedPiP:
            let pipRenderGeneration = phase.fence?.renderGeneration ?? currentRenderGeneration
            return pipRenderGeneration == currentRenderGeneration
                ? currentRenderGeneration
                : Self.reserveNextRenderGeneration(after: currentRenderGeneration)
        case .retainedPassiveInline, .unprovenPassiveInline:
            return currentRenderGeneration
        case .reservedNewInline:
            return Self.reserveNextRenderGeneration(after: currentRenderGeneration)
        }
    }

    func nativePiPRenderGeneration(
        for event: DemandPiPNativeEvent,
        currentRenderGeneration: Int
    ) -> Int {
        switch event {
        case .didStop:
            if case .restoringInline(let transaction) = phase {
                return transaction.fence.renderGeneration
            }
            return Self.reserveNextRenderGeneration(after: currentRenderGeneration)
        case .willStart, .didStart, .failedToStart, .willStop:
            return currentRenderGeneration
        }
    }

    static func reserveNextRenderGeneration(after currentRenderGeneration: Int) -> Int {
        currentRenderGeneration + 1
    }

    func registration(currentRenderGeneration: Int) -> Registration {
        let keepsReservedRenderGeneration: Bool
        switch phase {
        case .warmSuspendingForAudioOnly, .warmSuspended,
             .inlineNeedsAttachment, .inlineAttachPending, .restoringInline:
            keepsReservedRenderGeneration = true
        case .idle, .pausedInline, .inlineVisible, .inlineAttachedUnproven,
             .pipStarting, .pipStartFailed, .pipActive, .pipStopping,
             .failed:
            keepsReservedRenderGeneration = false
        }
        if let pendingFence = phase.fence,
           pendingFence.renderGeneration == Self.reserveNextRenderGeneration(after: currentRenderGeneration) {
            return .adoptReservedFence
        } else if let pendingFence = phase.fence,
                  keepsReservedRenderGeneration,
                  pendingFence.renderGeneration == currentRenderGeneration {
            return .adoptTransactionDestination(pendingFence.renderGeneration)
        } else {
            return .newContainer
        }
    }

    func shouldInstallInline(fence: DemandPresentationFence) -> Bool {
        guard let currentFence = phase.fence else { return true }
        let isPassiveInlinePhase: Bool
        switch phase {
        case .pausedInline, .inlineVisible, .inlineAttachedUnproven, .failed:
            isPassiveInlinePhase = true
        case .idle, .inlineNeedsAttachment, .inlineAttachPending,
             .warmSuspendingForAudioOnly, .warmSuspended,
             .pipStarting, .pipStartFailed, .pipActive, .pipStopping,
             .restoringInline:
            isPassiveInlinePhase = false
        }
        return !currentFence.hasSameContinuityAuthority(as: fence)
            || (isPassiveInlinePhase && currentFence.renderGeneration != fence.renderGeneration)
    }

    func reattachment(currentRenderGeneration: Int) -> Reattachment {
        if let fence = phase.fence,
           fence.renderGeneration == Self.reserveNextRenderGeneration(after: currentRenderGeneration) {
            return .advance
        } else if phase.fence?.renderGeneration != currentRenderGeneration {
            return .advance
        } else {
            return .adoptCurrent
        }
    }
}
