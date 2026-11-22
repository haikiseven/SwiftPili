import Foundation

/// Identity of one Demand presentation-continuity transaction. The fields are
/// deliberately separate: each generation fences a different resource and a
/// render reattachment must not accidentally rotate media or PiP ownership.
struct DemandPresentationFence: Equatable {
    let lifecycleEpoch: UInt64
    let ownerKey: String
    let ownerLeaseGeneration: UInt64
    let source: DecoderRecoveryAdmission.Source
    let backendGeneration: UInt64
    let sessionGeneration: UInt64
    let renderGeneration: Int
    let pipBindingGeneration: UInt64
    /// Transport intent is carried as a decision input, not as resource
    /// identity. Authority comparisons below intentionally ignore it so a
    /// PiP pause edge can update the route without becoming a stale-resource
    /// replacement.
    let userWantsPlaying: Bool
    /// One-shot marker carried only while an explicit Play waits for the local
    /// resume effect. It avoids a second coordinator-side Boolean when the
    /// phase moves from suspended state to inline-unproven state.
    let playAfterResume: Bool
    let playbackSuppressed: Bool

    init(
        lifecycleEpoch: UInt64,
        ownerKey: String,
        ownerLeaseGeneration: UInt64,
        source: DecoderRecoveryAdmission.Source,
        backendGeneration: UInt64,
        sessionGeneration: UInt64,
        renderGeneration: Int,
        pipBindingGeneration: UInt64,
        userWantsPlaying: Bool = true,
        playAfterResume: Bool = false,
        playbackSuppressed: Bool = false
    ) {
        self.lifecycleEpoch = lifecycleEpoch
        self.ownerKey = ownerKey
        self.ownerLeaseGeneration = ownerLeaseGeneration
        self.source = source
        self.backendGeneration = backendGeneration
        self.sessionGeneration = sessionGeneration
        self.renderGeneration = renderGeneration
        self.pipBindingGeneration = pipBindingGeneration
        self.userWantsPlaying = userWantsPlaying
        self.playAfterResume = playAfterResume
        self.playbackSuppressed = playbackSuppressed
    }

    func with(
        userWantsPlaying: Bool? = nil,
        playAfterResume: Bool? = nil
    ) -> Self {
        Self(
            lifecycleEpoch: lifecycleEpoch,
            ownerKey: ownerKey,
            ownerLeaseGeneration: ownerLeaseGeneration,
            source: source,
            backendGeneration: backendGeneration,
            sessionGeneration: sessionGeneration,
            renderGeneration: renderGeneration,
            pipBindingGeneration: pipBindingGeneration,
            userWantsPlaying: userWantsPlaying ?? self.userWantsPlaying,
            playAfterResume: playAfterResume ?? self.playAfterResume,
            playbackSuppressed: playbackSuppressed
        )
    }

    func hasSameContinuityAuthority(as other: Self) -> Bool {
        lifecycleEpoch == other.lifecycleEpoch
            && ownerKey == other.ownerKey
            && ownerLeaseGeneration == other.ownerLeaseGeneration
            && source.hasSameAuthority(as: other.source)
            && backendGeneration == other.backendGeneration
            && sessionGeneration == other.sessionGeneration
            && pipBindingGeneration == other.pipBindingGeneration
    }

    func hasSameResourceAuthority(as other: Self) -> Bool {
        ownerKey == other.ownerKey
            && ownerLeaseGeneration == other.ownerLeaseGeneration
            && source.hasSameAuthority(as: other.source)
            && backendGeneration == other.backendGeneration
            && sessionGeneration == other.sessionGeneration
            && pipBindingGeneration == other.pipBindingGeneration
    }

    /// The same resource after a same-source seek: a seek advances only the
    /// session (media-work) generation. A load changes `backendGeneration`,
    /// and owner, source or PiP binding changes are different resources.
    func isSameResourceAfterSeek(of earlier: Self) -> Bool {
        ownerKey == earlier.ownerKey
            && ownerLeaseGeneration == earlier.ownerLeaseGeneration
            && source.hasSameAuthority(as: earlier.source)
            && backendGeneration == earlier.backendGeneration
            && pipBindingGeneration == earlier.pipBindingGeneration
            && sessionGeneration > earlier.sessionGeneration
    }
}

struct DemandVideoSuspendToken: Equatable, Sendable {
    /// Why the video lane was suspended. PiP stop is deliberately distinct
    /// from audio-only background so a paused PiP return can retain its exact
    /// intent without pretending that a playing-only warm-suspend guard ran.
    let reason: DemandVideoLaneSuspensionReason
    /// Playback intent at the suspension edge. A paused PiP stop carries a
    /// false value through preparation/resume; it can be changed only by the
    /// explicit-play coordinator event, never by foregrounding alone.
    let resumesPlayback: Bool
    let generation: UInt64
    let sessionGeneration: UInt64
    let audioPosition: TimeInterval
    /// Presentation-owner identity is independent from the media/session
    /// generation. A replacement screen must not be able to resume a lane
    /// prepared for the previous owner even when the underlying session was
    /// retained.
    let ownerGeneration: UInt64
    /// Monotonic video-read identity observed at the warm-suspend edge. A
    /// candidate assembled from a read that completes after this edge cannot
    /// inherit retained-at-suspend authority, even when it lands in the same
    /// packet store.
    let videoReadGeneration: UInt64
    /// Scoped video bytes observed at the warm-suspend edge. The continuity
    /// hold reports the delta from this edge rather than a literal zero.
    let videoReadBytesAtSuspend: Int

    init(
        generation: UInt64,
        sessionGeneration: UInt64,
        audioPosition: TimeInterval,
        videoReadGeneration: UInt64 = 0,
        videoReadBytesAtSuspend: Int = 0,
        ownerGeneration: UInt64 = 0,
        reason: DemandVideoLaneSuspensionReason = .audioOnlyBackground,
        resumesPlayback: Bool = true
    ) {
        self.reason = reason
        self.resumesPlayback = resumesPlayback
        self.generation = generation
        self.sessionGeneration = sessionGeneration
        self.audioPosition = audioPosition
        self.ownerGeneration = ownerGeneration
        self.videoReadGeneration = videoReadGeneration
        self.videoReadBytesAtSuspend = videoReadBytesAtSuspend
    }
}

/// A busy source transition is not an unsupported media topology. The App
/// retries deferred suspension at the existing ready/seek-completion edge.
enum DemandVideoSuspensionResult: Equatable {
    case suspended(DemandVideoSuspendToken)
    case deferred
    case unsupported
}

/// Local suspension authority for a Demand video lane. This is not a player
/// park and it never authorizes a source/open replacement. PiP stop has its
/// own reason because it can arrive while PiP/user controls left playback
/// paused; that state must be prepared only after an explicit Play.
enum DemandVideoLaneSuspensionReason: String, Equatable, Sendable {
    case audioOnlyBackground
    case pipDidStop
}

/// Total result of one post-resume image-hold release observation. `waiting`
/// keeps the hold authority and its video-supply gate. `released` means the
/// audio due boundary was reached (only once for a hold). `refreshRequired`
/// atomically abandons stale hold/proof debt and hands the same suspended lane
/// back to strict video-only positioning.
enum WarmVideoImageHoldReleaseOutcome: Equatable, Sendable {
    case waiting
    case released
    case refreshRequired
}

struct DemandPresentationProof: Equatable {
    let fence: DemandPresentationFence
    let mediaTime: TimeInterval
    let rendererReady: Bool
}

struct DemandPresentationSample: Equatable, Sendable {
    let sessionGeneration: UInt64
    let renderGeneration: Int
    let mediaTime: TimeInterval
    let rendererReady: Bool
}

/// Presentation progress evidence is a monotonic admission witness, not a
/// cumulative frame counter. The uptime makes a long healthy prefix unable to
/// certify a frozen tail during PiP activation.
struct DemandPresentationProgressWitness: Equatable, Sendable {
    let serial: UInt64
    let lastProgressUptime: TimeInterval?
}

enum DemandPresentationProgressPolicy {
    /// One full pipe window plus margin. A PiP edge with no newly admitted
    /// frame inside this interval must use the local reconcile path.
    static let freshnessWindowSeconds: TimeInterval = 1.5

    static func isRecent(
        current: DemandPresentationProgressWitness,
        since baseline: DemandPresentationProgressWitness,
        nowUptime: TimeInterval,
        within window: TimeInterval = freshnessWindowSeconds
    ) -> Bool {
        guard current.serial != baseline.serial,
              let lastProgress = current.lastProgressUptime,
              lastProgress.isFinite,
              nowUptime.isFinite,
              window.isFinite,
              window > 0,
              lastProgress <= nowUptime else {
            return false
        }
        let age = nowUptime - lastProgress
        return age.isFinite && age >= 0 && age <= window
    }
}

/// The health/watchdog layer may consume presentation proof only for the exact
/// lifecycle transaction and render destination it is currently evaluating.
/// A numerically reused render generation is intentionally insufficient: a new
/// lifecycle epoch invalidates every pre-background frame fact.
struct DemandPresentationLivenessAuthority: Equatable {
    private struct Scope: Equatable {
        let lifecycleEpoch: UInt64
        let sessionGeneration: UInt64
        let renderGeneration: Int

