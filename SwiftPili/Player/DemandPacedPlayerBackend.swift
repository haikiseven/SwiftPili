import UIKit
import Observation

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
    private var parkedTicket: ParkedPlaybackTicket?
    private var parkTTLTask: Task<Void, Never>?
    private let memoryPressureObserver: DemandMemoryPressureObserver
    private var lastLoadIdentity: String?
    private static let parkTTL: Duration = .seconds(90)
    private static let demandBringUpPacketHWMCap: TimeInterval = 8

    private(set) var isReadyToPlay = false
    private(set) var runtimeGeneration: UInt64 = 0
    private var startupTraceToken: StartupTrace.Token?
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
    private var openTask: Task<Void, Never>?
    private var terminalFailure = false
    private var debugReportWasBuffering = false
    private var wantsPlaybackWhenReady = false
    private(set) var isPlaying = false
    var retainedPipelineHealth: RetainedPipelineHealth {
        session.retainedPipelineHealth(backendGeneration: runtimeGeneration)
    }

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
    private var seekSerial: UInt64 = 0
    private var seekEpoch: UInt64 = 0
    private var queuedSeekRequest: SeekRequest?
    private var seekWorkerTask: Task<Void, Never>?
    private var nextSeekWorkerID: UInt64 = 0
    private var activeSeekWorkerID: UInt64?
    private var activePreparedSeek: MediaEngineSeekPreparation?

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

    var seekLaunchReserve: TimeInterval { session.requiredAudioSeekContentSeconds }

    var isMuted = false {
        didSet { session.setAudioMuted(isMuted) }
    }

    var currentTime: TimeInterval { session.mediaTime }
    var duration: TimeInterval { session.duration }
    var playableTime: TimeInterval {
        if inputIsLocalFile, duration > 0 { return duration }
        return session.bufferedTime
    }

    var bufferDisplaySample: MediaBufferDisplaySample? {
        inputIsLocalFile ? nil : session.bufferDisplaySample
    }

    private var inputIsLocalFile = false

    private func publishDeliveryRunway() {
        guard let runway = session.deliveryRunway else { return }
        onBufferChanged?(runway)
    }

    var bufferedContentAhead: TimeInterval? { session.deliveryRunway }

    var bufferedPipelineAhead: TimeInterval? { session.pipelineRunway }

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
            if !changed.isEmpty {
                PlayerLog.log(
                    "[PathA] session-park-invalidated reason=prefetch-policy-changed " +
                        "fields=\(changed.joined(separator: ","))"
                )
                discardParkedSession()
            }
        }
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
            maxBuffer: min(maxBuffer, Self.demandBringUpPacketHWMCap)
        )
        lastLoadIdentity = identity
        inputIsLocalFile = url.isFileURL
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

        session.forceRetirePiP()
        invalidateSeekCoordinator()
        openedAtPosition = max(0, startPosition)
        isReadyToPlay = false
        isPlaying = false
        terminalFailure = false
        debugReportWasBuffering = false
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

    private func takeClaimableTicket(for identity: String) -> ParkedPlaybackTicket? {
        guard let ticket = parkedTicket else { return nil }
        switch ticket.decision(for: identity, now: .now, ttl: Self.parkTTL) {
        case .claim:
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

    private func discardParkedSession() {
        parkedTicket = nil
        parkTTLTask?.cancel()
        parkTTLTask = nil
        session.stop()
    }

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
        openedAtPosition = max(0, ticket.position)
        self.playbackRate = playbackRate
        wantsPlaybackWhenReady = true
        pendingSeekTarget = nil
        session.adoptOwnerGeneration(runtimeGeneration)
        session.setAutomaticPiPEnabled(playbackContinuationConfiguration.allowsAutomaticPiP)
        isReadyToPlay = true
        PlayerLog.log(
            "[PathA] session-claim age=\(ticket.ageMilliseconds(now: .now))ms " +
            "position=\(String(format: "%.2f", ticket.position)) " +
            "startΔ=\(String(format: "%.2f", startPosition - ticket.position))"
        )
        let claimGeneration = runtimeGeneration
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
        guard parkedTicket == nil else { return }
        wantsPlaybackWhenReady = false
        invalidateSeekCoordinator()
        session.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval, completion: (@MainActor @Sendable (Bool) -> Void)?) {
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
        replaced?.nativePiPRequest?.finish(success: false)
    }

    private func startSeekWorkerIfNeeded() {
        guard seekWorkerTask == nil else { return }
        let epoch = seekEpoch
        nextSeekWorkerID &+= 1
        let workerID = nextSeekWorkerID
        activeSeekWorkerID = workerID
        seekWorkerTask = Task { @MainActor [self] in
            await runSeekWorker(epoch: epoch, workerID: workerID)
        }
    }

    private func runSeekWorker(epoch: UInt64, workerID: UInt64) async {
        defer {
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

    var dynamicInfo: PlayerDynamicStats? {
        Self.dynamicInfo(from: session.stats)
    }

    static func dynamicInfo(from stats: MediaEngineStats) -> PlayerDynamicStats {
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
            StartupTrace.mark("ready-to-play", token: startupTraceToken)
            onStateChanged?(.readyToPlay)
            onTickWithGeneration?(session.mediaTime, duration, runtimeGeneration, startupTraceToken)
            publishDeliveryRunway()
            PlayerLog.log(
                "[PathA] ready duration=\(String(format: "%.1f", duration))"
            )
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
