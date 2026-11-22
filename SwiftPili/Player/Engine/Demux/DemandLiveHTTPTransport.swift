import Foundation

/// Single-reader wait with a monotonic deadline. Install and signal the waiter
/// under the same lock as the state predicate to avoid lost cancellation wakes.
final class DemandLiveReadLock: @unchecked Sendable {
    let lock = NSLock()
    private var waiter: DispatchSemaphore?

    func wait(until deadline: DispatchTime) {
        let waiter = DispatchSemaphore(value: 0)
        self.waiter = waiter
        lock.unlock()
        _ = waiter.wait(timeout: deadline)
        lock.lock()
        self.waiter = nil
    }

    func wake() { waiter?.signal() }
}

/// Foundation owns every request, including the effective URL after redirects.
/// One active task, with a second slot reserved for the TS startup playlist.
/// Stop revokes both slots and wakes playlist polling.
final class DemandLiveHTTPTransport: @unchecked Sendable {
    static let stallSeconds = 15

    struct Transfer: Sendable {
        let task: URLSessionDataTask
        let transfer: DemandLiveHTTPTransfer
        fileprivate let isInitialPlaylist: Bool
    }

    private let gate = DemandLiveReadLock()
    private let session: URLSession
    private let headers: [String: String]
    private let counter: MediaNetworkByteCounter?
    private var active: Transfer?
    private var playlistHedge: Transfer?
    private var cancelled = false

    init(request: MediaOpenRequest) {
        headers = request.headers
        counter = request.networkByteCounter
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(Self.stallSeconds)
        // Keep Foundation's resource lifetime for the continuous FLV response.
        // The native worker also applies its own deadline while waiting for bytes.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        cancel()
        session.invalidateAndCancel()
    }

    static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    static func failure(_ code: URLError.Code) -> MediaEngineError {
        .transportFailed(StreamTransportFailure(stage: .mediaRead, reason: .url(code.rawValue), retryAfter: nil))
    }

    func start(_ url: URL, body: DemandLiveHTTPTransfer.Body) throws -> Transfer {
        try start(url, body: body, isPlaylistHedge: false, notifyTerminal: nil)
    }

    func startInitialPlaylist(
        _ url: URL, isHedge: Bool, notifyTerminal: @escaping @Sendable () -> Void
    ) throws -> Transfer {
        try start(
            url, body: .complete(PathAHLSMediaPlaylist.maxPlaylistBytes),
            isPlaylistHedge: isHedge, notifyTerminal: notifyTerminal
        )
    }

    private func start(
        _ url: URL, body: DemandLiveHTTPTransfer.Body,
        isPlaylistHedge: Bool, notifyTerminal: (@Sendable () -> Void)?
    ) throws -> Transfer {
        try gate.lock.withLock {
            guard !cancelled else { throw MediaEngineError.stopped }
            guard Self.isHTTPURL(url) else { throw Self.failure(.unsupportedURL) }
            let canStart = isPlaylistHedge ? active?.isInitialPlaylist != false : active == nil
            guard playlistHedge == nil, canStart else {
                throw MediaEngineError.demuxFailed("Demand live concurrent HTTP request")
            }
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            // Both initial bodies count as wire bytes on this exact open, even if only one is admitted.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(nil, forHTTPHeaderField: "Range")
            let task = session.dataTask(with: request)
            let delegate = DemandLiveHTTPTransfer(body: body, counter: counter, notifyTerminal: notifyTerminal)
            task.delegate = delegate
            let transfer = Transfer(task: task, transfer: delegate, isInitialPlaylist: notifyTerminal != nil)
            if isPlaylistHedge { playlistHedge = transfer } else { active = transfer }
            task.resume()
            return transfer
        }
    }

    func load(_ url: URL, maximumBytes: Int, deadline: DispatchTime) throws -> DemandLiveHTTPTransfer.Resource {
        try checkCancellation()
        guard DispatchTime.now() < deadline else { throw Self.failure(.timedOut) }
        return try complete(start(url, body: .complete(maximumBytes)), deadline: deadline)
    }

