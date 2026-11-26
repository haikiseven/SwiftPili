import AVFoundation
import Foundation
import QuartzCore
import SwiftUI
import UIKit

extension PlayerViewModel {

    @discardableResult
    func playOffline(
        videoURL: URL,
        audioURL: URL?,
        aid: Int,
        cid: Int,
        quality: Int,
        codecs: String,
        durationSeconds: Int,
        title: String,
        artist: String,
        cover: String?,
        resumeAt: TimeInterval?,
        aspectRatioHint: CGFloat? = nil,
        owner: String
    ) -> PlayerOwnerLease? {
        let asset = OfflinePlaybackAsset(
            videoURL: videoURL,
            audioURL: audioURL,
            aid: aid,
            cid: cid,
            quality: quality,
            codecs: codecs,
            durationSeconds: durationSeconds,
            title: title,
            artist: artist,
            cover: cover
        )
        guard OfflinePlaybackAssetValidator.allows(
            videoURL: asset.videoURL,
            audioURL: asset.audioURL
        ) else {
            markTerminalNoReachableStreamFailure()
            return nil
        }

        let lease = claimOwnerLease(owner: owner)
        guard ownerKey == owner else { return nil }

        if mode != .offline || offlineAsset != asset || currentURL == nil {
            let effectiveResumeAt: TimeInterval = PlayerPlaybackPreferences.resumePlayback ? (resumeAt ?? 0) : 0
            startOfflinePlayback(
                asset,
                at: effectiveResumeAt,
                preservePlayState: false,
                aspectRatioHint: aspectRatioHint,
                isHistoryResume: PlayerPlaybackPreferences.resumePlayback
            )
        } else {
            presentationResetPendingForOwnerChange = false
            applyAspectRatioHint(aspectRatioHint)
            if stats.decoderType.isEmpty {
                prepareOfflineDecoderLabel(for: asset)
            }
        }
        return lease
    }

    @discardableResult
    func playOffline(
        videoURL: URL,
        audioURL: URL?,
        aid: Int,
        cid: Int,
        quality: Int,
        codecs: String,
        durationSeconds: Int,
        title: String,
        artist: String,
        cover: String?,
        resumeAt: TimeInterval?,
        aspectRatioHint: CGFloat? = nil,
        lease: PlayerOwnerLease
    ) -> Bool {
        let asset = OfflinePlaybackAsset(
            videoURL: videoURL,
            audioURL: audioURL,
            aid: aid,
            cid: cid,
            quality: quality,
            codecs: codecs,
            durationSeconds: durationSeconds,
            title: title,
            artist: artist,
            cover: cover
        )
        guard OfflinePlaybackAssetValidator.allows(
            videoURL: asset.videoURL,
            audioURL: asset.audioURL
        ), isCurrentOwner(lease) else {
            return false
        }
        if consumeMiniPlayerReturnIfLiveOffline(asset: asset, ownerLease: lease) {
            applyAspectRatioHint(aspectRatioHint)
            ensureOfflineSidecarsLoaded(for: asset)
            if stats.decoderType.isEmpty {
                prepareOfflineDecoderLabel(for: asset)
            }
            return isCurrentOwner(lease)
        }
        let effectiveResumeAt: TimeInterval = PlayerPlaybackPreferences.resumePlayback ? (resumeAt ?? 0) : 0
        startOfflinePlayback(
            asset,
            at: effectiveResumeAt,
            preservePlayState: false,
            aspectRatioHint: aspectRatioHint,
            isHistoryResume: PlayerPlaybackPreferences.resumePlayback
        )
        return isCurrentOwner(lease)
    }

