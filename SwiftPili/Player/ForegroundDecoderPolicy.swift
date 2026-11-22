import Foundation

/// Pure policy helpers for VideoToolbox recovery after leaving the foreground.
/// Marks sessions suspect on every background (never trusting sticky `isPiPActive`
/// or diagnostic FPS); PiP recovers while backgrounded, and audio-only mode defers
/// video reload until foreground return.
enum ForegroundDecoderPolicy {
    /// Legacy non-Demand settle after `didBecomeActive`. Demand presentation
    /// continuity bypasses this timer entirely; active PiP is a strict no-op and
    /// explicit restore is completed by native/attachment events.
    static let foregroundSettleSeconds: TimeInterval = 0.35

    /// Settle after `didEnterBackground` before recovering under PiP / audio-only
    /// background. Slightly longer so a Control Center peek is less likely to
    /// thrash a full reopen; still short enough that black PiP is not stuck.
    static let backgroundSettleSeconds: TimeInterval = 1.0

    /// In-place `loadVOD` when the session is suspect and playback is wanted.
    /// Frame rate is deliberately not an input (device: black + non-zero fps).
    ///
    /// `hasSurfacedFailure` is the fourth term because lifecycle recovery is the
    /// only automatic path that does not otherwise read it: the liveness
    /// evaluator stands down on `error != nil`, the delivery-health monitor
    /// guards on `error == nil`, and `Rejection.endsAutomaticRecovery` states the
    /// same rule for admission. Without it here, a stream sitting behind the
    /// Retry overlay reopens itself on the next background/foreground bounce —
    /// bypassing `allowsPlay(afterTerminalOpenFailure:)`, inheriting the burned
    /// budget an explicit Retry would have restored, and playing unasked. The
    /// loop is unbounded: `enteredBackground` accepts `.failed` and mints a new
    /// epoch each cycle, and a lifecycle trigger spends no runtime budget.
    ///
    /// Deliberately NOT `terminalOpenFailure`: that flag means "an open is in
    /// flight **or** permanently failed" — the lifecycle path sets it itself
    /// while admitting its own reload — so gating on it would stop lifecycle
    /// recovery running at all. The surfaced failure is the honest fact, and the
    /// explicit Retry path is what clears it.
    static func shouldReopenInPlace(
        sessionSuspect: Bool,
        userWantsPlaying: Bool,
        canAutoRevive: Bool,
        hasSurfacedFailure: Bool
    ) -> Bool {
        sessionSuspect && userWantsPlaying && canAutoRevive && !hasSurfacedFailure
    }

    /// Foreground settle when there is no PiP session to dismiss.
    ///
    /// Legacy no-PiP foreground settle. Demand does not use either fixed delay:
    /// its coordinator waits on typed video preparation, actual attachment and
    /// current-generation presentation proof.
    static let foregroundSettleWithoutPiPSeconds: TimeInterval = 0.05

    static func settleDelay(
        forBackground: Bool,
        pictureInPictureDismissalPending: Bool = true
    ) -> TimeInterval {
        if forBackground { return backgroundSettleSeconds }
        return pictureInPictureDismissalPending
            ? foregroundSettleSeconds
            : foregroundSettleWithoutPiPSeconds
    }
}

/// Whether an admitted recovery may reopen the RETAINED signed URL, or has to
/// refetch playurl first.
///
/// A refetch is a WBI-signed network round trip sitting in front of the reopen,
/// and for a same-encode recovery it buys nothing: the signed URL already in
/// hand addresses the same origin file, and the in-place CDN switch has always
/// reopened exactly that URL for exactly this reason. It is also the single
/// largest avoidable cost on the background→foreground path, where the user is
/// watching and waiting.
///
/// Two triggers still need a real refetch, for reasons about WHAT is opened
/// rather than how fast: an encode drop is a different origin file, and a manual
/// retry follows a surfaced failure in which the URL itself is a suspect. A
/// stale signature needs one because the bytes are no longer reachable.
enum RetainedSourceReopenPolicy {
    enum Decision: Equatable {
        case reopenRetainedURL
        /// `reason` is logged, so a device capture says which of the four
        /// distinct causes sent a recovery back through playurl.
        case refetchPlayURL(reason: String)
    }

    static func decision(
        isManualRetry: Bool,
        replacementQuality: Int?,
        hasRetainedURL: Bool,
        retainedURLIsFresh: Bool
    ) -> Decision {
        if let replacementQuality {
            return .refetchPlayURL(reason: "different encode qn=\(replacementQuality)")
        }
        if isManualRetry {
            return .refetchPlayURL(reason: "manual retry")
        }
        guard hasRetainedURL else {
            return .refetchPlayURL(reason: "no retained URL")
        }
        guard retainedURLIsFresh else {
            return .refetchPlayURL(reason: "signature expired")
        }
        return .reopenRetainedURL
    }
}

