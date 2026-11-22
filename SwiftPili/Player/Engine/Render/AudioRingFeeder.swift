import Foundation
import Synchronization
import os

/// Thread-safe PCM supply, callable from the feeder queue **and** from MainActor.
///
/// One supply, two entry points, no branch: `MediaEngineSession.pullPCM` (the
/// MainActor transaction paths — `start`, `prepareSeekTransition`) and the feeder
/// reach the same PCM through the same lock. The alternative — a feeder path and a
/// fallback MainActor path — is a branch selecting between two implementations of
/// the same operation, and this pipeline already paid for one of those: the
/// downcast that chose which clock was master, whose shipping branch had no test
/// (`MediaEngineSession.renderedContentDidAdvance`'s comment).
///
/// **Deliberately has no protocol default.** A default that supplies silence would
/// make a non-opted-in conformance feed the hardware nothing, forever, with no
/// error — the exact silent-failure shape `parkForReuse` and `runtimeGeneration`
/// had defaults removed for.
protocol AudioSupplySource: AnyObject, Sendable {
    /// Fill `buffer` with up to `frameCount` interleaved Float32 frames. Callable
    /// from any thread; implementations serialise internally. Returns frames
    /// written. Feeder calls hold the admission gate across this synchronous
    /// operation. Supply work must stay in memory, with no actor/native/I/O wait,
    /// callback or gate re-entry. The current source locks gate → PCM supply →
    /// display book; future conformances need a new lock-order audit. MainActor
    /// cutover may wait for this operation and its nested-lock contention.
    func pullContent(
        frameCount: Int,
        sampleRate: Double,
        channels: Int,
        into buffer: UnsafeMutablePointer<Float>
    ) -> AudioSupplyPull
}

/// What the feeder did since MainActor last looked. Drained on the drain-report
/// tick and handed to the session so decode scheduling and buffering state stay
/// where they are today — just invoked from a report instead of inline in the pull.
///
/// These are *supply* facts. None of them may move the clock.
struct AudioFeederPullReport: Sendable, Equatable {
    let passes: Int
    let requestedFrames: Int
    let writtenFrames: Int
    /// Passes whose pulled PCM was thrown away by `AudioFeederAdmission`.
    let refusedWrites: Int

    static let empty = AudioFeederPullReport(
        passes: 0, requestedFrames: 0, writtenFrames: 0, refusedWrites: 0
    )

    var isEmpty: Bool { self == .empty }
}

/// Runtime wrapper for `AudioFeederAdmission`.
///
/// An `OSAllocatedUnfairLock`, never taken by the real-time thread: the render
/// block reads only `PCMFloatRing` and `AtomicFloatBox`, and `makeSourceNode`'s
/// signature is the enforcement — the feeder and this gate are not reachable from
/// its captured state. Contention here is MainActor-transaction against
/// feeder-pass, both non-realtime; this does not make MainActor acquisition
/// nonblocking or give it a hard wall-time bound.
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

    func retire() {
        state.withLock { $0.retire() }
    }

    func beginPass() -> AudioFeederAdmission.Pass? {
        state.withLock { $0.beginPass() }
    }

    func endPass() {
        state.withLock { $0.endPass() }
    }

    /// Admit and consume source content in one critical section with cutover.
    /// Nil means the source body was not called, distinct from an empty pull.
    /// The synchronous, nonescaping body must not re-enter this gate or wait on
    /// an actor, native operation or I/O; see `AudioSupplySource`'s lock order.
    func withAdmittedPull(
        _ pass: AudioFeederAdmission.Pass,
        _ body: @Sendable () -> AudioSupplyPull
    ) -> AudioSupplyPull? {
        state.withLock { admission in
            guard admission.writeVerdict(for: pass) == nil else { return nil }
            return body()
        }
    }

    /// Adjudicate and perform the ring write inside ONE critical section, so the
    /// verdict cannot go stale between the check and the write. `body` runs only
    /// when the pass is still admitted for the slot and generation it began with.
    ///
    /// `body` is `@Sendable` because `OSAllocatedUnfairLock.withLock` takes a
    /// `@Sendable` closure, so a non-Sendable `body` cannot be captured by it —
    /// a Swift 6 isolation error that `swiftc -parse` cannot see and that only
    /// the Mac build surfaced. It is not an escaping closure and the lock runs
    /// it synchronously; the annotation states what was already true rather than
    /// widening the contract.
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

