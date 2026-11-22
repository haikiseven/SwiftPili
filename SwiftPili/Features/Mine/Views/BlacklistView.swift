import Observation
import SwiftUI

/// Settings → Blacklist, with account-owned loading and explicit retry.
struct BlacklistView: View {
    var body: some View {
        BlockedUsersContentView()
            .id(AccountManager.shared.identityRevision)
    }
}

private struct BlockedUsersContentView: View {
    @State private var model = BlockedUsersListModel()
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        List {
            if !model.users.isEmpty {
                Section {
                    ForEach(model.users) { user in
                        blockedUserRow(user)
                            .swipeActions(edge: .trailing) {
                                Button { model.startUnblock(user) } label: {
                                    Text("Unblock")
                                }
                                .tint(Color.biliAccent)
                                .disabled(model.isBusy)
                            }
                            .onAppear {
                                if user.id == model.users.last?.id {
                                    Task { await model.loadMore() }
                                }
                            }
                    }
                }
                .listRowBackground(AppFill.card)
                Section {
                    if let failure = model.loadFailure {
                        failureView(failure)
                    } else if model.isBusy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if model.hasMore {
                        Button("More") { Task { await model.loadMore() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .listRowBackground(AppFill.card)
            }
        }
        .refreshable {
            await model.refresh()
            await BlocklistManager.shared.loadIfNeeded()
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !model.isSignedIn {
                ContentUnavailableView("Sign In Required", systemImage: "person.crop.circle")
            } else if model.users.isEmpty {
                if model.isBusy || !model.hasLoaded && model.loadFailure == nil {
                    ProgressView()
                } else if let failure = model.loadFailure {
                    failureView(failure)
                } else if model.hasMore {
                    Button("More") { Task { await model.loadMore() } }
                        .frame(minHeight: 44)
                } else {
                    ContentUnavailableView(
                        "No Blocked Users", systemImage: "hand.raised",
                        description: Text("Users you block on BiliBili appear here.")
                    )
                }
            }
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.clearActionError() } }
        )) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .task(id: model.loadIdentity) { await model.loadMore() }
        .task { await BlocklistManager.shared.loadIfNeeded() }
    }

    private func failureView(_ failure: BlockedUsersListModel.LoadFailure) -> some View {
        MessageLoadFailureView(message: failure.message) {
            Task {
                await model.loadMore(retrying: failure)
                await BlocklistManager.shared.loadIfNeeded()
            }
        }
    }

