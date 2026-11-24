import Darwin
import Foundation

// MARK: - Public Request / Outcome Types

struct SegmentedDownloadProfile: Sendable, Equatable {
    let wifiStartLevel: Int
    let wifiTotalBound: Int
    let wifiEdgeBound: Int
    let wifiSessionsPerEdge: Int
    let cellularStartLevel: Int
    let cellularTotalBound: Int
    let cellularEdgeBound: Int
    let cellularSessionsPerEdge: Int

    static let standardVideo = SegmentedDownloadProfile(
        wifiStartLevel: 6,
        wifiTotalBound: 16,
        wifiEdgeBound: 8,
        wifiSessionsPerEdge: 4,
        cellularStartLevel: 2,
        cellularTotalBound: 4,
        cellularEdgeBound: 4,
        cellularSessionsPerEdge: 2
    )

    static let videoWithConcurrentAudio = SegmentedDownloadProfile(
        wifiStartLevel: 6,
        wifiTotalBound: 16,
        wifiEdgeBound: 8,
        wifiSessionsPerEdge: 4,
        cellularStartLevel: 2,
        cellularTotalBound: 3,
        cellularEdgeBound: 3,
        cellularSessionsPerEdge: 2
    )

    static let concurrentAudio = SegmentedDownloadProfile(
        wifiStartLevel: 2,
        wifiTotalBound: 4,
        wifiEdgeBound: 4,
        wifiSessionsPerEdge: 2,
        cellularStartLevel: 1,
        cellularTotalBound: 1,
        cellularEdgeBound: 1,
        cellularSessionsPerEdge: 1
    )
}

struct SegmentedDownloadRequest: Sendable {
    let urls: [URL]
    let verifiedAPIHosts: Set<String>
    let destination: URL
    let headers: [String: String]
    let label: String
    let operationLabel: String
    let knownTotalLength: Int64?
    let initialCompletedRanges: [DownloadByteRange]
    let network: DownloadNetworkPolicy
    let profile: SegmentedDownloadProfile
}

struct SegmentedRefreshedCandidates: Sendable {
    let urls: [URL]
    let verifiedAPIHosts: Set<String>
}

enum SegmentedDownloadOutcome: Sendable, Equatable {
    case completed(FileDownloader.StageResult)
    case fallbackToSingleConnection(expectedBytes: Int64?)
}

// MARK: - SegmentedFileDownloader

final class SegmentedFileDownloader: @unchecked Sendable {
    static let probeChunkBytes: Int64 = 256 * 1024
    static let minimumSegmentedBytes: Int64 = 2 * 1024 * 1024
    static let minimumPieceBytes: Int64 = 512 * 1024
    static let maximumPieceBytes: Int64 = 4 * 1024 * 1024

    private let lock = NSLock()
    private var cancelled = false
    private let quietGate = MultiConnectionQuietGate(quiet: false)
    private var activeProbe: ProbeClient?
    private var activeTransport: MultiConnectionURLTransport?
    private var activeCoordinator: SegmentedDownloadCoordinator?

