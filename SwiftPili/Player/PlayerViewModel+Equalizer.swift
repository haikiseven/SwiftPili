import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func applyExperimentalPolicy(_ changes: Set<ExperimentalFeature>) {
        if changes.contains(.equalizer) { backend.equalizerConfiguration = effectiveEqualizerConfiguration }
        if changes.contains(.videoEnhancement) { handleVideoEnhancementPolicyChange() }
        if changes.contains(.ambient) {
            ambientModeEnabled = ExperimentalSettingsPolicy.isAllowed(.ambient)
            reconcileAmbientStoryboard()
        }
        if changes.contains(.multiConnection) { refreshMultiConnectionQuiet() }
        if changes.contains(.http2Probe), !ExperimentalSettingsPolicy.isAllowed(.http2Probe),
           let receipt = videoProbeExperimentalAccess, !receipt.isValid {
            videoProbeTask?.cancel()
            videoProbeExperimentalAccess = nil
        }
    }

    func updateEqualizer(
        _ configuration: PlayerEqualizerConfiguration,
        presentation: PlayerEqualizerPresentationIdentity? = nil,
        access: ExperimentalAccessReceipt? = nil
    ) {
        let experiments = ExperimentalSettingsStore.shared
        guard experiments.isAllowed(.equalizer) else { return }
        if let presentation {
            guard presentation == equalizerPresentationIdentity, let access,
                  access.feature == .equalizer, experiments.isCurrentAccess(access) else { return }
        }
        let normalized = configuration.normalized
        PlayerEqualizerPreferences.equalizerConfiguration = normalized
        equalizerConfiguration = normalized
        backend.equalizerConfiguration = effectiveEqualizerConfiguration
    }

    func revokeEqualizerMaintenancePermission() {
        currentEqualizerMaintenancePermit?.revoke()
        currentEqualizerMaintenancePermit = nil
        backend.revokeAudioMaintenancePermission()
    }

    func installEqualizerMaintenanceAdmission() {
        let identity = equalizerPresentationIdentity
        let backendIdentity = ObjectIdentifier(backend)
        let backendGeneration = backend.runtimeGeneration
        backend.audioMaintenanceAdmission = { [weak self] in
            guard let self, let identity,
                  ObjectIdentifier(self.backend) == backendIdentity,
                  self.backend.runtimeGeneration == backendGeneration,
                  self.equalizerPresentationIdentity == identity,
                  self.playbackIntent == .playing, self.isPlaying,
                  UIApplication.shared.applicationState == .active
                    || PlayerPlaybackPreferences.playbackContinuationConfiguration.allowsBackgroundPlayback,
                  !self.audioSessionInterrupted, !self.audioSessionNeedsReactivation,
                  self.mediaResetRecovery.request == nil, !self.invalidatedBackendResources,
                  !self.currentPlaybackTerminalState.isTerminal, !self.terminalOpenFailure else { return nil }
            self.currentEqualizerMaintenancePermit?.revoke()
            let permit = AudioMaintenancePermit()
            self.currentEqualizerMaintenancePermit = permit
            return permit
        }
    }
}
