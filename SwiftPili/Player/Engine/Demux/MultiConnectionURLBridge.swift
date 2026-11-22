import Foundation

/// Header admission and cumulative bounds precede every body hop. Each request
/// owns one coalesced buffer and one drain, with no whole-response body copy.
final class MultiConnectionURLBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// All mutable state is protected by the bridge lock, including drain setup.
    private final class Transfer: @unchecked Sendable {
        let task: URLSessionTask
        let range: Range<Int64>
        let resourceLength: Int64
        let consume: @Sendable (MultiConnectionPrefix) async throws -> Void
        let continuation: CheckedContinuation<MultiConnectionResponse, any Error>
        var response: HTTPURLResponse?
        var pending = MultiConnectionPrefixBuffer()
        var bodyCount = 0
        var deliveredCount = 0
        var terminal: MultiConnectionResponse?
        var failure: (any Error)?
        var connection: MultiConnectionResponse.Connection?
        var waiter: CheckedContinuation<Void, Never>?
        var drain: Task<Void, Never>?

        init(
            task: URLSessionTask, range: Range<Int64>, resourceLength: Int64,
            consume: @escaping @Sendable (MultiConnectionPrefix) async throws -> Void,
            continuation: CheckedContinuation<MultiConnectionResponse, any Error>
        ) {
            self.task = task
            self.range = range
            self.resourceLength = resourceLength
            self.consume = consume
            self.continuation = continuation
        }
    }
    private enum DrainStep {
        case prefix(MultiConnectionPrefix)
        case completed(MultiConnectionResponse)
        case waiting
        case retired
    }
    private struct Retirement {
        let transfer: Transfer
        let drain: Task<Void, Never>?
        let waiter: CheckedContinuation<Void, Never>?
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    /// Late callbacks still belong to this open's wire counter after retirement.
    private let networkBytes: MediaNetworkByteCounter?

    init(networkBytes: MediaNetworkByteCounter? = nil) {
        self.networkBytes = networkBytes
        super.init()
    }

    func register(
        _ task: URLSessionTask, range: Range<Int64>, resourceLength: Int64,
        consume: @escaping @Sendable (MultiConnectionPrefix) async throws -> Void,
        continuation: CheckedContinuation<MultiConnectionResponse, any Error>
    ) {
        let transfer = Transfer(
            task: task, range: range, resourceLength: resourceLength, consume: consume, continuation: continuation
        )
        lock.withLock {
            transfers[task.taskIdentifier] = transfer
            transfer.drain = Task { await self.drain(transfer) }
        }
    }

    /// Also settles cancellation during a suspended consumer; its eventual store
    /// outcome belongs to that consumer, never to a replacement transfer.
    func retire(_ task: URLSessionTask, error: any Error) {
        let retired = lock.withLock { () -> Retirement? in
            guard let transfer = transfers[task.taskIdentifier], transfer.task === task else { return nil }
            transfers[task.taskIdentifier] = nil
            let result = Retirement(transfer: transfer, drain: transfer.drain, waiter: transfer.waiter)
            transfer.drain = nil
            transfer.waiter = nil
            transfer.pending.clear()
            return result
        }
        guard let retired else { return }
        retired.drain?.cancel()
        retired.waiter?.resume()
        task.cancel()
        retired.transfer.continuation.resume(throwing: error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        retire(task, error: PathAHTTPMediaSource.SourceError.invalidRange)
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let admitted = try update(dataTask) { transfer in
                guard transfer.response == nil, let http = response as? HTTPURLResponse else {
                    throw PathAHTTPMediaSource.SourceError.invalidRange
                }
                if let refusal = MultiConnectionTransportError.refusal(
                    status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type")
                ) { throw refusal }
                try MultiConnectionValidation.headers(
                    status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                    range: transfer.range, resourceLength: transfer.resourceLength
                )
                transfer.response = http
            }
            completionHandler(admitted ? .allow : .cancel)
        } catch {
            retire(dataTask, error: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        networkBytes?.add(data.count)
        guard !data.isEmpty else { return }
        do {
            var waiter: CheckedContinuation<Void, Never>?
            try update(dataTask) { transfer in
                let limit = transfer.range.upperBound - transfer.range.lowerBound
                guard transfer.response != nil, transfer.terminal == nil,
                      Int64(transfer.bodyCount) <= limit,
                      Int64(data.count) <= limit - Int64(transfer.bodyCount) else {
                    // Reject the entire offending callback, retaining earlier admitted prefixes.
                    throw PathAHTTPMediaSource.SourceError.invalidRange
                }
                transfer.bodyCount += data.count
                transfer.pending.append(data)
                waiter = transfer.waiter
                transfer.waiter = nil
            }
            waiter?.resume()
        } catch { retire(dataTask, error: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let metric = metrics.transactionMetrics.last,
              let remote = metric.remoteAddress, let localPort = metric.localPort else { return }
        lock.withLock {
            guard let transfer = transfers[task.taskIdentifier], transfer.task === task else { return }
            transfer.connection = .init(
                remote: remote, localPort: localPort,
                networkProtocol: metric.networkProtocolName ?? "unknown", reused: metric.isReusedConnection
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do {
            var waiter: CheckedContinuation<Void, Never>?
            try update(task) { transfer in
                if let error { throw MultiConnectionTransportError.policy(from: error) ?? error }
                guard let response = transfer.response else { throw PathAHTTPMediaSource.SourceError.invalidRange }
                try MultiConnectionValidation.headers(
                    status: response.statusCode, contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: response.value(forHTTPHeaderField: "Content-Length"),
                    range: transfer.range, resourceLength: transfer.resourceLength, bodyCount: transfer.bodyCount
                )
                transfer.terminal = MultiConnectionResponse(
                    status: response.statusCode, contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: response.value(forHTTPHeaderField: "Content-Length"), bodyCount: transfer.bodyCount,
                    connection: transfer.connection
                )
                waiter = transfer.waiter
                transfer.waiter = nil
            }
            waiter?.resume()
        } catch { retire(task, error: error) }
    }

    /// Mark validation failure before releasing the lock, so the drain cannot
    /// take another prefix between rejection and out-of-lock cancellation.
    @discardableResult
    private func update(_ task: URLSessionTask, _ operation: (Transfer) throws -> Void) rethrows -> Bool {
        try lock.withLock {
            guard let transfer = transfers[task.taskIdentifier], transfer.task === task,
                  transfer.failure == nil else { return false }
            do {
                try operation(transfer)
                return true
            } catch {
                transfer.failure = error
                throw error
            }
        }
    }

    private func drain(_ transfer: Transfer) async {
        while true {
            await waitForPending(transfer)
            let step = lock.withLock { takeNext(transfer) }
            switch step {
            case .prefix(let prefix):
                do {
                    try Task.checkCancellation()
                    try await transfer.consume(prefix)
                } catch {
                    retire(transfer.task, error: error)
                    return
                }
            case .completed(let response):
                transfer.continuation.resume(returning: response)
                return
            case .waiting:
                continue
            case .retired:
                return
            }
        }
    }

    private func waitForPending(_ transfer: Transfer) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                guard transfers[transfer.task.taskIdentifier] === transfer else { return true }
                if !transfer.pending.isEmpty || transfer.terminal != nil || transfer.failure != nil { return true }
                transfer.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Called only with the state lock held. The consumer and continuation run outside it.
    private func takeNext(_ transfer: Transfer) -> DrainStep {
        guard transfers[transfer.task.taskIdentifier] === transfer, transfer.failure == nil else { return .retired }
        if !transfer.pending.isEmpty {
            let data = transfer.pending.take()
            let offset = transfer.range.lowerBound + Int64(transfer.deliveredCount)
            transfer.deliveredCount += data.count
            return .prefix(.init(offset: offset, data: data))
        }
        guard let response = transfer.terminal else { return .waiting }
        transfers[transfer.task.taskIdentifier] = nil
        transfer.drain = nil
        return .completed(response)
    }
}