/// The identity of one lifecycle load from admission through transport
/// readiness.  A render attachment generation is deliberately absent: a
/// surface can be rebound while the backend is still opening, so it cannot be
/// part of the transport-ready decision.
struct LifecycleReadinessFence: Equatable {
    let lifecycleEpoch: UInt64
    let initialTrigger: LifecycleRecoveryCoordinator.Trigger
    /// Always a live `DecoderRecoveryAdmission` ticket — every backend owns a
    /// real `runtimeGeneration`, so an epoch that cannot be admitted is abandoned
    /// rather than opened unticketed. That is what makes the fence followable:
    /// only an open authorized by THIS ticket may re-stamp its generations or
    /// close it.
    let admissionToken: UInt64
    let ownerKey: String
    let ownerLeaseGeneration: UInt64
    let source: DecoderRecoveryAdmission.Source
    let loadGeneration: Int
    let backendGeneration: UInt64

    func hasSameAuthority(as other: Self) -> Bool {
        lifecycleEpoch == other.lifecycleEpoch
            && initialTrigger == other.initialTrigger
            && admissionToken == other.admissionToken
            && ownerKey == other.ownerKey
            && ownerLeaseGeneration == other.ownerLeaseGeneration
            && source.hasSameAuthority(as: other.source)
    }
}

enum LifecycleReadinessOutcome: Equatable {
    case transportReady
    case terminalFailure
}

enum LifecycleReadinessAcknowledgement: Equatable {
    case ignored
    case transportReady(LifecycleRecoveryCoordinator.Action)
    case terminalFailure(LifecycleRecoveryCoordinator.Action)
}

/// A foreground decision samples this value from the current backend. It is a
/// projection of live operation/resource ownership, not stored lifecycle state:
/// the same backend generation must still own either an active producer or a
/// deliberately paused, ready pipeline.
struct RetainedPipelineHealth: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case playingWithProducer
        case pausedReady
        case requiresRecovery(Reason)
    }

    enum Reason: String, Equatable, Sendable {
        /// The backend holds a pipeline but cannot establish that it survived the
        /// suspension. This is a STATED verdict, not an absent one: the protocol
        /// requirement has no default, so nothing reaches this by omission. It is
        /// `VLCPlayerBackend`'s answer for a `.playing`/`.paused` input, because
        /// libVLC reports transport intent and not input or decoder liveness.
        case unverifiedBackend
        case staleGeneration
        case transportNotReady
        case seekInFlight
        case missingResources
        case missingProducer
        case terminal
    }

    let backendGeneration: UInt64
    let state: State

    func provesReusable(
        for generation: UInt64,
        expectsPlaying: Bool
    ) -> Bool {
        guard backendGeneration == generation else { return false }
        switch state {
        case .playingWithProducer:
            return expectsPlaying
        case .pausedReady:
            return !expectsPlaying
        case .requiresRecovery:
            return false
        }
    }
}

/// Completion evidence for a Demand recovery ticket. A loader may report a
/// terminal failure before a backend has an opportunity to emit `.error`, but
/// that path must be explicit and must never be confused with a submission
/// return. The ticket itself remains the owner of the context used to finish.
enum DecoderRecoveryCompletion: Equatable {
    case backendReady
    case backendError
    case terminalLoaderFailure

    var succeeded: Bool {
        self == .backendReady
    }
}

/// One lifecycle epoch owns at most one reload. The coordinator does not know
/// how a loader or backend works; it only transitions from a submitted
/// opening to a typed readiness outcome. This is what prevents a loader's
/// "submission returned" boundary from being mistaken for completion.
struct LifecycleRecoveryCoordinator: Equatable {
    enum Trigger: Equatable {
        case background
        case foreground
    }

    enum Phase: Equatable {
        case idle
        case waiting(Trigger, UInt64)
        case reloading(Trigger, UInt64)
        case waitingForBackgroundReload(UInt64)
        case opening(LifecycleReadinessFence)
        case awaitingForeground(LifecycleReadinessFence)
        case ready(LifecycleReadinessFence)
        case failed(LifecycleReadinessFence)
    }

    enum Action: Equatable {
        case none
        case schedule(Trigger, UInt64)
        case reload(Trigger, UInt64)
        case rebindInline(UInt64)
        case reattachAndAwait(UInt64)
    }

    private(set) var epoch: UInt64 = 0
    private(set) var phase: Phase = .idle
    /// Environment and health events are not allowed to revive a terminal
    /// session.  This is separate from `phase`: an ended session may still
    /// have a final inline frame, but it no longer owns a lifecycle transaction.
    var terminalState: PlaybackTerminalState = .active
    var presentationPhase: DemandVideoPresentationPhase = .idle
    var presentationApplicationPhase: DemandPresentationApplicationPhase = .active
    var presentationRecoveryStage: DemandPresentationRecoveryStage = .retainedRenderer
    /// Set only when activation abandons a pending native start. A late
    /// didStart from that request must not retake presentation ownership after
    /// the inline fallback has been admitted.
    var pipStartWasAbandoned = false
    /// A Demand PiP activation reconcile is single-flight. The native stop
    /// handoff cannot begin until its completion event clears this marker.
    var pipPresentationReconcilePending = false

