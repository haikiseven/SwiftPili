import Observation
import SwiftUI

/// The full watch history (x/v2/history), cursor-paginated — the Mine
/// tab shows only the three most recent entries.
struct FullHistoryView: View {
    var body: some View {
        FullHistoryContentView()
            .id(AccountManager.shared.identityRevision)
    }
}

private struct FullHistoryContentView: View {
    @State private var model = FullHistoryListModel()
    @Environment(AppCoordinator.self) private var coordinator

    private var showsInitialPlaceholder: Bool {
        model.items.isEmpty && (model.isLoading || (!model.hasLoaded && model.loadError == nil))
    }

    private var rowItems: [MineLibraryRowItem] {
        model.items.map { item in
            // Case B, and BOTH halves of that are facts rather than assumptions.
            // `x/web-interface/history/cursor` composes no mobile variant, so the
            // widescreen asset is the fallback by API limitation — the display
            // mode, not a rewritten URL, resolves it against a 4:3 frame. And the
            // asset really is an archive `pic`: `UserAPI.getHistory` asks for
            // `type=archive`, which is what keeps live-room artwork and column
            // images out of this list.
            MineLibraryRowItem(
                id: .int(item.id),
                title: item.title,
                sources: VideoCoverSources(widescreen: item.cover),
                duration: item.duration,
                subtitle: item.authorName,
                footer: .text(FormatUtils.timeAgo(from: item.viewAt)),
                watchProgress: item.duration > 0
                    ? FormatUtils.historyProgressFraction(progress: item.progress, duration: item.duration)
                    : nil
            )
        }
    }

    private var footerState: MineFeedFooterState {
        guard !model.items.isEmpty else { return .none }
        if let error = model.loadError {
            return .error(message: error, retryTitle: String(localized: "Retry"))
        }
        if model.isLoading {
            return .loading
        }
        if model.hasMore {
            return .more(title: String(localized: "More"))
        }
        return .none
    }

    var body: some View {
        let placeholderLabel = String(
            format: String(localized: "Loading %@"),
            String(localized: "Watch History")
        )
        MineLibraryRowFeedView(
            items: rowItems,
            placeholderCount: showsInitialPlaceholder ? 6 : 0,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            onRefresh: {
                await model.refresh()
                return false
            },
            onNearEndAppear: {
                Task { await model.loadMore() }
            },
            onFooterAction: {
                if model.loadError != nil {
                    Task { await model.retry() }
                } else {
                    Task { await model.loadMore() }
                }
            },
            onSelectItem: { id in
                guard case .int(let kid) = id,
                      let item = model.items.first(where: { $0.id == kid }),
                      let target = VideoRouteTarget.make(
                          bvid: nil,
                          aid: item.kid,
                          title: item.title,
                          coverURL: item.cover,
                          ownerName: item.authorName,
                          durationSeconds: item.duration
                      ) else { return }
                coordinator.navigateToVideo(target)
            }
        )
        .appAmbientBrowseBackground()
        .navigationTitle("Watch History")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.items.isEmpty, !showsInitialPlaceholder {
                if let error = model.loadError {
                    MessageLoadFailureView(message: error) {
                        Task { await model.retry() }
                    }
                } else {
                    ContentUnavailableView("No Videos", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .task {
            if !model.hasLoaded { await model.loadMore() }
        }
    }
}

@MainActor
@Observable
private final class FullHistoryListModel {
    private(set) var items: [HistoryResult.HistoryItem] = []
    var isLoading: Bool { loadRequestID != nil }
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private var cursor: HistoryResult.HistoryCursor?
    private(set) var hasMore = true
    private var lastFailureWasRefresh = false
    private var loadRequestID: UUID?
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
