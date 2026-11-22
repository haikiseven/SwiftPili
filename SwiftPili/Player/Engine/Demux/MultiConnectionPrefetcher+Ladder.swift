import Foundation

extension MultiConnectionPrefetcher {
    // MARK: - Inputs refreshed once per planning pass

    func refreshLadderInputs(pending: [MultiConnectionPlanner.Candidate], context: PlanContext) async {
        let heldByTrack = context.heldByTrack
        rankZero = [:]
        for (index, track) in tracks.enumerated() {
            guard let current = track.fragments.lastIndex(where: { $0.range.lowerBound <= track.cursor }) else {
                continue
            }
            if let tail = works.values.first(where: {
                $0.candidate.track == index && $0.candidate.fragment.range.contains(track.cursor)
                    && !$0.allBytesPublished
                    && !$0.cancellation.isCancelled
            }) {
                rankZero[index] = tail.candidate.fragment.range
                continue
            }
            if context.currentTailByTrack[index] != nil {
                rankZero[index] = track.fragments[current].range
                continue
            }
            let held = heldByTrack[index] ?? []
            rankZero[index] = track.fragments.dropFirst(current + 1).first { fragment in
                !held.contains {
                    $0.lowerBound <= fragment.range.lowerBound && $0.upperBound >= fragment.range.upperBound
                }
            }?.range
        }
        backlog = pending.contains { candidate in
            let held = heldByTrack[candidate.track] ?? []
            let covered = held.contains {
                $0.lowerBound <= candidate.claimRange.lowerBound && $0.upperBound >= candidate.claimRange.upperBound
            }
            let active = works.values.contains {
                $0.candidate.track == candidate.track && $0.candidate.claimRange.overlaps(candidate.claimRange)
            }
            return !covered && !active
        }
        let diagnostics = await store.diagnostics()
        let seen = dedupSeen ?? (diagnostics.dedupWaits, diagnostics.dedupTimeouts)
        behind = diagnostics.dedupWaits > seen.waits || diagnostics.dedupTimeouts > seen.timeouts
        dedupSeen = (diagnostics.dedupWaits, diagnostics.dedupTimeouts)
    }

    func isRankZero(_ candidate: MultiConnectionPlanner.Candidate) -> Bool {
        rankZero[candidate.track] == candidate.fragment.range
    }

    func claimPrecedes(_ left: MultiConnectionPlanner.Candidate, _ right: MultiConnectionPlanner.Candidate) -> Bool {
        let lhs = isRankZero(left), rhs = isRankZero(right)
        if lhs != rhs { return lhs }
        return precedes(left, right, preferAbsentTrack: true)
    }

    // MARK: - Claim admission (both modes)

    func claimAdmits(_ candidate: MultiConnectionPlanner.Candidate?) -> Bool {
        guard policy.auto else { return works.count < workLimit && activeRequests < concurrencyLimit }
        guard works.count < MultiConnectionPolicy.maxWorks else { return false }
        if let candidate, isRankZero(candidate) { return true }
        return activeRequests < level && !hasSchedulableQueuedWork()
    }

    private func hasSchedulableQueuedWork() -> Bool {
        let now = clock()
        var inFlight: [String: Int] = [:]
        for work in works.values {
            for flight in work.flights.values { inFlight[edgeKey(flight.host), default: 0] += 1 }
        }
        return works.values.contains { work in
            guard !work.committing, !work.cancellation.isCancelled, work.hasQueuedBytes else { return false }
            return canLaunchMore(work, rankZero: isRankZero(work.candidate), inFlight: inFlight, now: now)
        }
    }

    func claimLoopAdmits(_ candidates: inout [MultiConnectionPlanner.Candidate], blocked: Set<Int>) -> Bool {
        candidates.removeAll { blocked.contains($0.track) }
        guard !candidates.isEmpty,
              claimAdmits(nil) || (policy.auto && candidates.contains(where: isRankZero)) else { return false }
        candidates.sort { policy.auto ? claimPrecedes($0, $1) : precedes($0, $1, preferAbsentTrack: true) }
        return true
    }

    func fitsOrBlocks(
        _ candidate: MultiConnectionPlanner.Candidate, context: PlanContext, blocked: inout Set<Int>
    ) -> Bool {
        guard fits(candidate, context: context) else {
            if policy.auto { blocked.insert(candidate.track) }
            return false
        }
        return true
    }