    /// Enter a typed terminal state at the policy boundary.  In particular,
    /// this does not manufacture a lifecycle failure or a recovery effect.
    /// The current epoch is fenced so callbacks from the ended transaction are
    /// stale even when UIKit reuses the same surface generation.
    mutating func enterTerminal(_ state: PlaybackTerminalState) {
        guard state.isTerminal,
              terminalState == .active else {
            // Terminal admission is monotonic. A duplicate end must not bump
            // the epoch twice, and a late natural-end callback must not
            // overwrite a previously surfaced terminal failure/stopped state.
            return
        }
        terminalState = state
        epoch &+= 1
        phase = .idle
        presentationPhase = .idle
        presentationApplicationPhase = .active
        presentationRecoveryStage = .retainedRenderer
        pipStartWasAbandoned = false
        pipPresentationReconcilePending = false
    }

    /// Clear terminal state only for an explicit new playback start.  This is
    /// intentionally not a recovery action and emits no lifecycle effect.
    mutating func beginExplicitReplay() {
        guard terminalState == .ended else { return }
        terminalState = .active
        epoch &+= 1
        phase = .idle
        presentationPhase = .idle
        presentationApplicationPhase = .active
        presentationRecoveryStage = .retainedRenderer
        pipStartWasAbandoned = false
        pipPresentationReconcilePending = false
    }

    /// Descriptive aliases keep call sites readable without introducing a
    /// second terminal-state owner.
    mutating func markPlaybackEnded() { enterTerminal(.ended) }
    mutating func clearTerminalForReplay() { beginExplicitReplay() }

    mutating func beginDemandPresentationEpoch() -> UInt64 {
        epoch &+= 1
        phase = .idle
        pipPresentationReconcilePending = false
        return epoch
    }

    mutating func ensureDemandPresentationEpoch() -> UInt64 {
        if epoch == 0 { epoch = 1 }
        return epoch
    }

    mutating func enteredBackground(
        reloadWhileBackgrounded: Bool = true,
        terminalState: PlaybackTerminalState? = nil
    ) -> Action {
        if let terminalState, terminalState.isTerminal {
            enterTerminal(terminalState)
        }
        guard !self.terminalState.isTerminal else {
            phase = .idle
            return .none
        }
        // An admitted load deliberately survives the task that scheduled it.
        // A rapid active/background bounce must therefore join that load,
        // rather than assign a new epoch that could admit a second reload.
        switch phase {
        case .reloading, .waitingForBackgroundReload, .opening, .awaitingForeground:
            return .none
        case .idle, .waiting, .ready, .failed:
            break
        }
        epoch &+= 1
        phase = .waiting(.background, epoch)
        return reloadWhileBackgrounded ? .schedule(.background, epoch) : .none
    }

    mutating func becameActive(
        retainedPipelineHealth: RetainedPipelineHealth? = nil,
        expectsPlaying: Bool = true,
        terminalState: PlaybackTerminalState? = nil
    ) -> Action {
        if let terminalState, terminalState.isTerminal {
            enterTerminal(terminalState)
        }
        guard !self.terminalState.isTerminal else {
            phase = .idle
            return .none
        }
        switch phase {
        case .waiting(.background, _):
            phase = .waiting(.foreground, epoch)
            return .schedule(.foreground, epoch)
        case .reloading(.background, let activeEpoch):
            phase = .waitingForBackgroundReload(activeEpoch)
            return .reattachAndAwait(activeEpoch)
        case .waitingForBackgroundReload(let activeEpoch):
            return .reattachAndAwait(activeEpoch)
        case .opening(let fence), .awaitingForeground(let fence):
            phase = .awaitingForeground(fence)
            return .reattachAndAwait(fence.lifecycleEpoch)
        case .ready(let fence):
            if retainedPipelineHealth?.provesReusable(
                for: fence.backendGeneration,
                expectsPlaying: expectsPlaying
            ) == true {
                phase = .idle
                return .rebindInline(fence.lifecycleEpoch)
            }
            // `.ready` records a past callback. It is not proof that the
            // producer/resources survived the remaining suspension. A fresh
            // foreground epoch reuses the normal admission/executor instead
            // of reviving or reopening outside that authority.
            epoch &+= 1
            phase = .waiting(.foreground, epoch)
            return .schedule(.foreground, epoch)
        case .failed:
            phase = .idle
            return .none
        case .idle, .waiting(.foreground, _), .reloading(.foreground, _):
            return .none
        }
    }

    mutating func settleFinished(trigger: Trigger, epoch candidate: UInt64) -> Action {
        guard !terminalState.isTerminal,
              candidate == epoch,
              phase == .waiting(trigger, candidate) else { return .none }
        phase = .reloading(trigger, candidate)
        return .reload(trigger, candidate)
    }

    /// Mark the lifecycle request as opening before any loader await. This
    /// provisional fence lets an API/candidate failure be acknowledged as a
    /// terminal failure, while a later backend submission replaces only its
    /// load/backend generations.
    @discardableResult
    mutating func beginOpening(_ fence: LifecycleReadinessFence) -> Bool {
        guard !terminalState.isTerminal,
              fence.lifecycleEpoch == epoch else { return false }
        switch phase {
        case .reloading(let trigger, let candidate)
                where trigger == fence.initialTrigger && candidate == fence.lifecycleEpoch:
            phase = .opening(fence)
            return true
        case .waitingForBackgroundReload(let candidate)
                where candidate == fence.lifecycleEpoch && fence.initialTrigger == .background:
            phase = .awaitingForeground(fence)
            return true
        default:
            return false
        }
    }

