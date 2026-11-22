import Foundation

struct MediaNetworkResponse: @unchecked Sendable {
    let data: Data
    let response: URLResponse
    /// Bytes delivered by the transport, including an ignored Range prefix.
    let receivedBodyBytes: Int64
    /// False when reception stopped after the requested window or headers.
    let isCompleteBody: Bool
    /// Only a complete-resource response can establish this value here. A 206
    /// total still belongs to the caller's Content-Range validation.
    let resourceLength: Int64?
}

/// Request-owned retention bounds apply before append. Range-ignore responses
/// discard the unwanted prefix and finish as soon as the requested window is
/// present; they never masquerade as a fully received response.
final class MediaNetworkDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum BodyPolicy: Sendable {
        case complete(maximumBytes: Int)
        case window(PathAHTTPRangeValidator.ByteWindow)

        var maximumBytes: Int {
            switch self {
            case .complete(let maximumBytes): maximumBytes
            case .window(let window): window.count
            }
        }
    }

    enum BodyError: Error, LocalizedError {
        case exceedsBound

        var errorDescription: String? { "response exceeds bound" }
    }

    private let policy: BodyPolicy
    private let counter: MediaNetworkByteCounter?
    private let completion: @Sendable (Result<MediaNetworkResponse, any Error>) -> Void
    // URLSession serializes this task's delegate callbacks.
    private var body = Data()
    private var response: URLResponse?
    private var receivedBodyBytes: Int64 = 0
    private var declaredBodyLength: Int64?
    private var retainedOffset: Int64 = 0
    private var windowEnd: Int64?
    private var completed = false

    private init(
        policy: BodyPolicy, counter: MediaNetworkByteCounter?,
        completion: @escaping @Sendable (Result<MediaNetworkResponse, any Error>) -> Void
    ) {
        self.policy = policy
        self.counter = counter
        self.completion = completion
        super.init()
    }

    static func makeTask(
        session: URLSession, request: URLRequest, policy: BodyPolicy, counter: MediaNetworkByteCounter?,
        completion: @escaping @Sendable (Result<MediaNetworkResponse, any Error>) -> Void
    ) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.delegate = MediaNetworkDataTask(policy: policy, counter: counter, completion: completion)
        return task
    }

    static func load(
        session: URLSession, request: URLRequest, policy: BodyPolicy, counter: MediaNetworkByteCounter?
    ) async throws -> MediaNetworkResponse {
        let cancellation = MediaNetworkDataTaskCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: MediaNetworkResponse = try await withCheckedThrowingContinuation { continuation in
                let task = makeTask(session: session, request: request, policy: policy, counter: counter) {
                    continuation.resume(with: $0)
                }
                cancellation.install(task)
                task.resume()
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard !completed else { completionHandler(.cancel); return }
        self.response = response
        // Consumers need the original status/headers, not an error-page body.
        if let http = response as? HTTPURLResponse, !acceptsBody(status: http.statusCode) {
            finishResponse(isCompleteBody: false)
            completionHandler(.cancel)
            return
        }
        do {
            try admit(response)
            completionHandler(.allow)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Delivered/discarded/late bytes still belong to this request's wire
        // counter. They never enter another stream's total or this body twice.
        counter?.add(data.count)
        guard !completed else { return }
        do {
            try append(data)
            if let windowEnd, receivedBodyBytes >= windowEnd {
                finishResponse(isCompleteBody: false)
                dataTask.cancel()
            }
        } catch {
            finish(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !completed else { return }
        if let error {
            finish(.failure(error))
        } else if let declaredBodyLength, declaredBodyLength != receivedBodyBytes {
            finish(.failure(PathAHTTPMediaSource.SourceError.invalidRange))
        } else {
            finishResponse(isCompleteBody: true)
        }
    }

    private func acceptsBody(status: Int) -> Bool {
        switch policy {
        case .complete: (200..<300).contains(status)
        case .window: status == 200 || status == 206
        }
    }

    private func admit(_ response: URLResponse) throws {
        guard policy.maximumBytes >= 0 else { throw BodyError.exceedsBound }
        guard let http = response as? HTTPURLResponse else { return }
        if case .complete = policy {
            // HLS may use gzip/br: URLSession delivers decoded bytes while
            // Content-Length describes the encoded body. Use only a matching
            // identity length as an early limit hint; the actual decoded-byte
            // cap applies in append regardless of encoding or declared size.
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if encoding == nil || encoding == "identity",
               let length = try? PathAHTTPRangeValidator.declaredContentLength(
                    http.value(forHTTPHeaderField: "Content-Length")
               ), length > Int64(policy.maximumBytes) {
                throw BodyError.exceedsBound
            }
            return
        }
        try PathAHTTPRangeValidator.validateIdentityContentEncoding(
            http.value(forHTTPHeaderField: "Content-Encoding")
        )
        declaredBodyLength = try PathAHTTPRangeValidator.declaredContentLength(
            http.value(forHTTPHeaderField: "Content-Length")
        )
        if case .window(let window) = policy {
            if http.statusCode == 200 {
                retainedOffset = window.offset
                windowEnd = window.endExclusive
                return
            }
            if http.statusCode == 206 {
                let range = try PathAHTTPRangeValidator.validatePartialResponse(
                    http.value(forHTTPHeaderField: "Content-Range"), requested: window, bodyCount: nil
                )
                if let declaredBodyLength, let range, declaredBodyLength != range.length {
                    throw PathAHTTPMediaSource.SourceError.invalidRange
                }
            }
        }
        if let declaredBodyLength, declaredBodyLength > Int64(policy.maximumBytes) {
            throw BodyError.exceedsBound
        }
    }

    private func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard let count = Int64(exactly: data.count),
              let end = MediaByteRange.checkedEndExclusive(offset: receivedBodyBytes, length: count) else {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }
        if let declaredBodyLength, end > declaredBodyLength {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }
        let start = receivedBodyBytes
        receivedBodyBytes = end
        let retainedStart = max(start, retainedOffset)
        let retainedEnd = min(end, windowEnd ?? end)
        guard retainedEnd > retainedStart else { return }
        let retainedCount = Int(retainedEnd - retainedStart)
        guard retainedCount <= policy.maximumBytes - body.count else { throw BodyError.exceedsBound }
        let lower = data.index(data.startIndex, offsetBy: Int(retainedStart - start))
        let upper = data.index(lower, offsetBy: retainedCount)
        body.append(contentsOf: data[lower..<upper])
    }

    private func finishResponse(isCompleteBody: Bool) {
        guard let response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let isResourceResponse = (response as? HTTPURLResponse)?.statusCode == 200
        let resourceLength = isResourceResponse
            ? declaredBodyLength ?? (isCompleteBody ? receivedBodyBytes : nil) : nil
        finish(.success(MediaNetworkResponse(
            data: body, response: response, receivedBodyBytes: receivedBodyBytes,
            isCompleteBody: isCompleteBody, resourceLength: resourceLength
        )))
    }

    private func finish(_ result: Result<MediaNetworkResponse, any Error>) {
        guard !completed else { return }
        completed = true
        completion(result)
        body = Data()
    }
}

private final class MediaNetworkDataTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func install(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let current = lock.withLock {
            cancelled = true
            return task
        }
        current?.cancel()
    }
}
