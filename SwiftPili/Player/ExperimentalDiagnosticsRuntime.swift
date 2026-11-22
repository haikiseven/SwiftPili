import Foundation

/// Applies effective diagnostic permission without replacing saved choices or
/// taking ownership of playback, renderer, graph or media-clock lifetimes.
@MainActor
enum ExperimentalDiagnosticsRuntime {
    private static var sceneActivated = false

    static func activateScene() {
        sceneActivated = true
        FreezeWatchdog.shared.start()
        applyPolicy()
    }

    static func applyPolicy() {
        PlayerLog.applyExperimentalPolicy(activateCollectors: sceneActivated)
        PlaybackDebugRecorder.applyExperimentalPolicy()
        let cacheOptionsChanged = ImagePipelinePolicy.applyExperimentalPolicy()
        ImageLoadingIndicatorPolicy.applyExperimentalPolicy()
        ImageDiagnostics.applyExperimentalPolicy(activateMonitor: sceneActivated)
        FreezeWatchdog.shared.applyExperimentalPolicy()
        #if DEBUG
        SeekHarness.applyExperimentalPolicy()
        #endif
        if cacheOptionsChanged { CacheManager.apply() }
    }
}
