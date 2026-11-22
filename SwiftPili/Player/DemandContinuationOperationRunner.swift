import Foundation

@MainActor
protocol DemandContinuationOperationOwner: AnyObject {
    var backend: PlayerBackend { get }
    func submitDemandContinuationOperationEvent(_ event: DemandPresentationEvent)
    func noteDemandContinuationPrepared(fence: DemandPresentationFence)
}

/// Executes continuation operations; admission and synchronous effects stay with
/// the owner. Only the last stored task is cancelled, matching the VM's slot.
@MainActor
final class DemandContinuationOperationRunner {
    private weak var owner: (any DemandContinuationOperationOwner)?
    private var currentTask: Task<Void, Never>?

    init(owner: any DemandContinuationOperationOwner) {
        self.owner = owner
    }

    func prepareVideoLane(fence: DemandPresentationFence, token: DemandVideoSuspendToken) {
        currentTask = Self.makePreparationTask(owner: owner, fence: fence, token: token)
    }

    func resumeVideoLane(fence: DemandPresentationFence, token: DemandVideoSuspendToken) {
        currentTask = Self.makeResumeTask(owner: owner, fence: fence, token: token)
    }

    func restoreInline(fence: DemandPresentationFence) {
        currentTask = Self.makeInlineRestoreTask(owner: owner, fence: fence)
    }

    func reconcilePiP(fence: DemandPresentationFence) {
        currentTask = Self.makePiPReconcileTask(owner: owner, fence: fence)
    }

    func recreateVideoDecoder(fence: DemandPresentationFence) {
        currentTask = Self.makeDecoderRecreationTask(owner: owner, fence: fence)
    }

    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }

    private static func makePreparationTask(
        owner: (any DemandContinuationOperationOwner)?,
        fence: DemandPresentationFence,
        token: DemandVideoSuspendToken
    ) -> Task<Void, Never> {
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            let result = await owner.backend.prepareDemandVideoLaneForForeground(token)
            guard !Task.isCancelled else { return }
            switch result {
            case .prepared:
                owner.noteDemandContinuationPrepared(fence: fence)
                owner.submitDemandContinuationOperationEvent(.videoLanePrepared(
                    fence: fence,
                    token: token
                ))
            case .cancelled:
                // A retired preparation must not fail the successor transaction.
                PlayerLog.log(
                    "[PathA][continuation] prepare cancelled — no event " +
                    "emitted (epoch=\(fence.lifecycleEpoch) " +
                    "render=\(fence.renderGeneration) " +
                    "token=\(token.generation))"
                )
            case .failed(let failure):
                // Preparation can be adopted across a reserved render; this is
                // deliberately broader than exact-render videoLaneResumeFailed.
                owner.submitDemandContinuationOperationEvent(.videoLanePreparationFailed(
                    fence: fence,
                    token: token,
                    failure: failure
                ))
            }
        }
    }

    private static func makeResumeTask(
        owner: (any DemandContinuationOperationOwner)?,
        fence: DemandPresentationFence,
        token: DemandVideoSuspendToken
    ) -> Task<Void, Never> {
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            let succeeded = await owner.backend.resumeDemandVideoLane(
                token,
                renderGeneration: fence.renderGeneration
            )
            guard !Task.isCancelled else { return }
            if succeeded {
                owner.submitDemandContinuationOperationEvent(.videoLaneResumed(
                    fence: fence,
                    token: token
                ))
            } else {
                owner.submitDemandContinuationOperationEvent(.videoLaneResumeFailed(
                    fence: fence,
                    failure: .decoderRecoveryFailed
                ))
            }
        }
    }

    private static func makeInlineRestoreTask(
        owner: (any DemandContinuationOperationOwner)?,
        fence: DemandPresentationFence
    ) -> Task<Void, Never> {
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            let succeeded = await owner.backend.restoreDemandInlinePresentation(
                renderGeneration: fence.renderGeneration
            )
            guard !Task.isCancelled else { return }
            if !succeeded {
                let health = owner.backend.demandPresentationHealth
                owner.submitDemandContinuationOperationEvent(.rendererHealthChanged(
                    fence: fence,
                    health: health
                ))
            }
        }
    }

    private static func makePiPReconcileTask(
        owner: (any DemandContinuationOperationOwner)?,
        fence: DemandPresentationFence
    ) -> Task<Void, Never> {
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            let succeeded = await owner.backend
                .reconcileDemandPiPPresentationAfterActivation(
                    renderGeneration: fence.renderGeneration
                )
            guard !Task.isCancelled else { return }
            if succeeded {
                // Inline handoff waits for the local reconciliation to complete.
                owner.submitDemandContinuationOperationEvent(.pipPresentationReconciled(
                    fence: fence
                ))
            } else {
                PlayerLog.log(
                    "[Lifecycle][PiP] activation reconciliation exhausted " +
                        "session=\(owner.backend.demandPresentationSessionGeneration) " +
                        "binding=\(owner.backend.demandPiPBindingGeneration) " +
                        "render=\(fence.renderGeneration)"
                )
                owner.submitDemandContinuationOperationEvent(.pipPresentationReconcileFailed(
                    fence: fence,
                    failure: .rendererRecoveryExhausted
                ))
            }
        }
    }

    private static func makeDecoderRecreationTask(
        owner: (any DemandContinuationOperationOwner)?,
        fence: DemandPresentationFence
    ) -> Task<Void, Never> {
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            let succeeded = await owner.backend.recreateDemandVideoDecoder()
            guard !Task.isCancelled else { return }
            if !succeeded {
                owner.submitDemandContinuationOperationEvent(.videoLaneResumeFailed(
                    fence: fence,
                    failure: .decoderRecoveryFailed
                ))
            }
        }
    }
}
