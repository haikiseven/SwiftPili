import Foundation
import Testing
@testable import SwiftPili

@Suite("Track 3: Local Content Filter, Cloud Import & Undo Toast")
struct Track3ContentFilterTests {
    private struct IsolatedStoreEnv {
        let store: LocalContentFilterStore
        let url: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    @MainActor
    private static func makeIsolatedStore() throws -> IsolatedStoreEnv {
        let id = UUID().uuidString
        let suiteName = "com.swiftpili.tests.contentfilter.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPiliContentFilterTests-\(id)", isDirectory: true)
            .appendingPathComponent("rules.json", isDirectory: false)
        let store = LocalContentFilterStore(
            storageURL: url,
            userDefaults: defaults,
            keyPrefix: "test_lcf_\(id)",
            observesCloudBlocklist: false
        )
        return IsolatedStoreEnv(store: store, url: url, suiteName: suiteName, defaults: defaults)
    }

    @Test("Persistence saves and reloads all 4 rule sets and settings across store instances")
    @MainActor
    func persistenceRoundtripAcrossInstances() throws {
        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }

        let store = env.store
        #expect(store.isEnabled == true)
        #expect(store.collapseFilteredComments == false)

        #expect(store.blockUP(mid: 12345, name: "SpamUP", face: "https://example.com/a.jpg") == true)
        let blockedVideo = store.blockVideo(
            aid: 9988,
            bvid: "BV1ab411c7mD",
            title: "Clickbait",
            ownerName: "Someone"
        )
        #expect(blockedVideo != nil)
        #expect(store.addTitleKeyword("clickbait", isRegex: false) != nil)
        #expect(store.addCommentKeyword("promo\\d+", isRegex: true) != nil)
        store.collapseFilteredComments = true

        store.markSessionDisliked(aid: 777, bvid: "BV1Session777")
        #expect(store.isSessionDisliked(aid: 777, bvid: nil) == true)

