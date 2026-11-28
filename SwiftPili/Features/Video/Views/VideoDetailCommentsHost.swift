import SwiftUI

struct VideoDetailRootToastView: View {
    @AppMotion private var motion
    let model: VideoDetailViewModel
    let commentPresentation: CommentZoomPresentation
    let isWideLayout: Bool
    let showsWideChrome: Bool
    var showsInRoutePortraitImmersive: Bool = false
    var pagerBottomInset: CGFloat = 0
    let stagePresentation: DetailStagePresentation
    let stagePanelWidth: CGFloat
    let hasActiveThread: Bool

    var body: some View {
        VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            let handledByWidePanel = showsWideChrome && stagePresentation == .stage && !hasActiveThread
            let handledByCompactOverlay = !isWideLayout && !showsInRoutePortraitImmersive && commentsPresented
            let visibleToast = (!handledByWidePanel && !handledByCompactOverlay
                && (isWideLayout || showsInRoutePortraitImmersive || !commentsPresented))
                ? model.toast.flatMap { $0.style == .error ? nil : $0 }
                : nil
            let bottomPadding: CGFloat = if showsInRoutePortraitImmersive {
                pagerBottomInset + 132
            } else if showsWideChrome {
                DetailStageLayout.outerMargin
            } else {
                0
            }
            Group {
                if let toast = visibleToast {
                    ToastView(message: toast)
                }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: visibleToast)
            .frame(maxWidth: showsWideChrome ? stagePanelWidth : .infinity)
            .padding(.trailing, showsWideChrome ? DetailStageLayout.outerMargin : 0)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: showsWideChrome ? .trailing : .center)
        }
    }
}

