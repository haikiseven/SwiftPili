import Foundation

/// Owns one URLSession request and the completion of the actor-side `load`.
///
/// The URLSession task is deliberately per-request rather than per-demuxer:
/// callers may inject a shared URLSession, so closing the demuxer must never
/// invalidate that session or affect another consumer. The completion waiters
/// let close/replacement wait until the actor-side load defer has run, not just
/// until URLSession has noticed cancellation.
final class PathAHLSInFlightRequest: @unchecked Sendable {
    let generation: UInt64

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var result: Result<MediaNetworkResponse, Error>?
    private var resultContinuation: CheckedContinuation<MediaNetworkResponse, Error>?
    private var didComplete = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(generation: UInt64) {
        self.generation = generation
    }

    func install(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func finish(_ result: Result<MediaNetworkResponse, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = resultContinuation
        resultContinuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        // Custom URLProtocols/transports are allowed to suppress the
        // URLSession cancellation callback. Resolve the actor-side await
        // ourselves after cancelling the owned task. `finish` is idempotent,
        // so a late transport callback cannot resume the continuation twice.
        finish(.failure(URLError(.cancelled)))
    }

    func value() async throws -> MediaNetworkResponse {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<MediaNetworkResponse, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                resultContinuation = continuation
                lock.unlock()
            }
        }
    }

    func markComplete() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let waiters = completionWaiters
        completionWaiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForCompletion() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didComplete {
                lock.unlock()
                continuation.resume()
            } else {
                completionWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
