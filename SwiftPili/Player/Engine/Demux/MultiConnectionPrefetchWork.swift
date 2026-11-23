import Foundation

extension MultiConnectionPrefetcher {
    struct ClaimLease {
        let token: MediaByteRangeStore.ClaimToken
        let reservationBytes: Int64
        let cancellation: MultiConnectionCancellation
    }

    struct PlanContext {
        let cap: Int64
        let budget: Int64
        let shares: [Int64]
        let capShares: [Int64]
        let rates: [Double]
        let heldByTrack: [Int: [Range<Int64>]]
        let currentTailByTrack: [Int: Range<Int64>]
        let generation: UInt64

        func rechecked(latestCap: Int64, ahead: TimeInterval) -> Self {
            let latestBudget = min(
                budget,
                MultiConnectionPlanner.byteBudget(totalCap: latestCap, rates: rates, ahead: ahead)
            )
            let latestShares = MultiConnectionPlanner.trackShares(budget: latestBudget, rates: rates, ahead: ahead)
            let latestCapShares = MultiConnectionPlanner.trackShares(
                budget: MultiConnectionPlanner.forwardCapCeiling(totalCap: latestCap), rates: rates, ahead: ahead
            )
            return Self(
                cap: latestCap, budget: latestBudget, shares: latestShares, capShares: latestCapShares,
                rates: rates, heldByTrack: heldByTrack, currentTailByTrack: currentTailByTrack,
                generation: generation
            )
        }
    }

    struct Track: Sendable {
        let key: MediaByteRangeStore.Key
        let helpers: [URL]
        let tier1Hosts: Set<String>
        let fragments: [MultiConnectionPlanner.Fragment]
        var cursor: Int64
        let primaryHost: String?

        init(
            key: MediaByteRangeStore.Key,
            helpers: [URL],
            tier1Hosts: Set<String> = [],
            fragments: [MultiConnectionPlanner.Fragment],
            cursor: Int64,
            primaryHost: String? = nil
        ) {
            self.key = key
            self.helpers = helpers
            self.tier1Hosts = tier1Hosts
            self.fragments = fragments
            self.cursor = cursor
            self.primaryHost = primaryHost.map(MultiConnectionPlanner.canonicalHost)
        }
    }
    struct Host: Sendable {
        var speed: Double?
        var failures = 0
        var demotedUntil: TimeInterval = 0
        var pieces = 0
        var bytes: Int64 = 0
        var connection: MultiConnectionResponse.Connection?
    }
    struct Snapshot: Sendable {
        let inFlight: Int
        let stagedBytes: Int
        let completedFragments: Int
        let drops: Int
        let cancelledStagingBytes: Int64
        let hosts: [String: Host]
        let activeWorks: Int
        let activePayloadBytes: Int64
        var level = 0
        var peakEdgeRequests = 0
        var refusals = 0
        var hedges = 0
    }
    struct Flight {
        let id: UUID
        let host: String
        let lane: Int
        let startedAt: TimeInterval
        var lastProgressAt: TimeInterval
        var bytesReceived: Int64 = 0
        let requestRange: Range<Int64>
        let task: Task<Void, Never>
    }
    final class Piece {
        var id: UUID
        let range: Range<Int64>
        var receivedThrough: Int64
        var pendingOffset: Int64
        var pending = MultiConnectionPrefixBuffer()
        var terminalSucceeded = false

        init(id: UUID, range: Range<Int64>) {
            self.id = id
            self.range = range
            receivedThrough = range.lowerBound
            pendingOffset = range.lowerBound
        }

        func takePrefix() -> Data {
            let data = pending.take()
            pendingOffset += Int64(data.count)
            return data
        }

    }
    final class Work {
        static let maxRangeRetries = 6

