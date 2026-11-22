import Foundation

// MARK: - Source traits

public enum PlaybackSourceKind: Hashable, Sendable {
    case onDemand
    case live
    case offline

    public var isSeekable: Bool {
        switch self {
        case .onDemand, .offline: return true
        case .live: return false
        }
    }

    public var supportsPlaybackRate: Bool {
        isSeekable
    }

    public var usesOnlineServices: Bool {
        self == .onDemand
    }

    public var usesRetainedRecoveryAuthority: Bool {
        true
    }
}

public enum PlaybackDuration: Hashable, Sendable {
    case finite(TimeInterval)
    case live
    case unknown

    public var finiteSeconds: TimeInterval? {
        if case let .finite(value) = self { return value }
        return nil
    }
}

public extension PlaybackSource {
    var sourceCapabilities: Set<PlaybackCapability> {
        var result: Set<PlaybackCapability> = [.retainedSourceRecovery]
        if kind.isSeekable { result.insert(.seeking) }
        if kind.supportsPlaybackRate { result.insert(.playbackRate) }
        if kind.usesOnlineServices { result.insert(.onlineServices) }
        return result
    }
}

// MARK: - Independent identity domains

public struct PlaybackOwnerLeaseID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackLifecycleEpoch: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}

public struct PlaybackSurfaceBindingID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackPictureInPictureBindingID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackEnvironmentEventID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackIdentityContext: Hashable, Sendable {
    public let ownerLease: PlaybackOwnerLeaseID?
    public let lifecycleEpoch: PlaybackLifecycleEpoch?
    public let surfaceBinding: PlaybackSurfaceBindingID?
    public let pictureInPictureBinding: PlaybackPictureInPictureBindingID?

    public init(
        ownerLease: PlaybackOwnerLeaseID? = nil,
        lifecycleEpoch: PlaybackLifecycleEpoch? = nil,
        surfaceBinding: PlaybackSurfaceBindingID? = nil,
        pictureInPictureBinding: PlaybackPictureInPictureBindingID? = nil
    ) {
        self.ownerLease = ownerLease
        self.lifecycleEpoch = lifecycleEpoch
        self.surfaceBinding = surfaceBinding
        self.pictureInPictureBinding = pictureInPictureBinding
    }
}

// MARK: - Independent state axes

public enum PlaybackIntent: Hashable, Sendable {
    case stopped
    case pausedByUser
    case playing
}

public enum PlaybackTransportState: Hashable, Sendable {
    case idle
    case opening
    case ready
    case buffering
    case ended
    case closed
    case failed(PlaybackFailure)
}

public enum PlaybackSuppressionReason: Hashable, Sendable {
    case audioInterruption
    case backgroundPolicy
    case mediaServicesUnavailable
    case resourceUnavailable
}

public enum PlaybackAudioLaneState: Hashable, Sendable {
    case unavailable
    case priming
    case active
    case parked
    case interrupted
    case failed(PlaybackFailure)
}

public enum PlaybackVideoLaneState: Hashable, Sendable {
    case unavailable
    case priming
    case presenting
    case parked
    case waitingForSurface
    case failed(PlaybackFailure)
}

public enum PlaybackPresentationRoute: Hashable, Sendable {
    case none
    case inline
    case pictureInPicture
}

public struct PlaybackPresentationState: Hashable, Sendable {
    public let route: PlaybackPresentationRoute
    public let surface: PlaybackSurface?
    public let proof: PlaybackPresentationProof?

    public init(
        route: PlaybackPresentationRoute = .none,
        surface: PlaybackSurface? = nil,
        proof: PlaybackPresentationProof? = nil
    ) {
        self.route = route
        self.surface = surface
        self.proof = proof
    }
}

// MARK: - Adapter-facing environment input

public enum PlaybackApplicationPhase: Hashable, Sendable {
    case foreground
    case inactive
    case background
}

public enum PlaybackAudioInterruption: Hashable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

public enum PlaybackMediaServicesEvent: Hashable, Sendable {
    case lost
    case reset
}

public enum PlaybackSurfaceEvent: Hashable, Sendable {
    case attached(binding: PlaybackSurfaceBindingID)
    case detached(binding: PlaybackSurfaceBindingID)
    case visibilityChanged(binding: PlaybackSurfaceBindingID, visible: Bool)
}

public enum PlaybackPictureInPictureNativeEvent: Hashable, Sendable {
    case willStart(binding: PlaybackPictureInPictureBindingID)
    case didStart(binding: PlaybackPictureInPictureBindingID)
    case failedToStart(binding: PlaybackPictureInPictureBindingID)
    case willStop(binding: PlaybackPictureInPictureBindingID)
    case didStop(binding: PlaybackPictureInPictureBindingID)
    case restoreUIRequested(binding: PlaybackPictureInPictureBindingID)
    case restoreUICompleted(binding: PlaybackPictureInPictureBindingID, success: Bool)

