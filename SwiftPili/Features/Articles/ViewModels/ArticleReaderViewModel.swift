import Foundation
import Observation

@MainActor
@Observable
final class ArticleReaderViewModel {
    struct CommentSourceReceipt: Equatable, Sendable {
        fileprivate let cvid: Int
        fileprivate let revision: UInt64
    }

    struct CommentListReceipt: Equatable, Sendable {
        fileprivate let source: CommentSourceReceipt
        fileprivate let lineage: UUID
    }

    fileprivate enum CommentRequestMode: Sendable {
        case append(CommentListReceipt?)
        case replacement
    }

    struct PreparedCommentRequest: Sendable {
        fileprivate let source: CommentSourceReceipt
        fileprivate let page: Int
        fileprivate let mode: CommentRequestMode
        fileprivate let token: FeedLoadToken
    }

    var info: ArticleViewInfo?
    var blocks: [ArticleBlock] = [] {
        didSet { indexedBlocks = ArticleContentParser.indexBlocks(blocks) }
    }
    private(set) var indexedBlocks: [IndexedArticleBlock] = []
    var isLoading = false
    var parseFailed = false
    var liked = false
    var likeCount = 0

    var comments: [CommentResult.CommentItem] = [] {
        didSet { commentRowsRevision &+= 1 }
    }
    @ObservationIgnored private var commentRowsRevision: UInt64 = 0
    var commentTotal = 0
    private(set) var commentFeedback = CommentLoadFeedback()
    private(set) var commentsClosed = false
    var isLoadingComments: Bool { commentLoadingToken != nil }
    private(set) var commentListReceipt: CommentListReceipt?

    private var page = 1
    private var hasMore = true
    private var commentAdmission = FeedLoadAdmission()
    private var commentLoadingToken: FeedLoadToken?
    private(set) var cvid = 0
    private var commentSourceRevision: UInt64 = 0
    private var loadingCVID: Int?
    private var settledCVID: Int?
    private var loadGeneration: UInt64 = 0
    let commentUpload = CommentComposerUploadOwner()
    private let commentComposerIdentifier = UUID()
    private var commentReplacementEpoch: UInt64 = 0
    private(set) var commentSendError: String?

    var commentComposerContext: CommentComposerUploadOwner.Context {
        .init(
            owner: commentComposerIdentifier,
            sourceRevision: commentSourceRevision,
            replacementEpoch: commentReplacementEpoch
        )
    }

    func commentDraftWasReplaced() {
        commentReplacementEpoch &+= 1
        commentUpload.retire()
        commentSendError = nil
    }

    func clearCommentSendError() {
        commentSendError = nil
    }

    func commentSource(for requestedCvid: Int) -> CommentSourceReceipt? {
        guard requestedCvid > 0, cvid == requestedCvid else { return nil }
        return CommentSourceReceipt(cvid: cvid, revision: commentSourceRevision)
    }

    var imageURLs: [URL] {
        blocks.compactMap { block in
            if case .image(let url) = block { return url }
            return nil
        }
    }

