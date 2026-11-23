import Foundation
import Observation

@MainActor
@Observable
final class MessageCenterViewModel {
    var unread: MessageUnreadCount?
    var replyItems: [ReplyMessageResult.ReplyMsgItem] = []
    var atItems: [AtMessageResult.AtMsgItem] = []
    var likeItems: [LikeMessageResult.LikeMsgItem] = []
    var systemItems: [SystemNotifyResult.SystemNotifyItem] = []
    var sessions: [SessionListResult.SessionItem] = []
    private(set) var isLoadingSessions = false
    private(set) var sessionsLoaded = false
    private(set) var sessionLoadError: String?
    var sessionUsers: [Int: IMUserInfo] = [:]

    var isLoadingReplies = false
    var isLoadingAt = false
    var isLoadingLikes = false
    var isLoadingSystem = false
    private(set) var replyLoadError: String?
    private(set) var atLoadError: String?
    private(set) var likeLoadError: String?
    private(set) var systemLoadError: String?

    private var replyCursor: ReplyMessageResult.MsgCursor?
    private var atCursor: ReplyMessageResult.MsgCursor?
    private var likeCursor: ReplyMessageResult.MsgCursor?
    private var systemCursorId: Int?
    private(set) var repliesLoaded = false
    private(set) var atLoaded = false
    private(set) var likesLoaded = false
    private(set) var systemLoaded = false
    private(set) var repliesAttempted = false
    private(set) var atAttempted = false
    private(set) var likesAttempted = false
    private(set) var systemAttempted = false

    private struct InitialSource: Equatable {
        let sessionGeneration: UUID
        let accountRevision: UInt64
        let accountMID: String?
    }

    private struct InitialRequest: Equatable {
        let source: InitialSource
        let sequence: UInt64
    }

    @ObservationIgnored private var initialRequest: InitialRequest?
    @ObservationIgnored private var initialWork: Task<Void, Never>?
    @ObservationIgnored private var initialSequence: UInt64 = 0

