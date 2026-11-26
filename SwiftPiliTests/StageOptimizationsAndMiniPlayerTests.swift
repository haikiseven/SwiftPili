import CoreGraphics
import CoreVideo
import Foundation
import os
import SwiftUI
import Testing
import UIKit
@testable import SwiftPili

// MARK: - Stage 1: WBISigner & HomeFeedSnapshotStore

@Suite("Stage 1: WBI Signer & Home Feed Snapshot")
struct Stage1ColdStartOptimizationTests {
    private static let sampleNavPayload: Data = Data(
        """
        {
          "code": 0,
          "message": "0",
          "data": {
            "wbi_img": {
              "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
              "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
            }
          }
        }
        """.utf8
    )

    private static let alternateNavPayload: Data = Data(
        """
        {
          "code": 0,
          "message": "0",
          "data": {
            "wbi_img": {
              "img_url": "https://i0.hdslb.com/bfs/wbi/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png",
              "sub_url": "https://i0.hdslb.com/bfs/wbi/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png"
            }
          }
        }
        """.utf8
    )

    private static func beijingDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
        let components = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        return calendar.date(from: components)!
    }

    private static func makeRecommendItem(
        id: Int,
        bvid: String? = nil,
        title: String? = nil,
        goto: String? = "av",
        includeOwner: Bool = true
    ) -> RecommendResult.RecommendItem {
        RecommendResult.RecommendItem(
            id: id,
            bvid: bvid ?? "BV1test\(String(format: "%05d", id))",
            title: title ?? "Video #\(id)",
            pic: "https://i0.hdslb.com/bfs/archive/\(id).jpg",
            pic4By3: "https://i0.hdslb.com/bfs/archive/\(id)_43.jpg",
            cover43: nil,
            duration: 120 + id,
            owner: includeOwner
                ? VideoInfo.VideoOwner(
                    mid: 1000 + id,
                    name: "UP \(id)",
                    face: "https://i0.hdslb.com/bfs/face/\(id).jpg"
                )
                : nil,
            stat: RecommendResult.RecommendItem.RecommendStat(
                view: 5000 + id,
                like: 300 + id,
                danmaku: 40 + id
            ),
            goto: goto,
            uri: "bilibili://video/\(id)",
            roomId: nil
        )
    }

    @Test("WBISigner warm-start hits persisted key on same Beijing day within 12h TTL and expires cleanly")
    func wbiSignerWarmStartTTLAndBeijingDayBoundary() async throws {
        let suiteName = "com.swiftpili.tests.wbi.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clock = OSAllocatedUnfairLock(
            initialState: Self.beijingDate(year: 2026, month: 11, day: 24, hour: 8, minute: 0)
        )
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let payload = Self.sampleNavPayload

        let makeSigner: () -> WBISigner = {
            WBISigner(
                storage: WBIMixinKeyStorage(defaults: defaults),
                now: { clock.withLock { $0 } },
                fetchNavData: {
                    fetchCount.withLock { $0 += 1 }
                    return payload
                }
            )
        }

        // Cold signer fetches nav once and persists the mixin key.
        let coldSigner = makeSigner()
        let firstSigned = try await coldSigner.sign(params: ["foo": "bar"])
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(firstSigned["w_rid"]?.count == 32)
        #expect(firstSigned["wts"] == String(Int(clock.withLock { $0 }.timeIntervalSince1970)))

        let persisted = try #require(WBIMixinKeyStorage(defaults: defaults).load())
        #expect(persisted.mixinKey.count == 32)
        #expect(persisted.fetchedAt == clock.withLock { $0 })

        // Warm-start relaunch 6 hours later on the same Beijing calendar day skips network fetch completely.
        clock.withLock { $0 = Self.beijingDate(year: 2026, month: 11, day: 24, hour: 14, minute: 0) }
        let warmSigner = makeSigner()
        let warmSigned = try await warmSigner.sign(params: ["foo": "bar"])
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(warmSigned["w_rid"]?.count == 32)

        // Exact 12h TTL boundary on the same Beijing calendar day expires and triggers fresh fetch.
        let at12Hours = Self.beijingDate(year: 2026, month: 11, day: 24, hour: 20, minute: 0)
        #expect(!WBISigner.isValidMixinKey(fetchedAt: persisted.fetchedAt, now: at12Hours))
        clock.withLock { $0 = at12Hours }
        _ = try await warmSigner.sign(params: ["foo": "bar"])
        #expect(fetchCount.withLock { $0 } == 2)

        // Crossing Beijing midnight (20:00 -> next day 00:30, only 4.5h elapsed) invalidates persisted key on warm start.
        let pastMidnight = Self.beijingDate(year: 2026, month: 11, day: 25, hour: 0, minute: 30)
        #expect(!WBISigner.isValidMixinKey(fetchedAt: at12Hours, now: pastMidnight))
        clock.withLock { $0 = pastMidnight }
        let postMidnightSigner = makeSigner()
        #expect(WBIMixinKeyStorage(defaults: defaults).load() == nil)
        _ = try await postMidnightSigner.sign(params: ["foo": "bar"])
        #expect(fetchCount.withLock { $0 } == 3)
        #expect(WBIMixinKeyStorage(defaults: defaults).load()?.fetchedAt == pastMidnight)

        // Negative clock skew (now < fetchedAt) is treated as invalid.
        let beforeFetch = Self.beijingDate(year: 2026, month: 11, day: 25, hour: 0, minute: 15)
        #expect(!WBISigner.isValidMixinKey(fetchedAt: pastMidnight, now: beforeFetch))
    }

    @Test("WBISigner invalidate clears persisted storage and forces a fresh key fetch")
    func wbiSignerInvalidateClearsPersistedKeyAndRefetches() async throws {
        let suiteName = "com.swiftpili.tests.wbi.invalidate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fixedNow = Self.beijingDate(year: 2026, month: 11, day: 24, hour: 10, minute: 0)
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let firstPayload = Self.sampleNavPayload
        let secondPayload = Self.alternateNavPayload

        let storage = WBIMixinKeyStorage(defaults: defaults)
        let signer = WBISigner(
            storage: storage,
            now: { fixedNow },
            fetchNavData: {
                let index = fetchCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                return index == 1 ? firstPayload : secondPayload
            }
        )

        let signedBefore = try await signer.sign(params: ["aid": "12345"])
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(storage.load() != nil)

        await signer.invalidate()
        #expect(storage.load() == nil)

        let signedAfter = try await signer.sign(params: ["aid": "12345"])
        #expect(fetchCount.withLock { $0 } == 2)
        #expect(storage.load() != nil)
        #expect(signedBefore["w_rid"] != signedAfter["w_rid"])
    }

    @Test("HomeFeedSnapshotStore persists top-20 items, isolates accounts, and enforces expiration")
    func homeFeedSnapshotStorePersistenceAndAccountIsolation() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-feed-snapshot-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let baseTime = Date(timeIntervalSince1970: 1_760_000_000)
        let items = (1...25).map { Self.makeRecommendItem(id: $0) }

        let writerStore = HomeFeedSnapshotStore(
            fileURL: tempURL,
            maxItemCount: HomeFeedSnapshotStore.defaultMaxItemCount,
            maxAge: 3600
        )
        writerStore.save(items, forAccountScope: "mid-1001", now: baseTime)
        writerStore.waitForPendingIO()

        // Cold-launch reader instance loads exact top 20 items from disk for the matching account.
        let coldReader = HomeFeedSnapshotStore(
            fileURL: tempURL,
            maxItemCount: HomeFeedSnapshotStore.defaultMaxItemCount,
            maxAge: 3600
        )
        let restored = coldReader.load(
            forAccountScope: "mid-1001",
            now: baseTime.addingTimeInterval(300)
        )
        #expect(restored.count == 20)
        #expect(restored.first?.id == 1)
        #expect(restored.first?.bvid == "BV1test00001")
        #expect(restored.first?.owner?.mid == 1001)
        #expect(restored.first?.owner?.name == "UP 1")
        #expect(restored.first?.stat?.view == 5001)
        #expect(restored.first?.pic4By3 == "https://i0.hdslb.com/bfs/archive/1_43.jpg")
        #expect(restored.last?.id == 20)

        // Switching account invalidates the persisted snapshot and returns empty.
        let otherAccountReader = HomeFeedSnapshotStore(
            fileURL: tempURL,
            maxItemCount: HomeFeedSnapshotStore.defaultMaxItemCount,
            maxAge: 3600
        )
        #expect(
            otherAccountReader.load(
                forAccountScope: "mid-2002",
                now: baseTime.addingTimeInterval(300)
            ).isEmpty
        )
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))

        // Re-save and verify maxAge TTL expiry removes the stale disk snapshot.
        writerStore.save(items, forAccountScope: "guest", now: baseTime)
        writerStore.waitForPendingIO()
        let expiredReader = HomeFeedSnapshotStore(
            fileURL: tempURL,
            maxItemCount: HomeFeedSnapshotStore.defaultMaxItemCount,
            maxAge: 3600
        )
        #expect(
            expiredReader.load(
                forAccountScope: "guest",
                now: baseTime.addingTimeInterval(3601)
            ).isEmpty
        )
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    }

    @Test("RecommendationFeed.hydrated(from:) instantly populates a deduplicated generation and blocks duplicate appends")
    func recommendationFeedHydratedDeduplicatesAndPreventsDuplicates() async throws {
        let valid1 = Self.makeRecommendItem(id: 101, bvid: "BV1alpha", goto: "av")
        let duplicateID = Self.makeRecommendItem(id: 101, bvid: "BV1different", goto: "av")
        let duplicateBVID = Self.makeRecommendItem(id: 102, bvid: "BV1alpha", goto: "av")
        let nonVideo = Self.makeRecommendItem(id: 103, bvid: "BV1live", goto: "live")
        let missingOwner = Self.makeRecommendItem(id: 104, bvid: "BV1noowner", includeOwner: false)
        let blankBVID = Self.makeRecommendItem(id: 105, bvid: "   ", goto: nil)
        let valid2 = Self.makeRecommendItem(id: 106, bvid: "BV1beta", goto: nil)

        let feed = RecommendationFeed.hydrated(
            from: [valid1, duplicateID, duplicateBVID, nonVideo, missingOwner, blankBVID, valid2]
        )
        #expect(feed.generations.count == 1)
        #expect(feed.items.map(\.id) == [101, 106])
        #expect(feed.generations.first?.items.map(\.bvid) == ["BV1alpha", "BV1beta"])

        // Appending a page that overlaps hydrated items only adds genuinely new entries.
        let fresh = Self.makeRecommendItem(id: 107, bvid: "BV1gamma", goto: "av")
        let updated = try await feed.appendingPage([valid1, valid2, fresh])
        #expect(updated.items.map(\.id) == [101, 106, 107])
        #expect(updated.generations.count == 1)

        // Hydrating from empty or all-invalid input produces an empty feed.
        let emptyFeed = RecommendationFeed.hydrated(from: [nonVideo, missingOwner, blankBVID])
        #expect(emptyFeed.generations.isEmpty)
        #expect(emptyFeed.items.isEmpty)
    }
}

