import Foundation
import Observation

@MainActor
@Observable
final class MomentDetailViewModel {
    enum InteractionLoadFailure: Sendable, Equatable {
        case initial, refresh, pagination
    }

    struct ReactionEntry: Identifiable, Sendable {
        let id: String
        let item: DynamicReactionResult.ReactionItem

        init(
            sourceID: String,
            cursor: String,
            itemIndex: Int,
            item: DynamicReactionResult.ReactionItem
        ) {
            id = "\(sourceID.utf8.count):\(sourceID)|\(cursor.utf8.count):\(cursor)|\(itemIndex)"
            self.item = item
        }
    }

    private static let likeAction = "赞了"
    private static let reactionScanPageLimit = 3

    var item: DynamicFeedResult.DynamicItem?
    var isLoading = false
    var error: String?
    var comments: [CommentResult.CommentItem] = []
    var commentTotal = 0
    private(set) var commentFeedback = CommentLoadFeedback()
    private(set) var commentListLineage: UUID?
    var isLoadingComments = false
    var commentsClosed = false
    var liked = false
    var likeCount = 0
    var commentSort: CommentSort = .top

    private var page = 1
    private var hasMore = true
    private(set) var oid: Int?

    fileprivate struct CommentSource: Equatable {
        let dynamicID: String
        let oid: Int?
        let type: Int
    }

    struct CommentSourceReceipt: Equatable, Sendable {
        fileprivate let dynamicID: String
        fileprivate let oid: Int
        fileprivate let type: Int
        fileprivate let generation: UInt64
    }

    let commentUpload = CommentComposerUploadOwner()
    private let commentComposerID = UUID()
    private var commentReplacementEpoch: UInt64 = 0
    private(set) var commentSendError: String?
    private var detailGeneration: UInt64 = 0
    private var loadingDetailID: String?
    private var settledDetailID: String?
    private var readyCommentGeneration: UInt64?
    private var commentRequestedID: String?
    @ObservationIgnored private var adoptedCommentSource: CommentSource?
    @ObservationIgnored private var commentAdmission = FeedLoadAdmission()
    @ObservationIgnored private var commentLoadingToken: FeedLoadToken?
    @ObservationIgnored private var commentListSort: CommentSort = .top

    var forwards: [DynamicForwardItem] = []
    var isLoadingForwards = false
    private(set) var forwardsLoaded = false
    private(set) var forwardFailure: InteractionLoadFailure?
    private(set) var forwardReportedTotal: Int?
    private var forwardOffset = ""
    private(set) var forwardsHaveMore = true
    private var forwardContinuationCursors: Set<String> = []

    var reactions: [ReactionEntry] = []
    var isLoadingReactions = false
    private(set) var reactionsLoaded = false
    private(set) var reactionFailure: InteractionLoadFailure?
    private(set) var reactionsHaveMore = true
    private(set) var reactionsNeedContinuation = false
    private(set) var reactionsHaveUnclassifiedActions = false
    private(set) var reactionReportedTotal: Int?
    private var reactionOffset = ""

    @ObservationIgnored private var interactionDynamicID: String?
    @ObservationIgnored private var reactionCursorSourceID: String?
    @ObservationIgnored private var reactionVisitedCursors: Set<String> = []
    @ObservationIgnored private var forwardAdmission = FeedLoadAdmission()
    @ObservationIgnored private var forwardLoadingToken: FeedLoadToken?
    @ObservationIgnored private var reactionAdmission = FeedLoadAdmission()
    @ObservationIgnored private var reactionLoadingToken: FeedLoadToken?

    var commentType: Int { item?.basic?.commentType ?? 17 }
    var authorMid: Int? { item?.modules?.moduleAuthor?.mid }
    var forwardCount: Int { item?.modules?.moduleStat?.forward?.count ?? 0 }
    var hasKnownForwardCount: Bool { item?.modules?.moduleStat?.forward?.count != nil }
    var hasKnownLikeCount: Bool { item?.modules?.moduleStat?.like?.count != nil }

