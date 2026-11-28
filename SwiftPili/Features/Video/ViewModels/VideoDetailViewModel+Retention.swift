import Foundation

enum VideoDetailReactivationPolicy {
    enum Decision {
        case alreadyLive
        case dataRetained
        case fullLoad
    }

    static let retainsScreenData = ProcessInfo.processInfo.environment["DETAIL_RETAIN_SCREEN_DATA"] != "0"
    static let screenDataMaxAge: Duration = .seconds(600)

    static func decision(alreadyLive: Bool, dataRetained: Bool) -> Decision {
        if alreadyLive { return .alreadyLive }
        return dataRetained ? .dataRetained : .fullLoad
    }

    struct Facts: Equatable, Sendable {
        let requestedID: VideoID
        let loadedID: VideoID?
        let hasLoadedMetadata: Bool
        let screenAid: Int?
        let screenCid: Int?
        let screenReportedFailure: Bool
        let requestedOwner: String
        let retainedLeaseOwner: String?
        let retainedLeaseIsCurrentOwner: Bool
        let targetMode: PlayerMode
        let targetSource: PlayerViewModel.StreamSource
        let playerMode: PlayerMode
        let playerAid: Int?
        let playerCid: Int?
        let playerSource: PlayerViewModel.StreamSource
        let playerHasSource: Bool
        let playerReportedFailure: Bool
    }

    static func isAlreadyLive(_ facts: Facts) -> Bool {
        let targetMatchesLoadedContent = facts.loadedID == facts.requestedID
            && facts.loadedID != nil
        return PlayerDetailReactivationPolicy.isAlreadyLive(
            .init(
                targetMatchesLoadedContent: targetMatchesLoadedContent,
                hasLoadedMetadata: facts.hasLoadedMetadata,
                screenAid: facts.screenAid,
                screenCid: facts.screenCid,
                screenReportedFailure: facts.screenReportedFailure,
                requestedOwner: facts.requestedOwner,
                retainedLeaseOwner: facts.retainedLeaseOwner,
                retainedLeaseIsCurrentOwner: facts.retainedLeaseIsCurrentOwner,
                targetMode: facts.targetMode,
                targetSource: facts.targetSource,
                playerMode: facts.playerMode,
                playerAid: facts.playerAid,
                playerCid: facts.playerCid,
                playerSource: facts.playerSource,
                playerHasSource: facts.playerHasSource,
                playerReportedFailure: facts.playerReportedFailure
            )
        )
    }
}

extension VideoDetailViewModel {
    struct CompletedScreenDataReceipt: Equatable {
        let id: VideoID
        let aid: Int
        let cid: Int
        let dataRequest: UInt64
        let accountSession: UUID
        let fetchedAt: ContinuousClock.Instant

        func replacingPart(_ cid: Int) -> Self {
            .init(id: id, aid: aid, cid: cid, dataRequest: dataRequest,
                  accountSession: accountSession, fetchedAt: fetchedAt)
        }
    }

    struct RetainedPlaybackRequest {
        let serial: UInt64
        let data: CompletedScreenDataReceipt
        let lease: PlayerOwnerLease
        let traceToken: StartupTrace.Token
    }

    struct InteractionStateReceipt: Equatable {
        let dataRequest: UInt64
        let aid: Int
        let accountSession: UUID
    }

    func clearInMemoryRetainedScreenData() {
        retainedScreenData = nil
        activeScreenCacheContext = nil
        retireRetainedPlayback(reason: "screen-data-replaced")
    }

    func invalidateRetainedScreenData() {
        if let source = currentCommentSource, let accountSession = metadataAccountSession {
            VideoDetailScreenDataCache.remove(id: source.videoID, accountSession: accountSession)
        } else if let context = activeScreenCacheContext {
            VideoDetailScreenDataCache.remove(id: context.id, accountSession: context.accountSession)
        }
        retainedScreenData = nil
        activeScreenCacheContext = nil
        retireRetainedPlayback(reason: "screen-data-invalidated")
    }

    func eligibleRetainedScreenData(for id: VideoID) -> CompletedScreenDataReceipt? {
        guard VideoDetailReactivationPolicy.retainsScreenData,
              let data = retainedScreenData, data.id == id,
              data.fetchedAt.duration(to: .now) <= VideoDetailReactivationPolicy.screenDataMaxAge,
              matchesRetainedScreenData(data), !isLoading,
              error == nil, unavailability == nil,
              let info = videoInfo,
              info.pages?.contains(where: { $0.cid == data.cid }) == true
                || ((info.pages?.isEmpty ?? true) && data.cid == info.cid)
        else { return nil }
        return data
    }