    func load(cvid: Int) async {
        guard !Task.isCancelled, settledCVID != cvid, loadingCVID != cvid else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadingCVID = cvid
        settledCVID = nil
        if self.cvid != cvid {
            commentSourceRevision &+= 1
            commentUpload.retire()
            commentSendError = nil
            commentAdmission.supersede()
            commentLoadingToken = nil
            comments = []
            commentTotal = 0
            page = 1
            hasMore = true
            commentListReceipt = nil
            commentFeedback = CommentLoadFeedback()
            commentsClosed = false
        }
        self.cvid = cvid
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
                if loadingCVID == cvid { loadingCVID = nil }
            }
        }

        async let infoFetch = try? ArticleAPI.getViewInfo(cvid: cvid)
        async let htmlFetch = try? ArticleAPI.fetchReadPageHTML(cvid: cvid)

        guard let html = await htmlFetch,
              generation == loadGeneration, self.cvid == cvid, !Task.isCancelled else {
            parseFailed = true
            return
        }
        blocks = await Task.detached(priority: .userInitiated) {
            ArticleContentParser.parse(pageHTML: html)
        }.value
        guard generation == loadGeneration, self.cvid == cvid, !Task.isCancelled else { return }
        parseFailed = blocks.isEmpty

        guard let loadedInfo = await infoFetch,
              generation == loadGeneration, self.cvid == cvid, !Task.isCancelled else {
            return
        }
        info = loadedInfo
        liked = loadedInfo.like == 1
        likeCount = loadedInfo.stats?.like ?? 0

        let commentsSettled: Bool
        if commentListReceipt != nil || commentsClosed {
            commentsSettled = true
        } else if let commentSource = commentSource(for: cvid),
                  let request = prepareCommentLoad(from: commentSource) {
            commentsSettled = await performCommentRequest(request)
        } else {
            commentsSettled = false
        }
        guard generation == loadGeneration, self.cvid == cvid, !Task.isCancelled,
              !parseFailed, commentsSettled else { return }
        settledCVID = cvid
    }

    func toggleLike() async {
        let wasLiked = liked
        let wasCount = likeCount
        liked.toggle()
        likeCount = max(0, likeCount + (liked ? 1 : -1))
        do {
            _ = try await ArticleAPI.setLike(cvid: cvid, like: liked)
        } catch {
            PlayerLog.log("[ArticleVM] like failed: \(error)")
            liked = wasLiked
            likeCount = wasCount
            if !Task.isCancelled, !BiliAPIRetryPolicy.isCancellation(error), !error.isCancellation {
                AppNoticeCenter.shared.showError(String(localized: "Like failed"))
            }
        }
    }

    func prepareMoreComments(from receipt: CommentListReceipt?) -> PreparedCommentRequest? {
        guard let receipt, receipt == commentListReceipt else { return nil }
        return prepareCommentLoad(from: receipt.source)
    }

    private func prepareCommentLoad(from source: CommentSourceReceipt) -> PreparedCommentRequest? {
        guard !Task.isCancelled, commentSource(for: source.cvid) == source,
              hasMore, commentLoadingToken == nil else { return nil }
        let requestedPage = page
        let kind: FeedLoadKind = requestedPage == 1 ? .initial : .pagination
        guard let token = commentAdmission.admit(kind: kind, cursor: "page:\(requestedPage)") else { return nil }
        commentLoadingToken = token
        commentFeedback.started()
        return PreparedCommentRequest(source: source, page: requestedPage,
                                      mode: .append(commentListReceipt), token: token)
    }

    func prepareCommentRefresh(from source: CommentSourceReceipt) -> PreparedCommentRequest? {
        guard !Task.isCancelled, commentSource(for: source.cvid) == source else { return nil }
        let token = commentAdmission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        commentLoadingToken = token
        commentFeedback.started()
        return PreparedCommentRequest(source: source, page: 1, mode: .replacement, token: token)
    }

    @discardableResult
    func performCommentRequest(_ request: PreparedCommentRequest) async -> Bool {
        var succeeded = false
        defer {
            commentAdmission.finish(request.token, succeeded: succeeded)
            if commentLoadingToken == request.token { commentLoadingToken = nil }
        }
        guard !Task.isCancelled, isCurrentCommentRequest(request) else { return false }
        do {
            let result = try await CommentAPI.getComments(oid: request.source.cvid, type: 12, pn: request.page)
            guard !Task.isCancelled, isCurrentCommentRequest(request) else { return false }
            var incoming = request.page == 1 ? result.repliesWithPinned : (result.replies ?? [])
            var rows = incoming
            if case .append = request.mode {
                while true {
                    let revision = commentRowsRevision
                    guard let prepared = try? await FeedCollectionPolicy.appendingAgainstRetainedIDs(
                        existing: comments, incoming: incoming, id: { $0.rpid }
                    ), !Task.isCancelled, isCurrentCommentRequest(request) else { return false }
                    if revision == commentRowsRevision {
                        rows = prepared.rows
                        break
                    }
                    incoming = prepared.accepted
                }
            }
            publishComments(result, rows: rows, for: request)
            commentFeedback.succeeded()
            commentsClosed = false
            succeeded = true
            return true
        } catch {
            guard !Task.isCancelled, !error.isCancellation, isCurrentCommentRequest(request) else { return false }
            commentFeedback.failed(page: request.page)
            if case .apiError(let code, _) = error, code == 12002 || code == 12061 {
                commentsClosed = true
                return true
            }
            PlayerLog.log("[ArticleVM] comments failed: \(error)")
            return false
        }
    }

    private func isCurrentCommentRequest(_ request: PreparedCommentRequest) -> Bool {
        guard commentLoadingToken == request.token, commentAdmission.isCurrent(request.token),
              commentSource(for: request.source.cvid) == request.source else { return false }
        switch request.mode {
        case .replacement:
            return true
        case .append(let receipt):
            return receipt == commentListReceipt
        }
    }

    private func publishComments(
        _ result: CommentResult, rows: [CommentResult.CommentItem], for request: PreparedCommentRequest
    ) {
        comments = rows
        if request.page == 1 {
            commentListReceipt = CommentListReceipt(source: request.source, lineage: UUID())
        }
        commentTotal = result.page?.count ?? commentTotal
        hasMore = !(result.replies ?? []).isEmpty
        page = request.page + 1
    }

    func postComment(
        message: String,
        root: Int?,
        parent: Int?,
        pictures: [ComposedPicture],
        expectedSource: CommentSourceReceipt
    ) async -> Bool {
        guard !Task.isCancelled, !commentsClosed,
              commentSource(for: expectedSource.cvid) == expectedSource else { return false }
        commentSendError = nil
        do {
            let result = try await CommentAPI.postComment(
                oid: expectedSource.cvid,
                message: message,
                type: 12,
                root: root,
                parent: parent,
                pictures: pictures
            )
            guard !Task.isCancelled, commentSource(for: expectedSource.cvid) == expectedSource else { return false }
            if let request = prepareCommentRefresh(from: expectedSource) {
                await performCommentRequest(request)
            }
            guard !Task.isCancelled, commentSource(for: expectedSource.cvid) == expectedSource else { return false }
            if !commentsClosed, commentListReceipt?.source == expectedSource,
               let created = result.acceptedTopLevelReply(matching: result.rpid, root: root, parent: parent),
               comments.insertAcceptedTopLevelCommentIfNeeded(created) {
                commentTotal += 1
            }
            return true
        } catch {
            guard !Task.isCancelled, !error.isCancellation,
                  commentSource(for: expectedSource.cvid) == expectedSource else { return false }
            PlayerLog.log("[ArticleVM] post failed: \(error)")
            commentSendError = String(
                format: String(localized: "Failed to post: %@"),
                error.localizedDescription
            )
            return false
        }
    }
}
