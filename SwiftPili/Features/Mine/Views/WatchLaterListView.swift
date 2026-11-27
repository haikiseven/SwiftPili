import Observation
import SwiftUI
import UIKit

struct WatchLaterListView: View {
    @State private var model = WatchLaterListModel()
    @State private var searchText = ""
    @State private var pendingRemoval: WatchLaterResult.WatchLaterItem?
    @State private var favoriteTarget: WatchLaterResult.WatchLaterItem?
    @State private var showRemoveWatchedConfirm = false
    @State private var showClearConfirm = false
    @Environment(AppCoordinator.self) private var coordinator

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [WatchLaterResult.WatchLaterItem] {
        let query = trimmedQuery
        guard !query.isEmpty else { return model.items }
        return model.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.owner?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var watchedCount: Int {
        model.items.reduce(into: 0) { count, item in
            if item.isWatched { count += 1 }
        }
    }

    private var sections: [MineLibraryRowSection] {
        let visible = filteredItems
        guard !visible.isEmpty else { return [] }
        let isMenuEnabled = !model.isBusy
        let cardItems = visible.map { item in
            let footer: UIKitRowVideoCell.FooterMode = if let stat = item.stat {
                .stats(play: stat.view, danmaku: stat.danmaku)
            } else {
                .none
            }
            return MineLibraryCardItem(
                id: .int(item.id),
                title: item.title,
                sources: VideoCoverSources(widescreen: item.pic),
                duration: item.duration ?? 0,
                subtitle: item.owner?.name,
                footer: footer,
                watchProgress: item.watchProgressFraction,
                isSelectable: !item.isUnavailable,
                isUnavailable: item.isUnavailable,
                statusBadge: item.isUnavailable ? String(localized: "Unavailable") : nil,
                statusBadgeStyle: .warning,
                hasTrailingMenu: true,
                trailingMenuAccessibilityLabel: String(localized: "More actions for \(item.title)"),
                isTrailingMenuEnabled: isMenuEnabled,
                allowsSwipeDelete: isMenuEnabled,
                swipeDeleteTitle: String(localized: "Remove")
            )
        }
        return [MineLibraryRowSection(id: "watchLater", title: nil, items: cardItems)]
    }

    private var showsInitialPlaceholder: Bool {
        model.items.isEmpty && (model.isBusy || (!model.hasLoaded && model.loadError == nil))
    }

    private var footerState: MineFeedFooterState {
        guard !filteredItems.isEmpty else { return .none }
        if let error = model.loadError {
            return .error(message: error, retryTitle: String(localized: "Retry"))
        }
        if model.isBusy {
            return .loading
        }
        return .none
    }

    var body: some View {
        let placeholderLabel = String(
            format: String(localized: "Loading %@"),
            String(localized: "Watch Later")
        )
        MineLibrarySectionedFeedView(
            sections: sections,
            placeholderCount: showsInitialPlaceholder ? 6 : 0,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            onRefresh: {
                await model.reload()
                return false
            },
            onFooterAction: {
                Task { await model.reload() }
            },
            onSelectItem: { id in
                guard case .int(let aid) = id,
                      let item = model.items.first(where: { $0.id == aid }),
                      !item.isUnavailable,
                      let target = routeTarget(item) else { return }
                coordinator.navigateToVideo(target)
            },
            makeTrailingMenu: { id, sourceView in
                guard case .int(let aid) = id,
                      let item = model.items.first(where: { $0.id == aid }) else {
                    return nil
                }
                return makeItemMenu(for: item, sourceView: sourceView)
            },
            makeContextMenu: { id in
                guard !model.isBusy,
                      case .int(let aid) = id,
                      let item = model.items.first(where: { $0.id == aid }) else {
                    return nil
                }
                return makeItemMenu(for: item, sourceView: nil)
            },
            onSwipeDelete: { id in
                guard case .int(let aid) = id else { return }
                model.startAction(.remove(aid))
            }
        )
        .appAmbientBrowseBackground()
        .navigationTitle("Watch Later")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search Watch Later")
        .toolbar {
            if !model.items.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !playableEntries.isEmpty {
                        Button {
                            playAll()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                    .font(.caption.weight(.semibold))
                                Text("Play All")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("watchLater.playAll")
                    }

                    Menu {
                        Button {
                            showRemoveWatchedConfirm = true
                        } label: {
                            Label("Remove Watched", systemImage: "checkmark.circle")
                        }
                        .disabled(watchedCount == 0)
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel(Text("More"))
                }
            }
        }
        .sheet(item: $favoriteTarget) { item in
            WatchLaterFavoritePickerSheet(item: item) {
                model.notice = ToastMessage(text: String(localized: "Saved"), style: .success)
            }
        }
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Watch Later", role: .destructive) {
                if let item = pendingRemoval { model.startAction(.remove(item.aid)) }
            }
            .disabled(model.isBusy)
        }
        .confirmationDialog(
            "Remove all watched videos from Watch Later?",
            isPresented: $showRemoveWatchedConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Watched", role: .destructive) { model.startAction(.removeWatched) }
                .disabled(model.isBusy)
        }
        .confirmationDialog(
            "Clear the entire Watch Later list?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { model.startAction(.clearAll) }
                .disabled(model.isBusy)
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.clearActionError() } }
        )) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .overlay {
            if filteredItems.isEmpty, !showsInitialPlaceholder {
                emptyContent
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                ToastView(message: notice)
                    .padding()
            }
        }
        .task(id: model.notice?.id) {
            let noticeID = model.notice?.id
            guard noticeID != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, model.notice?.id == noticeID { model.notice = nil }
        }
        .task { await model.reload() }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if model.items.isEmpty {
            if let error = model.loadError {
                MessageLoadFailureView(message: error) { Task { await model.reload() } }
            } else {
                ContentUnavailableView(
                    "Watch Later is Empty",
                    systemImage: "clock",
                    description: Text("Videos you save to Watch Later will appear here.")
                )
            }
        } else {
            ContentUnavailableView.search(text: trimmedQuery)
        }
    }

    private func videoURL(for item: WatchLaterResult.WatchLaterItem) -> URL? {
        if let bvid = item.bvid, !bvid.isEmpty {
            return URL(string: "https://www.bilibili.com/video/\(bvid)")
        }
        return URL(string: "https://www.bilibili.com/video/av\(item.aid)")
    }

    private func makeItemMenu(
        for item: WatchLaterResult.WatchLaterItem,
        sourceView: UIView?
    ) -> UIMenu {
        var children: [UIMenuElement] = []

        if !item.isUnavailable, let url = videoURL(for: item) {
            children.append(UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak sourceView] _ in
                let source = SwiftPiliLinkActivityItemSource(
                    url: url,
                    title: item.title,
                    uploader: item.owner?.name ?? ""
                )
                ActivitySharePresenter.present(items: [source], sourceView: sourceView)
            })
            children.append(UIAction(
                title: String(localized: "Copy Link"),
                image: UIImage(systemName: "link")
            ) { _ in
                UIPasteboard.general.url = url
                model.notice = ToastMessage(text: String(localized: "Copied"), style: .success)
            })
            children.append(UIAction(
                title: String(localized: "Add to Favorites"),
                image: UIImage(systemName: "star")
            ) { _ in
                favoriteTarget = item
            })
        }

        if let mid = item.owner?.mid, mid > 0 {
            children.append(UIAction(
                title: String(localized: "View Uploader"),
                image: UIImage(systemName: "person.crop.circle")
            ) { _ in
                coordinator.navigate(to: .userSpace(mid))
            })
        }

        children.append(UIAction(
            title: String(localized: "Remove from Watch Later"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            pendingRemoval = item
        })

        return UIMenu(children: children)
    }

    private var playableEntries: [PlaylistQueueEntry] {
        filteredItems.compactMap { item in
            guard !item.isUnavailable, let target = routeTarget(item) else { return nil }
            return PlaylistQueueEntry(
                aid: item.aid,
                bvid: item.bvid,
                cid: nil,
                title: item.title,
                artist: item.owner?.name ?? "",
                coverURL: item.pic.isEmpty ? nil : item.pic,
                duration: item.duration.map(TimeInterval.init),
                isPortraitHint: nil,
                routeTarget: target
            )
        }
    }

    private func playAll() {
        let entries = playableEntries
        guard !entries.isEmpty else { return }
        _ = PlaylistQueueLauncher.shared.launch(
            playlistName: String(localized: "Watch Later"),
            entries: entries,
            coordinator: coordinator
        )
    }

    private func routeTarget(_ item: WatchLaterResult.WatchLaterItem) -> VideoRouteTarget? {
        .make(
            bvid: item.bvid,
            aid: item.aid,
            title: item.title,
            coverURL: item.pic,
            ownerName: item.owner?.name ?? "",
            durationSeconds: item.duration ?? 0,
            isPortraitHint: item.dimension?.isPortrait,
            aspectRatioHint: item.dimension?.effectiveAspectRatio
        )
    }
}

