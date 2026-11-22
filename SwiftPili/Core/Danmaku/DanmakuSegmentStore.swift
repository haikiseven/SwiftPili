import Foundation
import QuartzCore

/// Owns the resident VOD danmaku segment window plus the metadata/special package timeline.
/// Network, protobuf decode, and sorting run off-main; admission and lifecycle share `@MainActor`.
@MainActor
final class DanmakuSegmentStore {
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
    private var latestPosition: (mediaTime: TimeInterval, duration: TimeInterval)?

    init() {
        metadataOwner.onMetadata = { [weak self] in self?.acceptMetadata($0) }
        metadataOwner.onSpecialLoaded = { [weak self] in self?.onSpecialLoaded?() }
    }

    func reset(oid newOID: Int?) {
        cancelInFlight()
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
        metadataOwner.advance()
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

    /// Allocation-free fast check equivalent to `DanmakuWindowPlan.isQuiet` on the 4 Hz tick path.
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

    /// Bullets due in `[from, to)` merged with special packages and local self-sent echoes.
    func elements(from: TimeInterval, to: TimeInterval) -> [DanmakuElem] {
        guard from < to, !isServerClosed else { return [] }
        var out: [DanmakuElem] = []
        for index in segments.keys.sorted() {
            guard let segment = segments[index] else { continue }
            out.append(contentsOf: segment.elements(from: from, to: to))
        }
        for url in metadataOwner.packages.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            guard let package = metadataOwner.packages[url] else { continue }
            out.append(contentsOf: package.elements(from: from, to: to))
        }
        let ownIDs = Set(selfSent.compactMap(\.identityKey))
        out.removeAll { $0.identityKey.map(ownIDs.contains) ?? false }
        out.append(contentsOf: selfSent.filter { $0.progress >= from && $0.progress < to })
        var seenIDs: Set<String> = []
        out = out.filter {
            $0.identityKey.map { seenIDs.insert($0).inserted } ?? true
        }
        return out.enumerated()
            .sorted { lhs, rhs in
                lhs.element.progress == rhs.element.progress
                    ? lhs.offset < rhs.offset
                    : lhs.element.progress < rhs.element.progress
            }
            .map(\.element)
    }

    /// Advances the admit cursor across loaded or failed segments, pausing at the first pending segment.
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

    private func load(oid: Int, segmentIndex: Int, request: UInt64) async {
        defer {
            if inFlight[segmentIndex]?.request == request {
                inFlight.removeValue(forKey: segmentIndex)
            }
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
        guard from < end, !isServerClosed else { return [] }
        let own = Set(selfSent.compactMap(\.identityKey))
        var seen: Set<String> = []
        return metadataOwner.packages.values.flatMap { $0.elements(from: from, to: end) }
            .filter { item in
                guard let key = item.identityKey else { return true }
                return !own.contains(key) && seen.insert(key).inserted
            }
            .sorted { $0.progress < $1.progress }
    }
}