// MARK: - Stage 2: RollingTimeIntervalWindow

@Suite("Stage 2: RollingTimeIntervalWindow")
struct Stage2RollingTimeIntervalWindowTests {
    private static func median(of window: RollingTimeIntervalWindow) -> TimeInterval? {
        var samples: [TimeInterval] = []
        samples.reserveCapacity(window.count)
        window.appendPositiveFinite(into: &samples)
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    @Test("RollingTimeIntervalWindow wraps cleanly past 32 samples, computes median period, and resets")
    func ringWrapAroundMedianAndReset() {
        var window = RollingTimeIntervalWindow()
        #expect(window.count == 0)
        #expect(Self.median(of: window) == nil)

        // Fill initial 20 slow samples (1.0s), then overwrite past the 32-slot capacity with 32 fast samples (~60fps).
        for _ in 0..<20 {
            window.append(1.0)
        }
        #expect(window.count == 20)

        let period60fps: TimeInterval = 1.0 / 60.0
        for _ in 0..<32 {
            window.append(period60fps)
        }
        #expect(window.count == 32)

        var collected: [TimeInterval] = []
        window.appendPositiveFinite(into: &collected)
        #expect(collected.count == 32)
        #expect(collected.allSatisfy { abs($0 - period60fps) < 1e-12 })
        #expect(abs((Self.median(of: window) ?? 0) - period60fps) < 1e-12)

        // Non-positive and non-finite values are filtered out by appendPositiveFinite.
        window.removeAll()
        #expect(window.count == 0)
        #expect(Self.median(of: window) == nil)

        let mixedSamples: [TimeInterval] = [
            0, -0.02, .nan, .infinity, -.infinity,
            1.0 / 24.0, 1.0 / 30.0, 1.0 / 60.0, 1.0 / 30.0, 1.0 / 25.0,
        ]
        for sample in mixedSamples {
            window.append(sample)
        }
        #expect(window.count == mixedSamples.count)

        var validSamples: [TimeInterval] = []
        window.appendPositiveFinite(into: &validSamples)
        #expect(validSamples.count == 5)
        // Sorted valid samples: [1/60, 1/30, 1/30, 1/25, 1/24] -> index 2 is 1/30.
        #expect(abs((Self.median(of: window) ?? 0) - (1.0 / 30.0)) < 1e-12)

        // Verify removeAll reset writeIndex so a second >32 wrap overwrites oldest entries in exact FIFO order.
        window.removeAll()
        for index in 1...40 {
            window.append(TimeInterval(index))
        }
        #expect(window.count == 32)
        var secondWrap: [TimeInterval] = []
        window.appendPositiveFinite(into: &secondWrap)
        secondWrap.sort()
        #expect(secondWrap.first == 9.0)
        #expect(secondWrap.last == 40.0)
        #expect(secondWrap[secondWrap.count / 2] == 25.0)
    }
}

// MARK: - Stage 3: In-App Mini-Player Layout Policy & Routes

@Suite("Stage 3: In-App Mini-Player Layout & Routes")
struct Stage3MiniPlayerLayoutAndRouteTests {
    @Test("InAppMiniPlayerLayoutPolicy computes 16:9 and 9:16 dimensions for iPhone, iPad, and compact containers")
    func cardDimensionsForPhonePadAndCompactContainer() {
        let phoneContainer = CGSize(width: 402, height: 874)
        let padContainer = CGSize(width: 1024, height: 768)

        #expect(
            InAppMiniPlayerLayoutPolicy.cardSize(
                isPortrait: false,
                isPad: false,
                containerSize: phoneContainer
            ) == InAppMiniPlayerLayoutPolicy.phoneHorizontalSize
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.cardSize(
                isPortrait: true,
                isPad: false,
                containerSize: phoneContainer
            ) == InAppMiniPlayerLayoutPolicy.phonePortraitSize
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.cardSize(
                isPortrait: false,
                isPad: true,
                containerSize: padContainer
            ) == InAppMiniPlayerLayoutPolicy.padHorizontalSize
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.cardSize(
                isPortrait: true,
                isPad: true,
                containerSize: padContainer
            ) == InAppMiniPlayerLayoutPolicy.padPortraitSize
        )

        // Narrow Split View / Slide Over container scales down proportionally within 56% width & 42% height caps.
        let compactContainer = CGSize(width: 300, height: 400)
        let scaled = InAppMiniPlayerLayoutPolicy.cardSize(
            isPortrait: false,
            isPad: true,
            containerSize: compactContainer
        )
        #expect(scaled.width <= compactContainer.width * 0.56 + 1)
        #expect(scaled.height <= compactContainer.height * 0.42 + 1)
        #expect(scaled.width < InAppMiniPlayerLayoutPolicy.padHorizontalSize.width)
    }

    @Test("InAppMiniPlayerLayoutPolicy clamps all 4 edges at corners and intermediate progress with clearances")
    func fourEdgeContinuousAnchorClamping() {
        let container = CGSize(width: 393, height: 852)
        let cardSize = InAppMiniPlayerLayoutPolicy.phoneHorizontalSize
        let safeArea = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let topBar: CGFloat = 52
        let bottomBar: CGFloat = 68
        let margin: CGFloat = 12

        // MiniPlayerDockPosition clamps out-of-range and non-finite progress values.
        #expect(MiniPlayerDockPosition(edge: .top, progress: -0.4).progress == 0)
        #expect(MiniPlayerDockPosition(edge: .bottom, progress: 1.8).progress == 1)
        #expect(MiniPlayerDockPosition(edge: .leading, progress: .nan).progress == 1)

        let expectedMinX = margin + cardSize.width / 2
        let expectedMaxX = container.width - margin - cardSize.width / 2
        let expectedMinY = safeArea.top + topBar + cardSize.height / 2
        let expectedMaxY = container.height - safeArea.bottom - bottomBar - cardSize.height / 2
        let horizontalSpan = expectedMaxX - expectedMinX
        let verticalSpan = expectedMaxY - expectedMinY

        let bounds = InAppMiniPlayerLayoutPolicy.safeCenterBounds(
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(bounds.minX == expectedMinX)
        #expect(bounds.maxX == expectedMaxX)
        #expect(bounds.minY == expectedMinY)
        #expect(bounds.maxY == expectedMaxY)

        // Convenience corner presets map cleanly onto all 4 safe corners.
        let topLeading = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: .topLeading,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        let topTrailing = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: .topTrailing,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        let bottomLeading = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: .bottomLeading,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        let bottomTrailing = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: .bottomTrailing,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )

        #expect(topLeading == CGPoint(x: expectedMinX, y: expectedMinY))
        #expect(topTrailing == CGPoint(x: expectedMaxX, y: expectedMinY))
        #expect(bottomLeading == CGPoint(x: expectedMinX, y: expectedMaxY))
        #expect(bottomTrailing == CGPoint(x: expectedMaxX, y: expectedMaxY))

        // All 4 edges interpolate smoothly across intermediate progress values (0.3, 0.5, 0.75).
        for progress: CGFloat in [0.3, 0.5, 0.75] {
            let topPoint = InAppMiniPlayerLayoutPolicy.anchorCenter(
                for: MiniPlayerDockPosition(edge: .top, progress: progress),
                cardSize: cardSize,
                containerSize: container,
                safeArea: safeArea,
                topBarClearance: topBar,
                bottomBarClearance: bottomBar,
                horizontalMargin: margin
            )
            #expect(abs(topPoint.x - (expectedMinX + horizontalSpan * progress)) < 1e-6)
            #expect(topPoint.y == expectedMinY)

            let bottomPoint = InAppMiniPlayerLayoutPolicy.anchorCenter(
                for: MiniPlayerDockPosition(edge: .bottom, progress: progress),
                cardSize: cardSize,
                containerSize: container,
                safeArea: safeArea,
                topBarClearance: topBar,
                bottomBarClearance: bottomBar,
                horizontalMargin: margin
            )
            #expect(abs(bottomPoint.x - (expectedMinX + horizontalSpan * progress)) < 1e-6)
            #expect(bottomPoint.y == expectedMaxY)

            let leadingPoint = InAppMiniPlayerLayoutPolicy.anchorCenter(
                for: MiniPlayerDockPosition(edge: .leading, progress: progress),
                cardSize: cardSize,
                containerSize: container,
                safeArea: safeArea,
                topBarClearance: topBar,
                bottomBarClearance: bottomBar,
                horizontalMargin: margin
            )
            #expect(leadingPoint.x == expectedMinX)
            #expect(abs(leadingPoint.y - (expectedMinY + verticalSpan * progress)) < 1e-6)

            let trailingPoint = InAppMiniPlayerLayoutPolicy.anchorCenter(
                for: MiniPlayerDockPosition(edge: .trailing, progress: progress),
                cardSize: cardSize,
                containerSize: container,
                safeArea: safeArea,
                topBarClearance: topBar,
                bottomBarClearance: bottomBar,
                horizontalMargin: margin
            )
            #expect(trailingPoint.x == expectedMaxX)
            #expect(abs(trailingPoint.y - (expectedMinY + verticalSpan * progress)) < 1e-6)
        }

        // Higher bottom chrome clearance lifts bottom-docked anchors further above the tab bar / banner.
        let liftedBottom = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: MiniPlayerDockPosition(edge: .bottom, progress: 0.5),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: 120,
            horizontalMargin: margin
        )
        #expect(liftedBottom.y == expectedMaxY - (120 - bottomBar))

