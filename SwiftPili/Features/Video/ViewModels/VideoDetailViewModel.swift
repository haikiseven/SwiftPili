import Foundation
import Observation

/// Latest-wins admission for one reusable detail screen. A pager retains its
/// screen lease while changing videos, so the lease alone cannot distinguish a
/// late metadata response for the previously committed page.
struct VideoDetailLoadAdmission: Equatable, Sendable {
    private(set) var currentRequest: UInt64 = 0

    mutating func begin() -> UInt64 {
        currentRequest &+= 1
        return currentRequest
    }

    func admits(_ request: UInt64) -> Bool {
        request == currentRequest
    }

    /// Retire the in-flight request without starting a new one: every later
    /// `admits(_:)` check of that request fails, so a load suspended at any
    /// `await` stops at its next admission point instead of carrying on for a
    /// page that is no longer the active route.
    mutating func revoke() {
        currentRequest &+= 1
    }
}

@MainActor
@Observable
final class VideoDetailViewModel {
    var videoInfo: VideoInfo?
    var relatedVideos: [VideoCard] = []
    /// Tags + identified BGM (view/detail/tag). Shown under the expanded
    /// description; loaded lazily off the first-frame critical path.
    var tagPublication: TagPublication?
    var tags: [VideoTag] { tagPublication?.tags ?? [] }
    @ObservationIgnored var tagRequestSerial: UInt64 = 0
    var comments: [CommentResult.CommentItem] = [] {
        didSet { commentRowsRevision &+= 1 }
    }
    @ObservationIgnored private(set) var commentRowsRevision: UInt64 = 0
    var isLoading = false
    var error: String?
    /// Set when `error` is a settled refusal (deleted, private, region-locked,
    /// unpublished, paid, sign-in) rather than a failure worth retrying. It is
    /// what lets the screen show a real unavailable state instead of a blank
    /// page — `error` alone was never rendered anywhere in `VideoDetailView`,
    /// so an unplayable video produced a silent empty screen.
    var unavailability: PlaybackUnavailability?
    /// This screen instance's playback exit authority (lease/generation
    /// model): the view's onDisappear ends playback through it, so a stale
    /// view can never stop a replacement screen's session — see load(id:).
    private(set) var playerLease: PlayerOwnerLease?
    var commentTotal: Int = 0
    @ObservationIgnored private(set) var commentDeletionRevision: UInt64 = 0

    /// Keep local row/count mutations in one receipt for in-flight preparation.
    func removeComment(rpid: Int) {
        comments.removeAll { $0.rpid == rpid }
        commentTotal = max(0, commentTotal - 1)
        commentDeletionRevision &+= 1
    }
    var isLiked = false
    /// Coins already given by the current user (0–2, from archive/coins).
    var coinCount = 0
    var isCoined: Bool { coinCount > 0 }
    /// BiliBili allows 2 coins on original/self-made uploads (copyright == 1),
    /// 1 on reposts.
    var maxCoins: Int { videoInfo?.copyright == 1 ? 2 : 1 }
    var isFavorited = false
    /// Whether this video is in Watch Later — loaded on open from the full
    /// toview list (loadInteractionState) so the button reflects reality,
    /// then tracks the user's add/remove toggles for this screen.
    var isInWatchLater = false
    /// True once THIS user shared the video this session (copy link or
    /// completed system share) — drives the share button's active tint.
    var hasShared = false
    /// nil until the relation fetch answers (or when it's not applicable:
    /// logged out / own video).
    var isFollowingUp: Bool?
    var defaultFolderId: Int?
    var toast: ToastMessage?
    /// cid of the part currently playing (multi-P videos).
    var currentCid: Int?
    /// Concurrent viewers ("1.2万" style), from x/player/online/total.
    var onlineCount: String?

