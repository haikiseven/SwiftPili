import Foundation
import Observation

/// Per-thread business state. Context is captured by each launching View value.
@MainActor
@Observable
final class CommentThreadStore {
    struct Context: Sendable {
        let oid: Int
        let root: CommentResult.CommentItem
        let type: Int

        fileprivate var source: Source { Source(oid: oid, type: type, rootID: root.rpid) }
    }

    struct Source: Equatable, Sendable {
        let oid: Int
        let type: Int
        let rootID: Int
    }

    struct ListReceipt: Equatable, Sendable {
        fileprivate let source: Source
        fileprivate let lineage: UUID
    }

    struct PreparedPage: Sendable {
        fileprivate let context: Context
        fileprivate let page: Int
        fileprivate let token: FeedLoadToken
        fileprivate let replacing: Bool
        fileprivate let list: ListReceipt?
    }

    struct ReplyRequest: Sendable {
        let context: Context
        let message: String
        let parent: Int
        let pictures: [ComposedPicture]
    }

    typealias GetReplies = @MainActor (Context, Int) async throws(BiliError) -> CommentResult
    typealias Post = @MainActor (ReplyRequest) async throws(BiliError) -> PostCommentResult

    struct Requests {
        let getReplies: GetReplies
        let post: Post

        init(
            getReplies: @escaping GetReplies = { (context, page) async throws(BiliError) in
                try await CommentAPI.getReplies(
                    oid: context.oid, rootID: context.root.rpid, type: context.type, pn: page
                )
            },
            post: @escaping Post = { (request) async throws(BiliError) in
                try await CommentAPI.postComment(
                    oid: request.context.oid,
                    message: request.message,
                    type: request.context.type,
                    root: request.context.root.rpid,
                    parent: request.parent,
                    pictures: request.pictures
                )
            }
        ) {
            self.getReplies = getReplies
            self.post = post
        }
    }

    private(set) var replies: [CommentResult.CommentItem] = []
    /// Server total is used by highlight search only; the header keeps root.rcount.
    private(set) var totalReplies: Int?
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var hasMore = true
    @ObservationIgnored private var openedSource: Source?
    @ObservationIgnored private var admission = FeedLoadAdmission()
    @ObservationIgnored private var loadingToken: FeedLoadToken?
    @ObservationIgnored private var failedRequest: PreparedPage?
    private(set) var loadingKind: FeedLoadKind?
    private(set) var listReceipt: ListReceipt?
    private(set) var loadFeedback = CommentLoadFeedback()
    private(set) var commentsClosed = false
    var isLoading: Bool { loadingKind != nil }
    /// Replacement admission retires a locator before the new list is published.
    var requestGeneration: UInt64 { admission.generation }
    private var draftText = ""
    var commentText: String {
        get { draftText }
        set {
            submission.draftDidChange()
            sendError = nil
            draftText = newValue
        }
    }
    private var draftPictures: [ComposedPicture] = []
    var commentPictures: [ComposedPicture] {
        get { draftPictures }
        set {
            if newValue != draftPictures {
                submission.draftDidChange()
                sendError = nil
            }
            draftPictures = newValue
        }
    }
    private var submission = CommentComposerSubmission()
    let commentUpload = CommentComposerUploadOwner()
    private let composerID = UUID()
    private var replacementEpoch: UInt64 = 0
    private let composerSessionGeneration = AuthManager.shared.sessionGeneration
    var isSending: Bool { submission.isSending }
    private(set) var sendError: String?
    private(set) var replyTarget: CommentResult.CommentItem?
    private(set) var postedCount = 0
    @ObservationIgnored private let requests: Requests

    init(requests: Requests = Requests()) {
        self.requests = requests
    }

    func beginReply(to target: CommentResult.CommentItem?, in context: Context) {
        guard bindOpenedSource(context) else { return }
        setReplyTarget(target, in: context)
        // nil is meaningful here: it means "reply to the root", which is this
        // screen's default rather than an absence of reply mode.
        PlayerLog.log(
            "[CommentThread] reply target \(target == nil ? "→ root" : "set") "
            + "rpid=\(target?.rpid ?? context.root.rpid) root=\(context.root.rpid)"
        )
    }

    func cancelReply(in context: Context) {
        guard bindOpenedSource(context) else { return }
        setReplyTarget(nil, in: context)
    }

    private func setReplyTarget(_ target: CommentResult.CommentItem?, in context: Context) {
        let previousParent = replyTarget?.rpid ?? context.root.rpid
        let nextParent = target?.rpid ?? context.root.rpid
        if previousParent != nextParent {
            submission.draftDidChange()
            sendError = nil
        }
        replyTarget = target
    }

