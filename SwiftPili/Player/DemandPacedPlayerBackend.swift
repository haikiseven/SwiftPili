import UIKit
import Observation

/// Owns a NotificationCenter token independently from the @MainActor backend.
/// NotificationCenter removal is thread-safe, while `DemandPacedPlayerBackend`
/// may be released by a non-main cache/Task teardown path. Keeping the token in
/// this Sendable owner avoids `MainActor.assumeIsolated` in `deinit`, which can
/// trap when the last backend reference is released off-main.
private final class DemandMemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter) {
        self.center = center
    }

    func install(_ token: NSObjectProtocol) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    deinit {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token {
            center.removeObserver(token)
        }
    }
}

/// Thin `PlayerBackend` adapter over `MediaEngineSession`.
///
/// **No demux/decode details here** — only maps load/play/seek/rate ↔ session
/// and session events ↔ `PlayerStateEvent`. Swap FFmpeg/VT implementations
/// under the session without touching this file or ViewModel.
///
/// Default `init()` uses the assembly's fail-closed unavailable session.
/// The product path injects `DemandMediaEngineAssembly.makeDemandBringUp()`
/// via `PlayerBackendFactory`.
@MainActor
@Observable
final class DemandPacedPlayerBackend: PlayerBackend {

    private struct SeekRequest {
        let serial: UInt64
        let target: TimeInterval
        let completion: (@MainActor @Sendable (Bool) -> Void)?
        let nativePiPRequest: EnginePiPSeekRequest?
    }

    private struct RuntimeFaultDeliveryKey: Equatable {
        let ownerGeneration: UInt64
        let sessionGeneration: UInt64
        let ownerLeaseGeneration: UInt64
    }

    private let session: MediaEngineSession
    private var scaleMode: VideoScaleMode = .fit
    /// Single-slot parked-session cache: at most ONE parked ticket, and it is
    /// always THIS backend's one session (never a second decoder pipeline).
    private var parkedTicket: ParkedPlaybackTicket?
    private var parkTTLTask: Task<Void, Never>?
    private let memoryPressureObserver: DemandMemoryPressureObserver
    /// Identity of the most recent load, park's reuse key. Path-canonical +
    /// load-shaping params — see ParkedPlaybackTicket.identity.
    private var lastLoadIdentity: String?
    private static let parkTTL: Duration = .seconds(90)
    /// Temporary bring-up cap (content seconds) on packet HWM.
    /// Architecture targets 15–30s compressed reservoirs; pass-through BGRA
    /// retain + jetsam forces a lower ceiling until A2b compressed/VT lands.
    /// Do not treat this as the final Path A product buffer depth.
    private static let demandBringUpPacketHWMCap: TimeInterval = 8

    private(set) var isReadyToPlay = false
    private(set) var runtimeGeneration: UInt64 = 0
    private var startupTraceToken: StartupTrace.Token?
    /// Complete continuation snapshot last applied by the factory/ViewModel.
    /// Directly-constructed test backends fail closed until they receive one.
    private(set) var playbackContinuationConfiguration = PlaybackContinuationConfiguration(
        backgroundAudioEnabled: false,
        pictureInPictureEnabled: false
    )
    private(set) var hasObservedPiPLease = false
    private var observedPiPLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var pipTransportEdgeHandler:
        (@MainActor @Sendable (PlayerBackendPiPTransportEdge) -> Void)?
    private var runtimeFaultHandler: (@MainActor @Sendable (MediaRuntimeFault) -> Void)?
    private var deliveredRuntimeFault: RuntimeFaultDeliveryKey?
    /// Retain and cancel the backend-owned open task so a stopped/replaced
    /// owner does not keep an unstructured session call alive unnecessarily.
    /// MediaEngineSession also fences the operation at its serial lifecycle
    /// barrier; this handle closes the outer backend ownership loop.
    private var openTask: Task<Void, Never>?
    /// Prevent a stale control callback from reviving a session after a
    /// terminal open failure. A fresh `load` is the only reset point.
    private var terminalFailure = false
    /// Playback-report bookkeeping only: names the `.buffering`/`.playing`
    /// edges as enter/exit lines so a freeze is legible in the captured ring.
    private var debugReportWasBuffering = false
    /// VLC's `load()` auto-plays internally, so the ViewModel drives playback on
    /// the "load ⇒ transport already running" assumption and never issues an
    /// explicit play() on the ready path. The Demand session does NOT auto-play on
    /// open, so without this the session sat opened-but-never-played: mediaTime
    /// frozen at 0, audio pull never started (device 2026-07-22). Track the play
    /// intent and start the session the moment it is ready.
    private var wantsPlaybackWhenReady = false
    private(set) var isPlaying = false
    var retainedPipelineHealth: RetainedPipelineHealth {
        session.retainedPipelineHealth(backendGeneration: runtimeGeneration)
    }

    /// Demand needs no observation window: it owns its producers, so the
    /// projection it already publishes IS the proof — a live supply loop, a
    /// running audio graph, open decoders, no fault, no seek in flight, all for
    /// the current generation. Answering synchronously keeps the foreground path
    /// exactly as fast as it was and deliberately does NOT introduce a second
    /// liveness mechanism for this engine.
    ///
    /// `timeout` is unused rather than slept through: a window this backend does
    /// not need is a window the user waits for.
    func confirmRetainedLiveness(within _: TimeInterval) async -> Bool {
        let health = session.retainedPipelineHealth(backendGeneration: runtimeGeneration)
        let alive = health.state == .playingWithProducer
        PlayerLog.log(
            "[PathA] retained-liveness \(alive ? "ALIVE" : "dead") " +
            "state=\(String(describing: health.state)) (synchronous projection)"
        )
        return alive
    }
    private(set) var pendingSeekTarget: TimeInterval?
    private(set) var openedAtPosition: TimeInterval = 0
    /// Interactive seeks are latest-wins, but `MediaEngineSession.seek` must not
    /// overlap itself: an older prime can otherwise keep the demux actor busy
    /// while a newer seek observes the shared fill guard and resumes with empty
    /// or stale queues. One worker serializes session calls; newer UI requests
    /// replace the single queued request.
    private var seekSerial: UInt64 = 0
    private var seekEpoch: UInt64 = 0
    private var queuedSeekRequest: SeekRequest?
    private var seekWorkerTask: Task<Void, Never>?
    private var nextSeekWorkerID: UInt64 = 0
    private var activeSeekWorkerID: UInt64?
    /// Preparation currently owned by the worker. A newer request aborts this
    /// private transaction before the renderer can acknowledge its epoch.
    private var activePreparedSeek: MediaEngineSeekPreparation?

