import Foundation

struct WarmVideoPreparationRunLedger {
    struct Run: Equatable {
        let id: UInt64
        let token: DemandVideoSuspendToken
        let sessionGeneration: UInt64
        let engineGeneration: Int
        let ownerGeneration: UInt64
        let startedAt: ContinuousClock.Instant
    }

    struct Orphan {
        let runID: UInt64
        let engineGeneration: Int
        let failure: DemandPresentationFailure
    }

    private var nextRunID: UInt64 = 0
    private(set) var currentRun: Run?
    private(set) var orphan: Orphan?
    private var pendingInterruptRunID: UInt64?
    private var interruptRequestedRunID: UInt64?
    private var primaryReturnedRunID: UInt64?
    private var interruptReturnedRunID: UInt64?

    var hasPendingInterrupt: Bool { pendingInterruptRunID != nil }

    mutating func allocateRunID() -> UInt64 {
        nextRunID &+= 1
        if nextRunID == 0 { nextRunID = 1 }
        return nextRunID
    }

    mutating func activate(_ run: Run) {
        currentRun = run
    }

    mutating func clearCurrentRun() {
        currentRun = nil
    }

    mutating func recordPrimaryReturn(runID: UInt64) {
        primaryReturnedRunID = runID
    }

    mutating func parkTimedOutRun(_ run: Run) {
        orphan = Orphan(
            runID: run.id, engineGeneration: run.engineGeneration,
            failure: .warmPreparationTimedOut
        )
        primaryReturnedRunID = nil
        interruptReturnedRunID = nil
    }

    mutating func parkRetiredRun(_ run: Run) {
        let sameOrphan = orphan?.runID == run.id
        orphan = Orphan(
            runID: run.id, engineGeneration: run.engineGeneration, failure: .retired
        )
        primaryReturnedRunID = nil
        if !sameOrphan {
            interruptReturnedRunID = nil
            interruptRequestedRunID = nil
        }
    }

    mutating func beginInterrupt(for run: Run) -> Bool {
        guard pendingInterruptRunID == nil,
              interruptRequestedRunID != run.id,
              interruptReturnedRunID != run.id else { return false }
        if let orphan, orphan.runID != run.id { return false }
        interruptRequestedRunID = run.id
        pendingInterruptRunID = run.id
        return true
    }

    mutating func recordInterruptReturn(runID: UInt64) {
        pendingInterruptRunID = nil
        interruptReturnedRunID = runID
    }

    mutating func clearReturnedOrphan(runID: UInt64) -> Bool {
        guard orphan?.runID == runID,
              pendingInterruptRunID == nil,
              primaryReturnedRunID == runID,
              interruptReturnedRunID == runID else { return false }
        orphan = nil
        primaryReturnedRunID = nil
        interruptReturnedRunID = nil
        interruptRequestedRunID = nil
        return true
    }
}
