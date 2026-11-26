import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class FavoriteDetailViewModel {
    typealias Media = FavoriteContentResult.FavoriteMedia

    enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case recentlyAdded = "mtime"
        case mostViewed = "view"
        case newestPublished = "pubtime"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .recentlyAdded: String(localized: "Recently Added")
            case .mostViewed: String(localized: "Most Viewed")
            case .newestPublished: String(localized: "Newest Published")
            }
        }
    }

    enum ActionKind: Equatable {
        case save, copy, move, remove, watchLater

        var title: String {
            switch self {
            case .save: String(localized: "Add to Favorites")
            case .copy: String(localized: "Copy to Folder")
            case .move: String(localized: "Move to Folder")
            case .remove: String(localized: "Remove from Folder")
            case .watchLater: String(localized: "Watch Later")
            }
        }
    }

    struct ActionRequest: Identifiable {
        let id = UUID()
        let kind: ActionKind
        let item: Media
        let accountID: String
        let ownerID: Int?
    }

    private struct PageRequest: Equatable {
        let token: FeedLoadToken
        let keyword: String?
        let order: SortOrder
        let page: Int
        let replaces: Bool
    }

    let mediaID: Int
    let accountID: String?
    private let accountRevision: UInt64
    private(set) var items: [Media] = []
    private(set) var activeKeyword: String?
    private(set) var sortOrder: SortOrder = .recentlyAdded
    private(set) var reportedMediaCount: Int?
    private(set) var hasMore = true
    private(set) var hasLoaded = false
    private(set) var hasAttempted = false
    private(set) var isLoading = false
    private(set) var publishedGeneration: UInt64 = 0
    private(set) var loadError: String?
    private(set) var activeActionID: UUID?
    private(set) var actionError: String?
    var notice: ToastMessage?
    private var page = 1
    private var folderInfo: FavoriteContentResult.FolderInfo?
    @ObservationIgnored private var admission = FeedLoadAdmission()
    @ObservationIgnored private var loadingRequest: PageRequest?
    @ObservationIgnored private var loadWork: Task<Void, Never>?
    private var failedRequest: PageRequest?
    private var actionFailureID: UUID?

    init(mediaID: Int) {
        self.mediaID = mediaID
        accountID = AccountManager.shared.activeMid
        accountRevision = AccountManager.shared.identityRevision
    }

    var isCurrentAccount: Bool {
        AccountManager.shared.identityRevision == accountRevision
            && AccountManager.shared.activeMid == accountID && AuthManager.shared.dedeUserID == accountID
    }

    var sourceOwnerID: Int? {
        guard isCurrentAccount, folderInfo?.id == mediaID,
              let owner = folderInfo?.mid, owner > 0 else { return nil }
        return owner
    }

    var ownsFolder: Bool {
        guard let accountID, let owner = sourceOwnerID else { return false }
        return Int(accountID) == owner
    }

    var canMutate: Bool { isCurrentAccount && (accountID.flatMap(Int.init) ?? 0) > 0 && activeActionID == nil }
    var canRetryLoading: Bool { failedRequest != nil && !isLoading }
    var playableVideos: [Media] { items.filter(\.isPlayableVideo) }
    var hasPlayableVideos: Bool { items.contains(where: \.isPlayableVideo) }

    func makePlayAllEntries() -> [PlaylistQueueEntry] {
        playableVideos.compactMap { item in
            guard let target = favoriteRouteTarget(item) else { return nil }
            return PlaylistQueueEntry(
                aid: item.id,
                bvid: item.bvid,
                cid: nil,
                title: item.title,
                artist: item.upper?.name ?? "",
                coverURL: item.cover?.isEmpty == false ? item.cover : nil,
                duration: item.duration.map(TimeInterval.init),
                isPortraitHint: nil,
                routeTarget: target
            )
        }
    }

    func actionError(for requestID: UUID) -> String? {
        actionFailureID == requestID ? actionError : nil
    }

    func clearActionError(for requestID: UUID? = nil) {
        guard requestID == nil || requestID == actionFailureID else { return }
        actionError = nil
        actionFailureID = nil
    }

    func loadInitial() async {
        guard !hasLoaded else { return }
        if failedRequest != nil { await retry() } else { await loadMore() }
    }

    func search(_ keyword: String?) {
        guard !Task.isCancelled, isCurrentAccount else { return }
        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        activeKeyword = trimmed?.isEmpty == false ? trimmed : nil
        items = []
        page = 1
        hasMore = true
        hasLoaded = false
        let request = prepareReplacement()
        loadWork = Task { await load(request) }
    }

    func setSortOrder(_ order: SortOrder) {
        guard !Task.isCancelled, isCurrentAccount, order != sortOrder else { return }
        sortOrder = order
        items = []
        page = 1
        hasMore = true
        hasLoaded = false
        let request = prepareReplacement()
        loadWork = Task { await load(request) }
    }

    func refresh() async {
        guard !Task.isCancelled, isCurrentAccount, mediaID > 0 else { return }
        await runLoad(prepareReplacement())
    }

    func loadMore() async {
        guard !Task.isCancelled, isCurrentAccount, !isLoading, hasMore,
              failedRequest == nil, mediaID > 0,
              let token = admission.admit(kind: page == 1 ? .initial : .pagination, cursor: String(page))
        else { return }
        let request = PageRequest(
            token: token,
            keyword: activeKeyword,
            order: sortOrder,
            page: page,
            replaces: page == 1
        )
        prepare(request)
        await runLoad(request)
    }

    func loadMore(after resourceKey: String, generation: UInt64) async {
        guard publishedGeneration == generation, items.last?.resourceKey == resourceKey else { return }
        await loadMore()
    }

    func retry() async {
        guard !Task.isCancelled, isCurrentAccount, !isLoading else { return }
        guard let failedRequest else { await loadMore(); return }
        guard failedRequest.keyword == activeKeyword, failedRequest.order == sortOrder else { return }
        self.failedRequest = nil
        if failedRequest.replaces { await refresh() } else { await loadMore() }
    }

    private func prepareReplacement() -> PageRequest {
        loadWork?.cancel()
        loadWork = nil
        let token = admission.supersedeAndAdmit(kind: .refresh, cursor: "1")
        let request = PageRequest(
            token: token,
            keyword: activeKeyword,
            order: sortOrder,
            page: 1,
            replaces: true
        )
        prepare(request)
        return request
    }

    private func prepare(_ request: PageRequest) {
        loadingRequest = request
        failedRequest = nil
        isLoading = true
        hasAttempted = true
        loadError = nil
    }

    private func isCurrent(_ request: PageRequest) -> Bool {
        isCurrentAccount && loadingRequest == request && admission.isCurrent(request.token)
            && request.keyword == activeKeyword && request.order == sortOrder
    }

    private func runLoad(_ request: PageRequest) async {
        let work = Task { await load(request) }
        loadWork = work
        defer {
            if loadingRequest == request {
                loadWork = nil
            }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func load(_ request: PageRequest) async {
        var succeeded = false
        var wasCancelled = false
        defer {
            admission.finish(request.token, succeeded: succeeded)
            if loadingRequest == request {
                loadingRequest = nil
                loadWork = nil
                isLoading = false
                if !succeeded, !wasCancelled || items.isEmpty { failedRequest = request }
            }
        }
        guard !Task.isCancelled, isCurrent(request) else {
            wasCancelled = true
            return
        }
        do {
            let result = try await UserAPI.getFavoriteContent(
                mediaId: mediaID,
                pn: request.page,
                keyword: request.keyword,
                order: request.order.rawValue
            )
            guard !Task.isCancelled, isCurrent(request) else {
                wasCancelled = true
                return
            }
            let incoming = result.medias ?? []
            items = FeedCollectionPolicy.appendDeduplicated(
                existing: request.replaces ? [] : items, incoming: incoming, id: \.resourceKey
            )
            folderInfo = result.info?.id == mediaID ? result.info : nil
            if let count = folderInfo?.mediaCount {
                reportedMediaCount = count
            }
            hasMore = result.hasMore ?? false
            page = request.page + 1
            hasLoaded = true
            publishedGeneration = request.token.generation
            succeeded = true
        } catch {
            if Task.isCancelled || error.isCancellation {
                wasCancelled = true
                return
            }
            guard isCurrent(request) else { return }
            loadError = error.localizedDescription
        }
    }

    func actionRequest(_ kind: ActionKind, item: Media) -> ActionRequest? {
        guard canMutate, let accountID, item.isVideo,
              kind == .remove || item.isPlayableVideo else { return nil }
        if kind == .remove || kind == .move, !ownsFolder { return nil }
        if kind == .copy, sourceOwnerID == nil { return nil }
        return ActionRequest(kind: kind, item: item, accountID: accountID, ownerID: sourceOwnerID)
    }

    func admits(_ request: ActionRequest) -> Bool {
        guard isCurrentAccount, request.accountID == accountID, request.item.isVideo,
              request.kind == .remove || request.item.isPlayableVideo else { return false }
        switch request.kind {
        case .move, .remove: return ownsFolder && request.ownerID == sourceOwnerID
        case .copy: return sourceOwnerID != nil && request.ownerID == sourceOwnerID
        case .save, .watchLater: return true
        }
    }

    @discardableResult
    func startAction(_ request: ActionRequest, destinationID: Int? = nil) -> Task<Bool, Never>? {
        guard !Task.isCancelled, activeActionID == nil, admits(request) else { return nil }
        switch request.kind {
        case .save, .copy, .move:
            guard let destinationID, destinationID > 0, destinationID != mediaID else { return nil }
        case .remove, .watchLater: break
        }
        activeActionID = request.id
        clearActionError()
        return Task { await execute(request, destinationID: destinationID) }
    }
}

private extension FavoriteDetailViewModel {
    func execute(_ request: ActionRequest, destinationID: Int?) async -> Bool {
        defer { if activeActionID == request.id { activeActionID = nil } }
        guard !Task.isCancelled, activeActionID == request.id, admits(request) else { return false }
        do {
            try await send(request, destinationID: destinationID)
            guard !Task.isCancelled, activeActionID == request.id, isCurrentAccount else { return false }
            notice = ToastMessage(text: successText(request.kind), style: .success)
            if request.kind == .remove || request.kind == .move {
                if items.contains(where: { $0.resourceKey == request.item.resourceKey }) {
                    withTransaction(\.favoriteRemovalID, request.id) {
                        items.removeAll { $0.resourceKey == request.item.resourceKey }
                    }
                    if let count = reportedMediaCount {
                        reportedMediaCount = max(items.count, count - 1)
                    }
                }
                if items.isEmpty && hasMore {
                    await loadMore()
                }
            }
            return true
        } catch {
            let failure: any Error = error
            guard !Task.isCancelled, activeActionID == request.id, isCurrentAccount,
                  !(failure is CancellationError),
                  (failure as? BiliError)?.isCancellation != true else { return false }
            actionError = failure.localizedDescription
            actionFailureID = request.id
            return false
        }
    }

    func send(_ request: ActionRequest, destinationID: Int?) async throws(BiliError) {
        switch request.kind {
        case .watchLater:
            _ = try await UserAPI.addToWatchLater(aid: request.item.id)
        case .remove:
            try await UserAPI.removeFavoriteResource(aid: request.item.id, mediaId: mediaID)
        case .save:
            guard let destinationID else {
                throw .apiError(code: -1, message: String(localized: "Operation Failed"))
            }
            _ = try await VideoAPI.dealFavorite(aid: request.item.id, addIds: [destinationID], delIds: [])
        case .copy, .move:
            guard let destinationID, let owner = request.ownerID else {
                throw .apiError(code: -1, message: String(localized: "Operation Failed"))
            }
            try await UserAPI.transferFavoriteResource(
                aid: request.item.id, sourceMediaId: mediaID, targetMediaId: destinationID,
                sourceOwnerMid: owner, operation: request.kind == .copy ? .copy : .move
            )
        }
    }

    func successText(_ kind: ActionKind) -> String {
        switch kind {
        case .save: String(localized: "Saved")
        case .copy: String(localized: "Copied")
        case .move: String(localized: "Moved")
        case .remove: String(localized: "Removed")
        case .watchLater: String(localized: "Added to Watch Later")
        }
    }
}