    func cancel() {
        let state = lock.withLock { () -> (ProbeClient?, MultiConnectionURLTransport?, SegmentedDownloadCoordinator?) in
            cancelled = true
            let result = (activeProbe, activeTransport, activeCoordinator)
            activeProbe = nil
            activeTransport = nil
            activeCoordinator = nil
            return result
        }
        quietGate.setParked(true)
        state.0?.cancel()
        state.1?.invalidateAndCancel()
        if let coordinator = state.2 {
            Task { await coordinator.cancel() }
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func download(
        _ request: SegmentedDownloadRequest,
        onProgress: @escaping @Sendable (_ receivedBytes: Int64, _ totalBytes: Int64) -> Void,
        onCheckpoint: @escaping @Sendable (_ completedRanges: [DownloadByteRange], _ totalBytes: Int64) -> Void,
        refreshURLs: (@Sendable () async throws -> SegmentedRefreshedCandidates)? = nil
    ) async throws -> SegmentedDownloadOutcome {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
        guard !request.urls.isEmpty else {
            return .fallbackToSingleConnection(expectedBytes: request.knownTotalLength)
        }

        // Fast-path: already verified complete on disk.
        if let known = request.knownTotalLength, known > 0 {
            let diskLength = FileDownloader.fileLength(request.destination)
            if diskLength == known,
               DownloadByteRange.isComplete(request.initialCompletedRanges, totalBytes: known) {
                PlayerLog.log(
                    "[Download] \(request.label) segmented already complete bytes=\(known) op=\(request.operationLabel)"
                )
                return .completed(FileDownloader.StageResult(bytesOnDisk: known, expectedBytes: known))
            }
            if known < Self.minimumSegmentedBytes {
                return .fallbackToSingleConnection(expectedBytes: known)
            }
        }

        // Check current network path before probing.
        let initialPath = PlayerViewModel.resolvedDownloadNetworkPath()
        if let initialPath {
            if initialPath.constrained {
                throw DownloadTransferError.lowDataModeNotAllowed
            }
            if initialPath.networkClass == .expensive, !request.network.allowsCellular {
                throw DownloadTransferError.cellularNotAllowed
            }
        }

        // Step 1: Initial Range Probe.
        let hasLeadingChunk = request.knownTotalLength != nil
            && DownloadByteRange.covers(request.initialCompletedRanges, target: 0..<Self.probeChunkBytes)
            && FileDownloader.fileLength(request.destination) >= Self.probeChunkBytes
        let probeEndInclusive: Int64 = hasLeadingChunk ? 0 : (Self.probeChunkBytes - 1)

        var currentURLs = request.urls
        var currentVerifiedHosts = request.verifiedAPIHosts
        var urlRefreshed = false

        let probeSuccess: ProbeSuccess
        while true {
            let probeResult = try await withTaskCancellationHandler {
                try await runProbe(
                    urls: currentURLs,
                    rangeEndInclusive: probeEndInclusive,
                    headers: request.headers,
                    network: request.network,
                    label: request.label,
                    operationLabel: request.operationLabel
                )
            } onCancel: {
                self.cancel()
            }

            switch probeResult {
            case .succeeded(let success):
                probeSuccess = success
            case .fallbackToSingle(let expectedBytes):
                PlayerLog.log(
                    "[Download] \(request.label) probe fallback (no 206 support) " +
                        "expected=\(expectedBytes.map(String.init) ?? "unknown") op=\(request.operationLabel)"
                )
                return .fallbackToSingleConnection(expectedBytes: expectedBytes)
            case .allFailed(let error):
                if !urlRefreshed, let refreshURLs {
                    urlRefreshed = true
                    PlayerLog.log(
                        "[Download] \(request.label) probe refreshing signed URLs op=\(request.operationLabel)"
                    )
                    if let refreshed = try? await refreshURLs(), !refreshed.urls.isEmpty {
                        currentURLs = refreshed.urls
                        currentVerifiedHosts = refreshed.verifiedAPIHosts
                        continue
                    }
                }
                throw error
            }
            break
        }

        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }

        let totalLength = probeSuccess.totalLength
        let probeData = probeSuccess.data

        // Small file check: < 2 MB falls back to single-connection (or finishes immediately if probe got all bytes).
        if totalLength < Self.minimumSegmentedBytes {
            if !hasLeadingChunk, Int64(probeData.count) == totalLength {
                let sink = try RandomAccessFileSink(destination: request.destination, initialRanges: [])
                defer { _ = sink.close() }
                try sink.reset()
                _ = try sink.write(at: 0, data: probeData)
                let finalRanges = [DownloadByteRange(start: 0, end: totalLength)]
                onCheckpoint(finalRanges, totalLength)
                onProgress(totalLength, totalLength)
                PlayerLog.log(
                    "[Download] \(request.label) completed in probe bytes=\(totalLength) op=\(request.operationLabel)"
                )
                return .completed(FileDownloader.StageResult(bytesOnDisk: totalLength, expectedBytes: totalLength))
            }
            // Write the 256 KB probe bytes to disk if file is empty so FileDownloader doesn't waste them.
            if !hasLeadingChunk, !probeData.isEmpty,
               request.initialCompletedRanges.isEmpty,
               FileDownloader.fileLength(request.destination) == 0 {
                if let sink = try? RandomAccessFileSink(destination: request.destination, initialRanges: []) {
                    _ = try? sink.write(at: 0, data: probeData)
                    _ = sink.close()
                }
            }
            PlayerLog.log(
                "[Download] \(request.label) small file (\(totalLength)B < \(Self.minimumSegmentedBytes)B) → single-connection op=\(request.operationLabel)"
            )
            return .fallbackToSingleConnection(expectedBytes: totalLength)
        }

        // Step 2: Open random-access file sink without truncating valid staged ranges.
        let diskBefore = FileDownloader.fileLength(request.destination)
        var seededRanges = request.initialCompletedRanges
        let needsReset = (request.knownTotalLength != nil && request.knownTotalLength != totalLength)
            || diskBefore > totalLength
            || (diskBefore == 0 && !seededRanges.isEmpty)
        if needsReset {
            seededRanges = []
        } else {
            seededRanges = DownloadByteRange.clamped(seededRanges, totalBytes: totalLength)
        }

        let sink = try RandomAccessFileSink(destination: request.destination, initialRanges: seededRanges)
        if needsReset {
            try sink.reset()
            PlayerLog.log(
                "[Download] \(request.label) reset staged partial (length changed to \(totalLength)B) op=\(request.operationLabel)"
            )
        }

        if !probeData.isEmpty {
            let probeSpan: Range<Int64> = 0..<Int64(probeData.count)
            if !DownloadByteRange.covers(sink.completedRangesSnapshot(), target: probeSpan) {
                _ = try sink.write(at: 0, data: probeData)
            }
        }

        let initialRanges = sink.completedRangesSnapshot()
        let initialBytes = sink.completedBytesSnapshot()
        onCheckpoint(initialRanges, totalLength)
        onProgress(initialBytes, totalLength)

        if DownloadByteRange.isComplete(initialRanges, totalBytes: totalLength) {
            _ = sink.close()
            return .completed(FileDownloader.StageResult(bytesOnDisk: totalLength, expectedBytes: totalLength))
        }

        // Step 3: Build adaptive MultiConnectionPolicy & transport.
        let resolvedPath = PlayerViewModel.resolvedDownloadNetworkPath()
        let isCellular = resolvedPath?.networkClass == .expensive
        let policy = Self.makePolicy(
            profile: request.profile,
            isCellular: isCellular,
            verifiedAPIHosts: currentVerifiedHosts
        )
        let transport = MultiConnectionURLTransport(
            policy: policy,
            allowsCellular: request.network.allowsCellular,
            allowsExpensive: request.network.allowsCellular,
            timeoutIntervalForRequest: 20
        )

        let coordinator = SegmentedDownloadCoordinator(
            totalLength: totalLength,
            sink: sink,
            transport: transport,
            quietGate: quietGate,
            headers: request.headers,
            label: request.label,
            operationLabel: request.operationLabel,
            network: request.network,
            policy: policy,
            cellularCap: max(1, request.profile.cellularTotalBound),
            candidateURLs: currentURLs,
            verifiedAPIHosts: currentVerifiedHosts,
            probeSeed: ProbeSeed(
                host: probeSuccess.host,
                bytes: Int64(probeData.count),
                elapsed: probeSuccess.elapsed,
                connection: probeSuccess.connection,
                failedHosts: probeSuccess.failedHosts
            ),
            urlAlreadyRefreshed: urlRefreshed,
            onProgress: onProgress,
            onCheckpoint: onCheckpoint,
            refreshURLs: refreshURLs
        )

        let shouldCancelImmediately = lock.withLock { () -> Bool in
            if cancelled { return true }
            activeTransport = transport
            activeCoordinator = coordinator
            return false
        }
        if shouldCancelImmediately {
            transport.invalidateAndCancel()
            await coordinator.cancel()
            throw CancellationError()
        }

        defer {
            lock.withLock {
                if activeTransport === transport { activeTransport = nil }
                if activeCoordinator === coordinator { activeCoordinator = nil }
            }
            transport.invalidateAndCancel()
        }

        let stageResult = try await withTaskCancellationHandler {
            try await coordinator.run()
        } onCancel: {
            self.cancel()
        }
        return .completed(stageResult)
    }

    private static func makePolicy(
        profile: SegmentedDownloadProfile,
        isCellular: Bool,
        verifiedAPIHosts: Set<String>
    ) -> MultiConnectionPolicy {
        if isCellular {
            let bound = max(1, profile.cellularTotalBound)
            let start = max(1, min(bound, profile.cellularStartLevel))
            let edge = max(1, min(bound, profile.cellularEdgeBound))
            let sessions = max(1, min(MultiConnectionPolicy.maximumSessionsPerEdge, profile.cellularSessionsPerEdge))
            return MultiConnectionPolicy(
                networkClass: .expensive,
                auto: bound > 1,
                startLevel: start,
                totalBound: bound,
                edgeBound: edge,
                hostSlots: max(2, bound),
                sessionsPerEdge: sessions,
                explores: bound > 1,
                fixedRequestLimit: start,
                fixedWorkLimit: 1,
                verifiedAPIHosts: verifiedAPIHosts
            )
        }
        let bound = max(1, profile.wifiTotalBound)
        let start = max(1, min(bound, profile.wifiStartLevel))
        let edge = max(1, min(bound, profile.wifiEdgeBound))
        let sessions = max(1, min(MultiConnectionPolicy.maximumSessionsPerEdge, profile.wifiSessionsPerEdge))
        return MultiConnectionPolicy(
            networkClass: .wifi,
            auto: bound > 1,
            startLevel: start,
            totalBound: bound,
            edgeBound: edge,
            hostSlots: 8,
            sessionsPerEdge: sessions,
            explores: bound > 1,
            fixedRequestLimit: start,
            fixedWorkLimit: 2,
            verifiedAPIHosts: verifiedAPIHosts
        )
    }

    // MARK: - Probe orchestration

    private struct ProbeSuccess: Sendable {
        let data: Data
        let totalLength: Int64
        let host: String
        let elapsed: TimeInterval
        let connection: MultiConnectionResponse.Connection?
        let failedHosts: Set<String>
    }

    private enum ProbeLoopOutcome {
        case succeeded(ProbeSuccess)
        case fallbackToSingle(expectedBytes: Int64?)
        case allFailed(Error)
    }

    private func runProbe(
        urls: [URL],
        rangeEndInclusive: Int64,
        headers: [String: String],
        network: DownloadNetworkPolicy,
        label: String,
        operationLabel: String
    ) async throws -> ProbeLoopOutcome {
        let client = ProbeClient(network: network)
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            activeProbe = client
            return false
        }
        if alreadyCancelled {
            client.cancel()
            throw CancellationError()
        }
        defer {
            lock.withLock {
                if activeProbe === client { activeProbe = nil }
            }
            client.invalidateAndCancel()
        }

        let now = Date()
        let freshURLs = urls.filter { MultiConnectionPlanner.isFresh($0, now: now) }
        let candidates = freshURLs.isEmpty ? urls : freshURLs
        var lastError: Error = DownloadTransferError.invalidURL
        var failedHosts: Set<String> = []

        for url in candidates {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }

            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("bytes=0-\(rangeEndInclusive)", forHTTPHeaderField: "Range")
            network.apply(to: &request)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15

            let outcome = await client.probe(request: request, maxBytes: Int(rangeEndInclusive + 1))
            let host = url.host ?? "unknown"
            switch outcome {
            case let .partial(data, contentRange, connection, elapsed):
                guard let total = contentRange.totalLength, total > 0,
                      contentRange.firstByte == 0,
                      Int64(data.count) == contentRange.lastByte - contentRange.firstByte + 1 else {
                    failedHosts.insert(host)
                    lastError = DownloadTransferError.rangeNotHonoured(host: host)
                    continue
                }
                PlayerLog.log(
                    "[Download] \(label) probe 206 host=\(host) bytes=\(data.count)/\(total) " +
                        "ms=\(Int(elapsed * 1000)) op=\(operationLabel)"
                )
                return .succeeded(ProbeSuccess(
                    data: data,
                    totalLength: total,
                    host: host,
                    elapsed: elapsed,
                    connection: connection,
                    failedHosts: failedHosts
                ))
            case .noRangeSupport(let contentLength):
                return .fallbackToSingle(expectedBytes: contentLength)
            case .policyUnavailable(let error):
                throw error
            case .cancelled:
                throw CancellationError()
            case .refused(let status):
                failedHosts.insert(host)
                lastError = DownloadTransferError.httpStatus(host: host, code: status)
            case .retryableFailure(let error):
                failedHosts.insert(host)
                lastError = error
            }
        }

        return .allFailed(lastError)
    }
}

// MARK: - Random-Access POSIX pwrite File Sink