    /// Replace the provisional fence after `backend.load` has submitted a
    /// successor backend context. The lifecycle ticket and epoch remain the
    /// same; only transport generations may advance.
    @discardableResult
    mutating func replaceOpeningFence(_ fence: LifecycleReadinessFence) -> Bool {
        guard !terminalState.isTerminal,
              fence.lifecycleEpoch == epoch else { return false }
        switch phase {
        case .opening(let current) where current.hasSameAuthority(as: fence):
            phase = .opening(fence)
            return true
        case .awaitingForeground(let current) where current.hasSameAuthority(as: fence):
            phase = .awaitingForeground(fence)
            return true
        default:
            return false
        }
    }

    /// A typed ready/failure acknowledgement is the only completion path.
    /// Duplicate, stale, or post-terminal callbacks return `.ignored` and do
    /// not mutate the current epoch.
    mutating func reloadFinished(
        fence: LifecycleReadinessFence,
        outcome: LifecycleReadinessOutcome,
        appIsActive: Bool
    ) -> LifecycleReadinessAcknowledgement {
        guard !terminalState.isTerminal,
              fence.lifecycleEpoch == epoch else { return .ignored }
        let accepted: Bool
        switch phase {
        case .opening(let current), .awaitingForeground(let current):
            accepted = current == fence
        default:
            accepted = false
        }
        guard accepted else { return .ignored }

        switch outcome {
        case .transportReady:
            phase = .ready(fence)
            if appIsActive {
                phase = .idle
                return .transportReady(.rebindInline(fence.lifecycleEpoch))
            }
            return .transportReady(.none)
        case .terminalFailure:
            phase = .failed(fence)
            if appIsActive {
                phase = .idle
            }
            return .terminalFailure(.none)
        }
    }

    /// A background settle may discover that an explicitly observed PiP lease
    /// is already carrying playback. Keep the epoch pending for foreground
    /// recovery instead of tearing that PiP session down on the timer.
    mutating func deferBackgroundReloadUntilForeground(epoch candidate: UInt64) {
        guard !terminalState.isTerminal,
              candidate == epoch,
              phase == .reloading(.background, candidate) else { return }
        phase = .waiting(.background, candidate)
    }

    mutating func abandon(epoch candidate: UInt64) {
        guard candidate == epoch else { return }
        phase = .idle
    }

    mutating func invalidate() {
        epoch &+= 1
        phase = .idle
        terminalState = .active
        presentationPhase = .idle
        presentationApplicationPhase = .active
        presentationRecoveryStage = .retainedRenderer
    }
}

/// **Recovery boundary 1 of 2** — every recovery whose completion is OBSERVABLE:
/// decoder rebuilds (typed runtime fault or the frame-liveness watchdog),
/// lifecycle reloads, manual retry, an encode drop. Each resolves through the
/// backend's `readyToPlay` / `.error`, which is what releases a ticket.
///
/// **Boundary 2 is `PlayerViewModel.switchCDN`**, and a CDN host swap is
/// deliberately not modelled here. Its characteristic failure is a host that
/// answers *nothing* — no ready, no error — so a ticket taken on it is never
/// released and every later detector coalesces into a dead operation. It is
/// bounded by `RecoveryBudget.spendCDNSwitch()` and a `defer`-released in-flight
/// flag instead, which a hung host cannot wedge. The two boundaries share
/// `RecoveryBudget` and nothing else. Referenced from `switchCDN`,
/// `RecoveryBudget` and `PlayerViewModel.admitRecovery` rather than restated.
///
/// It owns no task or timer; callers supply the current time and perform the
/// admitted reload. A new backend generation installs a new context, which
/// invalidates tickets from the old owner or source.
struct DecoderRecoveryAdmission: Equatable {
    enum Source: Equatable {
        case vod(aid: Int, cid: Int, quality: Int, source: String)
        case live(roomID: Int, quality: Int)
        case offline(OfflinePlaybackAsset)

        /// Quality may be normalized by the resolver during the successor
        /// open. The retained authority is the content/source, not that
        /// resolver detail; load/backend generations fence the actual open.
        func hasSameAuthority(as other: Self) -> Bool {
            switch (self, other) {
            case let (
                .vod(aid: leftAid, cid: leftCid, quality: _, source: leftSource),
                .vod(aid: rightAid, cid: rightCid, quality: _, source: rightSource)
            ):
                return leftAid == rightAid && leftCid == rightCid && leftSource == rightSource
            case let (
                .live(roomID: leftRoom, quality: _),
                .live(roomID: rightRoom, quality: _)
            ):
                return leftRoom == rightRoom
            case let (.offline(left), .offline(right)):
                return left == right
            default:
                return false
            }
        }
    }

    struct Context: Equatable {
        let owner: String
        let ownerLeaseGeneration: UInt64
        let backendGeneration: UInt64
        let source: Source