    private func blockedUserRow(_ user: BlacklistResult.BlockedUser) -> some View {
        HStack(spacing: AppSpacing.m) {
            Button {
                coordinator.navigate(to: .userSpace(user.mid))
            } label: {
                HStack(spacing: AppSpacing.m) {
                    AvatarImage(urlString: user.face ?? "", size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.uname ?? "\(user.mid)")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let mtime = user.mtime, mtime > 0 {
                            Text("Blocked \(FormatUtils.timeAgo(from: mtime))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: AppSpacing.s)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.startUnblock(user) } label: {
                Text("Unblock")
                    .appFont(.controlLabel)
                    .fontWeight(.medium)
                    .padding(.horizontal, AppSpacing.m)
                    .padding(.vertical, 6)
                    .background(AppFill.inset, in: Capsule())
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
        }
    }
}

@MainActor
@Observable
private final class BlockedUsersListModel {
    struct LoadFailure: Equatable {
        let id = UUID()
        let page: Int
        let replacing: Bool
        let message: String
    }

    struct LoadIdentity: Hashable {
        let membership: BlocklistManager.MembershipReceipt?
        let mutationPending: Bool
    }

    private(set) var users: [BlacklistResult.BlockedUser] = []
    private(set) var hasLoaded = false
    private(set) var hasMore = true
    private(set) var loadFailure: LoadFailure?
    private(set) var actionError: String?
    var isBusy: Bool { loadID != nil || hasPendingMutation }
    var isSignedIn: Bool { source != nil && source == BlocklistManager.AccountSource.capture() }
    var loadIdentity: LoadIdentity {
        LoadIdentity(membership: BlocklistManager.shared.membershipReceipt, mutationPending: hasPendingMutation)
    }
    private let source = BlocklistManager.AccountSource.capture()
    private var page = 1
    private var loadID: UUID?
    private var observedMembership: BlocklistManager.MembershipReceipt?
    private var needsReplacement = false
    @ObservationIgnored private var loadWork: Task<Void, Never>?

    private var hasPendingMutation: Bool {
        source.map { BlocklistManager.shared.hasPendingMutations(for: $0) } ?? false
    }

    func clearActionError() { actionError = nil }

    func refresh() async {
        guard !Task.isCancelled, isSignedIn else { return }
        reconcileAcceptedChanges()
        guard !hasPendingMutation else { return }
        loadWork?.cancel()
        let id = UUID()
        let previousFailure = loadFailure
        let membership = observedMembership
        loadID = id
        loadFailure = nil
        let work = Task {
            await fetchPage(1, replacing: true, membership: membership, id: id)
        }
        loadWork = work
        defer {
            if loadID == id {
                loadID = nil
                loadWork = nil
                if Task.isCancelled, !hasLoaded, users.isEmpty, loadFailure == nil {
                    loadFailure = previousFailure
                }
            }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func loadMore(retrying failure: LoadFailure? = nil) async {
        guard !Task.isCancelled, isSignedIn else { return }
        reconcileAcceptedChanges()
        guard !hasPendingMutation else { return }
        if let failure, failure.replacing {
            guard loadFailure == failure, loadID == nil || loadWork?.isCancelled == true else { return }
            await refresh()
            return
        }
        guard hasMore || needsReplacement else { return }
        if let failure {
            guard loadFailure == failure, failure.replacing == needsReplacement,
                  failure.page == (needsReplacement ? 1 : page) else { return }
        } else if loadFailure != nil {
            return
        }
        guard loadID == nil || loadWork?.isCancelled == true else { return }
        loadWork?.cancel()
        let id = UUID()
        let requestedPage = needsReplacement ? 1 : page
        let replacing = needsReplacement
        let membership = observedMembership
        loadID = id
        loadFailure = nil
        let work = Task {
            await fetchPage(requestedPage, replacing: replacing, membership: membership, id: id)
        }
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

    func startUnblock(_ user: BlacklistResult.BlockedUser) {
        guard isSignedIn, !isBusy, users.contains(where: { $0.mid == user.mid }) else { return }
        let blocklist = BlocklistManager.shared
        switch blocklist.prepareMutation(false, mid: user.mid) {
        case .busy, .authRequired:
            return
        case .admitted(let request):
            actionError = nil
            Task {
                let outcome = await blocklist.execute(request)
                guard isSignedIn, request.source == source else { return }
                switch outcome {
                case .accepted:
                    reconcileAcceptedChanges()
                case .failed(let error):
                    guard !Task.isCancelled, shouldPresent(error) else { return }
                    actionError = error.localizedDescription
                    PlayerLog.log("[Blacklist] unblock failed: \(error)")
                case .retired:
                    break
                }
            }
        }
    }

    /// Consume only proven accepted mutations, never absence from a partial cache.
    private func reconcileAcceptedChanges() {
        let blocklist = BlocklistManager.shared
        guard let source, let receipt = blocklist.captureMembership(), receipt.source == source,
              observedMembership != receipt else { return }
        let previousRevision = observedMembership?.revision ?? 0
        let changes = blocklist.acceptedChanges(after: previousRevision, for: source)
        let unblocked = Set(changes.filter { !$0.blocked }.map(\.mid))
        users.removeAll { unblocked.contains($0.mid) }
        if hasMore, !unblocked.isEmpty {
            // Deletions shift offset boundaries, including those reached elsewhere.
            let shiftedPages = (unblocked.count + UserAPI.blockedUsersPageSize - 1) / UserAPI.blockedUsersPageSize
            page = max(1, page - shiftedPages)
        }
        let invalidatedSnapshot = receipt.replacementRevision > (observedMembership?.replacementRevision ?? 0)
        if changes.contains(where: \.blocked) || invalidatedSnapshot {
            // New blocked users need their full DTOs. A retired credential's
            // accepted write likewise requires a real current-source snapshot.
            needsReplacement = true
        }
        loadWork?.cancel()
        loadWork = nil
        loadID = nil
        loadFailure = nil
        observedMembership = receipt
    }

    private func fetchPage(
        _ requestedPage: Int, replacing: Bool,
        membership: BlocklistManager.MembershipReceipt?, id: UUID
    ) async {
        guard isCurrentLoad(id, membership: membership) else { return }
        do {
            let result = try await UserAPI.getBlacklist(pn: requestedPage)
            guard isCurrentLoad(id, membership: membership) else { return }
            guard let fresh = result.list else {
                throw BiliError.decodingFailed(CocoaError(.coderReadCorrupt))
            }
            var retained = replacing ? [] : Set(users.map(\.mid))
            let accepted = fresh.filter {
                BlocklistManager.shared.acceptedChange(mid: $0.mid)?.blocked != false
                    && retained.insert($0.mid).inserted
            }
            if replacing { users = accepted } else { users.append(contentsOf: accepted) }
            hasMore = fresh.count >= UserAPI.blockedUsersPageSize
                && (result.total.map { requestedPage * UserAPI.blockedUsersPageSize < $0 } ?? true)
            page = requestedPage + 1
            hasLoaded = true
            needsReplacement = false
        } catch {
            guard isCurrentLoad(id, membership: membership), shouldPresent(error) else { return }
            loadFailure = LoadFailure(page: requestedPage, replacing: replacing, message: error.localizedDescription)
            PlayerLog.log("[Blacklist] load failed: \(error)")
        }
    }

    private func isCurrentLoad(_ id: UUID, membership: BlocklistManager.MembershipReceipt?) -> Bool {
        !Task.isCancelled && isSignedIn && loadID == id && !hasPendingMutation
            && BlocklistManager.shared.membershipReceipt == membership
    }

    private func shouldPresent(_ error: any Error) -> Bool {
        !(error is CancellationError) && (error as? BiliError)?.isCancellation != true
    }
}
