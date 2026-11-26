import Kingfisher
import SwiftUI
import UIKit

enum UGCSeasonInlineSelectionAction {
    case switchPart(VideoInfo.VideoPage)
    case resumeOrReplayCurrent
    case switchVideoInline(target: VideoRouteTarget, preferredCid: Int?)
}

enum UGCSeasonInlineSelectionPolicy {
    static func resolveSelection(
        episode: VideoInfo.UGCSeason.Episode,
        currentVideoInfo: VideoInfo?,
        currentCid: Int?,
        fallbackOwnerName: String
    ) -> UGCSeasonInlineSelectionAction {
        if let info = currentVideoInfo, episode.aid == info.aid {
            if episode.cid != currentCid,
               let page = info.pages?.first(where: { $0.cid == episode.cid }) {
                return .switchPart(page)
            }
            return .resumeOrReplayCurrent
        }
        let nextTarget = VideoDetailRouteTargetFactory.ugcSeasonTarget(
            for: episode,
            fallbackOwnerName: fallbackOwnerName
        ).withoutZoom
        return .switchVideoInline(
            target: nextTarget,
            preferredCid: episode.cid > 0 ? episode.cid : nil
        )
    }

    static func syncedSeasonQueue(
        existingQueue: PlaybackQueueContext?,
        seasonID: Int,
        aid: Int,
        cid: Int
    ) -> PlaybackQueueContext? {
        guard let existingQueue,
              case .ugcSeason(let existingSeasonId) = existingQueue.kind,
              existingSeasonId == seasonID,
              cid > 0 else {
            return nil
        }
        let synced = existingQueue.selecting(aid: aid, cid: cid)
        return synced != existingQueue ? synced : nil
    }
}

extension VideoDetailView {
    func claimPlayerLeaseIfNeeded() -> PlayerOwnerLease? {
        guard isActiveVideoRoute else { return nil }
        if let existing = viewModel.playerLease, player.isCurrentOwner(existing) {
            return existing
        }
        player.endForeignOwnerForRouteActivation(incomingOwner: screenOwner)
        let lease = player.claimOwnerLease(owner: screenOwner)
        viewModel.adoptPlayerLease(lease)
        return lease
    }

    func activateIfNeeded(settlesNavigationAdmission: Bool) async {
        let navigationTargetID = routeVideoID
        defer {
            if settlesNavigationAdmission {
                if isActiveVideoRoute {
                    coordinator.settleVideoNavigation(navigationTargetID)
                } else {
                    coordinator.cancelVideoNavigation(navigationTargetID)
                }
            }
        }
        guard isActiveVideoRoute, let lease = claimPlayerLeaseIfNeeded() else {
            if !isActiveVideoRoute {
                PlayerLog.log("[Navigation] historical VOD route activation ignored")
            }
            return
        }
        if let activeQueue = player.activePlaylistQueue,
           let activeItem = activeQueue.currentItem,
           player.currentAid == activeItem.aid,
           activeItem.originScreenRoute != .video(videoID) {
            activePlaylistTarget = inlinePlaylistTarget(for: activeItem)
        }
        let requestedID = videoID
        let preferredCid: Int? = {
            guard let activeItem = player.activePlaylistQueue?.currentItem,
                  activeItem.originScreenRoute == .video(requestedID),
                  activeItem.cid > 0 else { return nil }
            return activeItem.cid
        }()
        ensureImmersiveFeedSessionInitialized(preferredCid: preferredCid)
        _ = await viewModel.load(
            id: requestedID,
            preferredCid: preferredCid,
            owner: screenOwner,
            lease: lease,
            initialAspectRatioHint: activeTarget.preview.aspectRatioHint
        )
        PlaylistQueueLauncher.shared.adoptLoadedFirstVideoIfArmed(
            videoInfo: viewModel.videoInfo,
            currentCid: viewModel.currentCid,
            lease: lease,
            player: player
        )
        immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
        immersiveFeedSession.ingestRelatedVideos(viewModel.relatedVideos)
        syncImmersiveViewportReducerMetrics()
        prewarmAdjacentImmersiveCovers()
        installPlaylistSelectionHandlerIfNeeded()
        syncInlinePortraitImmersiveBinding()
        syncPortraitFullscreenContext()
        applyModeDPortraitFullscreenIfNeeded()
        if showsInRoutePortraitImmersive {
            triggerImmersiveRefillIfNeeded(forceSmallPool: true)
        }
        await handlePendingCommentNavigationIfNeeded()
    }

    func installPlaylistSelectionHandlerIfNeeded() {
        guard isActiveVideoRoute,
              let lease = viewModel.playerLease,
              player.isCurrentOwner(lease),
              player.activePlaylistQueue != nil else {
            return
        }
        player.liveQueueItemSelectionHandler = { item in
            guard isActiveVideoRoute,
                  let currentLease = viewModel.playerLease,
                  player.isCurrentOwner(currentLease),
                  !player.isFullscreen,
                  !player.isMiniPlayerActive else {
                return false
            }
            switchToPlaylistItemInline(item, lease: currentLease)
            return true
        }
    }

    func clearPlaylistSelectionHandlerIfOwned() {
        guard let lease = viewModel.playerLease, player.isCurrentOwner(lease) else { return }
        player.liveQueueItemSelectionHandler = nil
    }

    private func inlinePlaylistTarget(for item: PlaybackQueueItem) -> VideoRouteTarget {
        let base = item.playlistRouteTarget
        let resolvedPortrait = base.preview.isPortraitHint ?? item.isPortraitHint
        let resolvedAspect = base.preview.aspectRatioHint ?? item.aspectRatioHint
        guard resolvedPortrait != base.preview.isPortraitHint
            || resolvedAspect != base.preview.aspectRatioHint else {
            return base
        }
        return VideoRouteTarget(
            videoID: base.videoID,
            preview: PortraitPagingPreview(
                title: base.preview.title,
                coverSource: base.preview.coverSource,
                ownerName: base.preview.ownerName,
                durationSeconds: base.preview.durationSeconds,
                isPortraitHint: resolvedPortrait,
                aspectRatioHint: resolvedAspect
            ),
            zoomSourceID: nil
        )
    }

    func switchToPlaylistItemInline(_ item: PlaybackQueueItem, lease: PlayerOwnerLease) {
        if let info = viewModel.videoInfo, info.aid == item.aid {
            if item.cid == viewModel.currentCid {
                if player.playbackTerminalState == .ended {
                    player.restartForLoop()
                } else if !player.isPlaying {
                    player.play()
                }
                return
            }
            if let targetPage = info.pages?.first(where: { $0.cid == item.cid }) {
                Task { @MainActor in
                    viewModel.showToast(String(localized: "Playing P\(targetPage.page)…"), style: .progress)
                    await viewModel.switchPage(targetPage)
                    installPlaylistSelectionHandlerIfNeeded()
                }
                return
            }
        }

        composer.collapse(motion: motion)
        replyPresentation.cancelPendingAction()
        replyPresentation.isPresented = false
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil

        let nextTarget = inlinePlaylistTarget(for: item)
        userCollapsedImmersiveVideoID = nil
        if isPortraitImmersiveStageActive {
            activePlaylistTarget = nextTarget
            inlineScrollOffset = 0
            detailScrollToTopTick &+= 1
        } else {
            withAnimation(motion.feedbackAnimation(normal: .easeInOut(duration: 0.22))) {
                activePlaylistTarget = nextTarget
                inlineScrollOffset = 0
                detailScrollToTopTick &+= 1
            }
        }
        immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
        syncImmersiveViewportReducerMetrics()
        syncPortraitFullscreenContext()
        Task { @MainActor in
            guard isActiveVideoRoute, player.isCurrentOwner(lease) else { return }
            _ = await viewModel.load(
                id: nextTarget.videoID,
                preferredCid: item.cid > 0 ? item.cid : nil,
                owner: screenOwner,
                lease: lease,
                initialAspectRatioHint: nextTarget.preview.aspectRatioHint
            )
            installPlaylistSelectionHandlerIfNeeded()
            syncInlinePortraitImmersiveBinding()
            syncPortraitFullscreenContext()
            immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
            syncImmersiveViewportReducerMetrics()
            prewarmAdjacentImmersiveCovers()
        }
    }

