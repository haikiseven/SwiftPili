import Foundation
import Testing
import UIKit
@testable import SwiftPili

@Suite("Resume Notice, Cross-Part Resume & Sleep Timer", .serialized)
@MainActor
struct ResumeNoticeAndSleepTimerTests {

    private static func makeVideoInfo(
        aid: Int = 7700,
        bvid: String = "BV1resume0001",
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
          "title": "Multi-Part Resume Sample",
          "desc": "",
          "pic": "https://example.com/cover.jpg",
          "duration": \(pages.first?.duration ?? 600),
          "pubdate": 1700000000,
          "owner": {
            "mid": 99,
            "name": "Creator",
            "face": "https://example.com/face.jpg"
          },
          "stat": {
            "view": 1000,
            "danmaku": 50,
            "reply": 10,
            "favorite": 5,
            "coin": 4,
            "share": 2,
            "like": 40
          },
          "pages": [\(pageJSON)]
        }
        """
        return try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
    }

    private static func resetPlayerSharedState(originalOrder: PlaybackOrder) {
        let vm = PlayerViewModel.shared
        vm.cancelSleepTimer()
        vm.dismissNoticeBanner()
        vm.pendingHistoryResumeNotice = nil
        vm.pendingPartLocationNotice = nil
        vm.isAutonomousQueueAdvanceInFlight = false
        vm.miniPlayer.clearAll()
        vm.error = nil
        vm.unavailability = nil
        vm.terminalOpenFailure = false
        vm.playbackOrder = originalOrder
        vm.stop(reason: .ownerExit)
        vm.ownerKey = ""
        vm.activeSceneID = nil
    }

    // MARK: - Module 1: PendingHistoryResumeNotice & Interactive Notice Banner

    @Test("PendingHistoryResumeNotice formats single-part and multi-part text accurately")
    func pendingHistoryResumeNoticeFormatting() {
        let singlePart = PendingHistoryResumeNotice(resumedSeconds: 268, partNumber: nil)
        let expectedSingle = String(format: String(localized: "Resumed at %@"), FormatUtils.duration(268))
        #expect(singlePart.formattedNoticeText() == expectedSingle)

        let multiPart = PendingHistoryResumeNotice(resumedSeconds: 268, partNumber: 3)
        let expectedMulti = String(
            format: String(localized: "Resumed P%lld at %@"),
            Int64(3),
            FormatUtils.duration(268)
        )
        #expect(multiPart.formattedNoticeText() == expectedMulti)

        let invalid = PendingHistoryResumeNotice(resumedSeconds: .nan, partNumber: nil)
        let expectedZero = String(format: String(localized: "Resumed at %@"), FormatUtils.duration(0))
        #expect(invalid.formattedNoticeText() == expectedZero)
    }

    @Test("Interactive notice banner invokes action, dismisses immediately, and respects resume-only dismissal")
    func interactiveNoticeBannerLifecycle() {
        let vm = PlayerViewModel.shared
        let originalOrder = vm.playbackOrder
        defer { Self.resetPlayerSharedState(originalOrder: originalOrder) }
        Self.resetPlayerSharedState(originalOrder: originalOrder)

        var invoked = 0
        vm.showInteractiveNotice(
            text: "Resumed at 4:28",
            actionTitle: "Start Over",
            duration: 5.0,
            isResumeNotice: true
        ) {
            invoked += 1
        }
        #expect(vm.activeNoticeBanner != nil)
        #expect(vm.activeNoticeBanner?.isInteractive == true)
        #expect(vm.activeNoticeBanner?.isResumeNotice == true)
        #expect(vm.skipNotice == "Resumed at 4:28")

        vm.triggerNoticeBannerAction()
        #expect(invoked == 1)
        #expect(vm.activeNoticeBanner == nil)
        #expect(vm.skipNotice == nil)

        // Non-resume interactive banner (e.g. SponsorBlock Undo) survives resume-only dismissal.
        vm.showInteractiveNotice(
            text: "Skipped Sponsor",
            actionTitle: "Undo",
            duration: 5.0,
            isResumeNotice: false
        ) {}
        vm.dismissNoticeBanner(onlyIfResume: true)
        #expect(vm.activeNoticeBanner?.text == "Skipped Sponsor")

        // Resume banner is cleared by resume-only dismissal.
        vm.showInteractiveNotice(
            text: "Resumed P3 at 2:00",
            actionTitle: "Start Over",
            duration: 5.0,
            isResumeNotice: true
        ) {}
        vm.dismissNoticeBanner(onlyIfResume: true)
        #expect(vm.activeNoticeBanner == nil)
    }

    @Test("presentPendingHistoryResumeNoticeIfNeeded consumes resume and part-location notices once")
    func presentPendingHistoryResumeNoticeOnce() {
        let vm = PlayerViewModel.shared
        let originalOrder = vm.playbackOrder
        defer { Self.resetPlayerSharedState(originalOrder: originalOrder) }
        Self.resetPlayerSharedState(originalOrder: originalOrder)

        vm.pendingHistoryResumeNotice = PendingHistoryResumeNotice(resumedSeconds: 125, partNumber: 2)
        vm.presentPendingHistoryResumeNoticeIfNeeded()
        #expect(vm.pendingHistoryResumeNotice == nil)
        #expect(vm.activeNoticeBanner?.isResumeNotice == true)
        #expect(vm.activeNoticeBanner?.actionTitle == String(localized: "Start Over"))
        #expect(vm.activeNoticeBanner?.isInteractive == true)

        vm.dismissNoticeBanner()
        vm.presentPendingHistoryResumeNoticeIfNeeded()
        #expect(vm.activeNoticeBanner == nil)

        vm.pendingPartLocationNotice = 4
        vm.presentPendingHistoryResumeNoticeIfNeeded()
        #expect(vm.pendingPartLocationNotice == nil)
        #expect(vm.activeNoticeBanner?.isInteractive == false)
        #expect(
            vm.activeNoticeBanner?.text == String(
                format: String(localized: "Resumed at P%lld"),
                Int64(4)
            )
        )
    }

    @Test("SponsorBlock revertSkip rolls back stats and undo keeps skipped UUID to prevent re-skip loop")
    func sponsorBlockUndoAndRevertSkip() {
        let vm = PlayerViewModel.shared
        let manager = SponsorBlockManager.shared
        let originalOrder = vm.playbackOrder
        let originalEnabled = manager.isEnabled
        let originalShowNotice = manager.showSkipNotice
        let originalAction = manager.action(for: .sponsor)
        let originalCount = manager.skippedCount
        let originalSeconds = manager.skippedSeconds
        defer {
            manager.clear()
            manager.setAction(originalAction, for: .sponsor)
            manager.showSkipNotice = originalShowNotice
            manager.isEnabled = originalEnabled
            manager.restoreStatsForTesting(count: originalCount, seconds: originalSeconds)
            Self.resetPlayerSharedState(originalOrder: originalOrder)
        }
        Self.resetPlayerSharedState(originalOrder: originalOrder)

        manager.isEnabled = true
        manager.showSkipNotice = true
        manager.setAction(.skip, for: .sponsor)
        manager.restoreStatsForTesting(count: 10, seconds: 100.0)

        let segment = SponsorSegment(
            uuid: "seg-undo-test-1",
            category: .sponsor,
            actionType: .skip,
            start: 30,
            end: 55,
            videoDuration: 300,
            locked: true,
            votes: 10,
            cid: "9001"
        )
        manager.setLoadedSegmentsForTesting(videoID: "BV1sponsor001", cid: 9001, segments: [segment])

        vm.mode = .vod
        vm.currentCid = 9001
        vm.pendingSeekTarget = nil
        vm.lastSponsorSkipAt = 0
        vm.sponsorSkippedUUIDs = []

        vm.autoSkipSponsorIfNeeded(at: 31)
        #expect(vm.sponsorSkippedUUIDs.contains(segment.uuid))
        #expect(manager.skippedCount == 11)
        #expect(abs(manager.skippedSeconds - 125.0) < 0.001)
        #expect(vm.activeNoticeBanner?.actionTitle == String(localized: "Undo"))
        #expect(vm.activeNoticeBanner?.isResumeNotice == false)

        // Trigger Undo: rolls back skip counters and dismisses banner, while keeping UUID excluded.
        vm.triggerNoticeBannerAction()
        #expect(vm.activeNoticeBanner == nil)
        #expect(manager.skippedCount == 10)
        #expect(abs(manager.skippedSeconds - 100.0) < 0.001)
        #expect(vm.sponsorSkippedUUIDs.contains(segment.uuid))
        #expect(manager.autoSkipSegment(at: 30, excluding: vm.sponsorSkippedUUIDs) == nil)

        // Direct revertSkip clamps cleanly at 0.
        manager.restoreStatsForTesting(count: 0, seconds: 5.0)
        manager.revertSkip(seconds: 20.0)
        #expect(manager.skippedCount == 0)
        #expect(manager.skippedSeconds == 0)
    }

    // MARK: - Module 2: Cross-Part Resume Resolution

    @Test("resolveCrossPartResume switches to P3 with resumeAt when no preferredCid or pending return")
    func crossPartResumeJumpsToLastPlayedPart() throws {
        let info = try Self.makeVideoInfo(pages: [
            (cid: 101, page: 1, part: "Part 1", duration: 600),
            (cid: 102, page: 2, part: "Part 2", duration: 400),
            (cid: 103, page: 3, part: "Part 3", duration: 500),
            (cid: 104, page: 4, part: "Part 4", duration: 300),
        ])

        let plan = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 101,
            preferredCid: nil,
            hasPendingReturn: false,
            lastPlayCid: 103,
            lastPlayTimeMs: 120_000
        )
        #expect(plan?.targetPage.cid == 103)
        #expect(plan?.resumedPartNumber == 3)
        #expect(plan?.resumeAt == 120)
    }

    @Test("resolveCrossPartResume respects explicit preferredCid and pending mini-player return")
    func crossPartResumeRespectsExplicitOverrides() throws {
        let info = try Self.makeVideoInfo(pages: [
            (cid: 101, page: 1, part: "Part 1", duration: 600),
            (cid: 102, page: 2, part: "Part 2", duration: 400),
            (cid: 103, page: 3, part: "Part 3", duration: 500),
        ])

        let withPreferred = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 102,
            preferredCid: 102,
            hasPendingReturn: false,
            lastPlayCid: 103,
            lastPlayTimeMs: 90_000
        )
        #expect(withPreferred == nil)

        let withPendingReturn = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 101,
            preferredCid: nil,
            hasPendingReturn: true,
            lastPlayCid: 103,
            lastPlayTimeMs: 90_000
        )
        #expect(withPendingReturn == nil)
    }

    @Test("resolveCrossPartResume starts from P1 when final part is watched to end")
    func crossPartResumeResetsWhenFinalPartCompleted() throws {
        let info = try Self.makeVideoInfo(pages: [
            (cid: 101, page: 1, part: "Part 1", duration: 600),
            (cid: 102, page: 2, part: "Part 2", duration: 400),
            (cid: 103, page: 3, part: "Part 3", duration: 120),
        ])

        let sentinelEnd = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 101,
            preferredCid: nil,
            hasPendingReturn: false,
            lastPlayCid: 103,
            lastPlayTimeMs: -1
        )
        #expect(sentinelEnd == nil)

        // Near end of final 120s part (115s >= 120 - 15) must also restart from P1 00:00.
        let nearEnd = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 101,
            preferredCid: nil,
            hasPendingReturn: false,
            lastPlayCid: 103,
            lastPlayTimeMs: 115_000
        )
        #expect(nearEnd == nil)
    }

    @Test("resolveCrossPartResume locates to non-final part at 00:00 when stopped at 0..5s or completed")
    func crossPartResumeLocatesToNonFinalPartOrigin() throws {
        let info = try Self.makeVideoInfo(pages: [
            (cid: 101, page: 1, part: "Part 1", duration: 600),
            (cid: 102, page: 2, part: "Part 2", duration: 400),
            (cid: 103, page: 3, part: "Part 3", duration: 500),
            (cid: 104, page: 4, part: "Part 4", duration: 300),
        ])

        let earlyStop = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 101,
            preferredCid: nil,
            hasPendingReturn: false,
            lastPlayCid: 103,
            lastPlayTimeMs: 2_500
        )
        #expect(earlyStop?.targetPage.cid == 103)
        #expect(earlyStop?.resumedPartNumber == 3)
        #expect(earlyStop?.resumeAt == nil)

        let nonFinalCompleted = VideoDetailViewModel.resolveCrossPartResume(
            info: info,
            initialCid: 101,
            preferredCid: nil,
            hasPendingReturn: false,
            lastPlayCid: 103,
            lastPlayTimeMs: -1
        )
        #expect(nonFinalCompleted?.targetPage.cid == 103)
        #expect(nonFinalCompleted?.resumedPartNumber == 3)
        #expect(nonFinalCompleted?.resumeAt == nil)
    }

    // MARK: - Module 3: Player Sleep Timer

    @Test("PlayerSleepTimerOption lists End of Current Video only when allowed")
    func sleepTimerOptionsFilterEndOfVideo() {
        let vodOptions = PlayerSleepTimerOption.options(allowsEndOfVideo: true)
        #expect(vodOptions == [.off, .endOfVideo, .minutes(15), .minutes(30), .minutes(60)])

        let liveOptions = PlayerSleepTimerOption.options(allowsEndOfVideo: false)
        #expect(liveOptions == [.off, .minutes(15), .minutes(30), .minutes(60)])
    }

    @Test("shouldCloseSessionOnExpiry distinguishes foreground from mini-player, background, and PiP")
    func sleepTimerCloseSessionPolicy() {
        #expect(
            PlayerSleepTimer.shouldCloseSessionOnExpiry(
                hasActiveMiniPlayer: false,
                applicationState: .active,
                isPiPActive: false
            ) == false
        )
        #expect(
            PlayerSleepTimer.shouldCloseSessionOnExpiry(
                hasActiveMiniPlayer: true,
                applicationState: .active,
                isPiPActive: false
            ) == true
        )
        #expect(
            PlayerSleepTimer.shouldCloseSessionOnExpiry(
                hasActiveMiniPlayer: false,
                applicationState: .background,
                isPiPActive: false
            ) == true
        )
        #expect(
            PlayerSleepTimer.shouldCloseSessionOnExpiry(
                hasActiveMiniPlayer: false,
                applicationState: .inactive,
                isPiPActive: false
            ) == true
        )
        #expect(
            PlayerSleepTimer.shouldCloseSessionOnExpiry(
                hasActiveMiniPlayer: false,
                applicationState: .active,
                isPiPActive: true
            ) == true
        )
    }

    @Test("PlayerSleepTimer tracks countdown badge, deterministic expiry, cancellation, and live transition")
    func sleepTimerStateTransitions() {
        let timer = PlayerSleepTimer()
        let start = ContinuousClock.now
        var expiredCount = 0

        #expect(timer.option == .off)
        #expect(timer.menuBadge == nil)

        timer.select(.endOfVideo, allowsEndOfVideo: true) { expiredCount += 1 }
        #expect(timer.option == .endOfVideo)
        #expect(timer.remainingSeconds == nil)
        #expect(timer.menuBadge == String(localized: "End of Video"))

        // Switching to live clears .endOfVideo.
        timer.clearEndOfVideoIfUnsupported()
        #expect(timer.option == .off)

        // Selecting .endOfVideo while disallowed stays .off.
        timer.select(.endOfVideo, allowsEndOfVideo: false) { expiredCount += 1 }
        #expect(timer.option == .off)

        // Selecting 15 minutes sets countdown and formats mm:ss.
        timer.select(.minutes(15), allowsEndOfVideo: true, now: start) {
            expiredCount += 1
        }
        #expect(timer.option == .minutes(15))
        #expect(timer.remainingSeconds == 900)
        #expect(timer.menuBadge == "15:00")

        // Advance 28 seconds -> 14:32 remaining, not expired.
        let midExpired = timer.reconcile(now: start.advanced(by: .seconds(28))) {
            expiredCount += 1
        }
        #expect(midExpired == false)
        #expect(timer.remainingSeconds == 872)
        #expect(timer.menuBadge == "14:32")
        #expect(expiredCount == 0)

        // Timed countdown is preserved when switching to live.
        timer.clearEndOfVideoIfUnsupported()
        #expect(timer.option == .minutes(15))

        // Advance past deadline -> expires once and resets to .off.
        let endExpired = timer.reconcile(now: start.advanced(by: .seconds(900))) {
            expiredCount += 1
        }
        #expect(endExpired == true)
        #expect(expiredCount == 1)
        #expect(timer.option == .off)
        #expect(timer.remainingSeconds == nil)
        #expect(timer.menuBadge == nil)
    }

    @Test("PlayerViewModel mode transition to live clears endOfVideo but keeps timed sleep timer")
    func playerViewModelSleepTimerModeTransitionAndForegroundExpiry() {
        let vm = PlayerViewModel.shared
        let originalOrder = vm.playbackOrder
        defer { Self.resetPlayerSharedState(originalOrder: originalOrder) }
        Self.resetPlayerSharedState(originalOrder: originalOrder)

        vm.mode = .vod
        vm.setSleepTimer(.endOfVideo)
        #expect(vm.sleepTimerOption == .endOfVideo)

        vm.mode = .live
        #expect(vm.sleepTimerOption == .off)

        vm.setSleepTimer(.minutes(30))
        #expect(vm.sleepTimerOption == .minutes(30))

        vm.mode = .vod
        #expect(vm.sleepTimerOption == .minutes(30))

        vm.playbackIntent = .playing
        vm.handleSleepTimerExpired(reason: .countdown)
        #expect(vm.sleepTimerOption == .off)
        #expect(vm.playbackIntent == .pausedByUser)
        #expect(vm.activeNoticeBanner?.text == String(localized: "Paused by sleep timer"))
    }
}
