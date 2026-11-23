import Foundation
import Synchronization
import os

protocol AudioSupplySource: AnyObject, Sendable {
    func pullContent(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioSupplyPull
}

struct AudioFeederPullReport: Sendable, Equatable {
    let passes: Int
    let requestedFrames: Int
    let writtenFrames: Int
    let refusedWrites: Int

    static let empty = AudioFeederPullReport(
        passes: 0, requestedFrames: 0, writtenFrames: 0, refusedWrites: 0
    )

    var isEmpty: Bool { self == .empty }
}

struct FeederStandDownReceipt: Sendable {
    let requiresJoin: Bool
    private let queue: DispatchQueue?

    init(requiresJoin: Bool, queue: DispatchQueue?) {
        self.requiresJoin = requiresJoin
        self.queue = requiresJoin ? queue : nil
    }

    func join() async {
        guard requiresJoin, let queue else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    @MainActor
    func onQuiesce(_ action: @escaping @MainActor @Sendable () -> Void) {
        guard requiresJoin, let queue else {
            action()
            return
        }
        queue.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }
    }
}

final class AudioFeederGate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: AudioFeederAdmission())

    var snapshot: AudioFeederAdmission { state.withLock { $0 } }

    @discardableResult
    func admit(slot: Int, targetFrames: Int) -> Bool {
        state.withLock { $0.admit(slot: slot, targetFrames: targetFrames) }
    }

    func standDown() -> AudioFeederAdmission.StandDown {
        state.withLock { $0.standDown() }
    }

    func setTargetFrames(_ frames: Int) {
        state.withLock { $0.setTargetFrames(frames) }
    }

    func invalidateContent() {
        state.withLock { $0.invalidateContent() }
    }

    func retire() -> AudioFeederAdmission.StandDown {
        state.withLock { $0.retire() }
    }

    func beginPass() -> AudioFeederAdmission.Pass? {
        state.withLock { $0.beginPass() }
    }

    func endPass() {
        state.withLock { $0.endPass() }
    }

    func withAdmittedPull(
        _ pass: AudioFeederAdmission.Pass,
        _ body: @Sendable () -> AudioSupplyPull
    ) -> AudioSupplyPull? {
        state.withLock { admission in
            guard admission.writeVerdict(for: pass) == nil else { return nil }
            return body()
        }
    }

    func withAdmittedWrite(
        _ pass: AudioFeederAdmission.Pass,
        _ body: @Sendable () -> Void
    ) -> AudioFeederAdmission.WriteRefusal? {
        state.withLock { admission in
            if let refusal = admission.writeVerdict(for: pass) { return refusal }
            body()
            return nil
        }
    }
}

final class AudioRingFeeder: @unchecked Sendable {
    private let queue: DispatchQueue
    private let ringRouter: PCMFloatRingRouter
    private let gate = AudioFeederGate()
    private let scratch: UnsafeMutableBufferPointer<Float>
    private let sampleRate: Double
    private let channels: Int

    private let supplyBox = OSAllocatedUnfairLock<(any AudioSupplySource)?>(initialState: nil)

    private var timer: DispatchSourceTimer?

    private let reportBox = OSAllocatedUnfairLock<AudioFeederPullReport>(initialState: .empty)
    private let totalPullCalls = Atomic<Int>(0)

    init(
        ringRouter: PCMFloatRingRouter,
        sampleRate: Double,
        channels: Int,
        maximumContentSeconds: TimeInterval
    ) {
        self.ringRouter = ringRouter
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        queue = DispatchQueue(
            label: "com.swiftpili.patha.audio-feeder",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        let capacity = max(
            self.channels,
            Int((maximumContentSeconds * sampleRate).rounded(.up)) * self.channels
        )
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0)
        scratch = buffer
    }

    deinit {
        timer?.cancel()
        scratch.deallocate()
    }

    var admission: AudioFeederAdmission { gate.snapshot }
    var pullCallCount: Int { totalPullCalls.load(ordering: .relaxed) }

    // MARK: - MainActor control surface

    func resume(supply: any AudioSupplySource, slot: Int, targetFrames: Int, period: TimeInterval) {
        guard gate.admit(slot: slot, targetFrames: targetFrames) else { return }
        supplyBox.withLock { $0 = supply }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(period, 0.005)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(2)
        )
        source.setEventHandler { [weak self] in self?.runPass() }
        timer = source
        source.activate()
    }

    func standDown() -> FeederStandDownReceipt {
        let result = gate.standDown()
        return FeederStandDownReceipt(requiresJoin: result == .mustJoin, queue: queue)
    }

    func retire() -> FeederStandDownReceipt {
        let result = gate.retire()
        timer?.cancel()
        timer = nil
        supplyBox.withLock { $0 = nil }
        return FeederStandDownReceipt(requiresJoin: result == .mustJoin, queue: queue)
    }

    func invalidateContent() {
        gate.invalidateContent()
    }

    func setTargetFrames(_ frames: Int) {
        gate.setTargetFrames(frames)
    }

    @discardableResult
    func readmit(slot: Int, targetFrames: Int) -> Bool {
        gate.admit(slot: slot, targetFrames: targetFrames)
    }

    func drainReport() -> AudioFeederPullReport {
        reportBox.withLock { report in
            let current = report
            report = .empty
            return current
        }
    }

    // MARK: - Feeder queue

    private func runPass() {
        guard let pass = gate.beginPass() else { return }
        defer { gate.endPass() }
        guard let supply = supplyBox.withLock({ $0 }) else { return }

        let ring = ringRouter.ring(at: pass.slot)
        let want = pass.targetFrames - ring.frameCount
        guard want > 0 else { return }
        let frameCount = min(want, scratch.count / channels)
        guard frameCount > 0, let base = scratch.baseAddress else { return }

        nonisolated(unsafe) let pullBase = base
        guard let pull = gate.withAdmittedPull(pass, {
            supply.pullContent(
                frameCount: frameCount,
                sampleRate: sampleRate,
                channels: channels,
                into: pullBase
            )
        }) else { return }
        _ = totalPullCalls.wrappingAdd(1, ordering: .relaxed)
        let usable = max(0, min(pull.frames, frameCount))
        guard usable > 0 else {
            commitReport(passes: 1, requestedFrames: frameCount, writtenFrames: 0, refusedWrites: 0)
            return
        }

        nonisolated(unsafe) let writeBase = base
        nonisolated(unsafe) var wroteFrames = 0
        let refusal = gate.withAdmittedWrite(pass) {
            wroteFrames = ring.write(writeBase, count: usable * channels) / channels
        }
        commitReport(
            passes: 1, requestedFrames: frameCount, writtenFrames: wroteFrames,
            refusedWrites: refusal != nil ? 1 : 0
        )
    }

    private func commitReport(
        passes: Int, requestedFrames: Int, writtenFrames: Int, refusedWrites: Int
    ) {
        reportBox.withLock { report in
            report = AudioFeederPullReport(
                passes: report.passes + passes,
                requestedFrames: report.requestedFrames + requestedFrames,
                writtenFrames: report.writtenFrames + writtenFrames,
                refusedWrites: report.refusedWrites + refusedWrites
            )
        }
    }
}
