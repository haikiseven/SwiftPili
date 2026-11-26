import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func beginHoldFastForward() {
        guard supportsHoldFastForward, isPlaying, rateBeforeHold == nil,
              !isSeekInFlight, pendingSeekTarget == nil else { return }
        let saved = playbackRate
        setRate(2.0)
        rateBeforeHold = saved
    }

    func endHoldFastForward() {
        guard let saved = rateBeforeHold else { return }
        rateBeforeHold = nil
        setRate(saved)
    }

    func applyScaleMode() {
        backend.setScaleMode(scaleMode)
    }

    func applyPlaybackContinuationSettings() {
        let configuration = PlayerPlaybackPreferences.playbackContinuationConfiguration
        if usesDemandPresentationContinuity,
           !configuration.allowsAutomaticPiP,
           (backend.isPiPActive || backend.hasObservedPiPLease) {
            let epoch = lifecycleRecovery.ensureDemandPresentationEpoch()
            if let fence = makeDemandPresentationFence(epoch: epoch) {
                dispatchDemandPresentation(.forceRetirePiP(
                    fence: fence,
                    authority: .capabilityRevocation
                ))
            }
        }
        let result = backend.applyPlaybackContinuationConfiguration(configuration)
        PlayerLog.log(
            "[PiP] configuration applied backgroundAudio=" +
            "\(configuration.backgroundAudioEnabled ? 1 : 0) pictureInPicture=" +
            "\(configuration.pictureInPictureEnabled ? 1 : 0) " +
            "hostRevision=\(result.hostRevision)"
        )
        if result.requiresRenderAttachment {
            reattachInlineSurface()
            PlayerLog.log(
                "[PiP] continuation setting rebuilt inline host " +
                "revision=\(result.hostRevision) generation=\(playerGeneration)"
            )
        }
        guard configuration.allowsAutomaticPiP else {
            if activeBackendKind == .demandPaced { return }
            if backend.isPiPActive || backend.hasObservedPiPLease {
                PlayerLog.log("[PiP] continuation setting disabled — dismissing PiP")
                backend.stopPiP()
            }
            return
        }
    }

    func setRate(_ rate: Float, flushPipeline: Bool = false) {
        guard mode.supportsPlaybackRate else { return }
        rateBeforeHold = nil
        let changed = playbackRate != rate
        let wall = CFAbsoluteTimeGetCurrent()
        if changed {
            PlayerLog.log(String(
                format: "[Player] setRate %.2f→%.2f flush=%@ wall=%.3f",
                playbackRate, rate,
                flushPipeline ? "y" : "n",
                wall
            ))
        }
        playbackRate = rate
        backend.playbackRate = rate
        syncDanmakuTransport()
        pushNowPlayingPlayback(edge: .rateChanged)

        if flushPipeline, changed, backend.isReadyToPlay,
           !isSeekInFlight, pendingSeekTarget == nil {
            seek(to: resumeTargetTime)
        }
    }

    func switchAudioQuality(_ tier: AudioQualityTier) async {
        guard mode.usesOnlineVODServices else {
            PlayerLog.log("[Player] audio quality switch ignored for offline/local playback")
            return
        }
        guard tier != playingAudioTier else { return }
        retireCDNSwitchForNewIntent()
        let savedTime = resumeTargetTime
        audioTierOverride = tier
        let reloadOwnerLease = currentOwnerLease

        if let aid = currentAid, let cid = currentCid {
            resumeAtTime = savedTime > 2 ? savedTime : nil
            await loadVOD(
                aid: aid,
                cid: cid,
                quality: currentQuality,
                source: currentSource,
                preservePlayState: true,
                ownerLease: reloadOwnerLease
            )
        }
    }

    func switchQuality(_ quality: Int) async {
        guard mode.usesOnlineVODServices else {
            PlayerLog.log("[Player] quality switch ignored for offline/local playback")
            return
        }
        retireCDNSwitchForNewIntent()
        let savedTime = resumeTargetTime
        currentQuality = quality
        let reloadOwnerLease = currentOwnerLease

        if let aid = currentAid, let cid = currentCid {
            resumeAtTime = savedTime > 2 ? savedTime : nil
            await loadVOD(
                aid: aid,
                cid: cid,
                quality: quality,
                source: currentSource,
                preservePlayState: true,
                ownerLease: reloadOwnerLease
            )
        }
    }

    static func qualityLabel(for code: Int) -> String {
        qualityMap[code] ?? "\(code)"
    }
}

extension PlayerViewModel {

