import Foundation
import Observation

enum BangumiDetailReactivationPolicy {
    struct Facts: Equatable, Sendable {
        let requestedSeasonId: Int
        let loadedSeasonId: Int?
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
        let targetMatchesLoadedContent = facts.loadedSeasonId == facts.requestedSeasonId
            && facts.loadedSeasonId != nil
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

@MainActor
@Observable
final class BangumiViewModel {
    var season: PGCSeasonInfo?
    var selectedEpisodeId: Int?
    var isLoading = false
    var error: String?

    var showContinueBanner = false
    private(set) var playerLease: PlayerOwnerLease?
    private(set) var resumeEpisode: PGCSeasonInfo.Episode?
    private var resumeSeconds: TimeInterval?
    private var bannerDismissTask: Task<Void, Never>?
    private var startupTraceToken: StartupTrace.Token?

    private var seasonId = 0
    private var loadedSeasonId: Int?
    private var episodePlaybackRequestSerial: UInt64 = 0

    func load(seasonId: Int) async {
        guard !Task.isCancelled else { return }
        let owner = PlayerViewModel.pgcOwner(seasonId)
        if isLiveReactivation(seasonId: seasonId, owner: owner) {
            let player = PlayerViewModel.shared
            PlayerLog.log(
                "[BangumiVM] re-activation is a no-op — already live " +
                "sid=\(selectedEpisodeId ?? 0) aid=\(currentEpisodeAid ?? 0) " +
                "cid=\(player.currentCid ?? 0) " +
                "t=\(String(format: "%.1f", player.mediaTime))s owner=\(owner)"
            )
            return
        }
        episodePlaybackRequestSerial &+= 1
        self.seasonId = seasonId
        let departures = routeDepartures
        isLoading = true
        error = nil
        let traceToken = StartupTrace.begin("pgc-detail")
        startupTraceToken = traceToken
        let lease = PlayerViewModel.shared.claimOwnerLease(owner: owner)
        playerLease = lease
        defer { isLoading = false }

        do {
            let info = try await PGCAPI.getSeason(seasonId: seasonId)
            guard admitsLoad(departures: departures, lease: lease) else { return }
            season = info
            loadedSeasonId = seasonId
            guard let episodes = info.episodes, !episodes.isEmpty else {
                error = String(localized: "This season has no playable episodes.")
                PlayerViewModel.shared.endOwnerPlayback(lease: lease)
                StartupTrace.abort("no-playable-episode", token: traceToken)
                return
            }
            let cloudSeconds = info.userStatus?.progress?.lastTime.map(TimeInterval.init)
            let laterMatch: PGCSeasonInfo.Episode? = {
                guard PlayerViewModel.resumePlayback,
                      let lastEpId = info.userStatus?.progress?.lastEpId,
                      let match = episodes.first(where: { $0.id == lastEpId }),
                      match.id != episodes[0].id
                else { return nil }
                return match
            }()

            if let laterMatch {
                PlayerLog.log("[BangumiVM] cloud progress at \(laterMatch.indexLabel) — starting E1, offering Continue banner")
                let initialRequestSerial = episodePlaybackRequestSerial &+ 1
                await play(episode: episodes[0])
                offerInitialContinueBanner(
                    firstEpisode: episodes[0],
                    progress: (episode: laterMatch, seconds: cloudSeconds),
                    requestSerial: initialRequestSerial,
                    departures: departures,
                    lease: lease
                )
            } else if let progress = info.userStatus?.progress, progress.lastEpId == episodes[0].id {
                PlayerLog.log("[BangumiVM] cloud progress on first episode — resuming in place at \(progress.lastTime ?? 0)s")
                await play(episode: episodes[0], cloudFallbackSeconds: cloudSeconds)
            } else {
                PlayerLog.log("[BangumiVM] no season resume — starting at \(episodes[0].indexLabel)")
                await play(episode: episodes[0])
            }
        } catch {
            guard admitsLoad(departures: departures, lease: lease) else {
                StartupTrace.abort("stale-page-request", token: traceToken)
                PlayerLog.log("[BangumiVM] load ended quietly — route departed or lease replaced")
                return
            }
            self.error = "\(error)"
            PlayerViewModel.shared.endOwnerPlayback(lease: lease)
            StartupTrace.abort("load-failed", token: traceToken)
            PlayerLog.log("[BangumiVM] load failed: \(error)")
        }

    }

