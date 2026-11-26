import Foundation
import Observation

struct PlayerEndedRecommendation: Identifiable, Equatable, Sendable {
    let id: String
    let bvid: String
    let title: String
    let authorName: String
    let coverURL: String?
    let durationSeconds: Int?

    init(
        id: String,
        bvid: String,
        title: String,
        authorName: String,
        coverURL: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.bvid = bvid
        self.title = title
        self.authorName = authorName
        self.coverURL = coverURL
        self.durationSeconds = durationSeconds
    }
}

struct PlayerEndedAutoAdvanceState: Equatable, Sendable {
    let totalSeconds: Int
    let remainingSeconds: Int
    let title: String?
    let coverURL: String?
    let authorName: String?
    let durationSeconds: Int?

    var progress: Double {
        guard totalSeconds > 0 else { return 1 }
        let clamped = min(max(remainingSeconds, 0), totalSeconds)
        return Double(totalSeconds - clamped) / Double(totalSeconds)
    }
}

/// Playback session identity, transport state, media streams, and per-player enhancement/audio settings.
struct PlayerDecodeFallbackState: Equatable, Sendable {
    var contentKey: String = ""
    var rejectedCodecKeys: Set<String> = []
    var codecFallbackCount: Int = 0
    var engineOverride: PlayerEngineKind? = nil
    var shownCodecNotice: Bool = false
    var shownEngineNotice: Bool = false
    var pendingNoticeText: String? = nil
}

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
    var videoSuperResolutionSplitCompare = false
    var videoEnhancementMaxInputResolution = ExperimentalSettingsStore.shared.videoEnhancementMaxInputResolution
    var equalizerConfiguration = PlayerEqualizerPreferences.equalizerConfiguration

    var playbackOrder = PlayerPlaybackPreferences.playbackOrder
    var scaleMode: VideoScaleMode = .fit
    var rateBeforeHold: Float?

    var playbackIntent: PlayerViewModel.PlaybackIntent = .playing
    var playbackTerminalState: PlaybackTerminalState = .active
    var endedAutoAdvance: PlayerEndedAutoAdvanceState?
    var endedRecommendations: [PlayerEndedRecommendation] = []
    var endedRecommendationsOwnerLease: PlayerOwnerLease?
    var isDASHMode = false
    var currentVideoIsAV1 = false
    var decodeFallback = PlayerDecodeFallbackState()

    var availableQualities: [(id: Int, desc: String)] = []
    var availableCodecs: [VideoCodecPreference] = []
    var availableAudioTiers: [AudioQualityTier] = []
    var playingAudioTier: AudioQualityTier?

    var loadGeneration = 0 {
        didSet {
            guard loadGeneration != oldValue else { return }
            endedAutoAdvance = nil
            resetTransientSubtitleState()
        }
    }

    // MARK: - Dual-Track, Local Import & System Speech Subtitles

    var secondarySubtitleLan: String?
    var secondarySubtitleText: String?
    @ObservationIgnored var primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
    @ObservationIgnored var secondarySubtitleCues: [PlayerViewModel.SubtitleCue] = [] {
        didSet { secondarySubtitleCueIndex = SubtitleCueIndex(cues: secondarySubtitleCues) }
    }
    @ObservationIgnored var secondarySubtitleCueIndex = SubtitleCueIndex(cues: [])
    @ObservationIgnored var secondarySubtitleSelectionGeneration: UInt64 = 0
    var importedSubtitleTracks: [ImportedSubtitleTrack] = []

    var speechSubtitleStatus: SpeechSubtitleStatus = .idle
    var speechSubtitleLocale: SpeechSubtitleLocale = SubtitleStylePreferences.shared.speechLocale
    var speechSubtitleEngineLabel: String?
    var speechSubtitleCanDownloadModel = false
    @ObservationIgnored var speechSubtitleGenerator: SystemSpeechSubtitleGenerator?
    @ObservationIgnored var speechSubtitleTap: AudioPCMSubtitleTap?
    @ObservationIgnored var onDetachSpeechSubtitleTap: (@MainActor () -> Void)?

    @ObservationIgnored private let subtitlePreferences: SubtitleStylePreferences

    init(subtitlePreferences: SubtitleStylePreferences = .shared) {
        self.subtitlePreferences = subtitlePreferences
        self.speechSubtitleLocale = subtitlePreferences.speechLocale
        self.isAutoTranslationEnabled = subtitlePreferences.autoTranslateEnabled
        self.subtitleTranslationTargetLanguage = subtitlePreferences.translationTargetLanguage
    }

    // MARK: - On-Device Bilingual Auto-Translation

    var isAutoTranslationEnabled = SubtitleStylePreferences.shared.autoTranslateEnabled
    var subtitleTranslationTargetLanguage: SubtitleTranslationTargetLanguage =
        SubtitleStylePreferences.shared.translationTargetLanguage
    var subtitleTranslationService = SystemSubtitleTranslationService()

    func resetTransientSubtitleState() {
        secondarySubtitleSelectionGeneration &+= 1
        secondarySubtitleLan = nil
        secondarySubtitleText = nil
        secondarySubtitleCues = []
        primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
        importedSubtitleTracks = []
        isAutoTranslationEnabled = subtitlePreferences.autoTranslateEnabled
        speechSubtitleLocale = subtitlePreferences.speechLocale
        subtitleTranslationTargetLanguage = subtitlePreferences.translationTargetLanguage
        subtitleTranslationService.resetSession()
        speechSubtitleGenerator?.stop()
        speechSubtitleTap?.deactivate()
        onDetachSpeechSubtitleTap?()
        speechSubtitleStatus = .idle
        speechSubtitleEngineLabel = nil
        speechSubtitleCanDownloadModel = false
    }
}
