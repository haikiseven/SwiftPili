import Foundation
import os

final class EmoteLinkRunCache: Sendable {
    static let shared = EmoteLinkRunCache()

    struct Snapshot: Equatable, Sendable {
        let entryCount: Int
        let logicalBytes: Int
    }

    private struct Key: Hashable, Sendable {
        let text: String
        let links: [String: URL]

        var logicalBytes: Int {
            text.utf8.count + links.reduce(0) { $0 + $1.key.utf8.count + $1.value.absoluteString.utf8.count }
        }
    }

    private struct Entry: Sendable {
        let runs: [EmoteText.LinkRun]
        let logicalBytes: Int
    }

    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        var order: [Key] = []
        var orderHead = 0
        var logicalBytes = 0

        mutating func popOldest() -> Key? {
            guard orderHead < order.count else { return nil }
            let oldest = order[orderHead]
            orderHead += 1
            if orderHead >= 64, orderHead * 2 >= order.count {
                order.removeFirst(orderHead)
                orderHead = 0
            }
            return oldest
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maxEntries: Int
    private let maxLogicalBytes: Int
    private let maxEntryLogicalBytes: Int
    private let split: @Sendable (String, [String: URL]) -> [EmoteText.LinkRun]

    init(
        maxEntries: Int = 128,
        maxLogicalBytes: Int = 512 * 1024,
        maxEntryLogicalBytes: Int = 32 * 1024,
        split: @escaping @Sendable (String, [String: URL]) -> [EmoteText.LinkRun] = {
            EmoteText.linkRuns($0, links: $1)
        }
    ) {
        self.maxEntries = max(0, maxEntries)
        self.maxLogicalBytes = max(0, maxLogicalBytes)
        self.maxEntryLogicalBytes = max(0, maxEntryLogicalBytes)
        self.split = split
    }

    var snapshot: Snapshot {
        state.withLock { Snapshot(entryCount: $0.entries.count, logicalBytes: $0.logicalBytes) }
    }

    func runs(_ text: String, links: [String: URL]) -> [EmoteText.LinkRun] {
        guard !text.isEmpty else { return [] }
        guard !links.isEmpty else { return [EmoteText.LinkRun(text: text, url: nil)] }
        let key = Key(text: text, links: links)
        let keyBytes = key.logicalBytes
        guard maxEntries > 0, keyBytes <= maxEntryLogicalBytes,
              keyBytes <= maxLogicalBytes else { return split(text, links) }
        if let hit = state.withLock({ $0.entries[key]?.runs }) { return hit }

        let runs = split(text, links)
        let logicalBytes = keyBytes + runs.reduce(0) {
            $0 + $1.text.utf8.count + ($1.url?.absoluteString.utf8.count ?? 0)
        }
        guard logicalBytes <= maxEntryLogicalBytes,
              logicalBytes <= maxLogicalBytes else { return runs }
        let entry = Entry(runs: runs, logicalBytes: logicalBytes)
        state.withLock { resident in
            guard resident.entries[key] == nil else { return }
            while resident.entries.count >= maxEntries
                || resident.logicalBytes > maxLogicalBytes - logicalBytes {
                guard let oldest = resident.popOldest() else { break }
                if let removed = resident.entries.removeValue(forKey: oldest) {
                    resident.logicalBytes -= removed.logicalBytes
                }
            }
            resident.entries[key] = entry
            resident.order.append(key)
            resident.logicalBytes += logicalBytes
        }
        return runs
    }
}
