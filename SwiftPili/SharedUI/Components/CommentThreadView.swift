import SwiftUI

struct CommentThreadTarget: Identifiable {
    struct Identity: Hashable {
        let oid: Int
        let type: Int
        let rootRpid: Int
    }

    let oid: Int
    let type: Int
    let root: CommentResult.CommentItem
    var highlightRpid: Int?

    var id: Identity { Identity(oid: oid, type: type, rootRpid: root.rpid) }
}

struct CommentThreadView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isRegularWidth: Bool { sizeClass == .regular }

    let oid: Int
    let rootComment: CommentResult.CommentItem
    var highlightRpid: Int?
    var type: Int = 1
    var upMid: Int?
    var isStandalonePage = true
    var onAvatarTap: ((Int) -> Void)?

    @State private var thread = CommentThreadStore()

    private struct ComposerCapture {
        let store: CommentThreadStore
        let source: CommentThreadStore.Context
        let context: CommentComposerUploadOwner.Context
    }
    @State private var didScrollToHighlight = false
    @State private var locatedHighlightRpid: Int?
    @State private var highlightedReplyRpid: Int?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var previewImages: ImagePreviewItem?
    @State private var isComposerExpanded = false
    @State private var composerFocus = CommentComposerFocus()
    @AppMotion private var motion
    @Environment(AppCoordinator.self) private var coordinator

    private var threadContext: CommentThreadStore.Context {
        CommentThreadStore.Context(oid: oid, root: rootComment, type: type)
    }

    private func openProfile(_ mid: Int) {
        guard mid > 0 else { return }
        if let onAvatarTap {
            onAvatarTap(mid)
        } else {
            coordinator.navigate(to: .userSpace(mid))
        }
    }

    var body: some View {
        accentedBody.accentContentBoundary()
            .contentLinks()
            .appNoticeOverlay(bottomPadding: 64)
    }

    @ViewBuilder
    private var accentedBody: some View {
        let composer = composerCapture
        let listReceipt = thread.listReceipt
        let headerItems = threadHeaderItems(composer: composer)
        let visibleReplies = CommentAIFilterEngine.shared.visibleComments(from: thread.replies, upMid: upMid)
        let replyItems = visibleReplies.map { reply in
            UIKitCommentFeedItem(
                comment: reply,
                extraFingerprint: AnyHashableSendable(thread.commentsClosed),
                prefetchAvatarPointSize: 30
            ) {
                replyRow(reply, composer: composer)
            }
        }
        let showsInitialSkeletons = thread.isLoading && thread.replies.isEmpty && !thread.commentsClosed
        let hasMoreReplies = thread.totalReplies.map { thread.replies.count < $0 } ?? !thread.loadFeedback.hasLoaded
        let showsFooter = !showsInitialSkeletons && (
            thread.commentsClosed || thread.isLoading || thread.loadFeedback.failure != nil
                || thread.replies.isEmpty || hasMoreReplies
        )
        let composerVisible = AuthManager.shared.isLoggedIn && oid > 0 && !thread.commentsClosed

        UIKitCommentFeedCollectionView(
            headerItems: headerItems,
            items: replyItems,
            footerContent: showsFooter ? AnyView(threadFooterView(hasMore: hasMoreReplies)) : nil,
            footerFingerprint: showsFooter ? AnyHashableSendable(ThreadFooterFingerprint(
                commentsClosed: thread.commentsClosed,
                hasLoaded: thread.loadFeedback.hasLoaded,
                failure: thread.loadFeedback.failure,
                isLoading: thread.isLoading,
                isEmpty: thread.replies.isEmpty,
                hasMore: hasMoreReplies
            )) : nil,
            skeletonCount: showsInitialSkeletons ? 4 : 0,
            highlightedItemID: highlightedReplyRpid.map(AnyHashableSendable.init),
            scrollToItemID: locatedHighlightRpid.map(AnyHashableSendable.init),
            scrollToPosition: .centeredVertically,
            showsItemDividers: true,
            dividerLeadingInset: 40,
            itemSpacing: 8,
            headerSpacing: 8,
            horizontalInset: AppSpacing.l,
            topInset: AppSpacing.l,
            bottomClearance: composerVisible ? 88 : AppSpacing.l,
            ignoresBottomSafeArea: true,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: {
                guard let request = thread.prepareRefresh(in: threadContext) else { return false }
                await thread.perform(request)
                return false
            },
            onWillDisplayItemAt: { _ in
                guard let request = thread.prepareMore(in: threadContext, from: listReceipt) else { return }
                Task { await thread.perform(request) }
            }
        )
        .modifier(CommentThreadSurfaceBackground(isStandalonePage: isStandalonePage))
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if composerVisible {
                threadComposer(composer: composer)
            }
        }
        .task {
            let generation = thread.requestGeneration
            if !thread.loadFeedback.hasLoaded, thread.loadFeedback.failure == nil {
                await thread.loadMore(in: threadContext)
            }
            await scrollToHighlight(generation: generation)
        }
        .onDisappear {
            highlightClearTask?.cancel()
            highlightClearTask = nil
        }
        .imagePreview(item: $previewImages)
    }

    private func threadComposer(composer: ComposerCapture) -> some View {
        CollapsibleComposer(
            text: composerText(for: composer),
            pictures: composerPictures(for: composer),
            placeholder: CommentComposerBar.replyPlaceholder(
                to: thread.replyTarget?.member.uname ?? rootComment.member.uname
            ),
            replyBanner: thread.replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: thread.isSending,
            sendError: composerCanInteract(composer) ? thread.sendError : nil,
            focus: composerFocus,
            onCancelReply: {
                guard composerCanInteract(composer) else { return }
                composer.store.cancelReply(in: composer.source)
                composerFocus.dismiss()
            },
            onSend: { sendReply(from: composer) },
            uploadScope: composerUploadScope(for: composer),
            isInteractionCurrent: { composerCanInteract(composer) },
            expansion: $isComposerExpanded
        )
    }

    private func threadHeaderItems(composer: ComposerCapture) -> [UIKitCommentFeedItem] {
        let rootItem = UIKitCommentFeedItem(
            id: "thread-root-\(rootComment.rpid)",
            fingerprint: UIKitCommentItemFingerprint(rootComment)
        ) {
            CommentThreadRootRow(
                comment: rootComment,
                upMid: upMid,
                onReply: { _ in beginReply(to: nil, from: composer) },
                onImageTap: { item in previewImages = item },
                onAvatarTap: onAvatarTap
            )
        }
        let subheaderFingerprint = ThreadSubheaderFingerprint(
            replyTotal: rootComment.rcount + thread.postedCount
        )
        let subheaderItem = UIKitCommentFeedItem(
            id: "thread-replies-header",
            fingerprint: subheaderFingerprint
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle()
                    .fill(AppFill.nested)
                    .frame(height: 8)
                    .padding(.horizontal, -AppSpacing.l)
                HStack(spacing: 6) {
                    Text("Thread Replies")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("\(rootComment.rcount + thread.postedCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
        }
        return [rootItem, subheaderItem]
    }

    @ViewBuilder
    private func threadFooterView(hasMore: Bool) -> some View {
        if thread.commentsClosed {
            ContentUnavailableView("Replies are unavailable", systemImage: "bubble.left.and.bubble.right")
        } else {
            CommentLoadFeedbackView(
                feedback: thread.loadFeedback,
                isLoading: thread.isLoading,
                isEmpty: thread.replies.isEmpty,
                hasMore: hasMore,
                retry: retryReplies
            )
        }
    }

    private func retryReplies() {
        guard let request = thread.prepareRetry(in: threadContext) else { return }
        Task { await thread.perform(request) }
    }

    private func replyRow(
        _ reply: CommentResult.CommentItem,
        composer: ComposerCapture
    ) -> some View {
        CommentThreadReplyRow(
            reply: reply,
            upMid: upMid,
            isRegularWidth: isRegularWidth,
            commentsClosed: thread.commentsClosed,
            onAvatarTap: openProfile,
            onBeginReply: AuthManager.shared.isLoggedIn ? { beginReply(to: reply, from: composer) } : nil,
            onDelete: { thread.removeReply(rpid: reply.rpid) }
        )
    }

    // MARK: - In-place reply composer

    private func beginReply(to target: CommentResult.CommentItem?, from captured: ComposerCapture) {
        guard composerCanInteract(captured) else { return }
        captured.store.beginReply(to: target, in: captured.source)
        composerFocus.request()
        if !isComposerExpanded {
            withAnimation(motion.animation(normal: CollapsibleComposer.composerExpandAnimation)) {
                isComposerExpanded = true
            }
        }
    }
}

private extension CommentThreadView {
    private var composerCapture: ComposerCapture {
        ComposerCapture(store: thread, source: threadContext, context: thread.composerContext)
    }

    private func composerIsCurrent(_ captured: ComposerCapture) -> Bool {
        thread === captured.store && oid == captured.source.oid && type == captured.source.type
            && rootComment.rpid == captured.source.root.rpid
            && captured.store.composerIsCurrent(in: captured.source, expected: captured.context)
    }

    private func composerCanInteract(_ captured: ComposerCapture) -> Bool {
        composerIsCurrent(captured) && !captured.store.commentsClosed
    }

    private func composerUploadScope(for captured: ComposerCapture) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: captured.store.commentUpload, context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: {
                captured.store.imageSelectionWasAdmitted(in: captured.source, expected: captured.context)
            }
        )
    }

    private func composerText(for captured: ComposerCapture) -> Binding<String> {
        Binding(get: { captured.store.commentText }, set: { value in
            guard composerIsCurrent(captured) else { return }
            captured.store.commentText = value
        })
    }

    private func composerPictures(for captured: ComposerCapture) -> Binding<[ComposedPicture]> {
        Binding(get: { captured.store.commentPictures }, set: { value in
            guard composerIsCurrent(captured) else { return }
            captured.store.commentPictures = value
        })
    }

    private func sendReply(from captured: ComposerCapture) {
        guard composerCanInteract(captured) else { return }
        captured.store.sendReply(in: captured.source, expectedComposer: captured.context) {
            guard composerIsCurrent(captured) else { return }
            composerFocus.dismiss()
            withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                isComposerExpanded = false
            }
        }
    }

    private enum HighlightExit: String {
        case found
        case targetIsRoot = "target-is-root"
        case endOfThread = "eof"
        case cancelled
        case superseded
        case unavailable
        case repeatedResponse = "repeated-page"
        case noProgress = "no-progress"
        case requestFailed = "request-failed"
    }

    private func scrollToHighlight(generation: UInt64) async {
        guard !didScrollToHighlight, let target = highlightRpid else { return }
        didScrollToHighlight = true
        guard highlightMayContinue(generation: generation, target: target, pages: 0, detail: nil) else { return }

        guard target != rootComment.rpid else {
            logHighlight(.targetIsRoot, target: target, pages: 0, detail: nil)
            return
        }

        var pagesFetched = 0
        var consecutiveStalls = 0
        var lastSignature: String?
        var repeatedSignatures = 0

        while !thread.replies.contains(where: { $0.rpid == target }) {
            guard highlightMayContinue(
                generation: generation, target: target, pages: pagesFetched, detail: lastSignature
            ) else { return }
            if let total = thread.totalReplies, thread.replies.count >= total {
                logHighlight(.endOfThread, target: target, pages: pagesFetched,
                             detail: "loaded=\(thread.replies.count)/\(total)")
                return
            }

            let outcome = await thread.loadMore(in: threadContext)
            guard highlightMayContinue(
                generation: generation, target: target, pages: pagesFetched, detail: lastSignature
            ) else { return }

            switch outcome {
            case .failed, .cancelled, .superseded, .closed:
                logHighlight(highlightExit(for: outcome), target: target, pages: pagesFetched,
                             detail: lastSignature)
                return

            case .skipped:
                consecutiveStalls += 1

            case .advanced(let signature), .stalled(let signature):
                pagesFetched += 1
                if case .advanced = outcome {
                    consecutiveStalls = 0
                } else {
                    consecutiveStalls += 1
                }
                guard !isRepeat(signature, of: &lastSignature, count: &repeatedSignatures) else {
                    logHighlight(.repeatedResponse, target: target,
                                 pages: pagesFetched, detail: signature)
                    return
                }
            }

            guard consecutiveStalls <= Self.highlightStallTolerance else {
                logHighlight(.noProgress, target: target, pages: pagesFetched,
                             detail: lastSignature)
                return
            }
            if consecutiveStalls > 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        applyLocatedHighlight(target, generation: generation, pages: pagesFetched, detail: lastSignature)
    }

    private func applyLocatedHighlight(_ target: Int, generation: UInt64, pages: Int, detail: String?) {
        guard highlightMayContinue(generation: generation, target: target, pages: pages, detail: detail) else { return }
        locatedHighlightRpid = target
        highlightedReplyRpid = target
        highlightClearTask?.cancel()
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            highlightedReplyRpid = nil
        }
        logHighlight(.found, target: target, pages: pages, detail: detail)
    }

    private func highlightMayContinue(generation: UInt64, target: Int, pages: Int, detail: String?) -> Bool {
        let exit: HighlightExit?
        if Task.isCancelled {
            exit = .cancelled
        } else if thread.requestGeneration != generation {
            exit = .superseded
        } else if thread.commentsClosed {
            exit = .unavailable
        } else {
            exit = nil
        }
        guard let exit else { return true }
        logHighlight(exit, target: target, pages: pages, detail: detail)
        return false
    }

    private func highlightExit(for outcome: CommentThreadStore.PageLoad) -> HighlightExit {
        switch outcome {
        case .cancelled: .cancelled
        case .superseded: .superseded
        case .closed: .unavailable
        case .failed: .requestFailed
        case .advanced, .stalled, .skipped: .noProgress
        }
    }

    private func isRepeat(
        _ signature: String,
        of last: inout String?,
        count: inout Int
    ) -> Bool {
        if signature == last {
            count += 1
        } else {
            count = 0
        }
        last = signature
        return count >= Self.repeatedResponseTolerance
    }

    private func logHighlight(
        _ exit: HighlightExit,
        target: Int,
        pages: Int,
        detail: String?
    ) {
        PlayerLog.log(
            "[CommentThread] highlight root=\(rootComment.rpid) target=\(target) "
            + "exit=\(exit.rawValue) pages=\(pages) replies=\(thread.replies.count)"
            + (detail.map { " \($0)" } ?? "")
        )
    }

    private static let repeatedResponseTolerance = 2

    private static let highlightStallTolerance = 3
}

