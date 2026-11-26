import CoreGraphics
import Foundation
import Observation

struct VideoDetailLoadAdmission: Equatable, Sendable {
    private(set) var currentRequest: UInt64 = 0

    mutating func begin() -> UInt64 {
        currentRequest &+= 1
        return currentRequest
    }

    func admits(_ request: UInt64) -> Bool {
        request == currentRequest
    }

    mutating func revoke() {
        currentRequest &+= 1
    }
}

@MainActor
@Observable
final class VideoDetailViewModel {
    var videoInfo: VideoInfo?
    var relatedVideos: [VideoCard] = []
    @ObservationIgnored private var rawRelatedVideos: [VideoCard] = []
    var tagPublication: TagPublication?
    var tags: [VideoTag] { tagPublication?.tags ?? [] }
    @ObservationIgnored var tagRequestSerial: UInt64 = 0
    var comments: [CommentResult.CommentItem] = [] {
        didSet { commentRowsRevision &+= 1 }
    }
    @ObservationIgnored private(set) var commentRowsRevision: UInt64 = 0
    var isLoading = false
    var error: String?
    var unavailability: PlaybackUnavailability?
    private(set) var playerLease: PlayerOwnerLease?
    var commentTotal: Int = 0
    @ObservationIgnored private(set) var commentDeletionRevision: UInt64 = 0

    func removeComment(rpid: Int) {
        comments.removeAll { $0.rpid == rpid }
        commentTotal = max(0, commentTotal - 1)
        commentDeletionRevision &+= 1
    }
    var isLiked = false
    var coinCount = 0
    var isCoined: Bool { coinCount > 0 }
    var maxCoins: Int { videoInfo?.copyright == 1 ? 2 : 1 }
    var isFavorited = false
    var isInWatchLater = false
    var hasShared = false
    var tripleComboCelebrationTick: Int = 0
    var isFollowingUp: Bool?
    var defaultFolderId: Int?
    var toast: ToastMessage?
    var currentCid: Int?
    var onlineCount: String?

    init() {
        LocalContentFilterStore.shared.addObserver(self) { model in
            model.applyRelatedVideoContentFilters()
        }
    }

    private var loadedID: VideoID?

    func matchesLoadedVideo(_ id: VideoID) -> Bool {
        loadedID == id && videoInfo != nil
    }
    @ObservationIgnored var startupTraceToken: StartupTrace.Token?
    @ObservationIgnored private var initialAspectRatioHint: CGFloat?
    private var loadAdmission = VideoDetailLoadAdmission()
    @ObservationIgnored private var loadAccountSession: UUID?
    @ObservationIgnored var metadataAccountSession: UUID?
    @ObservationIgnored var retainedScreenData: CompletedScreenDataReceipt?
    @ObservationIgnored var retainedPlaybackAdmission = VideoDetailLoadAdmission()
    @ObservationIgnored var retainedPlaybackRequest: RetainedPlaybackRequest?
    @ObservationIgnored var interactionStateReceipt: InteractionStateReceipt?
    var commentSourceGeneration: UInt64 { loadAdmission.currentRequest }
    let commentUpload = CommentComposerUploadOwner()
    private let commentComposerIdentifier = UUID()
    private var commentReplacementEpoch: UInt64 = 0

    var commentComposerContext: CommentComposerUploadOwner.Context {
        .init(
            owner: commentComposerIdentifier,
            sourceRevision: commentSourceGeneration,
            replacementEpoch: commentReplacementEpoch
        )
    }

    func commentDraftWasReplaced() {
        commentReplacementEpoch &+= 1
        commentUpload.retire()
    }

    func hasCommentSource(for requestedID: VideoID) -> Bool {
        currentCommentSource?.videoID == requestedID
    }
    var currentCommentSource: CommentSource? {
        guard let source = commentMetadataSource,
              source.generation == commentSourceGeneration,
              source.videoID == loadedID, source.aid == videoInfo?.aid else { return nil }
        return source
    }
    func retainedCommentMetadataMatches(_ source: CommentSource, id: VideoID) -> Bool {
        source.videoID == id && loadedID == id && source.aid == videoInfo?.aid
    }
    var commentMetadataSource: CommentSource?
    var commentListReceipt: CommentListReceipt?
    var commentFeedback = CommentLoadFeedback()
    var commentAdmission = FeedLoadAdmission()
    var commentLoadingToken: FeedLoadToken?
    var commentRecoverySeed: UInt64?
    var commentRevocationWitness: CommentRevocationWitness?
    private var partAdmission = VideoDetailLoadAdmission()
    private var partSwitchInFlight: PartSwitchRequest?

    func adoptPlayerLease(_ lease: PlayerOwnerLease) {
        playerLease = lease
    }

    var commentPage = 1
    var commentsLoadedAid: Int?
    private var toastDismissTask: Task<Void, Never>?

    var commentSort: CommentSort = .top

    var commentsClosed = false

    var isLoadingComments: Bool { commentLoadingToken != nil }
    var commentsHaveMore = true

    var commentsReadyForNavigation: Bool {
        guard let source = currentCommentSource else { return false }
        return commentsLoadedAid == source.aid && commentListReceipt?.source == source
    }

    var commentsAwaitingInitialResponse: Bool {
        !commentsReadyForNavigation && (isLoading || (currentCommentSource != nil
            && (isLoadingComments || commentRecoverySeed == commentAdmission.generation)))
    }

    static func isClosedCommentsError(_ error: any Error) -> Bool {
        if case .apiError(let code, _)? = error as? BiliError {
            return code == 12002 || code == 12061
        }
        return false
    }

