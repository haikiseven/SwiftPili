import Foundation

/// Network class the App resolved for one load. Low Data Mode (`constrained`)
/// and an unsatisfied path are `.unavailable` and never prefetch.
enum MultiConnectionNetworkClass: String, Sendable, Equatable, Hashable {
    case wifi
    /// Cellular, or any interface iOS marks expensive (personal hotspot).
    case expensive
    case unavailable
}

/// Per-open prefetch policy. Bounds are SAFETY bounds, never targets: the
/// auto ladder stops on measured no-gain or on refusal, not on a table value.
/// `.expensive` runs the same ladder as `.wifi` (user decision 2026-10-04);
/// the class only selects the transport's session flags and keys the memo.
struct MultiConnectionPolicy: Sendable, Equatable {
    static let autoEnvironmentKey = "PATHA_MULTI_CONNECTION_AUTO"
    static let sessionsEnvironmentKey = "PATHA_MULTI_CONNECTION_SESSIONS"
    static let defaultSessionsPerEdge = 4
    static let maximumSessionsPerEdge = 4
    /// Levels of total concurrent helper range requests (both tracks, all edges).
    static let ladder = [2, 3, 4, 6, 8, 12, 16, 24, 32]
    /// Scheduling bound on concurrently claimed whole-fragment Works (not memory).
    static let maxWorks = 8

    var networkClass: MultiConnectionNetworkClass
    /// False is the fixed policy shipped before the ladder (rollback arm).
    var auto: Bool
    var startLevel: Int
    var totalBound: Int
    var edgeBound: Int
    var hostSlots: Int
    var sessionsPerEdge: Int
    var explores: Bool
    /// Fixed mode only: today's `requestLimit()` / `workLimit()`.
    var fixedRequestLimit: Int
    var fixedWorkLimit: Int
    /// Canonical hostnames from verified API-signed playurl URLs (`base_url` / `backup_url`).
    /// Combined with each track's primary host, these form Tier 1; other admitted UPOS hosts
    /// are Tier 2 synthetic mirrors.
    var verifiedAPIHosts: Set<String> = []

    var allowsExpensive: Bool { networkClass == .expensive }

    static func make(
        networkClass: MultiConnectionNetworkClass,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verifiedAPIHosts: Set<String> = []
    ) -> Self {
        let permitsOverrides = ExperimentalSettingsPolicy.isAllowed(.multiConnection)
        let auto = !permitsOverrides || environment[autoEnvironmentKey] != "0"
        return Self(
            networkClass: networkClass, auto: auto,
            startLevel: auto ? 8 : MultiConnectionPlanner.requestLimit(environment: environment),
            totalBound: auto ? 32 : MultiConnectionPlanner.requestLimit(environment: environment),
            edgeBound: auto ? 16 : 1,
            hostSlots: 8,
            sessionsPerEdge: resolvedSessionsPerEdge(
                auto: auto, permitsOverrides: permitsOverrides, environment: environment
            ),
            explores: true,
            fixedRequestLimit: MultiConnectionPlanner.requestLimit(environment: environment),
            fixedWorkLimit: MultiConnectionPlanner.workLimit(environment: environment),
            verifiedAPIHosts: verifiedAPIHosts
        )
    }

    private static func resolvedSessionsPerEdge(
        auto: Bool, permitsOverrides: Bool, environment: [String: String]
    ) -> Int {
        guard auto else { return 1 }
        guard permitsOverrides, let raw = environment[sessionsEnvironmentKey],
              let parsed = Int(raw), (1...maximumSessionsPerEdge).contains(parsed) else {
            return defaultSessionsPerEdge
        }
        return parsed
    }

    /// Today's behaviour byte-for-byte: one flight per host/connection identity.
    static func fixed(
        requestLimit: Int, workLimit: Int, networkClass: MultiConnectionNetworkClass = .wifi
    ) -> Self {
        let limit = max(1, min(MultiConnectionPlanner.maximumConcurrentRequests, requestLimit))
        return Self(
            networkClass: networkClass, auto: false, startLevel: limit, totalBound: limit,
            edgeBound: 1, hostSlots: 8, sessionsPerEdge: 1, explores: true,
            fixedRequestLimit: limit, fixedWorkLimit: max(1, min(2, workLimit))
        )
    }

    /// Ladder levels the policy admits at all.
    var levels: [Int] { Self.ladder.filter { $0 <= totalBound } }
}