    func claimResolvedCandidate(
        _ resolved: MultiConnectionPlanner.Candidate, context: PlanContext, blocked: inout Set<Int>
    ) async {
        guard eligible(resolved, context: context),
              fitsOrBlocks(resolved, context: context, blocked: &blocked),
              let reservation = Work.claimReservationBytes(
                payloadBytes: resolved.claimBytes, totalCap: context.cap
              ) else { return }
        let cancellation = MultiConnectionCancellation()
        guard let claim = await store.claim(
            tracks[resolved.track].key, range: resolved.claimRange,
            reservationBytes: reservation, onCancel: { cancellation.cancel() }
        ) else { return }
        let latestCap = await store.caps.totalBytes
        let latestContext = context.rechecked(latestCap: latestCap, ahead: ahead)
        guard context.generation == epoch, canSchedule, claimAdmits(resolved),
              eligible(resolved, context: latestContext),
              fitsOrBlocks(resolved, context: latestContext, blocked: &blocked),
              store.isClaimActive(claim), !cancellation.isCancelled else {
            store.release(claim)
            return
        }
        let lease = ClaimLease(token: claim, reservationBytes: reservation, cancellation: cancellation)
        let work = Work(
            candidate: resolved, lease: lease,
            pieceCap: pieceCap(resolved, bytes: resolved.claimBytes), epoch: context.generation
        )
        works[work.id] = work
        refillQueues()
    }

    func pieceCap(_ candidate: MultiConnectionPlanner.Candidate, bytes: Int64) -> Int {
        guard policy.auto else {
            return MultiConnectionPlanner.pieceCap(
                fragmentBytes: bytes,
                hostCount: Set(availableHosts(track: candidate.track).compactMap(\.host)).count,
                concurrencyLimit: concurrencyLimit
            )
        }
        return MultiConnectionPlanner.pieceCap(
            fragmentBytes: bytes, targetPieces: isRankZero(candidate) ? level : level - activeRequests
        )
    }

    // MARK: - Slot issue (§4.1, §6.2)

    func edgeKey(_ host: String) -> String { hosts[host]?.connection?.remote ?? host }

    func isIdentified(_ host: String) -> Bool {
        guard let state = hosts[host] else { return false }
        return state.connection != nil || state.pieces > 0
    }

    func refillByAllocation() {
        let now = clock()
        launchByAllocation(now: now)
        let decisions = observeLadder(now: now)
        if decisions.contains(where: { if case .stepUp = $0 { true } else { false } }) {
            launchByAllocation(now: now)
        }
    }

    private func launchByAllocation(now: TimeInterval) {
        guard canSchedule else { return }
        let laneCount = max(1, policy.sessionsPerEdge)
        var inFlight: [String: Int] = [:]
        var laneLoads: [String: [Int]] = [:]
        for work in works.values {
            for flight in work.flights.values {
                let edge = edgeKey(flight.host)
                inFlight[edge, default: 0] += 1
                var loads = laneLoads[edge] ?? Array(repeating: 0, count: laneCount)
                loads[max(0, flight.lane) % laneCount] += 1
                laneLoads[edge] = loads
            }
        }
        let ordered = works.values.filter { !$0.committing }.sorted {
            let lhs = isRankZero($0.candidate), rhs = isRankZero($1.candidate)
            return lhs != rhs ? lhs : precedes($0.candidate, $1.candidate)
        }
        let urgentQueued = ordered.contains { isRankZero($0.candidate) && $0.hasQueuedBytes }
        let ordinary = ordered.filter { !isRankZero($0.candidate) && $0.hasQueuedBytes }
        let recoveryEligible: Set<String> = urgentQueued ? [] : Set(ordinary.flatMap { work in
            availableHosts(track: work.candidate.track).map { edgeKey($0.host ?? "") }
        })
        let explore = urgentQueued ? nil : explorationEdge()
        allocation = controller.allocate(
            edges: edgeSamples(now: now, exploreEdge: explore), explore: explore, now: now,
            retainingSamples: Set(tracks.flatMap { $0.helpers.compactMap(\.host) }), inFlight: inFlight,
            recoveryEligible: recoveryEligible
        )
        for pruned in allocation.newlyPruned {
            PlayerLog.log("[Prefetch] prune host=\(pruned.key) rate=\(Self.megabytes(pruned.rate))MB/s " +
                          "median=\(Self.megabytes(pruned.median))MB/s for=\(Int(controller.tunables.pruneDuration))s")
        }
        var rankZeroQueued = false
        for work in ordered {
            let zero = isRankZero(work.candidate)
            launch(work, rankZero: zero, inFlight: &inFlight, laneLoads: &laneLoads, now: now)
            if zero, work.hasQueuedBytes { rankZeroQueued = true }
        }
        recordLaunchMetrics(inFlight: inFlight, rankZeroQueued: rankZeroQueued, now: now)
    }

