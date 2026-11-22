import Foundation

/// Opt-in speculative VOD reader. One revocable whole-fragment claim owns all
/// nonoverlapping pieces; validated contiguous prefixes enter the store atomically.
actor MultiConnectionPrefetcher {
    private let telemetryIdentity = UUID()
    let store: MediaByteRangeStore
    private let transport: any MultiConnectionTransport
    private let headers: [String: String]
    let ahead: TimeInterval
    let concurrencyLimit: Int
    var tracks: [Track]
    var hosts: [String: Host] = [:]
    var works: [UUID: Work] = [:]
    let workLimit: Int
    var failedCandidates: Set<MultiConnectionPlanner.Candidate> = []
    private let quietGate: MultiConnectionQuietGate
    private let ownsQuietGate: Bool
    private var quiet: Bool { quietGate.isQuiet }
    var suppressed = false
    var parked = false
    nonisolated let assistAvailability: MultiConnectionAssistAvailability
    var cooldownWakeTask: Task<Void, Never>?
    var failedAutoRetryUsed = false
    var position: TimeInterval
    var rate: Float
    var epoch: UInt64 = 0
    var completedFragments = 0
    var drops = 0
    var cancelledStagingBytes: Int64 = 0
    var lastLog: TimeInterval = 0
    var diagnosticBaseline: MediaByteRangeStore.ClaimDiagnostics?
    private var planning = false
    private var needsReschedule = false
    // Auto ladder state (design §3–§6); inert in fixed mode.
    let policy: MultiConnectionPolicy
    var controller: MultiConnectionConcurrencyController
    let memo: MultiConnectionLadderMemo
    /// Memo reset generation read at open; a later reset makes this open's stores stale.
    let memoGeneration: UInt64
    var memoFrozen = false
    let clock: @Sendable () -> TimeInterval
    var allocation = MultiConnectionConcurrencyController.Allocation()
    var admittedEdgeCount = 0
    var admittedCapacity = 0
    var rankZero: [Int: Range<Int64>] = [:]
    var backlog = false
    var claimable = false
    var behind = false
    var dedupSeen: (waits: Int64, timeouts: Int64)?
    var policyBlocked = false
    var refusals = 0
    var peakEdgeRequests = 0
    var tickEdgeMax = 0
    var rankZeroWaitSince: TimeInterval?
    var tickRankZeroWaitMs = 0
    var loggedConnections: Set<String> = []

    init(
        store: MediaByteRangeStore, tracks: [Track], ahead: TimeInterval, headers: [String: String] = [:],
        position: TimeInterval, rate: Float, quiet: Bool = false, quietGate: MultiConnectionQuietGate? = nil,
        transport: (any MultiConnectionTransport)? = nil,
        concurrencyLimit: Int = MultiConnectionPlanner.requestLimit(),
        workLimit: Int = MultiConnectionPlanner.workLimit(),
        policy: MultiConnectionPolicy? = nil,
        memo: MultiConnectionLadderMemo = .shared,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        networkBytes: MediaNetworkByteCounter? = nil
    ) {
        // No policy: today's fixed behaviour from the explicit limits.
        let resolved = policy ?? .fixed(requestLimit: concurrencyLimit, workLimit: workLimit)
        self.policy = resolved
        self.memo = memo
        self.clock = clock
        let learned = memo.entryAndGeneration(for: resolved.networkClass)
        memoGeneration = learned.generation
        controller = MultiConnectionConcurrencyController(
            policy: resolved, memo: learned.entry, now: clock()
        )
        self.store = store
        self.headers = headers
        self.tracks = tracks
        self.ahead = ahead
        self.position = position
        self.rate = rate
        ownsQuietGate = quietGate == nil
        self.quietGate = quietGate ?? MultiConnectionQuietGate(quiet: quiet)
        // `networkBytes` reaches only the real transport: it counts helper body
        // bytes as they arrive. An injected (test) transport counts nothing.
        self.transport = transport ?? MultiConnectionURLTransport(policy: resolved, networkBytes: networkBytes)
        self.concurrencyLimit = resolved.fixedRequestLimit
        self.workLimit = resolved.fixedWorkLimit
        assistAvailability = MultiConnectionAssistAvailability(trackCount: tracks.count)
    }

    deinit {
        cooldownWakeTask?.cancel()
    }

    nonisolated func isTailAssistAvailable(for trackIndex: Int) -> Bool {
        !quietGate.isQuiet && !quietGate.isParked && assistAvailability.isAvailable(track: trackIndex, now: clock())
    }

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ExperimentalSettingsPolicy.isAllowed(.multiConnection)
            && environment["PATHA_MULTI_CONNECTION"] != "0"
            && (!ExperimentalSettingsPolicy.diagnosticsEnabled || environment["PATHA_BYTE_CACHE"] != "0")
    }

    func start() async {
        diagnosticBaseline = await store.diagnostics()
        updateAssistAvailability()
        PlayerLog.log("[Prefetch] on hosts=\(Set(tracks.flatMap { $0.helpers.compactMap(\.host) }).count) " +
                      "ahead=\(String(format: "%.0f", ahead))s limit=\(concurrencyLimit) works=\(workLimit) " +
                      ladderOpenDescription())
        await schedule()
    }

    func update(cursors: [Int64], position: TimeInterval? = nil, rate: Float? = nil) async {
        var cursorChanged = false
        for index in tracks.indices where index < cursors.count {
            if tracks[index].cursor != cursors[index] { cursorChanged = true }
            tracks[index].cursor = cursors[index]
        }
        var rateChanged = false
        if let position, position.isFinite { self.position = position }
        if let rate, rate.isFinite, rate > 0 {
            if self.rate != rate { rateChanged = true }
            self.rate = rate
        }
        let wasParked = parked
        parked = false
        if cursorChanged || rateChanged || wasParked {
            failedCandidates.removeAll()
            failedAutoRetryUsed = false
        }
        updateAssistAvailability()
        await schedule()
    }

    func setQuiet(_ value: Bool) async {
        if ownsQuietGate { quietGate.setQuiet(value) }
        // A policy-forbidden interface stays quiet until the App re-admits the path.
        if !value { policyBlocked = false }
        if value || quiet {
            needsReschedule = false
            cancelCooldownWake()
        }
        // The gate carries the App's reason. A measurement window only holds new
        // resumes; a policy quiet (setting off, path not admitted) also retires
        // the pieces already on the wire — the same cancellation a seek uses.
        if quietGate.quietReason == .policy, !works.isEmpty {
            PlayerLog.log("[Prefetch] policy quiet → cancel inflight=\(activeRequests) works=\(works.count)")
            cancelAllWork()
            controller.restartWindow(now: clock())
        }
        updateAssistAvailability()
        if !quiet { await schedule() }
    }

    func seek(cursors: [Int64], position: TimeInterval) async {
        cancelCooldownWake()
        cancelAllWork()
        failedCandidates.removeAll()
        failedAutoRetryUsed = false
        controller.restartWindow(now: clock())
        await update(cursors: cursors, position: position)
    }

    func park() async {
        parked = true
        needsReschedule = false
        cancelCooldownWake()
        cancelAllWork()
        controller.restartWindow(now: clock())
        updateAssistAvailability()
        await clearAheadBudgets()
    }

    func cancel() async {
        suppressed = true
        needsReschedule = false
        cancelCooldownWake()
        cancelAllWork()
        // Memory pressure / close: back to the start level; this open no longer teaches the memo.
        controller.dropToStart(now: clock())
        memoFrozen = true
        updateAssistAvailability()
        await clearAheadBudgets()
    }

    private func clearAheadBudgets() async {
        for track in tracks { await store.setAheadBudget(track.key, bytes: 0) }
    }

    func telemetry() -> MultiConnectionTelemetry {
        let active = activeRequests
        let state: MultiConnectionTelemetry.State
        if suppressed {
            state = .suppressed
        } else if parked || quietGate.isParked {
            state = .parked
        } else if quiet {
            state = .quiet
        } else if policyBlocked {
            state = .networkRestricted
        } else if active > 0 {
            state = .downloading
        } else if hasDemotedTrackCooldown(now: clock()) {
            state = .coolingDown
        } else {
            state = .idle
        }
        return MultiConnectionTelemetry(
            identity: telemetryIdentity, epoch: epoch,
            observedAt: ProcessInfo.processInfo.systemUptime, state: state,
            activeRequests: active, concurrencyLimit: level, level: level,
            activeHelperHosts: works.values.flatMap { $0.flights.values.map(\.host) }.sorted(),
            candidateHosts: Set(tracks.flatMap { $0.helpers.compactMap(\.host) }).count,
            completedBytes: hosts.values.reduce(0) { $0 + $1.bytes },
            completedFragments: completedFragments, stagedBytes: stagedBytes,
            discardedBytes: cancelledStagingBytes
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            inFlight: activeRequests, stagedBytes: Int(stagedBytes),
            completedFragments: completedFragments, drops: drops,
            cancelledStagingBytes: cancelledStagingBytes, hosts: hosts,
            activeWorks: works.count, activePayloadBytes: works.values.reduce(0) { $0 + $1.candidate.claimBytes },
            level: level, peakEdgeRequests: peakEdgeRequests, refusals: refusals
        )
    }

    var activeRequests: Int { works.values.reduce(0) { $0 + $1.flights.count } }
    /// Granted concurrent requests: the ladder level, or the fixed limit.
    var level: Int { policy.auto ? controller.level : concurrencyLimit }
    private var stagedBytes: Int64 { works.values.reduce(0) { $0 + $1.stagingBytes } }

    private func cancelAllWork() {
        epoch &+= 1
        for id in Array(works.keys) { cancelWork(id: id) }
    }

    func cancelWork(id: UUID) {
        guard let work = works.removeValue(forKey: id) else { return }
        work.cancellation.cancel()
        store.release(work.claim)
        // The publisher owns any pending outcome. It settles accepted bytes
        // first, then discards only remaining staging even after retirement.
        if !work.committing { settleRetiredWork(work) }
    }

    func settleRetiredWork(_ work: Work) {
        guard !work.retirementSettled else { return }
        work.retirementSettled = true
        cancelledStagingBytes += work.stagingBytes
        work.stagingBytes = 0
        work.pieces.removeAll()
        work.flights.removeAll()
        drops += 1
    }

}