    private func matchesRetainedScreenData(_ data: CompletedScreenDataReceipt) -> Bool {
        data.accountSession == AuthManager.shared.sessionGeneration
            && metadataAccountSession == data.accountSession
            && currentCommentSource?.videoID == data.id
            && currentCommentSource?.aid == data.aid
            && commentSourceGeneration == data.dataRequest
            && videoInfo?.aid == data.aid && currentCid == data.cid
    }

    func retainCompletedScreenData(
        _ data: CompletedScreenDataReceipt, relatedLoaded: Bool, partSwitchPending: Bool
    ) {
        guard !Task.isCancelled, relatedLoaded, !partSwitchPending,
              matchesRetainedScreenData(data), commentsReadyForNavigation,
              error == nil, unavailability == nil,
              PlayerViewModel.shared.error == nil, PlayerViewModel.shared.unavailability == nil else { return }
        retainedScreenData = data
        cacheCompletedScreenData()
    }

    func retainCompletedPart(cid: Int) {
        guard !Task.isCancelled, let data = retainedScreenData,
              matchesRetainedScreenData(data.replacingPart(cid)),
              PlayerViewModel.shared.error == nil, PlayerViewModel.shared.unavailability == nil else { return }
        retainedScreenData = data.replacingPart(cid)
    }

    func retireRetainedPlayback(reason: String) {
        retainedPlaybackAdmission.revoke()
        guard let request = retainedPlaybackRequest else { return }
        retainedPlaybackRequest = nil
        StartupTrace.abort(reason, token: request.traceToken)
        if startupTraceToken == request.traceToken { startupTraceToken = nil }
    }

    private func ownsRetainedPlayback(_ request: RetainedPlaybackRequest) -> Bool {
        retainedPlaybackAdmission.admits(request.serial)
            && retainedScreenData == request.data && matchesRetainedScreenData(request.data)
            && playerLease == request.lease && PlayerViewModel.shared.isCurrentOwner(request.lease)
    }

    func resumeRetainedPlayback(
        data: CompletedScreenDataReceipt, owner: String, lease retainedLease: PlayerOwnerLease?
    ) async -> Bool {
        guard !Task.isCancelled, matchesRetainedScreenData(data), let info = videoInfo else { return false }
        let player = PlayerViewModel.shared
        let lease: PlayerOwnerLease
        if let retainedLease {
            guard retainedLease.owner == owner, player.isCurrentOwner(retainedLease) else { return false }
            lease = retainedLease
        } else {
            lease = player.claimOwnerLease(owner: owner)
        }
        adoptPlayerLease(lease)
        retireRetainedPlayback(reason: "playback-replaced")
        let request = RetainedPlaybackRequest(
            serial: retainedPlaybackAdmission.begin(), data: data, lease: lease,
            traceToken: StartupTrace.begin("vod-detail-retained")
        )
        retainedPlaybackRequest = request
        startupTraceToken = request.traceToken
        var succeeded = false
        defer { finishRetainedPlayback(request, succeeded: succeeded) }
        let page = info.pages?.first(where: { $0.cid == data.cid })
        let resumeLookup = await PlayerViewModel.serverResumePoint(
            aid: data.aid, cid: data.cid,
            duration: TimeInterval(page?.duration ?? info.duration), ownerLease: lease
        )
        guard !Task.isCancelled, ownsRetainedPlayback(request),
              case .load(let resumeAt) = resumeLookup.loadDecision() else { return false }
        StartupTrace.mark("resume-point-ready", token: request.traceToken)
        player.setAmbientCoverURL(info.pic, ownerLease: lease)
        let resolvedAspectRatioHint = page?.dimension?.effectiveAspectRatio
            ?? info.dimension?.effectiveAspectRatio
            ?? initialAspectRatioHint
        await player.loadVOD(
            aid: data.aid, cid: data.cid, bvid: info.bvid, resumeAt: resumeAt,
            portraitHint: page?.dimension?.isPortrait ?? info.dimension?.isPortrait,
            aspectRatioHint: resolvedAspectRatioHint,
            owner: owner, ownerLease: lease, startupTraceToken: request.traceToken,
            requestAdmission: { [weak self] in self?.ownsRetainedPlayback(request) == true }
        )
        guard !Task.isCancelled, ownsRetainedPlayback(request) else { return false }
        guard player.error == nil, player.unavailability == nil else {
            retainedScreenData = nil
            return false
        }
        player.setNowPlaying(
            title: info.title,
            artist: page.flatMap { $0.part.isEmpty ? nil : "P\($0.page) \($0.part)" } ?? info.owner.name,
            cover: info.pic
        )
        installNextPartHandler()
        restoreRetainedSideWork(request, info: info)
        PlayerLog.log("[VideoDetailVM] retained page resumed aid=\(data.aid) cid=\(data.cid) owner=\(owner)")
        succeeded = true
        return true
    }

