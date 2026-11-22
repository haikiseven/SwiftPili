import Foundation

@MainActor
struct CommentActionService {
    struct Target: Sendable {
        let oid: Int
        let type: Int
        let rpid: Int
    }

    struct LikeAttempt: Sendable {
        let target: Target
        let previous: (liked: Bool, count: Int)
        let desired: Bool
    }

    struct LikeState {
        private var override: (liked: Bool, count: Int)?

        func current(for comment: CommentResult.CommentItem) -> (liked: Bool, count: Int) {
            override ?? (comment.action == 1, comment.like)
        }

        mutating func begin(for comment: CommentResult.CommentItem, isLoggedIn: Bool) -> LikeAttempt? {
            guard isLoggedIn else { return nil }
            guard let oid = comment.oid else {
                PlayerLog.log("[Comment] like unavailable: reply \(comment.rpid) carries no oid")
                return nil
            }
            let previous = current(for: comment)
            override = (liked: !previous.liked, count: max(0, previous.count + (previous.liked ? -1 : 1)))
            return LikeAttempt(
                target: Target(oid: oid, type: comment.type ?? 1, rpid: comment.rpid),
                previous: previous,
                desired: !previous.liked
            )
        }

        mutating func settle(_ result: Result<Void, BiliError>, for attempt: LikeAttempt) {
            if case .failure(let error) = result {
                override = attempt.previous
                PlayerLog.log("[Comment] like failed: \(error)")
            }
        }
    }

    typealias Like = @MainActor (Target, Bool) async throws(BiliError) -> EmptyResult
    typealias Report = @MainActor (Target, Int, String) async throws(BiliError) -> EmptyResult
    typealias Delete = @MainActor (Target) async throws(BiliError) -> EmptyResult
    typealias PrepareBlock = @MainActor (Bool, Int) -> BlocklistManager.MutationAdmission
    typealias ExecuteBlock = @MainActor (BlocklistManager.MutationRequest) async -> BlocklistManager.MutationOutcome

    struct Dependencies {
        let isLoggedIn: @MainActor () -> Bool
        let like: Like
        let report: Report
        let delete: Delete
        let prepareBlock: PrepareBlock
        let executeBlock: ExecuteBlock

        init(
            isLoggedIn: @escaping @MainActor () -> Bool = { AuthManager.shared.isLoggedIn },
            like: @escaping Like = { (target, liked) async throws(BiliError) in
                try await CommentAPI.likeComment(
                    oid: target.oid, type: target.type, rpid: target.rpid, like: liked
                )
            },
            report: @escaping Report = { (target, reason, content) async throws(BiliError) in
                try await CommentAPI.reportComment(
                    oid: target.oid, type: target.type, rpid: target.rpid, reason: reason, content: content
                )
            },
            delete: @escaping Delete = { (target) async throws(BiliError) in
                try await CommentAPI.deleteComment(oid: target.oid, type: target.type, rpid: target.rpid)
            },
            prepareBlock: @escaping PrepareBlock = { BlocklistManager.shared.prepareMutation($0, mid: $1) },
            executeBlock: @escaping ExecuteBlock = { await BlocklistManager.shared.execute($0) }
        ) {
            self.isLoggedIn = isLoggedIn
            self.like = like
            self.report = report
            self.delete = delete
            self.prepareBlock = prepareBlock
            self.executeBlock = executeBlock
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    var isLoggedIn: Bool { dependencies.isLoggedIn() }

    func setLike(_ attempt: LikeAttempt) async -> Result<Void, BiliError> {
        do {
            _ = try await dependencies.like(attempt.target, attempt.desired)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func report(_ target: Target, reason: Int, content: String) async -> Result<Void, BiliError> {
        do {
            _ = try await dependencies.report(target, reason, content)
            PlayerLog.log("[CommentReport] ✓ accepted rpid=\(target.rpid) reason=\(reason)")
            return .success(())
        } catch {
            PlayerLog.log("[CommentReport] ✗ FAILED rpid=\(target.rpid) reason=\(reason): \(error)")
            return .failure(error)
        }
    }

    func delete(_ target: Target) async -> Result<Void, BiliError> {
        do {
            _ = try await dependencies.delete(target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func prepareBlocked(_ blocked: Bool, mid: Int) -> BlocklistManager.MutationAdmission {
        dependencies.prepareBlock(blocked, mid)
    }

    func setBlocked(_ request: BlocklistManager.MutationRequest) async -> BlocklistManager.MutationOutcome {
        let outcome = await dependencies.executeBlock(request)
        guard request.source == BlocklistManager.AccountSource.capture() else { return outcome }
        switch outcome {
        case .accepted:
            let action = request.blocked ? "blocked" : "unblocked"
            PlayerLog.log("[Blocklist] \(action) mid=\(request.mid) from comment row")
        case .failed(let error):
            if !error.isCancellation {
                PlayerLog.log("[Blocklist] toggle failed for mid=\(request.mid): \(error)")
            }
        case .retired:
            break
        }
        return outcome
    }
}
