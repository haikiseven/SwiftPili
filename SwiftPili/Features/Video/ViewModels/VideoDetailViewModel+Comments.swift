import Foundation

/// Comment identities are separate from player admission and editable draft ownership.
/// Stored state lives in the primary class: extensions cannot store properties,
/// and cross-file helpers deliberately use internal access rather than file-private.
@MainActor
extension VideoDetailViewModel {
    struct CommentSource: Equatable, Sendable {
        let videoID: VideoID
        let aid: Int
        let generation: UInt64
    }

    struct CommentRevocationWitness: Sendable {
        let source: CommentSource
        let generation: UInt64
    }

    struct CommentListReceipt: Equatable, Sendable {
        let source: CommentSource
        let sort: CommentSort
        let lineage: UUID
    }

    struct CommentSnapshot: Sendable {
        let rows: [CommentResult.CommentItem]
        let total: Int
        let page: Int
        let haveMore: Bool
        let closed: Bool
        let loadedAid: Int?
        let receipt: CommentListReceipt?
    }

    enum CommentRequestPurpose: Sendable {
        case initial, refresh, sort, acceptedPost, append
    }

    struct PreparedCommentRequest: Sendable {
        let source: CommentSource
        let sort: CommentSort
        let page: Int
        let token: FeedLoadToken
        let purpose: CommentRequestPurpose
        let receipt: CommentListReceipt?
        let rollback: CommentSnapshot?
    }

    struct CommentLocateIntent: Equatable {
        let receipt: CommentListReceipt
        let generation: UInt64
    }

    enum CommentLocation {
        case found(CommentLocateIntent)
        case missing(CommentLocateIntent)
        case superseded
    }

    func retireCommentRequests() {
        commentAdmission.supersede()
        commentRecoverySeed = nil
        commentLoadingToken = nil
    }

    func prepareCommentRefresh(from source: CommentSource?) -> PreparedCommentRequest? {
        prepareCommentRequest(purpose: .refresh, from: source)
    }

    func prepareCommentSort(_ sort: CommentSort, from source: CommentSource?) -> PreparedCommentRequest? {
        guard !Task.isCancelled, let source, source == currentCommentSource,
              sort != commentSort else { return nil }
        let snapshot = CommentSnapshot(
            rows: comments, total: commentTotal, page: commentPage,
            haveMore: commentsHaveMore, closed: commentsClosed,
            loadedAid: commentsLoadedAid, receipt: commentListReceipt
        )
        commentSort = sort
        comments = []
        commentsLoadedAid = nil
        commentListReceipt = nil
        commentPage = 1
        commentsHaveMore = true
        return prepareCommentRequest(purpose: .sort, from: source, rollback: snapshot)
    }

    /// All replacements admit immediately, including while an older GET is busy.
    func prepareCommentRequest(
        purpose: CommentRequestPurpose,
        from source: CommentSource?,
        rollback: CommentSnapshot? = nil
    ) -> PreparedCommentRequest? {
        guard !Task.isCancelled, let source, source == currentCommentSource else { return nil }
        commentRecoverySeed = nil
        let kind: FeedLoadKind = purpose == .initial ? .initial : .refresh
        let token = commentAdmission.supersedeAndAdmit(kind: kind, cursor: "1")
        commentLoadingToken = token
        commentFeedback.started()
        return PreparedCommentRequest(
            source: source, sort: commentSort, page: 1, token: token,
            purpose: purpose, receipt: nil, rollback: rollback
        )
    }

    /// How many trailing rows may start the next page. Waiting for the very
    /// last row made every fling hit the bottom before the request began.
    static let commentPrefetchDistance = 5

    /// `appearingRpid` is the row that just appeared; it admits only while it is
    /// inside the published list's trailing window. `nil` is the retry path.
    func prepareMoreComments(
        from receipt: CommentListReceipt?, appearingRpid: Int? = nil
    ) -> PreparedCommentRequest? {
        guard !Task.isCancelled, let receipt, receipt == commentListReceipt,
              receipt.source == currentCommentSource, receipt.sort == commentSort,
              !commentsClosed, commentsHaveMore, !isLoadingComments,
              appearingRpid.map({ rpid in
                  comments.suffix(Self.commentPrefetchDistance).contains { $0.rpid == rpid }
              }) ?? true,
              let token = commentAdmission.admit(kind: .pagination, cursor: String(commentPage))
        else { return nil }
        commentLoadingToken = token
        commentFeedback.started()
        return PreparedCommentRequest(
            source: receipt.source, sort: receipt.sort, page: commentPage,
            token: token, purpose: .append, receipt: receipt, rollback: nil
        )
    }

