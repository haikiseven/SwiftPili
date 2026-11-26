import Foundation
import Observation

@MainActor
@Observable
final class FavoritesViewModel {
    enum FolderTab: String, CaseIterable, Identifiable, Sendable {
        case created
        case collected

        var id: String { rawValue }

        var title: String {
            switch self {
            case .created: String(localized: "Created")
            case .collected: String(localized: "Subscribed")
            }
        }
    }

    var selectedTab: FolderTab = .created
    private(set) var folders: [FavoriteFolderResult.FavoriteFolder] = []
    private(set) var collectedFolders: [FavoriteFolderResult.FavoriteFolder] = []
    private(set) var previewsByFolderID: [Int: [FavoriteContentResult.FavoriteMedia]] = [:]
    private(set) var loadedFolderIDs: Set<Int> = []
    private(set) var failedPreviewIDs: Set<Int> = []
    private(set) var loadingPreviewIDs: Set<Int> = []
    private(set) var previewGeneration: UInt64 = 0
    private(set) var isLoading = true
    private(set) var isLoadingCollected = false
    private(set) var hasLoadedCollected = false
    private(set) var collectedHasMore = false
    private(set) var loadError: String?
    private(set) var collectedLoadError: String?
    private(set) var isMutating = false
    var errorText: String?

    private var collectedPage = 1
    @ObservationIgnored private var previewTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var authManager: AuthManager
    @ObservationIgnored private var accountManager: AccountManager

    init(
        authManager: AuthManager = .shared,
        accountManager: AccountManager = .shared
    ) {
        self.authManager = authManager
        self.accountManager = accountManager
    }

    func bind(authManager: AuthManager, accountManager: AccountManager) {
        self.authManager = authManager
        self.accountManager = accountManager
    }

    var activeFolders: [FavoriteFolderResult.FavoriteFolder] {
        selectedTab == .created ? folders : collectedFolders
    }

    var activeLoadError: String? {
        selectedTab == .created ? loadError : collectedLoadError
    }

    var showsInitialPlaceholder: Bool {
        switch selectedTab {
        case .created:
            folders.isEmpty && isLoading
        case .collected:
            collectedFolders.isEmpty && (isLoadingCollected || (!hasLoadedCollected && collectedLoadError == nil))
        }
    }

    var folderRows: [FavoriteFolderRowData] {
        let isOwned = selectedTab == .created
        return activeFolders.map { folder in
            let cached = previewsByFolderID[folder.id]
            let isFresh = loadedFolderIDs.contains(folder.id)
            let hasFailed = failedPreviewIDs.contains(folder.id)
            let displayLoaded = isFresh || cached != nil
            return FavoriteFolderRowData(
                folder: folder,
                previews: cached ?? [],
                isPreviewLoaded: displayLoaded,
                isPreviewFailed: hasFailed && cached == nil,
                needsPreview: !isFresh && !hasFailed,
                isOwned: isOwned
            )
        }
    }

    func loadInitial() async {
        await reload()
        isLoading = false
    }

    func loadCollectedIfNeeded() async {
        guard !hasLoadedCollected, !isLoadingCollected else { return }
        await reloadCollected()
    }

    func refreshActiveTab() async {
        let revision = accountManager.identityRevision
        switch selectedTab {
        case .created:
            await reload()
        case .collected:
            await reloadCollected()
        }
        guard !Task.isCancelled, accountManager.identityRevision == revision else { return }
        resetPreviewState(clearCache: false)
    }

    func retryActiveTab() async {
        switch selectedTab {
        case .created:
            isLoading = folders.isEmpty
            await reload()
            isLoading = false
        case .collected:
            await reloadCollected()
        }
    }

    func refreshAll() async {
        await refreshActiveTab()
    }

    func resetPreviewState(clearCache: Bool) {
        previewGeneration &+= 1
        previewTasks.values.forEach { $0.cancel() }
        previewTasks = [:]
        loadedFolderIDs = []
        failedPreviewIDs = []
        loadingPreviewIDs = []
        if clearCache {
            previewsByFolderID = [:]
        }
    }

    func reload() async {
        let revision = accountManager.identityRevision
        let mid = Int(authManager.dedeUserID ?? "0") ?? 0
        loadError = nil
        do {
            let result = try await UserAPI.getFavorites(mid: mid)
            guard accountManager.identityRevision == revision else { return }
            folders = result.list ?? []
            prunePreviewCaches()
        } catch {
            guard !Task.isCancelled,
                  accountManager.identityRevision == revision,
                  !error.isCancellation else { return }
            loadError = error.localizedDescription
            PlayerLog.log("[FavoritesView] failed: \(error)")
        }
    }

    func reloadCollected() async {
        let revision = accountManager.identityRevision
        let mid = Int(authManager.dedeUserID ?? "0") ?? 0
        guard mid > 0 else {
            hasLoadedCollected = true
            return
        }
        isLoadingCollected = true
        collectedLoadError = nil
        defer { isLoadingCollected = false }
        do {
            let result = try await UserAPI.getCollectedFavoriteFolders(upMid: mid, pn: 1, ps: 20)
            guard !Task.isCancelled, accountManager.identityRevision == revision else { return }
            collectedFolders = result.list ?? []
            collectedPage = 1
            collectedHasMore = result.hasMore ?? false
            hasLoadedCollected = true
            prunePreviewCaches()
        } catch {
            guard !Task.isCancelled,
                  accountManager.identityRevision == revision,
                  !error.isCancellation else { return }
            collectedLoadError = error.localizedDescription
            PlayerLog.log("[FavoritesView] collected failed: \(error)")
        }
    }

