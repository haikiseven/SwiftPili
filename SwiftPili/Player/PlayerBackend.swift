import CoreVideo
import UIKit

struct DisplayedFrameCaptureSource: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let displayScale: CGFloat
}

enum PlayerStateEvent: Sendable {
    case readyToPlay
    case buffering
    case bufferFinished
    case paused
    case playedToTheEnd
    case error(any Error)
}

enum PlayerBackendPiPTransportEdge: Sendable, Equatable {
    case transportIntent(
        operation: UInt64,
        playing: Bool,
        backendGeneration: UInt64,
        sessionGeneration: UInt64,
        pipBindingGeneration: UInt64?,
        ownerLeaseGeneration: UInt64
    )
    case seekSettled(
        operation: UInt64,
        position: TimeInterval,
        backendGeneration: UInt64,
        sessionGeneration: UInt64,
        pipBindingGeneration: UInt64?,
        ownerLeaseGeneration: UInt64
    )
}

struct PlayerTrackInfo: Sendable {
    let name: String
    let naturalSize: CGSize
}

struct PlayerDynamicStats: Sendable {
    var displayFPS: Double
    var videoBitrate: Int
    var audioBitrate: Int
    var bytesRead: Int64
    var networkBytesReceived: Int64
    var multiConnection = MultiConnectionTelemetry.unsupported
    var droppedVideoFrameCount: Int32 = 0
    var droppedVideoPacketCount: Int32 = 0
}

func bindingDeliveryRunway(
    video: TimeInterval?,
    audio: TimeInterval?
) -> TimeInterval? {
    switch (video, audio) {
    case let (video?, audio?): min(video, audio)
    case let (video?, nil): video
    case let (nil, audio?): audio
    case (nil, nil): nil
    }
}

@MainActor
protocol PlayerBackend: AnyObject {
    // MARK: - Lifecycle
    func load(
        url: URL, audioURL: URL?, headers: [String: String],
        startPosition: TimeInterval, playbackRate: Float, hardwareDecode: Bool,
        networkCaching: TimeInterval, maxBuffer: TimeInterval,
        preferNativeVideoToolbox: Bool, alternateVideoURLs: [URL],
        alternateAudioURLs: [URL], readAheadSeconds: TimeInterval?,
        multiConnectionPolicy: MultiConnectionPolicy?, liveSource: DemandLiveSource?
    )

    func refreshMultiConnectionTelemetry()
    func setMultiConnectionQuiet(_ quiet: MultiConnectionQuiet)

    func stop()

    func parkForReuse() -> Bool

    var hasParkedSession: Bool { get }

    func setStartupTraceToken(_ token: StartupTrace.Token?)

    // MARK: - Transport

    func play()
    func pause()
    func seek(to time: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?)

    var isReadyToPlay: Bool { get }
    var isPlaying: Bool { get }
    var retainedPipelineHealth: RetainedPipelineHealth { get }

    func confirmRetainedLiveness(within timeout: TimeInterval) async -> Bool
    var runtimeGeneration: UInt64 { get }

    var pendingSeekTarget: TimeInterval? { get }

    var openedAtPosition: TimeInterval { get }

    // MARK: - Properties

    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var playableTime: TimeInterval { get }
    var bufferDisplaySample: MediaBufferDisplaySample? { get }

    var bufferedContentAhead: TimeInterval? { get }

    var bufferedPipelineAhead: TimeInterval? { get }

    var videoDeliveryRunway: TimeInterval? { get }

    var seekLaunchReserve: TimeInterval { get }

    var equalizerConfiguration: PlayerEqualizerConfiguration { get set }
    var equalizerStatus: PlayerEqualizerStatus { get }
    var videoEnhancementConfiguration: VideoEnhancementConfiguration { get set }
    var videoEnhancementTelemetry: VideoEnhancementTelemetry { get }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? { get set }
    func revokeAudioMaintenancePermission()
    var supportsSystemSubtitleGeneration: Bool { get }
    func setSubtitlePCMTap(_ tap: AudioPCMSubtitleTap?)

    var playbackRate: Float { get set }
    var effectivePlaybackRate: Float { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }

    // MARK: - Rendering

