import Foundation

/// The settings that seed per-player enhancement choices. Changes to tuning settings (buffer
/// memory, sensitivity, …) are synced without touching what the user picked in the player.
struct VideoEnhancementDefaultsSnapshot: Equatable {
    let allowed: Bool
    let superResolutionMode: VideoSuperResolutionMode
    let frameInterpolation: Bool
    let interpolationRate: VideoInterpolationRate
    let superResolutionScale: VideoSuperResolutionScale
    let superResolutionTargetResolution: VideoSuperResolutionTargetResolution
    let maxInputResolution: VideoEnhancementMaxInputResolution

    @MainActor static var current: Self {
        let store = ExperimentalSettingsStore.shared
        return Self(
            allowed: store.isAllowed(.videoEnhancement),
            superResolutionMode: store.videoEnhancementDefaultSRMode,
            frameInterpolation: store.videoEnhancementDefaultFrameInterpolation,
            interpolationRate: store.videoEnhancementDefaultRate,
            superResolutionScale: store.videoEnhancementDefaultScale,
            superResolutionTargetResolution: store.videoEnhancementDefaultTargetResolution,
            maxInputResolution: store.videoEnhancementMaxInputResolution
        )
    }
}

struct VideoEnhancementControlStatus: Equatable {
    let isActive: Bool
    let bypassReason: String?

    init(telemetry: VideoEnhancementTelemetry?) {
        isActive = telemetry?.isActive == true
        bypassReason = telemetry?.bypassReason
    }
}

extension PlayerViewModel {
    var videoSuperResolutionTargetResolution: VideoSuperResolutionTargetResolution {
        get { session.videoSuperResolutionTargetResolution }
        set { session.videoSuperResolutionTargetResolution = newValue }
    }

    var videoEnhancementMaxInputResolution: VideoEnhancementMaxInputResolution {
        get { session.videoEnhancementMaxInputResolution }
        set { session.videoEnhancementMaxInputResolution = newValue }
    }

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
            superResolutionTargetResolution: videoSuperResolutionTargetResolution,
            maxInputResolution: videoEnhancementMaxInputResolution,
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

    func setVideoSuperResolutionTargetResolution(_ target: VideoSuperResolutionTargetResolution) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoSuperResolutionMode == .metalFXSpatial,
              videoSuperResolutionTargetResolution != target else { return }
        videoSuperResolutionTargetResolution = target
        syncVideoEnhancementToBackend()
    }

    func setVideoEnhancementMaxInputResolution(_ limit: VideoEnhancementMaxInputResolution) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream,
              videoEnhancementMaxInputResolution != limit else { return }
        videoEnhancementMaxInputResolution = limit
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
        let defaults = VideoEnhancementDefaultsSnapshot.current
        let previous = appliedVideoEnhancementDefaults
        guard defaults != previous else {
            syncVideoEnhancementToBackend()
            return
        }
        appliedVideoEnhancementDefaults = defaults
        if !defaults.allowed {
            videoSuperResolutionMode = .off
            videoFrameInterpolationEnabled = false
        } else if !previous.allowed {
            videoSuperResolutionMode = defaults.superResolutionMode
            videoFrameInterpolationEnabled = defaults.frameInterpolation
            videoInterpolationRate = defaults.interpolationRate
            videoSuperResolutionScale = defaults.superResolutionScale
            videoSuperResolutionTargetResolution = defaults.superResolutionTargetResolution
            videoEnhancementMaxInputResolution = defaults.maxInputResolution
        } else {
            if defaults.superResolutionMode != previous.superResolutionMode {
                videoSuperResolutionMode = defaults.superResolutionMode
            }
            if defaults.frameInterpolation != previous.frameInterpolation {
                videoFrameInterpolationEnabled = defaults.frameInterpolation
            }
            if defaults.interpolationRate != previous.interpolationRate {
                videoInterpolationRate = defaults.interpolationRate
            }
            if defaults.superResolutionScale != previous.superResolutionScale {
                videoSuperResolutionScale = defaults.superResolutionScale
            }
            if defaults.superResolutionTargetResolution != previous.superResolutionTargetResolution {
                videoSuperResolutionTargetResolution = defaults.superResolutionTargetResolution
            }
            if defaults.maxInputResolution != previous.maxInputResolution {
                videoEnhancementMaxInputResolution = defaults.maxInputResolution
            }
        }
        syncVideoEnhancementToBackend()
    }
}