private final class RandomAccessFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var closed = false
    private var completedRanges: [DownloadByteRange]
    private var completedBytes: Int64

    init(destination: URL, initialRanges: [DownloadByteRange]) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let opened = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDWR | O_CREAT, mode_t(0o644))
        }
        guard opened >= 0 else {
            let code = errno
            if code == ENOSPC {
                throw DownloadTransferError.outOfSpace
            }
            let detail = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
            throw DownloadTransferError.partialFileUnwritable(detail)
        }
        self.fd = opened
        let coalesced = DownloadByteRange.coalesce(initialRanges)
        self.completedRanges = coalesced
        self.completedBytes = DownloadByteRange.totalBytes(in: coalesced)
    }

    deinit {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    func reset() throws {
        try lock.withLock {
            guard !closed, fd >= 0 else { throw CancellationError() }
            if Darwin.ftruncate(fd, 0) != 0 {
                let code = errno
                if code == ENOSPC { throw DownloadTransferError.outOfSpace }
                let detail = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
                throw DownloadTransferError.partialFileUnwritable(detail)
            }
            completedRanges = []
            completedBytes = 0
        }
    }

    @discardableResult
    func write(at offset: Int64, data: Data) throws -> Int64 {
        guard !data.isEmpty else {
            return lock.withLock { completedBytes }
        }
        guard offset >= 0 else {
            throw DownloadTransferError.partialFileUnwritable("negative write offset")
        }
        return try lock.withLock {
            guard !closed, fd >= 0 else { throw CancellationError() }
            var written = 0
            let total = data.count
            var writeError: Error?

            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                while written < total {
                    let count = Darwin.pwrite(
                        fd,
                        base.advanced(by: written),
                        total - written,
                        off_t(offset) + off_t(written)
                    )
                    if count > 0 {
                        written += count
                    } else if count == -1, errno == EINTR {
                        continue
                    } else {
                        let code = errno
                        if code == ENOSPC {
                            writeError = DownloadTransferError.outOfSpace
                        } else {
                            let detail = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
                            writeError = DownloadTransferError.partialFileUnwritable(detail)
                        }
                        break
                    }
                }
            }

            if written > 0 {
                let added = DownloadByteRange.insert(
                    DownloadByteRange(start: offset, end: offset + Int64(written)),
                    into: &completedRanges
                )
                let (sum, overflow) = completedBytes.addingReportingOverflow(added)
                completedBytes = overflow ? Int64.max : sum
            }

            if let writeError {
                throw writeError
            }
            return completedBytes
        }
    }

    func completedRangesSnapshot() -> [DownloadByteRange] {
        lock.withLock { completedRanges }
    }

    func completedBytesSnapshot() -> Int64 {
        lock.withLock { completedBytes }
    }

    @discardableResult
    func close() -> (ranges: [DownloadByteRange], bytes: Int64) {
        lock.withLock {
            guard !closed else { return (completedRanges, completedBytes) }
            closed = true
            if fd >= 0 {
                _ = Darwin.fsync(fd)
                _ = Darwin.close(fd)
                fd = -1
            }
            return (completedRanges, completedBytes)
        }
    }
}

// MARK: - Lightweight Range Probe Client

private final class ProbeClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        case partial(
            data: Data,
            contentRange: DownloadContentRange,
            connection: MultiConnectionResponse.Connection?,
            elapsed: TimeInterval
        )
        case noRangeSupport(contentLength: Int64?)
        case refused(status: Int)
        case policyUnavailable(DownloadTransferError)
        case retryableFailure(Error)
        case cancelled
    }

    private struct ActiveProbe {
        let task: URLSessionDataTask
        let maxBytes: Int
        let startedAt: TimeInterval
        let host: String
        let continuation: CheckedContinuation<Outcome, Never>
        var contentRange: DownloadContentRange?
        var expectedBodyBytes: Int = 0
        var buffer = Data()
        var connection: MultiConnectionResponse.Connection?
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var cancelled = false
    private var current: ActiveProbe?

    init(network: DownloadNetworkPolicy) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = network.allowsCellular
        config.allowsExpensiveNetworkAccess = network.allowsCellular
        config.allowsConstrainedNetworkAccess = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func probe(request: URLRequest, maxBytes: Int) async -> Outcome {
        await withCheckedContinuation { continuation in
            let taskToResume: URLSessionDataTask? = lock.withLock {
                guard !cancelled, let session else { return nil }
                let task = session.dataTask(with: request)
                task.priority = URLSessionTask.highPriority
                current = ActiveProbe(
                    task: task,
                    maxBytes: maxBytes,
                    startedAt: ProcessInfo.processInfo.systemUptime,
                    host: request.url?.host ?? "unknown",
                    continuation: continuation
                )
                return task
            }
            if let taskToResume {
                taskToResume.resume()
            } else {
                continuation.resume(returning: .cancelled)
            }
        }
    }

    func cancel() {
        let active: ActiveProbe? = lock.withLock {
            cancelled = true
            let previous = current
            current = nil
            return previous
        }
        active?.task.cancel()
        active?.continuation.resume(returning: .cancelled)
    }

    func invalidateAndCancel() {
        cancel()
        let activeSession = lock.withLock { () -> URLSession? in
            let existing = session
            session = nil
            return existing
        }
        activeSession?.invalidateAndCancel()
    }

    private func settle(taskIdentifier: Int, with outcome: Outcome) {
        let active: ActiveProbe? = lock.withLock {
            guard let existing = current, existing.task.taskIdentifier == taskIdentifier else {
                return nil
            }
            current = nil
            return existing
        }
        active?.continuation.resume(returning: outcome)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              Self.isAllowedRedirect(from: task.originalRequest?.url ?? response.url, to: target) else {
            completionHandler(nil)
            settle(
                taskIdentifier: task.taskIdentifier,
                with: .retryableFailure(DownloadTransferError.rangeNotHonoured(host: response.url?.host ?? "unknown"))
            )
            return
        }
        completionHandler(request)
    }

    private static func isAllowedRedirect(from sourceURL: URL?, to targetURL: URL) -> Bool {
        guard let targetScheme = targetURL.scheme?.lowercased(),
              targetScheme == "http" || targetScheme == "https",
              let host = targetURL.host, !host.isEmpty,
              targetURL.user == nil, targetURL.password == nil else {
            return false
        }
        if sourceURL?.scheme?.lowercased() == "https", targetScheme == "http" {
            return false
        }
        return true
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            settle(taskIdentifier: dataTask.taskIdentifier, with: .retryableFailure(DownloadTransferError.nonHTTP))
            return
        }

        let status = http.statusCode
        let host = http.url?.host ?? "unknown"
        if let refusal = MultiConnectionTransportError.refusal(
            status: status, contentType: http.value(forHTTPHeaderField: "Content-Type")
        ), case .refused(let code) = refusal {
            completionHandler(.cancel)
            settle(taskIdentifier: dataTask.taskIdentifier, with: .refused(status: code))
            return
        }

        if status == 200 {
            let contentLength = response.expectedContentLength > 0
                ? Int64(response.expectedContentLength) : nil
            completionHandler(.cancel)
            settle(taskIdentifier: dataTask.taskIdentifier, with: .noRangeSupport(contentLength: contentLength))
            return
        }

        guard status == 206 else {
            completionHandler(.cancel)
            settle(
                taskIdentifier: dataTask.taskIdentifier,
                with: .retryableFailure(DownloadTransferError.httpStatus(host: host, code: status))
            )
            return
        }

        let rejection: Outcome? = lock.withLock {
            guard var probe = current, probe.task.taskIdentifier == dataTask.taskIdentifier else {
                return .cancelled
            }
            guard let parsed = DownloadContentRange.parse(http.value(forHTTPHeaderField: "Content-Range")),
                  parsed.firstByte == 0,
                  let total = parsed.totalLength, total > 0 else {
                return .retryableFailure(DownloadTransferError.rangeNotHonoured(host: host))
            }
            let rangeLen = parsed.lastByte - parsed.firstByte + 1
            guard rangeLen > 0, rangeLen <= Int64(probe.maxBytes),
                  let expectedInt = Int(exactly: rangeLen) else {
                return .retryableFailure(DownloadTransferError.rangeNotHonoured(host: host))
            }
            if let rawLength = http.value(forHTTPHeaderField: "Content-Length"),
               let declared = Int64(rawLength.trimmingCharacters(in: .whitespaces)),
               declared != rangeLen {
                return .retryableFailure(DownloadTransferError.rangeNotHonoured(host: host))
            }
            probe.contentRange = parsed
            probe.expectedBodyBytes = expectedInt
            probe.buffer.reserveCapacity(expectedInt)
            current = probe
            return nil
        }

        if let outcome = rejection {
            completionHandler(.cancel)
            settle(taskIdentifier: dataTask.taskIdentifier, with: outcome)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceededHost: String? = lock.withLock {
            guard var probe = current, probe.task.taskIdentifier == dataTask.taskIdentifier,
                  probe.contentRange != nil else { return nil }
            if probe.buffer.count + data.count > probe.expectedBodyBytes {
                return probe.host
            }
            probe.buffer.append(data)
            current = probe
            return nil
        }
        if let exceededHost {
            dataTask.cancel()
            settle(
                taskIdentifier: dataTask.taskIdentifier,
                with: .retryableFailure(DownloadTransferError.rangeNotHonoured(host: exceededHost))
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let metric = metrics.transactionMetrics.last,
              let remote = metric.remoteAddress,
              let localPort = metric.localPort else { return }
        lock.withLock {
            guard var probe = current, probe.task.taskIdentifier == task.taskIdentifier else { return }
            probe.connection = MultiConnectionResponse.Connection(
                remote: remote,
                localPort: localPort,
                networkProtocol: metric.networkProtocolName ?? "unknown",
                reused: metric.isReusedConnection
            )
            current = probe
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let classified = DownloadTransferError.classify(error) {
                switch classified {
                case .cellularNotAllowed, .lowDataModeNotAllowed, .expensiveNetworkNotAllowed:
                    settle(taskIdentifier: task.taskIdentifier, with: .policyUnavailable(classified))
                    return
                default:
                    break
                }
            }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                settle(taskIdentifier: task.taskIdentifier, with: .cancelled)
                return
            }
            settle(taskIdentifier: task.taskIdentifier, with: .retryableFailure(error))
            return
        }

        let settled: (CheckedContinuation<Outcome, Never>, Outcome)? = lock.withLock {
            guard let probe = current, probe.task.taskIdentifier == task.taskIdentifier else { return nil }
            current = nil
            guard let range = probe.contentRange, probe.buffer.count == probe.expectedBodyBytes else {
                return (
                    probe.continuation,
                    .retryableFailure(DownloadTransferError.rangeNotHonoured(host: probe.host))
                )
            }
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - probe.startedAt)
            return (
                probe.continuation,
                .partial(
                    data: probe.buffer,
                    contentRange: range,
                    connection: probe.connection,
                    elapsed: elapsed
                )
            )
        }
        if let settled {
            settled.0.resume(returning: settled.1)
        }
    }
}

