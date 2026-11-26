import Foundation
import QuartzCore

@MainActor
final class DanmakuSegmentStore {
    private static var offlineDirectories: [Int: URL] = [:]

    static func registerOfflineDirectory(_ directoryURL: URL, forOID oid: Int) {
        guard oid > 0 else { return }
        offlineDirectories[oid] = directoryURL
    }

    static func unregisterOfflineDirectory(forOID oid: Int, matching directoryURL: URL? = nil) {
        if let directoryURL {
            guard offlineDirectories[oid]?.standardizedFileURL == directoryURL.standardizedFileURL else {
                return
            }
        }
        offlineDirectories.removeValue(forKey: oid)
    }

    static func offlineDirectory(forOID oid: Int) -> URL? {
        offlineDirectories[oid]
    }

    var offlineDirectoryURL: URL?
    var isOfflineOnly: Bool

    private(set) var segments: [Int: DanmakuTimeIndex] = [:]
    private var inFlight: [Int: (request: UInt64, task: Task<Void, Never>)] = [:]
    private var nextRequest: UInt64 = 0
    private(set) var failures: [Int: DanmakuSegmentFailureState] = [:]
    private(set) var selfSent: [DanmakuElem] = []
    private(set) var oid: Int?

    private(set) var pageSeconds = DanmakuSegmentWindow.segmentSeconds
    private(set) var isServerClosed = false
    var onMetadataChanged: (() -> Void)?
    var onSpecialLoaded: (() -> Void)?
    var onSegmentsLoaded: (() -> Void)?
    private let metadataOwner = DanmakuMetadataStore()
    private var localMetadataChecked = false
    private var localMetadataTask: Task<Void, Never>?
    private var latestPosition: (mediaTime: TimeInterval, duration: TimeInterval)?

    init(offlineDirectoryURL: URL? = nil, isOfflineOnly: Bool = false) {
        self.offlineDirectoryURL = offlineDirectoryURL
        self.isOfflineOnly = isOfflineOnly
        metadataOwner.onMetadata = { [weak self] in self?.acceptMetadata($0) }
        metadataOwner.onSpecialLoaded = { [weak self] in self?.onSpecialLoaded?() }
    }

    func reset(oid newOID: Int?) {
        cancelInFlight()
        localMetadataTask?.cancel()
        localMetadataTask = nil
        localMetadataChecked = false
        segments.removeAll()
        failures.removeAll()
        selfSent.removeAll()
        oid = newOID
        pageSeconds = DanmakuSegmentWindow.segmentSeconds
        isServerClosed = false
        latestPosition = nil
        metadataOwner.reset(oid: newOID)
    }

    func insertSelfSent(_ element: DanmakuElem) {
        var own = element
        own.isSelfSent = true
        selfSent.removeAll { $0.id == own.id }
        let slot = selfSent.firstIndex { $0.progress > own.progress } ?? selfSent.endIndex
        selfSent.insert(own, at: slot)
    }

    func suspend() {
        cancelInFlight()
        localMetadataTask?.cancel()
        localMetadataTask = nil
        metadataOwner.suspend()
        latestPosition = nil
    }

    private func acceptMetadata(_ metadata: DanmakuMetadata) {
        let page = metadata.pageSeconds ?? DanmakuSegmentWindow.segmentSeconds
        let changed = page != pageSeconds || metadata.isClosed != isServerClosed
        pageSeconds = page
        isServerClosed = metadata.isClosed
        guard changed else { return }
        cancelInFlight()
        segments.removeAll()
        failures.removeAll()
        if !isServerClosed, let position = latestPosition {
            advance(to: position.mediaTime, duration: position.duration)
        }
        onMetadataChanged?()
    }

    @discardableResult
    func resetRetryableFailures() -> Int {
        let now = CACurrentMediaTime()
        var reopened = metadataOwner.resetRetryableFailures()
        for (index, state) in failures where !state.isTerminal {
            failures[index] = state.resetForNetworkChange(at: now)
            reopened += 1
        }
        return reopened
    }