        init(_ fence: DemandPresentationFence) {
            lifecycleEpoch = fence.lifecycleEpoch
            sessionGeneration = fence.sessionGeneration
            renderGeneration = fence.renderGeneration
        }
    }

    private var expected: Scope?
    private var proved: Scope?

    var hasCurrentProof: Bool {
        expected != nil && expected == proved
    }

    mutating func begin(_ fence: DemandPresentationFence) {
        expected = Scope(fence)
        proved = nil
    }

    /// Environment notifications do not create new presentation debt while
    /// native PiP remains the destination. Keeping the existing scope here
    /// preserves the lease/proof authority across lock/unlock; the separate
    /// PiP reconciliation event may still perform a renderer-local repair
    /// without reserving a new inline/warm destination.
    mutating func begin(
        _ fence: DemandPresentationFence,
        preservingExistingProof: Bool
    ) {
        if preservingExistingProof {
            let carriesProof = hasCurrentProof
            let scope = Scope(fence)
            expected = scope
            proved = carriesProof ? scope : nil
            return
        }
        begin(fence)
    }

    mutating func prove(_ fence: DemandPresentationFence) {
        let scope = Scope(fence)
        guard expected == scope else { return }
        proved = scope
    }

    mutating func invalidate() {
        expected = nil
        proved = nil
    }
}

enum DemandPresentationHealth: Equatable {
    case visible(DemandPresentationProof)
    case attachedButUnproven
    case warmSuspended
    case needsFlush
    case rendererFailed
    case decoderInvalid
    case missingSurface
}

enum DemandPiPStopAuthority: Equatable, Sendable {
    case userRestore
    case userStop
    case capabilityRevocation
    case ownerTeardown
    case mediaEnded
    case systemStop

    var isForcedRetirement: Bool {
        switch self {
        case .capabilityRevocation, .ownerTeardown, .mediaEnded:
            true
        case .userRestore, .userStop, .systemStop:
            false
        }
    }
}

enum DemandPiPNativeEvent: String, Equatable, Sendable {
    case willStart
    case didStart
    case failedToStart
    case willStop
    case didStop
}

struct DemandPiPNativeTransition: Equatable, Sendable {
    let event: DemandPiPNativeEvent
    let bindingGeneration: UInt64
}

enum DemandPresentationFailure: String, Equatable, Sendable {
    case unsupportedVideoContinuity
    case rendererRecoveryExhausted
    case decoderRecoveryFailed
    case decoderPreparationExhausted
    /// The one local warm-preparation deadline elapsed while demux/decode
    /// remained unresolved. This is presentation-local and never authorizes a
    /// source reopen or another recovery rung.
    case warmPreparationTimedOut
    case staleAuthority
    case retired
}

/// Closed result for one foreground video-lane preparation transaction.
/// `cancelled` is an authority handoff, not a failure belonging to the old
/// lifecycle fence. A terminal failure is deliberately typed so the caller
/// cannot turn a decoder debt into an indefinite warm-suspended state.
enum DemandVideoLanePreparationResult: Equatable, Sendable {
    case prepared
    case cancelled
    case failed(DemandPresentationFailure)

    var isPrepared: Bool { self == .prepared }
}

struct DemandPiPStopTransaction: Equatable {
    let fence: DemandPresentationFence
    let authority: DemandPiPStopAuthority
    var nativeDidStop: Bool
}

struct DemandInlineRestoreTransaction: Equatable {
    let fence: DemandPresentationFence
    /// AVKit supplies a token for a delegate-driven restore. The automatic
    /// foreground handoff has no AVKit completion to answer; it uses the same
    /// inline preparation transaction but leaves this nil.
    var completionToken: UInt64?
    /// Automatic foreground restoration prepares the inline destination before
    /// asking native PiP to stop. AVKit-driven restoration leaves this nil
    /// because AVKit owns the stop request after its completion handler.
    let nativeStopAuthority: DemandPiPStopAuthority?
    var inlineAttached: Bool
    var avKitCompletionSent: Bool
    var nativeDidStop: Bool
    /// Coalesces repeated attachment/layout callbacks while the native stop is
    /// still pending. It is separate from `nativeDidStop`: the request and the
    /// native completion are distinct lifecycle edges.
    var nativeStopRequested = false
}

struct DemandWarmSuspensionState: Equatable {
    var fence: DemandPresentationFence
    var token: DemandVideoSuspendToken?
    var prepareWhenSuspended: Bool
    var isPrepared: Bool
    /// Whether a foreground edge may resume playback automatically. Audio-only
    /// warm suspension is entered from a playing transport; PiP stop can be
    /// entered from a paused PiP transport and must retain that veto.
    var shouldResumePlayback: Bool = true
    var reason: DemandVideoLaneSuspensionReason = .audioOnlyBackground
    /// Set by an explicit user Play while this suspended lane is paused. The
    /// local prepare/resume transaction owns the eventual play effect; no
    /// direct backend.play may bypass it.
    var explicitPlayRequested: Bool = false
    /// The retained preparation COMPLETED while presentation was still
    /// inactive, so its GOP was positioned against an audio clock that has
    /// since moved. Before committing that work to a visible render
    /// destination, `didBecomeActive` performs one cheap current-audio
    /// validation through the same topology-local preparation seam.
    ///
    /// Set by `videoLanePrepared`, which is the only event that knows whether
    /// a preparation result predates the active edge. A new background
    /// destination clears it together with the other retired preparation facts.
    /// It was previously set at preparation-REQUEST time and cleared by each
    /// consumer that noticed the request had not landed yet; a request that
    /// `didBecomeActive` overtook then kept the flag and bought a second,
    /// redundant preparation round-trip inside the visible window — the exact
    /// foreground hitch this transaction exists to remove.
    var preparedWhileInactive = false
    var activeValidationRequested = false
    var attachRequested = false
    var inlineAttached = false
    /// The one outstanding suspend effect may acknowledge after an allowed
    /// environment epoch changes. Preserve its original authority only while
    /// the same resources still own this suspension; other old callbacks do
    /// not inherit this exception.
    var suspensionAcknowledgementFence: DemandPresentationFence?
    /// Video-local failure leaves the retained audio transport actionable.
    /// An explicit Retry owns source recovery; ordinary Play only resumes audio.
    var videoFailure: DemandPresentationFailure?
}

enum DemandVideoPresentationPhase: Equatable {
    case idle
    case pausedInline(DemandPresentationFence)
    case inlineVisible(DemandPresentationProof)
    case inlineNeedsAttachment(DemandPresentationFence)
    case inlineAttachPending(DemandPresentationFence)
    case inlineAttachedUnproven(DemandPresentationFence)
    case warmSuspendingForAudioOnly(DemandWarmSuspensionState)
    case warmSuspended(DemandWarmSuspensionState)
    case pipStarting(DemandPresentationFence)
    case pipStartFailed(DemandPresentationFence)
    case pipActive(DemandPresentationFence)
    case pipStopping(DemandPiPStopTransaction)
    case restoringInline(DemandInlineRestoreTransaction)
    case failed(DemandPresentationFence?, DemandPresentationFailure)

    var fence: DemandPresentationFence? {
        switch self {
        case .idle:
            nil
        case .pausedInline(let fence),
             .inlineNeedsAttachment(let fence),
             .inlineAttachPending(let fence),
             .inlineAttachedUnproven(let fence),
             .pipStarting(let fence),
             .pipStartFailed(let fence),
             .pipActive(let fence):
            fence
        case .inlineVisible(let proof):
            proof.fence
        case .warmSuspendingForAudioOnly(let state), .warmSuspended(let state):
            state.fence
        case .pipStopping(let transaction):
            transaction.fence
        case .restoringInline(let transaction):
            transaction.fence
        case .failed(let fence, _):
            fence
        }
    }

    /// Case name for the dropped-event report. Deliberately hand-written rather
    /// than reflected: a name that appears in a device capture is part of the
    /// diagnostic contract, and `String(describing:)` would drag whole payloads
    /// into a log line that has to stay one line.
    var diagnosticName: String {
        switch self {
        case .idle: "idle"
        case .pausedInline: "pausedInline"
        case .inlineVisible: "inlineVisible"
        case .inlineNeedsAttachment: "inlineNeedsAttachment"
        case .inlineAttachPending: "inlineAttachPending"
        case .inlineAttachedUnproven: "inlineAttachedUnproven"
        case .warmSuspendingForAudioOnly: "warmSuspendingForAudioOnly"
        case .warmSuspended: "warmSuspended"
        case .pipStarting: "pipStarting"
        case .pipStartFailed: "pipStartFailed"
        case .pipActive: "pipActive"
        case .pipStopping: "pipStopping"
        case .restoringInline: "restoringInline"
        case .failed: "failed"
        }
    }
}