    private func recordLaunchMetrics(inFlight: [String: Int], rankZeroQueued: Bool, now: TimeInterval) {
        let edgeMax = inFlight.values.max() ?? 0
        peakEdgeRequests = max(peakEdgeRequests, edgeMax)
        tickEdgeMax = max(tickEdgeMax, edgeMax)
        if rankZeroQueued {
            if rankZeroWaitSince == nil { rankZeroWaitSince = now }
        } else if let since = rankZeroWaitSince {
            tickRankZeroWaitMs = max(tickRankZeroWaitMs, Int((now - since) * 1000))
            rankZeroWaitSince = nil
        }
    }

    private struct LaunchPlan {
        var urls: [URL]
        var rankZeroSlots: [String: Int]?
        var fallbackSlots: [String: Int] = [:]
    }

    private func launchPlan(
        for work: Work, rankZero: Bool, inFlight: [String: Int], now: TimeInterval
    ) -> LaunchPlan {
        var urls = availableHosts(track: work.candidate.track)
        if !rankZero, let recovery = allocation.recoveryKey {
            urls.sort {
                (edgeKey($0.host ?? "") == recovery ? 0 : 1) < (edgeKey($1.host ?? "") == recovery ? 0 : 1)
            }
        }
        var plan = LaunchPlan(urls: urls, rankZeroSlots: nil)
        if rankZero {
            let launchable = urls.filter { work.canLaunch(on: $0.host ?? "") }
            let preferred = launchable.filter {
                let host = $0.host ?? ""
                return isTier1Host(host, track: work.candidate.track) || isIdentified(host)
            }
            let pool = preferred.isEmpty ? launchable : preferred
            plan.rankZeroSlots = controller.rankZeroSlots(
                allocation, eligible: Set(pool.map { edgeKey($0.host ?? "") })
            )
        }
        admitFallbackSlots(for: work, plan: &plan, inFlight: inFlight, now: now)
        return plan
    }

    private func admitFallbackSlots(
        for work: Work, plan: inout LaunchPlan, inFlight: [String: Int], now: TimeInterval
    ) {
        let track = work.candidate.track
        for deferred in work.deferredRanges {
            let failed = work.failedHostsByRange[deferred] ?? []
            let servable = plan.urls.contains { url in
                let host = url.host ?? ""
                return !failed.contains(host)
                    && edgeSlotCap(host: host, track: track, edge: edgeKey(host), plan: plan) > 0
            }
            if !servable,
               let index = fallbackHostIndex(in: plan.urls, excluding: failed, inFlight: inFlight, now: now) {
                let fallback = plan.urls.remove(at: index)
                plan.urls.insert(fallback, at: 0)
                let edge = edgeKey(fallback.host ?? "")
                plan.fallbackSlots[edge] = max(1, allocation.slots[edge, default: 0])
            }
        }
        guard work.nextOffset < work.candidate.claimRange.upperBound else { return }
        let hasFreshSlot = plan.urls.contains { url in
            let host = url.host ?? ""
            return edgeSlotCap(host: host, track: track, edge: edgeKey(host), plan: plan) > 0
        }
        if !hasFreshSlot,
           let index = fallbackHostIndex(in: plan.urls, excluding: [], inFlight: inFlight, now: now) {
            let edge = edgeKey(plan.urls[index].host ?? "")
            plan.fallbackSlots[edge] = max(1, allocation.slots[edge, default: 0])
        }
    }