/// Synchronous lock-protected helper availability snapshot for primary tail-split hints.
final class MultiConnectionAssistAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false
    private var parked = false
    private var policyBlocked = false
    private var trackAvailableAfter: [TimeInterval]

    init(trackCount: Int) {
        trackAvailableAfter = Array(repeating: 0, count: max(0, trackCount))
    }

    func update(
        suppressed: Bool,
        parked: Bool,
        policyBlocked: Bool,
        trackAvailableAfter: [TimeInterval]
    ) {
        lock.lock()
        self.suppressed = suppressed
        self.parked = parked
        self.policyBlocked = policyBlocked
        self.trackAvailableAfter = trackAvailableAfter
        lock.unlock()
    }

    func isAvailable(track: Int, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !suppressed, !parked, !policyBlocked,
              track >= 0, track < trackAvailableAfter.count else { return false }
        return trackAvailableAfter[track] <= now
    }
}

extension MultiConnectionPrefetcher {
    func logTick() async {
        let now = clock()
        guard now - lastLog >= 5 else { return }
        lastLog = now
        let diagnostics = await store.diagnostics()
        let sample = telemetry()
        let baseline = diagnosticBaseline
        let inFlightHosts = works.values.flatMap { $0.flights.values.map(\.host) }
        let speeds = hosts.sorted { $0.key < $1.key }.map { entry in
            "\(entry.key):\(Int(entry.value.speed ?? 0))Bps,pieces=\(entry.value.pieces),fails=\(entry.value.failures)"
                + (policy.auto ? ",k=\(inFlightHosts.filter { $0 == entry.key }.count)" : "")
        }.joined(separator: ";")
        PlayerLog.log("[Prefetch] tick hosts=[\(speeds)] inflight=\(sample.activeRequests) " +
                      "limit=\(concurrencyLimit) sampleUptime=\(String(format: "%.3f", sample.observedAt)) " +
                      "completedBytes=\(sample.completedBytes) completedFragments=\(sample.completedFragments) " +
                      "dupBytes=\(max(0, diagnostics.dupBytes - (baseline?.dupBytes ?? 0))) " +
                      "globalAdmissionOverlapBytes=\(diagnostics.dupBytes) " +
                      "dedupWaits=\(diagnostics.dedupWaits) dedupTimeouts=\(diagnostics.dedupTimeouts) " +
                      "hedges=0 drops=\(drops) cancelledStagingBytes=\(cancelledStagingBytes)" +
                      ladderTickDescription())
    }

    func ladderOpenDescription() -> String {
        let hardRest = controller.memo.activeCeiling(now: clock()).map {
            "\($0),\(Int(controller.memo.hardRestUntil - clock()))s"
        } ?? "none"
        return "policy=\(policy.networkClass.rawValue) auto=\(policy.auto ? 1 : 0) level=\(level) " +
            "bound=\(policy.totalBound) edgeBound=\(policy.edgeBound) sessions=\(policy.sessionsPerEdge) " +
            "memo=\(controller.memo.level.map(String.init) ?? "none") hardRest=\(hardRest)"
    }

    func ladderTickDescription() -> String {
        guard policy.auto else { return "" }
        var counts: [String: Int] = [:]
        for work in works.values {
            for flight in work.flights.values { counts[edgeKey(flight.host), default: 0] += 1 }
        }
        let edges = allocation.slots.keys.sorted().map { "\($0):\(counts[$0] ?? 0)/\(allocation.slots[$0] ?? 0)" }
        defer {
            tickEdgeMax = 0
            tickRankZeroWaitMs = 0
        }
        return " level=\(level) granted=\(activeRequests)/\(level) " +
            "sat=\(String(format: "%.2f", controller.lastSaturation)) works=\(works.count) " +
            "k=[\(edges.joined(separator: ","))] pruned=\(allocation.prunedCount) " +
            "rank0WaitMs=\(tickRankZeroWaitMs) edgeMax=\(tickEdgeMax) refusals=\(refusals)"
    }