    func loadMoreCollectedIfNeeded() async {
        guard selectedTab == .collected,
              collectedHasMore,
              !isLoadingCollected else { return }
        let revision = accountManager.identityRevision
        let mid = Int(authManager.dedeUserID ?? "0") ?? 0
        guard mid > 0 else { return }
        let nextPage = collectedPage + 1
        isLoadingCollected = true
        defer { isLoadingCollected = false }
        do {
            let result = try await UserAPI.getCollectedFavoriteFolders(upMid: mid, pn: nextPage, ps: 20)
            guard !Task.isCancelled, accountManager.identityRevision == revision else { return }
            let incoming = result.list ?? []
            collectedFolders = FeedCollectionPolicy.appendDeduplicated(
                existing: collectedFolders,
                incoming: incoming,
                id: \.id
            )
            collectedPage = nextPage
            collectedHasMore = (result.hasMore ?? false) && !incoming.isEmpty
        } catch {
            guard !Task.isCancelled,
                  accountManager.identityRevision == revision,
                  !error.isCancellation else { return }
            PlayerLog.log("[FavoritesView] collected page \(nextPage) failed: \(error)")
        }
    }

    private func prunePreviewCaches() {
        let validIDs = Set(folders.map(\.id)).union(collectedFolders.map(\.id))
        previewsByFolderID = previewsByFolderID.filter { validIDs.contains($0.key) }
        loadedFolderIDs = loadedFolderIDs.intersection(validIDs)
        failedPreviewIDs = failedPreviewIDs.intersection(validIDs)
    }

    func loadPreviewIfNeeded(for folderID: Int) {
        guard !loadedFolderIDs.contains(folderID),
              !failedPreviewIDs.contains(folderID),
              !loadingPreviewIDs.contains(folderID) else { return }
        let revision = accountManager.identityRevision
        let generation = previewGeneration
        loadingPreviewIDs.insert(folderID)
        previewTasks[folderID] = Task {
            defer {
                if previewGeneration == generation, accountManager.identityRevision == revision {
                    loadingPreviewIDs.remove(folderID)
                    previewTasks.removeValue(forKey: folderID)
                }
            }
            do {
                let result = try await UserAPI.getFavoriteContent(mediaId: folderID, ps: 10)
                guard !Task.isCancelled,
                      accountManager.identityRevision == revision,
                      previewGeneration == generation else { return }
                previewsByFolderID[folderID] = result.medias ?? []
                failedPreviewIDs.remove(folderID)
                loadedFolderIDs.insert(folderID)
            } catch {
                guard !Task.isCancelled,
                      accountManager.identityRevision == revision,
                      previewGeneration == generation,
                      !BiliAPIRetryPolicy.isCancellation(error),
                      (error as? BiliError)?.isCancellation != true else { return }
                failedPreviewIDs.insert(folderID)
                PlayerLog.log("[FavPreview] folder \(folderID) preview failed: \(error)")
            }
        }
    }

    func retryPreview(for folderID: Int) {
        previewTasks.removeValue(forKey: folderID)?.cancel()
        loadingPreviewIDs.remove(folderID)
        failedPreviewIDs.remove(folderID)
        loadedFolderIDs.remove(folderID)
        loadPreviewIfNeeded(for: folderID)
    }

    func createFolder(name rawName: String, isPrivate: Bool) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isMutating else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await UserAPI.createFavoriteFolder(title: name, isPrivate: isPrivate)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }

    func deleteFolder(_ folder: FavoriteFolderResult.FavoriteFolder) {
        guard !isMutating, !folder.isDefault else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await UserAPI.deleteFavoriteFolder(mediaId: folder.id)
                previewTasks.removeValue(forKey: folder.id)?.cancel()
                previewsByFolderID.removeValue(forKey: folder.id)
                loadedFolderIDs.remove(folder.id)
                failedPreviewIDs.remove(folder.id)
                loadingPreviewIDs.remove(folder.id)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }
}

@MainActor
@Observable
final class FavoriteFolderPreviewViewModel {
    private(set) var previews: [FavoriteContentResult.FavoriteMedia]
    private(set) var loaded: Bool
    private(set) var loadFailed = false

    init(cachedPreviews: [FavoriteContentResult.FavoriteMedia]? = nil) {
        self.previews = cachedPreviews ?? []
        self.loaded = cachedPreviews != nil
    }

    func loadIfNeeded(
        folderID: Int,
        onPreviewsLoaded: (([FavoriteContentResult.FavoriteMedia]) -> Void)?
    ) async {
        guard !loaded else { return }
        loadFailed = false
        do {
            let result = try await UserAPI.getFavoriteContent(mediaId: folderID, ps: 10)
            guard !Task.isCancelled else { return }
            let fetched = result.medias ?? []
            previews = fetched
            onPreviewsLoaded?(fetched)
            loaded = true
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            loadFailed = true
            loaded = true
            PlayerLog.log("[FavPreview] folder \(folderID) preview failed: \(error)")
        }
    }

    func retry(
        folderID: Int,
        onPreviewsLoaded: (([FavoriteContentResult.FavoriteMedia]) -> Void)?
    ) async {
        loaded = false
        loadFailed = false
        await loadIfNeeded(folderID: folderID, onPreviewsLoaded: onPreviewsLoaded)
    }
}
