import SwiftUI
import UIKit

private struct FavoriteRemovalTransactionKey: TransactionKey {
    static let defaultValue: UUID? = nil
}

extension Transaction {
    var favoriteRemovalID: UUID? {
        get { self[FavoriteRemovalTransactionKey.self] }
        set { self[FavoriteRemovalTransactionKey.self] = newValue }
    }
}

struct FavoriteDetailView: View {
    let mediaId: Int
    let title: String

    var body: some View {
        FavoriteDetailContent(mediaId: mediaId, title: title)
            .id(mediaId)
    }
}

private struct FavoriteDetailContent: View {
    let title: String
    @State private var model: FavoriteDetailViewModel
    @State private var searchText = ""
    @State private var destination: FavoriteDetailViewModel.ActionRequest?
    @State private var pendingRemoval: FavoriteDetailViewModel.ActionRequest?
    @Environment(AppCoordinator.self) private var coordinator

    init(mediaId: Int, title: String) {
        self.title = title
        _model = State(initialValue: FavoriteDetailViewModel(mediaID: mediaId))
    }

    private var showsInitialPlaceholder: Bool {
        model.items.isEmpty && (model.isLoading || !model.hasAttempted)
    }

    private var headerInfoText: String? {
        guard !model.items.isEmpty else { return nil }
        if let keyword = model.activeKeyword {
            return "\(title) — “\(keyword)”"
        }
        return title
    }

    private var rowItems: [MineLibraryRowItem] {
        let menuRevision = model.ownsFolder ? 1 : 0
        let isMenuEnabled = model.activeActionID == nil
        return model.items.map { item in
            let hasMenu = hasItemMenu(item)
            return MineLibraryRowItem(
                id: .string(item.resourceKey),
                title: item.title,
                sources: VideoCoverSources(widescreen: item.cover ?? ""),
                duration: item.duration ?? 0,
                subtitle: item.upper?.name,
                footer: .stats(play: item.cntInfo?.play, danmaku: item.cntInfo?.danmaku),
                isSelectable: item.isPlayableVideo,
                hasTrailingMenu: hasMenu,
                trailingMenuAccessibilityLabel: hasMenu
                    ? String(localized: "More actions for \(item.title)")
                    : nil,
                isTrailingMenuEnabled: isMenuEnabled,
                menuRevision: menuRevision
            )
        }
    }

    private var footerState: MineFeedFooterState {
        guard !model.items.isEmpty else { return .none }
        if model.isLoading {
            return .loading
        }
        if model.canRetryLoading {
            return .error(
                message: model.loadError ?? String(localized: "Load Failed"),
                retryTitle: String(localized: "Retry")
            )
        }
        return .none
    }

    var body: some View {
        let generation = model.publishedGeneration
        let placeholderLabel = String(format: String(localized: "Loading %@"), title)
        MineLibraryRowFeedView(
            items: rowItems,
            headerTitle: headerInfoText,
            placeholderCount: showsInitialPlaceholder ? 6 : 0,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            onRefresh: {
                await model.refresh()
                return false
            },
            onNearEndAppear: {
                guard let lastKey = model.items.last?.resourceKey else { return }
                Task { await model.loadMore(after: lastKey, generation: generation) }
            },
            onFooterAction: {
                Task { await model.retry() }
            },
            onSelectItem: { id in
                guard case .string(let key) = id,
                      let item = model.items.first(where: { $0.resourceKey == key }),
                      let target = favoriteRouteTarget(item) else { return }
                coordinator.navigateToVideo(target)
            },
            makeTrailingMenu: { id, sourceView in
                guard case .string(let key) = id,
                      let item = model.items.first(where: { $0.resourceKey == key }) else {
                    return nil
                }
                return makeItemMenu(for: item, sourceView: sourceView)
            }
        )
        .appAmbientBrowseBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText)
        .onSubmit(of: .search) { model.search(searchText) }
        .onChange(of: searchText) {
            if searchText.isEmpty, model.activeKeyword != nil { model.search(nil) }
        }
        .overlay { if model.items.isEmpty, !showsInitialPlaceholder { emptyContent } }
        .overlay(alignment: .bottom) {
            if let notice = model.notice { ToastView(message: notice).padding() }
        }
        .task(id: model.notice?.id) {
            let noticeID = model.notice?.id
            guard noticeID != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, model.notice?.id == noticeID { model.notice = nil }
        }
        .task { await model.loadInitial() }
        .sheet(item: $destination) { request in
            FavoriteDestinationSheet(model: model, request: request).id(request.id)
        }
        .confirmationDialog(
            pendingRemoval?.item.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            if let request = pendingRemoval {
                Button("Remove from Folder", role: .destructive) { model.startAction(request) }
            }
        }
        .alert("Operation Failed", isPresented: actionErrorPresented) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { destination == nil && model.actionError != nil },
            set: { if !$0 { model.clearActionError() } }
        )
    }

    @ViewBuilder
    private var emptyContent: some View {
        if !model.hasLoaded || model.canRetryLoading {
            failureContent
        } else if let keyword = model.activeKeyword {
            ContentUnavailableView.search(text: keyword)
        } else {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        }
    }

    private var failureContent: some View {
        ContentUnavailableView {
            Label("Load Failed", systemImage: "exclamationmark.triangle")
        } description: {
            if let error = model.loadError { Text(error) }
        } actions: {
            Button("Retry") { Task { await model.retry() } }.buttonStyle(.borderedProminent)
        }
    }

    private func hasItemMenu(_ item: FavoriteContentResult.FavoriteMedia) -> Bool {
        item.isPlayableVideo || (item.isVideo && model.ownsFolder) || (item.upper?.mid ?? 0) > 0
    }

    private func makeItemMenu(
        for item: FavoriteContentResult.FavoriteMedia,
        sourceView: UIView?
    ) -> UIMenu? {
        guard hasItemMenu(item) else { return nil }
        var children: [UIMenuElement] = []

        if item.isPlayableVideo, let url = URL(string: "https://www.bilibili.com/video/av\(item.id)") {
            children.append(UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak sourceView] _ in
                presentShareSheet(url: url, sourceView: sourceView)
            })
            children.append(UIAction(
                title: String(localized: "Copy Link"),
                image: UIImage(systemName: "link")
            ) { _ in
                UIPasteboard.general.url = url
                model.notice = ToastMessage(text: String(localized: "Copied"), style: .success)
            })
            children.append(contentsOf: mutationActions(for: item))
        }

        if let mid = item.upper?.mid, mid > 0 {
            children.append(UIAction(
                title: String(localized: "View Uploader"),
                image: UIImage(systemName: "person.crop.circle")
            ) { _ in
                coordinator.navigate(to: .userSpace(mid))
            })
        }

        if let request = model.actionRequest(.remove, item: item) {
            children.append(UIAction(
                title: String(localized: "Remove from Folder"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                pendingRemoval = request
            })
        }

        return children.isEmpty ? nil : UIMenu(children: children)
    }

    private func mutationActions(for item: FavoriteContentResult.FavoriteMedia) -> [UIAction] {
        var actions: [UIAction] = []
        if let request = model.actionRequest(.watchLater, item: item) {
            actions.append(UIAction(
                title: String(localized: "Watch Later"),
                image: UIImage(systemName: "clock")
            ) { _ in
                model.startAction(request)
            })
        }
        if let request = model.actionRequest(.save, item: item) {
            actions.append(UIAction(
                title: String(localized: "Add to Favorites"),
                image: UIImage(systemName: "star")
            ) { _ in
                destination = request
            })
        }
        if let request = model.actionRequest(.copy, item: item) {
            actions.append(UIAction(
                title: String(localized: "Copy to Folder"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                destination = request
            })
        }
        if let request = model.actionRequest(.move, item: item) {
            actions.append(UIAction(
                title: String(localized: "Move to Folder"),
                image: UIImage(systemName: "folder")
            ) { _ in
                destination = request
            })
        }
        return actions
    }

    @MainActor
    private func presentShareSheet(url: URL, sourceView: UIView?) {
        ActivitySharePresenter.present(items: [url], sourceView: sourceView)
    }
}

