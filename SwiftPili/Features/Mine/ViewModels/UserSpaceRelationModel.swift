import Foundation
import Observation

@MainActor
@Observable
final class UserSpaceRelationModel {
    struct LoadIdentity: Hashable {
        let mid: Int
        let source: BlocklistManager.AccountSource?
        let membership: BlocklistManager.MembershipReceipt?
        let mutationPending: Bool

        @MainActor
        static func capture(mid: Int) -> Self {
            let source = BlocklistManager.AccountSource.capture()
            let blocklist = BlocklistManager.shared
            return Self(
                mid: mid, source: source, membership: blocklist.membershipReceipt,
                mutationPending: blocklist.isMutating(mid: mid, for: source)
            )
        }
    }

    private var source: BlocklistManager.AccountSource?
    private var targetMid: Int?
    private var follows = false
    private var followingBlockRevision: UInt64 = 0
    private var blocked: Bool?
    private var loadingID: UUID?
    private var followID: UUID?
    private var followRevision: UInt64 = 0

    var isFollowing: Bool {
        guard let mid = targetMid, isCurrentSource else { return false }
        return follows && followingBlockRevision >= BlocklistManager.shared.acceptedBlockRevision(mid: mid)
    }

    var isBlocked: Bool {
        guard let mid = targetMid, isCurrentSource else { return false }
        let blocklist = BlocklistManager.shared
        if let accepted = blocklist.acceptedChange(mid: mid) { return accepted.blocked }
        return blocked ?? blocklist.blockedMids.contains(mid)
    }

    var isLoading: Bool {
        BlocklistManager.AccountSource.capture() != nil && (!isCurrentSource || loadingID != nil)
    }
    var isFollowingInFlight: Bool { followID != nil }

    private var isCurrentSource: Bool {
        source != nil && source == BlocklistManager.AccountSource.capture()
    }

    func load(mid: Int) async {
        let captured = BlocklistManager.AccountSource.capture()
        if source != captured || targetMid != mid {
            follows = false
            followingBlockRevision = 0
            blocked = nil
            followID = nil
        }
        source = captured
        targetMid = mid
        loadingID = nil
        guard !Task.isCancelled, let captured,
              !BlocklistManager.shared.isMutating(mid: mid, for: captured),
              let receipt = BlocklistManager.shared.captureRelation(mid: mid) else { return }
        let id = UUID()
        let capturedFollowRevision = followRevision
        let capturedBlockRevision = BlocklistManager.shared.acceptedBlockRevision(mid: mid)
        loadingID = id
        defer { if loadingID == id { loadingID = nil } }
        do {
            let relation = try await UserAPI.getRelation(mid: mid)
            guard !Task.isCancelled, source == captured, targetMid == mid, loadingID == id,
                  BlocklistManager.shared.isCurrent(receipt) else { return }
            if followID == nil, followRevision == capturedFollowRevision {
                follows = relation.isFollowing
                followingBlockRevision = capturedBlockRevision
            }
            blocked = relation.isBlocked
            if relation.isBlocked { BlocklistManager.shared.insert(mid: mid, receipt: receipt) }
        } catch {
            guard source == captured, loadingID == id,
                  !BiliAPIRetryPolicy.isCancellation(error) else { return }
            PlayerLog.log("[UserSpace] relation failed: \(error)")
        }
    }

    func setBlocked(_ blocked: Bool, mid: Int) {
        let blocklist = BlocklistManager.shared
        switch blocklist.prepareMutation(blocked, mid: mid) {
        case .busy, .authRequired:
            return
        case .admitted(let request):
            Task {
                let outcome = await blocklist.execute(request)
                guard request.source == BlocklistManager.AccountSource.capture() else { return }
                switch outcome {
                case .accepted(let change):
                    if source == request.source, targetMid == mid {
                        self.blocked = blocked
                        if blocked {
                            follows = false
                            followingBlockRevision = change.revision
                        }
                    }
                    PlayerLog.log("[Blocklist] \(blocked ? "blocked" : "unblocked") mid=\(mid) from user space")
                case .failed(let error):
                    guard !BiliAPIRetryPolicy.isCancellation(error) else { return }
                    PlayerLog.log("[Blocklist] toggle failed for mid=\(mid): \(error)")
                case .retired:
                    break
                }
            }
        }
    }

    func toggleFollow(mid: Int) {
        guard isCurrentSource, followID == nil, !BlocklistManager.shared.isMutating(mid: mid),
              let captured = source else { return }
        let id = UUID()
        let wasFollowing = isFollowing
        let capturedBlockRevision = BlocklistManager.shared.acceptedBlockRevision(mid: mid)
        followID = id
        followRevision &+= 1
        Task {
            defer {
                if followID == id {
                    followRevision &+= 1
                    followID = nil
                }
            }
            guard source == captured, captured == BlocklistManager.AccountSource.capture() else { return }
            do {
                if wasFollowing {
                    try await UserAPI.unfollow(mid: mid)
                } else {
                    try await UserAPI.follow(mid: mid)
                }
                guard source == captured, captured == BlocklistManager.AccountSource.capture(),
                      followID == id else { return }
                follows = !wasFollowing
                followingBlockRevision = capturedBlockRevision
            } catch {
                guard source == captured, captured == BlocklistManager.AccountSource.capture(),
                      !BiliAPIRetryPolicy.isCancellation(error) else { return }
                PlayerLog.log("[UserSpace] follow toggle failed: \(error)")
                AppNoticeCenter.shared.showError(String(localized: "Follow failed"))
            }
        }
    }
}
