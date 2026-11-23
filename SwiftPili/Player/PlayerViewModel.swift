import AVFoundation
import Foundation
import Network
import Observation
import UIKit
import os

@MainActor
@Observable
final class PlayerViewModel: DemandContinuationEffectSink, DemandContinuationOperationOwner,
    PresentationFailureUI, PresentationFailureTransport, PresentationFailureProjection {
    private enum SharedStorage {
        case uninitialized
        case initializing
        case ready(PlayerViewModel)
    }

    private static var sharedStorage = SharedStorage.uninitialized

    static var shared: PlayerViewModel {
        if let player = existingShared { return player }
        guard case .uninitialized = sharedStorage else {
            preconditionFailure("PlayerViewModel.shared accessed during initialization")
        }
        sharedStorage = .initializing
        let player = PlayerViewModel()
        sharedStorage = .ready(player)
        return player
    }

    static var existingShared: PlayerViewModel? {
        guard case .ready(let player) = sharedStorage else { return nil }
        return player
    }

    var backend: PlayerBackend { activeBackend }

    var backendKind: PlayerEngineKind { activeBackendKind }

    let preferredBackendKind: PlayerEngineKind

    @ObservationIgnored
    var activeBackend: PlayerBackend
    @ObservationIgnored
    var activeBackendKind: PlayerEngineKind

    @ObservationIgnored
    var backendInstances: [PlayerEngineKind: PlayerBackend] = [:]

    // MARK: - Modular Sub-Stores (Isolated Observation Scopes)

    @ObservationIgnored
    let clock = PlaybackClockState()
    @ObservationIgnored
    let chrome = PlayerChromeState()
    @ObservationIgnored
    let routeOwnership = PlayerRouteOwnershipCoordinator()
    @ObservationIgnored
    let session = PlayerSessionState()

    // MARK: - Session State Facade

    var isPlaying: Bool {
        get { session.isPlaying }
        set {
            if !newValue { revokeEqualizerMaintenancePermission() }
            session.isPlaying = newValue
        }
    }

    // MARK: - Playback Clock State Facade

    var mediaTime: TimeInterval {
        get { clock.mediaTime }
        set { clock.mediaTime = newValue }
    }

    var mediaTimeMovedAt: TimeInterval {
        get { clock.mediaTimeMovedAt }
        set { clock.mediaTimeMovedAt = newValue }
    }

    var bufferedTimeStorage: TimeInterval {
        get { clock.bufferedTimeStorage }
        set { clock.bufferedTimeStorage = newValue }
    }

    var bufferedTimeProjection: BufferedTimeUIProjection {
        get { clock.bufferedTimeProjection }
        set { clock.bufferedTimeProjection = newValue }
    }

    var bufferedDisplayDiagnostic: BufferedDisplayDiagnosticSample? {
        get { clock.bufferedDisplayDiagnostic }
        set { clock.bufferedDisplayDiagnostic = newValue }
    }

    var bufferedTime: TimeInterval {
        get { clock.bufferedTime }
        set {
            let value = Self.normalizedBufferedTime(newValue)
            resetBufferedTime(raw: value, displayedEnd: value > 0 ? value : nil)
        }
    }

    var canPublishBufferedDisplay: Bool { !terminalOpenFailure && error == nil }

    var displayedBufferedRange: BufferedDisplayRange? {
        let range = clock.publishedBufferedRange
        return canPublishBufferedDisplay ? range : nil
    }

    var displayedBufferedTime: TimeInterval? { displayedBufferedRange?.end }

    var duration: TimeInterval {
        get { clock.duration }
        set { clock.duration = newValue }
    }

    var isBuffering: Bool {
        get { clock.isBuffering }
        set { clock.isBuffering = newValue }
    }

    var unavailability: PlaybackUnavailability? {
        get { session.unavailability }
        set { session.unavailability = newValue }
    }

    var playbackRate: Float {
        get { session.playbackRate }
        set { session.playbackRate = newValue }
    }

    var currentQuality: Int {
        get { session.currentQuality }
        set {
            if newValue != session.currentQuality { revokeEqualizerMaintenancePermission() }
            session.currentQuality = newValue
        }
    }

    // MARK: - Chrome State Facade

    var isFullscreen: Bool {
        get { chrome.isFullscreen }
        set { chrome.isFullscreen = newValue }
    }

    @ObservationIgnored
    var fullscreenTransition = FullscreenTransitionCoalescer()

    @ObservationIgnored
    weak var fullscreenPresentation: (any PlayerFullscreenPresentation)?

    @ObservationIgnored
    var fullscreenPresentationReceipt: PlayerPresentationReceipt?

    var isPortraitContent: Bool {
        get { chrome.isPortraitContent }
        set { chrome.isPortraitContent = newValue }
    }

    var danmakuPortraitHint: Bool? {
        guard mode == .vod else { return nil }
        return portraitPropagation.apiHint
    }

    var inlineCondensed: Bool {
        get { chrome.inlineCondensed }
        set { chrome.inlineCondensed = newValue }
    }

    var portraitCondenseLocked: Bool {
        get { chrome.portraitCondenseLocked }
        set { chrome.portraitCondenseLocked = newValue }
    }

    var showControls: Bool {
        get { chrome.showControls }
        set { chrome.showControls = newValue }
    }

    var showStats: Bool {
        get { chrome.showStats }
        set { chrome.showStats = newValue }
    }

    var ambientModeEnabled: Bool {
        get { chrome.ambientModeEnabled }
        set { chrome.ambientModeEnabled = newValue }
    }

    var videoSuperResolutionMode: VideoSuperResolutionMode {
        get { session.videoSuperResolutionMode }
        set { session.videoSuperResolutionMode = newValue }
    }

    var videoFrameInterpolationEnabled: Bool {
        get { session.videoFrameInterpolationEnabled }
        set { session.videoFrameInterpolationEnabled = newValue }
    }

    var videoInterpolationRate: VideoInterpolationRate {
        get { session.videoInterpolationRate }
        set { session.videoInterpolationRate = newValue }
    }

    var videoSuperResolutionScale: VideoSuperResolutionScale {
        get { session.videoSuperResolutionScale }
        set { session.videoSuperResolutionScale = newValue }
    }

    /// Defaults last applied to the per-player choices above; tuning-only changes don't reset them.
    @ObservationIgnored var appliedVideoEnhancementDefaults = VideoEnhancementDefaultsSnapshot.current

    var equalizerConfiguration: PlayerEqualizerConfiguration {
        get { session.equalizerConfiguration }
        set { session.equalizerConfiguration = newValue }
    }

    @ObservationIgnored var currentEqualizerMaintenancePermit: AudioMaintenancePermit?

    var equalizerStatus: PlayerEqualizerStatus { backend.equalizerStatus }
    var equalizerPresentationIdentity: PlayerEqualizerPresentationIdentity? {
        guard let owner = currentOwnerLease, currentURL != nil, error == nil, unavailability == nil,
              !terminalOpenFailure, !invalidatedBackendResources,
              let source = decoderRecoverySource() else { return nil }
        return PlayerEqualizerPresentationIdentity(
            owner: owner, source: source, loadGeneration: loadGeneration,
            backend: ObjectIdentifier(backend)
        )
    }

    var effectiveEqualizerConfiguration: PlayerEqualizerConfiguration {
        var effective = equalizerConfiguration.normalized
        if !ExperimentalSettingsPolicy.isAllowed(.equalizer) { effective.enabled = false }
        return effective
    }

    var ambientCoverURL: String? {
        get { chrome.ambientCoverURL }
        set { chrome.ambientCoverURL = newValue }
    }

    var ambientOwnerLease: PlayerOwnerLease? {
        get { chrome.ambientOwnerLease }
        set { chrome.ambientOwnerLease = newValue }
    }

    var ambientStoryboard: [PlayerAmbientStoryboardFrame] {
        get { chrome.ambientStoryboard }
        set { chrome.ambientStoryboard = newValue }
    }

    var ambientStoryboardOwnerLease: PlayerOwnerLease? {
        get { chrome.ambientStoryboardOwnerLease }
        set { chrome.ambientStoryboardOwnerLease = newValue }
    }

    var ambientStoryboardLoadGeneration: Int? {
        get { chrome.ambientStoryboardLoadGeneration }
        set { chrome.ambientStoryboardLoadGeneration = newValue }
    }

    var ambientStoryboardContent: PlayerAmbientStoryboardLoader.Content? {
        get { chrome.ambientStoryboardContent }
        set { chrome.ambientStoryboardContent = newValue }
    }

    var ambientSelectionMediaTime: TimeInterval? {
        get { chrome.ambientSelectionMediaTime }
        set { chrome.ambientSelectionMediaTime = newValue }
    }

    var ambientSelectionContent: PlayerAmbientStoryboardLoader.Content? {
        get { chrome.ambientSelectionContent }
        set { chrome.ambientSelectionContent = newValue }
    }

    var ambientSelectionSource: PlayerAmbientSource? {
        get { chrome.ambientSelectionSource }
        set { chrome.ambientSelectionSource = newValue }
    }

    var ambientVideoLoadedOwner: PlayerOwnerLease? {
        get { chrome.ambientVideoLoadedOwner }
        set { chrome.ambientVideoLoadedOwner = newValue }
    }

    var ambientLiveImage: UIImage? {
        get { chrome.ambientLiveImage }
        set { chrome.ambientLiveImage = newValue }
    }

    var ambientLiveFrameSerial: UInt64 {
        get { chrome.ambientLiveFrameSerial }
        set { chrome.ambientLiveFrameSerial = newValue }
    }

    var lastAmbientLiveSampleWall: TimeInterval {
        get { chrome.lastAmbientLiveSampleWall }
        set { chrome.lastAmbientLiveSampleWall = newValue }
    }

    var ambientStoryboardLoader: PlayerAmbientStoryboardLoader {
        chrome.ambientStoryboardLoader
    }

    var ambientStoryboardRequest: PlayerAmbientStoryboardLoader.Request? {
        get { chrome.ambientStoryboardRequest }
        set { chrome.ambientStoryboardRequest = newValue }
    }

    var ambientSource: PlayerAmbientSource? {
        guard let request = ambientStoryboardRequest,
              ambientSelectionContent == request.content,
              admitsAmbientStoryboardContent(request),
              ExperimentalSettingsPolicy.isAllowed(.ambient) else { return nil }
        return ambientSelectionSource
    }

    var mode: PlayerMode {
        get { session.mode }
        set {
            let oldValue = session.mode
            if newValue != oldValue {
                revokeEqualizerMaintenancePermission()
                if oldValue == .live {
                    cancelLiveRecoveryTasks(resetAttempts: true, clearBackups: true)
                }
            }
            session.mode = newValue
            retireRecoveryCoverIfAuthorityChanged()
            guard newValue != oldValue, newValue != .vod else { return }
            releaseDanmaku()
        }
    }

    var error: String? {
        get { session.error }
        set {
            if newValue != nil {
                backgroundExecution.end(reason: "playback-error")
                revokeEqualizerMaintenancePermission()
                cancelLiveRecoveryTasks(resetAttempts: false)
            }
            session.error = newValue
            if session.error != nil { retireCDNFrameCover() }
            if session.error != nil, let recoveryCover {
                clearRecoveryCover(matching: recoveryCover.identity)
            }
        }
    }
    @ObservationIgnored
    var terminalOpenFailure = false {
        willSet { if newValue { revokeEqualizerMaintenancePermission() } }
    }
    var stats = PlaybackStats() {
        didSet {
            if videoResolution != stats.resolution {
                videoResolution = stats.resolution
            }
            if activeStreamCodec != stats.codec {
                activeStreamCodec = stats.codec
            }
            let enhancementStatus = VideoEnhancementControlStatus(telemetry: stats.videoEnhancement)
            if videoEnhancementControlStatus != enhancementStatus {
                videoEnhancementControlStatus = enhancementStatus
            }
        }
    }
    private(set) var videoEnhancementControlStatus = VideoEnhancementControlStatus(telemetry: nil)
    private(set) var videoResolution = ""
    private(set) var activeStreamCodec = ""
    var multiConnectionDisplay = MultiConnectionDisplay()
    @ObservationIgnored var multiConnectionAdmissionAttempted = false
    @ObservationIgnored var multiConnectionRateResetAt: TimeInterval = 0
    @ObservationIgnored var multiConnectionPayloadSampler = MultiConnectionPayloadSampler()
    @ObservationIgnored var multiConnectionTelemetry = MultiConnectionTelemetry.unsupported
    var availableQualities: [(id: Int, desc: String)] {
        get { session.availableQualities }
        set { session.availableQualities = newValue }
    }

    var availableCodecs: [VideoCodecPreference] {
        get { session.availableCodecs }
        set { session.availableCodecs = newValue }
    }

    var availableAudioTiers: [AudioQualityTier] {
        get { session.availableAudioTiers }
        set { session.availableAudioTiers = newValue }
    }

    var playingAudioTier: AudioQualityTier? {
        get { session.playingAudioTier }
        set { session.playingAudioTier = newValue }
    }

    @ObservationIgnored
    var audioTierOverride: AudioQualityTier?

    var currentURL: URL? {
        get { session.currentURL }
        set {
            if newValue != session.currentURL { revokeEqualizerMaintenancePermission() }
            session.currentURL = newValue
        }
    }

    var currentDASHAudioURL: URL? {
        get { session.currentDASHAudioURL }
        set {
            if newValue != session.currentDASHAudioURL { revokeEqualizerMaintenancePermission() }
            session.currentDASHAudioURL = newValue
        }
    }

    @ObservationIgnored var multiConnectionVideoURLs: [String] = []
    @ObservationIgnored var multiConnectionAudioURLs: [String] = []
    @ObservationIgnored var multiConnectionQuietWindows = MultiConnectionQuietWindows()
    @ObservationIgnored var multiConnectionWasEnabled = false
    @ObservationIgnored var multiConnectionLoadClass: MultiConnectionNetworkClass?
    @ObservationIgnored private var multiConnectionSweepObserver: CDNMeasurementObservation?

    // MARK: - Route Ownership Facade

    var ownerKey: String {
        get { routeOwnership.ownerKey }
        set {
            if newValue != routeOwnership.ownerKey {
                backgroundExecution.end(reason: "owner-change")
                revokeEqualizerMaintenancePermission()
                cancelLiveRecoveryTasks(resetAttempts: true, clearBackups: true)
            }
            routeOwnership.ownerKey = newValue
        }
    }

    var ownerLeaseGeneration: UInt64 {
        get { routeOwnership.ownerLeaseGeneration }
        set {
            backgroundExecution.end(reason: "owner-lease-change")
            revokeEqualizerMaintenancePermission()
            cancelLiveRecoveryTasks(resetAttempts: true, clearBackups: true)
            routeOwnership.ownerLeaseGeneration = newValue
        }
    }

    var activeSceneID: UUID? {
        get { routeOwnership.activeSceneID }
        set { routeOwnership.activeSceneID = newValue }
    }

    var presentationResetPendingForOwnerChange: Bool {
        get { routeOwnership.presentationResetPendingForOwnerChange }
        set { routeOwnership.presentationResetPendingForOwnerChange = newValue }
    }

    var surfaceAuthority: PlayerSurfaceAuthority {
        get { routeOwnership.surfaceAuthority }
        set { routeOwnership.surfaceAuthority = newValue }
    }

    var activeSurfaceLease: PlayerSurfaceLease? {
        get { routeOwnership.activeSurfaceLease }
        set { routeOwnership.activeSurfaceLease = newValue }
    }

    var deferredPiPOwnerExit: DeferredPiPOwnerExit {
        get { routeOwnership.deferredPiPOwnerExit }
        set { routeOwnership.deferredPiPOwnerExit = newValue }
    }

    @ObservationIgnored
    var portraitPropagation = PlayerPortraitPropagationState(
        mode: .vod,
        apiHint: nil,
        initialIsPortrait: false
    )

    var playerGeneration: Int {
        get { routeOwnership.playerGeneration }
        set { routeOwnership.playerGeneration = newValue }
    }

    @ObservationIgnored
    weak var renderAttachment: (any PlayerRenderAttachment)?
    @ObservationIgnored
    var renderAttachmentSurfaceLease: PlayerSurfaceLease?

    var inlineReturnTarget: PlayerInlineReturnTarget? {
        get { routeOwnership.inlineReturnTarget }
        set { routeOwnership.inlineReturnTarget = newValue }
    }

    var currentAid: Int? {
        get { session.currentAid }
        set {
            if newValue != session.currentAid {
                backgroundExecution.end(reason: "content-change")
                revokeEqualizerMaintenancePermission()
            }
            session.currentAid = newValue
            retireRecoveryCoverIfAuthorityChanged()
        }
    }

    var currentCid: Int? {
        get { session.currentCid }
        set {
            let oldValue = session.currentCid
            if newValue != oldValue {
                backgroundExecution.end(reason: "part-change")
                revokeEqualizerMaintenancePermission()
            }
            session.currentCid = newValue
            retireRecoveryCoverIfAuthorityChanged()
            guard newValue != oldValue, newValue == nil else { return }
            releaseDanmaku()
        }
    }

    var currentBvid: String? {
        get { session.currentBvid }
        set { session.currentBvid = newValue }
    }

    var offlineAsset: OfflinePlaybackAsset? {
        get { session.offlineAsset }
        set {
            if newValue != session.offlineAsset { revokeEqualizerMaintenancePermission() }
            session.offlineAsset = newValue
        }
    }

    @ObservationIgnored
    var offlineDecoderLabelTask: Task<Void, Never>?
    @ObservationIgnored
    var offlineDecoderLabelRequestID: UUID?

    var currentRoomID: Int? {
        get { session.currentRoomID }
        set {
            if newValue != session.currentRoomID {
                revokeEqualizerMaintenancePermission()
                cancelLiveRecoveryTasks(resetAttempts: true, clearBackups: true)
            }
            session.currentRoomID = newValue
        }
    }

    var currentLiveQuality: Int {
        get { session.currentLiveQuality }
        set {
            if newValue != session.currentLiveQuality { revokeEqualizerMaintenancePermission() }
            session.currentLiveQuality = newValue
        }
    }
    var historyReportTask: Task<Void, Never>?
    var offlineProgressTask: Task<Void, Never>?
    var playbackWatchdogTask: Task<Void, Never>?
    var lastWatchdogTime: TimeInterval = -1
    var currentFault: PlaybackFault?
    var faultTicks = 0
    var healthOutcome: (reason: String, ticks: Int)?
    static let healthOutcomeHeartbeatTicks = 12
    @ObservationIgnored var coalescedRecoveryWatchdog: (token: UInt64, ticks: Int)?
    static let maxCoalescedWatchdogTicks = 3
    var budget = RecoveryBudget()
    @ObservationIgnored var streamRecovery: StreamRecoveryCycle?
    @ObservationIgnored var streamSourceRequestAdmission: (@MainActor @Sendable () -> Bool)?

    static let maxLiveRefreshReconnects = 4
    static let liveRefreshBackoffSeconds: [TimeInterval] = [2, 4, 8, 12]
    static let liveStabilityResetSeconds: TimeInterval = 10
    @ObservationIgnored var liveBackupURLs: [URL] = []
    @ObservationIgnored var liveActiveSourceKind: DemandLiveSourceKind?
    @ObservationIgnored var liveReconnectAttempts = 0
    @ObservationIgnored var liveRecoveryGeneration: UInt64 = 0
    @ObservationIgnored var liveReconnectTask: Task<Void, Never>?
    @ObservationIgnored var liveStabilityResetTask: Task<Void, Never>?
    @ObservationIgnored var liveNeedsReconnectOnResume = false

    @ObservationIgnored let backgroundExecution = PlayerBackgroundExecution()
    struct NativeAudioRepairAttempt: Equatable {
        let owner: PlayerOwnerLease
        let backend: ObjectIdentifier
        let generation: UInt64
        let load: Int
    }
    @ObservationIgnored var nativeAudioRepairAttempt: NativeAudioRepairAttempt?
    var audioSessionPolicy = PlayerAudioSessionPolicy()
    var audioSessionInterrupted: Bool { audioSessionPolicy.suppressesPlayback }
    var audioSessionNeedsReactivation: Bool { audioSessionPolicy.needsActivation }

    enum MediaResetSource {
        case vod(aid: Int, cid: Int, quality: Int, source: StreamSource, position: TimeInterval)
        case offline(OfflinePlaybackAsset, position: TimeInterval)
        case live(roomID: Int, quality: Int)
    }

    var mediaResetRecovery = PlayerMediaResetRecovery<MediaResetSource>()
    var invalidatedBackendResources = false {
        willSet { if newValue { revokeEqualizerMaintenancePermission() } }
    }

    var isDASHMode: Bool {
        get { session.isDASHMode }
        set { session.isDASHMode = newValue }
    }

    var currentVideoIsAV1: Bool {
        get { session.currentVideoIsAV1 }
        set { session.currentVideoIsAV1 = newValue }
    }

    @ObservationIgnored
    var lastOnPlayAt: CFTimeInterval = 0

    var lastDisplayUpdate: CFTimeInterval {
        get { clock.lastDisplayUpdate }
        set { clock.lastDisplayUpdate = newValue }
    }

    enum PlaybackIntent {
        case playing
        case pausedByUser
        case pausedBySystem
    }

    var playbackIntent: PlaybackIntent {
        get { session.playbackIntent }
        set {
            if newValue != .playing {
                backgroundExecution.end(reason: "intent-paused")
                revokeEqualizerMaintenancePermission()
                suspendStreamRecovery()
                if newValue == .pausedByUser {
                    let hadPendingLiveReconnect = liveReconnectTask != nil
                    cancelLiveRecoveryTasks(resetAttempts: false)
                    if hadPendingLiveReconnect {
                        liveNeedsReconnectOnResume = true
                        isBuffering = false
                    }
                }
            }
            session.playbackIntent = newValue
        }
    }
    var userWantsPlaying: Bool { playbackIntent != .pausedByUser }
    var canAutoRevive: Bool {
        userWantsPlaying
            && !audioSessionInterrupted
            && !currentPlaybackTerminalState.isTerminal
            && mediaResetRecovery.request == nil
            && !invalidatedBackendResources
    }

    func updateIsPlaying(transportRunning: Bool) {
        let wasPlaying = isPlaying
        isPlaying = transportRunning && userWantsPlaying && !audioSessionInterrupted
        if transportRunning, !isPlaying { backend.pause() }
        if wasPlaying != isPlaying {
            resetMultiConnectionRate()
            publishMultiConnectionDisplay(rate: nil)
            syncDanmakuTransport()
        }
    }

    var playbackTerminalState: PlaybackTerminalState {
        get { session.playbackTerminalState }
        set {
            if newValue.isTerminal {
                backgroundExecution.end(reason: "terminal")
                revokeEqualizerMaintenancePermission()
                cancelLiveRecoveryTasks(resetAttempts: false)
            }
            session.playbackTerminalState = newValue
        }
    }

    var playbackEnded: Bool { playbackTerminalState.isNaturalEnd }

    var currentPlaybackTerminalState: PlaybackTerminalState {
        if playbackTerminalState.isTerminal { return playbackTerminalState }
        if error != nil { return .terminalFailure }
        return .active
    }
    var cdnFallbackActive = false
    var activeCDNSwitch: CDNSwitchTransaction?
    var cdnSwitchInFlight: Bool { activeCDNSwitch != nil }
    var recoveryBudgetIdentity = UUID() {
        willSet { backgroundExecution.end(reason: "recovery-owner-change") }
    }
    var cdnSwitchIntentGeneration: UInt64 = 0
    var cdnFrameCover: CDNFrameCoverPolicy?
    var freezeFrame: UIImage?
    var freezeFrameSetAt: CFTimeInterval = 0
    var freezeFrameAwaitingFreshProof = false
    var freezeFrameExpectedSessionGeneration: UInt64?
    var freezeFrameIdentity: UInt64 = 0
    var currentFreezeFrameIdentity: UInt64 { freezeFrameIdentity }
    var recoveryCover: PlayerRecoveryCover?
    static let freezeFrameSafetyTimeout: CFTimeInterval = 8
    @ObservationIgnored
    var transitionCoverExpiry = PlayerTransitionCoverExpiry()

    var outgoingRouteStills: [String: UIImage] {
        get { routeOwnership.outgoingRouteStills }
        set { routeOwnership.outgoingRouteStills = newValue }
    }

    var outgoingRouteStillExpiry: PlayerOutgoingRouteStillExpiry {
        routeOwnership.outgoingRouteStillExpiry
    }

    var departedRouteStillOwners: [String] {
        get { routeOwnership.departedRouteStillOwners }
        set { routeOwnership.departedRouteStillOwners = newValue }
    }

    var outgoingRouteStill: OutgoingRouteStill? {
        get { routeOwnership.outgoingRouteStill }
        set { routeOwnership.outgoingRouteStill = newValue }
    }

    var lastSeekRequest: TimeInterval?

    var fpsEverLive = false

    var clockEverAdvancedThisStream = false
    static let primingCeiling: TimeInterval = 15

    var lastBytesAdvanceAt: TimeInterval = 0
    static let dataFlowWindow: TimeInterval = 3
    static let bufferedRunwayFloor: TimeInterval = 1.5

    var decoderSessionSuspect = false

    var needsInlineSurfaceRebuild = false

    var needsReloadBeforeExplicitPlay = false
    var explicitPlayReloadInFlight = false

    var muteAuthority = MuteAuthority()

    var isSeekInFlight: Bool { backend.pendingSeekTarget != nil }

    var pendingSeekTarget: TimeInterval? {
        get { clock.pendingSeekTarget }
        set { clock.pendingSeekTarget = newValue }
    }

    var pendingSeekTask: Task<Void, Never>?
    var reopenSeekTask: Task<Void, Never>?
    @ObservationIgnored var activeSeekToken: SeekSettlementToken?
    var resumeAtTime: TimeInterval?

    var lastLoadStartPosition: TimeInterval = 0

    var resumeIsFromHistory = false
    var pendingRestartNotice = false

    var recoveryPosition: TimeInterval {
        pendingSeekTarget ?? durableResumeTarget ?? resumeAtTime ?? mediaTime
    }

    var durableResumeTarget: TimeInterval?
    var durableResumeArmedFrom: TimeInterval = 0
    var durableResumeArmedAtWall: CFTimeInterval = 0
    static let durableResumeStaleness: CFTimeInterval = 90

    var resumeTargetTime: TimeInterval {
        pendingSeekTarget ?? mediaTime
    }

    static let nearEndFreezeThreshold: TimeInterval = NearEndClockPolicy.freezeThreshold
    var nearEndStallWallStart: CFTimeInterval?
    var nearEndStallMediaStart: TimeInterval?

    var nearEndDisplayTime: TimeInterval? {
        get { clock.nearEndDisplayTime }
        set { clock.nearEndDisplayTime = newValue }
    }

    var nearEndStallDriveTask: Task<Void, Never>?
    var nearEndFreezeArmTask: Task<Void, Never>?
    var nearEndFreezeCandidateMedia: TimeInterval?
    var nearEndStallLogged = false

    struct SettledSeekDisplaySample: Equatable {
        let position: TimeInterval
        let loadGeneration: Int
        let backend: ObjectIdentifier
        let backendGeneration: UInt64
        let owner: String
        let url: URL?
    }

    var settledSeekDisplaySample: SettledSeekDisplaySample? {
        get { clock.settledSeekDisplaySample }
        set { clock.settledSeekDisplaySample = newValue }
    }
    @ObservationIgnored var nativeSeekCompletedRequestSerial: UInt64?

    var settledSeekDisplayTime: TimeInterval? {
        guard let sample = settledSeekDisplaySample,
              sample.loadGeneration == loadGeneration,
              sample.backend == ObjectIdentifier(backend),
              sample.backendGeneration == backend.runtimeGeneration,
              sample.owner == ownerKey,
              sample.url == currentURL else { return nil }
        return sample.position
    }

    var displayTime: TimeInterval {
        resolvedDisplayTime(mediaTime: settledSeekDisplayTime ?? mediaTime)
    }

    var canSampleSeekStripClock: Bool {
        mode.isSeekable && currentURL != nil && !terminalOpenFailure
            && isPlaying && nativeSeekIsReady && pendingSeekTarget == nil
            && !playbackEnded && nearEndDisplayTime == nil
    }

    nonisolated static let networkMonitor = NWPathMonitor()
    nonisolated static let multiConnectionPath = OSAllocatedUnfairLock(
        initialState: MultiConnectionNetworkPath()
    )
    nonisolated static var multiConnectionNetworkPath: MultiConnectionNetworkPath {
        multiConnectionPath.withLock { $0 }
    }
    private nonisolated static let _currentNetwork = OSAllocatedUnfairLock(initialState: NetworkType.wifi)
    nonisolated static var currentNetwork: NetworkType {
        get { _currentNetwork.withLock { $0 } }
        set { _currentNetwork.withLock { $0 = newValue } }
    }

    private init() {
        let env = ProcessInfo.processInfo.environment
        if ExperimentalSettingsPolicy.diagnosticsEnabled,
           env["PLAYER_DEBUG"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-player-debug")
            || ProcessInfo.processInfo.arguments.contains("player-debug=1") {
            PlayerLog.isEnabled = true
        }
        var kind = PlayerEngineKind.vodPreferred
        let continuation = PlayerPlaybackPreferences.playbackContinuationConfiguration
        let initialBackend: PlayerBackend
        if let preferred = PlayerBackendFactory.makeBackend(kind: kind, continuation: continuation) {
            initialBackend = preferred
        } else {
            PlayerLog.diagnostic(
                "[Player] preferred engine \(kind.shortLabel) unavailable — " +
                "starting on \(PlayerEngineKind.defaultKind.shortLabel)"
            )
            kind = PlayerEngineKind.defaultKind
            guard let fallback = PlayerBackendFactory.makeBackend(kind: kind, continuation: continuation) else {
                preconditionFailure("The default engine must always be constructible")
            }
            initialBackend = fallback
        }
        preferredBackendKind = kind
        activeBackendKind = kind
        activeBackend = initialBackend
        backendInstances[kind] = initialBackend
        initialBackend.equalizerConfiguration = effectiveEqualizerConfiguration
        initialBackend.videoEnhancementConfiguration = effectiveVideoEnhancementConfiguration
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let bundleBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        PlayerLog.log(
            "[Build] continuation-switch=20260729-v3 " +
            "version=\(bundleVersion) build=\(bundleBuild)"
        )
        PlayerLog.log(
            "[Player] backend: \(backendKind.shortLabel) (\(backendKind.displayName)) " +
            "— product default: demand; explicit preferences/launch overrides honored"
        )
        ExperimentalSettingsStore.shared.addObserver(owner: self) { owner, changes in
            owner.applyExperimentalPolicy(changes)
        }
        setupBackendCallbacks()
        multiConnectionSweepObserver = SmartCDNSelector.shared.observeMeasurementActivity { [weak self] active in
            guard let self else { return }
            self.multiConnectionQuietWindows.sweepActive = active
            self.refreshMultiConnectionQuiet()
        }

        StartupTrace.onComplete = { [weak self] totalMs in
            self?.stats.lastStartup = "\(totalMs) ms (proxy)"
        }
        SeekTrace.onComplete = { [weak self] timing in
            let target = timing.target.isFinite
                ? "\(String(format: "%.1f", timing.target))s"
                : "n/a"
            self?.stats.lastSeek =
                "\(timing.path) → \(target) · " +
                "clk \(timing.settleMs) · " +
                "vis \(timing.visibleMs.map(String.init) ?? "–") · " +
                "run \(timing.runUpMs.map(String.init) ?? "–") ms"
        }
        Self.startNetworkMonitor()

        PowerProfiler.shared.playerMetrics = { [weak self] in
            guard let self, self.currentURL != nil else { return nil }
            return "fps=\(String(format: "%.1f", self.stats.fps))"
                + " dec=\(self.stats.decoderType)"
                + " net=\(Int(self.stats.networkSpeed / 1024))KB/s"
                + (self.mode == .live ? " live" : "")
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            let event = PlayerAudioSessionEvent.interruption(
                type: note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                options: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            )
            MainActor.assumeIsolated {
                if let event { PlayerViewModel.shared.handleAudioSessionEvent(event) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            let event = PlayerAudioSessionEvent.route(
                reason: note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            )
            MainActor.assumeIsolated {
                if let event { PlayerViewModel.shared.handleAudioSessionEvent(event) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PlayerViewModel.shared.handleAudioSessionEvent(.mediaServicesReset)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let vm = PlayerViewModel.shared
                vm.noteDanmakuApplicationActivityChanged(isActive: false)
                vm.reconcileAmbientStoryboard(allowWork: false)
                guard vm.usesDemandPresentationContinuity else { return }
                vm.backend.noteDemandPiPEnvironmentWillResignActive()
                vm.markDemandBackgroundStage("resign", startsTransition: true)
                PlayerViewModel.probeMainThreadAcrossTransition()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let vm = PlayerViewModel.shared
                let postedAt = ContinuousClock.now
                DispatchQueue.main.async {
                    let elapsed = ContinuousClock.now - postedAt
                    let milliseconds = elapsed.components.seconds * 1000
                        + elapsed.components.attoseconds / 1_000_000_000_000_000
                    PlayerLog.log(
                        "[Lifecycle] background main-queue hop=\(milliseconds)ms"
                    )
                }
                vm.handleDidEnterBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let vm = PlayerViewModel.shared
                let postedAt = ContinuousClock.now
                DispatchQueue.main.async {
                    let elapsed = ContinuousClock.now - postedAt
                    let milliseconds = elapsed.components.seconds * 1000
                        + elapsed.components.attoseconds / 1_000_000_000_000_000
                    PlayerLog.log(
                        "[Lifecycle] foreground main-queue hop=\(milliseconds)ms"
                    )
                }
                vm.handleWillEnterForeground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let vm = PlayerViewModel.shared
                vm.reconcileAmbientStoryboard()
                vm.synchronizeForegroundEnvironment()
                if vm.resumeStreamRecoveryIfNeeded() { return }
                vm.scheduleForegroundLivenessCheck()
            }
        }

        installDanmakuGateObserver()
        installDanmakuMemoryWarningObserver()
    }

    var lifecycleRecoveryTask: Task<Void, Never>?
    var lifecycleRecovery = LifecycleRecoveryCoordinator()
    @ObservationIgnored
    lazy var demandContinuationAdapter = DemandContinuationEffectAdapter(sink: self)
    @ObservationIgnored
    var demandContinuationOperationRunner: DemandContinuationOperationRunner?
    @ObservationIgnored
    var demandForegroundStageTape: DemandForegroundStageTape?
    @ObservationIgnored
    var demandBackgroundStageTape: DemandBackgroundStageTape?
    var demandPresentationLiveness = DemandPresentationLivenessAuthority()

    struct DemandStageSessionKey: Equatable {
        let sessionGeneration: UInt64
        let ownerLeaseGeneration: UInt64

        init(_ fence: DemandPresentationFence) {
            sessionGeneration = fence.sessionGeneration
            ownerLeaseGeneration = fence.ownerLeaseGeneration
        }
    }

    struct DemandForegroundStageTape {
        let base: ContinuousClock.Instant
        var stages: [(String, Duration)] = []
        var session: DemandStageSessionKey?

        init(base: ContinuousClock.Instant) { self.base = base }

        mutating func mark(_ stage: String) {
            guard stages.count < 12 else { return }
            stages.append((stage, ContinuousClock.now - base))
        }

        var hasMarkedActivation: Bool {
            stages.contains { $0.0 == "active" }
        }

        var summary: String {
            stages.map { stage, elapsed in
                let milliseconds = elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000
                return "\(stage)=\(milliseconds)ms"
            }.joined(separator: " ")
        }
    }

    struct DemandBackgroundStageTape {
        let base: ContinuousClock.Instant
        var stages: [(String, Duration)] = []

        init(base: ContinuousClock.Instant) { self.base = base }

        mutating func mark(_ stage: String) {
            guard stages.count < 12 else { return }
            stages.append((stage, ContinuousClock.now - base))
        }

        var summary: String {
            stages.map { stage, elapsed in
                let milliseconds = elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000
                return "\(stage)=\(milliseconds)ms"
            }.joined(separator: " ")
        }
    }

    static var applicationStateLabel: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
    var decoderRecoveryAdmission = DecoderRecoveryAdmission()

    struct PendingLifecycleAdmission: Equatable {
        let epoch: UInt64
        let trigger: LifecycleRecoveryCoordinator.Trigger
        let token: UInt64
        let provisionalFence: LifecycleReadinessFence
    }

    enum LifecycleReadinessEvidence {
        case backendCallback
        case loaderReturn
    }

    @ObservationIgnored
    var pendingLifecycleAdmission: PendingLifecycleAdmission?
    @ObservationIgnored
    var lifecycleReadinessFence: LifecycleReadinessFence?
    @ObservationIgnored
    var nonLifecycleRecoveryTicket: DecoderRecoveryAdmission.Ticket?
    @ObservationIgnored
    var nonLifecycleRecoveryTask: (token: UInt64, task: Task<Void, Never>)?

    var usesDemandPresentationContinuity: Bool {
        activeBackendKind == .demandPaced
    }

    var isPiPRestoringInline: Bool {
        usesDemandPresentationContinuity
            && lifecycleRecovery.isPiPRestoringInline
    }

    var clampedDecoderRecoveryPosition: TimeInterval {
        let raw = recoveryPosition.isFinite ? recoveryPosition : 0
        switch mode {
        case .live:
            return 0
        case .vod:
            return SeekTargetAdmission.admissibleTarget(
                requested: raw,
                duration: duration,
                reserve: backend.seekLaunchReserve
            )
        case .offline:
            guard let asset = offlineAsset else { return 0 }
            return OfflinePlaybackRecoveryPolicy.request(
                for: asset,
                position: raw
            ).position
        }
    }

    struct CachedDemandLivenessIdentity: Equatable {
        enum Key: Equatable {
            case vod(
                aid: Int,
                cid: Int,
                quality: Int,
                source: StreamSource,
                ownerKey: String,
                ownerLeaseGeneration: UInt64
            )
            case live(
                roomID: Int,
                quality: Int,
                ownerKey: String,
                ownerLeaseGeneration: UInt64
            )
            case offline(
                aid: Int,
                cid: Int,
                quality: Int,
                ownerKey: String,
                ownerLeaseGeneration: UInt64
            )
        }

        var key: Key
        var source: DemandLivenessSourceIdentity
    }

    @ObservationIgnored var cachedDemandLivenessIdentity: CachedDemandLivenessIdentity?

    // MARK: - Now Playing (PiP / Lock Screen / Control Center)

    var lastNowPlayingPushAt: CFTimeInterval = 0
    @ObservationIgnored
    lazy var nowPlayingStateEdgeAdapter: NowPlayingStateEdgeAdapter = {
        NowPlayingStateEdgeAdapter(
            sink: NowPlayingCenter.shared,
            fenceValidator: { [weak self] fence in
                guard let self else { return false }
                return self.acceptsNowPlayingEdgeFence(fence)
            }
        )
    }()
    @ObservationIgnored
    let playbackTerminalSettlement = PlaybackTerminalSettlement()
    var nowPlayingMeta: (title: String, artist: String, cover: String?)?

    var nowPlayingCommandsAreActionable: Bool {
        currentOwnerLease != nil
            && currentURL != nil
            && !terminalOpenFailure
            && !currentPlaybackTerminalState.isTerminal
    }

    nonisolated static let danmakuLastPathSignature = OSAllocatedUnfairLock<String?>(
        initialState: nil
    )

    // MARK: - Network-selected Playback Preferences

    static var preferredQuality: Int {
        PlayerPlaybackPreferences.preferredQuality(for: currentNetwork)
    }

    static var preferredAudioQuality: AudioQualityTier {
        PlayerPlaybackPreferences.preferredAudioQuality(for: currentNetwork)
    }

    // MARK: - Playback Order & Hold Fast-Forward

    var playbackOrder: PlaybackOrder {
        get { session.playbackOrder }
        set {
            session.playbackOrder = newValue
            PlayerPlaybackPreferences.playbackOrder = newValue
        }
    }

    var onPlaybackEnded: (() -> Void)?

    var onPreviousEpisode: (() -> Void)?
    var onNextEpisode: (() -> Void)?

    var pgcSeasonContext: (sid: Int, type: Int?)?

    var rateBeforeHold: Float? {
        get { session.rateBeforeHold }
        set { session.rateBeforeHold = newValue }
    }

    var isHoldFastForwarding: Bool { rateBeforeHold != nil }

    var supportsHoldFastForward: Bool {
        mode.supportsPlaybackRate && backendKind.supportsHoldFastForward
    }

    // MARK: - Video Scale Mode (fullscreen aspect options)

    var scaleMode: VideoScaleMode {
        get { session.scaleMode }
        set {
            session.scaleMode = newValue
            applyScaleMode()
        }
    }

    // MARK: - CC Subtitles (x/player/wbi/v2 subtitle list)

    struct SubtitleCue: Sendable {
        let from: Double
        let to: Double
        let content: String
    }

    enum SubtitleCueTimelineSearchResult: Sendable {
        case unavailable
        case noMatch
        case match(String)
    }

    struct SubtitleCueTimeline: Sendable {
        private let cueCount: Int

        init?(cues: [SubtitleCue]) {
            guard !cues.isEmpty else { return nil }
            var previousEnd: Double?
            for cue in cues {
                guard cue.from.isFinite, cue.to.isFinite, cue.from <= cue.to,
                      previousEnd.map({ cue.from > $0 }) ?? true else { return nil }
                previousEnd = cue.to
            }
            cueCount = cues.count
        }

        func search(at time: TimeInterval, cues: [SubtitleCue]) -> SubtitleCueTimelineSearchResult {
            guard time.isFinite, cues.count == cueCount else { return .unavailable }
            var lower = 0
            var upper = cueCount
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if cues[middle].from <= time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return .noMatch }
            let index = lower - 1
            return time <= cues[index].to ? .match(cues[index].content) : .noMatch
        }
    }

    var availableSubtitles: [PlayerV2Info.SubtitleBox.SubtitleItem] = []
    var activeSubtitleLan: String?
    var subtitleText: String?
    var subtitleCues: [SubtitleCue] = [] {
        didSet { subtitleCueTimeline = SubtitleCueTimeline(cues: subtitleCues) }
    }
    @ObservationIgnored var subtitleCueTimeline: SubtitleCueTimeline?
    @ObservationIgnored var subtitleSelectionGeneration: UInt64 = 0
    struct PendingPlayerInfo {
        let aid: Int
        let cid: Int
        let info: PlayerV2Info
        let handoff: PlayerInfoHandoffToken
    }

    var pendingPlayerInfo: PendingPlayerInfo?
    var playerInfoHandoffPolicy = PlayerInfoHandoffPolicy()

    @ObservationIgnored var danmakuGateEnabled = false
    @ObservationIgnored var danmakuGateObserver: DanmakuGateObserverToken?
    @ObservationIgnored var danmakuStore: DanmakuSegmentStore?
    @ObservationIgnored var danmakuApplicationActive = UIApplication.shared.applicationState == .active
    @ObservationIgnored var danmakuVisibleWorkSuspended = false
    @ObservationIgnored var danmakuHeldAtNaturalEnd = false
    @ObservationIgnored var danmakuMaskSource: (cid: Int, url: URL)?
    @ObservationIgnored var danmakuMaskStore: DanmakuMaskStore?
    @ObservationIgnored var danmakuSessionLedger = DanmakuSessionLedger()
    @ObservationIgnored var danmakuRetentionExpiry: Task<Void, Never>?
    @ObservationIgnored var danmakuMemoryWarningObserver: DanmakuGateObserverToken?
    @ObservationIgnored var danmakuRealignPending = false
    @ObservationIgnored var danmakuOpenPosition: TimeInterval?
    @ObservationIgnored var danmakuAdmittedUntil: TimeInterval = 0
    @ObservationIgnored var danmakuSpecialAdmittedUntil: TimeInterval = 0
    struct DanmakuVisibleIdentity {
        let progress: TimeInterval
        let isSelfSent: Bool
    }
    @ObservationIgnored var danmakuAdmittedIDs: [String: DanmakuVisibleIdentity] = [:]
    @ObservationIgnored var nextDanmakuEchoID: Int64 = -1
    @ObservationIgnored var danmakuRefillVisibleWindow = false
    @ObservationIgnored var danmakuTiming: DanmakuClockSync.LayerTiming?
    @ObservationIgnored weak var danmakuSink: DanmakuTimelineSink?
    @ObservationIgnored var danmakuSeekRequestSerial: UInt64 = 0
    @ObservationIgnored var danmakuSettledSeekRequestSerial: UInt64?
    struct DanmakuPiPSeekSettlement: Equatable {
        let operation: UInt64
        let fence: NowPlayingEdgeFence
    }
    @ObservationIgnored var danmakuLastPiPSeekSettlement: DanmakuPiPSeekSettlement?

    var nativeSeekIsReady: Bool {
        backend.isReadyToPlay
    }

    static let danmakuMode7LifetimeCeiling: TimeInterval = 10

    var fullscreenDanmakuComposerPresented: Bool {
        get { chrome.fullscreenDanmakuComposerPresented }
        set { chrome.fullscreenDanmakuComposerPresented = newValue }
    }

    var fullscreenDanmakuSendFailure: String?
    var fullscreenDanmakuSendFailureDraft: String?
    var fullscreenDanmakuUnsentDraft: String?

    struct FullscreenDanmakuDraftReceipt: Equatable {
        let presentation: PlayerPresentationReceipt
        let accountSession: UUID
        let id = UUID()
    }

    struct FullscreenDanmakuFailure: Equatable {
        let receipt: FullscreenDanmakuDraftReceipt
        let message: String
    }

    struct FullscreenDanmakuDraft {
        let receipt: FullscreenDanmakuDraftReceipt
        var text = ""
        var isDiscarded = false
    }

    @ObservationIgnored var fullscreenVODDanmakuDraft: FullscreenDanmakuDraft?
    var fullscreenVODDanmakuSendFailure: FullscreenDanmakuFailure?

    var danmakuServerAllowsVisibleWork: Bool {
        guard let store = danmakuStore, store.oid == currentCid else { return true }
        return !store.isServerClosed
    }

    var danmakuCanDoVisibleWork: Bool {
        Self.danmakuVisibleWorkAdmits(currentPlaybackTerminalState) && danmakuServerAllowsVisibleWork
            && danmakuApplicationActive && UIApplication.shared.applicationState == .active
            && danmakuSink != nil
            && mode.usesOnlineVODServices && currentURL?.isFileURL == false
            && DanmakuFeatureGate.isEnabled()
            && danmakuSessionLedger.liveSession(for: currentCid)?.owner == ownerKey
    }

    var nativeSeekSettledPosition: TimeInterval {
        backend.currentTime
    }

    var danmakuEdgeTime: TimeInterval {
        if let open = danmakuOpenPosition { return open }
        if !isPlaying, let timing = danmakuTiming, timing.speed == 0 {
            return timing.timeOffset
        }
        return mediaTime
    }

    var danmakuTransportTime: TimeInterval {
        DanmakuClockSync.transportEdgeTime(
            openPosition: danmakuOpenPosition,
            liveClock: backend.currentTime,
            sampled: mediaTime
        )
    }

    // MARK: - Playback Settings

    static var animeSkipIntroOutro: Bool {
        get { PlayerPlaybackPreferences.animeSkipIntroOutro }
        set { PlayerPlaybackPreferences.animeSkipIntroOutro = newValue }
    }

    static var cdnFallbackEnabled: Bool {
        get { PlayerPlaybackPreferences.cdnFallbackEnabled }
        set { PlayerPlaybackPreferences.cdnFallbackEnabled = newValue }
    }

    static var resumePlayback: Bool {
        get { PlayerPlaybackPreferences.resumePlayback }
        set { PlayerPlaybackPreferences.resumePlayback = newValue }
    }

    var skipSegments: [(label: String, start: Double, end: Double)] = []
    var skipNotice: String?
    var skipNoticeTask: Task<Void, Never>?
    var lastAutoSkipAt: CFTimeInterval = 0
    var autoSkippedSegmentKeys: Set<String> = []

    // MARK: - SponsorBlock auto-skip

    var sponsorSkippedUUIDs: Set<String> = []
    var lastSponsorSkipAt: CFTimeInterval = 0

    var pendingSponsorManualSegment: SponsorSegment?

    var sponsorMutedUUID: String?

    // MARK: - Presentation start gate

    @ObservationIgnored var hasStartedPresenting = false
    @ObservationIgnored var presentationGates: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored var nextPresentationGateID = 0

    enum RecoveryCoverCapture {
        case stale, unavailable, mounted(UInt64)

        var isStale: Bool {
            if case .stale = self { return true }
            return false
        }

        var identity: UInt64? {
            switch self {
            case .stale, .unavailable: nil
            case .mounted(let identity): identity
            }
        }
    }

    var ambientSystemSurfaceAllowsWork: Bool {
        guard !backend.isPiPActive, !backend.hasObservedPiPLease else { return false }
        if usesDemandPresentationContinuity {
            switch lifecycleRecovery.presentationPhase {
            case .pipStarting, .pipActive, .pipStopping, .restoringInline: return false
            default: break
            }
        }
        return true
    }

    var currentOwnerLease: PlayerOwnerLease? {
        routeOwnership.currentOwnerLease
    }

    // MARK: - VOD

    enum StreamSource: Equatable, Sendable {
        case ugc
        case pgc(epId: Int)
    }

    var currentSource: StreamSource {
        get { session.currentSource }
        set {
            if newValue != session.currentSource { revokeEqualizerMaintenancePermission() }
            session.currentSource = newValue
            retireRecoveryCoverIfAuthorityChanged()
        }
    }

    var loadGeneration: Int {
        get { session.loadGeneration }
        set {
            revokeEqualizerMaintenancePermission()
            session.loadGeneration = newValue
        }
    }
    var lastCDNLogGeneration = -1
    var startupTraceToken: StartupTrace.Token?

    func play() {
        backgroundExecution.allowExplicitRequest()
        nativeAudioRepairAttempt = nil
        beginBackgroundPlaybackRestoration(reason: "user-play", explicit: true)
        if mediaResetRecovery.request != nil {
            recoverMediaServicesAfterUserPlay()
            return
        }
        guard !explicitPlayReloadInFlight, authorizeAudioPlayback() else { return }
        synchronizeTerminalAdmissionFromBackend()
        if playbackTerminalState == .ended {
            playbackIntent = .playing
            restartForLoop()
            return
        }
        if streamRecoveryOwnsWork {
            playbackIntent = .playing
            if resumeStreamRecoveryIfNeeded() { return }
        }
        if mode == .live, liveReconnectTask != nil {
            playbackIntent = .playing
            isBuffering = true
            return
        }
        if mode == .live, liveNeedsReconnectOnResume,
           let roomID = currentRoomID, let ownerLease = currentOwnerLease {
            liveNeedsReconnectOnResume = false
            playbackIntent = .playing
            playbackTerminalState = .active
            terminalOpenFailure = false
            error = nil
            isBuffering = true
            let quality = currentLiveQuality
            PlayerLog.log("[LiveRecovery] resuming paused live reconnect room=\(roomID) qn=\(quality)")
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentOwner(ownerLease) else { return }
                _ = await self.loadLive(
                    roomID: roomID,
                    quality: quality,
                    playInfo: nil,
                    preservePlayState: false,
                    owner: ownerLease.owner,
                    ownerLease: ownerLease
                )
            }
            return
        }
        guard PlayerTransportControlPolicy.allowsPlay(
            afterTerminalOpenFailure: terminalOpenFailure
        ) else {
            backgroundExecution.end(reason: "play-refused")
            PlayerLog.log("[Player] play ignored after terminal open failure — Retry required")
            return
        }
        playbackIntent = .playing
        updateDemandVideoLivenessContext()
        playbackTerminalState = .active
        clearNearEndStall()
        if requestDemandExplicitPlayResumeIfNeeded() {
            return
        }
        if needsReloadBeforeExplicitPlay, mode == .offline, let asset = offlineAsset {
            explicitPlayReloadInFlight = true
            needsReloadBeforeExplicitPlay = false
            let recoverTo = recoveryPosition
            let request = OfflinePlaybackRecoveryPolicy.request(
                for: asset,
                position: recoverTo
            )
            PlayerLog.log(
                "[Lifecycle] explicit-play local reopen at=\(String(format: "%.1f", recoverTo))"
            )
            startOfflinePlayback(
                request.asset,
                at: request.position,
                preservePlayState: false
            )
            explicitPlayReloadInFlight = false
            return
        }
        let hasVODIdentity =
            currentAid != nil && currentCid != nil &&
            currentURL != nil && currentURL?.isFileURL == false
        if ExplicitPlaybackResumePolicy.shouldReloadBeforePlay(
            recoveryPending: needsReloadBeforeExplicitPlay,
            hasVODIdentity: hasVODIdentity
        ), let aid = currentAid, let cid = currentCid {
            explicitPlayReloadInFlight = true
            needsReloadBeforeExplicitPlay = false
            let recoverTo = recoveryPosition
            let reloadOwnerLease = currentOwnerLease
            resumeAtTime = recoverTo > 2 ? recoverTo : nil
            PlayerLog.log(
                "[Lifecycle] explicit-play reload at=\(String(format: "%.1f", recoverTo))"
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.explicitPlayReloadInFlight = false }
                await self.loadVOD(
                    aid: aid,
                    cid: cid,
                    quality: self.currentQuality,
                    source: self.currentSource,
                    preservePlayState: true,
                    ownerLease: reloadOwnerLease
                )
            }
            return
        }
        backend.play()
        updateIsPlaying(transportRunning: true)
        resumePollingTasks()
        pushNowPlayingPlayback()
    }

    private func requestDemandExplicitPlayResumeIfNeeded() -> Bool {
        guard usesDemandPresentationContinuity,
              !lifecycleRecovery.terminalState.isTerminal,
              let fence = makeDemandPresentationFence(
                  epoch: lifecycleRecovery.ensureDemandPresentationEpoch()
              ) else {
            return false
        }
        _ = dispatchDemandPresentation(.explicitPlayRequested(fence: fence))
        return lifecycleRecovery.hasPendingDemandExplicitPlay
    }

    func resumePollingTasks() {
        if speedSampleTask == nil || speedSampleTask!.isCancelled {
            startSpeedSampling()
        }
        if mode.usesPlaybackWatchdog,
           playbackWatchdogTask == nil || playbackWatchdogTask!.isCancelled {
            startPlaybackWatchdog()
        }
        if mode.usesOnlineVODServices,
           historyReportTask == nil || historyReportTask!.isCancelled {
            startHistoryReporting(preservingSession: true)
        }
        if mode == .offline, offlineProgressTask?.isCancelled ?? true {
            startOfflineProgressPersistence()
        }
    }

    func pause() {
        playbackIntent = .pausedByUser
        updateDemandVideoLivenessContext()
        suspendPlayback()
    }

    func suspendPlayback() {
        backgroundExecution.end(reason: "transport-suspended")
        revokeEqualizerMaintenancePermission()
        if usesDemandPresentationContinuity,
           let fence = makeDemandPresentationFence(epoch: lifecycleRecovery.ensureDemandPresentationEpoch()) {
            dispatchDemandPresentation(.transportSuppressed(fence: fence))
        }
        activeSeekToken?.settle(.failed)
        activeSeekToken = nil
        backend.pause()
        pendingSeekTarget = nil
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        reopenSeekTask?.cancel()
        setMute(.seekTravel, false)
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        speedSampleTask?.cancel()
        playbackWatchdogTask?.cancel()
        historyReportTask?.cancel()
        endOfflineProgressPersistence()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    enum SeekSettlement: Equatable {
        case arrived
        case failed
        case handedOff
    }

    @ObservationIgnored
    var lastReportedSurfaceSize: CGSize = .zero
    @ObservationIgnored
    var lastReportedVerticalSizeClass = "nil"

    var hideControlsTask: Task<Void, Never>? {
        get { chrome.hideControlsTask }
        set { chrome.hideControlsTask = newValue }
    }

    var danmakuSettingsHold: Bool {
        get { chrome.danmakuSettingsHold }
        set { chrome.danmakuSettingsHold = newValue }
    }

    func stop(
        reason: PlayerTeardownReason = .ownerExit,
        preservingParkedBackend: Bool = false,
        mediaResetID: UUID? = nil,
        recoveryCoverIdentity: UInt64? = nil,
        cdnSwitchID: UUID? = nil,
        streamRetryID: UUID? = nil,
        preservingLiveReconnect: Bool = false
    ) {
        prepareBackgroundExecutionForStop(reason)
        cancelLiveRecoveryTasks(resetAttempts: !preservingLiveReconnect, clearBackups: true)
        let preservesStreamRecovery = preservesStreamRetryForReload(id: streamRetryID, reason: reason)
        revokeEqualizerMaintenancePermission()
        let preservesRecoveryCover = reason == .internalReload
            && recoveryCoverIdentity != nil
            && recoveryCoverIdentity == recoveryCover?.identity
            && recoveryCover.map(ownsRecoveryCoverAuthority) == true
            && recoveryCoverIdentity.map(isCurrentFreezeFrame) == true
        let preservesCDNCover = preservesCDNSwitchForReload(id: cdnSwitchID, reason: reason)
        if mediaResetID == nil || mediaResetRecovery.request?.id != mediaResetID {
            mediaResetRecovery.invalidate()
        }
        let stoppingOwner = currentOwnerLease
        resetMultiConnectionDisplay()
        loadGeneration += 1
        ambientStoryboardRequest = nil
        ambientStoryboardLoader.retire(keepingArtwork: reason == .internalReload)
        retireAmbientSelection(keepingArtwork: reason == .internalReload)
        migrateStreamRetryLoad(preserving: preservesStreamRecovery)

        advanceGeneration("stop:\(reason)")
        if !reason.preservesPresentation {
            fullscreenTransition = FullscreenTransitionCoalescer()
            if isFullscreen { exitFullscreen() }
        }
        PlayerLog.log(
            "[Player] stop(reason=\(reason)) — tearing down old players " +
            "(TLS noise below is teardown)"
        )
        if reason == .ownerExit {
            StartupTrace.abort("stop-ownerExit", token: startupTraceToken)
        } else {
            StartupTrace.abortIfStreaming(
                "stop-\(String(describing: reason))",
                token: startupTraceToken
            )
        }
        SeekTrace.abort("stop-\(String(describing: reason))")
        reportHistoryNow()
        historyPassIsOpen = false
        historyReportTask?.cancel()
        historyReportTask = nil
        endOfflineProgressPersistence()
        demandContinuationOperationRunner?.cancelCurrent()
        demandPresentationLiveness.invalidate()
        dispatchDemandPresentation(.teardown)
        if !reason.preservesPresentation {
            invalidateLifecycleReadiness()
            lifecycleRecovery.invalidate()
            decoderRecoveryAdmission.invalidate()
            nonLifecycleRecoveryTicket = nil
            nonLifecycleRecoveryTask?.task.cancel()
            nonLifecycleRecoveryTask = nil
            coalescedRecoveryWatchdog = nil
        }
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
        offlineDecoderLabelTask?.cancel()
        offlineDecoderLabelTask = nil
        offlineDecoderLabelRequestID = nil
        speedSampleTask?.cancel()
        speedSampleTask = nil
        byteRateSampler.reset()
        pipelineGoodput = 0
        resetMultiConnectionDisplay()
        FreezeWatchdog.clearPlayer()
        let keepCounters = reason.preservesPresentation
        let lastStartup = stats.lastStartup
        let lastSeek = stats.lastSeek
        stats = PlaybackStats()
        if keepCounters {
            stats.lastStartup = lastStartup
            stats.lastSeek = lastSeek
        }
        pendingBufferHealth = nil
        cachedResolutionSize = .zero
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        pendingSeekTarget = nil
        settledSeekDisplaySample = nil
        activeSeekToken?.settle(.failed)
        activeSeekToken = nil
        reopenSeekTask?.cancel()
        reopenSeekTask = nil
        videoProbeTask?.cancel()
        videoProbeTask = nil
        videoProbeExperimentalAccess = nil
        if reason == .ownerExit {
            durableResumeTarget = nil
        }
        if !preservingParkedBackend {
            backend.stop()
        }
        backend.updateDemandVideoLivenessContext(nil)
        if !preservesCDNCover, !preservesRecoveryCover {
            clearFreezeFrame()
        }
        updateIsPlaying(transportRunning: false)
        isBuffering = false
        clearNearEndStall()
        mediaTime = 0
        bufferedTime = 0
        lastDisplayUpdate = 0
        resumeIsFromHistory = false
        videoHostProbes = [:]
        duration = 0
        currentURL = nil
        currentDASHAudioURL = nil
        multiConnectionVideoURLs = []
        multiConnectionAudioURLs = []
        offlineAsset = nil
        needsReloadBeforeExplicitPlay = false
        isDASHMode = false
        skipSegments = []
        skipNotice = nil
        pendingSponsorManualSegment = nil
        sponsorMutedUUID = nil
        releaseAllMute()
        availableQualities = []
        availableCodecs = []
        availableAudioTiers = []
        playingAudioTier = nil
        availableSubtitles = []
        subtitleSelectionGeneration &+= 1
        activeSubtitleLan = nil
        subtitleCues = []
        subtitleText = nil
        suspendDanmakuSession(reason: reason)
        currentBvid = nil
        onPlaybackEnded = nil
        onPreviousEpisode = nil
        onNextEpisode = nil
        if let stoppingOwner {
            _ = NowPlayingCenter.shared.deactivate(owner: stoppingOwner)
        }
    }

    var watchdogStandDownReason: String? {
        if streamRecoveryOwnsWork { return "standdown/stream-recovery" }
        if !mode.usesPlaybackWatchdog { return "standdown/mode-\(mode)" }
        if !userWantsPlaying { return "standdown/user-paused" }
        if audioSessionInterrupted { return "standdown/audio-interrupted" }
        switch currentPlaybackTerminalState {
        case .active:
            break
        case .ended:
            return "standdown/playback-ended"
        case .terminalFailure:
            return "standdown/terminal-failure"
        case .stopped:
            return "standdown/terminal-stopped"
        }
        if error != nil { return "standdown/error-surfaced" }
        if isSeekInFlight { return "standdown/seek-in-flight" }
        if UIApplication.shared.applicationState != .active { return "standdown/not-foreground" }
        return nil
    }

    var runwayLogText: String {
        guard let ahead = backend.bufferedContentAhead else { return "n/a" }
        return "+\(String(format: "%.1f", max(0, ahead)))s"
    }

    var videoRunwayLogText: String {
        guard let ahead = backend.videoDeliveryRunway else { return "n/a" }
        return "+\(String(format: "%.1f", max(0, ahead)))s"
    }

    // MARK: - Smart CDN & delivery state

    var lastStreamStartAt: TimeInterval = 0

    var speedSampleTask: Task<Void, Never>?
    @ObservationIgnored var byteRateSampler = PlaybackByteRateSampler()
    @ObservationIgnored var pipelineGoodput: Double = 0

    var streamNominalBitrate = 0

    var unhealthySamples = 0
    var lastRunway: TimeInterval = 0

    var videoHostProbes: [String: VideoHostProbe] = [:]
    var videoProbeTask: Task<Void, Never>?
    @ObservationIgnored var videoProbeExperimentalAccess: ExperimentalAccessReceipt?

    @ObservationIgnored
    var lastArmedProbeKey = ""

    // MARK: - Stress diagnostics

    var stressLogTick = 0

    var lastDropSample: (count: Int, at: CFTimeInterval)?
    @ObservationIgnored var lastEnhancementTelemetryRefresh: CFTimeInterval = 0
    var pendingBufferHealth: TimeInterval?
    var cachedResolutionSize: CGSize = .zero

    var lastReportedProgress = -1
    var historyPassIsOpen = false
    var historyStartTs = 0
    var lastReportClock: CFTimeInterval = 0
    var completionMarkerReported = false

    var historyReportMid: String?

    var lastPersistedOfflineSecond = -1
    static let qualityMap: [Int: String] = [
        127: "8K", 126: String(localized: "Dolby Vision"), 125: "HDR",
        120: "4K", 116: "1080P60", 112: "1080P+",
        80: "1080P", 74: "720P60", 64: "720P",
        32: "480P", 16: "360P",
    ]

    static let selectableQualities: [(id: Int, desc: String)] = [
        (127, "8K"),
        (126, String(localized: "Dolby Vision")),
        (125, "HDR"),
        (120, "4K"),
        (116, "1080P60"),
        (112, "1080P+"),
        (80, "1080P"),
        (74, "720P60"),
        (64, "720P"),
        (32, "480P"),
        (16, "360P"),
    ]
    var streamRecoveryOwnsWork: Bool { streamRecovery?.recovering == true }

    var streamRecoveryMayRun: Bool {
        playbackIntent == .playing && !audioSessionInterrupted
            && mediaResetRecovery.request == nil && !invalidatedBackendResources
            && (UIApplication.shared.applicationState == .active
                || PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsBackgroundPlayback)
    }
}