        /// Backend generations and normalized quality are transport details.
        /// The owner/lease/source tuple is the authority that lets one
        /// admitted ticket migrate across a successor backend context.
        func hasSameAuthority(as other: Self) -> Bool {
            owner == other.owner
                && ownerLeaseGeneration == other.ownerLeaseGeneration
                && source.hasSameAuthority(as: other.source)
        }
    }

    /// What one admitted ticket authorizes. Detection stays plural — frame
    /// liveness, a frozen clock and a hard runtime fault are genuinely different
    /// signals — but the *authority* collapsed into this enum: the budget, the
    /// in-flight ticket, the coalescing and the backoff.
    enum Trigger: Equatable {
        /// Rebuild the decode path on the retained source (shared by typed VT faults and frame-liveness).
        case runtimeFault
        case lifecycle(epoch: UInt64)
        case manualRetry
        case streamTransport(cycle: UUID, request: UUID)
        /// Neither the host nor the position: a different encode of the same
        /// content. Spends no counter — the quality ladder is finite and strictly
        /// descending, its own bound — but it is a full source reopen with a real
        /// ready/error, so it holds the ticket like the rest.
        case differentEncode(quality: Int, reason: String)

        var streamRequestID: UUID? {
            guard case .streamTransport(_, let request) = self else { return nil }
            return request
        }

        var isLifecycle: Bool {
            if case .lifecycle = self { return true }
            return false
        }

        var isRuntimeFault: Bool {
            self == .runtimeFault
        }

        /// Lifecycle, manual and encode-drop actions are independent authorities.
        /// Only a decode-path rebuild spends the automatic decoder reload bucket,
        /// and only it arms the retry backoff on failure.
        var spendsAutomaticRuntimeBudget: Bool {
            isRuntimeFault
        }

        /// The encode tier this ticket authorizes; `nil` means reopen the tier the
        /// retained source already carries. This is what keeps the executor free
        /// of a per-trigger branch.
        var replacementQuality: Int? {
            guard case .differentEncode(let quality, _) = self else { return nil }
            return quality
        }

        var lifecycleEpoch: UInt64? {
            guard case .lifecycle(let epoch) = self else { return nil }
            return epoch
        }
    }

    struct Request: Equatable {
        let context: Context
        let trigger: Trigger
        let position: TimeInterval
        let fault: MediaRuntimeFault?
    }

    struct Ticket: Equatable {
        let token: UInt64
        let request: Request
    }

    enum Rejection: Equatable {
        case noAuthority
        case staleContext
        case staleFault
        case invalidPosition
        case nonRecoverableFault
        case backoff
        case budgetExhausted
        case lifecycleEpochAlreadySpent

        /// Whether the rejection is a verdict on the STREAM rather than on the
        /// request that asked. Exactly two are — the reopens are spent, or the
        /// fault itself is fatal — and only those may leave the player terminal.
        /// The rest describe the request: a one-second runtime-fault suppression,
        /// evidence from a superseded generation, a different owner/lease/source
        /// (or none installed), a replayed epoch, a non-finite position (an
        /// internal bug, not a broken stream). Surfacing Retry for one of those
        /// freezes a stream that was about to recover on its own — `error != nil`
        /// stands the 5s liveness evaluator down for good. Deliberately not a
        /// function of the trigger: an explicit Retry that cannot be admitted has
        /// produced nothing whatever the reason, and `retryPlayback` says so for
        /// itself without consulting this.
        var endsAutomaticRecovery: Bool {
            switch self {
            case .budgetExhausted, .nonRecoverableFault:
                true
            case .noAuthority, .staleContext, .staleFault, .invalidPosition,
                 .backoff, .lifecycleEpochAlreadySpent:
                false
            }
        }
    }

    enum Decision: Equatable {
        case admitted(UInt64)
        case coalesced(UInt64)
        case rejected(Rejection)
    }

    /// A failed or recently admitted runtime-fault reopen must not immediately
    /// start another rebuild. Lifecycle and manual authorities do not use this
    /// runtime-fault backoff.
    static let retryBackoff: TimeInterval = 1

    private(set) var context: Context?
    private(set) var inFlight: Ticket?
    private(set) var nextToken: UInt64 = 0
    private(set) var runtimeBackoffUntil: TimeInterval = 0
    /// The last lifecycle epoch admitted or coalesced for the current
    /// owner/source/lease authority. This is intentionally typed state rather
    /// than a timer, watchdog, observer, or boolean. A successor backend
    /// generation keeps it; authority replacement clears it.
    private(set) var lastLifecycleEpoch: UInt64?

    /// Install a backend successor. A current ticket survives only when the
    /// owner/lease/source authority is unchanged; its backend generation and
    /// request context migrate together. This keeps a lifecycle ticket alive
    /// across the `stop → backend.load` handoff instead of accidentally making
    /// submission look like completion.
    mutating func install(_ context: Context?) {
        guard let context else {
            invalidate()
            return
        }
        let authorityUnchanged = self.context?.hasSameAuthority(as: context) == true
        if let ticket = inFlight,
           ticket.request.context.hasSameAuthority(as: context) {
            self.context = context
            inFlight = Ticket(
                token: ticket.token,
                request: Request(
                    context: context,
                    trigger: ticket.request.trigger,
                    position: ticket.request.position,
                    fault: ticket.request.fault
                )
            )
            return
        }
        self.context = context
        inFlight = nil
        if !authorityUnchanged {
            runtimeBackoffUntil = 0
            lastLifecycleEpoch = nil
        }
    }

