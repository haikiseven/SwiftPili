import Foundation

// MARK: - Opaque identities

public struct PlaybackSessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackOperationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackSourceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackSurfaceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackPresentationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct PlaybackAuthority: Hashable, Sendable {
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }
}

// MARK: - Source and configuration

public struct MediaResource: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

public enum PlaybackInput: Sendable, Equatable {
    case split(video: MediaResource, audio: MediaResource?)
    case muxed(MediaResource)
    case local(MediaResource)
}

public struct PlaybackSource: Sendable, Equatable {
    public let id: PlaybackSourceID
    public let authority: PlaybackAuthority
    public let kind: PlaybackSourceKind
    public let duration: PlaybackDuration
    public let input: PlaybackInput
    public let startPosition: TimeInterval

    public init(
        id: PlaybackSourceID,
        authority: PlaybackAuthority,
        kind: PlaybackSourceKind = .onDemand,
        duration: PlaybackDuration = .unknown,
        input: PlaybackInput,
        startPosition: TimeInterval = 0
    ) {
        self.id = id
        self.authority = authority
        self.kind = kind
        self.duration = duration
        self.input = input
        self.startPosition = startPosition
    }
}

public struct PlaybackDiagnosticsConfiguration: Sendable, Equatable {
    public let enabled: Bool
    public let capacity: Int

    public init(enabled: Bool = false, capacity: Int = 128) {
        self.enabled = enabled
        self.capacity = max(0, capacity)
    }

    public static let disabled = PlaybackDiagnosticsConfiguration()
}

public struct PlaybackConfiguration: Sendable, Equatable {
    public var autoplay: Bool
    public var preferredRate: Float
    public var backgroundAudioEnabled: Bool
    public var pictureInPictureEnabled: Bool
    public var diagnostics: PlaybackDiagnosticsConfiguration

    public init(
        autoplay: Bool = false,
        preferredRate: Float = 1,
        backgroundAudioEnabled: Bool = false,
        pictureInPictureEnabled: Bool = false,
        diagnostics: PlaybackDiagnosticsConfiguration = .disabled
    ) {
        self.autoplay = autoplay
        self.preferredRate = preferredRate
        self.backgroundAudioEnabled = backgroundAudioEnabled
        self.pictureInPictureEnabled = pictureInPictureEnabled
        self.diagnostics = diagnostics
    }
}

public enum PlaybackCapability: Hashable, Sendable {
    case seeking
    case playbackRate
    case backgroundAudio
    case pictureInPicture
    case onlineServices
    case retainedSourceRecovery
}

// MARK: - Failure and command settlement

public enum PlaybackFailureCode: Hashable, Sendable {
    case mediaInput
    case presentationUnavailable
    case mediaServicesReset
    case terminal
    case unknown
}

public enum PlaybackFailure: Error, Hashable, Sendable {
    case engineUnavailable
    case closed
    case invalidSource
    case invalidRate
    case invalidSeek
    case unsupported(PlaybackCapability)
    case runtime(PlaybackFailureCode)
}

public enum PlaybackRejection: Hashable, Sendable {
    case noSource
    case closed
    case stale
    case invalidSource
    case invalidState
    case invalidRate
    case invalidSeek
    case unsupported(PlaybackCapability)
    case noPictureInPictureBinding
}

public enum PlaybackStopReason: Hashable, Sendable {
    case ownerExit
    case user
    case lifecycle
    case replacement
    case ended
}

public enum PlaybackCommandResult: Hashable, Sendable {
    case accepted(operation: PlaybackOperationID)
    case rejected(operation: PlaybackOperationID, reason: PlaybackRejection)
    case superseded(operation: PlaybackOperationID, by: PlaybackOperationID)
    case failed(operation: PlaybackOperationID, failure: PlaybackFailure)

    public var operation: PlaybackOperationID {
        switch self {
        case let .accepted(operation), let .rejected(operation, _),
             let .superseded(operation, _), let .failed(operation, _):
            return operation
        }
    }
}

public enum PlaybackCommandKind: Hashable, Sendable {
    case open
    case play
    case pause
    case seek
    case setRate
    case stop
    case requestPictureInPicture
    case environment
    case close
}

// MARK: - Surface and event contracts

public enum PlaybackSurfaceKind: Hashable, Sendable {
    case inline
    case pictureInPicture
    case unavailable
}

public struct PlaybackSurface: Hashable, Sendable {
    public let id: PlaybackSurfaceID
    public let kind: PlaybackSurfaceKind
    public let isAvailable: Bool

    public init(
        id: PlaybackSurfaceID,
        kind: PlaybackSurfaceKind,
        isAvailable: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.isAvailable = isAvailable
    }
}

