import Observation
import SwiftUI
import UIKit

struct FullHistoryView: View {
    @State private var model = FullHistoryListModel()
    @State private var searchText = ""
    @State private var showClearConfirm = false
    @Environment(AppCoordinator.self) private var coordinator

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [HistoryResult.HistoryItem] {
        let query = trimmedQuery
        guard !query.isEmpty else { return model.items }
        return model.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.authorName.localizedCaseInsensitiveContains(query)
        }
    }

    private var showsInitialPlaceholder: Bool {
        model.items.isEmpty && (model.isLoading || (!model.hasLoaded && model.loadError == nil))
    }

    private var sections: [MineLibraryRowSection] {
        let visible = filteredItems
        guard !visible.isEmpty else { return [] }
        let isMenuEnabled = !model.isMutating
        let cards = visible.map { item in
            let watchProgress: Double? = if item.duration > 0, item.progress != 0 {
                FormatUtils.historyProgressFraction(progress: item.progress, duration: item.duration)
            } else {
                nil
            }
            return MineLibraryCardItem(
                id: .int(item.id),
                title: item.title,
                sources: VideoCoverSources(widescreen: item.cover),
                duration: item.duration,
                subtitle: item.authorName,
                footer: .text(FormatUtils.timeAgo(from: item.viewAt)),
                watchProgress: watchProgress,
                isSelectable: true,
                isUnavailable: false,
                statusBadge: nil,
                statusBadgeStyle: .neutral,
                hasTrailingMenu: true,
                trailingMenuAccessibilityLabel: String(localized: "More actions for \(item.title)"),
                isTrailingMenuEnabled: isMenuEnabled,
                allowsSwipeDelete: isMenuEnabled,
                swipeDeleteTitle: String(localized: "Delete")
            )
        }
        return [MineLibraryRowSection(id: "history", title: nil, items: cards)]
    }

    private var footerState: MineFeedFooterState {
        guard !filteredItems.isEmpty else { return .none }
        if let error = model.loadError {
            return .error(message: error, retryTitle: String(localized: "Retry"))
        }
        if model.isLoading {
            return .loading
        }
        return .none
    }

    var body: some View {
        let placeholderLabel = String(
            format: String(localized: "Loading %@"),
            String(localized: "Watch History")
        )
        MineLibrarySectionedFeedView(
            sections: sections,
            placeholderCount: showsInitialPlaceholder ? 6 : 0,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            onRefresh: {
                await model.refresh()
                return false
            },
            onNearEndAppear: {
                guard trimmedQuery.isEmpty else { return }
                Task { await model.loadMore() }
            },
            onFooterAction: {
                Task { await model.retry() }
            },
            onSelectItem: { id in
                guard case .int(let kid) = id,
                      let item = model.items.first(where: { $0.id == kid }),
                      let target = VideoRouteTarget.make(
                          bvid: item.bvid,
                          aid: item.kid,
                          title: item.title,
                          coverURL: item.cover,
                          ownerName: item.authorName,
                          durationSeconds: item.duration
                      ) else { return }
                coordinator.navigateToVideo(target)
            },
            makeTrailingMenu: { id, sourceView in
                guard case .int(let kid) = id,
                      let item = model.items.first(where: { $0.id == kid }) else {
                    return nil
                }
                return makeItemMenu(for: item, sourceView: sourceView)
            },
            makeContextMenu: { id in
                guard !model.isMutating,
                      case .int(let kid) = id,
                      let item = model.items.first(where: { $0.id == kid }) else {
                    return nil
                }
                return makeItemMenu(for: item, sourceView: nil)
            },
            onSwipeDelete: { id in
                guard case .int(let kid) = id,
                      let item = model.items.first(where: { $0.id == kid }) else {
                    return
                }
                model.deleteItem(item)
            }
        )
        .appAmbientBrowseBackground()
        .navigationTitle("Watch History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search history")
        .toolbar {
            if !model.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(model.isMutating)
                    .accessibilityLabel(Text("Clear History"))
                }
            }
        }
        .confirmationDialog(
            "Clear all watch history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                model.clearHistory()
            }
            .disabled(model.isMutating)
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
                if !trimmedQuery.isEmpty, !model.items.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                } else if let error = model.loadError {
                    MessageLoadFailureView(message: error) {
                        Task { await model.retry() }
                    }
                } else {
                    ContentUnavailableView("No Watch History", systemImage: "clock.arrow.circlepath")
                }
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
        .task {
            if !model.hasLoaded { await model.loadMore() }
        }
    }

    private func videoURL(for item: HistoryResult.HistoryItem) -> URL? {
        if let bvid = item.bvid {
            return URL(string: "https://www.bilibili.com/video/\(bvid)")
        }
        return URL(string: "https://www.bilibili.com/video/av\(item.kid)")
    }

    private func makeItemMenu(
        for item: HistoryResult.HistoryItem,
        sourceView: UIView?
    ) -> UIMenu {
        var children: [UIMenuElement] = []

        if let url = videoURL(for: item) {
            children.append(UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak sourceView] _ in
                let source = SwiftPiliLinkActivityItemSource(
                    url: url,
                    title: item.title,
                    uploader: item.authorName
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
        }

        if item.kid > 0 {
            children.append(UIAction(
                title: String(localized: "Watch Later"),
                image: UIImage(systemName: "clock")
            ) { _ in
                model.addToWatchLater(item)
            })
        }

        if item.authorMid > 0 {
            children.append(UIAction(
                title: String(localized: "View Uploader"),
                image: UIImage(systemName: "person.crop.circle")
            ) { _ in
                coordinator.navigate(to: .userSpace(item.authorMid))
            })
        }

        children.append(UIAction(
            title: String(localized: "Delete from History"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            model.deleteItem(item)
        })

        return UIMenu(children: children)
    }
}

@MainActor
@Observable
private final class FullHistoryListModel {
    private(set) var items: [HistoryResult.HistoryItem] = []
    var isLoading: Bool { loadRequestID != nil }
    var isMutating: Bool { mutationID != nil }
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var actionError: String?
    var notice: ToastMessage?
    private var cursor: HistoryResult.HistoryCursor?
    private(set) var hasMore = true
    private var lastFailureWasRefresh = false
    private var loadRequestID: UUID?
    private var mutationID: UUID?
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

    func deleteItem(_ item: HistoryResult.HistoryItem) {
        guard isCurrentSource, !isMutating else { return }
        let token = UUID()
        mutationID = token
        actionError = nil
        Task {
            defer { if mutationID == token { mutationID = nil } }
            do {
                _ = try await UserAPI.deleteHistoryItem(kid: item.kid, business: item.historyBusiness)
                guard !Task.isCancelled, isCurrentSource, mutationID == token else { return }
                items.removeAll { $0.id == item.id }
                notice = ToastMessage(text: String(localized: "Removed"), style: .success)
            } catch {
                guard !Task.isCancelled, isCurrentSource, mutationID == token,
                      !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func clearHistory() {
        guard isCurrentSource, !isMutating else { return }
        let token = UUID()
        mutationID = token
        actionError = nil
        Task {
            defer { if mutationID == token { mutationID = nil } }
            do {
                _ = try await UserAPI.clearHistory()
                guard !Task.isCancelled, isCurrentSource, mutationID == token else { return }
                items = []
                cursor = nil
                hasMore = false
                hasLoaded = true
                loadError = nil
                notice = ToastMessage(text: String(localized: "History Cleared"), style: .success)
            } catch {
                guard !Task.isCancelled, isCurrentSource, mutationID == token,
                      !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func addToWatchLater(_ item: HistoryResult.HistoryItem) {
        guard isCurrentSource, !isMutating, item.kid > 0 else { return }
        let token = UUID()
        mutationID = token
        actionError = nil
        Task {
            defer { if mutationID == token { mutationID = nil } }
            do {
                _ = try await UserAPI.addToWatchLater(aid: item.kid)
                guard !Task.isCancelled, isCurrentSource, mutationID == token else { return }
                notice = ToastMessage(text: String(localized: "Added to Watch Later"), style: .success)
            } catch {
                guard !Task.isCancelled, isCurrentSource, mutationID == token,
                      !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard !Task.isCancelled, isCurrentSource else { return }
        loadWork?.cancel()
        let requestID = UUID()
        let previousError = loadError
        let previousFailureWasRefresh = lastFailureWasRefresh
        loadRequestID = requestID
        loadError = nil
        lastFailureWasRefresh = false
        let work = Task { await fetchPage(requestID, max: 0, viewAt: 0, replaces: true) }
        loadWork = work
        defer {
            if loadRequestID == requestID {
                loadRequestID = nil
                loadWork = nil
                if Task.isCancelled, !hasLoaded, items.isEmpty, loadError == nil {
                    loadError = previousError
                    lastFailureWasRefresh = previousFailureWasRefresh
                }
            }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func retry() async {
        if lastFailureWasRefresh {
            await refresh()
        } else {
            await loadMore(retrying: true)
        }
    }

    func loadMore(retrying: Bool = false) async {
        guard !Task.isCancelled, isCurrentSource, hasMore,
              loadError == nil || retrying else { return }
        guard loadRequestID == nil || loadWork?.isCancelled == true else { return }
        loadWork?.cancel()
        let requestID = UUID()
        let requestedMax = cursor?.max ?? 0
        let requestedViewAt = cursor?.viewAt ?? 0
        loadRequestID = requestID
        loadError = nil
        lastFailureWasRefresh = false
        let work = Task {
            await fetchPage(requestID, max: requestedMax, viewAt: requestedViewAt, replaces: false)
        }
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

    private func fetchPage(
        _ requestID: UUID,
        max requestedMax: Int,
        viewAt requestedViewAt: Int,
        replaces: Bool
    ) async {
        guard isCurrent(requestID) else { return }
        do {
            let result = try await UserAPI.getHistory(max: requestedMax, viewAt: requestedViewAt)
            guard isCurrent(requestID) else { return }
            guard let page = result.list else {
                throw BiliError.decodingFailed(DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "Missing history list"
                )))
            }
            if replaces {
                items = FeedCollectionPolicy.replaceDeduplicated(page, id: \.id)
            } else {
                FeedCollectionPolicy.appendDeduplicated(to: &items, incoming: page, id: \.id)
            }
            cursor = result.cursor
            hasLoaded = true
            hasMore = !page.isEmpty && result.cursor.map {
                $0.max != requestedMax || $0.viewAt != requestedViewAt
            } == true
            loadError = nil
            lastFailureWasRefresh = false
        } catch {
            guard isCurrent(requestID), !(error is CancellationError),
                  (error as? BiliError)?.isCancellation != true else { return }
            loadError = error.localizedDescription
            lastFailureWasRefresh = replaces
            PlayerLog.log("[History] load failed: \(error)")
        }
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        !Task.isCancelled && isCurrentSource && loadRequestID == requestID
    }
}
