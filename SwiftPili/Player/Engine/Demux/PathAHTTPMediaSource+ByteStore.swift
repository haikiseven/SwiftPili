import Foundation

/// `PATHA_BYTE_CACHE=0` rolls the Demand byte-range store back to today's
/// reads, byte for byte: no source consults it and nothing is admitted.
///
/// Only the explicit `0` disables it — any other value, or none, keeps the
/// product behaviour, the same rule `PATHA_AUDIO_ASYNC_START=0` and
/// `PATHA_AUDIO_HW=0` use. Read once per process, like the other `PATHA_`
/// switches: flipping it takes a relaunch.
enum PathAByteCacheSwitch {
    static let environmentKey = "PATHA_BYTE_CACHE"

    static func store(environment: [String: String]) -> MediaByteRangeStore? {
        ExperimentalSettingsPolicy.diagnosticsEnabled && environment[environmentKey] == "0"
            ? nil : MediaByteRangeStore.shared
    }

    /// The store the progressive (VOD) fMP4 path reads through. HLS never
    /// builds a `PathAHTTPMediaSource`, and file sources bypass it by scheme.
    static let vodStore: MediaByteRangeStore? = store(environment: ProcessInfo.processInfo.environment)
}

/// One source's view of `MediaByteRangeStore`: the store plus the key its
/// resource resolved to once `initialHead` learned the content length.
///
/// Every method is a hop into the store actor. Callers in
/// `PathAHTTPMediaSource` make these hops either BEFORE they read or write any
/// chunk-slot state, or as the LAST step after all of it — never between —
/// so an interleaving job can never observe or clobber a half-built slot.
struct PathAByteStoreBinding: Sendable {
    /// Held bytes reach the chunk-stream consumer in pieces no larger than
    /// this, so a fragment served from memory stops at the pump's content
    /// budget with the same granularity as network chunks (and as the
    /// 256 KiB primed head), instead of as one multi-megabyte chunk.
    static let heldPieceLimit = 256 * 1024

    let store: MediaByteRangeStore
    let key: MediaByteRangeStore.Key

    /// `nil` when there is no store (kill switch, test default, HLS) or the
    /// resource has no key: a file URL, or a length the response did not
    /// prove (a `206` without `Content-Range`).
    init?(store: MediaByteRangeStore?, url: URL, contentLength: Int64?) {
        guard let store, let contentLength,
              let key = MediaByteRangeStore.Key.key(for: url, contentLength: contentLength) else { return nil }
        self.store = store
        self.key = key
    }

    /// A response describes this key's resource only when its proven total
    /// equals the length the key was built from. A missing proof never admits.
    func admits(resourceLength: Int64?) -> Bool {
        resourceLength == key.contentLength
    }

    /// Sizes the store's budgets from the memory available now (once per
    /// source, at open) and admits the head window the open downloaded.
    func bindOpened(head: Data) async {
        await store.configure(.current())
        await admit(offset: 0, data: head)
    }

    /// Wait only for the requested missing bytes. Callers share one absolute
    /// deadline across progress wakeups, and recheck cache before takeover.
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

    /// The whole of `[offset, offset + count)` if held, or a shorter answer
    /// only when it ends exactly at the resource end — the same short read
    /// a `206` bounded by a proved total would have produced. A short read is
    /// the demuxer's EOF signal, so a merely partial hit is never returned.
    func window(offset: Int64, count: Int) async -> Data? {
        await store.noteRead(key, offset: offset)
        guard let held = await store.prefix(key, offset: offset, count: count) else { return nil }
        if held.count == count { return held }
        guard let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(held.count)),
              end == key.contentLength else { return nil }
        return held
    }

    /// The held bytes a chunk stream over `[offset, offset + count)` takes
    /// from memory after the `primedCount` bytes the primed head already
    /// supplies, capped so the prefix and the head together never exceed
    /// `limit` — the slot's back-pressure high-water. Without the cap a 12 MB
    /// fragment would sit in the slot's queue while the store holds the same
    /// bytes; with it, the rest is pulled from the store as the queue drains.
    func streamPrefix(
        offset: Int64, count: Int, after primedCount: Int, limit: Int,
        displayOwner: MediaDisplayByteOwner? = nil
    ) async -> [Data] {
        let want = min(count, limit) - primedCount
        guard want > 0,
              let cacheOffset = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(primedCount))
        else { return [] }
        return await heldPieces(offset: cacheOffset, count: want, displayOwner: displayOwner)
    }

    /// The leading held bytes of `[offset, offset + count)`, in pieces of at
    /// most `heldPieceLimit`. Stops at the first byte not held; an eviction
    /// between pieces only shortens the answer, and every piece returned is
    /// still the resource's own bytes.
    func heldPieces(
        offset: Int64, count: Int, displayOwner: MediaDisplayByteOwner? = nil
    ) async -> [Data] {
        await store.noteRead(key, offset: offset)
        var pieces: [Data] = []
        var cursor = offset
        var remaining = count
        while remaining > 0 {
            let want = min(remaining, Self.heldPieceLimit)
            guard let piece = await store.prefix(key, offset: cursor, count: want, displayOwner: displayOwner),
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

    /// Stores delivered, validated bytes at their logical offset. The reader
    /// is noted first, so the back-buffer trim inside `admit` measures
    /// "behind" from where reading is now — after a backward seek, a stale
    /// forward position would otherwise make the bytes just admitted the
    /// furthest behind and the first trimmed.
    func admit(offset: Int64, data: Data) async {
        guard !data.isEmpty else { return }
        await store.noteRead(key, offset: offset)
        await store.admit(key, offset: offset, data: data)
    }
}

/// Counts chunk-stream deliveries that have left URLSession's delegate queue
/// but not yet finished their hop into the source actor — and so, when the
/// source is bound to a store, not yet finished their admission.
///
/// A consumer receives a chunk BEFORE that chunk's admission lands (the
/// delivery hands the bytes over, then awaits the store), so "the demuxer has
/// the bytes" does not imply "the store has them". `settled()` is the
/// deterministic barrier between the two: `begin()` runs synchronously on the
/// delegate queue before the hop is even created, so every byte any consumer
/// has seen is already counted, and `settled()` returns only once each of
/// those hops — admitted, or rejected as stale — has run to completion.
/// Production never waits on it; it exists so tests can assert store contents
/// without polling. A lock, not an actor: `begin()` must be synchronous.
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

    /// Returns once no delivery hop is in flight.
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