    public var kind: PlaybackPictureInPictureNativeEventKind {
        switch self {
        case .willStart: return .willStart
        case .didStart: return .didStart
        case .failedToStart: return .failedToStart
        case .willStop: return .willStop
        case .didStop: return .didStop
        case .restoreUIRequested: return .restoreUIRequested
        case .restoreUICompleted: return .restoreUICompleted
        }
    }

    public var binding: PlaybackPictureInPictureBindingID {
        switch self {
        case let .willStart(binding), let .didStart(binding),
             let .failedToStart(binding), let .willStop(binding),
             let .didStop(binding), let .restoreUIRequested(binding),
             let .restoreUICompleted(binding, _):
            return binding
        }
    }
}

public enum PlaybackPictureInPictureNativeEventKind: Hashable, Sendable {
    case willStart
    case didStart
    case failedToStart
    case willStop
    case didStop
    case restoreUIRequested
    case restoreUICompleted
}

public enum PlaybackEnvironmentEventKind: Hashable, Sendable {
    case ownerLeaseChanged
    case applicationPhaseChanged
    case audioInterruption
    case mediaServices
    case surface
    case pictureInPicture
}

public enum PlaybackEnvironmentEvent: Hashable, Sendable {
    case ownerLeaseChanged(PlaybackOwnerLeaseID?)
    case applicationPhaseChanged(PlaybackApplicationPhase, epoch: PlaybackLifecycleEpoch)
    case audioInterruption(PlaybackAudioInterruption)
    case mediaServices(PlaybackMediaServicesEvent)
    case surface(PlaybackSurfaceEvent)
    case pictureInPicture(PlaybackPictureInPictureNativeEvent)

    public var kind: PlaybackEnvironmentEventKind {
        switch self {
        case .ownerLeaseChanged: return .ownerLeaseChanged
        case .applicationPhaseChanged: return .applicationPhaseChanged
        case .audioInterruption: return .audioInterruption
        case .mediaServices: return .mediaServices
        case .surface: return .surface
        case .pictureInPicture: return .pictureInPicture
        }
    }
}

public enum PlaybackEnvironmentRejection: Hashable, Sendable {
    case stale
    case invalid
    case closed
}

public enum PlaybackEnvironmentResult: Hashable, Sendable {
    case accepted(event: PlaybackEnvironmentEventID)
    case ignored(event: PlaybackEnvironmentEventID, reason: PlaybackEnvironmentRejection)
}

public enum PlaybackPictureInPictureRequest: Hashable, Sendable {
    case start
    case stop
}

// MARK: - Generic recovery vocabulary

public enum PlaybackRecoveryDisposition: Hashable, Sendable, CaseIterable {
    case park
    case rendererReprepare
    case decoderRecreate
    case randomAccessReposition
    case retainedSourceReopen
    case productRecoveryRequest
    case manualUserRetry
    case systemResetRequiresUser
    case unsupported
    case terminal
}

public enum PlaybackRecoveryReason: Hashable, Sendable {
    case rendererUnavailable
    case resourceUnavailable
    case mediaServicesReset
    case randomAccessUnavailable
    case sourceExpired
    case userRequested
    case unknown
}

public struct PlaybackRecoveryRequest: Hashable, Sendable {
    public let disposition: PlaybackRecoveryDisposition
    public let source: PlaybackSourceID?
    public let authority: PlaybackAuthority?
    public let owner: PlaybackOwnerLeaseID?
    public let operation: PlaybackOperationID?
    public let reason: PlaybackRecoveryReason
    public let budget: UInt32

    public init(
        disposition: PlaybackRecoveryDisposition,
        source: PlaybackSourceID? = nil,
        authority: PlaybackAuthority? = nil,
        owner: PlaybackOwnerLeaseID? = nil,
        operation: PlaybackOperationID? = nil,
        reason: PlaybackRecoveryReason,
        budget: UInt32
    ) {
        self.disposition = disposition
        self.source = source
        self.authority = authority
        self.owner = owner
        self.operation = operation
        self.reason = reason
        self.budget = budget
    }
}

// MARK: - Bounded journal metadata

public struct PlaybackDecisionJournalSnapshot: Hashable, Sendable {
    public let records: [PlaybackDecisionRecord]
    public let droppedCount: UInt64
    public let firstRetainedSequence: UInt64?
    public let lastRetainedSequence: UInt64?

    public init(
        records: [PlaybackDecisionRecord],
        droppedCount: UInt64,
        firstRetainedSequence: UInt64?,
        lastRetainedSequence: UInt64?
    ) {
        self.records = records
        self.droppedCount = droppedCount
        self.firstRetainedSequence = firstRetainedSequence
        self.lastRetainedSequence = lastRetainedSequence
    }
}
