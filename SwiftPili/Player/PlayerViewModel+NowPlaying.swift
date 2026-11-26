import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import os

extension PlayerViewModel {

    var canPlayNextTrack: Bool {
        mode.usesOnlineVODServices && (onNextEpisode != nil || playbackQueue?.hasNext == true)
    }

    var canPlayPreviousTrack: Bool {
        mode.usesOnlineVODServices && (onPreviousEpisode != nil || playbackQueue?.hasPrevious == true)
    }

    private var nowPlayingTrackCommandsAreActionable: Bool {
        currentOwnerLease != nil
            && currentURL != nil
            && !terminalOpenFailure
            && error == nil
            && unavailability == nil
    }

    func syncNowPlayingTrackCommands(
        center: MPRemoteCommandCenter = .shared()
    ) {
        let owner = currentOwnerLease
        let actionable = nowPlayingTrackCommandsAreActionable
        let canNext = actionable && canPlayNextTrack
        let canPrevious = actionable && canPlayPreviousTrack

        nowPlayingTrackCommandState.withLock { state in
            state = NowPlayingTrackCommandSnapshot(
                owner: owner,
                canPlayNext: canNext,
                canPlayPrevious: canPrevious
            )
        }

        if owner != nil, canNext || canPrevious {
            ensureNowPlayingTrackCommandTargets(on: center)
        }

        center.nextTrackCommand.isEnabled = canNext
        center.previousTrackCommand.isEnabled = canPrevious
    }