    func loadInitial() async {
        guard !Task.isCancelled, let source = currentInitialSource else { return }
        guard initialRequest?.source != source || initialWork?.isCancelled == true else { return }
        initialWork?.cancel()
        initialSequence &+= 1
        let request = InitialRequest(source: source, sequence: initialSequence)
        initialRequest = request
        isLoadingSessions = true
        sessionLoadError = nil
        let work = Task { await performInitialRequest(request) }
        initialWork = work
        defer {
            if initialRequest == request {
                isLoadingSessions = false
                initialRequest = nil
                initialWork = nil
            }
        }

        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func retrySessions() async {
        guard !Task.isCancelled, sessionLoadError != nil else { return }
        initialWork?.cancel()
        await loadInitial()
    }

    private func performInitialRequest(_ request: InitialRequest) async {
        async let unreadFetch: Void = loadUnread(for: request)
        async let sessionsFetch: Void = loadSessions(for: request)
        _ = await (unreadFetch, sessionsFetch)
    }

    private var currentInitialSource: InitialSource? {
        guard AuthManager.shared.isLoggedIn else { return nil }
        return InitialSource(
            sessionGeneration: AuthManager.shared.sessionGeneration,
            accountRevision: AccountManager.shared.identityRevision,
            accountMID: AuthManager.shared.dedeUserID
        )
    }

    private func isCurrentInitialRequest(_ request: InitialRequest) -> Bool {
        !Task.isCancelled && initialRequest == request && currentInitialSource == request.source
    }

    private func loadUnread(for request: InitialRequest) async {
        guard isCurrentInitialRequest(request) else { return }
        do {
            let result = try await MessageAPI.getUnreadCount()
            guard isCurrentInitialRequest(request) else { return }
            unread = result
            PlayerLog.log(
                "[MsgVM] unread: reply=\(result.reply ?? 0), at=\(result.at ?? 0), "
                    + "like=\(result.like ?? 0), sys=\(result.sysMsg ?? 0)"
            )
        } catch {
            guard isCurrentInitialRequest(request), !error.isCancellation else { return }
            PlayerLog.log("[MsgVM] unread failed: \(error)")
        }
    }

    private func loadSessions(for request: InitialRequest) async {
        guard isCurrentInitialRequest(request) else { return }
        do {
            let result = try await MessageAPI.getSessionList()
            guard isCurrentInitialRequest(request) else { return }
            let fetchedSessions = result.sessionList ?? []
            sessions = fetchedSessions
            sessionsLoaded = true
            isLoadingSessions = false
            if PlayerLog.isCapturing {
                let details = fetchedSessions.map { session in
                    "\(session.talkerId) type=\(session.sessionType ?? -1) "
                        + "sys=\(session.systemMsgType ?? 0) unread=\(session.unreadCount ?? 0)"
                }
                PlayerLog.log("[MsgVM] sessions: \(fetchedSessions.count) — \(details)")
            }
            await loadSessionUsers(for: fetchedSessions, request: request)
        } catch {
            guard isCurrentInitialRequest(request), !error.isCancellation else { return }
            sessionLoadError = error.localizedDescription
            isLoadingSessions = false
            PlayerLog.log("[MsgVM] sessions failed: \(error)")
        }
    }

    private func loadSessionUsers(
        for sessions: [SessionListResult.SessionItem],
        request: InitialRequest
    ) async {
        guard isCurrentInitialRequest(request) else { return }
        let uids = sessions
            .filter { ($0.sessionType ?? 1) == 1 && $0.talkerId < (1 << 40) }
            .map(\.talkerId)
        guard !uids.isEmpty else { return }

        do {
            let infos = try await MessageAPI.getSessionUserInfos(uids: uids)
            guard isCurrentInitialRequest(request) else { return }
            sessionUsers = Dictionary(uniqueKeysWithValues: infos.map { ($0.mid, $0) })
            if PlayerLog.isCapturing {
                let details = infos.prefix(3).map { info in
                    "\(info.mid):\(info.name ?? "?") face=\(info.face != nil)"
                }
                PlayerLog.log("[MsgVM] session users resolved: \(infos.count)/\(uids.count) — \(details)")
            }
        } catch {
            guard isCurrentInitialRequest(request), !error.isCancellation else { return }
            PlayerLog.log("[MsgVM] session user infos failed: \(error)")
        }
    }

    struct PageFailure: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    struct PageSnapshot<Item: Identifiable> {
        let items: [Item]
        let isLoading: Bool
        let isRefreshing: Bool
        let attempted: Bool
        let loaded: Bool
        let hasMore: Bool
        let failure: PageFailure?
    }

    private enum PageKind: Hashable { case reply, mention, like, system }
    private struct PageCursor: Equatable {
        let id: Int
        let time: Int
    }
    private struct PageRequest: Equatable {
        let id = UUID()
        let kind: PageKind
        let source: InitialSource
        let cursor: PageCursor
        let isRefresh: Bool
    }

    private var pageRequests: [PageKind: PageRequest] = [:]
    private var pageFailures: [PageKind: PageFailure] = [:]
    @ObservationIgnored private var pageSources: [PageKind: InitialSource] = [:]
    @ObservationIgnored private var failedPageRequests: [PageKind: PageRequest] = [:]
    @ObservationIgnored private var pageWork: [PageKind: Task<Void, Never>] = [:]
    private var endedPages: Set<PageKind> = []

    var canLoadMoreReplies: Bool { repliesLoaded && !endedPages.contains(.reply) }
    var canLoadMoreAt: Bool { atLoaded && !endedPages.contains(.mention) }
    var canLoadMoreLikes: Bool { likesLoaded && !endedPages.contains(.like) }
    var canLoadMoreSystem: Bool { systemLoaded && !endedPages.contains(.system) }

    var replyFailure: PageFailure? { pageFailures[.reply] }
    var atFailure: PageFailure? { pageFailures[.mention] }
    var likeFailure: PageFailure? { pageFailures[.like] }
    var systemFailure: PageFailure? { pageFailures[.system] }

    var replyPage: PageSnapshot<ReplyMessageResult.ReplyMsgItem> {
        PageSnapshot(
            items: replyItems, isLoading: isLoadingReplies,
            isRefreshing: pageRequests[.reply]?.isRefresh == true,
            attempted: repliesAttempted, loaded: repliesLoaded,
            hasMore: canLoadMoreReplies, failure: replyFailure
        )
    }
    var atPage: PageSnapshot<AtMessageResult.AtMsgItem> {
        PageSnapshot(
            items: atItems, isLoading: isLoadingAt,
            isRefreshing: pageRequests[.mention]?.isRefresh == true,
            attempted: atAttempted, loaded: atLoaded,
            hasMore: canLoadMoreAt, failure: atFailure
        )
    }
    var likePage: PageSnapshot<LikeMessageResult.LikeMsgItem> {
        PageSnapshot(
            items: likeItems, isLoading: isLoadingLikes,
            isRefreshing: pageRequests[.like]?.isRefresh == true,
            attempted: likesAttempted, loaded: likesLoaded,
            hasMore: canLoadMoreLikes, failure: likeFailure
        )
    }
    var systemPage: PageSnapshot<SystemNotifyResult.SystemNotifyItem> {
        PageSnapshot(
            items: systemItems, isLoading: isLoadingSystem,
            isRefreshing: pageRequests[.system]?.isRefresh == true,
            attempted: systemAttempted, loaded: systemLoaded,
            hasMore: canLoadMoreSystem, failure: systemFailure
        )
    }
}

extension MessageCenterViewModel {
    func loadReplies() async {
        if !repliesLoaded || pageSources[.reply] != currentInitialSource { await loadMoreReplies() }
    }
    func loadAt() async {
        if !atLoaded || pageSources[.mention] != currentInitialSource { await loadMoreAt() }
    }
    func loadLikes() async {
        if !likesLoaded || pageSources[.like] != currentInitialSource { await loadMoreLikes() }
    }
    func loadSystem() async {
        if !systemLoaded || pageSources[.system] != currentInitialSource { await loadMoreSystem() }
    }
    func loadMoreReplies() async { await loadPage(.reply) }
    func loadMoreAt() async { await loadPage(.mention) }
    func loadMoreLikes() async { await loadPage(.like) }
    func loadMoreSystem() async { await loadPage(.system) }
    func refreshReplies() async { await refreshPage(.reply) }
    func refreshAt() async { await refreshPage(.mention) }
    func refreshLikes() async { await refreshPage(.like) }
    func refreshSystem() async { await refreshPage(.system) }
    func retryReplies(_ failure: PageFailure) async { await loadPage(.reply, retrying: failure) }
    func retryAt(_ failure: PageFailure) async { await loadPage(.mention, retrying: failure) }
    func retryLikes(_ failure: PageFailure) async { await loadPage(.like, retrying: failure) }
    func retrySystem(_ failure: PageFailure) async { await loadPage(.system, retrying: failure) }