    private func fallbackHostIndex(
        in urls: [URL], excluding failed: Set<String>, inFlight: [String: Int], now: TimeInterval
    ) -> Int? {
        let eligible = urls.indices.filter { !failed.contains(urls[$0].host ?? "") }
        guard !eligible.isEmpty else { return nil }
        let unpruned = eligible.filter { !controller.isPruned(edgeKey(urls[$0].host ?? ""), now: now) }
        if !unpruned.isEmpty {
            return unpruned.first { inFlight[edgeKey(urls[$0].host ?? ""), default: 0] == 0 } ?? unpruned[0]
        }
        return eligible.max { lhs, rhs in
            let leftRate = hosts[urls[lhs].host ?? ""]?.speed ?? 0
            let rightRate = hosts[urls[rhs].host ?? ""]?.speed ?? 0
            return leftRate != rightRate ? leftRate < rightRate : lhs > rhs
        }
    }

    private func edgeSlotCap(host: String, track: Int, edge: String, plan: LaunchPlan) -> Int {
        let slots: Int
        if let fallback = plan.fallbackSlots[edge] {
            slots = fallback
        } else if let rankZeroSlots = plan.rankZeroSlots {
            guard let allowed = rankZeroSlots[edge] else { return 0 }
            slots = allowed
        } else {
            slots = allocation.slots[edge, default: 0]
        }
        return (isTier1Host(host, track: track) || isIdentified(host)) ? slots : min(1, slots)
    }

    private func canLaunchMore(
        _ work: Work, rankZero: Bool, inFlight: [String: Int], now: TimeInterval
    ) -> Bool {
        let plan = launchPlan(for: work, rankZero: rankZero, inFlight: inFlight, now: now)
        for url in plan.urls {
            let host = url.host ?? ""
            guard work.canLaunch(on: host) else { continue }
            let edge = edgeKey(host)
            let cap = edgeSlotCap(host: host, track: work.candidate.track, edge: edge, plan: plan)
            if inFlight[edge, default: 0] < cap { return true }
        }
        return false
    }

    private func launch(
        _ work: Work, rankZero: Bool, inFlight: inout [String: Int],
        laneLoads: inout [String: [Int]], now: TimeInterval
    ) {
        guard canSchedule, !work.cancellation.isCancelled else { return }
        let plan = launchPlan(for: work, rankZero: rankZero, inFlight: inFlight, now: now)
        let laneCount = max(1, policy.sessionsPerEdge)
        for url in plan.urls {
            guard work.hasQueuedBytes, activeRequests < level else { return }
            let host = url.host ?? ""
            guard work.canLaunch(on: host) else { continue }
            let edge = edgeKey(host)
            let edgeCap = edgeSlotCap(host: host, track: work.candidate.track, edge: edge, plan: plan)
            while work.canLaunch(on: host), activeRequests < level, inFlight[edge, default: 0] < edgeCap {
                let ordinal = inFlight[edge, default: 0]
                var loads = laneLoads[edge] ?? Array(repeating: 0, count: laneCount)
                let lane = (0..<laneCount).min { loads[$0] < loads[$1] } ?? (ordinal % laneCount)
                startPiece(work, url: url, host: host, options: .init(
                    lane: lane,
                    priority: rankZero ? URLSessionTask.highPriority : URLSessionTask.lowPriority
                ))
                if edge == allocation.recoveryKey {
                    controller.noteRecoveryIssued(edge, now: clock())
                }
                inFlight[edge] = ordinal + 1
                loads[lane] += 1
                laneLoads[edge] = loads
            }
        }
    }

    private func candidateURLsForAllocation(
        track: Int, now: TimeInterval, exploreEdge: String?
    ) -> [URL] {
        let eligible = availableHosts(track: track)
        let preferred = eligible.filter { url in
            let host = url.host ?? ""
            return isTier1Host(host, track: track) || isIdentified(host)
        }
        let preferredHostSet = Set(preferred.compactMap(\.host))
        let unprunedEdges = Set(preferred.compactMap { url -> String? in
            let edge = edgeKey(url.host ?? "")
            return controller.isPruned(edge, now: now) ? nil : edge
        })
        let needsFallback = works.values.contains { work in
            work.candidate.track == track && !work.cancellation.isCancelled
                && work.needsFallbackHost(among: preferredHostSet)
        }
        let preferredCapacity = unprunedEdges.count * max(1, policy.edgeBound)
        if !unprunedEdges.isEmpty, preferredCapacity >= level, !needsFallback {
            guard let exploreEdge else { return preferred }
            let extras = eligible.filter {
                let host = $0.host ?? ""
                return !preferredHostSet.contains(host) && edgeKey(host) == exploreEdge
            }
            return preferred + extras
        }
        return eligible
    }

