import QuartzCore

extension UIHitchMonitor {
    struct FrameInterval: Sendable, Equatable {
        let missed: Int
        let stalls: Int
        let worstMilliseconds: Int
        let spanMilliseconds: Int
        let boundaryGaps: Int
    }

    struct FrameIntervalState {
        let startedAt: CFTimeInterval
        var missed = 0
        var stalls = 0
        var worstMilliseconds = 0
        var boundaryGaps = 0
    }

    struct Span: Sendable {
        fileprivate let key: String
        fileprivate let epoch: UInt64
        fileprivate let start: CFTimeInterval
        fileprivate static let slowMicros = 4_000
    }

    nonisolated static func beginSpan(_ key: String) -> Span? { sharedMeter.beginSpan(key) }

    nonisolated static func endSpan(_ span: Span?) { sharedMeter.endSpan(span) }

    nonisolated static func measureCounted<T>(_ key: String, _ work: () -> T) -> T {
        let span = beginSpan(key)
        defer { endSpan(span) }
        return work()
    }
}

extension UIHitchMonitor.Meter {
    nonisolated func beginSpan(
        _ key: String, now: CFTimeInterval = CACurrentMediaTime()
    ) -> UIHitchMonitor.Span? {
        lock.withLock { $0.eligible ? UIHitchMonitor.Span(key: key, epoch: $0.epoch, start: now) : nil }
    }

    nonisolated func endSpan(_ span: UIHitchMonitor.Span?, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let span else { return }
        let micros = Int((now - span.start) * 1_000_000)
        let accepted = lock.withLock { state in
            guard state.eligible, state.epoch == span.epoch else { return false }
            state.bodyCounts[span.key, default: 0] += 1
            state.totalCounts[span.key, default: 0] += 1
            state.spentMicros[span.key, default: 0] += micros
            if micros >= UIHitchMonitor.Span.slowMicros {
                let slowKey = span.key + ">4ms"
                state.bodyCounts[slowKey, default: 0] += 1
                state.totalCounts[slowKey, default: 0] += 1
            }
            return true
        }
        if accepted, micros >= UIHitchMonitor.Span.slowMicros {
            PlayerLog.log(
                "[MainCost] key=\(span.key) us=\(micros) "
                    + "endUptime=\(String(format: "%.6f", now)) inclusive=1"
            )
        }
    }
}