        // Higher top bar clearance lowers top-docked anchors below the navigation bar.
        let loweredTop = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: MiniPlayerDockPosition(edge: .top, progress: 0.5),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: 92,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(loweredTop.y == expectedMinY + (92 - topBar))

        // Landscape horizontal safe areas inset leading and trailing edges away from the Dynamic Island.
        let landscapeSafeArea = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
        let landscapeLeading = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: MiniPlayerDockPosition(edge: .leading, progress: 0.5),
            cardSize: cardSize,
            containerSize: CGSize(width: 852, height: 393),
            safeArea: landscapeSafeArea,
            topBarClearance: 16,
            bottomBarClearance: 20,
            horizontalMargin: margin
        )
        let landscapeTrailing = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: MiniPlayerDockPosition(edge: .trailing, progress: 0.5),
            cardSize: cardSize,
            containerSize: CGSize(width: 852, height: 393),
            safeArea: landscapeSafeArea,
            topBarClearance: 16,
            bottomBarClearance: 20,
            horizontalMargin: margin
        )
        #expect(landscapeLeading.x == 59 + margin + cardSize.width / 2)
        #expect(landscapeTrailing.x == 852 - 59 - margin - cardSize.width / 2)
    }

    @Test("InAppMiniPlayerLayoutPolicy snaps continuously to the nearest edge with damped momentum")
    func nearestEdgeContinuousSnapping() {
        let container = CGSize(width: 393, height: 852)
        let cardSize = InAppMiniPlayerLayoutPolicy.phoneHorizontalSize
        let safeArea = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let topBar: CGFloat = 52
        let bottomBar: CGFloat = 68
        let margin: CGFloat = 12

        let bounds = InAppMiniPlayerLayoutPolicy.safeCenterBounds(
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        let midX = (bounds.minX + bounds.maxX) / 2
        let midY = (bounds.minY + bounds.maxY) / 2
        let bottomTrailingAnchor = InAppMiniPlayerLayoutPolicy.anchorCenter(
            for: .bottomTrailing,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )

        // Top-center drop stays centered on .top.
        let topCenterTranslation = CGSize(
            width: midX - bottomTrailingAnchor.x,
            height: (bounds.minY + 12) - bottomTrailingAnchor.y
        )
        let snapTopCenter = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: bottomTrailingAnchor,
            translation: topCenterTranslation,
            predictedEndTranslation: topCenterTranslation,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = snapTopCenter {
            #expect(dock.edge == .top)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected .snap(.top, progress ~0.5), got \(snapTopCenter)")
        }

        // Bottom-center drop stays centered on .bottom.
        let bottomCenterTranslation = CGSize(
            width: midX - bottomTrailingAnchor.x,
            height: (bounds.maxY - 12) - bottomTrailingAnchor.y
        )
        let snapBottomCenter = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: bottomTrailingAnchor,
            translation: bottomCenterTranslation,
            predictedEndTranslation: bottomCenterTranslation,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = snapBottomCenter {
            #expect(dock.edge == .bottom)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected .snap(.bottom, progress ~0.5), got \(snapBottomCenter)")
        }

        // Mid-left drop stays at mid-Y on .leading.
        let midLeftTranslation = CGSize(
            width: (bounds.minX + 14) - bottomTrailingAnchor.x,
            height: midY - bottomTrailingAnchor.y
        )
        let snapMidLeft = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: bottomTrailingAnchor,
            translation: midLeftTranslation,
            predictedEndTranslation: midLeftTranslation,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = snapMidLeft {
            #expect(dock.edge == .leading)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected .snap(.leading, progress ~0.5), got \(snapMidLeft)")
        }

        // Mid-right drop stays at mid-Y on .trailing.
        let midRightTranslation = CGSize(
            width: (bounds.maxX - 14) - bottomTrailingAnchor.x,
            height: midY - bottomTrailingAnchor.y
        )
        let snapMidRight = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: bottomTrailingAnchor,
            translation: midRightTranslation,
            predictedEndTranslation: midRightTranslation,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = snapMidRight {
            #expect(dock.edge == .trailing)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected .snap(.trailing, progress ~0.5), got \(snapMidRight)")
        }

        // Cross-screen flick right-to-left starting inside [minX, maxX] snaps to .leading without dismissing.
        let midTrailingAnchor = CGPoint(x: bounds.maxX, y: midY)
        let crossLeftFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midTrailingAnchor,
            translation: CGSize(width: -110, height: 0),
            predictedEndTranslation: CGSize(width: -360, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = crossLeftFlick {
            #expect(dock.edge == .leading)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected cross-screen flick to snap to .leading without dismissing, got \(crossLeftFlick)")
        }

        // Cross-screen flick left-to-right starting inside [minX, maxX] snaps to .trailing without dismissing.
        let midLeadingAnchor = CGPoint(x: bounds.minX, y: midY)
        let crossRightFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: 110, height: 0),
            predictedEndTranslation: CGSize(width: 360, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = crossRightFlick {
            #expect(dock.edge == .trailing)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected cross-screen flick to snap to .trailing without dismissing, got \(crossRightFlick)")
        }

        // Momentum damping caps extreme vertical flick velocity (<= 150pt) so docking stays composed.
        let dampedUpwardFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midTrailingAnchor,
            translation: CGSize(width: 0, height: -40),
            predictedEndTranslation: CGSize(width: 0, height: -900),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = dampedUpwardFlick {
            let expectedProgress = (midY - 40 - 150 - bounds.minY) / bounds.verticalSpan
            #expect(dock.edge == .trailing)
            #expect(abs(dock.progress - expectedProgress) < 0.01)
        } else {
            Issue.record("Expected damped upward flick to stay on .trailing, got \(dampedUpwardFlick)")
        }

        // Zero-distance release at .bottomTrailing preserves .bottomTrailing cleanly.
        let stayOrigin = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: bottomTrailingAnchor,
            translation: .zero,
            predictedEndTranslation: .zero,
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(stayOrigin == .snap(.bottomTrailing))

        // Degenerate zero-span container defaults progress to 1 without NaN.
        let zeroSpanAction = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: CGPoint(x: bounds.minX, y: bounds.minY),
            translation: CGSize(width: 0, height: -20),
            predictedEndTranslation: CGSize(width: 0, height: -20),
            cardSize: cardSize,
            containerSize: CGSize(width: 220, height: 852),
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(zeroSpanAction == .snap(MiniPlayerDockPosition(edge: .top, progress: 1)))
    }

    @Test("InAppMiniPlayerLayoutPolicy enforces high swipe-to-dismiss thresholds without hurting edge docking")
    func highThresholdSwipeToDismissAndProgress() {
        let container = CGSize(width: 393, height: 852)
        let cardSize = InAppMiniPlayerLayoutPolicy.phoneHorizontalSize
        let safeArea = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let topBar: CGFloat = 52
        let bottomBar: CGFloat = 68
        let margin: CGFloat = 12

        let bounds = InAppMiniPlayerLayoutPolicy.safeCenterBounds(
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        let midY = (bounds.minY + bounds.maxY) / 2
        let midLeadingAnchor = CGPoint(x: bounds.minX, y: midY)
        let midTrailingAnchor = CGPoint(x: bounds.maxX, y: midY)

        // dismissProgress is 0 across interior, safe dock edges (minX/maxX), and flush screen edges.
        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: container.width / 2,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 0
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: bounds.minX,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 0
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: bounds.maxX,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 0
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: cardSize.width / 2,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 0
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: container.width - cardSize.width / 2,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 0
        )

        // Ramps only once >20% of card width crosses outside the screen, clamping to 1.0 past the edge.
        let leadingEdgeProgress = InAppMiniPlayerLayoutPolicy.dismissProgress(
            currentCenterX: 45,
            cardWidth: cardSize.width,
            containerWidth: container.width
        )
        #expect(leadingEdgeProgress > 0 && leadingEdgeProgress < 1)

        let trailingEdgeProgress = InAppMiniPlayerLayoutPolicy.dismissProgress(
            currentCenterX: container.width - 45,
            cardWidth: cardSize.width,
            containerWidth: container.width
        )
        #expect(trailingEdgeProgress > 0 && trailingEdgeProgress < 1)

        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: -cardSize.width * 0.25,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 1
        )
        #expect(
            InAppMiniPlayerLayoutPolicy.dismissProgress(
                currentCenterX: container.width + cardSize.width * 0.25,
                cardWidth: cardSize.width,
                containerWidth: container.width
            ) == 1
        )

        // Slow drag to near left screen edge (x = 45) snaps cleanly to .leading instead of dismissing.
        let nearLeftSlowDrag = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: 45 - midLeadingAnchor.x, height: 0),
            predictedEndTranslation: CGSize(width: 45 - midLeadingAnchor.x, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = nearLeftSlowDrag {
            #expect(dock.edge == .leading)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected slow drag near x=45 to snap to .leading, got \(nearLeftSlowDrag)")
        }

        // Slow drag to near right screen edge (x = container.width - 45) snaps cleanly to .trailing.
        let nearRightSlowDrag = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midTrailingAnchor,
            translation: CGSize(width: (container.width - 45) - midTrailingAnchor.x, height: 0),
            predictedEndTranslation: CGSize(width: (container.width - 45) - midTrailingAnchor.x, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = nearRightSlowDrag {
            #expect(dock.edge == .trailing)
            #expect(abs(dock.progress - 0.5) < 0.01)
        } else {
            Issue.record("Expected slow drag near right edge to snap to .trailing, got \(nearRightSlowDrag)")
        }

        // Dragging >58% off-screen (x = -25) dismisses .leading.
        let slowLeadingDismiss = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: -25 - midLeadingAnchor.x, height: 0),
            predictedEndTranslation: CGSize(width: -30 - midLeadingAnchor.x, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(slowLeadingDismiss == .dismiss(.leading))

        // Dragging >58% off-screen (x = container.width + 25) dismisses .trailing.
        let slowTrailingDismiss = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midTrailingAnchor,
            translation: CGSize(width: (container.width + 25) - midTrailingAnchor.x, height: 0),
            predictedEndTranslation: CGSize(width: (container.width + 30) - midTrailingAnchor.x, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(slowTrailingDismiss == .dismiss(.trailing))

        // Strong outward horizontal flick past leading outer dock margin dismisses .leading.
        let fastLeadingFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: -35, height: 4),
            predictedEndTranslation: CGSize(width: -235, height: 14),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(fastLeadingFlick == .dismiss(.leading))

        // Strong outward horizontal flick past trailing outer dock margin dismisses .trailing.
        let fastTrailingFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midTrailingAnchor,
            translation: CGSize(width: 35, height: -4),
            predictedEndTranslation: CGSize(width: 235, height: -14),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        #expect(fastTrailingFlick == .dismiss(.trailing))

        // Moderate outward velocity (<150pt) or non-horizontal diagonal flick past margin snaps instead of dismissing.
        let weakLeadingFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: -35, height: 0),
            predictedEndTranslation: CGSize(width: -135, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = weakLeadingFlick {
            #expect(dock.edge == .leading)
        } else {
            Issue.record("Expected weak flick to snap instead of dismiss, got \(weakLeadingFlick)")
        }

        let diagonalLeadingFlick = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: -35, height: -20),
            predictedEndTranslation: CGSize(width: -215, height: -200),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap = diagonalLeadingFlick {
            // Expected snap (not horizontal-dominant)
        } else {
            Issue.record("Expected diagonal flick to snap instead of dismiss, got \(diagonalLeadingFlick)")
        }

        // Pull-back toward center cancels slow drag-off dismiss on both leading and trailing sides.
        let leadingPullBack = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midLeadingAnchor,
            translation: CGSize(width: -25 - midLeadingAnchor.x, height: 0),
            predictedEndTranslation: CGSize(width: 20 - midLeadingAnchor.x, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = leadingPullBack {
            #expect(dock.edge == .leading)
        } else {
            Issue.record("Expected pull-back from leading edge to cancel dismiss, got \(leadingPullBack)")
        }

        let trailingPullBack = InAppMiniPlayerLayoutPolicy.resolveRelease(
            anchorCenter: midTrailingAnchor,
            translation: CGSize(width: (container.width + 25) - midTrailingAnchor.x, height: 0),
            predictedEndTranslation: CGSize(width: (container.width - 20) - midTrailingAnchor.x, height: 0),
            cardSize: cardSize,
            containerSize: container,
            safeArea: safeArea,
            topBarClearance: topBar,
            bottomBarClearance: bottomBar,
            horizontalMargin: margin
        )
        if case .snap(let dock) = trailingPullBack {
            #expect(dock.edge == .trailing)
        } else {
            Issue.record("Expected pull-back from trailing edge to cancel dismiss, got \(trailingPullBack)")
        }
    }

    @Test("Route.withoutZoom and Route.fallback strip zoom sources while preserving route identity")
    func routeWithoutZoomAndFallback() throws {
        let zoomUUID = UUID()
        let zoom = RouteZoomSource(id: zoomUUID)
        let preview = PortraitPagingPreview(title: "Test Video")
        let videoTarget = VideoRouteTarget(
            videoID: .bvid("BV1zoom00001"),
            preview: preview,
            zoomSourceID: zoomUUID
        )

        if case .videoDetail(let stripped) = Route.videoDetail(videoTarget).withoutZoom {
            #expect(stripped.videoID == .bvid("BV1zoom00001"))
            #expect(stripped.preview == preview)
            #expect(stripped.zoomSourceID == nil)
        } else {
            Issue.record("Expected .videoDetail after withoutZoom")
        }

        if case .liveRoom(let roomID, let strippedZoom) = Route.liveRoom(777, zoom: zoom).withoutZoom {
            #expect(roomID == 777)
            #expect(strippedZoom.id == nil)
        } else {
            Issue.record("Expected .liveRoom after withoutZoom")
        }

        if case .bangumiDetail(let seasonID, let strippedZoom) = Route.bangumiDetail(34430, zoom: zoom).withoutZoom {
            #expect(seasonID == 34430)
            #expect(strippedZoom.id == nil)
        } else {
            Issue.record("Expected .bangumiDetail after withoutZoom")
        }

        if case .offlinePlayer(let id, let strippedZoom) = Route.offlinePlayer("dl-1", zoom: zoom).withoutZoom {
            #expect(id == "dl-1")
            #expect(strippedZoom.id == nil)
        } else {
            Issue.record("Expected .offlinePlayer after withoutZoom")
        }

        let multiContext = try #require(OfflinePortraitPagingContext(
            items: [
                .init(downloadID: "dl-1", preview: .init(title: "First")),
                .init(downloadID: "dl-2", preview: .init(title: "Second")),
            ],
            selectedID: "dl-2"
        ))
        if case .offlinePager(let ctx, let strippedZoom) = Route.offlinePager(multiContext, zoom: zoom).withoutZoom {
            #expect(ctx == multiContext)
            #expect(strippedZoom.id == nil)
        } else {
            Issue.record("Expected .offlinePager after withoutZoom")
        }

        // Non-player routes pass through unchanged.
        #expect(Route.userSpace(42).withoutZoom == .userSpace(42))

        // Route.fallback maps every PlayerScreenRoute variant to a clean zoom-free Route.
        #expect(Route.fallback(for: .video(.aid(55))) == .videoDetail(.aid(55)))
        #expect(Route.fallback(for: .bangumi(88)) == .bangumiDetail(88, zoom: .none))
        #expect(Route.fallback(for: .live(99)) == .liveRoom(99, zoom: .none))
        #expect(Route.fallback(for: .offline(.single("dl-1"))) == .offlinePlayer("dl-1", zoom: .none))
        #expect(Route.fallback(for: .offline(multiContext)) == .offlinePager(multiContext, zoom: .none))
    }
}

