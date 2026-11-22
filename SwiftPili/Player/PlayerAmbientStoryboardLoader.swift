import Foundation
import Observation

/// One optional metadata operation. It never owns playback, a clock or a
/// renderer; admitted same-content artwork can outlive a recovery reload.
@MainActor @Observable
final class PlayerAmbientStoryboardLoader {
    struct Content: Equatable {
        let aid: Int
        let cid: Int
        let owner: PlayerOwnerLease
    }

    struct Request: Equatable {
        let content: Content
        let loadGeneration: Int
    }

    private(set) var isEligible = false
    private(set) var samples: [PlayerAmbientStoryboardSample] = []
    @ObservationIgnored private var content: Content?
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var attempted: Request?
    @ObservationIgnored private var access: ExperimentalAccessReceipt?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    func artwork(at time: TimeInterval, matching content: Content) -> PlayerAmbientArtwork? {
        guard isEligible, self.content == content, time.isFinite, time >= 0 else { return nil }
        return samples.last(where: { $0.from <= time })?.artwork
    }

    func reconcile(
        request next: Request?,
        access nextAccess: ExperimentalAccessReceipt?,
        eligible: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        didPublish: @escaping @MainActor () -> Void
    ) {
        if let next, content != next.content {
            samples = []
            content = next.content
        }
        if request != next || access != nextAccess || isEligible != eligible {
            cancelPending()
            attempted = nil
        }
        request = next
        access = nextAccess
        isEligible = eligible
        guard eligible, let next, let nextAccess, ExperimentalSettingsStore.shared.isCurrentAccess(nextAccess),
              samples.isEmpty, attempted != next, isCurrent() else { return }
        start(next, access: nextAccess, isCurrent: isCurrent, didPublish: didPublish)
    }

    func retire(keepingArtwork: Bool) {
        cancelPending()
        request = nil
        attempted = nil
        access = nil
        isEligible = false
        if !keepingArtwork {
            content = nil
            samples = []
        }
    }

    private func cancelPending() {
        operation = nil
        task?.cancel()
        task = nil
    }

    private func start(
        _ request: Request,
        access: ExperimentalAccessReceipt,
        isCurrent: @escaping @MainActor () -> Bool,
        didPublish: @escaping @MainActor () -> Void
    ) {
        attempted = request
        let operation = UUID()
        self.operation = operation
        task = Task { @MainActor [weak self] in
            let manifest: VideoStoryboardManifest?
            if !Task.isCancelled, ExperimentalSettingsStore.shared.isCurrentAccess(access), isCurrent() {
                manifest = try? await VideoAPI.getStoryboard(aid: request.content.aid, cid: request.content.cid)
            } else {
                manifest = nil
            }
            let admitted = !Task.isCancelled
                && ExperimentalSettingsStore.shared.isCurrentAccess(access) && isCurrent()
            self?.complete(
                manifest, operation: operation, request: request,
                admitted: admitted, didPublish: didPublish
            )
        }
    }

    private func complete(
        _ manifest: VideoStoryboardManifest?, operation: UUID, request: Request, admitted: Bool,
        didPublish: @MainActor () -> Void
    ) {
        guard self.operation == operation, self.request == request else { return }
        self.operation = nil
        task = nil
        guard admitted, isEligible, let manifest else { return }
        samples = PlayerAmbientStoryboardSample.admitted(manifest)
        didPublish()
    }
}
