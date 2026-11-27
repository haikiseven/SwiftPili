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
        durationSeconds: item.duration ?? 0,
        isPortraitHint: item.dimension?.isPortrait,
        aspectRatioHint: item.dimension?.effectiveAspectRatio
    )
}

struct FavoritesView: View {
    @State private var viewModel = FavoritesViewModel()
    @State private var showManage = false
    @State private var showCreate = false
    @State private var newFolderName = ""
    @State private var pendingDelete: FavoriteFolderResult.FavoriteFolder?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.authManager) private var authManager
    @Environment(\.accountManager) private var accountManager

    var body: some View {
        let placeholderLabel = String(
            format: String(localized: "Loading %@"),
            String(localized: "Favorites")
        )
        FavoritesCollectionView(
            rows: viewModel.folderRows,
            placeholderCount: viewModel.showsInitialPlaceholder ? 4 : 0,
            placeholderLabel: placeholderLabel,
            isMutating: viewModel.isMutating,
            previewGeneration: viewModel.previewGeneration,
            onRefresh: {
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                await viewModel.refreshActiveTab()
                return false
            },
            onNeedPreview: { folderID in
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                viewModel.loadPreviewIfNeeded(for: folderID)
            },
            onRetryPreview: { folderID in
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                viewModel.retryPreview(for: folderID)
            },
            onNearEnd: {
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                Task { await viewModel.loadMoreCollectedIfNeeded() }
            },
            onOpenFolder: { folderID, title in
                coordinator.navigate(to: .favoriteDetail(folderID, title))
            },
            onSelectVideo: { target in
                coordinator.navigateToVideo(target)
            },
            onRequestDelete: { folder in
                guard !folder.isDefault else { return }
                pendingDelete = folder
            }
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("", selection: $viewModel.selectedTab) {
                ForEach(FavoritesViewModel.FolderTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
            .padding(.horizontal, AppSpacing.l)
            .padding(.vertical, AppSpacing.s)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
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
                .disabled(viewModel.isMutating)
                Button {
                    showManage = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .disabled(viewModel.isMutating)
            }
        }
        .sheet(
            isPresented: $showManage,
            onDismiss: {
                Task {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    await viewModel.reload()
                }
            },
            content: { ManageFavoriteFoldersView(folders: viewModel.folders) }
        )
        .alert("New Folder", isPresented: $showCreate) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                viewModel.createFolder(name: newFolderName, isPrivate: false)
            }
            Button("Create Private") {
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                viewModel.createFolder(name: newFolderName, isPrivate: true)
            }
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
                if let folder = pendingDelete {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    viewModel.deleteFolder(folder)
                }
            }
        } message: {
            Text("The folder and its saved list are removed from your account.")
        }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { viewModel.errorText != nil },
                set: { if !$0 { viewModel.errorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorText ?? "")
        }
        .overlay {
            if !viewModel.showsInitialPlaceholder, viewModel.activeFolders.isEmpty {
                if let error = viewModel.activeLoadError {
                    ContentUnavailableView {
                        Label("Load Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task {
                                viewModel.bind(authManager: authManager, accountManager: accountManager)
                                await viewModel.retryActiveTab()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if viewModel.selectedTab == .collected {
                    ContentUnavailableView(
                        "No Subscribed Folders",
                        systemImage: "folder.badge.plus",
                        description: Text("Favorite folders you subscribe to will appear here.")
                    )
                } else {
                    ContentUnavailableView("No Favorites", systemImage: "star.slash")
                }
            }
        }
        .task {
            viewModel.bind(authManager: authManager, accountManager: accountManager)
            await viewModel.loadInitial()
        }
        .task(id: viewModel.selectedTab) {
            guard viewModel.selectedTab == .collected else { return }
            viewModel.bind(authManager: authManager, accountManager: accountManager)
            await viewModel.loadCollectedIfNeeded()
        }
    }
}

struct FavoriteFolderPreviewRow: View {
    let folder: FavoriteFolderResult.FavoriteFolder
    let seedWidth: CGFloat

    private let onPreviewsLoaded: (([FavoriteContentResult.FavoriteMedia]) -> Void)?
    @State private var viewModel: FavoriteFolderPreviewViewModel
    @Environment(AppCoordinator.self) private var coordinator

    @State private var shelfWidth: CGFloat
    private var horizontalInset: CGFloat {
        FeedColumnPolicy.horizontalMargin(for: seedWidth)
    }

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
        _viewModel = State(initialValue: FavoriteFolderPreviewViewModel(cachedPreviews: cachedPreviews))
        let inset = FeedColumnPolicy.horizontalMargin(for: seedWidth)
        _shelfWidth = State(initialValue: max(0, seedWidth - inset * 2))
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
                    if folder.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
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

            if viewModel.previews.isEmpty, !viewModel.loaded {
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
            } else if viewModel.previews.isEmpty, viewModel.loadFailed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Failed to load preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Retry") {
                        Task {
                            await viewModel.retry(folderID: folder.id, onPreviewsLoaded: onPreviewsLoaded)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.biliAccent)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
            } else if viewModel.previews.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Empty Folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(viewModel.previews, id: \.resourceKey) { item in
                            VideoNavigationButton(target: favoriteRouteTarget(item)) {
                                previewCard(item)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!item.isPlayableVideo)
                        }
                        if let count = folder.mediaCount, count > viewModel.previews.count {
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
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, 12)
        .task {
            await viewModel.loadIfNeeded(folderID: folder.id, onPreviewsLoaded: onPreviewsLoaded)
        }
    }

    private func previewCard(_ item: FavoriteContentResult.FavoriteMedia) -> some View {
        let isPlayable = item.isPlayableVideo
        return VStack(alignment: .leading, spacing: 5) {
            VideoCoverImage(
                sources: VideoCoverSources(widescreen: item.cover ?? ""),
                width: cardWidth
            )
            .opacity(isPlayable ? 1.0 : 0.58)
            .videoCoverFrame(cornerRadius: AppRadius.thumbnail)
            .overlay(alignment: .topLeading) {
                if !isPlayable {
                    Text("Unavailable")
                        .appFont(.overlayBadge)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.red.opacity(0.84),
                            in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                        )
                        .padding(4)
                }
            }
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
                .opacity(isPlayable ? 1.0 : 0.58)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(width: cardWidth, alignment: .leading)

            if let upperName = item.upper?.name, !upperName.isEmpty {
                Text(upperName)
                    .lineLimit(1)
                    .appFont(.cardMeta)
                    .foregroundStyle(.secondary)
                    .opacity(isPlayable ? 1.0 : 0.58)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }
}