    /// Bounded seek trace. The record is intentionally numeric/enum-only so it
    /// can correlate a device reproduction without carrying source data or
    /// native error strings across the backend boundary.
    private func logSeekTrace(
        phase: String,
        serial: UInt64? = nil,
        target: TimeInterval? = nil,
        token: MediaAudioSeekToken? = nil,
        ready: Bool? = nil,
        result: Bool? = nil
    ) {
        let rawTarget = target ?? pendingSeekTarget ?? 0
        let safeTarget = rawTarget.isFinite ? rawTarget : 0
        let rawPending = pendingSeekTarget ?? -1
        let safePending = rawPending.isFinite ? rawPending : -1
        let readyValue = ready.map { $0 ? 1 : 0 } ?? -1
        let resultValue = result.map { $0 ? 1 : 0 } ?? -1
        PlayerLog.log(
            "[PathASeekBackend] phase=\(phase) serial=\(serial ?? seekSerial) " +
            "seekEpoch=\(seekEpoch) target=\(String(format: "%.3f", safeTarget)) " +
            "tokenGen=\(token?.generation ?? 0) ready=\(readyValue) result=\(resultValue) " +
            "sessionGen=\(session.runtimeGeneration) backendGen=\(runtimeGeneration) " +
            "pending=\(String(format: "%.3f", safePending))"
        )
    }

    var equalizerConfiguration: PlayerEqualizerConfiguration {
        get { session.equalizerConfiguration }
        set { session.equalizerConfiguration = newValue }
    }
    var equalizerStatus: PlayerEqualizerStatus { session.equalizerStatus }
    var videoEnhancementConfiguration: VideoEnhancementConfiguration {
        get { session.videoEnhancementConfiguration }
        set { session.videoEnhancementConfiguration = newValue }
    }
    var videoEnhancementTelemetry: VideoEnhancementTelemetry {
        session.videoEnhancementTelemetry
    }
    var audioMaintenanceAdmission: (@MainActor () -> AudioMaintenancePermit?)? {
        get { session.audioMaintenanceAdmission }
        set { session.audioMaintenanceAdmission = newValue }
    }
    func revokeAudioMaintenancePermission() { session.revokeAudioMaintenancePermission() }

    var playbackRate: Float {
        get { session.playbackRate }
        set { session.playbackRate = newValue }
    }

    var volume: Float = 1.0 {
        didSet { session.setAudioVolume(volume) }
    }

    /// The session's OWN seek-priming requirement, not a second number that
    /// happens to look like it: `SeekPrimingPolicy` refuses to launch until this
    /// much PCM sits past the target, and the audio renderer refuses the
    /// transition below it, so a ceiling derived from anything else would drift
    /// from the thing it exists to satisfy. Zero for a session with no audio
    /// track — there is nothing to bank — and it grows with the rate, because
    /// the reserve is denominated in content (0.25 s at 1×, 0.5 s at 2×).
    var seekLaunchReserve: TimeInterval { session.requiredAudioSeekContentSeconds }

    var isMuted = false {
        didSet { session.setAudioMuted(isMuted) }
    }

    var currentTime: TimeInterval { session.mediaTime }
    var duration: TimeInterval { session.duration }
    /// Streaming uses the session's raw delivery estimate. The seekable UI can
    /// use the independently qualified `bufferDisplaySample`. An opened local
    /// file supplies the full duration once its length is known.
    var playableTime: TimeInterval {
        if inputIsLocalFile, duration > 0 { return duration }
        return session.bufferedTime
    }

    var bufferDisplaySample: MediaBufferDisplaySample? {
        inputIsLocalFile ? nil : session.bufferDisplaySample
    }

    /// Set by `load` from the input URL, cleared by `stop`.
    private var inputIsLocalFile = false

    /// Report the binding track's delivery runway for live stats and backend
    /// diagnostics. The seekable Buffer row shares the strip's display range.
    private func publishDeliveryRunway() {
        guard let runway = session.deliveryRunway else { return }
        onBufferChanged?(runway)
    }

    /// A real measurement — content seconds sitting in the packet queues, which
    /// is what the frozen-clock runway veto was designed around: a demand session
    /// that has filled its runway stops fetching, and `net=0` there is
    /// idle-because-full, not starvation.
    ///
    /// F3: this reads `session.deliveryRunway` (the BINDING track) and NOT
    /// `session.bufferedTime`, which it used to derive from. `bufferedTime` is
    /// the availability horizon and returns the AUDIO depth alone once the audio
    /// master exists — so this channel was reporting `+5.1s` of health while the
    /// video queue sat at 0.0s and the picture was frozen. Availability still
    /// answers `playableTime` above; health answers here. Do not re-derive one
    /// from the other.
    var bufferedContentAhead: TimeInterval? { session.deliveryRunway }

    /// The same binding runway without the byte store's contribution — what
    /// the watchdog's frozen-clock veto may trust (see the protocol).
    var bufferedPipelineAhead: TimeInterval? { session.pipelineRunway }

    /// The video half on its own, for diagnostics that must be able to say WHICH
    /// track is short. `bufferedContentAhead` is the minimum and cannot: a
    /// reader seeing a small number there cannot tell a starved picture from a
    /// starved soundtrack, and those have different causes and different fixes.
    var videoDeliveryRunway: TimeInterval? { session.videoDeliveryRunway }

    var renderViewController: UIViewController? { session.videoHost }
    func currentDisplayedFrameForTransition() -> UIImage? {
        session.currentDisplayedFrameForTransition()
    }
    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage? {
        session.currentAmbientSampleImage(targetSize: targetSize)
    }
    var isPiPActive: Bool { session.isPiPActive }
    var demandPresentationSessionGeneration: UInt64 { session.runtimeGeneration }
    var renderedAudioOutputPosition: TimeInterval? {
        session.renderedAudioOutputPosition(ownerGeneration: runtimeGeneration)
    }
    var unresolvedPrimaryTransportFailure: StreamTransportFailure? {
        guard let failure = session.unresolvedPrimaryTransportFailure,
              failure.backendGeneration == runtimeGeneration,
              failure.sessionGeneration == session.runtimeGeneration else { return nil }
        return failure
    }
    var demandPiPBindingGeneration: UInt64 { session.currentPiPBindingGeneration }
    var demandPresentationHealth: DemandPresentationHealth {
        session.demandPresentationHealth
    }

    var onStateChanged: (@MainActor @Sendable (PlayerStateEvent) -> Void)?
    var onTickWithGeneration: (@MainActor @Sendable (TimeInterval, TimeInterval, UInt64, StartupTrace.Token?) -> Void)?
    var onBufferChanged: (@MainActor @Sendable (TimeInterval) -> Void)?

