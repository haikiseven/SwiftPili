import SwiftUI

func favoriteRouteTarget(
    _ item: FavoriteContentResult.FavoriteMedia
) -> VideoRouteTarget? {
    guard item.isPlayableVideo else { return nil }
    return .make(
        bvid: item.bvid,
        aid: item.id,
        title: item.title,
        coverURL: item.cover ?? "",
        ownerName: item.upper?.name ?? "",
        durationSeconds: item.duration ?? 0
    )
}

struct FavoritesView: View {
    @State private var folders: [FavoriteFolderResult.FavoriteFolder] = []
    @State private var previewsByFolderID: [Int: [FavoriteContentResult.FavoriteMedia]] = [:]
    @State private var loadedFolderIDs: Set<Int> = []
    @State private var failedPreviewIDs: Set<Int> = []
    @State private var loadingPreviewIDs: Set<Int> = []
    @State private var previewGeneration: UInt64 = 0
    @State private var previewTasks: [Int: Task<Void, Never>] = [:]
    @State private var isLoading = true
    @State private var showManage = false
    @State private var showCreate = false
    @State private var newFolderName = ""
    @State private var pendingDelete: FavoriteFolderResult.FavoriteFolder?
    @State private var errorText: String?
    @State private var isMutating = false
    @State private var accountRevision = AccountManager.shared.identityRevision
    @Environment(AppCoordinator.self) private var coordinator

    private var showsInitialPlaceholder: Bool {
        folders.isEmpty && isLoading
    }