// MARK: - Stage 3: Mini-Player Navigation & State Machine

@MainActor
private final class RecordingMiniPlayerNavigationHook: NavigationPlaybackHook {
    struct Transition: Equatable {
        let from: PlayerRouteDestination?
        let to: PlayerRouteDestination?
        let departingRoute: Route?
    }

    var transitions: [Transition] = []

    func playerRouteWillChange(from old: PlayerRouteDestination?, to new: PlayerRouteDestination?) {
        transitions.append(Transition(from: old, to: new, departingRoute: nil))
    }

    func playerRouteWillChange(
        from old: PlayerRouteDestination?,
        to new: PlayerRouteDestination?,
        departingRoute: Route?
    ) {
        transitions.append(Transition(from: old, to: new, departingRoute: departingRoute))
    }

    @discardableResult
    func parkOutgoingRouteStill() -> String? { nil }
    func retireDepartedRouteStill(owner _: String) {}
    func endCurrentOwnerPlayback() {}
    func clearAllOutgoingRouteStills() {}
}

@Suite("Stage 3: Mini-Player Navigation & State Machine", .serialized)
@MainActor
struct Stage3MiniPlayerNavigationAndStateTests {
    @Test("PlayerPlaybackPreferences.inAppMiniPlayerEnabled defaults to true and persists updates")
    func miniPlayerPreferenceDefaultAndPersistence() {
        let key = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(PlayerPlaybackPreferences.inAppMiniPlayerEnabled == true)

        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = false
        #expect(PlayerPlaybackPreferences.inAppMiniPlayerEnabled == false)

        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = true
        #expect(PlayerPlaybackPreferences.inAppMiniPlayerEnabled == true)
    }

