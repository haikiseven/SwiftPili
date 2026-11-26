import Foundation
import Testing
@testable import SwiftPili

private struct SampleDanmakuBullet {
    let id: UInt64
    let progressMS: UInt64
    let mode: UInt64
    let content: String
}

private struct SampleSubtitleLine {
    let from: Double
    let endTime: Double
    let content: String
}

private struct SampleVideoPart {
    let cid: Int
    let page: Int
    let part: String
    let duration: Int
}

@Suite("Track 6: Offline Sidecars, Batch Download Picker & Play All Queue", .serialized)
@MainActor
struct Track6OfflineAndPlaylistTests {

    private static func makeTempDirectory(prefix: String = "track6-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        while remaining >= 0x80 {
            bytes.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    private static func encodeLengthDelimited(field: UInt64, payload: [UInt8]) -> [UInt8] {
        var out = encodeVarint((field << 3) | 2)
        out.append(contentsOf: encodeVarint(UInt64(payload.count)))
        out.append(contentsOf: payload)
        return out
    }

    private static func encodeVarintField(field: UInt64, value: UInt64) -> [UInt8] {
        var out = encodeVarint(field << 3)
        out.append(contentsOf: encodeVarint(value))
        return out
    }

    private static func makeDanmakuSegmentProtobuf(elements: [SampleDanmakuBullet]) -> Data {
        var segmentBytes: [UInt8] = []
        for elem in elements {
            var elemBytes: [UInt8] = []
            elemBytes.append(contentsOf: encodeVarintField(field: 1, value: elem.id))
            elemBytes.append(contentsOf: encodeVarintField(field: 2, value: elem.progressMS))
            elemBytes.append(contentsOf: encodeVarintField(field: 3, value: elem.mode))
            elemBytes.append(contentsOf: encodeVarintField(field: 4, value: 25))
            elemBytes.append(contentsOf: encodeVarintField(field: 5, value: 0xFF_FF_FF))
            elemBytes.append(contentsOf: encodeLengthDelimited(field: 6, payload: Array("a1b2c3d4".utf8)))
            elemBytes.append(contentsOf: encodeLengthDelimited(field: 7, payload: Array(elem.content.utf8)))
            elemBytes.append(contentsOf: encodeLengthDelimited(field: 12, payload: Array(String(elem.id).utf8)))
            segmentBytes.append(contentsOf: encodeLengthDelimited(field: 1, payload: elemBytes))
        }
        return Data(segmentBytes)
    }

    private static func makeBilibiliSubtitleJSON(_ cues: [SampleSubtitleLine]) -> Data {
        let items = cues.map { cue in
            """
            {"from": \(cue.from), "to": \(cue.endTime), "content": "\(cue.content)"}
            """
        }.joined(separator: ",")
        return Data("{\"font_size\": 0.4, \"body\": [\(items)]}".utf8)
    }

    private static func makeSampleVideoInfo(
        aid: Int = 8801,
        bvid: String = "BV1track60001",
        pages: [SampleVideoPart]
    ) throws -> VideoInfo {
        let primaryCid = pages.first?.cid ?? 1
        let pageJSON = pages.map { page in
            """
            {"cid": \(page.cid), "page": \(page.page), "part": "\(page.part)", "duration": \(page.duration)}
            """
        }.joined(separator: ",")
        let json = """
        {
          "aid": \(aid),
          "bvid": "\(bvid)",
          "cid": \(primaryCid),
          "title": "Multi-Part Course",
          "desc": "",
          "pic": "https://example.com/cover.jpg",
          "duration": 900,
          "pubdate": 1700000000,
          "owner": {"mid": 100, "name": "Instructor", "face": "https://example.com/face.jpg"},
          "stat": {"view": 500, "danmaku": 20, "reply": 10, "favorite": 5, "coin": 4, "share": 2, "like": 30},
          "pages": [\(pageJSON)]
        }
        """
        return try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
    }

    private static func makeSampleBangumiSeason() throws -> PGCSeasonInfo {
        let ep1 = "{\"id\": 101, \"aid\": 5001, \"cid\": 6001, \"bvid\": \"BV1ep101\", " +
            "\"title\": \"1\", \"long_title\": \"Prologue\", \"cover\": \"https://example.com/e1.jpg\"}"
        let ep2 = "{\"id\": 102, \"aid\": 5002, \"cid\": 6002, \"bvid\": \"\", " +
            "\"title\": \"2\", \"long_title\": \"Journey\", \"cover\": \"\"}"
        let ep3 = "{\"id\": 103, \"title\": \"PV\", \"long_title\": \"Missing IDs\"}"
        let json = """
        {
          "season_id": 7700,
          "type": 1,
          "title": "Offline Anime",
          "cover": "https://example.com/season.jpg",
          "episodes": [\(ep1), \(ep2), \(ep3)]
        }
        """
        return try JSONDecoder().decode(PGCSeasonInfo.self, from: Data(json.utf8))
    }

    private static func makePlaylistEntry(
        aid: Int,
        bvid: String,
        title: String,
        artist: String,
        durationSeconds: Int
    ) throws -> PlaylistQueueEntry {
        let target = try #require(
            VideoRouteTarget.make(
                bvid: bvid,
                aid: aid,
                title: title,
                coverURL: "",
                ownerName: artist,
                durationSeconds: durationSeconds
            )
        )
        return PlaylistQueueEntry(
            aid: aid,
            bvid: bvid,
            cid: nil,
            title: title,
            artist: artist,
            coverURL: nil,
            duration: durationSeconds > 0 ? TimeInterval(durationSeconds) : nil,
            isPortraitHint: nil,
            routeTarget: target
        )
    }

