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
        /// Canonical hostnames for Tier 1 (verified API-signed backups + primary).
        let tier1Hosts: Set<String>
        let fragments: [MultiConnectionPlanner.Fragment]
        var cursor: Int64

        init(
            key: MediaByteRangeStore.Key,
            helpers: [URL],
            tier1Hosts: Set<String> = [],
            fragments: [MultiConnectionPlanner.Fragment],
            cursor: Int64
        ) {
            self.key = key
            self.helpers = helpers
            self.tier1Hosts = tier1Hosts
            self.fragments = fragments
            self.cursor = cursor
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
        /// Granted ladder level (fixed mode: the request limit).
        var level = 0
        /// Highest concurrent requests on one edge since open.
        var peakEdgeRequests = 0
        var refusals = 0
    }
    /// One in-flight piece. Keyed by the piece's offset, so an edge can carry k.
    struct Flight {
        let id: UUID
        let host: String
        let lane: Int
        let task: Task<Void, Never>
    }
    /// One coalesced staging owner per physical request, independent of callback count.
    final class Piece {
        let id: UUID
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
        /// Validated prefix bytes admitted to store before a piece failed mid-transfer and retried its suffix.
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

        /// 2x logical payload reservation up to the store's `cap / 2` reservation ceiling.
        /// A single large fragment up to `cap / 3` clamps to `cap / 2` so low-RAM caps never deadlock.
        static func claimReservationBytes(payloadBytes: Int64, totalCap: Int64) -> Int64? {
            let reservationLimit = totalCap / 2
            let singleLimit = totalCap / 3
            guard payloadBytes > 0, reservationLimit > 0, payloadBytes <= singleLimit else { return nil }
            let doubled = payloadBytes.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { return nil }
            return min(doubled.partialValue, reservationLimit)
        }

        static func fits(
            _ candidate: MultiConnectionPlanner.Candidate, context: PlanContext, works: [Work]
        ) -> Bool {
            let reservationLimit = context.cap / 2
            guard let candidateReservation = claimReservationBytes(
                payloadBytes: candidate.claimBytes, totalCap: context.cap
            ) else { return false }
            var remaining = context.budget
            var trackRemaining = context.shares[candidate.track]
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
            // Final admission can consume the token before its actor return.
            && (work.committing || work.allBytesPublished || store.isClaimActive(work.claim))
    }

    func receivePrefix(
        id: UUID, flightID: UUID, generation: UInt64, range: Range<Int64>, prefix: MultiConnectionPrefix
    ) async throws {
        try Task.checkCancellation()
        guard let work = works[id], generation == epoch, ownsWork(work),
              work.flights[range.lowerBound]?.id == flightID,
              let piece = work.pieces[range.lowerBound], piece.id == flightID, piece.range == range else {
            throw CancellationError()
        }
        let remaining = work.candidate.claimRange.upperBound - work.publishedThrough
        guard !prefix.data.isEmpty, prefix.data.count <= MultiConnectionPlanner.minimumPieceBytes,
              prefix.offset == piece.receivedThrough, prefix.offset < range.upperBound,
              Int64(prefix.data.count) <= range.upperBound - prefix.offset,
              work.stagingBytes <= remaining, Int64(prefix.data.count) <= remaining - work.stagingBytes else {
            throw PathAHTTPMediaSource.SourceError.invalidRange
        }
        piece.pending.append(prefix.data)
        piece.receivedThrough += Int64(prefix.data.count)
        work.stagingBytes += Int64(prefix.data.count)
        await publishContiguousPieces(work)
        try Task.checkCancellation()
        guard ownsWork(work) else { throw CancellationError() }
    }

    func finishFailure(id: UUID, flightID: UUID, host: String, range: Range<Int64>, error: any Error) async {
        guard let work = works[id], work.epoch == epoch,
              work.flights[range.lowerBound]?.id == flightID else { return }
        if case MultiConnectionTransportError.quiet = error, ownsWork(work) {
            if work.committing { work.refillAfterPublication = true }
            work.pieces[range.lowerBound] = nil
            await deferPiece(id: id, host: host, range: range)
        } else {
            await fail(id: id, host: host, range: range, error: error)
        }
    }

    /// One publisher owns all store awaits; concurrent transfers only append to
    /// their bounded coalesced buffers. Detached admission bytes stay accounted
    /// until the store's actual outcome, including retirement during that await.
    func publishContiguousPieces(_ work: Work) async {
        guard !work.committing, ownsWork(work) else { return }
        work.committing = true
        defer {
            work.committing = false
            // Success, quiet deferral, or piece-level retry may free a slot while
            // this publisher holds the Work. Resume once publication settles.
            if work.refillAfterPublication {
                work.refillAfterPublication = false
                if ownsWork(work), canSchedule { refillQueues() }
            }
        }
        while let piece = work.pieces.values.first(where: {
            $0.pendingOffset == work.publishedThrough && !$0.pending.isEmpty
        }) {
            // A failed transfer cancels its drain before the actor receives the
            // failure. Settle the previous await, but start no further admission.
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

    /// Byte coverage consumes the claim, but does not complete a response. Keep
    /// that Work until every physical request has its exact successful receipt.
    func completeWorkIfReady(_ work: Work) {
        let expected = work.candidate.claimBytes
        guard ownsWork(work), !work.retirementSettled, work.allBytesPublished,
              work.completedResponseBytes + work.admittedBeforeRetryBytes == expected,
              work.flights.isEmpty, !work.hasQueuedBytes, work.stagingBytes == 0,
              work.pieces.isEmpty else { return }
        if work.candidate.claimRange.upperBound == work.candidate.fragment.range.upperBound {
            completedFragments += 1
        }
        work.retirementSettled = true
        works[work.id] = nil
        work.pieces.removeAll()
        store.release(work.claim)
    }

    func deferPiece(id: UUID, host: String, range: Range<Int64>) async {
        guard let work = works[id] else { return }
        work.flights[range.lowerBound] = nil
        work.enqueueDeferred(range)
        // An unquiet edge may have arrived while transport was delivering
        // this rejection; resume deferred work without waiting for a pump.
        await schedule()
    }

    func fail(id: UUID, host: String, range: Range<Int64>, error: any Error) async {
        guard let work = works[id] else { return }
        let cancelled = work.cancellation.isCancelled || error is CancellationError || !ownsWork(work)
        if !cancelled { recordFailure(host: host, error: error) }
        let detached = detachFailedPiece(work, range: range)
        var failedHosts = work.failedHostsByRange.removeValue(forKey: range) ?? []
        failedHosts.insert(host)
        let retries = (work.rangeRetryCount.removeValue(forKey: range) ?? 0) + 1
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
        _ work: Work, range: Range<Int64>
    ) -> (retryRange: Range<Int64>, admittedPrefix: Int64) {
        work.flights[range.lowerBound] = nil
        guard let piece = work.pieces.removeValue(forKey: range.lowerBound) else { return (range, 0) }
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
            let stuckUnlaunchable = work.flights.isEmpty && work.hasQueuedBytes
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
               let tail = await store.currentTailAssistSpan(
                track.key, within: track.fragments[current].range,
                minimumBytes: MultiConnectionPlanner.minimumSplitBytes
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
            return await store.currentTailAssistSpan(
                track.key, within: candidate.fragment.range,
                minimumBytes: MultiConnectionPlanner.minimumSplitBytes
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
        let held = heldWindowBytes(track: index, heldRanges: context.heldByTrack[index] ?? [])
        let headroom = max(0, context.capShares[index] - held)
        let tailFloor = context.currentTailByTrack[index].map {
            min(context.shares[index], $0.upperBound - $0.lowerBound)
        } ?? 0
        return max(min(context.shares[index], headroom), tailFloor)
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
        Work.fits(candidate, context: context, works: Array(works.values))
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
