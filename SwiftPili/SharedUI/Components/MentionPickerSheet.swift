import SwiftUI

struct MentionPickerSheet: View {
    private struct PageRequest: Equatable {
        let id = UUID()
        let page: Int
        let account: CommentEditingPickerReceipt
    }

    let account: CommentEditingPickerReceipt
    let isCurrent: () -> Bool
    let onPick: (String) -> Void

    @State private var followings: [FollowingResult.FollowingItem] = []
    @State private var query = ""
    @State private var nextPage = 1
    @State private var hasMore = true
    @State private var hasAttempted = false
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var recoveryRequest: PageRequest?
    @State private var activeRequest: PageRequest?
    @State private var requestTask: Task<Void, Never>?
    @State private var isRetired = false
    @Environment(\.dismiss) private var dismiss

    private static let pageSize = 50
    private static let maximumPage = 4
    private var isLoading: Bool { activeRequest != nil }

    private var lifetimeIsCurrent: Bool {
        let revision = AccountManager.shared.identityRevision
        let mid = AuthManager.shared.dedeUserID.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        return !isRetired && account.identityRevision == revision && account.mid == mid && isCurrent()
    }

    private var filtered: [FollowingResult.FollowingItem] {
        guard !query.isEmpty else { return followings }
        return followings.filter { $0.uname.localizedCaseInsensitiveContains(query) }
    }

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here, so without this the screen renders the PLATFORM
    // accent while everything behind it renders the chosen one. Declared on
    // the view rather than at the call site so every presentation of it —
    // including future ones — is covered.
    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List {
                if !lifetimeIsCurrent {
                    ContentUnavailableView(
                        "Unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Close and reopen Mention to continue.")
                    )
                } else if account.mid == nil {
                    ContentUnavailableView(
                        "Unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Could not identify the current account.")
                    )
                } else {
                    peopleRows
                    loadingFeedback
                }
            }
            .searchable(text: $query, prompt: "Search following")
            .disabled(!lifetimeIsCurrent || account.mid == nil)
            .navigationTitle("Mention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        retire()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if !hasAttempted { startPage(1) }
        }
        .onChange(of: lifetimeIsCurrent) { _, current in
            if !current { retire() }
        }
        .onDisappear { retire() }
    }

    @ViewBuilder private var peopleRows: some View {
        let people = filtered
        if hasLoaded, !query.isEmpty, people.isEmpty {
            Text("No matches in loaded people.")
                .foregroundStyle(.secondary)
                .frame(minHeight: 56, alignment: .leading)
        } else if hasLoaded, followings.isEmpty {
            ContentUnavailableView("No People You Follow", systemImage: "person.2")
        }
        ForEach(people) { user in
            Button {
                guard validateLifetime(), account.mid != nil else { return }
                onPick(user.uname)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    AvatarImage(urlString: user.face, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.uname)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if let sign = user.sign, !sign.isEmpty {
                            Text(sign)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var loadingFeedback: some View {
        if isLoading || !hasAttempted {
            HStack { Spacer(); ProgressView(); Spacer() }
                .frame(minHeight: hasLoaded ? 56 : 160)
        } else if let recoveryRequest {
            VStack(alignment: .leading, spacing: 8) {
                if let loadError {
                    Text("Load Failed").font(.headline)
                    Text(loadError).foregroundStyle(.secondary)
                }
                Button("Retry") { startPage(recoveryRequest.page, retrying: recoveryRequest) }
            }
            .frame(maxWidth: .infinity, minHeight: hasLoaded ? 56 : 160, alignment: .leading)
        } else if hasMore {
            let page = nextPage
            Button("Load More Following") { startPage(page) }
                .frame(minHeight: 56, alignment: .leading)
        }
    }

    private func validateLifetime() -> Bool {
        guard lifetimeIsCurrent else {
            retire()
            return false
        }
        return true
    }

    private func retire() {
        isRetired = true
        requestTask?.cancel()
        requestTask = nil
        activeRequest = nil
        recoveryRequest = nil
        loadError = nil
    }

    private func startPage(_ page: Int, retrying recovery: PageRequest? = nil) {
        guard !Task.isCancelled, validateLifetime(), let mid = account.mid, mid > 0,
              activeRequest == nil, page == nextPage, (1...Self.maximumPage).contains(page),
              !hasLoaded || hasMore else { return }
        if let recovery {
            guard recoveryRequest == recovery, recovery.page == page, recovery.account == account else { return }
        } else {
            guard recoveryRequest == nil, !hasAttempted || hasLoaded else { return }
        }
        let request = PageRequest(page: page, account: account)
        hasAttempted = true
        loadError = nil
        recoveryRequest = nil
        activeRequest = request
        requestTask = Task { await load(request) }
    }

    private func requestIsCurrent(_ request: PageRequest) -> Bool {
        activeRequest == request && request.account == account && validateLifetime()
    }

    private func load(_ request: PageRequest) async {
        defer {
            if activeRequest == request {
                activeRequest = nil
                requestTask = nil
            }
        }
        guard requestIsCurrent(request), let mid = request.account.mid else { return }
        guard !Task.isCancelled else {
            recoveryRequest = request
            return
        }
        do {
            let result = try await UserAPI.getFollowing(mid: mid, pn: request.page, ps: Self.pageSize)
            guard requestIsCurrent(request) else { return }
            guard !Task.isCancelled else {
                recoveryRequest = request
                return
            }
            guard let list = result.list, list.allSatisfy({ $0.mid > 0 }) else {
                loadError = String(localized: "Couldn't load following people.")
                recoveryRequest = request
                return
            }
            FeedCollectionPolicy.appendDeduplicated(to: &followings, incoming: list, id: \.mid)
            nextPage = request.page + 1
            hasMore = request.page < Self.maximumPage && list.count >= Self.pageSize
            hasLoaded = true
        } catch {
            guard requestIsCurrent(request) else { return }
            recoveryRequest = request
            guard !Task.isCancelled, !error.isCancellation else { return }
            loadError = error.localizedDescription
        }
    }
}
