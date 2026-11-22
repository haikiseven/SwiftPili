import Foundation

/// Call-time media capabilities. The transaction never stores its host.
@MainActor
protocol WarmPreparationTransactionHost: AnyObject {
    func makeWarmVideoPreparationRun(
        id: UInt64, token: DemandVideoSuspendToken
    ) -> WarmVideoPreparationRunLedger.Run
    func performWarmVideoPreparation(
        _ run: WarmVideoPreparationRunLedger.Run
    ) async -> DemandVideoLanePreparationResult
    func consumeWarmVideoPreparationProgress(for run: WarmVideoPreparationRunLedger.Run) -> Bool
    func captureWarmPreparationInterrupt() -> WarmPreparationTransaction.InterruptOperation
    func applyWarmPreparationNotice(_ notice: WarmPreparationTransaction.Notice)
}

/// Cancellation handlers run outside MainActor; settlement reads the same marker.
private final class WarmPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct WarmPreparationWaiter {
    let id: UInt64
    let cancellation: WarmPreparationCancellation
    let continuation: CheckedContinuation<DemandVideoLanePreparationResult, Never>
}

/// Run lifetime and exactly-once public settlement, separate from media work.
/// Cancelled handles are not actual-return evidence: the run ledger owns that.
@MainActor
final class WarmPreparationTransaction {
    typealias Run = WarmVideoPreparationRunLedger.Run
    typealias InterruptOperation = @MainActor @Sendable () async -> MediaDemuxIOInterruptResult
    enum Notice {
        case runStarted(Run)
        case primaryReturned(Run, DemandVideoLanePreparationResult)
        case timeoutObserved(Run)
        case timeoutWillSettle(Run)
        case timeoutResultStored
        case currentRunReleased
        case matchingOrphanRunReleased
        case runCancelled(Run)
        case resetInvalidation
        case supplyRestartOpportunity
    }

    private let progressWindow: Duration
    private let directWindow: Duration
    private let diagnostics: any MediaEngineDiagnostics
    private var ledger = WarmVideoPreparationRunLedger()
    // Unstructured deliberately: a structured race would await a stuck loser.
    private var primaryTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var interruptTask: Task<Void, Never>?
    private var waiters: [UInt64: [WarmPreparationWaiter]] = [:]
    private var settledResults: [UInt64: DemandVideoLanePreparationResult] = [:]
    private var nextWaiterID: UInt64 = 0
    private(set) var joinCount = 0
    private(set) var timeoutCount = 0
    private(set) var timeoutExtensionCount = 0
    private(set) var orphanCount = 0
    private(set) var lastInterruptResult: MediaDemuxIOInterruptResult?

    var currentRun: Run? { ledger.currentRun }
    var orphan: WarmVideoPreparationRunLedger.Orphan? { ledger.orphan }
    var hasPendingInterrupt: Bool { ledger.hasPendingInterrupt }

    init(progressWindow: Duration, directWindow: Duration, diagnostics: any MediaEngineDiagnostics) {
        self.progressWindow = progressWindow
        self.directWindow = directWindow
        self.diagnostics = diagnostics
    }

