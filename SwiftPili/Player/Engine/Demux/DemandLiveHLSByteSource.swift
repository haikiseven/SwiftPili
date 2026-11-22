import Foundation

final class DemandLiveHLSByteSource: DemandLiveByteSource, @unchecked Sendable {
    private enum PlaylistCursor {
        case initial(primary: URL, backup: URL?)
        case selected(URL)
    }

    private static let maxSegmentBytes = 16 * 1024 * 1024
    private let transport: DemandLiveHTTPTransport
    private var playlist: PlaylistCursor
    private let source: DemandLiveSource?
    private let ownerGeneration: UInt64
    private var window = PathAHLSSegmentWindow()
    private var nextRefresh = DispatchTime.now()
    private var segment = Data()
    private var offset = 0
    private var terminalFailure: MediaEngineError?

    init(request: MediaOpenRequest) {
        self.playlist = .initial(primary: request.videoURL, backup: request.liveSource?.hlsTSBackupPlaylistURL)
        self.source = request.liveSource
        self.ownerGeneration = request.ownerGeneration
        self.transport = DemandLiveHTTPTransport(request: request)
    }

    func cancel() { transport.cancel() }

    func read(maximumBytes: Int, deadline: DispatchTime) throws -> Data? {
        try transport.checkCancellation()
        guard maximumBytes > 0 else { throw MediaEngineError.demuxFailed("HLS invalid read size") }
        if let terminalFailure { throw terminalFailure }
        do {
            try checkDeadline(deadline)
            if segment.isEmpty, try !loadNextSegment(deadline: deadline) {
                try checkDeadline(deadline)
                return nil
            }
            let count = min(maximumBytes, segment.count - offset)
            let result = segment.subdata(in: offset..<(offset + count))
            offset += count
            if offset == segment.count {
                segment = Data()
                offset = 0
            }
            try checkDeadline(deadline)
            return result
        } catch let error as MediaEngineError {
            terminalFailure = error
            try transport.checkCancellation()
            throw error
        }
    }

    private func loadNextSegment(deadline: DispatchTime) throws -> Bool {
        while true {
            try checkDeadline(deadline)
            if let next = try nextSegment() {
                let resource = try transport.load(next.url, maximumBytes: Self.maxSegmentBytes, deadline: deadline)
                try checkDeadline(deadline)
                guard !resource.data.isEmpty else {
                    throw DemandLiveHTTPTransport.failure(.badServerResponse)
                }
                guard window.commitOrderedFirst(next) else {
                    throw MediaEngineError.demuxFailed("HLS segment cursor changed during load")
                }
                segment = resource.data
                return true
            }
            guard !window.orderedEndListSeen else { return false }
            try transport.wait(until: min(nextRefresh, deadline))
            try refresh(deadline: deadline)
        }
    }

    private func nextSegment() throws -> PathAHLSMediaPlaylist.Segment? {
        do {
            return try window.firstOrderedPending()
        } catch let boundary as PathAHLSSegmentWindow.OrderedBoundary {
            PlayerLog.log("[PathA:HLS/TS] reload required reason=\(boundary.rawValue)")
            throw MediaEngineError.demuxFailed(MediaEngineError.liveMapChangedReloadRequiredDiagnostic)
        }
    }

    private func refresh(deadline: DispatchTime) throws {
        switch playlist {
        case .initial(let primary, let backup):
            let probe = DemandLiveHLSInitialPlaylist(transport: transport, parse: parsePlaylist)
            let snapshot = try probe.select(primary: primary, backup: backup, deadline: deadline)
            try checkDeadline(deadline)
            playlist = .selected(snapshot.requestURL)
            window = snapshot.window
            nextRefresh = snapshot.refreshAt
            let host = snapshot.responseURL.host(percentEncoded: true) ?? "?"
            let endpoint = snapshot.requestURL == primary ? "primary" : "backup"
            PlayerLog.log("[PathA:HLS/TS] initial playlist endpoint=\(endpoint) host=\(host.prefix(253))")
        case .selected(let url):
            let resource = try transport.load(
                url, maximumBytes: PathAHLSMediaPlaylist.maxPlaylistBytes, deadline: deadline
            )
            let snapshot = try parsePlaylist(resource, deadline: deadline)
            window.applyOrdered(snapshot)
            nextRefresh = Self.refreshTime(targetDuration: snapshot.targetDuration)
        }
    }

