import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here; no-op on Apple platforms
#endif

/// Path A D1 — byte-range media byte source.
///
/// The demand-paced demuxer (α in-house fMP4) reads the file head (`ftyp`/`moov`/
/// `sidx`) and then ranges into `moof`/`mdat` to lift samples. This is that byte
/// layer, and nothing more: it does **not** parse boxes, own a timeline, or
/// invent `mediaTime` (F1 / C4). It fetches exact byte ranges over HTTP(S) — or
/// reads a local `file://` fixture — with the signed URL preserved byte-for-byte
/// (C5), Referer/UA injected, a per-request timeout, and cumulative `bytesRead`
/// for stats/health.
///
/// Cancellation is **structured**: cancelling the enclosing `Task` (e.g. on a
/// session generation bump) cancels the in-flight load — `URLSession`'s async
/// `data(for:)` is cancellation-aware. No manual task juggling.
///
/// Engine-boundary rules: `Player/Engine/Demux/` may not import SmartCDN or the
/// ViewModel (C3). This type imports Foundation only.
actor PathAHTTPMediaSource {

    /// What a resource response established about the byte source.
    struct ResourceInfo: Sendable, Equatable {
        /// Total byte length, if the server (or file) reports it.
        let contentLength: Int64?
        let contentType: String?
    }

    /// The initial parser window and the metadata learned by fetching it.
    struct InitialHead: Sendable, Equatable {
        enum ResponseKind: Sendable, Equatable {
            case file
            case httpPartial
            /// HTTP 200 supplied the window without honoring Range. This is
            /// response provenance, not proof that its entire body arrived.
            case httpRangeIgnored
        }

        let data: Data
        let info: ResourceInfo
        /// `httpPartial` proves this request was honored with HTTP 206. An
        /// `Accept-Ranges` advertisement alone is not enough to parallelize
        /// later requests safely.
        let responseKind: ResponseKind
    }

    enum SourceError: Error, LocalizedError, Equatable {
        case notHTTP
        case httpStatus(Int)
        case fileUnreadable(String)
        case invalidRange

        var errorDescription: String? {
            switch self {
            case .notHTTP: return "response was not HTTP"
            case .httpStatus(let c): return "unexpected HTTP status \(c)"
            case .fileUnreadable(let s): return "file unreadable: \(s)"
            case .invalidRange: return "invalid byte range"
            }
        }
    }

    private typealias ByteWindow = PathAHTTPRangeValidator.ByteWindow
    private enum ChunkResponseKind: Sendable {
        case pending
        case partial(expectedLength: Int64?, limit: Int64)
        case complete(limit: Int64)
    }

    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let isFile: Bool

    /// Complete primary 206 spans only. Delegate times exclude actor/store
    /// backpressure; a cancelled high-water span never becomes an estimate.
    struct RetrievalEstimate: Sendable {
        let observedAt: ContinuousClock.Instant
        let latency: Double
        let bytesPerSecond: Double
    }

    /// Non-blocking hint allowing a slow primary stream span to leave a
    /// strictly disjoint tail (`>= 2 MiB`) for multi-connection helpers.
    struct TailAssistHint: Sendable {
        let trackByteRate: Double
        let isAvailable: @Sendable () -> Bool
        let notifyTailAvailable: @Sendable () -> Void
    }

    private static let minimumTailSplitBytes: Int64 = 2 * 1024 * 1024

    private var retrievalEstimate: RetrievalEstimate?
    private var primaryThroughputEWMA: Double?
    private var tailAssistHint: TailAssistHint?

    func setTailAssistHint(_ hint: TailAssistHint?) {
        tailAssistHint = hint
    }

    func recentRetrievalEstimate(maximumAge: Duration) -> RetrievalEstimate? {
        guard !isFile, maximumAge > .zero, let retrievalEstimate,
              retrievalEstimate.observedAt.duration(to: .now) >= .zero,
              retrievalEstimate.observedAt.duration(to: .now) <= maximumAge else { return nil }
        return retrievalEstimate
    }

    private(set) var bytesRead: Int64 = 0
    /// Response-body receive accounting, independent of validated `bytesRead`.
    /// Delegates capture this open's counter; store/primed/file reads add zero.
    private let networkBytes: MediaNetworkByteCounter?
    private let bootstrapIdentity: MediaBootstrapIdentity?
    private(set) var info: ResourceInfo?

    /// The bytes `initialHead` already downloaded, retained so the first
    /// fragment does not pay a second round trip for bytes that are in memory.
    ///
    /// Cold-start shape before this existed, per track: one 256 KiB GET for the
    /// head (of which the `moov` is a few tens of KiB), the head thrown away,
    /// then a 16 KiB probe GET at `mediaStart` — **inside the range just
    /// discarded** — and then a chunk-stream GET for the mdat tail, whose first
    /// bytes are also inside it. Two extra serialized round trips and a
    /// re-download, in front of the first decodable sample, on every cold open.
    ///
    /// Lifecycle is what keeps this from being a cache: it holds AT MOST the one
    /// window that was already fetched, and it is released by the first request
    /// that starts outside it (`releaseHeadIfPassed`). Forward playback releases
    /// it after the first fragment; a resume open, whose first request is a far
    /// fragment, releases it before it is ever read. Network sources only — the
    /// demuxer keeps `file://` on the buffered path, where a local read was
    /// never the bottleneck.
    private var primedHead: Data?
    private var displayTrack: MediaDisplayTrack?
    private var displayPrimed: MediaDisplayLease?

    func setDisplayTrack(_ track: MediaDisplayTrack?) {
        displayTrack = track
        displayPrimed = primedHead.flatMap { track?.own(bytes: 0..<Int64($0.count)) }
    }

    /// The process-wide byte store this source reads through and admits
    /// into (`PathAByteStoreBinding`), or nil to bypass it: file sources,
    /// the `PATHA_BYTE_CACHE=0` kill switch, and every caller that does not
    /// opt in. The progressive VOD demuxer is the only production opt-in.
    private let byteStore: MediaByteRangeStore?
    /// Bound by `initialHead` once the response proved the content length;
    /// nil until then, and forever when there is no store or no key.
    private var storeBinding: PathAByteStoreBinding?
    private let sourceClaims = PathAByteSourceClaims()

    /// - Parameters:
    ///   - url: signed CDN URL (or `file://`). Used verbatim — never rebuilt via
    ///     URLComponents, so the signed query survives byte-for-byte (C5).
    ///   - headers: request headers (at least Referer + UA, per `biliHeaders`).
    ///   - timeout: per-request ceiling in seconds.
    ///   - session: injectable for tests; a default ephemeral session otherwise.
    ///   - byteStore: the byte store to read through; nil (the default)
    ///     reads exactly as before the store existed. Ignored for `file://`.
    ///   - networkBytes: the stream's wire-byte counter; nil counts nothing.
    init(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval = 15,
        session: URLSession? = nil,
        byteStore: MediaByteRangeStore? = nil,
        networkBytes: MediaNetworkByteCounter? = nil,
        bootstrapIdentity: MediaBootstrapIdentity? = nil
    ) {
        self.url = url
        self.networkBytes = url.isFileURL ? nil : networkBytes
        self.bootstrapIdentity = url.isFileURL ? nil : bootstrapIdentity
        self.headers = headers
        self.isFile = url.isFileURL
        self.byteStore = url.isFileURL ? nil : byteStore
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = timeout
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Initial head

    /// Fetch the first `count` bytes and resource metadata in one operation.
    ///
    /// A 206 response derives the resource total only from `Content-Range`;
    /// its `Content-Length` describes the returned range, not the resource.
    /// A 200 response means Range was ignored. Retain only the requested parser
    /// window; a response without a declared length stays unknown unless EOF
    /// actually arrives before that window is complete.
    func initialHead(count: Int) async throws -> InitialHead {
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: 0, count: count) else {
            throw SourceError.invalidRange
        }

        if isFile {
            let size = try fileSize()
            let resourceInfo = ResourceInfo(
                contentLength: size,
                contentType: nil
            )
            let data = try readFile(offset: 0, count: count)
            info = resourceInfo
            return InitialHead(
                data: data,
                info: resourceInfo,
                responseKind: .file
            )
        }

        let headTicket = chunkOpenTicket
        if let retained = try await retainedInitialHead(count: count, ticket: headTicket) { return retained }
        try checkClaimFence(headTicket)
        var request = makeRequest()
        guard let rangeHeader = MediaByteRange.httpRangeHeader(
            offset: window.offset,
            length: window.count64
        ) else { throw SourceError.invalidRange }
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        // Timed because this is the first network cost of a cold start and the
        // stage above it (`demand-demux-open-done`) brackets head fetch + moov
        // parse + resume seek together. Without this the trace cannot say which
        // of the three a slow open spent its time in.
        let headStart = ContinuousClock.now
        let requestStart = Date()
        let (received, http) = try await load(request, window: window)
        let body = received.data
        let receivedAt = Date()
        try checkClaimFence(headTicket)
        let headMs = Int(headStart.duration(to: ContinuousClock.now) / .milliseconds(1))
        let total: Int64?
        switch http.statusCode {
        case 206:
            let range = try PathAHTTPRangeValidator.validatePartialResponse(
                http.value(forHTTPHeaderField: "Content-Range"),
                requested: window,
                bodyCount: body.count
            )
            try PathAHTTPRangeValidator.validateContentLength(
                http.value(forHTTPHeaderField: "Content-Length"),
                bodyCount: body.count,
                expectedRangeLength: range?.length
            )
            total = range?.total
        case 200:
            // A retained prefix is not a complete body. The transport has
            // checked received bytes against any declared length; only header
            // provenance or actual whole-body completion establishes a total.
            total = received.resourceLength
        default:
            throw StreamTransportFailure.http(http, stage: .mediaRead)
        }

        guard let receivedCount = Int(exactly: received.receivedBodyBytes),
              accountBytesRead(receivedCount) else { throw SourceError.invalidRange }
        let resourceInfo = ResourceInfo(
            contentLength: total,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
        info = resourceInfo

        let data = Data(body.prefix(window.count))
        // Retain exactly the window that was returned — see `primedHead`. Only
        // a partial (206) response is a byte-accurate prefix of the resource; a
        // 200 that ignored Range also starts at byte 0, so both are usable, and
        // `data` is already clamped to `count` in either case.
        primedHead = data.isEmpty ? nil : Data(data)
        PlayerLog.log(
            "[PathA] http initial-head host=\(url.host ?? "?") " +
            "len=\(total.map(String.init) ?? "?") " +
            "status=\(http.statusCode) primed=\(data.count)B in=\(headMs)ms"
        )
        // An ordinary miss establishes new HTTP provenance with this real GET.
        if let binding = PathAByteStoreBinding(store: byteStore, url: url, contentLength: total) {
            storeBinding = binding
            await binding.bindOpened(head: data)
        }
        let initial = InitialHead(
            data: data,
            info: resourceInfo,
            responseKind: http.statusCode == 206 ? .httpPartial : .httpRangeIgnored
        )
        try await registerBootstrapHead(MediaHTTPBootstrapRegistration(
            url: url, headers: headers, response: http,
            requestStart: requestStart, receivedAt: receivedAt, head: initial
        ), ticket: headTicket)
        return initial
    }

    // MARK: - Read

    private func registerBootstrapHead(
        _ registration: MediaHTTPBootstrapRegistration, ticket: UInt64
    ) async throws {
        try checkClaimFence(ticket)
        await byteStore?.retainBootstrap(identity: bootstrapIdentity, registration: registration)
        try checkClaimFence(ticket)
    }

    private func retainedInitialHead(count: Int, ticket: UInt64) async throws -> InitialHead? {
        guard let byteStore, let retained = await byteStore.retainedBootstrap(
            identity: bootstrapIdentity, url: url, headers: headers, count: count
        ) else { return nil }
        try checkClaimFence(ticket)
        let binding = PathAByteStoreBinding(
            store: byteStore, url: url, contentLength: retained.info.contentLength
        )
        // An owned coherent prefix retains the ordinary head lifetime even if
        // the store later evicts it. Parsing and additional reads stay ordinary.
        await binding?.bindOpened(head: retained.data)
        try checkClaimFence(ticket)
        info = retained.info
        primedHead = retained.data
        storeBinding = binding
        return retained
    }

    /// Read `[offset, offset+count)`. Returns up to `count` bytes; a short read
    /// (including empty) means end-of-resource — the natural EOF signal for the
    /// demuxer. `count` must be > 0.
    func read(
        offset: Int64, count: Int, waitBudget: MediaSourceWaitBudget? = nil,
        displayOwner: MediaDisplayByteOwner? = nil
    ) async throws -> Data {
        try checkWaitBudget(waitBudget)
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: offset, count: count) else {
            throw SourceError.invalidRange
        }
        if isFile {
            return try readFile(offset: offset, count: count)
        }

        // Already in hand? Only a FULLY contained range is served: a partial
        // hit would return fewer bytes than asked, and a short read is this
        // layer's EOF signal to the demuxer. Half an answer would be read as
        // end-of-resource.
        if let slice = primedHeadSlice(offset: offset, count: count) {
            displayOwner?.hold(offset..<(offset + Int64(slice.count)))
            PlayerLog.log(
                "[PathA] http read served from primed head " +
                "off=\(offset) count=\(count) (no request)"
            )
            return slice
        }
        releaseHeadIfPassed(offset: offset)
        if let binding = storeBinding {
            return try await readStoredWindow(
                window, binding: binding, waitBudget: waitBudget, displayOwner: displayOwner
            )
        }
        return try await readNetworkWindow(window, claim: nil, waitBudget: waitBudget).data
    }

    /// Exact logical read assembled from held runs and only actual holes.
    /// A partial hit is never EOF; one demand owns one bounded wait deadline.
    private func readStoredWindow(
        _ window: ByteWindow, binding: PathAByteStoreBinding, waitBudget: MediaSourceWaitBudget?,
        displayOwner: MediaDisplayByteOwner?
    ) async throws -> Data {
        let ticket = chunkOpenTicket
        let end = min(window.endExclusive, binding.key.contentLength)
        var cursor = window.offset
        var output = Data()
        var deadline: TimeInterval?
        while cursor < end {
            try checkClaimFence(ticket, waitBudget: waitBudget)
            let count = Int(end - cursor)
            if let held = await binding.store.prefix(
                binding.key, offset: cursor, count: count, displayOwner: displayOwner
            ) {
                try checkClaimFence(ticket, waitBudget: waitBudget)
                await binding.store.noteRead(binding.key, offset: cursor)
                try checkClaimFence(ticket, waitBudget: waitBudget)
                output.append(held)
                cursor += Int64(held.count)
                continue
            }
            try checkClaimFence(ticket, waitBudget: waitBudget)
            // A byte at the current cursor is enough to observe newly published
            // progress; waiting on the full hole would still hide its prefix.
            let now = ProcessInfo.processInfo.systemUptime
            deadline = deadline ?? (now + 1.5)
            let result = await binding.awaitClaims(
                offset: cursor, count: 1, timeout: max(0, (deadline ?? now) - now), waitBudget: waitBudget
            )
            try checkClaimFence(ticket, waitBudget: waitBudget)
            if result == .cancelled { throw CancellationError() }
            if result == .released {
                // Recheck cache, then the shared deadline on the next wait.
                // A release cannot renew this operation's wait authority.
                continue
            }
            let span = await binding.span(offset: cursor, end: end)
            try checkClaimFence(ticket, waitBudget: waitBudget)
            guard let hole = span else { break }
            let response = try await readStoredHole(hole, binding: binding, ticket: ticket, waitBudget: waitBudget)
            try checkClaimFence(ticket, waitBudget: waitBudget)
            guard let response else { continue }
            displayOwner?.hold(cursor..<(cursor + Int64(response.data.count)))
            output.append(response.data)
            cursor += Int64(response.data.count)
            if response.data.count < hole.count {
                guard response.reachedResourceEnd else { throw SourceError.invalidRange }
                return output
            }
        }
        try checkClaimFence(ticket, waitBudget: waitBudget)
        return output
    }

    private func readStoredHole(
        _ hole: Range<Int64>, binding: PathAByteStoreBinding, ticket: UInt64, waitBudget: MediaSourceWaitBudget?
    ) async throws -> NetworkWindowResult? {
        try checkClaimFence(ticket, waitBudget: waitBudget)
        let token = binding.claimForSource(offset: hole.lowerBound, count: hole.count)
        sourceClaims.insert(token, store: binding.store)
        defer { sourceClaims.release(token) }
        // Publication can win the registry lock after the hole snapshot.
        let covered = await binding.store.prefix(binding.key, offset: hole.lowerBound, count: 1) != nil
        try checkClaimFence(ticket, waitBudget: waitBudget)
        if covered { return nil }
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: hole.lowerBound, count: hole.count) else {
            throw SourceError.invalidRange
        }
        return try await readNetworkWindow(
            window, claim: ReadClaim(token: token, waitTicket: ticket), waitBudget: waitBudget
        )
    }

    private struct NetworkWindowResult {
        let data: Data
        let reachedResourceEnd: Bool
    }

    private func readNetworkWindow(
        _ window: ByteWindow, claim readClaim: ReadClaim?, waitBudget: MediaSourceWaitBudget?
    ) async throws -> NetworkWindowResult {
        try checkReadClaim(readClaim, waitBudget: waitBudget)
        var request = makeRequest()
        guard let rangeHeader = MediaByteRange.httpRangeHeader(
            offset: window.offset,
            length: window.count64
        ) else { throw SourceError.invalidRange }
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        try checkReadClaim(readClaim, waitBudget: waitBudget)
        let issue = waitBudget?.notePrimaryRequest(range: window.offset..<window.endExclusive)
        let (received, http) = try await load(request, window: window, claim: readClaim?.token)
        let data = received.data
        try checkReadClaim(readClaim, waitBudget: waitBudget)

        switch http.statusCode {
        case 206:
            let result = try await acceptPartialRead(data, http: http, window: window)
            try checkReadClaim(readClaim, waitBudget: waitBudget)
            if !result.data.isEmpty, let issue { waitBudget?.notePrimaryDelivery(issue) }
            return result
        case 200:
            let result = try await acceptCompleteRead(received, window: window)
            try checkReadClaim(readClaim, waitBudget: waitBudget)
            if !result.data.isEmpty, let issue { waitBudget?.notePrimaryDelivery(issue) }
            return result
        case 416:
            // Requested range beyond EOF → empty (EOF), not an error.
            return NetworkWindowResult(data: Data(), reachedResourceEnd: true)
        default:
            throw StreamTransportFailure.http(http, stage: .mediaRead)
        }
    }

    private func acceptPartialRead(
        _ data: Data, http: HTTPURLResponse, window: ByteWindow
    ) async throws -> NetworkWindowResult {
        let range = try PathAHTTPRangeValidator.validatePartialResponse(
            http.value(forHTTPHeaderField: "Content-Range"), requested: window, bodyCount: data.count
        )
        try PathAHTTPRangeValidator.validateContentLength(
            http.value(forHTTPHeaderField: "Content-Length"), bodyCount: data.count,
            expectedRangeLength: range?.length
        )
        guard accountBytesRead(data.count) else { throw SourceError.invalidRange }
        // Only validated range/total provenance admits these bytes.
        if let binding = storeBinding, let range, binding.admits(resourceLength: range.total) {
            await binding.admit(offset: window.offset, data: data)
        }
        return NetworkWindowResult(data: data, reachedResourceEnd: range.map { $0.total == $0.end + 1 } ?? false)
    }

    private func acceptCompleteRead(
        _ received: MediaNetworkResponse, window: ByteWindow
    ) async throws -> NetworkWindowResult {
        // The receiver already discarded the prefix and retained this window.
        // Do not compare its count to the complete object's Content-Length or
        // invent a total from bytes retained before an early cancellation.
        let data = received.data
        PlayerLog.log("[PathA] ⚠️ http 200 for ranged GET host=\(url.host ?? "?") — bounded window retained")
        guard let receivedCount = Int(exactly: received.receivedBodyBytes),
              accountBytesRead(receivedCount) else { throw SourceError.invalidRange }
        if let binding = storeBinding, binding.admits(resourceLength: received.resourceLength), !data.isEmpty {
            await binding.admit(offset: window.offset, data: data)
        }
        let reachedEnd = received.isCompleteBody
            || received.resourceLength.map { window.endExclusive >= $0 } == true
        return NetworkWindowResult(data: data, reachedResourceEnd: reachedEnd)
    }

    private func checkWaitBudget(_ waitBudget: MediaSourceWaitBudget?) throws {
        try Task.checkCancellation()
        if waitBudget?.isCancelled == true { throw CancellationError() }
    }

    private func checkClaimFence(_ ticket: UInt64, waitBudget: MediaSourceWaitBudget? = nil) throws {
        guard ticket == chunkOpenTicket else { throw CancellationError() }
        try checkWaitBudget(waitBudget)
    }

    private struct ReadClaim {
        let token: MediaByteRangeStore.ClaimToken?
        let waitTicket: UInt64?
    }

    private func checkReadClaim(_ claim: ReadClaim?, waitBudget: MediaSourceWaitBudget?) throws {
        // Ordinary reads retain their ordering when there was no speculative
        // wait. A new chunk opening alone is not authority to stop that read.
        if let ticket = claim?.waitTicket { try checkClaimFence(ticket, waitBudget: waitBudget) }
        try checkWaitBudget(waitBudget)
    }

    // MARK: - Chunk stream (streaming mdat)

    /// One live ranged GET delivered as chunks, consumed across pump calls.
    /// Single-slot by design: a reader streams at most one fragment tail at a
    /// time, and opening a new stream retires the previous one.
    private struct ChunkStreamSlot {
        let id: UInt64
        var network: NetworkSpan?
        var networkGeneration: UInt64 = 0
        /// Absolute offset of the first byte this stream delivers; together
        /// with `delivered` it names the next byte the consumer would get —
        /// the continuity certificate a resuming pump checks before trusting
        /// the slot (an id alone cannot prove no other pump consumed from it).
        let baseOffset: Int64
        /// Logical window admitted for this stream. Network responses may be
        /// shorter at the resource end, but no 206 data may cross this bound.
        let requestedCount: Int64
        var buffered: [StreamChunk] = []
        var bufferedBytes = 0
        /// The part of `bufferedBytes` that is the held prefix (primed head
        /// and store pieces) still queued ahead of the network chunks. Held
        /// bytes are not the response's backlog, so back-pressure leaves them
        /// out: a store prefix just under the high-water would otherwise end
        /// the network remainder after its first few KB. Zero without a store
        /// (kill switch), so the primed head counts exactly as before P1.
        var heldQueuedBytes = 0
        /// Bytes handed to the consumer (diagnostics only; the demuxer's
        /// assembler owns the authoritative resume offset).
        var delivered: Int64 = 0
        /// Clean completion (server finished the response, or the 200-slicing
        /// cap / 416 empty case ended it deliberately).
        var finished = false
        /// Terminal failure (HTTP status, transport error). Sticky until the
        /// slot is closed; the demuxer may close + reopen at its resume offset.
        var failure: Error?
        var waiter: CheckedContinuation<StreamChunk?, Error>?
        var waiterID: UUID?
        /// High-water reached: the response is ended (task cancelled) rather
        /// than suspended mid-body so buffered chunks drain and the pump
        /// reopens cleanly at the committed offset over warm keep-alive/h2.
        var tailEndedForBackpressure = false
        // Pacing diagnostics (burst-vs-starve): arrival cadence of this
        // stream, summarized in ONE line when it closes.
        let openedAt = ContinuousClock.now
        var chunkCount = 0
        var arrivedBytes: Int64 = 0
        var backpressureEndCount = 0
        var lastArrivalAt: ContinuousClock.Instant?
        var maxArrivalGapMs = 0
    }

    /// One physical ranged request within a logical stream. Every bridge hop
    /// carries its generation; completion cannot touch its successor's claim.
    private struct NetworkSpan {
        let generation: UInt64
        let task: URLSessionDataTask
        let offset: Int64
        let count: Int64
        let primaryDelivery: PrimaryDelivery?
        var claim: MediaByteRangeStore.ClaimToken?
        var storeAdmission: PathAByteStoreBinding?
        var responseKind: ChunkResponseKind = .pending
        var responseBytes: Int64 = 0
        var reachesResourceEnd = false
        var speedWindowStart: ContinuousClock.Instant?
        var lastBodyAt: ContinuousClock.Instant?
        var speedWindowBytes: Int64 = 0
        var recordedRetrievalEstimate = false
    }

    private struct PrimaryDelivery: Sendable {
        let budget: MediaSourceWaitBudget
        let issue: UUID

        func consumed(by current: MediaSourceWaitBudget?) {
            guard current?.id == budget.id else { return }
            budget.notePrimaryDelivery(issue)
        }
    }

    /// Provenance follows queued bytes after a physical span finishes. Held
    /// pieces have none; a later pump cannot borrow an earlier issue token.
    private struct StreamChunk: Sendable {
        let data: Data
        let primaryDelivery: PrimaryDelivery?
        var displayBytes: MediaDisplayLease? = nil
    }

    private var chunkSlot: ChunkStreamSlot?
    private var chunkSlotSeq: UInt64 = 0
    /// Latest-open-wins fence for `openChunkStream`'s store lookup, its only
    /// suspension point. Each open takes a ticket BEFORE awaiting and gives
    /// up after it when a newer open, or a seek/close fence
    /// (`closeActiveChunkStream`), took one meanwhile — so a slow open with a
    /// long held prefix can never resume after a newer one and retire it.
    /// Equality only; wrapping is harmless.
    private var chunkOpenTicket: UInt64 = 0

    /// Backpressure: past the high-water the response is ENDED (see
    /// `tailEndedForBackpressure`) — never suspended mid-body. The bound is
    /// SOFT: chunks whose delegate callbacks already ran still land — order
    /// highWater + a few chunks, not a hard cap.
    private static let chunkBufferHighWater = 4 * 1024 * 1024

    /// Open a live chunk stream over `[offset, offset+count)`. Returns a slot
    /// id immediately — response validation surfaces on `nextChunk` (same
    /// `SourceError` shapes as `read`): 206 streams, a 200 that ignored Range
    /// is sliced to the window, 416 ends as clean-empty (EOF), anything else
    /// fails the slot. Any previously open stream is retired first.
    /// Network resources only — the demuxer keeps `file://` on the buffered
    /// path, where local reads were never the bottleneck.
    func openChunkStream(
        offset: Int64, count: Int, waitBudget: MediaSourceWaitBudget? = nil
    ) async throws -> UInt64 {
        try checkWaitBudget(waitBudget)
        guard !isFile else { throw SourceError.fileUnreadable("chunk stream on file source") }
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: offset, count: count) else {
            throw SourceError.invalidRange
        }

        // The mdat tail of the FIRST fragment starts inside the window
        // `initialHead` already downloaded, and any window this resource
        // delivered before — on this source or an earlier one, whatever its
        // host or signature — may be in the byte store. Hand those bytes over
        // as the stream's first buffered chunks, primed head first, and
        // request only what is missing, so the first samples reach the decoder
        // without waiting for a new response. `baseOffset` stays the LOGICAL
        // offset, so `chunkStreamPosition` and the assembler's resume
        // arithmetic are unchanged — held bytes are delivered through the same
        // `buffered` queue as a network chunk.
        let displayBytes = displayTrack.map(MediaDisplayByteOwner.init)
        defer { displayBytes?.release() }
        let primed = primedHeadPrefix(offset: offset, count: count)
        if let primed { displayBytes?.hold(offset..<(offset + Int64(primed.count))) }
        let primedCount = primed?.count ?? 0
        // The store lookup is this open's only suspension point. It runs
        // BEFORE any slot state is read or written, and the ticket makes the
        // LATEST open win: one that a newer open or a fence overtook during
        // the await gives up instead of retiring the newer slot. The slot id,
        // the retire of the previous stream and the new slot are then decided
        // in one uninterrupted actor turn, as when this was synchronous. The
        // captured primed bytes stay valid even if a read released the head
        // meanwhile — they are the resource's bytes, not a claim on its
        // lifetime.
        chunkOpenTicket &+= 1
        let ticket = chunkOpenTicket
        var cached: [Data] = []
        if let binding = storeBinding {
            try checkClaimFence(ticket, waitBudget: waitBudget)
            cached = await binding.streamPrefix(
                offset: offset, count: count, after: primedCount, limit: Self.chunkBufferHighWater, displayOwner: displayBytes
            )
            try checkClaimFence(ticket, waitBudget: waitBudget)
        }
        try checkClaimFence(ticket, waitBudget: waitBudget)
        let cachedCount = cached.reduce(0) { $0 + $1.count }
        let prefixCount = primedCount + cachedCount
        let held = (primed.map { [$0] } ?? []) + cached

        let id = try claimChunkSlotID()
        logHeldPrefix(offset: offset, count: count, primed: primedCount, cached: cachedCount)
        // Any held prefix is useful immediately. The next demand scans the
        // cache and unfinished claim in this same logical slot. No-store keeps
        // the established primed-head plus network remainder behavior.
        if storeBinding != nil || prefixCount == count {
            installHeldOnlySlot(id: id, window: window, held: held, heldCount: prefixCount)
            if prefixCount == 0 { try await refillStoredStream(id, waitBudget: waitBudget) }
        } else {
            try startNetworkRemainder(
                id: id, window: window, held: held, heldCount: prefixCount, waitBudget: waitBudget
            )
        }
        try checkClaimFence(ticket, waitBudget: waitBudget)
        guard chunkSlot?.id == id else { throw CancellationError() }
        // The head has now been consumed by this stream (or was never usable
        // for it); either way the next request moves past it.
        if primedCount > 0 { releaseHead() } else { releaseHeadIfPassed(offset: offset) }
        return id
    }

    /// Next slot id, retiring the previous stream. Synchronous, so the retire
    /// and the install that follows share one actor turn.
    private func claimChunkSlotID() throws -> UInt64 {
        let nextID = chunkSlotSeq.addingReportingOverflow(1)
        guard !nextID.overflow, nextID.partialValue != 0 else {
            throw SourceError.invalidRange
        }
        retireChunkSlot(throwing: CancellationError())
        chunkSlotSeq = nextID.partialValue
        return nextID.partialValue
    }

    /// A slot with no request behind it: every byte is already in `held`, or
    /// (window larger than the high-water) the rest comes from the store.
    private func installHeldOnlySlot(id: UInt64, window: ByteWindow, held: [Data], heldCount: Int) {
        var slot = ChunkStreamSlot(id: id, baseOffset: window.offset, requestedCount: window.count64)
        slot.buffered = displayChunks(held, offset: window.offset)
        slot.bufferedBytes = heldCount
        slot.heldQueuedBytes = heldCount
        slot.finished = Int64(heldCount) == window.count64
        chunkSlot = slot
    }

    private func displayChunks(_ pieces: [Data], offset: Int64) -> [StreamChunk] {
        var cursor = offset
        return pieces.map { data in
            let end = cursor + Int64(data.count)
            defer { cursor = end }
            return StreamChunk(data: data, primaryDelivery: nil,
                               displayBytes: displayTrack?.own(bytes: cursor..<end))
        }
    }

    /// Legacy no-store prefix/remainder path uses the same physical span owner.
    private func startNetworkRemainder(
        id: UInt64, window: ByteWindow, held: [Data], heldCount: Int, waitBudget: MediaSourceWaitBudget?
    ) throws {
        var slot = ChunkStreamSlot(id: id, baseOffset: window.offset, requestedCount: window.count64)
        slot.buffered = displayChunks(held, offset: window.offset)
        slot.bufferedBytes = heldCount
        chunkSlot = slot
        try beginNetworkSpan(
            id, offset: window.offset + Int64(heldCount), count: window.count - heldCount,
            claim: nil, waitBudget: waitBudget
        )
    }

    private func beginNetworkSpan(
        _ id: UInt64, offset: Int64, count: Int, claim: MediaByteRangeStore.ClaimToken?,
        waitBudget: MediaSourceWaitBudget?
    ) throws {
        try checkWaitBudget(waitBudget)
        guard var slot = chunkSlot, slot.id == id, slot.network == nil, count > 0,
              let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(count)),
              let rangeHeader = MediaByteRange.httpRangeHeader(offset: offset, length: Int64(count)) else {
            throw SourceError.invalidRange
        }
        let next = slot.networkGeneration.addingReportingOverflow(1)
        guard !next.overflow else { throw SourceError.invalidRange }
        slot.networkGeneration = next.partialValue
        var request = makeRequest()
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        let issuedAt = ContinuousClock.now
        task.delegate = ChunkStreamBridge(
            source: self, id: id, generation: slot.networkGeneration, issuedAt: issuedAt,
            slicingOffset: offset, slicingCount: count,
            admissionLedger: storeBinding?.store.admissionLedger, networkBytes: networkBytes
        )
        try checkWaitBudget(waitBudget)
        let primary = waitBudget.map {
            PrimaryDelivery(budget: $0, issue: $0.notePrimaryRequest(range: offset..<end))
        }
        slot.network = NetworkSpan(generation: slot.networkGeneration, task: task,
                                   offset: offset, count: Int64(count), primaryDelivery: primary, claim: claim)
        chunkSlot = slot
        task.resume()
    }

    /// One line per stream open that was served, fully or partly, from memory.
    /// A primed-only open keeps its historical line byte for byte.
    private func logHeldPrefix(offset: Int64, count: Int, primed: Int, cached: Int) {
        guard primed > 0 || cached > 0 else { return }
        guard cached > 0 else {
            PlayerLog.log(
                "[PathA] mdat stream primed off=\(offset) prefix=\(primed)B " +
                "network=\(count - primed)B"
            )
            return
        }
        PlayerLog.log(
            "[PathA] mdat stream primed off=\(offset) prefix=\(primed)B " +
            "cache=\(cached)B rest=\(count - primed - cached)B"
        )
    }

    // MARK: - Primed head

    /// The requested range, but only when it lies ENTIRELY inside the retained
    /// head. A partial answer is never returned — see `read`.
    private func primedHeadSlice(offset: Int64, count: Int) -> Data? {
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: offset, count: count),
              let head = primedHead,
              let start = Int(exactly: window.offset),
              let end = Int(exactly: window.endExclusive),
              start >= 0,
              end <= head.count else { return nil }
        return head.subdata(in: start..<end)
    }

    /// The leading part of `[offset, offset+count)` the retained head can
    /// supply. Unlike `read`, a chunk stream is allowed a partial hit: the
    /// remainder is requested from the network and delivered after it, in
    /// order, so the consumer sees one continuous byte run.
    private func primedHeadPrefix(offset: Int64, count: Int) -> Data? {
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: offset, count: count),
              let head = primedHead,
              window.offset < Int64(head.count),
              let start = Int(exactly: window.offset) else { return nil }
        let available = head.count - start
        let prefixCount = min(available, window.count)
        guard prefixCount > 0 else { return nil }
        let end = start + prefixCount
        guard end > start else { return nil }
        return head.subdata(in: start..<end)
    }

    /// Forward progress past the retained window is the end of its usefulness.
    private func releaseHeadIfPassed(offset: Int64) {
        guard let head = primedHead, offset >= Int64(head.count) else { return }
        releaseHead()
    }

    private func releaseHead() {
        guard primedHead != nil else { return }
        primedHead = nil
        displayPrimed = nil
    }

    /// The absolute offset of the next byte `nextChunk` would deliver, or nil
    /// when `id` no longer names the live slot. Buffered-but-unconsumed chunks
    /// do not count — only bytes actually handed out do.
    func chunkStreamPosition(_ id: UInt64) -> Int64? {
        guard let slot = chunkSlot, slot.id == id else { return nil }
        guard slot.delivered >= 0,
              slot.delivered <= slot.requestedCount,
              let position = MediaByteRange.checkedEndExclusive(
                offset: slot.baseOffset,
                length: slot.delivered
              ) else { return nil }
        return position
    }

    /// The currently-owned stream identity, if a ranged response is live.
    /// This is intentionally observable only as an opaque id so a demuxer can
    /// issue an id-scoped interruption without ever closing a successor stream
    /// after actor reentrancy.
    func activeChunkStreamID() -> UInt64? {
        guard let slot = chunkSlot,
              slot.network != nil,
              !slot.finished,
              slot.failure == nil,
              !slot.tailEndedForBackpressure else {
            // A primed/fully buffered slot is still a useful logical stream,
            // but it no longer owns blocking I/O.  Do not report an
            // interruption acknowledgement for work that cannot be
            // interrupted.
            return nil
        }
        return slot.id
    }

    /// Interrupt exactly the current chunk stream and acknowledge whether the
    /// source actually owned one. `closeActiveChunkStream()` remains useful for
    /// ordinary park/teardown, but its no-op result cannot prove interruption
    /// to a caller enforcing a deadline.
    func interruptActiveIO() -> MediaDemuxIOInterruptResult {
        guard let id = activeChunkStreamID() else {
            return .noActiveOperation
        }
        return closeChunkStream(id) ? .interrupted : .noActiveOperation
    }

    /// Id-scoped retire: closes the stream only if `id` still names the live
    /// slot. A stale pump closing its OWN dead stream can never take down a
    /// successor's replacement this way.
    @discardableResult
    func closeChunkStream(_ id: UInt64) -> Bool {
        guard chunkSlot?.id == id else { return false }
        retireChunkSlot(throwing: CancellationError())
        return true
    }

    /// Admit a 206 response only after the delegate has validated its
    /// Content-Range. The hop is ordered before any data hop by
    /// `ChunkStreamBridge.hop`, so a body callback cannot reach the actor while
    /// this slot is still provenance-pending.
    fileprivate func chunkStreamAdmitPartial(
        _ id: UInt64, generation: UInt64,
        expectedLength: Int64?,
        responseLimit: Int64,
        resourceLength: Int64?
    ) {
        guard var slot = chunkSlot, slot.id == id, let network = slot.network, network.generation == generation,
              case .pending = network.responseKind else { return }
        guard responseLimit >= 0, responseLimit <= network.count else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            return
        }
        let limit = min(expectedLength ?? responseLimit, responseLimit)
        guard limit >= 0 else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            return
        }
        slot.network?.responseKind = .partial(expectedLength: expectedLength, limit: limit)
        slot.network?.reachesResourceEnd = resourceLength.map { network.offset + limit == $0 } ?? false
        slot.network?.storeAdmission = storeBinding.flatMap { $0.admits(resourceLength: resourceLength) ? $0 : nil }
        chunkSlot = slot
    }

    /// Admit a 200 response whose body will be sliced in the delegate. A 200
    /// body is intentionally not bounded to the requested range; only the
    /// sliced bytes become stream payload, preserving Range-ignore support.
    fileprivate func chunkStreamAdmitComplete(
        _ id: UInt64, generation: UInt64, responseLimit: Int64, resourceLength: Int64?
    ) {
        guard var slot = chunkSlot, slot.id == id, let network = slot.network, network.generation == generation,
              case .pending = network.responseKind else { return }
        guard responseLimit >= 0, responseLimit <= network.count else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            return
        }
        slot.network?.responseKind = .complete(limit: responseLimit)
        slot.network?.reachesResourceEnd = resourceLength.map { network.offset + responseLimit >= $0 } ?? false
        slot.network?.storeAdmission = storeBinding.flatMap { $0.admits(resourceLength: resourceLength) ? $0 : nil }
        chunkSlot = slot
    }

    private func failChunkSlot(_ slot: inout ChunkStreamSlot, error: Error) {
        slot.failure = error
        slot.finished = false
        slot.network?.task.cancel()
        sourceClaims.release(slot.network?.claim)
        slot.network?.claim = nil
        if let waiter = slot.waiter {
            slot.waiter = nil
            slot.waiterID = nil
            waiter.resume(throwing: error)
        }
    }

    /// Next chunk of the stream, in delivery order. `nil` means the stream
    /// ended cleanly (EOF — for a bounded range that is either completion or
    /// truncation; the caller's assembler knows which). Throws the slot's
    /// terminal failure, or `CancellationError` when the consuming task was
    /// cancelled or the slot was retired — the stream itself survives a
    /// cancelled consumer, so the next pump call resumes where it left off.
    func nextChunk(
        _ id: UInt64, waitBudget: MediaSourceWaitBudget? = nil,
        displayOwner: MediaDisplayByteOwner? = nil
    ) async throws -> Data? {
        while true {
            try checkWaitBudget(waitBudget)
            guard var slot = chunkSlot, slot.id == id else { throw CancellationError() }
            if !slot.buffered.isEmpty {
                return try consumeBufferedChunk(&slot, waitBudget: waitBudget, displayOwner: displayOwner)
            }
            if slot.tailEndedForBackpressure {
                // Returns only when a held slot was refilled from the store;
                // the loop re-reads the slot after this await.
                retireChunkSlot(throwing: CancellationError())
                throw CancellationError()
            }
            if let failure = slot.failure { throw failure }
            if slot.finished { return nil }
            if slot.network == nil, storeBinding != nil {
                try await refillStoredStream(id, waitBudget: waitBudget)
                continue
            }
            guard slot.waiter == nil else {
                // Single consumer by contract (the pump is serialized); a
                // second waiter is a stale caller.
                throw CancellationError()
            }
            try Task.checkCancellation()
            // Wait for the bridge to deliver. Consumer cancellation abandons
            // only the WAIT (the stream and its buffer live on) — that is what
            // lets a cancelled pump hand the intact stream to the next one.
            //
            // Ordering contract: there must be NO await between the handler
            // registration below and the continuation install inside it — the
            // install runs as one contiguous actor job, so an onCancel fired
            // mid-registration must acquire this actor and therefore runs
            // strictly AFTER the install, resuming the parked waiter. An await
            // introduced here would open a window where cancelChunkWaiter
            // no-ops before the install and the waiter parks until the next
            // network event or the request timeout.
            let resumed = try await waitForNetworkChunk(id, waitBudget: waitBudget)
            try checkWaitBudget(waitBudget)
            guard chunkSlot?.id == id else { throw CancellationError() }
            guard let resumed else { return nil }      // waiter woken by clean finish
            if resumed.data.isEmpty { continue }       // sentinel: re-read slot state
            if let slot = chunkSlot {
                let end = slot.baseOffset + slot.delivered
                displayOwner?.hold((end - Int64(resumed.data.count))..<end)
            }
            resumed.primaryDelivery?.consumed(by: waitBudget)
            return resumed.data
        }
    }

    private func consumeBufferedChunk(
        _ slot: inout ChunkStreamSlot, waitBudget: MediaSourceWaitBudget?,
        displayOwner: MediaDisplayByteOwner?
    ) throws -> Data {
        let delivery = slot.buffered[0]
        let chunk = delivery.data
        let deliveryResult = Int64(exactly: chunk.count).map { slot.delivered.addingReportingOverflow($0) }
        guard slot.bufferedBytes >= chunk.count,
              let deliveryResult, !deliveryResult.overflow,
              deliveryResult.partialValue <= slot.requestedCount,
              let deliveredStart = MediaByteRange.checkedEndExclusive(offset: slot.baseOffset, length: slot.delivered),
              let deliveredEnd = MediaByteRange.checkedEndExclusive(
                offset: slot.baseOffset, length: deliveryResult.partialValue
              ) else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            throw SourceError.invalidRange
        }
        displayOwner?.hold(deliveredStart..<deliveredEnd)
        slot.buffered.removeFirst()
        slot.bufferedBytes -= chunk.count
        // Held pieces remain whole queue entries before any network bytes.
        slot.heldQueuedBytes -= min(chunk.count, slot.heldQueuedBytes)
        slot.delivered = deliveryResult.partialValue
        chunkSlot = slot
        delivery.primaryDelivery?.consumed(by: waitBudget)
        return chunk
    }

    private func waitForNetworkChunk(
        _ id: UInt64, waitBudget: MediaSourceWaitBudget?
    ) async throws -> StreamChunk? {
        let waiterID = UUID()
        let observer = waitBudget?.observe { [weak self] change in
            if case .cancelled = change {
                Task { await self?.cancelChunkWaiter(id, waiterID: waiterID) }
            }
        }
        defer { if let observer { waitBudget?.removeObserver(observer) } }
        return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<StreamChunk?, Error>) in
                    if Task.isCancelled || waitBudget?.isCancelled == true {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if var current = chunkSlot, current.id == id, current.waiter == nil,
                       current.buffered.isEmpty, current.failure == nil, !current.finished {
                        current.waiter = cont
                        current.waiterID = waiterID
                        chunkSlot = current
                    } else {
                        // State moved while suspending — resolve on the next
                        // loop pass rather than parking a stale waiter. The
                        // empty Data is a loop-again sentinel, never returned
                        // (the bridge never delivers empty chunks).
                        cont.resume(returning: StreamChunk(data: Data(), primaryDelivery: nil))
                    }
                }
            } onCancel: {
                Task { await self.cancelChunkWaiter(id, waiterID: waiterID) }
            }
    }

    /// Retire the active stream: cancel its task, fail its waiter, drop its
    /// buffer. Seek, close, and open-replace fences call this; a stale
    /// `nextChunk` against the retired id resolves as cancellation.
    func closeActiveChunkStream() {
        // A fence also overtakes an open still inside its store lookup.
        chunkOpenTicket &+= 1
        retireChunkSlot(throwing: CancellationError())
        sourceClaims.releaseAll()
    }

    /// Continue the same logical stream through a held run or a bounded hole.
    /// Each drained demand has one absolute wait deadline, never reset by progress.
    private func refillStoredStream(_ id: UInt64, waitBudget: MediaSourceWaitBudget?) async throws {
        guard let original = chunkSlot, original.id == id, let binding = storeBinding,
              let position = MediaByteRange.checkedEndExclusive(offset: original.baseOffset, length: original.delivered)
        else { throw CancellationError() }
        let ticket = chunkOpenTicket
        let logicalEnd = original.baseOffset + original.requestedCount
        let end = min(logicalEnd, binding.key.contentLength)
        var deadline: TimeInterval?
        while true {
            try checkWaitBudget(waitBudget)
            guard var current = chunkSlot, current.id == id, current.delivered == original.delivered,
                  current.buffered.isEmpty, current.network == nil,
                  current.networkGeneration == original.networkGeneration else { throw CancellationError() }
            if position >= end {
                current.finished = true
                chunkSlot = current
                return
            }
            let displayBytes = displayTrack.map(MediaDisplayByteOwner.init)
            defer { displayBytes?.release() }
            let pieces = await binding.heldPieces(
                offset: position, count: min(Int(end - position), Self.chunkBufferHighWater), displayOwner: displayBytes
            )
            try checkStoredStreamFence(id, original: original, ticket: ticket, waitBudget: waitBudget)
            if !pieces.isEmpty {
                current = chunkSlot ?? current
                current.buffered = displayChunks(pieces, offset: position)
                current.bufferedBytes = pieces.reduce(0) { $0 + $1.count }
                current.heldQueuedBytes = current.bufferedBytes
                current.finished = position + Int64(current.bufferedBytes) >= end
                chunkSlot = current
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            deadline = deadline ?? (now + 1.5)
            let result = await binding.awaitClaims(
                offset: position, count: 1, timeout: max(0, (deadline ?? now) - now), waitBudget: waitBudget
            )
            try checkStoredStreamFence(id, original: original, ticket: ticket, waitBudget: waitBudget)
            if result == .cancelled { throw CancellationError() }
            if result == .released { continue }
            let span = await binding.span(offset: position, end: end)
            try checkStoredStreamFence(id, original: original, ticket: ticket, waitBudget: waitBudget)
            guard let hole = span else { throw SourceError.invalidRange }
            let requestCount = slowPrimarySplitCount(for: hole)
            var claim = binding.claimForSource(offset: position, count: requestCount)
            sourceClaims.insert(claim, store: binding.store)
            defer { sourceClaims.release(claim) }
            let covered = await binding.store.prefix(binding.key, offset: position, count: 1) != nil
            try checkStoredStreamFence(id, original: original, ticket: ticket, waitBudget: waitBudget)
            if covered { continue }
            try beginNetworkSpan(
                id, offset: position, count: requestCount, claim: claim, waitBudget: waitBudget
            )
            claim = nil // span owns release from here
            notifyTailSplitIfNeeded(requested: requestCount, holeCount: hole.count)
            return
        }
    }

    private func slowPrimarySplitCount(for hole: Range<Int64>) -> Int {
        let holeBytes = hole.upperBound - hole.lowerBound
        guard let hint = tailAssistHint,
              holeBytes >= Self.minimumTailSplitBytes * 2,
              hint.isAvailable(),
              let primarySpeed = primaryThroughputEWMA,
              primarySpeed.isFinite, primarySpeed > 0 else {
            return Int(holeBytes)
        }
        let slowThreshold = max(2.0 * 1024 * 1024, hint.trackByteRate * 1.5)
        guard primarySpeed < slowThreshold else { return Int(holeBytes) }
        return Int(min(holeBytes / 2, Self.minimumTailSplitBytes))
    }

    private func notifyTailSplitIfNeeded(requested: Int, holeCount: Int) {
        guard requested < holeCount else { return }
        tailAssistHint?.notifyTailAvailable()
    }

    private func updatePrimaryThroughputEWMA(_ sample: Double) {
        guard sample.isFinite, sample > 0 else { return }
        if let previous = primaryThroughputEWMA, previous.isFinite, previous > 0 {
            primaryThroughputEWMA = 0.7 * previous + 0.3 * sample
        } else {
            primaryThroughputEWMA = sample
        }
    }

    private func observePrimaryStreamBytes(
        _ byteCount: Int64, arrivedAt: ContinuousClock.Instant, slot: inout ChunkStreamSlot
    ) {
        guard !slot.tailEndedForBackpressure, var network = slot.network else { return }
        network.lastBodyAt = arrivedAt
        guard let start = network.speedWindowStart else {
            network.speedWindowStart = arrivedAt
            slot.network = network
            return
        }
        network.speedWindowBytes += byteCount
        let elapsed = Double(start.duration(to: arrivedAt) / .seconds(1))
        if elapsed >= 0.25, network.speedWindowBytes >= 64 * 1024 {
            updatePrimaryThroughputEWMA(Double(network.speedWindowBytes) / elapsed)
            network.speedWindowStart = arrivedAt
            network.speedWindowBytes = 0
        }
        slot.network = network
    }

    private func finishPrimaryStreamSpeedWindow(
        _ network: NetworkSpan, error: Error?, slot: ChunkStreamSlot
    ) {
        guard error == nil, slot.failure == nil,
              !slot.tailEndedForBackpressure, !network.recordedRetrievalEstimate,
              network.speedWindowBytes >= 64 * 1024,
              let start = network.speedWindowStart, let end = network.lastBodyAt else { return }
        let elapsed = Double(start.duration(to: end) / .seconds(1))
        guard elapsed >= 0.05 else { return }
        updatePrimaryThroughputEWMA(Double(network.speedWindowBytes) / elapsed)
    }

    private func checkStoredStreamFence(
        _ id: UInt64, original: ChunkStreamSlot, ticket: UInt64, waitBudget: MediaSourceWaitBudget?
    ) throws {
        try checkClaimFence(ticket, waitBudget: waitBudget)
        guard let current = chunkSlot, current.id == id, current.delivered == original.delivered,
              current.buffered.isEmpty, current.network == nil,
              current.networkGeneration == original.networkGeneration else { throw CancellationError() }
    }

    private func retireChunkSlot(throwing error: Error) {
        guard var slot = chunkSlot else { return }
        chunkSlot = nil
        logChunkStreamSummary(slot, outcome: "retired")
        slot.network?.task.cancel()
        sourceClaims.release(slot.network?.claim)
        slot.network?.claim = nil
        if let waiter = slot.waiter {
            slot.waiter = nil
            slot.waiterID = nil
            waiter.resume(throwing: error)
        }
    }

    /// One pacing line per stream lifetime: arrival cadence proves whether the
    /// network delivered smoothly (small maxGap) or in bursts, independent of
    /// what the consumer did with it.
    private func logChunkStreamSummary(_ slot: ChunkStreamSlot, outcome: String) {
        guard slot.chunkCount > 0 else { return }
        let ms = Int(slot.openedAt.duration(to: ContinuousClock.now) / .milliseconds(1))
        PlayerLog.log(
            "[PathA][pace] stream \(outcome) bytes=\(slot.arrivedBytes) " +
            "chunks=\(slot.chunkCount) in=\(ms)ms " +
            "maxGap=\(slot.maxArrivalGapMs)ms bpEnds=\(slot.backpressureEndCount)"
        )
    }

    private func cancelChunkWaiter(_ id: UInt64, waiterID: UUID) {
        guard var slot = chunkSlot, slot.id == id, slot.waiterID == waiterID,
              let waiter = slot.waiter else { return }
        slot.waiter = nil
        slot.waiterID = nil
        chunkSlot = slot
        waiter.resume(throwing: CancellationError())
    }

    // Bridge → actor deliveries. Chunk ORDER is preserved by the bridge's hop
    // chain (delegate callbacks are serial, but bare Task hops are not).

    /// Account every byte received from the network, including the prefix a
    /// 200 range-ignore response discards before slicing. This is kept
    /// separate from `chunkStreamDeliver`, whose payload is the logical
    /// requested window and may therefore be shorter than the response body.
    fileprivate func chunkStreamAccountReceived(_ id: UInt64, generation: UInt64, count: Int) {
        guard var slot = chunkSlot, slot.id == id, let network = slot.network, network.generation == generation,
              slot.failure == nil, !slot.finished else { return }
        let responseAdmitted: Bool
        switch network.responseKind {
        case .pending:
            responseAdmitted = false
        case .partial, .complete:
            responseAdmitted = true
        }
        guard responseAdmitted, accountBytesRead(count) else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            return
        }
        chunkSlot = slot
    }

    /// Deliver, then admit into the byte store. The store await is the LAST
    /// step, after every slot mutation, so it cannot interleave with this
    /// slot's state; the bridge's hop chain awaits it, which keeps admissions
    /// in arrival order and lands them all before the stream's finish hop.
    fileprivate func chunkStreamDeliverAndAdmit(
        _ id: UInt64, generation: UInt64, data: Data, arrivedAt: ContinuousClock.Instant
    ) async {
        guard let admission = chunkStreamDeliver(
            id, generation: generation, data: data, arrivedAt: arrivedAt
        ) else { return }
        await admission.binding.admit(offset: admission.offset, data: data)
    }

    /// Where a delivered chunk goes in the byte store.
    private struct ChunkStoreAdmission {
        let binding: PathAByteStoreBinding
        let offset: Int64
    }

    /// Returns the chunk's store admission only when it passed every bound
    /// check below and reached the consumer's queue — never for a chunk that
    /// failed the slot.
    private func chunkStreamDeliver(
        _ id: UInt64, generation: UInt64, data: Data, arrivedAt: ContinuousClock.Instant
    ) -> ChunkStoreAdmission? {
        guard var slot = chunkSlot, slot.id == id, let network = slot.network, network.generation == generation,
              slot.failure == nil, !slot.finished else { return nil }
        guard let dataCount = Int64(exactly: data.count) else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            return nil
        }
        let responseLimit: Int64?
        switch network.responseKind {
        case .pending:
            responseLimit = nil
        case .partial(_, let limit):
            responseLimit = limit
        case .complete(let limit):
            responseLimit = limit
        }
        let responseResult = network.responseBytes.addingReportingOverflow(dataCount)
        let deliveredResult = slot.delivered.addingReportingOverflow(dataCount)
        let chunkResult = slot.chunkCount.addingReportingOverflow(1)
        let bufferedResult = slot.bufferedBytes.addingReportingOverflow(data.count)
        let arrivedResult = slot.arrivedBytes.addingReportingOverflow(dataCount)
        guard !data.isEmpty,
              let responseLimit,
              !responseResult.overflow,
              responseResult.partialValue <= responseLimit,
              !deliveredResult.overflow,
              deliveredResult.partialValue <= slot.requestedCount,
              MediaByteRange.checkedEndExclusive(
                offset: slot.baseOffset,
                length: slot.delivered
              ) != nil,
              MediaByteRange.checkedEndExclusive(
                offset: slot.baseOffset,
                length: deliveredResult.partialValue
              ) != nil,
              !chunkResult.overflow,
              !bufferedResult.overflow,
              !arrivedResult.overflow else {
            failChunkSlot(&slot, error: SourceError.invalidRange)
            chunkSlot = slot
            return nil
        }
        let admission = network.storeAdmission.flatMap { binding in
            MediaByteRange.checkedEndExclusive(offset: network.offset, length: network.responseBytes)
                .map { ChunkStoreAdmission(binding: binding, offset: $0) }
        }
        slot.network?.responseBytes = responseResult.partialValue
        let now = ContinuousClock.now
        observePrimaryStreamBytes(dataCount, arrivedAt: arrivedAt, slot: &slot)
        if let last = slot.lastArrivalAt {
            let gap = Int(last.duration(to: now) / .milliseconds(1))
            if gap > slot.maxArrivalGapMs { slot.maxArrivalGapMs = gap }
            if gap >= 700 {
                PlayerLog.log("[PathA][pace] arrival-gap id=\(id) gap=\(gap)ms")
            }
        }
        slot.lastArrivalAt = now
        slot.chunkCount = chunkResult.partialValue
        slot.arrivedBytes = arrivedResult.partialValue
        if slot.chunkCount == 1 {
            // One line per stream open (≈ per fragment / per reopen): the
            // reopen → first-byte latency the freeze report correlates on.
            let ms = Int(slot.openedAt.duration(to: now) / .milliseconds(1))
            PlayerLog.log("[PathA][pace] first-byte id=\(id) +\(ms)ms bytes=\(data.count)")
        }
        if let waiter = slot.waiter {
            slot.waiter = nil
            slot.waiterID = nil
            slot.delivered = deliveredResult.partialValue
            chunkSlot = slot
            waiter.resume(returning: StreamChunk(
                data: data, primaryDelivery: network.primaryDelivery,
                displayBytes: displayTrack?.own(bytes: (network.offset + network.responseBytes)..<(network.offset + responseResult.partialValue))
            ))
            return admission
        }
        slot.buffered.append(StreamChunk(
                data: data, primaryDelivery: network.primaryDelivery,
                displayBytes: displayTrack?.own(bytes: (network.offset + network.responseBytes)..<(network.offset + responseResult.partialValue))
            ))
        slot.bufferedBytes = bufferedResult.partialValue
        // Only the network backlog ends the response (`heldQueuedBytes`).
        if !slot.tailEndedForBackpressure,
           slot.bufferedBytes - slot.heldQueuedBytes > Self.chunkBufferHighWater {
            slot.tailEndedForBackpressure = true
            slot.backpressureEndCount += 1
            slot.network?.task.cancel()
            // Event-time marker (the stream summary carries only the count):
            // lets the report line a high-water end up against the fill that
            // triggered it and the reopen that follows.
            PlayerLog.log(
                "[PathA][pace] high-water-end id=\(id) " +
                "buffered=\(slot.bufferedBytes)B chunks=\(slot.chunkCount)"
            )
        }
        chunkSlot = slot
        return admission
    }

    fileprivate func admitRetrievalEstimate(
        _ id: UInt64, generation: UInt64, sample: RetrievalEstimate, byteCount: Int64
    ) {
        guard var slot = chunkSlot, slot.id == id, let network = slot.network,
              network.generation == generation, !slot.tailEndedForBackpressure,
              slot.failure == nil, network.responseBytes == byteCount,
              byteCount > 0, case .partial(let expected, _) = network.responseKind,
              expected == byteCount, sample.latency.isFinite, sample.latency >= 0,
              sample.bytesPerSecond.isFinite, sample.bytesPerSecond > 0 else { return }
        slot.network?.recordedRetrievalEstimate = true
        chunkSlot = slot
        retrievalEstimate = sample
        updatePrimaryThroughputEWMA(sample.bytesPerSecond)
    }

    fileprivate func chunkStreamFinish(_ id: UInt64, generation: UInt64, error: Error?) {
        guard var slot = chunkSlot, slot.id == id,
              let network = slot.network, network.generation == generation else { return }
        sourceClaims.release(slot.network?.claim)
        slot.network?.claim = nil
        // A deliberate local cancel (416 / slicing cap reached / backpressure
        // tail-end) already marked its intent; the task's cancellation error
        // must not demote that to a failure. Likewise a real failure recorded
        // at response time (HTTP status) must not be clobbered by the
        // follow-up cancellation error — the demuxer's isCancellation mapping
        // would misread a 403 as a clean stop.
        if let error, !slot.finished, slot.failure == nil,
           !slot.tailEndedForBackpressure {
            slot.failure = error
        } else if error == nil, !slot.finished, slot.failure == nil,
                  !slot.tailEndedForBackpressure {
            switch network.responseKind {
            case .partial(let expectedLength, _):
                if let expectedLength, network.responseBytes != expectedLength {
                    slot.failure = SourceError.invalidRange
                } else {
                    slot.finished = storeBinding == nil
                        || network.reachesResourceEnd
                        || slot.delivered + Int64(slot.bufferedBytes) >= slot.requestedCount
                }
            case .pending:
                // A response callback must precede completion. Treat a
                // completion observed before admission as malformed rather
                // than allowing an unproven body to look like EOF.
                slot.failure = SourceError.invalidRange
            case .complete:
                slot.finished = storeBinding == nil
                    || network.reachesResourceEnd
                    || slot.delivered + Int64(slot.bufferedBytes) >= slot.requestedCount
            }
        }
        if error == nil, storeBinding != nil, network.responseBytes < network.count,
           !network.reachesResourceEnd, slot.failure == nil, !slot.tailEndedForBackpressure {
            slot.failure = SourceError.invalidRange
        }
        finishPrimaryStreamSpeedWindow(network, error: error, slot: slot)
        slot.network = nil
        if let waiter = slot.waiter {
            slot.waiter = nil
            slot.waiterID = nil
            chunkSlot = slot
            if slot.finished {
                waiter.resume(returning: nil)
            } else if let failure = slot.failure {
                waiter.resume(throwing: failure)
            } else {
                waiter.resume(returning: StreamChunk(data: Data(), primaryDelivery: nil)) // normal hole boundary
            }
            return
        }
        chunkSlot = slot
    }

    fileprivate func chunkStreamMarkFinished(_ id: UInt64, generation: UInt64, logicalEOF: Bool = false) {
        guard var slot = chunkSlot, slot.id == id,
              let network = slot.network, network.generation == generation else { return }
        sourceClaims.release(slot.network?.claim)
        slot.network?.claim = nil
        slot.finished = logicalEOF || storeBinding == nil
            || slot.delivered + Int64(slot.bufferedBytes) >= slot.requestedCount
        slot.network?.task.cancel()
        finishPrimaryStreamSpeedWindow(network, error: nil, slot: slot)
        slot.network = nil
        if let waiter = slot.waiter, slot.buffered.isEmpty {
            slot.waiter = nil
            slot.waiterID = nil
            chunkSlot = slot
            waiter.resume(returning: slot.finished ? nil : StreamChunk(data: Data(), primaryDelivery: nil))
            return
        }
        chunkSlot = slot
    }

    // MARK: - HTTP

    private func accountBytesRead(_ count: Int) -> Bool {
        guard let amount = Int64(exactly: count), amount >= 0 else { return false }
        let result = bytesRead.addingReportingOverflow(amount)
        guard !result.overflow else { return false }
        bytesRead = result.partialValue
        return true
    }

    private func makeRequest() -> URLRequest {
        // URL used verbatim (C5): no URLComponents round-trip that could
        // re-encode the signed query.
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        // Range offsets must describe the same bytes delivered to the parser.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func load(
        _ request: URLRequest,
        window: ByteWindow,
        claim: MediaByteRangeStore.ClaimToken?
    ) async throws -> (MediaNetworkResponse, HTTPURLResponse) {
        let claims = sourceClaims
        return try await withTaskCancellationHandler {
            try await load(request, window: window)
        } onCancel: {
            claims.release(claim)
        }
    }

    /// Cancellation-aware load. If the enclosing Task is cancelled (generation
    /// bump), the URLSession request is cancelled and this throws.
    private func load(
        _ request: URLRequest, window: ByteWindow
    ) async throws -> (MediaNetworkResponse, HTTPURLResponse) {
        let result = try await MediaNetworkDataTask.load(
            session: session, request: request, policy: .window(window), counter: networkBytes
        )
        guard let http = result.response as? HTTPURLResponse else { throw SourceError.notHTTP }
        return (result, http)
    }

    // MARK: - file://

    private func fileSize() throws -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } catch let error as SourceError {
            throw error
        } catch {
            throw SourceError.fileUnreadable(error.localizedDescription)
        }
    }

    private func readFile(offset: Int64, count: Int) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw SourceError.fileUnreadable(url.path)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: count) ?? Data()
            guard accountBytesRead(data.count) else { throw SourceError.invalidRange }
            return data
        } catch let error as SourceError {
            throw error
        } catch {
            throw SourceError.fileUnreadable(error.localizedDescription)
        }
    }
}

