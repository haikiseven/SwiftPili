import Observation
import SwiftUI

struct ArticleReaderView: View {
    let cvid: Int
    @State private var viewModel = ArticleReaderViewModel()
    @State private var previewImages: ImagePreviewItem?
    @State private var showThread: CommentThreadTarget?
    @State private var composerState = ArticleCommentComposerState()
    @State private var containerSize = WindowMetricsFallback.currentSize
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesSplit: Bool {
        DetailSplitPolicy.usesSplit(
            isRegularWidth: horizontalSizeClass == .regular,
            containerSize: containerSize
        )
    }

    private struct ArticleSourceCapture {
        let model: ArticleReaderViewModel
        let requestedCvid: Int
        let source: ArticleReaderViewModel.CommentSourceReceipt?
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
        let capture = sourceCapture
        let model = capture.model
        let requestedCvid = capture.requestedCvid
        let showsComments = !model.blocks.isEmpty && !model.commentsClosed
        let composerVisible = AuthManager.shared.isLoggedIn && showsComments
        return Group {
            if usesSplit {
                articleSplit(capture: capture, composerVisible: composerVisible)
            } else {
                commentFeed(
                    capture: capture,
                    headerItems: articleHeaderItems(capture: capture),
                    layout: .singleColumn(composerVisible: composerVisible)
                )
                .overlay(alignment: .bottom) {
                    if composerVisible {
                        ArticleCommentComposerOverlay(
                            viewModel: model,
                            cvid: requestedCvid,
                            state: composerState
                        )
                    }
                }
            }
        }
        .detailContainerSize { size in
            if containerSize != size { containerSize = size }
        }
        .contentLinks(presentsFeedback: false, handlesURLs: true, isCurrent: {
            viewModel === model && cvid == requestedCvid
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

    private func articleHeaderItems(capture: ArticleSourceCapture) -> [UIKitCommentFeedItem] {
        let model = capture.model
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
            headerItems.append(UIKitCommentFeedItem(id: "article-actions", fingerprint: 0) {
                ArticleActionRow(viewModel: model, articleURL: articleURL)
            })
            let commentsHeaderFP = ArticleCommentsHeaderFingerprint(
                commentTotal: model.commentTotal
            )
            headerItems.append(UIKitCommentFeedItem(id: "article-comments-header", fingerprint: commentsHeaderFP) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    commentHeader(for: capture)
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
        capture: ArticleSourceCapture,
        receipt: ArticleReaderViewModel.CommentListReceipt?
    ) -> some View {
        if state.commentsClosed {
            ContentUnavailableView("Comments are turned off", systemImage: "exclamationmark.bubble")
        } else {
            commentFeedback(for: capture, receipt: receipt)
        }
    }

    // MARK: - Web fallback

    private var webFallback: some View {
        ArticleWebView(url: articleURL)
            .ignoresSafeArea(edges: .bottom)
    }
}

private extension ArticleReaderView {
    private var sourceCapture: ArticleSourceCapture {
        let model = viewModel
        let requestedCvid = cvid
        return ArticleSourceCapture(
            model: model,
            requestedCvid: requestedCvid,
            source: model.commentSource(for: requestedCvid)
        )
    }

    private func sourceIsCurrent(_ capture: ArticleSourceCapture) -> Bool {
        guard let source = capture.source else { return false }
        return viewModel === capture.model
            && cvid == capture.requestedCvid
            && capture.model.commentSource(for: capture.requestedCvid) == source
    }

    private func commentRow(_ comment: CommentResult.CommentItem, capture: ArticleSourceCapture) -> some View {
        let model = capture.model
        let requestedCvid = capture.requestedCvid
        return CommentRowView(
            comment: comment,
            upMid: model.info?.mid,
            onReply: { target in
                guard sourceIsCurrent(capture) else { return }
                composerState.beginReply(target, model: model, requestedCvid: requestedCvid)
            },
            onViewThread: { root in
                openCommentThread(root, capture: capture)
            },
            onOpenReply: { root, rpid in
                openCommentThread(root, highlightRpid: rpid, capture: capture)
            },
            onImageTap: { item in
                guard sourceIsCurrent(capture) else { return }
                previewImages = item
            },
            onDelete: {
                guard sourceIsCurrent(capture) else { return }
                model.comments.removeAll { $0.rpid == comment.rpid }
            }
        )
    }

    private func commentHeader(for capture: ArticleSourceCapture) -> some View {
        let model = capture.model
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
        capture: ArticleSourceCapture
    ) {
        guard sourceIsCurrent(capture) else { return }
        let target = CommentThreadTarget(
            oid: capture.requestedCvid, type: 12, root: root, highlightRpid: highlightRpid
        )
        coordinator.contentLinks.cancel()
        showThread = target
    }

    private func commentFeedback(
        for capture: ArticleSourceCapture, receipt: ArticleReaderViewModel.CommentListReceipt?
    ) -> some View {
        let model = capture.model
        let requestedCvid = capture.requestedCvid
        let source = capture.source
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
}

private struct ArticleActionRow: View {
    let viewModel: ArticleReaderViewModel
    let articleURL: URL
    @State private var likeInFlight = false

    var body: some View {
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
}

@MainActor
@Observable
private final class ArticleCommentComposerState {
    struct Capture {
        let model: ArticleReaderViewModel
        let requestedCvid: Int
        let source: ArticleReaderViewModel.CommentSourceReceipt?
        let context: CommentComposerUploadOwner.Context
    }

    var commentText = ""
    var commentPictures: [ComposedPicture] = []
    var commentSubmission = CommentComposerSubmission()
    @ObservationIgnored var acceptedCommentClear: Capture?
    var replyTarget: CommentResult.CommentItem?
    @ObservationIgnored let commentFocus = CommentComposerFocus()

    func draftDidChange() {
        commentSubmission.draftDidChange()
        acceptedCommentClear = nil
    }

    func beginReply(
        _ target: CommentResult.CommentItem,
        model: ArticleReaderViewModel,
        requestedCvid: Int
    ) {
        guard model.commentSource(for: requestedCvid) != nil else { return }
        acceptedCommentClear = nil
        if replyTarget?.rpid != target.rpid {
            commentSubmission.draftDidChange()
            model.clearCommentSendError()
        }
        replyTarget = target
        commentFocus.request()
    }
}

private struct ArticleCommentComposerOverlay: View {
    let viewModel: ArticleReaderViewModel
    let cvid: Int
    let state: ArticleCommentComposerState
    @AppMotion private var motion

    var body: some View {
        let composer = currentCapture
        CollapsibleComposer(
            text: commentTextBinding(for: composer),
            pictures: commentPicturesBinding(for: composer),
            placeholder: state.replyTarget.map { CommentComposerBar.replyPlaceholder(to: $0.member.uname) }
                ?? String(localized: "Write a comment..."),
            replyBanner: state.replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: state.commentSubmission.isSending,
            sendError: composerIsCurrent(composer) ? viewModel.commentSendError : nil,
            focus: state.commentFocus,
            onCancelReply: {
                guard composerIsCurrent(composer) else { return }
                withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                    setCommentReplyTarget(nil, for: composer)
                }
                state.commentFocus.dismiss()
            },
            onSend: { sendComment(from: composer) },
            allowsCollapseAfterSend: allowsCollapseAfterCommentSend,
            uploadScope: commentUploadScope(for: composer),
            isInteractionCurrent: { composerIsCurrent(composer) }
        )
    }

    private var currentCapture: ArticleCommentComposerState.Capture {
        ArticleCommentComposerState.Capture(
            model: viewModel,
            requestedCvid: cvid,
            source: viewModel.commentSource(for: cvid),
            context: viewModel.commentComposerContext
        )
    }

    private func composerIsCurrent(_ captured: ArticleCommentComposerState.Capture) -> Bool {
        guard let source = captured.source else { return false }
        return viewModel === captured.model && cvid == captured.requestedCvid
            && captured.model.commentSource(for: captured.requestedCvid) == source
            && captured.model.commentComposerContext == captured.context
    }

    private func commentUploadScope(
        for captured: ArticleCommentComposerState.Capture
    ) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: captured.model.commentUpload,
            context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: {
                captured.model.clearCommentSendError()
                state.draftDidChange()
            }
        )
    }

    private func commentTextBinding(for captured: ArticleCommentComposerState.Capture) -> Binding<String> {
        Binding(get: { state.commentText }, set: { text in
            guard composerIsCurrent(captured) else { return }
            captured.model.clearCommentSendError()
            state.draftDidChange()
            state.commentText = text
        })
    }

    private func commentPicturesBinding(
        for captured: ArticleCommentComposerState.Capture
    ) -> Binding<[ComposedPicture]> {
        Binding(get: { state.commentPictures }, set: { pictures in
            guard composerIsCurrent(captured), pictures != state.commentPictures else { return }
            captured.model.clearCommentSendError()
            state.draftDidChange()
            state.commentPictures = pictures
        })
    }

    private func setCommentReplyTarget(
        _ target: CommentResult.CommentItem?,
        for captured: ArticleCommentComposerState.Capture
    ) {
        guard composerIsCurrent(captured) else { return }
        state.acceptedCommentClear = nil
        if state.replyTarget?.rpid != target?.rpid {
            state.commentSubmission.draftDidChange()
            captured.model.clearCommentSendError()
        }
        state.replyTarget = target
    }

    private func allowsCollapseAfterCommentSend() -> Bool {
        guard let accepted = state.acceptedCommentClear else { return false }
        return composerIsCurrent(accepted)
    }

    private func sendComment(from captured: ArticleCommentComposerState.Capture) {
        guard !Task.isCancelled, composerIsCurrent(captured),
              !captured.model.commentUpload.isUploading, let source = captured.source else { return }
        let msg = state.commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !state.commentPictures.isEmpty,
              let attempt = state.commentSubmission.begin() else { return }
        captured.model.clearCommentSendError()
        state.acceptedCommentClear = nil
        let target = state.replyTarget
        let pictures = state.commentPictures
        let model = captured.model
        Task {
            defer { state.commentSubmission.finish(attempt) }
            guard !Task.isCancelled, composerIsCurrent(captured) else { return }
            let accepted = await model.postComment(
                message: msg,
                root: target?.rpid,
                parent: target?.rpid,
                pictures: pictures,
                expectedSource: source
            )
            guard accepted, !Task.isCancelled, composerIsCurrent(captured),
                  state.commentSubmission.canApply(attempt) else { return }
            commentTextBinding(for: captured).wrappedValue = ""
            commentPicturesBinding(for: captured).wrappedValue = []
            setCommentReplyTarget(nil, for: captured)
            model.commentDraftWasReplaced()
            state.commentFocus.dismiss()
            state.acceptedCommentClear = currentCapture
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
    private func commentFeed(
        capture: ArticleSourceCapture,
        headerItems: [UIKitCommentFeedItem],
        layout: ArticleFeedLayout
    ) -> some View {
        let model = capture.model
        let receipt = model.commentListReceipt
        let source = capture.source
        let requestedCvid = capture.requestedCvid
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
                    commentRow(comment, capture: capture)
                }
            }
            : []
        let footerState = articleFooterState(model: model, showsInitialSkeletons: showsInitialSkeletons)
        let footerView = footerState.map {
            AnyView(articleFooterView(for: $0, capture: capture, receipt: receipt))
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

    private func articleSplit(capture: ArticleSourceCapture, composerVisible: Bool) -> some View {
        let model = capture.model
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
                if !model.blocks.isEmpty {
                    ArticleActionRow(viewModel: model, articleURL: articleURL)
                }
            }
        } companion: {
            if showsCompanion {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        commentHeader(for: capture)
                            .padding(.horizontal, 20)
                            .padding(.top, AppSpacing.l)
                            .padding(.bottom, AppSpacing.m)
                        Divider()
                            .opacity(0.35)
                    }
                    commentFeed(
                        capture: capture,
                        headerItems: [],
                        layout: .companion(composerVisible: composerVisible)
                    )
                }
                .overlay(alignment: .bottom) {
                    if composerVisible {
                        ArticleCommentComposerOverlay(
                            viewModel: model,
                            cvid: capture.requestedCvid,
                            state: composerState
                        )
                    }
                }
            }
        }
    }
}
