import SwiftUI

// MARK: - Dynamic comments

/// Comment thread for a dynamic post. The server routes every dynamic's
/// comment area via basic.comment_id_str + comment_type (draw = 11,
/// text = 17, video = 1, article = 12).
/// Presented from the Moments feed and from the Moments tab of a
/// user's profile.
struct DynamicCommentSheet: View {
    let item: DynamicFeedResult.DynamicItem

    @State private var comments: [CommentResult.CommentItem] = []
    @State private var total = 0
    @State private var commentSort: CommentSort = .top
    @State private var committedSort: CommentSort = .top
    @State private var commentFeedback = CommentLoadFeedback()
    @State private var commentsClosed = false
    @State private var commentListLineage: UUID?
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var commentAdmission = FeedLoadAdmissionGate()
    @State private var commentLoadingToken: FeedLoadToken?
    @State private var commentText = ""
    @State private var pictures: [ComposedPicture] = []
    @State private var commentSubmission = CommentComposerSubmission()
    @State private var commentUpload = CommentComposerUploadOwner()
    @State private var commentComposerID = UUID()
    @State private var commentReplacementEpoch: UInt64 = 0
    // Keep the presented account lifetime even if a pending task retains this Sheet.
    @State private var commentSessionGeneration = AuthManager.shared.sessionGeneration
    @State private var acceptedCommentClear: CommentComposerCapture?
    @State private var replyTarget: CommentResult.CommentItem?
    @State private var replyState = InlineCommentReplyState()
    @State private var previewImages: ImagePreviewItem?
    @State private var sendError: String?
    @State private var commentFocus = CommentComposerFocus()
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var coordinator

    /// Avatar taps push on the stack UNDER this sheet — close it first.
    private func openProfile(_ mid: Int) {
        dismiss()
        coordinator.navigate(to: .userSpace(mid))
    }

    private var oid: Int? { item.basic?.commentIdStr.flatMap(Int.init) }
    private var commentType: Int { item.basic?.commentType ?? 17 }
    private var upMid: Int? { item.modules?.moduleAuthor?.mid }

    private struct CommentSource: Equatable {
        let dynamicID: String?
        let oid: Int
        let type: Int
    }

    private struct CommentComposerCapture: Equatable {
        let source: CommentSource?
        let context: CommentComposerUploadOwner.Context
    }

    private var commentSource: CommentSource? {
        guard let oid else { return nil }
        return CommentSource(dynamicID: item.idStr, oid: oid, type: commentType)
    }

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here. Declared on the view so every presentation is covered.
    var body: some View {
        accentedBody
            .accentContentBoundary()
            .appAdaptiveSheet(padSizing: .page)
    }

    @ViewBuilder private var accentedBody: some View {
        let target = replyState.target
        CommentReplyZoomContainer(
            presentation: replyState.presentation,
            root: rootSurface,
            destination: Group {
                if let target {
                    CommentSheetReplyView(
                        target: target,
                        upMid: upMid,
                        anchors: replyState.presentation.anchors,
                        onBack: { replyState.close() },
                        onClose: { dismiss() },
                        onAvatarTap: openProfile
                    )
                }
            },
            ownsKeyboardSafeArea: false,
            onDismissed: { replyState.finishDismissal(target?.id) }
        )
        .appAmbientBrowseBackground()
        .imagePreview(item: $previewImages)
        // @mentions/BV links tapped in comments or the thread: this whole
        // view IS a sheet — close it before routing, or the push lands
        // invisibly under it (same as the avatar-tap handling above).
        .dismissingSheetOnBiliLink(coordinator: coordinator) { dismiss() }
        .appNoticeOverlay(bottomPadding: 64)
        .task { await loadMore() }
    }