    fileprivate static func refreshTime(targetDuration: TimeInterval) -> DispatchTime {
        let interval = max(0.25, min(targetDuration * 0.5, 2))
        return DispatchTime.now() + .milliseconds(Int(interval * 1_000))
    }

    private func checkDeadline(_ deadline: DispatchTime) throws {
        try transport.checkCancellation()
        guard DispatchTime.now() < deadline else { throw DemandLiveHTTPTransport.failure(.timedOut) }
    }

    private func parsePlaylist(
        _ resource: DemandLiveHTTPTransfer.Resource, deadline: DispatchTime
    ) throws -> PathAHLSMediaPlaylist {
        try checkDeadline(deadline)
        let parsed = Result { try decodePlaylist(resource) }
        try checkDeadline(deadline)
        return try parsed.get()
    }

    private func decodePlaylist(_ resource: DemandLiveHTTPTransfer.Resource) throws -> PathAHLSMediaPlaylist {
        guard let text = String(data: resource.data, encoding: .utf8) else {
            throw MediaEngineError.demuxFailed("HLS playlist: invalid UTF-8")
        }
        do {
            return try PathAHLSMediaPlaylist.parse(text, relativeTo: resource.url, format: .mpegTS)
        } catch let failure as PathAHLSMediaPlaylist.Failure {
            switch failure {
            case .unsupported:
                guard let source else { throw MediaEngineError.notImplemented(failure.diagnostic) }
                throw MediaEngineError.unsupportedLiveSource(
                    source, ownerGeneration: ownerGeneration, diagnostic: failure.diagnostic
                )
            case .invalid:
                throw MediaEngineError.demuxFailed(failure.diagnostic)
            }
        }
    }
}

private struct DemandLiveHLSInitialPlaylist {
    private static let hedgeDelay = DispatchTimeInterval.milliseconds(850)

    struct Snapshot {
        let requestURL: URL
        let responseURL: URL
        let window: PathAHLSSegmentWindow
        let refreshAt: DispatchTime

        var hasUsableSegment: Bool { (try? window.firstOrderedPending()) != nil }
        var isEmpty: Bool { window.firstPending() == nil }
    }

    private enum Endpoint: Sendable { case primary, backup }

    private struct Attempt {
        let url: URL
        let transfer: DemandLiveHTTPTransport.Transfer
    }

    private enum Primary {
        case pending(Attempt)
        case completed(Result<Snapshot, any Error>)
    }

    private final class Completions: @unchecked Sendable {
        private let gate = DemandLiveReadLock()
        private var queue: [Endpoint] = []

        func submit(_ endpoint: Endpoint) {
            gate.lock.withLock {
                queue.append(endpoint)
                gate.wake()
            }
        }

        func next(until wakeAt: DispatchTime, deadline: DispatchTime) -> Endpoint? {
            gate.lock.withLock {
                let waitUntil = min(wakeAt, deadline)
                while queue.isEmpty, DispatchTime.now() < waitUntil { gate.wait(until: waitUntil) }
                guard DispatchTime.now() < deadline, !queue.isEmpty else { return nil }
                return queue.removeFirst()
            }
        }
    }

    let transport: DemandLiveHTTPTransport
    let parse: (DemandLiveHTTPTransfer.Resource, DispatchTime) throws -> PathAHLSMediaPlaylist

    func select(primary: URL, backup: URL?, deadline: DispatchTime) throws -> Snapshot {
        try checkDeadline(deadline)
        guard let backup else {
            let resource = try transport.load(
                primary, maximumBytes: PathAHLSMediaPlaylist.maxPlaylistBytes, deadline: deadline
            )
            return try snapshot(from: resource, requested: primary, deadline: deadline)
        }
        let completions = Completions()
        let hedgeAt = DispatchTime.now() + Self.hedgeDelay
        let start = Result { try begin(primary, as: .primary, completions: completions) }
        defer { if let attempt = try? start.get() { transport.discard(attempt.transfer) } }

        let primary = collectPrimary(start, completions: completions, hedgeAt: hedgeAt, deadline: deadline)
        if case .completed(.success(let snapshot)) = primary, snapshot.hasUsableSegment {
            return snapshot
        }

        return try race(primary: primary, backup: backup, completions: completions, deadline: deadline)
    }

