import Foundation

struct StreamRouteProbeResult: Sendable {
    enum Evidence: Sendable { case unreachable, reachable, partial }

    let evidence: Evidence
    let outcome: StreamProbeOutcome
}

enum StreamRouteProbe {
    typealias Admission = @MainActor @Sendable (URL) -> Bool

    enum Mode: Sendable {
        case reachability, resume

        var offset: Int64 { self == .resume ? 1 : 0 }
    }

    static func run(
        _ url: URL, mode: Mode, deadline: ContinuousClock.Instant, admits: Admission? = nil
    ) async -> StreamRouteProbeResult {
        let host = CDNHostPolicy.canonicalHost(url.host())
        let receiver = RouteProbeReceiver(host: host, mode: mode, deadline: deadline, admits: admits)
        guard CDNHostPolicy.allows(url) else { return receiver.rejected(.structural) }
        if let admits, !(await admits(url)) { return receiver.rejected(.cancelled) }
        guard !Task.isCancelled else { return receiver.rejected(.cancelled) }
        guard let remaining = deadline.admittedSeconds else { return receiver.failed(URLError(.timedOut)) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = remaining
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: remaining)
        for (header, value) in PlayerBackendLoadConfiguration.biliHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.setValue("bytes=\(mode.offset)-\(mode.offset)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let wall = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            receiver.timeout()
        }
        defer { wall.cancel() }
        return await withTaskCancellationHandler {
            await receiver.start(request, session: session)
        } onCancel: {
            receiver.cancel()
        }
    }
}

private extension ContinuousClock.Instant {
    var admittedSeconds: TimeInterval? {
        let remaining = ContinuousClock.now.duration(to: self)
        guard remaining > .zero else { return nil }
        let (seconds, attoseconds) = remaining.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

private final class RouteProbeReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Completion {
        let waiter: CheckedContinuation<StreamRouteProbeResult, Never>?
        let task: URLSessionDataTask?
        let result: StreamRouteProbeResult
    }

    private let host: String?
    private let mode: StreamRouteProbe.Mode
    private let deadline: ContinuousClock.Instant
    private let admits: StreamRouteProbe.Admission?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<StreamRouteProbeResult, Never>?
    private var result: StreamRouteProbeResult?
    private var remainingBodyBytes: Int?

    init(
        host: String?, mode: StreamRouteProbe.Mode, deadline: ContinuousClock.Instant,
        admits: StreamRouteProbe.Admission?
    ) {
        self.host = host
        self.mode = mode
        self.deadline = deadline
        self.admits = admits
    }

    func start(_ request: URLRequest, session: URLSession) async -> StreamRouteProbeResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let result {
                    continuation.resume(returning: result)
                    return
                }
                guard ContinuousClock.now < deadline else {
                    continuation.resume(returning: failed(URLError(.timedOut)))
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }
    }

    func timeout() { finish(failed(URLError(.timedOut)), cancelTask: true) }
    func cancel() { finish(rejected(.cancelled), cancelTask: true) }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        Task {
            let target = await admittedRedirect(request)
            if target == nil { finish(rejected(.structural, status: response.statusCode)) }
            completionHandler(target)
        }
    }

    private func admittedRedirect(_ request: URLRequest) async -> URLRequest? {
        guard mode == .reachability, let url = request.url, CDNHostPolicy.allows(url) else { return nil }
        if let admits, !(await admits(url)) { return nil }
        let pending = lock.withLock { result == nil && ContinuousClock.now < deadline }
        return pending ? request : nil
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let (verdict, length) = inspect(response)
        guard let length else {
            finish(verdict ?? rejected(.unknown))
            completionHandler(.cancel)
            return
        }
        let pending = lock.withLock {
            guard result == nil, ContinuousClock.now < deadline else { return false }
            remainingBodyBytes = length
            return true
        }
        if !pending { timeout() }
        completionHandler(pending ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let valid = lock.withLock {
            guard result == nil else { return true }
            guard let remainingBodyBytes, data.count <= remainingBodyBytes else { return false }
            self.remainingBodyBytes = remainingBodyBytes - data.count
            return true
        }
        if !valid { finish(rejected(.unknown, status: 206), cancelTask: true) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(failed(error))
        } else if lock.withLock({ remainingBodyBytes == 0 }) {
            finish(responseResult(status: 206, evidence: .partial))
        } else {
            finish(rejected(.unknown))
        }
    }

    private func inspect(_ response: URLResponse) -> (StreamRouteProbeResult?, Int?) {
        guard let http = response as? HTTPURLResponse else { return (rejected(.unknown), nil) }
        let status = http.statusCode
        if status >= 400 {
            let outcome = StreamProbeOutcome(host: host, status: status, failure: .http(http, stage: .probe),
                rejection: nil)
            return (.init(evidence: .unreachable, outcome: outcome), nil)
        }
        if mode == .reachability || status == 200 {
            return (responseResult(status: status, evidence: .reachable), nil)
        }
        guard status == 206, http.mimeType?.lowercased() != "multipart/byteranges",
              let window = PathAHTTPRangeValidator.makeByteWindow(offset: mode.offset, count: 1) else {
            return (rejected(.unknown, status: status), nil)
        }
        do {
            try PathAHTTPRangeValidator.validateIdentityContentEncoding(
                http.value(forHTTPHeaderField: "Content-Encoding")
            )
            let range = try PathAHTTPRangeValidator.validatePartialResponse(
                http.value(forHTTPHeaderField: "Content-Range"), requested: window, bodyCount: nil
            )
            guard range?.end == window.endInclusive,
                  range?.length == window.count64,
                  try PathAHTTPRangeValidator.declaredContentLength(
                    http.value(forHTTPHeaderField: "Content-Length")
                  ).map({ $0 == window.count64 }) ?? true else {
                return (rejected(.unknown, status: status), nil)
            }
        } catch {
            return (rejected(.unknown, status: status), nil)
        }
        return (nil, window.count)
    }

    private func responseResult(status: Int, evidence: StreamRouteProbeResult.Evidence) -> StreamRouteProbeResult {
        .init(evidence: evidence, outcome: .init(host: host, status: status, failure: nil, rejection: nil))
    }

    func rejected(_ reason: StreamProbeOutcome.Rejection, status: Int? = nil) -> StreamRouteProbeResult {
        .init(evidence: .unreachable, outcome: .init(host: host, status: status, failure: nil, rejection: reason))
    }

    func failed(_ error: any Error) -> StreamRouteProbeResult {
        let failure = StreamTransportFailure.preserving(error, stage: .probe)
        let outcome = StreamProbeOutcome(host: host, status: nil, failure: failure,
            rejection: failure == nil ? .unknown : nil)
        return .init(evidence: .unreachable, outcome: outcome)
    }

    private func finish(_ verdict: StreamRouteProbeResult, cancelTask: Bool = false) {
        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }
            let admitted = ContinuousClock.now < deadline ? verdict : failed(URLError(.timedOut))
            result = admitted
            let completion = Completion(waiter: continuation, task: task, result: admitted)
            continuation = nil
            task = nil
            return completion
        }
        guard let completion else { return }
        if cancelTask { completion.task?.cancel() }
        completion.waiter?.resume(returning: completion.result)
    }
}