    /// Return the ticket currently owned by admission, allowing only backend
    /// generation/quality migration within the same owner, lease, and source.
    /// Callers must use this value's context for completion; reconstructing a
    /// context from mutable ViewModel quality/source fields can finish the
    /// wrong ticket or strand the original one.
    func authoritativeTicket(
        for token: UInt64,
        matchingAuthority authority: Context
    ) -> Ticket? {
        guard let currentContext = context,
              let ticket = inFlight,
              ticket.token == token,
              currentContext == ticket.request.context,
              ticket.request.context.hasSameAuthority(as: authority) else {
            return nil
        }
        return ticket
    }

    mutating func invalidate() {
        context = nil
        inFlight = nil
        runtimeBackoffUntil = 0
        lastLifecycleEpoch = nil
    }

    mutating func admit(
        _ request: Request,
        now: TimeInterval,
        budget: inout RecoveryBudget
    ) -> Decision {
        guard !request.context.owner.isEmpty,
              request.context.backendGeneration > 0,
              context != nil else {
            return .rejected(.noAuthority)
        }
        guard context == request.context else {
            return .rejected(.staleContext)
        }
        guard request.position.isFinite else {
            return .rejected(.invalidPosition)
        }
        if let fault = request.fault {
            guard fault.ownerGeneration == request.context.backendGeneration else {
                return .rejected(.staleFault)
            }
            guard fault.ownerLeaseGeneration == 0
                    || fault.ownerLeaseGeneration == request.context.ownerLeaseGeneration else {
                return .rejected(.staleFault)
            }
            // The two guards above already proved this fault belongs to the
            // CURRENT owner, lease and backend generation, so it is evidence
            // about the operation THIS admission is running — not an unrelated
            // rejection. That operation has failed fatally, so it terminates
            // here as well as being rejected; leaving it open is what let the
            // next manual Retry coalesce into a dead ticket (spinner, no
            // reopen). `.staleFault` deliberately never reaches this point: it
            // is evidence about a superseded generation and says nothing about
            // the live ticket.
            guard fault.isRecoveryWorthy else {
                if let ticket = inFlight {
                    finishAuthoritatively(
                        token: ticket.token,
                        matchingAuthority: request.context,
                        now: now,
                        outcome: .backendError
                    )
                }
                return .rejected(.nonRecoverableFault)
            }
        }
        // One ticket at a time, and a second request always JOINS it — never
        // replaces it, so a ticket's request always describes the operation
        // actually running. Reopening beside it would race it; taking it over
        // would strand the fence that follows its token.
        if let ticket = inFlight {
            guard ticket.request.context == request.context else {
                return .rejected(.staleContext)
            }
            // An overlapping lifecycle request is still the same operation,
            // even when the primary ticket was runtime/manual. Record the
            // lifecycle epoch at this boundary so a later duplicate cannot
            // manufacture a second open after the shared ticket finishes.
            if let epoch = request.trigger.lifecycleEpoch {
                if !markLifecycleEpoch(epoch), lastLifecycleEpoch != epoch {
                    return .rejected(.lifecycleEpochAlreadySpent)
                }
            }
            return .coalesced(ticket.token)
        }

        // Charge the resource this trigger draws.
        switch request.trigger {
        case .lifecycle(let epoch):
            guard markLifecycleEpoch(epoch) else {
                return .rejected(.lifecycleEpochAlreadySpent)
            }
        case .runtimeFault:
            guard now >= runtimeBackoffUntil else {
                return .rejected(.backoff)
            }
            // Seek priming is a local miss past a seek that already positioned
            // (audio not banked, preroll, EOF short of the target). It is not a
            // dead decoder. Charging it here used up the two reloads a genuine
            // VideoToolbox fault shares with the liveness watchdog, so two
            // ordinary seeks left the rest of the video with nothing but Retry.
            // The ticket still reopens the retained source; only the bucket is
            // spared. A second prime failure while that ticket is open still
            // coalesces and surfaces, so a seek that cannot be primed stays bounded.
            if request.fault?.stage != .seekPriming {
                guard budget.spendDecoderReload(at: request.position) else {
                    return .rejected(.budgetExhausted)
                }
            }
        case .differentEncode:
            // Bounded by the encode ladder, not by a counter.
            break
        case .manualRetry, .streamTransport:
            // Manual authority and exact stream requests bypass decoder debt.
            // The stream cycle spends its own currency at actual issuance.
            break
        }

        nextToken &+= 1
        let ticket = Ticket(token: nextToken, request: request)
        inFlight = ticket
        return .admitted(ticket.token)
    }

    /// Mark an epoch only once for the current authority. Coordinator epochs
    /// are monotonic, so rejecting an older value also fences a stale
    /// callback/request that arrived after a newer lifecycle epoch.
    private mutating func markLifecycleEpoch(_ epoch: UInt64) -> Bool {
        guard lastLifecycleEpoch.map({ epoch > $0 }) ?? true else {
            return false
        }
        lastLifecycleEpoch = epoch
        return true
    }

