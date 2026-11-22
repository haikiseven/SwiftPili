import Foundation

struct MediaSourcePrimaryObservation: Sendable {
    let budgetID: UUID
    let issueID: UUID
    let observationEpoch: UInt64
    let track: MediaTrackKind
    let issuedAt: TimeInterval
    let range: Range<Int64>?
}

struct MediaSourceAcceptedAU: Sendable {
    let observation: MediaSourcePrimaryObservation
    let pts: TimeInterval
    let payloadBytes: Int
}

final class MediaSourceWaitBudget: @unchecked Sendable {
    enum Change: Sendable {
        case deadline(TimeInterval)
        case cancelled
    }

    private struct PrimaryIssue {
        let id: UUID
        let issuedAt: TimeInterval
        let range: Range<Int64>?
        var delivered = false
    }

    private final class State: @unchecked Sendable {
        let id = UUID()
        let observationEpoch: UInt64
        let lock = NSLock()
        var deadline: TimeInterval
        var cancelled = false
        var observers: [UUID: @Sendable (Change) -> Void] = [:]
        var issues: [MediaTrackKind: [UUID: PrimaryIssue]] = [:]

        init(deadline: TimeInterval, observationEpoch: UInt64) {
            self.deadline = deadline
            self.observationEpoch = observationEpoch
        }
    }

    private let state: State
    private let track: MediaTrackKind

    init(
        reserve: TimeInterval, rate: Float,
        sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        usefulLatency: TimeInterval = 0, observationEpoch: UInt64 = 0
    ) {
        state = State(deadline: Self.limit(
            reserve: reserve, rate: rate, sampledAt: sampledAt, usefulLatency: usefulLatency
        ), observationEpoch: observationEpoch)
        track = .video
    }

    private init(state: State, track: MediaTrackKind) {
        self.state = state
        self.track = track
    }

    var id: UUID { state.id }
    var deadline: TimeInterval {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.deadline
    }
    var isCancelled: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.cancelled
    }

    func forTrack(_ track: MediaTrackKind) -> MediaSourceWaitBudget {
        MediaSourceWaitBudget(state: state, track: track)
    }

    @discardableResult
    func observe(_ callback: @escaping @Sendable (Change) -> Void) -> UUID {
        let token = UUID()
        state.lock.lock()
        let change: Change = state.cancelled ? .cancelled : .deadline(state.deadline)
        if !state.cancelled { state.observers[token] = callback }
        state.lock.unlock()
        callback(change)
        return token
    }

    func removeObserver(_ token: UUID) {
        state.lock.lock()
        state.observers[token] = nil
        state.lock.unlock()
    }

    func tighten(
        reserve: TimeInterval, rate: Float,
        sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        usefulLatency: TimeInterval = 0
    ) {
        let proposed = Self.limit(
            reserve: reserve, rate: rate, sampledAt: sampledAt, usefulLatency: usefulLatency
        )
        state.lock.lock()
        guard !state.cancelled, proposed < state.deadline else {
            state.lock.unlock()
            return
        }
        state.deadline = proposed
        let callbacks = Array(state.observers.values)
        state.lock.unlock()
        for callback in callbacks { callback(.deadline(proposed)) }
    }

    func cancel() {
        state.lock.lock()
        guard !state.cancelled else { state.lock.unlock(); return }
        state.cancelled = true
        state.issues.removeAll()
        let callbacks = Array(state.observers.values)
        state.observers.removeAll()
        state.lock.unlock()
        for callback in callbacks { callback(.cancelled) }
    }

    @discardableResult
    func notePrimaryRequest(range: Range<Int64>? = nil) -> UUID {
        let token = UUID()
        state.lock.lock()
        if !state.cancelled {
            state.issues[track, default: [:]][token] = PrimaryIssue(
                id: token, issuedAt: ProcessInfo.processInfo.systemUptime, range: range
            )
        }
        state.lock.unlock()
        return token
    }

    func notePrimaryDelivery(_ token: UUID) {
        state.lock.lock()
        if !state.cancelled, state.issues[track]?[token] != nil {
            state.issues[track]?[token]?.delivered = true
        }
        state.lock.unlock()
    }

    func takePrimaryObservation() -> MediaSourcePrimaryObservation? {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.cancelled,
              let issue = state.issues[track]?.values.filter(\.delivered)
                .min(by: { $0.issuedAt < $1.issuedAt }) else { return nil }
        state.issues[track]?[issue.id] = nil
        return MediaSourcePrimaryObservation(
            budgetID: id, issueID: issue.id, observationEpoch: state.observationEpoch,
            track: track, issuedAt: issue.issuedAt, range: issue.range
        )
    }

    private static func limit(
        reserve: TimeInterval, rate: Float, sampledAt: TimeInterval, usefulLatency: TimeInterval
    ) -> TimeInterval {
        guard reserve.isFinite, reserve >= 0, rate.isFinite, rate > 0,
              sampledAt.isFinite, usefulLatency.isFinite, usefulLatency >= 0 else {
            return sampledAt.isFinite ? sampledAt : 0
        }
        return sampledAt + max(0, reserve / Double(rate) - usefulLatency)
    }
}