    private func ownsCommentRequest(_ request: PreparedCommentRequest) -> Bool {
        guard !Task.isCancelled, request.source == currentCommentSource,
              request.sort == commentSort, commentAdmission.isCurrent(request.token),
              commentLoadingToken == request.token else { return false }
        return request.purpose != .append || request.receipt == commentListReceipt
    }

    /// Fetch only; each caller owns current-source publication and matching cleanup.
    func fetchCommentResponse(_ request: PreparedCommentRequest?) async -> Result<CommentResult, BiliError>? {
        guard let request, ownsCommentRequest(request) else { return nil }
        do {
            return .success(try await CommentAPI.getComments(
                oid: request.source.aid, sort: request.sort.apiValue, pn: request.page
            ))
        } catch {
            return .failure(error)
        }
    }

    func performCommentRequest(_ request: PreparedCommentRequest) async {
        var succeeded = false
        defer { finishCommentRequest(request, succeeded: succeeded) }
        let response = await fetchCommentResponse(request)
        guard ownsCommentRequest(request) else { return }
        var preparedAppend: [CommentResult.CommentItem]?
        var preparedTotal: Int?
        if request.purpose == .append, case .success(let result)? = response {
            var incoming = result.replies ?? []
            let deletionRevision = commentDeletionRevision
            while true {
                let revision = commentRowsRevision
                guard let prepared = try? await FeedCollectionPolicy.appendingAgainstRetainedIDs(
                    existing: comments, incoming: incoming, id: { $0.rpid }
                ), ownsCommentRequest(request) else { return }
                if revision == commentRowsRevision {
                    preparedAppend = prepared.rows
                    break
                }
                // A delete can change rows without retiring this GET. Keep its
                // original exclusions while rebuilding against the latest rows.
                incoming = prepared.accepted
            }
            if let count = result.page?.count {
                preparedTotal = FeedCollectionPolicy.totalAfterLocalRemovals(
                    count, removals: commentDeletionRevision &- deletionRevision
                )
            }
        }
        succeeded = consumeCommentResponse(
            response, for: request, preparedAppend: preparedAppend, preparedTotal: preparedTotal
        )
    }

    func finishCommentRequest(_ request: PreparedCommentRequest, succeeded: Bool) {
        commentAdmission.finish(request.token, succeeded: succeeded)
        guard commentLoadingToken == request.token else { return }
        commentLoadingToken = nil
    }

    /// Publication, errors and sort rollback require the same immutable owner.
    @discardableResult
    func consumeCommentResponse(
        _ response: Result<CommentResult, BiliError>?, for request: PreparedCommentRequest,
        preparedAppend: [CommentResult.CommentItem]? = nil, preparedTotal: Int? = nil
    ) -> Bool {
        guard ownsCommentRequest(request), let response else { return false }
        switch response {
        case .success(let result):
            return publishCommentResponse(
                result, for: request, preparedAppend: preparedAppend, preparedTotal: preparedTotal
            )
        case .failure(let error):
            guard !error.isCancellation else { return false }
            commentFeedback.failed(page: request.page)
            if request.purpose == .acceptedPost { return false }
            if request.purpose == .append {
                PlayerLog.log("[VideoDetailVM] comments page \(request.page) failed: \(error)")
            } else if Self.isClosedCommentsError(error) || request.purpose == .initial {
                settleUnavailableComments(error, for: request)
            } else if request.purpose == .sort, comments.isEmpty, !commentsClosed,
                      let snapshot = request.rollback {
                comments = snapshot.rows
                commentTotal = snapshot.total
                commentPage = snapshot.page
                commentsHaveMore = snapshot.haveMore
                commentsClosed = snapshot.closed
                commentsLoadedAid = snapshot.loadedAid
                commentListReceipt = snapshot.receipt
            }
            return false
        }
    }

    /// Called only after the consumer's live proof, with no further suspension.
    private func publishCommentResponse(
        _ result: CommentResult, for request: PreparedCommentRequest,
        preparedAppend: [CommentResult.CommentItem]?, preparedTotal: Int?
    ) -> Bool {
        if request.purpose == .append {
            guard let preparedAppend else { return false }
            comments = preparedAppend
        } else {
            comments = result.repliesWithPinned
            commentListReceipt = CommentListReceipt(
                source: request.source, sort: request.sort, lineage: UUID()
            )
        }
        commentTotal = preparedTotal ?? result.page?.count ?? (request.purpose == .initial ? 0 : commentTotal)
        commentPage = request.page + 1
        commentsHaveMore = !(result.replies ?? []).isEmpty
        // The detail host reads closed state; unchanged page writes must not
        // invalidate it when only the list observes the rows.
        if commentsClosed { commentsClosed = false }
        commentsLoadedAid = request.source.aid
        commentFeedback.succeeded()
        return true
    }

