import Foundation

/// Admission and cutover rules for the off-MainActor PCM ring feeder, as a value.
///
/// The feeder is the only thing in Path A that writes PCM into the ring slot the
/// real-time callback reads, and it does so from its own serial queue. Every
/// MainActor transaction that touches slot state — start, stop, flush, and all
/// three phases of the two-slot seek publish/acknowledge protocol — must **cut the
/// feeder over** first: revoke admission and bump the content generation. Not
/// "cooperate with", not "check a flag and hope": a stale pass writing into a slot
/// being `reset()` is PCM corruption, audible on the next callback.
///
/// The runtime gate holds one mutex across each source-pull or ring-write
/// verdict and body. Cutover takes the same mutex, so an operation finishes
/// before cutover returns or is refused afterward. This does not join the pass;
/// MainActor may wait for synchronous source/display/compaction work and lock
/// contention, with no hard wall-time bound. The realtime callback takes no gate.
///
/// The rules live here as a pure `struct` with no isolation and no I/O;
/// `AudioFeederGate` is the thin runtime mutex wrapper around them.
///
/// **This type deliberately knows nothing about the clock.** It cannot admit a
/// clock write, because the feeder has no route to one — see
/// `MediaEngineSession.renderedContentDidAdvance`, whose single caller stays on
/// MainActor by design (`architecture-audio-clock-ownership.md` §3.3 option A).
struct AudioFeederAdmission: Sendable, Equatable {
    /// Verdict returned to MainActor when it revokes admission.
    enum StandDown: Sendable, Equatable {
        /// No pass was in flight. Slot state is safe to touch immediately.
        case quiesced
        /// A pass is still running after its guarded data-access cutover. It
        /// retains scratch/ring/supply storage while finishing bookkeeping.
        /// Callers that need whole-pass completion use `joinAfterStandDown()`
        /// asynchronously; this observation does not require that stronger join.
        case mustJoin
    }

    /// What a feeder pass is allowed to do, stamped so a late pass can be refused.
    struct Pass: Sendable, Equatable {
        let slot: Int
        let contentGeneration: UInt64
        let targetFrames: Int
    }

    /// Why a pass may not consume source content or publish its pulled PCM.
    enum WriteRefusal: Sendable, Equatable {
        /// Content was replaced (seek discard, stop, flush, runtime fault) after
        /// this pass began. Its later pull is denied; PCM already in hand belongs
        /// to the previous timeline and cannot be published.
        case staleContentGeneration
        /// Admission was revoked before this operation's verdict.
        case standDownInProgress
        /// The feeder was retired.
        case retired
        /// The pass names a slot that is no longer the admitted one.
        case slotChanged
    }

    private(set) var isAdmitted = false
    private(set) var isRetired = false
    private(set) var isPassInFlight = false
    private(set) var admittedSlot = 0
    private(set) var targetFrames = 0
    /// Bumped by MainActor whenever the PCM supply's content is replaced. A pass
    /// carries the value it began with; a mismatch refuses its pull and write.
    private(set) var contentGeneration: UInt64 = 0
    /// Monotone count of completed passes. Diagnostics, and the cutover's tests.
    private(set) var completedPassCount = 0

    // MARK: - MainActor side

    /// Grant admission. Succeeds even while a pass is in flight, and **must**.
    ///
    /// Safety comes from `contentGeneration`: the transaction bumps it while
    /// admission is revoked, so a pass that predates the transaction is refused
    /// at its next pull/write even after admission is restored, while
    /// `isPassInFlight` still gates `beginPass` to keep the ring single-producer.
    @discardableResult
    mutating func admit(slot: Int, targetFrames: Int) -> Bool {
        guard !isRetired, slot == 0 || slot == 1 else { return false }
        isAdmitted = true
        admittedSlot = slot
        self.targetFrames = max(0, targetFrames)
        return true
    }

    /// Revoke admission and report whether a pass is still in flight.
    ///
    /// `.mustJoin` observes whole-pass lifetime, not outstanding admitted data
    /// access. Runtime teardown combines this pull/write cutover with retained
    /// storage; it need not join the queue. Acquiring the runtime gate mutex may
    /// still synchronously wait for the current pull/write and contention.
    mutating func standDown() -> StandDown {
        isAdmitted = false
        return isPassInFlight ? .mustJoin : .quiesced
    }

    /// Rate edge. Eventually consistent by design: the feeder recomputes its depth
    /// on its next pass, at most one period late. Ring depth does not gate a rate
    /// change — `AVAudioUnitTimePitch` re-times downstream of the ring — so this
    /// costs nothing audible.
    mutating func setTargetFrames(_ frames: Int) {
        targetFrames = max(0, frames)
    }

    /// Content replaced. Old passes cannot pull replacement PCM or publish PCM
    /// already held, even if the same slot is readmitted afterward.
    mutating func invalidateContent() {
        contentGeneration &+= 1
    }

    /// Terminal. Nothing admits again; a retired feeder is not resumable by
    /// anything except a fresh one. This is what makes a parked session's feeder
    /// unable to keep draining a ring nobody reads.
    mutating func retire() {
        isAdmitted = false
        isRetired = true
    }

    // MARK: - Feeder side

    /// Claim a pass, or refuse. Serial by construction: a second concurrent claim
    /// is refused, so `isPassInFlight` is a boolean rather than a count.
    mutating func beginPass() -> Pass? {
        guard isAdmitted, !isRetired, !isPassInFlight, targetFrames > 0 else { return nil }
        isPassInFlight = true
        return Pass(
            slot: admittedSlot,
            contentGeneration: contentGeneration,
            targetFrames: targetFrames
        )
    }

    /// Shared current-pass verdict for source consumption and ring publication.
    /// Runtime callers hold the gate across this check and the corresponding
    /// synchronous body; checking first and operating unlocked is insufficient.
    func writeVerdict(for pass: Pass) -> WriteRefusal? {
        if isRetired { return .retired }
        if pass.contentGeneration != contentGeneration { return .staleContentGeneration }
        if !isAdmitted { return .standDownInProgress }
        if pass.slot != admittedSlot { return .slotChanged }
        return nil
    }

    mutating func endPass() {
        guard isPassInFlight else { return }
        isPassInFlight = false
        completedPassCount &+= 1
    }
}