extension DemandPresentationEvent {
    /// Name and fence for the dropped-event report in
    /// `PlayerViewModel.dispatchDemandPresentation`.
    ///
    /// Events with no fence return `nil` and are not reported: they are
    /// unconditional (`teardown`, `playbackEnded`) and reducing to no effects
    /// is an ordinary outcome for them, not a rejection.
    var diagnosticFence: DemandPresentationFence? {
        switch self {
        case .playbackEnded, .explicitReplay, .teardown:
            nil
        case .installInline(let fence),
             .foregroundTransitionBegan(let fence),
             .didBecomeActive(let fence),
             .inlineAttached(let fence),
             .inlineDetached(let fence),
             .inlineAttachmentFailed(let fence),
             .pipWillStart(let fence),
             .pipDidStart(let fence),
             .pipStartAbandoned(let fence),
             .pipFailedToStart(let fence),
             .pipWillStop(let fence),
             .pipDidStop(let fence),
             .pipPresentationNeedsReconcile(let fence),
             .pipPresentationReconciled(let fence),
             .pipPresentationReconcileFailed(let fence, _),
             .transportSuppressed(let fence),
             .explicitPlayRequested(let fence),
             .videoLaneSuspensionMayProceed(let fence),
             .videoLaneSeekCommitted(let fence, _):
            fence
        case .didEnterBackground(_, _, let fence, _):
            fence
        case .videoLaneSuspended(let fence, _),
             .videoLanePrepared(let fence, _),
             .videoLaneResumed(let fence, _):
            fence
        case .videoLanePreparationFailed(let fence, _, _):
            fence
        case .videoFailureKeptAudio(let fence, _, _):
            fence
        case .videoLaneResumeFailed(let fence, _):
            fence
        case .pipTransportIntent(let fence, _),
             .requestPiPStop(let fence, _),
             .forceRetirePiP(let fence, _),
             .prepareInlineForPiPStop(let fence, _),
             .restoreInlineRequested(let fence, _),
             .rendererHealthChanged(let fence, _),
             .runtimeVideoFault(let fence, _):
            fence
        case .presentationProved(let proof):
            proof.fence
        }
    }

    /// See `DemandVideoPresentationPhase.diagnosticName` for why this is
    /// written out rather than reflected.
    var diagnosticName: String {
        switch self {
        case .playbackEnded: "playbackEnded"
        case .explicitReplay: "explicitReplay"
        case .installInline: "installInline"
        case .didEnterBackground: "didEnterBackground"
        case .foregroundTransitionBegan: "foregroundTransitionBegan"
        case .didBecomeActive: "didBecomeActive"
        case .videoLaneSuspended: "videoLaneSuspended"
        case .videoLaneSuspensionMayProceed: "videoLaneSuspensionMayProceed"
        case .videoFailureKeptAudio: "videoFailureKeptAudio"
        case .videoLanePrepared: "videoLanePrepared"
        case .videoLanePreparationFailed: "videoLanePreparationFailed"
        case .videoLaneResumed: "videoLaneResumed"
        case .videoLaneResumeFailed: "videoLaneResumeFailed"
        case .inlineAttached: "inlineAttached"
        case .inlineDetached: "inlineDetached"
        case .inlineAttachmentFailed: "inlineAttachmentFailed"
        case .pipWillStart: "pipWillStart"
        case .pipDidStart: "pipDidStart"
        case .pipStartAbandoned: "pipStartAbandoned"
        case .pipTransportIntent: "pipTransportIntent"
        case .pipFailedToStart: "pipFailedToStart"
        case .requestPiPStop: "requestPiPStop"
        case .forceRetirePiP: "forceRetirePiP"
        case .prepareInlineForPiPStop: "prepareInlineForPiPStop"
        case .restoreInlineRequested: "restoreInlineRequested"
        case .pipWillStop: "pipWillStop"
        case .pipDidStop: "pipDidStop"
        case .pipPresentationNeedsReconcile: "pipPresentationNeedsReconcile"
        case .pipPresentationReconciled: "pipPresentationReconciled"
        case .pipPresentationReconcileFailed: "pipPresentationReconcileFailed"
        case .rendererHealthChanged: "rendererHealthChanged"
        case .presentationProved: "presentationProved"
        case .runtimeVideoFault: "runtimeVideoFault"
        case .teardown: "teardown"
        case .transportSuppressed: "transportSuppressed"
        case .explicitPlayRequested: "explicitPlayRequested"
        case .videoLaneSeekCommitted: "videoLaneSeekCommitted"
        }
    }
}

enum DemandPresentationApplicationPhase: Equatable, Sendable {
    case active
    case foregroundTransitioning
    case background
}

enum DemandPresentationRecoveryStage: Int, Equatable, Sendable {
    case retainedRenderer = 0
    case rendererFlushed = 1
    case decoderRecreated = 2
    case exhausted = 3
}

enum DemandPresentationEvent: Equatable {
    /// Natural media end is terminal admission, not a lifecycle failure. It
    /// retires presentation debt so later environment events cannot warm
    /// suspend or attempt recovery against an ended session.
    case playbackEnded
    /// User-explicit replay starts a fresh normal presentation transaction.
    /// The effect adapter intentionally emits no recovery effect here; the
    /// ViewModel's ordinary load path owns reopening at the canonical origin.
    case explicitReplay
    case installInline(fence: DemandPresentationFence)
    case didEnterBackground(
        configuration: PlaybackContinuationConfiguration,
        observedPiPLease: Bool,
        fence: DemandPresentationFence,
        userWantsPlaying: Bool
    )
    case foregroundTransitionBegan(fence: DemandPresentationFence)
    case didBecomeActive(fence: DemandPresentationFence)
    case videoLaneSuspended(fence: DemandPresentationFence, token: DemandVideoSuspendToken)
    case videoLaneSuspensionMayProceed(fence: DemandPresentationFence)
    case videoFailureKeptAudio(
        fence: DemandPresentationFence,
        token: DemandVideoSuspendToken,
        failure: DemandPresentationFailure
    )
    case videoLanePrepared(fence: DemandPresentationFence, token: DemandVideoSuspendToken)
    /// The failing twin of `videoLanePrepared`, and it must be accepted the
    /// same way that one is.
    ///
    /// Media-lane PREPARATION is destination-agnostic — it repositions a reader
    /// and decodes, and knows nothing about which render generation will
    /// eventually display the result. `videoLaneResumeFailed` is matched on
    /// exact render generation, which is right for the attach/resume/renderer-
    /// health failures it was written for and wrong for this one: a foreground
    /// return reserves render N+1 in `didBecomeActive` while the preparation is
    /// still in flight under render N, so the preparation's own failure was
    /// rejected against a destination that only the preparation's SUCCESS could
    /// have created. Device 2026-09-10 (BV19UFjz9E7T): prepare emitted under
    /// render 4, phase moved to render 5, the 5 s timeout settled nothing, and
    /// the session sat black with no Retry and no log until the user left.
    case videoLanePreparationFailed(
        fence: DemandPresentationFence,
        token: DemandVideoSuspendToken,
        failure: DemandPresentationFailure
    )
    case videoLaneResumed(fence: DemandPresentationFence, token: DemandVideoSuspendToken)
    case videoLaneResumeFailed(fence: DemandPresentationFence, failure: DemandPresentationFailure)
    case inlineAttached(fence: DemandPresentationFence)
    case inlineDetached(fence: DemandPresentationFence)
    case inlineAttachmentFailed(fence: DemandPresentationFence)
    case pipWillStart(fence: DemandPresentationFence)
    case pipDidStart(fence: DemandPresentationFence)
    /// The application returned while a native start request still had no
    /// terminal callback. This is a local ownership decision, not a synthetic
    /// native didStop: detach the pending controller and reclaim inline.
    case pipStartAbandoned(fence: DemandPresentationFence)
    case pipTransportIntent(fence: DemandPresentationFence, userWantsPlaying: Bool)
    case pipFailedToStart(fence: DemandPresentationFence)
    case requestPiPStop(fence: DemandPresentationFence, authority: DemandPiPStopAuthority)
    case forceRetirePiP(fence: DemandPresentationFence, authority: DemandPiPStopAuthority)
    /// Automatic foreground return uses the same inline restoration contract
    /// as the AVKit delegate, but without fabricating an AVKit completion token.
    /// The native stop request is emitted only after `.inlineAttached`.
    case prepareInlineForPiPStop(
        fence: DemandPresentationFence,
        authority: DemandPiPStopAuthority
    )
    case restoreInlineRequested(fence: DemandPresentationFence, completionToken: UInt64)
    case pipWillStop(fence: DemandPresentationFence)
    case pipDidStop(fence: DemandPresentationFence)
    /// Re-check the PiP display layer after an inactive/active edge. The lease
    /// remains authoritative; this event only admits a renderer-local repair
    /// when the session's edge snapshot says that presentation may be stale.
    case pipPresentationNeedsReconcile(fence: DemandPresentationFence)
    /// Completion of the renderer-local reconcile. Only this event may advance
    /// the active PiP transaction into inline preparation for user restore.
    case pipPresentationReconciled(fence: DemandPresentationFence)
    case pipPresentationReconcileFailed(
        fence: DemandPresentationFence,
        failure: DemandPresentationFailure
    )
    case rendererHealthChanged(fence: DemandPresentationFence, health: DemandPresentationHealth)
    case presentationProved(DemandPresentationProof)
    case runtimeVideoFault(fence: DemandPresentationFence, decoderInvalid: Bool)
    case teardown
    /// A user Play is an explicit request to leave the paused PiP-stop local
    /// suspension. It is not itself a transport command; the coordinator emits
    /// prepare/resume/play effects in order.
    case transportSuppressed(fence: DemandPresentationFence)
    case explicitPlayRequested(fence: DemandPresentationFence)
    /// A same-source seek committed while a local video-lane suspension owns
    /// presentation. The seek advanced the session generation, so the
    /// suspension (token and fence) is re-issued under it. `resumesPlayback`
    /// is the ViewModel's existing post-seek auto-revive decision.
    case videoLaneSeekCommitted(fence: DemandPresentationFence, resumesPlayback: Bool)
}

