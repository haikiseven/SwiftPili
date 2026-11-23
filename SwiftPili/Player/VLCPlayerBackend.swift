import AVFoundation
import Observation
import QuartzCore
import SwiftVLC
import UIKit

private extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum VLCError: LocalizedError {
    case mediaCreationFailed(source: String)
    case playbackFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .mediaCreationFailed(let source): "Failed to create media: \(source)"
        case .playbackFailed(let reason): "Playback failed: \(reason)"
        }
    }
}

func vlcAvailabilityHorizon(
    inputIsLocalFile: Bool,
    mediaDuration: TimeInterval,
    lastObservedPosition: TimeInterval
) -> TimeInterval {
    guard mediaDuration > 0 else { return lastObservedPosition }
    guard !inputIsLocalFile else { return mediaDuration }
    return min(lastObservedPosition, mediaDuration)
}

@MainActor @Observable
private final class VLCEqualizerState {
    var desired = PlayerEqualizerConfiguration.defaults
    var submissionFailure: String?
}

@MainActor
final class VLCPlayerBackend: PlayerBackend {

    private nonisolated static var vlcSelection: VLCEngineHost.Selection? { VLCEngineHost.selection }

    static var isEngineAvailable: Bool { vlcSelection != nil }

    nonisolated static func prewarmPlaybackEngine() { VLCEngineHost.prewarm() }

    private let player: Player
    private let vlcInstance: VLCInstance
    private let instancePitchEngine: Bool?
    private let supportsEqualizer: Bool
    private let equalizerState = VLCEqualizerState()

    var equalizerConfiguration: PlayerEqualizerConfiguration {
        get { equalizerState.desired }
        set {
            equalizerState.desired = newValue.normalized
            applyDesiredEqualizer()
        }
    }

    var equalizerStatus: PlayerEqualizerStatus {
        if let failure = equalizerState.submissionFailure { return .failed(failure) }
        guard supportsEqualizer else {
            return .unsupported("The active VLC instance has no reviewed EQ contract")
        }
        switch player.equalizerApplication {
        case .accepted(let receipt):
            guard receipt.snapshot == desiredNativeEqualizer else { return .pendingNativeAccess }
            return receipt.mode == .bypassed ? .bypassed : .configuredCurrentGraph
        case .failed(_, let error, _): return .failed(error.localizedDescription)
        case .legacyUnverified: return .unsupported("Unchecked VLC equalizer attachment")
        case .neverSubmitted, .retired: return .retainedNoGraph
        }
    }

    private var desiredNativeEqualizer: EqualizerSnapshot? {
        guard !equalizerState.desired.isBypassed else { return nil }
        return try? EqualizerSnapshot(
            preamp: equalizerState.desired.effectivePreamp + PlayerEqualizerArtifact.nativePreampCompensation,
            bands: equalizerState.desired.bandGains
        )
    }

    private func applyDesiredEqualizer() {
        equalizerState.submissionFailure = nil
        guard supportsEqualizer else { return }
        do {
            let snapshot: EqualizerSnapshot?
            if equalizerState.desired.isBypassed {
                snapshot = nil
            } else {
                snapshot = try EqualizerSnapshot(
                    preamp: equalizerState.desired.effectivePreamp + PlayerEqualizerArtifact.nativePreampCompensation,
                    bands: equalizerState.desired.bandGains
                )
            }
            _ = try player.applyEqualizer(snapshot)
        } catch {
            equalizerState.submissionFailure = error.localizedDescription
            PlayerLog.log("[VLC] EQ native settings request failed")
        }
    }
    private var videoHosting: PiPVideoViewController
    private var automaticPiPEnabled: Bool
    private var continuationHostRevision: UInt64 = 1
    private var eventTask: Task<Void, Never>?
    private var pipEventTask: Task<Void, Never>?
    private var vlcLogTask: Task<Void, Never>?
    private var observedPiPLease = false
    private var observedPiPLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?

    var nextLoadIsSeekReopen = false

    private var seekVisibleBaseline: UInt64?
    private var startupVisibleBaseline: UInt64?
    private var startupVisibleArmedAt: CFTimeInterval = 0

    private let retainedLivenessObservation = VLCRetainedLivenessObservation()

    private var lastDisplayedPictures: UInt64 = 0
    private var lastFPSSampleTime: CFTimeInterval = 0
    private var measuredFPS: Double = 0

    private(set) var runtimeGeneration: UInt64 = 0

    private var startupTraceToken: StartupTrace.Token?

    private(set) var pendingSeekTarget: TimeInterval?
    private var pendingSeekGate: SeekCompletionGate?
    private var seekIssuedAt: CFTimeInterval = 0
    private var seekProgressAt: CFTimeInterval = 0
    private var startPositionChecked = false

    private var activeVoutCount: Int = 0

    private var hasFiredReady = false

    private var lastTickTime: TimeInterval = 0
    private var lastKnownDuration: TimeInterval = 0

    private var seekFromTime: TimeInterval = 0
    private var seekLanded = false

    private var loadStartOffset: TimeInterval = 0

    private var inputIsLocalFile = false

    // MARK: - Events

