import Foundation

enum SeekTargetAdmission {
    static func admissibleTarget(
        requested: TimeInterval,
        duration: TimeInterval,
        reserve: TimeInterval
    ) -> TimeInterval {
        let floor = requested.isFinite ? max(0, requested) : 0
        guard duration.isFinite, duration > 0 else { return floor }
        let safeReserve = reserve.isFinite ? max(0, reserve) : 0
        let ceiling = max(0, duration - safeReserve)
        return min(floor, ceiling)
    }

    static func wasClamped(
        requested: TimeInterval,
        admitted: TimeInterval
    ) -> Bool {
        guard requested.isFinite else { return true }
        return admitted < requested - 1e-6
    }
}
