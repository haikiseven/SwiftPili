import Foundation
import os

/// Where `AVAudioEngine.start()` runs for the Demand hardware audio graph.
///
/// Device 2026-09-25 (`research/device/baseline-analysis-2026-09-25.md`,
/// `run2-report-2026-09-25.txt`): of the whole hardware bring-up, only
/// `start()` is ever slow — 262–297 ms after the audio hardware has idled (cold
/// launch, re-activating a page after dwelling), 4–12 ms otherwise — and every
/// slow start maps 1:1 onto a `[Hang] 313ms/333ms`. Session calls and
/// `prepare()` are 0–3 ms. VLC 4, mpv and IJKPlayer all start their output off
/// the main thread (`research/audio-start-main-thread-reference.md`).
enum AudioHardwareStartMode: String, Sendable, Equatable {
    /// `start()` runs on the renderer's serial hardware queue; the main actor
    /// only learns the outcome when the completion hops back.
    case async
    /// Kill switch: today's synchronous `start()` on the main actor,
    /// byte-for-byte.
    case sync

    static let environmentKey = "PATHA_AUDIO_ASYNC_START"

    /// Only the explicit `0` selects the rollback — any other value, or none,
    /// keeps the product behaviour, the same rule `PATHA_AUDIO_HW=0` uses.
    static func resolve(environment: [String: String]) -> AudioHardwareStartMode {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return .async }
        return environment[environmentKey] == "0" ? .sync : .async
    }
}

/// What the MainActor drain tick does this period. The tick is the single
/// producer of `renderedContentDidAdvance`, so this is the clock's policy.
enum AudioDrainTickAction: Sendable, Equatable {
    /// A hardware start is in flight: no consumer exists that anybody hears.
    /// Neither simulate one nor report — the clock HOLDS. A simulated drain
    /// here would advance F1 across the ~300 ms start and skip audio that was
    /// never played.
    case holdClock
    /// No hardware consumer owns the ring (Simulator, `PATHA_AUDIO_HW=0`, a
    /// soft-failed graph): simulate one at wall × rate.
    case simulateConsumer
    /// The real render callback drains the ring; report what it consumed.
    case reportHardwareDrain
}

/// The pending/token admission for an off-main hardware start, as a value.
///
/// Same reason `AudioFeederAdmission` is a value: the real handshake needs a
/// device (the Simulator never builds a hardware graph), and a handshake that
/// can only be tested on a device is a handshake nobody tests. The renderer is
/// the thin runtime wrapper around this; the rules are all here.
///
/// Three facts, deliberately separate:
///
/// - **`pendingToken`** — the start whose outcome the renderer is waiting for.
///   Only a completion carrying exactly this token may flip the renderer into
///   hardware mode; `stop`/teardown and a newer start move it, which is what
///   makes a late completion harmless.
/// - **`outstandingOperations`** — every closure submitted to the hardware
///   queue (starts AND queued stops/teardowns, for any engine this renderer
///   ever owned) that has not yet reported back to the main actor. While it is
///   non-zero some engine may be starting, running, or stopping on another
///   thread, so the main actor must neither reuse an engine (a `prepare()` or
///   `attach` racing a `start()`/`stop()` on the same instance) nor let a render
///   callback read the ring (see `renderRate`).
/// - The clock policy (`drainTickAction`), which follows from the first.
struct AudioHardwareStartAdmission: Sendable, Equatable {
    struct Token: Hashable, Sendable {
        let value: UInt64
    }

    enum Completion: Sendable, Equatable {
        /// Current start, renderer still running on this engine, hardware up.
        case accept
        /// Current start, but `start()` threw: the existing fill-only fallback.
        case softFail
        /// Operation returned successfully, but no current native consumer exists.
        case unavailable
        /// Superseded or orphaned (stop, teardown, newer start, engine
        /// replaced). Publish nothing. `stopStaleEngine` is true when the
        /// hardware actually came up, so it must be stopped — ON THE HARDWARE
        /// QUEUE, behind anything else already queued for it.
        case discard(stopStaleEngine: Bool)
    }

