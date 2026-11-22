import Foundation
import QuartzCore

/// Which mask segments to hold around the playhead (`current`, prefetched `current + 1`, and retained `current - 1`).
enum DanmakuMaskWindow {
    struct Plan: Equatable, Sendable {
        var fetch: [Int] = []
        var evict: [Int] = []
        var cancel: [Int] = []

        var isQuiet: Bool { fetch.isEmpty && evict.isEmpty && cancel.isEmpty }
    }

    static func plan(
        current: Int,
        segmentCount: Int,
        loaded: Set<Int>,
        inFlight: Set<Int>,
        blocked: Set<Int>
    ) -> Plan {
        let valid = 0 ..< max(0, segmentCount)
        let wanted = Set([current, current + 1].filter { valid.contains($0) })
        let kept = wanted.union([current - 1].filter { valid.contains($0) })
        return Plan(
            fetch: wanted.subtracting(loaded).subtracting(inFlight).subtracting(blocked).sorted(),
            evict: loaded.subtracting(kept).sorted(),
            cancel: inFlight.subtracting(wanted).sorted()
        )
    }
}

/// Manages HTTP Range fetches and off-main decoding of person-mask segments around the playhead.
@MainActor
final class DanmakuMaskStore {
    struct Request: Sendable, Equatable {
        let url: URL
        let from: Int64
        /// Inclusive; `nil` reads to EOF.
        let through: Int64?
    }

    static let indexKey = -1
    static let indexProbeBytes = 4096

    let cid: Int
    let url: URL
    private(set) var index: DanmakuMaskIndex?
    private(set) var segments: [Int: DanmakuMaskSegment] = [:]
    private(set) var failures: [Int: DanmakuSegmentFailureState] = [:]
    private var inFlight: [Int: (request: UInt64, task: Task<Void, Never>)] = [:]
    private var nextRequest: UInt64 = 0
    private var lastMediaTime: TimeInterval = 0

    var onChange: (@MainActor () -> Void)?

    init(cid: Int, url: URL) {
        self.cid = cid
        self.url = url
    }

    func advance(to mediaTime: TimeInterval) {
        lastMediaTime = mediaTime
        let now = CACurrentMediaTime()
        guard let index else {
            if inFlight[Self.indexKey] == nil, isEligible(Self.indexKey, at: now) {
                start(Self.indexKey) { store, request in await store.loadIndex(request: request) }
            }
            return
        }
        let current = index.segment(containing: mediaTime) ?? 0
        let plan = DanmakuMaskWindow.plan(
            current: current,
            segmentCount: index.count,
            loaded: Set(segments.keys),
            inFlight: Set(inFlight.keys).subtracting([Self.indexKey]),
            blocked: Set(failures.lazy.filter { !$0.value.isEligible(at: now) }.map(\.key))
        )
        guard !plan.isQuiet else { return }
        for key in plan.cancel {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
        for key in plan.evict {
            segments.removeValue(forKey: key)
        }
        for key in plan.fetch {
            start(key) { store, request in await store.loadSegment(key, index: index, request: request) }
        }
        if !plan.evict.isEmpty { onChange?() }
    }

    func suspend() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
    }

    @discardableResult
    func resetRetryableFailures() -> Int {
        let now = CACurrentMediaTime()
        var reopened = 0
        for (key, state) in failures where !state.isTerminal {
            failures[key] = state.resetForNetworkChange(at: now)
            reopened += 1
        }
        return reopened
    }

    private func isEligible(_ key: Int, at now: TimeInterval) -> Bool {
        failures[key].map { $0.isEligible(at: now) } ?? true
    }

    private func start(
        _ key: Int,
        _ body: @escaping @MainActor (DanmakuMaskStore, UInt64) async -> Void
    ) {
        nextRequest &+= 1
        let request = nextRequest
        inFlight[key] = (request, Task { [weak self] in
            guard let self else { return }
            await body(self, request)
            if inFlight[key]?.request == request {
                inFlight.removeValue(forKey: key)
            }
        })
    }

    // MARK: - Loading