    private func collectPrimary(
        _ start: Result<Attempt, any Error>, completions: Completions, hedgeAt: DispatchTime, deadline: DispatchTime
    ) -> Primary {
        switch start {
        case .failure(let error):
            return .completed(.failure(error))
        case .success(let attempt):
            guard completions.next(until: hedgeAt, deadline: deadline) != nil else { return .pending(attempt) }
            return .completed(Result { try read(attempt, deadline: deadline) })
        }
    }

    private func race(
        primary: Primary, backup: URL, completions: Completions, deadline: DispatchTime
    ) throws -> Snapshot {
        try transport.checkCancellation()
        guard DispatchTime.now() < deadline,
              let alternate = try? begin(backup, as: .backup, completions: completions) else {
            return try resolve(primary, deadline: deadline)
        }
        defer { transport.discard(alternate.transfer) }

        switch primary {
        case .completed(let result):
            return try preferBackup(alternate, over: result, deadline: deadline)
        case .pending(let attempt):
            switch completions.next(until: deadline, deadline: deadline) {
            case .primary:
                let result = Result { try read(attempt, deadline: deadline) }
                return try preferBackup(alternate, over: result, deadline: deadline)
            case .backup:
                if let winner = usableBackup(alternate, deadline: deadline) { return winner }
                return try read(attempt, deadline: deadline)
            case nil:
                return try read(attempt, deadline: deadline)
            }
        }
    }

    private func preferBackup(
        _ attempt: Attempt, over primary: Result<Snapshot, any Error>, deadline: DispatchTime
    ) throws -> Snapshot {
        var cutoff = deadline
        if let snapshot = try? primary.get() {
            if snapshot.hasUsableSegment { return snapshot }
            if snapshot.isEmpty { cutoff = min(snapshot.refreshAt, cutoff) }
        }
        if let winner = usableBackup(attempt, deadline: cutoff) { return winner }
        try transport.checkCancellation()
        return try primary.get()
    }

    private func usableBackup(_ attempt: Attempt, deadline: DispatchTime) -> Snapshot? {
        guard let snapshot = try? read(attempt, deadline: deadline), snapshot.hasUsableSegment else { return nil }
        return snapshot
    }

    private func begin(_ url: URL, as endpoint: Endpoint, completions: Completions) throws -> Attempt {
        let transfer = try transport.startInitialPlaylist(url, isHedge: endpoint == .backup) {
            completions.submit(endpoint)
        }
        return Attempt(url: url, transfer: transfer)
    }

    private func resolve(_ primary: Primary, deadline: DispatchTime) throws -> Snapshot {
        try transport.checkCancellation()
        switch primary {
        case .pending(let attempt): return try read(attempt, deadline: deadline)
        case .completed(let result): return try result.get()
        }
    }

    private func read(_ attempt: Attempt, deadline: DispatchTime) throws -> Snapshot {
        let resource = try transport.complete(attempt.transfer, deadline: deadline)
        return try snapshot(from: resource, requested: attempt.url, deadline: deadline)
    }

    private func checkDeadline(_ deadline: DispatchTime) throws {
        try transport.checkCancellation()
        guard DispatchTime.now() < deadline else { throw DemandLiveHTTPTransport.failure(.timedOut) }
    }

    private func snapshot(
        from resource: DemandLiveHTTPTransfer.Resource, requested: URL, deadline: DispatchTime
    ) throws -> Snapshot {
        let playlist = try parse(resource, deadline)
        var window = PathAHLSSegmentWindow()
        window.applyOrdered(playlist)
        try checkDeadline(deadline)
        return Snapshot(
            requestURL: requested, responseURL: resource.url, window: window,
            refreshAt: DemandLiveHLSByteSource.refreshTime(targetDuration: playlist.targetDuration)
        )
    }
}