public struct PlaybackPresentationProof: Hashable, Sendable {
    public let id: PlaybackPresentationID
    public let surface: PlaybackSurfaceID
    public let authority: PlaybackAuthority

    public init(
        id: PlaybackPresentationID,
        surface: PlaybackSurfaceID,
        authority: PlaybackAuthority
    ) {
        self.id = id
        self.surface = surface
        self.authority = authority
    }
}

public struct PlaybackSnapshot: Hashable, Sendable {
    public let session: PlaybackSessionID
    public let source: PlaybackSourceID?
    public let authority: PlaybackAuthority?
    public let identities: PlaybackIdentityContext
    public let intent: PlaybackIntent
    public let transport: PlaybackTransportState
    public let suppression: PlaybackSuppressionReason?
    public let audio: PlaybackAudioLaneState
    public let video: PlaybackVideoLaneState
    public let presentation: PlaybackPresentationState
    public let currentOperation: PlaybackOperationID?
    public let mediaTime: TimeInterval
    public let duration: PlaybackDuration
    public let rate: Float
    public let capabilities: Set<PlaybackCapability>
    public let revision: UInt64

    public init(
        session: PlaybackSessionID,
        source: PlaybackSourceID? = nil,
        authority: PlaybackAuthority? = nil,
        identities: PlaybackIdentityContext = .init(),
        intent: PlaybackIntent = .stopped,
        transport: PlaybackTransportState = .idle,
        suppression: PlaybackSuppressionReason? = nil,
        audio: PlaybackAudioLaneState = .unavailable,
        video: PlaybackVideoLaneState = .unavailable,
        presentation: PlaybackPresentationState = .init(),
        currentOperation: PlaybackOperationID? = nil,
        mediaTime: TimeInterval = 0,
        duration: PlaybackDuration = .unknown,
        rate: Float = 1,
        capabilities: Set<PlaybackCapability> = [],
        revision: UInt64 = 0
    ) {
        self.session = session
        self.source = source
        self.authority = authority
        self.identities = identities
        self.intent = intent
        self.transport = transport
        self.suppression = suppression
        self.audio = audio
        self.video = video
        self.presentation = presentation
        self.currentOperation = currentOperation
        self.mediaTime = mediaTime
        self.duration = duration
        self.rate = rate
        self.capabilities = capabilities
        self.revision = revision
    }
}

public enum PlaybackEventKind: Hashable, Sendable {
    case commandAccepted
    case commandRejected
    case commandSuperseded
    case commandFailed
    case sourceChanged
    case transportChanged
    case intentChanged
    case suppressionChanged
    case audioLaneChanged
    case videoLaneChanged
    case presentationChanged
    case transportReady
    case transportPlaying
    case transportPaused
    case presentationProof
    case stopped
    case capabilityChanged
    case environmentApplied
    case environmentIgnored
    case pictureInPictureRequest
    case pictureInPictureNative
    case recoveryDisposition
    case productRecoveryRequested
    case closed
}

public enum PlaybackEvent: Hashable, Sendable {
    case commandAccepted
    case commandRejected(reason: PlaybackRejection)
    case commandSuperseded(by: PlaybackOperationID)
    case commandFailed(failure: PlaybackFailure)
    case sourceChanged
    case transportChanged(PlaybackTransportState)
    case intentChanged(PlaybackIntent)
    case suppressionChanged(PlaybackSuppressionReason?)
    case audioLaneChanged(PlaybackAudioLaneState)
    case videoLaneChanged(PlaybackVideoLaneState)
    case presentationChanged(PlaybackPresentationState)
    case transportReady
    case transportPlaying
    case transportPaused
    case presentationProof(PlaybackPresentationProof)
    case stopped(reason: PlaybackStopReason)
    case capabilityChanged(PlaybackCapability, enabled: Bool)
    case environmentApplied(PlaybackEnvironmentEventKind)
    case environmentIgnored(PlaybackEnvironmentEventKind, reason: PlaybackEnvironmentRejection)
    case pictureInPictureRequest(PlaybackPictureInPictureRequest)
    case pictureInPictureNative(PlaybackPictureInPictureNativeEventKind)
    case recoveryDisposition(PlaybackRecoveryDisposition)
    case productRecoveryRequested(PlaybackRecoveryRequest)
    case closed

