import Foundation
import os

actor MediaByteRangeStore {
    static let shared = MediaByteRangeStore(caps: .current())

    struct ResidentRun: Sendable {
        let byteCount: Int64
        let validity: ResidentValidity
    }

    static let defaultBlockLimit = 1 << 20

    static let bootstrapRecordLimit = 4

    let blockLimit: Int

    nonisolated let admissionLedger = PathAByteStoreAdmissionLedger()
    nonisolated let rangeClaims = MediaByteRangeClaims()

    struct Key: Hashable, Sendable {
        let path: String
        let contentLength: Int64

        fileprivate init(path: String, contentLength: Int64) {
            self.path = path
            self.contentLength = contentLength
        }

        static func key(for url: URL, contentLength: Int64) -> Key? {
            guard contentLength > 0, let path = networkPath(for: url) else { return nil }
            return Key(path: path, contentLength: contentLength)
        }

        static func networkPath(for url: URL) -> String? {
            guard !url.isFileURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty,
                  let path = canonicalPath(url.path) else { return nil }
            return path
        }

        private static func canonicalPath(_ path: String) -> String? {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { return nil }
            if let anchor = components.firstIndex(of: "upgcxcode") {
                return components[anchor...].joined(separator: "/")
            }
            return path
        }
    }

    struct Caps: Sendable, Equatable {
        let totalBytes: Int64
        let backBytesPerKey: Int64

        static let totalCeiling: Int64 = 256 << 20
        static let backCeiling: Int64 = 64 << 20

        init(totalBytes: Int64, backBytesPerKey: Int64) {
            self.totalBytes = max(totalBytes, 0)
            self.backBytesPerKey = max(min(backBytesPerKey, self.totalBytes), 0)
        }

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
        case rejected
        case conflictDropped
    }

    private(set) var caps: Caps
    var entries: [String: Entry] = [:]
    var residentObservers: [UUID: ResidentObserver] = [:]
    var bootstrapRecords: [MediaBootstrapIdentity: BootstrapRecord] = [:]
    private var activePathRegistrations: [UUID: Set<String>] = [:]
    private var useClock: UInt64 = 0
    private(set) var dupBytes: Int64 = 0

    private var protectedActivePaths: Set<String> {
        activePathRegistrations.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

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

    var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    func byteCount(for key: Key) -> Int64 {
        entry(for: key)?.byteCount ?? 0
    }

    func segmentRanges(for key: Key) -> [Range<Int64>] {
        entry(for: key)?.coalescedRanges ?? []
    }

    func prefix(_ key: Key, offset: Int64, count: Int) -> Data? {
        guard count > 0, offset >= 0, let entry = entry(for: key),
              let data = entry.copyPrefix(offset: offset, count: count) else { return nil }
        entries[key.path]?.lastUse = tick()
        return data
    }

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

    func residentRun(_ key: Key, from offset: Int64, matchingPrefix: Data? = nil) -> ResidentRun? {
        guard offset >= 0, let entry = entry(for: key) else { return nil }
        let count = entry.contiguousCount(from: offset)
        guard count > 0,
              let end = MediaByteRange.checkedEndExclusive(offset: offset, length: count) else { return nil }
        if let matchingPrefix {
            guard count >= Int64(matchingPrefix.count),
                  entry.agrees(with: matchingPrefix, at: offset) else { return nil }
        }
        guard let validity = entry.residentIncarnation.issue(for: offset..<end) else { return nil }
        return ResidentRun(byteCount: count, validity: validity)
    }

    func noteRead(_ key: Key, offset: Int64) {
        guard offset >= 0, entry(for: key) != nil else { return }
        entries[key.path]?.lastReadOffset = offset
        entries[key.path]?.lastUse = tick()
    }

    @discardableResult
    func admit(_ key: Key, offset: Int64, data: Data) -> AdmitOutcome {
        admit(key, offset: offset, data: data, heldCap: effectiveHeldCap)
    }

    private func admit(_ key: Key, offset: Int64, data: Data, heldCap: Int64) -> AdmitOutcome {
        guard !data.isEmpty,
              let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(data.count)),
              end <= key.contentLength else { return .rejected }
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

    @discardableResult
    func admitClaimedPrefix(_ key: Key, offset: Int64, data: Data, claim: ClaimToken) -> AdmitOutcome {
        guard let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(data.count)) else {
            return .rejected
        }
        return rangeClaims.withClaimedPrefix(claim, key: key, range: offset..<end) { reserved in
            admit(key, offset: offset, data: data, heldCap: max(0, caps.totalBytes - reserved))
        }
    }

    func setAheadBudget(_ key: Key, bytes: Int64) {
        guard entry(for: key) != nil else { return }
        entries[key.path]?.aheadBudget = max(0, min(bytes, forwardCapCeiling))
        evictToTotalCap(protecting: key.path)
    }

    func purgeAll() {
        rangeClaims.cancelAll()
        let paths = Array(entries.keys)
        for entry in entries.values { entry.residentIncarnation.revokeAll() }
        entries.removeAll()
        bootstrapRecords.removeAll()
        for path in paths { notifyResidentChange(at: path) }
    }

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