extension VideoDetailView {
    var compactCommentsOverlay: some View {
        CommentZoomContainer(
            presentation: commentPresentation,
            destination: { commentsSurface(bottomInset: pagerBottomInset) },
            onPresentationChanged: { isPresented in
                updatePlayerCondensation()
                if !isPresented {
                    composer.collapse(motion: motion)
                }
            },
            allowsInteractiveDismissal: showThread == nil,
            onDismissed: resetCommentThreadAfterModalDismissal
        )
        .padding(.top, playerVideoHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    func wideCommentPanel(
        model: VideoDetailViewModel,
        geometry: DetailStageLayout.Geometry
    ) -> some View {
        CinematicStagePanel(
            geometry: geometry,
            isStage: stagePresentation == .stage,
            isKeyboardDocked: isKeyboardDocked
        ) {
            commentReplyRegion {
                ZStack(alignment: .top) {
                    wideCommentList(model: model)
                        .transaction(value: stagePresentation) { $0.animation = nil }
                        .allowsHitTesting(showThread == nil)
                        .accessibilityHidden(showThread != nil)
                    VideoDetailComposerDismissScrim(
                        composer: composer,
                        isActive: stagePresentation == .stage && showThread == nil
                    )
                }
                .overlay(alignment: .bottom) {
                    commentFeedbackAndComposer(model: model, isCompactOverlay: false)
                }
            }
        }
    }

    func commentFeedbackAndComposer(
        model: VideoDetailViewModel,
        isCompactOverlay: Bool
    ) -> some View {
        let requestedID = videoID
        let eligible = !player.isFullscreen && AuthManager.shared.isLoggedIn && !model.commentsClosed
        return VideoDetailCommentComposerOverlay(
            composer: composer,
            model: model,
            commentPresentation: commentPresentation,
            requestedVideoID: requestedID,
            isCompactOverlay: isCompactOverlay,
            showsWideChrome: showsWideChrome,
            isWideLayout: isWideLayout,
            stagePresentation: stagePresentation,
            hasActiveThread: showThread != nil,
            isInlineCommentInputEligible: eligible,
            isModelCurrent: { viewModel === model && videoID == requestedID },
            onRevealPostedComment: { postedRpid, target, model, sourceIsCurrent in
                revealAcceptedComment(
                    postedRpid,
                    replyingTo: target,
                    model: model,
                    sourceIsCurrent: sourceIsCurrent
                )
            }
        )
    }

    func commentReplyRegion<Main: View>(@ViewBuilder root: () -> Main) -> some View {
        let target = showThread
        return CommentReplyZoomContainer(
            presentation: replyPresentation,
            root: root(),
            destination: Group {
                if let target { commentThreadInline(target) }
            },
            ownsKeyboardSafeArea: !isWideLayout,
            onDismissed: { finishCommentThreadDismissal(target?.id) }
        )
        .ignoresSafeArea(.container, edges: isWideLayout ? [] : .bottom)
    }

    func commentThreadInline(_ target: CommentThreadTarget) -> some View {
        VStack(spacing: 0) {
            CommentThreadHeader(
                isWideLayout: isWideLayout,
                anchors: replyPresentation.anchors,
                onBack: closeCommentThread,
                onClose: closeComments
            )
            CommentThreadView(
                oid: target.oid,
                rootComment: target.root,
                highlightRpid: target.highlightRpid,
                type: target.type,
                upMid: viewModel.videoInfo?.owner.mid,
                isStandalonePage: false,
                onAvatarTap: { mid in
                    navigateFromCommentThread(to: .userSpace(mid), target: target)
                }
            )
            .id(target.id)
            .modifier(CommentThreadLinkHandoff { url, context in
                openCommentThreadURL(url, context: context, target: target)
            })
            .contentLinks(isCurrent: {
                isActiveVideoRoute && replyPresentation.isPresented && showThread?.id == target.id
                    && composer.replyCommentSource == viewModel.currentCommentSource
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func wideCommentList(model: VideoDetailViewModel) -> some View {
        let source = model.currentCommentSource
        let requestedID = videoID
        let eligible = !player.isFullscreen && AuthManager.shared.isLoggedIn && !model.commentsClosed
        let headerView: AnyView? = model.videoInfo != nil ? AnyView(commentSectionHeader(model: model)) : nil
        let headerFingerprint = model.videoInfo.map { info in
            VideoCommentHeaderFingerprint(
                replyCount: info.stat.reply,
                commentsClosed: model.commentsClosed,
                commentSort: model.commentSort,
                sourceAid: source?.aid,
                sourceGeneration: source?.generation
            )
        }
        return VideoDetailCommentList(
            model: model,
            requestedID: requestedID,
            highlightedRpid: highlightedCommentRpid,
            scrollToRpid: commentTargetRpid,
            headerView: headerView,
            headerFingerprint: headerFingerprint,
            showsInitialVideoSkeletons: false,
            closedTopPadding: 40,
            bottomClearance: eligible
                ? max(120, VideoDetailLayoutMetrics.panelComposerClearance)
                : VideoDetailLayoutMetrics.panelComposerClearance,
            showsScrollIndicators: false,
            actions: commentRowActions,
            unavailableView: nil,
            unavailableFingerprint: nil,
            onRefresh: {
                guard viewModel === model, videoID == requestedID,
                      model.hasCommentSource(for: requestedID),
                      let request = model.prepareCommentRefresh(from: source) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onScrollOffsetChange: nil
        )
        .task(id: commentTargetRpid) {
            guard let target = commentTargetRpid else { return }
            setStagePresentation(.stage)
            highlightedCommentRpid = target
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, highlightedCommentRpid == target else { return }
            highlightedCommentRpid = nil
            commentTargetRpid = nil
        }
    }

    func commentSectionHeader(model: VideoDetailViewModel) -> some View {
        let source = model.currentCommentSource
        return HStack(spacing: 6) {
            Text("Comments").font(.headline)
            if let count = model.videoInfo?.stat.reply, count > 0 {
                Text(FormatUtils.viewCount(count))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if !model.commentsClosed {
                commentSortControl(model: model, capturedSource: source)
            }
        }
        .padding(.vertical, 4)
    }

    func commentPageHeader(model: VideoDetailViewModel) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Comments")
                        .appFont(.sectionTitle)
                        .fontWeight(.semibold)
                    if let count = model.videoInfo?.stat.reply, count > 0 {
                        Text(FormatUtils.viewCount(count))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.commentsClosed {
                    commentSortControl(model: model, capturedSource: model.currentCommentSource)
                        .background(
                            CommentZoomRegion(anchors: commentPresentation.anchors, role: .sortControl)
                                .padding(-4)
                        )
                }
                CommentHeaderCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Close comments",
                    anchors: commentPresentation.anchors,
                    role: .closeControl,
                    action: closeComments
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            Divider()
                .opacity(0.35)
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .background(CommentZoomRegion(anchors: commentPresentation.anchors, role: .header))
    }

    func commentSortControl(
        model: VideoDetailViewModel,
        capturedSource: VideoDetailViewModel.CommentSource? = nil
    ) -> some View {
        let source = capturedSource ?? model.currentCommentSource
        let requestedID = videoID
        return CommentSortBar(selection: model.commentSort) { sort in
            guard viewModel === model, videoID == requestedID,
                  model.hasCommentSource(for: requestedID),
                  model.currentCommentSource == source,
                  let request = model.prepareCommentSort(sort, from: source) else { return }
            Task { await model.performCommentRequest(request) }
        }
    }

    func commentsSurface(bottomInset: CGFloat) -> some View {
        ObservedModel(viewModel) { model in
            commentReplyRegion {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        commentPageHeader(model: model)
                        commentsPageList(bottomInset: bottomInset, model: model)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                    .allowsHitTesting(showThread == nil)
                    .accessibilityHidden(showThread != nil)
                    VideoDetailComposerDismissScrim(
                        composer: composer,
                        isActive: showThread == nil
                    )
                }
                .overlay(alignment: .bottom) {
                    commentFeedbackAndComposer(model: model, isCompactOverlay: true)
                }
            }
            .background {
                CommentZoomContentSurface()
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
    }

    func commentsPageList(
        bottomInset: CGFloat, model: VideoDetailViewModel
    ) -> some View {
        let source = model.currentCommentSource
        let requestedID = videoID
        let eligible = !player.isFullscreen && AuthManager.shared.isLoggedIn && !model.commentsClosed
        let unavailableMessage = (model.videoInfo == nil && !model.isLoading) ? model.error : nil
        let unavailableFingerprint = unavailableMessage.map { message in
            VideoUnavailableFingerprint(
                message: message,
                symbolName: model.unavailability?.symbolName ?? "exclamationmark.triangle",
                isRetryable: model.unavailability?.isRetryable ?? true
            )
        }
        return VideoDetailCommentList(
            model: model,
            requestedID: requestedID,
            highlightedRpid: highlightedCommentRpid,
            scrollToRpid: commentTargetRpid,
            headerView: nil,
            headerFingerprint: nil,
            showsInitialVideoSkeletons: true,
            closedTopPadding: 60,
            bottomClearance: (eligible ? 120 : 0)
                + bottomInset + VideoDetailLayoutMetrics.contentBottomPadding,
            showsScrollIndicators: true,
            actions: commentRowActions,
            unavailableView: unavailableMessage.map { message in
                AnyView(VideoDetailUnavailableStateView(
                    message: message,
                    unavailability: model.unavailability,
                    onRetry: { Task { await activateIfNeeded(settlesNavigationAdmission: false) } }
                ))
            },
            unavailableFingerprint: unavailableFingerprint,
            onRefresh: {
                guard viewModel === model, videoID == requestedID,
                      model.hasCommentSource(for: requestedID),
                      let request = model.prepareCommentRefresh(from: source) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onScrollOffsetChange: { offset in
                recordPageOffsets([1: offset])
            }
        )
        .task(id: commentTargetRpid) {
            guard let target = commentTargetRpid else { return }
            highlightedCommentRpid = target
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, highlightedCommentRpid == target else { return }
            highlightedCommentRpid = nil
            commentTargetRpid = nil
        }
    }

    var commentRowActions: VideoDetailCommentRowActions {
        VideoDetailCommentRowActions(
            isRouteActive: { isActiveVideoRoute },
            currentVideoID: { videoID },
            reply: { target in
                composer.beginReply(
                    to: target,
                    aid: viewModel.videoInfo?.aid ?? 0,
                    motion: motion
                )
            },
            openThread: { target in
                openCommentThread(target)
            },
            previewImages: { item in previewImages = item }
        )
    }

    func openComments() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        if isWideLayout { setStagePresentation(.stage) }
        commentPresentation.isPresented = true
        if showThread != nil { replyPresentation.isPresented = true }
    }

    func closeComments() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        composer.collapse(motion: motion)
        if commentPresentation.isPresented {
            commentPresentation.isPresented = false
        } else {
            let threadID = showThread?.id
            replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
        }
    }

    func resetCommentThreadAfterModalDismissal() {
        guard !commentPresentation.isPresented else { return }
        updatePlayerCondensation()
        replyPresentation.cancelPendingAction()
        replyPresentation.isPresented = false
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    func openCommentThread(_ target: CommentThreadTarget) {
        guard let source = viewModel.currentCommentSource,
              source.aid == target.oid, target.type == 1 else { return }
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        commentLinkLifetime.invalidate()
        coordinator.contentLinks.cancel()
        composer.collapse(motion: motion)
        replyPresentation.anchors.sourceProvider = { nil }
        composer.replyCommentSource = source
        showThread = target
        replyPresentation.isPresented = true
    }

    func closeCommentThread() {
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        let threadID = showThread?.id
        replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
    }

    func finishCommentThreadDismissal(_ threadID: CommentThreadTarget.Identity?) {
        guard !replyPresentation.isPresented, showThread?.id == threadID else { return }
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    func openCommentThreadURL(
        _ url: URL, context: ContentLinkContext, target: CommentThreadTarget
    ) -> OpenURLAction.Result {
        guard let origin = coordinator.contentLinkOrigin(context) else { return .discarded }
        coordinator.contentLinks.open(url, context: origin) { route in
            origin.beforeNavigate()
            navigateFromCommentThread(to: route, target: target)
        }
        return .handled
    }

    func navigateFromCommentThread(to route: Route, target: CommentThreadTarget) {
        let model = viewModel
        let requestedID = videoID
        guard isActiveVideoRoute, replyPresentation.isPresented, showThread?.id == target.id,
              let source = model.currentCommentSource, source == composer.replyCommentSource,
              source.aid == target.oid, target.type == 1,
              model.hasCommentSource(for: requestedID) else { return }
        let navigationRevision = coordinator.contentLinkNavigationRevision
        let accountRevision = AccountManager.shared.identityRevision
        commentPresentation.cancelPendingAction()
        replyPresentation.cancelPendingAction()
        composer.collapse(motion: motion)
        replyPresentation.dismissThenPerform {
            finishCommentThreadDismissal(target.id)
            commentPresentation.dismissThenPerform {
                guard isActiveVideoRoute, viewModel === model, videoID == requestedID,
                      model.currentCommentSource == source, model.hasCommentSource(for: requestedID),
                      coordinator.contentLinkNavigationRevision == navigationRevision,
                      AccountManager.shared.identityRevision == accountRevision else { return }
                coordinator.navigate(to: route)
            }
        }
    }

    func revealAcceptedComment(
        _ postedRpid: Int,
        replyingTo target: CommentResult.CommentItem?,
        model: VideoDetailViewModel,
        sourceIsCurrent: () -> Bool
    ) {
        guard sourceIsCurrent(), isActiveVideoRoute,
              let source = model.currentCommentSource else { return }
        openComments()
        if let target {
            let root = model.comments.first(where: { $0.rpid == target.rpid }) ?? target
            openCommentThread(CommentThreadTarget(
                oid: source.aid, type: 1, root: root, highlightRpid: postedRpid
            ))
        } else if model.comments.contains(where: { $0.rpid == postedRpid }) {
            commentTargetRpid = postedRpid
        }
    }

    func makePortraitFullscreenCommentsSheet() -> PortraitFullscreenCommentsSheet {
        let model = viewModel
        let requestedID = videoID
        let coordinator = coordinator
        return PortraitFullscreenCommentsSheet(
            model: model,
            requestedVideoID: requestedID,
            coordinator: coordinator,
            isRouteActive: { isActiveVideoRoute },
            onNavigateRoute: { route in
                if player.isFullscreen { player.exitFullscreen() }
                coordinator.navigate(to: route)
            },
            onCommentPosted: {
                syncPortraitFullscreenContext()
            }
        )
    }
}

struct PortraitFullscreenCommentsSheet: View {
    @AppMotion private var motion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let model: VideoDetailViewModel
    let requestedVideoID: VideoID
    let coordinator: AppCoordinator
    let isRouteActive: @MainActor () -> Bool
    let onNavigateRoute: @MainActor (Route) -> Void
    let onCommentPosted: @MainActor () -> Void

    @State private var commentPresentation = CommentZoomPresentation()
    @State private var replyPresentation = CommentZoomPresentation()
    @State private var composer = VideoCommentComposerState()
    @State private var showThread: CommentThreadTarget?
    @State private var commentTargetRpid: Int?
    @State private var highlightedCommentRpid: Int?
    @State private var previewImages: ImagePreviewItem?
    @State private var commentLinkLifetime = ContentLinkLifetime()
    @State private var selectedDetent: PresentationDetent = .medium

    private var isComposerEligible: Bool {
        AuthManager.shared.isLoggedIn && !model.commentsClosed
    }

    private var usesRegularPadFormSheet: Bool {
        guard DeviceCapability.supportsPadFormSheetPresentation else { return false }
        let windowClass = AppWindowMetrics.current?.traitCollection.horizontalSizeClass ?? .unspecified
        if windowClass != .unspecified {
            return windowClass == .regular
        }
        return horizontalSizeClass == .regular
    }

    var body: some View {
        adaptiveDetentPresentation(
            NavigationStack {
                ObservedModel(model) { observedModel in
                    replyRegion(model: observedModel) {
                        ZStack(alignment: .top) {
                            commentList(model: observedModel)
                                .allowsHitTesting(showThread == nil)
                                .accessibilityHidden(showThread != nil)
                            VideoDetailComposerDismissScrim(
                                composer: composer,
                                isActive: showThread == nil
                            )
                        }
                        .overlay(alignment: .bottom) {
                            feedbackAndComposer(model: observedModel)
                        }
                    }
                }
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .environment(coordinator)
            .imagePreview(item: $previewImages)
            .accentContentBoundary()
        )
        .onAppear {
            commentPresentation.isPresented = true
        }
        .onChange(of: composer.isExpanded) { _, expanded in
            guard expanded, !usesRegularPadFormSheet, selectedDetent != .large else { return }
            withAnimation(motion.animation(normal: .snappy(duration: 0.25))) {
                selectedDetent = .large
            }
        }
        .onChange(of: model.currentCommentSource) { _, source in
            composer.collapseImmediatelyIfSourceCleared(source)
            if let showThread,
               showThread.type != 1
                || showThread.oid != source?.aid
                || composer.replyCommentSource != source {
                replyPresentation.cancelPendingAction()
                replyPresentation.isPresented = false
                self.showThread = nil
                composer.replyCommentSource = nil
                replyPresentation.anchors.sourceProvider = nil
            }
        }
        .onDisappear {
            commentPresentation.isPresented = false
            composer.collapse(motion: motion)
        }
    }

    @ViewBuilder
    private func adaptiveDetentPresentation<Content: View>(_ content: Content) -> some View {
        if usesRegularPadFormSheet {
            content
                .appAdaptiveSheet(padSizing: .form)
        } else {
            content
                .presentationDetents([.medium, .large], selection: $selectedDetent)
                .presentationDragIndicator(.visible)
        }
    }

    private func replyRegion<Main: View>(
        model: VideoDetailViewModel,
        @ViewBuilder root: () -> Main
    ) -> some View {
        let target = showThread
        return CommentReplyZoomContainer(
            presentation: replyPresentation,
            root: root(),
            destination: Group {
                if let target { commentThreadInline(target, model: model) }
            },
            ownsKeyboardSafeArea: true,
            onDismissed: { finishCommentThreadDismissal(target?.id) }
        )
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func commentThreadInline(
        _ target: CommentThreadTarget,
        model: VideoDetailViewModel
    ) -> some View {
        VStack(spacing: 0) {
            CommentThreadHeader(
                isWideLayout: true,
                anchors: replyPresentation.anchors,
                onBack: closeCommentThread,
                onClose: { dismiss() }
            )
            CommentThreadView(
                oid: target.oid,
                rootComment: target.root,
                highlightRpid: target.highlightRpid,
                type: target.type,
                upMid: model.videoInfo?.owner.mid,
                isStandalonePage: false,
                onAvatarTap: { mid in
                    navigateFromSheet(to: .userSpace(mid))
                }
            )
            .id(target.id)
            .modifier(CommentThreadLinkHandoff { url, context in
                openCommentThreadURL(url, context: context)
            })
            .contentLinks(isCurrent: {
                isRouteActive() && replyPresentation.isPresented && showThread?.id == target.id
                    && composer.replyCommentSource == model.currentCommentSource
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func commentList(model: VideoDetailViewModel) -> some View {
        let source = model.currentCommentSource
        let eligible = AuthManager.shared.isLoggedIn && !model.commentsClosed
        let headerView: AnyView? = model.videoInfo != nil ? AnyView(commentHeader(model: model)) : nil
        let headerFingerprint = model.videoInfo.map { info in
            VideoCommentHeaderFingerprint(
                replyCount: info.stat.reply,
                commentsClosed: model.commentsClosed,
                commentSort: model.commentSort,
                sourceAid: source?.aid,
                sourceGeneration: source?.generation
            )
        }
        return VideoDetailCommentList(
            model: model,
            requestedID: requestedVideoID,
            highlightedRpid: highlightedCommentRpid,
            scrollToRpid: commentTargetRpid,
            headerView: headerView,
            headerFingerprint: headerFingerprint,
            showsInitialVideoSkeletons: false,
            closedTopPadding: 40,
            bottomClearance: eligible ? 120 : 32,
            showsScrollIndicators: true,
            actions: rowActions,
            unavailableView: nil,
            unavailableFingerprint: nil,
            onRefresh: {
                guard model.hasCommentSource(for: requestedVideoID),
                      let request = model.prepareCommentRefresh(from: source) else { return false }
                await model.performCommentRequest(request)
                return false
            },
            onScrollOffsetChange: nil
        )
        .task(id: commentTargetRpid) {
            guard let target = commentTargetRpid else { return }
            highlightedCommentRpid = target
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, highlightedCommentRpid == target else { return }
            highlightedCommentRpid = nil
            commentTargetRpid = nil
        }
    }

    private func commentHeader(model: VideoDetailViewModel) -> some View {
        let source = model.currentCommentSource
        return HStack(spacing: 6) {
            if let count = model.videoInfo?.stat.reply, count > 0 {
                Text(FormatUtils.viewCount(count))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if !model.commentsClosed {
                CommentSortBar(selection: model.commentSort) { sort in
                    guard model.hasCommentSource(for: requestedVideoID),
                          model.currentCommentSource == source,
                          let request = model.prepareCommentSort(sort, from: source) else { return }
                    Task { await model.performCommentRequest(request) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func feedbackAndComposer(model: VideoDetailViewModel) -> some View {
        let visibleToast = model.toast.flatMap { $0.style == .error ? nil : $0 }
        let showsInput = showThread == nil && isComposerEligible
        return VStack(spacing: 10) {
            Group {
                if let toast = visibleToast {
                    ToastView(message: toast)
                }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: visibleToast)

            if showsInput {
                VideoDetailCommentComposerBar(
                    composer: composer,
                    model: model,
                    commentPresentation: commentPresentation,
                    requestedVideoID: requestedVideoID,
                    usesFeedWidth: DeviceCapability.supportsPadDetailSplit,
                    ignoresContainerBottomSafeArea: !usesRegularPadFormSheet,
                    showsCommentInput: { presented in
                        presented && showThread == nil && isComposerEligible
                    },
                    isModelCurrent: { model.hasCommentSource(for: requestedVideoID) },
                    onRevealPostedComment: { postedRpid, target, postedModel, sourceIsCurrent in
                        guard sourceIsCurrent(),
                              let source = postedModel.currentCommentSource else { return }
                        onCommentPosted()
                        if let target {
                            let root = postedModel.comments.first(where: { $0.rpid == target.rpid }) ?? target
                            openCommentThread(CommentThreadTarget(
                                oid: source.aid, type: 1, root: root, highlightRpid: postedRpid
                            ))
                        } else if postedModel.comments.contains(where: { $0.rpid == postedRpid }) {
                            commentTargetRpid = postedRpid
                        }
                    }
                )
            }
        }
    }

    private var rowActions: VideoDetailCommentRowActions {
        VideoDetailCommentRowActions(
            isRouteActive: isRouteActive,
            currentVideoID: { requestedVideoID },
            reply: { target in
                composer.beginReply(
                    to: target,
                    aid: model.videoInfo?.aid ?? 0,
                    motion: motion
                )
            },
            openThread: { target in
                openCommentThread(target)
            },
            previewImages: { item in previewImages = item }
        )
    }

    private func openCommentThread(_ target: CommentThreadTarget) {
        guard let source = model.currentCommentSource,
              source.aid == target.oid, target.type == 1 else { return }
        replyPresentation.cancelPendingAction()
        commentLinkLifetime.invalidate()
        coordinator.contentLinks.cancel()
        composer.collapse(motion: motion)
        replyPresentation.anchors.sourceProvider = { nil }
        composer.replyCommentSource = source
        showThread = target
        replyPresentation.isPresented = true
    }

    private func closeCommentThread() {
        replyPresentation.cancelPendingAction()
        let threadID = showThread?.id
        replyPresentation.dismissThenPerform { finishCommentThreadDismissal(threadID) }
    }

    private func finishCommentThreadDismissal(_ threadID: CommentThreadTarget.Identity?) {
        guard !replyPresentation.isPresented, showThread?.id == threadID else { return }
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil
    }

    private func openCommentThreadURL(
        _ url: URL,
        context: ContentLinkContext
    ) -> OpenURLAction.Result {
        guard let origin = coordinator.contentLinkOrigin(context) else { return .discarded }
        coordinator.contentLinks.open(url, context: origin) { route in
            origin.beforeNavigate()
            navigateFromSheet(to: route)
        }
        return .handled
    }

    private func navigateFromSheet(to route: Route) {
        composer.collapse(motion: motion)
        dismiss()
        onNavigateRoute(route)
    }
}

private struct CommentThreadLinkHandoff: ViewModifier {
    @Environment(\.contentLinkContext) private var context
    @Environment(\.openURL) private var upstream
    let open: @MainActor (URL, ContentLinkContext) -> OpenURLAction.Result

    func body(content: Content) -> some View {
        content
            .environment(\.contentLinkDefersToParent, true)
            .environment(\.openURL, OpenURLAction { url in
                if BiliURLParser.handlesContent(url) {
                    guard let context else { return .discarded }
                    return open(url, context)
                }
                upstream(url)
                return .handled
            })
    }
}