    private func cancelInFlight() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
    }

    func advance(to mediaTime: TimeInterval, duration: TimeInterval) {
        guard let oid else { return }
        latestPosition = (mediaTime, duration)
        if let offlineDir = resolvedOfflineDirectory(for: oid) {
            if !localMetadataChecked, localMetadataTask == nil {
                localMetadataTask = Task { [weak self] in
                    await self?.loadLocalMetadata(oid: oid, directory: offlineDir)
                }
            }
        } else if !isOfflineOnly {
            metadataOwner.advance()
        }
        guard !isServerClosed else { return }
        let now = CACurrentMediaTime()
        if windowIsQuiet(mediaTime: mediaTime, duration: duration, now: now) { return }
        let plan = DanmakuSegmentWindow.plan(
            mediaTime: mediaTime,
            duration: duration,
            loaded: Set(segments.keys),
            inFlight: Set(inFlight.keys),
            blocked: blocked(at: now),
            pageSeconds: pageSeconds
        )
        guard !plan.isQuiet else { return }

        for index in plan.cancel {
            inFlight.removeValue(forKey: index)?.task.cancel()
        }
        for index in plan.evict {
            segments.removeValue(forKey: index)
        }
        for index in plan.fetch {
            nextRequest &+= 1
            let request = nextRequest
            inFlight[index] = (request, Task { [weak self] in
                await self?.load(oid: oid, segmentIndex: index, request: request)
            })
        }
    }

    private func blocked(at now: TimeInterval) -> Set<Int> {
        Set(failures.lazy.filter { !$0.value.isEligible(at: now) }.map(\.key))
    }

    private func windowIsQuiet(
        mediaTime: TimeInterval,
        duration: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        let current = DanmakuSegmentWindow.index(for: mediaTime, pageSeconds: pageSeconds)
        let last = DanmakuSegmentWindow.lastIndex(duration: duration, pageSeconds: pageSeconds)
        var indices = (0, 0, 0)
        var count = 0
        func keep(_ index: Int) {
            let visible = last.map { index >= 1 && index <= $0 } ?? (index >= 1)
            guard visible, count < 3 else { return }
            switch count {
            case 0: indices.0 = index
            case 1: indices.1 = index
            default: indices.2 = index
            }
            count += 1
        }
        keep(current)
        if current > 1 { keep(current - 1) }
        let segmentEnd = TimeInterval(current) * pageSeconds
        if mediaTime >= segmentEnd - DanmakuSegmentWindow.prefetchLeadSeconds {
            let next = current + 1
            if last.map({ next <= $0 }) ?? true {
                keep(next)
            }
        }
        func settlement(_ index: Int) -> Int {
            if segments[index] != nil || inFlight[index] != nil { return 1 }
            if let failure = failures[index], !failure.isEligible(at: now) { return 2 }
            return 0
        }
        var blockedOnly = 0
        for slot in 0 ..< count {
            let index = slot == 0 ? indices.0 : (slot == 1 ? indices.1 : indices.2)
            switch settlement(index) {
            case 0: return false
            case 2: blockedOnly += 1
            default: break
            }
        }
        return segments.count + inFlight.count == count - blockedOnly
    }

    func elements(from: TimeInterval, to: TimeInterval) -> [DanmakuElem] {
        guard from < to, !isServerClosed else { return [] }
        let hasPackages = !metadataOwner.packages.isEmpty
        let hasSelfSent = !selfSent.isEmpty
        if segments.isEmpty, !hasPackages, !hasSelfSent { return [] }

        var out: [DanmakuElem] = []
        if segments.count == 1, let segment = segments.values.first {
            let slice = segment.elements(from: from, to: to)
            if !slice.isEmpty {
                out.reserveCapacity(slice.count)
                out.append(contentsOf: slice)
            }
        } else if !segments.isEmpty {
            for index in segments.keys.sorted() {
                guard let segment = segments[index] else { continue }
                let slice = segment.elements(from: from, to: to)
                if !slice.isEmpty { out.append(contentsOf: slice) }
            }
        }
        if hasPackages {
            if metadataOwner.packages.count == 1, let package = metadataOwner.packages.values.first {
                let slice = package.elements(from: from, to: to)
                if !slice.isEmpty { out.append(contentsOf: slice) }
            } else {
                for url in metadataOwner.packages.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
                    guard let package = metadataOwner.packages[url] else { continue }
                    let slice = package.elements(from: from, to: to)
                    if !slice.isEmpty { out.append(contentsOf: slice) }
                }
            }
        }
        if hasSelfSent {
            let ownIDs = Set(selfSent.compactMap(\.identityKey))
            if !ownIDs.isEmpty, !out.isEmpty {
                out.removeAll { $0.identityKey.map(ownIDs.contains) ?? false }
            }
            for item in selfSent where item.progress >= from && item.progress < to {
                out.append(item)
            }
        }
        guard out.count > 1 else { return out }

        var seenIDs = Set<String>(minimumCapacity: out.count)
        var writeIndex = 0
        var isSorted = true
        var previousProgress = -TimeInterval.infinity
        for readIndex in 0 ..< out.count {
            let item = out[readIndex]
            if let key = item.identityKey, !seenIDs.insert(key).inserted {
                continue
            }
            if item.progress < previousProgress {
                isSorted = false
            }
            previousProgress = item.progress
            if writeIndex != readIndex {
                out[writeIndex] = item
            }
            writeIndex += 1
        }
        if writeIndex < out.count {
            out.removeSubrange(writeIndex ..< out.count)
        }
        if !isSorted {
            out.sort { $0.progress < $1.progress }
        }
        return out
    }

    func admitCursor(from: TimeInterval, to: TimeInterval) -> TimeInterval {
        guard from < to, from.isFinite, to.isFinite else { return from }
        guard !isServerClosed else { return to }
        let upper = to.nextDown
        guard upper.isFinite else { return from }
        var index = DanmakuSegmentWindow.index(for: from, pageSeconds: pageSeconds)
        let last = DanmakuSegmentWindow.index(for: max(from, upper), pageSeconds: pageSeconds)
        let cap = segments.count + failures.count
        var steps = 0
        while index <= last, steps <= cap {
            if segments[index] == nil, failures[index] == nil {
                let start = TimeInterval(index - 1) * pageSeconds
                return max(from, start)
            }
            if index == last { return to }
            index += 1
            steps += 1
        }
        let start = TimeInterval(index - 1) * pageSeconds
        return min(to, max(from, start))
    }

    // MARK: - Loading

    private func resolvedOfflineDirectory(for oid: Int) -> URL? {
        offlineDirectoryURL ?? Self.offlineDirectories[oid]
    }

    private func loadLocalMetadata(oid: Int, directory: URL) async {
        defer { localMetadataTask = nil }
        let data = await Self.readOfflineMetadataData(in: directory)
        guard !Task.isCancelled, self.oid == oid else { return }
        localMetadataChecked = true
        guard let data, !data.isEmpty else { return }
        let decoded: DanmakuMetadata? = await Task.detached(priority: .utility) {
            try? DanmakuMetadataDecoder.decode(data)
        }.value
        guard !Task.isCancelled, self.oid == oid, let decoded else { return }
        acceptMetadata(decoded)
    }

    nonisolated static func resolveOfflineSegmentFileURL(
        in directory: URL,
        segmentIndex: Int
    ) -> URL? {
        guard segmentIndex >= 1 else { return nil }
        let nested = DownloadStore.danmakuSegmentURL(in: directory, segmentIndex: segmentIndex)
        if isUsableLocalFile(nested) {
            return nested
        }
        let direct = directory.appendingPathComponent("seg_\(segmentIndex).pb")
        if isUsableLocalFile(direct) {
            return direct
        }
        return nil
    }

    nonisolated static func resolveOfflineMetadataFileURL(in directory: URL) -> URL? {
        let nested = DownloadStore.danmakuMetadataURL(in: directory)
        if isUsableLocalFile(nested) {
            return nested
        }
        let direct = directory.appendingPathComponent("metadata.pb")
        if isUsableLocalFile(direct) {
            return direct
        }
        return nil
    }

    private nonisolated static func isUsableLocalFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            return false
        }
        return true
    }

    private nonisolated static func readOfflineSegmentData(
        in directory: URL,
        segmentIndex: Int
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let fileURL = resolveOfflineSegmentFileURL(
                in: directory,
                segmentIndex: segmentIndex
            ) else { return nil }
            return try? Data(contentsOf: fileURL)
        }.value
    }

    private nonisolated static func readOfflineMetadataData(in directory: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let fileURL = resolveOfflineMetadataFileURL(in: directory) else { return nil }
            return try? Data(contentsOf: fileURL)
        }.value
    }

    private func load(oid: Int, segmentIndex: Int, request: UInt64) async {
        defer {
            if inFlight[segmentIndex]?.request == request {
                inFlight.removeValue(forKey: segmentIndex)
            }
        }
        if let offlineDir = resolvedOfflineDirectory(for: oid) {
            let localData = await Self.readOfflineSegmentData(
                in: offlineDir,
                segmentIndex: segmentIndex
            )
            guard accepts(oid: oid, segmentIndex: segmentIndex, request: request) else { return }
            if let localData, !localData.isEmpty {
                let decoded = await Self.decode(localData, segmentIndex: segmentIndex)
                guard accepts(oid: oid, segmentIndex: segmentIndex, request: request) else { return }
                switch decoded {
                case .success(let index):
                    failures.removeValue(forKey: segmentIndex)
                    segments[segmentIndex] = index
                    PlayerLog.log(
                        "[Danmaku] segment \(segmentIndex): \(index.count) bullets "
                            + "bytes=\(localData.count) source=offline-disk"
                    )
                    onSegmentsLoaded?()
                case .failure(let error):
                    recordFailure(
                        .malformed,
                        segmentIndex: segmentIndex,
                        evidence: "source=offline-disk bytes=\(localData.count) error=\(error)"
                    )
                }
                return
            }
            if isOfflineOnly {
                failures.removeValue(forKey: segmentIndex)
                segments[segmentIndex] = DanmakuTimeIndex([])
                return
            }
        } else if isOfflineOnly {
            failures.removeValue(forKey: segmentIndex)
            segments[segmentIndex] = DanmakuTimeIndex([])
            return
        }
        let response: DanmakuSegmentResponse
        do {
            response = try await DanmakuAPI.segment(oid: oid, segmentIndex: segmentIndex)
        } catch {
            guard accepts(oid: oid, segmentIndex: segmentIndex, request: request),
                  !Self.isCancellation(error) else { return }
            recordFailure(
                Self.failureKind(for: error),
                segmentIndex: segmentIndex,
                evidence: "bytes=- status=\(Self.status(of: error)) error=\(error)"
            )
            return
        }
        guard accepts(oid: oid, segmentIndex: segmentIndex, request: request) else { return }
        let evidence = "bytes=\(response.body.count) status=\(response.status)"
        switch DanmakuSegmentClassifier.classify(response) {
        case .failure(let kind):
            recordFailure(kind, segmentIndex: segmentIndex, evidence: evidence)
        case .protobuf:
            let decoded = await Self.decode(response.body, segmentIndex: segmentIndex)
            guard accepts(oid: oid, segmentIndex: segmentIndex, request: request) else { return }
            switch decoded {
            case .success(let index):
                failures.removeValue(forKey: segmentIndex)
                segments[segmentIndex] = index
                PlayerLog.log(
                    "[Danmaku] segment \(segmentIndex): \(index.count) bullets "
                        + "\(evidence) class=protobuf"
                )
                onSegmentsLoaded?()
            case .failure(let error):
                recordFailure(
                    .malformed,
                    segmentIndex: segmentIndex,
                    evidence: "\(evidence) error=\(error)"
                )
            }
        }
    }

    private func recordFailure(
        _ kind: DanmakuSegmentFailureKind,
        segmentIndex: Int,
        evidence: String
    ) {
        let now = CACurrentMediaTime()
        let state = DanmakuSegmentFailureState.recording(
            kind,
            after: failures[segmentIndex],
            at: now
        )
        failures[segmentIndex] = state
        let next: String
        if let eligible = state.nextEligibleAt {
            let wait = Int((eligible - now).rounded())
            next = state.attempts >= DanmakuSegmentRetryPolicy.maxAttempts
                ? "round exhausted, cool-down \(wait)s"
                : "retry in \(wait)s"
        } else {
            next = "no further attempts for this content"
        }
        PlayerLog.log(
            "[Danmaku] segment \(segmentIndex) failed \(evidence) class=\(kind) "
                + "attempt=\(state.attempts)/\(DanmakuSegmentRetryPolicy.maxAttempts) — \(next)"
        )
    }

    private func accepts(oid: Int, segmentIndex: Int, request: UInt64) -> Bool {
        !Task.isCancelled && self.oid == oid && !isServerClosed && inFlight[segmentIndex]?.request == request
    }
}