        let reloaded = LocalContentFilterStore(
            storageURL: env.url,
            userDefaults: env.defaults,
            keyPrefix: "test_lcf_reloaded_\(UUID().uuidString)",
            observesCloudBlocklist: false
        )
        #expect(reloaded.isEnabled == true)
        #expect(reloaded.collapseFilteredComments == true)
        #expect(reloaded.blockedUPs.count == 1)
        #expect(reloaded.blockedUPs.first?.mid == 12345)
        #expect(reloaded.blockedUPs.first?.name == "SpamUP")
        #expect(reloaded.blockedVideos.count == 1)
        #expect(reloaded.blockedVideos.first?.bvid == "BV1ab411c7mD")
        #expect(reloaded.titleKeywords.count == 1)
        #expect(reloaded.titleKeywords.first?.pattern == "clickbait")
        #expect(reloaded.commentKeywords.count == 1)
        #expect(reloaded.commentKeywords.first?.isRegex == true)
        #expect(reloaded.isSessionDisliked(aid: 777, bvid: "BV1Session777") == false)
    }

    @Test("UP, video, title keyword (plain & regex), and enable switch filtering behavior")
    @MainActor
    func videoFilteringMatchingAndPrimaryToggle() throws {
        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }
        let store = env.store

        store.blockUP(mid: 500, name: "BlockedCreator")
        store.blockVideo(aid: 42, bvid: "bv1Xx411c7mD", title: "Hidden Clip", ownerName: "Other")
        let plainRule = try #require(store.addTitleKeyword("SPOILER", isRegex: false))
        _ = store.addTitleKeyword(#"ep\s*\d+\s*leak"#, isRegex: true)

        #expect(store.shouldHideVideo(
            aid: 1, bvid: "BV1ok", mid: 500, title: "Normal", includeCloudBlocklist: false
        ))
        #expect(store.shouldHideVideo(
            aid: 42, bvid: nil, mid: 1, title: "Normal", includeCloudBlocklist: false
        ))
        #expect(store.shouldHideVideo(
            aid: nil, bvid: "BV1Xx411c7mD", mid: 1, title: "Normal", includeCloudBlocklist: false
        ))
        #expect(store.shouldHideVideo(
            aid: 2, bvid: "BV2", mid: 2, title: "Major spoiler ahead", includeCloudBlocklist: false
        ))
        #expect(store.shouldHideVideo(
            aid: 3, bvid: "BV3", mid: 3, title: "EP 12 Leak Breakdown", includeCloudBlocklist: false
        ))
        #expect(!store.shouldHideVideo(
            aid: 4, bvid: "BV4", mid: 4, title: "SwiftUI Tutorial", includeCloudBlocklist: false
        ))

        store.toggleTitleKeyword(id: plainRule.id, isEnabled: false)
        #expect(!store.shouldHideVideo(
            aid: 2, bvid: "BV2", mid: 2, title: "Major spoiler ahead", includeCloudBlocklist: false
        ))

        store.markSessionDisliked(aid: 99, bvid: nil)
        store.isEnabled = false
        #expect(!store.shouldHideVideo(
            aid: 1, bvid: "BV1ok", mid: 500, title: "EP 12 Leak", includeCloudBlocklist: false
        ))
        #expect(store.shouldHideVideo(
            aid: 99, bvid: nil, mid: 1, title: "Normal", includeCloudBlocklist: false
        ))
    }

    @Test("Comment plain & regex filtering, invalid regex graceful handling, and collapsible toggle")
    @MainActor
    func commentFilteringAndInvalidRegexHandling() throws {
        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }
        let store = env.store

        #expect(LocalContentFilterStore.validateRegex("[unclosed(") != nil)
        #expect(LocalContentFilterStore.validateRegex(#"free\s+coins"#) == nil)

        store.blockUP(mid: 888, name: "TrollUser")
        _ = store.addCommentKeyword("scam", isRegex: false)
        _ = store.addCommentKeyword(#"free\s+coins"#, isRegex: true)
        _ = store.addCommentKeyword("[unclosed(", isRegex: true)

        let upReason = store.matchComment(mid: 888, content: "hello", includeCloudBlocklist: false)
        #expect(upReason == .blockedUP(mid: 888, name: "TrollUser"))
        let plainReason = store.matchComment(mid: 1, content: "Total SCAM link", includeCloudBlocklist: false)
        #expect(plainReason == .commentKeyword(pattern: "scam"))
        let regexReason = store.matchComment(mid: 1, content: "Claim Free   Coins now", includeCloudBlocklist: false)
        #expect(regexReason == .commentKeyword(pattern: #"free\s+coins"#))
        #expect(store.matchComment(mid: 1, content: "Great video, thanks!", includeCloudBlocklist: false) == nil)

        #expect(store.collapseFilteredComments == false)
        #expect(store.shouldHideCommentCompletely(mid: 888, content: "hello", includeCloudBlocklist: false) == true)
        #expect(store.shouldHideCommentCompletely(
            mid: 1, content: "Total SCAM link", includeCloudBlocklist: false
        ) == true)

        store.collapseFilteredComments = true
        #expect(store.shouldHideCommentCompletely(mid: 888, content: "hello", includeCloudBlocklist: false) == false)
        #expect(store.matchComment(mid: 888, content: "hello", includeCloudBlocklist: false) != nil)
    }

    @Test("Cloud danmaku filter decoding and bulk import into local filter rules")
    @MainActor
    func cloudDanmakuFilterDecodingAndImport() throws {
        let json = Data(
            """
            {
              "rule": [
                { "id": 101, "mid": 999, "type": 0, "filter": "剧透", "comment": "no spoilers" },
                { "id": 102, "mid": 999, "type": 1, "filter": "^刷屏+$", "comment": "" },
                { "id": 103, "mid": 999, "type": 2, "filter": "ab12cd34", "comment": "user hash" }
              ]
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(CloudDanmakuFilterResult.self, from: json)
        let rules = try #require(decoded.rule)
        #expect(rules.count == 3)
        #expect(rules[0].kind == .keyword)
        #expect(rules[0].isImportableAsKeywordRule == true)
        #expect(rules[1].kind == .regex)
        #expect(rules[1].isRegex == true)
        #expect(rules[2].kind == .userHash)
        #expect(rules[2].isImportableAsKeywordRule == false)

        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }
        let store = env.store

        let added = store.importCloudDanmakuFilters(rules, target: .both)
        #expect(added == 4)
        #expect(store.commentKeywords.count == 2)
        #expect(store.titleKeywords.count == 2)
        #expect(store.hasKeywordRule(pattern: "剧透", isRegex: false, in: .both))
        #expect(store.hasKeywordRule(pattern: "^刷屏+$", isRegex: true, in: .both))

        let secondImport = store.importCloudDanmakuFilters(rules, target: .both)
        #expect(secondImport == 0)
    }

    @Test("JSON export and import roundtrip supports merge deduplication and full restore")
    @MainActor
    func jsonExportImportRoundtrip() throws {
        let envA = try Self.makeIsolatedStore()
        let envB = try Self.makeIsolatedStore()
        defer {
            envA.cleanup()
            envB.cleanup()
        }

        envA.store.blockUP(mid: 11, name: "UP Eleven")
        envA.store.blockVideo(aid: 22, bvid: "BV1Export22", title: "Exported Video", ownerName: "UP Eleven")
        _ = envA.store.addTitleKeyword("clickbait", isRegex: false)
        _ = envA.store.addCommentKeyword(#"spam\d+"#, isRegex: true)
        envA.store.collapseFilteredComments = true

        let data = try envA.store.exportJSONData()

        envB.store.blockUP(mid: 11, name: "UP Eleven")
        envB.store.blockUP(mid: 33, name: "Existing Local UP")

        let summary = try envB.store.importJSONData(data, merge: true)
        #expect(summary.addedUPs == 0)
        #expect(summary.addedVideos == 1)
        #expect(summary.addedTitleKeywords == 1)
        #expect(summary.addedCommentKeywords == 1)
        #expect(summary.totalAdded == 3)
        #expect(envB.store.blockedUPs.count == 2)
        #expect(envB.store.shouldHideVideo(
            aid: 22, bvid: nil, mid: 1, title: "X", includeCloudBlocklist: false
        ))
        #expect(envB.store.matchComment(mid: 1, content: "spam99", includeCloudBlocklist: false) != nil)

        _ = try envB.store.importJSONData(data, merge: false)
        #expect(envB.store.blockedUPs.count == 1)
        #expect(envB.store.blockedUPs.first?.mid == 11)
        #expect(envB.store.collapseFilteredComments == true)
    }

    @Test("Undo toast lifecycle restores blocked state, auto-dismisses, and never contains middle dot")
    @MainActor
    func undoToastLifecycleAndNoMiddleDot() async throws {
        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }
        let store = env.store
        let toastCenter = ContentFilterUndoToastCenter()

        store.blockUP(mid: 404, name: "NoisyUP")
        #expect(store.isUPBlockedLocally(404) == true)

        let firstToast = toastCenter.show(
            message: "已本地屏蔽 UP「NoisyUP」",
            undoLabel: "撤销",
            systemImage: "person.slash",
            duration: .seconds(4)
        ) {
            store.unblockUP(mid: 404)
        }

        #expect(toastCenter.currentToast == firstToast)
        #expect(!firstToast.message.contains("\u{00B7}"))
        #expect(!firstToast.undoLabel.contains("\u{00B7}"))

        toastCenter.performUndo()
        #expect(toastCenter.currentToast == nil)
        #expect(store.isUPBlockedLocally(404) == false)

        let sanitized = toastCenter.show(
            message: "已标记不感兴趣\u{00B7}撤销",
            undoLabel: "撤销",
            duration: .milliseconds(80)
        ) {}
        #expect(!sanitized.message.contains("\u{00B7}"))
        #expect(toastCenter.currentToast != nil)

        try await Task.sleep(for: .milliseconds(160))
        #expect(toastCenter.currentToast == nil)
    }

    @Test("Undo restoration works for session cloud dislike and local video hide")
    @MainActor
    func undoRestorationForDislikeAndHiddenVideo() throws {
        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }
        let store = env.store
        let toastCenter = ContentFilterUndoToastCenter()

        store.markSessionDisliked(aid: 1001, bvid: "BV1Dislike1001")
        #expect(store.shouldHideVideo(
            aid: 1001, bvid: "BV1Dislike1001", mid: 1, title: "Title", includeCloudBlocklist: false
        ))
        toastCenter.show(message: "已标记不感兴趣", undoLabel: "撤销") {
            store.unmarkSessionDisliked(aid: 1001, bvid: "BV1Dislike1001")
        }
        toastCenter.performUndo()
        #expect(!store.shouldHideVideo(
            aid: 1001, bvid: "BV1Dislike1001", mid: 1, title: "Title", includeCloudBlocklist: false
        ))

        let added = try #require(store.blockVideo(aid: 2002, bvid: "BV1Hide2002", title: "Hide Me"))
        #expect(store.shouldHideVideo(
            aid: 2002, bvid: "BV1Hide2002", mid: 1, title: "Hide Me", includeCloudBlocklist: false
        ))
        toastCenter.show(message: "已本地屏蔽该视频", undoLabel: "撤销") {
            store.unblockVideo(id: added.id)
        }
        toastCenter.performUndo()
        #expect(!store.shouldHideVideo(
            aid: 2002, bvid: "BV1Hide2002", mid: 1, title: "Hide Me", includeCloudBlocklist: false
        ))
    }

    @Test("Observer notifications fire synchronously on rule mutation and stop when owner deallocates")
    @MainActor
    func observerNotificationsAndWeakCleanup() throws {
        let env = try Self.makeIsolatedStore()
        defer { env.cleanup() }
        let store = env.store

        final class Spy {
            var count = 0
        }

        weak var weakSpy: Spy?
        do {
            let spy = Spy()
            weakSpy = spy
            store.addObserver(spy) { owner in
                owner.count += 1
            }

            store.blockUP(mid: 77, name: "ObservedUP")
            #expect(spy.count == 1)

            store.unblockUP(mid: 77)
            #expect(spy.count == 2)
        }

        #expect(weakSpy == nil)
        store.blockUP(mid: 78, name: "AfterDealloc")
        #expect(store.isUPBlockedLocally(78))
    }
}