    private var rootSurface: some View {
        let composerVisible = AuthManager.shared.isLoggedIn && oid != nil && !commentsClosed
        return VStack(spacing: 0) {
            commentHeaderBar
            if oid == nil {
                ContentUnavailableView(
                    "Comments Unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("This post does not expose a comment thread.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                commentList(composerVisible: composerVisible)
            }
        }
        .allowsHitTesting(replyState.target == nil)
        .accessibilityHidden(replyState.target != nil)
        .overlay(alignment: .bottom) {
            if composerVisible, replyState.target == nil {
                commentComposer
            }
        }
    }

    private var commentHeaderBar: some View {
        let source = commentSource
        return CommentSheetListHeader(
            total: total,
            sortSelection: (source != nil && !commentsClosed) ? commentSort : nil,
            anchors: replyState.presentation.anchors,
            onSelectSort: source.map { captured in
                { newSort in
                    guard newSort != commentSort, captured == commentSource else { return }
                    commentSort = newSort
                    Task { await replaceComments(captured, sort: newSort) }
                }
            },
            onClose: { dismiss() }
        )
    }

    private var commentComposer: some View {
        let composer = commentComposerCapture
        return CollapsibleComposer(
            text: commentTextBinding(for: composer),
            pictures: commentPicturesBinding(for: composer),
            placeholder: replyTarget.map { CommentComposerBar.replyPlaceholder(to: $0.member.uname) }
                ?? String(localized: "Write a comment..."),
            replyBanner: replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: commentSubmission.isSending,
            sendError: composerIsCurrent(composer) ? sendError : nil,
            focus: commentFocus,
            onCancelReply: {
                guard composerIsCurrent(composer) else { return }
                setCommentReplyTarget(nil, for: composer)
                commentFocus.dismiss()
            },
            onSend: { send(from: composer) },
            allowsCollapseAfterSend: allowsCollapseAfterCommentSend,
            uploadScope: commentUploadScope(for: composer),
            isInteractionCurrent: { composerIsCurrent(composer) }
        )
    }

    private func commentList(composerVisible: Bool) -> some View {
        let source = commentSource
        let lineage = commentListLineage
        let composer = commentComposerCapture
        let showsInitialSkeletons = isInitialCommentLoad
        let items = commentFeedItems(source: source, lineage: lineage, composer: composer)
        let footer = CommentListFooter.make(
            .init(
                commentsClosed: commentsClosed, showsInitialSkeletons: showsInitialSkeletons,
                feedback: commentFeedback, isLoading: isLoading,
                isEmpty: comments.isEmpty, hasMore: hasMore, lineage: lineage
            ),
            retry: { retryCommentLoad(source: source, lineage: lineage) }
        )
        return UIKitCommentFeedCollectionView(
            items: items,
            footerContent: footer.content,
            footerFingerprint: footer.fingerprint,
            skeletonCount: showsInitialSkeletons ? 6 : 0,
            showsItemDividers: true,
            dividerLeadingInset: 48,
            itemSpacing: AppSpacing.l,
            horizontalInset: AppSpacing.l,
            topInset: AppSpacing.s,
            bottomClearance: composerVisible ? 96 : AppSpacing.l,
            ignoresBottomSafeArea: true,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: {
                guard let source, source == commentSource else { return false }
                await replaceComments(source, sort: commentSort)
                return false
            },
            onWillDisplayItemAt: { _ in
                guard source == commentSource, lineage == commentListLineage else { return }
                Task {
                    guard source == commentSource, lineage == commentListLineage else { return }
                    await loadMore()
                }
            }
        )
        .contentLinks(presentsFeedback: false, handlesURLs: true, isCurrent: {
            source != nil && source == commentSource
        })
    }

    private var isInitialCommentLoad: Bool {
        !commentsClosed && comments.isEmpty
            && (isLoading || (!commentFeedback.hasLoaded && commentFeedback.failure == nil))
    }
}

private extension DynamicCommentSheet {
    private func openCommentThread(_ target: CommentThreadTarget) {
        coordinator.contentLinks.cancel()
        commentFocus.dismiss()
        replyState.open(target, presentInline: true)
    }

    private func commentFeedItems(
        source: CommentSource?,
        lineage: UUID?,
        composer: CommentComposerCapture
    ) -> [UIKitCommentFeedItem] {
        guard !commentsClosed else { return [] }
        let visibleComments = CommentAIFilterEngine.shared.visibleComments(from: comments, upMid: upMid)
        let rowFingerprint = AnyHashableSendable(CommentListRowFingerprint(
            upMid: upMid, oid: oid ?? 0, type: commentType, sort: commentSort, lineage: lineage
        ))
        return visibleComments.map { comment in
            UIKitCommentFeedItem(comment: comment, extraFingerprint: rowFingerprint) {
                commentRow(comment, source: source, composer: composer)
            }
        }
    }

