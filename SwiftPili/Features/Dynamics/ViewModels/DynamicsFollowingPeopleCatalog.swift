import Foundation
import Observation

struct DynamicFollowingPerson: Hashable, Sendable, Identifiable {
    let mid: Int
    let name: String
    let face: String?
    let hasUpdate: Bool

    var id: Int { mid }

    init(updateItem: DynamicUpItem) {
        mid = updateItem.mid
        name = updateItem.uname ?? ""
        face = updateItem.face
        hasUpdate = updateItem.hasUpdate ?? false
    }

    init(followingItem: FollowingResult.FollowingItem) {
        mid = followingItem.mid
        name = followingItem.uname
        face = followingItem.face
        hasUpdate = false
    }

    var displayName: String {
        name.isEmpty ? String(localized: "Unknown User") : name
    }
}

@MainActor
@Observable
final class DynamicsFollowingPeopleCatalog {
    private static let relationshipPageSize = 50

    private(set) var recentPeople: [DynamicFollowingPerson] = []
    private(set) var isLoadingRecent = false
    private(set) var recentHasLoaded = false
    private(set) var recentHasMore = false
    private(set) var recentFailure: String?

    private(set) var followingPeople: [DynamicFollowingPerson] = []
    private(set) var isLoadingFollowing = false
    private(set) var followingHasLoaded = false
    private(set) var followingHasMore = false
    private(set) var followingFailure: String?

    @ObservationIgnored private var ownerAccountMID: Int?
    @ObservationIgnored private var recentOffset: String?
    @ObservationIgnored private var recentVisitedOffsets: Set<String> = []
    @ObservationIgnored private var recentAdmission = FeedLoadAdmission()
    @ObservationIgnored private var recentLoadingToken: FeedLoadToken?
    @ObservationIgnored private var followingPage = 1
    @ObservationIgnored private var followingAdmission = FeedLoadAdmission()
    @ObservationIgnored private var followingLoadingToken: FeedLoadToken?

    func person(for mid: Int?) -> DynamicFollowingPerson? {
        guard let mid else { return nil }
        return recentPeople.first(where: { $0.mid == mid })
            ?? followingPeople.first(where: { $0.mid == mid })
    }

    func loadRecentPeopleIfNeeded() async {
        guard !Task.isCancelled, prepareAccount() != nil else { return }
        guard !recentHasLoaded else { return }
        await loadMoreRecentPeople()
    }

    func loadMoreRecentPeople() async {
        guard !Task.isCancelled, let accountMID = prepareAccount() else { return }
        guard !isLoadingRecent, recentHasMore || !recentHasLoaded else { return }

        let loadsPortal = !recentHasLoaded
        let requestedOffset = loadsPortal ? "" : (recentOffset ?? "")
        let kind: FeedLoadKind = loadsPortal ? .initial : .pagination
        let cursor = loadsPortal ? "portal" : "uplist:\(requestedOffset)"
        guard let token = recentAdmission.admit(kind: kind, cursor: cursor) else { return }

        recentLoadingToken = token
        isLoadingRecent = true
        recentFailure = nil
        var succeeded = false
        defer {
            recentAdmission.finish(token, succeeded: succeeded)
            if recentLoadingToken == token {
                recentLoadingToken = nil
                isLoadingRecent = false
            }
        }

        do {
            let page = try await requestRecentPage(
                loadsPortal: loadsPortal,
                requestedOffset: requestedOffset
            )
            guard isCurrentRecentRequest(token, accountMID: accountMID),
                  !Task.isCancelled else { return }
            guard let page else {
                recentFailure = String(localized: "Couldn't load recent people.")
                return
            }
            guard publishRecentPage(page, loadsPortal: loadsPortal, requestedOffset: requestedOffset) else { return }
            succeeded = true
        } catch {
            guard isCurrentRecentRequest(token, accountMID: accountMID) else { return }
            guard !Task.isCancelled,
                  !BiliAPIRetryPolicy.isCancellation(error),
                  !error.isCancellation else { return }
            recentFailure = recentHasLoaded
                ? String(localized: "Couldn't load more recent people.")
                : String(localized: "Couldn't load recent people.")
            PlayerLog.log("[DynamicsPeople] recent people request failed: \(error)")
        }
    }

    func loadFollowingPeopleIfNeeded() async {
        guard !Task.isCancelled, prepareAccount() != nil else { return }
        guard !followingHasLoaded else { return }
        await loadMoreFollowingPeople()
    }

    func loadMoreFollowingPeople() async {
        guard !Task.isCancelled, let accountMID = prepareAccount() else { return }
        guard !isLoadingFollowing,
              !followingHasLoaded || followingHasMore else { return }
        let requestedPage = followingPage
        let kind: FeedLoadKind = followingHasLoaded ? .pagination : .initial
        let cursor = "page:\(requestedPage)"
        guard let token = followingAdmission.admit(kind: kind, cursor: cursor) else { return }

        followingLoadingToken = token
        isLoadingFollowing = true
        followingFailure = nil
        var succeeded = false
        defer {
            followingAdmission.finish(token, succeeded: succeeded)
            if followingLoadingToken == token {
                followingLoadingToken = nil
                isLoadingFollowing = false
            }
        }

        do {
            let result = try await UserAPI.getFollowing(
                mid: accountMID, pn: requestedPage, ps: Self.relationshipPageSize
            )
            guard isCurrentFollowingRequest(token, accountMID: accountMID),
                  !Task.isCancelled,
                  publishFollowingPage(result, requestedPage: requestedPage) else { return }
            succeeded = true
        } catch {
            guard isCurrentFollowingRequest(token, accountMID: accountMID) else { return }
            guard !Task.isCancelled,
                  !BiliAPIRetryPolicy.isCancellation(error),
                  !error.isCancellation else { return }
            followingFailure = followingHasLoaded
                ? String(localized: "Couldn't load more following people.")
                : String(localized: "Couldn't load following people.")
            PlayerLog.log("[DynamicsPeople] relationship list failed: \(error)")
        }
    }