private struct FavoriteDestinationSheet: View {
    let model: FavoriteDetailViewModel
    let request: FavoriteDetailViewModel.ActionRequest
    @State private var folders: [FavoriteFolderResult.FavoriteFolder] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var attempted = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(folders) { folder in
                Button { select(folder.id) } label: {
                    HStack(spacing: 12) {
                        FolderIconView(size: 32)
                        Text(folder.title).foregroundStyle(.primary)
                        Spacer()
                        if let count = folder.mediaCount {
                            Text("\(count) items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(model.activeActionID != nil || !model.admits(request))
                .listRowBackground(AppFill.card)
            }
            .readableFormWidth(.ambientBrowse)
            .navigationTitle(request.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.activeActionID != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.activeActionID != nil { ProgressView() }
                }
            }
            .overlay { overlay }
            .alert("Operation Failed", isPresented: actionErrorPresented) {
                Button("OK") { model.clearActionError(for: request.id) }
            } message: { Text(model.actionError(for: request.id) ?? "") }
        }
        .accentContentBoundary()
        .appAdaptiveSheet(padSizing: .form)
        .interactiveDismissDisabled(model.activeActionID != nil)
        .task { await loadFolders() }
        .onChange(of: model.isCurrentAccount) { if !model.isCurrentAccount { dismiss() } }
        .onDisappear { model.clearActionError(for: request.id) }
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { model.actionError(for: request.id) != nil },
            set: { if !$0 { model.clearActionError(for: request.id) } }
        )
    }

    @ViewBuilder
    private var overlay: some View {
        if !model.admits(request) {
            ContentUnavailableView("Action Unavailable", systemImage: "folder.badge.questionmark")
        } else if isLoading || !attempted {
            ProgressView()
        } else if !loaded {
            ContentUnavailableView {
                Label("Load Failed", systemImage: "exclamationmark.triangle")
            } description: {
                if let error { Text(error) }
            } actions: {
                Button("Retry") { Task { await loadFolders() } }.buttonStyle(.borderedProminent)
            }
        } else if folders.isEmpty {
            ContentUnavailableView("No Other Folders", systemImage: "folder")
        }
    }

    private func loadFolders() async {
        guard !Task.isCancelled, !isLoading, !loaded, model.admits(request),
              let mid = Int(request.accountID), mid > 0 else { return }
        isLoading = true
        attempted = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await UserAPI.getFavorites(mid: mid)
            guard !Task.isCancelled, model.admits(request) else { return }
            folders = (result.list ?? []).filter { $0.id > 0 && $0.id != model.mediaID }
            loaded = true
        } catch {
            guard !Task.isCancelled, model.admits(request), !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
    }

    private func select(_ folderID: Int) {
        guard folders.contains(where: { $0.id == folderID }),
              let action = model.startAction(request, destinationID: folderID) else { return }
        Task {
            guard await action.value, !Task.isCancelled, model.isCurrentAccount else { return }
            dismiss()
        }
    }
}