    /// - Parameters:
    ///   - session: Injected engine. Default is the assembly's fail-closed
    ///     unavailable session. Factory passes the product Demand stack.
    ///   - memoryWarningCenter: where the memory warning is observed.
    ///   - byteStore: the process-wide byte store the VOD demuxer reads
    ///     through, emptied on a memory warning; nil under the kill switch.
    init(
        session: MediaEngineSession = DemandMediaEngineAssembly.makeUnavailableSession(),
        memoryWarningCenter: NotificationCenter = .default,
        byteStore: MediaByteRangeStore? = PathAByteCacheSwitch.vodStore
    ) {
        self.session = session
        self.memoryPressureObserver = DemandMemoryPressureObserver(center: memoryWarningCenter)
        self.session.onEvent = { [weak self] event in
            self?.handleSessionEvent(event)
        }
        self.session.onPiPTransportEvent = { [weak self] event in
            self?.handlePiPTransportEvent(event)
        }
        self.session.onPiPSkipRequest = { [weak self] request in
            guard let self else {
                request.finish(success: false)
                return
            }
            self.seekFromPiP(request)
        }
        self.session.setObservedPiPLeaseChangeHandler { [weak self] active in
            self?.updateObservedPiPLease(active)
        }
        // A parked session is a cache: memory pressure evicts it. A live
        // warm-suspended session sheds its compressed video window — the only
        // large, rebuildable background allocation — and stops refetching it.
        // The byte store is a cache too and is emptied whole; the session's
        // cached runway is zeroed once the purge has landed, so it cannot keep
        // claiming bytes that are gone (a later fill re-measures from empty).
        memoryPressureObserver.install(memoryWarningCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let byteStore {
                    let session = self.session
                    Task { @MainActor in
                        await session.cancelMultiConnectionPrefetching()
                        await byteStore.purgeAll()
                        session.resetCachedRunway()
                    }
                }
                self.session.discardSuspendedVideoWindowForMemoryPressure()
                guard self.parkedTicket != nil else { return }
                PlayerLog.log("[PathA] session-park-invalidated (memory pressure)")
                self.discardParkedSession()
            }
        })
        PlayerLog.log("[PathA] DemandPacedPlayerBackend ready")
    }

    func setStartupTraceToken(_ token: StartupTrace.Token?) {
        startupTraceToken = token
    }

    func refreshMultiConnectionTelemetry() { session.refreshMultiConnectionTelemetry() }

    func setMultiConnectionQuiet(_ quiet: MultiConnectionQuiet) {
        session.setMultiConnectionQuiet(quiet)
    }

    private struct PrefetchPolicy {
        let video: Set<String>
        let audio: Set<String>
        let ahead: TimeInterval?
        let multiConnection: MultiConnectionPolicy?
        let accountSession: UUID

        func changes(from previous: Self) -> [String] {
            var fields: [String] = []
            if video != previous.video { fields.append("video") }
            if audio != previous.audio { fields.append("audio") }
            if ahead != previous.ahead { fields.append("ahead") }
            if multiConnection != previous.multiConnection { fields.append("multiConnection") }
            if accountSession != previous.accountSession { fields.append("account-session") }
            return fields
        }
    }
    private var lastPrefetchPolicy: PrefetchPolicy?
    /// One synchronous prepare/load handoff. Never retain selected identities
    /// as session state: a URL-only reopen must remain a bootstrap miss.
    private var pendingBootstrapIdentities:
        (video: MediaBootstrapIdentity?, audio: MediaBootstrapIdentity?)?

    func prepareBootstrapIdentities(
        video: MediaBootstrapIdentity?, audio: MediaBootstrapIdentity?
    ) {
        pendingBootstrapIdentities = (video, audio)
    }

    private func preparePrefetchPolicy(
        video: [URL], audio: [URL], ahead: TimeInterval?, multiConnection: MultiConnectionPolicy?
    ) {
        let policy = PrefetchPolicy(
            video: Set(video.map { ParkedPlaybackTicket.streamIdentity(of: $0) }),
            audio: Set(audio.map { ParkedPlaybackTicket.streamIdentity(of: $0) }),
            ahead: ahead, multiConnection: multiConnection,
            accountSession: AuthManager.shared.sessionGeneration
        )
        if hasParkedSession {
            let changed = lastPrefetchPolicy.map { policy.changes(from: $0) } ?? ["missing-policy"]
            // A compatible claim keeps the original demux readers, helper URLs
            // and host state, so only a real difference retires the park.
            if !changed.isEmpty {
                PlayerLog.log(
                    "[PathA] session-park-invalidated reason=prefetch-policy-changed " +
                        "fields=\(changed.joined(separator: ","))"
                )
                discardParkedSession()
            }
        }
        // Store the live configuration even when it matched: a field that
        // `changes` did not compare must not stay frozen at park time.
        lastPrefetchPolicy = policy
    }

    // MARK: - PlayerBackend

    func load(
        url: URL,
        audioURL: URL?,
        headers: [String: String],
        startPosition: TimeInterval,
        playbackRate: Float,
        hardwareDecode: Bool,
        networkCaching _: TimeInterval,
        maxBuffer: TimeInterval,
        preferNativeVideoToolbox: Bool,
        alternateVideoURLs: [URL] = [],
        alternateAudioURLs: [URL] = [],
        readAheadSeconds: TimeInterval? = nil,
        multiConnectionPolicy: MultiConnectionPolicy? = nil,
        liveSource: DemandLiveSource? = nil
    ) {
        let bootstrapIdentities = takePreparedBootstrapIdentities()
        preparePrefetchPolicy(video: alternateVideoURLs, audio: alternateAudioURLs,
                              ahead: readAheadSeconds, multiConnection: multiConnectionPolicy)

        let identity = ParkedPlaybackTicket.identity(
            videoURL: url,
            audioURL: audioURL,
            hardwareDecode: hardwareDecode,
            preferNativeVideoToolbox: preferNativeVideoToolbox,
            // The OPERATIVE buffer depth: load clamps the HWM to the bring-up
            // cap, so identities fold the clamped value — a 60→120s Preload
            // change must not discard a park whose pipeline is byte-identical.
            maxBuffer: min(maxBuffer, Self.demandBringUpPacketHWMCap)
        )
        lastLoadIdentity = identity
        inputIsLocalFile = url.isFileURL
        // A parked session answering for exactly this playback is claimed in
        // place of the whole open: no open(), no demux rebuild, no decoder
        // bring-up. Anything else falls through to the cold path (the discard
        // inside takeClaimableTicket already tore the stale session down).
        if let ticket = takeClaimableTicket(for: identity) {
            claimParkedSession(
                ticket,
                startPosition: startPosition,
                playbackRate: playbackRate
            )
            return
        }

        runtimeGeneration &+= 1
        deliveredRuntimeFault = nil

        // A source replacement is forced retirement, not an ordinary PiP
        // handoff. Invalidate the old binding/lease synchronously so a delayed
        // native didStop cannot be mistaken for the replacement session.
        session.forceRetirePiP()
        invalidateSeekCoordinator()
        openedAtPosition = max(0, startPosition)
        isReadyToPlay = false
        isPlaying = false
        terminalFailure = false
        debugReportWasBuffering = false
        // Match VLC's load-auto-plays contract: play as soon as the session opens.
        wantsPlaybackWhenReady = true
        pendingSeekTarget = startPosition > 0.5 ? startPosition : nil

        let rawHWM = max(maxBuffer, 2)
        let hwm = min(rawHWM, Self.demandBringUpPacketHWMCap)
        if rawHWM > hwm + 0.5 {
            PlayerLog.log(
                "[PathA] cap packet HWM \(String(format: "%.0f", rawHWM))s → " +
                "\(String(format: "%.0f", hwm))s (pass-through memory)"
            )
        }
        var request = MediaOpenRequest(
            videoURL: url,
            audioURL: audioURL,
            headers: headers,
            startPosition: startPosition,
            preferredRate: playbackRate,
            packetQueueHighWater: hwm,
            preferHardwareVideo: hardwareDecode || preferNativeVideoToolbox,
            ownerGeneration: runtimeGeneration,
            startupTraceToken: startupTraceToken?.mediaEngineTraceID,
            liveSource: liveSource,
            alternateVideoURLs: alternateVideoURLs, alternateAudioURLs: alternateAudioURLs,
            readAheadSeconds: readAheadSeconds, multiConnectionPolicy: multiConnectionPolicy
        )
        applyBootstrapIdentities(bootstrapIdentities, to: &request)

        openTask?.cancel()
        openTask = Task { @MainActor [weak self, loadGeneration = runtimeGeneration] in
            guard let self else { return }
            await self.session.open(request)
            if self.runtimeGeneration == loadGeneration {
                self.openTask = nil
            }
        }
    }

    var hasParkedSession: Bool { parkedTicket != nil }

    private func takePreparedBootstrapIdentities()
        -> (video: MediaBootstrapIdentity?, audio: MediaBootstrapIdentity?)? {
        let identities = pendingBootstrapIdentities
        pendingBootstrapIdentities = nil
        return identities
    }

    private func applyBootstrapIdentities(
        _ identities: (video: MediaBootstrapIdentity?, audio: MediaBootstrapIdentity?)?,
        to request: inout MediaOpenRequest
    ) {
        guard request.videoURL.scheme == "https" || request.videoURL.scheme == "http" else { return }
        if identities?.video?.track == .video { request.videoBootstrapIdentity = identities?.video }
        if let audioURL = request.audioURL, audioURL.scheme == "https" || audioURL.scheme == "http",
           identities?.audio?.track == .audio {
            request.audioBootstrapIdentity = identities?.audio
        }
    }

    /// Park the session for a short-TTL same-content reuse instead of tearing
    /// it down. Synchronous, so the owner-exit path can decide teardown vs
    /// park in one place. Refusal (an open still in flight, no load identity,
    /// terminal failure, the session declines) means the caller performs its
    /// normal stop. `load` stamps `lastLoadIdentity` before `session.open`
    /// resets the clock, and cancelling `openTask` does not cancel that open —
    /// parking here would ticket the new URL at the previous item's media time.
    func parkForReuse() -> Bool {
        pendingBootstrapIdentities = nil
        guard openTask == nil,
              let identity = lastLoadIdentity,
              lastPrefetchPolicy?.accountSession == AuthManager.shared.sessionGeneration,
              !terminalFailure,
              parkedTicket == nil,
              session.parkForReuse() else {
            return false
        }
        runtimeGeneration &+= 1
        deliveredRuntimeFault = nil
        openTask?.cancel()
        openTask = nil
        session.forceRetirePiP()
        invalidateSeekCoordinator()
        isReadyToPlay = false
        isPlaying = false
        wantsPlaybackWhenReady = false
        pendingSeekTarget = nil
        let ticket = ParkedPlaybackTicket(
            identity: identity,
            position: session.mediaTime,
            parkedAt: .now
        )
        parkedTicket = ticket
        PlayerLog.log(
            "[PathA] session-park position=\(String(format: "%.2f", ticket.position)) " +
            "ttl=\(Self.parkTTL.components.seconds)s"
        )
        parkTTLTask?.cancel()
        parkTTLTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.parkTTL)
            guard !Task.isCancelled, let self, self.parkedTicket == ticket else { return }
            PlayerLog.log("[PathA] session-park-expired position=\(String(format: "%.2f", ticket.position))")
            self.discardParkedSession()
        }
        return true
    }

    /// Consume the parked ticket when it answers for `identity`; otherwise
    /// discard it (with the reason logged) so the cold path starts clean.
    private func takeClaimableTicket(for identity: String) -> ParkedPlaybackTicket? {
        guard let ticket = parkedTicket else { return nil }
        switch ticket.decision(for: identity, now: .now, ttl: Self.parkTTL) {
        case .claim:
            // A fault published DURING the parked window (a surviving decode/
            // pump continuation) fails the session but cannot invalidate the
            // ticket by itself — claiming it would synthesize readyToPlay
            // over a session whose play() refuses. Fall back to a cold open.
            guard session.isReady else {
                PlayerLog.log("[PathA] session-park-invalidated (session faulted while parked)")
                discardParkedSession()
                return nil
            }
            parkedTicket = nil
            parkTTLTask?.cancel()
            parkTTLTask = nil
            return ticket
        case .expiredTTL:
            PlayerLog.log("[PathA] session-park-expired (at claim) position=\(String(format: "%.2f", ticket.position))")
            discardParkedSession()
            return nil
        case .identityMismatch:
            PlayerLog.log("[PathA] session-park-invalidated (different content)")
            discardParkedSession()
            return nil
        }
    }

    /// Full teardown of the parked session — expiry, memory pressure, or an
    /// incompatible claim. After this the next load is an ordinary cold open.
    private func discardParkedSession() {
        parkedTicket = nil
        parkTTLTask?.cancel()
        parkTTLTask = nil
        session.stop()
    }

    /// Resume the parked session as this load's result: synthesize the ready
    /// transition the cold path would get from `.ready`, then auto-play. The
    /// parked audio graph restarts on its reuse fast path, pending frames
    /// present immediately, and the supply loop's pump reopens its streams at
    /// the committed sample/byte boundary.
    private func claimParkedSession(
        _ ticket: ParkedPlaybackTicket,
        startPosition: TimeInterval,
        playbackRate: Float
    ) {
        runtimeGeneration &+= 1
        deliveredRuntimeFault = nil
        terminalFailure = false
        debugReportWasBuffering = false
        openTask?.cancel()
        openTask = nil
        invalidateSeekCoordinator()
        // The claimed session sits at the parked position — that IS where this
        // "load" opened. The ViewModel's loaded-at-target logic then skips the
        // restore seek whenever its resume point matches (it does: the exit
        // reported history at exactly this position).
        openedAtPosition = max(0, ticket.position)
        self.playbackRate = playbackRate
        wantsPlaybackWhenReady = true
        pendingSeekTarget = nil
        // The resumed session's faults must carry THIS load's authority, or
        // every post-claim runtime fault (typed VT, silent-no-output) is
        // dropped as stale and recovery boundary 1 goes blind (review P1).
        session.adoptOwnerGeneration(runtimeGeneration)
        // Parking retired the PiP binding with the old owner; a cold open
        // rebinds inside the session's open, but a claim never opens. Without
        // this equal-snapshot reapplication the resumed session has no PiP
        // controller, so going Home can never start automatic PiP.
        session.setAutomaticPiPEnabled(playbackContinuationConfiguration.allowsAutomaticPiP)
        isReadyToPlay = true
        PlayerLog.log(
            "[PathA] session-claim age=\(ticket.ageMilliseconds(now: .now))ms " +
            "position=\(String(format: "%.2f", ticket.position)) " +
            "startΔ=\(String(format: "%.2f", startPosition - ticket.position))"
        )
        let claimGeneration = runtimeGeneration
        // Deferred one hop, mirroring how the cold `.ready` event arrives —
        // the ViewModel must never re-enter its own load call synchronously.
        // No seed tick here (unlike `.ready`): the claim seed carries the
        // PARKED position, which can exceed the ViewModel's armed preset and
        // would complete the startup trace at ready instead of first frame
        // (review P2). The first real tick lands within one fill period.
        Task { @MainActor [weak self] in
            guard let self, self.runtimeGeneration == claimGeneration else { return }
            StartupTrace.mark("ready-to-play", token: self.startupTraceToken)
            self.onStateChanged?(.readyToPlay)
            self.publishDeliveryRunway()
            guard self.runtimeGeneration == claimGeneration,
                  self.wantsPlaybackWhenReady else { return }
            let resumeReady: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.runtimeGeneration == claimGeneration,
                      self.wantsPlaybackWhenReady else { return }
                self.session.play()
                self.isPlaying = self.session.isPlaying
                PlayerLog.log(
                    "[PathA] session-resume-ready position=\(String(format: "%.2f", self.session.mediaTime))"
                )
            }
            // COLD-CONTRACT PARITY: a cold load opens AT startPosition —
            // including 0 (resume off / restart). A claim whose parked
            // position diverges travels FIRST, then plays, exactly as the
            // `.ready` branch defers auto-play behind a pending seek — never
            // the visible play-then-jump (review P2). Near-parked positions
            // resume in place.
            let target = max(0, startPosition)
            if abs(target - ticket.position) >= 2 {
                self.seek(to: target) { [weak self] restored in
                    guard let self,
                          self.runtimeGeneration == claimGeneration else { return }
                    guard restored else {
                        self.wantsPlaybackWhenReady = false
                        PlayerLog.log(
                            "[PathA] session-claim restore failed — retained session not played"
                        )
                        return
                    }
                    resumeReady()
                }
            } else {
                resumeReady()
            }
        }
    }

    func stop() {
        pendingBootstrapIdentities = nil
        parkedTicket = nil
        parkTTLTask?.cancel()
        parkTTLTask = nil
        runtimeGeneration &+= 1
        deliveredRuntimeFault = nil
        openTask?.cancel()
        openTask = nil
        session.forceRetirePiP()
        invalidateSeekCoordinator()
        session.stop()
        inputIsLocalFile = false
        isReadyToPlay = false
        isPlaying = false
        terminalFailure = false
        debugReportWasBuffering = false
        wantsPlaybackWhenReady = false
        pendingSeekTarget = nil
    }

    func play() {
        guard !terminalFailure else {
            PlayerLog.log("[PathA] play ignored after terminal open failure")
            return
        }
        // A parked session has NO owner: an out-of-band play (lock screen,
        // headset) must not resume ownerless audio, bump the park epoch, or
        // stale the ticket position. Before park existed, play-after-stop was
        // a no-op on every backend; parking keeps that contract.
        guard parkedTicket == nil else {
            PlayerLog.log("[PathA] play ignored while session is parked")
            return
        }
        wantsPlaybackWhenReady = true
        session.play()
        isPlaying = session.isPlaying
    }

    func resumeAudioWhileVideoSuspended(_ token: DemandVideoSuspendToken) -> Bool {
        guard parkedTicket == nil else { return false }
        let resumed = session.resumeAudioWhileVideoSuspended(token)
        if resumed { wantsPlaybackWhenReady = true }
        isPlaying = session.isPlaying
        return resumed
    }

    func pause() {
        // Parked sessions are already quiesced; a pause would only emit a
        // synthetic .paused into whatever owner-less handler still listens.
        guard parkedTicket == nil else { return }
        wantsPlaybackWhenReady = false
        invalidateSeekCoordinator()
        session.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?) {
        // An owner-less parked session accepts no transport. (The claim path
        // seeks only AFTER consuming the ticket, so it never trips this.)
        guard parkedTicket == nil else {
            PlayerLog.log("[PathA] seek ignored while session is parked")
            completion?(false)
            return
        }
        enqueueSeek(to: time, completion: completion, nativePiPRequest: nil)
    }

    private func seekFromPiP(_ native: EnginePiPSeekRequest) {
        let base = pendingSeekTarget ?? session.mediaTime
        let interval = native.interval
        let timelineDuration = session.duration
        let reserve = seekLaunchReserve
        let target = base + interval
        guard parkedTicket == nil, !terminalFailure,
              native.ownerGeneration == runtimeGeneration, native.isCurrent,
              interval.isFinite, interval != 0, base.isFinite, target.isFinite,
              timelineDuration.isFinite, timelineDuration > 0,
              reserve.isFinite, reserve >= 0 else {
            native.finish(success: false)
            return
        }
        let ceiling = max(0, timelineDuration - reserve)
        enqueueSeek(
            to: min(max(0, target), ceiling),
            completion: nil,
            nativePiPRequest: native
        )
    }

    private func enqueueSeek(
        to time: TimeInterval,
        completion: (@MainActor @Sendable (Bool) -> Void)?,
        nativePiPRequest: EnginePiPSeekRequest?
    ) {
        revokeAudioMaintenancePermission()
        abortActivePreparedSeek()
        seekSerial &+= 1
        let replaced = queuedSeekRequest
        let request = SeekRequest(
            serial: seekSerial, target: time, completion: completion,
            nativePiPRequest: nativePiPRequest
        )
        queuedSeekRequest = request
        pendingSeekTarget = time
        logSeekTrace(phase: "request", serial: request.serial, target: time)
        startSeekWorkerIfNeeded()
        // Native completion may re-enter with a successor. Install all new
        // queue/target state first and perform no writes after settlement.
        replaced?.nativePiPRequest?.finish(success: false)
    }

    private func startSeekWorkerIfNeeded() {
        guard seekWorkerTask == nil else { return }
        let epoch = seekEpoch
        nextSeekWorkerID &+= 1
        let workerID = nextSeekWorkerID
        activeSeekWorkerID = workerID
        // Retain the queue owner even before this task starts: every accepted
        // native request must reach discard or actual media return settlement.
        // runSeekWorker's defer releases the registered task at that boundary.
        seekWorkerTask = Task { @MainActor [self] in
            await runSeekWorker(epoch: epoch, workerID: workerID)
        }
    }

    private func runSeekWorker(epoch: UInt64, workerID: UInt64) async {
        defer {
            // Cancellation does not necessarily interrupt an actor call that
            // is already awaiting demux I/O. Keep the task registered until
            // that call returns, so a new request cannot start a second
            // session.prepareSeek concurrently.
            if activeSeekWorkerID == workerID {
                activeSeekWorkerID = nil
                seekWorkerTask = nil
                if queuedSeekRequest != nil {
                    startSeekWorkerIfNeeded()
                }
            }
        }

        while epoch == seekEpoch, !Task.isCancelled, let request = queuedSeekRequest {
            queuedSeekRequest = nil
            var nativeSucceeded = false
            defer { request.nativePiPRequest?.finish(success: nativeSucceeded) }
            if let native = request.nativePiPRequest,
               native.ownerGeneration != runtimeGeneration || !session.isReady {
                if request.serial == seekSerial { pendingSeekTarget = nil }
                continue
            }
            let prepared = await session.prepareSeek(to: request.target)
            logSeekTrace(
                phase: "prepare",
                serial: request.serial,
                target: request.target,
                token: prepared.token,
                ready: prepared.isReady,
                result: prepared.isReady
            )
            guard epoch == seekEpoch, !Task.isCancelled else {
                session.abortPreparedSeek(prepared)
                logSeekTrace(
                    phase: "abort",
                    serial: request.serial,
                    target: request.target,
                    token: prepared.token,
                    ready: prepared.isReady,
                    result: false
                )
                return
            }
            activePreparedSeek = prepared

            // A newer request arrived while this seek was reprime-awaiting. Its
            // target and completion own the public state; silently discard this
            // stale result and immediately run the newest queued request.
            // Once admitted, the same-item seek keeps its media authority if
            // only PiP presentation retires. The native settlement still
            // rejects an old binding; aborting here needs a media successor.
            guard request.serial == seekSerial,
                  request.nativePiPRequest.map({
                      $0.ownerGeneration == runtimeGeneration
                  }) ?? true else {
                activePreparedSeek = nil
                session.abortPreparedSeek(prepared)
                logSeekTrace(
                    phase: "abort",
                    serial: request.serial,
                    target: request.target,
                    token: prepared.token,
                    ready: prepared.isReady,
                    result: false
                )
                PlayerLog.log(
                    "[PathA] seek superseded target=\(String(format: "%.1f", request.target)) " +
                    "newest=\(String(format: "%.1f", pendingSeekTarget ?? request.target))"
                )
                if request.serial == seekSerial { pendingSeekTarget = nil }
                continue
            }

            guard prepared.isReady else {
                activePreparedSeek = nil
                session.abortPreparedSeek(prepared)
                logSeekTrace(
                    phase: "abort",
                    serial: request.serial,
                    target: request.target,
                    token: prepared.token,
                    ready: false,
                    result: false
                )
                pendingSeekTarget = nil
                isPlaying = session.isPlaying
                logSeekTrace(
                    phase: "settle",
                    serial: request.serial,
                    target: request.target,
                    token: prepared.token,
                    ready: false,
                    result: false
                )
                request.completion?(false)
                continue
            }

            logSeekTrace(
                phase: "commit",
                serial: request.serial,
                target: request.target,
                token: prepared.token,
                ready: true
            )
            let ok = await session.commitPreparedSeek(
                prepared,
                isAuthorized: { [weak self] in
                    guard let self else { return false }
                    return self.seekEpoch == epoch
                        && self.seekSerial == request.serial
                        && (request.nativePiPRequest.map {
                            $0.ownerGeneration == self.runtimeGeneration
                        } ?? true)
                }
            )
            logSeekTrace(
                phase: "commit",
                serial: request.serial,
                target: request.target,
                token: prepared.token,
                ready: prepared.isReady,
                result: ok
            )
            if activePreparedSeek?.token == prepared.token {
                activePreparedSeek = nil
            }
            guard epoch == seekEpoch, !Task.isCancelled else {
                session.abortPreparedSeek(prepared)
                logSeekTrace(
                    phase: "abort",
                    serial: request.serial,
                    target: request.target,
                    token: prepared.token,
                    ready: prepared.isReady,
                    result: false
                )
                return
            }

            // A newer request can arrive while the renderer waits for its RT
            // acknowledgement. Do not settle the superseded completion or
            // clear the newer target; the next loop owns the transaction.
            guard request.serial == seekSerial,
                  request.nativePiPRequest.map({
                      $0.ownerGeneration == runtimeGeneration
                  }) ?? true else {
                session.abortPreparedSeek(prepared)
                logSeekTrace(
                    phase: "abort",
                    serial: request.serial,
                    target: request.target,
                    token: prepared.token,
                    ready: prepared.isReady,
                    result: false
                )
                if ok {
                    PlayerLog.log(
                        "[PathA] seek commit superseded target=\(String(format: "%.1f", request.target)) " +
                        "newest=\(String(format: "%.1f", pendingSeekTarget ?? request.target))"
                    )
                }
                if request.serial == seekSerial { pendingSeekTarget = nil }
                continue
            }

            pendingSeekTarget = nil
            isPlaying = session.isPlaying
            // A resume-to-saved-position seek fires right after `.ready`; the ready
            // auto-play was skipped because this seek was pending, so START playback
            // now — at the target, not at 0 (that play-0-then-jump was the visible
            // "self fast-forward", device 2026-07-22).
            if ok, wantsPlaybackWhenReady, !session.isPlaying {
                session.play()
                isPlaying = session.isPlaying
            }
            logSeekTrace(
                phase: "settle",
                serial: request.serial,
                target: request.target,
                token: prepared.token,
                ready: prepared.isReady,
                result: ok
            )
            request.completion?(ok)
            nativeSucceeded = ok && epoch == seekEpoch && request.serial == seekSerial
        }
    }

    private func invalidateSeekCoordinator() {
        revokeAudioMaintenancePermission()
        if activePreparedSeek == nil,
           let queued = queuedSeekRequest ?? (pendingSeekTarget.map {
               SeekRequest(serial: seekSerial, target: $0, completion: nil, nativePiPRequest: nil)
           }) {
            logSeekTrace(
                phase: "abort",
                serial: queued.serial,
                target: queued.target,
                ready: false,
                result: false
            )
        }
        abortActivePreparedSeek()
        seekEpoch &+= 1
        seekSerial &+= 1
        let discarded = queuedSeekRequest
        queuedSeekRequest = nil
        seekWorkerTask?.cancel()
        pendingSeekTarget = nil
        discarded?.nativePiPRequest?.finish(success: false)
    }

    private func abortActivePreparedSeek() {
        guard let prepared = activePreparedSeek else { return }
        activePreparedSeek = nil
        session.abortPreparedSeek(prepared)
        logSeekTrace(
            phase: "abort",
            target: prepared.target,
            token: prepared.token,
            ready: prepared.isReady,
            result: false
        )
    }

    func setScaleMode(_ mode: VideoScaleMode) {
        scaleMode = mode
        session.setScaleMode(mode)
    }

    func setDemandPresentationCornerRadius(_ radius: CGFloat) {
        session.setPresentationCornerRadius(radius)
    }

    func applyPlaybackContinuationConfiguration(
        _ configuration: PlaybackContinuationConfiguration
    ) -> PlaybackContinuationApplyResult {
        let changed = playbackContinuationConfiguration != configuration
        playbackContinuationConfiguration = configuration
        // Always project the snapshot into the session. A cached backend can
        // retain the same desired ON/ON value after stop() has cleared its
        // presentation binding; the session owns the idempotent distinction
        // between an already-current binding and one that must be restored.
        session.setAutomaticPiPEnabled(configuration.allowsAutomaticPiP)
        if changed {
            PlayerLog.log(
                "[PathA] PiP capability enabled=" +
                (configuration.allowsAutomaticPiP ? "1" : "0")
            )
        }
        return .unchanged(hostRevision: 0)
    }

    func startPiP() {
        guard playbackContinuationConfiguration.allowsAutomaticPiP else {
            PlayerLog.log("[PathA] startPiP rejected — capability disabled")
            return
        }
        let ok = session.startPiP()
        if !ok {
            PlayerLog.log("[PathA] startPiP returned false — no observed Sample Buffer lease")
        }
    }

    func stopPiP() {
        session.stopPiP()
    }

    func noteDemandPiPEnvironmentWillResignActive() {
        session.notePiPEnvironmentWillResignActive()
    }

    func abandonDemandPiPStart() {
        session.abandonPendingPiPStart()
    }

    func reconcileDemandPiPPresentationAfterActivation(
        renderGeneration: Int
    ) async -> Bool {
        await session.reconcilePiPPresentationAfterActivation(
            renderGeneration: renderGeneration
        )
    }

    func setObservedPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        observedPiPLeaseChangeHandler = handler
        if handler == nil {
            hasObservedPiPLease = false
        }
    }

    func setPiPTransportEdgeHandler(
        _ handler: (@MainActor @Sendable (PlayerBackendPiPTransportEdge) -> Void)?
    ) {
        pipTransportEdgeHandler = handler
    }

    func warmSuspendDemandVideoLane() -> DemandVideoSuspensionResult {
        session.warmSuspendVideoLane()
    }

    func retainAudioAfterDemandVideoFailure() -> DemandVideoSuspendToken? {
        session.retainAudioAfterVideoFailure()
    }

    var audioOutputAvailability: MediaAudioOutputAvailability { session.audioOutputAvailability }

    func setAudioOutputStateChangeHandler(_ handler: (@MainActor () -> Void)?) {
        session.setAudioOutputStateChangeHandler(handler)
    }

    func reconcileAudioOutputForAuthorizedPlayback() -> Bool {
        session.reconcileAudioOutputForAuthorizedPlayback()
    }

    /// Native PiP didStop can arrive while the app is still backgrounded and
    /// while PiP/user controls left the transport paused. Keep this forwarding
    /// surface separate from the playing-only audio-background operation so the
    /// session can retain the exact pause intent in a typed local token.
    func suspendDemandVideoLaneAfterPiPStop() -> DemandVideoSuspensionResult {
        session.suspendVideoLaneAfterPiPStop()
    }

    func prepareDemandVideoLaneForForeground(
        _ token: DemandVideoSuspendToken
    ) async -> DemandVideoLanePreparationResult {
        await session.prepareVideoLaneForForeground(token)
    }

    func resumeDemandVideoLane(
        _ token: DemandVideoSuspendToken,
        renderGeneration: Int
    ) async -> Bool {
        await session.resumeVideoLane(token, renderGeneration: renderGeneration)
    }

    func restoreDemandInlinePresentation(renderGeneration: Int) async -> Bool {
        await session.restoreInlinePresentation(renderGeneration: renderGeneration)
    }

    func flushAndPrimeDemandRenderer(renderGeneration: Int) -> Bool {
        session.flushAndPrimeRenderer(renderGeneration: renderGeneration)
    }

    func recreateDemandVideoDecoder() async -> Bool {
        await session.recreateVideoDecoderForPresentation()
    }

    func noteDemandInlineAttachment(
        renderGeneration: Int,
        isVisible: Bool,
        boundsUsable: Bool
    ) {
        session.noteInlineAttachment(
            renderGeneration: renderGeneration,
            isVisible: isVisible,
            boundsUsable: boundsUsable
        )
    }

    func refreshDemandPresentationImageHold() {
        session.refreshPresentationImageHold()
    }

    func setDemandPresentationProofHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationSample) -> Void)?
    ) {
        session.setPresentationProofHandler(handler)
    }

    func setDemandPresentationFailureHandler(
        _ handler: (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)?
    ) {
        session.setPresentationFailureHandler(handler)
    }

    func setDemandPiPNativeTransitionHandler(
        _ handler: (@MainActor @Sendable (DemandPiPNativeTransition) -> Void)?
    ) {
        session.setPiPNativeTransitionHandler(handler)
    }

    func setDemandPiPRestoreRequestHandler(
        _ handler: (@MainActor @Sendable (UInt64) -> Void)?
    ) {
        session.setPiPRestoreRequestHandler(handler)
    }

    func completeDemandPiPRestore(token: UInt64, success: Bool) {
        session.completePiPRestore(token: token, success: success)
    }

    func forceRetireDemandPiP() {
        session.forceRetirePiP()
    }

    func setRuntimeFaultHandler(
        _ handler: (@MainActor @Sendable (MediaRuntimeFault) -> Void)?
    ) {
        runtimeFaultHandler = handler
    }

    private func updateObservedPiPLease(_ active: Bool) {
        guard hasObservedPiPLease != active else { return }
        hasObservedPiPLease = active
        observedPiPLeaseChangeHandler?(active)
        PlayerLog.log("[PathA] Demand observed PiP lease active=\(active ? 1 : 0)")
    }

    /// Stamp the engine-owned PiP edge with this backend's current load
    /// generation. Old session/binding callbacks are rejected before the App
    /// can project them into Now Playing.
    private func handlePiPTransportEvent(_ event: EnginePiPTransportEvent) {
        let sessionGeneration: UInt64
        let pipBindingGeneration: UInt64?
        let ownerLeaseGeneration: UInt64
        switch event {
        case let .transportIntent(_, _, generation, binding, ownerLease):
            guard generation == session.runtimeGeneration else {
                PlayerLog.log(
                    "[PathA] stale PiP transport edge ignored session=\(generation) " +
                    "current=\(session.runtimeGeneration)"
                )
                return
            }
            if let binding,
               binding != session.currentPiPBindingGeneration {
                PlayerLog.log(
                    "[PathA] stale PiP transport edge ignored binding=\(binding) " +
                    "current=\(session.currentPiPBindingGeneration)"
                )
                return
            }
            guard binding != nil || session.currentPiPBindingGeneration == 0 else {
                PlayerLog.log("[PathA] stale PiP transport edge ignored missing binding")
                return
            }
            sessionGeneration = generation
            pipBindingGeneration = binding
            ownerLeaseGeneration = ownerLease

        case let .seekSettled(_, _, generation, binding, ownerLease):
            guard generation == session.runtimeGeneration else {
                PlayerLog.log(
                    "[PathA] stale PiP transport edge ignored session=\(generation) " +
                    "current=\(session.runtimeGeneration)"
                )
                return
            }
            if let binding,
               binding != session.currentPiPBindingGeneration {
                PlayerLog.log(
                    "[PathA] stale PiP transport edge ignored binding=\(binding) " +
                    "current=\(session.currentPiPBindingGeneration)"
                )
                return
            }
            guard binding != nil || session.currentPiPBindingGeneration == 0 else {
                PlayerLog.log("[PathA] stale PiP transport edge ignored missing binding")
                return
            }
            sessionGeneration = generation
            pipBindingGeneration = binding
            ownerLeaseGeneration = ownerLease
        }

        switch event {
        case let .transportIntent(operation, playing, _, _, _):
            // Session applies the native transport once after this callback.
            // Install pause intent before discarded native completions can
            // re-enter, even when there is no App projection handler.
            wantsPlaybackWhenReady = playing
            if !playing { invalidateSeekCoordinator() }
            pipTransportEdgeHandler?(.transportIntent(
                operation: operation,
                playing: playing,
                backendGeneration: runtimeGeneration,
                sessionGeneration: sessionGeneration,
                pipBindingGeneration: pipBindingGeneration,
                ownerLeaseGeneration: ownerLeaseGeneration
            ))
        case let .seekSettled(operation, position, _, _, _):
            guard position.isFinite, position >= 0 else { return }
            pipTransportEdgeHandler?(.seekSettled(
                operation: operation,
                position: position,
                backendGeneration: runtimeGeneration,
                sessionGeneration: sessionGeneration,
                pipBindingGeneration: pipBindingGeneration,
                ownerLeaseGeneration: ownerLeaseGeneration
            ))
        }
    }

    func videoTracks() -> [PlayerTrackInfo] {
        guard isReadyToPlay else { return [] }
        return Self.videoTrack(from: session.stats).map { [$0] } ?? []
    }

    static func videoTrack(from stats: MediaEngineStats) -> PlayerTrackInfo? {
        guard stats.videoWidth > 0, stats.videoHeight > 0 else { return nil }
        return PlayerTrackInfo(
            name: "path-a",
            naturalSize: CGSize(width: stats.videoWidth, height: stats.videoHeight)
        )
    }

    /// A7: map engine stats → backend dynamic info (FPS/bitrate 0 when unknown).
    var dynamicInfo: PlayerDynamicStats? {
        Self.dynamicInfo(from: session.stats)
    }

    static func dynamicInfo(from stats: MediaEngineStats) -> PlayerDynamicStats {
        // Bitrate unknown without container metadata — leave 0 offline.
        return PlayerDynamicStats(
            displayFPS: stats.presentedVideoFPS,
            videoBitrate: 0,
            audioBitrate: 0,
            bytesRead: stats.bytesRead,
            networkBytesReceived: stats.networkBytesReceived,
            multiConnection: stats.multiConnection
        )
    }

    func thumbnailAtCurrentTime() async -> UIImage? {
        await session.thumbnailAtCurrentTime()
    }

    func invalidateFrameStats() {
        session.invalidateFrameStats()
    }

    func updateDemandVideoLivenessContext(_ context: DemandVideoLivenessContext?) {
        session.updateVideoLivenessContext(context)
    }

    // MARK: - Session → backend events

    private func handleSessionEvent(_ event: MediaSessionEvent) {
        switch event {
        case .ready(let duration):
            guard !terminalFailure else {
                PlayerLog.log("[PathA] ignored ready after terminal open failure")
                return
            }
            // Ticket set: a parked session has no owner. That includes a ready
            // that arrives after a finished session was parked — not the same
            // failure as an open this load already replaced.
            // Superseded open: `load` bumps `runtimeGeneration` before the
            // replacement `session.open` runs, so the previous open can still
            // emit `.ready` carrying the old owner. Compare owner generation
            // (`retainedPipelineHealth`'s stale verdict), never
            // `session.runtimeGeneration` — that counter is independent and a
            // match against it would drop a legitimate ready for the current
            // load. A current-generation ready with no ticket falls through.
            guard parkedTicket == nil else {
                PlayerLog.log("[PathA] ignored ready while session is parked")
                return
            }
            let readyHealth = session.retainedPipelineHealth(
                backendGeneration: runtimeGeneration
            )
            if case .requiresRecovery(.staleGeneration) = readyHealth.state {
                PlayerLog.log(
                    "[PathA] ignored ready from superseded open " +
                    "owner=\(readyHealth.backendGeneration) current=\(runtimeGeneration)"
                )
                return
            }
            isReadyToPlay = true
            if seekWorkerTask == nil, queuedSeekRequest == nil {
                pendingSeekTarget = nil
            }
            // Same label as the VLC backend's readiness mark, so the two
            // engines' startup traces read side by side.
            StartupTrace.mark("ready-to-play", token: startupTraceToken)
            onStateChanged?(.readyToPlay)
            onTickWithGeneration?(session.mediaTime, duration, runtimeGeneration, startupTraceToken)
            publishDeliveryRunway()
            PlayerLog.log(
                "[PathA] ready duration=\(String(format: "%.1f", duration))"
            )
            // VLC would already be playing here; start the Demand session too so
            // audio pull begins and mediaTime advances instead of freezing at 0.
            // Deferred one hop so a resume-to-saved-position seek (dispatched from
            // the ViewModel's readyToPlay handler during `onStateChanged` above)
            // wins the race and sets `pendingSeekTarget` first — then we DON'T play
            // at 0; the seek completion starts playback at the resume target. No
            // resume → pendingSeekTarget stays nil → play from 0 as normal.
            if wantsPlaybackWhenReady {
                Task { @MainActor [weak self] in
                    guard let self, self.wantsPlaybackWhenReady, self.isReadyToPlay,
                          self.pendingSeekTarget == nil, !self.session.isPlaying else { return }
                    self.session.play()
                    self.isPlaying = self.session.isPlaying
                }
            }
        case .buffering:
            if !debugReportWasBuffering {
                debugReportWasBuffering = true
                PlayerLog.log("[playback] buffering-enter mt=\(String(format: "%.2f", session.mediaTime))")
            }
            onStateChanged?(.buffering)
        case .playing:
            guard !terminalFailure else {
                isPlaying = false
                return
            }
            isPlaying = true
            if debugReportWasBuffering {
                debugReportWasBuffering = false
                PlayerLog.log("[playback] buffering-exit mt=\(String(format: "%.2f", session.mediaTime))")
            }
            onStateChanged?(.bufferFinished)
        case .paused:
            isPlaying = false
            onStateChanged?(.paused)
        case .ended:
            isPlaying = false
            onStateChanged?(.playedToTheEnd)
        case .failed(let err):
            if case .transportFailed(let failure) = err {
                guard failure.backendGeneration == runtimeGeneration,
                      failure.sessionGeneration == session.runtimeGeneration else { return }
            }
            if case .unsupportedLiveSource(_, let ownerGeneration, _) = err {
                guard ownerGeneration == runtimeGeneration, !session.isReady else { return }
            }
            isReadyToPlay = false
            isPlaying = false
            terminalFailure = true
            PlayerLog.log("[PathA] failed: \(err.localizedDescription)")
            onStateChanged?(.error(err))
        case .runtimeFault(let fault):
            let key = RuntimeFaultDeliveryKey(
                ownerGeneration: fault.ownerGeneration,
                sessionGeneration: fault.sessionGeneration,
                ownerLeaseGeneration: fault.ownerLeaseGeneration
            )
            guard fault.ownerGeneration == runtimeGeneration else {
                PlayerLog.log(
                    "[PathA] stale runtime fault ignored owner=\(fault.ownerGeneration) " +
                    "current=\(runtimeGeneration)"
                )
                return
            }
            guard fault.sessionGeneration == session.runtimeGeneration else {
                PlayerLog.log(
                    "[PathA] stale runtime fault ignored session=\(fault.sessionGeneration) " +
                    "current=\(session.runtimeGeneration)"
                )
                return
            }
            let isLocalPresentationDebt = session.hasLocalPresentationFault
            if !isLocalPresentationDebt {
                guard deliveredRuntimeFault != key else {
                    PlayerLog.log(
                        "[PathA] duplicate runtime fault coalesced " +
                        "session=\(fault.sessionGeneration)"
                    )
                    return
                }
                deliveredRuntimeFault = key
                isReadyToPlay = false
                isPlaying = false
                terminalFailure = !fault.isRecoveryWorthy
            }
            runtimeFaultHandler?(fault)
        case .tick(let t, let d, _):
            onTickWithGeneration?(t, d, runtimeGeneration, startupTraceToken)
            publishDeliveryRunway()
        }
    }
}
