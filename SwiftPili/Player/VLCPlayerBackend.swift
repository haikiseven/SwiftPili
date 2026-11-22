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

/// `VLCPlayerBackend.playableTime` availability horizon: complete media duration
/// for committed local files, or `min(lastObservedPosition, mediaDuration)` for
/// network streams where libVLC exposes no seconds-denominated read-ahead buffer.
func vlcAvailabilityHorizon(
    inputIsLocalFile: Bool,
    mediaDuration: TimeInterval,
    lastObservedPosition: TimeInterval
) -> TimeInterval {
    // Before libVLC reports a length there is no horizon to clamp to, and no
    // basis for claiming a file is wholly available either.
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

    /// Process-wide libVLC instance constructed off the main actor via `VLCEngineHost`.
    private nonisolated static var vlcSelection: VLCEngineHost.Selection? { VLCEngineHost.selection }

    /// Whether this process can build a libVLC backend at all.
    static var isEngineAvailable: Bool { vlcSelection != nil }

    /// Prewarm the process-wide libVLC instance off the main actor before detail entry.
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
    /// The actual native drawable survives inline/fullscreen reparenting,
    /// without a nested SwiftUI representable rebuilding its video destination.
    private var videoHosting: PiPVideoViewController
    private var automaticPiPEnabled: Bool
    private var continuationHostRevision: UInt64 = 1
    private var eventTask: Task<Void, Never>?
    private var pipEventTask: Task<Void, Never>?
    /// Forwards libVLC's internal log messages into PlayerLog. Lives for the
    /// backend's lifetime (instance-scoped, not per-media).
    private var vlcLogTask: Task<Void, Never>?
    /// A raw native PiP flag has been observed sticky after ordinary app
    /// switches. Only this event-backed lease may keep a page exit alive.
    private var observedPiPLease = false
    private var observedPiPLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?

    /// One-shot caller signal, consumed by the next `load()`: this open
    /// replaces a user seek, so the seek phase must arm even when the target
    /// is ≤ 0.5s (see the arming comment in `load`). Set by
    /// `PlayerViewModel.playURL(isSeekReopen:)` immediately before `load` in
    /// the same synchronous scope, so it cannot leak across loads.
    var nextLoadIsSeekReopen = false

    /// SeekTrace's visible-frame probe: the displayed-picture count at seek
    /// issue. While armed, every timeChanged/bufferingProgress event compares
    /// the live counter against it; the first increment IS the first rendered
    /// post-seek picture (event-cadence sampled). nil = disarmed — the fetch
    /// of `player.statistics` then costs nothing, keeping updateFPS's ≥1s
    /// gating intact outside seek windows. Self-healing: a mark landing on a
    /// closed session no-ops and the probe disarms with it.
    private var seekVisibleBaseline: UInt64?
    /// Startup twin of `seekVisibleBaseline`: the displayed-picture count when
    /// this load began, so the first increment is the first PRESENTED frame of
    /// a cold start. Armed only while a StartupTrace session is open.
    private var startupVisibleBaseline: UInt64?
    private var startupVisibleArmedAt: CFTimeInterval = 0

    private let retainedLivenessObservation = VLCRetainedLivenessObservation()

    private var lastDisplayedPictures: UInt64 = 0
    private var lastFPSSampleTime: CFTimeInterval = 0
    private var measuredFPS: Double = 0

    /// One libVLC open. Bumped by `load()`/`stop()` so a callback from a
    /// replaced media can be told apart from the current one.
    private(set) var runtimeGeneration: UInt64 = 0

    private var startupTraceToken: StartupTrace.Token?

    private(set) var pendingSeekTarget: TimeInterval?
    private var pendingSeekCompletion: (@MainActor @Sendable (Bool) -> Void)?
    private var seekTimeoutTask: Task<Void, Never>?
    /// Wall-clock time of the most recent seek() call. Used to suppress
    /// premature settlement: with VLC's coarse keyframe seeks, a rapid
    /// A->B sequence can produce a timeChanged from A's landing that
    /// satisfies B's 2-second tolerance window. Requiring 0.3s to elapse
    /// after the seek was issued lets VLC start seeking to the new target
    /// before we check for arrival.
    private var seekIssuedAt: CFTimeInterval = 0
    /// Last moment the in-flight seek visibly advanced — a buffering tick or a
    /// clock tick. The seek watchdog measures silence since this, not elapsed
    /// time: a seek now downloads its preroll (up to ~10s of stream), so a slow
    /// link can legitimately take longer than any fixed ceiling.
    private var seekProgressAt: CFTimeInterval = 0
    /// A `:start-time` open is only *asked* for. The first real clock tick is
    /// the first honest evidence of where the demuxer actually landed.
    private var startPositionChecked = false

    /// Tracks the number of active video outputs reported by VLC.
    /// A drop from >0 to 0 mid-play means VLC lost its render surface.
    private var activeVoutCount: Int = 0

    /// True once `.readyToPlay` has been emitted for the current load.
    /// Readiness is driven off the first `.playing` state (or the first
    /// advancing `timeChanged`, or a full buffer) — whichever the lossless
    /// event stream delivers first — NOT off a specific `bufferingProgress(1.0)`
    /// value, which libVLC does not guarantee to emit.
    private var hasFiredReady = false

    /// Last position reported by a real `timeChanged` event, and the last
    /// duration libVLC announced. `player.currentTime` is NOT usable for
    /// either: SwiftVLC stamps it synchronously to the seek target, and zeroes
    /// it on `stopped`. These are the only trustworthy "where were we when the
    /// input died" values.
    private var lastTickTime: TimeInterval = 0
    private var lastKnownDuration: TimeInterval = 0

    /// Real clock at the moment the last seek was issued, and whether that
    /// seek's discontinuity has been observed yet. Used to settle a seek on the
    /// REAL clock reaching the target while rejecting stale in-flight ticks
    /// from the pre-seek position (critical for BACKWARD seeks, whose leftover
    /// ticks arrive far ahead of the target and would otherwise look like
    /// arrival).
    private var seekFromTime: TimeInterval = 0
    private var seekLanded = false

    /// The `:start-time` handed to libVLC for the current load.
    ///
    /// When `:start-time=X` is set, libVLC reports the media length as the
    /// REMAINING duration (total − X) while `currentTime` stays absolute.
    /// Device log: `starting at time: 40s` → `lengthChanged(55.334s)` for a
    /// 95.334s media. Add the offset back so `duration` is absolute and
    /// consistent with `currentTime`; otherwise the scrubber, the progress
    /// percentage, the watched-to-the-end verdict and the premature-EOF check
    /// all read a duration the clock runs straight past.
    private var loadStartOffset: TimeInterval = 0

    /// The current input is a local file, so every byte is already present: there
    /// is no delivery to wait for and the availability horizon is the whole media.
    /// Set per `load()`, like `loadStartOffset` — a backend outlives its loads.
    private var inputIsLocalFile = false

    // MARK: - Events

    var onStateChanged: (@MainActor @Sendable (PlayerStateEvent) -> Void)?
    var onTickWithGeneration: (@MainActor @Sendable (_ currentTime: TimeInterval, _ totalTime: TimeInterval, _ generation: UInt64, _ startupTraceToken: StartupTrace.Token?) -> Void)?
    /// Conformance only: this backend never invokes it, because the runway it
    /// carries is the one `bufferedContentAhead` reports as unmeasurable.
    var onBufferChanged: (@MainActor @Sendable (_ consumeTime: TimeInterval) -> Void)?

    // MARK: - Init

    /// Fails when libVLC rejects the configured instance arguments.
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

        // Activate audio session once at init — it persists across loads.
        // Off-main to avoid the iOS 27 main-thread responsiveness warning.
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    isolated deinit {
        pipEventTask?.cancel()
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

    /// Per-frame trace lines libVLC emits at `debug`. The HTTP/2 access logs
    /// one line per DATA frame — at 8KB/frame and ~10Mbps that is ~160 lines a
    /// second, enough to hitch the app and bury every useful message. The
    /// signal we actually need ("stream N closed by peer", "end of stream",
    /// "EOF reached", "buffer deadlock prevented", the sidx/moof seek lines) is
    /// also `debug`, so the level can't simply be raised — filter by message.
    private nonisolated static func isVLCLogNoise(_ message: String) -> Bool {
        message.hasPrefix("in DATA")
            || message.hasPrefix("out DATA")
            || message.hasPrefix("in WINDOW_UPDATE")
            || message.hasPrefix("out WINDOW_UPDATE")
            // Duplicated verbatim by our own bufferingProgress events.
            || message.hasPrefix("Buffering ")
    }

    /// A message's "shape", with digit runs collapsed to `#`, so that
    /// `deferring start (335452 us)` and `deferring start (132 us)` compare
    /// equal. Used to fold a burst of near-identical lines into one.
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

    /// Routes libVLC's own messages (module, level, text) into PlayerLog.
    /// This is what names the real reason an input dies — e.g. a server that
    /// ends the HTTP/2 response mid-file, which libVLC reports as a clean
    /// end-of-stream and the player would otherwise see only as an
    /// unexplained `stopped`.
    ///
    /// Consecutive lines of the same shape are folded: the first is printed,
    /// the rest are counted and summarised when the run ends. libVLC emits
    /// `deferring start (N us)` once per attempt while the video output waits
    /// out the A/V fragment gap (hundreds of lines per seek), and
    /// `picture is too late to be displayed (missing N ms)` per late frame.
    /// Both are worth seeing once, not hundreds of times — folding keeps the
    /// signal (that it happened, how long it went on) at ~2 lines.
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
        // Read the main-actor static once, then hand the Sendable instance to a
        // detached consumer: libVLC yields log entries from its own thread.
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

    /// Opt the next loads into the `prefetch` stream filter (see the option
    /// site in `load`). The product default is ON; the Settings toggle or an
    /// explicit key remains a rollback. Applies from the NEXT load — no
    /// relaunch.
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

    /// libVLC owns its transport and does not construct the Demand prefetcher.
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
        // Consume the one-shot seek-reopen signal FIRST — before any early
        // return. Consumed at the Media guard's far side it survived a failed
        // open and wrongly armed the seek phase on the NEXT, unrelated load.
        let isSeekReopen = nextLoadIsSeekReopen
        nextLoadIsSeekReopen = false

        runtimeGeneration &+= 1
        // A pending foreground observation belongs to the pipeline being
        // replaced; it cannot be answered by the one about to open.
        retainedLivenessObservation.cancel(reason: .load)
        player.stop()
        eventTask?.cancel()

        // Keep video as main media and audio as slave: a large fragmented video slave
        // can fail seek tail-probing with EOF, whereas patch 0003 seeks the audio slave
        // directly to the requested timestamp rather than the video fragment boundary.
        guard let media = try? Media(url: url) else {
            onStateChanged?(.error(VLCError.mediaCreationFailed(source: url.absoluteString)))
            return
        }
        if let audioURL {
            try? media.addSlave(from: audioURL, type: .audio, priority: 4)
            if url.isFileURL, audioURL.isFileURL {
                // Disable the online 6s slave audio lead on local split files so
                // faster-than-realtime file demuxing cannot overflow the PCM bank.
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

        // `:file-caching` is consumed only by libVLC's file access.
        if url.isFileURL {
            let maxBufferMs = Int(maxBuffer * 1000)
            media.addOption(":file-caching=\(maxBufferMs)")
        }

        // Optional DEBUG `prefetch` stream filter (16 MiB history ring for in-demuxer `set_time` seeks).
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

        // AV1: prefer the native VideoToolbox decoder module. Without this,
        // avcodec's "ffmpeghw" submodule (capability 10001) outranks the native
        // videotoolbox module (800) and claims av01 via the FFmpeg-VT hwaccel VA
        // path — which captures the pre-decode buffer and renders black (design
        // doc F17; patch 0008 is the native path but is otherwise unreachable).
        // `:codec=` is a NON-strict preference (module_need_var → strict=false):
        // the native module is tried first, and everything else still falls back
        // normally — the audio ES (no VT match) lands on avcodec, and if native
        // AV1 can't open, it drops through to ffmpeghw/dav1d. Scoped to AV1 by
        // the caller so h264/hevc keep their current decoder.
        if preferNativeVideoToolbox {
            media.addOption(":codec=videotoolbox")
        }

        if startPosition > 0 {
            media.addOption(":start-time=\(startPosition)")
        }

        media.addOption(":timeout=10")

        // No `:http-reconnect` — verified no-op. VLC 4's access/http module
        // registers only http-continuous / http-forward-cookies /
        // http-referrer / http-user-agent (the `http-reconnect` string exists
        // in libvlc because a different module declares it). Nothing on this
        // path reads it.
        //
        // Truncation recovery is already built in, in access/http/file.c: when
        // a response body ends early it re-issues a Range request — but ONLY if
        // the response advertises `Accept-Ranges` AND a known total size
        // (Content-Length on a 200, or the total in Content-Range on a 206).
        // That gate is why a CDN that ends the HTTP/2 response without a size
        // kills playback. `:http-continuous` is the wrong lever: it swaps the
        // seekable FileRead for the live, non-seekable LiveRead.
        //
        // HTTP/2 cannot be disabled by any option: connmgr.c selects it purely
        // via TLS-ALPN ({"h2", "http/1.1"}). Plaintext http:// is HTTP/1.1-only
        // (vlc_h1_request, no h2c) — the one supported way to avoid h2.

        // Issue 2: Audio output option — ensure VLC streams audio correctly.
        media.addOption(":audio-time-stretch")

        // Audio-rate rework (docs/AUDIO_RATE_REWORK.md, docs/LIBVLC_ITERATION.md):
        // aout selection + pitch-engine flag are INSTANCE args (see vlcInstance).
        // Media options here cannot flip the backend: aout Open() already ran at
        // Player init and the output is reused. Logged so a stale instance is
        // obvious when the Settings toggle and the live path disagree.
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
        // A `:start-time` open IS a seek: libVLC lands the video and the audio
        // slave on their own fragments exactly as it does for `seek()`, so the
        // clock arrives seconds before `startPosition`. Enter the same pending
        // state so the whole player treats the catch-up as a seek in progress.
        // It is already "landed" — there are no stale pre-seek ticks to reject.
        //
        // A SEEK-REOPEN arms regardless of position: `> 0.5` alone left a
        // seek-to-≤0.5s open with no seek phase at all — the false-EOF swallow
        // never opened, the watchdog stayed live with the position reading as
        // "startup", and a HEALTHY reopen's normal noise escalated into a CDN
        // switch (device: seek-to-0 stall). The caller signals intent through
        // `nextLoadIsSeekReopen` because only it knows a 0 is a seek target
        // rather than a cold start; with target 0 the settle gate
        // (t >= target − 0.5) closes on the very first tick.
        let armSeekPhase = startPosition > 0.5 || isSeekReopen
        pendingSeekTarget = armSeekPhase ? startPosition : nil
        settlePendingSeekCompletion(false, reason: "superseded by load()")
        seekLanded = pendingSeekTarget != nil
        // The open IS the seek issue for an armed load — without this stamp
        // the visible probe's wall bound (and the settle extrapolation, if it
        // were ever consulted for an already-landed open) would read the
        // PREVIOUS seek's time and disarm a reopen's probe on its first event.
        if armSeekPhase { seekIssuedAt = CACurrentMediaTime() }
        // Fresh Media = fresh counters, so a seek-reopen's visible baseline is
        // 0: the first picture the NEW media displays is the mark. Any other
        // load disarms the probe. Same Debug Logging gate as the seek() arm.
        seekVisibleBaseline = (isSeekReopen && PlayerLog.isEnabled) ? 0 : nil
        // Cold-start visible-frame probe. `first-clock-tick` is a PROXY for the
        // frame (StartupTrace says so in its own doc); this measures the frame.
        // Fresh Media = fresh counters, so the baseline is 0 and the first
        // increment is the first picture this load presented. Armed only when a
        // screen-initiated session is open — internal reloads (CDN switch,
        // quality switch, recovery) carry no token and cost one nil-check.
        startupVisibleBaseline = (startupTraceToken != nil && PlayerLog.isEnabled) ? 0 : nil
        startupVisibleArmedAt = CACurrentMediaTime()

        startEventLoop(traceToken: startupTraceToken)

        PlayerLog.log("[VLC] load: hw=\(hardwareDecode), caching=\(cachingMs)ms, startPos=\(String(format: "%.1f", startPosition))s")
        StartupTrace.mark("vlc-open-started", token: startupTraceToken)
        SeekTrace.mark("vlc-open-started")

        do {
            try player.play(media)
        } catch {
            onStateChanged?(.error(error))
            return
        }
        // The one blind spot in the VLC trace, and it is not small: `play` is
        // synchronous on the main actor, and once a drawable has ever been
        // hosted SwiftVLC rebuilds the native media player inside it —
        // `libvlc_media_player_new`, ~60 carried-over property transfers, and
        // 35 event detach/attach pairs, where detach BLOCKS on in-flight libVLC
        // callbacks (SwiftVLC says so) at exactly the moment the outgoing
        // input's stop events are draining. Everything after this point is
        // libVLC-internal and shows up as `vlc-opening`; everything before it
        // was already bracketed. This mark is what separates "our open call is
        // slow" from "libVLC's demux/bank is slow", so the network-caching
        // question can be settled from a device log instead of assumed.
        StartupTrace.mark("vlc-play-returned", token: startupTraceToken)

        // A `:start-time` open IS a seek onto a possibly-dead host — guard it
        // exactly as seek() guards its target, or a stalled reopen (net=0)
        // leaves pendingSeekTarget set forever and deadlocks the recovery
        // ladder (see startSeekSilenceWatchdog).
        if pendingSeekTarget != nil {
            startSeekSilenceWatchdog(targetForLog: startPosition, context: "open-at-position")
        }

        if playbackRate != 1.0 {
            try? player.setPlaybackRate(PlaybackRate(playbackRate))
        }
    }

    /// libVLC sessions are NOT parked, and this is a declaration rather than
    /// an inherited default (the protocol has none — see `PlayerBackend`).
    ///
    /// It is not an oversight and not laziness. Parking means keeping the
    /// demuxer and decoders built so re-entry skips `open()`, which for libVLC
    /// means pausing the input instead of stopping it — and a paused libVLC
    /// input keeps its HTTP connection. Against a BiliBili playurl that is a
    /// signed URL with a `deadline=` and an origin that drops idle sockets, so
    /// the failure mode of a 90s park is an input that reports itself alive and
    /// delivers nothing on resume: strictly worse than the cold open it
    /// replaced, and indistinguishable from it at the call site, which only
    /// reads this Bool. Demand can park because its session owns its own
    /// ranged-HTTP requests and retires them explicitly.
    ///
    /// So the honest state of warm re-entry is: implemented for the opt-in
    /// engine, absent on the product default. Closing that needs a resume-time
    /// liveness check inside this backend, not a `true` here.
    func parkForReuse() -> Bool { false }

    var hasParkedSession: Bool { false }

    func stop() {
        runtimeGeneration &+= 1
        PlayerLog.log("[VLC] stop() called, state=\(player.state)")
        eventTask?.cancel()
        eventTask = nil
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        pendingSeekTarget = nil
        settlePendingSeekCompletion(false, reason: "stop()")
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
            // Only a truly stopped/idle player needs a fresh play() to
            // re-open the pipeline. Calling play() during .buffering would
            // needlessly restart an already-running open and re-buffer.
            try? player.play()
        default:
            // paused → resume; playing/opening/buffering → resume() reconciles
            // the intent flag and cancels any in-flight pause WITHOUT
            // restarting. Branching on the lagging `state` (e.g. `.playing`
            // right after a pause whose stop hasn't landed) would otherwise
            // drop the resume.
            player.resume()
        }
    }

    func pause() {
        PlayerLog.log("[VLC] pause() called, state=\(player.state)")
        player.pause()
    }

    func seek(to time: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?) {
        PlayerLog.log("[VLC] seek(to: \(String(format: "%.1f", time))) called, state=\(player.state)")
        // Cancel any previous pending seek.
        seekTimeoutTask?.cancel()
        pendingSeekCompletion?(false)

        // pendingSeekTarget is assigned below, once `time` has been clamped into
        // the media's real range — the settle check compares it against the real
        // clock, so an unreachable target would never settle.
        pendingSeekCompletion = completion
        // Visible-frame probe for the in-place path: same media, continuing
        // counters — baseline is the count at issue, and the first increment
        // is the first post-flush picture. (One already-in-flight pre-seek
        // picture can land after this line and fire the mark a frame early —
        // the proxy's documented caveat.) A nil statistics read leaves the
        // probe disarmed: visible reports n/a rather than a fabricated 0.
        // Armed BEFORE the issue stamp so the arm's own libVLC crossing is
        // not counted inside the settle it instruments; gated on Debug
        // Logging like the rest of the trace — the probe is its costly part.
        seekVisibleBaseline = PlayerLog.isEnabled ? player.statistics?.displayedPictures : nil
        seekIssuedAt = CACurrentMediaTime()
        seekFromTime = lastTickTime
        seekLanded = false

        // libVLC's three time coordinates do NOT agree when the media was opened
        // with `:start-time` (design doc F13):
        //   - the reported clock is ABSOLUTE (never adjusted by i_start)
        //   - `length` is RELATIVE       (input_GetItemDuration: duration -= i_start)
        //   - `set_time` is RELATIVE     (ControlSetTime: demux_SetTime(i_start + val))
        //   - `set_position` is a RELATIVE fraction of [start, end]
        // `time` here is absolute, like every other position in this app. Convert
        // once, and clamp in the coordinate each API actually wants.
        //
        // `player.seek(to:)` is STRICT: it throws when the media is not yet
        // seekable or the target exceeds a known duration. Fall back to a lenient
        // best-effort seek so recovery/resume never silently fails on a boundary
        // target.
        let playerTotal = player.duration?.timeInterval ?? 0   // relative
        let absTotal = playerTotal > 0 ? playerTotal + loadStartOffset : 0
        let absTarget = absTotal > 0
            ? min(max(loadStartOffset, time), absTotal - Self.endOfMediaSeekReserve)
            : max(loadStartOffset, time)
        // Seeking before the position the demuxer opened at is not expressible:
        // set_time adds i_start, so a negative relative value clamps to the open
        // position. Reaching it needs a reload — the ViewModel's job, not ours.
        if time < loadStartOffset - 0.5 {
            PlayerLog.log("[VLC] ⚠️ seek to \(String(format: "%.1f", time))s precedes the demuxer's open position (\(String(format: "%.1f", loadStartOffset))s) — clamped; a reload is required to go earlier")
        }
        pendingSeekTarget = absTarget
        let playerTarget = max(0, absTarget - loadStartOffset)  // relative

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

        // Settlement is owned by `.timeChanged`; fail on prolonged progress silence
        // so the ViewModel's recovery ladder can take over without deadlocking in `isSeekInFlight`.
        startSeekSilenceWatchdog(targetForLog: time, context: "seek")
    }

    /// Fail a seek or `:start-time` open that makes no buffering or clock progress
    /// within `seekSilenceTimeout`, clearing `pendingSeekTarget` so recovery unblocks.
    private func startSeekSilenceWatchdog(targetForLog target: TimeInterval, context: String) {
        seekProgressAt = CACurrentMediaTime()
        seekTimeoutTask?.cancel()
        seekTimeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.pendingSeekTarget != nil else { return }
                let silent = CACurrentMediaTime() - self.seekProgressAt
                guard silent >= Self.seekSilenceTimeout else { continue }
                PlayerLog.log("[VLC] ⚠️ \(context) to \(String(format: "%.1f", target)) made no progress for \(Int(silent))s — abandoning as FAILED (clock is at \(String(format: "%.1f", self.lastTickTime)))")
                SeekTrace.abort("silence-\(context)")
                let cb = self.pendingSeekCompletion
                self.pendingSeekTarget = nil
                self.pendingSeekCompletion = nil
                cb?(false)
                return
            }
        }
    }

    /// Settle an in-flight seek's completion when interrupted by `load()`, `stop()`, or a newer `seek()`.
    private func settlePendingSeekCompletion(_ finished: Bool, reason: String) {
        guard let completion = pendingSeekCompletion else { return }
        pendingSeekCompletion = nil
        PlayerLog.log("[VLC] pending seek completion settled \(finished) (\(reason))")
        completion(finished)
    }

    /// Seconds of total silence — no buffering tick, no clock tick — before an
    /// in-flight seek is declared failed.
    private static let seekSilenceTimeout: CFTimeInterval = 8

    var isReadyToPlay: Bool {
        switch player.state {
        case .playing, .paused, .buffering: true
        default: false
        }
    }

    /// What this backend can actually prove about a pipeline that has just been
    /// through a suspension — stated, because the protocol has no default and a
    /// foreground decision must not be made from a verdict no backend produced.
    ///
    /// The honest answer for libVLC is never `.playingWithProducer` or
    /// `.pausedReady`, and that is a property of the engine rather than an
    /// omission here. The evidence a warm resume would need is whether the input
    /// thread still has its socket and whether the decoder still has its
    /// VideoToolbox session, and libVLC exposes neither: `state` reports the
    /// TRANSPORT's intent, not the input's health, so a suspended input against a
    /// signed playurl — `deadline=`, an origin that drops idle sockets — comes
    /// back `.playing` and delivers nothing. This is the same fact that makes
    /// `parkForReuse()` return false, in the same file, for the same reason;
    /// `bufferedContentAhead` returning nil rather than a sticky `bufferFill`
    /// estimate is the third instance of it.
    ///
    /// So this reports WHICH unprovable state it is in, which is what the
    /// `[Lifecycle] foreground retained-health=` line is for, and the coordinator
    /// takes the normal admitted-reload path. Closing this for real means a
    /// resume-time liveness probe inside this backend — a bounded read that
    /// proves bytes still arrive — not a `.playingWithProducer` here.
    var retainedPipelineHealth: RetainedPipelineHealth {
        func verdict(_ reason: RetainedPipelineHealth.Reason) -> RetainedPipelineHealth {
            RetainedPipelineHealth(
                backendGeneration: runtimeGeneration,
                state: .requiresRecovery(reason)
            )
        }
        // Ordered most-terminal first, so the logged reason is the strongest true
        // one rather than whichever check happened to be written first. Only the
        // `state` cases this file already switches on elsewhere are named —
        // `.opening`, `.stopping` and `.error` are `PlayerEvent` cases, not
        // `state` ones, and naming them here would be a guess at another
        // module's enum that `swiftc -parse` cannot check.
        switch player.state {
        case .stopped, .idle:
            // Nothing is retained at all: no input, no decoder, no vout.
            return verdict(.terminal)
        case .buffering:
            // Mid-open — SwiftVLC raises this only out of `.idle`/`.opening`,
            // never out of `.playing`. A callback may still be coming; it is not
            // evidence yet.
            return verdict(.transportNotReady)
        case .playing, .paused:
            // The two states where something IS retained. Whether it still works
            // is what cannot be established — see below.
            break
        default:
            // Whatever SwiftVLC adds is not proof of a survivable pipeline.
            return verdict(.transportNotReady)
        }
        if !hasFiredReady {
            return verdict(.transportNotReady)
        }
        if pendingSeekTarget != nil {
            // An unsettled seek owns the position; a rebind would race it.
            return verdict(.seekInFlight)
        }
        if activeVoutCount == 0 {
            // The drawable is gone — observed on device as the black-PiP case.
            return verdict(.missingResources)
        }
        return verdict(.unverifiedBackend)
    }

    /// Watch the retained pipeline for evidence of forward progress, and answer
    /// with what arrives inside `timeout`.
    ///
    /// This is the resume-time liveness check `parkForReuse` and
    /// `retainedPipelineHealth` both say is the missing piece. It is purely
    /// observational: nothing here starts, seeks, or reopens, so a `false`
    /// verdict costs the caller only the window, and a `true` verdict is a
    /// clock that moved or a picture that was presented — never `state`.
    ///
    /// Two baselines because either can be the one that moves first: on a
    /// backgrounded audio session the clock ticks (~4 Hz) with no new picture
    /// until the vout is re-attached, and on a session whose ticks are still
    /// coalescing a presented picture can land first.
    ///
    /// A transport that does not even claim to be running is refused
    /// immediately — waiting on it could only ever time out, and the caller's
    /// reload is the correct answer for it.
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

    /// Called from the event hook: the events themselves are the evidence.
    private func checkRetainedLiveness() {
        guard retainedLivenessObservation.isObserving else { return }
        retainedLivenessObservation.observe(
            generation: runtimeGeneration,
            tick: lastTickTime,
            pictures: player.statistics?.displayedPictures
        )
    }

    var isPlaying: Bool {
        // Intent-based: true from the moment playback is requested (survives
        // the pre-frame buffering window and the one-turn `state` lag).
        player.isPlaying
    }

    // MARK: - Properties

    var currentTime: TimeInterval {
        player.currentTime.timeInterval
    }

    var openedAtPosition: TimeInterval { loadStartOffset }

    var duration: TimeInterval {
        // libVLC's length is relative to `:start-time` — see loadStartOffset.
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

    /// Not measurable on this backend.
    ///
    /// libVLC exposes no content-seconds runway. The only buffer signal is
    /// `bufferFill`, a cache-fill percentage SwiftVLC writes in exactly three
    /// places — `= 0` on stop, `= pct` on a buffering event, `= 0` on media
    /// change (`Player+Events.swift:81,146,292`). It is therefore STICKY: once
    /// the opening fill completes libVLC emits no further buffering event, so it
    /// sits at 1.0 for the life of the load. A local file's cache fills from disk
    /// instantly and reads "full" straight through a total freeze; a silently
    /// wedged network demuxer (one that never re-enters buffering) does the same.
    /// Scaling that by a hard-coded horizon produced a runway pinned at exactly
    /// +5.0s while playback was dead — an estimate whose consumers had to know
    /// when not to trust it.
    ///
    /// Unconditionally nil, for network and file inputs alike. What is
    /// untrustworthy is the producer, not the source type; returning nil for one
    /// and an estimate for the other would only move the uncertainty into
    /// whoever reads it. An unavailable measurement is represented as
    /// unavailable — see `hasProvenBufferedRunway` for what consumers do with it.
    var bufferedContentAhead: TimeInterval? { nil }
    /// The pipeline half of an unmeasurable runway is unmeasurable too.
    var bufferedPipelineAhead: TimeInterval? { nil }
    /// libVLC exposes no per-track queue depth at all — the same reason
    /// `bufferedContentAhead` is nil. Not zero.
    var videoDeliveryRunway: TimeInterval? { nil }

    var playbackRate: Float {
        get { player.rate }
        set { try? player.setPlaybackRate(PlaybackRate(newValue)) }
    }

    var volume: Float {
        get { player.volume }
        set { try? player.setAudioVolume(Volume(newValue)) }
    }

    /// Half a second, which is what this backend's own in-place seek has always
    /// clamped to (`seek(to:)`): `player.seek(to:)` is STRICT and throws on a
    /// target at a known duration, so the reserve was real long before it had a
    /// name — it was just stated once, privately, inside a coordinate
    /// conversion, where the ViewModel naming a target could not see it.
    ///
    /// It applies to the reopen path too, and that is the point. Every VOD seek
    /// here reopens the demuxer at the target (`:start-time`), and what libVLC
    /// does opening a 15.3 s file AT 15.3 s is not derivable from source — this
    /// stops the player from asking.
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
            // VLC doesn't support true aspect-ratio-ignoring stretch.
            // .fill (crop-to-fill) is the closest available behavior.
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
        // Do not seed this from `controller.isActive`: it is the raw state
        // proven sticky on device. A lease starts only after a lifecycle event.
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
        // A caller that explicitly dismisses PiP must not leave an old
        // didStart event authoritative while UIKit drains its didStop event.
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

        // SwiftVLC captures this capability when it creates the native drawable.
        // Replace the host so the setting applies before the next background
        // transition, rather than waiting for another app launch.
        stopPiP()
        pipEventTask?.cancel()
        pipEventTask = nil
        let previousHosting = videoHosting
        automaticPiPEnabled = automaticPiP
        continuationHostRevision &+= 1
        videoHosting = Self.makeVideoHosting(
            player: player, startsAutomaticallyFromInline: automaticPiP
        )
        // The replacement has claimed its drawable before old-host cleanup.
        // Exact-owner retirement cannot clear that successor's destination.
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
        // VLC's MediaStatistics doesn't separate audio/video bitrate;
        // demuxBitrate covers both. audioBitrate left at 0.
        return PlayerDynamicStats(
            displayFPS: measuredFPS,
            videoBitrate: Int(stats.demuxBitrate * 8000),
            audioBitrate: 0,
            bytesRead: Int64(stats.readBytes),
            // libVLC's read counter is already input bytes; goodput and the
            // wire figure are the same number on this engine.
            networkBytesReceived: Int64(stats.readBytes)
        )
    }

    func thumbnailAtCurrentTime() async -> UIImage? {
        // The freeze-frame cover comes from VLC's full-size PNG snapshot, which
        // it encodes SYNCHRONOUSLY on this (main) actor — ~247ms at 4K, more at
        // 8K. Taken on every reopen-seek / CDN switch, that is a per-seek
        // main-thread hang that reads as the app "randomly freezing". VLC can't
        // produce a sized snapshot from a hardware (CVPX) source, so above
        // 1080p SKIP the cover entirely: a brief black flash across the demuxer
        // reopen is far better than freezing the UI for a quarter-second-plus.
        // (A full fix — capturing off-thread — needs SwiftVLC's snapshot to be
        // callable off the main actor; verify on-device before doing that.)
        if let size = videoTracks().first?.naturalSize,
           size.width * size.height > 1920 * 1080 {
            PlayerLog.log("[VLC] snapshot skipped (\(Int(size.width))×\(Int(size.height)) > 1080p — avoids main-thread PNG-encode hang)")
            return nil
        }
        let path = NSTemporaryDirectory() + "vlc_snap_\(ProcessInfo.processInfo.globallyUniqueString).png"
        do {
            // Full size (0×0), NOT a 720p cap. A sized snapshot makes VLC build
            // a resize converter, which it cannot do from a CVPX (hardware-
            // decoded) source — "Failed to convert image for snapshot" — so it
            // silently yields nil and every reopen flashes black (device
            // 2026-07). The full-size cvpx→NV12→RV24 chain works. Encoding a 4K
            // PNG on-thread costs ~247ms — a one-off per 4K seek, and far better
            // than no cover at all. (Proper down-scaling would have to happen
            // AFTER capture, in Swift, not via VLC's resize — a follow-up.)
            try player.takeSnapshot(to: path)
            // Move the (potentially large) PNG file read off the main actor.
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
        // Consume the UNBOUNDED stream so one-shot transitions (the first
        // .playing, bufferingProgress, endReached, error) are never dropped
        // under a main-actor stall — the default `.newest(64)` stream is lossy
        // and could silently drop the very event that signals readiness.
        // Filter out the high-frequency positionChanged firehose so the
        // unbounded buffer stays bounded in practice.
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
        // The event stream can yield one queued callback after stop(). Fence
        // it before touching either player state or the request-owned startup
        // trace; otherwise an old same-owner open can stamp a successor.
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
                // .playing means libVLC's pipeline is running; with the
                // on-screen native drawable attached, frames are rendering.
                // Fire readyToPlay once here — off the lossless state
                // transition, not a bufferingProgress(1.0) value libVLC may
                // never emit.
                if !hasFiredReady {
                    hasFiredReady = true
                    StartupTrace.mark("ready-to-play", token: traceToken)
                    SeekTrace.mark("ready-to-play")
                    onStateChanged?(.readyToPlay)
                }
                // A settling seek keeps buffering until it confirms arrival;
                // otherwise .playing ends the buffering phase.
                if pendingSeekTarget == nil {
                    onStateChanged?(.bufferFinished)
                }
            case .paused:
                onStateChanged?(.paused)
            case .stopped, .stopping, .idle:
                break
            case .error:
                onStateChanged?(.error(VLCError.playbackFailed(reason: "Playback error")))
            }

        case .bufferingProgress(let fill):
            StartupTrace.mark("first-buffering-progress", token: traceToken)
            SeekTrace.mark("first-buffering-progress")
            checkSeekVisibleFrame()
            checkStartupVisibleFrame()
            checkRetainedLiveness()
            // The seek is alive: libVLC is filling at the new position.
            if pendingSeekTarget != nil { seekProgressAt = CACurrentMediaTime() }
            if fill >= 1.0 {
                PlayerLog.log("[VLC] event: bufferingProgress(1.0) — buffer full")
                // Secondary readiness trigger in case .playing was missed.
                if !hasFiredReady {
                    hasFiredReady = true
                    onStateChanged?(.readyToPlay)
                }
                // Seek settlement does NOT belong here. The buffer fills at the
                // stream's LANDING fragment, which for a DASH split stream is
                // seconds short of the target — settling here reported arrival
                // ~7.5s early, which closed the false-EOF suppression window
                // and rubber-banded the progress bar. Settlement now happens in
                // `.timeChanged`, when the real clock reaches the target.
                //
                // A full buffer while a seek is still travelling is not the end
                // of buffering either: the player has data, but not yet at the
                // position the user asked for.
                if pendingSeekTarget == nil {
                    onStateChanged?(.bufferFinished)
                }
            } else {
                PlayerLog.log("[VLC] event: bufferingProgress(\(String(format: "%.0f%%", fill * 100)))")
                // `onBufferChanged` carries the DELIVERY RUNWAY, and this backend
                // cannot measure one (`bufferedContentAhead`, nil). It published
                // `fill × 5s` here — the (since deleted) availability
                // estimate under the runway's name — and because libVLC raises
                // `bufferingProgress` only while opening, the stats overlay then
                // showed that opening fill, frozen, for the whole load while the
                // same build logged `buf=n/a`. Publish nothing; unknown is a
                // legitimate answer and the row renders as absent.
            }

        case .timeChanged(let time):
            checkSeekVisibleFrame()
            checkStartupVisibleFrame()
            checkRetainedLiveness()
            let t = time.timeInterval
            verifyStartPosition(against: t)
            // A moving clock is progress too — a small in-buffer seek settles
            // without any buffering cycle at all.
            if pendingSeekTarget != nil, t != lastTickTime { seekProgressAt = CACurrentMediaTime() }
            lastTickTime = t
            // Where the reopened stream's clock actually came up — libVLC lands on
            // a fragment boundary, which for split DASH is short of the target, so
            // this is the origin of the `run-up` the settle below completes.
            SeekTrace.markFirstTick(landedAt: t)
            settlePendingSeekIfArrived(at: t)
            // Ultimate readiness fallback: an advancing clock means playback
            // is underway even if the .playing/buffering signals were missed
            // (e.g. dropped one-shot events). Fire readyToPlay once here too.
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
                // Swallow fragment EOF mid-seek; real arrival (`timeChanged`) or silence timeout settles it.
                PlayerLog.log("[VLC] event: endReached SWALLOWED (seek pending → false EOF)")
            } else if lastKnownDuration > 0, lastKnownDuration - lastTickTime > 5 {
                // libVLC 4 collapses a natural end and a premature input
                // termination into the same `stopped`, and SwiftVLC synthesizes
                // `endReached` for any `stopped` that no error accounts for.
                // A stop this far from the end is a DEAD INPUT (idle-closed
                // connection, truncated stream), not end-of-media. Surface it
                // as a failure so recovery resumes in place — reporting
                // playedToTheEnd here marks the video watched and restarts it
                // from 0:00.
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
            // High-frequency — don't log to avoid spam.
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

    /// Settles a pending seek when the REAL clock reaches the target.
    ///
    /// Buffer-fill cannot be used: it fires at the landing fragment, seconds
    /// short of the target. `player.currentTime` cannot be used either — it is
    /// stamped to the target synchronously by SwiftVLC's `seek()`. Only
    /// `timeChanged` carries the truth.
    ///
    /// `seekLanded` rejects stale in-flight ticks from the pre-seek position:
    /// a BACKWARD seek's leftover ticks arrive far AHEAD of the target and
    /// would otherwise satisfy `t >= target` instantly. A tick only counts as
    /// the landing once it diverges from where the old clock would have been
    /// had the seek never happened.
    /// `:start-time=X` is a request, not a guarantee. A host that refuses ranged
    /// requests — observed answering `412 Precondition Failed` to libVLC's
    /// `If-Match` revalidation, three times — makes the demuxer's seek fail
    /// (`INPUT_CONTROL_SET_TIME @0 failed or not possible`) and it opens at 0.
    /// libVLC reports this only as a warning; the media plays, from the wrong
    /// place.
    ///
    /// The clock is absolute (design doc F13), so a stream opened at 58.9s
    /// cannot tick 1.4s. That makes this a FACT, not a heuristic. And the target
    /// is unreachable on this host: `set_time` is start-relative, so seeking
    /// there again re-issues the byte range the host just refused. Only a
    /// different host can serve it — so surface a failure and let §2.5's ladder
    /// move us, rather than sitting muted behind a spinner for the ~57s it would
    /// take the clock to crawl to the target.
    /// DIAGNOSTIC ONLY. Notes, once per load, if a `:start-time` open landed far
    /// from where it was asked to — the F15/412 symptom. It does NOT act: an
    /// earlier version raised `.error` here, which fed a host-avoidance cascade
    /// that broke playback on every CDN whose first post-open tick was briefly
    /// low. The real fix is `patches/libvlc/0005` (retry the range without the
    /// precondition), which is CDN-agnostic. If this line ever prints with 0005
    /// in the build, 0005 regressed — otherwise it is only an observation.
    private func verifyStartPosition(against t: TimeInterval) {
        guard !startPositionChecked, loadStartOffset > 0.5 else { return }
        startPositionChecked = true
        guard t < loadStartOffset - 5 else { return }
        PlayerLog.log("[VLC] ⚠️ opened at \(String(format: "%.1f", t))s but asked for \(String(format: "%.1f", loadStartOffset))s — :start-time may have been refused (F15; 0005 should prevent this)")
    }

    /// The visible-frame probe's sampler: while armed, compare the live
    /// displayed-picture counter against the at-issue baseline; the first
    /// increment is the first rendered post-seek picture and fires the trace
    /// mark once. Costs a `player.statistics` fetch per event ONLY while a
    /// seek is being measured — disarmed, it is one nil-check.
    /// Startup's visible-frame probe. Same shape and same cost model as the
    /// seek probe below: one nil-check when disarmed, one `player.statistics`
    /// fetch per event while measuring, and it disarms itself on the first
    /// increment (or a wall bound, so a start that is backgrounded before any
    /// picture cannot keep sampling for the whole session).
    ///
    /// The counter is the vout's own: libVLC increments `displayedPictures`
    /// when a picture is put on screen, which is the one signal on this backend
    /// that is neither readiness, nor the clock, nor a decode.
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
        // Scoped to the session it measures: a session that closed (or a
        // restore reopen that never opened one) disarms the probe on the
        // first event, so a stale baseline can never fire a mark into a
        // different seek's numbers — and the per-event statistics crossing
        // stops with it.
        guard SeekTrace.wantsVisibleFrame else {
            seekVisibleBaseline = nil
            return
        }
        // Wall bound: a settled seek backgrounded before any picture keeps
        // ticking on audio with a frozen picture counter — without this the
        // probe (and its epilogue) would stay armed for the whole background
        // session.
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
            // Diverged from continued pre-seek playback, or a small in-buffer
            // seek that simply never diverges but is already at the target.
            if abs(t - extrapolatedOld) > 1.0 || (elapsed > 1.0 && abs(t - target) < 1.0) {
                seekLanded = true
            }
        }
        guard seekLanded, t >= target - 0.5 else { return }

        PlayerLog.log("[VLC] seek settled: real clock \(String(format: "%.2f", t))s reached target \(String(format: "%.2f", target))s")
        // The settle IS the end of a seek session — this is the point where the
        // player stops treating the seek as in flight. A `:start-time` resume open
        // settles here too and has no session, so this is a no-op for it.
        SeekTrace.mark("arrived")
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        let cb = pendingSeekCompletion
        pendingSeekTarget = nil
        pendingSeekCompletion = nil
        cb?(true)
    }

    private func updateFPS() {
        // Gate before the statistics fetch: this is called on every ~30Hz
        // timeChanged event, and `player.statistics` crosses into libVLC —
        // only pay for it on the ≥1s samples that actually recompute.
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

    /// See `PlayerBackend.invalidateFrameStats`. Anchors the picture counter at
    /// the current value so the next ≥1s sample only counts **new** frames —
    /// pre-background sticky `measuredFPS` cannot survive into a foreground
    /// liveness check.
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


/// Nonisolated home for the process libVLC instance.
///
/// It exists so the instance can be built from a detached task at app launch.
/// `VLCInstance` is `Sendable` (SwiftVLC declares it so, and this file already
/// handed one to a detached log consumer), and a `static let` on a nonisolated
/// enum needs no isolation annotation at all — which is a materially safer
/// shape than marking a stored static on a `@MainActor` class `nonisolated`.
///
/// Verbosity is decided HERE, once, when the instance is built. That was always
/// true (`--verbose` is an instance argument, not a media option) but it now
/// happens at LAUNCH rather than at the first video, which has a useful
/// side effect for measurement: toggling Settings → Diagnostic Logging later in
/// the session no longer puts libVLC at debug verbosity, so a `ttff-measured`
/// number taken after the toggle is not paying for hundreds of forwarded log
/// lines during the open. See `StartupTrace`.
// libVLC's own verbosity follows Settings → Playback → Debug Logging (the
// single gate PlayerLog documents). Diagnostics ON → `--verbose=2` (debug),
// whose messages are routed into PlayerLog by startVLCLogForwarding() —
// subscribing installs libVLC's log callback, which supersedes its stderr
// logger, so this does not spam the console directly. Diagnostics OFF →
// `--quiet`, suppressing libVLC's HTTP/2 stream-closed spam.
//
// `--verbose=2` is REQUIRED to see debug/notice messages: libVLC's default
// verbosity is errors-only, so a `.debug` subscription would receive
// nothing. The level is fixed at instance creation — toggling the setting
// takes effect on the next launch.
// No fallback instance: a rejected argument list makes the engine unavailable.
//
// Pitch-corrected engine is an instance argument (opened at `Player()` construction,
// sticky until relaunch). Refuse construction without fallback if `libvlc_new` rejects
// the configured arguments so a stale libvlc slice fails closed rather than crashing.
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
            // Timed, because the whole justification for moving this off the
            // first video's path is that it is expensive — and nothing in the
            // repo has ever priced it. `[VLC] instance …` logs beside it.
            let start = CACurrentMediaTime()
            _ = selection
            PlayerLog.log(
                "[VLC] engine pre-warmed off-main "
                + "(\(Int((CACurrentMediaTime() - start) * 1000))ms)"
            )
        }
    }
}