enum DemandPresentationEffect: Equatable {
    case resumeSuspendedAudio(DemandPresentationFence, DemandVideoSuspendToken)
    case warmSuspendVideoLane(DemandPresentationFence)
    case suspendVideoLaneAfterPiPStop(DemandPresentationFence)
    case prepareVideoLaneForForeground(DemandPresentationFence, DemandVideoSuspendToken)
    case attachInline(DemandPresentationFence)
    case attachPausedInline(DemandPresentationFence)
    case resumeVideoLane(DemandPresentationFence, DemandVideoSuspendToken)
    case playDemandVideoLane(DemandPresentationFence)
    case restoreInlinePresentation(DemandPresentationFence)
    case requestPiPStop(DemandPresentationFence, DemandPiPStopAuthority)
    case forceRetirePiP(DemandPresentationFence, DemandPiPStopAuthority)
    case abandonPiPStart(DemandPresentationFence)
    case reconcilePiPPresentation(DemandPresentationFence)
    case completeAVKitRestore(token: UInt64, success: Bool)
    case flushAndPrimeRenderer(DemandPresentationFence)
    case recreateVideoDecoder(DemandPresentationFence)
    case settlePresentation(DemandPresentationProof)
    /// The fence is NOT optional. Both producers — `videoLaneResumeFailed` and
    /// the stale-authority path — have already accepted a concrete fence before
    /// they settle a failure, and the stage tape keyed on it (Move 3) requires
    /// one. It was declared optional and never emitted as nil; the Mac compile
    /// found the mismatch at the consumer. Narrowed rather than widening the
    /// consumer, so no branch exists for a state that cannot be produced.
    case settleFailure(DemandPresentationFence, DemandPresentationFailure)
    case pauseForContinuationPolicy(DemandPresentationFence)
}

/// Where an application activation should point presentation liveness.
///
/// The distinction exists because `didBecomeActive` does NOT reserve a new
/// render destination for every phase. Assuming it does — reserving
/// `playerGeneration + 1` unconditionally — begins a debt at a generation the
/// reducer never advances to, so a later genuine renderer proof arrives at the
/// current generation, is accepted by the reducer, and is then rejected by the
/// liveness authority whose `expected` scope can never be reached. The session
/// then reads `frames-never-proven` for a surface the user can plainly see.
enum DemandForegroundPresentationDestination: Equatable, Sendable {
    /// Native PiP owns presentation; the environment change reserves nothing
    /// and must not disturb the lease or its proof. A separate activation
    /// reconciliation may repair the shared renderer in place.
    case preservedPiP
    /// The inline destination is unchanged, and an existing proof for it
    /// remains valid across the environment epoch.
    case retainedPassiveInline
    /// Nothing is attached and no proof applies. Re-arm at the CURRENT
    /// generation so the debt is provable rather than fabricated.
    case unprovenPassiveInline
    /// The activation reserves a NEW inline or warm destination, so the
    /// generation advances and any prior proof is void.
    case reservedNewInline
}

extension LifecycleRecoveryCoordinator {
    /// The PiP-to-inline handoff owns the visual transition from the native
    /// rounded PiP surface to the rectangular inline player. A delegate-driven
    /// restore can arrive before `didBecomeActive`, so `restoringInline` is
    /// always covered; the automatic `pipActive`/`pipStopping` path starts
    /// coverage at the active edge. Keep this derived from coordinator state so
    /// the UI does not invent a second timer or flag that can outlive the native
    /// `didStop` edge.
    var isPiPRestoringInline: Bool {
        switch presentationPhase {
        case .restoringInline:
            return true
        case .pipActive, .pipStopping:
            return presentationApplicationPhase == .active
        default:
            return false
        }
    }

    /// Last user transport intent observed while native PiP owns the route.
    /// It is separate from the route itself so a real `didStop` can choose the
    /// correct local suspension contract even when PiP was paused.
    var hasPendingDemandExplicitPlay: Bool {
        switch presentationPhase {
        case .warmSuspendingForAudioOnly(let state), .warmSuspended(let state):
            return state.explicitPlayRequested
        case .inlineAttachedUnproven(let fence):
            return fence.playAfterResume
        default:
            return false
        }
    }

    /// Classify what `didBecomeActive` will actually do, so the ViewModel can
    /// arm liveness against the destination the reducer really reserves.
    ///
    /// Exhaustive on purpose: a new presentation phase must be classified here,
    /// not silently defaulted into fabricating a generation.
    var foregroundPresentationDestination: DemandForegroundPresentationDestination {
        if terminalState.isTerminal { return .unprovenPassiveInline }
        return RenderDestinationDecision(phase: presentationPhase).foregroundDestination
    }

    /// Native PiP still owns presentation until its real `didStop`. Repeated
    /// application lifecycle notifications must not invalidate the proof that
    /// grants the existing PiP route its liveness authority. An explicit
    /// restore has already reserved its own scope through `attachInline`.
    var preservesPresentationLivenessAcrossEnvironmentChange: Bool {
        guard !terminalState.isTerminal else { return false }
        switch presentationPhase {
        case .pipActive, .pipStopping, .restoringInline:
            return true
        case .idle, .pausedInline, .inlineVisible, .inlineAttachedUnproven,
             .warmSuspendingForAudioOnly, .warmSuspended, .pipStarting,
             .pipStartFailed, .inlineNeedsAttachment, .inlineAttachPending,
             .failed:
            return false
        }
    }

