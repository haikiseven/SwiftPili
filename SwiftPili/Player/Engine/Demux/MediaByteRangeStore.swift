import Foundation
import os

/// Process-wide, RAM-only store of media bytes the Demand pipeline has already
/// downloaded, keyed by the upos resource rather than by the signed URL.
///
/// Why it exists: every `open` builds fresh `PathAHTTPMediaSource` actors, and
/// every CDN host swap, quality round trip, cold reopen or backward seek
/// re-downloads bytes the process fetched moments ago. mpv answers the same
/// problem with `demuxer-max-back-bytes`; this store is that behaviour placed
/// BELOW the demuxer (shape (b) in
/// `.trellis/tasks/09-28-demand-in-buffer-seek/design.md`), so the existing
/// seek path — demux seek, clear, prime — runs unchanged and simply finds its
/// reads answered without the network.
///
/// It is a hint, never a source of truth: nothing here is required for
/// playback, anything may be evicted at any time, and a lookup that misses
/// takes today's network path. Admission is the caller's job to keep honest —
/// only delivered, validated, contiguous bytes may be admitted — and the store
/// adds two checks of its own: bytes past the key's content length are refused,
/// and bytes that disagree with what is already held for the same offsets drop
/// the whole key as corrupt instead of choosing a winner.
///
/// Storage is a sorted array of non-overlapping blocks of at most
/// `blockLimit` bytes per key. Adjacent blocks are one logical segment:
/// `prefix`, `residentRun`, and `segmentRanges` read straight across
/// them. Bounding the block size is what keeps trimming cheap: budgets are
/// enforced by dropping WHOLE blocks, never by copying the survivors of a
/// partly trimmed one, so a trim costs no memcpy at all. The price is
/// granularity — the back buffer and the total may each sit above their cap
/// by less than one block (`blockLimit`) — which is what mpv's own
/// packet-granular back buffer does too.
actor MediaByteRangeStore {
    static let shared = MediaByteRangeStore(caps: .current())

    struct ResidentRun: Sendable {
        let byteCount: Int64
        let validity: ResidentValidity
    }

    /// Default upper bound on one stored block. Large enough that a steady
    /// chunk stream coalesces into few blocks, small enough that the
    /// over-cap tolerance of whole-block trimming stays at 1 MiB.
    static let defaultBlockLimit = 1 << 20

    /// Only representations actually selected and fetched can register. This
    /// roster owns metadata, never a second head/extended-head payload cache.
    static let bootstrapRecordLimit = 4

    /// Upper bound on one stored block for this store; `defaultBlockLimit`
    /// in production, smaller in tests so budgets can be exercised with
    /// small fixtures.
    let blockLimit: Int

    /// Chunk-stream deliveries still on their way into this store. See
    /// `PathAByteStoreAdmissionLedger`.
    nonisolated let admissionLedger = PathAByteStoreAdmissionLedger()
    nonisolated let rangeClaims = MediaByteRangeClaims()

    /// Resource identity that outlives the signed URL.
    ///
    /// BiliBili's upos paths name the exact file — cid, quality and codec in
    /// `/upgcxcode/…/<cid>-1-<streamId>.m4s` — while the host (CDN re-pick,
    /// backup URL) and the query (`deadline=`/`upsig=` re-signing) change
    /// freely; PCDN additionally prefixes `/v1/resource/`. The P0 sample in the
    /// evaluation doc §7 confirmed every upos `backup_url` shares the path from
    /// `upgcxcode/` on, so that suffix is the key. `ParkedPlaybackTicket`
    /// makes the same path-canonical assumption for the same reason.
    ///
    /// The content length is part of the identity: a server-side re-encode
    /// under one path is a different resource, and its bytes must never be
    /// served for the other.
    struct Key: Hashable, Sendable {
        let path: String
        let contentLength: Int64

        fileprivate init(path: String, contentLength: Int64) {
            self.path = path
            self.contentLength = contentLength
        }

        /// The only constructor. `nil` for anything that is not a network
        /// resource with a known length: file URLs (offline playback reads the
        /// disk directly), non-http(s) schemes, a missing host or path, and a
        /// non-positive length.
        static func key(for url: URL, contentLength: Int64) -> Key? {
            guard contentLength > 0, let path = networkPath(for: url) else { return nil }
            return Key(path: path, contentLength: contentLength)
        }

        /// Response provenance must be retired even when today's response did
        /// not prove a total. This creates no byte key or length authority.
        static func networkPath(for url: URL) -> String? {
            guard !url.isFileURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty,
                  let path = canonicalPath(url.path) else { return nil }
            return path
        }

        /// Path from the first `upgcxcode` component on, or the full path when
        /// there is none. The two forms cannot collide: only the fallback
        /// keeps its leading `/`.
        private static func canonicalPath(_ path: String) -> String? {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { return nil }
            if let anchor = components.firstIndex(of: "upgcxcode") {
                return components[anchor...].joined(separator: "/")
            }
            return path
        }
    }

    /// Byte budgets, sized from the memory the process may still allocate.
    ///
    /// Scaled proportionally from `os_proc_available_memory()` (10% total, 3%
    /// back buffer) with high-RAM ceilings (256 MiB total, 64 MiB back) so
    /// low-RAM devices remain bounded while high-RAM 4K VOD retains full A/V
    /// forward headroom; memory warnings still call `purgeAll()`.
    struct Caps: Sendable, Equatable {
        let totalBytes: Int64
        let backBytesPerKey: Int64

        static let totalCeiling: Int64 = 256 << 20
        static let backCeiling: Int64 = 64 << 20

        init(totalBytes: Int64, backBytesPerKey: Int64) {
            self.totalBytes = max(totalBytes, 0)
            self.backBytesPerKey = max(min(backBytesPerKey, self.totalBytes), 0)
        }

        /// `availableMemory == 0` is what the simulator (and a process with no
        /// limit to report) returns; it means "unknown", not "none", so the
        /// ceilings apply.
        static func current(
            availableMemory: UInt64 = UInt64(os_proc_available_memory())
        ) -> Caps {
            guard availableMemory > 0 else {
                return Caps(totalBytes: totalCeiling, backBytesPerKey: backCeiling)
            }
            let total = Int64(clamping: availableMemory / 10)
            let back = Int64(clamping: availableMemory / 100 * 3)
            return Caps(
                totalBytes: min(totalCeiling, total),
                backBytesPerKey: min(backCeiling, back)
            )
        }
    }

    enum AdmitOutcome: Equatable, Sendable {
        case admitted
        /// Empty, negative, overflowing, or past the key's content length.
        case rejected
        /// Overlapping bytes disagreed with the held copy; the key was dropped.
        case conflictDropped
    }

    private(set) var caps: Caps
    // Actor-isolated implementation state shared with +Bootstrap. Every
    // bootstrap operation remains synchronous within this same actor turn.
    var entries: [String: Entry] = [:]
    /// Actor-isolated subscriptions shared with the residency extension.
    var residentObservers: [UUID: ResidentObserver] = [:]
    var bootstrapRecords: [MediaBootstrapIdentity: BootstrapRecord] = [:]
    private var activePathRegistrations: [UUID: Set<String>] = [:]
    private var useClock: UInt64 = 0
    private(set) var dupBytes: Int64 = 0

    private var protectedActivePaths: Set<String> {
        activePathRegistrations.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// Co-protects the active session's tracks (typically video + audio) from
    /// whole-entry LRU eviction while they share the store budget.
    func registerActivePaths(_ paths: Set<String>) -> UUID {
        let token = UUID()
        if !paths.isEmpty { activePathRegistrations[token] = paths }
        return token
    }

    func unregisterActivePaths(_ token: UUID) {
        activePathRegistrations[token] = nil
    }

    init(caps: Caps, blockLimit: Int = MediaByteRangeStore.defaultBlockLimit) {
        self.caps = caps
        self.blockLimit = max(blockLimit, 1)
    }

    deinit {
        for entry in entries.values { entry.residentIncarnation.revokeAll() }
    }

    /// Bytes held across every key.
    var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    /// Bytes held for `key`; 0 when absent or held under another length.
    func byteCount(for key: Key) -> Int64 {
        entry(for: key)?.byteCount ?? 0
    }

    /// The coalesced ranges held for `key`, ascending.
    func segmentRanges(for key: Key) -> [Range<Int64>] {
        entry(for: key)?.coalescedRanges ?? []
    }

    /// The LEADING contiguous bytes of `[offset, offset + count)` that are
    /// held — possibly fewer than `count`, `nil` when the first byte is absent.
    /// A caller with a short answer requests only the remainder, exactly as the
    /// source's primed-head handover already does.
    func prefix(
        _ key: Key, offset: Int64, count: Int, displayOwner: MediaDisplayByteOwner? = nil
    ) -> Data? {
        guard count > 0, offset >= 0, let entry = entry(for: key),
              let data = entry.copyPrefix(offset: offset, count: count) else { return nil }
        displayOwner?.hold(offset..<(offset + Int64(data.count)))
        entries[key.path]?.lastUse = tick()
        return data
    }

    /// Snapshot of the next held run or hole, bounded by the caller's window.
    /// A subsequent actor hop must recheck: eviction can invalidate a snapshot.
    func span(_ key: Key, at offset: Int64, through end: Int64) -> Range<Int64>? {
        guard offset >= 0, offset < end, end <= key.contentLength else { return nil }
        guard let entry = entry(for: key) else { return offset..<end }
        let index = entry.firstIndex(endingAfter: offset)
        guard index < entry.blocks.count else { return offset..<end }
        if entry.blocks[index].offset > offset {
            return offset..<min(end, entry.blocks[index].offset)
        }
        return offset..<(offset + entry.contiguousCount(from: offset, startingAt: index, maximumCount: end - offset))
    }

    /// Count and revocation authority come from the same actor turn. Additions
    /// preserve this lower bound; removals revoke only intersecting receipts.
    func residentRun(_ key: Key, from offset: Int64, matchingPrefix: Data? = nil) -> ResidentRun? {
        guard offset >= 0, let entry = entry(for: key) else { return nil }
        let count = entry.contiguousCount(from: offset)
        guard count > 0,
              let end = MediaByteRange.checkedEndExclusive(offset: offset, length: count) else { return nil }
        // Parsed metadata can come from an owned primed head. Bind it to this
        // exact resident incarnation, not a later same-key replacement.
        if let matchingPrefix {
            guard count >= Int64(matchingPrefix.count),
                  entry.agrees(with: matchingPrefix, at: offset) else { return nil }
        }
        guard let validity = entry.residentIncarnation.issue(for: offset..<end) else { return nil }
        return ResidentRun(byteCount: count, validity: validity)
    }

    /// Records the reader's position. Back-buffer trimming counts only bytes
    /// behind this offset, so it is what keeps the bytes about to be played.
    /// A key with nothing held is not created — the source notes reads after
    /// admitting or on a hit.
    func noteRead(_ key: Key, offset: Int64) {
        guard offset >= 0, entry(for: key) != nil else { return }
        entries[key.path]?.lastReadOffset = offset
        entries[key.path]?.lastUse = tick()
    }

    /// Stores delivered bytes at `offset`. Only the parts not already held are
    /// copied in; parts already held must match byte for byte.
    @discardableResult
    func admit(_ key: Key, offset: Int64, data: Data) -> AdmitOutcome {
        admit(key, offset: offset, data: data, heldCap: effectiveHeldCap)
    }

    private func admit(_ key: Key, offset: Int64, data: Data, heldCap: Int64) -> AdmitOutcome {
        guard !data.isEmpty,
              let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(data.count)),
              end <= key.contentLength else { return .rejected }
        // Taking the entry out of the dictionary keeps its blocks uniquely
        // referenced, so appending into the tail block does not copy it. A
        // held entry under another length is dropped here, never served.
        var entry = entries.removeValue(forKey: key.path) ?? Entry(contentLength: key.contentLength)
        if entry.contentLength != key.contentLength {
            entry.residentIncarnation.revokeAll()
            invalidateBootstrap(path: key.path)
            entry = Entry(contentLength: key.contentLength)
        }
        let overlap = entry.overlapByteCount(offset: offset, end: end)
        let duplicate = dupBytes.addingReportingOverflow(overlap)
        dupBytes = duplicate.overflow ? .max : duplicate.partialValue
        guard entry.agrees(with: data, at: offset) else {
            entry.residentIncarnation.revokeAll()
            invalidateBootstrap(path: key.path)
            notifyResidentChange(at: key.path)
            return .conflictDropped
        }
        entry.insertMissing(data, at: offset, blockLimit: blockLimit)
        entry.lastUse = tick()
        entries[key.path] = entry
        trimBackBuffer(path: key.path)
        evictToTotalCap(protecting: key.path, heldCap: heldCap)
        if Int64(data.count) > overlap { notifyResidentChange(at: key.path) }
        return .admitted
    }

    /// Reserve the full fragment before staging its nonoverlapping pieces.
    /// Reserved bytes reduce the held-byte ceiling across every coordinator.
    func claim(
        _ key: Key,
        range: Range<Int64>,
        reservationBytes: Int64? = nil,
        onCancel: @escaping @Sendable () -> Void = {}
    ) -> ClaimToken? {
        guard !segmentRanges(for: key).contains(where: { $0.overlaps(range) }),
              let token = rangeClaims.claim(
                key, range: range, reservationLimit: caps.totalBytes / 2,
                reservationBytes: reservationBytes, onCancel: onCancel
              ) else { return nil }
        evictToTotalCap(protecting: key.path)
        return token
    }

    private var effectiveHeldCap: Int64 {
        max(0, caps.totalBytes - rangeClaims.reservedBytes())
    }

    private var forwardCapCeiling: Int64 {
        (caps.totalBytes / 4) * 3 + ((caps.totalBytes % 4) * 3) / 4
    }

    /// Completed contiguous helper bytes transfer to storage before the claim
    /// shrinks. Failed writes retain authority and never wake success waiters.
    @discardableResult
    func admitClaimedPrefix(_ key: Key, offset: Int64, data: Data, claim: ClaimToken) -> AdmitOutcome {
        guard let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(data.count)) else {
            return .rejected
        }
        return rangeClaims.withClaimedPrefix(claim, key: key, range: offset..<end) { reserved in
            admit(key, offset: offset, data: data, heldCap: max(0, caps.totalBytes - reserved))
        }
    }

    /// Protect only a bounded forward window; protection affects eviction
    /// order and never permits bytes beyond the store's total budget.
    func setAheadBudget(_ key: Key, bytes: Int64) {
        guard entry(for: key) != nil else { return }
        entries[key.path]?.aheadBudget = max(0, min(bytes, forwardCapCeiling))
        evictToTotalCap(protecting: key.path)
    }

    /// Drops everything. Called on a memory warning: the store is a cache, and
    /// under pressure the decoded frames that are playing matter more.
    func purgeAll() {
        rangeClaims.cancelAll()
        let paths = Array(entries.keys)
        for entry in entries.values { entry.residentIncarnation.revokeAll() }
        entries.removeAll()
        bootstrapRecords.removeAll()
        for path in paths { notifyResidentChange(at: path) }
    }

    /// Replaces the budgets (re-sized at session open) and enforces them now.
    func configure(_ caps: Caps) {
        if caps.totalBytes < self.caps.totalBytes || caps.backBytesPerKey < self.caps.backBytesPerKey {
            bootstrapRecords.removeAll()
        }
        self.caps = caps
        rangeClaims.cancelPrefetchIfReservationsExceed(caps.totalBytes / 2)
        for path in entries.keys {
            trimBackBuffer(path: path)
        }
        evictToTotalCap(protecting: nil)
    }

    // MARK: - Enforcement

    /// Shared with bootstrap response-version retirement, still actor isolated.
    func revokeResidentEntry(at path: String) {
        entries[path]?.residentIncarnation.revokeAll()
        if entries[path] != nil { notifyResidentChange(at: path) }
    }

    func entry(for key: Key) -> Entry? {
        guard let entry = entries[key.path], entry.contentLength == key.contentLength else { return nil }
        return entry
    }

    func tick() -> UInt64 {
        useClock &+= 1
        return useClock
    }

    /// Keeps about `backBytesPerKey` behind the reader, dropping the bytes
    /// furthest behind first — mpv's back buffer. Whole blocks only: the
    /// bytes behind the reader may exceed the cap by less than `blockLimit`
    /// (the oldest block is dropped only once the excess covers all of it,
    /// and a block straddling the reader is never cut).
    private func trimBackBuffer(path: String) {
        guard var entry = entries.removeValue(forKey: path) else { return }
        let previousCount = entry.byteCount
        let excess = entry.bytesBehindRead - caps.backBytesPerKey
        entry.dropFrontBlocks(atMost: excess, endingBy: entry.lastReadOffset)
        if entry.byteCount != previousCount {
            entry.bootstrapVersion = UUID()
            invalidateBootstrap(path: path)
        }
        reinsert(entry, at: path)
        if entry.byteCount != previousCount { notifyResidentChange(at: path) }
    }

    /// Puts a trimmed entry back, unless trimming emptied it.
    private func reinsert(_ entry: Entry, at path: String) {
        guard entry.byteCount > 0 else {
            entry.residentIncarnation.revokeAll()
            invalidateBootstrap(path: path)
            return
        }
        entries[path] = entry
    }
}

