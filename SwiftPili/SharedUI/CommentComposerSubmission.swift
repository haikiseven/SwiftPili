import Foundation

struct CommentComposerSubmission: Sendable {
    struct Attempt: Equatable, Sendable {
        fileprivate let identifier: UUID
        fileprivate let draftRevision: UInt64
    }

    private var draftRevision: UInt64 = 0
    private var activeAttempt: Attempt?
    private var latestAttempt: Attempt?

    var isSending: Bool { activeAttempt != nil }

    mutating func draftDidChange() {
        draftRevision &+= 1
    }

    mutating func begin() -> Attempt? {
        guard activeAttempt == nil else { return nil }
        let attempt = Attempt(identifier: UUID(), draftRevision: draftRevision)
        activeAttempt = attempt
        latestAttempt = attempt
        return attempt
    }

    @discardableResult
    mutating func finish(_ attempt: Attempt) -> Bool {
        guard activeAttempt == attempt else { return false }
        activeAttempt = nil
        return true
    }

    func canApply(_ attempt: Attempt) -> Bool {
        latestAttempt == attempt && draftRevision == attempt.draftRevision
    }
}