    var readyCommentSource: CommentSourceReceipt? {
        guard let generation = readyCommentGeneration,
              let source = adoptedCommentSource, let oid = source.oid,
              isCurrentCommentSource(source, generation: generation) else { return nil }
        return CommentSourceReceipt(
            dynamicID: source.dynamicID, oid: oid, type: source.type,
            generation: generation
        )
    }

    var commentComposerContext: CommentComposerUploadOwner.Context {
        CommentComposerUploadOwner.Context(
            owner: commentComposerID, sourceRevision: detailGeneration, replacementEpoch: commentReplacementEpoch
        )
    }

    func commentSource(for requestedID: String) -> CommentSourceReceipt? {
        guard commentRequestedID == requestedID else { return nil }
        return readyCommentSource
    }

    func commentDraftWasReplaced() {
        commentReplacementEpoch &+= 1
        commentUpload.retire()
        commentSendError = nil
    }

    func clearCommentSendError() {
        commentSendError = nil
    }

    func removeComment(rpid: Int) {
        comments.removeAll { $0.rpid == rpid }
        commentTotal = max(0, commentTotal - 1)
    }

    func load(dynamicId: String) async {
        guard !Task.isCancelled else { return }
        guard settledDetailID != dynamicId, loadingDetailID != dynamicId else { return }
        detailGeneration &+= 1
        let generation = detailGeneration
        loadingDetailID = dynamicId
        settledDetailID = nil
        readyCommentGeneration = nil
        commentRequestedID = dynamicId
        commentUpload.retire()
        commentSendError = nil
        retireInteractionRequests()
        if commentSort != commentListSort { commentSort = commentListSort }
        commentAdmission.supersede()
        commentLoadingToken = nil
        isLoadingComments = false
        isLoading = true
        defer {
            if generation == detailGeneration {
                isLoading = false
                if loadingDetailID == dynamicId { loadingDetailID = nil }
            }
        }

        do {
            let result = try await DynamicAPI.getDetail(dynamicId: dynamicId)
            guard generation == detailGeneration, !Task.isCancelled else { return }
            guard let item = result.item else {
                error = "This moment is unavailable."
                return
            }
            self.item = item
            liked = item.modules?.moduleStat?.like?.status ?? false
            likeCount = item.modules?.moduleStat?.like?.count ?? 0
            adoptCommentSource(item, requestedID: dynamicId, generation: generation)
            let commentsSettled = await loadMoreComments()
            guard generation == detailGeneration, !Task.isCancelled, commentsSettled else { return }
            settledDetailID = dynamicId
        } catch {
            guard generation == detailGeneration, !Task.isCancelled, !error.isCancellation else { return }
            self.error = "\(error)"
            PlayerLog.log("[MomentDetailVM] load failed: \(error)")
        }
    }

    func loadMoreForwards() async {
        guard !Task.isCancelled, forwardsHaveMore, forwardLoadingToken == nil,
              let context = interactionRequestContext() else { return }
        let requestedOffset = forwardOffset
        let kind: FeedLoadKind = forwardsLoaded ? .pagination : .initial
        guard let token = forwardAdmission.admit(kind: kind, cursor: "offset:\(requestedOffset)") else { return }
        await performForwardRequest(
            sourceID: context.sourceID, generation: context.generation,
            offset: requestedOffset, token: token, replacing: !forwardsLoaded
        )
    }

    func refreshForwards() async {
        guard !Task.isCancelled, let context = interactionRequestContext() else { return }
        let token = forwardAdmission.supersedeAndAdmit(kind: .refresh, cursor: "offset:")
        await performForwardRequest(
            sourceID: context.sourceID, generation: context.generation,
            offset: "", token: token, replacing: true
        )
    }

