import Foundation

/// Synchronous value bookkeeping for one session's warm decode attempts.
/// Runtime admission and decoder/task ownership remain with MediaEngineSession.
struct WarmVideoPreparationLedger {
    /// Scalar snapshot supplied by the session at the existing admission point.
    struct Admission {
        let runID: UInt64
        let token: DemandVideoSuspendToken
        let sessionGeneration: UInt64
        let engineGeneration: Int
        let ownerGeneration: UInt64
        let target: TimeInterval
    }

    struct Attempt: Equatable {
        let id: UInt64
        /// The run this rung belongs to. Ownership is keyed here, not on the
        /// token, which is shared across runs of the same suspension.
        let runID: UInt64
        let token: DemandVideoSuspendToken
        let sessionGeneration: UInt64
        let engineGeneration: Int
        let ownerGeneration: UInt64
        let target: TimeInterval
    }

    /// One current decoder's advancing finite PTS frontier. The deadline
    /// consumes each observation once; old output is not perpetual liveness.
    struct Observation {
        let attempt: Attempt
        let decoderIdentity: ObjectIdentifier
        let frontierPTS: TimeInterval
        let id: UInt64
        let observedAt: ContinuousClock.Instant
        let floor: TimeInterval?

        var debt: TimeInterval? {
            guard let floor else { return nil }
            let debt = floor - frontierPTS
            return debt.isFinite ? max(0, debt) : nil
        }
    }

    private struct Progress {
        var observation: Observation
        var consumedObservationID: UInt64
    }

    private var nextAttemptID: UInt64 = 0
    private(set) var currentAttempt: Attempt?
    private var progress: Progress?

    var observation: Observation? { progress?.observation }

    mutating func beginAttempt(_ admission: Admission) -> Attempt {
        nextAttemptID &+= 1
        if nextAttemptID == 0 {
            nextAttemptID = 1
        }
        let attempt = Attempt(
            id: nextAttemptID,
            runID: admission.runID,
            token: admission.token,
            sessionGeneration: admission.sessionGeneration,
            engineGeneration: admission.engineGeneration,
            ownerGeneration: admission.ownerGeneration,
            target: admission.target
        )
        currentAttempt = attempt
        clearProgress()
        return attempt
    }

    mutating func retireAttempt() {
        currentAttempt = nil
        clearProgress()
    }

    mutating func clearProgress() {
        progress = nil
    }

    /// The session admits the output and supplies its finite frame frontier.
    mutating func observe(
        frontier: TimeInterval,
        attempt: Attempt,
        decoderIdentity: ObjectIdentifier,
        floor: TimeInterval?,
        observedAt: ContinuousClock.Instant
    ) {
        guard var progress,
              progress.observation.attempt == attempt,
              progress.observation.decoderIdentity == decoderIdentity else {
            self.progress = Progress(
                observation: Observation(
                    attempt: attempt, decoderIdentity: decoderIdentity,
                    frontierPTS: frontier, id: 1, observedAt: observedAt, floor: floor
                ),
                consumedObservationID: 0
            )
            return
        }
        guard frontier > progress.observation.frontierPTS else { return }
        let next = progress.observation.id.addingReportingOverflow(1)
        guard !next.overflow else { return }
        progress.observation = Observation(
            attempt: attempt, decoderIdentity: decoderIdentity,
            frontierPTS: frontier, id: next.partialValue, observedAt: observedAt, floor: floor
        )
        self.progress = progress
    }

    /// Runtime currentness is checked by the session before consuming a witness.
    mutating func consume(attempt: Attempt, decoderIdentity: ObjectIdentifier) -> Bool {
        guard var progress,
              progress.observation.attempt == attempt,
              progress.observation.decoderIdentity == decoderIdentity,
              progress.observation.id > progress.consumedObservationID else { return false }
        progress.consumedObservationID = progress.observation.id
        self.progress = progress
        return true
    }
}