    /// The presentation half of the lifecycle transaction. It deliberately
    /// lives on the existing coordinator so application notifications, PiP
    /// callbacks and renderer proof cannot become parallel recovery owners.
    mutating func reducePresentation(
        _ event: DemandPresentationEvent
    ) -> [DemandPresentationEffect] {
        if terminalState.isTerminal {
            switch event {
            case .playbackEnded:
                return []
            case .explicitReplay, .teardown:
                break
            default:
                // A terminal session has no lifecycle/presentation admission.
                // In particular, EOF with an empty runway cannot create a warm
                // suspend, decoder repair, attachment debt, or failure.
                return []
            }
        }

        switch event {
        case .playbackEnded:
            markPlaybackEnded()
            return []

        case .explicitReplay:
            clearTerminalForReplay()
            return []

        case .installInline(let fence):
            installPresentationAuthority(fence)
            pipStartWasAbandoned = false
            pipPresentationReconcilePending = false
            presentationPhase = .inlineAttachedUnproven(
                fence.with(playAfterResume: false)
            )
            presentationRecoveryStage = .retainedRenderer
            return []

        case let .didEnterBackground(configuration, observedPiPLease, fence, wantsPlaying):
            let nativePiPStartPending: Bool
            switch presentationPhase {
            case .pipStarting(let current):
                nativePiPStartPending = current.hasSameResourceAuthority(as: fence)
            default:
                nativePiPStartPending = false
            }
            installPresentationAuthority(fence)
            presentationApplicationPhase = .background
            presentationRecoveryStage = .retainedRenderer
            pipPresentationReconcilePending = false
            if configuration.mode != .disabled,
               !observedPiPLease,
               !nativePiPStartPending {
                switch presentationPhase {
                case .warmSuspendingForAudioOnly(var state)
                    where state.fence.hasSameResourceAuthority(as: fence),
                     .warmSuspended(var state)
                    where state.fence.hasSameResourceAuthority(as: fence):
                    if state.token == nil, state.suspensionAcknowledgementFence == nil {
                        state.suspensionAcknowledgementFence = state.fence
                    }
                    let resumesPendingPlayAudio = state.explicitPlayRequested
                        && state.shouldResumePlayback && state.prepareWhenSuspended
                        && wantsPlaying && fence.userWantsPlaying && !fence.playbackSuppressed
                    // The session remains locally suspended. A new environment
                    // fence retires destination/preparation facts, not its
                    // token or the user's paused/explicit-Play intent.
                    state.fence = fence
                    state.prepareWhenSuspended = false
                    state.isPrepared = false
                    state.preparedWhileInactive = false
                    state.activeValidationRequested = false
                    state.attachRequested = false
                    state.inlineAttached = false
                    presentationPhase = state.token == nil
                        ? .warmSuspendingForAudioOnly(state)
                        : .warmSuspended(state)
                    if resumesPendingPlayAudio, let token = state.token {
                        // Foreground Play already owns this request, but its
                        // pending video prepare no longer has a destination.
                        // Continue audio once; clearing prepareWhenSuspended
                        // above coalesces repeated background notifications.
                        return [.resumeSuspendedAudio(fence, token)]
                    }
                    return []
                default:
                    break
                }
            }
            switch configuration.mode {
            case .disabled:
                presentationPhase = .pausedInline(fence)
                return [.pauseForContinuationPolicy(fence)]
            case .backgroundAudio:
                if observedPiPLease || nativePiPStartPending {
                    presentationPhase = observedPiPLease ? .pipActive(fence) : .pipStarting(fence)
                    return []
                }
                return beginAudioOnlySuspension(fence: fence, resumesPlayback: wantsPlaying)
            case .pictureInPicture:
                if observedPiPLease {
                    presentationPhase = .pipActive(fence)
                } else if case .pipActive(let current) = presentationPhase,
                          current.hasSameContinuityAuthority(as: fence) {
                    // A didStart edge won the race with the application event.
                    presentationPhase = .pipActive(current)
                } else if nativePiPStartPending {
                    presentationPhase = .pipStarting(fence)
                } else {
                    // A preference is not a native PiP lease. Retain audio
                    // until a real willStart/didStart edge owns video output.
                    return beginAudioOnlySuspension(fence: fence, resumesPlayback: wantsPlaying)
                }
                return []
            }

        case .foregroundTransitionBegan(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            presentationApplicationPhase = .foregroundTransitioning
            switch presentationPhase {
            case .pipActive, .pipStopping, .restoringInline:
                return []
            case .warmSuspendingForAudioOnly(var state):
                if state.shouldResumePlayback { state.prepareWhenSuspended = true }
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return []
            case .warmSuspended(var state):
                if state.videoFailure != nil { return [] }
                if !state.shouldResumePlayback {
                    state.fence = fence
                    guard !state.attachRequested else { return [] }
                    state.attachRequested = true
                    presentationPhase = .warmSuspended(state)
                    return [.attachPausedInline(fence)]
                }
                guard let token = state.token,
                      !state.prepareWhenSuspended,
                      !state.isPrepared else { return [] }
                state.prepareWhenSuspended = true
                presentationPhase = .warmSuspended(state)
                return [.prepareVideoLaneForForeground(state.fence, token)]
            default:
                return []
            }

        case .didBecomeActive(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            presentationApplicationPhase = .active
            switch presentationPhase {
            case .pipActive(let currentFence):
                // The native lease remains the same, but an inline container
                // may have been replaced while PiP owned presentation. Adopt
                // the current render destination before the activation
                // reconcile so its exact-render fence is not rejected as
                // stale. This does not create a new PiP binding or session.
                if currentFence.renderGeneration != fence.renderGeneration {
                    presentationPhase = .pipActive(fence)
                }
                return []
            case .pipStopping, .restoringInline:
                return []
            case .pausedInline:
                presentationPhase = .pausedInline(fence)
                return [.attachPausedInline(fence)]
            case .warmSuspendingForAudioOnly(var state):
                // didBecomeActive reserves the foreground render destination
                // even when suspension/preparation has not acknowledged yet.
                // Late callbacks keep media authority through the continuity
                // fence, while the eventual attach must use this new render
                // generation rather than the background destination.
                state.fence = fence
                if state.shouldResumePlayback {
                    state.prepareWhenSuspended = true
                } else if !state.attachRequested {
                    state.attachRequested = true
                    presentationPhase = .warmSuspendingForAudioOnly(state)
                    return [.attachPausedInline(fence)]
                }
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return []
            case .warmSuspended(var state):
                let destinationChanged = state.fence.renderGeneration
                    != fence.renderGeneration
                state.fence = fence
                if destinationChanged {
                    state.attachRequested = false
                    state.inlineAttached = false
                }
                guard !state.attachRequested else { return [] }
                if state.videoFailure != nil {
                    state.attachRequested = true
                    presentationPhase = .warmSuspended(state)
                    return [.attachPausedInline(fence)]
                }
                if !state.shouldResumePlayback {
                    state.attachRequested = true
                    presentationPhase = .warmSuspended(state)
                    return [.attachPausedInline(fence)]
                }
                guard state.isPrepared else {
                    if !state.prepareWhenSuspended {
                        state.prepareWhenSuspended = true
                        presentationPhase = .warmSuspended(state)
                        guard let token = state.token else { return [] }
                        return [.prepareVideoLaneForForeground(fence, token)]
                    }
                    presentationPhase = .warmSuspended(state)
                    return []
                }
                if state.preparedWhileInactive,
                   !state.activeValidationRequested,
                   let token = state.token {
                    state.isPrepared = false
                    state.activeValidationRequested = true
                    presentationPhase = .warmSuspended(state)
                    return [.prepareVideoLaneForForeground(fence, token)]
                }
                state.attachRequested = true
                presentationPhase = .warmSuspended(state)
                return [.attachInline(fence)]
            case .pipStarting:
                // No native lease ever became authoritative. Reclaim only the
                // inline presentation; source/session ownership is unchanged.
                presentationPhase = .inlineAttachPending(fence)
                return [.attachInline(fence)]
            case .pipStartFailed:
                presentationPhase = .inlineAttachPending(fence)
                return [.attachInline(fence)]
            case .inlineNeedsAttachment:
                presentationPhase = .inlineAttachPending(fence)
                return [.attachInline(fence)]
            case .inlineAttachPending, .inlineAttachedUnproven, .inlineVisible:
                return []
            default:
                return []
            }

        case let .videoLaneSuspensionMayProceed(fence):
            guard case .warmSuspendingForAudioOnly(var state) = presentationPhase,
                  state.token == nil,
                  state.fence.hasSameResourceAuthority(as: fence)
                    || fence.isSameResourceAfterSeek(of: state.fence) else { return [] }
            state.fence = fence
            state.suspensionAcknowledgementFence = fence
            presentationPhase = .warmSuspendingForAudioOnly(state)
            return [state.reason == .pipDidStop
                ? .suspendVideoLaneAfterPiPStop(fence)
                : .warmSuspendVideoLane(fence)]

        case let .videoFailureKeptAudio(fence, token, failure):
            guard acceptsPresentationEvent(fence),
                  case .failed = presentationPhase,
                  token.sessionGeneration == fence.sessionGeneration,
                  token.ownerGeneration == fence.backendGeneration else { return [] }
            var state = DemandWarmSuspensionState(
                fence: fence,
                token: token,
                prepareWhenSuspended: false,
                isPrepared: false,
                shouldResumePlayback: fence.userWantsPlaying && !fence.playbackSuppressed,
                reason: token.reason
            )
            state.videoFailure = failure
            presentationPhase = .warmSuspended(state)
            presentationRecoveryStage = .exhausted
            return []

        case let .videoLaneSuspended(fence, token):
            guard token.sessionGeneration == fence.sessionGeneration else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly(var state):
                let pendingFence = state.suspensionAcknowledgementFence ?? state.fence
                guard state.fence.hasSameResourceAuthority(as: fence),
                      pendingFence.hasSameContinuityAuthority(as: fence) else { return [] }
                state.suspensionAcknowledgementFence = nil
                state.token = token
                state.reason = token.reason
                // An explicit Play may arrive before the suspension effect has
                // returned its token. Preserve that newer user authority over
                // the token's paused-at-suspend snapshot; otherwise the late
                // acknowledgement would silently turn the pending prepare
                // back into a non-resuming paused lane.
                state.shouldResumePlayback = state.explicitPlayRequested
                    ? true
                    : (state.shouldResumePlayback && token.resumesPlayback)
                presentationPhase = .warmSuspended(state)
                if state.explicitPlayRequested, presentationApplicationPhase == .background {
                    return [.resumeSuspendedAudio(state.fence, token)]
                }
                if state.prepareWhenSuspended && state.shouldResumePlayback {
                    return [.prepareVideoLaneForForeground(state.fence, token)]
                }
                return []
            case .warmSuspended(let state)
                where acceptsPresentationEvent(fence) && state.token == token:
                return []
            default:
                return []
            }

        case let .videoLanePrepared(fence, token):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspended(var state) where state.token == token && state.videoFailure == nil:
                state.isPrepared = true
                // The sole writer. A result that lands while the application
                // is already active was positioned against the live audio
                // clock and needs no second validation; only a result banked
                // while inactive does.
                state.preparedWhileInactive = presentationApplicationPhase != .active
                presentationPhase = .warmSuspended(state)
                if presentationApplicationPhase == .active,
                   state.shouldResumePlayback {
                    if state.inlineAttached {
                        let resumeFence = state.fence.with(
                            playAfterResume: state.explicitPlayRequested
                        )
                        presentationPhase = .inlineAttachedUnproven(resumeFence)
                        return [.resumeVideoLane(resumeFence, token)]
                    }
                    guard !state.attachRequested else { return [] }
                    state.attachRequested = true
                    presentationPhase = .warmSuspended(state)
                    return [.attachInline(state.fence)]
                }
                return []
            default:
                return []
            }

        case let .videoLanePreparationFailed(fence, token, failure):
            // Admitted exactly as `videoLanePrepared` is: the broad continuity
            // match plus token equality. The token is what proves this result
            // belongs to the suspension still in flight, which is the question
            // that actually matters here — a superseded preparation carries a
            // superseded token and is dropped, as it always was.
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspended(let state) where state.token == token:
                // Settle against the phase's OWN fence, not the fence the
                // preparation was emitted under. `didBecomeActive` may have
                // rotated the destination while this preparation ran; the
                // failure belongs to whatever destination is current, because
                // that destination is the one now waiting on a result that
                // will never come.
                let settleFence = state.fence
                presentationPhase = .failed(settleFence, failure)
                return [.settleFailure(settleFence, failure)]
            default:
                return []
            }

        case let .videoLaneResumed(fence, token):
            guard acceptsExactRenderPresentationEvent(fence) else { return [] }
            guard case .inlineAttachedUnproven(let currentFence) = presentationPhase else {
                return []
            }
            guard token.sessionGeneration == fence.sessionGeneration else { return [] }
            guard currentFence.playAfterResume else { return [] }
            let playFence = currentFence.with(playAfterResume: false)
            presentationPhase = .inlineAttachedUnproven(playFence)
            return [.playDemandVideoLane(playFence)]

        case let .videoLaneResumeFailed(fence, failure):
            guard acceptsExactRenderPresentationEvent(fence) else { return [] }
            if case .failed = presentationPhase { return [] }
            presentationPhase = .failed(fence, failure)
            return [.settleFailure(fence, failure)]

        case .inlineAttached(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly(var state):
                guard fence.renderGeneration == state.fence.renderGeneration else {
                    return []
                }
                state.inlineAttached = true
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return []
            case .warmSuspended(var state):
                guard fence.renderGeneration == state.fence.renderGeneration else {
                    return []
                }
                // A container attach is a UIKit layout edge, not an activation.
                // During the foreground transition `layoutSubviews`/
                // `didMoveToWindow` can deliver one while the application is
                // still inactive; resuming here would present video behind the
                // system animation. `didBecomeActive` remains the sole
                // visibility authority — it reads `inlineAttached` and resumes.
                guard presentationApplicationPhase == .active,
                      state.isPrepared,
                      let token = state.token else {
                    state.inlineAttached = true
                    presentationPhase = .warmSuspended(state)
                    return []
                }
                let resumeFence = fence.with(
                    playAfterResume: state.explicitPlayRequested
                )
                presentationPhase = .inlineAttachedUnproven(resumeFence)
                return [.resumeVideoLane(resumeFence, token)]
            case .restoringInline(var transaction):
                var effects: [DemandPresentationEffect] = []
                if !transaction.inlineAttached {
                    transaction.inlineAttached = true
                }
                if !transaction.avKitCompletionSent,
                   let completionToken = transaction.completionToken {
                    transaction.avKitCompletionSent = true
                    effects.append(.completeAVKitRestore(
                        token: completionToken,
                        success: true
                    ))
                }
                if transaction.nativeDidStop {
                    presentationPhase = .inlineAttachedUnproven(fence)
                    effects.append(.restoreInlinePresentation(fence))
                } else if let nativeStopAuthority = transaction.nativeStopAuthority,
                          !transaction.nativeStopRequested {
                    // The inline destination is now visible/usable. Only
                    // this edge may start the native PiP exit for the
                    // automatic foreground handoff.
                    transaction.nativeStopRequested = true
                    presentationPhase = .restoringInline(transaction)
                    effects.append(.requestPiPStop(
                        fence,
                        nativeStopAuthority
                    ))
                } else {
                    presentationPhase = .restoringInline(transaction)
                }
                return effects
            case .pausedInline:
                presentationPhase = .pausedInline(fence)
                return []
            case .inlineAttachPending:
                presentationPhase = .inlineAttachedUnproven(fence)
                return []
            case .inlineAttachedUnproven:
                presentationPhase = .inlineAttachedUnproven(fence)
                return []
            default:
                return []
            }

        case .inlineDetached(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly(var state):
                guard fence.renderGeneration == state.fence.renderGeneration else {
                    return []
                }
                state.inlineAttached = false
                presentationPhase = .warmSuspendingForAudioOnly(state)
            case .warmSuspended(var state):
                guard fence.renderGeneration == state.fence.renderGeneration else {
                    return []
                }
                state.inlineAttached = false
                presentationPhase = .warmSuspended(state)
            default:
                return []
            }
            return []

        case .inlineAttachmentFailed(let fence):
            guard acceptsExactRenderPresentationEvent(fence) else { return [] }
            var effects: [DemandPresentationEffect] = []
            if case .restoringInline(let transaction) = presentationPhase,
               !transaction.avKitCompletionSent,
               let completionToken = transaction.completionToken {
                effects.append(.completeAVKitRestore(
                    token: completionToken,
                    success: false
                ))
            }
            presentationPhase = .failed(fence, .staleAuthority)
            effects.append(.settleFailure(fence, .staleAuthority))
            return effects

        case .pipWillStart(let fence):
            guard acceptsOrReplacesPresentationAuthority(fence) else { return [] }
            pipStartWasAbandoned = false
            pipPresentationReconcilePending = false
            presentationPhase = .pipStarting(fence)
            return []

        case .pipDidStart(let fence):
            // A direct didStart from an idle coordinator is retained as a
            // deterministic/native compatibility seam. Once activation has
            // explicitly abandoned a pending start, however, this binding is
            // no longer allowed to reclaim the route.
            guard !pipStartWasAbandoned else { return [] }
            guard acceptsOrReplacesPresentationAuthority(fence) else { return [] }
            pipPresentationReconcilePending = false
            presentationPhase = .pipActive(fence)
            presentationApplicationPhase = .background
            return []

        case .pipStartAbandoned(let fence):
            guard acceptsPresentationEvent(fence),
                  case .pipStarting(let current) = presentationPhase,
                  current.hasSameContinuityAuthority(as: fence) else {
                return []
            }
            pipStartWasAbandoned = true
            pipPresentationReconcilePending = false
            presentationApplicationPhase = .active
            presentationRecoveryStage = .retainedRenderer
            presentationPhase = .inlineAttachPending(fence)
            return [
                .abandonPiPStart(fence),
                .attachInline(fence),
            ]

        case let .pipTransportIntent(fence, userWantsPlaying):
            guard acceptsPresentationEvent(fence),
                  presentationPhase.fence?.renderGeneration
                    == fence.renderGeneration else { return [] }
            switch presentationPhase {
            case .pipActive:
                let currentFence = presentationPhase.fence ?? fence
                presentationPhase = .pipActive(currentFence.with(
                    userWantsPlaying: userWantsPlaying,
                    playAfterResume: false
                ))
                return []
            case .pipStarting:
                let currentFence = presentationPhase.fence ?? fence
                presentationPhase = .pipStarting(currentFence.with(
                    userWantsPlaying: userWantsPlaying,
                    playAfterResume: false
                ))
                return []
            case .pipStopping(let transaction):
                presentationPhase = .pipStopping(.init(
                    fence: transaction.fence.with(
                        userWantsPlaying: userWantsPlaying,
                        playAfterResume: false
                    ),
                    authority: transaction.authority,
                    nativeDidStop: transaction.nativeDidStop
                ))
                return []
            case .warmSuspendingForAudioOnly(var state):
                // A pause request can race the native didStop callback. Keep
                // the stop transaction's local suspension intent aligned with
                // the latest PiP control edge, but never overwrite an explicit
                // Play that already owns preparation.
                guard state.reason == .pipDidStop, !state.explicitPlayRequested else {
                    return []
                }
                state.shouldResumePlayback = userWantsPlaying
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return []
            case .warmSuspended(var state):
                guard state.reason == .pipDidStop, !state.explicitPlayRequested else {
                    return []
                }
                state.shouldResumePlayback = userWantsPlaying
                presentationPhase = .warmSuspended(state)
                return []
            default:
                return []
            }

        case let .transportSuppressed(fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly(var state), .warmSuspended(var state):
                state.shouldResumePlayback = false
                state.explicitPlayRequested = false
                state.prepareWhenSuspended = false
                if state.token == nil {
                    presentationPhase = .warmSuspendingForAudioOnly(state)
                } else {
                    presentationPhase = .warmSuspended(state)
                }
            case .inlineAttachedUnproven(let current):
                presentationPhase = .inlineAttachedUnproven(current.with(playAfterResume: false))
            default: break
            }
            return []

        case let .explicitPlayRequested(fence):
            // A cancelled seek may have advanced the media generation without
            // delivering its success edge. Explicit Play can adopt that same
            // source; suspension still defers until the seek releases it.
            if let previousFence = presentationPhase.fence,
               fence.isSameResourceAfterSeek(of: previousFence) {
                switch presentationPhase {
                case .warmSuspendingForAudioOnly, .warmSuspended:
                    return reducePresentation(.videoLaneSeekCommitted(fence: fence, resumesPlayback: true))
                default: break
                }
            }
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly(var state), .warmSuspended(var state):
                guard !state.shouldResumePlayback else { return [] }
                state.shouldResumePlayback = true
                state.explicitPlayRequested = true
                if presentationApplicationPhase == .background || state.videoFailure != nil {
                    // Audio may resume under the retained local video suspension.
                    // Preparing/attaching background inline video is forbidden.
                    state.prepareWhenSuspended = false
                    if let token = state.token {
                        presentationPhase = .warmSuspended(state)
                        return [.resumeSuspendedAudio(state.fence, token)]
                    }
                    presentationPhase = .warmSuspendingForAudioOnly(state)
                    return [state.reason == .pipDidStop
                        ? .suspendVideoLaneAfterPiPStop(state.fence)
                        : .warmSuspendVideoLane(state.fence)]
                }
                state.prepareWhenSuspended = true
                switch presentationPhase {
                case .warmSuspendingForAudioOnly:
                    presentationPhase = .warmSuspendingForAudioOnly(state)
                    return [state.reason == .pipDidStop
                        ? .suspendVideoLaneAfterPiPStop(state.fence)
                        : .warmSuspendVideoLane(state.fence)]
                case .warmSuspended:
                    presentationPhase = .warmSuspended(state)
                    guard let token = state.token else { return [] }
                    if state.isPrepared {
                        if state.inlineAttached {
                            let resumeFence = state.fence.with(playAfterResume: true)
                            presentationPhase = .inlineAttachedUnproven(resumeFence)
                            return [.resumeVideoLane(resumeFence, token)]
                        }
                        state.attachRequested = true
                        presentationPhase = .warmSuspended(state)
                        return [.attachInline(state.fence)]
                    }
                    return [.prepareVideoLaneForForeground(state.fence, token)]
                default:
                    return []
                }
            default:
                return []
            }