extension MultiConnectionPrefetcher {
    func schedule() async {
        guard canSchedule else { return }
        if planning {
            needsReschedule = true
            return
        }
        planning = true
        defer { planning = false }
        repeat {
            needsReschedule = false
            await scheduleOnce()
        } while needsReschedule && canSchedule
    }

    private func scheduleOnce() async {
        guard canSchedule else { return }
        pruneRetiredWork()
        refillQueues()
        let generation = epoch
        let cap = await store.caps.totalBytes
        guard generation == epoch, canSchedule else { return }
        let rates = tracks.map { track -> Double in
            let duration = track.fragments.reduce(0.0) { $0 + $1.durationSeconds }
            return duration.isFinite && duration > 0 ? Double(track.key.contentLength) / duration : 0
        }
        let budget = MultiConnectionPlanner.byteBudget(totalCap: cap, rates: rates, ahead: ahead)
        let shares = MultiConnectionPlanner.trackShares(budget: budget, rates: rates, ahead: ahead)
        let capShares = MultiConnectionPlanner.trackShares(
            budget: MultiConnectionPlanner.forwardCapCeiling(totalCap: cap), rates: rates, ahead: ahead
        )
        let snapshots = await resolvePlanningSnapshots()
        guard generation == epoch, canSchedule else { return }
        let context = PlanContext(
            cap: cap, budget: budget, shares: shares, capShares: capShares, rates: rates,
            heldByTrack: snapshots.heldByTrack, currentTailByTrack: snapshots.currentTailByTrack,
            generation: generation
        )
        for index in tracks.indices {
            let held = heldWindowBytes(track: index, heldRanges: snapshots.heldByTrack[index] ?? [])
            let protect = min(capShares[index], max(shares[index], held + shares[index]))
            await store.setAheadBudget(tracks[index].key, bytes: protect)
            guard generation == epoch, canSchedule else { return }
        }
        let pending = tracks.indices.flatMap { candidates(track: $0, context: context) }
        if policy.auto {
            await refreshLadderInputs(pending: pending, context: context)
            guard generation == epoch, canSchedule else { return }
        }
        await claimCandidates(pending, context: context)
        guard generation == epoch, canSchedule else { return }
        pruneRetiredWork()
        refillQueues()
        updateAssistAvailability()
        if activeRequests > 0 {
            cancelCooldownWake()
        } else {
            scheduleCooldownWakeIfNeeded(pending: pending)
        }
    }