    private func retryCommentLoad(source: CommentSource?, lineage: UUID?) {
        guard let source, source == commentSource else { return }
        Task {
            guard source == commentSource else { return }
            if commentFeedback.failure == .pagination, lineage == commentListLineage {
                await loadMore()
            } else {
                await replaceComments(source, sort: commentSort)
            }
        }
    }

    private func commentRow(
        _ comment: CommentResult.CommentItem,
        source: CommentSource?,
        composer: CommentComposerCapture
    ) -> some View {
        let threadOID = oid ?? 0
        let threadType = commentType
        return CommentRowView(
            comment: comment,
            upMid: upMid,
            onReply: { target in
                guard composerIsCurrent(composer) else { return }
                setCommentReplyTarget(target, for: composer)
                commentFocus.request()
            },
            onViewThread: { root in
                openCommentThread(CommentThreadTarget(oid: threadOID, type: threadType, root: root))
            },
            onOpenReply: { root, rpid in
                openCommentThread(CommentThreadTarget(
                    oid: threadOID, type: threadType, root: root, highlightRpid: rpid
                ))
            },
            onImageTap: { previewImages = $0 },
            onAvatarTap: { openProfile($0) },
            onDelete: {
                guard source == commentSource else { return }
                comments.removeAll { $0.rpid == comment.rpid }
                total = max(0, total - 1)
            }
        )
    }

    private var commentComposerContext: CommentComposerUploadOwner.Context {
        // The presented item is immutable; only an accepted draft clear replaces this context.
        CommentComposerUploadOwner.Context(
            owner: commentComposerID, sourceRevision: 0, replacementEpoch: commentReplacementEpoch
        )
    }

    private var commentComposerCapture: CommentComposerCapture {
        CommentComposerCapture(source: commentSource, context: commentComposerContext)
    }

    var commentSessionIsCurrent: Bool {
        AuthManager.shared.isLoggedIn && AuthManager.shared.sessionGeneration == commentSessionGeneration
    }

    private func composerIsCurrent(_ captured: CommentComposerCapture) -> Bool {
        guard let source = captured.source else { return false }
        return source == commentSource && captured.context == commentComposerContext
            && !commentsClosed && commentSessionIsCurrent
    }

