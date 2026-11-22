import Foundation

enum DeliveryHealthSample {
    enum Verdict: Equatable {
        case healthy
        case unhealthy(severe: Bool)
    }

    static let demandMargin = 1.2
    static let runwayCeiling: TimeInterval = 20
    static let runwayFloor: TimeInterval = 3
    static let recoveryTolerance: TimeInterval = 0.5

    static func verdict(
        goodput: Double,
        requiredBps: Double,
        runway: TimeInterval,
        lastRunway: TimeInterval
    ) -> Verdict {
        guard goodput < requiredBps * demandMargin,
              runway < runwayCeiling,
              runway <= lastRunway + recoveryTolerance else { return .healthy }
        guard runway < runwayFloor else { return .healthy }
        return .unhealthy(severe: goodput < requiredBps)
    }
}
