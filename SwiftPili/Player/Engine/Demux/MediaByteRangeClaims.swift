import Foundation

extension MediaByteRangeStore {
    struct ClaimToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    enum ClaimWaitResult: Equatable, Sendable {
        case none, released, timedOut, cancelled
    }

    struct ClaimDiagnostics: Sendable {
        let dupBytes: Int64
        let dedupWaits: Int64
        let dedupTimeouts: Int64
    }
}

final class MediaByteRangeClaims: @unchecked Sendable {
    typealias Key = MediaByteRangeStore.Key
    typealias Token = MediaByteRangeStore.ClaimToken
    typealias Result = MediaByteRangeStore.ClaimWaitResult

    private struct Claim {
        let key: Key
        var range: Range<Int64>
        let source: Bool
        let reservationBytes: Int64
        let cancel: @Sendable () -> Void
    }

    private struct Waiter {
        let claims: Set<Token>
        let key: Key
        let range: Range<Int64>
        let continuation: CheckedContinuation<Result, Never>
    }

    private let lock = NSLock()
    private var claims: [Token: Claim] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var waits: Int64 = 0
    private var timeouts: Int64 = 0

    func claim(
        _ key: Key,
        range: Range<Int64>,
        source: Bool = false,
        reservationLimit: Int64 = .max,
        reservationBytes: Int64? = nil,
        onCancel: @escaping @Sendable () -> Void
    ) -> Token? {
        guard range.lowerBound >= 0, !range.isEmpty, range.upperBound <= key.contentLength else { return nil }
        lock.lock()
        let overlaps = claims.filter { $0.value.key == key && $0.value.range.overlaps(range) }
        let reserved = reservedBytesLocked()
        let length = range.upperBound - range.lowerBound
        let reservation = source ? 0 : (reservationBytes ?? length)
        let exceedsReservation = reservation > reservationLimit - min(reserved, reservationLimit)
        if !source, !overlaps.isEmpty || reservation < length || exceedsReservation {
            lock.unlock()
            return nil
        }
        let revoked = source ? overlaps.filter { !$0.value.source } : [:]
        for token in revoked.keys { claims[token] = nil }
        let token = Token(id: UUID())
        claims[token] = Claim(
            key: key, range: range, source: source, reservationBytes: reservation, cancel: onCancel
        )
        let ready = settledWaiters()
        lock.unlock()
        for claim in revoked.values { claim.cancel() }
        for waiter in ready { waiter.resume(returning: .released) }
        return token
    }

    func release(_ token: Token) {
        lock.lock()
        claims[token] = nil
        let ready = settledWaiters()
        lock.unlock()
        for waiter in ready { waiter.resume(returning: .released) }
    }

    func cancelAll() {
        lock.lock()
        let cancelled = Array(claims.values)
        claims.removeAll()
        let ready = waiters.values.map(\.continuation)
        waiters.removeAll()
        lock.unlock()
        for claim in cancelled { claim.cancel() }
        for waiter in ready { waiter.resume(returning: .cancelled) }
    }

    func cancelPrefetchIfReservationsExceed(_ limit: Int64) {
        lock.lock()
        guard reservedBytesLocked() > limit else { lock.unlock(); return }
        let cancelled = claims.filter { !$0.value.source }
        for token in cancelled.keys { claims[token] = nil }
        let ready = settledWaiters()
        lock.unlock()
        for claim in cancelled.values { claim.cancel() }
        for waiter in ready { waiter.resume(returning: .cancelled) }
    }

    func isActive(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claims[token] != nil
    }

    func withClaimedPrefix(
        _ token: Token, key: Key, range: Range<Int64>,
        operation: (Int64) -> MediaByteRangeStore.AdmitOutcome
    ) -> MediaByteRangeStore.AdmitOutcome {
        lock.lock()
        guard var claim = claims[token], !claim.source, claim.key == key,
              !range.isEmpty, range.lowerBound == claim.range.lowerBound,
              range.upperBound <= claim.range.upperBound else {
            lock.unlock()
            return .rejected
        }
        let result = operation(reservedBytesLocked())
        if result == .admitted {
            if range.upperBound == claim.range.upperBound {
                claims[token] = nil
            } else {
                claim.range = range.upperBound..<claim.range.upperBound
                claims[token] = claim
            }
        }
        let ready = settledWaiters()
        lock.unlock()
        for waiter in ready { waiter.resume(returning: .released) }
        return result
    }