    private func commentUploadScope(for captured: CommentComposerCapture) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: commentUpload,
            context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: { commentDraftDidChange() }
        )
    }

    func commentDraftDidChange() {
        commentSubmission.draftDidChange()
        acceptedCommentClear = nil
        sendError = nil
    }

    private func commentTextBinding(for captured: CommentComposerCapture) -> Binding<String> {
        Binding(get: { commentText }, set: { text in
            guard composerIsCurrent(captured) else { return }
            commentDraftDidChange()
            commentText = text
        })
    }

    private func commentPicturesBinding(for captured: CommentComposerCapture) -> Binding<[ComposedPicture]> {
        Binding(get: { pictures }, set: { newPictures in
            guard composerIsCurrent(captured), pictures != newPictures else { return }
            commentDraftDidChange()
            pictures = newPictures
        })
    }

    private func setCommentReplyTarget(_ target: CommentResult.CommentItem?, for captured: CommentComposerCapture) {
        guard composerIsCurrent(captured) else { return }
        acceptedCommentClear = nil
        if replyTarget?.rpid != target?.rpid {
            commentSubmission.draftDidChange()
            sendError = nil
        }
        replyTarget = target
    }

    private func allowsCollapseAfterCommentSend() -> Bool {
        guard let acceptedCommentClear else { return false }
        return composerIsCurrent(acceptedCommentClear)
    }

    private func send(from captured: CommentComposerCapture) {
        guard !Task.isCancelled, composerIsCurrent(captured),
              !commentUpload.isUploading, let source = captured.source else { return }
        let msg = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !pictures.isEmpty, let attempt = commentSubmission.begin() else { return }
        sendError = nil
        acceptedCommentClear = nil
        let target = replyTarget
        let pics = pictures
        Task {
            defer { commentSubmission.finish(attempt) }
            guard !Task.isCancelled, composerIsCurrent(captured) else { return }
            do {
                let result = try await CommentAPI.postComment(
                    oid: source.oid,
                    message: msg,
                    type: source.type,
                    root: target?.rpid,
                    parent: target?.rpid,
                    pictures: pics
                )
                guard !Task.isCancelled, commentSessionIsCurrent, source == commentSource else { return }
                if composerIsCurrent(captured), commentSubmission.canApply(attempt) {
                    commentTextBinding(for: captured).wrappedValue = ""
                    commentPicturesBinding(for: captured).wrappedValue = []
                    setCommentReplyTarget(nil, for: captured)
                    sendError = nil
                    // Clear with the old writers before retiring them, then authorize the new context.
                    commentReplacementEpoch &+= 1
                    commentUpload.retire()
                    commentFocus.dismiss()
                    acceptedCommentClear = commentComposerCapture
                }
                await replaceComments(source, sort: commentSort)
                if !Task.isCancelled, commentSessionIsCurrent, source == commentSource, !commentsClosed,
                   let created = result.acceptedTopLevelReply(
                       matching: result.rpid, root: target?.rpid, parent: target?.rpid
                   ),
                   comments.insertAcceptedTopLevelCommentIfNeeded(created) {
                    total += 1
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true,
                      commentSessionIsCurrent, source == commentSource else { return }
                PlayerLog.log("[DynamicComments] post failed: \(error)")
                if composerIsCurrent(captured) {
                    sendError = String(
                        format: String(localized: "Failed to post: %@"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func loadMore() async {
        guard !Task.isCancelled, let source = commentSource, hasMore, commentLoadingToken == nil else { return }
        let requestedPage = page
        let kind: FeedLoadKind = requestedPage == 1 ? .initial : .pagination
        guard let token = commentAdmission.admit(kind: kind, cursor: "page:\(requestedPage)") else { return }
        commentLoadingToken = token
        commentFeedback.started()
        isLoading = true
        await loadComments(source, page: requestedPage, sort: commentSort, token: token, replacing: false)
    }

    private func replaceComments(_ source: CommentSource, sort: CommentSort) async {
        guard !Task.isCancelled, source == commentSource else { return }
        let token = commentAdmission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        commentLoadingToken = token
        commentFeedback.started()
        isLoading = true
        await loadComments(source, page: 1, sort: sort, token: token, replacing: true)
    }

    private func isCurrentCommentRequest(_ token: FeedLoadToken, source: CommentSource) -> Bool {
        commentLoadingToken == token && commentAdmission.isCurrent(token) && source == commentSource
    }

    private func loadComments(
        _ source: CommentSource,
        page requestedPage: Int,
        sort requestSort: CommentSort,
        token: FeedLoadToken,
        replacing: Bool
    ) async {
        var succeeded = false
        defer {
            commentAdmission.finish(token, succeeded: succeeded)
            if isCurrentCommentRequest(token, source: source) {
                if !succeeded, requestedPage == 1 { commentSort = committedSort }
                commentLoadingToken = nil
                isLoading = false
            }
        }
        guard isCurrentCommentRequest(token, source: source), !Task.isCancelled else { return }
        do {
            let result = try await CommentAPI.getComments(
                oid: source.oid,
                type: source.type,
                sort: requestSort.apiValue,
                pn: requestedPage
            )
            guard isCurrentCommentRequest(token, source: source), !Task.isCancelled else { return }
            publishComments(result, page: requestedPage, sort: requestSort, replacing: replacing)
            commentFeedback.succeeded()
            succeeded = true
        } catch {
            guard isCurrentCommentRequest(token, source: source),
                  !Task.isCancelled, !error.isCancellation else { return }
            commentFeedback.failed(page: requestedPage)
            if case .apiError(let code, _) = error, code == 12002 || code == 12061 { commentsClosed = true }
            PlayerLog.log("[DynamicComments] load failed: \(error)")
        }
    }

    func publishComments(
        _ result: CommentResult, page requestedPage: Int, sort requestSort: CommentSort, replacing: Bool
    ) {
        // Pinned comments ride the captured first page only.
        let source = requestedPage == 1 ? result.repliesWithPinned : (result.replies ?? [])
        if replacing {
            comments = source
        } else {
            let retainedIDs = source.isEmpty ? Set<Int>() : Set(comments.lazy.map(\.rpid))
            let fresh = source.filter { !retainedIDs.contains($0.rpid) }
            comments.append(contentsOf: fresh)
        }
        if requestedPage == 1 {
            commentListLineage = UUID()
            committedSort = requestSort
        }
        commentsClosed = false
        total = result.page?.count ?? total
        hasMore = !(result.replies ?? []).isEmpty
        page = requestedPage + 1
    }
}
