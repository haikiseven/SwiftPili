import Foundation
import Observation

/// One user-requested submission, followed only by bounded anonymous reads.
@MainActor
@Observable
final class CommentCheckOperation {
    struct Input {
        let oid: Int
        let message: String
        let accountID: String
    }

    enum Phase: Equatable { case posting, verifying }

    enum Outcome: Equatable {
        case visible, notFound, indeterminate, submissionFailed

        var symbol: String {
            switch self {
            case .visible: "checkmark.circle.fill"
            case .notFound: "magnifyingglass"
            case .indeterminate: "questionmark.circle"
            case .submissionFailed: "exclamationmark.circle"
            }
        }
    }

    struct Result {
        let outcome: Outcome
        let replyID: Int?
        var errorMessage: String?
    }

    private struct PostedReply {
        let input: Input
        let replyID: Int
    }

    private struct Operation {
        let id = UUID()
        let input: Input
        let permit = ExperimentalAccessPermit()
    }

    private(set) var input: Input?
    private(set) var phase: Phase?
    private(set) var result: Result?
    var isChecking: Bool { phase != nil }
    private let access: ExperimentalAccessReceipt
    private let experiments = ExperimentalSettingsStore.shared
    @ObservationIgnored private var active: Operation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var postedReply: PostedReply?

    init(access: ExperimentalAccessReceipt) {
        self.access = access
    }

    func canPost(oid: String, message: String) -> Bool {
        !isChecking && admittedInput(oid: oid, message: message) != nil
    }

    func post(oid: String, message: String) {
        guard active == nil, let captured = admittedInput(oid: oid, message: message) else { return }
        postedReply = nil
        let operation = admit(captured, phase: .posting)
        task = Task { await submit(operation) }
    }

    var canRetryVerification: Bool {
        guard !isChecking, let postedReply, result?.outcome != .visible else { return false }
        return isAvailable(for: postedReply.input.accountID)
    }

    func retryVerification() {
        guard active == nil, canRetryVerification, let postedReply else { return }
        let operation = admit(postedReply.input, phase: .verifying)
        task = Task {
            defer { finish(operation) }
            await verify(postedReply, operation: operation)
        }
    }

    func retire() {
        active?.permit.revoke()
        active = nil
        task?.cancel()
        task = nil
        phase = nil
        input = nil
        result = nil
        postedReply = nil
    }

    private func admittedInput(oid: String, message: String) -> Input? {
        guard let oid = Int(oid.trimmingCharacters(in: .whitespacesAndNewlines)), oid > 0,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let accountID = AccountManager.shared.activeMid ?? AuthManager.shared.dedeUserID,
              isAvailable(for: accountID) else { return nil }
        return Input(oid: oid, message: message, accountID: accountID)
    }

    private func isAvailable(for accountID: String) -> Bool {
        AuthManager.shared.isLoggedIn
            && (AccountManager.shared.activeMid ?? AuthManager.shared.dedeUserID) == accountID
            && access.feature == .commentTools
            && experiments.isCurrentAccess(access) && experiments.storageError == nil
    }

    private func admit(_ captured: Input, phase: Phase) -> Operation {
        let operation = Operation(input: captured)
        active = operation
        input = captured
        self.phase = phase
        result = nil
        return operation
    }

    private func isCurrent(_ operation: Operation) -> Bool {
        active?.id == operation.id && operation.permit.isValid && !Task.isCancelled
            && isAvailable(for: operation.input.accountID)
    }

    private func finish(_ operation: Operation) {
        operation.permit.revoke()
        guard active?.id == operation.id else { return }
        active = nil
        task = nil
        phase = nil
    }

    private func submit(_ operation: Operation) async {
        defer { finish(operation) }
        guard isCurrent(operation) else { return }
        do {
            let posted = try await CommentAPI.postComment(
                oid: operation.input.oid, message: operation.input.message
            )
            guard isCurrent(operation) else { return }
            guard let replyID = posted.rpid, replyID > 0 else {
                result = Result(outcome: .indeterminate, replyID: nil)
                return
            }
            let reply = PostedReply(input: operation.input, replyID: replyID)
            postedReply = reply
            phase = .verifying
            await verify(reply, operation: operation)
        } catch {
            guard isCurrent(operation), !error.isCancellation else { return }
            PlayerLog.log("[CommentCheck] submission failed: \(error)")
            result = Result(outcome: .submissionFailed, replyID: nil, errorMessage: error.localizedDescription)
        }
    }

    private func verify(_ reply: PostedReply, operation: Operation) async {
        // Match the existing VOD propagation allowance; no additional POST occurs.
        let delays: [Double] = [3, 12, 30]
        var sawUnknown = false
        for delay in delays {
            guard isCurrent(operation) else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard isCurrent(operation) else { return }
            let visibility = await CommentAPI.checkCommentVisibleAnonymously(
                oid: reply.input.oid, rpid: reply.replyID, access: access, operation: operation.permit
            )
            guard isCurrent(operation) else { return }
            switch visibility {
            case .visible:
                result = Result(outcome: .visible, replyID: reply.replyID)
                return
            case .hidden:
                break
            case .unknown:
                sawUnknown = true
            }
        }
        guard isCurrent(operation) else { return }
        result = Result(outcome: sawUnknown ? .indeterminate : .notFound, replyID: reply.replyID)
    }
}