    func switchToSeasonEpisodeInline(
        _ episode: VideoInfo.UGCSeason.Episode,
        season: VideoInfo.UGCSeason,
        fallbackOwnerName: String
    ) {
        guard isActiveVideoRoute else { return }
        switch UGCSeasonInlineSelectionPolicy.resolveSelection(
            episode: episode,
            currentVideoInfo: viewModel.videoInfo,
            currentCid: viewModel.currentCid,
            fallbackOwnerName: fallbackOwnerName
        ) {
        case .switchPart(let page):
            Task { @MainActor in
                viewModel.showToast(String(localized: "Playing P\(page.page)…"), style: .progress)
                await viewModel.switchPage(page)
                installPlaylistSelectionHandlerIfNeeded()
                syncPortraitFullscreenContext()
            }
            return
        case .resumeOrReplayCurrent:
            if let lease = viewModel.playerLease, player.isCurrentOwner(lease) {
                if player.playbackTerminalState == .ended {
                    player.restartForLoop()
                } else if !player.isPlaying {
                    player.play()
                }
            }
            return
        case .switchVideoInline(let nextTarget, let preferredCid):
            guard let lease = claimPlayerLeaseIfNeeded() else { return }

            composer.collapse(motion: motion)
            replyPresentation.cancelPendingAction()
            replyPresentation.isPresented = false
            showThread = nil
            composer.replyCommentSource = nil
            replyPresentation.anchors.sourceProvider = nil

            isRouteTransitionSettled = true
            userCollapsedImmersiveVideoID = nil
            if isPortraitImmersiveStageActive {
                activePlaylistTarget = nextTarget
                inlineScrollOffset = 0
                detailScrollToTopTick &+= 1
            } else {
                withAnimation(motion.feedbackAnimation(normal: .easeInOut(duration: 0.22))) {
                    activePlaylistTarget = nextTarget
                    inlineScrollOffset = 0
                    detailScrollToTopTick &+= 1
                }
            }

            if let synced = UGCSeasonInlineSelectionPolicy.syncedSeasonQueue(
                existingQueue: player.playbackQueue,
                seasonID: season.id,
                aid: episode.aid,
                cid: episode.cid
            ) {
                player.setPlaybackQueue(synced, liveNavigationHandler: player.liveQueueNavigationHandler)
            }
            if player.activePlaylistQueue != nil {
                immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
            } else {
                immersiveFeedSession.reset(
                    initialTarget: nextTarget,
                    preferredCid: preferredCid,
                    activeQueue: nil
                )
            }
            syncImmersiveViewportReducerMetrics()
            syncPortraitFullscreenContext()

            Task { @MainActor in
                guard isActiveVideoRoute, player.isCurrentOwner(lease) else { return }
                _ = await viewModel.load(
                    id: nextTarget.videoID,
                    preferredCid: preferredCid,
                    owner: screenOwner,
                    lease: lease,
                    initialAspectRatioHint: nextTarget.preview.aspectRatioHint
                )
                guard isActiveVideoRoute,
                      player.isCurrentOwner(lease),
                      videoID == nextTarget.videoID else { return }
                let resolvedCid = viewModel.currentCid ?? episode.cid
                if let synced = UGCSeasonInlineSelectionPolicy.syncedSeasonQueue(
                    existingQueue: player.playbackQueue,
                    seasonID: season.id,
                    aid: episode.aid,
                    cid: resolvedCid
                ) {
                    player.setPlaybackQueue(
                        synced,
                        liveNavigationHandler: player.liveQueueNavigationHandler
                    )
                }
                installPlaylistSelectionHandlerIfNeeded()
                syncInlinePortraitImmersiveBinding()
                syncPortraitFullscreenContext()
                immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
                immersiveFeedSession.ingestRelatedVideos(viewModel.relatedVideos)
                syncImmersiveViewportReducerMetrics()
                prewarmAdjacentImmersiveCovers()
            }
        }
    }