    func complete(_ transfer: Transfer, deadline: DispatchTime) throws -> DemandLiveHTTPTransfer.Resource {
        defer { gate.lock.withLock { _ = detach(transfer) } }
        let resource = try transfer.transfer.complete(task: transfer.task, deadline: deadline)
        try checkCancellation()
        return resource
    }

    func discard(_ transfer: Transfer) {
        let didDetach = gate.lock.withLock {
            guard detach(transfer) else { return false }
            transfer.transfer.stop()
            return true
        }
        if didDetach { transfer.task.cancel() }
    }

    /// Called with the transport lock held. A late completion can retire only its own task.
    private func detach(_ transfer: Transfer) -> Bool {
        if active?.task === transfer.task {
            active = nil
        } else if playlistHedge?.task === transfer.task {
            playlistHedge = nil
        } else {
            return false
        }
        return true
    }

    func checkCancellation() throws {
        try gate.lock.withLock {
            if cancelled { throw MediaEngineError.stopped }
        }
    }

    func wait(until wakeTime: DispatchTime) throws {
        try gate.lock.withLock {
            while !cancelled, DispatchTime.now() < wakeTime { gate.wait(until: wakeTime) }
            if cancelled { throw MediaEngineError.stopped }
        }
    }

    func cancel() {
        let retired = gate.lock.withLock {
            cancelled = true
            let retired = [active, playlistHedge].compactMap { $0 }
            // Revoke and wake both waits before releasing cancellation admission.
            for transfer in retired { transfer.transfer.stop() }
            active = nil
            playlistHedge = nil
            gate.wake()
            return retired
        }
        for transfer in retired { transfer.task.cancel() }
    }
}

/// Request-owned delegate with one consumer. Callback data may race suspension,
/// so the hard bound reserves headroom above the point where we suspend delivery.
final class DemandLiveHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Body: Sendable {
        case complete(Int)
        case streaming

        var maximumBytes: Int {
            switch self {
            case .complete(let limit): limit
            case .streaming: Self.hardWater
            }
        }

