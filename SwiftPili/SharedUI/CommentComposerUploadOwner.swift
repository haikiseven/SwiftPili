import Foundation
import Observation

@MainActor
@Observable
final class CommentComposerUploadOwner {
    struct SourceIdentity: Equatable, Hashable, Sendable {
        let owner: UUID
        let sourceRevision: UInt64
    }

    struct Context: Equatable, Hashable, Sendable {
        let owner: UUID
        let sourceRevision: UInt64
        let replacementEpoch: UInt64

        var sourceIdentity: SourceIdentity {
            SourceIdentity(owner: owner, sourceRevision: sourceRevision)
        }
    }

    struct Batch: Equatable, Sendable {
        fileprivate let identifier: UUID
        let context: Context
    }

    private var activeBatch: Batch?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isUploading: Bool { activeBatch != nil }

    func begin(context: Context) -> Batch? {
        guard activeBatch == nil else { return nil }
        let batch = Batch(identifier: UUID(), context: context)
        activeBatch = batch
        error = nil
        return batch
    }

    func owns(_ batch: Batch) -> Bool { activeBatch == batch }

    func attach(_ task: Task<Void, Never>, to batch: Batch) {
        guard owns(batch) else {
            task.cancel()
            return
        }
        self.task = task
    }

    func setError(_ message: String, for batch: Batch) {
        guard owns(batch) else { return }
        error = message
    }

    func finish(_ batch: Batch) {
        guard owns(batch) else { return }
        activeBatch = nil
        task = nil
    }

    func retire() {
        task?.cancel()
        task = nil
        activeBatch = nil
        error = nil
    }
}

@MainActor
struct CommentComposerUploadScope {
    let owner: CommentComposerUploadOwner
    let context: CommentComposerUploadOwner.Context
    let isCurrent: () -> Bool
    let onAdmission: () -> Void

    func prepare(origin: CommentComposerUploadOwner.Context) -> CommentComposerUploadOwner.Batch? {
        guard origin == context, isCurrent(), let batch = owner.begin(context: context) else { return nil }
        onAdmission()
        return batch
    }

    func admits(_ batch: CommentComposerUploadOwner.Batch) -> Bool {
        !Task.isCancelled && batch.context == context && isCurrent() && owner.owns(batch)
    }
}
