import QuartzCore

/// Scoped main-thread cost spans for the Diagnostic Logging meter, for bodies
/// that cannot be wrapped in `UIHitchMonitor.measure` (early returns, `guard`
/// exits): `let span = beginSpan(k); defer { endSpan(span) }`.
///
/// Each completed span adds one count under `key` (the `bodies[…]` entry), its
/// microseconds under the same key in `us[…]`, and one count under `key>4ms`
/// when it alone spans a quarter of a 60Hz frame. Spans may nest and each
/// reports inclusive time. Costs one lock acquisition when metering is off.
extension UIHitchMonitor {
    /// Caller-scoped frame cost, independent of the reporting window. The span
    /// describes its actual width: a fullscreen interval opens at tap and closes
    /// on a later summary flush, so it is aligned to the event, not bounded by
    /// the transition's animation. Interrupted intervals return nil instead.
    struct FrameInterval: Sendable, Equatable {
        let missed: Int
        let stalls: Int
        let worstMilliseconds: Int
        let spanMilliseconds: Int
        /// Long gaps crossing the opening edge are excluded from this interval.
        let boundaryGaps: Int
    }

    /// One open interval's frame accumulator.
    struct FrameIntervalState {
        let startedAt: CFTimeInterval
        var missed = 0
        var stalls = 0
        var worstMilliseconds = 0
        var boundaryGaps = 0
    }

    /// One open span. It names the epoch it started in, so work that straddles
    /// an authority boundary is dropped rather than attributed.
    struct Span: Sendable {
        fileprivate let key: String
        fileprivate let epoch: UInt64
        fileprivate let start: CFTimeInterval
        fileprivate static let slowMicros = 4_000
    }

    nonisolated static func beginSpan(_ key: String) -> Span? { sharedMeter.beginSpan(key) }

    nonisolated static func endSpan(_ span: Span?) { sharedMeter.endSpan(span) }

    /// `beginSpan`/`endSpan` around a closure, for ViewBuilder bodies.
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
        // Emit after releasing the meter lock. Individual wall times expose
        // outliers hidden by a 2s sum; nested spans remain inclusive.
        if accepted, micros >= UIHitchMonitor.Span.slowMicros {
            PlayerLog.log(
                "[MainCost] key=\(span.key) us=\(micros) "
                    + "endUptime=\(String(format: "%.6f", now)) inclusive=1"
            )
        }
    }
}