    @Test("InAppMiniPlayerState tracks active session, return handoff lease retention, and cleanup")
    func miniPlayerStateLeaseRetentionLifecycle() {
        let state = InAppMiniPlayerState()
        let lease1 = PlayerOwnerLease(owner: "vod-detail-old", generation: 1)
        let lease2 = PlayerOwnerLease(owner: "vod-detail-new", generation: 2)
        let session = InAppMiniPlayerSession(
            originRoute: .videoDetail(.aid(77)),
            originScreenRoute: .video(.aid(77)),
            originPosition: PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 0),
            ownerLease: lease1,
            title: "Sample",
            coverURL: nil,
            mode: .vod,
            isPortrait: false
        )

        #expect(!state.isActive)
        #expect(!state.retainsOwnerLease(lease1))
        #expect(state.dockPosition == .bottomTrailing)
        state.dockPosition = MiniPlayerDockPosition(edge: .top, progress: 0.5)
        #expect(state.dockPosition == MiniPlayerDockPosition(edge: .top, progress: 0.5))

        state.activate(session)
        #expect(state.isActive)
        #expect(state.retainsOwnerLease(lease1))
        #expect(!state.retainsOwnerLease(lease2))

        // Moving to return handoff clears activeSession but retains previousOwnerLease until adopted.
        let handoff = MiniPlayerReturnHandoff(
            originScreenRoute: .video(.aid(77)),
            previousOwnerLease: lease1,
            adoptedOwnerLease: nil,
            mode: .vod,
            aid: 77,
            cid: 7701,
            source: .ugc,
            roomID: nil,
            offlineAsset: nil
        )
        state.transitionToReturnHandoff(handoff)
        #expect(!state.isActive)
        #expect(state.retainsOwnerLease(lease1))

        // Adopting the handoff releases retention on the old lease so teardown of the old view does not linger.
        state.markReturnHandoffAdopted(by: lease2)
        #expect(state.returnHandoff?.adoptedOwnerLease == lease2)
        #expect(!state.retainsOwnerLease(lease1))

