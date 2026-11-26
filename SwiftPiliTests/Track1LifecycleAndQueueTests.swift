import CoreGraphics
import Foundation
import MediaPlayer
import Testing
@testable import SwiftPili

@Suite("Track 1: Mini-Player Dock Persistence, Multi-Part/Bangumi Return & PlaybackQueueContext", .serialized)
@MainActor
struct Track1LifecycleAndQueueTests {

    private static func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "com.swiftpili.tests.track1.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func makeVideoInfo(
        aid: Int = 5500,
        bvid: String = "BV1track10001",
        pages: [(cid: Int, page: Int, part: String, duration: Int)]
    ) throws -> VideoInfo {
        let primaryCid = pages.first?.cid ?? 1
        let pageJSON = pages.map { page in
            """
            {
              "cid": \(page.cid),
              "page": \(page.page),
              "part": "\(page.part)",
              "duration": \(page.duration)
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "aid": \(aid),
          "bvid": "\(bvid)",
          "cid": \(primaryCid),
          "title": "Multi-Part Sample",
          "desc": "",
          "pic": "https://example.com/video-cover.jpg",
          "duration": 600,
          "pubdate": 1700000000,
          "owner": {
            "mid": 42,
            "name": "Uploader",
            "face": "https://example.com/face.jpg"
          },
          "stat": {
            "view": 100,
            "danmaku": 10,
            "reply": 5,
            "favorite": 3,
            "coin": 2,
            "share": 1,
            "like": 20
          },
          "pages": [\(pageJSON)]
        }
        """
        return try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
    }

    private static func makeBangumiSeason(
        seasonId: Int = 9900,
        type: Int = 1,
        episodes: [(id: Int, aid: Int?, cid: Int?, title: String, longTitle: String, op: (Int, Int)?, ed: (Int, Int)?)]
    ) throws -> PGCSeasonInfo {
        let episodesJSON = episodes.map { ep in
            let aidField = ep.aid.map { "\"aid\": \($0)," } ?? ""
            let cidField = ep.cid.map { "\"cid\": \($0)," } ?? ""
            let skipField: String
            if ep.op != nil || ep.ed != nil {
                var parts: [String] = []
                if let op = ep.op {
                    parts.append("\"op\": { \"start\": \(op.0), \"end\": \(op.1) }")
                }
                if let ed = ep.ed {
                    parts.append("\"ed\": { \"start\": \(ed.0), \"end\": \(ed.1) }")
                }
                skipField = "\"skip\": { \(parts.joined(separator: ", ")) },"
            } else {
                skipField = ""
            }
            return """
            {
              "id": \(ep.id),
              \(aidField)
              \(cidField)
              "bvid": "BV1ep\(ep.id)",
              "title": "\(ep.title)",
              "long_title": "\(ep.longTitle)",
              "cover": "https://example.com/ep-\(ep.id).jpg",
              \(skipField)
              "badge": null
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "season_id": \(seasonId),
          "type": \(type),
          "title": "Sample Anime",
          "cover": "https://example.com/season.jpg",
          "episodes": [\(episodesJSON)]
        }
        """
        return try JSONDecoder().decode(PGCSeasonInfo.self, from: Data(json.utf8))
    }

    private static func makeQueueItems(count: Int, aidBase: Int = 1000) -> [PlaybackQueueItem] {
        (0..<count).map { index in
            let aid = aidBase + index
            let cid = aid * 10 + 1
            let videoID = VideoID.aid(aid)
            return PlaybackQueueItem(
                id: "item-\(index)",
                aid: aid,
                cid: cid,
                bvid: "BV1queue000\(index)",
                title: "Item \(index + 1)",
                artist: "Creator \(index + 1)",
                coverURL: "https://example.com/cover-\(index + 1).jpg",
                duration: TimeInterval(120 + index * 30),
                isPortraitHint: index % 2 == 1,
                source: .ugc,
                originRoute: .videoDetail(videoID),
                originScreenRoute: .video(videoID),
                opEdSegments: [PlaybackSkipSegment(label: "OP", start: 5, end: 95)]
            )
        }
    }

    private static func resetPlayerSharedState(
        originalMiniPlayerPref: Any?,
        originalOrder: PlaybackOrder
    ) {
        let vm = PlayerViewModel.shared
        let key = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        vm.isAutonomousQueueAdvanceInFlight = false
        vm.miniPlayer.clearAll()
        vm.error = nil
        vm.unavailability = nil
        vm.terminalOpenFailure = false
        vm.playbackOrder = originalOrder
        vm.stop(reason: .ownerExit)
        vm.ownerKey = ""
        vm.activeSceneID = nil
        vm.clearAllOutgoingRouteStills()
        if let originalMiniPlayerPref {
            UserDefaults.standard.set(originalMiniPlayerPref, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Task 1.3: MiniPlayerDockPosition Persistence

    @Test("InAppMiniPlayerState persists MiniPlayerDockPosition across instances for all four edges and intermediate progress")
    func miniPlayerDockPositionPersistenceRoundTrip() {
        let (defaults, suiteName) = Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset defaults fall back to .bottomTrailing without mutating storage.
        let initial = InAppMiniPlayerState(defaults: defaults)
        #expect(initial.dockPosition == .bottomTrailing)
        #expect(defaults.object(forKey: InAppMiniPlayerState.dockEdgeDefaultsKey) == nil)
        #expect(defaults.object(forKey: InAppMiniPlayerState.dockProgressDefaultsKey) == nil)

        let cases: [MiniPlayerDockPosition] = [
            MiniPlayerDockPosition(edge: .top, progress: 0.25),
            MiniPlayerDockPosition(edge: .bottom, progress: 0.72),
            MiniPlayerDockPosition(edge: .leading, progress: 0.0),
            MiniPlayerDockPosition(edge: .trailing, progress: 0.64),
            MiniPlayerDockPosition(edge: .leading, progress: 1.0),
        ]

        for expected in cases {
            initial.dockPosition = expected
            #expect(defaults.string(forKey: InAppMiniPlayerState.dockEdgeDefaultsKey) == expected.edge.rawValue)
            let storedProgress = defaults.object(forKey: InAppMiniPlayerState.dockProgressDefaultsKey) as? Double
            #expect(storedProgress != nil)
            if let storedProgress {
                #expect(abs(storedProgress - Double(expected.progress)) < 1e-9)
            }

            let reloaded = InAppMiniPlayerState(defaults: defaults)
            #expect(reloaded.dockPosition.edge == expected.edge)
            #expect(abs(reloaded.dockPosition.progress - expected.progress) < 1e-6)
        }
    }

    @Test("InAppMiniPlayerState falls back to bottomTrailing on invalid or corrupt persisted dock values and clamps finite extremes")
    func miniPlayerDockPositionInvalidFallbackAndClamping() {
        let (defaults, suiteName) = Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Invalid edge string.
        defaults.set("diagonal", forKey: InAppMiniPlayerState.dockEdgeDefaultsKey)
        defaults.set(0.5, forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == .bottomTrailing)

        // Valid edge but missing progress.
        defaults.set(MiniPlayerEdge.top.rawValue, forKey: InAppMiniPlayerState.dockEdgeDefaultsKey)
        defaults.removeObject(forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == .bottomTrailing)

        // Valid progress but missing edge.
        defaults.removeObject(forKey: InAppMiniPlayerState.dockEdgeDefaultsKey)
        defaults.set(0.4, forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == .bottomTrailing)

        // Non-numeric progress string.
        defaults.set(MiniPlayerEdge.leading.rawValue, forKey: InAppMiniPlayerState.dockEdgeDefaultsKey)
        defaults.set("halfway", forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == .bottomTrailing)

        // Non-finite progress values.
        defaults.set(Double.nan, forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == .bottomTrailing)

        defaults.set(Double.infinity, forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == .bottomTrailing)

        // Out-of-range finite progress clamps cleanly to [0, 1].
        defaults.set(MiniPlayerEdge.bottom.rawValue, forKey: InAppMiniPlayerState.dockEdgeDefaultsKey)
        defaults.set(-0.75, forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == MiniPlayerDockPosition(edge: .bottom, progress: 0))

        defaults.set(2.4, forKey: InAppMiniPlayerState.dockProgressDefaultsKey)
        #expect(InAppMiniPlayerState(defaults: defaults).dockPosition == MiniPlayerDockPosition(edge: .bottom, progress: 1))
    }

    // MARK: - Task 1.2: PlaybackQueueContext Navigation & Builders

    @Test("PlaybackQueueContext handles empty queues, index clamping, forward/backward advancing, and selecting(aid:cid:)")
    func playbackQueueContextNavigationAndBoundaries() {
        let empty = PlaybackQueueContext(kind: .playlist(name: "Empty"), items: [], currentIndex: 4)
        #expect(empty.isEmpty)
        #expect(empty.currentIndex == 0)
        #expect(empty.currentItem == nil)
        #expect(!empty.hasPrevious)
        #expect(!empty.hasNext)
        #expect(empty.advancing(by: 1) == nil)
        #expect(empty.advancing(by: -1) == nil)
        #expect(empty.selecting(aid: 1, cid: 1) == empty)

        let items = Self.makeQueueItems(count: 3, aidBase: 200)

        // Negative initial index clamps to 0.
        let clampedLow = PlaybackQueueContext(kind: .playlist(name: "Watch Later"), items: items, currentIndex: -10)
        #expect(clampedLow.currentIndex == 0)
        #expect(clampedLow.currentItem == items[0])
        #expect(!clampedLow.hasPrevious)
        #expect(clampedLow.hasNext)
        #expect(clampedLow.advancing(by: -1) == nil)
        #expect(clampedLow.advancing(by: 0) == nil)

        // Oversized initial index clamps to items.count - 1.
        let clampedHigh = PlaybackQueueContext(kind: .ugcSeason(seasonId: 88), items: items, currentIndex: 99)
        #expect(clampedHigh.currentIndex == 2)
        #expect(clampedHigh.currentItem == items[2])
        #expect(clampedHigh.hasPrevious)
        #expect(!clampedHigh.hasNext)
        #expect(clampedHigh.advancing(by: 1) == nil)

        // Advance forward through every item, then back.
        let step1 = clampedLow.advancing(by: 1)
        #expect(step1?.0.currentIndex == 1)
        #expect(step1?.1 == items[1])
        #expect(step1?.0.hasPrevious == true)
        #expect(step1?.0.hasNext == true)

        let step2 = step1?.0.advancing(by: 1)
        #expect(step2?.0.currentIndex == 2)
        #expect(step2?.1 == items[2])
        #expect(step2?.0.hasPrevious == true)
        #expect(step2?.0.hasNext == false)
        #expect(step2?.0.advancing(by: 1) == nil)

        let stepBack = step2?.0.advancing(by: -1)
        #expect(stepBack?.0.currentIndex == 1)
        #expect(stepBack?.1 == items[1])

        // selecting(aid:cid:) moves to matching item and leaves context unchanged on miss.
        let selectedThird = clampedLow.selecting(aid: items[2].aid, cid: items[2].cid)
        #expect(selectedThird.currentIndex == 2)
        #expect(selectedThird.currentItem == items[2])

        let unchangedOnMiss = selectedThird.selecting(aid: 99999, cid: 88888)
        #expect(unchangedOnMiss == selectedThird)
    }

    @Test("PlaybackQueueContext builders construct videoParts and bangumiSeason queues accurately")
    func playbackQueueContextFactories() throws {
        // Single-part video returns nil.
        let singlePart = try Self.makeVideoInfo(
            aid: 101,
            pages: [(cid: 10101, page: 1, part: "Only", duration: 90)]
        )
        #expect(PlaybackQueueContext.videoParts(info: singlePart, videoID: .aid(101), currentCid: 10101) == nil)

        // Multi-part video builds items for all pages and selects the active cid.
        let multiPart = try Self.makeVideoInfo(
            aid: 202,
            bvid: "BV1multi0002",
            pages: [
                (cid: 20201, page: 1, part: "Intro", duration: 100),
                (cid: 20202, page: 2, part: "Main", duration: 240),
                (cid: 20203, page: 3, part: "", duration: 180),
            ]
        )
        let partsQueue = PlaybackQueueContext.videoParts(
            info: multiPart,
            videoID: .bvid("BV1multi0002"),
            currentCid: 20202
        )
        #expect(partsQueue?.kind == .videoParts(aid: 202))
        #expect(partsQueue?.items.count == 3)
        #expect(partsQueue?.currentIndex == 1)
        #expect(partsQueue?.currentItem?.cid == 20202)
        #expect(partsQueue?.currentItem?.artist == "P2 Main")
        #expect(partsQueue?.items[2].artist == "Uploader")
        #expect(partsQueue?.currentItem?.originScreenRoute == .video(.bvid("BV1multi0002")))

        // Bangumi season skips unavailable episodes (nil aid/cid) and preserves OP/ED segments & season type.
        let season = try Self.makeBangumiSeason(
            seasonId: 777,
            type: 4,
            episodes: [
                (id: 11, aid: 7001, cid: 70011, title: "1", longTitle: "First", op: (10, 100), ed: (1300, 1390)),
                (id: 12, aid: nil, cid: nil, title: "PV", longTitle: "Unavailable", op: nil, ed: nil),
                (id: 13, aid: 7003, cid: 70031, title: "2", longTitle: "Second", op: (0, 90), ed: nil),
            ]
        )
        let bangumiQueue = PlaybackQueueContext.bangumiSeason(
            season,
            seasonId: 777,
            currentEpisodeId: 13
        )
        #expect(bangumiQueue?.kind == .bangumiSeason(seasonId: 777))
        #expect(bangumiQueue?.items.count == 2)
        #expect(bangumiQueue?.currentIndex == 1)
        #expect(bangumiQueue?.currentItem?.source == .pgc(epId: 13))
        #expect(bangumiQueue?.currentItem?.pgcSeasonType == 4)
        #expect(bangumiQueue?.items[0].opEdSegments == [
            PlaybackSkipSegment(label: "OP", start: 10, end: 100),
            PlaybackSkipSegment(label: "ED", start: 1300, end: 1390),
        ])
        #expect(bangumiQueue?.items[1].opEdSegments == [
            PlaybackSkipSegment(label: "OP", start: 0, end: 90),
        ])
    }

    // MARK: - Task 1.1: Non-P1 & Non-EP1 Mini-Player Return Matching

    @Test("VideoDetailViewModel and BangumiViewModel match non-P1 and non-EP1 mini-player return handoffs cleanly")
    func nonFirstPartAndEpisodeMiniPlayerReturnMatching() throws {
        let multiPart = try Self.makeVideoInfo(
            aid: 3000,
            bvid: "BV1parts3000",
            pages: [
                (cid: 3001, page: 1, part: "Part 1", duration: 120),
                (cid: 3002, page: 2, part: "Part 2", duration: 150),
                (cid: 3003, page: 3, part: "Part 3", duration: 180),
            ]
        )

        // Matching P3 handoff selects P3 (3003), not P1 (3001).
        let p3Return = PendingMiniPlayerReturnVOD(aid: 3000, cid: 3003, source: .ugc)
        #expect(VideoDetailViewModel.resolvedInitialCid(info: multiPart, pendingReturn: p3Return) == 3003)

        // Mismatched aid, PGC source, unknown cid, or nil all safely fall back to P1 (3001).
        #expect(VideoDetailViewModel.resolvedInitialCid(info: multiPart, pendingReturn: nil) == 3001)
        #expect(
            VideoDetailViewModel.resolvedInitialCid(
                info: multiPart,
                pendingReturn: PendingMiniPlayerReturnVOD(aid: 9999, cid: 3003, source: .ugc)
            ) == 3001
        )
        #expect(
            VideoDetailViewModel.resolvedInitialCid(
                info: multiPart,
                pendingReturn: PendingMiniPlayerReturnVOD(aid: 3000, cid: 3003, source: .pgc(epId: 1))
            ) == 3001
        )
        #expect(
            VideoDetailViewModel.resolvedInitialCid(
                info: multiPart,
                pendingReturn: PendingMiniPlayerReturnVOD(aid: 3000, cid: 3999, source: .ugc)
            ) == 3001
        )

        // Bangumi season matches EP5 by source epId and by (aid, cid) fallback.
        let season = try Self.makeBangumiSeason(
            seasonId: 8080,
            episodes: [
                (id: 501, aid: 8001, cid: 8101, title: "1", longTitle: "EP1", op: nil, ed: nil),
                (id: 502, aid: 8002, cid: 8102, title: "2", longTitle: "EP2", op: nil, ed: nil),
                (id: 505, aid: 8005, cid: 8105, title: "5", longTitle: "EP5", op: nil, ed: nil),
            ]
        )
        let episodes = season.episodes ?? []

        let ep5BySource = BangumiViewModel.matchingReturnEpisode(
            in: episodes,
            for: PendingMiniPlayerReturnVOD(aid: 8005, cid: 8105, source: .pgc(epId: 505))
        )
        #expect(ep5BySource?.id == 505)

        let ep5ByAidCid = BangumiViewModel.matchingReturnEpisode(
            in: episodes,
            for: PendingMiniPlayerReturnVOD(aid: 8005, cid: 8105, source: .ugc)
        )
        #expect(ep5ByAidCid?.id == 505)

        let noMatch = BangumiViewModel.matchingReturnEpisode(
            in: episodes,
            for: PendingMiniPlayerReturnVOD(aid: 9999, cid: 9999, source: .pgc(epId: 999))
        )
        #expect(noMatch == nil)
    }

    @Test("PlayerViewModel queries and consumes live non-P1 and non-EP1 mini-player return handoffs without resetting")
    func playerViewModelLiveNonFirstPartAndBangumiReturnHandoff() {
        let vm = PlayerViewModel.shared
        let prefKey = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let originalPref = UserDefaults.standard.object(forKey: prefKey)
        let originalOrder = vm.playbackOrder

        Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        defer {
            Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        }

        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = true
        let coordinator = AppCoordinator(playbackHookProvider: { vm })

        // 1) Bangumi EP5 -> Mini-Player -> Return handoff matches EP5 and does NOT match EP1.
        let seasonId = 6610
        coordinator.navigate(to: .bangumiDetail(seasonId, zoom: .none))
        let pgcLease1 = vm.claimOwnerLease(owner: PlayerViewModel.pgcOwner(seasonId))
        _ = vm.claimSurfaceSlot(ownerLease: pgcLease1, role: .inline)
        vm.mode = .vod
        vm.currentAid = 66105
        vm.currentCid = 6610505
        vm.currentSource = .pgc(epId: 505)
        vm.currentURL = URL(string: "https://example.com/bangumi-ep5.m4s")
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing
        vm.isPlaying = true

        coordinator.goBack()
        #expect(vm.isMiniPlayerActive)
        if let activeSession = vm.miniPlayer.activeSession {
            coordinator.restoreFromMiniPlayer(activeSession)
        }
        #expect(!vm.isMiniPlayerActive)

        let pgcLease2 = vm.claimOwnerLease(owner: PlayerViewModel.pgcOwner(seasonId))
        let pendingBangumi = vm.pendingMiniPlayerReturnVOD(forSeasonId: seasonId, ownerLease: pgcLease2)
        #expect(pendingBangumi == PendingMiniPlayerReturnVOD(aid: 66105, cid: 6610505, source: .pgc(epId: 505)))
        #expect(
            vm.matchesLiveMiniPlayerReturnVOD(
                aid: 66105,
                cid: 6610505,
                source: .pgc(epId: 505),
                ownerLease: pgcLease2
            )
        )
        #expect(
            !vm.matchesLiveMiniPlayerReturnVOD(
                aid: 66101,
                cid: 6610101,
                source: .pgc(epId: 501),
                ownerLease: pgcLease2
            )
        )
        #expect(
            vm.consumeMiniPlayerReturnIfLiveVOD(
                aid: 66105,
                cid: 6610505,
                bvid: nil,
                source: .pgc(epId: 505),
                quality: nil,
                ownerLease: pgcLease2,
                startupTraceToken: nil,
                mediaResetID: nil,
                recoveryCoverIdentity: nil,
                cdnSwitchID: nil,
                streamRetryID: nil
            )
        )
        #expect(vm.miniPlayer.returnHandoff == nil)

        // 2) Multi-part video P3 -> Mini-Player -> Return handoff matches P3 and consumes cleanly.
        vm.stop(reason: .ownerExit)
        coordinator.goHome()
        let target = VideoRouteTarget(videoID: .aid(7720), preview: .init(title: "Multi-P Demo"))
        #expect(coordinator.navigateToVideo(target))
        coordinator.settleVideoNavigation(target.videoID)
        let vodLease1 = vm.claimOwnerLease(owner: "vod-detail-\(UUID().uuidString)")
        _ = vm.claimSurfaceSlot(ownerLease: vodLease1, role: .inline)
        vm.mode = .vod
        vm.currentAid = 7720
        vm.currentCid = 772003
        vm.currentSource = .ugc
        vm.currentURL = URL(string: "https://example.com/video-p3.m4s")
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing
        vm.isPlaying = true

        coordinator.goBack()
        #expect(vm.isMiniPlayerActive)
        if let activeSession = vm.miniPlayer.activeSession {
            coordinator.restoreFromMiniPlayer(activeSession)
        }
        let returningOwner = "vod-detail-\(UUID().uuidString)"
        vm.endForeignOwnerForRouteActivation(incomingOwner: returningOwner)
        let vodLease2 = vm.claimOwnerLease(owner: returningOwner)

        let pendingPart = vm.pendingMiniPlayerReturnVOD(forAid: 7720, ownerLease: vodLease2)
        #expect(pendingPart == PendingMiniPlayerReturnVOD(aid: 7720, cid: 772003, source: .ugc))
        #expect(
            vm.matchesLiveMiniPlayerReturnVOD(
                aid: 7720,
                cid: 772003,
                source: .ugc,
                ownerLease: vodLease2
            )
        )
        #expect(
            !vm.matchesLiveMiniPlayerReturnVOD(
                aid: 7720,
                cid: 772001,
                source: .ugc,
                ownerLease: vodLease2
            )
        )
        #expect(
            vm.consumeMiniPlayerReturnIfLiveVOD(
                aid: 7720,
                cid: 772003,
                bvid: nil,
                source: .ugc,
                quality: nil,
                ownerLease: vodLease2,
                startupTraceToken: nil,
                mediaResetID: nil,
                recoveryCoverIdentity: nil,
                cdnSwitchID: nil,
                streamRetryID: nil
            )
        )
        #expect(vm.miniPlayer.returnHandoff == nil)
    }

    // MARK: - Task 1.2: Autonomous Queue Advance, Mini-Player Metadata, & Teardown Lifecycle

    @Test("Autonomous queue advance updates mini-player activeSession, NowPlaying, skipSegments, and remote track commands")
    func autonomousQueueAdvanceUpdatesMiniPlayerAndNowPlaying() {
        let vm = PlayerViewModel.shared
        let prefKey = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let originalPref = UserDefaults.standard.object(forKey: prefKey)
        let originalOrder = vm.playbackOrder

        Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        defer {
            Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        }

        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = true
        let coordinator = AppCoordinator(playbackHookProvider: { vm })

        let items = Self.makeQueueItems(count: 3, aidBase: 9100)
        let initialTarget = VideoRouteTarget(videoID: .aid(9101), preview: .init(title: items[1].title))
        #expect(coordinator.navigateToVideo(initialTarget))
        coordinator.settleVideoNavigation(initialTarget.videoID)

        let lease = vm.claimOwnerLease(owner: "vod-detail-\(UUID().uuidString)")
        _ = vm.claimSurfaceSlot(ownerLease: lease, role: .inline)
        vm.mode = .vod
        vm.currentAid = items[1].aid
        vm.currentCid = items[1].cid
        vm.currentSource = .ugc
        vm.currentURL = URL(string: "https://example.com/item-2.m4s")
        vm.duration = 150
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing
        vm.isPlaying = true
        vm.setNowPlaying(title: items[1].title, artist: items[1].artist, cover: items[1].coverURL)

        var liveHandledOffsets: [Int] = []
        let queue = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: items,
            currentIndex: 1
        )
        vm.setPlaybackQueue(queue) { offset in
            liveHandledOffsets.append(offset)
            return true
        }

        // While mounted inline (not in mini-player), live handler receives navigation first.
        #expect(vm.canPlayNextTrack)
        #expect(vm.canPlayPreviousTrack)
        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
        #expect(vm.playNextInQueue())
        #expect(liveHandledOffsets == [1])
        #expect(vm.playbackQueue?.currentIndex == 1)

        // Pop into Mini-Player: autonomous queue advance bypasses the popped detail handler and updates activeSession.
        coordinator.goBack()
        #expect(vm.isMiniPlayerActive)
        #expect(vm.miniPlayer.activeSession?.ownerLease == lease)

        #expect(vm.playNextInQueue())
        #expect(liveHandledOffsets == [1]) // Live handler was NOT called while in mini-player.
        #expect(vm.playbackQueue?.currentIndex == 2)
        #expect(vm.miniPlayer.activeSession?.ownerLease == lease)
        #expect(vm.miniPlayer.activeSession?.title == items[2].title)
        #expect(vm.miniPlayer.activeSession?.coverURL == items[2].coverURL)
        #expect(vm.miniPlayer.activeSession?.originRoute == items[2].originRoute.withoutZoom)
        #expect(vm.miniPlayer.activeSession?.originScreenRoute == items[2].originScreenRoute)
        #expect(vm.nowPlayingMeta?.title == items[2].title)
        #expect(vm.nowPlayingMeta?.artist == items[2].artist)
        #expect(vm.nowPlayingMeta?.cover == items[2].coverURL)
        #expect(vm.skipSegments.count == 1)
        #expect(vm.skipSegments.first?.label == "OP")
        #expect(!vm.canPlayNextTrack)
        #expect(vm.canPlayPreviousTrack)
        #expect(!MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)

        // stop(reason: .newContentOwnership) while autonomous advance is in-flight preserves mini-player & queue.
        vm.isAutonomousQueueAdvanceInFlight = true
        vm.stop(reason: .newContentOwnership)
        #expect(vm.isMiniPlayerActive)
        #expect(vm.miniPlayer.activeSession?.ownerLease == lease)
        #expect(vm.playbackQueue?.currentIndex == 2)
        vm.isAutonomousQueueAdvanceInFlight = false

        // stop(reason: .internalReload) preserves playbackQueue.
        vm.stop(reason: .internalReload)
        #expect(vm.playbackQueue?.currentIndex == 2)

        // stop(reason: .ownerExit) tears down playbackQueue, mini-player, and Lock Screen track commands.
        vm.stop(reason: .ownerExit)
        #expect(vm.playbackQueue == nil)
        #expect(!vm.isMiniPlayerActive)
        #expect(!vm.canPlayNextTrack)
        #expect(!vm.canPlayPreviousTrack)
        #expect(!MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        #expect(!MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
    }

    @Test("Autonomous queue advance runs when live page handler reports page deallocated (e.g. PiP or background)")
    func autonomousQueueAdvanceFallsBackWhenLivePageGone() {
        let vm = PlayerViewModel.shared
        let prefKey = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let originalPref = UserDefaults.standard.object(forKey: prefKey)
        let originalOrder = vm.playbackOrder

        Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        defer {
            Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        }

        let lease = vm.claimOwnerLease(owner: PlayerViewModel.pgcOwner(4400))
        vm.mode = .vod
        vm.currentURL = URL(string: "https://example.com/pgc-ep1.m4s")
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing

        let ep1 = PlaybackQueueItem(
            id: "pgc-4400-1",
            aid: 44001,
            cid: 440011,
            title: "Anime",
            artist: "第1话",
            coverURL: "https://example.com/a1.jpg",
            source: .pgc(epId: 1),
            originRoute: .bangumiDetail(4400, zoom: .none),
            originScreenRoute: .bangumi(4400),
            pgcSeasonType: 1
        )
        let ep2 = PlaybackQueueItem(
            id: "pgc-4400-2",
            aid: 44002,
            cid: 440021,
            title: "Anime",
            artist: "第2话",
            coverURL: "https://example.com/a2.jpg",
            source: .pgc(epId: 2),
            originRoute: .bangumiDetail(4400, zoom: .none),
            originScreenRoute: .bangumi(4400),
            opEdSegments: [PlaybackSkipSegment(label: "OP", start: 12, end: 102)],
            pgcSeasonType: 1
        )

        // Simulate a deallocated page ViewModel whose weak-self live handler returns false.
        let queue = PlaybackQueueContext(
            kind: .bangumiSeason(seasonId: 4400),
            items: [ep1, ep2],
            currentIndex: 0
        )
        vm.setPlaybackQueue(queue) { _ in false }

        #expect(!vm.isMiniPlayerActive)
        #expect(vm.playNextInQueue())
        #expect(vm.playbackQueue?.currentIndex == 1)
        #expect(vm.pgcSeasonContext?.sid == 4400)
        #expect(vm.pgcSeasonContext?.type == 1)
        #expect(vm.nowPlayingMeta?.artist == "第2话")
        #expect(vm.skipSegments.first?.label == "OP")
        #expect(vm.skipSegments.first?.start == 12)
        #expect(vm.skipSegments.first?.end == 102)
        #expect(vm.currentOwnerLease == lease)
    }

    // MARK: - Playlist Order Modes, Reorder, Delete, Exit & Multi-Part Expansion

    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("PlaylistOrderMode sequential, loopList wrap-around, shuffle full-cycle traversal, and defaults persistence")
    func playlistOrderModesAndShuffleTraversal() throws {
        let (defaults, suiteName) = Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PlaylistOrderMode.loadPreferred(from: defaults) == .sequential)
        for mode in PlaylistOrderMode.allCases {
            PlaylistOrderMode.savePreferred(mode, to: defaults)
            #expect(PlaylistOrderMode.loadPreferred(from: defaults) == mode)
        }

        let items = Self.makeQueueItems(count: 4, aidBase: 5100)

        // 1) Sequential stops at both boundaries.
        let seq = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: items,
            currentIndex: 3,
            playlistOrderMode: .sequential
        )
        #expect(!seq.hasNext)
        #expect(seq.hasPrevious)
        #expect(seq.advancing(by: 1) == nil)
        #expect(seq.upNextItem == nil)

        // 2) Loop List wraps forward and backward seamlessly (including single-item playlists).
        let loopAtEnd = seq.settingOrderMode(.loopList)
        #expect(loopAtEnd.hasNext)
        #expect(loopAtEnd.hasPrevious)
        let wrappedForward = try #require(loopAtEnd.advancing(by: 1))
        #expect(wrappedForward.0.currentIndex == 0)
        #expect(wrappedForward.1 == items[0])
        let wrappedBackward = try #require(wrappedForward.0.advancing(by: -1))
        #expect(wrappedBackward.0.currentIndex == 3)
        #expect(wrappedBackward.1 == items[3])

        let singleLoop = PlaybackQueueContext(
            kind: .playlist(name: "Solo"),
            items: [items[0]],
            currentIndex: 0,
            playlistOrderMode: .loopList
        )
        #expect(singleLoop.hasNext)
        #expect(singleLoop.hasPrevious)
        #expect(singleLoop.advancing(by: 1)?.0.currentIndex == 0)
        #expect(singleLoop.advancing(by: -1)?.0.currentIndex == 0)

        // 3) Shuffle pins the active item at position 0, visits every item once, and avoids immediate repeats across cycle boundary.
        var rng = SeededRNG(seed: 42)
        var shuffled = PlaybackQueueContext(
            kind: .playlist(name: "Favorites"),
            items: items,
            currentIndex: 2
        ).settingOrderMode(.shuffle, using: &rng)

        #expect(shuffled.playlistOrderMode == .shuffle)
        #expect(shuffled.currentItem == items[2])
        #expect(shuffled.shuffledOrder.first == items[2].id)
        #expect(Set(shuffled.shuffledOrder) == Set(items.map(\.id)))

        var visitedIDs: [String] = [try #require(shuffled.currentItem?.id)]
        for _ in 0..<(items.count - 1) {
            let step = try #require(shuffled.advancing(by: 1, using: &rng))
            shuffled = step.0
            visitedIDs.append(step.1.id)
        }
        #expect(visitedIDs.count == items.count)
        #expect(Set(visitedIDs) == Set(items.map(\.id)))

        // Stepping back returns to the exact previous item in the shuffle cycle.
        let prevStep = try #require(shuffled.advancing(by: -1, using: &rng))
        #expect(prevStep.1.id == visitedIDs[visitedIDs.count - 2])

        // Advancing past the last item regenerates a full permutation without immediately repeating the last item.
        let lastIDOfCycle1 = visitedIDs.last!
        let nextCycleStart = try #require(shuffled.advancing(by: 1, using: &rng))
        #expect(nextCycleStart.1.id != lastIDOfCycle1)
        #expect(Set(nextCycleStart.0.shuffledOrder) == Set(items.map(\.id)))
    }

    @Test("Playlist reorder preserves active item index, remove handles before/at/after/last, and exitPlaylistMode preserves live playback")
    func playlistReorderDeleteAndExitMode() throws {
        let items = Self.makeQueueItems(count: 4, aidBase: 6200)
        var queue = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: items,
            currentIndex: 1
        )
        let activeID = items[1].id

        // Move item 3 (after active) to index 0 (before active) -> active shifts from index 1 to 2.
        queue = queue.movingItems(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(queue.items.map(\.id) == [items[3].id, items[0].id, items[1].id, items[2].id])
        #expect(queue.currentIndex == 2)
        #expect(queue.currentItem?.id == activeID)

        // Move active item itself from index 2 to end (toOffset: 4) -> active follows to index 3.
        queue = queue.movingItems(fromOffsets: IndexSet(integer: 2), toOffset: 4)
        #expect(queue.items.map(\.id) == [items[3].id, items[0].id, items[2].id, items[1].id])
        #expect(queue.currentIndex == 3)
        #expect(queue.currentItem?.id == activeID)

        // Remove item before active -> currentIndex decrements, removedActiveItem == false.
        let removedBefore = queue.removingItem(id: items[3].id)
        #expect(!removedBefore.removedActiveItem)
        let qAfterBefore = try #require(removedBefore.context)
        #expect(qAfterBefore.currentIndex == 2)
        #expect(qAfterBefore.currentItem?.id == activeID)

        // Move active to index 0, remove item after active -> currentIndex stays 0.
        let qActiveFirst = qAfterBefore.movingItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(qActiveFirst.currentIndex == 0)
        let removedAfter = qActiveFirst.removingItem(id: items[2].id)
        #expect(!removedAfter.removedActiveItem)
        let qAfterAfter = try #require(removedAfter.context)
        #expect(qAfterAfter.currentIndex == 0)
        #expect(qAfterAfter.currentItem?.id == activeID)

        // Remove active item while another remains -> advances to next item at that slot.
        let removedActive = qAfterAfter.removingItem(id: activeID)
        #expect(removedActive.removedActiveItem)
        let qOneLeft = try #require(removedActive.context)
        #expect(qOneLeft.items.count == 1)
        #expect(qOneLeft.currentIndex == 0)
        #expect(qOneLeft.currentItem?.id == items[0].id)

        // Remove the last remaining item -> returns nil context.
        let removedLast = qOneLeft.removingItem(id: items[0].id)
        #expect(removedLast.removedActiveItem)
        #expect(removedLast.context == nil)

        // PlayerViewModel.exitPlaylistMode() clears playlist queue while keeping active playback alive.
        let vm = PlayerViewModel.shared
        let prefKey = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let originalPref = UserDefaults.standard.object(forKey: prefKey)
        let originalOrder = vm.playbackOrder
        let originalPlaylistMode = UserDefaults.standard.object(forKey: PlaylistOrderMode.defaultsKey)

        Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
        defer {
            Self.resetPlayerSharedState(originalMiniPlayerPref: originalPref, originalOrder: originalOrder)
            if let originalPlaylistMode {
                UserDefaults.standard.set(originalPlaylistMode, forKey: PlaylistOrderMode.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PlaylistOrderMode.defaultsKey)
            }
        }

        let lease = vm.claimOwnerLease(owner: "vod-detail-playlist-exit")
        vm.mode = .vod
        vm.currentAid = items[0].aid
        vm.currentCid = items[0].cid
        vm.currentSource = .ugc
        let liveURL = URL(string: "https://example.com/live-playlist-item.m4s")!
        vm.currentURL = liveURL
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing
        vm.isPlaying = true
        vm.setPlaybackQueue(PlaybackQueueContext(kind: .playlist(name: "Watch Later"), items: items, currentIndex: 0))

        #expect(vm.activePlaylistQueue != nil)
        #expect(vm.canPlayNextTrack)

        vm.exitPlaylistMode()

        #expect(vm.playbackQueue == nil)
        #expect(vm.activePlaylistQueue == nil)
        #expect(!vm.canPlayNextTrack)
        #expect(!vm.canPlayPreviousTrack)
        #expect(vm.currentOwnerLease == lease)
        #expect(vm.currentAid == items[0].aid)
        #expect(vm.currentCid == items[0].cid)
        #expect(vm.currentURL == liveURL)
        #expect(vm.playbackTerminalState == .active)
        #expect(vm.isPlaying)
    }

    @Test("Multi-part video expands P1..Pn in-place inside playlist and stays contiguous in shuffle mode")
    func playlistMultiPartExpansionInPlaceAndShuffle() throws {
        let items = Self.makeQueueItems(count: 3, aidBase: 7300)
        let multiPartInfo = try Self.makeVideoInfo(
            aid: items[1].aid,
            bvid: "BV1multi7301",
            pages: [
                (cid: 73011, page: 1, part: "Intro", duration: 100),
                (cid: 73012, page: 2, part: "Main", duration: 220),
                (cid: 73013, page: 3, part: "Finale", duration: 160),
            ]
        )

        let baseQueue = PlaybackQueueContext(
            kind: .playlist(name: "Study List"),
            items: items,
            currentIndex: 1
        )
        let expanded = baseQueue.expandingMultiPartVideo(
            info: multiPartInfo,
            videoID: .bvid("BV1multi7301"),
            currentCid: 73011
        )

        #expect(expanded.items.count == 5)
        #expect(expanded.items.map(\.aid) == [7300, 7301, 7301, 7301, 7302])
        #expect(expanded.items[1].partBadge == "P1/3")
        #expect(expanded.items[2].partBadge == "P2/3")
        #expect(expanded.items[3].partBadge == "P3/3")
        #expect(expanded.currentIndex == 1)
        #expect(expanded.currentItem?.cid == 73011)

        // Sequential playback traverses P1 -> P2 -> P3 before advancing to Video 3 (aid 7302).
        let p2 = try #require(expanded.advancing(by: 1))
        #expect(p2.1.aid == 7301 && p2.1.cid == 73012)
        let p3 = try #require(p2.0.advancing(by: 1))
        #expect(p3.1.aid == 7301 && p3.1.cid == 73013)
        let v3 = try #require(p3.0.advancing(by: 1))
        #expect(v3.1.aid == 7302)

        // Expanding in shuffle mode keeps P1, P2, P3 contiguous in shuffledOrder so all parts finish before next video.
        var rng = SeededRNG(seed: 99)
        let shuffledBefore = baseQueue.settingOrderMode(.shuffle, using: &rng)
        let shuffledExpanded = shuffledBefore.expandingMultiPartVideo(
            info: multiPartInfo,
            videoID: .bvid("BV1multi7301"),
            currentCid: 73011
        )
        let partIDs = shuffledExpanded.items.filter { $0.aid == 7301 }.map(\.id)
        let firstPartPos = try #require(shuffledExpanded.shuffledOrder.firstIndex(of: partIDs[0]))
        #expect(Array(shuffledExpanded.shuffledOrder[firstPartPos..<(firstPartPos + 3)]) == partIDs)

        // VideoDetailViewModel.resolvedInitialCid honors preferredCid when no mini-player return handoff is pending.
        #expect(
            VideoDetailViewModel.resolvedInitialCid(
                info: multiPartInfo,
                pendingReturn: nil,
                preferredCid: 73012
            ) == 73012
        )
    }
}
