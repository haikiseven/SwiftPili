import AVFoundation
import Foundation
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
            startOfflinePlayback(asset, at: resumeAt ?? 0, preservePlayState: false)
        } else {
            presentationResetPendingForOwnerChange = false
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
        playbackTerminalState = .active
        if !sameContent {
            nowPlayingMeta = nil
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
            resumeIsFromHistory = false
            mediaTime = startAt
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