        state.clearAll()
        #expect(!state.isActive)
        #expect(state.returnHandoff == nil)
    }

    @Test("AppCoordinator.restoreFromMiniPlayer restores popped routes without zoom, pops stacked routes, and switches tabs/sidebar")
    func coordinatorRestoreFromMiniPlayerAllPaths() {
        let hook = RecordingMiniPlayerNavigationHook()
        let coordinator = AppCoordinator(playbackHookProvider: { hook })
        let lease = PlayerOwnerLease(owner: "vod-detail-1", generation: 1)

        // 1) Popped route -> restores by pushing originRoute.withoutZoom onto current tab.
        let zoomID = UUID()
        let zoomedTarget = VideoRouteTarget(
            videoID: .bvid("BV1pop00001"),
            preview: .init(title: "Popped Video"),
            zoomSourceID: zoomID
        )
        #expect(coordinator.navigateToVideo(zoomedTarget))
        coordinator.settleVideoNavigation(zoomedTarget.videoID)
        let originPosition = coordinator.playerRoutePosition(for: .videoDetail(zoomedTarget))

        hook.transitions.removeAll()
        coordinator.goBack()
        #expect(coordinator.stack(for: .home).isEmpty)
        #expect(hook.transitions.count == 1)
        #expect(hook.transitions.first?.departingRoute == .videoDetail(zoomedTarget))

        let poppedSession = InAppMiniPlayerSession(
            originRoute: .videoDetail(zoomedTarget),
            originScreenRoute: .video(zoomedTarget.videoID),
            originPosition: originPosition,
            ownerLease: lease,
            title: "Popped Video",
            coverURL: nil,
            mode: .vod,
            isPortrait: false
        )
        coordinator.restoreFromMiniPlayer(poppedSession)
        #expect(coordinator.stack(for: .home).count == 1)
        if case .videoDetail(let restoredTarget)? = coordinator.stack(for: .home).last {
            #expect(restoredTarget.videoID == zoomedTarget.videoID)
            #expect(restoredTarget.zoomSourceID == nil)
        } else {
            Issue.record("Expected restored .videoDetail on .home stack")
        }
        coordinator.settleVideoNavigation(zoomedTarget.videoID)

        // 2) Stacked route -> pushing non-player routes on top of player, restore pops back to existing player route.
        coordinator.navigate(to: .userSpace(123))
        coordinator.navigate(to: .favorites)
        #expect(coordinator.stack(for: .home).count == 3)
        coordinator.restoreFromMiniPlayer(poppedSession)
        #expect(coordinator.stack(for: .home) == [.videoDetail(zoomedTarget)])
        #expect(coordinator.isActivePlayerRoute(.video(zoomedTarget.videoID)))

        // 3) Tab switch -> live room on .live, user switches to .home, restore switches back to .live without duplicating.
        coordinator.selectedTab = .live
        coordinator.navigate(to: .liveRoom(8888, zoom: RouteZoomSource(id: UUID())))
        let livePos = coordinator.playerRoutePosition(for: .liveRoom(8888))
        let liveSession = InAppMiniPlayerSession(
            originRoute: .liveRoom(8888, zoom: .none),
            originScreenRoute: .live(8888),
            originPosition: livePos,
            ownerLease: PlayerOwnerLease(owner: "live-8888", generation: 2),
            title: "Live Room",
            coverURL: nil,
            mode: .live,
            isPortrait: false
        )
        coordinator.selectedTab = .home
        #expect(coordinator.selectedTab == .home)
        coordinator.restoreFromMiniPlayer(liveSession)
        #expect(coordinator.selectedTab == .live)
        #expect(coordinator.stack(for: .live) == [.liveRoom(8888)])

        // 4) Sidebar row switch -> player inside sidebar row, user navigates to .home, restore returns to sidebar row.
        let favoritesRow = SidebarDestination.myContent[0]
        coordinator.selectedTab = .mine
        coordinator.selectedSidebarRow = favoritesRow
        let sidebarVideo = VideoRouteTarget(videoID: .aid(404))
        #expect(coordinator.navigateToVideo(sidebarVideo))
        coordinator.settleVideoNavigation(sidebarVideo.videoID)
        let sidebarPos = coordinator.playerRoutePosition(for: .videoDetail(sidebarVideo))
        let sidebarSession = InAppMiniPlayerSession(
            originRoute: .videoDetail(sidebarVideo),
            originScreenRoute: .video(.aid(404)),
            originPosition: sidebarPos,
            ownerLease: PlayerOwnerLease(owner: "vod-detail-sidebar", generation: 3),
            title: "Sidebar Video",
            coverURL: nil,
            mode: .vod,
            isPortrait: false
        )
        coordinator.selectedSidebarRow = nil
        coordinator.selectedTab = .home
        coordinator.restoreFromMiniPlayer(sidebarSession)
        #expect(coordinator.selectedSidebarRow == favoritesRow)
        #expect(coordinator.selectedTab == favoritesRow.parentTab)
        #expect(coordinator.sidebarRowStack(for: favoritesRow) == [.videoDetail(sidebarVideo)])
    }

    @Test("PlayerViewModel activates mini-player on route pop, hands off surface, restores seamlessly, and dismisses cleanly")
    func playerViewModelMiniPlayerEndToEndStateMachine() {
        let vm = PlayerViewModel.shared
        let key = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let originalPref = UserDefaults.standard.object(forKey: key)

        let cleanup = {
            vm.miniPlayer.clearAll()
            vm.miniPlayer.dockPosition = .bottomTrailing
            vm.error = nil
            vm.unavailability = nil
            vm.terminalOpenFailure = false
            vm.stop(reason: .ownerExit)
            vm.ownerKey = ""
            vm.activeSceneID = nil
            vm.clearAllOutgoingRouteStills()
            if let originalPref {
                UserDefaults.standard.set(originalPref, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        cleanup()
        defer { cleanup() }

        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = true
        let coordinator = AppCoordinator(playbackHookProvider: { vm })

        let target = VideoRouteTarget(
            videoID: .aid(9001),
            preview: .init(title: "Mini-Player Demo"),
            zoomSourceID: UUID()
        )
        #expect(coordinator.navigateToVideo(target))
        coordinator.settleVideoNavigation(target.videoID)

        // Simulate an active playing VOD session owned by the initial detail view.
        let initialOwner = "vod-detail-\(UUID().uuidString)"
        let initialLease = vm.claimOwnerLease(owner: initialOwner)
        let inlineSurface = vm.claimSurfaceSlot(ownerLease: initialLease, role: .inline)
        #expect(inlineSurface?.role == .inline)

        vm.mode = .vod
        vm.currentAid = 9001
        vm.currentCid = 900101
        vm.currentSource = .ugc
        vm.currentURL = URL(string: "https://example.com/video.m4s")
        vm.playbackIntent = .playing
        vm.isPlaying = true
        vm.markFirstVideoFrameRendered()

        // Popping the detail route activates mini-player and hands surface off to .miniPlayer without pausing/stopping.
        coordinator.goBack()
        #expect(coordinator.stack(for: .home).isEmpty)
        #expect(vm.isMiniPlayerActive)
        let session = vm.miniPlayer.activeSession
        #expect(session?.ownerLease == initialLease)
        #expect(session?.originScreenRoute == .video(.aid(9001)))
        #expect(vm.activeSurfaceLease?.role == .miniPlayer)
        #expect(vm.activeSurfaceLease?.ownerLease == initialLease)

        // Departing detail view's onChange/onDisappear hooks preserve playback while mini-player owns the lease.
        #expect(!vm.pauseForRouteDeparture(lease: initialLease))
        #expect(vm.playbackIntent == .playing)
        #expect(vm.endOwnerPlayback(lease: initialLease) == .leaseRetained)
        #expect(vm.isCurrentOwner(initialLease))

        // Restoring from mini-player pushes zoom-free route, prepares return handoff, and hands surface back to .inline.
        if let session {
            coordinator.restoreFromMiniPlayer(session)
        }
        #expect(!vm.isMiniPlayerActive)
        #expect(vm.miniPlayer.returnHandoff?.previousOwnerLease == initialLease)
        #expect(vm.activeSurfaceLease?.role == .inline)

        // Newly mounted detail view claims a fresh UUID owner lease and seamlessly adopts the live VOD session.
        let returningOwner = "vod-detail-\(UUID().uuidString)"
        vm.endForeignOwnerForRouteActivation(incomingOwner: returningOwner)
        #expect(vm.isCurrentOwner(initialLease))
        let adoptedLease = vm.claimOwnerLease(owner: returningOwner)
        #expect(vm.hasRenderedFirstFrame)
        #expect(vm.miniPlayer.returnHandoff?.adoptedOwnerLease == adoptedLease)
        #expect(
            vm.consumeMiniPlayerReturnIfLiveVOD(
                aid: 9001,
                cid: 900101,
                bvid: nil,
                source: .ugc,
                quality: nil,
                ownerLease: adoptedLease,
                startupTraceToken: nil,
                mediaResetID: nil,
                recoveryCoverIdentity: nil,
                cdnSwitchID: nil,
                streamRetryID: nil
            )
        )
        #expect(vm.miniPlayer.returnHandoff == nil)
        coordinator.settleVideoNavigation(target.videoID)

        // Pop again into mini-player, then verify stale-lease dismiss is ignored and matching dismiss stops cleanly.
        coordinator.goBack()
        #expect(vm.isMiniPlayerActive)
        let staleLease = PlayerOwnerLease(owner: returningOwner, generation: adoptedLease.generation + 99)
        vm.dismissMiniPlayer(matching: staleLease)
        #expect(vm.isMiniPlayerActive)

        vm.dismissMiniPlayer(matching: adoptedLease)
        #expect(!vm.isMiniPlayerActive)
        #expect(vm.ownerKey.isEmpty)

        // When preference is disabled, popping a playing route does not activate mini-player.
        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = false
        #expect(coordinator.navigateToVideo(target))
        coordinator.settleVideoNavigation(target.videoID)
        let disabledLease = vm.claimOwnerLease(owner: "vod-detail-\(UUID().uuidString)")
        vm.currentURL = URL(string: "https://example.com/video.m4s")
        vm.playbackIntent = .playing
        coordinator.goBack()
        #expect(!vm.isMiniPlayerActive)
        #expect(!vm.miniPlayer.retainsOwnerLease(disabledLease))
    }

    @Test("Natural playback end dismisses active mini-player, blocks re-entry on route pop, and keeps controls visible")
    func playbackEndedDismissesMiniPlayerAndBlocksReEntry() {
        let vm = PlayerViewModel.shared
        let key = PlayerPlaybackPreferences.inAppMiniPlayerDefaultsKey
        let originalPref = UserDefaults.standard.object(forKey: key)
        let originalOrder = vm.playbackOrder

        let cleanup = {
            vm.miniPlayer.clearAll()
            vm.miniPlayer.dockPosition = .bottomTrailing
            vm.error = nil
            vm.unavailability = nil
            vm.terminalOpenFailure = false
            vm.playbackOrder = originalOrder
            vm.stop(reason: .ownerExit)
            vm.ownerKey = ""
            vm.activeSceneID = nil
            vm.clearAllOutgoingRouteStills()
            if let originalPref {
                UserDefaults.standard.set(originalPref, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        cleanup()
        defer { cleanup() }

        PlayerPlaybackPreferences.inAppMiniPlayerEnabled = true
        vm.playbackOrder = .pauseAtEnd
        let coordinator = AppCoordinator(playbackHookProvider: { vm })

        let target = VideoRouteTarget(
            videoID: .aid(9002),
            preview: .init(title: "Ended Mini-Player Demo"),
            zoomSourceID: UUID()
        )
        #expect(coordinator.navigateToVideo(target))
        coordinator.settleVideoNavigation(target.videoID)

        let miniLease = vm.claimOwnerLease(owner: "vod-detail-\(UUID().uuidString)")
        _ = vm.claimSurfaceSlot(ownerLease: miniLease, role: .inline)
        vm.mode = .vod
        vm.currentAid = 9002
        vm.currentCid = 900201
        vm.currentSource = .ugc
        vm.currentURL = URL(string: "https://example.com/ended-demo.m4s")
        vm.duration = 72
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing
        vm.isPlaying = true

        // Enter mini-player while playing, then naturally reach playback end.
        coordinator.goBack()
        #expect(vm.isMiniPlayerActive)
        vm.admitNaturalPlaybackEnd()
        vm.settleTerminalPlaybackEndPresentation()
        #expect(!vm.isMiniPlayerActive)
        #expect(vm.ownerKey.isEmpty)

        // Start another session on detail page, reach natural playback end, then pop route.
        #expect(coordinator.navigateToVideo(target))
        coordinator.settleVideoNavigation(target.videoID)
        let endedLease = vm.claimOwnerLease(owner: "vod-detail-\(UUID().uuidString)")
        _ = vm.claimSurfaceSlot(ownerLease: endedLease, role: .inline)
        vm.mode = .vod
        vm.currentAid = 9002
        vm.currentCid = 900201
        vm.currentSource = .ugc
        vm.currentURL = URL(string: "https://example.com/ended-demo.m4s")
        vm.duration = 72
        vm.playbackTerminalState = .active
        vm.playbackIntent = .playing
        vm.isPlaying = true
        vm.showControls = false

        vm.admitNaturalPlaybackEnd()
        vm.settleTerminalPlaybackEndPresentation()
        #expect(vm.playbackEnded)
        #expect(vm.showControls)
        #expect(!vm.canEnterMiniPlayer(for: endedLease))

        coordinator.goBack()
        #expect(!vm.isMiniPlayerActive)
        #expect(!vm.miniPlayer.retainsOwnerLease(endedLease))
    }
}

// MARK: - Detail-to-Detail Transition Optimizations

@MainActor
private final class MockTransitionStillBackend: PlayerBackend {
    var captureSourceHandler: (@MainActor () -> DisplayedFrameCaptureSource?)?
    var fallbackFrameHandler: (@MainActor () -> UIImage?)?
    var captureSourceCallCount = 0
    var fallbackFrameCallCount = 0

    var hasParkedSession = false
    var isReadyToPlay = true
    var isPlaying = true
    var retainedPipelineHealth = RetainedPipelineHealth(backendGeneration: 1, state: .playingWithProducer)
    var runtimeGeneration: UInt64 = 1
    var pendingSeekTarget: TimeInterval?
    var openedAtPosition: TimeInterval = 0
    var currentTime: TimeInterval = 12
    var duration: TimeInterval = 120
    var playableTime: TimeInterval = 40
    var bufferedContentAhead: TimeInterval? = 28
    var bufferedPipelineAhead: TimeInterval? = 28
    var videoDeliveryRunway: TimeInterval? = 28
    var seekLaunchReserve: TimeInterval = 2
    var playbackRate: Float = 1.0
    var volume: Float = 1.0
    var isMuted = false
    var renderViewController: UIViewController?
    var isPiPActive = false
    var dynamicInfo: PlayerDynamicStats?
    var onStateChanged: (@MainActor @Sendable (PlayerStateEvent) -> Void)?
    var onTickWithGeneration: (@MainActor @Sendable (TimeInterval, TimeInterval, UInt64, StartupTrace.Token?) -> Void)?
    var onBufferChanged: (@MainActor @Sendable (TimeInterval) -> Void)?

    func load(
        url _: URL, audioURL _: URL?, headers _: [String: String],
        startPosition _: TimeInterval, playbackRate _: Float, hardwareDecode _: Bool,
        networkCaching _: TimeInterval, maxBuffer _: TimeInterval,
        preferNativeVideoToolbox _: Bool, alternateVideoURLs _: [URL],
        alternateAudioURLs _: [URL], readAheadSeconds _: TimeInterval?,
        multiConnectionPolicy _: MultiConnectionPolicy?, liveSource _: DemandLiveSource?
    ) {}

    func refreshMultiConnectionTelemetry() {}
    func setMultiConnectionQuiet(_: MultiConnectionQuiet) {}
    func stop() {}
    func parkForReuse() -> Bool { false }
    func setStartupTraceToken(_: StartupTrace.Token?) {}
    func play() {}
    func pause() {}
    func seek(to _: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?) { completion?(true) }
    func confirmRetainedLiveness(within _: TimeInterval) async -> Bool { true }
    func setScaleMode(_: VideoScaleMode) {}
    func startPiP() {}
    func stopPiP() {}
    func videoTracks() -> [PlayerTrackInfo] { [] }
    func thumbnailAtCurrentTime() async -> UIImage? { nil }
    func invalidateFrameStats() {}

    func currentDisplayedFrameCaptureSource() -> DisplayedFrameCaptureSource? {
        captureSourceCallCount += 1
        return captureSourceHandler?()
    }

    func currentDisplayedFrameForTransition() -> UIImage? {
        fallbackFrameCallCount += 1
        return fallbackFrameHandler?()
    }
}

@Suite("Detail-to-Detail Transition Optimizations", .serialized)
@MainActor
struct DetailToDetailTransitionOptimizationTests {
    private static func makeSyntheticPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            memset(baseAddress, 0x80, bytesPerRow * height)
        }
        return buffer
    }

    private static func makeSyntheticFallbackImage(width: Int = 120, height: Int = 68) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func waitUntil(
        timeoutMilliseconds: Int = 3000,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("Off-main parkOutgoingRouteStill returns owner synchronously and populates downscaled still asynchronously")
    func offMainParkOutgoingRouteStillAsyncPopulateAndDownscale() async throws {
        let vm = PlayerViewModel.shared
        let savedBackend = vm.activeBackend
        let savedOwner = vm.ownerKey
        let mockBackend = MockTransitionStillBackend()
        let pixelBuffer = try Self.makeSyntheticPixelBuffer(width: 1280, height: 720)
        mockBackend.captureSourceHandler = {
            DisplayedFrameCaptureSource(pixelBuffer: pixelBuffer, displayScale: 2)
        }
        mockBackend.fallbackFrameHandler = {
            Self.makeSyntheticFallbackImage()
        }

        vm.clearAllOutgoingRouteStills()
        vm.activeBackend = mockBackend
        let owner = "vod-detail-async-\(UUID().uuidString)"
        vm.ownerKey = owner
        defer {
            vm.clearAllOutgoingRouteStills()
            vm.activeBackend = savedBackend
            vm.ownerKey = savedOwner
        }

        let parkedOwner = vm.parkOutgoingRouteStill()
        #expect(parkedOwner == owner)
        #expect(mockBackend.captureSourceCallCount == 1)
        #expect(mockBackend.fallbackFrameCallCount == 0)
        // Must NOT synchronously rasterize on MainActor.
        #expect(vm.outgoingRouteStill(for: owner) == nil)
        #expect(vm.routeOwnership.outgoingRouteStillTasks[owner] != nil)

        let populated = await Self.waitUntil {
            vm.outgoingRouteStill(for: owner) != nil
        }
        #expect(populated)
        let image = try #require(vm.outgoingRouteStill(for: owner))
        #expect(image.scale == 2)
        if let cgImage = image.cgImage {
            #expect(max(cgImage.width, cgImage.height) <= 480)
            #expect(cgImage.width == 480)
            #expect(cgImage.height == 270)
        } else {
            Issue.record("Expected rendered outgoing still to carry a CGImage")
        }
        #expect(mockBackend.fallbackFrameCallCount == 0)

        vm.clearOutgoingRouteStill(owner: owner)
        #expect(vm.outgoingRouteStill(for: owner) == nil)
        #expect(vm.routeOwnership.outgoingRouteStillTasks[owner] == nil)
    }

    @Test("Off-main parkOutgoingRouteStill respects clearOutgoingRouteStill and retireDepartedRouteStill cancellation")
    func offMainParkOutgoingRouteStillClearAndRetireCancellation() async throws {
        let vm = PlayerViewModel.shared
        let savedBackend = vm.activeBackend
        let savedOwner = vm.ownerKey
        let mockBackend = MockTransitionStillBackend()
        let pixelBuffer = try Self.makeSyntheticPixelBuffer(width: 1920, height: 1080)
        mockBackend.captureSourceHandler = {
            DisplayedFrameCaptureSource(pixelBuffer: pixelBuffer, displayScale: 3)
        }

        vm.clearAllOutgoingRouteStills()
        vm.activeBackend = mockBackend
        defer {
            vm.clearAllOutgoingRouteStills()
            vm.activeBackend = savedBackend
            vm.ownerKey = savedOwner
        }

        // 1) Immediate clearOutgoingRouteStill cancels in-flight detached render before storing.
        let clearedOwner = "vod-detail-clear-\(UUID().uuidString)"
        vm.ownerKey = clearedOwner
        #expect(vm.parkOutgoingRouteStill() == clearedOwner)
        vm.clearOutgoingRouteStill(owner: clearedOwner)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(vm.outgoingRouteStill(for: clearedOwner) == nil)
        #expect(vm.routeOwnership.outgoingRouteStillTasks[clearedOwner] == nil)

        // 2) Immediate retireDepartedRouteStill blocks departed owner from populating outgoingRouteStills.
        let retiredOwner = "vod-detail-retire-\(UUID().uuidString)"
        vm.ownerKey = retiredOwner
        #expect(vm.parkOutgoingRouteStill() == retiredOwner)
        vm.retireDepartedRouteStill(owner: retiredOwner)
        let cleanedUp = await Self.waitUntil {
            vm.routeOwnership.outgoingRouteStillTasks[retiredOwner] == nil
        }
        #expect(cleanedUp)
        #expect(vm.outgoingRouteStill(for: retiredOwner) == nil)

        // 3) Retiring an already-parked owner releases it on the next parkOutgoingRouteStill call.
        let previousOwner = "vod-detail-prev-\(UUID().uuidString)"
        vm.ownerKey = previousOwner
        #expect(vm.parkOutgoingRouteStill() == previousOwner)
        let prevPopulated = await Self.waitUntil {
            vm.outgoingRouteStill(for: previousOwner) != nil
        }
        #expect(prevPopulated)
        vm.retireDepartedRouteStill(owner: previousOwner)
        #expect(vm.outgoingRouteStill(for: previousOwner) != nil)

        let nextOwner = "vod-detail-next-\(UUID().uuidString)"
        vm.ownerKey = nextOwner
        #expect(vm.parkOutgoingRouteStill() == nextOwner)
        #expect(vm.outgoingRouteStill(for: previousOwner) == nil)
        vm.clearOutgoingRouteStill(owner: nextOwner)
    }

    @Test("parkOutgoingRouteStill falls back to currentDisplayedFrameForTransition when capture source is nil")
    func parkOutgoingRouteStillFallbackWhenCaptureSourceIsNil() throws {
        let vm = PlayerViewModel.shared
        let savedBackend = vm.activeBackend
        let savedOwner = vm.ownerKey
        let mockBackend = MockTransitionStillBackend()
        let fallbackImage = Self.makeSyntheticFallbackImage(width: 160, height: 90)
        mockBackend.captureSourceHandler = { nil }
        mockBackend.fallbackFrameHandler = { fallbackImage }

        vm.clearAllOutgoingRouteStills()
        vm.activeBackend = mockBackend
        defer {
            vm.clearAllOutgoingRouteStills()
            vm.activeBackend = savedBackend
            vm.ownerKey = savedOwner
        }

        // Empty owner returns nil without touching backend.
        vm.ownerKey = ""
        #expect(vm.parkOutgoingRouteStill() == nil)
        #expect(mockBackend.captureSourceCallCount == 0)
        #expect(mockBackend.fallbackFrameCallCount == 0)

        // Nil capture source falls back synchronously to currentDisplayedFrameForTransition.
        let owner = "vod-detail-fallback-\(UUID().uuidString)"
        vm.ownerKey = owner
        #expect(vm.parkOutgoingRouteStill() == owner)
        #expect(mockBackend.captureSourceCallCount == 1)
        #expect(mockBackend.fallbackFrameCallCount == 1)
        let stored = try #require(vm.outgoingRouteStill(for: owner))
        #expect(stored.size == fallbackImage.size)

        // When both capture source and fallback frame are nil, any stale still is cleared.
        mockBackend.fallbackFrameHandler = { nil }
        #expect(vm.parkOutgoingRouteStill() == owner)
        #expect(mockBackend.captureSourceCallCount == 2)
        #expect(mockBackend.fallbackFrameCallCount == 2)
        #expect(vm.outgoingRouteStill(for: owner) == nil)
    }

    @Test("DetailDepartureHeightFreezePolicy freezes compact height on departure and gates animations and related deferral")
    func detailDepartureHeightFreezeAndRelatedDeferralPolicy() {
        // Active compact route always reflects live computed height (ignoring stale frozen/cached values).
        #expect(
            DetailDepartureHeightFreezePolicy.resolvedHeight(
                isWideLayout: false,
                wideHeight: 500,
                isActiveRoute: true,
                frozenStateHeight: 420,
                cachedActiveHeight: 380,
                computedHeight: 292.5
            ) == 292.5
        )

        // Inactive compact route prefers frozenStateHeight, then cachedActiveHeight, then computedHeight.
        #expect(
            DetailDepartureHeightFreezePolicy.resolvedHeight(
                isWideLayout: false,
                wideHeight: 500,
                isActiveRoute: false,
                frozenStateHeight: 520,
                cachedActiveHeight: 480,
                computedHeight: 220
            ) == 520
        )
        #expect(
            DetailDepartureHeightFreezePolicy.resolvedHeight(
                isWideLayout: false,
                wideHeight: 500,
                isActiveRoute: false,
                frozenStateHeight: nil,
                cachedActiveHeight: 480,
                computedHeight: 220
            ) == 480
        )
        #expect(
            DetailDepartureHeightFreezePolicy.resolvedHeight(
                isWideLayout: false,
                wideHeight: 500,
                isActiveRoute: false,
                frozenStateHeight: nil,
                cachedActiveHeight: nil,
                computedHeight: 220
            ) == 220
        )

        // Wide layout always uses wideHeight even when inactive.
        #expect(
            DetailDepartureHeightFreezePolicy.resolvedHeight(
                isWideLayout: true,
                wideHeight: 500,
                isActiveRoute: false,
                frozenStateHeight: 420,
                cachedActiveHeight: 380,
                computedHeight: 220
            ) == 500
        )

        // Inline height animations are permitted only while active, compact, and non-fullscreen.
        #expect(
            DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                isActiveRoute: true,
                isWideLayout: false,
                isFullscreenPresentationActive: false,
                isFullscreen: false
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                isActiveRoute: false,
                isWideLayout: false,
                isFullscreenPresentationActive: false,
                isFullscreen: false
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                isActiveRoute: true,
                isWideLayout: true,
                isFullscreenPresentationActive: false,
                isFullscreen: false
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                isActiveRoute: true,
                isWideLayout: false,
                isFullscreenPresentationActive: true,
                isFullscreen: false
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.allowsInlineHeightAnimation(
                isActiveRoute: true,
                isWideLayout: false,
                isFullscreenPresentationActive: false,
                isFullscreen: true
            )
        )

        // Related grid deferral applies only on compact routes with videos before transition settles.
        #expect(
            DetailDepartureHeightFreezePolicy.shouldDeferRelatedGrid(
                isCompact: true,
                hasVideos: true,
                isTransitionSettled: false
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.shouldDeferRelatedGrid(
                isCompact: true,
                hasVideos: true,
                isTransitionSettled: true
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.shouldDeferRelatedGrid(
                isCompact: false,
                hasVideos: true,
                isTransitionSettled: false
            )
        )
        #expect(
            !DetailDepartureHeightFreezePolicy.shouldDeferRelatedGrid(
                isCompact: true,
                hasVideos: false,
                isTransitionSettled: false
            )
        )
    }

    @Test("UGCSeasonInlineSelectionPolicy resolves same-aid parts, cross-aid zoom-free targets, and season queue sync")
    func ugcSeasonInlineSelectionAndQueueSyncPolicy() throws {
        let json = """
        {
          "aid": 5001,
          "bvid": "BV1season0001",
          "cid": 50011,
          "title": "Season Ep 1",
          "desc": "",
          "pic": "https://example.com/ep1.jpg",
          "duration": 300,
          "pubdate": 1700000000,
          "owner": { "mid": 9, "name": "SeriesUP", "face": "https://example.com/up.jpg" },
          "stat": { "view": 100, "danmaku": 10, "reply": 5, "favorite": 4, "coin": 3, "share": 2, "like": 20 },
          "pages": [
            { "cid": 50011, "page": 1, "part": "Part 1", "duration": 150 },
            { "cid": 50012, "page": 2, "part": "Part 2", "duration": 150 }
          ],
          "ugc_season": {
            "id": 99,
            "title": "Swift Series",
            "sections": [
              {
                "id": 1,
                "title": "Main",
                "episodes": [
                  { "id": 1, "aid": 5001, "bvid": "BV1season0001", "cid": 50011, "title": "Ep 1 P1" },
                  { "id": 2, "aid": 5001, "bvid": "BV1season0001", "cid": 50012, "title": "Ep 1 P2" },
                  {
                    "id": 3,
                    "aid": 5002,
                    "bvid": "BV1season0002",
                    "cid": 50021,
                    "title": "Ep 2 Vertical",
                    "arc": { "pic": "https://example.com/ep2.jpg", "duration": 95 },
                    "page": {
                      "cid": 50021,
                      "page": 1,
                      "part": "Main",
                      "duration": 95,
                      "dimension": { "width": 1080, "height": 1920, "rotate": 0 }
                    }
                  }
                ]
              }
            ]
          }
        }
        """

        let info = try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
        let season = try #require(info.ugcSeason)
        let episodes = season.allEpisodes
        #expect(episodes.count == 3)

        // Same aid + same cid -> resume/replay current without pushing.
        let samePartAction = UGCSeasonInlineSelectionPolicy.resolveSelection(
            episode: episodes[0],
            currentVideoInfo: info,
            currentCid: 50011,
            fallbackOwnerName: info.owner.name
        )
        if case .resumeOrReplayCurrent = samePartAction {
            // Expected
        } else {
            Issue.record("Expected .resumeOrReplayCurrent for active episode, got \(samePartAction)")
        }

        // Same aid + different cid matching a page -> in-place part switch.
        let siblingPartAction = UGCSeasonInlineSelectionPolicy.resolveSelection(
            episode: episodes[1],
            currentVideoInfo: info,
            currentCid: 50011,
            fallbackOwnerName: info.owner.name
        )
        if case .switchPart(let page) = siblingPartAction {
            #expect(page.cid == 50012)
            #expect(page.page == 2)
        } else {
            Issue.record("Expected .switchPart(P2), got \(siblingPartAction)")
        }

        // Different aid -> zoom-free inline switch preserving videoID, cid, cover, duration, and aspect hints.
        let nextEpisodeAction = UGCSeasonInlineSelectionPolicy.resolveSelection(
            episode: episodes[2],
            currentVideoInfo: info,
            currentCid: 50011,
            fallbackOwnerName: info.owner.name
        )
        if case .switchVideoInline(let target, let preferredCid) = nextEpisodeAction {
            #expect(target.videoID == .bvid("BV1season0002"))
            #expect(target.zoomSourceID == nil)
            #expect(target.preview.title == "Ep 2 Vertical")
            #expect(target.preview.ownerName == "SeriesUP")
            #expect(target.preview.durationSeconds == 95)
            #expect(target.preview.isPortraitHint == true)
            #expect(abs((target.preview.aspectRatioHint ?? 0) - (9.0 / 16.0)) < 0.01)
            #expect(preferredCid == 50021)
        } else {
            Issue.record("Expected .switchVideoInline for episode 2, got \(nextEpisodeAction)")
        }

        // Active matching .ugcSeason queue syncs selection to target episode; unrelated queues stay untouched.
        let seasonQueue = try #require(
            PlaybackQueueContext.ugcSeason(
                season,
                info: info,
                videoID: .bvid(info.bvid),
                currentCid: 50011
            )
        )
        let synced = try #require(
            UGCSeasonInlineSelectionPolicy.syncedSeasonQueue(
                existingQueue: seasonQueue,
                seasonID: 99,
                aid: 5002,
                cid: 50021
            )
        )
        #expect(synced.currentItem?.aid == 5002)
        #expect(synced.currentItem?.cid == 50021)

        // Already-selected episode produces nil (no redundant queue mutation).
        #expect(
            UGCSeasonInlineSelectionPolicy.syncedSeasonQueue(
                existingQueue: synced,
                seasonID: 99,
                aid: 5002,
                cid: 50021
            ) == nil
        )
        // Different season ID or non-season queue is ignored.
        #expect(
            UGCSeasonInlineSelectionPolicy.syncedSeasonQueue(
                existingQueue: seasonQueue,
                seasonID: 777,
                aid: 5002,
                cid: 50021
            ) == nil
        )
        let unrelatedQueue = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: seasonQueue.items,
            currentIndex: 0
        )
        #expect(
            UGCSeasonInlineSelectionPolicy.syncedSeasonQueue(
                existingQueue: unrelatedQueue,
                seasonID: 99,
                aid: 5002,
                cid: 50021
            ) == nil
        )
    }
}