    func resumeFromLastEpisode() async {
        guard let episode = resumeEpisode else { return }
        let seconds = resumeSeconds
        await play(episode: episode, cloudFallbackSeconds: seconds)
    }

    func dismissContinueBanner() {
        bannerDismissTask?.cancel()
        showContinueBanner = false
        resumeEpisode = nil
        resumeSeconds = nil
    }

    private func offerInitialContinueBanner(
        firstEpisode: PGCSeasonInfo.Episode,
        progress: (episode: PGCSeasonInfo.Episode, seconds: TimeInterval?),
        requestSerial: UInt64,
        departures: UInt64,
        lease: PlayerOwnerLease
    ) {
        guard !Task.isCancelled, firstEpisode.aid != nil, firstEpisode.cid != nil else { return }
        guard admitsEpisodePlayback(
            requestSerial: requestSerial,
            departures: departures,
            lease: lease
        ) else { return }
        resumeEpisode = progress.episode
        resumeSeconds = progress.seconds
        presentContinueBanner()
    }

    private func presentContinueBanner() {
        bannerDismissTask?.cancel()
        showContinueBanner = true
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.showContinueBanner = false
        }
    }

    func play(episode: PGCSeasonInfo.Episode, cloudFallbackSeconds: TimeInterval? = nil) async {
        guard !Task.isCancelled else { return }
        let departures = routeDepartures
        dismissContinueBanner()
        guard let aid = episode.aid, let cid = episode.cid else {
            PlayerLog.log("[BangumiVM] episode \(episode.id) has no aid/cid (badge=\(episode.badge ?? "-"))")
            error = if let badge = episode.badge {
                String(format: String(localized: "Episode unavailable (%@)"), badge)
            } else {
                String(localized: "Episode unavailable")
            }
            return
        }
        episodePlaybackRequestSerial &+= 1
        let requestSerial = episodePlaybackRequestSerial
        error = nil
        if selectedEpisodeId != episode.id || currentEpisodeAid != aid {
            commentSourceRevision &+= 1
            commentComposer.replaceWithEmptyDraft()
            commentAdmission.supersede()
            commentLoadingToken = nil
            commentsClosed = false
            commentFeedback = CommentLoadFeedback()
        }
        selectedEpisodeId = episode.id
        currentEpisodeAid = aid
        let commentSource = CommentListSource(aid: aid, revision: commentSourceRevision)
        let owner = PlayerViewModel.pgcOwner(seasonId)
        let lease: PlayerOwnerLease
        if let current = playerLease,
           current.owner == owner,
           PlayerViewModel.shared.isCurrentOwner(current) {
            PlayerViewModel.shared.claim(owner: owner)
            lease = current
        } else {
            lease = PlayerViewModel.shared.claimOwnerLease(owner: owner)
            playerLease = lease
        }

        loadInitialComments(from: commentSource)

        let resumeLookup = await PlayerViewModel.serverResumePoint(
            aid: aid,
            cid: cid,
            ownerLease: lease
        )
        guard admitsEpisodePlayback(
            requestSerial: requestSerial,
            departures: departures,
            lease: lease
        ) else { return }
        guard case .load(let resumeAt) = resumeLookup.loadDecision(
            cloudFallbackSeconds: cloudFallbackSeconds
        ) else {
            if let token = startupTraceToken {
                StartupTrace.abort("resume-lookup-cancelled", token: token)
            }
            PlayerLog.log("[BangumiVM] episode load aborted — resume lookup cancelled aid=\(aid) cid=\(cid)")
            return
        }
        guard !Task.isCancelled else { return }
        if resumeLookup == .noHistory, let fallback = resumeAt {
            PlayerLog.log("[BangumiVM] using season-progress last_time as resume point: \(Int(fallback))s")
        }

        SponsorBlockManager.shared.clear()

        PlayerViewModel.shared.setAmbientCoverURL(
            episode.cover ?? season?.cover,
            ownerLease: lease
        )

        await PlayerViewModel.shared.loadVOD(
            aid: aid, cid: cid, bvid: episode.bvid, source: .pgc(epId: episode.id), resumeAt: resumeAt,
            owner: lease.owner,
            ownerLease: lease,
            startupTraceToken: startupTraceToken,
            requestAdmission: { [weak self] in
                self?.admitsEpisodePlayback(
                    requestSerial: requestSerial,
                    departures: departures,
                    lease: lease
                ) ?? false
            }
        )

        guard admitsEpisodePlayback(
            requestSerial: requestSerial,
            departures: departures,
            lease: lease
        ) else { return }

        PlayerViewModel.shared.pgcSeasonContext = (sid: seasonId, type: season?.type)

        let episodes = season?.episodes ?? []
        let index = episodes.firstIndex(where: { $0.id == episode.id })
        let hasPrevious = (index ?? 0) > 0
        let hasNext = index.map { $0 + 1 < episodes.count } ?? false
        PlayerViewModel.shared.onPreviousEpisode = hasPrevious
            ? { [weak self] in Task { await self?.playAdjacentEpisode(offset: -1) } }
            : nil
        PlayerViewModel.shared.onNextEpisode = hasNext
            ? { [weak self] in Task { await self?.playAdjacentEpisode(offset: 1) } }
            : nil
        PlayerViewModel.shared.onPlaybackEnded = hasNext
            ? { [weak self] in Task { await self?.playAdjacentEpisode(offset: 1) } }
            : nil

        var segments: [(label: String, start: Double, end: Double)] = []
        if let op = episode.skip?.op, let s = op.start, let e = op.end, e > s {
            segments.append((label: "OP", start: Double(s), end: Double(e)))
        }
        if let ed = episode.skip?.ed, let s = ed.start, let e = ed.end, e > s {
            segments.append((label: "ED", start: Double(s), end: Double(e)))
        }
        if !segments.isEmpty {
            PlayerViewModel.shared.skipSegments = segments
            PlayerLog.log("[BangumiVM] season skip marks: \(segments.map { "\($0.label) \(Int($0.start))-\(Int($0.end))" }.joined(separator: ", ")) (auto-skip \(PlayerViewModel.animeSkipIntroOutro ? "ON" : "OFF"))")
        } else if !PlayerViewModel.shared.skipSegments.isEmpty {
            PlayerLog.log("[BangumiVM] using playurl clip_info marks (auto-skip \(PlayerViewModel.animeSkipIntroOutro ? "ON" : "OFF"))")
        } else {
            let clips = await PGCAPI.getClipInfo(epId: episode.id, cid: cid)
            guard admitsEpisodePlayback(
                requestSerial: requestSerial,
                departures: departures,
                lease: lease
            ) else { return }
            if !clips.isEmpty {
                PlayerViewModel.shared.skipSegments = clips
                PlayerLog.log("[BangumiVM] v2 clip_info marks installed (auto-skip \(PlayerViewModel.animeSkipIntroOutro ? "ON" : "OFF"))")
            } else if clips.isEmpty {
                PlayerLog.log("[BangumiVM] ep\(episode.id): no OP/ED marks from season API (skip=\(episode.skip == nil ? "absent" : "present-but-empty")), v1 clip_info, or v2 business info — nothing to auto-skip")
            }
        }

        guard admitsEpisodePlayback(
            requestSerial: requestSerial,
            departures: departures,
            lease: lease
        ) else { return }
        PlayerViewModel.shared.setNowPlaying(
            title: season?.title ?? "Anime",
            artist: episode.displayTitle,
            cover: episode.cover ?? season?.cover
        )
    }

