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

    /// Playback entrances create the process owner on MainActor, once.
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

    /// Lifecycle lookups never construct a player or expose a partial init.
    static var existingShared: PlayerViewModel? {
        guard case .ready(let player) = sharedStorage else { return nil }
        return player
    }

    /// The currently installed engine; all transport reads go through this accessor.
    var backend: PlayerBackend { activeBackend }

    /// The installed engine kind, which may differ from the user's preferred kind.
    var backendKind: PlayerEngineKind { activeBackendKind }

    /// The process-wide user preference; each source resolves its supported engine separately.
    let preferredBackendKind: PlayerEngineKind

    /// Installed by initialization or an admitted engine handoff.
    @ObservationIgnored
    var activeBackend: PlayerBackend
    @ObservationIgnored
    var activeBackendKind: PlayerEngineKind

    /// Create each engine lazily and retain one instance per kind to bound native hosts and observers.
    @ObservationIgnored
    var backendInstances: [PlayerEngineKind: PlayerBackend] = [:]

    /// Write through updateIsPlaying so playback intent and audio interruption vetoes are applied.
    var isPlaying = false {
        willSet { if !newValue { revokeEqualizerMaintenancePermission() } }
    }

    /// Media-clock truth from admitted backend samples and explicit positioning/end policy; never wall-clock
    /// display progress.
    var mediaTime: TimeInterval = 0

    /// Latest backend buffer position. Observable publication is independently throttled by
    /// publishBufferedTime.
    @ObservationIgnored
    var bufferedTimeStorage: TimeInterval = 0
    @ObservationIgnored
    var bufferedTimeProjection = BufferedTimeUIProjection()
    @ObservationIgnored
    var bufferedDisplayDiagnostic: BufferedDisplayDiagnosticSample?
    var bufferedTime: TimeInterval {
        get {
            access(keyPath: \.bufferedTime)
            return bufferedTimeStorage
        }
        set {
            let value = Self.normalizedBufferedTime(newValue)
            // Stop resets to an unmeasured endpoint. Natural completion supplies the final endpoint.
            resetBufferedTime(raw: value, displayedEnd: value > 0 ? value : nil)
        }
    }

    var canPublishBufferedDisplay: Bool { !terminalOpenFailure && error == nil }

    /// Last admitted display range, sharing the bufferedTime observation key.
    var displayedBufferedRange: BufferedDisplayRange? {
        access(keyPath: \.bufferedTime)
        return canPublishBufferedDisplay ? bufferedTimeProjection.publishedRange : nil
    }

    var displayedBufferedTime: TimeInterval? { displayedBufferedRange?.end }
    var duration: TimeInterval = 0
    var isBuffering = false
    /// Set when the surfaced `error` is a settled refusal rather than a failure.
    var unavailability: PlaybackUnavailability?
    var playbackRate: Float = 1.0
    var currentQuality: Int = 116 {
        willSet { if newValue != currentQuality { revokeEqualizerMaintenancePermission() } }
    }
    var isFullscreen = false

    /// The pending transition outlives individual view mounts and is settled by this model.
    @ObservationIgnored
    var fullscreenTransition = FullscreenTransitionCoalescer()

    /// Weak registration of the exact active screen coordinator. UIKit owns its lifetime.
    @ObservationIgnored
    weak var fullscreenPresentation: (any PlayerFullscreenPresentation)?

    /// Identity of the current presentation registration, independent of the media session.
    @ObservationIgnored
    var fullscreenPresentationReceipt: PlayerPresentationReceipt?
    /// Seeded from the view API's `dimension` field, then corrected from the decoder's actual frame size on
    /// readyToPlay or the first later valid geometry (which also catches vertical live rooms whose ready event
    /// has zero dimensions).
    var isPortraitContent = false

    /// Nil means there is no hint: live and offline keep the coded frame.
    var danmakuPortraitHint: Bool? {
        guard mode == .vod else { return nil }
        return portraitPropagation.apiHint
    }
    /// Vertical content collapses to a 16:9 window once the detail page scrolls away from the top (set by the
    /// detail view's scroll tracking); once collapsed, only the portrait-window button can restore the expanded
    /// 3:4 window.
    var inlineCondensed = false
    /// True after the user explicitly chooses either portrait window size.
    /// Automatic scrolling never overrides that choice.
    var portraitCondenseLocked = false
    var showControls = true
    var showStats = false
    /// App-owned decoration around eligible VOD video. The setting is model
    /// state rather than a view-local `@AppStorage` mirror so inline and the
    /// fullscreen host observe one value and a toggle never reopens media.
    var ambientModeEnabled = ExperimentalSettingsPolicy.isAllowed(.ambient)
    var videoSuperResolutionMode: VideoSuperResolutionMode = ExperimentalSettingsPolicy.videoEnhancementEnabled
        ? VideoEnhancementPreferences.defaultSRMode
        : .off
    var videoFrameInterpolationEnabled = ExperimentalSettingsPolicy.videoEnhancementEnabled
        ? VideoEnhancementPreferences.defaultFrameInterpolationEnabled
        : false
    var videoInterpolationRate = ExperimentalSettingsStore.shared.videoEnhancementDefaultRate
    var videoSuperResolutionScale = ExperimentalSettingsStore.shared.videoEnhancementDefaultScale
    var equalizerConfiguration = PlayerEqualizerPreferences.equalizerConfiguration
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
    /// It is intentionally not a renderer snapshot: it is the bounded fallback for the optional time-indexed
    /// preview source, and a new owner clears it until its own metadata arrives.
    var ambientCoverURL: String?
    @ObservationIgnored
    var ambientOwnerLease: PlayerOwnerLease?
    /// Bounded metadata artwork admitted for the current owner/load. The
    /// array is the retained source of truth shared by inline and fullscreen.
    var ambientStoryboard: [PlayerAmbientStoryboardFrame] = []
    @ObservationIgnored
    var ambientStoryboardOwnerLease: PlayerOwnerLease?
    @ObservationIgnored
    var ambientStoryboardLoadGeneration: Int?
    @ObservationIgnored var ambientStoryboardContent: PlayerAmbientStoryboardLoader.Content?
    /// Last truthful position accepted outside a seek. The selection receipt
    /// below additionally freezes the exact artwork while metadata arrives
    /// during travel; neither value advances from a seek-target estimate.
    @ObservationIgnored
    var ambientSelectionMediaTime: TimeInterval?
    @ObservationIgnored var ambientSelectionContent: PlayerAmbientStoryboardLoader.Content?
    var ambientSelectionSource: PlayerAmbientSource?
    /// Owner lease whose current media load has reached playback readiness, gating default Ambient loading.
    var ambientVideoLoadedOwner: PlayerOwnerLease?
    var ambientLiveImage: UIImage?
    var ambientLiveFrameSerial: UInt64 = 0
    @ObservationIgnored
    var lastAmbientLiveSampleWall: TimeInterval = 0
    let ambientStoryboardLoader = PlayerAmbientStoryboardLoader()
    @ObservationIgnored var ambientStoryboardRequest: PlayerAmbientStoryboardLoader.Request?

    /// One derived decorative source for both inline Hero and fullscreen
    /// Backdrop. Preview artwork is selected only from truthful media time;
    /// cover remains the fallback for uncovered, malformed, or absent ranges.
    var ambientSource: PlayerAmbientSource? {
        guard let request = ambientStoryboardRequest,
              ambientSelectionContent == request.content,
              admitsAmbientStoryboardContent(request),
              ExperimentalSettingsPolicy.isAllowed(.ambient) else { return nil }
        return ambientSelectionSource
    }

    var mode: PlayerMode = .vod {
        willSet { if newValue != mode { revokeEqualizerMaintenancePermission() } }
        didSet {
            retireRecoveryCoverIfAuthorityChanged()
            // Leaving VOD must drop bullets even when the clock is paused.
            guard mode != oldValue, mode != .vod else { return }
            releaseDanmaku()
        }
    }
    var error: String? {
        willSet {
            if newValue != nil {
                backgroundExecution.end(reason: "playback-error")
                revokeEqualizerMaintenancePermission()
            }
        }
        didSet {
            if error != nil { retireCDNFrameCover() }
            if error != nil, let recoveryCover {
                clearRecoveryCover(matching: recoveryCover.identity)
            }
        }
    }
    /// Set only for a failed open/admission that requires Retry or a fresh
    /// load. This prevents double-tap/play from reviving an empty Demand
    /// session after a pre-demux candidate failure.
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
    var availableQualities: [(id: Int, desc: String)] = []
    /// Codecs the current DASH manifest actually offers at the playing
    /// quality — drives the codec menu (unavailable ones are disabled).
    var availableCodecs: [VideoCodecPreference] = []
    /// Audio tiers the current DASH manifest offers that the running engine
    /// decodes, highest first — drives the in-player Audio Quality menu.
    var availableAudioTiers: [AudioQualityTier] = []
    /// The tier actually playing (the menu's checkmark). `nil` for an audio
    /// stream whose id is not a known tier, and for non-DASH playback.
    var playingAudioTier: AudioQualityTier?
    /// Cleared when a different aid/cid loads; never persisted — Settings owns the persistent preference.
    @ObservationIgnored
    var audioTierOverride: AudioQualityTier?
    var currentURL: URL? {
        willSet { if newValue != currentURL { revokeEqualizerMaintenancePermission() } }
    }
    var currentDASHAudioURL: URL? {
        willSet { if newValue != currentDASHAudioURL { revokeEqualizerMaintenancePermission() } }
    }
    @ObservationIgnored var multiConnectionVideoURLs: [String] = []
    @ObservationIgnored var multiConnectionAudioURLs: [String] = []
    @ObservationIgnored var multiConnectionQuietWindows = MultiConnectionQuietWindows()
    @ObservationIgnored var multiConnectionWasEnabled = false
    /// Network class the current prefetcher was opened under (design §7.5).
    @ObservationIgnored var multiConnectionLoadClass: MultiConnectionNetworkClass?
    @ObservationIgnored private var multiConnectionSweepObserver: CDNMeasurementObservation?
    // The render view is shared. When two PlayerViews coexist, only the
    // one matching ownerKey may host the render view.
    var ownerKey = "" {
        willSet {
            if newValue != ownerKey {
                backgroundExecution.end(reason: "owner-change")
                revokeEqualizerMaintenancePermission()
            }
        }
    }
    var ownerLeaseGeneration: UInt64 = 0 {
        willSet {
            backgroundExecution.end(reason: "owner-lease-change")
            revokeEqualizerMaintenancePermission()
        }
    }
    /// Set when a different owner claims the shared player before its load.
    /// The load then uses the explicit new-content teardown reason even if
    /// the replacement happens to use the same media identity.
    @ObservationIgnored
    var presentationResetPendingForOwnerChange = false
    /// Only the lease below may own the physical render attachment.
    var surfaceAuthority = PlayerSurfaceAuthority()
    var activeSurfaceLease: PlayerSurfaceLease?
    /// Owner exit was deferred only because an event-backed PiP lease was
    /// visible. Its native lease end must finish teardown even though the
    /// originating screen no longer exists to send another exit callback.
    var deferredPiPOwnerExit = DeferredPiPOwnerExit()
    /// API-normalized VOD hint or nil for live/unknown VOD sources. This
    /// state is reset per session without recreating the renderer/session.
    @ObservationIgnored
    var portraitPropagation = PlayerPortraitPropagationState(
        mode: .vod,
        apiHint: nil,
        initialIsPortrait: false
    )
    // Bumped on every player reload so PlayerRenderView re-attaches (in-place
    // decoder reloads, CDN fallback to the same path).
    var playerGeneration = 0
    /// The currently visible render container. Settings can replace VLC's
    /// immutable PiP drawable host immediately instead of waiting for a later
    /// SwiftUI observation pass that may lose a race with app backgrounding.
    @ObservationIgnored
    weak var renderAttachment: (any PlayerRenderAttachment)?
    @ObservationIgnored
    var renderAttachmentSurfaceLease: PlayerSurfaceLease?
    /// Only the exact source/window may reuse this target. A returning inline
    /// layout publishes changes so the fullscreen host can consume fresh geometry.
    var inlineReturnTarget: PlayerInlineReturnTarget?

    var currentAid: Int? {
        willSet {
            if newValue != currentAid {
                backgroundExecution.end(reason: "content-change")
                revokeEqualizerMaintenancePermission()
            }
        }
        didSet { retireRecoveryCoverIfAuthorityChanged() }
    }
    var currentCid: Int? {
        willSet {
            if newValue != currentCid {
                backgroundExecution.end(reason: "part-change")
                revokeEqualizerMaintenancePermission()
            }
        }
        didSet {
            retireRecoveryCoverIfAuthorityChanged()
            // A nil part has nothing to render. Same rule as the clock guard,
            // but it cannot wait for a tick that pause will not deliver.
            guard currentCid != oldValue, currentCid == nil else { return }
            releaseDanmaku()
        }
    }

    /// Bilibili's `bvid` for the loaded VOD. Not derived from `currentAid`.
    /// Nil for offline, live, and any load that did not carry a bvid string.
    var currentBvid: String?
    var offlineAsset: OfflinePlaybackAsset? {
        willSet { if newValue != offlineAsset { revokeEqualizerMaintenancePermission() } }
    }
    @ObservationIgnored
    var offlineDecoderLabelTask: Task<Void, Never>?
    @ObservationIgnored
    var offlineDecoderLabelRequestID: UUID?
    // Retained so Retry can restart a failed live stream too.
    var currentRoomID: Int? {
        willSet { if newValue != currentRoomID { revokeEqualizerMaintenancePermission() } }
    }
    var currentLiveQuality = LiveAPI.defaultLiveQuality {
        willSet { if newValue != currentLiveQuality { revokeEqualizerMaintenancePermission() } }
    }
    var historyReportTask: Task<Void, Never>?
    /// Its own task rather than a second mode inside that one: `startHistoryReporting` owns the heartbeat's
    /// `start_ts`/`realtime` bookkeeping, which is an online-only concept, and folding a local write into it
    /// would make both harder to read than either.
    var offlineProgressTask: Task<Void, Never>?
    // Mid-play stall watchdog: streams can die AFTER a healthy start
    // (bitrate drops to 0, VLC spontaneously pauses once its buffer
    // drains). Detect a frozen clock and recover.
    var playbackWatchdogTask: Task<Void, Never>?
    var lastWatchdogTime: TimeInterval = -1
    /// The fault currently in effect, and how many consecutive health ticks have
    /// confirmed it. One fault at a time — see `PlaybackHealth.swift`.
    var currentFault: PlaybackFault?
    var faultTicks = 0
    /// Rate-limit state for the evaluator's "no recovery this tick" line: the last reason emitted and how many
    /// consecutive ticks have carried it.
    var healthOutcome: (reason: String, ticks: Int)?
    /// 12 × the 5s watchdog period — one heartbeat a minute per standing reason.
    static let healthOutcomeHeartbeatTicks = 12
    /// Bounds consecutive watchdog `.coalesced` ticks against a stalled boundary-1 ticket (`CB-19`).
    @ObservationIgnored var coalescedRecoveryWatchdog: (token: UInt64, ticks: Int)?
    static let maxCoalescedWatchdogTicks = 3
    /// Every recovery this video is allowed to spend, in one place. Reset in
    /// `claim()` (new content) and by an explicit Retry. See `RecoveryBudget`.
    var budget = RecoveryBudget()
    @ObservationIgnored var streamRecovery: StreamRecoveryCycle?
    @ObservationIgnored var streamSourceRequestAdmission: (@MainActor @Sendable () -> Bool)?

    // Another app owns the audio session (interruption .began — e.g. a music app started playing).
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
    // The system deactivated our session at interruption .began and AVAudioEngine restarts are not guaranteed
    // to re-activate it.
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

    /// Separate video and audio inputs; the selected backend owns their synchronization.
    var isDASHMode = false
    /// The selected video stream is AV1.
    var currentVideoIsAV1 = false
    /// Written on every audio tick and read by nothing. `@ObservationIgnored`
    /// so the assignment does not invalidate every `PlayerViewModel` observer
    /// at the audio rate.
    @ObservationIgnored
    var lastOnPlayAt: CFTimeInterval = 0
    var lastDisplayUpdate: CFTimeInterval = 0
    /// User intent is independent of temporary backend holds and system interruptions.
    enum PlaybackIntent {
        case playing
        /// Never a failure state: a failed open sets `error` + `terminalOpenFailure`, which is what every
        /// automatic path already reads.
        case pausedByUser
        // An interruption paused us while the user wanted playback.
        // Resolved at .ended (resume → .playing, no-resume →
        // .pausedByUser) or when a stale interruption latch clears.
        case pausedBySystem
    }

    var playbackIntent: PlaybackIntent = .playing {
        willSet {
            if newValue != .playing {
                backgroundExecution.end(reason: "intent-paused")
                revokeEqualizerMaintenancePermission()
                suspendStreamRecovery()
            }
        }
    }
    // Compatibility view: "the user has not deliberately paused".
    var userWantsPlaying: Bool { playbackIntent != .pausedByUser }
    // Single predicate for every path that autonomously starts playback or reloads the stream (watchdog kick,
    // bufferFinished enforce- resume, liveness recovery): the user wants playback AND no other app owns the
    // audio session AND the video hasn't naturally ended.
    var canAutoRevive: Bool {
        userWantsPlaying
            && !audioSessionInterrupted
            && !currentPlaybackTerminalState.isTerminal
            && mediaResetRecovery.request == nil
            && !invalidatedBackendResources
    }

    // This is the single place the veto is defined, so it is the only place that can stop the transport it
    // vetoes — teaching each event branch to do it is exactly the hand-copying the derivation exists to end.
    func updateIsPlaying(transportRunning: Bool) {
        let wasPlaying = isPlaying
        isPlaying = transportRunning && userWantsPlaying && !audioSessionInterrupted
        if transportRunning, !isPlaying { backend.pause() }
        if wasPlaying != isPlaying {
            resetMultiConnectionRate()
            publishMultiConnectionDisplay(rate: nil)
            // Paused playback stops media ticks, so the danmaku clock would
            // keep the last play speed. The edge is the only chance to pin it.
            syncDanmakuTransport()
        }
    }
    // This is a typed terminal admission state, not merely a transport symptom: trailing
    // buffer/health/lifecycle events must stand down rather than kick an ended backend with no bytes or
    // runway.
    var playbackTerminalState: PlaybackTerminalState = .active {
        willSet {
            if newValue.isTerminal {
                backgroundExecution.end(reason: "terminal")
                revokeEqualizerMaintenancePermission()
            }
        }
    }

    /// Compatibility projection for the existing near-end display policy and
    /// comments. Admission decisions use `playbackTerminalState` directly.
    var playbackEnded: Bool { playbackTerminalState.isNaturalEnd }

    /// They become terminal admission only once an error is surfaced, so a loader's temporary
    /// `terminalOpenFailure` does not block its own readiness path.
    var currentPlaybackTerminalState: PlaybackTerminalState {
        if playbackTerminalState.isTerminal { return playbackTerminalState }
        if error != nil { return .terminalFailure }
        return .active
    }
    // After a playback failure, URL selection skips the broken preferred host and picks a replacement — smart
    // mode walks the selector's ranking, manual mode latency-races the candidates (pickReachableURL /
    // switchCDN).
    var cdnFallbackActive = false
    /// Guards against concurrent switchCDN calls — three decision points can fire Tasks that enter switchCDN (a
    /// transport `.error`, the liveness ladder's first two rungs, and the proactive delivery-health monitor),
    /// and the await suspension points inside let them interleave.
    var activeCDNSwitch: CDNSwitchTransaction?
    var cdnSwitchInFlight: Bool { activeCDNSwitch != nil }
    var recoveryBudgetIdentity = UUID() {
        willSet { backgroundExecution.end(reason: "recovery-owner-change") }
    }
    var cdnSwitchIntentGeneration: UInt64 = 0
    var cdnFrameCover: CDNFrameCoverPolicy?
    /// Last decoded frame captured just before a CDN switch (in-place or full-reload), shown over the reopening
    /// (black) render view so the swap reads as a brief freeze instead of a black flash.
    var freezeFrame: UIImage?
    var freezeFrameSetAt: CFTimeInterval = 0
    /// A CDN handoff may not release its cover on an audio/clock tick alone; the successor must publish a fresh
    /// presentation proof first.
    var freezeFrameAwaitingFreshProof = false
    /// Actual-ready witness for the native recovery cover. Ordinary CDN
    /// handoffs carry backend/load/current-proof state in cdnFrameCover.
    var freezeFrameExpectedSessionGeneration: UInt64?
    /// Identity of the currently installed CDN/seek cover. Async cleanup must
    /// match this before clearing so a stale task cannot remove a newer cover.
    var freezeFrameIdentity: UInt64 = 0
    var currentFreezeFrameIdentity: UInt64 { freezeFrameIdentity }
    /// Presentation lifetime outlives the admission ticket's ready settlement.
    var recoveryCover: PlayerRecoveryCover?
    static let freezeFrameSafetyTimeout: CFTimeInterval = 8
    /// Media ticks can lift a seek cover earlier, but a hung seek never delivers one.
    @ObservationIgnored
    var transitionCoverExpiry = PlayerTransitionCoverExpiry()
    /// `outgoingRouteStill` is only the latest entry, for the single-value reader.
    var outgoingRouteStills: [String: UIImage] = [:]
    /// Route stills are decorative transition covers, but they must not live
    /// forever when a successor request hangs and no later path mutation
    /// arrives to retire them.
    @ObservationIgnored
    var outgoingRouteStillExpiry = PlayerOutgoingRouteStillExpiry()
    /// Owners popped off the stack whose still the in-flight transition is
    /// still reading. Released at the next path mutation, not in the pop
    /// that recorded them — that turn's body has not read the pixels yet.
    @ObservationIgnored
    var departedRouteStillOwners: [String] = []
    /// Latest parked still. A reader that cannot name an owner sees only
    /// this entry; it is not the store. The successor must not draw it
    /// unless the owner matches.
    var outgoingRouteStill: OutgoingRouteStill?
    /// The most recent position we asked libVLC to reach — a user seek, an auto-skip, or the `:start-time` of a
    /// load/recovery.
    var lastSeekRequest: TimeInterval?

    /// A counter that has never been live is not evidence of a dead decoder: without this, the decoder-health
    /// branch would reload in place forever.
    var fpsEverLive = false

    /// Until it has, a frozen clock is normal priming (Path A demand prime, or resume-at-N buffering), not a
    /// stall — the watchdog feeds this to `classifyPlayback` as `hasStartedPlaying`.
    var clockEverAdvancedThisStream = false
    /// Ceiling on the frozen-clock "priming" veto: a transport that has been running this long without ONE
    /// clock tick is not priming, whatever the byte counters say.
    static let primingCeiling: TimeInterval = 15

    /// Wall time of the last observed byte-counter advance.
    var lastBytesAdvanceAt: TimeInterval = 0
    /// Bytes must advance at least once within this window to count as flowing.
    static let dataFlowWindow: TimeInterval = 3
    /// MEASURED runway (content banked ahead of the play head) at or above which an idle input (net=0 →
    /// !dataFlowing) is "full", not starved.
    static let bufferedRunwayFloor: TimeInterval = 1.5

    /// Set on background; drives lifecycle reopen. Cleared after a recovery
    /// decision. Never trust pre-background `stats.fps` (device: fps=81.5 false OK).
    var decoderSessionSuspect = false

    /// Set after a recovery that ran while the app was still **backgrounded** (black-PiP path: stopPiP +
    /// loadVOD under `app=background`).
    var needsInlineSurfaceRebuild = false

    /// Background playback disabled: foreground must remain paused, but the VideoToolbox/VLC session may no
    /// longer be resumable after containment alone.
    var needsReloadBeforeExplicitPlay = false
    var explicitPlayReloadInFlight = false

    /// Every standing reason the transport is silent.
    var muteAuthority = MuteAuthority()

    /// Backend-owned travel. A held frame or frozen clock during this phase is not a playback fault.
    var isSeekInFlight: Bool { backend.pendingSeekTarget != nil }
    // Seek diagnostics: target of the in-flight seek, and a watchdog that
    // dumps player state if the seek never lands.
    var pendingSeekTarget: TimeInterval?
    var pendingSeekTask: Task<Void, Never>?
    // Stored so a fresh scrub cancels the one it supersedes: each reopen captures a thumbnail before tearing
    // the vout down, and rapid scrubbing would otherwise pile up snapshot work and leave superseded reopens
    // half-run.
    var reopenSeekTask: Task<Void, Never>?
    // Position to restore after a quality-switch reload, applied on
    // readyToPlay instead of a fixed sleep.
    var resumeAtTime: TimeInterval?

    /// The load's own opening position prevents a redundant seek when ready arrives already at the target.
    var lastLoadStartPosition: TimeInterval = 0

    /// Only historical resumes restart near EOF; internal recovery and quality changes preserve the exact
    /// position.
    var resumeIsFromHistory = false
    /// "Playing from beginning" owed to the user once the player is ready — set by loadVOD for the
    /// watched-to-the-end resume sentinel, consumed at readyToPlay (the notice slot survives from there;
    /// anything shown before loadVOD's stop() is wiped instantly).
    var pendingRestartNotice = false

    /// Pending seek and unreached resume intent take precedence over the backend clock during recovery.
    var recoveryPosition: TimeInterval {
        pendingSeekTarget ?? durableResumeTarget ?? resumeAtTime ?? mediaTime
    }

    /// Preserve an unreached user target across reloads and zero clocks until actual arrival or expiry.
    var durableResumeTarget: TimeInterval?
    /// The clock value when the target was armed — arrival is directional
    /// (approached from this side), so stale pre-travel ticks can never clear
    /// it and a throttled tick landing past the target still does.
    var durableResumeArmedFrom: TimeInterval = 0
    /// Wall time of the arm.
    var durableResumeArmedAtWall: CFTimeInterval = 0
    static let durableResumeStaleness: CFTimeInterval = 90

    /// Use the pending seek target or media truth, never near-EOF display extrapolation.
    var resumeTargetTime: TimeInterval {
        pendingSeekTarget ?? mediaTime
    }

    /// Media must stay frozen this long (while playing, in-window) before
    /// wall-clock presentation arms. Eligibility alone is not enough.
    static let nearEndFreezeThreshold: TimeInterval = NearEndClockPolicy.freezeThreshold
    /// Wall-clock anchor when media `timeChanged` freezes near duration while
    /// the transport is still live. Cleared on a real advance, seek, or end.
    var nearEndStallWallStart: CFTimeInterval?
    var nearEndStallMediaStart: TimeInterval?
    /// Presentation-only progress while media is frozen near EOF. Written by
    /// the 4Hz drive task; never copied into mediaTime.
    var nearEndDisplayTime: TimeInterval?
    var nearEndStallDriveTask: Task<Void, Never>?
    /// Delayed arm so we only start wall presentation after a real freeze,
    /// even if `onTickWithGeneration` stops firing same-value samples.
    var nearEndFreezeArmTask: Task<Void, Never>?
    var nearEndFreezeCandidateMedia: TimeInterval?
    /// One log line per stall session; cleared with the anchors.
    var nearEndStallLogged = false

    /// An acknowledged backend position can arrive before the next admitted UI tick, especially while paused.
    struct SettledSeekDisplaySample: Equatable {
        let position: TimeInterval
        let loadGeneration: Int
        let backend: ObjectIdentifier
        let backendGeneration: UInt64
        let owner: String
        let url: URL?
    }
    var settledSeekDisplaySample: SettledSeekDisplaySample?
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

    /// Strip-only reads use the installed backend's existing media clock.
    /// Paused truth and all presentation overrides keep the same priority as
    /// displayTime. Reading this never publishes a tick or advances media time.
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
        // Device soak: force PlayerLog on for this process without sticky Settings
        // (USB Console capture). Prefer env for devicectl (dashed args get eaten).
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
            // The selected engine cannot run in this process (libVLC refused its instance arguments). Demand
            // is the product default and always constructible; say so rather than crash or pretend.
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

        // Completed measurements only — aborts/supersedes stay log-only.
        StartupTrace.onComplete = { [weak self] totalMs in
            // The row label is already "TTFF"; the value carries only the
            // proxy qualifier (first clock tick, not the rendered frame).
            self?.stats.lastStartup = "\(totalMs) ms (proxy)"
        }
        SeekTrace.onComplete = { [weak self] timing in
            // Compact clk/vis/run form so the row stays one line in the inline overlay; an unset clock reads
            // NaN, hence the guard.
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

        // Player extras for the power profile's loops line (rides the
        // Debug Logging toggle, see PowerProfiler).
        PowerProfiler.shared.playerMetrics = { [weak self] in
            guard let self, self.currentURL != nil else { return nil }
            return "fps=\(String(format: "%.1f", self.stats.fps))"
                + " dec=\(self.stats.decoderType)"
                + " net=\(Int(self.stats.networkSpeed / 1024))KB/s"
                + (self.mode == .live ? " live" : "")
        }

        // We own audio-session interruptions (the previous backend's handler was detached in playURL): its
        // .ended(.shouldResume) auto-play fired even when the USER had paused, and even while another app was
        // playing music — re-grabbing NowPlaying from it in a loop.
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

        // Nothing in the player observed this before, so every reading of the transition has had to infer its
        // start.
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
                // Posted from inside the observer so it measures the main
                // queue's turnaround ACROSS the rest of the transition.
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
                // The FOREGROUND counterpart of the background hop, measured the same way: posted from inside
                // the observer so it spans the rest of the transition.
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
                // Foreground is not audio activation or interruption-end authority.
                // Missing-end recovery waits for explicit Play.
            }
        }

        // Foreground activation is the app's automatic PiP-to-inline handoff
        // boundary. The observed lease remains authoritative until the typed
        // userRestore stop request below receives the matching native didStop.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let vm = PlayerViewModel.shared
                vm.reconcileAmbientStoryboard()
                if vm.resumeStreamRecoveryIfNeeded() { return }
                vm.scheduleForegroundLivenessCheck()
            }
        }

        installDanmakuGateObserver()
        installDanmakuMemoryWarningObserver()
    }

    /// Serializes lifecycle recovery.
    var lifecycleRecoveryTask: Task<Void, Never>?
    var lifecycleRecovery = LifecycleRecoveryCoordinator()
    @ObservationIgnored
    lazy var demandContinuationAdapter = DemandContinuationEffectAdapter(sink: self)
    @ObservationIgnored
    var demandContinuationOperationRunner: DemandContinuationOperationRunner?
    /// Stage markers for the in-flight foreground transition. Diagnostic only;
    /// nothing reads it as state.
    @ObservationIgnored
    var demandForegroundStageTape: DemandForegroundStageTape?
    /// Stage markers for the in-flight background transition. Diagnostic only.
    @ObservationIgnored
    var demandBackgroundStageTape: DemandBackgroundStageTape?
    /// Health evidence is scoped independently from transport statistics. A
    /// new lifecycle epoch invalidates pre-background FPS/presentation proof
    /// even when UIKit reuses the same numeric render generation.
    var demandPresentationLiveness = DemandPresentationLivenessAuthority()

    /// Numeric only, on purpose: the tape's whole promise is that it emits no media identity.
    struct DemandStageSessionKey: Equatable {
        let sessionGeneration: UInt64
        let ownerLeaseGeneration: UInt64

        init(_ fence: DemandPresentationFence) {
            sessionGeneration = fence.sessionGeneration
            ownerLeaseGeneration = fence.ownerLeaseGeneration
        }
    }

    /// The residual physical failure is a visible hitch on return, and the only way to attribute it is to know
    /// how much of the work landed after the app was already active.
    struct DemandForegroundStageTape {
        let base: ContinuousClock.Instant
        var stages: [(String, Duration)] = []
        /// The playback session this tape measures, bound by the activation
        /// that opened it. A tape is extended and emitted only for its own
        /// session; a stage belonging to any other one discards it unread.
        var session: DemandStageSessionKey?

        init(base: ContinuousClock.Instant) { self.base = base }

        mutating func mark(_ stage: String) {
            guard stages.count < 12 else { return }
            stages.append((stage, ContinuousClock.now - base))
        }

        /// A transition that already reached activation is finished as far as
        /// this tape is concerned, whether or not it ever produced a proof.
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

    /// Separate instance from the foreground tape on purpose: that one closes only on `proof`/`failed`, which a
    /// background transition never reaches, and `willResignActive` can arrive with no `didEnterBackground` at
    /// all (app switcher).
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
    /// Shared recovery admission for every reopen with an observable completion: runtime faults, lifecycle
    /// reloads, manual retry and an encode drop share one ticket/coalescing boundary; only typed runtime faults
    /// spend the automatic decoder budget.
    var decoderRecoveryAdmission = DecoderRecoveryAdmission()

    /// A lifecycle admission is not complete when its loader returns.
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
    /// Runtime/manual recovery callbacks need the original ticket identity
    /// even when the backend context migrates during quality normalization.
    /// This is typed operation state, not another reload trigger or boolean.
    @ObservationIgnored
    var nonLifecycleRecoveryTicket: DecoderRecoveryAdmission.Ticket?

    // The CDN extension is a separate file of this type and shares this
    // backend-selection gate. Keep the gate module-scoped rather than // so Release builds type-check the cross-file extension consistently.
    var usesDemandPresentationContinuity: Bool {
        activeBackendKind == .demandPaced
    }

    /// True for a Demand PiP handoff from the delegate restore edge (which may
    /// precede app activation) through native `didStop`. The view uses this as
    /// a presentation-only mask; it never changes transport or render ownership.
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
            // The same ceiling a user seek is admitted against.
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

    /// Forward only the existing source/intent/lifecycle gates to Demand.
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
    /// Constructible App-owned bridge for backend-originated state edges. The
    /// weak validator keeps owner/backend/session/PiP fences at the App edge;
    /// the adapter itself only knows the Now Playing item fence.
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
    /// Demand's accepted presentation failure pauses the backend synchronously
    /// and can re-enter `onStateChanged(.paused)`. Suppress that intermediate
    /// system-media write through the same per-VM settlement owner.
    @ObservationIgnored
    let playbackTerminalSettlement = PlaybackTerminalSettlement()
    /// Retained so internal reloads (quality switch, CDN fallback, decoder
    /// recovery) restore the card that backend.stop() blanks; reset
    /// when a different video loads.
    var nowPlayingMeta: (title: String, artist: String, cover: String?)?

    /// System commands are admitted only while the current owner still has a source/item that can act.
    var nowPlayingCommandsAreActionable: Bool {
        currentOwnerLease != nil
            && currentURL != nil
            && !terminalOpenFailure
            && !currentPlaybackTerminalState.isTerminal
    }

    /// Last route signature seen by `networkMonitor`, for danmaku's A1a
    /// path-change reset. nil until the first callback, which only records
    /// the baseline.
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

    /// Observable so the player chip updates; persistence has no live mirror.
    var playbackOrder = PlayerPlaybackPreferences.playbackOrder {
        didSet { PlayerPlaybackPreferences.playbackOrder = playbackOrder }
    }

    /// Sequential (multi-P) playback: the owning screen supplies "play
    /// the next part". Overwritten by each screen's load; only consulted
    /// when playbackOrder == .playNext.
    var onPlaybackEnded: (() -> Void)?

    /// Episode navigation for series content — the anime screen installs
    /// these (nil at the first/last episode); the player controls show
    /// the ⏮/⏭ buttons only while set. Cleared on content change.
    var onPreviousEpisode: (() -> Void)?
    var onNextEpisode: (() -> Void)?

    /// Season id/type of the playing PGC episode — the heartbeat's
    /// sid/sub_type params, which the server wants to move the season
    /// watch state. Set by the anime screen after loadVOD.
    var pgcSeasonContext: (sid: Int, type: Int?)?

    var rateBeforeHold: Float?

    /// Press-and-hold accelerated playback: true while the finger is down.
    var isHoldFastForwarding: Bool { rateBeforeHold != nil }

    /// Press-and-hold 2× is offered: the mode takes a rate at all, and the RUNNING engine applies it fast
    /// enough to be heard during the hold.
    var supportsHoldFastForward: Bool {
        mode.supportsPlaybackRate && backendKind.supportsHoldFastForward
    }

    // MARK: - Video Scale Mode (fullscreen aspect options)

    var scaleMode: VideoScaleMode = .fit {
        didSet { applyScaleMode() }
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

    /// Search helper for the common cue timeline shape. The decoded source array
    /// stays authoritative; malformed, unordered, or overlapping data uses the
    /// original first-match scan.
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
    /// lan of the active subtitle track; nil = off.
    var activeSubtitleLan: String?
    /// The cue under the playhead, rendered by the player overlay.
    var subtitleText: String?
    var subtitleCues: [SubtitleCue] = [] {
        didSet { subtitleCueTimeline = SubtitleCueTimeline(cues: subtitleCues) }
    }
    @ObservationIgnored var subtitleCueTimeline: SubtitleCueTimeline?
    @ObservationIgnored var subtitleSelectionGeneration: UInt64 = 0
    /// Single-fetch handoff for x/player/wbi/v2: `serverResumePoint` already fetches this exact response on the
    /// critical path of every screen- initiated load, so it parks the result here and `loadSubtitleList`
    /// consumes it (key match) instead of hitting the identical endpoint again.
    struct PendingPlayerInfo {
        let aid: Int
        let cid: Int
        let info: PlayerV2Info
        let handoff: PlayerInfoHandoffToken
    }

    var pendingPlayerInfo: PendingPlayerInfo?
    var playerInfoHandoffPolicy = PlayerInfoHandoffPolicy()

    /// Danmaku clock edge.
    @ObservationIgnored var danmakuGateEnabled = false
    /// Owns the defaults token so removal happens in its `deinit`, not in this
    /// `@MainActor` class's `deinit` (that `deinit` is nonisolated).
    @ObservationIgnored var danmakuGateObserver: DanmakuGateObserverToken?
    @ObservationIgnored var danmakuStore: DanmakuSegmentStore?
    @ObservationIgnored var danmakuApplicationActive = UIApplication.shared.applicationState == .active
    @ObservationIgnored var danmakuVisibleWorkSuspended = false
    /// See `settleDanmakuNaturalEndHold`.
    @ObservationIgnored var danmakuHeldAtNaturalEnd = false
    /// The person-mask source `x/player/wbi/v2` reported, keyed by the cid it
    /// was fetched for (Phase C). Kept apart from the store: it arrives on the
    /// player-info path, which does not wait for the danmaku session.
    @ObservationIgnored var danmakuMaskSource: (cid: Int, url: URL)?
    /// Lives and dies with `danmakuStore`'s session; see `advanceDanmakuMask`.
    @ObservationIgnored var danmakuMaskStore: DanmakuMaskStore?
    /// Who may create a store, fetch and admit right now, and whom a store retained across `stop()` belongs to.
    @ObservationIgnored var danmakuSessionLedger = DanmakuSessionLedger()
    /// Fires `DanmakuSessionLedger.retentionTTL` after a suspend and evicts the retained store if no admission
    /// claimed it.
    @ObservationIgnored var danmakuRetentionExpiry: Task<Void, Never>?
    /// Owns the memory-warning token; same shape as `danmakuGateObserver`.
    @ObservationIgnored var danmakuMemoryWarningObserver: DanmakuGateObserverToken?
    /// The next clock edge consumes it: cursor to a lookback behind that edge's position, sink told `seeked` —
    /// the same refill a seek gets, so a re-adopted store never re-admits what was already on screen.
    @ObservationIgnored var danmakuRealignPending = false
    /// Where the admitted stream opens, until its first media tick arrives.
    @ObservationIgnored var danmakuOpenPosition: TimeInterval?
    @ObservationIgnored var danmakuAdmittedUntil: TimeInterval = 0
    /// Special packages have no ordinary request holes. Their cursor advances
    /// independently, and visible identities suppress cross-source duplicates
    /// before either copy can enter the asynchronous raster queue.
    @ObservationIgnored var danmakuSpecialAdmittedUntil: TimeInterval = 0
    struct DanmakuVisibleIdentity {
        let progress: TimeInterval
        let isSelfSent: Bool
    }
    @ObservationIgnored var danmakuAdmittedIDs: [String: DanmakuVisibleIdentity] = [:]
    /// Local echo ids.
    @ObservationIgnored var nextDanmakuEchoID: Int64 = -1
    /// Set when a resize reclaims the live set. The next clock edge rewinds once.
    @ObservationIgnored var danmakuRefillVisibleWindow = false
    @ObservationIgnored var danmakuTiming: DanmakuClockSync.LayerTiming?
    @ObservationIgnored weak var danmakuSink: DanmakuTimelineSink?
    @ObservationIgnored var danmakuSeekRequestSerial: UInt64 = 0
    /// Operation acknowledgements outlive the data store: toggling the overlay
    /// off/on does not make an already consumed native or PiP Seek new again.
    @ObservationIgnored var danmakuSettledSeekRequestSerial: UInt64?
    struct DanmakuPiPSeekSettlement: Equatable {
        let operation: UInt64
        let fence: NowPlayingEdgeFence
    }
    @ObservationIgnored var danmakuLastPiPSeekSettlement: DanmakuPiPSeekSettlement?

    var nativeSeekIsReady: Bool {
        backend.isReadyToPlay
    }

    /// Census maximum mode-7 lifetime. Scroll can run longer (user setting, up
    /// to 16s) and the fixed lifetime is shorter. A refill window has to cover
    /// whichever is on screen, or the tail of a wiped set never comes back.
    static let danmakuMode7LifetimeCeiling: TimeInterval = 10

    /// Open bit for the fullscreen send bar. The host owns the active editor;
    /// VOD parks its text below only across an ordinary fullscreen exit.
    var fullscreenDanmakuComposerPresented = false

    /// Legacy PGC handoffs to its retained inline composer. VOD has no inline
    /// composer and uses the source-bound slot and notice below instead.
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

    /// One ephemeral slot, not history. A new explicit opening consumes the
    /// parked text and replaces its receipt before the editor can change it.
    @ObservationIgnored var fullscreenVODDanmakuDraft: FullscreenDanmakuDraft?
    var fullscreenVODDanmakuSendFailure: FullscreenDanmakuFailure?

    var danmakuServerAllowsVisibleWork: Bool {
        // A retained old cid's closed state cannot suppress a fresh new cid.
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

    /// Position for an edge that is not a media tick. See `danmakuOpenPosition`.
    var danmakuEdgeTime: TimeInterval {
        if let open = danmakuOpenPosition { return open }
        if !isPlaying, let timing = danmakuTiming, timing.speed == 0 {
            return timing.timeOffset
        }
        return mediaTime
    }

    /// `mediaTime` is the 4Hz-throttled sample, up to a quarter second (times the rate) behind the picture;
    /// pinning a pause to it snapped every bullet back by that much.
    var danmakuTransportTime: TimeInterval {
        DanmakuClockSync.transportEdgeTime(
            openPosition: danmakuOpenPosition,
            liveClock: backend.currentTime,
            sampled: mediaTime
        )
    }

    // MARK: - Playback Settings

    /// Compatibility for untouched Bangumi and CDN extension consumers.
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

    /// OP/ED ranges (seconds) of the playing content, set by the anime
    /// screen after loading an episode; cleared on stop(). Consulted every
    /// clock tick while animeSkipIntroOutro is on.
    var skipSegments: [(label: String, start: Double, end: Double)] = []
    /// Transient "Skipped intro" notice for the player overlay.
    var skipNotice: String?
    var skipNoticeTask: Task<Void, Never>?
    var lastAutoSkipAt: CFTimeInterval = 0
    /// Without it a manual back-scrub into an intro re-triggers the skip after the throttle — the user
    /// navigated there on purpose.
    var autoSkippedSegmentKeys: Set<String> = []

    // MARK: - SponsorBlock auto-skip

    /// UUIDs auto-skipped this load — prevents a re-skip loop when the seek
    /// lands a hair before the segment end, and stops a manual back-scrub
    /// into a skipped range from bouncing forward again. Reset per load.
    var sponsorSkippedUUIDs: Set<String> = []
    var lastSponsorSkipAt: CFTimeInterval = 0

    /// The `.manual` SponsorBlock segment under the playhead, if any —
    /// drives the on-screen "Skip …" button. Read by PlayerView.
    var pendingSponsorManualSegment: SponsorSegment?

    /// UUID of the `.mute` segment the audio is currently silenced for (nil = not muted by SponsorBlock).
    var sponsorMutedUUID: String?

    // MARK: - Presentation start gate

    /// Has THIS stream actually begun presenting? Set on the first clock tick,
    /// which is the one presentation edge both engines publish (the measured
    /// first picture is libVLC-only and needs Diagnostic Logging).
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
        guard !ownerKey.isEmpty else { return nil }
        return PlayerOwnerLease(owner: ownerKey, generation: ownerLeaseGeneration)
    }

    // MARK: - VOD

    /// Where the stream URLs come from — bangumi episodes use the PGC
    /// endpoint; the UGC one rejects or previews them.
    enum StreamSource: Equatable, Sendable {
        case ugc
        case pgc(epId: Int)
    }

    var currentSource: StreamSource = .ugc {
        willSet { if newValue != currentSource { revokeEqualizerMaintenancePermission() } }
        didSet { retireRecoveryCoverIfAuthorityChanged() }
    }

    var loadGeneration = 0 {
        willSet { revokeEqualizerMaintenancePermission() }
    }
    var lastCDNLogGeneration = -1
    /// Token for the current screen-initiated startup request. Backend clock
    /// callbacks additionally carry their runtime generation, so an old
    /// backend event cannot use this mutable property to complete a successor.
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
            // It still goes through the normal canonical-origin load below, never a recovery ticket or
            // `backend.play()` on a stopped Demand session.
            playbackIntent = .playing
            restartForLoop()
            return
        }
        if streamRecoveryOwnsWork {
            playbackIntent = .playing
            if resumeStreamRecoveryIfNeeded() { return }
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
            // A paused PiP-stop lane must complete its local prepare/resume transaction before the transport
            // is allowed to play.
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

    /// Route an explicit Play through the presentation coordinator when a paused PiP-stop suspension still owns
    /// the Demand video lane.
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
            startHistoryReporting()
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
        backend.pause()
        // Demand cancellation intentionally does not invoke superseded seek
        // completions. Settle the VM-owned pin/mute here so a paused player
        // cannot remain muted while waiting for a tick that will never arrive.
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
        // A pause is where an offline position becomes final for a while: the clock stops moving, and a
        // process death from here on has nothing else to write.
        endOfflineProgressPersistence()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// How one `seek(to:)` transaction ended. Three cases because the transport
    /// has three answers, and collapsing the third into either of the others is
    /// what left a recovery fence open on the shipping engine.
    enum SeekSettlement: Equatable {
        /// The transport reached the target.
        case arrived
        /// The target is unreachable and nothing further is in flight.
        case failed
        /// This transaction is no longer the one that owns reaching a position: a successor open has been
        /// submitted (the VLC reopen path), the seek was deferred to the next readiness, or a newer seek / a
        /// new owner took the transport.
        case handedOff
    }

    /// The surface geometry the mounted `PlayerView` last measured, kept only so the model-owned settlement
    /// above can carry the same two diagnostics fields the view-owned one did (`size=`, `vSize=`).
    @ObservationIgnored
    var lastReportedSurfaceSize: CGSize = .zero
    @ObservationIgnored
    var lastReportedVerticalSizeClass = "nil"

    /// Model-owned for the same reason the settlement is: it was a `Task` in `PlayerView`'s `@State`, cancelled
    /// by that view's `onDisappear`, and a host move ends one instance and starts another in the middle of a
    /// transition.
    @ObservationIgnored
    var hideControlsTask: Task<Void, Never>?

    /// Landscape danmaku settings are open. The 5s chrome hide must not run:
    /// the only dismiss control lives in that chrome, and a hide leaves the
    /// card up with no way to close it.
    var danmakuSettingsHold = false

    /// Callers that replace the same owner/content must pass `.internalReload`; the default remains the safe
    /// owner-exit behavior for future teardown paths.
    func stop(
        reason: PlayerTeardownReason = .ownerExit,
        preservingParkedBackend: Bool = false,
        mediaResetID: UUID? = nil,
        recoveryCoverIdentity: UInt64? = nil,
        cdnSwitchID: UUID? = nil,
        streamRetryID: UUID? = nil
    ) {
        prepareBackgroundExecutionForStop(reason)
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
        // Invalidate everything still in flight.
        resetMultiConnectionDisplay()
        loadGeneration += 1
        ambientStoryboardRequest = nil
        ambientStoryboardLoader.retire(keepingArtwork: reason == .internalReload)
        retireAmbientSelection(keepingArtwork: reason == .internalReload)
        migrateStreamRetryLoad(preserving: preservesStreamRecovery)

        advanceGeneration("stop:\(reason)")
        if !reason.preservesPresentation {
            // `.internalReload` is excluded for the same reason it is excluded below: a quality switch or CDN
            // reopen keeps the presentation, so a transition in flight across it keeps its subject and must
            // settle normally.
            fullscreenTransition = FullscreenTransitionCoalescer()
            if isFullscreen { exitFullscreen() }
        }
        // TLS errors between this line and the next playURL are that noise, NOT a failure of the new stream.
        PlayerLog.log(
            "[Player] stop(reason=\(reason)) — tearing down old players " +
            "(TLS noise below is teardown)"
        )
        // An owner exit ends any open session, streamed or not — a user who pops mid-load must not leave a
        // session for the next unrelated playback's marks to land in.
        if reason == .ownerExit {
            StartupTrace.abort("stop-ownerExit", token: startupTraceToken)
        } else {
            StartupTrace.abortIfStreaming(
                "stop-\(String(describing: reason))",
                token: startupTraceToken
            )
        }
        // There is no equivalent of the streamed-only rule: a seek's own reopen goes through `playURL`, whose
        // teardown is `backend.stop()`, not this method — so a stop reaching here ends the seek.
        SeekTrace.abort("stop-\(String(describing: reason))")
        reportHistoryNow()
        // That flush is this pass's last raw write.
        historyPassIsOpen = false
        historyReportTask?.cancel()
        historyReportTask = nil
        // Mode is still the outgoing one too — a load's preparatory stop runs before `mode` is reassigned — so
        // a page change writes the part being left, not the one being opened.
        endOfflineProgressPersistence()
        demandContinuationOperationRunner?.cancelCurrent()
        demandPresentationLiveness.invalidate()
        dispatchDemandPresentation(.teardown)
        // Internal same-owner reloads are the successor context of an active
        // recovery ticket. Owner exit/new-content teardown invalidates it; a
        // preserved presentation must let `backend.load` migrate it.
        if !reason.preservesPresentation {
            invalidateLifecycleReadiness()
            lifecycleRecovery.invalidate()
            decoderRecoveryAdmission.invalidate()
            nonLifecycleRecoveryTicket = nil
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
        // The trace counters survive an INTERNAL reload only: a quality/codec switch or recovery reopen never
        // begins a StartupTrace session, so a blanket wipe would erase the one cold-start number the switch is
        // being compared against.
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
        reopenSeekTask?.cancel()
        reopenSeekTask = nil
        videoProbeTask?.cancel()
        videoProbeTask = nil
        videoProbeExperimentalAccess = nil
        // The durable resume intent belongs to the CONTENT the user was in.
        if reason == .ownerExit {
            durableResumeTarget = nil
        }
        if !preservingParkedBackend {
            backend.stop()
        }
        backend.updateDemandVideoLivenessContext(nil)
        // Only that exact transaction's admitted internal reload preserves its cover; an unrelated
        // quality/episode/owner teardown must retire it.
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
        // currentOptions removed (VLC config is per-media)
        isDASHMode = false
        skipSegments = []
        skipNotice = nil
        pendingSponsorManualSegment = nil
        // Both halves, together.
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
        // Pause produces no further media ticks, so the clock guard cannot be the thing that ends the session
        // on an owner exit or an internal reload.
        suspendDanmakuSession(reason: reason)
        currentBvid = nil
        onPlaybackEnded = nil
        onPreviousEpisode = nil
        onNextEpisode = nil
        if let stoppingOwner {
            _ = NowPlayingCenter.shared.deactivate(owner: stoppingOwner)
        }
    }

    /// Which of the evaluator's stand-down conditions is in force, or `nil` when none is and the classifier
    /// owns the verdict.
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

    /// Never `bufferedTime - t`.
    var runwayLogText: String {
        guard let ahead = backend.bufferedContentAhead else { return "n/a" }
        return "+\(String(format: "%.1f", max(0, ahead)))s"
    }

    /// The VIDEO runway, printed beside `buf=` so a capture can never again show a healthy-looking runway over
    /// a frozen picture.
    var videoRunwayLogText: String {
        guard let ahead = backend.videoDeliveryRunway else { return "n/a" }
        return "+\(String(format: "%.1f", max(0, ahead)))s"
    }

    // MARK: - Smart CDN & delivery state
    //
    // The logic over this state lives in PlayerViewModel+CDN.swift (host
    // selection, in-place switch) and PlayerViewModel+DeliveryHealth.swift
    // (network sampling, delivery health, per-video probes). Swift forbids
    // stored properties in extensions and scopes `private` to a file, so it is
    // declared here and internal.

    /// Set on every playURL; the health monitor and the liveness evaluator both
    /// measure elapsed-since-start from it, because a stream filling its first
    /// buffer looks exactly like one that has stopped delivering.
    var lastStreamStartAt: TimeInterval = 0

    var speedSampleTask: Task<Void, Never>?
    /// Previous 1Hz byte reading (wire + pipeline). Bookkeeping only — no view
    /// reads it, so it must not invalidate observers once a second.
    @ObservationIgnored var byteRateSampler = PlaybackByteRateSampler()
    /// Last measured pipeline GOODPUT (bytes/s) — the delivery-health input, printed as `gp=` next to the
    /// displayed `net=` in health log lines.
    @ObservationIgnored var pipelineGoodput: Double = 0

    /// `updateDynamicStats` has never written bitrate; both fields are set once per load from the same playurl
    /// response, which is why the monitor's `stats.bitrate` fallback was unreachable and is gone.
    var streamNominalBitrate = 0

    /// Consecutive 1Hz samples where the current edge couldn't sustain
    /// playback (goodput below demand while the runway shrinks).
    var unhealthySamples = 0
    /// Never an availability horizon: a runway nobody measured stands the monitor down instead of being
    /// reconstructed here.
    var lastRunway: TimeInterval = 0

    /// Verdicts for the CURRENT video across candidate hosts.
    var videoHostProbes: [String: VideoHostProbe] = [:]
    var videoProbeTask: Task<Void, Never>?
    @ObservationIgnored var videoProbeExperimentalAccess: ExperimentalAccessReceipt?

    /// Internal, not private: `private` is file-scoped and the only reader is `probeVideoAcrossHosts` in
    /// PlayerViewModel+DeliveryHealth.swift.
    @ObservationIgnored
    var lastArmedProbeKey = ""

    // MARK: - Stress diagnostics

    var stressLogTick = 0

    var lastDropSample: (count: Int, at: CFTimeInterval)?
    /// Latest `onBufferChanged` sample, or nil when this backend has published
    /// none — see `PlaybackStats.bufferHealth` for why nil is not 0.
    var pendingBufferHealth: TimeInterval?
    var cachedResolutionSize: CGSize = .zero

    var lastReportedProgress = -1
    /// A raw progress write belongs to an open pass: opened by
    /// `startHistoryReporting`, closed by `stop()`'s flush. See `stop()`.
    var historyPassIsOpen = false
    /// start_ts the heartbeat wants: wall-clock second this stream began.
    var historyStartTs = 0
    /// For the heartbeat's realtime (seconds actually elapsed since the
    /// previous report).
    var lastReportClock: CFTimeInterval = 0
    /// The periodic reporter and `stop()`'s flush both write a RAW second, and at natural EOF that second is ≈
    /// duration — written AFTER the marker it hands the server back exactly the record the marker exists to
    /// replace, and the next open resumes into the final seconds again.
    var completionMarkerReported = false

    /// `dedeUserID` captured when this pass's heartbeat task was created.
    /// Compared again before each POST so a mid-playback account switch cannot
    /// file this video's progress on the new account.
    var historyReportMid: String?

    /// Last second written to the offline row.
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