    func startOfflinePlayback(
        _ asset: OfflinePlaybackAsset,
        at requestedPosition: TimeInterval,
        preservePlayState: Bool,
        aspectRatioHint: CGFloat? = nil,
        mediaResetID: UUID? = nil,
        isHistoryResume: Bool = false
    ) {
        if let mediaResetID,
           !mediaResetRecovery.accepts(mediaResetID, owner: currentOwnerLease) { return }
        guard OfflinePlaybackAssetValidator.allows(
            videoURL: asset.videoURL,
            audioURL: asset.audioURL
        ) else {
            markTerminalNoReachableStreamFailure()
            return
        }
        retireStartupTraceBeforeNonVODLoad(.offline)
        let startAt = OfflinePlaybackRecoveryPolicy.request(
            for: asset,
            position: requestedPosition
        ).position
        let sameContent = mode == .offline && offlineAsset == asset
        let initialAspectHint = DetailPlayerGeometry.normalizedAspect(aspectRatioHint)
        let retainedAspectRatio = sameContent ? videoAspectRatio : nil
        let teardownReason = PlayerReloadPresentationPolicy.reason(
            targetMode: .offline,
            currentMode: mode,
            sameContent: sameContent,
            newOwner: presentationResetPendingForOwnerChange
        )
        playbackTerminalState = .active
        if !sameContent {
            nowPlayingMeta = nil
            portraitPureViewEnabled = false
            if portraitFullscreenContext?.ownerLease != currentOwnerLease {
                portraitFullscreenContext = nil
            }
        }
        let previousOfflineAsset = offlineAsset
        if let previousOfflineAsset, previousOfflineAsset != asset {
            unregisterOfflineDanmakuDirectory(for: previousOfflineAsset)
        }
        let fallbackContentKey = Self.offlineDecodeFallbackContentKey(asset: asset)
        if !sameContent || session.decodeFallback.contentKey != fallbackContentKey {
            session.decodeFallback = PlayerDecodeFallbackState(contentKey: fallbackContentKey)
        }
        stop(reason: teardownReason, mediaResetID: mediaResetID)
        presentationResetPendingForOwnerChange = false
        restorePreferredBackendForLoad("offline load")
        resetMultiConnectionDisplay()
        loadGeneration += 1
        if let mediaResetID { mediaResetRecovery.bind(mediaResetID, loadGeneration: loadGeneration) }
        mode = .offline
        armDurableResumeTarget(nil, source: "offline-load")
        offlineAsset = asset
        let offlineFolderURL = asset.videoURL.deletingLastPathComponent()
        syncOfflineDanmakuRegistration(for: asset, folderURL: offlineFolderURL)
        loadOfflineSubtitles(
            from: offlineFolderURL,
            asset: asset,
            generation: loadGeneration,
            ownerLease: currentOwnerLease
        )
        currentAid = asset.aid
        currentCid = asset.cid
        currentBvid = nil
        currentSource = .ugc
        currentRoomID = nil
        currentQuality = asset.quality
        currentVideoIsAV1 = VideoCodecPreference.av1.matches(asset.codecs)
        videoAspectRatio = sameContent ? (retainedAspectRatio ?? initialAspectHint) : initialAspectHint
        if !sameContent {
            isPortraitContent = DeviceCapability.usesCompactPortraitVideoFraming
                && DetailPlayerGeometry.isPortraitAspect(initialAspectHint, fallback: false)
        } else if let initialAspectHint, !portraitPropagation.hasValidVideoGeometry {
            isPortraitContent = DeviceCapability.usesCompactPortraitVideoFraming
                && DetailPlayerGeometry.isPortraitAspect(initialAspectHint, fallback: isPortraitContent)
        }
        portraitPropagation = PlayerPortraitPropagationState(
            mode: .offline,
            apiHint: nil,
            initialIsPortrait: isPortraitContent
        )
        inlineCondensed = false
        portraitCondenseLocked = false
        if !preservePlayState {
            playbackIntent = .playing
        }
        error = nil
        unavailability = nil
        availableQualities = []
        availableCodecs = []
        availableAudioTiers = []
        playingAudioTier = nil
        skipSegments = []
        streamNominalBitrate = 0
        duration = TimeInterval(asset.durationSeconds)
        stats.codec = asset.codecs
        prepareOfflineDecoderLabel(for: asset)
        stats.quality = asset.quality
        stats.qualityDesc = Self.qualityMap[asset.quality] ?? "\(asset.quality)"
        stats.hasSeparateAudio = asset.audioURL != nil
        stats.videoURL = ""
        stats.videoHost = ""
        stats.audioHost = ""
        stats.cdnSetting = ""
        stats.networkSpeed = 0
        if startAt > 2 {
            resumeAtTime = startAt
            resumeIsFromHistory = isHistoryResume
            mediaTime = startAt
        }
        if isHistoryResume,
           mediaResetID == nil,
           !preservePlayState,
           PlayerPlaybackPreferences.resumePlayback,
           startAt > 5 {
            pendingHistoryResumeNotice = PendingHistoryResumeNotice(
                resumedSeconds: startAt,
                partNumber: nil
            )
            pendingPartLocationNotice = nil
        }
        setNowPlaying(title: asset.title, artist: asset.artist, cover: asset.cover)
        playURL(
            asset.videoURL,
            audioURL: asset.audioURL,
            startAt: startAt > 2 ? startAt : 0
        )
        startOfflineProgressPersistence()
        PlayerLog.log(
            "[Player] offline asset opened qn=\(asset.quality) split=\(asset.audioURL == nil ? 0 : 1)"
        )
    }