    func loadMoreReactions(continuing: Bool = false) async {
        guard !Task.isCancelled, AuthManager.shared.isLoggedIn,
              reactionsHaveMore, reactionLoadingToken == nil,
              !reactionsNeedContinuation || continuing,
              let context = interactionRequestContext() else { return }
        let requestedOffset = reactionOffset
        let kind: FeedLoadKind = reactionsLoaded ? .pagination : .initial
        guard let token = reactionAdmission.admit(kind: kind, cursor: "offset:\(requestedOffset)") else { return }
        await performReactionScan(
            sourceID: context.sourceID, generation: context.generation,
            offset: requestedOffset, token: token, replacing: false
        )
    }

    func refreshReactions() async {
        guard !Task.isCancelled, AuthManager.shared.isLoggedIn,
              let context = interactionRequestContext() else { return }
        let token = reactionAdmission.supersedeAndAdmit(kind: .refresh, cursor: "offset:")
        await performReactionScan(
            sourceID: context.sourceID, generation: context.generation,
            offset: "", token: token, replacing: true
        )
    }

    @discardableResult
    func loadMoreComments() async -> Bool {
        guard !Task.isCancelled,
              let source = adoptedCommentSource,
              let generation = readyCommentGeneration,
              isCurrentCommentSource(source, generation: generation),
              hasMore, commentLoadingToken == nil else { return false }
        guard source.oid != nil else { return true }
        let requestedPage = page
        let kind: FeedLoadKind = requestedPage == 1 ? .initial : .pagination
        guard let token = commentAdmission.admit(kind: kind, cursor: "page:\(requestedPage)") else { return false }
        commentLoadingToken = token
        commentFeedback.started()
        isLoadingComments = true
        let outcome = await loadComments(source, generation: generation, page: requestedPage, token: token, replacing: false)
        return outcome == .success
    }

    func refreshComments(from expectedSource: CommentSourceReceipt?) async {
        guard !Task.isCancelled, let expectedSource, readyCommentSource == expectedSource,
              let source = adoptedCommentSource, let generation = readyCommentGeneration else { return }
        let token = commentAdmission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        commentLoadingToken = token
        commentFeedback.started()
        isLoadingComments = true
        _ = await loadComments(source, generation: generation, page: 1, token: token, replacing: true)
    }

    func setCommentSort(_ sort: CommentSort) async {
        guard !Task.isCancelled, sort != commentSort,
              let source = adoptedCommentSource, let generation = readyCommentGeneration,
              isCurrentCommentSource(source, generation: generation) else { return }
        commentSort = sort
        let token = commentAdmission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        commentLoadingToken = token
        commentFeedback.started()
        isLoadingComments = true
        _ = await loadComments(
            source, generation: generation, page: 1, token: token, replacing: true, sort: sort
        )
    }

    func toggleLike() async {
        guard let dynamicId = item?.idStr else { return }
        let wasLiked = liked
        let wasCount = likeCount
        liked.toggle()
        likeCount = max(0, likeCount + (liked ? 1 : -1))
        do {
            _ = try await DynamicAPI.likeDynamic(dynamicId: dynamicId, up: liked ? 1 : 2)
        } catch {
            PlayerLog.log("[MomentDetailVM] like failed: \(error)")
            liked = wasLiked
            likeCount = wasCount
            if !Task.isCancelled, !BiliAPIRetryPolicy.isCancellation(error), !error.isCancellation {
                AppNoticeCenter.shared.showError(String(localized: "Like failed"))
            }
        }
    }

}

// MARK: - Write actions

extension MomentDetailViewModel {
    func repost(content: String) async -> Bool {
        guard let dynamicId = item?.idStr else { return false }
        do {
            _ = try await DynamicAPI.repostDynamic(dynamicId: dynamicId, content: content)
            return true
        } catch {
            PlayerLog.log("[MomentDetailVM] repost failed: \(error)")
            return false
        }
    }