    var onStateChanged: (@MainActor @Sendable (PlayerStateEvent) -> Void)?
    var onTickWithGeneration: (@MainActor @Sendable (_ currentTime: TimeInterval, _ totalTime: TimeInterval, _ generation: UInt64, _ startupTraceToken: StartupTrace.Token?) -> Void)?
    var onBufferChanged: (@MainActor @Sendable (_ consumeTime: TimeInterval) -> Void)?

    // MARK: - Init

    init?() {
        guard let selection = Self.vlcSelection else { return nil }
        let player = Player(instance: selection.instance)
        self.player = player
        vlcInstance = selection.instance
        instancePitchEngine = selection.pitchEngine
        supportsEqualizer = selection.supportsEqualizer
        let configuration = PlayerPlaybackPreferences.playbackContinuationConfiguration
        let automaticPiP = configuration.allowsAutomaticPiP
        automaticPiPEnabled = automaticPiP
        videoHosting = Self.makeVideoHosting(
            player: player, startsAutomaticallyFromInline: automaticPiP
        )
        observePiPLease(videoHosting.pictureInPictureController)
        PlayerLog.log(
            "[PiP] host created revision=\(continuationHostRevision) " +
            "backgroundAudio=\(configuration.backgroundAudioEnabled ? 1 : 0) " +
            "pictureInPicture=\(configuration.pictureInPictureEnabled ? 1 : 0) " +
            "automatic=\(automaticPiP ? 1 : 0)"
        )

        startVLCLogForwarding()
        ExperimentalSettingsStore.shared.addObserver(owner: self) { owner, changes in
            guard changes.contains(.diagnostics) else { return }
            owner.applyDiagnosticLogPolicy()
        }
    }

    isolated deinit {
        vlcLogTask?.cancel()
        eventTask?.cancel()
        pipEventTask?.cancel()
        pendingSeekTarget = nil
        pendingSeekGate?.settle(false)
        pendingSeekGate = nil
        videoHosting.invalidate()
    }

    func setStartupTraceToken(_ token: StartupTrace.Token?) {
        startupTraceToken = token
    }

    private static func makeVideoHosting(
        player: Player,
        startsAutomaticallyFromInline: Bool
    ) -> PiPVideoViewController {
        let hosting = PiPVideoViewController(
            player,
            startsAutomaticallyFromInline: startsAutomaticallyFromInline,
            managesAudioSession: false
        )
        hosting.loadViewIfNeeded()
        return hosting
    }

    private nonisolated static func isVLCLogNoise(_ message: String) -> Bool {
        message.hasPrefix("in DATA")
            || message.hasPrefix("out DATA")
            || message.hasPrefix("in WINDOW_UPDATE")
            || message.hasPrefix("out WINDOW_UPDATE")
            || message.hasPrefix("Buffering ")
    }

    private nonisolated static func logSignature(_ message: String) -> String {
        var out = ""
        var inDigits = false
        for ch in message {
            if ch.isNumber {
                if !inDigits {
                    out.append("#")
                    inDigits = true
                }
            } else {
                out.append(ch)
                inDigits = false
            }
        }
        return out
    }

    private func logPitchConfiguration() {
        let pitchWanted = ExperimentalSettingsPolicy.diagnosticBool(
            key: "pitch_corrected_rate",
            saved: ExperimentalSettingsPolicy.diagnosticOverrides.audioOutputSpeed
        )
        let instancePitch = instancePitchEngine.map { $0 ? "1" : "0" } ?? "unknown"
        PlayerLog.log(
            "[VLC] load aout=avsamplebuffer instance_pitch=\(instancePitch) "
            + "desired_next_launch=\(pitchWanted ? 1 : 0) (instance arg; toggle needs app relaunch)"
        )
    }

    private func applyDiagnosticLogPolicy() {
        if PlayerLog.isEnabled {
            startVLCLogForwarding()
        } else {
            vlcLogTask?.cancel()
            vlcLogTask = nil
        }
    }

    private func startVLCLogForwarding() {
        guard PlayerLog.isEnabled,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        vlcLogTask?.cancel()
        let instance = vlcInstance
        vlcLogTask = Task.detached(priority: .utility) {
            var runSignature = ""
            var runSuppressed = 0
            var runLastMessage = ""
            for await entry in instance.logStream(minimumLevel: .debug) {
                guard !Task.isCancelled, access.isValid, PlayerLog.isEnabled else { return }
                let message = entry.message
                guard !Self.isVLCLogNoise(message) else { continue }

                let signature = Self.logSignature(message)
                if signature == runSignature {
                    runSuppressed += 1
                    runLastMessage = message
                    continue
                }
                if runSuppressed > 0 {
                    PlayerLog.log("[VLC] … \(runSuppressed)× more of the previous line (last: \(runLastMessage))")
                }
                runSignature = signature
                runSuppressed = 0
                PlayerLog.log("[VLC:\(entry.module ?? "core")] \(entry.level): \(message)")
            }
        }
    }

    static var prefetchFilterExperimentEnabled: Bool {
        get {
            ExperimentalSettingsPolicy.diagnosticBool(
                key: "prefetch_filter_experiment",
                saved: ExperimentalSettingsPolicy.diagnosticOverrides.prefetchFilter
            )
        }
        set {
            var overrides = ExperimentalSettingsStore.shared.snapshot.diagnosticOverrides
            overrides.prefetchFilter = newValue
            ExperimentalSettingsStore.shared.updateDiagnosticOverrides(overrides)
        }
    }