    private func prepareOfflineDecoderLabel(for asset: OfflinePlaybackAsset) {
        offlineDecoderLabelTask?.cancel()
        let requestID = UUID()
        offlineDecoderLabelRequestID = requestID
        let generation = loadGeneration
        let ownerLease = currentOwnerLease
        let codecs = asset.codecs
        stats.decoderType = ""
        offlineDecoderLabelTask = Task { [weak self] in
            let hardwareCapabilities = await VideoHardwareCapabilities.snapshot()
            guard let self else { return }
            defer {
                if self.offlineDecoderLabelRequestID == requestID {
                    self.offlineDecoderLabelTask = nil
                    self.offlineDecoderLabelRequestID = nil
                }
            }
            guard !Task.isCancelled,
                  self.offlineDecoderLabelRequestID == requestID,
                  self.loadGeneration == generation,
                  self.currentOwnerLease == ownerLease,
                  self.mode == .offline,
                  self.offlineAsset == asset,
                  self.stats.codec == codecs else { return }
            self.stats.decoderType = self.decoderLabel(
                codecs: codecs,
                hardwareSupported: hardwareCapabilities.supports(codecs: codecs)
            )
        }
    }

    // MARK: - Offline Sidecars (Danmaku & CC Subtitles)

    func syncOfflineDanmakuRegistration(for asset: OfflinePlaybackAsset, folderURL: URL) {
        if OfflineDanmakuSidecar.hasDanmaku(in: folderURL) {
            DanmakuSegmentStore.registerOfflineDirectory(folderURL, forOID: asset.cid)
        } else {
            DanmakuSegmentStore.unregisterOfflineDirectory(forOID: asset.cid, matching: folderURL)
        }
    }

    func unregisterOfflineDanmakuDirectory(for asset: OfflinePlaybackAsset?) {
        guard let asset else { return }
        let folderURL = asset.videoURL.deletingLastPathComponent()
        DanmakuSegmentStore.unregisterOfflineDirectory(forOID: asset.cid, matching: folderURL)
    }

    func ensureOfflineSidecarsLoaded(for asset: OfflinePlaybackAsset) {
        let folderURL = asset.videoURL.deletingLastPathComponent()
        syncOfflineDanmakuRegistration(for: asset, folderURL: folderURL)
        if availableSubtitles.isEmpty {
            loadOfflineSubtitles(
                from: folderURL,
                asset: asset,
                generation: loadGeneration,
                ownerLease: currentOwnerLease
            )
        }
    }

    @discardableResult
    func mountOfflineSubtitles(from folderURL: URL) -> [PlayerV2Info.SubtitleBox.SubtitleItem] {
        let items = OfflineSubtitleSidecar.loadSubtitleItems(in: folderURL)
        availableSubtitles = items
        if !items.isEmpty {
            let labels = items.map { $0.lanDoc ?? $0.lan ?? "?" }.joined(separator: ", ")
            PlayerLog.log("[Player] offline CC subtitles mounted: \(labels)")
        }
        return items
    }

    func loadOfflineSubtitles(
        from folderURL: URL,
        asset: OfflinePlaybackAsset,
        generation: Int,
        ownerLease: PlayerOwnerLease?
    ) {
        Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) {
                OfflineSubtitleSidecar.loadSubtitleItems(in: folderURL)
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.loadGeneration == generation,
                  self.mode == .offline,
                  self.offlineAsset == asset,
                  ownerLease.map({ self.isCurrentOwner($0) }) ?? true else { return }
            self.availableSubtitles = items
            if !items.isEmpty {
                let labels = items.map { $0.lanDoc ?? $0.lan ?? "?" }.joined(separator: ", ")
                PlayerLog.log("[Player] offline CC subtitles loaded: \(labels)")
            }
            await self.applyPersistedSubtitlePreferences(
                for: items,
                expectedGeneration: generation,
                ownerLease: ownerLease
            )
        }
    }
}