    func syncVideoDetailAfterExternalPlaylistSwitch() {
        guard isActiveVideoRoute,
              !player.isFullscreen,
              let lease = viewModel.playerLease,
              player.isCurrentOwner(lease),
              let activeItem = player.activePlaylistQueue?.currentItem else {
            return
        }
        installPlaylistSelectionHandlerIfNeeded()
        immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
        syncImmersiveViewportReducerMetrics()

        if let info = viewModel.videoInfo, info.aid == activeItem.aid {
            if activeItem.cid > 0, viewModel.currentCid != activeItem.cid {
                viewModel.currentCid = activeItem.cid
                viewModel.installNextPartHandler()
                Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: activeItem.cid) }
                viewModel.refreshOnlineCount()
            }
            syncInlinePortraitImmersiveBinding()
            syncPortraitFullscreenContext()
            return
        }

        composer.collapse(motion: motion)
        replyPresentation.cancelPendingAction()
        replyPresentation.isPresented = false
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil

        let nextTarget = inlinePlaylistTarget(for: activeItem)
        userCollapsedImmersiveVideoID = nil
        if isPortraitImmersiveStageActive {
            activePlaylistTarget = nextTarget
            inlineScrollOffset = 0
            detailScrollToTopTick &+= 1
        } else {
            withAnimation(motion.feedbackAnimation(normal: .easeInOut(duration: 0.22))) {
                activePlaylistTarget = nextTarget
                inlineScrollOffset = 0
                detailScrollToTopTick &+= 1
            }
        }
        syncPortraitFullscreenContext()
        Task { @MainActor in
            guard isActiveVideoRoute, player.isCurrentOwner(lease) else { return }
            _ = await viewModel.load(
                id: nextTarget.videoID,
                preferredCid: activeItem.cid > 0 ? activeItem.cid : nil,
                owner: screenOwner,
                lease: lease,
                initialAspectRatioHint: nextTarget.preview.aspectRatioHint
            )
            installPlaylistSelectionHandlerIfNeeded()
            syncInlinePortraitImmersiveBinding()
            syncPortraitFullscreenContext()
            immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
            syncImmersiveViewportReducerMetrics()
            prewarmAdjacentImmersiveCovers()
        }
    }

    func handlePendingCommentNavigationIfNeeded() async {
        let model = viewModel
        let requestedID = videoID
        let sourceGeneration = model.commentSourceGeneration
        guard isActiveVideoRoute,
              let request = coordinator.pendingCommentNavigation,
              request.anchor.videoID == requestedID,
              model.videoInfo != nil else { return }

        while model.commentsAwaitingInitialResponse,
              viewModel === model, videoID == requestedID,
              model.commentSourceGeneration == sourceGeneration,
              isActiveVideoRoute, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, isActiveVideoRoute, viewModel === model,
              videoID == requestedID, model.commentSourceGeneration == sourceGeneration,
              model.hasCommentSource(for: requestedID),
              coordinator.consumeCommentNavigation(request, for: requestedID) else { return }

        openComments()
        let anchor = request.anchor
        let rootRpid = anchor.rootRpid ?? anchor.rpid
        let location = await model.locateComment(rpid: rootRpid)
        guard !Task.isCancelled, isActiveVideoRoute, viewModel === model,
              videoID == requestedID, model.commentSourceGeneration == sourceGeneration,
              model.hasCommentSource(for: requestedID),
              model.isCurrentCommentLocation(location) else { return }
        guard case .found(let intent) = location,
              let root = model.comments.first(where: { $0.rpid == rootRpid }) else {
            model.showToast(String(localized: "Comment is unavailable"), style: .error)
            return
        }
        if anchor.isNestedReply {
            openCommentThread(CommentThreadTarget(
                oid: intent.receipt.source.aid, type: 1, root: root, highlightRpid: anchor.rpid
            ))
        } else {
            commentTargetRpid = anchor.rpid
        }
    }

    func handleCompactDetailScroll(_ rawOffset: CGFloat) {
        let offset = rawOffset.isFinite ? rawOffset : 0
        recordPageOffsets([0: offset])
        guard isActiveVideoRoute,
              !isWideLayout,
              !isPortraitImmersiveStageActive,
              !commentPresentation.isPresented,
              !player.isFullscreenPresentationActive else { return }
        syncInlineScrollOffset(from: offset)
    }

    func syncInlineScrollOffset(from rawOffset: CGFloat) {
        let offset = rawOffset.isFinite ? rawOffset : 0
        let compact = compactBaseWidth / (16.0 / 9.0)
        let maxTravel = max(0, expandedInlineVideoHeight - compact)
        let target: CGFloat
        if maxTravel <= 1 {
            target = 0
        } else {
            let clamped = max(-maxTravel, min(0, offset))
            target = (clamped * 2).rounded() / 2
        }
        if abs(inlineScrollOffset - target) >= 0.5 || (target == 0 && inlineScrollOffset != 0) {
            inlineScrollOffset = target
        }
    }

    func syncInlineScrollOffsetAfterAspectChange() {
        guard isActiveVideoRoute,
              !isWideLayout,
              !isPortraitImmersiveStageActive,
              !commentPresentation.isPresented,
              !player.isFullscreenPresentationActive else { return }
        syncInlineScrollOffset(from: pageOffsetStore.offsets[0] ?? 0)
    }

    func recordPageOffsets(_ offsets: [Int: CGFloat]) {
        pageOffsetStore.offsets.merge(offsets) { _, new in new }
        if commentPresentation.isPresented {
            updatePlayerCondensation()
        }
    }

    func updatePlayerCondensation() {
        guard !isWideLayout,
              !isPortraitImmersiveStageActive,
              !player.isFullscreenPresentationActive,
              player.ownerKey == screenOwner else { return }

        if commentPresentation.isPresented {
            guard !player.inlineCondensed else { return }
            let compact = compactBaseWidth / (16.0 / 9.0)
            guard expandedInlineVideoHeight > compact + 1 else { return }
            withAnimation(motion.animation(normal: .spring(duration: 0.3))) {
                player.inlineCondensed = true
            }
        } else if player.inlineCondensed {
            withAnimation(motion.animation(normal: .spring(duration: 0.3))) {
                player.inlineCondensed = false
            }
        }
    }

    func updateImmersiveViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
        if DeviceCapability.supportsOrientationLock, player.isFullscreenPresentationActive { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if immersiveViewportSize != rounded {
            immersiveViewportSize = rounded
        }
        syncImmersiveViewportReducerMetrics()
    }

    func syncImmersiveViewportReducerMetrics() {
        let stageSize = immersiveStageSize
        guard stageSize.width > 1, stageSize.height > 1 else { return }
        immersiveFeedSession.reducer.updateContainerHeight(stageSize.height)
        immersiveFeedSession.reducer.noteCoverResolution(width: stageSize.width, height: stageSize.height)
        if immersiveDragOffsetBox.y != immersiveFeedSession.reducer.offset {
            immersiveDragOffsetBox.y = immersiveFeedSession.reducer.offset
        }
    }

    func ensureImmersiveFeedSessionInitialized(preferredCid: Int? = nil) {
        if !hasInitializedImmersiveSession || immersiveFeedSession.entries.isEmpty {
            hasInitializedImmersiveSession = true
            immersiveFeedSession.reset(
                initialTarget: activeTarget,
                preferredCid: preferredCid ?? viewModel.currentCid,
                activeQueue: player.activePlaylistQueue
            )
            if !viewModel.relatedVideos.isEmpty {
                immersiveFeedSession.ingestRelatedVideos(viewModel.relatedVideos)
            }
        } else {
            immersiveFeedSession.syncPlaybackQueue(player.activePlaylistQueue)
        }
        syncImmersiveViewportReducerMetrics()
    }

    func syncImmersiveFeedSessionForEntry() {
        ensureImmersiveFeedSessionInitialized(preferredCid: viewModel.currentCid)
        if !viewModel.relatedVideos.isEmpty {
            immersiveFeedSession.ingestRelatedVideos(viewModel.relatedVideos)
        }
        syncImmersiveViewportReducerMetrics()
        prewarmAdjacentImmersiveCovers()
    }

    func triggerImmersiveRefillIfNeeded(forceSmallPool: Bool = false) {
        guard isActiveVideoRoute, !immersiveFeedSession.isBackedByPlaybackQueue else { return }
        let shouldRefill = forceSmallPool
            ? immersiveFeedSession.entries.count <= 2
            : immersiveFeedSession.shouldRefillRecommendations()
        guard shouldRefill else { return }
        Task { @MainActor in
            await immersiveFeedSession.refillRecommendationsIfNeeded()
            prewarmAdjacentImmersiveCovers()
        }
    }

    func prewarmAdjacentImmersiveCovers() {
        let budget = immersiveFeedSession.reducer.coverResolutionBudget
        guard budget.width > 1, budget.height > 1 else { return }
        let scale = AppWindowMetrics.current?.windowScene?.screen.scale ?? 3
        let requestBox = ImagePipelinePolicy.quantizedRequestBox(
            CGSize(width: budget.width.rounded(), height: budget.height.rounded())
        )
        let candidateIndices = [
            immersiveFeedSession.reducer.nextIndex,
            immersiveFeedSession.reducer.previousIndex,
        ].compactMap { $0 }
        let urls: [URL] = candidateIndices.compactMap { index in
            guard let entry = immersiveFeedSession.entry(at: index) else { return nil }
            let raw = entry.target.preview.coverSource.url(preferring: .mobileVariant)
            guard !raw.isEmpty else { return nil }
            let resized = raw.biliResized(
                toPixel: CGSize(width: requestBox.width * scale, height: requestBox.height * scale),
                crop: false
            )
            return URL(string: resized)
        }
        guard !urls.isEmpty else { return }
        ImagePrefetcher(
            urls: urls,
            options: [
                .processor(DownsamplingImageProcessor(size: requestBox)),
                .scaleFactor(scale),
                .backgroundDecode,
            ]
        ).start()
    }

    func syncInlinePortraitImmersiveBinding() {
        guard isActiveVideoRoute,
              let lease = viewModel.playerLease,
              player.isCurrentOwner(lease) else {
            return
        }
        let active = showsInRoutePortraitImmersive
        if player.isInlinePortraitImmersiveActive != active {
            player.isInlinePortraitImmersiveActive = active
        }
        player.onRequestInlinePortraitImmersive = { target in
            handleInlinePortraitImmersiveRequest(target)
        }
    }

    func clearInlinePortraitImmersiveBindingIfOwned() {
        guard let lease = viewModel.playerLease,
              player.isCurrentOwner(lease) else {
            return
        }
        player.isInlinePortraitImmersiveActive = false
        player.onRequestInlinePortraitImmersive = nil
    }

    @discardableResult
    func handleInlinePortraitImmersiveRequest(_ target: Bool) -> Bool {
        guard isActiveVideoRoute,
              !isWideLayout,
              DeviceCapability.usesCompactPortraitVideoFraming else {
            return false
        }
        if target {
            guard !isPortraitImmersiveStageActive else { return true }
            if commentPresentation.isPresented {
                closeComments()
            }
            userCollapsedImmersiveVideoID = nil
            immersiveDragOffsetBox.y = 0
            player.portraitPureViewEnabled = false
            syncImmersiveFeedSessionForEntry()
            withAnimation(motion.animation(normal: .spring(duration: 0.32, bounce: 0.04))) {
                isPortraitImmersiveStageActive = true
            }
            player.isInlinePortraitImmersiveActive = true
            syncPortraitFullscreenContext()
            triggerImmersiveRefillIfNeeded(forceSmallPool: true)
            return true
        } else {
            guard isPortraitImmersiveStageActive else { return false }
            collapseFromPortraitImmersiveStage()
            return true
        }
    }

    func collapseFromPortraitImmersiveStage() {
        userCollapsedImmersiveVideoID = videoID
        player.portraitPureViewEnabled = false
        immersiveDragOffsetBox.y = 0
        withAnimation(motion.animation(normal: .spring(duration: 0.32, bounce: 0.04))) {
            isPortraitImmersiveStageActive = false
        }
        if let lease = viewModel.playerLease, player.isCurrentOwner(lease) {
            player.isInlinePortraitImmersiveActive = false
        }
        syncPortraitFullscreenContext()
    }

    func beginImmersivePagingDrag() -> Bool {
        guard immersivePagingNeighboursReachable else { return false }
        syncImmersiveViewportReducerMetrics()
        let began = immersiveFeedSession.reducer.beginDrag()
        if began {
            immersiveDragOffsetBox.y = immersiveFeedSession.reducer.offset
        }
        return began
    }

    func updateImmersivePagingDrag(_ translation: CGFloat) {
        immersiveDragOffsetBox.y = immersiveFeedSession.reducer.dragOffset(for: translation)
    }

    func endImmersivePagingDrag(_ translation: CGFloat, _ predicted: CGFloat) {
        var next = immersiveFeedSession.reducer
        guard let settlement = next.endDrag(
            translation: translation,
            predictedEndTranslation: predicted
        ) else { return }
        motion.settle(normal: .snappy(duration: 0.24)) {
            immersiveFeedSession.reducer = next
            immersiveDragOffsetBox.y = next.offset
        } completion: {
            completeImmersivePagingSettlement(settlement.token)
        }
    }

    func cancelImmersivePagingDrag() {
        var next = immersiveFeedSession.reducer
        guard let settlement = next.cancelDrag() else { return }
        motion.settle(normal: .snappy(duration: 0.2)) {
            immersiveFeedSession.reducer = next
            immersiveDragOffsetBox.y = next.offset
        } completion: {
            completeImmersivePagingSettlement(settlement.token)
        }
    }

    func completeImmersivePagingSettlement(_ token: PortraitPagingToken) {
        let switched = PortraitPagingSettlementDispatcher.complete(
            token: token,
            reducer: &immersiveFeedSession.reducer,
            itemIDAtIndex: { index in
                immersiveFeedSession.entry(at: index)
            },
            handoff: {
                guard isActiveVideoRoute,
                      let lease = viewModel.playerLease,
                      player.isCurrentOwner(lease) else {
                    return false
                }
                return player.beginPortraitPagingHandoff(lease: lease)
            },
            activate: { _, entry in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    player.portraitPureViewEnabled = false
                    activePlaylistTarget = entry.target
                    immersiveDragOffsetBox.y = 0
                }
                activateImmersivePagedEntry(entry)
            }
        )
        if !switched {
            immersiveDragOffsetBox.y = immersiveFeedSession.reducer.offset
        }
    }

    func activateImmersivePagedEntry(_ entry: PortraitImmersiveEntry) {
        if immersiveFeedSession.isBackedByPlaybackQueue, let qid = entry.queueItemID {
            installPlaylistSelectionHandlerIfNeeded()
            if player.jumpToPlaylistItem(id: qid) {
                prewarmAdjacentImmersiveCovers()
                return
            }
        }

        composer.collapse(motion: motion)
        replyPresentation.cancelPendingAction()
        replyPresentation.isPresented = false
        showThread = nil
        composer.replyCommentSource = nil
        replyPresentation.anchors.sourceProvider = nil

        activePlaylistTarget = entry.target
        inlineScrollOffset = 0
        userCollapsedImmersiveVideoID = nil
        isRouteTransitionSettled = true
        detailScrollToTopTick &+= 1
        syncPortraitFullscreenContext()

        Task { @MainActor in
            await loadImmersivePagedEntry(entry)
            await immersiveFeedSession.refillRecommendationsIfNeeded()
            prewarmAdjacentImmersiveCovers()
        }
    }

    func loadImmersivePagedEntry(_ entry: PortraitImmersiveEntry) async {
        guard isActiveVideoRoute,
              let lease = claimPlayerLeaseIfNeeded(),
              player.isCurrentOwner(lease) else { return }
        _ = await viewModel.load(
            id: entry.target.videoID,
            preferredCid: entry.preferredCid,
            owner: screenOwner,
            lease: lease,
            initialAspectRatioHint: entry.target.preview.aspectRatioHint
        )
        guard isActiveVideoRoute,
              player.isCurrentOwner(lease),
              videoID == entry.target.videoID else { return }
        installPlaylistSelectionHandlerIfNeeded()
        syncInlinePortraitImmersiveBinding()
        syncPortraitFullscreenContext()
        immersiveFeedSession.ingestRelatedVideos(viewModel.relatedVideos)
        prewarmAdjacentImmersiveCovers()
    }

    func applyModeDPortraitFullscreenIfNeeded() {
        guard isActiveVideoRoute,
              !player.isFullscreen,
              !player.isFullscreenPresentationActive,
              !commentPresentation.isPresented else { return }

        let shouldPromote = PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: PlayerPlaybackPreferences.portraitVideoMode,
            isWideLayout: isWideLayout,
            usesCompactFraming: DeviceCapability.usesCompactPortraitVideoFraming,
            isAlreadyImmersive: isPortraitImmersiveStageActive,
            userCollapsedCurrentVideo: userCollapsedImmersiveVideoID == videoID,
            userHasScrolledInline: abs(inlineScrollOffset) > 4,
            aspectRatio: effectiveInlineAspectRatio,
            isPortraitFallback: metadataPortraitHint || (playerShapeIsCurrent && player.isPortraitContent)
        )
        guard shouldPromote else { return }

        if let aspect = effectiveInlineAspectRatio {
            player.applyAspectRatioHint(aspect)
        } else if !player.portraitPropagation.hasValidVideoGeometry {
            player.isPortraitContent = true
        }
        immersiveDragOffsetBox.y = 0
        syncImmersiveFeedSessionForEntry()
        withAnimation(motion.animation(normal: .spring(duration: 0.3))) {
            isPortraitImmersiveStageActive = true
        }
        syncInlinePortraitImmersiveBinding()
        syncPortraitFullscreenContext()
        triggerImmersiveRefillIfNeeded(forceSmallPool: true)
    }

    func syncPortraitFullscreenContext() {
        guard isActiveVideoRoute,
              let lease = viewModel.playerLease,
              player.isCurrentOwner(lease) else {
            return
        }
        let context: PlayerPortraitFullscreenContext
        if let existing = player.portraitFullscreenContext, existing.ownerLease == lease {
            context = existing
        } else {
            context = PlayerPortraitFullscreenContext(ownerLease: lease)
            player.portraitFullscreenContext = context
        }

        let info = viewModel.matchesLoadedVideo(videoID) ? viewModel.videoInfo : nil
        context.title = info?.title ?? activeTarget.preview.title
        context.upMid = info?.owner.mid ?? 0
        context.upName = info?.owner.name ?? activeTarget.preview.ownerName
        context.upAvatarURL = info?.owner.face ?? ""
        context.isFollowing = viewModel.isFollowingUp
        context.isLiked = viewModel.isLiked
        context.likeCount = info?.stat.like ?? 0
        context.isCoined = viewModel.isCoined
        context.coinCount = info?.stat.coin ?? 0
        context.canGiveTwoCoins = (viewModel.maxCoins - viewModel.coinCount) >= 2
        context.isFavorited = viewModel.isFavorited
        context.favoriteCount = info?.stat.favorite ?? 0
        context.replyCount = info?.stat.reply ?? 0
        context.shareCount = info?.stat.share ?? 0
        context.commentsClosed = viewModel.commentsClosed
        context.bvid = info?.bvid ?? ""
        context.aid = info?.aid ?? 0
        context.isInRouteImmersiveStage = showsInRoutePortraitImmersive
        context.hasExpandableDetails = info != nil
        context.descriptionPreview = PlayerPortraitFullscreenContext.normalizedDescriptionPreview(info?.desc)
        if let info {
            let playsText = String(
                format: String(localized: "%@ plays"),
                FormatUtils.viewCount(info.stat.view)
            )
            let pubText = FormatUtils.timeAgo(from: info.pubdate)
            context.statsSummary = [playsText, pubText]
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
        } else {
            context.statsSummary = nil
        }
        if let pages = info?.pages, pages.count > 1 {
            let activeCid = viewModel.currentCid ?? info?.cid
            let pageNum = pages.first(where: { $0.cid == activeCid })?.page ?? 1
            context.summaryBadgeText = "P\(pageNum)/\(pages.count)"
        } else if let season = info?.ugcSeason, !season.allEpisodes.isEmpty {
            let episodes = season.allEpisodes
            let activeCid = viewModel.currentCid
            let idx = episodes.firstIndex(where: {
                $0.aid == info?.aid && (activeCid == nil || $0.cid == activeCid)
            })
                ?? episodes.firstIndex(where: { $0.aid == info?.aid })
                ?? 0
            context.summaryBadgeText = "EP\(idx + 1)/\(episodes.count)"
        } else {
            context.summaryBadgeText = nil
        }

        context.onBackToFeed = {
            if player.isFullscreen { player.exitFullscreen() }
            coordinator.goBack()
        }
        context.onCollapseToDetail = {
            if isPortraitImmersiveStageActive {
                collapseFromPortraitImmersiveStage()
            } else {
                player.requestFullscreenTransition(target: false, source: .button)
            }
        }
        context.onSwipeUpToDetailComments = {
            if isPortraitImmersiveStageActive {
                collapseFromPortraitImmersiveStage()
            } else {
                player.requestFullscreenTransition(target: false, source: .button)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                if !viewModel.commentsClosed {
                    openComments()
                }
            }
        }
        context.onTapOwner = {
            let mid = viewModel.videoInfo?.owner.mid ?? 0
            guard mid > 0 else { return }
            if player.isFullscreen { player.exitFullscreen() }
            coordinator.navigate(to: .userSpace(mid))
        }
        context.onToggleFollow = {
            await viewModel.toggleFollowUp()
            syncPortraitFullscreenContext()
        }
        context.onToggleLike = {
            await viewModel.toggleLike()
            syncPortraitFullscreenContext()
        }
        context.onDoubleTapLike = {
            guard !viewModel.isLiked else { return }
            await viewModel.toggleLike()
            syncPortraitFullscreenContext()
        }
        context.onTripleCombo = {
            let ok = await viewModel.performTripleCombo()
            syncPortraitFullscreenContext()
            return ok
        }
        context.onGiveCoin = { count in
            await viewModel.addCoin(multiply: count)
            syncPortraitFullscreenContext()
        }
        context.onRequestFavoriteSheet = {
            await viewModel.loadFavFolders()
            return viewModel.favFolders.map { folder in
                FavoriteFolderResult.FavoriteFolder(
                    id: folder.id,
                    title: folder.title,
                    mediaCount: folder.mediaCount,
                    attr: folder.favState,
                    mid: nil,
                    cover: nil,
                    upper: nil
                )
            }
        }
        context.onCommitFavoriteFolders = { selected in
            await viewModel.applyFavorite(selectedIds: selected)
            syncPortraitFullscreenContext()
        }
        context.onRecordShare = {
            await viewModel.shareVideo()
            syncPortraitFullscreenContext()
        }
        context.makeShareSheetView = {
            let payload: VideoSharePayload = if let loadedInfo = viewModel.matchesLoadedVideo(videoID) ? viewModel.videoInfo : nil {
                VideoSharePayload.from(info: loadedInfo)
            } else {
                VideoSharePayload(
                    bvid: context.bvid,
                    aid: context.aid,
                    title: context.title,
                    uploader: context.upName,
                    avatarURL: context.upAvatarURL,
                    coverURL: activeTarget.preview.coverSource.desktopURL,
                    description: "",
                    durationSeconds: activeTarget.preview.durationSeconds,
                    viewCount: 0,
                    likeCount: context.likeCount,
                    isPortraitCover: activeTarget.preview.isPortraitHint ?? false
                )
            }
            return AnyView(
                VideoShareStudioSheet(payload: payload) {
                    await viewModel.shareVideo()
                    syncPortraitFullscreenContext()
                }
            )
        }
        context.onRequestLogin = {
            coordinator.presentLogin()
        }
        context.makeCommentsSheetView = {
            AnyView(makePortraitFullscreenCommentsSheet())
        }
        context.makeDetailsSheetView = {
            AnyView(makePortraitFullscreenDetailsSheet())
        }
    }

    func makePortraitFullscreenDetailsSheet() -> PortraitFullscreenDetailsSheet {
        let model = viewModel
        let coordinator = coordinator
        return PortraitFullscreenDetailsSheet(
            model: model,
            coordinator: coordinator,
            isRouteActive: { isActiveVideoRoute },
            onCollapseToStandardView: {
                if isPortraitImmersiveStageActive {
                    collapseFromPortraitImmersiveStage()
                } else if player.isFullscreen {
                    player.requestFullscreenTransition(target: false, source: .button)
                }
            },
            onNavigateRoute: { route in
                if player.isFullscreen { player.exitFullscreen() }
                coordinator.navigate(to: route)
            },
            onSelectSeasonEpisode: { ep, season, ownerName in
                switchToSeasonEpisodeInline(ep, season: season, fallbackOwnerName: ownerName)
            },
            onSyncContext: {
                syncPortraitFullscreenContext()
            }
        )
    }

    func clearPortraitFullscreenContextIfOwned() {
        guard let lease = viewModel.playerLease,
              player.portraitFullscreenContext?.ownerLease == lease else { return }
        player.portraitFullscreenContext = nil
    }

    func offerDownload(_ info: VideoInfo) {
        let cid = viewModel.currentCid ?? info.cid
        let isMultiPart = (info.pages?.count ?? 0) > 1
        if !isMultiPart {
            if let existing = DownloadManager.shared.existing(bvid: info.bvid, cid: cid) {
                if existing.filesExist {
                    viewModel.showToast(String(localized: "Already downloaded"), style: .success)
                    return
                }
                guard DownloadManager.shared.delete(existing) else {
                    viewModel.showToast(String(localized: "Download is being exported"), style: .progress)
                    return
                }
            }
            if DownloadManager.shared.isActive(bvid: info.bvid, cid: cid) {
                viewModel.showToast(String(localized: "Download in progress"), style: .progress)
                return
            }
        }
        let isImmediate = DownloadManager.shared.hasImmediateQualityList(
            aid: info.aid, cid: cid
        )
        if !isImmediate {
            viewModel.showToast(String(localized: "Preparing…"), style: .progress)
        }
        downloadRequestSerial &+= 1
        let serial = downloadRequestSerial
        Task {
            do {
                let qualities = try await DownloadManager.shared.availableQualities(
                    aid: info.aid, cid: cid
                )
                guard !Task.isCancelled,
                      downloadRequestSerial == serial,
                      viewModel.videoInfo?.aid == info.aid,
                      (viewModel.currentCid ?? viewModel.videoInfo?.cid) == cid
                else { return }
                if isMultiPart {
                    let items = BatchDownloadSelectionState.items(from: info)
                    activeSheet = .batchDownload(BatchDownloadPresentation(
                        title: info.title,
                        items: items,
                        qualities: qualities,
                        initialSelectedID: "\(info.bvid)_\(cid)"
                    ))
                } else {
                    activeSheet = .download(DownloadQualityPresentation(
                        info: info, cid: cid, qualities: qualities
                    ))
                }
            } catch {
                guard !Task.isCancelled, downloadRequestSerial == serial else { return }
                viewModel.showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func prepareShareCard(_ info: VideoInfo) {
        guard isActiveVideoRoute else { return }
        activeSheet = .share(VideoSharePayload.from(info: info))
    }

    func startDownload(_ info: VideoInfo, cid: Int, quality: Int) {
        let duration = info.pages?.first(where: { $0.cid == cid })?.duration ?? info.duration
        viewModel.showToast(String(localized: "Download started"), style: .progress)
        Task {
            await DownloadManager.shared.startDownload(
                aid: info.aid, cid: cid, bvid: info.bvid, title: info.title,
                coverURL: info.pic, ownerName: info.owner.name,
                durationSeconds: duration, quality: quality
            )
        }
    }
}

struct DownloadQualityPresentation: Identifiable {
    let id = UUID()
    let info: VideoInfo
    let cid: Int
    let qualities: [DownloadQualityOption]
}

struct PlaylistVideoPart: Equatable, Sendable {
    let cid: Int
    let page: Int
    let part: String
    let duration: Int
    let isPortrait: Bool?

    init(
        cid: Int,
        page: Int,
        part: String,
        duration: Int,
        isPortrait: Bool? = nil
    ) {
        self.cid = cid
        self.page = page
        self.part = part
        self.duration = duration
        self.isPortrait = isPortrait
    }

    init(_ videoPage: VideoInfo.VideoPage) {
        self.cid = videoPage.cid
        self.page = videoPage.page
        self.part = videoPage.part
        self.duration = videoPage.duration
        self.isPortrait = videoPage.dimension?.isPortrait
    }
}

struct PlaylistQueueEntry: Equatable, Sendable {
    let aid: Int
    let bvid: String?
    var cid: Int?
    let title: String
    let artist: String
    let coverURL: String?
    var duration: TimeInterval?
    var isPortraitHint: Bool?
    let routeTarget: VideoRouteTarget
    var pages: [PlaylistVideoPart]?

    init(
        aid: Int,
        bvid: String?,
        cid: Int?,
        title: String,
        artist: String,
        coverURL: String?,
        duration: TimeInterval?,
        isPortraitHint: Bool?,
        routeTarget: VideoRouteTarget,
        pages: [PlaylistVideoPart]? = nil
    ) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.artist = artist
        self.coverURL = coverURL
        self.duration = duration
        self.isPortraitHint = isPortraitHint
        self.routeTarget = routeTarget
        self.pages = pages
    }

    var videoID: VideoID { routeTarget.videoID }

    func makeQueueItem(playlistKey: String) -> PlaybackQueueItem? {
        guard let cid, cid > 0 else { return nil }
        return PlaybackQueueItem(
            id: "playlist-\(playlistKey)-\(aid)-\(cid)",
            aid: aid,
            cid: cid,
            bvid: bvid,
            title: title,
            artist: artist,
            coverURL: coverURL,
            duration: duration,
            isPortraitHint: isPortraitHint,
            source: .ugc,
            originRoute: .videoDetail(routeTarget),
            originScreenRoute: .video(videoID),
            partCount: pages != nil ? 1 : nil
        )
    }

    func makeQueueItems(playlistKey: String) -> [PlaybackQueueItem] {
        if let pages, pages.count > 1 {
            let totalParts = pages.count
            return pages.map { page in
                let pageTarget = VideoRouteTarget(
                    videoID: videoID,
                    preview: PortraitPagingPreview(
                        title: title,
                        coverURL: coverURL ?? "",
                        ownerName: artist,
                        durationSeconds: page.duration,
                        isPortraitHint: page.isPortrait ?? isPortraitHint
                    ),
                    zoomSourceID: nil
                )
                return PlaybackQueueItem(
                    id: "playlist-\(playlistKey)-\(aid)-\(page.cid)",
                    aid: aid,
                    cid: page.cid,
                    bvid: bvid,
                    title: title,
                    artist: artist,
                    coverURL: coverURL,
                    duration: TimeInterval(page.duration),
                    isPortraitHint: page.isPortrait ?? isPortraitHint,
                    source: .ugc,
                    originRoute: .videoDetail(pageTarget),
                    originScreenRoute: .video(videoID),
                    partIndex: page.page,
                    partCount: totalParts,
                    partTitle: page.part.isEmpty ? nil : page.part
                )
            }
        }
        return makeQueueItem(playlistKey: playlistKey).map { [$0] } ?? []
    }
}

struct ResolvedPlaylistVideoMetadata: Equatable, Sendable {
    let cid: Int
    let duration: Int?
    let isPortrait: Bool?
    let pages: [PlaylistVideoPart]?

    init(
        cid: Int,
        duration: Int?,
        isPortrait: Bool?,
        pages: [PlaylistVideoPart]? = nil
    ) {
        self.cid = cid
        self.duration = duration
        self.isPortrait = isPortrait
        self.pages = pages
    }
}

@MainActor
final class PlaylistQueueLauncher {
    typealias CIDResolver = @Sendable (VideoID) async -> ResolvedPlaylistVideoMetadata?

    static let shared = PlaylistQueueLauncher()

    private struct Session {
        let generation: UInt64
        let playlistName: String
        let playlistKey: String
        let orderMode: PlaylistOrderMode
        var entries: [PlaylistQueueEntry]
        var ownerLease: PlayerOwnerLease?
        var hasPublishedQueue = false
        var publishedAids: Set<Int> = []
        var removedAids: Set<Int> = []
        var removedItemIDs: Set<String> = []
    }

    private let cidResolver: CIDResolver
    private var generation: UInt64 = 0
    private var activeSession: Session?
    private var hydrationTask: Task<Void, Never>?

    init(cidResolver: @escaping CIDResolver = PlaylistQueueLauncher.defaultCIDResolver) {
        self.cidResolver = cidResolver
    }

    var isHydrating: Bool {
        hydrationTask != nil && activeSession != nil
    }

    private nonisolated static func defaultCIDResolver(
        _ videoID: VideoID
    ) async -> ResolvedPlaylistVideoMetadata? {
        guard let info = try? await VideoAPI.getVideoInfo(id: videoID), info.cid > 0 else {
            return nil
        }
        return ResolvedPlaylistVideoMetadata(
            cid: info.cid,
            duration: info.duration > 0 ? info.duration : nil,
            isPortrait: info.dimension?.isPortrait,
            pages: info.pages?.map(PlaylistVideoPart.init)
        )
    }

    func cancel() {
        generation &+= 1
        hydrationTask?.cancel()
        hydrationTask = nil
        activeSession = nil
    }

    func noteItemRemoved(aid: Int, itemID: String, removeWholeVideo: Bool) {
        guard var session = activeSession else { return }
        session.removedItemIDs.insert(itemID)
        if removeWholeVideo {
            session.removedAids.insert(aid)
        }
        activeSession = session
    }

    @discardableResult
    func launch(
        playlistName: String,
        entries: [PlaylistQueueEntry],
        coordinator: AppCoordinator,
        player: PlayerViewModel = .shared,
        orderMode: PlaylistOrderMode? = nil
    ) -> Bool {
        guard let first = entries.first else { return false }
        cancel()
        let sessionGeneration = generation
        let playlistKey = String(UUID().uuidString.prefix(8))
        let resolvedOrderMode = orderMode ?? PlaylistOrderMode.loadPreferred()
        let session = Session(
            generation: sessionGeneration,
            playlistName: playlistName,
            playlistKey: playlistKey,
            orderMode: resolvedOrderMode,
            entries: entries,
            ownerLease: nil
        )

        player.endCurrentOwnerPlayback()
        player.session.playbackOrder = .playNext
        activeSession = session

        guard coordinator.navigateToVideo(first.routeTarget) else {
            if activeSession?.generation == sessionGeneration {
                activeSession = nil
            }
            return false
        }

        if let immediateQueue = buildQueueContext(
            from: session,
            currentAid: first.aid,
            currentCid: first.cid
        ) {
            player.setPlaybackQueue(immediateQueue)
        }

        startHydratingRemainingEntries(generation: sessionGeneration, player: player)
        return true
    }

    func adoptLoadedFirstVideoIfArmed(
        videoInfo: VideoInfo?,
        currentCid: Int?,
        lease: PlayerOwnerLease,
        player: PlayerViewModel = .shared
    ) {
        guard var session = activeSession,
              session.ownerLease == nil || session.ownerLease == lease else { return }
        guard let info = videoInfo,
              let resolvedCid = currentCid, resolvedCid > 0,
              let first = session.entries.first,
              first.aid == info.aid,
              player.isCurrentOwner(lease) else {
            if session.ownerLease == nil {
                cancel()
            }
            return
        }

        session.ownerLease = lease
        session.entries[0].cid = resolvedCid
        session.entries[0].pages = info.pages?.map(PlaylistVideoPart.init)
        if session.entries[0].isPortraitHint == nil {
            session.entries[0].isPortraitHint = info.dimension?.isPortrait
        }
        if session.entries[0].duration == nil, info.duration > 0 {
            session.entries[0].duration = TimeInterval(info.duration)
        }
        activeSession = session
        publishHydratedQueue(for: session.generation, player: player, force: true)
    }

    func buildQueueContext(
        playlistName: String,
        playlistKey: String = "queue",
        entries: [PlaylistQueueEntry],
        currentAid: Int? = nil,
        currentCid: Int? = nil,
        orderMode: PlaylistOrderMode = .sequential
    ) -> PlaybackQueueContext? {
        let items = entries.flatMap { $0.makeQueueItems(playlistKey: playlistKey) }
        guard !items.isEmpty else { return nil }
        let selectedIndex: Int
        if let currentAid, let currentCid,
           let matched = items.firstIndex(where: { $0.aid == currentAid && $0.cid == currentCid }) {
            selectedIndex = matched
        } else if let currentAid,
                  let matched = items.firstIndex(where: { $0.aid == currentAid }) {
            selectedIndex = matched
        } else {
            selectedIndex = 0
        }
        return PlaybackQueueContext(
            kind: .playlist(name: playlistName),
            items: items,
            currentIndex: selectedIndex,
            playlistOrderMode: orderMode
        )
    }

    private func buildQueueContext(
        from session: Session,
        currentAid: Int?,
        currentCid: Int?
    ) -> PlaybackQueueContext? {
        let filteredEntries = session.entries.filter { !session.removedAids.contains($0.aid) }
        let items = filteredEntries
            .flatMap { $0.makeQueueItems(playlistKey: session.playlistKey) }
            .filter { !session.removedItemIDs.contains($0.id) }
        guard !items.isEmpty else { return nil }
        let selectedIndex: Int
        if let currentAid, let currentCid,
           let matched = items.firstIndex(where: { $0.aid == currentAid && $0.cid == currentCid }) {
            selectedIndex = matched
        } else if let currentAid,
                  let matched = items.firstIndex(where: { $0.aid == currentAid }) {
            selectedIndex = matched
        } else {
            selectedIndex = 0
        }
        return PlaybackQueueContext(
            kind: .playlist(name: session.playlistName),
            items: items,
            currentIndex: selectedIndex,
            playlistOrderMode: session.orderMode
        )
    }

    private func startHydratingRemainingEntries(
        generation sessionGeneration: UInt64,
        player: PlayerViewModel
    ) {
        guard let session = activeSession, session.generation == sessionGeneration else { return }
        let unresolvedIndices = session.entries.indices.filter { index in
            index > 0 && (session.entries[index].cid ?? 0) <= 0
        }
        guard !unresolvedIndices.isEmpty else { return }

        let targets = unresolvedIndices.map { index in
            (index: index, videoID: session.entries[index].videoID)
        }
        let resolver = cidResolver
        hydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeSession?.generation == sessionGeneration {
                    self.hydrationTask = nil
                }
            }

            // Hydrate the immediate next track first so Next/Auto-Advance is ready right away.
            if let firstTarget = targets.first {
                let resolved = await resolver(firstTarget.videoID)
                guard !Task.isCancelled,
                      self.activeSession?.generation == sessionGeneration else { return }
                if let resolved {
                    self.applyResolvedEntry(
                        resolved,
                        at: firstTarget.index,
                        generation: sessionGeneration,
                        player: player
                    )
                }
            }

            let remaining = Array(targets.dropFirst())
            guard !remaining.isEmpty else { return }

            let maxConcurrency = 4
            var nextCursor = 0
            await withTaskGroup(of: (Int, ResolvedPlaylistVideoMetadata?).self) { group in
                for _ in 0..<min(maxConcurrency, remaining.count) {
                    let target = remaining[nextCursor]
                    nextCursor += 1
                    group.addTask {
                        (target.index, await resolver(target.videoID))
                    }
                }

                var pendingBatchCount = 0
                while let (index, resolved) = await group.next() {
                    guard !Task.isCancelled,
                          self.activeSession?.generation == sessionGeneration else {
                        group.cancelAll()
                        return
                    }
                    if let resolved {
                        self.storeResolvedEntry(
                            resolved,
                            at: index,
                            generation: sessionGeneration
                        )
                        pendingBatchCount += 1
                        if pendingBatchCount >= 2 {
                            pendingBatchCount = 0
                            self.publishHydratedQueue(for: sessionGeneration, player: player, force: false)
                        }
                    }
                    if !Task.isCancelled, nextCursor < remaining.count {
                        let target = remaining[nextCursor]
                        nextCursor += 1
                        group.addTask {
                            (target.index, await resolver(target.videoID))
                        }
                    }
                }
                if pendingBatchCount > 0 {
                    self.publishHydratedQueue(for: sessionGeneration, player: player, force: false)
                }
            }
        }
    }

    private func applyResolvedEntry(
        _ resolved: ResolvedPlaylistVideoMetadata,
        at index: Int,
        generation sessionGeneration: UInt64,
        player: PlayerViewModel
    ) {
        storeResolvedEntry(resolved, at: index, generation: sessionGeneration)
        publishHydratedQueue(for: sessionGeneration, player: player, force: false)
    }

    private func storeResolvedEntry(
        _ resolved: ResolvedPlaylistVideoMetadata,
        at index: Int,
        generation sessionGeneration: UInt64
    ) {
        guard var session = activeSession,
              session.generation == sessionGeneration,
              session.entries.indices.contains(index),
              resolved.cid > 0 else { return }
        session.entries[index].cid = resolved.cid
        session.entries[index].pages = resolved.pages
        if session.entries[index].duration == nil, let duration = resolved.duration, duration > 0 {
            session.entries[index].duration = TimeInterval(duration)
        }
        if session.entries[index].isPortraitHint == nil {
            session.entries[index].isPortraitHint = resolved.isPortrait
        }
        activeSession = session
    }

    private func publishHydratedQueue(
        for sessionGeneration: UInt64,
        player: PlayerViewModel,
        force: Bool
    ) {
        guard var session = activeSession,
              session.generation == sessionGeneration else { return }
        guard let ownerLease = session.ownerLease else {
            return
        }
        guard player.isCurrentOwner(ownerLease) else {
            cancel()
            return
        }
        if session.hasPublishedQueue, !force {
            guard let existing = player.playbackQueue,
                  existing.kind == .playlist(name: session.playlistName) else {
                cancel()
                return
            }
            var newlyBuilt: [PlaybackQueueItem] = []
            for entry in session.entries {
                guard (entry.cid ?? 0) > 0,
                      !session.publishedAids.contains(entry.aid),
                      !session.removedAids.contains(entry.aid) else { continue }
                let built = entry.makeQueueItems(playlistKey: session.playlistKey)
                    .filter { !session.removedItemIDs.contains($0.id) }
                if !built.isEmpty {
                    newlyBuilt.append(contentsOf: built)
                }
                session.publishedAids.insert(entry.aid)
            }
            activeSession = session
            guard !newlyBuilt.isEmpty else { return }
            let merged = existing.appendingItems(newlyBuilt)
            player.setPlaybackQueue(merged, liveNavigationHandler: player.liveQueueNavigationHandler)
            PlayerLog.log(
                "[Queue] playlist \"\(session.playlistName)\" appended " +
                    "items=\(merged.items.count)/\(session.entries.count) index=\(merged.currentIndex + 1)"
            )
            return
        }
        guard let updated = buildQueueContext(
            from: session,
            currentAid: player.currentAid ?? session.entries.first?.aid,
            currentCid: player.currentCid ?? session.entries.first?.cid
        ) else { return }

        session.hasPublishedQueue = true
        session.publishedAids.formUnion(updated.items.map(\.aid))
        activeSession = session
        player.setPlaybackQueue(updated, liveNavigationHandler: player.liveQueueNavigationHandler)
        PlayerLog.log(
            "[Queue] playlist \"\(session.playlistName)\" hydrated " +
                "items=\(updated.items.count)/\(session.entries.count) index=\(updated.currentIndex + 1)"
        )
    }
}