    private func edgeSamples(
        now: TimeInterval, exploreEdge: String?
    ) -> [MultiConnectionConcurrencyController.Edge] {
        var order: [String] = []
        var rates: [String: Double] = [:]
        var samples: [String: Int] = [:]
        var observations: [String: [String: Int]] = [:]
        var uncappedEdges: Set<String> = []
        var seenHosts: Set<String> = []
        for track in tracks.indices {
            for url in candidateURLsForAllocation(track: track, now: now, exploreEdge: exploreEdge) {
                let host = url.host ?? ""
                guard seenHosts.insert(host).inserted else { continue }
                let edge = edgeKey(host)
                if samples[edge] == nil {
                    order.append(edge)
                    samples[edge] = 0
                }
                if isTier1Host(host, track: track) || isIdentified(host) { uncappedEdges.insert(edge) }
                if let state = hosts[host] {
                    samples[edge, default: 0] += state.pieces
                    observations[edge, default: [:]][host] = state.pieces
                    if let speed = state.speed { rates[edge] = max(rates[edge] ?? 0, speed) }
                }
            }
        }
        let bound = max(1, policy.edgeBound)
        let edges = order.map { edge in
            MultiConnectionConcurrencyController.Edge(
                key: edge, rate: rates[edge], samples: samples[edge] ?? 0,
                observations: observations[edge] ?? [:],
                maxSlots: uncappedEdges.contains(edge) ? nil : 1
            )
        }
        let activeEdges = edges.filter { !controller.isPruned($0.key, now: now) }
        if !activeEdges.isEmpty {
            admittedEdgeCount = activeEdges.count
            admittedCapacity = activeEdges.reduce(0) { $0 + min(bound, $1.maxSlots ?? bound) }
        } else if let best = edges.enumerated().max(by: { lhs, rhs in
            let leftRate = lhs.element.rate ?? 0, rightRate = rhs.element.rate ?? 0
            return leftRate != rightRate ? leftRate < rightRate : lhs.offset > rhs.offset
        })?.element {
            admittedEdgeCount = 1
            admittedCapacity = min(bound, best.maxSlots ?? bound)
        } else {
            admittedEdgeCount = 0
            admittedCapacity = 0
        }
        return edges
    }

    // MARK: - Ladder observation (§3)

    @discardableResult
    func observeLadder(now: TimeInterval) -> [MultiConnectionConcurrencyController.Decision] {
        guard policy.auto else { return [] }
        let waiting = works.values.contains { !$0.committing && !$0.cancellation.isCancelled && $0.hasQueuedBytes }
            || (claimable && works.count < MultiConnectionPolicy.maxWorks)
        let observation = MultiConnectionConcurrencyController.Observation(
            saturated: canSchedule && activeRequests >= level && waiting,
            backlog: backlog, behind: behind || rankZeroProjectedLate(),
            capacity: admittedCapacity
        )
        let decisions = controller.observe(observation, now: now)
        for decision in decisions { logDecision(decision) }
        if !decisions.isEmpty { storeMemo() }
        return decisions
    }

    private func rankZeroProjectedLate() -> Bool {
        works.values.contains { work in
            guard isRankZero(work.candidate), !work.committing, rate > 0 else { return false }
            let flightHosts = Set(work.flights.values.map(\.host))
            let speed = flightHosts.reduce(0.0) { $0 + (hosts[$1]?.speed ?? 0) }
            guard speed > 0 else { return false }
            let fragment = work.candidate.fragment
            let remaining = Double(work.candidate.claimRange.upperBound - work.publishedThrough - work.stagingBytes)
            let deadline = max(0, fragment.startSeconds - position) / Double(rate)
            return remaining / speed > deadline
        }
    }
}
