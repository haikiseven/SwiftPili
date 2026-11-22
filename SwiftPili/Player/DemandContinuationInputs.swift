import Foundation

struct DemandContinuationInputs {
    let phase: DemandVideoPresentationPhase

    var ownsLocalVideoFaultDebt: Bool {
        switch phase {
        case .warmSuspendingForAudioOnly, .warmSuspended,
             .pipStarting, .pipActive, .pipStopping, .restoringInline,
             .inlineNeedsAttachment, .inlineAttachPending,
             .inlineAttachedUnproven:
            return true
        case .idle, .pausedInline, .inlineVisible, .pipStartFailed, .failed:
            return false
        }
    }
}