    private func settleUnavailableComments(_ error: BiliError, for request: PreparedCommentRequest) {
        commentsClosed = Self.isClosedCommentsError(error)
        comments = []
        commentTotal = 0
        if request.purpose == .initial { commentPage = 1 }
        commentsHaveMore = false
        commentsLoadedAid = request.source.aid
        commentListReceipt = CommentListReceipt(source: request.source, sort: request.sort, lineage: UUID())
        if request.purpose == .initial {
            PlayerLog.log("[VideoDetailVM] comments unavailable (closed=\(commentsClosed)): \(error)")
        }
    }

    /// Only load's existing exact live proof may readopt retained comment metadata.
    func recoverCommentsAfterProvedLiveReactivation(id: VideoID) {
        guard let oldSource = commentMetadataSource,
              let witness = commentRevocationWitness, witness.source == oldSource,
              witness.generation == commentSourceGeneration,
              oldSource.generation != commentSourceGeneration,
              retainedCommentMetadataMatches(oldSource, id: id) else { return }
        let source = CommentSource(videoID: id, aid: oldSource.aid, generation: commentSourceGeneration)
        let retainedReceipt = commentListReceipt
        retireCommentRequests()
        commentMetadataSource = source
        commentRevocationWitness = nil
        if let retainedReceipt, retainedReceipt.source == oldSource {
            commentListReceipt = CommentListReceipt(
                source: source, sort: retainedReceipt.sort, lineage: UUID()
            )
            return
        }
        // No first outcome was consumed. Do not inherit parent cancellation or
        // reserve busy outside a Task which might never execute.
        commentsLoadedAid = nil
        let seed = commentAdmission.generation
        commentRecoverySeed = seed
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.commentRecoverySeed == seed { self.commentRecoverySeed = nil }
            }
            guard self.currentCommentSource == source,
                  self.commentAdmission.generation == seed,
                  !self.commentsReadyForNavigation,
                  let request = self.prepareCommentRequest(purpose: .initial, from: source) else { return }
            await self.performCommentRequest(request)
        }
    }

    private func isCurrentCommentLocateIntent(_ intent: CommentLocateIntent) -> Bool {
        !Task.isCancelled && intent.receipt == commentListReceipt
            && intent.receipt.source == currentCommentSource && intent.receipt.sort == commentSort
            && intent.generation == commentAdmission.generation
    }

    func isCurrentCommentLocation(_ location: CommentLocation) -> Bool {
        switch location {
        case .found(let intent), .missing(let intent): return isCurrentCommentLocateIntent(intent)
        case .superseded: return false
        }
    }

    /// One query and bounded progress: never walk into a successor list.
    func locateComment(rpid: Int) async -> CommentLocation {
        guard !Task.isCancelled, commentsReadyForNavigation,
              let receipt = commentListReceipt, receipt.sort == commentSort else { return .superseded }
        let intent = CommentLocateIntent(receipt: receipt, generation: commentAdmission.generation)
        guard isCurrentCommentLocateIntent(intent) else { return .superseded }
        guard rpid > 0 else { return .missing(intent) }
        if comments.contains(where: { $0.rpid == rpid }) { return .found(intent) }
        while commentsHaveMore {
            guard isCurrentCommentLocateIntent(intent),
                  let request = prepareMoreComments(from: receipt) else { return .superseded }
            let countBefore = comments.count
            await performCommentRequest(request)
            guard isCurrentCommentLocateIntent(intent) else { return .superseded }
            if comments.contains(where: { $0.rpid == rpid }) { return .found(intent) }
            guard comments.count > countBefore else { break }
        }
        guard isCurrentCommentLocateIntent(intent), !isLoadingComments else { return .superseded }
        return .missing(intent)
    }

    func postComment(
        message: String,
        root: Int? = nil,
        parent: Int? = nil,
        pictures: [ComposedPicture] = []
    ) async -> Int? {
        guard !Task.isCancelled, let source = currentCommentSource else { return nil }
        let verification = ExperimentalSettingsStore.shared.captureAutoVerification()
        let aid = source.aid
        let generation = source.generation
        let result: PostCommentResult
        do {
            result = try await CommentAPI.postComment(
                oid: aid,
                message: message,
                root: root,
                parent: parent,
                pictures: pictures
            )
        } catch {
            // Keep the draft on cancellation and do not retry automatically:
            // cancellation cannot tell us whether the server accepted the POST.
            guard isCurrentCommentSource(aid: aid, generation: generation),
                  !error.isCancellation else { return nil }
            PlayerLog.log("[VideoDetailVM] post comment failed: \(error)")
            showToast(String(localized: "Failed to post: \(error.localizedDescription)"), style: .error)
            return nil
        }
        guard isCurrentCommentSource(aid: aid, generation: generation) else { return nil }
        guard let rpid = result.rpid else {
            showToast(String(localized: "Comment was not accepted"), style: .error)
            return nil
        }
        // The re-fetch reseats page 1 (cursor included). A failed one
        // leaves the previously paged list AND its cursor alone — the
        // old code reset the cursor either way, so a failed refresh left
        // a many-page list claiming it had loaded only page 1.
        if let request = prepareCommentRequest(purpose: .acceptedPost, from: currentCommentSource) {
            await performCommentRequest(request)
        }
        guard isCurrentCommentSource(aid: aid, generation: generation) else { return nil }
        if !commentsClosed, commentsReadyForNavigation,
           let created = result.acceptedTopLevelReply(matching: rpid, root: root, parent: parent),
           comments.insertAcceptedTopLevelCommentIfNeeded(created) {
            commentTotal += 1
        }

        if let verification, ExperimentalSettingsStore.shared.isCurrentAutoVerification(verification) {
            showToast(String(localized: "Comment posted — verifying visibility…"), style: .progress)
            // Unstructured on purpose: the composer must be released
            // immediately, not held in "sending" while we wait out
            // bilibili's propagation delay.
            Task { [weak self] in
                await self?.verifyCommentVisibility(
                    aid: aid, generation: generation, rpid: rpid, root: root, verification: verification
                )
            }
        } else {
            showToast(String(localized: "Comment posted"), style: .success)
        }
        return rpid
    }

    private func isCurrentCommentSource(aid: Int, generation: UInt64) -> Bool {
        !Task.isCancelled && currentCommentSource?.aid == aid && currentCommentSource?.generation == generation
    }

    /// Anonymous re-fetch of the thread to detect shadow-banned comments —
    /// the author always sees their own comment, so the check must look
    /// like a logged-out stranger.
    ///
    /// Anonymous list views lag a fresh post (CDN caching + async
    /// indexing, often well past 10s) — the old single check 2s after
    /// posting misread ordinary propagation delay as a shadow ban.
    /// Re-check with growing delays and conclude "hidden" only after the
    /// final miss; conclude "visible" the moment it appears.
    private func verifyCommentVisibility(
        aid: Int, generation: UInt64, rpid: Int, root: Int?, verification: ExperimentalAutoVerifyReceipt
    ) async {
        let delays: [Double] = [3, 12, 30]
        var sawError = false
        for (attempt, delay) in delays.enumerated() {
            guard isCurrentCommentSource(aid: aid, generation: generation),
                  ExperimentalSettingsStore.shared.isCurrentAutoVerification(verification) else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard isCurrentCommentSource(aid: aid, generation: generation),
                  ExperimentalSettingsStore.shared.isCurrentAutoVerification(verification) else { return }
            let visibility = await CommentAPI.checkCommentVisibleAnonymously(
                oid: aid, rpid: rpid, root: root, access: verification.access, operation: verification.permit
            )
            guard isCurrentCommentSource(aid: aid, generation: generation),
                  ExperimentalSettingsStore.shared.isCurrentAutoVerification(verification) else { return }
            switch visibility {
            case .visible:
                showToast(String(localized: "Comment is publicly visible"), style: .success)
                return
            case .hidden:
                PlayerLog.log("[CommentCheck] rpid \(rpid) not visible yet (attempt \(attempt + 1)/\(delays.count))")
            case .unknown:
                PlayerLog.log("[CommentCheck] rpid \(rpid) check errored (attempt \(attempt + 1)/\(delays.count))")
                sawError = true
            }
        }
        guard isCurrentCommentSource(aid: aid, generation: generation),
                  ExperimentalSettingsStore.shared.isCurrentAutoVerification(verification) else { return }
        if sawError {
            showToast(String(localized: "Posted, but visibility check failed"), style: .warning)
        } else {
            showToast(String(localized: "Comment is hidden for others (shadow ban)"), style: .error)
        }
    }
}
