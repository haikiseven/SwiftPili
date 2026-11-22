import Foundation

/// Saturation-gated trial ladder for the number of concurrent helper range
/// requests (design §3). Pure value type: the prefetcher passes `now`, so no
/// decision reads a clock. Supply below demand can only waive the cooldown or
/// extend an inconclusive trial; the level falls only on a no-gain verdict or
/// on the refusal class (user correction 2026-10-04: priority, not throttling).
struct MultiConnectionConcurrencyController: Sendable {
    struct Tunables: Sendable, Equatable {
        var saturationFraction = 0.6
        var minRelativeGain = 0.10
        var settleMax: TimeInterval = 2
        var minWindow: TimeInterval = 1.5
        var maxWindow: TimeInterval = 4
        var maxExtensions = 2
        var restDuration: TimeInterval = 60
        var restMax: TimeInterval = 300
        var hardRest: TimeInterval = 300
        var hardRestMax: TimeInterval = 1800
        var pruneRatio = 0.25
        var pruneDuration: TimeInterval = 60
        var pruneMinimumEdges = 3
        var topTierRatio = 0.5
        var resetStormCount = 3
        var resetStormEdges = 2
        var resetStormWindow: TimeInterval = 5
        /// One refusal EVENT (§3.6): every in-flight piece of a risk-control
        /// burst fails within this span of the first, and counts once.
        var refusalEventWindow: TimeInterval = 5
    }

    enum Decision: Equatable, Sendable {
        case stepUp(from: Int, target: Int, saturation: Double, base: Double)
        case keep(level: Int, base: Double, trial: Double, saturation: Double)
        case stepBack(from: Int, target: Int, base: Double, trial: Double, saturation: Double, restFor: TimeInterval)
        case inconclusive(level: Int, saturation: Double)
        case hardRest(from: Int, target: Int, ceiling: Int, restFor: TimeInterval)
    }

    enum Phase: Equatable, Sendable {
        case holding
        case settling(since: TimeInterval, completions: Int)
        case trial(extensions: Int)
    }

    /// One observation edge (launch / finish / fail / defer).
    struct Observation: Sendable {
        /// `active >= level` and an admissible range was waiting for a slot.
        var saturated: Bool
        /// Read-ahead short of the Preload horizon / byte budget.
        var backlog: Bool
        /// The player waited on, or took over, prefetched work; or the nearest
        /// Work is projected late. Raise-only (§3.5).
        var behind: Bool
        /// Requests the admitted edges can carry (`edges × edgeBound`).
        var capacity: Int
    }

    struct Edge: Sendable, Equatable {
        let key: String
        /// Per-request completed-payload EWMA, bytes/s.
        let rate: Double?
        let samples: Int
        /// Successful piece identities before remote coalescing; a membership
        /// change or a second track must not manufacture a fresh observation.
        var observations: [String: Int] = [:]
        /// Optional per-edge slot cap (e.g. 1 for an untested Tier 2 synthetic mirror).
        var maxSlots: Int?

        var sampleIdentities: [String: Int] { observations.isEmpty ? [key: samples] : observations }
    }

    struct Pruned: Sendable, Equatable {
        let key: String
        let rate: Double
        let median: Double
    }

    struct Allocation: Sendable, Equatable {
        var slots: [String: Int] = [:]
        var topTier: Set<String> = []
        /// Admitted (unpruned) edges, best effective rate first.
        var ranked: [String] = []
        /// Per-request EWMA of each admitted edge that has completed a piece.
        var measured: [String: Double] = [:]
        var newlyPruned: [Pruned] = []
        var prunedCount = 0
        /// One ordinary Work opportunity; rank-zero admission remains G4.
        var recoveryKey: String?
        var capacity: Int { slots.values.reduce(0, +) }
    }

