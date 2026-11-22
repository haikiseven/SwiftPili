import SwiftUI

/// Native reader for column articles (专栏): parsed content blocks with a
/// banner/title/author header, article like, and the full comment section
/// (stickers, @mentions, image attachments). Falls back to a stripped-down
/// web renderer only if native parsing yields nothing, so an article is
/// always readable.
struct ArticleReaderView: View {
    let cvid: Int
    @State private var viewModel = ArticleReaderViewModel()
    @State private var previewImages: ImagePreviewItem?
    /// The like request the user started is running: only a turn-on during it
    /// plays the bounce/haptic.
    @State private var likeInFlight = false
    @State private var commentText = ""
    @State private var commentPictures: [ComposedPicture] = []
    @State private var commentSubmission = CommentComposerSubmission()
    @State private var acceptedCommentClear: CommentComposerCapture?
    @State private var replyTarget: CommentResult.CommentItem?
    @State private var showThread: CommentThreadTarget?
    @State private var commentFocus = CommentComposerFocus()
    @State private var commentLinkLifetime = ContentLinkLifetime()
    /// Actual detail container: iPad landscape does not consistently report a
    /// compact vertical size class.
    @State private var containerSize = (AppWindowMetrics.current?.bounds ?? UIScreen.main.bounds).size
    @Environment(AppCoordinator.self) private var coordinator

    private var usesSplit: Bool {
        DetailSplitPolicy.usesSplit(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            containerSize: containerSize
        )
    }

    private struct CommentComposerCapture {
        let model: ArticleReaderViewModel
        let requestedCvid: Int
        let source: ArticleReaderViewModel.CommentSourceReceipt?
        let context: CommentComposerUploadOwner.Context
    }

    private var articleURL: URL {
        URL(string: "https://www.bilibili.com/read/cv\(cvid)")!
    }