    private var folderRows: [FavoriteFolderRowData] {
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

    var body: some View {
        let placeholderLabel = String(
            format: String(localized: "Loading %@"),
            String(localized: "Favorites")
        )
        FavoritesCollectionView(
            rows: folderRows,
            placeholderCount: showsInitialPlaceholder ? 6 : 0,
            placeholderLabel: placeholderLabel,
            isMutating: isMutating,
            previewGeneration: previewGeneration,
            onRefresh: {
                await refreshAll()
                return false
            },
            onNeedPreview: { folderID in
                loadPreviewIfNeeded(for: folderID)
            },
            onOpenFolder: { folderID, title in
                coordinator.navigate(to: .favoriteDetail(folderID, title))
            },
            onSelectVideo: { target in
                coordinator.navigateToVideo(target)
            },
            onRequestDelete: { folder in
                pendingDelete = folder
            }
        )
        .appAmbientBrowseBackground()
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    newFolderName = ""
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isMutating)
                Button {
                    showManage = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .disabled(isMutating)
            }
        }
        .sheet(
            isPresented: $showManage,
            onDismiss: { Task { await reload() } },
            content: { ManageFavoriteFoldersView(folders: folders) }
        )
        .alert("New Folder", isPresented: $showCreate) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder(isPrivate: false) }
            Button("Create Private") { createFolder(isPrivate: true) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            String(format: String(localized: "Delete “%@”?"), pendingDelete?.title ?? ""),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folder = pendingDelete { deleteFolder(folder) }
            }
        } message: {
            Text("The folder and its saved list are removed from your account.")
        }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .overlay {
            if !showsInitialPlaceholder, folders.isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star.slash")
            }
        }
        .task(id: AccountManager.shared.identityRevision) {
            if accountRevision != AccountManager.shared.identityRevision {
                accountRevision = AccountManager.shared.identityRevision
                folders = []
                resetPreviewState(clearCache: true)
                pendingDelete = nil
                errorText = nil
                isLoading = true
            }
            await reload()
            isLoading = false
        }
    }

    private func refreshAll() async {
        let revision = AccountManager.shared.identityRevision
        await reload()
        guard !Task.isCancelled, AccountManager.shared.identityRevision == revision else { return }
        resetPreviewState(clearCache: false)
    }

    private func resetPreviewState(clearCache: Bool) {
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

    private func reload() async {
        let revision = AccountManager.shared.identityRevision
        let mid = Int(AuthManager.shared.dedeUserID ?? "0") ?? 0
        do {
            let result = try await UserAPI.getFavorites(mid: mid)
            guard AccountManager.shared.identityRevision == revision else { return }
            folders = result.list ?? []
            let validIDs = Set(folders.map(\.id))
            previewsByFolderID = previewsByFolderID.filter { validIDs.contains($0.key) }
            loadedFolderIDs = loadedFolderIDs.intersection(validIDs)
            failedPreviewIDs = failedPreviewIDs.intersection(validIDs)
        } catch {
            PlayerLog.log("[FavoritesView] failed: \(error)")
        }
    }

    private func loadPreviewIfNeeded(for folderID: Int) {
        guard !loadedFolderIDs.contains(folderID),
              !failedPreviewIDs.contains(folderID),
              !loadingPreviewIDs.contains(folderID) else { return }
        let revision = AccountManager.shared.identityRevision
        let generation = previewGeneration
        loadingPreviewIDs.insert(folderID)
        previewTasks[folderID] = Task {
            defer {
                if previewGeneration == generation, AccountManager.shared.identityRevision == revision {
                    loadingPreviewIDs.remove(folderID)
                    previewTasks.removeValue(forKey: folderID)
                }
            }
            do {
                let result = try await UserAPI.getFavoriteContent(mediaId: folderID, ps: 10)
                guard !Task.isCancelled,
                      AccountManager.shared.identityRevision == revision,
                      previewGeneration == generation else { return }
                previewsByFolderID[folderID] = result.medias ?? []
                failedPreviewIDs.remove(folderID)
                loadedFolderIDs.insert(folderID)
            } catch {
                guard !Task.isCancelled,
                      AccountManager.shared.identityRevision == revision,
                      previewGeneration == generation,
                      !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true else { return }
                failedPreviewIDs.insert(folderID)
                PlayerLog.log("[FavPreview] folder \(folderID) preview failed: \(error)")
            }
        }
    }

    private func createFolder(isPrivate: Bool) {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func deleteFolder(_ folder: FavoriteFolderResult.FavoriteFolder) {
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

struct FavoriteFolderPreviewRow: View {
    let folder: FavoriteFolderResult.FavoriteFolder
    let seedWidth: CGFloat

    private static let horizontalInset: CGFloat = 16
    private let onPreviewsLoaded: (([FavoriteContentResult.FavoriteMedia]) -> Void)?
    @State private var previews: [FavoriteContentResult.FavoriteMedia]
    @State private var loaded: Bool
    @Environment(AppCoordinator.self) private var coordinator

    @State private var shelfWidth: CGFloat
    private var cardWidth: CGFloat {
        FeedColumnPolicy.shelfCardWidth(availableWidth: shelfWidth)
    }

    private var cardHeight: CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: cardWidth)
    }

    private var seeMoreTileWidth: CGFloat {
        (cardWidth * 2 / 3).rounded()
    }

    init(
        folder: FavoriteFolderResult.FavoriteFolder,
        seedWidth: CGFloat,
        cachedPreviews: [FavoriteContentResult.FavoriteMedia]? = nil,
        onPreviewsLoaded: (([FavoriteContentResult.FavoriteMedia]) -> Void)? = nil
    ) {
        self.folder = folder
        self.seedWidth = seedWidth
        self.onPreviewsLoaded = onPreviewsLoaded
        _previews = State(initialValue: cachedPreviews ?? [])
        _loaded = State(initialValue: cachedPreviews != nil)
        _shelfWidth = State(initialValue: max(0, seedWidth - Self.horizontalInset * 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                coordinator.navigate(to: .favoriteDetail(folder.id, folder.title))
            } label: {
                HStack(spacing: 8) {
                    FolderIconView(size: 28)
                    Text(folder.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let count = folder.mediaCount {
                        Text(verbatim: "\(count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppFill.inset, in: Capsule())
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        Text("See More")
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if previews.isEmpty, !loaded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
                                    .fill(Color.imagePlaceholder)
                                    .frame(width: cardWidth, height: cardHeight)
                                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                                    .fill(Color.imagePlaceholder)
                                    .frame(width: cardWidth * 0.88, height: 11)
                                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                                    .fill(Color.imagePlaceholder)
                                    .frame(width: cardWidth * 0.56, height: 11)
                                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                                    .fill(Color.imagePlaceholder.opacity(0.65))
                                    .frame(width: cardWidth * 0.42, height: 10)
                            }
                        }
                    }
                }
                .disabled(true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } else if previews.isEmpty {
                Text("Empty Folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(height: cardHeight)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(previews, id: \.resourceKey) { item in
                            VideoNavigationButton(target: favoriteRouteTarget(item)) {
                                previewCard(item)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!item.isPlayableVideo)
                        }
                        if let count = folder.mediaCount, count > previews.count {
                            Button {
                                coordinator.navigate(to: .favoriteDetail(folder.id, folder.title))
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.title3)
                                    Text("See More")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                                .frame(width: seeMoreTileWidth, height: cardHeight)
                                .background(
                                    AppFill.inset,
                                    in: RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .measuringContentWidth(into: $shelfWidth)
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, 12)
        .task {
            guard !loaded else { return }
            do {
                let result = try await UserAPI.getFavoriteContent(mediaId: folder.id, ps: 10)
                let fetched = result.medias ?? []
                previews = fetched
                onPreviewsLoaded?(fetched)
            } catch {
                PlayerLog.log("[FavPreview] folder \(folder.id) preview failed: \(error)")
            }
            loaded = true
        }
    }

    private func previewCard(_ item: FavoriteContentResult.FavoriteMedia) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            VideoCoverImage(
                sources: VideoCoverSources(widescreen: item.cover ?? ""),
                width: cardWidth
            )
            .videoCoverFrame(cornerRadius: AppRadius.thumbnail)
            .overlay(alignment: .bottomTrailing) {
                if let duration = item.duration, duration > 0 {
                    Text(FormatUtils.duration(duration))
                        .appFont(.overlayBadge, monospacedDigit: true)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            .black.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                        )
                        .padding(4)
                }
            }
            Text(item.title)
                .appFont(.shelfCardTitle)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(width: cardWidth, alignment: .leading)

            if let upperName = item.upper?.name, !upperName.isEmpty {
                Text(upperName)
                    .lineLimit(1)
                    .appFont(.cardMeta)
                    .foregroundStyle(.secondary)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }
}
