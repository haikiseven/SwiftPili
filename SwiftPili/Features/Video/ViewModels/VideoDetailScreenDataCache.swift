import Foundation

/// A warm reopen can reuse read-only response values without inheriting the
/// previous screen's player, comment requests, composer or interaction state.
struct VideoDetailScreenDataSnapshot: Sendable {
    struct Tags: Sendable {
        let cid: Int
        let values: [VideoTag]
    }

    let id: VideoID
    let accountSession: UUID
    let fetchedAt: ContinuousClock.Instant
    let info: VideoInfo
    let related: [VideoCard]
    let tags: Tags?

    /// Bound retained values, without truncating or changing an API result.
    var fitsCacheBudget: Bool {
        guard related.count <= 100, (tags?.values.count ?? 0) <= 100,
              (info.pages?.count ?? 0) <= 100, (info.descV2?.count ?? 0) <= 512,
              info.descLinks.count <= 256 else { return false }
        var budget = TextBudget()
        guard budget.admit([info.bvid, info.title, info.desc, info.pic, info.owner.name, info.owner.face])
        else { return false }
        for page in info.pages ?? [] where !budget.admit([page.part]) { return false }
        for node in info.descV2 ?? [] where !budget.admit([node.rawText]) { return false }
        for (label, url) in info.descLinks where !budget.admit([label, url.absoluteString]) { return false }
        for video in related {
            guard budget.admit([
                video.bvid, video.title, video.pic, video.cover43 ?? "", video.owner.name, video.owner.face
            ]) else { return false }
        }
        for tag in tags?.values ?? [] {
            guard budget.admit([tag.tagName, tag.tagType ?? "", tag.musicId ?? "", tag.jumpUrl ?? ""])
            else { return false }
        }
        return true
    }

    private struct TextBudget {
        private var remaining = 256 * 1024

        mutating func admit(_ values: [String]) -> Bool {
            for value in values {
                let bytes = value.utf8.count
                guard bytes <= remaining else { return false }
                remaining -= bytes
            }
            return true
        }
    }
}

@MainActor
enum VideoDetailScreenDataCache {
    private struct Entry {
        let snapshot: VideoDetailScreenDataSnapshot
        var lastAccess: ContinuousClock.Instant
    }

    private static let maximumEntries = 3
    private static var accountSession: UUID?
    private static var entries: [VideoID: Entry] = [:]

    static func snapshot(for id: VideoID) -> VideoDetailScreenDataSnapshot? {
        prune()
        guard var entry = entries[id] else { return nil }
        entry.lastAccess = .now
        entries[id] = entry
        return entry.snapshot
    }

    static func store(_ snapshot: VideoDetailScreenDataSnapshot) {
        prune()
        guard snapshot.accountSession == accountSession else { return }
        // A covered older screen may disappear after a newer same-video load.
        // Its release cannot replace or evict that newer response.
        if let existing = entries[snapshot.id], existing.snapshot.fetchedAt > snapshot.fetchedAt { return }
        guard snapshot.fetchedAt.duration(to: .now) <= VideoDetailReactivationPolicy.screenDataMaxAge,
              snapshot.fitsCacheBudget else {
            entries[snapshot.id] = nil
            return
        }
        entries[snapshot.id] = Entry(snapshot: snapshot, lastAccess: .now)
        if entries.count > maximumEntries,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries[oldest] = nil
        }
    }

    static func remove(id: VideoID, accountSession: UUID) {
        prune()
        guard self.accountSession == accountSession else { return }
        entries[id] = nil
    }

    private static func prune() {
        let currentAccount = AuthManager.shared.sessionGeneration
        if accountSession != currentAccount {
            entries.removeAll()
            accountSession = currentAccount
        }
        let now = ContinuousClock.now
        entries = entries.filter {
            $0.value.snapshot.fetchedAt.duration(to: now) <= VideoDetailReactivationPolicy.screenDataMaxAge
        }
    }
}