    // MARK: - 1. Sidecars preserve DownloadFileSnapshot integrity

    @Test("Sidecar danmaku and subtitle files never break DownloadFileSnapshot.filesExist")
    func sidecarFilesPreserveDownloadFileSnapshotIntegrity() throws {
        let folderName = "track6-integrity-\(UUID().uuidString)"
        let folderURL = DownloadStore.downloadsLocation.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let videoData = Data(repeating: 0xAA, count: 128)
        let audioData = Data(repeating: 0xBB, count: 64)
        try videoData.write(to: folderURL.appendingPathComponent("video.m4s"), options: .atomic)
        try audioData.write(to: folderURL.appendingPathComponent("audio.m4s"), options: .atomic)

        let snapshot = DownloadFileSnapshot(
            id: folderName,
            folderName: folderName,
            addedAt: .now,
            hasSeparateAudio: true,
            verifiedByteLength: Int64(videoData.count + audioData.count)
        )
        #expect(snapshot.lengthMatchesCommit == true)
        #expect(snapshot.filesExist == true)
        #expect(snapshot.hasOfflineSubtitles == false)
        #expect(snapshot.hasOfflineDanmaku == false)

        let zhData = Self.makeBilibiliSubtitleJSON([
            SampleSubtitleLine(from: 1.0, endTime: 3.0, content: "你好离线字幕"),
        ])
        try OfflineSubtitleSidecar.saveSubtitleData(zhData, filename: "zh-CN.json", in: folderURL)
        try OfflineSubtitleSidecar.saveManifest(
            [OfflineSubtitleTrackEntry(lan: "zh-CN", lanDoc: "中文（简体）", filename: "zh-CN.json")],
            in: folderURL
        )
        let dmData = Self.makeDanmakuSegmentProtobuf(elements: [
            SampleDanmakuBullet(id: 10001, progressMS: 2500, mode: 1, content: "离线弹幕测试"),
        ])
        try OfflineDanmakuSidecar.saveSegment(dmData, segmentIndex: 1, in: folderURL)
        try OfflineDanmakuSidecar.saveMetadata(Data([0x08, 0x00]), in: folderURL)

        // verifiedByteLength still strictly checks video.m4s + audio.m4s.
        #expect(snapshot.lengthMatchesCommit == true)
        #expect(snapshot.filesExist == true)
        #expect(snapshot.hasOfflineSubtitles == true)
        #expect(snapshot.hasOfflineDanmaku == true)

        // Modifying video.m4s still fails integrity as expected.
        try Data(repeating: 0xCC, count: 32).write(
            to: folderURL.appendingPathComponent("video.m4s"),
            options: .atomic
        )
        #expect(snapshot.lengthMatchesCommit == false)
        #expect(snapshot.filesExist == false)
    }

    // MARK: - 2. Offline subtitle manifest, cue roundtrip & dual-track offline mounting