struct OfflineDanmakuOverlay: View {
    let player: PlayerViewModel
    let folderURL: URL
    let cid: Int

    var body: some View {
        GeometryReader { proxy in
            let picture = PlayerDanmakuPicture.rect(
                in: proxy.size,
                scaleMode: player.scaleMode,
                resolution: player.videoResolution,
                isPortraitContent: player.isPortraitContent,
                portraitHint: nil
            )
            OfflineDanmakuCanvasView(
                cid: cid,
                folderURL: folderURL,
                scaleMode: player.scaleMode,
                picture: picture,
                isFullscreen: player.isFullscreen,
                mediaTime: player.mediaTime,
                duration: player.duration,
                playbackRate: player.playbackRate,
                isPlaying: player.isPlaying,
                isBuffering: player.isBuffering,
                isSeekInFlight: player.isSeekInFlight,
                playbackEnded: player.playbackEnded
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}

private struct OfflineDanmakuCanvasView: UIViewRepresentable {
    let cid: Int
    let folderURL: URL
    let scaleMode: VideoScaleMode
    let picture: CGRect
    let isFullscreen: Bool
    let mediaTime: TimeInterval
    let duration: TimeInterval
    let playbackRate: Float
    let isPlaying: Bool
    let isBuffering: Bool
    let isSeekInFlight: Bool
    let playbackEnded: Bool

    func makeUIView(context _: Context) -> OfflineDanmakuHostView {
        let view = OfflineDanmakuHostView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: OfflineDanmakuHostView, context _: Context) {
        uiView.configure(
            cid: cid,
            folderURL: folderURL,
            scaleMode: scaleMode,
            picture: picture,
            isFullscreen: isFullscreen
        )
        uiView.syncPlayback(
            mediaTime: mediaTime,
            duration: duration,
            rate: playbackRate,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            isSeekInFlight: isSeekInFlight,
            playbackEnded: playbackEnded
        )
    }

    static func dismantleUIView(_ uiView: OfflineDanmakuHostView, coordinator _: ()) {
        uiView.teardown()
    }
}

private final class OfflineDanmakuPreferenceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    nonisolated(unsafe) weak var host: OfflineDanmakuHostView?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func install() {
        let names: [Notification.Name] = [
            UserDefaults.didChangeNotification,
            .danmakuPreferencesCommit,
        ]
        let installed = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == UserDefaults.didChangeNotification,
                   note.object as? UserDefaults !== UserDefaults.standard {
                    return
                }
                MainActor.assumeIsolated {
                    self?.host?.applyRenderPreferenceChange()
                }
            }
        }
        lock.lock()
        tokens = installed
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let installed = tokens
        tokens = []
        lock.unlock()
        for token in installed {
            center.removeObserver(token)
        }
    }

    deinit {
        invalidate()
    }
}

@MainActor
private final class OfflineDanmakuHostView: UIView {
    private struct SyncSnapshot: Equatable {
        let bounds: CGRect
        let picture: CGRect?
        let scaleMode: VideoScaleMode
        let presentation: DanmakuPresentation
        let preferences: DanmakuRenderPreferences
    }

    private struct PlaybackSnapshot {
        var mediaTime: TimeInterval = 0
        var duration: TimeInterval = 0
        var rate: Float = 1
        var isPlaying = false
        var isBuffering = false
        var isSeekInFlight = false
        var playbackEnded = false
    }

