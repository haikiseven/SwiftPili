import Foundation
import Observation

@MainActor
@Observable
final class BlocklistManager {
    struct AccountSource: Hashable, Sendable {
        let mid: String
        let identityRevision: UInt64
        let sessionGeneration: UUID

        @MainActor
        static func capture() -> Self? {
            let auth = AuthManager.shared
            let accounts = AccountManager.shared
            guard auth.isLoggedIn, let mid = accounts.activeMid,
                  auth.dedeUserID == mid else { return nil }
            return Self(
                mid: mid, identityRevision: accounts.identityRevision,
                sessionGeneration: auth.sessionGeneration
            )
        }
    }

    struct RelationReceipt: Sendable {
        fileprivate let source: AccountSource
        fileprivate let mid: Int
        fileprivate let revision: UInt64
    }

    struct MembershipReceipt: Hashable, Sendable {
        let source: AccountSource
        let revision: UInt64
        let replacementRevision: UInt64
    }

    struct MutationRequest: Sendable {
        let id: UUID
        let source: AccountSource
        let mid: Int
        let blocked: Bool
        fileprivate let authentication: UserAPI.RelationMutationAuthentication
    }

    enum MutationAdmission {
        case admitted(MutationRequest)
        case busy
        case authRequired
    }

    struct AcceptedChange: Sendable {
        let id: UUID
        let source: AccountSource
        let mid: Int
        let blocked: Bool
        let revision: UInt64
    }

    enum MutationOutcome {
        case accepted(AcceptedChange)
        case failed(BiliError)
        case retired
    }

    private struct MutationKey: Hashable {
        let accountMid: String
        let targetMid: Int
    }

    static let shared = BlocklistManager()

    var isEnabled: Bool = UserDefaults.standard.object(forKey: "blocklist_enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "blocklist_enabled") }
    }

    var blockedMids: Set<Int> {
        guard source == AccountSource.capture() else { return [] }
        return cachedMids
    }

    private var cachedMids: Set<Int> = []
    private var source: AccountSource?
    private var loaded = false
    private var loadID: UUID?
    @ObservationIgnored private var loadWork: Task<Void, Never>?
    private var localChanges: [Int: Bool] = [:]
    private var localRevisions: [Int: UInt64] = [:]
    private var membershipRevision: UInt64 = 0
    private var replacementRevision: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    private var acceptedChanges: [Int: AcceptedChange] = [:]
    private var acceptedBlockRevisions: [Int: UInt64] = [:]
    private var pendingMutations: [MutationKey: UUID] = [:]
    private var executingMutations: Set<UUID> = []
    private var reloadAfterMutations: AccountSource?

    private init() {}