private extension MediaByteRangeStore {
    /// Evicts whole inactive LRU entries first. When only `protected` and/or
    /// active co-protected tracks remain, trims blocks from the largest entry
    /// first instead of wiping the smaller active track (e.g. audio).
    func evictToTotalCap(protecting protected: String?, heldCap: Int64? = nil) {
        let ceiling = heldCap ?? effectiveHeldCap
        let activePaths = protectedActivePaths
        while totalBytes > ceiling {
            let victim = entries
                .filter { $0.key != protected && !activePaths.contains($0.key) && $0.value.byteCount > 0 }
                .min { $0.value.lastUse < $1.value.lastUse }?
                .key
            if let victim {
                revokeResidentEntry(at: victim)
                entries[victim] = nil
                invalidateBootstrap(path: victim)
                continue
            }
            guard let target = largestEntryPath(preferringNonProtected: protected),
                  trimEntryForTotalCap(path: target, ceiling: ceiling) else { return }
        }
    }

    func largestEntryPath(preferringNonProtected protected: String?) -> String? {
        entries.filter { $0.value.byteCount > 0 }.max { lhs, rhs in
            if lhs.value.byteCount != rhs.value.byteCount {
                return lhs.value.byteCount < rhs.value.byteCount
            }
            let lhsProtected = lhs.key == protected
            let rhsProtected = rhs.key == protected
            if lhsProtected != rhsProtected { return lhsProtected }
            return lhs.value.lastUse > rhs.value.lastUse
        }?.key
    }

    func trimEntryForTotalCap(path: String, ceiling: Int64) -> Bool {
        guard var entry = entries.removeValue(forKey: path) else { return false }
        let previousCount = entry.byteCount
        let excess = totalBytes + entry.byteCount - ceiling
        if entry.aheadBudget > 0 || ceiling < caps.totalBytes {
            let upper = MediaByteRange.checkedEndExclusive(
                offset: entry.lastReadOffset, length: min(entry.aheadBudget, forwardCapCeiling)
            ) ?? entry.contentLength
            entry.dropForAheadCap(excess: excess, protection: entry.lastReadOffset..<upper)
        } else {
            entry.dropFrontBlocks(atMost: excess, endingBy: .max)
        }
        let changed = entry.byteCount != previousCount
        if changed {
            entry.bootstrapVersion = UUID()
            invalidateBootstrap(path: path)
        }
        reinsert(entry, at: path)
        if changed { notifyResidentChange(at: path) }
        return changed
    }
}