    private func finishRetainedPlayback(_ request: RetainedPlaybackRequest, succeeded: Bool) {
        guard retainedPlaybackRequest?.serial == request.serial else { return }
        retainedPlaybackRequest = nil
        if !succeeded {
            StartupTrace.abort("retained-playback-withdrawn", token: request.traceToken)
            if startupTraceToken == request.traceToken { startupTraceToken = nil }
        }
    }

    private func restoreRetainedSideWork(_ request: RetainedPlaybackRequest, info: VideoInfo) {
        let data = request.data
        if currentTagSource == nil {
            let tags = prepareTags(aid: data.aid, cid: data.cid) { [weak self] in
                self?.ownsRetainedPlayback(request) == true
            }
            Task { await self.loadTags(tags) }
        }
        if onlineCount == nil { refreshOnlineCount(request: data.dataRequest, lease: request.lease) }
        let interactionReceipt = InteractionStateReceipt(
            dataRequest: data.dataRequest, aid: data.aid, accountSession: data.accountSession
        )
        if AuthManager.shared.isLoggedIn, interactionStateReceipt != interactionReceipt {
            Task { [weak self] in
                guard let self, self.ownsRetainedPlayback(request) else { return }
                await self.loadInteractionState(
                    aid: data.aid, request: data.dataRequest, lease: request.lease,
                    accountSession: data.accountSession
                )
            }
        }
        let sponsorBlock = SponsorBlockManager.shared
        if sponsorBlock.loadedVideoID != info.bvid || sponsorBlock.loadedCID != data.cid {
            Task { [weak self] in
                guard self?.ownsRetainedPlayback(request) == true else { return }
                await sponsorBlock.load(videoID: info.bvid, cid: data.cid)
            }
        }
    }
}

extension VideoDetailViewModel {
    struct InitialScreenMetadata {
        let info: VideoInfo
        let fetchedAt: ContinuousClock.Instant
        let readyMark: String
    }

    func initialScreenDataCandidate(for id: VideoID) -> VideoDetailScreenDataSnapshot? {
        guard VideoDetailReactivationPolicy.retainsScreenData,
              error == nil, unavailability == nil else { return nil }
        if let prehydrated = prehydratedScreenSnapshot, prehydrated.id == id {
            prehydratedScreenSnapshot = nil
            return prehydrated
        }
        return VideoDetailScreenDataCache.snapshot(for: id)
    }

    func initialScreenMetadata(
        id: VideoID, cached: VideoDetailScreenDataSnapshot?
    ) async throws -> InitialScreenMetadata {
        if let cached {
            return .init(info: cached.info, fetchedAt: cached.fetchedAt, readyMark: "video-info-cache-hit")
        }
        let info = try await VideoAPI.getVideoInfo(id: id)
        return .init(info: info, fetchedAt: .now, readyMark: "video-info-ready")
    }

    func initialRelatedVideos(aid: Int, cached: VideoDetailScreenDataSnapshot?) async throws -> [VideoCard] {
        if let cached, cached.hasLoadedRelated { return cached.related }
        return try await VideoAPI.getRelated(aid: aid)
    }

    func loadInitialTags(_ request: TagRequest, cached: VideoDetailScreenDataSnapshot?) {
        if let cached, let tags = cached.tags, tags.cid == request.source.cid,
           cached.accountSession == AuthManager.shared.sessionGeneration, request.admits() {
            tagPublication = TagPublication(source: request.source, tags: tags.values)
            return
        }
        Task {
            await self.loadTags(request)
            if request.admits(), self.currentTagSource == request.source {
                self.cacheIncrementalScreenData()
                self.cacheCompletedScreenData()
            }
        }
    }