    @Test("Offline subtitle manifest roundtrip, sanitization, and bilingual PlayerViewModel mounting")
    func offlineSubtitleRoundtripAndBilingualSelection() async throws {
        let folder = try Self.makeTempDirectory(prefix: "track6-subtitles")
        defer { try? FileManager.default.removeItem(at: folder) }

        let filename1 = OfflineSubtitleSidecar.sanitizedFilename(for: "zh-CN")
        let filename2 = OfflineSubtitleSidecar.sanitizedFilename(for: "en-US", existingNames: [filename1])
        let collision = OfflineSubtitleSidecar.sanitizedFilename(for: "zh-CN", existingNames: [filename1])
        let unsafe = OfflineSubtitleSidecar.sanitizedFilename(for: "../../etc/passwd")
        #expect(filename1 == "zh-CN.json")
        #expect(filename2 == "en-US.json")
        #expect(collision == "zh-CN_2.json")
        #expect(OfflineSubtitleSidecar.isValidFilename(unsafe))
        #expect(!OfflineSubtitleSidecar.isValidFilename("../evil.json"))

        let zhData = Self.makeBilibiliSubtitleJSON([
            SampleSubtitleLine(from: 1.0, endTime: 4.0, content: "离线主字幕"),
            SampleSubtitleLine(from: 5.0, endTime: 8.0, content: "第二句字幕"),
        ])
        let enData = Self.makeBilibiliSubtitleJSON([
            SampleSubtitleLine(from: 1.5, endTime: 4.5, content: "Offline secondary subtitle"),
        ])
        try OfflineSubtitleSidecar.saveSubtitleData(zhData, filename: filename1, in: folder)
        try OfflineSubtitleSidecar.saveSubtitleData(enData, filename: filename2, in: folder)

        let manifestEntries = [
            OfflineSubtitleTrackEntry(lan: "zh-CN", lanDoc: "中文（简体）", filename: filename1),
            OfflineSubtitleTrackEntry(lan: "en-US", lanDoc: "English", filename: filename2),
            OfflineSubtitleTrackEntry(lan: "bad", lanDoc: "Traversal", filename: "../escape.json"),
        ]
        try OfflineSubtitleSidecar.saveManifest(manifestEntries, in: folder)

        let loadedManifest = OfflineSubtitleSidecar.loadManifest(in: folder)
        #expect(loadedManifest.count == 2)
        #expect(loadedManifest[0].lan == "zh-CN")
        #expect(loadedManifest[1].lan == "en-US")

        let zhCues = try OfflineSubtitleSidecar.loadCues(for: loadedManifest[0], in: folder)
        #expect(zhCues.count == 2)
        #expect(zhCues[0].content == "离线主字幕")
        #expect(zhCues[1].from == 5.0)

        let player = PlayerViewModel.shared
        let previousAvailable = player.availableSubtitles
        defer {
            player.turnOffAllSubtitles()
            player.availableSubtitles = previousAvailable
        }

        let mounted = player.mountOfflineSubtitles(from: folder)
        #expect(mounted.count == 2)
        #expect(player.availableSubtitles.count == 2)
        #expect(mounted[0].subtitleUrl?.hasPrefix("file://") == true)

        await player.selectPrimarySubtitleTrack(id: "zh-CN")
        await player.selectSecondarySubtitleTrack(id: "en-US")
        player.updateSubtitle(at: 2.5)

        #expect(player.activeSubtitleLan == "zh-CN")
        #expect(player.secondarySubtitleLan == "en-US")
        #expect(player.subtitleText == "离线主字幕")
        #expect(player.secondarySubtitleText == "Offline secondary subtitle")
    }

    // MARK: - 3. Offline danmaku segment count & disk lookup