    /// Finish exactly the ticket that admission still owns. The original
    /// authority may have an older backend generation or pre-normalization
    /// quality; the migrated ticket context is authoritative for the exact
    /// completion. A replaced owner/source or consumed ticket is a no-op.
    @discardableResult
    mutating func finishAuthoritatively(
        token: UInt64,
        matchingAuthority authority: Context,
        now: TimeInterval,
        outcome: DecoderRecoveryCompletion
    ) -> Bool {
        guard let ticket = authoritativeTicket(
            for: token,
            matchingAuthority: authority
        ) else {
            return false
        }
        inFlight = nil
        if !outcome.succeeded, ticket.request.trigger.spendsAutomaticRuntimeBudget {
            runtimeBackoffUntil = max(runtimeBackoffUntil, now + Self.retryBackoff)
        }
        return true
    }
}

/// Exactly two kinds of exit may leave playback running, and each is admitted
/// here so no screen can invent a third.
///
/// **PiP.** Only an observed PiP lease may keep an owner alive after exit.
///
/// **Fullscreen presentation.** A UIKit `.fullScreen` presentation removes the
/// presenter's view from its window, firing SwiftUI `onDisappear` while the
/// screen still owns playback. `playerPresentationIsOnScreen` must come from a
/// live UIKit check (`PlayerPresentationHostPresence.isOnScreen`), never `isFullscreen`.
enum PlayerOwnerExitPolicy {
    static func shouldKeepPlayback(
        ownerMatches: Bool,
        hasObservedPiPLease: Bool,
        playerPresentationIsOnScreen: Bool,
        configuration: PlaybackContinuationConfiguration
    ) -> Bool {
        guard ownerMatches else { return false }
        if playerPresentationIsOnScreen { return true }
        return hasObservedPiPLease && configuration.allowsAutomaticPiP
    }
}

/// What an owner exit actually did, so the screen that asked for it does not
/// have to re-derive the policy that decided it.
///
/// The distinction exists because keeping PLAYBACK alive and keeping OWNERSHIP
/// with the requesting screen are different things, and the two keep-cases above
/// want opposite answers:
///  - PiP hands the exit to `DeferredPiPOwnerExit`, which completes it when the
///    native lease ends. The screen must let its lease go, exactly as before.
///  - a presentation of ours covers a screen that is still there. If that screen
///    dropped its lease it would claim a NEW one on its next activation pass —
///    which is `newContentOwnership`, a full teardown, and is what the device
///    capture above recorded: nobody was left entitled to claim the park.
enum PlayerOwnerExitOutcome: Equatable {
    /// The player was stopped, parked, handed on, or the lease was already
    /// stale. The requesting screen owns nothing now.
    case ownershipEnded
    /// Playback continues and THIS lease is still the live one. The screen kept
    /// its ownership and must not re-claim.
    case leaseRetained
}

/// A screen may disappear while its explicitly observed PiP session remains
/// visible. Remember that owner until the native lease ends, then consume the
/// exit exactly once. A different owner must never be stopped by a late PiP
/// callback from the previous screen.
struct DeferredPiPOwnerExit: Equatable {
    private(set) var owner: String?

    mutating func preserve(owner: String) {
        self.owner = owner
    }

    mutating func cancel() {
        owner = nil
    }

    mutating func consumeLeaseEnd(currentOwner: String) -> String? {
        defer { owner = nil }
        guard owner == currentOwner else { return nil }
        return owner
    }
}

/// User-facing continuation settings. Background audio is the broader gate:
/// PiP is a background playback mode and cannot keep a session alive when
/// background playback is disabled.
enum PlaybackContinuationPolicy {
    static func allowsBackgroundPlayback(backgroundAudioEnabled: Bool) -> Bool {
        backgroundAudioEnabled
    }

    static func allowsAutomaticPiP(
        backgroundAudioEnabled: Bool,
        pictureInPictureEnabled: Bool
    ) -> Bool {
        backgroundAudioEnabled && pictureInPictureEnabled
    }
}

/// One snapshot is used at each lifecycle or backend boundary so the two
/// persisted preferences cannot be observed in different revisions.
struct PlaybackContinuationConfiguration: Equatable {
    enum Mode: Equatable {
        case disabled
        case backgroundAudio
        case pictureInPicture
    }

    let backgroundAudioEnabled: Bool
    let pictureInPictureEnabled: Bool

    var mode: Mode {
        guard backgroundAudioEnabled else { return .disabled }
        return pictureInPictureEnabled ? .pictureInPicture : .backgroundAudio
    }

    var allowsBackgroundPlayback: Bool {
        PlaybackContinuationPolicy.allowsBackgroundPlayback(
            backgroundAudioEnabled: backgroundAudioEnabled
        )
    }

    var allowsAutomaticPiP: Bool {
        PlaybackContinuationPolicy.allowsAutomaticPiP(
            backgroundAudioEnabled: backgroundAudioEnabled,
            pictureInPictureEnabled: pictureInPictureEnabled
        )
    }
}