    private func requestRecentPage(
        loadsPortal: Bool,
        requestedOffset: String
    ) async throws(BiliError) -> DynamicFollowingUpdatePage? {
        if loadsPortal {
            return try await DynamicAPI.getFollowingPeoplePortal().upList
        }
        return try await DynamicAPI.getFollowingPeopleUpdates(offset: requestedOffset)
    }

    private func publishRecentPage(
        _ page: DynamicFollowingUpdatePage,
        loadsPortal: Bool,
        requestedOffset: String
    ) -> Bool {
        guard let items = page.items, let hasMore = page.hasMore else {
            recentFailure = String(localized: "Couldn't load recent people.")
            return false
        }

        var nextVisitedOffsets = loadsPortal ? Set<String>() : recentVisitedOffsets
        if hasMore {
            guard let nextOffset = page.offset,
                  !nextOffset.isEmpty,
                  nextOffset != requestedOffset,
                  nextVisitedOffsets.insert(nextOffset).inserted else {
                recentFailure = String(localized: "Couldn't load more recent people.")
                return false
            }
        }

        let people = items.map(DynamicFollowingPerson.init(updateItem:))
        if loadsPortal {
            recentPeople = FeedCollectionPolicy.replaceDeduplicated(people, id: \.id)
        } else {
            FeedCollectionPolicy.appendDeduplicated(to: &recentPeople, incoming: people, id: \.id)
        }
        recentOffset = page.offset
        recentVisitedOffsets = nextVisitedOffsets
        recentHasMore = hasMore
        recentHasLoaded = true
        recentFailure = nil
        return true
    }

    private func publishFollowingPage(
        _ result: FollowingResult,
        requestedPage: Int
    ) -> Bool {
        guard let users = result.list, users.allSatisfy({ $0.mid > 0 }) else {
            followingFailure = String(localized: "Couldn't load following people.")
            return false
        }

        let people = users.map(DynamicFollowingPerson.init(followingItem:))
        if followingHasLoaded {
            FeedCollectionPolicy.appendDeduplicated(
                to: &followingPeople, incoming: people, id: \.id
            )
        } else {
            followingPeople = FeedCollectionPolicy.replaceDeduplicated(people, id: \.id)
        }
        followingHasMore = hasMoreFollowing(result.total, userCount: users.count, page: requestedPage)
        followingPage = requestedPage + 1
        followingHasLoaded = true
        followingFailure = nil
        return true
    }

    private func hasMoreFollowing(_ total: Int?, userCount: Int, page: Int) -> Bool {
        guard let total else { return userCount == Self.relationshipPageSize }
        return page * Self.relationshipPageSize < total
    }

    private func prepareAccount() -> Int? {
        guard let accountMID = activeAccountMID else {
            resetIfAccountChanged(to: nil)
            let error = AuthManager.shared.isLoggedIn
                ? String(localized: "Could not identify the current account.")
                : String(localized: "Sign in to view dynamics.")
            recentFailure = error
            followingFailure = error
            return nil
        }
        resetIfAccountChanged(to: accountMID)
        return accountMID
    }

    private var activeAccountMID: Int? {
        guard AuthManager.shared.isLoggedIn else { return nil }
        let rosterMID = AccountManager.shared.activeMid.flatMap(Int.init)
        let authenticatedMID = AuthManager.shared.dedeUserID.flatMap(Int.init)
        if let rosterMID, let authenticatedMID, rosterMID != authenticatedMID { return nil }
        guard let mid = rosterMID ?? authenticatedMID, mid > 0 else { return nil }
        return mid
    }

    private func resetIfAccountChanged(to accountMID: Int?) {
        guard ownerAccountMID != accountMID else { return }
        recentAdmission.supersede()
        recentLoadingToken = nil
        isLoadingRecent = false
        recentPeople = []
        recentOffset = nil
        recentVisitedOffsets = []
        recentHasLoaded = false
        recentHasMore = false
        recentFailure = nil
        followingAdmission.supersede()
        followingLoadingToken = nil
        isLoadingFollowing = false
        followingPeople = []
        followingPage = 1
        followingHasLoaded = false
        followingHasMore = false
        followingFailure = nil
        ownerAccountMID = accountMID
    }

    private var currentAccountMID: Int? {
        activeAccountMID
    }

    private func isCurrentRecentRequest(_ token: FeedLoadToken, accountMID: Int) -> Bool {
        recentLoadingToken == token
            && recentAdmission.isCurrent(token)
            && ownerAccountMID == accountMID
            && currentAccountMID == accountMID
    }

    private func isCurrentFollowingRequest(_ token: FeedLoadToken, accountMID: Int) -> Bool {
        followingLoadingToken == token
            && followingAdmission.isCurrent(token)
            && ownerAccountMID == accountMID
            && currentAccountMID == accountMID
    }
}