    func refreshMultiConnectionTelemetry() {}

    func setMultiConnectionQuiet(_ quiet: MultiConnectionQuiet) { _ = quiet }

    // MARK: - Lifecycle

    func load(
        url: URL,
        audioURL: URL?,
        headers: [String: String],
        startPosition: TimeInterval,
        playbackRate: Float,
        hardwareDecode: Bool,
        networkCaching: TimeInterval,
        maxBuffer: TimeInterval,
        preferNativeVideoToolbox: Bool = false,
        alternateVideoURLs: [URL] = [],
        alternateAudioURLs: [URL] = [],
        readAheadSeconds: TimeInterval? = nil,
        multiConnectionPolicy: MultiConnectionPolicy? = nil,
        liveSource _: DemandLiveSource? = nil
    ) {
        _ = alternateVideoURLs
        _ = alternateAudioURLs
        _ = readAheadSeconds
        _ = multiConnectionPolicy
        let isSeekReopen = nextLoadIsSeekReopen
        nextLoadIsSeekReopen = false

        runtimeGeneration &+= 1
        retainedLivenessObservation.cancel(reason: .load)
        player.stop()
        eventTask?.cancel()

        guard let media = try? Media(url: url) else {
            pendingSeekTarget = nil
            settlePendingSeek(false, reason: "mediaCreationFailed")
            onStateChanged?(.error(VLCError.mediaCreationFailed(source: url.absoluteString)))
            return
        }
        if let audioURL {
            try? media.addSlave(from: audioURL, type: .audio, priority: 4)
            if url.isFileURL, audioURL.isFileURL {
                media.addOption(":slave-audio-lead-ms=0")
                PlayerLog.log(
                    "[VLC] local split asset: slave lead disabled; bounded file cache"
                )
            }
        }

        if let referer = headers["Referer"] {
            media.addOption(":http-referrer=\(referer)")
        }
        if let ua = headers["User-Agent"] {
            media.addOption(":http-user-agent=\(ua)")
        }

        let cachingMs = Int(networkCaching * 1000)
        media.addOption(":network-caching=\(cachingMs)")

        if url.isFileURL {
            let maxBufferMs = Int(maxBuffer * 1000)
            media.addOption(":file-caching=\(maxBufferMs)")
        }

        if Self.prefetchFilterExperimentEnabled, !url.isFileURL {
            media.addOption(":stream-filter=prefetch")
            PlayerLog.log(
                "[VLC] 🧪 prefetch stream filter armed (default 16 MiB ring; experiment; " +
                """
                setTimeSeek=\(ExperimentalSettingsPolicy.diagnosticBool(
                    key: "settime_seek_experiment",
                    saved: ExperimentalSettingsPolicy.diagnosticOverrides.setTimeSeek
                ) ? "on" : "OFF — reopen seeks discard the ring"))
                """
            )
        }

        media.addOption(hardwareDecode ? ":avcodec-hw=any" : ":avcodec-hw=none")

        if preferNativeVideoToolbox {
            media.addOption(":codec=videotoolbox")
        }

        if startPosition > 0 {
            media.addOption(":start-time=\(startPosition)")
        }

        media.addOption(":timeout=10")

        media.addOption(":audio-time-stretch")

        logPitchConfiguration()

        lastDisplayedPictures = 0
        lastFPSSampleTime = CACurrentMediaTime()
        measuredFPS = 0
        startPositionChecked = false
        activeVoutCount = 0
        hasFiredReady = false
        lastTickTime = 0
        lastKnownDuration = 0
        loadStartOffset = max(0, startPosition)
        inputIsLocalFile = url.isFileURL
        seekFromTime = 0
        let armSeekPhase = startPosition > 0.5 || isSeekReopen
        pendingSeekTarget = armSeekPhase ? startPosition : nil
        settlePendingSeek(false, reason: "superseded by load()")
        seekLanded = pendingSeekTarget != nil
        if armSeekPhase { seekIssuedAt = CACurrentMediaTime() }
        seekVisibleBaseline = (isSeekReopen && PlayerLog.isEnabled) ? 0 : nil
        startupVisibleBaseline = (startupTraceToken != nil && PlayerLog.isEnabled) ? 0 : nil
        startupVisibleArmedAt = CACurrentMediaTime()

        startEventLoop(traceToken: startupTraceToken)

        PlayerLog.log("[VLC] load: hw=\(hardwareDecode), caching=\(cachingMs)ms, startPos=\(String(format: "%.1f", startPosition))s")
        StartupTrace.mark("vlc-open-started", token: startupTraceToken)
        SeekTrace.mark("vlc-open-started")

        do {
            try player.play(media)
        } catch {
            pendingSeekTarget = nil
            settlePendingSeek(false, reason: "playFailed")
            onStateChanged?(.error(error))
            return
        }
        StartupTrace.mark("vlc-play-returned", token: startupTraceToken)

        if pendingSeekTarget != nil {
            startSeekSilenceWatchdog(targetForLog: startPosition, context: "open-at-position")
        }

        if playbackRate != 1.0 {
            try? player.setPlaybackRate(PlaybackRate(playbackRate))
        }
    }