    func claimCandidates(_ pending: [MultiConnectionPlanner.Candidate], context: PlanContext) async {
        var candidates = pending
        // Auto (G1): an envelope-blocked candidate blocks every farther one of its track.
        var blockedTracks: Set<Int> = []
        defer { if policy.auto { claimable = candidates.contains { !blockedTracks.contains($0.track) } } }
        while claimLoopAdmits(&candidates, blocked: blockedTracks) {
            let candidate = candidates.removeFirst()
            guard context.generation == epoch, canSchedule else { return }
            pruneRetiredWork()
            refillQueues()
            guard claimAdmits(candidate) else { break }
            guard !availableHosts(track: candidate.track).isEmpty,
                  let missingRange = await resolveMissingSpan(for: candidate) else { continue }
            guard context.generation == epoch, canSchedule else { return }
            let resolved = MultiConnectionPlanner.Candidate(
                track: candidate.track, fragment: candidate.fragment,
                claimRange: missingRange, deadline: candidate.deadline
            )
            guard claimAdmits(resolved) else { break }
            await claimResolvedCandidate(resolved, context: context, blocked: &blockedTracks)
        }
    }

    var canSchedule: Bool { !quiet && !quietGate.isParked && !suppressed && !parked && !policyBlocked }

    func refillQueues() {
        // Refill skipped committing Works when their publishers release queued ranges.
        for work in works.values where work.committing && work.hasQueuedBytes { work.refillAfterPublication = true }
        if policy.auto {
            refillByAllocation()
            return
        }
        let ordered = works.values.sorted { precedes($0.candidate, $1.candidate) }
        for work in ordered where !work.committing { launchPieces(work) }
    }