    var body: some View {
        Group {
            if viewModel.parseFailed, !viewModel.isLoading {
                webFallback
            } else {
                nativeReader
            }
        }
        .appAmbientBrowseBackground()
        .navigationTitle(viewModel.info?.title ?? String(localized: "Article"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: articleURL) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.primary)
                }
            }
        }
        .task { await viewModel.load(cvid: cvid) }
    }

    // MARK: - Native reader

    private var nativeReader: some View {
        let composer = commentComposerCapture
        let model = composer.model
        let showsComments = !model.blocks.isEmpty && !model.commentsClosed
        let composerVisible = AuthManager.shared.isLoggedIn && showsComments
        return Group {
            if usesSplit {
                articleSplit(composer: composer, composerVisible: composerVisible)
            } else {
                commentFeed(
                    composer: composer,
                    headerItems: articleHeaderItems(composer: composer),
                    layout: .singleColumn(composerVisible: composerVisible)
                )
                .overlay(alignment: .bottom) {
                    if composerVisible { commentComposer(for: composer) }
                }
            }
        }
        .detailContainerSize { size in
            if containerSize != size { containerSize = size }
        }
        .contentLinks(presentsFeedback: false, handlesURLs: true, isCurrent: {
            composer.source != nil
                && viewModel === model
                && cvid == composer.requestedCvid
                && model.commentSource(for: composer.requestedCvid) == composer.source
        })
        .sheet(item: $showThread) { root in
            threadSheet(for: root)
        }
        .imagePreview(item: $previewImages)
    }

    private func threadSheet(for root: CommentThreadTarget) -> some View {
        NavigationStack {
            CommentThreadView(
                oid: root.oid,
                rootComment: root.root,
                highlightRpid: root.highlightRpid,
                type: root.type,
                upMid: viewModel.info?.mid,
                onAvatarTap: { mid in
                    showThread = nil
                    coordinator.navigate(to: .userSpace(mid))
                }
            )
            .id(root.id)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showThread = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.primary)
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        .appAdaptiveSheet(padSizing: .page)
        .dismissingSheetOnBiliLink(coordinator: coordinator) { showThread = nil }
    }

    private func commentComposer(for composer: CommentComposerCapture) -> some View {
        CollapsibleComposer(
            text: commentTextBinding(for: composer),
            pictures: commentPicturesBinding(for: composer),
            placeholder: replyTarget.map { CommentComposerBar.replyPlaceholder(to: $0.member.uname) }
                ?? String(localized: "Write a comment..."),
            replyBanner: replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: commentSubmission.isSending,
            sendError: composerIsCurrent(composer) ? viewModel.commentSendError : nil,
            focus: commentFocus,
            onCancelReply: {
                guard composerIsCurrent(composer) else { return }
                setCommentReplyTarget(nil, for: composer)
                commentFocus.dismiss()
            },
            onSend: { sendComment(from: composer) },
            allowsCollapseAfterSend: allowsCollapseAfterCommentSend,
            uploadScope: commentUploadScope(for: composer),
            isInteractionCurrent: { composerIsCurrent(composer) }
        )
    }

    private func articleHeaderItems(composer: CommentComposerCapture) -> [UIKitCommentFeedItem] {
        let model = composer.model
        var headerItems: [UIKitCommentFeedItem] = []
        let headerFP = ArticleHeaderFingerprint(
            title: model.info?.title,
            bannerURL: model.info?.bannerUrl,
            authorName: model.info?.authorName,
            views: model.info?.stats?.view
        )
        headerItems.append(UIKitCommentFeedItem(id: "article-header", fingerprint: headerFP) {
            ArticleWidthCell { width in
                ArticleReaderHeader(info: model.info, availableWidth: width) {
                    if let mid = model.info?.mid { coordinator.navigate(to: .userSpace(mid)) }
                }
            }
        })
        for item in model.indexedBlocks {
            headerItems.append(UIKitCommentFeedItem(
                id: "article-block-\(item.id)",
                fingerprint: ArticleBlockFingerprint(block: item.block, imageIndex: item.imageIndex)
            ) {
                ArticleWidthCell { width in
                    ArticleBlockView(block: item.block, availableWidth: width) {
                        previewImages = ImagePreviewItem(urls: model.imageURLs, index: item.imageIndex ?? 0)
                    }
                }
            })
        }
        if model.isLoading, model.blocks.isEmpty {
            headerItems.append(UIKitCommentFeedItem(id: "article-loading", fingerprint: 0) {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 60)
            })
        }
        if !model.blocks.isEmpty {
            let actionsFP = ArticleActionsFingerprint(
                liked: model.liked, likeInFlight: likeInFlight, likeCount: model.likeCount
            )
            headerItems.append(UIKitCommentFeedItem(id: "article-actions", fingerprint: actionsFP) {
                actionRow
            })
            let commentsHeaderFP = ArticleCommentsHeaderFingerprint(
                commentTotal: model.commentTotal
            )
            headerItems.append(UIKitCommentFeedItem(id: "article-comments-header", fingerprint: commentsHeaderFP) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    commentHeader(for: composer)
                }
            })
        }
        return headerItems
    }

    private func articleFooterState(
        model: ArticleReaderViewModel, showsInitialSkeletons: Bool
    ) -> ArticleFooterFingerprint? {
        guard !model.blocks.isEmpty else { return nil }
        if model.commentsClosed {
            return ArticleFooterFingerprint(
                commentsClosed: true, isLoading: false, isEmpty: false, hasLoaded: true, failure: nil
            )
        }
        guard !showsInitialSkeletons else { return nil }
        let needsFeedback = model.isLoadingComments || model.commentFeedback.failure != nil || model.comments.isEmpty
        guard needsFeedback else { return nil }
        return ArticleFooterFingerprint(
            commentsClosed: false,
            isLoading: model.isLoadingComments,
            isEmpty: model.comments.isEmpty,
            hasLoaded: model.commentFeedback.hasLoaded,
            failure: model.commentFeedback.failure
        )
    }

    @ViewBuilder
    private func articleFooterView(
        for state: ArticleFooterFingerprint,
        composer: CommentComposerCapture,
        receipt: ArticleReaderViewModel.CommentListReceipt?
    ) -> some View {
        if state.commentsClosed {
            ContentUnavailableView("Comments are turned off", systemImage: "exclamationmark.bubble")
        } else {
            commentFeedback(for: composer, receipt: receipt)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    likeInFlight = true
                    await viewModel.toggleLike()
                    likeInFlight = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .appToggleFeedback(isOn: viewModel.liked, userActionInFlight: likeInFlight)
                    Text(FormatUtils.viewCount(viewModel.likeCount))
                        .monospacedDigit()
                        .appCountFeedback(value: viewModel.likeCount)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(viewModel.liked ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    viewModel.liked
                        ? AnyShapeStyle(Color.biliAccent.opacity(0.14))
                        : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: Capsule()
                )
            }
            .buttonStyle(.appControl)

            ShareLink(item: articleURL) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.appControl)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Web fallback

    private var webFallback: some View {
        ArticleWebView(url: articleURL)
            .ignoresSafeArea(edges: .bottom)
    }
}