    @Test("Offline danmaku segment count policy and DanmakuSegmentStore disk lookup")
    func offlineDanmakuDiskLookupWithoutNetwork() async throws {
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 0) == 1)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 1) == 1)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 360) == 1)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 361) == 2)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 720) == 2)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 721) == 3)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 7200) == 20)
        #expect(OfflineDanmakuSidecar.segmentCount(durationSeconds: 36_000) == 24)

        let folder = try Self.makeTempDirectory(prefix: "track6-danmaku")
        defer { try? FileManager.default.removeItem(at: folder) }

        let protobuf = Self.makeDanmakuSegmentProtobuf(elements: [
            SampleDanmakuBullet(id: 9001, progressMS: 4_200, mode: 1, content: "前方高能"),
            SampleDanmakuBullet(id: 9002, progressMS: 12_800, mode: 5, content: "离线顶部弹幕"),
        ])
        try OfflineDanmakuSidecar.saveSegment(protobuf, segmentIndex: 1, in: folder)
        #expect(OfflineDanmakuSidecar.availableSegmentIndices(in: folder) == [1])
        #expect(DanmakuSegmentStore.resolveOfflineSegmentFileURL(in: folder, segmentIndex: 1) != nil)
        #expect(DanmakuSegmentStore.resolveOfflineSegmentFileURL(in: folder, segmentIndex: 2) == nil)

        let testOID = 987_654_321
        DanmakuSegmentStore.registerOfflineDirectory(folder, forOID: testOID)
        defer { DanmakuSegmentStore.unregisterOfflineDirectory(forOID: testOID, matching: folder) }
        #expect(DanmakuSegmentStore.offlineDirectory(forOID: testOID) == folder)

        let store = DanmakuSegmentStore(isOfflineOnly: true)
        store.reset(oid: testOID)

        await withCheckedContinuation { continuation in
            var resumed = false
            store.onSegmentsLoaded = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            store.advance(to: 5.0, duration: 400.0)
        }

        let bullets = store.elements(from: 0, to: 15.0)
        #expect(bullets.count == 2)
        #expect(bullets[0].content == "前方高能")
        #expect(bullets[0].progress == 4.2)
        #expect(bullets[1].content == "离线顶部弹幕")
        #expect(bullets[1].mode == 5)
        #expect(store.failures.isEmpty)

        // Advancing into an uncached segment in offline-only mode never records a network error.
        store.advance(to: 365.0, duration: 720.0)
        for _ in 0..<20 where store.segments[2] == nil {
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.segments[2] != nil)
        #expect(store.segments[2]?.isEmpty == true)
        #expect(store.failures.isEmpty)

        // Native PlayerDanmakuMountPolicy admits offline file URLs when offline danmaku is registered,
        // enabling native fullscreen & inline offline danmaku while keeping online VOD rules intact.
        let fileSource = folder.appendingPathComponent("video.m4s")
        #expect(
            PlayerDanmakuMountPolicy.shouldMount(
                mode: .offline,
                source: fileSource,
                isOwner: true,
                hasSurfaceLease: true,
                enabled: true,
                hasOfflineDanmaku: true
            )
        )
        #expect(
            !PlayerDanmakuMountPolicy.shouldMount(
                mode: .offline,
                source: fileSource,
                isOwner: true,
                hasSurfaceLease: true,
                enabled: true,
                hasOfflineDanmaku: false
            )
        )
    }

    // MARK: - 4. BatchEpisodeDownloadSheet selection state & factories

    @Test("BatchDownloadSelectionState handles cached/downloading/uncached & status transitions")
    func batchDownloadSelectionStateLogic() throws {
        let info = try Self.makeSampleVideoInfo(pages: [
            SampleVideoPart(cid: 1001, page: 1, part: "Intro", duration: 120),
            SampleVideoPart(cid: 1002, page: 2, part: "Main", duration: 240),
            SampleVideoPart(cid: 1003, page: 3, part: "Demo", duration: 180),
            SampleVideoPart(cid: 1004, page: 4, part: "Summary", duration: 90),
        ])
        let items = BatchDownloadSelectionState.items(from: info)
        #expect(items.count == 4)
        #expect(items[0].indexLabel == "P1")
        #expect(items[0].epId == nil)

        let statuses: [String: BatchDownloadItemStatus] = [
            items[0].id: .cached,
            items[1].id: .downloading(fraction: 0.42),
            items[2].id: .uncached,
            items[3].id: .uncached,
        ]
        var state = BatchDownloadSelectionState(
            items: items,
            statuses: statuses,
            initialSelection: [items[0].id, items[1].id, items[2].id]
        )

        #expect(state.selectedIDs == [items[2].id])
        #expect(state.selectedCount == 1)
        #expect(state.cachedCount == 1)
        #expect(state.downloadingCount == 1)
        #expect(state.allUncachedSelected == false)

        state.toggle(items[0].id)
        state.toggle(items[1].id)
        #expect(state.selectedIDs == [items[2].id])

        state.selectAllUncached()
        #expect(state.selectedItems.map(\.cid) == [1003, 1004])
        #expect(state.allUncachedSelected == true)

        var updatedStatuses = statuses
        updatedStatuses[items[2].id] = .downloading(fraction: 0.05)
        state.reconcileStatuses(updatedStatuses)
        #expect(state.selectedItems.map(\.cid) == [1004])

        state.deselectAll()
        #expect(state.selectedCount == 0)
        #expect(state.allUncachedSelected == false)

        let options = [
            DownloadQualityOption(code: 120, label: "4K", estimatedBytes: nil),
            DownloadQualityOption(code: 80, label: "1080P", estimatedBytes: nil),
            DownloadQualityOption(code: 64, label: "720P", estimatedBytes: nil),
        ]
        #expect(BatchDownloadSelectionState.defaultQualityCode(from: options, preferredWiFiQuality: 80) == 80)
        #expect(BatchDownloadSelectionState.defaultQualityCode(from: options, preferredWiFiQuality: 116) == 80)
        #expect(BatchDownloadSelectionState.defaultQualityCode(from: options, preferredWiFiQuality: 32) == 120)

        let season = try Self.makeSampleBangumiSeason()
        let bangumiItems = BatchDownloadSelectionState.items(from: season)
        #expect(bangumiItems.count == 2)
        #expect(bangumiItems[0].epId == 101)
        #expect(bangumiItems[0].bvid == "BV1ep101")
        #expect(bangumiItems[1].epId == 102)
        #expect(bangumiItems[1].bvid == "ep102")
    }

    // MARK: - 5. Play All Playlist Queue Hydration & Context Building

    @Test("PlaylistQueueLauncher builds valid playlist queue and hydrates missing CIDs cleanly")
    func playlistQueueHydrationAndFiltering() async throws {
        let entries = [
            try Self.makePlaylistEntry(aid: 101, bvid: "BV1play0001", title: "First Video", artist: "UP A", durationSeconds: 180),
            try Self.makePlaylistEntry(aid: 102, bvid: "BV1play0002", title: "Second Video", artist: "UP B", durationSeconds: 240),
            try Self.makePlaylistEntry(aid: 103, bvid: "BV1play0003", title: "Deleted Video", artist: "UP C", durationSeconds: 0),
        ]

        let launcher = PlaylistQueueLauncher { videoID in
            switch videoID {
            case .bvid("BV1play0002"), .aid(102):
                return ResolvedPlaylistVideoMetadata(cid: 2020, duration: 240, isPortrait: true)
            default:
                return nil
            }
        }
        defer { launcher.cancel() }

        #expect(launcher.buildQueueContext(playlistName: "Watch Later", entries: entries) == nil)

        let coordinator = AppCoordinator()
        let player = PlayerViewModel.shared
        let originalPlaylistMode = UserDefaults.standard.object(forKey: PlaylistOrderMode.defaultsKey)
        defer {
            player.clearPlaybackQueue()
            player.endCurrentOwnerPlayback()
            if let originalPlaylistMode {
                UserDefaults.standard.set(originalPlaylistMode, forKey: PlaylistOrderMode.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PlaylistOrderMode.defaultsKey)
            }
        }

        let launched = launcher.launch(
            playlistName: "Watch Later",
            entries: entries,
            coordinator: coordinator,
            player: player,
            orderMode: .sequential
        )
        #expect(launched == true)
        #expect(player.session.playbackOrder == .playNext)

        let lease = player.claimOwnerLease(owner: "track6-test-owner")
        let firstInfo = try Self.makeSampleVideoInfo(
            aid: 101,
            bvid: "BV1play0001",
            pages: [SampleVideoPart(cid: 1010, page: 1, part: "P1", duration: 180)]
        )
        launcher.adoptLoadedFirstVideoIfArmed(
            videoInfo: firstInfo,
            currentCid: 1010,
            lease: lease,
            player: player
        )

        for _ in 0..<40 where (player.playbackQueue?.items.count ?? 0) < 2 {
            try? await Task.sleep(for: .milliseconds(15))
        }

        let queue = try #require(player.playbackQueue)
        #expect(queue.kind == .playlist(name: "Watch Later"))
        #expect(queue.items.count == 2)
        #expect(queue.items[0].aid == 101)
        #expect(queue.items[0].cid == 1010)
        #expect(queue.items[1].aid == 102)
        #expect(queue.items[1].cid == 2020)
        #expect(queue.currentIndex == 0)
        #expect(queue.hasNext == true)
        #expect(player.onNextEpisode != nil)
    }

    @Test("PlaylistQueueLauncher expands multi-part videos and preserves user mode and edits during hydration")
    func playlistHydrationExpandsMultiPartAndPreservesEdits() async throws {
        let entries = [
            try Self.makePlaylistEntry(aid: 201, bvid: "BV1mp0001", title: "Course A", artist: "UP A", durationSeconds: 300),
            try Self.makePlaylistEntry(aid: 202, bvid: "BV1mp0002", title: "Course B", artist: "UP B", durationSeconds: 420),
            try Self.makePlaylistEntry(aid: 203, bvid: "BV1mp0003", title: "Course C", artist: "UP C", durationSeconds: 180),
        ]

        let launcher = PlaylistQueueLauncher { videoID in
            switch videoID {
            case .bvid("BV1mp0002"), .aid(202):
                return ResolvedPlaylistVideoMetadata(
                    cid: 2021,
                    duration: 420,
                    isPortrait: false,
                    pages: [
                        PlaylistVideoPart(cid: 2021, page: 1, part: "Part 1", duration: 200),
                        PlaylistVideoPart(cid: 2022, page: 2, part: "Part 2", duration: 220),
                    ]
                )
            case .bvid("BV1mp0003"), .aid(203):
                try? await Task.sleep(for: .milliseconds(150))
                return ResolvedPlaylistVideoMetadata(
                    cid: 2031,
                    duration: 180,
                    isPortrait: false,
                    pages: [PlaylistVideoPart(cid: 2031, page: 1, part: "Single", duration: 180)]
                )
            default:
                return nil
            }
        }
        defer { launcher.cancel() }

        let coordinator = AppCoordinator()
        let player = PlayerViewModel.shared
        let originalPlaylistMode = UserDefaults.standard.object(forKey: PlaylistOrderMode.defaultsKey)
        defer {
            player.clearPlaybackQueue()
            player.endCurrentOwnerPlayback()
            if let originalPlaylistMode {
                UserDefaults.standard.set(originalPlaylistMode, forKey: PlaylistOrderMode.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PlaylistOrderMode.defaultsKey)
            }
        }

        let launched = launcher.launch(
            playlistName: "Favorites",
            entries: entries,
            coordinator: coordinator,
            player: player,
            orderMode: .sequential
        )
        #expect(launched == true)

        let lease = player.claimOwnerLease(owner: "track6-multipart-owner")
        let firstInfo = try Self.makeSampleVideoInfo(
            aid: 201,
            bvid: "BV1mp0001",
            pages: [
                SampleVideoPart(cid: 2011, page: 1, part: "Intro", duration: 120),
                SampleVideoPart(cid: 2012, page: 2, part: "Deep Dive", duration: 180),
            ]
        )
        launcher.adoptLoadedFirstVideoIfArmed(
            videoInfo: firstInfo,
            currentCid: 2011,
            lease: lease,
            player: player
        )

        // Wait until Course A (2 parts) + Course B (2 parts) are hydrated.
        for _ in 0..<40 where (player.playbackQueue?.items.count ?? 0) < 4 {
            try? await Task.sleep(for: .milliseconds(15))
        }

        // User switches to Loop List and removes Course B Part 1 before Course C finishes hydrating.
        player.setPlaylistOrderMode(.loopList)
        let courseBPart1ID = try #require(player.playbackQueue?.items.first(where: { $0.cid == 2021 })?.id)
        player.removePlaylistItem(id: courseBPart1ID)

        // Wait for Course C to append incrementally.
        for _ in 0..<80 where player.playbackQueue?.items.contains(where: { $0.aid == 203 }) != true {
            try? await Task.sleep(for: .milliseconds(15))
        }

        let finalQueue = try #require(player.playbackQueue)
        #expect(finalQueue.playlistOrderMode == .loopList)
        #expect(finalQueue.items.map(\.cid) == [2011, 2012, 2022, 2031])
        #expect(finalQueue.items[0].partBadge == "P1/2")
        #expect(finalQueue.items[1].partBadge == "P2/2")
        #expect(finalQueue.items[2].partBadge == "P2/2")
        #expect(finalQueue.items[3].partBadge == nil)
    }
}
