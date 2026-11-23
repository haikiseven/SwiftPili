import Foundation
import Observation

@MainActor
@Observable
final class FollowingListViewModel {
    typealias Mode = FollowingListView.Mode
    typealias FollowingItem = FollowingListView.FollowingItem
    typealias LoadFailure = FollowingFailureOverlay.Kind

    struct FailureReceipt: Equatable {
        let id = UUID()
        let source: ListSource
        let page: Int
        let replaces: Bool
        let failure: LoadFailure
    }

    struct ListSource: Equatable {
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

    let mode: Mode
    let mid: Int?

    private(set) var items: [FollowingItem] = []
    private(set) var page = 1
    private(set) var isLoading = false
    private(set) var paginationGeneration: UInt64 = 0
    private(set) var followOperations: [Int: UUID] = [:]
    private(set) var loadFailure: FailureReceipt?
    private(set) var tags: [RelationTag] = []
    private(set) var selectedTag: Int?

    @ObservationIgnored private var loadAdmission = FeedLoadAdmissionGate()
    @ObservationIgnored private var loadingRequest: PageRequest?
    @ObservationIgnored private var pageWork: Task<Void, Never>?
    @ObservationIgnored private var accountRevision: UInt64
    @ObservationIgnored private var authManager: AuthManager
    @ObservationIgnored private var accountManager: AccountManager

    init(
        mode: Mode = .following,
        mid: Int? = nil,
        authManager: AuthManager = .shared,
        accountManager: AccountManager = .shared
    ) {
        self.mode = mode
        self.mid = mid
        self.authManager = authManager
        self.accountManager = accountManager
        self.accountRevision = accountManager.identityRevision
    }

    func bind(authManager: AuthManager, accountManager: AccountManager) {
        self.authManager = authManager
        self.accountManager = accountManager
    }

    var isOwnList: Bool {
        mid == nil || mid.map(String.init) == authManager.dedeUserID
    }

    var supportsGroups: Bool {
        mode == .following && isOwnList && authManager.isLoggedIn
    }

    var showsInitialPlaceholder: Bool {
        items.isEmpty && (isLoading || (page == 1 && loadFailure == nil))
    }

    var rowModels: [FollowingRowData] {
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

    var footerState: MineFeedFooterState {
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

    private var listSource: ListSource {
        let account = authManager.dedeUserID
        return ListSource(
            mode: mode, mid: mid ?? Int(account ?? "0") ?? 0,
            tag: supportsGroups ? selectedTag : nil, account: account,
            revision: accountManager.identityRevision, session: authManager.sessionGeneration,
            ownFollowing: mode == .following && isOwnList
        )
    }

    @discardableResult
    func resetForAccountRevisionIfNeeded(_ revision: UInt64) -> Bool {
        guard accountRevision != revision else { return false }
        accountRevision = revision
        pageWork?.cancel()
        pageWork = nil
        loadAdmission.supersede()
        paginationGeneration = loadAdmission.generation
        loadingRequest = nil
        isLoading = false
        items = []
        page = 1
        loadFailure = nil
        tags = []
        selectedTag = nil
        followOperations = [:]
        return true
    }

    func loadInitialIfNeeded() async {
        if items.isEmpty { await loadMore() }
        if supportsGroups, tags.isEmpty { await loadTags() }
    }

    func selectTag(_ tagid: Int?) {
        guard selectedTag != tagid else { return }
        selectedTag = tagid
        reloadForSelectedTag()
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

    func createGroup(name rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let created = try await UserAPI.createRelationTag(name: name)
            PlayerLog.log("[FollowGroups] created group '\(name)' → tagid \(created.tagid.map(String.init) ?? "?")")
            await loadTags()
        } catch {
            PlayerLog.log("[FollowGroups] create group failed: \(error)")
        }
    }

    func requestMore(retrying receipt: FailureReceipt? = nil) {
        if let receipt, receipt.replaces {
            guard !isLoading || pageWork?.isCancelled == true,
                  loadFailure == receipt, receipt.source == listSource else { return }
            _ = startReplacement(for: listSource)
            return
        }
        guard let request = admitPage(retrying: receipt) else { return }
        _ = startPage(request)
    }

    func item(withMid userMid: Int) -> FollowingItem? {
        items.first(where: { $0.mid == userMid })
    }

    func toggleFollow(userMid: Int) {
        guard followOperations[userMid] == nil,
              let current = items.first(where: { $0.mid == userMid }) else { return }
        let request = FollowRequest(
            id: UUID(), mid: userMid, following: !current.isFollowing,
            source: listSource, generation: loadAdmission.generation
        )
        followOperations[userMid] = request.id
        Task { await performFollow(request) }
    }

    // MARK: - Private pagination & mutation helpers

    private func startReplacement(for source: ListSource) -> Task<Void, Never> {
        pageWork?.cancel()
        let token = loadAdmission.supersedeAndAdmit(kind: .refresh, cursor: "1")
        paginationGeneration = loadAdmission.generation
        let request = PageRequest(token: token, source: source, page: 1, replaces: true)
        loadingRequest = request
        loadFailure = nil
        isLoading = true
        return startPage(request)
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
            loadAdmission.supersede()
            paginationGeneration = loadAdmission.generation
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
