import Foundation
import Observation

struct ChatAccountSource: Hashable, Sendable {
    let session: UUID
    let revision: UInt64
    let mid: String?
    let isLoggedIn: Bool

    @MainActor
    static func current(
        authManager: AuthManager = .shared,
        accountManager: AccountManager = .shared
    ) -> Self {
        Self(
            session: authManager.sessionGeneration,
            revision: accountManager.identityRevision,
            mid: authManager.dedeUserID,
            isLoggedIn: authManager.isLoggedIn
        )
    }
}

@MainActor
@Observable
final class ChatViewModel {
    let talkerId: Int
    private let source: ChatAccountSource
    @ObservationIgnored private let authManager: AuthManager
    @ObservationIgnored private let accountManager: AccountManager

    private(set) var messages: [SessionMsgsResult.ChatMessage] = []
    private(set) var scrollTargetID: Int?
    private(set) var hasMore = false
    private(set) var loadedOnce = false
    private(set) var initialAttempted = false
    private(set) var initialFailure: String?
    private(set) var historyFailure: String?

    private var minSeqno: Int?
    private var latestSeqno: Int?
    private var acknowledgedSeqno: Int?
    private var runID: UUID?
    private var read: Read?
    @ObservationIgnored private var readWork: Task<Void, Never>?
    @ObservationIgnored private var catchUp: CatchUp?
    @ObservationIgnored private var failedKind: ReadKind?

    private enum ReadKind: Equatable { case initial, older, latest }
    private struct Read: Equatable {
        let id: UUID
        let run: UUID
        let kind: ReadKind
        let olderBoundary: Int?
    }
    private struct CatchUp {
        let boundary: Int?
        let knownIDs: Set<Int>
        var newestFirst: [SessionMsgsResult.ChatMessage] = []
        var nextEndSeqno: Int?
    }

    init(
        talkerId: Int,
        source: ChatAccountSource? = nil,
        authManager: AuthManager = .shared,
        accountManager: AccountManager = .shared
    ) {
        self.talkerId = talkerId
        self.source = source ?? ChatAccountSource.current(
            authManager: authManager,
            accountManager: accountManager
        )
        self.authManager = authManager
        self.accountManager = accountManager
    }

    var myUID: Int? { source.mid.flatMap(Int.init) }
    var isAuthenticated: Bool {
        source.isLoggedIn && source == ChatAccountSource.current(
            authManager: authManager,
            accountManager: accountManager
        )
    }
    var isReading: Bool { read != nil }
    var isLoadingOlder: Bool { read?.kind == .older }

    func runWhileVisible() async {
        guard !Task.isCancelled, isAuthenticated else { return }
        let run = UUID()
        readWork?.cancel()
        read = nil
        readWork = nil
        runID = run
        defer {
            if runID == run { stopVisibleRun() }
        }
        await awaitRead(beginRead(loadedOnce ? .latest : .initial))
        while isActive(run) {
            do {
                try await Task.sleep(for: historyFailure == nil ? .seconds(5) : .seconds(15))
            } catch { return }
            guard isActive(run) else { return }
            if loadedOnce { await awaitRead(beginRead(.latest)) }
        }
    }

    func stopVisibleRun() {
        runID = nil
        readWork?.cancel()
        read = nil
        readWork = nil
    }

    func retryInitial() { _ = beginRead(.initial) }
    func loadOlder() { _ = beginRead(.older) }
    func retryHistory() {
        guard let failedKind else { return }
        _ = beginRead(failedKind)
    }

    private func beginRead(_ kind: ReadKind) -> Task<Void, Never>? {
        guard let run = runID, isActive(run), read == nil || readWork?.isCancelled == true else { return nil }
        guard kind != .initial || !loadedOnce else { return nil }
        guard kind != .older || (hasMore && minSeqno != nil) else { return nil }
        let request = Read(id: UUID(), run: run, kind: kind, olderBoundary: minSeqno)
        read = request
        if kind == .initial {
            initialAttempted = true
            initialFailure = nil
        } else {
            historyFailure = nil
            failedKind = nil
        }
        let work = Task {
            defer {
                if read == request {
                    read = nil
                    readWork = nil
                }
            }
            await perform(request)
        }
        readWork = work
        return work
    }

    private func awaitRead(_ work: Task<Void, Never>?) async {
        guard let work else { return }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }

    private func isActive(_ run: UUID) -> Bool {
        !Task.isCancelled && runID == run && isAuthenticated
    }

    private func isCurrent(_ request: Read) -> Bool {
        read == request && isActive(request.run)
    }

    private func perform(_ request: Read) async {
        guard isCurrent(request) else { return }
        do {
            switch request.kind {
            case .initial, .older:
                let result = try await MessageAPI.getSessionMessages(
                    talkerId: talkerId,
                    endSeqno: request.kind == .older ? request.olderBoundary : nil
                )
                guard isCurrent(request) else { return }
                let incoming = try validMessages(result)
                messages = mergingChatHistory(
                    uniqueChatMessages(Array(incoming.reversed())), retaining: messages,
                    preservingCurrentPayload: request.kind == .older,
                    olderBoundary: request.kind == .older ? request.olderBoundary : nil
                )
                minSeqno = result.minSeqno
                hasMore = result.hasMore == 1 && result.minSeqno != nil
                    && (request.kind == .initial || result.minSeqno != request.olderBoundary)
                if request.kind == .initial {
                    latestSeqno = incoming.compactMap(\.msgSeqno).max()
                    loadedOnce = true
                    scrollTargetID = messages.last?.id
                    await acknowledgeLatest(request)
                }
            case .latest:
                try await fetchLatest(request)
            }
        } catch {
            guard isCurrent(request), !(error is CancellationError),
                  (error as? BiliError)?.isCancellation != true else { return }
            if request.kind == .initial {
                initialFailure = error.localizedDescription
            } else {
                historyFailure = error.localizedDescription
                failedKind = request.kind
            }
            PlayerLog.log("[Chat] history failed talker=\(talkerId): \(error)")
        }
    }