    func clearNowPlayingTrackCommands(
        center: MPRemoteCommandCenter = .shared()
    ) {
        nowPlayingTrackCommandState.withLock { state in
            state = NowPlayingTrackCommandSnapshot(
                owner: nil,
                canPlayNext: false,
                canPlayPrevious: false
            )
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        if let target = nowPlayingNextTrackTarget {
            center.nextTrackCommand.removeTarget(target)
            nowPlayingNextTrackTarget = nil
        }
        if let target = nowPlayingPreviousTrackTarget {
            center.previousTrackCommand.removeTarget(target)
            nowPlayingPreviousTrackTarget = nil
        }
    }

    private func ensureNowPlayingTrackCommandTargets(on center: MPRemoteCommandCenter) {
        let state = nowPlayingTrackCommandState
        if nowPlayingNextTrackTarget == nil {
            nowPlayingNextTrackTarget = center.nextTrackCommand.addTarget { @Sendable _ in
                let snapshot = state.withLock { $0 }
                guard let owner = snapshot.owner, snapshot.canPlayNext else {
                    return .noSuchContent
                }
                Task { @MainActor in
                    let vm = PlayerViewModel.shared
                    guard vm.isCurrentOwner(owner), vm.canPlayNextTrack else { return }
                    _ = vm.playNextInQueue()
                }
                return .success
            }
        }
        if nowPlayingPreviousTrackTarget == nil {
            nowPlayingPreviousTrackTarget = center.previousTrackCommand.addTarget { @Sendable _ in
                let snapshot = state.withLock { $0 }
                guard let owner = snapshot.owner, snapshot.canPlayPrevious else {
                    return .noSuchContent
                }
                Task { @MainActor in
                    let vm = PlayerViewModel.shared
                    guard vm.isCurrentOwner(owner), vm.canPlayPreviousTrack else { return }
                    _ = vm.playPreviousInQueue()
                }
                return .success
            }
        }
    }

    func setNowPlaying(title: String, artist: String, cover: String?) {
        guard let owner = currentOwnerLease else {
            nowPlayingMeta = nil
            clearNowPlayingTrackCommands()
            PlayerLog.log("[NowPlaying] metadata ignored — no current owner")
            return
        }
        nowPlayingMeta = (title, artist, cover)
        NowPlayingCenter.shared.activate(
            owner: owner,
            title: title,
            artist: artist,
            coverURL: cover,
            mode: mode,
            elapsed: displayTime,
            duration: duration,
            rate: playbackRate,
            isPlaying: isPlaying,
            isActionable: nowPlayingCommandsAreActionable
        )
        syncNowPlayingTrackCommands()
    }

    func makeNowPlayingEdgeFence(
        backendGeneration: UInt64? = nil,
        sessionGeneration: UInt64? = nil,
        pipBindingGeneration: UInt64? = nil
    ) -> NowPlayingEdgeFence? {
        guard let owner = currentOwnerLease,
              let item = NowPlayingCenter.shared.currentSnapshot,
              item.owner == owner else {
            return nil
        }
        let currentBinding = backend.demandPiPBindingGeneration
        return NowPlayingEdgeFence(
            owner: owner,
            itemGeneration: item.itemGeneration,
            backendGeneration: backendGeneration ?? backend.runtimeGeneration,
            sessionGeneration: sessionGeneration
                ?? backend.demandPresentationSessionGeneration,
            pipBindingGeneration: pipBindingGeneration
                ?? (currentBinding == 0 ? nil : currentBinding)
        )
    }

    func acceptsNowPlayingEdgeFence(_ fence: NowPlayingEdgeFence) -> Bool {
        guard currentOwnerLease == fence.owner,
              let item = NowPlayingCenter.shared.currentSnapshot,
              item.owner == fence.owner,
              item.itemGeneration == fence.itemGeneration,
              backend.runtimeGeneration == fence.backendGeneration,
              backend.demandPresentationSessionGeneration == fence.sessionGeneration else {
            return false
        }
        if let binding = fence.pipBindingGeneration,
           backend.demandPiPBindingGeneration != binding {
            return false
        }
        return true
    }

    func acceptsCurrentDemandPresentationFence(
        _ fence: DemandPresentationFence
    ) -> Bool {
        guard usesDemandPresentationContinuity,
              ownerKey == fence.ownerKey,
              ownerLeaseGeneration == fence.ownerLeaseGeneration,
              backend.runtimeGeneration == fence.backendGeneration,
              backend.demandPresentationSessionGeneration == fence.sessionGeneration,
              backend.demandPiPBindingGeneration == fence.pipBindingGeneration,
              let source = decoderRecoverySource(),
              source.hasSameAuthority(as: fence.source) else {
            return false
        }
        return true
    }

    func acceptsPiPTransportGenerations(
        backendGeneration: UInt64,
        sessionGeneration: UInt64,
        pipBindingGeneration: UInt64?,
        ownerLeaseGeneration: UInt64
    ) -> Bool {
        guard usesDemandPresentationContinuity,
              currentOwnerLease != nil,
              ownerLeaseGeneration == self.ownerLeaseGeneration,
              backend.runtimeGeneration == backendGeneration,
              backend.demandPresentationSessionGeneration == sessionGeneration else {
            return false
        }
        if self.ownerLeaseGeneration != 0,
           ownerLeaseGeneration != self.ownerLeaseGeneration {
            return false
        }
        if let pipBindingGeneration,
           backend.demandPiPBindingGeneration != pipBindingGeneration {
            return false
        }
        if pipBindingGeneration == nil,
           backend.demandPiPBindingGeneration != 0 {
            return false
        }
        return true
    }

    @discardableResult
    func publishNowPlayingStateEdge(
        _ edge: NowPlayingStateEdge,
        fence: NowPlayingEdgeFence? = nil,
        elapsed: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        rate: Float? = nil,
        isPlaying: Bool? = nil,
        isActionable: Bool? = nil
    ) -> Bool {
        lastNowPlayingPushAt = CACurrentMediaTime()
        guard let edgeFence = fence ?? makeNowPlayingEdgeFence() else { return false }
        let published = nowPlayingStateEdgeAdapter.publish(
            edge: edge,
            fence: edgeFence,
            projection: NowPlayingEdgeProjection(
                elapsed: elapsed ?? displayTime,
                duration: duration ?? self.duration,
                rate: rate ?? playbackRate,
                isPlaying: isPlaying ?? self.isPlaying,
                isActionable: isActionable ?? nowPlayingCommandsAreActionable
            )
        )
        if published {
            syncNowPlayingTrackCommands()
        }
        return published
    }

    func pushNowPlayingPlayback(edge explicitEdge: NowPlayingStateEdge? = nil) {
        let edge = explicitEdge ?? (isPlaying ? .playing : .paused)
        _ = publishNowPlayingStateEdge(edge)
    }

    func snapshotNowPlayingForBackground() {
        _ = publishNowPlayingStateEdge(.background)
    }
}