// MARK: - Adaptive Multi-CDN Piece Scheduler

private struct ProbeSeed: Sendable {
    let host: String
    let bytes: Int64
    let elapsed: TimeInterval
    let connection: MultiConnectionResponse.Connection?
    let failedHosts: Set<String>
}

private actor SegmentedDownloadCoordinator {
    private static let maxPieceRetries = 10
    private static let maxCooldownWaits = 3
    private static let progressReportInterval: TimeInterval = DownloadProgressEventCoalescer.defaultMinimumInterval
    private static let checkpointInterval: TimeInterval = 1.5
    private static let checkpointByteThreshold: Int64 = 4 * 1024 * 1024
    private static let stallWatchInterval: TimeInterval = 0.50
    private static let zeroByteStallDelay: TimeInterval = 2.0
    private static let midPieceStallDelay: TimeInterval = 2.5
    private static let tailSlowDelay: TimeInterval = 3.0
    private static let tailSlowFloorBytesPerSec: Double = 128 * 1024

    private struct HostState {
        var speed: Double?
        var failures = 0
        var demotedUntil: TimeInterval = 0
        var pieces = 0
        var bytes: Int64 = 0
        var connection: MultiConnectionResponse.Connection?
    }

    private struct Flight {
        let id: UUID
        let host: String
        let lane: Int
        let startedAt: TimeInterval
        var lastProgressAt: TimeInterval
        var bytesReceived: Int64 = 0
        let requestRange: Range<Int64>
        let task: Task<Void, Never>
    }

    private struct ActivePiece {
        let range: Range<Int64>
        var receivedThrough: Int64
        var primary: Flight
        var hedge: Flight?
        var failedHosts: Set<String>
        var retries: Int
    }

    private struct DeferredPiece {
        let range: Range<Int64>
        var failedHosts: Set<String>
        var retries: Int
    }

    private let totalLength: Int64
    private let sink: RandomAccessFileSink
    private let transport: MultiConnectionURLTransport
    private let quietGate: MultiConnectionQuietGate
    private let headers: [String: String]
    private let label: String
    private let operationLabel: String
    private let network: DownloadNetworkPolicy
    private let policy: MultiConnectionPolicy
    private let cellularCap: Int
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onCheckpoint: @Sendable ([DownloadByteRange], Int64) -> Void
    private let refreshURLs: (@Sendable () async throws -> SegmentedRefreshedCandidates)?
    private let clock: @Sendable () -> TimeInterval
    private let memo = MultiConnectionLadderMemo.shared
    private let memoGeneration: UInt64

    private var memoFrozen = false
    private var controller: MultiConnectionConcurrencyController
    private var allocation = MultiConnectionConcurrencyController.Allocation()
    private var candidateURLs: [URL]
    private var tier1Hosts: Set<String>
    private var hosts: [String: HostState] = [:]

    private var pendingSpans: [Range<Int64>]
    private var deferredPieces: [DeferredPiece] = []
    private var activePieces: [Int64: ActivePiece] = [:]

    private var finished = false
    private var terminalResult: Result<FileDownloader.StageResult, Error>?
    private var completionContinuation: CheckedContinuation<FileDownloader.StageResult, Error>?

    private var stallWatchTask: Task<Void, Never>?
    private var cooldownWakeTask: Task<Void, Never>?
    private var urlRefreshTask: Task<Void, Never>?

    private var urlRefreshAttempted: Bool
    private var urlRefreshing = false
    private var cooldownWaits = 0
    private var lastError: Error?

    private var lastProgressReportAt: TimeInterval = 0
    private var lastReportedBytes: Int64
    private var lastCheckpointAt: TimeInterval
    private var bytesSinceCheckpoint: Int64 = 0
    private var totalPiecesCompleted = 0
    private var hedgesIssued = 0
    private var refusals = 0

    init(
        totalLength: Int64,
        sink: RandomAccessFileSink,
        transport: MultiConnectionURLTransport,
        quietGate: MultiConnectionQuietGate,
        headers: [String: String],
        label: String,
        operationLabel: String,
        network: DownloadNetworkPolicy,
        policy: MultiConnectionPolicy,
        cellularCap: Int,
        candidateURLs: [URL],
        verifiedAPIHosts: Set<String>,
        probeSeed: ProbeSeed,
        urlAlreadyRefreshed: Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onCheckpoint: @escaping @Sendable ([DownloadByteRange], Int64) -> Void,
        refreshURLs: (@Sendable () async throws -> SegmentedRefreshedCandidates)?,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.totalLength = totalLength
        self.sink = sink
        self.transport = transport
        self.quietGate = quietGate
        self.headers = headers
        self.label = label
        self.operationLabel = operationLabel
        self.network = network
        self.policy = policy
        self.cellularCap = cellularCap
        self.candidateURLs = candidateURLs
        self.urlRefreshAttempted = urlAlreadyRefreshed
        self.onProgress = onProgress
        self.onCheckpoint = onCheckpoint
        self.refreshURLs = refreshURLs
        self.clock = clock

        let now = clock()
        let learned = memo.entryAndGeneration(for: policy.networkClass)
        self.memoGeneration = learned.generation
        self.controller = MultiConnectionConcurrencyController(
            policy: policy,
            memo: learned.entry,
            now: now
        )
        if let primary = candidateURLs.first {
            self.tier1Hosts = MultiConnectionPlanner.tier1Hosts(
                for: candidateURLs,
                primary: primary,
                verifiedAPIHosts: verifiedAPIHosts
            )
        } else {
            self.tier1Hosts = verifiedAPIHosts
        }

        let currentRanges = sink.completedRangesSnapshot()
        self.pendingSpans = DownloadByteRange.missingRanges(in: currentRanges, totalBytes: totalLength)
            .map(\.range)
        self.lastReportedBytes = sink.completedBytesSnapshot()
        self.lastCheckpointAt = now

        if !probeSeed.host.isEmpty {
            var state = HostState()
            if probeSeed.bytes >= 65_536, probeSeed.elapsed > 0 {
                state.speed = Double(probeSeed.bytes) / max(0.01, probeSeed.elapsed)
                state.pieces = 1
            }
            state.bytes = probeSeed.bytes
            state.connection = probeSeed.connection
            hosts[probeSeed.host] = state
        }
        for failed in probeSeed.failedHosts where failed != probeSeed.host {
            var state = hosts[failed] ?? HostState()
            state.failures = 1
            hosts[failed] = state
        }
    }

    deinit {
        stallWatchTask?.cancel()
        cooldownWakeTask?.cancel()
        urlRefreshTask?.cancel()
    }

    func run() async throws -> FileDownloader.StageResult {
        try await withCheckedThrowingContinuation { continuation in
            if let terminalResult {
                continuation.resume(with: terminalResult)
                return
            }
            completionContinuation = continuation
            PlayerLog.log(
                "[Download] \(label) segmented start bytes=\(totalLength) " +
                    "missing=\(totalPendingBytes)B hosts=\(candidateURLs.count) " +
                    "class=\(policy.networkClass.rawValue) level=\(controller.level) " +
                    "bound=\(policy.totalBound) edgeBound=\(policy.edgeBound) op=\(operationLabel)"
            )
            schedule()
        }
    }

    func cancel() {
        finish(with: .failure(CancellationError()))
    }

    // MARK: - Core Scheduling

    private var hasQueuedWork: Bool {
        !pendingSpans.isEmpty || !deferredPieces.isEmpty
    }

    private var activeFlightCount: Int {
        activePieces.values.reduce(0) { $0 + 1 + ($1.hedge != nil ? 1 : 0) }
    }

    private var totalPendingBytes: Int64 {
        let spanBytes = pendingSpans.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        let deferredBytes = deferredPieces.reduce(Int64(0)) { $0 + ($1.range.upperBound - $1.range.lowerBound) }
        return spanBytes + deferredBytes
    }

    private func edgeKey(_ host: String) -> String {
        hosts[host]?.connection?.remote ?? host
    }

    private func isTier1Host(_ host: String) -> Bool {
        tier1Hosts.contains(MultiConnectionPlanner.canonicalHost(host))
    }

    private func isIdentified(_ host: String) -> Bool {
        guard let state = hosts[host] else { return false }
        return state.connection != nil || state.pieces > 0
    }

    private func schedule() {
        guard !finished else { return }

        if !hasQueuedWork && activePieces.isEmpty {
            let ranges = sink.completedRangesSnapshot()
            if DownloadByteRange.isComplete(ranges, totalBytes: totalLength) {
                finish(with: .success(
                    FileDownloader.StageResult(bytesOnDisk: totalLength, expectedBytes: totalLength)
                ))
                return
            }
            let missing = DownloadByteRange.missingRanges(in: ranges, totalBytes: totalLength)
            if missing.isEmpty {
                finish(with: .failure(DownloadTransferError.incompleteTransfer))
                return
            }
            pendingSpans = missing.map(\.range)
        }

        // Dynamic network policy & cellular concurrency cap check.
        var effectiveLevel = policy.auto ? controller.level : policy.fixedRequestLimit
        var effectiveEdgeBound = max(1, policy.edgeBound)
        if let path = PlayerViewModel.resolvedDownloadNetworkPath() {
            if path.constrained {
                finish(with: .failure(DownloadTransferError.lowDataModeNotAllowed))
                return
            }
            if path.networkClass == .expensive {
                if !network.allowsCellular {
                    finish(with: .failure(DownloadTransferError.cellularNotAllowed))
                    return
                }
                effectiveLevel = min(effectiveLevel, cellularCap)
                effectiveEdgeBound = min(effectiveEdgeBound, cellularCap)
            }
        }
        effectiveLevel = max(1, effectiveLevel)

        let now = clock()
        let currentDate = Date()
        let freshURLs = candidateURLs.filter { MultiConnectionPlanner.isFresh($0, now: currentDate) }
        if freshURLs.isEmpty {
            if !urlRefreshAttempted && !urlRefreshing && refreshURLs != nil {
                triggerURLRefresh(reason: "urls_expired")
                return
            }
            if activePieces.isEmpty && !urlRefreshing {
                finish(with: .failure(lastError ?? DownloadTransferError.incompleteTransfer))
            }
            return
        }

        let eligibleURLs = freshURLs.filter { url in
            let host = url.host ?? ""
            return !host.isEmpty && (hosts[host]?.demotedUntil ?? 0) <= now
        }
        if eligibleURLs.isEmpty {
            if !urlRefreshAttempted && !urlRefreshing && refreshURLs != nil && refusals > 0 {
                triggerURLRefresh(reason: "hosts_refused")
                return
            }
            if activePieces.isEmpty && !urlRefreshing {
                scheduleCooldownWake(freshURLs: freshURLs, now: now)
            }
            return
        }

        cancelCooldownWake()

        let admittedCapacity = launchPass(
            eligibleURLs: eligibleURLs,
            effectiveLevel: effectiveLevel,
            effectiveEdgeBound: effectiveEdgeBound,
            now: now
        )

        if policy.auto {
            let decisions = observeLadder(
                now: now,
                effectiveLevel: effectiveLevel,
                admittedCapacity: admittedCapacity
            )
            if decisions.contains(where: { if case .stepUp = $0 { true } else { false } }) {
                let steppedLevel: Int
                if PlayerViewModel.resolvedDownloadNetworkPath()?.networkClass == .expensive {
                    steppedLevel = min(controller.level, cellularCap)
                } else {
                    steppedLevel = controller.level
                }
                _ = launchPass(
                    eligibleURLs: eligibleURLs,
                    effectiveLevel: max(1, steppedLevel),
                    effectiveEdgeBound: effectiveEdgeBound,
                    now: clock()
                )
            }
        }

        if activePieces.isEmpty && hasQueuedWork && !urlRefreshing {
            if !urlRefreshAttempted && refreshURLs != nil {
                triggerURLRefresh(reason: "no_launchable_host")
            } else {
                finish(with: .failure(lastError ?? DownloadTransferError.incompleteTransfer))
            }
            return
        }

        if !activePieces.isEmpty {
            armStallWatchIfNeeded()
        } else {
            cancelStallWatch()
        }
    }

    @discardableResult
    private func launchPass(
        eligibleURLs: [URL],
        effectiveLevel: Int,
        effectiveEdgeBound: Int,
        now: TimeInterval
    ) -> Int {
        let laneCount = max(1, policy.sessionsPerEdge)
        var inFlightByEdge: [String: Int] = [:]
        var laneLoads: [String: [Int]] = [:]
        for piece in activePieces.values {
            for flight in [piece.primary] + (piece.hedge.map { [$0] } ?? []) {
                let edge = edgeKey(flight.host)
                inFlightByEdge[edge, default: 0] += 1
                var loads = laneLoads[edge] ?? Array(repeating: 0, count: laneCount)
                loads[max(0, flight.lane) % laneCount] += 1
                laneLoads[edge] = loads
            }
        }

        let explore = explorationEdge(eligibleURLs: eligibleURLs)
        let (edges, admittedCapacity) = buildEdges(
            from: eligibleURLs,
            effectiveEdgeBound: effectiveEdgeBound,
            now: now
        )
        let recoveryEligible = Set(eligibleURLs.map { edgeKey($0.host ?? "") })
        allocation = controller.allocate(
            edges: edges,
            explore: explore,
            now: now,
            retainingSamples: Set(candidateURLs.compactMap(\.host)),
            inFlight: inFlightByEdge,
            recoveryEligible: recoveryEligible
        )

        var orderedURLs = eligibleURLs
        let rankIndex = Dictionary(
            uniqueKeysWithValues: allocation.ranked.enumerated().map { ($1, $0) }
        )
        orderedURLs.sort { lhs, rhs in
            let leftHost = lhs.host ?? "", rightHost = rhs.host ?? ""
            let leftEdge = edgeKey(leftHost), rightEdge = edgeKey(rightHost)
            if let recovery = allocation.recoveryKey {
                let leftRec = leftEdge == recovery, rightRec = rightEdge == recovery
                if leftRec != rightRec { return leftRec }
            }
            let leftRank = rankIndex[leftEdge] ?? Int.max
            let rightRank = rankIndex[rightEdge] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            let leftTrusted = isTier1Host(leftHost) || isIdentified(leftHost)
            let rightTrusted = isTier1Host(rightHost) || isIdentified(rightHost)
            if leftTrusted != rightTrusted { return leftTrusted }
            return (hosts[leftHost]?.speed ?? 0) > (hosts[rightHost]?.speed ?? 0)
        }

        let eligibleHostNames = Set(orderedURLs.compactMap(\.host))
        var fallbackSlots: [String: Int] = [:]
        let anyAllocated = orderedURLs.contains { url in
            let host = url.host ?? ""
            let edge = edgeKey(host)
            let raw = allocation.slots[edge, default: 0]
            let cap = min(effectiveEdgeBound, (isTier1Host(host) || isIdentified(host)) ? raw : min(1, raw))
            return cap > 0
        }
        if !anyAllocated, let first = orderedURLs.first {
            fallbackSlots[edgeKey(first.host ?? "")] = 1
        }

        for url in orderedURLs {
            guard hasQueuedWork, activeFlightCount < effectiveLevel else { break }
            let host = url.host ?? ""
            guard !host.isEmpty else { continue }
            let edge = edgeKey(host)
            let rawSlots = fallbackSlots[edge] ?? allocation.slots[edge, default: 0]
            let trusted = isTier1Host(host) || isIdentified(host)
            var edgeCap = min(effectiveEdgeBound, trusted ? rawSlots : min(1, rawSlots))
            if edgeCap == 0, hasDeferredNeedingHost(host, among: orderedURLs, effectiveEdgeBound: effectiveEdgeBound) {
                edgeCap = 1
            }
            guard edgeCap > 0 else { continue }

            while hasQueuedWork, activeFlightCount < effectiveLevel,
                  inFlightByEdge[edge, default: 0] < edgeCap {
                guard let work = takeNextPiece(
                    for: host,
                    eligibleHosts: eligibleHostNames,
                    effectiveLevel: effectiveLevel
                ) else { break }

                let ordinal = inFlightByEdge[edge, default: 0]
                var loads = laneLoads[edge] ?? Array(repeating: 0, count: laneCount)
                let lane = (0..<laneCount).min { loads[$0] < loads[$1] } ?? (ordinal % laneCount)
                launchFlight(
                    pieceRange: work.range,
                    requestRange: work.range,
                    url: url,
                    host: host,
                    lane: lane,
                    priority: URLSessionTask.defaultPriority,
                    failedHosts: work.failedHosts,
                    retries: work.retries,
                    isHedge: false
                )
                if edge == allocation.recoveryKey {
                    controller.noteRecoveryIssued(edge, now: now)
                }
                inFlightByEdge[edge] = ordinal + 1
                loads[lane] += 1
                laneLoads[edge] = loads
            }
        }

        return admittedCapacity
    }

    private func hasDeferredNeedingHost(
        _ host: String,
        among orderedURLs: [URL],
        effectiveEdgeBound: Int
    ) -> Bool {
        deferredPieces.contains { piece in
            guard !piece.failedHosts.contains(host) else { return false }
            let alreadyServable = orderedURLs.contains { url in
                let candidate = url.host ?? ""
                guard !piece.failedHosts.contains(candidate) else { return false }
                let edge = edgeKey(candidate)
                let raw = allocation.slots[edge, default: 0]
                let cap = min(effectiveEdgeBound, (isTier1Host(candidate) || isIdentified(candidate)) ? raw : min(1, raw))
                return cap > 0
            }
            return !alreadyServable
        }
    }

    private func takeNextPiece(
        for host: String,
        eligibleHosts: Set<String>,
        effectiveLevel: Int
    ) -> (range: Range<Int64>, failedHosts: Set<String>, retries: Int)? {
        if let index = deferredPieces.firstIndex(where: { !$0.failedHosts.contains(host) }) {
            let item = deferredPieces.remove(at: index)
            return (item.range, item.failedHosts, item.retries)
        }
        if let index = deferredPieces.firstIndex(where: { piece in
            eligibleHosts.isSubset(of: piece.failedHosts) && piece.retries < Self.maxPieceRetries
        }) {
            let item = deferredPieces.remove(at: index)
            return (item.range, item.failedHosts, item.retries)
        }
        guard !pendingSpans.isEmpty else { return nil }
        let pieceSize = slicePieceSize(for: host, effectiveLevel: effectiveLevel)
        let span = pendingSpans[0]
        let available = span.upperBound - span.lowerBound
        if available <= pieceSize {
            pendingSpans.removeFirst()
            return (span, [], 0)
        }
        let end = span.lowerBound + pieceSize
        pendingSpans[0] = end..<span.upperBound
        return (span.lowerBound..<end, [], 0)
    }

    private func slicePieceSize(for host: String, effectiveLevel: Int) -> Int64 {
        let planned = Int64(MultiConnectionPlanner.pieceBytes(speed: hosts[host]?.speed))
        var pieceSize = min(
            SegmentedFileDownloader.maximumPieceBytes,
            max(SegmentedFileDownloader.minimumPieceBytes, planned)
        )
        let remaining = totalPendingBytes
        let parallelism = Int64(max(1, effectiveLevel))
        if remaining > 0, remaining < pieceSize * parallelism {
            let tailShare = max(
                SegmentedFileDownloader.minimumPieceBytes,
                (remaining + parallelism - 1) / parallelism
            )
            pieceSize = min(pieceSize, tailShare)
        }
        return pieceSize
    }

    private func buildEdges(
        from eligibleURLs: [URL],
        effectiveEdgeBound: Int,
        now: TimeInterval
    ) -> ([MultiConnectionConcurrencyController.Edge], Int) {
        var order: [String] = []
        var rates: [String: Double] = [:]
        var samples: [String: Int] = [:]
        var observations: [String: [String: Int]] = [:]
        var uncappedEdges: Set<String> = []
        var seenHosts: Set<String> = []

        for url in eligibleURLs {
            let host = url.host ?? ""
            guard !host.isEmpty, seenHosts.insert(host).inserted else { continue }
            let edge = edgeKey(host)
            if samples[edge] == nil {
                order.append(edge)
                samples[edge] = 0
            }
            if isTier1Host(host) || isIdentified(host) {
                uncappedEdges.insert(edge)
            }
            if let state = hosts[host] {
                samples[edge, default: 0] += state.pieces
                observations[edge, default: [:]][host] = state.pieces
                if let speed = state.speed {
                    rates[edge] = max(rates[edge] ?? 0, speed)
                }
            }
        }

        let bound = max(1, effectiveEdgeBound)
        let edges = order.map { edge in
            MultiConnectionConcurrencyController.Edge(
                key: edge,
                rate: rates[edge],
                samples: samples[edge] ?? 0,
                observations: observations[edge] ?? [:],
                maxSlots: uncappedEdges.contains(edge) ? nil : 1
            )
        }
        let activeEdges = edges.filter { !controller.isPruned($0.key, now: now) }
        let capacity: Int
        if !activeEdges.isEmpty {
            capacity = activeEdges.reduce(0) { $0 + min(bound, $1.maxSlots ?? bound) }
        } else if let best = edges.max(by: { ($0.rate ?? 0) < ($1.rate ?? 0) }) {
            capacity = min(bound, best.maxSlots ?? bound)
        } else {
            capacity = 0
        }
        return (edges, capacity)
    }

    private func explorationEdge(eligibleURLs: [URL]) -> String? {
        guard policy.explores,
              hosts.values.contains(where: { $0.speed != nil }),
              totalPiecesCompleted > 0,
              totalPiecesCompleted % 6 == 0 else { return nil }
        if let untriedTier1 = eligibleURLs.first(where: { url in
            let host = url.host ?? ""
            return hosts[host] == nil && isTier1Host(host)
        }) {
            return edgeKey(untriedTier1.host ?? "")
        }
        if let untried = eligibleURLs.first(where: { hosts[$0.host ?? ""] == nil }) {
            return edgeKey(untried.host ?? "")
        }
        return nil
    }

    @discardableResult
    private func observeLadder(
        now: TimeInterval,
        effectiveLevel: Int,
        admittedCapacity: Int
    ) -> [MultiConnectionConcurrencyController.Decision] {
        let observation = MultiConnectionConcurrencyController.Observation(
            saturated: activeFlightCount >= effectiveLevel && hasQueuedWork,
            backlog: hasQueuedWork,
            behind: false,
            capacity: admittedCapacity
        )
        let decisions = controller.observe(observation, now: now)
        if !decisions.isEmpty {
            storeMemo()
            for decision in decisions {
                switch decision {
                case let .stepUp(from, target, _, base):
                    PlayerLog.log(
                        "[Download] \(label) ladder up \(from)→\(target) " +
                            "base=\(String(format: "%.1f", base / 1_000_000))MB/s op=\(operationLabel)"
                    )
                case let .stepBack(from, target, _, _, _, restFor):
                    PlayerLog.log(
                        "[Download] \(label) ladder stepBack \(from)→\(target) " +
                            "rest=\(Int(restFor))s op=\(operationLabel)"
                    )
                case let .hardRest(from, target, ceiling, restFor):
                    PlayerLog.log(
                        "[Download] \(label) ladder hardRest \(from)→\(target) " +
                            "ceiling=\(ceiling) rest=\(Int(restFor))s op=\(operationLabel)"
                    )
                case .keep, .inconclusive:
                    break
                }
            }
        }
        return decisions
    }

    private func storeMemo() {
        guard !memoFrozen else { return }
        if !memo.store(controller.memo, for: policy.networkClass, generation: memoGeneration) {
            memoFrozen = true
        }
    }

    // MARK: - Flight Execution

    private func launchFlight(
        pieceRange: Range<Int64>,
        requestRange: Range<Int64>,
        url: URL,
        host: String,
        lane: Int,
        priority: Float,
        failedHosts: Set<String>,
        retries: Int,
        isHedge: Bool
    ) {
        let pieceKey = pieceRange.lowerBound
        let flightID = UUID()
        let startedAt = clock()
        let resourceLength = totalLength
        let networkPolicy = network
        let task = Task { [transport, headers, quietGate] in
            do {
                var request = URLRequest(url: url)
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                let rangeHeader = MediaByteRange.httpRangeHeader(
                    offset: requestRange.lowerBound,
                    length: requestRange.upperBound - requestRange.lowerBound
                ) ?? "bytes=\(requestRange.lowerBound)-\(requestRange.upperBound - 1)"
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
                networkPolicy.apply(to: &request)
                request.cachePolicy = .reloadIgnoringLocalCacheData

                let response = try await transport.fetch(
                    MultiConnectionFetchRequest(
                        request: request,
                        range: requestRange,
                        resourceLength: resourceLength
                    ),
                    quietGate: quietGate,
                    options: MultiConnectionFetchOptions(lane: lane, priority: priority)
                ) { prefix in
                    try await self.receivePrefix(
                        pieceKey: pieceKey,
                        flightID: flightID,
                        prefix: prefix
                    )
                }
                try Task.checkCancellation()
                try MultiConnectionValidation.headers(
                    status: response.status,
                    contentRange: response.contentRange,
                    contentLength: response.contentLength,
                    range: requestRange,
                    resourceLength: resourceLength,
                    bodyCount: response.bodyCount
                )
                self.finishFlightSuccess(
                    pieceKey: pieceKey,
                    flightID: flightID,
                    response: response,
                    startedAt: startedAt
                )
            } catch {
                self.finishFlightFailure(
                    pieceKey: pieceKey,
                    flightID: flightID,
                    host: host,
                    error: error
                )
            }
        }

        let flight = Flight(
            id: flightID,
            host: host,
            lane: lane,
            startedAt: startedAt,
            lastProgressAt: startedAt,
            requestRange: requestRange,
            task: task
        )

        if isHedge {
            activePieces[pieceKey]?.hedge = flight
            hedgesIssued += 1
        } else {
            activePieces[pieceKey] = ActivePiece(
                range: pieceRange,
                receivedThrough: pieceRange.lowerBound,
                primary: flight,
                hedge: nil,
                failedHosts: failedHosts,
                retries: retries
            )
        }
    }

    private func receivePrefix(
        pieceKey: Int64,
        flightID: UUID,
        prefix: MultiConnectionPrefix
    ) async throws {
        try Task.checkCancellation()
        guard !finished, var piece = activePieces[pieceKey] else {
            throw CancellationError()
        }

        let isPrimary = piece.primary.id == flightID
        let matchedFlight: Flight
        if isPrimary {
            matchedFlight = piece.primary
        } else if let hedge = piece.hedge, hedge.id == flightID {
            matchedFlight = hedge
        } else {
            throw CancellationError()
        }
        let isHedge = !isPrimary

        var flight = matchedFlight
        let expectedOffset = flight.requestRange.lowerBound + flight.bytesReceived
        guard !prefix.data.isEmpty,
              prefix.offset == expectedOffset,
              prefix.offset >= piece.range.lowerBound,
              prefix.offset < piece.range.upperBound,
              Int64(prefix.data.count) <= piece.range.upperBound - prefix.offset else {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }

        let now = clock()
        flight.lastProgressAt = now
        flight.bytesReceived += Int64(prefix.data.count)
        if isPrimary {
            piece.primary = flight
        } else {
            piece.hedge = flight
        }

        let prefixEnd = prefix.offset + Int64(prefix.data.count)
        guard prefixEnd > piece.receivedThrough else {
            activePieces[pieceKey] = piece
            return
        }

        let overlap = Int(max(0, piece.receivedThrough - prefix.offset))
        let writeOffset = prefix.offset + Int64(overlap)
        let writeData = overlap > 0 ? Data(prefix.data.dropFirst(overlap)) : prefix.data

        if isHedge {
            let displaced = piece.primary
            displaced.task.cancel()
            penalizeStalledHost(displaced.host, now: now)
            piece.primary = flight
            piece.hedge = nil
        }

        let completedBytes: Int64
        do {
            completedBytes = try sink.write(at: writeOffset, data: writeData)
        } catch {
            activePieces[pieceKey] = piece
            if !finished {
                finish(with: .failure(error))
            }
            throw error
        }

        piece.receivedThrough = writeOffset + Int64(writeData.count)
        activePieces[pieceKey] = piece

        bytesSinceCheckpoint += Int64(writeData.count)
        if bytesSinceCheckpoint >= Self.checkpointByteThreshold
            || now - lastCheckpointAt >= Self.checkpointInterval {
            bytesSinceCheckpoint = 0
            lastCheckpointAt = now
            onCheckpoint(sink.completedRangesSnapshot(), totalLength)
        }

        let monotonicBytes = max(lastReportedBytes, completedBytes)
        if monotonicBytes > lastReportedBytes,
           monotonicBytes >= totalLength || now - lastProgressReportAt >= Self.progressReportInterval {
            lastReportedBytes = monotonicBytes
            lastProgressReportAt = now
            onProgress(monotonicBytes, totalLength)
        }
    }

    private func finishFlightSuccess(
        pieceKey: Int64,
        flightID: UUID,
        response: MultiConnectionResponse,
        startedAt: TimeInterval
    ) {
        guard !finished, var piece = activePieces[pieceKey] else { return }
        let isPrimary = piece.primary.id == flightID
        let host: String
        if isPrimary {
            host = piece.primary.host
        } else if let hedge = piece.hedge, hedge.id == flightID {
            host = hedge.host
        } else {
            return
        }
        let isHedge = !isPrimary
        let now = clock()
        let elapsed = max(0.001, now - startedAt)
        let speed = Double(response.bodyCount) / elapsed

        var state = hosts[host] ?? HostState()
        state.speed = MultiConnectionPlanner.updatedSpeed(previous: state.speed, sample: speed)
        state.failures = 0
        state.pieces += 1
        state.bytes += Int64(response.bodyCount)
        state.connection = response.connection ?? state.connection
        hosts[host] = state

        if policy.auto {
            controller.noteCompletion(bytes: Int64(response.bodyCount), seconds: elapsed, now: now)
        }

        if isHedge {
            piece.hedge = nil
            activePieces[pieceKey] = piece
            schedule()
            return
        }

        guard piece.receivedThrough == piece.range.upperBound else {
            finishFlightFailure(
                pieceKey: pieceKey,
                flightID: flightID,
                host: host,
                error: PathAHTTPMediaSource.SourceError.invalidRange
            )
            return
        }

        totalPiecesCompleted += 1
        piece.hedge?.task.cancel()
        activePieces[pieceKey] = nil
        schedule()
    }

    private func finishFlightFailure(
        pieceKey: Int64,
        flightID: UUID,
        host: String,
        error: Error
    ) {
        guard !finished, var piece = activePieces[pieceKey] else { return }
        let isPrimary = piece.primary.id == flightID
        let isHedge = piece.hedge?.id == flightID
        guard isPrimary || isHedge else { return }

        if let fatal = fatalTransferError(from: error) {
            finish(with: .failure(fatal))
            return
        }

        let isQuiet: Bool
        if case MultiConnectionTransportError.quiet = error { isQuiet = true } else { isQuiet = false }
        let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled

        if isHedge {
            piece.hedge = nil
            activePieces[pieceKey] = piece
            if !isCancelled && !isQuiet {
                recordHostFailure(host: host, error: error)
            }
            schedule()
            return
        }

        if !isCancelled && !isQuiet {
            recordHostFailure(host: host, error: error)
            lastError = mapRetryableError(error, host: host)
        }

        if let hedge = piece.hedge, hedge.requestRange.lowerBound <= piece.receivedThrough {
            piece.primary = hedge
            piece.hedge = nil
            activePieces[pieceKey] = piece
            schedule()
            return
        }

        piece.hedge?.task.cancel()
        activePieces[pieceKey] = nil

        let remaining = piece.receivedThrough..<piece.range.upperBound
        if !remaining.isEmpty {
            var failedHosts = piece.failedHosts
            if !isQuiet && !isCancelled {
                failedHosts.insert(host)
            }
            let nextRetries = (isQuiet || isCancelled) ? piece.retries : piece.retries + 1
            if nextRetries > Self.maxPieceRetries {
                if !urlRefreshAttempted && !urlRefreshing && refreshURLs != nil {
                    enqueueDeferred(DeferredPiece(range: remaining, failedHosts: [], retries: 0))
                    triggerURLRefresh(reason: "max_retries")
                    return
                }
                finish(with: .failure(lastError ?? mapRetryableError(error, host: host)))
                return
            }
            enqueueDeferred(DeferredPiece(range: remaining, failedHosts: failedHosts, retries: nextRetries))
        }

        schedule()
    }

    private func enqueueDeferred(_ piece: DeferredPiece) {
        let index = deferredPieces.firstIndex { $0.range.lowerBound > piece.range.lowerBound }
            ?? deferredPieces.endIndex
        deferredPieces.insert(piece, at: index)
    }

    private func recordHostFailure(host: String, error: Error) {
        let now = clock()
        var state = hosts[host] ?? HostState()
        if case MultiConnectionTransportError.refused(let status) = error {
            refusals += 1
            let isEstablished = isTier1Host(host) || state.pieces > 0
            if isEstablished {
                state.failures += 2
                state.demotedUntil = max(state.demotedUntil, now + 60)
                hosts[host] = state
                if policy.auto, let decision = controller.noteRefusal(now: now) {
                    storeMemo()
                    PlayerLog.log(
                        "[Download] \(label) refusal host=\(host) status=\(status) " +
                            "decision=\(decision) op=\(operationLabel)"
                    )
                }
            } else {
                // Unproven synthesized mirror rejected the request — sideline it without global hardRest.
                state.failures += 4
                state.demotedUntil = max(state.demotedUntil, now + 3600)
                hosts[host] = state
                PlayerLog.log(
                    "[Download] \(label) mirror rejected host=\(host) status=\(status) — sidelined op=\(operationLabel)"
                )
            }
            return
        }

        state.failures += 1
        if state.failures >= 2 {
            state.demotedUntil = max(state.demotedUntil, now + 60)
        }
        hosts[host] = state
        if policy.auto, MultiConnectionTransportError.isConnectionReset(error),
           let decision = controller.noteTransportReset(edge: edgeKey(host), now: now) {
            refusals += 1
            storeMemo()
            PlayerLog.log(
                "[Download] \(label) reset storm host=\(host) decision=\(decision) op=\(operationLabel)"
            )
        }
    }

    private func penalizeStalledHost(_ host: String, now: TimeInterval) {
        let currentDate = Date()
        let hasAlternative = candidateURLs.contains { url in
            let other = url.host ?? ""
            return !other.isEmpty && other != host
                && MultiConnectionPlanner.isFresh(url, now: currentDate)
                && (hosts[other]?.demotedUntil ?? 0) <= now
        }
        guard hasAlternative else { return }
        var state = hosts[host] ?? HostState()
        state.demotedUntil = max(state.demotedUntil, now + 15)
        hosts[host] = state
    }

    // MARK: - Tail & Stall Hedging

    private func armStallWatchIfNeeded() {
        guard !finished, !activePieces.isEmpty, stallWatchTask == nil else { return }
        stallWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.stallWatchInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let keepGoing = await self?.evaluateStalledFlights() ?? false
                if !keepGoing { return }
            }
        }
    }

    private func cancelStallWatch() {
        stallWatchTask?.cancel()
        stallWatchTask = nil
    }

    private func evaluateStalledFlights() -> Bool {
        guard !finished, !activePieces.isEmpty else {
            stallWatchTask = nil
            return false
        }
        let now = clock()
        let currentDate = Date()
        let isTail = !hasQueuedWork
        let freshEligible = candidateURLs.filter { url in
            let host = url.host ?? ""
            return !host.isEmpty
                && MultiConnectionPlanner.isFresh(url, now: currentDate)
                && (hosts[host]?.demotedUntil ?? 0) <= now
        }
        guard !freshEligible.isEmpty else { return true }

        let activeHosts = Set(activePieces.values.flatMap { piece in
            [piece.primary.host] + (piece.hedge.map { [$0.host] } ?? [])
        })

        let sortedKeys = activePieces.keys.sorted()
        for pieceKey in sortedKeys {
            guard let piece = activePieces[pieceKey],
                  piece.hedge == nil,
                  piece.receivedThrough < piece.range.upperBound else { continue }
            guard isFlightStalled(piece: piece, isTail: isTail, eligibleURLs: freshEligible, now: now),
                  let hedgeURL = pickHedgeURL(
                      piece: piece,
                      eligibleURLs: freshEligible,
                      activeHosts: activeHosts,
                      now: now
                  ),
                  let hedgeHost = hedgeURL.host, !hedgeHost.isEmpty else { continue }

            let hedgeRange = piece.receivedThrough..<piece.range.upperBound
            launchFlight(
                pieceRange: piece.range,
                requestRange: hedgeRange,
                url: hedgeURL,
                host: hedgeHost,
                lane: 0,
                priority: URLSessionTask.highPriority,
                failedHosts: piece.failedHosts,
                retries: piece.retries,
                isHedge: true
            )
        }
        return !activePieces.isEmpty && !finished
    }

    private func isFlightStalled(
        piece: ActivePiece,
        isTail: Bool,
        eligibleURLs: [URL],
        now: TimeInterval
    ) -> Bool {
        let flight = piece.primary
        let elapsed = now - flight.startedAt
        let idle = now - flight.lastProgressAt
        if flight.bytesReceived == 0 {
            return idle >= Self.zeroByteStallDelay
        }
        if idle >= Self.midPieceStallDelay {
            return true
        }
        guard isTail, elapsed >= Self.tailSlowDelay else { return false }
        let currentRate = Double(flight.bytesReceived) / max(0.01, elapsed)
        let bestOtherRate = eligibleURLs
            .filter { ($0.host ?? "") != flight.host }
            .compactMap { hosts[$0.host ?? ""]?.speed }
            .max() ?? 0
        let floor = max(Self.tailSlowFloorBytesPerSec, bestOtherRate * 0.20)
        let remaining = Double(max(0, piece.range.upperBound - piece.receivedThrough))
        return currentRate < floor && (remaining / max(currentRate, 1)) > 2.0
    }

    private func pickHedgeURL(
        piece: ActivePiece,
        eligibleURLs: [URL],
        activeHosts: Set<String>,
        now: TimeInterval
    ) -> URL? {
        let candidates = eligibleURLs.filter { url in
            let host = url.host ?? ""
            return !host.isEmpty && host != piece.primary.host && !piece.failedHosts.contains(host)
        }
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted {
            (hosts[$0.host ?? ""]?.speed ?? 0) > (hosts[$1.host ?? ""]?.speed ?? 0)
        }
        if let idleUnpruned = sorted.first(where: { url in
            let host = url.host ?? ""
            return !activeHosts.contains(host) && !controller.isPruned(edgeKey(host), now: now)
        }) {
            return idleUnpruned
        }
        if let unpruned = sorted.first(where: { !controller.isPruned(edgeKey($0.host ?? ""), now: now) }) {
            return unpruned
        }
        return sorted.first
    }

    // MARK: - Signed URL Refresh & Cooldown

    private func triggerURLRefresh(reason: String) {
        guard !finished, !urlRefreshAttempted, !urlRefreshing, let refreshURLs else { return }
        urlRefreshAttempted = true
        urlRefreshing = true
        PlayerLog.log("[Download] \(label) refreshing signed URLs reason=\(reason) op=\(operationLabel)")
        urlRefreshTask = Task { [weak self] in
            do {
                let refreshed = try await refreshURLs()
                await self?.applyRefreshedURLs(refreshed)
            } catch {
                await self?.handleURLRefreshFailure(error)
            }
        }
    }

    private func applyRefreshedURLs(_ refreshed: SegmentedRefreshedCandidates) {
        urlRefreshing = false
        urlRefreshTask = nil
        guard !finished else { return }
        guard !refreshed.urls.isEmpty else {
            if activePieces.isEmpty {
                finish(with: .failure(lastError ?? DownloadTransferError.incompleteTransfer))
            }
            return
        }
        candidateURLs = refreshed.urls
        if let primary = refreshed.urls.first {
            tier1Hosts = MultiConnectionPlanner.tier1Hosts(
                for: refreshed.urls,
                primary: primary,
                verifiedAPIHosts: refreshed.verifiedAPIHosts
            )
        }
        for key in hosts.keys {
            hosts[key]?.demotedUntil = 0
            hosts[key]?.failures = 0
        }
        for index in deferredPieces.indices {
            deferredPieces[index].failedHosts = []
            deferredPieces[index].retries = 0
        }
        PlayerLog.log(
            "[Download] \(label) refreshed \(refreshed.urls.count) signed URL(s) " +
                "(preserving \(sink.completedBytesSnapshot())B on disk) op=\(operationLabel)"
        )
        schedule()
    }

    private func handleURLRefreshFailure(_ error: Error) {
        urlRefreshing = false
        urlRefreshTask = nil
        guard !finished else { return }
        if activePieces.isEmpty {
            finish(with: .failure(error))
        }
    }

    private func scheduleCooldownWake(freshURLs: [URL], now: TimeInterval) {
        guard cooldownWakeTask == nil else { return }
        guard cooldownWaits < Self.maxCooldownWaits else {
            finish(with: .failure(lastError ?? DownloadTransferError.incompleteTransfer))
            return
        }
        let earliest = freshURLs
            .compactMap { hosts[$0.host ?? ""]?.demotedUntil }
            .filter { $0 > now }
            .min() ?? (now + 5)
        let delay = max(0.5, min(15.0, earliest - now))
        cooldownWaits += 1
        PlayerLog.log(
            "[Download] \(label) all hosts cooling down — retrying in \(String(format: "%.1f", delay))s " +
                "(\(cooldownWaits)/\(Self.maxCooldownWaits)) op=\(operationLabel)"
        )
        cooldownWakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleCooldownWake()
        }
    }

    private func cancelCooldownWake() {
        cooldownWakeTask?.cancel()
        cooldownWakeTask = nil
    }

    private func handleCooldownWake() {
        cooldownWakeTask = nil
        guard !finished else { return }
        let now = clock()
        for key in hosts.keys where (hosts[key]?.demotedUntil ?? 0) <= now + 60 {
            hosts[key]?.demotedUntil = 0
        }
        schedule()
    }

    // MARK: - Error Mapping & Terminal Cleanup

    private func fatalTransferError(from error: Error) -> DownloadTransferError? {
        if case MultiConnectionTransportError.policyUnavailable(let reason) = error {
            switch reason {
            case "cellular": return .cellularNotAllowed
            case "constrained": return .lowDataModeNotAllowed
            case "expensive": return .expensiveNetworkNotAllowed
            default: return .expensiveNetworkNotAllowed
            }
        }
        if let transfer = error as? DownloadTransferError {
            switch transfer {
            case .outOfSpace, .partialFileUnwritable,
                 .cellularNotAllowed, .lowDataModeNotAllowed, .expensiveNetworkNotAllowed:
                return transfer
            default:
                return nil
            }
        }
        if let classified = DownloadTransferError.classify(error) {
            switch classified {
            case .outOfSpace, .cellularNotAllowed, .lowDataModeNotAllowed, .expensiveNetworkNotAllowed:
                return classified
            default:
                return nil
            }
        }
        return nil
    }

    private func mapRetryableError(_ error: Error, host: String) -> Error {
        if case MultiConnectionTransportError.refused(let status) = error {
            return DownloadTransferError.httpStatus(host: host, code: status)
        }
        if error is PathAHTTPMediaSource.SourceError {
            return DownloadTransferError.rangeNotHonoured(host: host)
        }
        return DownloadTransferError.classify(error) ?? error
    }

    private func finish(with result: Result<FileDownloader.StageResult, Error>) {
        guard !finished else { return }
        finished = true
        terminalResult = result

        cancelStallWatch()
        cancelCooldownWake()
        urlRefreshTask?.cancel()
        urlRefreshTask = nil

        for piece in activePieces.values {
            piece.primary.task.cancel()
            piece.hedge?.task.cancel()
        }
        activePieces.removeAll()

        let closed = sink.close()
        if !closed.ranges.isEmpty {
            onCheckpoint(closed.ranges, totalLength)
        }
        if case .success = result {
            lastReportedBytes = totalLength
            onProgress(totalLength, totalLength)
            PlayerLog.log(
                "[Download] \(label) segmented complete bytes=\(totalLength) " +
                    "pieces=\(totalPiecesCompleted) hedges=\(hedgesIssued) refusals=\(refusals) " +
                    "finalLevel=\(controller.level) op=\(operationLabel)"
            )
        }

        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume(with: result)
    }
}