    func cacheIncrementalScreenData(fallbackCached: VideoDetailScreenDataSnapshot? = nil) {
        guard VideoDetailReactivationPolicy.retainsScreenData,
              let context = activeScreenCacheContext,
              let lease = playerLease,
              ownsCurrentLoad(context.dataRequest, lease: lease),
              context.accountSession == AuthManager.shared.sessionGeneration,
              metadataAccountSession == context.accountSession,
              currentCommentSource?.videoID == context.id,
              currentCommentSource?.aid == context.aid,
              commentSourceGeneration == context.dataRequest,
              let info = videoInfo, info.aid == context.aid,
              let cid = currentCid,
              error == nil, unavailability == nil else { return }
        let matchingCached = fallbackCached.flatMap { cached in
            cached.id == context.id && cached.info.aid == info.aid && cached.accountSession == context.accountSession
                ? cached
                : nil
        }
        let hasLoadedRelated = context.hasLoadedRelated || (matchingCached?.hasLoadedRelated ?? false)
        let related: [VideoCard] = if context.hasLoadedRelated {
            relatedVideos
        } else {
            matchingCached?.related ?? relatedVideos
        }
        let tags: VideoDetailScreenDataSnapshot.Tags? = currentTagSource.flatMap { source in
            tagPublication.map { VideoDetailScreenDataSnapshot.Tags(cid: source.cid, values: $0.tags) }
        } ?? matchingCached?.tags.flatMap { $0.cid == cid ? $0 : nil }
        let previewComments: VideoDetailScreenDataSnapshot.PreviewComments? = if commentsClosed || !comments.isEmpty {
            VideoDetailScreenDataSnapshot.PreviewComments(
                items: Array(comments.prefix(2)),
                total: max(commentTotal, info.stat.reply),
                commentsClosed: commentsClosed
            )
        } else {
            cachedPreviewComments ?? matchingCached?.previewComments
        }
        let interaction: VideoDetailScreenDataSnapshot.InteractionSnapshot? =
            if interactionStateReceipt?.aid == info.aid || seededInteractionAid == info.aid {
                VideoDetailScreenDataSnapshot.InteractionSnapshot(
                    isFollowingUp: isFollowingUp,
                    isLiked: isLiked,
                    coinCount: coinCount,
                    isFavorited: isFavorited,
                    isInWatchLater: isInWatchLater,
                    defaultFolderId: defaultFolderId
                )
            } else {
                matchingCached?.interaction
            }
        VideoDetailScreenDataCache.store(.init(
            id: context.id,
            accountSession: context.accountSession,
            fetchedAt: context.fetchedAt,
            info: info,
            cid: cid,
            related: related,
            tags: tags,
            previewComments: previewComments,
            interaction: interaction,
            hasLoadedRelated: hasLoadedRelated
        ))
    }

    func cacheCompletedScreenData() {
        guard VideoDetailReactivationPolicy.retainsScreenData,
              let data = retainedScreenData, matchesRetainedScreenData(data), let info = videoInfo,
              error == nil, unavailability == nil else { return }
        let tags = currentTagSource.flatMap { source in
            tagPublication.map { VideoDetailScreenDataSnapshot.Tags(cid: source.cid, values: $0.tags) }
        }
        let previewComments: VideoDetailScreenDataSnapshot.PreviewComments? = if commentsClosed || !comments.isEmpty {
            VideoDetailScreenDataSnapshot.PreviewComments(
                items: Array(comments.prefix(2)),
                total: max(commentTotal, info.stat.reply),
                commentsClosed: commentsClosed
            )
        } else {
            cachedPreviewComments
        }
        let interaction: VideoDetailScreenDataSnapshot.InteractionSnapshot? =
            if interactionStateReceipt?.aid == info.aid || seededInteractionAid == info.aid {
                VideoDetailScreenDataSnapshot.InteractionSnapshot(
                    isFollowingUp: isFollowingUp,
                    isLiked: isLiked,
                    coinCount: coinCount,
                    isFavorited: isFavorited,
                    isInWatchLater: isInWatchLater,
                    defaultFolderId: defaultFolderId
                )
            } else {
                nil
            }
        VideoDetailScreenDataCache.store(.init(
            id: data.id, accountSession: data.accountSession, fetchedAt: data.fetchedAt,
            info: info, cid: data.cid, related: relatedVideos, tags: tags,
            previewComments: previewComments, interaction: interaction, hasLoadedRelated: true
        ))
    }
}