    func showToast(_ text: String, style: ToastMessage.Style) {
        toastDismissTask?.cancel()
        toast = ToastMessage(text: text, style: style)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    struct CrossPartResumePlan: Equatable, Sendable {
        let targetPage: VideoInfo.VideoPage
        let resumeAt: TimeInterval?
        let resumedPartNumber: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.targetPage.cid == rhs.targetPage.cid
                && lhs.targetPage.page == rhs.targetPage.page
                && lhs.targetPage.part == rhs.targetPage.part
                && lhs.targetPage.duration == rhs.targetPage.duration
                && lhs.resumeAt == rhs.resumeAt
                && lhs.resumedPartNumber == rhs.resumedPartNumber
        }
    }

    static func resolveCrossPartResume(
        info: VideoInfo,
        initialCid: Int,
        preferredCid: Int?,
        hasPendingReturn: Bool,
        lastPlayCid: Int?,
        lastPlayTimeMs: Int?
    ) -> CrossPartResumePlan? {
        guard let pages = info.pages, pages.count > 1,
              preferredCid == nil,
              !hasPendingReturn,
              let lastPlayCid, lastPlayCid > 0, lastPlayCid != initialCid,
              let targetPage = pages.first(where: { $0.cid == lastPlayCid }) else {
            return nil
        }
        let partLookup = ServerResumeLookup.classify(
            lastPlayTimeMs: lastPlayTimeMs,
            duration: TimeInterval(targetPage.duration)
        )
        if partLookup == .watchedToEnd, targetPage.cid == pages.last?.cid {
            return nil
        }
        switch partLookup {
        case .resume(let seconds):
            return CrossPartResumePlan(
                targetPage: targetPage,
                resumeAt: seconds,
                resumedPartNumber: targetPage.page
            )
        case .noHistory, .watchedToEnd, .cancelled:
            return CrossPartResumePlan(
                targetPage: targetPage,
                resumeAt: nil,
                resumedPartNumber: targetPage.page
            )
        }
    }

    static func resolvedInitialCid(
        info: VideoInfo,
        pendingReturn: PendingMiniPlayerReturnVOD?,
        preferredCid: Int? = nil
    ) -> Int {
        if let pendingReturn,
           pendingReturn.aid == info.aid,
           pendingReturn.source == .ugc {
            if let pages = info.pages, !pages.isEmpty {
                return pages.contains(where: { $0.cid == pendingReturn.cid })
                    ? pendingReturn.cid
                    : info.cid
            }
            return pendingReturn.cid == info.cid ? pendingReturn.cid : info.cid
        }
        if let preferredCid, preferredCid > 0 {
            if let pages = info.pages, !pages.isEmpty {
                return pages.contains(where: { $0.cid == preferredCid })
                    ? preferredCid
                    : info.cid
            }
            return preferredCid == info.cid ? preferredCid : info.cid
        }
        return info.cid
    }

