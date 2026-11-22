import Foundation

struct MultiConnectionPruneRecovery: Sendable {
    private typealias Controller = MultiConnectionConcurrencyController
    private struct Observation: Sendable {
        var samples: Int
        var until: TimeInterval
        var nextOpportunity: TimeInterval
        var lastOpportunity: UInt64 = 0
    }
    private var observations: [String: Observation] = [:]
    private var excluded: [String: TimeInterval] = [:]
    private var recovering: Set<String> = []
    private var allocationIdentities: [String: Set<String>] = [:]
    private var serial: UInt64 = 0

    func isPruned(_ key: String, now: TimeInterval) -> Bool { (excluded[key] ?? 0) > now }

    func isRecovering(_ edge: MultiConnectionConcurrencyController.Edge) -> Bool {
        recovering.contains(edge.key)
    }

    func opportunity(
        edges: [MultiConnectionConcurrencyController.Edge], eligible: Set<String>?,
        inFlight: [String: Int], now: TimeInterval
    ) -> String? {
        let recovering = edges.filter(isRecovering)
        if let active = recovering.first(where: { inFlight[$0.key, default: 0] > 0 }) { return active.key }
        return recovering.filter {
            (eligible?.contains($0.key) ?? true) && evidence($0).allSatisfy { $0.nextOpportunity <= now }
        }.min {
            let lhs = evidence($0).map(\.lastOpportunity).max() ?? 0
            let rhs = evidence($1).map(\.lastOpportunity).max() ?? 0
            if lhs != rhs { return lhs < rhs }
            return (evidence($0).map(\.until).min() ?? now) < (evidence($1).map(\.until).min() ?? now)
        }?.key
    }

    mutating func noteIssued(_ edge: String, now: TimeInterval, interval: TimeInterval) {
        serial &+= 1
        for key in allocationIdentities[edge] ?? [] {
            observations[key]?.nextOpportunity = now + interval
            observations[key]?.lastOpportunity = serial
        }
    }

    mutating func update(
        edges: [MultiConnectionConcurrencyController.Edge], retainingSamples: Set<String>?,
        now: TimeInterval, tunables: MultiConnectionConcurrencyController.Tunables
    ) -> [MultiConnectionConcurrencyController.Pruned] {
        let retained = retainingSamples ?? Set(edges.flatMap { $0.sampleIdentities.keys })
        observations = observations.filter { retained.contains($0.key) }
        allocationIdentities = Dictionary(uniqueKeysWithValues: edges.map { ($0.key, Set($0.sampleIdentities.keys)) })
        excluded.removeAll(keepingCapacity: true)
        recovering.removeAll(keepingCapacity: true)
        let measured = edges.filter { $0.samples >= 2 && ($0.rate ?? 0) > 0 }
        let median = measured.count >= tunables.pruneMinimumEdges ? Controller.median(measured.compactMap(\.rate)) : nil
        var pruned: [Controller.Pruned] = []
        for edge in edges {
            let identities = edge.sampleIdentities
            let previous = evidence(edge)
            let fresh = identities.contains { key, samples in observations[key].map { samples > $0.samples } ?? false }
            let until = previous.map(\.until).max() ?? now
            let slow = edge.samples >= 2 && median.map { (edge.rate ?? 0) < tunables.pruneRatio * $0 } == true
            if slow, until <= now, previous.isEmpty || fresh {
                for (key, samples) in identities {
                    observations[key] = .init(samples: max(samples, observations[key]?.samples ?? samples),
                                              until: now + tunables.pruneDuration,
                                              nextOpportunity: now + tunables.pruneDuration)
                }
                pruned.append(.init(key: edge.key, rate: edge.rate ?? 0, median: median ?? 0))
            } else if fresh, !slow, until <= now {
                for key in identities.keys { observations[key] = nil }
            } else if !previous.isEmpty {
                for (key, samples) in identities where observations[key] == nil {
                    observations[key] = .init(samples: samples, until: until,
                                              nextOpportunity: previous.map(\.nextOpportunity).max() ?? until,
                                              lastOpportunity: previous.map(\.lastOpportunity).max() ?? 0)
                }
            }
            if let exclusion = evidence(edge).map(\.until).max(), exclusion > now { excluded[edge.key] = exclusion }
            if slow, excluded[edge.key] == nil, !evidence(edge).isEmpty { recovering.insert(edge.key) }
        }
        return pruned
    }

    private func evidence(_ edge: Controller.Edge) -> [Observation] {
        edge.sampleIdentities.keys.compactMap { observations[$0] }
    }
}
