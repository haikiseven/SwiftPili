import Foundation

struct DemandPresentationFence: Equatable {
    let lifecycleEpoch: UInt64
    let ownerKey: String
    let ownerLeaseGeneration: UInt64
    let source: DecoderRecoveryAdmission.Source
    let backendGeneration: UInt64
    let sessionGeneration: UInt64
    let renderGeneration: Int
    let pipBindingGeneration: UInt64
    let userWantsPlaying: Bool
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
    let reason: DemandVideoLaneSuspensionReason
    let resumesPlayback: Bool
    let generation: UInt64
    let sessionGeneration: UInt64
    let audioPosition: TimeInterval
    let ownerGeneration: UInt64
    let videoReadGeneration: UInt64
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

enum DemandVideoSuspensionResult: Equatable {
    case suspended(DemandVideoSuspendToken)
    case deferred
    case unsupported
}

enum DemandVideoLaneSuspensionReason: String, Equatable, Sendable {
    case audioOnlyBackground
    case pipDidStop
}

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

struct DemandPresentationProgressWitness: Equatable, Sendable {
    let serial: UInt64
    let lastProgressUptime: TimeInterval?
}

enum DemandPresentationProgressPolicy {
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
    case warmPreparationTimedOut
    case staleAuthority
    case retired
}

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
    var completionToken: UInt64?
    let nativeStopAuthority: DemandPiPStopAuthority?
    var inlineAttached: Bool
    var avKitCompletionSent: Bool
    var nativeDidStop: Bool
    var nativeStopRequested = false
}

struct DemandWarmSuspensionState: Equatable {
    var fence: DemandPresentationFence
    var token: DemandVideoSuspendToken?
    var prepareWhenSuspended: Bool
    var isPrepared: Bool
    var shouldResumePlayback: Bool = true
    var reason: DemandVideoLaneSuspensionReason = .audioOnlyBackground
    var explicitPlayRequested: Bool = false
    var preparedWhileInactive = false
    var activeValidationRequested = false
    var attachRequested = false
    var inlineAttached = false
    var suspensionAcknowledgementFence: DemandPresentationFence?
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
    case playbackEnded
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
    case pipStartAbandoned(fence: DemandPresentationFence)
    case pipTransportIntent(fence: DemandPresentationFence, userWantsPlaying: Bool)
    case pipFailedToStart(fence: DemandPresentationFence)
    case requestPiPStop(fence: DemandPresentationFence, authority: DemandPiPStopAuthority)
    case forceRetirePiP(fence: DemandPresentationFence, authority: DemandPiPStopAuthority)
    case prepareInlineForPiPStop(
        fence: DemandPresentationFence,
        authority: DemandPiPStopAuthority
    )
    case restoreInlineRequested(fence: DemandPresentationFence, completionToken: UInt64)
    case pipWillStop(fence: DemandPresentationFence)
    case pipDidStop(fence: DemandPresentationFence)
    case pipPresentationNeedsReconcile(fence: DemandPresentationFence)
    case pipPresentationReconciled(fence: DemandPresentationFence)
    case pipPresentationReconcileFailed(
        fence: DemandPresentationFence,
        failure: DemandPresentationFailure
    )
    case rendererHealthChanged(fence: DemandPresentationFence, health: DemandPresentationHealth)
    case presentationProved(DemandPresentationProof)
    case runtimeVideoFault(fence: DemandPresentationFence, decoderInvalid: Bool)
    case teardown
    case transportSuppressed(fence: DemandPresentationFence)
    case explicitPlayRequested(fence: DemandPresentationFence)
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
    case settleFailure(DemandPresentationFence, DemandPresentationFailure)
    case pauseForContinuationPolicy(DemandPresentationFence)
}

enum DemandForegroundPresentationDestination: Equatable, Sendable {
    case preservedPiP
    case retainedPassiveInline
    case unprovenPassiveInline
    case reservedNewInline
}

extension LifecycleRecoveryCoordinator {
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

    var foregroundPresentationDestination: DemandForegroundPresentationDestination {
        if terminalState.isTerminal { return .unprovenPassiveInline }
        return RenderDestinationDecision(phase: presentationPhase).foregroundDestination
    }

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
                    presentationPhase = .pipActive(current)
                } else if nativePiPStartPending {
                    presentationPhase = .pipStarting(fence)
                } else {
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
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspended(let state) where state.token == token:
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
                guard fence.isSameResourceAfterSeek(of: state.fence) else { return [] }
                state.fence = fence
                state.token = nil
                state.videoFailure = nil
                state.suspensionAcknowledgementFence = fence
                state.isPrepared = false
                state.preparedWhileInactive = false
                state.activeValidationRequested = false
                state.attachRequested = false
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
                return [.attachInline(fence)]
            case .restoringInline:
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
                return [.settlePresentation(proof)]
            default:
                return []
            }

        case let .runtimeVideoFault(fence, decoderInvalid):
            guard acceptsPresentationEvent(fence) else { return [] }
            switch presentationPhase {
            case .warmSuspendingForAudioOnly, .warmSuspended:
                presentationRecoveryStage = decoderInvalid
                    ? .decoderRecreated
                    : .rendererFlushed
                return []
            case .inlineNeedsAttachment where presentationApplicationPhase != .active:
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

    func reduce(
        _ event: DemandPresentationEvent,
        coordinator: LifecycleRecoveryCoordinator
    ) -> DemandContinuationReduction {
        var next = coordinator
        let effects = next.reducePresentation(event)
        return DemandContinuationReduction(coordinator: next, effects: effects)
    }

    func perform(_ effects: [DemandPresentationEffect]) {
        for effect in effects {
            sink?.performDemandPresentationEffect(effect)
        }
    }
}