        case let .videoLaneSeekCommitted(fence, resumesPlayback):
            switch presentationPhase {
            case .warmSuspendingForAudioOnly(var state), .warmSuspended(var state):
                // Without this the old token and fence were orphaned: every
                // later lifecycle event and Play was refused and playback
                // froze for good (device 2026-10-18, lock-screen seek).
                guard fence.isSameResourceAfterSeek(of: state.fence) else { return [] }
                state.fence = fence
                state.token = nil
                state.videoFailure = nil
                state.suspensionAcknowledgementFence = fence
                state.isPrepared = false
                state.preparedWhileInactive = false
                state.activeValidationRequested = false
                state.attachRequested = false
                // The seek's resumption runs through the suspension's own
                // explicit-Play path: audio resumes in background, and the
                // foreground prepares, attaches and resumes the lane.
                state.shouldResumePlayback = resumesPlayback
                state.explicitPlayRequested = resumesPlayback
                state.prepareWhenSuspended = resumesPlayback
                    && presentationApplicationPhase != .background
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return [state.reason == .pipDidStop
                    ? .suspendVideoLaneAfterPiPStop(fence)
                    : .warmSuspendVideoLane(fence)]
            default:
                return []
            }

        case .pipFailedToStart(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            pipPresentationReconcilePending = false
            guard case .pipStarting = presentationPhase else { return [] }
            guard presentationApplicationPhase == .background else {
                presentationPhase = .pipStartFailed(fence)
                return []
            }
            return beginAudioOnlySuspension(
                fence: fence,
                resumesPlayback: fence.userWantsPlaying && !fence.playbackSuppressed
            )

        case let .requestPiPStop(fence, authority):
            guard acceptsPresentationEvent(fence) else { return [] }
            pipPresentationReconcilePending = false
            guard !authority.isForcedRetirement else {
                presentationPhase = .failed(fence, .retired)
                return [.forceRetirePiP(fence, authority)]
            }
            switch presentationPhase {
            case .pipActive, .pipStarting:
                presentationPhase = .pipStopping(.init(
                    fence: fence,
                    authority: authority,
                    nativeDidStop: false
                ))
                return [.requestPiPStop(fence, authority)]
            case .pipStopping, .restoringInline:
                return []
            default:
                return []
            }

        case let .prepareInlineForPiPStop(fence, authority):
            guard acceptsPresentationEvent(fence),
                  !authority.isForcedRetirement else { return [] }
            switch presentationPhase {
            case .pipActive:
                pipPresentationReconcilePending = false
                presentationPhase = .restoringInline(.init(
                    fence: fence,
                    completionToken: nil,
                    nativeStopAuthority: authority,
                    inlineAttached: false,
                    avKitCompletionSent: false,
                    nativeDidStop: false
                ))
                // This effect only prepares UIKit containment/layout. The
                // native stop is deliberately emitted by inlineAttached below.
                return [.attachInline(fence)]
            case .restoringInline:
                // Repeated activation/foreground notifications coalesce onto
                // the existing restore transaction.
                return []
            default:
                return []
            }

        case let .forceRetirePiP(fence, authority):
            guard acceptsPresentationEvent(fence), authority.isForcedRetirement else { return [] }
            presentationPhase = .failed(fence, .retired)
            return [.forceRetirePiP(fence, authority)]

        case let .restoreInlineRequested(fence, completionToken):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .pipActive, .pipStopping:
                presentationPhase = .restoringInline(.init(
                    fence: fence,
                    completionToken: completionToken,
                    nativeStopAuthority: nil,
                    inlineAttached: false,
                    avKitCompletionSent: false,
                    nativeDidStop: false
                ))
                return [.attachInline(fence)]
            case .inlineNeedsAttachment:
                // A real system stop can beat the restore delegate. Preserve
                // that native completion and still acknowledge AVKit only
                // after the current inline generation is visibly attached.
                presentationPhase = .restoringInline(.init(
                    fence: fence,
                    completionToken: completionToken,
                    nativeStopAuthority: nil,
                    inlineAttached: false,
                    avKitCompletionSent: false,
                    nativeDidStop: true
                ))
                return [.attachInline(fence)]
            case .inlineAttachPending:
                presentationPhase = .restoringInline(.init(
                    fence: fence,
                    completionToken: completionToken,
                    nativeStopAuthority: nil,
                    inlineAttached: false,
                    avKitCompletionSent: false,
                    nativeDidStop: true
                ))
                return []
            case .inlineAttachedUnproven:
                presentationPhase = .inlineAttachedUnproven(fence)
                return [
                    .completeAVKitRestore(token: completionToken, success: true),
                    .restoreInlinePresentation(fence),
                ]
            case .restoringInline(var transaction):
                // A native restore callback can race the automatic foreground
                // handoff. Retain its completion token and answer it from the
                // already-prepared inline target exactly once.
                if transaction.completionToken == nil {
                    transaction.completionToken = completionToken
                }
                guard !transaction.avKitCompletionSent,
                      transaction.inlineAttached,
                      let token = transaction.completionToken else {
                    presentationPhase = .restoringInline(transaction)
                    return []
                }
                transaction.avKitCompletionSent = true
                presentationPhase = .restoringInline(transaction)
                return [.completeAVKitRestore(token: token, success: true)]
            default:
                return [.completeAVKitRestore(token: completionToken, success: false)]
            }

