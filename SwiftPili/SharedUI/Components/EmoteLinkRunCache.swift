import Foundation
import os

/// Synchronous reuse of the pure splitter result, before Text or styling exists.
/// Limits count logical UTF-8 key/run strings, including absolute destinations;
/// they do not describe RSS, Foundation object overhead, or temporary miss work.
final class EmoteLinkRunCache: Sendable {
    static let shared = EmoteLinkRunCache()

    struct Snapshot: Equatable, Sendable {
        let entryCount: Int
        let logicalBytes: Int
    }

    private struct Key: Hashable, Sendable {
        // String equality folds canonically equivalent Unicode spellings. UTF-8
        // identity keeps the caller's literal spelling intact even on a hit.
        let text: Data
        // Dictionary identity is independent of source-map insertion order.
        let destinations: [Data: Data]

        init(_ text: String, links: [String: URL]) {
            self.text = Data(text.utf8)
            destinations = Dictionary(uniqueKeysWithValues: links.lazy.map {
                (Data($0.key.utf8), Data($0.value.absoluteString.utf8))
            })
        }

        var logicalBytes: Int {
            text.count + destinations.reduce(0) { $0 + $1.key.count + $1.value.count }
        }
    }

    private struct Entry: Sendable {
        let runs: [EmoteText.LinkRun]
        let logicalBytes: Int
    }

    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        // FIFO admission order: hits do not reorder or scan this bounded array.
        var order: [Key] = []
        var logicalBytes = 0
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
        let key = Key(text, links: links)
        let keyBytes = key.logicalBytes
        // A key that cannot fit can never hit; avoid hashing oversized payloads
        // under the lock, while still returning the original splitter output.
        guard maxEntries > 0, keyBytes <= maxEntryLogicalBytes,
              keyBytes <= maxLogicalBytes else { return split(text, links) }
        if let hit = state.withLock({ $0.entries[key]?.runs }) { return hit }

        // Never run the splitter under the cache lock. Concurrent cold callers
        // may compute the same result; the second store does not charge it twice.
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
                let oldest = resident.order.removeFirst()
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