    func loadIfNeeded() async {
        let captured = AccountSource.capture()
        synchronizeSource(captured)
        guard !Task.isCancelled, let captured else { return }
        guard !hasPendingMutations(for: captured) else {
            reloadAfterMutations = captured
            return
        }
        guard !loaded else { return }
        guard loadID == nil || loadWork?.isCancelled == true else { return }
        loadWork?.cancel()
        let id = UUID()
        loadID = id
        let work = Task { await fetch(source: captured, id: id) }
        loadWork = work
        defer {
            if loadID == id {
                loadID = nil
                loadWork = nil
            }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func captureRelation(mid: Int) -> RelationReceipt? {
        guard let captured = AccountSource.capture() else { return nil }
        synchronizeSource(captured)
        return RelationReceipt(source: captured, mid: mid, revision: localRevisions[mid, default: 0])
    }

    func isCurrent(_ receipt: RelationReceipt) -> Bool {
        source == receipt.source && AccountSource.capture() == receipt.source
            && localRevisions[receipt.mid, default: 0] == receipt.revision
            && !isMutating(mid: receipt.mid, for: receipt.source)
    }

    func insert(mid: Int, receipt: RelationReceipt) {
        guard mid == receipt.mid, isCurrent(receipt) else { return }
        publishChange(mid: mid, blocked: true)
    }

    func isBlocked(_ mid: Int) -> Bool {
        isEnabled && blockedMids.contains(mid)
    }

    var membershipReceipt: MembershipReceipt? {
        guard let source, source == AccountSource.capture() else { return nil }
        return MembershipReceipt(source: source, revision: membershipRevision, replacementRevision: replacementRevision)
    }

    func captureMembership() -> MembershipReceipt? {
        synchronizeSource(AccountSource.capture())
        return membershipReceipt
    }

    func acceptedChanges(after revision: UInt64, for captured: AccountSource) -> [AcceptedChange] {
        guard source == captured, AccountSource.capture() == captured else { return [] }
        return acceptedChanges.values.filter { $0.revision > revision }
    }

    func acceptedChange(mid: Int) -> AcceptedChange? {
        guard source == AccountSource.capture() else { return nil }
        return acceptedChanges[mid]
    }

    func acceptedBlockRevision(mid: Int) -> UInt64 {
        guard source == AccountSource.capture() else { return 0 }
        return acceptedBlockRevisions[mid, default: 0]
    }

    func isMutating(mid: Int, for captured: AccountSource? = AccountSource.capture()) -> Bool {
        guard let captured else { return false }
        return pendingMutations[MutationKey(accountMid: captured.mid, targetMid: mid)] != nil
    }

    func hasPendingMutations(for captured: AccountSource) -> Bool {
        pendingMutations.keys.contains { $0.accountMid == captured.mid }
    }

    func prepareMutation(_ blocked: Bool, mid: Int) -> MutationAdmission {
        guard let captured = AccountSource.capture(),
              let authentication = UserAPI.RelationMutationAuthentication.capture(mid: captured.mid) else {
            return .authRequired
        }
        synchronizeSource(captured)
        let key = MutationKey(accountMid: captured.mid, targetMid: mid)
        guard pendingMutations[key] == nil else { return .busy }
        let request = MutationRequest(
            id: UUID(), source: captured, mid: mid, blocked: blocked, authentication: authentication
        )
        pendingMutations[key] = request.id
        if !loaded || loadID != nil {
            loadWork?.cancel()
            loadWork = nil
            loadID = nil
            reloadAfterMutations = captured
        }
        return .admitted(request)
    }

    func execute(_ request: MutationRequest) async -> MutationOutcome {
        let key = MutationKey(accountMid: request.source.mid, targetMid: request.mid)
        guard pendingMutations[key] == request.id,
              executingMutations.insert(request.id).inserted else { return .retired }
        defer { finishMutation(request, key: key) }
        guard !Task.isCancelled, AccountSource.capture() == request.source else { return .retired }
        do {
            try await UserAPI.setBlocked(
                request.blocked, mid: request.mid, authentication: request.authentication
            )
        } catch {
            return .failed(error)
        }
        mutationRevision &+= 1
        let accepted = AcceptedChange(
            id: request.id, source: request.source, mid: request.mid,
            blocked: request.blocked, revision: mutationRevision
        )
        synchronizeSource(AccountSource.capture())
        if source == request.source {
            publishChange(mid: request.mid, blocked: request.blocked)
            acceptedChanges[request.mid] = accepted
            if request.blocked { acceptedBlockRevisions[request.mid] = mutationRevision }
            membershipRevision = mutationRevision
        } else if let source, source.mid == request.source.mid {
            cachedMids = []
            localChanges = [:]
            localRevisions[request.mid, default: 0] &+= 1
            loaded = false
            membershipRevision = mutationRevision
            replacementRevision = mutationRevision
            reloadAfterMutations = source
        }
        return .accepted(accepted)
    }

    private func finishMutation(_ request: MutationRequest, key: MutationKey) {
        executingMutations.remove(request.id)
        guard pendingMutations[key] == request.id else { return }
        pendingMutations.removeValue(forKey: key)
        guard let demand = reloadAfterMutations, demand == AccountSource.capture(),
              !hasPendingMutations(for: demand) else { return }
        reloadAfterMutations = nil
        Task {
            guard AccountSource.capture() == demand else { return }
            await loadIfNeeded()
        }
    }

    private func synchronizeSource(_ captured: AccountSource?) {
        guard source != captured else { return }
        loadWork?.cancel()
        loadWork = nil
        loadID = nil
        source = captured
        cachedMids = []
        localChanges = [:]
        localRevisions = [:]
        membershipRevision = 0
        replacementRevision = 0
        acceptedChanges = [:]
        acceptedBlockRevisions = [:]
        reloadAfterMutations = nil
        loaded = false
    }

    private func publishChange(mid: Int, blocked: Bool) {
        localChanges[mid] = blocked
        localRevisions[mid, default: 0] &+= 1
        if blocked {
            cachedMids.insert(mid)
        } else {
            cachedMids.remove(mid)
        }
    }

}

private extension BlocklistManager {
    func fetch(source captured: AccountSource, id: UUID) async {
        var mids: Set<Int> = []
        var page = 1
        var snapshotRevision = membershipRevision
        var restartsRemaining = 1
        do {
            while page <= 20 {
                guard isCurrent(captured, id: id) else { return }
                let result = try await UserAPI.getBlacklist(pn: page)
                guard isCurrent(captured, id: id) else { return }
                guard snapshotRevision == membershipRevision else {
                    guard restartsRemaining > 0 else {
                        PlayerLog.log("[Blocklist] list changed again during load; retry required")
                        return
                    }
                    restartsRemaining -= 1
                    snapshotRevision = membershipRevision
                    page = 1
                    mids = []
                    continue
                }
                guard let users = result.list else {
                    throw BiliError.decodingFailed(CocoaError(.coderReadCorrupt))
                }
                mids.formUnion(users.map(\.mid))
                let reachedTotal = result.total.map { $0 >= 0 && mids.count >= $0 } ?? false
                guard users.count < UserAPI.blockedUsersPageSize || reachedTotal else {
                    page += 1
                    continue
                }
                publishLoaded(mids)
                return
            }
            throw BiliError.decodingFailed(CocoaError(.coderReadCorrupt))
        } catch {
            guard isCurrent(captured, id: id),
                  !(error is CancellationError),
                  (error as? BiliError)?.isCancellation != true else { return }
            PlayerLog.log("[Blocklist] load failed: \(error)")
        }
    }

    private func publishLoaded(_ mids: Set<Int>) {
        var latest = mids
        for (mid, blocked) in localChanges {
            if blocked { latest.insert(mid) } else { latest.remove(mid) }
        }
        cachedMids = latest
        loaded = true
    }

    private func isCurrent(_ captured: AccountSource, id: UUID) -> Bool {
        !Task.isCancelled && loadID == id && source == captured
            && AccountSource.capture() == captured
    }
}