/// The audio-owned producer for the PCM ring.
///
/// ```
/// decoded PCM (AudioTimelineBuffer, behind AudioSupplySource)
///   → THIS feeder, on its own serial queue
///   → PCMFloatRing
///   → realtime render callback
/// ```
///
/// It exists because the ring holds `AudioRingReserve.wallSeconds` = 0.25 s and the
/// measured main-queue outage on a background transition is 283–400 ms, so audio
/// continuity was a function of MainActor being scheduled every quarter second. It
/// no longer is. Tolerance rises from 0.25 s to whatever the session has banked
/// (`audioPCMTargetSeconds` = 4 s), beyond which the feeder starves anyway because
/// decode scheduling is a MainActor report.
///
/// **What it deliberately does NOT do.** It never advances the media clock, and it
/// has no route to: it holds an `AudioSupplySource`, not an `AudioPullSource`, so
/// `renderedContentDidAdvance` is not callable from here at all. The clock stays
/// MainActor-paced, with `EngineAudioRenderer.reportDrain` as its single delta
/// producer (`architecture-audio-clock-ownership.md` §3.3, option A). The known
/// residual, stated rather than hidden: during a MainActor stall audio survives and
/// the **clock freezes and then advances by one large delta**. That is monotone and
/// loses nothing (`AudioDrainProgress`), it has no visible consumer on the
/// background path (video is warm-suspended), and unfreezing it is a different
/// change with its own ownership question — option (C) — not something to smuggle
/// in here.
///
/// **Wake source.** A `DispatchSourceTimer` on a dedicated serial queue.
/// Explicitly not a `Task` on any actor (the point is to leave the main dispatch
/// queue) and explicitly not a signal from the render block (that would put a
/// kernel wake on the realtime thread, and the block's contract is that it never
/// allocates, locks, logs, swaps ARC graph objects, or calls TimePitch).
final class AudioRingFeeder: @unchecked Sendable {
    private let queue: DispatchQueue
    private let ringRouter: PCMFloatRingRouter
    private let gate = AudioFeederGate()
    private let scratch: UnsafeMutableBufferPointer<Float>
    private let sampleRate: Double
    private let channels: Int

    /// Bound on MainActor and cleared after retirement. Each pass captures its
    /// own strong reference under this lock before attempting an admitted pull;
    /// the binding is not a substitute for the gate's consumption verdict.
    private let supplyBox = OSAllocatedUnfairLock<(any AudioSupplySource)?>(initialState: nil)

    private var timer: DispatchSourceTimer?