    private func cursor(for kind: PageKind) -> PageCursor {
        switch kind {
        case .reply: PageCursor(id: replyCursor?.id ?? 0, time: replyCursor?.time ?? 0)
        case .mention: PageCursor(id: atCursor?.id ?? 0, time: atCursor?.time ?? 0)
        case .like: PageCursor(id: likeCursor?.id ?? 0, time: likeCursor?.time ?? 0)
        case .system: PageCursor(id: systemCursorId ?? 0, time: 0)
        }
    }

    private func refreshPage(_ kind: PageKind) async {
        guard !Task.isCancelled, let source = currentInitialSource else { return }
        if pageSources[kind] != source {
            resetPages(kind, source: source)
        } else {
            pageWork[kind]?.cancel()
            pageWork[kind] = nil
            pageRequests[kind] = nil
        }
        let request = PageRequest(
            kind: kind, source: source, cursor: PageCursor(id: 0, time: 0), isRefresh: true
        )
        await startPageRequest(request)
    }

    private func loadPage(_ kind: PageKind, retrying failure: PageFailure? = nil) async {
        guard !Task.isCancelled, let source = currentInitialSource else { return }
        if let failure {
            guard pageFailures[kind] == failure, let failed = failedPageRequests[kind],
                  failed.source == source else { return }
            if failed.isRefresh {
                await refreshPage(kind)
                return
            }
            guard failed.cursor == cursor(for: kind) else { return }
        } else if pageSources[kind] == source, pageFailures[kind] != nil {
            return
        }
        if pageSources[kind] != source { resetPages(kind, source: source) }
        guard !endedPages.contains(kind),
              pageRequests[kind] == nil || pageWork[kind]?.isCancelled == true else { return }
        let request = PageRequest(
            kind: kind, source: source, cursor: cursor(for: kind), isRefresh: false
        )
        await startPageRequest(request)
    }

    private func startPageRequest(_ request: PageRequest) async {
        let kind = request.kind
        pageRequests[kind] = request
        pageFailures[kind] = nil
        failedPageRequests[kind] = nil
        setLoading(true, kind: kind)
        setError(nil, kind: kind)
        let work = Task {
            defer {
                if pageRequests[kind] == request {
                    pageRequests[kind] = nil
                    pageWork[kind] = nil
                    setLoading(false, kind: kind)
                }
            }
            await performPage(request)
        }
        pageWork[kind] = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }

    private func isCurrentPage(_ request: PageRequest) -> Bool {
        !Task.isCancelled && pageRequests[request.kind] == request && currentInitialSource == request.source
    }

    private func resetPages(_ kind: PageKind, source: InitialSource) {
        pageWork[kind]?.cancel()
        pageWork[kind] = nil
        pageRequests[kind] = nil
        pageFailures[kind] = nil
        failedPageRequests[kind] = nil
        endedPages.remove(kind)
        pageSources[kind] = source
        setError(nil, kind: kind)
        switch kind {
        case .reply:
            replyItems = []
            replyCursor = nil
            repliesLoaded = false
            repliesAttempted = false
        case .mention:
            atItems = []
            atCursor = nil
            atLoaded = false
            atAttempted = false
        case .like:
            likeItems = []
            likeCursor = nil
            likesLoaded = false
            likesAttempted = false
        case .system:
            systemItems = []
            systemCursorId = nil
            systemLoaded = false
            systemAttempted = false
        }
    }