    private let controller = DanmakuRenderController()
    private let store = DanmakuSegmentStore(isOfflineOnly: true)
    private var activeCid: Int?
    private var activeFolderURL: URL?
    private var scaleMode: VideoScaleMode = .fit
    private var picture: CGRect?
    private var presentation: DanmakuPresentation = .inline
    private var appliedPreferences = DanmakuRenderPreferences.load()
    private var lastSync: SyncSnapshot?
    private var timing: DanmakuClockSync.LayerTiming?
    private var admittedUntil: TimeInterval = 0
    private var admittedIDs: [String: TimeInterval] = [:]
    private var lastSampledMediaTime: TimeInterval = 0
    private var realignPending = true
    private var playback = PlaybackSnapshot()
    nonisolated(unsafe) private var preferenceObserver: OfflineDanmakuPreferenceObserver?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(controller.container)
        store.onSegmentsLoaded = { [weak self] in
            self?.handleSegmentsLoaded()
        }
        store.onMetadataChanged = { [weak self] in
            self?.handleMetadataChanged()
        }
        let observer = OfflineDanmakuPreferenceObserver()
        preferenceObserver = observer
        observer.host = self
        observer.install()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        preferenceObserver?.invalidate()
        preferenceObserver = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncDisplayScale()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncDisplayScale()
        syncBounds()
    }

    func configure(
        cid: Int,
        folderURL: URL,
        scaleMode: VideoScaleMode,
        picture: CGRect?,
        isFullscreen: Bool
    ) {
        let nextPresentation: DanmakuPresentation = isFullscreen ? .fullscreen : .inline
        if activeCid != cid
            || activeFolderURL?.standardizedFileURL != folderURL.standardizedFileURL {
            activeCid = cid
            activeFolderURL = folderURL
            store.offlineDirectoryURL = folderURL
            store.isOfflineOnly = true
            store.reset(oid: cid)
            admittedUntil = 0
            admittedIDs.removeAll()
            timing = nil
            realignPending = true
            controller.teardown()
        }
        self.scaleMode = scaleMode
        self.picture = picture
        self.presentation = nextPresentation
        syncBounds()
    }

    func syncPlayback(
        mediaTime: TimeInterval,
        duration: TimeInterval,
        rate: Float,
        isPlaying: Bool,
        isBuffering: Bool,
        isSeekInFlight: Bool,
        playbackEnded: Bool
    ) {
        let normalizedTime = mediaTime.isFinite ? max(0, mediaTime) : 0
        let normalizedDuration = duration.isFinite ? max(0, duration) : 0
        playback = PlaybackSnapshot(
            mediaTime: normalizedTime,
            duration: normalizedDuration,
            rate: rate,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            isSeekInFlight: isSeekInFlight,
            playbackEnded: playbackEnded
        )
        pumpClock()
    }

    func teardown() {
        store.suspend()
        admittedIDs.removeAll()
        timing = nil
        realignPending = true
        controller.teardown()
    }

    private func syncDisplayScale() {
        let scale = window?.windowScene?.screen.scale
            ?? (traitCollection.displayScale > 0 ? traitCollection.displayScale : 0)
        if scale > 0 {
            controller.setDisplayScale(scale)
        }
    }

    private func syncBounds() {
        let preferences = DanmakuRenderPreferences.load()
        let snapshot = SyncSnapshot(
            bounds: bounds,
            picture: picture,
            scaleMode: scaleMode,
            presentation: presentation,
            preferences: preferences
        )
        guard snapshot != lastSync else { return }
        lastSync = snapshot
        appliedPreferences = preferences
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if controller.container.frame != bounds {
            controller.container.frame = bounds
        }
        controller.setContainerOpacity(preferences.opacity)
        CATransaction.commit()
        if controller.resize(
            viewport: bounds.size,
            picture: picture,
            presentation: presentation,
            preferences: preferences,
            maskFit: scaleMode
        ) {
            realignPending = true
            admittedIDs.removeAll()
            pumpClock()
        }
    }

    fileprivate func applyRenderPreferenceChange() {
        let preferences = DanmakuRenderPreferences.load()
        guard preferences != appliedPreferences else { return }
        let layout = preferences.layoutChanged(from: appliedPreferences)
        appliedPreferences = preferences
        lastSync = nil
        controller.setContainerOpacity(preferences.opacity)
        if layout {
            controller.retargetLayout(preferences: preferences)
        }
        syncBounds()
        pumpClock()
    }

    private func handleSegmentsLoaded() {
        guard !store.isServerClosed else { return }
        let lookback = Self.visibleLookback()
        admittedUntil = playback.mediaTime - lookback
        pumpClock()
    }

    private func handleMetadataChanged() {
        if store.isServerClosed {
            controller.teardown()
            admittedIDs.removeAll()
            timing = nil
            return
        }
        realignPending = true
        pumpClock()
    }

    private func pumpClock() {
        guard activeCid != nil, !store.isServerClosed else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let mediaTime = playback.mediaTime
        let lookback = Self.visibleLookback()
        if realignPending
            || mediaTime + 1 < admittedUntil
            || abs(mediaTime - lastSampledMediaTime) > 2.5 {
            realignPending = false
            admittedUntil = mediaTime - lookback
            admittedIDs.removeAll()
            timing = nil
            controller.seeked(to: mediaTime)
        }
        lastSampledMediaTime = mediaTime

        store.advance(to: mediaTime, duration: playback.duration)
        controller.reclaimFinished(at: mediaTime)

        let from = admittedUntil
        let end = store.admitCursor(from: from, to: mediaTime)
        let bullets = store.elements(from: from, to: end)
        admitUnique(bullets, at: mediaTime, lookback: lookback)
        admittedUntil = end

        syncTransport(at: mediaTime)
    }

    private func admitUnique(
        _ items: [DanmakuElem],
        at mediaTime: TimeInterval,
        lookback: TimeInterval
    ) {
        let oldestVisible = mediaTime - lookback
        admittedIDs = admittedIDs.filter { $0.value >= oldestVisible }
        let unique = items.filter { item in
            guard let key = item.identityKey else { return true }
            if admittedIDs[key] != nil { return false }
            admittedIDs[key] = item.progress
            return true
        }
        if !unique.isEmpty {
            controller.admit(unique, laneHeight: 28)
        }
    }

    private func syncTransport(at mediaTime: TimeInterval) {
        let host = CACurrentMediaTime()
        let effectiveRate = playback.rate.isFinite && playback.rate > 0 ? Double(playback.rate) : 0
        let transportPlaying = playback.isPlaying
            && !playback.isBuffering
            && !playback.isSeekInFlight
            && !playback.playbackEnded
            && effectiveRate > 0
        if let applied = timing {
            let expectedSpeed = transportPlaying ? effectiveRate : 0
            if applied.speed == expectedSpeed,
               !DanmakuClockSync.needsResync(under: applied, mediaTime: mediaTime, atHostTime: host) {
                return
            }
        }
        let next = DanmakuClockSync.transitionTiming(
            previous: timing,
            mediaTime: mediaTime,
            rate: effectiveRate,
            isPlaying: transportPlaying,
            hostTime: host
        )
        guard next != timing else { return }
        let anchorTime = DanmakuClockSync.localTime(under: next, atHostTime: host)
        controller.applyTiming(next, mediaTime: anchorTime)
        timing = next
    }

    private static func visibleLookback() -> TimeInterval {
        let fixedLifetime = DanmakuTrackLayout.Metrics(width: 1, laneCount: 1).fixedLifetime
        let scrollLifetime = DanmakuRenderPreferences.load().scrollLifetime
        return max(scrollLifetime, fixedLifetime, PlayerViewModel.danmakuMode7LifetimeCeiling)
    }
}