    /// Complete admission and Task publication before Session's first await.
    func begin(token: DemandVideoSuspendToken, host: any WarmPreparationTransactionHost) -> Run {
        if let inFlight = ledger.currentRun, inFlight.token == token {
            diagnostics.log(
                "[PathA][continuation] prepare joined run=\(inFlight.id) " +
                    "waiters=\((waiters[inFlight.id]?.count ?? 0) + 1)"
            )
            joinCount &+= 1
            return inFlight
        }
        // Allocate first; only the new-run branch samples Session identity/clock.
        let runID = ledger.allocateRunID()
        let run = host.makeWarmVideoPreparationRun(id: runID, token: token)
        ledger.activate(run)
        host.applyWarmPreparationNotice(.runStarted(run))
        primaryTask = Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            let result = await host.performWarmVideoPreparation(run)
            self.complete(run, result: result, host: host)
        }
        deadlineTask = Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            do {
                try await Task.sleep(for: self.policy(for: run).watchdogDelay(at: .now))
            } catch {
                return
            }
            self.timeout(run, host: host)
        }
        return run
    }

    func policy(for run: Run) -> WarmVideoRecoveryPolicy {
        WarmVideoRecoveryPolicy(
            startedAt: run.startedAt, progressWindow: progressWindow, directWindow: directWindow
        )
    }

    /// Session checks full runtime currentness immediately before this query.
    func hasTime(for run: Run, host: any WarmPreparationTransactionHost) -> Bool {
        guard policy(for: run).remaining(at: .now) > .zero else {
            timeout(run, host: host)
            return false
        }
        return true
    }

    func supersede(host: any WarmPreparationTransactionHost) {
        guard let run = ledger.currentRun else { return }
        host.applyWarmPreparationNotice(.runCancelled(run))
        if let orphanedRunID = ledger.orphan?.runID, orphanedRunID != run.id {
            // Preserve the older orphan and the original primary-handle lifetime.
            primaryTask?.cancel()
            deadlineTask?.cancel()
            deadlineTask = nil
            cancelAllWaiters()
            ledger.clearCurrentRun()
            host.applyWarmPreparationNotice(.currentRunReleased)
            return
        }
        ledger.parkRetiredRun(run)
        orphanCount = 1
        primaryTask?.cancel()
        deadlineTask?.cancel()
        deadlineTask = nil
        cancelAllWaiters()
        settledResults.removeValue(forKey: run.id)
        ledger.clearCurrentRun()
        host.applyWarmPreparationNotice(.currentRunReleased)
        requestInterrupt(for: run, host: host)
    }

    func reset(host: any WarmPreparationTransactionHost) {
        if let run = ledger.currentRun {
            host.applyWarmPreparationNotice(.runCancelled(run))
            // Reset intentionally retains its existing different-orphan asymmetry.
            ledger.parkRetiredRun(run)
            orphanCount = 1
            primaryTask?.cancel()
            requestInterrupt(for: run, host: host)
        }
        deadlineTask?.cancel()
        deadlineTask = nil
        primaryTask = nil
        lastInterruptResult = nil
        host.applyWarmPreparationNotice(.resetInvalidation)
        cancelAllWaiters()
        settledResults.removeAll(keepingCapacity: false)
        ledger.clearCurrentRun()
    }

    /// Keep the exact admitted host alive through waiter settlement, as the
    /// original Session-owned operation closure did. Cleanup still stays weak.
    func result(for run: Run, host: any WarmPreparationTransactionHost) async -> DemandVideoLanePreparationResult {
        defer { withExtendedLifetime(host) {} }
        if let result = settledResults[run.id] { return result }
        nextWaiterID &+= 1
        if nextWaiterID == 0 { nextWaiterID = 1 }
        let waiterID = nextWaiterID
        let cancellation = WarmPreparationCancellation()
        return await withTaskCancellationHandler(operation: {
            let result: DemandVideoLanePreparationResult = await withCheckedContinuation { continuation in
                if let result = self.settledResults[run.id] {
                    continuation.resume(returning: cancellation.isCancelled ? .cancelled : result)
                    return
                }
                self.waiters[run.id, default: []].append(WarmPreparationWaiter(
                    id: waiterID, cancellation: cancellation, continuation: continuation
                ))
                // Cleanup may precede registration; this actor-local recheck
                // shares the same exactly-once removal with the cleanup Task.
                if cancellation.isCancelled {
                    self.cancelWaiter(runID: run.id, waiterID: waiterID)
                }
            }
            return withExtendedLifetime(host) { result }
        }, onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.cancelWaiter(runID: run.id, waiterID: waiterID)
            }
        })
    }

    private func cancelWaiter(runID: UInt64, waiterID: UInt64) {
        guard var runWaiters = waiters[runID],
              let index = runWaiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = runWaiters.remove(at: index)
        if runWaiters.isEmpty {
            waiters.removeValue(forKey: runID)
        } else {
            waiters[runID] = runWaiters
        }
        waiter.continuation.resume(returning: .cancelled)
    }

    private func complete(
        _ run: Run, result: DemandVideoLanePreparationResult, host: any WarmPreparationTransactionHost
    ) {
        host.applyWarmPreparationNotice(.primaryReturned(run, result))
        ledger.recordPrimaryReturn(runID: run.id)
        if settledResults[run.id] == nil {
            settledResults[run.id] = result
            resolveWaiters(runID: run.id, result: result)
        }
        guard ledger.currentRun?.id == run.id else {
            clearOrphanIfReturned(runID: run.id, host: host)
            return
        }
        primaryTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        ledger.clearCurrentRun()
        host.applyWarmPreparationNotice(.currentRunReleased)
        settledResults.removeValue(forKey: run.id)
        clearOrphanIfReturned(runID: run.id, host: host)
        host.applyWarmPreparationNotice(.supplyRestartOpportunity)
    }

    private func resolveWaiters(runID: UInt64, result: DemandVideoLanePreparationResult) {
        let runWaiters = waiters.removeValue(forKey: runID) ?? []
        for waiter in runWaiters {
            waiter.continuation.resume(returning: waiter.cancellation.isCancelled ? .cancelled : result)
        }
    }

    private func timeout(_ run: Run, host: any WarmPreparationTransactionHost) {
        guard ledger.currentRun?.id == run.id, settledResults[run.id] == nil else { return }
        host.applyWarmPreparationNotice(.timeoutObserved(run))
        if policy(for: run).remaining(at: .now) > .zero,
           host.consumeWarmVideoPreparationProgress(for: run) {
            timeoutExtensionCount &+= 1
            diagnostics.log(
                "[PathA][continuation] video preparation deadline extended " +
                    "(fresh current output frontier) run=\(run.id) " +
                    "token=\(run.token.generation) extension=\(timeoutExtensionCount)"
            )
            deadlineTask = Task { @MainActor [weak self, weak host] in
                guard let self, let host else { return }
                do {
                    try await Task.sleep(for: self.policy(for: run).watchdogDelay(at: .now))
                } catch {
                    return
                }
                self.timeout(run, host: host)
            }
            return
        }
        host.applyWarmPreparationNotice(.timeoutWillSettle(run))
        timeoutCount &+= 1
        settledResults[run.id] = .failed(.warmPreparationTimedOut)
        host.applyWarmPreparationNotice(.timeoutResultStored)
        ledger.parkTimedOutRun(run)
        orphanCount = 1
        primaryTask?.cancel()
        resolveWaiters(runID: run.id, result: .failed(.warmPreparationTimedOut))
        requestInterrupt(for: run, host: host)
        diagnostics.log(
            "[PathA][continuation] video preparation deadline exceeded " +
                "run=\(run.id) token=\(run.token.generation)"
        )
    }

    private func requestInterrupt(for run: Run, host: any WarmPreparationTransactionHost) {
        guard ledger.beginInterrupt(for: run) else { return }
        let operation = host.captureWarmPreparationInterrupt()
        interruptTask = Task { @MainActor [weak self, weak host] in
            let acknowledgement = await operation()
            guard let self, let host else { return }
            self.lastInterruptResult = acknowledgement
            self.ledger.recordInterruptReturn(runID: run.id)
            self.interruptTask = nil
            self.diagnostics.log(
                "[PathA][continuation] warm preparation interrupt " +
                    "run=\(run.id) result=\(acknowledgement.rawValue)"
            )
            self.clearOrphanIfReturned(runID: run.id, host: host)
        }
    }

    private func clearOrphanIfReturned(runID: UInt64, host: any WarmPreparationTransactionHost) {
        guard ledger.clearReturnedOrphan(runID: runID) else { return }
        orphanCount = 0
        if ledger.currentRun?.id == runID {
            ledger.clearCurrentRun()
            host.applyWarmPreparationNotice(.matchingOrphanRunReleased)
        }
        settledResults.removeValue(forKey: runID)
        host.applyWarmPreparationNotice(.supplyRestartOpportunity)
    }

    private func cancelAllWaiters() {
        let allWaiters = waiters.values.flatMap { $0 }
        waiters.removeAll(keepingCapacity: false)
        for waiter in allWaiters {
            waiter.continuation.resume(returning: .cancelled)
        }
    }
}