    private func loadInitialComments(from source: CommentListSource) {
        guard let request = prepareCommentRefresh(from: source) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.performCommentRequest(request)
        }
    }

    private var routeDepartures: UInt64 = 0

    private func admitsLoad(departures: UInt64, lease: PlayerOwnerLease) -> Bool {
        departures == routeDepartures && PlayerViewModel.shared.isCurrentOwner(lease)
    }

    private func admitsEpisodePlayback(
        requestSerial: UInt64,
        departures: UInt64,
        lease: PlayerOwnerLease
    ) -> Bool {
        requestSerial == episodePlaybackRequestSerial && admitsLoad(departures: departures, lease: lease)
    }

    func revokeLoadForRouteDeparture() {
        routeDepartures &+= 1
        guard isLoading else { return }
        isLoading = false
        if let token = startupTraceToken {
            StartupTrace.abort("route-departed", token: token)
        }
        startupTraceToken = nil
        PlayerLog.log("[BangumiVM] in-flight load revoked — route departed")
    }

    func releasePlayback() {
        if let lease = playerLease,
           PlayerViewModel.shared.endOwnerPlayback(lease: lease) == .leaseRetained {
            return
        }
        playerLease = nil
        if let token = startupTraceToken {
            StartupTrace.abort("screen-disappear", token: token)
        }
        startupTraceToken = nil
    }