        case .pipWillStop(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            pipPresentationReconcilePending = false
            return []

        case .pipDidStop(let fence):
            guard acceptsPresentationEvent(fence) else { return [] }
            pipPresentationReconcilePending = false
            // A PiP pause request may have updated the phase fence before the
            // native didStop callback arrives. Read the latest phase intent
            // rather than requiring callers to reuse the exact event value.
            let stopFence = fence.with(
                userWantsPlaying: presentationPhase.fence?.userWantsPlaying
                    ?? fence.userWantsPlaying,
                playAfterResume: false
            )
            switch presentationPhase {
            case .pipStopping(var transaction):
                guard !transaction.nativeDidStop else { return [] }
                transaction.nativeDidStop = true
                if presentationApplicationPhase == .active {
                    presentationPhase = .inlineAttachPending(stopFence)
                    return [.attachInline(stopFence)]
                }
                let state = DemandWarmSuspensionState(
                    fence: stopFence,
                    token: nil,
                    prepareWhenSuspended: false,
                    isPrepared: false,
                    shouldResumePlayback: stopFence.userWantsPlaying,
                    reason: .pipDidStop
                )
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return [.suspendVideoLaneAfterPiPStop(stopFence)]
            case .restoringInline(var transaction):
                guard !transaction.nativeDidStop else { return [] }
                transaction.nativeDidStop = true
                if transaction.inlineAttached {
                    presentationPhase = .inlineAttachedUnproven(stopFence)
                    return [.restoreInlinePresentation(stopFence)]
                }
                presentationPhase = .restoringInline(transaction)
                return []
            case .pipActive:
                if presentationApplicationPhase == .active {
                    presentationPhase = .inlineAttachPending(stopFence)
                    return [.attachInline(stopFence)]
                }
                let state = DemandWarmSuspensionState(
                    fence: stopFence,
                    token: nil,
                    prepareWhenSuspended: false,
                    isPrepared: false,
                    shouldResumePlayback: stopFence.userWantsPlaying,
                    reason: .pipDidStop
                )
                presentationPhase = .warmSuspendingForAudioOnly(state)
                return [.suspendVideoLaneAfterPiPStop(stopFence)]
            default:
                return []
            }

        case .pipPresentationNeedsReconcile(let fence):
            guard acceptsExactRenderPresentationEvent(fence),
                  case .pipActive = presentationPhase,
                  !pipPresentationReconcilePending else { return [] }
            pipPresentationReconcilePending = true
            return [.reconcilePiPPresentation(fence)]

        case .pipPresentationReconciled(let fence):
            guard acceptsPresentationEvent(fence),
                  case .pipActive(let currentFence) = presentationPhase,
                  fence.hasSameContinuityAuthority(as: currentFence),
                  pipPresentationReconcilePending else { return [] }
            pipPresentationReconcilePending = false
            return reducePresentation(.prepareInlineForPiPStop(
                // A container replacement may have rotated only the render
                // destination while this local reconcile was in flight. The
                // reconcile remains single-flight; handoff must use the
                // coordinator's current destination fence.
                fence: currentFence,
                authority: .userRestore
            ))

        case let .pipPresentationReconcileFailed(fence, failure):
            guard acceptsPresentationEvent(fence),
                  case .pipActive(let currentFence) = presentationPhase,
                  fence.hasSameContinuityAuthority(as: currentFence),
                  pipPresentationReconcilePending else { return [] }
            pipPresentationReconcilePending = false
            presentationPhase = .failed(currentFence, failure)
            return [.settleFailure(currentFence, failure)]

        case let .rendererHealthChanged(fence, health):
            guard acceptsExactRenderPresentationEvent(fence) else { return [] }
            if case .warmSuspended(let state) = presentationPhase, state.videoFailure != nil { return [] }
            switch health {
            case .visible(let proof):
                return reducePresentation(.presentationProved(proof))
            case .attachedButUnproven, .warmSuspended, .missingSurface:
                return []
            case .needsFlush:
                guard presentationRecoveryStage == .retainedRenderer else { return [] }
                presentationRecoveryStage = .rendererFlushed
                return [.flushAndPrimeRenderer(fence)]
            case .rendererFailed, .decoderInvalid:
                guard presentationRecoveryStage.rawValue < DemandPresentationRecoveryStage.decoderRecreated.rawValue else {
                    return []
                }
                presentationRecoveryStage = .decoderRecreated
                return [.recreateVideoDecoder(fence)]
            }

        case .presentationProved(let proof):
            guard proof.rendererReady,
                  acceptsPresentationEvent(proof.fence),
                  let expectedFence = presentationPhase.fence,
                  proof.fence.renderGeneration == expectedFence.renderGeneration else {
                return []
            }
            switch presentationPhase {
            case .inlineAttachedUnproven:
                presentationPhase = .inlineVisible(proof)
                presentationRecoveryStage = .retainedRenderer
                return [.settlePresentation(proof)]
            case .pausedInline:
                // A paused screen still owns a real inline surface, and
                // `attachPausedInline` rotates the render generation, so the
                // renderer publishes a genuine two-frame proof for it. Route it
                // to liveness — otherwise the proof is dropped here and the
                // session reads `frames-never-proven` for a surface the user
                // can see. The phase deliberately does NOT move: a paused
                // screen is not `inlineVisible`.
                return [.settlePresentation(proof)]
            default:
                return []
            }

        case let .runtimeVideoFault(fence, decoderInvalid):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly, .warmSuspended:
                // Preserve the healthy source/audio clock. The local debt is
                // consumed when foreground preparation runs.
                presentationRecoveryStage = decoderInvalid
                    ? .decoderRecreated
                    : .rendererFlushed
                return []
            case .inlineNeedsAttachment where presentationApplicationPhase != .active:
                // No PiP lease owns presentation and the app has no surface:
                // iOS took the VideoToolbox session at the background edge.
                // Repairing in place decodes for nobody, and from a mid-GOP
                // queue the replacement only receives non-sync samples it
                // rejects (device 2026-10-18: 26 replace/badData cycles in
                // 0.7 s, then a session-terminal fault on the foreground edge).
                // This is the typed local suspension boundary the background
                // branch reserves: keep audio, suspend the video lane, and let
                // foreground preparation rebuild it from a sync sample.
                return beginAudioOnlySuspension(
                    fence: fence, resumesPlayback: fence.userWantsPlaying
                )
            case .pipStarting, .pipActive, .pipStopping,
                 .inlineNeedsAttachment, .inlineAttachPending,
                 .inlineAttachedUnproven, .restoringInline:
                if decoderInvalid,
                   presentationRecoveryStage.rawValue < DemandPresentationRecoveryStage.decoderRecreated.rawValue {
                    presentationRecoveryStage = .decoderRecreated
                    return [.recreateVideoDecoder(fence)]
                }
                if presentationRecoveryStage == .retainedRenderer {
                    presentationRecoveryStage = .rendererFlushed
                    return [.flushAndPrimeRenderer(fence)]
                }
                return []
            default:
                return []
            }