    @discardableResult
    func load(
        id: VideoID,
        preferredCid: Int? = nil,
        owner requestedOwner: String? = nil,
        lease retainedLease: PlayerOwnerLease? = nil,
        initialAspectRatioHint: CGFloat? = nil
    ) async -> Bool {
        if loadedID != id || initialAspectRatioHint != nil {
            self.initialAspectRatioHint = initialAspectRatioHint
        }
        let owner = requestedOwner ?? PlayerViewModel.vodOwner(id)
        if let info = videoInfo,
           loadedID == id,
           metadataAccountSession == AuthManager.shared.sessionGeneration,
           error == nil,
           unavailability == nil {
            let activeLease = retainedLease ?? playerLease
            if let pendingReturn = PlayerViewModel.shared.pendingMiniPlayerReturnVOD(
                forAid: info.aid,
                ownerLease: activeLease
            ) {
                let targetCid = Self.resolvedInitialCid(info: info, pendingReturn: pendingReturn)
                if targetCid != currentCid,
                   PlayerViewModel.shared.consumeMiniPlayerReturnIfLiveVOD(
                       aid: info.aid,
                       cid: targetCid,
                       bvid: info.bvid,
                       source: .ugc,
                       quality: nil,
                       ownerLease: activeLease,
                       startupTraceToken: nil,
                       mediaResetID: nil,
                       recoveryCoverIdentity: nil,
                       cdnSwitchID: nil,
                       streamRetryID: nil
                   ) {
                    currentCid = targetCid
                    if let activeLease {
                        adoptPlayerLease(activeLease)
                    }
                    retainedScreenData = retainedScreenData?.replacingPart(targetCid)
                    let page = info.pages?.first(where: { $0.cid == targetCid })
                    let artist: String = if let pages = info.pages, pages.count > 1,
                                            let page, !page.part.isEmpty {
                        "P\(page.page) \(page.part)"
                    } else {
                        info.owner.name
                    }
                    PlayerViewModel.shared.setNowPlaying(
                        title: info.title,
                        artist: artist,
                        cover: info.pic
                    )
                    installNextPartHandler()
                    Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: targetCid) }
                    let tagReq = prepareTags(aid: info.aid, cid: targetCid, retainsDisplay: true) { [weak self] in
                        self?.videoInfo?.aid == info.aid && self?.currentCid == targetCid
                    }
                    Task { await self.loadTags(tagReq) }
                    refreshOnlineCount()
                    recoverCommentsAfterProvedLiveReactivation(id: id)
                    PlayerLog.log(
                        "[VideoDetailVM] adopted mini-player advanced part " +
                        "aid=\(info.aid) cid=\(targetCid) owner=\(owner)"
                    )
                    return true
                }
            }
        }
        let retainedData = retainedDataForActivation(id: id)
        let decision = VideoDetailReactivationPolicy.decision(
            alreadyLive: isLiveReactivation(id: id, owner: owner, retainedLease: retainedLease),
            dataRetained: retainedData != nil
        )
        if decision == .alreadyLive {
            let player = PlayerViewModel.shared
            if let info = videoInfo, let cid = currentCid {
                _ = player.consumeMiniPlayerReturnIfLiveVOD(
                    aid: info.aid,
                    cid: cid,
                    bvid: info.bvid,
                    source: .ugc,
                    quality: nil,
                    ownerLease: retainedLease ?? playerLease,
                    startupTraceToken: nil,
                    mediaResetID: nil,
                    recoveryCoverIdentity: nil,
                    cdnSwitchID: nil,
                    streamRetryID: nil
                )
                installNextPartHandler()
            }
            recoverCommentsAfterProvedLiveReactivation(id: id)
            PlayerLog.log(
                "[VideoDetailVM] re-activation is a no-op — already live " +
                "aid=\(videoInfo?.aid ?? 0) cid=\(currentCid ?? 0) " +
                "t=\(String(format: "%.1f", player.mediaTime))s owner=\(owner)"
            )
            return true
        }
        if decision == .dataRetained, let retainedData {
            return await resumeRetainedPlayback(data: retainedData, owner: owner, lease: retainedLease)
        }
        let cachedData = initialScreenDataCandidate(for: id)
        invalidateRetainedScreenData()
        let request = loadAdmission.begin()
        let accountSession = AuthManager.shared.sessionGeneration
        loadAccountSession = accountSession
        interactionStateReceipt = nil
        retireTags()
        commentUpload.retire()
        commentRevocationWitness = nil
        retireCommentRequests()
        isLoading = true
        error = nil
        unavailability = nil
        let traceToken = StartupTrace.begin("vod-detail")
        startupTraceToken = traceToken
        let lease: PlayerOwnerLease
        if let retainedLease {
            guard retainedLease.owner == owner,
                  PlayerViewModel.shared.isCurrentOwner(retainedLease) else {
                StartupTrace.abort("stale-owner", token: traceToken)
                if loadAdmission.admits(request) {
                    isLoading = false
                }
                return false
            }
            lease = retainedLease
        } else {
            lease = PlayerViewModel.shared.claimOwnerLease(owner: owner)
        }
        playerLease = lease
        defer {
            if loadAdmission.admits(request) {
                isLoading = false
            }
        }

        do {
            let metadata = try await initialScreenMetadata(id: id, cached: cachedData)
            let info = metadata.info
            guard ownsCurrentLoad(request, lease: lease) else {
                StartupTrace.abort("stale-page-request", token: traceToken)
                return false
            }
            self.videoInfo = info
            metadataAccountSession = accountSession
            let fetchedAt = metadata.fetchedAt
            StartupTrace.mark(metadata.readyMark, token: traceToken)
            self.loadedID = id
            commentMetadataSource = CommentSource(videoID: id, aid: info.aid, generation: request)
            commentRevocationWitness = nil
            commentListReceipt = nil
            commentFeedback = CommentLoadFeedback()
            let pendingReturn = PlayerViewModel.shared.pendingMiniPlayerReturnVOD(
                forAid: info.aid,
                ownerLease: lease
            )
            let initialCid = Self.resolvedInitialCid(
                info: info,
                pendingReturn: pendingReturn,
                preferredCid: preferredCid
            )
            let initialPage = info.pages?.first(where: { $0.cid == initialCid })
            self.currentCid = initialCid
            let initialPartBaseline = partAdmission.currentRequest
            comments = []
            commentPage = 1
            commentsHaveMore = true
            commentsClosed = false
            commentsLoadedAid = nil
            PlayerViewModel.shared.setAmbientCoverURL(info.pic, ownerLease: lease)

            Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: initialCid) }
            let tagRequest = prepareTags(aid: info.aid, cid: initialCid) { [weak self] in
                guard let self else { return false }
                return self.ownsCurrentLoad(request, lease: lease)
                    && self.partAdmission.admits(initialPartBaseline)
                    && self.currentCid == initialCid
            }
            loadInitialTags(tagRequest, cached: cachedData)

            async let related = loadInitialRelatedVideos(
                aid: info.aid, cached: cachedData, request: request, lease: lease
            )
            let initialComments = prepareCommentRequest(purpose: .initial, from: currentCommentSource)
            async let firstComments: Void = loadInitialComments(
                initialComments, request: request, lease: lease
            )
            let partDuration = initialPage?.duration ?? info.duration
            let player = PlayerViewModel.shared
            let isLiveMiniPlayerReturn = player.matchesLiveMiniPlayerReturnVOD(
                aid: info.aid,
                cid: initialCid,
                source: .ugc,
                ownerLease: lease
            )
            let isAlreadyPlayingTargetVOD = !isLiveMiniPlayerReturn
                && player.isCurrentOwner(lease)
                && player.mode == .vod
                && player.currentAid == info.aid
                && player.currentCid == initialCid
                && player.currentSource == .ugc
                && player.currentURL != nil
                && !player.currentPlaybackTerminalState.isTerminal
                && player.error == nil
                && player.unavailability == nil
                && !player.terminalOpenFailure
            let resumeMetadata: ServerResumeMetadata
            if isLiveMiniPlayerReturn || isAlreadyPlayingTargetVOD {
                PlayerLog.log(
                    "[VideoDetailVM] skipping serverResumePoint for live session " +
                    "aid=\(info.aid) cid=\(initialCid)"
                )
                resumeMetadata = .noHistory
            } else {
                resumeMetadata = await PlayerViewModel.serverResumeMetadata(
                    aid: info.aid,
                    cid: initialCid,
                    duration: TimeInterval(partDuration),
                    ownerLease: lease
                )
            }
            guard ownsCurrentLoad(request, lease: lease) else {
                StartupTrace.abort("stale-page-request", token: traceToken)
                return false
            }
            let initialPartStillSelected: () -> Bool = {
                self.ownsCurrentLoad(request, lease: lease)
                    && self.partAdmission.admits(initialPartBaseline)
                    && self.currentCid == initialCid
                    && self.partSwitchInFlight == nil
            }
            var effectiveCid = initialCid
            var effectivePage = initialPage
            if initialPartStillSelected() {
                if isAlreadyPlayingTargetVOD {
                    let resolvedAspectRatioHint = initialPage?.dimension?.effectiveAspectRatio
                        ?? info.dimension?.effectiveAspectRatio
                        ?? self.initialAspectRatioHint
                    player.applyAspectRatioHint(resolvedAspectRatioHint)
                    StartupTrace.abort("already-playing-target-vod", token: traceToken)
                    PlayerLog.log(
                        "[VideoDetailVM] adopted live playback without reload aid=\(info.aid) cid=\(initialCid)"
                    )
                } else {
                    guard case .load(let rawResumeAt) = resumeMetadata.lookup.loadDecision() else {
                        StartupTrace.abort("resume-lookup-cancelled", token: traceToken)
                        PlayerLog.log(
                            "[VideoDetailVM] load aborted — resume lookup cancelled aid=\(info.aid) cid=\(initialCid)"
                        )
                        return false
                    }
                    let crossPart = Self.resolveCrossPartResume(
                        info: info,
                        initialCid: initialCid,
                        preferredCid: preferredCid,
                        hasPendingReturn: pendingReturn != nil,
                        lastPlayCid: resumeMetadata.lastPlayCid,
                        lastPlayTimeMs: resumeMetadata.lastPlayTimeMs
                    )
                    let effectiveResumeAt: TimeInterval?
                    let resumedPartNumber: Int?
                    if let crossPart {
                        effectiveCid = crossPart.targetPage.cid
                        effectivePage = crossPart.targetPage
                        self.currentCid = effectiveCid
                        PlayerViewModel.shared.clearPlayerInfoHandoff(matching: lease)
                        let switchedCid = effectiveCid
                        Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: switchedCid) }
                        let crossPartTagRequest = prepareTags(aid: info.aid, cid: switchedCid) { [weak self] in
                            guard let self else { return false }
                            return self.ownsCurrentLoad(request, lease: lease)
                                && self.partAdmission.admits(initialPartBaseline)
                                && self.currentCid == switchedCid
                        }
                        loadInitialTags(crossPartTagRequest, cached: nil)
                        effectiveResumeAt = crossPart.resumeAt
                        resumedPartNumber = crossPart.resumedPartNumber
                        PlayerLog.log(
                            "[VideoDetailVM] cross-part resume aid=\(info.aid) " +
                            "cid=\(initialCid)→\(effectiveCid) (P\(crossPart.resumedPartNumber)) " +
                            "resumeAt=\(crossPart.resumeAt.map { String(format: "%.0fs", $0) } ?? "0s")"
                        )
                    } else {
                        if let lastPlayCid = resumeMetadata.lastPlayCid,
                           lastPlayCid > 0,
                           lastPlayCid != initialCid {
                            effectiveResumeAt = nil
                        } else {
                            effectiveResumeAt = rawResumeAt
                        }
                        if let pages = info.pages, pages.count > 1,
                           let page = initialPage,
                           preferredCid != nil,
                           page.page > 1,
                           let effectiveResumeAt, effectiveResumeAt > 2 {
                            resumedPartNumber = page.page
                        } else {
                            resumedPartNumber = nil
                        }
                    }
                    let resolvedAspectRatioHint = effectivePage?.dimension?.effectiveAspectRatio
                        ?? info.dimension?.effectiveAspectRatio
                        ?? self.initialAspectRatioHint
                    let targetCid = effectiveCid
                    StartupTrace.mark("resume-point-ready", token: traceToken)
                    await PlayerViewModel.shared.loadVOD(
                        aid: info.aid, cid: targetCid, bvid: info.bvid,
                        resumeAt: effectiveResumeAt,
                        resumedPartNumber: resumedPartNumber,
                        portraitHint: effectivePage?.dimension?.isPortrait ?? info.dimension?.isPortrait,
                        aspectRatioHint: resolvedAspectRatioHint,
                        owner: lease.owner,
                        ownerLease: lease,
                        startupTraceToken: traceToken,
                        requestAdmission: { [weak self] in
                            guard let self else { return false }
                            return self.ownsCurrentLoad(request, lease: lease)
                                && self.partAdmission.admits(initialPartBaseline)
                                && self.currentCid == targetCid
                                && self.partSwitchInFlight == nil
                        }
                    )
                }
            } else {
                StartupTrace.abort("superseded-by-part-switch", token: traceToken)
                let cidDesc = self.currentCid ?? -1
                PlayerLog.log(
                    "[VideoDetailVM] initial part cid=\(initialCid) skipped (superseded by part switch, cid=\(cidDesc))"
                )
            }

            let relatedLoaded = await related
            await firstComments
            guard ownsCurrentLoad(request, lease: lease) else { return false }
            let settledEffectiveCid = effectiveCid
            let effectivePartStillSelected = self.ownsCurrentLoad(request, lease: lease)
                && self.partAdmission.admits(initialPartBaseline)
                && self.currentCid == settledEffectiveCid
                && self.partSwitchInFlight == nil
            if effectivePartStillSelected {
                let artist: String = if let pages = info.pages, pages.count > 1,
                                        let page = effectivePage, !page.part.isEmpty {
                    "P\(page.page) \(page.part)"
                } else {
                    info.owner.name
                }
                PlayerViewModel.shared.setNowPlaying(
                    title: info.title,
                    artist: artist,
                    cover: info.pic
                )
                installNextPartHandler()
            }
            let settledCid = currentCid ?? settledEffectiveCid
            retainCompletedScreenData(
                .init(id: id, aid: info.aid, cid: settledCid, dataRequest: request,
                      accountSession: accountSession, fetchedAt: fetchedAt),
                relatedLoaded: relatedLoaded, partSwitchPending: partSwitchInFlight != nil
            )
            if effectivePartStillSelected {
                refreshOnlineCount(request: request, lease: lease)
            }

            if AuthManager.shared.isLoggedIn {
                Task {
                    await self.loadInteractionState(
                        aid: info.aid,
                        request: request,
                        lease: lease,
                        accountSession: accountSession
                    )
                }
            }
            return true
        } catch {
            guard ownsCurrentLoad(request, lease: lease) else {
                StartupTrace.abort("stale-page-request", token: traceToken)
                return false
            }
            let reason = PlaybackAvailabilityPolicy.unavailability(forAny: error)
            self.unavailability = reason
            self.error = reason?.message ?? error.localizedDescription
            if let reason, PlayerViewModel.shared.isCurrentOwner(lease) {
                PlayerViewModel.shared.markUnavailable(reason, detail: "detail-load")
            }
            if retainedLease == nil {
                PlayerViewModel.shared.endOwnerPlayback(lease: lease)
            }
            StartupTrace.abort("load-failed", token: traceToken)
            PlayerLog.log(
                "[VideoDetailVM] load failed (unavailable=\(reason?.rawValue ?? "no")): \(error)"
            )
            return false
        }
    }

    private func loadInitialRelatedVideos(
        aid: Int, cached: VideoDetailScreenDataSnapshot?, request: UInt64, lease: PlayerOwnerLease
    ) async -> Bool {
        let videos = try? await initialRelatedVideos(aid: aid, cached: cached)
        guard !Task.isCancelled, ownsCurrentLoad(request, lease: lease) else { return false }
        setRawRelatedVideos(videos ?? [])
        return videos != nil
    }

    func setRawRelatedVideos(_ videos: [VideoCard]) {
        rawRelatedVideos = videos
        applyRelatedVideoContentFilters()
    }

    func applyRelatedVideoContentFilters() {
        guard !rawRelatedVideos.isEmpty || !relatedVideos.isEmpty else { return }
        let store = LocalContentFilterStore.shared
        relatedVideos = rawRelatedVideos.filter { video in
            !store.shouldHideVideo(
                aid: video.aid,
                bvid: video.bvid,
                mid: video.owner.mid,
                title: video.title,
                includeCloudBlocklist: true
            )
        }
    }

    private func loadInitialComments(
        _ initial: PreparedCommentRequest?, request: UInt64, lease: PlayerOwnerLease
    ) async {
        guard let initial else { return }
        var succeeded = false
        defer { finishCommentRequest(initial, succeeded: succeeded) }
        guard !Task.isCancelled, ownsCurrentLoad(request, lease: lease) else { return }
        let response = await fetchCommentResponse(initial)
        guard !Task.isCancelled, ownsCurrentLoad(request, lease: lease) else { return }
        succeeded = consumeCommentResponse(response, for: initial)
    }

    // MARK: - Multi-P parts

    func installNextPartHandler() {
        let player = PlayerViewModel.shared
        guard let info = videoInfo, let cid = currentCid else {
            player.onPreviousEpisode = nil
            player.onNextEpisode = nil
            player.onPlaybackEnded = nil
            return
        }

        if let existing = player.playbackQueue,
           let synced = reusableExistingQueue(existing, info: info, cid: cid) {
            player.setPlaybackQueue(
                synced,
                liveNavigationHandler: makeLivePartNavigationHandler(aid: info.aid)
            )
            return
        }

        let routeVideoID = loadedID ?? (info.bvid.isEmpty ? .aid(info.aid) : .bvid(info.bvid))
        if let season = info.ugcSeason,
           let seasonQueue = PlaybackQueueContext.ugcSeason(
               season, info: info, videoID: routeVideoID, currentCid: cid
           ) {
            player.setPlaybackQueue(
                seasonQueue,
                liveNavigationHandler: makeLivePartNavigationHandler(aid: info.aid)
            )
            return
        }

        guard let pages = info.pages, pages.count > 1,
              pages.contains(where: { $0.cid == cid }) else {
            player.setPlaybackQueue(nil)
            return
        }

        let queue = PlaybackQueueContext.videoParts(
            info: info, videoID: routeVideoID, currentCid: cid
        )
        player.setPlaybackQueue(
            queue,
            liveNavigationHandler: makeLivePartNavigationHandler(aid: info.aid)
        )
    }

    private func reusableExistingQueue(
        _ existing: PlaybackQueueContext,
        info: VideoInfo,
        cid: Int
    ) -> PlaybackQueueContext? {
        switch existing.kind {
        case .playlist:
            guard existing.matchingItem(aid: info.aid, cid: cid, source: .ugc) != nil
                || existing.items.contains(where: { $0.aid == info.aid && $0.source == .ugc }) else {
                return nil
            }
            let routeVideoID = loadedID ?? (info.bvid.isEmpty ? .aid(info.aid) : .bvid(info.bvid))
            let expanded = existing.expandingMultiPartVideo(
                info: info,
                videoID: routeVideoID,
                currentCid: cid
            )
            return expanded.selecting(aid: info.aid, cid: cid)
        case .ugcSeason(let existingSeasonId):
            guard existing.matchingItem(aid: info.aid, cid: cid, source: .ugc) != nil else {
                return nil
            }
            let expectedParts = max(1, info.pages?.count ?? 1)
            let matchingPartCount = existing.items.filter { $0.aid == info.aid }.count
            guard existingSeasonId == info.ugcSeason?.id, matchingPartCount == expectedParts else {
                return nil
            }
            return existing.selecting(aid: info.aid, cid: cid)
        case .videoParts, .bangumiSeason:
            return nil
        }
    }

    private func makeLivePartNavigationHandler(aid: Int) -> (Int) -> Bool {
        { [weak self] offset in
            guard let self, self.videoInfo?.aid == aid else { return false }
            if let queue = PlayerViewModel.shared.playbackQueue {
                guard let nextItem = queue.item(atOffset: offset),
                      nextItem.aid == aid,
                      nextItem.cid != self.currentCid,
                      let targetPage = self.videoInfo?.pages?.first(where: { $0.cid == nextItem.cid }) else {
                    return false
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.showToast(String(localized: "Playing P\(targetPage.page)…"), style: .progress)
                    await self.switchPage(targetPage)
                }
                return true
            }
            guard self.canPlayAdjacentPart(offset: offset) else { return false }
            Task { @MainActor [weak self] in
                await self?.playAdjacentPart(offset: offset)
            }
            return true
        }
    }

    func switchPage(_ page: VideoInfo.VideoPage) async {
        guard let lease = playerLease,
              PlayerViewModel.shared.isCurrentOwner(lease),
              let info = videoInfo,
              loadedID != nil,
              page.cid != currentCid else { return }
        retireRetainedPlayback(reason: "part-switch")
        let request = partSwitchRequest(loadRequest: loadAdmission.currentRequest)
        defer { settlePartSwitch(request) }
        currentCid = page.cid
        Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: page.cid) }
        let tagRequest = prepareTags(aid: info.aid, cid: page.cid, retainsDisplay: true) { [weak self] in
            self?.ownsPartSwitch(request, lease: lease) == true
        }
        Task { await self.loadTags(tagRequest) }
        let owner = lease.owner
        PlayerViewModel.shared.claim(owner: owner)
        let resumeMetadata = await PlayerViewModel.serverResumeMetadata(
            aid: info.aid,
            cid: page.cid,
            duration: TimeInterval(page.duration),
            ownerLease: lease
        )
        guard ownsPartSwitch(request, lease: lease) else {
            PlayerLog.log("[VideoDetailVM] part switch to cid=\(page.cid) withdrawn before loadVOD")
            return
        }
        guard case .load(let rawResumeAt) = resumeMetadata.lookup.loadDecision() else {
            PlayerLog.log("[VideoDetailVM] part switch aborted — resume lookup cancelled cid=\(page.cid)")
            return
        }
        let resumeAt: TimeInterval? = if let lastPlayCid = resumeMetadata.lastPlayCid,
                                         lastPlayCid > 0,
                                         lastPlayCid != page.cid {
            nil
        } else {
            rawResumeAt
        }
        PlayerViewModel.shared.setAmbientCoverURL(info.pic, ownerLease: lease)
        await PlayerViewModel.shared.loadVOD(
            aid: info.aid, cid: page.cid, bvid: info.bvid,
            resumeAt: resumeAt,
            portraitHint: page.dimension?.isPortrait ?? info.dimension?.isPortrait,
            aspectRatioHint: page.dimension?.effectiveAspectRatio
                ?? info.dimension?.effectiveAspectRatio
                ?? self.initialAspectRatioHint,
            owner: lease.owner,
            ownerLease: lease,
            startupTraceToken: nil,
            requestAdmission: { [weak self] in
                guard let self else { return false }
                return self.ownsPartSwitch(request, lease: lease)
            }
        )
        refreshOnlineCount()
        guard ownsPartSwitch(request, lease: lease) else { return }
        installNextPartHandler()
        PlayerViewModel.shared.setNowPlaying(
            title: info.title,
            artist: page.part.isEmpty ? info.owner.name : "P\(page.page) \(page.part)",
            cover: info.pic
        )
        retainCompletedPart(cid: page.cid)
    }

    func releasePlayback() {
        if let lease = playerLease, PlayerViewModel.shared.isCurrentOwner(lease),
           PlayerViewModel.shared.error != nil || PlayerViewModel.shared.unavailability != nil {
            invalidateRetainedScreenData()
        }
        cacheCompletedScreenData()
        if let lease = playerLease,
           PlayerViewModel.shared.endOwnerPlayback(lease: lease) == .leaseRetained {
            return
        }
        retireRetainedPlayback(reason: "screen-disappear")
        playerLease = nil
        if let token = startupTraceToken {
            StartupTrace.abort("screen-disappear", token: token)
        }
        startupTraceToken = nil
    }

    func clearPlayerLeaseAfterLocalFilterExit() {
        playerLease = nil
    }

    func revokeLoadForRouteDeparture() {
        retireRetainedPlayback(reason: "route-departed")
        if isLoading {
            loadAdmission.revoke()
            commentUpload.retire()
            commentRevocationWitness = commentMetadataSource.map {
                CommentRevocationWitness(source: $0, generation: loadAdmission.currentRequest)
            }
            retireCommentRequests()
            isLoading = false
            if let token = startupTraceToken {
                StartupTrace.abort("route-departed", token: token)
            }
            startupTraceToken = nil
            PlayerLog.log("[VideoDetailVM] in-flight load revoked — route departed")
        }
        if partSwitchInFlight != nil {
            partAdmission.revoke()
            partSwitchInFlight = nil
            PlayerLog.log("[VideoDetailVM] in-flight part switch revoked — route departed")
        }
    }

    private struct PartSwitchRequest: Equatable {
        let loadRequest: UInt64
        let partRequest: UInt64
    }

    private func partSwitchRequest(loadRequest: UInt64) -> PartSwitchRequest {
        let request = PartSwitchRequest(
            loadRequest: loadRequest,
            partRequest: partAdmission.begin()
        )
        partSwitchInFlight = request
        return request
    }

    private func settlePartSwitch(_ request: PartSwitchRequest) {
        if partSwitchInFlight == request { partSwitchInFlight = nil }
    }

    private func ownsPartSwitch(_ request: PartSwitchRequest, lease: PlayerOwnerLease) -> Bool {
        partAdmission.admits(request.partRequest)
            && ownsCurrentLoad(request.loadRequest, lease: lease)
    }

    private func canPlayAdjacentPart(offset: Int) -> Bool {
        guard let pages = videoInfo?.pages, pages.count > 1,
              let cid = currentCid,
              let index = pages.firstIndex(where: { $0.cid == cid }),
              pages.indices.contains(index + offset) else {
            return false
        }
        return true
    }

    func playAdjacentPart(offset: Int) async {
        guard let pages = videoInfo?.pages, pages.count > 1,
              let cid = currentCid,
              let index = pages.firstIndex(where: { $0.cid == cid }),
              pages.indices.contains(index + offset)
        else { return }
        let target = pages[index + offset]
        showToast(String(localized: "Playing P\(target.page)…"), style: .progress)
        await switchPage(target)
    }

    func playNextPart() async {
        await playAdjacentPart(offset: 1)
    }

    private func ownsCurrentLoad(_ request: UInt64, lease: PlayerOwnerLease) -> Bool {
        loadAdmission.admits(request) && PlayerViewModel.shared.isCurrentOwner(lease)
            && loadAccountSession == AuthManager.shared.sessionGeneration
    }

    private func retainedDataForActivation(id: VideoID) -> CompletedScreenDataReceipt? {
        guard partSwitchInFlight == nil else { return nil }
        return eligibleRetainedScreenData(for: id)
    }

    private func isLiveReactivation(
        id: VideoID,
        owner: String,
        retainedLease: PlayerOwnerLease?
    ) -> Bool {
        guard metadataAccountSession == AuthManager.shared.sessionGeneration else { return false }
        let player = PlayerViewModel.shared
        return VideoDetailReactivationPolicy.isAlreadyLive(
            .init(
                requestedID: id,
                loadedID: loadedID,
                hasLoadedMetadata: videoInfo != nil,
                screenAid: videoInfo?.aid,
                screenCid: currentCid,
                screenReportedFailure: error != nil || unavailability != nil,
                requestedOwner: owner,
                retainedLeaseOwner: retainedLease?.owner,
                retainedLeaseIsCurrentOwner: retainedLease
                    .map { player.isCurrentOwner($0) } ?? false,
                targetMode: .vod,
                targetSource: .ugc,
                playerMode: player.mode,
                playerAid: player.currentAid,
                playerCid: player.currentCid,
                playerSource: player.currentSource,
                playerHasSource: player.currentURL != nil,
                playerReportedFailure: player.error != nil
                    || player.unavailability != nil
            )
        )
    }

    func refreshOnlineCount(
        request: UInt64? = nil,
        lease: PlayerOwnerLease? = nil
    ) {
        guard let info = videoInfo, let cid = currentCid else { return }
        let accountSession = AuthManager.shared.sessionGeneration
        Task { [weak self] in
            let result = try? await VideoAPI.getOnlineTotal(aid: info.aid, cid: cid)
            guard let self,
                  accountSession == AuthManager.shared.sessionGeneration,
                  self.videoInfo?.aid == info.aid,
                  self.currentCid == cid,
                  request.map({ self.loadAdmission.admits($0) }) ?? true,
                  lease.map(PlayerViewModel.shared.isCurrentOwner) ?? true
            else { return }
            self.onlineCount = result?.total
        }
    }

    func loadInteractionState(
        aid: Int,
        request: UInt64? = nil,
        lease: PlayerOwnerLease? = nil,
        accountSession: UUID
    ) async {
        guard accountSession == AuthManager.shared.sessionGeneration else { return }
        async let liked = try? VideoAPI.hasLiked(aid: aid)
        async let coined = try? VideoAPI.hasCoined(aid: aid)
        async let favoured = try? VideoAPI.hasFavoured(aid: aid)
        async let folder = try? VideoAPI.getDefaultFolder()
        async let watchLater = try? UserAPI.getWatchLater(ps: 100)

        let likedValue = await liked ?? 0
        let coinValue = await coined ?? 0
        let favoriteValue = await favoured ?? false
        let folderValue = await folder
        let watchLaterValue = await watchLater
        guard accountSession == AuthManager.shared.sessionGeneration, videoInfo?.aid == aid,
              request.map({ loadAdmission.admits($0) }) ?? true,
              lease.map(PlayerViewModel.shared.isCurrentOwner) ?? true
        else { return }

        if let mid = videoInfo?.owner.mid,
           String(mid) != AuthManager.shared.dedeUserID {
            let relation = try? await UserAPI.getRelation(mid: mid)
            guard accountSession == AuthManager.shared.sessionGeneration, videoInfo?.aid == aid,
                  request.map({ loadAdmission.admits($0) }) ?? true,
                  lease.map(PlayerViewModel.shared.isCurrentOwner) ?? true
            else { return }
            isFollowingUp = relation?.isFollowing
        }

        isLiked = likedValue == 1
        coinCount = coinValue
        isFavorited = favoriteValue
        defaultFolderId = folderValue
        isInWatchLater = watchLaterValue?.list?.contains { $0.aid == aid } ?? false
        if let request {
            interactionStateReceipt = InteractionStateReceipt(
                dataRequest: request, aid: aid, accountSession: accountSession
            )
        }
    }

    func toggleFollowUp() async {
        guard let mid = videoInfo?.owner.mid, let following = isFollowingUp else { return }
        do {
            if following {
                try await UserAPI.unfollow(mid: mid)
            } else {
                try await UserAPI.follow(mid: mid)
            }
            isFollowingUp = !following
        } catch {
            PlayerLog.log("[VideoDetailVM] follow toggle failed: \(error)")
            if case let .apiError(code, message) = error {
                showToast(String(localized: "Follow failed (\(code)): \(message)"), style: .error)
            } else {
                showToast(String(localized: "Follow failed"), style: .error)
            }
        }
    }

    func toggleLike() async {
        guard let aid = videoInfo?.aid else { return }
        do {
            _ = try await VideoAPI.like(aid: aid, like: !isLiked)
            isLiked.toggle()
            let likes = videoInfo?.stat.like ?? 0
            videoInfo?.stat.like = isLiked ? likes + 1 : max(0, likes - 1)
        } catch {
            PlayerLog.log("[VideoDetailVM] like failed: \(error)")
            guard !Task.isCancelled, !error.isCancellation else { return }
            if case let .apiError(code, message) = error {
                showToast(String(localized: "Like failed (\(code)): \(message)"), style: .error)
            } else {
                showToast(String(localized: "Like failed"), style: .error)
            }
        }
    }

    func addCoin(multiply: Int = 1) async {
        guard let aid = videoInfo?.aid else { return }
        guard coinCount + multiply <= maxCoins else {
            showToast(maxCoins == 1 ? String(localized: "Reposts accept 1 coin max") : String(localized: "Already gave the maximum coins"), style: .warning)
            return
        }
        do {
            _ = try await VideoAPI.addCoin(aid: aid, multiply: multiply)
            coinCount += multiply
            videoInfo?.stat.coin += multiply
            showToast(multiply == 2 ? String(localized: "2 coins added") : String(localized: "Coin added"), style: .success)
        } catch {
            PlayerLog.log("[VideoDetailVM] coin failed: \(error)")
            if case let .apiError(code, message) = error {
                showToast(String(localized: "Coin failed (\(code)): \(message)"), style: .error)
            } else {
                showToast(String(localized: "Coin failed"), style: .error)
            }
        }
    }

    var favFolders: [FavFolderListResult.FavFolder] = []

    func loadFavFolders() async {
        guard let aid = videoInfo?.aid else { return }
        do {
            favFolders = try await VideoAPI.getFavFolders(aid: aid)
            PlayerLog.log("[VideoDetailVM] fav folders: \(favFolders.map { "\($0.id) \"\($0.title)\" fav=\($0.containsVideo)" })")
        } catch {
            favFolders = []
            PlayerLog.log("[VideoDetailVM] load fav folders failed: \(error)")
        }
    }

    func applyFavorite(selectedIds: Set<Int>) async {
        guard let aid = videoInfo?.aid else { return }
        let current = Set(favFolders.filter(\.containsVideo).map(\.id))
        let add = selectedIds.subtracting(current)
        let del = current.subtracting(selectedIds)
        guard !add.isEmpty || !del.isEmpty else { return }

        do {
            _ = try await VideoAPI.dealFavorite(aid: aid, addIds: Array(add), delIds: Array(del))
            let wasFavorited = isFavorited
            isFavorited = !selectedIds.isEmpty
            let favorites = videoInfo?.stat.favorite ?? 0
            if !wasFavorited, isFavorited {
                videoInfo?.stat.favorite = favorites + 1
            } else if wasFavorited, !isFavorited {
                videoInfo?.stat.favorite = max(0, favorites - 1)
            }
        } catch {
            PlayerLog.log("[VideoDetailVM] favorite deal failed: \(error)")
        }
    }

    func shareVideo() async {
        guard let aid = videoInfo?.aid else { return }
        do {
            _ = try await VideoAPI.share(aid: aid)
            videoInfo?.stat.share += 1
            hasShared = true
        } catch {
            PlayerLog.log("[VideoDetailVM] share failed: \(error)")
            hasShared = true
        }
    }

    func toggleWatchLater() async {
        guard let aid = videoInfo?.aid else { return }
        do {
            if isInWatchLater {
                _ = try await UserAPI.removeFromWatchLater(aid: aid)
                isInWatchLater = false
                showToast(String(localized: "Removed from Watch Later"), style: .success)
            } else {
                _ = try await UserAPI.addToWatchLater(aid: aid)
                isInWatchLater = true
                showToast(String(localized: "Added to Watch Later"), style: .success)
            }
        } catch {
            PlayerLog.log("[VideoDetailVM] watch later toggle failed: \(error)")
            showToast(
                String(format: String(localized: "Watch Later failed: %@"), error.localizedDescription),
                style: .error
            )
        }
    }
}