    let policy: MultiConnectionPolicy
    let tunables: Tunables
    private(set) var level: Int
    private(set) var phase: Phase = .holding
    private(set) var baseline: Double?
    private(set) var memo: MultiConnectionLadderMemo.Entry
    private(set) var lastSaturation = 0.0
    private var previousLevel: Int?
    private var windowStart: TimeInterval
    private var windowBytes: Int64 = 0
    private var saturatedTime: TimeInterval = 0
    private var lastEventAt: TimeInterval
    private var current = Observation(saturated: false, backlog: false, behind: false, capacity: 0)
    private var pieceSeconds: [TimeInterval] = []
    private var rests: [Int: (until: TimeInterval, count: Int)] = [:]
    private var resets: [(at: TimeInterval, edge: String)] = []
    private var pruning = MultiConnectionPruneRecovery()
    /// Start of the refusal event currently being absorbed (§3.6).
    private var refusalEventAt: TimeInterval?

    init(
        policy: MultiConnectionPolicy, memo: MultiConnectionLadderMemo.Entry = .init(),
        now: TimeInterval, tunables: Tunables = .init()
    ) {
        self.policy = policy
        self.tunables = tunables
        self.memo = memo
        windowStart = now
        lastEventAt = now
        let levels = policy.levels.isEmpty ? [max(1, policy.totalBound)] : policy.levels
        var start = policy.auto ? (memo.level ?? policy.startLevel) : policy.startLevel
        if policy.auto, let ceiling = memo.activeCeiling(now: now) { start = min(start, ceiling) }
        if policy.auto {
            start = levels.last { $0 <= start } ?? levels[0]
        }
        level = start
    }

    var windowLength: TimeInterval {
        guard !pieceSeconds.isEmpty else { return min(tunables.maxWindow, max(tunables.minWindow, 2)) }
        let sorted = pieceSeconds.sorted()
        return min(tunables.maxWindow, max(tunables.minWindow, 2 * sorted[sorted.count / 2]))
    }

    /// Highest level any rule currently permits.
    func ceiling(now: TimeInterval, capacity: Int) -> Int {
        var value = min(policy.totalBound, max(capacity, policy.levels.first ?? 1))
        if let hard = memo.activeCeiling(now: now) { value = min(value, hard) }
        for (rested, rest) in rests where rest.until > now {
            value = min(value, policy.levels.last { $0 < rested } ?? (policy.levels.first ?? 1))
        }
        return value
    }

    func nextLevel(now: TimeInterval, capacity: Int) -> Int? {
        let limit = ceiling(now: now, capacity: capacity)
        return policy.levels.first { $0 > level && $0 <= limit }
    }

    // MARK: - Observations

    mutating func noteCompletion(bytes: Int64, seconds: TimeInterval, now: TimeInterval) {
        guard policy.auto else { return }
        integrate(now: now)
        windowBytes += max(0, bytes)
        if seconds.isFinite, seconds > 0 {
            pieceSeconds.append(seconds)
            if pieceSeconds.count > 16 { pieceSeconds.removeFirst(pieceSeconds.count - 16) }
        }
        if case .settling(let since, let completions) = phase {
            phase = .settling(since: since, completions: completions + 1)
        }
    }

    /// Restarts measurement without changing the level (seek, park, quiet).
    mutating func restartWindow(now: TimeInterval) {
        windowStart = now
        lastEventAt = now
        windowBytes = 0
        saturatedTime = 0
        if case .settling = phase { phase = .settling(since: now, completions: 0) }
    }

    /// Memory warning: drop to the start level; the caller freezes the memo.
    mutating func dropToStart(now: TimeInterval) {
        guard policy.auto else { return }
        level = policy.levels.last { $0 <= policy.startLevel } ?? (policy.levels.first ?? level)
        phase = .holding
        baseline = nil
        restartWindow(now: now)
    }