    func launchPieces(_ work: Work) {
        guard canSchedule, !work.cancellation.isCancelled else { return }
        var occupied = Set(works.values.flatMap { $0.flights.values.map(\.host) })
        var connections = Set(occupied.compactMap { hosts[$0]?.connection?.identity })
        for url in availableHosts(track: work.candidate.track) {
            guard activeRequests < concurrencyLimit, work.hasQueuedBytes else { break }
            let host = url.host ?? ""
            guard work.canLaunch(on: host), !occupied.contains(host) else { continue }
            if let connection = hosts[host]?.connection?.identity, !connections.insert(connection).inserted { continue }
            startPiece(work, url: url, host: host, options: .init())
            occupied.insert(host)
        }
    }

    /// Carves the next range of `work` and launches it on `url`. Both modes.
    func startPiece(_ work: Work, url: URL, host: String, options: MultiConnectionFetchOptions) {
        let range: Range<Int64>
        if let deferred = work.takeEligibleDeferredRange(for: host) {
            range = deferred
        } else {
            guard work.nextOffset < work.candidate.claimRange.upperBound else { return }
            var selected = min(work.pieceCap, MultiConnectionPlanner.pieceBytes(speed: hosts[host]?.speed))
            // Larger fragments use 512 KiB–1 MiB leading pieces to cut RTT overhead;
            // small and audio ranges keep the 256 KiB floor.
            if work.nextOffset == work.candidate.claimRange.lowerBound {
                selected = min(
                    selected, MultiConnectionPlanner.leadingPieceCeiling(claimBytes: work.candidate.claimBytes)
                )
            }
            let count = min(Int64(selected), work.candidate.claimRange.upperBound - work.nextOffset)
            range = work.nextOffset..<(work.nextOffset + count)
            work.nextOffset = range.upperBound
        }
        let id = work.id
        let flightID = UUID()
        let generation = work.epoch
        let key = tracks[work.candidate.track].key
        let started = clock()
        let task = Task { [transport, headers, quietGate] in
            do {
                var request = URLRequest(url: url)
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                request.setValue(
                    MediaByteRange.httpRangeHeader(
                        offset: range.lowerBound, length: range.upperBound - range.lowerBound
                    ),
                    forHTTPHeaderField: "Range"
                )
                let response = try await transport.fetch(
                    .init(request: request, range: range, resourceLength: key.contentLength),
                    quietGate: quietGate, options: options
                ) { prefix in
                    try await self.receivePrefix(
                        id: id, flightID: flightID, generation: generation, range: range, prefix: prefix
                    )
                }
                try Task.checkCancellation()
                try MultiConnectionValidation.headers(
                    status: response.status, contentRange: response.contentRange,
                    contentLength: response.contentLength,
                    range: range, resourceLength: key.contentLength, bodyCount: response.bodyCount
                )
                await finish(
                    id: id, flightID: flightID, range: range, response: response, started: started
                )
            } catch {
                await finishFailure(id: id, flightID: flightID, host: host, range: range, error: error)
            }
        }
        work.pieces[range.lowerBound] = Piece(id: flightID, range: range)
        work.flights[range.lowerBound] = Flight(id: flightID, host: host, lane: options.lane, task: task)
        work.cancellation.insert(task)
    }

