import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Play a downloaded video from local files. The asset is retained as the
    /// sole authority for retry and lifecycle recovery; no offline action may
    /// manufacture an online VOD load from its aid/cid.
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

        // Validate the local authority before claiming the shared renderer.
        // A deleted/corrupt download must not steal ownership from an
        // already-playing screen or manufacture an empty offline session.
        let lease = claimOwnerLease(owner: owner)
        guard ownerKey == owner else { return nil }

        // A same-owner view can be recreated while the shared backend is still playing this asset.
        if mode != .offline || offlineAsset != asset || currentURL == nil {
            startOfflinePlayback(asset, at: resumeAt ?? 0, preservePlayState: false)
        } else {
            // Keeping the session means no loader runs, and the loaders are the only consumers of the
            // owner-change presentation latch.
            presentationResetPendingForOwnerChange = false
            if stats.decoderType.isEmpty {
                prepareOfflineDecoderLabel(for: asset)
            }
        }
        return lease
    }

    /// Offline pager activation under the screen's existing lease. Unlike the
    /// public single-item entry above, this never advances owner generation.
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
        startOfflinePlayback(asset, at: resumeAt ?? 0, preservePlayState: false)
        return isCurrentOwner(lease)
    }

    func startOfflinePlayback(
        _ asset: OfflinePlaybackAsset,
        at requestedPosition: TimeInterval,
        preservePlayState: Bool,
        mediaResetID: UUID? = nil
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
        let teardownReason = PlayerReloadPresentationPolicy.reason(
            targetMode: .offline,
            currentMode: mode,
            sameContent: sameContent,
            newOwner: presentationResetPendingForOwnerChange
        )
        // A normal source load (including queue-next/new-content) is a new playback admission, not a
        // replay/recovery of the previous terminal item.
        playbackTerminalState = .active
        if !sameContent {
            nowPlayingMeta = nil
        }
        stop(reason: teardownReason, mediaResetID: mediaResetID)
        presentationResetPendingForOwnerChange = false
        // Same rule as the VOD path: only live is routed by capability.
        restorePreferredBackendForLoad("offline load")
        resetMultiConnectionDisplay()
        loadGeneration += 1
        if let mediaResetID { mediaResetRecovery.bind(mediaResetID, loadGeneration: loadGeneration) }
        mode = .offline
        armDurableResumeTarget(nil, source: "offline-load")
        offlineAsset = asset
        currentAid = asset.aid
        currentCid = asset.cid
        currentBvid = nil
        currentSource = .ugc
        currentRoomID = nil
        currentQuality = asset.quality
        currentVideoIsAV1 = VideoCodecPreference.av1.matches(asset.codecs)
        isPortraitContent = sameContent ? isPortraitContent : false
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
        // A new load is a new verdict: a refusal belongs to the source that
        // produced it, and carrying it forward would make the successor
        // unplayable and un-retryable before it ever asked the server.
        unavailability = nil
        availableQualities = []
        availableCodecs = []
        availableAudioTiers = []
        playingAudioTier = nil
        skipSegments = []
        streamNominalBitrate = 0 // no delivery-health demand target for a local file
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
            resumeIsFromHistory = false
            mediaTime = startAt
        }
        // Before playURL: its tail pushes nowPlayingMeta to the Now Playing card.
        setNowPlaying(title: asset.title, artist: asset.artist, cover: asset.cover)
        playURL(
            asset.videoURL,
            audioURL: asset.audioURL,
            startAt: startAt > 2 ? startAt : 0
        )
        // Where the two VOD success paths call startHistoryReporting(). The
        // preceding stop() cancelled the outgoing session's task after flushing
        // it, so this is the one arming site for the incoming part.
        startOfflineProgressPersistence()
        PlayerLog.log(
            "[Player] offline asset opened qn=\(asset.quality) split=\(asset.audioURL == nil ? 0 : 1)"
        )
    }

    /// Offline transport starts synchronously. Only its support label waits for
    /// the shared snapshot; pending means unknown rather than software decode.
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
}

/// Everything required to reopen one validated download without consulting
/// playurl, CDN selection, persistence, or another screen.
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

/// Store beginning and completed positions as zero so the next offline open starts a fresh pass.
enum OfflineResumePolicy {
    /// The same `> 2` floor `startOfflinePlayback` and the VOD resume sites
    /// already apply before they arm a target.
    static let minimumSeconds: TimeInterval = 2
    /// `admitNaturalPlaybackEnd` snaps media truth to `duration`, so a natural end lands exactly on the bound;
    /// the margin also covers a stream whose last frame falls short of its stated duration and one the user
    /// scrubbed to within a few seconds of the end before leaving.
    static let completionMarginSeconds: TimeInterval = 5

    static func storedPosition(position: TimeInterval, durationSeconds: Int) -> Int {
        guard position.isFinite, position > minimumSeconds else { return 0 }
        let duration = TimeInterval(max(0, durationSeconds))
        // No stated duration is no completion verdict, not a completion: keep
        // the position and let the read side clamp it against the real asset.
        guard duration > 0 else { return Int(position) }
        guard position < duration - completionMarginSeconds else { return 0 }
        return Int(position)
    }
}

/// Offline admission is deliberately separate from CDNHostPolicy: local
/// playback must never be treated as a network source, but it still needs a
/// real, non-empty media file before authority or the backend is touched.
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