    mutating func observe(_ observation: Observation, now: TimeInterval) -> [Decision] {
        guard policy.auto else { return [] }
        integrate(now: now)
        current = observation
        var decisions: [Decision] = []
        if case .settling(let since, let completions) = phase,
           now - since >= tunables.settleMax || completions >= level {
            phase = .trial(extensions: 0)
            restartWindow(now: now)
            return decisions
        }
        let duration = now - windowStart
        guard duration >= windowLength, duration > 0 else { return decisions }
        let saturation = min(1, saturatedTime / duration)
        let rate = Double(windowBytes) / duration
        lastSaturation = saturation
        restartWindow(now: now)
        switch phase {
        case .settling:
            break
        case .holding:
            guard saturation >= tunables.saturationFraction else { break }
            baseline = rate
            if observation.backlog,
               let step = stepUp(now: now, saturation: saturation, capacity: observation.capacity) {
                decisions.append(step)
            }
        case .trial(let extensions):
            decisions += judgeTrial(extensions: extensions, saturation: saturation, rate: rate, now: now)
        }
        return decisions
    }

    private mutating func judgeTrial(
        extensions: Int, saturation: Double, rate: Double, now: TimeInterval
    ) -> [Decision] {
        guard saturation >= tunables.saturationFraction else {
            // Absence of demand is not evidence of no gain (E10).
            let used = current.behind ? extensions : extensions + 1
            phase = used > tunables.maxExtensions ? .holding : .trial(extensions: used)
            if used > tunables.maxExtensions { baseline = nil }
            return [.inconclusive(level: level, saturation: saturation)]
        }
        let base = baseline ?? 0
        // Relative tolerance only absorbs floating-point representation of the threshold.
        if rate - base >= base * tunables.minRelativeGain * (1 - 1e-9) {
            baseline = rate
            rests[level] = nil
            phase = .holding
            memo.level = level
            var decisions: [Decision] = [.keep(level: level, base: base, trial: rate, saturation: saturation)]
            // Behind waives the cooldown: the saturated trial window is enough.
            if current.behind, current.backlog,
               let step = stepUp(now: now, saturation: saturation, capacity: current.capacity) {
                decisions.append(step)
            }
            return decisions
        }
        let from = level
        let target = previousLevel ?? (policy.levels.last { $0 < from } ?? from)
        let count = (rests[from]?.count ?? 0) + 1
        let restFor = min(tunables.restMax, tunables.restDuration * pow(2, Double(count - 1)))
        rests[from] = (now + restFor, count)
        level = target
        phase = .holding
        memo.level = level
        return [.stepBack(
            from: from, target: target, base: base, trial: rate, saturation: saturation, restFor: restFor
        )]
    }

    private mutating func stepUp(now: TimeInterval, saturation: Double, capacity: Int) -> Decision? {
        guard let next = nextLevel(now: now, capacity: capacity) else { return nil }
        let from = level
        previousLevel = from
        level = next
        phase = .settling(since: now, completions: 0)
        restartWindow(now: now)
        return .stepUp(from: from, target: next, saturation: saturation, base: baseline ?? 0)
    }

    private mutating func integrate(now: TimeInterval) {
        guard now > lastEventAt else { return }
        if current.saturated { saturatedTime += now - lastEventAt }
        lastEventAt = now
    }

    // MARK: - Refusal class (§3.6)

    /// One refusal event lowers the ceiling one rung and counts one hard rest.
    /// The rest of the same burst (every other in-flight piece answered by the
    /// same risk-control edge) returns nil: the caller still penalizes its host.
    mutating func noteRefusal(now: TimeInterval) -> Decision? {
        guard policy.auto else { return nil }
        if let start = refusalEventAt, now >= start, now - start < tunables.refusalEventWindow { return nil }
        refusalEventAt = now
        let from = level
        let floor = policy.levels.first ?? from
        let ceiling = policy.levels.last { $0 < from } ?? floor
        memo.hardRestCount += 1
        let restFor = min(tunables.hardRestMax, tunables.hardRest * pow(2, Double(memo.hardRestCount - 1)))
        memo.hardRestCeiling = min(ceiling, memo.activeCeiling(now: now) ?? ceiling)
        memo.hardRestUntil = now + restFor
        level = min(level, memo.hardRestCeiling ?? ceiling)
        memo.level = level
        phase = .holding
        baseline = nil
        restartWindow(now: now)
        return .hardRest(from: from, target: level, ceiling: memo.hardRestCeiling ?? ceiling, restFor: restFor)
    }

