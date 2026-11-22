import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func beginHoldFastForward() {
        // backend seek-in-flight is required truth. Also keep the VM display
        // pin (reopen arms it before playURL sets backend pending) so hold does
        // not straddle ES_OUT_RESET_PCR during the snapshot→open gap.
        guard supportsHoldFastForward, isPlaying, rateBeforeHold == nil,
              !isSeekInFlight, pendingSeekTarget == nil else { return }
        // Save AFTER setRate: setRate cancels any hold-restore (an explicit
        // speed pick during hold must survive the release), and would
        // otherwise wipe the value we just stored.
        let saved = playbackRate
        // Flushing meant a seek/reopen at the current position, which (a) on 4K rides the same reopen-seek
        // that stalls for 8s+ — so 2x "never engaged" — and (b) re-adds the DASH audio slave mid-rate, hitting
        // the slave/PCR desync that silenced audio.
        setRate(2.0)
        rateBeforeHold = saved
    }

    func endHoldFastForward() {
        guard let saved = rateBeforeHold else { return }
        rateBeforeHold = nil
        setRate(saved)
    }

    /// Reapplied on every readyToPlay — each playURL builds a fresh
    /// render view with the default (fit) gravity.
    func applyScaleMode() {
        backend.setScaleMode(scaleMode)
    }

    /// Applies continuation preferences immediately. VLC's automatic PiP
    /// capability is immutable per drawable, so its backend returns whether
    /// the render container must attach a replacement host.
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

    /// Seeking to the current position forces a flush + clock re-anchor so the new rate takes effect from ~now.
    func setRate(_ rate: Float, flushPipeline: Bool = false) {
        guard mode.supportsPlaybackRate else { return }
        // Picking a rate from the speed menu while hold-2x is active used
        // to be silently reverted on finger release — the explicit choice
        // wins, so drop the pending restore.
        rateBeforeHold = nil
        let changed = playbackRate != rate
        let wall = CFAbsoluteTimeGetCurrent()
        if changed {
            // Correlate with [PlayerGesture] hold wall= and libVLC "changing rate".
            // (Hold sets rateBeforeHold AFTER setRate — see beginHoldFastForward.)
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

        // Flush the stale-rate pipeline by reopening at the current position.
        if flushPipeline, changed, backend.isReadyToPlay,
           !isSeekInFlight, pendingSeekTarget == nil {
            seek(to: resumeTargetTime)
        }
    }

    /// In-player audio tier pick: a position-preserving reload of the same
    /// video, exactly like a resolution switch. The pick outlives every reload
    /// of this content but is not persisted — Settings owns the preference.
    func switchAudioQuality(_ tier: AudioQualityTier) async {
        guard mode.usesOnlineVODServices else {
            PlayerLog.log("[Player] audio quality switch ignored for offline/local playback")
            return
        }
        guard tier != playingAudioTier else { return }
        retireCDNSwitchForNewIntent()
        // Same position rule as `switchQuality`: the seek target during an
        // in-flight seek, the media clock otherwise, never the wall-clock
        // presentation value near EOF.
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
        // The new pick owns intent before its asynchronous load worker starts.
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

    /// Human label for a quality code, falling back to the raw code.
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
        // Deferred: seeking from inside the onPlay callback risks
        // re-entering the player's state machine.
        Task { @MainActor [weak self] in
            self?.seek(to: seg.end)
        }
    }

    /// Uses `isMuted` (not `playbackVolume`) so it never collides with the align machine, which owns the volume
    /// channel for priming.
    private func setSponsorAudioMuted(_ muted: Bool) {
        setMute(.sponsorSegment, muted)
    }

    func autoSkipSponsorIfNeeded(at time: TimeInterval) {
        guard mode.usesOnlineVODServices, pendingSeekTarget == nil else { return }
        let manager = SponsorBlockManager.shared
        // Disabling SponsorBlock was already effective, but only as a side-effect: `clear()` nils `loadedCID`,
        // so the identity guard below happened to return for any VOD.
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

        // Surface / clear the manual-skip prompt for the current position.
        // Only reassign on change — this runs every clock tick and an
        // unconditional set would wake observers needlessly.
        let manual = manager.manualSegment(at: time)
        if manual?.uuid != pendingSponsorManualSegment?.uuid {
            pendingSponsorManualSegment = manual
        }

        // Mute segments — silence the audio while inside, restore on exit.
        // Asserted every tick (state-driven) so it survives reloads.
        if let muteSeg = manager.muteSegment(at: time) {
            if sponsorMutedUUID != muteSeg.uuid {
                sponsorMutedUUID = muteSeg.uuid
                setSponsorAudioMuted(true)
                // Notice + telemetry once per load (the dedup set is shared
                // with skips and reset on content change), so a reload back
                // into the same segment re-mutes silently.
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

        // Throttle only the auto-skip seek (not mute/manual, handled above):
        // back-to-back segments shouldn't fire two seeks in one instant.
        guard CACurrentMediaTime() - lastSponsorSkipAt > 1.0 else { return }
        guard let seg = manager.autoSkipSegment(at: time, excluding: sponsorSkippedUUIDs) else { return }
        lastSponsorSkipAt = CACurrentMediaTime()
        sponsorSkippedUUIDs.insert(seg.uuid)
        manager.recordSkip(seconds: seg.duration, uuid: seg.uuid)
        PlayerLog.log("[SponsorBlock] auto-skip \(seg.category.apiValue) (\(Int(seg.start))s → \(Int(seg.end))s)")
        if manager.showSkipNotice {
            showNotice(String(format: String(localized: "Skipped %@"), seg.category.displayName))
        }
        Task { @MainActor [weak self] in
            self?.seek(to: seg.end)
        }
    }

    /// Manually skip the segment currently under the button (user tap).
    func skipSponsorSegment(_ seg: SponsorSegment) {
        sponsorSkippedUUIDs.insert(seg.uuid)
        pendingSponsorManualSegment = nil
        SponsorBlockManager.shared.recordSkip(seconds: seg.duration, uuid: seg.uuid)
        seek(to: seg.end)
    }
}
