import Foundation
import Observation

/// Playback session identity, transport state, media streams, and per-player enhancement/audio settings.
@MainActor
@Observable
final class PlayerSessionState {
    var isPlaying = false
    var hasRenderedFirstFrame = false
    var playbackRate: Float = 1.0
    var currentQuality: Int = 116
    var mode: PlayerMode = .vod
    var error: String?
    var unavailability: PlaybackUnavailability?

    var currentURL: URL?
    var currentDASHAudioURL: URL?
    var currentAid: Int?
    var currentCid: Int?
    var currentBvid: String?
    var offlineAsset: OfflinePlaybackAsset?
    var currentRoomID: Int?
    var currentLiveQuality = LiveAPI.defaultLiveQuality
    var currentSource: PlayerViewModel.StreamSource = .ugc

    var videoSuperResolutionMode: VideoSuperResolutionMode = ExperimentalSettingsPolicy.videoEnhancementEnabled
        ? VideoEnhancementPreferences.defaultSRMode
        : .off
    var videoFrameInterpolationEnabled = ExperimentalSettingsPolicy.videoEnhancementEnabled
        ? VideoEnhancementPreferences.defaultFrameInterpolationEnabled
        : false
    var videoInterpolationRate = ExperimentalSettingsStore.shared.videoEnhancementDefaultRate
    var videoSuperResolutionScale = ExperimentalSettingsStore.shared.videoEnhancementDefaultScale
    var videoSuperResolutionTargetResolution =
        ExperimentalSettingsStore.shared.videoEnhancementDefaultTargetResolution
    var videoSuperResolutionSharpness = ExperimentalSettingsStore.shared.videoEnhancementDefaultSharpness
    var videoEnhancementMaxInputResolution = ExperimentalSettingsStore.shared.videoEnhancementMaxInputResolution
    var equalizerConfiguration = PlayerEqualizerPreferences.equalizerConfiguration

    var playbackOrder = PlayerPlaybackPreferences.playbackOrder
    var scaleMode: VideoScaleMode = .fit
    var rateBeforeHold: Float?

    var playbackIntent: PlayerViewModel.PlaybackIntent = .playing
    var playbackTerminalState: PlaybackTerminalState = .active
    var isDASHMode = false
    var currentVideoIsAV1 = false

    var availableQualities: [(id: Int, desc: String)] = []
    var availableCodecs: [VideoCodecPreference] = []
    var availableAudioTiers: [AudioQualityTier] = []
    var playingAudioTier: AudioQualityTier?

    var loadGeneration = 0
}