    private var loadedID: VideoID?
    @ObservationIgnored var startupTraceToken: StartupTrace.Token?
    private var loadAdmission = VideoDetailLoadAdmission()
    @ObservationIgnored private var loadAccountSession: UUID?
    @ObservationIgnored var metadataAccountSession: UUID?
    @ObservationIgnored var retainedScreenData: CompletedScreenDataReceipt?
    @ObservationIgnored var retainedPlaybackAdmission = VideoDetailLoadAdmission()
    @ObservationIgnored var retainedPlaybackRequest: RetainedPlaybackRequest?
    @ObservationIgnored var interactionStateReceipt: InteractionStateReceipt?
    /// Comments share the whole-video request identity; part switches retain it.
    var commentSourceGeneration: UInt64 { loadAdmission.currentRequest }
    /// Both composer presentations retain the same admitted upload and draft replacement lifetime.
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

    /// A requested page may retain the previous video's metadata while loading.
    func hasCommentSource(for requestedID: VideoID) -> Bool {
        currentCommentSource?.videoID == requestedID
    }
    var currentCommentSource: CommentSource? {
        guard let source = commentMetadataSource,
              source.generation == commentSourceGeneration,
              source.videoID == loadedID, source.aid == videoInfo?.aid else { return nil }
        return source
    }
    /// Only called inside the already-proved exact live branch.
    func retainedCommentMetadataMatches(_ source: CommentSource, id: VideoID) -> Bool {
        source.videoID == id && loadedID == id && source.aid == videoInfo?.aid
    }
    // Stored here for the cross-file Comments extension; identities are defined there.
    var commentMetadataSource: CommentSource?
    var commentListReceipt: CommentListReceipt?
    var commentFeedback = CommentLoadFeedback()
    var commentAdmission = FeedLoadAdmission()
    var commentLoadingToken: FeedLoadToken?
    var commentRecoverySeed: UInt64?
    var commentRevocationWitness: CommentRevocationWitness?
    /// Latest-wins admission for part switches — see `PartSwitchRequest`.
    private var partAdmission = VideoDetailLoadAdmission()
    /// The part switch currently between its entry and its tail, if any.
    private var partSwitchInFlight: PartSwitchRequest?

    /// A paging container claims one lease before its first target load and
    /// retains it for every committed target.
    func adoptPlayerLease(_ lease: PlayerOwnerLease) {
        playerLease = lease
    }

    /// `internal`, not `private`: `VideoDetailViewModel+Comments.swift` advances
    /// this while `load(...)` here resets it, and `private` is FILE-scoped in
    /// Swift. See that file's header for the full list of what crosses the seam.
    var commentPage = 1
    /// The aid whose page-one comment response has been consumed. A reused
    /// pager can still hold the previous video's rows while the next request
    /// is in flight; anchor navigation must never search that stale list.
    ///
    /// `internal` for the same seam reason as `commentPage`.
    var commentsLoadedAid: Int?
    private var toastDismissTask: Task<Void, Never>?

    /// Ordering of the comment list — the enum and its picker are shared
    /// with the bangumi page (SharedUI/Components/CommentSortBar).
    var commentSort: CommentSort = .top

    /// The UP has closed this video's comment section — the reply-list
    /// API answers code 12002/12061 (verified against PiliPlus, which
    /// keys off the same codes).
    var commentsClosed = false

    /// Presentation derives from the exact active GET owner, including initial
    /// loading and replacements; a retired request cannot release its successor.
    var isLoadingComments: Bool { commentLoadingToken != nil }
    /// `internal` for the same seam reason as `commentPage`: the paging in
    /// `VideoDetailViewModel+Comments.swift` writes it, `load(...)` here resets
    /// it.
    var commentsHaveMore = true

    /// True only after the current video's first comment response (including
    /// a closed/error result) has been consumed. It fences message taps from
    /// the reused pager rows while a new video is still loading.
    var commentsReadyForNavigation: Bool {
        guard let source = currentCommentSource else { return false }
        return commentsLoadedAid == source.aid && commentListReceipt?.source == source
    }