    private func isLiveReactivation(seasonId: Int, owner: String) -> Bool {
        guard let selectedEpisodeId,
              let episode = season?.episodes?.first(where: { $0.id == selectedEpisodeId })
        else { return false }

        let player = PlayerViewModel.shared
        return BangumiDetailReactivationPolicy.isAlreadyLive(
            .init(
                requestedSeasonId: seasonId,
                loadedSeasonId: loadedSeasonId,
                hasLoadedMetadata: season != nil,
                screenAid: currentEpisodeAid,
                screenCid: episode.cid,
                screenReportedFailure: error != nil,
                requestedOwner: owner,
                retainedLeaseOwner: playerLease?.owner,
                retainedLeaseIsCurrentOwner: playerLease
                    .map { player.isCurrentOwner($0) } ?? false,
                targetMode: .vod,
                targetSource: .pgc(epId: selectedEpisodeId),
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

    func playAdjacentEpisode(offset: Int) async {
        guard let episodes = season?.episodes,
              let index = episodes.firstIndex(where: { $0.id == selectedEpisodeId }),
              episodes.indices.contains(index + offset)
        else { return }
        let target = episodes[index + offset]
        PlayerLog.log("[BangumiVM] switching to \(target.indexLabel) (offset \(offset))")
        showToast(
            String(format: String(localized: "Playing %@…"), target.displayTitle),
            style: .progress
        )
        await play(episode: target)
    }

    // MARK: - Comments (评论区, keyed to the playing episode's aid)

    var comments: [CommentResult.CommentItem] = [] {
        didSet { commentRowsRevision &+= 1 }
    }
    @ObservationIgnored private var commentRowsRevision: UInt64 = 0
    struct CommentListSource: Equatable, Sendable {
        let aid: Int
        let revision: UInt64
    }

    struct CommentListReceipt: Equatable, Sendable {
        let source: CommentListSource
        let sort: CommentSort
        fileprivate let lineage: UUID
    }

    fileprivate enum CommentRequestMode: Sendable {
        case replacement
        case append(CommentListReceipt)
    }

    struct PreparedCommentRequest: Sendable {
        fileprivate let source: CommentListSource
        fileprivate let sort: CommentSort
        fileprivate let page: Int
        fileprivate let mode: CommentRequestMode
        fileprivate let token: FeedLoadToken
    }

    private(set) var commentListSource: CommentListSource?
    private(set) var commentListReceipt: CommentListReceipt?
    let commentComposer = PGCCommentComposerState()
    var commentTotal = 0
    @ObservationIgnored private(set) var commentDeletionRevision: UInt64 = 0

    func removeComment(rpid: Int) {
        comments.removeAll { $0.rpid == rpid }
        commentTotal = max(0, commentTotal - 1)
        commentDeletionRevision &+= 1
    }
    private(set) var commentSort: CommentSort = .top
    var commentsClosed = false
    private(set) var commentFeedback = CommentLoadFeedback()
    var isLoadingComments: Bool { commentLoadingToken != nil }
    private var commentAdmission = FeedLoadAdmission()
    private var commentLoadingToken: FeedLoadToken?
    private var commentsHaveMore = true
    var toast: ToastMessage?
    private(set) var currentEpisodeAid: Int?
    private(set) var commentSourceRevision: UInt64 = 0
    private var commentPage = 1
    private var toastDismissTask: Task<Void, Never>?

    var currentCommentSource: CommentListSource? {
        currentEpisodeAid.map { CommentListSource(aid: $0, revision: commentSourceRevision) }
    }

    var composerContext: CommentComposerUploadOwner.Context {
        .init(
            owner: commentComposer.identifier,
            sourceRevision: commentSourceRevision,
            replacementEpoch: commentComposer.replacementEpoch
        )
    }

    func admitsComment(_ comment: CommentResult.CommentItem, from source: CommentListSource?) -> Bool {
        guard let source, source.aid == currentEpisodeAid,
              source.revision == commentSourceRevision else { return false }
        return (comment.oid == nil || comment.oid == source.aid) && (comment.type == nil || comment.type == 1)
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

    func postComment(
        message: String,
        root: Int? = nil,
        parent: Int? = nil,
        pictures: [ComposedPicture] = []
    ) async -> Int? {
        guard !Task.isCancelled, let aid = currentEpisodeAid else { return nil }
        let revision = commentSourceRevision
        do {
            let result = try await CommentAPI.postComment(
                oid: aid, message: message, root: root, parent: parent, pictures: pictures
            )
            guard isCurrentCommentSource(aid: aid, revision: revision) else { return nil }
            guard let rpid = result.rpid else {
                showToast(String(localized: "Comment was not accepted"), style: .error)
                return nil
            }
            showToast(String(localized: "Comment posted"), style: .success)
            let source = CommentListSource(aid: aid, revision: revision)
            if let request = prepareCommentRefresh(from: source) {
                await performCommentRequest(request)
            }
            guard isCurrentCommentSource(aid: aid, revision: revision) else { return nil }
            if !commentsClosed, commentListReceipt?.source == source,
               let created = result.acceptedTopLevelReply(matching: rpid, root: root, parent: parent),
               comments.insertAcceptedTopLevelCommentIfNeeded(created) {
                commentTotal += 1
            }
            return rpid
        } catch {
            guard isCurrentCommentSource(aid: aid, revision: revision),
                  !error.isCancellation else { return nil }
            PlayerLog.log("[BangumiVM] post comment failed: \(error)")
            showToast(String(localized: "Failed to post: \(error.localizedDescription)"), style: .error)
            return nil
        }
    }

    private func isCurrentCommentSource(aid: Int, revision: UInt64) -> Bool {
        !Task.isCancelled && currentEpisodeAid == aid && commentSourceRevision == revision
    }
}

extension BangumiViewModel {
    func prepareCommentRefresh(from source: CommentListSource?) -> PreparedCommentRequest? {
        guard !Task.isCancelled, let source, source == currentCommentSource else { return nil }
        let token = commentAdmission.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        commentLoadingToken = token
        commentFeedback.started()
        return PreparedCommentRequest(source: source, sort: commentSort, page: 1, mode: .replacement, token: token)
    }

    func prepareCommentSort(_ sort: CommentSort, from source: CommentListSource?) -> PreparedCommentRequest? {
        guard !Task.isCancelled, let source, source == currentCommentSource,
              sort != commentSort else { return nil }
        commentSort = sort
        comments = []
        commentFeedback = CommentLoadFeedback()
        commentListReceipt = nil
        commentPage = 1
        commentsHaveMore = true
        return prepareCommentRefresh(from: source)
    }

    func prepareMoreComments(from receipt: CommentListReceipt?) -> PreparedCommentRequest? {
        guard !Task.isCancelled, let receipt, receipt == commentListReceipt,
              receipt.source == currentCommentSource, receipt.sort == commentSort,
              commentsHaveMore, commentLoadingToken == nil else { return nil }
        let page = commentPage
        guard let token = commentAdmission.admit(kind: .pagination, cursor: "page:\(page)") else { return nil }
        commentLoadingToken = token
        commentFeedback.started()
        return PreparedCommentRequest(source: receipt.source, sort: receipt.sort, page: page,
                                      mode: .append(receipt), token: token)
    }

    func performCommentRequest(_ request: PreparedCommentRequest) async {
        var succeeded = false
        defer {
            commentAdmission.finish(request.token, succeeded: succeeded)
            if commentLoadingToken == request.token {
                commentLoadingToken = nil
            }
        }
        guard isCurrentCommentRequest(request), !Task.isCancelled else { return }
        do {
            let result = try await CommentAPI.getComments(
                oid: request.source.aid, sort: request.sort.apiValue, pn: request.page
            )
            guard isCurrentCommentRequest(request), !Task.isCancelled else { return }
            var incoming = request.page == 1 ? result.repliesWithPinned : (result.replies ?? [])
            var rows = incoming
            let deletionRevision = commentDeletionRevision
            if case .append = request.mode {
                while true {
                    let revision = commentRowsRevision
                    guard let prepared = try? await FeedCollectionPolicy.appendingAgainstRetainedIDs(
                        existing: comments, incoming: incoming, id: { $0.rpid }
                    ), isCurrentCommentRequest(request), !Task.isCancelled else { return }
                    if revision == commentRowsRevision {
                        rows = prepared.rows
                        break
                    }
                    incoming = prepared.accepted
                }
            }
            publishComments(
                result, rows: rows, for: request,
                localRemovals: commentDeletionRevision &- deletionRevision
            )
            commentFeedback.succeeded()
            succeeded = true
        } catch {
            guard isCurrentCommentRequest(request), !Task.isCancelled,
                  !error.isCancellation else { return }
            commentFeedback.failed(page: request.page)
            if case .apiError(let code, _) = error, code == 12002 || code == 12061 {
                commentsClosed = true
                PlayerLog.log("[BangumiVM] comment area closed by UP (\(code))")
            } else {
                PlayerLog.log("[BangumiVM] comments failed: \(error)")
            }
        }
    }

    private func isCurrentCommentRequest(_ request: PreparedCommentRequest) -> Bool {
        guard commentLoadingToken == request.token, commentAdmission.isCurrent(request.token),
              request.source == currentCommentSource, request.sort == commentSort else { return false }
        switch request.mode {
        case .replacement:
            return true
        case .append(let receipt):
            return receipt == commentListReceipt
        }
    }

    private func publishComments(
        _ result: CommentResult, rows: [CommentResult.CommentItem], for request: PreparedCommentRequest,
        localRemovals: UInt64
    ) {
        comments = rows
        if case .replacement = request.mode {
            commentListSource = request.source
            commentListReceipt = CommentListReceipt(source: request.source, sort: request.sort, lineage: UUID())
        }
        if case .replacement = request.mode, let count = result.page?.count {
            commentTotal = FeedCollectionPolicy.totalAfterLocalRemovals(count, removals: localRemovals)
        }
        commentsHaveMore = !(result.replies ?? []).isEmpty
        commentPage = request.page + 1
        commentsClosed = false
    }
}
