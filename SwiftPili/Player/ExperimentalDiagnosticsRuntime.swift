import Foundation

@MainActor
enum ExperimentalDiagnosticsRuntime {
    static func activateScene() {
        applyPolicy()
    }

    static func applyPolicy() {
        PlayerLog.applyExperimentalPolicy()
        let cacheOptionsChanged = ImagePipelinePolicy.applyExperimentalPolicy()
        ImageLoadingIndicatorPolicy.applyExperimentalPolicy()
        #if DEBUG
        SeekHarness.applyExperimentalPolicy()
        #endif
        if cacheOptionsChanged { CacheManager.apply() }
    }
}
