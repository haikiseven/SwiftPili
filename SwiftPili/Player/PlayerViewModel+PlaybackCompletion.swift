import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    @discardableResult
    func standDownLifecycleForTerminalPlayback() -> Bool {
        let state = currentPlaybackTerminalState
        guard state.isTerminal else { return false }
        if let recoveryCover { clearRecoveryCover(matching: recoveryCover.identity) }
        retireCDNFrameCover()
        retireCDNSwitch()
        noteDanmakuTerminalPlaybackEdge()
        if lifecycleRecovery.terminalState != state {
            lifecycleRecovery.enterTerminal(state)
        }
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = nil
        demandContinuationOperationRunner?.cancelCurrent()
        demandForegroundStageTape = nil
        demandBackgroundStageTape = nil
        demandPresentationLiveness.invalidate()
        return true
    }

    func synchronizeTerminalAdmissionFromBackend() {
        guard backendKind == .demandPaced,
              currentPlaybackTerminalState == .active,
              backend.isReadyToPlay,
              case .requiresRecovery(.terminal) = backend.retainedPipelineHealth.state
        else { return }
        PlayerLog.log("[Player] terminal admission reconciled from Demand EOF")
        admitNaturalPlaybackEnd()
    }

    func admitNaturalPlaybackEnd() {
        guard currentPlaybackTerminalState == .active else {
            if playbackTerminalState == .ended {
                PlayerLog.log("[Player] playedToTheEnd (repeat) — end policy already applied")
            } else {
                PlayerLog.log("[Player] playedToTheEnd ignored after terminal state")
            }
            return
        }

        retireStreamRecovery(reason: "ended")
        PlayerLog.log("[Player] playedToTheEnd")
        playbackTerminalState = .ended
        isBuffering = false
        pendingSeekTarget = nil
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        standDownLifecycleForTerminalPlayback()
        if usesDemandPresentationContinuity {
            dispatchDemandPresentation(.playbackEnded)
        }
        updateDemandVideoLivenessContext()
        clearNearEndStall()
        if duration > 0 {
            mediaTime = duration
            bufferedTime = max(bufferedTime, duration)
        }
        reportCompletionNow()
        persistOfflineProgressNow()
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()

        let stopAfterCurrentVideo = sleepTimer.consumeEndOfVideoIfArmed()
        let settlesImmediatelyInForeground = !mode.isSeekable
            || stopAfterCurrentVideo
            || playbackOrder == .pauseAtEnd
            || (playbackOrder == .playNext && (isForegroundInteractiveForEndedCountdown || !hasEndedAutoAdvanceTarget))
        if settlesImmediatelyInForeground, miniPlayer.activeSession == nil {
            hideControlsTask?.cancel()
            hideControlsTask = nil
            if !showControls {
                showControls = true
            }
        }

        let endedGeneration = playerGeneration
        let endedLoadGeneration = loadGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.playerGeneration == endedGeneration,
                  self.loadGeneration == endedLoadGeneration,
                  self.playbackTerminalState == .ended else { return }
            if stopAfterCurrentVideo {
                self.handleSleepTimerExpired(reason: .endOfVideo)
                return
            }
            self.applyEndOfPlaybackOrder(
                endedGeneration: endedGeneration,
                endedLoadGeneration: endedLoadGeneration
            )
        }
    }

    // MARK: - Durable Playback Queue

    var activePlaylistQueue: PlaybackQueueContext? {
        guard let queue = playbackQueue, queue.isPlaylist, !queue.isEmpty else {
            return nil
        }
        return queue
    }

    func setPlaybackQueue(
        _ queue: PlaybackQueueContext?,
        liveNavigationHandler: ((Int) -> Bool)? = nil
    ) {
        playbackQueue = queue
        liveQueueNavigationHandler = queue == nil ? nil : liveNavigationHandler
        if queue == nil {
            liveQueueItemSelectionHandler = nil
        }
        syncPlaybackQueueCallbacks()
    }

    func clearPlaybackQueue() {
        cancelEndedAutoAdvance()
        autonomousQueueAdvanceGeneration &+= 1
        autonomousQueueAdvanceTask?.cancel()
        autonomousQueueAdvanceTask = nil
        isAutonomousQueueAdvanceInFlight = false
        liveQueueNavigationHandler = nil
        liveQueueItemSelectionHandler = nil
        playbackQueue = nil
        syncPlaybackQueueCallbacks()
    }

    func setPlaylistOrderMode(_ mode: PlaylistOrderMode) {
        PlaylistOrderMode.savePreferred(mode)
        guard let current = playbackQueue else { return }
        if current.isPlaylist {
            session.playbackOrder = .playNext
        }
        playbackQueue = current.settingOrderMode(mode)
        syncPlaybackQueueCallbacks()
    }

    @discardableResult
    func jumpToPlaylistItem(id: String) -> Bool {
        cancelEndedAutoAdvance()
        guard let (nextQueue, nextItem) = playbackQueue?.selecting(id: id) else {
            return false
        }
        if nextItem.aid == currentAid,
           nextItem.cid == currentCid,
           nextItem.source == currentSource,
           !currentPlaybackTerminalState.isTerminal,
           currentURL != nil {
            playbackQueue = nextQueue
            syncPlaybackQueueCallbacks()
            if !isPlaying {
                play()
            }
            return true
        }
        if !isMiniPlayerActive,
           !isFullscreen,
           let itemHandler = liveQueueItemSelectionHandler {
            let previousQueue = playbackQueue
            playbackQueue = nextQueue
            syncPlaybackQueueCallbacks()
            if itemHandler(nextItem) {
                return true
            }
            playbackQueue = previousQueue
            syncPlaybackQueueCallbacks()
        }
        return beginAutonomousQueueAdvance(to: nextQueue, item: nextItem)
    }

    func movePlaylistItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let current = playbackQueue else { return }
        playbackQueue = current.movingItems(fromOffsets: source, toOffset: destination)
        syncPlaybackQueueCallbacks()
    }

    func removePlaylistItem(id: String) {
        guard let current = playbackQueue else { return }
        let removedItem = current.items.first(where: { $0.id == id })
        let (updatedQueue, removedActiveItem) = current.removingItem(id: id)
        if let removedItem {
            let stillHasAid = updatedQueue?.items.contains(where: { $0.aid == removedItem.aid }) ?? false
            PlaylistQueueLauncher.shared.noteItemRemoved(
                aid: removedItem.aid,
                itemID: removedItem.id,
                removeWholeVideo: !stillHasAid
            )
        }
        guard let updatedQueue else {
            exitPlaylistMode()
            return
        }
        playbackQueue = updatedQueue
        syncPlaybackQueueCallbacks()
        guard removedActiveItem, let nextItem = updatedQueue.currentItem else { return }
        if !isMiniPlayerActive,
           !isFullscreen,
           let itemHandler = liveQueueItemSelectionHandler,
           itemHandler(nextItem) {
            return
        }
        _ = beginAutonomousQueueAdvance(to: updatedQueue, item: nextItem)
    }

    func exitPlaylistMode() {
        cancelEndedAutoAdvance()
        PlaylistQueueLauncher.shared.cancel()
        autonomousQueueAdvanceGeneration &+= 1
        autonomousQueueAdvanceTask?.cancel()
        autonomousQueueAdvanceTask = nil
        isAutonomousQueueAdvanceInFlight = false
        guard playbackQueue?.isPlaylist == true else { return }
        liveQueueNavigationHandler = nil
        liveQueueItemSelectionHandler = nil
        playbackQueue = nil
        syncPlaybackQueueCallbacks()
        PlayerLog.log("[Queue] exited playlist mode while keeping current playback active")
    }

    func syncPlaybackQueueCallbacks() {
        isSyncingQueueCallbacks = true
        defer { isSyncingQueueCallbacks = false }
        if let queue = playbackQueue {
            hasExternalPreviousEpisodeCallback = false
            hasExternalNextEpisodeCallback = false
            hasExternalPlaybackEndedCallback = false
            onPreviousEpisode = queue.hasPrevious
                ? { [weak self] in _ = self?.advancePlaybackQueue(by: -1, allowingExternalClosureFallback: false) }
                : nil
            onNextEpisode = queue.hasNext
                ? { [weak self] in _ = self?.advancePlaybackQueue(by: 1, allowingExternalClosureFallback: false) }
                : nil
            onPlaybackEnded = queue.hasNext
                ? { [weak self] in _ = self?.advancePlaybackQueue(by: 1, allowingExternalClosureFallback: false) }
                : nil
        } else {
            if !hasExternalPreviousEpisodeCallback { onPreviousEpisode = nil }
            if !hasExternalNextEpisodeCallback { onNextEpisode = nil }
            if !hasExternalPlaybackEndedCallback { onPlaybackEnded = nil }
        }
        syncNowPlayingTrackCommands()
    }

    @discardableResult
    func playNextInQueue() -> Bool {
        advancePlaybackQueue(by: 1)
    }

    @discardableResult
    func playPreviousInQueue() -> Bool {
        advancePlaybackQueue(by: -1)
    }

    @discardableResult
    func advancePlaybackQueue(
        by offset: Int,
        allowingExternalClosureFallback: Bool = true
    ) -> Bool {
        guard offset != 0 else { return false }
        cancelEndedAutoAdvance()
        if !isMiniPlayerActive,
           let liveHandler = liveQueueNavigationHandler,
           liveHandler(offset) {
            return true
        }
        if let (nextQueue, nextItem) = playbackQueue?.advancing(by: offset) {
            if !isMiniPlayerActive,
               !isFullscreen,
               let itemHandler = liveQueueItemSelectionHandler {
                let previousQueue = playbackQueue
                playbackQueue = nextQueue
                syncPlaybackQueueCallbacks()
                if itemHandler(nextItem) {
                    return true
                }
                playbackQueue = previousQueue
                syncPlaybackQueueCallbacks()
            }
            return beginAutonomousQueueAdvance(to: nextQueue, item: nextItem)
        }
        guard allowingExternalClosureFallback else { return false }
        if offset > 0, hasExternalNextEpisodeCallback, let handler = onNextEpisode {
            handler()
            return true
        }
        if offset < 0, hasExternalPreviousEpisodeCallback, let handler = onPreviousEpisode {
            handler()
            return true
        }
        return false
    }

    func applyAutonomousQueueAdvanceState(
        to nextQueue: PlaybackQueueContext,
        item: PlaybackQueueItem,
        ownerLease: PlayerOwnerLease
    ) {
        playbackQueue = nextQueue
        playbackTerminalState = .active
        playbackIntent = .playing
        syncPlaybackQueueCallbacks()
        setAmbientCoverURL(item.coverURL, ownerLease: ownerLease)

        if case .bangumiSeason(let seasonId) = nextQueue.kind {
            pgcSeasonContext = (sid: seasonId, type: item.pgcSeasonType)
        } else {
            pgcSeasonContext = nil
        }

        if !item.opEdSegments.isEmpty {
            skipSegments = item.skipSegmentTuples
        } else {
            skipSegments = []
        }

        let updatedPortrait = item.isPortraitHint.map {
            DeviceCapability.usesCompactPortraitVideoFraming && $0
        }
        miniPlayer.updateActiveSession(
            matching: ownerLease,
            title: item.title,
            coverURL: item.coverURL,
            originRoute: item.originRoute,
            originScreenRoute: item.originScreenRoute,
            isPortrait: updatedPortrait
        )
        setNowPlaying(title: item.title, artist: item.artist, cover: item.coverURL)
    }

    @discardableResult
    func beginAutonomousQueueAdvance(
        to nextQueue: PlaybackQueueContext,
        item: PlaybackQueueItem
    ) -> Bool {
        guard let ownerLease = currentOwnerLease else { return false }
        let isSameActiveItem = item.aid == currentAid
            && item.cid == currentCid
            && item.source == currentSource
        if isSameActiveItem {
            if playbackTerminalState == .ended {
                playbackQueue = nextQueue
                syncPlaybackQueueCallbacks()
                restartForLoop()
                return true
            }
            if !currentPlaybackTerminalState.isTerminal, currentURL != nil {
                playbackQueue = nextQueue
                syncPlaybackQueueCallbacks()
                seek(to: 0)
                if !isPlaying {
                    play()
                }
                return true
            }
        }

        autonomousQueueAdvanceGeneration &+= 1
        let advanceGeneration = autonomousQueueAdvanceGeneration
        autonomousQueueAdvanceTask?.cancel()

        applyAutonomousQueueAdvanceState(to: nextQueue, item: item, ownerLease: ownerLease)

        PlayerLog.log(
            "[Queue] autonomous advance → idx=\(nextQueue.currentIndex + 1)/\(nextQueue.items.count) " +
            "aid=\(item.aid) cid=\(item.cid) owner=\(ownerLease.owner)"
        )

        autonomousQueueAdvanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.autonomousQueueAdvanceGeneration == advanceGeneration {
                    self.isAutonomousQueueAdvanceInFlight = false
                    self.autonomousQueueAdvanceTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.autonomousQueueAdvanceGeneration == advanceGeneration,
                  self.isCurrentOwner(ownerLease) else { return }

            let resumeLookup = await Self.serverResumePoint(
                aid: item.aid,
                cid: item.cid,
                duration: item.duration ?? 0,
                ownerLease: ownerLease
            )
            guard !Task.isCancelled,
                  self.autonomousQueueAdvanceGeneration == advanceGeneration,
                  self.isCurrentOwner(ownerLease) else { return }
            guard case .load(let resumeAt) = resumeLookup.loadDecision() else {
                PlayerLog.log(
                    "[Queue] autonomous advance aborted — resume lookup cancelled " +
                    "aid=\(item.aid) cid=\(item.cid)"
                )
                return
            }

            self.isAutonomousQueueAdvanceInFlight = true
            await self.loadVOD(
                aid: item.aid,
                cid: item.cid,
                bvid: item.bvid,
                source: item.source,
                resumeAt: resumeAt,
                portraitHint: item.isPortraitHint,
                aspectRatioHint: item.aspectRatioHint,
                owner: ownerLease.owner,
                ownerLease: ownerLease,
                requestAdmission: { [weak self] in
                    guard let self else { return false }
                    return self.autonomousQueueAdvanceGeneration == advanceGeneration
                        && self.isCurrentOwner(ownerLease)
                }
            )

            guard !Task.isCancelled,
                  self.autonomousQueueAdvanceGeneration == advanceGeneration,
                  self.isCurrentOwner(ownerLease) else { return }

            if case .bangumiSeason(let seasonId) = nextQueue.kind {
                self.pgcSeasonContext = (sid: seasonId, type: item.pgcSeasonType)
            }

            self.syncPlaybackQueueCallbacks()
            guard self.error == nil,
                  self.unavailability == nil,
                  !self.terminalOpenFailure else { return }

            if !item.opEdSegments.isEmpty {
                self.skipSegments = item.skipSegmentTuples
            } else if case .pgc(let epId) = item.source, self.skipSegments.isEmpty {
                let clips = await PGCAPI.getClipInfo(epId: epId, cid: item.cid)
                guard !Task.isCancelled,
                      self.autonomousQueueAdvanceGeneration == advanceGeneration,
                      self.isCurrentOwner(ownerLease) else { return }
                if !clips.isEmpty {
                    self.skipSegments = clips
                }
            }

            if case .ugc = item.source, let bvid = item.bvid, !bvid.isEmpty {
                Task { await SponsorBlockManager.shared.load(videoID: bvid, cid: item.cid) }
            } else {
                SponsorBlockManager.shared.clear()
            }

            self.setNowPlaying(title: item.title, artist: item.artist, cover: item.coverURL)
            self.miniPlayer.updateActiveSession(
                matching: ownerLease,
                title: item.title,
                coverURL: item.coverURL,
                originRoute: item.originRoute,
                originScreenRoute: item.originScreenRoute,
                isPortrait: self.isPortraitContent
            )

            if case .playlist = nextQueue.kind,
               case .ugc = item.source,
               item.partCount == nil {
                let targetVideoID: VideoID = if let bvid = item.bvid, !bvid.isEmpty {
                    .bvid(bvid)
                } else {
                    .aid(item.aid)
                }
                if let info = try? await VideoAPI.getVideoInfo(id: targetVideoID),
                   !Task.isCancelled,
                   self.autonomousQueueAdvanceGeneration == advanceGeneration,
                   self.isCurrentOwner(ownerLease),
                   let liveQueue = self.playbackQueue,
                   liveQueue.isPlaylist {
                    let expanded = liveQueue.expandingMultiPartVideo(
                        info: info,
                        videoID: targetVideoID,
                        currentCid: item.cid
                    )
                    if expanded != liveQueue {
                        self.playbackQueue = expanded
                        self.syncPlaybackQueueCallbacks()
                        if let current = expanded.currentItem {
                            self.setNowPlaying(
                                title: current.title,
                                artist: current.artist,
                                cover: current.coverURL
                            )
                        }
                    }
                }
            }
        }
        return true
    }

    static let endedAutoAdvanceCountdownSeconds = 3

    var isForegroundInteractiveForEndedCountdown: Bool {
        UIApplication.shared.applicationState == .active
            && !backend.isPiPActive
            && !backend.hasObservedPiPLease
            && miniPlayer.activeSession == nil
    }

    var hasEndedAutoAdvanceTarget: Bool {
        guard mode.isSeekable else { return false }
        let hasQueueNext = playbackQueue?.hasNext == true
        let hasLegacyAdvance = hasExternalPlaybackEndedCallback && onPlaybackEnded != nil
        return hasQueueNext || hasLegacyAdvance
    }

    private var endedUpNextPreview: (
        title: String?,
        coverURL: String?,
        authorName: String?,
        durationSeconds: Int?
    ) {
        guard let nextItem = playbackQueue?.upNextItem else {
            return (nil, nil, nil, nil)
        }
        return (
            title: nextItem.displayTitleWithPart,
            coverURL: nextItem.coverURL,
            authorName: nextItem.artist.isEmpty ? nil : nextItem.artist,
            durationSeconds: nextItem.duration.map { max(0, Int($0.rounded())) }
        )
    }

    func syncEndedRecommendations(
        _ recommendations: [PlayerEndedRecommendation],
        ownerLease: PlayerOwnerLease,
        onSelect: ((PlayerEndedRecommendation) -> Void)?
    ) {
        guard isCurrentOwner(ownerLease) else { return }
        if session.endedRecommendations != recommendations {
            session.endedRecommendations = recommendations
        }
        session.endedRecommendationsOwnerLease = ownerLease
        onSelectEndedRecommendation = onSelect
    }

    func clearEndedRecommendations(matching ownerLease: PlayerOwnerLease) {
        guard session.endedRecommendationsOwnerLease == ownerLease else { return }
        clearAllEndedRecommendations()
    }

    func clearAllEndedRecommendations() {
        if !session.endedRecommendations.isEmpty {
            session.endedRecommendations = []
        }
        session.endedRecommendationsOwnerLease = nil
        onSelectEndedRecommendation = nil
    }

    func cancelEndedAutoAdvance() {
        endedAutoAdvanceGeneration &+= 1
        endedAutoAdvanceTask?.cancel()
        endedAutoAdvanceTask = nil
        if endedAutoAdvance != nil {
            endedAutoAdvance = nil
        }
    }

    func playEndedAutoAdvanceNow() {
        guard playbackTerminalState == .ended else {
            cancelEndedAutoAdvance()
            return
        }
        let endedGeneration = playerGeneration
        let endedLoadGeneration = loadGeneration
        cancelEndedAutoAdvance()
        executeEndedAutoAdvance(
            endedGeneration: endedGeneration,
            endedLoadGeneration: endedLoadGeneration
        )
    }

    var endedNextEpisodeAction: (() -> Void)? {
        guard mode.usesOnlineVODServices else { return nil }
        if playbackQueue?.hasNext == true || onNextEpisode != nil || onPlaybackEnded != nil {
            return { [weak self] in
                guard let self else { return }
                self.cancelEndedAutoAdvance()
                if !self.playNextInQueue(), self.hasExternalPlaybackEndedCallback {
                    self.onPlaybackEnded?()
                }
            }
        }
        return nil
    }

    private func applyEndOfPlaybackOrder(endedGeneration: Int, endedLoadGeneration: Int) {
        guard mode.isSeekable else {
            cancelEndedAutoAdvance()
            settleTerminalPlaybackEndPresentation()
            return
        }
        switch playbackOrder {
        case .pauseAtEnd:
            cancelEndedAutoAdvance()
            settleTerminalPlaybackEndPresentation()
        case .playNext:
            guard hasEndedAutoAdvanceTarget else {
                cancelEndedAutoAdvance()
                PlayerLog.log("[Player] end policy: playNext — nothing registered, stopping at end")
                settleTerminalPlaybackEndPresentation()
                return
            }
            if isForegroundInteractiveForEndedCountdown {
                settleTerminalPlaybackEndPresentation()
                startEndedAutoAdvanceCountdown(
                    endedGeneration: endedGeneration,
                    endedLoadGeneration: endedLoadGeneration
                )
            } else {
                executeEndedAutoAdvance(
                    endedGeneration: endedGeneration,
                    endedLoadGeneration: endedLoadGeneration
                )
            }
        case .loopOne:
            cancelEndedAutoAdvance()
            restartForLoop()
            if playbackTerminalState == .ended {
                settleTerminalPlaybackEndPresentation()
            }
        }
    }

    private func startEndedAutoAdvanceCountdown(
        endedGeneration: Int,
        endedLoadGeneration: Int
    ) {
        cancelEndedAutoAdvance()
        guard playbackTerminalState == .ended,
              playerGeneration == endedGeneration,
              loadGeneration == endedLoadGeneration,
              hasEndedAutoAdvanceTarget else { return }

        let totalSeconds = Self.endedAutoAdvanceCountdownSeconds
        let preview = endedUpNextPreview
        endedAutoAdvanceGeneration &+= 1
        let countdownGeneration = endedAutoAdvanceGeneration
        endedAutoAdvance = PlayerEndedAutoAdvanceState(
            totalSeconds: totalSeconds,
            remainingSeconds: totalSeconds,
            title: preview.title,
            coverURL: preview.coverURL,
            authorName: preview.authorName,
            durationSeconds: preview.durationSeconds
        )
        PlayerLog.log(
            "[Player] end policy: playNext countdown started (\(totalSeconds)s) " +
            "owner=\(ownerKey.isEmpty ? "-" : ownerKey)"
        )
        endedAutoAdvanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: totalSeconds - 1, through: 1, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.endedAutoAdvanceGeneration == countdownGeneration,
                      self.playerGeneration == endedGeneration,
                      self.loadGeneration == endedLoadGeneration,
                      self.playbackTerminalState == .ended,
                      self.playbackOrder == .playNext,
                      self.hasEndedAutoAdvanceTarget else { return }
                let refreshed = self.endedUpNextPreview
                self.endedAutoAdvance = PlayerEndedAutoAdvanceState(
                    totalSeconds: totalSeconds,
                    remainingSeconds: remaining,
                    title: refreshed.title,
                    coverURL: refreshed.coverURL,
                    authorName: refreshed.authorName,
                    durationSeconds: refreshed.durationSeconds
                )
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.endedAutoAdvanceGeneration == countdownGeneration,
                  self.playerGeneration == endedGeneration,
                  self.loadGeneration == endedLoadGeneration,
                  self.playbackTerminalState == .ended,
                  self.playbackOrder == .playNext,
                  self.hasEndedAutoAdvanceTarget else { return }
            self.endedAutoAdvanceTask = nil
            self.endedAutoAdvance = nil
            self.executeEndedAutoAdvance(
                endedGeneration: endedGeneration,
                endedLoadGeneration: endedLoadGeneration
            )
        }
    }

    private func executeEndedAutoAdvance(
        endedGeneration: Int,
        endedLoadGeneration: Int
    ) {
        let hasQueueNext = playbackQueue?.hasNext == true
        let hasLegacyAdvance = hasExternalPlaybackEndedCallback && onPlaybackEnded != nil
        guard hasQueueNext || hasLegacyAdvance else {
            PlayerLog.log("[Player] end policy: playNext — nothing registered, stopping at end")
            settleTerminalPlaybackEndPresentation()
            return
        }
        PlayerLog.log("[Player] end policy: playNext → owner=\(ownerKey.isEmpty ? "-" : ownerKey)")
        var advanced = false
        if hasQueueNext {
            advanced = playNextInQueue()
        }
        if !advanced, hasLegacyAdvance, let advance = onPlaybackEnded {
            advance()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.playerGeneration == endedGeneration,
                  self.loadGeneration == endedLoadGeneration,
                  self.autonomousQueueAdvanceTask == nil,
                  !self.isAutonomousQueueAdvanceInFlight,
                  self.playbackTerminalState == .ended else { return }
            PlayerLog.log("[Player] end policy: playNext did not advance — settling playback end")
            self.settleTerminalPlaybackEndPresentation()
        }
    }

    func settleTerminalPlaybackEndPresentation() {
        guard playbackTerminalState == .ended else { return }
        if isBuffering {
            isBuffering = false
        }
        if backend.isPiPActive || backend.hasObservedPiPLease {
            PlayerLog.log("[Player] playback ended — stopping active PiP")
            backend.stopPiP()
        }
        if let session = miniPlayer.activeSession, isCurrentOwner(session.ownerLease) {
            cancelEndedAutoAdvance()
            PlayerLog.log("[MiniPlayer] auto-dismissed at natural playback end")
            dismissMiniPlayer(matching: session.ownerLease)
            return
        }
        hideControlsTask?.cancel()
        hideControlsTask = nil
        if !showControls {
            showControls = true
        }
    }

    private func prepareExplicitReplay() -> Bool {
        guard PlaybackReplayPolicy.allows(from: playbackTerminalState) else {
            return false
        }
        let hasReplayAuthority: Bool = switch mode {
        case .vod:
            currentAid != nil && currentCid != nil
        case .offline:
            offlineAsset != nil
        case .live:
            false
        }
        guard hasReplayAuthority else { return false }
        cancelEndedAutoAdvance()
        playbackTerminalState = .active
        terminalOpenFailure = false
        error = nil
        unavailability = nil
        decoderSessionSuspect = false
        needsInlineSurfaceRebuild = false
        needsReloadBeforeExplicitPlay = false
        resumeAtTime = nil
        resumeIsFromHistory = false
        pendingSeekTarget = nil
        mediaTime = PlaybackReplayPolicy.canonicalOrigin
        lastSeekRequest = nil
        armDurableResumeTarget(nil, source: "explicit-replay")
        clearFreezeFrame()
        currentFault = nil
        faultTicks = 0
        healthOutcome = nil
        pendingHistoryResumeNotice = nil
        pendingPartLocationNotice = nil
        dismissNoticeBanner(onlyIfResume: true)
        resetRecoveryBudget()
        cdnFallbackActive = false
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = nil
        demandContinuationOperationRunner?.cancelCurrent()
        invalidateLifecycleReadiness()
        decoderRecoveryAdmission.invalidate()
        nonLifecycleRecoveryTicket = nil
        lifecycleRecovery.clearTerminalForReplay()
        demandPresentationLiveness.invalidate()
        if usesDemandPresentationContinuity {
            dispatchDemandPresentation(.explicitReplay)
        }
        rearmHistoryReportingAfterCompletion()
        updateDemandVideoLivenessContext()
        return true
    }

    func restartForLoop() {
        guard prepareExplicitReplay() else { return }
        let reloadOwnerLease = currentOwnerLease
        mediaTime = 0
        resumeAtTime = nil
        resumeIsFromHistory = false
        sponsorSkippedUUIDs = []
        autoSkippedSegmentKeys = []

        if let url = currentURL, Self.urlStillFresh(url) {
            guard reloadOwnerLease.map({ isCurrentOwner($0) }) ?? false else { return }
            PlayerLog.log("[Player] 🔁 end policy: loop — reopening at 0:00")
            playURL(url, audioURL: isDASHMode ? currentDASHAudioURL : nil, startAt: 0)
            return
        }
        guard let aid = currentAid, let cid = currentCid else {
            PlayerLog.log("[Player] end policy: loop — nothing to reopen, stopping at end")
            return
        }
        PlayerLog.log("[Player] 🔁 end policy: loop — URL signature expired, full reload")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadVOD(
                aid: aid,
                cid: cid,
                quality: self.currentQuality,
                source: self.currentSource,
                ownerLease: reloadOwnerLease
            )
        }
    }
}
