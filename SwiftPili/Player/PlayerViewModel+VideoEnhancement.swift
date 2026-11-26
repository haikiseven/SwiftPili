import Foundation
import Observation

/// Observable preference store for global default frame interpolation backend & force-interpolation mode.
/// Keeps `VideoEnhancementSettingsView` and active `PlayerViewModel` instances synchronized
/// without modifying `ExperimentalSettingsStore.swift`.
@MainActor
@Observable
final class InterpolationBackendPreferencesStore {
    static let shared = InterpolationBackendPreferencesStore()

    private(set) var defaultBackend: VideoFrameInterpolationBackend =
        VideoEnhancementPreferences.frameInterpolationBackend
    private(set) var defaultForceFrameInterpolation: Bool =
        VideoEnhancementPreferences.forceFrameInterpolation

    @ObservationIgnored
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (AnyObject, VideoFrameInterpolationBackend) -> Void
    }

    private init() {}

    func reloadFromDefaults() {
        defaultBackend = VideoEnhancementPreferences.frameInterpolationBackend
        defaultForceFrameInterpolation = VideoEnhancementPreferences.forceFrameInterpolation
    }

    @discardableResult
    func setDefaultBackend(_ backend: VideoFrameInterpolationBackend) -> Bool {
        let experiments = ExperimentalSettingsStore.shared
        guard experiments.isAllowed(.videoEnhancement), experiments.storageError == nil else {
            return false
        }
        guard defaultBackend != backend else { return true }
        VideoEnhancementPreferences.frameInterpolationBackend = backend
        defaultBackend = backend
        notifyObservers(backend)
        return true
    }

    @discardableResult
    func setDefaultForceFrameInterpolation(_ enabled: Bool) -> Bool {
        let experiments = ExperimentalSettingsStore.shared
        guard experiments.isAllowed(.videoEnhancement), experiments.storageError == nil else {
            return false
        }
        guard defaultForceFrameInterpolation != enabled else { return true }
        VideoEnhancementPreferences.forceFrameInterpolation = enabled
        defaultForceFrameInterpolation = enabled
        notifyObservers(defaultBackend)
        return true
    }

    func addObserver<Owner: AnyObject>(
        owner: Owner,
        handler: @escaping @MainActor (Owner, VideoFrameInterpolationBackend) -> Void
    ) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(Observer(owner: owner, handler: { object, backend in
            guard let typed = object as? Owner else { return }
            handler(typed, backend)
        }))
    }

    private func notifyObservers(_ backend: VideoFrameInterpolationBackend) {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            if let owner = observer.owner {
                observer.handler(owner, backend)
            }
        }
    }
}

@MainActor
@Observable
private final class PlayerInterpolationBackendState {
    var backend: VideoFrameInterpolationBackend
    var forceFrameInterpolation: Bool

    init(backend: VideoFrameInterpolationBackend, forceFrameInterpolation: Bool) {
        self.backend = backend
        self.forceFrameInterpolation = forceFrameInterpolation
    }
}

@MainActor
private final class PlayerInterpolationBackendRegistry {
    private struct Entry {
        weak var owner: PlayerViewModel?
        let state: PlayerInterpolationBackendState
    }

    static let shared = PlayerInterpolationBackendRegistry()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func state(for player: PlayerViewModel) -> PlayerInterpolationBackendState {
        let key = ObjectIdentifier(player)
        if let existing = entries[key], existing.owner === player {
            return existing.state
        }
        entries = entries.filter { $0.value.owner != nil }
        let store = InterpolationBackendPreferencesStore.shared
        let state = PlayerInterpolationBackendState(
            backend: store.defaultBackend,
            forceFrameInterpolation: store.defaultForceFrameInterpolation
        )
        entries[key] = Entry(owner: player, state: state)
        store.addObserver(owner: player) { owner, _ in
            owner.handleVideoEnhancementPolicyChange()
        }
        return state
    }
}

/// The settings that seed per-player enhancement choices. Changes to global display limits
/// are synced without touching what the user picked in the player.
struct VideoEnhancementDefaultsSnapshot: Equatable {
    let allowed: Bool
    let superResolutionMode: VideoSuperResolutionMode
    let frameInterpolation: Bool
    let frameInterpolationBackend: VideoFrameInterpolationBackend
    let interpolationRate: VideoInterpolationRate
    let forceFrameInterpolation: Bool
    let superResolutionScale: VideoSuperResolutionScale
    let superResolutionTargetResolution: VideoSuperResolutionTargetResolution
    let superResolutionSharpness: VideoSuperResolutionSharpness
    let maxInputResolution: VideoEnhancementMaxInputResolution

