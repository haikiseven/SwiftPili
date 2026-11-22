import Foundation

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
