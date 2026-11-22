import Foundation

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
