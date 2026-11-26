import CoreGraphics
import Foundation
import Testing
@testable import SwiftPili

@Suite("Track 5: UGC Season, Joint Creators, Timestamps, Chapters & Storyboard Preview")
struct Track5DetailAndSeekBarTests {

    // MARK: - VideoInfo ugc_season & staff Decoding

    @Test("Decodes VideoInfo staff joint creators, multi-section ugc_season, and description timestamp links")
    func videoInfoUGCSeasonStaffAndDescTimestamps() throws {
        let json = """
        {
          "aid": 100200,
          "bvid": "BV1track50001",
          "cid": 200300,
          "title": "Joint Collaboration Ep 2",
          "desc": "0:05 Intro\\n02:35 Main feature\\n1:04:09 Credits\\nIgnore 99:99 and 2026:11",
          "pic": "https://i0.hdslb.com/bfs/archive/cover.jpg",
          "duration": 4200,
          "pubdate": 1700000000,
          "copyright": 1,
          "owner": {
            "mid": 1001,
            "name": "LeadCreator",
            "face": "https://i0.hdslb.com/bfs/face/lead.jpg"
          },
          "stat": {
            "view": 123456,
            "danmaku": 888,
            "reply": 321,
            "favorite": 555,
            "coin": 444,
            "share": 99,
            "like": 9999
          },
          "staff": [
            {
              "mid": 1001,
              "title": "UP主",
              "name": "LeadCreator",
              "face": "https://i0.hdslb.com/bfs/face/lead.jpg",
              "vip": { "type": 2, "status": 1, "label": { "text": "年度大会员" } },
              "official": { "role": 1, "title": "知名UP主", "desc": "", "type": 0 },
              "follower": 500000
            },
            {
              "mid": 2002,
              "title": "混音",
              "name": "AudioWizard",
              "face": "https://i0.hdslb.com/bfs/face/audio.jpg",
              "vip": { "type": 0, "status": 0 },
              "official": { "role": 0, "title": "", "desc": "", "type": -1 }
            }
          ],
          "ugc_season": {
            "id": 778899,
            "title": "SwiftPili Deep Dive Series",
            "cover": "https://i0.hdslb.com/bfs/archive/season.jpg",
            "intro": "Multi-section series",
            "ep_count": 3,
            "sections": [
              {
                "id": 10,
                "title": "正片",
                "episodes": [
                  {
                    "id": 101,
                    "aid": 100100,
                    "bvid": "BV1track50000",
                    "cid": 200100,
                    "title": "Ep 1 Architecture",
                    "arc": {
                      "pic": "https://i0.hdslb.com/bfs/archive/ep1.jpg",
                      "duration": 610,
                      "stat": { "view": 88000, "like": 4200 }
                    }
                  },
                  {
                    "id": 102,
                    "aid": 100200,
                    "bvid": "BV1track50001",
                    "cid": 200300,
                    "title": "Ep 2 Playback",
                    "arc": {
                      "pic": "https://i0.hdslb.com/bfs/archive/ep2.jpg",
                      "duration": 4200,
                      "stat": { "view": 123456, "like": 9999 }
                    }
                  }
                ]
              },
              {
                "id": 20,
                "title": "番外",
                "episodes": [
                  {
                    "id": 201,
                    "aid": 100300,
                    "bvid": "BV1track50002",
                    "cid": 200400,
                    "title": "Behind the Scenes",
                    "arc": {
                      "pic": "https://i0.hdslb.com/bfs/archive/ep3.jpg",
                      "duration": 305,
                      "stat": { "view": 21000 }
                    }
                  }
                ]
              }
            ]
          }
        }
        """

        let info = try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))

        // Staff assertions
        #expect(info.staff?.count == 2)
        #expect(info.staff?[0].mid == 1001)
        #expect(info.staff?[0].title == "UP主")
        #expect(info.staff?[0].vip?.isActive == true)
        #expect(info.staff?[0].official?.title == "知名UP主")
        #expect(info.staff?[1].mid == 2002)
        #expect(info.staff?[1].title == "混音")
        #expect(info.staff?[1].name == "AudioWizard")

        // UGC Season assertions
        let season = try #require(info.ugcSeason)
        #expect(season.id == 778899)
        #expect(season.title == "SwiftPili Deep Dive Series")
        #expect(season.epCount == 3)
        #expect(season.sections?.count == 2)
        #expect(season.allEpisodes.count == 3)
        #expect(season.allEpisodes[0].arc?.duration == 610)
        #expect(season.allEpisodes[0].arc?.stat?.view == 88000)
        #expect(season.allEpisodes[2].bvid == "BV1track50002")

        // Description timestamp links assertions
        #expect(info.descLinks["0:05"] == URL(string: "swiftpili://seek?t=5"))
        #expect(info.descLinks["02:35"] == URL(string: "swiftpili://seek?t=155"))
        #expect(info.descLinks["1:04:09"] == URL(string: "swiftpili://seek?t=3849"))
        #expect(info.descLinks["99:99"] == nil)
        #expect(info.descLinks["2026:11"] == nil)
    }

    @Test("Builds PlaybackQueueContext.ugcSeason and expands current multi-part video pages in place")
    func ugcSeasonPlaybackQueueConstruction() throws {
        let json = """
        {
          "aid": 200,
          "bvid": "BV1ep20000001",
          "cid": 2001,
          "title": "Episode 2 Multi-Part",
          "desc": "",
          "pic": "https://example.com/ep2.jpg",
          "duration": 300,
          "pubdate": 1700000000,
          "owner": { "mid": 7, "name": "Creator", "face": "https://example.com/f.jpg" },
          "stat": { "view": 1, "danmaku": 0, "reply": 0, "favorite": 0, "coin": 0, "share": 0, "like": 0 },
          "pages": [
            { "cid": 2001, "page": 1, "part": "Part A", "duration": 150 },
            { "cid": 2002, "page": 2, "part": "Part B", "duration": 150 }
          ],
          "ugc_season": {
            "id": 42,
            "title": "Course",
            "sections": [
              {
                "id": 1,
                "title": "Main",
                "episodes": [
                  { "id": 1, "aid": 100, "bvid": "BV1ep10000001", "cid": 1001, "title": "Ep 1" },
                  { "id": 2, "aid": 200, "bvid": "BV1ep20000001", "cid": 2001, "title": "Ep 2" },
                  { "id": 3, "aid": 300, "bvid": "BV1ep30000001", "cid": 3001, "title": "Ep 3" }
                ]
              }
            ]
          }
        }
        """

        let info = try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
        let season = try #require(info.ugcSeason)
        let queue = try #require(
            PlaybackQueueContext.ugcSeason(
                season,
                info: info,
                videoID: .bvid(info.bvid),
                currentCid: 2002
            )
        )

        #expect(queue.kind == .ugcSeason(seasonId: 42))
        // Ep 1 (100/1001), Ep 2 P1 (200/2001), Ep 2 P2 (200/2002), Ep 3 (300/3001)
        #expect(queue.items.count == 4)
        #expect(queue.items.map(\.cid) == [1001, 2001, 2002, 3001])
        #expect(queue.currentIndex == 2)
        #expect(queue.hasPrevious == true)
        #expect(queue.hasNext == true)
        #expect(queue.item(atOffset: 1)?.aid == 300)
    }

    @Test("Decodes TripleLikeResult fields accurately")
    func tripleLikeResultDecoding() throws {
        let json = """
        { "like": true, "coin": true, "fav": true, "multiply": 2 }
        """
        let decoded = try JSONDecoder().decode(TripleLikeResult.self, from: Data(json.utf8))
        #expect(decoded == TripleLikeResult(like: true, coin: true, fav: true, multiply: 2))
    }

    // MARK: - PlayerV2Info ViewPoints & Chapters

    @Test("Decodes PlayerV2Info.ViewPoint content/title and resolves active VideoChapter & tick fractions")
    func viewPointChapterDecodingAndLookup() throws {
        let json = """
        {
          "last_play_time": 12000,
          "last_play_cid": 999,
          "view_points": [
            { "from": 0, "to": 45, "content": "开场导览", "imgUrl": "//i0.hdslb.com/bfs/vp/1.jpg" },
            { "from": 45, "to": 180, "title": "核心演示", "img_url": "https://i0.hdslb.com/bfs/vp/2.jpg" },
            { "from": 180, "to": 240, "content": "   ", "imgUrl": "https://i0.hdslb.com/bfs/vp/empty.jpg" },
            { "from": 240, "to": 300, "content": "总结问答" }
          ]
        }
        """

        let info = try JSONDecoder().decode(PlayerV2Info.self, from: Data(json.utf8))
        let points = try #require(info.viewPoints)
        #expect(points.count == 4)
        #expect(points[0].content == "开场导览")
        #expect(points[1].content == "核心演示")
        #expect(points[2].content == nil)
        #expect(points[3].content == "总结问答")

        let chapters = VideoChapter.from(viewPoints: points)
        #expect(chapters.count == 3)
        #expect(chapters[0].title == "开场导览")
        #expect(chapters[0].imgURL == "https://i0.hdslb.com/bfs/vp/1.jpg")
        #expect(chapters[1].title == "核心演示")
        #expect(chapters[2].title == "总结问答")

        #expect(VideoChapter.activeChapter(at: 0, in: chapters)?.title == "开场导览")
        #expect(VideoChapter.activeChapter(at: 44.9, in: chapters)?.title == "开场导览")
        #expect(VideoChapter.activeChapter(at: 45, in: chapters)?.title == "核心演示")
        #expect(VideoChapter.activeChapter(at: 190, in: chapters) == nil)
        #expect(VideoChapter.activeChapter(at: 260, in: chapters)?.title == "总结问答")

        let ticks = VideoChapter.tickFractions(for: chapters, duration: 300)
        // Chapter at 0s is excluded (<= 0.005); 45/300 = 0.15 and 240/300 = 0.80
        #expect(ticks.count == 2)
        #expect(abs(ticks[0] - 0.15) < 1e-6)
        #expect(abs(ticks[1] - 0.80) < 1e-6)
    }

    // MARK: - Timestamp Regex & URL Parsing

    @Test("Parses valid timestamps and rejects out-of-range, ratio, date, and embedded digit patterns")
    func timestampRegexParsing() throws {
        let validText = "空降0:05开始，高能在02:35-03:10，超长合集看1:04:09。"
        let links = EmoteText.timestampLinks(in: validText)
        #expect(links["0:05"] == URL(string: "swiftpili://seek?t=5"))
        #expect(links["02:35"] == URL(string: "swiftpili://seek?t=155"))
        #expect(links["03:10"] == URL(string: "swiftpili://seek?t=190"))
        #expect(links["1:04:09"] == URL(string: "swiftpili://seek?t=3849"))
        #expect(links.count == 4)

        let invalidText = "99:99 12:60 1:60:00 2026:11 123:45 16:9 abc02:35 02:35xyz 1.02:35 02:35.5 01:02:03:04"
        let rejected = EmoteText.timestampLinks(in: invalidText)
        #expect(rejected.isEmpty)

        // Both query (?t=) and legacy path (/seconds) forms decode accurately
        let queryURL = try #require(URL(string: "swiftpili://seek?t=155"))
        let legacyURL = try #require(URL(string: "swiftpili://seek/155"))
        let webURL = try #require(URL(string: "https://www.bilibili.com/video/BV1xx"))
        #expect(EmoteText.seekSeconds(from: queryURL) == 155)
        #expect(EmoteText.seekSeconds(from: legacyURL) == 155)
        #expect(EmoteText.seekSeconds(from: webURL) == nil)
    }

    // MARK: - Storyboard Frame Slot Lookup Math

    @Test("Resolves VideoStoryboardManifest sheetIndex, row, column, and crop rect with binary search")
    func storyboardFrameSlotLookupMath() throws {
        // 2x2 grid (4 cells per sheet) across 2 sheets, with Bilibili's duplicate leading 0 header
        let json = """
        {
          "img_x_len": 2,
          "img_y_len": 2,
          "img_x_size": 160,
          "img_y_size": 90,
          "image": [
            "//i0.hdslb.com/bfs/videoshot/sheet0.jpg",
            "https://i0.hdslb.com/bfs/videoshot/sheet1.jpg"
          ],
          "index": [0, 0, 5, 10, 15, 20, 25, 30, 35]
        }
        """
        let manifest = try JSONDecoder().decode(VideoStoryboardManifest.self, from: Data(json.utf8))

        // Normalized times should strip the duplicate leading 0 header -> [0, 5, 10, 15, 20, 25, 30, 35]
        let times = VideoStoryboardFrameLocator.normalizedTimes(from: manifest)
        #expect(times == [0, 5, 10, 15, 20, 25, 30, 35])

        // t = 0 -> frame 0 -> sheet 0, row 0, col 0
        let slot0 = try #require(VideoStoryboardFrameLocator.frameSlot(in: manifest, at: 0))
        #expect(slot0.frameIndex == 0)
        #expect(slot0.sheetIndex == 0)
        #expect(slot0.row == 0)
        #expect(slot0.column == 0)
        #expect(slot0.sheetURL == "https://i0.hdslb.com/bfs/videoshot/sheet0.jpg")

        // t = 14.9 -> binary search hits 10s (frame 2) -> sheet 0, row 1, col 0
        let slot2 = try #require(VideoStoryboardFrameLocator.frameSlot(in: manifest, at: 14.9))
        #expect(slot2.frameIndex == 2)
        #expect(slot2.sheetIndex == 0)
        #expect(slot2.row == 1)
        #expect(slot2.column == 0)

        // t = 27 -> binary search hits 25s (frame 5) -> sheet 1 (5 / 4 = 1), offset 1 -> row 0, col 1
        let slot5 = try #require(VideoStoryboardFrameLocator.frameSlot(in: manifest, at: 27))
        #expect(slot5.frameIndex == 5)
        #expect(slot5.sheetIndex == 1)
        #expect(slot5.row == 0)
        #expect(slot5.column == 1)
        #expect(slot5.sheetURL == "https://i0.hdslb.com/bfs/videoshot/sheet1.jpg")

        let crop5 = try #require(slot5.pixelCropRect(imagePixelWidth: 320, imagePixelHeight: 180))
        #expect(crop5 == CGRect(x: 160, y: 0, width: 160, height: 90))

        // t = 999 (past last timestamp) clamps to last frame 7 -> sheet 1, row 1, col 1
        let slotLast = try #require(VideoStoryboardFrameLocator.frameSlot(in: manifest, at: 999))
        #expect(slotLast.frameIndex == 7)
        #expect(slotLast.sheetIndex == 1)
        #expect(slotLast.row == 1)
        #expect(slotLast.column == 1)

        // Scaled sheet fallback when CDN returns half-resolution image
        let scaledCrop = try #require(slotLast.pixelCropRect(imagePixelWidth: 160, imagePixelHeight: 90))
        #expect(scaledCrop == CGRect(x: 80, y: 45, width: 80, height: 45))
    }

    @Test("PlayerChapterStore caches and retrieves chapters by (aid, cid)")
    @MainActor
    func chapterStoreRoundtrip() {
        let store = PlayerChapterStore()
        let chapters = [
            VideoChapter(id: "c0", title: "Intro", from: 0, to: 30, imgURL: nil),
            VideoChapter(id: "c1", title: "Demo", from: 30, to: 120, imgURL: nil),
        ]
        #expect(store.chapters(aid: 555, cid: 666).isEmpty)
        let beforeRev = store.revision
        store.record(chapters, aid: 555, cid: 666)
        #expect(store.revision == beforeRev + 1)
        #expect(store.chapters(aid: 555, cid: 666) == chapters)
        store.clear()
        #expect(store.chapters(aid: 555, cid: 666).isEmpty)
    }
}