    func logDecision(_ decision: MultiConnectionConcurrencyController.Decision) {
        switch decision {
        case let .stepUp(from, target, saturation, base):
            PlayerLog.log("[Prefetch] ladder up L=\(from)→\(target) sat=\(String(format: "%.2f", saturation)) " +
                          "backlog=\(backlog ? 1 : 0) behind=\(behind ? 1 : 0) base=\(Self.megabytes(base))MB/s")
        case let .keep(level, base, trial, saturation):
            PlayerLog.log(trialText(level: level, base: base, trial: trial, saturation: saturation, verdict: "keep"))
        case let .stepBack(from, _, base, trial, saturation, restFor):
            PlayerLog.log(trialText(level: from, base: base, trial: trial, saturation: saturation, verdict: "stepBack"))
            PlayerLog.log("[Prefetch] rest L>=\(from) for=\(Int(restFor))s")
        case let .inconclusive(level, saturation):
            PlayerLog.log("[Prefetch] trial L=\(level) sat=\(String(format: "%.2f", saturation)) verdict=inconclusive")
        case .hardRest:
            PlayerLog.log("[Prefetch] " + hardRestText(decision))
        }
    }

    private func trialText(level: Int, base: Double, trial: Double, saturation: Double, verdict: String) -> String {
        let gain = base > 0 ? Int(((trial / base) - 1) * 100) : 0
        return "[Prefetch] trial L=\(level) base=\(Self.megabytes(base))MB/s trial=\(Self.megabytes(trial))MB/s " +
            "gain=\(gain >= 0 ? "+" : "")\(gain)% sat=\(String(format: "%.2f", saturation)) verdict=\(verdict)"
    }

    func hardRestText(_ decision: MultiConnectionConcurrencyController.Decision?) -> String {
        guard case let .hardRest(from, target, ceiling, restFor)? = decision else { return "hardRest none" }
        return "hardRest L=\(from)→\(target) ceiling=\(ceiling) for=\(Int(restFor))s"
    }

    static func megabytes(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f", bytesPerSecond / 1_000_000)
    }

    /// Once per host, and (auto) once per new local port: h1 k-connections and lanes stay visible.
    func logConnection(_ connection: MultiConnectionResponse.Connection?, host: String, known: Bool) {
        guard let connection else { return }
        let key = "\(host)@\(connection.identity)"
        guard !known || (policy.auto && !loggedConnections.contains(key)) else { return }
        // Connections churn over a long open; the dedup set is diagnostic only, so keep it bounded.
        if loggedConnections.count >= 256 { loggedConnections.removeAll(keepingCapacity: true) }
        loggedConnections.insert(key)
        PlayerLog.log("[Prefetch] host=\(host) proto=\(connection.networkProtocol) " +
                      "remote=\(connection.remote) localPort=\(connection.localPort) reused=\(connection.reused)")
    }
}

extension MultiConnectionPrefetcher {
    func isTier1Host(_ host: String, track: Int? = nil) -> Bool {
        let canonical = MultiConnectionPlanner.canonicalHost(host)
        if let track, tracks.indices.contains(track) {
            return tracks[track].tier1Hosts.contains(canonical)
        }
        return tracks.contains { $0.tier1Hosts.contains(canonical) }
    }

    func availableHosts(track: Int) -> [URL] {
        let now = clock()
        let currentDate = Date()
        var eligible = tracks[track].helpers.filter { url in
            let host = url.host ?? ""
            return MultiConnectionPlanner.isFresh(url, now: currentDate) && (hosts[host]?.demotedUntil ?? 0) <= now
        }
        // Keep Tier 1 (API-signed backups + primary) and proven hosts ahead of untested
        // Tier 2 synthetic mirrors; among measured hosts prefer higher EWMA goodput.
        if hosts.values.contains(where: { $0.speed != nil }) {
            let tier1 = tracks[track].tier1Hosts
            eligible.sort { lhs, rhs in
                let leftHost = lhs.host ?? "", rightHost = rhs.host ?? ""
                let leftSpeed = hosts[leftHost]?.speed, rightSpeed = hosts[rightHost]?.speed
                let leftRank = (tier1.contains(MultiConnectionPlanner.canonicalHost(leftHost))
                    || leftSpeed != nil) ? 0 : 1
                let rightRank = (tier1.contains(MultiConnectionPlanner.canonicalHost(rightHost))
                    || rightSpeed != nil) ? 0 : 1
                if leftRank != rightRank { return leftRank < rightRank }
                return (leftSpeed ?? 0) > (rightSpeed ?? 0)
            }
            if !policy.auto {
                let pieces = hosts.values.reduce(0) { $0 + $1.pieces }
                if pieces % 6 == 0, let untried = eligible.firstIndex(where: { hosts[$0.host ?? ""] == nil }) {
                    eligible.insert(eligible.remove(at: untried), at: 0)
                }
            }
        }
        return eligible
    }