    func postComment(
        message: String,
        root: Int?,
        parent: Int?,
        pictures: [ComposedPicture],
        expectedSource: CommentSourceReceipt
    ) async -> Bool {
        guard !Task.isCancelled,
              readyCommentSource == expectedSource,
              let source = adoptedCommentSource, let oid = source.oid,
              let generation = readyCommentGeneration,
              isCurrentCommentSource(source, generation: generation) else { return false }
        commentSendError = nil
        do {
            let result = try await CommentAPI.postComment(
                oid: oid,
                message: message,
                type: source.type,
                root: root,
                parent: parent,
                pictures: pictures
            )
            guard isCurrentCommentSource(source, generation: generation), !Task.isCancelled else { return false }
            let token = commentAdmission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
            commentLoadingToken = token
            commentFeedback.started()
            isLoadingComments = true
            _ = await loadComments(source, generation: generation, page: 1, token: token, replacing: true)
            guard isCurrentCommentSource(source, generation: generation), !Task.isCancelled else { return false }
            if !commentsClosed,
               let created = result.acceptedTopLevelReply(matching: result.rpid, root: root, parent: parent),
               comments.insertAcceptedTopLevelCommentIfNeeded(created) {
                commentTotal += 1
            }
            return true
        } catch {
            guard isCurrentCommentSource(source, generation: generation),
                  !Task.isCancelled, !error.isCancellation else { return false }
            PlayerLog.log("[MomentDetailVM] post failed: \(error)")
            commentSendError = String(
                format: String(localized: "Failed to post: %@"),
                error.localizedDescription
            )
            return false
        }
    }
}

private struct DynamicReactionPageScan {
    var entries: [MomentDetailViewModel.ReactionEntry] = []
    var cursor: String
    var hasMore = false
    var pagesScanned = 0
    var hasUnclassifiedActions = false
    var reportedTotal: Int?
    var visitedCursors: Set<String>

    mutating func append(
        _ items: [DynamicReactionResult.ReactionItem], sourceID: String,
        cursor: String, likeAction: String
    ) {
        for (index, item) in items.enumerated() {
            guard item.action == likeAction else {
                hasUnclassifiedActions = true
                continue
            }
            entries.append(MomentDetailViewModel.ReactionEntry(
                sourceID: sourceID, cursor: cursor, itemIndex: index, item: item
            ))
        }
    }
}

private extension MomentDetailViewModel {
    func interactionRequestContext() -> (sourceID: String, generation: UInt64)? {
        guard let sourceID = interactionDynamicID,
              let generation = readyCommentGeneration,
              isCurrentInteractionSource(sourceID, generation: generation) else { return nil }
        return (sourceID, generation)
    }

    func isCurrentInteractionSource(_ sourceID: String, generation: UInt64) -> Bool {
        generation == detailGeneration && readyCommentGeneration == generation
            && interactionDynamicID == sourceID && adoptedCommentSource?.dynamicID == sourceID
    }

    func isCurrentForwardRequest(
        _ token: FeedLoadToken, sourceID: String, generation: UInt64
    ) -> Bool {
        forwardLoadingToken == token && forwardAdmission.isCurrent(token)
            && isCurrentInteractionSource(sourceID, generation: generation)
    }

    func isCurrentReactionRequest(
        _ token: FeedLoadToken, sourceID: String, generation: UInt64
    ) -> Bool {
        reactionLoadingToken == token && reactionAdmission.isCurrent(token)
            && isCurrentInteractionSource(sourceID, generation: generation)
    }

    func retireInteractionRequests() {
        forwardAdmission.supersede()
        forwardLoadingToken = nil
        isLoadingForwards = false
        reactionAdmission.supersede()
        reactionLoadingToken = nil
        isLoadingReactions = false
    }

    func resetInteractionLists(for sourceID: String) {
        retireInteractionRequests()
        interactionDynamicID = sourceID
        forwards = []
        forwardsLoaded = false
        forwardFailure = nil
        forwardReportedTotal = nil
        forwardOffset = ""
        forwardsHaveMore = true
        forwardContinuationCursors = []
        reactions = []
        reactionsLoaded = false
        reactionFailure = nil
        reactionReportedTotal = nil
        reactionOffset = ""
        reactionsHaveMore = true
        reactionsNeedContinuation = false
        reactionsHaveUnclassifiedActions = false
        reactionCursorSourceID = nil
        reactionVisitedCursors = []
    }

