import SwiftUI

struct VideoDetailCommentRowActions {
    let isRouteActive: () -> Bool
    let currentVideoID: () -> VideoID
    let reply: (CommentResult.CommentItem) -> Void
    let openThread: (CommentThreadTarget) -> Void
    let previewImages: (ImagePreviewItem) -> Void
}

struct VideoCommentHeaderFingerprint: Hashable, Sendable {
    let replyCount: Int?
    let commentsClosed: Bool
    let commentSort: CommentSort
    let sourceAid: Int?
    let sourceGeneration: UInt64?
}

struct VideoUnavailableFingerprint: Hashable, Sendable {
    let message: String
    let symbolName: String
    let isRetryable: Bool
}

private struct VideoCommentRowFingerprint: Hashable, Sendable {
    let upMid: Int?
    let receiptSourceAid: Int?
    let receiptSourceGeneration: UInt64?
    let receiptSort: CommentSort?
    let receiptLineage: UUID?
    let requestedID: VideoID
}

private enum VideoCommentFooterFingerprint: Hashable, Sendable {
    case unavailable(VideoUnavailableFingerprint)
    case closed(topPadding: CGFloat)
    case feedback(
        hasLoaded: Bool,
        failureCode: Int?,
        isLoading: Bool,
        isEmpty: Bool,
        hasMore: Bool,
        sourceAid: Int?,
        sourceGeneration: UInt64?,
        receiptLineage: UUID?
    )

    static func failureCode(_ failure: CommentLoadFeedback.Failure?) -> Int? {
        switch failure {
        case nil: nil
        case .initial: 0
        case .refresh: 1
        case .pagination: 2
        }
    }
}

struct VideoDetailCommentList: View {
    let model: VideoDetailViewModel
    let requestedID: VideoID
    let highlightedRpid: Int?
    let scrollToRpid: Int?
    let headerView: AnyView?
    let headerFingerprint: VideoCommentHeaderFingerprint?
    let showsInitialVideoSkeletons: Bool
    let closedTopPadding: CGFloat
    let bottomClearance: CGFloat
    let showsScrollIndicators: Bool
    let actions: VideoDetailCommentRowActions
    let unavailableView: AnyView?
    let unavailableFingerprint: VideoUnavailableFingerprint?
    let onRefresh: @MainActor () async -> Bool
    let onScrollOffsetChange: ((CGFloat) -> Void)?

    var body: some View {
        let receipt = model.commentListReceipt
        let receiptSource = receipt?.source
        let commentLinkIsCurrent: @MainActor @Sendable () -> Bool = {
            actions.isRouteActive()
                && actions.currentVideoID() == requestedID
                && receiptSource != nil
                && model.hasCommentSource(for: requestedID)
                && model.currentCommentSource == receiptSource
        }
        let footer = resolvedFooter(receipt: receipt)
        let currentComments = model.comments
        let filterStore = LocalContentFilterStore.shared
        let _ = (
            filterStore.revision,
            filterStore.collapseFilteredComments,
            BlocklistManager.shared.isEnabled,
            BlocklistManager.shared.blockedMids.count
        )
        let visibleComments = CommentAIFilterEngine.shared
            .visibleComments(
                from: currentComments,
                upMid: model.videoInfo?.owner.mid
            )
            .filter {
                !filterStore.shouldHideCommentCompletely(
                    mid: $0.mid,
                    content: $0.content.displayMessage
                )
            }
        UIKitCommentFeedCollectionView(
            headerItems: headerItems,
            items: commentItems(visibleComments, receipt: receipt),
            footerContent: footer.content,
            footerFingerprint: footer.fingerprint,
            skeletonCount: resolvedSkeletonCount,
            highlightedItemID: highlightedRpid.map { AnyHashableSendable($0) },
            scrollToItemID: scrollToRpid.map { AnyHashableSendable($0) },
            showsItemDividers: true,
            dividerLeadingInset: 48,
            itemSpacing: AppSpacing.l,
            headerSpacing: AppSpacing.l,
            horizontalInset: AppSpacing.l,
            topInset: headerView != nil ? AppSpacing.s : AppSpacing.l,
            maxContentWidth: nil,
            bottomClearance: bottomClearance,
            ignoresBottomSafeArea: false,
            showsScrollIndicators: showsScrollIndicators,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: onRefresh,
            onScrollOffsetChange: onScrollOffsetChange,
            onWillDisplayItemAt: { index in
                triggerPagination(
                    at: index,
                    in: visibleComments,
                    unfilteredCount: currentComments.count,
                    receipt: receipt
                )
            }
        )
        .contentLinks(presentsFeedback: false, handlesURLs: true, isCurrent: commentLinkIsCurrent)
    }

    private var headerItems: [UIKitCommentFeedItem] {
        guard let headerView, let headerFingerprint else { return [] }
        return [
            UIKitCommentFeedItem(
                id: "video-comment-header",
                fingerprint: headerFingerprint,
                content: { headerView }
            )
        ]
    }

    private var isCommentAreaOpen: Bool {
        model.videoInfo != nil && !model.commentsClosed
    }

    private var isEmptyInitialCommentLoad: Bool {
        if model.videoInfo == nil {
            return showsInitialVideoSkeletons && unavailableView == nil
        }
        return !model.commentsClosed
            && model.comments.isEmpty
            && (model.isLoadingComments || model.commentsAwaitingInitialResponse)
    }

    private var resolvedSkeletonCount: Int {
        isEmptyInitialCommentLoad ? 6 : 0
    }