private struct ThreadSubheaderFingerprint: Hashable, Sendable {
    let replyTotal: Int
}

private struct ThreadFooterFingerprint: Hashable, Sendable {
    let commentsClosed: Bool
    let hasLoaded: Bool
    let failure: CommentLoadFeedback.Failure?
    let isLoading: Bool
    let isEmpty: Bool
    let hasMore: Bool
}

private struct CommentThreadRootRow: View {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    let onReply: (CommentResult.CommentItem) -> Void
    let onImageTap: (ImagePreviewItem) -> Void
    let onAvatarTap: ((Int) -> Void)?

    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    var body: some View {
        CommentRowView(
            comment: comment,
            upMid: upMid,
            showsInlineReplies: false,
            onReply: onReply,
            onImageTap: onImageTap,
            onAvatarTap: onAvatarTap
        )
        .rowCardColumnWidth(envColumnWidth.flatMap { $0 > 24 ? $0 - 24 : nil })
        .padding(12)
    }
}

private struct CommentThreadReplyRow: View {
    let reply: CommentResult.CommentItem
    let upMid: Int?
    let isRegularWidth: Bool
    let commentsClosed: Bool
    let onAvatarTap: (Int) -> Void
    let onBeginReply: (() -> Void)?
    let onDelete: () -> Void