@MainActor
@Observable
private final class WatchLaterListModel {
    enum Action {
        case remove(Int)
        case removeWatched
        case clearAll
    }

    private enum Request: Equatable {
        case load(UUID)
        case action(UUID)
    }

    private(set) var items: [WatchLaterResult.WatchLaterItem] = []
    var isBusy: Bool { loadRequestID != nil || actionID != nil }
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var actionError: String?
    var notice: ToastMessage?
    private var loadRequestID: UUID?
    private var actionID: UUID?
    @ObservationIgnored private var loadWork: Task<Void, Never>?
    private let accountRevision = AccountManager.shared.identityRevision
    private let accountID = AccountManager.shared.activeMid
    private let sessionGeneration = AuthManager.shared.sessionGeneration

    private var isCurrentSource: Bool {
        AccountManager.shared.identityRevision == accountRevision
            && AccountManager.shared.activeMid == accountID
            && AuthManager.shared.dedeUserID == accountID
            && AuthManager.shared.sessionGeneration == sessionGeneration
    }

    func clearActionError() { actionError = nil }

    func reload() async {
        guard !Task.isCancelled, isCurrentSource, actionID == nil else { return }
        guard loadRequestID == nil || loadWork?.isCancelled == true else { return }
        loadWork?.cancel()
        let requestID = UUID()
        loadRequestID = requestID
        let work = Task { await fetchList(for: .load(requestID)) }
        loadWork = work
        defer {
            if loadRequestID == requestID {
                loadRequestID = nil
                loadWork = nil
            }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func startAction(_ action: Action) {
        guard isCurrentSource, !isBusy else { return }
        if case .remove(let aid) = action, !items.contains(where: { $0.aid == aid }) { return }
        let requestID = UUID()
        actionID = requestID
        actionError = nil
        Task {
            defer { if actionID == requestID { actionID = nil } }
            let request = Request.action(requestID)
            guard isCurrent(request) else { return }
            do {
                try await perform(action)
                guard isCurrent(request) else { return }
                await publishAccepted(action, for: request)
            } catch {
                guard isCurrent(request), shouldPresent(error) else { return }
                actionError = error.localizedDescription
                PlayerLog.log("[WatchLater] action failed: \(error)")
            }
        }
    }

    private func perform(_ action: Action) async throws(BiliError) {
        switch action {
        case .remove(let aid): _ = try await UserAPI.removeFromWatchLater(aid: aid)
        case .removeWatched: _ = try await UserAPI.removeWatchedFromWatchLater()
        case .clearAll: _ = try await UserAPI.clearWatchLater()
        }
    }

    private func publishAccepted(_ action: Action, for request: Request) async {
        guard isCurrent(request) else { return }
        switch action {
        case .remove(let aid):
            items.removeAll { $0.aid == aid }
            notice = ToastMessage(text: String(localized: "Removed"), style: .success)
        case .removeWatched:
            await fetchList(for: request)
            notice = ToastMessage(text: String(localized: "Removed"), style: .success)
        case .clearAll:
            items = []
            hasLoaded = true
            loadError = nil
            notice = ToastMessage(text: String(localized: "Cleared"), style: .success)
        }
    }

    private func fetchList(for request: Request) async {
        guard isCurrent(request) else { return }
        loadError = nil
        do {
            let result = try await UserAPI.getWatchLater(ps: 100)
            guard isCurrent(request) else { return }
            guard let list = result.list else {
                throw BiliError.decodingFailed(DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "Missing watch-later list"
                )))
            }
            items = list
            hasLoaded = true
        } catch {
            guard isCurrent(request), shouldPresent(error) else { return }
            loadError = error.localizedDescription
            PlayerLog.log("[WatchLater] load failed: \(error)")
        }
    }