    func removeReply(rpid: Int) {
        replies.removeAll { $0.rpid == rpid }
    }

    /// What one page request did, plus enough identity to tell a genuinely
    /// repeated response from a fresh one.
    enum PageLoad: Equatable {
        case advanced(signature: String)
        /// The response carried nothing this list did not already have.
        case stalled(signature: String)
        /// A load was already in flight; this call did nothing at all.
        case skipped
        case failed
        case superseded
        case cancelled
        case closed

        var signature: String? {
            switch self {
            case .advanced(let value), .stalled(let value): value
            case .skipped, .failed, .superseded, .cancelled, .closed: nil
            }
        }
    }

    /// Identity of one page response: what was asked for, what came back, and
    /// where that leaves the list.
    ///
    /// The fold is over the RETURNED ids, not the deduped ones — the question is
    /// what the server sent, not what survived our filter. The signature also
    /// includes requestedPage, so identical payloads requested on different
    /// pages do not match; this does not detect that server-side loop.
    private static func pageSignature(
        requestedPage: Int,
        returned: [CommentResult.CommentItem],
        loaded: Int,
        total: Int?
    ) -> String {
        var fold: UInt64 = 1
        for item in returned {
            fold = fold &* 31 &+ UInt64(bitPattern: Int64(item.rpid))
        }
        let totalText = total.map(String.init) ?? "?"
        return "pn=\(requestedPage) got=\(returned.count) "
            + "ids=\(String(fold, radix: 16)) loaded=\(loaded)/\(totalText)"
    }

    @discardableResult
    func loadMore(in context: Context) async -> PageLoad {
        guard !Task.isCancelled else { return .cancelled }
        guard !commentsClosed else { return .closed }
        guard let request = prepareMore(in: context, from: listReceipt) else { return .skipped }
        return await perform(request)
    }

    func prepareMore(in context: Context, from list: ListReceipt?) -> PreparedPage? {
        guard !Task.isCancelled, bindOpenedSource(context), loadingToken == nil,
              !commentsClosed, hasMore, list == listReceipt else { return nil }
        let kind: FeedLoadKind = loadFeedback.hasLoaded ? .pagination : .initial
        guard let token = admission.admit(kind: kind, cursor: "page:\(page)") else { return nil }
        return prepare(context, page: page, token: token, replacing: false, list: list)
    }

    func prepareRefresh(in context: Context) -> PreparedPage? {
        guard !Task.isCancelled, bindOpenedSource(context) else { return nil }
        hasMore = true
        let token = admission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        return prepare(context, page: 1, token: token, replacing: true, list: nil)
    }

    func prepareRetry(in context: Context) -> PreparedPage? {
        if failedRequest?.token.kind == .refresh { return prepareRefresh(in: context) }
        return prepareMore(in: context, from: listReceipt)
    }

    private func bindOpenedSource(_ context: Context) -> Bool {
        if let openedSource { return openedSource == context.source }
        openedSource = context.source
        return true
    }

    private func prepare(
        _ context: Context, page: Int, token: FeedLoadToken,
        replacing: Bool, list: ListReceipt?
    ) -> PreparedPage {
        loadingToken = token
        loadingKind = token.kind
        failedRequest = nil
        loadFeedback.started()
        return PreparedPage(context: context, page: page, token: token, replacing: replacing, list: list)
    }

    private func isCurrent(_ request: PreparedPage) -> Bool {
        openedSource == request.context.source && admission.isCurrent(request.token)
            && loadingToken == request.token
            && (request.replacing || request.list == listReceipt)
    }

    @discardableResult
    func perform(_ request: PreparedPage) async -> PageLoad {
        var succeeded = false
        defer {
            admission.finish(request.token, succeeded: succeeded)
            if loadingToken == request.token {
                loadingToken = nil
                loadingKind = nil
            }
        }
        guard isCurrent(request) else { return .superseded }
        guard !Task.isCancelled else { return .cancelled }
        do {
            let result = try await requests.getReplies(request.context, request.page)
            guard isCurrent(request) else { return .superseded }
            guard !Task.isCancelled else { return .cancelled }
            succeeded = true
            return publish(result, for: request)
        } catch {
            guard isCurrent(request) else { return .superseded }
            guard !Task.isCancelled, !error.isCancellation else { return .cancelled }
            if case .apiError(let code, _) = error, code == 12002 || code == 12061 {
                commentsClosed = true
                return .closed
            }
            failedRequest = request
            loadFeedback.failed(page: request.page)
            PlayerLog.log("[CommentThread] load failed: \(error)")
            return .failed
        }
    }

