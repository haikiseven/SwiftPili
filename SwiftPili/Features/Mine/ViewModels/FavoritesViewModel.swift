import Foundation
import Observation

@MainActor
@Observable
final class FavoritesViewModel {
    private(set) var folders: [FavoriteFolderResult.FavoriteFolder] = []
    private(set) var previewsByFolderID: [Int: [FavoriteContentResult.FavoriteMedia]] = [:]
    private(set) var loadedFolderIDs: Set<Int> = []
    private(set) var failedPreviewIDs: Set<Int> = []
    private(set) var loadingPreviewIDs: Set<Int> = []
    private(set) var previewGeneration: UInt64 = 0
    private(set) var isLoading = true
    private(set) var isMutating = false
    var errorText: String?

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

    var showsInitialPlaceholder: Bool {
        folders.isEmpty && isLoading
    }

    var folderRows: [FavoriteFolderRowData] {
        folders.map { folder in
            let cached = previewsByFolderID[folder.id]
            let isFresh = loadedFolderIDs.contains(folder.id)
            let hasFailed = failedPreviewIDs.contains(folder.id)
            let displayLoaded = isFresh || cached != nil || hasFailed
            return FavoriteFolderRowData(
                folder: folder,
                previews: cached ?? [],
                isPreviewLoaded: displayLoaded,
                needsPreview: !isFresh && !hasFailed
            )
        }
    }

    func loadInitial() async {
        await reload()
        isLoading = false
    }

    func refreshAll() async {
        let revision = accountManager.identityRevision
        await reload()
        guard !Task.isCancelled, accountManager.identityRevision == revision else { return }
        resetPreviewState(clearCache: false)
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
        do {
            let result = try await UserAPI.getFavorites(mid: mid)
            guard accountManager.identityRevision == revision else { return }
            folders = result.list ?? []
            let validIDs = Set(folders.map(\.id))
            previewsByFolderID = previewsByFolderID.filter { validIDs.contains($0.key) }
            loadedFolderIDs = loadedFolderIDs.intersection(validIDs)
            failedPreviewIDs = failedPreviewIDs.intersection(validIDs)
        } catch {
            PlayerLog.log("[FavoritesView] failed: \(error)")
        }
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

    func createFolder(name rawName: String, isPrivate: Bool) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isMutating else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await UserAPI.createFavoriteFolder(title: name, isPrivate: isPrivate)
            } catch {
                errorText = "\(error)"
            }
            await reload()
        }
    }

    func deleteFolder(_ folder: FavoriteFolderResult.FavoriteFolder) {
        guard !isMutating else { return }
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
                errorText = "\(error)"
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

    init(cachedPreviews: [FavoriteContentResult.FavoriteMedia]? = nil) {
        self.previews = cachedPreviews ?? []
        self.loaded = cachedPreviews != nil
    }

    func loadIfNeeded(
        folderID: Int,
        onPreviewsLoaded: (([FavoriteContentResult.FavoriteMedia]) -> Void)?
    ) async {
        guard !loaded else { return }
        do {
            let result = try await UserAPI.getFavoriteContent(mediaId: folderID, ps: 10)
            guard !Task.isCancelled else { return }
            let fetched = result.medias ?? []
            previews = fetched
            onPreviewsLoaded?(fetched)
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            PlayerLog.log("[FavPreview] folder \(folderID) preview failed: \(error)")
        }
        loaded = true
    }
}