    func performForwardRequest(
        sourceID: String,
        generation: UInt64,
        offset: String,
        token: FeedLoadToken,
        replacing: Bool
    ) async {
        forwardLoadingToken = token
        isLoadingForwards = true
        forwardFailure = nil
        var succeeded = false
        defer {
            forwardAdmission.finish(token, succeeded: succeeded)
            if isCurrentForwardRequest(token, sourceID: sourceID, generation: generation) {
                forwardLoadingToken = nil
                isLoadingForwards = false
            }
        }
        guard !Task.isCancelled,
              isCurrentForwardRequest(token, sourceID: sourceID, generation: generation) else { return }

        let fetch = Task { try await DynamicAPI.getForwardList(dynamicId: sourceID, offset: offset) }
        do {
            let result = try await fetch.value
            guard isCurrentForwardRequest(token, sourceID: sourceID, generation: generation),
                  !Task.isCancelled else { return }
            let nextOffset = result.offset ?? offset
            var nextContinuationCursors = replacing ? Set<String>() : forwardContinuationCursors
            if result.hasMore {
                guard !nextOffset.isEmpty,
                      nextOffset != offset,
                      nextContinuationCursors.insert(nextOffset).inserted else {
                    forwardFailure = interactionFailure(for: token.kind, loaded: forwardsLoaded)
                    PlayerLog.log("[MomentDetailVM] forward cursor did not advance")
                    return
                }
            }
            if replacing {
                forwards = FeedCollectionPolicy.replaceDeduplicated(result.items, id: \.id)
            } else {
                FeedCollectionPolicy.appendDeduplicated(to: &forwards, incoming: result.items, id: \.id)
            }
            forwardOffset = nextOffset
            forwardContinuationCursors = nextContinuationCursors
            forwardReportedTotal = replacing ? result.total : (result.total ?? forwardReportedTotal)
            forwardsHaveMore = result.hasMore
            forwardsLoaded = true
            forwardFailure = nil
            succeeded = true
            PlayerLog.log(
                "[MomentDetailVM] forwards +\(result.items.count) (total \(forwards.count), "
                    + "more=\(forwardsHaveMore))"
            )
        } catch {
            guard isCurrentForwardRequest(token, sourceID: sourceID, generation: generation) else { return }
            guard !Task.isCancelled,
                  !BiliAPIRetryPolicy.isCancellation(error),
                  (error as? BiliError)?.isCancellation != true else { return }
            forwardFailure = interactionFailure(for: token.kind, loaded: forwardsLoaded)
            PlayerLog.log("[MomentDetailVM] forward list failed: \(error)")
        }
    }

    func performReactionScan(
        sourceID: String,
        generation: UInt64,
        offset: String,
        token: FeedLoadToken,
        replacing: Bool
    ) async {
        reactionLoadingToken = token
        isLoadingReactions = true
        reactionFailure = nil
        var succeeded = false
        defer {
            reactionAdmission.finish(token, succeeded: succeeded)
            if isCurrentReactionRequest(token, sourceID: sourceID, generation: generation) {
                reactionLoadingToken = nil
                isLoadingReactions = false
            }
        }
        guard isCurrentReactionRequest(token, sourceID: sourceID, generation: generation) else { return }

        let knownCursors: Set<String>
        if !replacing, reactionCursorSourceID == sourceID {
            knownCursors = reactionVisitedCursors
        } else {
            knownCursors = []
        }
        let scan = await collectReactionPages(
            sourceID: sourceID, generation: generation, offset: offset,
            token: token, knownCursors: knownCursors
        )
        guard let scan, !Task.isCancelled,
              isCurrentReactionRequest(token, sourceID: sourceID, generation: generation) else { return }
        publishReactionScan(scan, sourceID: sourceID, replacing: replacing)
        succeeded = true
        PlayerLog.log(
            "[MomentDetailVM] reactions +\(scan.entries.count) (total \(reactions.count), "
                + "scanned \(scan.pagesScanned), more=\(scan.hasMore))"
        )
    }

