import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor PathAHTTPMediaSource {

    struct ResourceInfo: Sendable, Equatable {
        let contentLength: Int64?
        let contentType: String?
    }

    struct InitialHead: Sendable, Equatable {
        enum ResponseKind: Sendable, Equatable {
            case file
            case httpPartial
            case httpRangeIgnored
        }

        let data: Data
        let info: ResourceInfo
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

    struct RetrievalEstimate: Sendable {
        let observedAt: ContinuousClock.Instant
        let latency: Double
        let bytesPerSecond: Double
    }

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
    private let networkBytes: MediaNetworkByteCounter?
    private let bootstrapIdentity: MediaBootstrapIdentity?
    private(set) var info: ResourceInfo?

    private var primedHead: Data?
    private var displayTrack: MediaDisplayTrack?
    private var displayPrimed: MediaDisplayLease?

    func setDisplayTrack(_ track: MediaDisplayTrack?) {
        displayTrack = track
        displayPrimed = primedHead.flatMap { track?.own(bytes: 0..<Int64($0.count)) }
    }

    private let byteStore: MediaByteRangeStore?
    private var storeBinding: PathAByteStoreBinding?
    private let sourceClaims = PathAByteSourceClaims()

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
        primedHead = data.isEmpty ? nil : Data(data)
        PlayerLog.log(
            "[PathA] http initial-head host=\(url.host ?? "?") " +
            "len=\(total.map(String.init) ?? "?") " +
            "status=\(http.statusCode) primed=\(data.count)B in=\(headMs)ms"
        )
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
        await binding?.bindOpened(head: retained.data)
        try checkClaimFence(ticket)
        info = retained.info
        primedHead = retained.data
        storeBinding = binding
        return retained
    }

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
            let now = ProcessInfo.processInfo.systemUptime
            deadline = deadline ?? (now + 1.5)
            let result = await binding.awaitClaims(
                offset: cursor, count: 1, timeout: max(0, (deadline ?? now) - now), waitBudget: waitBudget
            )
            try checkClaimFence(ticket, waitBudget: waitBudget)
            if result == .cancelled { throw CancellationError() }
            if result == .released {
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
        if let binding = storeBinding, let range, binding.admits(resourceLength: range.total) {
            await binding.admit(offset: window.offset, data: data)
        }
        return NetworkWindowResult(data: data, reachedResourceEnd: range.map { $0.total == $0.end + 1 } ?? false)
    }

    private func acceptCompleteRead(
        _ received: MediaNetworkResponse, window: ByteWindow
    ) async throws -> NetworkWindowResult {
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
        if let ticket = claim?.waitTicket { try checkClaimFence(ticket, waitBudget: waitBudget) }
        try checkWaitBudget(waitBudget)
    }

    // MARK: - Chunk stream (streaming mdat)

    private struct ChunkStreamSlot {
        let id: UInt64
        var network: NetworkSpan?
        var networkGeneration: UInt64 = 0
        let baseOffset: Int64
        let requestedCount: Int64
        var buffered: [StreamChunk] = []
        var bufferedBytes = 0
        var heldQueuedBytes = 0
        var delivered: Int64 = 0
        var finished = false
        var failure: Error?
        var waiter: CheckedContinuation<StreamChunk?, Error>?
        var waiterID: UUID?
        var tailEndedForBackpressure = false
        let openedAt = ContinuousClock.now
        var chunkCount = 0
        var arrivedBytes: Int64 = 0
        var backpressureEndCount = 0
        var lastArrivalAt: ContinuousClock.Instant?
        var maxArrivalGapMs = 0
    }

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

    private struct StreamChunk: Sendable {
        let data: Data
        let primaryDelivery: PrimaryDelivery?
        var displayBytes: MediaDisplayLease? = nil
    }

    private var chunkSlot: ChunkStreamSlot?
    private var chunkSlotSeq: UInt64 = 0
    private var chunkOpenTicket: UInt64 = 0

    private static let chunkBufferHighWater = 4 * 1024 * 1024

    func openChunkStream(
        offset: Int64, count: Int, waitBudget: MediaSourceWaitBudget? = nil
    ) async throws -> UInt64 {
        try checkWaitBudget(waitBudget)
        guard !isFile else { throw SourceError.fileUnreadable("chunk stream on file source") }
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: offset, count: count) else {
            throw SourceError.invalidRange
        }

        let displayBytes = displayTrack.map(MediaDisplayByteOwner.init)
        defer { displayBytes?.release() }
        let primed = primedHeadPrefix(offset: offset, count: count)
        if let primed { displayBytes?.hold(offset..<(offset + Int64(primed.count))) }
        let primedCount = primed?.count ?? 0
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
        if primedCount > 0 { releaseHead() } else { releaseHeadIfPassed(offset: offset) }
        return id
    }

    private func claimChunkSlotID() throws -> UInt64 {
        let nextID = chunkSlotSeq.addingReportingOverflow(1)
        guard !nextID.overflow, nextID.partialValue != 0 else {
            throw SourceError.invalidRange
        }
        retireChunkSlot(throwing: CancellationError())
        chunkSlotSeq = nextID.partialValue
        return nextID.partialValue
    }

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

    private func primedHeadSlice(offset: Int64, count: Int) -> Data? {
        guard let window = PathAHTTPRangeValidator.makeByteWindow(offset: offset, count: count),
              let head = primedHead,
              let start = Int(exactly: window.offset),
              let end = Int(exactly: window.endExclusive),
              start >= 0,
              end <= head.count else { return nil }
        return head.subdata(in: start..<end)
    }

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

    private func releaseHeadIfPassed(offset: Int64) {
        guard let head = primedHead, offset >= Int64(head.count) else { return }
        releaseHead()
    }

    private func releaseHead() {
        guard primedHead != nil else { return }
        primedHead = nil
        displayPrimed = nil
    }

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

    func activeChunkStreamID() -> UInt64? {
        guard let slot = chunkSlot,
              slot.network != nil,
              !slot.finished,
              slot.failure == nil,
              !slot.tailEndedForBackpressure else {
            return nil
        }
        return slot.id
    }

    func interruptActiveIO() -> MediaDemuxIOInterruptResult {
        guard let id = activeChunkStreamID() else {
            return .noActiveOperation
        }
        return closeChunkStream(id) ? .interrupted : .noActiveOperation
    }

    @discardableResult
    func closeChunkStream(_ id: UInt64) -> Bool {
        guard chunkSlot?.id == id else { return false }
        retireChunkSlot(throwing: CancellationError())
        return true
    }

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
                throw CancellationError()
            }
            try Task.checkCancellation()
            let resumed = try await waitForNetworkChunk(id, waitBudget: waitBudget)
            try checkWaitBudget(waitBudget)
            guard chunkSlot?.id == id else { throw CancellationError() }
            guard let resumed else { return nil }
            if resumed.data.isEmpty { continue }
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
                        cont.resume(returning: StreamChunk(data: Data(), primaryDelivery: nil))
                    }
                }
            } onCancel: {
                Task { await self.cancelChunkWaiter(id, waiterID: waiterID) }
            }
    }

    func closeActiveChunkStream() {
        chunkOpenTicket &+= 1
        retireChunkSlot(throwing: CancellationError())
        sourceClaims.releaseAll()
    }

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
            claim = nil
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

    fileprivate func chunkStreamDeliverAndAdmit(
        _ id: UInt64, generation: UInt64, data: Data, arrivedAt: ContinuousClock.Instant
    ) async {
        guard let admission = chunkStreamDeliver(
            id, generation: generation, data: data, arrivedAt: arrivedAt
        ) else { return }
        await admission.binding.admit(offset: admission.offset, data: data)
    }

    private struct ChunkStoreAdmission {
        let binding: PathAByteStoreBinding
        let offset: Int64
    }

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
        if !slot.tailEndedForBackpressure,
           slot.bufferedBytes - slot.heldQueuedBytes > Self.chunkBufferHighWater {
            slot.tailEndedForBackpressure = true
            slot.backpressureEndCount += 1
            slot.network?.task.cancel()
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
                waiter.resume(returning: StreamChunk(data: Data(), primaryDelivery: nil))
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
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
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

private final class ChunkStreamBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var source: PathAHTTPMediaSource?
    private let id: UInt64
    private let generation: UInt64
    private let issuedAt: ContinuousClock.Instant
    private var firstBodyAt: ContinuousClock.Instant?
    private var firstBodyByteCount: Int64 = 0
    private var lastBodyAt: ContinuousClock.Instant?
    private let slicingOffset: Int64
    private let slicingCount: Int
    private var slicingActive = false
    private var skipRemaining: Int64 = 0
    private var capRemaining = 0
    private var responseKind: ResponseKind = .pending
    private var receivedBytes: Int64 = 0
    private var hopChain: Task<Void, Never>?
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

    private func finish(_ error: Error) {
        let streamID = id
        let generation = generation
        hop { await $0.chunkStreamFinish(streamID, generation: generation, error: error) }
    }

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
