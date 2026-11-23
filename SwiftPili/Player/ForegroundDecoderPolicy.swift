import Foundation

enum ForegroundDecoderPolicy {
    static let foregroundSettleSeconds: TimeInterval = 0.35

    static let backgroundSettleSeconds: TimeInterval = 1.0

    static func shouldReopenInPlace(
        sessionSuspect: Bool,
        userWantsPlaying: Bool,
        canAutoRevive: Bool,
        hasSurfacedFailure: Bool
    ) -> Bool {
        sessionSuspect && userWantsPlaying && canAutoRevive && !hasSurfacedFailure
    }

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

enum RetainedSourceReopenPolicy {
    enum Decision: Equatable {
        case reopenRetainedURL
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

struct LifecycleReadinessFence: Equatable {
    let lifecycleEpoch: UInt64
    let initialTrigger: LifecycleRecoveryCoordinator.Trigger
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

struct RetainedPipelineHealth: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case playingWithProducer
        case pausedReady
        case requiresRecovery(Reason)
    }

    enum Reason: String, Equatable, Sendable {
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

enum DecoderRecoveryCompletion: Equatable {
    case backendReady
    case backendError
    case terminalLoaderFailure

    var succeeded: Bool {
        self == .backendReady
    }
}

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
    var terminalState: PlaybackTerminalState = .active
    var presentationPhase: DemandVideoPresentationPhase = .idle
    var presentationApplicationPhase: DemandPresentationApplicationPhase = .active
    var presentationRecoveryStage: DemandPresentationRecoveryStage = .retainedRenderer
    var pipStartWasAbandoned = false
    var pipPresentationReconcilePending = false

    mutating func enterTerminal(_ state: PlaybackTerminalState) {
        guard state.isTerminal,
              terminalState == .active else {
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

struct DecoderRecoveryAdmission: Equatable {
    enum Source: Equatable {
        case vod(aid: Int, cid: Int, quality: Int, source: String)
        case live(roomID: Int, quality: Int)
        case offline(OfflinePlaybackAsset)

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

        func hasSameAuthority(as other: Self) -> Bool {
            owner == other.owner
                && ownerLeaseGeneration == other.ownerLeaseGeneration
                && source.hasSameAuthority(as: other.source)
        }
    }

    enum Trigger: Equatable {
        case runtimeFault
        case lifecycle(epoch: UInt64)
        case manualRetry
        case streamTransport(cycle: UUID, request: UUID)
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

        var spendsAutomaticRuntimeBudget: Bool {
            switch self {
            case .runtimeFault, .differentEncode:
                true
            case .lifecycle, .manualRetry, .streamTransport:
                false
            }
        }

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

    static let retryBackoff: TimeInterval = 1

    private(set) var context: Context?
    private(set) var inFlight: Ticket?
    private(set) var nextToken: UInt64 = 0
    private(set) var runtimeBackoffUntil: TimeInterval = 0
    private(set) var lastLifecycleEpoch: UInt64?

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
        if let ticket = inFlight {
            guard ticket.request.context == request.context else {
                return .rejected(.staleContext)
            }
            if let epoch = request.trigger.lifecycleEpoch {
                if !markLifecycleEpoch(epoch), lastLifecycleEpoch != epoch {
                    return .rejected(.lifecycleEpochAlreadySpent)
                }
            }
            return .coalesced(ticket.token)
        }

        switch request.trigger {
        case .lifecycle(let epoch):
            guard markLifecycleEpoch(epoch) else {
                return .rejected(.lifecycleEpochAlreadySpent)
            }
        case .runtimeFault, .differentEncode:
            guard now >= runtimeBackoffUntil else {
                return .rejected(.backoff)
            }
            if request.fault?.stage != .seekPriming {
                guard budget.spendDecoderReload(at: request.position) else {
                    return .rejected(.budgetExhausted)
                }
            }
        case .manualRetry, .streamTransport:
            break
        }

        nextToken &+= 1
        let ticket = Ticket(token: nextToken, request: request)
        inFlight = ticket
        return .admitted(ticket.token)
    }

    private mutating func markLifecycleEpoch(_ epoch: UInt64) -> Bool {
        guard lastLifecycleEpoch.map({ epoch > $0 }) ?? true else {
            return false
        }
        lastLifecycleEpoch = epoch
        return true
    }

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

enum PlayerOwnerExitOutcome: Equatable {
    case ownershipEnded
    case leaseRetained
}

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

enum InlineSurfaceBindingPolicy {
    struct InlineSurfaceFacts: Equatable {
        let hasIncomingController: Bool
        let hasHostedController: Bool
        let controllerIdentityMatches: Bool
        let hostedViewIsAttached: Bool
        let hasLiveContainment: Bool
        let containerIsInWindow: Bool
    }

    static func needsReattach(_ facts: InlineSurfaceFacts) -> Bool {
        guard facts.hasIncomingController || facts.hasHostedController else {
            return false
        }
        guard facts.controllerIdentityMatches else { return true }
        guard facts.containerIsInWindow else { return false }
        guard facts.hostedViewIsAttached else { return true }
        return !facts.hasLiveContainment
    }

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

enum ExplicitPlaybackResumePolicy {
    static func shouldReloadBeforePlay(
        recoveryPending: Bool,
        hasVODIdentity: Bool
    ) -> Bool {
        recoveryPending && hasVODIdentity
    }
}

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