    private func loadIndex(request: UInt64) async {
        do {
            var data = try await range(from: 0, through: Int64(Self.indexProbeBytes - 1))
            guard !Task.isCancelled, inFlight[Self.indexKey]?.request == request else { return }
            let count = try DanmakuMaskFormat.segmentCount(header: data)
            let needed = DanmakuMaskFormat.indexByteCount(segments: count)
            if data.count < needed {
                data = try await range(from: 0, through: Int64(needed - 1))
                guard !Task.isCancelled, inFlight[Self.indexKey]?.request == request else { return }
            }
            let indexData = data
            let parsed = try await Task.detached(priority: .utility) {
                try DanmakuMaskFormat.index(from: indexData)
            }.value
            guard !Task.isCancelled, inFlight[Self.indexKey]?.request == request else { return }
            failures.removeValue(forKey: Self.indexKey)
            index = parsed
            PlayerLog.log("[DanmakuMask] cid=\(cid) index: \(parsed.count) segments")
            advance(to: lastMediaTime)
        } catch {
            guard !Task.isCancelled, inFlight[Self.indexKey]?.request == request else { return }
            fail(Self.indexKey, error)
        }
    }

    private func loadSegment(_ key: Int, index: DanmakuMaskIndex, request: UInt64) async {
        guard let bytes = index.byteRange(of: key), let start = index.start(of: key) else { return }
        let declaredEnd = index.declaredEnd(of: key)
        do {
            let compressed = try await range(from: bytes.from, through: bytes.through)
            let decoded = try await Task.detached(priority: .utility) {
                try DanmakuMaskFormat.segment(compressed, index: key, start: start, declaredEnd: declaredEnd)
            }.value
            guard !Task.isCancelled, self.index == index else { return }
            failures.removeValue(forKey: key)
            segments[key] = decoded
            let width = Int(decoded.canvas.width)
            let height = Int(decoded.canvas.height)
            PlayerLog.log(
                "[DanmakuMask] cid=\(cid) segment \(key): \(decoded.frames.count) frames "
                    + "bytes=\(compressed.count) canvas=\(width)x\(height)"
            )
            onChange?()
        } catch {
            fail(key, error)
        }
    }

    private func range(from: Int64, through: Int64?) async throws -> Data {
        let response = try await Self.networkFetch(Request(url: url, from: from, through: through))
        switch response.status {
        case 206:
            return response.body
        case 200:
            let lower = Int(from)
            let upper = through.map { Int($0) + 1 } ?? response.body.count
            guard lower < response.body.count else { throw MaskFetchFailure.kind(.unexpectedBody) }
            return response.body.subdata(in: lower ..< min(upper, response.body.count))
        default:
            throw MaskFetchFailure.kind(.http(status: response.status))
        }
    }

    private enum MaskFetchFailure: Error {
        case kind(DanmakuSegmentFailureKind)
    }

    private func fail(_ key: Int, _ error: any Error) {
        guard !Task.isCancelled, !(error is CancellationError),
              (error as? URLError)?.code != .cancelled else { return }
        let kind: DanmakuSegmentFailureKind = switch error {
        case MaskFetchFailure.kind(let kind): kind
        case is DanmakuMaskFormatError: .malformed
        default: .transport
        }
        let now = CACurrentMediaTime()
        let state = DanmakuSegmentFailureState.recording(kind, after: failures[key], at: now)
        failures[key] = state
        let what = key == Self.indexKey ? "index" : "segment \(key)"
        let next = state.nextEligibleAt.map { "retry in \(Int(($0 - now).rounded()))s" }
            ?? "no further attempts for this video"
        PlayerLog.log("[DanmakuMask] cid=\(cid) \(what) failed class=\(kind) error=\(error) — \(next)")
    }

    // MARK: - Network

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    nonisolated static func networkFetch(_ request: Request) async throws -> DanmakuSegmentResponse {
        var urlRequest = URLRequest(url: request.url)
        let upper = request.through.map(String.init) ?? ""
        urlRequest.setValue("bytes=\(request.from)-\(upper)", forHTTPHeaderField: "Range")
        urlRequest.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        return DanmakuSegmentResponse(
            status: http?.statusCode ?? 0,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
            body: data
        )
    }
}