    var commentsAwaitingInitialResponse: Bool {
        !commentsReadyForNavigation && (isLoading || (currentCommentSource != nil
            && (isLoadingComments || commentRecoverySeed == commentAdmission.generation)))
    }

    // Shared with VideoDetailViewModel+Comments.swift. Swift `private` is
    // file-scoped, so keeping this helper private breaks the split ViewModel
    // at the real Swift compiler even though the source parses in isolation.
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

    @discardableResult
    func load(
        id: VideoID,
        owner requestedOwner: String? = nil,
        lease retainedLease: PlayerOwnerLease? = nil
    ) async -> Bool {
        let owner = requestedOwner ?? PlayerViewModel.vodOwner(id)
        let retainedData = retainedDataForActivation(id: id)
        let decision = VideoDetailReactivationPolicy.decision(
            alreadyLive: isLiveReactivation(id: id, owner: owner, retainedLease: retainedLease),
            dataRetained: retainedData != nil
        )
        // BEFORE any bookkeeping, deliberately. A skip must not begin a
        // StartupTrace session nothing will end (the live session's token is
        // still open and still describes the load that IS running), must not
        // flip `isLoading` it then has to undo, and must not advance
        // `loadAdmission` — the live load's own tail still owns that request
        // number, and bumping it here would fence a running load's completion
        // out of its own screen.
        if decision == .alreadyLive {
            recoverCommentsAfterProvedLiveReactivation(id: id)
            let player = PlayerViewModel.shared
            PlayerLog.log(
                "[VideoDetailVM] re-activation is a no-op — already live " +
                "aid=\(videoInfo?.aid ?? 0) cid=\(currentCid ?? 0) " +
                "t=\(String(format: "%.1f", player.mediaTime))s owner=\(owner)"
            )
            // Loaded is loaded: `false` would report a failed load for a
            // screen that is intact — a second defect in place of the one
            // being removed.
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
        // Claim this screen instance's exit authority before any await, so a
        // stale same-owner screen cannot stop or un-park its replacement.
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
            self.currentCid = info.cid
            let initialPartBaseline = partAdmission.currentRequest
            // The pager reuses this view model across video changes. Clear the
            // old comment page before the new first page arrives so an anchor
            // cannot scroll to a stale row from the previous video.
            comments = []
            commentPage = 1
            commentsHaveMore = true
            commentsClosed = false
            commentsLoadedAid = nil
            // Ambient is decoration for this exact owner. Publish the cover
            // after the metadata request has been admitted, so a late detail
            // response cannot repaint a successor pager's player background.
            PlayerViewModel.shared.setAmbientCoverURL(info.pic, ownerLease: lease)

            // SponsorBlock segments — keyed by BVID + the playing part's
            // cid. Fire-and-forget so it never delays first frame; the
            // player reads the manager's segments once they land.
            Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: info.cid) }
            // Tags + identified BGM live below the fold (expanded desc), so
            // load them lazily — never on the time-to-first-frame path.
            let tagRequest = prepareTags(aid: info.aid, cid: info.cid) { [weak self] in
                guard let self else { return false }
                return self.ownsCurrentLoad(request, lease: lease)
                    && self.partAdmission.admits(initialPartBaseline)
                    && self.currentCid == info.cid
            }
            loadInitialTags(tagRequest, cached: cachedData)