    var renderViewController: UIViewController? { get }

    func currentDisplayedFrameForTransition() -> UIImage?
    func currentDisplayedFrameCaptureSource() -> DisplayedFrameCaptureSource?
    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage?

    func setScaleMode(_ mode: VideoScaleMode)
    func setDemandPresentationCornerRadius(_ radius: CGFloat)

    // MARK: - PiP

    var isPiPActive: Bool { get }
    var hasObservedPiPLease: Bool { get }
    func startPiP()
    func stopPiP()
    func noteDemandPiPEnvironmentWillResignActive()
    func abandonDemandPiPStart()
    func reconcileDemandPiPPresentationAfterActivation(
        renderGeneration: Int
    ) async -> Bool
    func setObservedPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )

    func setPiPTransportEdgeHandler(
        _ handler: (@MainActor @Sendable (PlayerBackendPiPTransportEdge) -> Void)?
    )
    func applyPlaybackContinuationConfiguration(
        _ configuration: PlaybackContinuationConfiguration
    ) -> PlaybackContinuationApplyResult

    // MARK: Demand presentation continuity

    var demandPresentationSessionGeneration: UInt64 { get }
    var demandPiPBindingGeneration: UInt64 { get }
    var demandPresentationHealth: DemandPresentationHealth { get }
    func warmSuspendDemandVideoLane() -> DemandVideoSuspensionResult
    func retainAudioAfterDemandVideoFailure() -> DemandVideoSuspendToken?
    var audioOutputAvailability: MediaAudioOutputAvailability { get }
    func setAudioOutputStateChangeHandler(_ handler: (@MainActor () -> Void)?)
    func reconcileAudioOutputForAuthorizedPlayback() -> Bool
    func prepareDemandVideoLaneForForeground(
        _ token: DemandVideoSuspendToken
    ) async -> DemandVideoLanePreparationResult
    func resumeDemandVideoLane(
        _ token: DemandVideoSuspendToken,
        renderGeneration: Int
    ) async -> Bool
    func restoreDemandInlinePresentation(renderGeneration: Int) async -> Bool
    func flushAndPrimeDemandRenderer(renderGeneration: Int) -> Bool
    func recreateDemandVideoDecoder() async -> Bool
    func noteDemandInlineAttachment(
        renderGeneration: Int,
        isVisible: Bool,
        boundsUsable: Bool
    )
    func refreshDemandPresentationImageHold()
    func setDemandPresentationProofHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    )
    func setDemandPresentationFailureHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    )
    func setDemandPiPNativeTransitionHandler(
        _ handler: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    )
    func setDemandPiPRestoreRequestHandler(
        _ handler: (@MainActor @Sendable (UInt64) -> Void)?
    )
    func completeDemandPiPRestore(token: UInt64, success: Bool)
    func forceRetireDemandPiP()

    // MARK: - Info

    func videoTracks() -> [PlayerTrackInfo]
    var dynamicInfo: PlayerDynamicStats? { get }
    func thumbnailAtCurrentTime() async -> UIImage?

    func invalidateFrameStats()

    func updateDemandVideoLivenessContext(_ context: DemandVideoLivenessContext?)

    // MARK: - Events

    var onStateChanged: (@MainActor @Sendable (PlayerStateEvent) -> Void)? { get set }
    func setFirstVideoFrameHandler(
        _ handler: (@MainActor @Sendable (_ generation: UInt64) -> Void)?
    )
    func setRuntimeFaultHandler(
        _ handler: (@MainActor @Sendable (MediaRuntimeFault) -> Void)?
    )
    var onTickWithGeneration: (@MainActor @Sendable (_ currentTime: TimeInterval, _ totalTime: TimeInterval, _ generation: UInt64, _ startupTraceToken: StartupTrace.Token?) -> Void)? { get set }
    var onBufferChanged: (@MainActor @Sendable (_ consumeTime: TimeInterval) -> Void)? { get set }
}

extension PlayerBackend {
    var effectivePlaybackRate: Float {
        isPlaying ? playbackRate : 0
    }