    /// Low-frequency probe of an untried mirror on ordinary (non-rank-0) work only.
    func explorationEdge() -> String? {
        guard policy.explores, hosts.values.contains(where: { $0.speed != nil }),
              hosts.values.reduce(0, { $0 + $1.pieces }) % 6 == 0 else { return nil }
        for track in tracks.indices {
            if let untriedTier1 = availableHosts(track: track).first(where: {
                let host = $0.host ?? ""
                return hosts[host] == nil && isTier1Host(host, track: track)
            }) {
                return edgeKey(untriedTier1.host ?? "")
            }
        }
        for track in tracks.indices {
            if let untried = availableHosts(track: track).first(where: { hosts[$0.host ?? ""] == nil }) {
                return edgeKey(untried.host ?? "")
            }
        }
        return nil
    }

    func recordFailure(host: String, error: any Error) {
        if case MultiConnectionTransportError.policyUnavailable(let reason) = error {
            policyBlocked = true
            PlayerLog.log("[Prefetch] policy-unavailable reason=\(reason) → quiet")
        } else if policy.auto {
            noteAutoFailure(host: host, error: error)
        } else {
            var state = hosts[host] ?? Host()
            state.failures += 1
            if state.failures >= 2 { state.demotedUntil = clock() + 60 }
            hosts[host] = state
            PlayerLog.log("[Prefetch] drop host=\(host) failures=\(state.failures) reason=transport_or_range")
        }
    }

    func shouldMarkCandidateFailed(
        track: Int, failedHosts: Set<String>, retries: Int
    ) -> Bool {
        let now = clock()
        guard !allHelperHostsDemoted(now: now) else { return false }
        let currentDate = Date()
        let configuredFresh = Set(
            tracks[track].helpers
                .filter { MultiConnectionPlanner.isFresh($0, now: currentDate) }
                .compactMap(\.host)
        )
        guard !configuredFresh.isEmpty else { return false }
        if configuredFresh.allSatisfy({ (hosts[$0]?.demotedUntil ?? 0) > now }) { return false }
        return retries > Work.maxRangeRetries || configuredFresh.isSubset(of: failedHosts)
    }

    func noteAutoFailure(host: String, error: any Error) {
        let now = clock()
        var state = hosts[host] ?? Host()
        switch error {
        case MultiConnectionTransportError.policyUnavailable(let reason):
            // A policy outcome: no host penalty; quiet until the App re-admits the path.
            policyBlocked = true
            PlayerLog.log("[Prefetch] policy-unavailable reason=\(reason) → quiet")
            return
        case MultiConnectionTransportError.refused(let status):
            refusals += 1
            state.failures += 2
            state.demotedUntil = now + 60
            hosts[host] = state
            // nil = another piece of an event already counted: host penalty only.
            let decision = controller.noteRefusal(now: now)
            PlayerLog.log("[Prefetch] refusal host=\(host) edge=\(edgeKey(host)) status=\(status) " +
                          "class=\(status == 200 ? "json" : "status") → " +
                          (decision == nil ? "coalesced" : hardRestText(decision)))
            if decision != nil { storeMemo() }
            return
        default:
            state.failures += 1
            if state.failures >= 2 { state.demotedUntil = now + 60 }
            hosts[host] = state
            PlayerLog.log("[Prefetch] drop host=\(host) failures=\(state.failures) reason=transport_or_range")
            if MultiConnectionTransportError.isConnectionReset(error),
               let decision = controller.noteTransportReset(edge: edgeKey(host), now: now) {
                refusals += 1
                PlayerLog.log("[Prefetch] refusal host=\(host) edge=\(edgeKey(host)) status=0 class=resetStorm → " +
                              hardRestText(decision))
                storeMemo()
            }
        }
    }

    func storeMemo() {
        guard !memoFrozen else { return }
        // Ownership fence: a memo reset (network class change) since this open
        // retires its right to teach the memo; the store is dropped atomically.
        if !memo.store(controller.memo, for: policy.networkClass, generation: memoGeneration) {
            memoFrozen = true
            PlayerLog.log("[Prefetch] memo store dropped: reset since open")
        }
    }