            // Each section publishes from its own structured child as soon as
            // it answers. Neither waits for resume lookup or the other section;
            // playback still needs its admitted resume position before opening.
            async let related = loadInitialRelatedVideos(
                aid: info.aid, cached: cachedData, request: request, lease: lease
            )
            let initialComments = prepareCommentRequest(purpose: .initial, from: currentCommentSource)
            async let firstComments: Void = loadInitialComments(
                initialComments, request: request, lease: lease
            )
            // The page's own duration, not info.duration — that one is
            // the SUM across parts and would mask a finished part 1.
            let partDuration = info.pages?.first(where: { $0.cid == info.cid })?.duration ?? info.duration
            let resumeLookup = await PlayerViewModel.serverResumePoint(
                aid: info.aid,
                cid: info.cid,
                duration: TimeInterval(partDuration),
                ownerLease: lease
            )
            guard ownsCurrentLoad(request, lease: lease) else {
                StartupTrace.abort("stale-page-request", token: traceToken)
                return false
            }
            let initialPartStillSelected: () -> Bool = {
                self.ownsCurrentLoad(request, lease: lease)
                    && self.partAdmission.admits(initialPartBaseline)
                    && self.currentCid == info.cid
                    && self.partSwitchInFlight == nil
            }
            if initialPartStillSelected() {
                // A cancelled lookup is not "no history". Opening at 0 here is what
                // wrote progress=0 over a real resume point; the task that was
                // cancelled is re-run by this screen's activation, and that run
                // asks again.
                guard case .load(let resumeAt) = resumeLookup.loadDecision() else {
                    StartupTrace.abort("resume-lookup-cancelled", token: traceToken)
                    PlayerLog.log(
                        "[VideoDetailVM] load aborted — resume lookup cancelled aid=\(info.aid) cid=\(info.cid)"
                    )
                    return false
                }
                StartupTrace.mark("resume-point-ready", token: traceToken)
                await PlayerViewModel.shared.loadVOD(
                    aid: info.aid, cid: info.cid, bvid: info.bvid,
                    resumeAt: resumeAt,
                    portraitHint: info.dimension?.isPortrait,
                    owner: lease.owner,
                    ownerLease: lease,
                    startupTraceToken: traceToken,
                    requestAdmission: { [weak self] in
                        guard let self else { return false }
                        return self.ownsCurrentLoad(request, lease: lease)
                            && self.partAdmission.admits(initialPartBaseline)
                            && self.currentCid == info.cid
                            && self.partSwitchInFlight == nil
                    }
                )
            } else {
                StartupTrace.abort("superseded-by-part-switch", token: traceToken)
                let cidDesc = self.currentCid ?? -1
                PlayerLog.log(
                    "[VideoDetailVM] initial P1 skipped (superseded by part switch, cid=\(cidDesc))"
                )
            }

            let relatedLoaded = await related
            await firstComments
            // loadVOD is shielded from .task cancellation, so this tail can
            // resume AFTER another screen has claimed the player — never
            // install this screen's Now Playing card or next-part handler
            // over the successor's (a stale handler would load THIS video's
            // next part at the successor's EOF).
            guard ownsCurrentLoad(request, lease: lease) else { return false }
            if initialPartStillSelected() {
                // PiP / Lock Screen / Control Center card.
                PlayerViewModel.shared.setNowPlaying(
                    title: info.title,
                    artist: info.owner.name,
                    cover: info.pic
                )
                // Sequential playback through multi-P parts.
                installNextPartHandler()
            }
            let settledCid = currentCid ?? info.cid
            retainCompletedScreenData(
                .init(id: id, aid: info.aid, cid: settledCid, dataRequest: request,
                      accountSession: accountSession, fetchedAt: fetchedAt),
                relatedLoaded: relatedLoaded, partSwitchPending: partSwitchInFlight != nil
            )
            if initialPartStillSelected() {
                refreshOnlineCount(request: request, lease: lease)
            }

