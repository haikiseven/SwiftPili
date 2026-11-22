import Observation
import SwiftUI

/// Following / Followers list, for the logged-in account or any other
/// profile, plus the follow-group (分组) chips and editor.
struct FollowingListView: View {
    enum Mode: Equatable {
        case following
        case followers
    }

    /// Same list UI for both relation directions — only the endpoint,
    /// title, and initial follow-state differ.
    var mode: Mode = .following
    /// nil = the logged-in user's own list; a mid opens someone else's.
    var mid: Int?

    @State private var items: [FollowingItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var loadAdmission = FeedLoadAdmissionGate()
    @State private var loadingRequest: PageRequest?
    @State private var pageWork: Task<Void, Never>?
    @State private var accountRevision = AccountManager.shared.identityRevision
    @State private var followOperations: [Int: UUID] = [:]
    @State private var loadFailure: FailureReceipt?
    // Follow groups (own following list only): nil = All. -10 is
    // BiliBili's built-in Special Follow group, 0 the default group.
    @State private var tags: [RelationTag] = []
    @State private var selectedTag: Int?
    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @State private var groupTarget: FollowingItem?
    @Environment(AppCoordinator.self) private var coordinator

    typealias LoadFailure = FollowingFailureOverlay.Kind

    private struct FailureReceipt: Equatable {
        let id = UUID()
        let source: ListSource
        let page: Int
        let replaces: Bool
        let failure: LoadFailure
    }

    private struct ListSource: Equatable {
        let mode: Mode
        let mid: Int
        let tag: Int?
        let account: String?
        let revision: UInt64
        let session: UUID
        let ownFollowing: Bool
    }

    private struct PageRequest: Equatable {
        let id = UUID()
        let token: FeedLoadToken
        let source: ListSource
        let page: Int
        let replaces: Bool
    }

    private struct FollowRequest {
        let id: UUID
        let mid: Int
        let following: Bool
        let source: ListSource
        let generation: UInt64
    }

    private var listSource: ListSource {
        let account = AuthManager.shared.dedeUserID
        return ListSource(
            mode: mode, mid: mid ?? Int(account ?? "0") ?? 0,
            tag: supportsGroups ? selectedTag : nil, account: account,
            revision: AccountManager.shared.identityRevision, session: AuthManager.shared.sessionGeneration,
            ownFollowing: mode == .following && isOwnList
        )
    }

    private var isOwnList: Bool {
        mid == nil || mid.map(String.init) == AuthManager.shared.dedeUserID
    }

    struct FollowingItem: Identifiable {
        let mid: Int
        let uname: String
        let face: String
        let sign: String?
        var isFollowing: Bool
        var id: Int { mid }
    }

    /// Groups apply to MY following list only.
    private var supportsGroups: Bool {
        mode == .following && isOwnList && AuthManager.shared.isLoggedIn
    }

    private var rowModels: [FollowingRowData] {
        let lastIndex = items.count - 1
        return items.enumerated().map { index, user in
            FollowingRowData(
                mid: user.mid,
                uname: user.uname,
                face: user.face,
                sign: user.sign,
                isFollowing: user.isFollowing,
                isFollowBusy: followOperations[user.mid] != nil,
                showsGroupButton: supportsGroups,
                showsSeparator: index < lastIndex
            )
        }
    }

    private var footerState: MineFeedFooterState {
        guard !items.isEmpty else { return .none }
        if let receipt = loadFailure {
            let message: String
            switch receipt.failure {
            case .privacy:
                message = mode == .following
                    ? String(localized: "This user's following list is private.")
                    : String(localized: "This user's followers list is private.")
            case .cancelled:
                message = ""
            case .other(let text):
                message = text
            }
            return .error(message: message, retryTitle: String(localized: "Retry"))
        }
        if isLoading {
            return .loading
        }
        return .none
    }

    var body: some View {
        VStack(spacing: 0) {
            if supportsGroups, !tags.isEmpty {
                FollowingGroupChipsBar(
                    tags: tags,
                    selectedTag: selectedTag,
                    labelForTag: Self.tagDisplayName,
                    onSelectTag: { tagid in
                        guard selectedTag != tagid else { return }
                        selectedTag = tagid
                        reloadForSelectedTag()
                    }
                )
                .frame(maxWidth: ReadableWidth.feed, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            FollowingCollectionView(
                rows: rowModels,
                placeholderCount: showsInitialPlaceholder ? 6 : 0,
                placeholderLabel: loadingAccessibilityLabel,
                footerState: footerState,
                paginationGeneration: loadAdmission.generation,
                onRefresh: {
                    await refresh()
                    return false
                },
                onNearEndAppear: { requestMore() },
                onFooterAction: {
                    if let failure = loadFailure {
                        requestMore(retrying: failure)
                    }
                },
                onSelectUser: { userMid in
                    coordinator.navigate(to: .userSpace(userMid))
                },
                onGroupTap: { userMid in
                    if let user = items.first(where: { $0.mid == userMid }) {
                        groupTarget = user
                    }
                },
                onFollowTap: { userMid in
                    if let user = items.first(where: { $0.mid == userMid }) {
                        toggleFollow(user: user)
                    }
                }
            )
            .overlay {
                if items.isEmpty, !showsInitialPlaceholder {
                    if let failure = loadFailure {
                        failureView(failure)
                    } else if page > 1 {
                        if mode == .following {
                            ContentUnavailableView("No People You Follow", systemImage: "person.2")
                        } else {
                            ContentUnavailableView("Followers", systemImage: "person.2")
                        }
                    }
                }
            }
        }
        .appAmbientBrowseBackground()
        .navigationTitle(mode == .following ? Text("Following") : Text("Followers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if supportsGroups {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newGroupName = ""
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
        }
        .alert(Text("New Group"), isPresented: $showCreateGroup) {
            TextField(String(localized: "Group Name"), text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task { await createGroup() }
            }
        }
        .sheet(item: $groupTarget) { user in
            FollowGroupSheet(user: user, tags: tags) {
                // Membership changed: counts moved, and if a specific
                // group is being viewed its member list may have too.
                Task {
                    await loadTags()
                    if selectedTag != nil { reloadForSelectedTag() }
                }
            }
            .appAdaptiveSheet(padSizing: .form)
        }
        .task(id: AccountManager.shared.identityRevision) {
            if accountRevision != AccountManager.shared.identityRevision {
                accountRevision = AccountManager.shared.identityRevision
                pageWork?.cancel()
                pageWork = nil
                loadAdmission.supersede()
                loadingRequest = nil
                isLoading = false
                items = []
                page = 1
                loadFailure = nil
                tags = []
                selectedTag = nil
                groupTarget = nil
                followOperations = [:]
            }
            if items.isEmpty { await loadMore() }
            if supportsGroups, tags.isEmpty { await loadTags() }
        }
    }

    // MARK: - Follow groups

    static func tagDisplayName(_ tag: RelationTag) -> String {
        switch tag.tagid {
        case -10: String(localized: "Special Follow")
        case 0: String(localized: "Default Group")
        default: tag.name ?? "\(tag.tagid)"
        }
    }
}

private extension FollowingListView {
    var showsInitialPlaceholder: Bool {
        items.isEmpty && (isLoading || (page == 1 && loadFailure == nil))
    }

    var loadingAccessibilityLabel: String {
        let title = mode == .following ? String(localized: "Following") : String(localized: "Followers")
        return String(format: String(localized: "Loading %@"), title)
    }

    func loadTags() async {
        let source = listSource
        do {
            let result = try await UserAPI.getRelationTags()
            guard !Task.isCancelled, listSource == source else { return }
            tags = result
            PlayerLog.log(
                "[FollowGroups] \(tags.count) group(s): "
                    + "\(tags.map { "\($0.tagid)/\($0.name ?? "?")(\($0.count ?? 0))" }.joined(separator: ", "))"
            )
        } catch {
            PlayerLog.log("[FollowGroups] tag list failed: \(error)")
        }
    }

    func reloadForSelectedTag() {
        items = []
        page = 1
        _ = startReplacement(for: listSource)
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let source = listSource
        let work = startReplacement(for: source)
        await withTaskCancellationHandler {
            if supportsGroups {
                async let tagsTask: Void = loadTags()
                await work.value
                await tagsTask
            } else {
                await work.value
            }
        } onCancel: {
            work.cancel()
        }
    }

    private func startReplacement(for source: ListSource) -> Task<Void, Never> {
        pageWork?.cancel()
        let token = loadAdmission.supersedeAndAdmit(kind: .refresh, cursor: "1")
        let request = PageRequest(token: token, source: source, page: 1, replaces: true)
        loadingRequest = request
        loadFailure = nil
        isLoading = true
        return startPage(request)
    }

    func createGroup() async {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let created = try await UserAPI.createRelationTag(name: name)
            PlayerLog.log("[FollowGroups] created group '\(name)' → tagid \(created.tagid.map(String.init) ?? "?")")
            await loadTags()
        } catch {
            PlayerLog.log("[FollowGroups] create group failed: \(error)")
        }
    }

    @ViewBuilder
    private func failureView(_ receipt: FailureReceipt) -> some View {
        FollowingFailureOverlay(
            kind: receipt.failure,
            isFollowingMode: mode == .following,
            onRetry: { requestMore(retrying: receipt) }
        )
    }

    private func requestMore(retrying receipt: FailureReceipt? = nil) {
        if let receipt, receipt.replaces {
            guard !isLoading || pageWork?.isCancelled == true,
                  loadFailure == receipt, receipt.source == listSource else { return }
            _ = startReplacement(for: listSource)
            return
        }
        guard let request = admitPage(retrying: receipt) else { return }
        _ = startPage(request)
    }

    private func startPage(_ request: PageRequest) -> Task<Void, Never> {
        let work = Task { await load(request) }
        pageWork = work
        return work
    }

    private func loadMore() async {
        guard !Task.isCancelled, let request = admitPage() else { return }
        let work = startPage(request)
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func admitPage(retrying receipt: FailureReceipt? = nil) -> PageRequest? {
        guard !isLoading || pageWork?.isCancelled == true else { return nil }
        if let receipt {
            guard loadFailure == receipt, receipt.source == listSource,
                  receipt.page == page else { return nil }
        } else if loadFailure != nil {
            return nil
        }
        if loadingRequest != nil {
            // A cancelled appearance may still be awaiting transport return.
            // Retire its gate before admitting the successor for the same page.
            loadAdmission.supersede()
            pageWork?.cancel()
        }
        guard let token = loadAdmission.admit(
            kind: page == 1 ? .initial : .pagination, cursor: String(page)
        ) else { return nil }
        let request = PageRequest(token: token, source: listSource, page: page, replaces: false)
        loadingRequest = request
        loadFailure = nil
        isLoading = true
        return request
    }

    private func isCurrent(_ request: PageRequest) -> Bool {
        loadingRequest == request && loadAdmission.isCurrent(request.token)
            && listSource == request.source
    }

    private func finishPage(_ request: PageRequest, succeeded: Bool) {
        loadAdmission.finish(request.token, succeeded: succeeded)
        guard loadingRequest == request else { return }
        if !succeeded, loadFailure == nil, listSource == request.source, !request.replaces || items.isEmpty {
            loadFailure = FailureReceipt(
                source: request.source, page: request.page, replaces: request.replaces, failure: .cancelled
            )
        }
        loadingRequest = nil
        pageWork = nil
        isLoading = false
    }

    private func load(_ request: PageRequest) async {
        var succeeded = false
        defer { finishPage(request, succeeded: succeeded) }
        guard !Task.isCancelled, isCurrent(request) else { return }

        do {
            let list: [FollowingResult.FollowingItem]
            if let tagid = request.source.tag {
                // Group filter: members come from the tag endpoint.
                list = try await UserAPI.getRelationTagMembers(tagid: tagid, pn: request.page)
            } else {
                let result = switch request.source.mode {
                case .following: try await UserAPI.getFollowing(mid: request.source.mid, pn: request.page)
                case .followers: try await UserAPI.getFollowers(mid: request.source.mid, pn: request.page)
                }
                list = result.list ?? []
            }
            guard !Task.isCancelled, isCurrent(request) else { return }
            let newItems = list.map { user in
                FollowingItem(
                    mid: user.mid, uname: user.uname,
                    face: user.face, sign: user.sign,
                    // attribute is MY relation to the listed user (2 follow,
                    // 6 mutual). My own following list omits it — everyone
                    // there is followed by definition.
                    isFollowing: request.source.ownFollowing
                        || user.attribute == 2 || user.attribute == 6
                )
            }
            if request.replaces {
                items = FeedCollectionPolicy.replaceDeduplicated(newItems, id: \.mid)
            } else {
                FeedCollectionPolicy.appendDeduplicated(to: &items, incoming: newItems, id: \.mid)
            }
            page = request.page + 1
            loadFailure = nil
            succeeded = true
        } catch let BiliError.apiError(code, message) {
            guard !Task.isCancelled, isCurrent(request) else { return }
            // 22115: 用户已设置隐私，无法查看 — relation lists hidden.
            loadFailure = FailureReceipt(
                source: request.source, page: request.page, replaces: request.replaces,
                failure: code == 22115 ? .privacy : .other(message)
            )
        } catch {
            guard !Task.isCancelled, isCurrent(request), !error.isCancellation else { return }
            loadFailure = FailureReceipt(
                source: request.source, page: request.page, replaces: request.replaces,
                failure: .other(error.localizedDescription)
            )
        }
    }

    private func toggleFollow(user: FollowingItem) {
        guard followOperations[user.mid] == nil,
              let current = items.first(where: { $0.mid == user.mid }) else { return }
        let request = FollowRequest(
            id: UUID(), mid: user.mid, following: !current.isFollowing,
            source: listSource, generation: loadAdmission.generation
        )
        followOperations[user.mid] = request.id
        Task { await performFollow(request) }
    }

    private func performFollow(_ request: FollowRequest) async {
        defer {
            if followOperations[request.mid] == request.id { followOperations[request.mid] = nil }
        }
        guard !Task.isCancelled, listSource == request.source,
              loadAdmission.generation == request.generation else { return }
        do {
            if request.following {
                try await UserAPI.follow(mid: request.mid)
            } else {
                try await UserAPI.unfollow(mid: request.mid)
            }
            guard !Task.isCancelled, followOperations[request.mid] == request.id,
                  listSource == request.source, loadAdmission.generation == request.generation,
                  let index = items.firstIndex(where: { $0.mid == request.mid }) else { return }
            items[index].isFollowing = request.following
        } catch {
            PlayerLog.log("[Following] toggle failed: \(error)")
            guard !Task.isCancelled, !error.isCancellation else { return }
            AppNoticeCenter.shared.showError(String(localized: "Follow failed"))
        }
    }
}
