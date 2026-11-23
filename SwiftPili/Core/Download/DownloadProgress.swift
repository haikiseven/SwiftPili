import Foundation

enum DownloadStage: String, Sendable, Equatable, Hashable {
    case video
    case audio
}

struct DownloadTransferEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case candidateStarted
        case progress
    }

    let operationToken: UUID
    let stage: DownloadStage
    let stageGeneration: UInt64
    let candidateGeneration: UInt64
    let taskIdentifier: Int
    let sequence: UInt64
    let bytesTransferred: Int64
    let expectedBytes: Int64?
    let kind: Kind
}

struct DownloadProgressEventCoalescer: Sendable {
    static let defaultMinimumInterval: TimeInterval = 0.25

    let minimumInterval: TimeInterval
    private(set) var lastEmissionTime: TimeInterval?
    private(set) var pendingEvent: DownloadTransferEvent?

    init(minimumInterval: TimeInterval = Self.defaultMinimumInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func beginCandidate(_ event: DownloadTransferEvent) -> DownloadTransferEvent {
        let timestamp = ProcessInfo.processInfo.systemUptime
        pendingEvent = nil
        lastEmissionTime = timestamp.isFinite ? timestamp : nil
        return event
    }

    mutating func offer(_ event: DownloadTransferEvent) -> DownloadTransferEvent? {
        guard event.kind == .progress else {
            return beginCandidate(event)
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard minimumInterval > 0 else {
            pendingEvent = nil
            lastEmissionTime = timestamp.isFinite ? timestamp : nil
            return event
        }
        guard let lastEmissionTime,
              timestamp.isFinite,
              lastEmissionTime.isFinite,
              timestamp >= lastEmissionTime,
              timestamp - lastEmissionTime >= minimumInterval
        else {
            pendingEvent = event
            return nil
        }

        pendingEvent = nil
        self.lastEmissionTime = timestamp
        return event
    }

    mutating func flush(taskIdentifier: Int? = nil) -> DownloadTransferEvent? {
        guard let pendingEvent,
              taskIdentifier == nil || pendingEvent.taskIdentifier == taskIdentifier
        else { return nil }
        self.pendingEvent = nil
        return pendingEvent
    }

    mutating func cancel() {
        pendingEvent = nil
        lastEmissionTime = nil
    }
}

struct DownloadCallbackFence: Sendable {
    private struct StageFence: Sendable {
        var stageGeneration: UInt64
        var candidateGeneration: UInt64 = 0
        var taskIdentifier: Int?
        var lastSequence: UInt64 = 0
        var accepting = true
    }

    let operationToken: UUID
    private var stageFences: [DownloadStage: StageFence] = [:]

    init(operationToken: UUID) {
        self.operationToken = operationToken
    }

    mutating func beginStage(_ stage: DownloadStage, generation: UInt64) {
        stageFences[stage] = StageFence(stageGeneration: generation)
    }

    mutating func endStage(_ stage: DownloadStage) {
        stageFences[stage]?.accepting = false
    }

    mutating func closeAll() {
        for stage in stageFences.keys {
            stageFences[stage]?.accepting = false
        }
    }

    func candidateGeneration(for stage: DownloadStage) -> UInt64 {
        stageFences[stage]?.candidateGeneration ?? 0
    }

    func isAccepting(_ stage: DownloadStage, generation: UInt64) -> Bool {
        guard let fence = stageFences[stage] else { return false }
        return fence.accepting && fence.stageGeneration == generation
    }

    mutating func accepts(_ event: DownloadTransferEvent) -> Bool {
        guard event.operationToken == operationToken,
              var fence = stageFences[event.stage],
              fence.accepting,
              event.stageGeneration == fence.stageGeneration,
              event.sequence > fence.lastSequence,
              event.candidateGeneration >= fence.candidateGeneration
        else { return false }

        let nextTaskIdentifier: Int
        if event.candidateGeneration > fence.candidateGeneration {
            guard event.kind == .candidateStarted else { return false }
            nextTaskIdentifier = event.taskIdentifier
        } else {
            guard let taskIdentifier = fence.taskIdentifier,
                  event.taskIdentifier == taskIdentifier
            else { return false }
            nextTaskIdentifier = taskIdentifier
        }

        if event.candidateGeneration > fence.candidateGeneration {
            fence.candidateGeneration = event.candidateGeneration
            fence.taskIdentifier = nextTaskIdentifier
        }
        fence.lastSequence = event.sequence
        stageFences[event.stage] = fence
        return true
    }
}

struct DownloadProgressSnapshot: Sendable, Equatable {
    let bytesTransferred: Int64
    let expectedBytes: Int64?
    let fraction: Double?
    let speedBytesPerSecond: Double?
    let fractionIsEstimated: Bool
}

struct DownloadProgressAccumulator: Sendable {
    private static let minimumSpeedSampleInterval: TimeInterval = 0.25
    private static let maxSpeedSamples = 4

    private struct StageState: Sendable {
        var transferred: Int64 = 0
        var candidateTransferred: Int64 = 0
        var expected: Int64?
        var isRetrying = false
        var isActive = false
    }

    private var requiredStages: Set<DownloadStage>
    private var stages: [DownloadStage: StageState] = [:]
    private var knownExpected: [DownloadStage: Int64] = [:]
    private var estimatedExpected: [DownloadStage: Int64] = [:]
    private var highWaterFraction: Double?
    private var lastSampleBytes: Int64?
    private var lastSampleTime: TimeInterval?
    private var speedSamples: [Double] = []

    private(set) var snapshot: DownloadProgressSnapshot

    init(requiredStages: [DownloadStage]) {
        self.requiredStages = Set(requiredStages)
        for stage in self.requiredStages {
            stages[stage] = StageState()
        }
        snapshot = DownloadProgressSnapshot(
            bytesTransferred: 0,
            expectedBytes: nil,
            fraction: nil,
            speedBytesPerSecond: nil,
            fractionIsEstimated: false
        )
    }

    mutating func setRequiredStages(_ requiredStages: [DownloadStage]) {
        self.requiredStages = Set(requiredStages)
        for stage in self.requiredStages where stages[stage] == nil {
            stages[stage] = StageState()
        }
        refreshSnapshot()
    }

    mutating func seed(
        transferredBytes: [DownloadStage: Int64],
        expectedBytes: [DownloadStage: Int64],
        estimatedBytes: [DownloadStage: Int64]
    ) {
        for (stage, expected) in expectedBytes where expected > 0 {
            knownExpected[stage] = expected
        }
        for (stage, estimated) in estimatedBytes where estimated > 0 {
            estimatedExpected[stage] = estimated
        }
        for (stage, transferred) in transferredBytes where transferred > 0 {
            var state = stages[stage] ?? StageState()
            let clamped = max(state.transferred, transferred)
            state.transferred = clamped
            state.candidateTransferred = max(state.candidateTransferred, clamped)
            stages[stage] = state
        }
        rebaseSpeed(at: ProcessInfo.processInfo.systemUptime)
        refreshSnapshot()
    }

    mutating func beginStage(_ stage: DownloadStage) {
        var state = stages[stage] ?? StageState()
        state.candidateTransferred = state.transferred
        state.isRetrying = false
        state.isActive = true
        stages[stage] = state
        if lastSampleTime == nil {
            rebaseSpeed(at: ProcessInfo.processInfo.systemUptime)
        }
        refreshSnapshot()
    }

    mutating func beginCandidate(
        _ stage: DownloadStage,
        retrying: Bool,
        resumedFromBytes: Int64 = 0
    ) {
        let floor = max(0, resumedFromBytes)
        var state = stages[stage] ?? StageState()
        let previousCandidate = state.candidateTransferred
        state.candidateTransferred = floor
        state.transferred = max(state.transferred, floor)
        if let measured = state.expected, measured > 0 {
            knownExpected[stage] = measured
        }
        state.expected = nil
        state.isRetrying = retrying
        state.isActive = true
        stages[stage] = state

        let hasActiveSibling = stages.contains { $0.key != stage && $0.value.isActive && !$0.value.isRetrying }
        if hasActiveSibling {
            if let previousSample = lastSampleBytes {
                let delta = floor - previousCandidate
                lastSampleBytes = max(0, previousSample + delta)
            }
        } else {
            rebaseSpeed(at: ProcessInfo.processInfo.systemUptime)
        }
        refreshSnapshot()
    }

    mutating func update(
        stage: DownloadStage,
        transferredBytes: Int64,
        expectedBytes: Int64?
    ) {
        let clamped = max(0, transferredBytes)
        var state = stages[stage] ?? StageState()
        state.transferred = max(state.transferred, clamped)
        state.candidateTransferred = max(state.candidateTransferred, clamped)
        if let expectedBytes, expectedBytes > 0 {
            state.expected = expectedBytes
        }
        state.isRetrying = false
        state.isActive = true
        stages[stage] = state
        sampleSpeed(at: ProcessInfo.processInfo.systemUptime)
        refreshSnapshot()
    }

    mutating func completeStage(_ stage: DownloadStage, actualBytes: Int64) {
        let clamped = max(0, actualBytes)
        var state = stages[stage] ?? StageState()
        state.transferred = max(state.transferred, clamped)
        state.candidateTransferred = max(state.candidateTransferred, clamped)
        if clamped > 0 {
            state.expected = clamped
            knownExpected[stage] = clamped
        }
        state.isRetrying = false
        state.isActive = false
        stages[stage] = state
        sampleSpeed(at: ProcessInfo.processInfo.systemUptime)
        refreshSnapshot()
    }

    mutating func markTerminal() {
        for stage in stages.keys {
            stages[stage]?.isRetrying = false
            stages[stage]?.isActive = false
        }
        rebaseSpeed(at: ProcessInfo.processInfo.systemUptime)
        refreshSnapshot()
    }

    private mutating func rebaseSpeed(at time: TimeInterval) {
        speedSamples.removeAll(keepingCapacity: true)
        snapshot = DownloadProgressSnapshot(
            bytesTransferred: snapshot.bytesTransferred,
            expectedBytes: snapshot.expectedBytes,
            fraction: snapshot.fraction,
            speedBytesPerSecond: nil,
            fractionIsEstimated: snapshot.fractionIsEstimated
        )
        guard time.isFinite else {
            lastSampleBytes = nil
            lastSampleTime = nil
            return
        }
        lastSampleBytes = totalSpeedTransferred
        lastSampleTime = time
    }

    private mutating func sampleSpeed(at time: TimeInterval) {
        let bytes = totalSpeedTransferred
        guard time.isFinite else {
            rebaseSpeed(at: time)
            return
        }
        guard let previousBytes = lastSampleBytes,
              let previousTime = lastSampleTime
        else {
            lastSampleBytes = bytes
            lastSampleTime = time
            return
        }

        let elapsed = time - previousTime
        let delta = bytes - previousBytes
        guard elapsed.isFinite, elapsed >= 0, delta >= 0 else {
            rebaseSpeed(at: time)
            return
        }
        guard elapsed >= Self.minimumSpeedSampleInterval else {
            return
        }
        let rate = Double(delta) / elapsed
        guard rate.isFinite, rate >= 0 else {
            rebaseSpeed(at: time)
            return
        }

        speedSamples.append(rate)
        if speedSamples.count > Self.maxSpeedSamples { speedSamples.removeFirst() }
        lastSampleBytes = bytes
        lastSampleTime = time
    }

    private var totalTransferred: Int64 {
        stages.values.reduce(into: Int64(0)) { total, stage in
            let (sum, overflow) = total.addingReportingOverflow(stage.transferred)
            total = overflow ? Int64.max : sum
        }
    }

    private var totalSpeedTransferred: Int64 {
        stages.values.reduce(into: Int64(0)) { total, stage in
            let (sum, overflow) = total.addingReportingOverflow(stage.candidateTransferred)
            total = overflow ? Int64.max : sum
        }
    }

    private func expected(_ stage: DownloadStage) -> (bytes: Int64, isEstimated: Bool)? {
        if let stated = stages[stage]?.expected, stated > 0 { return (stated, false) }
        if let known = knownExpected[stage], known > 0 { return (known, false) }
        if let estimated = estimatedExpected[stage], estimated > 0 { return (estimated, true) }
        return nil
    }

    private var totalExpected: (bytes: Int64, isEstimated: Bool)? {
        guard !requiredStages.isEmpty else { return nil }
        var total: Int64 = 0
        var isEstimated = false
        for stage in requiredStages {
            guard let contribution = expected(stage) else { return nil }
            isEstimated = isEstimated || contribution.isEstimated
            let (sum, overflow) = total.addingReportingOverflow(contribution.bytes)
            total = overflow ? Int64.max : sum
        }
        return (total, isEstimated)
    }

    private var isAllActiveRetrying: Bool {
        let active = stages.values.filter(\.isActive)
        guard !active.isEmpty else { return false }
        return active.allSatisfy(\.isRetrying)
    }

    private mutating func refreshSnapshot() {
        let expected = totalExpected
        var fraction: Double?
        var fractionIsEstimated = false
        if !isAllActiveRetrying, let expected, expected.bytes > 0 {
            let raw = min(max(Double(totalTransferred) / Double(expected.bytes), 0), 1)
            highWaterFraction = max(highWaterFraction ?? 0, raw)
            fraction = highWaterFraction
            fractionIsEstimated = expected.isEstimated
        }
        let speed: Double?
        if speedSamples.isEmpty {
            speed = nil
        } else {
            let average = speedSamples.reduce(0, +) / Double(speedSamples.count)
            speed = average.isFinite && average >= 0 ? average : nil
        }
        snapshot = DownloadProgressSnapshot(
            bytesTransferred: totalTransferred,
            expectedBytes: expected?.bytes,
            fraction: fraction,
            speedBytesPerSecond: speed,
            fractionIsEstimated: fractionIsEstimated
        )
    }
}