            if AuthManager.shared.isLoggedIn {
                // Unstructured on purpose: this runs inside the view's
                // .task, which SwiftUI cancels on transient identity
                // changes — that cancellation was killing the like/coin/
                // favorite fetches (-999) for a video that kept playing.
                // A wasted fetch after really leaving is harmless.
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
            // A load that dies here never reaches playURL, so no stop()
            // will ever close its trace session — end it explicitly or the
            // next unrelated playback's marks land in it.
            guard ownsCurrentLoad(request, lease: lease) else {
                StartupTrace.abort("stale-page-request", token: traceToken)
                return false
            }
            // Classify before surfacing: a settled refusal is a state the
            // screen can explain, not a string to print. Raw interpolation put
            // `apiError(code: -404, message: "啥都木有")` in a field nothing
            // rendered, so the user saw an empty page and a black player.
            let reason = PlaybackAvailabilityPolicy.unavailability(forAny: error)
            self.unavailability = reason
            self.error = reason?.message ?? error.localizedDescription
            // BEFORE the ownership release below, and only while this screen
            // still owns the player. `endOwnerPlayback` hands the shared player
            // on; marking it unavailable afterwards could paint a terminal
            // error over whatever claimed it next.
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

    /// Publication stays on the model owner; cancellation never clears a
    /// retained section or lets an old load paint a successor's page.
    private func loadInitialRelatedVideos(
        aid: Int, cached: VideoDetailScreenDataSnapshot?, request: UInt64, lease: PlayerOwnerLease
    ) async -> Bool {
        let videos = try? await initialRelatedVideos(aid: aid, cached: cached)
        guard !Task.isCancelled, ownsCurrentLoad(request, lease: lease) else { return false }
        relatedVideos = videos ?? []
        return videos != nil
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

    /// Arms end-of-playback auto-advance for the part that is loading now.
    ///
    /// Must be re-armed after EVERY load, not just the first: `loadVOD` begins
    /// with `stop()`, and `stop()` clears `onPlaybackEnded` — so installing it
    /// only in `load` meant P1→P2 advanced and P2→P3 never fired.
    ///
    /// Installed only when a next part actually exists, so the player's own
    /// "nothing registered → rest at end" branch stays truthful for the last
    /// part and for single-part videos, instead of handing it a callback that
    /// no-ops internally.
    func installNextPartHandler() {
        guard let pages = videoInfo?.pages, pages.count > 1,
              let cid = currentCid,
              let index = pages.firstIndex(where: { $0.cid == cid }),
              index + 1 < pages.count
        else {
            PlayerViewModel.shared.onPlaybackEnded = nil
            return
        }
        PlayerViewModel.shared.onPlaybackEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.playNextPart()
            }
        }
    }