        let id = UUID()
        let candidate: MultiConnectionPlanner.Candidate
        let claim: MediaByteRangeStore.ClaimToken
        let reservationBytes: Int64
        let cancellation: MultiConnectionCancellation
        let pieceCap: Int
        let epoch: UInt64
        var stagingBytes: Int64 = 0
        var completedResponseBytes: Int64 = 0
        var admittedBeforeRetryBytes: Int64 = 0
        var committing = false
        var refillAfterPublication = false
        var retirementSettled = false
        var publishedThrough: Int64
        var nextOffset: Int64
        var pieces: [Int64: Piece] = [:]
        var deferredRanges: [Range<Int64>] = []
        var failedHostsByRange: [Range<Int64>: Set<String>] = [:]
        var rangeRetryCount: [Range<Int64>: Int] = [:]
        var flights: [Int64: Flight] = [:]
        var hedgeFlights: [Int64: Flight] = [:]
        var activeFlightCount: Int { flights.count + hedgeFlights.count }
        var allFlights: [Flight] { Array(flights.values) + Array(hedgeFlights.values) }
        var hasQueuedBytes: Bool { nextOffset < candidate.claimRange.upperBound || !deferredRanges.isEmpty }
        var allBytesPublished: Bool { publishedThrough == candidate.claimRange.upperBound }

        func enqueueDeferred(_ range: Range<Int64>) {
            let index = deferredRanges.firstIndex { $0.lowerBound > range.lowerBound } ?? deferredRanges.endIndex
            deferredRanges.insert(range, at: index)
        }

        func canLaunch(on host: String) -> Bool {
            if nextOffset < candidate.claimRange.upperBound { return true }
            return deferredRanges.contains { !(failedHostsByRange[$0]?.contains(host) ?? false) }
        }

        func takeEligibleDeferredRange(for host: String) -> Range<Int64>? {
            guard let index = deferredRanges.firstIndex(where: {
                !(failedHostsByRange[$0]?.contains(host) ?? false)
            }) else { return nil }
            return deferredRanges.remove(at: index)
        }

        func needsFallbackHost(among hostNames: Set<String>) -> Bool {
            deferredRanges.contains { range in
                let failed = failedHostsByRange[range] ?? []
                return !hostNames.contains { !failed.contains($0) }
            }
        }

        static func claimReservationBytes(payloadBytes: Int64, totalCap: Int64) -> Int64? {
            let reservationLimit = totalCap / 2
            let singleLimit = totalCap / 3
            guard payloadBytes > 0, reservationLimit > 0, payloadBytes <= singleLimit else { return nil }
            let doubled = payloadBytes.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { return nil }
            return min(doubled.partialValue, reservationLimit)
        }

        static func fits(
            _ candidate: MultiConnectionPlanner.Candidate, context: PlanContext, works: [Work],
            isRankZero: Bool = false
        ) -> Bool {
            let reservationLimit = context.cap / 2
            guard let candidateReservation = claimReservationBytes(
                payloadBytes: candidate.claimBytes, totalCap: context.cap
            ) else { return false }
            let singleLimit = context.cap / 3
            var remaining = isRankZero ? max(context.budget, min(context.capShares[candidate.track], singleLimit)) : context.budget
            var trackRemaining = isRankZero
                ? max(context.shares[candidate.track], min(context.capShares[candidate.track], singleLimit))
                : context.shares[candidate.track]
            var reservedRemaining = reservationLimit
            for work in works {
                let bytes = work.candidate.claimBytes
                guard bytes <= remaining, work.reservationBytes <= reservedRemaining else { return false }
                remaining -= bytes
                reservedRemaining -= work.reservationBytes
                if work.candidate.track == candidate.track {
                    guard bytes <= trackRemaining else { return false }
                    trackRemaining -= bytes
                }
            }
            let bytes = candidate.claimBytes
            return bytes <= remaining && bytes <= trackRemaining && candidateReservation <= reservedRemaining
        }

        init(
            candidate: MultiConnectionPlanner.Candidate, lease: ClaimLease, pieceCap: Int, epoch: UInt64
        ) {
            self.candidate = candidate
            claim = lease.token
            reservationBytes = lease.reservationBytes
            cancellation = lease.cancellation
            self.pieceCap = pieceCap
            self.epoch = epoch
            nextOffset = candidate.claimRange.lowerBound
            publishedThrough = nextOffset
        }
    }

}

