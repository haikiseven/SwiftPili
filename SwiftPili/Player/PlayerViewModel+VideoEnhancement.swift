import Foundation

struct VideoEnhancementControlStatus: Equatable {
    let isActive: Bool
    let bypassReason: String?

    init(telemetry: VideoEnhancementTelemetry?) {
        isActive = telemetry?.isActive == true
        bypassReason = telemetry?.bypassReason
    }
}

extension PlayerViewModel {
    var videoEnhancementUnavailableReason: String? {
        if mode == .live {
            return "Live unsupported"
        }
        if backendKind != .demandPaced {
            return "libVLC unsupported"
        }
        return nil
    }

    var videoEnhancementUnavailableDisplayReason: String? {
        videoEnhancementUnavailableReason.map(VideoEnhancementBypassDisplay.shortLabel(for:))
    }

    var isVideoEnhancementEligibleForStream: Bool {
        videoEnhancementUnavailableReason == nil
    }

    var effectiveVideoEnhancementConfiguration: VideoEnhancementConfiguration {
        guard ExperimentalSettingsPolicy.videoEnhancementEnabled else {
            return .disabled
        }
        return VideoEnhancementConfiguration(
            superResolutionMode: videoSuperResolutionMode,
            frameInterpolationEnabled: videoFrameInterpolationEnabled,
            interpolationRate: videoInterpolationRate,
            superResolutionScale: videoSuperResolutionScale,
            isLiveStream: mode == .live,
            adaptiveQualityEnabled: ExperimentalSettingsStore.shared.videoEnhancementAdaptiveQuality,
            adaptiveSensitivity: ExperimentalSettingsStore.shared.videoEnhancementAdaptiveSensitivity,
            bufferBudget: ExperimentalSettingsStore.shared.videoEnhancementBufferBudget,
            maxLookahead: ExperimentalSettingsStore.shared.videoEnhancementMaxLookahead,
            limitToScreenResolution: ExperimentalSettingsStore.shared.videoEnhancementLimitToScreen
        )
    }

    func setVideoSuperResolutionMode(_ mode: VideoSuperResolutionMode) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement) else { return }
        guard videoSuperResolutionMode != mode else { return }
        videoSuperResolutionMode = mode
        syncVideoEnhancementToBackend()
    }

    func setVideoFrameInterpolationEnabled(_ enabled: Bool) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement) else { return }
        guard videoFrameInterpolationEnabled != enabled else { return }
        videoFrameInterpolationEnabled = enabled
        syncVideoEnhancementToBackend()
    }

    func setVideoInterpolationRate(_ rate: VideoInterpolationRate) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoFrameInterpolationEnabled,
              videoInterpolationRate != rate else { return }
        videoInterpolationRate = rate
        syncVideoEnhancementToBackend()
    }

    func setVideoSuperResolutionScale(_ scale: VideoSuperResolutionScale) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoSuperResolutionMode != .off,
              videoSuperResolutionScale != scale else { return }
        videoSuperResolutionScale = scale
        syncVideoEnhancementToBackend()
    }

    func syncVideoEnhancementToBackend(_ targetBackend: (any PlayerBackend)? = nil) {
        let target = targetBackend ?? backend
        target.videoEnhancementConfiguration = effectiveVideoEnhancementConfiguration
        refreshVideoEnhancementTelemetry(from: target)
    }

    func currentVideoEnhancementTelemetry(
        from targetBackend: (any PlayerBackend)? = nil
    ) -> VideoEnhancementTelemetry? {
        guard ExperimentalSettingsPolicy.videoEnhancementEnabled,
              effectiveVideoEnhancementConfiguration.isRequested else {
            return nil
        }
        if let reason = videoEnhancementUnavailableReason {
            return .bypassed(reason: reason)
        }
        return (targetBackend ?? backend).videoEnhancementTelemetry
    }

    func refreshVideoEnhancementTelemetry(from targetBackend: (any PlayerBackend)? = nil) {
        let telemetry = currentVideoEnhancementTelemetry(from: targetBackend)
        if stats.videoEnhancement != telemetry {
            stats.videoEnhancement = telemetry
        }
    }

    func handleVideoEnhancementPolicyChange() {
        let experiments = ExperimentalSettingsStore.shared
        if experiments.isAllowed(.videoEnhancement) {
            videoSuperResolutionMode = experiments.videoEnhancementDefaultSRMode
            videoFrameInterpolationEnabled = experiments.videoEnhancementDefaultFrameInterpolation
        } else {
            videoSuperResolutionMode = .off
            videoFrameInterpolationEnabled = false
        }
        videoInterpolationRate = experiments.videoEnhancementDefaultRate
        videoSuperResolutionScale = experiments.videoEnhancementDefaultScale
        syncVideoEnhancementToBackend()
    }
}