    private(set) var pendingToken: Token?
    private(set) var outstandingOperations = 0
    private var lastIssuedValue: UInt64 = 0
    private var nativeOperationSerial: UInt64 = 0
    private var nativeOperationIDs: Set<UInt64> = []

    var isPending: Bool { pendingToken != nil }

    /// No hardware-queue work of this renderer is unacknowledged, so an
    /// existing engine is exclusively the main actor's again.
    var mayReuseEngine: Bool { outstandingOperations == 0 }

    /// This completion returns exclusive native access only when no queued
    /// start/stop follows it. Never sample engine state while that work owns it.
    var maySampleNativeStateForCompletingStart: Bool { outstandingOperations == 1 }

    /// Issue a start. Supersedes any pending one (its completion will be
    /// discarded) and counts as one outstanding queue operation.
    mutating func beginStart() -> Token {
        lastIssuedValue &+= 1
        if lastIssuedValue == 0 { lastIssuedValue = 1 }
        let token = Token(value: lastIssuedValue)
        pendingToken = token
        outstandingOperations += 1
        return token
    }

    /// `stop` / teardown: whatever is in flight no longer has authority.
    mutating func invalidate() {
        pendingToken = nil
    }

    /// A non-start closure (a stop or teardown serialized behind an in-flight
    /// start) was submitted to the hardware queue.
    mutating func noteOperationSubmitted() {
        outstandingOperations += 1
    }

    /// Maintenance actions have exact-once acknowledgement independent of start tokens.
    mutating func beginNativeOperation() -> UInt64 {
        nativeOperationSerial &+= 1
        nativeOperationIDs.insert(nativeOperationSerial)
        noteOperationSubmitted()
        return nativeOperationSerial
    }

    mutating func completeNativeOperation(_ id: UInt64) {
        guard nativeOperationIDs.remove(id) != nil else { return }
        acknowledgeOperation()
    }

    /// A non-start closure reported back on the main actor.
    mutating func acknowledgeOperation() {
        outstandingOperations = max(0, outstandingOperations - 1)
    }

    /// A start closure reported back on the main actor. Always acknowledges the
    /// operation; only the current token, for a renderer that is still running
    /// on the very engine that was started, may be accepted.
    mutating func complete(
        token: Token,
        succeeded: Bool,
        rendererRunning: Bool,
        engineIsCurrent: Bool,
        engineReportsRunning: Bool,
        configurationCurrent: Bool = true
    ) -> Completion {
        acknowledgeOperation()
        guard pendingToken == token else {
            return .discard(stopStaleEngine: engineReportsRunning)
        }
        pendingToken = nil
        guard rendererRunning, engineIsCurrent else {
            // Unreachable today (stop and teardown both invalidate first), and
            // fail-closed if a future path forgets to: an orphan never flips
            // the renderer into hardware mode.
            return .discard(stopStaleEngine: engineReportsRunning)
        }
        guard configurationCurrent else { return .unavailable }
        guard succeeded else { return .softFail }
        return engineReportsRunning ? .accept : .unavailable
    }

    /// The value the render callback's rate box may carry.
    ///
    /// While any queue operation is outstanding the callback is held at rate 0
    /// — its existing "silence, read nothing" branch. This is what makes
    /// "no realtime consumer while pending" physically true: `start()` returns
    /// on the hardware queue and the callback begins firing BEFORE the
    /// completion reaches the main actor, and in that window the main actor is
    /// still running the seek protocol's synchronous (non-realtime)
    /// acknowledgement and may reset a slot. A callback that reads nothing
    /// cannot race that, drains nothing (the clock keeps holding), and cannot
    /// record a false short read. An abandoned engine still stopping on the
    /// queue shares the same box, so it is silenced by the same rule.
    func renderRate(requested: Float, nativeOutputUnavailable: Bool = false) -> Float {
        outstandingOperations > 0 || nativeOutputUnavailable ? 0 : requested
    }