    /// Switches playback to another part of the same video.
    func switchPage(_ page: VideoInfo.VideoPage) async {
        // A historical detail VM may retain its end-of-playback callback after
        // a successor route has claimed the shared player. It must not derive a
        // fresh lease here and steal ownership back; only the current lease
        // holder may switch parts.
        guard let lease = playerLease,
              PlayerViewModel.shared.isCurrentOwner(lease),
              let info = videoInfo,
              loadedID != nil,
              page.cid != currentCid else { return }
        retireRetainedPlayback(reason: "part-switch")
        // Admission, the same shape `load` uses: this switch is retired by a
        // newer switch, by a new load, and by a route departure
        // (`revokeLoadForRouteDeparture`), and every await below re-checks it.
        // Without it a part switch outlived the page that asked for it and
        // opened the part for a page nobody could see — design §9's defect on
        // its second entrance.
        let request = partSwitchRequest(loadRequest: loadAdmission.currentRequest)
        defer { settlePartSwitch(request) }
        currentCid = page.cid
        Task { await SponsorBlockManager.shared.load(videoID: info.bvid, cid: page.cid) }
        // BGM is per-part (cid), so re-fetch the tag/music set for the new one.
        let tagRequest = prepareTags(aid: info.aid, cid: page.cid, retainsDisplay: true) { [weak self] in
            self?.ownsPartSwitch(request, lease: lease) == true
        }
        Task { await self.loadTags(tagRequest) }
        let owner = lease.owner
        // A part switch belongs to this screen, not a new screen owner. Keep
        // the admitted lease generation while preserving the existing
        // same-owner claim/reset behavior.
        PlayerViewModel.shared.claim(owner: owner)
        // Each part keeps its own server-side history point.
        let resumeLookup = await PlayerViewModel.serverResumePoint(
            aid: info.aid,
            cid: page.cid,
            duration: TimeInterval(page.duration),
            ownerLease: lease
        )
        guard ownsPartSwitch(request, lease: lease) else {
            PlayerLog.log("[VideoDetailVM] part switch to cid=\(page.cid) withdrawn before loadVOD")
            return
        }
        // Same rule as `load`: a cancelled lookup is not "no history".
        guard case .load(let resumeAt) = resumeLookup.loadDecision() else {
            PlayerLog.log("[VideoDetailVM] part switch aborted — resume lookup cancelled cid=\(page.cid)")
            return
        }
        PlayerViewModel.shared.setAmbientCoverURL(info.pic, ownerLease: lease)
        await PlayerViewModel.shared.loadVOD(
            aid: info.aid, cid: page.cid, bvid: info.bvid,
            resumeAt: resumeAt,
            portraitHint: page.dimension?.isPortrait ?? info.dimension?.isPortrait,
            owner: lease.owner,
            ownerLease: lease,
            startupTraceToken: nil,
            requestAdmission: { [weak self] in
                guard let self else { return false }
                return self.ownsPartSwitch(request, lease: lease)
            }
        )
        // Screen-local state — refresh even when the player moved on.
        refreshOnlineCount()
        // Same invariant as load(id:): the shielded loadVOD can resume
        // after another screen has claimed the player — a stale tail must
        // not install this screen's handler/card over the successor's — and
        // a withdrawn switch never reached playback, so it has nothing to arm.
        guard ownsPartSwitch(request, lease: lease) else { return }
        // Re-arm: the loadVOD above cleared the handler via stop(). Without
        // this the chain advanced once and then stopped mid-video.
        installNextPartHandler()
        PlayerViewModel.shared.setNowPlaying(
            title: info.title,
            artist: page.part.isEmpty ? info.owner.name : "P\(page.page) \(page.part)",
            cover: info.pic
        )
        retainCompletedPart(cid: page.cid)
    }

    /// `onDisappear` is the only caller, and that is not the same event as
    /// "this screen is finished".
    ///
    /// A UIKit `.fullScreen` presentation of ours removes the presenter's view
    /// from the window, so SwiftUI sends `onDisappear` to a screen that is still
    /// on the navigation stack and still the player's owner. Dropping the lease
    /// there is a second defect on top of stopping playback: the screen's next
    /// activation pass finds `playerLease == nil`, claims a NEW one, and that is
    /// `newContentOwnership` — a full teardown. The device capture recorded
    /// exactly that: the session parked at `position=20.99 ttl=90s` and the
    /// return cold-loaded from 0, because nobody was entitled to claim the park.
    ///
    /// So the player decides, at one admission point, whether this exit ended
    /// ownership; this screen only obeys the answer. Retaining a lease across a
    /// transition is not a new idea here — `load(id:owner:lease:)` already takes
    /// a retained lease for the same reason.
    func releasePlayback() {
        if let lease = playerLease, PlayerViewModel.shared.isCurrentOwner(lease),
           PlayerViewModel.shared.error != nil || PlayerViewModel.shared.unavailability != nil {
            invalidateRetainedScreenData()
        }
        cacheCompletedScreenData()
        if let lease = playerLease,
           PlayerViewModel.shared.endOwnerPlayback(lease: lease) == .leaseRetained {
            // Ownership survived, so the startup trace stays open with it: the
            // load this screen began is still the live one, and aborting it
            // would label a running session dead.
            return
        }
        retireRetainedPlayback(reason: "screen-disappear")
        playerLease = nil
        if let token = startupTraceToken {
            StartupTrace.abort("screen-disappear", token: token)
        }
        startupTraceToken = nil
    }

