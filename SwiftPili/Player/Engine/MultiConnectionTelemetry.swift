import Foundation

/// Read-only helper payload statistics. No URLs, packet-ingest goodput or socket counts.
struct MultiConnectionTelemetry: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case unsupported, pending, notConfigured, unavailable, idle, downloading, quiet, parked, suppressed
        case coolingDown, networkRestricted
    }
    var identity: UUID?
    var epoch: UInt64 = 0
    var observedAt: TimeInterval = 0
    var state: State = .unsupported
    var activeRequests = 0
    var concurrencyLimit = MultiConnectionPlanner.requestLimit()
    /// Auto ladder level (fixed mode: the request limit). Telemetry only; no UI row.
    var level = MultiConnectionPlanner.requestLimit()
    var activeHelperHosts: [String] = []
    var candidateHosts = 0
    var completedBytes: Int64 = 0
    var completedFragments = 0
    var stagedBytes: Int64 = 0
    var discardedBytes: Int64 = 0
    static let unsupported = Self()
}

/// Rates measure completed validated pieces, excluding partial/failed bodies.
struct MultiConnectionPayloadSampler {
    private var previous: MultiConnectionTelemetry?
    mutating func reset() { previous = nil }
    mutating func sample(_ value: MultiConnectionTelemetry) -> Double? {
        guard value.identity != nil, value.state == .idle || value.state == .downloading else {
            reset()
            return nil
        }
        let last = previous
        previous = value
        guard let last, last.identity == value.identity, last.epoch == value.epoch,
              value.completedBytes >= last.completedBytes,
              value.observedAt.isFinite, last.observedAt.isFinite,
              value.observedAt > last.observedAt else { return nil }
        let rate = Double(value.completedBytes - last.completedBytes) / (value.observedAt - last.observedAt)
        return rate.isFinite ? rate : nil
    }
}

/// A blocked query occupies one slot even after invalidation; it cannot pile up.
@MainActor
final class MultiConnectionTelemetryRefresh {
    private(set) var value = MultiConnectionTelemetry.unsupported
    private var epoch: UInt64 = 0
    private(set) var inFlight = false

    func invalidate(_ state: MultiConnectionTelemetry.State = .unsupported) {
        epoch &+= 1
        value = MultiConnectionTelemetry(state: state)
    }

    func invalidateKeepingValue() { epoch &+= 1 }

    func request(
        generation: Int,
        currentGeneration: @escaping @MainActor () -> Int,
        query: @escaping @Sendable () async -> MultiConnectionTelemetry
    ) {
        guard !inFlight, generation == currentGeneration() else { return }
        inFlight = true
        let fence = epoch
        Task { [weak self] in
            let result = await query()
            guard let self else { return }
            self.inFlight = false
            guard self.epoch == fence, generation == currentGeneration() else { return }
            self.value = result
        }
    }
}