    public var kind: PlaybackEventKind {
        switch self {
        case .commandAccepted: return .commandAccepted
        case .commandRejected: return .commandRejected
        case .commandSuperseded: return .commandSuperseded
        case .commandFailed: return .commandFailed
        case .sourceChanged: return .sourceChanged
        case .transportChanged: return .transportChanged
        case .intentChanged: return .intentChanged
        case .suppressionChanged: return .suppressionChanged
        case .audioLaneChanged: return .audioLaneChanged
        case .videoLaneChanged: return .videoLaneChanged
        case .presentationChanged: return .presentationChanged
        case .transportReady: return .transportReady
        case .transportPlaying: return .transportPlaying
        case .transportPaused: return .transportPaused
        case .presentationProof: return .presentationProof
        case .stopped: return .stopped
        case .capabilityChanged: return .capabilityChanged
        case .environmentApplied: return .environmentApplied
        case .environmentIgnored: return .environmentIgnored
        case .pictureInPictureRequest: return .pictureInPictureRequest
        case .pictureInPictureNative: return .pictureInPictureNative
        case .recoveryDisposition: return .recoveryDisposition
        case .productRecoveryRequested: return .productRecoveryRequested
        case .closed: return .closed
        }
    }
}

public struct PlaybackEventEnvelope: Hashable, Sendable {
    public let session: PlaybackSessionID
    public let source: PlaybackSourceID?
    public let authority: PlaybackAuthority?
    public let operation: PlaybackOperationID?
    public let identities: PlaybackIdentityContext
    public let environmentEvent: PlaybackEnvironmentEventID?
    public let sequence: UInt64
    public let monotonicOffset: Duration
    public let event: PlaybackEvent

    public init(
        session: PlaybackSessionID,
        source: PlaybackSourceID?,
        authority: PlaybackAuthority?,
        operation: PlaybackOperationID?,
        identities: PlaybackIdentityContext = .init(),
        environmentEvent: PlaybackEnvironmentEventID? = nil,
        sequence: UInt64,
        monotonicOffset: Duration,
        event: PlaybackEvent
    ) {
        self.session = session
        self.source = source
        self.authority = authority
        self.operation = operation
        self.identities = identities
        self.environmentEvent = environmentEvent
        self.sequence = sequence
        self.monotonicOffset = monotonicOffset
        self.event = event
    }
}

// MARK: - Structured decision journal

public enum PlaybackNativeOutcome: Hashable, Sendable {
    case accepted
    case rejected
    case failed
    case unavailable
    case proof
    case parked
    case reset
}

public enum PlaybackDecisionInput: Hashable, Sendable {
    case command(PlaybackCommandKind)
    case nativeCompletion(PlaybackCommandKind, outcome: PlaybackNativeOutcome)
    case capability(PlaybackCapability)
    case environment(PlaybackEnvironmentEventKind)
    case recovery(PlaybackRecoveryDisposition)
    case productRecoveryRequest
}

public struct PlaybackStateTransition: Hashable, Sendable {
    public let from: PlaybackTransportState
    public let to: PlaybackTransportState

    public init(from: PlaybackTransportState, to: PlaybackTransportState) {
        self.from = from
        self.to = to
    }
}

public enum PlaybackEffectSummary: Hashable, Sendable {
    case runtimeCommand(PlaybackCommandKind)
    case publish(PlaybackEventKind)
    case snapshotRevision
    case environment(PlaybackEnvironmentEventKind)
    case recovery(PlaybackRecoveryDisposition)
    case productRecoveryRequest
    case close
    case none
}

public enum PlaybackDecisionResult: Hashable, Sendable {
    case accepted
    case rejected
    case superseded
    case failed
    case ignored
}

public enum PlaybackReasonCode: Hashable, Sendable {
    case accepted
    case rejected
    case superseded
    case engineUnavailable
    case invalidSource
    case invalidValue
    case invalidState
    case unsupported
    case runtimeFailure
    case stale
    case closed
    case systemSuppressed
    case mediaServicesReset
    case stopped
}

public struct PlaybackDecisionRecord: Hashable, Sendable {
    public let sequence: UInt64
    public let monotonicOffset: Duration
    public let session: PlaybackSessionID
    public let source: PlaybackSourceID?
    public let operation: PlaybackOperationID?
    public let identities: PlaybackIdentityContext
    public let generation: UInt64
    public let input: PlaybackDecisionInput
    public let transition: PlaybackStateTransition?
    public let effects: [PlaybackEffectSummary]
    public let result: PlaybackDecisionResult
    public let reason: PlaybackReasonCode

    package init(
        sequence: UInt64,
        monotonicOffset: Duration,
        session: PlaybackSessionID,
        source: PlaybackSourceID?,
        operation: PlaybackOperationID?,
        identities: PlaybackIdentityContext,
        generation: UInt64,
        input: PlaybackDecisionInput,
        transition: PlaybackStateTransition?,
        effects: [PlaybackEffectSummary],
        result: PlaybackDecisionResult,
        reason: PlaybackReasonCode
    ) {
        self.sequence = sequence
        self.monotonicOffset = monotonicOffset
        self.session = session
        self.source = source
        self.operation = operation
        self.identities = identities
        self.generation = generation
        self.input = input
        self.transition = transition
        self.effects = effects
        self.result = result
        self.reason = reason
    }
}