struct OfflinePlaybackAsset: Equatable {
    let videoURL: URL
    let audioURL: URL?
    let aid: Int
    let cid: Int
    let quality: Int
    let codecs: String
    let durationSeconds: Int
    let title: String
    let artist: String
    let cover: String?
}

struct OfflinePlaybackRecoveryRequest: Equatable {
    let asset: OfflinePlaybackAsset
    let position: TimeInterval
}

enum OfflinePlaybackRecoveryPolicy {
    static func request(
        for asset: OfflinePlaybackAsset,
        position: TimeInterval
    ) -> OfflinePlaybackRecoveryRequest {
        let finitePosition = position.isFinite ? position : 0
        let upperBound = max(0, TimeInterval(asset.durationSeconds))
        return OfflinePlaybackRecoveryRequest(
            asset: asset,
            position: min(max(0, finitePosition), upperBound)
        )
    }
}

enum OfflineResumePolicy {
    static let minimumSeconds: TimeInterval = 2
    static let completionMarginSeconds: TimeInterval = 5

    static func storedPosition(position: TimeInterval, durationSeconds: Int) -> Int {
        guard position.isFinite, position > minimumSeconds else { return 0 }
        let duration = TimeInterval(max(0, durationSeconds))
        guard duration > 0 else { return Int(position) }
        guard position < duration - completionMarginSeconds else { return 0 }
        return Int(position)
    }
}

enum OfflinePlaybackAssetValidator {
    static func allows(videoURL: URL, audioURL: URL?) -> Bool {
        allowsFile(videoURL) && (audioURL == nil || allowsFile(audioURL!))
    }

    private static func allowsFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey, .fileSizeKey
              ]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0 else {
            return false
        }
        return true
    }
}