    private func commentItems(
        _ comments: [CommentResult.CommentItem],
        receipt: VideoDetailViewModel.CommentListReceipt?
    ) -> [UIKitCommentFeedItem] {
        guard isCommentAreaOpen else { return [] }
        let upMid = model.videoInfo?.owner.mid
        let extra = AnyHashableSendable(VideoCommentRowFingerprint(
            upMid: upMid,
            receiptSourceAid: receipt?.source.aid,
            receiptSourceGeneration: receipt?.source.generation,
            receiptSort: receipt?.sort,
            receiptLineage: receipt?.lineage,
            requestedID: requestedID
        ))
        return comments.map { comment in
            UIKitCommentFeedItem(comment: comment, extraFingerprint: extra) {
                VideoDetailCommentRow(
                    comment: comment,
                    upMid: upMid,
                    receipt: receipt,
                    requestedID: requestedID,
                    model: model,
                    actions: actions
                )
                .equatable()
            }
        }
    }

    private func resolvedFooter(
        receipt: VideoDetailViewModel.CommentListReceipt?
    ) -> (content: AnyView?, fingerprint: AnyHashableSendable?) {
        if let unavailableView, let unavailableFingerprint, model.videoInfo == nil {
            return (
                unavailableView,
                AnyHashableSendable(VideoCommentFooterFingerprint.unavailable(unavailableFingerprint))
            )
        }
        guard model.videoInfo != nil else { return (nil, nil) }
        if model.commentsClosed {
            let view = ContentUnavailableView(
                "Comments are turned off",
                systemImage: "exclamationmark.bubble"
            )
            .padding(.top, closedTopPadding)
            return (
                AnyView(view),
                AnyHashableSendable(VideoCommentFooterFingerprint.closed(topPadding: closedTopPadding))
            )
        }
        if isEmptyInitialCommentLoad { return (nil, nil) }
        let source = model.currentCommentSource
        let isLoading = model.isLoadingComments || model.commentsAwaitingInitialResponse
        let hasMore = model.commentsHaveMore
        if !isLoading, model.commentFeedback.failure == nil, !model.comments.isEmpty, !hasMore {
            return (nil, nil)
        }
        let feedbackView = CommentLoadFeedbackView(
            feedback: model.commentFeedback,
            isLoading: isLoading,
            isEmpty: model.comments.isEmpty,
            hasMore: hasMore
        ) {
            guard actions.currentVideoID() == requestedID,
                  model.hasCommentSource(for: requestedID),
                  model.currentCommentSource == source else { return }
            let request = model.commentFeedback.failure == .pagination
                ? model.prepareMoreComments(from: receipt) : model.prepareCommentRefresh(from: source)
            if let request { Task { await model.performCommentRequest(request) } }
        }
        let fingerprint = VideoCommentFooterFingerprint.feedback(
            hasLoaded: model.commentFeedback.hasLoaded,
            failureCode: VideoCommentFooterFingerprint.failureCode(model.commentFeedback.failure),
            isLoading: isLoading,
            isEmpty: model.comments.isEmpty,
            hasMore: hasMore,
            sourceAid: source?.aid,
            sourceGeneration: source?.generation,
            receiptLineage: receipt?.lineage
        )
        return (AnyView(feedbackView), AnyHashableSendable(fingerprint))
    }

    private func triggerPagination(
        at index: Int,
        in comments: [CommentResult.CommentItem],
        unfilteredCount: Int,
        receipt: VideoDetailViewModel.CommentListReceipt?
    ) {
        let receiptSource = receipt?.source
        guard actions.isRouteActive(),
              actions.currentVideoID() == requestedID,
              receiptSource != nil,
              model.hasCommentSource(for: requestedID),
              model.currentCommentSource == receiptSource,
              comments.indices.contains(index) else { return }
        let appearingRpid = comments.count < unfilteredCount ? nil : comments[index].rpid
        guard let request = model.prepareMoreComments(
            from: receipt, appearingRpid: appearingRpid
        ) else { return }
        Task { await model.performCommentRequest(request) }
    }
}

private struct VideoDetailCommentRow: View, Equatable {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    let receipt: VideoDetailViewModel.CommentListReceipt?
    let requestedID: VideoID
    let model: VideoDetailViewModel
    let actions: VideoDetailCommentRowActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.comment.rpid == rhs.comment.rpid
            && lhs.upMid == rhs.upMid
            && lhs.receipt == rhs.receipt
            && lhs.requestedID == rhs.requestedID
    }

    var body: some View {
        let model = model
        let source = receipt?.source
        let requestedID = requestedID
        let actions = actions
        let comment = comment
        let sourceIsCurrent: @MainActor @Sendable () -> Bool = {
            actions.isRouteActive()
                && actions.currentVideoID() == requestedID && source != nil
                && model.hasCommentSource(for: requestedID)
                && model.currentCommentSource == source
        }
        let actionIsCurrent: @MainActor @Sendable () -> Bool = { sourceIsCurrent() }
        CommentRowView(
            comment: comment,
            upMid: upMid,
            onReply: { target in
                guard actionIsCurrent() else { return }
                actions.reply(target)
            },
            onViewThread: { root in
                guard actionIsCurrent() else { return }
                let target = CommentThreadTarget(oid: source?.aid ?? 0, type: 1, root: root)
                actions.openThread(target)
            },
            onOpenReply: { root, rpid in
                guard actionIsCurrent() else { return }
                let target = CommentThreadTarget(oid: source?.aid ?? 0, type: 1, root: root, highlightRpid: rpid)
                actions.openThread(target)
            },
            onImageTap: { item in
                guard actionIsCurrent() else { return }
                actions.previewImages(item)
            },
            onDelete: {
                guard sourceIsCurrent() else { return }
                model.removeComment(rpid: comment.rpid)
                model.showToast(String(localized: "Comment deleted"), style: .success)
            }
        )
    }
}