extension MultiConnectionPrefetcher {
    func ownsWork(_ work: Work) -> Bool {
        works[work.id] === work && work.epoch == epoch && !work.cancellation.isCancelled
            && (work.committing || work.allBytesPublished || store.isClaimActive(work.claim))
    }

    func receivePrefix(
        id: UUID, flightID: UUID, generation: UInt64, pieceKey: Int64, prefix: MultiConnectionPrefix
    ) async throws {
        try Task.checkCancellation()
        guard let work = works[id], generation == epoch, ownsWork(work),
              let piece = work.pieces[pieceKey] else {
            throw CancellationError()
        }
        let isPrimary = work.flights[pieceKey]?.id == flightID && piece.id == flightID
        let isHedge = work.hedgeFlights[pieceKey]?.id == flightID
        guard isPrimary || isHedge,
              var flight = isPrimary ? work.flights[pieceKey] : work.hedgeFlights[pieceKey] else {
            throw CancellationError()
        }
        let expectedOffset = flight.requestRange.lowerBound + flight.bytesReceived
        let remaining = work.candidate.claimRange.upperBound - work.publishedThrough
        guard !prefix.data.isEmpty, prefix.data.count <= MultiConnectionPlanner.minimumPieceBytes,
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
            work.flights[pieceKey] = flight
        } else {
            work.hedgeFlights[pieceKey] = flight
        }
        let prefixEnd = prefix.offset + Int64(prefix.data.count)
        guard prefixEnd > piece.receivedThrough else {
            return
        }
        let overlap = Int(max(0, piece.receivedThrough - prefix.offset))
        let appendData = overlap > 0 ? Data(prefix.data.dropFirst(overlap)) : prefix.data
        guard !appendData.isEmpty,
              work.stagingBytes <= remaining,
              Int64(appendData.count) <= remaining - work.stagingBytes else {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }
        if isHedge {
            promoteHedgeFlight(work, pieceKey: pieceKey, piece: piece, now: now)
        }
        piece.pending.append(appendData)
        piece.receivedThrough += Int64(appendData.count)
        work.stagingBytes += Int64(appendData.count)
        await publishContiguousPieces(work)
        try Task.checkCancellation()
        guard ownsWork(work) else { throw CancellationError() }
    }

    private func promoteHedgeFlight(_ work: Work, pieceKey: Int64, piece: Piece, now: TimeInterval) {
        guard let hedge = work.hedgeFlights.removeValue(forKey: pieceKey) else { return }
        if let displaced = work.flights.removeValue(forKey: pieceKey) {
            displaced.task.cancel()
            penalizeStalledHost(displaced.host, now: now)
        }
        piece.id = hedge.id
        work.flights[pieceKey] = hedge
    }

    func finishFailure(
        id: UUID, flightID: UUID, host: String, pieceKey: Int64, range: Range<Int64>, error: any Error
    ) async {
        guard let work = works[id], work.epoch == epoch else { return }
        if work.hedgeFlights[pieceKey]?.id == flightID {
            work.hedgeFlights[pieceKey] = nil
            let isQuiet: Bool
            if case MultiConnectionTransportError.quiet = error { isQuiet = true } else { isQuiet = false }
            let cancelled = work.cancellation.isCancelled || error is CancellationError || !ownsWork(work)
            if !cancelled, !isQuiet { recordFailure(host: host, error: error) }
            if ownsWork(work), canSchedule {
                refillQueues()
                armStallWatchIfNeeded()
                await schedule()
            }
            return
        }
        guard work.flights[pieceKey]?.id == flightID else { return }
        if case MultiConnectionTransportError.quiet = error, ownsWork(work) {
            work.hedgeFlights.removeValue(forKey: pieceKey)?.task.cancel()
            if work.committing { work.refillAfterPublication = true }
            await deferPiece(id: id, pieceKey: pieceKey, fallbackRange: range)
            return
        }
        if ownsWork(work), let piece = work.pieces[pieceKey],
           let hedge = work.hedgeFlights[pieceKey],
           hedge.requestRange.lowerBound <= piece.receivedThrough {
            let cancelled = work.cancellation.isCancelled || error is CancellationError
            if !cancelled { recordFailure(host: host, error: error) }
            work.hedgeFlights[pieceKey] = nil
            piece.id = hedge.id
            work.flights[pieceKey] = hedge
            armStallWatchIfNeeded()
            return
        }
        work.hedgeFlights.removeValue(forKey: pieceKey)?.task.cancel()
        await fail(id: id, host: host, pieceKey: pieceKey, range: range, error: error)
    }

    func publishContiguousPieces(_ work: Work) async {
        guard !work.committing, ownsWork(work) else { return }
        work.committing = true
        defer {
            work.committing = false
            if work.refillAfterPublication {
                work.refillAfterPublication = false
                if ownsWork(work), canSchedule { refillQueues() }
            }
        }
        while let piece = work.pieces.values.first(where: {
            $0.pendingOffset == work.publishedThrough && !$0.pending.isEmpty
        }) {
            guard !Task.isCancelled else { return }
            let data = piece.takePrefix()
            let result = await store.admitClaimedPrefix(
                tracks[work.candidate.track].key, offset: work.publishedThrough,
                data: data, claim: work.claim
            )
            if result == .admitted {
                work.publishedThrough += Int64(data.count)
                work.stagingBytes -= Int64(data.count)
                if piece.pending.isEmpty, piece.terminalSucceeded,
                   work.pieces[piece.range.lowerBound]?.id == piece.id {
                    work.pieces[piece.range.lowerBound] = nil
                }
            }
            guard result == .admitted, ownsWork(work) else {
                if works[work.id] === work { cancelWork(id: work.id) }
                settleRetiredWork(work)
                return
            }
        }
        completeWorkIfReady(work)
    }

    func completeWorkIfReady(_ work: Work) {
        let expected = work.candidate.claimBytes
        guard ownsWork(work), !work.retirementSettled, work.allBytesPublished,
              work.completedResponseBytes + work.admittedBeforeRetryBytes == expected,
              work.activeFlightCount == 0, !work.hasQueuedBytes, work.stagingBytes == 0,
              work.pieces.isEmpty else { return }
        if work.candidate.claimRange.upperBound == work.candidate.fragment.range.upperBound {
            completedFragments += 1
        }
        work.retirementSettled = true
        works[work.id] = nil
        work.pieces.removeAll()
        store.release(work.claim)
    }

    func deferPiece(id: UUID, pieceKey: Int64, fallbackRange: Range<Int64>) async {
        guard let work = works[id] else { return }
        let detached = detachFailedPiece(work, pieceKey: pieceKey, fallbackRange: fallbackRange)
        work.admittedBeforeRetryBytes += detached.admittedPrefix
        if !detached.retryRange.isEmpty {
            work.enqueueDeferred(detached.retryRange)
        }
        await schedule()
    }

    func fail(id: UUID, host: String, pieceKey: Int64, range: Range<Int64>, error: any Error) async {
        guard let work = works[id] else { return }
        let cancelled = work.cancellation.isCancelled || error is CancellationError || !ownsWork(work)
        if !cancelled { recordFailure(host: host, error: error) }
        let fullRange = work.pieces[pieceKey]?.range ?? range
        let detached = detachFailedPiece(work, pieceKey: pieceKey, fallbackRange: fullRange)
        var failedHosts = work.failedHostsByRange.removeValue(forKey: fullRange) ?? []
        failedHosts.insert(host)
        let retries = (work.rangeRetryCount.removeValue(forKey: fullRange) ?? 0) + 1
        let hasUnfailedHost = availableHosts(track: work.candidate.track)
            .contains { !failedHosts.contains($0.host ?? "") }
        if !cancelled, !policyBlocked, canSchedule, ownsWork(work),
           !detached.retryRange.isEmpty, retries <= Work.maxRangeRetries, hasUnfailedHost {
            work.admittedBeforeRetryBytes += detached.admittedPrefix
            work.failedHostsByRange[detached.retryRange] = failedHosts
            work.rangeRetryCount[detached.retryRange] = retries
            work.enqueueDeferred(detached.retryRange)
            if work.committing { work.refillAfterPublication = true }
            refillQueues()
            updateAssistAvailability()
            await logTick()
            await schedule()
            return
        }
        if !cancelled, !policyBlocked, !detached.retryRange.isEmpty,
           shouldMarkCandidateFailed(track: work.candidate.track, failedHosts: failedHosts, retries: retries) {
            failedCandidates.insert(work.candidate)
        }
        let trackIndex = work.candidate.track
        cancelWork(id: id)
        refillQueues()
        updateAssistAvailability()
        if activeRequests == 0 {
            scheduleCooldownWakeIfNeeded(pending: nil, fallbackTracks: [trackIndex])
        }
        await logTick()
    }

    private func detachFailedPiece(
        _ work: Work, pieceKey: Int64, fallbackRange: Range<Int64>
    ) -> (retryRange: Range<Int64>, admittedPrefix: Int64) {
        work.flights[pieceKey] = nil
        guard let piece = work.pieces.removeValue(forKey: pieceKey) else { return (fallbackRange, 0) }
        let range = piece.range
        let unsubmitted = max(0, piece.receivedThrough - piece.pendingOffset)
        piece.pending.clear()
        if unsubmitted > 0 {
            work.stagingBytes = max(0, work.stagingBytes - unsubmitted)
            cancelledStagingBytes += unsubmitted
        }
        let retryStart = min(range.upperBound, max(range.lowerBound, piece.pendingOffset))
        return (retryStart..<range.upperBound, retryStart - range.lowerBound)
    }

    func pruneRetiredWork() {
        for work in Array(works.values) where !work.committing {
            let claimLost = !work.allBytesPublished && !store.isClaimActive(work.claim)
            let stuckUnlaunchable = work.activeFlightCount == 0 && work.hasQueuedBytes
                && !availableHosts(track: work.candidate.track).contains { work.canLaunch(on: $0.host ?? "") }
            if work.cancellation.isCancelled || claimLost || stuckUnlaunchable {
                cancelWork(id: work.id)
            }
        }
    }

    func resolvePlanningSnapshots() async -> (
        heldByTrack: [Int: [Range<Int64>]],
        currentTailByTrack: [Int: Range<Int64>]
    ) {
        var heldByTrack: [Int: [Range<Int64>]] = [:]
        var currentTailByTrack: [Int: Range<Int64>] = [:]
        for index in tracks.indices {
            let track = tracks[index]
            heldByTrack[index] = await store.segmentRanges(for: track.key)
            if let current = track.fragments.lastIndex(where: { $0.range.lowerBound <= track.cursor }),
               let tail = await store.currentFragmentAssistSpan(
                track.key, cursor: track.cursor, within: track.fragments[current].range,
                minimumTailSplitBytes: MultiConnectionPlanner.minimumSplitBytes
               ) {
                currentTailByTrack[index] = tail
            }
        }
        return (heldByTrack, currentTailByTrack)
    }

    func resolveMissingSpan(for candidate: MultiConnectionPlanner.Candidate) async -> Range<Int64>? {
        let track = tracks[candidate.track]
        let isCurrent = track.fragments.lastIndex(where: { $0.range.lowerBound <= track.cursor })
            .map { track.fragments[$0].range == candidate.fragment.range } ?? false
        if isCurrent {
            return await store.currentFragmentAssistSpan(
                track.key, cursor: track.cursor, within: candidate.fragment.range,
                minimumTailSplitBytes: MultiConnectionPlanner.minimumSplitBytes
            )
        }
        return await store.firstUnclaimedMissingSpan(track.key, within: candidate.fragment.range)
    }

    func heldWindowBytes(track index: Int, heldRanges: [Range<Int64>]) -> Int64 {
        let track = tracks[index]
        guard position.isFinite, ahead.isFinite, ahead > 0,
              let current = track.fragments.lastIndex(where: { $0.range.lowerBound <= track.cursor }) else {
            return 0
        }
        let horizon = position + ahead
        guard horizon.isFinite else { return 0 }
        var total: Int64 = 0
        for fragment in track.fragments.dropFirst(current) {
            if fragment.startSeconds > horizon { break }
            total += MultiConnectionPlanner.heldOverlapBytes(in: fragment.range, heldRanges: heldRanges)
        }
        return total
    }

    func trackCandidateBudget(track index: Int, context: PlanContext) -> Int64 {
        let heldRanges = context.heldByTrack[index] ?? []
        let held = heldWindowBytes(track: index, heldRanges: heldRanges)
        let headroom = max(0, context.capShares[index] - held)
        let singleLimit = context.cap / 3
        let rankZeroCeiling = min(context.capShares[index], singleLimit > 0 ? singleLimit : context.shares[index])
        let tailFloor = context.currentTailByTrack[index].map {
            min(rankZeroCeiling, $0.upperBound - $0.lowerBound)
        } ?? 0
        let gapFloor = earlierGapRankZeroFloor(track: index, context: context, heldRanges: heldRanges)
        return max(min(context.shares[index], headroom), tailFloor, gapFloor)
    }

    private func earlierGapRankZeroFloor(
        track index: Int, context: PlanContext, heldRanges: [Range<Int64>]
    ) -> Int64 {
        let track = tracks[index]
        guard position.isFinite, ahead.isFinite, ahead > 0,
              let current = track.fragments.lastIndex(where: { $0.range.lowerBound <= track.cursor }) else {
            return 0
        }
        let horizon = position + ahead
        guard horizon.isFinite else { return 0 }
        let futureFragments = track.fragments.dropFirst(current + 1).prefix { $0.startSeconds <= horizon }
        guard let firstMissing = futureFragments.first(where: {
            MultiConnectionPlanner.firstMissingSpan(in: $0.range, heldRanges: heldRanges) != nil
        }), let missingSpan = MultiConnectionPlanner.firstMissingSpan(in: firstMissing.range, heldRanges: heldRanges) else {
            return 0
        }
        // Only bypass heldWindowBytes when cached bytes already exist after this gap.
        let hasHeldAfterGap = heldRanges.contains { $0.upperBound > missingSpan.upperBound }
        guard hasHeldAfterGap else { return 0 }
        let singleLimit = context.cap / 3
        let ceiling = min(context.capShares[index], singleLimit > 0 ? singleLimit : context.shares[index])
        return min(ceiling, missingSpan.upperBound - missingSpan.lowerBound)
    }

    func candidates(track: Int, context: PlanContext) -> [MultiConnectionPlanner.Candidate] {
        MultiConnectionPlanner.candidates(
            fragments: tracks[track].fragments, track: track, cursor: tracks[track].cursor,
            window: .init(
                position: position, rate: rate, ahead: ahead,
                byteBudget: trackCandidateBudget(track: track, context: context),
                heldRanges: context.heldByTrack[track] ?? [],
                currentTail: context.currentTailByTrack[track]
            )
        )
    }

    func eligible(_ candidate: MultiConnectionPlanner.Candidate, context: PlanContext) -> Bool {
        !failedCandidates.contains {
            $0.track == candidate.track && $0.claimRange == candidate.claimRange
        } && !works.values.contains {
            $0.candidate.track == candidate.track && $0.candidate.claimRange.overlaps(candidate.claimRange)
        } && candidates(track: candidate.track, context: context).contains {
            $0.fragment == candidate.fragment
        }
    }

    func fits(_ candidate: MultiConnectionPlanner.Candidate, context: PlanContext) -> Bool {
        Work.fits(candidate, context: context, works: Array(works.values), isRankZero: isRankZero(candidate))
    }

    func precedes(
        _ left: MultiConnectionPlanner.Candidate, _ right: MultiConnectionPlanner.Candidate,
        preferAbsentTrack: Bool = false
    ) -> Bool {
        let lhs = max(0, left.fragment.startSeconds - position) / Double(rate)
        let rhs = max(0, right.fragment.startSeconds - position) / Double(rate)
        if lhs != rhs { return lhs < rhs }
        if preferAbsentTrack {
            let present = Set(works.values.map { $0.candidate.track })
            if present.contains(left.track) != present.contains(right.track) { return !present.contains(left.track) }
        }
        if left.track != right.track { return left.track < right.track }
        return left.fragment.range.lowerBound < right.fragment.range.lowerBound
    }
}