    /// Connection lost / cannot connect / TLS failure. A storm across edges is a refusal.
    mutating func noteTransportReset(edge: String, now: TimeInterval) -> Decision? {
        guard policy.auto else { return nil }
        resets.removeAll { now - $0.at > tunables.resetStormWindow }
        resets.append((now, edge))
        guard resets.count >= tunables.resetStormCount,
              Set(resets.map(\.edge)).count >= tunables.resetStormEdges else { return nil }
        resets.removeAll()
        return noteRefusal(now: now)
    }

    // MARK: - Allocation (§3.7)

    mutating func allocate(
        edges: [Edge], explore: String? = nil, now: TimeInterval,
        retainingSamples: Set<String>? = nil, inFlight: [String: Int] = [:], recoveryEligible: Set<String>? = nil
    ) -> Allocation {
        var result = Allocation()
        result.newlyPruned = pruning.update(
            edges: edges, retainingSamples: retainingSamples, now: now, tunables: tunables
        )
        var admitted = edges.filter { !pruning.isPruned($0.key, now: now) }
        result.prunedCount = edges.count - admitted.count
        // Last-resort fallback: pruning prefers fast edges over slow ones, but if every
        // remaining non-demoted edge is pruned, admit the least-slow edge instead of stalling.
        if admitted.isEmpty, let bestPruned = edges.enumerated().max(by: { lhs, rhs in
            let leftRate = lhs.element.rate ?? 0, rightRate = rhs.element.rate ?? 0
            return leftRate != rightRate ? leftRate < rightRate : lhs.offset > rhs.offset
        })?.element {
            admitted = [bestPruned]
        }
        for edge in admitted where edge.samples > 0 { result.measured[edge.key] = edge.rate ?? 0 }
        let known = Self.median(admitted.compactMap { $0.samples > 0 ? $0.rate : nil })
        func effective(_ edge: Edge) -> Double { (edge.samples > 0 ? edge.rate : nil) ?? known ?? 0 }
        let ordered = admitted.enumerated().sorted {
            let lhs = effective($0.element), rhs = effective($1.element)
            return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
        }.map(\.element)
        result.ranked = ordered.map(\.key)
        result.recoveryKey = level >= 2
            ? pruning.opportunity(edges: ordered, eligible: recoveryEligible, inFlight: inFlight, now: now) : nil
        let normal = ordered.filter { !pruning.isRecovering($0) }
        var breadth = Array(normal.prefix(min(level, policy.hostSlots)))
        let opportunity = result.recoveryKey ?? explore
        if let opportunity, !breadth.contains(where: { $0.key == opportunity }),
           let candidate = ordered.first(where: { $0.key == opportunity }), !breadth.isEmpty, level >= 2 {
            if breadth.count < min(level, policy.hostSlots) { breadth.append(candidate) } else {
                breadth[breadth.count - 1] = candidate
            }
        }
        for edge in breadth { result.slots[edge.key] = 1 }
        distributeDepth(normal, slots: &result.slots, effective: effective)
        let best = admitted.filter { $0.samples > 0 }.compactMap(\.rate).max()
        if let best, best > 0 {
            result.topTier = Set(admitted.filter {
                $0.samples > 0 && ($0.rate ?? 0) >= tunables.topTierRatio * best
            }.map(\.key))
        } else {
            result.topTier = Set(admitted.map(\.key))
        }
        return result
    }

}

