import Observation
import SwiftUI

struct MomentDetailView: View {
    let dynamicId: String
    @State private var viewModel = MomentDetailViewModel()
    @State private var previewImages: ImagePreviewItem?
    @State private var showRepost = false
    @State private var composerState = MomentCommentComposerState()
    @State private var replyState = InlineCommentReplyState()
    @State private var section: InteractionSection = .comments

    enum InteractionSection: CaseIterable, Hashable {
        case comments, forwards, likes
    }

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var containerSize = WindowMetricsFallback.currentSize

    private var usesSplit: Bool {
        DetailSplitPolicy.usesSplit(
            isRegularWidth: horizontalSizeClass == .regular,
            containerSize: containerSize
        )
    }

    var body: some View {
        let model = viewModel
        let requestedID = dynamicId
        let source = viewModel.readyCommentSource
        let showsComposer = AuthManager.shared.isLoggedIn && viewModel.oid != nil && !viewModel.commentsClosed
        let comments = section == .comments ? visibleComments : []
        Group {
            if usesSplit {
                splitContent(source: source, showsComposer: showsComposer, visibleComments: comments)
            } else {
                MomentDetailCollectionView(
                    input: makeSnapshotInput(visibleComments: comments, showsComposer: showsComposer),
                    item: viewModel.item,
                    comments: comments,
                    forwards: viewModel.forwards,
                    reactions: viewModel.reactions,
                    liked: viewModel.liked,
                    likeCount: viewModel.likeCount,
                    actions: makeCollectionActions(source: source)
                )
                .overlay(alignment: .bottom) {
                    if showsComposer {
                        MomentCommentComposerOverlay(
                            viewModel: model,
                            dynamicId: requestedID,
                            state: composerState
                        )
                    }
                }
            }
        }
        .detailContainerSize { size in
            if containerSize != size { containerSize = size }
        }
        .contentLinks(presentsFeedback: false, isCurrent: {
            viewModel === model && dynamicId == requestedID
        })
        .appAmbientBrowseBackground()
        .navigationTitle("Moment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: dynamicId) {
            await viewModel.load(dynamicId: dynamicId)
            PlayerLog.log(
                "[MomentDetail] load finished: item=\(viewModel.item != nil) comments=\(viewModel.comments.count) "
                    + "additional=\(viewModel.item?.modules?.moduleDynamic?.additional?.type ?? "none")"
            )
        }
        .sheet(item: compactThreadBinding) { root in
            threadSheet(for: root)
        }
        .onChange(of: usesSplit) { _, wide in
            replyState.adaptPresentation(isInline: wide)
        }
        .onChange(of: dynamicId) { _, _ in
            replyState.reset()
        }
        .sheet(isPresented: $showRepost) {
            if let item = viewModel.item {
                RepostSheet(item: item) { text in
                    await viewModel.repost(content: text)
                }
            }
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
                upMid: viewModel.authorMid,
                onAvatarTap: { mid in
                    replyState.reset()
                    coordinator.navigate(to: .userSpace(mid))
                }
            )
            .id(root.id)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        replyState.reset()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.primary)
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        .appAdaptiveSheet(padSizing: .page)
        .dismissingSheetOnBiliLink(coordinator: coordinator) { replyState.reset() }
    }

    private var interactionsHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                sectionSelector
                Spacer(minLength: 8)
                if section == .comments, let source = viewModel.readyCommentSource {
                    CommentSortBar(selection: viewModel.commentSort) { sort in
                        guard viewModel.readyCommentSource == source else { return }
                        Task {
                            guard viewModel.readyCommentSource == source else { return }
                            await viewModel.setCommentSort(sort)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 2)

            Divider()
                .opacity(0.35)
                .padding(.bottom, 10)
        }
    }

    private var visibleComments: [CommentResult.CommentItem] {
        CommentAIFilterEngine.shared.visibleComments(
            from: viewModel.comments,
            upMid: viewModel.authorMid
        )
    }

    private var isInitialCommentsLoading: Bool {
        section == .comments
            && !viewModel.commentsClosed && viewModel.oid != nil
            && viewModel.isLoadingComments && viewModel.comments.isEmpty
    }

    private func makeSnapshotInput(
        visibleComments: [CommentResult.CommentItem],
        showsComposer: Bool
    ) -> MomentDetailSnapshotInput {
        let cardFP = viewModel.item.map { item in
            let stat = item.modules?.moduleStat
            return MomentDetailSnapshotInput.CardFingerprint(
                id: item.id,
                liked: viewModel.liked,
                likeCount: viewModel.likeCount,
                commentCount: stat?.comment?.count,
                forwardCount: stat?.forward?.count
            )
        }
        let headerFP = MomentDetailSnapshotInput.HeaderFingerprint(
            section: section,
            commentSort: viewModel.commentSort,
            hasCommentSource: viewModel.readyCommentSource != nil,
            commentTotal: viewModel.commentTotal,
            forwardCount: viewModel.forwardCount,
            likeCount: viewModel.likeCount,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        return MomentDetailSnapshotInput(
            dynamicID: dynamicId,
            section: section,
            stateFingerprint: .init(isLoading: viewModel.isLoading, error: viewModel.error),
            cardFingerprint: cardFP,
            headerFingerprint: headerFP,
            commentFingerprints: section == .comments
                ? visibleComments.map { UIKitCommentItemFingerprint($0) }
                : [],
            forwardIDs: section == .forwards ? viewModel.forwards.map(\.id) : [],
            reactionIDs: section == .likes ? viewModel.reactions.map(\.id) : [],
            footerFingerprint: currentFooterFingerprint,
            showsReactionBanner: section == .likes && AuthManager.shared.isLoggedIn
                && viewModel.reactionsHaveUnclassifiedActions,
            skeletonCount: isInitialCommentsLoading ? 6 : 0,
            composerClearance: showsComposer ? 88 : 0
        )
    }

    private var currentFooterFingerprint: MomentDetailSnapshotInput.FooterFingerprint? {
        switch section {
        case .comments:
            let hasFooter = viewModel.commentsClosed
                || viewModel.oid == nil
                || (viewModel.isLoadingComments && !viewModel.comments.isEmpty)
                || viewModel.commentFeedback.failure != nil
                || (!viewModel.isLoadingComments && viewModel.comments.isEmpty)
            guard hasFooter else { return nil }
            return .comments(.init(
                closed: viewModel.commentsClosed,
                hasOID: viewModel.oid != nil,
                loading: viewModel.isLoadingComments,
                empty: viewModel.comments.isEmpty,
                loaded: viewModel.commentFeedback.hasLoaded,
                failure: viewModel.commentFeedback.failure
            ))
        case .forwards:
            let hasFooter = viewModel.isLoadingForwards
                || viewModel.forwardFailure != nil
                || (viewModel.forwardsLoaded && viewModel.forwardsHaveMore)
                || viewModel.forwards.isEmpty
            guard hasFooter else { return nil }
            return .forwards(.init(
                loading: viewModel.isLoadingForwards,
                loaded: viewModel.forwardsLoaded,
                haveMore: viewModel.forwardsHaveMore,
                empty: viewModel.forwards.isEmpty,
                failure: viewModel.forwardFailure,
                count: viewModel.forwardCount,
                reported: viewModel.forwardReportedTotal
            ))
        case .likes:
            let loggedIn = AuthManager.shared.isLoggedIn
            let hasFooter = !loggedIn
                || viewModel.isLoadingReactions
                || viewModel.reactionFailure != nil
                || viewModel.reactionsNeedContinuation
                || viewModel.reactions.isEmpty
            guard hasFooter else { return nil }
            return .likes(.init(
                loggedIn: loggedIn,
                loading: viewModel.isLoadingReactions,
                loaded: viewModel.reactionsLoaded,
                haveMore: viewModel.reactionsHaveMore,
                needCont: viewModel.reactionsNeedContinuation,
                unclassified: viewModel.reactionsHaveUnclassifiedActions,
                empty: viewModel.reactions.isEmpty,
                failure: viewModel.reactionFailure,
                count: viewModel.likeCount,
                reported: viewModel.reactionReportedTotal
            ))
        }
    }

    private func makeCollectionActions(
        source: MomentDetailViewModel.CommentSourceReceipt?
    ) -> MomentDetailCollectionActions {
        let model = viewModel
        let requestedID = dynamicId
        let lineage = viewModel.commentListLineage
        let thread = (viewModel.oid ?? 0, viewModel.commentType)
        return MomentDetailCollectionActions(
            onRefresh: { await refreshSelectedSection(); return false },
            onLoadMoreComments: {
                guard source != nil, viewModel.readyCommentSource == source,
                      lineage == viewModel.commentListLineage else { return }
                Task {
                    guard viewModel.readyCommentSource == source,
                          lineage == viewModel.commentListLineage else { return }
                    await viewModel.loadMoreComments()
                }
            },
            onLoadMoreForwards: { Task { await viewModel.loadMoreForwards() } },
            onLoadMoreReactions: {
                guard !viewModel.reactionsNeedContinuation else { return }
                Task { await viewModel.loadMoreReactions() }
            },
            onOpenPost: { id in coordinator.navigate(to: .momentDetail(id)) },
            onOpenProfile: { mid in coordinator.navigate(to: .userSpace(mid)) },
            onOpenVideo: { target in coordinator.navigateToVideo(target) },
            onOpenArticle: { cvid in coordinator.navigate(to: .articleReader(cvid)) },
            onOpenLiveRoom: { roomID in coordinator.navigate(to: .liveRoom(roomID)) },
            onImageTap: { previewItem in previewImages = previewItem },
            onRepost: { showRepost = true },
            onFocusComment: {
                guard isComposerSourceActive(model: model, requestedID: requestedID, source: source) else { return }
                composerState.commentFocus.request()
            },
            onToggleLike: { Task { await viewModel.toggleLike() } },
            makeStateView: { AnyView(momentStateView) },
            makeHeaderView: { AnyView(interactionsHeader) },
            makeCommentRow: { comment in
                AnyView(commentRow(comment, model: model, requestedID: requestedID, source: source, thread: thread))
            },
            makeForwardRow: { forward in
                AnyView(MomentForwardRow(
                    forward: forward,
                    openPost: { id in coordinator.navigate(to: .momentDetail(id)) },
                    openProfile: { mid in coordinator.navigate(to: .userSpace(mid)) }
                ))
            },
            makeReactionRow: { entry in
                AnyView(MomentReactionRow(
                    reaction: entry.item,
                    openProfile: { mid in coordinator.navigate(to: .userSpace(mid)) }
                ))
            },
            makeReactionBanner: { AnyView(reactionUnclassifiedBanner) },
            makeFooterView: { AnyView(sectionFooterView(source: source, lineage: lineage)) }
        )
    }

    @ViewBuilder
    private var momentStateView: some View {
        if viewModel.isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.top, 60)
        } else if let error = viewModel.error {
            ContentUnavailableView {
                Label("Couldn't Load Moment", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    Task { await viewModel.load(dynamicId: dynamicId) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 24)
        }
    }

    @ViewBuilder
    private func sectionFooterView(
        source: MomentDetailViewModel.CommentSourceReceipt?,
        lineage: UUID?
    ) -> some View {
        switch section {
        case .comments:
            if viewModel.commentsClosed {
                ContentUnavailableView("Comments are turned off", systemImage: "exclamationmark.bubble")
                    .padding(.vertical, 12)
            } else if viewModel.oid == nil {
                Text("This post does not expose a comment thread.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                commentFeedback(source: source, lineage: lineage)
            }
        case .forwards:
            forwardsFooter
        case .likes:
            likesFooter
        }
    }

    private var sectionBinding: Binding<InteractionSection> {
        Binding(get: { section }, set: { selectSection($0) })
    }

    private func selectSection(_ target: InteractionSection) {
        guard section != target else { return }
        section = target
        switch target {
        case .forwards where !viewModel.forwardsLoaded:
            Task { await viewModel.loadMoreForwards() }
        case .likes where !viewModel.reactionsLoaded && AuthManager.shared.isLoggedIn:
            Task { await viewModel.loadMoreReactions() }
        default: break
        }
    }

    private func refreshSelectedSection() async {
        switch section {
        case .comments:
            await viewModel.refreshComments(from: viewModel.readyCommentSource)
        case .forwards:
            await viewModel.refreshForwards()
        case .likes:
            await viewModel.refreshReactions()
        }
    }

    private func sectionLabel(_ target: InteractionSection) -> (name: LocalizedStringKey, total: Int) {
        switch target {
        case .comments: ("Comments", viewModel.commentTotal)
        case .forwards: ("Reposts", viewModel.forwardCount)
        case .likes: ("Post Likes", viewModel.likeCount)
        }
    }

    private var sectionSelector: some View {
        MomentInteractionSelector(
            selection: sectionBinding,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            label: sectionLabel
        )
    }

    private func isComposerSourceActive(
        model: MomentDetailViewModel,
        requestedID: String,
        source: MomentDetailViewModel.CommentSourceReceipt?
    ) -> Bool {
        guard let source else { return false }
        return viewModel === model
            && dynamicId == requestedID
            && model.commentSource(for: requestedID) == source
            && !model.commentsClosed
            && AuthManager.shared.isLoggedIn
            && AuthManager.shared.sessionGeneration == composerState.commentSessionGeneration
    }

    private func commentRow(
        _ comment: CommentResult.CommentItem,
        model: MomentDetailViewModel,
        requestedID: String,
        source: MomentDetailViewModel.CommentSourceReceipt?,
        thread: (oid: Int, type: Int)
    ) -> some View {
        CommentRowView(
            comment: comment,
            upMid: model.authorMid,
            onReply: { target in
                guard source != nil, model.readyCommentSource == source,
                      isComposerSourceActive(model: model, requestedID: requestedID, source: source) else { return }
                composerState.beginReply(target, model: model)
            },
            onViewThread: { root in
                openCommentThread(root, source: source, thread: thread)
            },
            onOpenReply: { root, rpid in
                openCommentThread(root, highlightRpid: rpid, source: source, thread: thread)
            },
            onImageTap: { item in
                openCommentImages(item, source: source)
            },
            onAvatarTap: { mid in
                guard source != nil, viewModel.readyCommentSource == source else { return }
                coordinator.navigate(to: .userSpace(mid))
            },
            onDelete: {
                guard source != nil, viewModel.readyCommentSource == source else { return }
                viewModel.removeComment(rpid: comment.rpid)
            }
        )
    }

    private func openCommentThread(
        _ root: CommentResult.CommentItem, highlightRpid: Int? = nil,
        source: MomentDetailViewModel.CommentSourceReceipt?, thread: (oid: Int, type: Int)
    ) {
        guard source != nil, viewModel.readyCommentSource == source else { return }
        let target = CommentThreadTarget(
            oid: thread.oid, type: thread.type, root: root, highlightRpid: highlightRpid
        )
        coordinator.contentLinks.cancel()
        composerState.commentFocus.dismiss()
        replyState.open(target, presentInline: usesSplit)
    }

    private func openCommentImages(
        _ item: ImagePreviewItem, source: MomentDetailViewModel.CommentSourceReceipt?
    ) {
        guard source != nil, viewModel.readyCommentSource == source else { return }
        previewImages = item
    }

    private func commentFeedback(
        source: MomentDetailViewModel.CommentSourceReceipt?, lineage: UUID?
    ) -> some View {
        CommentLoadFeedbackView(
            feedback: viewModel.commentFeedback, isLoading: viewModel.isLoadingComments,
            isEmpty: viewModel.comments.isEmpty, retry: {
                Task {
                    guard viewModel.readyCommentSource == source else { return }
                    if viewModel.commentFeedback.failure == .pagination,
                       viewModel.commentListLineage == lineage {
                        await viewModel.loadMoreComments()
                    } else {
                        await viewModel.refreshComments(from: source)
                    }
                }
            }
        )
    }
}

@MainActor
@Observable
private final class MomentCommentComposerState {
    struct Capture {
        let model: MomentDetailViewModel
        let requestedID: String
        let source: MomentDetailViewModel.CommentSourceReceipt?
        let context: CommentComposerUploadOwner.Context
    }

    var commentText = ""
    var commentPictures: [ComposedPicture] = []
    var commentSubmission = CommentComposerSubmission()
    @ObservationIgnored let commentSessionGeneration = AuthManager.shared.sessionGeneration
    @ObservationIgnored var acceptedCommentClear: Capture?
    var replyTarget: CommentResult.CommentItem?
    @ObservationIgnored let commentFocus = CommentComposerFocus()

    func draftDidChange() {
        commentSubmission.draftDidChange()
        acceptedCommentClear = nil
    }

    func beginReply(_ target: CommentResult.CommentItem, model: MomentDetailViewModel) {
        acceptedCommentClear = nil
        if replyTarget?.rpid != target.rpid {
            commentSubmission.draftDidChange()
            model.clearCommentSendError()
        }
        replyTarget = target
        commentFocus.request()
    }
}

private struct MomentCommentComposerOverlay: View {
    let viewModel: MomentDetailViewModel
    let dynamicId: String
    let state: MomentCommentComposerState
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

    private var currentCapture: MomentCommentComposerState.Capture {
        MomentCommentComposerState.Capture(
            model: viewModel,
            requestedID: dynamicId,
            source: viewModel.commentSource(for: dynamicId),
            context: viewModel.commentComposerContext
        )
    }

    private func composerIsCurrent(_ captured: MomentCommentComposerState.Capture) -> Bool {
        guard let source = captured.source else { return false }
        return viewModel === captured.model && dynamicId == captured.requestedID
            && captured.model.commentSource(for: captured.requestedID) == source
            && captured.model.commentComposerContext == captured.context
            && !captured.model.commentsClosed && AuthManager.shared.isLoggedIn
            && AuthManager.shared.sessionGeneration == state.commentSessionGeneration
    }

    private func commentUploadScope(
        for captured: MomentCommentComposerState.Capture
    ) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: captured.model.commentUpload, context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: {
                captured.model.clearCommentSendError()
                state.draftDidChange()
            }
        )
    }

    private func commentTextBinding(for captured: MomentCommentComposerState.Capture) -> Binding<String> {
        Binding(get: { state.commentText }, set: { text in
            guard composerIsCurrent(captured) else { return }
            captured.model.clearCommentSendError()
            state.draftDidChange()
            state.commentText = text
        })
    }

    private func commentPicturesBinding(
        for captured: MomentCommentComposerState.Capture
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
        for captured: MomentCommentComposerState.Capture
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

    private func sendComment(from captured: MomentCommentComposerState.Capture) {
        guard !Task.isCancelled, composerIsCurrent(captured),
              !captured.model.commentUpload.isUploading, let source = captured.source else { return }
        let msg = state.commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !state.commentPictures.isEmpty, let attempt = state.commentSubmission.begin() else { return }
        captured.model.clearCommentSendError()
        state.acceptedCommentClear = nil
        let target = state.replyTarget
        let pictures = state.commentPictures
        Task {
            defer { state.commentSubmission.finish(attempt) }
            guard !Task.isCancelled, composerIsCurrent(captured) else { return }
            let accepted = await captured.model.postComment(
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
            captured.model.commentDraftWasReplaced()
            state.commentFocus.dismiss()
            state.acceptedCommentClear = currentCapture
        }
    }
}

private extension MomentDetailView {
    @ViewBuilder
    private var forwardsFooter: some View {
        if viewModel.isLoadingForwards {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 16)
        } else if let failure = viewModel.forwardFailure {
            interactionFailure(
                failure == .pagination ? "Couldn't load more reposts." : "Couldn't load reposts."
            ) {
                Task {
                    if failure == .pagination, viewModel.forwardsHaveMore {
                        await viewModel.loadMoreForwards()
                    } else {
                        await viewModel.refreshForwards()
                    }
                }
            }
        } else if viewModel.forwardsLoaded, viewModel.forwardsHaveMore {
            Button("Load More Reposts") {
                Task { await viewModel.loadMoreForwards() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if viewModel.forwards.isEmpty, viewModel.forwardsLoaded,
                  viewModel.forwardCount > 0
                    || (viewModel.forwardReportedTotal ?? 0) > 0
                    || (!viewModel.hasKnownForwardCount && viewModel.forwardReportedTotal == nil) {
            MomentInteractionUnavailableState(
                title: "Reposts Unavailable",
                message: "No visible repost participants were returned.",
                systemImage: "arrowshape.turn.up.right",
                actionTitle: "Retry",
                action: { Task { await viewModel.refreshForwards() } }
            )
            .padding(.vertical, 20)
        } else if viewModel.forwards.isEmpty, viewModel.forwardsLoaded {
            Text("No reposts yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    private var reactionUnclassifiedBanner: some View {
        Label(
            "Other interactions are not shown in this likes list.",
            systemImage: "questionmark.bubble"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var likesFooter: some View {
        if !AuthManager.shared.isLoggedIn {
            MomentInteractionUnavailableState(
                title: "Sign In Required",
                message: "Sign in to view likes.",
                systemImage: "person.crop.circle.badge.exclamationmark",
                actionTitle: "Sign In",
                action: { coordinator.presentLogin() }
            )
            .padding(.vertical, 12)
        } else if viewModel.isLoadingReactions {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 16)
        } else if let failure = viewModel.reactionFailure {
            interactionFailure(
                failure == .pagination ? "Couldn't load more likes." : "Couldn't load likes."
            ) {
                Task {
                    if failure == .pagination {
                        await viewModel.loadMoreReactions(
                            continuing: viewModel.reactionsNeedContinuation
                        )
                    } else {
                        await viewModel.refreshReactions()
                    }
                }
            }
        } else if viewModel.reactionsNeedContinuation {
            Button("Continue Loading") {
                Task { await viewModel.loadMoreReactions(continuing: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if viewModel.reactions.isEmpty, viewModel.reactionsLoaded,
                  viewModel.reactionsHaveMore {
            Button("Continue Loading") {
                Task { await viewModel.loadMoreReactions() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if viewModel.reactions.isEmpty, viewModel.reactionsLoaded,
                  !viewModel.reactionsHaveMore, viewModel.reactionsHaveUnclassifiedActions {
            if viewModel.likeCount > 0 || (viewModel.reactionReportedTotal ?? 0) > 0 {
                Button("Retry") { Task { await viewModel.refreshReactions() } }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        } else if viewModel.reactions.isEmpty, viewModel.reactionsLoaded,
                  !viewModel.reactionsHaveMore,
                  viewModel.likeCount > 0
                    || (viewModel.reactionReportedTotal ?? 0) > 0
                    || (!viewModel.hasKnownLikeCount && viewModel.reactionReportedTotal == nil) {
            MomentInteractionUnavailableState(
                title: "Likes Unavailable",
                message: "No visible like participants were returned.",
                systemImage: "person.2",
                actionTitle: "Retry",
                action: { Task { await viewModel.refreshReactions() } }
            )
            .padding(.vertical, 20)
        } else if viewModel.reactions.isEmpty, viewModel.reactionsLoaded,
                  !viewModel.reactionsHaveMore {
            Text("No likes yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    func interactionFailure(_ message: LocalizedStringKey, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "exclamationmark.bubble")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - iPad landscape split

private extension MomentDetailView {
    private func splitContent(
        source: MomentDetailViewModel.CommentSourceReceipt?,
        showsComposer: Bool,
        visibleComments: [CommentResult.CommentItem]
    ) -> some View {
        let actions = makeCollectionActions(source: source)
        return DetailCompanionSplitLayout(
            containerWidth: containerSize.width,
            showsCompanion: viewModel.item != nil
        ) {
            splitPrimary(actions: actions)
        } companion: {
            if viewModel.item != nil {
                splitCompanion(actions: actions, showsComposer: showsComposer, visibleComments: visibleComments)
            }
        }
    }

    @ViewBuilder
    func splitPrimary(actions: MomentDetailCollectionActions) -> some View {
        if let item = viewModel.item {
            DynamicCardView(
                item: item,
                likeState: (viewModel.liked, viewModel.likeCount),
                expanded: true,
                onImageTap: actions.onImageTap,
                onLike: actions.onToggleLike,
                onComment: actions.onFocusComment,
                onRepost: actions.onRepost
            )
        } else {
            actions.makeStateView()
        }
    }

    private var splitCompanionHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: AppSpacing.s) {
                sectionSelector
                Spacer(minLength: AppSpacing.s)
                if section == .comments, let source = viewModel.readyCommentSource {
                    CommentSortBar(selection: viewModel.commentSort) { sort in
                        guard viewModel.readyCommentSource == source else { return }
                        Task {
                            guard viewModel.readyCommentSource == source else { return }
                            await viewModel.setCommentSort(sort)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, AppSpacing.m)
            .padding(.bottom, AppSpacing.xs)

            Divider()
                .opacity(0.35)
        }
    }

    var compactThreadBinding: Binding<CommentThreadTarget?> {
        Binding(
            get: { usesSplit ? nil : replyState.target },
            set: { next in
                if next == nil, !usesSplit { replyState.reset() }
            }
        )
    }

    func splitCommentThreadInline(_ target: CommentThreadTarget) -> some View {
        VStack(spacing: 0) {
            CommentThreadHeader(
                isWideLayout: true,
                anchors: replyState.presentation.anchors,
                onBack: { replyState.close() },
                onClose: { replyState.close() }
            )
            CommentThreadView(
                oid: target.oid,
                rootComment: target.root,
                highlightRpid: target.highlightRpid,
                type: target.type,
                upMid: viewModel.authorMid,
                isStandalonePage: false,
                onAvatarTap: { mid in
                    coordinator.navigate(to: .userSpace(mid))
                }
            )
            .id(target.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func splitCompanion(
        actions: MomentDetailCollectionActions,
        showsComposer: Bool,
        visibleComments: [CommentResult.CommentItem]
    ) -> some View {
        let target = replyState.target
        let footerFingerprint = currentFooterFingerprint
        return CommentReplyZoomContainer(
            presentation: replyState.presentation,
            root: VStack(spacing: 0) {
                splitCompanionHeader
                UIKitCommentFeedCollectionView(
                    items: splitItems(actions: actions, visibleComments: visibleComments),
                    footerContent: footerFingerprint == nil ? nil : actions.makeFooterView(),
                    footerFingerprint: footerFingerprint.map(AnyHashableSendable.init),
                    skeletonCount: isInitialCommentsLoading ? 6 : 0,
                    showsItemDividers: true,
                    dividerLeadingInset: 48,
                    itemSpacing: AppSpacing.l,
                    horizontalInset: 20,
                    topInset: AppSpacing.m,
                    bottomClearance: showsComposer ? 96 : AppSpacing.l,
                    keyboardDismissMode: .onDrag,
                    thresholdOffset: 4,
                    onRefresh: actions.onRefresh,
                    onWillDisplayItemAt: { _ in
                        switch section {
                        case .comments: actions.onLoadMoreComments()
                        case .forwards: actions.onLoadMoreForwards()
                        case .likes: actions.onLoadMoreReactions()
                        }
                    }
                )
            }
            .allowsHitTesting(replyState.target == nil)
            .accessibilityHidden(replyState.target != nil)
            .overlay(alignment: .bottom) {
                if showsComposer, replyState.target == nil {
                    MomentCommentComposerOverlay(
                        viewModel: viewModel,
                        dynamicId: dynamicId,
                        state: composerState
                    )
                }
            },
            destination: Group {
                if let target { splitCommentThreadInline(target) }
            },
            ownsKeyboardSafeArea: false,
            onDismissed: { replyState.finishDismissal(target?.id) }
        )
    }

    func splitItems(
        actions: MomentDetailCollectionActions,
        visibleComments: [CommentResult.CommentItem]
    ) -> [UIKitCommentFeedItem] {
        switch section {
        case .comments:
            return visibleComments.map { comment in
                UIKitCommentFeedItem(
                    comment: comment,
                    extraFingerprint: AnyHashableSendable(viewModel.authorMid)
                ) {
                    actions.makeCommentRow(comment)
                }
            }
        case .forwards:
            return viewModel.forwards.map { forward in
                UIKitCommentFeedItem(id: forward.id, fingerprint: forward.id) {
                    actions.makeForwardRow(forward)
                }
            }
        case .likes:
            var items: [UIKitCommentFeedItem] = []
            if AuthManager.shared.isLoggedIn, viewModel.reactionsHaveUnclassifiedActions {
                items.append(UIKitCommentFeedItem(id: "reaction-banner", fingerprint: 0) {
                    actions.makeReactionBanner()
                })
            }
            items += viewModel.reactions.map { entry in
                UIKitCommentFeedItem(id: entry.id, fingerprint: entry.id) {
                    actions.makeReactionRow(entry)
                }
            }
            return items
        }
    }
}