private extension ArticleReaderView {
    private func commentRow(_ comment: CommentResult.CommentItem, composer: CommentComposerCapture) -> some View {
        let model = composer.model
        let requestedCvid = composer.requestedCvid
        let source = composer.source
        return CommentRowView(
            comment: comment,
            upMid: model.info?.mid,
            onReply: { target in
                guard composerIsCurrent(composer) else { return }
                setCommentReplyTarget(target, for: composer)
                commentFocus.request()
            },
            onViewThread: { root in
                openCommentThread(root, composer: composer)
            },
            onOpenReply: { root, rpid in
                openCommentThread(root, highlightRpid: rpid, composer: composer)
            },
            onImageTap: { item in
                guard composerIsCurrent(composer) else { return }
                previewImages = item
            },
            onDelete: {
                guard let source, viewModel === model, cvid == requestedCvid,
                      model.commentSource(for: requestedCvid) == source else { return }
                model.comments.removeAll { $0.rpid == comment.rpid }
            }
        )
    }

    private func commentHeader(for composer: CommentComposerCapture) -> some View {
        let model = composer.model
        return HStack(spacing: AppSpacing.s) {
            Text("Comments")
                .appFont(.sectionTitle)
                .foregroundStyle(.primary)
            if model.commentTotal > 0 {
                Text(FormatUtils.viewCount(model.commentTotal))
                    .appFont(.controlLabel, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.s)
        }
    }

    private func openCommentThread(
        _ root: CommentResult.CommentItem, highlightRpid: Int? = nil,
        composer: CommentComposerCapture
    ) {
        guard composerIsCurrent(composer) else { return }
        let target = CommentThreadTarget(
            oid: composer.requestedCvid, type: 12, root: root, highlightRpid: highlightRpid
        )
        commentLinkLifetime.invalidate()
        coordinator.contentLinks.cancel()
        showThread = target
    }

    private func commentFeedback(
        for composer: CommentComposerCapture, receipt: ArticleReaderViewModel.CommentListReceipt?
    ) -> some View {
        let model = composer.model
        let requestedCvid = composer.requestedCvid
        let source = composer.source
        return CommentLoadFeedbackView(
            feedback: model.commentFeedback, isLoading: model.isLoadingComments,
            isEmpty: model.comments.isEmpty, retry: {
                guard viewModel === model, cvid == requestedCvid,
                      let source, model.commentSource(for: requestedCvid) == source else { return }
                let request = model.commentFeedback.failure == .pagination
                    ? model.prepareMoreComments(from: receipt) : model.prepareCommentRefresh(from: source)
                if let request { Task { await model.performCommentRequest(request) } }
            }
        )
    }

    private var commentComposerCapture: CommentComposerCapture {
        let model = viewModel
        let requestedCvid = cvid
        return CommentComposerCapture(
            model: model, requestedCvid: requestedCvid,
            source: model.commentSource(for: requestedCvid), context: model.commentComposerContext
        )
    }

    private func composerIsCurrent(_ captured: CommentComposerCapture) -> Bool {
        guard let source = captured.source else { return false }
        return viewModel === captured.model && cvid == captured.requestedCvid
            && captured.model.commentSource(for: captured.requestedCvid) == source
            && captured.model.commentComposerContext == captured.context
    }

    private func commentDraftDidChange() {
        commentSubmission.draftDidChange()
        acceptedCommentClear = nil
    }

    private func commentUploadScope(for captured: CommentComposerCapture) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: captured.model.commentUpload,
            context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: {
                captured.model.clearCommentSendError()
                commentDraftDidChange()
            }
        )
    }

    private func commentTextBinding(for captured: CommentComposerCapture) -> Binding<String> {
        Binding(get: { commentText }, set: { text in
            guard composerIsCurrent(captured) else { return }
            captured.model.clearCommentSendError()
            commentDraftDidChange()
            commentText = text
        })
    }

    private func commentPicturesBinding(for captured: CommentComposerCapture) -> Binding<[ComposedPicture]> {
        Binding(get: { commentPictures }, set: { pictures in
            guard composerIsCurrent(captured), pictures != commentPictures else { return }
            captured.model.clearCommentSendError()
            commentDraftDidChange()
            commentPictures = pictures
        })
    }

    private func setCommentReplyTarget(_ target: CommentResult.CommentItem?, for captured: CommentComposerCapture) {
        guard composerIsCurrent(captured) else { return }
        acceptedCommentClear = nil
        if replyTarget?.rpid != target?.rpid {
            commentSubmission.draftDidChange()
            captured.model.clearCommentSendError()
        }
        replyTarget = target
    }

    private func allowsCollapseAfterCommentSend() -> Bool {
        guard let acceptedCommentClear else { return false }
        return composerIsCurrent(acceptedCommentClear)
    }

    private func sendComment(from captured: CommentComposerCapture) {
        guard !Task.isCancelled, composerIsCurrent(captured),
              !captured.model.commentUpload.isUploading, let source = captured.source else { return }
        let msg = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !commentPictures.isEmpty,
              let attempt = commentSubmission.begin() else { return }
        captured.model.clearCommentSendError()
        acceptedCommentClear = nil
        let target = replyTarget
        let pictures = commentPictures
        let model = captured.model
        Task {
            defer { commentSubmission.finish(attempt) }
            guard !Task.isCancelled, composerIsCurrent(captured) else { return }
            let accepted = await model.postComment(
                message: msg,
                root: target?.rpid,
                parent: target?.rpid,
                pictures: pictures,
                expectedSource: source
            )
            guard accepted, !Task.isCancelled, composerIsCurrent(captured),
                  commentSubmission.canApply(attempt) else { return }
            commentTextBinding(for: captured).wrappedValue = ""
            commentPicturesBinding(for: captured).wrappedValue = []
            setCommentReplyTarget(nil, for: captured)
            model.commentDraftWasReplaced()
            commentFocus.dismiss()
            acceptedCommentClear = commentComposerCapture
        }
    }
}