struct FavoriteFolderSheet: View {
    let folders: [FavFolderListResult.FavFolder]
    @State var selection: Set<Int>
    let onConfirm: (Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List(folders) { folder in
                Button {
                    if selection.contains(folder.id) {
                        selection.remove(folder.id)
                    } else {
                        selection.insert(folder.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        FolderIconView(size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.title)
                                .foregroundStyle(.primary)
                            if let count = folder.mediaCount {
                                Text("\(count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selection.contains(folder.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selection.contains(folder.id)
                                ? AnyShapeStyle(.biliAccent)
                                : AnyShapeStyle(.quaternary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add to Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onConfirm(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView(
                        "No Folders",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Could not load your favorite folders. Check the log for details.")
                    )
                }
            }
        }
        .appAdaptiveSheet(padSizing: .form)
    }
}

struct DownloadQualitySheet: View {
    let qualities: [DownloadQualityOption]
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List {
                ForEach(qualities, id: \.code) { quality in
                    Button {
                        onSelect(quality.code)
                    } label: {
                        HStack {
                            Text(quality.label)
                            Spacer()
                            if let bytes = quality.estimatedBytes {
                                Text(DownloadStoragePolicy.byteLabel(bytes))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Download Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct VideoReportSheet: View {
    let aid: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            AuthedBiliWebView(url: URL(string: "https://www.bilibili.com/appeal/?avid=\(aid)")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Report Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .appAdaptiveSheet(compactDetents: [.large], padSizing: .page)
    }
}