extension MultiConnectionConcurrencyController {
    /// G4 for one track's rank-0 Work: edge → request cap. The global top tier
    /// restricted to the edges that can serve the track; when none of it can,
    /// the track's own best scheduled edges by the same ratio rule; when the
    /// allocation grants the track no edge at all, one request on its best
    /// admitted edge. A track's next-needed fragment is never left without an
    /// edge while the track has an admitted one, so G3 cannot stall on it.
    func rankZeroSlots(_ allocation: Allocation, eligible: Set<String>) -> [String: Int] {
        let scheduled = eligible.filter { allocation.slots[$0, default: 0] > 0 }
        var tier = allocation.topTier.intersection(scheduled)
        if tier.isEmpty {
            let best = scheduled.compactMap { allocation.measured[$0] }.max()
            if let best, best > 0 {
                tier = scheduled.filter { (allocation.measured[$0] ?? 0) >= tunables.topTierRatio * best }
            } else {
                tier = scheduled
            }
        }
        if !tier.isEmpty {
            return Dictionary(uniqueKeysWithValues: tier.map { ($0, allocation.slots[$0, default: 0]) })
        }
        guard let fallback = allocation.ranked.first(where: eligible.contains) else { return [:] }
        return [fallback: 1]
    }

    func isPruned(_ key: String, now: TimeInterval) -> Bool { pruning.isPruned(key, now: now) }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    mutating func noteRecoveryIssued(_ edge: String, now: TimeInterval) {
        pruning.noteIssued(edge, now: now, interval: tunables.pruneDuration)
    }

    private func distributeDepth(_ normal: [Edge], slots: inout [String: Int], effective: (Edge) -> Double) {
        var remaining = level - slots.values.reduce(0, +)
        let bound = max(1, policy.edgeBound)
        while remaining > 0 {
            let pick = normal.enumerated().filter {
                let limit = min(bound, $0.element.maxSlots ?? bound)
                return (slots[$0.element.key] ?? 0) < limit
            }.min {
                let lhs = effective($0.element), rhs = effective($1.element)
                if lhs != rhs { return lhs > rhs }
                let leftLoad = slots[$0.element.key] ?? 0, rightLoad = slots[$1.element.key] ?? 0
                return leftLoad != rightLoad ? leftLoad < rightLoad : $0.offset < $1.offset
            }
            guard let pick else { break }
            slots[pick.element.key, default: 0] += 1
            remaining -= 1
        }
    }
}

/// Process-wide ladder memory keyed by network class (design §3.9): a hard
/// rest must survive the next open, and a short fill should not re-learn the
/// level from the start every time. Holds no per-host data.
final class MultiConnectionLadderMemo: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        var level: Int?
        var hardRestCeiling: Int?
        var hardRestUntil: TimeInterval = 0
        var hardRestCount = 0

        func activeCeiling(now: TimeInterval) -> Int? {
            guard let hardRestCeiling, hardRestUntil > now else { return nil }
            return hardRestCeiling
        }
    }

    static let shared = MultiConnectionLadderMemo()
    private let lock = NSLock()
    private var entries: [MultiConnectionNetworkClass: Entry] = [:]
    /// Bumped by every `reset()`. A prefetcher learns on the network it was
    /// opened on; once the App resets the memo for a new network, that
    /// prefetcher's later failures (often the old interface going away) must
    /// not land in the fresh entry.
    private var generation: UInt64 = 0

    func entry(for networkClass: MultiConnectionNetworkClass) -> Entry {
        lock.withLock { entries[networkClass] ?? Entry() }
    }

    /// The entry and the reset generation it belongs to, read atomically.
    func entryAndGeneration(for networkClass: MultiConnectionNetworkClass) -> (entry: Entry, generation: UInt64) {
        lock.withLock { (entries[networkClass] ?? Entry(), generation) }
    }

    /// Seeds an entry unconditionally (tests, fixtures).
    func store(_ entry: Entry, for networkClass: MultiConnectionNetworkClass) {
        lock.withLock { entries[networkClass] = entry }
    }

    /// Stores only while no reset has happened since `generation` was read.
    @discardableResult
    func store(_ entry: Entry, for networkClass: MultiConnectionNetworkClass, generation: UInt64) -> Bool {
        lock.withLock {
            guard generation == self.generation else { return false }
            entries[networkClass] = entry
            return true
        }
    }

    func reset() {
        lock.withLock {
            entries.removeAll()
            generation &+= 1
        }
    }
}