private struct ArticleHeaderFingerprint: Hashable, Sendable {
    let title, bannerURL, authorName: String?
    let views: Int?
}

private struct ArticleBlockFingerprint: Hashable, Sendable {
    let block: ArticleBlock
    let imageIndex: Int?
}

private struct ArticleActionsFingerprint: Hashable, Sendable {
    let liked, likeInFlight: Bool
    let likeCount: Int
}

private struct ArticleCommentsHeaderFingerprint: Hashable, Sendable {
    let commentTotal: Int
}

private struct ArticleFooterFingerprint: Hashable, Sendable {
    let commentsClosed, isLoading, isEmpty, hasLoaded: Bool
    let failure: CommentLoadFeedback.Failure?
}

private struct ArticleWidthCell<Content: View>: View {
    @ViewBuilder let content: (CGFloat?) -> Content
    @Environment(\.rowCardColumnWidth) private var columnWidth

    var body: some View { content(columnWidth) }
}

// MARK: - Comment feed and iPad landscape split

/// Spacing and clearance of the comment feed in one layout mode.
private struct ArticleFeedLayout {
    var maxContentWidth: CGFloat?
    var horizontalInset: CGFloat
    var bottomClearance: CGFloat
    var ignoresBottomSafeArea: Bool
    var headerSpacing: CGFloat
    var topInset: CGFloat

    static func singleColumn(composerVisible: Bool) -> ArticleFeedLayout {
        ArticleFeedLayout(
            maxContentWidth: ReadableWidth.feed,
            horizontalInset: AppSpacing.l,
            bottomClearance: composerVisible ? 88 : AppSpacing.l,
            ignoresBottomSafeArea: true,
            headerSpacing: 14,
            topInset: AppSpacing.m
        )
    }

    static func companion(composerVisible: Bool) -> ArticleFeedLayout {
        ArticleFeedLayout(
            maxContentWidth: nil,
            horizontalInset: 20,
            bottomClearance: composerVisible ? 96 : AppSpacing.l,
            ignoresBottomSafeArea: false,
            headerSpacing: 14,
            topInset: AppSpacing.m
        )
    }
}