extension DanmakuSegmentStore {
    var metadata: DanmakuMetadata? { metadataOwner.metadata }

    func specialElements(from: TimeInterval, to end: TimeInterval) -> [DanmakuElem] {
        guard from < end, !isServerClosed, !metadataOwner.packages.isEmpty else { return [] }
        var out: [DanmakuElem] = []
        for package in metadataOwner.packages.values {
            let slice = package.elements(from: from, to: end)
            if !slice.isEmpty { out.append(contentsOf: slice) }
        }
        guard !out.isEmpty else { return [] }
        let own = selfSent.isEmpty ? Set<String>() : Set(selfSent.compactMap(\.identityKey))
        var seen = Set<String>(minimumCapacity: out.count)
        var writeIndex = 0
        var isSorted = true
        var previousProgress = -TimeInterval.infinity
        for readIndex in 0 ..< out.count {
            let item = out[readIndex]
            if let key = item.identityKey {
                if own.contains(key) || !seen.insert(key).inserted { continue }
            }
            if item.progress < previousProgress { isSorted = false }
            previousProgress = item.progress
            if writeIndex != readIndex { out[writeIndex] = item }
            writeIndex += 1
        }
        if writeIndex < out.count { out.removeSubrange(writeIndex ..< out.count) }
        if !isSorted { out.sort { $0.progress < $1.progress } }
        return out
    }
}