    func collectReactionPages(
        sourceID: String,
        generation: UInt64,
        offset: String,
        token: FeedLoadToken,
        knownCursors: Set<String>
    ) async -> DynamicReactionPageScan? {
        var scan = DynamicReactionPageScan(
            cursor: offset, visitedCursors: knownCursors
        )
        scan.visitedCursors.insert(offset)
        while scan.pagesScanned < Self.reactionScanPageLimit {
            guard isCurrentReactionRequest(token, sourceID: sourceID, generation: generation),
                  !Task.isCancelled else { return nil }
            let requestedCursor = scan.cursor
            do {
                let result = try await DynamicAPI.getReactionList(
                    dynamicId: sourceID, offset: requestedCursor
                )
                guard isCurrentReactionRequest(token, sourceID: sourceID, generation: generation),
                      !Task.isCancelled else { return nil }
                scan.pagesScanned += 1
                scan.append(
                    result.items, sourceID: sourceID,
                    cursor: requestedCursor, likeAction: Self.likeAction
                )
                if let total = result.total { scan.reportedTotal = total }
                scan.hasMore = result.hasMore
                let nextCursor = result.offset ?? requestedCursor
                if scan.hasMore && (nextCursor.isEmpty || !scan.visitedCursors.insert(nextCursor).inserted) {
                    reactionFailure = interactionFailure(for: token.kind, loaded: reactionsLoaded)
                    PlayerLog.log("[MomentDetailVM] reaction cursor repeated")
                    return nil
                }
                scan.cursor = nextCursor
                if !scan.hasMore { break }
            } catch {
                guard isCurrentReactionRequest(token, sourceID: sourceID, generation: generation) else { return nil }
                guard !Task.isCancelled,
                      !BiliAPIRetryPolicy.isCancellation(error),
                      !error.isCancellation else { return nil }
                reactionFailure = interactionFailure(for: token.kind, loaded: reactionsLoaded)
                PlayerLog.log("[MomentDetailVM] reaction list failed: \(error)")
                return nil
            }
        }
        return scan
    }

    func publishReactionScan(
        _ scan: DynamicReactionPageScan,
        sourceID: String,
        replacing: Bool
    ) {
        if replacing {
            reactions = scan.entries
            reactionsHaveUnclassifiedActions = scan.hasUnclassifiedActions
            reactionReportedTotal = scan.reportedTotal
        } else {
            FeedCollectionPolicy.appendDeduplicated(
                to: &reactions, incoming: scan.entries, id: \.id
            )
            reactionsHaveUnclassifiedActions = reactionsHaveUnclassifiedActions || scan.hasUnclassifiedActions
            if let total = scan.reportedTotal { reactionReportedTotal = total }
        }
        reactionOffset = scan.cursor
        reactionCursorSourceID = sourceID
        reactionVisitedCursors = scan.visitedCursors
        reactionsHaveMore = scan.hasMore
        reactionsNeedContinuation = scan.hasMore && scan.pagesScanned == Self.reactionScanPageLimit
        reactionsLoaded = true
        reactionFailure = nil
    }

    func interactionFailure(
        for kind: FeedLoadKind, loaded: Bool
    ) -> InteractionLoadFailure {
        switch kind {
        case .initial: .initial
        case .refresh: loaded ? .refresh : .initial
        case .pagination: loaded ? .pagination : .initial
        }
    }

    func adoptCommentSource(
        _ item: DynamicFeedResult.DynamicItem,
        requestedID: String,
        generation: UInt64
    ) {
        let source = CommentSource(
            dynamicID: item.idStr ?? requestedID,
            oid: item.basic?.commentIdStr.flatMap(Int.init),
            type: item.basic?.commentType ?? 17
        )
        if interactionDynamicID != source.dynamicID {
            resetInteractionLists(for: source.dynamicID)
        }
        if source != adoptedCommentSource {
            comments = []
            commentTotal = 0
            page = 1
            hasMore = true
            commentsClosed = false
            commentFeedback = CommentLoadFeedback()
            commentListLineage = nil
            commentListSort = commentSort
            commentSendError = nil
        }
        oid = source.oid
        adoptedCommentSource = source
        readyCommentGeneration = generation
    }