    var equalizerConfiguration: PlayerEqualizerConfiguration {
        get { .defaults }
        set { _ = newValue }
    }
    var equalizerStatus: PlayerEqualizerStatus { .unsupported("This backend does not support EQ") }
    var videoEnhancementConfiguration: VideoEnhancementConfiguration {
        get { .disabled }
        set { _ = newValue }
    }
    var videoEnhancementTelemetry: VideoEnhancementTelemetry {
        .bypassed(reason: "libVLC unsupported")
    }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? {
        get { nil }
        set { _ = newValue }
    }
    func revokeAudioMaintenancePermission() {}
    var supportsSystemSubtitleGeneration: Bool { false }
    func setSubtitlePCMTap(_: AudioPCMSubtitleTap?) {}

    var bufferDisplaySample: MediaBufferDisplaySample? { nil }

    func currentDisplayedFrameForTransition() -> UIImage? { nil }
    func currentDisplayedFrameCaptureSource() -> DisplayedFrameCaptureSource? { nil }
    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage? {
        _ = targetSize
        return nil
    }

    func setDemandPresentationCornerRadius(_ radius: CGFloat) {
        _ = radius
    }

    func setFirstVideoFrameHandler(
        _: (@MainActor @Sendable (UInt64) -> Void)?
    ) {}

    func setRuntimeFaultHandler(
        _: (@MainActor @Sendable (MediaRuntimeFault) -> Void)?
    ) {}

    func updateDemandVideoLivenessContext(_: DemandVideoLivenessContext?) {}

    var hasObservedPiPLease: Bool { false }

    func setObservedPiPLeaseChangeHandler(
        _: (@MainActor @Sendable (Bool) -> Void)?
    ) {}

    func noteDemandPiPEnvironmentWillResignActive() {}
    func abandonDemandPiPStart() {}
    func reconcileDemandPiPPresentationAfterActivation(
        renderGeneration: Int
    ) async -> Bool { true }

    func setPiPTransportEdgeHandler(
        _: (@MainActor @Sendable (PlayerBackendPiPTransportEdge) -> Void)?
    ) {}

    func applyPlaybackContinuationConfiguration(
        _: PlaybackContinuationConfiguration
    ) -> PlaybackContinuationApplyResult {
        .unchanged(hostRevision: 0)
    }

    var demandPresentationSessionGeneration: UInt64 { 0 }
    var demandPiPBindingGeneration: UInt64 { 0 }
    var demandPresentationHealth: DemandPresentationHealth { .missingSurface }
    func warmSuspendDemandVideoLane() -> DemandVideoSuspensionResult { .unsupported }
    func retainAudioAfterDemandVideoFailure() -> DemandVideoSuspendToken? { nil }
    var audioOutputAvailability: MediaAudioOutputAvailability { .stopped }
    func setAudioOutputStateChangeHandler(_: (@MainActor () -> Void)?) {}
    func reconcileAudioOutputForAuthorizedPlayback() -> Bool { false }
    func prepareDemandVideoLaneForForeground(
        _: DemandVideoSuspendToken
    ) async -> DemandVideoLanePreparationResult {
        .failed(.unsupportedVideoContinuity)
    }
    func resumeDemandVideoLane(
        _: DemandVideoSuspendToken,
        renderGeneration _: Int
    ) async -> Bool { false }
    func restoreDemandInlinePresentation(renderGeneration _: Int) async -> Bool { false }
    func flushAndPrimeDemandRenderer(renderGeneration _: Int) -> Bool { false }
    func recreateDemandVideoDecoder() async -> Bool { false }
    func noteDemandInlineAttachment(
        renderGeneration _: Int,
        isVisible _: Bool,
        boundsUsable _: Bool
    ) {}
    func refreshDemandPresentationImageHold() {}
    func setDemandPresentationProofHandler(
        _: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    ) {}
    func setDemandPresentationFailureHandler(
        _: (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    ) {}
    func setDemandPiPNativeTransitionHandler(
        _: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    ) {}
    func setDemandPiPRestoreRequestHandler(
        _: (@MainActor @Sendable (UInt64) -> Void)?
    ) {}
    func completeDemandPiPRestore(token _: UInt64, success _: Bool) {}
    func forceRetireDemandPiP() { stopPiP() }
}
