import SwiftUI

/// Private-message conversation: history bubbles + composer.
struct ChatView: View {
    let talkerId: Int
    let name: String
    let face: String?

    var body: some View {
        let source = ChatAccountSource.current
        ChatConversationView(talkerId: talkerId, name: name, face: face, source: source)
            .id(talkerId)
            .id(source)
    }
}

private struct ChatAccountSource: Hashable {
    let session: UUID
    let revision: UInt64
    let mid: String?
    let isLoggedIn: Bool

    @MainActor static var current: Self {
        Self(
            session: AuthManager.shared.sessionGeneration,
            revision: AccountManager.shared.identityRevision,
            mid: AuthManager.shared.dedeUserID,
            isLoggedIn: AuthManager.shared.isLoggedIn
        )
    }
}

private struct ChatConversationView: View {
    @AppMotion private var motion
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatConversationModel
    let name: String
    let face: String?

    init(talkerId: Int, name: String, face: String?, source: ChatAccountSource) {
        self.name = name
        self.face = face
        _model = State(initialValue: ChatConversationModel(talkerId: talkerId, source: source))
    }

    private var bubbleMaxWidth: CGFloat { sizeClass == .regular ? 420 : 260 }

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if !model.messages.isEmpty {
                            historyFeedback
                        }
                        if model.hasMore {
                            Button(action: model.loadOlder) {
                                if model.isLoadingOlder {
                                    ProgressView()
                                } else {
                                    Text("Load earlier messages")
                                        .appFont(.messageMeta)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44)
                            .disabled(model.isReading)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, msg in
                            ChatMessageRow(
                                message: msg,
                                previous: index > 0 ? model.messages[index - 1] : nil,
                                talkerID: model.talkerId, face: face, myUID: model.myUID,
                                bubbleMaxWidth: bubbleMaxWidth
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: ReadableWidth.feed)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTargetID) { _, targetID in
                    // New incoming pages and older history preserve the reading position.
                    if let targetID {
                        withAnimation(motion.animation(normal: .easeOut(duration: 0.2))) {
                            proxy.scrollTo(targetID, anchor: .bottom)
                        }
                    }
                }
            }
            .overlay {
                if !model.isAuthenticated {
                    ContentUnavailableView(
                        "Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if model.messages.isEmpty {
                    if model.loadedOnce && model.historyFailure == nil {
                        ContentUnavailableView(
                            "No messages yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Say hi to start the conversation.")
                        )
                    } else {
                        historyFeedback
                    }
                }
            }
        }
        // The composer's height varies (multi-line draft, send-error row, Dynamic Type),
        // so it is a bottom safe-area inset: the scroll view's inset tracks its real
        // height and the keyboard together, and messages still scroll beneath the glass.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposerView(sendMessage: model.sendMessage)
                .disabled(!model.isAuthenticated)
        }
        .appAmbientBrowseBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.navigate(to: .userSpace(model.talkerId))
                } label: {
                    ChatAvatarView(face: face, size: 30)
                }
                .accessibilityLabel(Text(String(format: String(localized: "Open %@'s profile"), name)))
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.runWhileVisible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.stopVisibleRun() }
        }
        .onDisappear { model.stopVisibleRun() }
    }

    @ViewBuilder private var historyFeedback: some View {
        if !model.loadedOnce {
            if model.isReading || !model.initialAttempted {
                ProgressView()
            } else {
                MessageLoadFailureView(message: model.initialFailure, retry: model.retryInitial)
            }
        } else if let failure = model.historyFailure {
            MessageLoadFailureView(message: failure, retry: model.retryHistory)
        }
    }
}

@MainActor
@Observable
private final class ChatConversationModel {
    let talkerId: Int
    private let source: ChatAccountSource
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

    init(talkerId: Int, source: ChatAccountSource) {
        self.talkerId = talkerId
        self.source = source
    }

    var myUID: Int? { source.mid.flatMap(Int.init) }
    var isAuthenticated: Bool { source.isLoggedIn && source == .current }
    var isReading: Bool { read != nil }
    var isLoadingOlder: Bool { read?.kind == .older }

    /// One active-view loop, at most one GET owner and four catch-up pages per pass.
    /// The interval is an application policy, not a server push guarantee.
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

    /// Revoke publication immediately; transport cancellation may settle later.
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
            // Persist progress only after a complete page. Failure retries this boundary.
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
            // Retry the acknowledgement on a later successful foreground refresh.
            PlayerLog.log("[Chat] mark read failed: \(error)")
        }
    }

    func sendMessage(_ text: String) async throws {
        guard let run = runID, isActive(run) else { throw CancellationError() }
        let result = try await MessageAPI.sendMessage(receiverId: talkerId, content: text)
        // Accepted transport success belongs to the original composer attempt.
        // Retired visibility forbids publication, not successful-send settlement.
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

/// Only actual wire identities can prove overlap; missing-ID messages remain distinct.
private func uniqueChatMessages(_ messages: [SessionMsgsResult.ChatMessage]) -> [SessionMsgsResult.ChatMessage] {
    var seen = Set<Int>()
    return messages.filter { message in
        (message.msgKey == nil && message.msgSeqno == nil) || seen.insert(message.id).inserted
    }
}

/// Preserve fetched order, using shared IDs to anchor retained runs without
/// inferring timestamps. Older pages keep current payloads at shared anchors,
/// but known rows at or after the request boundary cannot precede older anchors.
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
            // Repeated common wire IDs must not copy retained occurrences again.
            if emittedCommonIDs.insert(message.id).inserted {
                merged.append(contentsOf: retained)
            }
        } else {
            merged.append(message)
        }
    }
    // Keep known newer rows and unanchored local rows in one original-order tail.
    for (index, message) in current.enumerated()
        where !fetchedIDs.contains(message.id) && !prefixedIndices.contains(index) {
        merged.append(message)
    }
    return merged
}