    private func validMessages(_ result: SessionMsgsResult) throws -> [SessionMsgsResult.ChatMessage] {
        if let messages = result.messages { return messages }
        if result.hasMore == 0 { return [] }
        throw BiliError.decodingFailed(DecodingError.dataCorrupted(.init(
            codingPath: [], debugDescription: "Missing private-message history payload"
        )))
    }

    private func fetchLatest(_ request: Read) async throws {
        var pending = catchUp ?? CatchUp(
            boundary: latestSeqno,
            knownIDs: Set(messages.filter { $0.msgKey != nil || $0.msgSeqno != nil }.map(\.id))
        )
        for _ in 0 ..< 4 {
            guard isCurrent(request) else { return }
            let result = try await MessageAPI.getSessionMessages(
                talkerId: talkerId, endSeqno: pending.nextEndSeqno
            )
            guard isCurrent(request) else { return }
            let incoming = try validMessages(result)
            pending.newestFirst.append(contentsOf: incoming)
            let reachedBoundary = incoming.contains { message in
                if let boundary = pending.boundary, let sequence = message.msgSeqno {
                    return sequence <= boundary
                }
                return (message.msgKey != nil || message.msgSeqno != nil) && pending.knownIDs.contains(message.id)
            }
            if reachedBoundary || result.hasMore == 0 {
                let newestFirst = uniqueChatMessages(pending.newestFirst)
                messages = mergingChatHistory(
                    Array(newestFirst.reversed()), retaining: messages, preservingCurrentPayload: false
                )
                latestSeqno = max(latestSeqno ?? 0, newestFirst.compactMap(\.msgSeqno).max() ?? 0)
                catchUp = nil
                await acknowledgeLatest(request)
                return
            }
            guard !incoming.isEmpty, let next = result.minSeqno,
                  next != pending.nextEndSeqno else {
                throw BiliError.decodingFailed(DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "Private-message history cursor did not advance"
                )))
            }
            pending.nextEndSeqno = next
            catchUp = pending
        }
    }

    private func acknowledgeLatest(_ request: Read) async {
        guard isCurrent(request), let latestSeqno, latestSeqno > (acknowledgedSeqno ?? 0) else { return }
        do {
            try await MessageAPI.markSessionRead(talkerId: talkerId, ackSeqno: latestSeqno)
            guard isCurrent(request) else { return }
            acknowledgedSeqno = latestSeqno
        } catch {
            guard isCurrent(request), !error.isCancellation else { return }
            PlayerLog.log("[Chat] mark read failed: \(error)")
        }
    }

    func sendMessage(_ text: String) async throws {
        guard let run = runID, isActive(run) else { throw CancellationError() }
        let result = try await MessageAPI.sendMessage(receiverId: talkerId, content: text)
        guard isActive(run) else { return }
        let json = (try? JSONSerialization.data(withJSONObject: ["content": text]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let message = SessionMsgsResult.ChatMessage(
            senderUid: myUID, receiverId: talkerId, msgType: 1, content: json ?? text,
            msgSeqno: nil, timestamp: Int(Date().timeIntervalSince1970),
            msgKey: result.msgKey ?? Int(Date().timeIntervalSince1970 * 1000), msgStatus: 0
        )
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
            scrollTargetID = message.id
        }
    }
}

private func uniqueChatMessages(_ messages: [SessionMsgsResult.ChatMessage]) -> [SessionMsgsResult.ChatMessage] {
    var seen = Set<Int>()
    return messages.filter { message in
        (message.msgKey == nil && message.msgSeqno == nil) || seen.insert(message.id).inserted
    }
}

private func mergingChatHistory(
    _ fetched: [SessionMsgsResult.ChatMessage],
    retaining current: [SessionMsgsResult.ChatMessage],
    preservingCurrentPayload: Bool,
    olderBoundary: Int? = nil
) -> [SessionMsgsResult.ChatMessage] {
    let fetchedIDs = Set(fetched.map(\.id))
    var prefixes: [Int: [Int]] = [:]
    var commonRows: [Int: [SessionMsgsResult.ChatMessage]] = [:]
    var pending: [Int] = []
    var prefixedIndices = Set<Int>()
    for (index, message) in current.enumerated() {
        if fetchedIDs.contains(message.id) {
            if !pending.isEmpty {
                prefixes[message.id, default: []].append(contentsOf: pending)
                prefixedIndices.formUnion(pending)
                pending.removeAll(keepingCapacity: true)
            }
            if preservingCurrentPayload {
                commonRows[message.id, default: []].append(message)
            }
        } else {
            if let olderBoundary, let sequence = message.msgSeqno, sequence >= olderBoundary { continue }
            pending.append(index)
        }
    }

    var merged: [SessionMsgsResult.ChatMessage] = []
    var emittedCommonIDs = Set<Int>()
    merged.reserveCapacity(fetched.count + current.count)
    for message in fetched {
        if let prefix = prefixes.removeValue(forKey: message.id) {
            merged.append(contentsOf: prefix.map { current[$0] })
        }
        if let retained = commonRows[message.id] {
            if emittedCommonIDs.insert(message.id).inserted {
                merged.append(contentsOf: retained)
            }
        } else {
            merged.append(message)
        }
    }
    for (index, message) in current.enumerated()
        where !fetchedIDs.contains(message.id) && !prefixedIndices.contains(index) {
        merged.append(message)
    }
    return merged
}