    func parkForReuse() -> Bool { false }

    var hasParkedSession: Bool { false }

    func stop() {
        runtimeGeneration &+= 1
        PlayerLog.log("[VLC] stop() called, state=\(player.state)")
        eventTask?.cancel()
        eventTask = nil
        pendingSeekTarget = nil
        settlePendingSeek(false, reason: "stop()")
        seekVisibleBaseline = nil
        startupVisibleBaseline = nil
        retainedLivenessObservation.cancel(reason: .stop)
        player.stop()
    }

    // MARK: - Transport

    func play() {
        PlayerLog.log("[VLC] play() called, state=\(player.state)")
        switch player.state {
        case .stopped, .idle:
            try? player.play()
        default:
            player.resume()
        }
    }

    func pause() {
        PlayerLog.log("[VLC] pause() called, state=\(player.state)")
        player.pause()
    }

    func seek(to time: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?) {
        PlayerLog.log("[VLC] seek(to: \(String(format: "%.1f", time))) called, state=\(player.state)")
        settlePendingSeek(false, reason: "superseded by seek()")

        pendingSeekGate = SeekCompletionGate(completion: completion)
        seekVisibleBaseline = PlayerLog.isEnabled ? player.statistics?.displayedPictures : nil
        seekIssuedAt = CACurrentMediaTime()
        seekFromTime = lastTickTime
        seekLanded = false

        let playerTotal = player.duration?.timeInterval ?? 0
        let absTotal = playerTotal > 0 ? playerTotal + loadStartOffset : 0
        let absTarget = absTotal > 0
            ? min(max(loadStartOffset, time), absTotal - Self.endOfMediaSeekReserve)
            : max(loadStartOffset, time)
        if time < loadStartOffset - 0.5 {
            PlayerLog.log("[VLC] ⚠️ seek to \(String(format: "%.1f", time))s precedes the demuxer's open position (\(String(format: "%.1f", loadStartOffset))s) — clamped; a reload is required to go earlier")
        }
        pendingSeekTarget = absTarget
        let playerTarget = max(0, absTarget - loadStartOffset)

        var issued = false
        if player.isSeekable, playerTotal > 0 {
            do {
                try player.seek(to: .seconds(playerTarget))
                issued = true
            } catch {
                PlayerLog.log("[VLC] strict seek rejected (\(error)) — lenient fallback")
            }
        }
        if !issued {
            issued = playerTotal > 0
                ? player.seek(toPosition: PlaybackPosition(playerTarget / playerTotal))
                : player.jump(by: .seconds(absTarget - lastTickTime))
        }
        if !issued {
            PlayerLog.log("[VLC] seek not issued yet (seekable=\(player.isSeekable)) — awaiting settle/timeout")
        }

        startSeekSilenceWatchdog(targetForLog: time, context: "seek")
    }