/// Per-task delegate feeding one `ChunkStreamSlot`. All URLSession delegate
/// callbacks for a task arrive serially on the session's delegate queue; the
/// mutable slicing state below is touched only there. Deliveries hop into the
/// source actor through a CHAINED task (`hopChain`) because two bare `Task {}`
/// hops launched back-to-back are not guaranteed to reach the actor in order —
/// and out-of-order chunks would corrupt every sample behind them.
/// `@unchecked Sendable` is exactly that serialization argument.
private final class ChunkStreamBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var source: PathAHTTPMediaSource?
    private let id: UInt64
    private let generation: UInt64
    private let issuedAt: ContinuousClock.Instant
    private var firstBodyAt: ContinuousClock.Instant?
    private var firstBodyByteCount: Int64 = 0
    private var lastBodyAt: ContinuousClock.Instant?
    /// 200-slicing state (server ignored Range): skip the window's offset,
    /// deliver at most the window's count, then end the stream cleanly.
    private let slicingOffset: Int64
    private let slicingCount: Int
    private var slicingActive = false
    private var skipRemaining: Int64 = 0
    private var capRemaining = 0
    private var responseKind: ResponseKind = .pending
    private var receivedBytes: Int64 = 0
    private var hopChain: Task<Void, Never>?
    /// The bound store's delivery ledger; nil without a store binding.
    private let admissionLedger: PathAByteStoreAdmissionLedger?
    private let networkBytes: MediaNetworkByteCounter?

    private enum ResponseKind {
        case pending
        case partial(expectedLength: Int64?, limit: Int64)
        case complete(expectedLength: Int64?)
    }

    init(
        source: PathAHTTPMediaSource,
        id: UInt64,
        generation: UInt64,
        issuedAt: ContinuousClock.Instant,
        slicingOffset: Int64,
        slicingCount: Int,
        admissionLedger: PathAByteStoreAdmissionLedger?,
        networkBytes: MediaNetworkByteCounter?
    ) {
        self.source = source
        self.id = id
        self.generation = generation
        self.issuedAt = issuedAt
        self.slicingOffset = slicingOffset
        self.slicingCount = slicingCount
        self.admissionLedger = admissionLedger
        self.networkBytes = networkBytes
    }

    /// A delivery hop, counted in the store's ledger from the moment it is
    /// created (synchronously, on the delegate queue) until it has run.
    private func deliveryHop(_ chunk: Data, arrivedAt: ContinuousClock.Instant) {
        let streamID = id
        let generation = generation
        guard let ledger = admissionLedger else {
            hop {
                await $0.chunkStreamDeliverAndAdmit(
                    streamID, generation: generation, data: chunk, arrivedAt: arrivedAt
                )
            }
            return
        }
        ledger.begin()
        let source = source
        let previous = hopChain
        hopChain = Task {
            await previous?.value
            if let source {
                await source.chunkStreamDeliverAndAdmit(
                    streamID, generation: generation, data: chunk, arrivedAt: arrivedAt
                )
            }
            ledger.end()
        }
    }

    private func hop(_ operation: @escaping @Sendable (PathAHTTPMediaSource) async -> Void) {
        let source = source
        let previous = hopChain
        hopChain = Task {
            await previous?.value
            guard let source else { return }
            await operation(source)
        }
    }

    /// One terminal hop retains the physical request fence on every error path.
    private func finish(_ error: Error) {
        let streamID = id
        let generation = generation
        hop { await $0.chunkStreamFinish(streamID, generation: generation, error: error) }
    }

    /// Body bounds are shared by partial and range-ignored responses. A pending
    /// header never authorizes bytes; a 200 without length stays unbounded here.
    private func acceptBody(_ count: Int) -> Bool {
        guard let count = Int64(exactly: count) else { return false }
        let next = receivedBytes.addingReportingOverflow(count)
        guard !next.overflow else { return false }
        let limit: Int64?
        switch responseKind {
        case .pending: return false
        case .partial(_, let bound): limit = bound
        case .complete(let expectedLength): limit = expectedLength
        }
        guard limit.map({ next.partialValue <= $0 }) ?? true else { return false }
        receivedBytes = next.partialValue
        return true
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(PathAHTTPMediaSource.SourceError.notHTTP)
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 200 || http.statusCode == 206 {
            do {
                try PathAHTTPRangeValidator.validateIdentityContentEncoding(
                    http.value(forHTTPHeaderField: "Content-Encoding")
                )
            } catch {
                finish(error)
                completionHandler(.cancel)
                return
            }
        }
        switch http.statusCode {
        case 206:
            do {
                guard let requestedCount = Int64(exactly: slicingCount),
                      let requested = PathAHTTPRangeValidator.makeByteWindow(
                    offset: slicingOffset,
                    count: slicingCount
                ) else { throw PathAHTTPMediaSource.SourceError.invalidRange }
                let parsed = try PathAHTTPRangeValidator.validatePartialResponse(
                    http.value(forHTTPHeaderField: "Content-Range"),
                    requested: requested,
                    bodyCount: nil
                )
                let declaredLength = try PathAHTTPRangeValidator.declaredContentLength(
                    http.value(forHTTPHeaderField: "Content-Length")
                )
                if let declaredLength {
                    guard declaredLength <= requestedCount else {
                        throw PathAHTTPMediaSource.SourceError.invalidRange
                    }
                    if let parsedLength = parsed?.length, declaredLength != parsedLength {
                        throw PathAHTTPMediaSource.SourceError.invalidRange
                    }
                }
                let expectedLength = parsed?.length ?? declaredLength
                // Only a checked Content-Range proves which resource (and
                // which offset) the body is; without one nothing is admitted.
                let resourceLength = parsed?.total
                let limit = expectedLength ?? requestedCount
                guard limit <= requestedCount else {
                    throw PathAHTTPMediaSource.SourceError.invalidRange
                }
                responseKind = .partial(expectedLength: expectedLength, limit: limit)
                receivedBytes = 0
                let streamID = self.id
                let generation = generation
                hop {
                    await $0.chunkStreamAdmitPartial(
                        streamID, generation: generation,
                        expectedLength: expectedLength,
                        responseLimit: requestedCount,
                        resourceLength: resourceLength
                    )
                }
            } catch {
                finish(error)
                completionHandler(.cancel)
                return
            }
        case 200:
            // Range ignored — the whole resource is coming. Slice the window
            // in flight, exactly as `read` slices the buffered body.
            PlayerLog.log(
                "[PathA] ⚠️ http 200 for chunked GET host=\(dataTask.originalRequest?.url?.host ?? "?") " +
                "— server ignored Range; slicing stream"
            )
            guard let responseLimit = Int64(exactly: slicingCount) else {
                finish(PathAHTTPMediaSource.SourceError.invalidRange)
                completionHandler(.cancel)
                return
            }
            slicingActive = true
            skipRemaining = slicingOffset
            capRemaining = slicingCount
            let expectedLength: Int64?
            do {
                expectedLength = try PathAHTTPRangeValidator.declaredContentLength(
                    http.value(forHTTPHeaderField: "Content-Length")
                )
            } catch {
                finish(error)
                completionHandler(.cancel)
                return
            }
            responseKind = .complete(expectedLength: expectedLength)
            receivedBytes = 0
            let streamID = self.id
            let generation = generation
            hop {
                await $0.chunkStreamAdmitComplete(
                    streamID, generation: generation,
                    responseLimit: responseLimit,
                    resourceLength: expectedLength
                )
            }
        case 416:
            // Beyond EOF → clean empty stream, same as `read`'s empty Data.
            let streamID = self.id
            let generation = generation
            hop { await $0.chunkStreamMarkFinished(streamID, generation: generation, logicalEOF: true) }
            completionHandler(.cancel)
            return
        default:
            finish(StreamTransportFailure.http(http, stage: .mediaRead))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    private func observeBodyArrival(at instant: ContinuousClock.Instant, byteCount: Int) {
        guard byteCount > 0 else { return }
        if firstBodyAt == nil {
            firstBodyAt = instant
            firstBodyByteCount = Int64(byteCount)
        }
        lastBodyAt = instant
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Receive accounting precedes validation, slicing and actor admission.
        // Even a late callback after slot retirement belongs to this counter.
        let arrivedAt = ContinuousClock.now
        networkBytes?.add(data.count)
        guard acceptBody(data.count) else {
            finish(PathAHTTPMediaSource.SourceError.invalidRange)
            dataTask.cancel()
            return
        }
        observeBodyArrival(at: arrivedAt, byteCount: data.count)
        var payload = data
        if !payload.isEmpty {
            let receivedCount = payload.count
            let streamID = self.id
            let generation = generation
            hop { await $0.chunkStreamAccountReceived(streamID, generation: generation, count: receivedCount) }
        }
        if slicingActive {
            if skipRemaining > 0 {
                guard let payloadCount = Int64(exactly: payload.count) else {
                    finish(PathAHTTPMediaSource.SourceError.invalidRange)
                    dataTask.cancel()
                    return
                }
                let skip = Swift.min(payloadCount, skipRemaining)
                skipRemaining -= skip
                payload = payload.dropFirst(Int(skip))
            }
            guard !payload.isEmpty, capRemaining > 0 else { return }
            if payload.count > capRemaining {
                payload = payload.prefix(capRemaining)
            }
            capRemaining -= payload.count
            let reachedCap = capRemaining == 0
            let chunk = Data(payload)
            let streamID = self.id
            let generation = generation
            deliveryHop(chunk, arrivedAt: arrivedAt)
            if reachedCap {
                hop { await $0.chunkStreamMarkFinished(streamID, generation: generation) }
                dataTask.cancel()
            }
            return
        }
        // Never deliver an empty chunk: the actor's waiter path uses empty
        // Data as its loop-again sentinel.
        guard !payload.isEmpty else { return }
        deliveryHop(Data(payload), arrivedAt: arrivedAt)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let streamID = self.id
        let generation = generation
        let finalError: Error?
        if error == nil {
            switch responseKind {
            case .partial(let expectedLength, _), .complete(let expectedLength):
                if let expectedLength, receivedBytes != expectedLength {
                    finalError = PathAHTTPMediaSource.SourceError.invalidRange
                } else {
                    finalError = nil
                }
            case .pending:
                finalError = PathAHTTPMediaSource.SourceError.invalidRange
            }
        } else {
            finalError = error
        }
        if finalError == nil, case .partial(let expected, _) = responseKind,
           expected == receivedBytes, receivedBytes > 0,
           let firstBodyAt, let lastBodyAt {
            let bodySeconds = Double(firstBodyAt.duration(to: lastBodyAt) / .seconds(1))
            let latency = Double(issuedAt.duration(to: firstBodyAt) / .seconds(1))
            let rate = Double(receivedBytes - firstBodyByteCount) / bodySeconds
            if bodySeconds.isFinite, bodySeconds > 0, latency.isFinite, latency >= 0,
               rate.isFinite, rate > 0 {
                let sample = PathAHTTPMediaSource.RetrievalEstimate(
                    observedAt: lastBodyAt, latency: latency, bytesPerSecond: rate
                )
                let byteCount = receivedBytes
                hop { await $0.admitRetrievalEstimate(
                    streamID, generation: generation, sample: sample, byteCount: byteCount
                ) }
            }
        }
        hop { await $0.chunkStreamFinish(streamID, generation: generation, error: finalError) }
    }
}