    private func shouldPresent(_ error: any Error) -> Bool {
        !(error is CancellationError)
            && (error as? BiliError)?.isCancellation != true
    }

    private func isCurrent(_ request: Request) -> Bool {
        guard !Task.isCancelled, isCurrentSource else { return false }
        switch request {
        case .load(let requestID): return loadRequestID == requestID
        case .action(let requestID): return actionID == requestID
        }
    }
}

private struct WatchLaterFavoritePickerSheet: View {
    let item: WatchLaterResult.WatchLaterItem
    let onSaved: () -> Void
    @State private var folders: [FavoriteFolderResult.FavoriteFolder] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loaded = false
    @State private var loadError: String?
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(folders) { folder in
                Button {
                    save(to: folder.id)
                } label: {
                    HStack(spacing: 12) {
                        FolderIconView(size: 32)
                        Text(folder.title)
                            .foregroundStyle(.primary)
                        if folder.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let count = folder.mediaCount {
                            Text("\(count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(isSaving)
                .listRowBackground(AppFill.card)
            }
            .readableFormWidth(.ambientBrowse)
            .navigationTitle("Add to Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .primaryAction) {
                    if isSaving { ProgressView() }
                }
            }
            .overlay {
                if isLoading || (!loaded && loadError == nil) {
                    ProgressView()
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Load Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await loadFolders() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if folders.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder")
                }
            }
            .alert("Operation Failed", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
        .accentContentBoundary()
        .appAdaptiveSheet(padSizing: .form)
        .interactiveDismissDisabled(isSaving)
        .task { await loadFolders() }
    }

    private func loadFolders() async {
        guard !isLoading, let mid = AuthManager.shared.dedeUserID.flatMap(Int.init), mid > 0 else {
            loaded = true
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let result = try await UserAPI.getFavorites(mid: mid)
            guard !Task.isCancelled else { return }
            folders = result.list ?? []
            loaded = true
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            loadError = error.localizedDescription
        }
    }

    private func save(to folderID: Int) {
        guard !isSaving else { return }
        isSaving = true
        actionError = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await VideoAPI.dealFavorite(aid: item.aid, addIds: [folderID], delIds: [])
                guard !Task.isCancelled else { return }
                onSaved()
                dismiss()
            } catch {
                guard !Task.isCancelled,
                      !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true else { return }
                actionError = error.localizedDescription
            }
        }
    }
}