    @State private var actionState = CommentActionState()

    var body: some View {
        BlockedCollapsible(mid: reply.mid, uname: reply.member.uname) {
            CommentAIFilterRowContainer(comment: reply, upMid: upMid) { aiAssessment, onInspectAI in
                rowBody(aiAssessment: aiAssessment, onInspectAI: onInspectAI)
            }
        }
    }

    private func rowBody(
        aiAssessment: CommentAIAssessment?,
        onInspectAI: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarImage(urlString: reply.member.avatar.httpsURL, size: 30)
                .contentShape(Circle())
                .onTapGesture { onAvatarTap(reply.mid) }

            VStack(alignment: .leading, spacing: 4) {
                CommentAuthorHeader(
                    comment: reply,
                    upMid: upMid,
                    actionState: actionState,
                    onDelete: onDelete,
                    aiAssessment: aiAssessment,
                    onInspectAI: onInspectAI
                )

                EmoteText(
                    message: reply.content.displayMessage,
                    emotes: CommentRowView.emoteMap(reply),
                    links: reply.content.resolvedLinks,
                    font: .app(AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth)),
                    collapsedLineLimit: 6,
                    detectTimestamps: true
                )
                .lineSpacing(2)
                .modifier(TapToReply(action: onBeginReply))
                .padding(.top, 2)
                .padding(.bottom, 3)

                if reply.upAction?.like == true {
                    UPLikedTag()
                }

                if let vote = reply.content.vote, let voteId = vote.id {
                    VoteCardView(voteId: voteId, initialTitle: vote.title)
                }

                HStack(spacing: 20) {
                    CommentLikeButton(comment: reply)
                    if AuthManager.shared.isLoggedIn, !commentsClosed, let onBeginReply {
                        CommentReplyActionButton(action: onBeginReply)
                    }
                    Spacer()
                }
            }
        }
        .commentContextActions(reply, state: actionState, onDelete: onDelete)
    }
}

private struct CommentThreadSurfaceBackground: ViewModifier {
    let isStandalonePage: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isStandalonePage {
            content.appAmbientBrowseBackground()
        } else {
            content
        }
    }
}
