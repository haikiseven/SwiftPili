import UIKit
enum PlayerStateEvent: Sendable {
    case readyToPlay
    case buffering
    case bufferFinished
    case paused
    case playedToTheEnd
    case error(any Error)
}

/// Backend-neutral settlement edges emitted by Demand's direct sample-buffer
/// PiP transport path. The App adds its owner/item fence at the boundary; the
/// backend contributes only the generations that identify the transport,
/// session, and optional PiP binding that produced the edge.
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
    var bytesRead: Int64 // Pipeline payload used by delivery health and liveness.
    var networkBytesReceived: Int64 // Received bodies excluding store hits; VLC input bytes.
    var multiConnection = MultiConnectionTelemetry.unsupported
    var droppedVideoFrameCount: Int32 = 0
    var droppedVideoPacketCount: Int32 = 0
}

/// Minimum delivery runway across present tracks (`nil` = unmeasurable, never zero).
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

    /// Retained through replacement loads; every backend declares its capability.
    func refreshMultiConnectionTelemetry()
    /// `.measurement` holds new helper requests; `.policy` also cancels in-flight ones.
    func setMultiConnectionQuiet(_ quiet: MultiConnectionQuiet)

    func stop()

    /// Park the current playback session for short-TTL same-content reuse
    /// instead of destroying it on owner exit. No protocol default: every
    /// conformer must explicitly declare its parking contract.
    func parkForReuse() -> Bool

    /// True while a parked session is held so pre-load teardown preserves the ticket.
    var hasParkedSession: Bool { get }

    /// Binds backend-originated startup milestones to one screen request.
    /// Internal reloads may retain the current token, while a successor screen
    /// replaces it before opening a new media generation.
    func setStartupTraceToken(_ token: StartupTrace.Token?)

    // MARK: - Transport

    func play()
    func pause()
    func seek(to time: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?)

    var isReadyToPlay: Bool { get }
    var isPlaying: Bool { get }
    /// Current retained-pipeline health for foreground admission, computed from
    /// live generation/tasks/resources rather than sticky readiness callbacks.
    var retainedPipelineHealth: RetainedPipelineHealth { get }

    /// Observational bounded check that the retained pipeline is still delivering
    /// new media progress within `timeout`, without side effects on transport.
    func confirmRetainedLiveness(within timeout: TimeInterval) async -> Bool
    /// Backend load generation bumped on every `load()` and `stop()`.
    var runtimeGeneration: UInt64 { get }

    /// The position a seek (or a `:start-time` open) is still travelling to,
    /// or nil once the real clock has arrived there.
    ///
    /// Non-nil spans the whole `requested → landed → arrived` journey. For DASH
    /// split streams that journey includes a multi-second stretch where libVLC
    /// has landed the two streams on different fragments and is holding the
    /// last video frame — zero fps and an off-target clock are CORRECT there.
    /// Consumers must treat this as "a seek is in progress", not as a fault.
    var pendingSeekTarget: TimeInterval? { get }

    /// The position the demuxer was opened at (`:start-time`), in absolute media
    /// time. Zero for a plain load.
    ///
    /// libVLC cannot seek BEFORE this point: `set_time` is start-relative, so a
    /// negative relative value clamps to the open position (design doc F13).
    /// Reaching anything earlier requires reopening the media at the target.
    var openedAtPosition: TimeInterval { get }

    // MARK: - Properties

    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    /// Absolute media position content is available up to for the seek UI
    /// (not a pipeline liveness signal — consult `bufferedContentAhead` for delivery health).
    var playableTime: TimeInterval { get }
    /// One display-only read, including proof and the selected endpoint.
    /// Raw availability and health stay separate; nil preserves raw fallback.
    var bufferDisplaySample: MediaBufferDisplaySample? { get }

    /// Content seconds banked ahead of the playhead (`nil` = unmeasurable, never zero).
    var bufferedContentAhead: TimeInterval? { get }

    /// Queued/decoded portion of `bufferedContentAhead` excluding unconsumed cache bytes,
    /// used by the watchdog's frozen-clock veto.
    var bufferedPipelineAhead: TimeInterval? { get }

    /// Video-track component of `bufferedContentAhead` (`nil` = unmeasurable or audio-only).
    var videoDeliveryRunway: TimeInterval? { get }

    /// Content seconds that must remain between a seek target and end-of-media
    /// at the current rate (`SeekTargetAdmission`).
    var seekLaunchReserve: TimeInterval { get }

    var equalizerConfiguration: PlayerEqualizerConfiguration { get set }
    var equalizerStatus: PlayerEqualizerStatus { get }
    var videoEnhancementConfiguration: VideoEnhancementConfiguration { get set }
    var videoEnhancementTelemetry: VideoEnhancementTelemetry { get }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? { get set }
    func revokeAudioMaintenancePermission()

    var playbackRate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }

    // MARK: - Rendering

    var renderViewController: UIViewController? { get }

    /// Best-effort snapshot of the pixel the backend's renderer is currently
    /// displaying for a source/owner transition cover. This is decorative
    /// state only: implementations must never substitute a queued or future
    /// frame, and backends without a synchronous displayed-pixel seam return
    /// nil through the protocol default below.
    func currentDisplayedFrameForTransition() -> UIImage?
    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage?

    /// Video scale mode: fit (letterbox), fill (crop), stretch.
    func setScaleMode(_ mode: VideoScaleMode)
    /// Temporary Demand PiP restore mask. Backends without a source layer
    /// leave this as a no-op through the protocol extension below.
    func setDemandPresentationCornerRadius(_ radius: CGFloat)

    // MARK: - PiP

    var isPiPActive: Bool { get }
    /// True only when this backend observed a PiP lifecycle start for the
    /// current playback owner and has not observed its stop. Unlike a raw
    /// platform active bit, this may safely decide whether an owner exit keeps
    /// playback alive.
    var hasObservedPiPLease: Bool { get }
    func startPiP()
    func stopPiP()
    /// Record the PiP presentation state before an inactive/background edge.
    /// Demand consumes this snapshot once on activation; other backends ignore
    /// it through the protocol default.
    func noteDemandPiPEnvironmentWillResignActive()
    /// Settle a native PiP start that never reached didStart/failedToStart.
    func abandonDemandPiPStart()
    /// Reconcile a possibly stale PiP display layer after activation without
    /// reopening the source. Returns false only when the bounded local repair
    /// could not restore the current renderer/decoder.
    func reconcileDemandPiPPresentationAfterActivation(
        renderGeneration: Int
    ) async -> Bool
    /// Delivers event-backed lease transitions. Raw native active state must
    /// not be forwarded through this boundary because it can remain sticky.
    func setObservedPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )

    /// Direct PiP transport is applied by the backend/session, then surfaced
    /// here as a neutral generation-bearing edge. The App maps it to Now
    /// Playing; no backend owns MediaPlayer metadata or command registration.
    func setPiPTransportEdgeHandler(
        _ handler: (@MainActor @Sendable (PlayerBackendPiPTransportEdge) -> Void)?
    )
    /// Apply the complete continuation snapshot. Backends whose PiP capability
    /// is immutable per drawable return a replacement host revision so the
    /// caller can request one real render attachment.
    func applyPlaybackContinuationConfiguration(
        _ configuration: PlaybackContinuationConfiguration
    ) -> PlaybackContinuationApplyResult

    // MARK: Demand presentation continuity

    /// These identities are independent of backend open and render attachment
    /// generations. Legacy backends return zero and never enter the Demand
    /// continuation reducer.
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
    /// Re-present the retained warm-suspend still image at the didBecomeActive
    /// visibility edge. Declared as a requirement (not extension-only) so the
    /// call on the `PlayerBackend` existential dynamically reaches the Demand
    /// backend's renderer-local hold.
    func refreshDemandPresentationImageHold()
    func setDemandPresentationProofHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    )
    /// Delivers local continuation failures (for example, a stale-tail hold
    /// refresh or renderer resume failure) into the existing presentation
    /// reducer. This is not a transport/runtime recovery authority.
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

    /// Discard any cached display-FPS sample so the next reading reflects only
    /// frames produced after this call.
    ///
    /// Used when the VideoToolbox session may have been invalidated by
    /// backgrounding: a sticky pre-background `displayFPS` (device: 81.5 while
    /// black) must not look "alive" to the foreground liveness path.
    func invalidateFrameStats()

    /// Supply Demand-only mode/source/lifecycle gates to the session's pure
    /// video liveness collector. Legacy backends intentionally ignore it.
    func updateDemandVideoLivenessContext(_ context: DemandVideoLivenessContext?)

    // MARK: - Events

    var onStateChanged: (@MainActor @Sendable (PlayerStateEvent) -> Void)? { get set }
    /// Runtime engine faults bypass the generic input-error/CDN path.
    func setRuntimeFaultHandler(
        _ handler: (@MainActor @Sendable (MediaRuntimeFault) -> Void)?
    )
    /// Identity-bearing clock callback used by `PlayerViewModel`.
    var onTickWithGeneration: (@MainActor @Sendable (_ currentTime: TimeInterval, _ totalTime: TimeInterval, _ generation: UInt64, _ startupTraceToken: StartupTrace.Token?) -> Void)? { get set }
    /// Buffered content seconds ahead of the current playhead, never an absolute
    /// media timestamp.
    var onBufferChanged: (@MainActor @Sendable (_ consumeTime: TimeInterval) -> Void)? { get set }
}

extension PlayerBackend {
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

    var bufferDisplaySample: MediaBufferDisplaySample? { nil }

    func currentDisplayedFrameForTransition() -> UIImage? { nil }
    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage? {
        _ = targetSize
        return nil
    }

    func setDemandPresentationCornerRadius(_ radius: CGFloat) {
        _ = radius
    }

    func setRuntimeFaultHandler(
        _: (@MainActor @Sendable (MediaRuntimeFault) -> Void)?
    ) {}

    func updateDemandVideoLivenessContext(_: DemandVideoLivenessContext?) {}

    /// Backends without an observable PiP lifecycle must fail closed on owner
    /// exit: do not leave invisible audio alive based on an ambiguous flag.
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
    /// Re-present the retained warm-suspend still image at the visibility
    /// edge. Renderer-local and idempotent: a healthy displayed hold
    /// short-circuits, no hold is a no-op, and it carries no
    /// recovery/proof/completion authority. Backends without a renderer-local
    /// image hold have nothing to refresh.
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
