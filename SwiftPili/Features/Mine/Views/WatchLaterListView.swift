import Observation
import SwiftUI

struct WatchLaterListView: View {
    @State private var model = WatchLaterListModel()
    @State private var pendingRemoval: WatchLaterResult.WatchLaterItem?
    @State private var showRemoveWatchedConfirm = false
    @State private var showClearConfirm = false
    @Environment(AppCoordinator.self) private var coordinator

    private var showsInitialPlaceholder: Bool {
        model.items.isEmpty && (model.isBusy || (!model.hasLoaded && model.loadError == nil))
    }

    private var footerState: MineFeedFooterState {
        guard !model.items.isEmpty else { return .none }
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
        MineLibraryRowFeedView(
            items: model.rowItems,
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
                      let target = routeTarget(item) else { return }
                coordinator.navigateToVideo(target)
            },
            makeContextMenu: { id in
                guard !model.isBusy,
                      case .int(let aid) = id,
                      let item = model.items.first(where: { $0.id == aid }) else {
                    return nil
                }
                let removeAction = UIAction(
                    title: String(localized: "Remove from Watch Later"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    pendingRemoval = item
                }
                return UIMenu(children: [removeAction])
            }
        )
        .appAmbientBrowseBackground()
        .navigationTitle("Watch Later")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showRemoveWatchedConfirm = true
                        } label: {
                            Label("Remove Watched", systemImage: "checkmark.circle")
                        }
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
            if model.items.isEmpty, !showsInitialPlaceholder {
                if let error = model.loadError {
                    MessageLoadFailureView(message: error) { Task { await model.reload() } }
                } else {
                    ContentUnavailableView("No Videos", systemImage: "clock")
                }
            }
        }
        .task { await model.reload() }
    }

    private func routeTarget(_ item: WatchLaterResult.WatchLaterItem) -> VideoRouteTarget? {
        .make(
            bvid: item.bvid,
            aid: item.aid,
            title: item.title,
            coverURL: item.pic,
            ownerName: item.owner?.name ?? "",
            durationSeconds: item.duration ?? 0
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

    private(set) var items: [WatchLaterResult.WatchLaterItem] = [] {
        didSet {
            rowItems = items.map { item in
                let footer: UIKitRowVideoCell.FooterMode = if let stat = item.stat {
                    .stats(play: stat.view, danmaku: stat.danmaku)
                } else {
                    .none
                }
                return MineLibraryRowItem(
                    id: .int(item.id),
                    title: item.title,
                    sources: VideoCoverSources(widescreen: item.pic),
                    duration: item.duration ?? 0,
                    subtitle: item.owner?.name,
                    footer: footer
                )
            }
        }
    }
    private(set) var rowItems: [MineLibraryRowItem] = []
    var isBusy: Bool { loadRequestID != nil || actionID != nil }
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var actionError: String?
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
        case .remove(let aid): items.removeAll { $0.aid == aid }
        case .removeWatched: await fetchList(for: request)
        case .clearAll:
            items = []
            hasLoaded = true
            loadError = nil
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