    /// The route left the top of the stack: the load this screen started is no
    /// longer the one the user is waiting for.
    ///
    /// Device 2026-09-26: a page released its activation, began loading, and
    /// lost the top 93ms later to the next swipe-back. The cancelled task took
    /// the resume lookup down with it (-999), `serverResumePoint` reported that
    /// as "no history", and the load — still admitted, because only the LEASE
    /// was checked — opened the stream at 0 for a page nobody could see. The
    /// successor then ended that owner and its `stop()` flushed `progress=0`
    /// over the 20s the server had just accepted. Revoking the request is the
    /// admission the load already checks after every await (`ownsCurrentLoad`,
    /// and `loadVOD`'s `requestAdmission`), so the load ends at its next
    /// admission point and never reaches playback.
    ///
    /// Only what is IN FLIGHT is revoked. A completed load's request stays
    /// admitted on purpose: its detached `loadTags` / `refreshOnlineCount` /
    /// `loadInteractionState` still check it, and a reactivation that proves
    /// the session live (`isLiveReactivation`) begins no new request that
    /// could replace it. So an in-flight part switch alone retires only
    /// itself (`partAdmission`), and an in-flight initial load retires the
    /// load request — which every part switch begun under it checks too.
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

    /// One part switch's admission: the load request it was begun under (a
    /// new load or a departure mid-load retires it) plus its own latest-wins
    /// number (a newer switch or a departure mid-switch retires it).
    ///
    /// A second counter rather than `loadAdmission.begin()`, deliberately:
    /// that would retire the initial load's request whenever the user picks a
    /// part while its `loadVOD` is still in flight, silently dropping the
    /// load's own tail — `relatedVideos`/comments if they had not landed yet,
    /// and `loadInteractionState` (like/coin/favourite) always — and leaving
    /// `isLoading` set forever, since the load's `defer` clears it only while
    /// its request is admitted.
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

    /// Called by the player at end of playback when order == .playNext.
    func playNextPart() async {
        guard let pages = videoInfo?.pages, pages.count > 1,
              let cid = currentCid,
              let index = pages.firstIndex(where: { $0.cid == cid }),
              index + 1 < pages.count
        else { return }
        showToast(String(localized: "Playing P\(pages[index + 1].page)…"), style: .progress)
        await switchPage(pages[index + 1])
    }

    /// view/detail/tag for the given part. Anonymous-safe; failures leave
    /// the tag strip empty rather than surfacing an error.
    private func ownsCurrentLoad(_ request: UInt64, lease: PlayerOwnerLease) -> Bool {
        loadAdmission.admits(request) && PlayerViewModel.shared.isCurrentOwner(lease)
            && loadAccountSession == AuthManager.shared.sessionGeneration
    }

    private func retainedDataForActivation(id: VideoID) -> CompletedScreenDataReceipt? {
        guard partSwitchInFlight == nil else { return nil }
        return eligibleRetainedScreenData(for: id)
    }

    /// Reads every fact `VideoDetailReactivationPolicy` needs in ONE turn, then
    /// obeys the answer. The screen decides nothing itself and remembers
    /// nothing: the player is asked what it is running at the instant the
    /// question is put, which is the idiom `PlayerContainerView.surfaceFacts`
    /// and `PlayerPresentationHostPresence` already establish here.
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
                // This screen is the UGC detail page: its own `loadVOD` call
                // passes neither a mode nor a source, so the target is the
                // default pair. Stated rather than inferred, because the
                // identity below is only as complete as `loadVOD`'s own.
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
        // Watch Later has no cheap membership endpoint, but the whole
        // toview list (≤100) comes back in one call — check the aid against
        // it so the button reflects reality on open instead of a false
        // "not saved" baseline that made removal impossible.
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
            // Read into a local first: `videoInfo?.stat.x = f(videoInfo?.stat.x)`
            // overlaps a read with an exclusive write on the same property
            // and crashes with "Simultaneous accesses".
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

    /// Loads the user's folders (with fav_state for this video) for the picker.
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
            // The share itself happened client-side (copy/system sheet) —
            // still reflect it in the button even if the count ping failed.
            hasShared = true
        }
    }

    /// Add/remove the current video in Watch Later (稍后再看).
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