        case .teardown:
            presentationPhase = .idle
            terminalState = .active
            presentationApplicationPhase = .active
            presentationRecoveryStage = .retainedRenderer
            pipStartWasAbandoned = false
            pipPresentationReconcilePending = false
            return []
        }
    }

    private mutating func installPresentationAuthority(_ fence: DemandPresentationFence) {
        _ = fence
    }

    private mutating func acceptsOrReplacesPresentationAuthority(
        _ fence: DemandPresentationFence
    ) -> Bool {
        guard let current = presentationPhase.fence else {
            installPresentationAuthority(fence)
            return true
        }
        guard current.hasSameContinuityAuthority(as: fence) else { return false }
        installPresentationAuthority(fence)
        return true
    }

    private func acceptsPresentationEvent(_ fence: DemandPresentationFence) -> Bool {
        guard let current = presentationPhase.fence else { return true }
        return current.hasSameContinuityAuthority(as: fence)
    }

    private mutating func beginAudioOnlySuspension(
        fence: DemandPresentationFence,
        resumesPlayback: Bool
    ) -> [DemandPresentationEffect] {
        presentationPhase = .warmSuspendingForAudioOnly(DemandWarmSuspensionState(
            fence: fence,
            token: nil,
            prepareWhenSuspended: presentationApplicationPhase == .active && resumesPlayback,
            isPrepared: false,
            shouldResumePlayback: resumesPlayback,
            reason: .audioOnlyBackground
        ))
        return [.warmSuspendVideoLane(fence)]
    }

    /// Presentation failures can invalidate exactly one render destination.
    /// Late media callbacks intentionally use the broader continuity match so a
    /// successor transaction may adopt their result, but an attach/resume or
    /// renderer-health failure from an older render must never fail that
    /// successor. Keep this check beside the broad helper so the distinction is
    /// explicit at every failure effect boundary.
    private func acceptsExactRenderPresentationEvent(
        _ fence: DemandPresentationFence
    ) -> Bool {
        guard acceptsPresentationEvent(fence),
              let current = presentationPhase.fence else {
            return false
        }
        return current.renderGeneration == fence.renderGeneration
    }
}

/// The sink is the production wiring seam. The adapter owns no policy and no
/// async work; it always reduces through the shared coordinator before mapping
/// the resulting effects to the same collaborator method tests exercise.
@MainActor
protocol DemandContinuationEffectSink: AnyObject {
    func performDemandPresentationEffect(_ effect: DemandPresentationEffect)
}

struct DemandContinuationReduction: Equatable {
    let coordinator: LifecycleRecoveryCoordinator
    let effects: [DemandPresentationEffect]
}

@MainActor
final class DemandContinuationEffectAdapter {
    private weak var sink: (any DemandContinuationEffectSink)?

    init(sink: any DemandContinuationEffectSink) {
        self.sink = sink
    }

    /// Phase 1: reduce against a value copy and return the state/effects
    /// transaction. No collaborator is invoked while the caller owns mutable
    /// coordinator storage.
    func reduce(
        _ event: DemandPresentationEvent,
        coordinator: LifecycleRecoveryCoordinator
    ) -> DemandContinuationReduction {
        var next = coordinator
        let effects = next.reducePresentation(event)
        return DemandContinuationReduction(coordinator: next, effects: effects)
    }

    /// Phase 2: execute only after the caller has committed `coordinator` from
    /// `reduce`. Effects may synchronously submit another event; that nested
    /// reduction then observes the already-committed state without overlapping
    /// an `inout` access.
    func perform(_ effects: [DemandPresentationEffect]) {
        for effect in effects {
            sink?.performDemandPresentationEffect(effect)
        }
    }
}