    private func startSeekSilenceWatchdog(targetForLog target: TimeInterval, context: String) {
        seekProgressAt = CACurrentMediaTime()
        let gate = pendingSeekGate ?? SeekCompletionGate()
        pendingSeekGate = gate
        gate.timeoutTask?.cancel()
        gate.timeoutTask = Task { [weak self, weak gate] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let gate,
                      self.pendingSeekGate === gate, self.pendingSeekTarget != nil else { return }
                let silent = CACurrentMediaTime() - self.seekProgressAt
                guard silent >= Self.seekSilenceTimeout else { continue }
                PlayerLog.log("[VLC] ⚠️ \(context) to \(String(format: "%.1f", target)) made no progress for \(Int(silent))s — abandoning as FAILED (clock is at \(String(format: "%.1f", self.lastTickTime)))")
                SeekTrace.abort("silence-\(context)")
                self.pendingSeekTarget = nil
                self.settlePendingSeek(false, reason: "silence-\(context)")
                return
            }
        }
    }

    private func settlePendingSeek(_ finished: Bool, reason: String) {
        guard let gate = pendingSeekGate else { return }
        pendingSeekGate = nil
        if gate.hasPendingWork {
            PlayerLog.log("[VLC] pending seek completion settled \(finished) (\(reason))")
        }
        gate.settle(finished)
    }

    private static let seekSilenceTimeout: CFTimeInterval = 8

    var isReadyToPlay: Bool {
        switch player.state {
        case .playing, .paused, .buffering: true
        default: false
        }
    }

    var retainedPipelineHealth: RetainedPipelineHealth {
        func verdict(_ reason: RetainedPipelineHealth.Reason) -> RetainedPipelineHealth {
            RetainedPipelineHealth(
                backendGeneration: runtimeGeneration,
                state: .requiresRecovery(reason)
            )
        }
        switch player.state {
        case .stopped, .idle:
            return verdict(.terminal)
        case .buffering:
            return verdict(.transportNotReady)
        case .playing, .paused:
            break
        default:
            return verdict(.transportNotReady)
        }
        if !hasFiredReady {
            return verdict(.transportNotReady)
        }
        if pendingSeekTarget != nil {
            return verdict(.seekInFlight)
        }
        if activeVoutCount == 0 {
            return verdict(.missingResources)
        }
        return verdict(.unverifiedBackend)
    }

    func confirmRetainedLiveness(within timeout: TimeInterval) async -> Bool {
        retainedLivenessObservation.cancel(reason: .superseded)
        switch player.state {
        case .playing, .buffering:
            break
        default:
            PlayerLog.log(
                "[VLC] retained-liveness refused — transport is \(player.state), nothing to observe"
            )
            return false
        }
        guard timeout > 0 else { return false }
        let generation = runtimeGeneration
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let armedAt = CACurrentMediaTime()
            PlayerLog.log(
                "[VLC] retained-liveness armed t=\(String(format: "%.1f", lastTickTime))s " +
                "window=\(Int(timeout * 1000))ms"
            )
            retainedLivenessObservation.begin(
                generation: generation,
                baselineTick: lastTickTime,
                baselinePictures: player.statistics?.displayedPictures ?? 0,
                timeout: timeout
            ) { alive, reason in
                let ms = Int((CACurrentMediaTime() - armedAt) * 1000)
                PlayerLog.log(
                    "[VLC] retained-liveness \(alive ? "ALIVE" : "dead") " +
                    "(\(reason.rawValue)) after \(ms)ms"
                )
                continuation.resume(returning: alive)
            }
        }
    }

    private func checkRetainedLiveness() {
        guard retainedLivenessObservation.isObserving else { return }
        retainedLivenessObservation.observe(
            generation: runtimeGeneration,
            tick: lastTickTime,
            pictures: player.statistics?.displayedPictures
        )
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    // MARK: - Properties

    var currentTime: TimeInterval {
        player.currentTime.timeInterval
    }

    var openedAtPosition: TimeInterval { loadStartOffset }

    var duration: TimeInterval {
        guard let reported = player.duration?.timeInterval else { return 0 }
        return reported + loadStartOffset
    }

    var playableTime: TimeInterval {
        vlcAvailabilityHorizon(
            inputIsLocalFile: inputIsLocalFile,
            mediaDuration: duration,
            lastObservedPosition: lastTickTime
        )
    }

    var bufferedContentAhead: TimeInterval? { nil }
    var bufferedPipelineAhead: TimeInterval? { nil }
    var videoDeliveryRunway: TimeInterval? { nil }

    var playbackRate: Float {
        get { player.rate }
        set { try? player.setPlaybackRate(PlaybackRate(newValue)) }
    }

    var effectivePlaybackRate: Float {
        isPlaying ? player.rate : 0
    }

    var volume: Float {
        get { player.volume }
        set { try? player.setAudioVolume(Volume(newValue)) }
    }

    static let endOfMediaSeekReserve: TimeInterval = 0.5

    var seekLaunchReserve: TimeInterval { Self.endOfMediaSeekReserve }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    // MARK: - Rendering

    var renderViewController: UIViewController? {
        videoHosting
    }

    func setScaleMode(_ mode: VideoScaleMode) {
        switch mode {
        case .fit:
            player.aspectRatio = .default
        case .fill:
            player.aspectRatio = .fill
        case .stretch:
            player.aspectRatio = .fill
        }
    }

    // MARK: - PiP

    var isPiPActive: Bool {
        videoHosting.pictureInPictureController.isActive
    }

    var hasObservedPiPLease: Bool {
        observedPiPLease
    }

    func setObservedPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        observedPiPLeaseChangeHandler = handler
    }

    private func updateObservedPiPLease(_ active: Bool) {
        guard observedPiPLease != active else { return }
        observedPiPLease = active
        observedPiPLeaseChangeHandler?(active)
    }

    private func observePiPLease(_ controller: PiPController) {
        pipEventTask?.cancel()
        pipEventTask = nil
        updateObservedPiPLease(false)
        let revision = continuationHostRevision
        PlayerLog.log("[PiP] controller bound hostRevision=\(revision)")
        pipEventTask = Task { [weak self] in
            for await event in controller.pipEvents {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .didStart:
                    self.updateObservedPiPLease(true)
                    PlayerLog.log("[PiP] observed lease started hostRevision=\(revision)")
                    if !PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsAutomaticPiP {
                        PlayerLog.log(
                            "[PiP] ASSERT disabled configuration reached didStart " +
                            "hostRevision=\(revision)"
                        )
                        self.stopPiP()
                    }
                case .didStop:
                    self.updateObservedPiPLease(false)
                    PlayerLog.log("[PiP] observed lease ended hostRevision=\(revision)")
                case .willStart, .willStop, .failedToStart:
                    break
                }
            }
        }
    }

    func startPiP() {
        guard PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsAutomaticPiP else {
            PlayerLog.log("[PiP] start ignored — continuation setting disabled")
            return
        }
        videoHosting.pictureInPictureController.start()
    }

    func stopPiP() {
        updateObservedPiPLease(false)
        videoHosting.pictureInPictureController.stop()
    }

    func applyPlaybackContinuationConfiguration(
        _ configuration: PlaybackContinuationConfiguration
    ) -> PlaybackContinuationApplyResult {
        let automaticPiP = configuration.allowsAutomaticPiP
        guard automaticPiP != automaticPiPEnabled else {
            PlayerLog.log(
                "[PiP] configuration unchanged hostRevision=\(continuationHostRevision) " +
                "backgroundAudio=\(configuration.backgroundAudioEnabled ? 1 : 0) " +
                "pictureInPicture=\(configuration.pictureInPictureEnabled ? 1 : 0)"
            )
            return .unchanged(hostRevision: continuationHostRevision)
        }

        stopPiP()
        pipEventTask?.cancel()
        pipEventTask = nil
        let previousHosting = videoHosting
        automaticPiPEnabled = automaticPiP
        continuationHostRevision &+= 1
        videoHosting = Self.makeVideoHosting(
            player: player, startsAutomaticallyFromInline: automaticPiP
        )
        previousHosting.invalidate()
        observePiPLease(videoHosting.pictureInPictureController)
        PlayerLog.log(
            "[PiP] host replaced revision=\(continuationHostRevision) " +
            "backgroundAudio=\(configuration.backgroundAudioEnabled ? 1 : 0) " +
            "pictureInPicture=\(configuration.pictureInPictureEnabled ? 1 : 0) " +
            "automatic=\(automaticPiP ? 1 : 0)"
        )
        return .renderHostReplaced(hostRevision: continuationHostRevision)
    }

    // MARK: - Info

    func videoTracks() -> [PlayerTrackInfo] {
        player.videoTracks.map { track in
            PlayerTrackInfo(
                name: track.name,
                naturalSize: CGSize(
                    width: track.width ?? 0,
                    height: track.height ?? 0
                )
            )
        }
    }

    var dynamicInfo: PlayerDynamicStats? {
        guard let stats = player.statistics else { return nil }
        return PlayerDynamicStats(
            displayFPS: measuredFPS,
            videoBitrate: Int(stats.demuxBitrate * 8000),
            audioBitrate: 0,
            bytesRead: Int64(stats.readBytes),
            networkBytesReceived: Int64(stats.readBytes)
        )
    }

    func thumbnailAtCurrentTime() async -> UIImage? {
        if let size = videoTracks().first?.naturalSize,
           size.width * size.height > 1920 * 1080 {
            PlayerLog.log("[VLC] snapshot skipped (\(Int(size.width))×\(Int(size.height)) > 1080p — avoids main-thread PNG-encode hang)")
            return nil
        }
        let path = NSTemporaryDirectory() + "vlc_snap_\(ProcessInfo.processInfo.globallyUniqueString).png"
        do {
            try player.takeSnapshot(to: path)
            return await Task.detached {
                defer { try? FileManager.default.removeItem(atPath: path) }
                return UIImage(contentsOfFile: path)
            }.value
        } catch {
            return nil
        }
    }

    // MARK: - Event Loop

    private func startEventLoop(traceToken: StartupTrace.Token?) {
        eventTask?.cancel()
        let player = self.player
        let openGeneration = runtimeGeneration
        let stream = player.events(policy: .unbounded, filter: { event in
            if case .positionChanged = event { return false }
            return true
        })
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { return }
                self.handleEvent(
                    event,
                    runtimeGeneration: openGeneration,
                    traceToken: traceToken
                )
            }
        }
    }

    private func handleEvent(
        _ event: PlayerEvent,
        runtimeGeneration: UInt64,
        traceToken: StartupTrace.Token?
    ) {
        guard runtimeGeneration == self.runtimeGeneration else { return }
        switch event {
        case .stateChanged(let state):
            PlayerLog.log("[VLC] event: stateChanged(\(state))")
            switch state {
            case .opening:
                StartupTrace.mark("vlc-opening", token: traceToken)
                SeekTrace.mark("vlc-opening")
                onStateChanged?(.buffering)
            case .buffering:
                onStateChanged?(.buffering)
            case .playing:
                if !hasFiredReady {
                    hasFiredReady = true
                    StartupTrace.mark("ready-to-play", token: traceToken)
                    SeekTrace.mark("ready-to-play")
                    onStateChanged?(.readyToPlay)
                }
                if pendingSeekTarget == nil {
                    onStateChanged?(.bufferFinished)
                }
            case .paused:
                onStateChanged?(.paused)
            case .stopped, .stopping, .idle:
                break
            case .error:
                pendingSeekTarget = nil
                settlePendingSeek(false, reason: "stateChanged(.error)")
                onStateChanged?(.error(VLCError.playbackFailed(reason: "Playback error")))
            }

        case .bufferingProgress(let fill):
            StartupTrace.mark("first-buffering-progress", token: traceToken)
            SeekTrace.mark("first-buffering-progress")
            checkSeekVisibleFrame()
            checkStartupVisibleFrame()
            checkRetainedLiveness()
            if pendingSeekTarget != nil { seekProgressAt = CACurrentMediaTime() }
            if fill >= 1.0 {
                PlayerLog.log("[VLC] event: bufferingProgress(1.0) — buffer full")
                if !hasFiredReady {
                    hasFiredReady = true
                    onStateChanged?(.readyToPlay)
                }
                if pendingSeekTarget == nil {
                    onStateChanged?(.bufferFinished)
                }
            } else {
                PlayerLog.log("[VLC] event: bufferingProgress(\(String(format: "%.0f%%", fill * 100)))")
            }

        case .timeChanged(let time):
            checkSeekVisibleFrame()
            checkStartupVisibleFrame()
            checkRetainedLiveness()
            let t = time.timeInterval
            verifyStartPosition(against: t)
            if pendingSeekTarget != nil, t != lastTickTime { seekProgressAt = CACurrentMediaTime() }
            lastTickTime = t
            SeekTrace.markFirstTick(landedAt: t)
            settlePendingSeekIfArrived(at: t)
            if !hasFiredReady, t > 0 {
                hasFiredReady = true
                onStateChanged?(.readyToPlay)
                if pendingSeekTarget == nil {
                    onStateChanged?(.bufferFinished)
                }
            }
            updateFPS()
            onTickWithGeneration?(t, duration, runtimeGeneration, traceToken)

        case .endReached:
            if pendingSeekTarget != nil {
                PlayerLog.log("[VLC] event: endReached SWALLOWED (seek pending → false EOF)")
            } else if lastKnownDuration > 0, lastKnownDuration - lastTickTime > 5 {
                PlayerLog.log("[VLC] ⚠️ premature endReached at \(String(format: "%.1f", lastTickTime))s of \(String(format: "%.1f", lastKnownDuration))s — treating as stream failure, not end-of-media")
                onStateChanged?(.error(VLCError.playbackFailed(
                    reason: "stream ended early at \(String(format: "%.1f", lastTickTime))s of \(String(format: "%.1f", lastKnownDuration))s"
                )))
            } else {
                PlayerLog.log("[VLC] event: endReached (at \(String(format: "%.1f", lastTickTime))s of \(String(format: "%.1f", lastKnownDuration))s)")
                onStateChanged?(.playedToTheEnd)
            }

        case .encounteredError:
            PlayerLog.log("[VLC] event: encounteredError")
            pendingSeekTarget = nil
            settlePendingSeek(false, reason: "encounteredError")
            onStateChanged?(.error(VLCError.playbackFailed(reason: "VLC error")))

        case .voutChanged(let count):
            if count > 0 {
                StartupTrace.mark("first-vout", token: traceToken)
                SeekTrace.mark("first-vout")
            }
            let previous = activeVoutCount
            activeVoutCount = count
            PlayerLog.log("[VLC] event: voutChanged(\(count)), previous=\(previous)")
            if count == 0, previous > 0 {
                PlayerLog.log("[VLC] WARNING: video output lost (vout dropped to 0)")
            }

        case .corked:
            PlayerLog.log("[VLC] event: corked (audio output suspended by system)")

        case .uncorked:
            PlayerLog.log("[VLC] event: uncorked (audio output resumed)")

        case .tracksChanged:
            PlayerLog.log("[VLC] event: tracksChanged")

        case .mediaChanged:
            PlayerLog.log("[VLC] event: mediaChanged")

        case .seekableChanged(let seekable):
            PlayerLog.log("[VLC] event: seekableChanged(\(seekable))")

        case .pausableChanged(let pausable):
            PlayerLog.log("[VLC] event: pausableChanged(\(pausable))")

        case .lengthChanged(let length):
            lastKnownDuration = length.timeInterval + loadStartOffset
            PlayerLog.log("[VLC] event: lengthChanged(\(length.timeInterval)s → absolute \(String(format: "%.3f", lastKnownDuration))s, startOffset=\(String(format: "%.1f", loadStartOffset))s)")

        case .mediaStopping:
            PlayerLog.log("[VLC] event: mediaStopping")

        case .positionChanged:
            break

        case .volumeChanged(let vol):
            PlayerLog.log("[VLC] event: volumeChanged(\(vol))")

        case .muted:
            PlayerLog.log("[VLC] event: muted")

        case .unmuted:
            PlayerLog.log("[VLC] event: unmuted")

        case .chapterChanged(let ch):
            PlayerLog.log("[VLC] event: chapterChanged(\(ch))")

        case .recordingChanged(let recording, let path):
            PlayerLog.log("[VLC] event: recordingChanged(isRecording=\(recording), path=\(path ?? "nil"))")

        case .titleListChanged:
            PlayerLog.log("[VLC] event: titleListChanged")

        case .titleSelectionChanged(let idx):
            PlayerLog.log("[VLC] event: titleSelectionChanged(\(idx))")

        case .snapshotTaken(let path):
            PlayerLog.log("[VLC] event: snapshotTaken(\(path))")

        case .audioDeviceChanged(let device):
            PlayerLog.log("[VLC] event: audioDeviceChanged(\(device ?? "nil"))")

        case .programAdded(let id):
            PlayerLog.log("[VLC] event: programAdded(\(id))")

        case .programDeleted(let id):
            PlayerLog.log("[VLC] event: programDeleted(\(id))")

        case .programSelected(let unsel, let sel):
            PlayerLog.log("[VLC] event: programSelected(unselected=\(unsel), selected=\(sel))")

        case .programUpdated(let id):
            PlayerLog.log("[VLC] event: programUpdated(\(id))")
        }
    }

    private func verifyStartPosition(against t: TimeInterval) {
        guard !startPositionChecked, loadStartOffset > 0.5 else { return }
        startPositionChecked = true
        guard t < loadStartOffset - 5 else { return }
        PlayerLog.log("[VLC] ⚠️ opened at \(String(format: "%.1f", t))s but asked for \(String(format: "%.1f", loadStartOffset))s — :start-time may have been refused (F15; 0005 should prevent this)")
    }

    private func checkStartupVisibleFrame() {
        guard let baseline = startupVisibleBaseline else { return }
        guard let token = startupTraceToken else {
            startupVisibleBaseline = nil
            return
        }
        guard CACurrentMediaTime() - startupVisibleArmedAt < 30 else {
            startupVisibleBaseline = nil
            PlayerLog.log("[VLC] startup visible-frame probe timed out — no picture in 30s")
            return
        }
        guard let displayed = player.statistics?.displayedPictures,
              displayed > baseline else { return }
        startupVisibleBaseline = nil
        StartupTrace.mark(StartupTrace.measuredFirstFrameLabel, token: token)
    }

    private func checkSeekVisibleFrame() {
        guard let baseline = seekVisibleBaseline else { return }
        guard SeekTrace.wantsVisibleFrame else {
            seekVisibleBaseline = nil
            return
        }
        guard CACurrentMediaTime() - seekIssuedAt < 10 else {
            seekVisibleBaseline = nil
            SeekTrace.visibleProbeTimedOut()
            return
        }
        guard let displayed = player.statistics?.displayedPictures, displayed > baseline else { return }
        seekVisibleBaseline = nil
        SeekTrace.markVisibleFrame()
    }

    private func settlePendingSeekIfArrived(at t: TimeInterval) {
        guard let target = pendingSeekTarget else { return }
        let elapsed = CACurrentMediaTime() - seekIssuedAt
        let rate = Double(max(player.rate, 0.1))
        let extrapolatedOld = seekFromTime + elapsed * rate

        if !seekLanded {
            if abs(t - extrapolatedOld) > 1.0 || (elapsed > 1.0 && abs(t - target) < 1.0) {
                seekLanded = true
            }
        }
        guard seekLanded, t >= target - 0.5 else { return }

        PlayerLog.log("[VLC] seek settled: real clock \(String(format: "%.2f", t))s reached target \(String(format: "%.2f", target))s")
        SeekTrace.mark("arrived")
        pendingSeekTarget = nil
        settlePendingSeek(true, reason: "arrived")
    }

    private func updateFPS() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFPSSampleTime
        if elapsed >= 1.0 {
            guard let stats = player.statistics else { return }
            let current = stats.displayedPictures
            if current >= lastDisplayedPictures {
                let delta = current - lastDisplayedPictures
                measuredFPS = Double(delta) / elapsed
            } else {
                measuredFPS = 0
            }
            lastDisplayedPictures = current
            lastFPSSampleTime = now
        }
    }

    func invalidateFrameStats() {
        measuredFPS = 0
        lastFPSSampleTime = CACurrentMediaTime()
        if let stats = player.statistics {
            lastDisplayedPictures = stats.displayedPictures
        } else {
            lastDisplayedPictures = 0
        }
    }
}