    func updateAssistAvailability() {
        let now = Date()
        let trackAvailableAfter: [TimeInterval] = tracks.map { track in
            let freshHosts = track.helpers.filter { MultiConnectionPlanner.isFresh($0, now: now) }
                .compactMap(\.host)
            guard !freshHosts.isEmpty else { return .infinity }
            var earliest = TimeInterval.infinity
            for host in freshHosts {
                let until = hosts[host]?.demotedUntil ?? 0
                if until < earliest { earliest = until }
            }
            return earliest
        }
        assistAvailability.update(
            suppressed: suppressed,
            parked: parked,
            policyBlocked: policyBlocked,
            trackAvailableAfter: trackAvailableAfter
        )
    }

    func allHelperHostsDemoted(now: TimeInterval) -> Bool {
        let configuredHosts = Set(tracks.flatMap { $0.helpers.compactMap(\.host) })
        guard !configuredHosts.isEmpty else { return false }
        return configuredHosts.allSatisfy { (hosts[$0]?.demotedUntil ?? 0) > now }
    }

    func hasDemotedTrackCooldown(now: TimeInterval) -> Bool {
        if allHelperHostsDemoted(now: now) { return true }
        guard cooldownWakeTask != nil else { return false }
        return tracks.contains { track in
            let trackHosts = Set(track.helpers.compactMap(\.host))
            return !trackHosts.isEmpty && trackHosts.allSatisfy { (hosts[$0]?.demotedUntil ?? 0) > now }
        }
    }

    func cancelCooldownWake() {
        cooldownWakeTask?.cancel()
        cooldownWakeTask = nil
    }

    func scheduleCooldownWakeIfNeeded(
        pending: [MultiConnectionPlanner.Candidate]?,
        fallbackTracks: Set<Int> = []
    ) {
        guard canSchedule, activeRequests == 0, cooldownWakeTask == nil else { return }
        let neededTracks: Set<Int>
        if let pending {
            guard !pending.isEmpty else { return }
            neededTracks = Set(pending.map(\.track))
        } else {
            neededTracks = Set(failedCandidates.map(\.track)).union(fallbackTracks)
        }
        guard !neededTracks.isEmpty,
              let delay = cooldownWakeDelay(for: neededTracks, pending: pending) else { return }
        let wakeEpoch = epoch
        cooldownWakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.handleCooldownWake(expectedEpoch: wakeEpoch)
        }
    }

    private func cooldownWakeDelay(
        for neededTracks: Set<Int>, pending: [MultiConnectionPlanner.Candidate]?
    ) -> TimeInterval? {
        let now = clock()
        let currentDate = Date()
        var earliestCooldown = TimeInterval.infinity
        var hasAvailableHost = false
        for trackIndex in neededTracks where tracks.indices.contains(trackIndex) {
            let freshHosts = tracks[trackIndex].helpers
                .filter { MultiConnectionPlanner.isFresh($0, now: currentDate) }
                .compactMap(\.host)
            if freshHosts.contains(where: { (hosts[$0]?.demotedUntil ?? 0) <= now }) {
                hasAvailableHost = true
            } else {
                let trackEarliest = freshHosts.compactMap { hosts[$0]?.demotedUntil }
                    .filter { $0 > now }.min() ?? .infinity
                earliestCooldown = min(earliestCooldown, trackEarliest)
            }
        }
        if earliestCooldown.isFinite, earliestCooldown > now {
            return max(0.25, min(120, earliestCooldown - now))
        }
        if hasAvailableHost, !failedAutoRetryUsed, hasBlockedFailedCandidate(in: pending) {
            failedAutoRetryUsed = true
            return 3.0
        }
        return nil
    }

    private func hasBlockedFailedCandidate(in pending: [MultiConnectionPlanner.Candidate]?) -> Bool {
        guard !failedCandidates.isEmpty else { return false }
        guard let pending else { return true }
        return pending.contains { candidate in
            failedCandidates.contains {
                $0.track == candidate.track && $0.claimRange == candidate.claimRange
            }
        }
    }

    private func handleCooldownWake(expectedEpoch: UInt64) async {
        cooldownWakeTask = nil
        guard !Task.isCancelled, canSchedule, epoch == expectedEpoch else { return }
        failedCandidates.removeAll()
        updateAssistAvailability()
        await schedule()
    }
}