    func finish(
        id: UUID, flightID: UUID, range: Range<Int64>,
        response: MultiConnectionResponse, started: TimeInterval
    ) async {
        guard let work = works[id], ownsWork(work),
              let flight = work.flights[range.lowerBound], flight.id == flightID,
              let piece = work.pieces[range.lowerBound], piece.id == flightID else { return }
        let host = flight.host
        guard piece.receivedThrough == range.upperBound else {
            await fail(id: id, host: host, range: range, error: PathAHTTPMediaSource.SourceError.invalidRange)
            return
        }
        let generation = epoch
        work.flights[range.lowerBound] = nil
        if work.committing { work.refillAfterPublication = true }
        piece.terminalSucceeded = true
        work.completedResponseBytes += Int64(response.bodyCount)
        if piece.pending.isEmpty { work.pieces[range.lowerBound] = nil }
        var state = hosts[host] ?? Host()
        let finishedAt = clock()
        let speed = Double(response.bodyCount) / max(0.001, finishedAt - started)
        state.speed = MultiConnectionPlanner.updatedSpeed(previous: state.speed, sample: speed)
        state.failures = 0
        state.pieces += 1
        state.bytes += Int64(response.bodyCount)
        logConnection(response.connection, host: host, known: state.connection != nil)
        state.connection = response.connection ?? state.connection
        hosts[host] = state
        updateAssistAvailability()
        if policy.auto {
            controller.noteCompletion(bytes: Int64(response.bodyCount), seconds: finishedAt - started, now: finishedAt)
        }
        await publishContiguousPieces(work)
        completeWorkIfReady(work)
        await logTick()
        // A retired/rejected publisher cannot replenish replacement work.
        // Normal final publication may still release a slot for scheduling.
        guard generation == epoch, !work.cancellation.isCancelled,
              works[id] === work || work.publishedThrough == work.candidate.claimRange.upperBound else { return }
        await schedule()
    }

}
