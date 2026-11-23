import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {
    var backgroundExecutionKey: PlayerBackgroundExecution.Key? {
        currentOwnerLease.map { .init(owner: $0, recoveryBudget: recoveryBudgetIdentity) }
    }

    @discardableResult
    func beginBackgroundPlaybackRestoration(reason: String, explicit: Bool = false) -> UUID? {
        if explicit { backgroundExecution.allowExplicitRequest() }
        if !explicit {
            guard playbackIntent != .pausedByUser, !audioSessionPolicy.requiresUserPlay,
                  !currentPlaybackTerminalState.isTerminal, !terminalOpenFailure else { return nil }
        }
        guard UIApplication.shared.applicationState != .active,
              PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsBackgroundPlayback,
              let key = backgroundExecutionKey else { return nil }
        backgroundExecution.begin(key: key, reason: reason, explicit: explicit) { [weak self] requestID in
            Task { @MainActor [weak self] in
                guard let self, self.backgroundExecutionKey == key,
                      self.backgroundExecution.isExpired(key: key, requestID: requestID) else { return }
                self.audioSessionPolicy.requireUserPlay()
                self.audioSessionPolicy.requireActivation()
                self.suspendStreamRecovery()
                self.suspendPlayback()
                PlayerLog.log("[BackgroundPlayback] pending restoration paused after expiration")
            }
        }
        return backgroundExecution.currentRequestID
    }

    func finishBackgroundSeek(_ request: UUID?, settlement: SeekSettlement) {
        if settlement == .failed || (settlement == .arrived && playbackIntent != .playing) {
            backgroundExecution.end(requestID: request, reason: "seek-settled")
        }
    }

    func protectPendingBackgroundPlayback() {
        guard playbackIntent == .playing, !audioSessionInterrupted else { return }
        let output = backend.audioOutputAvailability
        let nativeOutputPending = backendKind == .demandPaced && output != .available && output != .fillOnly
        if isBuffering || streamRecoveryOwnsWork || !backend.isPlaying || nativeOutputPending {
            beginBackgroundPlaybackRestoration(reason: "entered-background")
        }
    }

    func prepareBackgroundExecutionForStop(_ reason: PlayerTeardownReason) {
        if reason != .internalReload { backgroundExecution.end(reason: "source-stop") }
        nativeAudioRepairAttempt = nil
    }

    func noteBackgroundPlaybackProgress(_ position: TimeInterval) {
        guard let key = backgroundExecutionKey,
              backend.isPlaying, !isSeekInFlight, !audioSessionInterrupted else { return }
        if backendKind == .demandPaced {
            guard backend.audioOutputAvailability == .available,
                  let nativePosition = (backend as? DemandPacedPlayerBackend)?.renderedAudioOutputPosition,
                  nativePosition >= position else { return }
        }
        if position > mediaTime { nativeAudioRepairAttempt = nil }
        guard backgroundExecution.isActive else { return }
        backgroundExecution.noteProgress(key: key, backend: ObjectIdentifier(backend),
            generation: backend.runtimeGeneration, position: position)
    }

    func installAudioOutputObservation() {
        let identity = ObjectIdentifier(backend)
        backend.setAudioOutputStateChangeHandler { [weak self] in
            guard let self, ObjectIdentifier(self.backend) == identity else { return }
            self.handleNativeAudioOutputChange()
            self.syncDanmakuTransport()
        }
    }

    func handleNativeAudioOutputChange() {
        let availability = backend.audioOutputAvailability
        if availability == .available { return }
        guard availability == .unavailable, playbackIntent == .playing,
              !audioSessionPolicy.interrupted, !audioSessionPolicy.requiresUserPlay,
              mediaResetRecovery.request == nil, !invalidatedBackendResources,
              !currentPlaybackTerminalState.isTerminal, !terminalOpenFailure,
              !isSeekInFlight, streamRecoveryMayRun, let owner = currentOwnerLease else { return }
        let attempt = NativeAudioRepairAttempt(owner: owner, backend: ObjectIdentifier(backend),
            generation: backend.runtimeGeneration, load: loadGeneration)
        guard nativeAudioRepairAttempt != attempt else { return }
        beginBackgroundPlaybackRestoration(reason: "native-output-loss")
        Task { @MainActor [weak self] in
            guard let self, self.nativeAudioRepairAttempt != attempt,
                  self.currentOwnerLease == owner,
                  ObjectIdentifier(self.backend) == attempt.backend,
                  self.backend.runtimeGeneration == attempt.generation,
                  self.loadGeneration == attempt.load,
                  self.playbackIntent == .playing, !self.audioSessionPolicy.interrupted,
                  !self.audioSessionPolicy.requiresUserPlay,
                  self.mediaResetRecovery.request == nil, !self.invalidatedBackendResources,
                  !self.currentPlaybackTerminalState.isTerminal, !self.terminalOpenFailure,
                  !self.isSeekInFlight, self.streamRecoveryMayRun,
                  self.backend.audioOutputAvailability == .unavailable else { return }
            self.nativeAudioRepairAttempt = attempt
            self.audioSessionPolicy.requireActivation()
            guard self.authorizeAudioPlayback() else { return }
            guard self.backend.reconcileAudioOutputForAuthorizedPlayback() else {
                if self.nativeAudioRepairAttempt == attempt { self.nativeAudioRepairAttempt = nil }
                return
            }
            PlayerLog.log("[BackgroundPlayback] native output repair submitted generation=\(attempt.generation)")
        }
    }
}
