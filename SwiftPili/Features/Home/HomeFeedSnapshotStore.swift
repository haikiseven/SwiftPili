import Foundation
import os

struct HomeFeedSnapshotPayload: Codable, Sendable, Equatable {
    let accountScope: String
    let savedAt: Date
    let items: [SnapshotItem]

    struct SnapshotItem: Codable, Sendable, Equatable {
        let id: Int
        let bvid: String?
        let title: String
        let pic: String
        let pic4By3: String?
        let cover43: String?
        let duration: Int?
        let ownerMid: Int?
        let ownerName: String?
        let ownerFace: String?
        let viewCount: Int?
        let likeCount: Int?
        let danmakuCount: Int?
        let goto: String?
        let uri: String?
        let roomId: Int?

        init(item: RecommendResult.RecommendItem) {
            self.id = item.id
            self.bvid = item.bvid
            self.title = item.title
            self.pic = item.pic
            self.pic4By3 = item.pic4By3
            self.cover43 = item.cover43
            self.duration = item.duration
            self.ownerMid = item.owner?.mid
            self.ownerName = item.owner?.name
            self.ownerFace = item.owner?.face
            self.viewCount = item.stat?.view
            self.likeCount = item.stat?.like
            self.danmakuCount = item.stat?.danmaku
            self.goto = item.goto
            self.uri = item.uri
            self.roomId = item.roomId
        }

        func toRecommendItem() -> RecommendResult.RecommendItem {
            let owner: VideoInfo.VideoOwner?
            if let ownerMid, let ownerName, let ownerFace {
                owner = VideoInfo.VideoOwner(mid: ownerMid, name: ownerName, face: ownerFace)
            } else {
                owner = nil
            }
            let stat: RecommendResult.RecommendItem.RecommendStat?
            if viewCount != nil || likeCount != nil || danmakuCount != nil {
                stat = RecommendResult.RecommendItem.RecommendStat(
                    view: viewCount,
                    like: likeCount,
                    danmaku: danmakuCount
                )
            } else {
                stat = nil
            }
            return RecommendResult.RecommendItem(
                id: id,
                bvid: bvid,
                title: title,
                pic: pic,
                pic4By3: pic4By3,
                cover43: cover43,
                duration: duration,
                owner: owner,
                stat: stat,
                goto: goto,
                uri: uri,
                roomId: roomId
            )
        }
    }
}

final class HomeFeedSnapshotStore: Sendable {
    static let shared = HomeFeedSnapshotStore()
    static let defaultFileName = "HomeFeedSnapshot_v1.json"
    static let defaultMaxItemCount = 20
    static let defaultMaxAge: TimeInterval = 7 * 24 * 3600

    static var defaultFileURL: URL {
        URL.cachesDirectory.appendingPathComponent(defaultFileName)
    }

    static var currentAccountScope: String {
        AuthManager.shared.dedeUserID ?? "guest"
    }

    private struct CacheState: Sendable {
        var generation: UInt64 = 0
        var hasLoadedFromDisk = false
        var payload: HomeFeedSnapshotPayload?
    }

    private static let ioQueue = DispatchQueue(
        label: "com.swiftpili.home-feed-snapshot",
        qos: .utility
    )

    private let fileURL: URL
    private let maxItemCount: Int
    private let maxAge: TimeInterval
    private let stateLock = OSAllocatedUnfairLock(initialState: CacheState())

    init(
        fileURL: URL = HomeFeedSnapshotStore.defaultFileURL,
        maxItemCount: Int = HomeFeedSnapshotStore.defaultMaxItemCount,
        maxAge: TimeInterval = HomeFeedSnapshotStore.defaultMaxAge
    ) {
        self.fileURL = fileURL
        self.maxItemCount = max(1, maxItemCount)
        self.maxAge = maxAge
    }

    func load(
        forAccountScope accountScope: String = HomeFeedSnapshotStore.currentAccountScope,
        now: Date = Date()
    ) -> [RecommendResult.RecommendItem] {
        let fastState = stateLock.withLock { $0 }
        if fastState.hasLoadedFromDisk {
            guard let payload = fastState.payload else { return [] }
            if isUsable(payload, forAccountScope: accountScope, now: now) {
                return payload.items.prefix(maxItemCount).map { $0.toRecommendItem() }
            }
            clear()
            return []
        }

        return Self.ioQueue.sync {
            let current = stateLock.withLock { $0 }
            if current.hasLoadedFromDisk {
                guard let payload = current.payload else { return [] }
                if isUsable(payload, forAccountScope: accountScope, now: now) {
                    return payload.items.prefix(maxItemCount).map { $0.toRecommendItem() }
                }
                stateLock.withLock { state in
                    state.generation &+= 1
                    state.payload = nil
                    state.hasLoadedFromDisk = true
                }
                try? FileManager.default.removeItem(at: fileURL)
                return []
            }

            let readGeneration = current.generation
            guard let data = try? Data(contentsOf: fileURL),
                  let payload = try? JSONDecoder().decode(HomeFeedSnapshotPayload.self, from: data) else {
                stateLock.withLock { state in
                    if state.generation == readGeneration {
                        state.hasLoadedFromDisk = true
                        state.payload = nil
                    }
                }
                return []
            }

            guard isUsable(payload, forAccountScope: accountScope, now: now) else {
                try? FileManager.default.removeItem(at: fileURL)
                stateLock.withLock { state in
                    if state.generation == readGeneration {
                        state.hasLoadedFromDisk = true
                        state.payload = nil
                    }
                }
                return []
            }

            stateLock.withLock { state in
                if state.generation == readGeneration {
                    state.hasLoadedFromDisk = true
                    state.payload = payload
                }
            }
            return payload.items.prefix(maxItemCount).map { $0.toRecommendItem() }
        }
    }

    func save(
        _ items: [RecommendResult.RecommendItem],
        forAccountScope accountScope: String = HomeFeedSnapshotStore.currentAccountScope,
        now: Date = Date()
    ) {
        let snapshotItems = items.prefix(maxItemCount).map(HomeFeedSnapshotPayload.SnapshotItem.init(item:))
        guard !snapshotItems.isEmpty else { return }

        let payload = HomeFeedSnapshotPayload(
            accountScope: accountScope,
            savedAt: now,
            items: snapshotItems
        )
        let writeGeneration = stateLock.withLock { state -> UInt64 in
            state.generation &+= 1
            state.hasLoadedFromDisk = true
            state.payload = payload
            return state.generation
        }

        let targetURL = fileURL
        Self.ioQueue.async { [stateLock] in
            guard stateLock.withLock({ $0.generation }) == writeGeneration else { return }
            do {
                let directory = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(payload)
                guard stateLock.withLock({ $0.generation }) == writeGeneration else { return }
                try data.write(to: targetURL, options: .atomic)
            } catch {
                PlayerLog.log("[HomeSnapshot] save failed: \(error)")
            }
        }
    }

    func clear() {
        let clearGeneration = stateLock.withLock { state -> UInt64 in
            state.generation &+= 1
            state.hasLoadedFromDisk = true
            state.payload = nil
            return state.generation
        }
        let targetURL = fileURL
        Self.ioQueue.async { [stateLock] in
            guard stateLock.withLock({ $0.generation }) == clearGeneration else { return }
            try? FileManager.default.removeItem(at: targetURL)
        }
    }

    func waitForPendingIO() {
        Self.ioQueue.sync {}
    }

    private func isUsable(
        _ payload: HomeFeedSnapshotPayload,
        forAccountScope accountScope: String,
        now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(payload.savedAt)
        return payload.accountScope == accountScope && age >= 0 && age <= maxAge
    }
}