    func reservedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return reservedBytesLocked()
    }

    private func reservedBytesLocked() -> Int64 {
        claims.values.filter { !$0.source }.reduce(0) { total, claim in
            let sum = total.addingReportingOverflow(claim.reservationBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    func statistics() -> (waits: Int64, timeouts: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (waits, timeouts)
    }

    func activeRanges(for key: Key) -> [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return claims.values
            .filter { $0.key == key }
            .map(\.range)
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    func activeSourceRanges(for key: Key) -> [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return claims.values
            .filter { $0.source && $0.key == key }
            .map(\.range)
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    private func hasPrefetchClaim(_ key: Key, range: Range<Int64>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claims.values.contains { !$0.source && $0.key == key && $0.range.overlaps(range) }
    }

    func awaitClaims(
        _ key: Key, range: Range<Int64>, timeout: TimeInterval,
        waitBudget: MediaSourceWaitBudget? = nil
    ) async -> Result {
        guard !Task.isCancelled, waitBudget?.isCancelled != true else { return .cancelled }
        guard hasPrefetchClaim(key, range: range) else { return .none }
        let id = UUID()
        let cancellation = ClaimWaitCancellation()
        let seconds = timeout.isFinite ? max(0, min(timeout, 60)) : 1.5
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard registerWaiter(
                    id, key: key, range: range, continuation: continuation, cancellation: cancellation
                ) else { return }
                let expire: @Sendable () -> Void = { [weak self] in
                    self?.finishWaiter(id, result: waitBudget?.isCancelled == true ? .cancelled : .timedOut)
                }
                cancellation.tighten(deadline: deadline, onExpiry: expire)
                if let waitBudget {
                    let observer = waitBudget.observe { [weak self] change in
                        switch change {
                        case .deadline(let revised):
                            cancellation.tighten(deadline: min(revised, waitBudget.deadline), onExpiry: expire)
                        case .cancelled:
                            cancellation.cancel()
                            self?.finishWaiter(id, result: .cancelled)
                        }
                    }
                    cancellation.install(observer: observer, budget: waitBudget)
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.finishWaiter(id, result: .cancelled)
        }
        cancellation.cancel()
        return result
    }

    private func registerWaiter(
        _ id: UUID,
        key: Key,
        range: Range<Int64>,
        continuation: CheckedContinuation<Result, Never>,
        cancellation: ClaimWaitCancellation
    ) -> Bool {
        lock.lock()
        let overlapping = Set(claims.filter {
            !$0.value.source && $0.value.key == key && $0.value.range.overlaps(range)
        }.keys)
        if cancellation.isCancelled {
            lock.unlock()
            continuation.resume(returning: .cancelled)
            return false
        } else if overlapping.isEmpty {
            lock.unlock()
            continuation.resume(returning: .none)
            return false
        } else {
            waits = waits == .max ? .max : waits + 1
            waiters[id] = Waiter(claims: overlapping, key: key, range: range, continuation: continuation)
            lock.unlock()
            return true
        }
    }

    private func finishWaiter(_ id: UUID, result: Result) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        if waiter != nil, result == .timedOut { timeouts = timeouts == .max ? .max : timeouts + 1 }
        lock.unlock()
        waiter?.continuation.resume(returning: result)
    }

    private func settledWaiters() -> [CheckedContinuation<Result, Never>] {
        let ready = waiters.filter { _, waiter in
            waiter.claims.allSatisfy { token in
                guard let claim = claims[token] else { return true }
                return claim.key != waiter.key || !claim.range.overlaps(waiter.range)
            }
        }
        for id in ready.keys { waiters[id] = nil }
        return ready.values.map(\.continuation)
    }
}

private final class ClaimWaitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var timer: Task<Void, Never>?
    private var deadline: TimeInterval = .infinity
    private var observer: (MediaSourceWaitBudget, UUID)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func tighten(deadline revised: TimeInterval, onExpiry: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !cancelled, revised < deadline else { lock.unlock(); return }
        deadline = revised
        let previous = timer
        let seconds = max(0, revised - ProcessInfo.processInfo.systemUptime)
        timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            onExpiry()
        }
        lock.unlock()
        previous?.cancel()
    }

    func install(observer token: UUID, budget: MediaSourceWaitBudget) {
        lock.lock()
        let remove = cancelled
        if !remove { observer = (budget, token) }
        lock.unlock()
        if remove { budget.removeObserver(token) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = timer
        timer = nil
        let registered = observer
        observer = nil
        lock.unlock()
        pending?.cancel()
        if let (budget, token) = registered { budget.removeObserver(token) }
    }
}

extension MediaByteRangeStore {
    nonisolated func claimForSource(_ key: Key, range: Range<Int64>) -> ClaimToken? {
        rangeClaims.claim(key, range: range, source: true, onCancel: {})
    }

    nonisolated func release(_ token: ClaimToken) { rangeClaims.release(token) }
    nonisolated func isClaimActive(_ token: ClaimToken) -> Bool { rangeClaims.isActive(token) }

    nonisolated func awaitClaims(
        _ key: Key,
        range: Range<Int64>,
        timeout: TimeInterval = 1.5,
        waitBudget: MediaSourceWaitBudget? = nil
    ) async -> ClaimWaitResult {
        await rangeClaims.awaitClaims(key, range: range, timeout: timeout, waitBudget: waitBudget)
    }

    func diagnostics() -> ClaimDiagnostics {
        let stats = rangeClaims.statistics()
        return ClaimDiagnostics(dupBytes: dupBytes, dedupWaits: stats.waits, dedupTimeouts: stats.timeouts)
    }

    func firstUnclaimedMissingSpan(_ key: Key, within range: Range<Int64>) -> Range<Int64>? {
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound,
              range.upperBound <= key.contentLength else { return nil }
        let occupied = (segmentRanges(for: key) + rangeClaims.activeRanges(for: key))
            .filter { $0.overlaps(range) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var cursor = range.lowerBound
        for span in occupied {
            if span.lowerBound > cursor {
                return cursor..<min(span.lowerBound, range.upperBound)
            }
            cursor = max(cursor, span.upperBound)
            if cursor >= range.upperBound { return nil }
        }
        return cursor < range.upperBound ? cursor..<range.upperBound : nil
    }

    func currentFragmentAssistSpan(
        _ key: Key, cursor: Int64, within fragmentRange: Range<Int64>, minimumTailSplitBytes: Int64
    ) -> Range<Int64>? {
        guard minimumTailSplitBytes > 0, fragmentRange.lowerBound >= 0,
              fragmentRange.lowerBound < fragmentRange.upperBound,
              fragmentRange.upperBound <= key.contentLength else { return nil }
        let activeSources = rangeClaims.activeSourceRanges(for: key)
            .filter { $0.overlaps(fragmentRange) }
        if let sourceEnd = activeSources.map(\.upperBound).max() {
            guard sourceEnd > fragmentRange.lowerBound,
                  sourceEnd < fragmentRange.upperBound,
                  let tail = firstUnclaimedMissingSpan(key, within: sourceEnd..<fragmentRange.upperBound),
                  tail.upperBound - tail.lowerBound >= minimumTailSplitBytes else { return nil }
            return tail
        }
        let effectiveStart = max(fragmentRange.lowerBound, min(cursor, fragmentRange.upperBound))
        guard effectiveStart < fragmentRange.upperBound else { return nil }
        return firstUnclaimedMissingSpan(key, within: effectiveStart..<fragmentRange.upperBound)
    }
}