    /// One pass's (passes, requested, written, refused) contribution commits as a
    /// single unit under this lock, so `drainReport()` can never observe a torn
    /// combination (e.g. `requested` incremented but `written` not yet).
    private let reportBox = OSAllocatedUnfairLock<AudioFeederPullReport>(initialState: .empty)
    /// Cumulative pull calls, the counter `fillCallCount` publishes to MainActor.
    /// Deliberately not part of the paired report above — a diagnostic total only.
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
        // Scratch is allocated once on the caller's thread and freed in
        // `deinit`. Source/display bookkeeping during a pass may allocate.
        let capacity = max(
            self.channels,
            Int((maximumContentSeconds * sampleRate).rounded(.up)) * self.channels
        )
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0)
        scratch = buffer
    }

    deinit {
        // A dispatch source must not be released while still active. `retire`
        // is the normal path; this covers a renderer torn down without one.
        timer?.cancel()
        scratch.deallocate()
    }

    var admission: AudioFeederAdmission { gate.snapshot }
    var pullCallCount: Int { totalPullCalls.load(ordering: .relaxed) }

    // MARK: - MainActor control surface
    //
    // These methods run on MainActor. Cutovers do not synchronously join the
    // feeder queue: they take the same mutex as admitted pulls and writes.
    // MainActor may wait for that synchronous work and lock contention. The
    // explicit async join below is separate from this data-access cutover.

    /// Begin feeding `slot`. Called once per session, from `start`.
    func resume(supply: any AudioSupplySource, slot: Int, targetFrames: Int, period: TimeInterval) {
        guard gate.admit(slot: slot, targetFrames: targetFrames) else { return }
        supplyBox.withLock { $0 = supply }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Leeway lets the system coalesce the wake with other work on this queue's
        // thread. It is a power concession, not a headroom purchase: the ring is
        // topped to the same reserve at the same period as the MainActor loop it
        // replaces. What changed is who runs it, not how deep it goes.
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

    /// Revoke admission. Until readmission, no source pull or ring write can
    /// occur after this returns. Both verdict/body pairs share this mutex: an
    /// admitted operation finishes before cutover, or its later verdict denies
    /// the operation. Content replacement also invalidates the generation before
    /// reset/prime/readmission, so an old pass stays refused afterward.
    ///
    /// This cuts over data access without joining the entire pass. Retained
    /// scratch/rings and the pass's local supply keep storage alive while it
    /// finishes metadata reads, lease release, diagnostic atomics and `endPass`.
    /// Retention alone would not stop it consuming a reset supply's new content.
    ///
    /// MainActor can wait for the admitted pull/write and nested-lock contention,
    /// including PCM copying, display metadata and compaction. Scratch bounds
    /// copied output, not all source work; there is no hard wall-time bound.
    @discardableResult
    func standDown() -> AudioFeederAdmission.StandDown {
        let result = gate.standDown()
        // Held ring PCM keeps its evidence through an ordinary stand-down.
        // Actual reset/content retirement belongs to the ring's owner.
        return result
    }

    /// Join a previously stood-down feeder pass without blocking MainActor or
    /// the real-time callback. The queue hop runs after any pass already in
    /// flight; the feeder object must remain strongly held by the caller until
    /// this returns. Current teardown uses the guarded pull/write cutover plus
    /// retained pass storage instead; the existing EQ path requests this stronger
    /// completion boundary separately.
    func joinAfterStandDown() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// Retire permanently. Used by teardown — `stop`, owner exit, park — so a
    /// parked session cannot leave a feeder draining a ring nobody reads, which
    /// under option (A) would let the next drain report fabricate progress.
    ///
    /// Shares `standDown`'s mutex/wait contract without joining the pass. After
    /// it returns, every later pull/write verdict is `.retired`: no source
    /// consumption or ring publication can occur. A pass may still finish its
    /// remaining bookkeeping. Its local supply and the handler's strong `self`
    /// retain storage until return, independently of clearing `supplyBox`.
    func retire() {
        gate.retire()
        timer?.cancel()
        timer = nil
        supplyBox.withLock { $0 = nil }
        // The report is not delivered from here: this object cannot reach the
        // session (it holds an `AudioSupplySource`, never an `AudioPullSource`),
        // and that is the property that makes a second clock writer impossible.
        // The renderer decides what to do with the residual counters.
    }

    /// Content replaced. Bumps the generation to refuse a pass's later source
    /// pull and ring write even after admission is restored on the same slot.
    /// Call it while stood down: on its own it does NOT stop the feeder, because
    /// passes claimed after it carry the new generation and are admitted
    /// (measured — `invalidateContent` alone lets a busy feeder keep writing).
    func invalidateContent() {
        gate.invalidateContent()
    }

    func setTargetFrames(_ frames: Int) {
        gate.setTargetFrames(frames)
    }

    /// Re-admit after a transaction. Separate from `resume` so a readmission
    /// cannot accidentally install a different supply or restart the timer.
    @discardableResult
    func readmit(slot: Int, targetFrames: Int) -> Bool {
        gate.admit(slot: slot, targetFrames: targetFrames)
    }

    /// Drain the supply report. The accumulator is swapped for `.empty` under the
    /// same lock every pass commits through, so a report is consumed exactly once
    /// and can never be read half-written.
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

        // The pass owns scratch on this serial queue. This nonescaping body
        // writes it synchronously under the gate; the pointer cannot outlive it.
        // Denial is not an empty pull and must not increment supply reports.
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

        // Adjudicate and write in ONE critical section. A pass that lost its
        // admission or whose content generation moved throws its PCM away rather
        // than pushing the previous timeline's audio at the speaker.
        //
        // The pointer capture is asserted, not hoped for. `withAdmittedWrite`
        // runs this closure inside `OSAllocatedUnfairLock.withLock`, which takes
        // a `@Sendable` closure, and a raw pointer is not `Sendable` under Swift
        // 6. `base` is this feeder pass's own `scratch` buffer: it is filled by
        // `supply.pullContent` immediately above, read only here, synchronously,
        // while the gate's lock is held, and it does not outlive the call. Same
        // contract and same spelling as `FreezeStackSampler`'s pointers.
        nonisolated(unsafe) let writeBase = base
        nonisolated(unsafe) var wroteFrames = 0
        let refusal = gate.withAdmittedWrite(pass) {
            wroteFrames = ring.write(
                writeBase, count: usable * channels, displaySpans: pull.displaySpans,
                sampleRate: sampleRate, channels: channels
            ) / channels
        }
        commitReport(
            passes: 1, requestedFrames: frameCount, writtenFrames: wroteFrames,
            refusedWrites: refusal != nil ? 1 : 0
        )
    }

    /// Fold one pass's contribution into the pending report as a single atomic
    /// unit, so `drainReport()` can never read a torn (requested, written) pair.
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