private extension ArticleReaderView {
    /// The comment list, shared by the single-column page (with the article as
    /// header items) and the split companion panel (comments only).
    private func commentFeed(
        composer: CommentComposerCapture,
        headerItems: [UIKitCommentFeedItem],
        layout: ArticleFeedLayout
    ) -> some View {
        let model = composer.model
        let receipt = model.commentListReceipt
        let source = composer.source
        let requestedCvid = composer.requestedCvid
        let showsComments = !model.blocks.isEmpty && !model.commentsClosed
        let showsInitialSkeletons = showsComments && model.isLoadingComments && model.comments.isEmpty
        let visibleComments = CommentAIFilterEngine.shared.visibleComments(
            from: model.comments,
            upMid: model.info?.mid
        )
        let commentItems: [UIKitCommentFeedItem] = showsComments
            ? visibleComments.map { comment in
                UIKitCommentFeedItem(
                    comment: comment,
                    extraFingerprint: AnyHashableSendable(model.info?.mid)
                ) {
                    commentRow(comment, composer: composer)
                }
            }
            : []
        let footerState = articleFooterState(model: model, showsInitialSkeletons: showsInitialSkeletons)
        let footerView = footerState.map {
            AnyView(articleFooterView(for: $0, composer: composer, receipt: receipt))
        }
        return UIKitCommentFeedCollectionView(
            headerItems: headerItems,
            items: commentItems,
            footerContent: footerView,
            footerFingerprint: footerState.map(AnyHashableSendable.init),
            skeletonCount: showsInitialSkeletons ? 6 : 0,
            showsItemDividers: true,
            dividerLeadingInset: 48,
            itemSpacing: AppSpacing.l,
            headerSpacing: layout.headerSpacing,
            horizontalInset: layout.horizontalInset,
            topInset: layout.topInset,
            maxContentWidth: layout.maxContentWidth,
            bottomClearance: layout.bottomClearance,
            ignoresBottomSafeArea: layout.ignoresBottomSafeArea,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: {
                guard viewModel === model, cvid == requestedCvid,
                      let currentSource = model.commentSource(for: requestedCvid),
                      let request = model.prepareCommentRefresh(from: currentSource) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onWillDisplayItemAt: { _ in
                guard viewModel === model, cvid == requestedCvid, let source,
                      model.commentSource(for: requestedCvid) == source,
                      let request = model.prepareMoreComments(from: receipt) else { return }
                Task { await model.performCommentRequest(request) }
            }
        )
    }

    /// Left: the article in its own scroll column. Right: a floating panel with
    /// the comments header, the comment list and the composer.
    private func articleSplit(composer: CommentComposerCapture, composerVisible: Bool) -> some View {
        let model = composer.model
        let showsCompanion = !model.blocks.isEmpty
        let contentWidth = DetailCompanionSplitLayout<EmptyView, EmptyView>
            .primaryContentWidth(containerWidth: containerSize.width, showsCompanion: showsCompanion)
        return DetailCompanionSplitLayout(
            containerWidth: containerSize.width,
            showsCompanion: showsCompanion
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                ArticleReaderHeader(info: model.info, availableWidth: contentWidth) {
                    if let mid = model.info?.mid { coordinator.navigate(to: .userSpace(mid)) }
                }
                ForEach(model.indexedBlocks) { item in
                    ArticleBlockView(block: item.block, availableWidth: contentWidth) {
                        previewImages = ImagePreviewItem(urls: model.imageURLs, index: item.imageIndex ?? 0)
                    }
                }
                if model.isLoading, model.blocks.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 60)
                }
                if !model.blocks.isEmpty { actionRow }
            }
        } companion: {
            if showsCompanion {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        commentHeader(for: composer)
                            .padding(.horizontal, 20)
                            .padding(.top, AppSpacing.l)
                            .padding(.bottom, AppSpacing.m)
                        Divider()
                            .opacity(0.35)
                    }
                    commentFeed(
                        composer: composer,
                        headerItems: [],
                        layout: .companion(composerVisible: composerVisible)
                    )
                }
                .overlay(alignment: .bottom) {
                    if composerVisible { commentComposer(for: composer) }
                }
            }
        }
    }
}