    private func setLoading(_ value: Bool, kind: PageKind) {
        switch kind {
        case .reply:
            isLoadingReplies = value
            if value { repliesAttempted = true }
        case .mention:
            isLoadingAt = value
            if value { atAttempted = true }
        case .like:
            isLoadingLikes = value
            if value { likesAttempted = true }
        case .system:
            isLoadingSystem = value
            if value { systemAttempted = true }
        }
    }

    private func setError(_ error: String?, kind: PageKind) {
        switch kind {
        case .reply: replyLoadError = error
        case .mention: atLoadError = error
        case .like: likeLoadError = error
        case .system: systemLoadError = error
        }
    }

    private func acceptCursor(_ cursor: ReplyMessageResult.MsgCursor?, for request: PageRequest) {
        let next = PageCursor(id: cursor?.id ?? 0, time: cursor?.time ?? 0)
        if cursor?.isEnd != false || next == request.cursor { endedPages.insert(request.kind) }
    }

    private func mergePage<Item: Identifiable>(
        _ incoming: [Item],
        into current: inout [Item],
        cursor: ReplyMessageResult.MsgCursor?,
        for request: PageRequest
    ) {
        if request.isRefresh { endedPages.remove(request.kind) }
        current = appendingMessages(incoming, to: request.isRefresh ? [] : current)
        acceptCursor(cursor, for: request)
    }

    private func performPage(_ request: PageRequest) async {
        guard isCurrentPage(request) else { return }
        do {
            switch request.kind {
            case .reply:
                let result = try await MessageAPI.getReplyMessages(
                    id: request.cursor.id, replyTime: request.cursor.time
                )
                guard isCurrentPage(request) else { return }
                mergePage(result.items ?? [], into: &replyItems, cursor: result.cursor, for: request)
                replyCursor = result.cursor
                repliesLoaded = true
            case .mention:
                let result = try await MessageAPI.getAtMessages(
                    id: request.cursor.id, atTime: request.cursor.time
                )
                guard isCurrentPage(request) else { return }
                mergePage(result.items ?? [], into: &atItems, cursor: result.cursor, for: request)
                atCursor = result.cursor
                atLoaded = true
            case .like:
                let result = try await MessageAPI.getLikeMessages(
                    id: request.cursor.id, likeTime: request.cursor.time
                )
                guard isCurrentPage(request) else { return }
                let incoming = result.total?.items ?? result.latest?.items ?? []
                mergePage(incoming, into: &likeItems, cursor: result.total?.cursor, for: request)
                likeCursor = result.total?.cursor
                likesLoaded = true
            case .system:
                let result = try await MessageAPI.getSystemNotifications(cursor: request.cursor.id)
                acceptSystemPage(result, for: request)
            }
        } catch {
            recordPageFailure(error, for: request)
        }
    }

    private func acceptSystemPage(_ result: SystemNotifyResult, for request: PageRequest) {
        guard isCurrentPage(request) else { return }
        if request.isRefresh { endedPages.remove(.system) }
        let items = result.systemNotifyList ?? []
        systemItems = appendingMessages(items, to: request.isRefresh ? [] : systemItems)
        if let next = items.last?.cursor, next > 0, next != request.cursor.id {
            systemCursorId = next
        } else {
            if request.isRefresh { systemCursorId = nil }
            endedPages.insert(.system)
        }
        systemLoaded = true
    }

    private func recordPageFailure(_ error: BiliError, for request: PageRequest) {
        guard isCurrentPage(request), !error.isCancellation else { return }
        if request.kind == .system, !request.isRefresh, request.cursor.id > 0, !systemItems.isEmpty,
           case .apiError(let code, _) = error, code == -6 {
            endedPages.insert(.system)
            PlayerLog.log("[MsgVM] system cursor \(request.cursor.id) rejected (-6); marking ended")
            return
        }
        let failure = PageFailure(message: error.localizedDescription)
        pageFailures[request.kind] = failure
        failedPageRequests[request.kind] = request
        setError(failure.message, kind: request.kind)
        PlayerLog.log("[MsgVM] page failed: \(error)")
    }

    private func appendingMessages<Item: Identifiable>(_ incoming: [Item], to current: [Item]) -> [Item] {
        var seen = Set(current.map(\.id))
        return current + incoming.filter { seen.insert($0.id).inserted }
    }
}