    /// The caller has already validated current source/token/cancellation; this
    /// entire publication stays synchronous on the same MainActor turn.
    private func publish(_ result: CommentResult, for request: PreparedPage) -> PageLoad {
        let returned = result.replies ?? []
        // Exclude the echoed root and only IDs already retained before this
        // response. Incoming new duplicates keep their original DTOs/order.
        let retainedIDs = request.replacing ? Set<Int>() : Set(replies.lazy.map(\.rpid))
        let fresh = returned.filter { item in
            item.rpid != request.context.root.rpid && !retainedIDs.contains(item.rpid)
        }
        // Blocked authors render collapsed; do not alter their floors/counts.
        if request.replacing {
            replies = fresh
        } else {
            replies.append(contentsOf: fresh)
        }
        page = request.page + 1
        hasMore = !returned.isEmpty
        // Server total remains optional and serves highlight EOF, not the header.
        if let count = result.page?.count { totalReplies = count }
        if request.replacing || listReceipt == nil {
            listReceipt = ListReceipt(source: request.context.source, lineage: UUID())
        }
        loadFeedback.succeeded()
        commentsClosed = false
        let signature = Self.pageSignature(
            requestedPage: request.page, returned: returned, loaded: replies.count, total: totalReplies
        )
        return fresh.isEmpty ? .stalled(signature: signature) : .advanced(signature: signature)
    }
}

// Composer lifetime is separate from GET requestGeneration and list replacement.
extension CommentThreadStore {
    var composerContext: CommentComposerUploadOwner.Context {
        .init(owner: composerID, sourceRevision: 0, replacementEpoch: replacementEpoch)
    }

    func composerIsCurrent(in context: Context, expected: CommentComposerUploadOwner.Context) -> Bool {
        expected == composerContext && composerSourceIsCurrent(in: context)
    }

    private func composerSourceIsCurrent(in context: Context) -> Bool {
        AuthManager.shared.isLoggedIn
            && AuthManager.shared.sessionGeneration == composerSessionGeneration
            && (openedSource == nil || openedSource == context.source)
    }

    func imageSelectionWasAdmitted(in context: Context, expected: CommentComposerUploadOwner.Context) {
        guard composerIsCurrent(in: context, expected: expected), bindOpenedSource(context) else { return }
        submission.draftDidChange()
        sendError = nil
    }

    func sendReply(
        in context: Context, expectedComposer: CommentComposerUploadOwner.Context,
        onAcceptedDraftCleared: @escaping @MainActor () -> Void
    ) {
        guard composerIsCurrent(in: context, expected: expectedComposer), !commentUpload.isUploading else { return }
        let msg = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !commentPictures.isEmpty,
              !commentsClosed, bindOpenedSource(context),
              let attempt = submission.begin() else { return }
        sendError = nil
        let target = replyTarget
        let pics = commentPictures
        let request = ReplyRequest(
            context: context, message: msg, parent: target?.rpid ?? context.root.rpid, pictures: pics
        )
        Task {
            defer {
                submission.finish(attempt)
                // Keep the original strong focus-host lifetime through the refresh.
                withExtendedLifetime(onAcceptedDraftCleared) {}
            }
            guard composerIsCurrent(in: context, expected: expectedComposer) else { return }
            do {
                _ = try await requests.post(request)
                guard composerSourceIsCurrent(in: context) else { return }
                if composerIsCurrent(in: context, expected: expectedComposer), submission.canApply(attempt) {
                    commentText = ""
                    commentPictures = []
                    cancelReply(in: context)
                    sendError = nil
                    // The callback owns the old context; retire it only after focus settles.
                    onAcceptedDraftCleared()
                    replacementEpoch &+= 1
                    commentUpload.retire()
                }
                postedCount += 1
                // Draft edits and our own epoch advance cannot suppress accepted refresh.
                if let refresh = prepareRefresh(in: context) {
                    await perform(refresh)
                }
            } catch {
                PlayerLog.log("[CommentThread] post failed: \(error)")
                let nsError = error as NSError
                guard !Task.isCancelled,
                      !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true,
                      !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
                      composerIsCurrent(in: context, expected: expectedComposer) else { return }
                sendError = String(
                    format: String(localized: "Failed to post: %@"),
                    error.localizedDescription
                )
            }
        }
    }
}
