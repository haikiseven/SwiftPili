import Foundation

struct WarmVideoRecoveryPolicy {
    let startedAt: ContinuousClock.Instant
    let progressWindow: Duration
    let directWindow: Duration
    private(set) var rescueUsed = false
    private var baseline: WarmVideoPreparationLedger.Observation?

    init(startedAt: ContinuousClock.Instant, progressWindow: Duration, directWindow: Duration) {
        self.startedAt = startedAt
        self.progressWindow = progressWindow
        self.directWindow = directWindow
    }

    func remaining(at now: ContinuousClock.Instant) -> Duration {
        max(.zero, progressWindow + directWindow - startedAt.duration(to: now))
    }

    func watchdogDelay(at now: ContinuousClock.Instant) -> Duration {
        min(progressWindow, remaining(at: now))
    }

    mutating func needsForwardRescue(
        observation: WarmVideoPreparationLedger.Observation?,
        epsilon: TimeInterval
    ) -> Bool {
        guard let observation, let debt = observation.debt else { return false }
        guard let previous = baseline,
              previous.attempt == observation.attempt,
              previous.decoderIdentity == observation.decoderIdentity else {
            baseline = observation
            return false
        }
        guard observation.id > previous.id,
              previous.observedAt.duration(to: observation.observedAt) >= progressWindow,
              let previousDebt = previous.debt else { return false }
        if debt > epsilon, previousDebt - debt <= epsilon {
            return true
        }
        baseline = observation
        return false
    }

    mutating func claimRescue() -> Bool {
        guard !rescueUsed else { return false }
        rescueUsed = true
        baseline = nil
        return true
    }
}
