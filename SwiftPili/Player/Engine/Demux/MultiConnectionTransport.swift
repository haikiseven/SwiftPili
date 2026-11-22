import Foundation

struct MultiConnectionResponse: Sendable {
    struct Connection: Sendable, Equatable {
        let remote: String
        let localPort: Int
        let networkProtocol: String
        let reused: Bool
        var identity: String { "\(remote):\(localPort)" }
    }
    let status: Int
    let contentRange: String?
    let contentLength: String?
    let bodyCount: Int
    let connection: Connection?
}

struct MultiConnectionFetchOptions: Sendable, Equatable {
    var lane = 0
    var priority: Float = URLSessionTask.defaultPriority
}

struct MultiConnectionPrefix: Sendable {
    let offset: Int64
    let data: Data
}

struct MultiConnectionPrefixBuffer: Sendable {
    private var data = Data()
    private var removedPrefix = false
    var isEmpty: Bool { data.isEmpty }

    mutating func append(_ bytes: Data) {
        if data.isEmpty { data = bytes } else { data.append(bytes) }
    }

    mutating func take() -> Data {
        let count = min(data.count, MultiConnectionPlanner.minimumPieceBytes)
        let prefix = count == data.count && !removedPrefix
            ? data : data.withUnsafeBytes { Data($0.prefix(count)) }
        if count == data.count {
            clear()
        } else {
            data.removeFirst(count)
            removedPrefix = true
        }
        return prefix
    }

    mutating func clear() {
        data = Data()
        removedPrefix = false
    }
}

struct MultiConnectionFetchRequest: Sendable {
    let request: URLRequest
    let range: Range<Int64>
    let resourceLength: Int64
}

protocol MultiConnectionTransport: Sendable {
    func fetch(
        _ request: MultiConnectionFetchRequest, quietGate: MultiConnectionQuietGate,
        options: MultiConnectionFetchOptions,
        consume: @escaping @Sendable (MultiConnectionPrefix) async throws -> Void
    ) async throws -> MultiConnectionResponse
}

enum MultiConnectionValidation {
    static func headers(
        status: Int, contentRange: String?, contentLength: String?,
        range: Range<Int64>, resourceLength: Int64, bodyCount: Int? = nil
    ) throws {
        guard status == 206, range.lowerBound >= 0, range.upperBound > range.lowerBound,
              let count = Int(exactly: range.upperBound - range.lowerBound),
              let window = PathAHTTPRangeValidator.makeByteWindow(offset: range.lowerBound, count: count),
              let parsed = try PathAHTTPRangeValidator.validatePartialResponse(
                contentRange, requested: window, bodyCount: bodyCount
              ), parsed.end == window.endInclusive, parsed.total == resourceLength else {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }
        if let declared = try PathAHTTPRangeValidator.declaredContentLength(contentLength), declared != window.count64 {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }
        if let bodyCount {
            try PathAHTTPRangeValidator.validateContentLength(
                contentLength, bodyCount: bodyCount, expectedRangeLength: window.count64
            )
        }
    }
}

final class MultiConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [Task<Void, Never>] = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    func insert(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if cancelled { return true }
            tasks.append(task)
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let result = tasks
            tasks = []
            return result
        }
        pending.forEach { $0.cancel() }
    }
}

final class MultiConnectionURLTransport: MultiConnectionTransport, @unchecked Sendable {
    private let lanes: [(session: URLSession, bridge: MultiConnectionURLBridge)]

    init(
        configuration: URLSessionConfiguration = .ephemeral, policy: MultiConnectionPolicy? = nil,
        networkBytes: MediaNetworkByteCounter? = nil
    ) {
        let allowsExpensive = policy?.allowsExpensive ?? false
        configuration.allowsCellularAccess = allowsExpensive
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsExpensiveNetworkAccess = allowsExpensive
        configuration.httpMaximumConnectionsPerHost = max(1, policy?.edgeBound ?? 1)
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let count = max(
            1, min(MultiConnectionPolicy.maximumSessionsPerEdge, policy?.sessionsPerEdge ?? 1)
        )
        lanes = (0..<count).map { _ in
            let bridge = MultiConnectionURLBridge(networkBytes: networkBytes)
            return (URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil), bridge)
        }
    }

    deinit { lanes.forEach { $0.session.invalidateAndCancel() } }

    func fetch(
        _ request: MultiConnectionFetchRequest, quietGate: MultiConnectionQuietGate,
        options: MultiConnectionFetchOptions,
        consume: @escaping @Sendable (MultiConnectionPrefix) async throws -> Void
    ) async throws -> MultiConnectionResponse {
        let lane = lanes[max(0, options.lane) % lanes.count]
        let cancellation = MultiConnectionURLCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = lane.session.dataTask(with: request.request)
                task.priority = options.priority
                lane.bridge.register(
                    task, range: request.range, resourceLength: request.resourceLength,
                    consume: consume, continuation: continuation
                )
                cancellation.install(task, bridge: lane.bridge)
                if !quietGate.withNotQuiet({ task.resume() }) {
                    lane.bridge.retire(task, error: MultiConnectionTransportError.quiet)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class MultiConnectionURLCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var transfer: (task: URLSessionTask, bridge: MultiConnectionURLBridge)?

    func install(_ task: URLSessionTask, bridge: MultiConnectionURLBridge) {
        let shouldCancel = lock.withLock {
            transfer = (task, bridge)
            return cancelled
        }
        if shouldCancel { bridge.retire(task, error: CancellationError()) }
    }

    func cancel() {
        let current = lock.withLock {
            cancelled = true
            return transfer
        }
        if let current { current.bridge.retire(current.task, error: CancellationError()) }
    }
}