    struct CommentPageRequest {
        let source: CommentSource
        let generation: UInt64
        let page: Int
        let token: FeedLoadToken
        let replacing: Bool
        let sort: CommentSort
    }

    func isCurrentCommentSource(_ source: CommentSource, generation: UInt64) -> Bool {
        generation == detailGeneration && readyCommentGeneration == generation && adoptedCommentSource == source
    }

    func isCurrentCommentRequest(_ token: FeedLoadToken, source: CommentSource, generation: UInt64) -> Bool {
        commentLoadingToken == token && commentAdmission.isCurrent(token)
            && isCurrentCommentSource(source, generation: generation)
    }

    func loadComments(
        _ source: CommentSource,
        generation: UInt64,
        page requestedPage: Int,
        token: FeedLoadToken,
        replacing: Bool,
        sort: CommentSort? = nil
    ) async -> FeedLoadOutcome {
        var succeeded = false
        defer {
            commentAdmission.finish(token, succeeded: succeeded)
            if isCurrentCommentRequest(token, source: source, generation: generation) {
                if !succeeded, requestedPage == 1 { commentSort = commentListSort }
                commentLoadingToken = nil
                isLoadingComments = false
            }
        }
        guard isCurrentCommentRequest(token, source: source, generation: generation),
              let oid = source.oid else { return .superseded }
        guard !Task.isCancelled else { return .cancelled }
        let requestSort = sort ?? commentSort
        do {
            let result = try await CommentAPI.getComments(
                oid: oid, type: source.type, sort: requestSort.apiValue, pn: requestedPage
            )
            let outcome = await consumeCommentPage(result, for: CommentPageRequest(
                source: source, generation: generation, page: requestedPage,
                token: token, replacing: replacing, sort: requestSort
            ))
            succeeded = outcome == .success
            return outcome
        } catch {
            guard isCurrentCommentRequest(token, source: source, generation: generation) else { return .superseded }
            guard !Task.isCancelled, !error.isCancellation else { return .cancelled }
            commentFeedback.failed(page: requestedPage)
            if case .apiError(let code, _) = error, code == 12002 || code == 12061 {
                commentsClosed = true
                PlayerLog.log("[MomentDetailVM] comment area closed by UP (\(code))")
            } else {
                PlayerLog.log("[MomentDetailVM] comments failed: \(error)")
            }
            return .failed
        }
    }

    func consumeCommentPage(_ result: CommentResult, for request: CommentPageRequest) async -> FeedLoadOutcome {
        guard isCurrentCommentRequest(request.token, source: request.source, generation: request.generation)
        else { return .superseded }
        guard !Task.isCancelled else { return .cancelled }
        let incoming = request.page == 1 ? result.repliesWithPinned : (result.replies ?? [])
        let rows: [CommentResult.CommentItem]
        if request.replacing {
            rows = incoming
        } else {
            let prepared = try? await FeedCollectionPolicy.appendingAgainstRetainedIDs(
                existing: comments, incoming: incoming, id: { $0.rpid }
            )
            guard isCurrentCommentRequest(request.token, source: request.source, generation: request.generation)
            else { return .superseded }
            guard !Task.isCancelled, let prepared else { return .cancelled }
            rows = prepared.rows
        }
        publishComments(result, rows: rows, page: request.page, sort: request.sort)
        commentFeedback.succeeded()
        return .success
    }

    func publishComments(
        _ result: CommentResult, rows: [CommentResult.CommentItem], page requestedPage: Int, sort: CommentSort
    ) {
        comments = rows
        if requestedPage == 1 {
            commentListLineage = UUID()
            commentListSort = sort
        }
        commentTotal = result.page?.count ?? commentTotal
        hasMore = !(result.replies ?? []).isEmpty
        page = requestedPage + 1
        commentsClosed = false
    }
}