    @MainActor static var current: Self {
        let store = ExperimentalSettingsStore.shared
        let fiStore = InterpolationBackendPreferencesStore.shared
        return Self(
            allowed: store.isAllowed(.videoEnhancement),
            superResolutionMode: store.videoEnhancementDefaultSRMode,
            frameInterpolation: store.videoEnhancementDefaultFrameInterpolation,
            frameInterpolationBackend: fiStore.defaultBackend,
            interpolationRate: store.videoEnhancementDefaultRate,
            forceFrameInterpolation: fiStore.defaultForceFrameInterpolation,
            superResolutionScale: store.videoEnhancementDefaultScale,
            superResolutionTargetResolution: store.videoEnhancementDefaultTargetResolution,
            superResolutionSharpness: store.videoEnhancementDefaultSharpness,
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
    var videoFrameInterpolationBackend: VideoFrameInterpolationBackend {
        get { PlayerInterpolationBackendRegistry.shared.state(for: self).backend }
        set { PlayerInterpolationBackendRegistry.shared.state(for: self).backend = newValue }
    }

    var videoForceFrameInterpolation: Bool {
        get { PlayerInterpolationBackendRegistry.shared.state(for: self).forceFrameInterpolation }
        set { PlayerInterpolationBackendRegistry.shared.state(for: self).forceFrameInterpolation = newValue }
    }

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
            frameInterpolationBackend: videoFrameInterpolationBackend,
            interpolationRate: videoInterpolationRate,
            forceFrameInterpolation: videoForceFrameInterpolation,
            superResolutionScale: videoSuperResolutionScale,
            superResolutionTargetResolution: videoSuperResolutionTargetResolution,
            superResolutionSharpness: videoSuperResolutionSharpness,
            superResolutionSplitCompare: videoSuperResolutionMode == .metalFXSpatial
                && videoSuperResolutionSplitCompare,
            maxInputResolution: videoEnhancementMaxInputResolution,
            isLiveStream: mode == .live,
            limitToScreenResolution: ExperimentalSettingsStore.shared.videoEnhancementLimitToScreen
        )
    }

    func setVideoSuperResolutionMode(_ mode: VideoSuperResolutionMode) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement) else { return }
        guard videoSuperResolutionMode != mode else { return }
        videoSuperResolutionMode = mode
        if mode == .off {
            videoSuperResolutionSplitCompare = false
        }
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

    func setVideoFrameInterpolationBackend(_ backend: VideoFrameInterpolationBackend) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoFrameInterpolationEnabled,
              backend.isSelectable(),
              videoFrameInterpolationBackend != backend else { return }
        videoFrameInterpolationBackend = backend
        syncVideoEnhancementToBackend()
    }

    func setVideoForceFrameInterpolation(_ enabled: Bool) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoFrameInterpolationEnabled,
              videoForceFrameInterpolation != enabled else { return }
        videoForceFrameInterpolation = enabled
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

    func setVideoSuperResolutionSharpness(_ sharpness: VideoSuperResolutionSharpness) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoSuperResolutionMode == .metalFXSpatial,
              videoSuperResolutionSharpness != sharpness else { return }
        videoSuperResolutionSharpness = sharpness
        syncVideoEnhancementToBackend()
    }

    func setVideoSuperResolutionSplitCompare(_ enabled: Bool) {
        guard ExperimentalSettingsStore.shared.isAllowed(.videoEnhancement),
              isVideoEnhancementEligibleForStream, videoSuperResolutionMode == .metalFXSpatial,
              videoSuperResolutionSplitCompare != enabled else { return }
        videoSuperResolutionSplitCompare = enabled
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
            videoSuperResolutionSplitCompare = false
            videoFrameInterpolationEnabled = false
        } else if !previous.allowed {
            applyAllVideoEnhancementDefaults(defaults)
        } else {
            applyChangedVideoEnhancementDefaults(from: previous, to: defaults)
        }
        syncVideoEnhancementToBackend()
    }

    private func applyAllVideoEnhancementDefaults(_ defaults: VideoEnhancementDefaultsSnapshot) {
        videoSuperResolutionMode = defaults.superResolutionMode
        videoFrameInterpolationEnabled = defaults.frameInterpolation
        videoFrameInterpolationBackend = defaults.frameInterpolationBackend
        videoInterpolationRate = defaults.interpolationRate
        videoForceFrameInterpolation = defaults.forceFrameInterpolation
        videoSuperResolutionScale = defaults.superResolutionScale
        videoSuperResolutionTargetResolution = defaults.superResolutionTargetResolution
        videoSuperResolutionSharpness = defaults.superResolutionSharpness
        videoEnhancementMaxInputResolution = defaults.maxInputResolution
    }

    private func applyChangedVideoEnhancementDefaults(
        from previous: VideoEnhancementDefaultsSnapshot,
        to defaults: VideoEnhancementDefaultsSnapshot
    ) {
        if defaults.superResolutionMode != previous.superResolutionMode {
            videoSuperResolutionMode = defaults.superResolutionMode
        }
        if defaults.frameInterpolation != previous.frameInterpolation {
            videoFrameInterpolationEnabled = defaults.frameInterpolation
        }
        if defaults.frameInterpolationBackend != previous.frameInterpolationBackend {
            videoFrameInterpolationBackend = defaults.frameInterpolationBackend
        }
        if defaults.interpolationRate != previous.interpolationRate {
            videoInterpolationRate = defaults.interpolationRate
        }
        if defaults.forceFrameInterpolation != previous.forceFrameInterpolation {
            videoForceFrameInterpolation = defaults.forceFrameInterpolation
        }
        if defaults.superResolutionScale != previous.superResolutionScale {
            videoSuperResolutionScale = defaults.superResolutionScale
        }
        if defaults.superResolutionTargetResolution != previous.superResolutionTargetResolution {
            videoSuperResolutionTargetResolution = defaults.superResolutionTargetResolution
        }
        if defaults.superResolutionSharpness != previous.superResolutionSharpness {
            videoSuperResolutionSharpness = defaults.superResolutionSharpness
        }
        if defaults.maxInputResolution != previous.maxInputResolution {
            videoEnhancementMaxInputResolution = defaults.maxInputResolution
        }
    }
}