        static let lowWater = 256 * 1024
        static let highWater = 512 * 1024
        static let hardWater = 2 * 1024 * 1024
    }

    struct Resource: Sendable {
        let data: Data
        let url: URL
    }

    private enum Terminal {
        case eof
        case failed(MediaEngineError)
    }

    private let gate = DemandLiveReadLock()
    private let body: Body
    private let counter: MediaNetworkByteCounter?
    private var notifyTerminal: (@Sendable () -> Void)?
    private var buffer = Data()
    private var head = 0
    private var isSuspended = false
    private var highWater = 0
    private var terminal: Terminal?
    private var effectiveURL: URL?
    private var expected: Int64?
    private var received: Int64 = 0

    private var readableBytes: Int { buffer.count - head }

    init(body: Body, counter: MediaNetworkByteCounter?, notifyTerminal: (@Sendable () -> Void)?) {
        self.body = body
        self.counter = counter
        self.notifyTerminal = notifyTerminal
    }

    func complete(task: URLSessionDataTask, deadline: DispatchTime) throws -> Resource {
        try waitForData(task: task, deadline: deadline) {
            guard case .eof = terminal, let effectiveURL else { return nil }
            let result = Resource(data: buffer, url: effectiveURL)
            buffer = Data()
            return result
        }
    }

    func read(maximumBytes: Int, task: URLSessionDataTask, deadline: DispatchTime) throws -> Data? {
        try waitForData(task: task, deadline: deadline) {
            if readableBytes > 0 { return .some(drain(maximumBytes: maximumBytes, task: task)) }
            if case .eof = terminal { return .some(nil) }
            return nil
        }
    }

    private func waitForData<T>(task: URLSessionDataTask, deadline: DispatchTime, ready: () -> T?) throws -> T {
        do {
            return try gate.lock.withLock {
                while true {
                    if case .failed(let error) = terminal { throw error }
                    guard DispatchTime.now() < deadline else {
                        let error = DemandLiveHTTPTransport.failure(.timedOut)
                        fail(error)
                        throw error
                    }
                    if let value = ready() { return value }
                    gate.wait(until: deadline)
                }
            }
        } catch {
            task.cancel()
            throw error
        }
    }

    private func drain(maximumBytes: Int, task: URLSessionDataTask) -> Data {
        let count = min(maximumBytes, readableBytes)
        let result = buffer.subdata(in: head..<(head + count))
        head += count
        if readableBytes == 0 {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        }
        if isSuspended, terminal == nil, readableBytes <= Body.lowWater {
            isSuspended = false
            task.resume()
        }
        return result
    }

    func stop() {
        gate.lock.withLock { fail(.stopped) }
    }

    private func fail(_ error: MediaEngineError) {
        buffer = Data()
        head = 0
        finish(.failed(error))
    }

    private func finish(_ terminal: Terminal) {
        self.terminal = terminal
        gate.wake()
        // The startup observer only enqueues a side in a separate mailbox.
        // It must never call back into this transport while this lock is held.
        let notification = notifyTerminal
        notifyTerminal = nil
        notification?()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirected = gate.lock.withLock { () -> URLRequest? in
            guard terminal == nil else { return nil }
            guard let url = request.url, DemandLiveHTTPTransport.isHTTPURL(url) else {
                fail(DemandLiveHTTPTransport.failure(.unsupportedURL))
                return nil
            }
            return request
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let admitted = gate.lock.withLock { () -> Bool in
            guard terminal == nil else { return false }
            do {
                try admit(response)
                return true
            } catch let error as MediaEngineError {
                fail(error)
                return false
            } catch {
                fail(DemandLiveHTTPTransport.failure(.badServerResponse))
                return false
            }
        }
        completionHandler(admitted ? .allow : .cancel)
    }

    private func admit(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DemandLiveHTTPTransport.failure(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw MediaEngineError.transportFailed(StreamTransportFailure.http(http, stage: .mediaRead))
        }
        guard let url = http.url, DemandLiveHTTPTransport.isHTTPURL(url) else {
            throw DemandLiveHTTPTransport.failure(.unsupportedURL)
        }
        guard http.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw DemandLiveHTTPTransport.failure(.badServerResponse)
        }
        try PathAHTTPRangeValidator.validateIdentityContentEncoding(http.value(forHTTPHeaderField: "Content-Encoding"))
        expected = try PathAHTTPRangeValidator.declaredContentLength(http.value(forHTTPHeaderField: "Content-Length"))
        if case .complete(let limit) = body, let expected, expected > Int64(limit) {
            throw MediaEngineError.demuxFailed("Demand live HTTP response exceeds bound")
        }
        effectiveURL = url
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter?.add(data.count)
        let abort = gate.lock.withLock { () -> Bool in
            guard terminal == nil, !data.isEmpty else { return false }
            guard data.count <= body.maximumBytes - readableBytes else {
                fail(.demuxFailed("Demand live HTTP buffer exceeds bound"))
                return true
            }
            let updated = received.addingReportingOverflow(Int64(data.count))
            guard !updated.overflow, expected.map({ updated.partialValue <= $0 }) ?? true else {
                fail(DemandLiveHTTPTransport.failure(.badServerResponse))
                return true
            }
            received = updated.partialValue
            if data.count > body.maximumBytes - buffer.count {
                buffer.removeSubrange(0..<head)
                head = 0
            }
            buffer.append(data)
            if case .streaming = body {
                highWater = max(highWater, readableBytes)
                if !isSuspended, readableBytes >= Body.highWater {
                    isSuspended = true
                    dataTask.suspend()
                }
                gate.wake()
            }
            return false
        }
        if abort { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let peak = gate.lock.withLock { () -> Int in
            if terminal == nil {
                if let error {
                    if let failure = StreamTransportFailure.preserving(error, stage: .mediaRead) {
                        fail(.transportFailed(failure))
                    } else {
                        fail(.demuxFailed("Demand live HTTP transfer failed"))
                    }
                } else if effectiveURL == nil {
                    fail(DemandLiveHTTPTransport.failure(.badServerResponse))
                } else if let expected, received != expected {
                    fail(DemandLiveHTTPTransport.failure(.networkConnectionLost))
                } else {
                    finish(.eof)
                }
            }
            return highWater
        }
        if case .streaming = body { PlayerLog.log("[PathA:FLV] HTTP buffer peak bytes=\(peak)") }
    }
}
