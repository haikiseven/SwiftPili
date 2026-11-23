import Foundation

enum PathAByteCacheSwitch {
    static let environmentKey = "PATHA_BYTE_CACHE"

    static func store(environment: [String: String]) -> MediaByteRangeStore? {
        ExperimentalSettingsPolicy.diagnosticsEnabled && environment[environmentKey] == "0"
            ? nil : MediaByteRangeStore.shared
    }

    static let vodStore: MediaByteRangeStore? = store(environment: ProcessInfo.processInfo.environment)
}

struct PathAByteStoreBinding: Sendable {
    static let heldPieceLimit = 256 * 1024

    let store: MediaByteRangeStore
    let key: MediaByteRangeStore.Key

    init?(store: MediaByteRangeStore?, url: URL, contentLength: Int64?) {
        guard let store, let contentLength,
              let key = MediaByteRangeStore.Key.key(for: url, contentLength: contentLength) else { return nil }
        self.store = store
        self.key = key
    }

    func admits(resourceLength: Int64?) -> Bool {
        resourceLength == key.contentLength
    }

    func bindOpened(head: Data) async {
        await store.configure(.current())
        await admit(offset: 0, data: head)
    }

    func awaitClaims(
        offset: Int64, count: Int, timeout: TimeInterval = 1.5,
        waitBudget: MediaSourceWaitBudget? = nil
    ) async -> MediaByteRangeStore.ClaimWaitResult {
        guard let range = claimRange(offset: offset, count: count) else { return .none }
        let result = await store.awaitClaims(key, range: range, timeout: timeout, waitBudget: waitBudget)
        if result == .released || result == .timedOut {
            PlayerLog.log("[Prefetch] dedup result=\(result) off=\(offset) count=\(count)")
        }
        return result
    }

    func span(offset: Int64, end: Int64) async -> Range<Int64>? {
        await store.span(key, at: offset, through: min(end, key.contentLength))
    }

    func claimForSource(offset: Int64, count: Int) -> MediaByteRangeStore.ClaimToken? {
        guard let range = claimRange(offset: offset, count: count) else { return nil }
        return store.claimForSource(key, range: range)
    }

    private func claimRange(offset: Int64, count: Int) -> Range<Int64>? {
        guard let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(count)),
              offset < key.contentLength else { return nil }
        return offset..<min(end, key.contentLength)
    }

    func window(offset: Int64, count: Int) async -> Data? {
        await store.noteRead(key, offset: offset)
        guard let held = await store.prefix(key, offset: offset, count: count) else { return nil }
        if held.count == count { return held }
        guard let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(held.count)),
              end == key.contentLength else { return nil }
        return held
    }

    func streamPrefix(
        offset: Int64, count: Int, after primedCount: Int, limit: Int
    ) async -> [Data] {
        let want = min(count, limit) - primedCount
        guard want > 0,
              let cacheOffset = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(primedCount))
        else { return [] }
        return await heldPieces(offset: cacheOffset, count: want)
    }

    func heldPieces(
        offset: Int64, count: Int
    ) async -> [Data] {
        await store.noteRead(key, offset: offset)
        var pieces: [Data] = []
        var cursor = offset
        var remaining = count
        while remaining > 0 {
            let want = min(remaining, Self.heldPieceLimit)
            guard let piece = await store.prefix(key, offset: cursor, count: want),
                  !piece.isEmpty,
                  let next = MediaByteRange.checkedEndExclusive(offset: cursor, length: Int64(piece.count))
            else { break }
            pieces.append(piece)
            cursor = next
            remaining -= piece.count
            if piece.count < want { break }
        }
        return pieces
    }

    func admit(offset: Int64, data: Data, noteRead: Bool = true) async {
        guard !data.isEmpty else { return }
        if noteRead { await store.noteRead(key, offset: offset) }
        await store.admit(key, offset: offset, data: data)
    }
}

final class PathAByteStoreAdmissionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() {
        lock.lock()
        inFlight += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        inFlight -= 1
        let ready = inFlight == 0 ? waiters : []
        if inFlight == 0 { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    func settled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if inFlight == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