enum PlaybackContinuationApplyResult: Equatable {
    case unchanged(hostRevision: UInt64)
    case renderHostReplaced(hostRevision: UInt64)

    var hostRevision: UInt64 {
        switch self {
        case .unchanged(let revision), .renderHostReplaced(let revision):
            revision
        }
    }

    var requiresRenderAttachment: Bool {
        if case .renderHostReplaced = self { return true }
        return false
    }
}

/// Separates a SwiftUI representable update from rebuilding UIKit child-VC containment.
/// `needsReattach` depends solely on live physical containment facts (never logical
/// render generation), while the container always records the incoming generation
/// so attachment snapshots and presentation proof stay aligned.
enum InlineSurfaceBindingPolicy {
    /// Physical containment facts, read live from UIKit in the same turn the
    /// decision is made. None of these is cached or inferred state, which is
    /// what makes a genuinely destroyed surface impossible to miss: a rebuilt
    /// SwiftUI representable is a brand-new container object that hosts no
    /// controller yet, and a hosted view moved elsewhere (fullscreen, PiP,
    /// a replaced render host) fails the superview test.
    struct InlineSurfaceFacts: Equatable {
        /// A controller was passed in to host. `false` is `dismantleUIView`
        /// handing over `nil`.
        let hasIncomingController: Bool
        /// The container currently holds a hosted controller reference.
        let hasHostedController: Bool
        /// The hosted reference and the incoming controller are the same
        /// object. Object identity, never a value comparison — a replaced
        /// render host (`PlaybackContinuationApplyResult.renderHostReplaced`,
        /// or a backend hand-off) produces a different controller and lands
        /// here.
        let controllerIdentityMatches: Bool
        /// `hostedController.view.superview === container`. The one fact that
        /// cannot lie about whether this container is still showing the video:
        /// being a subview of it is the definition of the thing, not evidence
        /// for it.
        let hostedViewIsAttached: Bool
        /// `hostedController.parent != nil` — the child-VC relationship the
        /// inner drawable needs for layout and rendering lifecycle callbacks.
        /// Without it SwiftVLC's `PiPVideoView` freezes after the first frame.
        let hasLiveContainment: Bool
        /// The container is in a window, so an embed can actually complete.
        /// While it is not, `embedIfNeeded()` is a deferred no-op owned by
        /// `didMoveToWindow`, so absent containment is expected rather than
        /// broken and a teardown buys nothing.
        let containerIsInWindow: Bool
    }

    static func needsReattach(_ facts: InlineSurfaceFacts) -> Bool {
        // Nothing hosted and nothing incoming: there is no containment to
        // build or destroy.
        guard facts.hasIncomingController || facts.hasHostedController else {
            return false
        }
        // A different controller object (including nil in either direction) is
        // the only case where the hosted reference itself has to change, and
        // that assignment lives on the rebuild path.
        guard facts.controllerIdentityMatches else { return true }
        // The same controller can remain pending until didMoveToWindow.
        // Neither missing superview nor containment can be repaired off-window;
        // repeatedly retiring its reference there only repeats bookkeeping.
        guard facts.containerIsInWindow else { return false }
        // A visible container must reclaim a view moved to another host.
        guard facts.hostedViewIsAttached else { return true }
        return !facts.hasLiveContainment
    }

    /// A paused foreground return may arrive while the background settle task
    /// is still queued. In that case the coordinator returns `.schedule` even
    /// though no decoder reload should be admitted for the paused intent. A
    /// real opening/reload action owns its own reattach; the paused path only
    /// needs the containment handoff here.
    static func shouldRebindOnForeground(
        needsInlineSurfaceRebuild: Bool,
        userWantsPlaying: Bool,
        lifecycleAction: LifecycleRecoveryCoordinator.Action
    ) -> Bool {
        guard needsInlineSurfaceRebuild, !userWantsPlaying else { return false }
        switch lifecycleAction {
        case .none, .schedule:
            return true
        case .reload, .rebindInline, .reattachAndAwait:
            return false
        }
    }
}

/// Disabled continuation intentionally returns to a paused foreground without
/// reopening the stream. The explicit Play action is the first point where a
/// source-aware reopen is both safe and authorized by the user.
enum ExplicitPlaybackResumePolicy {
    static func shouldReloadBeforePlay(
        recoveryPending: Bool,
        hasVODIdentity: Bool
    ) -> Bool {
        recoveryPending && hasVODIdentity
    }
}

/// Classifies a video decoder/renderer fault as local presentation debt (repaired in
/// place without cancelling shared audio supply) whenever video is warm-suspended,
/// owned by PiP, or app-backgrounded without a visible surface.
enum DemandVideoFaultLocalityPolicy {
    static func isLocalPresentationDebt(
        subsystem: MediaRuntimeFaultSubsystem,
        videoLaneIsWarmSuspended: Bool,
        hasObservedPiPLease: Bool,
        appIsBackgrounded: Bool
    ) -> Bool {
        guard subsystem == .videoDecoder || subsystem == .videoRenderer else {
            return false
        }
        return videoLaneIsWarmSuspended || hasObservedPiPLease || appIsBackgrounded
    }
}