    /// Whether an independent realtime callback owns acknowledgement. False
    /// while a start is pending, so a seek publication keeps its synchronous
    /// acknowledgement path instead of waiting on a callback that is not
    /// consuming anything yet.
    static func hasRealtimeConsumer(
        isRunning: Bool,
        engineStarted: Bool,
        fillOnlyMode: Bool,
        startPending: Bool,
        nativeOutputUnavailable: Bool = false,
        queueOutstanding: Bool = false
    ) -> Bool {
        isRunning && engineStarted && !fillOnlyMode && !startPending
            && !nativeOutputUnavailable && !queueOutstanding
    }

    static func drainTickAction(
        startPending: Bool,
        engineStarted: Bool,
        fillOnlyMode: Bool,
        nativeOutputUnavailable: Bool = false,
        queueOutstanding: Bool = false
    ) -> AudioDrainTickAction {
        if startPending || nativeOutputUnavailable || queueOutstanding { return .holdClock }
        if !engineStarted || fillOnlyMode { return .simulateConsumer }
        return .reportHardwareDrain
    }
}

/// Object-bound native facts. Notification delivery fences work immediately on
/// Apple's internal queue; only the immutable revision crosses to MainActor.
/// The callback never starts, prepares or destroys a native graph.
@MainActor
final class AudioNativeOutputBinding {
    final class Revision: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: UInt64(0))
        var current: UInt64 { value.withLock { $0 } }
        func invalidate() -> UInt64 {
            value.withLock { revision in
                revision &+= 1
                return revision
            }
        }
    }

    struct Stamp: Sendable {
        let binding: UInt64
        let revision: UInt64
    }

    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var binding: UInt64 = 0
    private var revision: Revision?
    private var preparedStamp: Stamp?
    private var nativeIsRunning: (@MainActor () -> Bool)?
    private var onInvalidation: (@MainActor () -> Void)?
    var reportsRunning: Bool {
        // Diagnostic Logging only: the native `isRunning` read, timed apart from
        // `outputPresentationLatency` so a slow `audio.timing` can be attributed.
        let runningSpan = UIHitchMonitor.beginSpan("audio.running")
        defer { UIHitchMonitor.endSpan(runningSpan) }
        return nativeIsRunning?() ?? false
    }
    var hasUnresolvedConfiguration: Bool {
        (revision?.current ?? 0) != (preparedStamp?.revision ?? 0)
    }
    var stamp: Stamp { Stamp(binding: binding, revision: revision?.current ?? 0) }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func bind(
        object: AnyObject,
        notification: Notification.Name,
        nativeIsRunning: @escaping @MainActor () -> Bool,
        onInvalidation: @escaping @MainActor () -> Void
    ) {
        retire()
        let currentBinding = binding
        let revision = Revision()
        self.revision = revision
        self.nativeIsRunning = nativeIsRunning
        self.onInvalidation = onInvalidation
        observer = notificationCenter.addObserver(forName: notification, object: object, queue: nil) { [weak self] _ in
            let observedRevision = revision.invalidate()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.deliver(binding: currentBinding, revision: observedRevision)
                }
            }
        }
    }

    /// Preparation has resolved all configuration changes seen up to this
    /// boundary. A queued notification from that preparation cannot revoke
    /// the start that uses its freshly resolved formats.
    func markPrepared(_ validated: Stamp) -> Bool {
        guard isCurrent(validated) else { return false }
        preparedStamp = validated
        return true
    }

    func isCurrent(_ stamp: Stamp) -> Bool {
        stamp.binding == binding && stamp.revision == revision?.current
    }

    private func deliver(binding: UInt64, revision: UInt64) {
        guard self.binding == binding, self.revision?.current == revision,
              preparedStamp?.revision != revision else { return }
        onInvalidation?()
    }

    func retire() {
        if let observer { notificationCenter.removeObserver(observer) }
        observer = nil
        binding &+= 1
        revision = nil
        preparedStamp = nil
        nativeIsRunning = nil
        onInvalidation = nil
    }

    isolated deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }
}