    func autoSkipIfNeeded(at time: TimeInterval) {
        guard mode.usesOnlineVODServices, !skipSegments.isEmpty, PlayerPlaybackPreferences.animeSkipIntroOutro,
              pendingSeekTarget == nil,
              CACurrentMediaTime() - lastAutoSkipAt > 2.0,
              let seg = skipSegments.first(where: {
                  time >= $0.start && time < $0.end - 1.5
                      && !autoSkippedSegmentKeys.contains("\($0.label)@\($0.start)")
              })
        else { return }
        lastAutoSkipAt = CACurrentMediaTime()
        autoSkippedSegmentKeys.insert("\(seg.label)@\(seg.start)")
        PlayerLog.log("[Player] auto-skip \(seg.label) (\(Int(seg.start))s → \(Int(seg.end))s)")
        showNotice(seg.label == "OP" ? String(localized: "Skipped intro") : String(localized: "Skipped outro"))
        Task { @MainActor [weak self] in
            self?.seek(to: seg.end)
        }
    }

    private func setSponsorAudioMuted(_ muted: Bool) {
        setMute(.sponsorSegment, muted)
    }

    func autoSkipSponsorIfNeeded(at time: TimeInterval) {
        guard mode.usesOnlineVODServices, pendingSeekTarget == nil else { return }
        let manager = SponsorBlockManager.shared
        guard manager.isEnabled else {
            if pendingSponsorManualSegment != nil { pendingSponsorManualSegment = nil }
            if sponsorMutedUUID != nil { sponsorMutedUUID = nil; setSponsorAudioMuted(false) }
            return
        }
        guard manager.loadedCID == currentCid else {
            if pendingSponsorManualSegment != nil { pendingSponsorManualSegment = nil }
            if sponsorMutedUUID != nil { sponsorMutedUUID = nil; setSponsorAudioMuted(false) }
            return
        }

        let manual = manager.manualSegment(at: time)
        if manual?.uuid != pendingSponsorManualSegment?.uuid {
            pendingSponsorManualSegment = manual
        }

        if let muteSeg = manager.muteSegment(at: time) {
            if sponsorMutedUUID != muteSeg.uuid {
                sponsorMutedUUID = muteSeg.uuid
                setSponsorAudioMuted(true)
                if !sponsorSkippedUUIDs.contains(muteSeg.uuid) {
                    sponsorSkippedUUIDs.insert(muteSeg.uuid)
                    manager.recordMute(uuid: muteSeg.uuid)
                    PlayerLog.log("[SponsorBlock] mute \(muteSeg.category.apiValue) (\(Int(muteSeg.start))s → \(Int(muteSeg.end))s)")
                    if manager.showSkipNotice {
                        showNotice(String(format: String(localized: "Muted %@"), muteSeg.category.displayName))
                    }
                }
            }
        } else if sponsorMutedUUID != nil {
            sponsorMutedUUID = nil
            setSponsorAudioMuted(false)
        }

        guard CACurrentMediaTime() - lastSponsorSkipAt > 1.0 else { return }
        guard let seg = manager.autoSkipSegment(at: time, excluding: sponsorSkippedUUIDs) else { return }
        lastSponsorSkipAt = CACurrentMediaTime()
        let originTime = max(0, seg.start)
        let segDuration = seg.duration
        let skipLoadGen = loadGeneration
        sponsorSkippedUUIDs.insert(seg.uuid)
        manager.recordSkip(seconds: segDuration, uuid: seg.uuid)
        PlayerLog.log("[SponsorBlock] auto-skip \(seg.category.apiValue) (\(Int(seg.start))s → \(Int(seg.end))s)")
        if manager.showSkipNotice {
            showInteractiveNotice(
                text: String(format: String(localized: "Skipped %@"), seg.category.displayName),
                actionTitle: String(localized: "Undo"),
                duration: 5.0
            ) { [weak self] in
                guard let self, self.loadGeneration == skipLoadGen else { return }
                SponsorBlockManager.shared.revertSkip(seconds: segDuration)
                self.seek(to: originTime)
            }
        }
        Task { @MainActor [weak self] in
            self?.seek(to: seg.end)
        }
    }

    func skipSponsorSegment(_ seg: SponsorSegment) {
        sponsorSkippedUUIDs.insert(seg.uuid)
        pendingSponsorManualSegment = nil
        SponsorBlockManager.shared.recordSkip(seconds: seg.duration, uuid: seg.uuid)
        seek(to: seg.end)
    }
}