private enum VLCEngineHost {
    struct Selection: Sendable {
        let instance: VLCInstance
        let supportsEqualizer: Bool
        let pitchEngine: Bool?
    }

    static let selection: Selection? = {
        var args = VLCInstance.defaultArguments
        args.append(PlayerLog.isEnabled ? "--verbose=2" : "--quiet")
        args.append("--aout=avsamplebuffer")
        args.append("--no-equalizer-vlcfreqs")
        args.append("--no-equalizer-2pass")
        let pitchEngine = ExperimentalSettingsPolicy.diagnosticBool(
            key: "pitch_corrected_rate",
            saved: ExperimentalSettingsPolicy.diagnosticOverrides.audioOutputSpeed
        )
        args.append(pitchEngine ? "--avsb-pitch-engine" : "--no-avsb-pitch-engine")
        if pitchEngine {
            args.append("--slave-audio-lead-ms=6000")
        }
        PlayerLog.log(
            "[VLC] instance aout=avsamplebuffer pitch_engine=\(pitchEngine ? "on" : "off")"
            + (pitchEngine ? " slave-audio-lead-ms=6000 0015" : "")
        )
        if let instance = try? VLCInstance(arguments: args) {
            return Selection(
                instance: instance,
                supportsEqualizer: PlayerEqualizerArtifact.isLinkedSliceSupported,
                pitchEngine: pitchEngine
            )
        }
        PlayerLog.diagnostic(
            "[VLC] ⛔️ libvlc_new rejected the instance arguments — libVLC engine unavailable. " +
            "The linked libvlc slice does not implement the configured options (stale slice?): " +
            args.joined(separator: " ")
        )
        return nil
    }()

    static func prewarm() {
        Task.detached(priority: .utility) {
            let start = CACurrentMediaTime()
            _ = selection
            PlayerLog.log(
                "[VLC] engine pre-warmed off-main "
                + "(\(Int((CACurrentMediaTime() - start) * 1000))ms)"
            )
        }
    }
}
